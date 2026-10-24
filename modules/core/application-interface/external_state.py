"""Fail-closed Execute fence for unconfirmed external-process consequences.

No scheduler or recovery authority. Observers only read this fence. A mutating
Bootstrap owns write-ahead admission and may finalize only its own active record.
Unknown records are never automatically cleared.
"""
import fcntl
import os
from pathlib import Path
import sys
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'apps/adapters'))
from homebrew_lifecycle import state_directory_fd, read_state, journal, private_file

KEY = 'MACSEED_EXTERNAL_JOURNAL_FD'


class ExternalStateUnavailable(Exception):
    """No mutation may launch without durable, exclusively owned admission."""


def completed(value):
    return (set(value) == {'contract', 'tool', 'state', 'owner', 'quiescence_confirmed'} and
            type(value['contract']) is int and value['contract'] == 1 and
            value['tool'] == 'external_process' and value['state'] == 'quiescent' and
            value['quiescence_confirmed'] is True and isinstance(value['owner'], str) and
            len(value['owner']) == 32 and all(c in '0123456789abcdef' for c in value['owner']))


def inherited_owner(descriptor, value):
    raw = os.environ.get(KEY, '')
    if not raw.isascii() or not raw.isdigit() or int(raw) <= 2 or value.get('state') != 'active':
        return False
    try:
        info = os.fstat(int(raw))
        private_file(info)
        current = os.stat('lifecycle.lock', dir_fd=descriptor, follow_symlinks=False)
        return ((info.st_dev, info.st_ino) == (current.st_dev, current.st_ino) and
                os.pread(int(raw), 65, 0).decode('ascii') == value.get('owner'))
    except (OSError, ValueError, UnicodeError):
        return False


def directory(home=None):
    return (Path.home() if home is None else Path(home)).resolve() / 'Library/Application Support/Macseed/ExternalProcesses'


def pending():
    try:
        descriptor = state_directory_fd(directory())
        try:
            value = read_state(descriptor)
            return not completed(value) and not inherited_owner(descriptor, value)
        finally:
            os.close(descriptor)
    except FileNotFoundError:
        return False
    except (OSError, ValueError):
        return True


class Lifecycle:
    def __init__(self, home=None):
        self.home = home
        self.directory_fd = self.descriptor = None
        self.value = None

    def __enter__(self):
        try:
            self.directory_fd = state_directory_fd(directory(self.home), create=True, home=self.home)
            self.descriptor = os.open('lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                                      0o600, dir_fd=self.directory_fd)
            private_file(os.fstat(self.descriptor))
            fcntl.flock(self.descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                current = read_state(self.directory_fd)
            except FileNotFoundError:
                current = None
            if current is not None and not completed(current):
                raise ValueError('external lifecycle pending')
            self.value = dict(contract=1, tool='external_process', state='active', owner=uuid.uuid4().hex)
            os.ftruncate(self.descriptor, 0)
            os.write(self.descriptor, self.value['owner'].encode('ascii'))
            os.fsync(self.descriptor)
            journal(None, self.value, self.directory_fd)
            return self
        except BaseException as exc:
            self.__exit__(None, None, None)
            if isinstance(exc, (OSError, ValueError)):
                raise ExternalStateUnavailable() from exc
            raise

    def finish(self, confirmed):
        if read_state(self.directory_fd) != self.value:
            raise ValueError('external lifecycle owner changed')
        value = (dict(self.value, state='quiescent', quiescence_confirmed=True) if confirmed else
                 dict(self.value, state='unknown_consequences', cause='external_execution_unconfirmed'))
        journal(None, value, self.directory_fd)

    def __exit__(self, *_):
        for descriptor in (self.descriptor, self.directory_fd):
            if descriptor is not None:
                os.close(descriptor)
        self.descriptor = self.directory_fd = None


if __name__ == '__main__':
    sys.exit(0 if pending() else 1)
