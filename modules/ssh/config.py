"""Bounded SSH profile data, shared by Discovery, Bundle and conformity readers.

Never evaluates OpenSSH configuration or opens an IdentityFile reference.
"""
import errno
import os
from pathlib import Path
import re
import stat
import sys

MAX_CONFIG = 1024 * 1024
MAX_IDENTITIES = 32
NAMES = {name.lower(): name for name in (
    'HostName', 'User', 'Port', 'ServerAliveInterval', 'ServerAliveCountMax',
    'TCPKeepAlive', 'ConnectTimeout', 'IdentityFile', 'IdentitiesOnly',
    'AddKeysToAgent', 'UseKeychain')}
EXTENDED = {'identityfile', 'identitiesonly', 'addkeystoagent', 'usekeychain'}
STATES = {'absent-directory', 'absent-config', 'empty', 'ready', 'partial', 'unsupported', 'external'}


class Invalid(ValueError):
    pass


class Unsafe(ValueError):
    pass


def identity_path(value):
    if value == 'none':
        return 'none'
    if len(value) > 1024 or not value.startswith(('~/', '/')):
        return None
    parts = value[2 if value.startswith('~/') else 1:].split('/')
    if any(part in ('', '.', '..') or not re.fullmatch(r'[A-Za-z0-9_.-]+', part) for part in parts):
        return None
    return 'portable' if value.startswith('~/') else 'unresolved'


def valid_value(key, value):
    if key == 'hostname':
        return re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', value) is not None
    if key == 'user':
        return re.fullmatch(r'[A-Za-z_][A-Za-z0-9._-]*', value) is not None
    if key in ('tcpkeepalive', 'identitiesonly', 'addkeystoagent', 'usekeychain'):
        return value in ('yes', 'no')
    if key == 'identityfile':
        return identity_path(value) is not None
    bounds = {'port': (1, 65535), 'serveraliveinterval': (0, 3600),
              'serveralivecountmax': (0, 20), 'connecttimeout': (1, 300)}
    return (key in bounds and re.fullmatch(r'(0|[1-9][0-9]{0,4})', value) is not None
            and bounds[key][0] <= int(value) <= bounds[key][1])


def parse(raw, version=2):
    if len(raw) > MAX_CONFIG or b'\0' in raw:
        raise Invalid('invalid SSH configuration')
    profiles, excluded, structural = {}, set(), False
    aliases, host, entries, bad = set(), None, [], False

    def finish():
        if host is not None:
            if bad or not any(key == 'hostname' for key, _ in entries):
                excluded.add(host)
            else:
                profiles[host] = list(entries)

    for raw_line in raw.split(b'\n'):
        line = raw_line.removesuffix(b'\r')
        if b'\r' in line:
            raise Invalid('invalid SSH configuration')
        line = line.strip(b' \t')
        if not line or line.startswith(b'#'):
            continue
        if any(byte < 32 and byte != 9 or byte > 126 for byte in line):
            raise Invalid('invalid SSH configuration')
        line = line.decode('ascii')
        assignment = re.match(r'^([A-Za-z][A-Za-z0-9]*)=', line)
        if assignment:
            key = assignment[1].lower()
            if key in ('host', 'include', 'match') or host is None:
                structural = True
            else:
                bad = True
            continue
        match = re.fullmatch(r'([A-Za-z][A-Za-z0-9]*)[ \t]+([^ \t].*)', line)
        if match is None:
            raise Invalid('invalid SSH configuration')
        key, value = match[1].lower(), match[2].strip(' \t')
        if key in ('include', 'match'):
            structural = True
        elif key == 'host':
            finish()
            host, entries, bad = value, [], False
            if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', host) or host.lower() in aliases:
                structural = True
            aliases.add(host.lower())
        elif host is None:
            structural = True
        elif (key not in NAMES or (version == 1 and key in EXTENDED)
              or not valid_value(key, value)):
            bad = True
        elif key == 'identityfile':
            previous = [v for k, v in entries if k == key]
            # OpenSSH's sentinel suppresses default files, not agent identities.
            # Mixed sentinel/path lists and duplicate paths are deliberately excluded.
            if (len(previous) >= MAX_IDENTITIES or value in previous
                    or (previous and (value == 'none' or 'none' in previous))):
                bad = True
            else:
                entries.append((key, value))
        elif any(k == key for k, _ in entries):
            bad = True
        else:
            entries.append((key, value))
    finish()
    return profiles, excluded, structural


def payload(profiles):
    return ''.join('Host ' + host + '\n' + ''.join(
        '    ' + NAMES[key] + ' ' + value + '\n' for key, value in entries)
        for host, entries in profiles.items()).encode('ascii')


def profile_values(entries):
    return ({key: value for key, value in entries if key != 'identityfile'},
            [value for key, value in entries if key == 'identityfile'])


def pending_publication(directory):
    # Only our direct sibling names; never inspect identities or their contents.
    with os.scandir(directory) as entries:
        return any(entry.name.startswith('.macseed-ssh-pending-') for entry in entries)


def snapshot(raw):
    lines = raw.split(b'\n', 4)
    if len(lines) != 5 or lines[0] not in (b'# toolkit-ssh-snapshot: 1', b'# toolkit-ssh-snapshot: 2'):
        raise Invalid('unsupported SSH snapshot version')
    version = int(lines[0][-1:])
    status = lines[1].removeprefix(b'# status: ').decode('ascii')
    count = lines[2].removeprefix(b'# excluded-profiles: ')
    if status not in STATES or re.fullmatch(rb'0|[1-9][0-9]{0,8}', count) is None or lines[3]:
        raise Invalid('invalid SSH snapshot')
    excluded = int(count)
    profiles, rejected, structural = parse(lines[4], version)
    if rejected or structural:
        raise Invalid('invalid SSH snapshot profiles')
    valid = ((status == 'ready' and profiles and excluded == 0)
             or (status == 'partial' and profiles and excluded > 0)
             or (status == 'unsupported' and not profiles and excluded > 0)
             or (status in STATES - {'ready', 'partial', 'unsupported'} and not profiles and excluded == 0))
    canonical = (f'# toolkit-ssh-snapshot: {version}\n# status: {status}\n'
                 f'# excluded-profiles: {excluded}\n\n').encode() + payload(profiles)
    if not valid or raw != canonical:
        raise Invalid('noncanonical SSH snapshot')
    return version, status, excluded, profiles


def select_snapshot(raw, hosts):
    """Narrow validated profiles without changing version or source coverage."""
    _, _, _, profiles = snapshot(raw)
    if (not hosts or len(set(hosts)) != len(hosts)
            or not set(hosts).issubset(profiles)):
        raise Invalid('invalid SSH Host selection')
    # Retain v2 even if the remaining profiles happen to use only v1 directives.
    # Intentional exclusions never increase unsupported-source coverage.
    header = raw.split(b'\n', 4)[:4]
    return b'\n'.join(header) + b'\n' + payload({
        host: entries for host, entries in profiles.items() if host in hosts})


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_nlink,
            info.st_size, info.st_mtime_ns, info.st_ctime_ns)


def read_file(path, *, directory=None, private=False):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1
                or (private and (before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o600))):
            raise Unsafe('unsafe SSH file')
        raw = stream.read(MAX_CONFIG + 1)
        if (len(raw) > MAX_CONFIG or stamp(before) != stamp(os.fstat(stream.fileno()))
                or stamp(before) != stamp(os.stat(path, dir_fd=directory, follow_symlinks=False))):
            raise Invalid('SSH observation changed')
        return raw


def read_snapshot(path):
    parent = str(Path(path).parent)
    fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if before.st_uid != os.getuid():
            raise Unsafe('unsafe SSH snapshot directory')
        raw = read_file(Path(path).name, directory=fd, private=True)
        if stamp(before) != stamp(os.fstat(fd)) or stamp(before) != stamp(os.stat(parent, follow_symlinks=False)):
            raise Invalid('SSH snapshot directory changed')
        return raw
    finally:
        os.close(fd)


def profile_assessment(expected, actual):
    """One conformity algorithm for aggregate verification and private Host detail."""
    source, _, _ = parse(expected)
    try:
        target, rejected, structural = parse(actual)
    except Invalid:
        return 'unsupported', 0, {host: 'unsupported' for host in source}
    # Case variants are ambiguous, never missing or equivalent.
    aliases = {host.lower(): host for host in target.keys() | rejected}
    if structural or any(host in rejected or aliases.get(host.lower(), host) != host for host in source):
        return 'unsupported', len(rejected), {host: 'unsupported' for host in source}
    states = {host: ('missing' if host not in target else
                    'matching' if profile_values(entries) == profile_values(target[host]) else 'differing')
              for host, entries in source.items()}
    conformity = ('conflicting_profiles' if 'differing' in states.values() else
                  'missing_profiles' if 'missing' in states.values() else
                  'exact' if actual == expected else 'profiles_match')
    return conformity, len(rejected), states


def assess(expected, home):
    """Return file equality separately from selected profile conformity."""
    if not os.path.isabs(home):
        raise Invalid('HOME must be absolute')
    opened = []
    try:
        hfd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        opened.append(hfd)
        hs = os.fstat(hfd)
        if hs.st_uid != os.getuid():
            raise Unsafe('unsafe HOME')
        try:
            dfd = os.open('.ssh', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=hfd)
        except FileNotFoundError:
            return 'absent-directory', 'missing_profiles', 0
        opened.append(dfd)
        ds = os.fstat(dfd)
        if ds.st_uid != os.getuid() or stat.S_IMODE(ds.st_mode) != 0o700:
            raise Unsafe('unsafe SSH directory')
        if pending_publication(dfd):
            return 'external', 'publication_uncertain', 0
        try:
            actual = read_file('config', directory=dfd, private=True)
        except FileNotFoundError:
            return 'absent-config', 'missing_profiles', 0
        conformity, excluded, _ = profile_assessment(expected, actual)
        return 'identical' if actual == expected else 'different', conformity, excluded
    finally:
        try:
            if opened and stamp(os.fstat(opened[0])) != stamp(os.stat(home, follow_symlinks=False)):
                raise Invalid('HOME changed')
            if len(opened) > 1 and (stamp(ds) != stamp(os.fstat(opened[1]))
                                   or stamp(ds) != stamp(os.stat('.ssh', dir_fd=opened[0], follow_symlinks=False))):
                raise Invalid('SSH directory changed')
        finally:
            for fd in reversed(opened):
                os.close(fd)


def main():
    command, *args = sys.argv[1:]
    if command == 'parse' and len(args) == 3:
        raw = read_file(args[0])
        if args[2] == 'snapshot':
            _, _, _, profiles = snapshot(raw)
            rejected, structural = set(), False
        elif args[2] == 'source':
            profiles, rejected, structural = parse(raw)
        else:
            raise Invalid('invalid mode')
        Path(args[1]).write_bytes(payload(profiles))
        print(len(profiles), len(rejected), int(structural))
    elif command == 'validate' and len(args) == 2:
        version, status, excluded, profiles = snapshot(read_snapshot(args[0]))
        Path(args[1]).write_bytes(payload(profiles))
        paths = [identity_path(value) for entries in profiles.values() for key, value in entries if key == 'identityfile']
        print(version, status, excluded, len(profiles), paths.count('portable'), paths.count('unresolved'))
    elif command == 'version' and len(args) == 1:
        profiles, rejected, structural = parse(read_file(args[0]))
        if rejected or structural:
            raise Invalid('invalid payload')
        print(2 if any(key in EXTENDED for entries in profiles.values() for key, _ in entries) else 1)
    elif command == 'assess' and len(args) == 2:
        try:
            print(*assess(read_file(args[0]), args[1]))
        except (Unsafe, NotADirectoryError):
            print('external unsafe 0')
            return 1
        except OSError as exc:
            if exc.errno == errno.ELOOP:
                print('external unsafe 0')
                return 1
            raise
    else:
        raise Invalid('invalid request')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Invalid, Unsafe, OSError, ValueError):
        sys.exit(2)  # Never expose file contents or paths in errors.
