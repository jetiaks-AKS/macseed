#!/bin/bash

# ==========================================
# VS Code Workspace Discovery
# ==========================================

export_vscode_workspaces() {

    action "Exporting VS Code Workspaces..."

    local output_file="$1"
    local folders_file="$2"
    local working_dir="$3"

    # Topology observation already prepared this member and its bounded sidecar.
    [[ ! -f "$working_dir/inventory.extra" ]] || return 0

    if [[ ! -f "$folders_file" || ! -r "$folders_file" ]]; then
        error "Workspace Folders are unavailable for VS Code Workspace discovery"
        return 2
    fi

    : > "$output_file" || {
        error "Failed to prepare VS Code Workspaces"
        return 2
    }

    local workspace_count=0

    while IFS="|" read -r folder type; do

        [[ "$type" != "workspace" ]] && continue

        local workspace_path="$HOME/$folder"

        [[ ! -d "$workspace_path" ]] && continue

        local workspaces_list="$working_dir/vscode-workspaces.$workspace_count"

        if ! find "$workspace_path" -type f -name "*.code-workspace" \
            > "$workspaces_list" 2>/dev/null; then
            error "Failed to scan VS Code Workspaces in: $folder"
            return 2
        fi

        while IFS= read -r workspace_file; do

            [[ -z "$workspace_file" ]] && continue

            local workspace_name

            if ! workspace_name="$(basename "$workspace_file" .code-workspace)"; then
                error "Failed to identify VS Code Workspace"
                return 2
            fi

            if ! cat >> "$output_file" <<EOF
[$workspace_name]
PATH="$workspace_file"

EOF
            then
                error "Failed to serialize VS Code Workspaces"
                return 2
            fi

            if [[ "$VERBOSE" == true ]]; then

                detail "Workspace: $workspace_name"
                detail "Path: $workspace_file"

            fi

            ((workspace_count++))

        done < "$workspaces_list"

    done < "$folders_file"

    return 0

}
