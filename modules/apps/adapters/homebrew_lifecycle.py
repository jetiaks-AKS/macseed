"""Authorized native Homebrew lifecycle, under the managing user's identity.

No credential is received by Core. sudo communicates directly with a fixed
askpass helper. A durable private journal prevents overlap after interruption;
unknown privileged consequences are never cleared by payload Verification.
"""
import fcntl
import json
import os
from pathlib import Path
import signal
import stat
import subprocess
import sys
import uuid

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'core/application-interface'))
from item_execution import ItemExecutor, CANCELLED, STALLED, OBSERVATION_FAILED, ProcessTree

UNKNOWN = 129
DENIED = 131
JOURNAL_FD = 'MACSEED_HOMEBREW_JOURNAL_FD'


def state_directory():
    return Path.home().resolve() / 'Library/Application Support/Macseed/Homebrew'


def state_directory_fd(directory, create=False):
    """Walk beneath HOME without following links or writing through foreign parents."""
    home = Path.home()
    parts = directory.relative_to(home.resolve()).parts
    descriptor = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        for index, component in enumerate(('', *parts)):
            if component:
                made = False
                if create:
                    try:
                        os.mkdir(component, 0o700, dir_fd=descriptor)
                        made = True
                    except FileExistsError:
                        pass
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=descriptor)
                if made:
                    try:
                        os.fsync(child)
                        os.fsync(descriptor)
                    except BaseException:
                        os.close(child)
                        raise
                os.close(descriptor)
                descriptor = child
            info = os.fstat(descriptor)
            if info.st_uid != os.getuid() or info.st_mode & (0o077 if index == len(parts) else 0o022):
                raise PermissionError('unsafe state directory')
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def private_directory(directory):
    os.close(state_directory_fd(directory, create=True))


def private_file(info):
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        raise PermissionError('unsafe lifecycle state')


def read_state(directory_fd, name='active.json'):
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory_fd)
    try:
        private_file(os.fstat(descriptor))
        data = os.read(descriptor, 4097)
        if len(data) > 4096:
            raise ValueError('oversized lifecycle state')
        value = json.loads(data)
        if not isinstance(value, dict):
            raise ValueError('invalid lifecycle state')
        return value
    finally:
        os.close(descriptor)


def inherited_owner(directory_fd, value):
    raw = os.environ.get(JOURNAL_FD, '')
    if not raw.isascii() or not raw.isdigit() or int(raw) <= 2:
        return None
    descriptor = int(raw)
    try:
        info = os.fstat(descriptor)
        private_file(info)
        current = os.stat('lifecycle.lock', dir_fd=directory_fd, follow_symlinks=False)
        if (info.st_dev, info.st_ino) != (current.st_dev, current.st_ino):
            return None
        owner = os.pread(descriptor, 64, 0).decode('ascii')
        if len(owner) == 32 and value.get('owner') == owner:
            return descriptor
    except (OSError, ValueError, UnicodeError):
        pass
    return None


def quiescent(value):
    return (type(value.get('contract')) is int and value['contract'] == 1 and value.get('state') == 'quiescent' and
            value.get('quiescence_confirmed') is True and value.get('outcome') in ('success', 'failure') and
            value.get('kind') in ('formula', 'cask') and isinstance(value.get('owner'), str) and
            len(value['owner']) == 32 and all(c in '0123456789abcdef' for c in value['owner']))


def pending():
    try:
        descriptor = state_directory_fd(state_directory())
        try:
            value = read_state(descriptor)
            return not quiescent(value) and not (value.get('state') == 'active' and
                                                  inherited_owner(descriptor, value) is not None)
        finally:
            os.close(descriptor)
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return True  # Invalid/inaccessible state is not proof of quiescence.


def journal(directory, value, directory_fd=None, name='active.json'):
    """Atomic publication, confirmed by both file and directory fsync."""
    owned_directory = directory_fd is None
    if owned_directory:
        directory_fd = state_directory_fd(directory, create=True)
    identity = None
    temporary = 'active.tmp' if name == 'active.json' else name + '.tmp'
    try:
        descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=directory_fd)
        info = os.fstat(descriptor)
        identity = info.st_dev, info.st_ino
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        try:
            private_file(os.stat(name, dir_fd=directory_fd, follow_symlinks=False))
        except FileNotFoundError:
            pass
        os.replace(temporary, name, src_dir_fd=directory_fd, dst_dir_fd=directory_fd)
        os.fsync(directory_fd)
    finally:
        try:
            if identity is not None:
                current = os.stat(temporary, dir_fd=directory_fd, follow_symlinks=False)
                if (current.st_dev, current.st_ino) == identity:
                    os.unlink(temporary, dir_fd=directory_fd)
        except FileNotFoundError:
            pass
        finally:
            if owned_directory:
                os.close(directory_fd)


def marker_fd():
    directory = os.environ.get('MACSEED_ITEM_STATE_DIR')
    if not directory:
        raise ValueError('missing operation state directory')
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    info = os.fstat(descriptor)
    if info.st_uid != os.getuid() or info.st_mode & 0o077:
        os.close(descriptor)
        raise PermissionError('unsafe operation state')
    return descriptor


def operation_unknown():
    try:
        marker = marker_fd()
        try:
            value = read_state(marker, 'external-tool-active.json')
        finally:
            os.close(marker)
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return True
    try:
        descriptor = state_directory_fd(state_directory())
        try:
            record = read_state(descriptor)
            return (value.get('state') != 'active' or record.get('state') != 'active' or
                    value.get('owner') != record.get('owner') or
                    inherited_owner(descriptor, record) is None)
        finally:
            os.close(descriptor)
    except (OSError, ValueError, AttributeError):
        return True


class WriteAhead:
    """One existing Homebrew journal and lock, shared by nested Formula supervisors.

    Only the owning supervisor may publish confirmed quiescence. An inherited
    descriptor permits its children to use active state without clearing it.
    """
    def __init__(self, kind, token):
        self.kind, self.token = kind, token
        self.directory_fd = self.descriptor = None
        self.owner = False
        self.previous = os.environ.get(JOURNAL_FD)

    def __enter__(self):
        try:
            # Reject missing/unsafe operation state before creating durable state.
            marker = marker_fd()
            os.close(marker)
            self.directory_fd = state_directory_fd(state_directory(), create=True)
            try:
                self.value = read_state(self.directory_fd)
            except FileNotFoundError:
                self.value = {}
            self.descriptor = inherited_owner(self.directory_fd, self.value)
            if self.descriptor is not None and self.value.get('state') != 'active':
                raise OSError('inherited lifecycle is uncertain')
            if self.descriptor is None:
                self.descriptor = os.open('lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                                          0o600, dir_fd=self.directory_fd)
                self.owner = True
                private_file(os.fstat(self.descriptor))
                fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
                previous_owner = os.pread(self.descriptor, 65, 0)
                if previous_owner and (len(previous_owner) != 32 or any(c not in b'0123456789abcdef' for c in previous_owner)):
                    raise PermissionError('foreign lifecycle lock')
                # Re-read under the same lock used by native Cask lifecycles.
                try:
                    current = read_state(self.directory_fd)
                except FileNotFoundError:
                    current = None
                if current is not None and not quiescent(current):
                    raise OSError('lifecycle already pending')
                self.value = {'contract': 1, 'state': 'active', 'kind': self.kind,
                              'token': self.token, 'owner': uuid.uuid4().hex}
                os.ftruncate(self.descriptor, 0)
                os.write(self.descriptor, self.value['owner'].encode('ascii'))
                os.fsync(self.descriptor)
                journal(state_directory(), self.value, self.directory_fd)
                marker = marker_fd()
                try:
                    try:
                        read_state(marker, 'external-tool-active.json')
                    except FileNotFoundError:
                        pass
                    else:
                        raise OSError('operation already pending')
                    journal(None, {'tool': 'homebrew', 'state': 'active', 'owner': self.value['owner']},
                            marker, name='external-tool-active.json')
                finally:
                    os.close(marker)
            os.environ[JOURNAL_FD] = str(self.descriptor)
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def finish(self, status, confirmed):
        if not confirmed or status == UNKNOWN or operation_unknown():
            return quarantine(self.kind, self.token)
        if self.owner:
            current = read_state(self.directory_fd)
            if current != self.value:
                return quarantine(self.kind, self.token)
            # Only our own active marker may be removed. Unknown markers stay.
            marker = marker_fd()
            try:
                value = read_state(marker, 'external-tool-active.json')
                if value != {'tool': 'homebrew', 'state': 'active', 'owner': self.value['owner']}:
                    return quarantine(self.kind, self.token)
                journal(state_directory(), dict(self.value, state='quiescent', quiescence_confirmed=True,
                                                outcome='success' if status == 0 else 'failure'), self.directory_fd)
                if status == 0:
                    os.unlink('active.json', dir_fd=self.directory_fd)
                    os.fsync(self.directory_fd)
                os.unlink('external-tool-active.json', dir_fd=marker)
            finally:
                os.close(marker)
        return status

    def __exit__(self, *_):
        if self.previous is None:
            os.environ.pop(JOURNAL_FD, None)
        else:
            os.environ[JOURNAL_FD] = self.previous
        if self.owner and self.descriptor is not None:
            os.close(self.descriptor)
        if self.directory_fd is not None:
            os.close(self.directory_fd)
        self.descriptor = self.directory_fd = None


def quarantine(kind, token, cause=None):
    """Retain detected uncertainty across the current operation and fresh Restore.

    The durable active record remains blocking even if this update fails. Only
    our own record or a confirmed quiescent record may change; foreign or already
    uncertain lifecycle evidence is preserved.
    """
    if cause not in {'item_stalled_timeout', 'progress_observation_failed', 'cancelled', 'item_install_failed'}:
        cause = 'progress_observation_failed'
    value = {'contract': 1, 'tool': 'homebrew', 'state': 'unknown_consequences',
             'kind': kind, 'token': token, 'cause': cause}
    try:
        marker = marker_fd()
        try:
            try:
                current_marker = read_state(marker, 'external-tool-active.json')
            except FileNotFoundError:
                current_marker = None
            if current_marker is None or (current_marker.get('tool') == 'homebrew' and current_marker.get('state') == 'active'):
                journal(None, value, marker, name='external-tool-active.json')
        finally:
            os.close(marker)
        descriptor = state_directory_fd(state_directory(), create=True)
        lock = None
        try:
            try:
                current = read_state(descriptor)
            except FileNotFoundError:
                current = None
            inherited = inherited_owner(descriptor, current or {})
            if inherited is None:
                lock = os.open('lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                               0o600, dir_fd=descriptor)
                private_file(os.fstat(lock))
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                try:
                    current = read_state(descriptor)
                except FileNotFoundError:
                    current = None
            if inherited is not None or current is None or quiescent(current):
                journal(state_directory(), dict(current or {}, **value), descriptor)
        finally:
            if lock is not None:
                os.close(lock)
            os.close(descriptor)
    except (OSError, ValueError):
        # The write-ahead active record remains authoritative even when updating
        # its diagnostic state fails. No external launch preceded a failed begin.
        pass
    return UNKNOWN


def requalify(operation, token, qualification):
    from homebrew_cask import PublicObserver, classify
    observer = PublicObserver()
    prefix = Path(observer.read(['brew', '--prefix']).decode().strip())
    row = observer.cask(token)
    value = classify(row, prefix, observer, operation=operation)
    return value.get('qualification_id') == qualification and value.get('authorization_required') is True


def authorized_run(operation, token, qualification):
    if os.getuid() == 0 or os.geteuid() != os.getuid() or operation not in ('install', 'reinstall'):
        return DENIED
    directory = state_directory()
    private_directory(directory)
    descriptor = os.open(directory / 'lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        if os.fstat(lock.fileno()).st_uid != os.getuid() or os.fstat(lock.fileno()).st_mode & 0o077:
            return DENIED
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return UNKNOWN
        if pending():
            return UNKNOWN
        executor = ItemExecutor()
        signal.signal(signal.SIGTERM, executor.cancel)
        signal.signal(signal.SIGINT, executor.cancel)
        helper = Path(__file__).with_name('homebrew-askpass.sh').resolve()
        if not helper.is_file() or helper.stat().st_uid not in (0, os.getuid()) or helper.stat().st_mode & 0o022:
            return DENIED
        previous = dict(os.environ)
        try:
            # A secret never enters Python, JSON, environment values or a log.
            os.environ['SUDO_ASKPASS'] = str(helper)
            os.environ.pop('HOMEBREW_NO_SUDO', None)
            for name in ('SUDO_PROMPT', 'SUDO_USER', 'SUDO_UID', 'SUDO_GID'):
                os.environ.pop(name, None)
            status, _ = executor.run(['/usr/bin/sudo', '-A', '-v'])
            if status:
                return status if status in (CANCELLED, STALLED, OBSERVATION_FAILED) else DENIED
            # Authorization can take arbitrarily long. It is not permission to
            # execute a changed definition, cleanup scope or target state.
            if not requalify(operation, token, qualification):
                return 128
            if executor.cancelled:
                return CANCELLED
            # Journal before native mutation. If this supervisor is killed, the
            # next Prepare cannot mistake caller termination for quiescence.
            active = Path(os.environ['MACSEED_ITEM_STATE_DIR']) / 'external-tool-active.json'
            active_fd = os.open(active, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
            with os.fdopen(active_fd, 'w') as stream:
                json.dump({'tool': 'homebrew', 'state': 'active'}, stream)
            journal(directory, {'contract': 1, 'state': 'active', 'operation': operation,
                                'token': token, 'qualification_id': qualification})
            status, _ = executor.run(['brew', operation, '--cask', token])
            if status == 0 and not executor.unquiescent:
                (directory / 'active.json').unlink()
                active.unlink()
                return 0
            if status == 132:
                (directory / 'active.json').unlink()
                active.unlink()
                return status
            # Even a normal nonzero pkg exit can leave installer-service work.
            cause = {124: 'item_stalled_timeout', 127: 'progress_observation_failed',
                     130: 'cancelled'}.get(status, 'item_install_failed')
            active.write_text(json.dumps({'tool': 'homebrew', 'state': 'unknown_consequences', 'cause': cause}))
            journal(directory, {'contract': 1, 'state': 'unknown_consequences',
                                'operation': operation, 'token': token, 'qualification_id': qualification, 'cause': cause})
            return UNKNOWN
        finally:
            os.environ.clear()
            os.environ.update(previous)


def unprivileged_run(operation, token):
    """Share the native lifecycle lock with authorized operations. The existing
    owned watchdog/cancellation still owns user processes; no secret is involved.
    """
    if os.environ.get('HOMEBREW_NO_SUDO') != '1' or os.getuid() == 0:
        return DENIED
    directory = state_directory()
    private_directory(directory)
    descriptor = os.open(directory / 'lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, 'w') as lock:
        if os.fstat(lock.fileno()).st_uid != os.getuid() or os.fstat(lock.fileno()).st_mode & 0o077:
            return DENIED
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return UNKNOWN
        if pending():
            return UNKNOWN
        executor = ItemExecutor()
        signal.signal(signal.SIGTERM, executor.cancel)
        signal.signal(signal.SIGINT, executor.cancel)
        status, _ = executor.run(['brew', operation, '--cask', token])
        if executor.unquiescent:
            journal(directory, {'contract': 1, 'state': 'unknown_consequences', 'operation': operation, 'token': token})
            return UNKNOWN
        return status


def main():
    try:
        if len(sys.argv) == 3 and sys.argv[1] == '--formula':
            from homebrew_cask import NAME
            if not NAME.fullmatch(sys.argv[2]) or os.environ.get('MACSEED_APPLICATION_EXECUTION') != 'true':
                return DENIED
            if pending() or operation_unknown():
                return quarantine('formula', sys.argv[2])
            executor = ItemExecutor()
            signal.signal(signal.SIGTERM, executor.cancel)
            signal.signal(signal.SIGINT, executor.cancel)
            with WriteAhead('formula', sys.argv[2]) as lease:
                executor.inherited_fds = (lease.descriptor,)
                status, _ = executor.run(['brew', 'install', sys.argv[2]])
                if executor.unquiescent:
                    return quarantine('formula', sys.argv[2], executor.reason)
                return lease.finish(status, True)
        if sys.argv[1:] == ['--pending']:
            return 0 if pending() else 1
        from homebrew_cask import NAME
        operation, token, qualification, profile = sys.argv[1:]
        if not NAME.fullmatch(token) or len(qualification) != 64 or any(c not in '0123456789abcdef' for c in qualification):
            return DENIED
        if profile == 'unprivileged' and operation in ('install', 'reinstall'):
            return unprivileged_run(operation, token)
        if profile == 'authorized_native_lifecycle':
            return authorized_run(operation, token, qualification)
        return DENIED
    except (OSError, ValueError, subprocess.SubprocessError):
        return UNKNOWN if pending() else DENIED


if __name__ == '__main__':
    sys.exit(main())
