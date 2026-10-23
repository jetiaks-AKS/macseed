#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/../core/application-interface/observation.sh" || return 2

OBSERVED_MAS_STATUS=
observe_appstore_inventory() {
    local inventory
    command -v mas >/dev/null 2>&1 || return 2
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        inventory="$(MAS_NO_AUTO_INDEX=1 application_observe inventory mas list 2>/dev/null)" || return 2
    else
        inventory="$(MAS_NO_AUTO_INDEX=1 mas list)" || return 2
    fi
    LC_ALL=C awk '/^$/ { next } { line=$0; gsub(/\t/, "", line); if ($1 !~ /^[0-9]+$/ || $1 ~ /^0+$/ || length($1) > 20 || NF < 2 || line ~ /[[:cntrl:]]/) exit 2; print }' <<< "$inventory"
}

# App Store Restore is assisted: observation only, never installation or sudo.
# Keep the configuration reader and observer shared by Preview and Verification.
read_appstore_configuration() {

    local config_file="$1"

    [[ -f "$config_file" && -r "$config_file" ]] || return 2

    LC_ALL=C awk -F "|" '
        /^$/ || /^#/ { next }
        {
            if (NF != 2 || $1 !~ /^[0-9]+$/ || $1 ~ /^0+$/ || length($1) > 20 || $2 == "" || $2 ~ /^-/ ||
                $2 ~ /^[[:space:]]/ || $2 ~ /[[:space:]]$/ ||
                $2 ~ /[[:cntrl:]]/) exit 2
            print
        }
    ' "$config_file" || return 2

    return 0

}

# Presence: 0 installed, 1 absent, 2 observation error.
is_appstore_app_installed() {

    local inventory
    if [[ "${OBSERVED_MAS_STATUS:-}" == pending ]]; then
        OBSERVED_MAS_STATUS=2
        OBSERVED_MAS_INVENTORY="$(observe_appstore_inventory)" && OBSERVED_MAS_STATUS=0
    fi
    if [[ -n "${OBSERVED_MAS_STATUS:-}" ]]; then
        [[ "$OBSERVED_MAS_STATUS" == 0 ]] || return 2
        inventory="$OBSERVED_MAS_INVENTORY"
    else
        inventory="$(observe_appstore_inventory)" || return 2
    fi
    # Prefix both operands to prevent awk from comparing IDs numerically.
    LC_ALL=C awk -v app_id="$1" '
        { if (("id:" $1) == ("id:" app_id)) found=1 }
        END { exit(found ? 0 : 1) }
    ' <<< "$inventory"

}

# Preview every selected ID, including uncertain observations. Missing apps require
# a user action outside Macseed; neither missing nor unverified blocks other domains.
preview_appstore_apps() {
    if blueprint_exists && [[ -z "$(blueprint_selected_items app-store)" ]]; then
        return 0
    fi
    local applications app_id app_name result status=0
    applications="$(read_appstore_configuration "$(blueprint_generated_file app-store)")" || {
        error "App Store configuration missing, unreadable, or malformed"
        return 2
    }
    local OBSERVED_MAS_STATUS=pending OBSERVED_MAS_INVENTORY
    while IFS='|' read -r app_id app_name || [[ -n "$app_id" ]]; do
        [[ -n "$app_id" && "$app_id" != \#* ]] || continue
        blueprint_item_selected app-store "$app_id" || continue
        is_appstore_app_installed "$app_id"
        result=$?
        case "$result" in
            0)
                preview_record app-store "$app_id" inspect satisfied
                detail "$app_name is installed"
                ;;
            1)
                preview_record app-store "$app_id" inspect warning manual_installation_required
                warning "Install in App Store, then refresh: $app_name ($app_id)"
                status=1
                ;;
            *)
                preview_record app-store "$app_id" inspect unknown observation_failed
                warning "App Store installation status could not be verified: $app_name ($app_id)"
                status=1
                ;;
        esac
    done <<< "$applications"
    return "$status"
}

# Retained as a fail-closed compatibility entrypoint for old callers. All active
# orchestration uses install_appstore_apps, which only observes selected IDs.
install_appstore_app() {
    warning "Automatic App Store installation is unavailable. Install in App Store, then refresh."
    return 1
}

install_appstore_apps() {
    if blueprint_exists && [[ -z "$(blueprint_selected_items app-store)" ]]; then
        success "No App Store applications selected by Blueprint"
        return 0
    fi
    local applications app_id app_name result status=0
    applications="$(read_appstore_configuration "$(blueprint_generated_file app-store)")" || {
        error "App Store configuration missing, unreadable, or malformed"
        return 2
    }
    local OBSERVED_MAS_STATUS=pending OBSERVED_MAS_INVENTORY
    while IFS='|' read -r app_id app_name || [[ -n "$app_id" ]]; do
        [[ -n "$app_id" && "$app_id" != \#* ]] || continue
        blueprint_item_selected app-store "$app_id" || continue
        if declare -F application_stop_checkpoint >/dev/null; then application_stop_checkpoint; fi
        is_appstore_app_installed "$app_id"
        result=$?
        case "$result" in
            0)
                declare -F verification_application_operation_hook >/dev/null &&
                    verification_application_operation_hook app-store "$app_id" inspect noop
                detail "$app_name is installed"
                ;;
            1)
                declare -F verification_application_operation_hook >/dev/null &&
                    verification_application_operation_hook app-store "$app_id" inspect skipped manual_installation_required
                warning "Install in App Store, then refresh: $app_name ($app_id)"
                status=1
                ;;
            *)
                declare -F verification_application_operation_hook >/dev/null &&
                    verification_application_operation_hook app-store "$app_id" inspect skipped observation_failed
                warning "App Store installation status could not be verified: $app_name ($app_id)"
                status=1
                ;;
        esac
    done <<< "$applications"
    if [[ "$status" -eq 0 ]]; then success "All selected App Store applications are installed"; fi
    return "$status"
}

# Inventory presence only; unavailable mas does not imply an absent app.
verify_appstore_apps() {
    verification_items_selected app-store || return 0
    local records item result
    records="$(read_appstore_configuration "$(blueprint_generated_file app-store)")" || {
        verification_input_error app-store; return 0;
    }
    records="$(cut -d '|' -f 1 <<< "$records")" || return 2
    verification_select_subjects app-store "$records" || return 2
    [[ ${#GV_SUBJECTS[@]} -gt 0 ]] || return 0
    local OBSERVED_MAS_STATUS=2 OBSERVED_MAS_INVENTORY
    if command -v mas >/dev/null 2>&1; then
        OBSERVED_MAS_INVENTORY="$(observe_appstore_inventory)" && OBSERVED_MAS_STATUS=0
    fi
    local observed_at
    observed_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    for item in "${GV_SUBJECTS[@]}"; do
        if ! command -v mas >/dev/null 2>&1; then
            verification_record app-store "$item" installed unverified supported "" || return 2
            verification_diagnostic "$GV_LAST_REF" dependency_unavailable warning observation
            continue
        fi
        is_appstore_app_installed "$item"
        result=$?
        verification_result app-store "$item" installed "$result" '' absent "$observed_at" || return 2
    done
}
