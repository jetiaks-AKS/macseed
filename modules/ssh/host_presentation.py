"""Private, optional Host evidence. Never a requirement or permission to Apply.

Only bounded aliases leave this module. Snapshots, directives, dependencies and
target bytes stay private. The ordinary aggregate records remain authoritative.
"""
import hashlib
import re

import config
import ssh_merge as merge

DOMAIN = 'ssh-configuration'
MAX_HOSTS = 2048


def identity(host):
    return 'restore:' + hashlib.sha256((DOMAIN + '\0' + host).encode()).hexdigest()


def observe(raw, home):
    _, _, _, profiles = config.snapshot(raw)
    if not profiles or len(profiles) > MAX_HOSTS or any(
            not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,159}', host) for host in profiles):
        return None  # Honest aggregate fallback for unrepresentable inventories.
    before = merge.evidence(home)
    reason = None
    try:
        with merge.target(home) as (directory, recheck, _):
            actual = b''
            if directory is not None:
                if config.pending_publication(directory):
                    raise merge.Refused('publication_uncertain')
                try:
                    actual, _, _ = merge.observed_file(directory)
                except FileNotFoundError:
                    pass
            _, _, states = config.profile_assessment(config.payload(profiles), actual)
            recheck()
    except (merge.Refused, config.Unsafe, config.Invalid, OSError):
        states = {host: 'unverified' for host in profiles}
        reason = 'observation_failed'
    after = merge.evidence(home)
    if before != after:
        return None
    return dict(version=1, snapshot_id=hashlib.sha256(raw).hexdigest(), observation_id=after,
                hosts=[dict(item_id=identity(host), label=host, state=state,
                            reason='target_conflict' if state == 'differing' else
                            'unsupported_target' if state == 'unsupported' else reason)
                       for host, state in states.items()])


def valid(detail, raw):
    """Reject foreign, reordered, duplicated or contradictory private evidence."""
    if not isinstance(detail, dict) or set(detail) != {'version', 'snapshot_id', 'observation_id', 'hosts'}:
        return False
    profiles = config.snapshot(raw)[3]
    if (type(detail['version']) is not int or detail['version'] != 1
            or detail['snapshot_id'] != hashlib.sha256(raw).hexdigest()
            or not isinstance(detail['observation_id'], str)
            or re.fullmatch(r'[0-9a-f]{64}', detail['observation_id']) is None
            or not isinstance(detail['hosts'], list) or not 1 <= len(detail['hosts']) <= MAX_HOSTS
            or len(detail['hosts']) != len(profiles)):
        return False
    for row, alias in zip(detail['hosts'], profiles):
        if (not isinstance(row, dict) or set(row) != {'item_id', 'label', 'state', 'reason'}
                or row['item_id'] != identity(alias) or row['label'] != alias
                or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]{0,159}', alias)
                or row['state'] not in ('matching', 'missing', 'differing', 'unsupported', 'unverified')
                or row['reason'] != {'differing': 'target_conflict', 'unsupported': 'unsupported_target',
                                     'unverified': 'observation_failed'}.get(row['state'])):
            return False
    states = {row['state'] for row in detail['hosts']}
    return not states & {'unsupported', 'unverified'} or len(states) == 1


def comparison(detail, rows, owners, raw):
    """Bind detail to the same aggregate predicate; never infer a Host match."""
    if not valid(detail, raw):
        return None
    candidates = [row for row in rows if row['domain'] == DOMAIN and row['item_id'] == 'config']
    if len(candidates) != 1:
        return None
    row = candidates[0]
    qualified = [owner for owner in owners if owner['record_id'] == row['record_id']]
    if (len(qualified) != 1 or qualified[0]['domain'] != DOMAIN or qualified[0]['item_id'] != 'config'
            or qualified[0]['predicate'] != 'supported_config_match'):
        return None
    states = {host['state'] for host in detail['hosts']}
    kind = ('unverified' if states & {'unsupported', 'unverified'} else
            'differing' if 'differing' in states else 'missing' if 'missing' in states else 'matching')
    if kind != row['comparison_kind'] or ('unsupported' in states) != (row['support'] == 'unsupported'):
        return None
    return dict(detail, comparison_record_id=row['record_id'])


def preview(detail, summary, raw):
    """Project the existing plan's decision, including operation-wide blockers."""
    if not valid(detail, raw):
        return None
    rows = [row for row in summary['plan'] if row['domain'] == DOMAIN]
    primary = [row for row in rows if row['item_id'] in ('config', 'missing-profiles')]
    if len(primary) != 1:
        return None
    owner = primary[0]
    states = {host['state'] for host in detail['hosts']}
    expected = {'target_conflict': 'differing', 'missing_profiles': 'missing',
                'unsupported_predicate': 'unsupported', 'observation_failed': 'unverified'}
    if owner.get('reason') in expected and expected[owner['reason']] not in states:
        return None
    # No independent planner: absence alone cannot authorize an addition.
    permitted = (summary['readiness']['ready'] and summary['error_count'] == 0
                 and owner['action'] == 'create' and owner['disposition'] == 'planned'
                 and all(row['disposition'] in ('planned', 'satisfied') or
                         (row['item_id'] == 'scope' and row['disposition'] == 'warning'
                          and row['reason'] == 'partial_source_coverage') or
                         (row['item_id'] == 'identity-references' and summary.get('ssh_resolution', {}).get('ready') is True)
                         for row in rows)
                 and summary.get('ssh_resolution', {}).get('ready', True) is True)
    if permitted and (not states <= {'matching', 'missing'} or 'missing' not in states):
        return None
    if owner['disposition'] == 'satisfied' and states != {'matching'}:
        return None
    hosts = []
    for host in detail['hosts']:
        disposition = ('satisfied' if host['state'] == 'matching' else
                       'planned' if host['state'] == 'missing' and permitted else 'blocked')
        hosts.append(dict(host, disposition=disposition))
    return dict(detail, hosts=hosts, plan_item_id=owner['item_id'],
                prepared_plan_id=summary['prepared_plan_id'])
