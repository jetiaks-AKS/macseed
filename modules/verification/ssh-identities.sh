#!/bin/bash
# Only trusted non-secret importer evidence enters these process-local fields.
# shellcheck disable=SC2034
secure_verification_import() {
    local channel_dir result
    GV_SECURE_ATTEMPT="${GV_RUN_ID}-${RANDOM}"
    GV_SECURE_STATE=invalid
    GV_SECURE_EXIT=""
    channel_dir="$(mktemp -d /private/tmp/macseed-channel-XXXXXXXX)" || {
        ./scripts/ssh-identity-migrate.sh import --input "$BUNDLE_RESTORE_SECURE_FILE"
        GV_SECURE_EXIT=$?
        return "$GV_SECURE_EXIT";
    }
    if chmod 700 "$channel_dir" && (umask 077; : > "$channel_dir/channel"); then
        secure_verification_channel "$channel_dir" 8<"$channel_dir/channel" 9>"$channel_dir/channel"
        result=$?
    fi
    if [[ -z "$GV_SECURE_EXIT" ]]; then
        ./scripts/ssh-identity-migrate.sh import --input "$BUNDLE_RESTORE_SECURE_FILE"
        result=$?
        GV_SECURE_EXIT=$result
    fi
    # Also covers failure to open the channel. No key material exists here.
    rm -f "$channel_dir/channel"
    rmdir "$channel_dir" 2>/dev/null || true
    return "$result"
}

# shellcheck disable=SC2034
secure_verification_channel() {
    local directory="$1" result line
    # Unlink both paths while the descriptors remain open: no named payload and
    # nothing left for a shell signal trap to clean up.
    rm -f "$directory/channel"
    rmdir "$directory" || return 2
    python3 modules/migration/evidence.py ./scripts/ssh-identity-migrate.sh \
        "$BUNDLE_RESTORE_SECURE_FILE" "$GV_SECURE_ATTEMPT"
    result=$?
    GV_SECURE_EXIT=$result
    GV_SECURE_ROWS=()
    while IFS= read -r line <&8; do GV_SECURE_ROWS+=("$line"); done
    if [[ ${#GV_SECURE_ROWS[@]} -ge 2 && "${GV_SECURE_ROWS[${#GV_SECURE_ROWS[@]}-1]}" == END ]]; then
        GV_SECURE_STATE=received
    fi
    return "$result"
}

verify_ssh_identity_evidence() {
    [[ -n "${BUNDLE_RESTORE_SECURE_FILE:-}" ]] || return 0
    local tag version attempt selection count outcome reason name conformity observed phase row
    if [[ "${GV_SECURE_STATE:-not_run}" != received ]]; then
        verification_coverage ssh-identities secure-selection unresolved unobserved
        GV_STATUS=incomplete
        if [[ "${GV_SECURE_STATE:-not_run}" == not_run ]]; then
            verification_diagnostic "$GV_LAST_REF" prerequisite_unmet warning orchestration
            verification_operation ssh-identities secure-selection import not_run prerequisite_unmet
        else
            GV_STATUS=incomplete
            verification_diagnostic "$GV_LAST_REF" observation_failed error orchestration
            case "${GV_SECURE_EXIT:-}" in
                0) verification_operation ssh-identities secure-selection import success exit_status_only ;;
                2) verification_operation ssh-identities secure-selection import failure exit_status_only ;;
            esac
        fi
        return 0
    fi
    IFS=$'\t' read -r tag version attempt selection count outcome reason <<< "${GV_SECURE_ROWS[0]}"
    if [[ "$attempt" != "$GV_SECURE_ATTEMPT" || "$version" != 1 || "$tag" != E ||
          "$count" -ne $((${#GV_SECURE_ROWS[@]}-2)) ]]; then
        GV_SECURE_STATE=invalid
        verify_ssh_identity_evidence
        return
    fi
    verification_operation ssh-identities secure-selection import "$outcome" "$reason"
    if [[ "$selection" == unresolved ]]; then
        verification_coverage ssh-identities secure-selection unresolved unobserved
        if [[ "$reason" == input_invalid ]]; then
            verification_diagnostic "$GV_LAST_REF" input_invalid error scope
        elif [[ "$reason" == cancelled ]]; then
            verification_diagnostic "$GV_LAST_REF" prerequisite_unmet warning orchestration
        fi
        return 0
    fi
    for row in "${GV_SECURE_ROWS[@]:1:$count}"; do
        IFS=$'\t' read -r tag name conformity observed reason phase <<< "$row"
        verification_coverage ssh-identities "$name" resolved observed_present
        [[ "$observed" != - ]] || observed=""
        verification_record ssh-identities "$name" identity_pair_matches_package "$conformity" supported "$observed"
        if [[ "$conformity" == mismatch && "$reason" == different_pair ]] &&
           declare -F comparison_note >/dev/null; then
            comparison_note different "$GV_LAST_REF"
        fi
        if [[ -n "$observed" && "$observed" < "$GV_STARTED_AT" ]]; then GV_STARTED_AT="$observed"; fi
        case "$conformity" in
            mismatch) verification_diagnostic "$GV_LAST_REF" confirmed_mismatch warning observation ;;
            unverified)
                case "$reason" in
                    cancelled|not_observed) verification_diagnostic "$GV_LAST_REF" prerequisite_unmet warning orchestration ;;
                    *)
                        local severity=warning
                        [[ "$phase" != post_apply && "$phase" != apply ]] || severity=error
                        verification_diagnostic "$GV_LAST_REF" observation_failed "$severity" "$phase" ;;
                esac ;;
        esac
    done
}
