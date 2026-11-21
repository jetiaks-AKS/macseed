"""Read-only, private Shell definition evidence; never evaluates user source."""
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
    __slots__ = ('snapshot', '_files', '_issues', '_loads', '_roots', 'uncertainties')

    def __init__(self, snapshot, files, issues, loads=(), roots=()):
        self.snapshot, self._files, self._issues = snapshot, files, tuple(issues)
        self._roots = tuple(roots)
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
        else:
            # A trailing comment is outside the original declaration span.
            match = base.TYPED_ALIAS.match(statement)
            if (match and (match.end() == len(statement) or re.fullmatch(r'[ \t]+#.*', statement[match.end():]))
                    and base.typed_declaration(match[0]) is not None):
                commands.append(('alias', match[1], [start, start + len(match[0].encode())]))
            else:
                unsupported = True
    return units, names, commands, unsupported, len(value['definitions'])


def _independent(raw, response, home, units, commands):
    """Qualify declaration positions with the existing bounded Shell lexer.

    Replace each parser-bounded outer function with a unique inert alias in a
    private lexical projection. The existing alias classifier then proves that
    its position is a complete, unconditional statement (not a conditional,
    substitution, pipeline, heredoc or command operand). Original bytes/spans
    never change. This proves declaration ownership, not effective runtime state.
    """
    value = state.parser_response(raw, response, 0)
    markers, pieces, end = {}, [], 0
    for index, row in enumerate(value['definitions']):
        if row['parent'] != -1:
            continue
        first, last = row['span']
        marker = '_macseed_' + state.digest(raw)[:24] + '_' + str(index)
        markers[tuple(row['span'])] = marker
        pieces += [raw[end:first], ("alias " + marker + "='/bin/true'").encode()]
        end = last
    # The legacy lexer accepts LF text. Only its private projection drops the
    # CR in CRLF; bare CR remains rejected, never a new command boundary.
    projection = b''.join([*pieces, raw[end:]]).replace(b'\r\n', b'\n')
    try:
        outer, _ = sources.top_level(projection, typed=True)
    except ValueError as exc:
        return [], [], [], str(exc) == 'ambiguous_alias_command' or any(c[0] == 'alias' for c in commands)
    eligible = {row['name'] for _, row in outer if row}
    spanned = {name for kind, name, _ in commands if kind == 'alias'} | set(markers.values())
    # Only name a literal binding at a proven outer position.
    # Never export its body, source path or a name that resembles a secret.
    excluded, accounted = [], set()
    for statement, row in outer:
        if row:
            accounted.add(statement)
            if row['name'] not in spanned:
                # The lexer identified the name, but the line observer has no
                # independent byte span (e.g. two declarations on one line).
                excluded.append((row['name'], 'unsupported_position'))
        elif (match := re.match(r'alias[ \t]+(?:(-[gs])[ \t]+)?(' + base.SOURCE_NAME + r')=', statement)):
            if not base.SENSITIVE.search(match[2]) and base.typed_declaration(statement) is None:
                if match[1]:
                    reason = 'unsupported_mode'
                elif base.SENSITIVE.search(statement):
                    reason = 'restricted_content'
                elif not base.TYPED_ALIAS.fullmatch(statement):
                    reason = 'literal_required'
                else:
                    reason = 'unsupported_declaration'
                excluded.append((match[2], reason))
                accounted.add(statement)
    outer = {statement for statement, _ in outer}
    # Explicit binding mutation is evidence against the saved declarations.
    # Dynamic initialization remains outside scope, never resolved or executed.
    statements = base.statements(projection.decode())
    binding_mutation = any(re.search(r'\b(?:unfunction|autoload|disable|enable|functions|unset)\b', statement)
                           for statement in statements if not base.TYPED_ALIAS.fullmatch(statement))
    units = [unit for unit in units if markers.get(tuple(unit[2]['span'])) in eligible and not binding_mutation]
    outer_alias_count = sum(c[0] == 'alias' for c in commands)
    commands = [command for command in commands
                if state.utf8(raw[slice(*command[2])]) in outer and
                (command[0] != 'alias' or command[1] in eligible)]
    unresolved = (outer_alias_count != sum(c[0] == 'alias' for c in commands) or
                  any(statement not in accounted and re.match(r'(?:(?:then|else|do|builtin)\s+)?alias\b', statement)
                      for statement in statements))
    return units, commands, excluded, unresolved


def _equivalence_context(files, loads, issues, check):
    """Bounded private barriers around already admitted declarations, not evaluation.

    A literal source edge is transparent only after the existing observer qualified
    it. Other outer statements can change definition-time options/alias expansion.
    Explicit evaluation/binding changes after a definition are possible overrides.
    """
    if any(code != 'unsupported_context' for _, code in issues):
        return None
    by_source, context = {}, {}
    for load in loads.values():
        by_source.setdefault(load['source'], []).append(load)
    count = 0
    for record in files.values():
        check()
        if record['status'] == 'missing':
            continue
        if record['status'] not in ('observed', 'partial'):
            return None
        masked = bytearray(record['raw'])
        for _, _, details in record['units']:
            if 'mode' not in details:
                for i in range(*details['span']):
                    if masked[i] not in (10, 13):
                        masked[i] = 32
        commands = {bounds[0]: (kind, bounds[1]) for kind, _, bounds in record['commands']}
        offset = 0
        for line in bytes(masked).split(b'\n'):
            text = line.strip(b' \t\r;')
            start = offset + line.find(text) if text else offset
            offset += len(line) + 1
            if not text or text.startswith(b'#'):
                continue
            kind, end = commands.get(start, (None, start))
            if end != start + len(text) and not (kind == 'alias' and text[end-start:].lstrip().startswith(b'#')):
                kind = None
            if kind in ('source', 'zdotdir'):
                continue
            if kind != 'alias' and re.search(rb'\b(?:alias|function)\b|\(\s*\)', text):
                return None  # Unadmitted binding syntax cannot prove equivalence.
            if kind != 'alias' and re.search(rb'(?<![\w/])(?:source|\.)\s', text):
                return None  # Dynamic/conditional/unqualified source could override a binding.
            override = kind != 'alias' and bool(re.search(
                rb'\b(?:eval|unfunction|autoload|functions|unset|unalias|disable|enable)\b', text))
            for load in by_source.get(record['source']['id'], []):
                count += 1
                if count > state.MAX_DECLARATIONS * len(CONTEXTS):
                    return None  # Refuse equivalence beyond the existing occurrence budget.
                context.setdefault(load['context'], []).append((state.load_position(loads, load['id'], start), override))
    return context


def _equivalent(candidates, files, loads, context):
    """Project proven duplicate Function observations into one B1 declaration."""
    if context is None or any('mode' in unit[2] for _, unit, _, _ in candidates):
        return None
    name, raw, details = candidates[0][1]
    physical = {(path, tuple(unit[2]['span'])) for path, unit, _, _ in candidates}
    if (sum(f['names'].count(name) for f in files.values()) != len(physical) or
            any(name in f['alias_names'] for f in files.values())):
        return None  # Includes non-admitted/conditional/multiple-name bindings.
    def structure(value):
        return (value['parser_profile'], *(tuple(n - value['span'][0] for n in value[key])
                                          for key in ('span', 'name', 'body')))
    if any(unit[1] != raw or structure(unit[2]) != structure(details) for _, unit, _, _ in candidates):
        return None
    positions = {}
    for _, unit, load, _ in candidates:
        positions.setdefault(load['context'], []).append(state.load_position(loads, load['id'], unit[2]['span'][0]))
    for key, points in positions.items():
        first, last = min(points), max(points)
        if any(first < position < last or override and position > first for position, override in context.get(key, [])):
            return None
    # Preserve a real canonical source/span and one occurrence in every observed
    # context. All physical units/loads remain private in Observation._files/_loads.
    canonical = candidates[0][0], tuple(details['span'])
    chosen = {}
    for candidate in candidates:
        path, unit, load, _ = candidate
        if (path, tuple(unit[2]['span'])) == canonical:
            chosen.setdefault(load['context'], candidate)
    return list(chosen.values()) if set(chosen) == set(positions) else None


def observe(home, parser, *, zdotdir=None, contexts=CONTEXTS, cancelled=lambda: False, _ignore_pending=(), aliases=False,
            independent=False, _additional_sources=(), environment=False):
    """Observe only an explicit HOME and trusted Parser; never ambient ZDOTDIR.

    Contexts are hypothetical standard startup sequences. System startup files,
    options and inherited bindings are unobserved, so activation stays unknown.
    """
    if (type(home) is not str or type(parser) is not client.Parser or type(contexts) not in (tuple, list)
            or not contexts or len(contexts) > len(CONTEXTS) or not callable(cancelled)
            or any(type(c) is not str or c not in CONTEXTS for c in contexts)
            or len(set(contexts)) != len(contexts) or type(independent) is not bool
            or type(_additional_sources) is not tuple or len(_additional_sources) > 1
            or any(not sources.portable(p) for p in _additional_sources)):
        raise Invalid('invalid_request')
    try:
        if cancelled():
            raise Invalid('cancelled')
        parser.preflight(cancelled=cancelled)
        with base.home_directory(home) as (_, stable):
            result = _observe(home, parser, zdotdir, contexts, cancelled, aliases, independent, _additional_sources,
                              lambda path: sources.file_state(home, path, _ignore_pending, limit=state.MAX_SOURCE), environment=environment)
            stable()
            return result
    except (Invalid, client.Invalid):
        raise
    except (OSError, ValueError) as exc:
        raise Invalid('source_changed' if str(exc) == 'target_changed' else 'observation_failed') from None


def project_appends(home, parser, observed, appends, cancelled, additional_sources, *, environment=False):
    """Reparse proposed original-source appends against the frozen, already observed startup graph."""
    def read(path):
        if path not in observed._files:
            raise Invalid('source_changed')
        file = observed._files[path]
        return appends.get(path, file['raw']), file['stamp']
    return _observe(home, parser, None, CONTEXTS, cancelled, True, True, additional_sources, read, environment=environment)


def _observe(home, parser, zdotdir, contexts, cancelled, aliases, independent, additional_sources, read_state, *, environment=False):
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
        record = dict(status='missing', raw=None, stamp=None, source=None, units=[], names=[], commands=[], alias_names=[],
                      definition_count=0, response_bytes=0)
        files[path] = record
        try:
            try:
                raw, stamp = read_state(path)
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
            alias_names = [name for kind, name, _ in commands if kind == 'alias']
            if independent and opaque:
                units, commands, excluded, unresolved = _independent(raw, response, home, units, commands)
                record.update(excluded_aliases=excluded, unresolved_aliases=unresolved)
                alias_names += [name for name, _ in excluded]
            if environment:
                structural = state.parser_response(raw, response, 0)
                bounds = structural.get('statements')
                record['environment'] = []
                record['boundaries'] = set()
                record['all_outer_known'] = bounds is not None
                record['all_outer_bounded'] = bounds is not None
                if bounds is None:
                    issue(path, 'environment_spans_unavailable')
                else:
                    literal_sources = {tuple(site) for command, _, site in commands if command == 'source'}
                    for first, last in bounds:
                        # Require a standalone foreground statement. Background
                        # separators live outside the sublist in the grammar.
                        left = raw[raw.rfind(b'\n', 0, first) + 1:first]
                        end = raw.find(b'\n', last)
                        right = raw[last:end if end >= 0 else len(raw)].strip(b' \t\r')
                        if (left.strip(b' \t') and not left.rstrip().endswith(b';') or
                                right and not right.startswith((b'#', b';'))):
                            record['all_outer_known'] = False
                            record['all_outer_bounded'] = False
                            continue
                        record['boundaries'].add((first, last))
                        text = state.utf8(raw[first:last])
                        try:
                            kind, key, intent = state.environment.classify(text)
                        except state.environment.Excluded as exc:
                            record['all_outer_known'] = False
                            if str(exc) == 'restricted_content':
                                restricted_names = re.findall(r'(?:^|[ \t])(' + state.environment.NAME + r')\+?=', text)
                                record.setdefault('private_bindings', set()).update(restricted_names)
                            if ((first, last) not in literal_sources and str(exc) == 'external_initializer' or
                                    re.match(r'(?:export |typeset |integer |readonly |unset |eval |[A-Za-z_]\w*\+?=|\[\[)', text)):
                                record.setdefault('environment_exclusions', set()).add(str(exc))
                            continue
                        record['environment'].append((kind, key, intent, [first, last]))
                    provider_sites = {tuple(site) for kind, _, _, site in record['environment'] if kind == 'initializer'}
                    commands = [command for command in commands if command[0] != 'source' or tuple(command[2]) not in provider_sites]
            if aliases:
                units += [(name, raw[slice(*bounds)], dict(mode='ordinary', span=bounds))
                          for kind, name, bounds in commands if kind == 'alias']
                count += len(alias_names)
            definition_count += count
            if definition_count > state.MAX_DECLARATIONS:
                raise Invalid('resource_limit')
            record.update(status=('partial' if independent else 'unsupported') if opaque else 'observed', units=units, names=names, commands=commands, alias_names=alias_names,
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
    known_env = environment and env['status'] == 'partial' and env.get('all_outer_bounded') and env.get('boundaries') and (
        ({tuple(b) for _, _, _, b in env.get('environment', [])} |
         {tuple(b) for command, _, b in env['commands'] if command == 'alias'} |
         {tuple(d['span']) for _, _, d in env['units']}) == env['boundaries'] and
        not any(name == 'ZDOTDIR' for _, name, _, _ in env['environment']))
    if env['status'] not in ('missing', 'observed') and not known_env:
        issue(env_path, 'startup_unresolved')
        root_paths = [env_path] if environment else []
    else:
        root_paths = [env_path, *(prefix + name for name in sources.STARTUP[1:])]

    shadowed_source = set()
    def visit(path, context, parent=None, site=None, entry='source', chain=()):
        check()
        if len(chain) >= state.MAX_LOAD_DEPTH or len(loads) >= state.MAX_LOADS:
            raise Invalid('resource_limit')
        record = read(path)
        if _shadows_source(record['names'] + record['alias_names'], record['commands']):
            shadowed_source.add(context)
            record['status'] = 'ambiguous'; issue(path, 'ambiguous_source_command')
        if path in chain:
            record['status'] = 'ambiguous'; issue(path, 'cyclic_source')
            return
        if record['status'] not in (('observed', 'partial') if independent else ('observed',)):
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

    for path in additional_sources:
        read(path)  # Destination evidence only; never invent a load occurrence.

    # Recheck all observed and missing files, even those contributing no item.
    # A race invalidates the entire observation rather than salvaging stale data.
    for path, record in files.items():
        check()
        if record['status'] == 'unsafe':
            continue
        try:
            try:
                current = read_state(path)
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
    source_issues = tuple(pair for pair in issues if pair[1] != 'environment_spans_unavailable')
    equivalence_context = None
    context_checked = False
    if environment and env['status'] not in ('missing', 'observed'):
        # Environment-only evidence may qualify a root. It cannot enlarge the
        # legacy definitions inventory beyond the B4 startup contract.
        bindings.clear()
    for name, candidates in sorted(bindings.items()):
        check()
        if independent and any(code != 'unsupported_context' for _, code in source_issues):
            # An unreadable/missing/malformed known source may contain a second
            # binding. Never salvage its readable peer as apparently unique.
            issue(candidates[0][0], 'ambiguous_alias' if 'mode' in candidates[0][1][2] else 'ambiguous_function')
            continue
        definitions = {(path, tuple(unit[2]['span'])) for path, unit, _, _ in candidates}
        contexts_seen = [load['context'] for _, _, load, _ in candidates]
        # Names also mentioned by non-selectable multiple-binding outer units
        # cannot be silently treated as a single ordinary definition.
        mentions = sum(f['names'].count(name) + (f['alias_names'].count(name)
                       if aliases else 0) for f in files.values())
        repeated = len(definitions) != 1 or len(contexts_seen) != len(set(contexts_seen)) or mentions != 1
        if repeated and independent and 'mode' not in candidates[0][1][2]:
            if not context_checked:
                equivalence_context = _equivalence_context(files, load_map, source_issues, check)
                context_checked = True
            equivalent = _equivalent(candidates, files, load_map, equivalence_context)
            if equivalent:
                candidates, repeated = equivalent, False
        if (repeated or any(files[p]['status'] not in (('observed', 'partial') if independent else ('observed',))
                            for _, _, _, chain in candidates for p in chain)):
            issue(candidates[0][0], 'ambiguous_function' if 'mode' not in candidates[0][1][2] else 'ambiguous_alias')
            continue
        path, (key, content, details), _, _ = candidates[0]
        # A function/alias name collision is parse-time ambiguity, not precedence.
        if not aliases and any(name in f['alias_names'] for f in files.values()):
            issue(path, 'ambiguous_function'); continue
        kind = 'alias' if 'mode' in details else 'function'
        if kind == 'alias' and any('alias' in f['names'] + f['alias_names'] for f in files.values()):
            issue(path, 'ambiguous_alias'); continue
        item = dict(id=state.identity(kind, key), kind=kind, key=key, source=files[path]['source']['id'],
                    loads=[load['id'] for _, _, load, _ in candidates], details=details)
        items.append(item); contents[item['id']] = content
        for load in item['loads']:
            while load is not None and load not in used_loads:
                used_loads.add(load); used_sources.add(load_map[load]['source'])
                load = load_map[load]['parent']
    if environment:
        provider_sites = {(f['source']['id'], tuple(bounds)) for f in files.values() if f['source']
                          for kind, _, _, bounds in f.get('environment', []) if kind == 'initializer'}
        qualified_sites = {(f['source']['id'], site) for f in files.values() if f['source']
                           for site in f.get('boundaries', ())} - provider_sites
        private_sources = set()
        for path, file in files.items():
            if file['source'] and state.environment.PRIVATE.search(path):
                private_sources.add(file['source']['id'])
                file.setdefault('environment_exclusions', set()).add('restricted_content')
        user_loads = set()
        for load in loads:
            parent = load['parent']
            if load['source'] in private_sources:
                continue
            if parent is None or (parent in user_loads and
                    (load_map[parent]['source'], tuple(load['site'])) in qualified_sites):
                user_loads.add(load['id'])
        # Propagate restrictions through symbolic reads without resolving values.
        # This private reverse index is bounded by the source and declaration budgets.
        private = {name for f in files.values() for name in f.get('private_bindings', ())}
        readers = {}
        for f in files.values():
            for kind, name, intent, _ in f.get('environment', ()):
                if kind != 'initializer':
                    writes, reads = state.environment.parameter_uses(name, intent)
                    for ref in reads:
                        readers.setdefault(ref, set()).update(writes)
        pending = list(private)
        while pending:
            newly_private = readers.get(pending.pop(), set()) - private
            private.update(newly_private)
            pending.extend(newly_private)
        shadowed = {name for f in files.values() for name in f['names'] + f['alias_names']}
        for path, file in files.items():
            if file['status'] not in ('observed', 'partial') or not file['source']:
                continue
            source_id = file['source']['id']
            visits = [load for load in loads if load['source'] == source_id and load['id'] in user_loads]
            if not visits:
                continue
            ordinals = {}
            for kind, key, intent, bounds in file.get('environment', []):
                writes, reads = state.environment.parameter_uses(key, intent)
                if writes & state.environment.FRAMEWORK_PARAMETERS:
                    file.setdefault('environment_exclusions', set()).add('special_parameter')
                    continue
                if (reads | writes) & private:
                    file.setdefault('environment_exclusions', set()).add('restricted_content')
                    continue
                if kind == 'initializer':
                    commands_used = {'source', '.'} if key in ('nvm', 'asdf', 'Cargo') else {'eval', intent['variant'].split()[0]}
                    if intent['guard'] == 'nonempty-nvm-script':
                        commands_used.add('[')
                else:
                    declarations = [m['declaration'] for m in intent['members']] if 'members' in intent else [intent]
                    commands_used = {d['form'] for d in declarations if d['form'] != 'assignment'}
                    if any(d.get('words') == [[['nvm-directory', 'XDG_CONFIG_HOME', 'HOME']]] for d in declarations):
                        commands_used.update(('[', 'printf'))
                if commands_used & shadowed:
                    file.setdefault('environment_exclusions', set()).add('shadowed_declaration')
                    continue
                order = ordinals.get((kind, key), 0)
                ordinals[kind, key] = order + 1
                row = dict(kind=kind, key=key, source=source_id, loads=[load['id'] for load in visits],
                           details=dict(span=bounds, ordinal=order, intent=intent))
                row['id'] = state.item_identity(row)
                items.append(row)
                contents[row['id']] = file['raw'][slice(*bounds)]
                for load in visits:
                    while load and load['id'] not in used_loads:
                        used_loads.add(load['id'])
                        used_sources.add(load['source'])
                        load = load_map.get(load['parent'])
    check()
    try:
        snapshot = state.assemble([f['source'] for f in files.values() if f['source'] and f['source']['id'] in used_sources],
                                  [r for r in loads if r['id'] in used_loads], items, state.parameter_dependencies(items, loads), contents)
    except state.Invalid as exc:
        raise Invalid('resource_limit' if str(exc) == 'shell_state_resource_limit' else 'observation_failed') from None
    check()
    return Observation(snapshot, files, issues, loads, root_paths)


def _shadows_source(names, commands):
    return (any(name in ('source', '.') for name in names) or
            any(c[0] == 'alias' and c[1] in ('source', '.') for c in commands))
