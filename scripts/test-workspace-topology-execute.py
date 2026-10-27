#!/usr/bin/env python3
"""Native Git mutations only in disposable HOME/local remote fixtures."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import signal
import sys
import time
import unittest

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('restore_fixture', Path(__file__).with_name('test-restore-prepare.py'))
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class TopologyExecuteTests(unittest.TestCase):
    invoke = fixture.RestorePrepareTests.invoke
    execute = fixture.RestorePrepareTests.execute
    pack = fixture.RestorePrepareTests.pack
    configure = fixture.TopologyPreviewTests.configure
    selection = fixture.TopologyPreviewTests.selection
    git_rows = fixture.TopologyPreviewTests.git_rows

    def setUp(self):
        fixture.TopologyPreviewTests.setUp(self)
        fixture.RestorePrepareTests.allow_application_bootstrap(self)
        remote, _ = self.fixture.repository(self.root, 'remote')
        self.environment.update(TEST_REAL_GIT=self.git, TEST_REMOTE=str(remote),
                                GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
        wrapper = self.root / 'bin/git'
        wrapper.write_text('''#!/usr/bin/env python3
import os, subprocess, sys
args = sys.argv[1:]
native = os.environ['TEST_REAL_GIT']
if 'clone' in args:
    assert args[-1].startswith(os.environ['HOME'] + '/')
    remote = args[-2]
    args[-2] = os.environ['TEST_REMOTE']
    with open(os.environ['TEST_MUTATIONS'], 'a') as stream: stream.write('clone\\n')
    code = subprocess.call([native, *args])
    if not code:
        code = subprocess.call([native, '-C', args[-1], 'config', 'remote.origin.url', remote])
    sys.exit(code)
if 'checkout' in args or ('worktree' in args and 'add' in args):
    assert args[args.index('-C') + 1].startswith(os.environ['HOME'] + '/')
    with open(os.environ['TEST_MUTATIONS'], 'a') as stream:
        stream.write('add_worktree\\n' if 'worktree' in args else 'checkout\\n')
    mode = os.environ.get('TEST_GIT_MODE')
    if mode == 'false_success': sys.exit(0)
    if mode == 'partial':
        os.makedirs(args[-2], exist_ok=True)
        with open(os.path.join(args[-2], 'retained.txt'), 'w') as stream: stream.write('retained')
        sys.exit(1)
    if mode == 'wait':
        import time
        time.sleep(60)
    if mode == 'delay':
        import time
        time.sleep(3)
    if mode == 'drop_branch' and 'worktree' in args:
        os.unlink(os.path.join(args[args.index('-C') + 1], '.git/refs/heads/feature'))
os.execv(native, [native, *args])
''')
        wrapper.chmod(0o700)

    def prepare(self, **kwargs):
        result, events = self.invoke(**kwargs)
        self.assertEqual(result.returncode, 0, events)
        return events[1]['data']

    def restore(self, **kwargs):
        plan = self.prepare(**kwargs)
        self.assertTrue(plan['readiness']['ready'], plan)
        result, events = self.execute(plan['prepared_plan_id'], **kwargs)
        self.assertEqual(result.returncode, 0, events)
        data = next(event['data'] for event in events if event['type'] == 'result')
        self.assertFalse(data['unknown_consequences'])
        self.assertEqual(data['verification']['verdict'], 'selected_requirements_verified', data)
        self.assertEqual(data['verification']['details']['status'], 'complete')
        self.assertTrue(all(row['disposition'] == 'satisfied' for row in self.prepare(**kwargs)['plan']))
        return data

    def remove_linked(self, index):
        path = self.home / self.paths[index]
        marker = path / '.git'
        admin = Path(marker.read_text().strip()[8:])
        shutil.rmtree(path)
        shutil.rmtree(admin)

    def test_matching_noop(self):
        self.restore()
        self.assertFalse((self.root / 'mutations').exists())

    def test_add_multiple_linked_and_repeat(self):
        self.remove_linked(1)
        self.remove_linked(2)
        self.restore()
        self.assertCountEqual((self.root / 'mutations').read_text().splitlines(), ['add_worktree', 'add_worktree', 'checkout'])
        self.restore()
        self.assertCountEqual((self.root / 'mutations').read_text().splitlines(), ['add_worktree', 'add_worktree', 'checkout'])

    def test_clone_and_detached_linked_in_one_restore(self):
        self.paths = [self.paths[0], self.paths[2]]
        self.branches, self.parents = ['main', ''], [0, 0]
        self.configure()
        shutil.rmtree(self.home / 'Projects')
        # A preexisting empty linked destination is still owned by worktree add.
        (self.home / self.paths[1]).mkdir(parents=True)
        self.restore()
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['clone', 'add_worktree'])

    def test_switch_and_exact_detached(self):
        original = (self.base / 'tracked.txt').read_text()
        gitdir = self.base / '.git'
        blob = self.fixture.object_file(gitdir, 'blob', b'next revision\n')
        tree = self.fixture.object_file(gitdir, 'tree', b'100644 tracked.txt\0' + bytes.fromhex(blob))
        next_oid = self.fixture.object_file(gitdir, 'commit',
            (f'tree {tree}\nparent {self.oid}\nauthor Fixture <test@example.invalid> 2 +0000\n'
             'committer Fixture <test@example.invalid> 2 +0000\n\nnext\n').encode())
        self.branches[0] = 'next'
        (gitdir / 'refs/heads/next').write_text(next_oid + '\n')
        (self.base / '.git/info').mkdir(exist_ok=True)
        (self.base / '.git/info/exclude').write_text('keep.ignored\n')
        for name in ('keep.untracked', 'keep.ignored'):
            (self.base / name).write_text('preserved ' + name)
        self.configure()
        self.restore()
        self.assertEqual((self.base / 'tracked.txt').read_text(), 'next revision\n')
        self.branches[0] = ''
        self.configure()
        self.restore()
        self.assertEqual((self.base / 'tracked.txt').read_text(), original)
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['checkout'] * 2)
        for name in ('keep.untracked', 'keep.ignored'):
            self.assertEqual((self.base / name).read_text(), 'preserved ' + name)

    def test_folder_only(self):
        self.configure(folders=['Projects/new/inner'])
        self.restore(selection=self.selection([], ['Projects/new/inner']))
        self.assertTrue((self.home / 'Projects/new/inner').is_dir())
        self.assertFalse((self.root / 'mutations').exists())

    def test_partial_selection_leaves_linked_absent(self):
        self.remove_linked(1)
        self.restore(selection=self.selection([0]))
        self.assertFalse((self.home / self.paths[1]).exists())
        self.assertFalse((self.root / 'mutations').exists())

    def test_shared_existing_folder_verifies_despite_git_conflict(self):
        self.paths, self.branches, self.parents = self.paths[:1], ['main'], [0]
        self.configure(folders=[self.paths[0]])
        config = self.base / '.git/config'
        config.write_text(config.read_text().replace('https://', 'https://other.'))
        plan = self.prepare()
        self.assertEqual(self.git_rows(plan)[0]['disposition'], 'conflict')
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 0, events)
        data = next(event['data'] for event in events if event['type'] == 'result')
        self.assertNotEqual(data['verification']['verdict'], 'selected_requirements_verified')
        records = data['verification']['details']['verification_records']
        folders = [row for row in records if row['domain'] == 'workspace-folders']
        self.assertEqual(len(folders), 1)
        self.assertEqual(folders[0]['conformity'], 'verified')
        self.assertFalse((self.root / 'mutations').exists())

    def test_target_change_rejects_before_publication(self):
        self.remove_linked(1)
        plan = self.prepare()
        (self.base / 'tracked.txt').write_text('changed after Preview\n')
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])
        self.assertFalse((self.root / 'mutations').exists())

    def test_detached_base_clone(self):
        self.paths, self.branches, self.parents = self.paths[:1], [''], [0]
        self.configure()
        shutil.rmtree(self.home / 'Projects')
        self.restore()
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['clone', 'checkout'])

    def test_clone_prerequisites_block_before_publication(self):
        self.paths, self.branches, self.parents = self.paths[:1], ['main'], [0]
        self.configure()
        shutil.rmtree(self.home / 'Projects')
        (self.root / 'bin/curl').write_text('#!/bin/bash\nexit 1\n')
        plan = self.prepare()
        self.assertFalse(plan['readiness']['ready'])
        self.assertTrue(any(row['domain'] == 'git-repositories' and row['code'] == 'internet_required'
                            for row in plan['readiness']['conditions']))
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'internet_required')
        self.assertFalse(events[-1]['data']['publication_started'])
        self.assertFalse((self.project / 'config/blueprint.conf').exists())
        self.assertFalse((self.root / 'mutations').exists())

    def test_nested_checkout_and_folder_dependencies(self):
        self.paths = ['Projects/base', 'Projects/base/nested']
        self.branches, self.parents = ['main', 'main'], [0, 1]
        self.configure(folders=['Projects/base', 'Projects/base/nested', 'Projects/base/nested/new'])
        shutil.rmtree(self.home / 'Projects')
        self.restore()
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['clone', 'clone'])

    def test_missing_local_branch_after_clone_is_blocked_without_creation(self):
        self.paths, self.branches, self.parents = self.paths[:2], ['main', 'feature'], [0, 0]
        self.configure()
        shutil.rmtree(self.home / 'Projects')
        plan = self.prepare()
        self.assertEqual(self.git_rows(plan)[1]['reason'], 'workspace_dependency_pending')
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 0, events)
        data = next(event['data'] for event in events if event['type'] == 'result')
        self.assertNotEqual(data['verification']['verdict'], 'selected_requirements_verified')
        self.assertEqual(data['bootstrap_status'], 'warning')
        self.assertFalse((self.home / self.paths[1]).exists())
        self.assertFalse((self.base / '.git/refs/heads/feature').exists())
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['clone'])

    def test_success_exit_without_result_is_not_verified(self):
        self.remove_linked(1)
        self.environment['TEST_GIT_MODE'] = 'false_success'
        plan = self.prepare()
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        data = events[-1]['data']
        self.assertFalse(data['unknown_consequences'])
        self.assertNotEqual(data['verification']['verdict'], 'selected_requirements_verified')
        self.assertTrue(any(row['reason'] == 'workspace_verification_failed'
                            for row in data['verification']['details']['operation_records']))
        self.assertEqual(next(row for row in self.git_rows(self.prepare()) if row['checkout_id'] == self.ids[1])['reason'], 'workspace_partial_checkout')

    def test_partial_worktree_retained_and_retry_fenced(self):
        self.remove_linked(1)
        self.environment['TEST_GIT_MODE'] = 'partial'
        plan = self.prepare()
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual((self.home / self.paths[1] / 'retained.txt').read_text(), 'retained')
        self.assertEqual(next(row for row in self.git_rows(self.prepare()) if row['checkout_id'] == self.ids[1])['reason'], 'workspace_partial_checkout')
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['add_worktree'])

    def test_source_bundle_changed_is_stale(self):
        plan = self.prepare()
        self.branches[0] = 'missing'
        self.configure()
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_branch_disappears_without_implicit_tracking_branch(self):
        self.remove_linked(1)
        tracking = self.base / '.git/refs/remotes/origin/feature'
        tracking.parent.mkdir(parents=True)
        tracking.write_text(self.oid + '\n')
        self.environment['TEST_GIT_MODE'] = 'drop_branch'
        selected = self.selection([0, 1])
        plan = self.prepare(selection=selected)
        result, events = self.execute(plan['prepared_plan_id'], selection=selected)
        self.assertEqual(result.returncode, 2, events)
        self.assertFalse((self.base / '.git/refs/heads/feature').exists())
        self.assertEqual(tracking.read_text(), self.oid + '\n')
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['add_worktree'])

    def test_unknown_consequences_fence_precedes_publication(self):
        plan = self.prepare()
        directory = self.home / 'Library/Application Support/Macseed/ExternalProcesses'
        directory.mkdir(parents=True, mode=0o700)
        state = directory / 'active.json'
        state.write_text(json.dumps(dict(contract=1, tool='external_process', state='unknown_consequences', owner='0' * 32)))
        state.chmod(0o600)
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'privileged_lifecycle_unknown')
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_force_stop_retains_unknown_fence(self):
        self.remove_linked(1)
        self.environment['TEST_GIT_MODE'] = 'wait'
        plan = self.prepare()
        request = dict(protocol_version=1, operation_id='cancel-worktree', operation='restore_execute',
                       parameters=dict(path=str(self.archive), disabled_groups=[], include_secure=False,
                                       expected_prepared_plan_id=plan['prepared_plan_id']))
        with tempfile_output() as output:
            process = subprocess.Popen(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                cwd=self.project, env=self.environment, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.DEVNULL)
            try:
                process.stdin.write(json.dumps(request).encode()); process.stdin.close()
                deadline = time.monotonic() + 120
                while not (self.root / 'mutations').exists() and process.poll() is None and time.monotonic() < deadline:
                    time.sleep(.05)
                self.assertTrue((self.root / 'mutations').exists())
                process.send_signal(signal.SIGTERM)
                process.wait(timeout=20)
                output.seek(0)
                events = [json.loads(line) for line in output.read().splitlines()]
                self.assertTrue(events[-1]['data']['unknown_consequences'], events)
                self.assertEqual(events[-1]['data']['code'], 'privileged_lifecycle_unknown')
                self.assertFalse((self.home / self.paths[1]).exists())
            finally:
                if process.poll() is None:
                    process.kill(); process.wait()
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'privileged_lifecycle_unknown')
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_graceful_stop_finishes_owned_step_and_fresh_retry(self):
        self.remove_linked(1)
        selected = self.selection([0, 1])
        self.environment['TEST_GIT_MODE'] = 'delay'
        plan = self.prepare(selection=selected)
        request = dict(protocol_version=1, operation_id='stop-worktree', operation='restore_execute',
                       parameters=dict(path=str(self.archive), disabled_groups=[], include_secure=False,
                                       selection=selected, expected_prepared_plan_id=plan['prepared_plan_id']))
        read_fd, write_fd = os.pipe()
        try:
            with tempfile_output() as output:
                process = subprocess.Popen(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                    cwd=self.project, env=dict(self.environment, MACSEED_GRACEFUL_FD=str(read_fd)),
                    pass_fds=(read_fd,), stdin=subprocess.PIPE, stdout=output, stderr=subprocess.DEVNULL)
                try:
                    process.stdin.write(json.dumps(request).encode()); process.stdin.close()
                    deadline = time.monotonic() + 180
                    while not (self.root / 'mutations').exists() and process.poll() is None and time.monotonic() < deadline:
                        time.sleep(.05)
                    self.assertTrue((self.root / 'mutations').exists())
                    os.write(write_fd, b'S')
                    process.wait(timeout=90)
                    output.seek(0)
                    events = [json.loads(line) for line in output.read().splitlines()]
                    self.assertFalse(events[-1]['data']['unknown_consequences'], events)
                    self.assertEqual(events[-1]['data']['code'], 'cancelled', events)
                    self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['add_worktree'])
                finally:
                    if process.poll() is None:
                        process.kill(); process.wait()
        finally:
            os.close(read_fd); os.close(write_fd)
        self.environment.pop('TEST_GIT_MODE')
        self.restore(selection=selected)


def tempfile_output():
    import tempfile
    return tempfile.TemporaryFile()


if __name__ == '__main__':
    unittest.main()
