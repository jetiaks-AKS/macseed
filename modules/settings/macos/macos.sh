#!/bin/bash

# ==========================================
# macOS Settings
# ==========================================

source modules/settings/macos/defaults.sh
source modules/settings/macos/finder.sh
source modules/settings/macos/dock.sh
source modules/settings/macos/windows.sh
source modules/settings/macos/keyboard.sh
source modules/settings/macos/trackpad.sh
source modules/settings/macos/screenshots.sh

# ==========================================
# Preview macOS Settings
# ==========================================

preview_macos_category() {
    local config_file="$1"
    local restart_process="${2:-}"

    preview_defaults_config "$config_file" "${3:-}" || return 2

    if [[ "$DEFAULTS_PREVIEW_CHANGED" == true && -n "$restart_process" ]]; then
        preview_record "macos-${3:-settings}" "$restart_process" restart_process planned
        preview_action "Would restart process: $restart_process"
    fi

    return 0
}

preview_macos_settings() {
    if blueprint_category_enabled macos-finder; then
        preview_macos_category "$FINDER_CONFIG" Finder finder || return 2
    fi
    if blueprint_category_enabled macos-dock; then
        preview_macos_category "$DOCK_CONFIG" Dock dock || return 2
    fi
    if blueprint_category_enabled macos-windows; then
        preview_macos_category "$WINDOWS_CONFIG" "" windows || return 2
    fi
    if blueprint_category_enabled macos-keyboard; then
        preview_macos_category "$KEYBOARD_CONFIG" "" keyboard || return 2
    fi
    if blueprint_category_enabled macos-trackpad; then
        preview_macos_category "$TRACKPAD_CONFIG" "" trackpad || return 2
    fi
    if blueprint_category_enabled macos-screenshots; then
        preview_screenshots_settings || return 2
    fi
    return 0
}

# ==========================================
# Check macOS Settings
# ==========================================

check_macos_settings() {

    local settings_result=0
    local category_result

    if blueprint_category_enabled macos-finder; then
        check_finder
        category_result=$?
        case $category_result in
            0) ;;
            1) settings_result=1 ;;
            *) return 2 ;;
        esac
    fi

    if blueprint_category_enabled macos-dock; then
        check_dock
        category_result=$?
        case $category_result in
            0) ;;
            1) settings_result=1 ;;
            *) return 2 ;;
        esac
    fi

    if blueprint_category_enabled macos-windows; then
        check_windows
        category_result=$?
        case $category_result in
            0) ;;
            1) settings_result=1 ;;
            *) return 2 ;;
        esac
    fi

    if blueprint_category_enabled macos-keyboard; then
        check_keyboard
        category_result=$?
        case $category_result in
            0) ;;
            1) settings_result=1 ;;
            *) return 2 ;;
        esac
    fi

    if blueprint_category_enabled macos-trackpad; then
        check_trackpad
        category_result=$?
        case $category_result in
            0) ;;
            1) settings_result=1 ;;
            *) return 2 ;;
        esac
    fi

    if blueprint_category_enabled macos-screenshots; then
        check_screenshots
        category_result=$?
        case $category_result in
            0) ;;
            1) settings_result=1 ;;
            *) return 2 ;;
        esac
    fi

    return "$settings_result"

}

# ==========================================
# Apply macOS Settings
# ==========================================

apply_macos_settings() {

    run_configuration \
        "macOS Settings" \
        check_macos_settings \
        apply_macos_components

}

# ==========================================
# Apply macOS Components
# ==========================================

apply_macos_components() {

    local apply_result=0
    local category_result

    if blueprint_category_enabled macos-finder; then
        check_finder
        category_result=$?

        case $category_result in
            0) ;;
            1)
                apply_finder_settings || apply_result=2
                ;;
            *) apply_result=2 ;;
        esac
    fi

    if blueprint_category_enabled macos-dock; then
        check_dock
        category_result=$?

        case $category_result in
            0) ;;
            1)
                apply_dock_settings || apply_result=2
                ;;
            *) apply_result=2 ;;
        esac
    fi

    if blueprint_category_enabled macos-windows; then
        check_windows
        category_result=$?

        case $category_result in
            0) ;;
            1)
                apply_windows_settings || apply_result=2
                ;;
            *) apply_result=2 ;;
        esac
    fi

    if blueprint_category_enabled macos-keyboard; then
        check_keyboard
        category_result=$?

        case $category_result in
            0) ;;
            1)
                apply_keyboard_settings || apply_result=2
                ;;
            *) apply_result=2 ;;
        esac
    fi

    if blueprint_category_enabled macos-trackpad; then
        check_trackpad
        category_result=$?

        case $category_result in
            0) ;;
            1)
                apply_trackpad_settings || apply_result=2
                ;;
            *) apply_result=2 ;;
        esac
    fi

    if blueprint_category_enabled macos-screenshots; then
        check_screenshots
        category_result=$?

        case $category_result in
            0) ;;
            1)
                apply_screenshots_settings || apply_result=2
                ;;
            *) apply_result=2 ;;
        esac
    fi

    [[ $apply_result -ne 2 ]] || return 2

    return 0

}
