#!/bin/bash

CORE_ROOT="$(
    # The launch descriptor belongs only to Core, not path-resolution children.
    if [[ $# -eq 2 && "$1" == --secure-fd && "$2" =~ ^[0-9]+$ && "$2" -gt 2 ]]; then
        eval "exec ${2}<&-"
    fi
    cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P
)" || exit 2
source "$CORE_ROOT/config/toolkit.conf"

if ! command -v python3 >/dev/null 2>&1; then
    printf 'Macseed Core requires Python 3\n' >&2
    exit 2
fi

exec python3 "$CORE_ROOT/modules/core/application-interface/core.py" "$TOOLKIT_VERSION" "$@"
