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

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'core/application-interface'))
from item_execution import ItemExecutor, CANCELLED, STALLED, OBSERVATION_FAILED, ProcessTree

UNKNOWN = 129
DENIED = 131


def state_directory():
    return Path.home().resolve() / 'Library/Application Support/Macseed/Homebrew'


def pending():
    try:
        (state_directory() / 'active.json').lstat()
        return True
    except FileNotFoundError:
        return False
    except OSError:
        return True  # Inaccessible state is not proof of quiescence.


def private_directory(directory):
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    home = Path.home().resolve()
    for component in (directory, *directory.parents):
        if component == home:
            break
        info = component.lstat()
        if stat.S_ISLNK(info.st_mode):
            raise PermissionError('unsafe state directory')
        if component == directory and (info.st_uid != os.getuid() or info.st_mode & 0o077):
            raise PermissionError('unsafe state directory')


def journal(directory, value):
    temporary = directory / 'active.tmp'
    descriptor = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(descriptor, 'w') as stream:
            json.dump(value, stream)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(directory / 'active.json')
    finally:
        temporary.unlink(missing_ok=True)


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
