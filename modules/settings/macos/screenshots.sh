#!/bin/bash

# ==========================================
# Screenshots Settings
# ==========================================

SCREENSHOTS_CONFIG="${BLUEPRINT_GENERATED_DIR:-config/generated}/macos/screenshots.conf"
SCREENSHOTS_DESTINATION=""
SCREENSHOTS_FIRST_MISSING=""
SCREENSHOTS_DIRECTORY_MISSING=false
SCREENSHOTS_PREFERENCE_CHANGED=false

screenshots_load_destination() {
    local domain key type value
    SCREENSHOTS_DESTINATION=""
    validate_defaults_config "$SCREENSHOTS_CONFIG" screenshots || return 2
    while IFS='|' read -r domain key type value || [[ -n "$domain$key$type$value" ]]; do
        [[ -n "${domain// /}" ]] || continue
        # The literal tilde is config input expanded by the consumer.
        # shellcheck disable=SC2088
        case "$value" in
            '~/'*) value="$HOME/${value#\~/}" ;;
        esac
        while [[ "$value" != / && "$value" == */ ]]; do value="${value%/}"; done
        SCREENSHOTS_DESTINATION="$value"
    done < "$SCREENSHOTS_CONFIG"
    return 0
}

# 0: usable; 1: safely creatable inside HOME; 2: unsafe/observation error.
screenshots_directory_state() {
    local target="$SCREENSHOTS_DESTINATION"
    local root current=/ remaining component physical metadata inside=false
    SCREENSHOTS_FIRST_MISSING=""
    [[ -n "$target" ]] || return 0
    root="$(cd "$HOME" && pwd -P)" || return 2
    case "$target" in "$HOME"|"$HOME"/*) inside=true ;; esac
    remaining="${target#/}"
    while [[ -n "$remaining" ]]; do
        component="${remaining%%/*}"
        current="${current%/}/$component"
        metadata="$(LC_ALL=C stat -f '%HT' "$current" 2>&1)"
        if [[ $? -ne 0 ]]; then
            # A checked searchable parent plus ENOENT is confirmed absence.
            if [[ "$metadata" == *'No such file or directory'* &&
                  "$inside" == true && "$current" == "$HOME"/* &&
                  -d "${current%/*}" && -x "${current%/*}" && -w "${current%/*}" ]]; then
                SCREENSHOTS_FIRST_MISSING="$current"
                return 1
            fi
            error "Failed to inspect screenshots destination: $current"
            return 2
        fi
        if [[ ! -d "$current" || ! -x "$current" ]]; then
            error "Screenshots destination component is not an accessible directory: $current"
            return 2
        fi
        physical="$(cd "$current" && pwd -P)" || return 2
        if [[ "$inside" == true && ( "$current" == "$HOME" || "$current" == "$HOME"/* ) &&
              "$physical" != "$root" && "$physical" != "$root"/* ]]; then
            error "Screenshots destination symlink escapes HOME: $current"
            return 2
        fi
        [[ "$remaining" == */* ]] || break
        remaining="${remaining#*/}"
    done
    if [[ ! -d "$target" || ! -x "$target" || ! -w "$target" ]]; then
        error "Screenshots destination is not writable and accessible: $target"
        return 2
    fi
    return 0
}

# Startup validates the path before any Bootstrap mutation, without reading prefs.
validate_screenshots_config() {
    local result
    screenshots_load_destination || return 2
    screenshots_directory_state
    result=$?
    if [[ $result -eq 2 ]]; then return 2; fi
    return 0
}

inspect_screenshots_settings() {
    local result
    SCREENSHOTS_DIRECTORY_MISSING=false
    SCREENSHOTS_PREFERENCE_CHANGED=false
    screenshots_load_destination || return 2
    [[ -n "$SCREENSHOTS_DESTINATION" ]] || return 0
    screenshots_directory_state
    result=$?
    case $result in
        0) ;;
        1) SCREENSHOTS_DIRECTORY_MISSING=true ;;
        *) return 2 ;;
    esac
    check_defaults_record com.apple.screencapture location string "$SCREENSHOTS_DESTINATION"
    result=$?
    case $result in
        0) ;;
        1) SCREENSHOTS_PREFERENCE_CHANGED=true ;;
        *) return 2 ;;
    esac
    return 0
}

check_screenshots() {
    inspect_screenshots_settings || return 2
    [[ "$SCREENSHOTS_DIRECTORY_MISSING" == false && "$SCREENSHOTS_PREFERENCE_CHANGED" == false ]]
}

preview_screenshots_settings() {
    inspect_screenshots_settings || return 2
    if [[ "$SCREENSHOTS_DIRECTORY_MISSING" != true && "$SCREENSHOTS_PREFERENCE_CHANGED" != true ]]; then
        preview_record macos-screenshots com.apple.screencapture/location none satisfied
    fi
    if [[ "$SCREENSHOTS_DIRECTORY_MISSING" == true ]]; then
        preview_record macos-screenshots destination create_directory planned
        preview_action "Would create screenshots directory: $SCREENSHOTS_DESTINATION"
    fi
    if [[ "$SCREENSHOTS_PREFERENCE_CHANGED" == true ]]; then
        preview_record macos-screenshots com.apple.screencapture/location set_preference planned
        preview_record macos-screenshots SystemUIServer restart_process planned
        local current=absent
        [[ "$DEFAULTS_OBSERVED_PRESENT" != true ]] || current="$DEFAULTS_OBSERVED_VALUE"
        preview_action "Would change macOS setting: com.apple.screencapture/location ($current -> $SCREENSHOTS_DESTINATION)"
        preview_action "Would restart process: SystemUIServer"
    fi
    return 0
}

apply_screenshots_settings() {
    local first_missing
    inspect_screenshots_settings || return 2
    [[ -n "$SCREENSHOTS_DESTINATION" ]] || return 0
    if [[ "$SCREENSHOTS_DIRECTORY_MISSING" == true ]]; then
        first_missing="$SCREENSHOTS_FIRST_MISSING"
        if ! mkdir -p "$SCREENSHOTS_DESTINATION"; then
            [[ ! -d "$first_missing" ]] || MODULE_CHANGED=true
            error "Failed to create screenshots destination: $SCREENSHOTS_DESTINATION"
            return 2
        fi
        # Shared lifecycle flag is read by the calling module wrapper.
        # shellcheck disable=SC2034
        MODULE_CHANGED=true
        if ! screenshots_directory_state; then
            error "Failed to verify screenshots destination: $SCREENSHOTS_DESTINATION"
            return 2
        fi
    fi
    if [[ "$SCREENSHOTS_PREFERENCE_CHANGED" == true ]]; then
        apply_defaults_record com.apple.screencapture location string "$SCREENSHOTS_DESTINATION" || return 2
        if [[ "$DEFAULTS_RECORD_CHANGED" == true ]] && ! killall SystemUIServer >/dev/null 2>&1; then
            error "Failed to restart SystemUIServer"
            return 2
        fi
    fi
    if ! check_screenshots; then
        error "Failed to verify Screenshots"
        return 2
    fi
    success "Screenshots configured successfully"
    return 0
}

# Production readers independently establish stored location and usable folder.
# A directory error must not hide an observable preference, or vice versa.
verify_screenshots() {
    verification_category_selected macos-screenshots || return 0
    local result
    if ! screenshots_load_destination; then verification_input_error macos-screenshots; return 0; fi
    if [[ -z "$SCREENSHOTS_DESTINATION" ]]; then
        verification_coverage macos-screenshots scope no_requirement unknown
        return 0
    fi
    verification_coverage macos-screenshots com.apple.screencapture/location resolved unknown
    check_defaults_record com.apple.screencapture location string "$SCREENSHOTS_DESTINATION"
    result=$?
    if [[ "${CV_ACTIVE:-false}" == true && $result -eq 2 &&
          "$DEFAULTS_OBSERVATION_KIND" == different ]]; then result=1; fi
    verification_result macos-screenshots com.apple.screencapture/location stored_preference "$result" '' "$DEFAULTS_OBSERVATION_KIND" || return 2
    verification_coverage macos-screenshots destination resolved unknown
    screenshots_directory_state
    result=$?
    local kind=unknown
    [[ $result -ne 1 ]] || kind=absent
    verification_result macos-screenshots destination directory "$result" '' "$kind"
}
