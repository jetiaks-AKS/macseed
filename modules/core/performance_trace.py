"""Private opt-in aggregate timings; never part of Protocol V1 or domain evidence."""
import atexit
from contextlib import contextmanager
from functools import wraps
import fcntl
import json
import os
import re
import select
import stat
import sys
import time

ENABLED = (os.environ.get('MACSEED_PERFORMANCE_TRACE') == '1'
           and '--capture' not in sys.argv and '--record' not in sys.argv
           and os.environ.get('MACSEED_APPLICATION_CAPTURE') != 'true'
           and os.environ.get('MACSEED_APPLICATION_COMPARE') != 'true')
DIRECTORY = os.environ.get('MACSEED_PERFORMANCE_TRACE_DIR', '')
SCOPE = os.environ.get('MACSEED_PERFORMANCE_SCOPE', 'core')
if SCOPE not in ('core', 'preview', 'requirements', 'publication', 'bootstrap', 'verification'):
    SCOPE = 'core'
TOTALS = {}
LABEL = re.compile(r'[a-z][a-z0-9_.]{0,79}\Z')


def add(label, elapsed):
    if not LABEL.fullmatch(label):
        return
    key = SCOPE + '.' + label
    row = TOTALS.setdefault(key, {'count': 0, 'seconds': 0.0, 'max_seconds': 0.0})
    row['count'] += 1
    row['seconds'] += elapsed
    row['max_seconds'] = max(row['max_seconds'], elapsed)


@contextmanager
def measure(label):
    if not ENABLED:
        yield
        return
    started = time.monotonic()
    try:
        yield
    finally:
        add(label, time.monotonic() - started)


def timed(label):
    def decorate(function):
        if not ENABLED:
            return function
        @wraps(function)
        def wrapped(*args, **kwargs):
            with measure(label):
                return function(*args, **kwargs)
        return wrapped
    return decorate


def flush():
    if not ENABLED or not DIRECTORY or not TOTALS:
        return
    try:
        # Open the directory itself without following a symlink. All names below
        # are fixed; neither arguments nor observed paths enter the trace.
        directory = os.open(DIRECTORY, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            info = os.fstat(directory)
            if info.st_uid != os.getuid() or stat.S_IMODE(info.st_mode) != 0o700:
                return
            descriptor = os.open('totals.json', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
                                 0o600, dir_fd=directory)
            with os.fdopen(descriptor, 'r+') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600:
                    return
                fcntl.flock(stream, fcntl.LOCK_EX)
                raw = stream.read(65537)
                data = json.loads(raw) if raw else {}
                if len(raw) > 65536 or not isinstance(data, dict):
                    return
                for key, row in data.items():
                    if (not LABEL.fullmatch(key) or not isinstance(row, dict)
                            or set(row) != {'count', 'seconds', 'max_seconds'}
                            or type(row['count']) is not int or row['count'] < 0
                            or any(type(row[field]) not in (int, float) or row[field] < 0
                                   for field in ('seconds', 'max_seconds'))):
                        return
                for key, row in TOTALS.items():
                    previous = data.setdefault(key, {'count': 0, 'seconds': 0.0, 'max_seconds': 0.0})
                    previous['count'] += row['count']
                    previous['seconds'] += row['seconds']
                    previous['max_seconds'] = max(previous['max_seconds'], row['max_seconds'])
                stream.seek(0)
                json.dump(data, stream, sort_keys=True)
                stream.truncate()
                TOTALS.clear()
        finally:
            os.close(directory)
    except (OSError, ValueError, TypeError, KeyError):
        # Diagnostics must never determine an operation result.
        pass


atexit.register(flush)


def collect(parent):
    """One helper per Bash process. ACKs bound scheduling error at each edge.

    No command strings, arguments or item identities are accepted. Nested spans
    are inclusive. Incomplete spans are omitted rather than declared complete.
    """
    active = {}
    while True:
        ready, _, _ = select.select([sys.stdin], [], [], 0.5)
        if not ready:
            flush()
            try:
                os.kill(parent, 0)
            except ProcessLookupError:
                return
            continue
        line = sys.stdin.readline()
        if not line:
            return
        fields = line.strip().split()
        now = time.monotonic()
        if len(fields) == 2 and LABEL.fullmatch(fields[1]):
            event, label = fields
            if event == 'finish':
                flush()
                # A failed diagnostic write must not retry at interpreter exit
                # after the shell has already received the finish ACK.
                TOTALS.clear()
                print('ok', flush=True)
                return
            if event == 'begin':
                active.setdefault(label, []).append(now)
            elif event == 'end' and active.get(label):
                add(label, now - active[label].pop())
        print('ok', flush=True)


if __name__ == '__main__':
    # Do not retain execution/report/verification descriptors in the helper.
    os.closerange(3, 256)
    collect(int(sys.argv[1]))
