#!/bin/bash

# ==========================================
# Run Preflight Checks
# ==========================================

run_preflight_checks() {

    section "Preflight Checks"

    check_internet || return 2
    check_xcode || return 2
    check_macos || return 2
    check_admin || return 2

    success "All preflight checks passed"

    return 0

}

# ==========================================
# Run Read-only Preflight Checks
# ==========================================

run_read_only_preflight_checks() {

    section "Preflight Checks"

    check_internet || return 2
    check_xcode || return 2
    check_macos || return 2

    success "All read-only preflight checks passed"

    return 0

}

# ==========================================
# Internet
# ==========================================

check_internet() {

    detail "Checking Internet connection..."

    if curl -fsSI --connect-timeout 5 --max-time 10 \
        https://github.com >/dev/null 2>&1 ||
       curl -fsSI --connect-timeout 5 --max-time 10 \
        https://brew.sh >/dev/null 2>&1; then

        detail "Internet connection available"
        return 0
    fi

    error "Internet connection unavailable"
    return 2
}

# ==========================================
# Xcode Command Line Tools
# ==========================================

check_xcode() {

    detail "Checking Xcode Command Line Tools..."

    if xcode-select -p >/dev/null 2>&1; then

        detail "Xcode Command Line Tools are installed"
        return 0

    fi

    error "Xcode Command Line Tools are not installed"
    return 2

}

# ==========================================
# macOS Version
# ==========================================

check_macos() {

    detail "Checking macOS version..."

    local current_version
    current_version=$(sw_vers -productVersion | cut -d "." -f1)

    if [[ "$current_version" -ge "$MIN_MACOS_VERSION" ]]; then

        detail "macOS version is supported"
        return 0

    fi

    error "Unsupported macOS version"
    return 2

}

# ==========================================
# Administrator Privileges
# ==========================================

check_admin() {

    detail "Checking administrator privileges..."

    if sudo -n true >/dev/null 2>&1; then

        detail "Administrator privileges available"
        return 0

    fi

    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        error "authorization_required: administrator privileges are unavailable non-interactively"
        return 2
    fi

    info "Administrator authentication required..."

    if sudo -v; then

        detail "Administrator privileges granted"
        return 0

    fi

    error "Failed to obtain administrator privileges"
    return 2

}
