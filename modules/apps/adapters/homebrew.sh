#!/bin/bash
# shellcheck disable=SC2034 # Provider fields are consumed by sourcing domain scripts.
# Concrete Homebrew provider. Consumers use normalized state; all metadata,
# lifecycle qualification and native command construction stay here.
[[ "${MACSEED_HOMEBREW_ADAPTER_LOADED:-false}" != true ]] || return 0
MACSEED_HOMEBREW_ADAPTER_LOADED=true

homebrew_adapter_capture_provenance() {
    local version
    version="$(HOMEBREW_NO_AUTO_UPDATE=1 brew --version)" || return 2
    version="${version%%$'\n'*}"
    [[ "$version" == 'Homebrew '* && ${#version} -le 265 ]] || return 2
    python3 -B -c 'import json,sys; print(json.dumps({"homebrew":{"version":sys.argv[1]}}))' "${version#Homebrew }"
}

# Adapter result is JSON, with shell fields for existing production consumers.
# Never cache safety observations. Capabilities may be cached within this process.
homebrew_adapter_probe() {
    local kind="$1" operation="${2:-install}" key="$1:${2:-install}"
    if [[ "${HOMEBREW_ADAPTER_PROBE_KEY:-}" != "$key" ]]; then
        HOMEBREW_ADAPTER_CONTEXT="$(python3 -B modules/apps/adapters/homebrew.py probe "$kind" "$operation")"
        HOMEBREW_ADAPTER_PROBE_STATUS=$?
        HOMEBREW_ADAPTER_PROBE_KEY="$key"
    fi
    HOMEBREW_ADAPTER_CONDITION="$(jq -r '.reason // "ready"' <<< "$HOMEBREW_ADAPTER_CONTEXT")" || return 2
    return "$HOMEBREW_ADAPTER_PROBE_STATUS"
}

homebrew_adapter_result() {
    local context="${HOMEBREW_ADAPTER_CONTEXT:-}"
    [[ -n "$context" ]] || context='{}'
    HOMEBREW_ADAPTER_STATE="$1"
    HOMEBREW_ADAPTER_CONDITION="${3:-ready}"
    HOMEBREW_ADAPTER_OPERATION="${4:-}"
    HOMEBREW_ADAPTER_RESULT="$(python3 -B modules/apps/adapters/homebrew.py result \
        "$1" "$2" "${3:-}" "${4:-}" "$context")"
    # Result classification is data; callers decide whether this item can run.
    [[ -n "$HOMEBREW_ADAPTER_RESULT" ]]
}

homebrew_adapter_failure() {
    case "$1" in
        cask_execution_requirements_unsupported|cask_target_conflict|cask_authorization_required)
            homebrew_adapter_result unsupported item_unsupported "$1" "$2" ;;
        homebrew_capability_unavailable)
            homebrew_adapter_result incompatible capability_unavailable "$1" "$2" ;;
        homebrew_metadata_incompatible)
            homebrew_adapter_result incompatible metadata_incompatible "$1" "$2" ;;
        *) homebrew_adapter_result observation_error observation_failure "$1" "$2" ;;
    esac
}

homebrew_adapter_classify() {
    local kind="$1" item="$2" result operation=install
    homebrew_adapter_probe "$kind" || {
        HOMEBREW_ADAPTER_RESULT="$HOMEBREW_ADAPTER_CONTEXT"
        HOMEBREW_ADAPTER_STATE="$(jq -r .state <<< "$HOMEBREW_ADAPTER_RESULT")"
        return 2
    }
    if [[ "$kind" == cask ]]; then
        homebrew_cask_result "$item" --classify || return 2
        [[ "$HOMEBREW_ADAPTER_STATE" == satisfied || "$HOMEBREW_ADAPTER_STATE" == installable ||
           "$HOMEBREW_ADAPTER_STATE" == repairable ]]
        return $?
    fi
    [[ "$kind" == formula ]] || return 2
    is_brew_package_installed "$item"; result=$?
    case "$result" in
        0) homebrew_adapter_result satisfied compatible ;;
        1) homebrew_adapter_result installable compatible '' install ;;
        *) homebrew_adapter_result observation_error observation_failure homebrew_unavailable; return 2 ;;
    esac
}

is_brew_package_installed() {

    local package="$1"
    local inventory

    inventory="$(brew list --formula --full-name)" || return 2

    # Discovery emits short names. Qualified inputs must match the tap too;
    # ambiguous short names are an observation error, not confirmed absence.
    LC_ALL=C awk -v package="$package" '
        {
            count = split($0, parts, "/")
            if ($0 == package || "homebrew/core/" $0 == package ||
                (index(package, "/") == 0 && parts[count] == package)) matches++
        }
        END { exit(matches > 1 ? 2 : (matches == 1 ? 0 : 1)) }
    ' <<< "$inventory"

}

CASK_REINSTALL_REQUIRED=false

# One provider projection drives Preview, execution requalification and independent
# Verification. Payload evidence is never inferred from registration alone.
homebrew_cask_result() {
    local item="$1" mode="$2" operation="${3:-}" metadata prefix status
    homebrew_adapter_result observation_error observation_failure homebrew_unavailable "$operation" || return 2
    CASK_REINSTALL_REQUIRED=false
    CASK_OBSERVATION_CONDITION=homebrew_unavailable
    metadata="$(HOMEBREW_NO_AUTO_UPDATE=1 brew info --json=v2 --cask "$item")" || return 2
    HOMEBREW_ADAPTER_METADATA="$metadata"
    jq -e --arg token "$item" '(.casks | length == 1) and .casks[0].token == $token' <<< "$metadata" >/dev/null || {
        homebrew_adapter_failure homebrew_metadata_incompatible "$operation"; return 2;
    }
    prefix="$(HOMEBREW_NO_AUTO_UPDATE=1 brew --prefix)" || return 2
    # Public info reports registration; cross-check public inventory rather than
    # silently treating malformed/missing installed fields as confirmed absence.
    local inventory registered=false
    inventory="$(HOMEBREW_NO_AUTO_UPDATE=1 brew list --cask)" || return 2
    if grep -Fxq "$item" <<< "$inventory"; then registered=true; fi
    if [[ "$registered" == true ]] && ! jq -e '.casks[0].installed | type == "string" and length > 0' <<< "$metadata" >/dev/null; then
        homebrew_adapter_failure homebrew_metadata_incompatible "$operation"; return 2
    fi
    if [[ "$registered" == false ]] && jq -e '.casks[0].installed != null and .casks[0].installed != ""' <<< "$metadata" >/dev/null; then
        homebrew_adapter_failure homebrew_metadata_incompatible "$operation"; return 2
    fi
    HOMEBREW_ADAPTER_RESULT="$(python3 -B modules/apps/adapters/homebrew_cask.py "$prefix" "$mode" ${operation:+"$operation"} <<< "$metadata")"
    status=$?
    [[ -n "$HOMEBREW_ADAPTER_RESULT" ]] || return 2
    [[ -n "${HOMEBREW_ADAPTER_CONTEXT:-}" ]] || HOMEBREW_ADAPTER_CONTEXT='{}'
    HOMEBREW_ADAPTER_RESULT="$(jq --argjson context "$HOMEBREW_ADAPTER_CONTEXT" '.provenance = ($context.provenance // {}) | .capabilities = ($context.capabilities // [])' <<< "$HOMEBREW_ADAPTER_RESULT")" || return 2
    HOMEBREW_ADAPTER_STATE="$(jq -r .state <<< "$HOMEBREW_ADAPTER_RESULT")"
    HOMEBREW_ADAPTER_CONDITION="$(jq -r '.reason // "ready"' <<< "$HOMEBREW_ADAPTER_RESULT")"
    HOMEBREW_ADAPTER_OPERATION="$(jq -r '.operation // ""' <<< "$HOMEBREW_ADAPTER_RESULT")"
    CASK_OBSERVATION_CONDITION="$HOMEBREW_ADAPTER_CONDITION"
    CASK_REINSTALL_REQUIRED=false
    [[ "$HOMEBREW_ADAPTER_STATE" != repairable ]] || CASK_REINSTALL_REQUIRED=true
    return "$status"
}

is_cask_installed() {
    homebrew_cask_result "$1" --observe
}

cask_application_readiness() {
    local operation="${2:-install}"
    homebrew_adapter_probe cask "$operation" || {
        CASK_APPLICATION_CONDITION="$HOMEBREW_ADAPTER_CONDITION"; return 2;
    }
    homebrew_cask_result "$1" --classify "$operation" || {
        CASK_APPLICATION_CONDITION="$HOMEBREW_ADAPTER_CONDITION"; return 2;
    }
    CASK_APPLICATION_CONDITION="$HOMEBREW_ADAPTER_CONDITION"
    [[ "$HOMEBREW_ADAPTER_STATE" == installable || "$HOMEBREW_ADAPTER_STATE" == repairable ]]
}

brew_install_cask_command() {
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_SUDO=1 HOMEBREW_NO_ASK=1 \
            HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1 \
            HOMEBREW_NO_INSTALL_UPGRADE=1 HOMEBREW_CASK_OPTS='' \
            python3 -B modules/apps/brew_items.py homebrew-casks "$2" bash modules/apps/adapters/homebrew-execute.sh cask "$1" "$2"
    else
        HOMEBREW_NO_ENV_HINTS=1 brew "$1" --cask "$2"
    fi
}

brew_install_formula() {
    declare -F verification_applying_hook >/dev/null && verification_applying_hook homebrew-packages "$1" install
    if [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true ]]; then
        HOMEBREW_NO_ENV_HINTS=1 HOMEBREW_NO_SUDO=1 \
            HOMEBREW_NO_INSTALL_CLEANUP=1 HOMEBREW_NO_INSTALL_UPGRADE=1 \
            HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_ASK=1 HOMEBREW_CASK_OPTS='' \
            python3 -B modules/apps/brew_items.py homebrew-packages "$1" bash modules/apps/adapters/homebrew-execute.sh formula install "$1"
    else
        HOMEBREW_NO_ENV_HINTS=1 brew install "$1"
    fi
}
