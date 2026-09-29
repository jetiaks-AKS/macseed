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

verification_report() {
    verification_aggregate
    section "Global Verification"
    info "Origin: $GV_ORIGIN; observation: $GV_STARTED_AT — $GV_FINISHED_AT; run: $GV_STATUS"
    if [[ "$GV_STATUS" != complete ]]; then
        warning "Incomplete verification; counts do not confirm one unchanged selected input."
    fi
    info "Resolved requirements: $GV_TOTAL; verified: $GV_VERIFIED; mismatch: $GV_MISMATCH; unverified: $GV_UNVERIFIED"
    info "Unsupported subset: $GV_UNSUPPORTED; unresolved selected references: $GV_UNRESOLVED"
    info "Diagnostics: warnings: $GV_WARNINGS; errors: $GV_ERRORS (independent of conformity)"
    local i
    for ((i=0; i<${#GV_V[@]}; i+=6)); do
        if [[ "${GV_V[i+4]}" == unsupported ]]; then
            info "Uncovered: ${GV_V[i]} / ${GV_V[i+1]} (${GV_V[i+2]})"
        elif [[ "${GV_V[i+3]}" != verified ]]; then
            info "${GV_V[i+3]}: ${GV_V[i]} / ${GV_V[i+1]} (${GV_V[i+2]})"
        fi
    done
    for ((i=0; i<${#GV_C[@]}; i+=4)); do
        detail "Coverage: ${GV_C[i]} / ${GV_C[i+1]}: ${GV_C[i+2]}, source=${GV_C[i+3]}"
        if [[ "${GV_C[i+2]}" == unresolved ]]; then
            info "Unresolved: ${GV_C[i]} / ${GV_C[i+1]}"
        fi
    done
    for ((i=0; i<${#GV_D[@]}; i+=4)); do
        info "${GV_D[i+2]}: ${GV_D[i+1]} (${GV_D[i+3]}, ${GV_D[i]})"
    done
    info "SSH identities are outside Global Verification coverage; import success is not a verification record."
    info "Sequential observations of supported predicates; no environment readiness verdict."
}
