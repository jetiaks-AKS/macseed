#!/bin/bash

# Validate a HOME-relative path without resolving nonexistent components.
workspace_bootstrap_path_valid() {
    local relative="$1"
    local component current="$HOME" physical root
    [[ -n "$relative" && "$relative" != /* && "$relative" != */ && "$relative" != *//* ]] || return 2
    [[ "$relative" != *[[:cntrl:]]* ]] || return 2
    root="$(cd "$HOME" && pwd -P)" || return 2
    while [[ -n "$relative" ]]; do
        component="${relative%%/*}"
        [[ "$component" != . && "$component" != .. ]] || return 2
        current="$current/$component"
        if [[ -e "$current" || -L "$current" ]]; then
            if [[ "${2:-}" == observation && "$relative" != */* && -f "$current" && ! -L "$current" ]]; then
                return 0 # A safe leaf conflict is observable, not malformed input.
            fi
            [[ -d "$current" ]] || return 2
            physical="$(cd "$current" && pwd -P)" || return 2
            [[ "$physical" == "$root"/* ]] || return 2
        fi
        [[ "$relative" == */* ]] || break
        relative="${relative#*/}"
    done
}

workspace_read_bootstrap_folders() {
    local config_file="$1" records folder classification
    [[ -f "$config_file" && -r "$config_file" ]] || return 2
    records="$(LC_ALL=C awk -F '|' '
        /^$/ { next }
        /[[:cntrl:]]/ || NF != 2 || $1 == "" ||
        ($2 != "system" && $2 != "user" && $2 != "workspace") { exit 2 }
        { print }
    ' "$config_file")" || return 2
    # Read both fields to preserve the Workspace record format.
    # shellcheck disable=SC2034
    while IFS='|' read -r folder classification; do
        [[ -n "$folder" ]] || continue
        blueprint_item_selected workspace-folders "$folder" || continue
        workspace_bootstrap_path_valid "$folder" || return 2
        printf '%s\n' "$folder"
    done <<< "$records"
}

workspace_read_bootstrap_repositories() {
    local config_file="$1" repositories repository name path remote branch checked_branch
    [[ -f "$config_file" && -r "$config_file" ]] || return 2
    LC_ALL=C awk '/[[:cntrl:]]/ { exit 2 }' "$config_file" || return 2
    workspace_validate_repositories "$config_file" || return 2
    repositories="$(config_sections "$config_file")" || return 2
    while IFS= read -r repository; do
        [[ -n "$repository" ]] || continue
        [[ "$repository" != *[[:cntrl:]]* && "$repository" != *\\* ]] || return 2
        blueprint_item_selected git-repositories "$repository" || continue
        name="$(config_get "$config_file" "$repository" NAME)" || return 2
        path="$(config_get "$config_file" "$repository" PATH)" || return 2
        remote="$(config_get "$config_file" "$repository" REMOTE)" || return 2
        branch="$(config_get "$config_file" "$repository" CURRENT_BRANCH)" || return 2
        [[ -n "$name" && -n "$remote" && -n "$branch" ]] || return 2
        [[ "$name$path$remote$branch" != *[[:cntrl:]]* &&
           "$name$path$remote$branch" != *'"'* ]] || return 2
        [[ "$path" == "$HOME"/* ]] || return 2
        workspace_bootstrap_path_valid "${path#"$HOME"/}" "${2:-}" || return 2
        [[ "$remote" != -* && "$remote" != [[:space:]]* && "$remote" != *[[:space:]] ]] || return 2
        case "$remote" in
            *://*) [[ "${remote#*://}" != "" && "${remote%%://*}" != "" ]] || return 2 ;;
            *:*) [[ "${remote%%:*}" != "" && "${remote#*:}" != "" ]] || return 2 ;;
        esac
        [[ "$branch" != -* ]] || return 2
        checked_branch="$(git check-ref-format --branch "$branch" 2>/dev/null)" || return 2
        [[ "$checked_branch" == "$branch" ]] || return 2
        printf '%s\t%s\t%s\t%s\n' "$repository" "$path" "$remote" "$branch"
    done <<< "$repositories"
}
