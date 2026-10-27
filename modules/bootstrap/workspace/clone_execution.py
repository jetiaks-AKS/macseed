"""Application Restore clone: owned transport, durable admission, retained partials."""
import fcntl
import hashlib
import os
from pathlib import Path
import re
import select
import signal
import subprocess
import sys
import time
import uuid
import tempfile
import shlex
import stat
from contextlib import ExitStack

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'core/application-interface'))
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'apps/adapters'))
from item_execution import ProcessTree, process_table, pipe_eof
from observation import read
from homebrew_lifecycle import state_directory_fd, private_file, read_state, journal, marker_fd

DEADLINE_SECONDS = 7200
NO_PROGRESS_SECONDS = 600
ERRORS = (OSError, ValueError, RuntimeError, subprocess.SubprocessError)


class CloneAdmissionError(ValueError):
    reason = 'git_clone_ssh_configuration_unavailable'


def state_directory():
    return Path.home().resolve() / 'Library/Application Support/Macseed/GitClone'


def completed(value):
    return (type(value.get('contract')) is int and value['contract'] == 1 and
            value.get('tool') in ('git_clone', 'git_workspace') and value.get('state') == 'quiescent' and
            value.get('quiescence_confirmed') is True and value.get('outcome') in ('success', 'failure') and
            isinstance(value.get('owner'), str) and re.fullmatch('[0-9a-f]{32}', value['owner']))


def partial_name(path):
    return 'partial-' + hashlib.sha256(os.fsencode(str(Path(path).resolve()).casefold())).hexdigest() + '.json'


def pending(path=None):
    try:
        descriptor = state_directory_fd(state_directory())
        try:
            if path is not None:
                read_state(descriptor, partial_name(path))
                return True
            return not completed(read_state(descriptor))
        finally:
            os.close(descriptor)
    except FileNotFoundError:
        return False
    except ERRORS:
        return True


def admitted():
    return (os.environ.get('MACSEED_GIT_CLONE_RESTORE') == 'true' and
            os.environ.get('MACSEED_APPLICATION_EXECUTION') == 'true' and
            os.environ.get('BUNDLE_RESTORE_ACTIVE') == 'true' and
            os.environ.get('BUNDLE_RESTORE_PREVIEW') != 'true' and
            os.environ.get('MACSEED_APPLICATION_SECURE_VERIFY_ONLY') != 'true')


class Lifecycle:
    def __init__(self, path, *, existing=False, tool='git_clone'):
        self.path = path
        self.existing, self.tool = existing, tool
        self.directory = self.lock = self.marker = None

    def __enter__(self):
        try:
            if not admitted():
                raise ValueError('not Restore clone')
            self.marker = marker_fd()
            try:
                read_state(self.marker, 'external-tool-active.json')
            except FileNotFoundError:
                pass
            else:
                raise ValueError('operation pending')
            self.directory = state_directory_fd(state_directory(), create=True)
            self.lock = os.open('lifecycle.lock', os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK,
                                0o600, dir_fd=self.directory)
            private_file(os.fstat(self.lock))
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            try:
                previous = read_state(self.directory)
            except FileNotFoundError:
                previous = None
            if previous is not None and not completed(previous):
                raise ValueError('clone pending')
            if (os.path.lexists(self.path) and not self.existing) or pending(self.path):
                raise ValueError('existing destination')
            self.value = dict(contract=1, tool=self.tool, state='active', owner=uuid.uuid4().hex)
            journal(None, self.value, self.directory)
            journal(None, self.value, self.marker, name='external-tool-active.json')
            return self
        except BaseException:
            self.__exit__(None, None, None)
            raise

    def finish(self, status, safe, reason, *, launched=True):
        if (read_state(self.directory) != self.value or
                read_state(self.marker, 'external-tool-active.json') != self.value):
            raise ValueError('clone state changed')
        if not safe:
            value = dict(self.value, state='unknown_consequences', cause=reason)
            journal(None, value, self.directory)
            journal(None, value, self.marker, name='external-tool-active.json')
            return
        if launched and status != 0 and (os.path.lexists(self.path) or self.tool == 'git_workspace'):
            journal(None, dict(contract=1, state='partial_clone'), self.directory,
                    name=partial_name(self.path))
        journal(None, dict(self.value, state='quiescent', quiescence_confirmed=True,
                           outcome='success' if status == 0 else 'failure'), self.directory)
        os.unlink('external-tool-active.json', dir_fd=self.marker)
        os.fsync(self.marker)

    def __exit__(self, *_):
        for descriptor in (self.marker, self.lock, self.directory):
            if descriptor is not None:
                os.close(descriptor)
        self.marker = self.lock = self.directory = None


class Progress:
    # Only local Git numeric work counters, never remote messages or output volume.
    pattern = re.compile(rb'^(Receiving objects|Resolving deltas|Updating files):\s+\d+% \((\d+)/(\d+)\)')
    transferred = re.compile(rb', ([0-9]+(?:\.[0-9]+)?) (bytes|KiB|MiB|GiB|TiB)(?: |$)')

    def __init__(self, interval=NO_PROGRESS_SECONDS):
        self.interval, self.buffer, self.phase = interval, b'', None
        self.count, self.last = 0, None
        self.bytes = 0

    def feed(self, chunk, now):
        self.buffer += chunk
        rows = re.split(rb'[\r\n]', self.buffer)
        self.buffer = rows.pop()[-4096:]
        for row in rows:
            match = self.pattern.match(row)
            if not match:
                continue
            phase, count, total = match[1], int(match[2]), int(match[3])
            if not 0 <= count <= total or total == 0:
                continue
            size = self.transferred.search(row) if phase == b'Receiving objects' else None
            received = (float(size[1]) * 1024 ** (b'bytes', b'KiB', b'MiB', b'GiB', b'TiB').index(size[2])) if size else 0
            if phase != self.phase or count > self.count or received > self.bytes:
                self.last = now
            self.bytes = max(self.bytes, received)
            self.phase, self.count = phase, count
            if count == total:
                self.last = None  # next silent phase has only its absolute deadline

    def stalled(self, now):
        return self.last is not None and now - self.last >= self.interval


def ssh_configuration(stack):
    """Snapshot inert client settings; native SSH still owns Host matching.

    Includes, Match/exec, providers and delegated transports are not admitted.
    This is local authentication configuration, never a migration projection.
    """
    source = Path.home() / '.ssh/config'
    if not os.path.lexists(source):
        return '/dev/null'
    descriptor = os.open(source, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise CloneAdmissionError('unsafe SSH configuration')
        raw = stream.read(131073)
    if len(raw) > 131072:
        raise CloneAdmissionError('oversized SSH configuration')
    try:
        data = raw.decode('utf-8')
    except UnicodeError as exc:
        raise CloneAdmissionError('invalid SSH configuration') from exc
    allowed = {'host', 'hostname', 'user', 'port', 'identityfile', 'certificatefile',
               'identitiesonly', 'addkeystoagent', 'usekeychain', 'serveraliveinterval',
               'serveralivecountmax', 'tcpkeepalive', 'connecttimeout', 'addressfamily',
               'compression', 'loglevel'}
    for line in data.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith('#'):
            continue
        key = re.split(r'[\s=]+', stripped, maxsplit=1)[0].lower()
        if key not in allowed or any((ord(c) < 32 and c != '\t') or ord(c) == 127 for c in line):
            raise CloneAdmissionError('unsupported SSH configuration')
    directory = Path(stack.enter_context(tempfile.TemporaryDirectory(prefix='macseed-clone-', dir='/private/tmp')))
    path = directory / 'ssh_config'
    descriptor = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        stream.write(data)
    return str(path)


def command(remote, path, branch, ssh_config='/dev/null', *, observe=None):
    # Reject config/env that can start filters, helpers, redirected work or hooks
    # outside the bounded transport contract. Do not rewrite global configuration.
    forbidden = ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR', 'GIT_INDEX_FILE', 'GIT_OBJECT_DIRECTORY',
                 'GIT_ALTERNATE_OBJECT_DIRECTORIES', 'GIT_CONFIG_COUNT', 'GIT_CONFIG_PARAMETERS',
                 'GIT_CONFIG', 'GIT_EXEC_PATH', 'GIT_TEMPLATE_DIR', 'GIT_PROXY_COMMAND')
    if any(name in os.environ for name in forbidden):
        raise ValueError('unsupported Git routing')
    if (not remote or remote.startswith('-') or '\n' in remote or
            ('://' in remote and not remote.startswith(('https://', 'ssh://', 'file://'))) or
            '::' in remote):
        raise ValueError('unsupported transport')
    config = read(['git', 'config', '--null', '--list'], cwd='/')
    if config.returncode != 0:
        raise ValueError('configuration unavailable')
    if observe is not None:
        observe(config.stdout)
    for record in config.stdout.split(b'\0'):
        key = record.partition(b'\n')[0].lower()
        if key.startswith((b'filter.', b'url.', b'include', b'remote.', b'uploadpack.')):
            raise ValueError('unsupported clone configuration')
    environment = dict(os.environ, LC_ALL='C', GIT_TERMINAL_PROMPT='0', GIT_ASKPASS='/usr/bin/false',
                       SSH_ASKPASS='/usr/bin/false', SSH_ASKPASS_REQUIRE='never', GIT_SSH_VARIANT='ssh',
                       GIT_SSH_COMMAND='ssh -F ' + shlex.quote(ssh_config) + ' -o BatchMode=yes -o StrictHostKeyChecking=yes '
                       '-o AddKeysToAgent=no '
                       '-o UpdateHostKeys=no -o CheckHostIP=no -o ControlMaster=no -o ControlPath=none '
                       '-o ControlPersist=no -o ProxyCommand=none -o ProxyJump=none '
                       '-o PermitLocalCommand=no -o ClearAllForwardings=yes -o ForwardAgent=no')
    arguments = ['git', '-c', 'credential.helper=', '-c', 'credential.interactive=false',
                 '-c', 'core.hooksPath=/dev/null', '-c', 'core.fsmonitor=false',
                 '-c', 'gc.auto=0', '-c', 'maintenance.auto=false', '-c', 'submodule.recurse=false',
                 '-c', 'protocol.allow=never', '-c', 'protocol.https.allow=always',
                 '-c', 'protocol.ssh.allow=always', '-c', 'protocol.file.allow=always',
                 'clone', '--progress', '--no-local', '--no-recurse-submodules', '--template=',
                 *(['--branch', branch] if branch else []), '--', remote, path]
    return arguments, environment


class CloneExecutor:
    def __init__(self, deadline=DEADLINE_SECONDS, no_progress=NO_PROGRESS_SECONDS):
        self.deadline, self.no_progress, self.cancelled = deadline, no_progress, False
        self.native_exit = None

    def cancel(self, *_):
        self.cancelled = True

    def run(self, remote, path, branch, *, empty_destination=False, verify=None):
        def prepare(scratch):
            if empty_destination and (Path(path).is_symlink() or not Path(path).is_dir() or any(Path(path).iterdir())):
                raise ValueError('destination changed')
            ssh_remote = remote.startswith('ssh://') or (':' in remote and not remote.startswith(('https://', 'file://', '/')))
            config = ssh_configuration(scratch) if ssh_remote else '/dev/null'
            return command(remote, path, branch, config)
        return self._run(path, prepare, existing=empty_destination, verify=verify)

    def run_local(self, path, arguments, environment, *, verify=None, unchanged=None, require_unchanged=False):
        """Same owned lifecycle for qualified worktree/HEAD operations."""
        return self._run(path, lambda _scratch: (arguments, environment),
                         existing=True, tool='git_workspace', verify=verify, unchanged=unchanged,
                         require_unchanged=require_unchanged)

    def _run(self, path, prepare, *, existing=False, tool='git_clone', verify=None, unchanged=None, require_unchanged=False):
        self.native_exit = None
        process = tree = lifecycle = None
        scratch = ExitStack()
        status, reason, safe = 2, 'git_clone_admission_failed', True
        try:
            if not admitted() or pending() or pending(path) or (os.path.lexists(path) and not existing):
                return status, reason, False
            arguments, environment = prepare(scratch)
            process_table()
            lifecycle = Lifecycle(path, existing=existing, tool=tool)
            lifecycle.__enter__()
            if self.cancelled:
                status, reason = 130, 'cancelled'
            else:
                def launch():
                    return subprocess.Popen(arguments, env=environment, cwd='/',
                                            stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                                            stderr=subprocess.PIPE, start_new_session=True)
                from homebrew_stop import State, KEY, StopAccepted
                if os.environ.get('MACSEED_WORKSPACE_CONTEXT') and os.environ.get(KEY):
                    def launch_at_boundary(data):
                        if data['stop']:
                            raise StopAccepted()
                        if data['scope'] != 'workspace':
                            raise ValueError('workspace launch scope changed')
                        return launch()
                    process = State(os.environ[KEY]).locked(launch_at_boundary)
                else:
                    process = launch()
                safe = False
                tree = ProcessTree(process.pid)
                os.set_blocking(process.stderr.fileno(), False)
                progress = Progress(self.no_progress)
                diagnostics = b''
                deadline, scan_at = time.monotonic() + self.deadline, 0
                while True:
                    now = time.monotonic()
                    if self.cancelled:
                        status, reason = 130, 'cancelled'
                        break
                    if now >= deadline or progress.stalled(now):
                        status = 124
                        reason = 'git_clone_deadline' if now >= deadline else 'git_clone_no_progress'
                        break
                    if now >= scan_at:
                        tree.scan()
                        scan_at = time.monotonic() + .25
                    ready, _, _ = select.select([process.stderr], [], [], .05)
                    if ready:
                        chunk = os.read(process.stderr.fileno(), 65536)
                        progress.feed(chunk, now)
                        diagnostics = (diagnostics + chunk)[-8192:]
                        if not chunk:
                            time.sleep(.05)
                    if process.poll() is not None:
                        # Collect the bounded diagnostic tail already in the pipe.
                        # EOF/quiescence is still independently required below.
                        for _ in range(8):
                            try:
                                chunk = os.read(process.stderr.fileno(), 65536)
                            except BlockingIOError:
                                break
                            if not chunk:
                                break
                            diagnostics = (diagnostics + chunk)[-8192:]
                        status = process.returncode
                        self.native_exit = status
                        reason = 'git_clone_failed' if status else 'none'
                        if status:
                            if b'Permission denied (publickey' in diagnostics or b'Authentication failed' in diagnostics:
                                reason = 'git_clone_authentication_failed'
                            elif b'Host key verification failed' in diagnostics:
                                reason = 'git_clone_host_key_failed'
                            elif b'Remote branch ' in diagnostics and b'not found' in diagnostics:
                                reason = 'git_clone_branch_unavailable'
                            elif b'Repository not found' in diagnostics or b'does not appear to be a git repository' in diagnostics:
                                reason = 'git_clone_remote_unavailable'
                        if tree.scan():
                            status, reason = 2, 'git_clone_worker_interrupted'
                        break
                # Controlled Git/SSH and no user hooks/filters/delegation: a stopped
                # tree bounds writes to this new destination, not repository validity.
                safe = tree.stop()
                process.wait(timeout=1)
        except ERRORS as exc:
            reason = 'git_clone_observation_failed' if process is not None else getattr(exc, 'reason', 'git_clone_admission_failed')
            status, safe = 2, process is None
        finally:
            if process is not None:
                try:
                    if tree is not None:
                        safe = tree.stop() and safe
                    if process.poll() is None:
                        os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=1)
                    safe = pipe_eof(process.stderr) and safe
                except ERRORS:
                    safe = False
                process.stderr.close()
            if not safe and process is not None:
                status, reason = 129, 'git_clone_quiescence_unconfirmed'
            if safe and status == 0 and verify is not None:
                try:
                    if not verify():
                        status, reason = 2, 'workspace_verification_failed'
                except ERRORS:
                    status, reason, safe = 129, 'workspace_preservation_unconfirmed', False
            if lifecycle is not None and lifecycle.directory is not None:
                try:
                    retained = process is not None
                    if safe and status != 0 and self.native_exit != 0 and unchanged is not None:
                        retained = not unchanged()
                        if retained and require_unchanged:
                            status, reason, safe = 129, 'workspace_preservation_unconfirmed', False
                    lifecycle.finish(status, safe, reason, launched=retained)
                except ERRORS:
                    status, reason, safe = 129, 'git_clone_state_failed', False
                finally:
                    lifecycle.__exit__(None, None, None)
            scratch.close()
        return status if status >= 0 else 128 - status, reason, safe


def main():
    if len(sys.argv) == 4 and sys.argv[1] == '--independent':
        left, right = (str(Path(path).resolve()).casefold().rstrip('/') for path in sys.argv[2:])
        metadata = Path(sys.argv[3]) / '.git'
        if os.path.lexists(metadata) and (not metadata.is_dir() or metadata.is_symlink() or
                any(os.path.lexists(metadata / name) for name in (
                    'commondir', 'worktrees', 'objects/info/alternates', 'objects/info/http-alternates'))):
            return 2
        return 2 if left == right or left.startswith(right + '/') or right.startswith(left + '/') else 0
    if sys.argv[1:] == ['--pending']:
        return 0 if pending() else 1
    if len(sys.argv) == 3 and sys.argv[1] == '--partial':
        return 0 if pending(sys.argv[2]) else 1
    if len(sys.argv) != 4:
        return 2
    executor = CloneExecutor()
    signal.signal(signal.SIGTERM, executor.cancel)
    signal.signal(signal.SIGINT, executor.cancel)
    status, reason, safe = executor.run(*sys.argv[1:])
    print(f'exit:{status}\nreason:{reason}\nsafe:{str(safe).lower()}')
    if executor.native_exit is not None and 0 <= executor.native_exit <= 255:
        print(f'native_exit:{executor.native_exit}')
    return 0


if __name__ == '__main__':
    sys.exit(main())
