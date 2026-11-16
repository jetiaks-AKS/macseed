#!/usr/bin/env python3
"""Disposable fixtures for the production structured Capture boundary."""
import importlib.util
import base64
import hashlib
import json
import os
import plistlib
from pathlib import Path
import select
import shutil
import signal
import socket
import struct
import subprocess
import sys
import time
import tarfile
import unittest
import tempfile
from unittest.mock import patch

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
fixtures = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixtures)
bundle = fixtures.bundle
sys.path.insert(0, str(ROOT / 'modules/migration'))
from secret_input import receive
spec = importlib.util.spec_from_file_location('parser_test_contract', ROOT / 'scripts/test-shell-parser.py')
parser_tests = importlib.util.module_from_spec(spec); spec.loader.exec_module(parser_tests)


class CaptureTests(unittest.TestCase):
    def functions_fixture(self, *, non_enforcing=False):
        self.fixture(shell=True)
        spec = importlib.util.spec_from_file_location('parser_build', ROOT / 'scripts/build-shell-parser.py')
        builder = importlib.util.module_from_spec(spec); spec.loader.exec_module(builder)
        package = self.root / 'parser'
        with patch.dict(os.environ, TMPDIR=str(self.private_temp)), patch.object(tempfile, 'tempdir', str(self.private_temp)):
            metadata = builder.build(package, [os.uname().machine])
        self.environment.pop('MACSEED_DESKTOP_BUNDLE', None)
        resources = self.project / 'desktop/Macseed/build/Debug/Macseed.app/Contents/Resources'
        resources.mkdir(parents=True)
        builder.install_package(package, resources)
        (resources / 'CoreRuntime.plist').write_bytes(plistlib.dumps(dict(Version=1, Mode='development',
            CoreRoot=str(self.project), PythonExecutable=sys.executable, ShellParserManifestSHA256=metadata['manifest_sha256'])))
        original = ('# é\nordinary() {\r\n print "é"\r\n}\n'
            'function complex {\n  for x in a b; do\n    if [[ -n $x ]]; then\n'
            '      cat <<\'EOF\'\nprivate literal $HOME\nEOF\n'
            '    fi\n  done\n  inner() { :; }\n  touch "$HOME/executed"\n}\n').encode()
        (self.home / '.zshenv').write_bytes(b"alias legacy='pwd'\n")
        source = self.home / '.zshrc'
        source.write_bytes(original); source.chmod(0o600)
        state = bundle.shell_state_contract()
        chosen = dict(categories=[], items={'shell-zsh': [state.identity('function', 'complex')]}, secure_identities=[])
        if non_enforcing:
            # Model ignored OS constraints only in this disposable Core copy.
            # The production preflight/transport and child Core process still run.
            caller = self.project / 'modules/shell/parser_client.py'
            with caller.open('a') as stream:
                stream.write('''
_fixture_launch = _Task._launch
def _fixture_ignored_constraint(task):
    task.api.send(task.task, 'setLaunchRequirementData:', None, (C.c_void_p,),
                  (task.api.send(task.api.cls('NSData'), 'data'),))
    _fixture_launch(task)
_Task._launch = _fixture_ignored_constraint
''')
        spec = importlib.util.spec_from_file_location('functions_capture_fixture', self.project / 'modules/shell/capture.py')
        self.functions_adapter = importlib.util.module_from_spec(spec); spec.loader.exec_module(self.functions_adapter)
        requirement = base64.b64decode(metadata['binaries']['macseed-shell-parser']['launch']['requirement_data'])
        self.functions_enforced = parser_tests.launch_enforced(self, self.functions_adapter.client, requirement)
        return source, original, resources, chosen

    def assert_functions_unavailable(self, chosen, *, legacy_capture=False):
        self.assertFalse(self.functions_enforced)
        adapter = self.functions_adapter
        with patch.dict(os.environ, self.environment, clear=True), \
                patch.object(adapter.observe.base, 'home_directory') as home_read, \
                patch.object(adapter.observe.sources, 'file_state') as source_read, \
                patch.object(adapter.client.Parser, '_run', wraps=adapter.client.Parser._run) as transport:
            observed = adapter.Observation(self.project)
            self.assertIsNone(observed.snapshot); self.assertIsNone(observed.binding)
            self.assertEqual(observed.entries(), [])
            self.assertEqual(observed.public['codes'], ['functions_unavailable'])
            home_read.assert_not_called(); source_read.assert_not_called()
            self.assertEqual([(c.args[0], c.args[2]) for c in transport.call_args_list], [('/usr/bin/true', b'')] * 2)
        original = (self.home / '.zshrc').read_bytes()
        scan = self.prepare()
        self.assertEqual(scan['shell_functions']['status'], 'unavailable')
        self.assertEqual(scan['shell_functions']['codes'], ['functions_unavailable'])
        row = next(r for r in scan['inventory'] if r['domain'] == 'shell-zsh')
        self.assertFalse(any(r['item_id'].startswith('shell-function:') for r in row['items']))
        for result, events in (self.invoke_capture(selection=chosen), self.execute('0' * 64, chosen)):
            self.assertEqual(result.returncode, 2, events)
            self.assertEqual(events[-1]['data']['code'], 'capture_functions_unavailable')
            self.assertNotIn(b'private literal', result.stdout + result.stderr)
            self.assertNotIn(b'.zshrc', result.stdout + result.stderr)
        self.assertFalse((self.root / 'captured.mbt').exists())
        self.assertFalse((self.root / 'mutations').exists())
        self.assertFalse((self.home / 'executed').exists())
        self.assertEqual((self.home / '.zshrc').read_bytes(), original)
        if legacy_capture:
            legacy = dict(categories=['shell-zsh'], items={}, secure_identities=[])
            saved = self.prepare(legacy)
            target = self.root / 'legacy.mbt'
            result, events = self.execute(saved['prepared_capture_id'], legacy, target)
            self.assertEqual(result.returncode, 0, events)
            files = bundle.validate_archive(target)
            self.assertNotIn(bundle.shell_state_contract().DEFINITIONS, files)
            self.assertEqual([a['name'] for a in bundle.shell_aliases(files[bundle.shell_state_contract().SNAPSHOT])['aliases']], ['legacy'])

    def test_functions_production_capture_bundle_exact_bytes_and_runtime_rejection(self):
        source, original, package, chosen = self.functions_fixture()
        if not self.functions_enforced:
            self.assert_functions_unavailable(chosen, legacy_capture=True)
            return  # Fail-closed coverage, not active Capture -> Bundle qualification.
        (self.home / '.zshenv').unlink()  # Functions do not depend on a legacy alias being present.
        original = original.replace(b'function complex {\n', 'function complex {\n  local greeting="é"\r\n'.encode())
        source.write_bytes(original)
        leaf = self.home / 'private-functions'
        source.replace(leaf)
        source.write_bytes(b'source "$HOME/private-functions"\n')
        source = leaf
        before = source.stat()
        scan = self.prepare()
        row = next(r for r in scan['inventory'] if r['domain'] == 'shell-zsh')
        self.assertEqual({r['label'] for r in row['items']}, {'complex', 'ordinary'})
        self.assertEqual(scan['shell_functions']['status'], 'observed')
        prepared = self.prepare(chosen)
        self.assertEqual(prepared['summary']['selected_items'], 1)
        result, events = self.execute(prepared['prepared_capture_id'], chosen)
        self.assertEqual(result.returncode, 0, events)
        target = self.root / 'captured.mbt'
        files = bundle.validate_archive(target)
        state = bundle.shell_state_contract()
        snapshot = bundle.typed_shell(files)
        value = snapshot._value
        self.assertEqual([r['key'] for r in value['items']], ['complex'])
        definition = value['items'][0]
        self.assertEqual(files[state.DEFINITIONS], original[slice(*definition['details']['span'])])
        self.assertTrue(all(r['condition'] == 'unknown' for r in value['loads']))
        self.assertEqual({r['path'] for r in value['sources']}, {'.zshrc', 'private-functions'})
        self.assertEqual(sum(r['parent'] is not None for r in value['loads']), 2)
        self.assertEqual(value['dependencies'], [])
        self.assertEqual(state.encode(state.select(snapshot, chosen['items']['shell-zsh'])), state.encode(snapshot))
        with tarfile.open(target) as archive:
            self.assertEqual(json.load(archive.extractfile('manifest.json'))['required_features'], state.FEATURE)
        reference = self.root / 'reference'
        for name, raw in files.items():
            bundle.write_file(reference / name, raw)
        for operation, parameters in [
            ('bundle_inspect', dict(path=str(target))),
            ('restore_prepare', dict(path=str(target), disabled_groups=[], include_secure=False)),
            ('restore_execute', dict(path=str(target), disabled_groups=[], include_secure=False,
                                     expected_prepared_plan_id='0' * 64)),
            ('environment_compare', dict(bundle_path=str(target))),
            ('environment_compare', dict(generated_dir=str(reference / 'generated'), blueprint_path=str(reference / 'blueprint.conf')))]:
            request = dict(protocol_version=1, operation_id='typed-runtime', operation=operation, parameters=parameters)
            run = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                cwd=self.project, env=self.environment, input=json.dumps(request).encode(), capture_output=True, timeout=30)
            records = [json.loads(line) for line in run.stdout.splitlines()]
            if operation == 'bundle_inspect':
                self.assertEqual(run.returncode, 0, records)
                inspected = records[-2]['data']
                self.assertFalse(inspected['restore_supported'])
                self.assertNotIn('restore_selection', inspected)
                self.assertEqual(inspected['required_features'], state.FEATURE)
            else:
                self.assertEqual(run.returncode, 2, records)
                self.assertEqual(records[-1]['data']['code'], 'unsupported_bundle')
            self.assertNotIn(b'private literal', run.stdout + run.stderr)
            self.assertNotIn(b'.zshrc', run.stdout + run.stderr)
            self.assertNotIn(b'private-functions', run.stdout + run.stderr)
        self.assertFalse((self.root / 'mutations').exists())
        self.assertFalse((self.home / 'executed').exists())
        self.assertEqual(source.read_bytes(), original)
        self.assertEqual(source.stat().st_mtime_ns, before.st_mtime_ns)
        self.assertNotIn(b'private literal', result.stdout + result.stderr)
        # Existing category selection explicitly retains aliases only, even with
        # qualified Functions available. It cannot silently opt into shell-state.
        (self.home / '.zshenv').write_bytes(b"alias legacy='pwd'\n")
        legacy = dict(categories=['shell-zsh'], items={}, secure_identities=[])
        saved = self.prepare(legacy)
        legacy_target = self.root / 'legacy.mbt'
        run, records = self.execute(saved['prepared_capture_id'], legacy, legacy_target)
        self.assertEqual(run.returncode, 0, records)
        old = bundle.validate_archive(legacy_target)
        self.assertNotIn(state.DEFINITIONS, old)
        self.assertEqual([a['name'] for a in bundle.shell_aliases(old[state.SNAPSHOT])['aliases']], ['legacy'])

    def test_functions_freshness_mixed_selection_and_fail_closed_parser(self):
        source, original, package, chosen = self.functions_fixture()
        if not self.functions_enforced:
            self.assert_functions_unavailable(chosen)
            return
        mixed = dict(chosen, items={'shell-zsh': [*chosen['items']['shell-zsh'], bundle.shell_contract().identity('legacy')]})
        for selection, extra in [(mixed, {}), (chosen, dict(shell_script_selection=['0' * 64], shell_script_policy='opaque-file-v5'))]:
            result, events = self.invoke_capture(selection=selection, extra=extra)
            self.assertEqual(result.returncode, 2, events)
            self.assertEqual(events[-1]['data']['code'], 'mixed_shell_selection_unsupported')
        saved = self.prepare(chosen)
        for raw in (original + b'# changed\n', original + b'if true; then source "$HOME/private"; fi\n',
                    original + b'complex() { :; }\n'):
            source.write_bytes(raw)
            result, events = self.execute(saved['prepared_capture_id'], chosen)
            self.assertEqual(result.returncode, 2, events)
            self.assertIn(events[-1]['data']['code'], ('stale_prepared_capture', 'capture_functions_unavailable'))
            self.assertFalse((self.root / 'captured.mbt').exists())
        source.write_bytes(original)
        saved = self.prepare(chosen)
        (package / 'ThirdPartyNotices/shell-parser-build.json').write_bytes(b'{"private":"malformed"}')
        result, events = self.execute(saved['prepared_capture_id'], chosen)
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'capture_functions_unavailable')
        self.assertFalse((self.root / 'captured.mbt').exists())
        self.assertNotIn(b'malformed', result.stdout + result.stderr)
        # Helper failure never changes the independent aliases path.
        self.prepare(dict(categories=['shell-zsh'], items={}, secure_identities=[]))

    def test_functions_source_change_during_execute_prevents_publication(self):
        source, original, package, chosen = self.functions_fixture()
        if not self.functions_enforced:
            self.assert_functions_unavailable(chosen)
            return
        saved = self.prepare(chosen)
        entry = self.project / 'bootstrap.sh'
        text = entry.read_text()
        entry.write_text(text.replace('#!/bin/bash\n', '#!/bin/bash\n'
            'if [[ "$1" == --dry-run ]]; then printf "# changed\\n" >> "$HOME/.zshrc"; fi\n', 1))
        result, events = self.execute(saved['prepared_capture_id'], chosen)
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        self.assertFalse((self.root / 'captured.mbt').exists())
        self.assertEqual(source.read_bytes(), original + b'# changed\n')

    def test_functions_runtime_descriptor_trust_and_private_failures(self):
        source, original, resources, chosen = self.functions_fixture()
        adapter = self.functions_adapter
        descriptor = resources / 'CoreRuntime.plist'
        raw = descriptor.read_bytes()
        value = plistlib.loads(raw)
        with patch.dict(os.environ, self.environment, clear=True):
            valid = adapter.Observation(self.project)
            if self.functions_enforced:
                self.assertIsNotNone(valid.snapshot)
            else:
                self.assertIsNone(valid.snapshot)
                self.assertEqual(valid.entries(), [])
                self.assertEqual(valid.public['codes'], ['functions_unavailable'])
            # Same existing Desktop launch context, never a parser-specific PATH
            # or environment override; the descriptor must belong to this Core.
            with patch.dict(os.environ, MACSEED_DESKTOP_BUNDLE=str(resources.parent.parent)):
                self.assertEqual(adapter.Observation(self.project).binding, valid.binding)
            run = adapter.client.Parser._run
            def not_enforcing(executable, requirement, source, cancelled, **options):
                self.assertEqual(executable, '/usr/bin/true')
                self.assertEqual(source, b'')
                return run(executable, b'', source, cancelled, **options)
            with patch.object(adapter.client.Parser, '_run', staticmethod(not_enforcing)), \
                    patch.object(adapter.observe.base, 'home_directory') as read:
                unavailable = adapter.Observation(self.project)
                self.assertIsNone(unavailable.snapshot)
                self.assertIsNone(unavailable.binding)
                self.assertEqual(unavailable.entries(), [])
                self.assertEqual(unavailable.public['status'], 'unavailable')
                self.assertEqual(unavailable.public['codes'], ['functions_unavailable'])
                self.assertNotIn(str(self.home), json.dumps(unavailable.public))
            read.assert_not_called()
            for bad in (dict(value, ShellParserManifestSHA256='0' * 64), dict(value, CoreRoot='/private/unrelated'),
                        {k: v for k, v in value.items() if k != 'ShellParserManifestSHA256'},
                        b'<?xml version="1.0"?><plist><dict><key>private-secret</key></plist>'):
                descriptor.write_bytes(bad if type(bad) is bytes else plistlib.dumps(bad))
                rejected = adapter.Observation(self.project)
                self.assertIsNone(rejected.snapshot)
                self.assertEqual(rejected.entries(), [])
                self.assertIn('helper_untrusted', rejected.public['codes'])
                self.assertNotIn('private-secret', json.dumps(rejected.public))
            descriptor.unlink()
            self.assertIsNone(adapter.Observation(self.project).snapshot)
            descriptor.write_bytes(raw)
            self.assertEqual(adapter.Observation(self.project).binding, valid.binding)
            (self.home / '.zprofile').write_bytes(b'# appeared after observation\n')
            changed = adapter.Observation(self.project)
            if self.functions_enforced:
                self.assertNotEqual(changed.binding, valid.binding)
            else:
                self.assertIsNone(changed.binding)
                self.assertEqual(changed.public['codes'], ['functions_unavailable'])
        self.assertEqual(source.read_bytes(), original)
        self.assertFalse((self.home / 'executed').exists())

    def test_functions_non_enforcing_capture_refusal_preserves_legacy(self):
        _, _, _, chosen = self.functions_fixture(non_enforcing=True)
        self.assert_functions_unavailable(chosen, legacy_capture=True)

    def test_shell_capture_counts_distinguish_aliases_and_saved_files(self):
        self.fixture(shell=True)
        directory = self.home / 'Scripts'; directory.mkdir(mode=0o700)
        paths = [directory / name for name in ('linked', 'independent-one', 'independent-two')]
        for path in paths:
            path.write_bytes(b'#!/bin/sh\necho fixture\n'); path.chmod(0o700)
        (self.home / '.zshrc').write_text("alias linked='$HOME/Scripts/linked'\n" + ''.join(
            f"alias independent_{index}='pwd'\n" for index in range(11)))
        contract = bundle.shell_contract(); recovery = contract.recovery_contract()
        linked = recovery.script_id('Scripts/linked')
        all_scripts = {recovery.script_id('Scripts/' + path.name) for path in paths}
        policy = dict(shell_script_policy='opaque-file-v5', shell_script_paths=list(map(str, paths)))
        result, events = self.invoke_capture('capture_script_inspect', extra=dict(policy, scripts={}))
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual({row['id'] for row in events[-2]['data']['shell_script_candidates']}, all_scripts)
        for label, aliases, scripts in [('aliases', True, set()), ('scripts', False, all_scripts),
                                        ('linked', True, {linked}), ('three', True, all_scripts),
                                        ('duplicate', True, {linked}), ('neither', False, set())]:
            with self.subTest(selection=label):
                categories = ['homebrew-packages'] + (['shell-zsh'] if aliases else [])
                chosen = dict(categories=categories, items={}, secure_identities=[])
                selected = dict(policy, shell_script_selection=sorted(scripts), shell_script_paths=[
                    str(path) for path in paths if recovery.script_id('Scripts/' + path.name) in scripts])
                if not scripts: selected.pop('shell_script_paths')
                if label == 'duplicate': selected['shell_script_paths'] += [str(directory) + '/./linked']
                result, events = self.invoke_capture(selection=chosen, extra=selected)
                self.assertEqual(result.returncode, 0, (label, events))
                prepared = events[-2]['data']
                self.assertEqual(prepared['summary'], dict(selected_domains=1 + int(aliases) + bool(scripts),
                    selected_items=1 + (12 if aliases else 0) + len(scripts), secure_identity_count=0))
                destination = self.root / (label + '.mbt')
                result, events = self.invoke_capture('capture_execute', chosen, dict(selected,
                    shell_script_ids=sorted(scripts), destination=str(destination),
                    expected_prepared_capture_id=prepared['prepared_capture_id']))
                self.assertEqual(result.returncode, 0, events)
                saved = bundle.validate_archive(destination)
                shell = bundle.shell_aliases(saved['generated/shell/zshrc.snapshot'], saved) if 'generated/shell/zshrc.snapshot' in saved else None
                alias_ids = {contract.identity(row['name']) for row in shell['aliases']} if shell else set()
                file_ids = {recovery.file_identity(row['path']) for row in shell['scripts']} if shell else set()
                self.assertTrue(alias_ids.isdisjoint(file_ids))
                self.assertEqual(len(alias_ids), 12 if aliases else 0)
                self.assertEqual(file_ids, {'shell-script:' + key for key in scripts})
                self.assertEqual(prepared['summary']['selected_items'], 1 + len(alias_ids | file_ids))
                publication = events[-2]['data']['bundle']
                self.assertEqual({row['id'] for row in publication.get('shell_script_candidates', [])}, scripts)
                # The publication still exposes the same physical Restore counts;
                # Capture's functional projection also uses the saved file identities.
                expected_physical = (12 if aliases else 0) + len(scripts - ({linked} if aliases else set()))
                self.assertEqual(publication['selected_item_counts'].get('shell-zsh', 0), expected_physical)
                self.assertEqual(publication, bundle.inspect_bundle(destination, str(self.home)))

    def test_v5_request_manifest_maximum_selection_and_fail_closed(self):
        self.fixture(shell=True)
        directory = self.home / 'Scripts'; directory.mkdir(mode=0o700)
        paths = []
        for index in range(128):
            path = directory / f'file-{index:03}.sh'
            path.write_bytes(b'echo fixture\n'); path.chmod(0o600); paths.append(str(path))
        private = self.root / 'scripts-request'; private.mkdir(mode=0o700)
        control = private / 'shell-scripts-request.json'
        self.environment['TMPDIR'] = str(private)
        request = dict(protocol_version=1, operation_id='scripts-maximum', operation='capture_script_inspect',
                       parameters=dict(shell_script_policy='opaque-file-v5'))
        fields = dict(scripts={}, shell_script_paths=paths)
        def invoke(body, mode=0o600):
            control.write_bytes(body); control.chmod(mode)
            request['parameters']['script_manifest'] = hashlib.sha256(body).hexdigest()
            result = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                cwd=self.project, env=self.environment, input=json.dumps(request).encode(), capture_output=True, timeout=30)
            return result, [json.loads(line) for line in result.stdout.splitlines()]
        raw = json.dumps(dict(version=5, operation_id=request['operation_id'], parameters=fields)).encode()
        self.assertGreater(len(raw), 4096)
        result, events = invoke(raw)
        self.assertEqual(result.returncode, 0, events)
        data = events[-2]['data']
        self.assertEqual(len(data['shell_script_candidates']), 128)
        self.assertTrue(all(row['status'] == 'qualified' for row in data['scripts']))
        # Bound actual maximum request metadata, with UTF-8 JSON escaping included.
        maximum = dict(shell_script_paths=['/' + 'a' * 1019 + str(i).zfill(4) for i in range(128)],
            shell_script_ids=[row['id'] for row in data['scripts']], shell_script_selection=[row['id'] for row in data['scripts']],
            scripts={row['id']: row['observation_id'] for row in data['scripts']}, shell_items=['shell-alias:' + str(i).zfill(64) for i in range(384)])
        self.assertLess(len(json.dumps(dict(version=5, operation_id='x'*64, parameters=maximum)).encode()), 262144)
        bad = [raw + b' ' * 262144,
               json.dumps(dict(version=5, operation_id='another-operation', parameters=fields)).encode(),
               json.dumps(dict(version=5, operation_id=request['operation_id'], parameters=dict(fields, shell_script_paths=paths + [paths[0]]))).encode(),
               json.dumps(dict(version=5, operation_id=request['operation_id'], parameters=dict(fields, destination='/tmp/unrelated'))).encode()]
        for body in bad:
            result, events = invoke(body)
            self.assertEqual(result.returncode, 2, events)
            self.assertEqual(events[-1]['data']['code'], 'invalid_request')
        result, events = invoke(raw, 0o644)
        self.assertEqual(result.returncode, 2, events)
        control.unlink(); control.symlink_to(directory / 'file-000.sh')
        result = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
            cwd=self.project, env=self.environment, input=json.dumps(request).encode(), capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 2)

    def setUp(self):
        fixtures.RestorePrepareTests.setUp(self)
        self.root = self.root.resolve()
        self.project = self.project.resolve()
        self.home = self.home.resolve()
        self.environment['HOME'] = str(self.home)
        self.environment['PATH'] = str(self.root / 'bin') + ':/usr/bin:/bin:/usr/sbin:/sbin'
        (self.root / 'bin/sw_vers').write_text('#!/bin/bash\necho 26.7.1\n')


    def fixture(self, real=False, workspace=False, ssh=False, shell=False):
        (self.project / 'scripts').mkdir(exist_ok=True)
        shutil.copy2(ROOT / 'scripts/ssh-identity-migrate.sh', self.project / 'scripts/ssh-identity-migrate.sh')
        self.home.chmod(0o700)
        brew = self.root / 'bin/brew'
        brew.write_text('''#!/bin/bash
case "$*" in
 "list --formula"|"list --formula --full-name"|"list --formula --installed-on-request") [[ "${CAPTURE_FAIL:-}" != true ]] || exit 2; printf '%s\\n' "${CAPTURE_ITEM:-fixture-formula}" ;;
 --version) echo 'Homebrew 7.0.7' ;;
 help\\ *) echo "$2 --formula --cask --full-name --json --appdir" ;;
 "info --json=v2 --installed --cask") echo '{"casks":[]}' ;;
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
            entry.write_text(entry.read_text().replace(marker, marker + '\n'.join(
                name + '() { return 1; }' for name in disabled
                if not (workspace and name == 'discover_workspace')
                and not (ssh and name == 'discover_ssh_configuration')
                and not (shell and name == 'discover_zsh')) + '\n'))
        self.selection = {'categories': ['homebrew-packages'], 'items': {}, 'secure_identities': []}

    def invoke_capture(self, operation='capture_prepare', selection=None, extra=None, channel=None, timeout=30):
        request = {'protocol_version': 1, 'operation_id': 'capture-test', 'operation': operation,
                   'parameters': {'selection': selection}}
        request['parameters'].update(extra or {})
        if operation == 'capture_script_inspect': request['parameters'].pop('selection')
        command = ['bash', str(self.project / 'modules/core/application-interface/core.sh')]
        kwargs = {}
        if channel is not None:
            command += ['--secure-fd', str(channel)]
            kwargs['pass_fds'] = (channel,)
        result = subprocess.run(command, cwd=self.project, env=self.environment, input=json.dumps(request).encode(),
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=timeout, **kwargs)
        return result, [json.loads(line) for line in result.stdout.splitlines()]

    def prepare(self, selection=None):
        status, events = self.invoke_capture(selection=selection)
        self.assertEqual(status.returncode, 0, events)
        self.assertEqual(sum(row['type'] in ('completed', 'failed') for row in events), 1)
        return events[-2]['data']

    def execute(self, prepared, selection=None, destination=None, timeout=30):
        return self.invoke_capture('capture_execute', selection or self.selection,
                                   {'expected_prepared_capture_id': prepared,
                                    'destination': str(destination or self.root / 'captured.mbt')}, timeout=timeout)

    def ssh_fixture(self, suffix=b''):
        self.fixture(ssh=True)
        directory = self.home / '.ssh'
        directory.mkdir(mode=0o700)
        target = directory / 'config'
        target.write_bytes(b'Host github\n HostName github.invalid\n User git\n Port 22\n'
                           b'Host production\n HostName production.invalid\n User deploy\n' + suffix)
        target.chmod(0o600)
        return target

    def test_legacy_shell_category_capture_with_script_policy(self):
        self.fixture(shell=True)
        target = self.home / '.zshrc'
        original = b'export EDITOR=vi\n'
        target.write_bytes(original); target.chmod(0o600)
        before = target.stat()
        chosen = dict(categories=['shell-zsh'], items={}, secure_identities=[])
        for policy in ({}, dict(shell_script_policy='opaque-file-v5')):
            with self.subTest(policy=policy):
                status, events = self.invoke_capture(selection=chosen, extra=policy)
                self.assertEqual(status.returncode, 0, events)
                prepared = events[-2]['data']
                row = next(row for row in prepared['inventory'] if row['domain'] == 'shell-zsh')
                self.assertEqual((row['status'], row['selection_mode'], row['items']), ('present', 'category', []))
                self.assertEqual(prepared['summary'], dict(selected_domains=1, selected_items=0, secure_identity_count=0))
                self.assertNotIn('shell_scripts', prepared)
                destination = self.root / ('legacy-policy.mbt' if policy else 'legacy.mbt')
                status, events = self.invoke_capture('capture_execute', chosen, dict(policy,
                    destination=str(destination), expected_prepared_capture_id=prepared['prepared_capture_id']))
                self.assertEqual(status.returncode, 0, events)
                saved = bundle.validate_archive(destination)
                self.assertTrue(saved['generated/shell/zshrc.snapshot'].startswith(b'MBT-ZSHRC-1\nstatus=eligible\n'))
                self.assertIsNone(bundle.shell_aliases(saved['generated/shell/zshrc.snapshot']))
                self.assertFalse(any(bundle.script_member(name) for name in saved))
                publication = events[-2]['data']['bundle']
                self.assertEqual(publication['selected_categories'], ['shell-zsh'])
                self.assertNotIn('shell-zsh', publication['selected_item_counts'])
                self.assertEqual(sum(publication['selected_item_counts'].values()), 0)
                self.assertEqual(publication, bundle.inspect_bundle(destination, str(self.home)))
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual((target.stat().st_ino, target.stat().st_mode, target.stat().st_mtime_ns),
                         (before.st_ino, before.st_mode, before.st_mtime_ns))
        policy = dict(shell_script_policy='opaque-file-v5')
        status, events = self.invoke_capture(selection=chosen,
            extra=dict(policy, shell_script_selection=['0' * 64]))
        self.assertNotEqual(status.returncode, 0)
        self.assertEqual(events[-1]['data']['code'], 'invalid_script_consent')
        status, events = self.invoke_capture(selection=chosen, extra=policy)
        self.assertEqual(status.returncode, 0, events)
        prepared = events[-2]['data']
        target.write_bytes(b'export EDITOR=nano\n')
        destination = self.root / 'stale-legacy.mbt'
        status, events = self.invoke_capture('capture_execute', chosen, dict(policy,
            destination=str(destination), expected_prepared_capture_id=prepared['prepared_capture_id']))
        self.assertNotEqual(status.returncode, 0)
        self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        self.assertFalse(destination.exists())

    def test_shell_alias_capture_selection_bundle_and_readonly_check(self):
        self.fixture(shell=True)
        target = self.home / '.zshrc'
        original = b"source optional.zsh\nalias zebra='ls -la'\nalias alpha='git status'\nexport API_TOKEN=private_fixture\n"
        target.write_bytes(original)
        os.chflags(target, 0x00000040)  # macOS document tracking must not exclude read-only Capture.
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'shell-zsh')
        self.assertEqual((row['status'], row['selection_mode'], row['reason']), ('present', 'items', 'source_partial'))
        self.assertEqual([entry['label'] for entry in row['items']], ['zebra', 'alpha'])
        chosen = dict(categories=[], items={'shell-zsh': [row['items'][1]['item_id']]}, secure_identities=[])
        prepared = self.prepare(chosen)
        self.assertEqual(prepared['summary'], dict(selected_domains=1, selected_items=1, secure_identity_count=0))
        result, events = self.execute(prepared['prepared_capture_id'], chosen)
        self.assertEqual(result.returncode, 0, events)
        archive = self.root / 'captured.mbt'
        files = bundle.validate_archive(archive)
        snapshot = bundle.shell_aliases(files['generated/shell/zshrc.snapshot'])
        self.assertEqual([entry['name'] for entry in snapshot['aliases']], ['alpha'])
        self.assertNotIn(b'private_fixture', files['generated/shell/zshrc.snapshot'])
        self.assertNotIn(b'optional.zsh', files['generated/shell/zshrc.snapshot'])
        self.assertEqual(target.read_bytes(), original)
        # This saved capability-3 alias has excluded startup context. Absence
        # cannot prove recoverability; the existing Check contract is unverified.
        self.assertFalse(snapshot['layout'][0]['closed'])
        for actual, expected in ((original, 'matching'), (b"alias other='ls'\n", 'unverified'),
                                 (b"alias alpha='git diff'\n", 'differing')):
            target.write_bytes(actual)
            if expected == 'unverified':
                self.assertEqual(bundle.shell_contract().recovery_contract().plan(snapshot, str(self.home))['reason'], 'source_prerequisite')
            before = target.stat()
            request = dict(protocol_version=1, operation_id='alias-check', operation='environment_compare', parameters=dict(bundle_path=str(archive)))
            checked = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')], cwd=self.project,
                                     env=self.environment, input=json.dumps(request).encode(), capture_output=True, timeout=30)
            self.assertEqual(checked.returncode, 0, checked.stdout)
            data = next(json.loads(line)['data'] for line in checked.stdout.splitlines() if json.loads(line)['type'] == 'result')
            self.assertEqual([r['comparison_kind'] for r in data['comparison_records']], [expected])
            self.assertEqual(data['comparison']['counts'][expected], 1)
            self.assertEqual(data['comparison']['counts']['unresolved'], 1)
            self.assertEqual(data['reference_presentation']['shell_alias_labels'], {row['items'][1]['item_id']: 'alpha'})
            self.assertNotIn('git status', json.dumps(data))
            self.assertEqual(target.read_bytes(), actual)
            self.assertEqual(target.stat().st_mtime_ns, before.st_mtime_ns)

    def test_shell_recovery_capture_script_consent_and_freshness(self):
        self.fixture(shell=True)
        (self.home / '.local/bin').mkdir(parents=True)
        script = self.home / '.local/bin/adns'
        script.write_text('#!/bin/bash\n/usr/bin/sw_vers -productVersion\n'); script.chmod(0o755)
        (self.home / '.zshrc').write_text("alias adns='$HOME/.local/bin/adns'\n")
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'shell-zsh')
        chosen = dict(categories=[], items={'shell-zsh': [row['items'][0]['item_id']]}, secure_identities=[])
        prepared = self.prepare(chosen)
        candidates = prepared['shell_scripts']
        self.assertEqual(len(candidates), 1)
        self.assertEqual(prepared['summary']['selected_items'], 1)
        extra = dict(destination=str(self.root / 'script.mbt'), expected_prepared_capture_id=prepared['prepared_capture_id'],
                     shell_script_ids=[candidates[0]['id']])
        # Metadata is bound before consent; a changed script cannot be captured.
        script.write_text('#!/bin/bash\n# Platform details\n/usr/bin/sw_vers -buildVersion\n')
        result, events = self.invoke_capture('capture_execute', chosen, extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        self.assertFalse((self.root / 'script.mbt').exists())
        extra['expected_prepared_capture_id'] = self.prepare(chosen)['prepared_capture_id']
        result, events = self.invoke_capture('capture_execute', chosen, extra)
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(self.root / 'script.mbt')
        value = bundle.shell_aliases(files['generated/shell/zshrc.snapshot'])
        self.assertEqual(value['version'], 3)
        self.assertEqual(value['scripts'][0]['text'], script.read_text())
        self.assertEqual(value['scripts'][0]['mode'], 0o755)
        self.assertNotIn('#!/bin/bash', json.dumps(events))
        self.assertEqual(next(e['data'] for e in events if e['type'] == 'result')['bundle']['selected_item_counts']['shell-zsh'], 1)

    def test_shell_script_selection_candidates_and_exact_capture_scope(self):
        for malformed in [None, True, 'a' * 64, ['a' * 64] * 2, ['a' * 64 + '\n'], [17], [f'{i:064x}' for i in range(17)]]:
            result, events = self.invoke_capture(extra={'shell_script_selection': malformed})
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events[-1]['data']['code'], 'invalid_request')
        self.fixture(shell=True)
        (self.home / '.local/bin').mkdir(parents=True)
        for name, text in [('shared', '#!/bin/sh\n/bin/date\n'), ('other', '#!/bin/sh\ntouch "$HOME/must-not-run"\n')]:
            path = self.home / '.local/bin' / name
            path.write_text(text); path.chmod(0o700)
        (self.home / '.zshrc').write_text("alias one='$HOME/.local/bin/shared'\nalias two='$HOME/.local/bin/shared'\nalias other='$HOME/.local/bin/other'\n")
        scan = self.prepare()
        candidates = scan['shell_script_candidates']
        self.assertEqual(len(candidates), 2)
        shared = next(row for row in candidates if row['path'].endswith('/shared'))
        other = next(row for row in candidates if row['path'].endswith('/other'))
        self.assertEqual(len(shared['alias_ids']), 2)
        self.assertNotIn('shell_scripts', scan)
        self.assertNotIn('must-not-run', json.dumps(scan))
        inspected, events = self.invoke_capture('capture_script_inspect', extra={'scripts': {
            row['id']: row['observation_id'] for row in candidates}})
        self.assertEqual(inspected.returncode, 0, events)
        qualification = {row['id']: row for row in events[-2]['data']['scripts']}
        self.assertEqual(qualification[shared['id']]['status'], 'qualified')
        self.assertEqual(qualification[other['id']]['status'], 'unsupported')
        self.assertEqual(qualification[other['id']]['reason'], 'script_dynamic_or_dependency')
        self.assertFalse(any(event['type'] == 'capture_category' for event in events), 'Targeted inspection never reruns Discovery')
        self.assertNotIn('must-not-run', json.dumps(events))
        self.assertFalse((self.home / 'must-not-run').exists())
        stale, events = self.invoke_capture('capture_script_inspect', extra={'scripts': {shared['id']: '0' * 64}})
        self.assertEqual(stale.returncode, 0)
        self.assertEqual(events[-2]['data']['scripts'][0]['reason'], 'script_changed')
        for scope in [{}, {'invalid': shared['observation_id']}, {shared['id']: True}]:
            invalid, events = self.invoke_capture('capture_script_inspect', extra={'scripts': scope})
            self.assertEqual(invalid.returncode, 2)
            self.assertEqual(events[-1]['data']['code'], 'invalid_request')
        chosen = dict(categories=['shell-zsh'], items={}, secure_identities=[])
        result, events = self.invoke_capture(selection=chosen, extra={'shell_script_selection': [other['id']]})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1]['data']['code'], 'script_transfer_unsupported')
        self.assertFalse((self.home / 'must-not-run').exists())
        alias_only, events = self.invoke_capture(selection=chosen, extra={'shell_script_selection': []})
        self.assertEqual(alias_only.returncode, 0, events)
        self.assertEqual(events[-2]['data']['summary']['selected_items'], 3)
        result, events = self.invoke_capture(selection=chosen, extra={'shell_script_selection': [shared['id']]})
        self.assertEqual(result.returncode, 0, events)
        prepared = events[-2]['data']
        self.assertEqual(prepared['summary']['selected_items'], 3)
        self.assertEqual(prepared['shell_script_candidates'], candidates)
        extra = dict(destination=str(self.root / 'selected-script.mbt'), expected_prepared_capture_id=prepared['prepared_capture_id'],
                     shell_script_selection=[shared['id']])
        result, events = self.invoke_capture('capture_execute', chosen, extra)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1]['data']['code'], 'invalid_script_consent')
        result, events = self.invoke_capture('capture_execute', chosen, dict(extra, shell_script_selection=[], shell_script_ids=[shared['id']]))
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        self.assertFalse((self.root / 'selected-script.mbt').exists())
        result, events = self.invoke_capture('capture_execute', chosen, dict(extra, shell_script_ids=[shared['id']]))
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(self.root / 'selected-script.mbt')
        value = bundle.shell_aliases(files['generated/shell/zshrc.snapshot'])
        self.assertEqual([row['path'] for row in value['scripts']], ['.local/bin/shared'])
        self.assertEqual(len(value['aliases']), 3)
        inspected = bundle.inspect_bundle(self.root / 'selected-script.mbt', str(self.home))
        self.assertEqual(len(inspected['shell_script_candidates']), 1)
        self.assertEqual(inspected['shell_script_candidates'][0]['alias_ids'], shared['alias_ids'])
        self.assertEqual(inspected['selected_item_counts']['shell-zsh'], 3)

    def test_opaque_script_capture_policy_consent_bytes_and_stale(self):
        self.fixture(shell=True)
        (self.home / '.local/bin').mkdir(parents=True)
        script = self.home / '.local/bin/automation'
        body = '#!/bin/bash\n# Сценарий fixture\nreport() { for x in one two; do echo "$x"; done; }\nif true; then report; fi\n'
        script.write_text(body); script.chmod(0o755)
        (self.home / '.zshrc').write_text("alias one='$HOME/.local/bin/automation'\nalias two='$HOME/.local/bin/automation'\n")
        scan = self.prepare()
        self.assertEqual(scan['shell_script_policies'], ['opaque-file-v4', 'opaque-file-v5'])
        candidate, = scan['shell_script_candidates']
        self.assertEqual(len(candidate['alias_ids']), 2)
        policy = {'shell_script_policy': 'opaque-file-v4'}
        result, events = self.invoke_capture('capture_script_inspect', extra=dict(policy, scripts={candidate['id']: candidate['observation_id']}))
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-2]['data']['scripts'][0]['status'], 'qualified')
        self.assertNotIn('report()', json.dumps(events))
        chosen = dict(categories=['shell-zsh'], items={}, secure_identities=[])
        selected = dict(policy, shell_script_selection=[candidate['id']])
        result, events = self.invoke_capture(extra=selected)
        self.assertEqual(result.returncode, 2, 'File authorization needs an explicit Capture selection')
        result, events = self.invoke_capture(selection=chosen, extra=dict(policy, shell_script_selection=['0' * 64]))
        self.assertEqual(result.returncode, 2, 'Unknown file identity must not create a standalone requirement')
        result, events = self.invoke_capture(selection=chosen, extra=selected)
        self.assertEqual(result.returncode, 0, events)
        prepared = events[-2]['data']
        self.assertEqual(prepared['shell_script_policy'], 'opaque-file-v4')
        self.assertEqual(prepared['summary']['selected_items'], 3)
        target = self.root / 'opaque.mbt'
        execute = dict(selected, destination=str(target), expected_prepared_capture_id=prepared['prepared_capture_id'], shell_script_ids=[candidate['id']])
        script.write_text(body + '# changed\n')
        result, events = self.invoke_capture('capture_execute', chosen, execute)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(target.exists())
        result, events = self.invoke_capture(selection=chosen, extra=selected)
        self.assertEqual(result.returncode, 0, events)
        execute['expected_prepared_capture_id'] = events[-2]['data']['prepared_capture_id']
        result, events = self.invoke_capture('capture_execute', chosen, execute)
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(target)
        value = bundle.shell_aliases(files['generated/shell/zshrc.snapshot'])
        self.assertEqual(value['version'], 4)
        self.assertEqual(bundle.validate_shell(files), {'shell-aliases': 4})
        self.assertEqual(value['scripts'][0]['text'].encode(), script.read_bytes())
        self.assertEqual(value['scripts'][0]['mode'], 0o755)
        self.assertEqual(bundle.inspect_bundle(target, str(self.home))['selected_item_counts']['shell-zsh'], 2)
        self.assertNotIn('report()', json.dumps(events))
        # A retained file selection can be captured independently of every alias.
        only_file = dict(categories=[], items={}, secure_identities=[])
        result, events = self.invoke_capture(selection=only_file, extra=selected)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-2]['data']['summary'], dict(selected_domains=1, selected_items=1, secure_identity_count=0))
        standalone_target = self.root / 'standalone.mbt'
        execute.update(destination=str(standalone_target), expected_prepared_capture_id=events[-2]['data']['prepared_capture_id'])
        result, events = self.invoke_capture('capture_execute', only_file, execute)
        self.assertEqual(result.returncode, 0, events)
        saved = bundle.shell_aliases(bundle.validate_archive(standalone_target)['generated/shell/zshrc.snapshot'])
        self.assertEqual((saved['aliases'], saved['layout']), ([], []))
        self.assertEqual(saved['scripts'][0]['text'].encode(), script.read_bytes())
        inspected = bundle.inspect_bundle(standalone_target, str(self.home))
        self.assertEqual(inspected['selected_item_counts']['shell-zsh'], 1)
        self.assertTrue(inspected['shell_script_candidates'][0]['independent'])
        self.assertEqual(inspected['shell_script_candidates'][0]['alias_ids'], [])
        for invalid in [True, 'unknown', 4]:
            result, events = self.invoke_capture(extra={'shell_script_policy': invalid})
            self.assertEqual(result.returncode, 2)

    def test_manual_scripts_capture_restore_check_without_aliases(self):
        self.fixture(shell=True)
        directory = self.home / 'Scripts'; directory.mkdir(mode=0o700)
        contents = {'one.sh': b'#!/bin/sh\r\n# fixture\r\ntouch "$HOME/must-not-run"\r\n',
                    'two.zsh': b'print fixture\n',
                    'three.py': b'#!/usr/bin/env python3\nprint("fixture")\n',
                    'no-extension': b'#!/bin/bash\necho fixture\n'}
        for index, (name, raw) in enumerate(contents.items()):
            path = directory / name; path.write_bytes(raw); path.chmod(0o600 if name == "two.zsh" else 0o755 if index % 2 else 0o700)
        quarantine = b'0083;12345678;MacseedFixture;'
        quarantined = directory / 'one.sh'
        subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', quarantine.decode(), str(quarantined)], check=True)
        before = {path.name: (path.read_bytes(), path.stat().st_mode, path.stat().st_mtime_ns) for path in directory.iterdir()}
        paths = [str(directory / name) for name in contents]
        policy = dict(shell_script_policy='opaque-file-v5', shell_script_paths=paths)
        result, events = self.invoke_capture('capture_script_inspect', extra=dict(policy, scripts={}))
        self.assertEqual(result.returncode, 0, events)
        rows = events[-2]['data']['shell_script_candidates']
        self.assertEqual(len(rows), 4)
        self.assertTrue(all(row['independent'] and not row['alias_ids'] for row in rows))
        self.assertTrue(all(row['status'] == 'qualified' for row in events[-2]['data']['scripts']))
        ids = sorted(row['id'] for row in rows)
        chosen = dict(categories=[], items={}, secure_identities=[])
        selected = dict(policy, shell_script_selection=ids)
        result, events = self.invoke_capture(selection=chosen, extra=selected)
        self.assertEqual(result.returncode, 0, events)
        prepared = events[-2]['data']
        self.assertEqual(prepared['summary'], dict(selected_domains=1, selected_items=4, secure_identity_count=0))
        target = self.root / 'manual.mbt'
        execute = dict(selected, destination=str(target), expected_prepared_capture_id=prepared['prepared_capture_id'])
        result, events = self.invoke_capture('capture_execute', chosen, execute)
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'invalid_script_consent')
        self.assertFalse(target.exists())
        # Changing one picked file invalidates the exact prepared publication.
        (directory / 'one.sh').write_bytes(contents['one.sh'] + b'# changed\n')
        result, events = self.invoke_capture('capture_execute', chosen, dict(execute, shell_script_ids=ids))
        self.assertEqual(result.returncode, 2, events)
        self.assertFalse(target.exists())
        (directory / 'one.sh').write_bytes(contents['one.sh'])
        result, events = self.invoke_capture(selection=chosen, extra=selected)
        self.assertEqual(result.returncode, 0, events)
        execute['expected_prepared_capture_id'] = events[-2]['data']['prepared_capture_id']
        result, events = self.invoke_capture('capture_execute', chosen, dict(execute, shell_script_ids=ids))
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(target)
        saved = bundle.shell_aliases(files['generated/shell/zshrc.snapshot'], files)
        self.assertEqual(saved['version'], 5)
        self.assertEqual(bundle.shell_contract().recovery_contract().quarantine_bytes(next(row for row in saved['scripts'] if row['path'] == 'Scripts/one.sh')['quarantine']), quarantine)
        self.assertEqual(len([name for name in files if bundle.script_member(name)]), 4)
        self.assertNotIn(b'touch', files['generated/shell/zshrc.snapshot'])
        self.assertEqual((saved['aliases'], saved['layout']), ([], []))
        for row in saved['scripts']:
            name = Path(row['path']).name
            self.assertEqual(row['text'].encode(), contents[name])
            self.assertEqual(row['mode'], before[name][1] & 0o777)
        self.assertFalse((self.home / 'must-not-run').exists())
        self.assertFalse((self.home / '.zshrc').exists())
        source = self.home
        self.home = self.root / 'target-home'; self.home.mkdir(mode=0o700)
        self.environment['HOME'] = str(self.home)
        self.archive = target
        # Only fixture tools/launcher are enabled; all mutations stay in its HOME/project.
        (self.root / 'bin/sudo').write_text('#!/bin/bash\nexit 0\n')
        (self.project / 'bin').mkdir()
        shutil.copy2(ROOT / 'bin/bs', self.project / 'bin/bs')
        shutil.copy2(ROOT / 'scripts/install-bs.sh', self.project / 'scripts/install-bs.sh')
        (self.root / 'bin/bs').symlink_to(self.project / 'bin/bs')
        self.environment['BS_INSTALL_DIR'] = str(self.root / 'bin')
        result, events = fixtures.RestorePrepareTests.invoke(self, shell_script_selection=ids)
        self.assertEqual(result.returncode, 0, events)
        plan = next(e['data'] for e in events if e['type'] == 'result')
        result, events = fixtures.RestorePrepareTests.execute(self, plan['prepared_plan_id'], shell_script_selection=ids)
        self.assertEqual(result.returncode, 2, events)
        self.assertFalse((self.home / 'Scripts').exists())
        result, events = fixtures.RestorePrepareTests.execute(self, plan['prepared_plan_id'], shell_script_selection=ids, shell_script_ids=ids)
        self.assertEqual(result.returncode, 0, events)
        for name, raw in contents.items():
            restored = self.home / 'Scripts' / name
            self.assertEqual(restored.read_bytes(), raw)
            self.assertEqual(restored.stat().st_mode & 0o777, before[name][1] & 0o777)
            self.assertEqual((source / 'Scripts' / name).read_bytes(), raw)
        for selected in [quarantined, self.home / 'Scripts/one.sh']:
            attribute = subprocess.run(['/usr/bin/xattr', '-p', 'com.apple.quarantine', str(selected)], check=True, capture_output=True).stdout.rstrip(b'\n')
            self.assertEqual(attribute, quarantine)
        self.assertFalse((self.home / '.zshrc').exists())
        self.assertFalse((self.home / 'must-not-run').exists())
        request = dict(protocol_version=1, operation_id='manual-check', operation='environment_compare', parameters=dict(bundle_path=str(target)))
        checked = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')], cwd=self.project,
            env=self.environment, input=json.dumps(request).encode(), capture_output=True, timeout=30)
        self.assertEqual(checked.returncode, 0, checked.stdout)
        report = next(json.loads(line)['data'] for line in checked.stdout.splitlines() if json.loads(line)['type'] == 'result')
        self.assertEqual(report['comparison']['counts']['matching'], 4)
        self.assertEqual(len(report['comparison_records']), 4)
        self.assertEqual({row['item_id'] for row in report['comparison_records']}, {'shell-script:' + key for key in ids})
        self.assertTrue(all(row['comparison_kind'] == 'matching' for row in report['comparison_records']))
        verified = report['records']['verification_records']
        self.assertEqual(len(verified), 4)
        self.assertTrue(all(row['predicate'] == 'script_file' and row['conformity'] == 'verified' for row in verified))
        stamps = {name: (self.home / 'Scripts' / name).stat().st_mtime_ns for name in contents}
        result, events = fixtures.RestorePrepareTests.invoke(self, shell_script_selection=ids)
        plan = next(e['data'] for e in events if e['type'] == 'result')
        self.assertFalse(plan['has_executable_changes'])
        result, events = fixtures.RestorePrepareTests.execute(self, plan['prepared_plan_id'], shell_script_selection=ids)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(stamps, {name: (self.home / 'Scripts' / name).stat().st_mtime_ns for name in contents})

    def test_manual_scripts_rejections_and_alias_deduplication(self):
        self.fixture(shell=True)
        directory = self.home / 'Scripts'; directory.mkdir(mode=0o700)
        path = directory / 'shared'; path.write_bytes(b'#!/bin/sh\necho fixture\n'); path.chmod(0o700)
        (self.home / '.zshrc').write_text("alias shared='$HOME/Scripts/shared'\n")
        discovered, = self.prepare()['shell_script_candidates']
        policy = dict(shell_script_policy='opaque-file-v4')
        result, events = self.invoke_capture('capture_script_inspect', extra=dict(policy, scripts={},
            shell_script_paths=[str(path), str(directory) + '/./shared']))
        self.assertEqual(result.returncode, 0, events)
        candidate, = events[-2]['data']['shell_script_candidates']
        self.assertEqual(candidate['id'], discovered['id'])
        self.assertEqual(candidate['alias_ids'], discovered['alias_ids'])
        selected = dict(policy, shell_script_paths=[str(path)], shell_script_selection=[candidate['id']])
        chosen = dict(categories=['shell-zsh'], items={}, secure_identities=[])
        result, events = self.invoke_capture(selection=chosen, extra=selected)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-2]['data']['summary']['selected_items'], 2)
        prepared = events[-2]['data']['prepared_capture_id']
        target = self.root / 'deduplicated.mbt'
        result, events = self.invoke_capture('capture_execute', chosen, dict(selected,
            destination=str(target), expected_prepared_capture_id=prepared, shell_script_ids=[candidate['id']]))
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(len(bundle.shell_aliases(bundle.validate_archive(target)['generated/shell/zshrc.snapshot'])['scripts']), 1)
        link = directory / 'link'; link.symlink_to(path)
        sourced = directory / 'sourced'; sourced.write_bytes(b'#!/bin/sh\necho fixture\n'); sourced.chmod(0o700)
        (self.home / '.zshrc').write_text("alias shared='$HOME/Scripts/shared'\nsource ~/Scripts/sourced\n")
        bad_files = [(link, 'script_observation_failed'), (self.home / '.zshrc', 'script_path_unsupported'),
                     (sourced, 'script_path_unsupported'),
                     (self.root / 'outside', 'script_path_unsupported')]
        for name, raw, mode, reason in [('text.py', b'print(1)\n', 0o700, 'script_format_unsupported'),
                ('large', b'#!/bin/sh\n' + b'#' * 8192, 0o700, 'script_limit'),
                ('writable', b'#!/bin/sh\ntrue\n', 0o777, 'script_observation_failed'),
                ('not-executable', b'#!/bin/sh\ntrue\n', 0o600, 'script_observation_failed'),
                ('example.py', b'#!/usr/bin/env python3\nAPI_TOKEN="private-fixture"\n', 0o700, 'script_sensitive_indicator')]:
            bad = directory / name; bad.write_bytes(raw); bad.chmod(mode); bad_files.append((bad, reason))
        for bad, reason in bad_files:
            with self.subTest(path=bad.name):
                result, events = self.invoke_capture('capture_script_inspect', extra=dict(policy, scripts={}, shell_script_paths=[str(bad)]))
                if result.returncode:
                    self.assertEqual(events[-1]['data']['code'], reason, events)
                else:
                    self.assertEqual(events[-2]['data']['scripts'][0]['reason'], reason, events)
                self.assertNotIn('private-fixture', json.dumps(events))
        for paths in [True, [], ['relative'], [str(path)] * 17]:
            result, events = self.invoke_capture('capture_script_inspect', extra=dict(policy, scripts={}, shell_script_paths=paths))
            self.assertEqual(result.returncode, 2, events)

    def test_shell_sources_capture_subset_provenance_and_privacy(self):
        self.fixture(shell=True)
        (self.home / '.config').mkdir()
        (self.home / '.config/.git').mkdir()
        (self.home / '.zshrc').write_text(f'source "{self.home}/.config/aliases"\n')
        original = (b'alias c.="code ."\n'
                    b"alias run_local='$HOME/.config/helper.sh'\n"
                    b'alias reload_local="source ~/.zshrc"\nexport API_TOKEN=private_fixture\n')
        target = self.home / '.config/aliases'
        target.write_bytes(original)
        script = self.home / '.config/helper.sh'
        script.write_text('#!/bin/sh\ntouch "$HOME/must-not-run"\n'); script.chmod(0o700)
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'shell-zsh')
        self.assertEqual([r['label'] for r in row['items']], ['c.', 'run_local', 'reload_local'])
        chosen = dict(categories=[], items={'shell-zsh': [r['item_id'] for r in row['items'][:2]]}, secure_identities=[])
        prepared = self.prepare(chosen)
        result, events = self.execute(prepared['prepared_capture_id'], chosen)
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(self.root / 'captured.mbt')
        value = bundle.shell_aliases(files['generated/shell/zshrc.snapshot'])
        self.assertEqual(value['version'], 3)
        self.assertEqual([r['name'] for r in value['aliases']], ['c.', 'run_local'])
        self.assertEqual(value['aliases'][0]['chain'], ['.zshrc', '.config/aliases'])
        self.assertNotIn(b'private_fixture', b''.join(files.values()))
        self.assertEqual({key for key in files if key.startswith('generated/')}, {'generated/shell/zshrc.snapshot'})
        published = next(e['data'] for e in events if e['type'] == 'result')
        self.assertEqual(published['bundle']['selected_categories'], ['shell-zsh'])
        self.assertEqual(published['bundle']['selected_item_counts']['shell-zsh'], 2)
        self.assertEqual(prepared['summary']['selected_domains'], 1)
        self.assertEqual(prepared['summary']['selected_items'], 2)
        # Recovery capability cannot report a match when required dependencies are missing.
        script.unlink()
        request = dict(protocol_version=1, operation_id='source-check', operation='environment_compare',
                       parameters=dict(bundle_path=str(self.root / 'captured.mbt')))
        checked = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                 cwd=self.project, env=self.environment, input=json.dumps(request).encode(),
                                 capture_output=True, timeout=30)
        self.assertEqual(checked.returncode, 0, checked.stdout)
        data = next(json.loads(line)['data'] for line in checked.stdout.splitlines() if json.loads(line)['type'] == 'result')
        self.assertEqual(data['comparison']['counts']['matching'], 0)
        self.assertEqual(data['comparison']['counts']['unverified'], 2)
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertIn('dependency_unavailable', [r['code'] for r in data['records']['diagnostics']])
        self.assertNotIn('.config/helper.sh', json.dumps(data))
        self.assertEqual(target.read_bytes(), original)
        self.assertFalse(script.exists())
        self.assertFalse((self.home / 'must-not-run').exists())

    def test_ssh_host_capture_subset_full_empty_and_readonly_check(self):
        target = self.ssh_fixture()
        original = target.read_bytes()
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'ssh-configuration')
        self.assertEqual(row['selection_mode'], 'items')
        self.assertEqual([entry['label'] for entry in row['items']], ['github', 'production'])
        chosen = {'categories': [], 'items': {'ssh-configuration': [row['items'][0]['item_id']]}, 'secure_identities': []}
        prepared = self.prepare(chosen)
        self.assertEqual(prepared['summary'], dict(selected_domains=1, selected_items=1, secure_identity_count=0))
        result, events = self.execute(prepared['prepared_capture_id'], chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-2]['data']['bundle']['selected_item_counts']['ssh-configuration'], 1)
        archive = self.root / 'captured.mbt'
        files = bundle.validate_archive(archive)
        version, status, excluded, profiles = bundle.ssh_snapshot(files['generated/ssh/config.snapshot'])
        self.assertEqual((version, status, excluded, list(profiles)), (1, 'ready', 0, ['github']))
        self.assertEqual(profiles['github'], [('hostname', 'github.invalid'), ('user', 'git'), ('port', '22')])
        self.assertNotIn('secure.age', files)
        self.assertEqual(target.read_bytes(), original)
        # Check reads only saved profiles. An omitted Host may differ locally.
        target.write_bytes(original.replace(b'production.invalid', b'changed.invalid'))
        before = target.stat()
        request = dict(protocol_version=1, operation_id='ssh-check', operation='environment_compare',
                       parameters=dict(bundle_path=str(archive)))
        result = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                cwd=self.project, env=self.environment, input=json.dumps(request).encode(), capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        checked = [json.loads(line) for line in result.stdout.splitlines()]
        rows = [row for row in checked[-2]['data']['comparison_records'] if row['domain'] == 'ssh-configuration']
        self.assertEqual([row['comparison_kind'] for row in rows], ['matching'])
        self.assertEqual(target.stat().st_mtime_ns, before.st_mtime_ns)
        for index, selection in enumerate((dict(categories=['ssh-configuration'], items={}, secure_identities=[]),
                                          dict(categories=[], items={'ssh-configuration': []}, secure_identities=[]))):
            with self.subTest(selection=selection):
                prepared = self.prepare(selection)
                destination = self.root / f'scope-{index}.mbt'
                result, events = self.execute(prepared['prepared_capture_id'], selection, destination)
                self.assertEqual(result.returncode, 0, events)
                saved = bundle.validate_archive(destination)
                if index == 0:
                    self.assertEqual(list(bundle.ssh_snapshot(saved['generated/ssh/config.snapshot'])[3]), ['github', 'production'])
                else:
                    self.assertNotIn('generated/ssh/config.snapshot', saved)
                    self.assertFalse(bundle.parse_blueprint(saved['blueprint.conf'])[1]['ssh-configuration'])

    def test_ssh_host_capture_partial_coverage_and_v2_preserved(self):
        self.ssh_fixture(b' IdentityFile ~/.ssh/deploy\nHost excluded\n HostName excluded.invalid\n ProxyCommand forbidden\n')
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'ssh-configuration')
        self.assertEqual(row['reason'], 'source_partial')
        self.assertEqual(len(row['items']), 2)
        chosen = dict(categories=[], items={'ssh-configuration': [row['items'][0]['item_id']]}, secure_identities=[])
        result, events = self.execute(self.prepare(chosen)['prepared_capture_id'], chosen)
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(self.root / 'captured.mbt')
        self.assertEqual(bundle.ssh_snapshot(files['generated/ssh/config.snapshot'])[:3], (2, 'partial', 1))
        self.assertEqual(list(bundle.ssh_snapshot(files['generated/ssh/config.snapshot'])[3]), ['github'])
        self.assertEqual(bundle.validate_ssh(files), {'ssh-configuration': 2})

    def test_ssh_host_capture_stale_ids_scope_and_ambiguous_source(self):
        target = self.ssh_fixture()
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'ssh-configuration')
        chosen = dict(categories=[], items={'ssh-configuration': [row['items'][0]['item_id']]}, secure_identities=[])
        plan = self.prepare(chosen)['prepared_capture_id']
        for invalid in ('unknown-host', row['items'][0]['item_id'].upper()):
            selection = dict(chosen, items={'ssh-configuration': [invalid]})
            result, events = self.invoke_capture(selection=selection)
            self.assertEqual(result.returncode, 2, events)
            self.assertEqual(events[-1]['data']['code'], 'invalid_selection')
        for selection in (dict(chosen, categories=['ssh-configuration'], items={}),
                          dict(chosen, items={'ssh-configuration': [row['items'][1]['item_id']]})):
            result, events = self.execute(plan, selection)
            self.assertEqual(result.returncode, 2, events)
            self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        target.write_bytes(target.read_bytes().replace(b'production.invalid', b'changed.invalid'))
        result, events = self.execute(plan, chosen)
        self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        self.assertFalse((self.root / 'captured.mbt').exists())
        target.write_bytes(target.read_bytes() + b'Host GITHUB\n HostName collision.invalid\n')
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'ssh-configuration')
        self.assertEqual((row['status'], row['items']), ('unsupported', []))
        result, events = self.invoke_capture(selection=chosen)
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'capture_source_unavailable')

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

    def test_unselected_application_inventories_not_saved(self):
        self.fixture()
        (self.root / 'bin/mas').write_text('#!/bin/bash\nprintf "%s\\n" "12345 Fixture Selected (1.0)" "67890 Fixture Excluded (2.0)"\n')
        (self.root / 'bin/code').write_text('#!/bin/bash\nprintf "%s\\n" fixture.selected fixture.excluded\n')
        prepared = self.prepare(self.selection)
        for domain in ('app-store', 'vscode-extensions'):
            row = next(row for row in prepared['inventory'] if row['domain'] == domain)
            self.assertEqual(len(row['items']), 2)
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(self.root / 'captured.mbt')
        selected, _ = bundle.parse_blueprint(files['blueprint.conf'])
        for domain, filename in bundle.COMPLETE_INVENTORIES.items():
            self.assertEqual(selected[domain], [])
            self.assertNotIn('generated/' + filename, files)
            self.assertNotIn('generated/provenance/' + domain + '.sha256', files)
        self.assertEqual(files['generated/brew-packages.conf'], b'fixture-formula\n')

    def test_partial_app_store_capture_retains_comparison_inventory(self):
        self.fixture()
        (self.root / 'bin/mas').write_text('#!/bin/bash\nprintf "%s\\n" "12345 Fixture Selected (1.0)" "67890 Fixture Excluded (2.0)"\n')
        selection = dict(categories=[], items={'app-store': ['12345']}, secure_identities=[])
        prepared = self.prepare(selection)
        result, events = self.execute(prepared['prepared_capture_id'], selection)
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(self.root / 'captured.mbt')
        self.assertEqual(bundle.parse_blueprint(files['blueprint.conf'])[0]['app-store'], ['12345'])
        self.assertEqual(files['generated/appstore.conf'], b'12345|Fixture Selected\n67890|Fixture Excluded\n')
        self.assertEqual(files['generated/provenance/app-store.sha256'],
                         ('complete ' + bundle.digest(files['generated/appstore.conf']) + '\n').encode())

    def test_stale_ice_capture_with_installed_thaw(self):
        self.fixture()
        app = self.home / 'Applications/Thaw.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.example.Thaw', 'CFBundleExecutable': 'Thaw'}))
        executable = app / 'Contents/MacOS/Thaw'
        executable.write_text('#!/bin/sh\n')
        executable.chmod(0o700)
        font = self.home / 'Library/Fonts/Fixture.ttf'
        font.parent.mkdir(parents=True)
        font.write_bytes(b'fixture font')
        package_file = self.home / 'Library/fixture-payload'
        package_file.write_bytes(b'fixture package payload')
        rows = [
            {'token': 'jordanbaird-ice', 'installed': '1.0',
             'artifacts': [{'app': ['Ice.app'], 'target': str(app.with_name('Ice.app'))}]},
            {'token': 'thaw@beta', 'installed': '1.0',
             'artifacts': [{'app': ['Thaw.app'], 'target': str(app)}]},
            {'token': 'font-fixture', 'installed': '1.0',
             'artifacts': [{'font': ['Fixture.ttf'], 'target': str(font)}]},
            {'token': 'pkg-fixture', 'installed': '1.0',
             'artifacts': [{'pkg': ['Fixture.pkg']}, {'uninstall': [{'pkgutil': 'org.example.fixture'}]}]},
        ]
        metadata = self.root / 'casks.json'
        metadata.write_text(json.dumps({'casks': rows}))
        self.environment['CAPTURE_CASK_METADATA'] = str(metadata)
        self.environment['CAPTURE_PKG_PAYLOAD'] = str(package_file)
        calls = self.root / 'cask-calls'
        self.environment['CAPTURE_CASK_CALLS'] = str(calls)
        # Substitute only public Homebrew/receipt observations. Discovery, typed
        # payload checks, Selection, Preview and Bundle validation remain real.
        helper = self.project / 'modules/apps/adapters/homebrew_cask.py'
        helper.write_text(helper.read_text().replace("if __name__ == '__main__':", '''
def fixture_packages(self, selectors):
    require(selectors == ['org.example.fixture'])
    return [{'id': selectors[0], 'present': True, 'paths': [os.environ['CAPTURE_PKG_PAYLOAD']]}]
PublicObserver.packages = fixture_packages

if __name__ == '__main__':'''))
        brew = self.root / 'bin/brew'
        brew.write_text(brew.read_text().replace(
            '"info --json=v2 --installed --cask") echo \'{"casks":[]}\'',
            '''"info --json=v2 --installed --cask") cat "$CAPTURE_CASK_METADATA" ;;
 "info --json=v2 --cask "*)
    printf '%s\\n' "$*" >> "$CAPTURE_CASK_CALLS"
    python3 -B -c 'import json,os,sys; rows=json.load(open(os.environ["CAPTURE_CASK_METADATA"]))["casks"]; print(json.dumps({"casks":[r for r in rows if r["token"] in sys.argv[1:]]}))' "${@:4}"'''
        ).replace('"list --cask") exit 0',
                  '"list --cask") printf "%s\\n" jordanbaird-ice thaw@beta font-fixture pkg-fixture'))
        expected = ['font-fixture', 'pkg-fixture', 'thaw@beta']
        for index, selection in enumerate((
                {'categories': ['homebrew-casks'], 'items': {}, 'secure_identities': []},
                {'categories': [], 'items': {'homebrew-casks': expected[:-1]}, 'secure_identities': []})):
            with self.subTest(selection=selection):
                prepared = self.prepare(selection)
                inventory = next(row for row in prepared['inventory'] if row['domain'] == 'homebrew-casks')
                self.assertEqual(inventory['status'], 'present')
                self.assertEqual([item['item_id'] for item in inventory['items']], expected)
                target = self.root / f'captured-{index}.mbt'
                result, events = self.execute(prepared['prepared_capture_id'], selection, target)
                self.assertEqual(result.returncode, 0, events)
                files = bundle.validate_archive(target)
                selected = expected if index == 0 else expected[:-1]
                self.assertEqual(bundle.parse_blueprint(files['blueprint.conf'])[0]['homebrew-casks'], selected)
                self.assertEqual(files['generated/brew-casks.conf'].decode().splitlines(), expected)
                capabilities = json.loads(files['generated/homebrew-casks.json'])['casks']
                self.assertEqual(sorted(capabilities), selected)
                self.assertTrue(all(row['state'] == 'satisfied' for row in capabilities.values()))
                self.assertEqual(files['generated/provenance/homebrew-casks.sha256'].decode(),
                                 'complete ' + bundle.digest(files['generated/brew-casks.conf']) + '\n')
        self.assertNotIn('jordanbaird-ice', calls.read_text())
        # Filtering must not conceal an incomplete or duplicated metadata reply.
        for invalid in (rows[1:], [*rows, rows[0]]):
            metadata.write_text(json.dumps({'casks': invalid}))
            inventory = next(row for row in self.prepare()['inventory'] if row['domain'] == 'homebrew-casks')
            self.assertEqual(inventory['status'], 'observation_error')
            self.assertEqual(inventory['items'], [])
        self.assertFalse((self.project / 'config/generated').exists())
        self.assertFalse(Path(self.environment['TEST_MUTATIONS']).exists())
        self.assertTrue(executable.is_file())
        self.assertTrue(font.is_file())
        self.assertTrue(package_file.is_file())

    def overlap_fixture(self, confirmed=True):
        self.fixture()
        app = self.home / 'Applications/Fixture.app'
        (app / 'Contents/MacOS').mkdir(parents=True)
        (app / 'Contents/Info.plist').write_bytes(plistlib.dumps({
            'CFBundleIdentifier': 'org.example.Fixture', 'CFBundleExecutable': 'Fixture'}))
        executable = app / 'Contents/MacOS/Fixture'
        executable.write_text('#!/bin/sh\n'); executable.chmod(0o700)
        metadata = self.root / 'cask.json'
        metadata.write_text(json.dumps({'casks': [{
            'token': 'fixture-cask', 'installed': '1.0', 'tap': 'homebrew/cask',
            'version': '1.0', 'disabled': False, 'sha256': 'a' * 64,
            'url': 'https://example.org/fixture.dmg',
            'artifacts': [{'app': ['Fixture.app'], 'target': str(app)}]}]}))
        self.environment['CAPTURE_CASK_METADATA'] = str(metadata)
        brew = self.root / 'bin/brew'
        brew.write_text(brew.read_text().replace(
            '"info --json=v2 --installed --cask") echo \'{"casks":[]}\'',
            '"info --json=v2 --installed --cask"|"info --json=v2 --cask fixture-cask") cat "$CAPTURE_CASK_METADATA"'
        ).replace('"list --cask") exit 0', '"list --cask") echo fixture-cask'))
        (self.root / 'bin/mas').write_text('#!/bin/bash\necho "12345 Fixture (1.0)"\necho "67890 Other (1.0)"\n')
        # Only the remote catalog is substituted; production observation, Prepare,
        # Execute, Blueprint, packing and archive inspection all remain real.
        helper = self.project / 'modules/apps/application_identity.py'
        helper.write_text(helper.read_text() +
            '\ndef fetch_catalog(ids):\n    return {"12345": "org.example.Fixture"} if "12345" in ids and '
            + ('True' if confirmed else 'False') + ' else {}\n')
        self.selection = {'categories': ['app-store', 'homebrew-casks'], 'items': {}, 'secure_identities': []}

    def test_overlap_prepare_execute_and_effective_publication(self):
        self.overlap_fixture()
        prepared = self.prepare(self.selection)
        self.assertEqual(prepared['selection'], self.selection)
        self.assertEqual(prepared['effective_selection'], {
            'categories': ['homebrew-casks'], 'items': {'app-store': ['67890']}, 'secure_identities': []})
        self.assertEqual(prepared['application_duplicates'], [
            {'app_store_item_id': '12345', 'cask_item_id': 'fixture-cask'}])
        self.assertEqual(prepared['summary']['selected_items'], 2)
        self.assertEqual(prepared['prepared_capture_id'], self.prepare(self.selection)['prepared_capture_id'])
        # Packing must consume the validated scope without another identity decision.
        helper = self.project / 'modules/bundle/bundle.py'
        helper.write_text(helper.read_text() +
            '\n_original_pack = pack\n'
            'def pack(*args, **kwargs):'
            '\n    assert kwargs.get("apply_precedence") is False\n'
            '    return _original_pack(*args, **kwargs)\n')
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(result.returncode, 0, events)
        published = events[-2]['data']
        self.assertEqual(published['prepared_capture_id'], prepared['prepared_capture_id'])
        self.assertEqual(published['bundle']['selected_item_counts']['app-store'], 1)
        files = bundle.validate_archive(self.root / 'captured.mbt')
        sections, _ = bundle.parse_blueprint(files['blueprint.conf'])
        self.assertEqual(sections['app-store'], ['67890'])
        self.assertEqual(sections['homebrew-casks'], ['fixture-cask'])
        self.assertFalse((self.project / 'config/generated').exists())
        self.assertFalse(Path(self.environment['TEST_MUTATIONS']).exists())

    def test_overlap_without_evidence_preserves_both_requirements(self):
        self.overlap_fixture(confirmed=False)
        prepared = self.prepare(self.selection)
        self.assertNotIn('effective_selection', prepared)
        self.assertNotIn('application_duplicates', prepared)
        self.assertEqual(prepared['summary']['selected_items'], 3)
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(result.returncode, 0, events)
        files = bundle.validate_archive(self.root / 'captured.mbt')
        self.assertEqual(bundle.parse_blueprint(files['blueprint.conf'])[0]['app-store'], ['12345', '67890'])

    def test_overlap_changed_decision_rejects_before_publication(self):
        self.overlap_fixture()
        prepared = self.prepare(self.selection)
        (self.home / 'Library/Application Support/Macseed/ApplicationIdentities/12345.json').unlink()
        helper = self.project / 'modules/apps/application_identity.py'
        helper.write_text(helper.read_text() + '\ndef fetch_catalog(ids):\n    return {}\n')
        result, events = self.execute(prepared['prepared_capture_id'])
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'stale_prepared_capture')
        self.assertFalse(events[-1]['data']['publication_occurred'])
        self.assertFalse((self.root / 'captured.mbt').exists())

    def test_overlap_explicit_subset_and_appstore_only(self):
        self.overlap_fixture()
        selected = {'categories': [], 'items': {'homebrew-casks': ['fixture-cask'], 'app-store': ['12345']},
                    'secure_identities': []}
        prepared = self.prepare(selected)
        self.assertEqual(prepared['effective_selection']['items'], {'homebrew-casks': ['fixture-cask']})
        self.assertEqual(prepared['summary']['selected_domains'], 1)
        result, events = self.execute(prepared['prepared_capture_id'], selected)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(events[-2]['data']['bundle']['selected_item_counts']['app-store'], 0)
        selected['items'].pop('homebrew-casks')
        store_only = self.prepare(selected)
        self.assertNotIn('effective_selection', store_only)
        self.assertEqual(store_only['summary']['selected_items'], 1)

    def workspace_fixture(self, duplicate=False):
        from workspace_fixture import repository
        self.fixture(workspace=True)
        paths = ['Projects/fixture-repo']
        if duplicate:
            paths.append('Other/fixture-repo')
        for path in paths:
            repository(self.home, path)

    def test_workspace_folders_success_is_selectable(self):
        self.workspace_fixture()
        prepared = self.prepare()
        row = next(row for row in prepared['inventory'] if row['domain'] == 'workspace-folders')
        self.assertEqual(row['status'], 'present')
        self.assertIsNone(row['reason'])
        self.assertEqual(row['selection_mode'], 'items')
        self.assertIn('Projects', [item['item_id'] for item in row['items']])
        selection = {'categories': [], 'items': {'workspace-folders': ['Projects']}, 'secure_identities': []}
        self.assertEqual(self.prepare(selection)['selection'], selection)

    def test_git_repositories_success_is_selectable(self):
        self.workspace_fixture()
        prepared = self.prepare()
        row = next(row for row in prepared['inventory'] if row['domain'] == 'git-repositories')
        self.assertEqual(row['status'], 'present')
        self.assertIsNone(row['reason'])
        self.assertEqual(row['selection_mode'], 'items')
        self.assertEqual([item['label'] for item in row['items']], ['fixture-repo'])
        selection = {'categories': [], 'items': {'git-repositories': [row['items'][0]['item_id']]}, 'secure_identities': []}
        self.assertEqual(self.prepare(selection)['selection'], selection)

    def test_vscode_descriptors_selected_metadata_only_and_legacy_omission(self):
        self.workspace_fixture()
        contract = bundle.workspace_contract()
        for name in ('Team', 'Second'):
            (self.home / f'Projects/{name}.code-workspace').write_text(json.dumps({
                'folders': [{'path': 'fixture-repo', 'name': 'Code'}],
                'settings': {'private': 'secret-marker'}, 'tasks': {'command': 'never-run'},
                'launch': {}, 'extensions': {'recommendations': ['private.extension']}}))
        before = bundle.fingerprint(self.home)
        scan = self.prepare()
        row = next(row for row in scan['inventory'] if row['domain'] == 'vscode-workspaces')
        self.assertEqual(row['selection_mode'], 'items')
        self.assertEqual({item['label'] for item in row['items']}, {'Team.code-workspace', 'Second.code-workspace'})
        ids = sorted(item['item_id'] for item in row['items'])
        for count in (0, 1, 2):
            selection = dict(categories=['git-repositories'], items={}, secure_identities=[])
            if count:
                selection['items']['vscode-workspaces'] = ids[:count]
            prepared = self.prepare(selection)
            destination = self.root / f'descriptors-{count}.mbt'
            result, events = self.execute(prepared['prepared_capture_id'], selection, destination)
            self.assertEqual(result.returncode, 0, events)
            files = bundle.validate_archive(destination)
            sections, _ = bundle.parse_blueprint(files['blueprint.conf'])
            self.assertEqual(sections.get('vscode-workspaces', []), ids[:count])
            if count:
                values = json.loads(files[contract.VSCODE])['items']
                self.assertEqual({value['item_id'] for value in values}, set(ids[:count]))
                self.assertEqual(events[-2]['data']['bundle']['selected_item_counts']['vscode-workspaces'], count)
            else:
                self.assertNotIn('vscode-workspaces', sections)
                self.assertNotIn(contract.VSCODE, files)
            for private in (b'secret-marker', b'never-run', b'private.extension', str(self.home).encode()):
                self.assertNotIn(private, b''.join(files.values()))
                self.assertNotIn(private.decode(), json.dumps(events))
        result, events = self.invoke_capture(selection=dict(categories=[],
            items={'vscode-workspaces': ids[:1]}, secure_identities=[]))
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'workspace_dependency_missing')
        self.assertEqual(bundle.fingerprint(self.home), before)

    def role_overlap_roundtrip(self, folders, git):
        from workspace_fixture import repository
        self.fixture(workspace=True)
        repository(self.home, 'standalone')
        before = bundle.fingerprint(self.home)
        config_before = bundle.fingerprint(self.project / 'config')
        scan = self.prepare()
        selected = sorted(row['domain'] for row in scan['inventory'] if row['status'] == 'present'
                          and row['domain'] not in ('workspace-folders', 'git-repositories'))
        if folders:
            selected.append('workspace-folders')
        if git:
            selected.append('git-repositories')
        selection = dict(categories=sorted(selected), items={}, secure_identities=[])
        destination = self.root / 'role-overlap.mbt'
        confirmation = self.prepare(selection)
        self.assertEqual(confirmation['selection'], selection)
        self.assertFalse(destination.exists())
        result, events = self.execute(confirmation['prepared_capture_id'], selection, destination)
        self.assertEqual(result.returncode, 0, events[-1])
        self.assertTrue(events[-2]['data']['publication_occurred'])
        self.assertEqual(destination.stat().st_mode & 0o777, 0o600)
        files = bundle.validate_archive(destination)
        sections, _ = bundle.parse_blueprint(files['blueprint.conf'])
        self.assertEqual(sections['workspace-folders'], ['standalone'] if folders else [])
        contract = bundle.workspace_contract()
        checkout = contract.identity('checkout', 'standalone')
        self.assertEqual(sections['git-repositories'], [checkout] if git else [])
        self.assertEqual(bundle.validate_workspace(files, exact=True), {'workspace-topology': 1} if git else {})
        if folders:
            self.assertEqual(files['generated/workspace/folders.conf'], b'standalone|workspace\n')
        if git:
            self.assertEqual(contract.repository_records(files[contract.REPOSITORIES])[checkout]['path'], '~/standalone')
            self.assertEqual(json.loads(files[contract.TOPOLOGY])['groups'][0]['base_item_id'], checkout)
        else:
            self.assertNotIn(contract.REPOSITORIES, files)
            self.assertNotIn(contract.TOPOLOGY, files)
        request = dict(protocol_version=1, operation_id='inspect-role-overlap', operation='bundle_inspect',
                       parameters=dict(path=str(destination)))
        inspected = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
            cwd=self.project, env=self.environment, input=json.dumps(request).encode(),
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
        self.assertEqual(inspected.returncode, 0)
        inspected_events = [json.loads(line) for line in inspected.stdout.splitlines()]
        self.assertEqual(inspected_events[-1]['type'], 'completed')
        self.assertEqual(inspected_events[-2]['data']['selected_item_counts']['workspace-folders'], int(folders))
        self.assertEqual(inspected_events[-2]['data']['selected_item_counts']['git-repositories'], int(git))
        if git:
            # Execute still requires the exact freshly prepared identity.
            result, events = fixtures.RestorePrepareTests.execute(self, '0' * 64, path=destination)
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events[-1]['data']['code'], 'stale_plan')
            self.assertFalse(events[-1]['data']['publication_started'])
            self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])
        self.assertEqual(bundle.fingerprint(self.home), before)
        self.assertEqual(bundle.fingerprint(self.project / 'config'), config_before)
        self.assertFalse(Path(self.environment['TEST_MUTATIONS']).exists())

    def test_role_overlap_both_selected_publish_and_inspect(self):
        self.role_overlap_roundtrip(True, True)

    def test_role_overlap_folder_only_publish_and_inspect(self):
        self.role_overlap_roundtrip(True, False)

    def test_role_overlap_git_only_publish_and_inspect(self):
        self.role_overlap_roundtrip(False, True)

    def test_role_overlap_neither_selected_publish_and_inspect(self):
        self.role_overlap_roundtrip(False, False)

    def test_review_destination_fresh_prepare_workspace_selection_matrix(self):
        from workspace_fixture import linked
        self.workspace_fixture(duplicate=True)
        base = self.home / 'Projects/fixture-repo'
        linked(base, self.home / 'Projects/feature', (base / '.git/refs/heads/main').read_text().strip())
        before = bundle.fingerprint(self.home)
        scan = self.prepare()
        whole = sorted(row['domain'] for row in scan['inventory'] if row['status'] == 'present')
        contract = bundle.workspace_contract()
        base_id = contract.identity('checkout', 'Projects/fixture-repo')
        linked_id = contract.identity('checkout', 'Projects/feature')
        selections = [
            dict(categories=whole, items={}, secure_identities=[]),
            dict(categories=[], items={'workspace-folders': ['Projects'],
                 'git-repositories': [base_id, linked_id]}, secure_identities=[]),
            dict(categories=['homebrew-packages', 'workspace-folders'], items={}, secure_identities=[]),
        ]
        for index, selection in enumerate(selections):
            with self.subTest(selection=index):
                destination = self.root / f'review-{index}.mbt'
                result, events = self.invoke_capture(selection=selection)
                self.assertEqual(result.returncode, 0)
                confirmation = events[-2]['data']
                self.assertEqual(confirmation['selection']['categories'], sorted(selection['categories']))
                self.assertEqual(confirmation['selection']['items'],
                                 {domain: sorted(items) for domain, items in selection['items'].items()})
                self.assertEqual(events[-1]['type'], 'completed')
                self.assertFalse(destination.exists())
                self.assertFalse(any(event.get('data', {}).get('phase') == 'bundle_creation' for event in events))
        self.assertEqual(bundle.fingerprint(self.home), before)
        self.assertFalse(Path(self.environment['TEST_MUTATIONS']).exists())

    def test_review_conflicts_are_typed_and_explicit_correction_prepares(self):
        from workspace_fixture import linked, repository
        self.workspace_fixture()
        base = self.home / 'Projects/fixture-repo'
        linked(base, self.home / 'Projects/feature', (base / '.git/refs/heads/main').read_text().strip())
        repository(self.home, 'Projects/fixture-repo/nested')
        before = bundle.fingerprint(self.home)
        scan = self.prepare()
        self.assertEqual(next(row for row in scan['inventory'] if row['domain'] == 'git-repositories')['status'], 'present')
        linked_id = bundle.workspace_contract().identity('checkout', 'Projects/feature')
        nested_id = bundle.workspace_contract().identity('checkout', 'Projects/fixture-repo/nested')
        for selected in ([linked_id], [nested_id]):
            selection = dict(categories=[], items={'git-repositories': selected}, secure_identities=[])
            result, events = self.invoke_capture(selection=selection)
            self.assertEqual(result.returncode, 2)
            self.assertIn({'type': 'phase_completed', 'phase': 'discovery'},
                          [dict(type=e['type'], phase=e.get('data', {}).get('phase')) for e in events])
            self.assertEqual(events[-1]['data'], dict(code='workspace_dependency_missing', publication_occurred=False))
            self.assertNotIn(str(self.home), json.dumps(events))
            self.assertNotIn('example.invalid', json.dumps(events))
        # Explicitly select the required base/parent; Core never adds dependencies.
        corrected = dict(categories=['git-repositories'], items={'workspace-folders': ['Projects']}, secure_identities=[])
        self.assertEqual(self.prepare(corrected)['selection'], corrected)
        self.assertEqual(bundle.fingerprint(self.home), before)
        self.assertFalse((self.root / 'captured.mbt').exists())

    def test_missing_staged_input_is_not_a_workspace_selection_conflict(self):
        sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
        import capture
        rows = [dict(domain='homebrew-packages', status='present',
                     items=[dict(item_id='fixture', _source='fixture')])]
        with self.assertRaises(capture.CaptureError) as failure:
            capture.prepared(self.stage, rows, dict(status='unavailable', items=[]),
                             dict(categories=['homebrew-packages'], items={}, secure_identities=[]))
        self.assertEqual(failure.exception.code, 'capture_inventory_invalid')

    def test_workspace_observation_failure_remains_non_selectable(self):
        # Malformed Git configuration is an observation error, not absence.
        self.workspace_fixture()
        (self.home / 'Projects/fixture-repo/.git/config').write_text('[broken\n')
        prepared = self.prepare()
        for domain in ('workspace-folders', 'git-repositories'):
            row = next(row for row in prepared['inventory'] if row['domain'] == domain)
            self.assertEqual(row['status'], 'observation_error')
            self.assertEqual(row['reason'], 'observation_failed')
            self.assertEqual(row['items'], [])
            result, events = self.invoke_capture(selection={
                'categories': [domain], 'items': {}, 'secure_identities': []})
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events[-1]['data']['code'], 'capture_source_unavailable')

    def test_topology_capture_full_partial_dependencies_and_restore_block(self):
        from workspace_fixture import linked
        self.workspace_fixture(duplicate=True)
        base = self.home / 'Projects/fixture-repo'
        oid = (base / '.git/refs/heads/main').read_text().strip()
        linked(base, self.home / 'Projects/feature', oid)
        (base / 'nested-folder').mkdir()
        self.environment['MACSEED_WORKSPACE_ROOTS'] = 'Projects/fixture-repo/nested-folder'
        before = bundle.fingerprint(self.home)
        inventory = self.prepare()
        row = next(row for row in inventory['inventory'] if row['domain'] == 'git-repositories')
        self.assertEqual(row['status'], 'present')
        self.assertEqual(len(row['items']), 3)
        contract = bundle.workspace_contract()
        base_id = contract.identity('checkout', 'Projects/fixture-repo')
        linked_id = contract.identity('checkout', 'Projects/feature')
        self.assertIn(linked_id, [item['item_id'] for item in row['items']])
        invalid = {'categories': [], 'items': {'git-repositories': [linked_id]}, 'secure_identities': []}
        result, events = self.invoke_capture(selection=invalid)
        self.assertEqual(result.returncode, 2, events)
        self.assertEqual(events[-1]['data']['code'], 'workspace_dependency_missing')
        nested = {'categories': [], 'items': {'workspace-folders': ['Projects/fixture-repo/nested-folder']},
                  'secure_identities': []}
        self.assertEqual(self.prepare(nested)['selection'], nested)
        partial = {'categories': [], 'items': {'git-repositories': [base_id, linked_id]}, 'secure_identities': []}
        full = {'categories': ['git-repositories'], 'items': {}, 'secure_identities': []}
        for count, selection in ((2, partial), (3, full)):
            prepared = self.prepare(selection)
            destination = self.root / f'topology-{count}.mbt'
            result, events = self.execute(prepared['prepared_capture_id'], selection, destination)
            self.assertEqual(result.returncode, 0, events)
            self.assertTrue(events[-2]['data']['publication_occurred'])
            files = bundle.validate_archive(destination)
            sections, _ = bundle.parse_blueprint(files['blueprint.conf'])
            self.assertEqual(len(sections['git-repositories']), count)
            self.assertEqual(bundle.validate_workspace(files, exact=True), {'workspace-topology': 1})
            self.assertNotIn(str(self.home).encode(), b''.join(files.values()))
            if count == 2:
                self.assertNotIn(b'Other/fixture-repo', b''.join(files.values()))
            target = self.root / f'restore-{count}'
            target.mkdir()
            with self.assertRaises(bundle.Unsupported):
                bundle.unpack(destination, target, str(self.home))
            self.assertFalse(list(target.iterdir()))
        self.assertEqual(bundle.fingerprint(self.home), before)
        self.assertFalse(Path(self.environment['TEST_MUTATIONS']).exists())

    def test_topology_git_capability_is_explicitly_unsupported(self):
        self.workspace_fixture()
        # Old Git advertises --porcelain but no -z. No line-parser fallback.
        git = self.root / 'bin/git'
        native_git = shutil.which('git')
        git.write_text('#!/bin/bash\ncase "$*" in\n'
                       ' --version) echo "git version 2.24.3" ;;\n'
                       ' "worktree list -h") echo "    --porcelain"; exit 129 ;;\n'
                       ' *) exec "' + native_git + '" "$@" ;;\nesac\n')
        git.chmod(0o700)
        prepared = self.prepare()
        row = next(row for row in prepared['inventory'] if row['domain'] == 'git-repositories')
        self.assertEqual(row['status'], 'unsupported')
        self.assertEqual(row['reason'], 'workspace_topology_unsupported')
        self.assertEqual(row['items'], [])

    def test_invalid_selection_and_unavailable_rejection(self):
        self.fixture()
        for selection in ([], {'categories': [], 'items': None, 'secure_identities': []},
                          {'categories': [], 'items': {'homebrew-packages': None}, 'secure_identities': []},
                          {'categories': ['unknown'], 'items': {}, 'secure_identities': []},
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
        path.write_text('#!/bin/bash\necho "The domain/default pair of ($2, $3) does not exist" >&2\nexit 1\n')
        path.chmod(0o700)
        prepared = self.prepare()
        self.assertNotIn('PRIVATE_IDENTITY', json.dumps(prepared))
        self.assertTrue(any(row['domain'] == 'git-configuration' and row['status'] == 'present' for row in prepared['inventory']))

    def test_macos27_optional_preferences_capture(self):
        self.fixture(real=True)
        (self.root / 'bin/sw_vers').write_text('#!/bin/bash\necho 27.2\n')
        defaults = self.root / 'bin/defaults'
        defaults.write_text('''#!/bin/bash
case "$3" in
 AppleShowAllExtensions|autohide|NSCloseAlwaysConfirmsChanges|Clicking)
  case "$1" in read-type) echo 'Type is boolean' ;; read) echo true ;; *) exit 2 ;; esac ;;
 KeyRepeat)
  case "$1" in read-type) echo 'Type is integer' ;; read) echo 6 ;; *) exit 2 ;; esac ;;
 *) domain="$2"; [[ "$domain" != NSGlobalDomain ]] || domain=kCFPreferencesAnyApplication
    echo "Error: Could not find key '$3' in domain '$domain'." >&2; exit 1 ;;
esac
''')
        defaults.chmod(0o700)
        prepared = self.prepare()
        rows = {row['domain']: row for row in prepared['inventory']}
        for category in ('finder', 'dock', 'windows', 'keyboard', 'trackpad'):
            self.assertEqual(rows['macos-' + category]['status'], 'present')
            self.assertEqual(len(rows['macos-' + category]['included_settings']), 1)
        self.assertEqual(rows['macos-screenshots']['status'], 'present')
        self.assertEqual(rows['macos-screenshots']['included_settings'], [{'id': 'location', 'label': 'Save location'}])

    def test_macos_metadata_does_not_change_prepared_identity(self):
        self.fixture()
        spec = importlib.util.spec_from_file_location('capture_metadata_fixture', self.project / 'modules/core/application-interface/capture.py')
        api = importlib.util.module_from_spec(spec)
        previous_path = sys.path[:]
        sys.path.insert(0, str(self.project / 'modules/core/application-interface'))
        try:
            spec.loader.exec_module(api)
        finally:
            sys.path[:] = previous_path
        bundle.write_file(self.stage / 'generated/macos/dock.conf', b'com.apple.dock|autohide|bool|true\n')
        rows = [{'domain': 'macos-dock', 'status': 'present', 'reason': None, 'selection_mode': 'category', 'items': []}]
        secure = {'status': 'unavailable', 'items': []}
        fingerprints = {str(path.relative_to(self.stage)): bundle.digest(bundle.checked_file(path))
                        for path in sorted((self.stage / 'generated').rglob('*')) if path.is_file()}
        legacy = {'schema': 1, 'inputs': fingerprints, 'inventory': rows, 'secure': secure, 'selection': None}
        expected = bundle.digest(json.dumps(legacy, sort_keys=True, separators=(',', ':')).encode())
        first, _, _ = api.prepared(self.stage, rows, secure, None)
        self.assertEqual(first['prepared_capture_id'], expected)
        definitions = self.project / 'modules/settings/macos/records.sh'
        definitions.write_text(definitions.read_text().replace('Auto-hide', 'Hide Dock automatically'))
        second, _, _ = api.prepared(self.stage, rows, secure, None)
        self.assertEqual(second['prepared_capture_id'], expected)
        self.assertEqual(second['inventory'][0]['included_settings'], [{'id': 'autohide', 'label': 'Hide Dock automatically'}])
        # Legacy readers retain the same status, item inventory and selection.
        legacy_row = {key: value for key, value in first['inventory'][0].items() if key != 'included_settings'}
        self.assertEqual(legacy_row, rows[0])

    def test_window_manager_included_settings_only_observed(self):
        self.fixture(real=True)
        settings = [('EnableStandardClickToShowDesktop', 'Click wallpaper to reveal Desktop'), ('EnableTilingByEdgeDrag', 'Tile windows by dragging to edges'), ('EnableTopTilingByEdgeDrag', 'Fill window by dragging to top'), ('EnableTiledWindowMargins', 'Tiled window margins')]
        defaults = self.root / 'bin/defaults'
        cases = '|'.join('"' + key + '"' for key, _ in settings)
        present = ('#!/bin/bash\nif [[ "$2" == com.apple.WindowManager ]]; then\n'
                   ' case "$3" in ' + cases + ')\n'
                   ' case "$1" in read-type) echo "Type is boolean"; exit 0 ;;'
                   ' read) echo false; exit 0 ;; esac ;; esac\nfi\n'
                   'echo "The domain/default pair of ($2, $3) does not exist" >&2; exit 1\n')
        defaults.write_text(present)
        defaults.chmod(0o700)
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'macos-windows')
        self.assertEqual(row['status'], 'present')
        self.assertEqual(row['included_settings'], [{'id': key, 'label': label} for key, label in settings])
        defaults.write_text('#!/bin/bash\necho "The domain/default pair of ($2, $3) does not exist" >&2; exit 1\n')
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'macos-windows')
        self.assertEqual((row['status'], row['included_settings']), ('unavailable', []))

    def test_macos_included_settings_are_effective_value_free_metadata(self):
        self.fixture(real=True)
        defaults = self.root / 'bin/defaults'
        defaults.write_text('''#!/bin/bash
case "$*" in
 "read-type NSGlobalDomain AppleShowAllExtensions"|"read-type com.apple.dock autohide"|"read-type com.apple.AppleMultitouchTrackpad Clicking"|"read-type com.apple.screencapture disable-shadow"|"read-type com.apple.screencapture show-thumbnail") echo 'Type is boolean' ;;
 "read-type com.apple.finder NewWindowTarget"|"read-type com.apple.dock orientation"|"read-type NSGlobalDomain AppleWindowTabbingMode"|"read-type com.apple.screencapture location") echo 'Type is string' ;;
 "read-type NSGlobalDomain KeyRepeat") echo 'Type is integer' ;;
 "read NSGlobalDomain AppleShowAllExtensions"|"read com.apple.dock autohide"|"read com.apple.AppleMultitouchTrackpad Clicking"|"read com.apple.screencapture disable-shadow") echo true ;;
 "read com.apple.screencapture show-thumbnail") echo false ;;
 "read com.apple.finder NewWindowTarget") echo PfLo ;;
 "read com.apple.dock orientation") echo unsupported-position ;;
 "read NSGlobalDomain AppleWindowTabbingMode") echo manual ;;
 "read NSGlobalDomain KeyRepeat") echo 6 ;;
 "read com.apple.screencapture location") echo "$HOME/PRIVATE_LOCATION" ;;
 *) echo "The domain/default pair of ($2, $3) does not exist" >&2; exit 1 ;;
esac
''')
        defaults.chmod(0o700)
        expected = {'macos-finder': ('AppleShowAllExtensions', 'Show extensions'),
                    'macos-dock': ('autohide', 'Auto-hide'),
                    'macos-windows': ('AppleWindowTabbingMode', 'Window tabbing'),
                    'macos-keyboard': ('KeyRepeat', 'Key repeat'),
                    'macos-trackpad': ('Clicking', 'Tap to click'),
                    'macos-screenshots': ('location', 'Save location')}
        prepared = self.prepare()
        for row in prepared['inventory']:
            if row['domain'] not in expected:
                self.assertNotIn('included_settings', row)
                continue
            identity, label = expected[row['domain']]
            settings = [{'id': identity, 'label': label}]
            if row['domain'] == 'macos-screenshots':
                settings += [{'id': 'disable-shadow', 'label': 'Window shadow'}, {'id': 'show-thumbnail', 'label': 'Floating thumbnail'}]
            self.assertEqual(row['included_settings'], settings)
            self.assertEqual(row['selection_mode'], 'category')
            self.assertEqual(row['items'], [])
            self.assertEqual(row['status'], 'present')
            if row['domain'] in ('macos-finder', 'macos-dock'):
                self.assertEqual(row['reason'], 'source_partial')
        self.assertNotIn('PRIVATE_LOCATION', json.dumps(prepared))
        self.assertNotIn('unsupported-position', json.dumps(prepared))
        selection = {'categories': sorted(expected), 'items': {}, 'secure_identities': []}
        selected = self.prepare(selection)
        self.assertEqual(selected['selection'], selection)
        self.assertEqual(selected['summary']['selected_items'], 0)
        # This real-discovery fixture executes a fresh scan plus validation.
        # CI #131 passed both Executes in 40.864 s total; #132 hit the former
        # 30 s per-operation bound. Keep the extra headroom local to this case.
        status, events = self.execute(selected['prepared_capture_id'], selection=selection, timeout=60)
        self.assertEqual(status.returncode, 0, events)
        self.assertTrue(events[-2]['data']['publication_occurred'])
        self.assertEqual(set(events[-2]['data']['bundle']['selected_categories']), set(expected))
        # A supported but absent preference must not enter Included Settings.
        present_defaults = defaults.read_text()
        for absent_keys in [('disable-shadow',), ('show-thumbnail',), ('disable-shadow', 'show-thumbnail')]:
            cases = '|'.join('"read-type com.apple.screencapture ' + key + '"' for key in absent_keys)
            defaults.write_text(present_defaults.replace('case "$*" in',
                'case "$*" in\n ' + cases + ') echo "The domain/default pair of ($2, $3) does not exist" >&2; exit 1 ;;', 1))
            row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'macos-screenshots')
            self.assertEqual(row['status'], 'present')
            self.assertEqual(row['included_settings'], [setting for setting in [
                {'id': 'location', 'label': 'Save location'},
                {'id': 'disable-shadow', 'label': 'Window shadow'},
                {'id': 'show-thumbnail', 'label': 'Floating thumbnail'}]
                if setting['id'] not in absent_keys])
        # A qualified implicit Desktop is a requirement even without native keys.
        defaults.write_text('#!/bin/bash\necho "The domain/default pair of ($2, $3) does not exist" >&2\nexit 1\n')
        for row in self.prepare()['inventory']:
            if row['domain'] in expected:
                if row['domain'] == 'macos-screenshots':
                    self.assertEqual(row['included_settings'], [{'id': 'location', 'label': 'Save location'}])
                    self.assertEqual(row['status'], 'present')
                else:
                    self.assertEqual(row['included_settings'], [])
                    self.assertEqual(row['status'], 'unavailable')
        selection = {'categories': ['macos-screenshots'], 'items': {}, 'secure_identities': []}
        prepared = self.prepare(selection)
        destination = self.root / 'desktop.mbt'
        status, events = self.execute(prepared['prepared_capture_id'], selection=selection, destination=destination, timeout=60)
        self.assertEqual(status.returncode, 0, events)
        self.assertEqual(bundle.validate_archive(destination)['generated/macos/screenshots.conf'],
                         b'com.apple.screencapture|location|string|~/Desktop\n')
        (self.root / 'bin/sw_vers').write_text('#!/bin/bash\necho 27.0\n')
        row = next(row for row in self.prepare()['inventory'] if row['domain'] == 'macos-screenshots')
        self.assertEqual(row['status'], 'present')
        self.assertEqual(row['included_settings'], [{'id': 'location', 'label': 'Save location'}])
        # A read failure is never the implicit Desktop on either native backend.
        defaults.write_text('#!/bin/bash\nexit 2\n')
        for version in ('26.7.1', '27.0'):
            (self.root / 'bin/sw_vers').write_text('#!/bin/bash\necho ' + version + '\n')
            for row in self.prepare()['inventory']:
                if row['domain'] in expected:
                    self.assertEqual(row['included_settings'], [])
                    self.assertEqual(row['status'], 'observation_error')

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
