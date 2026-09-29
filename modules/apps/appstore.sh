#!/bin/bash

# ==========================================
# Install App Store Application
# ==========================================

read_appstore_configuration() {

    local config_file="$1"

    [[ -f "$config_file" && -r "$config_file" ]] || return 2

    LC_ALL=C awk -F "|" '
        /^$/ || /^#/ { next }
        {
            if (NF != 2 || $1 !~ /^[0-9]+$/ || $2 == "" || $2 ~ /^-/ ||
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
    inventory="$(MAS_NO_AUTO_INDEX=1 mas list)" || return 2
    # Prefix both operands to prevent awk from comparing IDs numerically.
    LC_ALL=C awk -v app_id="$1" '
        { if (("id:" $1) == ("id:" app_id)) found=1 }
        END { exit(found ? 0 : 1) }
    ' <<< "$inventory"

}

# ==========================================
# Preview App Store Applications
# ==========================================

preview_appstore_apps() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items app-store)" ]]; then
        return 0
    fi

    local config_file
    config_file="$(blueprint_generated_file app-store)"

    local applications
    if ! applications="$(read_appstore_configuration "$config_file")"; then
        error "App Store configuration missing, unreadable, or malformed: $config_file"
        return 2
    fi

    if ! command -v mas >/dev/null 2>&1; then
        warning "mas is not installed"
        return 1
    fi

    local app_id
    local app_name
    local inspection_result

    while IFS='|' read -r app_id app_name || [[ -n "$app_id" ]]; do
        [[ -z "$app_id" ]] && continue
        [[ "$app_id" =~ ^# ]] && continue
        blueprint_item_selected app-store "$app_id" || continue

        is_appstore_app_installed "$app_id"
        inspection_result=$?

        case $inspection_result in
            0) detail "$app_name is already installed" ;;
            1) preview_action "Would install App Store app: $app_name ($app_id)" ;;
            *)
                error "Failed to inspect App Store application: $app_name"
                return 2
                ;;
        esac
    done <<< "$applications"

    return 0

}

install_appstore_app() {

    local app_id="$1"
    local app_name="$2"

    action "Installing $app_name..."

    if [[ "$VERBOSE" == true ]]; then

    MAS_NO_AUTO_INDEX=1 mas install "$app_id"

else

    MAS_NO_AUTO_INDEX=1 mas install "$app_id" >/dev/null 2>&1

fi

if [[ $? -eq 0 ]]; then

    return 0

fi

error "Failed to install $app_name"
return 2

}

# ==========================================
# Install App Store Applications
# ==========================================

install_appstore_apps() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items app-store)" ]]; then
        success "No App Store applications selected by Blueprint"
        return 0
    fi

    local config_file
    config_file="$(blueprint_generated_file app-store)"

    local applications
    if ! applications="$(read_appstore_configuration "$config_file")"; then

        error "App Store configuration missing, unreadable, or malformed: $config_file"
        return 2

    fi

    if ! command -v mas >/dev/null 2>&1; then
        warning "mas is not installed"
        return 1
    fi

    local missing_apps=0
    local inspection_result

    while IFS='|' read -r app_id app_name || [[ -n "$app_id" ]]; do

        [[ -z "$app_id" ]] && continue
        [[ "$app_id" =~ ^# ]] && continue
        blueprint_item_selected app-store "$app_id" || continue

        is_appstore_app_installed "$app_id"
        inspection_result=$?

        if [[ $inspection_result -eq 0 ]]; then

            detail "$app_name is already installed"
            continue

        fi

        if [[ $inspection_result -ne 1 ]]; then
            error "Failed to inspect App Store application: $app_name"
            return 2
        fi

        ((missing_apps++))

        if [[ $missing_apps -eq 1 ]]; then

            action "Installing App Store Applications..."
            echo

        fi

        install_appstore_app "$app_id" "$app_name"

        if [[ $? -ne 0 ]]; then
            return 2
        fi

        # Shared lifecycle flag is read by the calling module wrapper.
        # shellcheck disable=SC2034
        MODULE_CHANGED=true

        if ! is_appstore_app_installed "$app_id"; then
            error "Failed to verify App Store application: $app_name"
            return 2
        fi

        success "$app_name installed successfully"

    done <<< "$applications"

    if [[ $missing_apps -eq 0 ]]; then

        success "All App Store applications are installed."
        return 0

    fi

    echo
    success "App Store applications are ready"

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
    for item in "${GV_SUBJECTS[@]}"; do
        if ! command -v mas >/dev/null 2>&1; then
            verification_record app-store "$item" installed unverified supported "" || return 2
            verification_diagnostic "$GV_LAST_REF" dependency_unavailable warning observation
            continue
        fi
        is_appstore_app_installed "$item"
        result=$?
        verification_result app-store "$item" installed "$result" || return 2
    done
}
