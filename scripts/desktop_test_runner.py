"""Bound native test execution independently of MainActor and the GUI event loop."""
import argparse
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / 'modules/core/application-interface'))
from item_execution import ProcessTree, process_table


class Cancelled(Exception):
    def __init__(self, code):
        self.code = code


def sample_owned(tree):
    """Emit only source line numbers and fixed framework markers, never raw stacks."""
    if sys.platform != 'darwin' or tree.root not in tree.scan():
        return dict(sample='unavailable')
    try:
        with tempfile.TemporaryDirectory(prefix='macseed-desktop-sample-') as directory:
            path = Path(directory) / 'sample.txt'
            subprocess.run(['/usr/bin/sample', str(tree.root), '1', '-file', str(path)],
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=5, check=True)
            raw = path.read_text(errors='replace')
        lines = sorted({int(line) for line in re.findall(r'\bPresentationTests\.swift:(\d+)\b', raw)})
        markers = [name for name in ('CFRunLoopRun', 'sendEvent:', 'trackMouse:',
                                    'waitUntilExit', '__DISPATCH_WAIT_FOR_QUEUE__',
                                    'CGSWindow', 'NSApplicationMain') if name in raw]
        return dict(sample='captured', presentation_lines=lines[:40], framework_markers=markers)
    except (OSError, ValueError, subprocess.SubprocessError):
        return dict(sample='unavailable')


def run(command, timeout):
    if not command or not math.isfinite(timeout) or timeout <= 0:
        raise ValueError('invalid native test command/deadline')
    started = time.monotonic()
    child = tree = None
    code, reason, cleanup = 2, 'observation_error', 'not-launched'
    def cancel(sig, frame):
        raise Cancelled(130 if sig == signal.SIGINT else 143)
    handlers = {sig: signal.signal(sig, cancel) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        process_table()  # Refuse launch if process ownership cannot be observed.
        read_fd, write_fd = os.pipe()
        gate = ('import os,sys; fd=int(sys.argv[1]); token=os.read(fd,1); os.close(fd); '
                'token == b"1" or sys.exit(2); os.execvp(sys.argv[2],sys.argv[2:])')
        try:
            child = subprocess.Popen([sys.executable, '-B', '-c', gate, str(read_fd), *command],
                                     pass_fds=(read_fd,), stdin=subprocess.DEVNULL,
                                     start_new_session=True)
            tree = ProcessTree(child.pid)
            os.write(write_fd, b'1')
        finally:
            os.close(read_fd)
            os.close(write_fd)
        deadline = started + timeout
        announced = started
        while child.poll() is None:
            tree.scan()
            now = time.monotonic()
            if now >= deadline:
                code, reason = 124, 'deadline'
                print('Desktop diagnostic: ' + json.dumps(sample_owned(tree), sort_keys=True), flush=True)
                break
            if now - announced >= 60:
                print(f'RUNNING: native test {now - started:.1f}s; deadline {timeout:g}s', flush=True)
                announced = now
            time.sleep(.25)
        else:
            code = child.returncode if child.returncode >= 0 else 128 - child.returncode
            reason = 'completed' if code == 0 else 'test_failed'
    except Cancelled as exc:
        code, reason = exc.code, 'cancelled'
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
        code, reason = 2, 'observation_error'
    finally:
        for sig in handlers:
            signal.signal(sig, signal.SIG_IGN)
        try:
            if child is not None:
                tree = tree or ProcessTree(child.pid)
                if tree.scan():
                    if reason in ('completed', 'test_failed'):
                        code, reason = 2, 'surviving_processes'
                    if not tree.stop():
                        raise RuntimeError('cleanup unconfirmed')
                child.wait(timeout=3)
                cleanup = 'confirmed'
        except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
            code, reason, cleanup = 2, 'unconfirmed_cleanup', 'unconfirmed'
        finally:
            for sig, handler in handlers.items():
                signal.signal(sig, handler)
    result = dict(status='PASS' if code == 0 else 'ERROR', code=code, reason=reason,
                  cleanup=cleanup, seconds=round(time.monotonic() - started, 3))
    print('Desktop supervision: ' + json.dumps(result, sort_keys=True), flush=True)
    return code


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--timeout', type=float, required=True)
    parser.add_argument('command', nargs=argparse.REMAINDER)
    arguments = parser.parse_args()
    if not arguments.command or not math.isfinite(arguments.timeout) or arguments.timeout <= 0:
        parser.error('a command and positive finite timeout are required')
    sys.exit(run(arguments.command, arguments.timeout))
