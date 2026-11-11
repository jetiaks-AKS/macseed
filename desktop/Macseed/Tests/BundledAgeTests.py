#!/usr/bin/env python3
"""Focused pinned-artifact and Desktop runtime boundary checks; disposable paths only."""
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import platform
import shutil
import subprocess
import sys
import tarfile
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
DESKTOP = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(DESKTOP.parents[1] / 'modules/migration'))
import age_runtime as runtime
spec = importlib.util.spec_from_file_location('prepare_age', DESKTOP / 'prepare-age.py')
prepare = importlib.util.module_from_spec(spec)
spec.loader.exec_module(prepare)
CACHE = DESKTOP / 'build/Dependencies/age-v1.3.2'


class BundledAgeTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # The app build prepares its native artifact only. Test both trusted
        # archives using the same verifier, without replacing the built helper.
        temporary = tempfile.TemporaryDirectory(prefix='macseed-age-preparation-', dir='/private/tmp')
        cls.addClassCleanup(temporary.cleanup)
        resources = Path(temporary.name) / 'Fixture.app/Contents/Resources'
        for architecture in runtime.ARTIFACTS:
            prepare.prepare(resources, architecture, CACHE)

    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix='macseed-bundled-age-', dir='/private/tmp')
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.home = self.root / 'home'; self.home.mkdir(mode=0o700)
        self.architecture = platform.machine()
        self.assertIn(self.architecture, runtime.ARTIFACTS)
        self.other_architecture = 'x86_64' if self.architecture == 'arm64' else 'arm64'
        self.bundle = self.root / 'Fixture.app'
        self.binary = self.bundle / runtime.RELATIVE_EXECUTABLE
        self.binary.parent.mkdir(parents=True)
        self.raw = self.artifact(self.architecture)
        self.binary.write_bytes(self.raw); self.binary.chmod(0o755)
        self.environment = patch.dict(os.environ, {runtime.DESKTOP_BUNDLE: str(self.bundle), 'PATH': '/usr/bin:/bin', 'HOME': str(self.home)})
        self.environment.start(); self.addCleanup(self.environment.stop)

    def artifact(self, architecture):
        name = 'amd64' if architecture == 'x86_64' else architecture
        return prepare.unpack(prepare.read_archive(CACHE / f'age-v1.3.2-darwin-{name}.tar.gz', architecture), architecture)[0]

    def test_pinned_archives_and_license(self):
        for architecture, name in [('arm64', 'arm64'), ('x86_64', 'amd64')]:
            binary, notice = prepare.unpack(prepare.read_archive(CACHE / f'age-v1.3.2-darwin-{name}.tar.gz', architecture), architecture)
            self.assertTrue(runtime.valid_binary(binary, architecture))
            self.assertFalse(runtime.valid_binary(binary, 'x86_64' if architecture == 'arm64' else 'arm64'))
            self.assertIn(b'The age Authors', notice); self.assertIn(b'The Go Authors', notice)
        self.assertEqual(subprocess.check_output([str(self.binary), '--version']).strip(), b'v1.3.2')

    def test_external_absent_fake_or_different_never_selected(self):
        self.assertIsNone(shutil.which('age'))
        self.assertEqual(runtime.executable(), str(self.binary))
        tools = self.root / 'bin'; tools.mkdir()
        fake = tools / 'age'; fake.write_text('#!/bin/sh\ntouch "' + str(self.root / 'hijacked') + '"\nexit 99\n'); fake.chmod(0o755)
        with patch.dict(os.environ, {'PATH': str(tools) + ':/opt/homebrew/bin:/usr/bin:/bin'}):
            self.assertEqual(runtime.executable(), str(self.binary))
            self.assertEqual(subprocess.check_output([runtime.executable(), '--version']).strip(), b'v1.3.2')
        self.assertFalse((self.root / 'hijacked').exists())

    def test_missing_corrupt_and_mode_fail_closed(self):
        for mode in ('missing', 'corrupt', 'nonexecutable', 'writable'):
            with self.subTest(mode=mode):
                self.binary.write_bytes(self.raw); self.binary.chmod(0o755)
                if mode == 'missing': self.binary.unlink()
                if mode == 'corrupt': self.binary.write_bytes(self.raw[:-1] + bytes([self.raw[-1] ^ 1]))
                if mode == 'nonexecutable': self.binary.chmod(0o644)
                if mode == 'writable': self.binary.chmod(0o777)
                with patch.dict(os.environ, {'PATH': '/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin'}):
                    self.assertIsNone(runtime.executable())

    def test_links_and_path_substitution_fail_closed(self):
        original = self.root / 'outside'; self.binary.rename(original)
        self.binary.symlink_to(original); self.assertIsNone(runtime.executable()); self.binary.unlink()
        os.link(original, self.binary); self.assertIsNone(runtime.executable()); self.binary.unlink()
        original.rename(self.binary)
        alias = self.root / 'Alias.app'; alias.symlink_to(self.bundle)
        self.assertIsNone(runtime.bundled_executable(str(alias)))
        helpers = self.binary.parent; moved = self.root / 'Helpers'; helpers.rename(moved); helpers.symlink_to(moved)
        self.assertIsNone(runtime.executable())
        for invalid in ('', '/usr/bin', str(self.bundle) + '/../Fixture.app', str(self.bundle) + '/Contents'):
            self.assertIsNone(runtime.bundled_executable(invalid))

    def test_cache_reuse_and_invalid_cache_rejected(self):
        resources = self.bundle / 'Contents/Resources'
        original_run = subprocess.run
        def offline(command, **kwargs):
            self.assertNotIn('/usr/bin/curl', command)
            return original_run(command, **kwargs)
        with patch.object(prepare.subprocess, 'run', offline):
            prepare.prepare(resources, self.architecture, CACHE)
            prepare.prepare(resources, self.architecture, CACHE)
        self.assertEqual(hashlib.sha256(self.binary.read_bytes()).hexdigest(), runtime.ARTIFACTS[self.architecture]['binary'])
        self.assertEqual(self.binary.stat().st_mode & 0o777, 0o755)
        self.assertEqual(hashlib.sha256((resources / 'ThirdPartyNotices/age-LICENSE.txt').read_bytes()).hexdigest(), runtime.LICENSE_SHA256)
        invalid = self.root / 'invalid-cache'; invalid.mkdir()
        name = 'amd64' if self.architecture == 'x86_64' else self.architecture
        (invalid / f'age-v1.3.2-darwin-{name}.tar.gz').write_bytes(b'not an official archive')
        with patch.object(prepare.subprocess, 'run', side_effect=AssertionError('unverified executable/download attempted')):
            with self.assertRaises(ValueError): prepare.prepare(resources, self.architecture, invalid)
        # Cold-cache dependency failures must propagate; no system age fallback.
        before = self.binary.read_bytes()
        for error in (FileNotFoundError('missing download tool'), subprocess.CalledProcessError(22, 'curl')):
            cache = self.root / 'unavailable-cache'
            with patch.object(prepare.subprocess, 'run', side_effect=error), self.assertRaises(type(error)):
                prepare.prepare(resources, self.architecture, cache)
            self.assertEqual(list(cache.iterdir()), [])
            self.assertEqual(self.binary.read_bytes(), before)

    def test_archive_extra_traversal_duplicate_and_links_rejected(self):
        raw = prepare.read_archive(CACHE / 'age-v1.3.2-darwin-arm64.tar.gz', 'arm64')
        for fault in ('extra', 'traversal', 'duplicate', 'symlink', 'hardlink'):
            output = io.BytesIO()
            with tarfile.open(fileobj=output, mode='w:gz') as target, tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as source:
                for member in source.getmembers():
                    data = source.extractfile(member) if member.isfile() else None
                    if member.name == 'age/age' and fault in ('symlink', 'hardlink'):
                        member.type = tarfile.SYMTYPE if fault == 'symlink' else tarfile.LNKTYPE
                        member.linkname = '/outside'; member.size = 0; data = None
                    target.addfile(member, data)
                if fault in ('extra', 'traversal', 'duplicate'):
                    target.addfile(tarfile.TarInfo({'extra': 'age/extra', 'traversal': '../outside', 'duplicate': 'age/age'}[fault]))
            with self.subTest(fault=fault), self.assertRaises(ValueError): prepare.unpack(output.getvalue(), 'arm64')

    def test_settings_diagnostic_identity_and_read_only(self):
        before = (self.binary.read_bytes(), self.binary.stat().st_mtime_ns, self.binary.stat().st_mode)
        result = runtime.inspect_bundle(str(self.bundle))
        self.assertEqual(result.diagnostic(), {'schema_version': 1, 'status': 'available', 'version': 'v1.3.2', 'architecture': self.architecture})
        self.assertEqual(result.executable, runtime.bundled_executable(str(self.bundle)))
        self.assertEqual(before, (self.binary.read_bytes(), self.binary.stat().st_mtime_ns, self.binary.stat().st_mode))
        raw = subprocess.check_output([sys.executable, '-I', '-B', str(Path(runtime.__file__)), '--inspect-bundle', str(self.bundle)])
        self.assertEqual(__import__('json').loads(raw), result.diagnostic())
        self.assertNotIn(str(self.bundle).encode(), raw)

    def test_settings_failures_share_runtime_boundary(self):
        for fault in ('missing', 'corrupt', 'wrong_architecture', 'mode', 'symlink', 'hardlink'):
            with self.subTest(fault=fault):
                if self.binary.exists() or self.binary.is_symlink(): self.binary.unlink()
                self.binary.write_bytes(self.raw); self.binary.chmod(0o755)
                if fault == 'missing': self.binary.unlink()
                if fault == 'corrupt': self.binary.write_bytes(b'not trusted code')
                if fault == 'wrong_architecture': self.binary.write_bytes(self.artifact(self.other_architecture))
                if fault == 'mode': self.binary.chmod(0o777)
                if fault in ('symlink', 'hardlink'):
                    outside = self.root / fault; self.binary.rename(outside)
                    if fault == 'symlink': self.binary.symlink_to(outside)
                    else: os.link(outside, self.binary)
                observed = runtime.inspect_bundle(str(self.bundle))
                self.assertEqual(observed.diagnostic(), {'schema_version': 1, 'status': 'missing' if fault == 'missing' else 'invalid'})
                self.assertIsNone(runtime.executable())
        with patch.object(runtime.os, 'open', side_effect=PermissionError(13, 'fixture permission error')):
            self.assertEqual(runtime.inspect_bundle(str(self.bundle)).status, 'unable_to_verify')
            self.assertIsNone(runtime.executable())
        self.assertEqual(runtime.inspect_bundle(str(self.bundle), 'unsupported').status, 'unable_to_verify')

    def test_cli_keeps_path_resolution(self):
        tools = self.root / 'cli'; tools.mkdir()
        external = tools / 'age'; external.write_text('#!/bin/sh\nexit 0\n'); external.chmod(0o755)
        environment = {key: value for key, value in os.environ.items() if key != runtime.DESKTOP_BUNDLE}
        environment['PATH'] = str(tools) + ':/usr/bin:/bin'
        with patch.dict(os.environ, environment, clear=True): self.assertEqual(runtime.executable(), str(external))
        command = 'source "$1/modules/bundle/commands.sh"; bundle_offer_age'
        result = subprocess.run(['/bin/bash', '-c', command, 'fixture', str(DESKTOP.parents[1])], env=environment, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.assertEqual(result.returncode, 0)


if __name__ == '__main__':
    unittest.main()
