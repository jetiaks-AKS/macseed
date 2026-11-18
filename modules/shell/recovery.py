"""Capabilities 3/4/5: selected structure and opt-in, bounded script recovery.

No evaluator, directory crawler, package installer or managed-dotfile writer.
Capabilities 1/2 retain declaration-only semantics. Recovery proves qualified
configuration and dependencies, never the outcome of running a user's command.
"""
import base64
import hashlib
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import shlex
import stat

spec = importlib.util.spec_from_file_location('shell_recovery_sources', Path(__file__).with_name('sources.py'))
sources = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sources)
base = sources.base
MAGIC = b'MBT-ZSH-ALIASES-3\n'
OPAQUE_MAGIC = b'MBT-ZSH-ALIASES-4\n'
OPAQUE_POLICY = 'opaque-file-v4'
MAX_SCRIPT_BYTES = 8192
FILE_MAGIC = b'MBT-ZSH-ALIASES-5\n'
FILE_POLICY = 'opaque-file-v5'
MAX_FILES = 128
MAX_FILE_BYTES = 1024 * 1024
MAX_CONTENT_BYTES = 16 * 1024 * 1024
MAX_MANIFEST_BYTES = 256 * 1024
MAX_QUARANTINE_BYTES = 256
MEMBER_PREFIX = 'generated/shell/scripts/'
REQUEST_NAME = 'shell-scripts-request.json'
# Closed self-contained commands may be reconstructed as declarations in a new
# default .zshrc even when unrelated source initialization was excluded.
INDEPENDENT_COMMANDS = {
    '/bin/pwd': {(), ('-P',)}, '/bin/date': {(), ('-u',)},
    '/usr/bin/uname': {(), ('-s',), ('-a',)},
    '/bin/ls': {(), ('-l',), ('-la',), ('-a',)},
    '/usr/bin/git': {('status',), ('status', '--short'), ('diff', '--stat')},
}
BUILTINS = {'cd', 'pwd', 'echo', 'printf', 'true', 'false'}
TOOL_DIRS = ('/usr/bin', '/bin', '/usr/sbin', '/sbin', '/opt/homebrew/bin', '/usr/local/bin')


def encode(value):
    if value['version'] == 5:
        value = dict(value, scripts=[file_record(row) for row in value['scripts']])
        return FILE_MAGIC + (json.dumps(value, ensure_ascii=True, separators=(',', ':')) + '\n').encode()
    return (OPAQUE_MAGIC if value['version'] in (4, 5) else MAGIC) + (json.dumps(value, ensure_ascii=True, separators=(',', ':')) + '\n').encode()


def file_record(row):
    return dict(id=script_id(row['path']), path=row['path'], size=len(row['text'].encode()),
                sha256=row['sha256'], mode=row['mode'], managed=row['managed'],
                member=MEMBER_PREFIX + script_id(row['path']) + '.data', consent='file-transfer',
                quarantine=row.get('quarantine'))


def contents(value):
    return {file_record(row)['member']: row['text'].encode() for row in value['scripts']} if value['version'] == 5 else {}


def validated(value):
    return snapshot(encode(value), contents(value))


def save(path, value):
    """Write only validated, operation-private staging data; never user scripts."""
    value = validated(value)
    path = Path(path)
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    files = contents(value)
    directory = path.parent / 'scripts'
    if directory.exists() or directory.is_symlink():
        if directory.is_symlink() or not directory.is_dir():
            raise base.Invalid('unsafe_file')
        for old in directory.iterdir():
            if not base.re.fullmatch('[0-9a-f]{64}\.data', old.name):
                raise base.Invalid('invalid_script_members')
            if MEMBER_PREFIX + old.name not in files:
                base.read_file(old, private=True, limit=MAX_FILE_BYTES)
                old.unlink()
    for member, raw in files.items():
        destination = path.parent / 'scripts' / Path(member).name
        destination.parent.mkdir(mode=0o700, exist_ok=True)
        if destination.parent.is_symlink():
            raise base.Invalid('unsafe_file')
        fd = os.open(destination, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
        with os.fdopen(fd, 'wb') as stream:
            stream.write(raw)
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, 'wb') as stream:
        stream.write(encode(value))


def load(path):
    path = Path(path)
    raw = base.read_file(path, private=True, limit=MAX_MANIFEST_BYTES)
    def read(member):
        directory = path.parent / 'scripts'
        fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if info.st_uid != os.getuid() or info.st_mode & 0o022:
                raise base.Invalid('unsafe_file')
            return base.read_file(Path(member).name, fd, private=True, limit=MAX_FILE_BYTES)
        finally:
            os.close(fd)
    return snapshot(raw, read) if raw.startswith(FILE_MAGIC) else base.snapshot(raw)


def expand_request(value):
    """Bounded operation-scoped references; generic Protocol V1 stays at 4 KiB."""
    parameters = value.get('parameters')
    if not isinstance(parameters, dict) or 'script_manifest' not in parameters:
        return
    if value.get('operation') not in ('capture_script_inspect', 'capture_prepare', 'capture_execute',
                                     'restore_prepare', 'restore_execute', 'secure_restore_compare'):
        raise base.Invalid('invalid_script_request')
    directory = Path(os.environ.get('TMPDIR', '')).resolve()
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o700:
            raise base.Invalid('invalid_script_request')
        raw = base.read_file(REQUEST_NAME, fd, private=True, limit=MAX_MANIFEST_BYTES)
        if (before.st_dev, before.st_ino) != (directory.stat().st_dev, directory.stat().st_ino):
            raise base.Invalid('invalid_script_request')
    finally:
        os.close(fd)
    def unique(pairs):
        result = {}
        for key, val in pairs:
            if key in result:
                raise base.Invalid('invalid_script_request')
            result[key] = val
        return result
    control = json.loads(raw, object_pairs_hook=unique)
    if (hashlib.sha256(raw).hexdigest() != parameters.pop('script_manifest')
            or not isinstance(control, dict) or set(control) != {'version', 'operation_id', 'parameters'}
            or type(control['version']) is not int or control['version'] != 5
            or control['operation_id'] != value['operation_id'] or not isinstance(control['parameters'], dict)):
        raise base.Invalid('invalid_script_request')
    fields = control['parameters']
    allowed = {'scripts', 'shell_script_paths', 'shell_script_ids', 'shell_script_selection', 'shell_items'}
    if not fields or set(fields) - allowed or set(fields) & set(parameters):
        raise base.Invalid('invalid_script_request')
    if 'shell_items' in fields:
        items = fields.pop('shell_items')
        selection = parameters.get('selection')
        if (not isinstance(selection, dict) or not isinstance(selection.get('items'), dict)
                or 'shell-zsh' in selection['items'] or not isinstance(items, list) or len(items) > 384):
            raise base.Invalid('invalid_script_request')
        selection['items']['shell-zsh'] = items
    parameters.update(fields)


def source_value(value):
    return {key: (2 if key == 'version' else value[key]) for key in ('version', 'coverage', 'roots', 'aliases')}


def script_id(path):
    return hashlib.sha256(('shell-script:' + path).encode()).hexdigest()


def file_identity(path):
    return 'shell-script:' + script_id(path)


def standalone(value):
    deps = sources.dependencies(dict(value, scripts=[]))
    return [script for script in value['scripts'] if script['path'] not in deps] if value['version'] in (4, 5) else []


def requirement_ids(value):
    return [base.identity(row['name']) for row in value['aliases']] + [file_identity(row['path']) for row in standalone(value)]


def script_mode(mode, version=4):
    # Preserve ordinary read/execute bits. No set-id, sticky or shared write bits.
    required = 0o400 if version == 5 else 0o500
    return type(mode) is int and 0 <= mode <= 0o777 and mode & required == required and not mode & 0o022


def script_analysis(text):
    """Qualify inert transfer, never certify the effects of executing a program.

    Literal process wrappers only. Complex control flow, data/file operands,
    executable interpreters, credential indicators and encoded payloads fail closed.
    Commands remain explicit external prerequisites; no recursive content reads.
    """
    rejected = lambda reason: dict(qualified=False, reason=reason, commands=[])
    if (not isinstance(text, str) or len(text.encode()) > 8192 or not text.endswith('\n')
            or any(ord(c) < 32 and c not in '\n\t' for c in text) or not text.isascii()):
        return rejected('script_format_unsupported')
    lines = text.splitlines()
    if not lines or lines[0] not in ('#!/bin/sh', '#!/bin/bash', '#!/bin/zsh') or len(lines) > 128:
        return rejected('script_format_unsupported')
    # Previously accepted v3 wrappers retain their exact reader meaning. In
    # particular date -u is a known UTC option, not an ambiguous credential flag.
    legacy = lines[0] == '#!/bin/sh' and 1 <= len(lines[1:]) <= 16 and all(
        line == ' '.join(line.split()) and bool(line.split())
        and tuple(line.split()[1:]) in INDEPENDENT_COMMANDS.get(line.split()[0], set()) for line in lines[1:])
    if legacy:
        return dict(qualified=True, reason=None, commands=sorted({'/bin/sh', *(line.split()[0] for line in lines[1:])}))
    if base.SENSITIVE.search(text):
        return rejected('script_sensitive_indicator')
    commands = [lines[0][2:]]
    interpreters = {'sh', 'bash', 'zsh', 'dash', 'ksh', 'csh', 'tcsh', 'fish', 'env', 'xargs',
                    'python', 'python3', 'perl', 'ruby', 'osascript', 'node', 'swift', 'awk', 'sed',
                    'sudo', 'doas', 'su', 'eval', 'exec', 'source', '.', 'command', 'builtin'}
    statements = 0
    for line in lines[1:]:
        line = line.strip()
        if not line or line.startswith('#'):
            # Even comments may contain private machine paths or opaque values.
            if any(c in line for c in '/$`=') or base.re.search(r'[A-Za-z0-9_+-]{40,}', line):
                return rejected('script_sensitive_or_nonportable')
            continue
        if any(c in line for c in '$`\\;|&<>(){}[]*?!~='):
            return rejected('script_dynamic_or_dependency')
        try:
            words = shlex.split(line)
        except ValueError:
            return rejected('script_format_unsupported')
        if (not words or len(words) > 32 or not base.re.fullmatch(r'(?:/(?:usr/bin|bin|usr/sbin|sbin)/)?[A-Za-z][A-Za-z0-9_.+-]{0,63}', words[0])):
            return rejected('script_dynamic_or_dependency')
        if (Path(words[0]).name in interpreters or Path(words[0]).name in base.RESERVED
                or base.re.fullmatch(r'(?:python|perl|ruby|node|bash|zsh|sh)[0-9.]*', Path(words[0]).name)):
            return rejected('script_dynamic_or_dependency')
        # No embedded code, URLs, paths or opaque/credential values. A relative
        # data operand is ambiguous, so only literal flags, numbers and the
        # established Git read-only verbs are supported as arguments.
        verbs = {'status', 'diff', 'log', 'show', 'branch', 'rev-parse'} if Path(words[0]).name == 'git' else set()
        if any(not (base.re.fullmatch(r'-{1,2}[A-Za-z0-9][A-Za-z0-9-]{0,31}', word)
                    or base.re.fullmatch(r'[0-9]{1,6}', word) or word in verbs) for word in words[1:]):
            return rejected('script_dependency_unqualified')
        statements += 1
        if statements > 16:
            return rejected('script_limit')
        commands.append(words[0])
    return dict(qualified=bool(statements), reason=None if statements else 'script_empty', commands=sorted(set(commands)))


def opaque_analysis(text, *, version=4, path='', mode=0o700):
    """Bounded UTF-8 Shell file as exact bytes, not a program safety analysis.

    Sensitive-content indicators fail closed. Their absence is not certification;
    body dependencies/behavior remain unknown and no referenced file is inspected.
    """
    rejected = lambda reason: dict(qualified=False, reason=reason, commands=[])
    if (not isinstance(text, str) or len(text.encode('utf-8')) > (MAX_FILE_BYTES if version == 5 else MAX_SCRIPT_BYTES)
            or any(ord(c) < 32 and c not in '\n\r\t' for c in text) or '\x7f' in text):
        return rejected('script_format_unsupported')
    lines = text.splitlines()
    interpreters = {name: [name] for name in ('/bin/sh', '/bin/bash', '/bin/zsh', '/usr/bin/python3')}
    interpreters.update(('/usr/bin/env ' + name, ['/usr/bin/env', name])
                        for name in ('sh', 'bash', 'zsh', 'python3', 'python'))
    interpreter = lines[0][2:] if lines and lines[0].startswith('#!') else None
    # Extensions qualify non-executable text only. Executable/extensionless files
    # always need supported interpreter evidence; never infer execution safety.
    extension = Path(path).suffix.lower()
    if version == 5 and interpreter is None and not mode & 0o111 and extension in ('.sh', '.bash', '.zsh', '.py') and text.strip():
        interpreter = '/usr/bin/python3' if extension == '.py' else '/bin/zsh' if extension == '.zsh' else '/bin/bash' if extension == '.bash' else '/bin/sh'
    if interpreter not in interpreters:
        return rejected('script_format_unsupported')
    # Content is never evaluated. Restrict known credential material and literal
    # assignments, including commented examples: normal Bundle bytes are plaintext.
    sensitive = base.re.compile(
        r'-----BEGIN (?:[A-Z ]*PRIVATE KEY|PGP PRIVATE KEY)|'
        r'\b(?:AKIA|ASIA)[A-Z0-9]{16}\b|\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,})|'
        r'://(?=[^\s/@]*:)[^\s/]*@|'
        r'(?i:authorization\s*[:=]\s*[\"\']?(?:bearer|basic)\s+[A-Za-z0-9+/=_-]{8,})')
    if sensitive.search(text):
        return rejected('script_sensitive_indicator')
    names = r'[A-Za-z_][A-Za-z0-9_]*(?:TOKEN|PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL)[A-Za-z0-9_]*'
    names = r'(?:TOKEN|PASSWORD|PASSWD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL|' + names + ')'
    assignments = base.re.finditer(r'(?im)\b' + names + r'''["']?\s*[:=]\s*([^\n;]*)''', text)
    for match in assignments:
        literal = match[1].strip()
        if literal not in ("''", '\"\"', '') and not base.re.fullmatch(r'\"?\$(?:[A-Za-z_][A-Za-z0-9_]*|\{[A-Za-z_][A-Za-z0-9_]*\})\"?', literal):
            return rejected('script_sensitive_indicator')
    return dict(qualified=True, reason=None, commands=interpreters[interpreter])


def transfer_analysis(text, version, path='', mode=0o700):
    return opaque_analysis(text, version=version, path=path, mode=mode) if version in (4, 5) else script_analysis(text)


def script_valid(text):
    return script_analysis(text)['qualified']


def script_path(value, path, *, typed=False):
    # An executable payload must never double as a startup/source file. This
    # boundary also applies to older v3 data; consent cannot waive activation.
    reserved = {*sources.STARTUP, '.zlogout', '.profile', '.bashrc', '.bash_profile', '.bash_login'}
    if Path(path).name.casefold() in reserved or path.casefold().endswith('.zwc') or path.casefold() in {root.casefold() for root in value['roots']}:
        return False
    for row in value['aliases']:
        legacy = base.declaration(row['statement'], True)
        if typed and legacy is None:
            body = base.typed_declaration(row['statement'])[1]
            lexer = shlex.shlex(body, posix=True, punctuation_chars=True)
            lexer.whitespace_split = True
            lexer.commenters = ''
            words = list(lexer)
            if not {'source', '.'}.isdisjoint(words):
                # Only a single literal source operand can exclude an exact
                # destination. Complex source expressions cannot authorize files.
                if len(words) != 2 or words[0] not in ('source', '.') or not base.home_reference(words[1]):
                    return False
        else:
            words = shlex.split(legacy[1])
        if words[0] in ('source', '.') and (base.home_reference(words[1]) or '').casefold() == path.casefold():
            return False
    return path.casefold() not in {item['path'].casefold() for item in value['layout']}


def opaque_path(path):
    parts = [part.casefold() for part in Path(path).parts]
    return not any(part in {'.ssh', '.gnupg', '.aws', '.azure', '.kube', '.git', '.netrc', '.npmrc', '.pypirc'}
                   or part == '.env' or part.startswith('.env.') for part in parts)


def quarantine_record(raw):
    if raw is None:
        return None
    # Preserve the original record exactly, including flags and event identifier.
    # Never infer trust or synthesize a less restrictive quarantine value.
    if (not isinstance(raw, bytes) or not 1 <= len(raw) <= MAX_QUARANTINE_BYTES
            or not base.re.fullmatch(rb'[0-9A-Fa-f]{1,8};[0-9A-Fa-f]{1,16};[\x20-\x3a\x3c-\x7e]{0,128};(?:[0-9A-Fa-f]{8}(?:-[0-9A-Fa-f]{4}){3}-[0-9A-Fa-f]{12})?', raw)):
        raise base.Invalid('script_quarantine_invalid')
    return dict(version=1, data=base64.b64encode(raw).decode('ascii'), sha256=hashlib.sha256(raw).hexdigest())


def quarantine_bytes(record):
    if record is None:
        return None
    if (not isinstance(record, dict) or set(record) != {'version', 'data', 'sha256'}
            or type(record['version']) is not int or record['version'] != 1
            or not isinstance(record['data'], str) or len(record['data']) > 4 * ((MAX_QUARANTINE_BYTES + 2) // 3)):
        raise base.Invalid('script_quarantine_invalid')
    try:
        raw = base64.b64decode(record['data'], validate=True)
    except (ValueError, UnicodeError) as exc:
        raise base.Invalid('script_quarantine_invalid') from exc
    if quarantine_record(raw) != record:
        raise base.Invalid('script_quarantine_invalid')
    return raw


def opaque_metadata(directory, name, *, version=4):
    # Harmless v5 annotations are neither transferred nor trusted as identity.
    # Legacy readers retain their original provenance-only policy. V5 quarantine
    # is the only transferred xattr; all other names remain a closed allowlist.
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    try:
        info = os.fstat(fd)
        lib = sources.native()
        if version == 5:
            metadata = sources.attributes(fd)
            quarantine = quarantine_record(metadata.get(b'com.apple.quarantine'))
            allowed = {b'com.apple.provenance', b'com.apple.TextEncoding',
                       b'com.apple.metadata:kMDItemDownloadedDate',
                       b'com.apple.metadata:kMDItemWhereFroms', b'com.apple.lastuseddate#PS', b'com.apple.quarantine'}
            if set(metadata) - allowed:
                raise base.Invalid('unsupported_metadata')
        else:
            size = lib.flistxattr(fd, None, 0, 0)
            allowed = b'com.apple.provenance\0'
            if size not in (0, len(allowed)):
                raise base.Invalid('unsupported_metadata')
            names = sources.C.create_string_buffer(size)
            if lib.flistxattr(fd, names, size, 0) != size or names.raw not in (b'', allowed):
                raise base.Invalid('unsupported_metadata')
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                or info.st_flags):
            raise base.Invalid('unsupported_metadata')
        base.acl_safe(fd)
        if base.stamp(info) != base.stamp(os.stat(name, dir_fd=directory, follow_symlinks=False)):
            raise base.Invalid('target_changed')
        return quarantine if version == 5 else None
    finally:
        os.close(fd)


def snapshot(raw, payloads=None):
    magic = FILE_MAGIC if raw.startswith(FILE_MAGIC) else OPAQUE_MAGIC if raw.startswith(OPAQUE_MAGIC) else MAGIC
    version = 5 if magic == FILE_MAGIC else 4 if magic == OPAQUE_MAGIC else 3
    if not raw.startswith(magic) or len(raw) > (MAX_MANIFEST_BYTES if version == 5 else base.MAX_BYTES):
        raise base.Invalid('invalid_recovery')
    def unique(pairs):
        result = {}
        for key, val in pairs:
            if key in result:
                raise base.Invalid('invalid_recovery')
            result[key] = val
        return result
    value = json.loads(raw[len(magic):], object_pairs_hook=unique)
    if not isinstance(value, dict) or set(value) != {'version', 'coverage', 'roots', 'aliases', 'layout', 'scripts'} or type(value['version']) is not int or value['version'] != version:
        raise base.Invalid('invalid_recovery')
    if version == 5:
        # Startup/source structure retains its historical budget independently.
        if len(encode(dict(value, version=3, scripts=[]))) > base.MAX_BYTES:
            raise base.Invalid('invalid_recovery')
        records = value['scripts']
        if not isinstance(records, list) or not 0 <= len(records) <= MAX_FILES:
            raise base.Invalid('script_count_limit')
        seen, total = set(), 0
        for row in records:
            if (not isinstance(row, dict) or set(row) != {'id', 'path', 'size', 'sha256', 'mode', 'managed', 'member', 'consent', 'quarantine'}
                    or not isinstance(row['path'], str) or not sources.portable(row['path'])
                    or row['id'] != script_id(row['path']) or row['member'] != MEMBER_PREFIX + row['id'] + '.data'
                    or row['consent'] != 'file-transfer' or row['path'].casefold() in seen
                    or type(row['size']) is not int or not 0 < row['size'] <= MAX_FILE_BYTES
                    or not isinstance(row['sha256'], str) or not base.re.fullmatch('[0-9a-f]{64}', row['sha256'])):
                raise base.Invalid('invalid_script_manifest')
            quarantine_bytes(row['quarantine'])
            seen.add(row['path'].casefold())
            total += row['size']
        if total > MAX_CONTENT_BYTES:
            raise base.Invalid('script_total_limit')
        if payloads is None or (isinstance(payloads, dict) and set(payloads) != {row['member'] for row in records}):
            raise base.Invalid('invalid_script_members')
        scripts = []
        for row in records:
            content = payloads(row['member']) if callable(payloads) else payloads[row['member']]
            if not isinstance(content, bytes) or len(content) != row['size'] or hashlib.sha256(content).hexdigest() != row['sha256']:
                raise base.Invalid('script_integrity_mismatch')
            scripts.append(dict(path=row['path'], text=content.decode('utf-8'), sha256=row['sha256'], mode=row['mode'], managed=row['managed'], **({'quarantine': row['quarantine']} if row['quarantine'] is not None else {})))
        value['scripts'] = scripts
    sources.snapshot(sources.encode(source_value(value)), allow_empty=version in (4, 5))
    paths = set().union(*(set(row['chain']) for row in value['aliases']))
    aliases = {row['name']: row for row in value['aliases']}
    if not isinstance(value['layout'], list) or len(value['layout']) != len(paths):
        raise base.Invalid('invalid_recovery')
    layouts, seen_aliases, edges = {}, set(), set()
    for item in value['layout']:
        if (not isinstance(item, dict) or set(item) != {'path', 'entries', 'managed', 'closed'}
                or not isinstance(item['path'], str) or item['path'] not in paths or item['path'] in layouts
                or type(item['managed']) is not bool or type(item['closed']) is not bool
                or not isinstance(item['entries'], list) or len(item['entries']) > base.MAX_ITEMS + sources.MAX_FILES):
            raise base.Invalid('invalid_recovery')
        layouts[item['path']] = item
        for entry in item['entries']:
            if not isinstance(entry, dict) or len(entry) != 1:
                raise base.Invalid('invalid_recovery')
            if 'alias' in entry:
                name = entry['alias']
                if not isinstance(name, str) or name not in aliases or aliases[name]['source'] != item['path'] or name in seen_aliases:
                    raise base.Invalid('invalid_recovery')
                seen_aliases.add(name)
            elif 'source' in entry:
                dest = entry['source']
                if not isinstance(dest, str) or dest not in paths or (item['path'], dest) in edges:
                    raise base.Invalid('invalid_recovery')
                edges.add((item['path'], dest))
            else:
                raise base.Invalid('invalid_recovery')
    wanted_edges = set().union(*(set(zip(row['chain'], row['chain'][1:])) for row in value['aliases']))
    if seen_aliases != set(aliases) or edges != wanted_edges:
        raise base.Invalid('invalid_recovery')
    ordered = []
    def walk(path, chain):
        if len(chain) > sources.MAX_DEPTH or path in chain:
            raise base.Invalid('invalid_recovery')
        for entry in layouts.get(path, {}).get('entries', []):
            if 'source' in entry:
                walk(entry['source'], [*chain, path])
            else:
                row = aliases[entry['alias']]
                if row['chain'] != [*chain, path]:
                    raise base.Invalid('invalid_recovery')
                ordered.append(row['name'])
    for root in value['roots']:
        walk(root, [])
    if ordered != list(aliases):
        raise base.Invalid('invalid_recovery')
    deps = sources.dependencies(dict(value, scripts=[]))
    if (not isinstance(value['scripts'], list) or len(value['scripts']) > (MAX_FILES if version == 5 else 16)
            or (not value['aliases'] and not value['scripts'])):
        raise base.Invalid('invalid_recovery')
    seen_scripts = set()
    for script in value['scripts']:
        if (not isinstance(script, dict) or set(script) != (({'path', 'text', 'sha256', 'mode', 'managed'} | ({'quarantine'} if 'quarantine' in script and version == 5 else set())) if version in (4, 5) else {'path', 'text', 'sha256', 'mode'})
                or not isinstance(script['path'], str) or not sources.portable(script['path'])
                or (value['version'] == 3 and not deps.get(script['path'])) or script['path'] in paths
                or script['path'].casefold() in seen_scripts or not script_path(value, script['path']) or not script_mode(script['mode'], version)
                or (version in (4, 5) and not opaque_path(script['path']))
                or (version in (4, 5) and type(script['managed']) is not bool)
                or not transfer_analysis(script['text'], version, script['path'], script['mode'])['qualified'] or script['sha256'] != hashlib.sha256(script['text'].encode()).hexdigest()):
            raise base.Invalid('invalid_recovery')
        seen_scripts.add(script['path'].casefold())
    return value


def empty_capture():
    # Internal observation only; an empty snapshot is never serialized/published.
    return dict(version=3, coverage='partial', roots=list(sources.STARTUP), aliases=[], layout=[], scripts=[])


def manual_paths(value, home, paths):
    """Normalize explicitly picked paths without resolving links or reading content."""
    if not paths:
        return []
    source_paths = {path.casefold() for path in sources.observe(home)['files']}
    result = set()
    known = sources.dependency_states(value, home, transfer=True)
    identities = {state[1][0][:2]: path for path, state in sorted(known.items(), reverse=True) if state[0] == 'ready'}
    for path in paths:
        if '..' in Path(path).parts or not path.startswith(home + '/'):
            raise base.Invalid('script_path_unsupported')
        relative = os.path.normpath(path)[len(home) + 1:]
        if (not sources.portable(relative) or not opaque_path(relative) or not script_path(value, relative)
                or relative.casefold() in source_paths):
            raise base.Invalid('script_path_unsupported')
        state = sources.dependency_states(value, home, [relative], transfer=True)[relative]
        if state[0] == 'ready':
            identity = state[1][0][:2]
            with sources.parent(home, relative, read_only=True) as (directory, name, check):
                fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
                try:
                    # Darwin F_GETPATH returns the filesystem's canonical spelling,
                    # after link/owner checks, without following a selected link.
                    canonical = os.fsdecode(fcntl.fcntl(fd, 50, bytes(1024)).split(b'\0', 1)[0])
                    if base.stamp(os.fstat(fd)) != state[1][0] or not canonical.startswith(home + '/'):
                        raise base.Invalid('target_changed')
                    check()
                finally:
                    os.close(fd)
            relative = identities.setdefault(identity, canonical[len(home) + 1:])
            if not sources.portable(relative) or not opaque_path(relative) or not script_path(value, relative):
                raise base.Invalid('script_path_unsupported')
        result.add(relative)
    return sorted(result)


def capture(home, allow_empty=False):
    graph = sources.observe(home)
    if not graph['aliases']:
        if allow_empty:
            return dict(empty_capture(), roots=graph['roots'])
        raise base.Invalid('no_supported_aliases')
    value = dict(version=3, coverage='partial', roots=graph['roots'], aliases=graph['aliases'], layout=[], scripts=[])
    paths = set().union(*(set(row['chain']) for row in value['aliases']))
    names = {row['statement']: row['name'] for row in value['aliases']}
    edges = set().union(*(set(zip(row['chain'], row['chain'][1:])) for row in value['aliases']))
    for path in sorted(paths):
        raw, info = graph['files'][path]
        commands, hidden = sources.top_level(raw)
        entries, closed = [], not hidden
        for statement, _ in commands:
            if statement in names:
                entries.append({'alias': names[statement]})
            else:
                match = sources.re.fullmatch(r'(?:source|\.)\s+(.+)', statement)
                dest = sources.reference(match[1], home) if match else None
                if (path, dest) in edges:
                    entries.append({'source': dest})
                elif match or base.declaration(statement, extended=True) is None:
                    closed = False
        managed = bool(info[1][1] or sources.MANAGED.search(raw.decode()))
        value['layout'].append(dict(path=path, entries=entries, managed=managed, closed=closed))
    return snapshot(encode(value))


def select(value, names):
    rows = [row for row in value['aliases'] if row['name'] in names]
    paths = set().union(*(set(row['chain']) for row in rows))
    edges = set().union(*(set(zip(row['chain'], row['chain'][1:])) for row in rows))
    selected = dict(value, aliases=rows, layout=[dict(item, entries=[entry for entry in item['entries']
        if entry.get('alias') in names or (item['path'], entry.get('source')) in edges])
        for item in value['layout'] if item['path'] in paths])
    deps = sources.dependencies(dict(selected, scripts=[]))
    selected['scripts'] = [script for script in value['scripts'] if script['path'] in deps
                          or (value['version'] in (4, 5) and file_identity(script['path']) in names)]
    return validated(selected)


def script_candidates(value, home, script_paths=(), policy=None):
    states = sources.dependency_states(value, home, script_paths, transfer=policy == FILE_POLICY or value['version'] == 5)
    paths = {item['path'] for item in value['layout']}
    dependencies = dict(sources.dependencies(value), **dict.fromkeys(script_paths, True))
    candidates, identities = [], set()
    for path, executable in sorted(dependencies.items()):
        if not (executable or value['version'] == 5) or path in paths or not script_path(value, path) or states[path][0] != 'ready':
            continue
        identity = states[path][1][0][:2]
        if identity in identities:
            continue
        identities.add(identity)
        candidates.append(dict(id=script_id(path), path=path))
    return candidates[:MAX_FILES if policy == FILE_POLICY or value['version'] == 5 else 16]


def selection_candidates(value, home=None, script_paths=(), policy=None):
    """UI-safe associations, never implicit consent.

    Capture observes metadata only until explicit inspection/selection. Bundle inspection
    exposes only already validated payloads. Freshness is opaque to the client.
    """
    states = sources.dependency_states(value, home, script_paths, transfer=policy == FILE_POLICY or value['version'] == 5) if home is not None else None
    candidates = script_candidates(value, home, script_paths, policy) if home is not None else [
        dict(id=script_id(row['path']), path=row['path']) for row in value['scripts']]
    payloads = {row['path']: row for row in value['scripts']}
    return [dict(row, **({'independent': True} if value['version'] in (4, 5) or row['path'] in script_paths else {}),
        alias_ids=[base.identity(alias['name']) for alias in value['aliases']
        if any(executable and (path == row['path'] or (states is not None and states.get(path, ('missing',))[0] == 'ready'
            and states[path][1][0][:2] == states[row['path']][1][0][:2]))
            for path, executable in sources.dependencies(dict(value, aliases=[alias], scripts=[])).items())],
        observation_id=hashlib.sha256(json.dumps(states[row['path']] if states is not None else payloads[row['path']],
            sort_keys=True).encode()).hexdigest()) for row in candidates]


def authorize_capture(value, home, approvals, expected=None, policy=None, script_paths=()):
    version = 5 if policy == FILE_POLICY else 4 if policy == OPAQUE_POLICY else value['version']
    if policy not in (None, OPAQUE_POLICY, FILE_POLICY):
        raise base.Invalid('unsupported_script_policy')
    candidates = {row['id']: row['path'] for row in script_candidates(value, home, script_paths, policy)}
    if not set(approvals) <= set(candidates):
        raise base.Invalid('invalid_script_consent')
    scripts = []
    before = sources.dependency_states(value, home, script_paths, transfer=version == 5)
    if any(before.get(candidates[key], ('missing',))[0] != 'ready' for key in approvals):
        raise base.Invalid('target_changed')
    if expected is not None and before != expected:
        raise base.Invalid('target_changed')
    if version == 5 and sum(before[candidates[key]][1][0][7] for key in approvals) > MAX_CONTENT_BYTES:
        raise base.Invalid('script_total_limit')
    total = 0
    for key in approvals:
        path = candidates[key]
        if version in (4, 5) and not opaque_path(path):
            raise base.Invalid('script_path_unsupported')
        with sources.parent(home, path, read_only=True) as (fd, name, check):
            # Only now, after explicit per-file authorization, read contents.
            if version in (4, 5):
                quarantine = opaque_metadata(fd, name, version=version)
            if os.stat(name, dir_fd=fd, follow_symlinks=False).st_size > (MAX_FILE_BYTES if version == 5 else MAX_SCRIPT_BYTES):
                raise base.Invalid('script_limit')
            text = base.read_file(name, fd, limit=MAX_FILE_BYTES if version == 5 else MAX_SCRIPT_BYTES).decode('utf-8')
            total += len(text.encode())
            if version == 5 and total > MAX_CONTENT_BYTES:
                raise base.Invalid('script_total_limit')
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            management = check()[1]
            if (not script_mode(stat.S_IMODE(info.st_mode), version) or (version in (4, 5) and info.st_flags)
                    or not transfer_analysis(text, version, path, stat.S_IMODE(info.st_mode))['qualified']):
                raise base.Invalid('script_transfer_unsupported')
            scripts.append(dict(path=path, text=text, sha256=hashlib.sha256(text.encode()).hexdigest(), mode=stat.S_IMODE(info.st_mode),
                **({'managed': bool(management or sources.MANAGED.search(text))} if version in (4, 5) else {}),
                **({'quarantine': quarantine} if version == 5 and quarantine is not None else {})))
    if sources.dependency_states(value, home, script_paths, transfer=version == 5) != before:
        raise base.Invalid('target_changed')
    return validated(dict(value, version=version, scripts=sorted(scripts, key=lambda row: row['path'])))


def inspect_scripts(value, home, requested, policy=None, script_paths=()):
    """Explicit, exact-file content inspection; no payload publication or consent grant."""
    if policy not in (None, OPAQUE_POLICY, FILE_POLICY):
        raise base.Invalid('unsupported_script_policy')
    version = 5 if policy == FILE_POLICY else 4 if policy == OPAQUE_POLICY else value['version']
    candidates = {row['id']: row for row in selection_candidates(value, home, script_paths, policy)}
    result, payloads, inspected = [], [], set()
    total = 0
    if version == 5:
        observed = sources.dependency_states(value, home, script_paths, transfer=True)
        selected = [observed[candidates[key]['path']] for key in requested if key in candidates]
        if sum(state[1][0][7] for state in selected if state[0] == 'ready') > MAX_CONTENT_BYTES:
            return [dict(id=key, observation_id=observation, status='unsupported', reason='script_total_limit')
                    for key, observation in requested.items()]
    for key, observation in requested.items():
        row = candidates.get(key)
        status, reason = 'unverified', 'script_changed'
        if row is not None and row['observation_id'] == observation:
            try:
                with sources.parent(home, row['path'], read_only=True) as (fd, name, check):
                    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    if policy in (OPAQUE_POLICY, FILE_POLICY) and not opaque_path(row['path']):
                        status, reason = 'unsupported', 'script_path_unsupported'
                    elif not script_mode(stat.S_IMODE(info.st_mode), version) or (policy in (OPAQUE_POLICY, FILE_POLICY) and info.st_flags):
                        status, reason = 'unsupported', 'script_permissions_unsupported'
                    elif info.st_size > (MAX_FILE_BYTES if version == 5 else MAX_SCRIPT_BYTES):
                        status, reason = 'unsupported', 'script_file_limit' if version == 5 else 'script_limit'
                    else:
                        if policy in (OPAQUE_POLICY, FILE_POLICY):
                            opaque_metadata(fd, name, version=version)
                        raw = base.read_file(name, fd, limit=MAX_FILE_BYTES if version == 5 else MAX_SCRIPT_BYTES)
                        analysis = transfer_analysis(raw.decode('utf-8'), version, row['path'], stat.S_IMODE(info.st_mode))
                        status, reason = ('qualified', None) if analysis['qualified'] else ('unsupported', analysis['reason'])
                        if analysis['qualified']:
                            total += len(raw)
                            if version != 5:
                                payloads.append(dict(path=row['path'], text=raw.decode('utf-8'), mode=stat.S_IMODE(info.st_mode), sha256=hashlib.sha256(raw).hexdigest(),
                                    **({'managed': bool(check()[1] or sources.MANAGED.search(raw.decode('utf-8')))} if policy == OPAQUE_POLICY else {})))
                    check()
                inspected.add(key)
            except UnicodeError:
                status, reason = 'unsupported', 'script_format_unsupported'
            except (OSError, ValueError) as exc:
                status, reason = ('unsupported', 'script_metadata_unsupported') if str(exc) == 'unsupported_metadata' else ('unsupported', 'script_quarantine_invalid') if str(exc) == 'script_quarantine_invalid' else ('unverified', 'script_observation_failed')
        result.append(dict(id=key, observation_id=observation, status=status, reason=reason))
    if inspected:
        # Recheck the whole selection once after all reads, so a later read cannot
        # hide a change to an earlier file. Re-enumerating every file after each
        # read made maximum-size selections quadratic without stronger evidence.
        try:
            fresh = {item['id']: item for item in selection_candidates(value, home, script_paths, policy)}
        except (OSError, ValueError):
            for row in result:
                if row['id'] in inspected:
                    row.update(status='unverified', reason='script_observation_failed')
        else:
            for row in result:
                if row['id'] in inspected and fresh.get(row['id']) != candidates[row['id']]:
                    row.update(status='unverified', reason='script_changed')
    if (total > MAX_CONTENT_BYTES if version == 5
            else len(encode(dict(value, scripts=payloads))) > base.MAX_BYTES):
        for row in result:
            if row['status'] == 'qualified':
                row.update(status='unsupported', reason='script_total_limit' if version == 5 else 'script_limit')
    return result


def tool_state(command):
    if command in BUILTINS:
        return ('ready', 'builtin')
    for path in ([command] if command.startswith('/') else [directory + '/' + command for directory in TOOL_DIRS]):
        try:
            resolved = Path(path).resolve(strict=True)
            # Symlinked package executables are observable, but every real parent
            # must remain owned and non-writable by others. No program is run.
            for parent in (resolved, *resolved.parents):
                info = parent.stat()
                if info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022:
                    raise base.Invalid('unsafe_tool')
            info = resolved.stat()
            if not stat.S_ISREG(info.st_mode) or not info.st_mode & 0o111:
                raise base.Invalid('unsafe_tool')
            return ('ready', (str(resolved), base.stamp(info)))
        except FileNotFoundError:
            continue
        except (OSError, ValueError):
            return ('unverified', None)
    return ('missing', None)


def tools_for(value):
    commands = set()
    for row in value['aliases']:
        parsed = base.declaration(row['statement'], extended=True)
        words = shlex.split(parsed[1])
        if words[0] not in ('source', '.') and base.home_reference(words[0]) is None:
            commands.add(words[0])
    for script in value['scripts']:
        if value['version'] == 5 and script['path'] not in sources.dependencies(dict(value, scripts=[])):
            continue
        commands.update(transfer_analysis(script['text'], value['version'], script['path'], script['mode'])['commands'])
    return {command: tool_state(command) for command in sorted(commands)}


def directory_operand(row):
    body = base.declaration(row['statement'], True)[1]
    words, tokens = shlex.split(body), shlex.split(body, posix=False)
    if len(words) != 2 or words[0] != 'cd' or (tokens[1][:1] in "'\"" and tokens[1][1:].startswith('~')):
        return None
    return base.home_reference(words[1])


def directory_operands(value):
    return {path for row in value['aliases'] for path in [directory_operand(row)] if path is not None}


def operands_ready(value, home):
    for row in value['aliases']:
        words = shlex.split(base.declaration(row['statement'], True)[1])
        if words[0] in ('source', '.'):
            continue
        if directory_operand(row) is not None:
            try:
                with sources.parent(home, directory_operand(row) + '/.macseed-directory-probe', read_only=True) as (_, _, check):
                    check()
            except (OSError, ValueError):
                return False
        elif any('/' in word or word.startswith(('~', '$')) for word in words[1:]):
            return False
    return True


def dependency_reason(value, home):
    """Observation-bound explanation for this alias scope, without command values."""
    states = sources.dependency_states(value, home).values()
    if any(state[0] == 'unverified' for state in states):
        return 'dependency_observation_prerequisite'
    if any(state[0] == 'missing' for state in states):
        return 'dependency_missing_prerequisite'
    tools = tools_for(value).values()
    if any(state[0] == 'unverified' for state in tools):
        return 'tool_observation_prerequisite'
    if any(state[0] == 'missing' for state in tools):
        return 'tool_missing_prerequisite'
    for row in value['aliases']:
        path = directory_operand(row)
        if path is not None:
            try:
                with sources.parent(home, path + '/.macseed-directory-probe', read_only=True) as (_, _, check):
                    check()
            except FileNotFoundError:
                return 'directory_missing_prerequisite'
            except (OSError, ValueError):
                return 'directory_observation_prerequisite'
    if not operands_ready(value, home):
        return 'operand_unsupported_prerequisite'
    return None


def paths_for(value):
    return (set(value['roots']) | {item['path'] for item in value['layout']} | set(sources.dependencies(value))
            | {path + '/.macseed-directory-probe' for path in directory_operands(value)})


def independent_root(value, item):
    """No source activation or tool-specific initialization is inferred here."""
    if value['roots'] != list(sources.STARTUP) or item['path'] != '.zshrc' or not item['entries'] or any('source' in entry for entry in item['entries']):
        return False
    names = {entry['alias'] for entry in item['entries']}
    for row in value['aliases']:
        if row['name'] not in names:
            continue
        words = shlex.split(base.declaration(row['statement'], True)[1])
        command = words[0] if words[0].startswith('/') else '/bin/' + words[0]
        # A literal directory listing with ordinary display/sort flags has no
        # transferred file or initialization dependency. No operand is inferred.
        if command == '/bin/ls' and all(base.re.fullmatch(r'-[alhAGFdrtS1]+', word) for word in words[1:]):
            continue
        # Git needs repository context and is deliberately not independent.
        if command == '/usr/bin/git' or tuple(words[1:]) not in INDEPENDENT_COMMANDS.get(command, set()):
            return False
    return True


def observation(value, home, ignore_pending=()):
    """Bind both existing ancestors and absence, including disconnected files."""
    result, directories, documents = {}, {}, {}
    paths = set(value['roots']) | {item['path'] for item in value['layout']} | {row['path'] for row in value['scripts']}
    for path in sorted(paths):
        try:
            raw, stamp = sources.file_state(home, path, ignore_pending, limit=MAX_FILE_BYTES if value['version'] == 5 and path in {row['path'] for row in value['scripts']} else base.MAX_BYTES)
            result[path] = (hashlib.sha256(raw).hexdigest() if raw is not None else None, stamp)
            if value['version'] == 5 and raw is not None and path in {item['path'] for item in value['layout']} and stamp[0][5] == base.USER_READ_FLAGS:
                with sources.parent(home, path, read_only=True) as (fd, name, check):
                    info = os.stat(name, dir_fd=fd, follow_symlinks=False)
                    if base.stamp(info) != stamp[0]:
                        raise base.Invalid('target_changed')
                    documents[path] = sources.document_id(fd, name, info)
                    check()
        except FileNotFoundError:
            result[path] = ('missing_parent', None)
        except (OSError, ValueError):
            result[path] = ('unsafe', None)
    parents = {str(parent) for path in paths_for(value) for parent in Path(path).parents}
    for path in sorted(parents):
        try:
            probe = '.macseed-path-probe' if path == '.' else path + '/.macseed-path-probe'
            with sources.parent(home, probe, read_only=True) as (_, _, check):
                directories[path] = check()
        except FileNotFoundError:
            directories[path] = None
        except (OSError, ValueError):
            directories[path] = 'unsafe'
    return dict(files=result, directories=directories,
                graph=sources.evidence(source_value(value), home, ignore_pending), tools=tools_for(value),
                dependencies=sources.dependency_states(value, home),
                **({'documents': documents} if value['version'] == 5 else {}))


def evidence(value, home, ignore_pending=()):
    return hashlib.sha256(json.dumps(observation(value, home, ignore_pending), sort_keys=True).encode()).hexdigest()


def bounded_source_append(value, item, graph, raw, missing, candidate, home):
    """Qualify literal declarations at a known source EOF, not dynamic Shell state.

    No new source edge, dormant activation, guessed override or ambiguous suffix
    is authorized. Existing parser/observer limits and dependency gates still apply.
    """
    if (value['version'] != 5 or raw is None or item['managed'] or not missing
            or any(set(entry) != {'alias'} for entry in missing)
            or graph['failed'] or graph['repeated'] or item['path'] not in graph['files']):
        return False
    names = {entry['alias'] for entry in missing}
    rows = [row for row in value['aliases'] if row['name'] in names]
    if len(rows) != len(names) or any(
            row['source'] != item['path'] or row['chain'][0] not in graph['roots']
            or any(graph['files'].get(path, (None,))[0] is None for path in row['chain'])
            or any((a, b) not in graph['edges'] for a, b in zip(row['chain'], row['chain'][1:]))
            or graph['mentions'].get(row['name']) or row['name'] in graph['functions'] | graph['removed']
            for row in rows):
        return False
    try:
        original = base.statements(raw.decode())
        for statement in original:
            included = sources.re.fullmatch(r'(?:source|\.)\s+(.+)', statement)
            if included:
                destination = sources.reference(included[1], home)
                if (item['path'], destination) not in graph['edges'] or graph['files'].get(destination, (None,))[0] is None:
                    return False
        suffix = [next(row['statement'] for row in rows if row['name'] == entry['alias']) for entry in missing]
        if base.statements(candidate.decode()) != original + suffix:
            return False
        qualified, _ = base.classify(candidate, extended=True)
        return all({'name': row['name'], 'statement': row['statement']} in qualified for row in rows)
    except (UnicodeError, ValueError):
        return False


def safe_destination(home, path, *, managed_prerequisite=False):
    """Validate the longest existing prefix; missing directories are creatable."""
    parts = path.split('/')
    for index in range(len(parts)):
        prefix = '/'.join(parts[:index + 1])
        try:
            with sources.parent(home, prefix) as (directory, name, check):
                try:
                    info = os.stat(name, dir_fd=directory, follow_symlinks=False)
                except FileNotFoundError:
                    check(); return True
                if index < len(parts) - 1:
                    if not stat.S_ISDIR(info.st_mode):
                        return False
                check()
        except (OSError, ValueError) as exc:
            if managed_prerequisite and isinstance(exc, base.Invalid) and str(exc) == 'external_owner':
                raise base.Invalid('managed_source_prerequisite') from None
            return False
    return True


def script_state(script, home, *, limit=base.MAX_BYTES, version=4):
    """Read one authorized file within its version budget; never evaluate content."""
    try:
        with sources.parent(home, script['path'], read_only=True) as (fd, name, check):
            try:
                before = os.stat(name, dir_fd=fd, follow_symlinks=False)
            except FileNotFoundError:
                check()
                return 'missing'
            try:
                raw, info = sources.file_state(home, script['path'], limit=limit)
                if raw is None or base.stamp(before) != info[0]:
                    return 'unverified'
                quarantine = opaque_metadata(fd, name, version=version); check()
                if base.stamp(os.stat(name, dir_fd=fd, follow_symlinks=False)) != info[0]:
                    return 'unverified'
                return 'matching' if raw == script['text'].encode() and stat.S_IMODE(info[0][2]) == script['mode'] and quarantine == script.get('quarantine') else 'differing'
            except (OSError, ValueError):
                # Disappearance or replacement after a present observation is
                # uncertain evidence, never a fabricated confirmed absence.
                return 'unverified'
    except FileNotFoundError:
        return 'missing'
    except (OSError, ValueError):
        return 'unverified'


def alias_source_states(value, home):
    """Compare saved declarations in their qualified source, not an evaluated shell.

    A readable, bounded source can prove declaration absence even when unrelated
    startup commands prevent safe editing. Ambiguous names/chains remain unknown.
    Reuse the observer's ownership, link, grammar and freshness checks; never run
    startup code or qualify a write from this evidence.
    """
    states = dict.fromkeys((row['name'] for row in value['aliases']), 'unverified')
    try:
        graph = sources.observe(home)
    except (OSError, ValueError):
        return states
    actual = {row['name']: row for row in graph['aliases']}
    for row in value['aliases']:
        chain = row['chain']
        if (graph['roots'] != value['roots'] or chain[0] not in graph['roots']
                or any((a, b) not in graph['edges'] for a, b in zip(chain, chain[1:]))
                or any(path not in graph['files'] or path in graph['failed'] or path in graph['repeated'] for path in chain)):
            continue
        found = actual.get(row['name'])
        if found and found['source'] == row['source'] and found['chain'] == chain:
            states[row['name']] = ('matching' if base.declaration(found['statement'], True)[1]
                                   == base.declaration(row['statement'], True)[1] else 'differing')
        elif not graph['mentions'].get(row['name']) and row['name'] not in graph['functions']:
            states[row['name']] = 'missing'
    return states


def comparison(value, home):
    # Transfer consent is represented by the validated payload, not by an alias
    # dependency. Preserve historic planning identities; Check additionally owns
    # one file predicate for every capability-4/5 payload, even when aliases share it.
    if value['version'] not in (4, 5):
        return plan(value, home)
    observed = {script['path']: script_state(script, home, limit=MAX_FILE_BYTES if value['version'] == 5 else base.MAX_BYTES, version=value['version']) for script in value['scripts']}
    prepared = _group_plan(value, home, observed_scripts=observed)
    aliases = [row for row in prepared['rows'] if not row[0].get('file')]
    if any(state in ('unverified', 'differing') for _, state, _ in aliases):
        definitions = alias_source_states(value, home)
        # Editing prerequisites cannot erase definitive source-level absence or
        # differences. An identical declaration alone does not qualify its runtime
        # dependencies; retain their existing recovery result.
        aliases = [(row, (state if definitions[row['name']] == 'matching' else definitions[row['name']])
                    if state in ('unverified', 'differing') else state, policy) for row, state, policy in aliases]
    files = [(dict(name=file_identity(path), path=path, file=True), state, 'preserve')
             for path, state in observed.items()]
    return dict(prepared, rows=aliases + files)


def row_dependencies_ready(value, row, home, observed_scripts=None):
    subset = dict(value, aliases=[row], scripts=[])
    paths = sources.dependencies(subset)
    subset['scripts'] = [script for script in value['scripts'] if script['path'] in paths]
    if any(state[0] != 'ready' for state in sources.dependency_states(subset, home).values()):
        return False
    if any(state[0] != 'ready' for state in tools_for(subset).values()):
        return False
    for script in subset['scripts']:
        if observed_scripts is not None:
            if observed_scripts[script['path']] != 'matching':
                return False
            continue
        try:
            if value['version'] in (4, 5):
                with sources.parent(home, script['path'], read_only=True) as (fd, name, check):
                    quarantine = opaque_metadata(fd, name, version=value['version']); check()
            raw, info = sources.file_state(home, script['path'], limit=MAX_FILE_BYTES if value['version'] == 5 else base.MAX_BYTES)
            if raw != script['text'].encode() or stat.S_IMODE(info[0][2]) != script['mode'] or (value['version'] == 5 and quarantine != script.get('quarantine')) or (value['version'] in (4, 5) and info[0][5]):
                return False
        except (OSError, ValueError):
            return False
    return operands_ready(subset, home)


def plan(value, home, observed_scripts=None, *, source_files=None):
    """Keep v5 file publication independent of alias-source qualification.

    Reuse the same bounded planner for each file and the alias/source group.
    A rejected group contributes diagnostics, never writes. Legacy capability
    planning and physical Bundle identities retain their existing contracts.
    """
    if value['version'] != 5:
        if source_files is not None:
            raise base.Invalid('unsupported_contract')
        return _group_plan(value, home, observed_scripts)
    if source_files is not None and value['aliases']:
        raise base.Invalid('unsupported_contract')
    groups = []
    if value['aliases']:
        groups.append(_group_plan(select(value, {row['name'] for row in value['aliases']}), home, observed_scripts))
    for script in value['scripts']:
        groups.append(_group_plan(select(value, {file_identity(script['path'])}), home, observed_scripts, source_files=source_files))
    rows, writes, directories, reason = [], {}, set(), None
    for group in groups:
        for row, state, policy in group['rows']:
            if group['reason'] and state != 'matching':
                policy = group['reason']
                if not row.get('file') and state == 'unverified' and policy in ('dependency_prerequisite', 'tool_prerequisite', 'operand_prerequisite'):
                    policy = dependency_reason(select(value, {row['name']}), home) or 'selection_prerequisite'
            rows.append((row, state, policy))
        if group['reason']:
            reason = reason or group['reason']
        else:
            writes.update(group['writes'])
            directories.update(group['directories'])
    return dict(rows=rows, writes=writes, directories=sorted(directories, key=lambda p: (p.count('/'), p)), reason=reason)


def _group_plan(value, home, observed_scripts=None, *, source_files=None):
    """All-or-none qualification before any mutation; match includes dependencies."""
    file_rows = [dict(name=file_identity(script['path']), path=script['path'], file=True) for script in standalone(value)]
    rows, writes, dirs, reason = [], {}, set(), None
    try:
        for row in file_rows:
            script = next(item for item in value['scripts'] if item['path'] == row['path'])
            if observed_scripts is not None:
                rows.append((row, observed_scripts[row['path']], 'preserve'))
                continue
            try:
                raw, info = sources.file_state(home, row['path'], limit=MAX_FILE_BYTES if value['version'] == 5 else base.MAX_BYTES)
                if raw is None:
                    state = 'missing'
                else:
                    with sources.parent(home, row['path'], read_only=True) as (fd, name, check):
                        quarantine = opaque_metadata(fd, name, version=value['version']); check()
                    state = 'matching' if raw == script['text'].encode() and stat.S_IMODE(info[0][2]) == script['mode'] and quarantine == script.get('quarantine') else 'differing'
            except FileNotFoundError:
                state = 'missing'
            except (OSError, ValueError):
                state = 'unverified'
            rows.append((row, state, 'preserve'))
        # Typed definitions already have a protected native source observation.
        # Reuse its loaded files solely for independent v5 file admission; this
        # branch never qualifies alias/source publication or creates load edges.
        graph = (sources.observe(home) if source_files is None else
                 dict(files={p: (f['raw'], f['stamp']) for p, f in source_files.items()},
                      roots=value['roots'], failed=False, repeated=False, writable=False, aliases=[]))
        if source_files is not None and any(row['path'] in source_files for row in value['scripts']):
            raise base.Invalid('script_source_activation')
        if value['aliases'] and graph['roots'] != value['roots']:
            raise base.Invalid('startup_prerequisite')
        layout_paths = {item['path'] for item in value['layout']}
        repairable_failures = graph['failed'] and all(path in layout_paths and not (Path(home) / path).exists()
            and safe_destination(home, path) for path in graph['failed'])
        known_commands = source_files is not None or all(not sources.top_level(raw)[1] and all(alias is not None or
            (sources.re.fullmatch(r'(?:source|\.)\s+(.+)', command) and
             sources.reference(sources.re.fullmatch(r'(?:source|\.)\s+(.+)', command)[1], home))
            for command, alias in sources.top_level(raw)[0]) for raw, _ in graph['files'].values() if raw is not None)
        writable = graph['writable'] or (repairable_failures and known_commands)
        actual = {row['name']: row for row in graph['aliases']}
        expected = {row['name']: row for row in value['aliases']}
        for row in value['aliases']:
            found = actual.get(row['name'])
            matching = row_dependencies_ready(value, row, home, observed_scripts) and found and found['source'] == row['source'] and found['chain'] == row['chain'] and base.declaration(found['statement'], True)[1] == base.declaration(row['statement'], True)[1]
            rows.append((row, 'matching' if matching else 'missing', 'preserve'))
            if (not matching and graph['mentions'].get(row['name']) and
                    (not found or found['source'] != row['source'] or found['chain'] != row['chain'] or
                     base.declaration(found['statement'], True)[1] != base.declaration(row['statement'], True)[1])):
                raise base.Invalid('target_conflict')
        for item in value['layout']:
            path = item['path']
            try:
                raw, _ = sources.file_state(home, path)
            except FileNotFoundError:
                raw = None
            commands, hidden = sources.top_level(raw or b'')
            observed = []
            for statement, alias in commands:
                match = sources.re.fullmatch(r'(?:source|\.)\s+(.+)', statement)
                dest = sources.reference(match[1], home) if match else None
                if alias and alias['name'] in expected:
                    if alias['statement'] != expected[alias['name']]['statement']:
                        raise base.Invalid('target_conflict')
                    observed.append({'alias': alias['name']})
                elif dest and any(entry.get('source') == dest for entry in item['entries']):
                    observed.append({'source': dest})
            if raw is not None and path not in graph['files']:
                # Linking a dormant file activates all of it. Only the exact
                # selected, closed static slice can be safely connected.
                if hidden or len(observed) != len(commands) or observed != item['entries']:
                    raise base.Invalid('disconnected_source_conflict')
            # Existing selected entries must be an exact prefix; append only.
            if observed != item['entries'][:len(observed)]:
                raise base.Invalid('source_order_conflict')
            missing = item['entries'][len(observed):]
            if missing:
                if item['managed'] or not safe_destination(home, path):
                    raise base.Invalid('managed_source_prerequisite')
                lines = [expected[entry['alias']]['statement'] if 'alias' in entry else 'source "$HOME/' + entry['source'] + '"' for entry in missing]
                candidate = (raw or b'') + (b'\n' if raw and not raw.endswith(b'\n') else b'') + ('\n'.join(lines) + '\n').encode()
                if len(candidate) > base.MAX_BYTES:
                    raise base.Invalid('source_limit')
                bounded = bounded_source_append(value, item, graph, raw, missing, candidate, home)
                if not bounded and ((not item['closed'] and not (raw is None and independent_root(value, item))) or hidden or not writable or (graph['failed'] and not repairable_failures) or graph['repeated']):
                    raise base.Invalid('source_prerequisite')
                if raw is not None:
                    with sources.parent(home, path) as (fd, name, _):
                        sources.mutable_file(fd, name, tracked=bounded)
                writes[path] = (candidate, 0o600)
        scripts = {row['path']: row for row in value['scripts']}
        dependencies = sources.dependency_states(value, home)
        for path, executable in sources.dependencies(value).items():
            state = dependencies[path][0]
            if path in scripts:
                if state != 'ready' and path.casefold() in {source.casefold() for source in graph['files']}:
                    raise base.Invalid('script_source_activation')
                script = scripts[path]
                if executable and not script['mode'] & 0o100:
                    raise base.Invalid('dependency_prerequisite')
                if state == 'ready':
                    if observed_scripts is not None:
                        observed = observed_scripts[path]
                        if observed != 'matching':
                            raise base.Invalid('script_conflict' if observed == 'differing' else 'unsafe_dependency')
                        continue
                    if value['version'] in (4, 5):
                        with sources.parent(home, path, read_only=True) as (fd, name, check):
                            quarantine = opaque_metadata(fd, name, version=value['version']); check()
                    raw, info = sources.file_state(home, path, limit=MAX_FILE_BYTES if value['version'] == 5 else base.MAX_BYTES)
                    if value['version'] in (4, 5) and info[0][5]:
                        raise base.Invalid('unsafe_dependency')
                    if raw != script['text'].encode() or stat.S_IMODE(info[0][2]) != script['mode'] or (value['version'] == 5 and quarantine != script.get('quarantine')):
                        raise base.Invalid('script_conflict')
                elif state == 'missing' and safe_destination(home, path, managed_prerequisite=value['version'] in (4, 5)):
                    # `managed` records source provenance. Only actual target
                    # ownership blocks an explicitly consented missing-file copy.
                    writes[path] = (script['text'].encode(), script['mode'])
                else:
                    raise base.Invalid('unsafe_dependency')
            elif state != 'ready' and not (not executable and path in writes):
                raise base.Invalid('dependency_prerequisite')
        if any(state[0] != 'ready' for state in tools_for(value).values()):
            raise base.Invalid('tool_prerequisite')
        if not operands_ready(value, home):
            raise base.Invalid('operand_prerequisite')
        for path in writes:
            for parent in Path(path).parents:
                if str(parent) != '.' and not (Path(home) / parent).exists():
                    dirs.add(str(parent))
        # A disconnected pre-existing destination is not a safe place to append:
        # all known/unknown definitions there must be qualified before activation.
        for path in writes:
            if path not in graph['files'] and (Path(home) / path).exists():
                raise base.Invalid('disconnected_source_conflict')
        policies = {row['source']: ('add' if graph['files'].get(row['source'], (None,))[0] is not None else 'create') for row in value['aliases']}
        if writes:
            rows = [(row, state, ('create' if row.get('file') else policies[row['source']]) if state != 'matching' else 'preserve') for row, state, _ in rows]
        else:
            if any(state != 'matching' for _, state, _ in rows):
                raise base.Invalid('source_prerequisite')
    except (OSError, ValueError) as exc:
        reason = str(exc) if isinstance(exc, ValueError) else 'observation_failed'
        matches = {row['name'] for row, state, _ in rows if state == 'matching'}
        state = 'differing' if reason in ('target_conflict', 'source_order_conflict', 'script_conflict', 'disconnected_source_conflict') else 'unverified'
        rows = [(row, 'matching' if row['name'] in matches else state, 'preserve') for row in [*file_rows, *value['aliases']]]
        writes, dirs = {}, set()
    return dict(rows=rows, writes=writes, directories=sorted(dirs, key=lambda p: (p.count('/'), p)), reason=reason)


def assess(value, home):
    return plan(value, home)['rows']


def restore_scripts(value, home, *, source_files=None):
    writes = plan(value, home, source_files=source_files)['writes']
    return [dict(id=script_id(row['path']), path=row['path']) for row in value['scripts'] if row['path'] in writes]


def verify_quarantine(fd, record):
    if sources.attributes(fd).get(b'com.apple.quarantine') != quarantine_bytes(record):
        raise base.Invalid('script_quarantine_mismatch')


def apply_quarantine(fd, record):
    raw = quarantine_bytes(record)
    if raw is not None:
        lib = sources.native()
        lib.fsetxattr.argtypes = [sources.C.c_int, sources.C.c_char_p, sources.C.c_void_p,
                                 sources.C.c_size_t, sources.C.c_uint, sources.C.c_int]
        lib.fsetxattr.restype = sources.C.c_int
        # Only the validated quarantine attribute is writable through this path.
        # Never clear an inherited protection or overwrite a different one.
        current = sources.attributes(fd).get(b'com.apple.quarantine')
        if current is not None and current != raw:
            raise base.Invalid('script_quarantine_mismatch')
        if current is None and lib.fsetxattr(fd, b'com.apple.quarantine', raw, len(raw), 0, 2):
            raise base.Invalid('script_quarantine_apply_failed')
    verify_quarantine(fd, record)


def publish(value, home, expected=None, approvals=(), *, source_files=None, validate_sources=None):
    if source_files is not None and validate_sources is None:
        raise base.Invalid('source_prerequisite')
    if validate_sources is not None:
        validate_sources()
    initial = evidence(value, home)
    if expected is not None and expected != initial:
        raise base.Invalid('target_changed')
    prepared = plan(value, home, source_files=source_files)
    if prepared['reason'] and not (value['version'] == 5 and prepared['writes']):
        raise base.Invalid(prepared['reason'])
    required = {row['id'] for row in restore_scripts(value, home, source_files=source_files)}
    if set(approvals) != required:
        raise base.Invalid('script_consent_required')
    if not prepared['writes']:
        return False
    wanted, changed = initial, False
    try:
        def validate(ignore_pending=()):
            if validate_sources is not None:
                validate_sources(ignore_pending)
            if evidence(value, home, ignore_pending) != wanted:
                raise base.Invalid('target_changed')
        for path in prepared['directories']:
            validate()
            before = observation(value, home)
            with sources.parent(home, path) as (fd, name, check):
                validate(); check()
                os.mkdir(name, 0o700, dir_fd=fd)
                changed = True
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                try:
                    info = os.fstat(child)
                    if stat.S_IMODE(info.st_mode) != 0o700 or info.st_uid != os.getuid() or info.st_flags:
                        raise base.Invalid('publication_uncertain')
                    base.acl_safe(child)
                    check(); os.fsync(fd)
                    if base.stamp(info)[:6] != base.stamp(os.stat(name, dir_fd=fd, follow_symlinks=False))[:6]:
                        raise base.Invalid('publication_uncertain')
                finally:
                    os.close(child)
            after = observation(value, home)
            if (before.get('documents') != after.get('documents') or before['tools'] != after['tools'] or before['dependencies'] != after['dependencies'] or any(val is not None and after['directories'][key] != val for key, val in before['directories'].items())
                    or any((after['files'][key] not in (('missing_parent', None), (None, None)) if val[0] == 'missing_parent'
                            else after['files'][key] != val) for key, val in before['files'].items())):
                raise base.Invalid('publication_uncertain')
            wanted = evidence(value, home)
        # Publish dependencies/leaves first; activate source relationships last.
        depth = {item['path']: max(len(row['chain']) - row['chain'].index(item['path']) for row in value['aliases'] if item['path'] in row['chain']) for item in value['layout']}
        for path in sorted(prepared['writes'], key=lambda p: (depth.get(p, 0), p)):
            validate()
            before = observation(value, home)
            candidate, mode = prepared['writes'][path]
            script = next((row for row in value['scripts'] if row['path'] == path), None) if value['version'] == 5 else None
            metadata = ({'prepare': lambda fd: apply_quarantine(fd, script.get('quarantine')),
                         'verify': lambda fd: verify_quarantine(fd, script.get('quarantine'))} if script is not None else {})
            sources.publish_content(home, path, candidate, validate, mode,
                limit=MAX_FILE_BYTES if script is not None else base.MAX_BYTES,
                tracked=value['version'] == 5 and path in depth, create_only=script is not None, **metadata)
            changed = True
            after = observation(value, home)
            if (before.get('documents') != after.get('documents') or before['tools'] != after['tools'] or any(after['dependencies'].get(key) != val for key, val in before['dependencies'].items() if key != path) or before['directories'] != after['directories'] or any(after['files'].get(key) != val for key, val in before['files'].items() if key != path)):
                raise base.Invalid('publication_uncertain')
            wanted = evidence(value, home)
        # A v5 plan can leave an unsafe alias/source group untouched while
        # publishing independent files. Verify every qualified row; blocked
        # requirements remain visible to ordinary Verification and Check.
        required_rows = {row['name'] for row, state, policy in prepared['rows']
                         if state == 'matching' or policy in ('create', 'add')}
        verified = {row['name'] for row, state, _ in plan(value, home, source_files=source_files)['rows'] if state == 'matching'}
        if not required_rows <= verified:
            raise base.Invalid('verification_failed')
    except BaseException as exc:
        if changed or isinstance(exc, base.PublicationUncertain):
            raise base.PublicationUncertain('publication_uncertain') from exc
        raise
    return changed
