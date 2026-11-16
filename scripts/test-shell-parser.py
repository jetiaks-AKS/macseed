#!/usr/bin/env python3
"""Focused native parser admission, isolation and qualification corpus checks."""
import hashlib
import copy
import importlib.util
import json
import os
from pathlib import Path
import platform
import random
import select
import signal
import subprocess
import tarfile
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CORPUS = ROOT / 'scripts/fixtures/shell-parser'
spec = importlib.util.spec_from_file_location('shell_parser_build', ROOT / 'scripts/build-shell-parser.py')
builder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(builder)
spec = importlib.util.spec_from_file_location('shell_state', ROOT / 'modules/shell/state.py')
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)


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
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='macseed-shell-tests-')
        cls.addClassCleanup(cls.temporary.cleanup)
        cls.work = Path(cls.temporary.name)
        supplied = os.environ.get('MACSEED_TEST_PARSER_PACKAGE')
        cls.package = Path(supplied) if supplied else cls.work / 'package'
        if not supplied:
            builder.build(cls.package, [platform.machine()])
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
