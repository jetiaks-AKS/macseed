#!/bin/bash

# ==========================================
# Workspace Folders Bootstrap
# ==========================================

# Folder state: 0 usable directory, 1 absent, 2 observation error.
workspace_folder_state() {

    local folder="$1"
    local target="$HOME/$folder"

    workspace_bootstrap_path_valid "$folder" || return 2

    if [[ ! -e "$target" && ! -L "$target" ]]; then
        return 1
    fi

    [[ -d "$target" && -r "$target" && -x "$target" ]] || return 2
    return 0

}

workspace_folder_first_missing_path() {

    local folder="$1"
    local component
    local current="$HOME"

    while [[ -n "$folder" ]]; do
        component="${folder%%/*}"
        current="$current/$component"
        if [[ ! -e "$current" && ! -L "$current" ]]; then
            printf '%s\n' "$current"
            return 0
        fi
        [[ "$folder" == */* ]] || break
        folder="${folder#*/}"
    done

    return 1

}

# Resolve an existing ancestor, retaining the validated missing path components.
workspace_folder_physical_path() {
    workspace_bootstrap_path_valid "$1" || return 2
    local ancestor="$HOME/$1" suffix="" physical
    while [[ ! -e "$ancestor" && ! -L "$ancestor" ]]; do
        suffix="/${ancestor##*/}$suffix"
        ancestor="${ancestor%/*}"
    done
    physical="$(cd "$ancestor" && pwd -P)" || return 2
    printf '%s%s\n' "$physical" "$suffix"
}

# Component boundaries matter; conservatively include case aliases on macOS.
# Keep the shell option local to this comparison.
workspace_folder_paths_related() (
    shopt -s nocasematch
    [[ "$1" == "$2" || "$1" == "$2"/* || "$2" == "$1"/* ]]
)

# ==========================================
# Workspace Folders Preview
# ==========================================

preview_workspace_folders() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items workspace-folders)" ]]; then
        return 0
    fi

    local config_file
    config_file="$(blueprint_generated_file workspace-folders)"

    local folders folder inspection_result
    if ! folders="$(workspace_read_bootstrap_folders "$config_file")"; then
        error "Workspace folders configuration is missing, unreadable, or not actionable"
        return 2
    fi

    while IFS= read -r folder; do
        [[ -n "$folder" ]] || continue

        workspace_folder_state "$folder"
        inspection_result=$?
        case $inspection_result in
            0) preview_record workspace-folders "$folder" none satisfied ;;
            1) preview_record workspace-folders "$folder" create_directory planned ;;
            *) preview_record workspace-folders "$folder" create_directory blocked target_conflict ;;
        esac

        case $inspection_result in
            0)
                detail "$folder already exists"
                ;;
            1)
                preview_action "Would create workspace folder: $HOME/$folder"
                ;;
            *)
                error "Failed to inspect workspace folder: $folder"
                return 2
                ;;
        esac
    done <<< "$folders"

    return 0
}

bootstrap_workspace_folders() {

    if blueprint_exists &&
       [[ -z "$(blueprint_selected_items workspace-folders)" ]]; then
        success "No Workspace folders selected by Blueprint"
        return 0
    fi

    action "Creating Workspace folders..."

    local config_file
    config_file="$(blueprint_generated_file workspace-folders)"

    local folders folder target first_missing_path inspection_result
    local folders_result=0 physical_path checked_physical_path failed_path related
    local failed_paths=()
    if ! folders="$(workspace_read_bootstrap_folders "$config_file")"; then
        error "Workspace folders configuration is missing, unreadable, or not actionable"
        return 2
    fi

    while IFS= read -r folder; do
        [[ -n "$folder" ]] || continue
        if declare -F application_stop_checkpoint >/dev/null; then application_stop_checkpoint "$folders_result"; fi
        if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
              -f "${MACSEED_ITEM_STATE_DIR:-}/external-tool-active.json" ]]; then
            error "External lifecycle consequences are unknown; further mutation is blocked"
            return 2
        fi

        target="$HOME/$folder"
        workspace_folder_state "$folder"
        inspection_result=$?

        if [[ $inspection_result -eq 0 ]]; then
            detail "$folder already exists"
            continue
        fi

        if [[ $inspection_result -ne 1 ]]; then
            error "Failed to inspect workspace folder: $folder"
            return 2
        fi

        physical_path="$(workspace_folder_physical_path "$folder")" || {
            error "Failed to resolve workspace folder safely: $folder"
            return 2
        }
        related=false
        for failed_path in "${failed_paths[@]:-}"; do
            [[ -n "$failed_path" ]] || continue
            if workspace_folder_paths_related "$target" "$failed_path" ||
               workspace_folder_paths_related "$physical_path" "$failed_path"; then
                related=true
                break
            fi
        done
        if [[ "$related" == true ]]; then
            error "Skipping workspace folder after related creation failure: $folder"
            continue
        fi

        first_missing_path="$(workspace_folder_first_missing_path "$folder")" || {
            error "Failed to determine workspace folder mutation: $folder"
            return 2
        }

        action "Creating: $folder"

        if ! mkdir -p "$target"; then
            [[ ! -d "$first_missing_path" ]] || MODULE_CHANGED=true
            error "Failed to create workspace folder: $folder"
            folders_result=2
            # A synchronous mkdir failure is local only while its retained state
            # remains observable and its validated physical destination is stable.
            workspace_folder_state "$folder"
            inspection_result=$?
            if [[ $inspection_result -ne 0 && $inspection_result -ne 1 ]]; then
                error "Workspace folder state is uncertain after failed creation: $folder"
                return 2
            fi
            checked_physical_path="$(workspace_folder_physical_path "$folder")" || {
                error "Failed to resolve workspace folder after failed creation: $folder"
                return 2
            }
            if [[ "$checked_physical_path" != "$physical_path" ]]; then
                error "Workspace folder destination changed during creation: $folder"
                return 2
            fi
            failed_paths+=("$target" "$physical_path")
            continue
        fi

        # Shared lifecycle flag is read by the calling module wrapper.
        # shellcheck disable=SC2034
        MODULE_CHANGED=true

        if ! workspace_folder_state "$folder"; then
            error "Failed to verify workspace folder: $folder"
            return 2
        fi

        success "Workspace folder created: $folder"

    done <<< "$folders"

    if [[ $folders_result -ne 0 ]]; then
        error "Workspace folders completed with errors"
        return 2
    fi

    success "Workspace configuration loaded"

    return 0

}

verify_workspace_folders() {
    [[ -z "${MACSEED_WORKSPACE_CONTEXT:-}" ]] || return 0
    verification_items_selected workspace-folders || return 0
    local records folder result
    records="$(workspace_read_bootstrap_folders "$(blueprint_generated_file workspace-folders)")" || {
        verification_input_error workspace-folders; return 0;
    }
    verification_select_subjects workspace-folders "$records" || return 2
    for folder in "${GV_SUBJECTS[@]}"; do
        workspace_folder_state "$folder"
        result=$?
        local kind=unknown
        if [[ $result -eq 1 ]]; then kind=absent
        elif [[ "${CV_ACTIVE:-false}" == true && $result -eq 2 &&
                -f "$HOME/$folder" && ! -L "$HOME/$folder" ]]; then
            result=1 kind=different
        fi
        verification_result workspace-folders "$folder" directory "$result" '' "$kind" || return 2
    done
}
