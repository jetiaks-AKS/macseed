#!/bin/bash

# ==========================================
# macOS Discovery Safe Publication Harness
# ==========================================

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

TEST_FAILURES=0
VERBOSE=false
MOCK_MODE=normal
WINDOW_EXPANSION=false
MOCK_TARGET=""
MOCK_VALUE=""
MOCK_MACOS_VERSION=26.7.1
sw_vers() { [[ "$1" == -productVersion ]] && printf '%s\n' "$MOCK_MACOS_VERSION"; }
SUCCESS_MESSAGES=""
WARNING_MESSAGES=""
ERROR_MESSAGES=""

source "$PROJECT_ROOT/modules/core/common/common.sh"
source "$PROJECT_ROOT/modules/discovery/discovery.sh"

log() { :; }
action() { :; }
detail() { :; }
success() {
    SUCCESS_MESSAGES="${SUCCESS_MESSAGES}${SUCCESS_MESSAGES:+
}$1"
}
warning() {
    WARNING_MESSAGES="${WARNING_MESSAGES}${WARNING_MESSAGES:+
}$1"
}
error() {
    ERROR_MESSAGES="${ERROR_MESSAGES}${ERROR_MESSAGES:+
}$1"
}

mock_native_type() {
    case "$1" in
        EnableStandardClickToShowDesktop|EnableTilingByEdgeDrag|EnableTopTilingByEdgeDrag|EnableTiledWindowMargins|ApplePressAndHoldEnabled|NSAutomaticCapitalizationEnabled|NSAutomaticSpellingCorrectionEnabled|NSAutomaticPeriodSubstitutionEnabled|NSAutomaticQuoteSubstitutionEnabled|NSAutomaticDashSubstitutionEnabled|AppleShowAllExtensions|ShowPathbar|ShowStatusBar|_FXSortFoldersFirst|FXRemoveOldTrashItems|AppleShowAllFiles|ShowHardDrivesOnDesktop|ShowExternalHardDrivesOnDesktop|ShowMountedServersOnDesktop|FXEnableExtensionChangeWarning|autohide|show-recents|magnification|minimize-to-application|show-process-indicators|launchanim|mru-spaces|NSCloseAlwaysConfirmsChanges|NSQuitAlwaysKeepsWindows|HideDesktop|Clicking|TrackpadRightClick|disable-shadow|show-thumbnail)
            echo "Type is boolean"
            ;;
        tilesize|largesize|KeyRepeat|InitialKeyRepeat|AppleKeyboardUIMode)
            echo "Type is integer"
            ;;
        FXPreferredViewStyle|FXDefaultSearchScope|NewWindowTarget|orientation|mineffect|AppleActionOnDoubleClick|AppleWindowTabbingMode|location)
            echo "Type is string"
            ;;
        *)
            return 2
            ;;
    esac
}

mock_value() {
    case "$1" in
        EnableStandardClickToShowDesktop|EnableTilingByEdgeDrag|EnableTopTilingByEdgeDrag|EnableTiledWindowMargins|ApplePressAndHoldEnabled|NSAutomaticCapitalizationEnabled|NSAutomaticQuoteSubstitutionEnabled|AppleShowAllExtensions|ShowStatusBar|_FXSortFoldersFirst|AppleShowAllFiles|ShowExternalHardDrivesOnDesktop|FXEnableExtensionChangeWarning|autohide|magnification|minimize-to-application|launchanim|NSCloseAlwaysConfirmsChanges|NSQuitAlwaysKeepsWindows|HideDesktop|Clicking|show-thumbnail)
            echo 1
            ;;
        NSAutomaticSpellingCorrectionEnabled|NSAutomaticPeriodSubstitutionEnabled|NSAutomaticDashSubstitutionEnabled|ShowPathbar|FXRemoveOldTrashItems|ShowHardDrivesOnDesktop|ShowMountedServersOnDesktop|show-recents|show-process-indicators|mru-spaces|TrackpadRightClick|disable-shadow)
            echo 0
            ;;
        tilesize) echo 48 ;;
        largesize) echo 64 ;;
        KeyRepeat) echo 2 ;;
        InitialKeyRepeat) echo 15 ;;
        AppleKeyboardUIMode) echo 3 ;;
        FXPreferredViewStyle) echo Nlsv ;;
        FXDefaultSearchScope) echo SCcf ;;
        NewWindowTarget) echo PfHm ;;
        orientation) echo bottom ;;
        mineffect) echo genie ;;
        AppleActionOnDoubleClick) echo Minimize ;;
        AppleWindowTabbingMode) echo fullscreen ;;
        location) echo "/Users/test/Screen Shots" ;;
        *) return 2 ;;
    esac
}

defaults() {
    local operation="$1"
    local domain="$2"
    local key="$3"
    local identity="$domain|$key"

    if [[ "$identity" == "$MOCK_TARGET" && "$MOCK_MODE" == native_* ]]; then
        [[ "$domain" != NSGlobalDomain ]] || domain=kCFPreferencesAnyApplication
        case "$MOCK_MODE" in
            native_wrong_key) key=unrelated ;;
            native_wrong_domain) domain=unrelated ;;
            native_service) echo 'Preferences service unavailable' >&2; return 1 ;;
        esac
        echo "Error: Could not find key '$key' in domain '$domain'." >&2
        [[ "$MOCK_MODE" != native_error_status ]] || return 2
        return 1
    fi

    case "$key" in
        location-screenshot|target-screenshot|target)
            if [[ "$identity" != "$MOCK_TARGET" ]]; then
                echo "The domain/default pair of ($domain, $key) does not exist" >&2
                return 1
            fi
            if [[ "$MOCK_MODE" == raw_value ]]; then
                if [[ "$operation" == read-type ]]; then echo 'Type is string'; else printf '%b' "$MOCK_VALUE"; fi
                return 0
            fi ;;
    esac
    case "$key" in
        EnableStandardClickToShowDesktop|EnableTilingByEdgeDrag|EnableTopTilingByEdgeDrag|EnableTiledWindowMargins)
            if [[ "$WINDOW_EXPANSION" != true ]]; then echo "The domain/default pair of ($domain, $key) does not exist" >&2; return 1; fi ;;
    esac
    if [[ "$MOCK_MODE" == all_absent ||
          ( "$MOCK_MODE" == absent && "$identity" == "$MOCK_TARGET" ) ]]; then
        echo "The domain/default pair of ($domain, $key) does not exist" >&2
        return 1
    fi

    if [[ "$identity" == "$MOCK_TARGET" ]]; then
        case "$MOCK_MODE" in
            type_failure)
                echo "Preferences service unavailable" >&2
                return 1
                ;;
            type_mismatch)
                if [[ "$operation" == read-type ]]; then
                    echo "Type is string"
                    return 0
                fi
                ;;
            float_type)
                if [[ "$operation" == read-type ]]; then
                    echo "Type is float"
                    return 0
                fi
                if [[ "$operation" == read ]]; then
                    printf '%s\n' "$MOCK_VALUE"
                    return 0
                fi
                ;;
            value_failure)
                if [[ "$operation" == read ]]; then
                    echo "Preferences read failed" >&2
                    return 1
                fi
                ;;
            raw_value)
                if [[ "$operation" == read ]]; then
                    printf '%b' "$MOCK_VALUE"
                    return 0
                fi
                ;;
            empty_string)
                if [[ "$operation" == read ]]; then
                    return 0
                fi
                ;;
        esac
    fi

    case "$operation" in
        read-type) mock_native_type "$key" ;;
        read) mock_value "$key" ;;
        *) return 2 ;;
    esac
}

source "$PROJECT_ROOT/modules/discovery/macos/macos.sh"
source "$PROJECT_ROOT/modules/settings/macos/defaults.sh"

ORIGINAL_SERIALIZE_KEYBOARD="$(declare -f serialize_keyboard_settings)"
ORIGINAL_SERIALIZE_DOCK="$(declare -f serialize_dock_settings)"
ORIGINAL_SERIALIZE_WINDOWS="$(declare -f serialize_windows_settings)"
ORIGINAL_SERIALIZE_FINDER="$(declare -f serialize_finder_settings)"
ORIGINAL_EXPORT_FINDER="$(declare -f export_finder_settings)"
ORIGINAL_EXPORT_DOCK="$(declare -f export_dock_settings)"
ORIGINAL_EXPORT_WINDOWS="$(declare -f export_windows_settings)"
ORIGINAL_EXPORT_KEYBOARD="$(declare -f export_keyboard_settings)"
ORIGINAL_EXPORT_TRACKPAD="$(declare -f export_trackpad_settings)"
ORIGINAL_EXPORT_SCREENSHOTS="$(declare -f export_screenshots_settings)"

pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1"
    ((TEST_FAILURES++))
}

reset_functions() {
    eval "$ORIGINAL_SERIALIZE_KEYBOARD"
    eval "$ORIGINAL_SERIALIZE_DOCK"
    eval "$ORIGINAL_SERIALIZE_WINDOWS"
    eval "$ORIGINAL_SERIALIZE_FINDER"
    eval "$ORIGINAL_EXPORT_FINDER"
    eval "$ORIGINAL_EXPORT_DOCK"
    eval "$ORIGINAL_EXPORT_WINDOWS"
    eval "$ORIGINAL_EXPORT_KEYBOARD"
    eval "$ORIGINAL_EXPORT_TRACKPAD"
    eval "$ORIGINAL_EXPORT_SCREENSHOTS"
}

reset_fixture() {
    reset_functions
    rm -rf "$TEST_ROOT/config"
    mkdir -p "$TEST_ROOT/config/generated/macos"
    MOCK_MODE=normal
    MOCK_MACOS_VERSION=26.7.1
    MOCK_TARGET=""
    SUCCESS_MESSAGES=""
    WARNING_MESSAGES=""
    ERROR_MESSAGES=""
}

reset_counters() {
    MODULES_CHECKED=0
    INSTALLED_COUNT=0
    SKIPPED_COUNT=0
    WARNING_COUNT=0
    ERROR_COUNT=0
}

temporary_files() {
    find config/generated/macos -type f -name '*.tmp.*' -print 2>/dev/null
}

cd "$TEST_ROOT" || exit 1

optional_preferences_checks() {
    local domain key type mode result
    while IFS='|' read -r domain key type; do
        reset_fixture
        MOCK_TARGET="$domain|$key"
        MOCK_MODE=native_absent
        macos_collect_preference "$TEST_ROOT/optional.conf" "$domain" "$key" "$type"
        [[ $? -eq 0 && ! -s "$TEST_ROOT/optional.conf" ]] || fail "$key native absence omitted"
        check_defaults_record "$domain" "$key" "$type" true
        [[ $? -eq 1 && "$DEFAULTS_OBSERVATION_KIND" == absent ]] || fail "$key consumer absence"
        for mode in native_wrong_key native_wrong_domain native_service native_error_status; do
            MOCK_MODE="$mode"
            macos_collect_preference "$TEST_ROOT/optional.conf" "$domain" "$key" "$type"
            [[ $? -eq 2 ]] || fail "$key $mode is not absence"
            check_defaults_record "$domain" "$key" "$type" true
            [[ $? -eq 2 && "$DEFAULTS_OBSERVATION_KIND" == unknown ]] || fail "$key $mode consumer fails closed"
        done
    done <<'OPTIONAL_KEYS'
com.apple.finder|ShowMountedServersOnDesktop|bool
com.apple.dock|show-process-indicators|bool
NSGlobalDomain|AppleWindowTabbingMode|string
NSGlobalDomain|ApplePressAndHoldEnabled|bool
NSGlobalDomain|AppleKeyboardUIMode|int
NSGlobalDomain|NSAutomaticSpellingCorrectionEnabled|bool
NSGlobalDomain|NSAutomaticQuoteSubstitutionEnabled|bool
NSGlobalDomain|NSAutomaticDashSubstitutionEnabled|bool
com.apple.screencapture|disable-shadow|bool
com.apple.screencapture|show-thumbnail|bool
OPTIONAL_KEYS
    for mode in native_absent native_wrong_key native_wrong_domain native_service native_error_status; do
        MOCK_TARGET='com.apple.screencapture|location-screenshot'; MOCK_MODE="$mode"
        screenshots_read_optional_string location-screenshot
        result=$?
        if [[ "$mode" == native_absent ]]; then
            [[ $result -eq 1 ]] || fail 'Screenshots native absence'
        else
            [[ $result -eq 2 ]] || fail "Screenshots $mode is not absence"
        fi
    done
    reset_fixture
    MOCK_MODE=native_absent; MOCK_TARGET='com.apple.finder|ShowMountedServersOnDesktop'
    export_finder_settings >/dev/null
    [[ $? -eq 0 ]] && ! grep -q '|ShowMountedServersOnDesktop|' config/generated/macos/finder.conf || fail 'native absence publishes remaining Finder records'
    local before_checksum
    before_checksum="$(cksum config/generated/macos/finder.conf)"
    MOCK_MODE=native_service
    export_finder_settings >/dev/null
    [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/finder.conf)" ]] || fail 'native error preserves prior snapshot'
    reset_fixture
}
optional_preferences_checks
if [[ "${1:-}" == --optional-preferences-only ]]; then
    [[ "$TEST_FAILURES" -eq 0 ]] && echo 'PASS: 107 focused optional-preference assertions'
    exit "$TEST_FAILURES"
fi

windows_expansion_discovery_checks() {
    local key value mode before_checksum
    WINDOW_EXPANSION=true
    for key in EnableStandardClickToShowDesktop EnableTilingByEdgeDrag EnableTopTilingByEdgeDrag EnableTiledWindowMargins; do
        for value in true false; do
            reset_fixture; MOCK_MODE=raw_value; MOCK_TARGET="com.apple.WindowManager|$key"; MOCK_VALUE="$value\n"
            export_windows_settings >/dev/null
            [[ $? -eq 0 ]] && grep -Fxq "com.apple.WindowManager|$key|bool|$value" config/generated/macos/windows.conf || fail "$key populated"
        done
        reset_fixture; MOCK_MODE=absent; MOCK_TARGET="com.apple.WindowManager|$key"
        export_windows_settings >/dev/null
        [[ $? -eq 0 ]] && ! grep -q "|$key|" config/generated/macos/windows.conf || fail "$key absence"
        for mode in type_failure type_mismatch value_failure raw_value; do
            reset_fixture; export_windows_settings >/dev/null
            before_checksum="$(cksum config/generated/macos/windows.conf)"
            MOCK_MODE="$mode"; MOCK_TARGET="com.apple.WindowManager|$key"; MOCK_VALUE='invalid\n'
            export_windows_settings >/dev/null
            [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/windows.conf)" ]] || fail "$key $mode preserves snapshot"
        done
    done
    WINDOW_EXPANSION=false
    reset_fixture; export_windows_settings >/dev/null
    [[ $? -eq 0 && "$(wc -l < config/generated/macos/windows.conf | tr -d ' ')" == 5 ]] || fail 'legacy Windows remains five records'
    reset_fixture
}
if [[ "${1:-}" != --screenshots-only ]]; then windows_expansion_discovery_checks; fi
if [[ "${1:-}" == --windows-expansion-only ]]; then
    [[ "$TEST_FAILURES" -eq 0 ]] && echo 'PASS: focused Windows Discovery fixtures'
    exit "$TEST_FAILURES"
fi

screenshots_discovery_checks() {
    local key mode before_checksum expected
    expected=$'com.apple.screencapture|location|string|/Users/test/Screen Shots\ncom.apple.screencapture|disable-shadow|bool|0\ncom.apple.screencapture|show-thumbnail|bool|1'
    reset_fixture
    export_screenshots_settings >/dev/null
    [[ $? -eq 0 && "$(cat config/generated/macos/screenshots.conf)" == "$expected" ]] || fail 'Screenshots populated records'
    for key in disable-shadow show-thumbnail; do
        for value in true false; do
            reset_fixture; MOCK_MODE=raw_value; MOCK_TARGET="com.apple.screencapture|$key"; MOCK_VALUE="$value\n"
            export_screenshots_settings >/dev/null
            [[ $? -eq 0 ]] && grep -Fxq "com.apple.screencapture|$key|bool|$value" config/generated/macos/screenshots.conf || fail "$key $value"
        done
        reset_fixture; MOCK_MODE=absent; MOCK_TARGET="com.apple.screencapture|$key"
        export_screenshots_settings >/dev/null
        [[ $? -eq 0 ]] && ! grep -q "|$key|" config/generated/macos/screenshots.conf || fail "$key absence"
        for mode in type_failure type_mismatch value_failure raw_value; do
            reset_fixture
            printf '%s\n' "$expected" > config/generated/macos/screenshots.conf
            before_checksum="$(cksum config/generated/macos/screenshots.conf)"
            MOCK_MODE="$mode"; MOCK_TARGET="com.apple.screencapture|$key"; MOCK_VALUE='malformed\n'
            export_screenshots_settings >/dev/null
            [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/screenshots.conf)" && -z "$(temporary_files)" ]] || fail "$key $mode preserves snapshot"
        done
    done
    reset_fixture; MOCK_MODE=all_absent
    export_screenshots_settings >/dev/null
    [[ $? -eq 0 && "$(cat config/generated/macos/screenshots.conf)" == 'com.apple.screencapture|location|string|~/Desktop' ]] || fail 'absent location captures Desktop'
    [[ "$SCREENSHOTS_LOCATION_ORIGIN" == default_desktop ]] || fail 'implicit Desktop origin'
    for value in "$HOME/Desktop" "$HOME/Pictures/Captures" /Volumes/Captures; do
        reset_fixture; MOCK_MODE=raw_value; MOCK_TARGET='com.apple.screencapture|location'; MOCK_VALUE="$value\n"
        export_screenshots_settings >/dev/null
        [[ $? -eq 0 ]] || fail 'explicit destination capture'
        # Literal HOME-relative requirements are config data.
        # shellcheck disable=SC2088
        case "$value" in
            "$HOME/Desktop") mode=explicit_desktop; value='~/Desktop' ;;
            "$HOME"/*) mode=home; value='~/Pictures/Captures' ;;
            *) mode=external ;;
        esac
        grep -Fxq "com.apple.screencapture|location|string|$value" config/generated/macos/screenshots.conf || fail 'portable destination'
        [[ "$SCREENSHOTS_LOCATION_ORIGIN" == "$mode" ]] || fail 'destination origin'
    done
    for mode in mixed target service value unknown_version future; do
        reset_fixture
        printf '%s\n' "$expected" > config/generated/macos/screenshots.conf
        before_checksum="$(cksum config/generated/macos/screenshots.conf)"
        case "$mode" in
            mixed) MOCK_MODE=raw_value; MOCK_TARGET='com.apple.screencapture|location-screenshot'; MOCK_VALUE="$HOME/Downloads\n" ;;
            target) MOCK_MODE=raw_value; MOCK_TARGET='com.apple.screencapture|target'; MOCK_VALUE='clipboard\n' ;;
            service) MOCK_MODE=type_failure; MOCK_TARGET='com.apple.screencapture|location' ;;
            value) MOCK_MODE=value_failure; MOCK_TARGET='com.apple.screencapture|location' ;;
            unknown_version) MOCK_MACOS_VERSION=unknown ;;
            future) MOCK_MACOS_VERSION=28.0 ;;
        esac
        export_screenshots_settings >/dev/null
        [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/screenshots.conf)" && -z "$(temporary_files)" ]] || fail "$mode preserves snapshot"
        [[ "$SCREENSHOTS_LOCATION_ORIGIN" == unknown ]] || fail "$mode is not Desktop"
    done
}
screenshots_discovery_checks
if [[ "${1:-}" == --screenshots-only ]]; then
    [[ $TEST_FAILURES -eq 0 ]] || exit 1
    echo 'PASS: focused Screenshots Discovery fixtures'; exit 0
fi

# ==========================================
# Normal populated formats for all categories
# ==========================================

reset_fixture
export_finder_settings >/dev/null
finder_status=$?
expected_finder=$'NSGlobalDomain|AppleShowAllExtensions|bool|1\ncom.apple.finder|ShowPathbar|bool|0\ncom.apple.finder|ShowStatusBar|bool|1\ncom.apple.finder|FXPreferredViewStyle|string|Nlsv\ncom.apple.finder|FXDefaultSearchScope|string|SCcf\ncom.apple.finder|_FXSortFoldersFirst|bool|1\ncom.apple.finder|FXRemoveOldTrashItems|bool|0\ncom.apple.finder|AppleShowAllFiles|bool|1\ncom.apple.finder|NewWindowTarget|string|PfHm\ncom.apple.finder|ShowHardDrivesOnDesktop|bool|0\ncom.apple.finder|ShowExternalHardDrivesOnDesktop|bool|1\ncom.apple.finder|ShowMountedServersOnDesktop|bool|0\ncom.apple.finder|FXEnableExtensionChangeWarning|bool|1'
if [[ $finder_status -eq 0 && "$(cat config/generated/macos/finder.conf)" == "$expected_finder" ]]; then
    pass "Finder exact 13-record inventory preserves the existing format"
else
    fail "Finder populated format changed"
fi

reset_fixture
export_dock_settings >/dev/null
dock_status=$?
expected_dock=$'com.apple.dock|autohide|bool|1\ncom.apple.dock|show-recents|bool|0\ncom.apple.dock|tilesize|int|48\ncom.apple.dock|magnification|bool|1\ncom.apple.dock|largesize|int|64\ncom.apple.dock|orientation|string|bottom\ncom.apple.dock|mineffect|string|genie\ncom.apple.dock|minimize-to-application|bool|1\ncom.apple.dock|show-process-indicators|bool|0\ncom.apple.dock|launchanim|bool|1\ncom.apple.dock|mru-spaces|bool|0'
if [[ $dock_status -eq 0 && "$(cat config/generated/macos/dock.conf)" == "$expected_dock" ]]; then
    pass "Dock exact eleven-record inventory preserves the existing format"
else
    fail "Dock populated format changed"
fi

reset_fixture
MOCK_TARGET='com.apple.dock|tilesize'
MOCK_MODE=float_type
MOCK_VALUE='65.000000'
export_dock_settings >/dev/null
if [[ $? -eq 0 ]] && grep -Fxq 'com.apple.dock|tilesize|float|65.000000' config/generated/macos/dock.conf; then
    pass 'Dock tilesize float survives Discovery and generated validation'
else
    fail 'Dock tilesize float Discovery'
fi
MOCK_VALUE='65.5'
export_dock_settings >/dev/null
if [[ $? -eq 0 ]] && grep -Fxq 'com.apple.dock|tilesize|float|65.5' config/generated/macos/dock.conf; then
    pass 'Dock fractional tilesize survives Discovery'
else
    fail 'Dock fractional tilesize Discovery'
fi
before_checksum="$(cksum config/generated/macos/dock.conf)"
MOCK_VALUE='not-a-number'
export_dock_settings >/dev/null
if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/dock.conf)" ]]; then
    pass 'Invalid Dock float value preserves published snapshot'
else
    fail 'Invalid Dock float value publication guard'
fi
MOCK_MODE=type_mismatch
export_dock_settings >/dev/null
if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/dock.conf)" ]]; then
    pass 'Incompatible Dock plist type preserves published snapshot'
else
    fail 'Incompatible Dock plist type publication guard'
fi

reset_fixture
export_windows_settings >/dev/null
windows_status=$?
expected_windows=$'NSGlobalDomain|AppleActionOnDoubleClick|string|Minimize\nNSGlobalDomain|AppleWindowTabbingMode|string|fullscreen\nNSGlobalDomain|NSCloseAlwaysConfirmsChanges|bool|1\nNSGlobalDomain|NSQuitAlwaysKeepsWindows|bool|1\ncom.apple.WindowManager|HideDesktop|bool|1'
if [[ $windows_status -eq 0 && "$(cat config/generated/macos/windows.conf)" == "$expected_windows" ]]; then
    pass "Window Management exact five-record inventory uses the scalar format"
else
    fail "Window Management populated format changed"
fi
if grep -Eq 'StageManager|StandardHideWidgets' config/generated/macos/windows.conf; then
    fail "unsupported WindowManager setting entered the generated inventory"
else
    pass "Window Management inventory excludes unsupported settings"
fi

reset_fixture
export_keyboard_settings >/dev/null
keyboard_status=$?
expected_keyboard=$'NSGlobalDomain|KeyRepeat|int|2\nNSGlobalDomain|InitialKeyRepeat|int|15\nNSGlobalDomain|ApplePressAndHoldEnabled|bool|1\nNSGlobalDomain|AppleKeyboardUIMode|int|3\nNSGlobalDomain|NSAutomaticCapitalizationEnabled|bool|1\nNSGlobalDomain|NSAutomaticSpellingCorrectionEnabled|bool|0\nNSGlobalDomain|NSAutomaticPeriodSubstitutionEnabled|bool|0\nNSGlobalDomain|NSAutomaticQuoteSubstitutionEnabled|bool|1\nNSGlobalDomain|NSAutomaticDashSubstitutionEnabled|bool|0'
if [[ $keyboard_status -eq 0 && "$(cat config/generated/macos/keyboard.conf)" == "$expected_keyboard" ]]; then
    pass "Keyboard exact nine-record inventory preserves the existing format"
else
    fail "Keyboard populated format changed"
fi

reset_fixture
export_trackpad_settings >/dev/null
expected_trackpad=$'com.apple.AppleMultitouchTrackpad|Clicking|bool|1\ncom.apple.AppleMultitouchTrackpad|TrackpadRightClick|bool|0'
if [[ $? -eq 0 && "$(cat config/generated/macos/trackpad.conf)" == "$expected_trackpad" ]]; then
    pass "Trackpad exact two-record inventory uses the scalar format"
else
    fail "Trackpad populated format changed"
fi

for key in Clicking TrackpadRightClick; do
    reset_fixture
    MOCK_MODE=absent
    MOCK_TARGET="com.apple.AppleMultitouchTrackpad|$key"
    export_trackpad_settings >/dev/null
    expected_remaining="$(printf '%s\n' "$expected_trackpad" | awk -F '|' -v key="$key" '$2 != key')"
    if [[ $? -eq 0 && "$(cat config/generated/macos/trackpad.conf)" == "$expected_remaining" ]]; then
        pass "absent $key remains unmanaged"
    else
        fail "absent $key changed Trackpad inventory incorrectly"
    fi

    for mode in type_failure value_failure; do
        reset_fixture
        printf '%s\n' "$expected_trackpad" > config/generated/macos/trackpad.conf
        before_checksum="$(cksum config/generated/macos/trackpad.conf)"
        MOCK_MODE="$mode"
        MOCK_TARGET="com.apple.AppleMultitouchTrackpad|$key"
        export_trackpad_settings >/dev/null
        if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/trackpad.conf)" &&
              "$SUCCESS_MESSAGES" != *exported* && -z "$(temporary_files)" ]]; then
            pass "$key $mode preserves previous Trackpad snapshot"
        else
            fail "$key $mode Trackpad publication safety"
        fi
    done
done

reset_fixture
export_screenshots_settings >/dev/null
if [[ $? -eq 0 && "$(cat config/generated/macos/screenshots.conf)" == $'com.apple.screencapture|location|string|/Users/test/Screen Shots\ncom.apple.screencapture|disable-shadow|bool|0\ncom.apple.screencapture|show-thumbnail|bool|1' ]]; then
    pass "Screenshots present string with spaces preserves the existing format"
else
    fail "Screenshots populated format changed"
fi


# Stage 9B: each new key is independently observed; absence remains unmanaged.
new_finder_keys=(AppleShowAllFiles NewWindowTarget ShowHardDrivesOnDesktop ShowExternalHardDrivesOnDesktop ShowMountedServersOnDesktop FXEnableExtensionChangeWarning)
for key in "${new_finder_keys[@]}"; do
    reset_fixture
    MOCK_MODE=absent
    MOCK_TARGET="com.apple.finder|$key"
    export_finder_settings >/dev/null
    result=$?
    expected_remaining="$(printf '%s\n' "$expected_finder" | awk -F '|' -v key="$key" '$2 != key')"
    if [[ $result -eq 0 && "$(cat config/generated/macos/finder.conf)" == "$expected_remaining" ]]; then
        pass "absent $key omitted with the other 12 records intact"
    else
        fail "absent $key changed the remaining inventory"
    fi
    for mode in type_failure value_failure; do
        reset_fixture
        printf '%s\n' "$expected_finder" > config/generated/macos/finder.conf
        before_checksum="$(cksum config/generated/macos/finder.conf)"
        MOCK_MODE="$mode"
        MOCK_TARGET="com.apple.finder|$key"
        export_finder_settings >/dev/null
        if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/finder.conf)" &&
              "$SUCCESS_MESSAGES" != *exported* && -z "$(temporary_files)" ]]; then
            pass "$key $mode preserves previous Finder snapshot"
        else
            fail "$key $mode publication safety"
        fi
    done
done

for target in PfCm PfVo PfHm PfDe PfDo PfAF PfLo unknown ''; do
    reset_fixture
    MOCK_MODE=raw_value
    MOCK_TARGET='com.apple.finder|NewWindowTarget'
    MOCK_VALUE="$target"
    export_finder_settings >/dev/null
    result=$?
    case "$target" in
        PfLo|unknown|'')
            expected_remaining="$(printf '%s\n' "$expected_finder" | awk -F '|' '$2 != "NewWindowTarget"')"
            if [[ $result -eq 1 && "$(cat config/generated/macos/finder.conf)" == "$expected_remaining" &&
                  "$WARNING_MESSAGES" == *'Skipping unsupported Finder NewWindowTarget'* && -z "$(temporary_files)" ]]; then
                pass "unsupported target '$target' omitted with warning and valid publication"
            else
                fail "unsupported target '$target' handling"
            fi ;;
        *)
            expected_target="$(printf '%s\n' "$expected_finder" | sed "s/NewWindowTarget|string|PfHm/NewWindowTarget|string|$target/")"
            if [[ $result -eq 0 && "$(cat config/generated/macos/finder.conf)" == "$expected_target" ]]; then
                pass "supported target $target exported exactly"
            else
                fail "supported target $target export"
            fi ;;
    esac
    MOCK_MODE=normal
    export_finder_settings >/dev/null
    [[ $? -eq 0 ]] || fail 'Finder warning leaked into next export'
done

for raw in 'PfHm|extra\n' 'PfHm\t\n' 'PfHm\nextra\n' 'PfHm\000\n'; do
    reset_fixture
    printf '%s\n' "$expected_finder" > config/generated/macos/finder.conf
    before_checksum="$(cksum config/generated/macos/finder.conf)"
    MOCK_MODE=raw_value
    MOCK_TARGET='com.apple.finder|NewWindowTarget'
    MOCK_VALUE="$raw"
    export_finder_settings >/dev/null
    if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/finder.conf)" &&
          -z "$WARNING_MESSAGES" && -z "$(temporary_files)" ]]; then
        pass 'unsafe target scalar fails instead of being downgraded to unsupported'
    else
        fail 'unsafe target scalar weakened publication safety'
    fi
done

reset_fixture
printf '%s\n' "$expected_finder" > config/generated/macos/finder.conf
before_checksum="$(cksum config/generated/macos/finder.conf)"
serialize_finder_settings() { printf 'com.apple.finder|NewWindowTarget|string|PfLo\n' > "$1"; }
export_finder_settings >/dev/null
if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/finder.conf)" && -z "$(temporary_files)" ]]; then
    pass 'unsupported enum candidate cannot bypass shared validation'
else
    fail 'unsupported enum candidate published'
fi

reset_fixture
reset_counters
MOCK_MODE=raw_value
MOCK_TARGET='com.apple.finder|NewWindowTarget'
MOCK_VALUE=PfLo
run_module 'macOS Discovery' discover_macos >/dev/null
if [[ $? -eq 1 && $WARNING_COUNT -eq 1 && $ERROR_COUNT -eq 0 &&
      "$WARNING_MESSAGES" == *'macOS Discovery completed with warnings'* ]]; then
    pass 'real unsupported Finder target propagates warning through controller and lifecycle'
else
    fail 'unsupported Finder warning lost by orchestration'
fi

# Stage 9C: each new key is independently observed; absence remains unmanaged.
new_dock_keys=(orientation mineffect minimize-to-application show-process-indicators launchanim mru-spaces)
for key in "${new_dock_keys[@]}"; do
    reset_fixture
    MOCK_MODE=absent
    MOCK_TARGET="com.apple.dock|$key"
    export_dock_settings >/dev/null
    result=$?
    expected_remaining="$(printf '%s\n' "$expected_dock" | awk -F '|' -v key="$key" '$2 != key')"
    if [[ $result -eq 0 && "$(cat config/generated/macos/dock.conf)" == "$expected_remaining" ]]; then
        pass "absent $key omitted with the other ten records intact"
    else
        fail "absent $key changed the remaining inventory"
    fi
    for mode in type_failure value_failure; do
        reset_fixture
        printf '%s\n' "$expected_dock" > config/generated/macos/dock.conf
        before_checksum="$(cksum config/generated/macos/dock.conf)"
        MOCK_MODE="$mode"
        MOCK_TARGET="com.apple.dock|$key"
        export_dock_settings >/dev/null
        if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/dock.conf)" &&
              "$SUCCESS_MESSAGES" != *exported* && -z "$(temporary_files)" ]]; then
            pass "$key $mode preserves previous Dock snapshot"
        else
            fail "$key $mode publication safety"
        fi
    done
done


for entry in orientation:left orientation:bottom orientation:right orientation:unknown orientation: mineffect:genie mineffect:scale mineffect:unknown mineffect:; do
    reset_fixture
    key="${entry%%:*}"
    value="${entry#*:}"
    MOCK_MODE=raw_value
    MOCK_TARGET="com.apple.dock|$key"
    MOCK_VALUE="$value"
    export_dock_settings >/dev/null
    result=$?
    case "$value" in
        unknown|'')
            expected_remaining="$(printf '%s\n' "$expected_dock" | awk -F '|' -v key="$key" '$2 != key')"
            if [[ $result -eq 1 && "$(cat config/generated/macos/dock.conf)" == "$expected_remaining" &&
                  "$WARNING_MESSAGES" == *"Skipping unsupported Dock $key:"* && -z "$(temporary_files)" ]]; then
                pass "unsupported $key '$value' omitted with warning; other records intact"
            else
                fail "unsupported Dock $key handling"
            fi ;;
        *)
            expected_enum="$(printf '%s\n' "$expected_dock" | awk -F '|' -v OFS='|' -v key="$key" -v value="$value" '$2 == key {$4=value} {print}')"
            if [[ $result -eq 0 && "$(cat config/generated/macos/dock.conf)" == "$expected_enum" ]]; then
                pass "supported Dock $key $value exported exactly"
            else
                fail "supported Dock $key export"
            fi ;;
    esac
    MOCK_MODE=normal
    export_dock_settings >/dev/null
    [[ $? -eq 0 ]] || fail 'Dock warning leaked into next export'
done

for key in orientation mineffect; do
    for raw in 'bad|extra\n' 'bad\t\n' 'bad\nextra\n' 'bad\000\n'; do
        reset_fixture
        printf '%s\n' "$expected_dock" > config/generated/macos/dock.conf
        before_checksum="$(cksum config/generated/macos/dock.conf)"
        MOCK_MODE=raw_value
        MOCK_TARGET="com.apple.dock|$key"
        MOCK_VALUE="$raw"
        export_dock_settings >/dev/null
        if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/dock.conf)" &&
              -z "$WARNING_MESSAGES" && -z "$(temporary_files)" ]]; then
            pass "unsafe Dock $key scalar fails without warning downgrade"
        else
            fail "unsafe Dock $key scalar publication safety"
        fi
    done
    reset_fixture
    printf '%s\n' "$expected_dock" > config/generated/macos/dock.conf
    before_checksum="$(cksum config/generated/macos/dock.conf)"
    serialize_dock_settings() { printf 'com.apple.dock|%s|string|unsupported\n' "$key" > "$1"; }
    export_dock_settings >/dev/null
    if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/dock.conf)" && -z "$(temporary_files)" ]]; then
        pass "invalid Dock $key candidate cannot bypass shared validation"
    else
        fail "invalid Dock $key candidate published"
    fi
    reset_fixture
    reset_counters
    MOCK_MODE=raw_value
    MOCK_TARGET="com.apple.dock|$key"
    MOCK_VALUE=unsupported
    run_module 'macOS Discovery' discover_macos >/dev/null
    if [[ $? -eq 1 && $WARNING_COUNT -eq 1 && $ERROR_COUNT -eq 0 &&
          "$WARNING_MESSAGES" == *'macOS Discovery completed with warnings'* ]]; then
        pass "Dock $key warning propagates through controller and lifecycle"
    else
        fail "Dock $key warning lost"
    fi
done

# Stage 9E.1/9E.6: Window Management scalars and category publication.
windows_preferences=(
    'NSGlobalDomain|AppleActionOnDoubleClick'
    'NSGlobalDomain|AppleWindowTabbingMode'
    'NSGlobalDomain|NSCloseAlwaysConfirmsChanges'
    'NSGlobalDomain|NSQuitAlwaysKeepsWindows'
    'com.apple.WindowManager|HideDesktop'
)
for preference in "${windows_preferences[@]}"; do
    domain="${preference%%|*}"
    key="${preference#*|}"
    reset_fixture
    MOCK_MODE=absent
    MOCK_TARGET="$domain|$key"
    export_windows_settings >/dev/null
    result=$?
    expected_remaining="$(printf '%s\n' "$expected_windows" | awk -F '|' -v key="$key" '$2 != key')"
    if [[ $result -eq 0 && "$(cat config/generated/macos/windows.conf)" == "$expected_remaining" ]]; then
        pass "absent $key omitted with the other Window Management records intact"
    else
        fail "absent $key changed the Window Management inventory"
    fi

    for mode in type_failure value_failure; do
        reset_fixture
        printf '%s\n' "$expected_windows" > config/generated/macos/windows.conf
        before_checksum="$(cksum config/generated/macos/windows.conf)"
        MOCK_MODE="$mode"
        MOCK_TARGET="$domain|$key"
        export_windows_settings >/dev/null
        if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/windows.conf)" &&
              "$SUCCESS_MESSAGES" != *exported* && -z "$(temporary_files)" ]]; then
            pass "$key $mode preserves previous Window Management snapshot"
        else
            fail "$key $mode publication safety"
        fi
    done
done

reset_fixture
MOCK_MODE=raw_value
MOCK_TARGET='com.apple.WindowManager|HideDesktop'
MOCK_VALUE=0
export_windows_settings >/dev/null
expected_hidden_false="$(printf '%s\n' "$expected_windows" | awk -F '|' -v OFS='|' '$2 == "HideDesktop" {$4=0} {print}')"
if [[ $? -eq 0 && "$(cat config/generated/macos/windows.conf)" == "$expected_hidden_false" ]]; then
    pass "explicit false HideDesktop value is discovered"
else
    fail "explicit false HideDesktop value was not preserved"
fi

reset_fixture
printf '%s\n' "$expected_windows" > config/generated/macos/windows.conf
before_checksum="$(cksum config/generated/macos/windows.conf)"
MOCK_MODE=type_mismatch
MOCK_TARGET='com.apple.WindowManager|HideDesktop'
export_windows_settings >/dev/null
if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/windows.conf)" &&
      "$SUCCESS_MESSAGES" != *exported* && -z "$(temporary_files)" ]]; then
    pass "HideDesktop wrong native type preserves previous Window Management snapshot"
else
    fail "HideDesktop wrong native type publication safety"
fi

for entry in AppleActionOnDoubleClick:Minimize AppleActionOnDoubleClick:Maximize AppleActionOnDoubleClick:Fill AppleActionOnDoubleClick:None AppleActionOnDoubleClick:invalid AppleActionOnDoubleClick: AppleWindowTabbingMode:manual AppleWindowTabbingMode:always AppleWindowTabbingMode:fullscreen AppleWindowTabbingMode:invalid AppleWindowTabbingMode:; do
    reset_fixture
    key="${entry%%:*}"
    value="${entry#*:}"
    MOCK_MODE=raw_value
    MOCK_TARGET="NSGlobalDomain|$key"
    MOCK_VALUE="$value"
    export_windows_settings >/dev/null
    result=$?
    case "$key:$value" in
        AppleActionOnDoubleClick:Minimize|AppleActionOnDoubleClick:Maximize|AppleActionOnDoubleClick:Fill|AppleActionOnDoubleClick:None|AppleWindowTabbingMode:manual|AppleWindowTabbingMode:always|AppleWindowTabbingMode:fullscreen)
            expected_enum="$(printf '%s\n' "$expected_windows" | awk -F '|' -v OFS='|' -v key="$key" -v value="$value" '$2 == key {$4=value} {print}')"
            [[ $result -eq 0 && "$(cat config/generated/macos/windows.conf)" == "$expected_enum" ]] &&
                pass "supported Window Management $key $value exported" || fail "supported Window Management enum export" ;;
        *)
            expected_remaining="$(printf '%s\n' "$expected_windows" | awk -F '|' -v key="$key" '$2 != key')"
            [[ $result -eq 1 && "$(cat config/generated/macos/windows.conf)" == "$expected_remaining" &&
               "$WARNING_MESSAGES" == *"Skipping unsupported Window Management $key:"* ]] &&
                pass "unsupported Window Management $key omitted with warning" || fail "unsupported Window Management enum handling" ;;
    esac
done

reset_fixture
printf '%s\n' "$expected_windows" > config/generated/macos/windows.conf
before_checksum="$(cksum config/generated/macos/windows.conf)"
serialize_windows_settings() { printf 'NSGlobalDomain|AppleActionOnDoubleClick|string|invalid\n' > "$1"; }
export_windows_settings >/dev/null
if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/windows.conf)" && -z "$(temporary_files)" ]]; then
    pass 'invalid Window Management candidate preserves previous snapshot'
else
    fail 'invalid Window Management candidate published'
fi

# Stage 9D: each new key is independently observed; absence remains unmanaged.
new_keyboard_keys=(ApplePressAndHoldEnabled NSAutomaticCapitalizationEnabled NSAutomaticSpellingCorrectionEnabled NSAutomaticPeriodSubstitutionEnabled NSAutomaticQuoteSubstitutionEnabled NSAutomaticDashSubstitutionEnabled AppleKeyboardUIMode)
for key in "${new_keyboard_keys[@]}"; do
    reset_fixture
    MOCK_MODE=absent
    MOCK_TARGET="NSGlobalDomain|$key"
    export_keyboard_settings >/dev/null
    result=$?
    expected_remaining="$(printf '%s\n' "$expected_keyboard" | awk -F '|' -v key="$key" '$2 != key')"
    if [[ $result -eq 0 && "$(cat config/generated/macos/keyboard.conf)" == "$expected_remaining" ]]; then
        pass "absent $key omitted with the other eight records intact"
    else
        fail "absent $key changed the remaining inventory"
    fi
    for mode in type_failure value_failure; do
        reset_fixture
        printf '%s\n' "$expected_keyboard" > config/generated/macos/keyboard.conf
        before_checksum="$(cksum config/generated/macos/keyboard.conf)"
        MOCK_MODE="$mode"
        MOCK_TARGET="NSGlobalDomain|$key"
        export_keyboard_settings >/dev/null
        if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/keyboard.conf)" &&
              "$SUCCESS_MESSAGES" != *exported* && -z "$(temporary_files)" ]]; then
            pass "$key $mode preserves previous Keyboard snapshot"
        else
            fail "$key $mode publication safety"
        fi
    done
done


for key in "${new_keyboard_keys[@]}"; do
    for raw in 'invalid\n' '1.5\n' '1|extra\n' '1\t\n' '1\nextra\n' '1\000\n'; do
        reset_fixture
        printf '%s\n' "$expected_keyboard" > config/generated/macos/keyboard.conf
        before_checksum="$(cksum config/generated/macos/keyboard.conf)"
        MOCK_MODE=raw_value
        MOCK_TARGET="NSGlobalDomain|$key"
        MOCK_VALUE="$raw"
        export_keyboard_settings >/dev/null
        if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/keyboard.conf)" &&
              -z "$(temporary_files)" && "$SUCCESS_MESSAGES" != *exported* ]]; then
            pass "invalid Keyboard $key scalar preserves previous snapshot"
        else
            fail "invalid Keyboard $key scalar publication safety"
        fi
    done
done
for value in 0 -7 08 12345; do
    reset_fixture
    MOCK_MODE=raw_value
    MOCK_TARGET='NSGlobalDomain|AppleKeyboardUIMode'
    MOCK_VALUE="$value"
    export_keyboard_settings >/dev/null
    if [[ $? -eq 0 ]] && grep -Fxq "NSGlobalDomain|AppleKeyboardUIMode|int|$value" config/generated/macos/keyboard.conf; then
        pass "Keyboard UI integer $value serialized without invented range/normalization"
    else
        fail "Keyboard UI integer $value export"
    fi
done
reset_fixture
printf '%s\n' "$expected_keyboard" > config/generated/macos/keyboard.conf
before_checksum="$(cksum config/generated/macos/keyboard.conf)"
serialize_keyboard_settings() { printf 'NSGlobalDomain|AppleKeyboardUIMode|int|invalid\n' > "$1"; }
export_keyboard_settings >/dev/null
if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/keyboard.conf)" && -z "$(temporary_files)" ]]; then
    pass 'invalid Keyboard candidate cannot bypass shared validation'
else
    fail 'invalid Keyboard candidate published'
fi
reset_fixture
reset_counters
MOCK_MODE=value_failure
MOCK_TARGET='NSGlobalDomain|AppleKeyboardUIMode'
run_module 'macOS Discovery' discover_macos >/dev/null
if [[ $? -eq 2 && $ERROR_COUNT -eq 1 ]]; then
    pass 'new Keyboard observation error propagates through controller and lifecycle'
else
    fail 'new Keyboard observation error masked'
fi

# ==========================================
# Present empty string and legitimate absence
# ==========================================

reset_fixture
MOCK_MODE=empty_string
MOCK_TARGET='com.apple.finder|FXPreferredViewStyle'
export_finder_settings >/dev/null
if [[ $? -eq 0 ]] && grep -q 'FXPreferredViewStyle|string|$' config/generated/macos/finder.conf; then
    pass "generic empty string remains distinct from absence"
else
    fail "generic empty string was lost"
fi

for raw_value in '' '/tmp/a|b\n' '/tmp/a\tb\n' '/tmp/a\nb\n' '/tmp/a\n\n' '/tmp/a\000b\n' '/tmp/a\rb\n'; do
    reset_fixture
    printf 'com.apple.screencapture|location|string|/tmp/previous\n' > config/generated/macos/screenshots.conf
    before_checksum="$(cksum config/generated/macos/screenshots.conf)"
    MOCK_MODE=raw_value
    MOCK_TARGET='com.apple.screencapture|location'
    MOCK_VALUE="$raw_value"
    export_screenshots_settings >/dev/null
    result=$?
    if [[ $result -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/screenshots.conf)" &&
          -z "$(temporary_files)" && "$SUCCESS_MESSAGES" != *exported* ]]; then
        pass "unsafe raw scalar is rejected before publication: $raw_value"
    else
        fail "unsafe raw scalar reached generated state: $raw_value"
    fi
done

reset_fixture
printf 'previous bytes\n' > config/generated/macos/finder.conf
before_checksum="$(cksum config/generated/macos/finder.conf)"
serialize_finder_settings() { printf 'com.apple.dock|autohide|bool|1\n' > "$1"; }
export_finder_settings >/dev/null
if [[ $? -eq 2 && "$before_checksum" == "$(cksum config/generated/macos/finder.conf)" && -z "$(temporary_files)" ]]; then
    pass "candidate semantic validation preserves previous file"
else
    fail "invalid candidate was published"
fi

reset_fixture
printf 'stale record\n' > config/generated/macos/finder.conf
MOCK_MODE=absent
MOCK_TARGET='com.apple.finder|ShowPathbar'
export_finder_settings >/dev/null
absence_status=$?
if [[ $absence_status -eq 0 &&
      "$(cat config/generated/macos/finder.conf)" == "$expected_finder"$'\n' ]]; then
    fail "absent Finder preference remained serialized"
elif [[ $absence_status -eq 0 ]] &&
     ! grep -q 'ShowPathbar' config/generated/macos/finder.conf &&
     ! grep -q 'stale record' config/generated/macos/finder.conf; then
    pass "legitimate absence omits the record and removes stale generated state"
else
    fail "legitimate absence failed or preserved stale state"
fi

category_functions=(
    export_finder_settings
    export_dock_settings
    export_windows_settings
    export_keyboard_settings
    export_trackpad_settings
    export_screenshots_settings
)
category_files=(finder.conf dock.conf windows.conf keyboard.conf trackpad.conf screenshots.conf)

for ((category_index = 0; category_index < ${#category_functions[@]}; category_index++)); do
    reset_fixture
    MOCK_MODE=all_absent
    "${category_functions[$category_index]}" >/dev/null
    category_status=$?
    category_file="config/generated/macos/${category_files[$category_index]}"

    if [[ $category_status -eq 0 && -f "$category_file" ]] &&
       { [[ "${category_files[$category_index]}" == screenshots.conf && "$(cat "$category_file")" == 'com.apple.screencapture|location|string|~/Desktop' ]] ||
         [[ "${category_files[$category_index]}" != screenshots.conf && ! -s "$category_file" ]]; }; then
        pass "all-absent ${category_files[$category_index]} publishes qualified defaults or an empty file"
    else
        fail "all-absent ${category_files[$category_index]} did not publish empty success"
    fi
done

# ==========================================
# Per-category unexpected type-read failures
# ==========================================

category_targets=(
    'NSGlobalDomain|AppleShowAllExtensions'
    'com.apple.dock|autohide'
    'NSGlobalDomain|AppleActionOnDoubleClick'
    'NSGlobalDomain|KeyRepeat'
    'com.apple.AppleMultitouchTrackpad|Clicking'
    'com.apple.screencapture|location'
)

for ((category_index = 0; category_index < ${#category_functions[@]}; category_index++)); do
    reset_fixture
    category_file="config/generated/macos/${category_files[$category_index]}"
    printf 'previous category bytes\n' > "$category_file"
    before_checksum="$(cksum "$category_file")"
    MOCK_MODE=type_failure
    MOCK_TARGET="${category_targets[$category_index]}"
    "${category_functions[$category_index]}" >/dev/null
    category_status=$?
    after_checksum="$(cksum "$category_file")"

    if [[ $category_status -eq 2 && "$before_checksum" == "$after_checksum" &&
          "$SUCCESS_MESSAGES" != *'exported'* && -z "$(temporary_files)" ]]; then
        pass "unexpected read-type failure preserves ${category_files[$category_index]}"
    else
        fail "unexpected read-type failure damaged ${category_files[$category_index]}"
    fi
done

# ==========================================
# Value, type, serializer, and publication failures
# ==========================================

reset_fixture
printf 'previous Finder bytes\n' > config/generated/macos/finder.conf
before_checksum="$(cksum config/generated/macos/finder.conf)"
MOCK_MODE=value_failure
MOCK_TARGET='com.apple.finder|ShowPathbar'
export_finder_settings >/dev/null
failure_status=$?
after_checksum="$(cksum config/generated/macos/finder.conf)"
if [[ $failure_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to read macOS preference'* &&
      "$SUCCESS_MESSAGES" != *'Finder configuration exported'* && -z "$(temporary_files)" ]]; then
    pass "value-read failure preserves previous generated state"
else
    fail "value-read failure was destructive or falsely successful"
fi

reset_fixture
printf 'previous Dock bytes\n' > config/generated/macos/dock.conf
before_checksum="$(cksum config/generated/macos/dock.conf)"
MOCK_MODE=type_mismatch
MOCK_TARGET='com.apple.dock|autohide'
export_dock_settings >/dev/null
failure_status=$?
after_checksum="$(cksum config/generated/macos/dock.conf)"
if [[ $failure_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Incompatible macOS preference type'* &&
      "$SUCCESS_MESSAGES" != *'Dock configuration exported'* && -z "$(temporary_files)" ]]; then
    pass "native type mismatch preserves previous generated state"
else
    fail "native type mismatch was destructive or falsely successful"
fi

reset_fixture
printf 'previous Finder bytes\n' > config/generated/macos/finder.conf
before_checksum="$(cksum config/generated/macos/finder.conf)"
serialize_finder_settings() { return 2; }
export_finder_settings >/dev/null
failure_status=$?
after_checksum="$(cksum config/generated/macos/finder.conf)"
if [[ $failure_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$SUCCESS_MESSAGES" != *'Finder configuration exported'* && -z "$(temporary_files)" ]]; then
    pass "macOS serialization failure preserves state and cleans temporary files"
else
    fail "macOS serialization failure changed state or leaked temporary output"
fi

reset_fixture
printf 'previous Finder bytes\n' > config/generated/macos/finder.conf
before_checksum="$(cksum config/generated/macos/finder.conf)"
mv() { return 1; }
export_finder_settings >/dev/null
failure_status=$?
unset -f mv
after_checksum="$(cksum config/generated/macos/finder.conf)"
if [[ $failure_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$SUCCESS_MESSAGES" != *'Finder configuration exported'* && -z "$(temporary_files)" ]]; then
    pass "macOS publication failure preserves state and cleans temporary files"
else
    fail "macOS publication failure changed state or leaked temporary output"
fi

# ==========================================
# macOS controller and run_module propagation
# ==========================================

reset_fixture
discover_macos >/dev/null
if [[ $? -eq 0 && "$SUCCESS_MESSAGES" == *'macOS Discovery completed'* ]]; then
    pass "macOS Discovery controller preserves all-success status 0"
else
    fail "macOS Discovery controller success aggregation changed"
fi

reset_fixture
MOCK_MODE=type_failure
MOCK_TARGET='com.apple.dock|autohide'
discover_macos >/dev/null
if [[ $? -eq 2 && "$ERROR_MESSAGES" == *'macOS Discovery completed with errors'* &&
      "$SUCCESS_MESSAGES" != *'macOS Discovery completed'* ]]; then
    pass "macOS Discovery controller preserves category error status 2"
else
    fail "macOS Discovery controller masked a category error"
fi

reset_fixture
export_finder_settings() { return 1; }
export_dock_settings() { return 0; }
export_keyboard_settings() { return 0; }
export_trackpad_settings() { return 0; }
export_screenshots_settings() { return 0; }
discover_macos >/dev/null
if [[ $? -eq 1 ]]; then
    pass "macOS Discovery controller retains warning status 1"
else
    fail "macOS Discovery controller warning aggregation changed"
fi

for lifecycle_status in 0 1 2; do
    reset_fixture
    reset_counters
    export_finder_settings() { return "$lifecycle_status"; }
    export_dock_settings() { return 0; }
    export_keyboard_settings() { return 0; }
    export_trackpad_settings() { return 0; }
    export_screenshots_settings() { return 0; }

    run_module "macOS Discovery" discover_macos >/dev/null
    actual_status=$?

    if [[ $actual_status -eq $lifecycle_status &&
          $WARNING_COUNT -eq $((lifecycle_status == 1 ? 1 : 0)) &&
          $ERROR_COUNT -eq $((lifecycle_status == 2 ? 1 : 0)) ]]; then
        pass "macOS Discovery run_module propagates $lifecycle_status"
    else
        fail "macOS Discovery run_module failed to propagate $lifecycle_status"
    fi
done

if [[ $TEST_FAILURES -ne 0 ]]; then
    echo
    echo "$TEST_FAILURES macOS Discovery test(s) failed"
    exit 1
fi

echo
echo "All macOS Discovery tests passed"
