"""Private typed Shell snapshot codec. No observation, publication or execution.

A validated record is saved evidence, never target qualification or write consent.
"""
import hashlib
import importlib.util
import json
from pathlib import Path
import re
from typing import List, Literal, Optional, TypedDict, Union

MAGIC = b'MBT-SHELL-STATE-1\n'
MAGIC2 = b'MBT-SHELL-STATE-2\n'
MAGIC3 = b'MBT-SHELL-STATE-3\n'
MAGICS = (MAGIC, MAGIC2, MAGIC3)
_environment_spec = importlib.util.spec_from_file_location('shell_environment', Path(__file__).with_name('environment.py'))
environment = importlib.util.module_from_spec(_environment_spec)
_environment_spec.loader.exec_module(environment)
FEATURE = {'shell-state': 1}
SNAPSHOT = 'generated/shell/zshrc.snapshot'
DEFINITIONS = 'generated/shell/definitions.data'
SEMANTICS = 'shell-semantics-1'
RESOURCES = 'shell-resources-1'
MAX_MANIFEST = 1024 * 1024
MAX_STATEMENTS = 512
MAX_SOURCE = 128 * 1024
MAX_SOURCE_TOTAL = 2 * 1024 * 1024
MAX_DEFINITION = 64 * 1024
MAX_DEFINITION_TOTAL = 2 * 1024 * 1024
MAX_SOURCES, MAX_LOADS, MAX_LOAD_DEPTH = 128, 512, 16
MAX_DECLARATIONS, MAX_DEPENDENCIES = 512, 4096
MAX_JSON_DEPTH, MAX_JSON_NODES = 16, 65536
KINDS = ('alias', 'function', 'script')
NAME = re.compile(r'[A-Za-z_][A-Za-z0-9_.-]{0,63}')
HEX = re.compile(r'[0-9a-f]{64}')
_legacy = None


class Source(TypedDict):
    id: str
    path: str
    role: Literal['zsh', 'script']
    size: int
    sha256: str


class Load(TypedDict):
    id: str
    source: str
    parent: Optional[str]
    order: int
    context: Literal['noninteractive', 'interactive', 'login', 'interactive-login']
    entry: Literal['zshenv', 'zprofile', 'zshrc', 'zlogin', 'manual', 'source']
    condition: Literal['unconditional', 'conditional', 'unknown']
    site: Optional[List[int]]


class ContentRef(TypedDict):
    id: str
    member: str
    offset: int
    length: int
    sha256: str


class Target(TypedDict):
    id: str
    kind: Literal['alias', 'function', 'script', 'variable', 'path-operation', 'initializer', 'setting']
    key: str


class AliasDetails(TypedDict):
    mode: Literal['ordinary']
    span: List[int]


class FunctionDetails(TypedDict):
    span: List[int]
    body: List[int]
    name: List[int]
    parser_profile: Literal['zsh-default-1']


class ScriptDetails(TypedDict):
    mode: int
    managed: bool
    consent: Literal['file-transfer']
    quarantine: Optional[dict]


class EnvironmentDetails(TypedDict):
    span: List[int]
    ordinal: int
    intent: dict


class Item(Target):
    source: str
    loads: List[str]
    content: str
    details: Union[AliasDetails, FunctionDetails, ScriptDetails, EnvironmentDetails]


class Dependency(TypedDict):
    owner: str
    target: Target
    relation: Literal['calls', 'expands', 'executes', 'reads']
    phase: Literal['parse', 'invocation', 'startup']
    evidence: Literal['static-reference', 'unresolved', 'preceding-declaration']
    site: Optional[List[int]]


class Invalid(ValueError):
    """Only fixed codes cross the diagnostic boundary, never private records."""
    CODES = {'schema_invalid', 'unsupported_contract', 'resource_limit',
             'identity_invalid', 'reference_invalid', 'content_invalid',
             'ambiguous_record', 'parser_invalid', 'selection_invalid'}

    def __init__(self, code):
        super().__init__('shell_state_' + (code if code in self.CODES else 'schema_invalid'))


class ShellState:
    """Owned private data; public operations revalidate even a mutated instance."""
    __slots__ = ('_value', '_payloads')

    def __init__(self, value, payloads):
        self._value, self._payloads = value, payloads

    def __repr__(self):
        return '<ShellState private>'


def legacy():
    global _legacy
    if _legacy is None:
        spec = importlib.util.spec_from_file_location('shell_state_legacy', Path(__file__).with_name('recovery.py'))
        _legacy = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_legacy)
    return _legacy


def require(condition, code='schema_invalid'):
    if not condition:
        raise Invalid(code)


def keys(value, names):
    require(type(value) is dict and set(value) == set(names.split()))


def integer(value, minimum, maximum):
    require(type(value) is int and minimum <= value <= maximum)


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def utf8(raw):
    require(type(raw) is bytes and b'\0' not in raw, 'content_invalid')
    try:
        return raw.decode('utf-8')
    except UnicodeError:
        raise Invalid('content_invalid') from None


def path(value):
    # Use the established portable path policy, without touching the filesystem.
    require(type(value) is str and legacy().sources.portable(value), 'identity_invalid')
    return value


def identity(kind, key):
    require(type(kind) is str and kind in KINDS, 'unsupported_contract')
    if kind == 'script':
        return legacy().file_identity(path(key))
    require(type(key) is str and NAME.fullmatch(key) is not None, 'identity_invalid')
    return 'shell-' + kind + ':' + digest(key.encode('utf-8'))


def item_identity(row):
    if row['kind'] not in environment.KINDS:
        return identity(row['kind'], row['key'])
    details = row['details']
    if row['kind'] == 'setting' and type(details) is dict and 'placement' in details:
        keys(details, 'span ordinal intent placement')
        placement = details['placement']
        if type(placement) is dict and 'source_required' in placement:
            keys(placement, 'graph slot source_required')
            require(placement['source_required'] is True, 'reference_invalid')
        else:
            keys(placement, 'graph slot')
        require(type(placement['graph']) is str and HEX.fullmatch(placement['graph']), 'reference_invalid')
        integer(placement['slot'], 0, MAX_STATEMENTS)
    else:
        keys(details, 'span ordinal intent')
    integer(details['ordinal'], 0, MAX_DECLARATIONS - 1)
    require(type(row['key']) is str and type(row['source']) is str)
    key = [row['source'], row['key'], details['ordinal']]
    return 'shell-' + row['kind'] + ':' + digest(json.dumps(key, separators=(',', ':')).encode())


def source_identity(value):
    return 'shell-source:' + digest(('home\0' + path(value)).encode('utf-8'))


def load_identity(row):
    # Content hashes, byte offsets and conditions are evidence, not identity.
    value = [row[k] for k in ('source', 'parent', 'order', 'context', 'entry')]
    return 'shell-load:' + digest(json.dumps(value, separators=(',', ':')).encode())


def content_identity(item_id):
    return 'shell-content:' + digest(item_id.encode('ascii'))


def source_record(value, raw, role='zsh') -> Source:
    require(role in ('zsh', 'script'), 'unsupported_contract')
    require(type(raw) is bytes and len(raw) <= (MAX_SOURCE if role == 'zsh' else legacy().MAX_FILE_BYTES),
            'resource_limit')
    utf8(raw)
    return dict(id=source_identity(value), path=value, role=role, size=len(raw), sha256=digest(raw))


def _json_tree(value):
    """Bound Python input before encoding, including cyclic caller-owned objects."""
    pending, nodes, encoded_bytes = [(value, 0)], 0, 0
    while pending:
        item, depth = pending.pop()
        nodes += 1
        require(nodes <= MAX_JSON_NODES and depth <= MAX_JSON_DEPTH, 'resource_limit')
        if type(item) is dict:
            require(len(item) <= MAX_JSON_NODES and all(type(k) is str for k in item))
            encoded_bytes += 2 + max(0, len(item) - 1) + len(item)
            pending.extend((v, depth + 1) for pair in item.items() for v in pair)
        elif type(item) is list:
            require(len(item) <= MAX_JSON_NODES, 'resource_limit')
            encoded_bytes += 2 + max(0, len(item) - 1)
            pending.extend((v, depth + 1) for v in item)
        elif type(item) is str:
            require(len(item) <= MAX_MANIFEST, 'resource_limit')
            try:
                item.encode('utf-8')
            except UnicodeError:
                raise Invalid('schema_invalid') from None
            encoded_bytes += len(json.encoder.encode_basestring_ascii(item))
        else:
            require(item is None or type(item) is bool or (type(item) is int and abs(item) <= 2**63 - 1))
            encoded_bytes += len('null' if item is None else 'true' if item is True else
                                 'false' if item is False else str(item))
        require(encoded_bytes + len(MAGIC) + 1 <= MAX_MANIFEST, 'resource_limit')


def _json(raw, limit):
    require(type(raw) is bytes and len(raw) <= limit, 'resource_limit')
    # Bound nesting before json.loads allocates a nested object graph.
    depth, quoted, escaped = 0, False, False
    for byte in raw:
        if quoted:
            if escaped:
                escaped = False
            elif byte == 92:
                escaped = True
            elif byte == 34:
                quoted = False
        elif byte == 34:
            quoted = True
        elif byte in (91, 123):
            depth += 1
            require(depth <= MAX_JSON_DEPTH, 'resource_limit')
        elif byte in (93, 125):
            depth -= 1
            require(depth >= 0)

    def unique(pairs):
        value = {}
        for key, item in pairs:
            require(key not in value, 'ambiguous_record')
            value[key] = item
        return value

    def number(value):
        require(len(value) <= 19)
        return int(value)

    def forbidden(_value):
        raise Invalid('schema_invalid')

    try:
        value = json.loads(raw.decode('utf-8'), object_pairs_hook=unique,
                           parse_int=number, parse_float=forbidden, parse_constant=forbidden)
    except (UnicodeError, ValueError, RecursionError) as exc:
        if isinstance(exc, Invalid):
            raise
        raise Invalid('schema_invalid') from None
    _json_tree(value)
    return value


def span(value, size):
    require(type(value) is list and len(value) == 2, 'content_invalid')
    require(all(type(v) is int for v in value) and 0 <= value[0] < value[1] <= size, 'content_invalid')
    return value


def _rows(value, name, limit):
    rows = value[name]
    require(type(rows) is list)
    require(len(rows) <= limit, 'resource_limit')
    return rows


def _indexed(rows):
    ids = [row['id'] for row in rows]
    require(all(type(key) is str for key in ids))
    require(ids == sorted(set(ids)), 'ambiguous_record')
    return {row['id']: row for row in rows}


def _contracts(items, dependencies, *, selection_evidence=False):
    kinds = {row['kind'] for row in items} | {row['target']['kind'] for row in dependencies}
    if selection_evidence:
        kinds.add('selection-evidence')
    return {kind: 1 for kind in sorted(kinds)}


def _dependency_order(row):
    return (row['owner'], row['relation'], row['target']['id'], row['phase'])


def manifest_keys(value):
    fields = 'schema semantic_profile resource_profile required_contracts sources loads items dependencies content_refs'
    keys(value, fields + (' selection_evidence' if type(value) is dict and 'selection_evidence' in value else ''))


def _validate(value, payloads):
    manifest_keys(value)
    require(type(value['schema']) is int and value['schema'] in (1, 2, 3) and
            value['semantic_profile'] == f"shell-semantics-{value['schema']}" and value['resource_profile'] == RESOURCES,
            'unsupported_contract')
    contracts = value['required_contracts']
    require(type(contracts) is dict and all(k in KINDS + (environment.KINDS + ('selection-evidence',) if value['schema'] >= 2 else ()) and type(v) is int and v == 1 for k, v in contracts.items()),
            'unsupported_contract')
    sources = _rows(value, 'sources', MAX_SOURCES + legacy().MAX_FILES)
    loads = _rows(value, 'loads', MAX_LOADS)
    items = _rows(value, 'items', MAX_DECLARATIONS + legacy().MAX_FILES)
    refs = _rows(value, 'content_refs', MAX_DECLARATIONS + legacy().MAX_FILES)
    dependencies = _rows(value, 'dependencies', MAX_DEPENDENCIES)
    source_total, source_paths, zsh_sources, script_sources = 0, set(), 0, 0
    for row in sources:
        keys(row, 'id path role size sha256')
        require(row['role'] in ('zsh', 'script'), 'unsupported_contract')
        if value['schema'] == 3:
            require(type(row['path']) is str and not legacy().sources.history_path(row['path']), 'content_invalid')
        require(row['id'] == source_identity(row['path']), 'identity_invalid')
        require(row['path'].casefold() not in source_paths, 'ambiguous_record')
        source_paths.add(row['path'].casefold())
        integer(row['size'], 0, MAX_SOURCE if row['role'] == 'zsh' else legacy().MAX_FILE_BYTES)
        require(type(row['sha256']) is str and HEX.fullmatch(row['sha256']))
        if row['role'] == 'zsh':
            source_total += row['size']
            zsh_sources += 1
        else:
            script_sources += 1
    require(source_total <= MAX_SOURCE_TOTAL and zsh_sources <= MAX_SOURCES and
            script_sources <= legacy().MAX_FILES, 'resource_limit')
    source_map = _indexed(sources)
    restricted_sources = {r['id'] for r in sources if value['schema'] >= 2 and environment.PRIVATE.search(r['path'])}
    restricted_loads = set()
    load_map, depths, last_order = {}, {}, -1
    for row in loads:
        keys(row, 'id source parent order context entry condition site')
        require(type(row['source']) is str and row['source'] in source_map and
                source_map[row['source']]['role'] == 'zsh', 'reference_invalid')
        integer(row['order'], 0, 2**31 - 1)
        require(row['order'] > last_order, 'ambiguous_record')
        last_order = row['order']
        require(row['context'] in ('noninteractive', 'interactive', 'login', 'interactive-login') and
                row['condition'] in ('unconditional', 'conditional', 'unknown'), 'unsupported_contract')
        parent = row['parent']
        if parent is None:
            require(row['entry'] in ('zshenv', 'zprofile', 'zshrc', 'zlogin', 'manual') and row['site'] is None)
            if row['entry'] in ('zprofile', 'zlogin'):
                require(row['context'] in ('login', 'interactive-login'))
            if row['entry'] == 'zshrc':
                require(row['context'] in ('interactive', 'interactive-login'))
            depth = 1
        else:
            require(type(parent) is str and parent in load_map, 'reference_invalid')
            require(row['entry'] == 'source' and row['context'] == load_map[parent]['context'])
            span(row['site'], source_map[load_map[parent]['source']]['size'])
            depth = depths[parent] + 1
        require(depth <= MAX_LOAD_DEPTH, 'resource_limit')
        require(row['id'] == load_identity(row) and row['id'] not in load_map, 'identity_invalid')
        load_map[row['id']], depths[row['id']] = row, depth
        if row['source'] in restricted_sources or parent in restricted_loads:
            restricted_loads.add(row['id'])
    for row in refs:
        keys(row, 'id member offset length sha256')
        require(type(row['member']) is str and type(row['sha256']) is str and HEX.fullmatch(row['sha256']))
        integer(row['offset'], 0, MAX_DEFINITION_TOTAL)
        integer(row['length'], 1, legacy().MAX_FILE_BYTES)
    ref_map = _indexed(refs)
    require(type(payloads) is dict and all(type(k) is str and type(v) is bytes for k, v in payloads.items()),
            'content_invalid')
    require(len(payloads) <= legacy().MAX_FILES + 1 and
            sum(len(raw) for raw in payloads.values()) <= MAX_DEFINITION_TOTAL + legacy().MAX_CONTENT_BYTES,
            'resource_limit')
    for row in items:
        keys(row, 'id kind key source loads content details')
        require(value['schema'] >= 2 or row['kind'] in KINDS, 'unsupported_contract')
        require(row['id'] == item_identity(row), 'identity_invalid')
    item_map = _indexed(items)
    names = [row['key'] for row in items if row['kind'] in ('alias', 'function')]
    require(len(names) == len(set(names)), 'ambiguous_record')
    used_sources, used_loads, used_refs, used_members = set(), set(), set(), set()
    offset, script_bytes, declarations, aliases, scripts = 0, 0, 0, 0, []
    environment_order = {}
    alias_definitions = []
    intervals = {}
    for row in items:
        require(type(row['source']) is str and row['source'] in source_map, 'reference_invalid')
        source = source_map[row['source']]
        used_sources.add(row['source'])
        require(type(row['loads']) is list and all(type(v) is str and v in load_map for v in row['loads']),
                'reference_invalid')
        require(row['loads'] == sorted(set(row['loads']), key=lambda k: load_map[k]['order']), 'ambiguous_record')
        if row['kind'] in environment.KINDS:
            require(restricted_loads.isdisjoint(row['loads']), 'content_invalid')
        for load in row['loads']:
            require(load_map[load]['source'] == row['source'], 'reference_invalid')
            while load is not None and load not in used_loads:
                used_loads.add(load)
                used_sources.add(load_map[load]['source'])
                load = load_map[load]['parent']
        require(type(row['content']) is str and row['content'] in ref_map and
                row['content'] == content_identity(row['id']), 'reference_invalid')
        ref = ref_map[row['content']]
        require(row['content'] not in used_refs and ref['member'] in payloads, 'reference_invalid')
        used_refs.add(row['content']); used_members.add(ref['member'])
        raw = payloads[ref['member']]
        require(ref['offset'] + ref['length'] <= len(raw), 'content_invalid')
        content = raw[ref['offset']:ref['offset'] + ref['length']]
        require(digest(content) == ref['sha256'], 'content_invalid')
        text = utf8(content)
        if row['kind'] == 'script':
            require(source['role'] == 'script' and source['path'] == row['key'] and not row['loads'])
            keys(row['details'], 'mode managed consent quarantine')
            require(row['details']['consent'] == 'file-transfer')
            require(ref['member'] == legacy().MEMBER_PREFIX + legacy().script_id(row['key']) + '.data' and
                    ref['offset'] == 0 and ref['length'] == len(raw) == source['size'] and
                    ref['sha256'] == source['sha256'], 'content_invalid')
            script_bytes += len(raw)
            scripts.append(dict(path=row['key'], text=text, sha256=ref['sha256'],
                                mode=row['details']['mode'], managed=row['details']['managed'],
                                quarantine=row['details']['quarantine']))
        else:
            declarations += 1
            require(source['role'] == 'zsh' and row['loads'], 'reference_invalid')
            require(ref['member'] == DEFINITIONS and ref['offset'] == offset, 'content_invalid')
            require(ref['length'] <= MAX_DEFINITION, 'resource_limit')
            offset += ref['length']
            details = row['details']
            if row['kind'] not in environment.KINDS:
                keys(details, 'span mode' if row['kind'] == 'alias' else 'span body name parser_profile')
            first, last = span(details['span'], source['size'])
            require(last - first == len(content), 'content_invalid')
            intervals.setdefault(row['source'], []).append((first, last))
            if row['kind'] in environment.KINDS:
                family = (row['source'], row['kind'], row['key'])
                environment_order.setdefault(family, []).append((first, details['ordinal']))
                try:
                    kind, name, intent = environment.classify(text, settings=value['schema'] == 3)
                except environment.Excluded:
                    raise Invalid('content_invalid') from None
                require(row['kind'] == kind and row['key'] == name and
                        json.dumps(details['intent'], sort_keys=True) == json.dumps(intent, sort_keys=True),
                        'content_invalid')
            elif row['kind'] == 'alias':
                aliases += 1
                require(details['mode'] == 'ordinary', 'unsupported_contract')
                try:
                    parsed = legacy().base.typed_declaration(text)
                except ValueError:
                    raise Invalid('content_invalid') from None
                require(parsed is not None and parsed[0]['name'] == row['key'], 'content_invalid')
                alias_definitions.append(parsed[0])
            else:
                require(details['parser_profile'] == 'zsh-default-1', 'unsupported_contract')
                body = span(details['body'], source['size'])
                name = span(details['name'], source['size'])
                require(first <= name[0] < name[1] <= body[0] < body[1] <= last, 'content_invalid')
                require(content[name[0] - first:name[1] - first] == row['key'].encode(), 'content_invalid')
                utf8(content[body[0] - first:body[1] - first])
    require(declarations <= MAX_DECLARATIONS and aliases <= legacy().base.MAX_ITEMS and
            len(scripts) <= legacy().MAX_FILES and script_bytes <= legacy().MAX_CONTENT_BYTES and
            offset <= MAX_DEFINITION_TOTAL, 'resource_limit')
    require(not offset or len(payloads[DEFINITIONS]) == offset, 'content_invalid')
    require(used_sources == set(source_map) and used_loads == set(load_map) and
            used_refs == set(ref_map) and used_members == set(payloads), 'reference_invalid')
    for occurrences in environment_order.values():
        ordinals = [n for _, n in sorted(occurrences)]
        require(ordinals == sorted(set(ordinals)), 'ambiguous_record')
    for ranges in intervals.values():
        ranges.sort()
        require(all(left[1] <= right[0] for left, right in zip(ranges, ranges[1:])), 'ambiguous_record')
    # Reuse v5's bytes/mode/path/quarantine/language contract, without I/O or
    # inventing a second Script implementation. Capture consent is not Restore consent.
    try:
        if scripts:
            context = dict(aliases=alias_definitions,
                           roots=[source_map[row['source']]['path'] for row in loads if row['parent'] is None],
                           layout=[dict(path=row['path']) for row in sources if row['role'] == 'zsh'])
            require(all(legacy().script_path(context, row['path'], typed=True) for row in scripts), 'content_invalid')
            # The legacy envelope checks payloads only; its source model cannot
            # represent typed repeated loads. Check actual selected context above.
            legacy().validated(dict(legacy().empty_capture(), version=5, scripts=scripts))
    except (ValueError, TypeError, UnicodeError):
        raise Invalid('content_invalid') from None
    ordered_reads = {(_dependency_order(r), tuple(r['site'])) for r in parameter_dependencies(items, loads)}
    if 'selection_evidence' in value:
        proof = value['selection_evidence']
        keys(proof, 'declarations bindings ancestors')
        ancestors = proof['ancestors']
        require(type(ancestors) is dict and len(ancestors) <= MAX_SOURCES, 'resource_limit')
        for key, data in ancestors.items():
            require(re.fullmatch(r'shell-source:[0-9a-f]{64}', key) and type(data) is list and len(data) == 2 and
                    type(data[0]) is str and HEX.fullmatch(data[0]), 'reference_invalid')
            integer(data[1], 0, MAX_SOURCE)
        witnesses = proof['declarations']
        require(value['schema'] >= 2 and type(witnesses) is dict and bool(witnesses) and
                len(witnesses) + declarations <= MAX_DECLARATIONS, 'resource_limit')
        for key, receipt in witnesses.items():
            require(re.fullmatch(r'shell-(?:variable|path-operation|initializer|setting|alias|function):[0-9a-f]{64}', key)
                    and key not in item_map, 'reference_invalid')
            require(value['schema'] == 3 or not key.startswith('shell-setting:'), 'unsupported_contract')
            keys(receipt, 'unit sha256 size offset family ordinal visits')
            visits = _rows(receipt, 'visits', MAX_LOADS)
            require(visits, 'reference_invalid')
            for route in visits:
                require(type(route) is list and 1 <= len(route) <= MAX_LOAD_DEPTH, 'reference_invalid')
                for index, step in enumerate(route):
                    require(type(step) is list and len(step) == 2, 'reference_invalid')
                    integer(step[0], 0, 2**31 - 1)
                    if index:
                        span(step[1], MAX_SOURCE)
                    else:
                        require(step[1] is None, 'reference_invalid')
                orders = [step[0] for step in route]
                require(orders == sorted(set(orders)), 'ambiguous_record')
            ends = [route[-1][0] for route in visits]
            require(ends == sorted(set(ends)), 'ambiguous_record')
            require(all(type(receipt[k]) is str and HEX.fullmatch(receipt[k]) for k in ('unit', 'sha256')))
            integer(receipt['size'], 1, MAX_SOURCE)
            integer(receipt['offset'], 0, receipt['size'] - 1)
            if key.startswith(('shell-alias:', 'shell-function:')):
                require(receipt['family'] == key and receipt['ordinal'] is None, 'reference_invalid')
            else:
                require(type(receipt['family']) is str and re.fullmatch(
                    re.escape(key.split(':')[0]) + r':[0-9a-f]{64}', receipt['family']), 'reference_invalid')
                integer(receipt['ordinal'], 0, MAX_DECLARATIONS - 1)
        bindings = proof['bindings']
        require(type(bindings) is dict and len(bindings) <= MAX_DECLARATIONS, 'resource_limit')
        for key, fingerprint in bindings.items():
            require((key in item_map or key in witnesses) and
                    key.startswith(('shell-variable:', 'shell-path-operation:', 'shell-initializer:', 'shell-setting:')) and
                    type(fingerprint) is str and HEX.fullmatch(fingerprint), 'reference_invalid')
    orders = []
    for row in dependencies:
        keys(row, 'owner target relation phase evidence site')
        require(type(row['owner']) is str and row['owner'] in item_map, 'reference_invalid')
        keys(row['target'], 'id kind key')
        target = row['target']
        if row['relation'] == 'reads':
            require(type(target['id']) is str and target['id'] in item_map and
                    all(target[k] == item_map[target['id']][k] for k in ('kind', 'key')) and
                    row['evidence'] == 'preceding-declaration' and row['phase'] == 'startup' and
                    type(row['site']) is list and len(row['site']) == 2 and all(type(n) is int for n in row['site']) and
                    (_dependency_order(row), tuple(row['site'])) in ordered_reads, 'reference_invalid')
            orders.append(_dependency_order(row))
            continue
        require(item_map[row['owner']]['kind'] not in environment.KINDS, 'unsupported_contract')
        require(target['id'] == identity(target['kind'], target['key']), 'identity_invalid')
        allowed = {'calls': ('function', 'invocation'), 'expands': ('alias', 'parse'),
                   'executes': ('script', 'invocation')}
        require(type(row['relation']) is str and row['relation'] in allowed and
                allowed[row['relation']] == (target['kind'], row['phase']) and
                row['evidence'] in ('static-reference', 'unresolved'), 'unsupported_contract')
        owner = item_map[row['owner']]
        if row['site'] is None:
            require(row['evidence'] == 'unresolved')
        else:
            site = span(row['site'], source_map[owner['source']]['size'])
            if owner['kind'] != 'script':
                bounds = owner['details']['span']
                require(bounds[0] <= site[0] < site[1] <= bounds[1], 'reference_invalid')
        orders.append(_dependency_order(row))
    require(orders == sorted(set(orders)), 'ambiguous_record')
    require(value['schema'] == declaration_schema(items), 'unsupported_contract')
    require(contracts == _contracts(items, dependencies, selection_evidence='selection_evidence' in value), 'unsupported_contract')


def decode(raw, payloads) -> ShellState:
    require(type(raw) is bytes and len(raw) <= MAX_MANIFEST, 'resource_limit')
    require(raw.startswith(MAGICS), 'unsupported_contract')
    value = _json(raw[len(MAGIC):], MAX_MANIFEST)
    _validate(value, payloads)
    require(raw.startswith(MAGICS[value['schema'] - 1]), 'unsupported_contract')
    return ShellState(value, dict(payloads))


def encode(state):
    require(type(state) is ShellState)
    _json_tree(state._value)
    _validate(state._value, state._payloads)
    raw = MAGICS[state._value['schema'] - 1] + (json.dumps(state._value, sort_keys=True, ensure_ascii=True, separators=(',', ':')) + '\n').encode()
    require(len(raw) <= MAX_MANIFEST, 'resource_limit')
    return raw, dict(sorted(state._payloads.items()))


def content(value, item):
    ref = next(row for row in value._value['content_refs'] if row['id'] == item['content'])
    return value._payloads[ref['member']][ref['offset']:ref['offset'] + ref['length']]


def script_value(value):
    """Project validated typed files into the existing independent v5 policy."""
    scripts = [dict(path=row['key'], text=utf8(content(value, row)),
                    sha256=digest(content(value, row)), mode=row['details']['mode'],
                    managed=row['details']['managed'], quarantine=row['details']['quarantine'])
               for row in value._value['items'] if row['kind'] == 'script']
    return legacy().validated(dict(legacy().empty_capture(), version=5, scripts=scripts)) if scripts else None


def with_scripts(value, scripts):
    """Attach only explicitly authorized v5 files; never infer dependencies."""
    encode(value)
    sources = list(value._value['sources'])
    items = [{k: v for k, v in row.items() if k != 'content'} for row in value._value['items']]
    contents = {row['id']: content(value, row) for row in value._value['items']}
    for script in scripts:
        raw = script['text'].encode('utf-8')
        source = source_record(script['path'], raw, 'script')
        row = dict(id=identity('script', script['path']), kind='script', key=script['path'],
                   source=source['id'], loads=[], details=dict(mode=script['mode'], managed=script['managed'],
                   consent='file-transfer', quarantine=script.get('quarantine')))
        sources.append(source); items.append(row); contents[row['id']] = raw
    return assemble(sources, value._value['loads'], items, value._value['dependencies'], contents,
                    selection_evidence=value._value.get('selection_evidence'))


def declaration_schema(items):
    if any(row['kind'] == 'setting' for row in items):
        return 3
    return 2 if any(row['kind'] in environment.VARIABLE_KINDS for row in items) else 1


def assemble(sources, loads, items, dependencies, contents, *, selection_evidence=None) -> ShellState:
    """Build canonical private records from explicit items; never infer selection."""
    value = dict(schema=1, semantic_profile=SEMANTICS, resource_profile=RESOURCES,
                 required_contracts={}, sources=sources, loads=loads, items=items,
                 dependencies=dependencies, content_refs=[])
    if selection_evidence:
        value['selection_evidence'] = selection_evidence
    _json_tree(value)
    for name, limit in (('sources', MAX_SOURCES + legacy().MAX_FILES), ('loads', MAX_LOADS),
                        ('items', MAX_DECLARATIONS + legacy().MAX_FILES), ('dependencies', MAX_DEPENDENCIES)):
        _rows(value, name, limit)
    # Copy bounded caller data before adding content references or sorting.
    value = json.loads(json.dumps(value))
    for row in value['items']:
        keys(row, 'id kind key source loads details')
        require(row['id'] == item_identity(row), 'identity_invalid')
    schema = declaration_schema(value['items'])
    value.update(schema=schema, semantic_profile=f'shell-semantics-{schema}')
    require(type(contents) is dict and set(contents) == {r['id'] for r in value['items']}, 'reference_invalid')
    require(all(type(raw) is bytes for raw in contents.values()) and
            sum(len(raw) for raw in contents.values()) <= MAX_DEFINITION_TOTAL + legacy().MAX_CONTENT_BYTES,
            'resource_limit')
    value['items'].sort(key=lambda row: row['id'])
    refs, payloads, definitions, offset = [], {}, [], 0
    for row in value['items']:
        raw = contents[row['id']]
        row['content'] = content_identity(row['id'])
        member = legacy().MEMBER_PREFIX + legacy().script_id(row['key']) + '.data' if row['kind'] == 'script' else DEFINITIONS
        refs.append(dict(id=row['content'], member=member, offset=0 if row['kind'] == 'script' else offset,
                         length=len(raw), sha256=digest(raw)))
        if row['kind'] == 'script':
            payloads[member] = raw
        else:
            require(len(raw) <= MAX_DEFINITION, 'resource_limit')
            definitions.append(raw); offset += len(raw)
            require(offset <= MAX_DEFINITION_TOTAL, 'resource_limit')
    if definitions:
        payloads[DEFINITIONS] = b''.join(definitions)
    value['content_refs'] = sorted(refs, key=lambda row: row['id'])
    try:
        value['sources'].sort(key=lambda row: row['id'])
        value['loads'].sort(key=lambda row: row['order'])
        value['dependencies'].sort(key=_dependency_order)
        value['required_contracts'] = _contracts(value['items'], value['dependencies'], selection_evidence='selection_evidence' in value)
    except (KeyError, TypeError):
        raise Invalid('schema_invalid') from None
    state = ShellState(value, payloads)
    # Both entry points enforce the identical wire and semantic contract.
    return decode(*encode(state))


def declaration_routes(row, loads):
    routes = []
    for key in row['loads']:
        route = []
        while key is not None:
            visit = loads[key]
            route.append(visit)
            key = visit['parent']
        routes.append(route[::-1])
    return routes


def declaration_receipt(row, raw, loads):
    """Pin the sequence of physical source routes independently of byte and traversal indices."""
    routes = [[[visit[k] for k in ('source', 'context', 'entry', 'condition')] for visit in route]
              for route in declaration_routes(row, loads)]
    evidence = [row['kind'], row['key'], row['source'], routes, digest(raw)]
    return digest(json.dumps(evidence, separators=(',', ':')).encode())


def binding_receipt(edges):
    """Fingerprint the ordered-reader contract without exporting omitted binding names."""
    return digest(json.dumps(sorted(edge['target']['id'] for edge in edges), separators=(',', ':')).encode())


def declaration_family(row):
    if row['kind'] in environment.KINDS:
        return item_identity(dict(row, details=dict(row['details'], ordinal=0)))
    return row['id']


def select(state, item_ids) -> ShellState:
    """Keep only explicit items/bytes, ancestry and outgoing dependency evidence."""
    value = decode(*encode(state))._value
    require(type(item_ids) is list and len(item_ids) <= MAX_DECLARATIONS + legacy().MAX_FILES and
            all(type(v) is str for v in item_ids), 'selection_invalid')
    selected = set(item_ids)
    require(len(selected) == len(item_ids) and selected <= {r['id'] for r in value['items']}, 'selection_invalid')
    items = [r for r in value['items'] if r['id'] in selected]
    loads = {r['id']: r for r in value['loads']}
    used_loads = set()
    for row in items:
        for key in row['loads']:
            while key is not None and key not in used_loads:
                used_loads.add(key)
                key = loads[key]['parent']
    used_sources = {r['source'] for r in items} | {loads[k]['source'] for k in used_loads}
    refs = {r['id']: r for r in value['content_refs']}
    contents = {}
    for row in items:
        ref = refs[row.pop('content')]
        contents[row['id']] = state._payloads[ref['member']][ref['offset']:ref['offset'] + ref['length']]
    proof = None
    if any(r['kind'] in environment.KINDS for r in items):
        previous = value.get('selection_evidence', {})
        witnesses = dict(previous.get('declarations', {}))
        ancestors = dict(previous.get('ancestors', {}))
        sources = {r['id']: r for r in value['sources']}
        for row in value['items']:
            if row['id'] not in selected and row['kind'] != 'script' and not any(
                    d['owner'] == row['id'] and d['relation'] != 'reads' for d in value['dependencies']):
                source = sources[row['source']]
                for visit in row['loads']:
                    parent = loads[visit]['parent']
                    while parent is not None:
                        ancestor = sources[loads[parent]['source']]
                        ancestors[ancestor['id']] = [ancestor['sha256'], ancestor['size']]
                        parent = loads[parent]['parent']
                witnesses[row['id']] = dict(unit=declaration_receipt(row, content(state, row), loads),
                    sha256=source['sha256'], size=source['size'], offset=row['details']['span'][0],
                    family=declaration_family(row), ordinal=row['details'].get('ordinal'),
                    visits=[[[v['order'], v['site']] for v in route] for route in declaration_routes(row, loads)])
        if declaration_schema(items) < 3:
            witnesses = {key: receipt for key, receipt in witnesses.items() if not key.startswith('shell-setting:')}
        if witnesses:
            bindings = dict(previous.get('bindings', {}))
            by_owner = {}
            for edge in value['dependencies']:
                if edge['relation'] == 'reads':
                    by_owner.setdefault(edge['owner'], []).append(edge)
            for owner, edges in by_owner.items():
                if owner in witnesses or any(e['target']['id'] in witnesses for e in edges):
                    bindings.setdefault(owner, binding_receipt(edges))
            bindings = {key: mark for key, mark in bindings.items() if key in witnesses or key in selected}
            proof = dict(declarations=witnesses, bindings=bindings, ancestors=ancestors)
    return assemble([r for r in value['sources'] if r['id'] in used_sources],
                    [r for r in value['loads'] if r['id'] in used_loads], items,
                    [r for r in value['dependencies'] if r['owner'] in selected and
                     (r['relation'] != 'reads' or r['target']['id'] in selected)], contents, selection_evidence=proof)


def parser_response(source, response, returncode):
    """Validate a complete private helper result, including zero definitions."""
    require(type(returncode) is int and returncode == 0, 'parser_invalid')
    require(type(source) is bytes and len(source) <= MAX_SOURCE, 'resource_limit')
    utf8(source)
    value = _json(response, 128 * 1024 - 1)
    fields = 'schema profile status code bytes sha256 nodes syntax_depth allocation_peak definitions'
    if type(value) is dict and 'statements' in value:
        fields += ' statements'
        if value['statements'] is not None:
            previous = 0
            # Helper protocol capacity, independent of the observer's selected
            # declaration budget (as for definitions below).
            for bounds in _rows(value, 'statements', MAX_STATEMENTS):
                first, last = span(bounds, len(source))
                require(first >= previous, 'parser_invalid')
                previous = last
    keys(value, fields)
    require(type(value['schema']) is int and value['schema'] == 1 and value['profile'] == 'zsh-default-1' and
            value['status'] == 'ok' and value['code'] == 'ok' and type(value['bytes']) is int and
            value['bytes'] == len(source) and value['sha256'] == digest(source), 'parser_invalid')
    integer(value['nodes'], 0, 65536)
    integer(value['syntax_depth'], 0, 32)  # Counted nesting, distinct from AST depth below.
    integer(value['allocation_peak'], 1, 128 * 1024 * 1024)
    definitions = _rows(value, 'definitions', 512)
    require(value['nodes'] >= max(1, len(definitions)), 'parser_invalid')
    stack, previous = [], -1
    for position, row in enumerate(definitions):
        keys(row, 'span body names parent depth')
        first, last = span(row['span'], len(source))
        body = span(row['body'], len(source))
        require(previous <= first and last - first <= MAX_DEFINITION and
                first <= body[0] < body[1] <= last, 'parser_invalid')
        previous = first
        while stack and first >= definitions[stack[-1]]['span'][1]:
            stack.pop()
        integer(row['parent'], -1, position - 1)
        require(row['parent'] == (stack[-1] if stack else -1), 'parser_invalid')
        if stack:
            parent_body = definitions[stack[-1]]['body']
            require(parent_body[0] <= first < last <= parent_body[1], 'parser_invalid')
        stack.append(position)
        integer(row['depth'], 0, 256)
        names = _rows(row, 'names', 16)
        end = first
        for name in names:
            a, b = span(name, len(source))
            require(end <= a < b <= body[0], 'parser_invalid')
            utf8(source[a:b]); end = b
        utf8(source[first:last]); utf8(source[body[0]:body[1]])
    return value


def function_evidence(source, response, returncode, index):
    """Return one exact named outer unit; no activation or Restore authority."""
    value = parser_response(source, response, returncode)
    require(type(index) is int and 0 <= index < len(value['definitions']), 'parser_invalid')
    row = value['definitions'][index]
    require(row['parent'] == -1 and len(row['names']) == 1, 'ambiguous_record')
    name = row['names'][0]
    key = utf8(source[name[0]:name[1]])
    identity('function', key)
    first, last = row['span']
    return key, source[first:last], dict(span=row['span'], body=row['body'], name=name, parser_profile=value['profile'])


def load_position(loads, key, offset):
    """Private position in a validated depth-first B1 load traversal."""
    row = loads[key]
    order = [offset]
    while row['parent'] is not None:
        order.insert(0, row['site'][0])
        row = loads[row['parent']]
    return (row['order'], *order)


def parameter_dependencies(items, loads):
    """Record preceding saved declarations, without claiming runtime binding."""
    load_map = {r['id']: r for r in loads}
    visits = {}
    count = 0
    for row in items:
        if row['kind'] not in environment.KINDS:
            continue
        for key in row['loads']:
            count += 1
            require(count <= MAX_DEPENDENCIES, 'resource_limit')
            context = load_map[key]['context']
            position = load_position(load_map, key, row['details']['span'][0])
            visits.setdefault(context, []).append((position, row))
    edges = {}
    for events in visits.values():
        previous = {}
        for _, row in sorted(events, key=lambda event: event[0]):
            intent = row['details']['intent']
            writes, names = environment.parameter_uses(row['key'], intent)
            for name in names:
                target = previous.get(name)
                if target and target['id'] != row['id']:
                    key = (row['id'], target['id'])
                    edges[key] = dict(owner=row['id'], relation='reads', phase='startup',
                        evidence='preceding-declaration', site=row['details']['span'],
                        target={k: target[k] for k in ('id', 'kind', 'key')})
                    require(len(edges) <= MAX_DEPENDENCIES, 'resource_limit')
            for name in writes:
                previous[name] = row
    return sorted(edges.values(), key=_dependency_order)


def declaration_order(snapshot):
    """One portable order satisfying every saved relative declaration order.

    Load sites interleave parent declarations and sourced declarations. This is
    an ordering projection of validated B1 evidence, never Shell evaluation.
    Contradictory context orders cannot be flattened into a managed file.
    """
    loads = {r['id']: r for r in snapshot._value['loads']}
    items = {r['id']: r for r in snapshot._value['items'] if r['kind'] != 'script'}
    edges = {key: set() for key in items}
    rank = {}
    contexts = {}
    for item in items.values():
        for key in item['loads']:
            row = loads[key]
            order = load_position(loads, key, item['details']['span'][0])
            contexts.setdefault(row['context'], []).append((order, item['id']))
    for rows in contexts.values():
        ids = [key for _, key in sorted(rows)]
        require(len(ids) == len(set(ids)), 'ambiguous_record')
        for key in ids:
            rank.setdefault(key, len(rank))
        for before, after in zip(ids, ids[1:]):
            edges[after].add(before)
    result = []
    while edges:
        ready = [key for key, parents in edges.items() if not parents]
        require(ready, 'ambiguous_record')
        key = min(ready, key=lambda key: (rank.get(key, MAX_DECLARATIONS), key))
        result.append(items[key]); del edges[key]
        for parents in edges.values():
            parents.discard(key)
    return result
