"""Private, one-shot importer evidence. Never accepts key material."""
import datetime
import os
from pathlib import Path
import re
import signal
import stat
import subprocess
import sys
import tempfile

LIMIT = 16384
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\Z', re.ASCII)
ATTEMPT = re.compile(r'[A-Za-z0-9_-]{1,100}\Z', re.ASCII)
REASONS = {'match', 'not_observed', 'target_conflict', 'different_pair',
           'unsafe_target', 'cancelled', 'decrypt_failed', 'input_invalid',
           'post_validation_failed', 'operation_failed'}


def now():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


class Evidence:
    def __init__(self, endpoint=None, attempt=None):
        self.endpoint, self.attempt = endpoint, attempt
        self.identities = {}
        self.outcome, self.reason = 'failure', 'input_invalid'
        self.phase = 'scope'

    def selected(self, names):
        self.identities = {name: ['unverified', '-', 'not_observed', 'observation'] for name in names}
        self.phase = 'observation'

    def matched(self, outcome):
        self.outcome, self.reason = outcome, 'match'
        for name in self.identities:
            self.identities[name] = ['verified', now(), 'match', self.phase]

    def different(self, name):
        self.identities[name] = ['mismatch', now(), 'different_pair', 'observation']

    def failed(self, outcome, reason):
        self.outcome, self.reason = outcome, reason
        # Only a preserved, positively observed different pair survives failure.
        for name, row in self.identities.items():
            if reason == 'target_conflict' and row[0] == 'mismatch' and self.phase == 'observation':
                continue
            self.identities[name] = ['unverified', '-', reason if reason in REASONS else 'not_observed', self.phase]

    def publish(self):
        if self.endpoint is None:
            return
        selection = 'validated' if self.identities else 'unresolved'
        rows = [['E', '1', self.attempt, selection, str(len(self.identities)), self.outcome, self.reason]]
        rows += [['I', name] + row for name, row in self.identities.items()]
        rows += [['END']]
        raw = ('\n'.join('\t'.join(row) for row in rows) + '\n').encode('ascii')
        # Parent owns this dedicated random directory. Pin it for publication.
        directory = os.path.dirname(self.endpoint)
        fd = open_directory(directory)
        try:
            temporary = os.open('pending', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            with os.fdopen(temporary, 'wb') as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(raw)
                stream.flush()
            os.rename('pending', os.path.basename(self.endpoint), src_dir_fd=fd, dst_dir_fd=fd)
        finally:
            os.close(fd)


def open_directory(path):
    if os.path.realpath(path) != path:
        raise ValueError('directory')
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    s = os.fstat(fd)
    visible = os.lstat(path)
    if (not stat.S_ISDIR(s.st_mode) or s.st_uid != os.getuid() or
            stat.S_IMODE(s.st_mode) != 0o700 or (s.st_dev, s.st_ino) != (visible.st_dev, visible.st_ino)):
        os.close(fd)
        raise ValueError('directory')
    return fd


def validate(raw, attempt, status):
    if len(raw) > LIMIT or not raw.endswith(b'\n') or b'\r' in raw or b'\x00' in raw:
        raise ValueError('framing')
    rows = [line.split('\t') for line in raw.decode('ascii').splitlines()]
    if len(rows) < 2 or rows[-1] != ['END'] or len(rows[0]) != 7:
        raise ValueError('framing')
    tag, version, binding, selection, count, outcome, reason = rows[0]
    if tag != 'E' or version != '1' or not ATTEMPT.fullmatch(binding) or binding != attempt:
        raise ValueError('binding')
    if selection not in ('validated', 'unresolved') or reason not in REASONS:
        raise ValueError('enum')
    expected = {'success': (0,), 'noop': (0,), 'skipped': (1,), 'cancelled': (1, 130), 'failure': (1, 2)}
    if outcome not in expected or status not in expected[outcome]:
        raise ValueError('exit')
    if not count.isdigit() or count != str(len(rows) - 2) or not 0 <= int(count) <= 32:
        raise ValueError('count')
    if (selection == 'validated') != (int(count) > 0):
        raise ValueError('selection')
    if (outcome in ('success', 'noop')) != (reason == 'match'):
        raise ValueError('outcome')
    if outcome in ('success', 'noop') and selection != 'validated':
        raise ValueError('selection')
    if outcome == 'cancelled' and reason != 'cancelled' or outcome == 'skipped' and reason != 'target_conflict':
        raise ValueError('reason')
    names = set()
    for row in rows[1:-1]:
        if len(row) != 6:
            raise ValueError('identity')
        tag, name, conformity, observed, why, phase = row
        if tag != 'I' or not NAME.fullmatch(name) or name.endswith('.pub') or name in names:
            raise ValueError('name')
        names.add(name)
        if conformity not in ('verified', 'mismatch', 'unverified') or why not in REASONS or phase not in ('scope', 'observation', 'apply', 'post_apply'):
            raise ValueError('enum')
        if observed != '-':
            parsed = datetime.datetime.strptime(observed, '%Y-%m-%dT%H:%M:%SZ')
            if parsed.strftime('%Y-%m-%dT%H:%M:%SZ') != observed:
                raise ValueError('time')
        if conformity != 'unverified' and observed == '-':
            raise ValueError('time')
        if (conformity == 'verified') != (outcome in ('success', 'noop')):
            raise ValueError('conformity')
        if conformity == 'verified' and why != 'match':
            raise ValueError('match')
        if conformity == 'mismatch' and (outcome != 'skipped' or why != 'different_pair' or phase != 'observation'):
            raise ValueError('mismatch')
    return raw


def read_evidence(endpoint, attempt, status):
    parent = os.path.dirname(endpoint)
    directory = open_directory(parent)
    try:
        fd = os.open(os.path.basename(endpoint), os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory)
        with os.fdopen(fd, 'rb') as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_uid != os.getuid() or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) != 0o600 or before.st_size > LIMIT:
                raise ValueError('file')
            raw = stream.read(LIMIT + 1)
            after = os.fstat(stream.fileno())
            visible = os.stat(os.path.basename(endpoint), dir_fd=directory, follow_symlinks=False)
            def signature(s):
                return (s.st_dev, s.st_ino, s.st_mode, s.st_uid, s.st_nlink, s.st_size, s.st_mtime_ns, s.st_ctime_ns)
            parent_now = os.lstat(parent)
            pinned = os.fstat(directory)
            if (signature(before) != signature(after) or signature(after) != signature(visible) or
                    (pinned.st_dev, pinned.st_ino) != (parent_now.st_dev, parent_now.st_ino) or
                    parent_now.st_uid != os.getuid() or stat.S_IMODE(parent_now.st_mode) != 0o700):
                raise ValueError('substitution')
        return validate(raw, attempt, status)
    finally:
        os.close(directory)


def supervise(cli, package, attempt):
    # fd 9 is a preopened anonymous regular file, not stdout or an env payload.
    child = None
    def interrupt(signum, frame):
        if child is not None and child.poll() is None:
            child.send_signal(signum)
    signal.signal(signal.SIGINT, interrupt)
    signal.signal(signal.SIGTERM, interrupt)
    temporary = None
    status, raw = 2, b''
    try:
        try:
            temporary = tempfile.TemporaryDirectory(prefix='macseed-evidence-', dir='/private/tmp')
            directory = temporary.name
            os.chmod(directory, 0o700)
            endpoint = str(Path(directory) / 'terminal')
        except OSError:
            endpoint = None
        command = [cli, 'import', '--input', package]
        if endpoint is not None:
            command += ['--internal-evidence', endpoint, '--attempt', attempt]
        child = subprocess.Popen(command)
        status = child.wait()
        if status < 0:
            status = 128 - status
        if endpoint is not None:
            try:
                raw = read_evidence(endpoint, attempt, status)
            except (OSError, ValueError, UnicodeError):
                raw = b''
    finally:
        if temporary is not None:
            try:
                temporary.cleanup()
            except OSError:
                raw = b''  # Cleanup failure invalidates reporting, not the import.
    # Only complete validated records cross into Bash. Cleanup precedes delivery.
    try:
        with os.fdopen(os.dup(9), 'wb') as channel:
            channel.write(raw)
    except OSError:
        pass  # Reporting failure must not replace the import result.
    return status


if __name__ == '__main__':
    sys.exit(supervise(*sys.argv[1:]))
