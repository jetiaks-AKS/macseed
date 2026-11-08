#!/usr/bin/env python3
"""Native Git mutations only in disposable HOME/local remote fixtures."""
import importlib.util
import copy
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import signal
import sys
import time
import unittest
from unittest import mock

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
    if os.environ.get('TEST_EXPECT_SSH_CONFIG'):
        assert os.path.isfile(os.path.join(os.environ['HOME'], '.ssh/config'))
        assert 'StrictHostKeyChecking=yes' in os.environ['GIT_SSH_COMMAND']
        assert 'BatchMode=yes' in os.environ['GIT_SSH_COMMAND']
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

    def ssh_clone(self, *, selected=False, local=False, references=(), remote='git@fixture-alias:team/repo.git', version=2):
        self.paths, self.branches, self.parents = self.paths[:1], ['main'], [0]
        self.configure()
        if (self.home / 'Projects').exists():
            shutil.rmtree(self.home / 'Projects')
        repositories = self.stage / self.contract.REPOSITORIES
        repositories.write_text(repositories.read_text().replace('https://example.invalid/team/repo.git', remote))
        raw = ('Host fixture-alias\n    HostName example.invalid\n    User git\n' + ''.join(
            '    IdentityFile ' + value + '\n' for value in references)).encode()
        if local:
            directory = self.home / '.ssh'; directory.mkdir(mode=0o700, exist_ok=True)
            target = directory / 'config'; target.write_bytes(raw); target.chmod(0o600)
        if selected:
            blueprint = self.stage / 'blueprint.conf'
            blueprint.write_text(blueprint.read_text().replace('ssh-configuration="false"', 'ssh-configuration="true"'))
            fixture.bundle.write_file(self.stage / 'generated/ssh/config.snapshot',
                f'# toolkit-ssh-snapshot: {version}\n# status: ready\n# excluded-profiles: 0\n\n'.encode() + raw)
        self.archive.unlink(); self.pack()

    def test_ssh_selected_alias_publication_before_clone(self):
        self.ssh_clone(selected=True)
        self.environment['TEST_EXPECT_SSH_CONFIG'] = 'true'
        plan = self.prepare()
        self.assertEqual(self.git_rows(plan)[0]['reason'], 'git_ssh_restore_pending')
        self.assertFalse((self.root / 'mutations').exists())
        self.assertFalse((self.home / '.ssh').exists())
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['clone'])
        repeated = self.git_rows(self.prepare())[0]
        self.assertEqual(repeated['disposition'], 'satisfied')
        self.assertNotIn('git_ssh', repeated['reason'] or '')

    def test_ssh_v1_selected_alias_and_uri(self):
        self.ssh_clone(selected=True, remote='ssh://git@fixture-alias/team/repo.git', version=1)
        self.environment['TEST_EXPECT_SSH_CONFIG'] = 'true'
        self.assertEqual(self.git_rows(self.prepare())[0]['reason'], 'git_ssh_restore_pending')
        self.restore()

    def test_ssh_local_key_and_stale_identity(self):
        self.ssh_clone(local=True, references=['~/.ssh/id_fixture'])
        key = self.home / '.ssh/id_fixture'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        plan = self.prepare()
        self.assertEqual(self.git_rows(plan)[0]['reason'], 'git_ssh_local_ready')
        key.write_bytes(key.read_bytes() + b'\n')
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])
        self.assertFalse((self.root / 'mutations').exists())

    def test_ssh_local_configuration_clone_and_stale_config(self):
        self.ssh_clone(local=True)
        plan = self.prepare()
        self.assertEqual(self.git_rows(plan)[0]['reason'], 'git_ssh_local_ready')
        target = self.home / '.ssh/config'
        target.write_bytes(target.read_bytes() + b'# changed\n')
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.restore()

    def test_ssh_missing_required_key_and_independent_https(self):
        self.paths, self.branches, self.parents = self.paths[:2], ['main', 'main'], [0, 1]
        self.configure(folders=['Projects'])
        shutil.rmtree(self.home / 'Projects')
        repositories = self.stage / self.contract.REPOSITORIES
        repositories.write_text(repositories.read_text().replace('https://example.invalid/team/repo.git',
            'git@fixture-alias:team/repo.git', 1))
        directory = self.home / '.ssh'; directory.mkdir(mode=0o700)
        (directory / 'config').write_text('Host fixture-alias\n    HostName example.invalid\n    IdentityFile ~/.ssh/missing\n')
        (directory / 'config').chmod(0o600)
        self.archive.unlink(); self.pack()
        plan = self.prepare(); rows = {row['checkout_id']: row for row in self.git_rows(plan)}
        self.assertEqual(rows[self.ids[0]]['reason'], 'git_ssh_identity_unresolved')
        self.assertEqual(rows[self.ids[0]]['disposition'], 'blocked')
        self.assertEqual(rows[self.ids[1]]['disposition'], 'planned')
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 0, events)
        self.assertFalse((self.home / self.paths[0]).exists())
        self.assertTrue((self.home / self.paths[1] / '.git').exists())
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['clone'])
        self.assertNotEqual(events[-2]['data']['verification']['verdict'], 'selected_requirements_verified')

    def test_ssh_conflict_and_independent_https_with_unsupported_ssh(self):
        self.ssh_clone(selected=True, local=True)
        target = self.home / '.ssh/config'
        target.write_text(target.read_text().replace('example.invalid', 'different.invalid'))
        plan = self.prepare()
        self.assertEqual(self.git_rows(plan)[0]['reason'], 'git_ssh_configuration_conflict')
        self.assertFalse(plan['readiness']['ready'])
        # Existing topology admission allows HTTPS/SSH, not file/local remotes.
        # Do not widen it just because Clone Executor also supports local forms.
        self.ssh_clone(remote='https://example.invalid/team/repo.git')
        target.write_text('Match exec unsafe\n')
        self.assertIsNone(self.git_rows(self.prepare())[0]['reason'])
        self.restore()

    def test_ssh_private_import_binding_and_approved_destination(self):
        # Component fixture: authenticated evidence is simulated here; the secure
        # suite separately exercises the actual encrypted import/receipt bridge.
        sys.path.insert(0, str(fixture.ROOT / 'modules/ssh'))
        sys.path.insert(0, str(fixture.ROOT / 'modules/bootstrap/workspace'))
        import git_dependencies as dependency
        self.ssh_clone(local=True, references=['~/keys/id_fixture'])
        files = {str(p.relative_to(self.stage)): p.read_bytes() for p in self.stage.rglob('*') if p.is_file()}
        rows = [dict(domain='git-repositories', item_id='1', checkout_id=self.ids[0], action='clone',
                     disposition='planned', reason=None, dependency_ids=[])]
        evidence = dependency.assess(files, self.home, rows, pending_secure=True)
        rule = evidence['rules'][self.ids[0]]
        self.assertEqual(rule['reason'], dependency.PENDING)
        empty = dependency.assess(files, self.home, rows, pending_secure=True,
                                 destinations=dict(version=2, bundle_id='b' * 64, items=[]))
        self.assertEqual(empty['rules'][self.ids[0]]['reason'], dependency.MISSING)
        (self.home / 'keys').mkdir(mode=0o700)
        key = self.home / 'keys/id_fixture'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        receipt = dict(identity_id='a' * 64, name='id_fixture', target='identical',
                       pair_digest=[hashlib.sha256(p.read_bytes()).hexdigest() for p in (key, key.with_suffix('.pub'))])
        mapping = dict(version=2, bundle_id='b' * 64, items=[dict(identity_id='a' * 64, directory=str(key.parent), selected=True)])
        excluded = copy.deepcopy(evidence)
        excluded_mapping = copy.deepcopy(mapping); excluded_mapping['items'][0]['selected'] = False
        dependency.bind_imports(excluded, self.home, authenticated=[receipt], destinations=excluded_mapping)
        self.assertFalse(dependency.revalidate(excluded['rules'][self.ids[0]], self.home))
        dependency.bind_imports(evidence, self.home, authenticated=[receipt], destinations=mapping)
        self.assertTrue(dependency.revalidate(rule, self.home))
        self.assertFalse(dependency.revalidate(rule, self.home, '/dev/null'), 'The executor must use the bound configuration')
        key.chmod(0o644)
        self.assertFalse(dependency.revalidate(rule, self.home), 'Changed or unsafe key evidence cannot launch a clone')
        key.chmod(0o600)
        target = self.home / '.ssh/config'
        target.write_text(target.read_text().replace('~/keys/id_fixture', str(key)))
        unapproved = dependency.assess(files, self.home, rows)
        self.assertEqual(unapproved['rules'][self.ids[0]]['reason'], dependency.MISSING)
        approved = dependency.assess(files, self.home, rows, approved_paths=[str(key)])
        self.assertTrue(dependency.revalidate(approved['rules'][self.ids[0]], self.home))
        for remote in ('git@github.com:owner/repo.git', 'ssh://git@github.com/owner/repo.git'):
            self.assertEqual(dependency.host(remote), 'github.com')
        for remote in ('https://example.invalid/repo', 'file:///fixture/repo', '/fixture/repo'):
            self.assertIsNone(dependency.host(remote))
        self.assertEqual(dependency.host('git@Fixture-Alias:repo'), 'Fixture-Alias')
        self.assertRaises(ValueError, dependency.host, 'ssh://git:secret@example.invalid/repo')

    def test_ssh_shared_file_transition_and_dependency_ids(self):
        sys.path.insert(0, str(fixture.ROOT / 'modules/ssh'))
        sys.path.insert(0, str(fixture.ROOT / 'modules/bootstrap/workspace'))
        import git_dependencies as dependency
        from topology_preview import dependency_id
        self.ssh_clone(local=True)
        files = {str(p.relative_to(self.stage)): p.read_bytes() for p in self.stage.rglob('*') if p.is_file()}
        files['blueprint.conf'] = files['blueprint.conf'].replace(b'ssh-configuration="false"', b'ssh-configuration="true"')
        additional = [('hostname', 'other.invalid')]
        files['generated/ssh/config.snapshot'] = dependency.snapshot('additional', additional)
        rows = [dict(domain='git-repositories', item_id='1', checkout_id=self.ids[0], action='clone',
                     disposition='planned', reason=None, dependency_ids=[])]
        evidence = dependency.assess(files, self.home, rows)
        rule = evidence['rules'][self.ids[0]]
        self.assertEqual(rule['reason'], dependency.PENDING)
        with mock.patch.object(dependency, 'MAX_EVIDENCE', 0):
            limited = dependency.assess(files, self.home, rows)
        self.assertEqual(limited['rules'][self.ids[0]], dict(reason=dependency.UNSUPPORTED))
        with mock.patch.object(dependency, 'MAX_HOSTS', 1), \
                mock.patch.object(dependency, 'host', side_effect=['first', 'second']), \
                mock.patch.object(dependency, 'qualify', side_effect=ValueError('unsupported')) as qualification:
            dependency.assess(files, self.home, rows * 2)
        self.assertEqual(qualification.call_count, 1, 'Failed observations also consume the Host budget')
        with mock.patch('clone_execution.SSH_CONFIG_LIMIT', 1):
            oversized = dependency.assess(files, self.home, rows)
        self.assertEqual(oversized['rules'][self.ids[0]], dict(reason=dependency.UNSUPPORTED),
                         'Planned publication must also fit the existing Clone Executor limit')
        dependency.bind_imports(evidence, self.home)
        self.assertFalse(dependency.revalidate(rule, self.home))
        target = self.home / '.ssh/config'
        target.write_bytes(target.read_bytes() + dependency.config.payload({'additional': additional}))
        self.assertTrue(dependency.revalidate(rule, self.home), 'An authorized sibling Host merge must not invalidate this existing Host')
        noop = [dict(rows[0], action='none', disposition='satisfied')]
        self.assertFalse(dependency.assess(files, self.home, noop)['rules'])
        folder = dict(domain='workspace-folders', item_id='Projects/checkout/data', action='create_directory',
                      disposition='planned', reason=None, dependency_ids=[self.ids[0]])
        workspace = dict(domain='vscode-workspaces', item_id='workspace-fixture', action='create_workspace',
                         disposition='planned', reason=None,
                         dependency_ids=[dependency_id('workspace-folders', folder['item_id'])])
        projected = rows + [folder, workspace]
        dependency.project(projected, dict(rules={self.ids[0]: dict(reason=dependency.CONFLICT)}))
        self.assertTrue(all(row['disposition'] == 'blocked' for row in projected))
        # No explicit dependency and ordered unresolved references remain distinct.
        for references, expected in [(['none'], dependency.READY),
                                     (['~/.ssh/first', '~/.ssh/second'], dependency.MISSING)]:
            target.write_bytes(dependency.config.payload({'fixture-alias': [('hostname', 'example.invalid')]
                              + [('identityfile', value) for value in references]}))
            local_files = dict(files, **{'blueprint.conf': files['blueprint.conf'].replace(
                b'ssh-configuration="true"', b'ssh-configuration="false"')})
            assessed = dependency.assess(local_files, self.home, [dict(rows[0], action='clone', disposition='planned')])
            local_rule = assessed['rules'][self.ids[0]]
            self.assertEqual(local_rule['reason'], expected)
            self.assertEqual([row['reference'] for row in local_rule['references']], references)

    def descriptors(self, *, folder_only=False, count=1, folders=None, linked=False):
        self.configure(folders=folders or ['Projects/data'])
        sections, categories = fixture.bundle.parse_blueprint((self.stage / 'blueprint.conf').read_bytes())
        if folder_only:
            sections['git-repositories'] = []
            (self.stage / self.contract.TOPOLOGY).unlink()
            (self.stage / self.contract.REPOSITORIES).unlink()
        relationships = [dict(domain='workspace-folders', item_id=self.folders[0], subpath='', name='Data')]
        if not folder_only:
            relationships += [dict(domain='git-repositories', item_id=self.ids[2 if linked else 0], subpath='', name='Code')]
        self.descriptor_items = [dict(item_id=self.contract.identity('workspace', f'Projects/view-{i}.code-workspace'),
            path=f'~/Projects/view-{i}.code-workspace', folders=relationships) for i in range(count)]
        sections['vscode-workspaces'] = [row['item_id'] for row in self.descriptor_items]
        raw = '[categories]\n' + ''.join(f'{key}="{str(value).lower()}"\n' for key, value in sorted(categories.items()))
        raw += ''.join('\n[' + domain + ']\n' + ''.join(item + '\n' for item in values)
                       for domain, values in sections.items() if domain != 'categories')
        (self.stage / 'blueprint.conf').write_bytes(raw.encode())
        fixture.bundle.write_file(self.stage / self.contract.VSCODE,
                                  json.dumps(dict(contract=1, items=self.descriptor_items)).encode())
        self.archive.unlink()
        self.pack()
        return self.home / 'Projects/view-0.code-workspace'

    def test_descriptor_folder_only_create_verify_and_repeat(self):
        path = self.descriptors(folder_only=True)
        (self.root / 'bin/git').write_text('#!/bin/bash\nprintf git >> "$TEST_MUTATIONS"\nexit 99\n')
        result = self.restore()
        self.assertEqual(json.loads(path.read_bytes()), {'folders': [{'path': 'data', 'name': 'Data'}]})
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        operations = result['verification']['details']['operation_records']
        self.assertTrue(any(row['domain'] == 'vscode-workspaces' and row['outcome'] == 'success' for row in operations))
        before = path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_ino
        self.restore()
        self.assertEqual(before, (path.read_bytes(), path.stat().st_mtime_ns, path.stat().st_ino))
        self.assertFalse((self.root / 'mutations').exists())

    def test_descriptor_after_clone_and_linked_checkout(self):
        self.paths, self.branches, self.parents = [self.paths[0], self.paths[2]], ['main', ''], [0, 0]
        path = self.descriptors()
        # The descriptor also depends on the selected detached linked checkout.
        value = json.loads((self.stage / self.contract.VSCODE).read_bytes())
        value['items'][0]['folders'][1]['item_id'] = self.ids[1]
        (self.stage / self.contract.VSCODE).write_bytes(json.dumps(value).encode())
        self.archive.unlink(); self.pack()
        shutil.rmtree(self.home / 'Projects')
        plan = self.prepare()
        self.assertEqual(next(row for row in plan['plan'] if row['domain'] == 'vscode-workspaces')['reason'], 'workspace_dependency_pending')
        self.restore()
        self.assertEqual(json.loads(path.read_bytes())['folders'][1], {'path': 'other/demo', 'name': 'Code'})
        self.assertEqual((self.root / 'mutations').read_text().splitlines(), ['clone', 'add_worktree'])

    def test_descriptor_partial_selection_and_missing_dependencies(self):
        path = self.descriptors(count=2, linked=True)
        selection = self.selection([0, 2], self.folders)
        selection['items']['vscode-workspaces'] = [self.descriptor_items[0]['item_id']]
        self.restore(selection=selection)
        self.assertTrue(path.is_file())
        self.assertFalse(path.with_name('view-1.code-workspace').exists())
        for domain in ('workspace-folders', 'git-repositories'):
            incomplete = json.loads(json.dumps(selection))
            incomplete['items'].pop(domain)
            result, events = self.invoke(selection=incomplete)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events[-1]['data']['code'], 'workspace_dependency_missing')
        incomplete = self.selection([2], self.folders)
        incomplete['items']['vscode-workspaces'] = selection['items']['vscode-workspaces']
        result, events = self.invoke(selection=incomplete)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'workspace_dependency_missing')

    def test_descriptor_matching_jsonc_and_conflict_preserve_bytes(self):
        path = self.descriptors(folder_only=True)
        (self.home / 'Projects/data').mkdir()
        path.write_text('{// retained settings\n"folders":[{"path":"data","name":"Data",}],"settings":{"private":"retained"}}')
        before = path.read_bytes(), path.stat().st_mtime_ns
        self.restore()
        self.assertEqual(before, (path.read_bytes(), path.stat().st_mtime_ns))
        path.write_text('{"folders":[{"path":"data","name":"Different"}],"tasks":{"secret":"retained"}}')
        before = path.read_bytes()
        plan = self.prepare()
        row = next(row for row in plan['plan'] if row['domain'] == 'vscode-workspaces')
        self.assertEqual((row['disposition'], row['reason']), ('conflict', 'workspace_descriptor_conflict'))
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 0, events)
        data = next(event['data'] for event in events if event['type'] == 'result')
        self.assertNotEqual(data['verification']['verdict'], 'selected_requirements_verified')
        self.assertEqual(path.read_bytes(), before)
        public = json.dumps(events)
        for private in (str(self.home), 'retained', 'Different', 'secret'):
            self.assertNotIn(private, public)

    def test_descriptor_symlink_escape_and_observation_error(self):
        path = self.descriptors(folder_only=True)
        (self.home / 'Projects/data').mkdir()
        outside = self.root / 'outside'
        outside.write_text('preserved')
        path.symlink_to(outside)
        row = next(row for row in self.prepare()['plan'] if row['domain'] == 'vscode-workspaces')
        self.assertEqual(row['disposition'], 'conflict')
        path.unlink()
        path.write_text('{"folders":[{"path":"../../outside"}]}')
        row = next(row for row in self.prepare()['plan'] if row['domain'] == 'vscode-workspaces')
        self.assertNotIn(row['disposition'], ('planned', 'satisfied'))
        path.write_text('{invalid json')
        row = next(row for row in self.prepare()['plan'] if row['domain'] == 'vscode-workspaces')
        self.assertEqual(row['disposition'], 'unknown')
        path.unlink()
        (self.home / 'Projects/data').rmdir()
        (self.home / 'Projects/data').symlink_to(self.root, target_is_directory=True)
        row = next(row for row in self.prepare()['plan'] if row['domain'] == 'vscode-workspaces')
        self.assertEqual(row['disposition'], 'conflict')
        self.assertFalse(path.exists())
        # A symlink in the descriptor parent cannot redirect creation either.
        shutil.rmtree(self.home / 'Projects')
        (self.home / 'Projects').symlink_to(self.root, target_is_directory=True)
        row = next(row for row in self.prepare()['plan'] if row['domain'] == 'vscode-workspaces')
        self.assertEqual(row['disposition'], 'conflict')
        self.assertFalse((self.root / path.name).exists())
        self.assertEqual(outside.read_text(), 'preserved')

    def test_descriptor_target_change_rejects_before_publication(self):
        path = self.descriptors(folder_only=True)
        plan = self.prepare()
        path.write_text('{"folders":[]}')
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])
        self.assertEqual(path.read_text(), '{"folders":[]}')

    def test_descriptor_tracked_by_parent_is_preserved_before_branch_switch(self):
        self.descriptors()
        path = self.base / 'tracked.code-workspace'
        path.write_text('{"folders":[{"path":"../data","name":"Data"},{"path":".","name":"Code"}]}')
        subprocess.run([self.git, '-C', str(self.base), 'add', '--', path.name],
                       env=self.environment, check=True, capture_output=True)
        subprocess.run([self.git, '-C', str(self.base), '-c', 'user.name=Fixture',
                        '-c', 'user.email=fixture@example.invalid', '-c', 'core.hooksPath=/dev/null',
                        '-c', 'commit.gpgsign=false', 'commit', '-m', 'descriptor'],
                       env=self.environment, check=True, capture_output=True)
        (self.base / '.git/refs/heads/next').write_text(self.oid + '\n')
        self.branches[0] = 'next'
        self.descriptors()
        value = json.loads((self.stage / self.contract.VSCODE).read_bytes())
        value['items'][0].update(path='~/Projects/base/tracked.code-workspace',
            item_id=self.contract.identity('workspace', 'Projects/base/tracked.code-workspace'))
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace(self.descriptor_items[0]['item_id'], value['items'][0]['item_id']))
        (self.stage / self.contract.VSCODE).write_bytes(json.dumps(value).encode())
        self.archive.unlink(); self.pack()
        before = path.read_bytes()
        plan = self.prepare()
        self.assertEqual(self.git_rows(plan)[0]['reason'], 'workspace_descriptor_conflict')
        result, events = self.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(path.read_bytes(), before)
        self.assertFalse((self.root / 'mutations').exists())

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
