"""Private, bounded transport to an explicitly trusted bundled Zsh helper."""
from contextlib import contextmanager
import base64
import ctypes as C
from functools import lru_cache
import importlib.util
import json
import os
from pathlib import Path
import platform
import re
import select
import selectors
import signal
import stat
import subprocess
import time

spec = importlib.util.spec_from_file_location('shell_observation_state', Path(__file__).with_name('state.py'))
state = importlib.util.module_from_spec(spec)
spec.loader.exec_module(state)
base = state.legacy().base
spec = importlib.util.spec_from_file_location('shell_owned_process',
    Path(__file__).parents[1] / 'core/application-interface/item_execution.py')
processes = importlib.util.module_from_spec(spec)
spec.loader.exec_module(processes)

PROCESS_SECONDS = 3.0
OUTPUT_LIMIT = 128 * 1024
BINARY_LIMIT = 32 * 1024 * 1024  # Includes the existing universal developer package.
# Public Darwin sys/event.h flags. A signal alone is not enforcement evidence.
NOTE_EXITSTATUS = 0x04000000
NOTE_EXIT_DETAIL = 0x02000000
NOTE_EXIT_DETAIL_MASK = 0x00070000
NOTE_EXIT_CSERROR = 0x00040000
ERROR_CODES = frozenset(('invalid_request input_io input_limit invalid_encoding syntax_invalid '
    'boundary_uncertain nesting_limit node_limit definition_count_limit definition_size_limit '
    'name_count_limit allocation_limit output_limit timeout cancelled process_failed memory_limit internal_error').split())


class Invalid(ValueError):
    CODES = {'functions_unavailable', 'helper_unavailable', 'helper_untrusted', 'launch_failed', 'process_failed',
             'process_cleanup_failed', 'parser_invalid', 'output_limit', 'timeout', 'cancelled',
             'source_limit', 'source_encoding'} | {'parser_' + code for code in ERROR_CODES}

    def __init__(self, code):
        self.code = code if code in self.CODES else 'parser_invalid'
        super().__init__('shell_observation_' + self.code)


class _Foundation:
    """Public Objective-C API only; load OS code, never a custom runtime bridge."""
    def __init__(self):
        try:
            self.framework = C.CDLL('/System/Library/Frameworks/Foundation.framework/Foundation')
            self.objc = C.CDLL('/usr/lib/libobjc.A.dylib')
            self.objc.objc_getClass.argtypes = [C.c_char_p]
            self.objc.objc_getClass.restype = C.c_void_p
            self.objc.sel_registerName.argtypes = [C.c_char_p]
            self.objc.sel_registerName.restype = C.c_void_p
            self.calls = {}
        except (OSError, AttributeError):
            raise Invalid('functions_unavailable') from None

    def cls(self, name):
        return self.objc.objc_getClass(name.encode('ascii'))

    def send(self, obj, selector, result=C.c_void_p, types=(), args=()):
        key = (selector, result, types)
        if key not in self.calls:
            method = C.CFUNCTYPE(result, C.c_void_p, C.c_void_p, *types)(('objc_msgSend', self.objc))
            self.calls[key] = method, self.objc.sel_registerName(selector.encode('ascii'))
        method, selected = self.calls[key]
        return method(obj, selected, *args)

    def require_available(self):
        selector = self.objc.sel_registerName(b'setLaunchRequirementData:')
        if not self.cls('NSTask') or not self.send(self.cls('NSTask'), 'instancesRespondToSelector:',
                C.c_bool, (C.c_void_p,), (selector,)):
            raise Invalid('functions_unavailable')

    def string(self, text):
        return self.send(self.cls('NSString'), 'stringWithUTF8String:', types=(C.c_char_p,),
                         args=(str(text).encode('utf-8'),))

    def url(self, path):
        return self.send(self.cls('NSURL'), 'fileURLWithPath:', types=(C.c_void_p,), args=(self.string(path),))

    def environment(self):
        values = {'PATH': '/nonexistent', 'HOME': '/nonexistent', 'LC_ALL': 'C'}
        keys = (C.c_void_p * len(values))(*[self.string(k) for k in values])
        objects = (C.c_void_p * len(values))(*[self.string(v) for v in values.values()])
        return self.send(self.cls('NSDictionary'), 'dictionaryWithObjects:forKeys:count:',
                         types=(C.c_void_p, C.c_void_p, C.c_ulong), args=(objects, keys, len(values)))


@lru_cache(maxsize=1)
def _foundation():
    return _Foundation()


class _Task:
    """One Foundation-owned task, with Python-owned bounded transport pipes.

    Foundation alone observes/reaps the direct child's exit; never waitpid it.
    The autorelease pool and task are released on the calling thread on all paths.
    """
    def __init__(self, executable, requirement, *, enforcement_probe=False):
        self.api = _foundation()
        self.api.require_available()
        self.pool = self.task = self.pid = None
        self.stdin = self.stdout = None
        self.returncode = None
        self.group = None
        self.exit_queue = None
        self.exit_events = []
        ends = []
        api = self.api
        try:
            self.pool = api.send(api.cls('NSAutoreleasePool'), 'new')
            self.task = api.send(api.cls('NSTask'), 'new')
            data = api.send(api.cls('NSData'), 'dataWithBytes:length:',
                types=(C.c_void_p, C.c_ulong), args=(C.cast(C.c_char_p(requirement), C.c_void_p), len(requirement)))
            for selector, value in (('setExecutableURL:', api.url(executable)),
                    ('setCurrentDirectoryURL:', api.url('/')), ('setEnvironment:', api.environment()),
                    ('setLaunchRequirementData:', data)):
                api.send(self.task, selector, None, (C.c_void_p,), (value,))
            for selector, reading in (('setStandardInput:', False), ('setStandardOutput:', True)):
                rd, wr = os.pipe()
                parent, child = (rd, wr) if reading else (wr, rd)
                ends.append(child)
                stream = os.fdopen(parent, 'rb' if reading else 'wb', buffering=0)
                if reading:
                    self.stdout = stream
                else:
                    self.stdin = stream
                handle = api.send(api.send(api.cls('NSFileHandle'), 'alloc'),
                    'initWithFileDescriptor:closeOnDealloc:', types=(C.c_int, C.c_bool), args=(child, False))
                api.send(self.task, selector, None, (C.c_void_p,), (handle,))
                api.send(handle, 'release', None)
            api.send(self.task, 'setStandardError:', None, (C.c_void_p,),
                     (api.send(api.cls('NSFileHandle'), 'fileHandleWithNullDevice'),))
            if enforcement_probe:
                self.exit_queue = select.kqueue()
            self._launch()
            self.pid = api.send(self.task, 'processIdentifier', C.c_int)
            if self.exit_queue is not None:
                event = select.kevent(self.pid, filter=select.KQ_FILTER_PROC,
                    flags=select.KQ_EV_ADD | select.KQ_EV_ONESHOT,
                    fflags=select.KQ_NOTE_EXIT | NOTE_EXITSTATUS | NOTE_EXIT_DETAIL)
                self.exit_events = self.exit_queue.control([event], 1, 0)
            try:
                if os.getpgid(self.pid) != self.pid:
                    raise Invalid('process_failed')
                self.group = self.pid
            except ProcessLookupError:
                pass  # Immediate rejection/exit still requires its exit status.
        except BaseException:
            self.close()
            raise
        finally:
            for fd in ends:
                os.close(fd)

    def _launch(self):
        error = C.c_void_p()
        if not self.api.send(self.task, 'launchAndReturnError:', C.c_bool,
                (C.POINTER(C.c_void_p),), (C.byref(error),)):
            # NSError may contain paths. Never format or propagate its description.
            raise Invalid('launch_failed')

    def poll(self):
        if self.returncode is None and not self.api.send(self.task, 'isRunning', C.c_bool):
            status = self.api.send(self.task, 'terminationStatus', C.c_int)
            reason = self.api.send(self.task, 'terminationReason', C.c_long)
            self.returncode = -status if reason == 2 else status
        return self.returncode

    def wait(self, timeout):
        until = time.monotonic() + timeout
        while self.poll() is None:
            if time.monotonic() >= until:
                raise Invalid('process_cleanup_failed')
            time.sleep(.01)
        return self.returncode

    def kill(self):
        if self.pid and self.poll() is None:
            if self.group == self.pid and os.getpgid(self.pid) == self.pid:
                os.killpg(self.pid, signal.SIGKILL)
            else:
                os.kill(self.pid, signal.SIGKILL)

    def constraint_rejected(self):
        """Require the OS code-signing kill receipt for this exact child.

        kqueue does not reap Foundation's child. A lost/late event fails closed;
        neither ordinary SIGKILL nor timeout/cleanup kills prove enforcement.
        """
        if not self.exit_events:
            self.exit_events = self.exit_queue.control([], 1, 0)
        if len(self.exit_events) != 1:
            return False
        event = self.exit_events[0]
        return (event.ident == self.pid and event.filter == select.KQ_FILTER_PROC
                and not event.flags & select.KQ_EV_ERROR
                and event.fflags == select.KQ_NOTE_EXIT | NOTE_EXITSTATUS | NOTE_EXIT_DETAIL
                and event.data & NOTE_EXIT_DETAIL_MASK == NOTE_EXIT_CSERROR
                and os.WIFSIGNALED(event.data & 0xffff)
                and os.WTERMSIG(event.data & 0xffff) == signal.SIGKILL
                and self.poll() == -signal.SIGKILL)

    def close(self):
        try:
            if self.task and self.pid:
                self.kill()
                self.wait(1)
        finally:
            if self.exit_queue is not None:
                self.exit_queue.close()
                self.exit_queue = None
            for stream in (self.stdin, self.stdout):
                if stream is not None and not stream.closed:
                    stream.close()
            if self.task:
                self.api.send(self.task, 'release', None)
                self.task = None
            if self.pool:
                self.api.send(self.pool, 'drain', None)
                self.pool = None
            self.pid = None


@contextmanager
def _file(path, limit, executable=False):
    """Hold and recheck the trusted code path; never resolve arbitrary links."""
    fds, links = [], []
    try:
        path = Path(path)
        if not path.is_absolute() or '..' in path.parts or len(path.parts) > 64:
            raise Invalid('helper_untrusted')
        # Same fixed, root-owned macOS temporary aliases as Shell's HOME guard.
        for prefix in ('/var/', '/tmp/'):
            if str(path).startswith(prefix):
                alias = Path(prefix[:-1]); target = Path('/private' + prefix[:-1])
                if alias.lstat().st_uid == 0 and alias.resolve() == target:
                    path = target / str(path)[len(prefix):]
        fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        fds.append(fd)
        for i, part in enumerate(path.parts[1:]):
            parent = os.fstat(fd)
            if (parent.st_uid not in (0, os.getuid()) or
                    parent.st_mode & 0o022 and not (parent.st_uid == 0 and parent.st_mode & stat.S_ISVTX)):
                raise Invalid('helper_untrusted')
            base.acl_safe(fd)
            flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK
            if i < len(path.parts) - 2:
                flags |= os.O_DIRECTORY
            child = os.open(part, flags, dir_fd=fd)
            fds.append(child)
            links.append((fd, part, child, base.stamp(os.fstat(child))))
            fd = child
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid not in (0, os.getuid()) or
                info.st_nlink != 1 or info.st_mode & 0o022 or info.st_flags or
                info.st_size > limit or executable and stat.S_IMODE(info.st_mode) != 0o755):
            raise Invalid('helper_untrusted')
        def check():
            for owner, part, child, before in links:
                # Directory timestamps change for unrelated siblings; identity,
                # ownership, mode and ACL still have to remain safe.
                width = 6 if stat.S_ISDIR(before[2]) else len(before)
                if (base.stamp(os.fstat(child))[:width] != before[:width] or
                        base.stamp(os.stat(part, dir_fd=owner, follow_symlinks=False))[:width] != before[:width]):
                    raise Invalid('helper_untrusted')
                base.acl_safe(child)
        raw = bytearray()
        while len(raw) <= limit:
            chunk = os.read(fd, min(65536, limit + 1 - len(raw)))
            if not chunk:
                break
            raw.extend(chunk)
        if len(raw) != info.st_size:
            raise Invalid('helper_untrusted')
        check()
        yield str(path), bytes(raw), check
        check()
    except FileNotFoundError:
        raise Invalid('helper_unavailable') from None
    except (OSError, ValueError) as exc:
        if isinstance(exc, Invalid):
            raise
        raise Invalid('helper_untrusted') from None
    finally:
        for fd in reversed(fds):
            os.close(fd)


class Parser:
    """The caller supplies a trusted code location, never snapshot/user config."""
    def __init__(self, *, package=None, bundle=None, manifest_sha256=None):
        if (package is None) == (bundle is None):
            raise Invalid('helper_untrusted')
        location = package if package is not None else bundle
        if not isinstance(location, (str, Path)) or not Path(location).is_absolute():
            raise Invalid('helper_untrusted')
        # The trusted Core/build caller supplies this anchor out of band. A
        # writable build.json (or an adjacent checksum) cannot authorize code.
        if type(manifest_sha256) is not str or not re.fullmatch('[0-9a-f]{64}', manifest_sha256):
            raise Invalid('helper_untrusted')
        self._manifest_sha256 = manifest_sha256
        self._enforced_requirement = None
        root = Path(location)
        self._binary = root / ('macseed-shell-parser' if package is not None else 'Contents/Helpers/macseed-shell-parser')
        self._manifest = root / ('build.json' if package is not None else 'Contents/Resources/ThirdPartyNotices/shell-parser-build.json')

    def __repr__(self):
        return '<ShellParser private>'

    @staticmethod
    def require_available():
        _foundation().require_available()

    @contextmanager
    def _verified(self):
        self.require_available()
        with _file(self._manifest, 65536) as (_, metadata, manifest_check), \
                _file(self._binary, BINARY_LIMIT, True) as (executable, binary, binary_check):
            try:
                if state.digest(metadata) != self._manifest_sha256:
                    raise Invalid('helper_untrusted')
                value = state._json(metadata, 65536)
                state.keys(value, 'schema minimum_macos functions_minimum_macos architectures sanitized sources compiler swift_compiler build_macos sdk binaries')
                pins = json.loads((Path(__file__).parent / 'parser/vendor/pins.json').read_bytes())
                expected = value['binaries']['macseed-shell-parser']
                state.keys(expected, 'bytes sha256 launch')
                if (type(value['schema']) is not int or value['schema'] != 2 or
                        value['minimum_macos'] != '14.0' or value['functions_minimum_macos'] != '14.4' or
                        value['sanitized'] is not False or value['sources'] != pins or
                        type(value['architectures']) is not list or
                        not 1 <= len(value['architectures']) <= 2 or
                        len(set(value['architectures'])) != len(value['architectures']) or
                        type(expected['bytes']) is not int or
                        platform.machine() not in value['architectures'] or expected['bytes'] != len(binary) or
                        expected['sha256'] != state.digest(binary) or binary[:4] not in
                        (b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xca\xfe\xba\xbf')):
                    raise Invalid('helper_untrusted')
                launch = expected['launch']
                state.keys(launch, 'schema cdhashes requirement_data')
                hashes = launch['cdhashes']
                if (type(launch['schema']) is not int or launch['schema'] != 1 or
                        type(hashes) is not dict or set(hashes) != set(value['architectures']) or
                        not set(hashes) <= {'arm64', 'x86_64'} or
                        any(type(rows) is not list or not 1 <= len(rows) <= 4 or
                            any(type(h) is not str or not re.fullmatch('[0-9a-f]{40}', h) for h in rows) or
                            rows != sorted(set(rows)) for rows in hashes.values()) or
                        type(launch['requirement_data']) is not str or len(launch['requirement_data']) > 5464):
                    raise Invalid('helper_untrusted')
                requirement = base64.b64decode(launch['requirement_data'], validate=True)
                if not 0 < len(requirement) <= 4096:
                    raise Invalid('helper_untrusted')
            except (KeyError, TypeError, ValueError):
                raise Invalid('helper_untrusted') from None
            yield executable, requirement
            manifest_check(); binary_check()

    def preflight(self, *, cancelled=lambda: False):
        """Fresh enforcement evidence before observing HOME, never a parser run."""
        self._enforced_requirement = None
        if cancelled():
            raise Invalid('cancelled')
        with self._verified() as (_, requirement):
            self._require_enforcement(requirement, cancelled)

    def _require_enforcement(self, requirement, cancelled):
        if cancelled():
            raise Invalid('cancelled')
        if self._enforced_requirement == requirement:
            return
        # Only the fixed Apple system executable may run before enforcement is
        # established. The anchored build supplies a valid parser-only CDHash
        # requirement, deliberately excluding this OS executable. Controls on
        # either side rule out an unusable executable or launch environment.
        try:
            for constraint, probe in ((b'', False), (requirement, True), (b'', False)):
                output, code = self._run('/usr/bin/true', constraint, b'', cancelled,
                                         enforcement_probe=probe)
                if output or code != (-signal.SIGKILL if probe else 0):
                    raise Invalid('functions_unavailable')
        except Invalid as exc:
            if exc.code in ('cancelled', 'process_cleanup_failed'):
                raise
            raise Invalid('functions_unavailable') from None
        # Instance-local only: observe() explicitly refreshes this receipt for
        # every observation. Never persist/cache an environment capability.
        self._enforced_requirement = requirement

    def parse(self, source, *, cancelled=lambda: False):
        if type(source) is not bytes or len(source) > state.MAX_SOURCE:
            raise Invalid('source_limit')
        try:
            state.utf8(source)
        except state.Invalid:
            raise Invalid('source_encoding') from None
        if cancelled():
            raise Invalid('cancelled')
        with self._verified() as (executable, requirement):
            self._require_enforcement(requirement, cancelled)
            response, code = self._run(executable, requirement, source, cancelled)
        if code == 2:
            try:
                error = state._json(response, OUTPUT_LIMIT - 1)
                state.keys(error, 'schema profile status code definitions')
                if (type(error['schema']) is int and error['schema'] == 1 and error['profile'] == 'zsh-default-1'
                        and error['status'] == 'error' and error['definitions'] == []
                        and type(error['code']) is str and error['code'] in ERROR_CODES):
                    raise Invalid('parser_' + error['code'])
            except state.Invalid:
                pass
            raise Invalid('parser_invalid')
        if code != 0:
            raise Invalid('process_failed')
        try:
            state.parser_response(source, response, code)
        except state.Invalid:
            raise Invalid('parser_invalid') from None
        return response

    @staticmethod
    def _run(executable, requirement, source, cancelled, *, enforcement_probe=False):
        child = tree = None
        deadline = time.monotonic() + PROCESS_SECONDS
        output, sent = bytearray(), 0
        try:
            child = _Task(executable, requirement, enforcement_probe=enforcement_probe)
            # Input remains open/empty until process ownership is captured. The
            # native helper cannot fork its parsing worker before input EOF.
            tree = processes.ProcessTree(child.pid, process_group=True)
            with selectors.DefaultSelector() as poller:
                for stream in (child.stdin, child.stdout):
                    os.set_blocking(stream.fileno(), False)
                poller.register(child.stdout, selectors.EVENT_READ)
                poller.register(child.stdin, selectors.EVENT_WRITE)
                scan_at = 0
                while poller.get_map() or child.poll() is None:
                    if cancelled():
                        raise Invalid('cancelled')
                    if time.monotonic() >= deadline:
                        raise Invalid('timeout')
                    if time.monotonic() >= scan_at:
                        tree.scan(); scan_at = time.monotonic() + .1
                    for key, _ in poller.select(.02):
                        if key.fileobj is child.stdin:
                            try:
                                sent += os.write(key.fd, source[sent:sent + 16384])
                            except BrokenPipeError:
                                sent = len(source)
                            if sent == len(source):
                                poller.unregister(child.stdin); child.stdin.close()
                        else:
                            chunk = os.read(key.fd, min(8192, OUTPUT_LIMIT - len(output)))
                            output.extend(chunk)
                            if len(output) >= OUTPUT_LIMIT:
                                raise Invalid('output_limit')
                            if not chunk:
                                poller.unregister(child.stdout); child.stdout.close()
            code = child.wait(timeout=1)
            if enforcement_probe and not child.constraint_rejected():
                raise Invalid('functions_unavailable')
            return bytes(output), code
        except (OSError, subprocess.SubprocessError, RuntimeError, ValueError) as exc:
            if isinstance(exc, Invalid):
                raise
            raise Invalid('launch_failed' if child is None else 'process_failed') from None
        finally:
            if child is not None:
                clean = False
                try:
                    tree = tree or processes.ProcessTree(child.pid, process_group=True)
                    clean = tree.stop()
                except (OSError, ValueError, RuntimeError, subprocess.SubprocessError):
                    clean = False
                finally:
                    try:
                        if child.poll() is None:
                            # The live Foundation task proves its private group's
                            # identity even when process-table inspection fails.
                            child.kill()
                    except OSError:
                        clean = False
                    try:
                        child.wait(timeout=1)
                    except (OSError, subprocess.SubprocessError):
                        clean = False
                    finally:
                        try:
                            child.close()
                        except (OSError, Invalid):
                            clean = False
                if not clean:
                    raise Invalid('process_cleanup_failed') from None
