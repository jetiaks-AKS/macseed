"""Small value contract for concrete external-tool providers; no tool registry."""

STATES = frozenset({'satisfied', 'installable', 'repairable', 'unsupported',
                    'incompatible', 'observation_error'})
COMPATIBILITY = frozenset({'compatible', 'item_unsupported', 'tool_unavailable',
                          'capability_unavailable', 'metadata_incompatible',
                          'observation_failure'})


def result(tool, state, compatibility, reason=None, operation=None, provenance=None,
           capabilities=()):
    if state not in STATES or compatibility not in COMPATIBILITY:
        raise ValueError('invalid external-tool result')
    return {'adapter_contract': 1, 'tool': tool, 'state': state,
            'compatibility': compatibility, 'reason': reason,
            'operation': operation, 'provenance': provenance or {},
            'capabilities': list(capabilities)}


# Bounded provider diagnostics: no paths, user values, free text or raw tool output.
DIAGNOSTIC_PRIMITIVES = frozenset({'payload', 'metadata', 'historical_metadata', 'lifecycle',
                                  'requirements', 'replacement', 'launchctl', 'login_item', 'pkgutil'})
DIAGNOSTIC_CONDITIONS = frozenset({'ownership_unproven', 'unsupported_capability', 'observation_failed',
    'malformed_observation', 'observation_limit', 'ownership_ambiguous', 'foreign_target',
    'conflicting_plist', 'live_ownership_unproven', 'identity_ambiguous', 'authorization_required',
    'authorization_denied', 'application_unavailable'})


def diagnostic_valid(value):
    return (isinstance(value, dict) and set(value) == {'primitive', 'condition'}
            and isinstance(value['primitive'], str) and value['primitive'] in DIAGNOSTIC_PRIMITIVES
            and isinstance(value['condition'], str) and value['condition'] in DIAGNOSTIC_CONDITIONS)
