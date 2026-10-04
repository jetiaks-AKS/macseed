#!/bin/bash

MACOS_FINDER_WINDOW_TARGET_PATTERN='^(PfCm|PfVo|PfHm|PfDe|PfDo|PfAF)$'
MACOS_DOCK_ORIENTATION_PATTERN='^(left|bottom|right)$'
MACOS_DOCK_MINEFFECT_PATTERN='^(genie|scale)$'
MACOS_WINDOW_DOUBLE_CLICK_PATTERN='^(Minimize|Maximize|Fill|None)$'
MACOS_WINDOW_TABBING_PATTERN='^(manual|always|fullscreen)$'

# Support identity, native type and presentation label share one definition.
macos_setting_definitions() {
    cat <<'MACOS_SETTINGS'
finder|NSGlobalDomain|AppleShowAllExtensions|bool|Show extensions
finder|com.apple.finder|ShowPathbar|bool|Show path bar
finder|com.apple.finder|ShowStatusBar|bool|Show status bar
finder|com.apple.finder|FXPreferredViewStyle|string|Default view
finder|com.apple.finder|FXDefaultSearchScope|string|Search scope
finder|com.apple.finder|_FXSortFoldersFirst|bool|Folders first
finder|com.apple.finder|FXRemoveOldTrashItems|bool|Remove old Trash items
finder|com.apple.finder|AppleShowAllFiles|bool|Show hidden files
finder|com.apple.finder|NewWindowTarget|string|New window location
finder|com.apple.finder|ShowHardDrivesOnDesktop|bool|Desktop hard drives
finder|com.apple.finder|ShowExternalHardDrivesOnDesktop|bool|Desktop external drives
finder|com.apple.finder|ShowMountedServersOnDesktop|bool|Desktop servers
finder|com.apple.finder|FXEnableExtensionChangeWarning|bool|Extension change warning
dock|com.apple.dock|autohide|bool|Auto-hide
dock|com.apple.dock|show-recents|bool|Recent applications
dock|com.apple.dock|tilesize|number|Icon size
dock|com.apple.dock|magnification|bool|Magnification
dock|com.apple.dock|largesize|number|Magnified icon size
dock|com.apple.dock|orientation|string|Position
dock|com.apple.dock|mineffect|string|Minimize effect
dock|com.apple.dock|minimize-to-application|bool|Minimize into application
dock|com.apple.dock|show-process-indicators|bool|Running indicators
dock|com.apple.dock|launchanim|bool|Launch animation
dock|com.apple.dock|mru-spaces|bool|Reorder Spaces
windows|NSGlobalDomain|AppleActionOnDoubleClick|string|Title bar double-click
windows|NSGlobalDomain|AppleWindowTabbingMode|string|Window tabbing
windows|NSGlobalDomain|NSCloseAlwaysConfirmsChanges|bool|Confirm unsaved changes
windows|NSGlobalDomain|NSQuitAlwaysKeepsWindows|bool|Restore windows on launch
windows|com.apple.WindowManager|HideDesktop|bool|Hide Desktop items
keyboard|NSGlobalDomain|KeyRepeat|int|Key repeat
keyboard|NSGlobalDomain|InitialKeyRepeat|int|Repeat delay
keyboard|NSGlobalDomain|ApplePressAndHoldEnabled|bool|Press and hold
keyboard|NSGlobalDomain|AppleKeyboardUIMode|int|Keyboard navigation
keyboard|NSGlobalDomain|NSAutomaticCapitalizationEnabled|bool|Automatic capitalization
keyboard|NSGlobalDomain|NSAutomaticSpellingCorrectionEnabled|bool|Spelling correction
keyboard|NSGlobalDomain|NSAutomaticPeriodSubstitutionEnabled|bool|Period substitution
keyboard|NSGlobalDomain|NSAutomaticQuoteSubstitutionEnabled|bool|Smart quotes
keyboard|NSGlobalDomain|NSAutomaticDashSubstitutionEnabled|bool|Smart dashes
trackpad|com.apple.AppleMultitouchTrackpad|Clicking|bool|Tap to click
trackpad|com.apple.AppleMultitouchTrackpad|TrackpadRightClick|bool|Secondary click
screenshots|com.apple.screencapture|location|string|Save location
MACOS_SETTINGS
}

# Shared scalar contract for macOS Discovery and consumers. No generated code.
macos_record_bytes_valid() {
    local bytes
    # Check before shell/awk string parsing: macOS awk can silently lose NUL.
    bytes="$(LC_ALL=C od -An -v -tu1 "$1")" || return 2
    LC_ALL=C awk '{ for (i=1; i<=NF; i++)
        if (($i < 32 && $i != 10) || $i == 127) exit 2
    }' <<< "$bytes"
}

validate_defaults_config() {
    local config_file="$1"
    local category="${2:-}"

    if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
        error "Configuration file not found or unreadable: $config_file"
        return 2
    fi

    if ! macos_record_bytes_valid "$config_file" || ! MACSEED_MACOS_SETTING_DEFINITIONS="$(macos_setting_definitions)" LC_ALL=C awk -F '|' -v category="$category" \
        -v finder_target_pattern="$MACOS_FINDER_WINDOW_TARGET_PATTERN" \
        -v dock_orientation_pattern="$MACOS_DOCK_ORIENTATION_PATTERN" \
        -v dock_mineffect_pattern="$MACOS_DOCK_MINEFFECT_PATTERN" \
        -v window_double_click_pattern="$MACOS_WINDOW_DOUBLE_CLICK_PATTERN" \
        -v window_tabbing_pattern="$MACOS_WINDOW_TABBING_PATTERN" '
        BEGIN {
            count = split(ENVIRON["MACSEED_MACOS_SETTING_DEFINITIONS"], lines, "\n")
            for (i = 1; i <= count; i++) {
                split(lines[i], fields, "|")
                allowed[fields[1], fields[2], fields[3]] = fields[4]
            }
            if (category !~ /^(finder|dock|windows|keyboard|trackpad|screenshots)$/) exit 2
        }
        /^ *$/ { next }
        NF != 4 || $1 == "" || $2 == "" { exit 2 }
        { if (seen[$1, $2]++) exit 2 }
        allowed[category, $1, $2] != $3 &&
            !(allowed[category, $1, $2] == "number" && ($3 == "int" || $3 == "float")) { exit 2 }
        category == "finder" && $2 == "NewWindowTarget" && $4 !~ finder_target_pattern { exit 2 }
        category == "dock" && $2 == "orientation" && $4 !~ dock_orientation_pattern { exit 2 }
        category == "dock" && $2 == "mineffect" && $4 !~ dock_mineffect_pattern { exit 2 }
        category == "windows" && $2 == "AppleActionOnDoubleClick" && $4 !~ window_double_click_pattern { exit 2 }
        category == "windows" && $2 == "AppleWindowTabbingMode" && $4 !~ window_tabbing_pattern { exit 2 }
        category == "screenshots" {
            # Only absolute paths or leading ~/; no shell syntax or traversal.
            if ($4 !~ /^(\/|~\/)/ || $4 ~ /[$`\\]/ || $4 ~ /\/\// ||
                $4 ~ /(^|\/)\.\.?($|\/)/) exit 2
        }
        $3 == "bool" {
            if ($4 !~ /^(0|1|true|false)$/) exit 2
            next
        }
        $3 == "int" { if ($4 !~ /^-?[0-9]+$/) exit 2; next }
        $3 == "float" { if ($4 !~ /^-?[0-9]+(\.[0-9]+)?$/) exit 2; next }
        $3 == "string" { next }
        { exit 2 }
    ' "$config_file"; then
        error "Invalid macOS configuration${category:+ ($category)}: $config_file"
        return 2
    fi
    return 0
}

# Preserve raw bytes until validated; remove only the command output newline.
macos_read_scalar() {
    local value_file
    MACOS_DEFAULTS_VALUE=""
    value_file="$(mktemp)" || return 2
    if ! defaults read "$1" "$2" > "$value_file" 2>/dev/null ||
       ! macos_record_bytes_valid "$value_file" ||
       ! LC_ALL=C awk 'NR > 1 || /\|/ { exit 2 }' "$value_file"; then
        rm -f "$value_file"
        return 2
    fi
    # Shared state is read by another sourced module.
    # shellcheck disable=SC2034
    IFS= read -r MACOS_DEFAULTS_VALUE < "$value_file" || :
    rm -f "$value_file" || return 2
    return 0
}

# Project only effective validated records. Values never leave this helper.
macos_included_settings() {
    validate_defaults_config "$1" "$2" >/dev/null || return 2
    MACSEED_MACOS_SETTING_DEFINITIONS="$(macos_setting_definitions)" LC_ALL=C awk -F '|' -v category="$2" '
        BEGIN {
            count = split(ENVIRON["MACSEED_MACOS_SETTING_DEFINITIONS"], lines, "\n")
            for (i = 1; i <= count; i++) {
                split(lines[i], fields, "|")
                labels[fields[1], fields[2], fields[3]] = fields[5]
            }
        }
        NF == 4 { printf "%s\t%s\n", $2, labels[category, $1, $2] }
    ' "$1"
}
