#!/bin/bash
# Runs inside the existing owned-item watchdog, after dependency resolution.
# Bind final qualification before native launch; the authorized profile repeats
# qualification after its credential prompt. Homebrew owns every lifecycle write.
umask 077
source modules/apps/adapters/homebrew.sh
kind="$1" operation="$2" item="$3"
[[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
   "${HOMEBREW_NO_SUDO:-}" == 1 && -d "${MACSEED_ITEM_STATE_DIR:-}" ]] || exit 128
if [[ "$kind" == cask ]]; then
    if ! cask_application_readiness "$item" "$operation"; then
        homebrew_adapter_failure "$CASK_APPLICATION_CONDITION" "$operation"
        printf '%s\n' "$HOMEBREW_ADAPTER_RESULT" > "$MACSEED_ITEM_STATE_DIR/homebrew-precondition.json"
        exit 128
    fi
    accepted="$(jq -er --arg item "$item" '.[$item]' "$MACSEED_ITEM_STATE_DIR/prepared-casks.json")" || exit 128
    current="$(jq -er '.qualification_id' <<< "$HOMEBREW_ADAPTER_RESULT")" || exit 128
    if [[ "$accepted" != "$current" ]]; then
        homebrew_adapter_failure homebrew_precondition_changed "$operation"
        printf '%s\n' "$HOMEBREW_ADAPTER_RESULT" > "$MACSEED_ITEM_STATE_DIR/homebrew-precondition.json"
        exit 128
    fi
    profile="$(jq -er '.execution.profile' <<< "$HOMEBREW_ADAPTER_RESULT")" || exit 128
    # Remember the qualified declaration, not a possibly evolved definition read
    # after installation. This is Macseed-owned evidence, never a Homebrew receipt.
    printf '%s\n' "$HOMEBREW_ADAPTER_METADATA" > "$MACSEED_ITEM_STATE_DIR/homebrew-applied-metadata.json" || exit 128
    exec python3 -B modules/apps/adapters/homebrew_lifecycle.py "$operation" "$item" "$current" "$profile"
elif [[ "$kind" == formula && "$operation" == install ]]; then
    if ! homebrew_adapter_probe formula; then
        printf '%s\n' "$HOMEBREW_ADAPTER_CONTEXT" > "$MACSEED_ITEM_STATE_DIR/homebrew-precondition.json"
        exit 128
    fi
    exec brew install "$item"
fi
exit 128
