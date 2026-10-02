#!/usr/bin/env python3
"""Real importer pairs/rollback, disposable HOME, mock age, strict evidence IPC."""
import base64
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location('evidence', ROOT / 'modules/migration/evidence.py')
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)


class IdentityEvidence(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.tools = self.root / 'bin'
        self.tools.mkdir()
        self.counter = self.root / 'decrypt-count'
        age = self.tools / 'age'
        age.write_text('#!/bin/sh\necho x >> "$EVIDENCE_TEST_COUNT"\n[ "${EVIDENCE_TEST_DECRYPT_FAIL:-0}" = 0 ] || exit 1\ncat "$2"\n')
        age.chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.tools) + ':' + os.environ['PATH'],
                        EVIDENCE_TEST_COUNT=str(self.counter), PYTHONDONTWRITEBYTECODE='1')
        self.env.pop('BASH_ENV', None)
        self.key = self.root / 'key'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(self.key)], check=True)
        self.package = self.root / 'package.age'
        self.build_package()
        self.endpoint_dir = self.root / 'evidence'
        self.endpoint_dir.mkdir(mode=0o700)
        self.endpoint = self.endpoint_dir / 'terminal'
        self.cli = str(ROOT / 'scripts/ssh-identity-migrate.sh')
        self.attempt = 'test-attempt'

    def build_package(self, mismatched=False):
        private = self.key.read_bytes()
        public = self.key.with_suffix('.pub').read_bytes()
        if mismatched:
            other = self.root / 'other'
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(other)], check=True)
            public = other.with_suffix('.pub').read_bytes()
        blob = base64.b64decode(public.split()[1])
        fp = 'SHA256:' + base64.b64encode(hashlib.sha256(blob).digest()).decode().rstrip('=')
        manifest = ('toolkit-ssh-identities\nversion=1\ncount=1\n' + '\t'.join([
            'id_test', 'ssh-ed25519', fp, str(len(private)), hashlib.sha256(private).hexdigest(),
            str(len(public)), hashlib.sha256(public).hexdigest()]) + '\n').encode()
        with tarfile.open(self.package, 'w', format=tarfile.USTAR_FORMAT) as archive:
            for name, raw in [('manifest', manifest), ('keys/id_test', private), ('keys/id_test.pub', public)]:
                info = tarfile.TarInfo(name)
                info.size = len(raw)
                archive.addfile(info, io.BytesIO(raw))
        self.package.chmod(0o600)

    def execute(self, command, answer=b'import'):
        master, slave = pty.openpty()
        process = subprocess.Popen(command, stdin=slave, stdout=slave, stderr=slave,
                                   env=self.env, cwd=ROOT, start_new_session=True)
        os.close(slave)
        transcript = b''
        deadline = time.monotonic() + 20
        sent = False
        while process.poll() is None and time.monotonic() < deadline:
            if select.select([master], [], [], .05)[0]:
                try:
                    chunk = os.read(master, 65536)
                    if not chunk:
                        break
                    transcript += chunk
                except OSError:
                    break
            if not sent and b'Type import' in transcript:
                os.write(master, answer + b'\n')
                sent = True
        try:
            status = process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            self.fail('importer timed out')
        while select.select([master], [], [], 0)[0]:
            try:
                chunk = os.read(master, 65536)
                if not chunk:
                    break
                transcript += chunk
            except OSError:
                break
        os.close(master)
        self.assertNotIn(b'BEGIN OPENSSH PRIVATE KEY', transcript)
        return status, transcript

    def imported(self, answer=b'import'):
        status, output = self.execute([self.cli, 'import', '--input', str(self.package),
                                      '--internal-evidence', str(self.endpoint), '--attempt', self.attempt], answer)
        raw = evidence.read_evidence(str(self.endpoint), self.attempt, status)
        self.assertNotIn(b'SHA256:', raw)
        self.assertNotIn(b'PRIVATE KEY', raw)
        self.assertNotIn(self.key.read_bytes(), raw)
        self.assertNotIn(self.key.with_suffix('.pub').read_bytes().strip(), raw)
        self.assertNotIn(str(self.root).encode(), raw)
        for payload in (self.key.read_bytes(), self.key.with_suffix('.pub').read_bytes()):
            self.assertNotIn(hashlib.sha256(payload).hexdigest().encode(), raw)
        return status, raw, output

    def target(self, different=False, partial=False):
        directory = self.home / '.ssh'
        directory.mkdir(mode=0o700)
        target = directory / 'id_test'
        if different:
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(target)], check=True)
        else:
            shutil.copyfile(self.key, target)
            target.chmod(0o600)
            if not partial:
                shutil.copyfile(self.key.with_suffix('.pub'), directory / 'id_test.pub')
                (directory / 'id_test.pub').chmod(0o644)

    def test_import_and_identical(self):
        status, raw, _ = self.imported()
        self.assertEqual(status, 0)
        self.assertIn(b'\t1\tsuccess\tmatch\n', raw)
        self.assertIn(b'I\tid_test\tverified\t', raw)
        self.endpoint.unlink()
        status, raw, _ = self.imported()
        self.assertEqual(status, 0)
        self.assertIn(b'\tnoop\tmatch\n', raw)
        self.assertEqual(self.counter.read_text().splitlines(), ['x', 'x'])

    def test_different_conflict(self):
        self.target(different=True)
        before = (self.home / '.ssh/id_test').read_bytes()
        status, raw, _ = self.imported()
        self.assertEqual(status, 1)
        self.assertIn(b'\tskipped\ttarget_conflict\n', raw)
        self.assertIn(b'I\tid_test\tmismatch\t', raw)
        self.assertEqual((self.home / '.ssh/id_test').read_bytes(), before)

    def test_partial_and_unsafe_conflict(self):
        self.target(partial=True)
        for unsafe in (False, True):
            with self.subTest(unsafe=unsafe):
                if unsafe:
                    (self.home / '.ssh').chmod(0o755)
                status, raw, _ = self.imported()
                self.assertEqual(status, 1)
                self.assertIn(b'I\tid_test\tunverified\t', raw)
                self.assertNotIn(b'\tmismatch\t', raw)
                self.endpoint.unlink()

    def test_cancel(self):
        status, raw, _ = self.imported(b'no')
        self.assertEqual(status, 1)
        self.assertIn(b'\tcancelled\tcancelled\n', raw)
        self.assertIn(b'I\tid_test\tunverified\t', raw)
        self.assertFalse((self.home / '.ssh').exists())

    def test_decrypt_failure(self):
        self.env['EVIDENCE_TEST_DECRYPT_FAIL'] = '1'
        status, raw, _ = self.imported()
        self.assertEqual(status, 2)
        self.assertIn(b'\tunresolved\t0\tfailure\tdecrypt_failed', raw)
        self.assertNotIn(b'\nI\t', raw)

    def test_mismatched_pair_and_malformed(self):
        self.build_package(mismatched=True)
        for malformed in (False, True):
            with self.subTest(malformed=malformed):
                if malformed:
                    self.package.write_bytes(b'bad archive')
                status, raw, _ = self.imported()
                self.assertEqual(status, 2)
                self.assertIn(b'\tunresolved\t0\tfailure\tinput_invalid', raw)
                self.endpoint.unlink()

    def test_unlock_failure(self):
        # Existing reader recognizes incorrect-passphrase stderr and exhausts 3 attempts.
        keygen = self.tools / 'ssh-keygen'
        keygen.write_text('#!/bin/sh\necho "incorrect passphrase" >&2\nexit 255\n')
        keygen.chmod(0o700)
        status, raw, output = self.imported()
        self.assertEqual(status, 2)
        self.assertIn(b'after 3 attempts', output)
        self.assertIn(b'\tunresolved\t0\tfailure\tinput_invalid', raw)

    def test_post_validation_rollback(self):
        site = self.root / 'site'
        site.mkdir()
        (site / 'sitecustomize.py').write_text('''import os
original = os.open
def fail(path, flags, *a, **kw):
    if path == 'id_test' and not flags & os.O_CREAT and os.path.exists(os.path.join(os.environ['HOME'], '.ssh/id_test.pub')):
        raise OSError('fixture final read failure')
    return original(path, flags, *a, **kw)
os.open = fail
''')
        self.env['PYTHONPATH'] = str(site)
        status, raw, _ = self.imported()
        self.assertEqual(status, 1)  # Existing target_plan turns unsafe pair into Conflict.
        self.assertIn(b'\tfailure\tpost_validation_failed\n', raw)
        self.assertIn(b'I\tid_test\tunverified\t', raw)
        self.assertNotIn(b'\tverified\t', raw)
        self.assertFalse((self.home / '.ssh').exists())

    def test_strict_reader(self):
        _, good, _ = self.imported()
        changes = [good[:-1], good.replace(b'test-attempt', b'wrong-attempt'),
                   good.replace(b'END\n', b'FIN\n'), good.replace(b'\tvalidated\t1\t', b'\tvalidated\t2\t'),
                   good.replace(b'validated\t1', b'validated\t2').replace(b'\nEND', b'\n' + good.splitlines()[1] + b'\nEND'),
                   good.replace(b'\tid_test\t', b'\t../escape\t'),
                   good.replace(b'\tverified\t', b'\tunknown\t'),
                   good.replace(b'\tsuccess\t', b'\tfailure\t'), b'x' * 16385]
        for raw in changes:
            with self.subTest(raw=raw[:40]):
                self.endpoint.write_bytes(raw)
                with self.assertRaises((ValueError, UnicodeError)):
                    evidence.read_evidence(str(self.endpoint), self.attempt, 0)
        self.endpoint.write_bytes(good)
        self.endpoint.chmod(0o644)
        with self.assertRaises(ValueError):
            evidence.read_evidence(str(self.endpoint), self.attempt, 0)
        self.endpoint.chmod(0o600)
        linked = self.endpoint_dir / 'link'
        os.link(self.endpoint, linked)
        with self.assertRaises(ValueError):
            evidence.read_evidence(str(self.endpoint), self.attempt, 0)
        linked.unlink()
        self.endpoint.unlink()
        with self.assertRaises(OSError):
            evidence.read_evidence(str(self.endpoint), self.attempt, 0)
        self.endpoint.symlink_to(self.package)
        with self.assertRaises(OSError):
            evidence.read_evidence(str(self.endpoint), self.attempt, 0)
        self.endpoint.unlink()
        os.mkfifo(self.endpoint, 0o600)
        with self.assertRaises(ValueError):
            evidence.read_evidence(str(self.endpoint), self.attempt, 0)

    def test_restore_transport_collector(self):
        script = '''source modules/core/common/common.sh
source modules/core/verification/verification.sh
source modules/verification/ssh-identities.sh
verification_reset restore
BUNDLE_RESTORE_SECURE_FILE="$1"
secure_verification_import
status=$?
# Block readers after import: mapping must only consume evidence.
ssh-keygen(){ return 99; }; age(){ return 99; }; target_plan(){ return 99; }
GV_STARTED_AT=2999-01-01T00:00:00Z
GV_STATUS=complete
verify_ssh_identity_evidence
verification_aggregate
test "$status" = 0 && test "$GV_VERIFIED" = 1 && test "$GV_UNRESOLVED" = 0 &&
test "$GV_STARTED_AT" != 2999-01-01T00:00:00Z && test "${GV_O[3]}" = success
'''
        status, output = self.execute(['bash', '-c', script, 'test', str(self.package)])
        self.assertEqual(status, 0, output)
        self.assertEqual(self.counter.read_text().splitlines(), ['x'])
        self.assertFalse(self.endpoint.exists())

    def test_missing_evidence_never_verified(self):
        script = '''source modules/core/common/common.sh
source modules/core/verification/verification.sh
source modules/verification/ssh-identities.sh
verification_reset restore
BUNDLE_RESTORE_SECURE_FILE=selected
GV_SECURE_STATE=invalid
GV_SECURE_EXIT=0
GV_STATUS=complete
verify_ssh_identity_evidence
verification_aggregate
test "$GV_STATUS" = incomplete && test "$GV_VERIFIED" = 0 &&
test "$GV_UNRESOLVED" = 1 && test "${GV_O[3]}" = success
'''
        self.assertEqual(subprocess.run(['bash', '-c', script], cwd=ROOT, env=self.env).returncode, 0)

    def test_transport_cleanup_failure_preserves_result(self):
        temporary = mock.Mock(name='private-directory')
        temporary.name = str(self.endpoint_dir)
        temporary.cleanup.side_effect = OSError('fixture cleanup failure')
        child = mock.Mock()
        child.wait.return_value = 0
        with mock.patch.object(evidence.tempfile, 'TemporaryDirectory', return_value=temporary), \
                mock.patch.object(evidence.subprocess, 'Popen', return_value=child), \
                mock.patch.object(evidence, 'read_evidence', return_value=b''), \
                mock.patch.object(evidence.signal, 'signal'), \
                mock.patch.object(evidence.os, 'dup', side_effect=OSError('closed channel')):
            self.assertEqual(evidence.supervise(self.cli, str(self.package), self.attempt), 0)
        temporary.cleanup.assert_called_once()

    def test_invalid_transport_is_incomplete(self):
        # Real supervisor/strict reader and Bash mapper, synthetic terminal producer.
        fake = self.root / 'fake-importer'
        good = b'E\t1\ttest-attempt\tvalidated\t1\tsuccess\tmatch\nI\tid_test\tverified\t2026-09-30T00:00:00Z\tmatch\tpost_apply\nEND\n'
        invalid = [b'', good[:-4], good.replace(b'test-attempt', b'wrong'),
                   good.replace(b'END', b'BAD'), good.replace(b'validated\t1', b'validated\t2')]
        for index, raw in enumerate(invalid):
            with self.subTest(case=index):
                fake.write_text('#!/usr/bin/env python3\nimport sys\nfrom pathlib import Path\nPath(sys.argv[5]).write_bytes(' + repr(raw) + ')\nPath(sys.argv[5]).chmod(0o600)\n')
                fake.chmod(0o700)
                channel = self.root / 'channel'
                script = r"""source modules/core/common/common.sh
source modules/core/verification/verification.sh
source modules/verification/ssh-identities.sh
verification_reset restore
BUNDLE_RESTORE_SECURE_FILE=selected
GV_SECURE_ATTEMPT=test-attempt
python3 modules/migration/evidence.py "$1" selected test-attempt 9>"$2"
GV_SECURE_EXIT=$?
GV_SECURE_ROWS=()
while IFS= read -r row; do GV_SECURE_ROWS+=("$row"); done < "$2"
GV_SECURE_STATE=invalid
GV_STATUS=complete
verify_ssh_identity_evidence
verification_aggregate
test "$GV_SECURE_EXIT" = 0 && test "$GV_STATUS" = incomplete &&
test "$GV_VERIFIED" = 0 && test "$GV_UNRESOLVED" = 1 && test ! -s "$2"
"""
                result = subprocess.run(['bash', '-c', script, 'test', str(fake), str(channel)], cwd=ROOT, env=self.env)
                self.assertEqual(result.returncode, 0)

    def test_standalone_no_evidence(self):
        status, output = self.execute([self.cli, 'import', '--input', str(self.package)])
        self.assertEqual(status, 0)
        self.assertIn(b'Import verified', output)
        self.assertFalse(self.endpoint.exists())


if __name__ == '__main__':
    unittest.main()
