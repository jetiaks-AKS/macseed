#!/usr/bin/env python3
"""Read-only secure Check: disposable real age/OpenSSH and observation boundaries."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'modules/migration'))
sys.path.insert(0, str(ROOT / 'modules/ssh'))
import identity_check
import identity_dependencies
from restore_destinations import identity_id
spec = importlib.util.spec_from_file_location('secure_restore_fixtures', ROOT / 'scripts/test-secure-restore.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)


class IdentityObservationTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='macseed-check-observation-', dir='/private/tmp')
        self.addCleanup(temporary.cleanup)
        self.home = Path(temporary.name) / 'home'; self.home.mkdir(mode=0o700)
        self.directory = self.home / '.ssh'
        self.record = ('id_fixture', 'ssh-ed25519', 'fixture', b'private fixture', b'public fixture')

    def pair(self):
        self.directory.mkdir(mode=0o700, exist_ok=True)
        for suffix, raw in zip(('', '.pub'), self.record[3:]):
            p = self.directory / ('id_fixture' + suffix); p.write_bytes(raw); p.chmod(0o600)

    def observe(self):
        value = identity_check.observe(self.record, None, str(self.home))
        self.assertTrue(identity_check.valid_result(value))
        return value

    def test_matching_missing_different_private_public_partial(self):
        self.assertEqual(self.observe()['comparison_kind'], 'missing')
        self.assertFalse(self.directory.exists())
        self.pair(); self.assertEqual(self.observe()['comparison_kind'], 'matching')
        for suffix, reason in [('', 'private_bytes_differ'), ('.pub', 'public_bytes_differ')]:
            self.pair(); (self.directory / ('id_fixture' + suffix)).write_bytes(b'different fixture')
            row = self.observe(); self.assertEqual((row['comparison_kind'], row['reason']), ('differing', reason))
        (self.directory / 'id_fixture.pub').unlink()
        self.assertEqual(self.observe()['reason'], 'partial_pair')

    def test_permissions_links_acl_collision_and_custom_destination(self):
        self.pair(); key = self.directory / 'id_fixture'
        key.chmod(0o644); self.assertEqual(self.observe()['reason'], 'unsafe_target'); key.chmod(0o600)
        os.link(key, self.home / 'hardlink'); self.assertEqual(self.observe()['comparison_kind'], 'unverified')
        (self.home / 'hardlink').unlink()
        key.rename(self.home / 'private'); key.symlink_to(self.home / 'private')
        self.assertEqual(self.observe()['comparison_kind'], 'unverified')
        key.unlink(); (self.home / 'private').rename(key)
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(key)], check=True)
        self.assertEqual(self.observe()['reason'], 'unsafe_target')
        subprocess.run(['/bin/chmod', '-N', str(key)], check=True)
        key.rename(self.directory / 'ID_fixture')
        self.assertEqual(self.observe()['reason'], 'unsafe_target'); (self.directory / 'ID_fixture').rename(key)
        custom = self.home / 'keys'; self.directory.rename(custom)
        self.assertEqual(identity_check.observe(self.record, str(custom), str(self.home))['comparison_kind'], 'matching')
        self.assertEqual(identity_check.observe(self.record, str(self.home / 'absent'), str(self.home))['comparison_kind'], 'unverified')
        self.assertFalse((self.home / 'absent').exists())

    def test_changed_target_and_failed_observation_never_match(self):
        self.pair()
        original = identity_check.read_pair
        def change(path):
            value = original(path)
            Path(path).write_bytes(b'changed fixture')
            return value
        with patch.object(identity_check, 'read_pair', side_effect=change):
            self.assertEqual(self.observe()['reason'], 'target_changed')
        with patch.object(identity_check.os, 'scandir', side_effect=PermissionError):
            self.assertEqual(self.observe()['comparison_kind'], 'unverified')
        old = identity_check.result('matching', 'pair_identical', 'a' * 64, True, True)
        new = identity_check.result('missing', 'pair_absent', 'b' * 64)
        with patch.object(identity_check, 'observe', side_effect=[old, new]):
            self.assertEqual(identity_check.compare([self.record], {}, str(self.home))[0]['reason'], 'target_changed')


class SecureCheckTests(unittest.TestCase):
    setUp = fixtures.SecureRestoreTests.setUp
    secure_directories = staticmethod(fixtures.SecureRestoreTests.secure_directories)
    fixture = fixtures.SecureRestoreTests.fixture
    multiple_fixture = fixtures.SecureRestoreTests.multiple_fixture
    publish_pairs = fixtures.SecureRestoreTests.publish_pairs
    peer = fixtures.SecureRestoreTests.peer
    dependency_snapshot = fixtures.SecureRestoreTests.dependency_snapshot
    write_mapping = fixtures.SecureRestoreTests.write_mapping

    def inventory(self):
        status, events, challenges = self.peer(operation='secure_check_inventory')
        self.assertEqual(status, 0, events)
        self.assertEqual([c['kind'] for c in challenges], ['bundle_unlock'])
        inventory = json.loads((self.private_temp / 'secure-restore-inventory.json').read_bytes())
        mapping = dict(version=2, bundle_id=inventory['bundle_id'], items=sorted([
            dict(identity_id=row['identity_id'], directory=None, selected=False) for row in inventory['items']], key=lambda r: r['identity_id']))
        return mapping, inventory

    def snapshot(self):
        # Only the disposable fixture HOME, never the developer's environment.
        return [(str(p.relative_to(self.home)), p.lstat().st_mode, p.lstat().st_ino, p.lstat().st_mtime_ns,
                 p.lstat().st_ctime_ns, hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() and not p.is_symlink() else None)
                for p in sorted(self.home.rglob('*'))]

    def check(self, mapping, **kwargs):
        before, source = self.snapshot(), self.archive.read_bytes()
        status, events, challenges = self.peer(operation='secure_check_compare', mapping=mapping, **kwargs)
        self.assertEqual(before, self.snapshot(), 'Check must not modify any target state')
        if 'answer' not in kwargs:
            self.assertTrue(source == self.archive.read_bytes(), 'Check must not change Bundle bytes')
        self.assertTrue(all(c['kind'] == 'bundle_unlock' for c in challenges), 'Check accepts only Bundle authentication')
        terminal = events[-1]['data']
        self.assertTrue(terminal['read_only']); self.assertFalse(terminal['publication_occurred'])
        self.assertFalse(terminal['target_mutation_may_have_started'])
        public = json.dumps(events).encode()
        for private in [b'id_disposable', b'id_external', b'PRIVATE KEY', str(self.home).encode()] + [r['identity_id'].encode() for r in mapping['items']]:
            self.assertTrue(private not in public, 'Sensitive identity evidence leaked to ordinary Protocol')
        if status != 0:
            self.assertFalse((self.private_temp / 'secure-check-result.json').exists())
            return None, events, challenges
        result = json.loads((self.private_temp / 'secure-check-result.json').read_bytes())
        self.assertEqual(result['context']['mapping'], mapping)
        self.assertEqual(result['context']['source_validation'], 'saved_files')
        self.assertEqual(result['bundle_id'], mapping['bundle_id'])
        self.assertEqual(result['operation_id'], 'secure-test')
        self.assertEqual(sorted(r['identity_id'] for r in result['items']), [r['identity_id'] for r in mapping['items'] if r['selected']])
        return result, events, challenges

    def write_pair(self, pair, name='id_disposable', directory=None):
        directory = directory or self.home / '.ssh'; directory.mkdir(mode=0o700, exist_ok=True)
        for suffix, raw in zip(('', '.pub'), pair):
            p = directory / (name + suffix); p.write_bytes(raw); p.chmod(0o600)

    def test_authenticated_missing_matching_repeat_and_read_only(self):
        pair = self.fixture(protected=True, prepare=False)
        mapping, _ = self.inventory()
        self.assertFalse(mapping['items'][0]['selected'])
        mapping['items'][0]['selected'] = True
        result, _, challenges = self.check(mapping)
        self.assertEqual(result['items'][0]['comparison_kind'], 'missing')
        self.assertEqual([c['kind'] for c in challenges], ['bundle_unlock'])
        self.assertFalse((self.home / '.ssh').exists())
        self.write_pair(pair)
        for _ in range(2):
            result, _, _ = self.check(mapping)
            self.assertEqual(result['items'][0]['comparison_kind'], 'matching')
            self.assertTrue(result['items'][0]['private_bytes_match'] and result['items'][0]['public_bytes_match'])

    def test_same_fingerprint_different_private_bytes_and_public_bytes(self):
        pair = self.fixture(prepare=False)
        mapping, _ = self.inventory(); mapping['items'][0]['selected'] = True
        # An encoding/comment change preserves the private key and fingerprint,
        # but byte identity is still a required predicate.
        subprocess.run(['ssh-keygen', '-q', '-c', '-C', 'different fixture comment', '-P', '', '-f', str(self.identity)], check=True, stdout=subprocess.DEVNULL)
        self.write_pair((self.identity.read_bytes(), pair[1]))
        result, _, _ = self.check(mapping)
        self.assertEqual(result['items'][0]['reason'], 'private_bytes_differ')
        self.write_pair((pair[0], pair[1].rstrip() + b' changed-comment\n'))
        result, _, _ = self.check(mapping)
        self.assertEqual(result['items'][0]['reason'], 'public_bytes_differ')

    def test_subset_custom_destination_excluded_protected_identity(self):
        pairs = self.multiple_fixture(protected=True, prepare=False)
        mapping, inventory = self.inventory()
        selected = next(r['identity_id'] for r in inventory['items'] if r['name'] == 'id_external')
        custom = self.home / 'custom'; self.write_pair(pairs['id_external'], 'id_external', custom)
        for row in mapping['items']:
            row.update(selected=row['identity_id'] == selected, directory=str(custom) if row['identity_id'] == selected else str(self.home / 'unavailable'))
        result, _, challenges = self.check(mapping)
        self.assertEqual(len(result['items']), 1)
        self.assertEqual(result['items'][0]['comparison_kind'], 'matching')
        self.assertEqual([c['kind'] for c in challenges], ['bundle_unlock'])
        self.assertFalse((self.home / '.ssh').exists())

    def test_complete_scope_preserves_matching_and_missing_per_identity(self):
        pairs = self.multiple_fixture(protected=True, prepare=False)
        mapping, _ = self.inventory()
        for row in mapping['items']:
            row['selected'] = True
        self.write_pair(pairs['id_external'], 'id_external')
        result, _, _ = self.check(mapping)
        self.assertEqual(sorted(row['comparison_kind'] for row in result['items']), ['matching', 'missing'])
        self.assertEqual(len({row['identity_id'] for row in result['items']}), 2)

    def test_cancel_wrong_passphrase_empty_selection_and_stale_bundle(self):
        self.fixture(prepare=False)
        for answer, code in [('cancel', 'secure_cancelled'), ('wrong fixture passphrase', 'secure_unlock_rejected')]:
            status, events, _ = self.peer(lambda *_: answer, operation='secure_check_inventory')
            self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], code)
        mapping, _ = self.inventory()
        result, events, challenges = self.check(mapping)
        self.assertIsNone(result); self.assertEqual(events[-1]['data']['code'], 'secure_input_invalid'); self.assertFalse(challenges)
        mapping['items'][0]['selected'] = True
        result, events, challenges = self.check(mapping, expected_bundle_id='a' * 64)
        self.assertIsNone(result); self.assertEqual(events[-1]['data']['code'], 'reference_changed'); self.assertFalse(challenges)
        def changed(*_):
            with self.archive.open('ab') as stream: stream.write(b'changed fixture')
        result, events, _ = self.check(mapping, answer=changed)
        self.assertIsNone(result); self.assertEqual(events[-1]['data']['code'], 'reference_changed')

    def test_protected_saved_reference_matches_only_its_authenticated_destination(self):
        pair = self.fixture(protected=True, prepare=False)
        self.dependency_snapshot(['~/.ssh/id_disposable'])
        mapping, _ = self.inventory(); mapping['items'][0]['selected'] = True
        self.write_pair(pair)
        result, _, _ = self.check(mapping)
        self.assertEqual(result['items'][0]['comparison_kind'], 'matching')
        self.assertEqual(result['context']['ssh_reference_coverage'], 'resolved')
        self.assertEqual(len(result['items']), 1)  # No fabricated reference/Host matches.
        # Ordinary qualification still requires unlocking; Check grants no import
        # receipt or cryptographic/clone authorization.
        raw = (self.stage / 'generated/ssh/config.snapshot').read_bytes()
        finding = identity_dependencies.assess(raw, str(self.home))[0]['references'][0]
        self.assertEqual((finding['status'], finding['reason']), ('unresolved', 'locked_or_invalid_identity'))
        self.dependency_snapshot(['~/.ssh/id_disposable', '~/.ssh/absent'])
        mapping, _ = self.inventory(); mapping['items'][0]['selected'] = True
        result, _, _ = self.check(mapping)
        self.assertEqual(result['context']['ssh_reference_coverage'], 'unresolved')
        # Identical authenticated bytes elsewhere do not prove the configured path.
        self.dependency_snapshot(['~/.ssh/id_disposable'])
        custom = self.home / 'custom'; self.write_pair(pair, directory=custom)
        mapping, _ = self.inventory(); mapping['items'][0].update(selected=True, directory=str(custom))
        result, _, _ = self.check(mapping)
        self.assertEqual(result['items'][0]['comparison_kind'], 'matching')
        self.assertEqual(result['context']['ssh_reference_coverage'], 'unresolved')
        # Matching bytes at both paths still cannot authorize a different mapping.
        self.dependency_snapshot(['~/custom/id_disposable'])
        mapping, _ = self.inventory(); mapping['items'][0].update(selected=True, directory=str(custom))
        result, _, _ = self.check(mapping)
        self.assertEqual(result['context']['ssh_reference_coverage'], 'resolved')
        self.dependency_snapshot([str(custom / 'id_disposable')])
        mapping, _ = self.inventory(); mapping['items'][0].update(selected=True, directory=str(custom))
        result, _, _ = self.check(mapping)
        self.assertEqual(result['context']['ssh_reference_coverage'], 'unresolved')

    def test_reference_scope_excludes_unselected_keys_and_partial_observations(self):
        pairs = self.multiple_fixture(protected=True, prepare=False)
        self.dependency_snapshot(['~/.ssh/id_disposable', '~/.ssh/id_external'])
        for name, pair in pairs.items():
            self.write_pair(pair, name)
        mapping, inventory = self.inventory()
        selected = next(row['identity_id'] for row in inventory['items'] if row['name'] == 'id_external')
        for row in mapping['items']:
            row['selected'] = row['identity_id'] == selected
        result, _, _ = self.check(mapping)
        self.assertEqual([row['comparison_kind'] for row in result['items']], ['matching'])
        self.assertEqual(result['context']['ssh_reference_coverage'], 'unresolved')
        for row in mapping['items']:
            row['selected'] = True
        result, _, _ = self.check(mapping)
        self.assertEqual([row['comparison_kind'] for row in result['items']], ['matching', 'matching'])
        self.assertEqual(result['context']['ssh_reference_coverage'], 'resolved')
        (self.home / '.ssh/id_disposable.pub').unlink()
        result, _, _ = self.check(mapping)
        self.assertEqual(sorted(row['comparison_kind'] for row in result['items']), ['matching', 'unverified'])
        self.assertEqual(result['context']['ssh_reference_coverage'], 'unresolved')

    def test_reference_correlation_requires_live_unambiguous_safe_evidence(self):
        pair = self.fixture(protected=True, prepare=False)
        self.dependency_snapshot(['~/.ssh/id_disposable'])
        self.write_pair(pair)
        mapping, inventory = self.inventory(); mapping['items'][0]['selected'] = True
        evidence = dict(inventory['items'][0], target='identical',
                        pair_digest=[hashlib.sha256(raw).hexdigest() for raw in pair])
        raw = (self.stage / 'generated/ssh/config.snapshot').read_bytes()
        def coverage(rows):
            return identity_check.reference_coverage(raw, str(self.home), rows, mapping)
        self.assertEqual(coverage([evidence]), 'resolved')
        self.assertEqual(coverage([]), 'unresolved')
        self.assertEqual(coverage([evidence, evidence]), 'unresolved')
        self.assertEqual(coverage([dict(evidence, target='unresolved')]), 'unresolved')
        with patch.object(identity_dependencies, 'observe', side_effect=PermissionError):
            self.assertEqual(coverage([evidence]), 'unresolved')
        observe = identity_dependencies.observe
        def changed(path):
            value = observe(path)
            path.write_bytes(path.read_bytes() + b'\n')
            return value
        with patch.object(identity_dependencies, 'observe', side_effect=changed):
            self.assertEqual(coverage([evidence]), 'unresolved')
        self.write_pair(pair)
        key = self.home / '.ssh/id_disposable'
        key.chmod(0o644)
        self.assertEqual(coverage([evidence]), 'unresolved')
        key.chmod(0o600)
        os.link(key, self.home / 'hardlink')
        self.assertEqual(coverage([evidence]), 'unresolved')
        (self.home / 'hardlink').unlink()
        key.rename(self.home / 'private'); key.symlink_to(self.home / 'private')
        self.assertEqual(coverage([evidence]), 'unresolved')

    def test_independent_local_pair_qualification(self):
        pair = self.fixture(prepare=False)
        self.dependency_snapshot(['~/.ssh/id_disposable'])
        mapping, _ = self.inventory(); mapping['items'][0]['selected'] = True
        self.write_pair(pair)
        result, _, _ = self.check(mapping)
        self.assertEqual(result['context']['ssh_reference_coverage'], 'resolved')

    def test_invalid_encrypted_payload_and_partial_unsafe_target(self):
        pair = self.fixture(prepare=False)
        mapping, _ = self.inventory(); mapping['items'][0]['selected'] = True
        self.write_pair(pair); (self.home / '.ssh/id_disposable.pub').unlink()
        result, _, _ = self.check(mapping)
        self.assertEqual(result['items'][0]['reason'], 'partial_pair')
        self.write_pair(pair); (self.home / '.ssh/id_disposable').chmod(0o644)
        result, _, _ = self.check(mapping)
        self.assertEqual(result['items'][0]['reason'], 'unsafe_target')
        (self.root / 'payload.tar').write_bytes(b'invalid disposable payload')
        (self.stage / 'secure.age').unlink()
        fixtures.encrypt(fixtures.REAL_AGE, self.root / 'payload.tar', self.stage / 'secure.age')
        self.archive.unlink(); fixtures.bundle.pack(self.stage, self.archive, '/Users/source')
        status, events, _ = self.peer(operation='secure_check_inventory')
        self.assertNotEqual(status, 0)
        self.assertEqual(events[-1]['data']['code'], 'secure_payload_invalid')
        self.assertFalse((self.private_temp / 'secure-restore-inventory.json').exists())

    def test_public_envelope_validation_and_bundle_unlock_cancellation(self):
        pair = self.fixture(protected=True, prepare=False)
        mapping, _ = self.inventory(); mapping['items'][0]['selected'] = True
        result, events, challenges = self.check(mapping, answer=lambda *_: 'cancel')
        self.assertIsNone(result); self.assertEqual(events[-1]['data']['code'], 'secure_cancelled')
        self.assertEqual([row['kind'] for row in challenges], ['bundle_unlock'])
        # A self-consistent manifest cannot hide a mismatched private/public envelope.
        other = self.root / 'other-fixture'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(other)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        payload = self.root / 'payload.tar'
        with fixtures.tarfile.open(payload) as archive:
            entries = {row.name: archive.extractfile(row).read() for row in archive}
        changed = other.read_bytes()
        manifest = entries['manifest'].decode().splitlines()
        fields = manifest[-1].split('\t'); fields[3] = str(len(changed)); fields[4] = hashlib.sha256(changed).hexdigest()
        manifest[-1] = '\t'.join(fields)
        entries['manifest'] = ('\n'.join(manifest) + '\n').encode(); entries['keys/id_disposable'] = changed
        with fixtures.tarfile.open(payload, 'w', format=fixtures.tarfile.USTAR_FORMAT) as archive:
            for name, raw in entries.items():
                member = fixtures.tarfile.TarInfo(name); member.size = len(raw); archive.addfile(member, fixtures.io.BytesIO(raw))
        (self.stage / 'secure.age').unlink()
        fixtures.encrypt(fixtures.REAL_AGE, payload, self.stage / 'secure.age')
        self.archive.unlink(); fixtures.bundle.pack(self.stage, self.archive, '/Users/source')
        status, events, _ = self.peer(operation='secure_check_inventory')
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'secure_payload_invalid')
        self.assertFalse((self.private_temp / 'secure-restore-inventory.json').exists())
        self.assertFalse((self.home / '.ssh').exists())

    def test_no_secure_component_identity_mismatch_and_unsafe_destination(self):
        self.fixture(prepare=False)
        mapping, _ = self.inventory(); mapping['items'][0]['selected'] = True
        mapping['items'][0]['directory'] = str(self.home / 'absent-custom')
        result, _, _ = self.check(mapping)
        self.assertEqual(result['items'][0]['comparison_kind'], 'unverified')
        mapping['items'][0]['identity_id'] = 'a' * 64
        result, events, _ = self.check(mapping)
        self.assertIsNone(result); self.assertEqual(events[-1]['data']['code'], 'secure_target_changed')
        (self.stage / 'secure.age').unlink(); self.archive.unlink()
        fixtures.bundle.pack(self.stage, self.archive, '/Users/source')
        status, events, challenges = self.peer(operation='secure_check_inventory')
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'secure_component_unavailable')
        self.assertFalse(challenges)


if __name__ == '__main__':
    unittest.main()
