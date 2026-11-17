"""Read-only, private Functions evidence. No production workflow registration."""
import importlib.util
from pathlib import Path
import re
import time

spec = importlib.util.spec_from_file_location('shell_parser_client', Path(__file__).with_name('parser_client.py'))
client = importlib.util.module_from_spec(spec)
spec.loader.exec_module(client)
state = client.state
sources = state.legacy().sources
base = sources.base
OBSERVATION_SECONDS = 30.0
CONTEXTS = ('noninteractive', 'interactive', 'login', 'interactive-login')


class Invalid(ValueError):
    CODES = {'invalid_request', 'resource_limit', 'cancelled', 'observation_timeout', 'source_changed',
             'observation_failed'}

    def __init__(self, code):
        self.code = code if code in self.CODES else 'observation_failed'
        super().__init__('shell_observation_' + self.code)


class Observation:
    """All records are private. Only fixed codes may enter ordinary diagnostics.

    snapshot is B1 evidence, not an eligibility decision. Source outcomes include
    missing/rejected units that cannot belong to a selected B1 snapshot.
    """
    __slots__ = ('snapshot', '_files', '_issues', '_loads', 'uncertainties')

    def __init__(self, snapshot, files, issues, loads=()):
        self.snapshot, self._files, self._issues = snapshot, files, tuple(issues)
        self._loads = tuple(loads)
        self.uncertainties = ('activation_unproven', 'function_calls_unresolved', 'alias_expansion_unresolved',
                              'script_invocation_and_consent_unresolved', 'external_configuration_unobserved')

    def __repr__(self):
        return '<ShellObservation private>'

    @property
    def codes(self):
        return tuple(sorted({code for _, code in self._issues}))


def _outer(raw, response, home):
    """Recognize a closed outer envelope, never interpret function bodies.

    Native spans mask whole function units, preserving byte offsets/newlines.
    Only literal standalone source/ZDOTDIR/alias lines are classified outside
    those spans. Unrecognized syntax is opaque, not a guessed execution context.
    """
    value = state.parser_response(raw, response, 0)
    masked = bytearray(raw)
    units, names, opaque_unit = [], [], False
    for index, row in enumerate(value['definitions']):
        if row['parent'] != -1:
            continue
        first, last = row['span']
        # Anonymous invocations execute during loading and can change source or
        # startup semantics. They are not inert named declarations.
        if not row['names']:
            opaque_unit = True
        for i in range(first, last):
            if masked[i] not in (10, 13):
                masked[i] = 32
        for a, b in row['names']:
            name = state.utf8(raw[a:b])
            names.append(name)
            if not state.NAME.fullmatch(name):
                opaque_unit = True  # Do not resolve quoted/computed bindings.
        try:
            key, content, details = state.function_evidence(raw, response, 0, index)
            units.append((key, content, details))
        except state.Invalid:
            # Anonymous/multiple bindings are still masked as whole units;
            # they do not become independently selectable definitions.
            continue
    commands, offset, unsupported = [], 0, opaque_unit
    # Only LF terminates a parser source line. In particular, a bare CR in a
    # comment must not expose its suffix as a source command or ZDOTDIR assignment.
    for line in bytes(masked).split(b'\n'):
        text = line.strip(b' \t\r\n;')
        start = offset + line.find(text) if text else offset
        offset += len(line) + 1
        if not text or text.startswith(b'#'):
            continue
        statement = state.utf8(text)
        include = re.fullmatch(r'(?:source|\.)[ \t]+(.+)', statement)
        location = re.fullmatch(r'(?:export[ \t]+)?ZDOTDIR=(.+)', statement)
        if include and sources.reference(include[1], home) is not None:
            commands.append(('source', sources.reference(include[1], home), [start, start + len(text)]))
        elif location and sources.reference(location[1], home) is not None:
            commands.append(('zdotdir', sources.reference(location[1], home), [start, start + len(text)]))
        elif base.declaration(statement, extended=True) is not None:
            commands.append(('alias', base.declaration(statement, extended=True)[0]['name'], [start, start + len(text)]))
        else:
            unsupported = True
    return units, names, commands, unsupported, len(value['definitions'])


def observe(home, parser, *, zdotdir=None, contexts=CONTEXTS, cancelled=lambda: False, _ignore_pending=()):
    """Observe only an explicit HOME and trusted Parser; never ambient ZDOTDIR.

    Contexts are hypothetical standard startup sequences. System startup files,
    options and inherited bindings are unobserved, so activation stays unknown.
    """
    if (type(home) is not str or type(parser) is not client.Parser or type(contexts) not in (tuple, list)
            or not contexts or len(contexts) > len(CONTEXTS) or not callable(cancelled)
            or any(type(c) is not str or c not in CONTEXTS for c in contexts)
            or len(set(contexts)) != len(contexts)):
        raise Invalid('invalid_request')
    try:
        if cancelled():
            raise Invalid('cancelled')
        parser.preflight(cancelled=cancelled)
        with base.home_directory(home) as (_, stable):
            result = _observe(home, parser, zdotdir, contexts, cancelled, _ignore_pending)
            stable()
            return result
    except (Invalid, client.Invalid):
        raise
    except (OSError, ValueError) as exc:
        raise Invalid('source_changed' if str(exc) == 'target_changed' else 'observation_failed') from None


def _observe(home, parser, zdotdir, contexts, cancelled, ignore_pending):
    contexts = [c for c in CONTEXTS if c in contexts]
    deadline = time.monotonic() + OBSERVATION_SECONDS
    files, issues, loads, occurrences = {}, [], [], []
    source_bytes = definition_count = response_bytes = 0
    def check():
        if cancelled():
            raise Invalid('cancelled')
        if time.monotonic() >= deadline:
            raise Invalid('observation_timeout')
    def issue(path, code):
        if (path, code) not in issues:
            issues.append((path, code))
    def read(path):
        nonlocal source_bytes, definition_count, response_bytes
        check()
        if path in files:
            return files[path]
        if len(files) >= state.MAX_SOURCES:
            raise Invalid('resource_limit')
        record = dict(status='missing', raw=None, stamp=None, source=None, units=[], names=[], commands=[],
                      definition_count=0, response_bytes=0)
        files[path] = record
        try:
            try:
                raw, stamp = sources.file_state(home, path, ignore_pending, limit=state.MAX_SOURCE)
            except FileNotFoundError:
                # A missing parent is absence too; verify it again at completion.
                raw, stamp = None, None
            record.update(raw=raw, stamp=stamp)
            if raw is None:
                return record
            source_bytes += len(raw)
            if source_bytes > state.MAX_SOURCE_TOTAL:
                raise Invalid('resource_limit')
            record['source'] = state.source_record(path, raw)
            response = parser.parse(raw, cancelled=lambda: cancelled() or time.monotonic() >= deadline)
            check()
            response_bytes += len(response)
            if response_bytes > state.MAX_MANIFEST:
                raise Invalid('resource_limit')
            units, names, commands, opaque, count = _outer(raw, response, home)
            definition_count += count
            if definition_count > state.MAX_DECLARATIONS:
                raise Invalid('resource_limit')
            record.update(status='unsupported' if opaque else 'observed', units=units, names=names, commands=commands,
                          definition_count=count, response_bytes=len(response))
            if opaque:
                issue(path, 'unsupported_context')
        except client.Invalid as exc:
            if exc.code in ('cancelled', 'timeout', 'process_cleanup_failed'):
                raise
            record['status'] = 'unsupported'
            issue(path, exc.code)
        except Invalid:
            raise
        except (OSError, ValueError) as exc:
            if str(exc) == 'target_changed':
                raise Invalid('source_changed') from None
            record['status'] = 'unsafe' if isinstance(exc, OSError) or not isinstance(exc, state.Invalid) else 'unsupported'
            issue(path, 'unsafe_source' if record['status'] == 'unsafe' else 'source_encoding')
        return record

    # Use the same portable reference policy as legacy Shell, but consume an
    # explicit environment observation rather than mutable process environment.
    if zdotdir in (None, '', home):
        prefix = ''
    elif type(zdotdir) is str and zdotdir.startswith(home + '/') and sources.portable(zdotdir[len(home) + 1:]):
        prefix = zdotdir[len(home) + 1:] + '/'
    else:
        raise Invalid('invalid_request')
    env_path = prefix + '.zshenv'
    env = read(env_path)
    locations = [command for command in env['commands'] if command[0] == 'zdotdir']
    if locations:
        # A sourced file or other executable unit before the redirect can alter
        # its meaning. Admit only one literal redirect before any function/source.
        before = locations[0][2][0]
        if (len(locations) != 1 or env['status'] != 'observed' or
                any(line.strip() and not line.lstrip().startswith(b'#')
                    for line in env['raw'][:before].split(b'\n'))):
            env['status'] = 'ambiguous'; issue(env_path, 'ambiguous_zdotdir')
        else:
            prefix = locations[0][1] + '/'
    if env['status'] not in ('missing', 'observed'):
        issue(env_path, 'startup_unresolved')
        root_paths = []
    else:
        root_paths = [env_path, *(prefix + name for name in sources.STARTUP[1:])]

    shadowed_source = set()
    def visit(path, context, parent=None, site=None, entry='source', chain=()):
        check()
        if len(chain) >= state.MAX_LOAD_DEPTH or len(loads) >= state.MAX_LOADS:
            raise Invalid('resource_limit')
        record = read(path)
        if _shadows_source(record['names'], record['commands']):
            shadowed_source.add(context)
            record['status'] = 'ambiguous'; issue(path, 'ambiguous_source_command')
        if path in chain:
            record['status'] = 'ambiguous'; issue(path, 'cyclic_source')
            return
        if record['status'] != 'observed':
            if parent is not None:
                issue(path, 'source_unresolved')
            return
        if any(c[0] == 'zdotdir' for c in record['commands']) and path != env_path:
            record['status'] = 'unsupported'; issue(path, 'unsupported_zdotdir')
            return
        if context in shadowed_source and any(c[0] == 'source' for c in record['commands']):
            record['status'] = 'ambiguous'; issue(path, 'ambiguous_source_command')
            return
        row = dict(source=record['source']['id'], parent=parent, order=len(loads), context=context,
                   entry=entry, condition='unknown', site=site)
        row['id'] = state.load_identity(row); loads.append(row)
        for unit in record['units']:
            occurrences.append((path, unit, row, (*chain, path)))
            if len(occurrences) > state.MAX_DECLARATIONS * len(CONTEXTS):
                raise Invalid('resource_limit')
        for kind, target, bounds in record['commands']:
            if kind == 'source':
                if context in shadowed_source:
                    record['status'] = 'ambiguous'; issue(path, 'ambiguous_source_command')
                    break
                visit(target, context, row['id'], bounds, chain=(*chain, path))

    for context in contexts:
        for path, entry in zip(root_paths, ('zshenv', 'zprofile', 'zshrc', 'zlogin')):
            if entry in ('zprofile', 'zlogin') and 'login' not in context:
                continue
            if entry == 'zshrc' and context not in ('interactive', 'interactive-login'):
                continue
            visit(path, context, entry=entry)

    # Recheck all observed and missing files, even those contributing no item.
    # A race invalidates the entire observation rather than salvaging stale data.
    for path, record in files.items():
        check()
        if record['status'] == 'unsafe':
            continue
        try:
            try:
                current = sources.file_state(home, path, ignore_pending, limit=state.MAX_SOURCE)
            except FileNotFoundError:
                current = (None, None)
            if current != (record['raw'], record['stamp']):
                raise Invalid('source_changed')
        except (OSError, ValueError):
            raise Invalid('source_changed') from None

    folded = {}
    for path, record in files.items():
        if record['raw'] is not None:
            previous = folded.setdefault(path.casefold(), path)
            if previous != path:
                record['status'] = files[previous]['status'] = 'ambiguous'
                issue(path, 'ambiguous_source')
    bindings = {}
    for path, unit, load, chain in occurrences:
        bindings.setdefault(unit[0], []).append((path, unit, load, chain))
    items, contents, used_loads, used_sources = [], {}, set(), set()
    load_map = {row['id']: row for row in loads}
    for name, candidates in sorted(bindings.items()):
        check()
        definitions = {(path, tuple(unit[2]['span'])) for path, unit, _, _ in candidates}
        contexts_seen = [load['context'] for _, _, load, _ in candidates]
        # Names also mentioned by non-selectable multiple-binding outer units
        # cannot be silently treated as a single ordinary definition.
        mentions = sum(f['names'].count(name) for f in files.values())
        if (len(definitions) != 1 or len(contexts_seen) != len(set(contexts_seen)) or mentions != 1 or
                any(files[p]['status'] != 'observed' for _, _, _, chain in candidates for p in chain)):
            issue(candidates[0][0], 'ambiguous_function')
            continue
        path, (key, content, details), _, _ = candidates[0]
        # A function/alias name collision is parse-time ambiguity, not precedence.
        if any(c[0] == 'alias' and c[1] == name for f in files.values() for c in f['commands']):
            issue(path, 'ambiguous_function'); continue
        item = dict(id=state.identity('function', key), kind='function', key=key, source=files[path]['source']['id'],
                    loads=[load['id'] for _, _, load, _ in candidates], details=details)
        items.append(item); contents[item['id']] = content
        for load in item['loads']:
            while load is not None and load not in used_loads:
                used_loads.add(load); used_sources.add(load_map[load]['source'])
                load = load_map[load]['parent']
    check()
    try:
        snapshot = state.assemble([f['source'] for f in files.values() if f['source'] and f['source']['id'] in used_sources],
                                  [r for r in loads if r['id'] in used_loads], items, [], contents)
    except state.Invalid as exc:
        raise Invalid('resource_limit' if str(exc) == 'shell_state_resource_limit' else 'observation_failed') from None
    check()
    return Observation(snapshot, files, issues, loads)


def _shadows_source(names, commands):
    return (any(name in ('source', '.') for name in names) or
            any(c[0] == 'alias' and c[1] in ('source', '.') for c in commands))
