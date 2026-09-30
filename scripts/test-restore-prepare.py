#!/usr/bin/env python3
"""Isolated production Preview checks for structured Restore preparation."""

import json
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
