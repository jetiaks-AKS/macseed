#!/usr/bin/env python3
"""Focused Stage 15B/15C structured Core checks."""

import io
import json
import pathlib
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = ROOT / "modules/core/application-interface/core.sh"
sys.dont_write_bytecode = True
sys.path.insert(0, str(ROOT / "modules/bundle"))
import bundle


def invoke(payload):
    return subprocess.run(
        ["bash", str(CORE)], input=payload, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, cwd=ROOT, check=False,
    )


class CoreInterfaceTests(unittest.TestCase):
    def test_capabilities(self):
        result = invoke(b'{"protocol_version":1,"operation_id":"round_trip-1","operation":"capabilities"}\n')
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        self.assertEqual(len(lines), 3)
        records = [json.loads(line) for line in lines]
        self.assertEqual([row["sequence"] for row in records], [1, 2, 3])
        self.assertEqual([row["type"] for row in records], ["started", "result", "completed"])
        self.assertEqual({row["operation_id"] for row in records}, {"round_trip-1"})
        self.assertEqual({row["protocol_version"] for row in records}, {1})
        self.assertEqual(records[1]["data"], {
            "protocol_version": 1,
            "product_version": "3.4.0",
            "features": {"restore_selection": {"version": 1, "inventory": "bundle_inspect", "selection_modes": ["category", "items"]}},
            "operations": ["capabilities", "bundle_inspect", "restore_prepare", "restore_execute", "capture_prepare", "capture_execute", "environment_compare"],
        })
        self.assertEqual(sum(row["type"] in ("completed", "failed") for row in records), 1)
        self.assertEqual(records[-1]["type"], "completed")

    def test_invalid_requests(self):
        cases = (
            (b"", "invalid_request"),
            (b"{", "invalid_request"),
            (b'{"protocol_version":2,"operation_id":"id","operation":"capabilities"}', "unsupported_protocol"),
            (b'{"protocol_version":true,"operation_id":"id","operation":"capabilities"}', "invalid_request"),
            (b'{"protocol_version":1,"operation_id":"id","operation":"other"}', "unsupported_operation"),
            (b'{"protocol_version":1,"operation_id":"id"}', "invalid_request"),
            (b'{"protocol_version":1,"operation_id":7,"operation":"capabilities"}', "invalid_request"),
            (b'{"protocol_version":1,"operation_id":"id","operation":7}', "invalid_request"),
            (b'{"protocol_version":1,"operation_id":"id","operation":"capabilities"}{"extra":1}', "invalid_request"),
            (b'{"protocol_version":1,"operation_id":"id","operation":"capabilities","extra":1}', "invalid_request"),
            (b'{"protocol_version":1,"protocol_version":1,"operation_id":"id","operation":"capabilities"}', "invalid_request"),
        )
        for payload, code in cases:
            with self.subTest(payload=payload):
                result = invoke(payload)
                self.assertNotEqual(result.returncode, 0)
                records = [json.loads(line) for line in result.stdout.splitlines()]
                self.assertEqual(len(records), 1)
                self.assertEqual(records[0]["type"], "failed")
                self.assertEqual(records[0]["data"]["code"], code)

    def test_human_cli_unchanged(self):
        for flag, expected in (("--version", "Version 3.4.0"), ("--help", "--capture")):
            with self.subTest(flag=flag):
                result = subprocess.run(
                    ["bash", "bootstrap.sh", flag], cwd=ROOT,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout.decode())

    def test_bundle_inspect(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = pathlib.Path(temporary)
            stage = root / "stage"
            stage.mkdir()
            output = root / "demo bundle é.mbt"
            categories = {name: False for name in bundle.CATEGORY_FLAGS}
            categories["vscode-settings"] = True
            blueprint = ("[categories]\n" +
                         "".join(f'{name}="{str(enabled).lower()}"\n'
                                 for name, enabled in categories.items()) +
                         "".join(f"\n[{name}]\n" +
                                 ("demo-app\n" if name == "homebrew-casks" else "")
                                 for name in bundle.ITEMS)).encode()
            bundle.write_file(stage / "blueprint.conf", blueprint)
            bundle.write_file(stage / "generated/brew-casks.conf", b"demo-app\n")
            private = b'{"private-setting":"not-for-protocol"}'
            bundle.write_file(stage / "generated/vscode/settings.json", private)
            bundle.write_file(stage / "secure.age", b"age-encryption.org/v1\nprivate-ciphertext")
            bundle.pack(stage, output, "/Users/source")
            original = output.read_bytes()

            def inspect(path):
                return invoke(json.dumps({
                    "protocol_version": 1, "operation_id": "inspect-1",
                    "operation": "bundle_inspect", "parameters": {"path": str(path)},
                }).encode())

            response = inspect(output)
            self.assertEqual(response.returncode, 0, response.stderr)
            events = [json.loads(line) for line in response.stdout.splitlines()]
            self.assertEqual([event["type"] for event in events], ["started", "result", "completed"])
            self.assertEqual([event["sequence"] for event in events], [1, 2, 3])
            self.assertEqual({key: value for key, value in events[1]["data"].items() if key != "restore_selection"}, {
                "format_version": 1,
                "selected_categories": ["vscode-settings"],
                "selected_item_counts": {name: 1 if name == "homebrew-casks" else 0
                                         for name in bundle.ITEMS},
                "secure_component": True,
                "external_tools": {},
            })
            self.assertEqual(events[-1]["type"], "completed")
            self.assertNotIn(str(output).encode(), response.stdout)
            self.assertNotIn(private, response.stdout)
            self.assertNotIn(b"private-ciphertext", response.stdout)
            self.assertEqual(output.read_bytes(), original)
            self.assertEqual({path.name for path in root.iterdir()}, {"stage", output.name})

            missing = inspect(root / "missing.mbt")
            self.assertEqual(json.loads(missing.stdout.splitlines()[-1])["data"]["code"],
                             "bundle_unavailable")
            malformed = root / "malformed.mbt"
            malformed.write_bytes(b"not a Bundle")
            self.assertEqual(json.loads(inspect(malformed).stdout.splitlines()[-1])["data"]["code"],
                             "bundle_invalid")
            self.assertEqual(json.loads(inspect(stage).stdout.splitlines()[-1])["data"]["code"],
                             "bundle_invalid")
            linked = root / "linked.mbt"
            linked.symlink_to(output)
            self.assertEqual(json.loads(inspect(linked).stdout.splitlines()[-1])["data"]["code"],
                             "bundle_invalid")

            unsupported = root / "unsupported.mbt"
            with tarfile.open(output) as source, tarfile.open(unsupported, "w") as target:
                for member in source.getmembers():
                    data = source.extractfile(member).read()
                    if member.name == "manifest.json":
                        manifest = json.loads(data)
                        manifest["version"] = 2
                        data = json.dumps(manifest).encode()
                    member.size = len(data)
                    target.addfile(member, io.BytesIO(data))
            self.assertEqual(json.loads(inspect(unsupported).stdout.splitlines()[-1])["data"]["code"],
                             "unsupported_bundle")

            tampered = root / "tampered.mbt"
            with tarfile.open(output) as source, tarfile.open(tampered, "w") as target:
                for member in source.getmembers():
                    data = source.extractfile(member).read()
                    if member.name == "generated/brew-casks.conf":
                        data = b"other-app\n"
                    member.size = len(data)
                    target.addfile(member, io.BytesIO(data))
            with self.assertRaises(bundle.Invalid):
                bundle.unpack(tampered, root / "unpacked", "/Users/target")
            failure = inspect(tampered)
            failure_events = [json.loads(line) for line in failure.stdout.splitlines()]
            self.assertNotEqual(failure.returncode, 0)
            self.assertEqual([event["type"] for event in failure_events], ["started", "failed"])
            self.assertEqual(failure_events[-1]["data"]["code"], "bundle_invalid")
            self.assertFalse((root / "unpacked").exists())

    def test_bundle_request_validation(self):
        for parameters in ({"path": "relative.mbt"}, {"path": 7}, {},
                           {"path": "/tmp/example.mbt", "extra": 1}):
            with self.subTest(parameters=parameters):
                response = invoke(json.dumps({
                    "protocol_version": 1, "operation_id": "inspect-2",
                    "operation": "bundle_inspect", "parameters": parameters,
                }).encode())
                self.assertNotEqual(response.returncode, 0)
                events = [json.loads(line) for line in response.stdout.splitlines()]
                self.assertEqual(len(events), 1)
                self.assertEqual(events[0]["type"], "failed")
                self.assertEqual(events[0]["data"]["code"], "invalid_request")


if __name__ == "__main__":
    unittest.main()
