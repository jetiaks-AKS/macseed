#!/usr/bin/env python3
"""Focused, read-only Stage 15B protocol checks."""

import json
import pathlib
import subprocess
import unittest

ROOT = pathlib.Path(__file__).resolve().parent.parent
CORE = ROOT / "modules/core/application-interface/core.sh"


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
            "product_version": "3.3.0",
            "operations": ["capabilities"],
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
        for flag, expected in (("--version", "Version 3.3.0"), ("--help", "--capture")):
            with self.subTest(flag=flag):
                result = subprocess.run(
                    ["bash", "bootstrap.sh", flag], cwd=ROOT,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(expected, result.stdout.decode())


if __name__ == "__main__":
    unittest.main()
