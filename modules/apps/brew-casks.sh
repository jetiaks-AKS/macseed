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

CASK_REINSTALL_REQUIRED=false

is_cask_installed() {

    local cask="$1"
    local installed_casks
    local metadata
    local app_paths
    local app_path
    local HOMEBREW_NO_AUTO_UPDATE="${HOMEBREW_NO_AUTO_UPDATE:-}"
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        HOMEBREW_NO_AUTO_UPDATE=1
        export HOMEBREW_NO_AUTO_UPDATE
    fi

    CASK_REINSTALL_REQUIRED=false

    if ! installed_casks="$(brew list --cask)"; then
        return 2
    fi

    if ! grep -Fxq "$cask" <<< "$installed_casks"; then
        return 1
    fi

    if ! metadata="$(brew info --json=v2 --cask "$cask")"; then
        return 2
    fi

    if ! app_paths="$(jq -er \
        'if (.casks | type) != "array" or (.casks | length) != 1 then
            error("Expected one cask")
         else .casks[0].artifacts end |
         if type != "array" then error("Expected artifacts array") else . end |
         map(if type != "object" then error("Invalid artifact") else . end |
             select(.target != null) | .target |
             if type != "string" then error("Invalid artifact target")
             elif (startswith("/") | not) or (explode | any(. < 32 or . == 127)) then
                 error("Invalid artifact path")
             else . end) | join("\n")' \
        <<< "$metadata")"; then
        return 2
    fi

    while IFS= read -r app_path; do
        if [[ -n "$app_path" && ! -e "$app_path" ]]; then
            CASK_REINSTALL_REQUIRED=true
        fi
    done <<< "$app_paths"

    [[ "$CASK_REINSTALL_REQUIRED" == false ]] || return 1

    return 0

}

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
    local inspection_result

    while IFS= read -r cask || [[ -n "$cask" ]]; do
        [[ -z "$cask" ]] && continue
        [[ "$cask" =~ ^# ]] && continue
        blueprint_item_selected homebrew-casks "$cask" || continue

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
            preview_record homebrew-casks "$cask" reinstall blocked cask_repair_not_supported
            preview_action "Would reinstall Homebrew cask: $cask"
        else
            preview_record homebrew-casks "$cask" install planned
            preview_action "Would install Homebrew cask: $cask"
        fi
    done <<< "$casks"

    return 0

}

# A conservative metadata-only gate. Installed casks need no installer gate.
# Do not evaluate vendor scripts or duplicate Homebrew's artifact implementation.
cask_application_readiness() {
    local cask="$1" metadata targets target
    CASK_APPLICATION_CONDITION=cask_metadata_unavailable
    metadata="$(HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --cask "$cask")" || return 2
    jq -e --arg token "$cask" '
        (.casks | type == "array" and length == 1) and
        (.casks[0] | .token == $token and (.artifacts | type == "array"))
    ' <<< "$metadata" >/dev/null || return 2
    CASK_APPLICATION_CONDITION=cask_execution_requirements_unsupported
    targets="$(jq -er '
        .casks[0] |
        select(.tap == "homebrew/cask" and .disabled == false and
               (.caveats == null or .caveats == "") and .caveats_rosetta != true and
               (.depends_on | type == "object" and
                 (keys - ["macos", "arch"] | length == 0)) and
               (.container == null) and (.rename == []) and
               (.artifacts | length > 0)) |
        .artifacts |
        select(all(.[]; type == "object" and
                   (keys - ["app", "target", "uninstall", "zap"] | length == 0) and
                   ([has("app"), has("uninstall"), has("zap")] | map(select(.)) | length == 1))) |
        map(select(has("app"))) |
        select(length > 0) |
        map(select((.app | type == "array" and length > 0) and
                   (.target | type == "string" and
                     test("^/Applications/[^/]+\\.app$") and
                     (explode | all(. >= 32 and . != 127))))) |
        select(length > 0) | .[].target
    ' <<< "$metadata")" || return 2
    # Every app artifact must have passed the target validation above.
    local expected actual
    expected="$(jq '[.casks[0].artifacts[] | select(has("app"))] | length' <<< "$metadata")" || return 2
    actual="$(printf '%s\n' "$targets" | wc -l | tr -d ' ')"
    [[ "$actual" == "$expected" ]] || return 2
    while IFS= read -r target; do
        if [[ -e "$target" || -L "$target" ]]; then
            CASK_APPLICATION_CONDITION=cask_target_conflict
            return 2
        fi
        if [[ ! -d "${target%/*}" || ! -w "${target%/*}" || ! -x "${target%/*}" ]]; then
            CASK_APPLICATION_CONDITION=cask_authorization_required
            return 2
        fi
    done <<< "$targets"
    CASK_APPLICATION_CONDITION=ready
    return 0
}

brew_install_cask_command() {
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_SUDO=1 HOMEBREW_NO_ASK=1 \
            HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
            HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_CASK_OPTS='' \
            python3 -B modules/apps/brew_items.py homebrew-casks "$2" brew "$1" --cask --appdir=/Applications "$2"
    else
        HOMEBREW_NO_ENV_HINTS=1 brew "$1" --cask "$2"
    fi
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
        if [[ "$install_command" != install ]]; then
            error "cask_repair_not_supported"
            return 2
        fi
        local accepted_skip
        accepted_skip="$(python3 -B modules/apps/brew_items.py --skip-reason homebrew-casks "$cask")" || {
            error "Accepted Homebrew item state unavailable"
            return 2
        }
        if [[ "$accepted_skip" == cask_execution_requirements_unsupported ]]; then
            declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook homebrew-casks "$cask" install skipped "$accepted_skip"
            warning "Homebrew cask requires unsupported execution: $cask"
            return 2
        fi
        cask_application_readiness "$cask" || {
            if [[ "${MACSEED_APPLICATION_ALLOW_ITEM_SKIPS:-false}" == true &&
                  "$CASK_APPLICATION_CONDITION" == cask_execution_requirements_unsupported ]]; then
                declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook homebrew-casks "$cask" install skipped "$CASK_APPLICATION_CONDITION"
                warning "Homebrew cask requires unsupported execution: $cask"
            else
                error "$CASK_APPLICATION_CONDITION"
            fi
            return 2
        }
    fi

    declare -F verification_applying_hook >/dev/null && verification_applying_hook homebrew-casks "$cask" "$install_command"
    action "Installing $cask..."

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
                130) return 130 ;;
            esac
        fi
        declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook homebrew-casks "$cask" "$install_command" "$outcome" "$reason"
        error "Failed to install $cask"
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
        python3 -B modules/apps/brew_items.py --verified homebrew-casks "$cask" || {
            error "Homebrew item state unavailable after verification"
            return 2
        }
    fi
    success "$cask installed successfully"
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
        local kind=unknown
        if [[ $result -eq 1 ]]; then
            if [[ "$CASK_REINSTALL_REQUIRED" == true ]]; then kind=different; else kind=absent; fi
        fi
        verification_result homebrew-casks "$item" installed "$result" '' "$kind" || return 2
    done
}
