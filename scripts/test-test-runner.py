#!/usr/bin/env python3
"""Cheap runner contract checks; no Macseed operations or full regression."""
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

import test_runner as runner
from test_unittest import load

ROOT = Path(__file__).resolve().parent.parent


class RunnerTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'scripts').mkdir()
        dependency = self.root / 'modules/core/application-interface'
        dependency.mkdir(parents=True)
        shutil.copy2(ROOT / 'modules/core/application-interface/item_execution.py', dependency)
        for name in ('test_runner.py', 'test_unittest.py'):
            shutil.copy2(ROOT / 'scripts' / name, self.root / 'scripts' / name)
        self.inventory = []

    def fixture(self, name, body):
        path = 'scripts/test-' + name + '.py'
        (self.root / path).write_text('import unittest, os, time\nfrom pathlib import Path\n'
            'class Fixture(unittest.TestCase):\n    def test_fixture(self):\n' +
            ''.join('        ' + line + '\n' for line in body.splitlines()))
        self.inventory.append(path)

    def command(self, *args):
        (self.root / 'scripts/test-timings.json').write_text(json.dumps(dict(
            unknown_suite_seconds=1, suites={key: i + 1 for i, key in enumerate(self.inventory)})))
        return [sys.executable, '-B', str(self.root / 'scripts/test_runner.py'),
                *self.inventory, '--', '--output', str(self.root / 'result'), *args]

    def run_fixture(self, *args):
        result = subprocess.run(self.command(*args), cwd=self.root, capture_output=True, timeout=30)
        rows = json.loads((self.root / 'result/safe/summary.json').read_text())
        return result, rows

    def test_real_ids_are_exact_disjoint_and_new_cases_are_assigned(self):
        inventory = re.findall(r'^    (scripts/test-\S+)$', (ROOT / 'scripts/test.sh').read_text(), re.M)
        weights = json.loads((ROOT / 'scripts/test-timings.json').read_text())
        parts = runner.plan(inventory, weights, 4)
        original = list(load(ROOT / runner.HEAVY))
        assigned = [key for part in parts for row in part if row['suite'] == runner.HEAVY for key in row['ids']]
        self.assertEqual(set(assigned), set(original))
        self.assertEqual(len(assigned), len(set(assigned)))
        self.assertEqual({row['suite'] for part in parts for row in part}, set(inventory))
        with patch.object(runner, 'load', return_value={key: None for key in original + ['new.method']}):
            expanded = runner.plan(inventory, weights, 4)
        self.assertEqual(sum('new.method' in row['ids'] for part in expanded for row in part), 1)
        units = [dict(suite=runner.HEAVY, ids=original + ['new.method'])]
        runner.verify_partitions(units, [[dict(suite=runner.HEAVY, ids=original)],
                                        [dict(suite=runner.HEAVY, ids=['new.method'])]])
        for invalid in ([[]], [[dict(suite=runner.HEAVY, ids=original)]],
                        [[dict(suite=runner.HEAVY, ids=original + ['new.method', original[0]])]]):
            with self.assertRaises(ValueError):
                runner.verify_partitions(units, invalid)

    def test_discovery_errors_and_empty_suites_fail_closed(self):
        path = self.root / 'scripts/bad.py'
        for source in ('import missing_fixture_dependency', 'import unittest'):
            path.write_text(source)
            with self.assertRaises((ImportError, ValueError)):
                load(path)

    def test_multiple_failures_keep_safe_logs_summary_and_reproduction(self):
        self.fixture('a', "print('PRIVATE_SENTINEL'); self.fail('PRIVATE_SENTINEL')")
        self.fixture('b', 'self.assertEqual(1, 2)')
        self.fixture('c', 'self.assertTrue(True)')
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([row['status'] for row in rows], ['FAIL', 'FAIL', 'PASS'])
        self.assertEqual(len(list((self.root / 'result/safe').glob('*.log'))), 3)
        safe = ''.join(path.read_text() for path in (self.root / 'result/safe').iterdir())
        self.assertNotIn('PRIVATE_SENTINEL', safe)
        self.assertIn('--case test_a.Fixture.test_fixture', safe)
        self.assertIn('body', safe)
        self.assertIn('cleanup', safe)

    def test_local_fail_fast(self):
        self.fixture('a', 'self.fail()')
        self.fixture('b', 'self.fail()')
        result, rows = self.run_fixture()
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['status'] for row in rows], ['FAIL', 'NOT RUN'])

    def test_existing_skip_and_incomplete_worker(self):
        self.fixture('a', "self.skipTest('PRIVATE_SENTINEL')")
        self.fixture('b', 'os._exit(0)')
        self.fixture('c', 'self.assertTrue(True)')
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['status'] for row in rows], ['SKIP', 'ERROR', 'NOT RUN'])

    def test_dirty_cleanup_stops_after_assertion(self):
        self.fixture('a', "Path(os.environ['TMPDIR'], 'leftover').touch(); self.fail()")
        self.fixture('b', 'self.assertTrue(True)')
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['status'] for row in rows], ['ERROR', 'NOT RUN'])

    def test_cleanup_error_stops_even_after_teardown(self):
        self.fixture('a', "self.addCleanup(lambda: self.fail('cleanup'))")
        self.fixture('b', 'self.assertTrue(True)')
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['status'] for row in rows], ['ERROR', 'NOT RUN'])

    def test_surviving_process_stops_later_suites(self):
        self.fixture('a', 'import subprocess\nsubprocess.Popen(["sleep", "30"])')
        self.fixture('b', 'self.assertTrue(True)')
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['status'] for row in rows], ['ERROR', 'NOT RUN'])
        self.assertEqual(rows[0]['reason'], 'surviving_processes')

    def test_deadline_reports_error_and_stops_owned_work(self):
        path = self.root / 'scripts/test_runner.py'
        source = path.read_text()
        boundary = "max(300, row['seconds'] * 3 + 60)"
        self.assertEqual(source.count(boundary), 1)
        path.write_text(source.replace(boundary, '0.05'))
        self.fixture('a', 'time.sleep(30)')
        self.fixture('b', 'self.assertTrue(True)')
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['status'] for row in rows], ['ERROR', 'NOT RUN'])
        self.assertEqual(rows[0]['reason'], 'deadline')

    def test_shell_assertions_are_safe_but_unclassified_exit_stops(self):
        for name, body in (
                ('a', 'fail() { echo "FAIL: $*"; }; private=PRIVATE_SENTINEL\n'
                      'fail "fixture assertion: $private"\nexit 1\n'),
                ('b', 'exit 1\n'), ('c', 'exit 0\n')):
            path = 'scripts/test-' + name + '.sh'
            (self.root / path).write_text(body)
            self.inventory.append(path)
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['status'] for row in rows], ['FAIL', 'ERROR', 'NOT RUN'])
        self.assertEqual(rows[0]['checks'], [{'line': 2, 'label': 'fixture assertion: '}])
        safe = ''.join(path.read_text() for path in (self.root / 'result/safe').iterdir())
        self.assertNotIn('PRIVATE_SENTINEL', safe)

    def test_cancel_records_error_and_not_run(self):
        marker = self.root / 'started'
        self.fixture('a', f'Path({str(marker)!r}).touch(); time.sleep(30)')
        self.fixture('b', 'self.assertTrue(True)')
        child = subprocess.Popen(self.command('--ci'), stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: child.poll() is None and child.kill())
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(.02)
        self.assertTrue(marker.exists())
        child.send_signal(signal.SIGTERM)
        _, stderr = child.communicate(timeout=10)
        self.assertEqual(child.returncode, 143, stderr)
        rows = json.loads((self.root / 'result/safe/summary.json').read_text())
        self.assertEqual([row['status'] for row in rows], ['ERROR', 'NOT RUN'])


if __name__ == '__main__':
    unittest.main()
