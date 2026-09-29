#!/bin/bash
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)" || exit 2
TEST_ROOT="$(mktemp -d)" || exit 2
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)" || exit 2
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
export HOME="$TEST_ROOT/home"
mkdir -m 700 "$HOME" "$HOME/.ssh"
CLI="$PROJECT_ROOT/scripts/ssh-identity-migrate.sh"
REAL_AGE_PATH="$(command -v age || true)"
failed=0
check() {
    local label="$1" expected="$2"; shift 2
    "$@" > "$TEST_ROOT/out" 2>&1
    local got=$?
    if [[ $got -eq $expected ]]; then printf 'PASS %s\n' "$label"; else printf 'FAIL %s (%s)\n' "$label" "$got"; failed=$((failed+1)); fi
}
ssh-keygen -q -t ed25519 -N '' -f "$HOME/.ssh/id_ed25519" >/dev/null 2>&1 || exit 2
check list 0 bash "$CLI" list
grep -q 'id_ed25519 ssh-ed25519 SHA256:' "$TEST_ROOT/out" || { printf 'FAIL list content\n'; failed=$((failed+1)); }
cp "$HOME/.ssh/id_ed25519.pub" "$TEST_ROOT/public"
rm "$HOME/.ssh/id_ed25519.pub"
check missing_public_excluded 0 bash "$CLI" list
grep -q 'id_ed25519 ssh-' "$TEST_ROOT/out" && { printf 'FAIL missing public listed\n'; failed=$((failed+1)); }
cp "$TEST_ROOT/public" "$HOME/.ssh/id_ed25519.pub"
chmod 666 "$HOME/.ssh/id_ed25519.pub"
check unsafe_public_mode_excluded 0 bash "$CLI" list
grep -q 'id_ed25519 ssh-' "$TEST_ROOT/out" && { printf 'FAIL unsafe public listed\n'; failed=$((failed+1)); }
chmod 644 "$HOME/.ssh/id_ed25519.pub"
ssh-keygen -q -t ed25519 -N '' -f "$TEST_ROOT/different" >/dev/null 2>&1 || exit 2
cp "$TEST_ROOT/different.pub" "$HOME/.ssh/id_ed25519.pub"
check mismatched_public_excluded 0 bash "$CLI" list
grep -q 'id_ed25519 ssh-' "$TEST_ROOT/out" && { printf 'FAIL mismatched public listed\n'; failed=$((failed+1)); }
cp "$TEST_ROOT/public" "$HOME/.ssh/id_ed25519.pub"
ln -s "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_link"
ln -s "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_link.pub"
check symlink_excluded 0 bash "$CLI" list
grep -q 'id_link ssh-' "$TEST_ROOT/out" && { printf 'FAIL symlink listed\n'; failed=$((failed+1)); }
ln "$HOME/.ssh/id_ed25519" "$HOME/.ssh/id_hard"
cp "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_hard.pub"
check hardlink_excluded 0 bash "$CLI" list
grep -q 'id_hard ssh-' "$TEST_ROOT/out" && { printf 'FAIL hardlink listed\n'; failed=$((failed+1)); }
rm "$HOME/.ssh/id_hard" "$HOME/.ssh/id_hard.pub" "$HOME/.ssh/id_link" "$HOME/.ssh/id_link.pub"
mkdir -m 700 "$TEST_ROOT/no-age-bin" || exit 2
for tool in cat dirname python3 ssh-keygen tar; do
    ln -s "$(command -v "$tool")" "$TEST_ROOT/no-age-bin/$tool" || exit 2
done
check dependency_without_age 2 /usr/bin/env PATH="$TEST_ROOT/no-age-bin" /bin/bash "$CLI" export --output "$TEST_ROOT/package.age"
grep -Fq 'age required' "$TEST_ROOT/out" || { printf 'FAIL dependency_without_age reason\n'; failed=$((failed+1)); }
ssh-keygen -q -t rsa -b 2048 -N '' -f "$HOME/.ssh/id_rsa" >/dev/null 2>&1 || exit 2
ssh-keygen -q -t ecdsa -b 256 -N '' -f "$HOME/.ssh/id_ecdsa" >/dev/null 2>&1 || exit 2
mkdir -m 700 "$TEST_ROOT/mock-bin"
cat > "$TEST_ROOT/mock-bin/age" <<'MOCK'
#!/bin/bash
if [[ -n "${MIGRATION_TEST_HANG:-}" ]]; then touch "$MIGRATION_TEST_HANG"; sleep 30; fi
if [[ "${2:-}" == /dev/fd/* ]]; then cat "$2"; else cat; fi
MOCK
chmod 755 "$TEST_ROOT/mock-bin/age"
export PATH="$TEST_ROOT/mock-bin:$PATH"
python3 - "$CLI" "$HOME" "$TEST_ROOT" "$REAL_AGE_PATH" <<'PY'
import fcntl, glob, hashlib, os, pty, re, select, shutil, signal, subprocess, sys, tarfile, termios, time
cli, source_home, root, real_age = sys.argv[1:]
temp_before = set(glob.glob('/private/tmp/ssh-migrate-*'))
def execute(command, answers, home):
    global last_output
    master, slave = pty.openpty()
    settings = termios.tcgetattr(slave)
    settings[3] &= ~termios.ECHO
    termios.tcsetattr(slave, termios.TCSANOW, settings)
    env = dict(os.environ, HOME=home)
    def controlling_tty():
        os.setsid()
        fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
    proc = subprocess.Popen(command, stdin=slave, stdout=slave,
                            stderr=slave, env=env, preexec_fn=controlling_tty)
    os.close(slave)
    transcript = b''
    full_transcript = b''
    pending = list(answers)
    end = time.monotonic() + 20
    while proc.poll() is None and time.monotonic() < end:
        marker = os.environ.get('MIGRATION_TEST_HANG')
        if marker and os.path.exists(marker):
            os.killpg(proc.pid, signal.SIGTERM)
            os.environ.pop('MIGRATION_TEST_HANG', None)
        ready, _, _ = select.select([master], [], [], .2)
        if ready:
            try:
                chunk = os.read(master, 65536)
                transcript += chunk
                full_transcript += chunk
            except OSError: break
        if pending and pending[0][0] in transcript:
            if b'passphrase' in pending[0][0]:
                time.sleep(.05)
            os.write(master, pending.pop(0)[1] + b'\n')
            transcript = b''
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    os.close(master)
    if b'BEGIN OPENSSH PRIVATE KEY' in full_transcript or b'fixture-only-passphrase' in full_transcript or re.search(rb'ssh-(?:ed25519|rsa) [A-Za-z0-9+/]{32}', full_transcript):
        print('FAIL secret appeared in PTY output from', command[0]); sys.exit(1)
    last_output = full_transcript
    return proc.returncode
def invoke(args, answers, home):
    return execute(['bash', cli] + args, answers, home)
package = os.path.join(root, 'package.age')
linked_home = os.path.join(root, 'linked-home')
os.symlink(source_home, linked_home)
if invoke(['list'], [], linked_home) != 2:
    print('FAIL symlink HOME'); sys.exit(1)
print('PASS symlink HOME rejected')
if invoke(['export', '--output', package], [(b'Select numbers', b'1,2,3'), (b'Type export', b'export')], source_home):
    print('FAIL mocked export'); sys.exit(1)
if os.stat(package).st_mode & 0o777 != 0o600:
    print('FAIL package mode'); sys.exit(1)
if invoke(['export', '--output', package], [], source_home) != 1:
    print('FAIL export no-clobber'); sys.exit(1)
target_home = os.path.join(root, 'target')
os.mkdir(target_home, 0o700)
if invoke(['import', '--input', package], [(b'Type import', b'import')], target_home):
    print('FAIL mocked import'); sys.exit(1)
if invoke(['import', '--input', package], [], target_home):
    print('FAIL mocked identical import'); sys.exit(1)
print('PASS mocked export/import/identical PTY lifecycle')
import io, tarfile
with tarfile.open(package, 'r:') as t:
    members = [(m.name, t.extractfile(m).read()) for m in t.getmembers()]
bad_cases = {
    'duplicate': members + [members[-1]],
    'unexpected': members + [('extra', b'x')],
    'traversal': members + [('../escape', b'x')],
    'absolute': members + [('/tmp/escape', b'x')],
    'malformed manifest': [('manifest', b'bad\n')] + members[1:],
}
for label, entries in bad_cases.items():
    bad = os.path.join(root, label.replace(' ', '-') + '.age')
    with tarfile.open(bad, 'w') as t:
        for name, payload in entries:
            info = tarfile.TarInfo(name)
            info.size = len(payload)
            t.addfile(info, io.BytesIO(payload))
    os.chmod(bad, 0o600)
    if invoke(['import', '--input', bad], [], target_home) != 2:
        print('FAIL rejected archive:', label); sys.exit(1)
print('PASS mocked malformed/duplicate/unexpected/traversal rejection')
metadata_package = os.path.join(root, 'pax.age')
with tarfile.open(metadata_package, 'w', format=tarfile.PAX_FORMAT) as t:
    for name, payload in members:
        info = tarfile.TarInfo(name)
        info.size = len(payload)
        info.pax_headers = {'comment': 'unexpected'}
        t.addfile(info, io.BytesIO(payload))
os.chmod(metadata_package, 0o600)
if invoke(['import', '--input', metadata_package], [], target_home) != 2:
    print('FAIL pax archive'); sys.exit(1)
print('PASS pax metadata rejection')
bad_link = os.path.join(root, 'link.age')
with tarfile.open(bad_link, 'w') as t:
    for name, payload in members:
        info = tarfile.TarInfo(name)
        if name == members[-1][0]:
            info.type = tarfile.SYMTYPE
            info.linkname = '/tmp/escape'
        else:
            info.size = len(payload)
        t.addfile(info, None if info.issym() else io.BytesIO(payload))
os.chmod(bad_link, 0o600)
if invoke(['import', '--input', bad_link], [], target_home) != 2:
    print('FAIL link archive'); sys.exit(1)
bad_device = os.path.join(root, 'device.age')
with tarfile.open(bad_device, 'w') as t:
    for name, payload in members:
        info = tarfile.TarInfo(name)
        if name == members[-1][0]:
            info.type = tarfile.CHRTYPE
        else:
            info.size = len(payload)
        t.addfile(info, None if info.ischr() else io.BytesIO(payload))
os.chmod(bad_device, 0o600)
if invoke(['import', '--input', bad_device], [], target_home) != 2:
    print('FAIL device archive'); sys.exit(1)
for label, payload in [('truncated', open(package, 'rb').read()[:100]),
                       ('tampered', b'X' + open(package, 'rb').read()[1:]),
                       ('oversized', b'x' * (32 * 1024 * 1024 + 1))]:
    bad = os.path.join(root, label + '.age')
    with open(bad, 'wb') as f: f.write(payload)
    os.chmod(bad, 0o600)
    if invoke(['import', '--input', bad], [], target_home) != 2:
        print('FAIL', label); sys.exit(1)
print('PASS mocked link/device/tampered/truncated/oversized rejection')
name = 'id_ed25519'
for suffix in ('', '.pub'):
    os.unlink(os.path.join(target_home, '.ssh', name + suffix))
subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f',
                os.path.join(target_home, '.ssh', name)], check=True,
               stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
if invoke(['import', '--input', package], [], target_home) != 1:
    print('FAIL target conflict'); sys.exit(1)
print('PASS target conflict blocks package')
site = os.path.join(root, 'site')
os.mkdir(site, 0o700)
with open(os.path.join(site, 'sitecustomize.py'), 'w') as f:
    f.write('''import os
_open = os.open
_lstat = os.lstat
_link = os.link
_postlink_failed = False
def blocked(path, flags, *args, **kwargs):
    wanted = os.environ.get('MIGRATION_TEST_FAIL_PUB')
    if wanted and (path == wanted or (path == os.path.basename(wanted) and kwargs.get('dir_fd') is not None)) and flags & os.O_EXCL:
        raise OSError('injected publication failure')
    concurrent = os.environ.get('MIGRATION_TEST_CONCURRENT_TARGET')
    if concurrent and path == 'id_ecdsa.pub' and flags & os.O_EXCL and kwargs.get('dir_fd') is not None:
        with os.fdopen(_open(os.path.join(concurrent, '.ssh', path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as f:
            f.write(b'concurrent')
        os.environ.pop('MIGRATION_TEST_CONCURRENT_TARGET', None)
    swap = os.environ.get('MIGRATION_TEST_SWAP_DIR')
    if swap and path == 'id_ecdsa' and flags & os.O_EXCL and kwargs.get('dir_fd') is not None:
        os.rename(os.path.join(swap, '.ssh'), os.path.join(swap, '.ssh-old'))
        os.symlink(os.path.join(swap, 'alternate'), os.path.join(swap, '.ssh'))
        os.environ.pop('MIGRATION_TEST_SWAP_DIR', None)
    source = os.environ.get('MIGRATION_TEST_SWAP_SOURCE')
    if source and (path == source or (path == os.path.basename(source) and kwargs.get('dir_fd') is not None)) and flags & os.O_NOFOLLOW:
        os.rename(source, source + '.prior')
        os.symlink(os.environ['MIGRATION_TEST_OTHER_SOURCE'], source)
        os.environ.pop('MIGRATION_TEST_SWAP_SOURCE', None)
    package = os.environ.get('MIGRATION_TEST_SWAP_PACKAGE')
    if package and (path == package or (path == os.path.basename(package) and kwargs.get('dir_fd') is not None)) and flags & os.O_NOFOLLOW:
        os.rename(package, package + '.prior')
        os.symlink(os.environ['MIGRATION_TEST_OTHER_PACKAGE'], package)
        os.environ.pop('MIGRATION_TEST_SWAP_PACKAGE', None)
    return _open(path, flags, *args, **kwargs)
def broken_lstat(path, *args, **kwargs):
    global _postlink_failed
    output = os.environ.get('MIGRATION_TEST_FAIL_POSTLINK')
    if output and path == output and not _postlink_failed and os.path.exists(path):
        _postlink_failed = True
        raise OSError('injected postlink failure')
    return _lstat(path, *args, **kwargs)
def concurrent_link(source, target, *args, **kwargs):
    expected = os.environ.get('MIGRATION_TEST_CONCURRENT_EXPORT')
    if expected and (target == expected or (target == os.path.basename(expected) and kwargs.get('dst_dir_fd') is not None)):
        with os.fdopen(_open(expected, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), 'wb') as f:
            f.write(b'concurrent')
        os.environ.pop('MIGRATION_TEST_CONCURRENT_EXPORT', None)
    return _link(source, target, *args, **kwargs)
os.open = blocked
os.lstat = broken_lstat
os.link = concurrent_link
''')
rollback_home = os.path.join(root, 'rollback-home')
os.mkdir(rollback_home, 0o700)
os.environ['PYTHONPATH'] = site
os.environ['MIGRATION_TEST_FAIL_PUB'] = os.path.join(rollback_home, '.ssh', 'id_ecdsa.pub')
rollback_status = invoke(['import', '--input', package], [(b'Type import', b'import')], rollback_home)
if rollback_status != 2:
    print('FAIL publication failure status', rollback_status); sys.exit(1)
if os.path.exists(os.path.join(rollback_home, '.ssh')):
    print('FAIL publication rollback'); sys.exit(1)
print('PASS injected publication failure rollback')
os.environ.pop('MIGRATION_TEST_FAIL_PUB', None)
concurrent_home = os.path.join(root, 'concurrent-home')
os.mkdir(concurrent_home, 0o700)
os.mkdir(os.path.join(concurrent_home, '.ssh'), 0o700)
os.environ['MIGRATION_TEST_CONCURRENT_TARGET'] = concurrent_home
if invoke(['import', '--input', package], [(b'Type import', b'import')], concurrent_home) != 1:
    print('FAIL concurrent target status'); sys.exit(1)
if os.path.exists(os.path.join(concurrent_home, '.ssh', 'id_ecdsa')) or open(os.path.join(concurrent_home, '.ssh', 'id_ecdsa.pub'), 'rb').read() != b'concurrent':
    print('FAIL concurrent target preservation'); sys.exit(1)
print('PASS concurrent target remains untouched')
unsafe_home = os.path.join(root, 'unsafe-home')
os.mkdir(unsafe_home, 0o700)
os.mkdir(os.path.join(unsafe_home, '.ssh'), 0o755)
os.chmod(os.path.join(unsafe_home, '.ssh'), 0o755)
if invoke(['import', '--input', package], [], unsafe_home) != 1:
    print('FAIL unsafe target directory status'); sys.exit(1)
print('PASS unsafe target directory is conflict')
linked_target_home = os.path.join(root, 'linked-target-home')
os.mkdir(linked_target_home, 0o700)
os.symlink(os.path.join(source_home, '.ssh'), os.path.join(linked_target_home, '.ssh'))
if invoke(['import', '--input', package], [], linked_target_home) != 1:
    print('FAIL symlink target directory status'); sys.exit(1)
print('PASS symlink target directory is conflict')
swap_home = os.path.join(root, 'swap-home')
os.mkdir(swap_home, 0o700)
os.mkdir(os.path.join(swap_home, 'alternate'), 0o700)
os.environ['MIGRATION_TEST_SWAP_DIR'] = swap_home
if invoke(['import', '--input', package], [(b'Type import', b'import')], swap_home) != 1:
    print('FAIL target directory swap status'); sys.exit(1)
if os.listdir(os.path.join(swap_home, 'alternate')) or os.listdir(os.path.join(swap_home, '.ssh-old')):
    print('FAIL target directory swap wrote files'); sys.exit(1)
print('PASS target directory swap is blocked')
source_swap_home = os.path.join(root, 'source-swap-home')
os.mkdir(source_swap_home, 0o700)
os.mkdir(os.path.join(source_swap_home, '.ssh'), 0o700)
source_swap = os.path.join(source_swap_home, '.ssh', 'id_swap')
subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', source_swap],
               check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
os.environ['MIGRATION_TEST_SWAP_SOURCE'] = source_swap
os.environ['MIGRATION_TEST_OTHER_SOURCE'] = os.path.join(source_home, '.ssh', 'id_rsa')
if invoke(['list'], [], source_swap_home) != 0 or b'id_swap ssh-' in last_output:
    print('FAIL source symlink swap'); sys.exit(1)
print('PASS source symlink swap is excluded')
os.environ.pop('MIGRATION_TEST_OTHER_SOURCE', None)
package_swap = os.path.join(root, 'package-swap.age')
with open(package_swap, 'wb') as f:
    f.write(open(package, 'rb').read())
os.chmod(package_swap, 0o600)
os.environ['MIGRATION_TEST_SWAP_PACKAGE'] = package_swap
os.environ['MIGRATION_TEST_OTHER_PACKAGE'] = package
package_swap_home = os.path.join(root, 'package-swap-home')
os.mkdir(package_swap_home, 0o700)
if invoke(['import', '--input', package_swap], [], package_swap_home) != 2:
    print('FAIL package symlink swap'); sys.exit(1)
if os.path.lexists(os.path.join(package_swap_home, '.ssh')):
    print('FAIL package swap changed target'); sys.exit(1)
os.environ.pop('MIGRATION_TEST_OTHER_PACKAGE', None)
print('PASS package symlink swap is rejected')
postlink = os.path.join(root, 'postlink.age')
os.environ['MIGRATION_TEST_FAIL_POSTLINK'] = postlink
if invoke(['export', '--output', postlink],
          [(b'Select numbers', b'1'), (b'Type export', b'export')], source_home) != 2:
    print('FAIL postlink failure status'); sys.exit(1)
if os.path.lexists(postlink):
    print('FAIL postlink cleanup'); sys.exit(1)
print('PASS postlink failure removes own package')
os.environ.pop('MIGRATION_TEST_FAIL_POSTLINK', None)
concurrent_export = os.path.join(root, 'concurrent-export.age')
os.environ['MIGRATION_TEST_CONCURRENT_EXPORT'] = concurrent_export
if invoke(['export', '--output', concurrent_export],
          [(b'Select numbers', b'1'), (b'Type export', b'export')], source_home) != 1:
    print('FAIL concurrent export status'); sys.exit(1)
if open(concurrent_export, 'rb').read() != b'concurrent':
    print('FAIL concurrent export preservation'); sys.exit(1)
print('PASS concurrent export destination preserved')
os.environ.pop('PYTHONPATH', None)
protected_home = os.path.join(root, 'protected-home')
os.mkdir(protected_home, 0o700)
os.mkdir(os.path.join(protected_home, '.ssh'), 0o700)
protected = os.path.join(protected_home, '.ssh', 'id_protected')
phrase = b'fixture-only-passphrase'
if execute(['ssh-keygen', '-q', '-t', 'ed25519', '-f', protected],
           [(b'Enter passphrase', phrase), (b'Enter same passphrase', phrase)], protected_home):
    print('FAIL protected fixture generation'); sys.exit(1)
if invoke(['list'], [(b'SSH key passphrase', phrase)], protected_home):
    print('FAIL protected identity validation'); sys.exit(1)
wrong_ssh_phrase = b'wrong-fixture-only-passphrase'
if invoke(['list'], [(b'SSH key passphrase', wrong_ssh_phrase),
                     (b'SSH key passphrase', phrase)], protected_home) or \
        b'id_protected ssh-ed25519 SHA256:' not in last_output or \
        last_output.count(b'SSH key passphrase was not accepted') != 1:
    print('FAIL protected identity retry recovery'); sys.exit(1)
print('PASS protected identity unlock retry recovers')
if invoke(['list'], [(b'SSH key passphrase', wrong_ssh_phrase)] * 3, protected_home) or \
        b'id_protected ssh-ed25519 SHA256:' in last_output or \
        b'Excluded: SSH key could not be unlocked after 3 attempts' not in last_output or \
        last_output.count(b'SSH key passphrase:') != 3:
    print('FAIL protected identity retry exhaustion'); sys.exit(1)
print('PASS protected identity unlock retry exhaustion')
failed_keygen_dir = os.path.join(root, 'failed-keygen-bin')
os.mkdir(failed_keygen_dir, 0o700)
failed_keygen = os.path.join(failed_keygen_dir, 'ssh-keygen')
with open(failed_keygen, 'w') as stub:
    stub.write('#!/bin/sh\nprintf x >> "$MIGRATION_TEST_COUNTER"\nexit 255\n')
os.chmod(failed_keygen, 0o700)
counter = os.path.join(root, 'failed-keygen-count')
original_path = os.environ['PATH']
os.environ['PATH'] = failed_keygen_dir + os.pathsep + original_path
os.environ['MIGRATION_TEST_COUNTER'] = counter
generic_failure_status = invoke(['list'], [], protected_home)
os.environ['PATH'] = original_path
os.environ.pop('MIGRATION_TEST_COUNTER')
if generic_failure_status or open(counter, 'rb').read() != b'x' or \
        b'id_protected ssh-ed25519 SHA256:' in last_output or \
        b'SSH key passphrase was not accepted' in last_output:
    print('FAIL non-passphrase validation retried'); sys.exit(1)
print('PASS non-passphrase validation fails closed without retry')
if invoke(['export', '--output', os.path.join(root, 'retry-protected.age')],
          [(b'SSH key passphrase', wrong_ssh_phrase), (b'SSH key passphrase', phrase),
           (b'Select numbers', b'')], protected_home) != 1 or \
        b'id_protected ssh-ed25519 SHA256:' not in last_output or \
        os.path.lexists(os.path.join(root, 'retry-protected.age')):
    print('FAIL protected export candidate retry'); sys.exit(1)
print('PASS protected export candidate unlock retry')
for attempt in range(10):
    if invoke(['list'], [(b'SSH key passphrase', phrase)], protected_home) or \
            b'id_protected ssh-ed25519 SHA256:' not in last_output:
        print('FAIL repeated protected identity validation'); sys.exit(1)
    if invoke(['export', '--output', os.path.join(root, 'cancelled-protected.age')],
              [(b'SSH key passphrase', phrase), (b'Select numbers', b'')], protected_home) != 1 or \
            b'id_protected ssh-ed25519 SHA256:' not in last_output:
        print('FAIL repeated protected export candidate validation'); sys.exit(1)
if os.path.lexists(os.path.join(root, 'cancelled-protected.age')):
    print('FAIL cancelled protected export published'); sys.exit(1)
print('PASS repeated protected list/export candidate validation')
protected_package = os.path.join(root, 'protected.age')
if invoke(['export', '--output', protected_package],
          [(b'SSH key passphrase', phrase), (b'Select numbers', b'1'),
           (b'SSH key passphrase', phrase), (b'Type export', b'export')], protected_home):
    print('FAIL protected identity export'); sys.exit(1)
protected_target = os.path.join(root, 'protected-target')
os.mkdir(protected_target, 0o700)
if invoke(['import', '--input', protected_package],
          [(b'SSH key passphrase', phrase), (b'Type import', b'import'),
           (b'SSH key passphrase', phrase)], protected_target):
    print('FAIL protected identity import'); sys.exit(1)
print('PASS protected identity mock export/import')
if set(glob.glob('/private/tmp/ssh-migrate-*')) != temp_before:
    print('FAIL normal temporary cleanup'); sys.exit(1)
os.environ['MIGRATION_TEST_HANG'] = os.path.join(root, 'age-started')
interrupted_package = os.path.join(root, 'interrupted.age')
interrupted_status = invoke(['export', '--output', interrupted_package],
       [(b'SSH key passphrase', phrase), (b'Select numbers', b'1'),
        (b'SSH key passphrase', phrase), (b'Type export', b'export')], protected_home)
time.sleep(.5)
if interrupted_status != 130:
    print('FAIL interrupted export status'); sys.exit(1)
if os.path.lexists(interrupted_package):
    print('FAIL interrupted export published'); sys.exit(1)
if real_age:
    mocked_path = os.path.dirname(shutil.which('age'))
    os.environ['PATH'] = os.pathsep.join(p for p in os.environ['PATH'].split(os.pathsep) if p != mocked_path)
    resolved = shutil.which('age')
    if not resolved or os.path.realpath(resolved) != os.path.realpath(real_age):
        print('FAIL production age path'); sys.exit(1)
    print('PASS production CLI resolves real age')
    age_phrase = b'fixture-only-passphrase-age'
    wrong_phrase = b'wrong-fixture-only-passphrase'
    real_package = os.path.join(root, 'real.age')
    real_export_status = invoke(['export', '--output', real_package],
              [(b'Select numbers', b'1,2,3'), (b'Type export', b'export'),
               (b'Enter passphrase', age_phrase), (b'Confirm passphrase', age_phrase)], source_home)
    if real_export_status:
        print('FAIL real age encryption', real_export_status,
              'enter=', b'Enter passphrase' in last_output,
              'confirm=', b'Confirm passphrase' in last_output,
              'crypto-error=', b'encryption failed' in last_output); sys.exit(1)
    with open(real_package, 'rb') as package_file:
        ciphertext_header = package_file.read(64)
    if not ciphertext_header.startswith(b'age-encryption.org/v1\n') or b'BEGIN OPENSSH' in ciphertext_header:
        print('FAIL real age ciphertext header'); sys.exit(1)
    real_target = os.path.join(root, 'real-target')
    os.mkdir(real_target, 0o700)
    if invoke(['import', '--input', real_package],
              [(b'Enter passphrase', age_phrase), (b'Type import', b'import')], real_target):
        print('FAIL real age decryption/import'); sys.exit(1)
    for identity in ('id_ed25519', 'id_ecdsa', 'id_rsa'):
        for suffix in ('', '.pub'):
            with open(os.path.join(source_home, '.ssh', identity + suffix), 'rb') as source_file:
                source_hash = hashlib.sha256(source_file.read()).digest()
            with open(os.path.join(real_target, '.ssh', identity + suffix), 'rb') as target_file:
                target_hash = hashlib.sha256(target_file.read()).digest()
            if source_hash != target_hash:
                print('FAIL real age round-trip bytes'); sys.exit(1)
    print('PASS real age encrypted round-trip')
    wrong_target = os.path.join(root, 'wrong-age-target')
    os.mkdir(wrong_target, 0o700)
    if invoke(['import', '--input', real_package], [(b'Enter passphrase', wrong_phrase)], wrong_target) != 2:
        print('FAIL wrong age passphrase status'); sys.exit(1)
    if os.path.lexists(os.path.join(wrong_target, '.ssh')):
        print('FAIL wrong age passphrase changed target'); sys.exit(1)
    print('PASS wrong age passphrase rejected before mutation')
    real_protected_package = os.path.join(root, 'real-protected.age')
    if invoke(['export', '--output', real_protected_package],
              [(b'SSH key passphrase', phrase), (b'Select numbers', b'1'),
               (b'SSH key passphrase', phrase), (b'Type export', b'export'),
               (b'Enter passphrase', age_phrase), (b'Confirm passphrase', age_phrase)], protected_home):
        print('FAIL real age protected identity export'); sys.exit(1)
    if last_output.count(b'SSH key passphrase:') != 2:
        print('FAIL standalone export did not independently revalidate selected key'); sys.exit(1)
    real_protected_target = os.path.join(root, 'real-protected-target')
    os.mkdir(real_protected_target, 0o700)
    if invoke(['import', '--input', real_protected_package],
              [(b'Enter passphrase', age_phrase), (b'SSH key passphrase', phrase),
               (b'Type import', b'import'), (b'SSH key passphrase', phrase)], real_protected_target):
        print('FAIL real age protected identity import'); sys.exit(1)
    for suffix in ('', '.pub'):
        with open(protected + suffix, 'rb') as source_file:
            source_hash = hashlib.sha256(source_file.read()).digest()
        with open(os.path.join(real_protected_target, '.ssh', 'id_protected' + suffix), 'rb') as target_file:
            target_hash = hashlib.sha256(target_file.read()).digest()
        if source_hash != target_hash:
            print('FAIL real age protected identity bytes'); sys.exit(1)
    print('PASS real age passphrase-protected SSH identity round-trip')
    capture_package = os.path.join(root, 'capture-protected.age')
    if invoke(['capture-export', '--output', capture_package],
              [(b'Select numbers', b'1'), (b'Type export', b'export'),
               (b'SSH key passphrase', phrase), (b'Enter passphrase', age_phrase),
               (b'Confirm passphrase', age_phrase)], protected_home) or \
            last_output.count(b'SSH key passphrase:') != 1 or \
            b'NEW Secure Credentials passphrase' not in last_output or \
            age_phrase in last_output:
        print('FAIL Capture export single unlock and manual passphrase UX'); sys.exit(1)
    print('PASS Capture export unlocks selected protected identity once and hides manual passphrase')
    mismatch_home = os.path.join(root, 'capture-mismatch-home')
    os.mkdir(mismatch_home, 0o700)
    os.mkdir(os.path.join(mismatch_home, '.ssh'), 0o700)
    mismatch_key = os.path.join(mismatch_home, '.ssh', 'id_ed25519')
    shutil.copyfile(os.path.join(source_home, '.ssh', 'id_ed25519'), mismatch_key)
    shutil.copyfile(os.path.join(source_home, '.ssh', 'id_rsa.pub'), mismatch_key + '.pub')
    os.chmod(mismatch_key, 0o600)
    os.chmod(mismatch_key + '.pub', 0o644)
    mismatch_package = os.path.join(root, 'capture-mismatch.age')
    if invoke(['capture-export', '--output', mismatch_package],
              [(b'Select numbers', b'1'), (b'Type export', b'export')], mismatch_home) != 2 or os.path.lexists(mismatch_package):
        print('FAIL Capture selected pair was not fully validated'); sys.exit(1)
    print('PASS Capture rejects candidate with mismatched staged key pair before packaging')
    autogenerated_package = os.path.join(root, 'capture-autogenerated.age')
    if invoke(['capture-export', '--output', autogenerated_package],
              [(b'Select numbers', b'1'), (b'Type export', b'export'),
               (b'Enter passphrase', b'')], source_home):
        print('FAIL Capture autogenerated passphrase export'); sys.exit(1)
    generated_lines = [line for line in last_output.splitlines() if b'using autogenerated' in line]
    if len(generated_lines) != 1 or b'Save it separately from the Bundle' not in last_output:
        print('FAIL autogenerated passphrase display and save warning'); sys.exit(1)
    generated_phrase = generated_lines[0].split()[-1]
    if len(generated_phrase) < 20 or generated_phrase in open(autogenerated_package, 'rb').read():
        print('FAIL autogenerated passphrase leaked into encrypted package'); sys.exit(1)
    print('PASS autogenerated passphrase displayed once with save warning and absent from ciphertext')
else:
    print('SKIP real age integration: age absent')
if set(glob.glob('/private/tmp/ssh-migrate-*')) != temp_before:
    print('FAIL temporary cleanup'); sys.exit(1)
print('PASS interrupted cleanup and secret output check')
PY
[[ $? -eq 0 ]] || failed=$((failed+1))
if rg -q 'BEGIN OPENSSH PRIVATE KEY|ssh-ed25519 [A-Za-z0-9+/]{30}' "$TEST_ROOT/out"; then
    printf 'FAIL secret output\n'; failed=$((failed+1))
fi
[[ $failed -eq 0 ]]
