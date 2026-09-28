#!/bin/bash

# ==========================================
# Check Homebrew
# ==========================================

homebrew_availability() {

    command -v brew >/dev/null 2>&1

    case $? in
        0) return 0 ;; # Present.
        1) return 1 ;; # Absent.
        *) return 2 ;; # The availability check itself failed.
    esac

}

is_homebrew_installed() {

    homebrew_availability

}

# The installer runs in a child shell; activate its prefix in this process.
homebrew_activate_installed() {
    local prefix observed
    case "$(uname -m)" in
        arm64) prefix=/opt/homebrew ;;
        x86_64) prefix=/usr/local ;;
        *) return 2 ;;
    esac
    [[ -f "$prefix/bin/brew" && -x "$prefix/bin/brew" ]] || return 2
    observed="$("$prefix/bin/brew" --prefix)" || return 2
    [[ "$observed" == "$prefix" ]] || return 2
    export PATH="$prefix/bin:$prefix/sbin:$PATH"
    hash -r
}

check_homebrew_read_only() {

    homebrew_availability
    local availability_result=$?

    case $availability_result in
        0)
            success "Homebrew already installed"
            return 0
            ;;
        1)
            warning "Homebrew is not installed"
            return 1
            ;;
        *)
            error "Failed to inspect Homebrew availability"
            return 2
            ;;
    esac

}

# ==========================================
# Install Homebrew
# ==========================================

install_homebrew() {

    info "Installing Homebrew..."

    local installer
    installer="$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" || return 2
    /bin/bash -c "$installer"

}

# ==========================================
# Module Check
# ==========================================

check_homebrew() {

    homebrew_availability
    local availability_result=$?

    if [[ $availability_result -eq 0 ]]; then
        success "Homebrew already installed"
        return 0
    fi

    if [[ $availability_result -ne 1 ]]; then
        error "Failed to inspect Homebrew availability"
        return 2
    fi

    warning "Homebrew is not installed"

    read -r -p "Install Homebrew? (y/n): " answer

    if [[ "$answer" != "y" ]]; then
        warning "Installation cancelled by user"
        return 1
    fi

    if ! install_homebrew; then
        error "Homebrew installer failed"
        return 2
    fi
    # Shared lifecycle flag is read by the calling module wrapper.
    # shellcheck disable=SC2034
    MODULE_CHANGED=true

    homebrew_availability
    availability_result=$?

    if [[ $availability_result -eq 1 ]]; then
        homebrew_activate_installed || {
            error "Failed to activate installed Homebrew"
            return 2
        }
        homebrew_availability
        availability_result=$?
    fi

    if [[ $availability_result -eq 0 ]]; then
        success "Homebrew installed successfully"
        return 0
    fi

    if [[ $availability_result -ne 1 ]]; then
        error "Failed to inspect Homebrew availability after installation"
        return 2
    fi

    error "Failed to install Homebrew"
    return 2

}
