"""Bounded exact-definition Restore/Check; never evaluates Shell source.

The B2A observer owns discovery and parser transport. The existing Shell
publisher owns safe append, metadata, competing writers and recovery fences.
"""
import importlib.util
import json
import os
from pathlib import Path
import sys
import time

spec = importlib.util.spec_from_file_location('shell_function_capture', Path(__file__).with_name('capture.py'))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)
observe, state, client = capture.observe, capture.state, capture.client
sources, base = observe.sources, observe.base
ROOT = Path(__file__).resolve().parents[2]
PLAN_SECONDS = 60


def load(path):
    path = Path(path)
    raw = base.read_file(str(path), private=True, limit=state.MAX_MANIFEST)
    payload = base.read_file(str(path.with_name('definitions.data')), private=True, limit=state.MAX_DEFINITION_TOTAL)
    value = state.decode(raw, {state.DEFINITIONS: payload})
    if not value._value['items'] or any(row['kind'] != 'function' for row in value._value['items']):
        raise base.Invalid('unsupported_contract')
    return value


def content(value, item):
    ref = next(r for r in value._value['content_refs'] if r['id'] == item['content'])
    return value._payloads[ref['member']][ref['offset']:ref['offset'] + ref['length']]


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
        if not value._value['items'] or any(r['kind'] != 'function' for r in value._value['items']):
            raise base.Invalid('unsupported_contract')
        self.rows, self.writes = [], {}
        self.observed = None
        self.helper = helper
        self.evidence = None
        self._value, self._home, self._cancelled = value, home, cancelled
        self._deadline = time.monotonic() + PLAN_SECONDS
        inputs = dict(snapshot=state.digest(raw), payloads={k: state.digest(v) for k, v in payloads.items()})
        try:
            self._check()
            self.helper = helper or capture.parser(ROOT)
            self.observed = observe.observe(home, self.helper, cancelled=self._check, _ignore_pending=ignore_pending)
            inputs.update(parser=self.helper._manifest_sha256,
                files={p: dict(status=f['status'], stamp=f['stamp'], digest=state.digest(f['raw']) if f['raw'] is not None else None)
                       for p, f in self.observed._files.items()}, loads=self.observed._loads)
            self._inspect()
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
        aliases = {c[1] for f in observed._files.values() for c in f['commands'] if c[0] == 'alias'}
        managed = any(f['raw'] is not None and (sources.MANAGED.search(f['raw'].decode('utf-8', errors='replace')) or
                      (f['stamp'] is not None and f['stamp'][1][1])) for f in observed._files.values())
        grouped = {}
        source_bytes = sum(len(f['raw'] or b'') for f in observed._files.values())
        definitions = sum(f['definition_count'] for f in observed._files.values())
        response_bytes = sum(f['response_bytes'] for f in observed._files.values())
        load_count = len(observed._loads)
        for item in value._value['items']:
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
            competing = (sum(f['names'].count(item['key']) for f in observed._files.values()) > 1 or item['key'] in aliases)
            if observe._shadows_source([item['key']], []):
                reason = 'source_prerequisite'
            elif managed:
                reason = 'managed_source_prerequisite'
            elif competing:
                status, reason = 'differing', 'target_conflict'
            elif observed.codes:
                reason = 'unsafe_destination' if 'unsafe_source' in observed.codes else 'source_prerequisite'
            elif aliases or any(d['owner'] == item['id'] for d in value._value['dependencies']):
                reason = 'dependency_prerequisite'
            elif supported and target is not None:
                selected = [r['id'] for r in observed._loads if actual_paths[r['source']] == path]
                actual_chains = chains(observed._loads, actual_paths, selected)
                direct_missing = (path == '.zshrc' and target['status'] == 'missing' and
                                  all(len(chain) == 1 for _, chain in expected))
                if actual_chains == expected or direct_missing:
                    found = actual.get(item['key'])
                    if found is not None:
                        status = ('matching' if actual_paths[found['source']] == path and
                                  content(observed.snapshot, found) == saved else 'differing')
                        reason = 'preserve' if status == 'matching' else 'target_conflict'
                    elif any(item['key'] in f['names'] for f in observed._files.values()):
                        status, reason = 'differing', 'target_conflict'
                    else:
                        status, reason = 'missing', 'add' if target['raw'] is not None else 'create'
            # Structural bytes in an untrusted Bundle must actually describe one
            # complete named unit. B1 integrity alone is not a parser receipt.
            response = self.helper.parse(saved, cancelled=self._check)
            units, _, commands, opaque, _ = observe._outer(saved, response, home)
            relative = {key: [n - item['details']['span'][0] for n in item['details'][key]]
                        for key in ('span', 'name', 'body')}
            if (len(units) != 1 or units[0][0] != item['key'] or units[0][1] != saved or commands or opaque or
                    any(units[0][2][key] != span for key, span in relative.items())):
                status, reason = 'unverified', 'definition_invalid'
            self.rows.append((item, status, reason))
            if status == 'missing':
                grouped.setdefault(path, []).append(item)
        for path, items in grouped.items():
            self._check()
            items.sort(key=lambda r: r['details']['span'])
            original = observed._files[path]['raw'] or b''
            candidate = original + (b'\n' if original and not original.endswith(b'\n') else b'')
            candidate += b''.join(content(value, r) + b'\n' for r in items)
            try:
                if sources.MANAGED.search(candidate.decode('utf-8')):
                    raise base.Invalid('external_owner')
                if len(candidate) > state.MAX_SOURCE:
                    raise base.Invalid('source_limit')
                response = self.helper.parse(candidate, cancelled=self._check)
                units, names, _, opaque, count = observe._outer(candidate, response, home)
                if opaque or any(names.count(r['key']) != 1 or not any(k == r['key'] and data == content(value, r)
                                  for k, data, _ in units) for r in items):
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


def plan(value, home, **options):
    return Plan(value, home, **options)


def publish(value, home, *, expected=None, helper=None, cancelled=lambda: False):
    current = plan(value, home, helper=helper, cancelled=cancelled)
    if expected is not None and current.evidence != expected:
        raise base.Invalid('target_changed')
    if any(s not in ('matching', 'missing') for _, s, _ in current.rows):
        raise base.Invalid('target_conflict')
    changed = False
    try:
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
            changed = publish(value, os.environ['HOME'], expected=os.environ.get('MACSEED_SHELL_EXPECTED_EVIDENCE'))
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
