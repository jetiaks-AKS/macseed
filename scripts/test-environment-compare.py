#!/usr/bin/env python3
"""Read-only Protocol V1 Compare through production readers on disposable Macs."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import time
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent


class CompareTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.project = self.root / 'project'
        self.project.mkdir()
        shutil.copytree(ROOT / 'modules', self.project / 'modules')
        shutil.copy2(ROOT / 'bootstrap.sh', self.project / 'bootstrap.sh')
        (self.project / 'config').mkdir()
        shutil.copy2(ROOT / 'config/toolkit.conf', self.project / 'config/toolkit.conf')
        self.generated = self.root / 'generated'
        self.generated.mkdir()
        self.home = self.root / 'home'
        self.home.mkdir()
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        self.mutations = self.root / 'mutations'
        self.mutations.write_text('')
        self.mock('brew', '''case "$*" in
'list --formula --full-name')
 case "$TEST_MODE" in missing) exit 0;; error) exit 2;; slow) echo $$ > "$TEST_PID"; exec sleep 30;; esac
 echo git;;
'list --cask') echo extra-app;;
'info --json=v2 --cask reference-app') echo '{"casks":[]}' ;;
*) echo "brew $*" >> "$TEST_MUTATIONS"; exit 99;; esac''')
        for name in ('sudo', 'defaults', 'killall', 'mas', 'code', 'curl', 'xcode-select'):
            self.mock(name, 'echo "$0 $*" >> "$TEST_MUTATIONS"; exit 99')
        self.temporary = self.root / 'temporary'
        self.temporary.mkdir()
        self.environment = dict(os.environ, TMPDIR=str(self.temporary), HOME=str(self.home), PATH=str(self.bin) + ':' + os.environ['PATH'],
                                TEST_MUTATIONS=str(self.mutations), TEST_MODE='matching', TEST_PID=str(self.root / 'pid'),
                                GIT_CONFIG_NOSYSTEM='1', XDG_CONFIG_HOME=str(self.home / '.config'))
        self.blueprint = self.root / 'blueprint.conf'
        self.write_blueprint()
        (self.generated / 'brew-packages.conf').write_text('git\n')

    def mock(self, name, body):
        path = self.bin / name
        path.write_text('#!/bin/bash\n' + body + '\n')
        path.chmod(0o700)

    def write_blueprint(self, categories=(), packages='git', casks=''):
        names = ('git-configuration', 'ssh-configuration', 'vscode-settings', 'shell-zsh',
                 'macos-finder', 'macos-dock', 'macos-windows', 'macos-keyboard', 'macos-trackpad', 'macos-screenshots')
        self.blueprint.write_text('[categories]\n' + ''.join(f'{name}="{str(name in categories).lower()}"\n' for name in names) +
                                  f'[homebrew-packages]\n{packages}\n[homebrew-casks]\n{casks}\n[app-store]\n[vscode-extensions]\n[workspace-folders]\n[git-repositories]\n')

    def payload(self, **overrides):
        parameters = {} if "bundle_path" in overrides else dict(generated_dir=str(self.generated), blueprint_path=str(self.blueprint))
        parameters.update(overrides)
        return json.dumps(dict(protocol_version=1, operation_id='compare-test', operation='environment_compare', parameters=parameters)).encode()

    def invoke(self, **overrides):
        before = self.snapshot()
        result = subprocess.run(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                input=self.payload(**overrides), env=self.environment, cwd=self.project,
                                capture_output=True, timeout=20)
        events = [json.loads(line) for line in result.stdout.splitlines()]
        self.assertEqual(sum(e['type'] in ('completed', 'failed', 'cancelled') for e in events), 1)
        self.assertEqual([e['sequence'] for e in events], list(range(1, len(events) + 1)))
        self.assertEqual(self.mutations.read_text(), '')
        self.assertEqual(before, self.snapshot())
        self.assertFalse((self.project / 'logs').exists())
        self.assertFalse(list(self.project.rglob('__pycache__')))
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])
        return result, events

    def snapshot(self):
        return {str(p.relative_to(self.root)): p.read_bytes() for base in (self.generated, self.home, self.project / 'config') for p in base.rglob('*') if p.is_file()}

    def comparison(self, **overrides):
        result, events = self.invoke(**overrides)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(events[-1]['type'], 'completed')
        self.assertTrue(any(e['type'] == 'execution_event' and e['data']['read_only'] for e in events))
        return next(e['data'] for e in events if e['type'] == 'result')

    def make_bundle(self, secure=False):
        stage = self.root / 'bundle-stage'
        if stage.exists(): shutil.rmtree(stage)
        stage.mkdir()
        shutil.copytree(self.generated, stage / 'generated')
        (stage / 'blueprint.conf').write_text(self.blueprint.read_text() + '[git-configuration]\n')
        if secure:
            (stage / 'secure.age').write_bytes(b'age-encryption.org/v1\nopaque encrypted fixture')
        output = self.root / 'saved.mbt'
        output.unlink(missing_ok=True)
        packed = subprocess.run([sys.executable, str(self.project / 'modules/bundle/bundle.py'), 'pack',
                                str(stage), str(output), str(self.home)], capture_output=True)
        self.assertEqual(packed.returncode, 0, packed.stderr.decode())
        return output

    def test_bundle_reference_selection_and_read_only(self):
        path = self.make_bundle(secure=True)
        data = self.comparison(bundle_path=str(path))
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertFalse(data['publication_occurred'])
        self.environment['TEST_MODE'] = 'missing'
        self.assertEqual(self.comparison(bundle_path=str(path))['comparison']['counts']['missing'], 1)
        self.environment['TEST_MODE'] = 'error'
        self.assertEqual(self.comparison(bundle_path=str(path))['comparison']['verdict'], 'incomplete')
        self.environment['TEST_MODE'] = 'matching'
        # Full inventory is not selected scope; retain completeness for extras.
        self.write_blueprint(packages='', casks='')
        inventory = self.generated / 'brew-casks.conf'
        inventory.write_text('reference-app\n')
        marker = self.generated / 'provenance/homebrew-casks.sha256'
        marker.parent.mkdir()
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertFalse(data['comparison_records'])
        self.assertFalse(any(r['domain'] == 'homebrew-casks' and r['disposition'] == 'resolved'
                             for r in data['records']['coverage_records']))
        self.assertEqual(data['extra']['items'], [])
        self.assertEqual(data['extra']['domains'][0]['reason'], 'category_excluded')
        self.write_blueprint(packages='', casks='reference-app')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['extra']['items'], [{'domain': 'homebrew-casks', 'item_id': 'extra-app'}])
        # Selected subset remains narrowed even with full source inventory.
        self.write_blueprint(packages='git')
        (self.generated / 'brew-packages.conf').write_text('git\nwget\n')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual([r['item_id'] for r in data['comparison_records']], ['git'])
        self.write_blueprint(categories=('vscode-settings',), packages='')
        (self.generated / 'vscode').mkdir()
        (self.generated / 'vscode/settings.json').write_text('{"secret":"reference-token"}')
        target = self.home / 'Library/Application Support/Code/User'
        target.mkdir(parents=True)
        (target / 'settings.json').write_text('{"secret":"current-token"}')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertNotIn('reference-token', json.dumps(data))

    def test_bundle_app_store_presentation_names(self):
        self.write_blueprint(packages='')
        self.blueprint.write_text(self.blueprint.read_text().replace('[app-store]\n', '[app-store]\n1136220934\n'))
        (self.generated / 'appstore.conf').write_text('1136220934|Infuse\n')
        self.mock('mas', '[[ "$*" == list ]] || exit 99; echo "1136220934 Infuse (8.0)"')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['reference_presentation']['app_store_names'], {'1136220934': 'Infuse'})
        self.assertEqual(data['comparison_records'][0]['item_id'], '1136220934')
        self.assertTrue(any(g['id'] == 'Applications' and 'app-store' in g['domains']
                            for g in data['reference_presentation']['groups']))

    def test_bundle_repository_display_labels_keep_diagnostics_private(self):
        self.write_blueprint(packages='')
        names = ['macseed', 'bootstrap-test', 'private/name']
        self.blueprint.write_text(self.blueprint.read_text().replace('[git-repositories]\n', '[git-repositories]\n' + '\n'.join(names) + '\n'))
        workspace = self.generated / 'workspace'
        workspace.mkdir()
        (workspace / 'repositories.conf').write_text(''.join(
            f'[{name}]\nNAME="{name}"\nPATH="{self.home}/Projects/{index}/same"\nREMOTE="https://example.invalid/repo.git"\nDEFAULT_BRANCH="main"\nCURRENT_BRANCH="main"\nHAS_UNCOMMITTED_CHANGES="false"\nHAS_VSCODE_FOLDER="false"\nHAS_SETTINGS="false"\nHAS_TASKS="false"\nHAS_LAUNCH="false"\nHAS_EXTENSIONS="false"\n'
            for index, name in enumerate(names)))
        data = self.comparison(bundle_path=str(self.make_bundle()))
        key = lambda name: 'opaque:' + hashlib.sha256(name.encode()).hexdigest()
        self.assertEqual(data['reference_presentation']['repository_labels'], {key(name): name for name in names[:2]})
        self.assertEqual(data['comparison']['counts']['missing'], 3)
        self.assertEqual(data['comparison']['counts']['unverified'], 6)
        self.assertEqual(data['comparison']['verdict'], 'differences_detected')
        self.assertEqual(len(data['comparison_records']), 9)
        raw = json.dumps({'records': data['records'], 'comparison_records': data['comparison_records']})
        for name in names: self.assertNotIn(name, raw)
        self.assertNotIn(str(self.home), json.dumps(data))
        self.assertTrue(all(row['item_id'].startswith('opaque:') for row in data['comparison_records']))

    def test_bundle_macos_labels_reuse_capture_definitions(self):
        self.write_blueprint(categories=('macos-dock',), packages='')
        directory = self.generated / 'macos'
        directory.mkdir()
        (directory / 'dock.conf').write_text('com.apple.dock|autohide|bool|true\ncom.apple.dock|magnification|bool|false\n')
        self.mock('defaults', '[[ "$1" == read ]] || exit 99; [[ "$3" == autohide ]] && echo 1 || echo 0')
        data = self.comparison(bundle_path=str(self.make_bundle()))
        self.assertEqual(data['reference_presentation']['setting_labels']['macos-dock'], {
            'com.apple.dock/autohide': 'Auto-hide', 'com.apple.dock/magnification': 'Magnification'})

    def test_bundle_invalid_unsafe_and_changed(self):
        path = self.make_bundle()
        for parameters in ({'bundle_path': 'relative'}, {'bundle_path': str(path), 'generated_dir': str(self.generated)}):
            result, events = self.invoke(**parameters)
            self.assertEqual(events[-1]['data']['code'], 'invalid_request')
        alias = self.root / 'alias.mbt'
        alias.symlink_to(path)
        self.assertEqual(self.invoke(bundle_path=str(alias))[1][-1]['data']['code'], 'bundle_invalid')
        self.assertEqual(self.invoke(bundle_path=str(self.root / 'absent.mbt'))[1][-1]['data']['code'], 'bundle_unavailable')
        path.write_bytes(b'corrupted archive')
        self.assertEqual(self.invoke(bundle_path=str(path))[1][-1]['data']['code'], 'bundle_invalid')
        # Mutation of the reference during observation cannot publish a clean result.
        path = self.make_bundle()
        self.environment['TEST_BUNDLE'] = str(path)
        self.mock('brew', 'echo changed >> "$TEST_BUNDLE"; echo git')
        result, events = self.invoke(bundle_path=str(path))
        self.assertEqual(events[-1]['data']['code'], 'reference_changed')
        self.assertFalse(any(e['type'] == 'result' for e in events))

    def test_bundle_cancellation_cleanup(self):
        path = self.make_bundle()
        original = self.payload
        self.payload = lambda **kwargs: original(bundle_path=str(path))
        before = path.read_bytes()
        self.test_cancellation_owned_group()
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])
        self.environment['TEST_MODE'] = 'matching'
        self.comparison(bundle_path=str(path))

    def test_cancel_during_bundle_validation(self):
        path = self.make_bundle()
        before = path.read_bytes()
        adapter = self.project / 'modules/core/application-interface/core.py'
        original = adapter.read_text()
        for boundary in ('                bundle.inspect_bundle(source, os.environ["HOME"])',
                         '                bundle.unpack(source, stage, os.environ["HOME"])'):
            partial_stage = '                (stage / "partial-fixture").write_bytes(b"fixture")\n' if 'unpack' in boundary else ''
            adapter.write_text(original.replace(boundary,
                partial_stage + '                os.kill(os.getpid(), signal.SIGTERM)\n' + boundary))
            result, events = self.invoke(bundle_path=str(path))
            self.assertEqual(result.returncode, 130)
            self.assertEqual(events[-1]['type'], 'cancelled')
            self.assertEqual(path.read_bytes(), before)
        adapter.write_text(original)
        self.comparison(bundle_path=str(path))

    def test_cancel_cleanup_error_is_not_bundle_unavailable(self):
        path = self.make_bundle()
        before = path.read_bytes()
        execution = self.project / 'modules/core/application-interface/execution.py'
        original = execution.read_text()
        # Fault only after the owned readers have been stopped and collected.
        execution.write_text(original.replace('        self._collect()\n        return 130',
            '        self._collect()\n        raise FileNotFoundError(2, "fixture staging vanished", self.item_state.name)\n        return 130'))
        payload = self.payload
        self.payload = lambda **kwargs: payload(bundle_path=str(path))
        self.test_cancellation_owned_group(expected_code='comparison_unavailable')
        self.assertEqual(path.read_bytes(), before)
        self.assertEqual(list(self.temporary.glob("macseed-compare-*")), [])

    def deny_compare_descendant_kill(self):
        execution = self.project / 'modules/core/application-interface/execution.py'
        original = execution.read_text()
        boundary = '                os.killpg(self.process.pid, signal.SIGKILL)'
        self.assertIn(boundary, original)
        execution.write_text(original.replace(boundary,
            '                raise PermissionError(1, "fixture descendant stop denied")', 1))

    def test_cancel_descendant_kill_denied(self):
        self.deny_compare_descendant_kill()
        self.test_cancellation_owned_group()

    def test_cancel_does_not_hide_source_error(self):
        self.deny_compare_descendant_kill()
        path = self.make_bundle()
        execution = self.project / 'modules/core/application-interface/execution.py'
        original = execution.read_text()
        execution.write_text(original.replace('        self._collect()\n        return 130',
            '        self._collect()\n        from pathlib import Path\n        source = Path(' + repr(str(path)) + ')\n        source.unlink()\n        source.read_bytes()\n        return 130'))
        payload = self.payload
        self.payload = lambda **kwargs: payload(bundle_path=str(path))
        self.test_cancellation_owned_group(expected_code='bundle_unavailable')

    def test_matching_and_projections(self):
        data = self.comparison()
        self.assertTrue(data['read_only'])
        self.assertFalse(data['target_mutation_may_have_started'])
        self.assertEqual(data['comparison']['counts']['matching'], 1)
        self.assertEqual(data['comparison']['verdict'], 'no_differences_detected')
        self.assertEqual(data['comparison_records'][0]['comparison_kind'], 'matching')
        self.assertIsNone(data['comparison_records'][0]['reason'])
        self.assertEqual(data['records']['verification_records'][0]['conformity'], 'verified')
        self.assertEqual(data['verification']['verdict'], 'selected_requirements_verified')
        self.assertEqual({r['disposition'] for r in data['records']['coverage_records']}, {'resolved', 'excluded'})
        self.assertFalse(data['records']['operation_records'])

    def test_missing(self):
        self.environment['TEST_MODE'] = 'missing'
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['missing'], 1)
        self.assertEqual(data['comparison_records'][0]['reason'], 'confirmed_mismatch')
        self.assertEqual(data['comparison']['verdict'], 'differences_detected')
        self.assertEqual(data['verification']['mismatch_count'], 1)

    def test_differing_and_sensitive_contents(self):
        self.write_blueprint(categories=('vscode-settings',))
        (self.generated / 'vscode').mkdir()
        (self.generated / 'vscode/settings.json').write_text('{"secret":"reference-token"}')
        target = self.home / 'Library/Application Support/Code/User'
        target.mkdir(parents=True)
        (target / 'settings.json').write_text('{"secret":"current-token"}')
        data = self.comparison()
        row = next(r for r in data['comparison_records'] if r['domain'] == 'vscode-settings')
        self.assertEqual(row['comparison_kind'], 'differing')
        self.assertEqual(data['comparison']['counts']['differing'], 1)
        self.assertNotIn('reference-token', json.dumps(data))
        self.assertNotIn('current-token', json.dumps(data))
        self.assertNotIn(str(self.root), json.dumps(data))

    def test_observation_failure_is_unverified(self):
        self.environment['TEST_MODE'] = 'error'
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unverified'], 1)
        self.assertEqual(data['comparison_records'][0]['reason'], 'observation_failed')
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertEqual(data['verification']['status'], 'complete')

    def test_unresolved_selection(self):
        self.write_blueprint(packages='unknown')
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unresolved'], 1)
        self.assertEqual(data['records']['coverage_records'][0]['disposition'], 'unresolved')
        self.assertEqual(data['records']['diagnostics'][0]['code'], 'selected_input_unresolved')

    def test_invalid_reference(self):
        self.blueprint.write_text('malformed!\n')
        result, events = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_invalid')
        self.assertEqual(events[-1]['data']['comparison']['status'], 'incomplete')

    def test_invalid_domain_input(self):
        (self.generated / 'brew-packages.conf').write_text('invalid value!\n')
        result, events = self.invoke()
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'reference_invalid')

    def test_unavailable_and_request_validation(self):
        for overrides, code in (({'generated_dir': str(self.root / 'absent')}, 'reference_unavailable'),
                                ({'blueprint_path': str(self.root / 'absent')}, 'reference_unavailable'),
                                ({'generated_dir': 'relative'}, 'invalid_request')):
            with self.subTest(overrides=overrides):
                result, events = self.invoke(**overrides)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(events[-1]['data']['code'], code)

    def test_extra_provenance(self):
        self.write_blueprint(packages='', casks='stale')
        inventory = self.generated / 'brew-casks.conf'
        inventory.write_text('reference-app\n')
        data = self.comparison()
        self.assertEqual(data['extra']['domains'][0]['status'], 'unavailable')
        provenance = self.generated / 'provenance'
        provenance.mkdir()
        marker = provenance / 'homebrew-casks.sha256'
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        data = self.comparison()
        self.assertEqual(data['extra']['items'], [{'domain': 'homebrew-casks', 'item_id': 'extra-app'}])
        self.assertEqual(data['comparison']['counts']['extra'], 1)
        marker.write_text('complete ' + '0' * 64 + '\n')
        self.assertEqual(self.comparison()['extra']['items'], [])
        marker.write_text('complete ' + hashlib.sha256(inventory.read_bytes()).hexdigest() + '\n')
        self.mock('brew', 'echo "invalid inventory value"')
        data = self.comparison()
        self.assertEqual(data['extra']['items'], [])
        self.assertEqual(data['extra']['domains'][0]['reason'], 'invalid_target_inventory')

    def test_determinism_and_bounds(self):
        first = self.comparison()
        second = self.comparison()
        for data in (first, second):
            for row in data['records']['verification_records']:
                row.pop('observed_at')
        self.assertEqual(first, second)
        sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
        from execution import OwnedBootstrap
        from reporting import MAX_RECORDS, item
        self.assertTrue(item('git-repositories', 'https://user:token@server/private').startswith('opaque:'))
        owned = OwnedBootstrap.__new__(OwnedBootstrap)
        owned.mode = '--application-compare'
        owned.report_count = MAX_RECORDS
        owned.details = {'status': 'partial'}
        owned.comparison_records = []
        owned._record({'kind': 'comparison', 'domain': 'homebrew-packages', 'item_id': 'git'})
        self.assertEqual(owned.details['status'], 'truncated')
        self.assertEqual(owned.comparison_records, [])

    def test_invalid_and_truncated_reporting_fails_closed(self):
        entry = self.project / 'bootstrap.sh'
        for kind in ('invalid', 'truncated'):
            entry.write_text("#!/usr/bin/env python3\n" + """
import json, os
fd = int(os.environ['MACSEED_REPORT_FD'])
def write(row):
    os.write(fd, (json.dumps(row) + '\\n').encode())
""" + ("write({'kind': 'comparison', 'unexpected': 'raw secret'})\n" if kind == 'invalid' else """
for i in range(8193):
    write({'kind': 'coverage', 'record_id': 'c:' + str(i), 'domain': 'homebrew-packages',
           'item_id': 'git', 'disposition': 'resolved', 'source_status': 'unknown'})
""") + "write({'kind': 'details_complete'})\n")
            result, events = self.invoke()
            self.assertEqual(result.returncode, 2)
            self.assertEqual(events[-1]['data']['code'], 'comparison_reporting_incomplete')
            self.assertEqual(events[-1]['data']['records']['status'], kind)
            self.assertNotIn('raw secret', result.stdout.decode())
            self.assertLessEqual(len(events[-1]['data']['records']['coverage_records']), 8192)

    def test_cancellation_owned_group(self, expected_code=None):
        self.environment['TEST_MODE'] = 'slow'
        process = subprocess.Popen(['bash', str(self.project / 'modules/core/application-interface/core.sh')],
                                   stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   env=self.environment, cwd=self.project, start_new_session=True)
        process.stdin.write(self.payload())
        process.stdin.close()
        process.stdin = None
        pid_file = self.root / 'pid'
        deadline = time.monotonic() + 10
        while not pid_file.exists() and time.monotonic() < deadline:
            time.sleep(.05)
        self.assertTrue(pid_file.exists())
        os.killpg(process.pid, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(process.returncode, 2 if expected_code else 130, stderr)
        events = [json.loads(line) for line in stdout.splitlines()]
        self.assertEqual(sum(e['type'] in ('completed', 'failed', 'cancelled') for e in events), 1)
        self.assertEqual(events[-1]['type'], 'failed' if expected_code else 'cancelled')
        if expected_code:
            self.assertEqual(events[-1]['data']['code'], expected_code)
        pid = int(pid_file.read_text())
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                break
            time.sleep(.05)
        else:
            self.fail('Owned reader survived cancellation')
        self.assertEqual(self.mutations.read_text(), '')

    def test_cancellation_stops_term_ignoring_grandchild(self):
        code = ("import os, signal, time; from pathlib import Path; "
                "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
                "Path(os.environ['TEST_PID']).write_text(str(os.getpid())); time.sleep(30)")
        path = self.bin / 'brew'
        path.write_text('#!/usr/bin/env python3\nimport subprocess, sys\n' +
                        'child = subprocess.Popen([sys.executable, "-c", ' + repr(code) + '])\nchild.wait()\n')
        self.test_cancellation_owned_group()

    def test_production_operation_support_and_unknown_difference(self):
        entry = self.project / 'bootstrap.sh'
        marker = 'source modules/verification/comparison.sh\n'
        entry.write_text(entry.read_text().replace(marker, marker + """
verify_brew_packages() {
    verification_coverage homebrew-packages git resolved unknown
    verification_operation homebrew-packages git inspect success
    verification_record homebrew-packages git installed mismatch supported '2026-10-01T00:00:00Z'
    verification_diagnostic "$GV_LAST_REF" confirmed_mismatch warning observation
    verification_unsupported homebrew-packages other unsupported_fixture
    verification_coverage homebrew-packages empty no_requirement observed_absent
}
"""))
        data = self.comparison()
        self.assertEqual(data['comparison']['counts']['unknown_difference'], 1)
        self.assertEqual(data['comparison']['counts']['unsupported'], 1)
        self.assertEqual(data['comparison']['counts']['unverified'], 2)
        self.assertEqual({r['reason'] for r in data['comparison_records']}, {'unknown_difference', 'unsupported_predicate'})
        self.assertEqual(data['records']['operation_records'][0]['outcome'], 'success')
        self.assertEqual(data['verification']['verdict'], 'differences_detected')
        self.assertEqual(data['comparison']['verdict'], 'incomplete')
        self.assertIn('no_requirement', {r['disposition'] for r in data['records']['coverage_records']})

    def test_git_identity_privacy(self):
        self.write_blueprint(categories=('git-configuration',), packages='')
        (self.generated / 'git.conf').write_text('[user]\nname = Private Reference\nemail = private-reference@example.invalid\n')
        (self.home / '.gitconfig').write_text('[user]\nname = Private Target\nemail = private-target@example.invalid\n')
        data = self.comparison()
        raw = json.dumps(data)
        for forbidden in ('Private Reference', 'Private Target', 'private-reference', 'private-target', str(self.root)):
            self.assertNotIn(forbidden, raw)
        self.assertEqual(data['comparison']['counts']['differing'], 2)

    def test_empty_scope_and_explicit_no_blueprint(self):
        self.write_blueprint(packages='')
        self.assertEqual(self.comparison()['comparison']['verdict'], 'no_comparable_requirements')
        # An ambient Blueprint cannot substitute for explicit null.
        self.environment['BLUEPRINT_FILE'] = str(self.blueprint)
        (self.project / 'config/blueprint.conf').write_text('malformed ambient blueprint!')
        result, events = self.invoke(blueprint_path=None)
        self.assertFalse(any(e.get('data', {}).get('code') == 'reference_invalid' and
                             any(r['domain'] == 'blueprint' for r in e['data'].get('records', {}).get('coverage_records', [])) for e in events))
        self.assertTrue(any(r['domain'] == 'homebrew-packages' for e in events if e['type'] == 'result'
                            for r in e['data']['comparison_records']))

    def test_cli_compatibility(self):
        self.environment.update(BLUEPRINT_FILE=str(self.blueprint), BLUEPRINT_GENERATED_DIR=str(self.generated))
        result = subprocess.run(['./bootstrap.sh', '--compare'], cwd=self.project, env=self.environment, capture_output=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(b'No differences detected', result.stdout)
        self.assertIn(b'Matching: 1; missing: 0; differing: 0; unverified: 0', result.stdout)
        self.assertNotIn(b'comparison_records', result.stdout)
        self.assertEqual(self.mutations.read_text(), '')


if __name__ == '__main__':
    unittest.main()
