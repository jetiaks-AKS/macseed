#!/bin/bash

# ==========================================
# Workspace Inventory
# ==========================================

export_workspace_inventory() {

    local output_file="$1"
    local folders_file="$2"
    local repositories_file="$3"

    action "Generating Workspace Inventory..."

    if [[ ! -f "$folders_file" || ! -r "$folders_file" ||
          ! -f "$repositories_file" || ! -r "$repositories_file" ]]; then
        error "Workspace inventory prerequisites are unavailable"
        return 2
    fi

    if ! workspace_validate_folders "$folders_file" ||
       ! workspace_validate_repositories "$repositories_file" "${4:-legacy}"; then
        error "Workspace inventory prerequisites are malformed"
        return 2
    fi

    local total=0
    local workspace=0
    local user=0
    local system=0
    local repositories=0

    while IFS="|" read -r folder type; do

        [[ -z "$folder" ]] && continue

        ((total++))

        case "$type" in

            workspace)
                ((workspace++))
                ;;

            user)
                ((user++))
                ;;

            system)
                ((system++))
                ;;

            *)
                error "Malformed Workspace folder record: $folder"
                return 2
                ;;

        esac

    done < "$folders_file"

    repositories="$(grep -c '^\[[^]]*\]$' "$repositories_file")"
    local count_result=$?
    [[ $count_result -le 1 ]] || {
        error "Failed to read Workspace repository inventory"
        return 2
    }

    if ! cat > "$output_file" <<EOF
TOTAL_FOLDERS=$total
WORKSPACE_FOLDERS=$workspace
USER_FOLDERS=$user
SYSTEM_FOLDERS=$system
TOTAL_REPOSITORIES=$repositories
EOF
    then
        error "Failed to serialize Workspace Inventory"
        return 2
    fi

    if [[ -f "${output_file%/*}/inventory.extra" ]]; then
        cat "${output_file%/*}/inventory.extra" >> "$output_file" || return 2
    fi

    if [[ "$VERBOSE" == true ]]; then

        detail "Total folders: $total"
        detail "Workspace folders: $workspace"
        detail "User folders: $user"
        detail "System folders: $system"
        detail "Git repositories: $repositories"

    fi

    return 0

}
