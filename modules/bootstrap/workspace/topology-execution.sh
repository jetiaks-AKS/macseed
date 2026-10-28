#!/bin/bash

# Private domain bridge; Core supplies the digest-bound confirmed context.
workspace_topology_validate() {
    python3 -B modules/bootstrap/workspace/topology_execution.py --validate
}

bootstrap_workspace_topology() {
    local report status kind domain subject operation outcome reason changed
    report="$(mktemp "${MACSEED_ITEM_STATE_DIR}/workspace-operations.XXXXXX")" || return 2
    python3 -B modules/bootstrap/workspace/topology_execution.py --execute >"$report"
    status=$?
    while IFS=$'\t' read -r kind domain subject operation outcome reason changed; do
        if [[ "$kind" == changed ]]; then
            # shellcheck disable=SC2034
            MODULE_CHANGED=true
            continue
        fi
        [[ "$kind" == operation ]] || { status=2; continue; }
        [[ "$reason" != none ]] || reason=""
        verification_operation "$domain" "$subject" "$operation" "$outcome" "$reason" || status=2
        # Shared lifecycle flag is consumed by run_module.
        # shellcheck disable=SC2034
        if [[ "$changed" == true ]]; then MODULE_CHANGED=true; fi
    done <"$report"
    rm -f "$report"
    if [[ $status -eq 2 ]]; then
        verification_operation workspace scope restore failure workspace_execution_failed
    fi
    [[ $status -ne 132 ]] || return 132
    application_stop_checkpoint "$status"
    return "$status"
}

verify_workspace_topology() {
    local report domain subject predicate result
    report="$(python3 -B modules/bootstrap/workspace/topology_execution.py --verify)" || {
        verification_input_error git-repositories
        verification_input_error workspace-folders
        verification_input_error vscode-workspaces
        return 0
    }
    while IFS=$'\t' read -r domain subject predicate result; do
        [[ -n "$domain" ]] || continue
        verification_coverage "$domain" "$subject" resolved unknown || return 2
        verification_result "$domain" "$subject" "$predicate" "$result" || return 2
    done <<< "$report"
}
