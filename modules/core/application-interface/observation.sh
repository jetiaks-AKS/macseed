#!/bin/bash

# Explicit read sites only. Never wraps mutation commands or ordinary CLI.
application_observe() {
    local budget="$1"
    shift
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        python3 -B modules/core/application-interface/observation.py "$budget" "$@"
    else
        "$@"
    fi
}
