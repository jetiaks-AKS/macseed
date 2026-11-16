#!/usr/bin/env python3
"""Focused native parser admission, isolation and qualification corpus checks."""
import hashlib
import base64
import copy
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import select
import shutil
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'scripts/fixtures/shell-parser'
spec = importlib.util.spec_from_file_location('shell_parser_build', ROOT / 'scripts/build-shell-parser.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
spec = importlib.util.spec_from_file_location('shell_state', ROOT / 'modules/shell/state.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)
spec = importlib.util.spec_from_file_location('shell_observe', ROOT / 'modules/shell/observe.py')
observer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(observer)


class ShellStateTests(unittest.TestCase):
    """Pure codec tests share the Shell harness; no helper build or HOME access."""
    def load(self, source, order=0, parent=None, context='interactive', site=None):
        row = dict(source=source['id'], parent=parent, order=order, context=context,
                   entry='source' if parent else 'manual', condition='unconditional', site=site)
        return dict(row, id=state.load_identity(row))

    def function(self, key, raw, source, loads, start=0):
        end = start + len(raw)
        return dict(id=state.identity('function', key), kind='function', key=key,
                    source=source['id'], loads=[r['id'] for r in loads],
                    details=dict(span=[start, end], body=[start + raw.index(b'{'), end],
                                 name=[start, start + len(key)], parser_profile='zsh-default-1'))

    def fixture(self, body=b'll; helper; print "private-fixture";', alias_key='ll', alias_value='run'):
        alias = ("alias " + alias_key + "='" + alias_value + "'").encode()
        main = b'run() { ' + body + b' }'
        helper = b'helper() { print "unselected-body"; }'
        raw = b'# \xc3\xa9\r\n' + alias + b'\r\n' + main + b'\r\n' + helper + b'\r\n'
        source = state.source_record('.zshrc', raw)
        loads = [self.load(source), self.load(source, 1, context='interactive-login')]
        items = [dict(id=state.identity('alias', alias_key), kind='alias', key=alias_key, source=source['id'],
                      loads=[r['id'] for r in loads], details=dict(mode='ordinary',
                      span=[raw.index(alias), raw.index(alias) + len(alias)])),
                 self.function('run', main, source, loads, raw.index(main)),
                 self.function('helper', helper, source, loads, raw.index(helper))]
        contents = dict(zip([r['id'] for r in items], [alias, main, helper]))
        script = b'#!/bin/sh\nprintf "file-only"\n'
        script_source = state.source_record('Scripts/task.sh', script, 'script')
        items.append(dict(id=state.identity('script', script_source['path']), kind='script',
                          key=script_source['path'], source=script_source['id'], loads=[],
                          details=dict(mode=0o600, managed=False, consent='file-transfer',
                                       quarantine=state.legacy().quarantine_record(b'0083;12345678;Fixture;'))))
        contents[items[-1]['id']] = script
        dependencies = []
        for owner, target, relation, phase in ((items[0], items[1], 'calls', 'invocation'),
                                             (items[1], items[2], 'calls', 'invocation'),
                                             (items[1], items[3], 'executes', 'invocation'),
                                             (items[2], items[1], 'calls', 'invocation')):
            dependencies.append(dict(owner=owner['id'], target={k: target[k] for k in ('id', 'kind', 'key')},
                                     relation=relation, phase=phase, evidence='unresolved', site=None))
        if alias_key == 'll' and b'll;' in body:
            site = raw.index(b'll;', raw.index(main))
            dependencies.append(dict(owner=items[1]['id'], target={k: items[0][k] for k in ('id', 'kind', 'key')},
                                     relation='expands', phase='parse', evidence='static-reference', site=[site, site + 2]))
        return [source, script_source], loads, items, dependencies, contents

    def value(self):
        raw, payloads = state.encode(state.assemble(*self.fixture()))
        return json.loads(raw[len(state.MAGIC):]), payloads

    def wire(self, value):
        return state.MAGIC + json.dumps(value, separators=(',', ':')).encode()

    def reject(self, edit, code=None):
        value, payloads = self.value()
        edit(value, payloads)
        with self.assertRaises(state.Invalid) as caught:
            state.decode(self.wire(value), payloads)
        if code:
            self.assertEqual(str(caught.exception), 'shell_state_' + code)

    def test_typed_identities_roundtrip_and_content_changes(self):
        args = self.fixture()
        snapshot = state.assemble(*args)
        encoded = state.encode(snapshot)
        self.assertEqual(state.encode(state.decode(*encoded)), encoded)
        reordered = [list(reversed(rows)) for rows in args[:4]] + [args[4]]
        self.assertEqual(state.encode(state.assemble(*reordered)), encoded)
        before = json.loads(encoded[0][len(state.MAGIC):])
        after = json.loads(state.encode(state.assemble(*self.fixture(b':;')))[0][len(state.MAGIC):])
        self.assertEqual([r['id'] for r in before['items']], [r['id'] for r in after['items']])
        self.assertEqual([r['id'] for r in before['sources']], [r['id'] for r in after['sources']])
        self.assertNotEqual(before['content_refs'], after['content_refs'])
        self.assertEqual(state.identity('alias', 'll'), state.legacy().base.identity('ll'))
        self.assertEqual(state.identity('script', 'Scripts/task.sh'), state.legacy().file_identity('Scripts/task.sh'))
        self.assertNotEqual(state.identity('alias', 'run'), state.identity('function', 'run'))
        extended = self.fixture(alias_key='go.here', alias_value='cd $HOME/Projects')
        self.assertEqual(state.identity('alias', 'go.here'), state.legacy().base.identity('go.here'))
        state.assemble(*extended)

    def test_selection_never_adds_dependency_items_or_payloads(self):
        snapshot = state.assemble(*self.fixture())
        chosen = [state.identity('function', 'run'), state.identity('alias', 'll')]
        raw, files = state.encode(state.select(snapshot, chosen))
        value = json.loads(raw[len(state.MAGIC):])
        self.assertEqual([r['id'] for r in value['items']], sorted(chosen))
        self.assertEqual(value['required_contracts'], {'alias': 1, 'function': 1, 'script': 1})
        self.assertEqual(set(files), {state.DEFINITIONS})
        self.assertNotIn(b'unselected-body', files[state.DEFINITIONS])
        self.assertNotIn(b'file-only', files[state.DEFINITIONS])
        self.assertEqual(len(value['sources']), 1)
        self.assertEqual(len(value['loads']), 2)  # Repeated source, distinct contexts.
        self.assertIn(state.identity('function', 'helper'), [r['target']['id'] for r in value['dependencies']])
        self.assertEqual(state.encode(state.select(snapshot, list(reversed(chosen)))), (raw, files))
        self.assertEqual(state.encode(state.select(state.select(snapshot, chosen), chosen)), (raw, files))
        empty = state.encode(state.select(snapshot, []))
        self.assertEqual(empty, state.encode(state.assemble([], [], [], [], {})))
        for ids in ([chosen[0], chosen[0]], ['unknown'], [True], None):
            with self.subTest(ids=ids), self.assertRaises(state.Invalid):
                state.select(snapshot, ids)

    def test_function_spans_bytes_and_integrity(self):
        value, files = self.value()
        item = next(r for r in value['items'] if r['key'] == 'run')
        ref = next(r for r in value['content_refs'] if r['id'] == item['content'])
        expected = self.fixture()[4][item['id']]
        self.assertEqual(files[ref['member']][ref['offset']:ref['offset'] + ref['length']], expected)
        self.assertEqual(ref['sha256'], hashlib.sha256(expected).hexdigest())
        for field, bad in [('offset', -1), ('offset', True), ('length', 0), ('sha256', '0' * 64),
                           ('member', '../private'), ('member', 'generated/shell/unknown.data')]:
            with self.subTest(field=field, bad=bad):
                self.reject(lambda v, p: v['content_refs'][0].update({field: bad}))
        self.reject(lambda v, p: p.update({state.DEFINITIONS: p[state.DEFINITIONS] + b'private-tail'}))
        self.reject(lambda v, p: p.update({'unexpected': b'private-unselected'}))
        for field, bad in [('span', [0, 1]), ('span', [True, 4]), ('body', [0, 99999]),
                           ('name', [0, 2]), ('parser_profile', 'unknown')]:
            with self.subTest(field=field):
                self.reject(lambda v, p: next(r for r in v['items'] if r['kind'] == 'function')['details'].update({field: bad}))

    def test_schema_profiles_contracts_duplicates_and_order(self):
        for field, bad in [('schema', True), ('schema', 2), ('semantic_profile', 'future'),
                           ('resource_profile', 'future'), ('required_contracts', {'function': 2}),
                           ('required_contracts', {'variable': 1}), ('qualified', True)]:
            with self.subTest(field=field):
                self.reject(lambda v, p: v.update({field: bad}))
        for field in ('items', 'sources', 'content_refs', 'dependencies', 'loads'):
            with self.subTest(field=field):
                self.reject(lambda v, p: v[field].append(copy.deepcopy(v[field][0])))
                self.reject(lambda v, p: v[field].reverse())
        self.reject(lambda v, p: v['items'][0].update(kind='variable'), 'unsupported_contract')
        self.reject(lambda v, p: v['items'][0].update(id='private-id'), 'identity_invalid')
        self.reject(lambda v, p: v['items'][0]['loads'].reverse())
        value, files = self.value(); raw = self.wire(value)
        for invalid in (raw.replace(b'"schema":1', b'"schema":1,"schema":1'),
                        raw.replace(b'"schema":1', b'"schema":NaN'),
                        raw.replace(b'"schema":1', b'"schema":1.0'),
                        raw.replace(b'"schema":1', b'"schema":' + b'9' * 100),
                        raw.replace(b'"mode":384', b'"mode":384,"mode":384'),
                        raw + b'{}', b'\xff', state.MAGIC + b'"\\ud800"'):
            with self.subTest(raw=invalid[:20]), self.assertRaises(state.Invalid):
                state.decode(invalid, files)

    def test_source_load_dependency_references_and_phases(self):
        self.reject(lambda v, p: v['items'][0].update(source='unknown'))
        self.reject(lambda v, p: v['items'][0].update(loads=['unknown']))
        self.reject(lambda v, p: v['loads'][0].update(parent=v['loads'][-1]['id']))
        self.reject(lambda v, p: v['loads'][0].update(context='unknown'))
        self.reject(lambda v, p: v['dependencies'][0].update(owner='unknown'))
        self.reject(lambda v, p: v['dependencies'][0].update(evidence='qualified'))
        self.reject(lambda v, p: v['dependencies'][0].update(phase='restore'))
        self.reject(lambda v, p: v['dependencies'][0].update(phase='parse'))
        self.reject(lambda v, p: v['dependencies'][0].update(evidence='static-reference', site=None))
        self.reject(lambda v, p: v['dependencies'][0].update(site=[0, 99999]))
        self.reject(lambda v, p: v['dependencies'][0]['target'].update(id='unknown'))
        self.reject(lambda v, p: v['sources'].append(state.source_record('Unused', b':;')))

    def test_load_ancestry_is_retained_without_unselected_content(self):
        raw = b'run() { :; }'
        source = state.source_record('.config/functions.zsh', raw)
        root = state.source_record('.zshrc', b'source ~/.config/functions.zsh\n')
        first = self.load(root)
        child = self.load(source, 1, first['id'], site=[0, root['size'] - 1])
        item = self.function('run', raw, source, [child])
        result = state.select(state.assemble([root, source], [first, child], [item], [], {item['id']: raw}), [item['id']])
        encoded, files = state.encode(result); value = json.loads(encoded[len(state.MAGIC):])
        self.assertEqual(len(value['sources']), 2)
        self.assertEqual(value['loads'], [first, child])
        self.assertEqual(files, {state.DEFINITIONS: raw})
        self.assertNotIn(b'source ~/', b''.join(files.values()))

    def test_script_v5_bytes_mode_quarantine_and_consent_are_preserved(self):
        snapshot = state.assemble(*self.fixture())
        selected = state.identity('script', 'Scripts/task.sh')
        raw, files = state.encode(state.select(snapshot, [selected]))
        value = json.loads(raw[len(state.MAGIC):]); item = value['items'][0]
        self.assertEqual(item['details']['mode'], 0o600)
        self.assertEqual(state.legacy().quarantine_bytes(item['details']['quarantine']), b'0083;12345678;Fixture;')
        self.assertEqual(files, state.legacy().contents(dict(version=5, scripts=[
            dict(path='Scripts/task.sh', text=self.fixture()[4][selected].decode(),
                 sha256=hashlib.sha256(self.fixture()[4][selected]).hexdigest(), mode=0o600, managed=False)])))
        for field, bad in [('mode', True), ('mode', 0o777), ('consent', 'restore'),
                           ('consent', None), ('managed', 1), ('quarantine', {'sha256': '0' * 64})]:
            with self.subTest(field=field):
                self.reject(lambda v, p: next(r for r in v['items'] if r['kind'] == 'script')['details'].update({field: bad}))

    def test_script_v5_selected_source_aliases_are_rejected(self):
        for command in ('source', '.'):
            with self.subTest(command=command):
                args = self.fixture(alias_value=command + ' $HOME/Scripts/task.sh')
                with self.assertRaisesRegex(state.Invalid, '^shell_state_content_invalid$'):
                    state.assemble(*args)
                # Forge an otherwise valid persisted snapshot, including the
                # content hash, so rejection must come from selected context.
                valid = state.assemble(*self.fixture(alias_value=command + ' $HOME/Scripts/safe.sh'))
                raw, files = state.encode(valid)
                value = json.loads(raw[len(state.MAGIC):])
                alias = next(row for row in value['items'] if row['kind'] == 'alias')
                ref = next(row for row in value['content_refs'] if row['id'] == alias['content'])
                files[state.DEFINITIONS] = files[state.DEFINITIONS].replace(b'Scripts/safe.sh', b'Scripts/task.sh')
                ref['sha256'] = hashlib.sha256(args[4][alias['id']]).hexdigest()
                next(row for row in value['sources'] if row['id'] == alias['source'])['sha256'] = args[0][0]['sha256']
                with self.assertRaisesRegex(state.Invalid, '^shell_state_content_invalid$'):
                    state.decode(self.wire(value), files)
                malformed = state.ShellState(value, files)
                with self.assertRaisesRegex(state.Invalid, '^shell_state_content_invalid$'):
                    state.encode(malformed)
                with self.assertRaisesRegex(state.Invalid, '^shell_state_content_invalid$'):
                    state.select(malformed, [alias['id'], state.identity('script', 'Scripts/task.sh')])

    def test_script_v5_execution_alias_and_independent_selection(self):
        script_id = state.identity('script', 'Scripts/task.sh')
        alias_id = state.identity('alias', 'll')
        for command in ('$HOME/Scripts/task.sh', 'source $HOME/Scripts/safe.sh', '. $HOME/Scripts/safe.sh'):
            with self.subTest(command=command):
                snapshot = state.assemble(*self.fixture(alias_value=command))
                combined = state.encode(state.select(snapshot, [alias_id, script_id]))
                self.assertEqual(state.encode(state.decode(*combined)), combined)
                raw, files = state.encode(state.select(snapshot, [script_id]))
                value = json.loads(raw[len(state.MAGIC):])
                self.assertEqual([row['id'] for row in value['items']], [script_id])
                self.assertEqual(len(value['sources']), 1)
                self.assertEqual(value['loads'], [])
                self.assertEqual(list(files.values()), [self.fixture()[4][script_id]])
                independent = (raw, files)
        # An omitted alias may remain in private source provenance or as a
        # dependency target. Neither makes it a selected declaration.
        sources, loads, items, dependencies, contents = self.fixture(alias_value='source $HOME/Scripts/task.sh')
        items = [row for row in items if row['id'] != alias_id]
        dependencies = [row for row in dependencies if row['owner'] != alias_id]
        del contents[alias_id]
        snapshot = state.assemble(sources, loads, items, dependencies, contents)
        self.assertEqual(state.encode(state.select(snapshot, [script_id])), independent)

    def test_manifest_and_json_allocation_boundaries(self):
        raw, files = state.encode(state.assemble([], [], [], [], {}))
        padded = raw + b' ' * (state.MAX_MANIFEST - len(raw))
        self.assertEqual(state.encode(state.decode(padded, files)), (raw, files))
        for bad in (padded + b' ', state.MAGIC + b'[' * 17 + b'0' + b']' * 17):
            with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
                state.decode(bad, {})
        value, files = self.value()
        for field, limit in [('sources', state.MAX_SOURCES + state.legacy().MAX_FILES), ('loads', state.MAX_LOADS),
                             ('items', state.MAX_DECLARATIONS + state.legacy().MAX_FILES),
                             ('content_refs', state.MAX_DECLARATIONS + state.legacy().MAX_FILES),
                             ('dependencies', state.MAX_DEPENDENCIES)]:
            candidate = copy.deepcopy(value); candidate[field] = [{}] * (limit + 1)
            with self.subTest(field=field), self.assertRaisesRegex(state.Invalid, 'resource_limit'):
                state.decode(self.wire(candidate), files)
        cycle = []; cycle.append(cycle)
        with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
            state.assemble(cycle, [], [], [], {})
        # Python callers cannot amplify individually bounded strings into an
        # oversized allocation before encode reaches its manifest-size check.
        with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
            state.encode(state.ShellState({'unused': ['x' * 1024] * 2048}, {}))

    def test_source_definition_and_aggregate_byte_limits(self):
        for size in (state.MAX_DEFINITION, state.MAX_DEFINITION + 1):
            raw = b'f() { #' + b'x' * (size - len(b'f() { #\n}')) + b'\n}'
            source = state.source_record('.zshrc', raw); load = self.load(source)
            item = self.function('f', raw, source, [load])
            if size == state.MAX_DEFINITION:
                state.assemble([source], [load], [item], [], {item['id']: raw})
            else:
                with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
                    state.assemble([source], [load], [item], [], {item['id']: raw})
        state.source_record('.zshrc', b' ' * state.MAX_SOURCE)
        with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
            state.source_record('.zshrc', b' ' * (state.MAX_SOURCE + 1))
        sources, loads, items, contents = [], [], [], {}
        for i in range(32):
            key = 'f%d' % i; prefix = (key + '() { #').encode()
            raw = prefix + b'x' * (state.MAX_DEFINITION - len(prefix) - 2) + b'\n}'
            source = state.source_record('parts/%d.zsh' % i, raw); load = self.load(source, i)
            item = self.function(key, raw, source, [load])
            sources.append(source); loads.append(load); items.append(item); contents[item['id']] = raw
        result = state.assemble(sources, loads, items, [], contents)
        self.assertEqual(len(state.encode(result)[1][state.DEFINITIONS]), state.MAX_DEFINITION_TOTAL)
        sources[0]['size'] += 1
        with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
            state.assemble(sources, loads, items, [], contents)

    def test_128_scripts_do_not_consume_the_zsh_source_budget(self):
        raw = b'f() { :; }'; source = state.source_record('.zshrc', raw); load = self.load(source)
        item = self.function('f', raw, source, [load])
        sources, items, contents = [source], [item], {item['id']: raw}
        for i in range(129):
            key = 'Scripts/task-%d.sh' % i; data = b'#!/bin/sh\n# inert fixture\n'
            record = state.source_record(key, data, 'script')
            sources.append(record)
            item = dict(id=state.identity('script', key), kind='script', key=key,
                        source=record['id'], loads=[], details=dict(mode=0o600, managed=False,
                                                                  consent='file-transfer', quarantine=None))
            items.append(item); contents[item['id']] = data
            if i == 127:
                encoded, files = state.encode(state.assemble(sources, [load], items, [], contents))
                self.assertEqual(len(files), 129)  # 128 script members plus definitions.
                self.assertEqual(len(json.loads(encoded[len(state.MAGIC):])['items']), 129)
        with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
            state.assemble(sources, [load], items, [], contents)

    def test_declaration_source_load_counts_and_depth(self):
        for count in (512, 513):
            definitions = [('f%d' % i, ('f%d() { :; }' % i).encode()) for i in range(count)]
            raw = b'\n'.join(content for _, content in definitions)
            source = state.source_record('.zshrc', raw); load = self.load(source)
            items = [self.function(key, content, source, [load], raw.index(content)) for key, content in definitions]
            contents = {item['id']: content for item, (_, content) in zip(items, definitions)}
            if count == 512:
                state.assemble([source], [load], items, [], contents)
            else:
                with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
                    state.assemble([source], [load], items, [], contents)
        sources, loads, items, contents = [], [], [], {}
        for i in range(129):
            key = 'f%d' % i; raw = (key + '() { :; }').encode()
            source = state.source_record('parts/%d.zsh' % i, raw); load = self.load(source, i)
            item = self.function(key, raw, source, [load])
            sources.append(source); loads.append(load); items.append(item); contents[item['id']] = raw
            if i == 127:
                state.assemble(sources, loads, items, [], contents)
        with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
            state.assemble(sources, loads, items, [], contents)
        raw = b'f() { :; }'; source = state.source_record('.zshrc', raw)
        loads = [self.load(source, i) for i in range(512)]
        item = self.function('f', raw, source, loads)
        state.assemble([source], loads, [item], [], {item['id']: raw})
        loads.append(self.load(source, 512))
        with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
            state.assemble([source], loads, [item], [], {item['id']: raw})
        loads = [self.load(source)]
        for i in range(1, 17):
            loads.append(self.load(source, i, loads[-1]['id'], site=[0, 1]))
            if len(loads) == 16:
                item = self.function('f', raw, source, [loads[-1]])
                state.assemble([source], loads, [item], [], {item['id']: raw})
        item = self.function('f', raw, source, [loads[-1]])
        with self.assertRaisesRegex(state.Invalid, 'resource_limit'):
            state.assemble([source], loads, [item], [], {item['id']: raw})

    def test_malformed_field_types_have_only_fixed_errors(self):
        value, files = self.value()
        locations = [(key,) for key in value]
        for group in ('items', 'sources', 'loads', 'dependencies', 'content_refs'):
            locations += [(group, 0, key) for key in value[group][0]]
        for location in locations:
            for bad in (None, [], {}, True, 1, 'private-fixture'):
                candidate = copy.deepcopy(value); parent = candidate
                for key in location[:-1]:
                    parent = parent[key]
                if parent[location[-1]] == bad and type(parent[location[-1]]) is type(bad):
                    continue
                parent[location[-1]] = bad
                with self.subTest(location=location, kind=type(bad).__name__):
                    try:
                        state.decode(self.wire(candidate), files)
                    except state.Invalid as error:
                        self.assertIn(str(error), {'shell_state_' + code for code in state.Invalid.CODES})
                    else:
                        # No observed dependency is valid data, not proof of
                        # independence. B1 never grants Restore eligibility.
                        self.assertEqual((location, bad), (('dependencies',), []))

    def test_nested_units_and_conflicting_source_roles_are_ambiguous(self):
        raw = b'outer() { inner() { :; } }'
        source = state.source_record('.zshrc', raw); load = self.load(source)
        inner = b'inner() { :; }'
        items = [self.function('outer', raw, source, [load]),
                 self.function('inner', inner, source, [load], raw.index(inner))]
        with self.assertRaisesRegex(state.Invalid, 'ambiguous_record'):
            state.assemble([source], [load], items, [], dict(zip([r['id'] for r in items], [raw, inner])))
        args = self.fixture()
        args[0].append(state.source_record('.ZSHRC', b'f() { :; }'))
        with self.assertRaisesRegex(state.Invalid, 'ambiguous_record'):
            state.assemble(*args)

    def test_private_state_and_errors_never_emit_source_or_paths(self):
        with tempfile.TemporaryDirectory(prefix='shell-state-privacy-') as directory:
            tripwire = Path(directory) / 'executed'
            args = self.fixture(('touch ' + str(tripwire)).encode())
            snapshot = state.assemble(*args)
            self.assertEqual(repr(snapshot), '<ShellState private>')
            self.assertFalse(tripwire.exists())
            raw, files = state.encode(snapshot)
            self.assertNotIn(b'touch ', raw)  # Code is in private content members only.
            for malformed in (b'{private-fixture', raw.replace(b'"schema":1', b'"schema":"private-fixture"')):
                with self.assertRaises(state.Invalid) as caught:
                    state.decode(malformed, files)
                self.assertNotIn('private-fixture', repr(caught.exception))
                self.assertNotIn(directory, repr(caught.exception))
            self.assertFalse(tripwire.exists())

    def test_parser_response_binding_and_rejection_without_launch(self):
        source = b'f() { :; }'
        value = dict(schema=1, profile='zsh-default-1', status='ok', code='ok', bytes=len(source),
                     sha256=hashlib.sha256(source).hexdigest(), nodes=24, syntax_depth=2, allocation_peak=18126,
                     definitions=[dict(span=[0, 10], body=[4, 10], names=[[0, 1]], parent=-1, depth=6)])
        response = json.dumps(value).encode()
        self.assertEqual(state.function_evidence(source, response, 0, 0)[:2], ('f', source))
        empty = dict(value, bytes=0, sha256=hashlib.sha256(b'').hexdigest(), definitions=[], nodes=1)
        self.assertEqual(state.parser_response(b'', json.dumps(empty).encode(), 0), empty)
        with self.assertRaises(state.Invalid):
            state.parser_response(b'', json.dumps(dict(empty, nodes=0)).encode(), 0)
        for field, allowed in (('syntax_depth', (0, 32)), ('allocation_peak', (1, 128 * 1024 * 1024))):
            for boundary in allowed:
                with self.subTest(field=field, boundary=boundary):
                    changed = dict(value, **{field: boundary})
                    self.assertEqual(state.function_evidence(source, json.dumps(changed).encode(), 0, 0)[:2], ('f', source))
        for field, rejected in (('syntax_depth', (-1, 33, 256)), ('allocation_peak', (0, -1, 128 * 1024 * 1024 + 1))):
            for bad in (*rejected, True, False, None, '32', [], {}, 1.5):
                with self.subTest(field=field, bad=bad), self.assertRaises(state.Invalid):
                    state.function_evidence(source, json.dumps(dict(value, **{field: bad})).encode(), 0, 0)
        # AST depth is a separate counter with a 256 limit, not syntax nesting.
        changed = copy.deepcopy(value); changed['definitions'][0]['depth'] = 256
        self.assertEqual(state.function_evidence(source, json.dumps(changed).encode(), 0, 0)[:2], ('f', source))
        for bad in (257, True):
            changed['definitions'][0]['depth'] = bad
            with self.assertRaises(state.Invalid):
                state.function_evidence(source, json.dumps(changed).encode(), 0, 0)
        for changed in (dict(value, sha256='0' * 64), dict(value, bytes=True), dict(value, nodes=0), dict(value, profile='bash'),
                        dict(value, status='error'), dict(value, extra='private-fixture')):
            with self.subTest(changed=list(changed)), self.assertRaises(state.Invalid):
                state.function_evidence(source, json.dumps(changed).encode(), 0, 0)
        for code in (2, -9, True):
            with self.assertRaises(state.Invalid):
                state.function_evidence(source, response, code, 0)
        for response in (b'', b'{}', response + b'{}', b'x' * (128 * 1024)):
            with self.assertRaises(state.Invalid):
                state.function_evidence(source, response, 0, 0)


class ShellParser(unittest.TestCase):
    def observation_home(self):
        temporary = tempfile.TemporaryDirectory(prefix='functions-', dir=self.work)
        self.addCleanup(temporary.cleanup)
        return Path(temporary.name).resolve()

    def source_file(self, home, path, raw):
        target = home / path
        target.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
        target.write_bytes(raw); target.chmod(0o600)
        return target

    def observed(self, home, **options):
        result = observer.observe(str(home), observer.client.Parser(package=self.package, manifest_sha256=self.manifest_sha256), **options)
        encoded, payloads = observer.state.encode(result.snapshot)
        value = json.loads(encoded[len(observer.state.MAGIC):])
        self.assertEqual(observer.state.encode(observer.state.decode(encoded, payloads)), (encoded, payloads))
        return result, value, payloads

    def test_observation_exact_complex_bytes_and_determinism(self):
        home = self.observation_home()
        # Match the qualified corpus CRLF policy: interior CRLF is preserved;
        # CRLF after the closing unit is rejected by the pinned grammar below.
        raw = ('# é\nordinary() {\r\n print "é"\r\n}\n'
               'function complex {\n  for x in a b; do\n    if [[ -n $x ]]; then\n'
               '      cat <<\'EOF\'\nprivate literal $HOME\nEOF\n'
               '    fi\n  done\n  inner() { :; }\n  touch "$HOME/executed"\n}\n').encode()
        self.source_file(home, '.zshrc', raw)
        result, value, payloads = self.observed(home)
        self.assertEqual({r['key'] for r in value['items']}, {'ordinary', 'complex'})
        refs = {r['id']: r for r in value['content_refs']}
        for item in value['items']:
            first, last = item['details']['span']; ref = refs[item['content']]
            self.assertEqual(payloads[ref['member']][ref['offset']:ref['offset'] + ref['length']], raw[first:last])
            self.assertEqual(len(item['loads']), 2)
        self.assertEqual(value['dependencies'], [])
        self.assertTrue(all(r['condition'] == 'unknown' for r in value['loads']))
        self.assertIn('function_calls_unresolved', result.uncertainties)
        self.assertEqual(observer.state.encode(result.snapshot), observer.state.encode(self.observed(home)[0].snapshot))
        self.assertFalse((home / 'executed').exists())
        self.assertEqual((home / '.zshrc').read_bytes(), raw)
        self.assertEqual(repr(result), '<ShellObservation private>')

    def test_observation_static_chains_contexts_and_zdotdir(self):
        home = self.observation_home()
        self.source_file(home, '.zshenv', b'export ZDOTDIR="$HOME/.config/zsh"\nenv_fn() { :; }\n')
        for name, key in (('.zprofile', 'profile'), ('.zshrc', 'rc'), ('.zlogin', 'login')):
            self.source_file(home, '.config/zsh/' + name, (key + '() { :; }\n').encode())
        with (home / '.config/zsh/.zshrc').open('ab') as stream:
            stream.write(b'source "$HOME/parts/one"\n')
        self.source_file(home, 'parts/one', b'. ${HOME}/parts/two\n')
        self.source_file(home, 'parts/two', b'leaf() { :; }\n')
        with patch.dict(os.environ, {'ZDOTDIR': '/untrusted/private/path'}):
            result, value, _ = self.observed(home)
        source_paths = {r['id']: r['path'] for r in value['sources']}
        actual = [(r['context'], source_paths[r['source']]) for r in value['loads']]
        self.assertEqual(actual, [('noninteractive', '.zshenv'), ('interactive', '.zshenv'),
            ('interactive', '.config/zsh/.zshrc'), ('interactive', 'parts/one'), ('interactive', 'parts/two'),
            ('login', '.zshenv'), ('login', '.config/zsh/.zprofile'), ('login', '.config/zsh/.zlogin'),
            ('interactive-login', '.zshenv'), ('interactive-login', '.config/zsh/.zprofile'),
            ('interactive-login', '.config/zsh/.zshrc'), ('interactive-login', 'parts/one'),
            ('interactive-login', 'parts/two'), ('interactive-login', '.config/zsh/.zlogin')])
        loads = {r['id']: r for r in value['loads']}
        for row in value['loads']:
            if row['parent']:
                parent_path = source_paths[loads[row['parent']]['source']]
                raw = (home / parent_path).read_bytes()
                self.assertTrue(raw[slice(*row['site'])].startswith((b'source ', b'. ')))
        redirected = self.observation_home()
        self.source_file(redirected, 'zsh/.zshrc', b'explicit() { :; }\n')
        self.assertEqual([r['key'] for r in self.observed(redirected, zdotdir=str(redirected / 'zsh'))[1]['items']], ['explicit'])
        with self.assertRaisesRegex(observer.Invalid, 'invalid_request'):
            self.observed(home, zdotdir='/outside/home')

    def test_observation_bare_cr_comments_never_create_commands(self):
        home = self.observation_home()
        leaf = b'ghost() { :; }\n'
        self.source_file(home, 'leaf', leaf)
        self.source_file(home, 'redirect/.zshrc', leaf)
        local = b'local_fn() {\r\n print "\xc3\xa9"\r\n}\n'
        for ending in (b'\n', b'\r\n'):
            with self.subTest(ending=ending):
                rc = b'# comment\rsource "$HOME/leaf"' + ending + local
                env = b'# comment\rZDOTDIR="$HOME/redirect"' + ending
                self.source_file(home, '.zshrc', rc)
                self.source_file(home, '.zshenv', env)
                result, value, _ = self.observed(home, contexts=['interactive'])
                self.assertEqual([row['key'] for row in value['items']], ['local_fn'])
                self.assertEqual({row['path'] for row in value['sources']}, {'.zshrc'})
                self.assertEqual(result._files['.zshrc']['status'], 'observed')
                self.assertEqual(result._files['.zshenv']['status'], 'observed')
                self.assertEqual(result._files['.zshrc']['commands'], [])
                self.assertEqual(result._files['.zshenv']['commands'], [])
                self.assertEqual(set(result._files), {'.zshenv', '.zshrc'})
                self.assertTrue(all(row['parent'] is None for row in value['loads']))
                self.assertEqual(result._files['.zshrc']['raw'], rc)
                self.assertEqual(result._files['.zshenv']['raw'], env)
                self.assertEqual((home / '.zshrc').read_bytes(), rc)
                self.assertEqual((home / '.zshenv').read_bytes(), env)
        # A real LF after the CR-containing comment admits the real command,
        # while source sites retain their original byte offsets.
        env = b'# comment\rignored\nZDOTDIR="$HOME/redirect"\n'
        rc = b'# comment\rignored\nsource "$HOME/leaf"\n'
        self.source_file(home, '.zshenv', env)
        self.source_file(home, 'redirect/.zshrc', rc)
        result, value, _ = self.observed(home, contexts=['interactive'])
        self.assertEqual([row['key'] for row in value['items']], ['ghost'])
        child = next(row for row in value['loads'] if row['parent'] is not None)
        self.assertEqual(child['site'], [rc.index(b'source'), len(rc) - 1])
        self.assertEqual(set(result._files), {'.zshenv', 'redirect/.zshrc', 'leaf'})

    def test_observation_ambiguous_units_and_source_relationships(self):
        home = self.observation_home()
        cases = [
            (b'f() { :; }\nf() { print later; }\n', 'ambiguous_function'),
            (b'function f other { :; }\nf() { :; }\n', 'ambiguous_function'),
            (b"alias f='echo existing'\nf() { :; }\n", 'ambiguous_function'),
            (b'if true; then\nf() { :; }\nfi\n', 'unsupported_context'),
            (b'source "$HOME/$dynamic"\nf() { :; }\n', 'unsupported_context'),
            (b'source ../escape\nf() { :; }\n', 'unsupported_context'),
            (b"function 'source' { :; }\nsource \"$HOME/leaf\"\n", 'unsupported_context'),
            (b'source() { :; }\nsource "$HOME/leaf"\n', 'ambiguous_source_command'),
            (b'source "$HOME/leaf"\nsource "$HOME/leaf"\n', 'ambiguous_function'),
            (b'source "$HOME/.zshrc"\nf() { :; }\n', 'cyclic_source'),
        ]
        self.source_file(home, 'leaf', b'f() { :; }\n')
        for raw, code in cases:
            self.source_file(home, '.zshrc', raw)
            with self.subTest(code=code, raw=raw):
                result, value, _ = self.observed(home, contexts=['interactive'])
                self.assertEqual(value['items'], [])
                self.assertIn(code, result.codes)
        self.source_file(home, '.zshrc', b'function a b { :; }\nouter() { inner() { :; } }\n')
        self.assertEqual([r['key'] for r in self.observed(home)[1]['items']], ['outer'])
        self.source_file(home, '.zshrc', b'() { :; }\nouter() { :; }\n')
        self.assertEqual(self.observed(home)[1]['items'], [])
        self.source_file(home, '.zshenv', b'if true; then ZDOTDIR="$HOME/zsh"; fi\n')
        result, value, _ = self.observed(home)
        self.assertEqual(value['items'], [])
        self.assertIn('startup_unresolved', result.codes)
        self.source_file(home, '.zshenv', b'function a b { :; }\nZDOTDIR="$HOME/zsh"\n')
        result, value, _ = self.observed(home)
        self.assertEqual(value['items'], []); self.assertIn('ambiguous_zdotdir', result.codes)

    def test_observation_missing_unsafe_malformed_and_changed_sources(self):
        home = self.observation_home()
        result, value, _ = self.observed(home)
        self.assertEqual(value['items'], [])
        self.assertEqual({r['status'] for r in result._files.values()}, {'missing'})
        target = self.source_file(home, 'leaf', b'private_name() { :; }\n')
        startup = home / '.zshrc'; startup.symlink_to(target)
        result, value, _ = self.observed(home)
        self.assertEqual(result._files['.zshrc']['status'], 'unsafe'); self.assertEqual(value['items'], [])
        startup.unlink(); os.link(target, startup)
        self.assertEqual(self.observed(home)[0]._files['.zshrc']['status'], 'unsafe')
        startup.unlink(); self.source_file(home, '.zshrc', target.read_bytes()); startup.chmod(0o666)
        self.assertEqual(self.observed(home)[0]._files['.zshrc']['status'], 'unsafe')
        startup.chmod(0o600)
        subprocess.run(['/bin/chmod', '+a', 'everyone allow read', str(startup)], check=True)
        try:
            self.assertEqual(self.observed(home)[0]._files['.zshrc']['status'], 'unsafe')
        finally:
            subprocess.run(['/bin/chmod', '-N', str(startup)], check=True)
        (home / 'linked-parent').symlink_to(home, target_is_directory=True)
        self.source_file(home, '.zshrc', b'source "$HOME/linked-parent/leaf"\n')
        self.assertEqual(self.observed(home)[0]._files['linked-parent/leaf']['status'], 'unsafe')
        self.source_file(home, '.zshrc', target.read_bytes())
        self.source_file(home, '.zshrc.zwc', b'compiled')
        self.assertEqual(self.observed(home)[1]['items'], [])
        (home / '.zshrc.zwc').unlink()
        for raw, code in ((b'private_name() {', 'parser_syntax_invalid'),
                          (b'f() { :; }\r\n', 'parser_syntax_invalid'), (b'\xff', 'source_encoding'),
                          (b'x\x00', 'source_encoding')):
            self.source_file(home, '.zshrc', raw)
            result, value, _ = self.observed(home)
            self.assertIn(code, result.codes); self.assertEqual(value['items'], [])
            self.assertNotIn('private_name', repr(result.codes))
            self.assertNotIn(str(home), repr(result))
        self.source_file(home, '.zshrc', target.read_bytes())
        original = observer.client.Parser.parse
        def changing(parser, raw, **options):
            response = original(parser, raw, **options)
            startup.write_bytes(raw + b'# changed\n')
            return response
        with patch.object(observer.client.Parser, 'parse', changing), self.assertRaisesRegex(observer.Invalid, 'source_changed'):
            self.observed(home)
        self.source_file(home, '.zshrc', target.read_bytes())
        def appeared(parser, raw, **options):
            response = original(parser, raw, **options)
            self.source_file(home, '.zshenv', b'# appeared after absence\n')
            return response
        with patch.object(observer.client.Parser, 'parse', appeared), self.assertRaisesRegex(observer.Invalid, 'source_changed'):
            self.observed(home)

    def test_observation_conflicting_files_and_uncertain_loads(self):
        home = self.observation_home()
        self.source_file(home, '.zshrc', b'source "$HOME/one"\nsource "$HOME/two"\n')
        self.source_file(home, 'one', b'f() { :; }\n')
        self.source_file(home, 'two', b'f() { print other; }\n')
        result, value, _ = self.observed(home)
        self.assertEqual(value['items'], []); self.assertIn('ambiguous_function', result.codes)
        (home / 'two').unlink()
        result, value, _ = self.observed(home)
        self.assertEqual([r['key'] for r in value['items']], ['f'])
        self.assertIn('source_unresolved', result.codes)
        self.assertTrue(all(row['condition'] == 'unknown' for row in value['loads']))
        self.source_file(home, '.zshenv', b'source() { :; }\n')
        result, value, _ = self.observed(home)
        self.assertEqual(value['items'], [])
        self.assertIn('ambiguous_source_command', result.codes)
        self.assertNotIn('one', result._files)  # No fabricated load through a shadowed command.
        self.source_file(home, '.zshenv', b'# inert\n')
        self.source_file(home, 'one', b'source() { :; }\n')
        self.source_file(home, 'two', b'late() { :; }\n')
        result, value, _ = self.observed(home)
        self.assertEqual(value['items'], []); self.assertNotIn('two', result._files)
        self.source_file(home, 'one', b'f() { :; }\n')
        self.source_file(home, '.zshrc', b'source "$HOME/one"\nsource "$HOME/ONE"\n')
        # Works on both case-sensitive and default case-insensitive test volumes.
        if not (home / 'ONE').exists():
            self.source_file(home, 'ONE', b'g() { :; }\n')
        result, value, _ = self.observed(home)
        self.assertEqual(value['items'], [])
        self.assertIn('ambiguous_source', result.codes)

    def test_observation_resource_limits_and_cancellation(self):
        home = self.observation_home()
        self.source_file(home, '.zshrc', b'#' + b' ' * observer.state.MAX_SOURCE)
        self.assertEqual(self.observed(home)[1]['items'], [])
        # Real depth boundary: sixteen entered files, then a seventeenth.
        self.source_file(home, '.zshrc', b'source "$HOME/part0"\n')
        for i in range(15):
            self.source_file(home, 'part%d' % i, ('source "$HOME/part%d"\n' % (i + 1)).encode()
                             if i < 14 else b'leaf() { :; }\n')
        self.assertEqual([r['key'] for r in self.observed(home, contexts=['interactive'])[1]['items']], ['leaf'])
        self.source_file(home, 'part14', b'source "$HOME/part15"\n')
        self.source_file(home, 'part15', b'leaf() { :; }\n')
        with self.assertRaisesRegex(observer.Invalid, 'resource_limit'):
            self.observed(home, contexts=['interactive'])
        # Reduced aggregate/count budgets exercise collection, independently of
        # the existing B1 tests of the actual 2 MiB/128/512 codec boundaries.
        self.source_file(home, '.zshrc', b'source "$HOME/part15"\n')
        for field, limit in (('MAX_SOURCE_TOTAL', 20), ('MAX_SOURCES', 1), ('MAX_LOADS', 1),
                             ('MAX_DECLARATIONS', 0), ('MAX_MANIFEST', 1)):
            with self.subTest(field=field), patch.object(observer.state, field, limit), self.assertRaisesRegex(observer.Invalid, 'resource_limit'):
                self.observed(home)
        with self.assertRaisesRegex(observer.Invalid, 'cancelled'):
            self.observed(home, cancelled=lambda: True)
        with patch.object(observer, 'OBSERVATION_SECONDS', 0), self.assertRaisesRegex(observer.Invalid, 'observation_timeout'):
            self.observed(home)
        for options in (dict(contexts=['interactive'] * 5), dict(cancelled=None)):
            with self.assertRaisesRegex(observer.Invalid, 'invalid_request'):
                self.observed(home, **options)

    def test_observation_trusted_transport_and_packaged_location(self):
        home = self.observation_home()
        parser = observer.client.Parser(package=self.package, manifest_sha256=self.manifest_sha256)
        response = parser.parse(b'')
        self.assertEqual(observer.state.parser_response(b'', response, 0)['definitions'], [])
        app = home / 'Fixture.app'
        helper = app / 'Contents/Helpers/macseed-shell-parser'; helper.parent.mkdir(parents=True)
        shutil.copyfile(self.binary, helper); helper.chmod(0o755)
        manifest = app / 'Contents/Resources/ThirdPartyNotices/shell-parser-build.json'
        manifest.parent.mkdir(parents=True); shutil.copyfile(self.package / 'build.json', manifest)
        self.assertEqual(json.loads(observer.client.Parser(bundle=app, manifest_sha256=self.manifest_sha256).parse(b'f() { :; }'))['status'], 'ok')
        with self.assertRaisesRegex(observer.client.Invalid, 'helper_unavailable'):
            observer.client.Parser(package=home / 'missing', manifest_sha256=self.manifest_sha256).parse(b'')
        with patch.object(observer.client, '_Task', side_effect=OSError('private-path')):
            with self.assertRaisesRegex(observer.client.Invalid, '^shell_observation_launch_failed$'):
                parser.parse(b'')
        helper.write_bytes(b'untrusted')
        with self.assertRaisesRegex(observer.client.Invalid, 'helper_untrusted'):
            observer.client.Parser(bundle=app, manifest_sha256=self.manifest_sha256).parse(b'')
        helper.unlink(); helper.symlink_to(self.binary)
        with self.assertRaisesRegex(observer.client.Invalid, 'helper_untrusted'):
            observer.client.Parser(bundle=app, manifest_sha256=self.manifest_sha256).parse(b'')

    def test_observation_transport_faults_deadline_cleanup_and_privacy(self):
        directory = self.observation_home()
        source = directory / 'fault.c'
        source.write_text('''#include <stdio.h>
#include <string.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
int main(void) {
  char input[64] = {0}; fread(input, 1, sizeof(input)-1, stdin);
  if (!strcmp(input, "crash")) { raise(SIGKILL); }
  if (!strcmp(input, "short")) { puts("{"); return 0; }
  if (!strncmp(input, "broken", 6)) { close(0); return 0; }
  if (!strcmp(input, "orphan")) {
    if (!fork()) { signal(SIGTERM, SIG_IGN); for (;;) pause(); }
    return 3;
  }
  if (!strcmp(input, "overflow")) { for (int i=0; i<140000; ++i) putchar('x'); return 0; }
  if (!strcmp(input, "hang")) { signal(SIGTERM, SIG_IGN); fork(); for (;;) pause(); }
  if (!strcmp(input, "nonzero")) { return 3; }
  fputs("private-source /private/path secret-name", stderr);
  puts("{private-malformed-output}"); return 0;
}
''')
        binary = directory / 'macseed-shell-parser'
        subprocess.run(['xcrun', 'clang', str(source), '-o', str(binary)], check=True, capture_output=True)
        binary.chmod(0o755)
        manifest = json.loads((self.package / 'build.json').read_bytes())
        manifest['architectures'] = [platform.machine()]
        builder.sign_binary(binary)
        launch = builder.launch_metadata(binary, [platform.machine()], directory)
        manifest['binaries']['macseed-shell-parser'] = dict(bytes=binary.stat().st_size,
            sha256=hashlib.sha256(binary.read_bytes()).hexdigest(), launch=launch)
        (directory / 'build.json').write_text(json.dumps(manifest))
        parser = observer.client.Parser(package=directory,
            manifest_sha256=hashlib.sha256((directory / 'build.json').read_bytes()).hexdigest())
        original = observer.client.processes.ProcessTree.scan
        seen = set()
        broken_pipes = []
        original_write = observer.client.os.write
        def write(fd, data):
            try:
                return original_write(fd, data)
            except BrokenPipeError:
                broken_pipes.append(True)
                raise
        def remember(tree):
            rows = original(tree); seen.update(rows); return rows
        unrelated = subprocess.Popen(['/bin/sleep', '30'], start_new_session=True)
        self.addCleanup(lambda: (unrelated.kill(), unrelated.wait()))
        for raw, code in ((b'crash', 'process_failed'), (b'nonzero', 'process_failed'),
                          (b'overflow', 'output_limit'), (b'malformed', 'parser_invalid'),
                          (b'short', 'parser_invalid'), (b'broken' + b' ' * (state.MAX_SOURCE - 6), 'parser_invalid'),
                          (b'hang', 'timeout'), (b'orphan', 'timeout')):
            with self.subTest(mode=raw[:16]), patch.object(observer.client.os, 'write', write), \
                    patch.object(observer.client, 'PROCESS_SECONDS', .4 if raw == b'hang' else 3), \
                    patch.object(observer.client.processes.ProcessTree, 'scan', remember):
                started = time.monotonic()
                with self.assertRaises(observer.client.Invalid) as caught:
                    parser.parse(raw)
                self.assertEqual(str(caught.exception), 'shell_observation_' + code)
                self.assertLess(time.monotonic() - started, 6)
        self.assertTrue(broken_pipes)  # Exercise EPIPE, not merely an empty response.
        started = time.monotonic()
        with patch.object(observer.client.processes.ProcessTree, 'scan', remember), self.assertRaisesRegex(observer.client.Invalid, 'cancelled'):
            parser.parse(b'hang', cancelled=lambda: time.monotonic() - started > .2)
        self.assertFalse(seen & observer.client.processes.process_table().keys())
        scans = 0
        def failed_observation(tree):
            nonlocal scans
            scans += 1
            if scans > 3:
                raise OSError('private-process-detail')
            return remember(tree)
        with patch.object(observer.client.processes.ProcessTree, 'scan', failed_observation):
            with self.assertRaisesRegex(observer.client.Invalid, '^shell_observation_process_cleanup_failed$'):
                parser.parse(b'hang')
        self.assertFalse(seen & observer.client.processes.process_table().keys())
        self.assertIsNone(unrelated.poll())
        self.assertEqual(repr(parser), '<ShellParser private>')

    def copied_package(self):
        directory = self.observation_home()
        for name in ('macseed-shell-parser', 'build.json'):
            shutil.copy2(self.package / name, directory / name)
        return directory

    def fixture_manifest(self, directory, metadata):
        # Only test/build code establishes a new anchor. Runtime parsing never
        # derives this value from the package it is about to execute.
        raw = (json.dumps(metadata, indent=2) + '\n').encode()
        (directory / 'build.json').write_bytes(raw)
        return hashlib.sha256(raw).hexdigest()

    def test_protected_launch_build_identities_and_packaging(self):
        metadata = json.loads((self.package / 'build.json').read_bytes())
        self.assertEqual(metadata['schema'], 2)
        self.assertEqual(metadata['minimum_macos'], '14.0')
        self.assertEqual(metadata['functions_minimum_macos'], '14.4')
        for name, record in metadata['binaries'].items():
            binary = self.package / name
            self.assertEqual(hashlib.sha256(binary.read_bytes()).hexdigest(), record['sha256'])
            self.assertEqual(binary.stat().st_size, record['bytes'])
            actual = builder.launch_metadata(binary, list(record['launch']['cdhashes']), self.work)
            self.assertEqual(actual, record['launch'])
        parser = observer.client.Parser(package=self.package, manifest_sha256=self.manifest_sha256)
        self.assertEqual(json.loads(parser.parse(b'f() { :; }'))['status'], 'ok')
        resources = self.observation_home() / 'Proof.app/Contents/Resources'
        builder.install_package(self.package, resources)
        packaged = observer.client.Parser(bundle=resources.parent.parent, manifest_sha256=self.manifest_sha256)
        self.assertEqual(json.loads(packaged.parse(b'f() { :; }'))['status'], 'ok')

    def test_protected_launch_x86_64_identity_when_packaged(self):
        metadata = json.loads((self.package / 'build.json').read_bytes())
        binary = self.package / 'macseed-shell-parser-x86_64'
        if not binary.exists():
            self.skipTest('x86_64 slice not in this developer package')
        launch = metadata['binaries'][binary.name]['launch']
        # Use the union constraint for both CPUs, including the Rosetta choice.
        union = metadata['binaries']['macseed-shell-parser']['launch']
        self.assertEqual(launch['cdhashes']['x86_64'], union['cdhashes']['x86_64'])
        raw = b'f() { :; }'
        response, code = observer.client.Parser._run(str(binary),
            base64.b64decode(union['requirement_data']), raw, lambda: False)
        self.assertEqual(observer.state.function_evidence(raw, response, code, 0)[0], 'f')
        if platform.machine() == 'arm64':
            wrong = metadata['binaries']['macseed-shell-parser-arm64']['launch']
            response, code = observer.client.Parser._run(str(binary),
                base64.b64decode(wrong['requirement_data']), raw, lambda: False)
            self.assertNotEqual(code, 0)
            with self.assertRaises(observer.state.Invalid):
                observer.state.parser_response(raw, response, code)

    def test_protected_launch_substitution_marker_and_forged_response(self):
        directory = self.copied_package()
        binary = directory / 'macseed-shell-parser'
        parser = observer.client.Parser(package=directory, manifest_sha256=self.manifest_sha256)
        source = b'f() { :; }'
        genuine = parser.parse(source)
        marker = directory / 'must-not-execute'
        fixture = directory / 'replacement.c'
        fixture.write_text('#include <stdio.h>\n#include <fcntl.h>\n#include <unistd.h>\n'
            'int main(void) { int fd=open(' + json.dumps(str(marker)) + ',O_WRONLY|O_CREAT|O_EXCL,0600); '
            'if(fd>=0) close(fd); fputs(' + json.dumps(genuine.decode()) + ',stdout); return 0; }\n')
        replacement = directory / 'replacement'
        subprocess.run(['xcrun', 'clang', str(fixture), '-o', str(replacement)], check=True, capture_output=True)
        builder.sign_binary(replacement)
        launch = builder.launch_metadata(replacement, [platform.machine()], directory)
        # This signed fixture really writes a marker and can forge usable B1 JSON
        # when explicitly authorized. The swap test never authorizes its identity.
        response, code = observer.client.Parser._run(str(replacement),
            base64.b64decode(launch['requirement_data']), source, lambda: False)
        self.assertEqual(observer.state.function_evidence(source, response, code, 0)[0], 'f')
        self.assertTrue(marker.exists()); marker.unlink()
        launch_task = observer.client._Task._launch
        wait = observer.client._Task.wait
        statuses = []
        def record(task, timeout):
            status = wait(task, timeout); statuses.append(status); return status
        for attempt in range(3):
            with self.subTest(attempt=attempt):
                staged = directory / 'swap'
                shutil.copy2(replacement, staged)
                def swap(task):
                    os.replace(staged, binary)
                    launch_task(task)
                with patch.object(observer.client._Task, '_launch', swap), \
                        patch.object(observer.client._Task, 'wait', record), self.assertRaises(observer.client.Invalid) as caught:
                    parser.parse(source)
                self.assertIn(caught.exception.code, ('helper_untrusted', 'launch_failed', 'process_failed'))
                self.assertFalse(marker.exists())
                self.assertNotIn(str(directory), str(caught.exception))
                binary.unlink(); shutil.copy2(self.binary, binary)
        self.assertTrue(statuses)
        self.assertTrue(all(code < 0 for code in statuses))

    def test_protected_launch_manifest_anchor_and_resigning(self):
        directory = self.copied_package()
        binary = directory / 'macseed-shell-parser'
        metadata = json.loads((directory / 'build.json').read_bytes())
        parser = observer.client.Parser(package=directory, manifest_sha256=self.manifest_sha256)
        with self.assertRaisesRegex(observer.client.Invalid, 'helper_untrusted'):
            observer.client.Parser(package=directory)  # No adjacent-file auto-trust.
        builder.sign_binary(binary, 'org.macseed.test.resigned')
        record = metadata['binaries']['macseed-shell-parser']
        record['bytes'] = binary.stat().st_size
        record['sha256'] = hashlib.sha256(binary.read_bytes()).hexdigest()
        stale_requirement_pin = self.fixture_manifest(directory, metadata)
        with patch.object(observer.client, '_Task') as launch, self.assertRaisesRegex(observer.client.Invalid, 'helper_untrusted'):
            parser.parse(b'')
        launch.assert_not_called()  # Updating writable metadata cannot grant trust.
        with self.assertRaisesRegex(observer.client.Invalid, '^shell_observation_process_failed$'):
            observer.client.Parser(package=directory, manifest_sha256=stale_requirement_pin).parse(b'')
        refreshed = builder.launch_metadata(binary, metadata['architectures'], directory)
        self.assertNotEqual(record['launch']['cdhashes'], refreshed['cdhashes'])
        record['launch'] = refreshed
        new_pin = self.fixture_manifest(directory, metadata)
        with patch.object(observer.client, '_Task') as launch, self.assertRaisesRegex(observer.client.Invalid, 'helper_untrusted'):
            parser.parse(b'')
        launch.assert_not_called()
        self.assertEqual(json.loads(observer.client.Parser(package=directory, manifest_sha256=new_pin).parse(b''))['status'], 'ok')

    def test_protected_launch_malformed_required_metadata(self):
        directory = self.copied_package()
        original = json.loads((directory / 'build.json').read_bytes())
        cases = []
        for field, value in (('schema', 999), ('cdhashes', {}), ('requirement_data', ''),
                             ('requirement_data', 'not base64'), ('requirement_data', 'x' * 5465)):
            metadata = copy.deepcopy(original)
            metadata['binaries']['macseed-shell-parser']['launch'][field] = value
            cases.append(metadata)
        metadata = copy.deepcopy(original); del metadata['binaries']['macseed-shell-parser']['launch']; cases.append(metadata)
        metadata = copy.deepcopy(original); metadata['schema'] = 1; cases.append(metadata)
        for metadata in cases:
            pin = self.fixture_manifest(directory, metadata)
            with self.subTest(metadata=cases.index(metadata)), patch.object(observer.client, '_Task') as launch, \
                    self.assertRaisesRegex(observer.client.Invalid, '^shell_observation_helper_untrusted$'):
                observer.client.Parser(package=directory, manifest_sha256=pin).parse(b'')
            launch.assert_not_called()

    def test_functions_unavailable_without_launch_api_is_not_empty_success(self):
        home = self.observation_home()
        parser = observer.client.Parser(package=self.package, manifest_sha256=self.manifest_sha256)
        api = observer.client._foundation()
        send = api.send
        def unavailable(obj, selector, *args, **kwargs):
            return False if selector == 'instancesRespondToSelector:' else send(obj, selector, *args, **kwargs)
        with patch.object(api, 'send', unavailable), patch.object(observer.client, '_Task') as launch, \
                patch.object(observer.sources, 'file_state') as read:
            for action in (lambda: parser.parse(b''), lambda: observer.observe(str(home), parser)):
                with self.assertRaisesRegex(observer.client.Invalid, '^shell_observation_functions_unavailable$'):
                    action()
        launch.assert_not_called(); read.assert_not_called()

    def test_protected_launch_malformed_constraint_is_rejected_by_os(self):
        directory = self.copied_package()
        metadata = json.loads((directory / 'build.json').read_bytes())
        record = metadata['binaries']['macseed-shell-parser']['launch']
        valid = base64.b64decode(record['requirement_data'])
        for raw in (b'\0', valid[:-1]):
            record['requirement_data'] = base64.b64encode(raw).decode('ascii')
            pin = self.fixture_manifest(directory, metadata)
            with self.assertRaises(observer.client.Invalid) as caught:
                observer.client.Parser(package=directory, manifest_sha256=pin).parse(b'')
            self.assertIn(caught.exception.code, ('launch_failed', 'process_failed'))

    def test_process_group_ownership_preserves_unrelated_and_reused_roots(self):
        processes = observer.client.processes
        rows = {1001: (1, 'root-birth', '0:00', 'helper'),
                1002: (1, 'worker-birth', '0:00', 'worker'),
                1003: (1, 'other-birth', '0:00', 'unrelated')}
        groups = {1001: 1001, 1002: 1001, 1003: 1003}
        with patch.object(processes, 'process_table', side_effect=lambda: dict(rows)), \
                patch.object(processes.os, 'getsid', return_value=999), \
                patch.object(processes.os, 'getpgid', side_effect=groups.__getitem__), \
                patch.object(processes.os, 'kill') as kill:
            ordinary = processes.ProcessTree(1001)
            self.assertEqual(set(ordinary.scan()), {1001})
            owned = processes.ProcessTree(1001, process_group=True)
            self.assertEqual(set(owned.scan()), {1001, 1002})
            del rows[1001]
            self.assertEqual(set(owned.scan()), {1002})
            del rows[1002]
            rows[1001] = (1, 'reused-pid', '0:00', 'unrelated-new-root')
            self.assertEqual(owned.scan(), {})
            self.assertTrue(owned.stop())
        kill.assert_not_called()

    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='macseed-shell-tests-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.work = Path(cls.temporary.name)
        supplied = os.environ.get('MACSEED_TEST_PARSER_PACKAGE')
        cls.package = Path(supplied) if supplied else cls.work / 'package'
        if not supplied:
            builder.build(cls.package, [platform.machine()])
        # Explicit test-fixture trust boundary, captured once before any mutation.
        cls.manifest_sha256 = hashlib.sha256((cls.package / 'build.json').read_bytes()).hexdigest()
        cls.binary = cls.package / 'macseed-shell-parser'
        cls.sanitized = json.loads((cls.package / 'build.json').read_text())['sanitized']
        cls.manifest = json.loads((CORPUS / 'manifest.json').read_text())
        builder.extract_sources(cls.work)
        cls.faults = cls.work / 'faults'
        subprocess.run(['xcrun', 'clang', '-std=c11', '-O2', '-DTREE_SITTER_REUSE_ALLOCATOR',
                        '-I' + str(cls.work / 'runtime/lib/include'),
                        '-I' + str(cls.work / 'runtime/lib/src'),
                        str(CORPUS / 'faults.c'), str(cls.work / 'runtime/lib/src/lib.c'),
                        '-o', str(cls.faults)], check=True, capture_output=True)

    def parse(self, data, binary=None, arguments=()):
        environment = {'PATH': '/nonexistent', 'HOME': str(self.work / 'absent-home')}
        if self.sanitized:
            # Keep the no-tool-discovery test strict; ASan otherwise warns while
            # looking for atos on the deliberately empty PATH. Checks stay on.
            environment['ASAN_OPTIONS'] = 'symbolize=0'
            environment['UBSAN_OPTIONS'] = 'symbolize=0:halt_on_error=1'
        process = subprocess.run([str(binary or self.binary), *arguments], input=data,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=4,
                                 env=environment)
        self.assertEqual(process.stderr, b'')
        self.assertLess(len(process.stdout), 128 * 1024)
        value = json.loads(process.stdout)
        self.assertEqual(value['schema'], 1)
        self.assertEqual(value['profile'], 'zsh-default-1')
        if value['status'] == 'error':
            self.assertEqual(process.returncode, 2)
            self.assertEqual(value['definitions'], [])
            self.assertEqual(set(value), {'schema', 'profile', 'status', 'code', 'definitions'})
        else:
            self.assertEqual(process.returncode, 0)
            self.assertEqual(value['sha256'], hashlib.sha256(data).hexdigest())
            self.assertEqual(value['bytes'], len(data))
            self.assertLessEqual(value['allocation_peak'], 128 * 1024 * 1024)
            for i, definition in enumerate(value['definitions']):
                start, end = definition['span']
                self.assertTrue(0 <= start < end <= len(data))
                self.assertLessEqual(end - start, 65536)
                data[start:end].decode('utf-8')
                body_start, body_end = definition['body']
                self.assertTrue(start <= body_start < body_end <= end)
                for first, last in definition['names']:
                    self.assertTrue(start <= first < last <= body_start)
                parent = definition['parent']
                self.assertTrue(-1 <= parent < i)
                if parent >= 0:
                    first, last = value['definitions'][parent]['body']
                    self.assertTrue(first <= start < end <= last)
        return value

    def corpus(self, binary):
        for case in self.manifest:
            with self.subTest(case=case['name']):
                data = (CORPUS / case['file']).read_bytes()
                self.assertEqual(hashlib.sha256(data).hexdigest(), case['sha256'])
                result = self.parse(data, binary)
                if case['context'] == 'reject_encoding':
                    self.assertEqual(result['code'], 'invalid_encoding')
                elif not case['valid']:
                    self.assertEqual(result['code'], 'syntax_invalid')
                else:
                    self.assertEqual(result['code'], 'ok')
                    self.assertEqual([d['span'] for d in result['definitions']], case['expected'])

    def test_original_83_case_corpus_and_golden_spans(self):
        self.assertEqual(len(self.manifest), 83)
        self.corpus(self.binary)

    def test_x86_64_corpus_when_package_contains_slice(self):
        binary = self.package / 'macseed-shell-parser-x86_64'
        if not binary.exists():
            self.skipTest('x86_64 slice not in this developer package')
        # Failure to run the requested slice is a failure, never a silent skip.
        self.corpus(binary)

    def test_names_nested_anonymous_and_multiple_bindings_are_structural(self):
        data = b"function one two { inner() { :; }; }\n() { :; } arg\n"
        definitions = self.parse(data)['definitions']
        self.assertEqual([[data[a:b] for a, b in d['names']] for d in definitions],
                         [[b'one', b'two'], [b'inner'], []])
        self.assertEqual([d['parent'] for d in definitions], [-1, 0, -1])

    def test_utf8_nul_and_noncanonical_encoding_rejected(self):
        for invalid in (b'\0', b'\xff', b'\xc0\xaf', b'\xe0\x80\x80', b'\xed\xa0\x80',
                        b'\xf4\x90\x80\x80', b'\xf0\x80\x80\x80', b'\xe2\x82', b'\x80'):
            with self.subTest(encoding=invalid.hex()):
                self.assertEqual(self.parse(b'f() { print "' + invalid + b'"; }')['code'], 'invalid_encoding')

    def test_document_and_definition_byte_limits(self):
        self.assertEqual(self.parse(b'#' + b'x' * (131072 - 2) + b'\n')['code'], 'ok')
        self.assertEqual(self.parse(b' ' * 131073)['code'], 'input_limit')
        for length, expected in ((65536, 'ok'), (65537, 'definition_size_limit')):
            data = b'f() { print "' + b'x' * (length - len(b'f() { print ""; }')) + b'"; }'
            self.assertEqual(len(data), length)
            self.assertEqual(self.parse(data)['code'], expected)

    def test_definition_name_and_nesting_limits(self):
        for count, expected in ((512, 'ok'), (513, 'definition_count_limit')):
            data = b''.join(('f%d() { :; }\n' % i).encode() for i in range(count))
            result = self.parse(data)
            self.assertEqual(result['code'], expected)
            if expected == 'ok':
                self.assertEqual(len(result['definitions']), 512)
        data = b'function ' + b' '.join(('f%d' % i).encode() for i in range(17)) + b' { :; }'
        self.assertEqual(self.parse(data)['code'], 'name_count_limit')
        self.assertEqual(self.parse(b'f() { ' + b'{ ' * 40 + b':; ' + b'}; ' * 40 + b'}')['code'], 'nesting_limit')
        for nested, expected in ((30, 'ok'), (31, 'nesting_limit')):
            self.assertEqual(self.parse(b'f() { ' + b'{ ' * nested + b':; ' + b'}; ' * nested + b'}')['code'], expected)

    def test_heredoc_suffix_outside_definition_is_rejected(self):
        for data in (b'f() { :; } <<END\nhello\nEND\n',
                     b'outer() { inner() { :; } <<END\nhello\nEND\n}\n'):
            self.assertEqual(self.parse(data)['code'], 'boundary_uncertain')
        # Body heredocs remain admitted; a separate source-level heredoc is not
        # part of the definition and cannot change its exact bytes.
        data = b'f() { cat <<END\nbody\nEND\n}\ncat <<END\nother\nEND\n'
        result = self.parse(data)
        self.assertEqual(result['code'], 'ok')
        self.assertEqual(result['definitions'][0]['span'], [0, data.index(b'\ncat')])

    def test_dense_node_budget_and_hostile_input_are_bounded(self):
        self.assertEqual(self.parse(b':\n' * 12000)['code'], 'node_limit')
        for data in (b'f(){ ' * 25000, b'$(' * 50000, b';' * 131072):
            start = time.monotonic()
            result = self.parse(data)
            self.assertLess(time.monotonic() - start, 2.8)
            self.assertIn(result['code'], {'syntax_invalid', 'allocation_limit', 'timeout', 'nesting_limit', 'node_limit'})

    def test_json_output_budget_has_no_partial_definitions(self):
        unit = b'function ' + b' '.join(('n%d' % i).encode() for i in range(16)) + b' { :; }\n'
        self.assertEqual(self.parse(unit * 512)['code'], 'output_limit')

    def test_bundle_preparation_preserves_other_files_and_refuses_links(self):
        resources = (self.work / 'fixture.app/Contents/Resources').resolve()
        resources.mkdir(parents=True)
        marker = resources / 'unrelated'
        marker.write_bytes(b'preserve')
        builder.install_package(self.package, resources)
        helper = resources.parent / 'Helpers/macseed-shell-parser'
        self.assertEqual(helper.read_bytes(), self.binary.read_bytes())
        self.assertEqual(helper.stat().st_mode & 0o777, 0o755)
        self.assertEqual(self.parse(b'f() { :; }', helper)['code'], 'ok')
        builder.install_package(self.package, resources)
        self.assertEqual(marker.read_bytes(), b'preserve')
        notices = resources / 'ThirdPartyNotices'
        self.assertEqual({p.name for p in notices.iterdir()},
                         {'shell-parser-zsh-LICENSE.txt', 'shell-parser-runtime-LICENSE.txt',
                          'shell-parser-runtime-unicode-LICENSE.txt', 'shell-parser-build.json'})
        self.assertEqual({p.name for p in self.package.glob('*LICENSE')},
                         {'zsh-LICENSE', 'runtime-LICENSE', 'runtime-unicode-LICENSE'})
        pins = json.loads((builder.VENDOR / 'pins.json').read_text())
        for component, license_name, upstream_path in (
                ('zsh', 'zsh-LICENSE', 'LICENSE'),
                ('runtime', 'runtime-LICENSE', 'LICENSE'),
                ('runtime', 'runtime-unicode-LICENSE', 'lib/src/unicode/LICENSE')):
            with self.subTest(license=license_name):
                archive = builder.VENDOR / pins[component]['archive']
                self.assertEqual(hashlib.sha256(archive.read_bytes()).hexdigest(), pins[component]['sha256'])
                with tarfile.open(archive) as stream:
                    matches = [m for m in stream.getmembers()
                               if m.isfile() and m.name.split('/', 1)[-1] == upstream_path]
                    self.assertEqual(len(matches), 1)
                    expected = stream.extractfile(matches[0]).read()
                self.assertEqual((self.package / license_name).read_bytes(), expected)
                notice = notices / ('shell-parser-' + license_name + '.txt')
                self.assertEqual(notice.read_bytes(), expected)
                self.assertFalse(notice.is_symlink())
                self.assertEqual(notice.stat().st_mode & 0o777, 0o644)
        helper.unlink()
        helper.symlink_to(marker)
        with self.assertRaisesRegex(ValueError, 'unsafe_bundle_output'):
            builder.install_package(self.package, resources)
        self.assertEqual(marker.read_bytes(), b'preserve')
        with self.assertRaisesRegex(ValueError, 'output_must_not_exist'):
            builder.build(self.package, [platform.machine()])

    def test_truncation_never_admits_a_completed_start_zero_definition(self):
        # Same five units/proper-prefix family as the research experiment.
        names = ['01_braces', '16_controls', '20_substitutions',
                 '23_heredoc_quoted', '25_heredoc_queue']
        count = 0
        for name in names:
            case = next(c for c in self.manifest if c['name'] == name)
            data = (CORPUS / case['file']).read_bytes()
            end = case['expected'][0][1]
            for stop in range(end):
                result = self.parse(data[:stop])
                self.assertFalse(any(d['span'][0] == 0 for d in result['definitions']))
                count += 1
        self.assertEqual(count, 570)

    def test_privacy_no_execution_no_path_or_source_output(self):
        tripwire = self.work / 'must-not-exist'
        data = (f'PRIVATE_FUNCTION_MARKER() {{ touch "{tripwire}"; }}\n'
                f'touch "{tripwire}"\nsource "{tripwire}"\n'
                'print "$(PRIVATE_COMMAND_MARKER)"\n').encode()
        result = self.parse(data)
        self.assertEqual(result['code'], 'ok')
        serialized = json.dumps(result)
        self.assertNotIn('PRIVATE_', serialized)
        self.assertNotIn(str(self.work), serialized)
        self.assertFalse(tripwire.exists())
        self.assertEqual(self.parse(data + b'"')['code'], 'syntax_invalid')
        self.assertEqual(self.parse(data, arguments=('--mode=extended',))['code'], 'invalid_request')

    def test_watchdog_covers_incomplete_stdin_and_cancellation(self):
        for terminate in (False, True):
            with subprocess.Popen([str(self.binary)], stdin=subprocess.PIPE,
                                  stdout=subprocess.PIPE, stderr=subprocess.PIPE) as process:
                start = time.monotonic()
                process.stdin.write(b'f() { :; }')
                process.stdin.flush()
                if terminate:
                    time.sleep(0.05)
                    process.send_signal(signal.SIGTERM)
                process.wait(timeout=3)
                self.assertLess(time.monotonic() - start, 2.8)
                response = json.loads(process.stdout.read())
                self.assertEqual(response['code'], 'cancelled' if terminate else 'timeout')
                self.assertEqual(response['definitions'], [])
                self.assertEqual(process.stderr.read(), b'')

    def test_supervisor_faults_allocation_output_rss_timeout_and_reaping(self):
        expected = {0: 'process_failed', 1: 'process_failed', 2: 'timeout', 3: 'output_limit',
                    4: 'process_failed', 5: 'allocation_limit', 6: 'allocation_limit',
                    7: 'allocation_limit', 8: 'memory_limit', 9: 'allocation_limit'}
        for scenario, code in expected.items():
            with self.subTest(scenario=scenario):
                process = subprocess.run([str(self.faults), str(scenario)], capture_output=True, timeout=3)
                self.assertEqual(process.returncode, 0)
                self.assertEqual(process.stdout, (code + '\n').encode())
                self.assertEqual(process.stderr, b'')

    def test_cancel_running_worker_and_closed_output_fail_without_leaks(self):
        with subprocess.Popen([str(self.faults), '10'], stdout=subprocess.PIPE,
                              stderr=subprocess.PIPE) as process:
            self.assertTrue(select.select([process.stdout], [], [], 2)[0])
            self.assertEqual(process.stdout.readline(), b'ready\n')
            process.send_signal(signal.SIGTERM)
            stdout, stderr = process.communicate(timeout=2)
            self.assertEqual(process.returncode, 0)  # The harness also checks waitpid/ECHILD.
            self.assertEqual(stdout, b'cancelled\n')
            self.assertEqual(stderr, b'')
        read_fd, write_fd = os.pipe()
        os.close(read_fd)
        try:
            process = subprocess.run([str(self.binary)], input=b'f() { :; }',
                                     stdout=write_fd, stderr=subprocess.PIPE, timeout=3)
            self.assertEqual(process.returncode, 2)
            self.assertEqual(process.stderr, b'')
        finally:
            os.close(write_fd)

    def test_seeded_mutations_never_crash_or_return_unbounded_output(self):
        generator = random.Random(0x5A5348)
        valid = [c for c in self.manifest if c['valid'] and c['group'] != 'policy']
        for index in range(128):
            case = generator.choice(valid)
            data = bytearray((CORPUS / case['file']).read_bytes())
            offset = generator.randrange(len(data))
            data[offset:offset + 1] = generator.choice([b'}', b'"', b'$(', b'\n', b'', b'\0', b'\xff'])
            with self.subTest(mutation=index):
                result = self.parse(bytes(data))
                self.assertIn(result['code'], {'ok', 'syntax_invalid', 'invalid_encoding', 'boundary_uncertain'})

    def test_version_is_fixed_and_requires_no_tool_discovery(self):
        process = subprocess.run([str(self.binary), '--version'], capture_output=True, check=True,
                                 env={'PATH': '/nonexistent'})
        result = json.loads(process.stdout)
        self.assertEqual(result['grammar'], '0.8.0')
        self.assertEqual(result['runtime'], '0.27.2')
        self.assertEqual(result['revision'], '17651db6e3a413b22e148c8a57726d4b392d10f7')

    def test_typed_state_consumes_helper_evidence_without_restore_authority(self):
        case = next(row for row in self.manifest if row['name'] == '62_archive_workflow')
        raw = (CORPUS / case['file']).read_bytes()
        result = self.parse(raw)
        key, content, details = state.function_evidence(raw, json.dumps(result).encode(), 0, 0)
        first, last = case['expected'][0]
        self.assertEqual(content, raw[first:last])
        source = state.source_record('.zshrc', raw)
        load = dict(source=source['id'], parent=None, order=0, context='interactive',
                    entry='zshrc', condition='unknown', site=None)
        load['id'] = state.load_identity(load)
        item = dict(id=state.identity('function', key), kind='function', key=key,
                    source=source['id'], loads=[load['id']], details=details)
        encoded, files = state.encode(state.assemble([source], [load], [item], [], {item['id']: content}))
        self.assertEqual(files, {state.DEFINITIONS: content})
        self.assertNotIn(b'qualified', encoded)
        self.assertNotIn(b'eligible', encoded)


if __name__ == '__main__':
    unittest.main()
