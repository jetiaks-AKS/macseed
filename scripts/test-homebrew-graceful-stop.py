#!/usr/bin/env python3
"""Operation-wide Restore boundaries and Homebrew admission mocks; no real user state."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import patch
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
from homebrew_stop import Controller, State, StopAccepted, KEY
from item_execution import ItemExecutor

class GracefulMocks(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='macseed-graceful-mock-')
        self.base = Path(self.tmp.name)
        self.read_fd, self.write_fd = os.pipe()
        self.control = Controller(self.base, self.read_fd)
        self.state = self.control.state
        self.state.boundary('homebrew')
        self.children = []
        self.env = patch.dict(os.environ, {KEY: str(self.state.path)})
        self.env.start()
    def tearDown(self):
        self.control.close()
        for child in self.children:
            if child.poll() is None:
                child.kill()
            child.wait(timeout=3)
        os.close(self.read_fd)
        if self.write_fd is not None: os.close(self.write_fd)
        self.env.stop(); self.tmp.cleanup()
    def launch(self, command):
        child = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(child)
        return child
    def request(self):
        os.write(self.write_fd, b'S')
        deadline = time.monotonic() + 2
        while not self.state.stopped():
            self.assertLess(time.monotonic(), deadline)
            time.sleep(.01)
        # Acceptance and its acknowledgement are committed under the controller lock.
        with self.control.lock:
            self.assertTrue(self.control.accepted)
    def install(self, status=0):
        code = "import sys,time; from pathlib import Path; p=Path(sys.argv[1]); (p/'started').touch();\nwhile not (p/'release').exists(): time.sleep(.01)\n(p/'completed').touch();sys.exit(int(sys.argv[2]))"
        child = self.state.launch([sys.executable, '-B', '-c', code, str(self.base), str(status)], self.launch)
        deadline = time.monotonic() + 2
        while not (self.base / 'started').exists():
            self.assertLess(time.monotonic(), deadline); time.sleep(.01)
        return child
    def test_before_native_launch(self):
        self.request()
        with self.assertRaises(StopAccepted): self.install()
        self.assertFalse(self.children)
    def test_cask_finishes_and_postchecks_then_no_item(self):
        child = self.install(); self.request()
        self.assertIsNone(child.poll())
        (self.base / 'release').touch(); self.assertEqual(child.wait(timeout=3), 0)
        (self.base / 'postchecked').touch()
        with self.assertRaises(StopAccepted): self.state.launch(['not-launched'], self.launch)
        self.assertTrue((self.base / 'completed').exists() and (self.base / 'postchecked').exists())
    def test_formula_finishes(self):
        self.test_cask_finishes_and_postchecks_then_no_item()
    def test_between_items_and_repeated_stop(self):
        child = self.install(); (self.base / 'release').touch(); child.wait(timeout=3)
        self.request(); self.request()
        self.assertEqual(len(self.children), 1)
        with self.assertRaises(StopAccepted): self.state.launch(['not-launched'], self.launch)
    def test_race(self):
        entered = threading.Event(); release = threading.Event()
        def native(command):
            entered.set(); release.wait(timeout=2)
            return self.launch(command)
        worker = threading.Thread(target=lambda: self.state.launch([sys.executable, '-c', 'pass'], native))
        worker.start(); self.assertTrue(entered.wait(timeout=2))
        os.write(self.write_fd, b'S'); release.set(); worker.join(timeout=3)
        self.assertFalse(worker.is_alive())
        deadline = time.monotonic() + 2
        while not self.state.stopped():
            self.assertLess(time.monotonic(), deadline); time.sleep(.01)
        with self.assertRaises(StopAccepted): self.state.launch(['not-launched'], self.launch)
        self.assertEqual(len(self.children), 1)
    def test_failed_installer_retains_failure(self):
        child = self.install(7); self.request(); (self.base / 'release').touch()
        self.assertEqual(child.wait(timeout=3), 7)
    def test_channel_loss_freezes_admission(self):
        child = self.install(); os.close(self.write_fd); self.write_fd = None
        deadline = time.monotonic() + 2
        while not self.control.lost:
            self.assertLess(time.monotonic(), deadline); time.sleep(.01)
        self.assertIsNone(child.poll())
        (self.base / 'release').touch(); child.wait(timeout=3)
        with self.assertRaises(StopAccepted): self.state.launch(['not-launched'], self.launch)
    def test_non_homebrew_scope_accepts_and_retains_stop(self):
        for scope in ['preparation', 'publication', 'git', 'workspace', 'settings', 'verification']:
            self.state.boundary(scope)
        self.request()
        self.assertTrue(self.control.accepted)
        for scope in ['idle', 'homebrew', 'git']:
            with self.assertRaises(StopAccepted): self.state.boundary(scope)

    def test_scope_returns_idle_after_module(self):
        script = 'source modules/core/common/common.sh\nrun_module_body() { return 0; }\napplication_module_record() { :; }\nrun_module next configure_git\n'
        result = subprocess.run(['bash', '-c', script], cwd=ROOT, env=os.environ, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.state.locked(lambda data: data['scope']), 'idle')

    def test_non_homebrew_current_module_finishes_then_stops(self):
        script = 'source modules/core/common/common.sh\napplication_module_record() { :; }\nrun_module_body() { touch "$MOCK/started"; while [[ ! -f "$MOCK/release" ]]; do sleep .02; done; touch "$MOCK/finished"; }\nrun_module current configure_git\ntouch "$MOCK/next"\n'
        child = subprocess.Popen(['bash', '-c', script], cwd=ROOT, env=dict(os.environ, MOCK=str(self.base)))
        self.children.append(child)
        deadline = time.monotonic() + 2
        while not (self.base / 'started').exists():
            self.assertLess(time.monotonic(), deadline); time.sleep(.01)
        self.request(); self.assertIsNone(child.poll())
        (self.base / 'release').touch()
        self.assertEqual(child.wait(timeout=3), 132)
        self.assertTrue((self.base / 'finished').exists()); self.assertFalse((self.base / 'next').exists())

    def test_bootstrap_next_module_never_runs(self):
        self.request()
        script = "source modules/core/common/common.sh\nrun_module_body() { touch \"$NEXT_MARKER\"; }\nrun_module next install_appstore_apps\n"
        env = dict(os.environ, NEXT_MARKER=str(self.base / 'next'))
        result = subprocess.run(['bash', '-c', script], cwd=ROOT, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertEqual(result.returncode, 132); self.assertFalse((self.base / 'next').exists())
    def test_force_stop_during_wait(self):
        from item_execution import ProcessTree
        child = self.install(); self.request()
        tree = ProcessTree(child.pid)
        threading.Thread(target=child.wait, daemon=True).start()
        tree.stop()
        self.assertIsNotNone(child.poll())
        self.assertFalse((self.base / 'completed').exists())

    def test_terminal_requires_accepted_stop(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location('mock_graceful_core', ROOT / 'modules/core/application-interface/core.py')
        core = importlib.util.module_from_spec(spec); spec.loader.exec_module(core)
        for accepted, unknown, expected in [(True, False, 130), (False, False, 2), (True, True, 2)]:
            control = type('Control', (), {'accepted': accepted})()
            owner = type('Owner', (), {'graceful': control})()
            state = {'unknown_consequences': unknown}
            codes = []
            result = core.restore_graceful_result(state, owner, lambda code, status: codes.append(code) or status)
            self.assertEqual(result, expected)
            self.assertEqual(codes, ['cancelled'] if expected == 130 else ['privileged_lifecycle_unknown'])

    def test_settings_checkpoint_stops_before_next_category(self):
        self.check_settings_stop(False)
    def test_settings_error_wins_and_has_scope_record(self):
        self.check_settings_stop(True)
    def check_settings_stop(self, failed):
        script = """source modules/core/common/common.sh
source modules/settings/macos/macos.sh
blueprint_category_enabled() { return 0; }
check_finder() { return 1; }
apply_finder_settings() {
    touch "$MOCK/started"
    while [[ ! -f "$MOCK/release" ]]; do sleep .02; done
    return "$FAIL_CODE"
}
check_dock() { touch "$MOCK/next"; return 0; }
application_module_record() { printf '%s %s %s\\n' "$1" "$2" "$3" >> "$MOCK/records"; }
MODULE_CHANGED=false
apply_macos_components
"""
        child = subprocess.Popen(['bash', '-c', script], cwd=ROOT,
            env=dict(os.environ, MOCK=str(self.base), FAIL_CODE='2' if failed else '0'))
        self.children.append(child)
        deadline = time.monotonic() + 2
        while not (self.base / 'started').exists():
            self.assertLess(time.monotonic(), deadline); time.sleep(.01)
        self.request(); (self.base / 'release').touch()
        self.assertEqual(child.wait(timeout=3), 2 if failed else 132)
        self.assertFalse((self.base / 'next').exists())
        if failed: self.assertIn('check_finder finished 2', (self.base / 'records').read_text())

    def test_owned_bootstrap_shares_controller_without_closing_it(self):
        from execution import OwnedBootstrap
        root = self.base / 'owned'; root.mkdir()
        bootstrap = root / 'bootstrap.sh'
        bootstrap.write_text('#!/bin/bash\nexit 0\n'); bootstrap.chmod(0o700)
        home = self.base / 'home'; home.mkdir(mode=0o700)
        with patch('homebrew_stop.Controller', side_effect=AssertionError('second controller')):
            owned = OwnedBootstrap(root, dict(os.environ, HOME=str(home), MACSEED_GRACEFUL_FD=str(self.read_fd)), graceful_control=self.control)
            self.assertIs(owned.graceful, self.control)
            self.assertEqual(owned.wait(), 0)
        self.assertFalse(self.control.closed.is_set())

    def test_restore_preparation_stop_preserves_flags(self):
        self.check_core_checkpoint('preparation')
    def test_restore_publication_finishes_before_stop(self):
        self.check_core_checkpoint('publication')
    def test_restore_stop_before_preparation(self):
        self.check_core_checkpoint('initial')
    def check_core_checkpoint(self, point):
        import importlib.util
        from contextlib import contextmanager
        spec = importlib.util.spec_from_file_location('checkpoint_core', ROOT / 'modules/core/application-interface/core.py')
        core = importlib.util.module_from_spec(spec); spec.loader.exec_module(core)
        plan_id = 'a' * 64
        plan = {'prepared_plan_id': plan_id, 'has_executable_changes': True, 'readiness': {'conditions': []}, 'error_count': 0}
        (self.base / 'blueprint.conf').write_text('fixture')
        @contextmanager
        def prepared(*args):
            if point == 'preparation': self.request()
            yield plan, self.base, 'digest', 'digest'
        def publish(stage):
            self.assertEqual(point, 'publication')
            self.request()
        events = []
        if point == 'initial': self.request()
        with patch.dict(os.environ, {'MACSEED_GRACEFUL_FD': str(self.read_fd)}), \
             patch.object(core, 'Controller', return_value=self.control), \
             patch.object(core, 'prepared_restore', prepared), patch.object(core, 'readiness'), \
             patch.object(core.bundle, 'parse_blueprint', return_value=({}, {})), \
             patch.object(core.bundle, 'fingerprint', return_value='digest'), \
             patch.object(core.bundle, 'RECOVERY', self.base / 'no-recovery'), \
             patch.object(core.bundle, 'publish', side_effect=publish) as publication, \
             patch.object(core, 'OwnedBootstrap') as bootstrap, \
             patch.object(core, 'emit', side_effect=lambda sequence, kind, operation, data=None: events.append((kind, data))):
            result = core.restore_execute('fixture', str(self.base), [], False, plan_id)
        self.assertEqual(result, 130)
        terminal = events[-1][1]
        self.assertEqual(events[-1][0], 'failed'); self.assertEqual(terminal['code'], 'cancelled')
        self.assertFalse(terminal['target_mutation_may_have_started']); self.assertFalse(terminal['unknown_consequences'])
        self.assertEqual(terminal['publication_occurred'], point == 'publication')
        self.assertEqual(terminal['verification']['status'], 'not_run')
        self.assertEqual(publication.call_count, int(point == 'publication')); bootstrap.assert_not_called()
        self.assertTrue(any(kind == 'execution_event' and row.get('state') == 'graceful_stop_accepted' for kind, row in events))

    def check_bash_consumer(self, kind, failed=False):
        fifo = self.base / 'finish'; os.mkfifo(fifo, 0o600)
        cask = kind == 'casks'
        domain = 'homebrew-casks' if cask else 'homebrew-packages'
        install = 'brew_install_cask_command' if cask else 'brew_install_formula'
        inspect = 'is_cask_installed' if cask else 'is_brew_package_installed'
        argument = '$2' if cask else '$1'
        script = f"""source modules/apps/brew-{kind}.sh
        action() {{ :; }}; success() {{ :; }}; error() {{ :; }}; warning() {{ :; }}; detail() {{ :; }}
        brew() {{ return 99; }}
        blueprint_exists() {{ return 1; }}
        blueprint_generated_file() {{ printf unused; }}
        blueprint_item_selected() {{ return 0; }}
        read_brew_{kind}_configuration() {{ printf 'A\nB\n'; }}
        {inspect}() {{
            if [[ -f "$MOCK/done-$1" ]]; then printf checked > "$MOCK/post-$1"; return 0; fi
            return 1
        }}
        {install}() {{
            local item={argument}
            printf started > "$MOCK/start-$item"
            read -r completion < "$MOCK/finish"
            printf done > "$MOCK/done-$item"
            return {7 if failed else 0}
        }}
        verification_application_operation_hook() {{ printf '%s' "$4" > "$MOCK/receipt-$2"; }}
        verification_operation_hook() {{ printf '%s' "$4" > "$MOCK/receipt-$2"; }}
        verification_application_post_hook() {{ :; }}; verification_post_hook() {{ :; }}
        VERBOSE=true; MACSEED_APPLICATION_EXECUTION=false
        install_brew_{kind}
        """
        child = subprocess.Popen(['bash', '-c', script], cwd=ROOT, env=dict(os.environ, MOCK=str(self.base)),
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.children.append(child)
        try:
            deadline = time.monotonic() + 2
            while not (self.base / 'start-A').exists():
                self.assertIsNone(child.poll()); self.assertLess(time.monotonic(), deadline); time.sleep(.01)
            self.request()
        finally:
            # Release only this fixture's private FIFO; no signals or mounts.
            try:
                descriptor = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
                os.write(descriptor, b'finish\n'); os.close(descriptor)
            except OSError:
                pass
        self.assertEqual(child.wait(timeout=3), 2 if failed else 132)
        if not failed: self.assertTrue((self.base / 'post-A').exists())
        self.assertEqual((self.base / 'receipt-A').read_text(), 'failure' if failed else 'success')
        self.assertFalse((self.base / 'start-B').exists())
    def test_real_cask_consumer_postchecks(self):
        self.check_bash_consumer('casks')
    def test_real_cask_consumer_failure_wins_over_stop(self):
        self.check_bash_consumer('casks', failed=True)
    def test_real_formula_consumer_postchecks(self):
        self.check_bash_consumer('packages')

    def test_item_executor_actual_native_gate(self):
        self.request()
        self.assertEqual(ItemExecutor().run(['brew', 'install', 'never'])[0], 132)

if __name__ == '__main__': unittest.main(verbosity=2)
