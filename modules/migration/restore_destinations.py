"""Session-private Restore destinations; Secure Migration v1 stays unchanged."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import re
import stat
import sys

from external_sources import ExternalSourceError, read_control
from secret_input import SecureError

CONTROL = 'secure-restore-destinations.json'
INVENTORY = 'secure-restore-inventory.json'
HEX = re.compile(r'[0-9a-f]{64}\Z', re.ASCII)


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def identity_id(record):
    name, kind, fingerprint, private, public = record
    return digest([name, kind, fingerprint, hashlib.sha256(private).hexdigest(), hashlib.sha256(public).hexdigest()])


def validate(value):
    if (not isinstance(value, dict) or set(value) != {'version', 'bundle_id', 'items'}
            or type(value['version']) is not int or value['version'] not in (1, 2)
            or not isinstance(value['bundle_id'], str) or not HEX.fullmatch(value['bundle_id'])
            or not isinstance(value['items'], list) or not 1 <= len(value['items']) <= 32):
        raise SecureError('secure_input_invalid')
    ids = []
    for row in value['items']:
        fields = {'identity_id', 'directory'} | ({'selected'} if value['version'] == 2 else set())
        if (not isinstance(row, dict) or set(row) != fields
                or (value['version'] == 2 and type(row['selected']) is not bool)
                or not isinstance(row['identity_id'], str) or not HEX.fullmatch(row['identity_id'])):
            raise SecureError('secure_input_invalid')
        path = row['directory']
        if path is not None and (not isinstance(path, str) or not path.startswith('/')
                or len(path.encode('utf-8')) > 1024 or str(Path(path)) != path
                or '..' in Path(path).parts or any(ord(c) < 32 or ord(c) == 127 for c in path)):
            raise SecureError('secure_input_invalid')
        ids.append(row['identity_id'])
    if ids != sorted(set(ids)):
        raise SecureError('secure_input_invalid')
    return value


def selected_items(mapping):
    # v1 always describes the whole authenticated package. v2 never falls back.
    return [row for row in mapping['items'] if mapping['version'] == 1 or row['selected']]


def operation_mapping(operation_id):
    try:
        value = read_control(Path(os.environ['TMPDIR']).resolve() / CONTROL)
        if not isinstance(value, dict) or set(value) != {'operation_id', 'mapping'} or value['operation_id'] != operation_id:
            raise SecureError('secure_input_invalid')
        return validate(value['mapping'])
    except (ExternalSourceError, OSError, KeyError, ValueError):
        raise SecureError('secure_input_invalid') from None


def publish_inventory(operation_id, bundle_id, items, *, name=INVENTORY, context=None):
    directory = Path(os.environ['TMPDIR']).resolve()
    fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o700:
            raise SecureError('secure_input_invalid')
        value = dict(version=1, operation_id=operation_id, bundle_id=bundle_id, items=items)
        if context is not None:
            value['context'] = context
        raw = json.dumps(value, separators=(',', ':')).encode()
        if len(raw) > 65536:
            raise SecureError('secure_input_invalid')
        output = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(output, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(raw)
        current = os.lstat(directory)
        if Directory.stamp(before) != Directory.stamp(current):
            os.unlink(name, dir_fd=fd)
            raise SecureError('secure_target_changed')
    finally:
        os.close(fd)


def safe_acl(fd):
    # POSIX mode bits do not describe macOS extended ACL grants. Custom targets
    # reject extended grants; deny-only ACLs (e.g. home deletion protection) are safe.
    if sys.platform != 'darwin':
        return
    libc = ctypes.CDLL(None, use_errno=True)
    libc.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    libc.acl_get_fd_np.restype = ctypes.c_void_p
    libc.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    libc.acl_free.argtypes = [ctypes.c_void_p]
    libc.acl_get_tag_type.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_int)]
    acl = libc.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED
    if not acl and ctypes.get_errno() == 2:  # ENOENT: no extended ACL
        return
    if not acl:
        raise SecureError('secure_target_conflict')
    try:
        entry = ctypes.c_void_p()
        entry_id = 0  # ACL_FIRST_ENTRY; ACL_NEXT_ENTRY is -1 on Darwin.
        for _ in range(170):
            ctypes.set_errno(0)
            result = libc.acl_get_entry(acl, entry_id, ctypes.byref(entry))
            if result == -1 and ctypes.get_errno() == 22:
                return
            tag = ctypes.c_int()
            if result != 0 or libc.acl_get_tag_type(entry, ctypes.byref(tag)) != 0 or tag.value != 2:
                raise SecureError('secure_target_conflict')
            entry_id = -1
        raise SecureError('secure_target_conflict')
    finally:
        libc.acl_free(acl)


class Directory:
    """Pin every path component and check visibility again before publication."""
    def __init__(self, path):
        self.path = path
        self.opened = []
        self.visible = []
        try:
            if (not path.startswith('/') or str(Path(path)) != path or '..' in Path(path).parts
                    or os.path.realpath(path) != path):
                raise SecureError('secure_target_conflict')
            fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
            self.opened.append(fd)
            visible = Path('/')
            for component in Path(path).parts[1:]:
                fd = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                self.opened.append(fd)
                visible /= component
                info = os.fstat(fd)
                shared = info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o1777
                if info.st_uid not in (0, os.getuid()) or (info.st_mode & 0o022 and not shared):
                    raise SecureError('secure_target_conflict')
                safe_acl(fd)
                self.visible.append((visible, self.stamp(info)))
            info = os.fstat(fd)
            if (info.st_uid != os.getuid() or info.st_mode & 0o022 or info.st_mode & 0o700 != 0o700
                    or getattr(info, 'st_flags', 0) & 0x60006  # immutable/append-only
                    or os.fstatvfs(fd).f_flag & os.ST_RDONLY
                    or not os.access(path, os.R_OK | os.W_OK | os.X_OK)):
                raise SecureError('secure_target_conflict')
            self.fd = fd
            self.check()
        except OSError:
            self.close()
            raise SecureError('secure_target_conflict') from None
        except BaseException:
            self.close()
            raise

    @staticmethod
    def stamp(info):
        return [info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid, getattr(info, 'st_flags', 0)]

    def check(self):
        for (path, expected), fd in zip(self.visible, self.opened[1:]):
            try:
                unchanged = self.stamp(os.lstat(path)) == expected and self.stamp(os.fstat(fd)) == expected
            except OSError:
                unchanged = False
            if not unchanged:
                raise SecureError('secure_target_changed')
            safe_acl(fd)

    def close(self):
        for fd in reversed(self.opened):
            os.close(fd)
        self.opened = []

    def __enter__(self):
        return self

    def __exit__(self, *_):
        self.close()


def preparation(mapping, bundle_id):
    if mapping['bundle_id'] != bundle_id:
        raise SecureError('stale_plan')
    observations = []
    for path in sorted({row['directory'] for row in selected_items(mapping) if row['directory'] is not None}):
        with Directory(path) as directory:
            observations.append([path, [stamp for _, stamp in directory.visible]])
    return digest([mapping, observations])
