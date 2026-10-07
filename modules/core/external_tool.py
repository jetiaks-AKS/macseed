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
