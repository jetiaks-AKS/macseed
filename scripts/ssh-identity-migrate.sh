#!/bin/bash
set -u
SCRIPT_ROOT="$(
    if [[ $# -eq 11 && "$8" == --application-channel-fd && "$9" =~ ^[0-9]+$ && "$9" -gt 2 ]]; then
        eval "exec ${9}<&-"
    fi
    if [[ $# -eq 9 && "$6" == --application-channel-fd && "$7" =~ ^[0-9]+$ && "$7" -gt 2 ]]; then
        eval "exec ${7}<&-"
    fi
    cd "$(dirname "$0")/.." && pwd
)" || exit 2
source "$SCRIPT_ROOT/modules/migration/ssh-identities.sh"
migration_main "$@"
