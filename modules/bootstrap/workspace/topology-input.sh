#!/bin/bash

# Read sectional metadata through the production validator and Config Engine.
# This bridge has no workflow, observation, publication or Apply entry point.
set -eu
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cd "$root"
source modules/core/config/config.sh
source modules/discovery/workspace.sh

[[ $# -eq 2 ]] || exit 2
case "$2" in topology|select) ;; *) exit 2 ;; esac
workspace_validate_repositories "$1" topology || exit 2
sections="$(config_sections "$1")" || exit 2
selected=''
[[ "$2" != select ]] || selected="$(cat)"
while IFS= read -r section; do
    [[ -n "$section" && "$section" != *[[:cntrl:]]* && "$section" != *\ * &&
       "$section" != *\\* ]] || exit 2
    if [[ "$2" == select ]]; then
        grep -Fxq -- "$section" <<< "$selected" || continue
        printf '[%s]\n' "$section"
        for key in NAME PATH REMOTE DEFAULT_BRANCH CURRENT_BRANCH HAS_UNCOMMITTED_CHANGES \
            HAS_VSCODE_FOLDER HAS_SETTINGS HAS_TASKS HAS_LAUNCH HAS_EXTENSIONS TOPOLOGY_VERSION; do
            value="$(config_get "$1" "$section" "$key")" || exit 2
            printf '%s="%s"\n' "$key" "$value"
        done
        printf '\n'
        continue
    fi
    printf '%s\0' "$section"
    for key in NAME PATH REMOTE CURRENT_BRANCH DEFAULT_BRANCH TOPOLOGY_VERSION; do
        value="$(config_get "$1" "$section" "$key")" || exit 2
        printf '%s\0' "$value"
    done
done <<< "$sections"
