#!/usr/bin/env python3
"""Build-time preparation only. Pinned verified bytes; no runtime downloader."""
import argparse
import hashlib
import io
import os
from pathlib import Path
import platform
import stat
import subprocess
import sys
import tarfile
import tempfile

sys.dont_write_bytecode = True
DESKTOP = Path(__file__).resolve().parent
sys.path.insert(0, str(DESKTOP.parent.parent / 'modules/migration'))
from age_runtime import ARTIFACTS, VERSION, LICENSE_SHA256, valid_binary

MAX_ARCHIVE = 64 * 1024 * 1024
MEMBERS = {'age', 'age/age', 'age/LICENSE', 'age/age-keygen', 'age/age-inspect',
           'age/age-plugin-batchpass', 'age/age-plugin-pq', 'age/age-plugin-tag', 'age/age-plugin-tagpq'}


def private_directory(path, mode=0o755):
    if not path.is_absolute() or path.resolve() != path:
        raise ValueError('build path must be absolute without symlinks')
    path.mkdir(parents=True, exist_ok=True, mode=mode)
    value = path.lstat()
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.getuid() or value.st_mode & 0o022:
        raise ValueError('unsafe build directory')


def read_archive(path, architecture):
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd, 'rb') as stream:
        before = os.fstat(stream.fileno())
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > MAX_ARCHIVE:
            raise ValueError('unsafe cached age artifact')
        raw = stream.read(MAX_ARCHIVE + 1)
        after = os.fstat(stream.fileno())
    def stamp(value):
        return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_nlink,
                value.st_size, value.st_mtime_ns, value.st_ctime_ns)
    if (stamp(before) != stamp(after) or stamp(path.lstat()) != stamp(after) or len(raw) > MAX_ARCHIVE
            or hashlib.sha256(raw).hexdigest() != ARTIFACTS[architecture]['archive']):
        raise ValueError('age artifact checksum mismatch; remove the invalid cached archive and retry')
    return raw


def unpack(raw, architecture):
    # Never extract paths or archive permissions. Validate every member first,
    # then copy only the executable and complete upstream redistribution notice.
    with tarfile.open(fileobj=io.BytesIO(raw), mode='r:gz') as archive:
        members = archive.getmembers()
        if len(members) != len(MEMBERS) or {m.name for m in members} != MEMBERS:
            raise ValueError('unexpected age archive members')
        for member in members:
            if (member.pax_headers or member.linkname or member.size > 16 * 1024 * 1024
                    or (member.name == 'age' and not member.isdir())
                    or (member.name != 'age' and not member.isfile())):
                raise ValueError('unsafe age archive entry')
        if sum(m.size for m in members) > MAX_ARCHIVE:
            raise ValueError('age archive too large')
        binary = archive.extractfile('age/age').read()
        license_text = archive.extractfile('age/LICENSE').read()
    if not valid_binary(binary, architecture) or hashlib.sha256(license_text).hexdigest() != LICENSE_SHA256:
        raise ValueError('age executable or license differs from verified upstream artifact')
    return binary, license_text


def publish(path, raw, mode):
    if path.is_symlink() or (path.exists() and not path.is_file()):
        raise ValueError('unsafe bundle output')
    with tempfile.NamedTemporaryFile(dir=path.parent, prefix='.age-', delete=False) as output:
        temporary = Path(output.name)
        try:
            os.fchmod(output.fileno(), mode)
            output.write(raw); output.flush(); os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def prepare(resources, architecture, cache):
    if architecture not in ARTIFACTS:
        raise ValueError('age requires one explicit arm64 or x86_64 target; universal packaging is not qualified')
    if resources.name != 'Resources' or resources.parent.name != 'Contents' or resources.parent.parent.suffix != '.app':
        raise ValueError('expected an app Contents/Resources directory')
    for directory in (resources.parent.parent, resources.parent, resources):
        private_directory(directory)
    private_directory(cache, 0o700)
    upstream_architecture = 'amd64' if architecture == 'x86_64' else architecture
    name = f'age-{VERSION}-darwin-{upstream_architecture}.tar.gz'
    cached = cache / name
    if not cached.exists() and not cached.is_symlink():
        with tempfile.NamedTemporaryFile(dir=cache, prefix='.download-', delete=False) as output:
            temporary = Path(output.name)
        try:
            subprocess.run(['/usr/bin/curl', '-q', '--fail', '--silent', '--show-error', '--location',
                            '--proto', '=https', '--proto-redir', '=https', '--tlsv1.2', '--connect-timeout', '15',
                            '--max-time', '120', '--max-filesize', str(MAX_ARCHIVE),
                            f'https://github.com/FiloSottile/age/releases/download/{VERSION}/{name}', '-o', str(temporary)], check=True)
            read_archive(temporary, architecture)
            os.replace(temporary, cached)
        finally:
            temporary.unlink(missing_ok=True)
    binary, license_text = unpack(read_archive(cached, architecture), architecture)
    helpers = resources.parent / 'Helpers'
    notices = resources / 'ThirdPartyNotices'
    private_directory(helpers); private_directory(notices)
    publish(helpers / 'age', binary, 0o755)
    publish(notices / 'age-LICENSE.txt', license_text, 0o644)
    if architecture == platform.machine():
        version = subprocess.run([str(helpers / 'age'), '--version'], stdout=subprocess.PIPE,
                                 stderr=subprocess.DEVNULL, timeout=10, check=True).stdout
        if version.strip() != VERSION.encode():
            raise ValueError('verified age version check failed')
    print(f'Prepared verified age {VERSION} ({architecture}) in Contents/Helpers/age')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('resources', type=Path)
    parser.add_argument('architecture', choices=tuple(ARTIFACTS))
    parser.add_argument('--cache', type=Path, default=DESKTOP / 'build/Dependencies' / ('age-' + VERSION))
    options = parser.parse_args()
    try:
        prepare(options.resources.absolute(), options.architecture, options.cache.absolute())
    except (OSError, ValueError, tarfile.TarError, subprocess.SubprocessError):
        print('Bundled age preparation failed: verify the pinned cache, network access and safe app output paths. No external age fallback.', file=sys.stderr)
        sys.exit(2)
