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


def collision(directory, names):
    """Bounded direct-name check; never discover keys or descend directories."""
    with os.scandir(directory.fd) as entries:
        for index, entry in enumerate(entries):
            if index >= MAX_ENTRIES:
                raise TimeoutError()
            if any(entry.name.casefold() == name.casefold() and entry.name != name for name in names):
                raise SecureError('secure_target_conflict')


def observe(path):
    """Return checked absence or an exact, safely read pair and private binding."""
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
        _, private, public, binding = read_pair(str(path))
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


def assess(raw, home, *, authenticated=(), destinations=None):
    """Assess a validated, already narrowed snapshot; never trust inventory files.

    authenticated is supplied only by the live successful Secure Compare bridge,
    after full package validation and selected-target checks. No cross-run cache.
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
            if kind != 'portable':
                findings.append(dict(reference=reference, status='unresolved', reason='nonportable_reference'))
                continue
            path = str(Path(home) / reference[2:])
            if path not in locations:
                status, reason, binding = 'unresolved', 'observation_limit', None
                pair_digest = None
                if len(locations) < MAX_LOCATIONS and time.monotonic() < deadline:
                    try:
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
                locations[path] = dict(status=status, reason=reason, binding=binding, pair_digest=pair_digest)
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
                elif target == 'identical' and finding['pair_digest'] != matches[0]['pair_digest']:
                    finding.update(status='unresolved', reason='observation_changed')
                elif target == 'create' and finding['status'] == 'missing':
                    finding.update(status='selected_expected', reason='authenticated_destination')
                elif target == 'identical' and finding['status'] == 'unresolved' and finding['reason'] == 'locked_or_invalid_identity':
                    finding.update(status='selected_expected', reason='authenticated_pair_requires_unlock')
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
    return dict(version=1, findings=sorted({item['status'] for row in rows for item in row['references']}))
