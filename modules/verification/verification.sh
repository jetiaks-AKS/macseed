#!/bin/bash

# Scope/dispatch only. Comparisons remain with production domain readers.
verification_result() {
    local domain="$1" subject="$2" predicate="$3" result="$4" code="${5:-}" conformity
    case "$result" in
        0) conformity=verified ;;
        1) conformity=mismatch; code="${code:-confirmed_mismatch}" ;;
        *) conformity=unverified; code="${code:-observation_failed}" ;;
    esac
    verification_record "$domain" "$subject" "$predicate" "$conformity" supported "$(date -u +%Y-%m-%dT%H:%M:%SZ)" || return 2
    if [[ -n "$code" ]]; then
        local severity=error
        [[ "$result" != 1 && "$code" != external_management ]] || severity=warning
        verification_diagnostic "$GV_LAST_REF" "$code" "$severity" observation
    fi
    return 0
}

verification_input_error() {
    verification_coverage "$1" "${2:-scope}" unresolved unknown
    verification_diagnostic "$GV_LAST_REF" input_invalid error scope
    GV_STATUS=incomplete
}

# Resolve references against validated candidates, never against target state.
verification_select_subjects() {
    local domain="$1" candidates="$2" item selected="$2" found candidate
    GV_SUBJECTS=()
    if blueprint_exists; then
        if [[ "$domain" != git-configuration ]] || blueprint_item_section_exists "$domain"; then
            selected="$(blueprint_selected_items "$domain")" || return 2
        fi
    fi
    while IFS= read -r item; do
        [[ -n "$item" ]] || continue
        found=false
        while IFS= read -r candidate; do
            [[ "$candidate" != "$item" ]] || found=true
        done <<< "$candidates"
        if [[ "$found" == true ]]; then
            verification_coverage "$domain" "$item" resolved unknown
            GV_SUBJECTS+=("$item")
        else
            verification_coverage "$domain" "$item" unresolved unknown
            verification_diagnostic "$GV_LAST_REF" selected_input_unresolved warning scope
        fi
    done <<< "$selected"
    while IFS= read -r candidate; do
        [[ -n "$candidate" ]] || continue
        found=false
        while IFS= read -r item; do
            [[ "$candidate" != "$item" ]] || found=true
        done <<< "$selected"
        [[ "$found" == true ]] || verification_coverage "$domain" "$candidate" excluded unknown
    done <<< "$candidates"
    if [[ -z "$selected" ]]; then
        verification_coverage "$domain" scope no_requirement unknown
    fi
}

verification_category_selected() {
    if blueprint_category_enabled "$1"; then return 0; fi
    verification_coverage "$1" scope excluded unknown
    return 1
}

verification_items_selected() {
    if blueprint_exists && [[ -z "$(blueprint_selected_items "$1")" ]]; then
        verification_coverage "$1" scope excluded unknown
        return 1
    fi
    return 0
}

verification_unsupported() {
    verification_record "$1" "$2" "$3" unverified unsupported "" || return 2
    verification_diagnostic "$GV_LAST_REF" unsupported_predicate warning scope
}

# Explicit known inputs only, including coverage-only domains. Hash bytes and
# absence markers, not values re-serialized through a second configuration model.
verification_input_identity() (
    set -o pipefail
    {
        printf '%s\0' "$HOME" "${BLUEPRINT_FILE:-config/blueprint.conf}" \
            "${BUNDLE_RESTORE_SECURE_FILE:+secure-selected}"
        local path domain
        verification_hash_input "${BLUEPRINT_FILE:-config/blueprint.conf}" || exit 2
        for domain in homebrew-packages homebrew-casks app-store vscode-extensions workspace-folders git-repositories; do
            if blueprint_exists && [[ -z "$(blueprint_selected_items "$domain")" ]]; then continue; fi
            path="$(blueprint_generated_file "$domain")" || exit 2
            verification_hash_input "$path" || exit 2
        done
        for domain in git-configuration ssh-configuration shell-zsh vscode-settings macos-finder macos-dock macos-windows macos-keyboard macos-trackpad macos-screenshots; do
            blueprint_category_enabled "$domain" || continue
            case "$domain" in
                git-configuration) git_configuration_scope_selected || continue; path="$GIT_CONFIGURATION_FILE" ;;
                ssh-configuration) path="$SSH_SNAPSHOT_FILE" ;;
                shell-zsh) path="$ZSH_SNAPSHOT_FILE" ;;
                vscode-settings) path="$BLUEPRINT_GENERATED_DIR/vscode/settings.json" ;;
                macos-*) path="$BLUEPRINT_GENERATED_DIR/macos/${domain#macos-}.conf" ;;
            esac
            verification_hash_input "$path" || exit 2
        done
    } | shasum -a 256
)

verification_hash_input() {
    local path="$1"
    printf '%s\0' "$path"
    if [[ -e "$path" || -L "$path" ]]; then
        [[ -f "$path" && -r "$path" ]] || return 2
        shasum -a 256 "$path" || return 2
    else
        printf 'absent\0'
    fi
}

# No target inspection for domains outside Batch 1. Enumerate known input
# predicates solely to make missing verification coverage visible.
verification_uncovered_scope() {
    local domain file records item category value key type result
    for domain in homebrew-casks app-store vscode-extensions workspace-folders; do
        verification_items_selected "$domain" || continue
        file="$(blueprint_generated_file "$domain")"
        case "$domain" in
            homebrew-casks) records="$(read_brew_casks_configuration "$file")"; result=$? ;;
            app-store) records="$(read_appstore_configuration "$file")"; result=$? ;;
            vscode-extensions) records="$(read_vscode_extensions_configuration "$file")"; result=$? ;;
            workspace-folders)
                records="$(blueprint_workspace_folder_candidates "$file")"; result=$? ;;
        esac
        if [[ $result -ne 0 ]]; then verification_input_error "$domain"; continue; fi
        if [[ "$domain" == app-store ]]; then records="$(cut -d '|' -f 1 <<< "$records")"; fi
        verification_select_subjects "$domain" "$records" || return 2
        for item in "${GV_SUBJECTS[@]}"; do
            if [[ "$domain" == workspace-folders ]]; then
                verification_unsupported "$domain" "$item" directory
            else
                verification_unsupported "$domain" "$item" installed
            fi
        done
    done
    for category in finder dock windows keyboard trackpad screenshots; do
        domain="macos-$category"
        verification_category_selected "$domain" || continue
        file="$BLUEPRINT_GENERATED_DIR/macos/$category.conf"
        if ! validate_defaults_config "$file" "$category"; then verification_input_error "$domain"; continue; fi
        local any=false
        # Coverage uses record identity only; values stay with the domain reader.
        # shellcheck disable=SC2034
        while IFS='|' read -r item key type value; do
            [[ -n "${item// /}" ]] || continue
            any=true
            verification_coverage "$domain" "$item/$key" resolved unknown
            verification_unsupported "$domain" "$item/$key" stored_preference
            if [[ "$category" == screenshots ]]; then
                verification_unsupported "$domain" destination directory
            fi
        done < "$file"
        [[ "$any" == true ]] || verification_coverage "$domain" scope no_requirement unknown
    done
    if verification_category_selected vscode-settings; then
        validate_vscode_settings_source "$BLUEPRINT_GENERATED_DIR/vscode/settings.json"
        result=$?
        case "$result" in
            0)
                verification_coverage vscode-settings settings.json resolved unknown
                verification_unsupported vscode-settings settings.json file_content ;;
            1)
                verification_coverage vscode-settings scope unresolved unknown
                verification_diagnostic "$GV_LAST_REF" selected_input_unresolved warning scope ;;
            *) verification_input_error vscode-settings ;;
        esac
    fi
    if verification_category_selected shell-zsh; then
        zsh_snapshot_validate
        result=$?
        if [[ $result -eq 1 ]] && ! blueprint_exists; then
            verification_coverage shell-zsh scope no_requirement unknown
        elif [[ $result -ne 0 ]]; then
            verification_input_error shell-zsh
        else
            case "$ZSH_SNAPSHOT_STATUS" in
                eligible)
                    verification_coverage shell-zsh .zshrc resolved observed_present
                    verification_unsupported shell-zsh .zshrc file_content ;;
                absent) verification_coverage shell-zsh scope no_requirement observed_absent ;;
                *)
                    verification_coverage shell-zsh scope unresolved partial
                    verification_diagnostic "$GV_LAST_REF" unsupported_predicate warning scope ;;
            esac
        fi
    fi
}

# Run context is consumed by the separately sourced Core collector/report.
# shellcheck disable=SC2034
verification_run() {
    GV_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    GV_STATUS=complete
    local final_identity
    if ! GV_INPUT_ID="$(verification_input_identity)"; then
        verification_input_error selected-input
    elif ! blueprint_validate_syntax_if_present; then
        verification_input_error blueprint
    else
        verify_brew_packages || verification_input_error homebrew-packages
        verify_git_configuration || verification_input_error git-configuration
        verify_ssh_configuration || verification_input_error ssh-configuration
        verify_workspace_repositories || verification_input_error git-repositories
        verification_uncovered_scope || verification_input_error uncovered-scope
        if [[ -n "${BUNDLE_RESTORE_SECURE_FILE:-}" ]]; then
            verification_coverage ssh-identities secure-selection unresolved unknown
            verification_diagnostic "$GV_LAST_REF" unsupported_predicate warning scope
        fi
        if ! final_identity="$(verification_input_identity)" || [[ "$final_identity" != "$GV_INPUT_ID" ]]; then
            GV_STATUS=incomplete
            verification_diagnostic run input_changed error scope
        fi
    fi
    GV_FINISHED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    verification_report
    # Internal facts do not redefine existing command exit codes in Batch 1.
    return 0
}

blueprint_validate_syntax_if_present() {
    blueprint_exists || return 0
    blueprint_validate_syntax "$BLUEPRINT_FILE"
}
