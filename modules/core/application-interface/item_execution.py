"""Application-only owned item processes and observable-progress watchdog.

No tool output is interpreted as progress. Probes observe owned process identities,
regular-file growth/read offsets, and CPU time of compiler/linker processes (never curl/Ruby).
"""
import os
from pathlib import Path
import signal
import subprocess
import time

STALL_SECONDS = 180
STALLED, BLOCKED, UNOBSERVABLE, OBSERVATION_FAILED, CANCELLED = 124, 125, 126, 127, 130


class StallTimer:
    def __init__(self, now, interval=STALL_SECONDS):
        self.last_progress = now
        self.interval = interval

    def observe(self, now, progress):
        if progress:
            self.last_progress = now
        return now - self.last_progress >= self.interval


def process_table():
    # Kernel process fields only; never arguments, environment or tool diagnostics.
    result = subprocess.run(['/bin/ps', '-axo', 'pid=,ppid=,lstart=,time=,comm='],
                            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2, check=True)
    rows = {}
    for line in result.stdout.decode(errors='replace').splitlines():
        fields = line.split(None, 8)
        if len(fields) != 9:
            continue
        pid, parent = map(int, fields[:2])
        rows[pid] = (parent, ' '.join(fields[2:7]), fields[7], fields[8])
    return rows


class ProcessTree:
    """Remember birth identities before descendants create groups or are reparented."""
    def __init__(self, pid, initialize=True):
        self.root = pid
        self.known = {}
        self.initialized = False
        try:
            self.session = pid if os.getsid(pid) == pid else None
        except ProcessLookupError:
            self.session = None
        if initialize:
            self.scan()

    def scan(self):
        table = process_table()
        owned = {pid for pid, birth in self.known.items() if pid in table and table[pid][1] == birth}
        if not self.initialized and self.root in table:
            owned.add(self.root)
        self.initialized = True
        # Homebrew creates process groups within the item's private session. This
        # also finds those children if a short-lived parent has already exited.
        if self.session is not None and not (self.root in table and self.root in self.known and table[self.root][1] != self.known[self.root]):
            for pid in table:
                try:
                    if os.getsid(pid) == self.session:
                        owned.add(pid)
                except (ProcessLookupError, PermissionError):
                    pass
        while True:
            children = {pid for pid, row in table.items() if row[0] in owned}
            if children <= owned:
                break
            owned |= children
        for pid in owned:
            self.known[pid] = table[pid][1]
        return {pid: table[pid] for pid in owned}

    def stop(self):
        # Keep rediscovering while parents are alive; signal leaves before parents.
        deadline = time.monotonic() + 1
        while True:
            rows = self.scan()
            if not rows:
                return True
            for pid in sorted(rows, key=lambda pid: pid == self.root):
                try:
                    os.kill(pid, signal.SIGTERM if time.monotonic() < deadline else signal.SIGKILL)
                except ProcessLookupError:
                    pass
                except PermissionError:
                    pass  # Privileged descendants remain explicitly unquiescent.
            if time.monotonic() >= deadline:
                break
            time.sleep(.05)
        # A TERM-ignoring, reparented child still has its remembered birth identity.
        for pid in self.scan():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except PermissionError:
                pass
        return not bool(self.scan())


class ProgressProbe:
    COMPILERS = {'clang', 'clang++', 'cc', 'cc1', 'cc1plus', 'gcc', 'g++', 'ld', 'ld64',
                 'as', 'rustc', 'swift-frontend'}

    def __init__(self):
        self.files = {}
        self.offsets = {}
        self.cpu = {}

    @staticmethod
    def cpu_seconds(value):
        parts = value.split(':')
        return float(parts[-1]) + 60 * int(parts[-2]) + (3600 * int(parts[-3]) if len(parts) == 3 else 0)

    def sample(self, rows):
        progress = False
        for pid, row in rows.items():
            name = Path(row[3]).name
            versioned = name.rsplit('-', 1)
            if name not in self.COMPILERS and not (len(versioned) == 2 and versioned[1].isdigit() and versioned[0] in self.COMPILERS):
                continue
            key = (pid, row[1])
            cpu = self.cpu_seconds(row[2])
            if cpu > self.cpu.get(key, 0):
                progress = True
            self.cpu[key] = cpu
        if not rows:
            return progress
        result = subprocess.run(['/usr/sbin/lsof', '-nP', '-o', '-F0pftasnioD', '-p', ','.join(map(str, rows))],
                                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=2)
        if result.returncode not in (0, 1):
            raise RuntimeError('progress observation unavailable')
        record = {}
        def consume():
            nonlocal progress
            if record.get('t') != 'REG' or not record.get('f', '').isdigit() or record.get('f') in ('0', '1', '2'):
                return
            name = record.get('n', '')
            if name.endswith(('.log', '.lock')) or '/Logs/' in name or '/logs/' in name:
                return
            size = int(record.get('s', '0'))
            key = (record.get('D'), record.get('i'), name)
            if record.get('a') in ('w', 'u'):
                if size > self.files.get(key, 0):
                    progress = True
                self.files[key] = max(size, self.files.get(key, 0))
            offset = record.get('o', '')
            if record.get('a') in ('r', 'u') and offset.startswith(('0t', '0x')):
                position = int(offset[2:], 10 if offset.startswith('0t') else 16)
                if position > self.offsets.get(key, 0):
                    progress = True
                self.offsets[key] = max(position, self.offsets.get(key, 0))
        for field in result.stdout.decode(errors='replace').split('\0'):
            field = field.lstrip('\n')
            if not field:
                continue
            if field[0] in ('p', 'f'):
                consume(); record = {}
            record[field[0]] = field[1:]
        consume()
        return progress


class ItemExecutor:
    def __init__(self, interval=STALL_SECONDS, poll=.5):
        self.interval = interval
        self.poll = poll
        self.cancelled = False
        self.reason = None
        self.unquiescent = False

    def cancel(self, *_):
        self.cancelled = True

    def run(self, command, capture=False):
        if self.cancelled:
            self.reason = 'cancelled'
            return CANCELLED, b''
        # A bounded metadata response goes to a private file, never a pipe that can deadlock.
        import tempfile
        with tempfile.TemporaryFile() as output:
            process = subprocess.Popen(command, stdin=subprocess.DEVNULL,
                                       stdout=output if capture else subprocess.DEVNULL,
                                       stderr=subprocess.DEVNULL, start_new_session=True)
            tree = None
            try:
                tree = ProcessTree(process.pid)
                probe = ProgressProbe()
                timer = StallTimer(time.monotonic(), self.interval)
                while process.poll() is None:
                    if self.cancelled:
                        self.reason = 'cancelled'; tree.stop(); process.wait()
                        return CANCELLED, b''
                    progress = probe.sample(tree.scan())
                    if process.poll() is not None:
                        break
                    if timer.observe(time.monotonic(), progress):
                        self.reason = 'item_stalled_timeout'; tree.stop(); process.wait()
                        return STALLED, b''
                    time.sleep(self.poll)
                status = process.wait()
                if self.cancelled:
                    self.reason = 'cancelled'; return CANCELLED, b''
                output.seek(0)
                return status, output.read(1024 * 1024 + 1) if capture else b''
            except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                self.reason = 'progress_observation_failed'
                return OBSERVATION_FAILED, b''
            finally:
                if tree is not None:
                    self.unquiescent |= not tree.stop()
                else:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                process.wait()
