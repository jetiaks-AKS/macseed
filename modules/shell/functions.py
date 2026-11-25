"""Bounded exact-definition Restore/Check; never evaluates Shell source.

The B2A observer owns discovery and parser transport. The existing Shell
publisher owns safe append, metadata, competing writers and recovery fences.
"""
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import stat
import sys
import time

spec = importlib.util.spec_from_file_location('shell_function_capture', Path(__file__).with_name('capture.py'))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
observe, state, client = capture.observe, capture.state, capture.client
sources, base = observe.sources, observe.base
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('shell_providers', Path(__file__).with_name('providers.py'))
providers = importlib.util.module_from_spec(spec)
spec.loader.exec_module(providers)
PLAN_SECONDS = 60
MANAGED_PATH = '.macseed-shell-definitions.zsh'
MANAGED_HEADER = b'# Macseed portable definitions 1\n'
PARTIAL_INIT = re.compile(rb'eval "\$\(([A-Za-z][A-Za-z0-9_-]*) init zsh\)"')
PARTIAL_OPTION = re.compile(rb'setopt[ \t]+(?:interactive_?comments|auto_?cd)', re.I)
MANAGED_SOURCE = ('source "$HOME/' + MANAGED_PATH + '"\n').encode()


def load(path, *, archive=False):
    path = Path(path)
    raw = base.read_file(str(path), private=True, limit=state.MAX_MANIFEST)
    state.require(raw.startswith(state.MAGICS), 'unsupported_contract')
    manifest = state._json(raw[len(state.MAGIC):], state.MAX_MANIFEST)
    state.manifest_keys(manifest)
    refs = state._rows(manifest, 'content_refs', state.MAX_DECLARATIONS + state.legacy().MAX_FILES)
    members = set()
    for ref in refs:
        state.keys(ref, 'id member offset length sha256')
        member = ref['member']
        state.require(type(member) is str and (member == state.DEFINITIONS or
            re.fullmatch(r'generated/shell/scripts/[0-9a-f]{64}\.data', member)), 'content_invalid')
        members.add(member)
    state.require(len(members) <= state.legacy().MAX_FILES + 1, 'resource_limit')
    payloads = {}
    for member in sorted(members):
        payloads[member] = base.read_file(str(path.parent / member.removeprefix('generated/shell/')), private=True,
            limit=state.MAX_DEFINITION_TOTAL if member == state.DEFINITIONS else state.legacy().MAX_FILE_BYTES)
        state.require(sum(map(len, payloads.values())) <= state.MAX_DEFINITION_TOTAL + state.legacy().MAX_CONTENT_BYTES, 'resource_limit')
    value = state.decode(raw, payloads)
    if not value._value['items']:
        raise base.Invalid('unsupported_contract')
    return value


def content(value, item):
    return state.content(value, item)


def chains(loads, paths, selected):
    """Project existing B1 load records, without resolving any Shell commands."""
    table = {row['id']: row for row in loads}
    result = []
    for key in selected:
        row = table[key]
        chain = []
        while row is not None:
            chain.append((paths[row['source']], row['entry']))
            parent = row['parent']
            row = table[parent] if parent is not None else None
        result.append((table[key]['context'], tuple(reversed(chain))))
    return sorted(result)


def environment_order(snapshot, selected_ids):
    table = {r['id']: r for r in snapshot._value['loads']}
    contexts = {}
    for row in snapshot._value['items']:
        if row['id'] in selected_ids:
            for key in row['loads']:
                position = state.load_position(table, key, row['details']['span'][0])
                contexts.setdefault(table[key]['context'], []).append((position, row['id']))
    return {context: [identity for _, identity in sorted(events)] for context, events in contexts.items()}


def order_conflicts(expected, observed):
    """Identify the participants in a reversal among retained declarations."""
    common = set(expected) & set(observed)
    expected = [key for key in expected if key in common]
    observed = [key for key in observed if key in common]
    if expected == observed:
        return set()
    if len(expected) != len(common) or len(observed) != len(common):
        return common  # Changed repeated visits have no unique positional pairing.
    rank = {key: index for index, key in enumerate(observed)}
    conflicts = set()
    latest = -1
    for key in expected:
        if rank[key] < latest:
            conflicts.add(key)
        latest = max(latest, rank[key])
    earliest = len(observed)
    for key in reversed(expected):
        if rank[key] > earliest:
            conflicts.add(key)
        earliest = min(earliest, rank[key])
    return conflicts


def saved_setting_offsets(original, missing, payloads, source):
    """Use saved line positions only if inserting the selected bytes recreates the saved source."""
    if any(row['kind'] != 'setting' for row in missing):
        return {}
    offsets, inserted, previous = {}, 0, 0
    for row in sorted(missing, key=lambda r: r['details']['span']):
        key = row['id']
        offset = row['details']['span'][0] - inserted
        if not previous <= offset <= len(original) or (offset and original[offset-1:offset] != b'\n'):
            return {}
        previous = offsets[key] = offset
        inserted += len(payloads[key]) + 1
    if len(original) + inserted != source['size']:
        return {}
    candidate = sources.inserted_content(original, [(offset, payloads[key] + b'\n') for key, offset in offsets.items()])
    return offsets if state.digest(candidate) == source['sha256'] else {}


class Plan:
    def __init__(self, value, home, *, helper=None, cancelled=lambda: False, ignore_pending=()):
        raw, payloads = state.encode(value)
        if not value._value['items']:
            raise base.Invalid('unsupported_contract')
        self.rows, self.writes = [], {}
        self.coverage = 'partial'
        self.insertions, self.provider_evidence = {}, {}
        self.skipped = set()
        self.pending_dependencies = set()
        self.observable_absences = set()
        self.environment = value._value['schema'] >= 2
        self.settings = value._value['schema'] == 3
        self.observed = None
        self.helper = helper
        self.evidence = None
        self._value, self._home, self._cancelled = value, home, cancelled
        self._selected = {r['id'] for r in value._value['items']}
        self._unresolved_reads = set()
        self._archive = value
        self._deadline = time.monotonic() + PLAN_SECONDS
        self.scripts = state.script_value(value)
        self.script_plan = None
        self.script_evidence = None
        self._alias_evidence = {}
        inputs = dict(snapshot=state.digest(raw), payloads={k: state.digest(v) for k, v in payloads.items()})
        try:
            self._check()
            if any(r['kind'] != 'script' for r in value._value['items']):
                self.helper = helper or capture.parser(ROOT)
                self.observed = observe.observe(home, self.helper, cancelled=self._check, _ignore_pending=ignore_pending, aliases=True, independent=True,
                                                _additional_sources=(MANAGED_PATH,), environment=self.environment, settings=self.settings)
                inputs.update(parser=self.helper._manifest_sha256,
                    files={p: dict(status=f['status'], stamp=f['stamp'], digest=state.digest(f['raw']) if f['raw'] is not None else None)
                           for p, f in self.observed._inputs.items()}, loads=self.observed._loads)
            if self.scripts is not None:
                self.script_plan = state.legacy().plan(self.scripts, home,
                    source_files=self.observed._inputs if self.observed is not None else None)
                self.script_evidence = inputs['scripts'] = state.legacy().evidence(self.scripts, home, ignore_pending)
            if self.observed is not None:
                if self.environment:
                    self._ambiguous = self._align_occurrences(self.observed)
                    self._include_observed_evidence(value)
                    self._inspect_environment(self._existing_definitions(self.observed))
                    self.rows = [entry for entry in self.rows if entry[0]['id'] in self._selected]
                    self.skipped.intersection_update(self._selected)
                    inputs['providers'] = self.provider_evidence
                else:
                    self._inspect()
                inputs['aliases'] = self._alias_evidence
            if self.scripts is not None:
                by_id = {r['id']: r for r in value._value['items']}
                self.rows += [(by_id[row['name']], status, policy) for row, status, policy in self.script_plan['rows']]
            # A selected item owns its own outcome. Scope needs a separate
            # warning only when the source observation itself is incomplete.
            if self.observed is None or not (set(self.observed.codes) - {'unsupported_context'}):
                self.coverage = 'information'
        except (client.Invalid, observe.Invalid) as exc:
            if exc.code in ('cancelled', 'process_cleanup_failed'):
                raise
            code = 'functions_unavailable' if exc.code in ('functions_unavailable', 'helper_unavailable', 'helper_untrusted') else 'observation_failed'
            self.rows = [(item, 'unverified', code) for item in value._value['items']]
            self.writes = {}
        if self.environment:
            inputs['pending_dependencies'] = sorted(self.pending_dependencies & self._selected)
            inputs['observable_absences'] = sorted(self.observable_absences & self._selected)
            inputs['publication_order'] = list(self.writes)
        if self.skipped:
            inputs['skipped'] = sorted(self.skipped)
        self.evidence = state.digest(json.dumps(dict(inputs, coverage=self.coverage, rows=[(r['id'], s, p) for r, s, p in self.rows],
            writes={p: state.digest(v) for p, v in self.writes.items()}), sort_keys=True, separators=(',', ':')).encode())

    def __repr__(self):
        return '<ShellFunctionPlan private>'

    def _check(self):
        if self._cancelled():
            raise client.Invalid('cancelled')
        if time.monotonic() >= self._deadline:
            raise observe.Invalid('observation_timeout')
        return False

    def _align_occurrences(self, observed):
        """A deletion shifts parser ordinals. Pair only a unique ordered subsequence."""
        saved, live = self._archive, observed.snapshot
        expected, actual = {}, {}
        saved_loads = {r['id']: r for r in saved._value['loads']}
        live_loads = {r['id']: r for r in live._value['loads']}
        for row in saved._value['items']:
            if row['kind'] in state.environment.KINDS:
                unit = state.declaration_receipt(row, content(saved, row), saved_loads)
                expected.setdefault(state.declaration_family(row), []).append((row['details']['ordinal'], unit, row['id']))
        for key, proof in saved._value.get('selection_evidence', {}).get('declarations', {}).items():
            if proof['ordinal'] is not None:
                expected.setdefault(proof['family'], []).append((proof['ordinal'], proof['unit'], key))
        for row in live._value['items']:
            if row['kind'] in state.environment.KINDS:
                actual.setdefault(state.declaration_family(row), []).append(row)
        remapped, ambiguous = {}, set()
        for family, occurrences in expected.items():
            sequence = sorted(occurrences)
            found = sorted(actual.get(family, ()), key=lambda r: r['details']['ordinal'])
            if not found or len(found) >= len(sequence) or [r[0] for r in sequence] != list(range(len(sequence))):
                continue
            units = [state.declaration_receipt(r, content(live, r), live_loads) for r in found]
            def positions(saved_positions, live_units):
                positions = iter(saved_positions)
                return [next((i for i in positions if sequence[i][1] == unit), None) for unit in live_units]
            left = positions(range(len(sequence)), units)
            right = positions(reversed(range(len(sequence))), reversed(units))[::-1]
            if None in left or left != right:
                ambiguous.update(r[2] for r in sequence)
                continue
            for row, index in zip(found, left):
                if row['details']['ordinal'] != index:
                    remapped[row['id']] = dict(row, id=sequence[index][2], details=dict(row['details'], ordinal=index))
        if remapped:
            rows, contents = [], {}
            for item in live._value['items']:
                row = remapped.get(item['id'], item)
                rows.append({k: v for k, v in row.items() if k != 'content'})
                contents[row['id']] = content(live, item)
            observed.snapshot = state.assemble(live._value['sources'], live._value['loads'], rows,
                state.parameter_dependencies(rows, live._value['loads']), contents)
        return ambiguous

    def report_rows(self, *, compare):
        for row, status, reason in self.rows:
            if status == 'matching' and row['id'] in self.pending_dependencies:
                status, reason = ('unverified', 'dependency_prerequisite') if compare else ('pending', 'dependency')
            if compare and row['id'] in self.observable_absences and status == 'unverified' and reason in (
                    'source_prerequisite', 'managed_source_prerequisite', 'unsafe_destination'):
                status, reason = 'missing', 'preserve'
            yield row, status, reason

    @staticmethod
    def _opaque_statements(file):
        known = ({tuple(site) for _, _, site in file['commands']} |
                 {tuple(site) for _, _, _, site in file.get('environment', ())} |
                 {tuple(details['span']) for _, _, details in file['units']})
        return file['boundaries'] - known

    def _include_observed_evidence(self, saved):
        """Recover comparison-only declarations from independent target observations."""
        proof = saved._value.get('selection_evidence')
        if not proof:
            return
        live = self.observed.snapshot
        sources = {r['id']: r for r in saved._value['sources']}
        loads = {r['id']: r for r in saved._value['loads']}
        live_sources = {r['id']: r for r in live._value['sources']}
        live_loads = {r['id']: r for r in live._value['loads']}
        items = {r['id']: r for r in saved._value['items']}
        contents = {key: content(saved, row) for key, row in items.items()}
        dependencies = list(saved._value['dependencies'])
        for row in live._value['items']:
            receipt = proof['declarations'].get(row['id'])
            if not receipt:
                continue
            raw = content(live, row)
            if (state.declaration_family(row) != receipt['family'] or row['details'].get('ordinal') != receipt['ordinal']
                    or receipt['offset'] + len(raw) > receipt['size']
                    or state.declaration_receipt(row, raw, live_loads) != receipt['unit']):
                continue
            # Translate traversal indices back to the saved graph. The same
            # physical source visit can have a new index after another root disappears.
            routes = state.declaration_routes(row, live_loads)
            if list(map(len, routes)) != list(map(len, receipt['visits'])):
                continue
            ancestry, saved_visits = {}, []
            qualified_sites = True
            for route, saved_route in zip(routes, receipt['visits']):
                parent = None
                for visit, (order, site) in zip(route, saved_route):
                    if site != visit['site']:
                        parent_id = live_loads[visit['parent']]['source']
                        file = self.observed._files[live_sources[parent_id]['path']]
                        child = live_sources[visit['source']]['path']
                        # A shifted byte offset still identifies the unique literal
                        # load in a fully inspected parent. Repeated or opaque
                        # sites require the original physical placement.
                        if (not file.get('all_outer_bounded') or self._opaque_statements(file) or
                                sum(command == 'source' and operand == child for command, operand, _ in file['commands']) != 1):
                            qualified_sites = False
                            break
                    original = dict(visit, order=order, site=site, parent=parent)
                    parent = original['id'] = state.load_identity(original)
                    ancestry[parent] = original
                saved_visits.append(parent)
            if not qualified_sites or any(key in loads and loads[key] != visit for key, visit in ancestry.items()):
                continue
            layouts = {visit['source']: proof['ancestors'].get(visit['source']) for visit in ancestry.values()}
            layouts[row['source']] = [receipt['sha256'], receipt['size']]
            if any(layout is None or source_id in sources and
                   layout != [sources[source_id]['sha256'], sources[source_id]['size']]
                   for source_id, layout in layouts.items()):
                continue
            for source_id, (digest, size) in layouts.items():
                sources[source_id] = dict(live_sources[source_id], sha256=digest, size=size)
            loads.update(ancestry)
            # Compare both positions. A displaced declaration can establish a
            # byte match, but cannot act as an exact-site anchor across opaque code.
            details = dict(row['details'])
            details.pop('placement', None)  # Omitted declarations have no archived Settings placement.
            delta = receipt['offset'] - details['span'][0]
            for field in ('span', 'body', 'name'):
                if field in details:
                    details[field] = [n + delta for n in details[field]]
            items[row['id']] = dict(row, details=details, loads=saved_visits)
            contents[row['id']] = raw
        ordered = {}
        for edge in state.parameter_dependencies(items.values(), loads.values()):
            ordered.setdefault(edge['owner'], []).append(edge)
        for owner, fingerprint in proof['bindings'].items():
            edges = ordered.get(owner, [])
            if state.binding_receipt(edges) != fingerprint:
                self._unresolved_reads.add(owner)
            else:
                dependencies.extend(edge for edge in edges if owner not in self._selected or
                                    edge['target']['id'] not in self._selected)
        if len(items) != len(self._selected):
            self._value = state.assemble(list(sources.values()), list(loads.values()),
                [{k: v for k, v in row.items() if k != 'content'} for row in items.values()],
                dependencies, contents)

    def _inspect_environment(self, existing, excluded=frozenset()):
        value, observed = self._value, self.observed
        rows = [r for r in value._value['items'] if r['kind'] != 'script' and r['id'] not in excluded]
        source_paths = {s['id']: s['path'] for s in value._value['sources']}
        target_paths = {f['source']['id']: p for p, f in observed._files.items() if f['source']}
        actual = {r['id']: r for r in observed.snapshot._value['items']}
        states, payloads, groups = {}, {}, {}
        write_restrictions = {}
        saved_loads = {r['id']: r for r in value._value['loads']}
        conditional = set()
        for load in saved_loads.values():  # Validated parents precede their children.
            if load['condition'] == 'conditional' or load['parent'] in conditional:
                conditional.add(load['id'])
        for row in rows:
            self._check()
            key, path = row['id'], source_paths[row['source']]
            record = observed._files.get(path)
            route = chains(value._value['loads'], source_paths, row['loads'])
            ancestors = {p for _, chain in route for p, _ in chain}
            relevant = [observed._files.get(p, {}) for p in ancestors]
            if key in self._ambiguous or not conditional.isdisjoint(row['loads']):
                states[key] = ('unverified', 'source_prerequisite')
                continue
            found = actual.get(key)
            if found is None and key not in self._selected:
                states[key] = ('unverified', 'source_prerequisite')
                continue
            if not found and any(
                    f.get('stamp') and (f['stamp'][1][1] or sources.MANAGED.search(state.utf8(f['raw']))) for f in relevant):
                write_restrictions[path] = 'managed_source_prerequisite'
            if not record or record['status'] not in ('observed', 'partial', 'missing'):
                states[key] = ('unverified', 'unsafe_destination')
                continue
            visits = [r['id'] for r in observed._loads if target_paths[r['source']] == path]
            if record['raw'] is None:
                if path not in observed._roots or not all(len(chain) == 1 and Path(path).name == '.' + chain[0][1] for _, chain in route):
                    states[key] = ('unverified', 'source_prerequisite')
                    continue
            elif key not in existing and chains(observed._loads, target_paths, visits) != route:
                states[key] = ('unverified', 'source_prerequisite')
                continue
            saved = content(value, row)
            if row['kind'] in state.environment.KINDS:
                reason, saved = self._environment_payload(row, saved)
                if reason:
                    states[key] = ('unverified', reason)
                    continue
            elif observe._shadows_source([row['key']], []) or (key not in existing and not self._definition_valid(row, saved)):
                states[key] = ('unverified', 'definition_invalid')
                continue
            if key in self._unresolved_reads or any(d['owner'] == key and d['relation'] != 'reads' for d in value._value['dependencies']):
                states[key] = ('unverified', 'dependency_prerequisite')
                continue
            payloads[key] = saved
            if key in existing:
                states[key] = existing[key]
            elif found and row['kind'] in ('alias', 'function') and observed.codes:
                # A partially observed graph needs B4's independent binding
                # evidence, including later overrides and equivalent copies.
                states[key] = ('unverified', 'source_prerequisite')
            elif found:
                same = self._same_environment(row, saved, observed, found)
                states[key] = ('matching', 'preserve') if same else ('differing', 'target_conflict')
                if not same and row['kind'] == 'initializer' and found['kind'] == 'initializer':
                    actual_intent = found['details']['intent']
                    reason, normalized = self._environment_payload(found, content(observed.snapshot, found))
                    if (not reason and normalized == saved and
                            actual_intent['variant'].split(' ', 1)[0].isidentifier()):
                        states[key] = ('unverified', 'tool_observation_prerequisite')
            else:
                states[key] = ('missing', 'create' if record['raw'] is None else 'add')
            if (states[key][0] == 'missing' and row['kind'] == 'variable' and
                    not any(d['owner'] == key for d in value._value['dependencies']) and
                    self._observable_variable_absence(row, observed)):
                self.observable_absences.add(key)
            groups.setdefault(path, []).append(row)

        saved_sources = {s['id']: s for s in value._value['sources']}
        for path, items in groups.items():
            missing = [r for r in items if states[r['id']][0] == 'missing']
            if not missing:
                continue
            original = observed._files[path]['raw'] or b''
            anchors = [(r['details']['span'][0], actual[r['id']]['details']['span'][0]) for r in items
                       if states[r['id']][0] == 'matching']
            # A qualified literal source command anchors statements before and
            # after that load, even when the parent has no retained declaration.
            expected_sites = {}
            for load in saved_loads.values():
                if load['parent'] and source_paths[saved_loads[load['parent']]['source']] == path:
                    expected_sites.setdefault(source_paths[load['source']], set()).add(load['site'][0])
            for child, sites in expected_sites.items():
                found_sites = sorted(site[0] for cmd, operand, site in observed._files[path]['commands']
                                     if cmd == 'source' and operand == child)
                if len(sites) == len(found_sites):
                    anchors.extend(zip(sorted(sites), found_sites))
            anchors.sort()
            additions = {}
            try:
                if [target for _, target in anchors] != sorted(target for _, target in anchors):
                    raise base.Invalid('source_prerequisite')
                exact = saved_setting_offsets(original, missing, payloads, saved_sources[missing[0]['source']])
                for row in sorted(missing, key=lambda r: r['details']['span']):
                    if exact:
                        additions.setdefault(exact[row['id']], []).append(payloads[row['id']])
                        continue
                    offset = next((target for source, target in anchors if source > row['details']['span'][0]), len(original))
                    placement = row['details'].get('placement')
                    file = observed._files[path]
                    if placement and placement['graph'] == file.get('setting_runtime_graph'):
                        positions = file['setting_operations']
                        if placement['slot'] < len(positions):
                            offset = min(offset, positions[placement['slot']])
                    if offset < len(original):
                        start = original.rfind(b'\n', 0, offset) + 1
                        if original[start:offset].strip(b' \t'):
                            states[row['id']] = ('unverified', 'source_prerequisite')
                            continue
                        offset = start
                    additions.setdefault(offset, []).append(payloads[row['id']])
                if not additions:
                    continue
                insertions = [(offset, (b'\n' if offset and original[offset-1:offset] != b'\n' else b'') +
                               b''.join(raw + b'\n' for raw in data)) for offset, data in sorted(additions.items())]
                candidate = sources.inserted_content(original, insertions)
                if len(candidate) > state.MAX_SOURCE or (path not in write_restrictions and
                        sources.MANAGED.search(state.utf8(candidate))):
                    raise base.Invalid('unsafe_destination')
                if path not in write_restrictions:
                    try:
                        with sources.parent(self._home, path) as (fd, name, check):
                            sources.swap_supported(fd)
                            try:
                                current, _, _ = sources.mutable_file(fd, name, limit=state.MAX_SOURCE, tracked=True)
                            except FileNotFoundError:
                                current = None
                            if current != observed._files[path]['raw']:
                                raise base.Invalid('target_changed')
                            check()
                    except (ValueError, OSError) as exc:
                        if str(exc) == 'target_changed':
                            raise
                        write_restrictions[path] = 'unsafe_destination'
                self.writes[path], self.insertions[path] = candidate, insertions
            except (ValueError, OSError) as exc:
                reason = 'source_prerequisite' if str(exc) == 'source_prerequisite' else 'unsafe_destination'
                for row in missing:
                    if reason == 'unsafe_destination':
                        self.observable_absences.discard(row['id'])
                    states[row['id']] = ('unverified', reason)

        projected = observe.project_appends(self._home, self.helper, observed, self.writes, self._check,
                                            (MANAGED_PATH,), environment=True, settings=self.settings) if self.writes else observed
        ambiguous = self._align_occurrences(projected) if self.writes else self._ambiguous
        projected_definitions = self._existing_definitions(projected) if self.writes else existing
        target_rows = {r['id']: r for r in projected.snapshot._value['items']}
        target_sources = {s['id']: s['path'] for s in projected.snapshot._value['sources']}
        unsafe_bindings = self._attribute_conflicts(projected.snapshot)
        selected_ids = {r['id'] for r in rows}
        # Replanning without blocked writes retains the user's original
        # comparison scope. A skipped later declaration is still selected.
        comparison_ids = {r['id'] for r in value._value['items']}
        # Opposite settings are preserved in place. Their relative position cannot
        # establish order for an independent declaration that we may publish.
        ordered_ids = selected_ids - {r['id'] for r in rows if r['kind'] == 'setting'
                                     and states[r['id']][0] == 'differing'}
        expected_order = environment_order(value, ordered_ids)
        actual_order = environment_order(projected.snapshot, ordered_ids)
        unordered = set(ambiguous)
        for context, expected in expected_order.items():
            unordered.update(order_conflicts(expected, actual_order.get(context, [])))
        # Only a retained, observed statement at its saved site
        # can anchor recovery in a partially understood startup file. Candidate
        # bytes and missing siblings cannot supply their own anchors.
        anchors_by_source = {}
        for row in rows:
            key = row['id']
            found = actual.get(key)
            if (states[key][0] == 'matching' and key not in unordered and key not in unsafe_bindings
                    and found and found == target_rows.get(key) and row['source'] == found['source']
                    and row['loads'] == found['loads'] and row['details']['span'] == found['details']['span']
                    and content(value, row) == content(observed.snapshot, found)):
                anchors_by_source.setdefault(row['source'], []).append(row['details']['span'][0])
        # An older narrow archive may still prove the entire original file.
        # Only declarations independently present before projection can anchor it.
        projected_loads = {visit['id']: visit for visit in projected._loads}
        for key, before in actual.items():
            if key in comparison_ids or key in unsafe_bindings or before != target_rows.get(key):
                continue
            source = projected._files[target_sources[before['source']]]['source']
            if (source != saved_sources.get(before['source']) or
                    not self._unchanged_environment_visits(source, projected_loads) or
                    content(observed.snapshot, before) != content(projected.snapshot, before)):
                continue
            if before['kind'] in ('variable', 'path-operation'):
                _, reads = state.environment.parameter_uses(before['key'], before['details']['intent'])
                if not (reads - {'HOME', 'PATH', 'path'}) and not self._environment_payload(
                        before, content(observed.snapshot, before))[0]:
                    anchors_by_source.setdefault(source['id'], []).append(before['details']['span'][0])
        if projected.codes:
            visits = {r['id']: r for r in projected._loads}
            if observe._equivalence_context(projected._files, visits, projected._issues, self._check) is None:
                anchors_by_source = None

        # Compare the reparsed publication candidate with the captured source and every
        # saved visit. A retained declaration at the same offset cannot attest opaque bytes.
        exact_setting_sources = set()
        configured_contexts = set()
        if self.settings and any(row['kind'] == 'setting' and states[row['id']][0] == 'missing' for row in rows):
            # Keep clean-target reconstruction. A retained executable predecessor
            # replaced by an ordinary command still needs the archived placement.
            configured_sources = {f['source']['id'] for f in observed._files.values()
                                  if f['source'] and f.get('setting_context_code', True)}
            configured_contexts = {v['context'] for v in observed._loads if v['source'] in configured_sources}
            for path, file in projected._files.items():
                source = file['source']
                if (source and source == saved_sources.get(source['id'])
                        and self._unchanged_environment_visits(source, projected_loads)):
                    before = observed._files[path]
                    retained = {site for site, _, effect, _ in before.get('setting_sites', ()) if effect == 'runtime'}
                    if all(site in retained and before['raw'][slice(*site)] == file['raw'][slice(*site)]
                           for site, _, effect, _ in file.get('setting_sites', ()) if effect == 'runtime'):
                        exact_setting_sources.add(source['id'])
        for row in rows:
            self._check()
            key = row['id']
            if states[key][0] not in ('matching', 'missing'):
                continue
            found = target_rows.get(key)
            if row['kind'] == 'setting' and found:
                same_site = row['details']['span'] == found['details']['span'] and row['loads'] == found['loads']
                placement = row['details'].get('placement')
                proof = exact_setting_sources if same_site and not placement else ()
                original = observed._files[source_paths[row['source']]]
                adding = states[key][0] == 'missing'
                placement_matches = bool(placement and placement['graph'] == original.get('setting_runtime_graph')
                                         and placement == found['details'].get('placement'))
                reason = observe.setting_issue(found, projected, adding=adding, exact_sources=proof,
                                               placement_matches=placement_matches)
                if (not reason and placement and not placement_matches
                        and (placement.get('source_required') or
                             adding and any(saved_loads[k]['context'] in configured_contexts for k in row['loads']))):
                    reason = 'source_prerequisite'
                if reason == 'target_conflict':
                    states[key] = ('differing', reason)
                    continue
                if not reason:
                    reason = self._environment_context(row, projected, found, selected_ids, unsafe_bindings,
                                                       anchors_by_source, adding=states[key][0] == 'missing')
            elif key in existing:
                reason = None if projected_definitions.get(key) == existing[key] else 'source_prerequisite'
            elif row['kind'] in ('alias', 'function') and projected.codes:
                # B4 independently qualifies the original interactive route,
                # parse-time bindings and later overrides in the candidate.
                routes = chains(value._value['loads'], source_paths, row['loads'])
                standard = {context for context, _ in routes} == {'interactive', 'interactive-login'} and all(
                    chain[0] == ('.zshrc', 'zshrc') for _, chain in routes)
                reason = None if standard and projected_definitions.get(key) == ('matching', 'preserve') else 'source_prerequisite'
            else:
                adding = states[key][0] == 'missing'
                reason = self._environment_context(row, projected, found, selected_ids if adding else comparison_ids,
                                                   unsafe_bindings, anchors_by_source, adding=adding)
            if key in unsafe_bindings:
                reason = 'dependency_prerequisite'
            elif key in unordered and not reason:
                reason = 'source_prerequisite'
            if (reason or not found or not self._same_environment(row, payloads[key], projected, found) or
                    chains(value._value['loads'], source_paths, row['loads']) !=
                    chains(projected._loads, target_sources, found['loads'])):
                states[key] = ('unverified', reason or 'source_prerequisite')
        for row in rows:
            key = row['id']
            path = source_paths[row['source']]
            if path in write_restrictions and key not in actual:
                if states[key][0] == 'missing' and not any(d['owner'] == key for d in value._value['dependencies']):
                    self.observable_absences.add(key)
                states[key] = ('unverified', write_restrictions[path])
                self.writes.pop(path, None)
                self.insertions.pop(path, None)
        # Publish prerequisites before their consumers even when a sourced
        # file sorts after its parent. A cyclic file group has no safe first write.
        destinations = {r['id']: source_paths[r['source']] for r in rows if states[r['id']][0] == 'missing'}
        parents = {path: set() for path in self.writes}
        for edge in value._value['dependencies']:
            owner, target = destinations.get(edge['owner']), destinations.get(edge['target']['id'])
            if edge['relation'] == 'reads' and owner in parents and target in parents and owner != target:
                parents[owner].add(target)
        ordered_writes = {}
        while parents:
            ready = sorted(path for path, required in parents.items() if not required)
            if not ready:
                for key, path in destinations.items():
                    if path in parents:
                        states[key] = ('unverified', 'dependency_prerequisite')
                break
            for path in ready:
                ordered_writes[path] = self.writes[path]
                del parents[path]
            for required in parents.values():
                required.difference_update(ready)
        self.writes = ordered_writes
        blocked = {k for k, (status, _) in states.items() if status not in ('matching', 'missing')}
        dependents = {}
        # A conflict on a tied binding blocks new writes to that sequence.
        # Existing declarations depend only on their actual preceding reads.
        by_binding = {}
        for row in rows:
            if row['kind'] in state.environment.KINDS:
                names, _ = state.environment.parameter_uses(row['key'], row['details']['intent'])
                for name in names:
                    by_binding.setdefault(name, set()).add(row['id'])
        for sequence in by_binding.values():
            for key in sequence:
                dependents.setdefault(key, set()).update(other for other in sequence - {key}
                                                        if states[other][0] == 'missing')
        for edge in value._value['dependencies']:
            if edge['relation'] == 'reads' and edge['owner'] in states:
                dependents.setdefault(edge['target']['id'], set()).add(edge['owner'])
        pending = list(blocked)
        while pending:
            for key in dependents.get(pending.pop(), set()) - blocked:
                states[key] = ('unverified', 'dependency_prerequisite')
                blocked.add(key)
                pending.append(key)
        supplied = {k for k, (status, _) in states.items() if status == 'missing'}
        pending = list(supplied)
        while pending:
            for key in dependents.get(pending.pop(), set()) - supplied - blocked:
                supplied.add(key)
                pending.append(key)
        self.pending_dependencies = {k for k in supplied if states[k][0] == 'matching'}
        self.rows = [(r, *states[r['id']]) for r in rows]
        if blocked:
            self.writes.clear()
            self.insertions.clear()
            if not excluded and len(blocked) == len(rows) and self.scripts is not None:
                self.skipped = blocked
            elif not excluded and len(blocked) < len(rows):
                # Rebuild and reparse independently without the blocked bytes.
                # Keep the full snapshot's dependency and source evidence.
                original = self.rows
                self._inspect_environment(existing, blocked)
                qualified = {r['id']: (s, p) for r, s, p in self.rows}
                if all(s in ('matching', 'missing') for s, _ in qualified.values()):
                    self.skipped = blocked
                else:
                    qualified = {key: (('unverified', 'source_prerequisite') if s == 'missing' else (s, p))
                                 for key, (s, p) in qualified.items()}
                self.rows = [(r, *qualified.get(r['id'], (s, p))) for r, s, p in original]

    def _observable_variable_absence(self, row, observed):
        """A complete lexical search can prove absence without proving a write site."""
        intent = row['details']['intent']
        writes, reads = state.environment.parameter_uses(row['key'], intent)
        if (intent.get('operator') != '=' or intent['guard'] or reads - {'HOME'} or
                set(observed.codes) - {'unsupported_context'}):
            return False
        for file in observed._files.values():
            if file['status'] == 'missing':
                continue
            if file['status'] not in ('observed', 'partial') or not file.get('all_outer_bounded'):
                return False
            for first, last in self._opaque_statements(file):
                statement = file['raw'][first:last]
                if not PARTIAL_OPTION.fullmatch(statement) and not PARTIAL_INIT.fullmatch(statement):
                    return False
            for _, name, declaration, _ in file.get('environment', ()):
                if writes & state.environment.parameter_uses(name, declaration)[0]:
                    return False
        return True

    def _same_environment(self, row, payload, observed, found):
        if row['source'] != found['source'] or row['kind'] != found['kind']:
            return False
        if row['kind'] not in state.environment.KINDS:
            return content(observed.snapshot, found) == payload
        expected = state.environment.classify(state.utf8(payload), settings=row['kind'] == 'setting')[2]
        actual = found['details']['intent']
        if expected == actual:
            return True
        if row['kind'] == 'initializer' and actual['variant'].startswith(('/', '~/', '$HOME/')):
            reason, qualified = self._environment_payload(found, content(observed.snapshot, found))
            return not reason and state.environment.classify(state.utf8(qualified))[2] == expected
        return False

    def _attribute_conflicts(self, snapshot):
        loads = {r['id']: r for r in snapshot._value['loads']}
        events = {}
        for row in snapshot._value['items']:
            if row['kind'] in ('variable', 'path-operation'):
                for load in row['loads']:
                    pos = state.load_position(loads, load, row['details']['span'][0])
                    events.setdefault(loads[load]['context'], []).append((pos, row))
        blocked = set()
        for sequence in events.values():
            readonly, integers = set(), set()
            for _, row in sorted(sequence, key=lambda pair: pair[0]):
                intent = row['details']['intent']
                for member in intent.get('members', [dict(name=row['key'], declaration=intent)]):
                    name, decl = member['name'], member['declaration']
                    if name in readonly:
                        blocked.add(row['id'])
                    if decl['form'] == 'integer' or 'i' in decl['flags']:
                        integers.add(name)
                    if name in integers and decl['operator']:
                        words = decl['words']
                        if not (len(words) == 1 and len(words[0]) == 1 and words[0][0][0] == 'literal' and
                                state.environment.static_integer(words[0][0][1])):
                            blocked.add(row['id'])
                    if decl['form'] == 'readonly' or 'r' in decl['flags']:
                        readonly.add(name)
        return blocked

    def _environment_payload(self, row, raw):
        intent = row['details']['intent']
        if row['kind'] == 'setting':
            if row['key'] == 'HISTFILE':
                name = intent['value']
                try:
                    self.provider_evidence[name] = sources.history_destination(self._home, name)
                except (ValueError, OSError):
                    return 'unsafe_destination', raw
            return None, raw
        if row['kind'] == 'initializer':
            try:
                if row['key'] in ('nvm', 'Cargo', 'asdf'):
                    return self._sourced_provider(row, raw)
                invocation = providers.executable(intent, self.provider_evidence, self._home)
                rendered = 'eval "$(' + invocation + ')"'
                if intent['guard']:
                    rendered = '[[ -o ' + intent['guard'] + ' ]] && ' + rendered
                return None, rendered.encode()
            except (OSError, ValueError, RuntimeError) as exc:
                return ('tool_missing_prerequisite' if isinstance(exc, FileNotFoundError) or
                        str(exc) == 'tool_missing_prerequisite' else 'tool_observation_prerequisite'), raw
        writes, reads = state.environment.parameter_uses(row['key'], intent)
        if any(state.environment.control_parameter(name) for name in writes | reads):
            return 'dependency_prerequisite', raw
        for member in intent.get('members', [dict(declaration=intent)]):
            for word in member['declaration']['words']:
                for part in word:
                    if part[0] == 'literal' and any(marker in part[1] for marker in ('`', '$(', '$[', '/Users/')):
                        return 'dependency_prerequisite', raw
        if row['kind'] == 'path-operation':
            for component in intent['path']['components']:
                if not component or component[0][0] != 'literal' or not component[0][1].startswith('/'):
                    continue
                if len(component) != 1:
                    return 'directory_observation_prerequisite', raw
                directory = Path(component[0][1])
                if '..' in directory.parts or (directory.parts[:2] == ('/', 'Users') and
                        not directory.is_relative_to(self._home)):
                    return 'directory_observation_prerequisite', raw
                try:
                    for part in (*reversed(directory.parents), directory):
                        providers._stamp(part, self.provider_evidence, directory=True)
                except FileNotFoundError:
                    return 'directory_missing_prerequisite', raw
                except (OSError, ValueError):
                    return 'directory_observation_prerequisite', raw
        return None, raw

    def _sourced_provider(self, row, raw):
        def read(relative, limit, *, executable=False):
            data, stamp = sources.file_state(self._home, relative, limit=limit)
            if data is None:
                raise FileNotFoundError()
            if executable and not stamp[0][2] & 0o111:
                raise providers.Unqualified('tool_observation_prerequisite')
            self.provider_evidence['home/' + relative] = [stamp, state.digest(data)]
            return data
        name = row['key']
        if name == 'Cargo':
            # rustup's POSIX env template with its portable default cargo_bin.
            # A custom installer file cannot gain source authority by its name.
            data = read('.cargo/env', 8192)
            commands = [line.strip(b' \t') for line in data.split(b'\n') if line.strip(b' \t')
                        and not line.lstrip(b' \t').startswith(b'#')]
            if commands != [b'case ":${PATH}:" in', b'*:"$HOME/.cargo/bin":*)', b';;', b'*)',
                            b'export PATH="$HOME/.cargo/bin:$PATH"', b';;', b'esac']:
                return 'tool_observation_prerequisite', raw
            with sources.parent(self._home, '.cargo/bin/rustup', read_only=True) as (fd, entry, check):
                executable = os.stat(entry, dir_fd=fd, follow_symlinks=False)
                cargo = os.stat('cargo', dir_fd=fd, follow_symlinks=False)
                if (not stat.S_ISREG(executable.st_mode) or executable.st_uid != os.getuid() or
                        executable.st_mode & 0o022 or not executable.st_mode & 0o111 or not os.path.samestat(cargo, executable)):
                    return 'tool_observation_prerequisite', raw
                if executable.st_size > 64 * 1024 * 1024:
                    return 'tool_observation_prerequisite', raw
                with os.fdopen(os.open(entry, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd), 'rb') as stream:
                    if base.stamp(os.fstat(stream.fileno())) != base.stamp(executable):
                        return 'tool_observation_prerequisite', raw
                    base.acl_safe(stream.fileno())
                    digest = state.digest(stream.read(executable.st_size + 1))
                    if (digest not in providers.RUSTUP.get(platform.machine(), ()) or
                            base.stamp(os.fstat(stream.fileno())) != base.stamp(executable)):
                        return 'tool_observation_prerequisite', raw
                    providers._native_image(stream.fileno())
                self.provider_evidence['cargo-tools'] = [base.stamp(executable), check(), digest]
        elif name == 'asdf':
            if (state.digest(read('.asdf/asdf.sh', 8192)) != 'f3d785f3a0e2c0bb55a1f0eabe6ed8eb79ff0133bc062723368b971041b82fb3' or
                    state.digest(read('.asdf/bin/asdf', 65536, executable=True)) != '641926e55ed3314ffc1f470eac10dae113c02e50973c10e39779b3596a0072f3'):
                return 'tool_observation_prerequisite', raw
        else:
            inputs = [d['target']['id'] for d in self._value._value['dependencies'] if d['owner'] == row['id'] and d['relation'] == 'reads']
            producers = [r for r in self._value._value['items'] if r['id'] in inputs and r['key'] == 'NVM_DIR']
            if len(producers) != 1:
                return 'dependency_prerequisite', raw
            parameter = producers[0]['details']['intent']
            directory = None
            words = parameter.get('words')
            if words == [[['nvm-directory', 'XDG_CONFIG_HOME', 'HOME']]]:
                xdg_ids = {d['target']['id'] for d in self._value._value['dependencies'] if d['owner'] == producers[0]['id'] and d['relation'] == 'reads'}
                xdg = [r['details']['intent'] for r in self._value._value['items'] if r['id'] in xdg_ids and r['key'] == 'XDG_CONFIG_HOME']
                if len(xdg) == 1 and not xdg[0].get('guard'):
                    if xdg[0].get('form') == 'unset' or (xdg[0].get('operator') == '=' and xdg[0].get('words') == [[]]):
                        directory = '.nvm'
                    elif xdg[0].get('operator') == '=' and xdg[0].get('words') == [[['reference', 'HOME', None, None, 'quoted'], ['literal', '/.config']]]:
                        directory = '.config/nvm'
            elif (words and len(words) == 1 and len(words[0]) == 2 and
                  words[0][0] == ['reference', 'HOME', None, None, 'quoted'] and words[0][1][0] == 'literal' and
                  words[0][1][1] in ('/.nvm', '/.config/nvm')):
                directory = words[0][1][1][1:]
            if parameter.get('guard') or parameter.get('operator') != '=' or directory is None:
                return 'dependency_prerequisite', raw
            if state.digest(read(directory + '/nvm.sh', 256 * 1024)) not in {
                    '390260ab9eb1da20e8bc0ebea2ee90f528d53e5e9f6e13b16717db4af454df9d',
                    'e7ffd3d192735da61e5eb04e68f1aca4a293af4cd0000864568d6de7aa8f6fc4'}:
                return 'tool_observation_prerequisite', raw
            if not row['details']['intent']['variant'].endswith(' --no-use'):
                # Automatic version selection can invoke an independently
                # installed Node/npm and project-specific version resolution.
                return 'tool_observation_prerequisite', raw
        return None, raw

    def _unchanged_environment_visits(self, source, loads):
        """Bind every visit and parent load site to the archived startup graph."""
        saved = self._value._value
        saved_loads = {visit['id']: visit for visit in saved['loads']}
        visits = {k for k, v in loads.items() if v['source'] == source['id']}
        if visits != {v['id'] for v in saved['loads'] if v['source'] == source['id']}:
            return False
        for key in visits:
            while key is not None:
                if loads[key] != saved_loads.get(key):
                    return False
                key = loads[key]['parent']
        return True

    def _unchanged_environment_placement(self, row, found, file, opaque, loads, original):
        """Compare bounded surrounding statements only for an existing declaration."""
        if row['kind'] not in state.environment.KINDS or found['details']['span'] != row['details']['span']:
            return False
        visits = [v for v in loads.values() if v['source'] == file['source']['id']]
        evaluators = []
        for start, end in opaque:
            statement = file['raw'][start:end]
            if statement.startswith(b'eval '):
                evaluators.append(start)
            elif not re.fullmatch(rb'setopt[ \t]+[A-Za-z_]+(?:[ \t]+[A-Za-z_]+)*', statement):
                return False
        # A subsequent startup stage cannot change the observed placement of
        # this declaration in an earlier stage. Runtime activation stays unknown.
        if original and all(state.load_position(loads, v['id'], 0)[0] >
                            state.load_position(loads, key, 0)[0]
                            for v in visits for key in found['loads'] if v['context'] == loads[key]['context']):
            return True
        if (found['loads'] != row['loads'] or file['source'] not in self._value._value['sources'] or
                not self._unchanged_environment_visits(file['source'], loads)):
            return False
        provider = row['kind'] == 'initializer'
        if not provider and not evaluators:
            return True
        # Every provider lookup must precede the first opaque statement. For
        # variables, even the last evaluator must precede the declaration.
        offset = min(start for start, _ in opaque) if provider else max(evaluators)
        positions = {}
        for key in found['loads']:
            positions.setdefault(loads[key]['context'], []).append(state.load_position(loads, key, found['details']['span'][0]))
        for visit in visits:
            points = positions.get(visit['context'])
            if points:
                boundary = state.load_position(loads, visit['id'], offset)
                if (provider and boundary <= max(points)) or (not provider and boundary >= min(points)):
                    return False
        return True

    def _anchored_environment_placement(self, row, found, file, opaque, loads, anchors, owner, adding):
        """Qualify a retained declaration or a selected append in a bounded partial graph."""
        start = found['details']['span'][0]
        before = min(start, row['details']['span'][0])
        retained = [offset for offset in anchors.get(row['source'], ()) if offset <= before]
        same_file = file['source']['id'] == row['source']
        if not retained:
            # A later startup stage cannot move an already observed literal
            # assignment in an earlier root. This proof authorizes no insertion.
            intent = row['details'].get('intent', {})
            if (adding or self.writes or same_file or row['kind'] != 'variable' or intent.get('guard')
                    or not self._literal_assignment(intent) or any(loads[key]['parent'] for key in found['loads'])
                    or content(self._value, row) != content(self.observed.snapshot, found)):
                return False
        if adding:
            original_end = len(self.observed._files[owner]['raw'] or b'')
            if (row['kind'] == 'initializer' or before < original_end or
                    [offset for offset, _ in self.insertions.get(owner, ())] != [original_end]):
                return False
        if not same_file:
            # A later independent startup stage cannot change an earlier
            # physical declaration. Never introduce an earlier lookup override.
            if (adding and row['kind'] != 'variable' or
                    any(state.load_position(loads, visit['id'], 0)[0] <= state.load_position(loads, key, 0)[0]
                        for visit in loads.values() if visit['source'] == file['source']['id']
                        for key in found['loads'] if visit['context'] == loads[key]['context'])):
                return False
        for first, last in opaque:
            statement = file['raw'][first:last]
            if same_file and row['kind'] == 'initializer' and first <= start:
                return False
            if PARTIAL_OPTION.fullmatch(statement):
                continue
            # Only the literal, argument-bounded init invocation is admitted here.
            # Its output and the runtime bindings it creates remain unobserved.
            initializer = PARTIAL_INIT.fullmatch(statement)
            if not initializer:
                return False
            if same_file and first >= max(retained):
                return False
            if adding and not same_file:
                intent = row['details']['intent']
                if not self._literal_assignment(intent):
                    return False
                prefix = initializer[1].decode().upper().replace('-', '_')
                if (not any(first < offset for offset in anchors.get(file['source']['id'], ())) or
                        not self._unchanged_environment_visits(file['source'], loads) or
                        row['key'] in ('PATH', 'path', 'HOME') or row['key'].startswith(('XDG_', prefix + '_'))):
                    return False
        return True

    @staticmethod
    def _literal_assignment(intent):
        return (intent.get('form') in ('assignment', 'export') and intent['operator'] == '=' and
                not intent['array'] and not intent['flags'] and
                all(part[0] == 'literal' for word in intent['words'] for part in word))

    def _environment_context(self, row, observed, found, selected_ids, unsafe_bindings, anchors_by_source, *, adding):
        if not found:
            return 'source_prerequisite'
        loads = {r['id']: r for r in observed._loads}
        contexts = {loads[k]['context'] for k in found['loads']}
        paths = {f['source']['id']: p for p, f in observed._files.items() if f['source']}
        active = {paths[r['source']] for r in loads.values() if r['context'] in contexts}
        for root in observed._roots:
            entry = Path(root).name
            applies = (entry == '.zshenv' or entry == '.zshrc' and bool(contexts & {'interactive', 'interactive-login'})
                       or entry in ('.zprofile', '.zlogin') and bool(contexts & {'login', 'interactive-login'}))
            if applies and observed._files[root]['status'] not in ('observed', 'partial', 'missing'):
                return 'unsafe_destination'
        owner = paths[found['source']]
        same_visits = (row['source'] == found['source'] and row['loads'] == found['loads']
                       and self._unchanged_environment_visits(observed._files[owner]['source'], loads))
        original = (same_visits and not adding and observed._files[owner]['source'] == self.observed._files[owner]['source']
                    and found['details']['span'] == row['details']['span']
                    and observed._files[owner]['source'] in self._value._value['sources'])
        anchored_route = same_visits and anchors_by_source is not None and not (set(observed.codes) - {'unsupported_context'})
        evaluations = {}
        for path in active:
            file = observed._files[path]
            if file['status'] not in ('observed', 'partial'):
                return 'source_prerequisite'
            if not file.get('all_outer_bounded'):
                return 'source_prerequisite'
            # Settings already qualified every active span and projected insertion
            # through setting_issue. Keep shared dependency and binding checks below.
            opaque = set() if row['kind'] == 'setting' else self._opaque_statements(file)
            if opaque:
                unchanged = not adding and self._unchanged_environment_placement(row, found, file, opaque, loads, original)
                if not unchanged and not (anchored_route and self._anchored_environment_placement(
                        row, found, file, opaque, loads, anchors_by_source, owner, adding)):
                    return 'source_prerequisite'
                offsets = [start for start, end in opaque if file['raw'][start:end].startswith(b'eval ')]
                for key, visit in loads.items():
                    if visit['source'] == file['source']['id'] and offsets:
                        evaluations.setdefault(visit['context'], []).extend(
                            state.load_position(loads, key, offset) for offset in offsets)
            for command, child, _ in file['commands']:
                if command == 'source' and observed._files.get(child, {}).get('status') not in ('observed', 'partial'):
                    return 'source_prerequisite'
        if any(code in ('ambiguous_zdotdir', 'startup_unresolved') for _, code in observed._issues):
            return 'source_prerequisite'
        if row['kind'] not in state.environment.KINDS:
            return None
        if row['kind'] == 'initializer':
            family = row['key']
            invocation = found['details']['intent']['variant'].split()
            full_pyenv = family == 'pyenv' and '--path' not in invocation
            if family == 'pyenv' and (full_pyenv or '--no-rehash' not in invocation):
                # Upstream emits "command pyenv rehash" after prepending its
                # shims. Bind that second lookup independently of the launcher.
                try:
                    with sources.parent(self._home, '.pyenv/shims/pyenv', read_only=True) as (fd, name, check):
                        os.stat(name, dir_fd=fd, follow_symlinks=False)
                        return 'tool_observation_prerequisite'
                except FileNotFoundError:
                    pass
                except (ValueError, OSError):
                    return 'tool_observation_prerequisite'
                bin_dir = str(Path(found['details']['intent']['variant'].split()[0]).parent)
                for visit in found['loads']:
                    at = state.load_position(loads, visit, found['details']['span'][0])
                    preceding = []
                    for event in observed.snapshot._value['items']:
                        if event['kind'] not in ('path-operation', 'initializer'):
                            continue
                        for edge in event['loads']:
                            pos = state.load_position(loads, edge, event['details']['span'][0])
                            if loads[edge]['context'] == loads[visit]['context'] and pos < at:
                                preceding.append((pos, event))
                    if not preceding:
                        return 'tool_observation_prerequisite'
                    last = max(preceding, key=lambda pair: pair[0])[1]
                    intent = last['details']['intent']
                    if (last['kind'] != 'path-operation' or intent['guard'] or
                            intent['path']['action'] not in ('replace', 'prefix') or
                            intent['path']['components'][:1] != [[['literal', bin_dir]]]):
                        return 'tool_observation_prerequisite'
                    if full_pyenv:
                        # pyenv-commands interpolates sh-* command names from
                        # every search directory into the generated function.
                        components = intent['path']['components']
                        if intent['path']['action'] != 'replace' or len(components) > 32:
                            return 'tool_observation_prerequisite'
                        for parts in components:
                            if len(parts) != 1 or parts[0][0] != 'literal' or not parts[0][1].startswith('/'):
                                return 'tool_observation_prerequisite'
                            try:
                                directory = Path(parts[0][1])
                                for parent in (*reversed(directory.parents), directory):
                                    providers._stamp(parent, self.provider_evidence, directory=True)
                                with os.scandir(directory) as entries:
                                    if any(i >= 8192 or e.name.startswith('pyenv-sh-') for i, e in enumerate(entries)):
                                        return 'tool_observation_prerequisite'
                            except (OSError, ValueError):
                                return 'tool_observation_prerequisite'
            controls = {'Homebrew': ('HOMEBREW_', 'PATH_HELPER_', 'XDG_CONFIG_HOME'), 'pyenv': ('PYENV_',),
                        'mise': ('MISE_',), 'fnm': ('FNM_',), 'direnv': ('DIRENV_',), 'asdf': ('ASDF_',),
                        'Cargo': ('CARGO_', 'RUSTUP_'), 'nvm': ('NVM_',)}[family]
            conventional = {'PYENV_ROOT': '/.pyenv', 'ASDF_DIR': '/.asdf', 'ASDF_DATA_DIR': '/.asdf',
                            'CARGO_HOME': '/.cargo', 'RUSTUP_HOME': '/.rustup', 'XDG_CONFIG_HOME': '/.config'}
            for path in active:
                for _, name, intent, _ in observed._files[path].get('environment', ()):
                    if 'provider' in intent:
                        continue
                    for member in intent.get('members', [dict(name=name, declaration=intent)]):
                        key, declaration = member['name'], member['declaration']
                        if not key.startswith(controls) or (family == 'nvm' and key == 'NVM_DIR'):
                            continue
                        words = declaration['words']
                        if declaration['form'] == 'unset':
                            continue
                        if (key in conventional and declaration['operator'] == '=' and len(words) == 1 and
                                len(words[0]) == 2 and words[0][0] in (['home', 'HOME'],
                                ['reference', 'HOME', None, None, 'quoted'], ['reference', 'HOME', None, None, 'bare']) and
                                words[0][1] == ['literal', conventional[key]]):
                            continue
                        return 'tool_observation_prerequisite'
        writes, reads = state.environment.parameter_uses(row['key'], row['details']['intent'])
        saved_edges = {d['target']['id'] for d in self._value._value['dependencies'] if d['owner'] == row['id'] and d['relation'] == 'reads'}
        observed_reads = {}
        for edge in observed.snapshot._value['dependencies']:
            if edge['relation'] == 'reads':
                observed_reads.setdefault(edge['owner'], set()).add(edge['target']['id'])
        actual_edges = observed_reads.get(row['id'], set())
        # Earlier narrow snapshots carry a whole-source fingerprint. A
        # byte-exact reconstruction can attest a retained producer, including
        # when the selected consumer is missing. Projected-only rows cannot.
        siblings = set()
        exact_owner = (same_visits and observed._files[owner]['source'] in self._value._value['sources']
                       and row['details']['span'] == found['details']['span'])
        if exact_owner and row['kind'] in ('variable', 'path-operation'):
            retained = {item['id']: item for item in self.observed.snapshot._value['items']}
            archived = {item['id'] for item in self._value._value['items']}
            for other in observed.snapshot._value['items']:
                if (retained.get(other['id']) != other or other['id'] in archived or other['id'] in unsafe_bindings or
                        other['source'] != row['source'] or other['loads'] != found['loads'] or
                        other['kind'] not in ('variable', 'path-operation')):
                    continue
                if content(self.observed.snapshot, retained[other['id']]) != content(observed.snapshot, other):
                    continue
                if other['id'] in actual_edges:
                    _, inputs = state.environment.parameter_uses(other['key'], other['details']['intent'])
                    if other['id'] in observed_reads or inputs - {'HOME', 'PATH', 'path'} or self._environment_payload(
                            other, content(observed.snapshot, other))[0]:
                        continue
                siblings.add(other['id'])
        if saved_edges != actual_edges - siblings:
            return 'dependency_prerequisite'
        # An explicit reference to another custom variable requires a qualified
        # preceding binding in each context where the consumer can run.
        declarations = row['details']['intent'].get('members', [dict(declaration=row['details']['intent'])])
        required = set()
        for member in declarations:
            for word in member['declaration'].get('words', []):
                required.update(part[1] for part in word if part[0] == 'reference' and part[2] is None)
        if row['kind'] == 'initializer':
            required.update(reads)
        required.intersection_update(reads)
        required.difference_update(('HOME', 'PATH', 'path'))
        for visit in found['loads']:
            context = loads[visit]['context']
            guard = found['details']['intent']['guard']
            if (guard == 'login' and context not in ('login', 'interactive-login') or
                    guard == 'interactive' and context not in ('interactive', 'interactive-login')):
                continue
            position = state.load_position(loads, visit, found['details']['span'][0])
            latest = {}
            for producer in observed.snapshot._value['items']:
                if producer['id'] not in actual_edges:
                    continue
                declaration = producer['details']['intent']
                condition = declaration['guard']
                applies = (not condition or condition == guard or
                           condition == 'interactive' and context in ('interactive', 'interactive-login') or
                           condition == 'login' and context in ('login', 'interactive-login'))
                members = declaration.get('members', [dict(name=producer['key'], declaration=declaration)])
                for member in members:
                    name = member['name']
                    if name not in required:
                        continue
                    for k in producer['loads']:
                        point = state.load_position(loads, k, producer['details']['span'][0])
                        if loads[k]['context'] == context and point < position and (
                                name not in latest or latest[name][0] < point):
                            binding = member['declaration']
                            established = binding['form'] != 'unset' and (
                                producer['id'] in saved_edges or binding.get('operator') == '=')
                            latest[name] = (point, applies and established)
            if any(name not in latest or not latest[name][1] or
                   any(latest[name][0] < barrier < position for barrier in evaluations.get(context, ()))
                   for name in required):
                return 'dependency_prerequisite'
        for other in observed.snapshot._value['items']:
            if other['id'] == row['id'] or other['kind'] not in state.environment.KINDS:
                continue
            if not any(loads[k]['context'] in contexts for k in other['loads']):
                continue
            changes, uses = state.environment.parameter_uses(other['key'], other['details']['intent'])
            if adding and other['kind'] == 'initializer' and other['id'] not in self._selected:
                # A changed binding must not redirect an existing source or
                # provider lookup that was never authorized for this Restore.
                lookup = {'PATH', 'path'} | uses
                prefixes = {'asdf': ('ASDF_',), 'Homebrew': ('HOMEBREW_',), 'pyenv': ('PYENV_',),
                            'nvm': ('NVM_',), 'fnm': ('FNM_',), 'mise': ('MISE_',),
                            'direnv': ('DIRENV_',), 'Cargo': ('CARGO_', 'RUSTUP_')}
                lookup.update(name for name in writes if name.startswith(prefixes[other['key']]))
                if writes & lookup and any(loads[a]['context'] == loads[b]['context'] and
                        state.load_position(loads, a, found['details']['span'][0]) <
                        state.load_position(loads, b, other['details']['span'][0])
                        for a in found['loads'] for b in other['loads']):
                    return 'dependency_prerequisite'
            if other['id'] not in selected_ids and other['id'] not in siblings and changes & (writes | reads):
                return 'dependency_prerequisite'
        return None

    def _inspect(self):
        # Definition conformity precedes destination planning. A qualified
        # existing declaration needs no permission to append to its source.
        definitions = [r for r in self._value._value['items'] if r['kind'] != 'script']
        if any(r['condition'] == 'conditional' for r in self._value._value['loads']):
            self.rows = [(r, 'unverified', 'source_prerequisite') for r in definitions]
            return
        existing = self._existing_definitions(self.observed)
        if len(existing) == len(definitions):
            self.rows = [(r, *existing[r['id']]) for r in definitions]
            return
        self._inspect_destination()
        self.rows = [(r, *existing[r['id']]) if r['id'] in existing else (r, s, p) for r, s, p in self.rows]
        if existing and not self.writes:
            # A matching original declaration does not authorize moving its
            # missing siblings into a fallback that rejected the mixed layout.
            self.rows = [(r, 'unverified', 'source_prerequisite') if s == 'missing' else (r, s, p)
                         for r, s, p in self.rows]

    def _existing_definitions(self, observed):
        value = self._value
        actual = {r['id']: r for r in observed.snapshot._value['items']}
        present = [r for r in value._value['items'] if r['kind'] in ('alias', 'function') and r['id'] in actual]
        if not present:
            return {}
        if any(code != 'unsupported_context' for code in observed.codes):
            return {}
        loads = {r['id']: r for r in observed._loads}
        barriers = observe._equivalence_context(observed._files, loads, observed._issues, self._check)
        if barriers is None:
            return {}
        paths = {r['id']: r['path'] for r in value._value['sources']}
        actual_paths = {r['id']: r['path'] for r in observed.snapshot._value['sources']}
        try:
            expected_order = [r['id'] for r in state.declaration_order(state.select(value, [r['id'] for r in present]))]
            actual_order = [r['id'] for r in state.declaration_order(state.select(observed.snapshot, expected_order))]
        except state.Invalid:
            return {r['id']: ('unverified', 'source_prerequisite') for r in present}
        if expected_order != actual_order and not self.environment:
            return {r['id']: ('unverified', 'source_prerequisite') for r in present}
        misplaced = order_conflicts(expected_order, actual_order)
        result = {}
        for item in present:
            self._check()
            if item['id'] in misplaced:
                result[item['id']] = ('unverified', 'source_prerequisite')
                continue
            found = actual[item['id']]
            path = paths[item['source']]
            # Managed-file integration retains its own strict qualification.
            if (path == MANAGED_PATH or actual_paths[found['source']] != path or
                    chains(value._value['loads'], paths, item['loads']) !=
                    chains(observed._loads, actual_paths, found['loads']) or
                    any(d['owner'] == item['id'] for d in value._value['dependencies'])):
                continue
            # Reuse the observer's bounded barriers: unrelated earlier startup
            # initialization is outside scope; a later dynamic override is not.
            if any(override and position > state.load_position(loads, key, found['details']['span'][0])
                   for key in found['loads'] for position, override in barriers.get(loads[key]['context'], [])):
                continue
            saved = content(value, item)
            if not self._definition_valid(item, saved):
                continue
            same = found['kind'] == item['kind'] and content(observed.snapshot, found) == saved
            result[item['id']] = ('matching', 'preserve') if same else ('differing', 'target_conflict')
        return result

    def _inspect_destination(self):
        value, observed, home = self._value, self.observed, self._home
        paths = {row['id']: row['path'] for row in value._value['sources']}
        actual_paths = {f['source']['id']: p for p, f in observed._files.items() if f['source']}
        actual = {row['key']: row for row in observed.snapshot._value['items']}
        selected_paths = {paths[r['source']] for r in value._value['items'] if r['kind'] != 'script'}
        present_paths = {p for p in selected_paths if observed._files.get(p, {}).get('status') in ('observed', 'partial')}
        load_order_matches = all(
            [paths[r['source']] for r in value._value['loads'] if r['context'] == context and paths[r['source']] in present_paths] ==
            [actual_paths[r['source']] for r in observed._loads if r['context'] == context and actual_paths[r['source']] in present_paths]
            for context in observe.CONTEXTS)
        managed_paths = {p for p, f in observed._files.items() if f['raw'] is not None
                         and (f['stamp'][1][1] or sources.MANAGED.search(f['raw'].decode('utf-8', errors='replace')))}

        # Unknown bindings or unresolved loads cannot establish absence. Earlier
        # unrelated initialization can be admitted only after a prospective Check.
        partial = bool(observed.codes) and observe._equivalence_context(observed._files,
            {r['id']: r for r in observed._loads}, observed._issues, self._check) is not None
        try:
            ordered = state.declaration_order(value)
        except state.Invalid:
            self.rows = [(r, 'unverified', 'source_prerequisite') for r in value._value['items'] if r['kind'] != 'script']
            return
        def original_route(item):
            path = paths[item['source']]
            expected = chains(value._value['loads'], paths, item['loads'])
            if (len(expected) != 2 or {r[0] for r in expected} != {'interactive', 'interactive-login'} or
                    not all(chain[0] == ('.zshrc', 'zshrc') and all(entry == 'source' for _, entry in chain[1:]) for _, chain in expected)):
                return False
            target = observed._files.get(path)
            if target is None:
                return False
            if path == '.zshrc' and target['status'] == 'missing':
                return True
            selected = [r['id'] for r in observed._loads if actual_paths[r['source']] == path]
            return chains(observed._loads, actual_paths, selected) == expected
        if not all(original_route(item) for item in ordered):
            relevant = {p for item in ordered for _, chain in chains(value._value['loads'], paths, item['loads'])
                        for p, _ in chain} | {MANAGED_PATH, '.zshrc'}
            self._inspect_managed(ordered, not relevant.isdisjoint(managed_paths))
            return
        grouped = {}
        source_bytes = sum(len(f['raw'] or b'') for f in observed._files.values())
        definitions = sum(f['definition_count'] for f in observed._files.values())
        response_bytes = sum(f['response_bytes'] for f in observed._files.values())
        load_count = len(observed._loads)
        for item in value._value['items']:
            if item['kind'] == 'script':
                continue
            self._check()
            path, saved = paths[item['source']], content(value, item)
            status, reason = 'unverified', 'source_prerequisite'
            expected = chains(value._value['loads'], paths, item['loads'])
            # B3 never invents load relationships. Only a direct standard .zshrc
            # may be created; a descendant must already have the same static loads.
            supported = (len(expected) == 2 and {r[0] for r in expected} == {'interactive', 'interactive-login'}
                         and all(chain[0] == ('.zshrc', 'zshrc') and
                                 all(entry == 'source' for _, entry in chain[1:]) for _, chain in expected))
            target = observed._files.get(path)
            competing = sum(f['names'].count(item['key']) + f['alias_names'].count(item['key']) for f in observed._files.values()) > 1
            if observe._shadows_source([item['key']], []):
                reason = 'source_prerequisite'
            elif any(p in managed_paths for _, chain in expected for p, _ in chain):
                reason = 'managed_source_prerequisite'
            elif competing:
                status, reason = 'differing', 'target_conflict'
            elif observed.codes and (not partial or item['key'] in actual):
                reason = 'unsafe_destination' if 'unsafe_source' in observed.codes else 'source_prerequisite'
            elif not load_order_matches:
                reason = 'source_prerequisite'
            elif any(d['owner'] == item['id'] for d in value._value['dependencies']):
                reason = 'dependency_prerequisite'
            elif supported and target is not None:
                selected = [r['id'] for r in observed._loads if actual_paths[r['source']] == path]
                actual_chains = chains(observed._loads, actual_paths, selected)
                direct_missing = (path == '.zshrc' and target['status'] == 'missing' and
                                  all(len(chain) == 1 for _, chain in expected))
                if actual_chains == expected or direct_missing:
                    found = actual.get(item['key'])
                    if found is not None:
                        status = ('matching' if found['kind'] == item['kind'] and actual_paths[found['source']] == path and
                                  content(observed.snapshot, found) == saved else 'differing')
                        reason = 'preserve' if status == 'matching' else 'target_conflict'
                    elif any(item['key'] in f['names'] + f['alias_names'] for f in observed._files.values()):
                        status, reason = 'differing', 'target_conflict'
                    else:
                        status, reason = 'missing', 'add' if target['raw'] is not None else 'create'
            # Structural bytes in an untrusted Bundle must actually describe one
            # complete named unit. B1 integrity alone is not a parser receipt.
            valid = self._definition_valid(item, saved)
            if not valid:
                status, reason = 'unverified', 'definition_invalid'
            self.rows.append((item, status, reason))
            if status == 'missing':
                grouped.setdefault(path, []).append(item)
        # Exact bytes do not prove the selected declarations retained their
        # relative order. Check matching units too, including a no-op target.
        for path in {paths[r['source']] for r in value._value['items'] if r['kind'] != 'script'}:
            ordered = sorted((r for r in value._value['items'] if r['kind'] != 'script' and paths[r['source']] == path),
                             key=lambda r: r['details']['span'])
            present = [r for r in ordered if r['key'] in actual and actual_paths[actual[r['key']]['source']] == path]
            if present != sorted(present, key=lambda r: actual[r['key']]['details']['span']):
                self.rows = [(r, 'unverified', 'source_prerequisite') if r in ordered and s != 'differing' else (r, s, p)
                             for r, s, p in self.rows]
                grouped.pop(path, None)
        for path, items in grouped.items():
            self._check()
            items.sort(key=lambda r: r['details']['span'])
            ordered = sorted((r for r in value._value['items'] if r['kind'] != 'script' and paths[r['source']] == path),
                             key=lambda r: r['details']['span'])
            present = sorted((r for r in ordered if r['key'] in actual and actual_paths[actual[r['key']]['source']] == path),
                             key=lambda r: actual[r['key']]['details']['span'])
            # Append cannot insert a declaration before a retained selected unit
            # or before a source statement that loads another selected unit.
            source_sites = [load['site'][0] for load in value._value['loads'] if load['parent'] is not None
                            and paths[next(r for r in value._value['loads'] if r['id'] == load['parent'])['source']] == path]
            if present != ordered[:len(present)] or any(item['details']['span'][0] < site for item in items for site in source_sites):
                self.rows = [(r, 'unverified', 'source_prerequisite') if r in items else (r, s, p) for r, s, p in self.rows]
                continue
            original = observed._files[path]['raw'] or b''
            candidate = original + (b'\n' if original and not original.endswith(b'\n') else b'')
            candidate += b''.join(content(value, r) + b'\n' for r in items)
            try:
                if sources.MANAGED.search(candidate.decode('utf-8')):
                    raise base.Invalid('external_owner')
                if len(candidate) > state.MAX_SOURCE:
                    raise base.Invalid('source_limit')
                response = self.helper.parse(candidate, cancelled=self._check)
                units, names, commands, opaque, count = observe._outer(candidate, response, home)
                declarations = units + [(name, candidate[slice(*span)], dict(span=span))
                    for kind, name, span in commands if kind == 'alias']
                count += sum(kind == 'alias' for kind, _, _ in commands)
                if (opaque and not partial) or any(sum(k == r['key'] for k, _, _ in declarations) != 1 or
                    not any(k == r['key'] and data == content(value, r) for k, data, _ in declarations) for r in items):
                    raise base.Invalid('candidate_invalid')
                with sources.parent(home, path) as (fd, name, check):
                    sources.swap_supported(fd)
                    try:
                        current, _, _ = sources.mutable_file(fd, name, limit=state.MAX_SOURCE, tracked=True)
                    except FileNotFoundError:
                        current = b''
                    if current != original:
                        raise base.Invalid('target_changed')
                    check()
                self.writes[path] = candidate
                source_bytes += len(candidate) - len(original)
                definitions += count - observed._files[path]['definition_count']
                response_bytes += len(response) - observed._files[path]['response_bytes']
                if observed._files[path]['raw'] is None:
                    load_count += 2  # Only the standard interactive .zshrc may be created.
            except (OSError, ValueError) as exc:
                if isinstance(exc, observe.Invalid) or (isinstance(exc, client.Invalid) and exc.code in ('cancelled', 'process_cleanup_failed')):
                    raise
                reason = 'managed_source_prerequisite' if str(exc) == 'external_owner' else 'unsafe_destination'
                self.rows = [(r, 'unverified', reason) if r in items else (r, s, p) for r, s, p in self.rows]
        if (source_bytes > state.MAX_SOURCE_TOTAL or definitions > state.MAX_DECLARATIONS or
                response_bytes > state.MAX_MANIFEST or load_count > state.MAX_LOADS):
            raise observe.Invalid('resource_limit')
        if partial and self.writes:
            # Use the same independent parser/lexer, load chains, relative order
            # and later-override checks as post-Restore Check, before publication.
            projected = observe.project_appends(home, self.helper, observed, self.writes, self._check, (MANAGED_PATH,))
            qualified = self._existing_definitions(projected)
            if any(qualified.get(r['id']) != ('matching', 'preserve') for r in value._value['items'] if r['kind'] != 'script'):
                self.writes.clear()
                self.rows = [(r, 'unverified', 'source_prerequisite') if s == 'missing' else (r, s, p)
                             for r, s, p in self.rows]

    def _definition_valid(self, item, saved):
        response = self.helper.parse(saved, cancelled=self._check)
        units, _, commands, opaque, _ = observe._outer(saved, response, self._home)
        if item['kind'] == 'alias':
            # A literal alias declaration is saved state. Availability of tools,
            # operands and services at invocation is not declaration conformity.
            # Legacy capabilities 1–5 keep their existing prerequisite policy.
            return not units and not opaque and commands == [('alias', item['key'], [0, len(saved)])]
        relative = {key: [n - item['details']['span'][0] for n in item['details'][key]]
                    for key in ('span', 'name', 'body')}
        return (len(units) == 1 and units[0][0] == item['key'] and units[0][1] == saved and not commands and not opaque and
                all(units[0][2][key] == span for key, span in relative.items()))

    def _inspect_managed(self, ordered, externally_managed):
        """Portable fallback, using the same observer, parser and append publisher.

        Only a safe standard .zshrc can integrate this controlled destination.
        Missing original directories/source commands are never reconstructed.
        """
        observed, home, value = self.observed, self._home, self._value
        target, startup = observed._files[MANAGED_PATH], observed._files.get('.zshrc')
        raw = target['raw']
        paths = {f['source']['id']: p for p, f in observed._files.items() if f['source']}
        blocked = 'managed_source_prerequisite' if externally_managed else None
        if any(code != 'source_unresolved' or path != MANAGED_PATH for path, code in observed._issues):
            blocked = 'unsafe_destination' if 'unsafe_source' in observed.codes else 'source_prerequisite'
        if (startup is None or startup['status'] not in ('missing', 'observed') or
                target['status'] not in ('missing', 'observed') or
                any(r['condition'] == 'conditional' for r in value._value['loads']) or
                (self.scripts and any(s['path'] in (MANAGED_PATH, '.zshrc') for s in self.scripts['scripts']))):
            blocked = blocked or 'source_prerequisite'
        if raw is not None and (not raw.startswith(MANAGED_HEADER) or any(c[0] != 'alias' for c in target['commands'])):
            blocked = 'target_conflict'
        load_ids = [r['id'] for r in observed._loads if paths[r['source']] == MANAGED_PATH]
        actual_chains = chains(observed._loads, paths, load_ids)
        expected = [(c, (('.zshrc', 'zshrc'), (MANAGED_PATH, 'source'))) for c in ('interactive', 'interactive-login')]
        integrated = actual_chains == expected
        source_commands = [c for f in observed._files.values() for c in f['commands'] if c[0] == 'source' and c[1] == MANAGED_PATH]
        direct_commands = [c for c in (startup or {}).get('commands', []) if c[0] == 'source' and c[1] == MANAGED_PATH]
        if source_commands and (len(source_commands) != 1 or len(direct_commands) != 1 or (raw is not None and not integrated)):
            blocked = 'source_prerequisite'
        # Existing definitions outside the controlled destination are never moved
        # or duplicated, even when their bytes happen to match.
        physical = {name: (data, details) for name, data, details in target['units']}
        physical.update({name: (raw[slice(*span)], dict(mode='ordinary', span=span))
                         for kind, name, span in target['commands'] if kind == 'alias'})
        if not integrated and set(physical) - {item['key'] for item in ordered}:
            # A marker is not authorization to activate dormant, unselected
            # declarations. Interrupted selected-only publication can be retried.
            blocked = 'source_prerequisite'
        missing = []
        for item in ordered:
            self._check()
            saved = content(value, item)
            status, reason = 'unverified', blocked or 'source_prerequisite'
            conflicts = any(item['key'] in f['names'] + f['alias_names'] for p, f in observed._files.items() if p != MANAGED_PATH)
            found = physical.get(item['key'])
            mentions = target['names'].count(item['key']) + target['alias_names'].count(item['key'])
            if not self._definition_valid(item, saved):
                reason = 'definition_invalid'
            elif any(d['owner'] == item['id'] for d in value._value['dependencies']):
                reason = 'dependency_prerequisite'
            elif observe._shadows_source([item['key']], []):
                reason = 'source_prerequisite'
            elif conflicts or mentions > 1 or (found and (found[0] != saved or ('mode' in found[1]) != (item['kind'] == 'alias'))):
                status, reason = 'differing', 'target_conflict'
            elif blocked is None:
                status, reason = ('matching', 'preserve') if found and integrated else ('missing', 'add' if raw is not None else 'create')
                if not found:
                    missing.append(item)
            self.rows.append((item, status, reason))
        if any(s not in ('matching', 'missing') for _, s, _ in self.rows):
            return
        retained = [r for r in ordered if r['key'] in physical]
        if (retained != ordered[:len(retained)] or
                retained != sorted(retained, key=lambda r: physical[r['key']][1]['span'])):
            self.rows = [(r, 'unverified', 'source_prerequisite') for r in ordered]
            return
        candidates = {}
        if missing:
            candidate = raw if raw is not None else MANAGED_HEADER
            candidate += b'\n' if candidate and not candidate.endswith(b'\n') else b''
            candidate += b''.join(content(value, item) + b'\n' for item in missing)
            candidates[MANAGED_PATH] = candidate
        if not integrated and not direct_commands:
            original = startup['raw'] or b''
            candidates['.zshrc'] = original + (b'\n' if original and not original.endswith(b'\n') else b'') + MANAGED_SOURCE
        source_bytes = sum(len(f['raw'] or b'') for f in observed._files.values())
        definitions = sum(f['definition_count'] for f in observed._files.values())
        response_bytes = sum(f['response_bytes'] for f in observed._files.values())
        try:
            for path, candidate in candidates.items():
                self._check()
                if len(candidate) > state.MAX_SOURCE or sources.MANAGED.search(candidate.decode('utf-8')):
                    raise base.Invalid('candidate_invalid')
                response = self.helper.parse(candidate, cancelled=self._check)
                _, _, commands, opaque, count = observe._outer(candidate, response, home)
                if opaque:
                    raise base.Invalid('candidate_invalid')
                count += sum(c[0] == 'alias' for c in commands)
                previous = observed._files[path]
                with sources.parent(home, path) as (fd, name, check):
                    sources.swap_supported(fd)
                    try:
                        current, _, _ = sources.mutable_file(fd, name, limit=state.MAX_SOURCE, tracked=True)
                    except FileNotFoundError:
                        current = b''
                    if current != (previous['raw'] or b''):
                        raise base.Invalid('target_changed')
                    check()
                source_bytes += len(candidate) - len(previous['raw'] or b'')
                definitions += count - previous['definition_count']
                response_bytes += len(response) - previous['response_bytes']
            if (source_bytes > state.MAX_SOURCE_TOTAL or definitions > state.MAX_DECLARATIONS or
                    response_bytes > state.MAX_MANIFEST or len(observed._loads) + (0 if integrated else 4) > state.MAX_LOADS):
                raise observe.Invalid('resource_limit')
            self.writes.update(candidates)
        except (OSError, ValueError) as exc:
            if isinstance(exc, observe.Invalid) or (isinstance(exc, client.Invalid) and exc.code in ('cancelled', 'process_cleanup_failed')):
                raise
            self.rows = [(r, 'unverified', 'unsafe_destination') for r in ordered]


def plan(value, home, **options):
    return Plan(value, home, **options)


def publish(value, home, *, expected=None, helper=None, cancelled=lambda: False, approvals=()):
    current = plan(value, home, helper=helper, cancelled=cancelled)
    if expected is not None and current.evidence != expected:
        raise base.Invalid('target_changed')
    skipped = current.skipped
    if any(s not in ('matching', 'missing') and r['id'] not in skipped for r, s, _ in current.rows):
        raise base.Invalid('target_conflict')
    if skipped and not current.writes and not any(s == 'missing' for _, s, _ in current.rows):
        raise base.Invalid('target_conflict')
    required = {r['id'].removeprefix('shell-script:') for r, status, _ in current.rows
                if r['kind'] == 'script' and status == 'missing'}
    if set(approvals) != required:
        raise base.Invalid('script_consent_required')
    changed = False
    try:
        if current.scripts is not None:
            def validate_sources(ignore_pending=()):
                fresh_sources = observe.observe(home, current.helper, cancelled=cancelled,
                    _ignore_pending=ignore_pending, aliases=True, independent=True, _additional_sources=(MANAGED_PATH,),
                    environment=current.environment, settings=current.settings)
                if fresh_sources._inputs != current.observed._inputs:
                    raise base.Invalid('target_changed')
            changed = state.legacy().publish(current.scripts, home,
                expected=current.script_evidence, approvals=approvals,
                source_files=current.observed._inputs if current.observed is not None else None,
                validate_sources=validate_sources if current.observed is not None else None)
            fresh = plan(value, home, helper=current.helper, cancelled=cancelled)
            if fresh.provider_evidence != current.provider_evidence or (
                    current.observed is not None and fresh.observed._inputs != current.observed._inputs):
                raise base.PublicationUncertain('source_changed')
            current = fresh
            if current.skipped != skipped or any(s not in ('matching', 'missing') and r['id'] not in skipped for r, s, _ in current.rows):
                raise base.PublicationUncertain('source_changed')
        for path in (list(current.writes) if current.environment else sorted(current.writes)):
            if path not in current.writes:
                raise base.Invalid('target_changed')
            candidate, wanted = current.writes[path], current.evidence
            def validate(ignore_pending=()):
                fresh = plan(value, home, helper=current.helper, cancelled=cancelled, ignore_pending=ignore_pending)
                if fresh.evidence != wanted:
                    raise base.Invalid('target_changed')
            sources.publish_content(home, path, candidate, validate, limit=state.MAX_SOURCE, tracked=True,
                                    insertions=current.insertions.get(path))
            changed = True
            fresh = plan(value, home, helper=current.helper, cancelled=cancelled)
            # Other observed sources and their metadata must remain identical.
            if (fresh.skipped != skipped or current.provider_evidence != fresh.provider_evidence or
                    fresh.observed._files.get(path, {}).get('raw') != candidate or
                    {p: f for p, f in fresh.observed._inputs.items() if p != path} !=
                    {p: f for p, f in current.observed._inputs.items() if p != path}):
                raise base.PublicationUncertain('source_changed')
            current = fresh
        if current.skipped != skipped or any(s != 'matching' and r['id'] not in skipped for r, s, _ in current.rows):
            raise base.PublicationUncertain('verification_failed')
    except BaseException as exc:
        if changed or isinstance(exc, base.PublicationUncertain):
            raise base.PublicationUncertain('publication_uncertain') from exc
        raise
    return changed


def main():
    command, path = sys.argv[1:]
    value = load(path)
    if command == 'validate':
        return 0
    if command == 'predicate':
        print('function_definition')
        return 0
    if command in ('inspect', 'compare'):
        result = plan(value, os.environ['HOME'])
        for item, status, reason in result.report_rows(compare=command == 'compare'):
            print(item['id'], status, reason, sep='\t')
        print('scope', result.coverage, 'activation_unknown' if result.coverage == 'information' else 'source_prerequisite', sep='\t')
        return 0
    if command == 'apply':
        try:
            changed = publish(value, os.environ['HOME'], expected=os.environ.get('MACSEED_SHELL_EXPECTED_EVIDENCE'),
                              approvals=json.loads(os.environ.get('MACSEED_SHELL_SCRIPT_APPROVALS', '[]')))
            print('changed' if changed else 'matching')
            return 0
        except base.PublicationUncertain:
            print('changed\ndiagnostic\tshell_publication_uncertain')
            return 2
        except (OSError, ValueError):
            print('diagnostic\tshell_function_restore_blocked')
            return 2
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError):
        sys.exit(2)
