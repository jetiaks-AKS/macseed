#!/bin/bash

# ==========================================
# Workspace Bootstrap
# ==========================================

source modules/bootstrap/workspace/validation.sh
source modules/bootstrap/workspace/folders.sh
source modules/bootstrap/workspace/repositories-helpers.sh
source modules/bootstrap/workspace/repositories.sh

# ==========================================
# Validate Workspace Bootstrap Input
# ==========================================

workspace_validate_bootstrap_inputs() {

    local folders_required=true
    local repositories_required=true
    local config_file

    if blueprint_exists; then
        [[ -n "$(blueprint_selected_items workspace-folders)" ]] || folders_required=false
        [[ -n "$(blueprint_selected_items git-repositories)" ]] || repositories_required=false
    fi

    if [[ "$folders_required" == true ]]; then
        config_file="$(blueprint_generated_file workspace-folders)" || return 2

        if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
            error "Workspace folders configuration not found or unreadable"
            return 2
        fi

        if ! workspace_read_bootstrap_folders "$config_file" >/dev/null; then
            error "Workspace folders configuration is malformed"
            return 2
        fi
    fi

    if [[ "$repositories_required" == true ]]; then
        config_file="$(blueprint_generated_file git-repositories)" || return 2

        if [[ ! -f "$config_file" || ! -r "$config_file" ]]; then
            error "Workspace repositories configuration not found or unreadable"
            return 2
        fi

        if ! workspace_read_bootstrap_repositories "$config_file" >/dev/null; then
            error "Workspace repositories configuration is malformed"
            return 2
        fi
    fi

    return 0

}

bootstrap_workspace() {

    local workspace_result=0
    local submodule_result

    if ! workspace_validate_bootstrap_inputs; then
        error "Workspace Bootstrap completed with errors"
        return 2
    fi

    bootstrap_workspace_folders
    submodule_result=$?

    if [[ $submodule_result -eq 2 ]]; then
        error "Workspace Bootstrap completed with errors"
        return 2
    elif [[ $submodule_result -eq 1 && $workspace_result -eq 0 ]]; then
        workspace_result=1
    fi

    echo

    if declare -F application_stop_checkpoint >/dev/null; then application_stop_checkpoint "$workspace_result"; fi
    bootstrap_workspace_repositories
    submodule_result=$?

    if [[ $submodule_result -eq 2 ]]; then
        workspace_result=2
    elif [[ $submodule_result -eq 1 && $workspace_result -eq 0 ]]; then
        workspace_result=1
    fi

    echo

    if [[ $workspace_result -eq 0 ]]; then
        success "Workspace Bootstrap completed"
    elif [[ $workspace_result -eq 1 ]]; then
        warning "Workspace Bootstrap completed with warnings"
    else
        error "Workspace Bootstrap completed with errors"
    fi

    return "$workspace_result"

}
