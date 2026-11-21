"""Inspect target-owned Zsh provider installations. No provider process is launched."""
import ctypes
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import stat
import struct
import subprocess

spec = importlib.util.spec_from_file_location('provider_file_policy', Path(__file__).with_name('aliases.py'))
file_policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(file_policy)


class Unqualified(ValueError):
    pass


# SHA-256 from static.rust-lang.org/rustup/archive/{1.28.2,1.29.3}/<target>/rustup-init.sha256.
RUSTUP = {
    'arm64': {'20ef5516c31b1ac2290084199ba77dbbcaa1406c45c1d978ca68558ef5964ef5',
              '63752a1919a3a4793173ec70f8f212621a7ce38ba6a246095984482f4de20f9f'},
    'x86_64': {'9c331076f62b4d0edeae63d9d1c9442d5fe39b37b05025ec8d41c5ed35486496',
               'bc107f1fb0228de7fa32413c89c1b305cea9cd256e94b01150cd054128145429'},
}
# Whole-file launcher/dispatcher/shellenv identities select their reviewed
# additional sources and whether shellenv reaches the system id lookup.
BREW_OS = (('utils/os.sh', 'c83eacf7b72cfffac02b87973622bb5b66f6d6ca6e9d80d27b922e5dc0318fa6'),)
BREW_RELEASES = {
    ('8a25c9c7911374cec315b223c4fddbba6843b49f688a4f3b085567a677d368bc',
     '206042147db08a4815f03944df148c3671db36f2919426cedadb555d3a465c3c',
     '4725adb705296bde080c222cf12fbaae03593114edce2b699140ba3b05675a3e'): ((), False),  # 5.0.0
    ('c9a27029eb72dab04f4595041f7670bb03b4cb467297abba817883afb23e0bf3',
     'e4ffb52d887309fb53737d4080b705615ee603556542f60663229070f171431e',
     '04e6506a4649dfb1ac6c6576a8fbdf086cc6136b8da8b3c2078b02e207792ef8'): (BREW_OS, True),  # 7.0.11
    ('c9a27029eb72dab04f4595041f7670bb03b4cb467297abba817883afb23e0bf3',
     'c449628d32f7a5e3442057b82c6472ecc596f7623be1619fb0eb2de9202bd26d',
     '04e6506a4649dfb1ac6c6576a8fbdf086cc6136b8da8b3c2078b02e207792ef8'): (BREW_OS, False),  # 7.0.15
}
# Digests of uncompressed macOS executables from the official jdx/mise
# release assets for v2025.11.7 and v2026.11.10.
MISE_RELEASES = {
    'arm64': {'43de9d6ec62c821c0301fd1e8250e2b436cce42532a9eaffbb919e1717925bb9',
              '3f4ba9d21c6f2170048d0870fd98ab287e04730b76a6fc8e83964d59c80eb704'},
    'x86_64': {'9abdb272462159259cae02efbc2bbf37d931aa90c20ff070e1f8fcfc38e4b0ab',
               '7eab8054d301b75dcbd93440ff184bee6864d95799cfdc4a00ce858313b68783'},
}
# Sorted relative names and SHA-256 of all regular files in the upstream v2.6.14 trees.
PYENV_LIBEXEC = '1c4a154f6d640ef24404140fd4c0216ecc9a301fec809714283b47aee09d69f8'
PYENV_REHASH = 'ac82f9480846c750e611d686683244a83483b1524e721087591e607e3d842199'
PYENV_COMPLETION = 'ed89a8042c37c1df64a5ac8d449f06709f137b26b1b01f2d4adc75ff8f303f9b'
# SHA-256 of bin/<formula> after validating the official bottle blob against
# formulae.brew.sh's independent SHA-256. Includes available macOS platforms.
FORMULA_BINARIES = {
    ('fnm', 'arm64'): {'ad84e0f4d941a0363fe4f58ef0fc36daea59fff84ea5d09c0a5bcc87c41bc72c',
                       'dee5acc82725a109d74989219b9adf2ec22f7bd58e8cf043b043a127ffe2c9b3',
                       '0eef8ee5288bdb248bbf0fde9b66cd266344e62514d3bc697c7f76d3030a626b',
                       'e3ea80a3d0af9d5115c9bb4a859431ac4b493a850f4621e1972ae896170f3663'},
    ('fnm', 'x86_64'): {'d5a6bbc3021be08ad960647d000ffccd10b46badc62f8b3730bd6873b8d0a41a'},
    ('direnv', 'arm64'): {'aafe35e8edbcfeaf2948f34d96dc40b5813152dcffe4002e53b34b470428aed0',
                          'e0bffc81769ea003bf37216e35b63fab6bb1c75f01889a779fd71a68a1b647de',
                          'c655c839adcdda53996f420edfd478beef9240adbb13ef98688cfb89634d1c97'},
    ('mise', 'arm64'): {'c847cd20edab31601a6403829686c7933c664c85dd614baab0a36dd8f656bcd7',
                        '11a99e80f733a502dbd3b82ef2a01ce5ab0ee170ea03dd4116f58924265ec119',
                        'bc2bbae7b2096e701fd4bfab4517edf93834e1d912a1a7f5ee3c8fe0c4c9fd69'},
}



def _stamp(path, evidence, *, directory=False, executable=False):
    info = path.lstat()
    safe_group = info.st_gid in (0, 80)
    if (info.st_uid not in (0, os.getuid()) or info.st_mode & 0o002 or
            info.st_mode & 0o020 and not safe_group or
            not (stat.S_ISDIR(info.st_mode) if directory else stat.S_ISREG(info.st_mode)) or
            executable and not info.st_mode & 0o111):
        raise Unqualified('tool_observation_prerequisite')
    flags = os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW | (os.O_DIRECTORY if directory else 0)
    fd = os.open(path, flags)
    try:
        if file_policy.stamp(os.fstat(fd)) != file_policy.stamp(info):
            raise Unqualified('tool_observation_prerequisite')
        file_policy.acl_safe(fd)
    finally:
        os.close(fd)
    # Directory times change during unrelated and protected Shell publication.
    evidence[str(path)] = [info.st_dev, info.st_ino, info.st_uid, info.st_gid, info.st_mode,
                           *([] if directory else [info.st_size, info.st_ctime_ns, info.st_mtime_ns])]
    return info


def _checked(path, evidence, executable=False):
    for directory in reversed(path.parents):
        _stamp(directory, evidence, directory=True)
    return _stamp(path, evidence, executable=executable)


def _bytes(path, evidence, limit, *, executable=False):
    info = _checked(path, evidence, executable=executable)
    if info.st_size > limit:
        raise Unqualified('tool_observation_prerequisite')
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        if os.fstat(fd) != info:
            raise Unqualified('tool_observation_prerequisite')
        raw = stream.read(limit + 1)
        after = os.fstat(fd)
        if (len(raw) != info.st_size or after.st_ctime_ns != info.st_ctime_ns or
                path.lstat().st_ino != info.st_ino):
            raise Unqualified('tool_observation_prerequisite')
    evidence[str(path)].append(hashlib.sha256(raw).hexdigest())
    return raw


def _release_binary(path, evidence, allowed):
    info = _checked(path, evidence, executable=True)
    if not allowed or info.st_size > 192 * 1024 * 1024:
        raise Unqualified('tool_observation_prerequisite')
    with os.fdopen(os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK), 'rb') as stream:
        digest = hashlib.sha256()
        for data in iter(lambda: stream.read(1024 * 1024), b''):
            if stream.tell() > info.st_size:
                raise Unqualified('tool_observation_prerequisite')
            digest.update(data)
        if (file_policy.stamp(info) != file_policy.stamp(os.fstat(stream.fileno())) or
                file_policy.stamp(info) != file_policy.stamp(path.lstat()) or digest.hexdigest() not in allowed):
            raise Unqualified('tool_observation_prerequisite')
        _native_image(stream.fileno())
    evidence[str(path)].append(digest.hexdigest())
    return info


def _native_image(fd):
    """Read the authenticated Mach-O slice and its immediate loader prerequisites."""
    bad = 'tool_observation_prerequisite'
    cpu = {'arm64': 0x0100000c, 'x86_64': 0x01000007}.get(platform.machine())
    header = os.pread(fd, 4096, 0)
    offsets = [0]
    if header[:4] in (b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf'):
        width = 20 if header[3] == 0xbe else 32
        count = int.from_bytes(header[4:8], 'big')
        if not 0 < count <= 32 or len(header) < 8 + width * count:
            raise Unqualified(bad)
        offsets = [int.from_bytes(header[i+8:i+(12 if width == 20 else 16)], 'big')
                   for i in range(8, 8 + width * count, width) if int.from_bytes(header[i:i+4], 'big') == cpu]
        if not offsets:
            raise Unqualified(bad)
    for offset in offsets:
        _native_slice(fd, offset, cpu)


def _native_slice(fd, offset, cpu):
    bad = 'tool_observation_prerequisite'
    header = os.pread(fd, 32, offset)
    if (len(header) < 32 or header[:4] != b'\xcf\xfa\xed\xfe' or
            int.from_bytes(header[4:8], 'little') != cpu or int.from_bytes(header[12:16], 'little') != 2):
        raise Unqualified(bad)
    count, size = struct.unpack_from('<II', header, 16)
    if count > 1024 or size > 1024 * 1024:
        raise Unqualified(bad)
    table = os.pread(fd, size, offset + 32)
    cached = getattr(ctypes.CDLL(None), '_dyld_shared_cache_contains_path', None)
    if cached:
        cached.argtypes, cached.restype = [ctypes.c_char_p], ctypes.c_bool
    current = [int(v) for v in platform.mac_ver()[0].split('.')[:3]]
    os_version = int.from_bytes(bytes([0, *(current + [0, 0])[:3]]), 'big')
    index = 0
    for _ in range(count):
        if index + 8 > len(table):
            raise Unqualified(bad)
        command, length = struct.unpack_from('<II', table, index)
        if length < 8 or index + length > len(table):
            raise Unqualified(bad)
        cmd = command & 0x7fffffff
        if cmd in (0xc, 0x18, 0x1f, 0x20, 0x23, 0xe):
            if length < 12:
                raise Unqualified(bad)
            start = struct.unpack_from('<I', table, index + 8)[0]
            name = table[index+start:index+length].split(b'\0', 1)[0]
            if (not name.startswith((b'/usr/lib/', b'/System/Library/')) or os.path.normpath(name) != name or
                    not (os.path.isfile(name) or cached and cached(name))):
                raise Unqualified(bad)
        if cmd == 0x32 and (length < 24 or struct.unpack_from('<I', table, index + 8)[0] != 1 or
                             struct.unpack_from('<I', table, index + 12)[0] > os_version):
            raise Unqualified(bad)
        if cmd == 0x24 and (length < 16 or struct.unpack_from('<I', table, index + 8)[0] > os_version):
            raise Unqualified(bad)
        index += length
    if index != size:
        raise Unqualified(bad)


def _prefixes(evidence):
    # A custom prefix requires target-local administrator enrollment. A prefix
    # found only in the imported invocation cannot nominate a trusted program.
    prefixes = [Path('/opt/homebrew'), Path('/usr/local')]
    marker = Path('/private/etc/paths.d/homebrew')
    try:
        if marker.lstat().st_uid != 0:
            raise Unqualified('tool_observation_prerequisite')
        for entry in _bytes(marker, evidence, 4096).decode().splitlines():
            if re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/){1,8}bin', entry) and '..' not in entry.split('/'):
                prefixes.append(Path(entry).parent)
    except FileNotFoundError:
        pass
    return list(dict.fromkeys(prefixes))


def _installation(prefix, evidence):
    repo = prefix / 'Homebrew' if prefix == Path('/usr/local') else prefix
    brew = repo / 'bin/brew'
    files = [brew, repo / 'Library/Homebrew/brew.sh', repo / 'Library/Homebrew/cmd/shellenv.sh']
    for path in files:
        _bytes(path, evidence, 128 * 1024, executable=path == brew)
    profile = BREW_RELEASES.get(tuple(evidence[str(path)][-1] for path in files))
    if profile is None:
        raise Unqualified('tool_observation_prerequisite')
    helpers, needs_id = profile
    for relative, digest in helpers:
        if hashlib.sha256(_bytes(repo / 'Library/Homebrew' / relative, evidence, 65536)).hexdigest() != digest:
            raise Unqualified('tool_observation_prerequisite')
    if needs_id:
        # The authenticated launcher resets PATH with /usr/bin first and uses
        # env -i /bin/bash -p before this dispatcher's group check.
        identity = Path('/usr/bin/id')
        for component in (*reversed(identity.parents), identity):
            info = _stamp(component, evidence, directory=component != identity, executable=component == identity)
            if info.st_uid != 0 or info.st_mode & 0o022:
                raise Unqualified('tool_observation_prerequisite')
        _verify_code(identity, info, ('-R', '=anchor apple and identifier "com.apple.id"'))
    return brew


def _without_brew_overrides(prefix, home, evidence):
    files = [Path('/private/etc/homebrew/brew.env'), prefix / 'etc/homebrew/brew.env']
    if home is not None:
        files += [Path(home) / '.homebrew/brew.env', Path(home) / '.config/homebrew/brew.env']
    for path in files:
        try:
            for parent in reversed(path.parents):
                _stamp(parent, evidence, directory=True)
            path.lstat()
        except FileNotFoundError:
            continue
        raise Unqualified('tool_observation_prerequisite')


def _entries(path, evidence):
    try:
        for part in (*reversed(path.parents), path):
            _stamp(part, evidence, directory=True)
    except FileNotFoundError:
        return []
    # Bound enumeration even for an unexpectedly large local plugin directory.
    with os.scandir(path) as children:
        entries = []
        for child in children:
            if len(entries) >= 64:
                raise Unqualified('tool_observation_prerequisite')
            entries.append(child.name)
    return sorted(entries)


def _release_tree(root, evidence, expected, *, executable=False):
    todo, entries, count = [root], {}, 0
    while todo:
        current = todo.pop()
        for name in _entries(current, evidence):
            path = current / name
            count += 1
            if (len(path.relative_to(root).parts) > 3 or count > 64 or
                    not re.fullmatch(r'[A-Za-z0-9_.-]{1,80}', name)):
                raise Unqualified('tool_observation_prerequisite')
            if stat.S_ISDIR(path.lstat().st_mode):
                todo.append(path)
            else:
                if executable:
                    _checked(path, evidence, executable=True)
                entries[path.relative_to(root).as_posix()] = hashlib.sha256(_bytes(path, evidence, 65536)).hexdigest()
    manifest = ''.join(name + ' ' + digest + '\n' for name, digest in sorted(entries.items()))
    if hashlib.sha256(manifest.encode()).hexdigest() != expected:
        raise Unqualified('tool_observation_prerequisite')


def _pyenv(root, home, evidence):
    _release_tree(root / 'libexec', evidence, PYENV_LIBEXEC, executable=True)
    _release_tree(root / 'pyenv.d/rehash', evidence, PYENV_REHASH)
    completion = root / 'completions/pyenv.zsh'
    if hashlib.sha256(_bytes(completion, evidence, 65536)).hexdigest() != PYENV_COMPLETION:
        raise Unqualified('tool_observation_prerequisite')
    # Additional rehash hooks can source arbitrary code when init runs. A
    # normal bundled python-build plugin needs no sh-* commands or rehash hook.
    forbidden = [Path('/usr/etc/pyenv.d/rehash'), Path('/usr/local/etc/pyenv.d/rehash'),
                 Path('/private/etc/pyenv.d/rehash'), Path('/usr/lib/pyenv/hooks/rehash')]
    if home is not None:
        forbidden.extend([Path(home) / '.pyenv/plugins', Path(home) / '.pyenv/pyenv.d/rehash'])
    plugins = root / 'plugins'
    if set(_entries(plugins, evidence)) - {'python-build'}:
        raise Unqualified('tool_observation_prerequisite')
    forbidden.append(plugins / 'python-build/etc/pyenv.d/rehash')
    if any(_entries(path, evidence) for path in forbidden):
        raise Unqualified('tool_observation_prerequisite')
    if any(name.startswith('pyenv-sh-') for name in _entries(plugins / 'python-build/bin', evidence)):
        raise Unqualified('tool_observation_prerequisite')


def _formula(prefix, name, evidence, home):
    link = prefix / 'bin' / name
    real = link
    for _ in range(12):
        components = real.relative_to(prefix).parts
        current = prefix
        for i, part in enumerate(components):
            current /= part
            info = current.lstat()
            if stat.S_ISLNK(info.st_mode):
                if info.st_uid not in (0, os.getuid()):
                    raise Unqualified('tool_observation_prerequisite')
                target = os.readlink(current)
                evidence[str(current)] = [info.st_dev, info.st_ino, info.st_ctime_ns, target]
                real = Path(os.path.normpath(current.parent / target)).joinpath(*components[i+1:])
                real.relative_to(prefix)
                break
            if i + 1 < len(components):
                _stamp(current, evidence, directory=True)
        else:
            break
    else:
        raise Unqualified('tool_observation_prerequisite')
    relative = real.relative_to(prefix / 'Cellar' / name)
    if len(relative.parts) < 3 or real.name != name:
        raise Unqualified('tool_observation_prerequisite')
    _checked(real, evidence, executable=True)
    receipt = prefix / 'Cellar' / name / relative.parts[0] / 'INSTALL_RECEIPT.json'
    data = json.loads(_bytes(receipt, evidence, 262144))
    arch = {'arm64': 'arm64', 'x86_64': 'x86_64'}.get(platform.machine())
    if (not isinstance(data, dict) or not isinstance(data.get('source'), dict) or
            data['source'].get('tap') != 'homebrew/core' or arch is None or data.get('arch') != arch or
            data.get('poured_from_bottle') is not True):
        raise Unqualified('tool_observation_prerequisite')
    if name == 'pyenv':
        if real.parent.name != 'libexec':
            raise Unqualified('tool_observation_prerequisite')
        _pyenv(real.parent.parent, home, evidence)
        return link
    info = _release_binary(real, evidence, FORMULA_BINARIES.get((name, arch), ()))
    _verify_code(real, info)
    return link


def _verify_code(real, info, requirements=()):
    fd = os.open(real, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        try:
            verified = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', *requirements, '--', str(real)],
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                env={'PATH': '/usr/bin:/bin'}, timeout=5, check=False)
        except subprocess.TimeoutExpired:
            raise Unqualified('tool_observation_prerequisite') from None
        if (verified.returncode or file_policy.stamp(info) != file_policy.stamp(os.fstat(stream.fileno())) or
                file_policy.stamp(info) != file_policy.stamp(real.lstat())):
            raise Unqualified('tool_observation_prerequisite')


def executable(intent, evidence, home=None):
    """Return a fixed absolute invocation bound independently to the target."""
    variant = intent['variant']
    token, args = variant.split(' ', 1)
    name = token.rsplit('/', 1)[-1]
    candidates = []
    local = Path(home) / '.local/bin/mise' if name == 'mise' and home is not None else None
    standalone = False
    if local is not None and not token.startswith('/') and os.path.lexists(local) and not local.is_symlink():
        _release_binary(local, evidence, MISE_RELEASES.get(platform.machine(), ()))
        if token != 'mise':
            return token + ' ' + args
        standalone = True
    for prefix in _prefixes(evidence):
        try:
            if name == 'brew':
                brew = _installation(prefix, evidence)
            else:
                repo = prefix / 'Homebrew' if prefix == Path('/usr/local') else prefix
                # Formula recipes invoke their own authenticated executable.
                # The shellenv implementation is not a dependency of that call.
                launcher = repo / 'bin/brew'
                _checked(launcher, evidence, executable=True)
                if not _bytes(launcher, evidence, 131072).startswith(b'#!/bin/bash'):
                    raise Unqualified('tool_observation_prerequisite')
        except FileNotFoundError:
            if os.path.lexists(prefix / 'bin/brew'):
                raise Unqualified('tool_observation_prerequisite')
            continue
        try:
            if name == 'brew':
                if prefix == Path('/usr/local') and platform.machine() != 'x86_64' or (
                    prefix == Path('/opt/homebrew') and platform.machine() != 'arm64'):
                    raise Unqualified('tool_observation_prerequisite')
                _without_brew_overrides(prefix, home, evidence)
                target = brew
            else:
                target = _formula(prefix, name, evidence, home)
            candidates.append(target)
        except FileNotFoundError:
            if os.path.lexists(prefix / 'bin' / name):
                raise Unqualified('tool_observation_prerequisite')
            continue
    if standalone:
        if candidates:
            raise Unqualified('tool_observation_prerequisite')
        return '~/.local/bin/mise ' + args
    if len(candidates) != 1:
        raise Unqualified('tool_observation_prerequisite' if candidates else 'tool_missing_prerequisite')
    target = str(candidates[0])
    if token.startswith(('~/', '$HOME/')):
        if name != 'mise' or home is None:
            raise Unqualified('tool_observation_prerequisite')
        for parent in reversed(local.parents):
            _stamp(parent, evidence, directory=True)
        info = local.lstat()
        if not stat.S_ISLNK(info.st_mode) or info.st_uid not in (0, os.getuid()):
            raise Unqualified('tool_observation_prerequisite')
        destination = os.readlink(local)
        if destination != target:
            raise Unqualified('tool_observation_prerequisite')
        evidence[str(local)] = [info.st_dev, info.st_ino, info.st_ctime_ns, destination]
        return token + ' ' + args
    if token.startswith('/') and token != target:
        # Preserve explicit source prefixes. The standard Intel prefix link
        # may designate the same independently established repository.
        if token != '/usr/local/bin/brew' or target != '/usr/local/Homebrew/bin/brew' or Path(token).resolve(strict=True) != candidates[0]:
            raise Unqualified('tool_observation_prerequisite')
    if not re.fullmatch(r'/(?:[A-Za-z0-9_.-]+/){1,10}bin/[a-z0-9-]+', target):
        raise Unqualified('tool_observation_prerequisite')
    if name == 'brew' and args == 'shellenv':
        args = 'shellenv zsh'
    return target + ' ' + args
