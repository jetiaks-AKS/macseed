"""Read-only observations of explicitly selected, authenticated SSH pairs.

The caller authenticates saved bytes and validates public metadata through Secure
Migration first. Equality does not prove fresh private/public correspondence. This
module has no publication/import callbacks and never creates a target directory.
"""
import os
from pathlib import Path
import stat

from external_sources import ExternalSourceError, read_pair, stamp
from restore_destinations import Directory, digest, safe_acl
from secret_input import SecureError

REASONS = {
    'matching': {'pair_identical'},
    'missing': {'pair_absent'},
    'differing': {'private_bytes_differ', 'public_bytes_differ', 'pair_bytes_differ'},
    'unverified': {'partial_pair', 'unsafe_target', 'target_unavailable', 'target_changed'},
}


def result(kind, reason, state=None, private=None, public=None):
    return dict(comparison_kind=kind, reason=reason, target_state=state,
                private_bytes_match=private, public_bytes_match=public)


def valid_result(row):
    if not isinstance(row, dict) or set(row) != {'comparison_kind', 'reason', 'target_state', 'private_bytes_match', 'public_bytes_match'}:
        return False
    kind = row['comparison_kind']
    if kind not in REASONS or row['reason'] not in REASONS[kind]:
        return False
    from restore_destinations import HEX
    state = row['target_state']
    if state is not None and (not isinstance(state, str) or not HEX.fullmatch(state)):
        return False
    a, b = row['private_bytes_match'], row['public_bytes_match']
    if kind in ('matching', 'differing'):
        return (state is not None and type(a) is bool and type(b) is bool and ((a and b) == (kind == 'matching'))
                and row['reason'] == ('pair_identical' if a and b else 'pair_bytes_differ' if not a and not b
                                      else 'private_bytes_differ' if not a else 'public_bytes_differ'))
    return a is None and b is None and (kind != 'missing' or state is not None)


def visible(directory):
    return [[str(path), value] for path, value in directory.visible]


def observe(record, directory, home):
    """Safe absence, exact byte equality or a qualified mismatch; else unverified."""
    name, _, _, private, public = record
    default = directory is None
    directory = directory or str(Path(home) / '.ssh')
    try:
        # Reuse the destination contract, including ancestor pinning and ACLs.
        with Directory(home) as parent:
            home_before = stamp(os.fstat(parent.fd))
            if default:
                try:
                    os.stat('.ssh', dir_fd=parent.fd, follow_symlinks=False)
                except FileNotFoundError:
                    parent.check()
                    try:
                        os.stat('.ssh', dir_fd=parent.fd, follow_symlinks=False)
                    except FileNotFoundError:
                        if stamp(os.fstat(parent.fd)) != home_before:
                            return result('unverified', 'target_changed')
                        return result('missing', 'pair_absent', digest([directory, name, visible(parent), home_before, None]))
                    return result('unverified', 'target_changed')
            with Directory(directory) as target:
                before = stamp(os.fstat(target.fd))
                if default and stat.S_IMODE(os.fstat(target.fd).st_mode) != 0o700:
                    return result('unverified', 'unsafe_target')
                with os.scandir(target.fd) as entries:
                    for index, entry in enumerate(entries):
                        if index >= 8192 or any(entry.name.casefold() == filename.casefold() and entry.name != filename
                                               for filename in (name, name + '.pub')):
                            return result('unverified', 'unsafe_target')
                present = []
                for filename in (name, name + '.pub'):
                    try:
                        present.append(stamp(os.stat(filename, dir_fd=target.fd, follow_symlinks=False)))
                    except FileNotFoundError:
                        present.append(None)
                descriptors = []
                try:
                    for filename, info in zip((name, name + '.pub'), present):
                        if info is None:
                            continue
                        fd = os.open(filename, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=target.fd)
                        descriptors.append((fd, filename, info))
                        current = os.fstat(fd)
                        modes = (0o600, 0o644) if filename.endswith('.pub') else (0o600,)
                        if (not stat.S_ISREG(current.st_mode) or current.st_uid != os.getuid()
                                or current.st_nlink != 1 or stat.S_IMODE(current.st_mode) not in modes):
                            return result('unverified', 'unsafe_target')
                        safe_acl(fd)
                    if all(info is not None for info in present):
                        _, actual_private, actual_public, binding = read_pair(str(Path(directory) / name))
                        private_match, public_match = actual_private == private, actual_public == public
                        kind = 'matching' if private_match and public_match else 'differing'
                        reason = ('pair_identical' if kind == 'matching' else 'pair_bytes_differ'
                                  if not private_match and not public_match else 'private_bytes_differ'
                                  if not private_match else 'public_bytes_differ')
                    else:
                        private_match = public_match = binding = None
                        kind, reason = ('missing', 'pair_absent') if present == [None, None] else ('unverified', 'partial_pair')
                    for fd, filename, info in descriptors:
                        safe_acl(fd)
                        if stamp(os.fstat(fd)) != info or stamp(os.stat(filename, dir_fd=target.fd, follow_symlinks=False)) != info:
                            return result('unverified', 'target_changed')
                    for filename, info in zip((name, name + '.pub'), present):
                        if info is None:
                            try:
                                os.stat(filename, dir_fd=target.fd, follow_symlinks=False)
                            except FileNotFoundError:
                                continue
                            return result('unverified', 'target_changed')
                    target.check(); parent.check()
                    if stamp(os.fstat(target.fd)) != before or stamp(os.fstat(parent.fd)) != home_before:
                        return result('unverified', 'target_changed')
                    state = digest([directory, name, visible(parent), home_before, visible(target), before, present, binding])
                    return result(kind, reason, state, private_match, public_match)
                finally:
                    for fd, _, _ in reversed(descriptors):
                        os.close(fd)
    except ExternalSourceError as exc:
        return result('unverified', 'target_changed' if exc.code == 'external_identity_changed' else 'unsafe_target')
    except SecureError as exc:
        return result('unverified', 'target_changed' if exc.code == 'secure_target_changed' else 'unsafe_target')
    except OSError:
        return result('unverified', 'target_unavailable')


def compare(records, destinations, home):
    before = [observe(row, destinations.get(row[0]), home) for row in records]
    # Recheck the selected set before returning. Partial/changing observations
    # cannot become Matches or an established content mismatch.
    after = [observe(row, destinations.get(row[0]), home) for row in records]
    return [old if old == new else result('unverified', 'target_changed') for old, new in zip(before, after)]


def reference_coverage(raw, home, authenticated, destinations):
    """Check-only saved-state correspondence, never cryptographic qualification.

    Evidence comes from this operation's authenticated Check relay, after exact
    selected-pair comparison. Reuse fresh dependency observations and preserve
    assess()'s Restore/Import qualification semantics, including locked keys.
    Neither paths nor Host-to-key relationships leave this process.
    """
    from identity_dependencies import assess, identity_path
    from restore_destinations import selected_items

    selected = {row['identity_id']: row['directory'] for row in selected_items(destinations)}
    intended = {}
    for row in authenticated:
        if row['identity_id'] in selected:
            path = str(Path(selected[row['identity_id']] or str(Path(home) / '.ssh')) / row['name'])
            intended.setdefault(path, []).append(row)
    rows = assess(raw, home, authenticated=authenticated, destinations=destinations)
    for row in rows:
        for finding in row['references']:
            if finding['status'] == 'no_file_dependency':
                continue
            reference = finding['reference']
            # A selected custom destination does not approve an absolute or
            # otherwise nonportable IdentityFile from the saved configuration.
            if identity_path(reference) != 'portable':
                return 'unresolved'
            matches = intended.get(str(Path(home) / reference[2:]), [])
            if (len(matches) != 1 or matches[0]['target'] != 'identical'
                    or not finding.get('binding') or finding.get('pair_digest') != matches[0]['pair_digest']
                    or not (finding['status'] == 'local_satisfied'
                            or (finding['status'] == 'selected_expected'
                                and finding['reason'] == 'authenticated_pair_requires_unlock'))):
                return 'unresolved'
    return 'resolved'
