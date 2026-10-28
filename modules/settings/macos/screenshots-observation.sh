#!/bin/bash

# Domain-owned observation shared by Discovery, Preview, Apply and Verification.
# Bundle's location record describes a destination, not a target OS key choice.
# Choose by target OS, never by Bundle origin or the presence of stale keys.
# Bundle v1 keeps the logical location identity for every native backend.
# Observation outputs are consumed by the sourced Discovery/Settings modules.
# shellcheck disable=SC2034
screenshots_location_backend() {
    local version
    SCREENSHOTS_LOCATION_REASON=observation_failed
    SCREENSHOTS_LOCATION_KEY=''
    SCREENSHOTS_TARGET_KEY=''
    version="$(application_observe local sw_vers -productVersion)" || return 2
    [[ "$version" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 2
    case "$version" in
        10.14|10.14.*|10.15|10.15.*|11|11.*|12|12.*|13|13.*|14|14.*|15|15.*|26|26.*)
            SCREENSHOTS_LOCATION_KEY=location
            SCREENSHOTS_TARGET_KEY=target ;;
        27|27.*)
            SCREENSHOTS_LOCATION_KEY=location-screenshot
            SCREENSHOTS_TARGET_KEY=target-screenshot ;;
        *) SCREENSHOTS_LOCATION_REASON=screenshots_location_unsupported
           error "Screenshots location is not qualified on this macOS version"; return 2 ;;
    esac
}

# 0: typed string; 1: confirmed absence; 2: unknown/error. Never use a failed
# value read as evidence for the Desktop default.
screenshots_read_optional_string() {
    local key="$1" native_type result
    MACOS_DEFAULTS_VALUE=''
    native_type="$(LC_ALL=C application_observe local-diagnostic defaults read-type com.apple.screencapture "$key" 2>&1)"
    result=$?
    if [[ $result -ne 0 ]]; then
        if macos_defaults_key_absent "$result" "$native_type" com.apple.screencapture "$key"; then
            return 1
        fi
        error "Failed to inspect Screenshots preference: $key"
        return 2
    fi
    if [[ "$native_type" != 'Type is string' ]] || ! macos_read_scalar com.apple.screencapture "$key"; then
        error "Failed to read Screenshots string preference: $key"
        return 2
    fi
}

screenshots_observe_location() {
    local key result value
    SCREENSHOTS_LOCATION_ORIGIN=unknown
    SCREENSHOTS_LOCATION_VALUE=''
    screenshots_location_backend || return 2
    if [[ "$SCREENSHOTS_LOCATION_KEY" == location ]]; then
        # Preserve the established legacy conflict policy. Split-generation keys
        # on an older OS are not evidence that its backend has changed.
        for key in location-screenshot target-screenshot; do
            screenshots_read_optional_string "$key"
            result=$?
            if [[ $result -ne 1 ]]; then
                error "Screenshots contains an unqualified location/target mechanism"
                return 2
            fi
        done
    fi
    # On 27, legacy and screen-recording keys are unrelated to this observation.
    screenshots_read_optional_string "$SCREENSHOTS_TARGET_KEY"
    result=$?
    [[ $result -ne 2 ]] || return 2
    if [[ $result -eq 0 && "$MACOS_DEFAULTS_VALUE" != file ]]; then
        SCREENSHOTS_LOCATION_REASON=screenshots_non_file_target
        error "Screenshots destination is not a supported file target"
        return 2
    fi
    screenshots_read_optional_string "$SCREENSHOTS_LOCATION_KEY"
    result=$?
    [[ $result -ne 2 ]] || return 2
    if [[ $result -eq 1 ]]; then
        SCREENSHOTS_LOCATION_ORIGIN=default_desktop
        value="$HOME/Desktop"
    else
        value="$MACOS_DEFAULTS_VALUE"
        # Only the documented leading tilde; never shell-expand preferences.
        # shellcheck disable=SC2088
        case "$value" in '~/'*) value="$HOME/${value#\~/}" ;; esac
        while [[ "$value" != / && "$value" == */ ]]; do value="${value%/}"; done
        case "$value" in
            "$HOME/Desktop") SCREENSHOTS_LOCATION_ORIGIN=explicit_desktop ;;
            "$HOME"/*) SCREENSHOTS_LOCATION_ORIGIN=home ;;
            /*) SCREENSHOTS_LOCATION_ORIGIN=external ;;
            *) error "Invalid Screenshots location"; return 2 ;;
        esac
    fi
    SCREENSHOTS_LOCATION_VALUE="$value"
    return 0
}

# Preserve the existing Verification protocol identity and observation kinds.
# This checks the effective file destination, including the qualified default;
# it does not assert that a real screenshot was rendered or saved.
screenshots_check_location() {
    DEFAULTS_OBSERVED_PRESENT=false
    DEFAULTS_OBSERVED_VALUE=''
    DEFAULTS_OBSERVATION_KIND=unknown
    screenshots_observe_location || return 2
    DEFAULTS_OBSERVED_PRESENT=true
    DEFAULTS_OBSERVED_VALUE="$SCREENSHOTS_LOCATION_VALUE"
    if [[ "$SCREENSHOTS_LOCATION_VALUE" == "$SCREENSHOTS_DESTINATION" ]]; then
        DEFAULTS_OBSERVATION_KIND=matching
        return 0
    fi
    DEFAULTS_OBSERVATION_KIND=different
    return 1
}
