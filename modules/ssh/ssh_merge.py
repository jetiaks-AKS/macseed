"""Bounded SSH additions and Darwin predecessor-preserving publication.

No key readers, config evaluation, overwrite rename fallback or automatic rollback.
"""
from contextlib import contextmanager
import ctypes as C
import errno
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import uuid

spec = importlib.util.spec_from_file_location('ssh_configuration', Path(__file__).with_name('config.py'))
config = importlib.util.module_from_spec(spec)
spec.loader.exec_module(config)


class Refused(ValueError):
    pass


class PublicationUncertain(Refused):
    def __init__(self, changed=False):
        self.changed = changed


def native():
    if sys.platform != 'darwin':
        raise Refused('publication_unavailable')
    lib = C.CDLL(None, use_errno=True)
    lib.renameatx_np.argtypes = [C.c_int, C.c_char_p, C.c_int, C.c_char_p, C.c_uint]
    lib.renameatx_np.restype = C.c_int
    lib.acl_get_fd_np.argtypes = [C.c_int, C.c_int]
    lib.acl_get_fd_np.restype = C.c_void_p
    lib.acl_get_entry.argtypes = [C.c_void_p, C.c_int, C.POINTER(C.c_void_p)]
    lib.acl_get_tag_type.argtypes = [C.c_void_p, C.POINTER(C.c_int)]
    lib.acl_free.argtypes = [C.c_void_p]
    lib.fgetattrlist.argtypes = [C.c_int, C.c_void_p, C.c_void_p, C.c_size_t, C.c_ulong]
    lib.flistxattr.argtypes = [C.c_int, C.c_void_p, C.c_size_t, C.c_int]
    lib.flistxattr.restype = C.c_ssize_t
    lib.fgetxattr.argtypes = [C.c_int, C.c_char_p, C.c_void_p, C.c_size_t, C.c_uint, C.c_int]
    lib.fgetxattr.restype = C.c_ssize_t
    lib.fcopyfile.argtypes = [C.c_int, C.c_int, C.c_void_p, C.c_uint]
    return lib


def check_acl(fd, *, ancestor=False):
    lib = native()
    C.set_errno(0)
    acl = lib.acl_get_fd_np(fd, 0x100)  # ACL_TYPE_EXTENDED
    if not acl:
        if C.get_errno() == errno.ENOENT:
            return
        raise Refused('metadata_unavailable')
    try:
        entry, tag = C.c_void_p(), C.c_int()
        for index in range(129):
            if lib.acl_get_entry(acl, index, C.byref(entry)) != 0:
                if C.get_errno() == errno.EINVAL and index < 129:
                    return
                raise Refused('metadata_unavailable')
            # Ancestor deny-only ACLs (e.g. macOS HOME deny-delete) are safe.
            if (not ancestor or lib.acl_get_tag_type(entry, C.byref(tag)) != 0 or tag.value != 2):
                raise Refused('unsupported_acl')
        raise Refused('unsupported_acl')
    finally:
        lib.acl_free(acl)


def swap_supported(fd):
    class Attributes(C.Structure):
        _fields_ = [('count', C.c_ushort), ('reserved', C.c_ushort),
                    ('common', C.c_uint), ('volume', C.c_uint), ('directory', C.c_uint),
                    ('file', C.c_uint), ('fork', C.c_uint)]
    class Capabilities(C.Structure):
        _fields_ = [('length', C.c_uint), ('capabilities', C.c_uint * 4), ('valid', C.c_uint * 4)]
    attributes = Attributes(5, 0, 0, 0x80020000, 0, 0, 0)  # VOL_INFO | VOL_CAPABILITIES
    capabilities = Capabilities()
    if native().fgetattrlist(fd, C.byref(attributes), C.byref(capabilities), C.sizeof(capabilities), 0):
        raise Refused('publication_unavailable')
    required = 0x000C0000  # VOL_CAP_INT_RENAME_SWAP | VOL_CAP_INT_RENAME_EXCL
    if (capabilities.length != C.sizeof(capabilities) or
            capabilities.valid[1] & capabilities.capabilities[1] & required != required):
        raise Refused('publication_unavailable')


def rename(source_fd, source, target_fd, target, flag):
    # Darwin RENAME_NOFOLLOW_ANY | RENAME_RESOLVE_BENEATH; never follow links.
    if native().renameatx_np(source_fd, os.fsencode(source), target_fd, os.fsencode(target), flag | 0x30):
        raise OSError(C.get_errno(), 'SSH publication failed')


def identity(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_uid, info.st_gid, info.st_flags)


def file_evidence(info):
    return (*identity(info), info.st_nlink, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


@contextmanager
def target(home):
    """Pin ancestors and provide explicit rechecks at decision/publication boundaries."""
    path = Path(home)
    if not path.is_absolute() or '..' in path.parts or str(path) != home:
        raise Refused('unsafe_target')
    fds, links = [], []
    try:
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        fds.append(fd)

        def recheck():
            for parent, name, child, observed in links:
                if (identity(os.fstat(child)) != observed or
                        identity(os.stat(name, dir_fd=parent, follow_symlinks=False)) != observed):
                    raise Refused('target_changed')
                check_acl(child, ancestor=name != '.ssh')

        for part in (*path.parts[1:], '.ssh'):
            before = os.fstat(fd)
            if part == '.ssh' and before.st_uid != os.getuid():
                raise Refused('unsafe_target')
            if before.st_uid not in (0, os.getuid()) or (
                    stat.S_IMODE(before.st_mode) & 0o022 and
                    not (before.st_uid == 0 and before.st_mode & stat.S_ISVTX)):
                raise Refused('unsafe_ancestor')
            check_acl(fd, ancestor=True)
            try:
                child = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            except FileNotFoundError:
                if part != '.ssh':
                    raise
                recheck()
                yield None, recheck, [identity(os.fstat(item)) for item in fds]
                return
            fds.append(child)
            links.append((fd, part, child, identity(os.fstat(child))))
            fd = child
        directory = os.fstat(fd)
        if directory.st_uid != os.getuid() or stat.S_IMODE(directory.st_mode) != 0o700 or directory.st_flags:
            raise Refused('unsafe_target')
        check_acl(fd)

        recheck()
        yield fd, recheck, [identity(os.fstat(item)) for item in fds]
    finally:
        for fd in reversed(fds):
            os.close(fd)


def attributes(fd):
    lib = native()
    size = lib.flistxattr(fd, None, 0, 0)
    if not 0 <= size <= 8192:
        raise Refused('unsupported_metadata')
    names = C.create_string_buffer(size)
    if lib.flistxattr(fd, names, size, 0) != size:
        raise Refused('target_changed')
    entries = names.raw.split(b'\0')[:-1] if size else []
    if (size and not names.raw.endswith(b'\0')) or len(entries) > 32:
        raise Refused('unsupported_metadata')
    result = {}
    for name in entries:
        size = lib.fgetxattr(fd, name, None, 0, 0, 0)
        if not name or not 0 <= size <= 32768:
            raise Refused('unsupported_metadata')
        value = C.create_string_buffer(size)
        if lib.fgetxattr(fd, name, value, size, 0, 0) != size:
            raise Refused('target_changed')
        result[name] = value.raw
    return result


def observed_file(directory, name='config'):
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
    try:
        before = os.fstat(fd)
        if (not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_uid != os.getuid()
                or stat.S_IMODE(before.st_mode) != 0o600 or before.st_flags):
            raise Refused('unsafe_target')
        check_acl(fd)
        metadata = attributes(fd)
        raw = os.read(fd, config.MAX_CONFIG + 1)
        if (len(raw) > config.MAX_CONFIG or len(raw) != before.st_size or file_evidence(before) != file_evidence(os.fstat(fd)) or
                file_evidence(before) != file_evidence(os.stat(name, dir_fd=directory, follow_symlinks=False))):
            raise Refused('target_changed')
        return raw, before, metadata
    finally:
        os.close(fd)


def evidence(home):
    """Private digest only; comments, metadata and inode replacements invalidate plans."""
    try:
        with target(home) as (directory, recheck, ancestors):
            state = [ancestors]
            if directory is None:
                state.append('absent-directory')
            else:
                state.append(config.pending_publication(directory))
                try:
                    raw, info, metadata = observed_file(directory)
                    state.extend([file_evidence(info), hashlib.sha256(raw).hexdigest(),
                                  [(key.hex(), value.hex()) for key, value in sorted(metadata.items())]])
                except FileNotFoundError:
                    state.append('absent-config')
            recheck()
            return hashlib.sha256(json.dumps(state, separators=(',', ':')).encode()).hexdigest()
    except (OSError, ValueError):
        return hashlib.sha256(b'unsafe-or-unavailable').hexdigest()


def candidate(expected, actual, *, version=1):
    source, rejected, structural = config.parse(expected, version=version)
    if rejected or structural:
        raise Refused('source_excluded')
    existing, rejected, structural = config.parse(actual)
    if rejected or structural:
        raise Refused('unsupported_target')
    aliases = {host.lower(): host for host in existing}
    missing = {}
    for host, entries in source.items():
        if host.lower() in aliases and aliases[host.lower()] != host:
            raise Refused('ambiguous_alias')
        if host in existing:
            if config.profile_values(entries) != config.profile_values(existing[host]):
                raise Refused('target_conflict')
        else:
            missing[host] = entries
    if not missing:
        return actual, 0
    # The original bytes are an immutable prefix. Only canonical missing blocks
    # are appended, with an explicit line boundary even after a final comment.
    merged = actual + (b'' if not actual or actual.endswith(b'\n') else b'\n') + config.payload(missing)
    checked, rejected, structural = config.parse(merged)
    if (rejected or structural or checked != (existing | missing) or
            list(checked) != [*existing, *missing] or not merged.startswith(actual)):
        raise Refused('candidate_invalid')
    return merged, len(missing)


def plan(expected, home, *, version=1):
    with target(home) as (directory, recheck, _):
        if directory is None:
            return 'create', 0
        if config.pending_publication(directory):
            raise Refused('publication_uncertain')
        try:
            actual, _, _ = observed_file(directory)
        except FileNotFoundError:
            recheck()
            return 'create', 0
        _, count = candidate(expected, actual, version=version)
        if count:
            swap_supported(directory)
        recheck()
        return ('merge' if count else 'noop'), count


def write_private(directory, name, raw, source_directory, old, metadata):
    fd = os.open(name, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory)
    with os.fdopen(fd, 'wb') as stream:
        os.fchown(stream.fileno(), -1, old.st_gid)
        os.fchmod(stream.fileno(), 0o600)
        stream.write(raw)
        stream.flush()
        source = os.open('config', os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=source_directory)
        try:
            if file_evidence(os.fstat(source)) != file_evidence(old):
                raise Refused('target_changed')
            if native().fcopyfile(source, stream.fileno(), None, 4):  # COPYFILE_XATTR only
                raise Refused('unsupported_metadata')
            if (attributes(stream.fileno()) != metadata or attributes(source) != metadata or
                    file_evidence(os.fstat(source)) != file_evidence(old)):
                raise Refused('target_changed')
        finally:
            os.close(source)
        os.fsync(stream.fileno())
        fcntl.fcntl(stream.fileno(), 51)  # Darwin F_FULLFSYNC, no durability fallback.


def publish(expected, home, expected_evidence, *, version=1, validate=None):
    if not expected_evidence or evidence(home) != expected_evidence:
        raise Refused('target_changed')
    with target(home) as (directory, recheck, _):
        if directory is None or config.pending_publication(directory):
            raise Refused('target_changed')
        original, old, metadata = observed_file(directory)
        merged, count = candidate(expected, original, version=version)
        if not count:
            recheck()
            return False
        swap_supported(directory)
        if evidence(home) != expected_evidence:
            raise Refused('target_changed')
        token = uuid.uuid4().hex
        pending = '.macseed-ssh-pending-' + token
        saved = '.macseed-ssh-predecessor-' + token
        # Once created, retain every artifact on failure or interruption. There
        # is deliberately no cleanup/rollback that could destroy a raced file.
        recovery = None
        created = False
        try:
            os.mkdir(pending, 0o700, dir_fd=directory)
            created = True
            recovery = os.open(pending, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            recovery_identity = identity(os.fstat(recovery))
            write_private(recovery, 'observed', original, directory, old, metadata)
            write_private(recovery, 'swap', merged, directory, old, metadata)
            _, staged, _ = observed_file(recovery, 'swap')
            os.fsync(recovery)
            os.fsync(directory)
            recheck()
            latest, current, current_metadata = observed_file(directory)
            if latest != original or file_evidence(current) != file_evidence(old) or current_metadata != metadata:
                raise Refused('target_changed')
            if identity(os.stat(pending, dir_fd=directory, follow_symlinks=False)) != recovery_identity:
                raise Refused('target_changed')
            # This is an atomic exchange, not inode compare-and-swap. Verify the
            # actual displaced predecessor and retain it even on a last-gap race.
            if validate is not None:
                validate()
            rename(recovery, 'swap', directory, 'config', 2)
            published, new, new_metadata = observed_file(directory)
            displaced, predecessor, predecessor_metadata = observed_file(recovery, 'swap')
            if (published != merged or identity(new) != identity(staged) or
                    displaced != original or identity(predecessor) != identity(old) or
                    predecessor.st_mtime_ns != old.st_mtime_ns or
                    new_metadata != metadata or predecessor_metadata != metadata):
                raise Refused('publication_uncertain')
            recheck()
            if identity(os.stat(pending, dir_fd=directory, follow_symlinks=False)) != recovery_identity:
                raise Refused('publication_uncertain')
            if validate is not None:
                validate()
            os.fsync(recovery)
            os.fsync(directory)
            # A completed directory is a retained backup, not a re-entry block.
            # A crash before this marker may require manual review of a valid merge.
            # Completion is the last decision: do not reject after clearing pending.
            rename(directory, pending, directory, saved, 4)
            return True
        except BaseException as exc:
            if created:
                # Retained recovery artifacts are themselves a real mutation;
                # this does not assert that the config exchange completed.
                raise PublicationUncertain(True) from exc
            raise
        finally:
            if recovery is not None:
                os.close(recovery)


def main():
    command, *args = sys.argv[1:]
    try:
        if command == 'evidence' and len(args) == 1:
            print(evidence(args[0]))
        elif command == 'plan' and len(args) == 2:
            before = evidence(args[1])
            decision = plan(config.read_file(args[0]), args[1])
            if evidence(args[1]) != before:
                raise Refused('target_changed')
            print(*decision, before)
        elif command == 'publish' and len(args) == 3:
            print('published' if publish(config.read_file(args[0]), args[1], args[2]) else 'noop')
        else:
            return 2
        return 0
    except PublicationUncertain as exc:
        print('publication_uncertain', int(exc.changed))
        return 2
    except (OSError, ValueError):
        print('refused')
        return 1


if __name__ == '__main__':
    sys.exit(main())
