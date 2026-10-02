#!/usr/bin/env python3
"""Disposable Core peer, real age/OpenSSH, and fail-closed channel regressions."""
import base64
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
from secret_input import SecureError, inherited_socket, receive, response, tool
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

    def peer(self, answer=None, plan=None, invalid_fd=False, timeout=30):
        parent, endpoint = socket.socketpair()
        fd = endpoint.fileno()
        identity = os.fstat(fd)
        self.environment['TEST_EXTERNAL_SOCKET'] = str(identity.st_dev) + ':' + str(identity.st_ino)
        request = {'protocol_version': 1, 'operation_id': 'secure-test', 'operation': 'restore_execute',
                   'parameters': {'path': str(self.archive), 'disabled_groups': [], 'include_secure': True,
                                  'expected_prepared_plan_id': plan or self.plan}}
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
            self.assertEqual(sum(e['type'] in ('failed', 'completed') for e in events), 1, events)
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
        real_keygen = shutil.which('ssh-keygen')
        path = self.root / 'bin/ssh-keygen'
        path.write_text('#!/bin/bash\n'
                        'if [[ "$1" == -y ]]; then\n'
                        '  if [[ -e "$HOME/.ssh/id_disposable" ]]; then exit 2; fi\n'
                        'fi\nexec ' + real_keygen + ' "$@"\n')
        path.chmod(0o700)
        _, events, _ = self.peer()
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
        real_keygen = shutil.which('ssh-keygen')
        path = self.root / 'bin/ssh-keygen'
        path.write_text('#!/bin/bash\n'
                        'if [[ "$1" == -y && -e "$HOME/.ssh/id_disposable" ]]; then\n'
                        ' : > "$TEST_POST_PUBLICATION"\n sleep 30\nfi\n'
                        'exec ' + real_keygen + ' "$@"\n')
        path.chmod(0o700)
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
        _, events, _ = self.peer(answer)
        for worker in workers:
            worker.join(timeout=2)
        self.assertTrue(marker.exists())
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
