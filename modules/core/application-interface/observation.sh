#!/bin/bash

MACSEED_OBSERVATION_DIRECTORY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)" || return 2

# Explicit read sites only. Never wraps mutation commands or ordinary CLI.
application_observe() {
    local budget="$1"
    shift
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        python3 -B "$MACSEED_OBSERVATION_DIRECTORY/observation.py" "$budget" "$@"
    else
        "$@"
    fi
}
