#!/bin/bash
migration_run() {
    command -v python3 >/dev/null 2>&1 || { printf 'Python 3 required\n' >&2; return 2; }
    local migration_code
    migration_code="$(
        # Do not lend the application channel to the heredoc reader.
        if [[ $# -eq 10 && "$7" == --application-channel-fd && "$8" =~ ^[0-9]+$ && "$8" -gt 2 ]]; then
            eval "exec ${8}<&-"
        fi
        if [[ $# -eq 7 && "$4" == --application-channel-fd && "$5" =~ ^[0-9]+$ && "$5" -gt 2 ]]; then
            eval "exec ${5}<&-"
        fi
        cat <<'PY'
import hashlib
import json
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tarfile
import tempfile
import termios
import threading

MAX_PACKAGE = 32 * 1024 * 1024
MAX_KEY = 1024 * 1024
MAX_ITEMS = 32
NAME = re.compile(r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}\Z', re.ASCII)
TYPES = {'ssh-ed25519', 'ssh-rsa', 'ecdsa-sha2-nistp256',
         'ecdsa-sha2-nistp384', 'ecdsa-sha2-nistp521'}
sys.dont_write_bytecode = True
sys.path.insert(0, sys.argv.pop(1))
from evidence import Evidence
from secret_input import Input, SecureError, PrivateTemporaryDirectory, decrypt, key_public, encrypt
mode, *args = sys.argv[1:]
interaction = None
if mode == 'import' and len(args) == 9:
    interaction = Input(int(args[6]), args[8])
    args = args[:5]
if mode == 'application-export' and len(args) == 6:
    interaction = Input(int(args[3]), args[5])
    args = args[:2]
evidence = Evidence(args[2], args[4]) if mode == 'import' and len(args) == 5 else Evidence()
secure_code = None
private_temporary = PrivateTemporaryDirectory if interaction is not None else tempfile.TemporaryDirectory
home = os.environ.get('HOME', '')
ssh = os.path.join(home, '.ssh')
uid = os.getuid()

def interrupted(signum, frame):
    raise KeyboardInterrupt()

signal.signal(signal.SIGINT, interrupted)
signal.signal(signal.SIGTERM, interrupted)

class Invalid(Exception):
    pass

class UnlockFailed(Invalid):
    pass

class Conflict(Exception):
    pass

class Cancel(Exception):
    pass

def say(message):
    print(message, file=sys.stderr)

def owned(path, kind, permissions):
    s = os.lstat(path)
    allowed_modes = permissions if isinstance(permissions, tuple) else (permissions,)
    if s.st_uid != uid or (kind == 'file' and s.st_nlink != 1) or stat.S_IMODE(s.st_mode) not in allowed_modes:
        raise Invalid('unsafe ownership, links or permissions')
    if kind == 'file' and not stat.S_ISREG(s.st_mode):
        raise Invalid('non-regular file')
    if kind == 'dir' and not stat.S_ISDIR(s.st_mode):
        raise Invalid('non-directory')

def home_check():
    if not home.startswith('/') or os.path.realpath(home) != home or not os.path.isdir(home) or os.stat(home).st_uid != uid:
        raise Invalid('unsafe HOME')

def ssh_check(allow_missing=False):
    home_check()
    if not os.path.lexists(ssh):
        if allow_missing:
            return False
        raise Invalid('SSH directory missing')
    owned(ssh, 'dir', 0o700)
    return True

def safe_name(name):
    if not NAME.fullmatch(name) or name.endswith('.pub') or name in ('.', '..'):
        raise Invalid('unsafe identity name')

def data(path, limit=MAX_KEY):
    with open(path, 'rb') as f:
        result = f.read(limit + 1)
    if len(result) > limit:
        raise Invalid('file too large')
    return result

def checked_bytes(path, modes):
    parent = os.path.dirname(path)
    if os.path.realpath(parent) != parent:
        raise Invalid('identity parent contains symlink')
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parent_before = os.fstat(parent_fd)
        if not stat.S_ISDIR(parent_before.st_mode) or parent_before.st_uid != uid or stat.S_IMODE(parent_before.st_mode) != 0o700 or (parent_before.st_dev, parent_before.st_ino) != (os.lstat(parent).st_dev, os.lstat(parent).st_ino):
            raise Invalid('identity parent changed')
        fd = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            before = os.fstat(fd)
            allowed = modes if isinstance(modes, tuple) else (modes,)
            if not stat.S_ISREG(before.st_mode) or before.st_uid != uid or before.st_nlink != 1 or stat.S_IMODE(before.st_mode) not in allowed:
                raise Invalid('unsafe identity file')
            with os.fdopen(os.dup(fd), 'rb') as stream:
                raw = stream.read(MAX_KEY + 1)
            after = os.fstat(fd)
            path_now = os.lstat(path)
            parent_now = os.lstat(parent)
            if len(raw) > MAX_KEY or (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns) or (after.st_dev, after.st_ino) != (path_now.st_dev, path_now.st_ino) or (parent_before.st_dev, parent_before.st_ino) != (parent_now.st_dev, parent_now.st_ino) or stat.S_IMODE(parent_now.st_mode) != 0o700:
                raise Invalid('identity changed during validation')
            return raw
        finally:
            os.close(fd)
    finally:
        os.close(parent_fd)

def open_checked_package(path):
    parent = os.path.dirname(path)
    if os.path.realpath(parent) != parent:
        raise Invalid('package parent contains symlink')
    parent_fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        parent_before = os.fstat(parent_fd)
        parent_visible = os.lstat(parent)
        if not stat.S_ISDIR(parent_before.st_mode) or (parent_before.st_dev, parent_before.st_ino) != (parent_visible.st_dev, parent_visible.st_ino):
            raise Invalid('package parent changed')
        fd = os.open(os.path.basename(path), os.O_RDONLY | os.O_NOFOLLOW, dir_fd=parent_fd)
        try:
            s = os.fstat(fd)
            visible = os.lstat(path)
            parent_now = os.lstat(parent)
            if not stat.S_ISREG(s.st_mode) or s.st_uid != uid or s.st_nlink != 1 or stat.S_IMODE(s.st_mode) != 0o600 or s.st_size > MAX_PACKAGE or (s.st_dev, s.st_ino) != (visible.st_dev, visible.st_ino) or (parent_before.st_dev, parent_before.st_ino) != (parent_now.st_dev, parent_now.st_ino):
                raise Invalid('unsafe package input')
            return fd
        except BaseException:
            os.close(fd)
            raise
    finally:
        os.close(parent_fd)

def public_fields(raw):
    try:
        line = raw.strip().split()
        if len(line) < 2 or line[0].decode('ascii') not in TYPES:
            raise ValueError()
        import base64
        blob = base64.b64decode(line[1], validate=True)
        if len(blob) < 32:
            raise ValueError()
        return line[0].decode('ascii'), blob
    except (UnicodeError, ValueError):
        raise Invalid('unsupported or malformed public key')

def validate_pair(private, public):
    raw_private = checked_bytes(private, 0o600)
    raw_public = checked_bytes(public, (0o600, 0o644))
    if not raw_private.startswith(b'-----BEGIN OPENSSH PRIVATE KEY-----'):
        raise Invalid('unsupported private key format')
    kind, blob = public_fields(raw_public)
    tty_settings = None
    if os.isatty(0):
        tty_settings = termios.tcgetattr(0)
        hidden = termios.tcgetattr(0)
        hidden[3] &= ~termios.ECHO
        termios.tcsetattr(0, termios.TCSANOW, hidden)
    try:
        with private_temporary(prefix='ssh-migrate-', dir=local_tempbase()) as validation_dir:
            os.chmod(validation_dir, 0o700)
            validated_private = os.path.join(validation_dir, 'identity')
            fd = os.open(validated_private, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
            with os.fdopen(fd, 'wb') as staged:
                os.fchmod(staged.fileno(), 0o600)
                staged.write(raw_private)
            if interaction is not None:
                public_output = key_public(validated_private, interaction)
            else:
                for attempt in range(1, 4):
                    wrong_passphrase = False
                    child = subprocess.Popen(
                        ['ssh-keygen', '-y', '-f', validated_private],
                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)
                    def prompt_filter():
                        nonlocal wrong_passphrase
                        seen = b''
                        prompt_started = False
                        try:
                            while True:
                                chunk = child.stderr.read(1)
                                if not chunk:
                                    break
                                seen = (seen + chunk)[-96:]
                                if b'incorrect passphrase' in seen:
                                    wrong_passphrase = True
                                if seen.endswith(b'Enter passphrase'):
                                    prompt_started = True
                                if prompt_started and seen.endswith(b': '):
                                    say('SSH key passphrase: ')
                                    prompt_started = False
                        except OSError:
                            pass
                    reader = threading.Thread(target=prompt_filter, daemon=True)
                    reader.start()
                    try:
                        public_output = child.stdout.read(MAX_KEY + 1)
                        if len(public_output) > MAX_KEY and child.poll() is None:
                            child.kill()
                        child.wait()
                        reader.join()
                    finally:
                        if child.poll() is None:
                            child.terminate()
                            try:
                                child.wait(timeout=2)
                            except subprocess.TimeoutExpired:
                                child.kill()
                                child.wait()
                        child.stdout.close()
                        child.stderr.close()
                    if child.returncode == 0 and len(public_output) <= MAX_KEY:
                        break
                    if not wrong_passphrase or len(public_output) > MAX_KEY:
                        raise Invalid('private key validation failed')
                    if not os.isatty(0):
                        raise UnlockFailed('SSH key could not be unlocked')
                    if attempt == 3:
                        raise UnlockFailed('SSH key could not be unlocked after 3 attempts')
                    say('SSH key passphrase was not accepted; try again')
    finally:
        if tty_settings is not None:
            termios.tcsetattr(0, termios.TCSANOW, tty_settings)
    derived_kind, derived_blob = public_fields(public_output)
    if (kind, blob) != (derived_kind, derived_blob):
        raise Invalid('public/private mismatch')
    fp = 'SHA256:' + __import__('base64').b64encode(hashlib.sha256(blob).digest()).decode().rstrip('=')
    return kind, fp, raw_private, raw_public

def candidates():
    ssh_check()
    found = []
    for name in sorted(os.listdir(ssh)):
        if not NAME.fullmatch(name) or name.endswith('.pub') or name in ('.', '..'):
            continue
        private = os.path.join(ssh, name)
        public = private + '.pub'
        if not os.path.lexists(public):
            continue
        try:
            kind, fp, _, _ = validate_pair(private, public)
            found.append((name, kind, fp))
        except UnlockFailed as exc:
            say('Excluded: ' + str(exc))
        except (Invalid, OSError):
            say('Excluded: unsuitable identity')
    return found

def capture_candidates():
    # Show candidates without unlocking keys; selected pairs are fully validated
    # once, from private staged bytes, immediately before package construction.
    ssh_check()
    found = []
    for name in sorted(os.listdir(ssh)):
        if not NAME.fullmatch(name) or name.endswith('.pub') or name in ('.', '..'):
            continue
        private = os.path.join(ssh, name)
        public = private + '.pub'
        if not os.path.lexists(public):
            continue
        try:
            raw_private = checked_bytes(private, 0o600)
            raw_public = checked_bytes(public, (0o600, 0o644))
            if not raw_private.startswith(b'-----BEGIN OPENSSH PRIVATE KEY-----'):
                raise Invalid('unsupported private key format')
            kind, blob = public_fields(raw_public)
            fp = 'SHA256:' + __import__('base64').b64encode(hashlib.sha256(blob).digest()).decode().rstrip('=')
            found.append((name, kind, fp))
        except (Invalid, OSError):
            say('Excluded: unsuitable identity')
    return found

def application_candidates():
    if not ssh_check(allow_missing=True):
        return {'status': 'unavailable', 'reason': 'source_absent', 'items': []}
    entries = []
    for name, kind, fp in capture_candidates():
        states = []
        for suffix in ('', '.pub'):
            metadata = os.lstat(os.path.join(ssh, name + suffix))
            states.append((metadata.st_dev, metadata.st_ino, metadata.st_size, metadata.st_mtime_ns,
                           metadata.st_ctime_ns, metadata.st_mode, metadata.st_uid))
        stamp = hashlib.sha256(json.dumps(states).encode()).hexdigest()
        item_id = hashlib.sha256((name + ':' + fp).encode()).hexdigest()
        entries.append({'item_id': item_id, 'label': name, 'key_type': kind, 'fingerprint': fp,
                        'validation': 'candidate_requires_pair_validation', '_stamp': stamp, '_name': name})
    if len(entries) > MAX_ITEMS:
        raise Invalid('too many candidates')
    return {'status': 'present' if entries else 'unavailable', 'reason': None if entries else 'no_eligible_identities', 'items': entries}

def ask(prompt):
    if interaction is not None:
        interaction.ask('import_confirmation')
        return 'import'
    try:
        sys.stderr.write(prompt)
        sys.stderr.flush()
        return sys.stdin.readline().strip()
    except OSError:
        raise Invalid('interactive terminal required')

def digest(raw):
    return hashlib.sha256(raw).hexdigest()

def local_tempbase():
    path = '/private/tmp'
    with open(os.devnull, 'wb') as null:
        result = subprocess.run(['df', '-P', path], stdout=subprocess.PIPE, stderr=null)
    lines = result.stdout.splitlines()
    if result.returncode or len(lines) != 2 or not lines[1].split()[0].startswith(b'/dev/'):
        raise Invalid('local temporary storage unavailable')
    return path

def manifest_bytes(records):
    lines = ['toolkit-ssh-identities', 'version=1', 'count=' + str(len(records))]
    for name, kind, fp, priv, pub in records:
        lines.append('\t'.join((name, kind, fp, str(len(priv)), digest(priv), str(len(pub)), digest(pub))))
    return ('\n'.join(lines) + '\n').encode('ascii')

def check_manifest(raw):
    if len(raw) > 16384 or b'\r' in raw or b'\x00' in raw:
        raise Invalid('invalid manifest')
    try:
        lines = raw.decode('ascii').splitlines()
        if lines[:2] != ['toolkit-ssh-identities', 'version=1'] or len(lines) < 4:
            raise ValueError()
        count = int(lines[2].removeprefix('count='))
        if lines[2] != 'count=' + str(count) or not 1 <= count <= MAX_ITEMS or len(lines) != count + 3:
            raise ValueError()
        records = []
        for line in lines[3:]:
            parts = line.split('\t')
            if len(parts) != 7:
                raise ValueError()
            name, kind, fp, psz, ph, usz, uh = parts
            safe_name(name)
            if kind not in TYPES or not re.fullmatch(r'SHA256:[A-Za-z0-9+/]{43}', fp):
                raise ValueError()
            if not (psz.isdigit() and usz.isdigit() and psz == str(int(psz)) and usz == str(int(usz)) and 0 < int(psz) <= MAX_KEY and 0 < int(usz) <= MAX_KEY):
                raise ValueError()
            if not (re.fullmatch('[0-9a-f]{64}', ph) and re.fullmatch('[0-9a-f]{64}', uh)):
                raise ValueError()
            records.append(parts)
        if [r[0] for r in records] != sorted(set(r[0] for r in records)):
            raise ValueError()
        if not raw.endswith(b'\n') or b'\n\n' in raw:
            raise ValueError()
        return records
    except (ValueError, Invalid):
        raise Invalid('invalid manifest')

def raw_tar_names(path):
    raw = data(path, MAX_PACKAGE)
    offset = 0
    names = []
    while offset + 512 <= len(raw):
        header = raw[offset:offset + 512]
        if header == b'\0' * 512:
            if len(raw) - offset < 1024 or any(raw[offset:]):
                raise Invalid('invalid archive trailer')
            return names
        if header[156:157] not in (b'0', b'\0') or header[345:500].strip(b'\0'):
            raise Invalid('unsupported archive header')
        name_bytes = header[:100].split(b'\0', 1)[0]
        size_bytes = header[124:136].strip(b'\0 ')
        try:
            name = name_bytes.decode('ascii')
            if not name or not size_bytes or any(c not in b'01234567' for c in size_bytes):
                raise ValueError()
            size = int(size_bytes, 8)
        except (UnicodeError, ValueError):
            raise Invalid('invalid archive header')
        if size < 1 or size > MAX_KEY or len(names) >= 1 + 2 * MAX_ITEMS:
            raise Invalid('archive limits exceeded')
        names.append(name)
        offset += 512 + ((size + 511) // 512) * 512
    raise Invalid('truncated archive')

def archive_validate(path, stage):
    if os.path.getsize(path) > MAX_PACKAGE:
        raise Invalid('package too large')
    raw_names = raw_tar_names(path)
    with tarfile.open(path, 'r:') as archive:
        members = archive.getmembers()
        with open(path, 'rb') as archive_bytes:
            archive_bytes.seek(archive.offset)
            tail = archive_bytes.read()
        if len(tail) < 1024 or any(tail):
            raise Invalid('invalid archive trailer')
        if not 3 <= len(members) <= 1 + 2 * MAX_ITEMS or members[0].name != 'manifest':
            raise Invalid('invalid archive entries')
        names = [m.name for m in members]
        if names != raw_names:
            raise Invalid('unexpected archive metadata')
        if len(set(names)) != len(names) or any(m.pax_headers or not m.isfile() or m.size < 1 or m.size > MAX_KEY for m in members):
            raise Invalid('invalid archive type or size')
        if sum(m.size for m in members) > MAX_PACKAGE:
            raise Invalid('archive too large')
        raw = archive.extractfile(members[0]).read(16385)
        records = check_manifest(raw)
        expected = ['manifest']
        for r in records:
            expected.extend(('keys/' + r[0], 'keys/' + r[0] + '.pub'))
        if names != expected:
            raise Invalid('unexpected archive entries')
        result = []
        for r in records:
            name, kind, fp, psz, ph, usz, uh = r
            private = archive.extractfile('keys/' + name).read(MAX_KEY + 1)
            public = archive.extractfile('keys/' + name + '.pub').read(MAX_KEY + 1)
            if (len(private), digest(private), len(public), digest(public)) != (int(psz), ph, int(usz), uh):
                raise Invalid('package metadata mismatch')
            p = os.path.join(stage, name)
            q = p + '.pub'
            for path, payload, perm in ((p, private, 0o600), (q, public, 0o644)):
                fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, perm)
                with os.fdopen(fd, 'wb') as f:
                    os.fchmod(f.fileno(), perm)
                    f.write(payload)
            actual_kind, actual_fp, _, _ = validate_pair(p, q)
            if (kind, fp) != (actual_kind, actual_fp):
                raise Invalid('package fingerprint mismatch')
            result.append((name, kind, fp, private, public))
        return result

def target_plan(records):
    home_check()
    exists = os.path.lexists(ssh)
    if exists:
        try:
            owned(ssh, 'dir', 0o700)
        except Invalid:
            raise Conflict('unsafe SSH target directory')
    plan = []
    for name, _, _, private, public in records:
        p = os.path.join(ssh, name)
        q = p + '.pub'
        if not exists or (not os.path.lexists(p) and not os.path.lexists(q)):
            plan.append('create')
            continue
        if not (os.path.lexists(p) and os.path.lexists(q)):
            raise Conflict('partial target pair')
        try:
            _, _, current_private, current_public = validate_pair(p, q)
            if current_private != private or current_public != public:
                evidence.different(name)
                raise Conflict('different target pair')
        except (Invalid, OSError):
            raise Conflict('unsafe target pair')
        plan.append('identical')
    return plan

def open_home_dir():
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        current = os.fstat(fd)
        visible = os.lstat(home)
        if not stat.S_ISDIR(current.st_mode) or current.st_uid != uid or (current.st_dev, current.st_ino) != (visible.st_dev, visible.st_ino):
            raise Conflict('HOME changed')
        return fd
    except BaseException:
        os.close(fd)
        raise

def open_export_parent(path):
    if os.path.realpath(path) != path:
        raise Invalid('export parent contains symlink')
    fd = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        current = os.fstat(fd)
        visible = os.lstat(path)
        if not stat.S_ISDIR(current.st_mode) or current.st_uid != uid or stat.S_IMODE(current.st_mode) != 0o700 or (current.st_dev, current.st_ino) != (visible.st_dev, visible.st_ino):
            raise Invalid('unsafe export parent')
        return fd
    except BaseException:
        os.close(fd)
        raise

def export_parent_still_visible(fd, path):
    current = os.fstat(fd)
    visible = os.lstat(path)
    if (current.st_dev, current.st_ino) != (visible.st_dev, visible.st_ino):
        raise Conflict('export parent changed')

def open_target_dir(homefd):
    fd = os.open('.ssh', os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=homefd)
    try:
        current = os.fstat(fd)
        visible = os.lstat(ssh)
        if not stat.S_ISDIR(current.st_mode) or current.st_uid != uid or stat.S_IMODE(current.st_mode) != 0o700 or (current.st_dev, current.st_ino) != (visible.st_dev, visible.st_ino):
            raise Conflict('SSH directory changed')
        return fd
    except BaseException:
        os.close(fd)
        raise

def target_dir_still_visible(fd):
    current = os.fstat(fd)
    visible = os.lstat(ssh)
    if (current.st_dev, current.st_ino) != (visible.st_dev, visible.st_ino) or not stat.S_ISDIR(visible.st_mode) or visible.st_uid != uid or stat.S_IMODE(visible.st_mode) != 0o700:
        raise Conflict('SSH directory changed')

def publish_pair(name, private, public, created, dirfd):
    for suffix, payload, perm in (('', private, 0o600), ('.pub', public, 0o644)):
        target_dir_still_visible(dirfd)
        relative = name + suffix
        try:
            fd = os.open(relative, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, perm, dir_fd=dirfd)
        except FileExistsError:
            raise Conflict('target identity appeared during publication')
        with os.fdopen(fd, 'wb') as f:
            s = os.fstat(f.fileno())
            created.append((relative, s.st_dev, s.st_ino))
            os.fchmod(f.fileno(), perm)
            f.write(payload)
            f.flush()
            os.fsync(f.fileno())

def run():
    for dependency in ('ssh-keygen', 'tar', 'python3'):
        if not shutil.which(dependency):
            raise Invalid('required tool missing: ' + dependency)
    if mode == 'application-list':
        print(json.dumps(application_candidates(), sort_keys=True))
        return
    if mode == 'list':
        for index, (name, kind, fp) in enumerate(candidates(), 1):
            print(f'{index}. {name} {kind} {fp}')
        return
    if not shutil.which('age'):
        raise Invalid('age required')
    if not os.isatty(0) and interaction is None:
        raise Invalid('interactive terminal required')
    if mode in ('export', 'capture-export', 'application-export'):
        output = args[0]
        if os.path.lexists(output) or os.path.islink(output):
            raise Conflict('export destination exists')
        parent = os.path.dirname(output)
        owned(parent, 'dir', 0o700)
        if os.path.realpath(parent) != parent:
            raise Invalid('export parent contains symlink')
        if mode == 'application-export':
            selected = json.loads(data(args[1]))
            current = {entry['item_id']: entry for entry in application_candidates()['items']}
            if (not isinstance(selected, list) or not 1 <= len(selected) <= MAX_ITEMS or
                    len({entry['item_id'] for entry in selected}) != len(selected) or
                    any(current.get(entry['item_id']) != entry for entry in selected)):
                raise Conflict('selected identity changed')
            chosen = sorted(entry['_name'] for entry in selected)
            candidate_details = {entry['_name']: (entry['key_type'], entry['fingerprint']) for entry in selected}
        else:
            items = capture_candidates() if mode == 'capture-export' else candidates()
            if not items:
                if mode == 'capture-export':
                    say('No candidate SSH identities found')
                    return
                raise Invalid('no eligible identities')
            if mode == 'capture-export':
                say('Select candidate SSH identities; each selected key will be fully validated before encryption.')
            for index, (name, kind, fp) in enumerate(items, 1):
                print(f'{index}. {name} {kind} {fp}')
            selection = ask('Select numbers (comma separated): ')
            if not selection:
                raise Cancel()
            try:
                indices = [int(x.strip()) for x in selection.split(',')]
                if len(indices) > MAX_ITEMS or len(indices) != len(set(indices)) or any(i < 1 or i > len(items) for i in indices):
                    raise ValueError()
            except ValueError:
                raise Invalid('invalid selection')
            chosen = sorted(items[i-1][0] for i in indices)
            candidate_details = {name: (kind, fp) for name, kind, fp in items}
            if mode == 'capture-export':
                for name in chosen:
                    kind, fp = candidate_details[name]
                    print(f'Candidate export: {name} {kind} {fp}')
                print('Destination:', output)
                if ask('Type export to confirm: ') != 'export':
                    raise Cancel()
        records = []
        for name in chosen:
            kind, fp, private, public = validate_pair(os.path.join(ssh, name), os.path.join(ssh, name + '.pub'))
            if mode in ('capture-export', 'application-export') and (kind, fp) != candidate_details[name]:
                raise Conflict('selected identity changed')
            records.append((name, kind, fp, private, public))
        if mode == 'application-export':
            current = {entry['item_id']: entry for entry in application_candidates()['items']}
            if any(current.get(entry['item_id']) != entry for entry in selected):
                raise Conflict('selected identity changed')
        if sum(len(r[3]) + len(r[4]) for r in records) > MAX_PACKAGE - 65536:
            raise Invalid('selected identities exceed package limit')
        if mode == 'export':
            for name, kind, fp, _, _ in records:
                print(f'Export: {name} {kind} {fp}')
            print('Destination:', output)
            if ask('Type export to confirm: ') != 'export':
                raise Cancel()
        parent_fd = open_export_parent(parent)
        published_identity = None
        completed = False
        try:
            export_parent_still_visible(parent_fd, parent)
            if os.path.lexists(output):
                raise Conflict('export destination exists')
            with private_temporary(prefix='ssh-migrate-', dir=local_tempbase()) as temp, private_temporary(prefix='.ssh-migrate-', dir=parent) as cipher_temp:
                os.chmod(temp, 0o700)
                os.chmod(cipher_temp, 0o700)
                stage = os.path.join(temp, 'stage')
                os.mkdir(stage, 0o700)
                os.mkdir(os.path.join(stage, 'keys'), 0o700)
                for path, payload in [('manifest', manifest_bytes(records))] + [(f'keys/{name}{suffix}', raw) for name, _, _, private, public in records for suffix, raw in (('', private), ('.pub', public))]:
                    target = os.path.join(stage, path)
                    with open(target, 'xb') as f:
                        os.chmod(target, 0o600)
                        f.write(payload)
                encrypted = os.path.join(cipher_temp, 'package.age')
                if mode == 'capture-export':
                    say('Create a NEW Secure Credentials passphrase for this Bootstrap Bundle. It is not your SSH-key passphrase.')
                    say('You will need it for bs restore on the new Mac. Save it separately from the Bundle.')
                    say('Leave the age prompt empty only if you want age to display an autogenerated passphrase once; save that too.')
                with open(encrypted, 'xb') as out, open(os.devnull, 'wb') as null:
                    os.chmod(encrypted, 0o600)
                    tar = subprocess.Popen(['tar', '-cf', '-', '--format=ustar', '-C', stage, '--', 'manifest'] + [f'keys/{name}{suffix}' for name, _, _, _, _ in records for suffix in ('', '.pub')], stdout=subprocess.PIPE, stderr=null, env=dict(os.environ, COPYFILE_DISABLE='1'))
                    age = None
                    try:
                        tar_fd = tar.stdout.fileno()
                        if mode == 'application-export':
                            encrypt(tar_fd, out, interaction)
                            age = subprocess.CompletedProcess([], 0)
                        else:
                            age = subprocess.run(['age', '-p', '/dev/fd/' + str(tar_fd)], stdout=out, pass_fds=(tar_fd,))
                    finally:
                        tar.stdout.close()
                        if tar.poll() is None and (age is None or age.returncode != 0):
                            tar.terminate()
                        tar.wait()
                    if tar.returncode or age.returncode:
                        raise Invalid('encryption failed')
                if not os.path.getsize(encrypted) or os.path.getsize(encrypted) > MAX_PACKAGE:
                    raise Invalid('encrypted package size invalid')
                metadata = os.stat(encrypted, follow_symlinks=False)
                published_identity = (metadata.st_dev, metadata.st_ino)
                export_parent_still_visible(parent_fd, parent)
                try:
                    os.link(encrypted, os.path.basename(output), dst_dir_fd=parent_fd, follow_symlinks=False)
                except FileExistsError:
                    raise Conflict('export destination appeared')
            export_parent_still_visible(parent_fd, parent)
            owned(output, 'file', 0o600)
            completed = True
        finally:
            if not completed and published_identity is not None:
                try:
                    current = os.stat(os.path.basename(output), dir_fd=parent_fd, follow_symlinks=False)
                    if (current.st_dev, current.st_ino) == published_identity:
                        os.unlink(os.path.basename(output), dir_fd=parent_fd)
                except OSError:
                    pass
            os.close(parent_fd)
        print('Encrypted package published')
        return
    source = args[0]
    if os.path.realpath(source) != source:
        raise Invalid('package path contains symlink')
    tempbase = local_tempbase()
    package_fd = open_checked_package(source)
    with os.fdopen(package_fd, 'rb') as encrypted_in, private_temporary(prefix='ssh-migrate-', dir=tempbase) as temp:
        os.chmod(temp, 0o700)
        archive = os.path.join(temp, 'payload.tar')
        stage = os.path.join(temp, 'stage')
        os.mkdir(stage, 0o700)
        with open(archive, 'xb') as out:
            os.chmod(archive, 0o600)
            input_fd = encrypted_in.fileno()
            evidence.reason = 'decrypt_failed'
            if interaction is not None:
                decrypt(input_fd, out, interaction)
            else:
                result = subprocess.run(['age', '-d', '/dev/fd/' + str(input_fd)], stdout=out, pass_fds=(input_fd,))
                if result.returncode:
                    raise Invalid('decryption failed')
        evidence.reason = 'input_invalid'
        records = archive_validate(archive, stage)
        evidence.selected([r[0] for r in records])
        plan = target_plan(records)
        for (name, kind, fp, _, _), status in zip(records, plan):
            print(f'{status}: {name} {kind} {fp}')
        if 'create' not in plan:
            evidence.matched('noop')
            print('All identities already match')
            return
        if ask('Type import to confirm: ') != 'import':
            raise Cancel()
        if target_plan(records) != plan:
            raise Conflict('target changed')
        evidence.phase = 'apply'
        created = []
        made_ssh = False
        mutation_recorded = False
        homefd = None
        dirfd = None
        try:
            homefd = open_home_dir()
            if not os.path.lexists(ssh):
                if interaction is not None:
                    interaction.mutation()
                    mutation_recorded = True
                try:
                    os.mkdir('.ssh', 0o700, dir_fd=homefd)
                except FileExistsError:
                    raise Conflict('SSH directory appeared')
                made_ssh = True
            dirfd = open_target_dir(homefd)
            if target_plan(records) != plan:
                raise Conflict('target changed')
            for (name, _, _, private, public), status in zip(records, plan):
                if status == 'create':
                    if interaction is not None and not mutation_recorded:
                        interaction.mutation()
                        mutation_recorded = True
                    publish_pair(name, private, public, created, dirfd)
            evidence.phase = 'post_apply'
            target_dir_still_visible(dirfd)
            if target_plan(records) != ['identical'] * len(records):
                raise Invalid('post-publication verification failed')
            evidence.matched('success')
            print('Import verified')
        except BaseException:
            for relative, device, inode in reversed(created):
                try:
                    current = os.stat(relative, dir_fd=dirfd, follow_symlinks=False)
                    if (current.st_dev, current.st_ino) == (device, inode):
                        os.unlink(relative, dir_fd=dirfd)
                except OSError:
                    pass
            if made_ssh:
                try:
                    if dirfd is not None:
                        target_dir_still_visible(dirfd)
                    if homefd is not None:
                        os.rmdir('.ssh', dir_fd=homefd)
                except (OSError, Conflict):
                    pass
            raise
        finally:
            if dirfd is not None:
                os.close(dirfd)
            if homefd is not None:
                os.close(homefd)

status = 0
try:
    run()
except SecureError as exc:
    secure_code = exc.code
    if secure_code == 'secure_payload_invalid' and evidence.phase in ('apply', 'post_apply'):
        secure_code = 'secure_import_failed'
    evidence.failed('cancelled' if exc.code == 'secure_cancelled' else 'failure',
                    'cancelled' if exc.code == 'secure_cancelled' else 'operation_failed')
    status = 1 if exc.code == 'secure_cancelled' else 2
except Cancel:
    say('Cancelled')
    evidence.failed('cancelled', 'cancelled')
    status = 1
except Conflict as exc:
    say('Conflict: ' + str(exc))
    if interaction is not None:
        secure_code = 'secure_target_conflict'
    if evidence.phase in ('apply', 'post_apply'):
        evidence.failed('failure', 'post_validation_failed' if evidence.phase == 'post_apply' else 'operation_failed')
    else:
        evidence.failed('skipped', 'target_conflict')
    status = 1
except (Invalid, OSError, tarfile.TarError, subprocess.SubprocessError) as exc:
    say('Migration failed: ' + (str(exc) if isinstance(exc, Invalid) else 'operation failed'))
    reason = 'post_validation_failed' if evidence.phase == 'post_apply' else ('operation_failed' if evidence.phase == 'apply' else (evidence.reason if evidence.reason in ('decrypt_failed', 'input_invalid') else 'operation_failed'))
    evidence.failed('failure', reason)
    status = 2
except KeyboardInterrupt:
    say('Interrupted')
    evidence.failed('cancelled', 'cancelled')
    status = 130
try:
    evidence.publish()
except (OSError, ValueError, KeyboardInterrupt):
    pass # Evidence transport never changes the standalone import result.
if interaction is not None:
    if mode == 'application-export' and status != 0 and secure_code is None:
        secure_code = 'secure_cancelled' if status in (1, 130) else 'secure_export_failed'
    if secure_code is None:
        secure_code = ('success' if status == 0 else
                       'secure_cancelled' if evidence.reason == 'cancelled' else
                       'secure_target_conflict' if evidence.reason == 'target_conflict' else
                       'secure_payload_invalid' if evidence.phase not in ('apply', 'post_apply') else 'secure_import_failed')
    try:
        interaction.finish(secure_code)
    except (SecureError, OSError):
        pass
sys.exit(status)
PY
)" || return 2
    exec python3 -c "$migration_code" "$SCRIPT_ROOT/modules/migration" "$@"
}
