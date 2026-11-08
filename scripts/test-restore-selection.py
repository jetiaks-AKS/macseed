#!/usr/bin/env python3
"""Focused additive V1 selection tests; production preparation, no real user state."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'modules/bundle'))
sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
import bundle
import restore_selection as selection_api
spec = importlib.util.spec_from_file_location('restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)
sys.path.insert(0, str(ROOT / 'modules/ssh'))
import identity_dependencies as dependencies
import restore_resolution as resolution


class IdentityDependencyTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='ssh-dependencies-', dir='/private/tmp')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.key = self.root / 'id_fixture'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True)

    def raw(self, hosts, version=2):
        return (f'# toolkit-ssh-snapshot: {version}\n# status: ready\n# excluded-profiles: 0\n\n' + ''.join(
            f'Host {host}\n    HostName {host}.invalid\n' + ''.join(f'    IdentityFile {ref}\n' for ref in refs)
            for host, refs in hosts)).encode()

    def install(self, name='id_fixture', directory='.ssh', source=None):
        target = self.home / directory / name
        target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        for suffix in ('', '.pub'):
            shutil.copy2(str(source or self.key) + suffix, str(target) + suffix)
        return target

    def state(self):
        return [(str(p.relative_to(self.home)), p.lstat().st_mode, p.lstat().st_ino,
                 p.lstat().st_mtime_ns, p.read_bytes() if p.is_file() and not p.is_symlink() else None)
                for p in [self.home, *sorted(self.home.rglob('*'))]]

    def assess(self, hosts, **kwargs):
        before = self.state()
        rows = dependencies.assess(self.raw(hosts), str(self.home), **kwargs)
        self.assertEqual(self.state(), before)
        return rows

    def test_order_shared_local_and_missing(self):
        self.install()
        hosts = [('first', ['~/.ssh/absent', '~/.ssh/id_fixture']), ('second', ['~/.ssh/id_fixture'])]
        with patch.object(dependencies, 'qualify', wraps=dependencies.qualify) as qualify:
            rows = self.assess(hosts)
        self.assertEqual(qualify.call_count, 1)
        self.assertEqual([r['reference'] for r in rows[0]['references']], hosts[0][1])
        self.assertEqual([r['status'] for r in rows[0]['references']], ['missing', 'local_satisfied'])
        self.assertEqual(rows[1]['references'][0]['status'], 'local_satisfied')
        self.assertEqual(dependencies.projection(rows), dict(version=1, findings=['local_satisfied', 'missing']))

    def test_none_implicit_legacy_and_absolute_never_read(self):
        with patch.object(dependencies, 'observe', side_effect=AssertionError('unexpected path inspection')):
            rows = self.assess([('none', ['none']), ('implicit', []), ('old', ['/old-home/key'])])
            legacy = dependencies.assess(self.raw([('legacy', [])], version=1), str(self.home))
        self.assertEqual([r['references'][0]['status'] for r in rows],
                         ['no_file_dependency', 'no_file_dependency', 'unresolved'])
        self.assertEqual(legacy[0]['references'][0]['status'], 'no_file_dependency')
        with self.assertRaises(bundle.Invalid):
            bundle.ssh_snapshot(self.raw([('bad', ['~/.ssh/key'])], version=1))

    def test_missing_nested_and_unsafe_paths(self):
        rows = self.assess([('missing', ['~/nested/deep/key'])])
        self.assertEqual(rows[0]['references'][0]['status'], 'missing')
        target = self.install()
        target.chmod(0o644)
        self.assertEqual(self.assess([('unsafe', ['~/.ssh/id_fixture'])])[0]['references'][0]['status'], 'unsafe_target')
        target.chmod(0o600)
        target.unlink()
        target.symlink_to(self.key)
        self.assertEqual(self.assess([('unsafe', ['~/.ssh/id_fixture'])])[0]['references'][0]['status'], 'unsafe_target')
        target.unlink()
        os.mkfifo(target, 0o600)
        # FIFO bytes must never be read, even by the fixture snapshot helper.
        rows = dependencies.assess(self.raw([('unsafe', ['~/.ssh/id_fixture'])]), str(self.home))
        self.assertEqual(rows[0]['references'][0]['status'], 'unsafe_target')
        target.unlink()
        os.link(self.key, target)
        self.assertEqual(self.assess([('unsafe', ['~/.ssh/id_fixture'])])[0]['references'][0]['status'], 'unsafe_target')

    def test_partial_case_parent_and_public_mismatch(self):
        target = self.install()
        public = Path(str(target) + '.pub')
        public.unlink()
        self.assertEqual(self.assess([('partial', ['~/.ssh/id_fixture'])])[0]['references'][0]['status'], 'unsafe_target')
        target.unlink()
        target.with_name('ID_FIXTURE').write_bytes(b'conflicting name')
        self.assertEqual(self.assess([('alias', ['~/.ssh/id_fixture'])])[0]['references'][0]['status'], 'unsafe_target')
        target.with_name('ID_FIXTURE').unlink()
        self.install()
        target.parent.chmod(0o777)
        self.assertEqual(self.assess([('parent', ['~/.ssh/id_fixture'])])[0]['references'][0]['status'], 'unsafe_target')
        target.parent.chmod(0o700)
        other = self.root / 'other'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(other)], check=True)
        public.write_bytes(Path(str(other) + '.pub').read_bytes())
        self.assertEqual(self.assess([('pair', ['~/.ssh/id_fixture'])])[0]['references'][0]['reason'], 'pair_mismatch')

    def test_locked_and_invalid_files_are_not_satisfied(self):
        locked = self.root / 'locked'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', 'fixture-only', '-f', str(locked)], check=True)
        target = self.install(source=locked)
        rows = self.assess([('locked', ['~/.ssh/id_fixture'])])
        self.assertEqual(rows[0]['references'][0]['status'], 'unresolved')
        target.write_bytes(b'not a key')
        self.assertEqual(self.assess([('invalid', ['~/.ssh/id_fixture'])])[0]['references'][0]['status'], 'unresolved')

    def test_authenticated_destinations_exclusions_and_ambiguity(self):
        authenticated = [dict(identity_id='a' * 64, name='id_fixture', target='create', pair_digest=['b' * 64] * 2)]
        mapping = dict(version=2, bundle_id='c' * 64, items=[dict(identity_id='a' * 64, selected=True, directory=None)])
        hosts = [('selected', ['~/.ssh/id_fixture']), ('custom', ['~/keys/id_fixture'])]
        rows = self.assess(hosts, authenticated=authenticated, destinations=mapping)
        self.assertEqual([r['references'][0]['status'] for r in rows], ['selected_expected', 'missing'])
        mapping['items'][0]['directory'] = str(self.home / 'keys')
        rows = self.assess(hosts, authenticated=authenticated, destinations=mapping)
        self.assertEqual([r['references'][0]['status'] for r in rows], ['missing', 'selected_expected'])
        mapping['items'][0]['selected'] = False
        self.assertEqual(self.assess(hosts, authenticated=authenticated, destinations=mapping)[1]['references'][0]['status'], 'missing')
        mapping['version'] = 1
        del mapping['items'][0]['selected']
        self.assertEqual(self.assess(hosts, authenticated=authenticated, destinations=mapping)[1]['references'][0]['status'], 'selected_expected')
        duplicate = dict(authenticated[0], identity_id='d' * 64)
        self.assertEqual(self.assess(hosts, authenticated=authenticated + [duplicate])[0]['references'][0]['reason'], 'ambiguous_destination')
        self.install()
        authenticated[0]['target'] = 'identical'
        self.assertEqual(self.assess(hosts, authenticated=authenticated)[0]['references'][0]['reason'], 'observation_changed')
        authenticated[0]['pair_digest'] = [dependencies.hashlib.sha256(Path(str(self.key) + suffix).read_bytes()).hexdigest()
                                            for suffix in ('', '.pub')]
        self.assertEqual(self.assess(hosts, authenticated=authenticated)[0]['references'][0]['status'], 'local_satisfied')
        (self.home / '.ssh/id_fixture').chmod(0o644)
        self.assertEqual(self.assess(hosts, authenticated=authenticated)[0]['references'][0]['status'], 'unsafe_target')

    def test_changed_observation_and_bound_budget(self):
        self.install()
        original = dependencies.observe
        calls = []
        def changed(path):
            pair, binding = original(path)
            calls.append(path)
            return pair, binding if len(calls) == 1 else 'changed'
        with patch.object(dependencies, 'observe', side_effect=changed):
            rows = self.assess([('raced', ['~/.ssh/id_fixture'])])
        self.assertEqual(rows[0]['references'][0]['reason'], 'observation_changed')
        with patch.object(dependencies, 'MAX_LOCATIONS', 1):
            rows = self.assess([('bounded', ['~/absent', '~/uninspected'])])
        self.assertEqual(rows[0]['references'][1]['reason'], 'observation_limit')
        with patch.object(dependencies, 'observe', side_effect=[original(self.home / '.ssh/id_fixture'), TimeoutError()]):
            rows = self.assess([('bounded', ['~/.ssh/id_fixture'])])
        self.assertEqual(rows[0]['references'][0]['status'], 'unresolved')

    def test_private_derivation_transport_and_cleanup(self):
        target = self.install()
        before = set(Path('/private/tmp').glob('macseed-dependency-*'))
        with patch.object(dependencies.subprocess, 'run', wraps=subprocess.run) as run:
            self.assertEqual(self.assess([('private', ['~/.ssh/id_fixture'])])[0]['references'][0]['status'], 'local_satisfied')
        arguments, options = run.call_args
        for sensitive in (str(target), str(self.home), self.key.read_text(), Path(str(self.key) + '.pub').read_text()):
            self.assertNotIn(sensitive, repr((arguments, options)))
        self.assertEqual(options['stdin'], subprocess.DEVNULL)
        self.assertEqual(options['stderr'], subprocess.DEVNULL)
        self.assertEqual(options['env']['SSH_ASKPASS_REQUIRE'], 'never')
        self.assertEqual(set(Path('/private/tmp').glob('macseed-dependency-*')), before)


class IdentityResolutionTests(unittest.TestCase):
    setUp = IdentityDependencyTests.setUp
    raw = IdentityDependencyTests.raw
    install = IdentityDependencyTests.install
    state = IdentityDependencyTests.state

    def execution_context(self, raw, plan, **kwargs):
        directory = self.root / ('context-' + str(len(list(self.root.glob('context-*')))))
        directory.mkdir(mode=0o700)
        resolution.write_context(directory, raw, resolution.execution_context(raw, plan, **kwargs))
        with patch.dict(os.environ, MACSEED_APPLICATION_EXECUTION='true', MACSEED_ITEM_STATE_DIR=str(directory)):
            return resolution.context(plan['raw'])

    def approval(self, raw, reference, identity=None):
        row = resolution.references(raw)[0]
        return dict(version=1, bundle_id='a' * 64, items=[dict(host_id=row['host_id'], index=row['index'],
                    original=row['reference'], reference=reference, identity_id=identity, approved=True)])

    def inspect(self, raw, **kwargs):
        before = self.state()
        plan = resolution.inspect(raw, str(self.home), bundle_id='a' * 64, **kwargs)
        self.assertEqual(before, self.state(), 'assessment cannot mutate HOME')
        return plan

    def test_v2_local_order_shared_create_verify_noop(self):
        self.install(); self.install('second')
        raw = self.raw([('one', ['~/.ssh/second', '~/.ssh/id_fixture']), ('two', ['~/.ssh/id_fixture']), ('none', ['none'])])
        plan = self.inspect(raw)
        self.assertTrue(plan['qualified']); self.assertEqual(plan['action'], 'create')
        context = self.execution_context(raw, plan, bundle_id='a' * 64)
        self.assertTrue(resolution.apply(raw, str(self.home), context))
        self.assertEqual((self.home / '.ssh/config').read_bytes(), resolution.config.payload(resolution.config.snapshot(raw)[3]))
        self.assertTrue(resolution.bound_plan(raw, str(self.home), context, verification=True)['qualified'])
        repeat = self.inspect(raw)
        self.assertEqual(repeat['action'], 'noop')
        self.assertFalse(resolution.apply(raw, str(self.home)))

    def test_v2_none_and_no_file_creation(self):
        raw = self.raw([('implicit', []), ('none', ['none'])])
        self.assertTrue(self.inspect(raw)['qualified'])
        self.assertTrue(resolution.apply(raw, str(self.home)))
        self.assertEqual((self.home / '.ssh/config').stat().st_mode & 0o777, 0o600)

    def test_execution_context_large_snapshot_and_protected_original(self):
        raw = self.raw([(f'host-{index:04d}-' + 'x' * 65, []) for index in range(450)])
        self.assertGreater(len(raw), 65536)
        plan = self.inspect(raw)
        context = self.execution_context(raw, plan)
        directory = Path(context['_directory'])
        original = directory / resolution.ORIGINAL
        control = directory / resolution.EVIDENCE
        self.assertLess(control.stat().st_size, 65536)
        self.assertEqual(original.read_bytes(), raw)
        self.assertEqual(original.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('host-0000', control.read_text())
        with self.assertRaises(FileExistsError):
            resolution.write_context(directory, raw, resolution.execution_context(raw, plan))
        self.assertTrue(resolution.bound_plan(raw, str(self.home), context)['qualified'])
        # Same bytes at a new inode must not bypass the private freshness binding.
        replacement = directory / 'replacement'
        replacement.write_bytes(raw); replacement.chmod(0o600); replacement.replace(original)
        with self.assertRaises(resolution.merge.Refused):
            resolution.bound_plan(raw, str(self.home), context)
        context = self.execution_context(raw, plan)
        original = Path(context['_directory']) / resolution.ORIGINAL
        original.write_bytes(raw.replace(b'host-0000', b'host-9999'))
        with self.assertRaises(resolution.merge.Refused):
            resolution.apply(raw, str(self.home), context)
        self.assertFalse((self.home / '.ssh').exists())
        context = self.execution_context(raw, plan)
        original = Path(context['_directory']) / resolution.ORIGINAL
        original.chmod(0o644)
        with self.assertRaises((OSError, resolution.config.Unsafe)):
            resolution.bound_plan(raw, str(self.home), context)
        original.unlink(); original.symlink_to(directory / resolution.ORIGINAL)
        with self.assertRaises((OSError, resolution.config.Invalid)):
            resolution.bound_plan(raw, str(self.home), context)


    def test_explicit_local_approval_and_original_conflict(self):
        target = self.key # Explicit safe absolute destination outside receiving HOME.
        raw = self.raw([('one', ['/old-home/key'])])
        self.assertFalse(self.inspect(raw)['qualified'])
        approval = self.approval(raw, str(target))
        plan = self.inspect(raw, approvals=approval)
        self.assertTrue(plan['qualified'])
        context = self.execution_context(raw, plan, approvals=approval, bundle_id='a' * 64)
        self.assertTrue(resolution.apply(plan['raw'], str(self.home), context))
        with self.assertRaises(resolution.merge.Refused):
            self.inspect(raw, approvals=approval) # Corrected existing Host cannot conceal original conflict.

    def test_inline_review_qualifies_proposals_without_granting_consent(self):
        self.install()
        raw = self.raw([('one', ['/old/key', '~/.ssh/absent']), ('healthy', ['~/.ssh/id_fixture']), ('none', ['none']), ('implicit', [])])
        before = self.state()
        rows = resolution.review_references(raw, str(self.home))
        self.assertEqual([row['reference'] for row in rows], ['/old/key', '~/.ssh/absent'])
        self.assertTrue(all(row['proposal'] is None for row in rows))
        proposal = self.approval(raw, '~/.ssh/id_fixture'); proposal['items'][0]['approved'] = False
        rows = resolution.review_references(raw, str(self.home), proposals=proposal, bundle_id='a'*64)
        self.assertEqual(rows[0]['proposal'], dict(reference='~/.ssh/id_fixture', identity_id=None, status='local_satisfied'))
        self.assertIsNone(rows[1]['proposal'])
        with self.assertRaises(resolution.SecureError): self.inspect(raw, approvals=proposal)
        proposal['items'][0]['reference'] = '~/.ssh/missing-other'
        rows = resolution.review_references(raw, str(self.home), proposals=proposal, bundle_id='a'*64)
        self.assertIsNone(rows[0]['proposal'])
        proposal['bundle_id'] = 'b'*64
        with self.assertRaises(resolution.SecureError):
            resolution.review_references(raw, str(self.home), proposals=proposal, bundle_id='a'*64)
        self.assertEqual(self.state(), before)

    def test_empty_review_shared_keys_and_actionable_limit(self):
        self.install()
        raw = self.raw([(f'host-{i}', ['~/.ssh/id_fixture']) for i in range(40)])
        before = self.state()
        self.assertEqual(resolution.review_references(raw, str(self.home)), [])
        self.assertEqual(self.state(), before)
        missing = self.raw([(f'host-{i}', ['~/.ssh/missing']) for i in range(33)])
        with self.assertRaises(resolution.SecureError) as caught:
            resolution.review_references(missing, str(self.home))
        self.assertEqual(caught.exception.code, 'ssh_review_unavailable')

    def test_merge_preserves_unrelated_profiles_and_partial_source(self):
        self.install()
        target = self.home / '.ssh/config'
        before = b'# retained comment\nHost untouched\n    HostName unrelated.invalid\n'
        target.write_bytes(before); target.chmod(0o600)
        raw = self.raw([('new', ['~/.ssh/id_fixture'])])
        self.assertEqual(self.inspect(raw)['action'], 'merge')
        partial = raw.replace(b'status: ready', b'status: partial').replace(b'excluded-profiles: 0', b'excluded-profiles: 1')
        with self.assertRaises(resolution.merge.Refused): self.inspect(partial)
        self.assertTrue(resolution.apply(raw, str(self.home)))
        self.assertTrue(target.read_bytes().startswith(before))
        saved = list(target.parent.glob('.macseed-ssh-predecessor-*'))
        self.assertEqual(len(saved), 1)
        self.assertEqual((saved[0] / 'observed').read_bytes(), before)

    def test_stale_key_target_approval_and_bundle(self):
        key = self.install()
        raw = self.raw([('one', ['~/.ssh/id_fixture'])])
        plan = self.inspect(raw)
        context = self.execution_context(raw, plan, bundle_id='a' * 64)
        key.chmod(0o644)
        with self.assertRaises(resolution.merge.Refused): resolution.apply(raw, str(self.home), context)
        key.chmod(0o600)
        target = self.home / '.ssh/config'; target.write_bytes(b'# appeared\n'); target.chmod(0o600)
        with self.assertRaises(resolution.merge.Refused): resolution.apply(raw, str(self.home), context)
        target.unlink()
        approval = self.approval(raw, '~/keys/other'); approval['bundle_id'] = 'b' * 64
        with self.assertRaises(resolution.SecureError): self.inspect(raw, approvals=approval)
        self.assertFalse(target.exists())

    def test_unsafe_case_symlink_and_existing_conflicting_host(self):
        self.install()
        raw = self.raw([('one', ['~/.ssh/id_fixture'])])
        target = self.home / '.ssh/config'
        collision = target.with_name('Config'); collision.write_bytes(b'preserve'); collision.chmod(0o600)
        with self.assertRaises(resolution.merge.Refused): self.inspect(raw)
        collision.unlink()
        target.symlink_to(self.key)
        with self.assertRaises((OSError, resolution.merge.Refused)): self.inspect(raw)
        target.unlink()
        for source in (b'Host one\n HostName different.invalid\n', b'Host *\n User other\n', b'Include extra\n', b'Match all\n User other\n'):
            target.write_bytes(source); target.chmod(0o600)
            with self.assertRaises(resolution.merge.Refused): self.inspect(raw)
            self.assertEqual(target.read_bytes(), source)

    def test_expected_identity_requires_selected_destination_and_verified_import(self):
        import hashlib
        from restore_destinations import digest
        raw = self.raw([('one', ['/old/key'])])
        pair = [self.key.read_bytes(), Path(str(self.key) + '.pub').read_bytes()]
        hashes = [hashlib.sha256(value).hexdigest() for value in pair]
        identity = dict(name='id_fixture', key_type='ssh-ed25519', fingerprint='SHA256:' + 'x'*43, pair_digest=hashes, target='create')
        identity['identity_id'] = digest([identity['name'], identity['key_type'], identity['fingerprint'], *hashes])
        approval = self.approval(raw, '~/keys/id_fixture', identity['identity_id'])
        directory = self.home / 'keys'; directory.mkdir(mode=0o700)
        mapping = dict(version=2, bundle_id='a'*64, items=[dict(identity_id=identity['identity_id'], directory=str(directory), selected=True)])
        pending = self.inspect(raw, approvals=approval, destinations=mapping, pending_secure=True)
        self.assertTrue(pending['pending']); self.assertFalse(pending['qualified'])
        expected = self.inspect(raw, approvals=approval, destinations=mapping, authenticated=[identity])
        self.assertTrue(expected['expected']); self.assertFalse(expected['qualified'])
        mapping['items'][0]['selected'] = False
        with self.assertRaises(resolution.SecureError): self.inspect(raw, approvals=approval, destinations=mapping, authenticated=[identity])


    def test_preview_context_cannot_apply_and_approval_cannot_be_implicit(self):
        self.install()
        raw = self.raw([('one', ['~/.ssh/id_fixture'])])
        plan = self.inspect(raw)
        context = self.execution_context(raw, plan, preview=True)
        with self.assertRaises(resolution.merge.Refused): resolution.apply(raw, str(self.home), context)
        approval = self.approval(raw, '~/keys/other'); approval['items'][0]['approved'] = False
        with self.assertRaises(resolution.SecureError): self.inspect(raw, approvals=approval)
        self.assertFalse((self.home / '.ssh/config').exists())

    def test_uncertain_creation_retains_recovery_and_blocks_reentry(self):
        raw = self.raw([('one', ['none'])])
        with patch.object(resolution.merge, 'rename', side_effect=OSError('fixture publication fault')):
            with self.assertRaises(resolution.merge.PublicationUncertain) as caught:
                resolution.apply(raw, str(self.home))
        self.assertTrue(caught.exception.changed)
        self.assertFalse((self.home / '.ssh/config').exists())
        pending = list((self.home / '.ssh').glob('.macseed-ssh-pending-*'))
        self.assertEqual(len(pending), 1); self.assertTrue((pending[0] / 'new').is_file())
        with self.assertRaises(resolution.merge.Refused): self.inspect(raw)

    def test_dependency_change_at_merge_preserves_pending_predecessor(self):
        key = self.install()
        target = self.home / '.ssh/config'; before = b'Host untouched\n HostName untouched.invalid\n'
        target.write_bytes(before); target.chmod(0o600)
        raw = self.raw([('one', ['~/.ssh/id_fixture'])])
        rename = resolution.merge.rename
        def change(*args):
            rename(*args)
            if args[-1] == 2: # Darwin RENAME_SWAP completed before the observation changes.
                key.chmod(0o644)
        with patch.object(resolution.merge, 'rename', side_effect=change):
            with self.assertRaises(resolution.merge.PublicationUncertain): resolution.apply(raw, str(self.home))
        pending = list(target.parent.glob('.macseed-ssh-pending-*'))
        self.assertEqual(len(pending), 1)
        self.assertEqual((pending[0] / 'swap').read_bytes(), before)
        self.assertTrue(target.read_bytes().startswith(before))

    def test_check_dependency_qualification_remains_separate_from_config_conflict(self):
        self.install()
        raw = self.raw([('one', ['~/.ssh/id_fixture'])])
        target = self.home / '.ssh/config'; target.write_bytes(b'Host one\n HostName different.invalid\n'); target.chmod(0o600)
        before = self.state()
        self.assertTrue(resolution.bound_plan(raw, str(self.home), None, verification=True)['qualified'])
        self.assertEqual(before, self.state())
        self.assertEqual(resolution.config.assess(resolution.config.payload(resolution.config.snapshot(raw)[3]), str(self.home))[1], 'conflicting_profiles')



class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture.RestorePrepareTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.stage = self.fixture.stage

    def inspect(self):
        request = dict(protocol_version=1, operation_id='selection-inspect', operation='bundle_inspect', parameters=dict(path=str(self.fixture.archive)))
        result = subprocess.run(['bash', str(self.fixture.project / 'modules/core/application-interface/core.sh')],
                                input=json.dumps(request).encode(), env=self.fixture.environment, cwd=self.fixture.project, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        return json.loads(result.stdout.splitlines()[-2])['data']

    def prepare(self, selection=None):
        result, events = self.fixture.invoke(selection=selection)
        self.assertEqual(result.returncode, 0, events)
        return events[-2]['data']

    def ssh_fixture(self, *, version=1, partial=False, secure=False):
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('ssh-configuration="false"', 'ssh-configuration="true"')
                             .replace('Projects\n', ''))
        self.ssh_source = self.stage / 'generated/ssh/config.snapshot'
        self.ssh_payload = b'Host github\n    HostName github.invalid\n    User git\nHost production\n    HostName production.invalid\n'
        if version == 2:
            self.ssh_payload += b'    IdentityFile /old-home/deploy\n    IdentitiesOnly yes\n'
        bundle.write_file(self.ssh_source, (f'# toolkit-ssh-snapshot: {version}\n# status: {"partial" if partial else "ready"}\n'
                                         f'# excluded-profiles: {1 if partial else 0}\n\n').encode() + self.ssh_payload)
        self.fixture.pack(secure=secure)
        row = next(row for row in self.inspect()['restore_selection']['inventory'] if row['domain'] == 'ssh-configuration')
        self.assertEqual(row['selection_mode'], 'items')
        self.assertEqual([item['label'] for item in row['items']], ['github', 'production'])
        self.ssh_ids = [item['item_id'] for item in row['items']]
        return self.fixture.home / '.ssh/config'

    def ssh_selection(self, indexes=(0,)):
        return dict(categories=[], items={'ssh-configuration': sorted(self.ssh_ids[index] for index in indexes)})

    def test_ssh_dependency_prepare_binding_and_selection(self):
        target = self.ssh_fixture(version=2, secure=True)
        (self.fixture.root / 'bin/age').write_text(
            '#!/bin/bash\nif [[ "$*" == --version ]]; then echo v1.3.2; exit 0; fi\n'
            'echo age >> "$TEST_MUTATIONS"\nexit 99\n')
        self.ssh_source.write_bytes(self.ssh_source.read_bytes().replace(b'/old-home/deploy', b'~/.ssh/id_fixture'))
        self.fixture.archive.unlink()
        bundle.pack(self.stage, self.fixture.archive, '/Users/source')
        chosen = self.ssh_selection((1,))
        initial = self.prepare(chosen)
        self.assertEqual(initial['ssh_identity_dependencies'], dict(version=1, findings=['missing']))
        self.assertFalse(initial['include_secure'])
        self.assertFalse(target.parent.exists())
        target.parent.mkdir(mode=0o700)
        key = target.parent / 'id_fixture'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        before = [(p.name, p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes()) for p in sorted(target.parent.iterdir())]
        local = self.prepare(chosen)
        self.assertEqual(local['ssh_identity_dependencies'], dict(version=1, findings=['local_satisfied']))
        self.assertTrue(local['readiness']['ready'], local)
        self.assertNotEqual(initial['prepared_plan_id'], local['prepared_plan_id'])
        self.assertEqual(before, [(p.name, p.stat().st_ino, p.stat().st_mtime_ns, p.read_bytes()) for p in sorted(target.parent.iterdir())])
        self.assertEqual(self.prepare(self.ssh_selection((0,)))['ssh_identity_dependencies']['findings'], ['no_file_dependency'])
        result, events = self.fixture.invoke(secure=True, selection=dict(categories=[], items={}))
        self.assertEqual(result.returncode, 0, events)
        self.assertNotIn('ssh_identity_dependencies', events[-2]['data'])
        self.assertTrue(events[-2]['data']['include_secure'])
        key.unlink(); Path(str(key) + '.pub').unlink()
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        changed = self.prepare(chosen)
        self.assertEqual(changed['ssh_identity_dependencies'], local['ssh_identity_dependencies'])
        self.assertNotEqual(changed['prepared_plan_id'], local['prepared_plan_id'])
        result, events = self.fixture.execute(local['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])
        self.assertFalse((self.fixture.root / 'mutations').exists(), 'Prepare must never unlock age or request sudo')
        self.assertFalse(target.exists())
        for private in ('id_fixture', '~/.ssh', str(self.fixture.home), 'production.invalid'):
            self.assertNotIn(private, json.dumps(local))

    def test_ssh_subset_execute_verify_noop_and_unselected_conflict(self):
        target = self.ssh_fixture()
        self.fixture.allow_application_bootstrap()
        target.parent.mkdir(mode=0o700)
        original = b'# preserve unrelated bytes\nHost production\n HostName different.invalid\nHost unrelated\n HostName unrelated.invalid\n'
        target.write_bytes(original); target.chmod(0o600)
        full = self.prepare(dict(categories=['ssh-configuration'], items={}))
        self.assertFalse(full['readiness']['ready'])
        chosen = self.ssh_selection()
        prepared = self.prepare(chosen)
        self.assertTrue(prepared['readiness']['ready'], prepared)
        self.assertEqual(prepared['selection'], chosen)
        self.assertEqual(prepared['selected_item_counts']['ssh-configuration'], 1)
        self.assertTrue(any(row['domain'] == 'ssh-configuration' and row['disposition'] == 'planned' for row in prepared['plan']))
        result, events = self.fixture.execute(prepared['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(target.read_bytes(), original + b'Host github\n    HostName github.invalid\n    User git\n')
        published = self.fixture.project / 'config/generated/ssh/config.snapshot'
        self.assertEqual(list(bundle.ssh_snapshot(published.read_bytes())[3]), ['github'])
        self.assertEqual(events[-2]['data']['verification']['verdict'], 'selected_requirements_verified')
        before = target.stat()
        retained = list(target.parent.glob('.macseed-ssh-predecessor-*'))
        self.assertEqual(len(retained), 1)
        repeated = self.prepare(chosen)
        self.assertTrue(repeated['readiness']['ready'])
        self.assertFalse(any(row['disposition'] == 'planned' for row in repeated['plan']))
        result, events = self.fixture.execute(repeated['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual((target.stat().st_ino, target.stat().st_mtime_ns), (before.st_ino, before.st_mtime_ns))
        self.assertEqual(list(target.parent.glob('.macseed-ssh-predecessor-*')), retained)

    def ssh_request(self, operation, chosen, approvals=None, plan=None):
        request = dict(protocol_version=1, operation_id='ssh-review-test', operation=operation,
                       parameters=dict(path=str(self.fixture.archive), selection=chosen))
        if operation != 'ssh_restore_review':
            request['parameters'].update(disabled_groups=[], include_secure=False)
        if plan is not None: request['parameters']['expected_prepared_plan_id'] = plan
        if approvals is not None:
            request['parameters']['ssh_approvals'] = True
            control = self.fixture.private_temp / resolution.CONTROL
            control.write_text(json.dumps(dict(operation_id=request['operation_id'], approvals=approvals))); control.chmod(0o600)
        child = subprocess.run(['bash', str(self.fixture.project / 'modules/core/application-interface/core.sh')],
                               input=json.dumps(request).encode(), env=self.fixture.environment, cwd=self.fixture.project, capture_output=True)
        return child.returncode, [json.loads(line) for line in child.stdout.splitlines()]

    def test_ssh_review_and_readiness_fixture_matrix(self):
        # Production request/Bundle/selection/snapshot/review/response and Prepare.
        # Every scenario has its own HOME; no live key or config is consulted.
        scenarios = [('A-v1', 1, []), ('B-local', 2, ['~/.ssh/id_fixture']),
                     ('C-none', 2, ['none']), ('C-implicit', 2, []),
                     ('D-missing', 2, ['~/.ssh/missing']), ('G-conflict-v1', 1, []),
                     ('G-conflict-v2', 2, []),
                     ('H-ordered', 2, ['~/.ssh/id_fixture', '~/.ssh/missing', '~/.ssh/other']),
                     ('I-unsafe', 2, ['~/.ssh/unsafe', '/source-only/key'])]
        for label, version, refs in scenarios:
            with self.subTest(scenario=label):
                case = SelectionTests(); case.setUp()
                try:
                    target = case.ssh_fixture(version=version)
                    raw = IdentityDependencyTests.raw(self, [('production', refs)], version=version)
                    case.ssh_source.write_bytes(raw)
                    case.fixture.archive.unlink(); bundle.pack(case.stage, case.fixture.archive, '/Users/source')
                    if label in ('B-local', 'H-ordered'):
                        target.parent.mkdir(mode=0o700)
                        for name in (['id_fixture', 'other'] if label == 'H-ordered' else ['id_fixture']):
                            subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(target.parent / name)], check=True)
                    elif label.startswith('G-'):
                        target.parent.mkdir(mode=0o700)
                        target.write_bytes(b'Host production\n HostName conflicting.invalid\n'); target.chmod(0o600)
                    elif label == 'I-unsafe':
                        target.parent.mkdir(mode=0o700)
                        (target.parent / 'unsafe').symlink_to(case.fixture.root / 'absent-key')
                    def state():
                        return [(str(p.relative_to(case.fixture.home)), p.lstat().st_ino, p.lstat().st_mode,
                                 p.lstat().st_mtime_ns, p.read_bytes() if p.is_file() and not p.is_symlink() else None)
                                for p in [case.fixture.home, *sorted(case.fixture.home.rglob('*'))]]
                    before = state()
                    chosen = dict(categories=['ssh-configuration'], items={})
                    code, events = case.ssh_request('ssh_restore_review', chosen)
                    self.assertEqual(code, 0, (label, events))
                    review = json.loads((case.fixture.private_temp / resolution.REVIEW).read_bytes())
                    actionable = label in ('D-missing', 'H-ordered', 'I-unsafe')
                    self.assertEqual(bool(review['items']), actionable, label)
                    if label == 'H-ordered':
                        self.assertEqual([(row['index'], row['reference']) for row in review['items']], [(1, refs[1])])
                    if label == 'I-unsafe':
                        self.assertEqual([row['status'] for row in review['items']], ['unsafe_target', 'unresolved'])
                    prepared = case.prepare(chosen)
                    blocked = actionable or label.startswith('G-')
                    self.assertEqual(prepared['readiness']['ready'], not blocked, (label, prepared))
                    if version == 2: self.assertEqual(prepared['ssh_resolution']['ready'], not blocked)
                    if blocked:
                        result, rejected = case.fixture.execute(prepared['prepared_plan_id'], selection=chosen)
                        self.assertEqual(result.returncode, 2, rejected)
                        self.assertFalse(rejected[-1]['data']['publication_started'])
                    self.assertEqual(state(), before, 'read-only assessment/rejected Execute cannot change HOME')
                    self.assertFalse((case.fixture.root / 'mutations').exists())
                    print('PASS fixture:', label)
                finally:
                    case.doCleanups()

    def test_large_v2_snapshot_prepare_execute_context(self):
        target = self.ssh_fixture(version=2)
        self.fixture.allow_application_bootstrap()
        raw = IdentityDependencyTests.raw(self, [(f'host-{index:04d}-' + 'x' * 65, []) for index in range(450)])
        self.assertGreater(len(raw), 65536)
        bundle.ssh_snapshot(raw)
        self.ssh_source.write_bytes(raw)
        self.fixture.archive.unlink(); bundle.pack(self.stage, self.fixture.archive, '/Users/source')
        chosen = dict(categories=['ssh-configuration'], items={})
        prepared = self.prepare(chosen)
        self.assertTrue(prepared['readiness']['ready'], prepared)
        self.assertFalse(target.exists())
        result, events = self.fixture.execute(prepared['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(target.read_bytes(), resolution.config.payload(resolution.config.snapshot(raw)[3]))
        self.assertEqual(events[-2]['data']['verification']['verdict'], 'selected_requirements_verified')

    def test_v2_private_review_local_approval_execute_and_stale(self):
        target = self.ssh_fixture(version=2)
        self.fixture.allow_application_bootstrap()
        directory = self.fixture.home / 'keys'; directory.mkdir(mode=0o700)
        key = directory / 'deploy'
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        chosen = self.ssh_selection((1,))
        code, events = self.ssh_request('ssh_restore_review', chosen)
        self.assertEqual(code, 0, events)
        reviewed = json.loads((self.fixture.private_temp / resolution.REVIEW).read_bytes())
        self.assertEqual(reviewed['items'], [dict(host_id=self.ssh_ids[1], host='production', index=0,
            reference='/old-home/deploy', status='unresolved', proposal=None)])
        self.assertEqual(reviewed['bundle_id'], bundle.fingerprint(self.fixture.archive))
        self.assertNotIn('/old-home', json.dumps(events)); self.assertFalse(target.parent.exists())
        approval = dict(version=1, bundle_id=reviewed['bundle_id'], items=[dict(host_id=self.ssh_ids[1], index=0,
            original='/old-home/deploy', reference='~/keys/deploy', identity_id=None, approved=True)])
        proposal = json.loads(json.dumps(approval)); proposal['items'][0]['approved'] = False
        (self.fixture.private_temp / resolution.REVIEW).unlink()
        code, events = self.ssh_request('ssh_restore_review', chosen, proposal)
        self.assertEqual(code, 0, events)
        qualified = json.loads((self.fixture.private_temp / resolution.REVIEW).read_bytes())
        self.assertEqual(qualified['items'][0]['proposal']['status'], 'local_satisfied')
        self.assertNotIn('deploy', json.dumps(events))
        code, events = self.ssh_request('restore_prepare', chosen, proposal)
        self.assertEqual(code, 2); self.assertEqual(events[-1]['data']['code'], 'ssh_approval_invalid')
        code, events = self.ssh_request('restore_prepare', chosen, approval)
        self.assertEqual(code, 0, events)
        plan = events[-2]['data']; self.assertTrue(plan['ssh_resolution']['ready']); self.assertTrue(plan['readiness']['ready'], plan)
        code, stale = self.ssh_request('restore_execute', chosen, plan=plan['prepared_plan_id'])
        self.assertEqual(code, 2); self.assertEqual(stale[-1]['data']['code'], 'stale_plan'); self.assertFalse(target.exists())
        code, result = self.ssh_request('restore_execute', chosen, approval, plan['prepared_plan_id'])
        self.assertEqual(code, 0, result)
        self.assertIn(b'IdentityFile ~/keys/deploy', target.read_bytes())
        self.assertNotIn(b'Host github', target.read_bytes())
        self.assertEqual(result[-2]['data']['verification']['verdict'], 'selected_requirements_verified', result)
        code, repeated = self.ssh_request('restore_prepare', chosen, approval)
        self.assertEqual(code, 0, repeated)
        self.assertFalse(repeated[-2]['data']['readiness']['ready'], 'original differing Host remains a conflict')
        for private in ('/old-home', '~/keys/deploy', str(self.fixture.home), 'production.invalid'):
            self.assertNotIn(private, json.dumps(result))

    def test_v2_no_file_execute_noop_and_selected_stale(self):
        target = self.ssh_fixture(version=2)
        self.fixture.allow_application_bootstrap()
        chosen = self.ssh_selection()
        plan = self.prepare(chosen)
        result, stale = self.fixture.execute(plan['prepared_plan_id'], selection=self.ssh_selection((1,)))
        self.assertEqual(result.returncode, 2); self.assertEqual(stale[-1]['data']['code'], 'stale_plan')
        result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-2]['data']['verification']['verdict'], 'selected_requirements_verified')
        before = target.stat()
        plan = self.prepare(chosen)
        self.assertEqual(plan['ssh_resolution']['action'], 'noop')
        result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual((before.st_ino, before.st_mtime_ns), (target.stat().st_ino, target.stat().st_mtime_ns))

    def test_v2_partial_creation_retains_unresolved_coverage(self):
        target = self.ssh_fixture(version=2, partial=True)
        self.fixture.allow_application_bootstrap()
        chosen = self.ssh_selection()
        plan = self.prepare(chosen)
        self.assertTrue(plan['ssh_resolution']['ready']); self.assertTrue(plan['readiness']['ready'])
        result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
        self.assertEqual(events[-1]['type'], 'completed', events)
        self.assertTrue(target.exists())
        self.assertTrue(any(row['domain'] == 'ssh-configuration' and row['disposition'] == 'unresolved'
                            and row['source_status'] == 'partial'
                            for row in events[-2]['data']['verification']['details']['coverage_records']))
        self.assertNotEqual(events[-2]['data']['verification']['verdict'], 'selected_requirements_verified')

    def test_ssh_full_legacy_empty_and_independent_secure_selection(self):
        target = self.ssh_fixture(secure=True)
        explicit = self.prepare(self.ssh_selection((0, 1)))
        legacy = self.prepare(dict(categories=['ssh-configuration'], items={}))
        implicit = self.prepare()
        self.assertEqual(explicit['selection'], self.ssh_selection((0, 1)))
        self.assertEqual(explicit['prepared_plan_id'], legacy['prepared_plan_id'])
        self.assertEqual(explicit['selection'], implicit['selection'])
        self.assertEqual(explicit['plan'], implicit['plan'])
        self.assertFalse(explicit['include_secure'])
        result, events = self.fixture.invoke(secure=True, selection=self.ssh_selection())
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue(events[-2]['data']['include_secure'])
        self.assertEqual(events[-2]['data']['selection'], self.ssh_selection())
        for empty in (dict(categories=[], items={}), self.ssh_selection(())):
            plan = self.prepare(empty)
            self.assertEqual(plan['selection'], dict(categories=[], items={}))
            self.assertEqual(plan['plan'], [])
            self.assertFalse(plan['include_secure'])
        self.fixture.allow_application_bootstrap()
        result, events = self.fixture.execute(explicit['prepared_plan_id'], selection=self.ssh_selection((0, 1)))
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(target.read_bytes(), self.ssh_payload)
        self.assertFalse((self.fixture.project / 'config/generated/secure.age').exists())

    def test_ssh_selection_stale_ids_bundle_and_target_bindings(self):
        target = self.ssh_fixture()
        chosen = self.ssh_selection()
        plan = self.prepare(chosen)
        for invalid in ('unknown', self.ssh_ids[0].upper()):
            result, events = self.fixture.invoke(selection=dict(categories=[], items={'ssh-configuration': [invalid]}))
            self.assertEqual(result.returncode, 2, events)
            self.assertEqual(events[-1]['data']['code'], 'invalid_selection')
        for changed in (self.ssh_selection((1,)), dict(categories=['ssh-configuration'], items={}), self.ssh_selection(())):
            result, events = self.fixture.execute(plan['prepared_plan_id'], selection=changed)
            self.assertEqual(events[-1]['data']['code'], 'stale_plan')
            self.assertFalse(events[-1]['data']['publication_started'])
        self.fixture.archive.unlink()
        self.ssh_source.write_bytes(self.ssh_source.read_bytes().replace(b'production.invalid', b'changed.invalid'))
        self.fixture.pack()
        result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])
        fresh = self.prepare(chosen)
        target.parent.mkdir(mode=0o700)
        target.write_bytes(b'Host unrelated\n HostName unrelated.invalid\n'); target.chmod(0o600)
        result, events = self.fixture.execute(fresh['prepared_plan_id'], selection=chosen)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse((self.fixture.project / 'config/generated').exists())

    def test_ssh_subset_conflicts_and_ambiguous_target_remain_blocked(self):
        target = self.ssh_fixture()
        target.parent.mkdir(mode=0o700)
        for raw in (b'Host github\n HostName conflicting.invalid\n',
                    b'Host GITHUB\n HostName github.invalid\n',
                    b'Host github\n HostName github.invalid\n ProxyCommand forbidden\n',
                    b'Host unrelated\n HostName unrelated.invalid\n Compression yes\n',
                    b'Host github\n HostName github.invalid\nHost GITHUB\n HostName github.invalid\n'):
            with self.subTest(raw=raw):
                target.write_bytes(raw); target.chmod(0o600)
                plan = self.prepare(self.ssh_selection())
                self.assertFalse(plan['readiness']['ready'], plan)
                result, events = self.fixture.execute(plan['prepared_plan_id'], selection=self.ssh_selection())
                self.assertEqual(result.returncode, 2, events)
                self.assertFalse(events[-1]['data']['publication_started'])
                self.assertEqual(target.read_bytes(), raw)

    def test_ssh_subset_v2_qualified_no_file_and_unresolved_identity(self):
        target = self.ssh_fixture(version=2)
        local = self.prepare(self.ssh_selection())
        self.assertTrue(local['readiness']['ready'], local)
        self.assertTrue(local['ssh_resolution']['ready'])
        chosen = self.ssh_selection((1,))
        plan = self.prepare(chosen)
        self.assertFalse(plan['readiness']['ready'], plan)
        self.assertFalse(plan['ssh_resolution']['ready'])
        self.assertTrue(any(row['reason'] == 'identity_dependencies_unresolved' for row in plan['plan']))
        result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 2, events)
        self.assertFalse(events[-1]['data']['publication_started'])
        self.assertFalse(target.exists())
        # A subset cannot erase ambiguous source syntax or its v2 capability.
        files = bundle.validate_archive(self.fixture.archive)
        self.assertEqual(bundle.validate_ssh(files), {'ssh-configuration': 2})
        files['generated/ssh/config.snapshot'] += b'Host GITHUB\n    HostName ambiguous.invalid\n'
        with self.assertRaises(bundle.Invalid):
            selection_api.inventory(files)

    def test_ssh_subset_preserves_partial_coverage_and_independent_categories(self):
        target = self.ssh_fixture(partial=True)
        target.parent.mkdir(mode=0o700)
        target.write_bytes(b'Host unrelated\n HostName unrelated.invalid\n'); target.chmod(0o600)
        plan = self.prepare(self.ssh_selection())
        self.assertFalse(plan['readiness']['ready'])
        self.assertTrue(any(row['reason'] == 'partial_source_coverage' for row in plan['plan']))
        # Narrow only private staged SSH data; flags for independent categories survive.
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[workspace-folders]\n', '[workspace-folders]\nProjects\n'))
        self.fixture.archive.unlink()
        self.fixture.pack()
        chosen = dict(categories=['workspace-folders'], items={'ssh-configuration': []})
        plan = self.prepare(chosen)
        self.assertTrue(plan['readiness']['ready'])
        self.assertFalse(any(row['domain'] == 'ssh-configuration' for row in plan['plan']))
        original, before = target.read_bytes(), target.stat()
        self.fixture.allow_application_bootstrap()
        result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue((self.fixture.home / 'Projects').is_dir())
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual((target.stat().st_ino, target.stat().st_mtime_ns), (before.st_ino, before.st_mtime_ns))
        self.assertEqual(list(target.parent.iterdir()), [target])
        sections, categories = bundle.parse_blueprint((self.fixture.project / 'config/blueprint.conf').read_bytes())
        self.assertFalse(categories['ssh-configuration'])
        self.assertEqual(sections['workspace-folders'], ['Projects'])
        records = events[-2]['data']['verification']['details']['verification_records']
        self.assertFalse(any(row['domain'] == 'ssh-configuration' for row in records))

    def test_homebrew_token_labels_from_saved_bundle_keep_identity_and_privacy(self):
        tokens = {'homebrew-casks': ['thaw@beta'],
                  'homebrew-packages': ['openssl@3', 'libsigc++', 'owner/tap/formula@2+extra']}
        blueprint = self.stage / 'blueprint.conf'
        raw = blueprint.read_text()
        for domain, values in tokens.items():
            raw = raw.replace('[' + domain + ']\n', '[' + domain + ']\n' + '\n'.join(values) + '\n')
            bundle.write_file(self.stage / 'generated' / bundle.ITEMS[domain], ('\n'.join(values) + '\n').encode())
        blueprint.write_text(raw)
        self.fixture.pack()
        before = self.fixture.archive.read_bytes()
        rows = {row['domain']: row for row in self.inspect()['restore_selection']['inventory']}
        for domain, values in tokens.items():
            self.assertEqual(rows[domain]['items'], [
                {'item_id': selection_api.identity(domain, value), 'label': value} for value in values])
            for unsafe in ('https://user:SECRET@example.test/app', 'user:SECRET@host',
                           '/Users/private/app', '~/private/app', '../private/app',
                           'folder/app', 'owner/tap/path/app', '--option', 'app.rb', 'app\nsecret'):
                self.assertEqual(selection_api.label(unsafe, domain), 'Private item')
        self.assertEqual(selection_api.label('owner/tap/app', 'homebrew-casks'), 'Private item')
        for domain in set(selection_api.LABELS) - set(tokens):
            for value in ('thaw@beta', 'openssl@3', 'libsigc++', 'https://user:SECRET@example.test/app'):
                self.assertEqual(selection_api.label(value, domain), 'Private item')
        self.assertEqual(self.fixture.archive.read_bytes(), before)

    def test_protocol_inventory_prepare_binding_and_stale_execute(self):
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[workspace-folders]\nProjects\n', '[workspace-folders]\nProjects\nOther\n'))
        (self.stage / 'generated/workspace/folders.conf').write_bytes(b'Projects|workspace\nOther|workspace\n')
        self.fixture.pack()
        before = self.fixture.archive.read_bytes()
        data = self.inspect()
        self.assertEqual(data['restore_selection']['groups'], [{'id': k, 'domains': list(v)} for k, v in bundle.GROUPS.items()])
        rows = {row['domain']: row for row in data['restore_selection']['inventory']}
        items = rows['workspace-folders']['items']
        legacy = self.prepare()
        chosen = {'categories': [], 'items': {'workspace-folders': [items[1]['item_id']]}}
        prepared = self.prepare(chosen)
        self.assertEqual(prepared['selection'], chosen)
        self.assertEqual(prepared['selected_item_counts']['workspace-folders'], 1)
        self.assertEqual(prepared['plan'][0]['selection_item_id'], items[1]['item_id'])
        self.assertEqual(prepared['plan'][0]['item_id'], 'Other')
        self.assertNotEqual(prepared['prepared_plan_id'], legacy['prepared_plan_id'])
        mismatched = {'categories': [], 'items': {'workspace-folders': [items[0]['item_id']]}}
        result, events = self.fixture.execute(prepared['prepared_plan_id'], selection=mismatched)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])
        self.assertFalse((self.fixture.home / 'Projects').exists())
        self.assertFalse((self.fixture.home / 'Other').exists())
        self.assertFalse((self.fixture.project / 'config/generated').exists())
        self.assertEqual(self.fixture.archive.read_bytes(), before)
        empty = self.prepare({'categories': [], 'items': {}})
        self.assertFalse(empty['selected_groups'])
        self.assertFalse(empty['plan'])
        self.assertEqual(self.prepare()['prepared_plan_id'], legacy['prepared_plan_id'])
        self.fixture.allow_application_bootstrap()
        result, events = self.fixture.execute(prepared['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue((self.fixture.home / 'Other').is_dir())
        self.assertFalse((self.fixture.home / 'Projects').exists())
        self.assertEqual(self.fixture.archive.read_bytes(), before)

    def test_invalid_and_disabled_requests(self):
        self.fixture.pack()
        rows = {r['domain']: r for r in self.inspect()['restore_selection']['inventory']}
        item = rows['workspace-folders']['items'][0]['item_id']
        for selection in [False, {}, {'categories': ['missing'], 'items': {}},
                          {'categories': ['workspace-folders'] * 2, 'items': {}},
                          {'categories': ['workspace-folders'], 'items': {'workspace-folders': [item]}},
                          {'categories': [], 'items': {'workspace-folders': [item, item]}},
                          {'categories': [], 'items': {'workspace-folders': ['unknown']}},
                          {'categories': [], 'items': {'macos-dock': [item]}},
                          {'categories': ['macos-dock'], 'items': {}},
                          {'categories': [], 'items': {'workspace-folders': []}}]:
            result, events = self.fixture.invoke(selection=selection)
            self.assertEqual(result.returncode, 2, selection)
            self.assertEqual(events[-1]['data']['code'], 'invalid_selection')
        result, events = self.fixture.invoke(groups=['Workspace'], selection={'categories': ['workspace-folders'], 'items': {}})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'invalid_selection')

    def populated(self):
        flags = {name: True for name in bundle.CATEGORY_FLAGS}
        sections = {name: ['first', 'second'] for name in bundle.ITEMS}
        sections['git-configuration'] = ['user.name', 'user.email']
        raw = '[categories]\n' + ''.join(f'{k}="true"\n' for k in flags)
        raw += ''.join('\n[' + k + ']\n' + '\n'.join(v) + '\n' for k, v in sections.items())
        (self.stage / 'blueprint.conf').write_bytes(raw.encode())
        for name, path in bundle.ITEMS.items():
            target = self.stage / 'generated' / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes( b'first|workspace\nsecond|workspace\n' if name == 'workspace-folders' else b'PRIVATE_VALUE')
        for path in bundle.CATEGORIES.values():
            target = self.stage / 'generated' / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes( b'PRIVATE_PREFERENCE_VALUE')
        snapshot = self.stage / 'generated/ssh/config.snapshot'
        snapshot.write_bytes(b'# toolkit-ssh-snapshot: 1\n# status: empty\n# excluded-profiles: 0\n\n')
        snapshot.chmod(0o600)
        return sections

    def test_all_modes_narrowing_identity_privacy_and_category_flags(self):
        sections = self.populated()
        projection, sources = selection_api.inventory(selection_api.staged_files(self.stage))
        rows = {row['domain']: row for row in projection['inventory']}
        for domain in bundle.ITEMS | bundle.CATEGORIES:
            self.assertTrue(rows[domain]['source_present'], domain)
            self.assertTrue(rows[domain]['capture_selected'], domain)
        self.assertFalse(rows['vscode-workspaces']['source_present'])
        self.assertFalse(rows['vscode-workspaces']['capture_selected'])
        self.assertEqual(rows['vscode-workspaces']['items'], [])
        self.assertEqual(rows['vscode-workspaces']['availability'], 'unavailable')
        files = selection_api.staged_files(self.stage)
        del files['generated/brew-casks.conf']
        files['generated/vscode/settings.json'] = b''
        presence, _ = selection_api.inventory(files)
        rows = {row['domain']: row for row in presence['inventory']}
        self.assertFalse(rows['homebrew-casks']['source_present'])
        self.assertTrue(rows['vscode-settings']['source_present'])

        self.assertNotIn('PRIVATE_', json.dumps(projection))
        self.assertNotIn('secure', json.dumps(projection))
        self.assertEqual(selection_api.label('https://user:SECRET@example.test/repo'), 'Private item')
        self.assertEqual({r['domain'] for r in projection['inventory'] if r['selection_mode'] == 'items'}, set(bundle.SELECTABLE_ITEMS))
        chosen = {'categories': ['macos-finder', 'macos-trackpad', 'vscode-settings', 'shell-zsh', 'ssh-configuration'],
                  'items': {domain: [selection_api.identity(domain, values[1])] for domain, values in sections.items()}}
        selection_api.narrow(self.stage, chosen, [])
        narrowed, flags = bundle.parse_blueprint((self.stage / 'blueprint.conf').read_bytes())
        for domain, values in sections.items():
            self.assertEqual(narrowed[domain], [values[1]])
        for domain in bundle.CATEGORIES:
            self.assertEqual(flags[domain], domain in chosen['categories'])
        records = [{'domain': 'git-repositories', 'item_id': '1'}]
        selection_api.correlate(records, self.stage)
        self.assertEqual(records[0]['selection_item_id'], chosen['items']['git-repositories'][0])
        self.assertEqual(selection_api.canonical(self.stage), {'categories': sorted(chosen['categories']), 'items': dict(sorted(chosen['items'].items()))})
        selection_api.narrow(self.stage, {'categories': chosen['categories'],
                            'items': {domain: ids for domain, ids in chosen['items'].items() if domain != 'vscode-extensions'}}, [])
        retained, _ = selection_api.inventory(selection_api.staged_files(self.stage))
        row = next(row for row in retained['inventory'] if row['domain'] == 'vscode-extensions')
        self.assertTrue(row['source_present'])
        self.assertFalse(row['capture_selected'])
        self.assertEqual(row['items'], [])


    def test_captured_app_names_preserve_identity_and_round_trip(self):
        self.populated()
        target = self.stage / 'generated/appstore.conf'
        target.write_bytes(b'first|Captured App One\nsecond|Captured App Two\n')
        projection, sources = selection_api.inventory(selection_api.staged_files(self.stage))
        rows = {r['domain']: r for r in projection['inventory']}
        self.assertEqual(rows['homebrew-casks']['label'], 'Homebrew Applications')
        self.assertEqual(rows['app-store']['items'], [
            {'item_id': selection_api.identity('app-store', value), 'label': name}
            for value, name in [('first', 'Captured App One'), ('second', 'Captured App Two')]])
        for domain in bundle.ITEMS:
            if domain != 'app-store':
                self.assertEqual([r['label'] for r in rows[domain]['items']], list(sources[domain].values()))
        before = rows['app-store']['items'][1]['item_id']
        target.write_bytes(b'first|Renamed One\nsecond|Renamed Two\n')
        updated, _ = selection_api.inventory(selection_api.staged_files(self.stage))
        self.assertEqual(next(r for r in updated['inventory'] if r['domain'] == 'app-store')['items'][1]['item_id'], before)
        selection_api.narrow(self.stage, {'categories': [], 'items': {'app-store': [before]}}, [])
        self.assertEqual(selection_api.canonical(self.stage)['items'], {'app-store': [before]})
        records = [{'domain': 'app-store', 'item_id': 'second'}]
        selection_api.correlate(records, self.stage)
        self.assertEqual(records[0]['selection_item_id'], before)

    def test_whole_domains_and_each_macos_domain(self):
        for domain in bundle.CATEGORIES:
            self.populated()
            selection_api.narrow(self.stage, {'categories': [domain], 'items': {}}, [])
            self.assertEqual(selection_api.canonical(self.stage), {'categories': [domain], 'items': {}})
        for domain in bundle.ITEMS:
            values = self.populated()[domain]
            selection_api.narrow(self.stage, {'categories': [domain], 'items': {}}, [])
            self.assertEqual(selection_api.canonical(self.stage)['items'], {domain: sorted(selection_api.identity(domain, x) for x in values)})

    def test_real_macos_domain_and_git_subset_preview(self):
        blueprint = self.stage / 'blueprint.conf'
        raw = blueprint.read_text().replace('macos-dock="false"', 'macos-dock="true"').replace('macos-keyboard="false"', 'macos-keyboard="true"').replace('git-configuration="false"', 'git-configuration="true"').replace('[git-configuration]\n', '[git-configuration]\nuser.name\nuser.email\n')
        blueprint.write_text(raw)
        bundle.write_file(self.stage / 'generated/macos/dock.conf', b'com.apple.dock|autohide|bool|true\n')
        bundle.write_file(self.stage / 'generated/macos/keyboard.conf', b'NSGlobalDomain|KeyRepeat|int|6\n')
        bundle.write_file(self.stage / 'generated/git.conf', b'[user]\nname = PRIVATE_NAME\nemail = PRIVATE_EMAIL\n')
        defaults = self.fixture.root / 'bin/defaults'
        defaults.write_text('#!/bin/bash\necho "The domain/default pair of ($2, $3) does not exist" >&2\nexit 1\n')
        defaults.chmod(0o700)
        self.fixture.pack()
        chosen = {'categories': ['macos-dock'], 'items': {'git-configuration': [selection_api.identity('git-configuration', 'user.name')]}}
        result = self.prepare(chosen)
        self.assertEqual(result['selection'], chosen)
        self.assertEqual(set(row['domain'] for row in result['plan']), {'macos-dock', 'git-configuration'})
        self.assertFalse(any(row['item_id'] == 'user.email' for row in result['plan']))
        self.assertNotIn('PRIVATE_', json.dumps(result))
        self.assertFalse((self.fixture.home / '.gitconfig').exists())

    def test_capability_and_null_legacy(self):
        self.fixture.pack()
        plan = self.prepare()
        # Legacy means an omitted/null request, not whichever adapter happens to
        # be in git HEAD (which now also advertises additive response metadata).
        expected = selection_api.canonical(self.stage)
        self.assertEqual(plan['selection'], expected)
        self.assertTrue(expected['items'])  # Legacy retains captured scope; no empty whitelist.
        for operation, parameters in [('capabilities', None), ('restore_prepare', dict(path=str(self.fixture.archive), disabled_groups=[], include_secure=False, selection=None))]:
            request = dict(protocol_version=1, operation_id='compatibility', operation=operation)
            if parameters is not None: request['parameters'] = parameters
            result = subprocess.run(['bash', str(self.fixture.project / 'modules/core/application-interface/core.sh')], input=json.dumps(request).encode(), env=self.fixture.environment, cwd=self.fixture.project, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout)
            data = json.loads(result.stdout.splitlines()[-2])['data']
            if operation == 'capabilities': self.assertEqual(data['features']['restore_selection']['version'], 1)
            else:
                self.assertEqual(data['prepared_plan_id'], plan['prepared_plan_id'])
                self.assertEqual(data['selection'], expected)
                self.assertEqual(data, plan)  # Exact effective plan, including correlation and identity.

if __name__ == '__main__': unittest.main()
