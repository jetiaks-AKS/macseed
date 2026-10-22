#!/usr/bin/env python3
"""Focused watchdog and real Restore tests, disposable processes/HOME/tools only."""
import importlib.util
import hashlib
import itertools
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import Mock, patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
from item_execution import ItemExecutor, StallTimer, STALLED, CANCELLED
sys.path.insert(0, str(ROOT / 'modules/apps'))
from brew_items import BrewItemExecutor, valid_name
sys.path.insert(0, str(ROOT / 'modules/apps/adapters'))
from adapters import homebrew_lifecycle as lifecycle
spec = importlib.util.spec_from_file_location('restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class WatchdogTests(unittest.TestCase):
    def test_dependency_identity_validation(self):
        for name in ['-force', '../payload.rb', '/tmp/tool', 'owner/tap/../tool', 'tool.rb', False]:
            self.assertFalse(valid_name(name))
        for name in ['tree', 'python@3.14', 'owner/tap/tool']:
            self.assertTrue(valid_name(name))

    def test_no_total_runtime_limit(self):
        timer = StallTimer(0)
        for second in range(1, 1201):
            self.assertFalse(timer.observe(second, second % 150 == 0))
        self.assertFalse(timer.observe(1379, False))
        self.assertTrue(timer.observe(1380, False))

    def test_completed_process_is_not_reclassified_as_stalled(self):
        from unittest.mock import patch
        with patch('item_execution.ProgressProbe.sample', side_effect=lambda _: time.sleep(.3) or False):
            status, _ = ItemExecutor(interval=.2, poll=.02).run([sys.executable, '-B', '-c', 'import time; time.sleep(.05)'])
        self.assertEqual(status, 0)

    def test_real_file_growth(self):
        with tempfile.TemporaryDirectory() as directory:
            target = str(Path(directory, 'download.incomplete'))
            code = "import sys,time; f=open(sys.argv[1],'wb');\nfor i in range(12): f.write(b'x'*1024); f.flush(); time.sleep(.1)"
            executor = ItemExecutor(interval=.6, poll=.02)
            status, _ = executor.run([sys.executable, '-B', '-c', code, target])
            self.assertEqual(status, 0)
            self.assertGreater(Path(target).stat().st_size, 0)

    def test_artifact_read_progress(self):
        with tempfile.TemporaryDirectory() as directory:
            target = Path(directory, 'artifact')
            target.write_bytes(b'x' * 1024 * 1024)
            code = "import sys,time; f=open(sys.argv[1],'rb',buffering=0);\nfor i in range(12): f.read(4096); time.sleep(.1)"
            executor = ItemExecutor(interval=.6, poll=.02)
            status, _ = executor.run([sys.executable, '-B', '-c', code, str(target)])
            self.assertEqual(status, 0)

    def test_stall_kills_separate_group_descendant(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory, 'pid')
            code = """import subprocess,sys,time
p=subprocess.Popen([sys.executable,'-B','-c','import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'],start_new_session=True)
open(sys.argv[1],'w').write(str(p.pid))
time.sleep(60)
"""
            executor = ItemExecutor(interval=.6, poll=.02)
            status, _ = executor.run([sys.executable, '-B', '-c', code, str(pidfile)])
            self.assertEqual(status, STALLED)
            self.assertEqual(executor.reason, 'item_stalled_timeout')
            pid = int(pidfile.read_text())
            for _ in range(50):
                row = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True).stdout.strip()
                if not row or row.startswith(b'Z'):
                    break
                time.sleep(.02)
            else:
                os.kill(pid, signal.SIGKILL); self.fail('owned descendant survived')

    def test_short_lived_parent_does_not_leave_group_child(self):
        with tempfile.TemporaryDirectory() as directory:
            pidfile = Path(directory, 'pid')
            code = "import subprocess,sys; p=subprocess.Popen([sys.executable,'-B','-c','import time; time.sleep(60)'],process_group=0); open(sys.argv[1],'w').write(str(p.pid))"
            # macOS system Python 3.9 has no process_group parameter; use setsid-
            # independent setpgrp, preserving the owned session exactly as brew does.
            code = code.replace('process_group=0', 'preexec_fn=__import__("os").setpgrp')
            executor = ItemExecutor(interval=180, poll=.02)
            status, _ = executor.run([sys.executable, '-B', '-c', code, str(pidfile)])
            self.assertEqual(status, 0)
            pid = int(pidfile.read_text())
            stat = subprocess.run(['/bin/ps', '-p', str(pid), '-o', 'stat='], capture_output=True).stdout.strip()
            self.assertTrue(not stat or stat.startswith(b'Z'))

    def test_cancellation(self):
        import threading
        executor = ItemExecutor(interval=180, poll=.02)
        timer = threading.Timer(.3, executor.cancel)
        timer.start()
        try:
            status, _ = executor.run([sys.executable, '-B', '-c', 'import time; time.sleep(60)'])
            self.assertEqual(status, CANCELLED)
            self.assertEqual(executor.reason, 'cancelled')
        finally:
            timer.cancel()


class RestoreStallTests(unittest.TestCase):
    def test_production_cask_stall_continues_and_verifies(self):
        self.production_cask_stall()

    def test_production_cask_repair_stall_continues_and_verifies(self):
        self.production_cask_stall(repair=True)

    def production_cask_stall(self, repair=False):
        f = fixture.RestorePrepareTests()
        f.setUp(); self.addCleanup(f.doCleanups)
        if repair:
            _, prefix, _ = f.repair_cask_fixture()
        else:
            f.cask_fixture(mixed=True)
        module = f.project / 'modules/core/application-interface/item_execution.py'
        module.write_text(module.read_text().replace('STALL_SECONDS = 180', 'STALL_SECONDS = 1.5'))
        blueprint = f.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[homebrew-casks]\nfixture-cask\n', '[homebrew-casks]\nfixture-cask\nlater-cask\n'))
        (f.stage / 'generated/brew-casks.conf').write_bytes(b'fixture-cask\nlater-cask\n')
        f.environment['STALL_PID'] = str(f.root / 'stall-pid')
        f.environment['LATER_STATE'] = str(f.root / 'later-state')
        # Executable mock, never a shell-function replacement of the child command.
        brew = f.root / 'bin/brew'
        brew.write_text('''#!/usr/bin/env python3
import json,os,plistlib,subprocess,sys,time
from pathlib import Path
a=sys.argv[1:]; state=Path(os.environ['TEST_CASK_STATE']); later=Path(os.environ['LATER_STATE'])
if a==['--prefix']: print('/opt/homebrew')
elif a==['--version']: print('Homebrew 7.0.7')
elif a[:1]==['help']: print(a[1]+' --formula --cask --full-name --json --appdir')
elif a==['list','--formula','--full-name']:
 if Path(str(state)+'.formula').exists(): print('fixture-formula')
elif a==['list','--cask']:
 if later.exists(): print('later-cask')
elif a[:3]==['info','--json=v2','--formula']: print(json.dumps({'formulae':[{'full_name':a[-1],'dependencies':[],'build_dependencies':[]}]}))
elif a[:3]==['info','--json=v2','--cask']:
 data=json.loads(Path(os.environ['TEST_CASK_METADATA']).read_text()); data['casks'][0]['token']=a[-1]
 data['casks'][0]['installed']='1.0' if (later.exists() if a[-1]=='later-cask' else state.exists()) else None
 if a[-1]=='later-cask': data['casks'][0]['artifacts']=[{'app':['Later.app'],'target':str(Path(os.environ['TEST_CASK_TARGET']).parent/'Later.app')}]
 print(json.dumps(data))
elif a==['install','fixture-formula']: Path(str(state)+'.formula').touch()
elif a[0]=='install' and a[-1]=='fixture-cask':
 p=subprocess.Popen([sys.executable,'-B','-c','import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); time.sleep(60)'],start_new_session=True)
 Path(os.environ['STALL_PID']).write_text(str(p.pid)); time.sleep(60)
elif a[0]=='install' and a[-1]=='later-cask':
 later.touch(); app=Path(os.environ['TEST_CASK_TARGET']).parent/'Later.app'; (app/'Contents/MacOS').mkdir(parents=True)
 (app/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':'org.example.Later','CFBundleExecutable':'Later'}))
 binary=app/'Contents/MacOS/Later'; binary.write_text('#!/bin/sh\\n'); binary.chmod(0o700)
else: sys.exit(2)
''')
        if repair:
            mock = brew.read_text().replace('/opt/homebrew', str(prefix))
            mock = mock.replace("elif a==['list','--cask']:\n", "elif a==['list','--cask']:\n if state.exists(): print('fixture-cask')\n")
            mock = mock.replace("a[0]=='install' and a[-1]=='fixture-cask'", "a[0]=='reinstall' and a[-1]=='fixture-cask'")
            brew.write_text(mock)
        brew.chmod(0o700)
        f.pack(); prepared = f.invoke()[1][1]['data']['prepared_plan_id']
        result, events = f.execute(prepared)
        self.assertEqual(result.returncode, 2, events)
        final = events[-1]['data']
        self.assertTrue(final['independent_work_completed'])
        self.assertTrue(final['target_mutation_may_have_started'])
        self.assertEqual(final['verification']['status'], 'complete')
        self.assertNotEqual(final['verification']['verdict'], 'selected_requirements_verified')
        records = final['verification']['details']
        self.assertTrue(any(r['item_id']=='fixture-cask' and r['action']==('reinstall' if repair else 'install') and r['reason']=='item_stalled_timeout' for r in records['operation_records']))
        self.assertTrue(any(r['item_id']=='later-cask' and r['conformity']=='verified' for r in records['verification_records']))
        self.assertTrue(any(r['item_id']=='fixture-cask' and r['conformity']!='verified' for r in records['verification_records']))
        self.assertTrue(Path(f.environment['LATER_STATE']).exists())
        pid = int(Path(f.environment['STALL_PID']).read_text())
        stat = subprocess.run(['/bin/ps','-p',str(pid),'-o','stat='],capture_output=True).stdout.strip()
        self.assertTrue(not stat or stat.startswith(b'Z'))

    def test_production_formula_dependency_is_structured_skip(self):
        f = fixture.RestorePrepareTests()
        f.setUp(); self.addCleanup(f.doCleanups)
        f.allow_application_bootstrap()
        module = f.project / 'modules/core/application-interface/item_execution.py'
        module.write_text(module.read_text().replace('STALL_SECONDS = 180', 'STALL_SECONDS = 1.5'))
        blueprint = f.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[homebrew-packages]\n', '[homebrew-packages]\nfailed\ndependent\nindependent\n'))
        fixture.bundle.write_file(f.stage / 'generated/brew-packages.conf', b'failed\ndependent\nindependent\n')
        f.environment['FORMULA_STATE'] = str(f.root / 'formula-state')
        brew = f.root / 'bin/brew'
        brew.write_text('''#!/usr/bin/env python3
import json,os,sys,time
from pathlib import Path
a=sys.argv[1:]; state=Path(os.environ['FORMULA_STATE'])
if a==['--prefix']: print('/opt/homebrew')
elif a==['--version']: print('Homebrew 7.0.7')
elif a[:1]==['help']: print(a[1]+' --formula --cask --full-name --json --appdir')
elif a==['list','--formula','--full-name']:
 if state.exists(): print(state.read_text())
elif a[:3]==['info','--json=v2','--formula']:
 print(json.dumps({'formulae':[{'full_name':a[-1],'dependencies':['failed'] if a[-1]=='dependent' else []}]}))
elif a==['install','failed']: time.sleep(60)
elif a==['install','dependent']: sys.exit(99)
elif a==['install','independent']: state.write_text('independent')
else: sys.exit(2)
''')
        brew.chmod(0o700)
        f.pack(); prepared = f.invoke()[1][1]['data']['prepared_plan_id']
        result, events = f.execute(prepared)
        self.assertEqual(result.returncode, 2, events)
        data = events[-1]['data']
        self.assertTrue(data['independent_work_completed'])
        records = data['verification']['details']
        self.assertTrue(any(r['item_id']=='dependent' and r['outcome']=='skipped' and r['reason']=='dependency_failed' for r in records['operation_records']))
        self.assertTrue(any(r['item_id']=='independent' and r['conformity']=='verified' for r in records['verification_records']))
        self.assertTrue(any(r['item_id']=='dependent' and r['conformity']=='mismatch' for r in records['verification_records']))
        self.assertEqual(Path(f.environment['FORMULA_STATE']).read_text(), 'independent')

    def test_dependency_block_and_independent_continuation(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            home, items = root / 'home', root / 'items'
            home.mkdir(mode=0o700); items.mkdir(mode=0o700)
            brew = root / 'brew'
            brew.write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
a=sys.argv[1:]
if a[0]=='info': print(json.dumps({'formulae':[{'full_name':a[-1], 'dependencies':['failed'] if a[-1]=='dependent' else []}]}))
else: Path(sys.argv[-1]).touch()
''')
            brew.chmod(0o700)
            (items / 'failed-items.json').write_text('["formula:failed"]')
            with patch.dict(os.environ, HOME=str(home), MACSEED_ITEM_STATE_DIR=str(items),
                            MACSEED_APPLICATION_EXECUTION='true',
                            PATH=str(root) + os.pathsep + os.environ['PATH']):
                executor = BrewItemExecutor()
                status = executor.execute('formula', 'dependent', ['brew','install',str(root/'dependent')], items)
                self.assertEqual(status, 125)
                self.assertEqual(executor.reason, 'dependency_failed')
                self.assertFalse((root/'dependent').exists())
                independent = BrewItemExecutor()
                self.assertEqual(independent.execute('formula','independent',['brew','install',str(root/'independent')],items),0)
                self.assertTrue((root/'independent').exists())
                self.assertFalse(lifecycle.pending())
                self.assertFalse((items / 'external-tool-active.json').exists())


class FormulaQuiescenceTests(unittest.TestCase):
    """D1 only: isolated process mocks, private HOME and production consumers."""

    def environment(self):
        temporary = tempfile.TemporaryDirectory(prefix='macseed-formula-quiescence-')
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        home, items = root / 'home', root / 'items'
        home.mkdir(mode=0o700); items.mkdir(mode=0o700)
        return patch.dict(os.environ, HOME=str(home), MACSEED_ITEM_STATE_DIR=str(items),
                          MACSEED_APPLICATION_EXECUTION='true'), items

    def assert_quarantine(self, items):
        marker = items / 'external-tool-active.json'
        journal = lifecycle.state_directory() / 'active.json'
        self.assertEqual(json.loads(marker.read_text())['state'], 'unknown_consequences')
        self.assertEqual(json.loads(journal.read_text())['state'], 'unknown_consequences')
        self.assertEqual(marker.stat().st_mode & 0o777, 0o600)
        self.assertEqual(journal.stat().st_mode & 0o777, 0o600)
        self.assertTrue(lifecycle.pending())

    def test_native_exit_zero_failure_and_timeout_retain_uncertainty(self):
        for status in (0, 1, STALLED):
            with self.subTest(status=status):
                environment, items = self.environment()
                with environment:
                    executor = ItemExecutor()
                    executor.unquiescent = True
                    executor.reason = 'item_stalled_timeout' if status == STALLED else None
                    with patch.object(lifecycle, 'ItemExecutor', return_value=executor), \
                         patch.object(executor, 'run', return_value=(status, b'')), \
                         patch.object(lifecycle.signal, 'signal'), \
                         patch.object(sys, 'argv', ['homebrew_lifecycle.py', '--formula', 'first']):
                        self.assertEqual(lifecycle.main(), lifecycle.UNKNOWN)
                    self.assert_quarantine(items)
                    original = (lifecycle.state_directory() / 'active.json').read_bytes()
                    for kind in ('formula', 'cask'):
                        following = BrewItemExecutor()
                        with patch.object(following, 'run') as run:
                            self.assertEqual(following.execute(kind, 'next', ['native'], items), lifecycle.UNKNOWN)
                            run.assert_not_called()
                    self.assertEqual((lifecycle.state_directory() / 'active.json').read_bytes(), original)

    def test_denied_descendant_cleanup_blocks_following_item(self):
        from item_execution import ProcessTree
        environment, items = self.environment()
        with environment:
            tree = ProcessTree(123456, initialize=False)
            process = Mock(pid=123456)
            process.poll.return_value = 0
            process.wait.return_value = 0
            rows = {123457: (123456, 'birth', '0:00', 'compiler')}
            executor = BrewItemExecutor()
            with patch('item_execution.subprocess.Popen', return_value=process), \
                 patch('item_execution.ProcessTree', return_value=tree), \
                 patch.object(tree, 'scan', return_value=rows), \
                 patch('item_execution.os.kill', side_effect=PermissionError) as kill, \
                 patch('item_execution.time.monotonic', side_effect=itertools.count(0, 2)), \
                 patch.object(executor, 'info', return_value=('formula:first', [])):
                self.assertEqual(executor.execute('formula', 'first', ['native'], items), lifecycle.UNKNOWN)
            self.assertTrue(executor.unquiescent)
            self.assertTrue(kill.called)
            self.assert_quarantine(items)
            with patch.object(executor, 'run') as run:
                self.assertEqual(executor.execute('formula', 'next', ['native'], items), lifecycle.UNKNOWN)
                run.assert_not_called()

    def test_failed_cleanup_observation_is_not_safe_success(self):
        for cleanup in (PermissionError(), RuntimeError()):
            with self.subTest(cleanup=type(cleanup).__name__):
                process = Mock(pid=123456)
                process.poll.return_value = 0
                process.wait.return_value = 0
                tree = Mock()
                tree.stop.side_effect = cleanup
                executor = ItemExecutor()
                with patch('item_execution.subprocess.Popen', return_value=process), \
                     patch('item_execution.ProcessTree', return_value=tree):
                    self.assertEqual(executor.run(['native'])[0], 0)
                self.assertTrue(executor.unquiescent)

    def test_metadata_uncertainty_prevents_native_install(self):
        for dependency in (False, True):
            for status in (0, 1, STALLED):
                with self.subTest(dependency=dependency, status=status):
                    environment, items = self.environment()
                    with environment:
                        if dependency:
                            (items / 'failed-items.json').write_text('["formula:failed"]')
                        executor = BrewItemExecutor()
                        calls = []
                        def run(command, capture=False):
                            calls.append(command)
                            name = command[-1]
                            if not dependency or name == 'dependency':
                                executor.unquiescent = True
                                return status, b'{}'
                            return 0, json.dumps({'formulae': [{'full_name': name, 'dependencies': ['dependency']}]}).encode()
                        with patch.object(executor, 'run', side_effect=run):
                            self.assertEqual(executor.execute('formula', 'first', ['native'], items), lifecycle.UNKNOWN)
                        self.assertTrue(all(command[:2] == ['brew', 'info'] for command in calls))
                        self.assertEqual(len(calls), 2 if dependency else 1)
                        self.assert_quarantine(items)

    def test_outer_native_uncertainty_and_confirmed_local_failures(self):
        for status in (0, 1, STALLED):
            for unknown in (False, True):
                with self.subTest(status=status, unknown=unknown):
                    environment, items = self.environment()
                    with environment:
                        executor = BrewItemExecutor()
                        def run(command, capture=False):
                            executor.unquiescent = unknown
                            return status, b''
                        with patch.object(executor, 'info', return_value=('formula:first', [])), \
                             patch.object(executor, 'run', side_effect=run):
                            self.assertEqual(executor.execute('formula', 'first', ['native'], items), lifecycle.UNKNOWN if unknown else status)
                        if unknown:
                            self.assert_quarantine(items)
                        else:
                            following = BrewItemExecutor()
                            with patch.object(following, 'info', return_value=('formula:next', [])), \
                                 patch.object(following, 'run', return_value=(0, b'')) as launch:
                                self.assertEqual(following.execute('formula', 'next', ['native'], items), 0)
                                launch.assert_called_once()
                            self.assertFalse(lifecycle.pending())

    def restore_fixture(self, status, unknown):
        f = fixture.RestorePrepareTests()
        f.setUp(); self.addCleanup(f.doCleanups)
        f.cask_fixture(mixed=True)
        f.environment.update(TEST_FORMULA_STATUS=str(status), TEST_FORMULA_UNKNOWN=str(unknown).lower(),
                             TEST_FORMULA_LOG=str(f.root / 'formula-log'))
        blueprint = f.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('fixture-formula\n', 'fixture-formula\nlater-formula\n')
                             .replace('shell-zsh="false"', 'shell-zsh="true"'))
        (f.stage / 'generated/brew-packages.conf').write_bytes(b'fixture-formula\nlater-formula\n')
        payload = b'# portable fixture\n'
        snapshot = ('MBT-ZSHRC-1\nstatus=eligible\nreason=-\nlength=' + str(len(payload)) +
                    '\nsha256=' + hashlib.sha256(payload).hexdigest() + '\n---\n').encode() + payload
        fixture.bundle.write_file(f.stage / 'generated/shell/zshrc.snapshot', snapshot)
        brew = f.root / 'bin/brew'
        brew.write_text(brew.read_text().replace(
            '  "install fixture-formula") touch "$TEST_CASK_STATE.formula" ;;',
            '  "install fixture-formula") echo first >> "$TEST_FORMULA_LOG"; '
            '[[ "$TEST_FORMULA_STATUS" != 0 ]] || touch "$TEST_CASK_STATE.formula"; exit "$TEST_FORMULA_STATUS" ;;\n'
            '  "install later-formula") echo later >> "$TEST_FORMULA_LOG"; touch "$TEST_CASK_STATE.later" ;;\n'
            '  "info --json=v2 --formula later-formula") echo \'{"formulae":[{"full_name":"later-formula","dependencies":[]}]}\' ;;')
            .replace('|| echo fixture-formula ;;', '|| echo fixture-formula; [[ ! -f "$TEST_CASK_STATE.later" ]] || echo later-formula ;;'))
        # The copied module uses mock process observation only. Native brew is the
        # disposable executable above; no real Homebrew, process scan or installer.
        module = f.project / 'modules/core/application-interface/item_execution.py'
        module.write_text(module.read_text() + '''
def process_table():
    return {}
_fixture_original_run = ItemExecutor.run
def _fixture_run(self, command, capture=False):
    if command == ['brew', 'install', 'fixture-formula']:
        status = subprocess.run(command, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL).returncode
        self.unquiescent = os.environ['TEST_FORMULA_UNKNOWN'] == 'true'
        if status == STALLED:
            self.reason = 'item_stalled_timeout'
        return status, b''
    return _fixture_original_run(self, command, capture)
ItemExecutor.run = _fixture_run
''')
        f.pack()
        return f

    def test_core_result_and_durable_reentry_gate(self):
        for status in (0, 1, STALLED):
            with self.subTest(status=status):
                f = self.restore_fixture(status, True)
                result, events = f.execute(f.plan_result()['prepared_plan_id'])
                self.assertEqual(result.returncode, 2, events)
                final = events[-1]['data']
                self.assertEqual(final['code'], 'privileged_lifecycle_unknown')
                self.assertTrue(final['unknown_consequences'])
                self.assertFalse(final['independent_work_completed'])
                self.assertEqual(final['verification']['status'], 'complete')
                operations = final['verification']['details']['operation_records']
                first = [row for row in operations if row['domain'] == 'homebrew-packages' and row['item_id'] == 'fixture-formula']
                self.assertEqual([(row['outcome'], row['reason']) for row in first], [('failure', 'privileged_lifecycle_unknown')])
                self.assertEqual(Path(f.environment['TEST_FORMULA_LOG']).read_text(), 'first\n')
                self.assertFalse(Path(f.environment['TEST_CASK_LOG']).exists())
                self.assertFalse((f.home / '.zshrc').exists())
                journal = f.home / 'Library/Application Support/Macseed/Homebrew/active.json'
                original = journal.read_bytes()
                fresh = f.plan_result()
                self.assertFalse(fresh['readiness']['ready'])
                self.assertTrue(any(row['code'] == 'privileged_lifecycle_unknown' for row in fresh['readiness']['conditions']))
                retry, retry_events = f.execute(fresh['prepared_plan_id'])
                self.assertEqual(retry.returncode, 2, retry_events)
                self.assertFalse(retry_events[-1]['data']['publication_started'])
                # Even selecting only a later local configuration cannot bypass
                # the operation-wide live readiness gate before publication.
                selection = {'categories': ['shell-zsh'], 'items': {}}
                settings = f.plan_result(selection=selection)
                retry, retry_events = f.execute(settings['prepared_plan_id'], selection=selection)
                self.assertEqual(retry.returncode, 2, retry_events)
                self.assertEqual(retry_events[-1]['data']['code'], 'privileged_lifecycle_unknown')
                self.assertFalse(retry_events[-1]['data']['publication_started'])
                self.assertEqual(journal.read_bytes(), original)
                self.assertEqual(Path(f.environment['TEST_FORMULA_LOG']).read_text(), 'first\n')
                self.assertFalse((f.home / '.zshrc').exists())

    def test_confirmed_quiescence_preserves_success_and_independent_continuation(self):
        for status in (0, 1, STALLED):
            with self.subTest(status=status):
                f = self.restore_fixture(status, False)
                result, events = f.execute(f.plan_result()['prepared_plan_id'])
                self.assertEqual(result.returncode, 0 if status == 0 else 2, events)
                final = events[-2 if status == 0 else -1]['data']
                if status == 0:
                    self.assertEqual(final['execution_status'], 'completed')
                else:
                    self.assertEqual(final['code'], 'bootstrap_failed')
                self.assertFalse(final['unknown_consequences'])
                self.assertTrue(final['independent_work_completed'])
                self.assertEqual(final['verification']['status'], 'complete')
                self.assertEqual(Path(f.environment['TEST_FORMULA_LOG']).read_text(), 'first\nlater\n')
                self.assertEqual(Path(f.environment['TEST_CASK_LOG']).read_text(), 'install\n')
                self.assertEqual((f.home / '.zshrc').read_bytes(), b'# portable fixture\n')
                self.assertFalse((f.home / 'Library/Application Support/Macseed/Homebrew/active.json').exists())


class FormulaDurabilityTests(unittest.TestCase):
    """D1 final only: one journal, write-ahead faults and crash/re-entry mocks."""

    environment = FormulaQuiescenceTests.environment
    restore_fixture = FormulaQuiescenceTests.restore_fixture

    def test_missing_item_state_prevents_journal_and_launch(self):
        environment, items = self.environment()
        with environment:
            os.environ.pop('MACSEED_ITEM_STATE_DIR')
            executor = BrewItemExecutor()
            with patch.object(executor, 'run') as launch, \
                 patch.object(lifecycle, 'state_directory_fd', wraps=lifecycle.state_directory_fd) as durable, \
                 patch.object(lifecycle, 'journal', wraps=lifecycle.journal) as journal:
                self.assertEqual(executor.execute('formula', 'first', ['native'], items), lifecycle.UNKNOWN)
                self.assertTrue(lifecycle.operation_unknown())
                launch.assert_not_called()
                durable.assert_not_called()
                journal.assert_not_called()
            self.assertFalse((Path.home() / 'Library').exists())
            self.assertEqual(list(items.iterdir()), [])

    def test_persistent_prepare_failures_prevent_every_launch(self):
        for failure in ('create', 'write', 'file_fsync', 'directory_fsync'):
            for boundary in ('outer', 'native'):
                with self.subTest(failure=failure, boundary=boundary):
                    environment, items = self.environment()
                    with environment:
                        directory = lifecycle.state_directory()
                        lifecycle.private_directory(directory)
                        real_open, real_fsync = os.open, os.fsync
                        descriptors = {}
                        def open_file(path, flags, *args, **kwargs):
                            if path == 'active.tmp' and failure == 'create':
                                raise PermissionError('mock persistent create failure')
                            descriptor = real_open(path, flags, *args, **kwargs)
                            descriptors[descriptor] = path
                            return descriptor
                        def fsync(descriptor):
                            if failure == 'file_fsync' and descriptors.get(descriptor) == 'active.tmp':
                                raise OSError('mock persistent file fsync failure')
                            info = os.fstat(descriptor)
                            if (failure == 'directory_fsync' and stat.S_ISDIR(info.st_mode) and
                                    (directory / 'active.json').exists() and
                                    info.st_ino == directory.stat().st_ino):
                                raise OSError('mock persistent directory fsync failure')
                            return real_fsync(descriptor)
                        executor = BrewItemExecutor() if boundary == 'outer' else ItemExecutor()
                        with patch.object(lifecycle.os, 'open', side_effect=open_file), \
                             patch.object(lifecycle.os, 'fsync', side_effect=fsync), \
                             patch.object(executor, 'run') as launch:
                            write = patch.object(lifecycle.json, 'dump', side_effect=OSError('mock write failure')) if failure == 'write' else patch.object(lifecycle.json, 'dump', wraps=json.dump)
                            with write:
                                if boundary == 'outer':
                                    self.assertNotEqual(executor.execute('formula', 'first', ['native'], items), 0)
                                else:
                                    with patch.object(lifecycle, 'ItemExecutor', return_value=executor), \
                                         patch.object(lifecycle.signal, 'signal'), \
                                         patch.object(sys, 'argv', ['lifecycle', '--formula', 'first']):
                                        self.assertNotEqual(lifecycle.main(), 0)
                            launch.assert_not_called()

    def test_durable_state_precedes_metadata_and_native_and_safe_failures_continue(self):
        for status in (0, 1, STALLED, 127):
            with self.subTest(status=status):
                environment, items = self.environment()
                with environment:
                    executor = BrewItemExecutor()
                    calls = []
                    def run(command, capture=False):
                        record = json.loads((lifecycle.state_directory() / 'active.json').read_bytes())
                        self.assertEqual(record['state'], 'active')
                        self.assertEqual(record['owner'], os.pread(executor.inherited_fds[0], 64, 0).decode())
                        calls.append(command)
                        if capture:
                            return 0, json.dumps({'formulae': [{'full_name': 'first', 'dependencies': []}]}).encode()
                        # Nested lifecycle borrows the same durable record. It
                        # cannot clear the parent's evidence even after exit 0.
                        child = ItemExecutor()
                        with patch.object(lifecycle, 'ItemExecutor', return_value=child), \
                             patch.object(child, 'run', return_value=(status, b'')), \
                             patch.object(lifecycle.signal, 'signal'), \
                             patch.object(sys, 'argv', ['lifecycle', '--formula', 'first']):
                            self.assertEqual(lifecycle.main(), status)
                        self.assertEqual(json.loads((lifecycle.state_directory() / 'active.json').read_bytes())['state'], 'active')
                        return status, b''
                    with patch.object(executor, 'run', side_effect=run):
                        self.assertEqual(executor.execute('formula', 'first', ['native'], items), status)
                    self.assertEqual(len(calls), 2)
                    self.assertFalse(lifecycle.pending())
                    self.assertFalse((items / 'external-tool-active.json').exists())
                    if status:
                        record = json.loads((lifecycle.state_directory() / 'active.json').read_bytes())
                        self.assertEqual((record['state'], record['outcome']), ('quiescent', 'failure'))
                    following = BrewItemExecutor()
                    with patch.object(following, 'info', return_value=('formula:next', [])), \
                         patch.object(following, 'run', return_value=(0, b'')) as launch:
                        self.assertEqual(following.execute('formula', 'next', ['native'], items), 0)
                        launch.assert_called_once()

    def test_postlaunch_uncertainty_survives_failed_updates_and_metadata_blocks_native(self):
        for boundary in ('metadata', 'native'):
            for status in (0, 1, STALLED, 127):
                with self.subTest(boundary=boundary, status=status):
                    environment, items = self.environment()
                    with environment:
                        executor = BrewItemExecutor()
                        calls = []
                        write_failure = None
                        def run(command, capture=False):
                            nonlocal write_failure
                            calls.append(command)
                            if boundary == 'native' and capture:
                                return 0, json.dumps({'formulae': [{'full_name': 'first', 'dependencies': []}]}).encode()
                            executor.unquiescent = True
                            # Initial active state is already durable. All later
                            # diagnostic writes fail, including the temporary gate.
                            write_failure = patch.object(lifecycle.json, 'dump', side_effect=OSError('mock disk failure'))
                            write_failure.start()
                            return status, b'{}'
                        try:
                            with patch.object(executor, 'run', side_effect=run):
                                self.assertEqual(executor.execute('formula', 'first', ['native'], items), lifecycle.UNKNOWN)
                        finally:
                            if write_failure is not None:
                                write_failure.stop()
                        self.assertEqual(len(calls), 1 if boundary == 'metadata' else 2)
                        record = json.loads((lifecycle.state_directory() / 'active.json').read_bytes())
                        self.assertEqual(record['state'], 'active')
                        self.assertTrue(lifecycle.pending())
                        for kind in ('formula', 'cask'):
                            following = BrewItemExecutor()
                            with patch.object(following, 'run') as launch:
                                self.assertEqual(following.execute(kind, 'next', ['native'], items), lifecycle.UNKNOWN)
                                launch.assert_not_called()

    def test_unsafe_journal_paths_never_launch_or_clobber_foreign_state(self):
        for conflict in ('directory_link', 'journal_link', 'foreign_journal', 'foreign_lock', 'public_directory'):
            with self.subTest(conflict=conflict):
                environment, items = self.environment()
                with environment:
                    directory = lifecycle.state_directory()
                    target = items / 'foreign'
                    target.write_bytes(b'foreign contents')
                    if conflict == 'directory_link':
                        foreign = items / 'foreign-directory'
                        foreign.mkdir()
                        (Path.home() / 'Library').symlink_to(foreign, target_is_directory=True)
                    else:
                        lifecycle.private_directory(directory)
                        if conflict == 'journal_link':
                            (directory / 'active.json').symlink_to(target)
                        elif conflict == 'foreign_journal':
                            (directory / 'active.json').write_bytes(b'{}')
                            (directory / 'active.json').chmod(0o600)
                        elif conflict == 'foreign_lock':
                            (directory / 'lifecycle.lock').write_bytes(b'foreign contents')
                            (directory / 'lifecycle.lock').chmod(0o600)
                        else:
                            directory.chmod(0o755)
                    executor = BrewItemExecutor()
                    with patch.object(executor, 'run') as launch:
                        self.assertEqual(executor.execute('formula', 'first', ['native'], items), lifecycle.UNKNOWN)
                        launch.assert_not_called()
                    self.assertEqual(target.read_bytes(), b'foreign contents')
                    if conflict == 'directory_link':
                        self.assertEqual(list(foreign.iterdir()), [])
                    elif conflict == 'foreign_journal':
                        self.assertEqual((directory / 'active.json').read_bytes(), b'{}')
                    elif conflict == 'foreign_lock':
                        self.assertEqual((directory / 'lifecycle.lock').read_bytes(), b'foreign contents')

    def test_mock_chain_keeps_safe_success_and_independent_failure(self):
        for status in (0, 1):
            with self.subTest(status=status):
                f = self.restore_fixture(status, False)
                result, events = f.execute(f.plan_result()['prepared_plan_id'])
                self.assertEqual(result.returncode, 0 if status == 0 else 2, events)
                final = events[-2 if status == 0 else -1]['data']
                self.assertFalse(final['unknown_consequences'])
                self.assertTrue(final['independent_work_completed'])
                self.assertEqual(final['verification']['status'], 'complete')
                self.assertEqual(Path(f.environment['TEST_FORMULA_LOG']).read_text(), 'first\nlater\n')
                self.assertEqual(Path(f.environment['TEST_CASK_LOG']).read_text(), 'install\n')
                self.assertEqual((f.home / '.zshrc').read_bytes(), b'# portable fixture\n')
                self.assertFalse((f.home / 'Library/Application Support/Macseed/Homebrew/active.json').exists())

    def test_supervisor_crash_keeps_reentry_blocked_including_without_homebrew(self):
        f = self.restore_fixture(0, False)
        items = f.root / 'crashed-items'
        items.mkdir(mode=0o700)
        code = '''
import os,sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from homebrew_lifecycle import WriteAhead
with WriteAhead('formula', 'fixture-formula'):
    Path(sys.argv[2]).write_text('mock native operation started')
    os._exit(23)
'''
        launched = f.root / 'crash-launch'
        result = subprocess.run([sys.executable, '-B', '-c', code,
                                 str(f.project / 'modules/apps/adapters'), str(launched)],
                                env=dict(f.environment, MACSEED_ITEM_STATE_DIR=str(items)), capture_output=True)
        self.assertEqual(result.returncode, 23, result.stderr)
        self.assertTrue(launched.exists())
        journal = f.home / 'Library/Application Support/Macseed/Homebrew/active.json'
        original = journal.read_bytes()
        self.assertEqual(json.loads(original)['state'], 'active')
        self.assertEqual(journal.stat().st_mode & 0o777, 0o600)
        for selection in (None, {'categories': ['shell-zsh'], 'items': {}}):
            with self.subTest(selection=selection):
                plan = f.plan_result(**({'selection': selection} if selection else {}))
                result, events = f.execute(plan['prepared_plan_id'], selection=selection)
                self.assertEqual(result.returncode, 2, events)
                final = events[-1]['data']
                self.assertEqual(final['code'], 'privileged_lifecycle_unknown')
                self.assertFalse(final['publication_started'])
                self.assertFalse(final['target_mutation_may_have_started'])
                self.assertEqual(journal.read_bytes(), original)
                self.assertFalse(Path(f.environment['TEST_FORMULA_LOG']).exists())
                self.assertFalse(Path(f.environment['TEST_CASK_LOG']).exists())
                self.assertFalse((f.home / '.zshrc').exists())


if __name__ == '__main__':
    unittest.main()
