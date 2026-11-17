"""Bounded exact-definition Restore/Check; never evaluates Shell source.

The B2A observer owns discovery and parser transport. The existing Shell
publisher owns safe append, metadata, competing writers and recovery fences.
"""
import importlib.util
import json
import os
from pathlib import Path
import re
import sys
import time

spec = importlib.util.spec_from_file_location('shell_function_capture', Path(__file__).with_name('capture.py'))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
observe, state, client = capture.observe, capture.state, capture.client
sources, base = observe.sources, observe.base
ROOT = Path(__file__).resolve().parents[2]
PLAN_SECONDS = 60
MANAGED_PATH = '.macseed-shell-definitions.zsh'
MANAGED_HEADER = b'# Macseed portable definitions 1\n'
MANAGED_SOURCE = ('source "$HOME/' + MANAGED_PATH + '"\n').encode()


def load(path):
    path = Path(path)
    raw = base.read_file(str(path), private=True, limit=state.MAX_MANIFEST)
    state.require(raw.startswith(state.MAGIC), 'unsupported_contract')
    manifest = state._json(raw[len(state.MAGIC):], state.MAX_MANIFEST)
    state.keys(manifest, 'schema semantic_profile resource_profile required_contracts sources loads items dependencies content_refs')
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


class Plan:
    def __init__(self, value, home, *, helper=None, cancelled=lambda: False, ignore_pending=()):
        raw, payloads = state.encode(value)
        if not value._value['items']:
            raise base.Invalid('unsupported_contract')
        self.rows, self.writes = [], {}
        self.observed = None
        self.helper = helper
        self.evidence = None
        self._value, self._home, self._cancelled = value, home, cancelled
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
                self.observed = observe.observe(home, self.helper, cancelled=self._check, _ignore_pending=ignore_pending, aliases=True,
                                                _additional_sources=(MANAGED_PATH,))
                inputs.update(parser=self.helper._manifest_sha256,
                    files={p: dict(status=f['status'], stamp=f['stamp'], digest=state.digest(f['raw']) if f['raw'] is not None else None)
                           for p, f in self.observed._files.items()}, loads=self.observed._loads)
            if self.scripts is not None:
                self.script_plan = state.legacy().plan(self.scripts, home,
                    source_files=self.observed._files if self.observed is not None else None)
                self.script_evidence = inputs['scripts'] = state.legacy().evidence(self.scripts, home, ignore_pending)
            if self.observed is not None:
                self._inspect()
                inputs['aliases'] = self._alias_evidence
            if self.scripts is not None:
                by_id = {r['id']: r for r in value._value['items']}
                self.rows += [(by_id[row['name']], status, policy) for row, status, policy in self.script_plan['rows']]
        except (client.Invalid, observe.Invalid) as exc:
            if exc.code in ('cancelled', 'process_cleanup_failed'):
                raise
            code = 'functions_unavailable' if exc.code in ('functions_unavailable', 'helper_unavailable', 'helper_untrusted') else 'observation_failed'
            self.rows = [(item, 'unverified', code) for item in value._value['items']]
            self.writes = {}
        self.evidence = state.digest(json.dumps(dict(inputs, rows=[(r['id'], s, p) for r, s, p in self.rows],
            writes={p: state.digest(v) for p, v in self.writes.items()}), sort_keys=True, separators=(',', ':')).encode())

    def __repr__(self):
        return '<ShellFunctionPlan private>'

    def _check(self):
        if self._cancelled():
            raise client.Invalid('cancelled')
        if time.monotonic() >= self._deadline:
            raise observe.Invalid('observation_timeout')
        return False

    def _inspect(self):
        value, observed, home = self._value, self.observed, self._home
        paths = {row['id']: row['path'] for row in value._value['sources']}
        actual_paths = {f['source']['id']: p for p, f in observed._files.items() if f['source']}
        actual = {row['key']: row for row in observed.snapshot._value['items']}
        selected_paths = {paths[r['source']] for r in value._value['items'] if r['kind'] != 'script'}
        present_paths = {p for p in selected_paths if observed._files.get(p, {}).get('status') == 'observed'}
        load_order_matches = all(
            [paths[r['source']] for r in value._value['loads'] if r['context'] == context and paths[r['source']] in present_paths] ==
            [actual_paths[r['source']] for r in observed._loads if r['context'] == context and actual_paths[r['source']] in present_paths]
            for context in observe.CONTEXTS)
        managed = any(f['raw'] is not None and (sources.MANAGED.search(f['raw'].decode('utf-8', errors='replace')) or
                      (f['stamp'] is not None and f['stamp'][1][1])) for f in observed._files.values())
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
            self._inspect_managed(ordered, managed)
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
            elif managed:
                reason = 'managed_source_prerequisite'
            elif competing:
                status, reason = 'differing', 'target_conflict'
            elif observed.codes:
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
                    elif any(item['key'] in f['names'] for f in observed._files.values()):
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
                if opaque or any(sum(k == r['key'] for k, _, _ in declarations) != 1 or
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
    if any(s not in ('matching', 'missing') for _, s, _ in current.rows):
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
                    _ignore_pending=ignore_pending, aliases=True, _additional_sources=(MANAGED_PATH,))
                if fresh_sources._files != current.observed._files:
                    raise base.Invalid('target_changed')
            changed = state.legacy().publish(current.scripts, home,
                expected=current.script_evidence, approvals=approvals,
                source_files=current.observed._files if current.observed is not None else None,
                validate_sources=validate_sources if current.observed is not None else None)
            fresh = plan(value, home, helper=current.helper, cancelled=cancelled)
            if current.observed is not None and fresh.observed._files != current.observed._files:
                raise base.PublicationUncertain('source_changed')
            current = fresh
            if any(s not in ('matching', 'missing') for _, s, _ in current.rows):
                raise base.PublicationUncertain('source_changed')
        for path in sorted(current.writes):
            candidate, wanted = current.writes[path], current.evidence
            def validate(ignore_pending=()):
                fresh = plan(value, home, helper=current.helper, cancelled=cancelled, ignore_pending=ignore_pending)
                if fresh.evidence != wanted:
                    raise base.Invalid('target_changed')
            sources.publish_content(home, path, candidate, validate, limit=state.MAX_SOURCE, tracked=True)
            changed = True
            fresh = plan(value, home, helper=current.helper, cancelled=cancelled)
            # Other observed sources and their metadata must remain identical.
            if ({p: f for p, f in fresh.observed._files.items() if p != path} !=
                    {p: f for p, f in current.observed._files.items() if p != path}):
                raise base.PublicationUncertain('source_changed')
            current = fresh
        if any(s != 'matching' for _, s, _ in current.rows):
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
        for item, status, reason in result.rows:
            print(item['id'], status, reason, sep='\t')
        print('scope\tpartial\tactivation_unknown')
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
