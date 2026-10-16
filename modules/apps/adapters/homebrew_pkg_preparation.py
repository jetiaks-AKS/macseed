"""Bounded, short-lived PKG requirements, never archives or standing consent."""
import hashlib
from itertools import islice
import json
import os
from pathlib import Path
import re
import stat
import time

CONTEXT = 'MACSEED_PKG_PREPARATION_CONTEXT'
TTL = 1800
LIMIT = 64
IDENTITY = re.compile(r'[0-9a-f]{64}\Z')


def context(bundle, stage):
    return hashlib.sha256((bundle + ':' + stage).encode()).hexdigest()


def identity(row):
    scope = os.environ.get(CONTEXT, '')
    if not IDENTITY.fullmatch(scope):
        return None
    return hashlib.sha256(json.dumps({'context': scope, 'metadata': {k: v for k, v in row.items()
                                                 if k not in ('installed', 'installed_time', 'outdated')}},
                                    sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def directory():
    from homebrew_lifecycle import state_directory
    return state_directory() / 'pkg-preparations'


def checked_directory(root):
    home = Path.home().resolve()
    for part in (root, *root.parents):
        if part == home:
            break
        info = part.lstat()
        if not stat.S_ISDIR(info.st_mode) or stat.S_ISLNK(info.st_mode):
            raise ValueError('unsafe preparation directory')
        if part == root and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise ValueError('unsafe preparation directory')


def load(key):
    if not key or not IDENTITY.fullmatch(key):
        return None
    try:
        root = directory()
        checked_directory(root)
        fd = os.open(root / (key + '.json'), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(fd) as stream:
            info = os.fstat(stream.fileno())
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_nlink != 1 or info.st_size > 65536):
                return None
            value = json.load(stream)
        if (set(value) != {'contract', 'identity', 'created', 'required'} or value['contract'] != 1
                or value['identity'] != key or type(value['created']) not in (float, int)
                or not 0 <= time.time() - value['created'] < TTL):
            return None
        return value['required']
    except (OSError, ValueError, TypeError):
        return None


def save(key, required):
    from homebrew_lifecycle import private_directory
    if not IDENTITY.fullmatch(key):
        raise ValueError('invalid preparation identity')
    root = directory()
    private_directory(root.parent)
    private_directory(root)
    checked_directory(root)
    # Bounded cleanup only in this owned directory, during explicit preparation.
    entries = list(islice(root.iterdir(), LIMIT + 1))
    if len(entries) > LIMIT:
        raise ValueError('preparation storage limit')
    for entry in entries:
        if (entry.suffix == '.json' and IDENTITY.fullmatch(entry.stem)) or entry.name.startswith('preparing-'):
            info = entry.lstat()
            if (stat.S_ISREG(info.st_mode) and time.time() - info.st_mtime >= TTL):
                entry.unlink()
    if len(list(root.iterdir())) >= LIMIT and not (root / (key + '.json')).exists():
        raise ValueError('preparation storage limit')
    # Exclusive private temporary creation; interruption leaves no usable record.
    import tempfile
    fd, name = tempfile.mkstemp(prefix='preparing-', dir=root)
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump({'contract': 1, 'identity': key, 'created': time.time(), 'required': required}, stream)
        os.replace(name, root / (key + '.json'))
    finally:
        Path(name).unlink(missing_ok=True)
