#!/usr/bin/env python3
"""Focused, sandboxed Bundle tests. No real Toolkit or HOME state is touched."""
import importlib.util
import fcntl
import glob
import io
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import tarfile
import tempfile
import termios
import time
import unittest
from unittest.mock import patch

MODULE = Path(__file__).resolve().parents[1] / "modules/bundle/bundle.py"
spec = importlib.util.spec_from_file_location("bundle", MODULE)
bundle = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bundle)


def blueprint():
    categories = {name: False for name in bundle.CATEGORY_FLAGS}
    categories["macos-screenshots"] = True
    return ("[categories]\n" +
            "".join(f'{name}="{str(value).lower()}"\n' for name, value in categories.items()) +
            "".join(f"\n[{name}]\n" +
                    ("demo\n" if name in ("git-repositories", "workspace-folders") else "")
                    for name in bundle.ITEMS)).encode()


class BundleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.config = self.root / "config"
        self.config.mkdir()
        self.stage = self.root / "stage"
        self.stage.mkdir(mode=0o700)
        self.bundle = self.root / "test.mbt"
        bundle.write_file(self.stage / "blueprint.conf", blueprint())
        bundle.write_file(self.stage / "generated/workspace/folders.conf", b"Work|workspace\n")
        bundle.write_file(self.stage / "generated/workspace/repositories.conf",
                          b'[demo]\nNAME="demo"\nPATH="/Users/source/Work/demo"\n'
                          b'REMOTE="git@example.com:demo.git"\nCURRENT_BRANCH="main"\n')
        bundle.write_file(self.stage / "generated/macos/screenshots.conf",
                          b"com.apple.screencapture|location|string|/Users/source/Screenshots\n")

    def pack(self):
        bundle.pack(self.stage, self.bundle, "/Users/source")

    def run_pty(self, command, answers, *, cwd, env):
        master, slave = pty.openpty()
        settings = termios.tcgetattr(slave)
        settings[3] &= ~termios.ECHO
        termios.tcsetattr(slave, termios.TCSANOW, settings)
        def controlling_tty():
            os.setsid()
            fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
        proc = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                                cwd=cwd, env=env, preexec_fn=controlling_tty)
        os.close(slave)
        pending = list(answers)
        observed = b""
        transcript = b""
        deadline = time.monotonic() + 20
        reached_eof = False
        try:
            while proc.poll() is None and time.monotonic() < deadline:
                ready, _, _ = select.select([master], [], [], .2)
                if ready:
                    try:
                        chunk = os.read(master, 65536)
                    except OSError:
                        reached_eof = True
                        break
                    if not chunk:
                        reached_eof = True
                        break
                    observed += chunk
                    transcript += chunk
                if pending:
                    expected = pending[0][0]
                    prompts = expected if isinstance(expected, tuple) else (expected,)
                    if any(prompt in observed for prompt in prompts):
                        os.write(master, pending.pop(0)[1] + b"\n")
                        observed = b""
            if reached_eof and proc.poll() is None:
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    pass
            if proc.poll() is None:
                reason = "PTY closed before process exit" if reached_eof else "PTY dialogue timed out"
                next_prompt = pending[0][0] if pending else b"<process exit>"
                raise AssertionError(f"{reason}; waiting for {next_prompt!r}")
            proc.wait()
        finally:
            os.close(master)
            if proc.poll() is None:
                try:
                    os.killpg(proc.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    try:
                        os.killpg(proc.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    proc.wait()
        self.assertFalse(pending, "expected prompt was not reached")
        self.assertNotIn(b"BEGIN OPENSSH PRIVATE KEY", transcript)
        return proc.returncode, transcript

    def test_portable_paths_and_selected_allowlist(self):
        bundle.write_file(self.stage / "generated/never-include", b"private")
        self.pack()
        files = bundle.validate_archive(self.bundle)
        self.assertNotIn("generated/never-include", files)
        self.assertIn(b'PATH="~/Work/demo"', files["generated/workspace/repositories.conf"])
        self.assertIn(b"location|string|~/Screenshots", files["generated/macos/screenshots.conf"])
        target = self.root / "target"
        target.mkdir()
        bundle.unpack(self.bundle, target, "/Users/target")
        self.assertIn(b'PATH="/Users/target/Work/demo"',
                      (target / "generated/workspace/repositories.conf").read_bytes())
        self.assertIn(b"location|string|~/Screenshots",
                      (target / "generated/macos/screenshots.conf").read_bytes())
        self.assertEqual(self.bundle.stat().st_mode & 0o777, 0o600)

    def test_windows_expansion_preserves_legacy_bundles(self):
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_bytes(blueprint.read_bytes().replace(b'macos-windows="false"', b'macos-windows="true"'))
        source = self.stage / 'generated/macos/windows.conf'
        legacy = b'NSGlobalDomain|AppleWindowTabbingMode|string|manual\n'
        booleans = ''.join('com.apple.WindowManager|' + key + '|bool|' + value + '\n'
                           for key, value in zip(['EnableStandardClickToShowDesktop', 'EnableTilingByEdgeDrag', 'EnableTopTilingByEdgeDrag', 'EnableTiledWindowMargins'], ['true', 'false', 'true', 'false'])).encode()
        for index, content in enumerate((legacy, legacy + booleans, booleans, b'')):
            with self.subTest(index=index):
                source.parent.mkdir(parents=True, exist_ok=True)
                source.write_bytes(content)
                source.chmod(0o600)
                archive = self.root / f'windows-{index}.mbt'
                bundle.pack(self.stage, archive, '/Users/source')
                self.assertEqual(bundle.validate_archive(archive)['generated/macos/windows.conf'], content)
                target = self.root / f'windows-{index}'
                target.mkdir()
                bundle.unpack(archive, target, '/Users/target')
                self.assertEqual((target / 'generated/macos/windows.conf').read_bytes(), content)

    def test_screenshot_booleans_preserve_location_and_legacy_bundles(self):
        source = self.stage / 'generated/macos/screenshots.conf'
        legacy = source.read_bytes()
        booleans = b'com.apple.screencapture|disable-shadow|bool|true\ncom.apple.screencapture|show-thumbnail|bool|false\n'
        desktop = b'com.apple.screencapture|location|string|~/Desktop\n'
        for index, content in enumerate((legacy, legacy + booleans, booleans, b'',
                                         desktop, desktop.replace(b'~/', b'/Users/source/'))):
            with self.subTest(index=index):
                source.write_bytes(content)
                archive = self.root / f'screenshots-{index}.mbt'
                bundle.pack(self.stage, archive, '/Users/source')
                files = bundle.validate_archive(archive)
                expected = content.replace(b'/Users/source/', b'~/')
                self.assertEqual(files['generated/macos/screenshots.conf'], expected)
                target = self.root / f'unpacked-{index}'
                target.mkdir()
                bundle.unpack(archive, target, '/Users/target')
                self.assertEqual((target / 'generated/macos/screenshots.conf').read_bytes(), expected)

    def test_unselected_inventory_is_not_carried(self):
        path = self.stage / "blueprint.conf"
        path.write_bytes(path.read_bytes().replace(
            b"[homebrew-packages]\n", b"[homebrew-packages]\nselected\n"))
        bundle.write_file(self.stage / "generated/brew-packages.conf",
                          b"selected\nunselected\n")
        repo = self.stage / "generated/workspace/repositories.conf"
        repo.write_bytes(repo.read_bytes() +
                         b'[other]\nNAME="other"\nPATH="/Users/source/Work/other"\n'
                         b'REMOTE="git@example.com:other.git"\nCURRENT_BRANCH="main"\n')
        self.pack()
        files = bundle.validate_archive(self.bundle)
        self.assertEqual(files["generated/brew-packages.conf"], b"selected\n")
        self.assertNotIn(b"[other]", files["generated/workspace/repositories.conf"])

    def test_complete_inventory_keeps_excluded_items_for_comparison(self):
        inventory = b"selected\nexcluded\n"
        selected = self.stage / "blueprint.conf"
        selected.write_bytes(selected.read_bytes().replace(
            b"[homebrew-casks]\n", b"[homebrew-casks]\nselected\n"))
        bundle.write_file(self.stage / "generated/brew-casks.conf", inventory)
        marker = ("complete " + bundle.digest(inventory) + "\n").encode()
        bundle.write_file(self.stage / "generated/provenance/homebrew-casks.sha256", marker)
        self.pack()
        files = bundle.validate_archive(self.bundle)
        self.assertEqual(files["generated/brew-casks.conf"], inventory)
        self.assertEqual(files["generated/provenance/homebrew-casks.sha256"], marker)
        target = self.root / "target"
        target.mkdir()
        bundle.unpack(self.bundle, target, "/Users/target")
        self.assertEqual((target / "generated/brew-casks.conf").read_bytes(), inventory)

    def test_invalid_completeness_marker_rejected(self):
        bundle.write_file(self.stage / "generated/brew-casks.conf", b"example\n")
        bundle.write_file(self.stage / "generated/provenance/homebrew-casks.sha256",
                          b"complete " + b"0" * 64 + b"\n")
        with self.assertRaises(bundle.Invalid):
            self.pack()

    def test_only_selected_git_values_are_carried(self):
        path = self.stage / "blueprint.conf"
        path.write_bytes(path.read_bytes().replace(
            b'git-configuration="false"', b'git-configuration="true"').replace(
            b"[git-configuration]\n", b"[git-configuration]\nuser.name\n"))
        bundle.write_file(self.stage / "generated/git.conf",
                          b'[user]\n\tname = Selected\n\temail = excluded@example.invalid\n')
        self.pack()
        content = bundle.validate_archive(self.bundle)["generated/git.conf"]
        self.assertIn(b"Selected", content)
        self.assertNotIn(b"excluded@example.invalid", content)

    def test_staged_capture_keeps_working_blueprint(self):
        working = self.config / "blueprint.conf"
        working.write_bytes(b"working Mac selection\n")
        self.pack()
        self.assertEqual(working.read_bytes(), b"working Mac selection\n")
        self.assertNotEqual(bundle.validate_archive(self.bundle)["blueprint.conf"],
                            working.read_bytes())

    def test_secure_payload_stays_opaque_and_outside_generated(self):
        payload = b"age-encryption.org/v1\nopaque-test-ciphertext"
        bundle.write_file(self.stage / "secure.age", payload)
        self.pack()
        files = bundle.validate_archive(self.bundle)
        self.assertEqual(files["secure.age"], payload)
        self.assertFalse(any("secure" in name for name in files if name.startswith("generated/")))
        target = self.root / "target"
        target.mkdir()
        bundle.unpack(self.bundle, target, "/Users/target")
        self.assertEqual((target / "secure.age").read_bytes(), payload)
        self.assertFalse((target / "generated/secure.age").exists())

    def test_cancel_before_publication_preserves_staging(self):
        before = (self.stage / "blueprint.conf").read_bytes()
        result = subprocess.run(
            ["bash", "-c", 'source modules/bundle/commands.sh; bundle_choose_categories "$1"', "_",
             str(self.stage)], input="q\n", text=True, capture_output=True,
            cwd=MODULE.parents[2], check=False)
        self.assertEqual(result.returncode, 3)
        self.assertEqual((self.stage / "blueprint.conf").read_bytes(), before)
        self.assertFalse(self.bundle.exists())

    def test_external_screenshot_rejected(self):
        (self.stage / "generated/macos/screenshots.conf").write_bytes(
            b"com.apple.screencapture|location|string|/Volumes/other/Screenshots\n")
        with self.assertRaises(bundle.Invalid):
            self.pack()
        self.assertFalse(self.bundle.exists())

    def test_external_repository_rejected(self):
        path = self.stage / "generated/workspace/repositories.conf"
        path.write_bytes(path.read_bytes().replace(b"/Users/source/Work", b"/Users/other/Work"))
        with self.assertRaises(bundle.Invalid):
            self.pack()

    def test_integrity_and_malformed_archive(self):
        self.pack()
        files = bundle.validate_archive(self.bundle)
        files["generated/workspace/folders.conf"] = b"tampered"
        changed = self.root / "changed.mbt"
        with tarfile.open(changed, "w") as tar:
            for name, data in files.items():
                info = tarfile.TarInfo(name)
                info.size = len(data)
                tar.addfile(info, io.BytesIO(data))
            with tarfile.open(self.bundle) as original:
                data = json.loads(original.extractfile("manifest.json").read())
            raw = json.dumps(data).encode()
            info = tarfile.TarInfo("manifest.json")
            info.size = len(raw)
            tar.addfile(info, io.BytesIO(raw))
        with self.assertRaises(bundle.Invalid):
            bundle.validate_archive(changed)
        unsafe = self.root / "unsafe.mbt"
        with tarfile.open(unsafe, "w") as tar:
            info = tarfile.TarInfo("../escape")
            info.size = 1
            tar.addfile(info, io.BytesIO(b"x"))
        with self.assertRaises(bundle.Invalid):
            bundle.validate_archive(unsafe)
        linked = self.root / "linked.mbt"
        with tarfile.open(linked, "w") as tar:
            info = tarfile.TarInfo("secure.age")
            info.type = tarfile.SYMTYPE
            info.linkname = "blueprint.conf"
            tar.addfile(info)
        with self.assertRaises(bundle.Invalid):
            bundle.validate_archive(linked)

    def test_narrow_only_removes(self):
        bundle.narrow(self.stage, ["Workspace", "macOS Settings"])
        sections, categories = bundle.parse_blueprint((self.stage / "blueprint.conf").read_bytes())
        self.assertEqual(sections["git-repositories"], [])
        self.assertFalse(categories["macos-screenshots"])

    def test_restore_groups_cover_every_transferable_scope(self):
        self.assertEqual(set(bundle.SELECTABLE_ITEMS) | set(bundle.CATEGORIES),
                         {scope for scopes in bundle.GROUPS.values() for scope in scopes})

    def test_vscode_settings_can_be_disabled_without_expanding_source_selection(self):
        path = self.stage / "blueprint.conf"
        path.write_bytes(path.read_bytes().replace(
            b'vscode-settings="false"', b'vscode-settings="true"'))
        with patch("sys.stdout", capture := io.StringIO()):
            bundle.summary(self.stage, False, ["VS Code Settings"])
        self.assertIn("VS Code Settings     No", capture.getvalue())
        bundle.narrow(self.stage, ["VS Code Settings"])
        sections, categories = bundle.parse_blueprint(path.read_bytes())
        self.assertFalse(categories["vscode-settings"])
        self.assertFalse(categories["ssh-configuration"])
        self.assertEqual(sections["git-repositories"], ["demo"])
        bundle.narrow(self.stage, ["Applications"])
        self.assertFalse(bundle.parse_blueprint(path.read_bytes())[1]["vscode-settings"])

    def test_restore_menu_disables_vscode_settings(self):
        path = self.stage / "blueprint.conf"
        path.write_bytes(path.read_bytes().replace(
            b'vscode-settings="false"', b'vscode-settings="true"'))
        result = subprocess.run(
            ["bash", "-c", 'source modules/bundle/commands.sh; bundle_choose_categories "$1"', "_",
             str(self.stage)], input="c\n8\n\n", text=True, capture_output=True,
            cwd=MODULE.parents[2], check=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("8 [x] VS Code Settings", result.stdout)
        self.assertIn("VS Code Settings     No", result.stdout)
        self.assertFalse(bundle.parse_blueprint(path.read_bytes())[1]["vscode-settings"])

    def test_summary_lists_selected_states_without_aggregation(self):
        path = self.stage / "blueprint.conf"
        path.write_bytes(path.read_bytes().replace(
            b'vscode-settings="false"', b'vscode-settings="true"').replace(
            b'ssh-configuration="false"', b'ssh-configuration="true"').replace(
            b'[homebrew-casks]\n', b'[homebrew-casks]\ncask-one\n').replace(
            b'[app-store]\n', b'[app-store]\napp-one\n').replace(
            b'[vscode-extensions]\n', b'[vscode-extensions]\next-one\n'))
        bundle.write_file(self.stage / "secure.age", b"opaque")
        capture = io.StringIO()
        with patch("sys.stdout", capture):
            bundle.summary(self.stage, True, [])
        result = capture.getvalue()
        for line in ("Homebrew casks       1", "App Store apps       1",
                     "VS Code extensions   1", "VS Code Settings     Yes",
                     "SSH Configuration    Yes", "Shell / Zsh          No",
                     "Folders              1", "Git repositories     1",
                     "SSH identities       Selected"):
            self.assertIn(line, result)
        with patch("sys.stdout", capture := io.StringIO()):
            bundle.summary(self.stage, False, ["Applications", "SSH Configuration"])
        self.assertIn("VS Code extensions   0", capture.getvalue())
        self.assertIn("SSH Configuration    No", capture.getvalue())
        self.assertIn("SSH identities       No", capture.getvalue())

    def test_publication_failure_and_interrupted_recovery(self):
        target = self.root / "target"
        target.mkdir()
        self.pack()
        bundle.unpack(self.bundle, target, "/Users/target")
        old_dir = self.config / "generated"
        old_dir.mkdir()
        (old_dir / "old").write_text("old")
        (self.config / "blueprint.conf").write_text("old")
        with patch.object(bundle, "CONFIG", self.config), patch.object(bundle, "RECOVERY", self.config / ".bundle-publication"):
            real_rename = os.rename
            def fail_new_blueprint(source, destination):
                if Path(source).name == "blueprint.new":
                    raise OSError("injected failure")
                return real_rename(source, destination)
            with patch.object(bundle.os, "rename", side_effect=fail_new_blueprint):
                with self.assertRaises(bundle.Invalid):
                    bundle.publish(target)
            self.assertEqual((self.config / "blueprint.conf").read_text(), "old")
            self.assertEqual((old_dir / "old").read_text(), "old")
            recovery = self.config / ".bundle-publication"
            recovery.mkdir()
            def identity(path, prepared):
                return {"present": True, "dev": path.stat().st_dev,
                        "ino": path.stat().st_ino, "old": bundle.fingerprint(path),
                        "new": bundle.fingerprint(prepared)}
            (recovery / "incomplete").write_text(json.dumps({
                "generated": identity(old_dir, target / "generated"),
                "blueprint": identity(self.config / "blueprint.conf", target / "blueprint.conf"),
            }))
            real_rename(old_dir, recovery / "generated.old")
            bundle.recover()
            self.assertEqual((old_dir / "old").read_text(), "old")
            self.assertEqual((self.config / "blueprint.conf").read_text(), "old")
            bundle.publish(target)
            self.assertTrue((self.config / "generated/workspace/folders.conf").is_file())
            bundle.publish(target)

    def test_each_publication_rename_failure_restores_pair(self):
        target = self.root / "target"
        target.mkdir()
        self.pack()
        bundle.unpack(self.bundle, target, "/Users/target")
        for step in range(1, 5):
            with self.subTest(rename=step):
                config = self.root / f"config-{step}"
                config.mkdir()
                (config / "generated").mkdir()
                (config / "generated/old").write_text("old")
                (config / "blueprint.conf").write_text("old")
                with patch.object(bundle, "CONFIG", config), patch.object(
                    bundle, "RECOVERY", config / ".bundle-publication"
                ):
                    real_rename = os.rename
                    calls = [0]
                    def fail_step(source, destination):
                        calls[0] += 1
                        if calls[0] == step:
                            raise OSError("injected rename failure")
                        return real_rename(source, destination)
                    with patch.object(bundle.os, "rename", side_effect=fail_step):
                        with self.assertRaises(bundle.Invalid):
                            bundle.publish(target)
                    self.assertEqual((config / "generated/old").read_text(), "old")
                    self.assertEqual((config / "blueprint.conf").read_text(), "old")
                    self.assertFalse((config / ".bundle-publication").exists())

    def test_completion_marker_failure_restores_previous_pair(self):
        target = self.root / "completion-stage"
        target.mkdir()
        self.pack()
        bundle.unpack(self.bundle, target, "/Users/target")
        (self.config / "generated").mkdir()
        (self.config / "generated/old").write_text("old generated")
        (self.config / "blueprint.conf").write_text("old blueprint")
        recovery = self.config / ".bundle-publication"
        real_rename = os.rename
        def fail_completion(source, destination):
            if Path(source).name == "incomplete" and Path(destination).name == "complete":
                raise OSError("injected completion failure")
            return real_rename(source, destination)
        with patch.object(bundle, "CONFIG", self.config), patch.object(bundle, "RECOVERY", recovery):
            with patch.object(bundle.os, "rename", side_effect=fail_completion):
                with self.assertRaises(bundle.Invalid):
                    bundle.publish(target)
        self.assertEqual((self.config / "generated/old").read_text(), "old generated")
        self.assertEqual((self.config / "blueprint.conf").read_text(), "old blueprint")
        self.assertFalse(recovery.exists())

    def test_marker_before_first_rename_and_changed_state(self):
        config = self.config
        old = config / "generated"
        old.mkdir()
        (old / "old").write_text("old")
        blueprint_path = config / "blueprint.conf"
        blueprint_path.write_text("old")
        recovery = config / ".bundle-publication"
        recovery.mkdir()
        records = {}
        for key, path in (("generated", old), ("blueprint", blueprint_path)):
            records[key] = {"present": True, "dev": path.stat().st_dev,
                            "ino": path.stat().st_ino, "old": bundle.fingerprint(path),
                            "new": "different"}
        (recovery / "incomplete").write_text(json.dumps(records))
        with patch.object(bundle, "CONFIG", config), patch.object(bundle, "RECOVERY", recovery):
            bundle.recover()
            self.assertEqual(blueprint_path.read_text(), "old")
            recovery.mkdir()
            (recovery / "incomplete").write_text(json.dumps(records))
            blueprint_path.write_text("changed")
            with self.assertRaises(bundle.Invalid):
                bundle.recover()

    def test_restore_stages_preview_then_publishes_for_bootstrap(self):
        self.pack()
        fixture = self.root / "fixture"
        (fixture / "modules/bundle").mkdir(parents=True)
        (fixture / "config/generated").mkdir(parents=True)
        (fixture / "scripts").mkdir()
        shutil.copy2(MODULE, fixture / "modules/bundle/bundle.py")
        shutil.copy2(MODULE.with_name("commands.sh"), fixture / "modules/bundle/commands.sh")
        (fixture / "modules/apps").mkdir()
        shutil.copy2(MODULE.parents[1] / "apps/application_identity.py",
                     fixture / "modules/apps/application_identity.py")
        (fixture / "config/blueprint.conf").write_text("old selection")
        (fixture / "config/generated/old").write_text("old state")
        fake_home = self.root / "target-home"
        fake_home.mkdir()
        stub = fixture / "bootstrap.sh"
        stub.write_text(
            '#!/bin/bash\n'
            'case "$1" in\n'
            '  --dry-run) [[ "$BLUEPRINT_FILE" == /* && -f "$BLUEPRINT_FILE" && '
            '"$BLUEPRINT_GENERATED_DIR" == /* ]] || exit 2; '
            'echo preview >> calls ;;\n'
            '  --bootstrap) [[ -z "${BLUEPRINT_FILE:-}" && -f config/blueprint.conf && '
            '-f config/generated/workspace/repositories.conf ]] || exit 2; '
            'echo bootstrap >> calls ;;\n'
            '  *) exit 2 ;;\n'
            'esac\n')
        stub.chmod(0o700)
        command = ('source modules/bundle/commands.sh; '
                   'info(){ :; }; warning(){ :; }; error(){ :; }; '
                   'success(){ :; }; bundle_restore "$1"')
        environment = dict(os.environ, HOME=str(fake_home))
        isolated_tmp = fixture / "private-tmp"
        isolated_tmp.mkdir(mode=0o700)
        cancelled = subprocess.run(
            ["bash", "-c", command, "_", str(self.bundle)],
            input="q\n", text=True, capture_output=True,
            cwd=fixture, env=dict(environment, TMPDIR=str(isolated_tmp)), check=False)
        self.assertEqual(cancelled.returncode, 0, cancelled.stderr)
        self.assertFalse((fixture / "calls").exists())
        self.assertFalse(list(isolated_tmp.glob("mbt-bundle.*")))
        self.assertEqual((fixture / "config/blueprint.conf").read_text(), "old selection")
        fault = fixture / "fault"
        fault.mkdir()
        (fault / "sitecustomize.py").write_text(
            'import os, sys\n'
            'if len(sys.argv) > 1 and sys.argv[1] == "publish":\n'
            '    original = os.rename\n'
            '    def fail_completion(source, target):\n'
            '        if str(source).endswith("/.bundle-publication/incomplete") and '
            'str(target).endswith("/.bundle-publication/complete"):\n'
            '            raise OSError("injected completion failure")\n'
            '        return original(source, target)\n'
            '    os.rename = fail_completion\n')
        failed = subprocess.run(
            ["bash", "-c", command, "_", str(self.bundle)], input="\ny\n", text=True,
            capture_output=True, cwd=fixture,
            env=dict(environment, PYTHONPATH=str(fault), TMPDIR=str(isolated_tmp)), check=False)
        self.assertEqual(failed.returncode, 2, failed.stderr + failed.stdout)
        self.assertEqual((fixture / "calls").read_text().splitlines(), ["preview"])
        self.assertEqual((fixture / "config/blueprint.conf").read_text(), "old selection")
        self.assertEqual((fixture / "config/generated/old").read_text(), "old state")
        self.assertFalse((fixture / "config/.bundle-publication").exists())
        self.assertFalse(list(isolated_tmp.glob("mbt-bundle.*")))
        (fixture / "calls").unlink()
        applied = subprocess.run(
            ["bash", "-c", command, "_", str(self.bundle)],
            input="\ny\n", text=True, capture_output=True,
            cwd=fixture, env=environment, check=False)
        self.assertEqual(applied.returncode, 0, applied.stderr + applied.stdout)
        self.assertEqual((fixture / "calls").read_text().splitlines(),
                         ["preview", "bootstrap"])
        self.assertIn(str(fake_home / "Work/demo"),
                      (fixture / "config/generated/workspace/repositories.conf").read_text())

    @unittest.skipUnless(shutil.which("age") and shutil.which("ssh-keygen"),
                         "real age and ssh-keygen are required")
    def test_apply_gate_to_real_secure_import_in_isolated_home(self):
        source_home = self.root / "source-home"
        source_ssh = source_home / ".ssh"
        source_ssh.mkdir(parents=True, mode=0o700)
        source_key = source_ssh / "id_ed25519"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(source_key)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        phrase = b"fixture-only-bundle-phrase"
        migration = MODULE.parents[2] / "scripts/ssh-identity-migrate.sh"
        export_status, _ = self.run_pty(
            ["bash", str(migration), "export", "--output", str(self.stage / "secure.age")],
            [(b"Select numbers", b"1"), (b"Type export", b"export"),
             (b"Enter passphrase", phrase), (b"Confirm passphrase", phrase)],
            cwd=MODULE.parents[2], env=dict(os.environ, HOME=str(source_home)))
        self.assertEqual(export_status, 0)
        self.pack()

        fixture = self.root / "runtime"
        for folder in ("modules/bundle", "modules/apps", "modules/migration", "modules/verification", "scripts", "config/generated"):
            (fixture / folder).mkdir(parents=True, exist_ok=True)
        for original, target in (
            (MODULE, fixture / "modules/bundle/bundle.py"),
            (MODULE.with_name("commands.sh"), fixture / "modules/bundle/commands.sh"),
            (MODULE.parents[1] / "apps/application_identity.py", fixture / "modules/apps/application_identity.py"),
            (migration, fixture / "scripts/ssh-identity-migrate.sh"),
            (migration.parents[1] / "modules/migration/ssh-identities.sh",
             fixture / "modules/migration/ssh-identities.sh"),
            (migration.parents[1] / "modules/migration/package.sh",
             fixture / "modules/migration/package.sh"),
            (migration.parents[1] / "modules/migration/evidence.py",
             fixture / "modules/migration/evidence.py"),
            (migration.parents[1] / "modules/migration/secret_input.py",
             fixture / "modules/migration/secret_input.py"),
        ):
            shutil.copy2(original, target)
        shutil.copy2(migration.parents[1] / "modules/verification/ssh-identities.sh",
                     fixture / "modules/verification/ssh-identities.sh")
        (fixture / "config/generated/old").write_text("previous state")
        (fixture / "config/blueprint.conf").write_text("previous selection")
        bootstrap = fixture / "bootstrap.sh"
        bootstrap.write_text(
            '#!/bin/bash\n'
            'case "$1" in\n'
            '  --dry-run) [[ -f "$BLUEPRINT_FILE" && -d "$BLUEPRINT_GENERATED_DIR" ]] || exit 2; '
            'echo preview >> calls ;;\n'
            '  --bootstrap) [[ -z "${BLUEPRINT_FILE:-}" && -f config/blueprint.conf && '
            '-f config/generated/workspace/repositories.conf ]] || exit 2; '
            'echo bootstrap >> calls; [[ -z "${BUNDLE_TEST_BOOTSTRAP_FAIL:-}" ]] || exit 2; '
            'source modules/bundle/commands.sh; source modules/verification/ssh-identities.sh; '
            'GV_RUN_ID=bundle-fixture; '
            'blueprint_category_enabled(){ return 1; }; '
            'info(){ printf "%s\\n" "$1"; }; warning(){ :; }; '
            'bundle_restore_prerequisites ;;\n'
            '  --workflow) [[ -f config/blueprint.conf && '
            '-f config/generated/workspace/repositories.conf ]] || exit 2; '
            'echo workflow >> calls ;;\n'
            '  *) exit 2 ;;\n'
            'esac\n')
        bootstrap.chmod(0o700)
        command = ["bash", "-c", 'source modules/bundle/commands.sh; '
                   'info(){ printf "%s\\n" "$1"; }; warning(){ :; }; error(){ :; }; success(){ :; }; '
                   'bundle_restore "$1"', "_", str(self.bundle)]
        private_tmp = self.root / "private-tmp"
        private_tmp.mkdir(mode=0o700)
        migration_temps = set(glob.glob("/private/tmp/ssh-migrate-*"))

        def run_restore(home, answers):
            home.mkdir(mode=0o700)
            return self.run_pty(command, answers, cwd=fixture,
                                env=dict(os.environ, HOME=str(home), TMPDIR=str(private_tmp),
                                         MACSEED_APPLICATION_EXECUTION="false",
                                         MACSEED_APPLICATION_SECURE_READY="true",
                                         MACSEED_APPLICATION_SECURE_VERIFY_ONLY="true"))

        target = self.root / "target-home"
        status, restore_transcript = run_restore(target, [(b"Enter=continue", b""),
                                         (b"Apply this selection", b"y"),
                                         (b"Enter passphrase", phrase),
                                         (b"Type import", b"import")])
        self.assertEqual(status, 0)
        self.assertIn(b"Secure Credentials: enter the Bundle passphrase", restore_transcript)
        self.assertIn(b"not an SSH-key passphrase", restore_transcript)
        self.assertNotIn(phrase, restore_transcript)
        self.assertEqual((fixture / "calls").read_text().splitlines(), ["preview", "bootstrap"])
        self.assertEqual((target / ".ssh/id_ed25519").read_bytes(), source_key.read_bytes())
        self.assertEqual((target / ".ssh/id_ed25519.pub").read_bytes(),
                         source_key.with_suffix(".pub").read_bytes())
        self.assertEqual((target / ".ssh").stat().st_mode & 0o777, 0o700)
        self.assertEqual((target / ".ssh/id_ed25519").stat().st_mode & 0o777, 0o600)
        self.assertEqual((target / ".ssh/id_ed25519.pub").stat().st_mode & 0o777, 0o644)
        self.assertFalse((fixture / "config/.bundle-publication").exists())
        self.assertFalse(list(private_tmp.glob("mbt-bundle.*")))
        workflow = subprocess.run(["bash", "bootstrap.sh", "--workflow"], cwd=fixture,
                                  env=dict(os.environ, HOME=str(target)), capture_output=True)
        self.assertEqual(workflow.returncode, 0)
        self.assertEqual((fixture / "calls").read_text().splitlines(),
                         ["preview", "bootstrap", "workflow"])

        failed_home = self.root / "bootstrap-failed-home"
        failed_home.mkdir(mode=0o700)
        status, _ = self.run_pty(command, [(b"Enter=continue", b""),
                                          (b"Apply this selection", b"y")], cwd=fixture,
                                 env=dict(os.environ, HOME=str(failed_home),
                                          TMPDIR=str(private_tmp), BUNDLE_TEST_BOOTSTRAP_FAIL="1"))
        self.assertEqual(status, 2)
        self.assertFalse((failed_home / ".ssh").exists())
        self.assertFalse(list(private_tmp.glob("mbt-bundle.*")))

        wrong_target = self.root / "wrong-home"
        status, _ = run_restore(wrong_target, [(b"Enter=continue", b""),
                                               (b"Apply this selection", b"y"),
                                               (b"Enter passphrase", b"wrong-fixture-phrase")])
        self.assertEqual(status, 2)
        self.assertFalse((wrong_target / ".ssh").exists())
        self.assertFalse(list(private_tmp.glob("mbt-bundle.*")))
        self.assertEqual(set(glob.glob("/private/tmp/ssh-migrate-*")), migration_temps)

        conflict_target = self.root / "conflict-home"
        conflict_target.mkdir(mode=0o700)
        conflict_ssh = conflict_target / ".ssh"
        conflict_ssh.mkdir(mode=0o700)
        conflict_key = conflict_ssh / "id_ed25519"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(conflict_key)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        before = conflict_key.read_bytes()
        status, _ = self.run_pty(command, [(b"Enter=continue", b""),
                                            (b"Apply this selection", b"y"),
                                            (b"Enter passphrase", phrase)], cwd=fixture,
                                 env=dict(os.environ, HOME=str(conflict_target), TMPDIR=str(private_tmp)))
        self.assertEqual(status, 1)
        self.assertEqual(conflict_key.read_bytes(), before)
        self.assertFalse(list(private_tmp.glob("mbt-bundle.*")))

    @unittest.skipUnless(shutil.which("age") and shutil.which("ssh-keygen"),
                         "real age and ssh-keygen are required")
    def test_integrated_capture_unlocks_selected_key_once(self):
        source_home = self.root / "capture-home"
        ssh = source_home / ".ssh"
        ssh.mkdir(parents=True, mode=0o700)
        key = ssh / "id_ed25519"
        key_phrase = b"fixture-only-ssh-key-passphrase"
        age_phrase = b"fixture-only-secure-credentials-passphrase"
        status, _ = self.run_pty(
            ["ssh-keygen", "-q", "-t", "ed25519", "-f", str(key)],
            [(b"Enter passphrase", key_phrase), (b"Enter same passphrase", key_phrase)],
            cwd=self.root, env=dict(os.environ, HOME=str(source_home)))
        self.assertEqual(status, 0)
        repositories = self.stage / "generated/workspace/repositories.conf"
        repositories.write_bytes(repositories.read_bytes().replace(
            b"/Users/source", str(source_home).encode()))
        screenshots = self.stage / "generated/macos/screenshots.conf"
        screenshots.write_bytes(screenshots.read_bytes().replace(
            b"/Users/source", str(source_home).encode()))
        bundle.write_file(self.stage / "generated/appstore.conf", b"")
        bundle.write_file(self.stage / "generated/vscode-extensions.conf", b"")
        fixture = self.root / "capture-runtime"
        for folder in ("modules/bundle", "modules/apps", "modules/migration", "scripts", "seed", "private-tmp"):
            (fixture / folder).mkdir(parents=True, exist_ok=True)
        shutil.copytree(self.stage, fixture / "seed", dirs_exist_ok=True)
        migration = MODULE.parents[2] / "scripts/ssh-identity-migrate.sh"
        for original, target in (
            (MODULE, fixture / "modules/bundle/bundle.py"),
            (MODULE.with_name("commands.sh"), fixture / "modules/bundle/commands.sh"),
            (MODULE.parents[1] / "apps/application_identity.py", fixture / "modules/apps/application_identity.py"),
            (migration, fixture / "scripts/ssh-identity-migrate.sh"),
            (migration.parents[1] / "modules/migration/ssh-identities.sh",
             fixture / "modules/migration/ssh-identities.sh"),
            (migration.parents[1] / "modules/migration/package.sh",
             fixture / "modules/migration/package.sh"),
            (migration.parents[1] / "modules/migration/evidence.py",
             fixture / "modules/migration/evidence.py"),
            (migration.parents[1] / "modules/migration/secret_input.py",
             fixture / "modules/migration/secret_input.py"),
        ):
            shutil.copy2(original, target)
        bootstrap = fixture / "bootstrap.sh"
        bootstrap.write_text(
            '#!/bin/bash\n'
            'case "$1" in\n'
            '  --discover) cp -R seed/generated/. "$BLUEPRINT_GENERATED_DIR/" ;;\n'
            '  --blueprint) cp seed/blueprint.conf "$BLUEPRINT_FILE" ;;\n'
            '  --dry-run) [[ -f "$BLUEPRINT_FILE" && -d "$BLUEPRINT_GENERATED_DIR" ]] ;;\n'
            '  *) exit 2 ;;\n'
            'esac\n')
        bootstrap.chmod(0o700)
        command = ["bash", "-c", 'source modules/bundle/commands.sh; '
                   'info(){ :; }; warning(){ :; }; error(){ :; }; success(){ :; }; '
                   'bundle_capture']
        # ssh-keygen may prompt on the controlling PTY instead of the wrapper's
        # stderr pipe; both forms must still request the key passphrase once.
        status, transcript = self.run_pty(
            command, [(b"Select SSH identities for encrypted", b"y"),
                      (b"Select numbers", b"1"),
                      (b"Type export", b"export"),
                      ((b"SSH key passphrase:", b'/identity": '), key_phrase),
                      (b"Enter passphrase", age_phrase),
                      (b"Confirm passphrase", age_phrase)],
            cwd=fixture, env=dict(os.environ, HOME=str(source_home),
                                  TMPDIR=str(fixture / "private-tmp")))
        self.assertEqual(status, 0)
        self.assertEqual(transcript.count(b"SSH key passphrase:") +
                         transcript.count(b'/identity": '), 1)
        self.assertNotIn(key_phrase, transcript)
        self.assertNotIn(age_phrase, transcript)
        output = list((fixture / "exports").glob("*.mbt"))
        self.assertEqual(len(output), 1)
        self.assertEqual(output[0].stat().st_mode & 0o777, 0o600)
        self.assertIn("secure.age", bundle.validate_archive(output[0]))
        self.assertNotIn(age_phrase, output[0].read_bytes())
        self.assertFalse(list((fixture / "private-tmp").glob("mbt-bundle.*")))
        output[0].rename(fixture / "manual-fixture.mbt")
        status, autogenerated_transcript = self.run_pty(
            command, [(b"Select SSH identities for encrypted", b"y"),
                      (b"Select numbers", b"1"),
                      (b"Type export", b"export"),
                      ((b"SSH key passphrase:", b'/identity": '), key_phrase),
                      (b"Enter passphrase", b"")],
            cwd=fixture, env=dict(os.environ, HOME=str(source_home),
                                  TMPDIR=str(fixture / "private-tmp")))
        self.assertEqual(status, 0)
        self.assertEqual(autogenerated_transcript.count(b"SSH key passphrase:") +
                         autogenerated_transcript.count(b'/identity": '), 1)
        generated_lines = [line for line in autogenerated_transcript.splitlines()
                           if b"using autogenerated" in line]
        self.assertEqual(len(generated_lines), 1)
        self.assertIn(b"Save it separately from the Bundle", autogenerated_transcript)
        generated_phrase = generated_lines[0].split()[-1]
        self.assertGreater(len(generated_phrase), 20)
        output = list((fixture / "exports").glob("*.mbt"))
        self.assertEqual(len(output), 1)
        archive = bundle.validate_archive(output[0])
        self.assertNotIn(generated_phrase, output[0].read_bytes())
        self.assertNotIn(generated_phrase, archive["blueprint.conf"])
        self.assertFalse((fixture / "logs").exists())
        self.assertFalse(list((fixture / "private-tmp").glob("mbt-bundle.*")))

    def test_restore_preview_plans_missing_homebrew_only_in_context(self):
        root = MODULE.parents[2]
        script = r'''
            source modules/apps/brew-packages.sh
            source modules/apps/brew-casks.sh
            command() {
                [[ "$*" != "-v brew" ]] || return 1
                builtin command "$@"
            }
            blueprint_exists() { return 0; }
            blueprint_selected_items() { echo selected; }
            blueprint_item_selected() { [[ "$2" == selected ]]; }
            blueprint_generated_file() { echo ignored; }
            read_brew_packages_configuration() { echo selected; }
            read_brew_casks_configuration() { echo selected; }
            preview_action() { printf '%s\n' "$1"; }
            error() { printf 'ERROR: %s\n' "$1"; }
            BUNDLE_RESTORE_PREVIEW=true
            preview_brew_packages || exit 3
            preview_brew_casks || exit 4
            unset BUNDLE_RESTORE_PREVIEW
            preview_brew_packages && exit 5
            [[ $? -eq 2 ]] || exit 6
        '''
        result = subprocess.run(["bash", "-c", script], text=True, capture_output=True,
                                cwd=root, check=False)
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        self.assertIn("Would install Homebrew formula after setup: selected", result.stdout)
        self.assertIn("Would install Homebrew cask after setup: selected", result.stdout)
        self.assertIn("ERROR: Homebrew is not installed", result.stdout)


class TopologyTests(unittest.TestCase):
    """Phase 1 contracts: inert metadata fixtures, no Git repositories/mutations."""
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.stage = self.root / 'stage'
        self.stage.mkdir(mode=0o700)
        self.archive = self.root / 'topology.mbt'
        self.contract = bundle.workspace_contract()
        self.paths = ['Projects/base', 'Projects/team/demo', 'Projects/other/demo']
        self.ids = [self.contract.identity('checkout', path) for path in self.paths]
        self.topology = dict(contract=1, roots=['Projects'], groups=[dict(
            id=self.contract.identity('repository', self.paths[0]), base_item_id=self.ids[0],
            object_format='sha1', members=[dict(item_id=item, head_kind=kind, head_oid='a' * 40)
                for item, kind in zip(self.ids, ['branch', 'branch', 'detached'])])])
        self.records = self.repository_data()
        self.blueprint = self.selection(self.ids)
        self.files = {'blueprint.conf': self.blueprint,
                      self.contract.REPOSITORIES: self.records,
                      'generated/workspace/folders.conf': b'Projects|workspace\n'}
        self.sync_topology()

    def selection(self, ids, workspaces=None):
        result = ('[categories]\n' + ''.join(f'{key}="false"\n' for key in bundle.CATEGORY_FLAGS) +
                  ''.join(f'\n[{key}]\n' + ('\n'.join(ids) + '\n' if key == 'git-repositories' else
                           'Projects\n' if key == 'workspace-folders' else '') for key in bundle.ITEMS))
        if workspaces is not None:
            result += '\n[vscode-workspaces]\n' + '\n'.join(workspaces) + '\n'
        return result.encode()

    def repository_data(self):
        output = ''
        for index, (item, path) in enumerate(zip(self.ids, self.paths)):
            branch = ('main', 'feature/test', '')[index]
            output += (f'[{item}]\nNAME="{Path(path).name}"\nPATH="~/{path}"\n'
                       f'REMOTE="https://example.invalid/team/repo.git"\n'
                       f'CURRENT_BRANCH="{branch}"\nDEFAULT_BRANCH="main"\nTOPOLOGY_VERSION="1"\n')
            output += ''.join(f'{key}="false"\n' for key in ('HAS_UNCOMMITTED_CHANGES',
                'HAS_VSCODE_FOLDER', 'HAS_SETTINGS', 'HAS_TASKS', 'HAS_LAUNCH', 'HAS_EXTENSIONS')) + '\n'
        return output.encode()

    def sync_topology(self):
        self.files[self.contract.TOPOLOGY] = (json.dumps(self.topology) + '\n').encode()

    def stage_files(self):
        for name, content in self.files.items():
            path = self.stage / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(content.replace(b'PATH="~/', b'PATH="/Users/source/')
                             if name == self.contract.REPOSITORIES else content)

    def pack(self):
        self.stage_files()
        bundle.pack(self.stage, self.archive, '/Users/source', apply_precedence=False)

    def rewrite_archive(self, update):
        with tarfile.open(self.archive) as source:
            files = {member.name: source.extractfile(member).read() for member in source.getmembers()}
        update(files)
        with tarfile.open(self.archive, 'w', format=tarfile.USTAR_FORMAT) as target:
            for name, data in sorted(files.items()):
                member = tarfile.TarInfo(name)
                member.size, member.mode = len(data), 0o600
                target.addfile(member, io.BytesIO(data))

    def test_schema_multiple_worktrees_duplicate_basenames_and_stable_ids(self):
        self.assertEqual(bundle.validate_workspace(self.files, exact=True), {'workspace-topology': 1})
        records = self.contract.repository_records(self.records)
        self.assertEqual([records[item]['name'] for item in self.ids], ['base', 'demo', 'demo'])
        self.assertEqual(len(set(self.ids)), 3)
        absolute = dict(self.files, **{self.contract.REPOSITORIES:
                        self.records.replace(b'PATH="~/', b'PATH="/Users/another/')})
        self.assertEqual(bundle.validate_workspace(absolute, home='/Users/another'), {'workspace-topology': 1})
        self.assertEqual(self.ids, [self.contract.identity('checkout', path) for path in self.paths])
        reversed_topology = json.loads(self.files[self.contract.TOPOLOGY])
        reversed_topology['groups'][0]['members'].reverse()
        reversed_files = dict(self.files, **{self.contract.TOPOLOGY: json.dumps(reversed_topology).encode()})
        self.assertEqual(bundle.validate_workspace(reversed_files), {'workspace-topology': 1})
        self.assertEqual(self.contract.identity('checkout', 'Projects/café'),
                         self.contract.identity('checkout', 'Projects/cafe\u0301'))

    def test_named_and_detached_heads_do_not_relax_legacy_consumer(self):
        self.stage_files()
        path = self.stage / self.contract.REPOSITORIES
        command = 'source modules/discovery/workspace.sh; workspace_validate_repositories "$1"'
        result = subprocess.run(['bash', '-c', command, 'test', str(path)], cwd=MODULE.parents[2], capture_output=True)
        self.assertEqual(result.returncode, 2)
        for kind, oid, branch in [('branch', 'a' * 40, ''), ('detached', '', ''),
                                  ('detached', 'a' * 40, 'main'), ('detached', '0' * 40, ''),
                                  ('branch', 'a' * 40, '@{-1}')]:
            with self.subTest(kind=kind, oid=oid, branch=branch):
                variant = json.loads(self.files[self.contract.TOPOLOGY])
                variant['groups'][0]['members'][2].update(head_kind=kind, head_oid=oid)
                files = dict(self.files, **{self.contract.TOPOLOGY: json.dumps(variant).encode(),
                    self.contract.REPOSITORIES: self.records.replace(b'CURRENT_BRANCH=""', f'CURRENT_BRANCH="{branch}"'.encode())})
                with self.assertRaises(bundle.Invalid):
                    bundle.validate_workspace(files)
        self.topology['groups'][0]['object_format'] = 'sha256'
        for member in self.topology['groups'][0]['members']:
            member['head_oid'] = 'b' * 64
        self.sync_topology()
        self.assertTrue(bundle.validate_workspace(self.files))

    def test_missing_unselected_base_and_selection_narrowing(self):
        for selection in (self.ids[1:], [self.ids[1]], self.ids + ['absent'], self.ids + [self.ids[0]]):
            with self.subTest(selection=selection), self.assertRaises(bundle.Invalid):
                bundle.validate_workspace(dict(self.files, **{'blueprint.conf': self.selection(selection)}))
        self.files['blueprint.conf'] = self.selection(self.ids[:2])
        self.files[self.contract.REPOSITORIES] = self.records.replace(
            b'HAS_UNCOMMITTED_CHANGES="false"', b'HAS_UNCOMMITTED_CHANGES="true"', 1)
        bundle.validate_workspace(self.files)
        narrowed = dict(self.files)
        sections, _ = bundle.parse_blueprint(narrowed['blueprint.conf'])
        self.contract.selected_payload(narrowed, sections)
        self.assertTrue(bundle.validate_workspace(narrowed, exact=True))
        original_records = self.contract.repository_records(self.files[self.contract.REPOSITORIES])
        self.assertEqual(self.contract.repository_records(narrowed[self.contract.REPOSITORIES]),
                         {item: original_records[item] for item in self.ids[:2]})
        self.assertIn(b'HAS_UNCOMMITTED_CHANGES="true"', narrowed[self.contract.REPOSITORIES])
        # Pack the full three-checkout inventory, not the already narrowed copy.
        self.pack()
        # validate_archive always enforces validate_workspace(exact=True).
        archived = bundle.validate_archive(self.archive)
        self.assertTrue(bundle.validate_workspace(archived, exact=True))
        self.assertEqual(archived[self.contract.REPOSITORIES], narrowed[self.contract.REPOSITORIES])
        for files in (narrowed, archived):
            self.assertNotIn(self.ids[2].encode(), b''.join(files.values()))
            self.assertNotIn(self.paths[2].encode(), b''.join(files.values()))
        rejected = dict(self.files)
        with self.assertRaises(self.contract.Invalid):
            self.contract.selected_payload(rejected, dict(sections, **{'git-repositories': self.ids[1:]}))
        self.assertEqual(rejected, self.files)
        self.topology['groups'][0]['base_item_id'] = 'absent'
        self.sync_topology()
        with self.assertRaises(bundle.Invalid):
            bundle.validate_workspace(self.files)

    def test_paths_roots_nested_dependencies_and_aliases(self):
        for path in ('/outside/demo', '~/../demo', '~/Projects//demo', '~/Projects/.git/demo',
                     '~/Elsewhere/demo', '~/Projects/BASE'):
            with self.subTest(path=path), self.assertRaises(bundle.Invalid):
                files = dict(self.files, **{self.contract.REPOSITORIES:
                    self.records.replace(b'~/Projects/team/demo', path.encode())})
                bundle.validate_workspace(files)
        with self.assertRaises(self.contract.Invalid):
            self.contract.aliases(['Projects/demo', 'Projects/DEMO'])
        with self.assertRaises(self.contract.Invalid):
            self.contract.aliases(['Projects/café', 'Projects/cafe\u0301'])
        # Legitimate nested linked destination has an explicit base dependency.
        self.paths[1] = 'Projects/base/trees/demo'
        self.ids[1] = self.contract.identity('checkout', self.paths[1])
        self.topology['groups'][0]['members'][1]['item_id'] = self.ids[1]
        self.files[self.contract.REPOSITORIES] = self.repository_data()
        self.files['blueprint.conf'] = self.selection(self.ids)
        self.sync_topology()
        self.assertTrue(bundle.validate_workspace(self.files))
        # Making the child the base creates a path/common-repository cycle.
        self.topology['groups'][0].update(base_item_id=self.ids[1],
            id=self.contract.identity('repository', self.paths[1]))
        self.sync_topology()
        with self.assertRaises(bundle.Invalid):
            bundle.validate_workspace(self.files)

    def test_target_filesystem_aliases_errors_and_no_mutation(self):
        home = self.root / 'home'
        (home / 'Projects/real').mkdir(parents=True)
        (home / 'Projects/link').symlink_to(home / 'Projects/real')
        sentinel = home / 'Projects/real/user-file'
        sentinel.write_bytes(b'preserve tracked staged untracked ignored')
        def snapshot():
            return [(str(path.relative_to(home)), path.lstat().st_mode, path.lstat().st_ino,
                     os.readlink(path) if path.is_symlink() else path.read_bytes() if path.is_file() else None)
                    for path in sorted(home.rglob('*'))]
        before = snapshot()
        for path in ('Projects/link/demo', 'Projects/real/user-file/nested'):
            with self.assertRaises(self.contract.Invalid):
                self.contract.target_paths([path], home)
        with patch.object(self.contract.os, 'access', return_value=False), self.assertRaises(self.contract.Invalid):
            self.contract.target_paths(['Projects/missing'], home)
        with patch.object(self.contract.Path, 'lstat', side_effect=PermissionError()), self.assertRaises(OSError):
            self.contract.target_paths(['Projects/missing'], home)
        self.assertEqual(snapshot(), before)

    def test_folder_checkout_roles_remain_in_selected_bundle(self):
        folders = '\n'.join(self.paths) + '\n'
        self.files['blueprint.conf'] = self.selection(self.ids).replace(b'Projects\n', folders.encode())
        self.files['generated/workspace/folders.conf'] = ''.join(path + '|workspace\n' for path in self.paths).encode()
        home = self.root / 'home'
        for path in self.paths:
            (home / path).mkdir(parents=True)
        before = bundle.fingerprint(home)
        # Base, linked and detached checkouts may each also be structural folders.
        self.assertTrue(bundle.validate_workspace(self.files, home=home, exact=True, inspect_home=True))
        missing_base = dict(self.files, **{'blueprint.conf': self.selection(self.ids[1:]).replace(b'Projects\n', folders.encode())})
        with self.assertRaises(bundle.WorkspaceSelectionInvalid) as failure:
            bundle.validate_workspace(missing_base)
        self.assertEqual(failure.exception.code, 'workspace_dependency_missing')
        self.pack()
        archived = bundle.validate_archive(self.archive)
        sections, _ = bundle.parse_blueprint(archived['blueprint.conf'])
        self.assertEqual(sections['workspace-folders'], self.paths)
        self.assertEqual(sections['git-repositories'], self.ids)
        self.assertEqual(archived['generated/workspace/folders.conf'], self.files['generated/workspace/folders.conf'])
        self.assertEqual(set(self.contract.repository_records(archived[self.contract.REPOSITORIES])), set(self.ids))
        self.assertEqual(json.loads(archived[self.contract.TOPOLOGY]), self.topology)
        self.assertEqual(bundle.inspect_bundle(self.archive, str(home))['selected_item_counts']['workspace-folders'], 3)
        self.assertEqual(bundle.fingerprint(home), before)

    def test_folder_structure_does_not_require_unselected_git_dependencies(self):
        folders = [self.paths[1], self.paths[0] + '/structure']
        self.files['generated/workspace/folders.conf'] = ''.join(path + '|workspace\n' for path in folders).encode()
        for ids in ([], self.ids[:1]):
            with self.subTest(selected_git=len(ids)):
                self.files['blueprint.conf'] = self.selection(ids).replace(b'Projects\n', ('\n'.join(folders) + '\n').encode())
                self.assertTrue(bundle.validate_workspace(self.files))
                self.archive = self.root / f'folder-structure-{len(ids)}.mbt'
                self.pack()
                archived = bundle.validate_archive(self.archive)
                sections, _ = bundle.parse_blueprint(archived['blueprint.conf'])
                self.assertEqual(sections['workspace-folders'], folders)
                self.assertEqual(sections['git-repositories'], ids)
                self.assertEqual(self.contract.TOPOLOGY in archived, bool(ids))
                self.assertEqual(bundle.inspect_bundle(self.archive, str(self.root))['selected_item_counts']['git-repositories'], len(ids))
        workspace_id = self.contract.identity('workspace', 'Projects/folders.code-workspace')
        relationship = dict(domain='workspace-folders', item_id=folders[0], subpath='')
        descriptor = dict(contract=1, items=[dict(item_id=workspace_id, path='~/Projects/folders.code-workspace',
                                                folders=[relationship])])
        files = dict(self.files, **{'blueprint.conf': self.selection([], [workspace_id]).replace(
            b'Projects\n', ('\n'.join(folders) + '\n').encode()), self.contract.VSCODE: json.dumps(descriptor).encode()})
        self.assertTrue(bundle.validate_workspace(files))
        # Choosing the folder role does not implicitly fulfill a Git reference.
        relationship.update(domain='git-repositories', item_id=self.ids[1])
        files[self.contract.VSCODE] = json.dumps(descriptor).encode()
        with self.assertRaises(bundle.WorkspaceSelectionInvalid) as failure:
            bundle.validate_workspace(files)
        self.assertEqual(failure.exception.code, 'workspace_dependency_missing')

    def test_role_overlap_does_not_mask_real_destination_conflicts(self):
        for folders in (['Projects/BASE'], ['Projects/base', 'Projects/BASE']):
            with self.subTest(folders=folders):
                files = dict(self.files, **{
                    'blueprint.conf': self.selection(self.ids).replace(b'Projects\n', ('\n'.join(folders) + '\n').encode()),
                    'generated/workspace/folders.conf': ''.join(path + '|workspace\n' for path in folders).encode()})
                with self.assertRaises(bundle.WorkspaceSelectionInvalid) as failure:
                    bundle.validate_workspace(files)
                self.assertEqual(failure.exception.code, 'workspace_path_conflict')
        # Different checkout identities cannot occupy case aliases or one path.
        for path in ('Projects/BASE', 'Projects/base'):
            with self.subTest(checkout=path):
                self.paths[1] = path
                self.ids[1] = self.contract.identity('checkout', path)
                self.topology['groups'][0]['members'][1]['item_id'] = self.ids[1]
                self.files[self.contract.REPOSITORIES] = self.repository_data()
                self.files['blueprint.conf'] = self.selection(self.ids)
                self.sync_topology()
                with self.assertRaises(bundle.Invalid):
                    bundle.validate_workspace(self.files)

    def test_role_overlap_keeps_filesystem_alias_and_symlink_guards(self):
        self.files['blueprint.conf'] = self.selection(self.ids).replace(b'Projects\n', b'Projects/base\n')
        self.files['generated/workspace/folders.conf'] = b'Projects/base|workspace\n'
        home = self.root / 'home'
        for path in self.paths:
            (home / path).mkdir(parents=True)
        self.assertTrue(bundle.validate_workspace(self.files, home=home, inspect_home=True))
        before = bundle.fingerprint(home)
        original_lstat = Path.lstat
        base_info = (home / self.paths[0]).lstat()
        def aliased_lstat(path):
            return base_info if path == home / self.paths[1] else original_lstat(path)
        with patch.object(Path, 'lstat', aliased_lstat), self.assertRaises(bundle.Invalid):
            bundle.validate_workspace(self.files, home=home, inspect_home=True)
        self.assertEqual(bundle.fingerprint(home), before)
        (home / self.paths[0]).rmdir()
        (home / self.paths[0]).symlink_to(home / self.paths[1])
        for ids in (self.ids, []):
            files = dict(self.files, **{'blueprint.conf': self.selection(ids).replace(b'Projects\n', b'Projects/base\n')})
            with self.assertRaises(bundle.Invalid):
                bundle.validate_workspace(files, home=home, inspect_home=True)

    def test_malformed_topology_no_secret_or_machine_fields(self):
        changes = [lambda t: t.update(common_dir='/private/git'),
                   lambda t: t.update(contract=2), lambda t: t.update(contract=True),
                   lambda t: t['groups'][0].update(ino=123),
                   lambda t: t['groups'][0]['members'].append(t['groups'][0]['members'][0]),
                   lambda t: t['groups'][0]['members'].pop(),
                   lambda t: t['groups'].append(t['groups'][0])]
        for index, change in enumerate(changes):
            with self.subTest(index=index):
                topology = json.loads(self.files[self.contract.TOPOLOGY])
                change(topology)
                with self.assertRaises(bundle.Invalid):
                    bundle.validate_workspace(dict(self.files, **{self.contract.TOPOLOGY: json.dumps(topology).encode()}))
        for data in (b'{', b'{"contract":1,"contract":1}', b'[]', b'x' * (self.contract.MAX_BYTES + 1)):
            with self.assertRaises(bundle.Invalid):
                bundle.validate_workspace(dict(self.files, **{self.contract.TOPOLOGY: data}))
        for remote in ('https://token@example.invalid/repo', 'https://example.invalid/repo?token=private',
                       'ssh://user:private@example.invalid/repo', '/Users/source/private.git'):
            with self.assertRaises(bundle.Invalid):
                bundle.validate_workspace(dict(self.files, **{self.contract.REPOSITORIES:
                    self.records.replace(b'https://example.invalid/team/repo.git', remote.encode())}))

    def test_sectional_values_are_data_and_missing_git_cannot_prompt(self):
        sentinel = self.root / 'must-not-exist'
        files = dict(self.files, **{self.contract.REPOSITORIES:
            self.records.replace(b'NAME="base"', ('NAME="$(touch ' + str(sentinel) + ')"').encode())})
        self.assertTrue(bundle.validate_workspace(files))
        self.assertFalse(sentinel.exists())
        # A real PATH containing only the Config Engine tools: no Git or xcode-select.
        bin_dir = self.root / 'bin'
        bin_dir.mkdir()
        for command in ('dirname', 'awk', 'grep', 'sed', 'cat'):
            (bin_dir / command).symlink_to(shutil.which(command))
        with patch.dict(os.environ, PATH=str(bin_dir)), \
                patch.object(self.contract, 'git_executable', side_effect=AssertionError('native Git probe')) as probe, \
                patch.object(self.contract.subprocess, 'run', wraps=subprocess.run) as run:
            self.assertIsNone(shutil.which('git'))
            self.pack()
            self.assertEqual(bundle.validate_workspace(bundle.validate_archive(self.archive), exact=True),
                             {'workspace-topology': 1})
            probe.assert_not_called()
            self.assertTrue(run.call_args_list)
            self.assertTrue(all(call.args[0][:2] == ['/bin/bash', str(self.contract.BRIDGE)]
                                for call in run.call_args_list))
        with patch.dict(os.environ, PATH=str(bin_dir)), self.assertRaises(self.contract.Unsupported):
            self.contract.branch_valid('main')
        for branch in ('feature/topic', 'release/v1.2', 'ветка', 'refs/heads/topic'):
            self.contract.branch_metadata_valid(branch)
        for branch in ('', 'HEAD', '@', '@{-1}', '-option', 'a..b', 'a@{b', '.hidden', 'a/.b',
                       'a.lock', 'a.lock/b', '/a', 'a/', 'a//b', 'a.', 'a b', 'a\tb', 'a\x7fb',
                       'a~b', 'a^b', 'a:b', 'a?b', 'a*b', 'a[b', 'a\\b', 'a"b'):
            with self.subTest(branch=branch), self.assertRaises(self.contract.Invalid):
                self.contract.branch_metadata_valid(branch)
        # Native readiness still rejects a syntactically valid name if Git does.
        with patch.object(self.contract, 'git_executable', return_value='/qualified/git'), \
                patch.object(self.contract.subprocess, 'run', return_value=
                    subprocess.CompletedProcess([], 1, b'', b'')) as run, \
                self.assertRaises(self.contract.Invalid):
            self.contract.branch_valid('main')
        run.assert_called_once_with(['/qualified/git', 'check-ref-format', '--branch', 'main'],
                                    capture_output=True, timeout=10)
        with patch.object(self.contract.shutil, 'which', return_value='/usr/bin/git'), \
                patch.object(self.contract.subprocess, 'run', return_value=
                    subprocess.CompletedProcess([], 1, b'', b'')) as run:
            with self.assertRaises(self.contract.Unsupported):
                self.contract.git_executable()
            self.assertEqual([call.args[0] for call in run.call_args_list], [['xcode-select', '-p']])

    def test_topology_markers_cannot_downgrade_to_legacy(self):
        files = dict(self.files)
        files.pop(self.contract.TOPOLOGY)
        with self.assertRaises(bundle.Invalid):
            bundle.validate_workspace(files)
        files = dict(self.files, **{self.contract.REPOSITORIES: self.records.replace(b'TOPOLOGY_VERSION="1"\n', b'')})
        with self.assertRaises(bundle.Invalid):
            bundle.validate_workspace(files)
        files = dict(self.files, **{self.contract.REPOSITORIES: self.records.replace(b'TOPOLOGY_VERSION="1"', b'TOPOLOGY_VERSION="2"')})
        with self.assertRaises(bundle.Invalid):
            bundle.validate_workspace(files)

    def test_bundle_v1_extension_checksums_capabilities_and_old_allowlist(self):
        self.pack()
        files = bundle.validate_archive(self.archive)
        self.assertEqual(bundle.validate_workspace(files, exact=True), {'workspace-topology': 1})
        with tarfile.open(self.archive) as archive:
            manifest = json.load(archive.extractfile('manifest.json'))
        self.assertEqual(manifest['version'], 1)
        self.assertEqual(manifest['required_features'], {'workspace-topology': 1})
        self.assertNotIn(b'/Users/source', b''.join(files.values()))
        with patch.object(bundle, 'WORKSPACE_EXTENSIONS', {}), self.assertRaisesRegex(bundle.Invalid, 'unexpected Bundle entry'):
            bundle.validate_archive(self.archive)
        def corrupt(files):
            files[self.contract.TOPOLOGY] += b' '
        self.rewrite_archive(corrupt)
        with self.assertRaisesRegex(bundle.Invalid, 'integrity'):
            bundle.validate_archive(self.archive)

    def test_required_capabilities_and_limits_are_enforced(self):
        self.pack()
        original = self.archive.read_bytes()
        for features in ({}, {'workspace-topology': 2}, {'unknown': 1}, {'workspace-topology': True}):
            self.archive.write_bytes(original)
            def update(files):
                manifest = json.loads(files['manifest.json'])
                manifest['required_features'] = features
                files['manifest.json'] = json.dumps(manifest).encode()
            self.rewrite_archive(update)
            with self.subTest(features=features), self.assertRaises(bundle.Invalid):
                bundle.validate_archive(self.archive)
        self.archive.write_bytes(original)
        with patch.object(bundle, 'MAX_ENTRIES', 2), self.assertRaises(bundle.Invalid):
            bundle.validate_archive(self.archive)
        with patch.object(self.contract, 'MAX_ITEMS', 2), self.assertRaises(bundle.Invalid):
            bundle.validate_archive(self.archive)

    def test_runtime_unpack_inspect_publish_and_grouped_publication_remain_closed(self):
        self.pack()
        target = self.root / 'target'
        target.mkdir()
        before = bundle.fingerprint(target)
        with self.assertRaises(bundle.Unsupported):
            bundle.unpack(self.archive, target, '/Users/target')
        self.assertEqual(bundle.inspect_bundle(self.archive, '/Users/target')['selected_item_counts']['git-repositories'], 3)
        self.assertEqual(bundle.fingerprint(target), before)
        with patch.object(bundle, 'recover') as recover, self.assertRaises(bundle.Unsupported):
            bundle.publish(self.stage)
        recover.assert_not_called()
        before_stage = bundle.fingerprint(self.stage)
        with self.assertRaises(bundle.Unsupported):
            bundle.narrow(self.stage, ['Workspace'])
        self.assertEqual(bundle.fingerprint(self.stage), before_stage)
        command = ('source modules/discovery/workspace.sh; error() { :; }; '
                   'workspace_publish_snapshot "$1" "$2"')
        result = subprocess.run(['bash', '-c', command, 'test',
                                 str(self.stage / 'generated/workspace'), str(target)],
                                cwd=MODULE.parents[2], capture_output=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(bundle.fingerprint(target), before)

    def test_protocol_allows_preview_but_rejects_stale_identity_before_target_mutation(self):
        self.pack()
        spec = importlib.util.spec_from_file_location('topology_restore_fixture',
            MODULE.parents[2] / 'scripts/test-restore-prepare.py')
        fixtures = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(fixtures)
        fixture = fixtures.RestorePrepareTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        before = bundle.fingerprint(fixture.home)
        config_before = bundle.fingerprint(fixture.project / 'config')
        result, events = fixture.invoke(path=self.archive)
        self.assertEqual(result.returncode, 0, events)
        self.assertNotIn('workspace_restore_not_enabled',
                         [row['code'] for row in events[1]['data']['readiness']['conditions']])
        result, events = fixture.execute('0' * 64, path=self.archive)
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])
        self.assertFalse((fixture.root / 'mutations').exists())
        self.assertEqual(bundle.fingerprint(fixture.home), before)
        self.assertEqual(bundle.fingerprint(fixture.project / 'config'), config_before)

    def test_invalid_pack_preserves_output_and_existing_state(self):
        self.pack()
        old = self.archive.read_bytes()
        self.topology['groups'][0]['base_item_id'] = 'missing'
        self.sync_topology()
        self.stage_files()
        before = bundle.fingerprint(self.stage)
        with self.assertRaises(bundle.Invalid):
            bundle.pack(self.stage, self.archive, '/Users/source', bundle.digest(old), apply_precedence=False)
        self.assertEqual(self.archive.read_bytes(), old)
        self.assertEqual(bundle.fingerprint(self.stage), before)
        self.assertFalse(list(self.root.glob('.bundle-*')))

    def test_vscode_relationships_are_separately_selected_and_metadata_only(self):
        path = 'Projects/team.code-workspace'
        item = self.contract.identity('workspace', path)
        workspace = dict(contract=1, items=[dict(item_id=item, path='~/' + path, folders=[
            dict(domain='git-repositories', item_id=self.ids[0], subpath='', name='Base'),
            dict(domain='git-repositories', item_id=self.ids[1], subpath='src', name='Feature')])])
        self.files[self.contract.VSCODE] = json.dumps(workspace).encode()
        self.files['blueprint.conf'] = self.selection(self.ids, [item])
        self.assertEqual(bundle.validate_workspace(self.files), {'workspace-topology': 1, 'vscode-workspaces': 1})
        self.pack()
        self.assertIn(self.contract.VSCODE, bundle.validate_archive(self.archive))
        for change in (lambda w: w['items'][0].update(tasks={'command': 'private'}),
                       lambda w: w['items'][0]['folders'][0].update(subpath='../private'),
                       lambda w: w['items'][0]['folders'][0].update(item_id='missing')):
            value = json.loads(self.files[self.contract.VSCODE])
            change(value)
            with self.assertRaises(bundle.Invalid):
                bundle.validate_workspace(dict(self.files, **{self.contract.VSCODE: json.dumps(value).encode()}))
        with self.assertRaises(bundle.Invalid):
            bundle.validate_workspace(dict(self.files, **{'blueprint.conf': self.selection([self.ids[0]], [item])}))

    def test_vscode_folder_only_capability_and_no_implicit_selection(self):
        item = self.contract.identity('workspace', 'Projects/folders.code-workspace')
        files = {'blueprint.conf': self.selection([], [item]),
                 'generated/workspace/folders.conf': b'Projects|workspace\n',
                 self.contract.VSCODE: json.dumps(dict(contract=1, items=[dict(item_id=item,
                    path='~/Projects/folders.code-workspace', folders=[dict(
                        domain='workspace-folders', item_id='Projects', subpath='', name='Projects')])])).encode()}
        self.assertEqual(bundle.validate_workspace(files, exact=True), {'vscode-workspaces': 1})
        self.files = dict(files)
        self.pack()
        self.assertIn(self.contract.VSCODE, bundle.validate_archive(self.archive))
        self.assertEqual(bundle.inspect_bundle(self.archive, '/Users/target')['format_version'], 1)
        files['blueprint.conf'] = self.selection([])
        bundle.selected_payload(files, files['blueprint.conf'])
        self.assertNotIn(self.contract.VSCODE, files)
        self.assertEqual(bundle.validate_workspace(files, exact=True), {})
        # No optional section and an empty section both produce usable legacy Bundles.
        (self.stage / self.contract.VSCODE).unlink()
        for index, selection in enumerate((None, [])):
            with self.subTest(selection=selection):
                self.archive = self.root / f'empty-{index}.mbt'
                self.files = dict(files, **{'blueprint.conf': self.selection([], selection)})
                self.pack()
                archived = bundle.validate_archive(self.archive)
                sections, _ = bundle.parse_blueprint(archived['blueprint.conf'])
                self.assertNotIn('vscode-workspaces', sections)
                self.assertNotIn(self.contract.VSCODE, archived)
                if selection is None:
                    self.assertEqual(archived['blueprint.conf'], self.files['blueprint.conf'])
                self.assertEqual((self.stage / 'blueprint.conf').read_bytes(), self.files['blueprint.conf'])
                self.assertEqual(bundle.inspect_bundle(self.archive, '/Users/target')['format_version'], 1)
        # Already packed empty sections are accepted after integrity verification,
        # then omitted from unpacked Blueprint syntax for the legacy consumer.
        def empty_section(archived):
            archived['blueprint.conf'] += b'\n[vscode-workspaces]\n# no selected descriptors\n'
            manifest = json.loads(archived['manifest.json'])
            data = archived['blueprint.conf']
            manifest['files']['blueprint.conf'] = dict(size=len(data), sha256=bundle.digest(data))
            archived['manifest.json'] = json.dumps(manifest).encode()
        self.rewrite_archive(empty_section)
        self.assertEqual(bundle.inspect_bundle(self.archive, '/Users/target')['format_version'], 1)
        restored = self.root / 'restored'
        restored.mkdir()
        bundle.unpack(self.archive, restored, '/Users/target')
        self.assertNotIn(b'[vscode-workspaces]', (restored / 'blueprint.conf').read_bytes())
        # A nonempty selection without its sidecar fails before publication.
        self.files['blueprint.conf'] = self.selection([], [item])
        self.archive = self.root / 'missing-sidecar.mbt'
        self.stage_files()
        before = bundle.fingerprint(self.stage)
        with self.assertRaises(bundle.Invalid):
            bundle.pack(self.stage, self.archive, '/Users/source', apply_precedence=False)
        self.assertFalse(self.archive.exists())
        self.assertEqual(bundle.fingerprint(self.stage), before)

    def test_legacy_blueprint_and_sectional_selection_are_unchanged(self):
        sections, _ = bundle.parse_blueprint(blueprint())
        self.assertNotIn('vscode-workspaces', sections)
        self.assertEqual(sections['git-repositories'], ['demo'])
        legacy = dict(self.files)
        legacy.pop(self.contract.TOPOLOGY)
        legacy[self.contract.REPOSITORIES] = self.records.replace(b'TOPOLOGY_VERSION="1"\n', b'')
        self.assertEqual(bundle.validate_workspace(legacy), {})
        selection_file = self.root / 'selection.conf'
        selection_file.write_bytes(self.blueprint)
        command = ('source modules/blueprint/blueprint.sh; error() { :; }; '
                   'blueprint_validate_syntax "$1" || exit $?; blueprint_selected_items git-repositories "$1"')
        result = subprocess.run(['bash', '-c', command, 'test', str(selection_file)],
                                cwd=MODULE.parents[2], capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.decode().splitlines(), self.ids)

    def test_git_capability_detection_never_guesses_support_from_version(self):
        def result(output=b'', status=0):
            return subprocess.CompletedProcess([], status, output, b'')
        old, new = b'git version 2.24.4\n', b'git version 2.50.1 (Apple Git-155)\n'
        cases = [(old, old, b'    --porcelain\n', 'worktree_porcelain_z_unavailable'),
                 (new, new, b'    --porcelain\n', 'worktree_porcelain_z_unavailable'),
                 (old, new, b'    --porcelain\n    -z  NUL termination\n', 'git_version_changed'),
                 (new, new, b'    --porcelain\n    -z  NUL termination\n', 'worktree_porcelain_z'),
                 (b'unknown', b'unknown', b'', 'git_version_unavailable')]
        for before, after, help_output, reason in cases:
            with patch.object(self.contract.shutil, 'which', return_value='/qualified/git'), \
                    patch.object(self.contract.subprocess, 'run', side_effect=[
                    result(before), result(help_output, 129), result(after)]) as run:
                self.assertEqual(self.contract.detect_worktree_capability(),
                                 dict(status='supported' if reason == 'worktree_porcelain_z' else 'unsupported', reason=reason))
                self.assertEqual([call.args[0][1:] for call in run.call_args_list],
                                 [['--version'], ['worktree', 'list', '-h'], ['--version']])
        with patch.object(self.contract.subprocess, 'run', side_effect=FileNotFoundError()):
            self.assertEqual(self.contract.detect_worktree_capability()['reason'], 'git_observation_failed')


class WorkspaceDiscoveryTests(unittest.TestCase):
    """Native read-only Git observations in a disposable HOME."""
    def setUp(self):
        from workspace_fixture import repository, linked
        self.repository, self.linked = repository, linked
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.stage = self.root / 'stage'
        self.stage.mkdir()
        self.workspace = self.stage / 'generated/workspace'
        self.workspace.mkdir(parents=True)
        self.base, self.oid = repository(self.home)
        spec = importlib.util.spec_from_file_location('workspace_observer',
            MODULE.parents[2] / 'modules/discovery/workspace/topology.py')
        self.observer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.observer)
        environment = patch.dict(os.environ, HOME=str(self.home), MACSEED_WORKSPACE_ROOTS='')
        environment.start()
        self.addCleanup(environment.stop)

    def collect(self):
        (self.workspace / 'folders.conf').write_text('Projects|workspace\n')
        counts = self.observer.collect(self.home, self.workspace)
        self.observer.validate_stage(self.workspace)
        return counts

    def metadata(self):
        return json.loads((self.workspace / 'topology.json').read_text())

    def selection(self, ids):
        raw = ('[categories]\n' + ''.join(f'{name}="false"\n' for name in bundle.CATEGORY_FLAGS) +
               ''.join(f'\n[{name}]\n' + ('\n'.join(ids) + '\n' if name == 'git-repositories' else '')
                       for name in bundle.ITEMS))
        (self.stage / 'blueprint.conf').write_text(raw)

    def cli_fixture(self):
        # Satisfy unrelated read-only CLI prerequisites with inert fixture files.
        (self.home / '.ssh').mkdir(mode=0o700)
        (self.home / '.ssh/id_fixture.pub').write_text('fixture only\n')
        (self.home / '.ssh/config').write_text('')
        (self.home / '.zshrc').write_text('')
        project = self.root / 'project'
        project.mkdir()
        shutil.copytree(MODULE.parents[2] / 'modules', project / 'modules')
        shutil.copy2(MODULE.parents[2] / 'bootstrap.sh', project / 'bootstrap.sh')
        (project / 'config').mkdir()
        shutil.copy2(MODULE.parents[2] / 'config/toolkit.conf', project / 'config/toolkit.conf')
        binaries = self.root / 'bin'
        binaries.mkdir()
        native_git = self.observer.contract.git_executable()
        for name, body in (
                ('sw_vers', 'echo 26.7.1'), ('xcode-select', 'exit 0'), ('curl', 'exit 0'),
                ('brew', 'case "$*" in --prefix) echo /opt/homebrew ;; *) exit 0 ;; esac'),
                ('sudo', 'echo sudo >> "$TEST_MUTATIONS"; exit 99'),
                ('git', 'for arg in "$@"; do\ncase "$arg" in clone|fetch|checkout|switch|reset|clean|add|remove|prune|commit|update-ref) '
                 'echo git-mutation >> "$TEST_MUTATIONS"; exit 99 ;; esac\ndone\nexec "' + native_git + '" "$@"')):
            path = binaries / name
            path.write_text('#!/bin/bash\n' + body + '\n')
            path.chmod(0o700)
        env = dict(os.environ, HOME=str(self.home), SHELL='/bin/zsh', BLUEPRINT_GENERATED_DIR=str(self.stage / 'generated'),
                   BLUEPRINT_FILE=str(self.stage / 'blueprint.conf'), VERBOSE='false',
                   PATH=str(binaries) + os.pathsep + os.environ['PATH'], GIT_OPTIONAL_LOCKS='0',
                   TEST_MUTATIONS=str(self.root / 'mutations'))
        for name in ('BUNDLE_RESTORE_ACTIVE', 'BUNDLE_RESTORE_PREVIEW', 'MACSEED_APPLICATION_EXECUTION', 'BASH_ENV'):
            env.pop(name, None)
        return project, env

    def snapshot(self, project, env):
        return subprocess.run(['/bin/bash', '-c', '''source modules/discovery/workspace.sh
action() { :; }; success() { :; }; warning() { :; }; error() { echo "$*" >&2; }
export_workspace_snapshot
'''], cwd=project, env=env, capture_output=True)

    def test_discovery_blueprint_cli_preview_preserves_ordinary_repository_actions(self):
        project, env = self.cli_fixture()
        result = self.snapshot(project, env)
        self.assertEqual(result.returncode, 0, result.stderr)
        item = self.observer.contract.identity('checkout', 'Projects/base')
        self.selection([item])
        selected = subprocess.run(['/bin/bash', '-c', '''source modules/core/common/common.sh
source modules/core/config/config.sh
source modules/blueprint/blueprint.sh
source modules/blueprint/selector.sh
blueprint_validate || exit $?
blueprint_selector_load_items git-repositories || exit $?
blueprint_selected_items git-repositories
'''], cwd=project, env=env, capture_output=True)
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertIn(item.encode(), selected.stdout)
        before = bundle.fingerprint(self.home)
        workflow = subprocess.run(['./bootstrap.sh', '--workflow'], input=b'n\nq\n',
                                  cwd=project, env=env, capture_output=True)
        self.assertEqual(workflow.returncode, 0, workflow.stdout + workflow.stderr)
        self.assertIn(b'Refresh generated configuration', workflow.stdout)
        self.assertNotIn(b'Discovery is required', workflow.stdout)
        self.assertEqual(bundle.fingerprint(self.home), before)
        preview = subprocess.run(['./bootstrap.sh', '--dry-run'], cwd=project, env=env, capture_output=True)
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertNotIn(b'Would clone', preview.stdout)
        self.assertNotIn(b'Would switch', preview.stdout)
        self.assertEqual(bundle.fingerprint(self.home), before)
        # Exercise the existing Apply consumer only in its already-matching no-op case.
        apply = subprocess.run(['/bin/bash', '-c', '''source modules/core/common/common.sh
source modules/core/config/config.sh
source modules/blueprint/blueprint.sh
source modules/discovery/workspace.sh
source modules/bootstrap/workspace/workspace.sh
MODULE_CHANGED=false
bootstrap_workspace || exit $?
[[ "$MODULE_CHANGED" == false ]]
'''], cwd=project, env=env, capture_output=True)
        self.assertEqual(apply.returncode, 0, apply.stdout + apply.stderr)
        self.assertEqual(bundle.fingerprint(self.home), before)
        # Fixture-only metadata changes; Preview must preserve legacy planned actions.
        (self.base / '.git/refs/heads/feature').write_text(self.oid + '\n')
        (self.base / '.git/HEAD').write_text('ref: refs/heads/feature\n')
        before = bundle.fingerprint(self.home)
        preview = subprocess.run(['./bootstrap.sh', '--dry-run'], cwd=project, env=env, capture_output=True)
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertIn(b'Would switch repository branch:', preview.stdout)
        self.assertEqual(bundle.fingerprint(self.home), before)
        self.base.rename(self.root / 'saved-fixture-checkout')
        before = bundle.fingerprint(self.home)
        preview = subprocess.run(['./bootstrap.sh', '--dry-run'], cwd=project, env=env, capture_output=True)
        self.assertEqual(preview.returncode, 0, preview.stdout + preview.stderr)
        self.assertIn(b'Would clone repository:', preview.stdout)
        self.assertEqual(bundle.fingerprint(self.home), before)
        self.assertFalse((self.root / 'mutations').exists())

    def test_cli_linked_topology_refuses_before_any_workspace_mutation(self):
        self.linked(self.base, self.home / 'Projects/feature', self.oid)
        self.repository(self.home, 'Projects/independent')
        project, env = self.cli_fixture()
        self.assertEqual(self.snapshot(project, env).returncode, 0)
        identity = self.observer.contract.identity
        base, linked, independent = [identity('checkout', 'Projects/' + name)
                                     for name in ('base', 'feature', 'independent')]
        # An unselected linked group must not disable an independent ordinary group.
        self.selection([independent])
        result = subprocess.run(['./bootstrap.sh', '--dry-run'], cwd=project, env=env, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        with (self.workspace / 'folders.conf').open('a') as output:
            output.write('MustNotCreate|user\n')
        for selected in ([base, linked], [base], [linked]):
            with self.subTest(selected=selected):
                self.selection(selected)
                # Even a valid planned folder action must not run before repository admission.
                blueprint_file = self.stage / 'blueprint.conf'
                blueprint_file.write_text(blueprint_file.read_text().replace(
                    '[workspace-folders]\n', '[workspace-folders]\nMustNotCreate\n'))
                before = bundle.fingerprint(self.home)
                preview = subprocess.run(['./bootstrap.sh', '--dry-run'], cwd=project, env=env, capture_output=True)
                self.assertEqual(preview.returncode, 2, preview.stdout + preview.stderr)
                if base in selected:
                    self.assertIn(b'linked/shared worktrees', preview.stderr)
                else:
                    self.assertIn(b'Workspace topology validation failed', preview.stderr)
                apply = subprocess.run(['/bin/bash', '-c', '''source modules/core/common/common.sh
source modules/core/config/config.sh
source modules/blueprint/blueprint.sh
source modules/discovery/workspace.sh
source modules/bootstrap/workspace/workspace.sh
MODULE_CHANGED=false
bootstrap_workspace
result=$?
[[ "$MODULE_CHANGED" == false ]] || exit 99
exit "$result"
'''], cwd=project, env=env, capture_output=True)
                self.assertEqual(apply.returncode, 2, apply.stdout + apply.stderr)
                self.assertEqual(bundle.fingerprint(self.home), before)
        self.assertFalse((self.root / 'mutations').exists())

    def test_cli_topology_admission_keeps_schema_and_target_guards(self):
        project, env = self.cli_fixture()
        self.assertEqual(self.snapshot(project, env).returncode, 0)
        self.selection([self.observer.contract.identity('checkout', 'Projects/base')])
        topology_file = self.workspace / 'topology.json'
        records_file = self.workspace / 'repositories.conf'
        topology, records = topology_file.read_bytes(), records_file.read_bytes()
        for invalid in ('version', 'missing', 'detached', 'shared-target', 'linked-target'):
            with self.subTest(invalid=invalid):
                topology_file.write_bytes(topology)
                records_file.write_bytes(records)
                if invalid == 'version':
                    records_file.write_bytes(records.replace(b'TOPOLOGY_VERSION="1"', b'TOPOLOGY_VERSION="2"'))
                elif invalid == 'missing':
                    topology_file.unlink()
                elif invalid == 'detached':
                    value = json.loads(topology)
                    value['groups'][0]['members'][0]['head_kind'] = 'detached'
                    topology_file.write_text(json.dumps(value))
                    records_file.write_bytes(records.replace(b'CURRENT_BRANCH="main"', b'CURRENT_BRANCH=""'))
                elif invalid == 'shared-target':
                    self.linked(self.base, self.home / 'Projects/new-link', self.oid)
                else:
                    shutil.rmtree(self.base / '.git/worktrees')
                    (self.base / '.git').rename(self.root / 'saved-git')
                    (self.base / '.git').write_text('gitdir: ' + str(self.root / 'saved-git') + '\n')
                before = bundle.fingerprint(self.home)
                result = subprocess.run(['./bootstrap.sh', '--dry-run'], cwd=project, env=env, capture_output=True)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertNotIn(b'Would clone', result.stdout)
                self.assertNotIn(b'Would switch', result.stdout)
                self.assertEqual(bundle.fingerprint(self.home), before)
        self.assertFalse((self.root / 'mutations').exists())

    def test_descriptor_missing_folder_preserves_valid_independent_metadata(self):
        (self.home / 'Projects/good.code-workspace').write_text('{"folders":[{"path":"base","name":"Base"}]}')
        (self.home / 'Projects/bad.code-workspace').write_text('{"folders":[{"path":"confirmed-missing"}]}')
        project, env = self.cli_fixture()
        before = bundle.fingerprint(self.home)
        result = self.snapshot(project, env)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual(len(self.metadata()['groups']), 1)
        items = json.loads((self.workspace / 'vscode-workspaces.json').read_bytes())['items']
        self.assertEqual([item['path'] for item in items], ['~/Projects/good.code-workspace'])
        self.assertIn(b'UNSUPPORTED_WORKSPACES=1', (self.workspace / 'inventory.conf').read_bytes())
        self.assertNotIn(b'confirmed-missing', b''.join(p.read_bytes() for p in self.workspace.iterdir()))
        self.assertEqual(bundle.fingerprint(self.home), before)

    def test_descriptor_access_failure_preserves_previous_grouped_snapshot(self):
        (self.home / 'Projects/good.code-workspace').write_text('{"folders":[{"path":"base"}]}')
        project, env = self.cli_fixture()
        self.assertEqual(self.snapshot(project, env).returncode, 0)
        before = bundle.fingerprint(self.workspace)
        blocked = self.home / 'private-folder'
        (blocked / 'target').mkdir(parents=True)
        (self.home / 'Projects/blocked.code-workspace').write_text(
            '{"folders":[{"path":"../private-folder/target"}]}')
        blocked.chmod(0)
        try:
            with self.assertRaises(PermissionError):
                (blocked / 'target').lstat()
            result = self.snapshot(project, env)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(bundle.fingerprint(self.workspace), before)
            self.assertNotIn(b'private-folder', result.stdout + result.stderr)
        finally:
            blocked.chmod(0o700)
        (self.home / 'Projects/blocked.code-workspace').unlink()
        head = self.base / '.git/HEAD'
        for corrupt in (None, 'invalid mandatory Git metadata\n'):
            with self.subTest(head=corrupt):
                if corrupt is None:
                    head.unlink()
                else:
                    head.write_text(corrupt)
                result = self.snapshot(project, env)
                self.assertEqual(result.returncode, 2, result.stderr)
                self.assertEqual(bundle.fingerprint(self.workspace), before)

    def test_descriptor_unstable_or_lost_observation_is_not_missing_folder(self):
        path = self.home / 'Projects/project.code-workspace'
        path.write_text('{"folders":[{"path":"base"}]}')
        self.collect()
        before = bundle.fingerprint(self.workspace)
        native = self.observer.inside
        observations = []
        def unstable(target, home):
            if target == self.base:
                observations.append(target)
                if len(observations) == 1:
                    raise FileNotFoundError(2, 'fixture disappeared', str(target))
            return native(target, home)
        observer = self.observer.Observer(self.home, ['Projects'])
        with patch.object(self.observer, 'inside', side_effect=unstable):
            with self.assertRaises(self.observer.ObservationError):
                observer.workspaces([path], {})
        self.assertEqual(observer.counts['UNSUPPORTED_WORKSPACES'], 0)
        path.unlink()
        with self.assertRaises(FileNotFoundError):
            observer.workspaces([path], {})
        self.assertEqual(bundle.fingerprint(self.workspace), before)

    def test_native_topology_duplicate_nested_detached_and_no_mutation(self):
        from workspace_fixture import object_file, write_index
        self.linked(self.base, self.home / 'Projects/base/nested/demo', self.oid)
        self.linked(self.base, self.home / 'Projects/team/demo', self.oid, branch=None)
        staged = object_file(self.base / '.git', 'blob', b'staged content\n')
        write_index(self.base / '.git', staged)
        (self.base / 'tracked.txt').write_bytes(b'working tree content\n')
        (self.base / 'untracked').write_text('preserve')
        (self.base / '.gitignore').write_text('ignored\n')
        (self.base / 'ignored').write_text('preserve ignored')
        before = bundle.fingerprint(self.home)
        self.assertFalse(any(self.collect().values()))
        topology = self.metadata()
        self.assertEqual(len(topology['groups']), 1)
        self.assertEqual(len(topology['groups'][0]['members']), 3)
        self.assertEqual([m['head_kind'] for m in topology['groups'][0]['members']].count('detached'), 1)
        self.assertEqual(bundle.fingerprint(self.home), before)
        captured = bundle.fingerprint(self.workspace)
        self.collect()
        self.assertEqual(bundle.fingerprint(self.workspace), captured)

    def test_unsafe_origins_filters_and_unborn_repositories_are_excluded(self):
        config = self.base / '.git/config'
        original = config.read_text()
        for origin in ('ssh://user:secret@example.invalid/repo', 'https://example.invalid/repo?secret=token',
                       '/external/repository', ''):
            config.write_text(original.replace('https://example.invalid/team/repo.git', origin))
            self.assertGreater(self.collect()['UNSUPPORTED_REPOSITORIES'], 0)
            self.assertEqual((self.workspace / 'repositories.conf').read_bytes(), b'')
        config.write_text(original + '[filter "unsafe"]\nclean = touch ' + str(self.root / 'mutated') + '\n')
        (self.base / '.gitattributes').write_text('tracked.txt filter=unsafe\n')
        self.assertGreater(self.collect()['UNSUPPORTED_REPOSITORIES'], 0)
        self.assertFalse((self.root / 'mutated').exists())
        config.write_text(original)
        (self.base / '.git/refs/heads/main').unlink()
        self.assertGreater(self.collect()['UNSUPPORTED_REPOSITORIES'], 0)

    def test_ssh_origin_and_observation_errors_are_distinct_from_absence(self):
        config = self.base / '.git/config'
        config.write_text(config.read_text().replace('https://example.invalid/team/repo.git',
                                                   'ssh://git@example.invalid/team/repo.git'))
        self.assertFalse(any(self.collect().values()))
        self.assertIn(b'ssh://git@example.invalid', (self.workspace / 'repositories.conf').read_bytes())
        before = bundle.fingerprint(self.workspace)
        native = self.observer.Observer.run
        def failed_status(observer, path, *args, **kwargs):
            if args[0] == 'status':
                raise self.observer.ObservationError('status_failed')
            return native(observer, path, *args, **kwargs)
        with patch.object(self.observer.Observer, 'run', failed_status), self.assertRaises(self.observer.ObservationError):
            self.collect()
        self.assertEqual(bundle.fingerprint(self.workspace), before)

    def test_independent_equal_origins_full_and_partial_bundle_roundtrip(self):
        self.linked(self.base, self.home / 'Projects/team/demo', self.oid)
        self.repository(self.home, 'Projects/other/demo')
        self.collect()
        topology = self.metadata()
        self.assertEqual(len(topology['groups']), 2)
        linked = next(g for g in topology['groups'] if len(g['members']) == 2)
        ids = [member['item_id'] for group in topology['groups'] for member in group['members']]
        for selected in (ids, [m['item_id'] for m in linked['members']]):
            self.selection(selected)
            preview = bundle.capture_preview(self.stage, str(self.home))
            self.assertEqual(bundle.parse_blueprint(preview)[0]['git-repositories'], [])
            output = self.root / f'{len(selected)}.mbt'
            bundle.pack(self.stage, output, str(self.home), apply_precedence=False)
            files = bundle.validate_archive(output)
            self.assertEqual(len(bundle.workspace_contract().repository_records(
                files['generated/workspace/repositories.conf'])), len(selected))
            self.assertEqual(bundle.inspect_bundle(output, str(self.home))['selected_item_counts']['git-repositories'], len(selected))
            self.assertNotIn(str(self.home).encode(), b''.join(files.values()))
            target = self.root / f'restore-{len(selected)}'
            target.mkdir()
            with self.assertRaises(bundle.Unsupported):
                bundle.unpack(output, target, str(self.home))
            self.assertEqual(list(target.iterdir()), [])
        self.selection([m['item_id'] for m in linked['members'] if m['item_id'] != linked['base_item_id']])
        with self.assertRaises(bundle.Invalid):
            bundle.capture_preview(self.stage, str(self.home))

    def test_locked_missing_prunable_and_external_groups_are_not_flattened(self):
        self.linked(self.base, self.home / 'Projects/locked', self.oid, locked=True)
        self.linked(self.base, self.home / 'Projects/missing', self.oid, branch='missing', missing=True)
        self.linked(self.base, self.root / 'external', self.oid, branch='external')
        self.repository(self.home, 'Projects/independent')
        before = bundle.fingerprint(self.home)
        counts = self.collect()
        for key in ('LOCKED_WORKTREES', 'MISSING_WORKTREES', 'PRUNABLE_WORKTREES', 'EXTERNAL_WORKTREES'):
            self.assertGreater(counts[key], 0, key)
        self.assertGreater(counts['UNSUPPORTED_REPOSITORIES'], 0)
        self.assertEqual(len(self.metadata()['groups']), 1)
        records = (self.workspace / 'repositories.conf').read_text()
        self.assertIn('Projects/independent', records)
        self.assertNotIn('Projects/base', records)
        self.assertEqual(bundle.fingerprint(self.home), before)
        self.assertNotIn(b'private reason', b''.join(p.read_bytes() for p in self.workspace.iterdir()))

    def test_missing_base_and_gitfile_external_are_unsupported(self):
        self.linked(self.base, self.home / 'Projects/feature', self.oid)
        # A linked marker can remain after its base has disappeared.
        shutil.rmtree(self.base)
        with self.assertRaises((FileNotFoundError, self.observer.contract.Unsupported)):
            self.collect()
        marker = self.home / 'Projects/feature/.git'
        marker.write_text('gitdir: ' + str(self.root / 'outside') + '\n')
        counts = self.collect()
        self.assertEqual(counts['UNSUPPORTED_REPOSITORIES'], 1)
        self.assertEqual((self.workspace / 'repositories.conf').read_bytes(), b'')

    def test_capabilities_and_malformed_porcelain_fail_closed(self):
        with patch.object(self.observer.contract, 'detect_worktree_capability', return_value={
                'status': 'unsupported', 'reason': 'worktree_porcelain_z_unavailable'}):
            counts = self.collect()
        self.assertEqual(counts['GIT_CAPABILITY_UNSUPPORTED'], 1)
        self.assertFalse((self.workspace / 'topology.json').exists())
        valid = b'worktree /home/base\0HEAD ' + b'a' * 40 + b'\0branch refs/heads/main\0\0'
        self.assertEqual(len(self.observer.porcelain(valid)), 1)
        for data in (valid.replace(b'\0', b'\n'), valid[:-1], valid + valid,
                     valid.replace(b'branch refs/heads/main', b'branch refs/tags/main'),
                     valid.replace(b'\0\0', b'\0unknown unsafe\0\0')):
            with self.subTest(data=data), self.assertRaises(self.observer.contract.Invalid):
                self.observer.porcelain(data)

    def test_safe_roots_symlinks_and_observation_failure(self):
        outside = self.root / 'outside'
        outside.mkdir()
        (self.home / 'Projects/external').symlink_to(outside)
        self.repository(self.home, 'Documents/Code/extra')
        with patch.dict(os.environ, MACSEED_WORKSPACE_ROOTS='Documents/Code'):
            self.collect()
        self.assertEqual(len(self.metadata()['groups']), 2)
        (self.base / 'src').mkdir()
        with patch.dict(os.environ, MACSEED_WORKSPACE_ROOTS='Projects/base/src'):
            self.collect()
        self.selection([])
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_bytes(blueprint.read_bytes().replace(b'[workspace-folders]\n',
                             b'[workspace-folders]\nProjects/base/src\n'))
        preview = bundle.capture_preview(self.stage, str(self.home))
        sections, _ = bundle.parse_blueprint(preview)
        self.assertEqual(sections['workspace-folders'], ['Projects/base/src'])
        self.assertEqual(sections['git-repositories'], [])
        output = self.root / 'folders-only.mbt'
        bundle.pack(self.stage, output, str(self.home), apply_precedence=False)
        self.assertEqual(bundle.validate_archive(output)['generated/workspace/folders.conf'], b'Projects/base/src|workspace\n')
        self.assertNotIn('generated/workspace/topology.json', bundle.validate_archive(output))
        self.assertNotIn('generated/workspace/repositories.conf', bundle.validate_archive(output))
        with patch.dict(os.environ, MACSEED_WORKSPACE_ROOTS='../outside'), self.assertRaises(self.observer.contract.Invalid):
            self.collect()
        with patch.object(self.observer.os, 'walk', side_effect=PermissionError()), self.assertRaises(PermissionError):
            self.collect()
        with patch.object(self.observer.Observer, 'run', side_effect=self.observer.ObservationError()), \
                self.assertRaises(self.observer.ObservationError):
            self.collect()

    def test_remote_privacy_and_jsonc_folder_relationships_only(self):
        config = self.base / '.git/config'
        config.write_text(config.read_text().replace('https://', 'https://private-user:private-token@'))
        (self.home / 'Projects/project.code-workspace').write_text('''{
            // Metadata only; arbitrary settings must never leave this file.
            "folders": [{"path":"base", "name":"Base display",},],
            "settings": {"secret":"private-project-content"},
        }''')
        before = bundle.fingerprint(self.home)
        counts = self.collect()
        self.assertEqual(counts['REMOTE_REDACTED'], 1)
        raw = b''.join(path.read_bytes() for path in self.workspace.iterdir())
        for secret in (b'private-user', b'private-token', b'private-project-content', str(self.home).encode()):
            self.assertNotIn(secret, raw)
        workspace = json.loads((self.workspace / 'vscode-workspaces.json').read_bytes())['items'][0]
        self.assertEqual(workspace['folders'][0]['name'], 'Base display')
        self.assertEqual(workspace['folders'][0]['domain'], 'git-repositories')
        self.assertEqual(bundle.fingerprint(self.home), before)

    def test_group_publication_rollback_and_optional_sidecar_retirement(self):
        (self.home / 'Projects/project.code-workspace').write_text('{"folders":[{"path":"base"}]}')
        output = self.root / 'generated/workspace'
        output.mkdir(parents=True)
        names = ('folders.conf', 'repositories.conf', 'vscode-workspaces.conf', 'inventory.conf',
                 'topology.json', 'vscode-workspaces.json')
        for name in names:
            (output / name).write_text('old ' + name)
        before = bundle.fingerprint(output)
        command = '''source modules/discovery/workspace.sh
action() { :; }; success() { :; }; warning() { :; }; error() { :; }
position=0
workspace_publish_member() {
    position=$((position + 1))
    [[ $position != "$FAIL_POSITION" ]] || return 2
    if [[ -f "$1" ]]; then mv "$1" "$2"; else rm -f "$2"; fi
}
export_workspace_snapshot
'''
        env = dict(os.environ, HOME=str(self.home), BLUEPRINT_GENERATED_DIR=str(output.parent), VERBOSE='false')
        for position in range(1, 7):
            result = subprocess.run(['/bin/bash', '-c', command], cwd=MODULE.parents[2],
                                    env=dict(env, FAIL_POSITION=str(position)), capture_output=True)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertEqual(bundle.fingerprint(output), before, position)
        result = subprocess.run(['/bin/bash', '-c', command], cwd=MODULE.parents[2],
                                env=dict(env, FAIL_POSITION='0'), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue((output / 'topology.json').is_file())
        shutil.rmtree(self.base)
        (self.home / 'Projects/project.code-workspace').unlink()
        result = subprocess.run(['/bin/bash', '-c', command], cwd=MODULE.parents[2],
                                env=dict(env, FAIL_POSITION='0'), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse((output / 'topology.json').exists())
        self.assertFalse((output / 'vscode-workspaces.json').exists())


if __name__ == "__main__":
    unittest.main()
