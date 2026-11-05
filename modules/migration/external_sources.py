"""Operation-scoped, explicit SSH source pairs. No scanning or destination mapping."""
import hashlib
import json
import os
from pathlib import Path
import re
import stat

MAX_ITEMS = 32
MAX_KEY = 1024 * 1024
MAX_PATH = 1024
MAX_CONTROL = 64 * 1024
CONTROL_NAME = 'external-ssh-sources.json'
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\Z', re.ASCII)
RESERVED = {'config', 'known_hosts', 'known_hosts2', 'authorized_keys', 'authorized_keys2', 'environment', 'rc'}


class ExternalSourceError(Exception):
    def __init__(self, code='external_identity_unsafe'):
        self.code = code
        super().__init__(code)


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def paths(value):
    if (not isinstance(value, list) or not 1 <= len(value) <= MAX_ITEMS
            or any(not isinstance(p, str) or not p.startswith('/') or len(p.encode('utf-8')) > MAX_PATH
                   or any(ord(c) < 32 or ord(c) == 127 for c in p) for p in value)
            or len(value) != len(set(value))):
        raise ExternalSourceError('external_identity_invalid_request')
    return value


def read_control(path):
    """Only a bounded regular private reference file in an owned private directory."""
    def unique_fields(pairs):
        value = {}
        for key, item in pairs:
            if key in value:
                raise ValueError('duplicate field')
            value[key] = item
        return value
    descriptors = []
    try:
        parent = str(Path(path).parent)
        if os.path.realpath(parent) != parent:
            raise ExternalSourceError()
        directory = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        descriptors.append(directory)
        info = os.fstat(directory)
        if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
            raise ExternalSourceError()
        fd = os.open(Path(path).name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        descriptors.append(fd)
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1
                or stat.S_IMODE(before.st_mode) != 0o600 or before.st_size > MAX_CONTROL):
            raise ExternalSourceError()
        with os.fdopen(os.dup(fd), 'rb') as stream:
            raw = stream.read(MAX_CONTROL + 1)
        if (len(raw) > MAX_CONTROL or stamp(before) != stamp(os.fstat(fd))
                or stamp(before) != stamp(os.stat(Path(path).name, dir_fd=directory, follow_symlinks=False))
                or (info.st_dev, info.st_ino) != (os.lstat(parent).st_dev, os.lstat(parent).st_ino)):
            raise ExternalSourceError()
        return json.loads(raw, object_pairs_hook=unique_fields)
    except (OSError, ValueError, UnicodeError):
        raise ExternalSourceError('external_identity_invalid_request') from None
    finally:
        for fd in reversed(descriptors):
            os.close(fd)


def operation_paths(operation_id):
    # Normalize only Core's existing temporary-directory alias, never a selected source.
    directory = Path(os.environ.get('TMPDIR', '')).resolve()
    value = read_control(directory / CONTROL_NAME)
    if (not isinstance(value, dict) or set(value) != {'version', 'operation_id', 'paths'}
            or type(value['version']) is not int or value['version'] != 1 or value['operation_id'] != operation_id):
        raise ExternalSourceError('external_identity_invalid_request')
    return paths(value['paths'])


def read_pair(source):
    paths([source])
    path = Path(source)
    if (str(path) != source or '..' in path.parts or not NAME.fullmatch(path.name)
            or path.name.lower().endswith('.pub') or path.name.casefold() in RESERVED):
        raise ExternalSourceError('external_identity_name_invalid')
    opened, directories, files = [], [], []
    try:
        parent = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        opened.append(parent)
        visible = Path('/')
        for component in path.parts[1:-1]:
            parent = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent)
            opened.append(parent)
            info = os.fstat(parent)
            # Root-owned sticky shared ancestors (e.g. /private/tmp) protect owned
            # child directories. All other ancestors prohibit group/other writes.
            shared = info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o1777
            if info.st_uid not in (0, os.getuid()) or (info.st_mode & 0o022 and not shared):
                raise ExternalSourceError()
            visible /= component
            directories.append((visible, (info.st_dev, info.st_ino, info.st_mode, info.st_uid)))
        info = os.fstat(parent)
        if info.st_uid != os.getuid() or info.st_mode & 0o022:
            raise ExternalSourceError()
        for suffix, modes in (('', (0o600,)), ('.pub', (0o600, 0o644))):
            try:
                fd = os.open(path.name + suffix, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=parent)
            except FileNotFoundError:
                raise ExternalSourceError('external_identity_pair_missing') from None
            opened.append(fd)
            info = os.fstat(fd)
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1
                    or stat.S_IMODE(info.st_mode) not in modes or not 1 <= info.st_size <= MAX_KEY):
                raise ExternalSourceError()
            with os.fdopen(os.dup(fd), 'rb') as stream:
                raw = stream.read(MAX_KEY + 1)
            if len(raw) > MAX_KEY:
                raise ExternalSourceError()
            files.append((fd, path.name + suffix, info, raw))
        for fd, name, before, _ in files:
            if stamp(before) != stamp(os.fstat(fd)) or stamp(before) != stamp(os.stat(name, dir_fd=parent, follow_symlinks=False)):
                raise ExternalSourceError('external_identity_changed')
        for visible, expected in directories:
            now = os.lstat(visible)
            if (now.st_dev, now.st_ino, now.st_mode, now.st_uid) != expected or not stat.S_ISDIR(now.st_mode):
                raise ExternalSourceError('external_identity_changed')
        state = [stamp(info) + (hashlib.sha256(raw).hexdigest(),) for _, _, info, raw in files]
        state += [value for _, value in directories]
        binding = hashlib.sha256(json.dumps(state).encode()).hexdigest()
        return path.name, files[0][3], files[1][3], binding
    except OSError:
        raise ExternalSourceError() from None
    finally:
        for fd in reversed(opened):
            os.close(fd)
