"""Private Homebrew launch/Stop lock; never signals an installer."""
import fcntl
import json
import os
from pathlib import Path
import select
import stat
import sys
import threading

STOPPED = 132
KEY = 'MACSEED_HOMEBREW_STOP'

class StopAccepted(Exception):
    pass

class State:
    def __init__(self, path):
        self.path = Path(path)
    def locked(self, action):
        fd = os.open(self.path, os.O_RDWR | os.O_NOFOLLOW)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
                raise OSError('unsafe Homebrew control state')
            fcntl.flock(fd, fcntl.LOCK_EX)
            raw = os.read(fd, 4096)
            data = json.loads(raw)
            result = action(data)
            encoded = json.dumps(data).encode()
            if encoded != raw:
                os.lseek(fd, 0, 0); os.write(fd, encoded); os.ftruncate(fd, len(encoded))
            return result
        finally:
            os.close(fd)
    def request(self):
        def apply(data):
            if data['stop']:
                return True
            if data['scope'] != 'homebrew' and data['scope'] != 'idle':
                return False
            data['stop'] = True
            return True
        return self.locked(apply)
    def boundary(self, scope):
        def apply(data):
            if data['stop']:
                raise StopAccepted()
            data['scope'] = scope
        self.locked(apply)
    def launch(self, command, popen):
        def apply(data):
            if data['stop']:
                raise StopAccepted()
            # Popen is inside the same lock used to accept Stop. Qualification
            # and post-checks remain with their existing domain owners.
            if data['scope'] != 'homebrew':
                raise OSError('native launch outside Homebrew scope')
            return popen(command)
        return self.locked(apply)
    def stopped(self):
        return self.locked(lambda data: data['stop'])


def stopped():
    path = os.environ.get(KEY)
    return bool(path and State(path).stopped())


class Controller:
    def __init__(self, directory, fd):
        self.state = State(Path(directory) / 'homebrew-stop.json')
        descriptor = os.open(self.state.path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(descriptor, 'w') as stream:
            json.dump({'stop': False, 'scope': 'idle'}, stream)
        self.fd = fd
        self.events = []
        self.lock = threading.Lock()
        self.closed = threading.Event()
        self.lost = False
        self.accepted = False
        self.thread = threading.Thread(target=self.read, daemon=True)
        self.thread.start()
    def read(self):
        while not self.closed.is_set():
            try:
                ready, _, _ = select.select([self.fd], [], [], .1)
                if not ready:
                    continue
                command = os.read(self.fd, 1)
            except (OSError, ValueError):
                self.lost = True
                try:
                    self.state.locked(lambda data: data.update(stop=True))
                except (OSError, ValueError):
                    pass
                return
            try:
                if command != b'S':
                    # Broken control freezes admission, but is not accepted Stop.
                    self.lost = True
                    self.state.locked(lambda data: data.update(stop=True))
                    return
                accepted = self.state.request()
                self.accepted |= accepted
                with self.lock:
                    self.events.append('graceful_stop_accepted' if accepted else 'graceful_stop_unavailable')
            except (OSError, ValueError):
                self.lost = True
                return
    def drain(self, emit):
        with self.lock:
            events, self.events = self.events, []
        for state in events:
            emit('execution_event', {'domain': 'orchestration', 'item_id': 'stop', 'state': state})
    def close(self):
        self.closed.set(); self.thread.join(timeout=1)


if __name__ == '__main__':
    path = os.environ.get(KEY)
    if not path:
        sys.exit(0)
    try:
        state = State(path)
        if len(sys.argv) > 1:
            state.boundary('homebrew' if sys.argv[1] in ('install_brew_packages', 'install_brew_casks') else 'unsupported')
        elif state.stopped():
            raise StopAccepted()
    except StopAccepted:
        sys.exit(STOPPED)
    except (OSError, ValueError):
        sys.exit(133)
