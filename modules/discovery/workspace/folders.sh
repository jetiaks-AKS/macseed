#!/bin/bash

# ==========================================
# Workspace Folders Discovery
# ==========================================

classify_folder() {

    case "$1" in

        Applications|Library|Public)
            echo "system"
            ;;

        Desktop|Documents|Downloads|Movies|Music|Pictures)
            echo "user"
            ;;

        *)
            echo "workspace"
            ;;

    esac

}

# ==========================================
# Export Workspace Folders
# ==========================================

export_workspace_folders() {

    local output_file="$1"

    action "Exporting Workspace Folders..."

    if [[ ! -d "$HOME" || ! -r "$HOME" || ! -x "$HOME" ]]; then
        error "Workspace root is unavailable for folder discovery"
        return 2
    fi

    : > "$output_file" || {
        error "Failed to prepare Workspace Folders"
        return 2
    }

    for folder in "$HOME"/*; do

        [[ ! -d "$folder" || -L "$folder" ]] && continue

        local name
        local type

        if ! name="$(basename "$folder")" ||
           ! type="$(classify_folder "$name")"; then
            error "Failed to classify Workspace folder"
            return 2
        fi

        if ! printf '%s|%s\n' "$name" "$type" >> "$output_file"; then
            error "Failed to serialize Workspace Folders"
            return 2
        fi

        if [[ "$VERBOSE" == true ]]; then
            detail "$name ($type)"
        fi

    done

    return 0

}
