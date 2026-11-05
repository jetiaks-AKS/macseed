"""Pinned Desktop age; CLI retains its existing PATH-based tool contract."""
from dataclasses import dataclass
import errno
import hashlib
import os
from pathlib import Path
import platform
import shutil
import stat
import struct
import sys

VERSION = 'v1.3.2'
DESKTOP_BUNDLE = 'MACSEED_DESKTOP_BUNDLE'
RELATIVE_EXECUTABLE = 'Contents/Helpers/age'
LICENSE_SHA256 = 'afbdb4e07a359499db587ae632815809b1fc1670a92d5449af112ce9a67833a2'
# Official release archives, verified with upstream Sigsum v0.13.1 and the
# sigsum-generic-2025-1 policy. See docs/DISTRIBUTION.md for the trust record.
ARTIFACTS = {
    'arm64': dict(archive='e2020b073c44f692685a24d6abc378817eb81ffaaf49fd0531ef8565f767f2f5',
                  binary='4012dfc2725883beafb710894af4f599b7a94f8c8e0f51f02cc96ab8df33915e', cpu=0x0100000c),
    'x86_64': dict(archive='1d1e4bc66e1427edad7739ae7616157de0e79db8b6d2a1497d7d9925fb06a539',
                   binary='0c2fbcffab91d0af398162a8ed792e096916c8c47c3c400e303904431103f492', cpu=0x01000007),
}


def valid_binary(raw, architecture):
    pin = ARTIFACTS.get(architecture)
    return (pin is not None and 32 <= len(raw) <= 16 * 1024 * 1024
            and struct.unpack('<I', raw[:4])[0] == 0xfeedfacf
            and struct.unpack('<I', raw[4:8])[0] == pin['cpu']
            and struct.unpack('<I', raw[12:16])[0] == 2
            and hashlib.sha256(raw).hexdigest() == pin['binary'])


@dataclass(frozen=True)
class BundledAgeInspection:
    status: str
    executable: str = None
    version: str = None
    architecture: str = None


def inspect_bundle(bundle, architecture=None):
    """Inspect without executing. No symlinks, unsafe modes or external fallback.

    Open each path component relative to a held directory descriptor. Recheck the
    file and visible chain after hashing so replacement during inspection fails.
    The development checkout/app are trusted code; Stage 17 must additionally seal
    and validate signed nested code (signing changes these upstream binary hashes).
    """
    architecture = architecture or platform.machine()
    if architecture not in ARTIFACTS:
        return BundledAgeInspection('unable_to_verify')
    if not isinstance(bundle, str) or not bundle.startswith('/') or '\0' in bundle:
        return BundledAgeInspection('invalid')
    path = Path(bundle)
    if path.suffix != '.app' or str(path) != bundle or '..' in path.parts:
        return BundledAgeInspection('invalid')
    opened, stamps = [], []
    try:
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
        opened.append(fd)
        parts = (*path.parts[1:], 'Contents', 'Helpers')
        for index, part in enumerate(parts):
            fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            opened.append(fd)
            info = os.fstat(fd)
            if index >= len(path.parts) - 2 and (info.st_uid not in (0, os.getuid()) or info.st_mode & 0o022):
                return BundledAgeInspection('invalid')
            stamps.append((info.st_dev, info.st_ino))
        binary = os.open('age', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
        opened.append(binary)
        before = os.fstat(binary)
        if (not stat.S_ISREG(before.st_mode) or before.st_uid not in (0, os.getuid())
                or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o755
                or not 32 <= before.st_size <= 16 * 1024 * 1024):
            return BundledAgeInspection('invalid')
        raw = bytearray()
        while len(raw) <= before.st_size:
            chunk = os.read(binary, min(65536, before.st_size + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        def stamp(value):
            return (value.st_dev, value.st_ino, value.st_mode, value.st_uid, value.st_nlink,
                    value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        executable = path / RELATIVE_EXECUTABLE
        if (stamp(before) != stamp(os.fstat(binary)) or stamp(before) != stamp(os.lstat(executable))
                or not valid_binary(raw, architecture)):
            return BundledAgeInspection('invalid')
        visible = Path('/')
        for part, expected in zip(parts, stamps):
            visible /= part
            current = os.lstat(visible)
            if not stat.S_ISDIR(current.st_mode) or (current.st_dev, current.st_ino) != expected:
                return BundledAgeInspection('invalid')
        # The exact authenticated bytes bind both the release version and CPU.
        # Settings consumes this same decision; it never executes age to discover them.
        return BundledAgeInspection('available', str(executable), VERSION, architecture)
    except OSError as error:
        if error.errno == errno.ENOENT:
            return BundledAgeInspection('missing')
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            return BundledAgeInspection('invalid')
        return BundledAgeInspection('unable_to_verify')
    except ValueError:
        return BundledAgeInspection('invalid')
    finally:
        for descriptor in reversed(opened):
            os.close(descriptor)


def bundled_executable(bundle, architecture=None):
    return inspect_bundle(bundle, architecture).executable


def executable():
    if DESKTOP_BUNDLE in os.environ:
        return bundled_executable(os.environ[DESKTOP_BUNDLE])
    return shutil.which('age')


if __name__ == '__main__':
    sys.exit(0 if sys.argv[1:] == ['--check'] and executable() else 2)
