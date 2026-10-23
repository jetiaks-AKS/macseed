"""Bounded application reads, without installer lifecycle or persistent state."""
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time

sys.dont_write_bytecode = True
from item_execution import ProcessTree, process_table, pipe_eof

LOCAL_SECONDS = 30
INVENTORY_SECONDS = 120
PHASE_SECONDS = 900
MAX_OUTPUT = 8 * 1024 * 1024
ERRORS = (OSError, ValueError, RuntimeError, subprocess.SubprocessError)


class ObservationError(OSError):
    def __init__(self, reason, quiescent=True):
        self.reason, self.quiescent = reason, quiescent
        super().__init__(reason)


def retain_unknown():
    # Only an existing Execute context; a read never creates durable lifecycle
    # state or clears an earlier safety record. Parent reads fail before Apply.
    if not os.environ.get('MACSEED_ITEM_STATE_DIR'):
        return
    sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'apps/adapters'))
    from homebrew_lifecycle import marker_fd, journal, read_state
    descriptor = marker_fd()
    try:
        try:
            read_state(descriptor, 'external-tool-active.json')
        except FileNotFoundError:
            journal(None, {'tool': 'observer', 'state': 'unknown_consequences',
                           'cause': 'external_observation_unquiescent'}, descriptor,
                    name='external-tool-active.json')
    finally:
        os.close(descriptor)


def read(command, timeout=LOCAL_SECONDS, *, env=None, cwd=None, progress=None, merge_stderr=False):
    """Return only complete, quiescent output; root exit is not pipe completion."""
    if Path(command[0]).name == 'git':
        env = dict(os.environ if env is None else env, GIT_OPTIONAL_LOCKS='0',
                   GIT_NO_LAZY_FETCH='1', GIT_TERMINAL_PROMPT='0')
    process = tree = None
    data = bytearray()
    reason, confirmed = None, True
    try:
        process_table()
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL, start_new_session=True,
                                   env=env, cwd=cwd)
        confirmed = False
        tree = ProcessTree(process.pid)
        os.set_blocking(process.stdout.fileno(), False)
        deadline, scan_at, eof = time.monotonic() + timeout, 0, False
        while True:
            if progress is not None:
                progress()
            if time.monotonic() >= deadline:
                reason = 'external_observation_deadline'
                break
            if time.monotonic() >= scan_at:
                rows = tree.scan()
                scan_at = time.monotonic() + .25
            if not eof:
                ready, _, _ = select.select([process.stdout], [], [], .05)
                if ready:
                    chunk = os.read(process.stdout.fileno(), 65536)
                    data.extend(chunk)
                    eof = not chunk
                    if len(data) > MAX_OUTPUT:
                        reason = 'external_observation_limit'
                        break
            else:
                time.sleep(.05)
            if process.poll() is not None:
                if tree.scan():
                    reason = 'external_observation_worker'
                    break
                if eof:
                    break
        confirmed = tree.stop()
        process.wait(timeout=1)
    except ERRORS:
        reason = reason or 'external_observation_failed'
    finally:
        if process is not None:
            try:
                if tree is not None:
                    confirmed = tree.stop()
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.wait(timeout=1)
                confirmed = pipe_eof(process.stdout) and confirmed
            except ERRORS:
                confirmed = False
            process.stdout.close()
        if not confirmed:
            retain_unknown()
    if not confirmed:
        raise ObservationError('external_observation_unquiescent', False)
    if reason:
        raise ObservationError(reason)
    if progress is not None:
        progress()  # Collect the terminal Capture inventory rows before return.
    return subprocess.CompletedProcess(command, process.returncode, bytes(data))


def main():
    budgets = {'local': LOCAL_SECONDS, 'inventory': INVENTORY_SECONDS, 'local-diagnostic': LOCAL_SECONDS}
    if len(sys.argv) < 3 or sys.argv[1] not in budgets:
        return 2
    try:
        result = read(sys.argv[2:], budgets[sys.argv[1]], merge_stderr=sys.argv[1] == 'local-diagnostic')
    except ERRORS as exc:
        print(getattr(exc, 'reason', 'external_observation_failed'), file=sys.stderr)
        return 2
    sys.stdout.buffer.write(result.stdout)
    return result.returncode if 0 <= result.returncode < 128 else 2


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(130))
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))
    sys.exit(main())
