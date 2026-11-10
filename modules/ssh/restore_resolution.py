"""Explicit private IdentityFile approvals and qualified v2 SSH publication.

Authorization is input, never identity evidence. Only the current secure helper
can supply authenticated identities; publication rechecks their actual bytes.
"""
import hashlib
import fcntl
import json
import os
from pathlib import Path
import sys
import uuid

import config
import identity_dependencies as dependencies
import ssh_merge as merge
from external_sources import ExternalSourceError, read_control, MAX_CONTROL
from evidence import open_directory
from restore_destinations import digest, selected_items, HEX
from secret_input import SecureError

CONTROL = 'ssh-restore-approvals.json'
REVIEW = 'ssh-restore-references.json'
EVIDENCE = 'ssh-restore-evidence.json'
ORIGINAL = 'ssh-original.snapshot'
MAX_APPROVALS = 32


def host_id(host):
    return 'restore:' + hashlib.sha256(('ssh-configuration\0' + host).encode()).hexdigest()


def validate(value, *, review=False):
    if (not isinstance(value, dict) or set(value) != {'version', 'bundle_id', 'items'}
            or type(value['version']) is not int or value['version'] != 1
            or not isinstance(value['bundle_id'], str) or not HEX.fullmatch(value['bundle_id'])
            or not isinstance(value['items'], list) or not 1 <= len(value['items']) <= MAX_APPROVALS):
        raise SecureError('ssh_approval_invalid')
    keys = []
    for row in value['items']:
        if (not isinstance(row, dict) or set(row) != {'host_id', 'index', 'original', 'reference', 'identity_id', 'approved'}
                or row['approved'] is not (not review) or not isinstance(row['host_id'], str)
                or not row['host_id'].startswith('restore:') or not HEX.fullmatch(row['host_id'][8:])
                or type(row['index']) is not int or not 0 <= row['index'] < config.MAX_IDENTITIES
                or any(not isinstance(row[key], str) or config.identity_path(row[key]) not in ('portable', 'unresolved')
                       for key in ('original', 'reference'))
                or (row['identity_id'] is not None and
                    (not isinstance(row['identity_id'], str) or not HEX.fullmatch(row['identity_id'])))):
            raise SecureError('ssh_approval_invalid')
        keys.append((row['host_id'], row['index']))
    if keys != sorted(set(keys)):
        raise SecureError('ssh_approval_invalid')
    return value


def operation_approvals(operation_id, *, review=False):
    try:
        value = read_control(Path(os.environ['TMPDIR']).resolve() / CONTROL)
        if not isinstance(value, dict) or set(value) != {'operation_id', 'approvals'} or value['operation_id'] != operation_id:
            raise SecureError('ssh_approval_invalid')
        return validate(value['approvals'], review=review)
    except (ExternalSourceError, OSError, ValueError, KeyError):
        raise SecureError('ssh_approval_invalid') from None


def references(raw):
    rows = []
    for host, entries in config.snapshot(raw)[3].items():
        for index, reference in enumerate(value for key, value in entries if key == 'identityfile'):
            rows.append(dict(host_id=host_id(host), host=host, index=index, reference=reference))
    if len(rows) > MAX_APPROVALS:
        raise SecureError('ssh_review_unavailable')
    return rows


def effective(original, approvals, bundle_id, *, review=False):
    _, _, _, profiles = config.snapshot(original)
    if approvals is None:
        return original
    validate(approvals, review=review)
    if approvals['bundle_id'] != bundle_id:
        raise SecureError('stale_plan')
    known = {(row['host_id'], row['index']): row for row in references(original)}
    replacements = {}
    for row in approvals['items']:
        key = row['host_id'], row['index']
        if key not in known or known[key]['reference'] != row['original'] or row['original'] == 'none':
            raise SecureError('ssh_approval_invalid')
        replacements[key] = row['reference']
    changed = {}
    for host, entries in profiles.items():
        index, values = 0, []
        for key, value in entries:
            if key == 'identityfile':
                value = replacements.get((host_id(host), index), value)
                index += 1
            values.append((key, value))
        changed[host] = values
    raw = b'\n'.join(original.split(b'\n', 4)[:4]) + b'\n' + config.payload(changed)
    config.snapshot(raw)  # Includes ordered duplicate/sentinel and grammar checks.
    return raw


def collision(fd, name):
    with os.scandir(fd) as entries:
        for index, entry in enumerate(entries):
            if index >= dependencies.MAX_ENTRIES or (entry.name.casefold() == name.casefold() and entry.name != name):
                raise merge.Refused('unsafe_target')


def target_state(home):
    with merge.target(home) as (directory, recheck, ancestors):
        state = 'absent-directory'
        homefd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            collision(homefd, '.ssh')
        finally:
            os.close(homefd)
        if directory is not None:
            collision(directory, 'config')
            if config.pending_publication(directory):
                raise merge.Refused('publication_uncertain')
            try:
                merge.observed_file(directory)
                state = 'present'
            except FileNotFoundError:
                state = 'absent-config'
        recheck()
        return dict(state=state, ancestors=[list(row) for row in ancestors], evidence=merge.evidence(home))


def after_import(before, home):
    current = target_state(home)
    if current != before and not (before['state'] == 'absent-directory'
            and current['state'] == 'absent-config' and current['ancestors'][:-1] == before['ancestors']):
        raise SecureError('stale_plan')
    return current


def destination(row, home, destinations):
    if destinations is None:
        return str(Path(home) / '.ssh' / row['name'])
    selected = {item['identity_id']: item['directory'] for item in selected_items(destinations)}
    if row['identity_id'] not in selected:
        raise SecureError('ssh_identity_unresolved')
    return str(Path(selected[row['identity_id']] or str(Path(home) / '.ssh')) / row['name'])


def resolved_dependencies(original, home, *, approvals=None, bundle_id=None, destinations=None,
                          authenticated=(), pending_secure=False, verified_import=False, review=False):
    raw = effective(original, approvals, bundle_id, review=review)
    approved = approvals['items'] if approvals else []
    paths = {row['reference'] for row in approved}
    rows = dependencies.assess(raw, home, authenticated=authenticated, destinations=destinations,
                               approved_paths=paths, verified_import=verified_import)
    refs = {(host_id(row['host']), index): item for row in rows
            for index, item in enumerate(row['references']) if item['reference'] is not None}
    identities = {row['identity_id']: row for row in authenticated}
    for approval in approved:
        item = refs[approval['host_id'], approval['index']]
        if approval['identity_id'] is None:
            if item['status'] != 'local_satisfied':
                item.update(status='unresolved', reason='approved_local_key_unqualified')
        elif approval['identity_id'] in identities:
            path = str(Path(home) / approval['reference'][2:]) if approval['reference'].startswith('~/') else approval['reference']
            if destination(identities[approval['identity_id']], home, destinations) != path:
                item.update(status='unresolved', reason='approved_identity_destination_changed')
        elif authenticated or not pending_secure or (destinations is not None and
                approval['identity_id'] not in {row['identity_id'] for row in selected_items(destinations)}):
            item.update(status='unresolved', reason='approved_identity_unavailable')
    return raw, rows


def review_references(original, home, *, proposals=None, bundle_id=None, destinations=None, authenticated=()):
    """Private advisory rows only; a proposal is never execution consent."""
    _, current = resolved_dependencies(original, home, destinations=destinations, authenticated=authenticated)
    proposed = {}
    if proposals:
        _, findings = resolved_dependencies(original, home, approvals=proposals, bundle_id=bundle_id,
            destinations=destinations, authenticated=authenticated, review=True)
        qualified = {(host_id(row['host']), index): item['status'] for row in findings
                     for index, item in enumerate(row['references'])}
        for item in proposals['items']:
            status = qualified[item['host_id'], item['index']]
            if status in ('local_satisfied', 'selected_expected'):
                proposed[item['host_id'], item['index']] = dict(reference=item['reference'],
                    identity_id=item['identity_id'], status=status)
    rows = [dict(host_id=host_id(row['host']), host=row['host'], index=index,
                 reference=item['reference'], status=item['status'], reason=item['reason'], proposal=proposed.get((host_id(row['host']), index)))
            for row in current for index, item in enumerate(row['references'])
            if item['status'] in ('missing', 'unresolved', 'unsafe_target')]
    # Bound the private response after filtering; healthy shared references need
    # no correction and must not turn a successful empty review into an error.
    if len(rows) > MAX_APPROVALS:
        raise SecureError('ssh_review_unavailable')
    return rows


def correction_findings(rows, approvals):
    """Only an explicitly changed reference makes identity evidence authorization."""
    required = {(item['host_id'], item['index']) for item in (approvals or {}).get('items', [])}
    return [item for row in rows for index, item in enumerate(row['references'])
            if (host_id(row['host']), index) in required]


def inspect(original, home, *, approvals=None, bundle_id=None, destinations=None,
            authenticated=(), pending_secure=False, verified_import=False):
    raw, rows = resolved_dependencies(original, home, approvals=approvals, bundle_id=bundle_id,
        destinations=destinations, authenticated=authenticated, pending_secure=pending_secure, verified_import=verified_import)
    version, status, _, profiles = config.snapshot(raw)
    if version != 2:
        raise merge.Refused('not_v2')
    findings = [item for row in rows for item in row['references']]
    qualified = all(item['status'] in ('local_satisfied', 'no_file_dependency') for item in findings)
    expected = all(item['status'] in ('local_satisfied', 'no_file_dependency', 'selected_expected') for item in findings)
    corrections = correction_findings(rows, approvals)
    corrections_qualified = all(item['status'] == 'local_satisfied' for item in corrections)
    corrections_expected = all(item['status'] in ('local_satisfied', 'selected_expected') for item in corrections)
    pending = not corrections_qualified and not corrections_expected and pending_secure and not authenticated and all(
        item['status'] in ('local_satisfied', 'no_file_dependency', 'missing') or
        (item['status'] == 'unresolved' and item['reason'] == 'locked_or_invalid_identity') for item in corrections)
    target = target_state(home)
    action, count = merge.plan(config.payload(profiles), home, version=2)
    # An approved effective match needs no publication. Any mutation still checks
    # the original Hosts so a correction cannot conceal an existing conflict.
    _, original_conformity, _ = config.assess(config.payload(config.snapshot(original)[3]), home)
    if (original_conformity in ('unsupported', 'unsafe', 'publication_uncertain')
            or (original_conformity == 'conflicting_profiles' and action != 'noop')):
        raise merge.Refused('original_target_conflict')
    if status == 'partial' and action == 'merge':
        raise merge.Refused('partial_source')
    if not profiles:
        raise merge.Refused('source_excluded')
    if target_state(home) != target:
        raise merge.Refused('target_changed')
    return dict(raw=raw, action=action, count=count, target=target, dependencies=rows,
                dependency_digest=digest(rows), qualified=qualified, expected=expected,
                corrections_qualified=corrections_qualified, corrections_expected=corrections_expected,
                pending=pending, partial=status == 'partial')


def public(plan):
    ready = plan['corrections_expected']
    return dict(version=1, action=plan['action'], ready=ready, pending=plan['pending'],
                dependencies=dependencies.projection(plan['dependencies']), remote_authentication='not_assessed')


def blocked():
    return dict(version=1, action='blocked', ready=False, pending=False,
                dependencies={'version': 1, 'findings': ['unresolved']}, remote_authentication='not_assessed')


def valid_public(value):
    return (isinstance(value, dict) and set(value) == set(blocked()) and type(value['version']) is int and value['version'] == 1
            and value['action'] in ('blocked', 'noop', 'create', 'merge') and type(value['ready']) is bool
            and type(value['pending']) is bool and value['remote_authentication'] == 'not_assessed'
            and isinstance(value['dependencies'], dict) and set(value['dependencies']) in ({'version', 'findings'}, {'version', 'findings', 'reasons'})
            and isinstance(value['dependencies'].get('reasons', []), list)
            and len(value['dependencies'].get('reasons', [])) <= len(dependencies.REASONS)
            and all(isinstance(reason, str) and reason in dependencies.REASONS for reason in value['dependencies'].get('reasons', []))
            and type(value['dependencies']['version']) is int and value['dependencies']['version'] == 1
            and isinstance(value['dependencies']['findings'], list) and len(value['dependencies']['findings']) <= 6
            and not (value['ready'] and (value['pending'] or value['action'] == 'blocked'))
            and all(isinstance(row, str) and row in {'local_satisfied', 'selected_expected', 'missing', 'unresolved', 'unsafe_target', 'no_file_dependency'}
                    for row in value['dependencies']['findings']))


def execution_context(original, plan, *, approvals=None, bundle_id=None, destinations=None, authenticated=(), preview=False):
    if not preview and not plan['corrections_qualified']:
        raise SecureError('ssh_identity_unresolved')
    return dict(version=1, preview=preview, pending_secure=plan['pending'], original_sha=hashlib.sha256(original).hexdigest(), effective_sha=hashlib.sha256(plan['raw']).hexdigest(),
                approvals=approvals, bundle_id=bundle_id, destinations=destinations,
                authenticated=list(authenticated), dependency_digest=plan['dependency_digest'], target=plan['target'])


def read_original(directory, expected_sha, expected_stamp=None):
    """Read the bounded original through a pinned private directory, without links."""
    fd = open_directory(str(directory))
    try:
        parent = merge.identity(os.fstat(fd))
        before = config.stamp(os.stat(ORIGINAL, dir_fd=fd, follow_symlinks=False))
        raw = config.read_file(ORIGINAL, directory=fd, private=True)
        after = config.stamp(os.stat(ORIGINAL, dir_fd=fd, follow_symlinks=False))
        stamp = digest(after)
        if (before != after or hashlib.sha256(raw).hexdigest() != expected_sha
                or (expected_stamp is not None and stamp != expected_stamp)
                or merge.identity(os.fstat(fd)) != parent or merge.identity(os.lstat(directory)) != parent):
            raise merge.Refused('original_snapshot_changed')
        config.snapshot(raw)
        return raw, stamp
    finally:
        os.close(fd)


def write_context(directory, original, value, *, existing_original=False):
    """Publish fixed-name private inputs exclusively; the global control limit stays unchanged."""
    if len(original) > config.MAX_CONFIG or hashlib.sha256(original).hexdigest() != value['original_sha']:
        raise merge.Refused('invalid_original_snapshot')
    config.snapshot(original)
    fd = open_directory(str(directory))
    try:
        parent = merge.identity(os.fstat(fd))
        if not existing_original:
            output = os.open(ORIGINAL, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            with os.fdopen(output, 'wb') as stream:
                os.fchmod(stream.fileno(), 0o600)
                stream.write(original)
        _, stamp = read_original(directory, value['original_sha'])
        raw = json.dumps(dict(value, original_stamp=stamp), separators=(',', ':')).encode()
        if len(raw) > MAX_CONTROL:
            raise merge.Refused('execution_context_limit')
        output = os.open(EVIDENCE, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
        with os.fdopen(output, 'wb') as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(raw)
        if merge.identity(os.fstat(fd)) != parent or merge.identity(os.lstat(directory)) != parent:
            raise merge.Refused('original_snapshot_changed')
        read_original(directory, value['original_sha'], stamp)
    finally:
        os.close(fd)


def context(raw):
    directory = os.environ.get('MACSEED_ITEM_STATE_DIR')
    if os.environ.get('MACSEED_APPLICATION_EXECUTION') != 'true' or not directory:
        return None
    path = Path(directory) / EVIDENCE
    if not os.path.lexists(path):
        return None
    value = read_control(path)
    if (not isinstance(value, dict) or set(value) != {'version', 'original_sha', 'original_stamp', 'effective_sha', 'approvals', 'bundle_id',
            'destinations', 'authenticated', 'dependency_digest', 'target', 'preview', 'pending_secure'} or type(value['version']) is not int or value['version'] != 1
            or type(value['preview']) is not bool or type(value['pending_secure']) is not bool
            or value['effective_sha'] != hashlib.sha256(raw).hexdigest()
            or any(not isinstance(value[key], str) or not HEX.fullmatch(value[key]) for key in ('original_sha', 'original_stamp'))):
        raise merge.Refused('invalid_execution_evidence')
    read_original(directory, value['original_sha'], value['original_stamp'])
    return dict(value, _directory=directory)


def bound_plan(raw, home, value, *, verification=False):
    original = read_original(value['_directory'], value['original_sha'], value['original_stamp'])[0] if value else None
    if verification:
        # Dependency verification is independent of config conformity. A previous
        # private operation can prove a protected pair only while exact bytes match.
        approved = (value['approvals'] or {}).get('items', []) if value else []
        rows = dependencies.assess(raw, home, authenticated=value['authenticated'] if value else (),
            destinations=value['destinations'] if value else None,
            approved_paths=[row['reference'] for row in approved], verified_import=value is not None and not value['preview'])
        return dict(qualified=all(item['status'] in ('local_satisfied', 'no_file_dependency') for row in rows for item in row['references']),
                    corrections_qualified=all(item['status'] == 'local_satisfied' for item in
                        correction_findings(rows, value['approvals'] if value else None)))
    if value is None:
        return inspect(raw, home)
    plan = inspect(original, home, approvals=value['approvals'], bundle_id=value['bundle_id'],
                   destinations=value['destinations'], authenticated=value['authenticated'], verified_import=not value['preview'], pending_secure=value['pending_secure'])
    if plan['raw'] != raw or plan['target'] != value['target'] or plan['dependency_digest'] != value['dependency_digest']:
        raise merge.Refused('target_changed')
    return plan


def create(expected, home, target, validate):
    if target_state(home) != target:
        raise merge.Refused('target_changed')
    changed = False
    try:
        with merge.target(home) as (directory, recheck, ancestors):
            if directory is None:
                homefd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
                try:
                    if merge.identity(os.fstat(homefd)) != tuple(ancestors[-1]):
                        raise merge.Refused('target_changed')
                    recheck()
                    collision(homefd, '.ssh')
                    os.mkdir('.ssh', 0o700, dir_fd=homefd)
                    changed = True
                    os.fsync(homefd)
                    target = dict(target, ancestors=target['ancestors'] + [list(merge.identity(os.stat('.ssh', dir_fd=homefd, follow_symlinks=False)))])
                    recheck()
                finally:
                    os.close(homefd)
        with merge.target(home) as (directory, recheck, ancestors):
            if [list(row) for row in ancestors] != target['ancestors']:
                raise merge.Refused('target_changed')
            if directory is None or config.pending_publication(directory):
                raise merge.Refused('target_changed')
            try:
                os.stat('config', dir_fd=directory, follow_symlinks=False)
            except FileNotFoundError:
                pass
            else:
                raise merge.Refused('target_changed')
            pending = '.macseed-ssh-pending-' + uuid.uuid4().hex
            os.mkdir(pending, 0o700, dir_fd=directory)
            changed = True
            recovery = os.open(pending, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=directory)
            try:
                pinned = merge.identity(os.fstat(recovery))
                fd = os.open('new', os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=recovery)
                with os.fdopen(fd, 'wb') as stream:
                    os.fchmod(stream.fileno(), 0o600)
                    stream.write(expected); stream.flush(); os.fsync(stream.fileno())
                    fcntl.fcntl(stream.fileno(), 51)
                    staged = merge.identity(os.fstat(stream.fileno()))
                os.fsync(recovery); os.fsync(directory)
                recheck(); validate(); collision(directory, 'config')
                if merge.identity(os.stat(pending, dir_fd=directory, follow_symlinks=False)) != pinned:
                    raise merge.Refused('target_changed')
                merge.rename(recovery, 'new', directory, 'config', 4)
                actual, info, _ = merge.observed_file(directory)
                if actual != expected or merge.identity(info) != staged:
                    raise merge.Refused('publication_uncertain')
                recheck(); validate()
                os.fsync(directory)
                if merge.identity(os.stat(pending, dir_fd=directory, follow_symlinks=False)) != pinned:
                    raise merge.Refused('publication_uncertain')
                os.rmdir(pending, dir_fd=directory)
            finally:
                os.close(recovery)
    except BaseException as exc:
        if changed:
            raise merge.PublicationUncertain(True) from exc
        raise


def apply(raw, home, value=None):
    if value is not None and value['preview']:
        raise merge.Refused('preview_not_authorization')
    plan = bound_plan(raw, home, value)
    if not plan['corrections_qualified']:
        raise merge.Refused('identity_unresolved')
    def recheck_dependencies():
        if value is not None:
            read_original(value['_directory'], value['original_sha'], value['original_stamp'])
        approved = (value['approvals'] or {}).get('items', []) if value else []
        rows = dependencies.assess(raw, home, authenticated=value['authenticated'] if value else (),
                                   destinations=value['destinations'] if value else None,
                                   approved_paths=[row['reference'] for row in approved], verified_import=value is not None)
        # Creation of our pinned .ssh directory changes the absence binding for
        # references below it. Accept only that expected transition: the key must
        # still be checked absent, with no newly appearing intermediate directory.
        # Every other key observation (including advisory ones) stays bound.
        if plan['target']['state'] == 'absent-directory':
            for before, after in zip(plan['dependencies'], rows):
                for old, new in zip(before['references'], after['references']):
                    reference = old['reference']
                    if (reference and reference.startswith('~/.ssh/') and old['status'] == new['status'] == 'missing'
                            and old['reason'] == new['reason'] == 'checked_absent'):
                        parent = (Path(home) / reference[2:]).parent
                        while not os.path.lexists(parent):
                            parent = parent.parent
                        if parent == Path(home) / '.ssh':
                            new['binding'] = old['binding']
        if digest(rows) != plan['dependency_digest']:
            raise merge.Refused('identity_changed')
    if plan['action'] == 'noop':
        recheck_dependencies()
        if target_state(home) != plan['target']:
            raise merge.Refused('target_changed')
        return False
    expected = config.payload(config.snapshot(raw)[3])
    if plan['action'] == 'merge':
        return merge.publish(expected, home, plan['target']['evidence'], version=2, validate=recheck_dependencies)
    if target_state(home) != plan['target']:
        raise merge.Refused('target_changed')
    create(expected, home, plan['target'], recheck_dependencies)
    return True


def main():
    command, filename, home = sys.argv[1:]
    raw = config.read_snapshot(filename)
    value = context(raw)
    if command in ('verify', 'verify-corrections'):
        field = 'qualified' if command == 'verify' else 'corrections_qualified'
        print('qualified' if bound_plan(raw, home, value, verification=True)[field] else 'unresolved')
    elif command == 'plan':
        plan = bound_plan(raw, home, value)
        if not (plan['corrections_qualified'] or (value and value['preview'] and (plan['pending'] or plan['corrections_expected']))):
            raise merge.Refused('identity_unresolved')
        print(plan['action'], plan['count'], plan['target']['evidence'], 'qualified' if plan['qualified'] else 'advisory')
    elif command == 'apply':
        print('published' if apply(raw, home, value) else 'noop')
    else:
        raise ValueError()


if __name__ == '__main__':
    try:
        main()
    except merge.PublicationUncertain as exc:
        print('publication_uncertain', int(exc.changed))
        sys.exit(2)
    except merge.Refused as exc:
        print('identity_unresolved' if str(exc) == 'identity_unresolved' else 'unresolved')
        sys.exit(1)
    except (OSError, ValueError, KeyError, TypeError, SecureError, ExternalSourceError):
        print('unresolved')
        sys.exit(1)
