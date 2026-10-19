#!/usr/bin/env python3
"""Fixed local Debug deployment. Never runs application code as root."""
import hashlib
import os
import re
import plistlib
from pathlib import Path
import stat
import subprocess
import sys
import uuid

SOURCE = Path(__file__).resolve().parent / 'build/Debug/Macseed.app'
PARENT = Path('/Library/Application Support/MacseedDesktop')
APP = PARENT / 'Macseed.app'
STAGE = PARENT / '.incoming'
BACKUP = PARENT / 'Macseed.previous.app'
SERVICE = 'system/org.macseed.desktop.mas-helper'
CERT = 'E898826915F0BFAD30789097118EDBBF619BC07E'
COMPONENTS = {'': 'org.macseed.desktop', 'Contents/Helpers/MASHelper': 'org.macseed.desktop.mas-helper',
              'Contents/Helpers/MASClient': 'org.macseed.desktop.mas-client',
              'Contents/Helpers/mas': 'org.macseed.development.bundled-mas'}


def run(args, root=False):
    # Only Apple system utilities execute as root; this Python program never does.
    return subprocess.check_output((['/usr/bin/sudo', '--'] if root else []) + [str(x) for x in args], stderr=subprocess.STDOUT, timeout=120)


def require(ok, message):
    if not ok:
        raise RuntimeError(message)


def metadata(path):
    info = path.lstat()
    require(not path.is_symlink(), f'Symlink refused: {path}')
    require(stat.S_ISDIR(info.st_mode) or stat.S_ISREG(info.st_mode), 'Special object refused')
    require(not info.st_mode & 0o022, f'Writable object refused: {path}')
    require(len(run(['/bin/ls', '-lde', path]).splitlines()) == 1, f'ACL refused: {path}')
    return info


def protected_parent(path):
    for part in [*reversed(path.parents), path]:
        info = metadata(part)
        require(info.st_uid == 0 and stat.S_ISDIR(info.st_mode), f'Unprotected ancestor: {part}')


def manifest(app):
    result = {}
    for path in [app, *app.rglob('*')]:
        info = metadata(path)
        name = str(path.relative_to(app))
        mode = stat.S_IMODE(info.st_mode)
        expected = 0o755 if path.is_dir() or name in ['Contents/MacOS/Macseed', 'Contents/Helpers/MASHelper', 'Contents/Helpers/MASClient'] else 0o555 if name == 'Contents/Helpers/mas' else 0o644
        require(mode == expected, f'Unexpected mode: {path}')
        require(path.is_dir() or info.st_nlink == 1, f'Hard link refused: {path}')
        result[name] = (mode, hashlib.sha256(path.read_bytes()).hexdigest() if path.is_file() else None)
    return result


def verify(app, root=False):
    run(['/usr/bin/codesign', '--verify', '--deep', '--strict', app], root)
    for relative, identifier in COMPONENTS.items():
        requirement = f'=anchor apple generic and identifier "{identifier}" and certificate leaf = H"{CERT}"'
        run(['/usr/bin/codesign', '--verify', '--strict', '-R', requirement, app / relative], root)


def helper_loaded():
    p = subprocess.run(['/bin/launchctl', 'print', SERVICE], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
    if p.returncode == 0:
        return True
    require(p.returncode == 113, 'Cannot determine helper state')
    return False


def code_identity(path):
    # CMS signing time may change while executable CodeDirectory stays identical.
    text = run(['/usr/bin/codesign', '-d', '--verbose=4', path]).decode()
    matches = re.findall(r'^CDHash=([0-9a-f]+)$', text, re.MULTILINE)
    require(len(matches) == 1, 'Missing executable CodeDirectory identity')
    return matches[0]


def compatible(old, new):
    if code_identity(old / 'Contents/Helpers/MASHelper') != code_identity(new / 'Contents/Helpers/MASHelper'):
        return False
    for relative in ['Contents/Helpers/mas', 'Contents/Library/LaunchDaemons/org.macseed.desktop.mas-helper.plist']:
        if (old / relative).read_bytes() != (new / relative).read_bytes():
            return False
    return True


def parse_native_status(text):
    match = re.fullmatch(r'Native registration status=([0-3])', text.strip())
    require(match is not None, 'Cannot determine native registration: unexpected status response')
    return int(match.group(1))


def btm_helper_present(text):
    # dumpbtm is a diagnostic format, not a stable registration API. Fail closed
    # on missing UID sections; use only as corroboration of native notFound.
    require(re.search(r'(?m)^[ \t]*Records for UID -?[0-9]+[ \t]*:', text) is not None,
            'Cannot qualify native notFound: unrecognized BTM snapshot format')
    identifier = 'org.macseed.desktop.mas-helper'
    matches = re.findall(r'(?m)^\s*Identifier:\s*(\S+)\s*$', text)
    if any(re.sub(r'^[0-9]+\.', '', value) == identifier for value in matches):
        return True
    # An unclassified reference is uncertainty, never proof of absence.
    require(identifier not in text, 'Cannot qualify native notFound: unclassified BTM helper reference')
    return False


def registration_disposition(native, loaded, btm_present=None):
    if native == 0 and not loaded:
        return 'absent'
    if native == 3 and not loaded and btm_present is False:
        return 'absent'
    if native in (1, 2):
        return 'registered'
    raise RuntimeError(f'Cannot determine helper registration safely: native={native}, loaded={loaded}, BTM_present={btm_present}')


def deployment_registration(app, loaded):
    native = parse_native_status(run([app / 'Contents/MacOS/Macseed', '--mas-helper-status']).decode())
    btm = None
    if native == 3:
        daemon = plistlib.loads((app / 'Contents/Library/LaunchDaemons/org.macseed.desktop.mas-helper.plist').read_bytes())
        require(daemon.get('Label') == 'org.macseed.desktop.mas-helper'
                and daemon.get('BundleProgram') == 'Contents/Helpers/MASHelper'
                and daemon.get('MachServices') == {'org.macseed.desktop.mas-helper': True},
                'Native notFound with invalid daemon payload; repair packaging before deployment')
        btm = btm_helper_present(run(['/usr/bin/sfltool', 'dumpbtm'], root=True).decode())
    disposition = registration_disposition(native, loaded, btm)
    print(f'Helper registration: {disposition}; native={native}, loaded={loaded}, BTM_present={btm}')
    return disposition


def deploy():
    expected = manifest(SOURCE)
    verify(SOURCE)
    protected_parent(PARENT.parent)
    processes = run(['/bin/ps', '-axo', 'comm=']).decode().splitlines()
    require(not any(x.strip().endswith(('/Contents/MacOS/Macseed', '/Contents/Helpers/MASClient')) for x in processes), 'Quit Macseed before deployment')
    if PARENT.exists():
        protected_parent(PARENT)
    else:
        run(['/bin/mkdir', '-m', '0755', PARENT], True)
        run(['/usr/sbin/chown', 'root:wheel', PARENT], True)
    if APP.exists():
        protected_parent(APP)
        verify(APP)
        loaded = helper_loaded()
        registration = deployment_registration(APP, loaded)
        same_helper = compatible(APP, SOURCE)
        print(f'Helper deployment compatibility: {same_helper}')
        if registration == 'registered':
            require(same_helper,
                    'Registered helper is incompatible with this build; native unregister is required. Deployment stopped without changing registration or journals.')
            require(run([APP / 'Contents/Helpers/MASClient', 'deployment-status']).decode().strip() in ['ready', 'unavailable'],
                    'Registered compatible helper did not confirm idle ownership; deployment refused')

    else:
        require(not helper_loaded(), 'Unexpected helper registration; deployment refused')
    require(not BACKUP.is_symlink(), 'Backup symlink refused')
    if BACKUP.exists():
        protected_parent(BACKUP); verify(BACKUP)
        run(['/bin/mv', BACKUP, PARENT / ('Macseed.previous-' + str(uuid.uuid4()) + '.app')], True)
    # Exclusive root-only staging: even a racing source substitution cannot expose
    # copied data. Only the complete expected, signed snapshot can be published.
    run(['/bin/mkdir', '-m', '0700', STAGE], True)
    incoming = STAGE / 'Macseed.app'
    run(['/usr/bin/ditto', '--noextattr', '--noqtn', SOURCE, incoming], True)
    names = run(['/usr/bin/find', '-P', incoming, '-print0'], True).split(b'\0')[:-1]
    actual = set()
    for raw in names:
        path = Path(os.fsdecode(raw))
        relative = str(path.relative_to(incoming))
        require(relative in expected and '..' not in path.parts, 'Unexpected staged object; private staging retained')
        actual.add(relative)
        mode, digest = expected[relative]
        fields = run(['/usr/bin/stat', '-f', '%p %l', path], True).decode().split()
        staged_mode = int(fields[0], 8)
        require((stat.S_ISDIR(staged_mode) if digest is None else stat.S_ISREG(staged_mode)) and stat.S_IMODE(staged_mode) == mode, 'Staged type/mode mismatch')
        require(digest is None or fields[1] == '1', 'Staged hard link refused')
        require(len(run(['/bin/ls', '-lde', path], True).splitlines()) == 1, 'Staged ACL refused')
        if digest is not None:
            require(run(['/usr/bin/shasum', '-a', '256', path], True).decode().split()[0] == digest, 'Staged bytes changed')
    require(actual == set(expected), 'Incomplete snapshot')
    run(['/usr/sbin/chown', '-RP', 'root:wheel', incoming], True)
    verify(incoming, root=True)
    # A non-root source cannot change this staged snapshot after validation.
    if APP.exists():
        run(['/bin/mv', APP, BACKUP], True)
    try:
        run(['/bin/mv', incoming, APP], True)
    except Exception:
        if BACKUP.exists() and not APP.exists():
            run(['/bin/mv', BACKUP, APP], True)
        raise
    run(['/bin/rmdir', STAGE], True)
    print('Deployed. Registration and Restore were not started. Previous signed app retained for rollback.')


def main():
    require(os.geteuid() != 0, 'Run as the developer, never sudo this script')
    action = sys.argv[1] if len(sys.argv) == 2 else ''
    if action == 'status':
        print(f'build={SOURCE.exists()} installed={APP.exists()} helper_loaded={helper_loaded()} backup={BACKUP.exists()} staging={STAGE.exists()}')
        if APP.exists():
            protected_parent(APP); verify(APP)
            print('Installed signature/ancestry verified. Native registration status: Debug Settings → App Store Helper.')
    elif action == 'open':
        if APP.exists():
            protected_parent(APP); verify(APP)
            require(manifest(APP) == manifest(SOURCE), 'Installed app differs from the current build; deploy explicitly before opening it')
            run(['/usr/bin/open', APP])
        else:
            verify(SOURCE); run(['/usr/bin/open', SOURCE])
            print('Checkout GUI opened; privileged Restore requires protected deployment.')
    elif action == 'deploy':
        deploy()
    else:
        raise RuntimeError('Usage: python3 desktop/Macseed/develop.py status|open|deploy (deploy requires separate system approval)')


if __name__ == '__main__':
    try:
        main()
    except (RuntimeError, OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
        print(f'Refused: {error}', file=sys.stderr)
        sys.exit(2)
