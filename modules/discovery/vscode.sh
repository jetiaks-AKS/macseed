#!/bin/bash

# ==========================================
# VS Code Discovery
# ==========================================

serialize_vscode_extensions() {

    local output_file="$1"
    local inventory="$2"

    [[ -z "$inventory" ]] && return 0

    sort > "$output_file" <<< "$inventory" || return 2

    return 0

}

# ==========================================

serialize_vscode_settings() {

    local output_file="$1"
    local source_file="$2"

    cp "$source_file" "$output_file" 2>/dev/null || return 2

    return 0

}

# ==========================================

export_vscode_extensions() {

    if ! command -v code >/dev/null 2>&1; then

        warning "VS Code CLI not found"
        return 1

    fi

    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/vscode-extensions.conf"

    action "Exporting VS Code Extensions..."

    local inventory
    if ! inventory="$(code --list-extensions)"; then
        error "Failed to inventory VS Code Extensions"
        return 2
    fi

    if ! discovery_publish_file "$output_file" serialize_vscode_extensions "$inventory"; then
        error "Failed to publish VS Code Extensions"
        return 2
    fi

    provenance_publish vscode-extensions || return 2

    local extension_count
    extension_count=$(wc -l < "$output_file" | tr -d ' ')

    if [[ "$VERBOSE" == true ]]; then

        while IFS= read -r extension; do

            [[ -n "$extension" ]] && detail "$extension"

        done < "$output_file"

    fi

    success "$extension_count Extensions exported"

}

# ==========================================

export_vscode_settings() {

    local source_file="$HOME/Library/Application Support/Code/User/settings.json"
    local output_file="${BLUEPRINT_GENERATED_DIR:-config/generated}/vscode/settings.json"

    if [[ ! -e "$source_file" ]]; then

        warning "VS Code settings not found"
        return 1

    fi

    action "Exporting VS Code Settings..."

    if ! discovery_publish_file "$output_file" serialize_vscode_settings "$source_file"; then
        error "Failed to publish VS Code Settings"
        return 2
    fi

    if [[ "$VERBOSE" == true ]]; then

        detail "Source: $source_file"
        detail "Configuration saved to: $output_file"

    fi

    success "VS Code Settings exported"

    return 0

}

# ==========================================

discover_vscode() {

    local discovery_result=0
    local exporter_result

    export_vscode_extensions
    exporter_result=$?

    if [[ $exporter_result -gt $discovery_result ]]; then
        discovery_result=$exporter_result
    fi

    echo

    export_vscode_settings
    exporter_result=$?

    if [[ $exporter_result -gt $discovery_result ]]; then
        discovery_result=$exporter_result
    fi

    echo

    if [[ $discovery_result -eq 0 ]]; then
        success "VS Code Discovery completed"
    elif [[ $discovery_result -eq 1 ]]; then
        warning "VS Code Discovery completed with warnings"
    else
        error "VS Code Discovery completed with errors"
    fi

    return "$discovery_result"

}
