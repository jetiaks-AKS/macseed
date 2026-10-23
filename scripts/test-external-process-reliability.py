#!/usr/bin/env python3
"""R5 boundaries: disposable HOME, real process ownership and production consumers."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'modules/bootstrap/workspace'))
sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
import clone_execution as clone
import observation
import item_execution
spec = importlib.util.spec_from_file_location('restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class ReliabilityTests(unittest.TestCase):
    maxDiff = None
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='macseed-r5-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.items = self.root / 'items'
        self.items.mkdir(mode=0o700)
        self.destination = self.home / 'target'
        environment = dict(os.environ, HOME=str(self.home), MACSEED_ITEM_STATE_DIR=str(self.items),
                           MACSEED_APPLICATION_EXECUTION='true', BUNDLE_RESTORE_ACTIVE='true',
                           MACSEED_GIT_CLONE_RESTORE='true', GIT_CONFIG_NOSYSTEM='1',
                           GIT_CONFIG_GLOBAL='/dev/null')
        environment.pop('PYTHONDONTWRITEBYTECODE', None)
        for key in ('BUNDLE_RESTORE_PREVIEW', 'MACSEED_APPLICATION_SECURE_VERIFY_ONLY',
                    'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS'):
            environment.pop(key, None)
        self.environment = patch.dict(os.environ, environment, clear=True)
        self.environment.start()
        self.addCleanup(self.environment.stop)

    def snapshot(self):
        return {str(p.relative_to(self.home)): (p.lstat().st_mode, hashlib.sha256(p.read_bytes()).hexdigest()
                if p.is_file() else None) for p in self.home.rglob('*')}

    def script(self, body):
        return [sys.executable, '-B', '-c', body, str(self.destination)]

    def run_clone(self, body, **budgets):
        # Replace only the native tool, preserving admission, journal and ownership.
        with patch.object(clone, 'command', return_value=(self.script(body), dict(os.environ))):
            return clone.CloneExecutor(**budgets).run('https://example.invalid/repo', str(self.destination), 'main')

    def test_real_clone_success_selected_branch_and_no_clobber(self):
        source = self.home / 'source'
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(source)], check=True)
        (source / 'data').write_text('portable\n')
        subprocess.run(['git', '-C', str(source), 'add', 'data'], check=True)
        subprocess.run(['git', '-C', str(source), '-c', 'user.name=Fixture', '-c',
                        'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
        self.assertEqual(clone.CloneExecutor().run(str(source), str(self.destination), 'main'), (0, 'none', True))
        self.assertEqual((self.destination / 'data').read_text(), 'portable\n')
        before = self.snapshot()
        self.assertEqual(clone.CloneExecutor().run(str(source), str(self.destination), 'main')[0], 2)
        self.assertEqual(before, self.snapshot())
        self.assertFalse(clone.pending())
        config = self.home / 'custom-git-config'
        config.write_text('[filter "lfs"]\nprocess = should-never-launch\n')
        with patch.dict(os.environ, GIT_CONFIG_GLOBAL=str(config)):
            before = self.snapshot()
            self.assertEqual(clone.CloneExecutor().run(str(source), str(self.home / 'declined'), 'main')[0], 2)
            self.assertEqual(before, self.snapshot())

    def test_progress_counts_and_long_work_within_budget(self):
        timer = clone.Progress(interval=1)
        timer.feed(b'remote: Receiving objects: 1% (1/100)\r', 0)
        self.assertFalse(timer.stalled(10))
        timer.feed(b'Receiving objects: 1% (1/100)\r', 10)
        timer.feed(b'Receiving objects: 1% (1/100)\r', 10.9)
        self.assertTrue(timer.stalled(11))
        timer.feed(b'Receiving objects: 100% (100/100)\r', 12)
        self.assertFalse(timer.stalled(100))
        transfer = clone.Progress(interval=1)
        transfer.feed(b'Receiving objects: 1% (1/100), 2.00 MiB | 1.00 MiB/s\r', 0)
        transfer.feed(b'Receiving objects: 1% (1/100), 3.00 MiB | 1.00 MiB/s\r', .9)
        self.assertFalse(transfer.stalled(1.2))
        started = time.monotonic()
        self.assertEqual(self.run_clone('import time; time.sleep(.5)', deadline=3)[0], 0)
        self.assertGreater(time.monotonic() - started, .4)

    def test_deadline_partial_clone_and_no_progress_are_distinct(self):
        body = 'import pathlib,sys,time; pathlib.Path(sys.argv[1]).mkdir(); time.sleep(10)'
        status, reason, safe = self.run_clone(body, deadline=.3)
        self.assertEqual((status, reason, safe), (124, 'git_clone_deadline', True))
        self.assertTrue(clone.pending(self.destination))
        self.assertFalse(clone.pending())
        self.assertTrue(self.destination.is_dir())
        self.destination = self.home / 'second'
        body = 'import sys,time; sys.stderr.write("Receiving objects: 1% (1/100)\\r"); sys.stderr.flush(); time.sleep(10)'
        self.assertEqual(self.run_clone(body, deadline=3, no_progress=.2), (124, 'git_clone_no_progress', True))

    def test_cancel_and_root_exit_worker_have_owned_bounded_cleanup(self):
        pidfile = self.root / 'worker'
        body = ('import subprocess,sys,time,pathlib; '
                'p=subprocess.Popen([sys.executable,"-B","-c","import time; time.sleep(20)"]); '
                f'pathlib.Path({str(pidfile)!r}).write_text(str(p.pid))')
        result = self.run_clone(body, deadline=2)
        self.assertEqual(result, (2, 'git_clone_worker_interrupted', True))
        self.assertNotIn(int(pidfile.read_text()), item_execution.process_table())
        executor = clone.CloneExecutor(deadline=3)
        original = clone.ProcessTree.scan
        def cancel_on_scan(tree):
            executor.cancel()
            return original(tree)
        with patch.object(clone, 'command', return_value=(self.script('import time; time.sleep(20)'), dict(os.environ))), \
             patch.object(clone.ProcessTree, 'scan', cancel_on_scan):
            self.assertEqual(executor.run('remote', str(self.destination), 'main'), (130, 'cancelled', True))

    def test_unconfirmed_quiescence_and_state_failure_deny_reentry(self):
        original = clone.ProcessTree.stop
        def unconfirmed(tree):
            original(tree)
            return False
        with patch.object(clone.ProcessTree, 'stop', unconfirmed):
            self.assertEqual(self.run_clone('pass')[2], False)
        self.assertTrue(clone.pending())
        with patch.object(clone.subprocess, 'Popen') as launch:
            self.assertEqual(clone.CloneExecutor().run('remote', str(self.destination), 'main')[0], 2)
            launch.assert_not_called()
        self.assertTrue((self.items / 'external-tool-active.json').exists())

    def test_write_ahead_failure_and_crash_keep_launch_or_reentry_blocked(self):
        with patch.object(clone, 'journal', side_effect=OSError('fsync denied')), \
             patch.object(clone, 'command', return_value=(self.script('pass'), dict(os.environ))):
            # process_table uses Popen too; inspect native command specifically.
            native = clone.subprocess.Popen
            launched = []
            def launch(args, **kwargs):
                launched.append(args)
                return native(args, **kwargs)
            with patch.object(clone.subprocess, 'Popen', side_effect=launch):
                self.assertNotEqual(clone.CloneExecutor().run('remote', str(self.destination), 'main')[0], 0)
            self.assertNotIn(self.script('pass'), launched)
        # Write-ahead state survives an abrupt supervisor exit before completion.
        code = ('import sys,os; sys.path.insert(0,sys.argv[1]); import clone_execution as c; '
                'c.Lifecycle(sys.argv[2]).__enter__(); os._exit(17)')
        child = subprocess.run([sys.executable, '-B', '-c', code,
                                str(ROOT / 'modules/bootstrap/workspace'), str(self.destination)], timeout=5)
        self.assertEqual(child.returncode, 17)
        self.assertTrue(clone.pending())

    def test_observation_deadline_pipe_worker_and_no_home_writes(self):
        before = self.snapshot()
        final = self.root / 'terminal-inventory'
        samples = []
        observation.read(self.script(f'import pathlib; pathlib.Path({str(final)!r}).touch()'),
                         timeout=2, progress=lambda: samples.append(final.exists()))
        self.assertTrue(samples[-1])
        for body in ('import time; time.sleep(10)',
                     'import subprocess,sys; subprocess.Popen([sys.executable,"-B","-c","import time; time.sleep(10)"])'):
            with self.assertRaises(observation.ObservationError) as raised:
                observation.read(self.script(body), timeout=.3)
            self.assertIn(raised.exception.reason, ('external_observation_deadline', 'external_observation_worker'))
            self.assertTrue(raised.exception.quiescent)
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.items / 'external-tool-active.json').exists())

        # Capture batches existing macOS serializers inside the same observer.
        # A hung native read must stop with its owned child, not publish Missing.
        native = self.root / 'defaults'
        pidfile = self.root / 'defaults-pid'
        native.write_text('#!/bin/bash\necho $$ > "$TEST_DEFAULTS_PID"\nexec sleep 10\n')
        native.chmod(0o700)
        candidate = self.root / 'candidate.conf'
        candidate.touch()
        environment = dict(os.environ, PATH=str(self.root) + ':' + os.environ['PATH'],
                           MACSEED_APPLICATION_CAPTURE='true', BLUEPRINT_GENERATED_DIR=str(self.root / 'generated'),
                           TEST_DEFAULTS_PID=str(pidfile))
        with self.assertRaises(observation.ObservationError) as raised:
            observation.read(['bash', str(ROOT / 'modules/discovery/macos/macos.sh'),
                              '--capture-serialize', 'finder', str(candidate)],
                             timeout=2, cwd=ROOT, env=environment)
        self.assertEqual(raised.exception.reason, 'external_observation_deadline')
        self.assertTrue(raised.exception.quiescent)
        self.assertNotIn(int(pidfile.read_text()), item_execution.process_table())
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.items / 'external-tool-active.json').exists())

    def test_observation_failure_is_not_empty_success_or_permission_to_mutate(self):
        original = observation.ProcessTree.stop
        def unconfirmed(tree):
            original(tree)
            return False
        with patch.object(observation.ProcessTree, 'stop', unconfirmed), self.assertRaises(observation.ObservationError):
            # Force the cleanup path: a successful EOF/empty-tree observation
            # no longer needs stop(). Partial output must still be rejected.
            observation.read(self.script('import time; print("publisher.extension", flush=True); time.sleep(10)'), timeout=.3)
        self.assertTrue((self.items / 'external-tool-active.json').exists())
        result = subprocess.run(['bash', '-c', 'source modules/core/common/common.sh; '
            'later() { echo UNSAFE; }; run_module later later'], cwd=ROOT, capture_output=True, timeout=5)
        self.assertEqual(result.returncode, 2)
        self.assertNotIn(b'UNSAFE', result.stdout)
        self.assertFalse(list(self.home.rglob('*.pyc')))

    def test_watchdog_kernel_wait_is_bounded(self):
        started = time.monotonic()
        with self.assertRaises(subprocess.TimeoutExpired):
            item_execution.kernel_read(self.script('import time; time.sleep(10)'), timeout=.15)
        self.assertLess(time.monotonic() - started, 2)

    def restore(self):
        f = fixture.RestorePrepareTests()
        f.setUp()
        self.addCleanup(f.doCleanups)
        # The fixture inherits our environment; only the real OwnedBootstrap may
        # supply its operation directory, not the direct supervisor test above.
        for key in ('MACSEED_ITEM_STATE_DIR', 'MACSEED_GIT_CLONE_RESTORE',
                    'MACSEED_APPLICATION_EXECUTION', 'BUNDLE_RESTORE_ACTIVE'):
            f.environment.pop(key, None)
        return f

    def test_production_execute_failure_continues_independent_and_verifies(self):
        f = self.restore()
        target = f.repository_fixture()
        config = f.stage / 'generated/workspace/repositories.conf'
        config.write_text(config.read_text() + config.read_text().replace('[repo]', '[later]').replace('/Projects/repo', '/Projects/later'))
        blueprint = f.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[git-repositories]\nrepo\n', '[git-repositories]\nrepo\nlater\n'))
        git = f.root / 'bin/git'
        git.write_text(git.read_text().replace('[[ "${TEST_CLONE_FAIL:-false}" != true ]]', '[[ "$target" != */repo ]]'))
        f.pack()
        plan = f.plan_result()
        result, events = f.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        data = events[-1]['data']
        self.assertFalse(data.get('unknown_consequences', False), data)
        self.assertEqual(data['verification']['status'], 'complete', data)
        records = data['verification']['details']['operation_records']
        self.assertTrue(any(r['action'] == 'clone' and r['outcome'] == 'failure' for r in records), records)
        self.assertTrue(any(r['action'] == 'clone' and r['outcome'] == 'success' for r in records), records)
        self.assertEqual((f.root / 'repo-log').read_text(), 'clone\nclone\n')
        self.assertTrue(target.is_dir())
        self.assertEqual((f.home / 'Projects/later/.branch').read_text(), 'main\n')
        self.assertFalse(list(f.home.rglob('*.pyc')))
        fresh = f.plan_result()
        result, events = f.execute(fresh['prepared_plan_id'])
        self.assertEqual(events[-1]['data']['code'], 'repository_target_conflict', events)
        self.assertFalse(events[-1]['data']['publication_started'])

        # Exercise the production parent deadline and its global re-entry fence.
        f = self.restore()
        f.allow_application_bootstrap()
        execution = f.project / 'modules/core/application-interface/execution.py'
        execution.write_text(execution.read_text().replace(
            'self.execution_deadline = time.monotonic() + 86400',
            'self.execution_deadline = time.monotonic() + .001'))
        f.pack()
        plan = f.plan_result()
        result, events = f.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['external_lifecycle_cause'], 'external_execution_deadline')
        fence = f.home / 'Library/Application Support/Macseed/ExternalProcesses/active.json'
        self.assertEqual(json.loads(fence.read_text())['state'], 'unknown_consequences')
        result, events = f.execute(plan['prepared_plan_id'])
        self.assertEqual(events[-1]['data']['code'], 'privileged_lifecycle_unknown', events)
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_unknown_blocks_execute_even_without_git_selection(self):
        f = self.restore()
        f.allow_application_bootstrap()
        directory = f.home / 'Library/Application Support/Macseed/GitClone'
        directory.mkdir(parents=True, mode=0o700)
        state = directory / 'active.json'
        state.write_text('{"state":"active"}')
        state.chmod(0o600)
        f.pack()
        plan = f.plan_result()
        result, events = f.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'privileged_lifecycle_unknown')
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_read_only_vscode_routing_preserves_snapshot_and_error(self):
        cli = self.root / 'code'
        cli.write_text('#!/bin/sh\nprintf "publisher.extension\\n"\n')
        cli.chmod(0o700)
        environment = dict(os.environ, PATH=str(self.root) + ':' + os.environ['PATH'])
        before = self.snapshot()
        command = ['bash', '-c', 'source modules/vscode/extensions.sh; observe_vscode_inventory']
        result = subprocess.run(command, env=environment, cwd=ROOT, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout), (0, b'publisher.extension\n'))
        cli.write_text('#!/bin/sh\nexit 2\n')
        result = subprocess.run(command, env=environment, cwd=ROOT, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout), (2, b''))
        mas = self.root / 'mas'
        mas.write_text('#!/bin/sh\n[ "$MAS_NO_AUTO_INDEX" = 1 ] && [ "$1" = list ] || exit 2\nprintf "123 Fixture (1.0)\\n"\n')
        mas.chmod(0o700)
        command = ['bash', '-c', 'source modules/apps/appstore.sh; observe_appstore_inventory']
        result = subprocess.run(command, env=environment, cwd=ROOT, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout), (0, b'123 Fixture (1.0)\n'))
        mas.write_text('#!/bin/sh\nexit 2\n')
        result = subprocess.run(command, env=environment, cwd=ROOT, capture_output=True, timeout=5)
        self.assertEqual((result.returncode, result.stdout), (2, b''))
        self.assertEqual(before, self.snapshot())


if __name__ == '__main__':
    unittest.main()
