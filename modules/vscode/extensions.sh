#!/bin/bash

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

check_vscode_cli() {

    if command -v code >/dev/null 2>&1; then
        return 0
    fi

    warning "The 'code' command is not available"
    return 1

}

# ==========================================
# Install VS Code Extension
# ==========================================

# Presence: 0 installed, 1 absent, 2 observation error.
is_vscode_extension_installed() {

    local inventory
    inventory="$(code --list-extensions)" || return 2
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

    while IFS= read -r extension || [[ -n "$extension" ]]; do
        [[ -z "$extension" ]] && continue
        [[ "$extension" =~ ^# ]] && continue
        blueprint_item_selected vscode-extensions "$extension" || continue

        is_vscode_extension_installed "$extension"
        inspection_result=$?

        case $inspection_result in
            0) detail "$extension is already installed" ;;
            1) preview_action "Would install VS Code extension: $extension" ;;
            *)
                error "Failed to inspect VS Code extension: $extension"
                return 2
                ;;
        esac
    done <<< "$extensions"

    return 0

}

install_vscode_extension() {

    local extension="$1"

    action "Installing $extension..."

    if [[ "$VERBOSE" == true ]]; then

    code --install-extension "$extension"

else

    code --install-extension "$extension" >/dev/null 2>&1

fi

if [[ $? -eq 0 ]]; then

    return 0

fi

error "Failed to install $extension"
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

    check_vscode_cli || return 1

    local missing_extensions=0
    local inspection_result

    while IFS= read -r extension || [[ -n "$extension" ]]; do

        [[ -z "$extension" ]] && continue
        [[ "$extension" =~ ^# ]] && continue
        blueprint_item_selected vscode-extensions "$extension" || continue

        is_vscode_extension_installed "$extension"
        inspection_result=$?

        if [[ $inspection_result -eq 0 ]]; then

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

        install_vscode_extension "$extension"

        if [[ $? -ne 0 ]]; then
            return 2
        fi

        # Shared lifecycle flag is read by the calling module wrapper.
        # shellcheck disable=SC2034
        MODULE_CHANGED=true

        if ! is_vscode_extension_installed "$extension"; then
            error "Failed to verify VS Code extension: $extension"
            return 2
        fi

        success "$extension installed successfully"

    done <<< "$extensions"

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
    for item in "${GV_SUBJECTS[@]}"; do
        if ! command -v code >/dev/null 2>&1; then
            verification_record vscode-extensions "$item" installed unverified supported "" || return 2
            verification_diagnostic "$GV_LAST_REF" dependency_unavailable warning observation
            continue
        fi
        is_vscode_extension_installed "$item"
        result=$?
        verification_result vscode-extensions "$item" installed "$result" || return 2
    done
}
