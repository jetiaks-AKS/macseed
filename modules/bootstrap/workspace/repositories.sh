#!/bin/bash

# ==========================================
# Bootstrap Workspace Repositories
# ==========================================

preview_workspace_repositories() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items git-repositories)" ]]; then
        return 0
    fi

    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]] &&
       ! repository_application_readiness; then
        if [[ "$REPOSITORY_APPLICATION_CONDITION" != repository_target_conflict ]]; then
            warning "Repository readiness requires attention"
            return 1
        fi
    fi

    local config_file
    config_file="$(blueprint_generated_file git-repositories)"

    local repositories
    if ! repositories="$(workspace_read_bootstrap_repositories "$config_file")"; then
        error "Workspace repositories configuration is missing, unreadable, or not actionable"
        return 2
    fi

    local has_warnings=false
    local repository_result
    local repository path remote branch

    while IFS=$'\t' read -r repository path remote branch; do
        [[ -n "$repository" ]] || continue

        repository_preview "$repository" "$path" "$remote" "$branch"
        repository_result=$?
        if [[ $repository_result -eq 2 ]]; then
            error "Repository inspection failed: $repository"
            return 2
        fi
        [[ $repository_result -eq 0 ]] || has_warnings=true
    done <<< "$repositories"

    [[ "$has_warnings" == false ]] && return 0
    return 1
}

bootstrap_workspace_repositories() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items git-repositories)" ]]; then
        success "No Git repositories selected by Blueprint"
        return 0
    fi

    action "Restoring Git repositories..."

    local config_file
    config_file="$(blueprint_generated_file git-repositories)"

    local repositories
    if ! repositories="$(workspace_read_bootstrap_repositories "$config_file")"; then
        error "Workspace repositories configuration is missing, unreadable, or not actionable"
        return 2
    fi

    success "Workspace repositories configuration loaded"

    echo

    local has_warnings=false
    local repository_result
    local has_errors=false failed_checkouts="" failed_clones="" failed_path

    local repository path remote branch
    while IFS=$'\t' read -r repository path remote branch; do
        [[ -n "$repository" ]] || continue
        if declare -F application_stop_checkpoint >/dev/null; then
            if [[ "$has_errors" == true ]]; then application_stop_checkpoint 2; else application_stop_checkpoint; fi
        fi
        if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
              -f "${MACSEED_ITEM_STATE_DIR:-}/external-tool-active.json" ]]; then
            error "External lifecycle consequences are unknown; further mutation is blocked"
            return 2
        fi
        if [[ -n "$failed_checkouts" ]]; then
            if ! workspace_bootstrap_path_valid "${path#"$HOME"/}" ||
               ! printf '%s\n' "$failed_checkouts" | python3 -B modules/bootstrap/workspace/checkout-evidence.py independent "$path" 2>/dev/null; then
                error "Repository independence is unproven; further restoration is blocked: $repository"
                return 2
            fi
        fi
        # A known partial clone is isolated only from disjoint destinations.
        while IFS= read -r failed_path; do
            [[ -n "$failed_path" ]] || continue
            python3 -B modules/bootstrap/workspace/clone_execution.py --independent "$failed_path" "$path" || return 2
        done <<< "$failed_clones"

    info "Repository: $repository"

        repository_verify "$path" "$remote" "$branch" "$repository"
        repository_result=$?
        if [[ $repository_result -eq 2 ]]; then
            error "Repository inspection failed: $repository"
            if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
                  "${BUNDLE_RESTORE_ACTIVE:-false}" == true &&
                  "${REPOSITORY_CLONE_FAILURE_SAFE:-false}" == true ]]; then
                has_errors=true
                failed_clones="${failed_clones}${failed_clones:+$'\n'}$path"
                continue
            fi
            if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
                  "${BUNDLE_RESTORE_ACTIVE:-false}" == true &&
                  -n "${REPOSITORY_CHECKOUT_FAILURE_EVIDENCE:-}" ]]; then
                has_errors=true
                failed_checkouts="${failed_checkouts}${failed_checkouts:+$'\n'}$REPOSITORY_CHECKOUT_FAILURE_EVIDENCE"
                continue
            fi
            return 2
        fi
        if [[ $repository_result -ne 0 ]]; then
            warning "Repository requires manual attention: $repository"
            has_warnings=true
        fi

        echo

    done <<< "$repositories"

    if [[ "$has_errors" == true ]]; then
        return 2
    fi
    if [[ "$has_warnings" == true ]]; then
        return 1
    fi

    return 0

}

verify_workspace_repositories() {
    verification_items_selected git-repositories || return 0
    local file candidates records repository path remote branch result predicate kind
    file="$(blueprint_generated_file git-repositories)"
    # The existing input reader applies Blueprint selection and path safety.
    if ! records="$(workspace_read_bootstrap_repositories "$file" observation)" ||
       ! candidates="$(config_sections "$file")"; then
        verification_input_error git-repositories
        return 0
    fi
    verification_select_subjects git-repositories "$candidates" || return 2
    while IFS=$'\t' read -r repository path remote branch; do
        [[ -n "$repository" ]] || continue
        repository_inspect "$path" "$remote" "$branch"
        verification_result git-repositories "$repository" worktree "$REPOSITORY_WORKTREE_RESULT" '' "$REPOSITORY_WORKTREE_KIND"
        for predicate in origin branch; do
            if [[ "$predicate" == origin ]]; then result=$REPOSITORY_ORIGIN_RESULT; else result=$REPOSITORY_BRANCH_RESULT; fi
            if [[ $result -eq 3 ]]; then
                verification_record git-repositories "$repository" "$predicate" unverified supported ""
                verification_diagnostic "$GV_LAST_REF" prerequisite_unmet warning observation
            else
                if [[ "$predicate" == origin ]]; then kind=$REPOSITORY_ORIGIN_KIND; else kind=$REPOSITORY_BRANCH_KIND; fi
                verification_result git-repositories "$repository" "$predicate" "$result" '' "$kind"
            fi
        done
    done <<< "$records"
}
