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
    if ! folders="$(workspace_read_bootstrap_folders "$config_file")"; then
        error "Workspace folders configuration is missing, unreadable, or not actionable"
        return 2
    fi

    while IFS= read -r folder; do
        [[ -n "$folder" ]] || continue

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

        first_missing_path="$(workspace_folder_first_missing_path "$folder")" || {
            error "Failed to determine workspace folder mutation: $folder"
            return 2
        }

        action "Creating: $folder"

        if ! mkdir -p "$target"; then
            [[ ! -d "$first_missing_path" ]] || MODULE_CHANGED=true
            error "Failed to create workspace folder: $folder"
            return 2
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

    success "Workspace configuration loaded"

    return 0

}

verify_workspace_folders() {
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
