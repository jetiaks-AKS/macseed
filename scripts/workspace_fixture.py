"""Disposable native Git readers' fixtures; no Git mutation commands are used."""
import hashlib
from pathlib import Path
import struct
import zlib


def object_file(directory, kind, data):
    raw = kind.encode() + b' ' + str(len(data)).encode() + b'\0' + data
    oid = hashlib.sha1(raw).hexdigest()
    path = directory / 'objects' / oid[:2] / oid[2:]
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(zlib.compress(raw))
    return oid


def repository(home, relative='Projects/base', remote='https://example.invalid/team/repo.git'):
    path = Path(home) / relative
    git = path / '.git'
    (git / 'refs/heads').mkdir(parents=True)
    (git / 'config').write_text('[core]\nrepositoryformatversion = 0\nbare = false\n'
                              '[remote "origin"]\nurl = ' + remote + '\n')
    blob = object_file(git, 'blob', b'tracked\n')
    tree = object_file(git, 'tree', b'100644 tracked.txt\0' + bytes.fromhex(blob))
    oid = object_file(git, 'commit', (
        f'tree {tree}\nauthor Fixture <test@example.invalid> 1 +0000\n'
        'committer Fixture <test@example.invalid> 1 +0000\n\nfixture\n').encode())
    (git / 'refs/heads/main').write_text(oid + '\n')
    (git / 'HEAD').write_text('ref: refs/heads/main\n')
    (path / 'tracked.txt').write_bytes(b'tracked\n')
    write_index(git, blob, (path / 'tracked.txt').stat())
    return path, oid


def write_index(git, oid, stat_cache=None):
    name = b'tracked.txt'
    fields = [0, 0, 0, 0, 0, 0, 0o100644, 0, 0, 0]
    if stat_cache is not None:
        # Match a real clean index so legacy diff --quiet need not refresh its cache.
        fields = [*divmod(stat_cache.st_ctime_ns, 10**9), *divmod(stat_cache.st_mtime_ns, 10**9),
                  stat_cache.st_dev, stat_cache.st_ino, 0o100644,
                  stat_cache.st_uid, stat_cache.st_gid, stat_cache.st_size]
    entry = struct.pack('>10I20sH', *(value & 0xffffffff for value in fields), bytes.fromhex(oid), len(name))
    entry += name + b'\0'
    entry += b'\0' * (-len(entry) % 8)
    data = b'DIRC' + struct.pack('>II', 2, 1) + entry
    (git / 'index').write_bytes(data + hashlib.sha1(data).digest())


def linked(base, destination, oid, branch='feature', *, locked=False, missing=False):
    destination = Path(destination)
    name = hashlib.sha256(str(destination).encode()).hexdigest()[:12]
    git = base / '.git/worktrees' / name
    git.mkdir(parents=True)
    (git / 'gitdir').write_text(str(destination / '.git') + '\n')
    (git / 'commondir').write_text('../..\n')
    (git / 'HEAD').write_text('ref: refs/heads/' + branch + '\n' if branch else oid + '\n')
    if branch:
        ref = base / '.git/refs/heads' / branch
        ref.parent.mkdir(parents=True, exist_ok=True)
        ref.write_text(oid + '\n')
    if locked:
        (git / 'locked').write_text('private reason must not travel\n')
    if not missing:
        destination.mkdir(parents=True)
        (destination / '.git').write_text('gitdir: ' + str(git) + '\n')
        (destination / 'tracked.txt').write_bytes(b'tracked\n')
        (git / 'index').write_bytes((base / '.git/index').read_bytes())
    return destination
