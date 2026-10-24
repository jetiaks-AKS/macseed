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
from reporting import observation_failure

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
    if Path(command[0]).name == 'brew':
        # Ruby-backed reads can detach an analytics curl after successful exit.
        # Keep reads self-contained without weakening owned-worker observation or
        # changing the user's persistent Homebrew preferences.
        env = dict(os.environ if env is None else env, HOMEBREW_NO_ANALYTICS='1',
                   HOMEBREW_NO_AUTO_UPDATE='1')
    if Path(command[0]).name == 'git':
        env = dict(os.environ if env is None else env, GIT_OPTIONAL_LOCKS='0',
                   GIT_NO_LAZY_FETCH='1', GIT_TERMINAL_PROMPT='0')
    process = tree = None
    started = time.monotonic()
    layer = 'external_observation_process'
    data = bytearray()
    reason, confirmed = None, True
    try:
        process_table()
        layer = 'external_observation_launch'
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.STDOUT if merge_stderr else subprocess.DEVNULL, start_new_session=True,
                                   env=env, cwd=cwd)
        confirmed = False
        layer = 'external_observation_process'
        tree = ProcessTree(process.pid)
        layer = 'external_observation_failed'
        os.set_blocking(process.stdout.fileno(), False)
        now = time.monotonic()
        deadline, scan_at, eof = now + timeout, now + .25, False
        root_exited = False
        while True:
            if progress is not None:
                progress()
            if time.monotonic() >= deadline:
                reason = 'external_observation_deadline'
                break
            if time.monotonic() >= scan_at:
                tree.scan()
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
                # Scan once on exit and again at EOF if it arrives later. The
                # constructor already scanned; do not repeat it immediately.
                if (not root_exited or eof) and tree.scan():
                    reason = 'external_observation_worker'
                    break
                root_exited = True
                if eof:
                    # Reaped root, EOF and no owned workers establish completion.
                    # Repeated stop scans add no evidence on this success path.
                    confirmed = True
                    break
    except ERRORS:
        reason = reason or layer
    finally:
        if process is not None:
            try:
                if tree is not None and not confirmed:
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
    # A wrapper's warning/absence exit can be valid by its caller's contract.
    # Homebrew read commands, however, require native success.
    failure = ('external_observation_unquiescent' if not confirmed else reason
               or ('external_observation_native' if process.returncode and Path(command[0]).name == 'brew' else None))
    if failure:
        observation_failure(command, failure, time.monotonic() - started,
                            process.returncode if process is not None else None, confirmed)
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
