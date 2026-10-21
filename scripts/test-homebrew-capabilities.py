#!/usr/bin/env python3
"""Focused generic Cask contracts. No real Homebrew lifecycle or authorization."""
import copy
import importlib.util
import io
import hashlib
import json
import os
from pathlib import Path
import plistlib
import signal
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'modules/apps/adapters'))
import homebrew_cask as cask
import homebrew_lifecycle as lifecycle
import homebrew


class Observer(cask.PublicObserver):
    def __init__(self):
        self.receipts = []
        self.jobs = False
        self.conflicting = False
        self.shared = False
        self.children = {}
        self.reads = []

    def packages(self, selectors):
        return copy.deepcopy(self.receipts or [{'id': s, 'present': False, 'paths': []} for s in selectors])

    def package_install_payloads(self, row, selectors):
        return copy.deepcopy(self.package_payloads)

    def package_ownership(self, packages):
        cask.require(not self.shared, cask.CONFLICT)

    def launchctl(self, labels, payloads, orphan_labels=(), xpc_labels=()):
        cask.require(not self.jobs, cask.CONFLICT)
        return False

    def login_items(self, names, apps, orphan_names=()):
        cask.require(all(any(Path(app['path']).stem == name for app in apps) for name in names), cask.CONFLICT)

    def platform(self):
        return 'arm64', '15.6.1'

    def conflicts(self, value):
        cask.require(not self.conflicting, cask.CONFLICT)

    def cask(self, token):
        return self.children[token]


class CapabilityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='macseed-cask-contract-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / 'home'
        self.home.mkdir(mode=0o700)
        self.prefix = self.root / 'brew'
        (self.prefix / 'bin').mkdir(parents=True)
        (self.home / 'Applications').mkdir()
        self.item = self.root / 'items'
        self.item.mkdir(mode=0o700)
        environment = patch.dict(os.environ, HOME=str(self.home), BLUEPRINT_GENERATED_DIR=str(self.root / 'generated'),
                                 MACSEED_ITEM_STATE_DIR=str(self.item))
        environment.start()
        self.addCleanup(environment.stop)
        for sig in (signal.SIGINT, signal.SIGTERM):
            self.addCleanup(signal.signal, sig, signal.getsignal(sig))
        self.observer = Observer()
        self.app = self.home / 'Applications/Example.app'
        self.observer.package_payloads = [{'kind': 'app', 'path': str(self.app), 'package': 'org.example.Package'}]
        self.row = {'token': 'generic-example', 'installed': None, 'tap': 'homebrew/cask',
                    'disabled': False, 'version': '2.0', 'sha256': 'a' * 64,
                    'url': 'https://example.org/download.dmg', 'depends_on': {'macos': {'>=': ['12']}},
                    'artifacts': [{'app': ['Example.app'], 'target': str(self.app)}]}

    def classify(self, **kwargs):
        return cask.classify(self.row, self.prefix, self.observer, **kwargs)

    def test_appstore_marker_blocks_registered_cask_without_claiming_ownership(self):
        self.application()
        self.historical()
        before = (self.app / 'Contents/Info.plist').read_bytes()
        self.assertEqual(self.classify()['state'], 'satisfied')
        marker = self.app / 'Contents/_MASReceipt'
        marker.mkdir()
        for operation in (None, 'reinstall'):
            value = self.classify(operation=operation)
            self.assertEqual((value['state'], value['reason']), ('unsupported', cask.CONFLICT))
            self.assertEqual(value['diagnostic'], {'primitive': 'payload', 'condition': 'provider_conflict'})
            self.assertNotIn('qualification_id', value)
        self.assertEqual((self.app / 'Contents/Info.plist').read_bytes(), before)
        marker.rmdir()
        # Malformed/dangling receipt evidence is also protected, never trusted.
        marker.symlink_to(self.root / 'absent-receipt')
        self.assertEqual(self.classify(operation='reinstall')['reason'], cask.CONFLICT)

    def test_provider_change_invalidates_existing_reinstall_qualification(self):
        self.historical()
        accepted = self.classify(operation='reinstall')
        self.assertIn('qualification_id', accepted)
        self.application()
        (self.app / 'Contents/_MASReceipt').mkdir()
        current = self.classify(operation='reinstall')
        self.assertNotIn('qualification_id', current)
        self.assertEqual(current['diagnostic']['condition'], 'provider_conflict')

    def application(self, target=None):
        app = target or self.app
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.example.Application', 'CFBundleExecutable': 'Example'}))
        binary = app / 'Contents/MacOS/Example'
        binary.write_text('#!/bin/sh\n')
        binary.chmod(0o700)

    def historical(self, artifacts=None):
        directory = self.prefix / 'Caskroom/generic-example/.metadata'
        directory.mkdir(parents=True)
        artifacts = artifacts or [{k: v for k, v in a.items() if k != 'target'} for a in self.row['artifacts']]
        (directory / 'INSTALL_RECEIPT.json').write_text(json.dumps({
            'uninstall_flight_blocks': False, 'source': {'tap': 'homebrew/cask', 'version': '1.0'},
            'uninstall_artifacts': artifacts}))
        (directory / 'config.json').write_text(json.dumps({'default': {'appdir': str(self.app.parent)}}))
        self.row['installed'] = '1.0'
        return directory

    def test_rosetta_prerequisite_states_and_refresh(self):
        self.row['caveats_rosetta'] = True
        states = [('x86_64', b'', 0, b'', 'installable', None),
                  ('arm64', b'', 0, b'', 'installable', None),
                  ('arm64', b'', 1, b'arch: posix_spawnp: /usr/bin/true: Bad CPU type in executable\n',
                   'unsupported', cask.ROSETTA_REQUIRED),
                  ('arm64', b'', 1, b'permission denied\n', 'observation_error', cask.OBSERVATION),
                  ('x86_64', b'1', 0, b'', 'installable', None)]
        for machine, translated, code, stderr, state, reason in states:
            with self.subTest(machine=machine, code=code, stderr=stderr), \
                 patch('homebrew_cask.platform.machine', return_value=machine), \
                 patch.object(self.observer, 'read', return_value=translated), \
                 patch('homebrew_cask.subprocess.run', return_value=subprocess.CompletedProcess([], code, b'', stderr)) as run:
                value = self.classify()
                self.assertEqual((value['state'], value['reason']), (state, reason), value)
                if reason == cask.ROSETTA_REQUIRED:
                    self.assertEqual(value['diagnostic'], {'primitive': 'rosetta', 'condition': 'installation_required'})
                    self.assertNotIn('qualification_id', value)
                if machine == 'x86_64' and translated == b'':
                    run.assert_not_called()
                else:
                    self.assertEqual(run.call_args.args[0], ['/usr/bin/arch', '-x86_64', '/usr/bin/true'])
                    self.assertEqual(run.call_args.kwargs['env'], {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'LC_ALL': 'C'})
                    self.assertEqual(run.call_args.kwargs['stdin'], subprocess.DEVNULL)
                    self.assertEqual(run.call_args.kwargs['timeout'], 5)
        # Every classification observes afresh; installation is never cached.
        with patch.object(self.observer, 'rosetta_available', side_effect=[False, True]):
            self.assertEqual(self.classify()['reason'], cask.ROSETTA_REQUIRED)
            self.assertEqual(self.classify()['state'], 'installable')
        with patch.object(self.observer, 'rosetta_available', return_value=True):
            self.observer.conflicting = True
            self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_rosetta_observation_failures_and_unrequired_cask(self):
        with patch.object(self.observer, 'rosetta_available', side_effect=AssertionError('unneeded observation')):
            self.assertEqual(self.classify()['state'], 'installable')
        self.row['caveats_rosetta'] = True
        for failure in (OSError('unavailable'), subprocess.TimeoutExpired('probe', 5)):
            with self.subTest(failure=type(failure).__name__), \
                 patch('homebrew_cask.platform.machine', return_value='arm64'), \
                 patch('homebrew_cask.subprocess.run', side_effect=failure):
                value = self.classify()
                self.assertEqual((value['state'], value['reason']), ('observation_error', cask.OBSERVATION))
                self.assertEqual(value['diagnostic'], {'primitive': 'rosetta', 'condition': 'observation_failed'})
        with patch('homebrew_cask.platform.machine', return_value='x86_64'), \
             patch.object(self.observer, 'read', side_effect=OSError('sysctl failed')):
            self.assertEqual(self.classify()['state'], 'observation_error')
        with patch('homebrew_cask.platform.machine', return_value='x86_64'), \
             patch.object(self.observer, 'read', return_value=b'unknown'):
            self.assertEqual(self.classify()['state'], 'observation_error')

    def generated(self):
        self.row['artifacts'] = [{'binary': ['bin/example'], 'target': str(self.prefix / 'bin/example')},
            {cask.GENERATED_COMPLETIONS: ['bin/example', 'completion',
                {'base_name': None, 'shell_parameter_format': None, 'shells': ['bash', 'zsh', 'fish']}]}]

    def generated_files(self):
        executable = self.prefix / 'Caskroom/generic-example/2.0/bin/example'
        executable.parent.mkdir(parents=True, exist_ok=True)
        executable.write_text('#!/bin/sh\n')
        executable.chmod(0o700)
        link = self.prefix / 'bin/example'
        if not link.is_symlink():
            link.symlink_to(executable)
        for predicate in cask.completion_predicates(self.row['artifacts'][1][cask.GENERATED_COMPLETIONS], self.prefix):
            target = Path(predicate['path'])
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text('completion text\n')
        self.row['installed'] = '2.0'

    def test_generated_completion_capture_native_install_verify_repeat(self):
        self.generated()
        value = self.classify()
        self.assertEqual(value['state'], 'installable', value)
        self.assertEqual(len(value['evidence']), 4)
        self.generated_files()
        captured = cask.capture_rows({'casks': [self.row]}, self.prefix)
        source = self.root / 'generated/homebrew-casks.json'
        source.parent.mkdir()
        source.write_text(json.dumps(captured))
        cask.save_contract(self.row, self.prefix)
        self.assertEqual(self.classify()['state'], 'satisfied')
        (self.prefix / 'share/zsh/site-functions/_example').unlink()
        value = self.classify()
        self.assertEqual(value['state'], 'repairable', value)
        previous_environment = os.environ.get('HOMEBREW_NO_SUDO')
        with patch.dict(os.environ, HOMEBREW_NO_SUDO='1'):
            def native(executor, arguments, capture=False):
                self.assertEqual(arguments, ['brew', 'reinstall', '--cask', 'generic-example'])
                self.generated_files()
                executor.unquiescent = False
                return 0, b''
            with patch.object(lifecycle.ItemExecutor, 'run', native):
                self.assertEqual(lifecycle.unprivileged_run('reinstall', 'generic-example'), 0)
        self.assertEqual(os.environ.get('HOMEBREW_NO_SUDO'), previous_environment)
        self.assertEqual(self.classify(observation_only=True)['state'], 'satisfied')
        cask.save_contract(self.row, self.prefix)
        self.assertEqual(self.classify()['state'], 'satisfied')

    def test_generated_completion_damage_and_foreign_outputs_fail_closed(self):
        self.generated()
        self.generated_files()
        self.historical()
        (self.prefix / 'share/zsh/site-functions/_example').unlink()
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        self.row['installed'] = '2.0'
        self.generated_files()
        cask.save_contract(self.row, self.prefix)
        (self.prefix / 'share/zsh/site-functions/_example').unlink()
        target = self.prefix / 'etc/bash_completion.d/example'
        target.write_text('user edited completion\n')
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        target.unlink()
        target.symlink_to(self.home / 'foreign')
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_generated_completion_command_shell_integrity_boundaries(self):
        self.generated()
        original = copy.deepcopy(self.row)
        for invalid in ('script', 'erase', 'completion;sh'):
            self.row = copy.deepcopy(original)
            self.row['artifacts'][1][cask.GENERATED_COMPLETIONS][1] = invalid
            self.assertEqual(self.classify()['state'], 'unsupported')
        self.row = copy.deepcopy(original)
        self.row['sha256'] = 'no_check'
        self.assertEqual(self.classify()['state'], 'unsupported')
        self.row = copy.deepcopy(original)
        self.row['artifacts'][1][cask.GENERATED_COMPLETIONS][-1]['shells'] = ['unknown']
        self.assertEqual(self.classify()['state'], 'unsupported')
        self.row = copy.deepcopy(original)
        self.row['artifacts'][1][cask.GENERATED_COMPLETIONS][0] = '/usr/bin/security'
        self.assertEqual(self.classify()['state'], 'unsupported')
        self.row = copy.deepcopy(original)
        self.row['artifacts'][1][cask.GENERATED_COMPLETIONS][-1]['base_name'] = '../foreign'
        self.assertEqual(self.classify()['state'], 'unsupported')

    def test_generated_completion_evolution_binds_arguments_and_targets(self):
        self.generated()
        self.historical()
        value = self.classify()
        self.assertEqual(value['state'], 'repairable', value)
        self.row['artifacts'][1][cask.GENERATED_COMPLETIONS][1] = 'completions'
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        self.row['artifacts'][1][cask.GENERATED_COMPLETIONS][1] = 'completion'
        self.row['artifacts'][1][cask.GENERATED_COMPLETIONS][-1]['base_name'] = 'changed'
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_nonempty_requirements_registration_not_payload(self):
        self.assertEqual(self.classify()['state'], 'installable')
        self.historical()
        self.assertEqual(self.classify()['state'], 'repairable')
        self.application()
        self.assertEqual(self.classify()['state'], 'satisfied')
        self.row['artifacts'] = [{'zap': [{'trash': ['~/anything']}]}]
        self.assertEqual(self.classify()['state'], 'unsupported')
        self.row['artifacts'] = [{'pkg': ['Example.pkg']}, {'uninstall': [{'pkgutil': 'org.example.Package'}]}]
        self.assertNotEqual(self.classify()['state'], 'satisfied')

    def test_invalid_empty_bundle_and_foreign_destination(self):
        self.app.mkdir()
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        self.row['installed'] = '1.0'
        self.assertNotEqual(self.classify(observation_only=True)['state'], 'satisfied')
        self.app.rmdir()
        self.app.symlink_to('/missing/app')
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_current_quit_evolution_and_inactive_zap(self):
        self.historical()
        self.row['artifacts'].extend([{'uninstall': [{'quit': 'org.example.Application'}]},
                                      {'zap': [{'script': {'executable': '/dangerous'}}]}])
        self.assertEqual(self.classify()['state'], 'repairable')
        old = self.prefix / 'Caskroom/generic-example/.metadata/INSTALL_RECEIPT.json'
        data = json.loads(old.read_text())
        data['uninstall_artifacts'].append({'uninstall': [{'script': '/opaque'}]})
        old.write_text(json.dumps(data))
        self.assertEqual(self.classify()['state'], 'unsupported')

    def test_payload_identity_change_does_not_authorize_old_removal(self):
        self.historical()
        self.row['artifacts'][0] = {'app': ['Replacement.app'], 'target': str(self.app.parent / 'Replacement.app')}
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_links_wrappers_and_static_ancillary_files(self):
        self.row['artifacts'] += [
            {'binary': [str(self.app / 'Contents/MacOS/Example'), {'target': 'example'}], 'target': str(self.prefix / 'bin/example')},
            {'command_wrapper': ['example-wrapper', {'executable': str(self.app / 'Contents/MacOS/Example'),
                                                    'args': ['--cli'], 'env': {'LANG': 'C'}}],
             'target': str(self.prefix / 'bin/example-wrapper')}]
        self.historical()
        self.assertEqual(self.classify()['state'], 'repairable')
        self.application()
        (self.prefix / 'bin/example').symlink_to(self.app / 'Contents/MacOS/Example')
        owned = self.prefix / 'Caskroom/generic-example/owned-tool'
        owned.write_text('#!/bin/sh\n'); owned.chmod(0o700)
        (self.prefix / 'bin/example-wrapper').symlink_to(owned)
        self.assertEqual(self.classify()['state'], 'satisfied')
        (self.prefix / 'bin/example').unlink()
        (self.prefix / 'bin/example').symlink_to('/foreign/tool')
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_relocated_payload_classes(self):
        for artifact, directory in cask.RELOCATED.items():
            if artifact == 'app':
                continue
            destination = self.home / directory[0] / 'Example.bundle'
            destination.parent.mkdir(parents=True, exist_ok=True)
            self.row['artifacts'] = [{artifact: ['Example.bundle'], 'target': str(destination)}]
            value = self.classify()
            self.assertIn(value['state'], ('installable', 'unsupported'), value)
            if artifact == 'keyboard_layout':
                self.assertTrue(value['authorization_required'])
        self.row['artifacts'] = [{'artifact': ['data.txt', {'target': str(self.prefix / 'share/example/data.txt')}],
                                 'target': str(self.prefix / 'share/example/data.txt')}]
        (self.prefix / 'share/example').mkdir(parents=True)
        self.assertEqual(self.classify()['state'], 'installable')

    def test_static_links_suite_and_relocated_file_verification(self):
        owned = self.prefix / 'Caskroom/generic-example/static-payload'
        owned.parent.mkdir(parents=True)
        owned.write_text('payload')
        for artifact in cask.LINKED - {'binary'}:
            destination = self.prefix / 'share' / artifact / 'payload'
            destination.parent.mkdir(parents=True)
            destination.symlink_to(owned)
            self.row.update(installed='1.0', artifacts=[{artifact: ['payload'], 'target': str(destination)}])
            self.assertEqual(self.classify()['state'], 'satisfied')
        font = self.home / 'Library/Fonts/Example.ttf'
        font.parent.mkdir(parents=True)
        font.write_bytes(b'font payload')
        self.row['artifacts'] = [{'font': ['Example.ttf'], 'target': str(font)}]
        self.assertEqual(self.classify()['state'], 'satisfied')
        font.write_bytes(b'')
        self.assertNotEqual(self.classify(observation_only=True)['state'], 'satisfied')
        suite = self.home / 'Applications/Example Suite'
        suite.mkdir()
        self.row['artifacts'] = [{'suite': ['Example Suite'], 'target': str(suite)}]
        self.assertNotEqual(self.classify(observation_only=True)['state'], 'satisfied')
        self.application(suite / 'Member.app')
        self.assertEqual(self.classify()['state'], 'satisfied')
        required_suite = [{'kind': 'suite', 'path': str(suite),
                           'members': [{'name': 'Missing.app', 'bundle_id': 'org.example.Application'}]}]
        missing, _ = cask.observe(required_suite, self.row, self.prefix)
        self.assertEqual(len(missing), 1)
        required_suite[0]['members'][0]['name'] = '../Member.app'
        with self.assertRaises(cask.Unsafe):
            cask.observe(required_suite, self.row, self.prefix)

    def package(self):
        self.row['artifacts'] = [{'pkg': ['Example-2.pkg']}, {'uninstall': [{'pkgutil': 'org.example.Package'}]}]
        self.observer.receipts = [{'id': 'org.example.Package', 'present': True, 'location': str(self.app),
                                  'version': '1.0', 'paths': [str(self.app / 'Contents/Info.plist'),
                                                            str(self.app / 'Contents/MacOS/Example')]}]

    def captured_package(self):
        source = copy.deepcopy(self.row)
        source['installed'] = '1.0'
        value = cask.capture_rows({'casks': [source]}, self.prefix, self.observer)
        generated = self.root / 'generated'
        generated.mkdir(exist_ok=True)
        (generated / 'homebrew-casks.json').write_text(json.dumps(value))

    def test_package_local_evidence_never_downloads_during_classification(self):
        self.package()
        with patch.object(self.observer, 'package_install_payloads', side_effect=AssertionError('installer download')), \
             patch('homebrew_cask.urllib.request.urlopen', side_effect=AssertionError('network')):
            self.row['installed'] = '1.0'
            self.application()
            for options in ({}, {'observation_only': True}):
                self.assertEqual(self.classify(**options)['state'], 'satisfied')
            (self.app / 'Contents/MacOS/Example').unlink()
            self.assertEqual(self.classify(observation_only=True)['state'], 'repairable')
            self.captured_package()
            self.row['installed'] = None
            self.observer.receipts = []
            shutil.rmtree(self.app)
            for options in ({}, {'observation_only': True}, {'operation': 'install'}):
                value = self.classify(**options)
                self.assertEqual(value['state'], 'installable', value)
                self.assertTrue(any(p['kind'] == 'app' for p in value['evidence']))
            (self.root / 'generated/homebrew-casks.json').unlink()
            for installed in (None, '1.0'):
                self.row['installed'] = installed
                for options in ({}, {'observation_only': True}):
                    value = self.classify(**options)
                    self.assertEqual(value['state'], 'unsupported', value)
                    self.assertEqual(value['reason'], cask.UNSUPPORTED)
            with patch.object(self.observer, 'packages', side_effect=cask.Unsafe(cask.OBSERVATION)):
                self.assertEqual(self.classify(observation_only=True)['state'], 'observation_error')

    def pkg_preparation_fixture(self):
        self.row['artifacts'] = [{'pkg': ['Example.pkg']}, {'uninstall': [{'pkgutil': 'org.example.Package'}]}]
        self.observer.receipts = []
        self.observer.package_payloads = [{'kind': 'app', 'path': '/Applications/Example.app',
            'package': 'org.example.Package', 'bundle_id': 'org.example.Application'}]
        os.environ[cask.pkg_preparation.CONTEXT] = 'b' * 64
        self.observer.cask = lambda token: copy.deepcopy(self.row)
        self.observer.read = lambda args: b'/opt/homebrew'

    def test_pkg_explicit_consent_preparation_reuse_and_invalidation(self):
        self.pkg_preparation_fixture()
        with patch.object(self.observer, 'package_install_payloads', wraps=self.observer.package_install_payloads) as inspect:
            first = self.classify()
            self.assertEqual(first['diagnostic']['condition'], 'preparation_required')
            key = first['installer_preparation_id']
            self.classify(); inspect.assert_not_called()
            with patch.object(cask, 'PublicObserver', return_value=self.observer):
                with self.assertRaises(cask.Unsafe):
                    cask.prepare_packages([self.row['token']], ['f' * 64])
                inspect.assert_not_called()
                cask.prepare_packages([self.row['token']], [key])
            inspect.assert_called_once()
            prepared = self.classify()
            self.assertEqual(prepared['state'], 'installable', prepared)
            self.assertEqual(prepared['operation'], 'install')
            self.assertEqual(self.classify(), prepared)
            inspect.assert_called_once()
            for field, changed in [('version', '3.0'), ('sha256', 'c' * 64),
                                   ('url', 'https://example.org/new.pkg'), ('caveats', 'new conditions'),
                                   ('artifacts', [{'pkg': ['Other.pkg']}, {'uninstall': [{'pkgutil': 'org.example.Package'}]}])]:
                original = self.row.get(field)
                self.row[field] = changed
                self.assertNotEqual(self.classify().get('state'), 'installable', field)
                if original is None: self.row.pop(field, None)
                else: self.row[field] = original
            with patch.dict(os.environ, {cask.pkg_preparation.CONTEXT: 'd' * 64}):
                self.assertNotEqual(self.classify().get('state'), 'installable')
            record = cask.pkg_preparation.directory() / (key + '.json')
            value = json.loads(record.read_text()); value['created'] -= cask.pkg_preparation.TTL + 1
            record.write_text(json.dumps(value))
            self.assertEqual(self.classify()['state'], 'unsupported')
            self.assertEqual(record.stat().st_mode & 0o777, 0o600)
            self.assertEqual(record.parent.parent.stat().st_mode & 0o777, 0o700)
            self.assertNotIn(self.row['url'], record.read_text())

    def test_pkg_consent_only_prepares_listed_current_installers(self):
        self.pkg_preparation_fixture()
        second = copy.deepcopy(self.row); second['token'] = 'another-example'
        rows = {self.row['token']: self.row, second['token']: second}
        self.observer.cask = lambda token: copy.deepcopy(rows[token])
        key = self.classify()['installer_preparation_id']
        with patch.object(cask, 'PublicObserver', return_value=self.observer), \
             patch.object(self.observer, 'package_install_payloads', wraps=self.observer.package_install_payloads) as inspect:
            cask.prepare_packages(list(rows), [key])
            inspect.assert_called_once()
            self.assertEqual(inspect.call_args.args[0]['token'], self.row['token'])
        self.assertEqual(cask.classify(second, self.prefix, self.observer)['state'], 'unsupported')
        key = cask.classify(second, self.prefix, self.observer)['installer_preparation_id']
        payloads = copy.deepcopy(self.observer.package_payloads)
        def changed(row, selectors):
            second['sha256'] = 'c' * 64
            return payloads
        with patch.object(cask, 'PublicObserver', return_value=self.observer), \
             patch.object(self.observer, 'package_install_payloads', side_effect=changed), self.assertRaises(cask.Unsafe):
            cask.prepare_packages(list(rows), [key])
        self.assertIsNone(cask.pkg_preparation.load(key))

    def test_pkg_preparation_storage_rejects_foreign_links_and_special_files(self):
        self.pkg_preparation_fixture()
        key = self.classify()['installer_preparation_id']
        cask.pkg_preparation.save(key, [{'target': {'root': 'applications', 'relative': 'Example.app'},
            'bundle_id': 'org.example.Application', 'receipt': 'org.example.Package'}])
        record = cask.pkg_preparation.directory() / (key + '.json')
        self.assertIsNotNone(cask.pkg_preparation.load(key))
        foreign = self.root / 'foreign'; foreign.write_text(record.read_text())
        original = foreign.read_bytes()
        record.unlink(); record.symlink_to(foreign)
        self.assertIsNone(cask.pkg_preparation.load(key))
        self.assertEqual(foreign.read_bytes(), original)
        record.unlink(); os.mkfifo(record, 0o600)
        self.assertIsNone(cask.pkg_preparation.load(key))

    def test_pkg_incomplete_capture_preserves_receipt_identity(self):
        self.pkg_preparation_fixture()
        generated = self.root / 'generated'; generated.mkdir()
        source = generated / 'homebrew-casks.json'
        value = {'contract': 1, 'casks': {self.row['token']: {'state': 'unsupported',
            'reason': cask.UNSUPPORTED, 'required': []}}}
        source.write_text(json.dumps(value))
        self.assertIn('installer_preparation_id', self.classify())
        value['casks'][self.row['token']]['required'] = [{'kind': 'receipt', 'identity': 'org.foreign.Other'}]
        source.write_text(json.dumps(value))
        self.assertEqual(self.classify()['reason'], 'homebrew_metadata_incompatible')
        self.assertNotIn('installer_preparation_id', self.classify())

    def test_pkg_preparation_does_not_expand_repair_or_opaque_profiles(self):
        self.pkg_preparation_fixture()
        rosetta = patch.object(self.observer, 'rosetta_available', return_value=False)
        rosetta.start(); self.addCleanup(rosetta.stop)
        for field, value in [('installed', '1.0'), ('sha256', 'no_check'), ('caveats_rosetta', True)]:
            original = self.row.get(field)
            self.row[field] = value
            self.assertNotIn('installer_preparation_id', self.classify())
            if original is None: self.row.pop(field, None)
            else: self.row[field] = original
        key = self.classify()['installer_preparation_id']
        self.observer.package_payloads = []
        with patch.object(cask, 'PublicObserver', return_value=self.observer), self.assertRaises(cask.Unsafe):
            cask.prepare_packages([self.row['token']], [key])
        self.assertIsNone(cask.pkg_preparation.load(key))
        self.row['installed'] = '1.0'
        with patch.object(cask, 'observe', return_value=([], [])), \
             patch.object(self.observer, 'package_install_payloads', side_effect=AssertionError('matching download')):
            self.observer.receipts = [{'id': 'org.example.Package', 'present': True,
                                      'paths': ['/Applications/Example.app/Contents/MacOS/Example']}]
            self.assertEqual(self.classify()['state'], 'satisfied')

    def test_performance_external_timing_is_private_and_observational(self):
        import performance_trace as trace
        command = ['/usr/sbin/pkgutil', '--expand-full', '/private/secret.pkg', '/private/output']
        observer = cask.PublicObserver()
        completed = subprocess.CompletedProcess(command, 0, stdout=b'fixture', stderr=b'')
        with patch.object(trace, 'ENABLED', False), patch.object(trace, 'TOTALS', {}), \
             patch.object(trace.time, 'monotonic', side_effect=AssertionError('disabled clock')), \
             patch('homebrew_cask.subprocess.run', return_value=completed):
            self.assertEqual(observer.read(command), b'fixture')
            self.assertEqual(trace.TOTALS, {})
        with patch.object(trace, 'ENABLED', True), patch.object(trace, 'TOTALS', {}), \
             patch('homebrew_cask.subprocess.run', side_effect=[
                 completed, subprocess.TimeoutExpired(command, 30)]):
            self.assertEqual(observer.read(command), b'fixture')
            with self.assertRaises(subprocess.TimeoutExpired):
                observer.read(command)
            row = trace.TOTALS[trace.SCOPE + '.cask.external.pkgutil.expand']
            self.assertEqual(row['count'], 2)
            self.assertGreaterEqual(row['seconds'], row['max_seconds'])
            self.assertNotIn('/private', json.dumps(trace.TOTALS))
            self.assertNotIn('secret', json.dumps(trace.TOTALS))

    def test_public_native_package_inspection_binds_checksum_identity_and_target(self):
        row = copy.deepcopy(self.row)
        content = b'inert fixture package'
        row['sha256'] = hashlib.sha256(content).hexdigest()
        observer = cask.PublicObserver()
        commands = []
        layout = "direct"
        def expand(arguments):
            commands.append(arguments)
            self.assertEqual(arguments[:2], ['/usr/sbin/pkgutil', '--expand-full'])
            component = Path(arguments[-1]) / 'component.pkg'
            component.mkdir(parents=True)
            destination = '/Applications/Example.app' if layout == 'direct' else '/Applications'
            (component / 'PackageInfo').write_text('<pkg-info identifier="org.example.Package" install-location="' + destination + '"/>')
            payload = component / 'Payload'
            app = payload if layout == 'direct' else payload / 'Example.app'
            self.application(app)
            if layout == 'ambiguous':
                self.application(payload / 'Other.app')
            elif layout == 'framework':
                framework = app / 'Contents/Frameworks/Example.framework'
                (framework / 'Versions/B/Resources').mkdir(parents=True)
                (framework / 'Versions/Current').symlink_to('B')
                (framework / 'Resources').symlink_to('Versions/Current/Resources')
            elif layout == 'dangling':
                (app / 'missing').symlink_to('absent')
            elif layout == 'cycle':
                (app / 'cycle').symlink_to('cycle')
            elif layout == 'relative_escape':
                (app / 'escape').symlink_to('..')
            elif layout == 'symlink':
                (app / 'escape').symlink_to('/private')
            elif layout == 'hardlink':
                os.link(app / 'Contents/Info.plist', app / 'linked-info')
            return b''
        def response(*args, **kwargs):
            value = io.BytesIO(content)
            value.geturl = lambda: row['url']
            return value
        with patch('homebrew_cask.urllib.request.urlopen', side_effect=response), patch.object(observer, 'read', side_effect=expand):
            payload = observer.package_install_payloads(row, ['org.example.Package'])
            self.assertEqual(payload, [{'kind': 'app', 'path': '/Applications/Example.app',
                'package': 'org.example.Package', 'bundle_id': 'org.example.Application'}])
            self.assertFalse(Path(commands[-1][-1]).exists())
            with self.assertRaises(cask.Unsafe):
                observer.package_install_payloads(row, ['org.example.Foreign'])
            layout = 'applications'
            self.assertEqual(observer.package_install_payloads(row, ['org.example.Package']), payload)
            layout = 'framework'
            self.assertEqual(observer.package_install_payloads(row, ['org.example.Package']), payload)
            for layout in ('ambiguous', 'symlink', 'hardlink', 'dangling', 'cycle', 'relative_escape'):
                with self.subTest(layout=layout), self.assertRaises(cask.PreparationFailure) as failure:
                    observer.package_install_payloads(row, ['org.example.Package'])
                self.assertEqual(failure.exception.preparation_diagnostic['predicate'], 'payload_structure_unsupported')
            model = (ROOT / 'desktop/Macseed/Sources/RestoreModel.swift').read_text()
            self.assertIn('"payload_structure_unsupported"].contains(predicate)', model)
            self.assertIn('technicalReason = "pkg_preparation_failed · payload_validation · " + predicate', model)
            layout = 'direct'
            row['sha256'] = 'b' * 64
            previous = len(commands)
            with self.assertRaises(cask.Unsafe):
                observer.package_install_payloads(row, ['org.example.Package'])
            self.assertEqual(len(commands), previous)

    def test_native_package_caveats_clean_install_and_repair_are_distinct(self):
        self.package()
        self.captured_package()
        self.observer.receipts = []
        self.row['caveats'] = 'Activation may require user consent. See vendor license before installation.'
        value = self.classify()
        self.assertEqual(value['state'], 'installable', value)
        self.assertTrue(value['authorization_required'])
        self.assertEqual(value['execution']['requirements']['caveats'], self.row['caveats'])
        self.historical()
        self.assertEqual(self.classify()['state'], 'unsupported')
        self.assertEqual(self.classify()['diagnostic']['primitive'], 'lifecycle')
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_native_package_clean_install_rejects_receipts_and_delete_residuals(self):
        self.package()
        self.captured_package()
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        self.observer.receipts = []
        target = self.home / 'owned-wrapper'
        self.row['artifacts'][1]['uninstall'][0]['delete'] = str(target)
        target.write_text('residual state')
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        target.unlink()
        self.assertEqual(self.classify()['state'], 'installable')

    def test_absent_package_install_does_not_require_repair_cleanup_capability(self):
        self.package()
        self.captured_package()
        self.observer.receipts = []
        self.row['artifacts'][1]['uninstall'][0]['script'] = '/opaque/cleanup'
        self.assertEqual(self.classify()['state'], 'installable')
        self.historical()
        self.assertEqual(self.classify()['state'], 'unsupported')

    def test_native_package_verification_cannot_satisfy_receipt_only(self):
        self.package()
        self.row['installed'] = '2.0'
        self.observer.receipts[0]['paths'] = []
        self.assertNotEqual(self.classify(observation_only=True)['state'], 'satisfied')
        self.observer.receipts = []
        self.assertNotEqual(self.classify(observation_only=True)['state'], 'satisfied')
        self.row['installed'] = None
        self.row['artifacts'].append({'installer': [{'script': {'executable': 'opaque.sh'}}]})
        self.assertEqual(self.classify()['state'], 'unsupported')

    def pkg_repair_fixture(self):
        self.package()
        self.row['caveats'] = 'Activation requires separate user approval.'
        self.historical()
        target = self.root / 'receipt-owned-helper'
        target.write_text('installer-declared helper')
        self.observer.receipts[0]['paths'].append(str(target))
        self.row['artifacts'][1]['uninstall'][0]['delete'] = str(target)
        # Persist the same installed cleanup declaration, rather than inferring it.
        receipt = self.prefix / 'Caskroom/generic-example/.metadata/INSTALL_RECEIPT.json'
        data = json.loads(receipt.read_text())
        data['uninstall_artifacts'] = copy.deepcopy(self.row['artifacts'])
        receipt.write_text(json.dumps(data))
        return target

    def record_pkg_repair_fixture(self):
        target = self.pkg_repair_fixture()
        self.application()
        self.row['installed'] = self.row['version']
        self.observer.receipts[0]['version'] = self.row['version']
        with patch.object(cask, 'PublicObserver', return_value=self.observer):
            cask.save_contract(self.row, self.prefix)
        shutil.rmtree(self.app)
        return target

    def test_pkg_repair_legacy_receipt_ownership_and_caveats(self):
        self.pkg_repair_fixture()
        value = self.classify()
        self.assertEqual(value['state'], 'repairable', value)
        self.assertEqual(value['operation'], 'reinstall')
        self.assertEqual(value['execution']['pkg_ownership']['source'], 'legacy_receipts')
        self.assertTrue(value['authorization_required'])
        self.assertFalse((self.home / 'Library/Application Support/Macseed/Homebrew/contracts').exists())
        self.observer.shared = True
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_pkg_repair_manifest_and_missing_app(self):
        self.record_pkg_repair_fixture()
        value = self.classify()
        self.assertEqual(value['state'], 'repairable', value)
        manifest = value['execution']['pkg_ownership']
        self.assertEqual(manifest['source'], 'pkg_receipt_ownership')
        self.assertEqual(manifest['token'], self.row['token'])
        self.assertEqual(len(manifest['components']), 1)
        self.assertEqual(self.classify()['qualification_id'], value['qualification_id'])

    def test_pkg_repair_rejects_modified_or_replaced_component(self):
        target = self.record_pkg_repair_fixture()
        original = target.read_bytes()
        target.write_bytes(b'foreign replacement')
        self.assertEqual(self.classify()['diagnostic']['condition'], 'ownership_ambiguous')
        target.unlink()
        target.write_bytes(original)
        self.assertNotEqual(self.classify()['state'], 'repairable')

    def test_pkg_repair_rejects_stale_source_metadata_and_receipts(self):
        self.record_pkg_repair_fixture()
        self.row['sha256'] = 'b' * 64
        self.assertEqual(self.classify()['diagnostic']['condition'], 'ownership_ambiguous')
        self.row['sha256'] = 'a' * 64
        self.observer.receipts[0]['version'] = 'other'
        self.assertEqual(self.classify()['diagnostic']['condition'], 'ownership_ambiguous')

    def test_pkg_repair_legacy_unreceipted_wrapper_is_not_adopted(self):
        target = self.pkg_repair_fixture()
        self.observer.receipts[0]['paths'].remove(str(target))
        target.write_text('#!/bin/sh\n' + str(self.app / 'Contents/MacOS/Example') + ' "$@"\n')
        value = self.classify()
        self.assertEqual(value['state'], 'unsupported', value)
        self.assertEqual(value['diagnostic'], {'primitive': 'lifecycle', 'condition': 'ownership_unproven'})
        # A recorded installation must not grant authority over the same wrapper.
        self.application()
        self.row['installed'] = self.row['version']
        with patch.object(cask, 'PublicObserver', return_value=self.observer):
            cask.save_contract(self.row, self.prefix)
        shutil.rmtree(self.app)
        self.assertEqual(self.classify()['diagnostic']['condition'], 'ownership_unproven')

    def test_pkg_repair_caveats_do_not_allow_unknown_lifecycle(self):
        self.pkg_repair_fixture()
        self.row['artifacts'][1]['uninstall'][0]['script'] = '/opaque/uninstall'
        self.assertEqual(self.classify()['state'], 'unsupported')

    def test_package_receipt_plus_real_payload_and_repair(self):
        self.package()
        self.historical()
        value = self.classify()
        self.assertEqual(value['state'], 'repairable', value)
        self.assertTrue(value['authorization_required'])
        self.application()
        self.assertEqual(self.classify()['state'], 'satisfied')
        (self.app / 'Contents/MacOS/Example').unlink()
        self.assertNotEqual(self.classify(observation_only=True)['state'], 'satisfied')

    def test_payload_observation_is_independent_of_unsafe_cleanup(self):
        self.package()
        self.row['installed'] = '1.0'
        self.application()
        self.row['artifacts'][1]['uninstall'][0]['script'] = '/opaque/cleanup'
        self.assertEqual(self.classify()['state'], 'satisfied')
        (self.app / 'Contents/MacOS/Example').unlink()
        self.assertEqual(self.classify()['state'], 'unsupported')

    def test_package_components_share_one_required_app(self):
        self.package()
        component = copy.deepcopy(self.observer.receipts[0])
        component['id'] = 'org.example.Component'
        self.observer.receipts.append(component)
        self.row['artifacts'][1]['uninstall'][0]['pkgutil'] = ['org.example.Package', 'org.example.Component']
        self.historical()
        value = self.classify()
        self.assertEqual(value['state'], 'repairable', value)
        self.assertEqual(sum(p['kind'] == 'app' for p in value['evidence']), 1)
        self.assertEqual(sum(p['kind'] == 'receipt' for p in value['evidence']), 2)

    def test_package_fresh_install_and_missing_shared_receipt(self):
        self.package()
        self.captured_package()
        self.observer.receipts = []
        value = self.classify()
        self.assertEqual(value['state'], 'installable', value)
        self.assertTrue(value['authorization_required'])
        self.historical()
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        self.package()
        self.observer.shared = True
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_captured_package_fresh_install_has_payload_postconditions(self):
        self.package()
        self.row['installed'] = '1.0'
        value = cask.capture_rows({'casks': [self.row]}, self.prefix, self.observer)
        generated = self.root / 'generated'
        generated.mkdir()
        (generated / 'homebrew-casks.json').write_text(json.dumps(value))
        self.observer.receipts = []
        self.row['installed'] = None
        fresh = self.classify()
        self.assertEqual(fresh['state'], 'installable', fresh)
        self.assertTrue(any(p['kind'] == 'app' for p in fresh['evidence']))
        self.row['installed'] = '2.0'
        self.assertNotEqual(self.classify(observation_only=True)['state'], 'satisfied')

    def test_exact_cleanup_and_authorization_separate_from_support(self):
        self.historical()
        self.row['artifacts'].append({'uninstall': [{'delete': '/Library/Preferences/org.example.missing.plist',
                                                   'quit': 'org.example.Application'}]})
        value = self.classify()
        self.assertEqual(value['state'], 'repairable', value)
        self.assertTrue(value['authorization_required'])
        self.row['artifacts'][-1] = {'uninstall': [{'delete': '/Library/Preferences'}]}
        self.assertEqual(self.classify()['state'], 'unsupported')
        for key in ('trash', 'rmdir'):
            self.row['artifacts'][-1] = {'uninstall': [{key: str(self.app)}]}
            self.assertEqual(self.classify()['state'], 'repairable')

    def test_service_and_login_item_fail_closed(self):
        self.historical()
        self.row['artifacts'].append({'uninstall': [{'launchctl': 'org.example.Helper', 'login_item': 'Example'}]})
        self.assertEqual(self.classify()['state'], 'repairable')
        self.observer.jobs = True
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        for key, value in (('launchctl', 'org.example.*'), ('pkgutil', 'org.example.*'), ('delete', '~/Library/*')):
            with self.subTest(key=key), self.assertRaises(cask.Unsafe):
                cask.lifecycle([{'uninstall': [{key: value}]}])

    def test_public_service_evidence_matches_loaded_program(self):
        label = 'org.example.Helper'
        program = str(self.app / 'Contents/MacOS/Example')
        directory = self.home / 'Library/LaunchAgents'
        directory.mkdir(parents=True)
        (directory / (label + '.plist')).write_bytes(plistlib.dumps({'Label': label, 'Program': program}))
        observer = cask.PublicObserver()
        def read(arguments):
            if arguments[-1].endswith('/' + label):
                return ('program = ' + program + '\n').encode()
            if arguments[-1] == 'list':
                return ('PID Status Label\n- 0 ' + label + '\n').encode()
            if arguments[-1] == 'gui/' + str(os.getuid()):
                return ('services = {\n0 - ' + label + '\n}\n').encode()
            return b'services = {\n}\n'
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=read):
            self.assertFalse(observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}]))
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=lambda args: b'program = /foreign/service\n' if args[-1].endswith('/' + label) else read(args)):
            with self.assertRaises(cask.Unsafe):
                observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}])

    def public_jobs(self, programs=None, domains=('user',), state='waiting', extra=''):
        label = 'org.example.Helper'
        observer = cask.PublicObserver()
        program = str(self.app / 'Contents/XPCServices/Helper.xpc/Contents/MacOS/Helper')
        programs = programs or [program]
        def read(arguments):
            target = arguments[-1]
            if target == 'list':
                return b'PID Status Label\n'
            if target.endswith('/' + label):
                return ('\n'.join('program = ' + p for p in programs) + '\nstate = ' + state + '\n' + extra).encode()
            present = any(target == domain + '/' + str(os.getuid()) for domain in domains)
            return ('services = {\n' + ('0 - ' + label + '\n' if present else '') + '}\n').encode()
        directory = self.home / 'Library/LaunchAgents'
        directory.mkdir(parents=True, exist_ok=True)
        return observer, label, program, directory, read

    def test_launchctl_missing_and_declared_owned_orphan(self):
        observer, label, program, directory, read = self.public_jobs()
        payload = [{'kind': 'app', 'path': str(self.app)}]
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=lambda args: b'PID Status Label\n' if args[-1] == 'list' else b'services = {\n}\n'):
            self.assertFalse(observer.launchctl([label], payload))
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=read):
            self.assertFalse(observer.launchctl([label], payload, [label]))
            with self.assertRaises(cask.Unsafe) as error:
                observer.launchctl([label], payload)
            self.assertEqual(error.exception.diagnostic['condition'], 'ownership_unproven')
        # The actual old/current adapter contract qualifies the same primitive;
        # it is not a test-only orphan override or version allowlist.
        self.row['artifacts'].append({'uninstall': [{'launchctl': label, 'quit': 'org.example.Application'}]})
        self.historical()
        self.row['version'] = '99.5'
        with patch.object(observer, 'platform', return_value=('arm64', '15.6.1')), patch.object(observer, 'conflicts'), \
                patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=read):
            value = cask.classify(self.row, self.prefix, observer)
            self.assertEqual(value['state'], 'repairable', value)
            self.assertEqual(value['execution']['historical_cleanup']['launchctl'], [label])
            self.assertTrue(value['qualification_id'])

    def test_launchctl_foreign_conflicting_plist_and_live_orphans(self):
        for program, state, extra, detail in [
                ('/foreign/Helper', 'waiting', '', 'foreign_target'),
                (str(self.app / 'Contents/XPCServices/Helper.xpc/Contents/MacOS/Helper'), 'running', 'pid = 123\n', 'live_ownership_unproven')]:
            observer, label, _, directory, read = self.public_jobs([program], state=state, extra=extra)
            with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=read):
                with self.assertRaises(cask.Unsafe) as error:
                    observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}], [label])
                self.assertEqual(error.exception.condition, cask.CONFLICT)
                self.assertEqual(error.exception.diagnostic, {'primitive': 'launchctl', 'condition': detail})
        observer, label, _, directory, read = self.public_jobs()
        (directory / 'different-filename.plist').write_bytes(plistlib.dumps({'Label': label, 'Program': '/foreign/Helper'}))
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=read):
            with self.assertRaises(cask.Unsafe) as error:
                observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}], [label])
            self.assertEqual(error.exception.diagnostic['condition'], 'foreign_target')

    def test_launchctl_ambiguous_domains_and_malformed_evidence(self):
        for programs, domains, condition in [
                (['/one', '/two'], ('user',), 'malformed_observation'),
                (None, ('gui', 'user'), 'ownership_ambiguous')]:
            observer, label, _, directory, read = self.public_jobs(programs, domains)
            with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=read):
                with self.assertRaises(cask.Unsafe) as error:
                    observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}], [label])
                self.assertEqual(error.exception.diagnostic['condition'], condition)
        observer, label, _, directory, _ = self.public_jobs()
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=PermissionError):
            with self.assertRaises(cask.Unsafe) as error:
                observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}], [label])
            self.assertEqual(error.exception.condition, cask.OBSERVATION)

    def test_duplicate_service_plist_ownership_is_ambiguous(self):
        observer, label, program, directory, read = self.public_jobs()
        for name in ('first.plist', 'second.plist'):
            (directory / name).write_bytes(plistlib.dumps({'Label': label, 'Program': program}))
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=read):
            with self.assertRaises(cask.Unsafe) as error:
                observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}], [label])
            self.assertEqual(error.exception.diagnostic['condition'], 'ownership_ambiguous')

    def test_launchctl_scopes_records_and_ignores_mach_endpoints_and_implicit_list(self):
        observer, label, _, directory, read = self.public_jobs()
        (directory / 'unrelated.plist').write_bytes(b'malformed unrelated plist')
        def inventory(arguments):
            self.assertNotEqual(arguments[-1], 'list')
            raw = read(arguments)
            if arguments[-1].startswith('gui/') and not arguments[-1].endswith('/' + label):
                return raw + ('mach endpoints = {\n0 0 ' + label + '\n}\n').encode()
            if arguments[-1].startswith('user/') and not arguments[-1].endswith('/' + label):
                return raw.replace(b'services = {\n', b'services = {\nunrelated malformed record\n')
            return raw
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=inventory):
            self.assertFalse(observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}], [label]))
        (directory / (label + '.plist')).write_bytes(b'malformed selected plist')
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=inventory):
            with self.assertRaises(cask.Unsafe):
                observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}], [label])

    def test_current_only_xpc_requires_exact_native_identity_and_path(self):
        observer, label, program, directory, read = self.public_jobs()
        payload = [{'kind': 'app', 'path': str(self.app)}]
        source = str(Path(program).parent.parent.parent)
        for identity, bundle, expected in [(label, source, True), ('org.foreign', source, False),
                                           (label, '/foreign/Helper.xpc', False)]:
            def native(arguments):
                raw = read(arguments)
                if arguments[-1].endswith('/' + label):
                    raw += ('type = XPCService\npath = ' + bundle + '\nbundle id = ' + identity + '\n').encode()
                return raw
            with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=native):
                if expected:
                    self.assertFalse(observer.launchctl([label], payload, (), [label]))
                else:
                    with self.assertRaises(cask.Unsafe):
                        observer.launchctl([label], payload, (), [label])
        with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', side_effect=read):
            with self.assertRaises(cask.Unsafe):
                observer.launchctl([label], payload, (), [label])

    def test_login_item_unrelated_duplicate_does_not_poison_selected_identity(self):
        with patch('homebrew_automation.login_items', return_value=[('Other', None), ('Other', '/foreign')]):
            cask.PublicObserver().login_items(['Example'], [{'kind': 'app', 'path': str(self.app)}], ['Example'])

    def test_diagnostic_contract_excludes_free_text_and_unknown_fields(self):
        from external_tool import diagnostic_valid
        self.assertTrue(diagnostic_valid({'primitive': 'login_item', 'condition': 'foreign_target'}))
        for value in ({'primitive': '/private/path', 'condition': 'foreign_target'},
                      {'primitive': 'login_item', 'condition': 'raw output'},
                      {'primitive': 'login_item', 'condition': 'foreign_target', 'path': '/private/path'},
                      {'primitive': ['login_item'], 'condition': 'foreign_target'}):
            self.assertFalse(diagnostic_valid(value))

    def test_malformed_launch_inventory_cannot_mean_absence(self):
        observer, label, _, directory, _ = self.public_jobs()
        for raw in (b'garbage', b'services = {', b'PID Status Label\nmalformed'):
            with patch.object(observer, 'launch_roots', return_value=(directory,)), patch.object(observer, 'read', return_value=raw):
                with self.assertRaises(cask.Unsafe) as error:
                    observer.launchctl([label], [{'kind': 'app', 'path': str(self.app)}], [label])
                self.assertEqual(error.exception.condition, 'cask_launchctl_observation_failed')
                self.assertEqual(error.exception.diagnostic['condition'], 'malformed_observation')

    def test_login_item_owned_absent_and_declared_missing_target(self):
        observer = cask.PublicObserver()
        apps = [{'kind': 'app', 'path': str(self.app)}]
        for pairs in ([], [('Example', str(self.app))], [('Example', None)]):
            with patch('homebrew_automation.login_items', return_value=pairs):
                observer.login_items(['Example'], apps, ['Example'])
        self.application()
        with patch('homebrew_automation.login_items', return_value=[('Example', str(self.app))]):
            observer.login_items(['Example'], apps)
        with patch('homebrew_automation.login_items', return_value=[('Example', None)]):
            with self.assertRaises(cask.Unsafe):
                observer.login_items(['Example'], apps, ['Example'])

    def test_login_item_foreign_duplicate_and_unproven_orphan(self):
        observer = cask.PublicObserver()
        apps = [{'kind': 'app', 'path': str(self.app)}]
        for pairs, historical, reason, condition in [
                ([('Example', '/Applications/Other.app')], ['Example'], cask.CONFLICT, 'foreign_target'),
                ([('Example', None)], [], cask.CONFLICT, 'ownership_unproven'),
                ([('Example', None), ('Example', None)], ['Example'], cask.OBSERVATION, 'identity_ambiguous')]:
            with patch('homebrew_automation.login_items', return_value=pairs):
                with self.assertRaises(cask.Unsafe) as error:
                    observer.login_items(['Example'], apps, historical)
                self.assertEqual(error.exception.condition, reason)
                self.assertEqual(error.exception.diagnostic, {'primitive': 'login_item', 'condition': condition})

    def test_login_item_metadata_evolution_and_installed_identity_binding(self):
        self.row['artifacts'].append({'uninstall': [{'login_item': 'Example', 'quit': 'org.example.Application'}]})
        self.historical()
        observer = cask.PublicObserver()
        with patch.object(observer, 'platform', return_value=('arm64', '15.6.1')), patch.object(observer, 'conflicts'), \
                patch('homebrew_automation.login_items', return_value=[('Example', None)]):
            value = cask.classify(self.row, self.prefix, observer)
            self.assertEqual(value['state'], 'repairable', value)
            self.row['artifacts'][0] = {'app': ['Other.app'], 'target': str(self.app.parent / 'Other.app')}
            self.assertEqual(cask.classify(self.row, self.prefix, observer)['reason'], cask.CONFLICT)

    def test_login_item_authorization_and_unavailability_are_not_conflicts(self):
        from homebrew_automation import AutomationUnavailable
        self.row['artifacts'].append({'uninstall': [{'login_item': 'Example'}]})
        self.historical()
        observer = cask.PublicObserver()
        for condition, authorization in [('authorization_denied', True), ('authorization_required', True),
                                         ('application_unavailable', False), ('observation_failed', False)]:
            with patch.object(observer, 'platform', return_value=('arm64', '15.6.1')), patch.object(observer, 'conflicts'), \
                    patch('homebrew_automation.login_items', side_effect=AutomationUnavailable(condition, authorization)):
                value = cask.classify(self.row, self.prefix, observer)
                self.assertEqual(value['reason'], 'cask_authorization_required' if authorization else cask.OBSERVATION)
                self.assertEqual(value['diagnostic'], {'primitive': 'login_item', 'condition': condition})
                self.assertNotEqual(value['reason'], cask.CONFLICT)

    def test_automation_never_executes_without_nonprompting_permission(self):
        from homebrew_automation import AppleEvents, AutomationUnavailable, login_items
        for code in (-1743, -1744, -600):
            with self.assertRaises(AutomationUnavailable):
                AppleEvents.check(code)
        with patch('homebrew_automation.AppleEvents') as factory:
            events = factory.return_value
            events.permission.side_effect = AutomationUnavailable('authorization_denied', True)
            with self.assertRaises(AutomationUnavailable):
                login_items()
            events.evaluate.assert_not_called()
            events.permission.side_effect = None
            events.evaluate.return_value = 'Example\tmissing\t-\nOther\tpresent\t/Applications/Other.app'
            self.assertEqual(login_items(), [('Example', None), ('Other', '/Applications/Other.app')])
            events.evaluate.return_value = 'malformed'
            with self.assertRaises(AutomationUnavailable):
                login_items()
        with patch('homebrew_automation.AppleEvents') as factory:
            events = factory.return_value
            events.evaluate.return_value = ''
            self.assertEqual(login_items(), [])
        with patch('homebrew_automation.C.CDLL') as library:
            events = AppleEvents()
            with patch.object(events, 'descriptor') as descriptor:
                from homebrew_automation import Descriptor
                descriptor.return_value = Descriptor()
                library.return_value.AEDeterminePermissionToAutomateTarget.return_value = 0
                events.permission()
                self.assertIs(library.return_value.AEDeterminePermissionToAutomateTarget.call_args.args[-1], False)

    def test_owned_dangling_link_is_repairable_foreign_link_is_conflict(self):
        destination = self.prefix / 'bin/example'
        self.row['artifacts'] = [{'binary': ['bin/example'], 'target': str(destination)}]
        self.historical()
        destination.symlink_to(self.prefix / 'Caskroom/generic-example/1.0/bin/example')
        self.assertEqual(self.classify()['state'], 'repairable')
        destination.unlink()
        destination.symlink_to(self.prefix / 'Caskroom/foreign-example/1.0/bin/example')
        value = self.classify()
        self.assertEqual(value['reason'], cask.CONFLICT)
        self.assertEqual(value['diagnostic']['primitive'], 'payload')

    def test_public_package_receipt_interface_and_existing_shared_files(self):
        observer = cask.PublicObserver()
        identifier = 'org.example.Package'
        target = self.home / 'payload'
        target.write_text('payload')
        outputs = [identifier.encode(), plistlib.dumps({'pkgid': identifier, 'volume': '/', 'install-location': str(self.home),
                                                       'pkg-version': '1.0'}), b'payload\n']
        with patch.object(observer, 'read', side_effect=outputs) as read:
            packages = observer.packages([identifier])
            self.assertEqual(packages[0]['paths'], [str(target)])
            self.assertEqual(read.call_args_list[-1].args[0], ['/usr/sbin/pkgutil', '--only-files', '--files', identifier])
        with patch.object(observer, 'read', return_value=plistlib.dumps({'pkgs': [{'pkgid': identifier}, {'pkgid': 'org.foreign.Other'}]})):
            with self.assertRaises(cask.Unsafe):
                observer.package_ownership(packages)

    def test_requirements_conflicts_integrity_and_opaque_behavior(self):
        self.row['depends_on']['macos'] = {'>=': ['99']}
        self.assertEqual(self.classify()['reason'], 'homebrew_platform_incompatible')
        self.row['depends_on']['macos'] = {}
        self.observer.conflicting = True
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)
        self.observer.conflicting = False
        for artifact in ('installer', 'preflight', 'postflight', 'stage_only', 'generated_script', 'unknown'):
            self.row['artifacts'].append({artifact: None})
            self.assertEqual(self.classify()['state'], 'unsupported')
            self.row['artifacts'].pop()
        self.row['sha256'] = 'no_check'
        self.assertEqual(self.classify()['execution']['integrity'], 'https_source_trust')
        self.row['url'] = 'http://example.org/insecure'
        self.assertEqual(self.classify()['state'], 'unsupported')

    def test_cask_dependencies_qualified_and_bound(self):
        child = copy.deepcopy(self.row)
        child['token'] = 'generic-child'
        child['artifacts'][0] = {'app': ['Child.app'], 'target': str(self.app.parent / 'Child.app')}
        self.observer.children['generic-child'] = child
        self.row['depends_on']['cask'] = ['generic-child']
        value = self.classify()
        self.assertEqual(value['state'], 'installable')
        first = value['qualification_id']
        child['sha256'] = 'b' * 64
        self.assertNotEqual(self.classify()['qualification_id'], first)
        child['artifacts'].append({'preflight': None})
        self.assertEqual(self.classify()['state'], 'unsupported')
        child['artifacts'].pop()
        child['depends_on']['cask'] = ['generic-example']
        self.observer.children['generic-example'] = self.row
        self.assertEqual(self.classify()['state'], 'unsupported')

    def test_capture_requirements_and_saved_identity_fail_closed(self):
        self.row['installed'] = '1.0'
        value = cask.capture_rows({'casks': [self.row]}, self.prefix, self.observer)
        self.assertEqual(value['casks']['generic-example']['state'], 'repairable')
        generated = self.root / 'generated'
        generated.mkdir()
        (generated / 'homebrew-casks.json').write_text(json.dumps(value))
        self.application()
        self.assertEqual(self.classify()['state'], 'satisfied')
        value['casks']['generic-example']['required'] = []
        (generated / 'homebrew-casks.json').write_text(json.dumps(value))
        self.assertEqual(self.classify()['state'], 'incompatible')
        fresh_capture = cask.capture_rows({'casks': [self.row]}, self.prefix, self.observer)
        self.assertEqual(fresh_capture['casks']['generic-example']['state'], 'satisfied')

    def test_captured_bundle_identity_rejects_foreign_replacement(self):
        self.row['installed'] = '1.0'
        self.application()
        value = cask.capture_rows({'casks': [self.row]}, self.prefix, self.observer)
        generated = self.root / 'generated'
        generated.mkdir()
        (generated / 'homebrew-casks.json').write_text(json.dumps(value))
        self.assertEqual(self.classify()['state'], 'satisfied')
        info = self.app / 'Contents/Info.plist'
        data = plistlib.loads(info.read_bytes())
        data['CFBundleIdentifier'] = 'org.foreign.Replacement'
        info.write_bytes(plistlib.dumps(data))
        self.assertEqual(self.classify()['reason'], cask.CONFLICT)

    def test_observation_errors_are_not_absence(self):
        self.package()
        with patch.object(self.observer, 'packages', side_effect=PermissionError):
            self.assertEqual(self.classify()['state'], 'observation_error')

    def test_native_privileged_lifecycle_success_and_unknown_quarantine(self):
        calls = []
        def run(executor, command, capture=False):
            calls.append(command)
            executor.unquiescent = False
            return 0, b''
        with patch.object(lifecycle.ItemExecutor, 'run', run), patch.object(lifecycle, 'requalify', return_value=True):
            self.assertEqual(lifecycle.authorized_run('reinstall', 'generic-example', 'a' * 64), 0)
        self.assertEqual(calls[0], ['/usr/bin/sudo', '-A', '-v'])
        self.assertEqual(calls[1], ['brew', 'reinstall', '--cask', 'generic-example'])
        self.assertFalse(lifecycle.pending())
        with patch.object(lifecycle.ItemExecutor, 'run', side_effect=[(0, b''), (130, b'')]), patch.object(lifecycle, 'requalify', return_value=True):
            self.assertEqual(lifecycle.authorized_run('reinstall', 'generic-example', 'a' * 64), lifecycle.UNKNOWN)
        self.assertTrue(lifecycle.pending())
        self.assertEqual(json.loads((lifecycle.state_directory() / 'active.json').read_text())['cause'], 'cancelled')
        self.assertTrue((self.item / 'external-tool-active.json').exists())
        with patch.object(lifecycle.ItemExecutor, 'run') as execute:
            self.assertEqual(lifecycle.authorized_run('install', 'generic-example', 'a' * 64), lifecycle.UNKNOWN)
            execute.assert_not_called()
        value = homebrew.probe('cask')
        self.assertEqual(value['reason'], 'privileged_lifecycle_unknown')

    def test_authorization_denial_does_not_start_mutation(self):
        with patch.object(lifecycle.ItemExecutor, 'run', return_value=(1, b'')) as execute:
            self.assertEqual(lifecycle.authorized_run('install', 'generic-example', 'a' * 64), lifecycle.DENIED)
            self.assertEqual(execute.call_count, 1)
        self.assertFalse(lifecycle.pending())

    def test_changes_during_authorization_block_native_operation(self):
        with patch.object(lifecycle.ItemExecutor, 'run', return_value=(0, b'')) as execute, \
                patch.object(lifecycle, 'requalify', return_value=False):
            self.assertEqual(lifecycle.authorized_run('install', 'generic-example', 'a' * 64), 128)
            self.assertEqual(execute.call_count, 1)
        self.assertFalse(lifecycle.pending())

    def test_private_journal_and_credentials_boundary(self):
        directory = lifecycle.state_directory()
        lifecycle.private_directory(directory)
        self.assertEqual(directory.stat().st_mode & 0o777, 0o700)
        lifecycle.journal(directory, {'state': 'unknown_consequences'})
        self.assertEqual((directory / 'active.json').stat().st_mode & 0o777, 0o600)
        helper = (ROOT / 'modules/apps/adapters/homebrew-askpass.sh').read_text()
        self.assertIn('with hidden answer', helper)
        self.assertNotIn('do shell script', helper)

    def test_privileged_descendants_are_not_reported_quiescent(self):
        tree = lifecycle.ProcessTree(123456, initialize=False)
        rows = {123456: (1, 'birth', '0:00', 'installer')}
        with patch.object(tree, 'scan', return_value=rows), patch.object(lifecycle.os, 'kill', side_effect=PermissionError), \
                patch('item_execution.time.monotonic', side_effect=[0, 2, 2, 2, 4]):
            self.assertFalse(tree.stop())

    def test_process_stop_waits_for_kill_confirmation(self):
        tree = lifecycle.ProcessTree(123456, initialize=False)
        rows = {123456: (1, 'birth', '0:00', 'installer')}
        with patch.object(tree, 'scan', side_effect=[rows, rows, {}]), \
                patch.object(lifecycle.os, 'kill') as kill, \
                patch('item_execution.time.monotonic', side_effect=[0, 2, 2, 2, 2]), \
                patch('item_execution.time.sleep'):
            self.assertTrue(tree.stop())
        self.assertTrue(all(call.args[1] == signal.SIGKILL for call in kill.call_args_list))


class RestoreCapabilityTests(unittest.TestCase):
    def fixture(self):
        spec = importlib.util.spec_from_file_location('cask_restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        fixture = module.RestorePrepareTests()
        fixture.setUp()
        self.addCleanup(fixture.doCleanups)
        metadata, prefix, _ = fixture.repair_cask_fixture()
        metadata['casks'][0]['artifacts'].append({'uninstall': [{'delete': '/Library/Preferences/org.example.absent.plist'}]})
        Path(fixture.environment['TEST_CASK_METADATA']).write_text(json.dumps(metadata))
        sudo = fixture.root / 'bin/sudo'
        sudo.write_text('#!/bin/bash\n[[ "$*" == "-A -v" ]] || exit 2\nexit 0\n')
        sudo.chmod(0o700)
        bridge = fixture.project / 'modules/apps/adapters/homebrew_lifecycle.py'
        bridge.write_text(bridge.read_text().replace('/usr/bin/sudo', str(sudo)))
        brew = fixture.root / 'bin/brew'
        brew.write_text(brew.read_text().replace('"$HOMEBREW_NO_SUDO" == 1', '"${HOMEBREW_NO_SUDO:-}" != 1'))
        return fixture, module.bundle

    def test_privileged_restore_native_mock_and_repeat_run(self):
        fixture, _ = self.fixture()
        fixture.pack()
        plan = fixture.plan_result()
        item = next(row for row in plan['plan'] if row['domain'] == 'homebrew-casks')
        self.assertTrue(item['authorization_required'])
        self.assertTrue(item['qualification_id'])
        result, events = fixture.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-2]['data']['verification']['verdict'], 'selected_requirements_verified')
        self.assertFalse((fixture.home / 'Library/Application Support/Macseed/Homebrew/active.json').exists())
        self.assertEqual(Path(fixture.environment['TEST_CASK_LOG']).read_text(), 'reinstall\n')
        fresh = fixture.plan_result()
        item = next(row for row in fresh['plan'] if row['domain'] == 'homebrew-casks')
        self.assertEqual(item['disposition'], 'satisfied')

    def test_uncertain_privileged_failure_stops_and_blocks_reentry(self):
        fixture, _ = self.fixture()
        fixture.environment['TEST_CASK_FAIL'] = 'true'
        fixture.pack()
        plan = fixture.plan_result()
        result, events = fixture.execute(plan['prepared_plan_id'])
        self.assertEqual(result.returncode, 2, events)
        final = events[-1]['data']
        self.assertEqual(final['code'], 'privileged_lifecycle_unknown')
        self.assertTrue(final['unknown_consequences'])
        self.assertEqual(final['verification']['status'], 'complete')
        self.assertFalse(final['independent_work_completed'])
        fresh = fixture.plan_result()
        self.assertFalse(fresh['readiness']['ready'])
        self.assertTrue(any(row['code'] == 'privileged_lifecycle_unknown' for row in fresh['readiness']['conditions']))

    def test_provider_diagnostic_roundtrip_and_readiness_binding(self):
        fixture, _ = self.fixture()
        metadata = json.loads(Path(fixture.environment['TEST_CASK_METADATA']).read_text())
        metadata['casks'][0]['artifacts'].append({'uninstall': [{'login_item': 'Fixture'}]})
        Path(fixture.environment['TEST_CASK_METADATA']).write_text(json.dumps(metadata))
        # Mock only the native observer in the disposable Core copy. The real
        # Shell Preview/readiness, selected identity and Protocol projection run.
        adapter = fixture.project / 'modules/apps/adapters/homebrew_automation.py'
        adapter.write_text(adapter.read_text() + "\ndef login_items():\n    raise AutomationUnavailable('authorization_denied', True)\n")
        fixture.pack()
        plan = fixture.plan_result()
        item = next(row for row in plan['plan'] if row['domain'] == 'homebrew-casks')
        expected = {'primitive': 'login_item', 'condition': 'authorization_denied'}
        self.assertEqual(item['diagnostic'], expected)
        self.assertEqual(item['reason'], 'cask_authorization_required')
        self.assertEqual(item['disposition'], 'blocked')
        self.assertFalse(plan['readiness']['ready'])
        condition = next(row for row in plan['readiness']['conditions'] if row['domain'] == 'homebrew-casks')
        self.assertEqual(condition['diagnostic'], expected)
        self.assertEqual(condition['scope'], 'operation')
        self.assertEqual(condition['status'], 'external_action_required')
        self.assertNotIn('qualification_id', item)

    def test_preview_and_readiness_collect_all_items_after_primitive_failure(self):
        fixture, _ = self.fixture()
        path = Path(fixture.environment['TEST_CASK_METADATA'])
        template = json.loads(path.read_text())['casks'][0]
        rows = []
        prefix = fixture.root / 'brew-prefix'
        for token, name, directive in [('fixture-cask', 'Fixture', {'launchctl': 'org.example.Service'}),
                                       ('login-cask', 'Login', {'login_item': 'Login'}),
                                       ('plain-cask', 'Plain', None), ('matched-cask', 'Matched', None),
                                       ('unsupported-cask', 'Unsupported', None)]:
            row = copy.deepcopy(template)
            row['token'] = token
            target = fixture.home / 'Applications' / (name + '.app')
            row['artifacts'] = [{'app': [name + '.app'], 'target': str(target)}]
            if directive:
                row['artifacts'].append({'uninstall': [directive]})
            if token == 'unsupported-cask':
                row['artifacts'].append({'installer': [{'script': {'executable': 'install.sh'}}]})
            rows.append(row)
            receipt = prefix / 'Caskroom' / token / '.metadata'
            receipt.mkdir(parents=True, exist_ok=True)
            (receipt / 'INSTALL_RECEIPT.json').write_text(json.dumps({'uninstall_flight_blocks': False,
                'source': {'tap': 'homebrew/cask', 'version': '1.0'},
                'uninstall_artifacts': [{k: v for k, v in artifact.items() if k != 'target'} for artifact in row['artifacts']]}))
            (receipt / 'config.json').write_text(json.dumps({'default': {'appdir': str(target.parent)}}))
            if token == 'matched-cask':
                (target / 'Contents/MacOS').mkdir(parents=True)
                (target / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'org.example.Matched', 'CFBundleExecutable': 'Matched'}))
                binary = target / 'Contents/MacOS/Matched'
                binary.write_text('#!/bin/sh\n'); binary.chmod(0o700)
        path.write_text(json.dumps({'casks': rows}))
        brew = fixture.root / 'bin/brew'
        contents = brew.read_text()
        line = next(line for line in contents.splitlines() if line.strip().startswith('"info --json=v2 --cask fixture-cask")'))
        contents = contents.replace(line, "  info\\ --json=v2\\ --cask\\ *) python3 -B -c 'import json,os,sys; from pathlib import Path; rows=json.loads(Path(os.environ[\"TEST_CASK_METADATA\"]).read_text())[\"casks\"]; print(json.dumps({\"casks\":[r for r in rows if r[\"token\"]==sys.argv[1]]}))' \"$4\" ;;")
        contents = contents.replace('|| echo fixture-cask ;;', '|| echo "' + '\n'.join(row['token'] for row in rows) + '" ;;')
        brew.write_text(contents)
        adapter = fixture.project / 'modules/apps/adapters/homebrew_cask.py'
        adapter.write_text(adapter.read_text() + "\ndef fixture_launchctl(self, *args):\n    raise Unsafe('cask_launchctl_observation_failed', {'primitive': 'launchctl', 'condition': 'observation_failed'})\nPublicObserver.launchctl = fixture_launchctl\n")
        # Definitions must precede the CLI main invocation.
        text = adapter.read_text()
        marker = text.index("\ndef fixture_launchctl")
        override = text[marker:]
        text = text[:marker]
        main = text.index("if __name__ == '__main__':")
        adapter.write_text(text[:main] + override + '\n' + text[main:])
        automation = fixture.project / 'modules/apps/adapters/homebrew_automation.py'
        automation.write_text(automation.read_text() + "\ndef login_items():\n    raise AutomationUnavailable('authorization_denied', True)\n")
        tokens = [row['token'] for row in rows]
        (fixture.stage / 'generated/brew-casks.conf').write_text('\n'.join(tokens) + '\n')
        blueprint = fixture.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[homebrew-casks]\nfixture-cask\n', '[homebrew-casks]\n' + '\n'.join(tokens) + '\n'))
        fixture.pack()
        plan = fixture.plan_result()
        items = [row for row in plan['plan'] if row['domain'] == 'homebrew-casks']
        self.assertEqual(len(items), len(tokens), items)
        self.assertNotIn('inspection_unavailable', [row['reason'] for row in items])
        self.assertEqual([row['disposition'] for row in items], ['blocked', 'blocked', 'planned', 'satisfied', 'blocked'], items)
        conditions = [row for row in plan['readiness']['conditions'] if row['domain'] == 'homebrew-casks']
        self.assertTrue(any(row.get('diagnostic', {}).get('primitive') == 'launchctl' for row in conditions), conditions)
        self.assertTrue(any(row.get('diagnostic', {}).get('primitive') == 'login_item' for row in conditions), conditions)
        self.assertFalse(plan['readiness']['ready'])
        self.assertFalse(Path(fixture.environment['TEST_CASK_LOG']).exists())

    def test_missing_qualification_cannot_be_replaced_by_diagnostics(self):
        fixture, _ = self.fixture()
        module = fixture.project / 'modules/apps/brew-casks.sh'
        text = module.read_text().replace("{qualification_id, authorization_required}", "{diagnostic: {primitive: \"payload\", condition: \"ownership_unproven\"}}")
        module.write_text(text)
        fixture.pack()
        result, events = fixture.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'preview_failed')
        self.assertFalse(Path(fixture.environment['TEST_CASK_LOG']).exists())

    def test_captured_capabilities_roundtrip_and_selection_validation(self):
        fixture, bundle = self.fixture()
        value = {'contract': 1, 'casks': {'fixture-cask': {'state': 'repairable', 'reason': None,
                  'required': [{'kind': 'app', 'identity': 'Fixture.app'}]}}}
        bundle.write_file(fixture.stage / 'generated/homebrew-casks.json', json.dumps(value).encode())
        fixture.pack()
        files = bundle.validate_archive(fixture.archive)
        self.assertIn('generated/homebrew-casks.json', files)
        plan = fixture.plan_result()
        self.assertTrue(plan['readiness']['ready'])
        value['casks']['fixture-cask']['required'] = []
        with self.assertRaises(bundle.Invalid):
            bundle.cask_capabilities(value)


if __name__ == '__main__':
    unittest.main()
