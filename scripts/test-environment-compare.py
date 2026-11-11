#!/usr/bin/env python3
"""Read-only Protocol V1 Compare through production readers on disposable Macs."""
import hashlib
import copy
import importlib.util
import json
import os
import plistlib
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'modules/ssh'))
import ssh_merge
import host_presentation


class SSHMergeTests(unittest.TestCase):
    def test_host_evidence_safety_and_bounds(self):
        raw = b'# toolkit-ssh-snapshot: 1\n# status: ready\n# excluded-profiles: 0\n\n' + self.expected
        def observe():
            return host_presentation.observe(raw, str(self.home))
        self.path.write_bytes(self.expected)
        self.assertEqual(observe()['hosts'][0]['state'], 'matching')
        detail = observe()
        self.assertTrue(host_presentation.valid(detail, raw))
        for field, value in (('item_id', host_presentation.identity('foreign')), ('label', 'foreign'),
                             ('state', 'invented'), ('reason', 'target_conflict'), ('hostname', 'private.invalid')):
            malformed = copy.deepcopy(detail)
            malformed['hosts'][0][field] = value
            self.assertFalse(host_presentation.valid(malformed, raw))
        duplicate = copy.deepcopy(detail); duplicate['hosts'] *= 2
        self.assertFalse(host_presentation.valid(duplicate, raw))
        foreign = copy.deepcopy(detail); foreign['snapshot_id'] = 'b' * 64
        self.assertFalse(host_presentation.valid(foreign, raw))
        owner = dict(record_id='v:ssh', domain='ssh-configuration', item_id='config', predicate='supported_config_match')
        mismatch = dict(record_id='v:ssh', domain='ssh-configuration', item_id='config', comparison_kind='missing', support='supported')
        self.assertIsNone(host_presentation.comparison(detail, [mismatch], [owner], raw))
        for mode in (0o644, 0o400):
            self.path.chmod(mode)
            self.assertEqual(observe()['hosts'][0]['state'], 'unverified')
        self.path.chmod(0o600)
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(self.path)], check=True)
        self.assertEqual(observe()['hosts'][0]['state'], 'unverified')
        subprocess.run(['/bin/chmod', '-N', str(self.path)], check=True)
        saved = self.directory / 'saved'
        self.path.rename(saved)
        self.path.symlink_to(saved)
        self.assertEqual(observe()['hosts'][0]['state'], 'unverified')
        self.path.unlink(); saved.rename(self.path)
        pending = self.directory / '.macseed-ssh-pending-fixture'
        pending.mkdir()
        self.assertEqual(observe()['hosts'][0]['state'], 'unverified')
        pending.rmdir()
        with patch.object(host_presentation.merge, 'evidence', side_effect=['a' * 64, 'b' * 64]):
            self.assertIsNone(observe())
        oversized = raw.replace(b'Host added', b'Host ' + b'x' * 161)
        self.assertIsNone(host_presentation.observe(oversized, str(self.home)))
        self.assertEqual(self.path.read_bytes(), self.expected)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name).resolve() / 'home'
        self.directory = self.home / '.ssh'
        self.directory.mkdir(parents=True, mode=0o700)
        self.path = self.directory / 'config'
        self.original = b'# existing comment\r\nHost existing\r\n\tUser fixture\r\n HostName existing.invalid\r\n Port 2222\r\n# final comment'
        self.path.write_bytes(self.original); self.path.chmod(0o600)
        self.expected = b'Host added\n    HostName added.invalid\n'

    def publish(self):
        return ssh_merge.publish(self.expected, str(self.home), ssh_merge.evidence(str(self.home)))

    def test_merge_preserves_bytes_behavior_metadata_and_repeat(self):
        subprocess.run(['/usr/bin/xattr', '-w', 'com.macseed.fixture', 'preserve', str(self.path)], check=True)
        before = self.path.stat()
        native = ['/usr/bin/ssh', '-G', '-F', str(self.path), 'existing']
        options = subprocess.check_output(native, env=dict(os.environ, HOME=str(self.home)), stderr=subprocess.DEVNULL)
        self.assertEqual(ssh_merge.plan(self.expected, str(self.home)), ('merge', 1))
        self.assertEqual(list(self.directory.iterdir()), [self.path])
        self.assertTrue(self.publish())
        self.assertEqual(self.path.read_bytes(), self.original + b'\n' + self.expected)
        self.assertEqual(subprocess.check_output(native, env=dict(os.environ, HOME=str(self.home)), stderr=subprocess.DEVNULL), options)
        after = self.path.stat()
        self.assertEqual((after.st_uid, after.st_gid, after.st_mode), (before.st_uid, before.st_gid, before.st_mode))
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.macseed.fixture', str(self.path)]), b'preserve\n')
        retained = list(self.directory.glob('.macseed-ssh-predecessor-*'))
        self.assertEqual(len(retained), 1)
        self.assertEqual((retained[0] / 'swap').read_bytes(), self.original)
        self.assertEqual((retained[0] / 'swap').stat().st_ino, before.st_ino)
        self.assertEqual(ssh_merge.plan(self.expected, str(self.home)), ('noop', 0))
        self.assertFalse(self.publish())
        self.assertEqual(self.path.stat().st_ino, after.st_ino)
        self.assertEqual(list(self.directory.glob('.macseed-ssh-predecessor-*')), retained)

    def test_multiple_missing_with_existing_match_and_comments_only(self):
        selected = (b'Host existing\n    HostName existing.invalid\n    User fixture\n    Port 2222\n' +
                    self.expected + b'Host second\n    HostName second.invalid\n')
        merged, count = ssh_merge.candidate(selected, self.original)
        self.assertEqual(count, 2)
        self.assertEqual(merged, self.original + b'\n' + self.expected + b'Host second\n    HostName second.invalid\n')
        self.assertEqual(ssh_merge.candidate(self.expected, b'# comment'), (b'# comment\n' + self.expected, 1))

    def test_conflicting_ambiguous_and_unsupported_profiles_refused(self):
        for raw in (self.expected.replace(b'added.invalid', b'other.invalid'),
                    self.expected.replace(b'Host added', b'Host Added'),
                    self.expected * 2, self.expected + self.expected.replace(b'Host added', b'Host Added'),
                    b'Include other\n', b'Match all\n', b'Host *\n HostName wildcard.invalid\n',
                    b'User global\n', self.original + b'\n Compression yes\n'):
            with self.subTest(raw=raw), self.assertRaises((ValueError, OSError)):
                ssh_merge.candidate(self.expected, raw)
        with self.assertRaises(ValueError):
            ssh_merge.candidate(self.expected + b'    IdentityFile ~/.ssh/key\n', self.original)

    def test_links_permissions_ownership_acl_and_metadata_refused(self):
        self.path.chmod(0o644)
        with self.assertRaises(ValueError): self.publish()
        self.path.chmod(0o600)
        self.directory.chmod(0o755)
        with self.assertRaises(ValueError): self.publish()
        self.directory.chmod(0o700)
        other = self.home / 'other'
        os.link(self.path, other)
        with self.assertRaises(ValueError): self.publish()
        other.unlink()
        self.path.rename(other); self.path.symlink_to(other)
        with self.assertRaises((ValueError, OSError)): self.publish()
        self.path.unlink(); other.rename(self.path)
        with patch.object(ssh_merge.os, 'getuid', return_value=os.getuid() + 1), self.assertRaises(ValueError):
            self.publish()
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(self.path)], check=True)
        with self.assertRaises(ValueError): self.publish()
        self.assertEqual(self.path.read_bytes(), self.original)

    def test_unsafe_ancestor_and_unqualified_filesystem_refused(self):
        self.home.chmod(0o777)
        with self.assertRaises(ValueError): self.publish()
        self.home.chmod(0o700)
        alias = self.home.parent / 'alias'
        alias.symlink_to(self.home, target_is_directory=True)
        with self.assertRaises((ValueError, OSError)):
            ssh_merge.plan(self.expected, str(alias))
        with patch.object(ssh_merge, 'swap_supported', side_effect=ssh_merge.Refused('publication_unavailable')):
            with self.assertRaises(ValueError): self.publish()
        self.assertEqual(list(self.directory.iterdir()), [self.path])

    def test_stale_bytes_and_identical_inode_replacement_refused(self):
        for raw in (self.original + b'\n# edit\n', self.original):
            previous = ssh_merge.evidence(str(self.home))
            replacement = self.directory / 'editor-save'
            replacement.write_bytes(raw); replacement.chmod(0o600); replacement.replace(self.path)
            with self.assertRaises(ValueError):
                ssh_merge.publish(self.expected, str(self.home), previous)
            self.assertEqual(self.path.read_bytes(), raw)
            self.assertEqual(list(self.directory.iterdir()), [self.path])

    def test_publication_failure_retains_predecessor_and_blocks_retry(self):
        with patch.object(ssh_merge, 'rename', side_effect=OSError('fixture failure')):
            with self.assertRaises(ssh_merge.PublicationUncertain) as failure: self.publish()
        self.assertTrue(failure.exception.changed)
        pending = list(self.directory.glob('.macseed-ssh-pending-*'))
        self.assertEqual(len(pending), 1)
        self.assertEqual((pending[0] / 'observed').read_bytes(), self.original)
        self.assertEqual(self.path.read_bytes(), self.original)
        with self.assertRaises(ValueError): ssh_merge.plan(self.expected, str(self.home))
        self.assertEqual(ssh_merge.config.assess(self.expected, str(self.home))[1], 'publication_uncertain')

    def test_staging_failure_retains_pending_without_touching_config(self):
        with patch.object(ssh_merge, 'write_private', side_effect=OSError('fixture failure')):
            with self.assertRaises(ssh_merge.PublicationUncertain) as failure: self.publish()
        self.assertTrue(failure.exception.changed)
        self.assertEqual(self.path.read_bytes(), self.original)
        self.assertEqual(len(list(self.directory.glob('.macseed-ssh-pending-*'))), 1)
        with self.assertRaises(ValueError): ssh_merge.plan(self.expected, str(self.home))

    def test_last_gap_directory_replacement_preserves_both_locations(self):
        rename = ssh_merge.rename
        moved = self.home / 'moved-ssh'
        concurrent = b'Host editor\n HostName editor.invalid\n'
        def racing_rename(source_fd, source, target_fd, target, flag):
            if flag == 2:
                self.directory.rename(moved)
                self.directory.mkdir(mode=0o700)
                self.path.write_bytes(concurrent); self.path.chmod(0o600)
            return rename(source_fd, source, target_fd, target, flag)
        with patch.object(ssh_merge, 'rename', side_effect=racing_rename):
            with self.assertRaises(ssh_merge.PublicationUncertain): self.publish()
        self.assertEqual(self.path.read_bytes(), concurrent)
        self.assertEqual(list(self.directory.iterdir()), [self.path])
        pending = next(moved.glob('.macseed-ssh-pending-*'))
        self.assertEqual((pending / 'observed').read_bytes(), self.original)
        self.assertEqual((pending / 'swap').read_bytes(), self.original)
        self.assertEqual((moved / 'config').read_bytes(), self.original + b'\n' + self.expected)

    def test_last_gap_edit_is_retained_and_never_rolled_back(self):
        rename = ssh_merge.rename
        concurrent = b'# editor content\nHost editor\n HostName editor.invalid\n'
        def racing_rename(source_fd, source, target_fd, target, flag):
            if flag == 2:
                replacement = self.directory / 'editor-save'
                replacement.write_bytes(concurrent); replacement.chmod(0o600); replacement.replace(self.path)
            return rename(source_fd, source, target_fd, target, flag)
        with patch.object(ssh_merge, 'rename', side_effect=racing_rename):
            with self.assertRaises(ssh_merge.PublicationUncertain): self.publish()
        pending = next(self.directory.glob('.macseed-ssh-pending-*'))
        self.assertEqual((pending / 'observed').read_bytes(), self.original)
        self.assertEqual((pending / 'swap').read_bytes(), concurrent)
        self.assertEqual(self.path.read_bytes(), self.original + b'\n' + self.expected)
        self.assertEqual(ssh_merge.config.assess(self.expected, str(self.home))[1], 'publication_uncertain')

    def test_interruption_after_swap_retains_actual_predecessor(self):
        script = '''import os, sys
sys.path.insert(0, sys.argv[1])
import ssh_merge
rename = ssh_merge.rename
def interrupted(*args):
    rename(*args)
    os._exit(73)
ssh_merge.rename = interrupted
ssh_merge.publish(b'Host added\\n    HostName added.invalid\\n', sys.argv[2], ssh_merge.evidence(sys.argv[2]))
'''
        result = subprocess.run([sys.executable, '-B', '-c', script, str(ROOT / 'modules/ssh'), str(self.home)],
                                env=dict(os.environ, HOME=str(self.home)), capture_output=True, timeout=10)
        self.assertEqual(result.returncode, 73, result.stderr)
        pending = next(self.directory.glob('.macseed-ssh-pending-*'))
        self.assertEqual((pending / 'swap').read_bytes(), self.original)
        self.assertEqual(self.path.read_bytes(), self.original + b'\n' + self.expected)
        with self.assertRaises(ValueError): ssh_merge.plan(self.expected, str(self.home))


class CompareTests(unittest.TestCase):
    def test_bundle_host_detail_scope_counts_and_privacy(self):
        self.environment['HOME'] = str(self.home.resolve())
        payload = b'Host zebra\n    HostName secret-address.invalid\n    User privateuser\nHost alpha\n    HostName other.invalid\n'
        target = self.ssh_reference(payload)
        cases = [
            (payload, ['matching', 'matching'], 'matching'),
            (payload.split(b'Host alpha')[0], ['matching', 'missing'], 'missing'),
            (payload.replace(b'other.invalid', b'conflict.invalid'), ['matching', 'differing'], 'differing'),
            (b'Host zebra\n HostName conflicting.invalid\n', ['differing', 'missing'], 'differing'),
            (b'Include other\n' + payload, ['unsupported', 'unsupported'], 'unverified'),
        ]
        for actual, states, aggregate in cases:
            with self.subTest(states=states):
                target.write_bytes(actual); target.chmod(0o600)
                data = self.comparison(bundle_path=str(self.make_bundle()))
                detail = data['reference_presentation']['ssh_hosts']
                self.assertEqual([row['label'] for row in detail['hosts']], ['zebra', 'alpha'])
                self.assertEqual([row['state'] for row in detail['hosts']], states)
                self.assertEqual(data['comparison']['counts'][aggregate], 1)
                self.assertEqual(len(data['comparison_records']), 1)
                self.assertEqual(detail['comparison_record_id'], data['comparison_records'][0]['record_id'])
                wire = json.dumps(data)
                for private in ('secret-address.invalid', 'privateuser', 'HostName', 'IdentityFile'):
                    self.assertNotIn(private, wire)
                public = dict(data); public.pop('reference_presentation')
                self.assertNotIn('zebra', json.dumps(public))
        # Selected snapshot order/scope, never all Hosts in the original target.
        self.ssh_reference(payload.split(b'Host alpha')[0], partial=True)
        target.write_bytes(payload); target.chmod(0o600)
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual([h['label'] for h in data['reference_presentation']['ssh_hosts']['hosts']], ['zebra'])
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertNotIn('ssh_hosts', self.comparison()['reference_presentation'])  # Legacy/local reference fallback.

    def test_bundle_host_detail_preserves_identity_and_unsafe_diagnostics(self):
        self.environment['HOME'] = str(self.home.resolve())
        payload = b'Host example\n    HostName hidden.invalid\n    IdentityFile ~/.ssh/private_key\n'
        target = self.ssh_reference(payload, version=2)
        target.write_bytes(payload); target.chmod(0o600)
        archive = self.make_bundle()
        data = self.comparison(bundle_path=str(archive))
        self.assertEqual(data['reference_presentation']['ssh_hosts']['hosts'][0]['state'], 'matching')
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertTrue(any(row['item_id'] == 'identity-references' for row in data['records']['coverage_records']))
        self.assertNotIn('private_key', json.dumps(data))
        target.chmod(0o644)
        data = self.comparison(bundle_path=str(archive))
        self.assertEqual(data['reference_presentation']['ssh_hosts']['hosts'][0]['state'], 'unverified')
        self.assertEqual(data['comparison']['counts']['matching'], 0)

    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / 'project'
        self.project.mkdir()
        shutil.copytree(ROOT / 'modules', self.project / 'modules')
        shutil.copy2(ROOT / 'bootstrap.sh', self.project / 'bootstrap.sh')
        (self.project / 'config').mkdir()
        shutil.copy2(ROOT / 'config/toolkit.conf', self.project / 'config/toolkit.conf')
        self.generated = self.root / 'generated'
        self.generated.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.mutations = self.root / 'mutations'
        self.mutations.write_text('')
        self.mock('brew', '''case "$*" in
'list --formula --full-name')
 case "$TEST_MODE" in missing) exit 0;; error) exit 2;; slow) echo $$ > "$TEST_PID"; exec sleep 30;; esac
 echo git;;
'list --cask') echo extra-app;;
'info --json=v2 --cask reference-app') echo '{"casks":[]}' ;;
*) echo "brew $*" >> "$TEST_MUTATIONS"; exit 99;; esac''')
        for name in ('sudo', 'defaults', 'killall', 'mas', 'code', 'curl', 'xcode-select'):
            self.mock(name, 'echo "$0 $*" >> "$TEST_MUTATIONS"; exit 99')
        self.temporary = self.root / 'temporary'
        self.temporary.mkdir()
        self.environment = dict(os.environ, TMPDIR=str(self.temporary), HOME=str(self.home), PATH=str(self.bin) + ':' + os.environ['PATH'],
                                TEST_MUTATIONS=str(self.mutations), TEST_MODE='matching', TEST_PID=str(self.root / 'pid'),
                                GIT_CONFIG_NOSYSTEM='1', XDG_CONFIG_HOME=str(self.home / '.config'))
        self.blueprint = self.root / 'blueprint.conf'
        self.write_blueprint()
        (self.generated / 'brew-packages.conf').write_text('git\n')

    def mock(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o700)

    def write_blueprint(self, categories=(), packages='git', casks=''):
        names = ('git-configuration', 'ssh-configuration', 'vscode-settings', 'shell-zsh',
                 'macos-finder', 'macos-dock', 'macos-windows', 'macos-keyboard', 'macos-trackpad', 'macos-screenshots')
        self.blueprint.write_text('[categories]\n' + ''.join(f'{name}="{str(name in categories).lower()}"\n' for name in names) +
                                  f'[homebrew-packages]\n{packages}\n[homebrew-casks]\n{casks}\n[app-store]\n[vscode-extensions]\n[workspace-folders]\n[git-repositories]\n')

    def payload(self, **overrides):
        parameters = {} if "bundle_path" in overrides else dict(generated_dir=str(self.generated), blueprint_path=str(self.blueprint))
        parameters.update(overrides)
        return json.dumps(dict(protocol_version=1, operation_id='compare-test', operation='environment_compare', parameters=parameters)).encode()

    def invoke(self, **overrides):
        before = self.snapshot()
        result = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                input=self.payload(**overrides), env=self.environment, cwd=self.project,
                                capture_output=True, timeout=getattr(self, 'comparison_timeout', 20))
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(sum(e['type'] in ('completed', 'failed', 'cancelled') for e in events), 1)
        self.assertEqual([e['sequence'] for e in events], list(range(1, len(events) + 1)))
        self.assertEqual(self.mutations.read_text(), '')
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.project / 'logs').exists())
        self.assertFalse(list(self.project.rglob('__pycache__')))
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])
        return result, events

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for base in (self.generated, self.home, self.project / 'config') for p in base.rglob('*') if p.is_file()}

    def comparison(self, **overrides):
        result, events = self.invoke(**overrides)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(events[-1]['type'], 'completed')
        self.assertTrue(any(e['type'] == 'execution_event' and e['data']['read_only'] for e in events))
        return next(e['data'] for e in events if e['type'] == 'result')

    def make_bundle(self, secure=False):
        stage = self.root / 'bundle-stage'
        if stage.exists(): shutil.rmtree(stage)
        stage.mkdir()
        shutil.copytree(self.generated, stage / 'generated')
        (stage / 'blueprint.conf').write_text(self.blueprint.read_text() + '[git-configuration]\n')
        if secure:
            (stage / 'secure.age').write_bytes(b'age-encryption.org/v1\nopaque encrypted fixture')
        output = self.root / 'saved.mbt'
        output.unlink(missing_ok=True)
        packed = subprocess.run([sys.executable, str(self.project / 'modules/bundle/bundle.py'), 'pack',
                                str(stage), str(output), str(self.home)], capture_output=True)
        self.assertEqual(packed.returncode, 0, packed.stderr.decode())
        return output

    def ssh_reference(self, payload, *, version=1, partial=False):
        self.write_blueprint(categories=('ssh-configuration',), packages='')
        directory = self.generated / 'ssh'
        directory.mkdir(exist_ok=True, mode=0o700)
        source = directory / 'config.snapshot'
        source.write_bytes((f'# toolkit-ssh-snapshot: {version}\n# status: {"partial" if partial else "ready"}\n'
                            f'# excluded-profiles: {1 if partial else 0}\n\n').encode() + payload)
        source.chmod(0o600)
        (self.home / '.ssh').mkdir(exist_ok=True, mode=0o700)
        for name in ('ssh', 'ssh-add', 'security', 'age'):
            self.mock(name, 'echo "unexpected secure tool" >> "$TEST_MUTATIONS"; exit 99')
        return self.home / '.ssh/config'

    def test_ssh_supported_profile_conformity(self):
        payload = b'Host example\n    HostName example.invalid\n    User git\n'
        target = self.ssh_reference(payload)
        cases = (
            (payload, 'matching'),
            (b'# user comment\nHost example\n User git\n HostName example.invalid\n', 'matching'),
            (payload + b'Host unrelated\n HostName unrelated.invalid\n', 'matching'),
            (b'Host unrelated\n HostName unrelated.invalid\n', 'missing'),
            (payload.replace(b'User git', b'User other'), 'differing'),
            (payload + b' Include other\n', 'unverified'),
            (payload + b' Compression yes\n', 'unverified'),
            (payload + b'Host example\n HostName another.invalid\n', 'unverified'),
        )
        for raw, kind in cases:
            with self.subTest(kind=kind, raw=raw):
                target.write_bytes(raw)
                target.chmod(0o600)
                data = self.comparison()
                self.assertEqual(len(data['comparison_records']), 1)
                self.assertEqual(data['comparison_records'][0]['comparison_kind'], kind)
                self.assertEqual(data['comparison']['counts'][kind], 1)
        target.chmod(0o644)
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unverified'], 1)
        self.assertEqual(data['comparison_records'][0]['reason'], 'external_management')

    def test_ssh_case_variant_aliases_remain_unverified(self):
        for source_alias, target_alias in ((b'example', b'Example'), (b'Example', b'example')):
            payload = b'Host ' + source_alias + b'\n    HostName example.invalid\n'
            target = self.ssh_reference(payload)
            variant = payload.replace(b'Host ' + source_alias, b'Host ' + target_alias)
            for raw, kind in ((payload, 'matching'), (variant, 'unverified'),
                              (variant.replace(b'example.invalid', b'other.invalid'), 'unverified'),
                              (variant + b'    Compression yes\n', 'unverified'),
                              (payload + variant, 'unverified')):
                with self.subTest(source_alias=source_alias, raw=raw):
                    target.write_bytes(raw)
                    target.chmod(0o600)
                    data = self.comparison()
                    self.assertEqual(len(data['comparison_records']), 1)
                    self.assertEqual(data['comparison']['counts'][kind], 1)
                    self.assertEqual(data['comparison']['counts']['missing'], 0)
                    if kind == 'unverified':
                        self.assertEqual(data['comparison_records'][0]['reason'], 'unsupported_predicate')
                        self.assertEqual(data['comparison']['verdict'], 'incomplete')

    def test_ssh_partial_coverage_remains_incomplete(self):
        payload = b'Host example\n    HostName example.invalid\n'
        target = self.ssh_reference(payload, partial=True)
        target.write_bytes(payload)
        target.chmod(0o600)
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual([r['code'] for r in data['records']['diagnostics']], ['partial_source_coverage'])
        self.assertEqual([r['conformity'] for r in data['records']['verification_records']], ['verified'])
        coverage = [r for r in data['records']['coverage_records'] if r['domain'] == 'ssh-configuration']
        self.assertEqual(sorted(r['disposition'] for r in coverage), ['resolved', 'unresolved'])
        unresolved = next(r for r in coverage if r['disposition'] == 'unresolved')
        self.assertEqual(data['records']['diagnostics'][0]['record_id'], unresolved['record_id'])
        target.write_bytes(payload.replace(b'example.invalid', b'different.invalid'))
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual([r['code'] for r in data['records']['diagnostics']].count('partial_source_coverage'), 1)
        self.assertEqual([r['conformity'] for r in data['records']['verification_records']], ['mismatch'])
        self.assertTrue(data['comparison']['also_incomplete'])

    def test_ssh_v2_references_are_not_identity_evidence(self):
        payload = (b'Host example\n    HostName example.invalid\n    IdentityFile ~/.ssh/key\n'
                   b'    IdentityFile /external/other\n    IdentitiesOnly yes\n'
                   b'    AddKeysToAgent no\n    UseKeychain yes\n')
        target = self.ssh_reference(payload, version=2)
        target.write_bytes(payload)
        target.chmod(0o600)
        # Opening the reference would hang/fail: configuration observation must
        # never inspect key material, including public/private pairing.
        os.mkfifo(self.home / '.ssh/key')
        saved = self.make_bundle()
        data = self.comparison(bundle_path=str(saved))
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertIn('prerequisite_unmet', [r['code'] for r in data['records']['diagnostics']])
        self.assertEqual([r['item_id'] for r in data['records']['coverage_records'] if r['disposition'] == 'unresolved'], ['identity-references'])
        self.assertEqual(data['secure_check']['status'], 'absent')
        self.assertNotIn('/external', json.dumps(data))
        target.write_bytes(payload.replace(b'~/.ssh/key', b'~/.ssh/renamed'))
        data = self.comparison(bundle_path=str(saved))
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertTrue(data['comparison']['also_incomplete'])

    def test_ssh_none_and_unsupported_target_coverage(self):
        payload = b'Host example\n    HostName example.invalid\n    IdentityFile none\n'
        target = self.ssh_reference(payload, version=2)
        target.write_bytes(payload)
        target.chmod(0o600)
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 0)
        target.write_bytes(payload + b'Host unrelated\n HostName unrelated.invalid\n ProxyJump jump\n')
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertIn('unsupported_predicate', [r['code'] for r in data['records']['diagnostics']])

    def test_ssh_merge_and_uncertain_publication_check(self):
        payload = b'Host added\n    HostName added.invalid\n'
        target = self.ssh_reference(payload)
        original = b'# preserved\nHost existing\n  HostName existing.invalid\n'
        target.write_bytes(original); target.chmod(0o600)
        home = str(self.home.resolve())
        ssh_merge.publish(payload, home, ssh_merge.evidence(home))
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 0)
        self.assertTrue(target.read_bytes().startswith(original))
        pending = target.parent / '.macseed-ssh-pending-fixture'
        pending.mkdir(mode=0o700)
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unverified'], 1)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual(data['comparison_records'][0]['reason'], 'operation_failed')

    def test_bundle_reference_selection_and_read_only(self):
        path = self.make_bundle(secure=True)
        data = self.comparison(bundle_path=str(path))
        self.assertEqual(data['secure_check'], dict(version=1, bundle_id=hashlib.sha256(path.read_bytes()).hexdigest(), status='available'))
        self.assertFalse(any(r['domain'] == 'secure-ssh-identities' for r in data['comparison_records']))
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertFalse(data['publication_occurred'])
        self.environment['TEST_MODE'] = 'missing'
        self.assertEqual(self.comparison(bundle_path=str(path))['comparison']['counts']['missing'], 1)
        self.environment['TEST_MODE'] = 'error'
        self.assertEqual(self.comparison(bundle_path=str(path))['comparison']['verdict'], 'incomplete')
        self.environment['TEST_MODE'] = 'matching'
        # Full inventory is not selected scope; retain completeness for extras.
        self.write_blueprint(packages='', casks='')
        inventory = self.generated / 'brew-casks.conf'
        inventory.write_text('reference-app\n')
        marker = self.generated / 'provenance/homebrew-casks.sha256'
        marker.parent.mkdir()
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertFalse(data['comparison_records'])
        self.assertFalse(any(r['domain'] == 'homebrew-casks' and r['disposition'] == 'resolved'
                             for r in data['records']['coverage_records']))
        self.assertEqual(data['extra']['items'], [])
        self.assertEqual(data['extra']['domains'][0]['reason'], 'category_excluded')
        self.write_blueprint(packages='', casks='reference-app')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['extra']['items'], [{'domain': 'homebrew-casks', 'item_id': 'extra-app'}])
        # Selected subset remains narrowed even with full source inventory.
        self.write_blueprint(packages='git')
        (self.generated / 'brew-packages.conf').write_text('git\nwget\n')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual([r['item_id'] for r in data['comparison_records']], ['git'])
        self.write_blueprint(categories=('vscode-settings',), packages='')
        (self.generated / 'vscode').mkdir()
        (self.generated / 'vscode/settings.json').write_text('{"secret":"reference-token"}')
        target = self.home / 'Library/Application Support/Code/User'
        target.mkdir(parents=True)
        (target / 'settings.json').write_text('{"secret":"current-token"}')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertNotIn('reference-token', json.dumps(data))

    def test_bundle_app_store_presentation_names(self):
        self.write_blueprint(packages='')
        self.blueprint.write_text(self.blueprint.read_text().replace('[app-store]\n', '[app-store]\n1136220934\n'))
        (self.generated / 'appstore.conf').write_text('1136220934|Infuse\n')
        self.mock('mas', '[[ "$*" == list ]] || exit 99; echo "1136220934 Infuse (8.0)"')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['reference_presentation']['app_store_names'], {'1136220934': 'Infuse'})
        self.assertEqual(data['comparison_records'][0]['item_id'], '1136220934')
        self.assertTrue(any(g['id'] == 'Applications' and 'app-store' in g['domains']
                            for g in data['reference_presentation']['groups']))

    def test_telegram_cask_does_not_satisfy_selected_app_store_requirement(self):
        self.write_blueprint(packages='', casks='telegram')
        self.blueprint.write_text(self.blueprint.read_text().replace('[app-store]\n', '[app-store]\n747648890\n'))
        (self.generated / 'brew-casks.conf').write_text('telegram\n')
        (self.generated / 'appstore.conf').write_text('747648890|Telegram\n')
        app = self.home / 'Applications/Telegram.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'ru.keepcoder.Telegram', 'CFBundleExecutable': 'Telegram'}))
        executable = app / 'Contents/MacOS/Telegram'
        executable.write_text('#!/bin/sh\n')
        executable.chmod(0o700)
        prefix = self.root / 'brew'
        prefix.mkdir()
        metadata = self.root / 'cask.json'
        metadata.write_text(json.dumps({'casks': [{
            'token': 'telegram', 'installed': '1.0', 'tap': 'homebrew/cask',
            'disabled': False, 'version': '1.0', 'sha256': 'a' * 64,
            'url': 'https://example.invalid/telegram.dmg',
            'artifacts': [{'app': ['Telegram.app'], 'target': str(app)}]}]}))
        self.environment.update(TEST_CASK_METADATA=str(metadata), TEST_BREW_PREFIX=str(prefix))
        self.mock('brew', '''case "$*" in
'info --json=v2 --cask telegram') cat "$TEST_CASK_METADATA";;
'--prefix') echo "$TEST_BREW_PREFIX";;
'list --cask') echo telegram;;
*) echo "brew $*" >> "$TEST_MUTATIONS"; exit 99;; esac''')
        self.mock('mas', '[[ "$*" == list ]] || exit 99; exit 0')
        for parameters in ({}, {'bundle_path': str(self.make_bundle())}):
            data = self.comparison(**parameters)
            kinds = {(r['domain'], r['item_id']): r['comparison_kind'] for r in data['comparison_records']}
            self.assertEqual(kinds, {('homebrew-casks', 'telegram'): 'matching', ('app-store', '747648890'): 'missing'})
            self.assertEqual(data['comparison']['counts']['matching'], 1)
            self.assertEqual(data['comparison']['counts']['missing'], 1)
            self.assertEqual(data['comparison']['verdict'], 'differences_detected')
            self.assertNotIn('effective_selection', data)
            self.assertNotIn('application_duplicates', data)

    def test_bundle_repository_display_labels_keep_diagnostics_private(self):
        self.write_blueprint(packages='')
        names = ['macseed', 'bootstrap-test', 'private/name']
        self.blueprint.write_text(self.blueprint.read_text().replace('[git-repositories]\n', '[git-repositories]\n' + '\n'.join(names) + '\n'))
        workspace = self.generated / 'workspace'
        workspace.mkdir()
        (workspace / 'repositories.conf').write_text(''.join(
            f'[{name}]\nNAME="{name}"\nPATH="{self.home}/Projects/{index}/same"\nREMOTE="https://example.invalid/repo.git"\nDEFAULT_BRANCH="main"\nCURRENT_BRANCH="main"\nHAS_UNCOMMITTED_CHANGES="false"\nHAS_VSCODE_FOLDER="false"\nHAS_SETTINGS="false"\nHAS_TASKS="false"\nHAS_LAUNCH="false"\nHAS_EXTENSIONS="false"\n'
            for index, name in enumerate(names)))
        data = self.comparison(bundle_path=str(self.make_bundle()))
        key = lambda name: 'opaque:' + hashlib.sha256(name.encode()).hexdigest()
        self.assertEqual(data['reference_presentation']['repository_labels'], {key(name): name for name in names[:2]})
        self.assertEqual(data['comparison']['counts']['missing'], 3)
        self.assertEqual(data['comparison']['counts']['unverified'], 6)
        self.assertEqual(data['comparison']['verdict'], 'differences_detected')
        self.assertEqual(len(data['comparison_records']), 9)
        raw = json.dumps({'records': data['records'], 'comparison_records': data['comparison_records']})
        for name in names: self.assertNotIn(name, raw)
        self.assertNotIn(str(self.home), json.dumps(data))
        self.assertTrue(all(row['item_id'].startswith('opaque:') for row in data['comparison_records']))

    def test_bundle_macos_labels_reuse_capture_definitions(self):
        self.write_blueprint(categories=('macos-dock',), packages='')
        directory = self.generated / 'macos'
        directory.mkdir()
        (directory / 'dock.conf').write_text('com.apple.dock|autohide|bool|true\ncom.apple.dock|magnification|bool|false\n')
        self.mock('defaults', '[[ "$1" == read ]] || exit 99; [[ "$3" == autohide ]] && echo 1 || echo 0')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['reference_presentation']['setting_labels']['macos-dock'], {
            'com.apple.dock/autohide': 'Auto-hide', 'com.apple.dock/magnification': 'Magnification'})

    def test_bundle_invalid_unsafe_and_changed(self):
        path = self.make_bundle()
        for parameters in ({'bundle_path': 'relative'}, {'bundle_path': str(path), 'generated_dir': str(self.generated)}):
            result, events = self.invoke(**parameters)
            self.assertEqual(events[-1]['data']['code'], 'invalid_request')
        alias = self.root / 'alias.mbt'
        alias.symlink_to(path)
        self.assertEqual(self.invoke(bundle_path=str(alias))[1][-1]['data']['code'], 'bundle_invalid')
        self.assertEqual(self.invoke(bundle_path=str(self.root / 'absent.mbt'))[1][-1]['data']['code'], 'bundle_unavailable')
        path.write_bytes(b'corrupted archive')
        self.assertEqual(self.invoke(bundle_path=str(path))[1][-1]['data']['code'], 'bundle_invalid')
        # Mutation of the reference during observation cannot publish a clean result.
        path = self.make_bundle()
        self.environment['TEST_BUNDLE'] = str(path)
        self.mock('brew', 'echo changed >> "$TEST_BUNDLE"; echo git')
        result, events = self.invoke(bundle_path=str(path))
        self.assertEqual(events[-1]['data']['code'], 'reference_changed')
        self.assertFalse(any(e['type'] == 'result' for e in events))

    def test_bundle_cancellation_cleanup(self):
        path = self.make_bundle()
        original = self.payload
        self.payload = lambda **kwargs: original(bundle_path=str(path))
        before = path.read_bytes()
        self.test_cancellation_owned_group()
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])
        self.environment['TEST_MODE'] = 'matching'
        self.comparison(bundle_path=str(path))

    def test_cancel_during_bundle_validation(self):
        path = self.make_bundle()
        before = path.read_bytes()
        adapter = self.project / 'modules/core/application-interface/core.py'
        original = adapter.read_text()
        for boundary in ('                bundle.inspect_bundle(source, os.environ["HOME"])',
                         '                bundle.unpack(source, stage, os.environ["HOME"], workspace_preview=True)'):
            self.assertIn(boundary, original)
            partial_stage = '                (stage / "partial-fixture").write_bytes(b"fixture")\n' if 'unpack' in boundary else ''
            adapter.write_text(original.replace(boundary,
                partial_stage + '                os.kill(os.getpid(), signal.SIGTERM)\n' + boundary))
            result, events = self.invoke(bundle_path=str(path))
            self.assertEqual(result.returncode, 130)
            self.assertEqual(events[-1]['type'], 'cancelled')
            self.assertEqual(path.read_bytes(), before)
        adapter.write_text(original)
        self.comparison(bundle_path=str(path))

    def inject_after_cancel(self, fault):
        # Wrap the completed operation, not a textual return branch: cancel()
        # can finish through several paths after stopping and collecting readers.
        marker = self.root / 'cancel-fault-fired'
        execution = self.project / 'modules/core/application-interface/execution.py'
        execution.write_text(execution.read_text() +
            '\n_fixture_cancel = OwnedBootstrap.cancel\n'
            'def _cancel_with_fault(self):\n'
            '    result = _fixture_cancel(self)\n'
            '    assert not Path(self.item_state.name).exists()\n'
            f'    Path({str(marker)!r}).write_text(str(result))\n' +
            ''.join('    ' + line + '\n' for line in fault.splitlines()) +
            'OwnedBootstrap.cancel = _cancel_with_fault\n')
        return marker

    def test_cancel_cleanup_error_is_not_bundle_unavailable(self):
        path = self.make_bundle()
        before = path.read_bytes()
        marker = self.inject_after_cancel(
            'raise FileNotFoundError(2, "fixture staging vanished", self.item_state.name)')
        payload = self.payload
        self.payload = lambda **kwargs: payload(bundle_path=str(path))
        try:
            self.test_cancellation_owned_group(expected_code='comparison_unavailable')
        finally:
            self.assertEqual(marker.read_text(), '130', 'Cleanup fault must execute after cancellation')
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])

    def deny_compare_descendant_kill(self):
        execution = self.project / 'modules/core/application-interface/execution.py'
        marker = self.root / 'kill-denied'
        # Inject at the dependency actually used by cancel. The first stop sees
        # real PermissionErrors; finally reap our disposable readers with the
        # real implementation, while preserving the unconfirmed result.
        execution.write_text(execution.read_text() + f'''
_fixture_stop = ProcessTree.stop
def _fixture_denied_stop(self):
    original_kill = os.kill
    def denied_kill(pid, sig):
        Path({str(marker)!r}).write_text('denied')
        raise PermissionError(1, 'fixture descendant stop denied')
    try:
        os.kill = denied_kill
        stopped = _fixture_stop(self)
    finally:
        os.kill = original_kill
        if not _fixture_stop(self):
            raise RuntimeError('fixture reader cleanup failed')
    return stopped
ProcessTree.stop = _fixture_denied_stop
''')
        return marker

    def test_cancel_descendant_kill_denied(self):
        marker = self.deny_compare_descendant_kill()
        self.test_cancellation_owned_group()
        self.assertEqual(marker.read_text(), 'denied', 'Owned stop must reach kill denial')

    def test_cancel_does_not_hide_source_error(self):
        path = self.make_bundle()
        # Confirm source-error precedence even with uncertain cleanup evidence;
        # the real owned readers are already stopped before injecting this state.
        marker = self.inject_after_cancel(
            'self.unknown_consequences = True\n'
            f'source = Path({str(path)!r})\nsource.unlink()\nsource.read_bytes()')
        payload = self.payload
        self.payload = lambda **kwargs: payload(bundle_path=str(path))
        try:
            self.test_cancellation_owned_group(expected_code='bundle_unavailable')
        finally:
            self.assertEqual(marker.read_text(), '130', 'Source fault must execute after cancellation')

    def test_matching_and_projections(self):
        data = self.comparison()
        self.assertTrue(data['read_only'])
        self.assertFalse(data['target_mutation_may_have_started'])
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['verdict'], 'no_differences_detected')
        self.assertEqual(data['comparison_records'][0]['comparison_kind'], 'matching')
        self.assertIsNone(data['comparison_records'][0]['reason'])
        self.assertEqual(data['records']['verification_records'][0]['conformity'], 'verified')
        self.assertEqual(data['verification']['verdict'], 'selected_requirements_verified')
        self.assertEqual({r['disposition'] for r in data['records']['coverage_records']}, {'resolved', 'excluded'})
        self.assertFalse(data['records']['operation_records'])

    def test_missing(self):
        self.environment['TEST_MODE'] = 'missing'
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['missing'], 1)
        self.assertEqual(data['comparison_records'][0]['reason'], 'confirmed_mismatch')
        self.assertEqual(data['comparison']['verdict'], 'differences_detected')
        self.assertEqual(data['verification']['mismatch_count'], 1)

    def test_differing_and_sensitive_contents(self):
        self.write_blueprint(categories=('vscode-settings',))
        (self.generated / 'vscode').mkdir()
        (self.generated / 'vscode/settings.json').write_text('{"secret":"reference-token"}')
        target = self.home / 'Library/Application Support/Code/User'
        target.mkdir(parents=True)
        (target / 'settings.json').write_text('{"secret":"current-token"}')
        data = self.comparison()
        row = next(r for r in data['comparison_records'] if r['domain'] == 'vscode-settings')
        self.assertEqual(row['comparison_kind'], 'differing')
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertNotIn('reference-token', json.dumps(data))
        self.assertNotIn('current-token', json.dumps(data))
        self.assertNotIn(str(self.root), json.dumps(data))

    def test_observation_failure_is_unverified(self):
        self.environment['TEST_MODE'] = 'error'
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unverified'], 1)
        self.assertEqual(data['comparison_records'][0]['reason'], 'observation_failed')
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual(data['verification']['status'], 'complete')

    def test_unresolved_selection(self):
        self.write_blueprint(packages='unknown')
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['records']['coverage_records'][0]['disposition'], 'unresolved')
        self.assertEqual(data['records']['diagnostics'][0]['code'], 'selected_input_unresolved')

    def test_invalid_reference(self):
        self.blueprint.write_text('malformed!\n')
        result, events = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_invalid')
        self.assertEqual(events[-1]['data']['comparison']['status'], 'incomplete')

    def test_invalid_domain_input(self):
        (self.generated / 'brew-packages.conf').write_text('invalid value!\n')
        result, events = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_invalid')

    def test_unavailable_and_request_validation(self):
        for overrides, code in (({'generated_dir': str(self.root / 'absent')}, 'reference_unavailable'),
                                ({'blueprint_path': str(self.root / 'absent')}, 'reference_unavailable'),
                                ({'generated_dir': 'relative'}, 'invalid_request')):
            with self.subTest(overrides=overrides):
                result, events = self.invoke(**overrides)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(events[-1]['data']['code'], code)

    def test_extra_provenance(self):
        self.write_blueprint(packages='', casks='stale')
        inventory = self.generated / 'brew-casks.conf'
        inventory.write_text('reference-app\n')
        data = self.comparison()
        self.assertEqual(data['extra']['domains'][0]['status'], 'unavailable')
        provenance = self.generated / 'provenance'
        provenance.mkdir()
        marker = provenance / 'homebrew-casks.sha256'
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        data = self.comparison()
        self.assertEqual(data['extra']['items'], [{'domain': 'homebrew-casks', 'item_id': 'extra-app'}])
        self.assertEqual(data['comparison']['counts']['extra'], 1)
        marker.write_text('complete ' + '0' * 64 + '\n')
        self.assertEqual(self.comparison()['extra']['items'], [])
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        self.mock('brew', 'echo "invalid inventory value"')
        data = self.comparison()
        self.assertEqual(data['extra']['items'], [])
        self.assertEqual(data['extra']['domains'][0]['reason'], 'invalid_target_inventory')

    def test_determinism_and_bounds(self):
        first = self.comparison()
        second = self.comparison()
        for data in (first, second):
            for row in data['records']['verification_records']:
                row.pop('observed_at')
        self.assertEqual(first, second)
        sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
        from execution import OwnedBootstrap
        from reporting import MAX_RECORDS, item
        self.assertTrue(item('git-repositories', 'https://user:token@server/private').startswith('opaque:'))
        owned = OwnedBootstrap.__new__(OwnedBootstrap)
        owned.mode = '--application-compare'
        owned.report_count = MAX_RECORDS
        owned.details = {'status': 'partial'}
        owned.comparison_records = []
        owned._record({'kind': 'comparison', 'domain': 'homebrew-packages', 'item_id': 'git'})
        self.assertEqual(owned.details['status'], 'truncated')
        self.assertEqual(owned.comparison_records, [])

    def test_invalid_and_truncated_reporting_fails_closed(self):
        entry = self.project / 'bootstrap.sh'
        for kind in ('invalid', 'truncated'):
            entry.write_text("#!/usr/bin/env python3\n" + """
import json, os
fd = int(os.environ['MACSEED_REPORT_FD'])
def write(row):
    os.write(fd, (json.dumps(row) + '\\n').encode())
""" + ("write({'kind': 'comparison', 'unexpected': 'raw secret'})\n" if kind == 'invalid' else """
for i in range(8193):
    write({'kind': 'coverage', 'record_id': 'c:' + str(i), 'domain': 'homebrew-packages',
           'item_id': 'git', 'disposition': 'resolved', 'source_status': 'unknown'})
""") + "write({'kind': 'details_complete'})\n")
            result, events = self.invoke()
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events[-1]['data']['code'], 'comparison_reporting_incomplete')
            self.assertEqual(events[-1]['data']['records']['status'], kind)
            self.assertNotIn('raw secret', result.stdout.decode())
            self.assertLessEqual(len(events[-1]['data']['records']['coverage_records']), 8192)

    def test_cancellation_owned_group(self, expected_code=None):
        self.environment['TEST_MODE'] = 'slow'
        process = subprocess.Popen(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=self.environment, cwd=self.project, start_new_session=True)
        process.stdin.write(self.payload())
        process.stdin.close()
        process.stdin = None
        pid_file = self.root / 'pid'
        deadline = time.monotonic() + 10
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertTrue(pid_file.exists())
        os.killpg(process.pid, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 2 if expected_code else 130, stderr)
        events = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual(sum(e['type'] in ('completed', 'failed', 'cancelled') for e in events), 1)
        self.assertEqual(events[-1]['type'], 'failed' if expected_code else 'cancelled')
        if expected_code:
            self.assertEqual(events[-1]['data']['code'], expected_code)
        pid = int(pid_file.read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(.05)
        else:
            self.fail('Owned reader survived cancellation')
        self.assertEqual(self.mutations.read_text(), '')

    def test_cancellation_stops_term_ignoring_grandchild(self):
        code = ("import os, signal, time; from pathlib import Path; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "Path(os.environ['TEST_PID']).write_text(str(os.getpid())); time.sleep(30)")
        path = self.bin / 'brew'
        path.write_text('#!/usr/bin/env python3\nimport subprocess, sys\n' +
                        'child = subprocess.Popen([sys.executable, "-c", ' + repr(code) + '])\nchild.wait()\n')
        self.test_cancellation_owned_group()

    def test_production_operation_support_and_unknown_difference(self):
        entry = self.project / 'bootstrap.sh'
        marker = 'source modules/verification/comparison.sh\n'
        entry.write_text(entry.read_text().replace(marker, marker + """
verify_brew_packages() {
    verification_coverage homebrew-packages git resolved unknown
    verification_operation homebrew-packages git inspect success
    verification_record homebrew-packages git installed mismatch supported '2026-10-01T00:00:00Z'
    verification_diagnostic "$GV_LAST_REF" confirmed_mismatch warning observation
    verification_unsupported homebrew-packages other unsupported_fixture
    verification_coverage homebrew-packages empty no_requirement observed_absent
}
"""))
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unknown_difference'], 1)
        self.assertEqual(data['comparison']['counts']['unsupported'], 1)
        self.assertEqual(data['comparison']['counts']['unverified'], 2)
        self.assertEqual({r['reason'] for r in data['comparison_records']}, {'unknown_difference', 'unsupported_predicate'})
        self.assertEqual(data['records']['operation_records'][0]['outcome'], 'success')
        self.assertEqual(data['verification']['verdict'], 'differences_detected')
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertIn('no_requirement', {r['disposition'] for r in data['records']['coverage_records']})

    def test_git_identity_privacy(self):
        self.write_blueprint(categories=('git-configuration',), packages='')
        (self.generated / 'git.conf').write_text('[user]\nname = Private Reference\nemail = private-reference@example.invalid\n')
        (self.home / '.gitconfig').write_text('[user]\nname = Private Target\nemail = private-target@example.invalid\n')
        data = self.comparison()
        raw = json.dumps(data)
        for forbidden in ('Private Reference', 'Private Target', 'private-reference', 'private-target', str(self.root)):
            self.assertNotIn(forbidden, raw)
        self.assertEqual(data['comparison']['counts']['differing'], 2)

    def test_empty_scope_and_explicit_no_blueprint(self):
        self.write_blueprint(packages='')
        self.assertEqual(self.comparison()['comparison']['verdict'], 'no_comparable_requirements')
        # An ambient Blueprint cannot substitute for explicit null.
        self.environment['BLUEPRINT_FILE'] = str(self.blueprint)
        (self.project / 'config/blueprint.conf').write_text('malformed ambient blueprint!')
        result, events = self.invoke(blueprint_path=None)
        self.assertFalse(any(e.get('data', {}).get('code') == 'reference_invalid' and
                             any(r['domain'] == 'blueprint' for r in e['data'].get('records', {}).get('coverage_records', [])) for e in events))
        self.assertTrue(any(r['domain'] == 'homebrew-packages' for e in events if e['type'] == 'result'
                            for r in e['data']['comparison_records']))

    def test_cli_compatibility(self):
        self.environment.update(BLUEPRINT_FILE=str(self.blueprint), BLUEPRINT_GENERATED_DIR=str(self.generated))
        result = subprocess.run(['./bootstrap.sh', '--compare'], cwd=self.project, env=self.environment, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(b'No differences detected', result.stdout)
        self.assertIn(b'Matching: 1; missing: 0; differing: 0; unverified: 0', result.stdout)
        self.assertNotIn(b'comparison_records', result.stdout)
        self.assertEqual(self.mutations.read_text(), '')


spec = importlib.util.spec_from_file_location('topology_fixture', ROOT / 'scripts/test-restore-prepare.py')
topology_fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(topology_fixture)


class TopologyCompareTests(unittest.TestCase):
    """Same native Git fixtures/inspector as Restore; only read-only Compare runs."""
    comparison_timeout = 60
    mock = CompareTests.mock
    write_blueprint = CompareTests.write_blueprint
    payload = CompareTests.payload
    invoke = CompareTests.invoke
    comparison = CompareTests.comparison
    configure = topology_fixture.TopologyPreviewTests.configure
    pack = topology_fixture.RestorePrepareTests.pack

    def setUp(self):
        CompareTests.setUp(self)
        self.home = self.home.resolve()
        self.environment['HOME'] = str(self.home)
        self.environment['GIT_CONFIG_GLOBAL'] = '/dev/null'
        sys.path.insert(0, str(ROOT / 'scripts'))
        import workspace_fixture
        self.fixture = workspace_fixture
        self.contract = topology_fixture.bundle.workspace_contract()
        self.paths = ['Projects/base', 'Projects/team/demo', 'Projects/other/demo']
        self.base, self.oid = workspace_fixture.repository(self.home)
        workspace_fixture.linked(self.base, self.home / self.paths[1], self.oid, 'feature')
        workspace_fixture.linked(self.base, self.home / self.paths[2], self.oid, '')
        self.branches, self.parents = ['main', 'feature', ''], [0, 0, 0]
        self.git = shutil.which('git')
        self.environment['TEST_REAL_GIT'] = self.git
        self.mock('git', '''for word in "$@"; do
case "$word" in clone|fetch|checkout|prune|remove|reset|clean|switch|add|update-ref)
 echo mutation >> "$TEST_MUTATIONS"; exit 99;; esac
done
exec "$TEST_REAL_GIT" "$@"''')
        for name in ('age', 'ssh', 'ssh-add'):
            self.mock(name, 'echo "$0" >> "$TEST_MUTATIONS"; exit 99')
        self.stage = self.root / 'bundle-stage'
        self.stage.mkdir()
        self.archive = self.root / 'saved.mbt'
        self.configure()
        self.generated = self.stage / 'generated'
        self.blueprint = self.stage / 'blueprint.conf'

    def snapshot(self):
        result = {}
        for base in (self.generated, self.home, self.project / 'config'):
            for path in base.rglob('*'):
                info = path.lstat()
                value = os.readlink(path) if path.is_symlink() else path.read_bytes() if path.is_file() else None
                result[(base.name, str(path.relative_to(base)))] = (info.st_mode, info.st_ino, info.st_mtime_ns, value)
        return result

    def compare(self):
        before = self.archive.read_bytes(), self.blueprint.read_bytes()
        data = self.comparison(bundle_path=str(self.archive))
        self.assertEqual(before, (self.archive.read_bytes(), self.blueprint.read_bytes()))
        self.assertEqual(data['records']['operation_records'], [])
        rows = data['comparison_records']
        owners = data['records']['verification_records']
        self.assertEqual(len(rows), len(owners))
        self.assertEqual(len({(r['domain'], r['item_id'], r['predicate']) for r in owners}), len(owners))
        for row in rows:
            self.assertTrue(any(all(owner[key] == row[key] for key in ('record_id', 'domain', 'item_id')) for owner in owners))
        for kind in ('matching', 'missing', 'differing', 'unverified'):
            self.assertEqual(data['comparison']['counts'][kind], sum(row['comparison_kind'] == kind for row in rows))
        self.assertEqual(data['comparison']['counts']['unsupported'], sum(row['support'] == 'unsupported' for row in rows))
        for private in (str(self.home), '/Users/source', 'https://example.invalid', self.oid, 'private-ciphertext'):
            self.assertNotIn(private, json.dumps(data))
        self.assertFalse(data['publication_occurred'])
        self.assertFalse(data['target_mutation_may_have_started'])
        return data

    def git_rows(self, data):
        return [row for row in data['comparison_records'] if row['domain'] == 'git-repositories']

    def git_row(self, data, index):
        identity = 'opaque:' + hashlib.sha256(self.ids[index].encode()).hexdigest()
        return next(row for row in self.git_rows(data) if row['item_id'] == identity)

    def remove_linked(self, index):
        path = self.home / self.paths[index]
        admin = Path((path / '.git').read_text().strip()[8:])
        shutil.rmtree(path)
        shutil.rmtree(admin)

    def descriptor(self, *, folder_only=False, count=1):
        if folder_only:
            self.configure(folders=['Projects/data'])
        sections, categories = topology_fixture.bundle.parse_blueprint(self.blueprint.read_bytes())
        if folder_only:
            sections['git-repositories'] = []
        self.descriptor_id = self.contract.identity('workspace', 'Projects/view.code-workspace')
        folders = ([dict(domain='workspace-folders', item_id='Projects/data', subpath='', name='Data')]
                   if folder_only else [dict(domain='git-repositories', item_id=self.ids[2], subpath='', name='Code')])
        descriptors = [dict(item_id=self.descriptor_id, path='~/Projects/view.code-workspace', folders=folders)]
        if count == 2:
            descriptors.append(dict(item_id=self.contract.identity('workspace', 'Projects/other.code-workspace'),
                                    path='~/Projects/other.code-workspace', folders=folders))
        sections['vscode-workspaces'] = [row['item_id'] for row in descriptors]
        raw = '[categories]\n' + ''.join(f'{key}="{str(value).lower()}"\n' for key, value in categories.items())
        raw += ''.join('\n[' + domain + ']\n' + ''.join(item + '\n' for item in items)
                       for domain, items in sections.items() if domain != 'categories')
        self.blueprint.write_text(raw)
        (self.stage / self.contract.VSCODE).write_text(json.dumps(dict(contract=1, items=descriptors)))
        self.archive.unlink()
        self.pack(secure=True)
        return self.home / 'Projects/view.code-workspace'

    def test_matching_privacy_stable_identities_and_counts(self):
        first = self.compare()
        self.assertEqual(first['comparison']['verdict'], 'no_differences_detected')
        self.assertEqual(first['comparison']['counts']['matching'], 5)
        self.assertEqual({row['predicate'] for row in first['records']['verification_records']}, {'topology', 'directory'})
        self.assertEqual(len(self.git_rows(first)), 3)
        self.assertEqual(first['reference_presentation']['repository_labels'][self.git_row(first, 1)['item_id']], 'demo')
        self.assertEqual(first['reference_presentation']['repository_labels'][self.git_row(first, 2)['item_id']], 'demo')
        self.assertNotEqual(self.git_row(first, 1)['item_id'], self.git_row(first, 2)['item_id'])
        second = self.compare()
        for key in ('comparison', 'comparison_records', 'reference_presentation'):
            self.assertEqual(first[key], second[key])

    def test_missing_base_does_not_match_dependents(self):
        shutil.rmtree(self.home / 'Projects')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['comparison_kind'], 'missing')
        for index in (1, 2):
            self.assertEqual((self.git_row(data, index)['comparison_kind'], self.git_row(data, index)['reason']),
                             ('unverified', 'prerequisite_unmet'))
        self.assertEqual(data['comparison']['verdict'], 'differences_detected')
        self.assertTrue(data['comparison']['also_incomplete'])

    def test_missing_linked_and_independent_clone_relationship(self):
        self.remove_linked(1)
        self.assertEqual(self.git_row(self.compare(), 1)['comparison_kind'], 'missing')
        self.fixture.repository(self.home, self.paths[1])
        data = self.compare()
        self.assertEqual(self.git_row(data, 1)['comparison_kind'], 'differing')
        self.assertFalse(data['comparison']['also_incomplete'])

    def test_origin_and_head_differences_are_not_missing(self):
        config = self.base / '.git/config'
        original = config.read_text()
        config.write_text(original.replace('repo.git', 'different.git'))
        self.assertEqual(self.git_row(self.compare(), 0)['comparison_kind'], 'differing')
        config.write_text(original)
        (self.base / '.git/refs/heads/other').write_text(self.oid + '\n')
        (self.base / '.git/HEAD').write_text('ref: refs/heads/other\n')
        self.assertEqual(self.git_row(self.compare(), 0)['comparison_kind'], 'differing')
        (self.base / '.git/HEAD').write_text('ref: refs/heads/main\n')
        tree = self.fixture.object_file(self.base / '.git', 'tree', b'')
        other = self.fixture.object_file(self.base / '.git', 'commit',
            f'tree {tree}\nauthor A <a@b> 2 +0000\ncommitter A <a@b> 2 +0000\n\nother\n'.encode())
        # Named OID is diagnostic; detached OID is an exact requirement.
        (self.base / '.git/refs/heads/main').write_text(other + '\n')
        admin = Path((self.home / self.paths[2] / '.git').read_text().strip()[8:])
        (admin / 'HEAD').write_text(other + '\n')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['comparison_kind'], 'matching')
        self.assertEqual(self.git_row(data, 2)['comparison_kind'], 'differing')

    def test_nested_checkout_dependency(self):
        nested = 'Projects/base/nested'
        self.fixture.repository(self.home, nested)
        self.paths.append(nested); self.branches.append('main'); self.parents.append(3)
        self.configure()
        self.assertEqual(self.git_row(self.compare(), 3)['comparison_kind'], 'matching')
        (self.base / '.git/config').write_text('[core]\nrepositoryformatversion=0\nbare=false\n')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['comparison_kind'], 'differing')
        self.assertEqual(self.git_row(data, 3)['comparison_kind'], 'unverified')

    def test_descriptor_match_missing_difference_and_dependency(self):
        path = self.descriptor(count=2)
        def row(data):
            return next(row for row in data['comparison_records'] if row['item_id'] == self.descriptor_id)
        self.assertEqual(row(self.compare())['comparison_kind'], 'missing')
        path.write_text('{// kept\n"folders":[{"path":"other/demo","name":"Code",}],"settings":{"private":"retained"}}')
        path.with_name('other.code-workspace').write_text('{"folders":[{"path":"other/demo","name":"Different"}]}')
        data = self.compare()
        self.assertEqual(row(data)['comparison_kind'], 'matching')
        self.assertEqual(row(data)['item_id'], self.descriptor_id)
        self.assertEqual(data['reference_presentation']['workspace_labels'][self.descriptor_id], 'view.code-workspace')
        self.assertTrue(any(r['predicate'] == 'folder_relationships' for r in data['records']['verification_records']))
        self.assertEqual(next(r for r in data['comparison_records'] if r['domain'] == 'vscode-workspaces'
                              and r['item_id'] != self.descriptor_id)['comparison_kind'], 'differing')
        self.remove_linked(2)
        self.assertEqual(row(self.compare())['comparison_kind'], 'unverified')

    def test_descriptor_folder_only_and_symlink_conflict(self):
        path = self.descriptor(folder_only=True)
        (self.home / 'Projects/data').mkdir()
        self.mock('git', 'echo git >> "$TEST_MUTATIONS"; exit 99')
        path.write_text('{"folders":[{"path":"data","name":"Data"}]}')
        data = self.compare()
        self.assertEqual(data['comparison']['counts']['matching'], 2)
        path.unlink(); path.symlink_to(self.home / 'Projects/data')
        self.assertEqual(next(r for r in self.compare()['comparison_records'] if r['domain'] == 'vscode-workspaces')['comparison_kind'], 'unverified')
        path.unlink()
        path.write_text('{"folders":[{"uri":"vscode-remote://private/path"}]}')
        unsupported = next(r for r in self.compare()['comparison_records'] if r['domain'] == 'vscode-workspaces')
        self.assertEqual((unsupported['comparison_kind'], unsupported['support']), ('unverified', 'unsupported'))
        path.write_text('{broken JSON')
        unreadable = next(r for r in self.compare()['comparison_records'] if r['domain'] == 'vscode-workspaces')
        self.assertEqual((unreadable['comparison_kind'], unreadable['reason']), ('unverified', 'observation_failed'))

    def test_capability_and_observation_failures(self):
        self.mock('git', 'case " $* " in *" worktree -h "*) echo "--porcelain"; exit 129;; esac\nexec "$TEST_REAL_GIT" "$@"')
        data = self.compare()
        self.assertEqual(data['comparison']['counts']['unsupported'], 3)
        self.assertTrue(all(row['comparison_kind'] == 'unverified' for row in self.git_rows(data)))
        self.mock('git', 'case " $* " in *" status "*) exit 2;; esac\nexec "$TEST_REAL_GIT" "$@"')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['reason'], 'observation_failed')
        self.assertEqual(data['comparison']['counts']['unsupported'], 0)

    def test_changed_evidence_never_retains_match_or_difference(self):
        sys.path.insert(0, str(ROOT / 'modules/bootstrap/workspace'))
        import topology_preview
        files = topology_fixture.bundle.validate_archive(self.archive)
        first = dict(domain='git-repositories', item_id='1', checkout_id=self.ids[0],
                     disposition='satisfied', action='none', reason=None, difference='unknown')
        second = dict(first, disposition='conflict', difference='different')
        with patch.object(topology_preview.Inspector, 'plan', side_effect=[[first], [second]]):
            rows = list(topology_preview.comparison_records(files, str(self.home), None))
        self.assertEqual(rows[0][3:], ('2', 'supported', 'observation_failed', 'unknown'))

    def test_live_changed_observation_and_locked_metadata(self):
        self.paths, self.branches, self.parents = self.paths[:1], self.branches[:1], [0]
        self.configure()
        self.environment['TEST_OBSERVATIONS'] = str(self.root / 'observation-count')
        self.mock('git', '''case " $* " in *" status "*)
count=0
[[ ! -f "$TEST_OBSERVATIONS" ]] || read -r count < "$TEST_OBSERVATIONS"
count=$((count + 1))
echo "$count" > "$TEST_OBSERVATIONS"
if [[ "$count" -eq 1 ]]; then printf ' M tracked.txt\\0'; exit 0; fi
;; esac
exec "$TEST_REAL_GIT" "$@"''')
        data = self.compare()
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual(data['comparison']['counts']['unverified'], 3)
        self.assertTrue(all(row['reason'] == 'observation_failed' for row in data['comparison_records']))
        self.mock('git', 'exec "$TEST_REAL_GIT" "$@"')
        (self.base / '.git/index.lock').write_text('retained lock')
        data = self.compare()
        self.assertEqual(self.git_row(data, 0)['comparison_kind'], 'unverified')
        self.assertEqual(self.git_row(data, 0)['reason'], 'prerequisite_unmet')

    def test_non_git_destination_and_symlink_never_match(self):
        self.paths, self.branches, self.parents = self.paths[:2], self.branches[:2], [0, 0]
        self.configure()
        self.remove_linked(1)
        destination = self.home / self.paths[1]
        destination.mkdir()
        (destination / 'user-data').write_text('retained')
        self.assertEqual(self.git_row(self.compare(), 1)['comparison_kind'], 'unverified')
        shutil.rmtree(destination)
        destination.symlink_to(self.base, target_is_directory=True)
        self.assertEqual(self.git_row(self.compare(), 1)['comparison_kind'], 'unverified')

    def test_changed_bundle_and_stage_cannot_publish_results(self):
        self.paths, self.branches, self.parents = self.paths[:1], self.branches[:1], [0]
        self.configure()
        # A hostile observer changing private reference bytes is detected before
        # result publication; the fixture writes neither target nor local config.
        self.environment['TEST_REFERENCE'] = str(self.archive)
        original = self.archive.read_bytes()
        self.mock('git', 'printf changed >> "$TEST_REFERENCE"\nexec "$TEST_REAL_GIT" "$@"')
        result, events = self.invoke(bundle_path=str(self.archive))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_changed')
        self.assertFalse(any(event['type'] == 'result' for event in events))
        self.archive.write_bytes(original)
        self.mock('git', 'printf "\\n" >> "$BLUEPRINT_GENERATED_DIR/workspace/topology.json"\nexec "$TEST_REAL_GIT" "$@"')
        result, events = self.invoke(bundle_path=str(self.archive))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_changed')
        self.assertFalse(any(event['type'] == 'result' for event in events))
        self.assertEqual(self.archive.read_bytes(), original)

    def test_invalid_dependency_payload_rejected_before_observation(self):
        import io
        import tarfile
        self.descriptor()
        descriptors = self.stage / self.contract.VSCODE
        payload = json.loads(descriptors.read_bytes())
        payload['items'][0]['folders'] = [dict(domain='workspace-folders', item_id='Projects/base', subpath='')]
        descriptors.write_text(json.dumps(payload))
        self.archive.unlink()
        self.pack()
        expected = topology_fixture.bundle.validate_archive(self.archive)
        with tarfile.open(self.archive, 'r:') as stream:
            content = {member.name: stream.extractfile(member).read() for member in stream if member.isfile()}

        def repack():
            with tarfile.open(self.archive, 'w', format=tarfile.USTAR_FORMAT) as stream:
                for name, value in content.items():
                    info = tarfile.TarInfo(name); info.size = len(value); info.mode = 0o600
                    stream.addfile(info, io.BytesIO(value))

        # The same writer must produce an accepted control Bundle before only
        # the selected dependency and its manifest checksum/size are changed.
        repack()
        self.assertEqual(topology_fixture.bundle.validate_archive(self.archive), expected)
        manifest = json.loads(content['manifest.json'])
        self.assertEqual(content['blueprint.conf'].count(b'Projects/base\n'), 1)
        blueprint = content['blueprint.conf'].replace(b'Projects/base\n', b'')
        content['blueprint.conf'] = blueprint
        manifest['files']['blueprint.conf'] = dict(size=len(blueprint), sha256=hashlib.sha256(blueprint).hexdigest())
        content['manifest.json'] = json.dumps(manifest).encode()
        repack()
        with self.assertRaises(topology_fixture.bundle.WorkspaceSelectionInvalid) as rejected:
            topology_fixture.bundle.validate_archive(self.archive)
        self.assertEqual(rejected.exception.code, 'workspace_dependency_missing')
        # Any entry into target observation must fail this test, even if the
        # adapter were to report bundle_invalid after launching the collector.
        (self.project / 'bootstrap.sh').write_text('#!/bin/bash\necho target-observation >> "$TEST_MUTATIONS"\nexit 99\n')
        before = self.archive.read_bytes()
        result, events = self.invoke(bundle_path=str(self.archive))
        self.assertEqual(self.archive.read_bytes(), before)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'bundle_invalid')
        self.assertEqual([event['data'] for event in events if event['type'] == 'execution_event'],
                         [dict(phase='bundle_validation', read_only=True)])
        self.assertFalse(any(event['type'] == 'result' for event in events))


if __name__ == '__main__':
    unittest.main()
