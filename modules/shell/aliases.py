"""Bounded static Zsh declarations, never a shell evaluator or dotfile merger.

New Capture prefers qualified declarations over whole-file snapshots. It proves
saved declarations, not the effective state of a running interactive shell.
"""
from contextlib import contextmanager
import ctypes
import errno
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import uuid

MAGIC = b'MBT-ZSH-ALIASES-1\n'
SOURCE_MAGIC = b'MBT-ZSH-ALIASES-2\n'
RECOVERY_MAGIC = b'MBT-ZSH-ALIASES-3\n'
OPAQUE_MAGIC = b'MBT-ZSH-ALIASES-4\n'
FILE_MAGIC = b'MBT-ZSH-ALIASES-5\n'
_recovery = None
_sources = None


def source_contract():
    global _sources
    if _sources is None:
        spec = importlib.util.spec_from_file_location('shell_sources', Path(__file__).with_name('sources.py'))
        _sources = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_sources)
    return _sources

def recovery_contract():
    global _recovery
    if _recovery is None:
        spec = importlib.util.spec_from_file_location('shell_recovery', Path(__file__).with_name('recovery.py'))
        _recovery = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(_recovery)
    return _recovery


def evidence(value, home):
    return (recovery_contract() if value['version'] in (3, 4, 5) else source_contract()).evidence(value, home)


MAX_BYTES = 65536
MAX_ITEMS = 256
# Darwin UF_TRACKED records document identity, not write/access restrictions.
# Permit it only when observing existing user files, never private snapshots.
USER_READ_FLAGS = 0x00000040
NAME = r'[A-Za-z_][A-Za-z0-9_-]{0,63}'
SOURCE_NAME = r'[A-Za-z_][A-Za-z0-9_.-]{0,63}'
RESERVED = {'alias', 'unalias', 'builtin', 'command', 'eval', 'source', 'function',
            'if', 'then', 'else', 'elif', 'fi', 'for', 'while', 'until', 'do', 'done',
            'case', 'esac', 'select', 'repeat', 'return', 'exit', 'exec', 'emulate',
            'setopt', 'unsetopt', 'enable', 'disable', 'autoload', 'typeset', 'export'}
SENSITIVE = re.compile(r'(?:token|password|passwd|secret|api[_-]?key|access[_-]?key|'
                       r'private[_-]?key|credential|authorization|bearer)|'
                       r'[a-z][a-z0-9+.-]*://[^\s/]*@|(?:^|\s)(?:--user|-u|-p)(?:\s|=)|'
                       r'-----BEGIN|\b(?:AKIA|ASIA)[A-Z0-9]{16}\b', re.I)


class Invalid(ValueError):
    pass


class PublicationUncertain(Invalid):
    pass


def failure_diagnostic(exc):
    """Closed, content-free diagnostics over the existing helper result path."""
    phase, reason, seen = 'preflight', 'observation_failed', set()
    while exc is not None and id(exc) not in seen:
        seen.add(id(exc))
        if getattr(exc, 'phase', None) in ('staging', 'exchange', 'verification'):
            phase = exc.phase
        if isinstance(exc, ValueError) and str(exc) in {
                'target_changed', 'target_conflict', 'publication_uncertain',
                'metadata_copy_failed', 'metadata_copy_mismatch', 'unsupported_metadata',
                'document_identity_unavailable', 'verification_failed', 'script_consent_required'}:
            reason = str(exc)
        exc = exc.__cause__
    return 'shell_' + phase + '_' + reason


def identity(name):
    return 'shell-alias:' + hashlib.sha256(name.encode()).hexdigest()


def statements(text):
    """Lex complete outer statements; opaque/unterminated syntax fails closed.

    Quotes, escapes, balanced substitutions/groups and comments are structural
    only. Here-documents and case/alternate grammar are outside this first slice.
    No statement following an unbounded context is extracted.
    """
    def quoted(index, end, depth):
        if depth > 32:
            raise Invalid('ambiguous_context')
        while index < len(text):
            char = text[index]
            if char == end:
                return index + 1
            if end != "'" and char == '\\':
                index += 2
            elif end == '"' and text.startswith('$(', index):
                index = balanced(index + 2, ')', depth + 1)
            elif end == '"' and text.startswith('${', index):
                index = balanced(index + 2, '}', depth + 1)
            elif end == '"' and char == '`':
                index = quoted(index + 1, '`', depth + 1)
            else:
                index += 1
        raise Invalid('ambiguous_context')

    def balanced(index, end, depth):
        if depth > 32:
            raise Invalid('ambiguous_context')
        while index < len(text):
            char = text[index]
            if char == end:
                return index + 1
            if text.startswith('<<', index):
                raise Invalid('ambiguous_context')
            if char == '\\':
                index += 2
            elif char in "'\"`":
                index = quoted(index + 1, char, depth + 1)
            elif char in '({':
                index = balanced(index + 1, ')' if char == '(' else '}', depth + 1)
            elif char == '#' and (index == 0 or text[index - 1].isspace()):
                newline = text.find('\n', index)
                index = len(text) if newline < 0 else newline + 1
            else:
                index += 1
        raise Invalid('ambiguous_context')

    rows, start, index = [], 0, 0
    while index < len(text):
        char = text[index]
        if text.startswith('<<', index) or char in ')}':
            raise Invalid('ambiguous_context')
        if char == '\\':
            index += 2
        elif char in "'\"`":
            index = quoted(index + 1, char, 0)
        elif char in '({':
            index = balanced(index + 1, ')' if char == '(' else '}', 0)
        elif text.startswith('[[', index):
            # A multiline test contains words, never alias declarations.
            index += 2
            while index < len(text) and not text.startswith(']]', index):
                if text[index] in "'\"`":
                    index = quoted(index + 1, text[index], 0)
                elif text[index] == '\\':
                    index += 2
                elif text.startswith('$(', index):
                    index = balanced(index + 2, ')', 0)
                else:
                    index += 1
            if index >= len(text):
                raise Invalid('ambiguous_context')
            index += 2
        elif char == '#' and (index == start or text[index - 1].isspace()):
            continuation = text[start:index].replace('\\\n', '').rstrip().endswith(('&&', '||', '|', '|&'))
            if not continuation:
                rows.append(text[start:index].strip())
            newline = text.find('\n', index)
            index = len(text) if newline < 0 else newline + 1
            if not continuation:
                start = index
        elif char in '\n;':
            if char == '\n' and text[start:index].rstrip().endswith(('&&', '||', '|', '|&')):
                index += 1
                continue
            rows.append(text[start:index].strip())
            index += 1
            start = index
        else:
            index += 1
    rows.append(text[start:].strip())
    return [row for row in rows if row]


def home_reference(word):
    """A bounded portable reference, without expansion or filesystem access."""
    match = re.fullmatch(r'(?:\$HOME/|\$\{HOME\}/|~/)([A-Za-z0-9_./ -]{1,512})', word)
    if match and all(re.fullmatch(r'[A-Za-z0-9_. -]{1,128}', part) and part == part.strip() and part not in ('.', '..', '.git')
                     for part in match[1].split('/')) and not SENSITIVE.search(match[1]):
        return match[1]
    return None


def declaration(statement, extended=False):
    """One ordinary alias with a literal quoted command; no option/global forms."""
    if extended:
        original = declaration(statement)
        if original is not None:
            return original  # Existing capability-2 declarations retain their meaning.
    flat = statement.replace('\\\n', '')
    match = re.fullmatch(r'alias[ \t]+(' + (SOURCE_NAME if extended else NAME) + r')=(\'[^\'\n]*\'|"[^"\n]*")', flat)
    if not match:
        return None
    name, word = match.groups()
    value = word[1:-1]
    inert = value.replace('${HOME}/', '$HOME/').replace('$HOME/', '') if extended else value
    if (name in RESERVED or not 1 <= len(value) <= 2048 or value != value.strip()
            or any(char in inert for char in '$`\\;|&<>(){}!\r\n')
            or (extended and word.startswith('"') and '$' in value)
            or (word.startswith("'") and '\n' in statement[statement.index("'", statement.index('=')):])
            or SENSITIVE.search(name + ' ' + value)
            or re.search(r'/Users/|/opt/homebrew(?:/|\b)|/usr/local(?:/|\b)', value)):
        return None
    try:
        words = shlex.split(value, posix=True)
    except ValueError:
        return None
    if extended:
        # Quoting stays in the saved statement. Reject literal quoted tildes and
        # all parameter forms except an entire HOME-relative word. No eval/source.
        tokens = shlex.split(value, posix=False)
        if any(('$' in token and home_reference(token.strip('"')) is None)
               or (token[:1] in "'\"" and token[1:].startswith('~')) for token in tokens):
            return None
        if any((token != '~' and token.startswith(('~', '$')) and home_reference(token) is None)
               or (token.startswith('/') and not re.fullmatch(r'/(?:usr/bin|bin)/[A-Za-z0-9_.+-]+', token))
               for token in words):
            return None
        if words and words[0] in ('source', '.'):
            if len(words) == 2 and home_reference(words[1]) is not None:
                return {'name': name, 'statement': statement}, value, words[0]
            return None
    if (not words or words[0] in RESERVED or not (re.fullmatch(r'(?:/usr/bin/|/bin/)?[A-Za-z0-9_.+-]+', words[0])
            or (extended and home_reference(words[0]) is not None))
            or any(word.startswith('/') and not word.startswith(('/usr/bin/', '/bin/')) for word in words)
            or any(word.startswith('~') and word != '~' and not word.startswith('~/') for word in words)):
        return None
    return {'name': name, 'statement': statement}, value, words[0]


def classify(raw, extended=False):
    if len(raw) > MAX_BYTES or b'\0' in raw:
        raise Invalid('unsupported_source')
    try:
        text = raw.decode('utf-8')
    except UnicodeError as exc:
        raise Invalid('unsupported_source') from exc
    if any(ord(c) < 32 and c not in '\n\t' for c in text):
        raise Invalid('unsupported_source')
    commands = statements(text)
    name_pattern = SOURCE_NAME if extended else NAME
    candidates, rejected, blocks, partial = [], set(), [], False
    definitions = []
    for line in '\n'.join(commands).replace('\\\n', '').splitlines():
        alias = re.search(r'\balias\s+(.*)', line)
        if alias:
            definitions.extend(re.findall(r'(?:^|\s)([A-Za-z0-9_.-]+)\s*=', alias[1]))
    terminated = False
    for statement in commands:
        first = statement.split(None, 1)[0]
        if re.fullmatch(r'(?:function\s+)?' + name_pattern + r'\s*\(\s*\)', statement) or re.fullmatch(r'function\s+' + name_pattern, statement):
            raise Invalid('ambiguous_context')
        if first in ('case', 'esac', 'repeat', 'select'):
            raise Invalid('ambiguous_context')
        if first in ('if', 'for', 'while', 'until'):
            blocks.append('fi' if first == 'if' else 'done')
        elif first in ('fi', 'done'):
            if not blocks or blocks.pop() != first:
                raise Invalid('ambiguous_context')
            partial = True
            continue
        parsed = declaration(statement, extended) if not blocks and not terminated else None
        if not blocks and first in ('return', 'exit', 'exec'):
            terminated = True
        if parsed:
            candidates.append(parsed)
        else:
            partial = True
        if re.match(r'(?:alias\s+(?:-\w+\s+)?alias\s*=|function\s+alias\b|alias\s*\()', statement):
            raise Invalid('ambiguous_alias_command')
        if re.match(r'(?:builtin\s+)?unalias\s', statement):
            try:
                removed = shlex.split(statement)[1:]
            except ValueError as exc:
                raise Invalid('ambiguous_alias_command') from exc
            if any(not re.fullmatch(name_pattern, name) for name in removed):
                raise Invalid('ambiguous_alias_command')
            rejected.update(removed)
        if re.match(r'alias\s', statement) and parsed is None and not re.match(r'alias\s+[A-Za-z0-9_.-]+=', statement):
            raise Invalid('ambiguous_alias_command')
    if blocks:
        raise Invalid('ambiguous_context')
    names = set(definitions)
    boundary = r'(?![A-Za-z0-9_.-])' if extended else r'\b'
    functions = {name for pair in re.findall(r'(?:^|[;\n])\s*(?:function\s+)?(' + name_pattern
                 + r')\s*\(\s*\)|(?:^|[;\n])\s*function\s+(' + name_pattern + ')' + boundary, text) for name in pair if name}
    rows = [row for row, _, command in candidates if definitions.count(row['name']) == 1
            and row['name'] not in rejected and command not in (names | functions)]
    if len(rows) > MAX_ITEMS:
        raise Invalid('unsupported_source')
    return rows, partial or len(rows) != len(candidates)


def encode(rows, partial=True):
    return MAGIC + (json.dumps({'version': 1, 'coverage': 'partial' if partial else 'complete',
                              'aliases': rows}, ensure_ascii=True, separators=(',', ':')) + '\n').encode()


def snapshot(raw, payloads=None):
    if raw.startswith((RECOVERY_MAGIC, OPAQUE_MAGIC, FILE_MAGIC)):
        return recovery_contract().snapshot(raw, payloads)
    if raw.startswith(SOURCE_MAGIC):
        return source_contract().snapshot(raw)
    if not raw.startswith(MAGIC) or len(raw) > MAX_BYTES:
        raise Invalid('invalid_snapshot')
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise Invalid('invalid_snapshot')
            result[key] = value
        return result
    try:
        value = json.loads(raw[len(MAGIC):], object_pairs_hook=unique)
    except (ValueError, UnicodeError) as exc:
        raise Invalid('invalid_snapshot') from exc
    if (not isinstance(value, dict) or set(value) != {'version', 'coverage', 'aliases'}
            or type(value['version']) is not int or value['version'] != 1
            or value['coverage'] not in ('complete', 'partial') or not isinstance(value['aliases'], list)
            or not 1 <= len(value['aliases']) <= MAX_ITEMS):
        raise Invalid('invalid_snapshot')
    names = []
    for row in value['aliases']:
        if (not isinstance(row, dict) or set(row) != {'name', 'statement'}
                or not all(isinstance(v, str) for v in row.values())):
            raise Invalid('invalid_snapshot')
        parsed = declaration(row['statement'])
        if parsed is None or parsed[0] != row or statements(row['statement']) != [row['statement']]:
            raise Invalid('invalid_snapshot')
        names.append(row['name'])
    if len(set(names)) != len(names) or any(declaration(row['statement'])[2] in names for row in value['aliases']):
        raise Invalid('invalid_snapshot')
    return value


def select_snapshot(raw, names, payloads=None):
    value = snapshot(raw, payloads)
    allowed = {row['name'] for row in value['aliases']}
    if value['version'] in (4, 5):
        allowed.update(recovery_contract().file_identity(row['path']) for row in value['scripts'])
    if not names or not set(names) <= allowed:
        raise Invalid('invalid_selection')
    selected = [row for row in value['aliases'] if row['name'] in names]
    if value['version'] in (3, 4, 5):
        return recovery_contract().encode(recovery_contract().select(value, names))
    if value['version'] == 2:
        return source_contract().encode(dict(value, aliases=selected))
    return encode(selected, value['coverage'] == 'partial')


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid,
            getattr(info, 'st_flags', 0), info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def acl_safe(fd):
    if sys.platform != 'darwin':
        raise Invalid('unsupported_filesystem')
    lib = ctypes.CDLL(None, use_errno=True)
    lib.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    lib.acl_get_fd_np.restype = ctypes.c_void_p
    lib.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    lib.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    lib.acl_free.argtypes = [ctypes.c_void_p]
    acl = lib.acl_get_fd_np(fd, 0x100)
    if not acl:
        if ctypes.get_errno() == errno.ENOENT:
            return
        raise Invalid('observation_failed')
    try:
        entry, tag = ctypes.c_void_p(), ctypes.c_int()
        for index in range(129):
            if lib.acl_get_entry(acl, index, ctypes.byref(entry)) != 0:
                if ctypes.get_errno() == errno.EINVAL:
                    return
                break
            if lib.acl_get_tag_type(entry, ctypes.byref(tag)) != 0 or tag.value != 2:
                raise Invalid('unsafe_permissions')
        raise Invalid('unsafe_permissions')
    finally:
        lib.acl_free(acl)


@contextmanager
def home_directory(home):
    path = Path(home)
    if not path.is_absolute() or '..' in path.parts or str(path) != home:
        raise Invalid('unsafe_home')
    # macOS exposes these root-owned aliases for its private temporary tree.
    # Resolve only that fixed prefix, never arbitrary user-controlled links.
    for prefix in ('/var/', '/tmp/'):
        if home.startswith(prefix):
            root = Path(prefix[:-1])
            expected = Path('/private' + prefix[:-1])
            if root.lstat().st_uid == 0 and root.resolve() == expected:
                path = expected / home[len(prefix):]
    fds, links = [], []
    try:
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        fds.append(fd)
        for part in path.parts[1:]:
            before = os.fstat(fd)
            if before.st_uid not in (0, os.getuid()) or (before.st_mode & 0o022 and not (before.st_uid == 0 and before.st_mode & stat.S_ISVTX)):
                raise Invalid('unsafe_home')
            acl_safe(fd)
            child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            fds.append(child)
            links.append((fd, part, child, stamp(os.fstat(child))[:6]))
            fd = child
        info = os.fstat(fd)
        if info.st_uid != os.getuid() or info.st_mode & 0o022 or getattr(info, 'st_flags', 0):
            raise Invalid('unsafe_home')
        def recheck():
            for parent, part, child, expected in links:
                if stamp(os.fstat(child))[:6] != expected or stamp(os.stat(part, dir_fd=parent, follow_symlinks=False))[:6] != expected:
                    raise Invalid('target_changed')
                acl_safe(child)
        recheck()
        yield fd, recheck
    finally:
        for fd in reversed(fds):
            os.close(fd)


def read_file(name, directory=None, private=False, *, limit=MAX_BYTES):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    try:
        before = os.fstat(fd)
        allowed_flags = 0 if private else USER_READ_FLAGS
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1
                or before.st_size > limit or before.st_mode & 0o022
                or getattr(before, 'st_flags', 0) & ~allowed_flags
                or (private and stat.S_IMODE(before.st_mode) != 0o600)):
            raise Invalid('unsafe_file')
        acl_safe(fd)
        with os.fdopen(os.dup(fd), 'rb') as stream:
            raw = stream.read(limit + 1)
        if len(raw) != before.st_size or stamp(before) != stamp(os.fstat(fd)) or stamp(before) != stamp(os.stat(name, dir_fd=directory, follow_symlinks=False)):
            raise Invalid('target_changed')
        return raw
    finally:
        os.close(fd)


def startup(directory, home):
    if os.environ.get('ZDOTDIR') not in (None, '', home):
        raise Invalid('unsupported_startup')
    for name in ('.zshenv', '.zprofile', '.zlogin'):
        try:
            raw = read_file(name, directory)
        except FileNotFoundError:
            continue
        if re.search(rb'\b(?:ZDOTDIR|RCS|GLOBAL_RCS)\b', raw):
            raise Invalid('unsupported_startup')
    for name in ('.zshenv.zwc', '.zprofile.zwc', '.zshrc.zwc', '.zlogin.zwc'):
        try:
            os.stat(name, dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            continue
        raise Invalid('unsupported_startup')


def assess(value, home):
    if value['version'] in (3, 4, 5):
        return recovery_contract().assess(value, home)
    if value['version'] == 2:
        return source_contract().assess(value, home)
    try:
        with home_directory(home) as (directory, recheck):
            startup(directory, home)
            try:
                actual = read_file('.zshrc', directory)
            except FileNotFoundError:
                recheck()
                return [(row, 'missing', 'create') for row in value['aliases']]
            rows, _ = classify(actual)
            current = {row['name']: declaration(row['statement'])[1] for row in rows}
            # A syntactically present but rejected definition is uncertain, not absent.
            mentions = set(re.findall(rb'\balias\s+(?:--\s+)?([A-Za-z_][A-Za-z0-9_-]*)\s*=', actual))
            recheck()
            return [(row, 'matching' if current.get(row['name']) == declaration(row['statement'])[1]
                     else 'differing' if row['name'] in current else 'unverified' if row['name'].encode() in mentions
                     else 'missing', 'preserve') for row in value['aliases']]
    except (OSError, Invalid):
        return [(row, 'unverified', 'preserve') for row in value['aliases']]


def publish(value, home):
    if value['version'] in (2, 3, 4, 5):
        contract = recovery_contract() if value['version'] in (3, 4, 5) else source_contract()
        try:
            expected = os.environ.get('MACSEED_SHELL_EXPECTED_EVIDENCE')
            if os.environ.get('MACSEED_APPLICATION_EXECUTION') == 'true' and not expected:
                raise Invalid('missing_observation')
            return contract.publish(value, home, expected, **({'approvals': json.loads(os.environ.get('MACSEED_SHELL_SCRIPT_APPROVALS', '[]'))} if value['version'] in (3, 4, 5) else {}))
        except contract.base.PublicationUncertain as exc:
            raise PublicationUncertain('publication_uncertain') from exc
        except ValueError as exc:
            raise Invalid('target_conflict') from exc
    if all(state == 'matching' for _, state, _ in assess(value, home)):
        return False
    payload = ('\n'.join(row['statement'] for row in value['aliases']) + '\n').encode()
    with home_directory(home) as (directory, recheck):
        startup(directory, home)
        try:
            os.stat('.zshrc', dir_fd=directory, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            raise Invalid('target_conflict')
        temporary = '.macseed-zsh-' + uuid.uuid4().hex
        fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
        published = False
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(payload)
                stream.flush()
                os.fsync(stream.fileno())
            recheck()
            startup(directory, home)
            # Atomic no-clobber creation. An intervening target is never replaced.
            os.link(temporary, '.zshrc', src_dir_fd=directory, dst_dir_fd=directory, follow_symlinks=False)
            published = True
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except OSError as exc:
                if published:
                    raise PublicationUncertain('publication_uncertain') from exc
                raise
        try:
            recheck()
            if read_file('.zshrc', directory) != payload:
                raise Invalid('verification_failed')
        except (OSError, Invalid) as exc:
            raise PublicationUncertain('publication_uncertain') from exc
    return True


def main():
    command, path, *args = sys.argv[1:]
    if command == 'capture':
        try:
            value = recovery_contract().capture(path)
        except ValueError:
            return 1
        data = recovery_contract().encode(value)
        snapshot(data)
        fd = os.open(args[0], os.O_WRONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd, 'wb') as output:
            info = os.fstat(output.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
                raise Invalid('unsafe_staging')
            os.ftruncate(output.fileno(), 0)
            output.write(data)
        return 0
    value = recovery_contract().load(path)
    if command == 'predicate':
        print('alias_recovery' if value['version'] in (3, 4, 5) else 'alias_definition')
        return 0
    if command == 'validate':
        return 0
    if command in ('inspect', 'compare'):
        recovery = recovery_contract() if value['version'] in (3, 4, 5) else None
        plan = (recovery.comparison if command == 'compare' else recovery.plan)(value, os.environ['HOME']) if recovery else None
        reason = plan['reason'] if plan else None
        for row, state, policy in plan['rows'] if plan else assess(value, os.environ['HOME']):
            if not (command == 'inspect' and value['version'] == 5) and not (command == 'compare' and row.get('file')) and reason in ('managed_source_prerequisite', 'dependency_prerequisite', 'tool_prerequisite', 'source_prerequisite', 'operand_prerequisite', 'startup_prerequisite'):
                policy = reason
                if not row.get('file') and state == 'unverified' and reason in ('dependency_prerequisite', 'tool_prerequisite', 'operand_prerequisite'):
                    policy = recovery.dependency_reason(recovery.select(value, {row['name']}), os.environ['HOME']) or 'selection_prerequisite'
            print(row['name'] if row.get('file') else identity(row['name']), state, policy, sep='\t')
        # Coverage describes selected alias/startup reconstruction. An independent
        # file-only selection promises bytes/mode, not the unselected source graph.
        # Its own unsafe/missing dependency evidence remains in the file row above.
        if value['coverage'] == 'partial' and value['aliases']:
            dependency = (value['version'] in (2, 3, 4, 5) and any(state[0] != 'ready' for state in
                          source_contract().dependency_states(value, os.environ['HOME']).values()))
            print('scope\tpartial\t' + ('dependency_unavailable' if dependency or (reason and reason.endswith('_prerequisite')) else 'preserve'))
        return 0
    if command == 'apply':
        try:
            print('changed' if publish(value, os.environ['HOME']) else 'matching')
            if value['version'] == 5 and recovery_contract().plan(value, os.environ['HOME'])['reason']:
                return 1  # Independent files published; selected aliases still need attention.
        except PublicationUncertain as exc:
            print('changed')
            print('diagnostic\t' + failure_diagnostic(exc))
            return 2
        except Invalid as exc:
            print('diagnostic\t' + failure_diagnostic(exc))
            return 1
        return 0
    return 2


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (OSError, ValueError):
        # Neither source text nor exception paths are public diagnostics.
        sys.exit(2)
