#!/bin/bash

# ==========================================
# Install Homebrew Cask
# ==========================================

read_brew_casks_configuration() {

    local config_file="$1"

    [[ -f "$config_file" && -r "$config_file" ]] || return 2

    LC_ALL=C awk '
        /^$/ || /^#/ { next }
        {
            if ($0 !~ /^[A-Za-z0-9][A-Za-z0-9+_.@-]*$/ ||
                tolower($0) ~ /\.(rb|json|sh|bash|zsh|dmg|pkg|zip)$/) exit 2
            print
        }
    ' "$config_file" || return 2

    return 0

}

# ==========================================
# Check Homebrew Cask
# ==========================================

source modules/apps/adapters/homebrew.sh

# ==========================================
# Preview Homebrew Casks
# ==========================================

preview_brew_casks() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items homebrew-casks)" ]]; then
        return 0
    fi

    local config_file
    config_file="$(blueprint_generated_file homebrew-casks)"

    local casks
    if ! casks="$(read_brew_casks_configuration "$config_file")"; then
        error "Cask configuration missing, unreadable, or malformed: $config_file"
        return 2
    fi

    if ! command -v brew >/dev/null 2>&1; then
        if [[ "${BUNDLE_RESTORE_PREVIEW:-false}" != true ]]; then
            error "Homebrew is not installed"
            return 2
        fi
        if [[ "${RESTORE_PREVIEW_HOMEBREW_PLANNED:-false}" != true ]]; then
            preview_action "Would offer to install Homebrew during Restore"
            RESTORE_PREVIEW_HOMEBREW_PLANNED=true
        fi
        local cask
        while IFS= read -r cask || [[ -n "$cask" ]]; do
            [[ -n "$cask" && "$cask" != \#* ]] || continue
            blueprint_item_selected homebrew-casks "$cask" || continue
            preview_record homebrew-casks "$cask" install blocked homebrew_installation_requires_interaction
            preview_action "Would install Homebrew cask after setup: $cask"
        done <<< "$casks"
        return 0
    fi

    local cask
    local inspection_result observation_status=0

    while IFS= read -r cask || [[ -n "$cask" ]]; do
        [[ -z "$cask" ]] && continue
        [[ "$cask" =~ ^# ]] && continue
        blueprint_item_selected homebrew-casks "$cask" || continue

        if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
            homebrew_adapter_classify cask "$cask" >/dev/null 2>&1
            case "$HOMEBREW_ADAPTER_STATE" in
                satisfied) preview_record homebrew-casks "$cask" none satisfied ;;
                installable)
                    preview_record homebrew-casks "$cask" install planned none "$(jq -c '{qualification_id, authorization_required}' <<< "$HOMEBREW_ADAPTER_RESULT")"
                    preview_action "Would install Homebrew cask: $cask" ;;
                repairable)
                    preview_record homebrew-casks "$cask" reinstall planned none "$(jq -c '{qualification_id, authorization_required}' <<< "$HOMEBREW_ADAPTER_RESULT")"
                    preview_action "Would repair Homebrew cask: $cask" ;;
                unsupported)
                    preview_record homebrew-casks "$cask" "${HOMEBREW_ADAPTER_OPERATION:-install}" blocked "$HOMEBREW_ADAPTER_CONDITION" "$(jq -c 'if .diagnostic then {diagnostic} else {} end' <<< "$HOMEBREW_ADAPTER_RESULT")" ;;
                *)
                    preview_record homebrew-casks "$cask" install blocked "$HOMEBREW_ADAPTER_CONDITION" "$(jq -c 'if .diagnostic then {diagnostic} else {} end' <<< "$HOMEBREW_ADAPTER_RESULT")"
                    error "Failed to qualify Homebrew cask: $cask"
                    observation_status=2 ;;
            esac
            continue
        fi
        is_cask_installed "$cask"
        inspection_result=$?

        if [[ $inspection_result -eq 0 ]]; then
            preview_record homebrew-casks "$cask" none satisfied
            detail "$cask is already installed"
            continue
        fi

        if [[ $inspection_result -ne 1 ]]; then
            error "Failed to inspect Homebrew cask: $cask"
            return 2
        fi

        if [[ "${CASK_REINSTALL_REQUIRED:-false}" == true ]]; then
            preview_record homebrew-casks "$cask" reinstall planned
            preview_action "Would repair Homebrew cask: $cask"
        else
            preview_record homebrew-casks "$cask" install planned
            preview_action "Would install Homebrew cask: $cask"
        fi
    done <<< "$casks"

    return "$observation_status"

}

install_brew_cask() {

    local cask="$1"
    local install_command="${2:-}"

    if [[ -z "$install_command" ]]; then
        is_cask_installed "$cask"
        local inspection_result=$?

        if [[ $inspection_result -eq 0 ]]; then
            return 0
        fi

        if [[ $inspection_result -ne 1 ]]; then
            error "Failed to inspect Homebrew cask: $cask"
            return 2
        fi

        install_command="install"
        if [[ "${CASK_REINSTALL_REQUIRED:-false}" == true ]]; then
            install_command="reinstall"
        fi
    fi

    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        [[ "$install_command" == install || "$install_command" == reinstall ]] || return 2
        local accepted_skip
        accepted_skip="$(python3 -B modules/apps/brew_items.py --skip-reason homebrew-casks "$cask")" || {
            error "Accepted Homebrew item state unavailable"
            return 2
        }
        if [[ "$accepted_skip" == cask_execution_requirements_unsupported ]]; then
            declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook homebrew-casks "$cask" "$install_command" skipped "$accepted_skip"
            warning "Homebrew cask requires unsupported execution: $cask"
            return 2
        fi
        cask_application_readiness "$cask" "$install_command" || {
            if [[ "${MACSEED_APPLICATION_ALLOW_ITEM_SKIPS:-false}" == true &&
                  "$CASK_APPLICATION_CONDITION" == cask_execution_requirements_unsupported ]]; then
                declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook homebrew-casks "$cask" "$install_command" skipped "$CASK_APPLICATION_CONDITION"
                warning "Homebrew cask requires unsupported execution: $cask"
            else
                error "$CASK_APPLICATION_CONDITION"
            fi
            return 2
        }
    fi

    declare -F verification_applying_hook >/dev/null && verification_applying_hook homebrew-casks "$cask" "$install_command"
    if [[ "$install_command" == reinstall ]]; then
        action "Repairing $cask..."
    else
        action "Installing $cask..."
    fi

    if [[ "$VERBOSE" == true ]]; then

        brew_install_cask_command "$install_command" "$cask"

    else

        brew_install_cask_command "$install_command" "$cask" >/dev/null 2>&1

    fi

    local install_result=$?

    if [[ $install_result -ne 0 ]]; then
        local reason='' outcome=failure
        if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
            reason=item_install_failed
            case "$install_result" in
                124) reason=item_stalled_timeout ;;
                125) reason=dependency_failed; outcome=skipped ;;
                126) reason=dependency_observation_failed ;;
                127) reason=progress_observation_failed ;;
                128) reason="$(jq -er '.reason' "$MACSEED_ITEM_STATE_DIR/homebrew-precondition.json" 2>/dev/null)" || reason=homebrew_precondition_changed; outcome=skipped ;;
                129)
                    reason=privileged_lifecycle_unknown
                    [[ -f "$MACSEED_ITEM_STATE_DIR/external-tool-active.json" ]] ||
                        printf '%s\n' '{"tool":"homebrew","state":"unknown_consequences"}' > "$MACSEED_ITEM_STATE_DIR/external-tool-active.json" ;;
                131) reason=cask_authorization_required ;;
                130) return 130 ;;
            esac
        fi
        declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook homebrew-casks "$cask" "$install_command" "$outcome" "$reason"
        error "Failed to install $cask"
        [[ "$install_result" -ne 129 ]] || return 129
        return 2
    fi

    # Shared lifecycle flag is read by the calling module wrapper.
    # shellcheck disable=SC2034
    MODULE_CHANGED=true

    declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook homebrew-casks "$cask" "$install_command" success
    is_cask_installed "$cask"
    local verify_result=$?
    declare -F verification_application_post_hook >/dev/null && verification_application_post_hook "$verify_result"
    if [[ $verify_result -ne 0 ]]; then
        error "Failed to verify Homebrew cask: $cask"
        return 2
    fi

    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        local metadata prefix
        metadata="$(HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --cask "$cask")" || return 2
        prefix="$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix)" || return 2
        python3 -B modules/apps/adapters/homebrew_cask.py "$prefix" --record <<< "$metadata" || return 2
        python3 -B modules/apps/brew_items.py --verified homebrew-casks "$cask" || {
            error "Homebrew item state unavailable after verification"
            return 2
        }
    fi
    if [[ "$install_command" == reinstall ]]; then
        success "$cask repaired successfully"
    else
        success "$cask installed successfully"
    fi
    return 0

}

# ==========================================
# Install Homebrew Casks
# ==========================================

install_brew_casks() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items homebrew-casks)" ]]; then
        success "No Homebrew casks selected by Blueprint"
        return 0
    fi

    local config_file
    config_file="$(blueprint_generated_file homebrew-casks)"

    local casks
    if ! casks="$(read_brew_casks_configuration "$config_file")"; then

        error "Cask configuration missing, unreadable, or malformed: $config_file"
        return 2

    fi

    if ! command -v brew >/dev/null 2>&1; then
        error "Homebrew is not installed"
        return 2
    fi

    local missing_casks=0
    local item_errors=0

    while IFS= read -r cask || [[ -n "$cask" ]]; do

        [[ -z "$cask" ]] && continue
        [[ "$cask" =~ ^# ]] && continue
        blueprint_item_selected homebrew-casks "$cask" || continue

        is_cask_installed "$cask"
        local inspection_result=$?

        if [[ $inspection_result -eq 0 ]]; then

            declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook homebrew-casks "$cask" install noop
            detail "$cask is already installed"
            continue

        fi

        if [[ $inspection_result -eq 2 ]]; then
            if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
                  "${MACSEED_APPLICATION_ALLOW_ITEM_SKIPS:-false}" == true &&
                  "${HOMEBREW_ADAPTER_STATE:-}" == unsupported &&
                  "${HOMEBREW_ADAPTER_CONDITION:-}" == cask_execution_requirements_unsupported ]]; then
                install_brew_cask "$cask" install
                item_errors=$((item_errors + 1))
                continue
            fi
            error "Failed to inspect Homebrew cask: $cask"
            return 2
        fi

        ((missing_casks++))

        if [[ $missing_casks -eq 1 ]]; then
            action "Installing Homebrew Casks..."
            echo
        fi

        local install_command="install"
        if [[ "${CASK_REINSTALL_REQUIRED:-false}" == true ]]; then
            install_command="reinstall"
        fi

        install_brew_cask "$cask" "$install_command"

        local item_result=$?
        if [[ $item_result -ne 0 ]]; then
            [[ $item_result -ne 130 ]] || return 130
            [[ $item_result -ne 129 ]] || return 2
            [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]] || return 2
            item_errors=$((item_errors + 1))
        fi

    done <<< "$casks"
    [[ $item_errors -eq 0 ]] || return 2

    if [[ $missing_casks -eq 0 ]]; then

        success "All Homebrew casks are installed."
        return 0

    fi

    echo
    success "Homebrew Casks are ready"

}

# Registered cask and the artifact paths observed by the production reader.
verify_brew_casks() {
    verification_items_selected homebrew-casks || return 0
    local records item result
    records="$(read_brew_casks_configuration "$(blueprint_generated_file homebrew-casks)")" || {
        verification_input_error homebrew-casks; return 0;
    }
    verification_select_subjects homebrew-casks "$records" || return 2
    for item in "${GV_SUBJECTS[@]}"; do
        is_cask_installed "$item"
        result=$?
        if [[ $result -eq 2 && "${HOMEBREW_ADAPTER_STATE:-}" == unsupported &&
              "${HOMEBREW_ADAPTER_CONDITION:-}" == cask_execution_requirements_unsupported ]]; then
            verification_unsupported homebrew-casks "$item" installed || return 2
            declare -F comparison_note >/dev/null && comparison_note unverified "$GV_LAST_REF"
            continue
        fi
        local kind=unknown
        if [[ $result -eq 1 ]]; then
            if [[ "$CASK_REINSTALL_REQUIRED" == true ]]; then kind=different; else kind=absent; fi
        fi
        verification_result homebrew-casks "$item" installed "$result" '' "$kind" || return 2
    done
}
