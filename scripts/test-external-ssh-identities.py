#!/usr/bin/env python3
"""Focused external-source inspection through the real Core/SSH launcher path."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'modules/migration'))
from external_sources import read_pair, read_control, ExternalSourceError


class ExternalIdentityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='macseed-external-test-', dir='/private/tmp')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / 'home'; self.home.mkdir(mode=0o700)
        self.directory = self.root / 'outside'; self.directory.mkdir(mode=0o755)
        self.key = self.directory / 'fixture_key'
        self.keygen(self.key)
        self.before = set(Path('/private/tmp').glob('ssh-migrate-*'))
        self.addCleanup(lambda: self.assertEqual(self.before, set(Path('/private/tmp').glob('ssh-migrate-*'))))

    def keygen(self, path, kind='ed25519', bits=None):
        command = ['/usr/bin/ssh-keygen', '-q', '-t', kind, '-N', '', '-f', str(path)]
        if bits: command += ['-b', str(bits)]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def inspect(self, source=None, *, mutate_control=None):
        with tempfile.TemporaryDirectory(prefix='operation-', dir=self.root) as temporary:
            directory = Path(temporary); directory.chmod(0o700)
            control = directory / 'external-ssh-sources.json'
            payload = {'version': 1, 'operation_id': 'external-fixture', 'paths': [str(source or self.key)]}
            if mutate_control: mutate_control(payload)
            control.write_text(json.dumps(payload)); control.chmod(0o600)
            request = {'protocol_version': 1, 'operation_id': 'external-fixture', 'operation': 'capture_identity_inspect',
                       'parameters': {'external_identities': True}}
            raw = json.dumps(request).encode()
            self.assertLess(len(raw), 4096)
            environment = dict(HOME=str(self.home), TMPDIR=temporary, PATH=str(Path(sys.executable).parent)+':/usr/bin:/bin:/usr/sbin:/sbin', PYTHONDONTWRITEBYTECODE='1')
            result = subprocess.run(['/bin/bash', str(ROOT / 'modules/core/application-interface/core.sh')], cwd=ROOT,
                                    input=raw, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=environment, timeout=45)
            self.assertNotIn(str(self.directory).encode(), result.stdout + result.stderr)
            self.assertNotIn(b'OPENSSH PRIVATE KEY', result.stdout + result.stderr)
            events = [json.loads(line) for line in result.stdout.splitlines()]
            self.assertEqual(events[0]['type'], 'started')
            return result.returncode, events

    def failure(self, expected, source=None):
        code, events = self.inspect(source)
        self.assertEqual(code, 2)
        self.assertEqual(events[-1]['data']['code'], expected)
        self.assertFalse(any(e['type'] == 'secure_challenge_waiting' for e in events))

    def test_supported_types_and_source_scope(self):
        cases = [('ed25519', None), ('rsa', 2048), ('ecdsa', 256), ('ecdsa', 384), ('ecdsa', 521)]
        for index, (kind, bits) in enumerate(cases):
            path = self.home / ('home_key_' + str(index)) if index % 2 else self.directory / ('outside_key_' + str(index))
            self.keygen(path, kind, bits)
            before = [p.read_bytes() for p in (path, Path(str(path)+'.pub'))]
            code, events = self.inspect(path)
            self.assertEqual(code, 0)
            identity = next(e['data']['identity'] for e in events if e['type'] == 'result')
            self.assertEqual(identity['label'], path.name)
            self.assertEqual(identity['source'], 'manual')
            self.assertEqual(set(identity), {'item_id','label','key_type','fingerprint','validation','source'})
            self.assertEqual(before, [p.read_bytes() for p in (path, Path(str(path)+'.pub'))])

    def test_missing_public_pair(self):
        Path(str(self.key)+'.pub').unlink()
        self.failure('external_identity_pair_missing')

    def test_mismatched_or_unsupported_pair(self):
        other = self.directory / 'other'; self.keygen(other)
        Path(str(self.key)+'.pub').write_bytes(Path(str(other)+'.pub').read_bytes())
        self.failure('external_identity_pair_invalid')
        self.key.write_bytes(b'-----BEGIN RSA PRIVATE KEY-----\nunsupported')
        self.failure('external_identity_pair_invalid')

    def test_symlink_hardlink_and_fifo(self):
        original = self.root / 'original'; self.key.rename(original)
        self.key.symlink_to(original); self.failure('external_identity_unsafe'); self.key.unlink()
        os.link(original, self.key); self.failure('external_identity_unsafe'); self.key.unlink()
        os.mkfifo(self.key, 0o600); self.failure('external_identity_unsafe')

    def test_unsafe_modes_and_parent(self):
        self.key.chmod(0o644); self.failure('external_identity_unsafe'); self.key.chmod(0o600)
        Path(str(self.key)+'.pub').chmod(0o666); self.failure('external_identity_unsafe'); Path(str(self.key)+'.pub').chmod(0o644)
        self.directory.chmod(0o777); self.failure('external_identity_unsafe')

    def test_parent_alias_and_traversal(self):
        alias = self.root / 'alias'; alias.symlink_to(self.directory)
        self.failure('external_identity_unsafe', alias / self.key.name)
        with self.assertRaises(ExternalSourceError): read_pair(str(self.directory) + '/../outside/' + self.key.name)
        with self.assertRaises(ExternalSourceError): read_pair(str(self.directory) + '//'+ self.key.name)

    def test_size_name_and_public_selection_limits(self):
        self.key.write_bytes(b'x' * (1024*1024+1)); self.failure('external_identity_unsafe')
        self.failure('external_identity_name_invalid', Path(str(self.key)+'.pub'))
        for name in ['config', 'AUTHORIZED_KEYS', 'known_hosts', 'rc', 'key.PUB']:
            self.failure('external_identity_name_invalid', self.directory / name)
        odd = self.directory / 'unsafe name'; self.key.rename(odd)
        self.failure('external_identity_name_invalid', odd)

    def test_control_is_operation_bound_and_count_bounded(self):
        for change in [lambda v: v.update(operation_id='foreign'), lambda v: v.update(version=2),
                       lambda v: v.update(paths=[str(self.key)]*33), lambda v: v.update(paths=['/'+'x'*1024])]:
            code, events = self.inspect(mutate_control=change)
            self.assertEqual(code,2)
            self.assertEqual(events[-1]['data']['code'],'external_identity_invalid_request')

    def test_case_insensitive_destination_collision(self):
        other = self.home / 'FIXTURE_KEY'; self.keygen(other)
        control = self.root / 'sources.json'
        control.write_text(json.dumps([str(self.key), str(other)])); control.chmod(0o600)
        result = subprocess.run(['/bin/bash', str(ROOT / 'scripts/ssh-identity-migrate.sh'),
                                 'application-external-list', '--sources', str(control)], cwd=ROOT,
                                env=dict(HOME=str(self.home), PATH='/usr/bin:/bin:/usr/sbin:/sbin', PYTHONDONTWRITEBYTECODE='1'),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(json.loads(result.stdout), {'error': 'external_identity_duplicate'})
        self.assertNotIn(str(self.directory).encode(), result.stdout + result.stderr)

    def test_private_reference_file_safety(self):
        control = self.root / 'control.json'
        control.write_text('{"version":1,"version":2}'); control.chmod(0o600)
        with self.assertRaises(ExternalSourceError): read_control(control)
        control.write_text('[]'); control.chmod(0o644)
        with self.assertRaises(ExternalSourceError): read_control(control)
        control.chmod(0o600)
        alias = self.root / 'control-alias'; alias.symlink_to(control)
        with self.assertRaises(ExternalSourceError): read_control(alias)
        alias.unlink(); os.link(control, alias)
        with self.assertRaises(ExternalSourceError): read_control(control)
        alias.unlink(); control.unlink(); os.mkfifo(control, 0o600)
        with self.assertRaises(ExternalSourceError): read_control(control)


if __name__ == '__main__':
    unittest.main()
