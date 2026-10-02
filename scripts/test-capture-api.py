#!/usr/bin/env python3
"""Disposable fixtures for the production structured Capture boundary."""
import importlib.util
import json
import os
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
bundle = fixtures.bundle
sys.path.insert(0, str(ROOT / 'modules/migration'))
from secret_input import receive


class CaptureTests(unittest.TestCase):
    def setUp(self):
        fixtures.RestorePrepareTests.setUp(self)
        self.root = self.root.resolve()
        self.project = self.project.resolve()
        self.home = self.home.resolve()
        self.environment['HOME'] = str(self.home)
        self.environment['PATH'] = str(self.root / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'


    def fixture(self, real=False):
        (self.project / 'scripts').mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'scripts/ssh-identity-migrate.sh', self.project / 'scripts/ssh-identity-migrate.sh')
        self.home.chmod(0o700)
        brew = self.root / 'bin/brew'
        brew.write_text('''#!/bin/bash
case "$*" in
 "list --formula"|"list --formula --full-name"|"list --formula --installed-on-request") [[ "${CAPTURE_FAIL:-}" != true ]] || exit 2; printf '%s\\n' "${CAPTURE_ITEM:-fixture-formula}" ;;
 "list --cask") exit 0 ;;
 --prefix) echo /opt/homebrew ;;
 *) exit 2 ;;
esac
''')
        brew.chmod(0o700)
        for tool in ('code', 'mas'):
            path = self.root / 'bin' / tool
            path.write_text('#!/bin/bash\nexit 2\n')
            path.chmod(0o700)
        if not real:
            entry = self.project / 'bootstrap.sh'
            marker = 'source modules/discovery/workspace.sh\n'
            disabled = ('discover_git', 'discover_ssh_configuration', 'discover_zsh',
                        'export_vscode_settings', 'discover_workspace', 'export_finder_settings',
                        'export_dock_settings', 'export_windows_settings', 'export_keyboard_settings',
                        'export_trackpad_settings', 'export_screenshots_settings')
            entry.write_text(entry.read_text().replace(marker, marker + '\n'.join(name + '() { return 1; }' for name in disabled) + '\n'))
        self.selection = {'categories': ['homebrew-packages'], 'items': {}, 'secure_identities': []}

    def invoke_capture(self, operation='capture_prepare', selection=None, extra=None, channel=None):
        request = {'protocol_version': 1, 'operation_id': 'capture-test', 'operation': operation,
                   'parameters': {'selection': selection}}
        request['parameters'].update(extra or {})
        command = ['bash', str(self.project / 'modules/core/application-interface/core.sh')]
        kwargs = {}
        if channel is not None:
            command += ['--secure-fd', str(channel)]
            kwargs['pass_fds'] = (channel,)
        result = subprocess.run(command, cwd=self.project, env=self.environment, input=json.dumps(request).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, **kwargs)
        return result, [json.loads(line) for line in result.stdout.splitlines()]

    def prepare(self, selection=None):
        status, events = self.invoke_capture(selection=selection)
        self.assertEqual(status.returncode, 0, events)
        self.assertEqual(sum(row['type'] in ('completed', 'failed') for row in events), 1)
        return events[-2]['data']

    def execute(self, prepared, selection=None, destination=None):
        return self.invoke_capture('capture_execute', selection or self.selection,
                                   {'expected_prepared_capture_id': prepared,
                                    'destination': str(destination or self.root / 'captured.mbt')})

    def test_inventory_absence_error_privacy_and_determinism(self):
        self.fixture()
        (self.root / 'bin/mas').unlink()
        first = self.prepare()
        second = self.prepare()
        self.assertEqual(first['prepared_capture_id'], second['prepared_capture_id'])
        rows = {row['domain']: row for row in first['inventory']}
        self.assertEqual(rows['homebrew-packages']['items'][0]['item_id'], 'fixture-formula')
        self.assertEqual(rows['app-store']['status'], 'unavailable')
        self.assertEqual(rows['vscode-extensions']['status'], 'observation_error')
        self.assertNotIn('_source', json.dumps(first))
        self.assertNotIn(str(self.home), json.dumps(first))
        self.assertFalse((self.project / 'config/generated').exists())
        self.assertFalse((self.project / 'logs').exists())
        self.assertFalse(Path(self.environment['TEST_MUTATIONS']).exists())

    def test_app_identity_and_safe_display_label(self):
        self.fixture()
        mas = self.root / 'bin/mas'
        mas.write_text('#!/bin/bash\nprintf "%s\n" "12345 Public App Name (1.0)"\n')
        prepared = self.prepare()
        row = next(row for row in prepared['inventory'] if row['domain'] == 'app-store')
        self.assertEqual(row['status'], 'present')
        self.assertEqual(row['items'], [{'item_id': '12345', 'label': 'Public App Name'}])

    def test_invalid_selection_and_unavailable_rejection(self):
        self.fixture()
        for selection in ({'categories': ['unknown'], 'items': {}, 'secure_identities': []},
                          {'categories': [], 'items': {'homebrew-packages': ['unknown']}, 'secure_identities': []},
                          {'categories': ['homebrew-packages', 'homebrew-packages'], 'items': {}, 'secure_identities': []},
                          {'categories': [], 'items': {}, 'secure_identities': ['unknown']}):
            result, events = self.invoke_capture(selection=selection)
            self.assertEqual(result.returncode, 2, events)
            self.assertIn(events[-1]['data']['code'], ('invalid_selection', 'invalid_secure_selection'))
        result, events = self.invoke_capture(selection={'categories': ['vscode-extensions'], 'items': {}, 'secure_identities': []})
        self.assertEqual(events[-1]['data']['code'], 'capture_source_unavailable')

    def test_malformed_observed_inventory_is_not_selectable(self):
        self.fixture()
        self.environment['CAPTURE_ITEM'] = 'https://user:PRIVATE_TOKEN@example.test/formula'
        prepared = self.prepare()
        row = next(row for row in prepared['inventory'] if row['domain'] == 'homebrew-packages')
        self.assertEqual(row['status'], 'observation_error')
        self.assertEqual(row['reason'], 'inventory_invalid')
        self.assertEqual(row['items'], [])
        self.assertNotIn('PRIVATE_TOKEN', json.dumps(prepared))

    def test_bundle_publication_validation_and_restore(self):
        self.fixture()
        prepared = self.prepare(self.selection)
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(result.returncode, 0, events)
        destination = self.root / 'captured.mbt'
        bundle.validate_archive(destination)
        self.assertTrue(events[-2]['data']['publication_occurred'])
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        request = {'protocol_version': 1, 'operation_id': 'restore-test', 'operation': 'restore_prepare',
                   'parameters': {'path': str(destination), 'disabled_groups': [], 'include_secure': False}}
        restored = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                  cwd=self.project, env=self.environment, input=json.dumps(request).encode(),
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(restored.returncode, 0, restored.stdout)
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(events[-1]['data']['code'], 'invalid_destination')

    def test_stale_and_failure_leave_no_bundle(self):
        self.fixture()
        prepared = self.prepare(self.selection)
        self.environment['CAPTURE_ITEM'] = 'changed-formula'
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        self.assertFalse((self.root / 'captured.mbt').exists())
        self.environment['CAPTURE_FAIL'] = 'true'
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(events[-1]['data']['code'], 'capture_source_unavailable')
        self.assertFalse(events[-1]['data']['publication_occurred'])

    def test_item_subset_blueprint_projection(self):
        self.fixture()
        self.environment['CAPTURE_ITEM'] = 'one\ntwo'
        selected = {'categories': [], 'items': {'homebrew-packages': ['two']}, 'secure_identities': []}
        prepared = self.prepare(selected)
        result, events = self.execute(prepared['prepared_capture_id'], selected)
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(self.root / 'captured.mbt')
        self.assertIn(b'two\n', files['blueprint.conf'])
        self.assertNotIn(b'one\n', files['blueprint.conf'])
        self.assertEqual(files['generated/brew-packages.conf'], b'two\n')

    def test_production_scan_private_values_not_exposed(self):
        self.fixture(real=True)
        (self.home / '.gitconfig').write_text('[user]\nname = PRIVATE_IDENTITY\n')
        path = self.root / 'bin/defaults'
        path.write_text('#!/bin/bash\necho "does not exist" >&2\nexit 1\n')
        path.chmod(0o700)
        prepared = self.prepare()
        self.assertNotIn('PRIVATE_IDENTITY', json.dumps(prepared))
        self.assertTrue(any(row['domain'] == 'git-configuration' and row['status'] == 'present' for row in prepared['inventory']))

    def test_cancellation_cleanup_and_no_terminal_input(self):
        self.fixture()
        baseline = set(Path('/private/tmp').glob('macseed-capture-*'))
        brew = self.root / 'bin/brew'
        brew.write_text('#!/bin/bash\nread -r answer && exit 2\ntouch "$CAPTURE_STARTED"\nsleep 30\n')
        self.environment['CAPTURE_STARTED'] = str(self.root / 'started')
        request = {'protocol_version': 1, 'operation_id': 'cancel-test', 'operation': 'capture_prepare', 'parameters': {'selection': None}}
        child = subprocess.Popen(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                 cwd=self.project, env=self.environment, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, start_new_session=True)
        child.stdin.write(json.dumps(request).encode()); child.stdin.close(); child.stdin = None
        deadline = time.monotonic() + 10
        while not (self.root / 'started').exists() and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertTrue((self.root / 'started').exists())
        child.send_signal(signal.SIGTERM)
        output, _ = child.communicate(timeout=10)
        events = [json.loads(line) for line in output.splitlines()]
        self.assertEqual(child.returncode, 130, events)
        self.assertEqual(sum(row['type'] in ('completed', 'failed') for row in events), 1)
        self.assertEqual(events[-1]['data']['code'], 'cancelled')
        self.assertEqual(baseline, set(Path('/private/tmp').glob('macseed-capture-*')))

    def secure_fixture(self, protected=False):
        self.fixture()
        age = shutil.which('age')
        if not age:
            self.skipTest('real age unavailable')
        (self.root / 'bin/age').unlink()
        (self.root / 'bin/age').symlink_to(age)
        ssh = self.home / '.ssh'
        ssh.mkdir(mode=0o700)
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', 'disposable-key-secret' if protected else '',
                        '-f', str(ssh / 'id_fixture')], check=True)
        prepared = self.prepare()
        self.assertEqual(prepared['secure_identities']['status'], 'present')
        self.selection['secure_identities'] = [prepared['secure_identities']['items'][0]['item_id']]
        return self.prepare(self.selection)

    def test_secure_source_stamp_stale(self):
        prepared = self.secure_fixture()
        private = self.home / '.ssh/id_fixture'
        metadata = private.stat()
        os.utime(private, ns=(metadata.st_atime_ns, metadata.st_mtime_ns + 1000000000))
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        self.assertFalse((self.root / 'captured.mbt').exists())

    def test_empty_scope_and_unsafe_destination(self):
        self.fixture()
        selection = {'categories': [], 'items': {}, 'secure_identities': []}
        prepared = self.prepare(selection)
        result, events = self.execute(prepared['prepared_capture_id'], selection)
        self.assertEqual(result.returncode, 0, events)
        bundle.validate_archive(self.root / 'captured.mbt')
        for target in (self.root / 'absent/sub.mbt', self.root / 'bad.txt'):
            result, events = self.execute(prepared['prepared_capture_id'], selection, target)
            self.assertEqual(events[-1]['data']['code'], 'invalid_destination')

    def test_secure_metadata_and_missing_channel(self):
        prepared = self.secure_fixture()
        self.assertNotIn('PRIVATE KEY', json.dumps(prepared))
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(events[-1]['data']['code'], 'secure_bridge_required')
        self.assertFalse((self.root / 'captured.mbt').exists())

    def secure_execute(self, protected=False, cancel=False):
        prepared = self.secure_fixture(protected)
        baseline = {str(p) for pattern in ('ssh-migrate-*', 'macseed-evidence-*', 'macseed-capture-*')
                    for p in Path('/private/tmp').glob(pattern)}
        parent, endpoint = socket.socketpair()
        original_socket = os.fstat(endpoint.fileno())
        self.environment['CAPTURE_SECRET_SOCKET'] = str(original_socket.st_dev) + ':' + str(original_socket.st_ino)
        age_path = self.root / 'bin/age'
        real_age = str(age_path.resolve())
        age_path.unlink()
        age_path.write_text("#!/usr/bin/python3\nimport os, sys\n" +
            "for fd in range(3, 256):\n" +
            " try:\n  info = os.fstat(fd)\n except OSError:\n  continue\n" +
            " if str(info.st_dev) + ':' + str(info.st_ino) == os.environ['CAPTURE_SECRET_SOCKET']:\n  sys.exit(98)\n" +
            "if any('disposable-bundle-secret' in value or 'disposable-key-secret' in value for value in sys.argv + list(os.environ.values())):\n sys.exit(99)\n" +
            "os.execv(" + repr(real_age) + ", [" + repr(real_age) + "] + sys.argv[1:])\n")
        age_path.chmod(0o700)
        command = ['bash', str(self.project / 'modules/core/application-interface/core.sh'), '--secure-fd', str(endpoint.fileno())]
        request = {'protocol_version': 1, 'operation_id': 'capture-secure', 'operation': 'capture_execute',
                   'parameters': {'selection': self.selection, 'destination': str(self.root / 'captured.mbt'),
                                  'expected_prepared_capture_id': prepared['prepared_capture_id']}}
        child = subprocess.Popen(command, cwd=self.project, env=self.environment, pass_fds=(endpoint.fileno(),),
                                 stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        endpoint.close()
        child.stdin.write(json.dumps(request).encode()); child.stdin.close(); child.stdin = None
        kinds = []
        deadline = time.monotonic() + 25
        try:
            while child.poll() is None and time.monotonic() < deadline:
                if not select.select([parent], [], [], .1)[0]:
                    continue
                if not parent.recv(1, socket.MSG_PEEK):
                    break
                challenge = json.loads(receive(parent, deadline))
                kinds.append(challenge['kind'])
                action = b'C' if cancel else b'S'
                secret = b'' if cancel else (b'disposable-key-secret' if challenge['kind'] == 'ssh_key_unlock' else b'disposable-bundle-secret')
                body = bytes.fromhex(challenge['challenge_id']) + action + secret
                parent.sendall(struct.pack('!I', len(body)) + body)
            output, errors = child.communicate(timeout=10)
        finally:
            parent.close()
            if child.poll() is None:
                child.kill(); child.wait()
        self.assertEqual(baseline, {str(p) for pattern in ('ssh-migrate-*', 'macseed-evidence-*', 'macseed-capture-*')
                                    for p in Path('/private/tmp').glob(pattern)})
        events = [json.loads(line) for line in output.splitlines()]
        self.assertNotIn(b'disposable-bundle-secret', output + errors)
        self.assertNotIn(b'disposable-key-secret', output + errors)
        self.assertNotIn(b'PRIVATE KEY', output + errors)
        self.assertEqual(sum(row['type'] in ('completed', 'failed') for row in events), 1)
        if cancel:
            self.assertEqual(child.returncode, 130, events)
            self.assertFalse((self.root / 'captured.mbt').exists())
        else:
            self.assertEqual(child.returncode, 0, events)
            files = bundle.validate_archive(self.root / 'captured.mbt')
            self.assertIn('secure.age', files)
            self.assertIn('bundle_encrypt', kinds)
            if protected:
                self.assertIn('ssh_key_unlock', kinds)

    def test_secure_capture_and_protected_unlock(self):
        self.secure_execute(protected=True)

    def test_secure_capture_without_key_unlock(self):
        self.secure_execute()

    def test_secure_cancel_does_not_publish(self):
        self.secure_execute(cancel=True)


if __name__ == '__main__':
    unittest.main()
