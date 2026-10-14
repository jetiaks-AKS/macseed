#!/usr/bin/env python3
"""Stage 1 only: exercise existing cancellation with disposable owned processes.

Run directly, outside a sandbox denying /bin/ps. No real Bootstrap is invoked:
OwnedBootstrap receives a temporary root containing only a mock bootstrap.sh.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO / 'modules/core/application-interface'))
import item_execution as items
from execution import OwnedBootstrap
FIXTURE = REPO / 'scripts/fixtures/restore-cancellation-process.py'
REAL_KILL = os.kill
RESULTS = []


class CancellationMocks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='macseed-cancel-mock-')
        self.directory = Path(self.tmp.name)
        self.births = {}
        self.process = None
        self.owned = None
        self.denied = set()
        items.process_table()  # Refuse to launch if observation is unavailable.

    def alive(self, pid):
        result = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, check=False)
        if result.returncode not in (0, 1):
            raise RuntimeError("process-state observation failed")
        state = result.stdout.strip()
        return bool(state) and not state.startswith(b'Z')

    def signal_owned(self, pid, sig):
        if pid not in self.births or pid <= 1:
            raise AssertionError('refusing signal outside fixture ownership')
        row = items.process_table().get(pid)
        if row is None:
            raise ProcessLookupError(pid)
        if row[1] != self.births[pid]:
            raise AssertionError('birth identity changed; refusing signal')
        if pid in self.denied:
            raise PermissionError('simulated privileged child')
        REAL_KILL(pid, sig)

    def ready(self):
        deadline = time.monotonic() + 5
        while not (self.directory / 'ready').exists():
            if time.monotonic() > deadline:
                self.fail('fixture readiness timeout')
            time.sleep(.01)
        data = json.loads((self.directory / 'ready').read_text())
        table = items.process_table()
        self.assertEqual(data['root'], self.process.pid)
        for pid in [data['root'], data['child']]:
            if pid:
                self.assertIn(pid, table)
                self.births[pid] = table[pid][1]
        return data

    def launch(self, mode, owned=False, ignore=False, reap=True):
        if ignore:
            (self.directory / 'ignore').touch()
        if owned:
            launcher = self.directory / 'bootstrap.sh'
            import shlex
            launcher.write_text('#!/bin/sh\nexec ' + ' '.join(map(shlex.quote,
                [sys.executable, '-B', str(FIXTURE), mode, str(self.directory)])) + '\n')
            launcher.chmod(0o700)
            self.owned = OwnedBootstrap(self.directory, dict(os.environ))
            self.process = self.owned.process
        else:
            self.process = subprocess.Popen([sys.executable, '-B', str(FIXTURE), mode, str(self.directory)],
                                            start_new_session=True)
        self.births[self.process.pid] = items.process_table()[self.process.pid][1]
        data = self.ready()
        # Reap root promptly so zombies are not confused with running processes.
        if reap:
            threading.Thread(target=self.process.wait, daemon=True).start()
        return data

    def record(self, scenario, started, stop_return, **extra):
        stop_seconds = round(time.monotonic() - started, 3)
        deadline = time.monotonic() + 2
        while any(self.alive(pid) for pid in self.births) and time.monotonic() < deadline and not extra.get('survivor_expected'):
            time.sleep(.02)
        live = [pid for pid in self.births if self.alive(pid)]
        row = dict(scenario=scenario, stop_seconds=stop_seconds,
                   stop_and_confirmation_seconds=round(time.monotonic() - started, 3),
                   stop_return=stop_return, live_count=len(live), **extra)
        RESULTS.append(row)
        return live

    def tearDown(self):
        # Use unpatched kernel observation and only registered, matching identities.
        self.denied.clear()
        try:
            for pid, birth in self.births.items():
                row = items.process_table().get(pid)
                if row and row[1] == birth:
                    try:
                        REAL_KILL(pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
            if self.process:
                self.process.wait(timeout=5)
            deadline = time.monotonic() + 3
            while any(self.alive(pid) for pid in self.births) and time.monotonic() < deadline:
                time.sleep(.02)
            self.assertFalse(any(self.alive(pid) for pid in self.births), 'fixture process survived cleanup')
        finally:
            if self.owned and Path(self.owned.item_state.name).exists():
                self.owned._collect()
            self.tmp.cleanup()

    def check_tree(self, mode, ignore=False):
        self.launch(mode, ignore=ignore)
        tree = items.ProcessTree(self.process.pid)
        started = time.monotonic()
        with patch.object(items.os, 'kill', side_effect=self.signal_owned):
            stopped = tree.stop()
        self.assertTrue(stopped)
        self.assertFalse(self.record(mode + ('-ignore-term' if ignore else ''), started, stopped))

    def test_01_plain(self):
        self.check_tree('plain')

    def test_02_child(self):
        self.check_tree('child')

    def test_03_ignores_term(self):
        self.check_tree('child', ignore=True)

    def test_04_detached_remembered(self):
        self.check_tree('detached', ignore=True)

    def test_05_denied_child_owned_cancel(self):
        data = self.launch('denied', owned=True, ignore=True)
        self.owned.tree.scan()
        self.denied.add(data['child'])
        original_stop = self.owned.tree.stop
        returns = []
        def observed_stop():
            value = original_stop(); returns.append(value); return value
        started = time.monotonic()
        with patch.object(items.os, 'kill', side_effect=self.signal_owned), patch.object(self.owned.tree, 'stop', side_effect=observed_stop):
            result = self.owned.cancel()
        live = self.record('denied-child-owned-cancel', started, returns[0], cancel_return=result,
                           unknown_consequences=self.owned.unknown_consequences, survivor_expected=True)
        self.assertFalse(returns[0])
        self.assertEqual(result, 130)
        self.assertIn(data['child'], live)
        self.assertTrue(self.owned.unknown_consequences)
        self.owned._collect()
        self.assertTrue(self.owned.unknown_consequences)

    def test_06_observer_unavailable(self):
        self.launch('plain', owned=True)
        self.owned.tree.scan()
        started = time.monotonic()
        with patch.object(items, 'process_table', side_effect=OSError('simulated observation denial')):
            result = self.owned.cancel()
        self.assertEqual(result, 130)
        self.assertTrue(self.owned.unknown_consequences)
        self.assertFalse(self.record('observer-unavailable', started, result,
                                     unknown_consequences=self.owned.unknown_consequences))

    def test_09_owned_normal_cancel(self):
        # OwnedBootstrap reaps after tree.stop(), just as the real Restore path.
        # An exited but unreaped root must not produce unknown consequences.
        self.launch('plain', owned=True, reap=False)
        self.owned.tree.scan()
        original_stop = self.owned.tree.stop
        returned = []
        def observed_stop():
            stopped = original_stop(); returned.append(stopped); return stopped
        started = time.monotonic()
        with patch.object(items.os, 'kill', side_effect=self.signal_owned), patch.object(self.owned.tree, 'stop', side_effect=observed_stop):
            result = self.owned.cancel()
        self.assertEqual(returned, [True])
        self.assertEqual(result, 130)
        self.assertFalse(self.owned.unknown_consequences)
        self.assertFalse(self.record('owned-normal-cancel', started, returned[0], cancel_return=result))

    def test_terminal_unknown_propagation(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('cancellation_core', REPO / 'modules/core/application-interface/core.py')
        core = importlib.util.module_from_spec(spec); spec.loader.exec_module(core)
        for unknown, expected_code, expected_exit in [(False, 'cancelled', 130), (True, 'privileged_lifecycle_unknown', 2)]:
            owner = type('MockOwner', (), {'unknown_consequences': unknown})()
            state = {'target_mutation_may_have_started': True}
            events = []
            def failure(code, exit_status=2):
                events.append({'type': 'failed', 'data': dict(state, code=code)})
                return exit_status
            self.assertEqual(core.restore_cancelled_result(state, owner, failure), expected_exit)
            self.assertEqual(events[0]['data']['unknown_consequences'], unknown)
            self.assertEqual(events[0]['data']['code'], expected_code)
            self.assertNotEqual(events[0]['type'], 'completed')
        model = (REPO / 'desktop/Macseed/Sources/RestoreModel.swift').read_text()
        self.assertIn('if payload?["unknown_consequences"]?.boolean == true || !validTerminal', model)

    def test_07_detached_before_first_scan(self):
        data = self.launch('unseen', ignore=True)
        tree = items.ProcessTree(self.process.pid, initialize=False)
        (self.directory / 'release').touch()
        self.process.wait(timeout=3)
        started = time.monotonic()
        with patch.object(items.os, 'kill', side_effect=self.signal_owned):
            result = tree.stop()
        live = self.record('detached-before-first-scan', started, result, survivor_expected=True)
        self.assertTrue(result)
        self.assertIn(data['child'], live)

    def test_08_item_watchdog_cancel(self):
        executor = items.ItemExecutor(interval=180, poll=.02)
        values = []
        worker = threading.Thread(target=lambda: values.append(executor.run(
            [sys.executable, '-B', str(FIXTURE), 'detached', str(self.directory)])))
        (self.directory / 'ignore').touch()
        real_popen = subprocess.Popen
        def owned_popen(command, *args, **kwargs):
            process = real_popen(command, *args, **kwargs)
            if str(FIXTURE) in command:
                self.process = process
                self.births[process.pid] = items.process_table()[process.pid][1]
            return process
        launch_patch = patch.object(subprocess, 'Popen', side_effect=owned_popen)
        signal_patch = patch.object(items.os, 'kill', side_effect=self.signal_owned)
        launch_patch.start(); signal_patch.start()
        self.addCleanup(launch_patch.stop); self.addCleanup(signal_patch.stop)
        worker.start()
        deadline = time.monotonic() + 5
        while not (self.directory / 'ready').exists():
            if time.monotonic() > deadline:
                executor.cancel(); worker.join(timeout=5); self.fail('watchdog fixture timeout')
            time.sleep(.01)
        data = json.loads((self.directory / 'ready').read_text())
        table = items.process_table()
        self.assertEqual(table[data['root']][0], os.getpid())
        for pid in data.values():
            if pid:
                self.births[pid] = table[pid][1]
        started = time.monotonic()
        with patch.object(items.os, 'kill', side_effect=self.signal_owned):
            executor.cancel(); worker.join(timeout=8)
        self.assertFalse(worker.is_alive())
        self.assertEqual(values[0][0], items.CANCELLED)
        self.assertFalse(self.record('item-watchdog-cancel', started, 130, unquiescent=executor.unquiescent))


if __name__ == '__main__':
    result = unittest.TextTestRunner(verbosity=2).run(unittest.defaultTestLoader.loadTestsFromTestCase(CancellationMocks))
    print(json.dumps(RESULTS, indent=2), flush=True)
    sys.exit(not result.wasSuccessful())
