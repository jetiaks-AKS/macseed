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

    local inventory tool_provenance
    tool_provenance="$(homebrew_adapter_capture_provenance)" || {
        error "Failed to observe Homebrew provenance"
        return 2
    }
    if ! inventory="$(brew list --formula --installed-on-request)"; then
        error "Failed to inventory Homebrew Formulae"
        return 2
    fi

    if ! discovery_publish_file "$output_file" serialize_brew_inventory "$inventory"; then
        error "Failed to publish Homebrew Formulae"
        return 2
    fi

    discovery_publish_file "${BLUEPRINT_GENERATED_DIR:-config/generated}/provenance/homebrew.json" \
        serialize_brew_inventory "$tool_provenance" || return 2

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

    local inventory metadata capabilities prefix
    if ! inventory="$(brew list --cask)"; then
        error "Failed to inventory Homebrew Casks"
        return 2
    fi

    metadata="$(HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --installed --cask)" || return 2
    prefix="$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix)" || return 2
    capabilities="$(python3 -B modules/apps/adapters/homebrew_cask.py "$prefix" --capture <<< "$metadata")" || return 2
    jq -e --arg inventory "$inventory" '(.casks | keys | sort) ==
        ($inventory | split("\n") | map(select(length > 0)) | sort)' <<< "$capabilities" >/dev/null || return 2

    if ! discovery_publish_file "$output_file" serialize_brew_inventory "$inventory"; then
        error "Failed to publish Homebrew Casks"
        return 2
    fi
    discovery_publish_file "${BLUEPRINT_GENERATED_DIR:-config/generated}/homebrew-casks.json" \
        serialize_brew_inventory "$capabilities" || return 2

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
