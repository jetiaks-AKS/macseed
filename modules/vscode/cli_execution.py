"""Bounded VS Code CLI waits; no output/CPU based stall inference.

Reuse Core's process identities and durable publication primitives. Interrupted
CLI work stays quarantined even when the observed tree has stopped: that is not
proof that a detached worker or delegated operation cannot still change state.
"""
import fcntl
import os
from pathlib import Path
import re
import select
import shutil
import signal
import subprocess
import sys
import time
import uuid

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent))
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'apps/adapters'))
from cli_diagnostic import Diagnostic
from homebrew_lifecycle import state_directory_fd, private_file, read_state, journal, marker_fd
from item_execution import ProcessTree, process_table

# Absolute policy budgets, not measurements of absent progress. Dependency packs
# and slow downloads get a full hour; inventory has no installation to wait for.
INVENTORY_SECONDS = 120
INSTALL_SECONDS = 3600
MAX_INVENTORY = 1024 * 1024
ERRORS = (OSError, ValueError, RuntimeError, subprocess.SubprocessError)


def restore_execution():
    # Set only by the explicit Bash Restore consumer, not the shared native CLI.
    return (os.environ.get('MACSEED_VSCODE_SUPERVISED_RESTORE') == 'true' and
            os.environ.get('MACSEED_APPLICATION_EXECUTION') == 'true' and
            os.environ.get('BUNDLE_RESTORE_ACTIVE') == 'true' and
            os.environ.get('BUNDLE_RESTORE_PREVIEW') != 'true' and
            os.environ.get('MACSEED_APPLICATION_SECURE_VERIFY_ONLY') != 'true')


def state_directory():
    return Path.home().resolve() / 'Library/Application Support/Macseed/VSCode'


def completed(value):
    return (type(value.get('contract')) is int and value['contract'] == 1 and
            value.get('tool') == 'vscode' and value.get('state') == 'quiescent' and
            value.get('quiescence_confirmed') is True and value.get('outcome') in ('success', 'failure') and
            value.get('operation') in ('inventory', 'install') and
            isinstance(value.get('owner'), str) and re.fullmatch('[0-9a-f]{32}', value['owner']))


def pending():
    try:
        directory = state_directory_fd(state_directory())
        try:
            return not completed(read_state(directory))
        finally:
            os.close(directory)
    except FileNotFoundError:
        return False
    except ERRORS:
        return True


class Lifecycle:
    """VS Code state using the existing no-follow, atomic, fsynced journal IO.

    No Homebrew state is adopted or changed. Only explicitly supervised
    application Restore consumers may begin a lifecycle, including inventory.
    """
    def __init__(self, operation):
        self.operation = operation
        self.directory = self.lock = self.marker = None

    def __enter__(self):
        try:
            if not restore_execution():
                raise ValueError('outside supervised Restore execution')
            # Required for inventory too: missing state denies launch rather
            # than silently losing the current-operation unknown marker.
            self.marker = marker_fd()
            try:
                read_state(self.marker, 'external-tool-active.json')
            except FileNotFoundError:
                pass
            else:
                raise ValueError('external operation already active')
            self.directory = state_directory_fd(state_directory(), create=True)
            self.lock = os.open('lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                                0o600, dir_fd=self.directory)
            private_file(os.fstat(self.lock))
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            owner = os.pread(self.lock, 65, 0)
            if owner and not re.fullmatch(b'[0-9a-f]{32}', owner):
                raise ValueError('foreign lifecycle lock')
            try:
                previous = read_state(self.directory)
            except FileNotFoundError:
                previous = None
            if previous is not None and not completed(previous):
                raise ValueError('lifecycle pending')
            self.value = dict(contract=1, tool='vscode', state='active',
                              operation=self.operation, owner=uuid.uuid4().hex)
            os.ftruncate(self.lock, 0)
            os.write(self.lock, self.value['owner'].encode('ascii'))
            os.fsync(self.lock)
            journal(None, self.value, self.directory)
            if self.marker is not None:
                journal(None, self.value, self.marker, name='external-tool-active.json')
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def finish(self, status, safe, reason):
        if read_state(self.directory) != self.value:
            raise ValueError('lifecycle changed')
        if self.marker is not None and read_state(self.marker, 'external-tool-active.json') != self.value:
            raise ValueError('operation state changed')
        if not safe:
            value = dict(self.value, state='unknown_consequences', cause=reason)
            # The durable active state already blocks re-entry if either update fails.
            journal(None, value, self.directory)
            if self.marker is not None:
                journal(None, value, self.marker, name='external-tool-active.json')
            return
        journal(None, dict(self.value, state='quiescent', quiescence_confirmed=True,
                           outcome='success' if status == 0 else 'failure'), self.directory)
        if self.marker is not None:
            os.unlink('external-tool-active.json', dir_fd=self.marker)
            os.fsync(self.marker)

    def __exit__(self, *_):
        for descriptor in (self.marker, self.lock, self.directory):
            if descriptor is not None:
                os.close(descriptor)
        self.marker = self.lock = self.directory = None


class CLIExecutor:
    def __init__(self, inventory_seconds=INVENTORY_SECONDS, install_seconds=INSTALL_SECONDS, poll=.1):
        self.budgets = {'inventory': inventory_seconds, 'install': install_seconds}
        self.poll = poll
        self.cancelled = False

    def cancel(self, *_):
        self.cancelled = True

    def run(self, command, operation):
        status, reason, safe, inventory = 2, 'vscode_process_observation_failed', True, b''
        diagnostic = Diagnostic()
        process = tree = None
        lifecycle = None
        failure_reason = reason
        try:
            if not restore_execution():
                return 2, 'vscode_lifecycle_state_failed', False, b''
            # An IPC redirect can transfer work outside the owned tree. Do not
            # silently change its target or infer ownership from inventory.
            executable = shutil.which(command[0]) or command[0]
            if os.environ.get('VSCODE_IPC_HOOK_CLI') or 'remote-cli' in Path(executable).resolve().parts:
                return 2, 'vscode_cli_delegation_unsupported', False, b''
            if pending():
                return 2, 'vscode_lifecycle_pending', False, b''
            if self.cancelled:
                return 130, 'cancelled', True, b''
            process_table()  # Observation must work before any CLI launch.
            failure_reason = 'vscode_lifecycle_state_failed'
            lifecycle = Lifecycle(operation)
            lifecycle.__enter__()
            failure_reason = 'vscode_process_observation_failed'
            if self.cancelled:
                status, reason = 130, 'cancelled'
            else:
                process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                           stderr=subprocess.STDOUT if operation == 'install' else subprocess.DEVNULL,
                                           start_new_session=True)
                safe = False
                os.set_blocking(process.stdout.fileno(), False)
                tree = ProcessTree(process.pid)
                deadline = time.monotonic() + self.budgets[operation]
                last_scan = time.monotonic()
                reason = 'unknown'
                stream_open = True

                def consume():
                    nonlocal inventory
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if operation == 'install':
                        diagnostic.feed(chunk)
                    else:
                        inventory += chunk
                        if len(inventory) > MAX_INVENTORY:
                            raise ValueError('oversized inventory')
                    return chunk

                while True:
                    if self.cancelled:
                        status, reason = 130, 'cancelled'
                        break
                    if time.monotonic() >= deadline:
                        status, reason = 124, 'vscode_' + operation + '_deadline'
                        break
                    if time.monotonic() - last_scan >= self.poll:
                        tree.scan()
                        last_scan = time.monotonic()
                    if stream_open:
                        ready, _, _ = select.select([process.stdout], [], [], self.poll)
                        if ready and not consume():
                            stream_open = False
                    else:
                        time.sleep(self.poll)
                    if process.poll() is not None:
                        status = process.returncode
                        safe = 0 <= status < 128
                        if not safe:
                            reason = 'vscode_process_interrupted'
                        break
                # No unbounded wait, including when a signal was refused. A
                # normal root exit does not excuse surviving owned descendants.
                if safe and tree.scan():
                    # Killing a still-running worker interrupts work whose
                    # consequences a native root exit/inventory cannot explain.
                    status, reason, safe = 129, 'vscode_process_interrupted', False
                confirmed = tree.stop()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    confirmed = False
                if not confirmed:
                    status, reason, safe = 129, 'vscode_quiescence_unconfirmed', False
                elif safe:
                    # With the tree stopped there is no live owned pipe writer.
                    # Drain only the bounded kernel buffer, never wait for EOF.
                    drained = False
                    for _ in range(32):
                        try:
                            if not consume():
                                drained = True
                                break
                        except BlockingIOError:
                            break
                    if not drained:
                        status, reason, safe = 129, 'vscode_quiescence_unconfirmed', False
                    if operation == 'install':
                        if safe:
                            reason = diagnostic.reason()
                    elif status == 0:
                        rows = inventory.decode('ascii').splitlines()
                        if any(row and not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_-]*', row) for row in rows):
                            status, reason = 2, 'vscode_inventory_invalid'
                        inventory = ('\n'.join(row for row in rows if row) + '\n').encode('ascii')
        except ERRORS:
            status, reason = 2, failure_reason
            safe = process is None
        finally:
            if process is not None:
                if not safe:
                    try:
                        if tree is not None:
                            tree.stop()
                    except ERRORS:
                        pass
                    try:
                        # Root is still our unreaped child, so its private group
                        # cannot be a reused unrelated process identity.
                        if process.poll() is None:
                            os.killpg(process.pid, signal.SIGKILL)
                        process.wait(timeout=1)
                    except ERRORS:
                        pass
                process.stdout.close()
            if self.cancelled and process is not None:
                status, reason, safe = 130, 'cancelled', False
            if lifecycle is not None and lifecycle.directory is not None:
                try:
                    lifecycle.finish(status, safe, reason)
                except ERRORS:
                    status, reason, safe = 129, 'vscode_lifecycle_state_failed', False
                finally:
                    lifecycle.__exit__(None, None, None)
        if status < 0:
            status = min(255, 128 - status)
        return status, reason, safe, inventory if status == 0 and safe else b''


def main():
    arguments = sys.argv[1:]
    if arguments == ['--pending']:
        return 0 if pending() else 1
    if len(arguments) == 2 and arguments[1] == '--list-extensions':
        operation = 'inventory'
    elif len(arguments) == 3 and arguments[1] == '--install-extension' and re.fullmatch(
            r'[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_-]*', arguments[2]):
        operation = 'install'
    else:
        return 2
    executor = CLIExecutor()
    signal.signal(signal.SIGTERM, executor.cancel)
    signal.signal(signal.SIGINT, executor.cancel)
    status, reason, safe, inventory = executor.run(arguments, operation)
    if operation == 'inventory':
        if status == 0 and safe:
            sys.stdout.buffer.write(inventory)
            return 0
        print('reason:' + reason)
        return 2
    print(f'reason:{reason}\nexit:{status}\nreader:0\nquiescence:{"confirmed" if safe else "unknown"}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
