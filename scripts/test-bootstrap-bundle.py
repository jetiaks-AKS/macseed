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
        self.assertEqual(set(bundle.ITEMS) | set(bundle.CATEGORIES),
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
        for folder in ("modules/bundle", "modules/migration", "modules/verification", "scripts", "config/generated"):
            (fixture / folder).mkdir(parents=True, exist_ok=True)
        for original, target in (
            (MODULE, fixture / "modules/bundle/bundle.py"),
            (MODULE.with_name("commands.sh"), fixture / "modules/bundle/commands.sh"),
            (migration, fixture / "scripts/ssh-identity-migrate.sh"),
            (migration.parents[1] / "modules/migration/ssh-identities.sh",
             fixture / "modules/migration/ssh-identities.sh"),
            (migration.parents[1] / "modules/migration/package.sh",
             fixture / "modules/migration/package.sh"),
            (migration.parents[1] / "modules/migration/evidence.py",
             fixture / "modules/migration/evidence.py"),
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
                                env=dict(os.environ, HOME=str(home), TMPDIR=str(private_tmp)))

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
        for folder in ("modules/bundle", "modules/migration", "scripts", "seed", "private-tmp"):
            (fixture / folder).mkdir(parents=True, exist_ok=True)
        shutil.copytree(self.stage, fixture / "seed", dirs_exist_ok=True)
        migration = MODULE.parents[2] / "scripts/ssh-identity-migrate.sh"
        for original, target in (
            (MODULE, fixture / "modules/bundle/bundle.py"),
            (MODULE.with_name("commands.sh"), fixture / "modules/bundle/commands.sh"),
            (migration, fixture / "scripts/ssh-identity-migrate.sh"),
            (migration.parents[1] / "modules/migration/ssh-identities.sh",
             fixture / "modules/migration/ssh-identities.sh"),
            (migration.parents[1] / "modules/migration/package.sh",
             fixture / "modules/migration/package.sh"),
            (migration.parents[1] / "modules/migration/evidence.py",
             fixture / "modules/migration/evidence.py"),
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


if __name__ == "__main__":
    unittest.main()
