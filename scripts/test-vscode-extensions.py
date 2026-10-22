#!/usr/bin/env python3
"""VS Code reliability using only disposable CLI, target and Core fixtures."""
import importlib.util
import io
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DIAGNOSTIC = load('vscode_diagnostic', ROOT / 'modules/vscode/cli_diagnostic.py')
PREPARE = load('vscode_restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
SECRET = 'PRIVATE_VSCODE_SECRET'
CLI = r'''#!/usr/bin/env python3
import json, os, pathlib, signal, sys, time
root = pathlib.Path(os.environ['TEST_VSCODE_ROOT'])
spec = json.loads((root / 'spec.json').read_text())
state = root / 'installed.json'
installed = json.loads(state.read_text())
attempts = root / 'attempts'
mode = spec.get('mode', 'success')
if sys.argv[1:] == ['--list-extensions']:
    if mode == 'stop_during_inventory': (root / 'stop').touch()
    if mode == 'inventory_error' or (mode == 'inventory_after_failure' and attempts.exists()):
        sys.exit(77)
    if mode == 'malformed_inventory':
        print('not an extension ID'); sys.exit(0)
    print('\n'.join(installed)); sys.exit(0)
if len(sys.argv) != 3 or sys.argv[1] != '--install-extension':
    sys.exit(99)
item = sys.argv[2]
with attempts.open('a') as stream: stream.write(item + '\n')
if mode == 'block' and item == 'publisher.failed':
    (root / 'active').write_text(str(os.getpid()))
    time.sleep(60)
failed = item == 'publisher.failed' or (item == 'publisher.pack' and 'publisher.failed' not in installed)
if failed and mode != 'success' and mode != 'stop':
    if mode == 'flood':
        for descriptor in (1, 2):
            for _ in range(2048): os.write(descriptor, b'PRIVATE_VSCODE_SECRET' * 200)
        sys.exit(43)
    if mode == 'unknown':
        print('Error: EPERM https://marketplace.invalid/?token=PRIVATE_VSCODE_SECRET', file=sys.stderr)
        print('Cookie: PRIVATE_VSCODE_SECRET /Users/private/Code', file=sys.stdout)
        sys.exit(37)
    if mode == 'false_success': sys.exit(0)
    print('Installing extensions...')
    print('Error while installing extensions: read ECONNRESET', file=sys.stderr)
    if mode == 'contradictory': print('Error: ownership is unknown', file=sys.stderr)
    if mode == 'reset_changed':
        installed.append('dependency.changed'); state.write_text(json.dumps(installed))
    if mode == 'stop_after_failure': (root / 'stop').touch()
    if mode == 'signal': sys.exit(130)
    sys.exit(42)
if item not in installed: installed.append(item)
state.write_text(json.dumps(installed))
if mode == 'stop': (root / 'stop').touch()
print('Extension installed; private tool output is never forwarded')
'''


def fixture(root, cli, mode='success', installed=()):
    (root / 'spec.json').write_text(json.dumps({'mode': mode}))
    (root / 'installed.json').write_text(json.dumps(list(installed)))
    cli.write_text(CLI)
    cli.chmod(0o700)


class DiagnosticReaderTests(unittest.TestCase):
    def test_closed_classification_and_bounded_drain(self):
        reset = b'Error while installing extensions: read ECONNRESET\n'
        self.assertEqual(DIAGNOSTIC.classify(io.BytesIO(b'Installing extensions...\n' + reset)), 'network_reset')
        for output in (b'', b'Error: EPERM\n', b'https://invalid/?token=ECONNRESET\n',
                       b'prefix ECONNRESET suffix\n', reset + b'Error: ownership unknown\n',
                       b'Installing extension publisher.pack...\n' + reset,
                       b'x' * (8 * 1024 * 1024) + reset):
            self.assertEqual(DIAGNOSTIC.classify(io.BytesIO(output)), 'unknown')
        self.assertEqual(DIAGNOSTIC.classify(io.BytesIO(b'\n' * 8190 + reset)), 'network_reset')
        # A producer with no newline cannot grow the reader's carry buffer.
        class Flood:
            remaining = 4096
            calls = 0
            def read(self, size):
                self.calls += 1
                self.assert_size = size
                if self.remaining == 0:
                    return b''
                self.remaining -= 1
                return b'x' * size
        flood = Flood()
        self.assertEqual(DIAGNOSTIC.classify(flood), 'unknown')
        self.assertEqual((flood.remaining, flood.calls, flood.assert_size), (0, 4097, 4096))


class ExtensionBootstrapTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        (self.root / 'bin').mkdir()
        fixture(self.root, self.root / 'bin/code')
        self.config = self.root / 'extensions.conf'
        self.config.write_text('publisher.failed\npublisher.independent\n')
        self.environment = dict(os.environ, HOME=str(self.root), TEST_VSCODE_ROOT=str(self.root),
                                TEST_CONFIGURATION=str(self.config), MACSEED_APPLICATION_EXECUTION='true',
                                PATH=str(self.root / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin')

    def mode(self, value):
        (self.root / 'spec.json').write_text(json.dumps({'mode': value}))

    def run_install(self, verbose=False):
        script = '''
source modules/core/common/common.sh
source modules/core/verification/verification.sh
source modules/vscode/extensions.sh
log() { printf '%s\n' "$1" >> "$TEST_VSCODE_ROOT/technical.log"; }
blueprint_exists() { return 1; }
blueprint_generated_file() { printf '%s\n' "$TEST_CONFIGURATION"; }
blueprint_item_selected() { return 0; }
application_stop_checkpoint() {
    [[ -e "$TEST_VSCODE_ROOT/stop" ]] || return 0
    [[ "${1:-0}" -le 1 ]] || exit 2
    exit 132
}
VERBOSE="${TEST_VERBOSE:-false}"
MODULE_CHANGED=false
verification_reset restore
install_vscode_extensions
install_status=$?
printf '%s\n' "$MODULE_CHANGED" > "$TEST_VSCODE_ROOT/changed"
exit "$install_status"
'''
        with tempfile.TemporaryFile() as records:
            environment = dict(self.environment, MACSEED_REPORT_FD=str(records.fileno()),
                               TEST_VERBOSE=str(verbose).lower())
            result = subprocess.run(['bash', '-c', script], cwd=ROOT, env=environment,
                                    pass_fds=(records.fileno(),), capture_output=True, timeout=15)
            records.seek(0)
            rows = [json.loads(line) for line in records]
        return result, [row for row in rows if row['kind'] == 'operation']

    def attempts(self):
        p = self.root / 'attempts'
        return p.read_text().splitlines() if p.exists() else []

    def test_success_and_repeated_noop(self):
        result, records = self.run_install()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([row['outcome'] for row in records], ['success', 'success'])
        self.assertEqual((self.root / 'changed').read_text(), 'true\n')
        result, records = self.run_install()
        self.assertEqual(result.returncode, 0)
        self.assertEqual([row['outcome'] for row in records], ['noop', 'noop'])
        self.assertEqual(len(self.attempts()), 2)
        self.assertEqual((self.root / 'changed').read_text(), 'false\n')

    def test_reset_continues_independent_and_preserves_native_exit(self):
        for verbose in (False, True):
            with self.subTest(verbose=verbose):
                self.mode('reset')
                result, records = self.run_install(verbose)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(records[0]['reason'], 'network_reset')
                self.assertEqual([row['outcome'] for row in records], ['failure', 'success' if not verbose else 'noop'])
                self.assertIn('exit_code=42 reason=network_reset', (self.root / 'technical.log').read_text())
                self.assertNotIn(b'VS Code Extensions are ready', result.stdout)
                self.assertNotIn(b'All VS Code extensions are installed', result.stdout)
        self.assertEqual(self.attempts(), ['publisher.failed', 'publisher.independent', 'publisher.failed'])

    def test_dependency_failure_is_not_pack_success(self):
        self.mode('reset')
        self.config.write_text('publisher.failed\npublisher.pack\npublisher.independent\n')
        result, records = self.run_install()
        self.assertEqual(result.returncode, 2)
        self.assertEqual([(r['item_id'], r['outcome']) for r in records],
                         [('publisher.failed', 'failure'), ('publisher.pack', 'failure'), ('publisher.independent', 'success')])
        self.assertEqual(json.loads((self.root / 'installed.json').read_text()), ['publisher.independent'])

    def test_unknown_and_contradictory_errors_stop_and_do_not_leak(self):
        for mode in ('unknown', 'contradictory', 'signal', 'reset_changed'):
            with self.subTest(mode=mode):
                (self.root / 'attempts').unlink(missing_ok=True)
                (self.root / 'installed.json').write_text('[]')
                self.mode(mode)
                result, records = self.run_install(verbose=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.attempts(), ['publisher.failed'])
                self.assertEqual(records[0]['outcome'], 'failure')
                if mode in ('unknown', 'contradictory'):
                    self.assertEqual(records[0]['reason'], 'unknown')
                for data in (result.stdout, result.stderr, json.dumps(records).encode(),
                             (self.root / 'technical.log').read_bytes()):
                    for private in (SECRET.encode(), b'https://', b'/Users/private', b'Cookie:'):
                        self.assertNotIn(private, data)
        self.assertEqual((self.root / 'changed').read_text(), 'false\n')

    def test_inventory_errors_stop_immediately(self):
        for mode, expected in [('inventory_error', []), ('malformed_inventory', []),
                               ('inventory_after_failure', ['publisher.failed'])]:
            with self.subTest(mode=mode):
                (self.root / 'attempts').unlink(missing_ok=True)
                self.mode(mode)
                result, _ = self.run_install()
                self.assertEqual(result.returncode, 2)
                self.assertEqual(self.attempts(), expected)

    def test_large_stdout_and_stderr_are_drained_without_leaking(self):
        self.mode('flood')
        result, records = self.run_install(verbose=True)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(records[0]['reason'], 'unknown')
        self.assertEqual(self.attempts(), ['publisher.failed'])
        self.assertLess(len(result.stdout) + len(result.stderr), 2048)
        self.assertNotIn(SECRET.encode(), result.stdout + result.stderr)
        self.assertIn('exit_code=43 reason=unknown', (self.root / 'technical.log').read_text())

    def test_invalid_configuration_precedes_all_installs(self):
        self.config.write_text('publisher.failed\nhttps://invalid/private.vsix\n')
        result, _ = self.run_install()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.attempts(), [])

    def test_prior_changes_survive_unknown_failure_and_false_success_stops(self):
        self.mode('unknown')
        self.config.write_text('publisher.independent\npublisher.failed\npublisher.later\n')
        result, _ = self.run_install()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.attempts(), ['publisher.independent', 'publisher.failed'])
        self.assertEqual((self.root / 'changed').read_text(), 'true\n')
        (self.root / 'attempts').unlink()
        self.config.write_text('publisher.failed\npublisher.later\n')
        self.mode('false_success')
        result, _ = self.run_install()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(self.attempts(), ['publisher.failed'])

    def test_stop_after_success_or_failure_prevents_new_launches(self):
        for mode in ('stop', 'stop_after_failure', 'stop_during_inventory'):
            with self.subTest(mode=mode):
                (self.root / 'attempts').unlink(missing_ok=True)
                (self.root / 'stop').unlink(missing_ok=True)
                (self.root / 'installed.json').write_text('[]')
                self.mode(mode)
                result, _ = self.run_install()
                self.assertEqual(result.returncode, 2 if mode == 'stop_after_failure' else 132)
                self.assertEqual(self.attempts(), [] if mode == 'stop_during_inventory' else ['publisher.failed'])


class ExtensionRestoreTests(unittest.TestCase):
    def setUp(self):
        self.fixture = PREPARE.RestorePrepareTests('test_vscode_prerequisites_and_safe_resolution')
        self.addCleanup(self.fixture.doCleanups)
        self.fixture.setUp()
        code = self.fixture.vscode_fixture()
        self.root = self.fixture.root
        fixture(self.root, code, mode='reset', installed=['publisher.already'])
        self.fixture.environment['TEST_VSCODE_ROOT'] = str(self.root)
        blueprint = self.fixture.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('already.extension\npublisher.fixture\n',
            'publisher.already\npublisher.success\npublisher.failed\npublisher.pack\npublisher.independent\n'))
        (self.fixture.stage / 'generated/vscode-extensions.conf').write_text(
            'publisher.already\npublisher.success\npublisher.failed\npublisher.pack\npublisher.independent\n')
        self.fixture.pack()

    def test_partial_execution_verification_privacy_and_fresh_preview(self):
        plan = self.fixture.plan_result()['prepared_plan_id']
        result, events = self.fixture.execute(plan)
        self.assertEqual(result.returncode, 2, result.stderr)
        terminal = events[-1]['data']
        self.assertEqual(terminal['code'], 'bootstrap_failed')
        self.assertTrue(terminal['independent_work_completed'])
        self.assertFalse(terminal['unknown_consequences'])
        verification = terminal['verification']
        self.assertEqual((verification['status'], verification['verified_count'], verification['mismatch_count']),
                         ('complete', 4, 2))  # Includes the independent Workspace folder.
        operations = [r for r in verification['details']['operation_records'] if r['domain'] == 'vscode-extensions']
        self.assertEqual([r['outcome'] for r in operations], ['noop', 'success', 'failure', 'failure', 'success'])
        self.assertTrue(all(set(r) == {'record_id', 'domain', 'item_id', 'action', 'outcome', 'reason'} for r in operations))
        self.assertEqual([r['reason'] for r in operations if r['outcome'] == 'failure'], ['network_reset', 'network_reset'])
        fresh = self.fixture.plan_result()
        by_id = {r['item_id']: r for r in fresh['plan'] if r['domain'] == 'vscode-extensions'}
        self.assertEqual({k for k, r in by_id.items() if r['disposition'] == 'planned'}, {'publisher.failed', 'publisher.pack'})
        self.assertEqual({k for k, r in by_id.items() if r['disposition'] == 'satisfied'},
                         {'publisher.already', 'publisher.success', 'publisher.independent'})
        (self.root / 'spec.json').write_text('{"mode":"success"}')
        recovered, recovered_events = self.fixture.execute(fresh['prepared_plan_id'])
        self.assertEqual(recovered.returncode, 0, recovered_events)
        self.assertEqual(recovered_events[-2]['data']['verification']['mismatch_count'], 0)

    def test_unknown_raw_output_never_enters_protocol_or_core_log(self):
        (self.root / 'spec.json').write_text('{"mode":"unknown"}')
        result, events = self.fixture.execute(self.fixture.plan_result()['prepared_plan_id'])
        self.assertEqual(result.returncode, 2)
        failures = events[-1]['data']['operation_failures']
        self.assertEqual(next(r for r in failures if r['domain'] == 'vscode-extensions')['reason'], 'unknown')
        self.assertNotIn('publisher.independent', (self.root / 'attempts').read_text())
        logs = b'\n'.join(p.read_bytes() for p in (self.fixture.project / 'logs/history').glob('bootstrap-*.log'))
        self.assertIn(b'exit_code=37 reason=unknown', logs)
        for data in (result.stdout, result.stderr, logs):
            for private in (SECRET.encode(), b'https://marketplace.invalid', b'/Users/private', b'Cookie:'):
                self.assertNotIn(private, data)
        self.assertEqual(events[-1]['data']['verification']['status'], 'complete')

    def test_cancellation_stops_active_cli_and_never_starts_later_items(self):
        (self.root / 'spec.json').write_text('{"mode":"block"}')
        plan = self.fixture.plan_result()['prepared_plan_id']
        request = {'protocol_version': 1, 'operation_id': 'cancel-vscode', 'operation': 'restore_execute',
                   'parameters': {'path': str(self.fixture.archive), 'disabled_groups': [],
                                  'include_secure': False, 'expected_prepared_plan_id': plan}}
        process = subprocess.Popen(['bash', str(self.fixture.project / 'modules/core/application-interface/core.sh')],
            cwd=self.fixture.project, env=self.fixture.environment, stdin=subprocess.PIPE,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            process.stdin.write(json.dumps(request).encode()); process.stdin.close(); process.stdin = None
            deadline = time.monotonic() + 15
            while not (self.root / 'active').exists():
                self.assertIsNone(process.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(0.05)
            process.send_signal(signal.SIGTERM)
            output, errors = process.communicate(timeout=15)
            self.assertEqual(process.returncode, 130, errors)
            events = [json.loads(line) for line in output.splitlines()]
            self.assertEqual((events[-1]['type'], events[-1]['data']['code']), ('failed', 'cancelled'))
            self.assertEqual((self.root / 'attempts').read_text().splitlines(), ['publisher.success', 'publisher.failed'])
            cli_pid = (self.root / 'active').read_text()
            child = subprocess.run(['/bin/ps', '-p', cli_pid, '-o', 'stat='], capture_output=True)
            self.assertTrue(not child.stdout.strip() or child.stdout.strip().startswith(b'Z'))
        finally:
            if process.poll() is None:
                process.kill(); process.communicate()


if __name__ == '__main__':
    unittest.main()
