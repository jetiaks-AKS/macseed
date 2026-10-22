"""Private, read-only evidence for one narrowly qualified checkout refusal.

No checkout, repair, cleanup or topology reconstruction occurs here. Incomplete
observations decline qualification; callers retain their existing hard failure.
"""
import hashlib
import json
import os
from pathlib import Path
import stat
import subprocess
import sys

sys.dont_write_bytecode = True
MAX_ENTRIES = 4096
MAX_BYTES = 64 * 1024 * 1024


def require(value):
    if not value:
        raise ValueError('checkout evidence unavailable')


def git(path, *arguments):
    result = subprocess.run(['git', '-C', str(path), *arguments], stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=10,
                            env=dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_NO_LAZY_FETCH='1',
                                     GIT_TERMINAL_PROMPT='0'))
    require(result.returncode == 0 and len(result.stdout) <= 1024 * 1024)
    return result.stdout


def related(left, right):
    left, right = str(left).casefold().rstrip('/'), str(right).casefold().rstrip('/')
    return left == right or left.startswith(right + '/') or right.startswith(left + '/')


def identity(path):
    # Routing/overrides would make a local .git inspection incomplete.
    for name in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE',
                 'GIT_OBJECT_DIRECTORY', 'GIT_ALTERNATE_OBJECT_DIRECTORIES',
                 'GIT_NAMESPACE', 'GIT_CONFIG', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS',
                 'GIT_SHALLOW_FILE', 'GIT_REPLACE_REF_BASE', 'GIT_EXEC_PATH'):
        require(name not in os.environ)
    root = Path(path).resolve(strict=True)
    require(Path.home().resolve(strict=True) in root.parents)
    directory = root / '.git'
    require(directory.is_dir() and not directory.is_symlink())
    config = git(root, 'config', '--null', '--list')
    for record in config.split(b'\0'):
        key, _, value = record.partition(b'\n')
        key = key.lower()
        require(not key.startswith((b'filter.', b'extensions.', b'submodule.', b'maintenance.')))
        require(key not in (b'core.hookspath', b'core.worktree', b'core.sparsecheckout',
                            b'core.splitindex', b'core.untrackedcache', b'checkout.workers',
                            b'submodule.recurse'))
        if key == b'core.fsmonitor':
            require(value.lower() in (b'false', b'0', b'no', b'off'))
        require(not (key.startswith(b'remote.') and key.endswith(b'.promisor')))
    require(Path(os.fsdecode(git(root, 'rev-parse', '--show-toplevel').rstrip(b'\n'))).resolve() == root)
    require(Path(os.fsdecode(git(root, 'rev-parse', '--absolute-git-dir').rstrip(b'\n'))).resolve() == directory)
    common = os.fsdecode(git(root, 'rev-parse', '--git-common-dir').rstrip(b'\n'))
    require((root / common).resolve() == directory)
    for relative in ('commondir', 'worktrees', 'modules', 'objects/info/alternates',
                     'objects/info/http-alternates', 'info/sparse-checkout'):
        require(not os.path.lexists(directory / relative))
    hooks = directory / 'hooks'
    if hooks.exists():
        require(hooks.is_dir() and not hooks.is_symlink())
        require(all(entry.name.endswith('.sample') for entry in hooks.iterdir()))
    worktrees = [row[9:] for row in git(root, 'worktree', 'list', '--porcelain', '-z').split(b'\0')
                 if row.startswith(b'worktree ')]
    require(len(worktrees) == 1 and Path(os.fsdecode(worktrees[0])).resolve() == root)
    require(not git(root, 'ls-files', '--unmerged', '-z'))
    index = git(root, 'ls-files', '--stage', '-z')
    require(not any(row.startswith(b'160000 ') for row in index.split(b'\0')))
    head = git(root, 'rev-parse', '--verify', 'HEAD^{commit}')
    branch = git(root, 'branch', '--show-current')
    origin = git(root, 'remote', 'get-url', 'origin')
    require(origin.strip())
    ids = [[item.stat().st_dev, item.stat().st_ino] for item in (root, directory)]
    return root, config + head + branch + origin + index, ids, origin.rstrip(b'\n')


def fingerprint(root, seed):
    digest = hashlib.sha256(seed)
    entries = total = 0

    def visit(path):
        nonlocal entries, total
        entries += 1
        require(entries <= MAX_ENTRIES)
        before = path.lstat()
        require(before.st_uid == os.getuid() and not before.st_mode & 0o022 and
                not stat.S_ISLNK(before.st_mode))
        relative = path.relative_to(root)
        require(relative == Path('.git') or '.git' not in relative.parts[1:])
        require(not (relative.parts and relative.parts[0] == '.git' and path.name.endswith('.lock')))
        details = [str(relative), before.st_dev, before.st_ino, before.st_mode, before.st_uid, before.st_gid]
        if stat.S_ISDIR(before.st_mode):
            children = sorted(path.iterdir())
            digest.update(json.dumps(details).encode())
            for child in children:
                visit(child)
            require(children == sorted(path.iterdir()))
            after = path.lstat()
            require((before.st_dev, before.st_ino, before.st_mode) == (after.st_dev, after.st_ino, after.st_mode))
        else:
            require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1)
            total += before.st_size
            require(total <= MAX_BYTES)
            details += [before.st_size, before.st_mtime_ns, before.st_ctime_ns]
            digest.update(json.dumps(details).encode())
            descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            try:
                require(os.fstat(descriptor) == before)
                remaining = before.st_size
                while remaining:
                    block = os.read(descriptor, min(65536, remaining))
                    require(block)
                    digest.update(block)
                    remaining -= len(block)
                require(not os.read(descriptor, 1))
                after = os.fstat(descriptor)
                require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) ==
                        (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns))
            finally:
                os.close(descriptor)

    visit(root)
    return digest.hexdigest()


def snapshot(path, branch, remote):
    root, seed, ids, origin = identity(path)
    require(origin == os.fsencode(remote))
    target = git(root, 'rev-parse', '--verify', 'refs/heads/' + branch + '^{commit}')
    tree = git(root, 'ls-tree', '-r', '-z', 'refs/heads/' + branch)
    rows = [row.split(b'\t', 1) for row in tree.split(b'\0') if row]
    require(all(len(row) == 2 and not row[0].startswith(b'160000 ') for row in rows))
    targets = [os.fsdecode(row[1]) for row in rows]
    others = git(root, 'ls-files', '--others', '--exclude-standard', '-z')
    others += git(root, 'ls-files', '--others', '--ignored', '--exclude-standard', '-z')
    blockers = [os.fsdecode(row) for row in others.split(b'\0') if row]
    require(any(related(local, target) for local in blockers for target in targets))
    return {'path': str(root), 'branch': branch, 'remote': remote, 'ids': ids,
            'digest': fingerprint(root, seed + target + tree + others)}


def independent(path, records):
    root, seed, ids, _ = identity(path)
    fingerprint(root, seed)  # Reject shared files, nested repositories and incomplete enumeration.
    require(records)
    for record in records:
        require(snapshot(record['path'], record['branch'], record['remote']) == record)
        require(not related(root, record['path']))
        require(not any(left == right for left in ids for right in record['ids']))


def main():
    try:
        if sys.argv[1] == 'snapshot':
            print(json.dumps(snapshot(*sys.argv[2:]), sort_keys=True))
        elif sys.argv[1] == 'independent':
            records = sys.stdin.read(65537)
            require(len(records) <= 65536)
            independent(sys.argv[2], [json.loads(row) for row in records.splitlines()])
        else:
            return 2
        return 0
    except (OSError, ValueError, KeyError, TypeError, IndexError, RuntimeError, subprocess.SubprocessError):
        return 2


if __name__ == '__main__':
    sys.exit(main())
