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
        return sections

    def test_all_modes_narrowing_identity_privacy_and_category_flags(self):
        sections = self.populated()
        projection, sources = selection_api.inventory(selection_api.staged_files(self.stage))
        self.assertNotIn('PRIVATE_', json.dumps(projection))
        self.assertNotIn('secure', json.dumps(projection))
        self.assertEqual(selection_api.label('https://user:SECRET@example.test/repo'), 'Private item')
        self.assertEqual({r['domain'] for r in projection['inventory'] if r['selection_mode'] == 'items'}, set(bundle.ITEMS))
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
        defaults.write_text('#!/bin/bash\necho "does not exist" >&2\nexit 1\n')
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
