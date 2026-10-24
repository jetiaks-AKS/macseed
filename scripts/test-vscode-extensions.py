#!/usr/bin/env python3
"""VS Code reliability using only disposable CLI, target and Core fixtures."""
import importlib.util
import hashlib
import io
import json
import os
from pathlib import Path
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DIAGNOSTIC = load('vscode_diagnostic', ROOT / 'modules/vscode/cli_diagnostic.py')
EXECUTION = load('vscode_cli_execution', ROOT / 'modules/vscode/cli_execution.py')
PREPARE = load('vscode_restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
SECRET = 'PRIVATE_VSCODE_SECRET'
# Scope bytecode isolation to the mock interpreter, never its production parent.
CLI = r'''#!/usr/bin/env -S PYTHONDONTWRITEBYTECODE=1 python3
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(os.environ['TEST_VSCODE_ROOT'])
spec = json.loads((root / 'spec.json').read_text())
state = root / 'installed.json'
installed = json.loads(state.read_text())
attempts = root / 'attempts'
mode = spec.get('mode', 'success')
if spec.get('trace_context'):
    directory = os.environ.get('MACSEED_ITEM_STATE_DIR')
    durable = pathlib.Path.home() / 'Library/Application Support/Macseed/VSCode/active.json'
    marker = pathlib.Path(directory) / 'external-tool-active.json' if directory else None
    def value(path):
        return json.loads(path.read_text()) if path is not None and path.is_file() else None
    row = dict(arguments=sys.argv[1:], installed=installed,
        bytecode_disabled=(os.environ.get('PYTHONDONTWRITEBYTECODE') == '1' and sys.dont_write_bytecode),
        supervised=os.environ.get('MACSEED_VSCODE_SUPERVISED_RESTORE') == 'true',
        secure_verify_only=os.environ.get('MACSEED_APPLICATION_SECURE_VERIFY_ONLY') == 'true',
        operation_state=directory, state_exists=bool(directory and pathlib.Path(directory).is_dir()),
        final_verify=bool(directory and (pathlib.Path(directory) / 'execution-complete').is_file()),
        durable=value(durable), marker=value(marker))
    with (root / 'contexts.jsonl').open('a') as stream:
        stream.write(json.dumps(row) + '\n')
if mode == 'supervised_inventory_hang':
    mode = 'inventory_hang' if os.environ.get('MACSEED_VSCODE_SUPERVISED_RESTORE') == 'true' else 'success'
if sys.argv[1:] == ['--list-extensions']:
    with (root / 'inventory-reads').open('a') as stream: stream.write('read\n')
    if mode == 'inventory_hang':
        (root / 'active').write_text(str(os.getpid()))
        print('PRIVATE_VSCODE_SECRET https://private.invalid/?token=PRIVATE_VSCODE_SECRET', flush=True)
        time.sleep(60)
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
if mode == 'orphan_worker':
    child = subprocess.Popen([sys.executable, '-c',
        'import pathlib,signal,sys,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); '
        'pathlib.Path(sys.argv[1]).touch(); time.sleep(60)', str(root / 'worker-ready')],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        preexec_fn=os.setpgrp)
    (root / 'active').write_text(str(os.getpid()))
    (root / 'child').write_text(str(child.pid))
    deadline = time.monotonic() + 5
    while not all((root / name).exists() for name in ('worker-ready', 'observer-ready')):
        if time.monotonic() >= deadline: sys.exit(98)
        time.sleep(.01)
    sys.exit(0) # The owned worker deliberately outlives this successful root.
if mode == 'progress':
    for index in range(10):
        (root / 'download').write_bytes(b'x' * (index + 1))
        time.sleep(.08)
if mode == 'install_hang' and item == 'publisher.failed':
    (root / 'active').write_text(str(os.getpid()))
    child = subprocess.Popen([sys.executable, '-c',
        'import signal,time; signal.signal(signal.SIGTERM, signal.SIG_IGN); time.sleep(60)'],
        preexec_fn=os.setpgrp)
    (root / 'child').write_text(str(child.pid))
    print('PRIVATE_VSCODE_SECRET https://private.invalid /Users/private/Code', flush=True)
    print('Cookie: PRIVATE_VSCODE_SECRET', file=sys.stderr, flush=True)
    time.sleep(60)
if mode == 'block' and item == 'publisher.failed':
    (root / 'active').write_text(str(os.getpid()))
    time.sleep(60)
failed = item == 'publisher.failed' or (item == 'publisher.pack' and 'publisher.failed' not in installed)
if failed and mode not in ('success', 'stop', 'progress'):
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
        (self.root / 'items').mkdir(mode=0o700)
        self.environment = dict(os.environ, HOME=str(self.root), TEST_VSCODE_ROOT=str(self.root),
                                TEST_CONFIGURATION=str(self.config), MACSEED_APPLICATION_EXECUTION='true',
                                BUNDLE_RESTORE_ACTIVE='true',
                                MACSEED_ITEM_STATE_DIR=str(self.root / 'items'),
                                PATH=str(self.root / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin')

    def mode(self, value):
        (self.root / 'spec.json').write_text(json.dumps({'mode': value}))

    def run_install(self, verbose=False, reader_failure=False):
        script = '''
source modules/core/common/common.sh
source modules/core/verification/verification.sh
source modules/vscode/extensions.sh
MODE=--bootstrap
if [[ "${TEST_READER_FAILURE:-false}" == true ]]; then
    python3() {
        if [[ "$*" == '-B modules/vscode/cli_diagnostic.py' ]]; then
            cat >/dev/null
            return 19
        fi
        command python3 "$@"
    }
fi
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
printf '%s %s %s %s\n' "${VSCODE_INSTALL_EXIT_CODE:-unset}" \
    "${VSCODE_INSTALL_DIAGNOSTIC_VALID:-false}" "${VSCODE_INSTALL_SUPERVISED:-false}" \
    "${VSCODE_INSTALL_QUIESCENT:-false}" > "$TEST_VSCODE_ROOT/diagnostic-status"
exit "$install_status"
'''
        with tempfile.TemporaryFile() as records:
            environment = dict(self.environment, MACSEED_REPORT_FD=str(records.fileno()),
                               TEST_VERBOSE=str(verbose).lower(),
                               TEST_READER_FAILURE=str(reader_failure).lower())
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
        # Initial read, post-Apply read, fresh absent-item admission, post-Apply.
        self.assertEqual(len((self.root / 'inventory-reads').read_text().splitlines()), 4)
        (self.root / 'inventory-reads').write_text('')
        result, records = self.run_install()
        self.assertEqual(result.returncode, 0)
        self.assertEqual([row['outcome'] for row in records], ['noop', 'noop'])
        self.assertEqual(len(self.attempts()), 2)
        self.assertEqual((self.root / 'changed').read_text(), 'false\n')
        self.assertEqual((self.root / 'inventory-reads').read_text(), 'read\n')

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
        for mode in ('unknown', 'contradictory', 'reset_changed', 'signal'):
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
            self.assertEqual(process.returncode, 2, errors)
            events = [json.loads(line) for line in output.splitlines()]
            self.assertEqual((events[-1]['type'], events[-1]['data']['code']), ('failed', 'privileged_lifecycle_unknown'))
            self.assertTrue(events[-1]['data']['unknown_consequences'])
            self.assertTrue((self.fixture.home / 'Library/Application Support/Macseed/VSCode/active.json').exists())
            self.assertEqual((self.root / 'attempts').read_text().splitlines(), ['publisher.success', 'publisher.failed'])
            cli_pid = (self.root / 'active').read_text()
            child = subprocess.run(['/bin/ps', '-p', cli_pid, '-o', 'stat='], capture_output=True)
            self.assertTrue(not child.stdout.strip() or child.stdout.strip().startswith(b'Z'))
        finally:
            if process.poll() is None:
                process.kill(); process.communicate()


class CLIWatchdogTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.cli = self.root / 'code'
        fixture(self.root, self.cli)
        (self.root / 'items').mkdir(mode=0o700)
        self.environment = {key: value for key, value in os.environ.items()
                            if not key.startswith(('MACSEED_', 'VSCODE_'))}
        self.environment.update(HOME=str(self.root), TEST_VSCODE_ROOT=str(self.root),
                                MACSEED_APPLICATION_EXECUTION='true',
                                BUNDLE_RESTORE_ACTIVE='true', MACSEED_VSCODE_SUPERVISED_RESTORE='true',
                                MACSEED_ITEM_STATE_DIR=str(self.root / 'items'))
        self.environment_patch = patch.dict(os.environ, self.environment, clear=True)
        self.environment_patch.start()
        self.addCleanup(self.environment_patch.stop)

    def mode(self, value):
        (self.root / 'spec.json').write_text(json.dumps({'mode': value}))

    def run_cli(self, operation, **kwargs):
        arguments = ['--list-extensions'] if operation == 'inventory' else ['--install-extension', 'publisher.failed']
        return EXECUTION.CLIExecutor(inventory_seconds=1, install_seconds=1, poll=.05, **kwargs).run(
            [str(self.cli), *arguments], operation)

    def assert_blocked(self, reason):
        durable = self.root / 'Library/Application Support/Macseed/VSCode/active.json'
        self.assertEqual(json.loads(durable.read_text())['cause'], reason)
        marker = self.root / 'items/external-tool-active.json'
        self.assertEqual(json.loads(marker.read_text())['cause'], reason)
        with patch.object(EXECUTION.subprocess, 'Popen') as launch:
            result = EXECUTION.CLIExecutor().run([str(self.cli), '--install-extension', 'publisher.later'], 'install')
            self.assertEqual(result[:2], (2, 'vscode_lifecycle_pending'))
            launch.assert_not_called()
        script = 'source modules/core/common/common.sh; later() { echo UNSAFE; }; run_module later later'
        following = subprocess.run(['bash', '-c', script], cwd=ROOT, capture_output=True, timeout=5)
        self.assertEqual(following.returncode, 2)
        self.assertNotIn(b'UNSAFE', following.stdout)

    def assert_pid_stopped(self, name):
        pid = (self.root / name).read_text()
        result = subprocess.run(['/bin/ps', '-p', pid, '-o', 'stat='], capture_output=True, timeout=2)
        self.assertTrue(not result.stdout.strip() or result.stdout.strip().startswith(b'Z'), (name, result.stdout))

    def test_long_progress_and_quiescent_success(self):
        self.mode('progress')
        executor = EXECUTION.CLIExecutor(inventory_seconds=3, install_seconds=3, poll=.05)
        started = time.monotonic()
        status, _, safe, _ = executor.run([str(self.cli), '--install-extension', 'publisher.failed'], 'install')
        self.assertEqual((status, safe), (0, True))
        self.assertGreater(time.monotonic() - started, .7)
        self.assertEqual((self.root / 'download').stat().st_size, 10)
        self.assertFalse((self.root / 'items/external-tool-active.json').exists())
        self.assertFalse(EXECUTION.pending())

    def test_inventory_deadline_blocks_native_install(self):
        self.mode('inventory_hang')
        result = self.run_cli('inventory')
        self.assertEqual(result, (124, 'vscode_inventory_deadline', False, b''))
        self.assert_pid_stopped('active')
        self.assertFalse((self.root / 'attempts').exists())
        self.assert_blocked('vscode_inventory_deadline')

    def test_install_deadline_stops_owned_tree_and_never_leaks(self):
        self.mode('install_hang')
        result = self.run_cli('install')
        self.assertEqual(result, (124, 'vscode_install_deadline', False, b''))
        self.assert_pid_stopped('active')
        self.assert_pid_stopped('child')
        self.assert_blocked('vscode_install_deadline')
        for path in self.root.rglob('*'):
            if path.is_file() and path.name not in ('code',):
                self.assertNotIn(SECRET.encode(), path.read_bytes())

    def test_unconfirmed_stop_blocks_all_later_mutations(self):
        self.mode('install_hang')
        tree_type = EXECUTION.ProcessTree
        def unconfirmed(pid):
            tree = tree_type(pid)
            self.addCleanup(tree.stop)  # Real cleanup remains bounded and fixture-owned.
            tree.stop = lambda: False
            return tree
        with patch.object(EXECUTION, 'ProcessTree', side_effect=unconfirmed):
            result = self.run_cli('install')
        self.assertEqual(result[:3], (129, 'vscode_quiescence_unconfirmed', False))
        self.assert_blocked('vscode_quiescence_unconfirmed')

    def test_exit_zero_does_not_override_unconfirmed_quiescence(self):
        tree_type = EXECUTION.ProcessTree
        def unconfirmed(pid):
            tree = tree_type(pid)
            stop = tree.stop
            def decline():
                stop()
                return False
            tree.stop = decline
            return tree
        with patch.object(EXECUTION, 'ProcessTree', side_effect=unconfirmed):
            result = self.run_cli('install')
        self.assertEqual(json.loads((self.root / 'installed.json').read_text()), ['publisher.failed'])
        self.assertEqual(result[:3], (129, 'vscode_quiescence_unconfirmed', False))
        self.assert_blocked('vscode_quiescence_unconfirmed')

    def test_orphan_worker_after_root_exit_zero(self):
        parent = self.root
        native_popen, tree_type = subprocess.Popen, EXECUTION.ProcessTree
        for confirmed in (True, False):
            with self.subTest(quiescence_confirmed=confirmed):
                self.root = parent / ('confirmed' if confirmed else 'unconfirmed')
                self.root.mkdir(mode=0o700)
                self.cli = self.root / 'code'
                fixture(self.root, self.cli, mode='orphan_worker')
                (self.root / 'items').mkdir(mode=0o700)
                durable = self.root / 'Library/Application Support/Macseed/VSCode/active.json'
                marker = self.root / 'items/external-tool-active.json'
                observed = {'stops': [], 'orphan_seen': False}

                def launch(*args, **kwargs):
                    process = native_popen(*args, **kwargs)
                    if args[0][0] == str(self.cli):
                        observed['root'] = process
                    return process

                def owned_tree(pid):
                    delegate = tree_type(pid)
                    observed['tree'] = delegate
                    self.addCleanup(delegate.stop)
                    # Keep root alive until its private session is observed.
                    (self.root / 'observer-ready').touch()
                    def scan():
                        rows = delegate.scan()
                        if observed['root'].poll() == 0 and (self.root / 'child').exists():
                            worker = int((self.root / 'child').read_text())
                            if worker in rows:
                                observed['orphan_seen'] = True
                        return rows
                    def stop():
                        self.assertEqual(observed['root'].poll(), 0)
                        if not observed['stops']:
                            worker = int((self.root / 'child').read_text())
                            self.assertIn(worker, delegate.scan())
                            self.assertTrue(observed['orphan_seen'])
                            self.assertEqual(json.loads(durable.read_text())['state'], 'active')
                            self.assertEqual(json.loads(marker.read_text())['state'], 'active')
                        stopped = delegate.stop() if confirmed else False
                        observed['stops'].append(stopped)
                        return stopped
                    tree = Mock(wraps=delegate)
                    tree.scan.side_effect = scan
                    tree.stop.side_effect = stop
                    observed['mock'] = tree
                    return tree

                environment = dict(os.environ, HOME=str(self.root), TEST_VSCODE_ROOT=str(self.root),
                                   MACSEED_ITEM_STATE_DIR=str(self.root / 'items'))
                with patch.dict(os.environ, environment, clear=True):
                    try:
                        with patch.object(EXECUTION.subprocess, 'Popen', side_effect=launch), \
                             patch.object(EXECUTION, 'ProcessTree', side_effect=owned_tree):
                            result = self.run_cli('install')
                        reason = 'vscode_process_interrupted' if confirmed else 'vscode_quiescence_unconfirmed'
                        self.assertEqual(observed['root'].returncode, 0)
                        self.assertEqual(result, (129, reason, False, b''))
                        self.assertTrue(observed['orphan_seen'])
                        self.assertTrue(observed['mock'].stop.called)
                        self.assertEqual(observed['stops'], [confirmed, confirmed])
                        if confirmed:
                            self.assertEqual(observed['tree'].scan(), {})
                            self.assert_pid_stopped('child')
                        else:
                            worker = int((self.root / 'child').read_text())
                            self.assertIn(worker, observed['tree'].scan())
                        self.assert_blocked(reason)
                        self.assertEqual(json.loads(durable.read_text())['state'], 'unknown_consequences')
                        self.assertEqual(json.loads(marker.read_text())['state'], 'unknown_consequences')
                        before = durable.read_bytes(), marker.read_bytes()

                        # A fresh Execute with no VS Code selection must reject
                        # the persisted uncertainty before any publication.
                        restore = PREPARE.RestorePrepareTests('test_structured_folder_actions_and_selected_scope')
                        self.addCleanup(restore.doCleanups)
                        restore.setUp()
                        restore.environment['HOME'] = str(self.root)
                        restore.pack()
                        plan = restore.plan_result(groups=('Applications',))
                        retry, events = restore.execute(plan['prepared_plan_id'], groups=('Applications',))
                        self.assertEqual(retry.returncode, 2, events)
                        terminal = events[-1]['data']
                        self.assertEqual(terminal['code'], 'privileged_lifecycle_unknown')
                        self.assertTrue(terminal['unknown_consequences'])
                        self.assertFalse(terminal['publication_occurred'])
                        self.assertFalse(terminal['target_mutation_may_have_started'])
                        self.assertEqual((durable.read_bytes(), marker.read_bytes()), before)
                        self.assertEqual((self.root / 'attempts').read_text().splitlines(), ['publisher.failed'])
                        self.assertFalse((self.root / 'Projects').exists())
                    finally:
                        if 'tree' in observed:
                            observed['tree'].stop() # Fixture cleanup cannot reconcile the journal.
                    self.assertEqual((durable.read_bytes(), marker.read_bytes()), before)

    def test_observer_failure_retains_uncertainty(self):
        self.mode('install_hang')
        tree_type = EXECUTION.ProcessTree
        def failing(pid):
            tree = tree_type(pid)
            scan = tree.scan
            def cleanup():
                tree.scan = scan
                tree.stop()
            self.addCleanup(cleanup)
            tree.scan = lambda: (_ for _ in ()).throw(RuntimeError('private observer detail'))
            return tree
        with patch.object(EXECUTION, 'ProcessTree', side_effect=failing):
            result = self.run_cli('install')
        self.assertEqual(result[:3], (2, 'vscode_process_observation_failed', False))
        self.assert_blocked('vscode_process_observation_failed')

    def test_durability_failure_and_ipc_decline_launch(self):
        with patch.object(EXECUTION.os, 'fsync', side_effect=OSError('private failure')), \
             patch.object(EXECUTION.subprocess, 'Popen') as launch:
            # Isolate native-launch admission from subprocess-based ps itself.
            with patch.object(EXECUTION, 'process_table', return_value={}):
                result = self.run_cli('install')
            self.assertEqual(result[:2], (2, 'vscode_lifecycle_state_failed'))
            launch.assert_not_called()
        with patch.dict(os.environ, VSCODE_IPC_HOOK_CLI='/private/secret'), \
             patch.object(EXECUTION.subprocess, 'Popen') as launch:
            self.assertEqual(self.run_cli('install')[:2], (2, 'vscode_cli_delegation_unsupported'))
            launch.assert_not_called()

    def test_supervisor_crash_keeps_write_ahead_state(self):
        self.mode('inventory_hang')
        supervisor = subprocess.Popen([sys.executable, str(ROOT / 'modules/vscode/cli_execution.py'),
                                       str(self.cli), '--list-extensions'], cwd=ROOT,
                                      stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        try:
            deadline = time.monotonic() + 5
            while not (self.root / 'active').exists():
                self.assertIsNone(supervisor.poll())
                self.assertLess(time.monotonic(), deadline)
                time.sleep(.02)
            tree = EXECUTION.ProcessTree(int((self.root / 'active').read_text()))
            self.addCleanup(tree.stop)
            supervisor.kill()
            supervisor.communicate(timeout=3)
            self.assertTrue(EXECUTION.pending())
            durable = self.root / 'Library/Application Support/Macseed/VSCode/active.json'
            self.assertEqual(json.loads(durable.read_text())['state'], 'active')
            self.assertTrue((self.root / 'items/external-tool-active.json').exists())
            with patch.object(EXECUTION.subprocess, 'Popen') as launch:
                self.assertEqual(self.run_cli('install')[:2], (2, 'vscode_lifecycle_pending'))
                launch.assert_not_called()
        finally:
            if supervisor.poll() is None:
                supervisor.kill()
            supervisor.communicate(timeout=3)


class CLIWatchdogRestoreTests(unittest.TestCase):
    def setUp(self):
        ExtensionRestoreTests.setUp(self)

    def test_unknown_result_and_reentry_without_extensions(self):
        self.fixture.environment.pop('VSCODE_IPC_HOOK_CLI', None)
        # Short budgets are confined to the disposable project, never an env override.
        runner = self.fixture.project / 'modules/vscode/cli_execution.py'
        runner.write_text(runner.read_text().replace('executor = CLIExecutor()',
                          'executor = CLIExecutor(inventory_seconds=2, install_seconds=1, poll=.05)'))
        (self.root / 'spec.json').write_text('{"mode":"install_hang"}')
        result, events = self.fixture.execute(self.fixture.plan_result()['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        terminal = events[-1]['data']
        self.assertEqual(terminal['code'], 'privileged_lifecycle_unknown')
        self.assertTrue(terminal['unknown_consequences'])
        self.assertEqual(terminal['external_lifecycle_cause'], 'vscode_install_deadline')
        self.assertEqual((self.root / 'attempts').read_text().splitlines(), ['publisher.success', 'publisher.failed'])
        self.assertFalse(terminal['independent_work_completed'])
        self.assertNotIn(SECRET.encode(), result.stdout + result.stderr)
        # With Applications disabled the domain report can be empty; live Execute
        # must still run the global safety gate before publication/mutation.
        journal = self.fixture.home / 'Library/Application Support/Macseed/VSCode/active.json'
        before = journal.read_bytes()
        blocked = self.fixture.plan_result(groups=('Applications',))
        retried, retry_events = self.fixture.execute(blocked['prepared_plan_id'], groups=('Applications',))
        self.assertEqual(retried.returncode, 2, retry_events)
        self.assertEqual(retry_events[-1]['data']['code'], 'privileged_lifecycle_unknown')
        self.assertFalse(retry_events[-1]['data']['publication_occurred'])
        self.assertFalse(retry_events[-1]['data']['target_mutation_may_have_started'])
        self.assertEqual(journal.read_bytes(), before)
        self.assertEqual((self.root / 'attempts').read_text().splitlines(), ['publisher.success', 'publisher.failed'])
        logs = b'\n'.join(p.read_bytes() for p in (self.fixture.project / 'logs/history').glob('bootstrap-*.log'))
        for data in (result.stdout, result.stderr, logs):
            for private in (SECRET.encode(), b'https://private.invalid', b'/Users/private', b'Cookie:'):
                self.assertNotIn(private, data)


class ExecutionBoundaryTests(unittest.TestCase):
    """Production Core/Bootstrap routing; only external tools are disposable mocks."""
    def setUp(self):
        ExtensionRestoreTests.setUp(self)
        for name in tuple(self.fixture.environment):
            if name.startswith(('MACSEED_', 'VSCODE_', 'BUNDLE_RESTORE_')):
                self.fixture.environment.pop(name)
        self.mode('success')

    def mode(self, mode):
        (self.root / 'spec.json').write_text(json.dumps(dict(mode=mode, trace_context=True)))

    def contexts(self):
        path = self.root / 'contexts.jsonl'
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def snapshot(self):
        # Include every HOME path, lifecycle lock/journal, bytes and metadata.
        result = {}
        for path in (self.fixture.home, *sorted(self.fixture.home.rglob('*'))):
            info = path.lstat()
            content = (os.readlink(path) if path.is_symlink() else
                       path.read_bytes() if path.is_file() else None)
            result[str(path.relative_to(self.fixture.home))] = (
                stat.S_IMODE(info.st_mode), info.st_uid, info.st_mtime_ns, content)
        return result

    def assert_home_unchanged(self, before):
        after = self.snapshot()
        if after == before:
            return
        added = sorted(after.keys() - before.keys())
        removed = sorted(before.keys() - after.keys())
        changed = sorted(path for path in before.keys() & after.keys() if before[path] != after[path])

        def describe(entry):
            if entry is None:
                return None
            mode, uid, mtime, content = entry
            result = dict(mode=mode, uid=uid, mtime_ns=mtime)
            if content is not None:
                raw = content if isinstance(content, bytes) else os.fsencode(content)
                result.update(size=len(raw), sha256=hashlib.sha256(raw).hexdigest())
            return result

        details = {path: dict(before=describe(before.get(path)), after=describe(after.get(path)))
                   for path in added + removed + changed}
        self.fail('HOME snapshot mismatch:\n' + json.dumps(dict(
            added=added, removed=removed, changed=changed, details=details), indent=2, sort_keys=True))

    def seed_quiescent(self):
        directory = self.fixture.home / 'Library/Application Support/Macseed/VSCode'
        directory.mkdir(parents=True, mode=0o700)
        value = dict(contract=1, tool='vscode', owner='a' * 32, operation='inventory',
                     state='quiescent', quiescence_confirmed=True, outcome='success')
        for name, raw in (('active.json', json.dumps(value)), ('lifecycle.lock', 'a' * 32)):
            path = directory / name
            path.write_text(raw)
            path.chmod(0o600)

    def assert_native_observations(self, rows):
        self.assertTrue(rows)
        self.assertTrue(all(row['arguments'] == ['--list-extensions'] and
                            not row['supervised'] for row in rows), rows)
        self.assertTrue(all(row['bytecode_disabled'] for row in rows), rows)

    def test_prepare_and_readiness_preserve_lifecycle(self):
        for existing in (False, True):
            with self.subTest(existing_journal=existing):
                if existing:
                    self.seed_quiescent()
                before, first = self.snapshot(), len(self.contexts())
                plan = self.fixture.plan_result()
                self.assertTrue(plan['readiness']['ready'], plan)
                environment = dict(self.fixture.environment, MACSEED_APPLICATION_EXECUTION='true',
                    BUNDLE_RESTORE_ACTIVE='true', BLUEPRINT_FILE=str(self.fixture.stage / 'blueprint.conf'),
                    BLUEPRINT_GENERATED_DIR=str(self.fixture.stage / 'generated'))
                result = subprocess.run(['bash', './bootstrap.sh', '--application-readiness'],
                    cwd=self.fixture.project, env=environment, capture_output=True, timeout=20)
                self.assertEqual((result.returncode, result.stdout.strip()), (0, b'ready'), result.stderr)
                self.assert_home_unchanged(before)
                self.assert_native_observations(self.contexts()[first:])

    def test_compare_verification_preserves_lifecycle(self):
        self.seed_quiescent()
        before = self.snapshot()
        request = dict(protocol_version=1, operation_id='routing-verify', operation='environment_compare',
                       parameters=dict(bundle_path=str(self.fixture.archive)))
        result = subprocess.run(['bash', './modules/core/application-interface/core.sh'],
            input=json.dumps(request).encode(), cwd=self.fixture.project,
            env=self.fixture.environment, capture_output=True, timeout=20)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual((result.returncode, events[-1]['type']), (0, 'completed'), events)
        self.assert_home_unchanged(before)
        self.assert_native_observations(self.contexts())
        state = next(event['data'] for event in events if event['type'] == 'result')
        self.assertEqual(state['verification']['status'], 'complete')

    def test_secure_failure_verification_preserves_lifecycle(self):
        self.seed_quiescent()
        # Mock the external importer protocol, retaining real Core SecureError,
        # OwnedBootstrap, receipt validation and the entire verification dispatch.
        (self.root / 'bin/age').write_text('#!/bin/bash\n[[ "$*" == --version ]]\n')
        importer = self.fixture.project / 'scripts/ssh-identity-migrate.sh'
        importer.write_text('''#!/usr/bin/env -S PYTHONDONTWRITEBYTECODE=1 python3
import json, os, pathlib, socket, struct, sys
args = sys.argv[1:]
attempt = args[args.index('--attempt') + 1]
endpoint = pathlib.Path(args[args.index('--internal-evidence') + 1])
raw = ('E\\t1\\t' + attempt + '\\tvalidated\\t1\\tskipped\\ttarget_conflict\\n'
       'I\\tid_fixture\\tunverified\\t-\\ttarget_conflict\\tobservation\\nEND\\n').encode()
descriptor = os.open(endpoint, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(descriptor, 'wb') as stream: stream.write(raw)
body = json.dumps(dict(type='finish', code='secure_target_conflict')).encode()
channel = socket.socket(fileno=int(args[args.index('--application-channel-fd') + 1]))
channel.sendall(struct.pack('!I', len(body)) + body)
sys.exit(1)
''')
        importer.chmod(0o700)
        self.fixture.archive = self.root / 'secure routing.mbt'
        self.fixture.pack(secure=True)
        plan = self.fixture.plan_result(secure=True)
        before, first = self.snapshot(), len(self.contexts())
        request = dict(protocol_version=1, operation_id='routing-secure', operation='restore_execute',
            parameters=dict(path=str(self.fixture.archive), disabled_groups=[], include_secure=True,
                            expected_prepared_plan_id=plan['prepared_plan_id']))
        parent, child = socket.socketpair()
        try:
            result = subprocess.run(['bash', './modules/core/application-interface/core.sh',
                '--secure-fd', str(child.fileno())], input=json.dumps(request).encode(),
                pass_fds=(child.fileno(),), cwd=self.fixture.project, env=self.fixture.environment,
                capture_output=True, timeout=25)
        finally:
            parent.close()
            child.close()
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(result.returncode, 2, events)
        terminal = events[-1]['data']
        self.assertEqual(terminal['code'], 'secure_target_conflict', events)
        self.assertEqual(terminal['verification']['status'], 'complete')
        self.assertTrue(any(row['domain'] == 'secure-ssh-identities'
            for row in terminal['verification']['details']['operation_records']))
        self.assert_home_unchanged(before)
        rows = self.contexts()[first:]
        self.assert_native_observations(rows)
        self.assertTrue(any(row['secure_verify_only'] for row in rows), rows)
        self.assertFalse((self.root / 'attempts').exists())

    def test_execute_keeps_context_through_final_verification(self):
        plan = self.fixture.plan_result()
        result, events = self.fixture.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-1]['type'], 'completed')
        terminal = events[-2]['data']
        self.assertEqual(terminal['execution_status'], 'completed')
        self.assertFalse(terminal['unknown_consequences'])
        verification = terminal['verification']
        self.assertEqual((verification['status'], verification['verdict']),
                         ('complete', 'selected_requirements_verified'))
        details = verification['details']
        self.assertEqual(details['status'], 'complete')
        operations = [row for row in details['operation_records'] if row['domain'] == 'vscode-extensions']
        self.assertEqual([row['outcome'] for row in operations], ['noop'] + ['success'] * 4)
        self.assertTrue(any(row['domain'] == 'vscode-extensions' and row['state'] == 'changed'
                            and row['changed'] is True for row in details['module_outcomes']), details)
        rows = [row for row in self.contexts() if row['supervised']]
        self.assertTrue(rows)
        states = {row['operation_state'] for row in rows}
        self.assertEqual(len(states), 1)
        for row in rows:
            self.assertTrue(row['state_exists'], row)
            self.assertEqual(row['durable'], row['marker'])
            self.assertEqual(row['durable']['state'], 'active')
            operation = 'inventory' if row['arguments'] == ['--list-extensions'] else 'install'
            self.assertEqual(row['durable']['operation'], operation)
        final = [row for row in rows if row['final_verify']]
        self.assertEqual(len(final), 1, rows)
        self.assertEqual(final[0]['arguments'], ['--list-extensions'])
        self.assertEqual(set(final[0]['installed']), set((self.fixture.stage /
            'generated/vscode-extensions.conf').read_text().splitlines()))
        self.assertFalse(Path(next(iter(states))).exists())  # Cleanup is after final Verify.
        journal = self.fixture.home / 'Library/Application Support/Macseed/VSCode/active.json'
        self.assertTrue(EXECUTION.completed(json.loads(journal.read_text())))

    def test_missing_or_invalid_state_has_no_native_fallback(self):
        consumer = ExtensionBootstrapTests('test_success_and_repeated_noop')
        consumer.setUp()
        self.addCleanup(consumer.doCleanups)
        invalid = consumer.root / 'unsafe-items'
        invalid.mkdir(mode=0o755)
        linked = consumer.root / 'linked-items'
        linked.symlink_to(consumer.root / 'items', target_is_directory=True)
        for state in (None, str(consumer.root / 'missing'), str(invalid), str(linked)):
            with self.subTest(operation_state=state):
                consumer.environment.pop('MACSEED_ITEM_STATE_DIR', None)
                if state is not None:
                    consumer.environment['MACSEED_ITEM_STATE_DIR'] = state
                (consumer.root / 'spec.json').write_text('{"mode":"success","trace_context":true}')
                result, records = consumer.run_install()
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertEqual(consumer.attempts(), [])
                self.assertFalse((consumer.root / 'Library/Application Support/Macseed/VSCode').exists())
                self.assertFalse((consumer.root / 'contexts.jsonl').exists())
                self.assertFalse(any(row['outcome'] == 'success' for row in records))

    def test_native_and_supervised_diagnostics_keep_statuses(self):
        for supervised, reader_failure in ((False, False), (False, True), (True, False)):
            with self.subTest(supervised=supervised, reader_failure=reader_failure):
                consumer = ExtensionBootstrapTests('test_success_and_repeated_noop')
                consumer.setUp()
                self.addCleanup(consumer.doCleanups)
                if not supervised:
                    consumer.environment.pop('BUNDLE_RESTORE_ACTIVE')
                consumer.config.write_text('publisher.failed\n')
                consumer.mode('reset')
                result, records = consumer.run_install(verbose=True, reader_failure=reader_failure)
                self.assertEqual(result.returncode, 2)
                expected_reason = 'unknown' if reader_failure else 'network_reset'
                self.assertEqual(records[0]['reason'], expected_reason)
                self.assertEqual((consumer.root / 'diagnostic-status').read_text().strip(),
                    f'42 {str(not reader_failure).lower()} {str(supervised).lower()} {str(supervised).lower()}')
                self.assertIn(f'exit_code=42 reason={expected_reason}',
                              (consumer.root / 'technical.log').read_text())
                self.assertEqual(consumer.attempts(), ['publisher.failed'])
                for data in (result.stdout, result.stderr, json.dumps(records).encode(),
                             (consumer.root / 'technical.log').read_bytes()):
                    self.assertNotIn(b'Error while installing extensions:', data)
                    self.assertNotIn(SECRET.encode(), data)

    def test_execute_inventory_deadline_prevents_install(self):
        plan = self.fixture.plan_result()
        runner = self.fixture.project / 'modules/vscode/cli_execution.py'
        runner.write_text(runner.read_text().replace('executor = CLIExecutor()',
            'executor = CLIExecutor(inventory_seconds=1, install_seconds=2, poll=.05)'))
        self.mode('supervised_inventory_hang')
        result, events = self.fixture.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        terminal = events[-1]['data']
        self.assertEqual(terminal['code'], 'privileged_lifecycle_unknown')
        self.assertTrue(terminal['unknown_consequences'])
        self.assertEqual(terminal['external_lifecycle_cause'], 'vscode_inventory_deadline')
        self.assertFalse((self.root / 'attempts').exists())
        journal = self.fixture.home / 'Library/Application Support/Macseed/VSCode/active.json'
        before = journal.read_bytes()
        self.assertEqual(json.loads(before)['state'], 'unknown_consequences')
        blocked = self.fixture.plan_result(groups=('Applications',))
        retry, retry_events = self.fixture.execute(blocked['prepared_plan_id'], groups=('Applications',))
        self.assertEqual(retry.returncode, 2, retry_events)
        self.assertEqual(retry_events[-1]['data']['code'], 'privileged_lifecycle_unknown')
        self.assertFalse(retry_events[-1]['data']['publication_occurred'])
        self.assertEqual(journal.read_bytes(), before)


if __name__ == '__main__':
    if '--routing-only' in sys.argv:
        sys.argv.remove('--routing-only')
        suite = unittest.TestSuite()
        suite.addTests(ExecutionBoundaryTests(name) for name in (
            'test_prepare_and_readiness_preserve_lifecycle',
            'test_compare_verification_preserves_lifecycle',
            'test_secure_failure_verification_preserves_lifecycle',
            'test_execute_keeps_context_through_final_verification',
            'test_missing_or_invalid_state_has_no_native_fallback',
            'test_native_and_supervised_diagnostics_keep_statuses',
            'test_execute_inventory_deadline_prevents_install',
        ))
        for cls, names in (
            (ExtensionBootstrapTests, ['test_reset_continues_independent_and_preserves_native_exit',
                'test_inventory_errors_stop_immediately',
                'test_unknown_and_contradictory_errors_stop_and_do_not_leak']),
            (ExtensionRestoreTests, ['test_cancellation_stops_active_cli_and_never_starts_later_items']),
            (CLIWatchdogRestoreTests, ['test_unknown_result_and_reentry_without_extensions']),
            (CLIWatchdogTests, ['test_orphan_worker_after_root_exit_zero']),
        ):
            suite.addTests(cls(name) for name in names)
        sys.exit(not unittest.TextTestRunner(verbosity=2, failfast=True).run(suite).wasSuccessful())
    if '--r5a-only' in sys.argv:
        sys.argv.remove('--r5a-only')
        suite = unittest.TestSuite()
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(CLIWatchdogTests))
        suite.addTests(unittest.defaultTestLoader.loadTestsFromTestCase(CLIWatchdogRestoreTests))
        for cls, names in (
            (DiagnosticReaderTests, ['test_closed_classification_and_bounded_drain']),
            (ExtensionBootstrapTests, ['test_reset_continues_independent_and_preserves_native_exit',
                'test_stop_after_success_or_failure_prevents_new_launches',
                'test_unknown_and_contradictory_errors_stop_and_do_not_leak']),
            (ExtensionRestoreTests, ['test_cancellation_stops_active_cli_and_never_starts_later_items']),
        ):
            suite.addTests(cls(name) for name in names)
        sys.exit(not unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful())
    unittest.main()
