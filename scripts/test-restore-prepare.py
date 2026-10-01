#!/usr/bin/env python3
"""Isolated production Preview checks for structured Restore preparation."""

import json
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parent.parent
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "modules/bundle"))
import bundle


class RestorePrepareTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / "project"
        self.project.mkdir()
        shutil.copytree(ROOT / "modules", self.project / "modules")
        shutil.copy2(ROOT / "bootstrap.sh", self.project / "bootstrap.sh")
        (self.project / "config").mkdir()
        shutil.copy2(ROOT / "config/toolkit.conf", self.project / "config/toolkit.conf")
        self.home = self.root / "home"
        self.home.mkdir()
        self.private_temp = self.root / "private-tmp"
        self.private_temp.mkdir(mode=0o700)
        mock_bin = self.root / "bin"
        mock_bin.mkdir()
        for name, body in (("curl", "exit 0"), ("xcode-select", "exit 0"),
                           ("sw_vers", 'printf "%s\\n" 99'),
                           ("sudo", 'printf sudo >> "$TEST_MUTATIONS"; exit 99'),
                           ("age", 'printf age >> "$TEST_MUTATIONS"; exit 99')):
            path = mock_bin / name
            path.write_text("#!/bin/bash\n" + body + "\n")
            path.chmod(0o700)
        self.environment = dict(os.environ, HOME=str(self.home), TMPDIR=str(self.private_temp),
                                PATH=str(mock_bin) + os.pathsep + os.environ["PATH"],
                                TEST_MUTATIONS=str(self.root / "mutations"))
        for name in ("BLUEPRINT_FILE", "BLUEPRINT_GENERATED_DIR", "BUNDLE_RESTORE_ACTIVE",
                     "BUNDLE_RESTORE_PREVIEW", "PREVIEW_SUMMARY_FILE"):
            self.environment.pop(name, None)
        self.stage = self.root / "source"
        self.stage.mkdir(mode=0o700)
        categories = {name: False for name in bundle.CATEGORY_FLAGS}
        blueprint = ("[categories]\n" +
                     "".join(f'{name}="{str(enabled).lower()}"\n'
                             for name, enabled in categories.items()) +
                     "".join(f"\n[{name}]\n" +
                             ("Projects\n" if name == "workspace-folders" else "")
                             for name in bundle.ITEMS)).encode()
        bundle.write_file(self.stage / "blueprint.conf", blueprint)
        bundle.write_file(self.stage / "generated/workspace/folders.conf", b"Projects|workspace\n")
        self.archive = self.root / "demo bundle.mbt"

    def pack(self, secure=False):
        if secure:
            bundle.write_file(self.stage / "secure.age", b"age-encryption.org/v1\nprivate-ciphertext")
        bundle.pack(self.stage, self.archive, "/Users/source")

    def invoke(self, *, groups=(), secure=False, path=None):
        request = {"protocol_version": 1, "operation_id": "prepare-1",
                   "operation": "restore_prepare",
                   "parameters": {"path": str(path or self.archive),
                                  "disabled_groups": list(groups), "include_secure": secure}}
        result = subprocess.run(
            ["bash", str(self.project / "modules/core/application-interface/core.sh")],
            input=json.dumps(request).encode(), cwd=self.project, env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
        )
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(sum(event["type"] in ("completed", "failed") for event in events), 1)
        self.assertIn(events[-1]["type"], ("completed", "failed"))
        self.assertFalse(list(self.private_temp.glob("mbt-bundle-*")))
        return result, events

    def execute(self, plan_id, *, groups=(), secure=False, path=None):
        request = {"protocol_version": 1, "operation_id": "execute-1",
                   "operation": "restore_execute",
                   "parameters": {"path": str(path or self.archive),
                                  "disabled_groups": list(groups), "include_secure": secure,
                                  "expected_prepared_plan_id": plan_id}}
        result = subprocess.run(
            ["bash", str(self.project / "modules/core/application-interface/core.sh")],
            input=json.dumps(request).encode(), cwd=self.project, env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(sum(event["type"] in ("completed", "failed") for event in events), 1)
        self.assertIn(events[-1]["type"], ("completed", "failed"))
        return result, events

    def allow_application_bootstrap(self):
        (self.root / "bin/sudo").write_text("#!/bin/bash\nexit 0\n")
        (self.project / "scripts").mkdir()
        (self.project / "bin").mkdir()
        shutil.copy2(ROOT / "scripts/install-bs.sh", self.project / "scripts/install-bs.sh")
        shutil.copy2(ROOT / "bin/bs", self.project / "bin/bs")
        (self.root / "bin/bs").symlink_to(self.project / "bin/bs")
        self.environment["BS_INSTALL_DIR"] = str(self.root / "bin")

    def test_prepare_plan_and_recomputation(self):
        self.pack()
        before = self.archive.read_bytes()
        first, events = self.invoke()
        self.assertEqual(first.returncode, 0, first.stderr)
        self.assertEqual([event["type"] for event in events], ["started", "result", "completed"])
        plan = events[1]["data"]
        self.assertEqual(plan["preview_detail_level"], "module_summary")
        self.assertTrue(plan["has_planned_changes"])
        self.assertFalse(plan["include_secure"])
        self.assertEqual(plan["secure_restore_status"], "not_selected")
        self.assertEqual(len(plan["prepared_plan_id"]), 64)
        self.assertTrue(any(module["module"] == "preview_workspace_folders" and
                            module["planned"] and module["status"] == "success"
                            for module in plan["modules"]))
        self.assertEqual(self.invoke()[1][1]["data"]["prepared_plan_id"], plan["prepared_plan_id"])
        self.assertFalse((self.home / "Projects").exists())
        self.assertFalse((self.root / "mutations").exists())
        narrowed, narrowed_events = self.invoke(groups=("Workspace",))
        self.assertEqual(narrowed.returncode, 0, narrowed.stderr)
        narrowed_plan = narrowed_events[1]["data"]
        self.assertNotIn("Workspace", narrowed_plan["selected_groups"])
        self.assertFalse(narrowed_plan["has_planned_changes"])
        self.assertNotEqual(narrowed_plan["prepared_plan_id"], plan["prepared_plan_id"])
        (self.home / "Projects").mkdir()
        changed, changed_events = self.invoke()
        self.assertEqual(changed.returncode, 0, changed.stderr)
        self.assertFalse(changed_events[1]["data"]["has_planned_changes"])
        self.assertNotEqual(changed_events[1]["data"]["prepared_plan_id"], plan["prepared_plan_id"])
        self.assertEqual(self.archive.read_bytes(), before)
        self.assertFalse((self.project / "config/generated").exists())
        self.assertFalse((self.project / "config/blueprint.conf").exists())
        self.assertNotIn(str(self.home).encode(), first.stdout)
        self.assertNotIn(b"Projects|workspace", first.stdout)
        self.assertNotIn(str(self.archive).encode(), first.stdout)

    def test_secure_and_invalid_selection(self):
        self.pack(secure=True)
        selected, selected_events = self.invoke(secure=True)
        self.assertEqual(selected.returncode, 0, selected.stderr)
        self.assertEqual(selected_events[1]["data"]["secure_restore_status"], "selected_pending")
        self.assertNotIn(b"private-ciphertext", selected.stdout)
        self.assertFalse((self.root / "mutations").exists())
        excluded, excluded_events = self.invoke(secure=False)
        self.assertEqual(excluded.returncode, 0, excluded.stderr)
        self.assertNotEqual(selected_events[1]["data"]["prepared_plan_id"],
                            excluded_events[1]["data"]["prepared_plan_id"])
        for groups in (("Workspace", "Workspace"), ("Unknown",)):
            with self.subTest(groups=groups):
                result, events = self.invoke(groups=groups)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(events[-1]["data"]["code"], "invalid_selection")

    def test_application_readiness_is_read_only_and_typed(self):
        environment = dict(self.environment, BLUEPRINT_FILE=str(self.stage / "blueprint.conf"),
                           BLUEPRINT_GENERATED_DIR=str(self.stage / "generated"),
                           BUNDLE_RESTORE_ACTIVE="true", MACSEED_APPLICATION_EXECUTION="true")
        command = ["bash", "./bootstrap.sh", "--application-readiness"]

        def check():
            return subprocess.run(command, cwd=self.project, env=environment,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)

        denied = check()
        self.assertEqual(denied.returncode, 2)
        self.assertEqual(denied.stdout.strip(), b"authorization_required")
        self.assertFalse((self.project / "config/generated").exists())
        self.assertFalse((self.project / "config/blueprint.conf").exists())
        (self.root / "bin/sudo").write_text("#!/bin/bash\nexit 0\n")
        ready = check()
        self.assertEqual(ready.returncode, 0, ready.stderr)
        self.assertEqual(ready.stdout.strip(), b"ready")
        environment["MACSEED_APPLICATION_SECURE_SELECTED"] = "true"
        self.assertEqual(check().stdout.strip(), b"secure_bridge_required")
        environment.pop("MACSEED_APPLICATION_SECURE_SELECTED")
        blueprint = self.stage / "blueprint.conf"
        blueprint.write_text(blueprint.read_text().replace("[git-repositories]\n", "[git-repositories]\nrepo\n"))
        bundle.write_file(self.stage / "generated/workspace/repositories.conf",
                          ('[repo]\nNAME="repo"\nPATH="/Users/source/Projects/repo"\n'
                           'REMOTE="git@example.com:repo.git"\nDEFAULT_BRANCH="main"\n'
                           'CURRENT_BRANCH="main"\nHAS_UNCOMMITTED_CHANGES="false"\n'
                           'HAS_VSCODE_FOLDER="false"\nHAS_SETTINGS="false"\n'
                           'HAS_TASKS="false"\nHAS_LAUNCH="false"\n'
                           'HAS_EXTENSIONS="false"\n').encode())
        self.assertEqual(check().stdout.strip(), b"invalid_selected_input")
        self.assertFalse((self.project / "config/.bundle-publication").exists())

    def test_formula_readiness_keeps_casks_separate(self):
        blueprint = self.stage / "blueprint.conf"
        blueprint.write_text(blueprint.read_text().replace(
            'homebrew-packages="false"', 'homebrew-packages="true"').replace(
            '[homebrew-packages]\n', '[homebrew-packages]\nfixture-formula\n'))
        bundle.write_file(self.stage / "generated/brew-packages.conf", b"fixture-formula\n")
        brew = self.root / "bin/brew"
        brew.write_text('#!/bin/bash\ncase "$*" in\n'
                        '  --prefix) echo /opt/homebrew ;;\n'
                        '  "list --formula --full-name") exit 0 ;;\n'
                        '  *) exit 2 ;;\nesac\n')
        brew.chmod(0o700)
        (self.root / "bin/sudo").write_text("#!/bin/bash\nexit 0\n")
        environment = dict(self.environment, BLUEPRINT_FILE=str(blueprint),
                           BLUEPRINT_GENERATED_DIR=str(self.stage / "generated"),
                           BUNDLE_RESTORE_ACTIVE="true", MACSEED_APPLICATION_EXECUTION="true",
                           PATH=str(self.root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin")

        def check():
            return subprocess.run(["bash", "./bootstrap.sh", "--application-readiness"],
                                  cwd=self.project, env=environment, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, check=False)

        self.assertEqual(check().stdout.strip(), b"ready")
        brew.write_text('#!/bin/bash\nexit 2\n')
        self.assertEqual(check().stdout.strip(), b"homebrew_unavailable")
        brew.unlink()
        # The fixture gives the production prefix lookup a nonexistent prefix.
        module = self.project / "modules/core/homebrew/homebrew.sh"
        module.write_text(module.read_text().replace(
            '/opt/homebrew', str(self.root / 'absent-homebrew')))
        self.assertEqual(check().stdout.strip(), b"homebrew_installation_requires_interaction")
        blueprint.write_text(blueprint.read_text().replace(
            '[homebrew-casks]\n', '[homebrew-casks]\nfixture-cask\n'))
        bundle.write_file(self.stage / "generated/brew-casks.conf", b"fixture-cask\n")
        self.assertEqual(check().stdout.strip(), b"homebrew_installation_requires_interaction")

    def cask_fixture(self, mixed=False):
        self.allow_application_bootstrap()
        destination = self.home / "Applications"
        destination.mkdir()
        module = self.project / "modules/apps/brew-casks.sh"
        module.write_text(module.read_text().replace('/Applications', str(destination)))
        self.environment.update(TEST_CASK_METADATA=str(self.root / "cask.json"),
                                TEST_CASK_STATE=str(self.root / "cask-state"),
                                TEST_CASK_LOG=str(self.root / "cask-log"),
                                TEST_CASK_TARGET=str(destination / "Fixture.app"),
                                TEST_BOUNDARY=str(self.root / "boundary"))
        metadata = {"casks": [{"token": "fixture-cask", "tap": "homebrew/cask",
                               "disabled": False, "caveats": None, "caveats_rosetta": None,
                               "depends_on": {"macos": {}}, "container": None, "rename": [],
                               "artifacts": [{"app": ["Fixture.app"],
                                              "target": self.environment["TEST_CASK_TARGET"]}]}]}
        Path(self.environment["TEST_CASK_METADATA"]).write_text(json.dumps(metadata))
        brew = self.root / "bin/brew"
        brew.write_text('''#!/bin/bash
case "$*" in
  --prefix) echo /opt/homebrew ;;
  "list --formula --full-name") [[ ! -f "$TEST_CASK_STATE.formula" ]] || echo fixture-formula ;;
  "list --cask") [[ ! -f "$TEST_CASK_STATE" ]] || echo fixture-cask ;;
  "info --json=v2 --cask fixture-cask") cat "$TEST_CASK_METADATA" ;;
  "install fixture-formula") touch "$TEST_CASK_STATE.formula" ;;
  install\ --cask\ --appdir=*\ fixture-cask)
    [[ "$MACSEED_APPLICATION_EXECUTION" == true && "$HOMEBREW_NO_SUDO" == 1 &&
       "$HOMEBREW_NO_AUTO_UPDATE" == 1 && "$HOMEBREW_NO_INSTALL_CLEANUP" == 1 &&
       "$HOMEBREW_NO_INSTALL_UPGRADE" == 1 && "$HOMEBREW_NO_ASK" == 1 &&
       ! -t 0 && ! -t 1 && -f "$TEST_BOUNDARY" ]] || exit 2
    if (: </dev/tty) 2>/dev/null; then exit 2; fi
    read -r input && exit 2
    echo install >> "$TEST_CASK_LOG"
    [[ "${TEST_CASK_FAIL:-false}" != true ]] || exit 2
    touch "$TEST_CASK_STATE"
    mkdir "$TEST_CASK_TARGET" ;;
  *) exit 2 ;;
esac
exit 0
''')
        brew.chmod(0o700)
        entrypoint = self.project / "bootstrap.sh"
        entrypoint.write_text(entrypoint.read_text().replace(
            "    printf 'mutation_may_have_started\\n'", '    touch "$TEST_BOUNDARY"\n' +
            "    printf 'mutation_may_have_started\\n'"))
        blueprint = self.stage / "blueprint.conf"
        contents = blueprint.read_text().replace(
            '[homebrew-casks]\n', '[homebrew-casks]\nfixture-cask\n')
        if mixed:
            contents = contents.replace('[homebrew-packages]\n',
                                        '[homebrew-packages]\nfixture-formula\n')
            bundle.write_file(self.stage / "generated/brew-packages.conf", b"fixture-formula\n")
        blueprint.write_text(contents)
        bundle.write_file(self.stage / "generated/brew-casks.conf", b"fixture-cask\n")
        return metadata

    def test_cask_execution_and_convergence(self):
        self.cask_fixture(mixed=True)
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue(Path(self.environment["TEST_CASK_STATE"]).exists())
        self.assertTrue(Path(self.environment["TEST_CASK_STATE"] + ".formula").exists())
        self.assertEqual(events[-2]["data"]["verification"]["verdict"],
                         "selected_requirements_verified")
        self.assertNotIn(b"fixture-cask", result.stdout)
        next_plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        self.assertEqual(self.execute(next_plan)[0].returncode, 0)
        self.assertEqual(Path(self.environment["TEST_CASK_LOG"]).read_text(), "install\n")

    def test_cask_failure_preserves_mutation_boundary(self):
        self.cask_fixture()
        self.environment["TEST_CASK_FAIL"] = "true"
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "bootstrap_failed")
        self.assertTrue(events[-1]["data"]["target_mutation_may_have_started"])

    def test_cask_readiness_states_and_other_categories(self):
        metadata = self.cask_fixture()
        blueprint = self.stage / "blueprint.conf"
        environment = dict(self.environment, BLUEPRINT_FILE=str(blueprint),
                           BLUEPRINT_GENERATED_DIR=str(self.stage / "generated"),
                           BUNDLE_RESTORE_ACTIVE="true", MACSEED_APPLICATION_EXECUTION="true")
        def check():
            return subprocess.run(["bash", "./bootstrap.sh", "--application-readiness"],
                                  cwd=self.project, env=environment, stdin=subprocess.DEVNULL,
                                  stdout=subprocess.PIPE, check=False).stdout.strip()
        self.assertEqual(check(), b"ready")
        # Already satisfied casks bypass the installation artifact classifier.
        metadata["casks"][0]["artifacts"].append({"pkg": ["Fixture.pkg"]})
        Path(self.environment["TEST_CASK_METADATA"]).write_text(json.dumps(metadata))
        Path(self.environment["TEST_CASK_STATE"]).touch()
        target = Path(self.environment["TEST_CASK_TARGET"])
        target.mkdir()
        self.assertEqual(check(), b"ready")
        target.rmdir()
        self.assertEqual(check(), b"cask_repair_not_supported\t1")
        brew = self.root / "bin/brew"
        brew.write_text("#!/bin/bash\nexit 2\n")
        self.assertEqual(check(), b"homebrew_unavailable")
        selected = blueprint.read_text()
        blueprint.write_text(selected.replace("fixture-cask\n", ""))
        self.assertEqual(check(), b"ready")
        blueprint.write_text(selected)
        brew.unlink()
        environment["PATH"] = str(self.root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
        module = self.project / "modules/core/homebrew/homebrew.sh"
        module.write_text(module.read_text().replace('/opt/homebrew', str(self.root / 'absent'))
                          .replace('/usr/local', str(self.root / 'absent')))
        self.assertEqual(check(), b"homebrew_installation_requires_interaction")
        for category, item in (("app-store", "123"),):
            blueprint.write_text(selected.replace(f"[{category}]\n", f"[{category}]\n{item}\n"))
            self.assertEqual(check(), b"unsupported_interactive_operation")
        blueprint.write_text(selected)
        environment["MACSEED_APPLICATION_SECURE_SELECTED"] = "true"
        self.assertEqual(check(), b"secure_bridge_required")
        self.assertFalse(Path(self.environment["TEST_CASK_LOG"]).exists())
        self.assertFalse((self.project / "config/.bundle-publication").exists())

    def test_blocked_cask_prevents_mixed_plan_publication(self):
        metadata = self.cask_fixture(mixed=True)
        metadata["casks"][0]["artifacts"].append({"pkg": ["Fixture.pkg"]})
        Path(self.environment["TEST_CASK_METADATA"]).write_text(json.dumps(metadata))
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(result.returncode, 2)
        final = events[-1]["data"]
        self.assertEqual(final["code"], "cask_execution_requirements_unsupported")
        self.assertEqual(final["selected_item_index"], 1)
        self.assertFalse(final["publication_started"])
        self.assertFalse(final["target_mutation_may_have_started"])
        self.assertFalse(Path(self.environment["TEST_CASK_STATE"] + ".formula").exists())
        self.assertIn("fixture-formula", (self.stage / "blueprint.conf").read_text())
        self.assertIn("fixture-cask", (self.stage / "blueprint.conf").read_text())
        self.assertNotIn(b"fixture-cask", result.stdout)

    def test_cask_metadata_artifact_boundary(self):
        metadata = self.cask_fixture()
        path = Path(self.environment["TEST_CASK_METADATA"])
        command = ['bash', '-c', 'source modules/apps/brew-casks.sh; '
                   'cask_application_readiness fixture-cask >/dev/null 2>&1; '
                   'printf "%s" "$CASK_APPLICATION_CONDITION"']
        def check(value):
            path.write_text(json.dumps(value))
            return subprocess.run(command, cwd=self.project, env=self.environment,
                                  stdout=subprocess.PIPE, check=False).stdout.decode()
        self.assertEqual(check(metadata), "ready")
        for artifact in ("pkg", "installer", "binary", "suite", "preflight", "postflight",
                         "preflight_steps", "postflight_steps", "generated_script", "service",
                         "unknown"):
            value = json.loads(json.dumps(metadata))
            value["casks"][0]["artifacts"].append({artifact: None})
            with self.subTest(artifact=artifact):
                self.assertEqual(check(value), "cask_execution_requirements_unsupported")
        for artifact in ("zap", "uninstall"):
            value = json.loads(json.dumps(metadata))
            value["casks"][0]["artifacts"].append({artifact: [{}]})
            self.assertEqual(check(value), "ready")
        for key, value in (("caveats", "EULA"), ("caveats_rosetta", True),
                           ("depends_on", {"formula": ["helper"]}), ("container", {"type": "pkg"}),
                           ("disabled", True), ("tap", "third-party/tap"), ("rename", ["something"])):
            candidate = json.loads(json.dumps(metadata))
            candidate["casks"][0][key] = value
            self.assertEqual(check(candidate), "cask_execution_requirements_unsupported")
        self.assertEqual(check({"casks": []}), "cask_metadata_unavailable")
        Path(self.environment["TEST_CASK_TARGET"]).mkdir()
        self.assertEqual(check(metadata), "cask_target_conflict")
        Path(self.environment["TEST_CASK_TARGET"]).rmdir()
        (self.home / "Applications").rmdir()
        self.assertEqual(check(metadata), "cask_authorization_required")

    def vscode_fixture(self, bundled=False, mixed=False):
        if mixed:
            self.cask_fixture(mixed=True)
            (self.root / "bin/jq").symlink_to(shutil.which("jq"))
        else:
            self.allow_application_bootstrap()
            brew = self.root / "bin/brew"
            brew.write_text("#!/bin/bash\necho /opt/homebrew\n")
            brew.chmod(0o700)
        self.environment.update(TEST_EXTENSION_STATE=str(self.root / "extension-state"),
                                TEST_EXTENSION_LOG=str(self.root / "extension-log"),
                                TEST_BOUNDARY=str(self.root / "boundary"),
                                PATH=str(self.root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin")
        # Replace only the standard system bundle location in this isolated copy.
        system_app = self.root / "Applications/Visual Studio Code.app"
        module = self.project / "modules/vscode/extensions.sh"
        module.write_text(module.read_text().replace('"/Applications/Visual Studio Code.app"',
                                                    '"' + str(system_app) + '"'))
        if bundled:
            code = system_app / "Contents/Resources/app/bin/code"
            code.parent.mkdir(parents=True)
        else:
            code = self.root / "bin/code"
        code.write_text('''#!/bin/bash
case "$*" in
  --list-extensions)
    [[ "${TEST_EXTENSION_OBSERVATION_FAIL:-false}" != true ]] || exit 2
    echo already.extension
    [[ ! -f "$TEST_EXTENSION_STATE" ]] || echo publisher.fixture ;;
  "--install-extension publisher.fixture")
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
      [[ ! -t 0 && ! -t 1 && -f "$TEST_BOUNDARY" ]] || exit 2
      if (: </dev/tty) 2>/dev/null; then exit 2; fi
      read -r input && exit 2
    fi
    echo "$*" >> "$TEST_EXTENSION_LOG"
    [[ "${TEST_EXTENSION_FAIL:-false}" != true ]] || exit 2
    touch "$TEST_EXTENSION_STATE" ;;
  *) exit 2 ;;
esac
exit 0
''')
        code.chmod(0o700)
        entrypoint = self.project / "bootstrap.sh"
        entrypoint.write_text(entrypoint.read_text().replace(
            "    printf 'mutation_may_have_started\\n'", '    touch "$TEST_BOUNDARY"\n' +
            "    printf 'mutation_may_have_started\\n'"))
        blueprint = self.stage / "blueprint.conf"
        blueprint.write_text(blueprint.read_text().replace('[vscode-extensions]\n',
                             '[vscode-extensions]\nalready.extension\npublisher.fixture\n'))
        bundle.write_file(self.stage / "generated/vscode-extensions.conf",
                          b"already.extension\npublisher.fixture\n")
        return code

    def test_vscode_restore_production_and_convergence(self):
        self.vscode_fixture(mixed=True)
        settings = self.home / "Library/Application Support/Code/User/settings.json"
        settings.parent.mkdir(parents=True)
        settings.write_text('{"unchanged":true}')
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue(Path(self.environment["TEST_EXTENSION_STATE"]).exists())
        self.assertTrue(Path(self.environment["TEST_CASK_STATE"]).exists())
        self.assertTrue(Path(self.environment["TEST_CASK_STATE"] + ".formula").exists())
        final = events[-2]["data"]
        self.assertEqual(final["verification"]["verdict"], "selected_requirements_verified")
        self.assertTrue(final["target_mutation_may_have_started"])
        self.assertNotIn(b"publisher.fixture", result.stdout)
        self.assertNotIn(str(self.home).encode(), result.stdout)
        next_plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        self.assertEqual(self.execute(next_plan)[0].returncode, 0)
        self.assertEqual(Path(self.environment["TEST_EXTENSION_LOG"]).read_text(),
                         "--install-extension publisher.fixture\n")
        self.assertEqual(settings.read_text(), '{"unchanged":true}')

    def test_vscode_bundled_cli_without_path(self):
        self.vscode_fixture(bundled=True)
        self.pack()
        result, prepared = self.invoke()
        self.assertEqual(result.returncode, 0, prepared)
        self.assertTrue(any(row["module"] == "preview_vscode_extensions" and row["planned"]
                            for row in prepared[1]["data"]["modules"]))
        result, events = self.execute(prepared[1]["data"]["prepared_plan_id"])
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-2]["data"]["verification"]["verdict"],
                         "selected_requirements_verified")
        self.assertFalse((self.root / "bin/code").exists())
        # Without application context, the original CLI PATH-only policy remains.
        human = subprocess.run(['bash', '-c', 'warning() { :; }; '
                                'source modules/vscode/extensions.sh; check_vscode_cli'],
                               cwd=self.project, env=self.environment, stdout=subprocess.PIPE,
                               check=False)
        self.assertEqual(human.returncode, 1)

    def test_vscode_prerequisites_before_publication(self):
        code = self.vscode_fixture()
        self.pack()
        for state, expected in (("missing", "vscode_cli_required"),
                                ("broken", "vscode_cli_unavailable")):
            if state == "missing":
                original = code.read_text()
                code.unlink()
            else:
                code.write_text("#!/bin/bash\nexit 2\n")
                code.chmod(0o700)
            prepared_result, prepared = self.invoke()
            self.assertEqual(prepared_result.returncode, 0, prepared)
            result, events = self.execute(prepared[1]["data"]["prepared_plan_id"])
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events[-1]["data"]["code"], expected)
            self.assertFalse(events[-1]["data"]["publication_started"])
            self.assertFalse(Path(self.environment["TEST_EXTENSION_LOG"]).exists())
            self.assertIn("publisher.fixture", (self.stage / "blueprint.conf").read_text())
            self.assertNotIn(b"publisher.fixture", result.stdout)
        code.write_text(original)
        code.chmod(0o700)
        blueprint = self.stage / "blueprint.conf"
        contents = blueprint.read_text()
        blueprint.write_text(contents.replace("already.extension\n", "").replace("publisher.fixture\n", ""))
        self.environment["TEST_EXTENSION_OBSERVATION_FAIL"] = "true"
        self.archive = self.root / "no-extensions.mbt"
        self.pack()
        prepared = self.invoke()[1][1]["data"]["prepared_plan_id"]
        self.assertEqual(self.execute(prepared)[0].returncode, 0)

    def test_vscode_install_failure_preserves_mutation(self):
        self.vscode_fixture()
        self.environment["TEST_EXTENSION_FAIL"] = "true"
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "bootstrap_failed")
        self.assertTrue(events[-1]["data"]["target_mutation_may_have_started"])
        self.assertFalse(Path(self.environment["TEST_EXTENSION_STATE"]).exists())

    def test_vscode_bundle_ambiguity_and_broken_launcher(self):
        code = self.vscode_fixture(bundled=True)
        user_app = self.home / "Applications/Visual Studio Code.app"
        user_app.mkdir(parents=True)
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(events[-1]["data"]["code"], "vscode_cli_ambiguous")
        self.assertFalse(events[-1]["data"]["publication_started"])
        user_app.rmdir()
        code.chmod(0o600)
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(events[-1]["data"]["code"], "vscode_cli_unavailable")
        self.assertFalse(events[-1]["data"]["publication_started"])

    def repository_fixture(self, remote="https://example.test/public.git", mixed=False):
        if mixed:
            self.vscode_fixture(mixed=True)
        else:
            self.allow_application_bootstrap()
        self.environment.update(TEST_REPO_LOG=str(self.root / "repo-log"),
                                TEST_REPO_REMOTE=remote,
                                TEST_BOUNDARY=str(self.root / "boundary"))
        entrypoint = self.project / "bootstrap.sh"
        entrypoint.write_text(entrypoint.read_text().replace(
            "    printf 'mutation_may_have_started\\n'", '    touch "$TEST_BOUNDARY"\n' +
            "    printf 'mutation_may_have_started\\n'"))
        git = self.root / "bin/git"
        git.write_text('''#!/bin/bash
[[ "${TEST_GIT_BROKEN:-false}" != true ]] || exit 2
case "$1" in
 --version) echo 'git version fixture'; exit 0 ;;
 clone) echo "human:$*" >> "$TEST_REPO_LOG"; exit 0 ;;
 check-ref-format) echo "${@: -1}"; exit 0 ;;
 -c)
   [[ "$GIT_TERMINAL_PROMPT" == 0 && "$GIT_ASKPASS" == /usr/bin/false ]] || exit 2
   [[ "$SSH_ASKPASS_REQUIRE" == never && "$GIT_SSH_COMMAND" == *'BatchMode=yes'* &&
      "$GIT_SSH_COMMAND" == *'StrictHostKeyChecking=yes'* &&
      "$GIT_SSH_COMMAND" == *'UpdateHostKeys=no'* ]] || exit 2
   [[ "$*" == *'credential.helper= -c credential.interactive=false clone'* ]] || exit 2
   [[ ! -t 0 && ! -t 1 && -f "$TEST_BOUNDARY" ]] || exit 2
   if (: </dev/tty) 2>/dev/null; then exit 2; fi
   read -r input && exit 2
   target="${@: -1}"
   echo clone >> "$TEST_REPO_LOG"
   mkdir -p "$target"
   [[ "${TEST_CLONE_FAIL:-false}" != true ]] || exit 2
   mkdir "$target/.git"
   echo default > "$target/.branch"
   exit 0 ;;
 -C)
   target="$2"; shift 2
   case "$1" in
     rev-parse) echo true ;;
     remote) echo "${TEST_ORIGIN:-$TEST_REPO_REMOTE}" ;;
     branch) cat "$target/.branch" ;;
     diff) [[ "${TEST_DIRTY:-false}" != true ]] || exit 1 ;;
     checkout) [[ "${TEST_CHECKOUT_FAIL:-false}" != true ]] || exit 2; echo "$2" > "$target/.branch"; echo checkout >> "$TEST_REPO_LOG" ;;
     *) exit 2 ;;
   esac
   exit 0 ;;
 *) exit 0 ;;
esac
''')
        git.chmod(0o700)
        blueprint = self.stage / "blueprint.conf"
        blueprint.write_text(blueprint.read_text().replace('[git-repositories]\n',
                                                              '[git-repositories]\nrepo\n'))
        bundle.write_file(self.stage / "generated/workspace/repositories.conf",
                          ('[repo]\nNAME="repo"\nPATH="/Users/source/Projects/repo"\n'
                           f'REMOTE="{remote}"\nDEFAULT_BRANCH="main"\n'
                           'CURRENT_BRANCH="main"\nHAS_UNCOMMITTED_CHANGES="false"\n'
                           'HAS_VSCODE_FOLDER="false"\nHAS_SETTINGS="false"\n'
                           'HAS_TASKS="false"\nHAS_LAUNCH="false"\n'
                           'HAS_EXTENSIONS="false"\n').encode())
        return self.home / "Projects/repo"

    def test_repository_clone_convergence_and_existing_coverage(self):
        target = self.repository_fixture(mixed=True)
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual((target / ".branch").read_text().strip(), "main")
        self.assertEqual(events[-2]["data"]["verification"]["verdict"],
                         "selected_requirements_verified")
        self.assertNotIn(str(target).encode(), result.stdout)
        self.assertNotIn(b"example.test", result.stdout)
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        self.assertEqual(self.execute(plan)[0].returncode, 0)
        self.assertEqual((self.root / "repo-log").read_text(), "clone\ncheckout\n")
        self.assertTrue(Path(self.environment["TEST_CASK_STATE"]).exists())
        self.assertTrue(Path(self.environment["TEST_CASK_STATE"] + ".formula").exists())
        self.assertTrue(Path(self.environment["TEST_EXTENSION_STATE"]).exists())

    def test_repository_conflicts_before_publication(self):
        target = self.repository_fixture()
        target.parent.mkdir(parents=True)
        self.pack()
        for kind in ("file", "directory", "wrong-origin", "dirty"):
            if kind == "file":
                target.write_text("user data")
            else:
                target.mkdir(exist_ok=True)
            if kind in ("wrong-origin", "dirty"):
                (target / ".git").mkdir(exist_ok=True)
                (target / ".branch").write_text("other")
                self.environment["TEST_ORIGIN"] = ("wrong" if kind == "wrong-origin"
                                                   else self.environment["TEST_REPO_REMOTE"])
                self.environment["TEST_DIRTY"] = "true"
            result, prepared = self.invoke()
            self.assertEqual(result.returncode, 0, prepared)
            result, events = self.execute(prepared[1]["data"]["prepared_plan_id"])
            self.assertEqual(events[-1]["data"]["code"], "repository_target_conflict")
            self.assertFalse(events[-1]["data"]["publication_started"])
            self.assertFalse((self.root / "repo-log").exists())
            if kind == "file":
                self.assertEqual(target.read_text(), "user data")
                target.unlink()

    def test_repository_git_prerequisites(self):
        self.repository_fixture()
        self.pack()
        for state, expected in (("broken", "git_unavailable"), ("missing", "git_required")):
            if state == "broken":
                self.environment["TEST_GIT_BROKEN"] = "true"
            else:
                # Simulate absence in the isolated capability probe without host fallback.
                module = self.project / "modules/bootstrap/workspace/repositories-helpers.sh"
                module.write_text(module.read_text().replace('$(command -v git)', '$(false)').replace('<<< "$PATH"', '<<< "/nonexistent"'))
            result, prepared = self.invoke()
            self.assertEqual(result.returncode, 0, prepared)
            result, events = self.execute(prepared[1]["data"]["prepared_plan_id"])
            self.assertEqual(events[-1]["data"]["code"], expected)
            self.assertFalse(events[-1]["data"]["publication_started"])
            self.assertIn("repo", (self.stage / "blueprint.conf").read_text())

    def test_repository_partial_failure_and_ssh_boundary(self):
        target = self.repository_fixture(remote="git@example.test:public.git")
        self.environment["TEST_CLONE_FAIL"] = "true"
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(result.returncode, 2, events)
        self.assertTrue(events[-1]["data"]["target_mutation_may_have_started"])
        self.assertTrue(target.is_dir())
        self.assertFalse((target / ".git").exists())
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(events[-1]["data"]["code"], "repository_target_conflict")
        self.assertEqual((self.root / "repo-log").read_text(), "clone\n")

    def test_repository_unselected_and_human_clone(self):
        self.repository_fixture()
        result = subprocess.run(["bash", "-c",
            'source modules/bootstrap/workspace/repositories-helpers.sh; '
            'repository_clone "$TEST_REPO_REMOTE" "$HOME/disposable"'],
            cwd=self.project, env=self.environment, check=False)
        self.assertEqual(result.returncode, 0)
        self.assertEqual((self.root / "repo-log").read_text(),
                         f"human:clone {self.environment['TEST_REPO_REMOTE']} {self.home}/disposable\n")
        blueprint = self.stage / "blueprint.conf"
        blueprint.write_text(blueprint.read_text().replace('[git-repositories]\nrepo\n',
                                                          '[git-repositories]\n'))
        self.environment["TEST_GIT_BROKEN"] = "true"
        self.pack()
        result, prepared = self.invoke()
        self.assertEqual(result.returncode, 0, prepared)
        self.assertEqual(self.execute(prepared[1]["data"]["prepared_plan_id"])[0].returncode, 0)

    def test_repository_unavailable_branch_is_execution_failure(self):
        target = self.repository_fixture()
        self.environment["TEST_CHECKOUT_FAIL"] = "true"
        self.pack()
        plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(plan)
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]["data"]["code"], "bootstrap_failed")
        self.assertTrue(events[-1]["data"]["target_mutation_may_have_started"])
        self.assertEqual((target / ".branch").read_text().strip(), "default")

    def test_repository_credentials_rejected_privately(self):
        self.repository_fixture(remote="https://user:secret@example.test/private.git")
        self.pack()
        result, events = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(b"secret", result.stdout + result.stderr)
        logs = b"".join(p.read_bytes() for p in (self.project / "logs").rglob("*.log"))
        self.assertNotIn(b"secret", logs)

    def test_execute_selected_formula_through_production_module(self):
        blueprint = self.stage / "blueprint.conf"
        blueprint.write_text(blueprint.read_text().replace(
            'homebrew-packages="false"', 'homebrew-packages="true"').replace(
            '[homebrew-packages]\n', '[homebrew-packages]\nfixture-formula\n'))
        bundle.write_file(self.stage / "generated/brew-packages.conf", b"fixture-formula\n")
        brew = self.root / "bin/brew"
        brew.write_text('''#!/bin/bash
case "$*" in
  --prefix) echo /opt/homebrew ;;
  "list --formula --full-name")
    [[ ! -f "$TEST_FORMULA_INSTALLED" ]] || echo fixture-formula ;;
  "install fixture-formula")
    [[ "$MACSEED_APPLICATION_EXECUTION" == true && "$HOMEBREW_NO_SUDO" == 1 &&
       "$HOMEBREW_NO_INSTALL_CLEANUP" == 1 && ! -t 0 && ! -t 1 ]] || exit 2
    echo install >> "$TEST_FORMULA_LOG"
    [[ "${TEST_FORMULA_FAIL:-false}" != true ]] || exit 2
    touch "$TEST_FORMULA_INSTALLED" ;;
  *) exit 2 ;;
esac
''')
        brew.chmod(0o700)
        self.environment["TEST_FORMULA_INSTALLED"] = str(self.root / "formula-installed")
        self.environment["TEST_FORMULA_LOG"] = str(self.root / "formula-log")
        self.environment["PATH"] = str(self.root / "bin") + ":/usr/bin:/bin:/usr/sbin:/sbin"
        self.allow_application_bootstrap()
        self.pack()
        prepared = self.invoke()[1][1]["data"]["prepared_plan_id"]
        result, events = self.execute(prepared)
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue((self.root / "formula-installed").exists())
        self.assertNotIn(b"fixture-formula", result.stdout)
        self.assertTrue(events[-2]["data"]["target_mutation_may_have_started"])
        self.assertEqual(events[-2]["data"]["verification"]["verdict"],
                         "selected_requirements_verified")
        repeated_plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        repeated, _ = self.execute(repeated_plan)
        self.assertEqual(repeated.returncode, 0)
        self.assertEqual((self.root / "formula-log").read_text().splitlines(), ["install"])
        (self.root / "formula-installed").unlink()
        self.environment["TEST_FORMULA_FAIL"] = "true"
        failed_plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        failed, events = self.execute(failed_plan)
        self.assertEqual(failed.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "bootstrap_failed")
        self.assertTrue(events[-1]["data"]["target_mutation_may_have_started"])

    def test_execute_repreviews_and_publishes_only_after_gates(self):
        self.pack()
        self.allow_application_bootstrap()
        prepared = self.invoke()[1][1]["data"]["prepared_plan_id"]
        stale, stale_events = self.execute("0" * 64)
        self.assertEqual(stale.returncode, 2)
        self.assertEqual(stale_events[-1]["data"]["code"], "stale_plan")
        self.assertFalse(stale_events[-1]["data"]["publication_occurred"])
        self.assertFalse(stale_events[-1]["data"]["target_mutation_may_have_started"])
        self.assertFalse((self.project / "config/blueprint.conf").exists())
        self.assertFalse((self.home / "Projects").exists())

        self.assertEqual(self.execute("A" * 64)[1][0]["data"]["code"], "invalid_request")
        self.assertEqual(self.execute("0" * 63)[1][0]["data"]["code"], "invalid_request")
        self.assertEqual(self.execute(prepared, secure=True)[1][-1]["data"]["code"], "invalid_selection")
        self.assertFalse((self.project / "config/blueprint.conf").exists())

        success, events = self.execute(prepared)
        self.assertEqual(success.returncode, 0, success.stderr)
        self.assertEqual(events[-1]["type"], "completed")
        self.assertEqual([row["sequence"] for row in events], list(range(1, len(events) + 1)))
        self.assertEqual([row["type"] for row in events],
                         ["started", "phase_started", "phase_completed", "phase_started",
                          "phase_completed", "phase_started", "phase_completed", "result", "completed"])
        final = events[-2]["data"]
        self.assertEqual(final["execution_status"], "completed")
        self.assertTrue(final["publication_occurred"])
        self.assertTrue(final["target_mutation_may_have_started"])
        self.assertEqual(final["prepared_plan_id"], prepared)
        self.assertEqual(final["verification"]["verdict"], "selected_requirements_verified")
        self.assertTrue((self.project / "config/blueprint.conf").exists())
        self.assertTrue((self.home / "Projects").is_dir())
        for sensitive in (str(self.archive), str(self.home), "Projects|workspace"):
            self.assertNotIn(sensitive.encode(), success.stdout)

    def test_execute_rejects_target_change_and_publication_failure(self):
        self.pack()
        self.allow_application_bootstrap()
        prepared = self.invoke()[1][1]["data"]["prepared_plan_id"]
        (self.home / "Projects").mkdir()
        stale, events = self.execute(prepared)
        self.assertEqual(stale.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "stale_plan")
        self.assertFalse(events[-1]["data"]["publication_started"])
        self.assertFalse((self.project / "config/blueprint.conf").exists())

        current = self.invoke()[1][1]["data"]["prepared_plan_id"]
        (self.project / "config/blueprint.conf").mkdir()
        failed, events = self.execute(current)
        self.assertEqual(failed.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "publication_failed")
        self.assertTrue(events[-1]["data"]["publication_started"])
        self.assertFalse(events[-1]["data"]["publication_occurred"])
        self.assertFalse(events[-1]["data"]["target_mutation_may_have_started"])

    def test_execute_readiness_failures_never_publish(self):
        self.pack(secure=True)
        prepared = self.invoke(secure=True)[1][1]["data"]["prepared_plan_id"]
        secure, events = self.execute(prepared, secure=True)
        self.assertEqual(secure.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "secure_bridge_required")
        self.assertFalse(events[-1]["data"]["publication_occurred"])
        self.assertFalse(events[-1]["data"]["target_mutation_may_have_started"])
        self.assertFalse((self.project / "config/blueprint.conf").exists())

        ordinary_id = self.invoke()[1][1]["data"]["prepared_plan_id"]
        denied, events = self.execute(ordinary_id)
        self.assertEqual(denied.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "authorization_required")
        self.assertFalse((self.project / "config/blueprint.conf").exists())
        self.assertFalse((self.home / "Projects").exists())

        blueprint = self.stage / "blueprint.conf"
        blueprint.write_text(blueprint.read_text().replace("[git-repositories]\n", "[git-repositories]\nrepo\n"))
        bundle.write_file(self.stage / "generated/workspace/repositories.conf",
                          ('[repo]\nNAME="repo"\nPATH="/Users/source/Projects/repo"\n'
                           'REMOTE="git@example.com:repo.git"\nDEFAULT_BRANCH="main"\n'
                           'CURRENT_BRANCH="main"\nHAS_UNCOMMITTED_CHANGES="false"\n'
                           'HAS_VSCODE_FOLDER="false"\nHAS_SETTINGS="false"\n'
                           'HAS_TASKS="false"\nHAS_LAUNCH="false"\n'
                           'HAS_EXTENSIONS="false"\n').encode())
        self.archive = self.root / "with-repository.mbt"
        self.pack()
        prepared_result, prepared_events = self.invoke()
        logs = "\n".join(p.read_text() for p in (self.project / "logs/history").glob("preview-*.log"))
        self.assertEqual(prepared_result.returncode, 0,
                         (prepared_events, [line for line in logs.splitlines() if "[ERROR]" in line]))
        unsupported_id = prepared_events[1]["data"]["prepared_plan_id"]
        rejected, events = self.execute(unsupported_id)
        self.assertEqual(rejected.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "authorization_required")
        self.assertFalse((self.project / "config/blueprint.conf").exists())

    def test_execute_verification_and_partial_failure_states(self):
        self.pack()
        self.allow_application_bootstrap()
        original = (self.project / "bootstrap.sh").read_text()
        marker = "source modules/bootstrap/workspace/workspace.sh\n"
        (self.project / "bootstrap.sh").write_text(
            original.replace(marker, marker + "bootstrap_workspace_folders() { return 0; }\n"))
        prepared = self.invoke()[1][1]["data"]["prepared_plan_id"]
        completed, events = self.execute(prepared)
        self.assertEqual(completed.returncode, 0)
        self.assertEqual(events[-2]["data"]["execution_status"], "completed")
        self.assertEqual(events[-2]["data"]["verification"]["verdict"], "differences_detected")
        self.assertFalse((self.home / "Projects").exists())

        # A new isolated Bundle and local state are needed for the failure case.
        (self.project / "bootstrap.sh").write_text(
            original.replace(marker, marker +
                             'bootstrap_workspace_folders() { mkdir -p "$HOME/Projects"; '
                             'MODULE_CHANGED=true; return 2; }\n'))
        next_plan = self.invoke()[1][1]["data"]["prepared_plan_id"]
        failed, events = self.execute(next_plan)
        self.assertEqual(failed.returncode, 2)
        self.assertEqual(events[-1]["data"]["code"], "bootstrap_failed")
        self.assertTrue(events[-1]["data"]["publication_occurred"])
        self.assertTrue(events[-1]["data"]["target_mutation_may_have_started"])
        self.assertEqual(events[-1]["data"]["execution_status"],
                         "failed_after_mutation_may_have_started")
        self.assertTrue((self.home / "Projects").exists())

    def test_execute_failure_after_publication_before_mutation(self):
        self.pack()
        self.allow_application_bootstrap()
        sudo_count = self.root / "sudo-count"
        (self.root / "bin/sudo").write_text(
            "#!/bin/bash\n"
            'count=$(cat "$TEST_SUDO_COUNT" 2>/dev/null || echo 0)\n'
            'count=$((count+1))\n'
            'printf "%s" "$count" > "$TEST_SUDO_COUNT"\n'
            '[[ "$count" -eq 1 ]]\n')
        self.environment["TEST_SUDO_COUNT"] = str(sudo_count)
        prepared = self.invoke()[1][1]["data"]["prepared_plan_id"]
        failed, events = self.execute(prepared)
        self.assertEqual(failed.returncode, 2)
        state = events[-1]["data"]
        self.assertEqual(state["code"], "bootstrap_failed")
        self.assertTrue(state["publication_occurred"])
        self.assertFalse(state["target_mutation_may_have_started"])
        self.assertEqual(state["execution_status"], "failed_before_mutation")
        self.assertTrue((self.project / "config/blueprint.conf").exists())
        self.assertFalse((self.home / "Projects").exists())

    def test_execute_verification_incomplete_is_not_execution_failure(self):
        self.pack()
        self.allow_application_bootstrap()
        bootstrap = self.project / "bootstrap.sh"
        original = bootstrap.read_text()
        marker = "source modules/verification/comparison.sh\n"
        bootstrap.write_text(original.replace(
            marker, marker + "verification_input_identity() { return 2; }\n"))
        prepared = self.invoke()[1][1]["data"]["prepared_plan_id"]
        completed, events = self.execute(prepared)
        self.assertEqual(completed.returncode, 0)
        final = events[-2]["data"]
        self.assertEqual(final["execution_status"], "completed")
        self.assertEqual(final["verification"]["status"], "incomplete")
        self.assertEqual(final["verification"]["verdict"], "incomplete")

    def test_execute_cancellation_stops_owned_group(self):
        self.pack()
        self.allow_application_bootstrap()
        bootstrap = self.project / "bootstrap.sh"
        marker = "printf 'mutation_may_have_started\\n' >&\"$MACSEED_EXECUTION_SIGNAL_FD\""
        self.assertIn(marker, bootstrap.read_text())
        bootstrap.write_text(bootstrap.read_text().replace(
            marker, marker + '\n    touch "$TEST_BOUNDARY"\n    sleep 30'))
        boundary = self.root / "boundary"
        self.environment["TEST_BOUNDARY"] = str(boundary)
        prepared = self.invoke()[1][1]["data"]["prepared_plan_id"]
        request = {"protocol_version": 1, "operation_id": "cancel-1",
                   "operation": "restore_execute",
                   "parameters": {"path": str(self.archive), "disabled_groups": [],
                                  "include_secure": False,
                                  "expected_prepared_plan_id": prepared}}
        unrelated = subprocess.Popen(["sleep", "30"])
        def cleanup_unrelated():
            if unrelated.poll() is None:
                unrelated.terminate()
            unrelated.wait()
        self.addCleanup(cleanup_unrelated)
        core = subprocess.Popen(
            ["bash", str(self.project / "modules/core/application-interface/core.sh")],
            stdin=subprocess.PIPE, cwd=self.project, env=self.environment,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: core.kill() if core.poll() is None else None)
        core.stdin.write(json.dumps(request).encode())
        core.stdin.close()
        for _ in range(1000):
            if boundary.exists():
                break
            if core.poll() is not None:
                break
            time.sleep(0.01)
        self.assertTrue(boundary.exists(), core.stderr.read() if core.poll() is not None else "")
        core.send_signal(signal.SIGTERM)
        core.wait(timeout=10)
        events = [json.loads(line) for line in core.stdout.read().splitlines()]
        core.stdout.close()
        core.stderr.close()
        self.assertEqual(core.returncode, 130)
        self.assertEqual(events[-1]["type"], "failed")
        self.assertEqual(events[-1]["data"]["code"], "cancelled")
        self.assertTrue(events[-1]["data"]["publication_occurred"])
        self.assertTrue(events[-1]["data"]["target_mutation_may_have_started"])
        self.assertIsNone(unrelated.poll())

    def test_owned_process_boundary_and_group_cancellation(self):
        spec = importlib.util.spec_from_file_location(
            "execution", ROOT / "modules/core/application-interface/execution.py")
        execution = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(execution)
        fixture = self.root / "owned"
        fixture.mkdir()
        grandchild_script = fixture / "grandchild.py"
        grandchild_script.write_text(
            "import os, signal, sys, time\n"
            "def stop(*args):\n"
            "    open(os.environ['TEST_STOPPED'], 'w').write('stopped')\n"
            "    sys.exit(0)\n"
            "signal.signal(signal.SIGTERM, stop)\n"
            "open(os.environ['TEST_READY'], 'w').write('ready')\n"
            "while True: time.sleep(1)\n")
        script = fixture / "bootstrap.sh"
        script.write_text("#!/bin/bash\n"
                          "printf 'mutation_may_have_started\\n' >&\"$MACSEED_EXECUTION_SIGNAL_FD\"\n"
                          "python3 grandchild.py &\n"
                          "printf '%s\\n' \"$!\" > \"$TEST_GRANDCHILD\"\n"
                          "wait\n")
        script.chmod(0o700)
        grandchild = self.root / "grandchild"
        ready = self.root / "ready"
        unrelated = subprocess.Popen(["sleep", "30"])
        def cleanup_unrelated():
            if unrelated.poll() is None:
                unrelated.terminate()
            unrelated.wait()
        self.addCleanup(cleanup_unrelated)
        stopped = self.root / "stopped"
        owned = execution.OwnedBootstrap(
            fixture, dict(self.environment, TEST_GRANDCHILD=str(grandchild),
                          TEST_STOPPED=str(stopped), TEST_READY=str(ready)))
        self.addCleanup(lambda: owned.cancel() if owned.process.poll() is None else None)
        for _ in range(100):
            if grandchild.exists() and ready.exists():
                break
            time.sleep(0.01)
        self.assertTrue(grandchild.exists() and ready.exists())
        child_pid = int(grandchild.read_text())
        self.assertEqual(owned.cancel(), 130)
        self.assertEqual(owned.wait(), owned.process.returncode)
        self.assertTrue(owned.mutation_may_have_started)
        self.assertIsNone(unrelated.poll())
        for _ in range(100):
            if stopped.exists():
                break
            time.sleep(0.01)
        self.assertTrue(stopped.exists(), f"grandchild {child_pid} did not stop")

        script.write_text("#!/bin/bash\n"
                          "printf 'mutation_may_have_started\\n' >&\"$MACSEED_EXECUTION_SIGNAL_FD\"\n"
                          "exit 2\n")
        failed = execution.OwnedBootstrap(fixture, self.environment)
        self.assertEqual(failed.wait(), 2)
        self.assertTrue(failed.mutation_may_have_started)

    def test_production_bootstrap_boundary_and_module_changed(self):
        spec = importlib.util.spec_from_file_location(
            "execution", ROOT / "modules/core/application-interface/execution.py")
        execution = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(execution)
        environment = dict(self.environment, BLUEPRINT_FILE=str(self.stage / "blueprint.conf"),
                           BLUEPRINT_GENERATED_DIR=str(self.stage / "generated"),
                           BUNDLE_RESTORE_ACTIVE="true", BS_INSTALL_DIR=str(self.root / "bin"))
        denied = execution.OwnedBootstrap(self.project, environment)
        self.assertEqual(denied.wait(), 2)
        self.assertFalse(denied.mutation_may_have_started)
        self.assertFalse((self.home / "Projects").exists())
        (self.root / "bin/sudo").write_text("#!/bin/bash\nexit 0\n")
        (self.project / "scripts").mkdir()
        (self.project / "bin").mkdir()
        shutil.copy2(ROOT / "scripts/install-bs.sh", self.project / "scripts/install-bs.sh")
        shutil.copy2(ROOT / "bin/bs", self.project / "bin/bs")
        (self.root / "bin/bs").symlink_to(self.project / "bin/bs")
        allowed = execution.OwnedBootstrap(self.project, environment)
        status = allowed.wait()
        logs = "\n".join(p.read_text() for p in (self.project / "logs/history").glob("bootstrap-*.log"))
        self.assertIn(status, (0, 1), logs)
        self.assertTrue(allowed.mutation_may_have_started)
        self.assertTrue((self.home / "Projects").is_dir())
        self.assertIn("Changed: Yes", logs)

    def test_application_child_has_no_input_or_controlling_terminal(self):
        spec = importlib.util.spec_from_file_location(
            "execution", ROOT / "modules/core/application-interface/execution.py")
        execution = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(execution)
        fixture = self.root / "no-terminal"
        fixture.mkdir()
        (fixture / "bootstrap.sh").write_text(
            "#!/bin/bash\n"
            "[[ ! -t 0 ]] || exit 2\n"
            "if printf probe > /dev/tty 2>/dev/null; then exit 2; fi\n"
            "if IFS= read -r answer; then exit 2; fi\n"
            "exit 0\n")
        (fixture / "bootstrap.sh").chmod(0o700)
        owned = execution.OwnedBootstrap(fixture, self.environment)
        self.assertEqual(owned.wait(), 0)
        self.assertFalse(owned.mutation_may_have_started)

    def test_human_sudo_fallback_and_application_prompt_guard(self):
        sudo_log = self.root / "sudo.log"
        (self.root / "bin/sudo").write_text(
            "#!/bin/bash\n"
            "printf '%s\\n' \"$*\" >> \"$TEST_SUDO_LOG\"\n"
            "[[ \"$1\" == -v ]]\n")
        environment = dict(self.environment, TEST_SUDO_LOG=str(sudo_log))
        command = (
            "source modules/core/preflight/preflight.sh; "
            "detail() { :; }; info() { :; }; error() { :; }; "
            "check_admin")
        human = subprocess.run(["bash", "-c", command], cwd=self.project,
                               env=environment, input=b"", capture_output=True, check=False)
        self.assertEqual(human.returncode, 0)
        self.assertEqual(sudo_log.read_text().splitlines(), ["-n true", "-v"])
        sudo_log.unlink()
        environment["MACSEED_APPLICATION_EXECUTION"] = "true"
        app = subprocess.run(["bash", "-c", command], cwd=self.project,
                             env=environment, input=b"", capture_output=True, check=False)
        self.assertEqual(app.returncode, 2)
        self.assertEqual(sudo_log.read_text().splitlines(), ["-n true"])
        prompt = subprocess.run(
            ["bash", "-c", "source modules/bundle/commands.sh; bundle_prompt 'Confirm?'"],
            cwd=self.project, env=environment, input=b"yes\n", capture_output=True, check=False)
        self.assertEqual(prompt.returncode, 2)
        self.assertEqual(prompt.stdout, b"")

    def test_recovery_and_failures_leave_state_untouched(self):
        self.pack()
        recovery = self.project / "config/.bundle-publication"
        recovery.mkdir()
        marker = recovery / "incomplete"
        marker.write_text("pending-state")
        result, events = self.invoke()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual([event["type"] for event in events], ["started", "failed"])
        self.assertEqual(events[-1]["data"]["code"], "recovery_required")
        self.assertEqual(marker.read_text(), "pending-state")
        self.assertFalse((self.project / "config/generated").exists())
        self.assertFalse((self.project / "config/blueprint.conf").exists())
        marker.unlink()
        recovery.rmdir()
        self.archive.write_bytes(b"invalid archive")
        invalid, invalid_events = self.invoke()
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(invalid_events[-1]["data"]["code"], "bundle_invalid")

    def test_secure_without_component_and_preview_failure(self):
        self.pack()
        invalid, events = self.invoke(secure=True)
        self.assertNotEqual(invalid.returncode, 0)
        self.assertEqual(events[-1]["data"]["code"], "invalid_selection")
        (self.root / "bin/curl").write_text("#!/bin/bash\nexit 2\n")
        failed, failed_events = self.invoke()
        self.assertNotEqual(failed.returncode, 0)
        self.assertEqual(failed_events[-1]["data"]["code"], "preview_failed")
        self.assertFalse((self.project / "config/generated").exists())

    def test_cancellation_cleans_stage(self):
        self.pack()
        (self.root / "bin/curl").write_text("#!/bin/bash\nsleep 20\n")
        request = {"protocol_version": 1, "operation_id": "cancel-1",
                   "operation": "restore_prepare",
                   "parameters": {"path": str(self.archive), "disabled_groups": [],
                                  "include_secure": False}}
        process = subprocess.Popen(
            ["bash", str(self.project / "modules/core/application-interface/core.sh")],
            cwd=self.project, env=self.environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        try:
            process.stdin.write(json.dumps(request).encode())
            process.stdin.close()
            deadline = time.monotonic() + 5
            while not list(self.private_temp.glob("mbt-bundle-*")) and time.monotonic() < deadline:
                time.sleep(0.02)
            self.assertTrue(list(self.private_temp.glob("mbt-bundle-*")))
            process.send_signal(signal.SIGTERM)
            output = process.stdout.read()
            process.wait(timeout=5)
            events = [json.loads(line) for line in output.splitlines()]
            self.assertEqual([event["type"] for event in events], ["started", "failed"])
            self.assertEqual(events[-1]["data"]["code"], "cancelled")
            self.assertFalse(list(self.private_temp.glob("mbt-bundle-*")))
            self.assertFalse((self.project / "config/generated").exists())
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            process.stdout.close()
            process.stderr.close()


if __name__ == "__main__":
    unittest.main()
