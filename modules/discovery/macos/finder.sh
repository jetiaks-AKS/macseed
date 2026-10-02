# shellcheck shell=bash
# ==========================================
# Finder Discovery
# ==========================================

serialize_finder_settings() {

    local output_file="$1"

    : > "$output_file" || return 2

    macos_collect_preference "$output_file" NSGlobalDomain AppleShowAllExtensions bool || return 2
    macos_collect_preference "$output_file" com.apple.finder ShowPathbar bool || return 2
    macos_collect_preference "$output_file" com.apple.finder ShowStatusBar bool || return 2
    macos_collect_preference "$output_file" com.apple.finder FXPreferredViewStyle string || return 2
    macos_collect_preference "$output_file" com.apple.finder FXDefaultSearchScope string || return 2
    macos_collect_preference "$output_file" com.apple.finder _FXSortFoldersFirst bool || return 2
    macos_collect_preference "$output_file" com.apple.finder FXRemoveOldTrashItems bool || return 2
    macos_collect_preference "$output_file" com.apple.finder AppleShowAllFiles bool || return 2
    macos_collect_preference "$output_file" com.apple.finder NewWindowTarget string || return 2
    macos_collect_preference "$output_file" com.apple.finder ShowHardDrivesOnDesktop bool || return 2
    macos_collect_preference "$output_file" com.apple.finder ShowExternalHardDrivesOnDesktop bool || return 2
    macos_collect_preference "$output_file" com.apple.finder ShowMountedServersOnDesktop bool || return 2
    macos_collect_preference "$output_file" com.apple.finder FXEnableExtensionChangeWarning bool || return 2

    return 0

}

export_finder_settings() {

    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/macos/finder.conf"
    FINDER_DISCOVERY_WARNING=false

    action "Exporting Finder configuration..."

    if ! discovery_publish_file "$output_file" macos_serialize_candidate finder serialize_finder_settings; then
        error "Failed to export Finder configuration"
        return 2
    fi

if [[ "$VERBOSE" == true ]]; then
    detail "Configuration saved to: $output_file"
fi
    [[ "$FINDER_DISCOVERY_WARNING" == false ]] || return 1
    success "Finder configuration exported"

    return 0

}
