#!/usr/bin/env python3
"""Batch A: real Restore entrypoint/consumers, disposable HOME, local Git transport."""
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("bundle_tests", ROOT / "scripts/test-bootstrap-bundle.py")
helpers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helpers)
bundle = helpers.bundle


class RestorePrerequisites(unittest.TestCase):
    run_pty = helpers.BundleTests.run_pty

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.project = self.root / "project"
        self.project.mkdir()
        for directory in ("modules", "bin"):
            shutil.copytree(ROOT / directory, self.project / directory,
                            ignore=shutil.ignore_patterns("__pycache__"))
        (self.project / "config").mkdir()
        (self.project / "scripts").mkdir()
        for relative in ("bootstrap.sh", "config/toolkit.conf", "scripts/install-bs.sh",
                         "scripts/ssh-identity-migrate.sh"):
            shutil.copy2(ROOT / relative, self.project / relative)
        self.home = self.root / "home"
        self.home.mkdir(mode=0o700)
        self.stage = self.root / "stage"
        (self.stage / "generated").mkdir(parents=True, mode=0o700)
        self.stage.chmod(0o700)
        self.archive = self.root / "test.mbt"
        self.tools = self.root / "tools"
        self.tools.mkdir()
        (self.tools / "python3").symlink_to(sys.executable)
        if shutil.which("age"):
            (self.tools / "age").symlink_to(shutil.which("age"))
        self.events = self.root / "events"
        self.spies = self.root / "spies.sh"
        self.spies.write_text(r'''
curl(){ [[ "$*" == *-fsSI* ]]; }
xcode-select(){ return 0; }
sw_vers(){ echo 99; }
sudo(){ echo preflight >> "$AUDIT_EVENTS"; return 0; }
git(){
    if [[ "${1:-}" == clone ]]; then
        echo clone >> "$AUDIT_EVENTS"
        [[ "${AUDIT_REQUIRE_CONFIG:-0}" != 1 || -f "$HOME/.ssh/config" ]] || return 97
        [[ "${AUDIT_REQUIRE_KEY:-0}" != 1 || -f "$HOME/.ssh/id_ed25519" ]] || return 98
        /usr/bin/git clone "$AUDIT_ORIGIN" "$3" || return 2
        /usr/bin/git -C "$3" remote set-url origin "$2"
    else
        /usr/bin/git "$@"
    fi
}
''')
        self.env = dict(os.environ, HOME=str(self.home),
                        PATH=str(self.tools) + ":/usr/bin:/bin:/usr/sbin:/sbin",
                        BASH_ENV=str(self.spies), AUDIT_EVENTS=str(self.events),
                        BS_INSTALL_DIR=str(self.root / "missing-prefix/bin"),
                        PYTHONDONTWRITEBYTECODE="1", SHELL="/bin/zsh")
        for key in ("BLUEPRINT_FILE", "BLUEPRINT_GENERATED_DIR", "SSH_SNAPSHOT_FILE",
                    "ZSH_SNAPSHOT_FILE", "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM",
                    "BUNDLE_RESTORE_ACTIVE", "BUNDLE_RESTORE_SECURE_FILE"):
            self.env.pop(key, None)
        self.env["GIT_CONFIG_NOSYSTEM"] = "1"
        self.env["XDG_CONFIG_HOME"] = str(self.home / ".config")

    def prepare(self, ssh=False, repository=False, secure=False):
        flags = {key: False for key in bundle.CATEGORY_FLAGS}
        flags["ssh-configuration"] = ssh
        flags["git-configuration"] = True
        selected = {key: [] for key in bundle.ITEMS}
        selected["git-configuration"] = ["user.name"]
        if repository:
            selected["git-repositories"] = ["demo"]
            origin = self.root / "origin"
            subprocess.run(["/usr/bin/git", "init", "-b", "main", str(origin)], check=True,
                           capture_output=True, env=self.env)
            subprocess.run(["/usr/bin/git", "-C", str(origin), "-c", "user.name=Fixture",
                            "-c", "user.email=fixture@example.invalid", "commit", "--allow-empty",
                            "-m", "fixture"], check=True, capture_output=True, env=self.env)
            self.env["AUDIT_ORIGIN"] = str(origin)
            self.env["AUDIT_REQUIRE_CONFIG"] = "1" if ssh else "0"
            self.env["AUDIT_REQUIRE_KEY"] = "1" if secure else "0"
            content = ('[demo]\nNAME="demo"\nPATH="/Users/source/Work/demo"\n'
                       'REMOTE="git@bundle-host:demo"\nCURRENT_BRANCH="main"\n'
                       'DEFAULT_BRANCH="main"\n' + ''.join(
                           key + '="false"\n' for key in ("HAS_UNCOMMITTED_CHANGES",
                           "HAS_VSCODE_FOLDER", "HAS_SETTINGS", "HAS_TASKS", "HAS_LAUNCH",
                           "HAS_EXTENSIONS")))
            bundle.write_file(self.stage / "generated/workspace/repositories.conf", content.encode())
        if ssh:
            bundle.write_file(self.stage / "generated/ssh/config.snapshot",
                              b"# toolkit-ssh-snapshot: 1\n# status: ready\n# excluded-profiles: 0\n\n"
                              b"Host bundle-host\n    HostName example.invalid\n    User git\n")
        bundle.write_file(self.stage / "generated/git.conf", b"[user]\nname = Restored User\n")
        bp = "[categories]\n" + "".join(f'{k}="{str(v).lower()}"\n' for k, v in flags.items())
        bp += "".join(f"[{k}]\n" + "".join(v + "\n" for v in values)
                      for k, values in selected.items())
        bundle.write_file(self.stage / "blueprint.conf", bp.encode())
        if secure:
            source = self.root / "source"
            (source / ".ssh").mkdir(parents=True, mode=0o700)
            key = source / ".ssh/id_ed25519"
            subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                           check=True, capture_output=True)
            status, _ = self.run_pty(
                ["bash", str(ROOT / "scripts/ssh-identity-migrate.sh"), "export", "--output",
                 str(self.stage / "secure.age")],
                [(b"Select numbers", b"1"), (b"Type export", b"export"),
                 (b"Enter passphrase", b"fixture-secret"), (b"Confirm passphrase", b"fixture-secret")],
                cwd=ROOT, env=dict(self.env, HOME=str(source)))
            self.assertEqual(status, 0)
        bundle.pack(self.stage, self.archive, "/Users/source")

    def restore(self, answers="\ny\n"):
        return subprocess.run(["./bootstrap.sh", "--restore", str(self.archive)],
                              cwd=self.project, env=self.env, input=answers, text=True,
                              capture_output=True, timeout=30)

    def secure_restore(self, confirmation=b"import", phrase=b"fixture-secret"):
        answers = [(b"Enter=continue", b""), (b"Apply this selection", b"y"),
                   (b"Enter passphrase", phrase)]
        if confirmation is not None:
            answers.append((b"Type import", confirmation))
        return self.run_pty(["./bootstrap.sh", "--restore", str(self.archive)],
                            answers,
                            cwd=self.project, env=self.env)

    def test_clean_home_settings_only_and_optional_launcher(self):
        self.prepare()
        result = self.restore()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("Optional bs launcher deferred", result.stdout)
        self.assertIn("Restored User", (self.home / ".gitconfig").read_text())
        self.assertFalse((self.home / ".ssh").exists())
        self.assertFalse((self.root / "missing-prefix").exists())

    def test_full_preview_cancel_does_not_create_ssh_or_publish(self):
        self.prepare(ssh=True, repository=True)
        result = self.restore("\nn\n")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Would restore SSH configuration", result.stdout)
        self.assertIn("Would clone repository", result.stdout)
        self.assertFalse(self.events.exists())
        self.assertFalse((self.home / ".ssh").exists())
        self.assertFalse((self.project / "config/blueprint.conf").exists())

    def test_selected_ssh_configuration_precedes_repository_transport(self):
        self.prepare(ssh=True, repository=True)
        result = self.restore()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertTrue((self.home / "Work/demo/.git").is_dir())
        self.assertEqual(self.events.read_text().splitlines().count("clone"), 1)
        # Same inputs converge: no second clone and no SSH replacement.
        before = (self.home / ".ssh/config").stat().st_ino
        result = self.restore()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual((self.home / ".ssh/config").stat().st_ino, before)
        self.assertEqual(self.events.read_text().splitlines().count("clone"), 1)

    def test_invalid_selected_ssh_blocks_before_publication(self):
        self.prepare(ssh=True, repository=True)
        snapshot = self.stage / "generated/ssh/config.snapshot"
        snapshot.write_bytes(snapshot.read_bytes() + b"    ProxyCommand malicious\n")
        self.archive.unlink()
        bundle.pack(self.stage, self.archive, "/Users/source")
        result = self.restore()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(self.events.exists())
        self.assertFalse((self.project / "config/blueprint.conf").exists())
        self.assertFalse((self.home / ".ssh").exists())

    def test_other_invalid_selected_input_blocks_ssh_mutation(self):
        self.prepare(ssh=True, repository=True)
        # Corrupt the already-unpacked selected input after Preview, to exercise
        # Bootstrap's second complete validation before early SSH application.
        self.spies.write_text(self.spies.read_text() + r'''
if [[ "${BUNDLE_RESTORE_ACTIVE:-false}" == true ]]; then
    printf '[user]\nname = Restored User\n[core]\neditor = unsupported\n' > config/generated/git.conf
fi
''')
        result = self.restore()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertFalse(self.events.exists())
        self.assertFalse((self.home / ".ssh").exists())

    def test_ssh_configuration_conflict_preserves_target_and_stops_clone(self):
        self.prepare(ssh=True, repository=True)
        (self.home / ".ssh").mkdir(mode=0o700)
        target = self.home / ".ssh/config"
        target.write_text("# existing configuration\n")
        target.chmod(0o600)
        result = self.restore()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertEqual(target.read_text(), "# existing configuration\n")
        self.assertNotIn("clone", self.events.read_text())

    @unittest.skipUnless(shutil.which("age"), "real age required")
    def test_confirmed_secure_import_precedes_repository_transport(self):
        self.prepare(ssh=True, repository=True, secure=True)
        status, transcript = self.secure_restore()
        self.assertEqual(status, 1, transcript.decode(errors="replace"))
        self.assertTrue((self.home / "Work/demo/.git").is_dir())
        self.assertEqual((self.home / ".ssh/id_ed25519").read_bytes(),
                         (self.root / "source/.ssh/id_ed25519").read_bytes())
        self.assertNotIn(b"fixture-secret", transcript)

    @unittest.skipUnless(shutil.which("age"), "real age required")
    def test_declined_secure_import_stops_clone(self):
        self.prepare(ssh=True, repository=True, secure=True)
        status, transcript = self.secure_restore(confirmation=b"cancel")
        self.assertEqual(status, 1, transcript.decode(errors="replace"))
        self.assertFalse((self.home / ".ssh/id_ed25519").exists())
        self.assertNotIn("clone", self.events.read_text())
        self.assertFalse((self.home / ".gitconfig").exists())

    @unittest.skipUnless(shutil.which("age"), "real age required")
    def test_selected_identity_without_ssh_configuration_precedes_clone(self):
        self.prepare(repository=True, secure=True)
        status, transcript = self.secure_restore()
        self.assertEqual(status, 1, transcript.decode(errors="replace"))
        self.assertTrue((self.home / "Work/demo/.git").is_dir())
        self.assertFalse((self.home / ".ssh/config").exists())

    @unittest.skipUnless(shutil.which("age"), "real age required")
    def test_decryption_failure_stops_clone(self):
        self.prepare(ssh=True, repository=True, secure=True)
        status, transcript = self.secure_restore(confirmation=None, phrase=b"wrong-fixture-phrase")
        self.assertEqual(status, 2, transcript.decode(errors="replace"))
        self.assertNotIn("clone", self.events.read_text())
        self.assertFalse((self.home / ".ssh/id_ed25519").exists())

    @unittest.skipUnless(shutil.which("age"), "real age required")
    def test_secure_conflict_preserves_pair_and_stops_clone(self):
        self.prepare(ssh=True, repository=True, secure=True)
        (self.home / ".ssh").mkdir(mode=0o700)
        key = self.home / ".ssh/id_ed25519"
        subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)],
                       check=True, capture_output=True)
        before = key.read_bytes()
        status, transcript = self.secure_restore(confirmation=None)
        self.assertEqual(status, 1, transcript.decode(errors="replace"))
        self.assertEqual(key.read_bytes(), before)
        self.assertNotIn("clone", self.events.read_text())

    def test_homebrew_activation_in_parent_and_downstream_process(self):
        source = (ROOT / "modules/core/homebrew/homebrew.sh").read_text()
        for architecture in ("arm64", "x86_64"):
            with self.subTest(architecture=architecture):
                prefix = self.root / architecture
                # Relocate only installation roots; run the production helper,
                # availability checks and parent/child PATH handling unchanged.
                module = self.project / "modules/core/homebrew/homebrew.sh"
                module.write_text(source.replace("/opt/homebrew", str(prefix))
                                  .replace("/usr/local", str(prefix)))
                script = r'''
source "$TEST_MODULE" || exit $?
info(){ :; }; warning(){ :; }; success(){ :; }; error(){ echo "$*" >&2; }
uname(){ echo "$TEST_ARCH"; }
install_homebrew(){
    [[ "${TEST_INSTALL_FAIL:-0}" != 1 ]] || return 7
    mkdir -p "$TEST_PREFIX/bin"
    printf '#!/bin/bash\nprintf "%%s\\n" "%s"\n' "$TEST_PREFIX" > "$TEST_PREFIX/bin/brew"
    chmod +x "$TEST_PREFIX/bin/brew"
}
check_homebrew || exit $?
[[ "$(brew --prefix)" == "$TEST_PREFIX" ]] || exit 8
/bin/bash -c '[[ "$(brew --prefix)" == "$TEST_PREFIX" ]]' || exit 9
'''
                env = dict(self.env, TEST_MODULE=str(module), TEST_PREFIX=str(prefix),
                           TEST_ARCH=architecture)
                result = subprocess.run(["/bin/bash", "-c", script], input="y\n", text=True,
                                        capture_output=True, env=env)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                result = subprocess.run(["/bin/bash", "-c", script], input="y\n", text=True,
                                        capture_output=True, env=dict(env, TEST_INSTALL_FAIL="1"))
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)

    def test_ssh_observation_rejects_invalid_existing_paths(self):
        script = 'source modules/core/ssh/ssh.sh; error(){ :; }; warning(){ :; }; check_ssh'
        target = self.home / ".ssh"
        for kind in ("file", "dangling-link"):
            with self.subTest(kind=kind):
                if kind == "file":
                    target.write_text("not a directory")
                else:
                    target.symlink_to(self.home / "absent")
                result = subprocess.run(["/bin/bash", "-c", script], cwd=self.project,
                                        env=self.env, capture_output=True)
                self.assertEqual(result.returncode, 2)
                target.unlink()


if __name__ == "__main__":
    unittest.main()
