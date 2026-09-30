#!/bin/bash

# ==========================================
# Read and Validate Generated Formulae
# ==========================================

read_brew_packages_configuration() {

    local config_file="$1"

    [[ -f "$config_file" && -r "$config_file" ]] || return 2

    # Only formula names, optionally qualified as owner/tap/formula.
    # Emit a validated snapshot so a later record cannot fail after mutation.
    LC_ALL=C awk '
        /^$/ || /^#/ { next }
        {
            count = split($0, parts, "/")
            if (count != 1 && count != 3) exit 2
            for (i = 1; i <= count; i++) {
                if (parts[i] !~ /^[A-Za-z0-9][A-Za-z0-9+_.@-]*$/) exit 2
            }
            if (tolower($0) ~ /\.rb$/) exit 2
            print
        }
    ' "$config_file" || return 2

    return 0

}

# ==========================================
# Inspect Formula Presence (0 Present, 1 Absent, 2 Error)
# ==========================================

is_brew_package_installed() {

    local package="$1"
    local inventory

    inventory="$(brew list --formula --full-name)" || return 2

    # Discovery emits short names. Qualified inputs must match the tap too;
    # ambiguous short names are an observation error, not confirmed absence.
    LC_ALL=C awk -v package="$package" '
        {
            count = split($0, parts, "/")
            if ($0 == package || "homebrew/core/" $0 == package ||
                (index(package, "/") == 0 && parts[count] == package)) matches++
        }
        END { exit(matches > 1 ? 2 : (matches == 1 ? 0 : 1)) }
    ' <<< "$inventory"

}

# ==========================================
# Preview Homebrew Packages
# ==========================================

preview_brew_packages() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items homebrew-packages)" ]]; then
        return 0
    fi

    local config_file
    config_file="$(blueprint_generated_file homebrew-packages)"

    local packages
    if ! packages="$(read_brew_packages_configuration "$config_file")"; then
        error "Formula configuration missing, unreadable, or malformed: $config_file"
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
        local package
        while IFS= read -r package || [[ -n "$package" ]]; do
            [[ -n "$package" && "$package" != \#* ]] || continue
            blueprint_item_selected homebrew-packages "$package" || continue
            preview_action "Would install Homebrew formula after setup: $package"
        done <<< "$packages"
        return 0
    fi

    local package
    local inspection_result

    while IFS= read -r package || [[ -n "$package" ]]; do
        [[ -z "$package" ]] && continue
        [[ "$package" =~ ^# ]] && continue
        blueprint_item_selected homebrew-packages "$package" || continue

        is_brew_package_installed "$package"
        inspection_result=$?

        case $inspection_result in
            0) detail "$package is already installed" ;;
            1) preview_action "Would install Homebrew formula: $package" ;;
            *)
                error "Failed to inspect Homebrew formula: $package"
                return 2
                ;;
        esac
    done <<< "$packages"

    return 0

}

# ==========================================
# Install Homebrew Packages
# ==========================================

install_brew_packages() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items homebrew-packages)" ]]; then
        success "No Homebrew packages selected by Blueprint"
        return 0
    fi

    if ! command -v brew >/dev/null 2>&1; then

        error "Homebrew is not installed"
        return 2

    fi

    local config_file
    config_file="$(blueprint_generated_file homebrew-packages)"

    local packages
    if ! packages="$(read_brew_packages_configuration "$config_file")"; then

        error "Formula configuration missing, unreadable, or malformed: $config_file"
        return 2

    fi

    local missing_packages=0
    local package
    local inspection_result

    while IFS= read -r package || [[ -n "$package" ]]; do

        [[ -z "$package" ]] && continue
        [[ "$package" =~ ^# ]] && continue
        blueprint_item_selected homebrew-packages "$package" || continue

        is_brew_package_installed "$package"
        inspection_result=$?

        if [[ $inspection_result -eq 0 ]]; then

            declare -F verification_operation_hook >/dev/null && verification_operation_hook homebrew-packages "$package" install noop
            detail "$package is already installed"
            continue

        fi

        if [[ $inspection_result -ne 1 ]]; then
            error "Failed to inspect Homebrew formula: $package"
            return 2
        fi

        ((missing_packages++))

        if [[ $missing_packages -eq 1 ]]; then
            action "Installing Homebrew Packages..."
            echo
        fi

        action "Installing $package..."

        if [[ "$VERBOSE" == true ]]; then

            HOMEBREW_NO_ENV_HINTS=1 brew install "$package"

        else

            HOMEBREW_NO_ENV_HINTS=1 brew install "$package" >/dev/null 2>&1

        fi

        local install_result=$?
        if [[ $install_result -ne 0 ]]; then
            declare -F verification_operation_hook >/dev/null && verification_operation_hook homebrew-packages "$package" install failure

            error "Failed to install $package"
            return 2

        fi

        # Shared lifecycle flag is read by the calling module wrapper.
        # shellcheck disable=SC2034
        MODULE_CHANGED=true

        declare -F verification_operation_hook >/dev/null && verification_operation_hook homebrew-packages "$package" install success
        is_brew_package_installed "$package"
        inspection_result=$?
        declare -F verification_post_hook >/dev/null && verification_post_hook "$inspection_result"
        if [[ $inspection_result -ne 0 ]]; then
            error "Failed to verify Homebrew formula: $package"
            return 2
        fi

        success "$package installed successfully"

    done <<< "$packages"

    if [[ $missing_packages -eq 0 ]]; then

        success "All Homebrew packages are installed."
        return 0

    fi


    echo
    success "Homebrew Packages are ready"

}

# Read-only Global Verification: presence only, never install/version/health.
verify_brew_packages() {
    verification_items_selected homebrew-packages || return 0
    local packages package result
    packages="$(read_brew_packages_configuration "$(blueprint_generated_file homebrew-packages)")" || {
        verification_input_error homebrew-packages; return 0;
    }
    verification_select_subjects homebrew-packages "$packages" || return 2
    for package in "${GV_SUBJECTS[@]}"; do
        is_brew_package_installed "$package"
        result=$?
        verification_result homebrew-packages "$package" installed "$result" '' absent
    done
}
