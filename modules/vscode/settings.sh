#!/bin/bash

VSCODE_SETTINGS_FIRST_MISSING_DIR=""
VSCODE_SETTINGS_INSPECTION_ERROR=""

# Comparison: 0 equal, 1 absent/different, 2 observation error.
inspect_vscode_settings() {

    local source_file="$1"
    local target_file="$2"
    local result

    [[ -f "$source_file" && -r "$source_file" ]] || return 2
    if [[ ! -e "$target_file" && ! -L "$target_file" ]]; then
        return 1
    fi
    [[ -f "$target_file" && -r "$target_file" ]] || return 2
    cmp -s "$source_file" "$target_file"
    result=$?
    [[ $result -le 1 ]] || return 2
    return "$result"

}

# Inspect the destination path and settings contents without mutation.
inspect_vscode_settings_target() {

    local source_file="$1"
    local target_dir="$2"
    local target_file="$3"
    local parent_dir="$target_dir"

    VSCODE_SETTINGS_FIRST_MISSING_DIR=""
    VSCODE_SETTINGS_INSPECTION_ERROR=""

    while [[ ! -e "$parent_dir" && ! -L "$parent_dir" ]]; do
        VSCODE_SETTINGS_FIRST_MISSING_DIR="$parent_dir"
        parent_dir="$(dirname "$parent_dir")"
    done

    if [[ ! -d "$parent_dir" || ! -x "$parent_dir" ]]; then
        VSCODE_SETTINGS_INSPECTION_ERROR=directory
        return 2
    fi

    inspect_vscode_settings "$source_file" "$target_file"
    local result=$?
    [[ $result -ne 2 ]] || VSCODE_SETTINGS_INSPECTION_ERROR=settings
    return "$result"
}

# Publish a complete copy; failed staging leaves the destination unchanged.
copy_vscode_settings() {

    local source_file="$1"
    local target_file="$2"
    local temporary_file

    temporary_file="$(mktemp "${target_file}.tmp.XXXXXX")" || return 2
    if ! cp -p "$source_file" "$temporary_file" ||
       ! mv -f "$temporary_file" "$target_file"; then
        rm -f "$temporary_file"
        return 2
    fi
    MODULE_CHANGED=true
    return 0

}

# ==========================================
# Apply VS Code Settings
# ==========================================

validate_vscode_settings_source() {

    local source_file="$1"

    if [[ ! -e "$source_file" && ! -L "$source_file" ]]; then
        return 1
    fi

    # Settings are copied verbatim, including comments; validate file access.
    if [[ ! -f "$source_file" || ! -r "$source_file" ]] ||
       ! cat "$source_file" >/dev/null; then
        error "VS Code settings source is not a readable regular file"
        return 2
    fi

    return 0

}

apply_vscode_settings() {

    local source_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/vscode/settings.json"
    local target_dir="$HOME/Library/Application Support/Code/User"
    local target_file="$target_dir/settings.json"
    local inspection_result
    local first_missing_dir=""

    validate_vscode_settings_source "$source_file"
    local source_result=$?

    if [[ $source_result -eq 1 ]]; then
        warning "Configuration file $source_file not found"
        return 1
    fi

    if [[ $source_result -ne 0 ]]; then
        return 2
    fi

    inspect_vscode_settings_target "$source_file" "$target_dir" "$target_file"
    inspection_result=$?
    first_missing_dir="$VSCODE_SETTINGS_FIRST_MISSING_DIR"
    if [[ $inspection_result -eq 0 ]]; then
        success "VS Code Settings already configured"
        return 0
    fi
    if [[ $inspection_result -ne 1 ]]; then
        if [[ "$VSCODE_SETTINGS_INSPECTION_ERROR" == directory ]]; then
            error "Failed to inspect VS Code settings directory"
        else
            error "Failed to inspect VS Code Settings"
        fi
        return 2
    fi

    # Atomic publication must not replace links or directories with regular files.
    if [[ -L "$target_file" || -L "$target_file.bootstrap.bak" ||
          ( -e "$target_file.bootstrap.bak" && ! -f "$target_file.bootstrap.bak" ) ]]; then
        error "Unsupported VS Code settings destination or backup type"
        return 2
    fi

    if [[ ! -d "$target_dir" ]]; then
        if ! mkdir -p "$target_dir"; then
            # mkdir -p can create an ancestor before failing on a later component.
            [[ -z "$first_missing_dir" || ! -d "$first_missing_dir" ]] || MODULE_CHANGED=true
            error "Failed to create VS Code settings directory"
            return 2
        fi
        # Shared lifecycle flag is read by the calling module wrapper.
        # shellcheck disable=SC2034
        MODULE_CHANGED=true
    fi

    if [[ -f "$target_file" ]]; then
        action "Creating backup of current VS Code Settings..."
        if ! copy_vscode_settings "$target_file" "$target_file.bootstrap.bak"; then
            error "Failed to back up current VS Code Settings"
            return 2
        fi
    fi

    if ! copy_vscode_settings "$source_file" "$target_file"; then
        error "Failed to apply VS Code Settings"
        return 2
    fi

    if ! inspect_vscode_settings "$source_file" "$target_file"; then
        error "Failed to verify VS Code Settings"
        return 2
    fi

    success "VS Code Settings applied successfully"
    return 0

}

# ==========================================
# Preview VS Code Settings
# ==========================================

preview_vscode_settings() {

    local source_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/vscode/settings.json"
    local target_dir="$HOME/Library/Application Support/Code/User"
    local target_file="$target_dir/settings.json"
    local source_result
    local inspection_result

    validate_vscode_settings_source "$source_file"
    source_result=$?

    if [[ $source_result -eq 1 ]]; then
        warning "Configuration file $source_file not found"
        return 1
    fi

    [[ $source_result -eq 0 ]] || return 2

    inspect_vscode_settings_target "$source_file" "$target_dir" "$target_file"
    inspection_result=$?

    case $inspection_result in
        0)
            return 0
            ;;
        1)
            preview_action "Would update VS Code settings"
            return 0
            ;;
        *)
            error "Failed to inspect VS Code Settings"
            return 2
            ;;
    esac
}

# Opaque supported payload equality; no assertion about editor runtime state.
verify_vscode_settings() {
    verification_category_selected vscode-settings || return 0
    local source_file="$BLUEPRINT_GENERATED_DIR/vscode/settings.json"
    local target_dir="$HOME/Library/Application Support/Code/User" result
    validate_vscode_settings_source "$source_file"
    result=$?
    case "$result" in
        1)
            verification_coverage vscode-settings scope unresolved unknown
            verification_diagnostic "$GV_LAST_REF" selected_input_unresolved warning scope
            return 0 ;;
        0) ;;
        *) verification_input_error vscode-settings; return 0 ;;
    esac
    verification_coverage vscode-settings settings.json resolved unknown
    inspect_vscode_settings_target "$source_file" "$target_dir" "$target_dir/settings.json"
    result=$?
    verification_result vscode-settings settings.json file_content "$result"
}
