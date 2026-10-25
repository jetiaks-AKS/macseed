#!/bin/bash

# ==========================================
# Screenshots Discovery
# ==========================================

source modules/settings/macos/screenshots-observation.sh

serialize_screenshots_settings() {

    local output_file="$1"
    local location

    : > "$output_file" || return 2

    screenshots_observe_location || return 2
    location="$SCREENSHOTS_LOCATION_VALUE"
    # Keep the existing behavior record portable even before Bundle packaging.
    # shellcheck disable=SC2088
    case "$location" in "$HOME"/*) location="~/${location#"$HOME"/}" ;; esac
    printf 'com.apple.screencapture|location|string|%s\n' "$location" >> "$output_file" || return 2
    detail "Screenshots location source: $SCREENSHOTS_LOCATION_ORIGIN"
    macos_collect_preference "$output_file" com.apple.screencapture disable-shadow bool || return 2
    macos_collect_preference "$output_file" com.apple.screencapture show-thumbnail bool || return 2

    return 0

}

export_screenshots_settings() {

    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/macos/screenshots.conf"

    action "Exporting Screenshots configuration..."

    if ! discovery_publish_file "$output_file" macos_serialize_candidate screenshots serialize_screenshots_settings; then
        error "Failed to export Screenshots configuration"
        return 2
    fi

if [[ "$VERBOSE" == true ]]; then
    detail "Configuration saved to: $output_file"
fi
    success "Screenshots configuration exported"

    return 0

}
