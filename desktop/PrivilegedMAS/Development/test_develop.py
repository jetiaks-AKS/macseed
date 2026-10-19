#!/usr/bin/env python3
"""Rootless updater policy tests; no sudo, service registration or MAS execution."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import os

spec = importlib.util.spec_from_file_location('develop', Path(__file__).parents[2] / 'Macseed/develop.py')
dev = importlib.util.module_from_spec(spec)
spec.loader.exec_module(dev)

class DeploymentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.app = Path(self.temp.name) / 'Macseed.app'
        self.app.mkdir(mode=0o755)
        self.file = self.app / 'Info.plist'
        self.file.write_text('fixture')
        self.file.chmod(0o644)

    def test_snapshot(self):
        self.assertEqual(dev.manifest(self.app)['Info.plist'][0], 0o644)
        self.file.write_text('changed')
        self.assertNotEqual(dev.manifest(self.app)['Info.plist'][1], dev.hashlib.sha256(b'fixture').hexdigest())

    def test_symlink(self):
        (self.app / 'link').symlink_to(self.file)
        with self.assertRaises(RuntimeError): dev.manifest(self.app)

    def test_hardlink(self):
        os.link(self.file, self.app / 'hardlink')
        with self.assertRaises(RuntimeError): dev.manifest(self.app)

    def test_writable(self):
        self.file.chmod(0o666)
        with self.assertRaises(RuntimeError): dev.manifest(self.app)

    def test_no_privilege_on_invalid_source(self):
        with patch.object(dev, 'SOURCE', self.app), patch.object(dev, 'run', wraps=dev.run) as invoke:
            self.file.chmod(0o666)
            with self.assertRaises(RuntimeError): dev.deploy()
            self.assertTrue(all(not c.kwargs.get('root', False) and not (len(c.args) > 1 and c.args[1]) for c in invoke.call_args_list))

    def test_component_compatibility(self):
        for name in ['Contents/Helpers/MASHelper', 'Contents/Helpers/mas', 'Contents/Library/LaunchDaemons/org.macseed.desktop.mas-helper.plist']:
            p = self.app / name; p.parent.mkdir(parents=True, exist_ok=True); p.write_text('fixture')
        with patch.object(dev, 'code_identity', return_value='fixture-cdhash'):
            self.assertTrue(dev.compatible(self.app, self.app))
        with patch.object(dev, 'code_identity', side_effect=['old', 'new']):
            self.assertFalse(dev.compatible(self.app, self.app))

    def test_uncertain_service_state(self):
        class Result: returncode = 1
        with patch.object(dev.subprocess, 'run', return_value=Result()):
            with self.assertRaises(RuntimeError): dev.helper_loaded()

    def test_native_status_parser(self):
        for status in range(4):
            self.assertEqual(dev.parse_native_status(f'Native registration status={status}\n'), status)
        for text in ['Native registration status=4', 'service_status=0', '', 'Native registration status=0\nextra']:
            with self.assertRaises(RuntimeError): dev.parse_native_status(text)

    def test_absent_registration(self):
        self.assertEqual(dev.registration_disposition(0, False), 'absent')
        self.assertEqual(dev.registration_disposition(3, False, False), 'absent')

    def test_registered(self):
        for status in [1, 2]:
            for loaded in [True, False]:
                self.assertEqual(dev.registration_disposition(status, loaded), 'registered')

    def test_uncertain_or_contradictory_registration(self):
        for args in [(0, True), (3, True, False), (3, False, True), (3, False, None), (9, False)]:
            with self.assertRaises(RuntimeError): dev.registration_disposition(*args)

    def test_btm_snapshot(self):
        header = ' Records for UID 501 : fixture\n'
        self.assertFalse(dev.btm_helper_present(header + 'Identifier: org.example.other\n'))
        self.assertTrue(dev.btm_helper_present(header + 'Identifier: 16.org.macseed.desktop.mas-helper\n'))
        with self.assertRaises(RuntimeError): dev.btm_helper_present('')
        with self.assertRaises(RuntimeError):
            dev.btm_helper_present(header + 'URL: /org.macseed.desktop.mas-helper.plist\n')

if __name__ == '__main__': unittest.main()
