# shellcheck shell=bash
# ==========================================
# Window Management Discovery
# ==========================================

serialize_windows_settings() {
    local output_file="$1"

    : > "$output_file" || return 2

    macos_collect_preference "$output_file" NSGlobalDomain AppleActionOnDoubleClick string || return 2
    macos_collect_preference "$output_file" NSGlobalDomain AppleWindowTabbingMode string || return 2
    macos_collect_preference "$output_file" NSGlobalDomain NSCloseAlwaysConfirmsChanges bool || return 2
    macos_collect_preference "$output_file" NSGlobalDomain NSQuitAlwaysKeepsWindows bool || return 2
    macos_collect_preference "$output_file" com.apple.WindowManager HideDesktop bool || return 2

    return 0
}

export_windows_settings() {
    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/macos/windows.conf"
    WINDOWS_DISCOVERY_WARNING=false

    action "Exporting Window Management configuration..."

    if ! discovery_publish_file "$output_file" macos_serialize_candidate windows serialize_windows_settings; then
        error "Failed to export Window Management configuration"
        return 2
    fi

    if [[ "$VERBOSE" == true ]]; then
        detail "Configuration saved to: $output_file"
    fi
    [[ "$WINDOWS_DISCOVERY_WARNING" == false ]] || return 1
    success "Window Management configuration exported"

    return 0
}
