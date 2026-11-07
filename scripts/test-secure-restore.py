#!/usr/bin/env python3
"""Disposable Core peer, real age/OpenSSH, and fail-closed channel regressions."""
import base64
import ast
import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tarfile
import termios
import threading
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'modules/migration'))
from secret_input import SecureError, inherited_socket, receive, response, tool, valid_challenge, unique_fields
spec = importlib.util.spec_from_file_location('prepare_tests', ROOT / 'scripts/test-restore-prepare.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
bundle = fixtures.bundle
REAL_AGE = shutil.which('age')
BUNDLE_SECRET = 'disposable-bundle-only-731'
KEY_SECRET = 'disposable-key-only-842'


def encrypt(age, payload, destination):
    master, slave = pty.openpty()
    settings = termios.tcgetattr(slave)
    settings[3] &= ~(termios.ECHO | termios.ECHONL)
    termios.tcsetattr(slave, termios.TCSANOW, settings)
    child = subprocess.Popen([age, '-p', '-o', str(destination), str(payload)],
                             stdin=slave, stdout=subprocess.DEVNULL, stderr=slave,
                             start_new_session=True)
    os.close(slave)
    seen = b''
    end = time.monotonic() + 10
    try:
        while child.poll() is None:
            if time.monotonic() > end:
                raise AssertionError('fixture encryption timeout')
            if select.select([master], [], [], .1)[0]:
                try:
                    chunk = os.read(master, 4096)
                except OSError:
                    break
                seen += chunk
                if b': ' in seen:
                    os.write(master, BUNDLE_SECRET.encode() + b'\n')
                    seen = b''
        if child.wait(timeout=2) != 0:
            raise AssertionError('fixture encryption failed')
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        os.close(master)


class SecureRestoreTests(unittest.TestCase):
    def setUp(self):
        fixtures.RestorePrepareTests.setUp(self)
        self.home = self.home.resolve()
        self.environment['HOME'] = str(self.home)
        self.secure_before = self.secure_directories()
        self.addCleanup(lambda: self.assertEqual(self.secure_directories(), self.secure_before))
    @staticmethod
    def secure_directories():
        return {str(p) for pattern in ('ssh-migrate-*', 'macseed-evidence-*')
                for p in Path('/private/tmp').glob(pattern)}

    invoke = fixtures.RestorePrepareTests.invoke
    execute = fixtures.RestorePrepareTests.execute

    def fixture(self, protected=False, invalid=False):
        if not REAL_AGE:
            self.skipTest('real age unavailable; no installation attempted')
        self.home.chmod(0o700)
        (self.project / 'scripts').mkdir()
        shutil.copy2(ROOT / 'scripts/ssh-identity-migrate.sh', self.project / 'scripts/ssh-identity-migrate.sh')
        (self.root / 'bin/age').unlink()
        os.symlink(REAL_AGE, self.root / 'bin/age')
        blueprint = (self.stage / 'blueprint.conf').read_bytes().replace(b'Projects\n', b'')
        (self.stage / 'blueprint.conf').write_bytes(blueprint)
        self.identity = self.root / 'disposable_identity'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', KEY_SECRET if protected else '',
                        '-f', str(self.identity)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        private, public = self.identity.read_bytes(), self.identity.with_suffix('.pub').read_bytes()
        blob = base64.b64decode(public.split()[1])
        fingerprint = 'SHA256:' + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip('=')
        manifest = ('toolkit-ssh-identities\nversion=1\ncount=1\n' + '\t'.join([
            'id_disposable', 'ssh-ed25519', fingerprint, str(len(private)), hashlib.sha256(private).hexdigest(),
            str(len(public)), hashlib.sha256(public).hexdigest()]) + '\n').encode()
        payload = self.root / 'payload.tar'
        with tarfile.open(payload, 'w', format=tarfile.USTAR_FORMAT) as archive:
            for name, raw in [('manifest', manifest), ('keys/id_disposable', private), ('keys/id_disposable.pub', public)]:
                member = tarfile.TarInfo(name)
                member.size = len(raw)
                archive.addfile(member, io.BytesIO(raw))
        if invalid:
            payload.write_bytes(b'invalid disposable payload')
        encrypt(REAL_AGE, payload, self.stage / 'secure.age')
        (self.stage / 'secure.age').chmod(0o600)
        bundle.pack(self.stage, self.archive, '/Users/source')
        result, events = self.invoke(secure=True)
        self.assertEqual(result.returncode, 0, events)
        self.plan = events[1]['data']['prepared_plan_id']
        return private, public

    def peer(self, answer=None, plan=None, invalid_fd=False, timeout=30, *, operation='restore_execute', mapping=None, comparison=None):
        parent, endpoint = socket.socketpair()
        fd = endpoint.fileno()
        identity = os.fstat(fd)
        self.environment['TEST_EXTERNAL_SOCKET'] = str(identity.st_dev) + ':' + str(identity.st_ino)
        request = {'protocol_version': 1, 'operation_id': 'secure-test', 'operation': 'restore_execute',
                   'parameters': {'path': str(self.archive), 'disabled_groups': [], 'include_secure': True,
                                  'expected_prepared_plan_id': plan or self.plan}}
        request['operation'] = operation
        if operation == 'secure_restore_inventory':
            request['parameters'] = {'path': str(self.archive)}
            (self.private_temp / 'secure-restore-inventory.json').unlink(missing_ok=True)
        if mapping is not None:
            request['parameters']['custom_destinations'] = True
            self.write_mapping(mapping, 'secure-test')
        if comparison is not None:
            request['parameters']['secure_comparison'] = comparison
        command = ['bash', str(self.project / 'modules/core/application-interface/core.sh'),
                   '--secure-fd', str(99999 if invalid_fd else fd)]
        child = subprocess.Popen(command, cwd=self.project, env=self.environment, pass_fds=(fd,),
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        endpoint.close()
        child.stdin.write(json.dumps(request).encode())
        child.stdin.close()
        child.stdin = None
        challenges = []
        end = time.monotonic() + timeout
        try:
            while child.poll() is None:
                if time.monotonic() > end:
                    self.fail('Core peer timeout')
                if not select.select([parent], [], [], .1)[0]:
                    continue
                try:
                    raw = receive(parent, end)
                except SecureError:
                    break
                challenge = json.loads(raw)
                challenges.append(challenge)
                result = answer(challenge, len(challenges), child) if answer else None
                if result == 'wait':
                    continue
                if result == 'eof':
                    parent.close()
                    break
                if result == 'term':
                    child.send_signal(signal.SIGTERM)
                    break
                if isinstance(result, bytes):
                    parent.sendall(result)
                    continue
                action = b'Y' if challenge['kind'] == 'import_confirmation' else b'S'
                secret = b'' if action == b'Y' else (KEY_SECRET if challenge['kind'] == 'ssh_key_unlock' else BUNDLE_SECRET).encode()
                if result == 'cancel':
                    action, secret = b'C', b''
                elif isinstance(result, str):
                    secret = result.encode()
                body = bytes.fromhex(challenge['challenge_id']) + action + secret
                parent.sendall(struct.pack('!I', len(body)) + body)
            stdout, stderr = child.communicate(timeout=timeout)
            events = [json.loads(line) for line in stdout.splitlines()]
            for secret in (BUNDLE_SECRET.encode(), KEY_SECRET.encode()):
                self.assertNotIn(secret, stdout + stderr + json.dumps(request).encode())
                for log in (self.project / 'logs').glob('*'):
                    if log.is_file():
                        self.assertNotIn(secret, log.read_bytes())
            self.assertEqual(sum(e['type'] in ('failed', 'completed', 'cancelled') for e in events), 1, events)
            return child.returncode, events, challenges
        finally:
            parent.close()
            if child.poll() is None:
                os.killpg(child.pid, signal.SIGTERM)
                child.wait(timeout=5)
            if child.stdout:
                child.stdout.close()
            if child.stderr:
                child.stderr.close()

    def failure(self, answer, code):
        self.fixture()
        status, events, _ = self.peer(answer)
        self.assertNotEqual(status, 0, events)
        self.assertEqual(events[-1]['data']['code'], code, events)
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'], events)
        self.assertFalse((self.home / '.ssh').exists())
        self.assertFalse(list(self.private_temp.glob('mbt-bundle-*')))

    def test_real_secure_import_and_global_verification(self):
        private, public = self.fixture()
        status, events, challenges = self.peer()
        self.assertEqual(status, 0, events)
        self.assertEqual([c['kind'] for c in challenges], ['bundle_unlock', 'import_confirmation'])
        data = events[-2]['data']
        self.assertEqual(data['secure_restore_status'], 'completed')
        self.assertTrue(data['target_mutation_may_have_started'])
        self.assertEqual(data['verification']['verified_count'], 1, data)
        details = data['verification']['details']
        self.assertEqual(details['status'], 'complete')
        self.assertTrue(any(row['domain'] == 'secure-ssh-identities' and
                            row['predicate'] == 'identity_pair_matches_package' and
                            row['conformity'] == 'verified' for row in details['verification_records']))
        transport = json.dumps(events)
        self.assertNotIn('id_disposable', transport)
        self.assertNotIn('PRIVATE KEY', transport)
        self.assertNotIn('bundle-passphrase', transport)

        ssh = self.home / '.ssh'
        self.assertEqual((ssh / 'id_disposable').read_bytes(), private)
        self.assertEqual((ssh / 'id_disposable.pub').read_bytes(), public)
        for path, mode in [(ssh, 0o700), (ssh / 'id_disposable', 0o600), (ssh / 'id_disposable.pub', 0o644)]:
            self.assertEqual(path.stat().st_mode & 0o777, mode)
        self.assertFalse((self.root / 'mutations').exists(), 'no sudo or Homebrew installation')

    def test_identical_noop(self):
        private, public = self.fixture()
        ssh = self.home / '.ssh'
        ssh.mkdir(mode=0o700)
        bundle.write_file(ssh / 'id_disposable', private)
        bundle.write_file(ssh / 'id_disposable.pub', public)
        (ssh / 'id_disposable.pub').chmod(0o644)
        status, events, challenges = self.peer()
        self.assertEqual(status, 0, events)
        self.assertEqual([c['kind'] for c in challenges], ['bundle_unlock'])
        self.assertFalse(events[-2]['data']['target_mutation_may_have_started'])

    def test_protected_key_separate_unlock(self):
        self.fixture(protected=True)
        status, events, challenges = self.peer()
        self.assertEqual(status, 0, events)
        self.assertIn('ssh_key_unlock', [c['kind'] for c in challenges])
        self.assertEqual(events[-2]['data']['verification']['verified_count'], 1)

    def test_key_retry(self):
        self.fixture(protected=True)
        status, events, challenges = self.peer(lambda c, n, p: 'wrong-test-only' if c['kind'] == 'ssh_key_unlock' and c['attempt'] == 1 else None)
        self.assertEqual(status, 0, events)
        self.assertTrue(any(c['kind'] == 'ssh_key_unlock' and c['attempt'] == 2 for c in challenges))

    def test_key_retry_exhausted(self):
        self.fixture(protected=True)
        status, events, challenges = self.peer(lambda c, n, p: 'wrong-test-only' if c['kind'] == 'ssh_key_unlock' else None)
        self.assertEqual(events[-1]['data']['code'], 'secure_key_unlock_rejected', events)
        self.assertEqual([c['attempt'] for c in challenges if c['kind'] == 'ssh_key_unlock'], [1, 2, 3])
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])

    def test_bundle_retry(self):
        self.fixture()
        status, events, challenges = self.peer(lambda c, n, p: 'wrong-test-only' if n == 1 else None)
        self.assertEqual(status, 0, events)
        self.assertEqual([c['attempt'] for c in challenges if c['kind'] == 'bundle_unlock'], [1, 2])

    def test_bundle_retry_exhausted(self):
        self.failure(lambda c, n, p: 'wrong-test-only', 'secure_unlock_rejected')

    def test_confirmation_cancel(self):
        self.failure(lambda c, n, p: 'cancel' if c['kind'] == 'import_confirmation' else None, 'secure_cancelled')

    def test_peer_eof(self):
        self.failure(lambda c, n, p: 'eof', 'secure_cancelled')

    def test_sigterm(self):
        self.failure(lambda c, n, p: 'term', 'cancelled')

    def test_malformed_frame(self):
        self.failure(lambda c, n, p: struct.pack('!I', 1) + b'x', 'secure_channel_invalid')

    def test_oversized_frame(self):
        self.failure(lambda c, n, p: struct.pack('!I', 2049), 'secure_channel_invalid')

    def test_invalid_payload(self):
        self.fixture(invalid=True)
        status, events, _ = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'secure_payload_invalid', events)
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])

    def test_target_conflict(self):
        self.fixture()
        ssh = self.home / '.ssh'
        ssh.mkdir(mode=0o700)
        bundle.write_file(ssh / 'id_disposable', b'preserved existing identity')
        status, events, _ = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'secure_target_conflict', events)
        self.assertEqual(events[-1]['data']['verification']['details']['status'], 'complete')
        self.assertTrue(any(row['outcome'] == 'skipped' and row['reason'] == 'target_conflict' for row in
                            events[-1]['data']['verification']['details']['operation_records']))

        self.assertEqual((ssh / 'id_disposable').read_bytes(), b'preserved existing identity')
        self.assertEqual(events[-1]['data']['verification']['status'], 'complete', events)
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])

    def test_missing_channel(self):
        self.fixture()
        result, events = self.execute(self.plan, secure=True)
        self.assertEqual(events[-1]['data']['code'], 'secure_bridge_required')
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_invalid_descriptor(self):
        self.fixture()
        _, events, _ = self.peer(invalid_fd=True)
        self.assertEqual(events[-1]['data']['code'], 'secure_bridge_required')

    def test_age_broken(self):
        self.fixture()
        path = self.root / 'bin/age'
        path.unlink()
        path.write_text('#!/bin/bash\nexit 2\n')
        path.chmod(0o700)
        _, stale, _ = self.peer()
        self.assertEqual(stale[-1]['data']['code'], 'stale_plan')
        result, prepared = self.invoke(secure=True)
        self.assertEqual(result.returncode, 0, prepared)
        self.plan = prepared[1]['data']['prepared_plan_id']
        _, events, challenges = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'age_unavailable')
        self.assertFalse(challenges)
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_stale_plan(self):
        self.fixture()
        _, events, challenges = self.peer(plan='0' * 64)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(challenges)
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_age_absent(self):
        self.fixture()
        (self.root / 'bin/age').unlink()
        self.environment['PATH'] = str(self.root / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'
        result, prepared = self.invoke(secure=True)
        self.assertEqual(result.returncode, 0, prepared)
        self.plan = prepared[1]['data']['prepared_plan_id']
        _, events, challenges = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'age_required', events)
        self.assertFalse(challenges)
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_age_child_failure(self):
        self.fixture()
        path = self.root / 'bin/age'
        path.unlink()
        path.write_text('#!/bin/bash\n[[ "$1" == --version ]] && exit 0\nexit 2\n')
        path.chmod(0o700)
        _, events, _ = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'secure_tool_failed', events)
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])

    def test_secure_child_failure(self):
        self.fixture()
        path = self.project / 'scripts/ssh-identity-migrate.sh'
        path.write_text('#!/bin/bash\nexit 2\n')
        _, events, _ = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'secure_import_failed', events)
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])

    def test_channel_timeout(self):
        self.fixture()
        path = self.project / 'modules/migration/secret_input.py'
        path.write_text(path.read_text().replace('WAIT_SECONDS = 120', 'WAIT_SECONDS = 1'))
        _, events, _ = self.peer(lambda c, n, p: 'wait')
        self.assertEqual(events[-1]['data']['code'], 'secure_channel_timeout', events)
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])

    def test_another_ciphertext_cannot_use_plan(self):
        self.fixture()
        (self.stage / 'secure.age').write_bytes(b'age-encryption.org/v1\ndifferent disposable ciphertext')
        self.archive.unlink()
        bundle.pack(self.stage, self.archive, '/Users/source')
        _, events, challenges = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'stale_plan', events)
        self.assertFalse(challenges)
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_post_publication_failure_preserves_mutation(self):
        self.fixture()
        # Exact-byte pair proof can avoid a second ssh-keygen call. Permissions
        # must still be checked after publication, independently of that proof.
        path = self.project / 'modules/migration/package.sh'
        source = path.read_text()
        boundary = "            evidence.phase = 'post_apply'\n"
        self.assertEqual(source.count(boundary), 1)
        path.write_text(source.replace(boundary, boundary +
                        "            os.chmod(os.path.join(ssh, records[0][0]), 0o644)\n"))
        status, events, _ = self.peer()
        self.assertNotEqual(status, 0, events)
        self.assertEqual(events[-1]['type'], 'failed', events)
        self.assertTrue(events[-1]['data']['target_mutation_may_have_started'], events)
        self.assertFalse((self.home / '.ssh').exists(), 'only importer-created files rolled back')
        self.assertEqual(sum(e['type'] == 'secure_publication_started' for e in events), 1)

    def test_secret_fd_and_argv_environment_isolation(self):
        self.fixture()
        # Check all descriptors in each secret consumer, including its --version
        # prerequisite process. The socket identity is metadata, never a secret.
        path = self.root / 'bin/age'
        path.unlink()
        path.write_text('#!/usr/bin/env python3\n'
                        'import os,sys,stat\n'
                        'identity=os.environ.get("TEST_EXTERNAL_SOCKET","")\n'
                        'for fd in range(3,256):\n'
                        ' try: s=os.fstat(fd)\n'
                        ' except OSError: continue\n'
                        ' assert str(s.st_dev)+":"+str(s.st_ino)!=identity\n'
                        ' assert not stat.S_ISSOCK(s.st_mode)\n'
                        'for secret in (' + repr(BUNDLE_SECRET) + ',' + repr(KEY_SECRET) + '):\n'
                        ' assert all(secret not in a for a in sys.argv)\n'
                        ' assert all(secret not in v for v in os.environ.values())\n'
                        'with open(os.environ["TEST_ISOLATION_CHECKS"],"a") as f: f.write("checked\\n")\n'
                        'os.execv(' + repr(REAL_AGE) + ',[' + repr(REAL_AGE) + ']+sys.argv[1:])\n')
        path.chmod(0o700)
        for name in ('dirname', 'cat'):
            wrapper = self.root / 'bin' / name
            wrapper.write_text(path.read_text().replace(repr(REAL_AGE), repr(shutil.which(name))))
            wrapper.chmod(0o700)
        self.environment['TEST_ISOLATION_CHECKS'] = str(self.root / 'isolation-checks')
        status, events, _ = self.peer()
        self.assertEqual(status, 0, events)
        self.assertGreaterEqual((self.root / 'isolation-checks').read_text().count('checked'), 3)

    def test_ordinary_scope_does_not_need_age_or_channel(self):
        # Existing settings/folders path retains its readiness contract.
        self.stage.joinpath('secure.age').unlink(missing_ok=True)
        bundle.pack(self.stage, self.archive, '/Users/source')
        result, events = self.invoke(secure=False)
        self.assertEqual(result.returncode, 0, events)
        self.assertFalse((self.root / 'mutations').exists())

    def test_bundle_cancel(self):
        self.failure(lambda c, n, p: 'cancel', 'secure_cancelled')

    def test_confirmation_eof(self):
        self.failure(lambda c, n, p: 'eof' if c['kind'] == 'import_confirmation' else None, 'secure_cancelled')

    def test_public_mode_600_noop_preserved(self):
        private, public = self.fixture()
        ssh = self.home / '.ssh'
        ssh.mkdir(mode=0o700)
        bundle.write_file(ssh / 'id_disposable', private)
        bundle.write_file(ssh / 'id_disposable.pub', public)
        status, events, _ = self.peer()
        self.assertEqual(status, 0, events)
        self.assertEqual((ssh / 'id_disposable.pub').stat().st_mode & 0o777, 0o600)
        self.assertFalse(events[-2]['data']['target_mutation_may_have_started'])

    def test_unusable_age_executable(self):
        self.fixture()
        path = self.root / 'bin/age'
        path.unlink()
        path.write_text('#!/bin/bash\nexit 0\n')
        path.chmod(0o600)
        # Keep a discoverable unusable entry but exclude another installed age.
        self.environment['PATH'] = str(self.root / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'
        result, prepared = self.invoke(secure=True)
        self.assertEqual(result.returncode, 0, prepared)
        self.plan = prepared[1]['data']['prepared_plan_id']
        _, events, _ = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'age_unavailable', events)
        self.assertFalse(events[-1]['data']['publication_started'])

    def test_repeated_restore_is_noop(self):
        self.fixture()
        status, events, _ = self.peer()
        self.assertEqual(status, 0, events)
        result, prepared = self.invoke(secure=True)
        self.assertEqual(result.returncode, 0, prepared)
        self.plan = prepared[1]['data']['prepared_plan_id']
        status, events, challenges = self.peer()
        self.assertEqual(status, 0, events)
        self.assertEqual([c['kind'] for c in challenges], ['bundle_unlock'])
        self.assertFalse(events[-2]['data']['target_mutation_may_have_started'])

    def test_unsolicited_extra_frame(self):
        def extra(challenge, count, child):
            body = bytes.fromhex(challenge['challenge_id']) + b'S' + BUNDLE_SECRET.encode()
            return struct.pack('!I', len(body)) + body + struct.pack('!I', 1) + b'x'
        self.failure(extra, 'secure_channel_invalid')

    def test_wrong_challenge_id(self):
        self.failure(lambda c, n, p: struct.pack('!I', 18) + bytes(16) + b'Sx', 'secure_channel_invalid')

    def test_confirmation_invalid_action(self):
        def answer(challenge, count, child):
            if challenge['kind'] == 'import_confirmation':
                body = bytes.fromhex(challenge['challenge_id']) + b'N'
                return struct.pack('!I', len(body)) + body
        self.failure(answer, 'secure_channel_invalid')

    def test_bundle_passphrase_does_not_unlock_key(self):
        self.fixture(protected=True)
        _, events, challenges = self.peer(lambda c, n, p: BUNDLE_SECRET if c['kind'] == 'ssh_key_unlock' else None)
        self.assertEqual(events[-1]['data']['code'], 'secure_key_unlock_rejected', events)
        self.assertEqual([c['attempt'] for c in challenges if c['kind'] == 'ssh_key_unlock'], [1, 2, 3])
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])

    def test_sigterm_after_publication_cleans_own_files(self):
        self.fixture()
        marker = self.root / 'publication-observed'
        self.environment['TEST_POST_PUBLICATION'] = str(marker)
        # Pause at the real post-publication boundary, even when exact-byte proof
        # means post-apply verification does not launch another ssh-keygen.
        path = self.project / 'modules/migration/package.sh'
        source = path.read_text()
        boundary = "            evidence.phase = 'post_apply'\n"
        self.assertEqual(source.count(boundary), 1)
        path.write_text(source.replace(boundary, boundary +
                        "            with open(os.environ['TEST_POST_PUBLICATION'], 'x'): pass\n"
                        "            __import__('time').sleep(30)\n"))
        workers = []
        def answer(challenge, count, child):
            if challenge['kind'] == 'import_confirmation':
                def cancel_after_publication():
                    end = time.monotonic() + 10
                    while child.poll() is None and time.monotonic() < end:
                        if marker.exists():
                            child.send_signal(signal.SIGTERM)
                            return
                        time.sleep(.01)
                worker = threading.Thread(target=cancel_after_publication, daemon=True)
                workers.append(worker)
                worker.start()
        status, events, _ = self.peer(answer)
        for worker in workers:
            worker.join(timeout=2)
        self.assertTrue(marker.exists())
        self.assertNotEqual(status, 0, events)
        self.assertEqual(events[-1]['type'], 'failed', events)
        self.assertEqual(events[-1]['data']['code'], 'cancelled', events)
        self.assertTrue(events[-1]['data']['target_mutation_may_have_started'])
        self.assertFalse((self.home / '.ssh').exists(), 'only current import files removed')

    def test_stage_ciphertext_symlink_rejected(self):
        self.fixture()
        alternate = self.root / 'other-disposable.age'
        shutil.copy2(self.stage / 'secure.age', alternate)
        self.environment['TEST_ALTERNATE_CIPHER'] = str(alternate.resolve())
        path = self.project / 'modules/bundle/bundle.py'
        with path.open('a') as source:
            source.write("\n_original_publish = publish\n"
                         "def publish(stage):\n"
                         "    _original_publish(stage)\n"
                         "    (stage / 'secure.age').unlink()\n"
                         "    (stage / 'secure.age').symlink_to(os.environ['TEST_ALTERNATE_CIPHER'])\n")
        _, events, challenges = self.peer()
        self.assertEqual(events[-1]['data']['code'], 'secure_payload_invalid', events)
        self.assertFalse(challenges, 'symlink cannot redirect the staged input')
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])
        self.assertFalse((self.home / '.ssh').exists())

    def write_mapping(self, mapping, operation_id):
        control = self.private_temp / 'secure-restore-destinations.json'
        control.write_text(json.dumps({'operation_id': operation_id, 'mapping': mapping}))
        control.chmod(0o600)

    def destination_prepare(self, mapping):
        self.write_mapping(mapping, 'destination-prepare')
        request = {'protocol_version': 1, 'operation_id': 'destination-prepare', 'operation': 'restore_prepare',
                   'parameters': {'path': str(self.archive), 'disabled_groups': [], 'include_secure': True,
                                  'custom_destinations': True}}
        result = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                input=json.dumps(request).encode(), cwd=self.project, env=self.environment,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30)
        return result.returncode, [json.loads(line) for line in result.stdout.splitlines()]

    def inventory_mapping(self, directories):
        status, events, challenges = self.peer(operation='secure_restore_inventory')
        self.assertEqual(status, 0, events)
        self.assertEqual([c['kind'] for c in challenges], ['bundle_unlock'])
        inventory = json.loads((self.private_temp / 'secure-restore-inventory.json').read_bytes())
        self.assertEqual(inventory['bundle_id'], bundle.fingerprint(self.archive))
        self.assertEqual(len(inventory['items']), len(directories))
        mapping = dict(version=1, bundle_id=inventory['bundle_id'], items=sorted([
            dict(identity_id=row['identity_id'], directory=str(directory) if directory else None)
            for row, directory in zip(inventory['items'], directories)], key=lambda row: row['identity_id']))
        for row in inventory['items']:
            for field in ('name', 'fingerprint', 'identity_id'):
                self.assertNotIn(row[field], json.dumps(events))
        return mapping, inventory

    def destination_comparison(self, mapping):
        status, events = self.destination_prepare(mapping)
        self.assertEqual(status, 0, events)
        prepared = events[1]['data']['prepared_plan_id']
        status, events, _ = self.peer(operation='secure_restore_compare', mapping=mapping, plan=prepared)
        self.assertEqual(status, 0, events)
        return prepared, next(row['data'] for row in events if row['type'] == 'result')

    def multiple_fixture(self, *, protected=False, count=2):
        pairs = {'id_disposable': self.fixture(protected=protected)}
        for name in ['id_external', 'id_third'][:count - 1]:
            key = self.root / name
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
            pairs[name] = (key.read_bytes(), Path(str(key) + '.pub').read_bytes())
        self.publish_pairs(pairs)
        return pairs

    def publish_pairs(self, pairs):
        lines = ['toolkit-ssh-identities', 'version=1', 'count=' + str(len(pairs))]
        for name, (private, public) in pairs.items():
            fp = 'SHA256:' + base64.b64encode(hashlib.sha256(base64.b64decode(public.split()[1])).digest()).decode().rstrip('=')
            lines.append('\t'.join((name, 'ssh-ed25519', fp, str(len(private)), hashlib.sha256(private).hexdigest(), str(len(public)), hashlib.sha256(public).hexdigest())))
        with tarfile.open(self.root / 'payload.tar', 'w', format=tarfile.USTAR_FORMAT) as archive:
            for name, raw in [('manifest', ('\n'.join(lines) + '\n').encode())] + [
                    ('keys/' + name + suffix, raw) for name, pair in pairs.items() for suffix, raw in zip(('', '.pub'), pair)]:
                member = tarfile.TarInfo(name); member.size = len(raw); archive.addfile(member, io.BytesIO(raw))
        (self.stage / 'secure.age').unlink(); self.archive.unlink()
        encrypt(REAL_AGE, self.root / 'payload.tar', self.stage / 'secure.age')
        (self.stage / 'secure.age').chmod(0o600)
        bundle.pack(self.stage, self.archive, '/Users/source')

    def selective_mapping(self, names, directories):
        mapping, inventory = self.inventory_mapping(directories)
        selected = {row['identity_id'] for row in inventory['items'] if row['name'] in names}
        mapping['version'] = 2
        for row in mapping['items']:
            row['selected'] = row['identity_id'] in selected
        return mapping, inventory

    def test_selective_protected_excluded_conflict_and_repeat(self):
        pairs = self.multiple_fixture(protected=True)
        target = self.root.resolve() / 'chosen-private'; target.mkdir(mode=0o700)
        unsafe = self.root.resolve() / 'excluded-unsafe'; unsafe.mkdir(mode=0o777); unsafe.chmod(0o777)
        preserved = unsafe / 'id_disposable.pub'; preserved.write_bytes(b'excluded conflict')
        before = preserved.stat()
        mapping, inventory = self.selective_mapping({'id_external'}, [unsafe, target])
        plan, comparison = self.destination_comparison(mapping)
        self.assertEqual(comparison['decision'], 'import_required')
        status, events, challenges = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertEqual(status, 0, events)
        self.assertEqual([c['kind'] for c in challenges], ['bundle_unlock', 'import_confirmation'])
        self.assertEqual(events[-2]['data']['verification']['verified_count'], 1)
        self.assertEqual((target / 'id_external').read_bytes(), pairs['id_external'][0])
        self.assertEqual((target / 'id_external.pub').read_bytes(), pairs['id_external'][1])
        self.assertEqual(preserved.read_bytes(), b'excluded conflict')
        self.assertEqual([getattr(preserved.stat(), k) for k in ('st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')],
                         [getattr(before, k) for k in ('st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')])
        self.assertEqual(unsafe.stat().st_mode & 0o777, 0o777)
        self.assertFalse((unsafe / 'id_disposable').exists()); self.assertFalse((self.home / '.ssh').exists())
        for value in [str(target), str(unsafe)] + [r[k] for r in inventory['items'] for k in ('identity_id', 'name', 'fingerprint')]:
            self.assertNotIn(value, json.dumps(events))
            for log in (self.project / 'logs').rglob('*'):
                if log.is_file(): self.assertNotIn(value.encode(), log.read_bytes())
        before = (target / 'id_external').stat()
        plan, comparison = self.destination_comparison(mapping)
        self.assertEqual(comparison['decision'], 'all_match')
        status, events, challenges = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0, events)
        self.assertEqual(events[-1]['data']['code'], 'no_executable_work')
        self.assertFalse(challenges)
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])
        self.assertEqual([getattr((target / 'id_external').stat(), k) for k in ('st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')],
                         [getattr(before, k) for k in ('st_ino', 'st_mode', 'st_size', 'st_mtime_ns', 'st_ctime_ns')])

    def test_selective_selected_conflict_blocks_subset(self):
        self.multiple_fixture(count=3)
        targets = [self.root.resolve() / name for name in ('one', 'two', 'excluded')]
        for target in targets: target.mkdir(mode=0o700)
        preserved = targets[1] / 'id_external.pub'; preserved.write_bytes(b'conflicting selected pair')
        mapping, _ = self.selective_mapping({'id_disposable', 'id_external'}, targets)
        plan, comparison = self.destination_comparison(mapping)
        self.assertEqual(comparison['decision'], 'conflict')
        status, events, challenges = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0); self.assertFalse(challenges)
        self.assertEqual(list(targets[0].iterdir()), []); self.assertEqual(list(targets[2].iterdir()), [])
        self.assertEqual(preserved.read_bytes(), b'conflicting selected pair')

    def test_selective_unselected_default_conflict_and_inactive_destination(self):
        pairs = self.multiple_fixture()
        ssh = self.home / '.ssh'; ssh.mkdir(mode=0o700)
        preserved = ssh / 'id_disposable.pub'; preserved.write_bytes(b'excluded default conflict')
        mapping, _ = self.selective_mapping({'id_external'}, [None, None])
        _, comparison = self.destination_comparison(mapping)
        self.assertEqual(comparison['decision'], 'import_required')
        unsafe = self.root.resolve() / 'unsafe-unused'; unsafe.mkdir(mode=0o700); unsafe.chmod(0o777)
        next(row for row in mapping['items'] if not row['selected'])['directory'] = str(unsafe)
        status, events = self.destination_prepare(mapping); self.assertEqual(status, 0, events)
        self.assertEqual(events[1]['data']['secure_destination_scope'], 'default')
        plan, comparison = self.destination_comparison(mapping)
        status, events, _ = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertEqual(status, 0, events)
        self.assertEqual((ssh / 'id_external').read_bytes(), pairs['id_external'][0])
        self.assertEqual(preserved.read_bytes(), b'excluded default conflict')
        self.assertFalse((ssh / 'id_disposable').exists()); self.assertEqual(list(unsafe.iterdir()), [])

    def test_selective_multiple_locations_and_legacy_whole_package(self):
        pairs = self.multiple_fixture()
        status, prepared = self.invoke(secure=True)
        self.assertEqual(status.returncode, 0, prepared)
        status, events, _ = self.peer(plan=prepared[1]['data']['prepared_plan_id'])
        self.assertEqual(status, 0, events)
        self.assertEqual(events[-2]['data']['verification']['verified_count'], 2)
        for name, pair in pairs.items(): self.assertEqual((self.home / '.ssh' / name).read_bytes(), pair[0])
        targets = [self.root.resolve() / name for name in ('first-location', 'second-location')]
        for target in targets: target.mkdir(mode=0o700)
        for suffix, raw in zip(('', '.pub'), pairs['id_disposable']):
            path = targets[0] / ('id_disposable' + suffix); path.write_bytes(raw); path.chmod(0o600)
        before = (targets[0] / 'id_disposable').stat()
        mapping, _ = self.selective_mapping(set(pairs), targets)
        plan, comparison = self.destination_comparison(mapping)
        status, events, _ = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertEqual(status, 0, events)
        self.assertEqual(events[-2]['data']['verification']['verified_count'], 2)
        self.assertEqual((targets[0] / 'id_disposable').stat().st_ino, before.st_ino)
        self.assertEqual((targets[0] / 'id_disposable').stat().st_mtime_ns, before.st_mtime_ns)
        for (name, pair), target in zip(pairs.items(), targets):
            self.assertEqual((target / name).read_bytes(), pair[0])
            self.assertEqual((target / (name + '.pub')).read_bytes(), pair[1])

    def test_selective_invalid_context_and_unknown_ids(self):
        self.multiple_fixture()
        mapping, _ = self.selective_mapping({'id_external'}, [None, None])
        for kind in ('duplicate', 'bad-id', 'non-bool', 'missing-flag', 'v1-with-flags', 'unknown-version', 'too-many'):
            invalid = json.loads(json.dumps(mapping))
            if kind == 'duplicate': invalid['items'][1]['identity_id'] = invalid['items'][0]['identity_id']
            elif kind == 'bad-id': invalid['items'][0]['identity_id'] = 'forged'
            elif kind == 'non-bool': invalid['items'][0]['selected'] = 1
            elif kind == 'missing-flag': del invalid['items'][0]['selected']
            elif kind == 'v1-with-flags': invalid['version'] = 1
            elif kind == 'unknown-version': invalid['version'] = 3
            else: invalid['items'] *= 17
            with self.subTest(kind=kind):
                status, events = self.destination_prepare(invalid)
                self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'secure_input_invalid')
        selected = next(row for row in mapping['items'] if row['selected'])
        selected['identity_id'] = 'a' * 64; mapping['items'].sort(key=lambda row: row['identity_id'])
        status, events = self.destination_prepare(mapping); self.assertEqual(status, 0, events)
        status, events, _ = self.peer(operation='secure_restore_compare', mapping=mapping, plan=events[1]['data']['prepared_plan_id'])
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'secure_target_changed')
        self.assertFalse((self.home / '.ssh').exists())

    def test_selective_zero_does_not_import_and_allows_ordinary(self):
        self.multiple_fixture(protected=True)
        (self.project / 'bin').mkdir()
        shutil.copy2(ROOT / 'scripts/install-bs.sh', self.project / 'scripts/install-bs.sh')
        shutil.copy2(ROOT / 'bin/bs', self.project / 'bin/bs')
        (self.root / 'bin/bs').symlink_to(self.project / 'bin/bs')
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[workspace-folders]\n', '[workspace-folders]\nProjects\n'))
        self.archive.unlink(); bundle.pack(self.stage, self.archive, '/Users/source')
        mapping, _ = self.selective_mapping(set(), [self.root.resolve() / 'missing-excluded', None])
        status, events = self.destination_prepare(mapping); self.assertEqual(status, 0, events)
        plan = events[1]['data']
        self.assertFalse(plan['include_secure'])
        self.assertTrue(any(row['domain'] != 'secure-ssh-identities' for row in plan['plan']))
        self.assertFalse(any(row['domain'] == 'secure-ssh-identities' for row in plan['plan']))
        status, events, challenges = self.peer(mapping=mapping, plan=plan['prepared_plan_id'])
        self.assertEqual(status, 0, events); self.assertFalse(challenges)
        self.assertEqual(events[-2]['data']['secure_restore_status'], 'not_selected')
        self.assertTrue((self.home / 'Projects').is_dir())
        self.assertFalse(any(row.get('phase') == 'secure_import' for row in events))
        self.assertFalse((self.home / '.ssh').exists())

    def test_selective_stale_selection_bundle_and_destination(self):
        pairs = self.multiple_fixture()
        target = self.root.resolve() / 'selected'; target.mkdir(mode=0o700)
        mapping, _ = self.selective_mapping({'id_external'}, [None, target])
        plan, comparison = self.destination_comparison(mapping)
        original = json.loads(json.dumps(mapping))
        for row in mapping['items']: row['selected'] = not row['selected']
        status, events, challenges = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'stale_plan'); self.assertFalse(challenges)
        mapping = original
        target.rename(target.with_name('previous')); target.mkdir(mode=0o700)
        status, events, challenges = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'stale_plan'); self.assertFalse(challenges)
        self.publish_pairs(pairs)
        status, events = self.destination_prepare(mapping)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'stale_plan')

    def test_selective_excluded_malformed_entry_still_rejected(self):
        pairs = self.multiple_fixture()
        mapping, _ = self.selective_mapping({'id_external'}, [None, None])
        pairs['id_disposable'] = (b'not an OpenSSH envelope', pairs['id_disposable'][1])
        self.publish_pairs(pairs)
        mapping['bundle_id'] = bundle.fingerprint(self.archive)
        status, events = self.destination_prepare(mapping); self.assertEqual(status, 0, events)
        status, events, challenges = self.peer(operation='secure_restore_compare', mapping=mapping, plan=events[1]['data']['prepared_plan_id'])
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'secure_payload_invalid')
        self.assertEqual([row['kind'] for row in challenges], ['bundle_unlock'])
        self.assertFalse((self.home / '.ssh').exists())

    def test_selective_password_cancel_and_interrupted_subset(self):
        self.multiple_fixture(count=3)
        targets = [self.root.resolve() / name for name in ('one', 'two', 'excluded')]
        for target in targets: target.mkdir(mode=0o700)
        preserved = targets[2] / 'id_third'; preserved.write_bytes(b'untouched excluded identity')
        mapping, _ = self.selective_mapping({'id_disposable', 'id_external'}, targets)
        plan, comparison = self.destination_comparison(mapping)
        for answer in ('wrong passphrase', 'cancel'):
            status, events, _ = self.peer(lambda *_: answer, operation='secure_restore_compare', mapping=mapping, plan=plan)
            self.assertNotEqual(status, 0)
            self.assertEqual(list(targets[0].iterdir()), []); self.assertEqual(list(targets[1].iterdir()), [])
        importer = self.project / 'modules/migration/package.sh'
        original = importer.read_text()
        marker = "        target_dir_still_visible(dirfd)\n        relative = name + suffix"
        self.assertEqual(original.count(marker), 1)
        for failure in ("raise OSError('disposable failure')", 'os.kill(os.getpid(), signal.SIGTERM)'):
            with self.subTest(failure=failure):
                plan, comparison = self.destination_comparison(mapping)
                importer.write_text(original.replace(marker, "        if name == 'id_external' and suffix == '.pub':\n            " + failure + '\n' + marker))
                status, events, _ = self.peer(mapping=mapping, plan=plan, comparison=comparison)
                importer.write_text(original)
                self.assertNotEqual(status, 0); self.assertTrue(events[-1]['data']['target_mutation_may_have_started'])
                self.assertEqual(list(targets[0].iterdir()), []); self.assertEqual(list(targets[1].iterdir()), [])
                self.assertEqual(preserved.read_bytes(), b'untouched excluded identity')
                self.assertFalse(any(e['type'] == 'verification_record' and e['data'].get('conformity') == 'verified' for e in events))

    def test_custom_destinations_mixed_and_repeated_preview(self):
        pairs = self.multiple_fixture()
        target = self.root.resolve() / 'private custom-ключи'; target.mkdir(mode=0o700)
        mapping, _ = self.inventory_mapping([None, target])
        plan, comparison = self.destination_comparison(mapping)
        repeat, again = self.destination_comparison(mapping)
        self.assertEqual(plan, repeat); self.assertEqual(comparison['target_state'], again['target_state'])
        self.assertEqual(comparison['decision'], 'import_required')
        status, events, _ = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertEqual(status, 0, events)
        for name, directory in [('id_disposable', self.home / '.ssh'), ('id_external', target)]:
            self.assertEqual((directory / name).read_bytes(), pairs[name][0])
            self.assertEqual((directory / (name + '.pub')).read_bytes(), pairs[name][1])
            self.assertEqual((directory / name).stat().st_mode & 0o777, 0o600)
        _, repeated = self.destination_comparison(mapping)
        self.assertEqual(repeated['decision'], 'all_match')
        for path in (target, target / 'id_external'):
            self.assertNotIn(str(path), json.dumps(events))
        for log in (self.project / 'logs').rglob('*'):
            if log.is_file(): self.assertNotIn(str(target).encode(), log.read_bytes())

    def test_custom_destinations_multiple_and_matching_pair(self):
        pairs = self.multiple_fixture()
        targets = [self.root.resolve() / name for name in ('custom-one', 'custom-two')]
        for directory in targets: directory.mkdir(mode=0o700)
        for suffix, raw in zip(('', '.pub'), pairs['id_disposable']):
            path = targets[0] / ('id_disposable' + suffix); path.write_bytes(raw); path.chmod(0o600)
        before = (targets[0] / 'id_disposable').stat()
        mapping, _ = self.inventory_mapping(targets)
        plan, comparison = self.destination_comparison(mapping)
        status, events, _ = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertEqual(status, 0, events)
        self.assertEqual((targets[0] / 'id_disposable').stat().st_ino, before.st_ino)
        self.assertEqual((targets[1] / 'id_external').read_bytes(), pairs['id_external'][0])
        self.assertFalse((self.home / '.ssh').exists())

    def test_custom_destination_conflict_blocks_entire_package(self):
        self.multiple_fixture()
        target = self.root.resolve() / 'custom'; target.mkdir(mode=0o700)
        mapping, _ = self.inventory_mapping([None, target])
        # A partial pair blocks every identity, including the default destination.
        (target / 'id_external.pub').write_bytes(b'preserve partial pair')
        plan, comparison = self.destination_comparison(mapping)
        self.assertEqual(comparison['decision'], 'conflict')
        status, events, challenges = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0); self.assertFalse(challenges)
        self.assertFalse((self.home / '.ssh').exists())
        self.assertEqual((target / 'id_external.pub').read_bytes(), b'preserve partial pair')

    def test_custom_destination_changed_after_preview(self):
        self.fixture()
        target = self.root.resolve() / 'custom'; target.mkdir(mode=0o700)
        mapping, _ = self.inventory_mapping([target])
        plan, comparison = self.destination_comparison(mapping)
        target.rename(target.with_name('old-custom')); target.mkdir(mode=0o700)
        status, events, challenges = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(challenges); self.assertEqual(list(target.iterdir()), [])
        # Changing only the selected mapping also invalidates preparation.
        mapping['items'][0]['directory'] = str(target.with_name('old-custom'))
        status, events, _ = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'stale_plan')

    def test_custom_destination_unsafe_and_case_collisions(self):
        private, public = self.fixture()
        target = self.root.resolve() / 'custom'; target.mkdir(mode=0o700)
        mapping, _ = self.inventory_mapping([target])
        for mode in (0o777, 0o770):
            target.chmod(mode)
            status, _ = self.destination_prepare(mapping); self.assertNotEqual(status, 0)
        target.chmod(0o700)
        alias = target.with_name('alias'); alias.symlink_to(target)
        mapping['items'][0]['directory'] = str(alias)
        status, _ = self.destination_prepare(mapping); self.assertNotEqual(status, 0)
        alias.unlink(); mapping['items'][0]['directory'] = str(target)
        for kind in ('case', 'symlink', 'hardlink', 'different'):
            with self.subTest(kind=kind):
                p = target / ('ID_DISPOSABLE' if kind == 'case' else 'id_disposable')
                q = target / 'id_disposable.pub'
                if kind == 'symlink': p.symlink_to(self.identity)
                elif kind == 'hardlink': os.link(self.identity, p)
                else: p.write_bytes(b'different' if kind == 'different' else private); p.chmod(0o600)
                q.write_bytes(public); q.chmod(0o644)
                _, comparison = self.destination_comparison(mapping)
                self.assertEqual(comparison['decision'], 'conflict')
                p.unlink(); q.unlink()

    def test_custom_inventory_wrong_password_cancel_and_bundle_binding(self):
        self.fixture()
        for answer in ('wrong disposable passphrase', 'cancel'):
            status, events, _ = self.peer(lambda *_: answer, operation='secure_restore_inventory')
            self.assertNotEqual(status, 0)
            self.assertFalse((self.private_temp / 'secure-restore-inventory.json').exists())
            self.assertFalse((self.home / '.ssh').exists())
        target = self.root.resolve() / 'custom'; target.mkdir(mode=0o700)
        mapping, _ = self.inventory_mapping([target])
        # Valid legacy Bundle v1 and the same identities, re-encrypted to new bytes.
        (self.stage / 'secure.age').unlink()
        encrypt(REAL_AGE, self.root / 'payload.tar', self.stage / 'secure.age')
        (self.stage / 'secure.age').chmod(0o600)
        self.archive.unlink(); bundle.pack(self.stage, self.archive, '/Users/source')
        self.assertNotEqual(mapping['bundle_id'], bundle.fingerprint(self.archive))
        status, events = self.destination_prepare(mapping)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'stale_plan')


    def test_custom_destination_identity_binding_and_required_compare(self):
        self.fixture()
        target = self.root.resolve() / 'custom'; target.mkdir(mode=0o700)
        mapping, _ = self.inventory_mapping([target])
        plan, comparison = self.destination_comparison(mapping)
        status, events, challenges = self.peer(mapping=mapping, plan=plan)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(challenges)
        mapping['items'][0]['identity_id'] = 'a' * 64
        status, events = self.destination_prepare(mapping)
        self.assertEqual(status, 0, events)
        plan = events[1]['data']['prepared_plan_id']
        status, events, _ = self.peer(operation='secure_restore_compare', mapping=mapping, plan=plan)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'secure_target_changed')
        self.assertEqual(list(target.iterdir()), [])

    def test_custom_destination_failed_and_interrupted_publication(self):
        self.multiple_fixture()
        target = self.root.resolve() / 'custom'; target.mkdir(mode=0o700)
        sentinel = target / 'preserve'; sentinel.write_bytes(b'existing user file')
        mapping, _ = self.inventory_mapping([None, target])
        importer = self.project / 'modules/migration/package.sh'
        original = importer.read_text()
        marker = '        target_dir_still_visible(dirfd)\n        relative = name + suffix'
        self.assertEqual(original.count(marker), 1)
        for failure in ("raise OSError('disposable failure')", 'os.kill(os.getpid(), signal.SIGTERM)'):
            with self.subTest(failure=failure):
                plan, comparison = self.destination_comparison(mapping)
                importer.write_text(original.replace(marker, "        if name == 'id_external' and suffix == '.pub':\n            " + failure + '\n' + marker))
                status, events, _ = self.peer(mapping=mapping, plan=plan, comparison=comparison)
                importer.write_text(original)
                self.assertNotEqual(status, 0, events)
                self.assertTrue(events[-1]['data']['target_mutation_may_have_started'])
                self.assertFalse((self.home / '.ssh').exists())
                self.assertEqual(list(target.iterdir()), [sentinel])
                self.assertEqual(sentinel.read_bytes(), b'existing user file')
                self.assertFalse(any(e['type'] == 'verification_record' and e['data'].get('conformity') == 'verified' for e in events))

    def test_custom_destination_target_change_during_consent(self):
        self.fixture()
        target = self.root.resolve() / 'custom'; target.mkdir(mode=0o700)
        mapping, _ = self.inventory_mapping([target])
        plan, comparison = self.destination_comparison(mapping)
        def changed(challenge, *_):
            if challenge['kind'] == 'import_confirmation':
                (target / 'id_disposable.pub').write_bytes(b'preserve competing file')
        status, events, _ = self.peer(changed, mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0); self.assertEqual(events[-1]['data']['code'], 'secure_target_changed')
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])
        self.assertFalse((target / 'id_disposable').exists())
        self.assertEqual((target / 'id_disposable.pub').read_bytes(), b'preserve competing file')

    def test_custom_destination_acl_and_disappearance(self):
        self.fixture()
        target = self.root.resolve() / 'custom'; target.mkdir(mode=0o700)
        mapping, _ = self.inventory_mapping([target])
        for rule, allowed in [('everyone allow add_file', False), ('everyone deny add_file', False), ('everyone deny delete', True)]:
            try:
                subprocess.run(['/bin/chmod', '+a', rule, str(target)], check=True)
                status, events = self.destination_prepare(mapping)
                self.assertEqual(status == 0, allowed, events)
            finally:
                subprocess.run(['/bin/chmod', '-N', str(target)], check=True)
        plan, comparison = self.destination_comparison(mapping)
        target.rmdir()
        status, events, challenges = self.peer(mapping=mapping, plan=plan, comparison=comparison)
        self.assertNotEqual(status, 0); self.assertFalse(challenges)
        self.assertFalse(target.exists()); self.assertFalse((self.home / '.ssh').exists())




class PairProofTests(unittest.TestCase):
    def test_target_change_between_comparison_and_proof_is_not_matching(self):
        # Exercise the actual embedded production function with a deterministic
        # observer race. Both byte sets may already have valid crypto proofs.
        source = (ROOT / 'modules/migration/package.sh').read_text().split("<<'PY'\n", 1)[1].rsplit('\nPY\n', 1)[0]
        tree = ast.parse(source)
        function = next(node for node in tree.body if isinstance(node, ast.FunctionDef) and node.name == 'target_plan')
        class Conflict(Exception):
            pass
        class Invalid(Exception):
            pass
        for changed in (False, True):
            records = [('fixture', 'ssh-ed25519', 'unused', b'saved-private', b'saved-public')]
            namespace = dict(home_check=lambda: None, ssh='/unused-fixture',
                             target_directory=lambda _: '/unused-fixture',
                             os=type('OS', (), {'listdir': staticmethod(lambda _: ['fixture', 'fixture.pub']), 'path': type('Paths', (), {'lexists': staticmethod(lambda _: True), 'join': staticmethod(lambda *x: '/'.join(x))})}),
                             owned=lambda *args: None, checked_bytes=lambda path, mode: b'saved-public' if path.endswith('.pub') else b'saved-private',
                             validate_pair=lambda *args, **kwargs: ('ssh-ed25519', 'unused', b'changed-private' if changed else b'saved-private', b'saved-public'),
                             Conflict=Conflict, Invalid=Invalid)
            exec(compile(ast.Module(body=[function], type_ignores=[]), '<production-target-plan>', 'exec'), namespace)
            if changed:
                with self.assertRaises(Conflict):
                    namespace['target_plan'](records)
            else:
                self.assertEqual(namespace['target_plan'](records), ['identical'])
            # Preview never reaches a cryptographic validator.
            namespace['validate_pair'] = lambda *args, **kwargs: self.fail('Preview attempted crypto unlock')
            self.assertEqual(namespace['target_plan'](records, cryptographic=False), ['identical'])


class ChallengeContextTests(unittest.TestCase):
    def challenge(self):
        return dict(type='challenge', protocol_version=2, operation_id='context-test',
                    challenge_id='a' * 32, kind='ssh_key_unlock', attempt=1,
                    identity=dict(name='fixture_identity', key_type='ssh-ed25519',
                                  fingerprint='SHA256:' + 'A' * 43, position=1, total=2))

    def valid(self, value, kinds={'ssh_key_unlock'}):
        return valid_challenge(value, 'context-test', kinds)

    def test_exact_context_and_compatibility(self):
        self.assertTrue(self.valid(self.challenge()))
        value = self.challenge()
        del value['identity']['position'], value['identity']['total']
        self.assertTrue(self.valid(value))
        for kind in ('bundle_unlock', 'bundle_encrypt', 'import_confirmation'):
            value = self.challenge()
            value.update(kind=kind, protocol_version=1)
            self.assertFalse(self.valid(value, {kind}))
            del value['identity']
            self.assertTrue(self.valid(value, {kind}))
        self.assertFalse(self.valid(self.challenge(), {'bundle_unlock'}))

    def test_invalid_identity_fails_closed(self):
        invalid = {'name': ['', '../key', 'key.pub', 'key\n', 'key\x1b', 'a' * 81, True, [], None],
                   'key_type': ['unknown', [], {}, None],
                   'fingerprint': ['SHA256:' + 'A' * 42, 'SHA256:' + 'A' * 42 + 'B', [], None],
                   'position': [0, 3, True, 1.0, '1', None],
                   'total': [0, 33, True, 2.0, '2', None]}
        for field, values in invalid.items():
            for item in values:
                with self.subTest(field=field, type=type(item).__name__):
                    value = self.challenge(); value['identity'][field] = item
                    self.assertFalse(self.valid(value))
        for field in self.challenge()['identity']:
            value = self.challenge(); del value['identity'][field]
            self.assertFalse(self.valid(value))
        value = self.challenge(); value['identity']['path'] = 'forbidden'
        self.assertFalse(self.valid(value))

    def test_identity_is_bound_to_strict_challenge(self):
        for field, item in [('operation_id', 'another-operation'), ('challenge_id', 'a' * 31),
                            ('challenge_id', 'a' * 32 + '\n'), ('kind', []), ('kind', 'unknown'),
                            ('protocol_version', 1), ('protocol_version', True), ('protocol_version', 2.0),
                            ('attempt', True), ('attempt', 0), ('attempt', 4), ('attempt', 1.0)]:
            value = self.challenge(); value[field] = item
            self.assertFalse(self.valid(value))
        value = self.challenge(); del value['identity']
        self.assertFalse(self.valid(value))
        value = self.challenge(); value['extra'] = 1
        self.assertFalse(self.valid(value))

    def test_duplicate_fields_rejected_before_forwarding(self):
        for value in ('{"kind":"ssh_key_unlock","kind":"bundle_unlock"}',
                      '{"identity":{"name":"first","name":"second"}}'):
            with self.assertRaises(ValueError):
                json.loads(value, object_pairs_hook=unique_fields)


class ChannelTests(unittest.TestCase):
    def test_stdin_descriptor_rejected(self):
        with self.assertRaises(ValueError):
            inherited_socket(0)

    def test_regular_file_rejected(self):
        fd = os.open(os.devnull, os.O_RDONLY)
        try:
            with self.assertRaises((OSError, ValueError)):
                inherited_socket(fd)
        finally:
            try:
                os.close(fd)
            except OSError:
                pass

    def test_wrong_nonce(self):
        with self.assertRaises(SecureError):
            response(b'x' * 16 + b'Spass', {'challenge_id': '0' * 32, 'kind': 'bundle_unlock'})

    def test_control_bytes_rejected(self):
        with self.assertRaises(SecureError):
            response(bytes(16) + b'Shello\n', {'challenge_id': '0' * 32, 'kind': 'bundle_unlock'})

    def test_secret_in_ordinary_json_rejected(self):
        request = dict(protocol_version=1, operation_id='invalid-secret-input', operation='restore_execute',
                       parameters=dict(path='/unused.mbt', disabled_groups=[], include_secure=True,
                                       expected_prepared_plan_id='0' * 64, passphrase=BUNDLE_SECRET))
        result = subprocess.run(['bash', str(ROOT / 'modules/core/application-interface/core.sh')],
                                input=json.dumps(request).encode(), stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, cwd=ROOT)
        self.assertEqual(json.loads(result.stdout)['data']['code'], 'invalid_request')
        self.assertNotIn(BUNDLE_SECRET.encode(), result.stdout + result.stderr)

    def test_connected_socket_is_noninheritable(self):
        peer, endpoint = socket.socketpair()
        channel = inherited_socket(endpoint.detach())
        try:
            self.assertFalse(os.get_inheritable(channel.fileno()))
        finally:
            peer.close()
            channel.close()

    def test_zero_length_frame(self):
        peer, endpoint = socket.socketpair()
        try:
            peer.sendall(bytes(4))
            with self.assertRaises(SecureError):
                receive(endpoint, time.monotonic() + 1)
        finally:
            peer.close()
            endpoint.close()

    def test_partial_frame_deadline(self):
        peer, endpoint = socket.socketpair()
        try:
            peer.sendall(b'\x00')
            with self.assertRaises(SecureError) as caught:
                receive(endpoint, time.monotonic() + .02)
            self.assertEqual(caught.exception.code, 'secure_channel_timeout')
        finally:
            peer.close()
            endpoint.close()

    def test_confirmation_secret_rejected(self):
        with self.assertRaises(SecureError):
            response(bytes(16) + b'Ysecret', {'challenge_id': '0' * 32, 'kind': 'import_confirmation'})

    def test_secret_limit(self):
        with self.assertRaises(SecureError):
            response(bytes(16) + b'S' + b'x' * 129, {'challenge_id': '0' * 32, 'kind': 'bundle_unlock'})

    def test_empty_secret_rejected(self):
        with self.assertRaises(SecureError):
            response(bytes(16) + b'S', {'challenge_id': '0' * 32, 'kind': 'bundle_unlock'})

    def test_invalid_utf8_rejected(self):
        with self.assertRaises(SecureError):
            response(bytes(16) + b'S\xff', {'challenge_id': '0' * 32, 'kind': 'bundle_unlock'})

    def test_tool_echo_and_controlling_tty(self):
        # Probe checks PTY isolation and echo before it requests/reads the secret.
        code = "import os,sys,termios; assert os.isatty(0); assert not termios.tcgetattr(0)[3]&termios.ECHO;\ntry: os.open('/dev/tty',os.O_RDONLY); sys.exit(5)\nexcept OSError: pass\nsys.stderr.write('Passphrase: ');sys.stderr.flush();assert sys.stdin.readline().strip()=='disposable-probe';print('safe')"
        # Run adapter in a new session, as the production owned importer is run.
        adapter = "import sys;sys.path.insert(0,sys.argv[1]);from secret_input import tool;s,o,d=tool([sys.executable,'-c',sys.argv[2]],b'disposable-probe');assert s==0 and o==b'safe\\n' and b'disposable-probe' not in d"
        result = subprocess.run([sys.executable, '-c', adapter, str(ROOT / 'modules/migration'), code],
                                start_new_session=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == '__main__':
    unittest.main()
