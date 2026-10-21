#!/bin/bash

# ==========================================
# Configure bs Launcher
# ==========================================

launcher_failure_record() {
    declare -F verification_application_operation_hook >/dev/null &&
        verification_application_operation_hook launcher scope restore failure "$1"
    return 0
}

configure_bs_launcher() {
    local installer_path="scripts/install-bs.sh"
    local check_output install_output verify_output
    local check_result install_result verify_result

    check_output="$("$installer_path" --check 2>&1)"
    check_result=$?

    case $check_result in
        0)
            success "bs launcher already configured"
            return 0
            ;;
        1)
            if [[ "${BUNDLE_RESTORE_ACTIVE:-false}" == true ]] &&
               ! command -v brew >/dev/null 2>&1; then
                warning "Optional bs launcher deferred: Homebrew is unavailable; use ./bootstrap.sh from the repository root"
                return 1
            fi
            ;;
        *)
            if [[ $check_result -eq 2 ]]; then
                launcher_failure_record launcher_destination_conflict
            else
                launcher_failure_record launcher_inspection_failed
            fi
            error "${check_output:-Failed to inspect bs launcher}"
            return 2
            ;;
    esac

    action "Installing bs launcher"
    install_output="$("$installer_path" 2>&1)"
    install_result=$?
    if [[ $install_result -ne 0 ]]; then
        launcher_failure_record launcher_install_failed
        error "${install_output:-Failed to install bs launcher}"
        return 2
    fi

    verify_output="$("$installer_path" --check 2>&1)"
    verify_result=$?
    if [[ $verify_result -ne 0 ]]; then
        launcher_failure_record launcher_verification_failed
        error "${verify_output:-Failed to verify bs launcher}"
        return 2
    fi

    # Shared lifecycle flag is read by the calling module wrapper.
    # shellcheck disable=SC2034
    MODULE_CHANGED=true
    success "bs launcher installed and verified"
    return 0
}
