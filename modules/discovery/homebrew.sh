#!/bin/bash

# ==========================================
# Homebrew Discovery
# ==========================================

serialize_brew_inventory() {

    local output_file="$1"
    local inventory="$2"
    local entry

    while IFS= read -r entry; do

        [[ -z "$entry" ]] && continue

        printf '%s\n' "$entry" >> "$output_file" || return 2

    done <<< "$inventory"

    return 0

}

# ==========================================

export_brew_packages() {

    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/brew-packages.conf"

    action "Exporting Homebrew Formulae..."

    local inventory
    if ! inventory="$(brew list --formula --installed-on-request)"; then
        error "Failed to inventory Homebrew Formulae"
        return 2
    fi

    if ! discovery_publish_file "$output_file" serialize_brew_inventory "$inventory"; then
        error "Failed to publish Homebrew Formulae"
        return 2
    fi

    local package_count=0

    while IFS= read -r package; do

        [[ -z "$package" ]] && continue

        ((package_count++))

        detail "$package"

    done <<< "$inventory"

    success "$package_count Formulae exported"

}

# ==========================================

export_brew_casks() {

    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/brew-casks.conf"

    action "Exporting Homebrew Casks..."

    local inventory
    if ! inventory="$(brew list --cask)"; then
        error "Failed to inventory Homebrew Casks"
        return 2
    fi

    if ! discovery_publish_file "$output_file" serialize_brew_inventory "$inventory"; then
        error "Failed to publish Homebrew Casks"
        return 2
    fi

    provenance_publish homebrew-casks || return 2

    local cask_count=0

    while IFS= read -r cask; do

        [[ -z "$cask" ]] && continue

        ((cask_count++))

        detail "$cask"

    done <<< "$inventory"

    success "$cask_count Casks exported"

}

# ==========================================

discover_homebrew() {

    homebrew_availability
    case $? in
        0) ;;
        1)
            error "Homebrew is not installed"
            return 2
            ;;
        *)
            error "Failed to inspect Homebrew availability"
            return 2
            ;;
    esac

    export_brew_packages || return 2

    echo

    export_brew_casks || return 2

    echo

    success "Homebrew Discovery completed"

    return 0

}
