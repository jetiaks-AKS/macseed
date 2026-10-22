#!/bin/bash

OBSERVED_VSCODE_STATUS=
observe_vscode_inventory() {
    local inventory
    if ! inventory="$(vscode_cli --list-extensions)"; then
        case "$inventory" in
            reason:vscode_inventory_deadline|reason:vscode_process_observation_failed|reason:vscode_quiescence_unconfirmed|reason:vscode_lifecycle_state_failed|reason:vscode_lifecycle_pending|reason:vscode_cli_delegation_unsupported|reason:cancelled|reason:vscode_process_interrupted)
                error "${inventory#reason:}" ;;
            *) error "vscode_inventory_observation_failed" ;;
        esac
        return 2
    fi
    LC_ALL=C awk '/^$/ { next } { if ($0 !~ /^[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_-]*$/) exit 2; print }' <<< "$inventory"
}

# ==========================================
# Check VS Code CLI
# ==========================================

read_vscode_extensions_configuration() {

    local config_file="$1"

    [[ -f "$config_file" && -r "$config_file" ]] || return 2

    LC_ALL=C awk '
        /^$/ || /^#/ { next }
        {
            if ($0 !~ /^[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_-]*$/ ||
                tolower($0) ~ /\.vsix$/) exit 2
            print
        }
    ' "$config_file" || return 2

    return 0

}

# PATH selects an explicit installation. Application callers can also use the
# documented bundled CLI of stable VS Code, without publishing a PATH change.
vscode_cli_resolve() {
    VSCODE_CLI_COMMAND=code
    VSCODE_CLI_CONDITION=vscode_cli_required
    command -v code >/dev/null 2>&1 && return 0
    [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]] || return 1

    local directory
    local -a directories
    IFS=: read -r -a directories <<< "$PATH"
    for directory in "${directories[@]}"; do
        [[ -n "$directory" ]] || directory=.
        if [[ -e "$directory/code" || -L "$directory/code" ]]; then
            VSCODE_CLI_CONDITION=vscode_cli_unavailable
            return 2
        fi
    done
    local app selected="" count=0
    for app in "/Applications/Visual Studio Code.app" "$HOME/Applications/Visual Studio Code.app"; do
        [[ -e "$app" || -L "$app" ]] || continue
        selected="$app"
        ((count++))
    done
    if [[ $count -gt 1 ]]; then
        VSCODE_CLI_CONDITION=vscode_cli_ambiguous
        return 2
    fi
    [[ $count -ne 0 ]] || return 1
    VSCODE_CLI_COMMAND="$selected/Contents/Resources/app/bin/code"
    if [[ ! -f "$VSCODE_CLI_COMMAND" || ! -x "$VSCODE_CLI_COMMAND" ]]; then
        VSCODE_CLI_CONDITION=vscode_cli_unavailable
        return 2
    fi
    return 0
}

vscode_cli() {
    vscode_cli_resolve || return 2
    python3 -B modules/vscode/cli_execution.py "$VSCODE_CLI_COMMAND" "$@" 2>/dev/null
}

check_vscode_cli() {

    if vscode_cli_resolve; then
        return 0
    fi

    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        warning "$VSCODE_CLI_CONDITION"
    else
        warning "The 'code' command is not available"
    fi
    return 1

}

# ==========================================
# Install VS Code Extension
# ==========================================

# Presence: 0 installed, 1 absent, 2 observation error.
is_vscode_extension_installed() {

    local inventory
    if [[ "${OBSERVED_VSCODE_STATUS:-}" == pending ]]; then
        OBSERVED_VSCODE_STATUS=2
        OBSERVED_VSCODE_INVENTORY="$(observe_vscode_inventory)" && OBSERVED_VSCODE_STATUS=0
    fi
    if [[ -n "${OBSERVED_VSCODE_STATUS:-}" ]]; then
        [[ "$OBSERVED_VSCODE_STATUS" == 0 ]] || return 2
        inventory="$OBSERVED_VSCODE_INVENTORY"
    else
        inventory="$(observe_vscode_inventory)" || return 2
    fi
    grep -Fxq -- "$1" <<< "$inventory"

}

# ==========================================
# Preview VS Code Extensions
# ==========================================

preview_vscode_extensions() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items vscode-extensions)" ]]; then
        return 0
    fi

    local config_file
    config_file="$(blueprint_generated_file vscode-extensions)"

    local extensions
    if ! extensions="$(read_vscode_extensions_configuration "$config_file")"; then
        error "VS Code extensions configuration missing, unreadable, or malformed: $config_file"
        return 2
    fi

    check_vscode_cli || return 1

    local extension
    local inspection_result
    local OBSERVED_VSCODE_STATUS='' OBSERVED_VSCODE_INVENTORY
    if [[ "${BUNDLE_RESTORE_PREVIEW:-false}" == true && "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        OBSERVED_VSCODE_STATUS=pending
    fi

    while IFS= read -r extension || [[ -n "$extension" ]]; do
        [[ -z "$extension" ]] && continue
        [[ "$extension" =~ ^# ]] && continue
        blueprint_item_selected vscode-extensions "$extension" || continue

        is_vscode_extension_installed "$extension"
        inspection_result=$?
        case $inspection_result in
            0) preview_record vscode-extensions "$extension" none satisfied ;;
            1) preview_record vscode-extensions "$extension" install planned ;;
            *) preview_record vscode-extensions "$extension" install blocked observation_failed ;;
        esac

        case $inspection_result in
            0) detail "$extension is already installed" ;;
            1) preview_action "Would install VS Code extension: $extension" ;;
            *)
                if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
                    warning "vscode_cli_unavailable: extension inventory could not be read"
                    return 1
                fi
                error "Failed to inspect VS Code extension: $extension"
                return 2
                ;;
        esac
    done <<< "$extensions"

    return 0

}

install_vscode_extension() {

    local extension="$1"
    local report field value
    # Process-local facts; the public module status remains 0/1/2. The exact
    # native status belongs to the existing Core technical log, not new V1 fields.
    VSCODE_INSTALL_EXIT_CODE=2
    VSCODE_INSTALL_REASON=unknown
    VSCODE_INSTALL_DIAGNOSTIC_VALID=false
    VSCODE_INSTALL_QUIESCENT=false

    command -v python3 >/dev/null 2>&1 && [[ -r modules/vscode/cli_execution.py ]] || {
        error "VS Code CLI diagnostics are unavailable"
        return 2
    }

    action "Installing $extension..."

    # The supervisor drains opaque output and emits only bounded typed facts.
    report="$(vscode_cli --install-extension "$extension")"
    while IFS=: read -r field value; do
        case "$field:$value" in
            reason:network_reset|reason:unknown|reason:vscode_install_deadline|reason:vscode_process_observation_failed|reason:vscode_quiescence_unconfirmed|reason:vscode_lifecycle_state_failed|reason:vscode_lifecycle_pending|reason:vscode_cli_delegation_unsupported|reason:cancelled|reason:vscode_process_interrupted)
                VSCODE_INSTALL_REASON="$value" ;;
            exit:*) [[ "$value" =~ ^[0-9]+$ && "$value" -le 255 ]] && VSCODE_INSTALL_EXIT_CODE="$value" ;;
            reader:0) VSCODE_INSTALL_DIAGNOSTIC_VALID=true ;;
            quiescence:confirmed) VSCODE_INSTALL_QUIESCENT=true ;;
        esac
    done <<< "$report"
    [[ "$VSCODE_INSTALL_DIAGNOSTIC_VALID" == true ]] || VSCODE_INSTALL_REASON=unknown
    detail "VS Code CLI result: exit_code=$VSCODE_INSTALL_EXIT_CODE reason=$VSCODE_INSTALL_REASON"

    if [[ "$VSCODE_INSTALL_EXIT_CODE" -eq 0 && "$VSCODE_INSTALL_QUIESCENT" == true &&
          "$VSCODE_INSTALL_DIAGNOSTIC_VALID" == true ]]; then
        return 0
    fi

    error "Failed to install $extension (exit_code=$VSCODE_INSTALL_EXIT_CODE; reason=$VSCODE_INSTALL_REASON)"
    return 2

}

# ==========================================
# Install VS Code Extensions
# ==========================================

install_vscode_extensions() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items vscode-extensions)" ]]; then
        success "No VS Code extensions selected by Blueprint"
        return 0
    fi

    local config_file
    config_file="$(blueprint_generated_file vscode-extensions)"

    local extensions
    if ! extensions="$(read_vscode_extensions_configuration "$config_file")"; then

        error "VS Code extensions configuration missing, unreadable, or malformed: $config_file"
        return 2

    fi

    if ! check_vscode_cli; then
        if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
            error "$VSCODE_CLI_CONDITION"
            return 2
        fi
        return 1
    fi

    local missing_extensions=0 failures=0
    local inspection_result before_inventory
    local OBSERVED_VSCODE_STATUS='' OBSERVED_VSCODE_INVENTORY

    while IFS= read -r extension || [[ -n "$extension" ]]; do

        [[ -z "$extension" ]] && continue
        [[ "$extension" =~ ^# ]] && continue
        blueprint_item_selected vscode-extensions "$extension" || continue
        if declare -F application_stop_checkpoint >/dev/null; then application_stop_checkpoint "$failures"; fi

        OBSERVED_VSCODE_STATUS=pending
        is_vscode_extension_installed "$extension"
        inspection_result=$?
        before_inventory="$OBSERVED_VSCODE_INVENTORY"

        if [[ $inspection_result -eq 0 ]]; then

            declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook vscode-extensions "$extension" install noop
            detail "$extension is already installed"
            continue

        fi

        if [[ $inspection_result -ne 1 ]]; then
            error "Failed to inspect VS Code extension: $extension"
            return 2
        fi

        ((missing_extensions++))

        if [[ $missing_extensions -eq 1 ]]; then

            action "Installing VS Code Extensions..."
            echo

        fi

        if declare -F application_stop_checkpoint >/dev/null; then application_stop_checkpoint "$failures"; fi
        declare -F verification_applying_hook >/dev/null && verification_applying_hook vscode-extensions "$extension" install
        install_vscode_extension "$extension"

        if [[ $? -ne 0 ]]; then
            declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook vscode-extensions "$extension" install failure "$VSCODE_INSTALL_REASON"
            failures=2
            if declare -F application_stop_checkpoint >/dev/null; then application_stop_checkpoint "$failures"; fi
            # Unknown failures, signals and failed diagnostics are not proven
            # item-local. Never turn them into permission to launch more work.
            [[ "$VSCODE_INSTALL_REASON" == network_reset &&
               "$VSCODE_INSTALL_DIAGNOSTIC_VALID" == true &&
               "$VSCODE_INSTALL_QUIESCENT" == true &&
               "$VSCODE_INSTALL_EXIT_CODE" -gt 0 && "$VSCODE_INSTALL_EXIT_CODE" -lt 128 ]] || return 2

            OBSERVED_VSCODE_STATUS=pending
            is_vscode_extension_installed "$extension"
            inspection_result=$?
            if [[ "$OBSERVED_VSCODE_STATUS" != 0 ]]; then
                error "Failed to inspect VS Code extensions after installation failure"
                return 2
            fi
            if [[ "$OBSERVED_VSCODE_INVENTORY" != "$before_inventory" ]]; then
                error "VS Code extension inventory changed during a failed installation; further installs stopped"
                return 2
            fi
            [[ "$inspection_result" -eq 1 ]] || return 2
            # Pack/dependency installation remains owned by the VS Code CLI. A
            # later pack may retry its requirements; no dependency is guessed.
            continue
        fi
        declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook vscode-extensions "$extension" install success

        # Shared lifecycle flag is read by the calling module wrapper.
        # shellcheck disable=SC2034
        MODULE_CHANGED=true

        OBSERVED_VSCODE_STATUS=pending
        is_vscode_extension_installed "$extension"
        inspection_result=$?
        declare -F verification_application_post_hook >/dev/null && verification_application_post_hook "$inspection_result"
        if [[ $inspection_result -ne 0 ]]; then
            error "Failed to verify VS Code extension: $extension"
            return 2
        fi

        success "$extension installed successfully"

    done <<< "$extensions"

    if [[ "$failures" -ne 0 ]]; then
        error "Some VS Code extensions failed; independent work completed where safe"
        return 2
    fi

    if [[ $missing_extensions -eq 0 ]]; then

        success "All VS Code extensions are installed."
        return 0

    fi

    echo
    success "VS Code Extensions are ready"

}

# Installed ID only, not version, enablement or runtime behavior.
verify_vscode_extensions() {
    verification_items_selected vscode-extensions || return 0
    local records item result
    records="$(read_vscode_extensions_configuration "$(blueprint_generated_file vscode-extensions)")" || {
        verification_input_error vscode-extensions; return 0;
    }
    verification_select_subjects vscode-extensions "$records" || return 2
    [[ ${#GV_SUBJECTS[@]} -gt 0 ]] || return 0
    local OBSERVED_VSCODE_STATUS=2 OBSERVED_VSCODE_INVENTORY
    OBSERVED_VSCODE_INVENTORY="$(observe_vscode_inventory)" && OBSERVED_VSCODE_STATUS=0
    local observed_at
    observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for item in "${GV_SUBJECTS[@]}"; do
        if ! vscode_cli_resolve; then
            verification_record vscode-extensions "$item" installed unverified supported "" || return 2
            verification_diagnostic "$GV_LAST_REF" dependency_unavailable warning observation
            continue
        fi
        is_vscode_extension_installed "$item"
        result=$?
        verification_result vscode-extensions "$item" installed "$result" '' absent "$observed_at" || return 2
    done
}
