#!/bin/bash

MACOS_FINDER_WINDOW_TARGET_PATTERN='^(PfCm|PfVo|PfHm|PfDe|PfDo|PfAF)$'
MACOS_DOCK_ORIENTATION_PATTERN='^(left|bottom|right)$'
MACOS_DOCK_MINEFFECT_PATTERN='^(genie|scale)$'
MACOS_WINDOW_DOUBLE_CLICK_PATTERN='^(Minimize|Maximize|Fill|None)$'
MACOS_WINDOW_TABBING_PATTERN='^(manual|always|fullscreen)$'

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

    if ! macos_record_bytes_valid "$config_file" || ! LC_ALL=C awk -F '|' -v category="$category" \
        -v finder_target_pattern="$MACOS_FINDER_WINDOW_TARGET_PATTERN" \
        -v dock_orientation_pattern="$MACOS_DOCK_ORIENTATION_PATTERN" \
        -v dock_mineffect_pattern="$MACOS_DOCK_MINEFFECT_PATTERN" \
        -v window_double_click_pattern="$MACOS_WINDOW_DOUBLE_CLICK_PATTERN" \
        -v window_tabbing_pattern="$MACOS_WINDOW_TABBING_PATTERN" '
        BEGIN {
            allowed["finder", "NSGlobalDomain", "AppleShowAllExtensions"] = "bool"
            allowed["finder", "com.apple.finder", "ShowPathbar"] = "bool"
            allowed["finder", "com.apple.finder", "ShowStatusBar"] = "bool"
            allowed["finder", "com.apple.finder", "FXPreferredViewStyle"] = "string"
            allowed["finder", "com.apple.finder", "FXDefaultSearchScope"] = "string"
            allowed["finder", "com.apple.finder", "_FXSortFoldersFirst"] = "bool"
            allowed["finder", "com.apple.finder", "FXRemoveOldTrashItems"] = "bool"
            allowed["finder", "com.apple.finder", "AppleShowAllFiles"] = "bool"
            allowed["finder", "com.apple.finder", "NewWindowTarget"] = "string"
            allowed["finder", "com.apple.finder", "ShowHardDrivesOnDesktop"] = "bool"
            allowed["finder", "com.apple.finder", "ShowExternalHardDrivesOnDesktop"] = "bool"
            allowed["finder", "com.apple.finder", "ShowMountedServersOnDesktop"] = "bool"
            allowed["finder", "com.apple.finder", "FXEnableExtensionChangeWarning"] = "bool"
            allowed["dock", "com.apple.dock", "autohide"] = "bool"
            allowed["dock", "com.apple.dock", "show-recents"] = "bool"
            allowed["dock", "com.apple.dock", "tilesize"] = "number"
            allowed["dock", "com.apple.dock", "magnification"] = "bool"
            allowed["dock", "com.apple.dock", "largesize"] = "number"
            allowed["dock", "com.apple.dock", "orientation"] = "string"
            allowed["dock", "com.apple.dock", "mineffect"] = "string"
            allowed["dock", "com.apple.dock", "minimize-to-application"] = "bool"
            allowed["dock", "com.apple.dock", "show-process-indicators"] = "bool"
            allowed["dock", "com.apple.dock", "launchanim"] = "bool"
            allowed["dock", "com.apple.dock", "mru-spaces"] = "bool"
            allowed["windows", "NSGlobalDomain", "AppleActionOnDoubleClick"] = "string"
            allowed["windows", "NSGlobalDomain", "AppleWindowTabbingMode"] = "string"
            allowed["windows", "NSGlobalDomain", "NSCloseAlwaysConfirmsChanges"] = "bool"
            allowed["windows", "NSGlobalDomain", "NSQuitAlwaysKeepsWindows"] = "bool"
            allowed["windows", "com.apple.WindowManager", "HideDesktop"] = "bool"
            allowed["keyboard", "NSGlobalDomain", "KeyRepeat"] = "int"
            allowed["keyboard", "NSGlobalDomain", "InitialKeyRepeat"] = "int"
            allowed["keyboard", "NSGlobalDomain", "ApplePressAndHoldEnabled"] = "bool"
            allowed["keyboard", "NSGlobalDomain", "AppleKeyboardUIMode"] = "int"
            allowed["keyboard", "NSGlobalDomain", "NSAutomaticCapitalizationEnabled"] = "bool"
            allowed["keyboard", "NSGlobalDomain", "NSAutomaticSpellingCorrectionEnabled"] = "bool"
            allowed["keyboard", "NSGlobalDomain", "NSAutomaticPeriodSubstitutionEnabled"] = "bool"
            allowed["keyboard", "NSGlobalDomain", "NSAutomaticQuoteSubstitutionEnabled"] = "bool"
            allowed["keyboard", "NSGlobalDomain", "NSAutomaticDashSubstitutionEnabled"] = "bool"
            allowed["trackpad", "com.apple.AppleMultitouchTrackpad", "Clicking"] = "bool"
            allowed["trackpad", "com.apple.AppleMultitouchTrackpad", "TrackpadRightClick"] = "bool"
            allowed["screenshots", "com.apple.screencapture", "location"] = "string"
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
