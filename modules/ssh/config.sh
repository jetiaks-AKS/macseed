#!/bin/bash

SSH_SNAPSHOT_FILE="${SSH_SNAPSHOT_FILE:-${BLUEPRINT_GENERATED_DIR:-config/generated}/ssh/config.snapshot}"
SSH_SNAPSHOT_STATUS=""
SSH_SNAPSHOT_COUNT=0
SSH_SNAPSHOT_EXCLUDED=0
SSH_TARGET_STATUS=""
SSH_TARGET_CONFORMITY=""
SSH_TARGET_EXCLUDED=0
SSH_SNAPSHOT_VERSION=1
SSH_IDENTITY_PORTABLE=0
SSH_IDENTITY_UNRESOLVED=0
SSH_CONFIG_HELPER="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.py"
SSH_MERGE_HELPER="${SSH_CONFIG_HELPER%/*}/ssh_merge.py"
SSH_RESOLUTION_HELPER="${SSH_CONFIG_HELPER%/*}/restore_resolution.py"
SSH_DEPENDENCIES=""
SSH_V2_APPLIED=false
SSH_V2_POST_EVIDENCE=""
SSH_MERGE_ACTION=""
SSH_MERGE_COUNT=0
SSH_TARGET_EVIDENCE=""
SSH_SOURCE_PARTIAL=false

ssh_configuration_scope_selected() {
    blueprint_exists || [[ -e "$SSH_SNAPSHOT_FILE" || -L "$SSH_SNAPSHOT_FILE" ]]
}

# Domain-owned parser shared with Bundle validation. Values remain in the
# private payload; stdout carries only counts.
ssh_config_parse() {
    python3 -B "$SSH_CONFIG_HELPER" parse "$1" "$2" "${3:-source}"
}

ssh_snapshot_validate() {
    local payload="$1" file="${2:-$SSH_SNAPSHOT_FILE}" metadata
    SSH_SNAPSHOT_STATUS=""; SSH_SNAPSHOT_COUNT=0; SSH_SNAPSHOT_EXCLUDED=0
    SSH_SNAPSHOT_VERSION=1; SSH_IDENTITY_PORTABLE=0; SSH_IDENTITY_UNRESOLVED=0
    [[ -e "$file" || -L "$file" ]] || return 1
    [[ ! -L "$file" && -f "$file" && -r "$file" &&
       ! -L "${file%/*}" && -d "${file%/*}" &&
       "$(stat -f '%u' "${file%/*}" 2>/dev/null)" == "$(id -u)" ]] || return 2
    metadata="$(python3 -B "$SSH_CONFIG_HELPER" validate "$file" "$payload")" || return 2
    read -r SSH_SNAPSHOT_VERSION SSH_SNAPSHOT_STATUS SSH_SNAPSHOT_EXCLUDED SSH_SNAPSHOT_COUNT \
        SSH_IDENTITY_PORTABLE SSH_IDENTITY_UNRESOLVED <<< "$metadata"
    return 0
}

ssh_snapshot_write() {
    local output="$1" status="$2" excluded="$3" payload="$4" checked version
    version="$(python3 -B "$SSH_CONFIG_HELPER" version "$payload")" || return 2
    { printf '# toolkit-ssh-snapshot: %s\n# status: %s\n# excluded-profiles: %s\n\n' "$version" "$status" "$excluded"; cat "$payload"; } > "$output" || return 2
    chmod 600 "$output" || return 2
    checked="$(mktemp)" || return 2
    ssh_snapshot_validate "$checked" "$output"
    local result=$?
    rm -f "$checked"
    return "$result"
}

# Conformity is shared with Verification/Comparison. Merge eligibility is
# stricter and must independently preserve the complete existing target.
ssh_target_inspect() {
    local assessment result
    SSH_TARGET_STATUS=error; SSH_TARGET_CONFORMITY=unavailable; SSH_TARGET_EXCLUDED=0
    assessment="$(python3 -B "$SSH_CONFIG_HELPER" assess "$1" "$HOME")"
    result=$?
    if [[ $result -eq 0 || $result -eq 1 ]]; then
        read -r SSH_TARGET_STATUS SSH_TARGET_CONFORMITY SSH_TARGET_EXCLUDED <<< "$assessment"
    fi
    return "$result"
}

ssh_configuration_inspect() {
    local payload="$1" result merge
    SSH_SOURCE_PARTIAL=false
    SSH_TARGET_STATUS=""; SSH_TARGET_CONFORMITY=""; SSH_TARGET_EXCLUDED=0
    SSH_MERGE_ACTION=""; SSH_MERGE_COUNT=0; SSH_TARGET_EVIDENCE=""
    ssh_snapshot_validate "$payload"
    result=$?
    if [[ $result -eq 1 ]] && ! blueprint_exists; then return 3; fi
    [[ $result -eq 0 ]] || { error "Invalid selected SSH snapshot"; return 2; }
    if [[ "$SSH_SNAPSHOT_STATUS" == partial ]]; then
        SSH_SOURCE_PARTIAL=true
        warning "SSH source excluded $SSH_SNAPSHOT_EXCLUDED profiles"
    fi
    case "$SSH_SNAPSHOT_STATUS" in
        ready|partial) ;;
        absent-directory|absent-config|empty) return 3 ;;
        unsupported|external) warning "SSH source is not eligible for restoration"; return 1 ;;
    esac
    ssh_target_inspect "$payload"
    result=$?
    [[ $result -ne 2 ]] || { error "Failed to inspect SSH target"; return 2; }
    if [[ $result -eq 1 || "$SSH_TARGET_CONFORMITY" == publication_uncertain ]]; then
        warning "Existing SSH configuration is preserved"
        return 1
    fi
    SSH_DEPENDENCIES=""
    if [[ "$SSH_SNAPSHOT_VERSION" == 2 ]]; then
        if [[ "$SSH_V2_APPLIED" == true ]]; then
            if [[ ( "$SSH_TARGET_CONFORMITY" != exact && "$SSH_TARGET_CONFORMITY" != profiles_match ) ||
                  "$(python3 -B "$SSH_MERGE_HELPER" evidence "$HOME")" != "$SSH_V2_POST_EVIDENCE" ||
                  "$(python3 -B "$SSH_RESOLUTION_HELPER" verify "$SSH_SNAPSHOT_FILE" "$HOME")" != qualified ]]; then
                error "SSH state changed after publication"
                return 2
            fi
            SSH_MERGE_ACTION=noop; SSH_DEPENDENCIES=qualified
            return 0
        fi
        merge="$(python3 -B "$SSH_RESOLUTION_HELPER" plan "$SSH_SNAPSHOT_FILE" "$HOME")"
        result=$?
        if [[ $result -ne 0 ]]; then
            SSH_MERGE_ACTION=refused
            warning "SSH configuration or identity dependencies remain unresolved"
            return 1
        fi
        read -r SSH_MERGE_ACTION SSH_MERGE_COUNT SSH_TARGET_EVIDENCE SSH_DEPENDENCIES <<< "$merge"
        return 0
    fi
    merge="$(python3 -B "$SSH_MERGE_HELPER" plan "$payload" "$HOME")"
    result=$?
    if [[ $result -ne 0 ]]; then
        SSH_MERGE_ACTION=refused
        warning "SSH configuration is not eligible for automatic additions"
        return 1
    fi
    read -r SSH_MERGE_ACTION SSH_MERGE_COUNT SSH_TARGET_EVIDENCE <<< "$merge"
    if [[ -n "${MACSEED_SSH_EXPECTED_EVIDENCE:-}" && "$MACSEED_SSH_EXPECTED_EVIDENCE" != "$SSH_TARGET_EVIDENCE" ]]; then
        error "SSH target changed after preparation"
        return 2
    fi
    if [[ "$SSH_SOURCE_PARTIAL" == true && "$SSH_MERGE_ACTION" == merge ]]; then
        warning "Partial SSH sources cannot add profiles to an existing configuration"
        return 1
    fi
    return 0
}

preview_ssh_configuration() {
    local payload result
    payload="$(mktemp)" || return 2
    ssh_configuration_inspect "$payload"; result=$?
    if [[ $result -eq 0 && "$SSH_MERGE_ACTION" == merge ]]; then
        preview_record ssh-configuration missing-profiles create planned missing_profiles
        preview_action "Would add SSH configuration: $SSH_MERGE_COUNT missing profiles"
    elif [[ "$SSH_TARGET_CONFORMITY" == exact || "$SSH_TARGET_CONFORMITY" == profiles_match ]]; then
        preview_record ssh-configuration config none satisfied
    elif [[ $result -eq 0 && "$SSH_TARGET_STATUS" == absent-* ]]; then
        preview_record ssh-configuration config create planned
    elif [[ $result -eq 3 ]]; then
        preview_record ssh-configuration config none warning source_absent
    elif [[ $result -eq 2 ]]; then
        preview_record ssh-configuration config none blocked observation_failed
    elif [[ "$SSH_SNAPSHOT_STATUS" == unsupported || "$SSH_SNAPSHOT_STATUS" == external ]]; then
        preview_record ssh-configuration config none warning source_excluded
    else
        case "$SSH_TARGET_CONFORMITY" in
            missing_profiles) preview_record ssh-configuration config none conflict missing_profiles ;;
            conflicting_profiles) preview_record ssh-configuration config none conflict target_conflict ;;
            unsupported) preview_record ssh-configuration config none warning unsupported_predicate ;;
            publication_uncertain) preview_record ssh-configuration publication none blocked ssh_publication_uncertain ;;
            *) preview_record ssh-configuration config none blocked observation_failed ;;
        esac
    fi
    if [[ $result -eq 1 && "$SSH_MERGE_ACTION" == refused &&
          ( "$SSH_TARGET_CONFORMITY" == exact || "$SSH_TARGET_CONFORMITY" == profiles_match ) ]]; then
        preview_record ssh-configuration publication none blocked external_management
    elif [[ $result -eq 1 && "$SSH_TARGET_STATUS" == different && "$SSH_TARGET_CONFORMITY" == profiles_match ]]; then
        preview_record ssh-configuration publication none conflict target_conflict
    fi
    if (( SSH_IDENTITY_PORTABLE + SSH_IDENTITY_UNRESOLVED > 0 )) && [[ "$SSH_DEPENDENCIES" != qualified ]]; then
        preview_record ssh-configuration identity-references none warning identity_dependencies_unresolved
    fi
    if [[ $result -eq 0 && "$SSH_TARGET_STATUS" == absent-* ]]; then
        preview_action "Would restore SSH configuration: $SSH_SNAPSHOT_COUNT eligible profiles"
    fi
    rm -f "$payload"
    [[ $result -ne 3 ]] || return 0
    if [[ "$SSH_SOURCE_PARTIAL" == true ]]; then
        preview_record ssh-configuration scope none warning partial_source_coverage
        [[ $result -ne 0 ]] || result=1
    fi
    if [[ "$SSH_TARGET_EXCLUDED" -gt 0 ]]; then
        preview_record ssh-configuration target-scope none warning partial_target_coverage
        [[ $result -ne 0 ]] || result=1
    fi
    return "$result"
}

bootstrap_ssh_configuration() {
    local payload result target="$HOME/.ssh/config" directory="$HOME/.ssh" temporary publication
    payload="$(mktemp)" || return 2
    ssh_configuration_inspect "$payload"; result=$?
    if [[ $result -ne 0 ]]; then
        if [[ $result -eq 1 ]]; then
            declare -F verification_application_operation_hook >/dev/null && verification_application_operation_hook ssh-configuration config create skipped target_or_source_conflict
        fi
        rm -f "$payload"; [[ $result -ne 3 ]] || return 0; return "$result"
    fi
    if [[ "$SSH_SNAPSHOT_VERSION" == 2 ]]; then
        if [[ "$SSH_V2_APPLIED" == true ]]; then
            rm -f "$payload"
            success "SSH configuration already verified"
            [[ "$SSH_SOURCE_PARTIAL" != true ]] || return 1
            return 0
        fi
        publication="$(python3 -B "$SSH_RESOLUTION_HELPER" apply "$SSH_SNAPSHOT_FILE" "$HOME")"
        result=$?
        if [[ $result -eq 0 ]]; then
            ssh_target_inspect "$payload"; result=$?
            if [[ "$SSH_TARGET_CONFORMITY" != exact && "$SSH_TARGET_CONFORMITY" != profiles_match ]]; then result=2; fi
        fi
        rm -f "$payload"
        if [[ "$publication" == published || "$publication" == 'publication_uncertain 1' ]]; then
            MODULE_CHANGED=true
        fi
        if [[ $result -ne 0 ]]; then
            declare -F verification_operation_hook >/dev/null && verification_operation_hook ssh-configuration config create failure ssh_publication_uncertain
            error "SSH publication was not verified; preserve any .macseed-ssh-pending-* directory for manual review"
            return 2
        fi
        SSH_V2_APPLIED=true
        SSH_V2_POST_EVIDENCE="$(python3 -B "$SSH_MERGE_HELPER" evidence "$HOME")" || return 2
        local outcome=success
        [[ "$publication" != noop ]] || outcome=noop
        declare -F verification_operation_hook >/dev/null && verification_operation_hook ssh-configuration config create "$outcome"
        success "SSH configuration verified; remote authentication was not tested"
        [[ "$SSH_SOURCE_PARTIAL" != true ]] || return 1
        return 0
    fi
    if [[ "$SSH_MERGE_ACTION" == merge ]]; then
        publication="$(python3 -B "$SSH_MERGE_HELPER" publish "$payload" "$HOME" "$SSH_TARGET_EVIDENCE")"
        result=$?
        rm -f "$payload"
        if [[ "$publication" == published || "$publication" == 'publication_uncertain 1' ]]; then
            MODULE_CHANGED=true
        fi
        if [[ $result -ne 0 ]]; then
            declare -F verification_operation_hook >/dev/null && verification_operation_hook ssh-configuration config create failure ssh_publication_uncertain
            error "SSH addition was not verified; preserve any .macseed-ssh-pending-* directory for manual review"
            return 2
        fi
        unset MACSEED_SSH_EXPECTED_EVIDENCE
        declare -F verification_operation_hook >/dev/null && verification_operation_hook ssh-configuration missing-profiles create success
        success "Missing SSH profiles added; predecessor retained in .macseed-ssh-predecessor-*"
        return 0
    fi
    if [[ "$SSH_TARGET_STATUS" == identical || "$SSH_MERGE_ACTION" == noop ]]; then
        unset MACSEED_SSH_EXPECTED_EVIDENCE
        declare -F verification_operation_hook >/dev/null && verification_operation_hook ssh-configuration config create noop
        rm -f "$payload"; success "SSH configuration already matches"
        [[ "$SSH_SOURCE_PARTIAL" != true ]] || return 1
        return 0
    fi
    if [[ "$SSH_TARGET_STATUS" == absent-directory ]]; then
        ssh_target_inspect "$payload"; result=$?
        if [[ $result -ne 0 || "$SSH_TARGET_STATUS" != absent-directory ]]; then
            rm -f "$payload"
            [[ $result -ne 2 ]] || { error "Failed to reinspect SSH target"; return 2; }
            warning "SSH target changed before creation"; return 1
        fi
        if ! mkdir -m 700 "$directory"; then rm -f "$payload"; error "Failed to create SSH directory"; return 2; fi
        MODULE_CHANGED=true
    fi
    ssh_target_inspect "$payload"; result=$?
    if [[ $result -ne 0 || "$SSH_TARGET_STATUS" != absent-config ]]; then
        rm -f "$payload"
        [[ $result -ne 2 ]] || { error "Failed to reinspect SSH target"; return 2; }
        warning "SSH target changed before publication"; return 1
    fi
    temporary="$(mktemp "$target.tmp.XXXXXX")" || { rm -f "$payload"; return 2; }
    if ! chmod 600 "$temporary" || ! cat "$payload" > "$temporary"; then
        rm -f "$temporary" "$payload"; error "Failed to stage SSH configuration"; return 2
    fi
    ssh_target_inspect "$payload"; result=$?
    if [[ $result -ne 0 || "$SSH_TARGET_STATUS" != absent-config ]]; then
        rm -f "$temporary" "$payload"
        [[ $result -ne 2 ]] || { error "Failed to reinspect SSH target"; return 2; }
        warning "SSH target changed before publication"; return 1
    fi
    if ! ln "$temporary" "$target"; then
        rm -f "$temporary" "$payload"
        if [[ -e "$target" || -L "$target" ]]; then warning "SSH target appeared during publication"; return 1; fi
        error "Failed to publish SSH configuration"; return 2
    fi
    # Shared lifecycle flag is read by the calling module wrapper.
    # shellcheck disable=SC2034
    MODULE_CHANGED=true
    declare -F verification_operation_hook >/dev/null && verification_operation_hook ssh-configuration config create success
    rm -f "$temporary" || { rm -f "$payload"; error "Failed to clean SSH staging file"; return 2; }
    ssh_target_inspect "$payload"; result=$?
    rm -f "$payload"
    if [[ $result -ne 0 || "$SSH_TARGET_STATUS" != identical ]]; then
        local verify_result=1
        [[ $result -eq 0 ]] || verify_result=2
        declare -F verification_post_hook >/dev/null && verification_post_hook "$verify_result"
        error "SSH configuration verification failed"
        return 2
    fi
    success "SSH configuration restored"
    [[ "$SSH_SOURCE_PARTIAL" != true ]] || return 1
    return 0
}

# Preserve the production reader's combined content/ownership predicate.
verify_ssh_configuration() {
    verification_category_selected ssh-configuration || return 0
    local payload result
    payload="$(mktemp)" || { verification_input_error ssh-configuration; return 0; }
    ssh_snapshot_validate "$payload"
    result=$?
    if [[ $result -eq 1 ]] && ! blueprint_exists; then
        verification_coverage ssh-configuration scope no_requirement unknown
        rm -f "$payload"
        return 0
    fi
    if [[ $result -ne 0 ]]; then
        verification_input_error ssh-configuration
        rm -f "$payload"
        return 0
    fi
    case "$SSH_SNAPSHOT_STATUS" in
        absent-directory|absent-config|empty)
            verification_coverage ssh-configuration scope no_requirement observed_absent
            rm -f "$payload"; return 0 ;;
        unsupported|external)
            verification_coverage ssh-configuration scope unresolved partial
            verification_diagnostic "$GV_LAST_REF" unsupported_predicate warning scope
            rm -f "$payload"; return 0 ;;
        partial)
            verification_coverage ssh-configuration config resolved partial ;;
        ready) verification_coverage ssh-configuration config resolved observed_present ;;
    esac
    if [[ "$SSH_SNAPSHOT_STATUS" == partial ]]; then
        verification_coverage ssh-configuration excluded-profiles unresolved partial
        verification_diagnostic "$GV_LAST_REF" partial_source_coverage warning scope
    fi
    ssh_target_inspect "$payload"
    result=$?
    rm -f "$payload"
    if [[ $result -eq 2 ]]; then
        verification_result ssh-configuration config supported_config_match 2
    else
        case "$SSH_TARGET_CONFORMITY" in
            exact|profiles_match) verification_result ssh-configuration config supported_config_match 0 ;;
            conflicting_profiles)
                verification_result ssh-configuration config supported_config_match 1 '' different ;;
            missing_profiles)
                verification_result ssh-configuration config supported_config_match 1 '' absent ;;
            unsupported) verification_unsupported ssh-configuration config supported_config_match ;;
            unsafe) verification_result ssh-configuration config supported_config_match 2 external_management ;;
            publication_uncertain)
                verification_result ssh-configuration config supported_config_match 2 operation_failed
                verification_coverage ssh-configuration publication unresolved unobserved ;;
            *) verification_result ssh-configuration config supported_config_match 2 ;;
        esac
    fi
    if (( SSH_IDENTITY_PORTABLE + SSH_IDENTITY_UNRESOLVED > 0 )); then
        if [[ "$(python3 -B "$SSH_RESOLUTION_HELPER" verify "$SSH_SNAPSHOT_FILE" "$HOME")" == qualified ]]; then
            verification_coverage ssh-configuration identity-references resolved observed_present
            verification_result ssh-configuration identity-references identity_references_qualified 0
        else
            verification_coverage ssh-configuration identity-references unresolved unobserved
            verification_diagnostic "$GV_LAST_REF" prerequisite_unmet warning scope
        fi
    fi
    if [[ "$SSH_TARGET_EXCLUDED" -gt 0 ]]; then
        verification_coverage ssh-configuration target-scope unresolved partial
        verification_diagnostic "$GV_LAST_REF" unsupported_predicate warning scope
    fi
}
