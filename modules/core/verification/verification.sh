#!/bin/bash

# Internal, process-local records. No desired values and no target readers here.
# Fixed-width arrays avoid delimiter escaping and Bash 4 associative arrays.
# V: domain, subject, predicate, conformity, support, observed_at
# C: domain, subject, disposition, source_status
# O: domain, subject, action, outcome, reason
# D: owner (run/v:N/c:N/o:N), code, severity, phase
# All records belong to GV_RUN_ID / GV_INPUT_ID; indexes are local record IDs.
# shellcheck disable=SC2034
verification_reset() {
    GV_V=() GV_C=() GV_O=() GV_D=()
    GV_SECURE_ROWS=() GV_SECURE_STATE=not_run GV_SECURE_ATTEMPT="" GV_SECURE_EXIT=""
    GV_RUN_ID="$$-$(date -u +%Y%m%dT%H%M%SZ)-${RANDOM}"
    GV_OPERATION_CONTEXT="$GV_RUN_ID"
    GV_ORIGIN="${1:-bootstrap}"
    GV_INPUT_ID="" GV_STARTED_AT="" GV_FINISHED_AT=""
    GV_STATUS=incomplete GV_LAST_REF=run
    GV_ACTIVE=true
}

verification_diagnostic() {
    local owner="$1" code="$2" severity="$3" phase="$4" i
    case "$code" in
        confirmed_mismatch|observation_failed|selected_input_unresolved|unsupported_predicate|operation_failed|partial_source_coverage|external_management|dependency_unavailable|prerequisite_unmet|input_changed|input_invalid) ;;
        *) return 2 ;;
    esac
    case "$severity" in warning|error) ;; *) return 2 ;; esac
    case "$phase" in scope|observation|apply|post_apply|orchestration) ;; *) return 2 ;; esac
    for ((i=0; i<${#GV_D[@]}; i+=4)); do
        [[ "${GV_D[i]}" != "$owner" || "${GV_D[i+1]}" != "$code" ||
           "${GV_D[i+2]}" != "$severity" || "${GV_D[i+3]}" != "$phase" ]] || return 0
    done
    GV_D+=("$owner" "$code" "$severity" "$phase")
}

verification_record() {
    local domain="$1" subject="$2" predicate="$3" conformity="$4" support="$5" observed="$6" i
    case "$conformity" in verified|mismatch|unverified) ;; *) return 2 ;; esac
    case "$support" in supported|unsupported) ;; *) return 2 ;; esac
    [[ "$support" != unsupported || "$conformity" == unverified ]] || return 2
    [[ "$conformity" == unverified || -n "$observed" ]] || return 2
    for ((i=0; i<${#GV_V[@]}; i+=6)); do
        # Duplicate predicates indicate a collector caller error, never two facts.
        [[ "${GV_V[i]}" != "$domain" || "${GV_V[i+1]}" != "$subject" ||
           "${GV_V[i+2]}" != "$predicate" ]] || return 2
    done
    GV_LAST_REF="v:${#GV_V[@]}"
    GV_V+=("$domain" "$subject" "$predicate" "$conformity" "$support" "$observed")
}

verification_coverage() {
    local i
    case "$3" in resolved|unresolved|excluded|no_requirement) ;; *) return 2 ;; esac
    case "$4" in observed_present|observed_absent|partial|unobserved|unknown) ;; *) return 2 ;; esac
    for ((i=0; i<${#GV_C[@]}; i+=4)); do
        if [[ "${GV_C[i]}" == "$1" && "${GV_C[i+1]}" == "$2" ]]; then
            GV_LAST_REF="c:$i"
            return 0
        fi
    done
    GV_LAST_REF="c:${#GV_C[@]}"
    GV_C+=("$1" "$2" "$3" "$4")
}

verification_operation() {
    [[ "${GV_ACTIVE:-false}" == true ]] || return 0
    case "$4" in success|failure|noop|skipped|cancelled|not_run) ;; *) return 2 ;; esac
    GV_LAST_REF="o:${#GV_O[@]}"
    GV_O+=("$1" "$2" "$3" "$4" "${5:-}")
    if [[ "$4" == failure ]]; then
        verification_diagnostic "$GV_LAST_REF" operation_failed error apply
    fi
}

# Optional production hook. It must never change the caller's public status.
verification_operation_hook() {
    [[ "${GV_ACTIVE:-false}" == true ]] || return 0
    verification_operation "$@"
    return 0
}

verification_post_hook() {
    [[ "${GV_ACTIVE:-false}" == true ]] || return 0
    local result="$1"
    case "$result" in
        0) ;;
        1) verification_diagnostic "$GV_LAST_REF" confirmed_mismatch error post_apply ;;
        *) verification_diagnostic "$GV_LAST_REF" observation_failed error post_apply ;;
    esac
    return 0
}

verification_aggregate() {
    GV_TOTAL=$((${#GV_V[@]} / 6))
    GV_VERIFIED=0 GV_MISMATCH=0 GV_UNVERIFIED=0 GV_UNSUPPORTED=0
    GV_UNRESOLVED=0 GV_WARNINGS=0 GV_ERRORS=0
    local i
    for ((i=0; i<${#GV_V[@]}; i+=6)); do
        case "${GV_V[i+3]}" in
            verified) GV_VERIFIED=$((GV_VERIFIED+1)) ;;
            mismatch) GV_MISMATCH=$((GV_MISMATCH+1)) ;;
            unverified) GV_UNVERIFIED=$((GV_UNVERIFIED+1)) ;;
        esac
        [[ "${GV_V[i+4]}" != unsupported ]] || GV_UNSUPPORTED=$((GV_UNSUPPORTED+1))
    done
    for ((i=0; i<${#GV_C[@]}; i+=4)); do
        [[ "${GV_C[i+2]}" != unresolved ]] || GV_UNRESOLVED=$((GV_UNRESOLVED+1))
    done
    for ((i=0; i<${#GV_D[@]}; i+=4)); do
        case "${GV_D[i+2]}" in
            warning) GV_WARNINGS=$((GV_WARNINGS+1)) ;;
            error) GV_ERRORS=$((GV_ERRORS+1)) ;;
        esac
    done
}

verification_verdict() {
    verification_aggregate
    GV_VERDICT='Verification incomplete'
    GV_INCOMPLETE_COVERAGE=false
    [[ "$GV_STATUS" == complete ]] || return 0
    if (( GV_MISMATCH > 0 )); then
        GV_VERDICT='Differences detected'
        if (( GV_UNVERIFIED > 0 || GV_UNRESOLVED > 0 )); then
            GV_INCOMPLETE_COVERAGE=true
        fi
    elif (( GV_UNVERIFIED > 0 || GV_UNRESOLVED > 0 )); then
        :
    elif (( GV_TOTAL > 0 )); then
        GV_VERDICT='Selected requirements verified'
    else
        # An unknown empty inventory cannot prove that nothing was managed.
        local i
        ((${#GV_C[@]} > 0)) || return 0
        for ((i=0; i<${#GV_C[@]}; i+=4)); do
            case "${GV_C[i+2]}:${GV_C[i+3]}" in
                excluded:*|no_requirement:observed_absent) ;;
                *) return 0 ;;
            esac
        done
        GV_VERDICT='No managed requirements'
    fi
}

verification_reason() {
    local owner="$1" i
    GV_REASON=unknown GV_PHASE=''
    for ((i=0; i<${#GV_D[@]}; i+=4)); do
        if [[ "${GV_D[i]}" == "$owner" ]]; then
            GV_REASON="${GV_D[i+1]}"
            GV_PHASE="${GV_D[i+3]}"
            return 0
        fi
    done
}

verification_report() {
    verification_verdict
    section "Global Verification"
    info "Verdict: $GV_VERDICT"
    [[ "$GV_INCOMPLETE_COVERAGE" != true ]] || info 'Verification also incomplete.'
    info "Run: $GV_STATUS; origin: $GV_ORIGIN; observation: $GV_STARTED_AT — $GV_FINISHED_AT"
    info "Resolved: $GV_TOTAL; verified: $GV_VERIFIED; mismatch: $GV_MISMATCH; unverified: $GV_UNVERIFIED"
    info "Unsupported subset: $GV_UNSUPPORTED; unresolved selected references: $GV_UNRESOLVED"
    info "Diagnostics: $GV_WARNINGS warning(s), $GV_ERRORS error(s)"
    local i
    for ((i=0; i<${#GV_V[@]}; i+=6)); do
        [[ "${GV_V[i+3]}" != verified ]] || continue
        verification_reason "v:$i"
        info "${GV_V[i]} / ${GV_V[i+1]} / ${GV_V[i+2]}: ${GV_V[i+3]} (${GV_V[i+4]}); $GV_REASON${GV_PHASE:+; phase=$GV_PHASE}"
    done
    for ((i=0; i<${#GV_C[@]}; i+=4)); do
        detail "Coverage: ${GV_C[i]} / ${GV_C[i+1]}: ${GV_C[i+2]}, source=${GV_C[i+3]}"
        if [[ "${GV_C[i+2]}" == unresolved ]]; then
            verification_reason "c:$i"
            info "${GV_C[i]} / ${GV_C[i+1]}: unresolved selected reference; $GV_REASON${GV_PHASE:+; phase=$GV_PHASE}"
        fi
    done
    for ((i=0; i<${#GV_D[@]}; i+=4)); do
        case "${GV_D[i]}" in
            run) info "${GV_D[i+2]}: ${GV_D[i+1]} (phase=${GV_D[i+3]})" ;;
            *) [[ "${GV_D[i+1]}" != partial_source_coverage ]] || info "Warning: partial_source_coverage (${GV_D[i+3]})" ;;
        esac
    done
    for ((i=0; i<${#GV_O[@]}; i+=5)); do
        case "${GV_O[i+3]}" in
            failure|skipped|cancelled|not_run)
                info "Operation: ${GV_O[i]} / ${GV_O[i+1]} / ${GV_O[i+2]}: ${GV_O[i+3]}${GV_O[i+4]:+; reason=${GV_O[i+4]}}" ;;
            success)
                [[ "$GV_MISMATCH" -eq 0 ]] || info "Operation: ${GV_O[i]} / ${GV_O[i+1]} / ${GV_O[i+2]}: success; final differences detected" ;;
        esac
    done
    if [[ "$GV_ORIGIN" == workflow ]] && ((${#GV_O[@]} == 0)); then info 'Apply: not run'; fi
    info 'Source inventory provenance: unknown unless explicitly recorded; empty unknown inventory does not prove source absence.'
    if [[ -n "${BUNDLE_RESTORE_SECURE_FILE:-}" ]]; then
        info "SSH identity evidence is from this Restore importer at its observation time; identities are not rechecked by Global Verification."
    fi
    detail 'Target observations are sequential, not an atomic snapshot.'
}

# Aggregate-only side channel for an owned application Bootstrap subprocess.
# This projects existing records and never serializes desired or observed values.
verification_application_summary() {
    [[ "${MACSEED_APPLICATION_EXECUTION:-false}" == true &&
       "${MACSEED_VERIFICATION_FD:-}" =~ ^[0-9]+$ ]] || return 0
    local verdict=incomplete
    case "$GV_VERDICT" in
        'Selected requirements verified') verdict=selected_requirements_verified ;;
        'Differences detected') verdict=differences_detected ;;
        'No managed requirements') verdict=no_managed_requirements ;;
    esac
    printf 'v1\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\t%d\n' \
        "$GV_STATUS" "$verdict" "$GV_TOTAL" "$GV_VERIFIED" "$GV_MISMATCH" \
        "$GV_UNVERIFIED" "$GV_UNRESOLVED" "$GV_WARNINGS" "$GV_ERRORS" \
        "$WARNING_COUNT" "$ERROR_COUNT" \
        >&"$MACSEED_VERIFICATION_FD" || :
}
