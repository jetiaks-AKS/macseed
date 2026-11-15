"""Read-only IdentityFile qualification, separate from configuration conformity.

Profiles, references and evidence stay process-private. Only projection() may be
sent to ordinary Protocol events. This module never authenticates a remote host,
unlocks a protected key, or authorizes configuration publication/import.
"""
import errno
import hashlib
import os
from pathlib import Path
import stat
import subprocess
import sys
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'migration'))
from external_sources import ExternalSourceError, NAME, RESERVED, paths, read_pair, stamp
from restore_destinations import Directory, digest, safe_acl, selected_items
from secret_input import PrivateTemporaryDirectory, SecureError
from config import identity_path, snapshot

MAX_LOCATIONS = 32
MAX_ENTRIES = 4096
SECONDS = 5
TYPES = {b'ssh-ed25519', b'ssh-rsa', b'ecdsa-sha2-nistp256',
         b'ecdsa-sha2-nistp384', b'ecdsa-sha2-nistp521'}
REASONS = {'explicit_none', 'no_explicit_reference', 'nonportable_reference', 'observation_limit',
           'checked_absent', 'observation_changed', 'unsupported_identity', 'unsafe_pair', 'unsafe_path',
           'observation_unavailable', 'ambiguous_destination', 'selected_target_conflict',
           'selected_target_unqualified', 'authenticated_destination', 'verified_import_pair',
           'authenticated_pair_requires_unlock', 'locked_or_invalid_identity', 'pair_mismatch',
           'local_pair_qualified', 'approved_local_key_unqualified', 'approved_identity_destination_changed',
           'approved_identity_unavailable'}


def collision(directory, names):
    """Bounded direct-name check; never discover keys or descend directories."""
    with os.scandir(directory.fd) as entries:
        for index, entry in enumerate(entries):
            if index >= MAX_ENTRIES:
                raise TimeoutError()
            if any(entry.name.casefold() == name.casefold() and entry.name != name for name in names):
                raise SecureError('secure_target_conflict')


def observe(path, *, public_only=False):
    """Return checked absence or safe pair evidence, optionally without private bytes."""
    paths([str(path)])
    if (not NAME.fullmatch(path.name) or path.name.lower().endswith('.pub')
            or path.name.casefold() in RESERVED):
        raise ExternalSourceError('external_identity_name_invalid')
    parent = path.parent
    while not os.path.lexists(parent):
        parent = parent.parent
    with Directory(str(parent)) as directory:
        relative = path.relative_to(parent)
        first = relative.parts[0]
        collision(directory, (first, first + '.pub') if len(relative.parts) == 1 else (first,))
        present = []
        for name in ((first, first + '.pub') if len(relative.parts) == 1 else (first,)):
            try:
                os.stat(name, dir_fd=directory.fd, follow_symlinks=False)
                present.append(True)
            except FileNotFoundError:
                present.append(False)
        if not any(present):
            directory.check()
            # An observed absence must still be visible at the pinned location.
            for name in ((first, first + '.pub') if len(relative.parts) == 1 else (first,)):
                try:
                    os.stat(name, dir_fd=directory.fd, follow_symlinks=False)
                except FileNotFoundError:
                    continue
                raise SecureError('secure_target_changed')
            return None, digest([str(path), [(str(p), s) for p, s in directory.visible], 'absent'])
        if len(relative.parts) != 1 or not all(present):
            raise SecureError('secure_target_conflict')
        metadata = []
        for name in (first, first + '.pub'):
            fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=directory.fd)
            try:
                info = os.fstat(fd)
                if not stat.S_ISREG(info.st_mode):
                    raise SecureError('secure_target_conflict')
                safe_acl(fd)
                metadata.append(stamp(info))
            finally:
                os.close(fd)
        _, private, public, binding = read_pair(str(path), public_only=public_only)
        if metadata != [stamp(os.stat(name, dir_fd=directory.fd, follow_symlinks=False))
                        for name in (first, first + '.pub')]:
            raise SecureError('secure_target_changed')
        directory.check()
        return (private, public), digest([binding, [(str(p), s) for p, s in directory.visible]])


def qualify(pair, deadline):
    """Prove an unprotected local pair without prompts or source paths in argv."""
    private, public = pair
    if (not private.startswith(b'-----BEGIN OPENSSH PRIVATE KEY-----')
            or len(public.splitlines()) != 1 or len(public.split()) < 2
            or public.split()[0] not in TYPES):
        return 'unresolved', 'unsupported_identity'
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError()
    with PrivateTemporaryDirectory(prefix='macseed-dependency-', dir='/private/tmp') as temporary:
        candidate = Path(temporary) / 'identity'
        with candidate.open('xb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(private)
        # An empty passphrase is explicit; stdin/askpass/agent cannot unlock a key.
        result = subprocess.run(['/usr/bin/ssh-keygen', '-y', '-P', '', '-f', str(candidate)],
                                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C',
                                     'SSH_ASKPASS_REQUIRE': 'never'}, timeout=remaining,
                                start_new_session=True)
    if result.returncode:
        return 'unresolved', 'locked_or_invalid_identity'
    if result.stdout.split()[:2] != public.split()[:2]:
        return 'unsafe_target', 'pair_mismatch'
    return 'local_satisfied', 'local_pair_qualified'


def agent_socket():
    """Bind the runtime's explicit socket inside an owned, private directory."""
    value = os.environ.get('SSH_AUTH_SOCK', '')
    if (not value.startswith('/') or len(value.encode()) > 1024 or str(Path(value)) != value
            or '..' in Path(value).parts or any(ord(c) < 32 or ord(c) == 127 for c in value)):
        raise OSError('agent unavailable')
    path = Path(value)
    aliases = []
    # launchd publishes /tmp/... on macOS. Admit only the two root-owned OS
    # aliases, retaining their metadata in the binding; arbitrary links stay
    # forbidden by the canonical path and no-follow checks below.
    if len(path.parts) > 2 and path.parts[1] in ('tmp', 'var'):
        alias = Path('/') / path.parts[1]
        info = alias.lstat()
        if stat.S_ISLNK(info.st_mode):
            target = 'private/' + path.parts[1]
            if info.st_uid != 0 or os.readlink(alias) not in (target, '/' + target):
                raise OSError('unsafe agent path alias')
            aliases = [str(alias), stamp(info), target]
            path = Path('/private').joinpath(*path.parts[1:])
    parent = str(path.parent)
    if os.path.realpath(parent) != parent:
        raise OSError('unsafe agent path')
    # This is read-only IPC, not a key publication destination. macOS runtime
    # directories can be root-owned and system-group-writable (e.g. /var/run).
    # Require an owned private immediate directory, pin its identity, and bind
    # every ancestor; possession is independently proven by the signature.
    ancestors = []
    for ancestor in reversed(path.parent.parents):
        info = ancestor.lstat()
        shared = info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o1777
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid not in (0, os.getuid())
                or (info.st_mode & 0o002 and not shared)
                or (info.st_mode & 0o020 and info.st_uid != 0)):
            raise OSError('unsafe agent ancestor')
        ancestors.append((str(ancestor), Directory.stamp(info)))
    fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        before = os.fstat(fd)
        if before.st_uid != os.getuid() or stat.S_IMODE(before.st_mode) != 0o700:
            raise OSError('agent directory is not private')
        safe_acl(fd)
        info = os.stat(path.name, dir_fd=fd, follow_symlinks=False)
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid() or info.st_nlink != 1:
            raise OSError('unsafe agent socket')
        if (Directory.stamp(os.lstat(parent)) != Directory.stamp(before)
                or any(Directory.stamp(os.lstat(p)) != expected for p, expected in ancestors)
                or stamp(os.lstat(path)) != stamp(info)):
            raise OSError('agent path changed')
        return value, digest([value, aliases, stamp(info), Directory.stamp(before), ancestors])
    finally:
        os.close(fd)


def qualify_agent(path, deadline):
    """Prove possession of the explicit public key with a fresh sign/verify test.

    Git-only opt-in. No key listing, private bytes, unlock, agent mutation or
    remote authentication. The stable endpoint/file binding enters the existing
    Prepare fingerprint; every later admission repeats the cryptographic proof.
    """
    try:
        socket, agent_binding = agent_socket()
    except (OSError, SecureError):
        return None
    pair, binding = observe(path, public_only=True)
    if not pair:
        return None
    public = pair[1]
    if len(public.splitlines()) != 1 or len(public.split()) < 2 or public.split()[0] not in TYPES:
        return None
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError()
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'core/application-interface'))
    from observation import read
    with PrivateTemporaryDirectory(prefix='macseed-agent-proof-', dir='/private/tmp') as temporary:
        candidate = Path(temporary) / 'identity.pub'
        with candidate.open('xb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(public)
        result = read(['/usr/bin/ssh-add', '-T', str(candidate)], timeout=remaining,
                      env={'PATH': '/usr/bin:/bin', 'LC_ALL': 'C', 'SSH_AUTH_SOCK': socket,
                           'SSH_ASKPASS_REQUIRE': 'never', 'SSH_ASKPASS': '/usr/bin/false'})
    if result.returncode:
        return None
    if agent_socket() != (socket, agent_binding) or observe(path, public_only=True)[1] != binding:
        raise SecureError('secure_target_changed')
    return dict(status='local_satisfied', reason='agent_key_qualified', binding=binding,
                pair_digest=None, agent_binding=agent_binding,
                public_digest=hashlib.sha256(public).hexdigest())


def assess(raw, home, *, authenticated=(), destinations=None, approved_paths=(), verified_import=False,
           agent_references=()):
    """Assess a validated, already narrowed snapshot; never trust inventory files.

    authenticated is supplied only by the live successful Compare/import bridge,
    after full package validation and selected-target checks. verified_import
    additionally requires a validated cryptographic import receipt. No cross-run cache.
    agent_references defaults off for configuration/Check; Git opts in with None
    initially, then only the exact references already qualified through its agent.
    """
    _, _, _, profiles = snapshot(raw)
    intended = {}
    selected = ({row['identity_id']: row['directory'] for row in selected_items(destinations)}
                if destinations is not None else None)
    for row in authenticated:
        if selected is not None and row['identity_id'] not in selected:
            continue
        directory = selected[row['identity_id']] if selected is not None else None
        path = str(Path(directory or str(Path(home) / '.ssh')) / row['name'])
        intended.setdefault(path, []).append(row)
    locations, rows = {}, []
    deadline = time.monotonic() + SECONDS
    for host, entries in profiles.items():
        references = [value for key, value in entries if key == 'identityfile']
        findings = []
        for reference in references:
            kind = identity_path(reference)
            if kind == 'none':
                findings.append(dict(reference=reference, status='no_file_dependency', reason='explicit_none'))
                continue
            if kind != 'portable' and reference not in approved_paths:
                findings.append(dict(reference=reference, status='unresolved', reason='nonportable_reference'))
                continue
            path = str(Path(home) / reference[2:]) if kind == 'portable' else reference
            if path not in locations:
                status, reason, binding = 'unresolved', 'observation_limit', None
                pair_digest = None
                agent = None
                if len(locations) < MAX_LOCATIONS and time.monotonic() < deadline:
                    try:
                        if agent_references is None or reference in agent_references:
                            agent = qualify_agent(Path(path), deadline)
                        if agent is None:
                            pair, binding = observe(Path(path))
                            pair_digest = [hashlib.sha256(raw).hexdigest() for raw in pair] if pair else None
                            status, reason = qualify(pair, deadline) if pair else ('missing', 'checked_absent')
                            if observe(Path(path))[1] != binding:
                                status, reason, binding = 'unresolved', 'observation_changed', None
                    except (TimeoutError, subprocess.TimeoutExpired):
                        status, reason, binding = 'unresolved', 'observation_limit', None
                    except ExternalSourceError as exc:
                        unresolved = {'external_identity_name_invalid', 'external_identity_invalid_request', 'external_identity_changed'}
                        status = 'unresolved' if exc.code in unresolved else 'unsafe_target'
                        reason = ('observation_changed' if exc.code == 'external_identity_changed' else
                                  'unsupported_identity' if status == 'unresolved' else 'unsafe_pair')
                    except SecureError as exc:
                        status = 'unresolved' if exc.code == 'secure_target_changed' else 'unsafe_target'
                        reason = 'observation_changed' if status == 'unresolved' else 'unsafe_path'
                    except OSError as exc:
                        status = 'unsafe_target' if exc.errno in (errno.ELOOP, errno.ENOTDIR) else 'unresolved'
                        reason = 'observation_unavailable'
                locations[path] = agent or dict(status=status, reason=reason, binding=binding, pair_digest=pair_digest)
            finding = dict(locations[path])
            matches = intended.get(path, [])
            if len(matches) > 1:
                finding.update(status='unresolved', reason='ambiguous_destination')
            elif matches:
                target = matches[0]['target']
                if finding['status'] == 'unsafe_target':
                    pass  # Fresh unsafe local evidence takes precedence over older Compare evidence.
                elif target == 'conflict':
                    finding.update(status='unsafe_target', reason='selected_target_conflict')
                elif target == 'unresolved':
                    finding.update(status='unresolved', reason='selected_target_unqualified')
                elif target == 'identical' and (finding.get('public_digest') != matches[0]['pair_digest'][1]
                        if finding['reason'] == 'agent_key_qualified' else finding['pair_digest'] != matches[0]['pair_digest']):
                    finding.update(status='unresolved', reason='observation_changed')
                elif target == 'create' and finding['status'] == 'missing':
                    finding.update(status='selected_expected', reason='authenticated_destination')
                elif target == 'identical' and finding['status'] == 'unresolved' and finding['reason'] == 'locked_or_invalid_identity':
                    finding.update(status='local_satisfied' if verified_import else 'selected_expected',
                                   reason='verified_import_pair' if verified_import else 'authenticated_pair_requires_unlock')
                elif ((target == 'create' and finding['status'] != 'missing')
                      or (target == 'identical' and finding['status'] == 'missing')):
                    finding.update(status='unresolved', reason='observation_changed')
            findings.append(dict(reference=reference, **finding))
        if not references:
            findings.append(dict(reference=None, status='no_file_dependency', reason='no_explicit_reference'))
        rows.append(dict(host=host, references=findings))
    return rows


def projection(rows):
    # No names, paths, identity IDs, fingerprints, counts or per-item correlation.
    return dict(version=1, findings=sorted({item['status'] for row in rows for item in row['references']}),
                reasons=sorted({item['reason'] for row in rows for item in row['references']} & REASONS))
