#!/usr/bin/env python3
"""Focused additive V1 selection tests; production preparation, no real user state."""
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / 'modules/bundle'))
sys.path.insert(0, str(ROOT / 'modules/core/application-interface'))
import bundle
import restore_selection as selection_api
spec = importlib.util.spec_from_file_location('restore_fixture', ROOT / 'scripts/test-restore-prepare.py')
fixture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fixture)


class SelectionTests(unittest.TestCase):
    def setUp(self):
        self.fixture = fixture.RestorePrepareTests()
        self.fixture.setUp()
        self.addCleanup(self.fixture.doCleanups)
        self.stage = self.fixture.stage

    def inspect(self):
        request = dict(protocol_version=1, operation_id='selection-inspect', operation='bundle_inspect', parameters=dict(path=str(self.fixture.archive)))
        result = subprocess.run(['bash', str(self.fixture.project / 'modules/core/application-interface/core.sh')],
                                input=json.dumps(request).encode(), env=self.fixture.environment, cwd=self.fixture.project, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout)
        return json.loads(result.stdout.splitlines()[-2])['data']

    def prepare(self, selection=None):
        result, events = self.fixture.invoke(selection=selection)
        self.assertEqual(result.returncode, 0, events)
        return events[-2]['data']

    def ssh_fixture(self, *, version=1, partial=False, secure=False):
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('ssh-configuration="false"', 'ssh-configuration="true"')
                             .replace('Projects\n', ''))
        self.ssh_source = self.stage / 'generated/ssh/config.snapshot'
        self.ssh_payload = b'Host github\n    HostName github.invalid\n    User git\nHost production\n    HostName production.invalid\n'
        if version == 2:
            self.ssh_payload += b'    IdentityFile /old-home/deploy\n    IdentitiesOnly yes\n'
        bundle.write_file(self.ssh_source, (f'# toolkit-ssh-snapshot: {version}\n# status: {"partial" if partial else "ready"}\n'
                                         f'# excluded-profiles: {1 if partial else 0}\n\n').encode() + self.ssh_payload)
        self.fixture.pack(secure=secure)
        row = next(row for row in self.inspect()['restore_selection']['inventory'] if row['domain'] == 'ssh-configuration')
        self.assertEqual(row['selection_mode'], 'items')
        self.assertEqual([item['label'] for item in row['items']], ['github', 'production'])
        self.ssh_ids = [item['item_id'] for item in row['items']]
        return self.fixture.home / '.ssh/config'

    def ssh_selection(self, indexes=(0,)):
        return dict(categories=[], items={'ssh-configuration': sorted(self.ssh_ids[index] for index in indexes)})

    def test_ssh_subset_execute_verify_noop_and_unselected_conflict(self):
        target = self.ssh_fixture()
        self.fixture.allow_application_bootstrap()
        target.parent.mkdir(mode=0o700)
        original = b'# preserve unrelated bytes\nHost production\n HostName different.invalid\nHost unrelated\n HostName unrelated.invalid\n'
        target.write_bytes(original); target.chmod(0o600)
        full = self.prepare(dict(categories=['ssh-configuration'], items={}))
        self.assertFalse(full['readiness']['ready'])
        chosen = self.ssh_selection()
        prepared = self.prepare(chosen)
        self.assertTrue(prepared['readiness']['ready'], prepared)
        self.assertEqual(prepared['selection'], chosen)
        self.assertEqual(prepared['selected_item_counts']['ssh-configuration'], 1)
        self.assertTrue(any(row['domain'] == 'ssh-configuration' and row['disposition'] == 'planned' for row in prepared['plan']))
        result, events = self.fixture.execute(prepared['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(target.read_bytes(), original + b'Host github\n    HostName github.invalid\n    User git\n')
        published = self.fixture.project / 'config/generated/ssh/config.snapshot'
        self.assertEqual(list(bundle.ssh_snapshot(published.read_bytes())[3]), ['github'])
        self.assertEqual(events[-2]['data']['verification']['verdict'], 'selected_requirements_verified')
        before = target.stat()
        retained = list(target.parent.glob('.macseed-ssh-predecessor-*'))
        self.assertEqual(len(retained), 1)
        repeated = self.prepare(chosen)
        self.assertTrue(repeated['readiness']['ready'])
        self.assertFalse(any(row['disposition'] == 'planned' for row in repeated['plan']))
        result, events = self.fixture.execute(repeated['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual((target.stat().st_ino, target.stat().st_mtime_ns), (before.st_ino, before.st_mtime_ns))
        self.assertEqual(list(target.parent.glob('.macseed-ssh-predecessor-*')), retained)

    def test_ssh_full_legacy_empty_and_independent_secure_selection(self):
        target = self.ssh_fixture(secure=True)
        explicit = self.prepare(self.ssh_selection((0, 1)))
        legacy = self.prepare(dict(categories=['ssh-configuration'], items={}))
        implicit = self.prepare()
        self.assertEqual(explicit['selection'], self.ssh_selection((0, 1)))
        self.assertEqual(explicit['prepared_plan_id'], legacy['prepared_plan_id'])
        self.assertEqual(explicit['selection'], implicit['selection'])
        self.assertEqual(explicit['plan'], implicit['plan'])
        self.assertFalse(explicit['include_secure'])
        result, events = self.fixture.invoke(secure=True, selection=self.ssh_selection())
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue(events[-2]['data']['include_secure'])
        self.assertEqual(events[-2]['data']['selection'], self.ssh_selection())
        for empty in (dict(categories=[], items={}), self.ssh_selection(())):
            plan = self.prepare(empty)
            self.assertEqual(plan['selection'], dict(categories=[], items={}))
            self.assertEqual(plan['plan'], [])
            self.assertFalse(plan['include_secure'])
        self.fixture.allow_application_bootstrap()
        result, events = self.fixture.execute(explicit['prepared_plan_id'], selection=self.ssh_selection((0, 1)))
        self.assertEqual(result.returncode, 0, events)
        self.assertEqual(target.read_bytes(), self.ssh_payload)
        self.assertFalse((self.fixture.project / 'config/generated/secure.age').exists())

    def test_ssh_selection_stale_ids_bundle_and_target_bindings(self):
        target = self.ssh_fixture()
        chosen = self.ssh_selection()
        plan = self.prepare(chosen)
        for invalid in ('unknown', self.ssh_ids[0].upper()):
            result, events = self.fixture.invoke(selection=dict(categories=[], items={'ssh-configuration': [invalid]}))
            self.assertEqual(result.returncode, 2, events)
            self.assertEqual(events[-1]['data']['code'], 'invalid_selection')
        for changed in (self.ssh_selection((1,)), dict(categories=['ssh-configuration'], items={}), self.ssh_selection(())):
            result, events = self.fixture.execute(plan['prepared_plan_id'], selection=changed)
            self.assertEqual(events[-1]['data']['code'], 'stale_plan')
            self.assertFalse(events[-1]['data']['publication_started'])
        self.fixture.archive.unlink()
        self.ssh_source.write_bytes(self.ssh_source.read_bytes().replace(b'production.invalid', b'changed.invalid'))
        self.fixture.pack()
        result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])
        fresh = self.prepare(chosen)
        target.parent.mkdir(mode=0o700)
        target.write_bytes(b'Host unrelated\n HostName unrelated.invalid\n'); target.chmod(0o600)
        result, events = self.fixture.execute(fresh['prepared_plan_id'], selection=chosen)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse((self.fixture.project / 'config/generated').exists())

    def test_ssh_subset_conflicts_and_ambiguous_target_remain_blocked(self):
        target = self.ssh_fixture()
        target.parent.mkdir(mode=0o700)
        for raw in (b'Host github\n HostName conflicting.invalid\n',
                    b'Host GITHUB\n HostName github.invalid\n',
                    b'Host github\n HostName github.invalid\n ProxyCommand forbidden\n',
                    b'Host unrelated\n HostName unrelated.invalid\n Compression yes\n',
                    b'Host github\n HostName github.invalid\nHost GITHUB\n HostName github.invalid\n'):
            with self.subTest(raw=raw):
                target.write_bytes(raw); target.chmod(0o600)
                plan = self.prepare(self.ssh_selection())
                self.assertFalse(plan['readiness']['ready'], plan)
                result, events = self.fixture.execute(plan['prepared_plan_id'], selection=self.ssh_selection())
                self.assertEqual(result.returncode, 2, events)
                self.assertFalse(events[-1]['data']['publication_started'])
                self.assertEqual(target.read_bytes(), raw)

    def test_ssh_subset_v2_never_downgrades_or_resolves_identity(self):
        target = self.ssh_fixture(version=2)
        for chosen in (self.ssh_selection(), self.ssh_selection((1,))):
            plan = self.prepare(chosen)
            self.assertFalse(plan['readiness']['ready'], plan)
            self.assertTrue(any(row['reason'] == 'extended_ssh_read_only' for row in plan['plan']))
            unresolved = any(row['reason'] == 'identity_dependencies_unresolved' for row in plan['plan'])
            self.assertEqual(unresolved, chosen == self.ssh_selection((1,)))
            result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
            self.assertEqual(result.returncode, 2, events)
            self.assertFalse(events[-1]['data']['publication_started'])
        self.assertFalse(target.exists())
        # A subset cannot erase ambiguous source syntax or its v2 capability.
        files = bundle.validate_archive(self.fixture.archive)
        self.assertEqual(bundle.validate_ssh(files), {'ssh-configuration': 2})
        files['generated/ssh/config.snapshot'] += b'Host GITHUB\n    HostName ambiguous.invalid\n'
        with self.assertRaises(bundle.Invalid):
            selection_api.inventory(files)

    def test_ssh_subset_preserves_partial_coverage_and_independent_categories(self):
        target = self.ssh_fixture(partial=True)
        target.parent.mkdir(mode=0o700)
        target.write_bytes(b'Host unrelated\n HostName unrelated.invalid\n'); target.chmod(0o600)
        plan = self.prepare(self.ssh_selection())
        self.assertFalse(plan['readiness']['ready'])
        self.assertTrue(any(row['reason'] == 'partial_source_coverage' for row in plan['plan']))
        # Narrow only private staged SSH data; flags for independent categories survive.
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[workspace-folders]\n', '[workspace-folders]\nProjects\n'))
        self.fixture.archive.unlink()
        self.fixture.pack()
        chosen = dict(categories=['workspace-folders'], items={'ssh-configuration': []})
        plan = self.prepare(chosen)
        self.assertTrue(plan['readiness']['ready'])
        self.assertFalse(any(row['domain'] == 'ssh-configuration' for row in plan['plan']))
        original, before = target.read_bytes(), target.stat()
        self.fixture.allow_application_bootstrap()
        result, events = self.fixture.execute(plan['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue((self.fixture.home / 'Projects').is_dir())
        self.assertEqual(target.read_bytes(), original)
        self.assertEqual((target.stat().st_ino, target.stat().st_mtime_ns), (before.st_ino, before.st_mtime_ns))
        self.assertEqual(list(target.parent.iterdir()), [target])
        sections, categories = bundle.parse_blueprint((self.fixture.project / 'config/blueprint.conf').read_bytes())
        self.assertFalse(categories['ssh-configuration'])
        self.assertEqual(sections['workspace-folders'], ['Projects'])
        records = events[-2]['data']['verification']['details']['verification_records']
        self.assertFalse(any(row['domain'] == 'ssh-configuration' for row in records))

    def test_homebrew_token_labels_from_saved_bundle_keep_identity_and_privacy(self):
        tokens = {'homebrew-casks': ['thaw@beta'],
                  'homebrew-packages': ['openssl@3', 'libsigc++', 'owner/tap/formula@2+extra']}
        blueprint = self.stage / 'blueprint.conf'
        raw = blueprint.read_text()
        for domain, values in tokens.items():
            raw = raw.replace('[' + domain + ']\n', '[' + domain + ']\n' + '\n'.join(values) + '\n')
            bundle.write_file(self.stage / 'generated' / bundle.ITEMS[domain], ('\n'.join(values) + '\n').encode())
        blueprint.write_text(raw)
        self.fixture.pack()
        before = self.fixture.archive.read_bytes()
        rows = {row['domain']: row for row in self.inspect()['restore_selection']['inventory']}
        for domain, values in tokens.items():
            self.assertEqual(rows[domain]['items'], [
                {'item_id': selection_api.identity(domain, value), 'label': value} for value in values])
            for unsafe in ('https://user:SECRET@example.test/app', 'user:SECRET@host',
                           '/Users/private/app', '~/private/app', '../private/app',
                           'folder/app', 'owner/tap/path/app', '--option', 'app.rb', 'app\nsecret'):
                self.assertEqual(selection_api.label(unsafe, domain), 'Private item')
        self.assertEqual(selection_api.label('owner/tap/app', 'homebrew-casks'), 'Private item')
        for domain in set(selection_api.LABELS) - set(tokens):
            for value in ('thaw@beta', 'openssl@3', 'libsigc++', 'https://user:SECRET@example.test/app'):
                self.assertEqual(selection_api.label(value, domain), 'Private item')
        self.assertEqual(self.fixture.archive.read_bytes(), before)

    def test_protocol_inventory_prepare_binding_and_stale_execute(self):
        blueprint = self.stage / 'blueprint.conf'
        blueprint.write_text(blueprint.read_text().replace('[workspace-folders]\nProjects\n', '[workspace-folders]\nProjects\nOther\n'))
        (self.stage / 'generated/workspace/folders.conf').write_bytes(b'Projects|workspace\nOther|workspace\n')
        self.fixture.pack()
        before = self.fixture.archive.read_bytes()
        data = self.inspect()
        self.assertEqual(data['restore_selection']['groups'], [{'id': k, 'domains': list(v)} for k, v in bundle.GROUPS.items()])
        rows = {row['domain']: row for row in data['restore_selection']['inventory']}
        items = rows['workspace-folders']['items']
        legacy = self.prepare()
        chosen = {'categories': [], 'items': {'workspace-folders': [items[1]['item_id']]}}
        prepared = self.prepare(chosen)
        self.assertEqual(prepared['selection'], chosen)
        self.assertEqual(prepared['selected_item_counts']['workspace-folders'], 1)
        self.assertEqual(prepared['plan'][0]['selection_item_id'], items[1]['item_id'])
        self.assertEqual(prepared['plan'][0]['item_id'], 'Other')
        self.assertNotEqual(prepared['prepared_plan_id'], legacy['prepared_plan_id'])
        mismatched = {'categories': [], 'items': {'workspace-folders': [items[0]['item_id']]}}
        result, events = self.fixture.execute(prepared['prepared_plan_id'], selection=mismatched)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'stale_plan')
        self.assertFalse(events[-1]['data']['publication_started'])
        self.assertFalse(events[-1]['data']['target_mutation_may_have_started'])
        self.assertFalse((self.fixture.home / 'Projects').exists())
        self.assertFalse((self.fixture.home / 'Other').exists())
        self.assertFalse((self.fixture.project / 'config/generated').exists())
        self.assertEqual(self.fixture.archive.read_bytes(), before)
        empty = self.prepare({'categories': [], 'items': {}})
        self.assertFalse(empty['selected_groups'])
        self.assertFalse(empty['plan'])
        self.assertEqual(self.prepare()['prepared_plan_id'], legacy['prepared_plan_id'])
        self.fixture.allow_application_bootstrap()
        result, events = self.fixture.execute(prepared['prepared_plan_id'], selection=chosen)
        self.assertEqual(result.returncode, 0, events)
        self.assertTrue((self.fixture.home / 'Other').is_dir())
        self.assertFalse((self.fixture.home / 'Projects').exists())
        self.assertEqual(self.fixture.archive.read_bytes(), before)

    def test_invalid_and_disabled_requests(self):
        self.fixture.pack()
        rows = {r['domain']: r for r in self.inspect()['restore_selection']['inventory']}
        item = rows['workspace-folders']['items'][0]['item_id']
        for selection in [False, {}, {'categories': ['missing'], 'items': {}},
                          {'categories': ['workspace-folders'] * 2, 'items': {}},
                          {'categories': ['workspace-folders'], 'items': {'workspace-folders': [item]}},
                          {'categories': [], 'items': {'workspace-folders': [item, item]}},
                          {'categories': [], 'items': {'workspace-folders': ['unknown']}},
                          {'categories': [], 'items': {'macos-dock': [item]}},
                          {'categories': ['macos-dock'], 'items': {}},
                          {'categories': [], 'items': {'workspace-folders': []}}]:
            result, events = self.fixture.invoke(selection=selection)
            self.assertEqual(result.returncode, 2, selection)
            self.assertEqual(events[-1]['data']['code'], 'invalid_selection')
        result, events = self.fixture.invoke(groups=['Workspace'], selection={'categories': ['workspace-folders'], 'items': {}})
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events[-1]['data']['code'], 'invalid_selection')

    def populated(self):
        flags = {name: True for name in bundle.CATEGORY_FLAGS}
        sections = {name: ['first', 'second'] for name in bundle.ITEMS}
        sections['git-configuration'] = ['user.name', 'user.email']
        raw = '[categories]\n' + ''.join(f'{k}="true"\n' for k in flags)
        raw += ''.join('\n[' + k + ']\n' + '\n'.join(v) + '\n' for k, v in sections.items())
        (self.stage / 'blueprint.conf').write_bytes(raw.encode())
        for name, path in bundle.ITEMS.items():
            target = self.stage / 'generated' / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes( b'first|workspace\nsecond|workspace\n' if name == 'workspace-folders' else b'PRIVATE_VALUE')
        for path in bundle.CATEGORIES.values():
            target = self.stage / 'generated' / path
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes( b'PRIVATE_PREFERENCE_VALUE')
        snapshot = self.stage / 'generated/ssh/config.snapshot'
        snapshot.write_bytes(b'# toolkit-ssh-snapshot: 1\n# status: empty\n# excluded-profiles: 0\n\n')
        snapshot.chmod(0o600)
        return sections

    def test_all_modes_narrowing_identity_privacy_and_category_flags(self):
        sections = self.populated()
        projection, sources = selection_api.inventory(selection_api.staged_files(self.stage))
        rows = {row['domain']: row for row in projection['inventory']}
        for domain in bundle.ITEMS | bundle.CATEGORIES:
            self.assertTrue(rows[domain]['source_present'], domain)
            self.assertTrue(rows[domain]['capture_selected'], domain)
        self.assertFalse(rows['vscode-workspaces']['source_present'])
        self.assertFalse(rows['vscode-workspaces']['capture_selected'])
        self.assertEqual(rows['vscode-workspaces']['items'], [])
        self.assertEqual(rows['vscode-workspaces']['availability'], 'unavailable')
        files = selection_api.staged_files(self.stage)
        del files['generated/brew-casks.conf']
        files['generated/vscode/settings.json'] = b''
        presence, _ = selection_api.inventory(files)
        rows = {row['domain']: row for row in presence['inventory']}
        self.assertFalse(rows['homebrew-casks']['source_present'])
        self.assertTrue(rows['vscode-settings']['source_present'])

        self.assertNotIn('PRIVATE_', json.dumps(projection))
        self.assertNotIn('secure', json.dumps(projection))
        self.assertEqual(selection_api.label('https://user:SECRET@example.test/repo'), 'Private item')
        self.assertEqual({r['domain'] for r in projection['inventory'] if r['selection_mode'] == 'items'}, set(bundle.SELECTABLE_ITEMS))
        chosen = {'categories': ['macos-finder', 'macos-trackpad', 'vscode-settings', 'shell-zsh', 'ssh-configuration'],
                  'items': {domain: [selection_api.identity(domain, values[1])] for domain, values in sections.items()}}
        selection_api.narrow(self.stage, chosen, [])
        narrowed, flags = bundle.parse_blueprint((self.stage / 'blueprint.conf').read_bytes())
        for domain, values in sections.items():
            self.assertEqual(narrowed[domain], [values[1]])
        for domain in bundle.CATEGORIES:
            self.assertEqual(flags[domain], domain in chosen['categories'])
        records = [{'domain': 'git-repositories', 'item_id': '1'}]
        selection_api.correlate(records, self.stage)
        self.assertEqual(records[0]['selection_item_id'], chosen['items']['git-repositories'][0])
        self.assertEqual(selection_api.canonical(self.stage), {'categories': sorted(chosen['categories']), 'items': dict(sorted(chosen['items'].items()))})
        selection_api.narrow(self.stage, {'categories': chosen['categories'],
                            'items': {domain: ids for domain, ids in chosen['items'].items() if domain != 'vscode-extensions'}}, [])
        retained, _ = selection_api.inventory(selection_api.staged_files(self.stage))
        row = next(row for row in retained['inventory'] if row['domain'] == 'vscode-extensions')
        self.assertTrue(row['source_present'])
        self.assertFalse(row['capture_selected'])
        self.assertEqual(row['items'], [])


    def test_captured_app_names_preserve_identity_and_round_trip(self):
        self.populated()
        target = self.stage / 'generated/appstore.conf'
        target.write_bytes(b'first|Captured App One\nsecond|Captured App Two\n')
        projection, sources = selection_api.inventory(selection_api.staged_files(self.stage))
        rows = {r['domain']: r for r in projection['inventory']}
        self.assertEqual(rows['homebrew-casks']['label'], 'Homebrew Applications')
        self.assertEqual(rows['app-store']['items'], [
            {'item_id': selection_api.identity('app-store', value), 'label': name}
            for value, name in [('first', 'Captured App One'), ('second', 'Captured App Two')]])
        for domain in bundle.ITEMS:
            if domain != 'app-store':
                self.assertEqual([r['label'] for r in rows[domain]['items']], list(sources[domain].values()))
        before = rows['app-store']['items'][1]['item_id']
        target.write_bytes(b'first|Renamed One\nsecond|Renamed Two\n')
        updated, _ = selection_api.inventory(selection_api.staged_files(self.stage))
        self.assertEqual(next(r for r in updated['inventory'] if r['domain'] == 'app-store')['items'][1]['item_id'], before)
        selection_api.narrow(self.stage, {'categories': [], 'items': {'app-store': [before]}}, [])
        self.assertEqual(selection_api.canonical(self.stage)['items'], {'app-store': [before]})
        records = [{'domain': 'app-store', 'item_id': 'second'}]
        selection_api.correlate(records, self.stage)
        self.assertEqual(records[0]['selection_item_id'], before)

    def test_whole_domains_and_each_macos_domain(self):
        for domain in bundle.CATEGORIES:
            self.populated()
            selection_api.narrow(self.stage, {'categories': [domain], 'items': {}}, [])
            self.assertEqual(selection_api.canonical(self.stage), {'categories': [domain], 'items': {}})
        for domain in bundle.ITEMS:
            values = self.populated()[domain]
            selection_api.narrow(self.stage, {'categories': [domain], 'items': {}}, [])
            self.assertEqual(selection_api.canonical(self.stage)['items'], {domain: sorted(selection_api.identity(domain, x) for x in values)})

    def test_real_macos_domain_and_git_subset_preview(self):
        blueprint = self.stage / 'blueprint.conf'
        raw = blueprint.read_text().replace('macos-dock="false"', 'macos-dock="true"').replace('macos-keyboard="false"', 'macos-keyboard="true"').replace('git-configuration="false"', 'git-configuration="true"').replace('[git-configuration]\n', '[git-configuration]\nuser.name\nuser.email\n')
        blueprint.write_text(raw)
        bundle.write_file(self.stage / 'generated/macos/dock.conf', b'com.apple.dock|autohide|bool|true\n')
        bundle.write_file(self.stage / 'generated/macos/keyboard.conf', b'NSGlobalDomain|KeyRepeat|int|6\n')
        bundle.write_file(self.stage / 'generated/git.conf', b'[user]\nname = PRIVATE_NAME\nemail = PRIVATE_EMAIL\n')
        defaults = self.fixture.root / 'bin/defaults'
        defaults.write_text('#!/bin/bash\necho "The domain/default pair of ($2, $3) does not exist" >&2\nexit 1\n')
        defaults.chmod(0o700)
        self.fixture.pack()
        chosen = {'categories': ['macos-dock'], 'items': {'git-configuration': [selection_api.identity('git-configuration', 'user.name')]}}
        result = self.prepare(chosen)
        self.assertEqual(result['selection'], chosen)
        self.assertEqual(set(row['domain'] for row in result['plan']), {'macos-dock', 'git-configuration'})
        self.assertFalse(any(row['item_id'] == 'user.email' for row in result['plan']))
        self.assertNotIn('PRIVATE_', json.dumps(result))
        self.assertFalse((self.fixture.home / '.gitconfig').exists())

    def test_capability_and_null_legacy(self):
        self.fixture.pack()
        plan = self.prepare()
        # Legacy means an omitted/null request, not whichever adapter happens to
        # be in git HEAD (which now also advertises additive response metadata).
        expected = selection_api.canonical(self.stage)
        self.assertEqual(plan['selection'], expected)
        self.assertTrue(expected['items'])  # Legacy retains captured scope; no empty whitelist.
        for operation, parameters in [('capabilities', None), ('restore_prepare', dict(path=str(self.fixture.archive), disabled_groups=[], include_secure=False, selection=None))]:
            request = dict(protocol_version=1, operation_id='compatibility', operation=operation)
            if parameters is not None: request['parameters'] = parameters
            result = subprocess.run(['bash', str(self.fixture.project / 'modules/core/application-interface/core.sh')], input=json.dumps(request).encode(), env=self.fixture.environment, cwd=self.fixture.project, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stdout)
            data = json.loads(result.stdout.splitlines()[-2])['data']
            if operation == 'capabilities': self.assertEqual(data['features']['restore_selection']['version'], 1)
            else:
                self.assertEqual(data['prepared_plan_id'], plan['prepared_plan_id'])
                self.assertEqual(data['selection'], expected)
                self.assertEqual(data, plan)  # Exact effective plan, including correlation and identity.

if __name__ == '__main__': unittest.main()
