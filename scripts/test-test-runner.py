#!/usr/bin/env python3
"""Cheap runner contract checks; no Macseed operations or full regression."""
import json
import io
from contextlib import redirect_stderr, redirect_stdout
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
        shutil.copy2(ROOT / 'modules/core/performance_trace.py', dependency.parent)
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
        self.assertEqual(parts, runner.plan(inventory, weights, 4))
        original = {suite: list(load(ROOT / suite)) for suite in runner.CASE_SHARDED}
        units = [dict(suite=suite, ids=original.get(suite, [])) for suite in inventory]
        runner.verify_partitions(units, parts)
        for suite, ids in original.items():
            assigned = [key for part in parts for row in part if row['suite'] == suite for key in row['ids']]
            self.assertEqual(set(assigned), set(ids))
            self.assertEqual(len(assigned), len(set(assigned)))
            self.assertEqual(sum(any(row['suite'] == suite for row in part) for part in parts), 4)
        self.assertEqual({row['suite'] for part in parts for row in part}, set(inventory))
        def expanded_load(path):
            suite = path.relative_to(ROOT).as_posix()
            return dict.fromkeys(original[suite] + ['new.method'])
        with patch.object(runner, 'load', side_effect=expanded_load):
            expanded = runner.plan(inventory, weights, 4)
        for suite, ids in original.items():
            self.assertEqual(sum('new.method' in row['ids'] for part in expanded for row in part if row['suite'] == suite), 1)
            self.assertGreaterEqual(runner.case_weights(suite, ids + ['new.method'], weights)['new.method'], 60)
        for invalid in ([[]], parts[:-1], parts + [parts[0]]):
            with self.assertRaises(ValueError): runner.verify_partitions(units, invalid)

    def test_case_weights_preserve_budget_and_conservative_unknowns(self):
        suite = 'fixture'
        weights = dict(unknown_suite_seconds=180, unknown_case_seconds=60,
                       suites={suite: 100}, cases={'a': 30, 'b': 50})
        measured = runner.case_weights(suite, ['a', 'b'], weights)
        self.assertEqual(sum(measured.values()), 100)
        expanded = runner.case_weights(suite, ['a', 'b', 'new'], weights)
        self.assertGreaterEqual(expanded['new'], 60)
        self.assertGreaterEqual(expanded['a'], 30)
        self.assertGreaterEqual(expanded['b'], 50)
        self.assertTrue(all(value > 0 for value in runner.case_weights('unknown', ['one', 'two'], weights).values()))

    def test_case_sharded_cli_selection_is_read_only(self):
        inventory = re.findall(r'^    (scripts/test-\S+)$', (ROOT / 'scripts/test.sh').read_text(), re.M)
        def listed(*args):
            stream = io.StringIO()
            with redirect_stdout(stream), patch.object(runner, 'execute', side_effect=AssertionError('planning executed work')):
                self.assertEqual(runner.main(inventory, [*args, '--list']), 0)
            return json.loads(stream.getvalue())
        for suite in sorted(runner.CASE_SHARDED):
            ids = list(load(ROOT / suite))
            self.assertEqual(listed('--suite', suite)['selected'][0]['ids'], ids)
            selected = listed('--suite', suite, '--case', ids[-1], '--case', ids[0].split('.', 1)[1], '--ci')
            self.assertEqual(selected['selected'][0]['ids'], [ids[-1], ids[0]])
            with redirect_stderr(io.StringIO()), self.assertRaises(SystemExit) as failure:
                listed('--suite', suite, '--case', ids[0], '--case', ids[0])
            self.assertEqual(failure.exception.code, 2)
        quick = listed('--quick', '--ci')['selected']
        self.assertEqual({row['suite']: tuple(row['ids']) for row in quick}, runner.QUICK)
        self.assertEqual(listed('--shard', '2/4')['selected'], listed('--ci', '--shard', '2/4')['selected'])

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
        # Modern unittest formatting mutates traceback links. Simulate this on
        # older local Python too: diagnostics must snapshot locations first.
        path = self.root / self.inventory[0]
        path.write_text(path.read_text() + '''
original_format = unittest.TestResult._exc_info_to_string
def truncate_then_format(self, err, test):
    err[2].tb_next = None
    return original_format(self, err, test)
unittest.TestResult._exc_info_to_string = truncate_then_format
''')
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertEqual([row['status'] for row in rows], ['FAIL', 'FAIL', 'PASS'])
        self.assertEqual(len(list((self.root / 'result/safe').glob('*.log'))), 3)
        safe = ''.join(path.read_text() for path in (self.root / 'result/safe').iterdir())
        self.assertNotIn('PRIVATE_SENTINEL', safe)
        self.assertIn('--case test_a.Fixture.test_fixture', safe)
        self.assertIn('body', safe)
        self.assertIn('cleanup', safe)
        self.assertIn({'file': 'scripts/test-a.py', 'line': 5},
                      rows[0]['cases'][0]['diagnostics'][0]['frames'])
        raw = ''.join(path.read_text() for path in (self.root / 'result/raw').glob('*.log'))
        self.assertIn('PRIVATE_SENTINEL', raw)
        self.assertIn('test-a.py", line 5', raw)

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
        marker = self.root / 'started'
        stopped = self.root / 'stopped'
        later = self.root / 'later'
        boundary = "deadline = started + max(300, row['seconds'] * 3 + 60)"
        self.assertEqual(source.count(boundary), 1)
        # Only the disposable runner gets a short deadline. Start it after the
        # worker report/body exists, so slow imports cannot test missing-report
        # failure instead. Startup remains bounded and ownership stays observed.
        ready = (f"startup_deadline = time.monotonic() + 5\n"
                 f"            while not Path({str(marker)!r}).is_file():\n"
                 "                if child.poll() is not None or time.monotonic() >= startup_deadline:\n"
                 "                    raise RuntimeError('fixture startup failed')\n"
                 "                tree.scan()\n"
                 "                time.sleep(.01)\n"
                 "            deadline = time.monotonic() + 0.05")
        path.write_text(source.replace(boundary, ready))
        # Exercise a cooperative worker exit, not platform-specific teardown of
        # a signal-terminated interpreter. ProcessTree still observes real exit.
        self.fixture('a', 'import signal\n'
                     'def stop(signum, frame):\n'
                     f'    Path({str(stopped)!r}).touch()\n'
                     '    os._exit(0)\n'
                     'signal.signal(signal.SIGTERM, stop)\n'
                     f'Path({str(marker)!r}).write_text(str(os.getpid()))\ntime.sleep(30)')
        self.fixture('b', f'Path({str(later)!r}).touch()')
        result, rows = self.run_fixture('--ci')
        self.assertEqual(result.returncode, 1)
        self.assertEqual([row['status'] for row in rows], ['ERROR', 'NOT RUN'])
        self.assertEqual(rows[0]['reason'], 'deadline')
        self.assertEqual(rows[0]['code'], 124)
        self.assertTrue(stopped.is_file())
        self.assertFalse(later.exists())
        with self.assertRaises(ProcessLookupError):
            os.kill(int(marker.read_text()), 0)

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
