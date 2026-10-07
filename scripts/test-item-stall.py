#!/usr/bin/env python3
"""Focused watchdog and real Restore tests, disposable processes/HOME/tools only."""
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

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
from item_execution import ItemExecutor, StallTimer, STALLED, CANCELLED
sys.path.insert(0, str(ROOT / 'modules/apps'))
from brew_items import BrewItemExecutor, valid_name
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
            brew = root / 'brew'
            brew.write_text('''#!/usr/bin/env python3
import json,sys
from pathlib import Path
a=sys.argv[1:]
if a[0]=='info': print(json.dumps({'formulae':[{'full_name':a[-1], 'dependencies':['failed'] if a[-1]=='dependent' else []}]}))
else: Path(sys.argv[-1]).touch()
''')
            brew.chmod(0o700)
            (root / 'failed-items.json').write_text('["formula:failed"]')
            old = os.environ['PATH']; os.environ['PATH'] = str(root) + ':' + old
            try:
                executor = BrewItemExecutor()
                status = executor.execute('formula', 'dependent', ['brew','install',str(root/'dependent')], root)
                self.assertEqual(status, 125)
                self.assertEqual(executor.reason, 'dependency_failed')
                self.assertFalse((root/'dependent').exists())
                independent = BrewItemExecutor()
                self.assertEqual(independent.execute('formula','independent',['brew','install',str(root/'independent')],root),0)
                self.assertTrue((root/'independent').exists())
            finally:
                os.environ['PATH'] = old


if __name__ == '__main__':
    unittest.main()
