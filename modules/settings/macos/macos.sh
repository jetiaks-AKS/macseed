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
    local result=0
    if blueprint_category_enabled macos-finder; then
        preview_macos_category "$FINDER_CONFIG" Finder finder || result=2
    fi
    if blueprint_category_enabled macos-dock; then
        preview_macos_category "$DOCK_CONFIG" Dock dock || result=2
    fi
    if blueprint_category_enabled macos-windows; then
        preview_macos_category "$WINDOWS_CONFIG" "" windows || result=2
    fi
    if blueprint_category_enabled macos-keyboard; then
        preview_macos_category "$KEYBOARD_CONFIG" "" keyboard || result=2
    fi
    if blueprint_category_enabled macos-trackpad; then
        preview_macos_category "$TRACKPAD_CONFIG" "" trackpad || result=2
    fi
    if blueprint_category_enabled macos-screenshots; then
        preview_screenshots_settings || result=2
    fi
    return "$result"
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

validate_macos_settings_inputs() {
    if blueprint_category_enabled macos-finder; then
        validate_defaults_config "$FINDER_CONFIG" finder || return 2
    fi
    if blueprint_category_enabled macos-dock; then
        validate_defaults_config "$DOCK_CONFIG" dock || return 2
    fi
    if blueprint_category_enabled macos-windows; then
        validate_defaults_config "$WINDOWS_CONFIG" windows || return 2
    fi
    if blueprint_category_enabled macos-keyboard; then
        validate_defaults_config "$KEYBOARD_CONFIG" keyboard || return 2
    fi
    if blueprint_category_enabled macos-trackpad; then
        validate_defaults_config "$TRACKPAD_CONFIG" trackpad || return 2
    fi
    if blueprint_category_enabled macos-screenshots; then
        validate_screenshots_config || return 2
    fi
    return 0
}

macos_settings_checkpoint() {
    if declare -F application_stop_checkpoint >/dev/null; then
        application_stop_checkpoint "$1"
    fi
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
          -f "${MACSEED_ITEM_STATE_DIR:-}/external-tool-active.json" ]]; then
        error "External lifecycle consequences are unknown; further mutation is blocked"
        return 2
    fi
    return 0
}

apply_macos_restore_components() {
    # Validate the complete selected input before any category may mutate.
    # Category-local observation/Apply failures remain owned by the dispatcher.
    validate_macos_settings_inputs || return 2
    apply_macos_components
    local result=$?
    macos_settings_checkpoint "$result" || return 2
    return "$result"
}

apply_macos_settings() {

    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
          "${BUNDLE_RESTORE_ACTIVE:-false}" == true ]]; then
        run_module "macOS Settings" apply_macos_restore_components
        return $?
    fi

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

    macos_settings_checkpoint "$apply_result" || return 2
    if blueprint_category_enabled macos-finder; then
        check_finder
        category_result=$?

        case $category_result in
            0) ;;
            1)
                if apply_finder_settings; then
                    category_result=0
                else
                    category_result=$?
                    apply_result=2
                fi
                ;;
            *) apply_result=2 ;;
        esac
        if [[ $category_result -ne 0 ]] && declare -F application_module_record >/dev/null; then
            application_module_record check_finder finished 2 "$MODULE_CHANGED"
        fi
    fi

    macos_settings_checkpoint "$apply_result" || return 2
    if blueprint_category_enabled macos-dock; then
        check_dock
        category_result=$?

        case $category_result in
            0) ;;
            1)
                if apply_dock_settings; then
                    category_result=0
                else
                    category_result=$?
                    apply_result=2
                fi
                ;;
            *) apply_result=2 ;;
        esac
        if [[ $category_result -ne 0 ]] && declare -F application_module_record >/dev/null; then
            application_module_record check_dock finished 2 "$MODULE_CHANGED"
        fi
    fi

    macos_settings_checkpoint "$apply_result" || return 2
    if blueprint_category_enabled macos-windows; then
        check_windows
        category_result=$?

        case $category_result in
            0) ;;
            1)
                if apply_windows_settings; then
                    category_result=0
                else
                    category_result=$?
                    apply_result=2
                fi
                ;;
            *) apply_result=2 ;;
        esac
        if [[ $category_result -ne 0 ]] && declare -F application_module_record >/dev/null; then
            application_module_record check_windows finished 2 "$MODULE_CHANGED"
        fi
    fi

    macos_settings_checkpoint "$apply_result" || return 2
    if blueprint_category_enabled macos-keyboard; then
        check_keyboard
        category_result=$?

        case $category_result in
            0) ;;
            1)
                if apply_keyboard_settings; then
                    category_result=0
                else
                    category_result=$?
                    apply_result=2
                fi
                ;;
            *) apply_result=2 ;;
        esac
        if [[ $category_result -ne 0 ]] && declare -F application_module_record >/dev/null; then
            application_module_record check_keyboard finished 2 "$MODULE_CHANGED"
        fi
    fi

    macos_settings_checkpoint "$apply_result" || return 2
    if blueprint_category_enabled macos-trackpad; then
        check_trackpad
        category_result=$?

        case $category_result in
            0) ;;
            1)
                if apply_trackpad_settings; then
                    category_result=0
                else
                    category_result=$?
                    apply_result=2
                fi
                ;;
            *) apply_result=2 ;;
        esac
        if [[ $category_result -ne 0 ]] && declare -F application_module_record >/dev/null; then
            application_module_record check_trackpad finished 2 "$MODULE_CHANGED"
        fi
    fi

    macos_settings_checkpoint "$apply_result" || return 2
    if blueprint_category_enabled macos-screenshots; then
        check_screenshots
        category_result=$?

        case $category_result in
            0) ;;
            1)
                if apply_screenshots_settings; then
                    category_result=0
                else
                    category_result=$?
                    apply_result=2
                fi
                ;;
            *) apply_result=2 ;;
        esac
        if [[ $category_result -ne 0 ]] && declare -F application_module_record >/dev/null; then
            application_module_record check_screenshots finished 2 "$MODULE_CHANGED"
        fi
    fi

    [[ $apply_result -ne 2 ]] || return 2

    return 0

}
