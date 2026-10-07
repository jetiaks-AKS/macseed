#!/bin/bash

# ==========================================
# Toolkit Statistics
# ==========================================

MODULES_CHECKED=0
INSTALLED_COUNT=0
SKIPPED_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0

# ==========================================
# Module State
# ==========================================

MODULE_CHANGED=false
PREVIEW_HAS_CHANGES=false
PREVIEW_ACTION_COUNT=0

# ==========================================
# Information Message
# ==========================================

info() {

    echo "[INFO] $1"
    log "[INFO] $1"

}

# ==========================================
# Detail Message (Verbose Mode)
# ==========================================

detail() {

    log "[INFO] $1"

    [[ "$VERBOSE" == true ]] || return 0

    echo "[INFO] $1"

}

# ==========================================
# Action Message
# ==========================================

action() {

    echo "[....] $1"
    log "[....] $1"

}

# Record an existing Preview decision without changing inspection status.
preview_action() {
    # Shared state is read by another sourced module.
    # shellcheck disable=SC2034
    PREVIEW_HAS_CHANGES=true
    ((PREVIEW_ACTION_COUNT++))
    action "$1"
}

# ==========================================
# Success Message
# ==========================================

success() {

    echo "[ OK ] $1"
    log "[ OK ] $1"

}

# ==========================================
# Warning Message
# ==========================================

warning() {

    echo "[WARN] $1"
    log "[WARN] $1"

}

# ==========================================
# Error Message
# ==========================================

error() {

    echo "[ERROR] $1"
    log "[ERROR] $1"

}

# ==========================================
# Section Header
# ==========================================

section() {

    echo
    echo "=========================================="
    echo " $1"
    echo "=========================================="

    log ""
    log "=========================================="
    log " $1"
    log "=========================================="

}

# ==========================================
# Run Module
# ==========================================

run_module_body() {

    local module_name="$1"
    local module_function="$2"

    section "$module_name"

    ((MODULES_CHECKED++))

    MODULE_CHANGED=false

    log "[MODULE] START: $module_name"

    $module_function

    local result=$?

    if [[ "$MODULE_CHANGED" == true ]]; then
        ((INSTALLED_COUNT++))
        log "[MODULE] Changed: Yes"
    else
        ((SKIPPED_COUNT++))
        log "[MODULE] Changed: No"
    fi

    case $result in

        0)
            log "[MODULE] RESULT: SUCCESS"
            return 0
            ;;

        1)
            ((WARNING_COUNT++))
            log "[MODULE] RESULT: WARNING"
            return 1
            ;;

        2)
            ((ERROR_COUNT++))
            log "[MODULE] RESULT: ERROR"
            return 2
            ;;

        *)
            ((ERROR_COUNT++))
            log "[MODULE] RESULT: UNKNOWN ($result)"
            return 2
            ;;

    esac

}

# ==========================================
# Run Read-only Inspection
# ==========================================

run_inspection() {

    local inspection_name="$1"
    local inspection_function="$2"
    local previous_actions="$PREVIEW_ACTION_COUNT"

    [[ "${3:-}" == no-heading ]] || section "$inspection_name"
    ((MODULES_CHECKED++))
    log "[MODULE] START: $inspection_name"

    "$inspection_function"
    local result=$?

    if [[ "${PREVIEW_SUMMARY_FILE:-}" != "" && "$MODE" == --dry-run ]]; then
        local planned=false
        [[ "$PREVIEW_ACTION_COUNT" -eq "$previous_actions" ]] || planned=true
        printf '%s\t%s\t%s\n' "$inspection_function" "$result" "$planned" >> "$PREVIEW_SUMMARY_FILE" || {
            ((ERROR_COUNT++))
            return 2
        }
    fi

    case $result in
        0)
            log "[MODULE] RESULT: SUCCESS"
            return 0
            ;;
        1)
            ((WARNING_COUNT++))
            log "[MODULE] RESULT: WARNING"
            return 1
            ;;
        2)
            ((ERROR_COUNT++))
            log "[MODULE] RESULT: ERROR"
            return 2
            ;;
        *)
            ((ERROR_COUNT++))
            log "[MODULE] RESULT: UNKNOWN ($result)"
            return 2
            ;;
    esac

}

# ==========================================
# Run Configuration
# ==========================================

run_configuration_body() {

    local module_name="$1"
    local check_function="$2"
    local apply_function="$3"

    section "$module_name"

    ((MODULES_CHECKED++))

    MODULE_CHANGED=false

    log "[MODULE] START: $module_name"

    local result

    $check_function >/dev/null 2>&1
    result=$?

    case $result in

        0)

            ((SKIPPED_COUNT++))

            log "[MODULE] Changed: No"
            log "[MODULE] RESULT: SUCCESS"

            success "$module_name already configured"

            return 0
            ;;

        1)

            $apply_function
            result=$?

            if [[ $result -ne 0 ]]; then
                if [[ "$MODULE_CHANGED" == true ]]; then
                    ((INSTALLED_COUNT++))
                else
                    ((SKIPPED_COUNT++))
                fi

                log "[MODULE] Changed: $MODULE_CHANGED"
                log "[MODULE] RESULT: ERROR"

                error "$module_name configuration failed"

                ((ERROR_COUNT++))
                return 2
            fi

            $check_function >/dev/null 2>&1
            result=$?

            if [[ $result -eq 0 ]]; then
                if [[ "$MODULE_CHANGED" == true ]]; then
                    ((INSTALLED_COUNT++))
                else
                    ((SKIPPED_COUNT++))
                fi

                log "[MODULE] Changed: $MODULE_CHANGED"
                log "[MODULE] RESULT: SUCCESS"

                success "$module_name configured successfully"

                return 0

            fi

            if [[ "$MODULE_CHANGED" == true ]]; then
                ((INSTALLED_COUNT++))
            else
                ((SKIPPED_COUNT++))
            fi

            log "[MODULE] Changed: $MODULE_CHANGED"
            log "[MODULE] RESULT: ERROR"

            error "$module_name configuration failed"

            ((ERROR_COUNT++))
            return 2
            ;;

        2)

            log "[MODULE] Changed: No"
            log "[MODULE] RESULT: ERROR"

            ((ERROR_COUNT++))
            return 2
            ;;

        *)

            log "[MODULE] Changed: No"
            log "[MODULE] RESULT: UNKNOWN ($result)"

            ((ERROR_COUNT++))
            return 2
            ;;

    esac

}

# ==========================================
# Toolkit Exit Code
# ==========================================

toolkit_exit_code() {

    if [[ $ERROR_COUNT -gt 0 ]]; then
        return 2
    fi

    if [[ $WARNING_COUNT -gt 0 ]]; then
        return 1
    fi

    return 0

}

# ==========================================
# Toolkit Summary
# ==========================================

show_summary() {

    section "Summary"

    if [[ $ERROR_COUNT -gt 0 ]]; then

        case "$MODE" in

            --discover)
                error "Discovery completed with errors"
                ;;

            --bootstrap)
                error "Bootstrap completed with errors"
                ;;

            --check)
                error "System check completed with errors"
                ;;

            --dry-run)
                error "Preview completed with errors"
                ;;
            --compare)
                error "Comparison observation incomplete"
                ;;

        esac

    elif [[ $WARNING_COUNT -gt 0 ]]; then

        case "$MODE" in

            --discover)
                warning "Discovery completed with warnings"
                ;;

            --bootstrap)
                warning "Bootstrap completed with warnings"
                ;;

            --check)
                warning "System check completed with warnings"
                ;;

            --dry-run)
                warning "Preview completed with warnings"
                ;;
            --compare)
                warning "Comparison completed with warnings"
                ;;

        esac

    else

        case "$MODE" in

            --discover)
                success "Discovery completed successfully"
                ;;

            --bootstrap)
                success "Bootstrap completed successfully"
                ;;

            --check)
                success "System check completed successfully"
                ;;

            --dry-run)
                success "Preview completed successfully"
                ;;
            --compare)
                success "Comparison observation completed"
                ;;

        esac

    fi

    echo
    log ""

    echo "------------------------------------------"
    log "------------------------------------------"

    if [[ "$MODE" == "--discover" ]]; then
        echo "Modules Processed : $MODULES_CHECKED"
        echo "Warnings          : $WARNING_COUNT"
        echo "Errors            : $ERROR_COUNT"

        log "Modules Processed : $MODULES_CHECKED"
        log "Warnings          : $WARNING_COUNT"
        log "Errors            : $ERROR_COUNT"
    elif [[ "$MODE" == "--dry-run" || "$MODE" == "--compare" ]]; then
        echo "Modules Inspected : $MODULES_CHECKED"
        echo "Warnings          : $WARNING_COUNT"
        echo "Errors            : $ERROR_COUNT"

        log "Modules Inspected : $MODULES_CHECKED"
        log "Warnings          : $WARNING_COUNT"
        log "Errors            : $ERROR_COUNT"
    elif [[ "$MODE" == "--bootstrap" &&
          "${BLUEPRINT_BOOTSTRAP_SUMMARY:-false}" == true ]] &&
       blueprint_exists &&
       command -v blueprint_show_bootstrap_summary >/dev/null 2>&1; then
        blueprint_show_bootstrap_summary
    else
        echo "Modules Checked : $MODULES_CHECKED"
        echo "Installed       : $INSTALLED_COUNT"
        echo "Skipped         : $SKIPPED_COUNT"
        echo "Warnings        : $WARNING_COUNT"
        echo "Errors          : $ERROR_COUNT"

        log "Modules Checked : $MODULES_CHECKED"
        log "Installed       : $INSTALLED_COUNT"
        log "Skipped         : $SKIPPED_COUNT"
        log "Warnings        : $WARNING_COUNT"
        log "Errors          : $ERROR_COUNT"
    fi

    if [[ -n "$START_TIME" ]]; then

        local end_time
        local duration

        end_time=$(date +%s)
        duration=$((end_time - START_TIME))

        echo "------------------------------------------"
        log "------------------------------------------"

        echo "Duration        : ${duration}s"
        log "Duration        : ${duration}s"

    fi

}

# Private machine projection emitted at production Preview decision points.
# Values, commands and diagnostics are deliberately not accepted by this API.
preview_record() {
    [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
       "${MODE:-}" == --dry-run && -n "${PREVIEW_PLAN_FILE:-}" ]] || return 0
    local field
    for field in "$@"; do
        [[ "$field" != *$'\t'* && "$field" != *$'\n'* && "$field" != *$'\r'* ]] || return 2
    done
    if [[ -n "${6:-}" ]]; then
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-none}" "$6" >> "$PREVIEW_PLAN_FILE"
    else
        printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-none}" >> "$PREVIEW_PLAN_FILE"
    fi
}

# Application-only records; no CLI/log output is interpreted by this channel.
application_record() {
    [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
       "${MACSEED_REPORT_FD:-}" =~ ^[0-9]+$ ]] || return 0
    MACSEED_REPORT_COUNT=$((${MACSEED_REPORT_COUNT:-0} + 1))
    if [[ "$MACSEED_REPORT_COUNT" -gt 8193 ]]; then return 0; fi
    if [[ "$MACSEED_REPORT_COUNT" -eq 8193 ]]; then set -- truncated; fi
    if [[ "${MACSEED_REPORT_INVALID:-false}" == true && "$1" == complete ]]; then set -- reporting_failed; fi
    printf '%s\0' "$@" | python3 modules/core/application-interface/reporting.py \
        1>&"$MACSEED_REPORT_FD" 2>/dev/null || MACSEED_REPORT_INVALID=true
    return 0
}

run_module() {
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
          -f "${MACSEED_ITEM_STATE_DIR:-}/external-tool-active.json" ]]; then
        error "External lifecycle consequences are unknown; further mutation is blocked"
        return 2
    fi
    application_module_record "$2" started '' false
    run_module_body "$@"
    local status=$?
    application_module_record "$2" finished "$status" "$MODULE_CHANGED"
    return "$status"
}

run_configuration() {
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
          -f "${MACSEED_ITEM_STATE_DIR:-}/external-tool-active.json" ]]; then
        return 2
    fi
    application_module_record "$2" started '' false
    run_configuration_body "$@"
    local status=$?
    application_module_record "$2" finished "$status" "$MODULE_CHANGED"
    return "$status"
}

application_module_record() {
    [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
       "${MACSEED_REPORT_FD:-}" =~ ^[0-9]+$ ]] || return 0
    case "$1" in
        install_brew_packages) bootstrap_item_scope_selected homebrew-packages || return 0 ;;
        install_brew_casks) bootstrap_item_scope_selected homebrew-casks || return 0 ;;
        install_appstore_apps) bootstrap_item_scope_selected app-store || return 0 ;;
        install_vscode_extensions) bootstrap_item_scope_selected vscode-extensions || return 0 ;;
        bootstrap_workspace)
            bootstrap_item_scope_selected workspace-folders || bootstrap_item_scope_selected git-repositories || return 0 ;;
        configure_git) blueprint_category_enabled git-configuration && git_configuration_scope_selected || return 0 ;;
        apply_vscode_settings) blueprint_category_enabled vscode-settings || return 0 ;;
        bootstrap_zsh) blueprint_category_enabled shell-zsh || return 0 ;;
        bootstrap_ssh_configuration|bundle_restore_prerequisites)
            blueprint_category_enabled ssh-configuration || [[ -n "${BUNDLE_RESTORE_SECURE_FILE:-}" ]] || return 0 ;;
        check_finder|check_dock|check_windows|check_keyboard|check_trackpad|check_screenshots)
            blueprint_category_enabled "macos-${1#check_}" || return 0 ;;
    esac
    application_record module "$@"
}
