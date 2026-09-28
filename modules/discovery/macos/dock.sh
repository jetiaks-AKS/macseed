# shellcheck shell=bash
# ==========================================
# Dock Discovery
# ==========================================

serialize_dock_settings() {

    local output_file="$1"

    : > "$output_file" || return 2

    macos_collect_preference "$output_file" com.apple.dock autohide bool || return 2
    macos_collect_preference "$output_file" com.apple.dock show-recents bool || return 2
    macos_collect_preference "$output_file" com.apple.dock tilesize number || return 2
    macos_collect_preference "$output_file" com.apple.dock magnification bool || return 2
    macos_collect_preference "$output_file" com.apple.dock largesize number || return 2
    macos_collect_preference "$output_file" com.apple.dock orientation string || return 2
    macos_collect_preference "$output_file" com.apple.dock mineffect string || return 2
    macos_collect_preference "$output_file" com.apple.dock minimize-to-application bool || return 2
    macos_collect_preference "$output_file" com.apple.dock show-process-indicators bool || return 2
    macos_collect_preference "$output_file" com.apple.dock launchanim bool || return 2
    macos_collect_preference "$output_file" com.apple.dock mru-spaces bool || return 2

    return 0

}

export_dock_settings() {

    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/macos/dock.conf"
    DOCK_DISCOVERY_WARNING=false

    action "Exporting Dock configuration..."

    if ! discovery_publish_file "$output_file" macos_serialize_candidate dock serialize_dock_settings; then
        error "Failed to export Dock configuration"
        return 2
    fi

if [[ "$VERBOSE" == true ]]; then
    detail "Configuration saved to: $output_file"
fi
    [[ "$DOCK_DISCOVERY_WARNING" == false ]] || return 1
    success "Dock configuration exported"

    return 0

}
