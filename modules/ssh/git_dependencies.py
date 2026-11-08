"""Private, bounded SSH requirements for Restore's existing Git clone executor.

No network probes, default-key discovery or authentication claims. Only fixed
reasons leave this module; profiles and file evidence stay in the digest-bound
Workspace execution context, never ordinary Protocol rows.
"""
import hashlib
import json
from pathlib import Path
import re
from urllib.parse import urlsplit

import config
import identity_dependencies as identities
import ssh_merge as merge

MAX_HOSTS = 32
MAX_EVIDENCE = 1024 * 1024
READY = 'git_ssh_local_ready'
PENDING = 'git_ssh_restore_pending'
MISSING = 'git_ssh_identity_unresolved'
CONFLICT = 'git_ssh_configuration_conflict'
UNSUPPORTED = 'git_ssh_configuration_unsupported'


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(',', ':')).encode()).hexdigest()


def host(remote):
    """Extract a literal destination only; native SSH retains Host matching."""
    from clone_execution import uses_ssh
    if not uses_ssh(remote):
        return None
    if remote.startswith('ssh://'):
        url = urlsplit(remote)
        if url.password is not None or url.query or url.fragment or not url.path:
            raise ValueError('unsupported SSH remote')
        # Preserve literal case; qualification never infers alias equivalence.
        value = url.netloc.rsplit('@', 1)[-1].split(':', 1)[0]
        if url.port is not None and not 1 <= url.port <= 65535:
            raise ValueError('unsupported SSH port')
    else:
        value, _, path = remote.partition(':')
        if not path:
            raise ValueError('missing SSH repository')
        value = value.rsplit('@', 1)[-1]
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', value):
        raise ValueError('unsupported SSH destination')
    return value


def local(home):
    with merge.target(str(home)) as (directory, recheck, _):
        raw = b''
        if directory is not None:
            if config.pending_publication(directory):
                raise merge.Refused('publication_uncertain')
            try:
                raw, _, _ = merge.observed_file(directory)
            except FileNotFoundError:
                pass
        recheck()
    return raw


def snapshot(name, entries):
    return (b'# toolkit-ssh-snapshot: 2\n# status: ready\n# excluded-profiles: 0\n\n'
            + config.payload({name: entries}))


def findings(rule, home, *, authenticated=(), destinations=None):
    return identities.assess(rule['snapshot'].encode(), str(home), authenticated=authenticated,
        destinations=destinations, approved_paths=rule['approved_paths'],
        verified_import=bool(authenticated))[0]['references']


def qualify(name, files, home, *, pending_secure=False, approved_paths=()):
    import bundle
    from clone_execution import SSH_CONFIG_LIMIT
    raw = local(home)
    profiles, excluded, structural = config.parse(raw)
    if excluded or structural:
        raise merge.Refused('unsupported_configuration')
    _, categories = bundle.parse_blueprint(files['blueprint.conf'])
    source = {}
    version = 2
    if categories.get('ssh-configuration'):
        version, _, _, source = config.snapshot(files['generated/ssh/config.snapshot'])
    # Do not infer aliases from HostName or case-fold native Host matching.
    if any(alias.lower() == name.lower() and alias != name for alias in profiles.keys() | source.keys()):
        raise merge.Refused('ambiguous_alias')
    entries = source.get(name, profiles.get(name, [('hostname', name)]))
    expected = raw
    configuration_pending = False
    if name in source and name in profiles and config.profile_values(profiles[name]) != config.profile_values(entries):
        return dict(reason=CONFLICT)
    if source:
        try:
            # The shared file can change even when this Host already matches.
            # Bind Safe Merge's full authorized result, not a speculative subset.
            expected, _ = merge.candidate(config.payload(source), raw, version=version)
            configuration_pending = expected != raw
        except merge.Refused:
            if name in source and name not in profiles:
                return dict(reason=CONFLICT)
            # Existing local state is independently usable. Selected conflicting
            # configuration retains the operation-wide readiness fence.
    if len(expected) > SSH_CONFIG_LIMIT:
        raise ValueError('SSH executor configuration limit')
    rule = dict(snapshot=snapshot(name, entries).decode(), approved_paths=list(approved_paths),
                expected_config=hashlib.sha256(expected).hexdigest(),
                config_evidence=merge.evidence(str(home)),
                absent_directory=not (Path(home) / '.ssh').exists(),
                configuration_pending=configuration_pending)
    rows = findings(rule, home)
    rule['references'] = rows
    unresolved = [row for row in rows if row['status'] not in ('local_satisfied', 'no_file_dependency')]
    pending = bool(unresolved) and pending_secure and all(
        row['status'] == 'missing' or row['reason'] == 'locked_or_invalid_identity' for row in unresolved)
    rule['reason'] = MISSING if unresolved and not pending else PENDING if configuration_pending or pending else READY
    return rule


def assess(files, home, plan, *, pending_secure=False, approved_paths=(), destinations=None):
    import bundle
    pending_secure = pending_secure and (destinations is None or bool(identities.selected_items(destinations)))
    targets = [row for row in plan if row['domain'] == 'git-repositories'
               and row['action'] == 'clone' and row['disposition'] == 'planned']
    records = bundle.workspace_contract().repository_records(files[bundle.workspace_contract().REPOSITORIES]) if targets else {}
    rules, cache = {}, {}
    evidence_bytes = 0
    before = None
    for row in targets:
        try:
            name = host(records[row['checkout_id']]['remote'])
            if name is None:
                continue
            if before is None:
                before = merge.evidence(str(home))
            if name not in cache:
                if len(cache) >= MAX_HOSTS:
                    raise ValueError('SSH observation limit')
                try:
                    cache[name] = qualify(name, files, home, pending_secure=pending_secure, approved_paths=approved_paths)
                except (OSError, ValueError):
                    # Failed observations consume the same bounded budget.
                    cache[name] = dict(reason=UNSUPPORTED)
            rule = cache[name]
        except (OSError, ValueError):
            rule = dict(reason=UNSUPPORTED)
        size = len(json.dumps(rule).encode())
        if evidence_bytes + size > MAX_EVIDENCE:
            rule = dict(reason=UNSUPPORTED)
        else:
            evidence_bytes += size
        rules[row['checkout_id']] = rule
    if before is not None and merge.evidence(str(home)) != before:
        rules = {item: dict(reason=UNSUPPORTED) for item in rules}
    return dict(rules=rules, fingerprint=digest([before, rules]))


def project(plan, evidence):
    from topology_preview import dependency_id
    blocked = set()
    for row in plan:
        if any(parent in blocked for parent in row.get('dependency_ids', [])):
            row.update(action='inspect', disposition='blocked', reason='workspace_dependency_pending')
        rule = evidence['rules'].get(row.get('checkout_id'))
        if rule is not None and row['disposition'] == 'planned':
            row['reason'] = PENDING if rule['reason'] == READY and row['reason'] else rule['reason']
            if rule['reason'] not in (READY, PENDING):
                row.update(action='inspect', disposition='blocked')
        if row['disposition'] not in ('planned', 'satisfied'):
            blocked.add(dependency_id(row['domain'], row.get('checkout_id', row['item_id'])))


def bind_imports(evidence, home, *, authenticated=(), destinations=None):
    """Bind only receipt-qualified import transitions; never rebase other keys."""
    selected = {row['identity_id']: row['directory'] for row in identities.selected_items(destinations)} if destinations else None
    receipts = {}
    for row in authenticated:
        if row['target'] != 'identical' or (selected is not None and row['identity_id'] not in selected):
            continue
        directory = selected[row['identity_id']] if selected is not None else None
        receipts[str(Path(directory or str(Path(home) / '.ssh')) / row['name'])] = row['pair_digest']
    for rule in evidence['rules'].values():
        if rule['reason'] not in (READY, PENDING):
            continue
        if not rule['configuration_pending'] and merge.evidence(str(home)) != rule['config_evidence']:
            if rule['absent_directory'] and receipts and not local(home):
                rule['config_evidence'] = merge.evidence(str(home))
            else:
                rule['reason'] = CONFLICT
                continue
        current = findings(rule, home, authenticated=authenticated, destinations=destinations)
        for old, new in zip(rule['references'], current):
            if old == new:
                continue
            reference = new['reference']
            path = str(Path(home) / reference[2:]) if reference and reference.startswith('~/') else reference
            if new['status'] == 'local_satisfied' and receipts.get(path) == new.get('pair_digest') and new.get('pair_digest'):
                new['reason'] = 'verified_import_pair'
            if not (old['status'] in ('missing', 'unresolved') and new['status'] == 'local_satisfied'
                    and new['reason'] == 'verified_import_pair'):
                rule['reason'] = MISSING
        if any(row['status'] not in ('local_satisfied', 'no_file_dependency') for row in current):
            rule['reason'] = MISSING
        rule['references'] = current


def revalidate(rule, home, ssh_config=None):
    try:
        return _revalidate(rule, home, ssh_config)
    except (OSError, ValueError):
        return False


def _revalidate(rule, home, ssh_config):
    if rule['reason'] not in (READY, PENDING):
        return False
    raw = local(home)
    if hashlib.sha256(raw).hexdigest() != rule['expected_config']:
        return False
    if not rule['configuration_pending'] and merge.evidence(str(home)) != rule['config_evidence']:
        return False
    if ssh_config is not None:
        used = b'' if ssh_config == '/dev/null' else Path(ssh_config).read_bytes()
        if used != raw:
            return False
    current = findings(rule, home)
    for old, new in zip(rule['references'], current):
        if old == new:
            continue
        # Imported protected keys need no second unlock: exact private pair and
        # safe-location evidence is bound to the already verified import receipt.
        if not (old['reason'] == 'verified_import_pair' and old.get('binding') == new.get('binding')
                and old.get('pair_digest') == new.get('pair_digest') and old.get('binding') is not None):
            return False
    return True
