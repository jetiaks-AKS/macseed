#!/bin/bash

# Transient projection of the current Verification run. CV_KIND is indexed by
# Verification record offset; it contains only typed observations, never values.
source "$(dirname "${BASH_SOURCE[0]}")/provenance.sh"

comparison_note() {
    [[ "${CV_ACTIVE:-false}" == true ]] || return 0
    case "$1" in absent|different|unknown) ;; *) return 2 ;; esac
    CV_KIND["${2#v:}"]="$1"
}

comparison_project() {
    CV_MATCHING=0 CV_MISSING=0 CV_DIFFERING=0 CV_UNVERIFIED=0
    CV_UNSUPPORTED=0 CV_UNRESOLVED=0 CV_UNKNOWN_DIFFERENCE=0
    CV_ROWS=()
    local i kind category reason phase
    for ((i=0; i<${#GV_V[@]}; i+=6)); do
        kind="${CV_KIND[$i]:-unknown}"
        case "${GV_V[i+3]}" in
            verified) category=matching; CV_MATCHING=$((CV_MATCHING+1)) ;;
            unverified) category=unverified; CV_UNVERIFIED=$((CV_UNVERIFIED+1)) ;;
            mismatch)
                case "$kind" in
                    absent) category=missing; CV_MISSING=$((CV_MISSING+1)) ;;
                    different) category=differing; CV_DIFFERING=$((CV_DIFFERING+1)) ;;
                    *) category=unverified; CV_UNVERIFIED=$((CV_UNVERIFIED+1)); CV_UNKNOWN_DIFFERENCE=$((CV_UNKNOWN_DIFFERENCE+1)) ;;
                esac ;;
        esac
        [[ "${GV_V[i+4]}" != unsupported ]] || CV_UNSUPPORTED=$((CV_UNSUPPORTED+1))
        [[ "$category" != matching ]] || continue
        verification_reason "v:$i"
        reason="$GV_REASON" phase="$GV_PHASE"
        [[ "$kind" != unknown || "${GV_V[i+3]}" != mismatch ]] || reason=unknown_difference
        CV_ROWS+=("$category" "${GV_V[i]}" "${GV_V[i+1]}" "${GV_V[i+2]}" "$reason" "$phase" "${GV_V[i+4]}")
    done
    for ((i=0; i<${#GV_C[@]}; i+=4)); do
        [[ "${GV_C[i+2]}" != unresolved ]] || CV_UNRESOLVED=$((CV_UNRESOLVED+1))
    done
    comparison_extra
    CV_VERDICT='Comparison incomplete'
    CV_ALSO_INCOMPLETE=false
    [[ "$GV_STATUS" == complete ]] || return 0
    if (( CV_MISSING + CV_DIFFERING + CV_EXTRA_TOTAL > 0 )); then
        CV_VERDICT='Differences detected'
        if (( CV_UNVERIFIED + CV_UNRESOLVED > 0 )); then CV_ALSO_INCOMPLETE=true; fi
    elif (( CV_UNVERIFIED + CV_UNRESOLVED > 0 )); then
        :
    elif (( CV_MATCHING > 0 )); then
        CV_VERDICT='No differences detected'
    else
        # Stage 13 already proves empty managed scope from Coverage facts.
        verification_verdict
        [[ "$GV_VERDICT" != 'No managed requirements' ]] || CV_VERDICT='No comparable requirements'
    fi
}

comparison_extra() {
    CV_EXTRA_DOMAINS=(homebrew-casks app-store vscode-extensions)
    CV_EXTRA_STATES=() CV_EXTRA_COUNTS=() CV_EXTRA_REASONS=() CV_EXTRA_ROWS=()
    CV_EXTRA_TOTAL=0
    local domain source target item identity found count state reason
    for domain in "${CV_EXTRA_DOMAINS[@]}"; do
        state=unavailable reason=reference_inventory_completeness_unknown count=''
        if blueprint_exists && [[ -z "$(blueprint_selected_items "$domain")" ]]; then
            state=not_applicable reason=category_excluded
        elif provenance_complete "$domain"; then
            state=pending
            case "$domain" in
                homebrew-casks) source="$(read_brew_casks_configuration "$PROVENANCE_INVENTORY")" || state=unavailable ;;
                app-store) source="$(read_appstore_configuration "$PROVENANCE_INVENTORY")" || state=unavailable ;;
                vscode-extensions) source="$(read_vscode_extensions_configuration "$PROVENANCE_INVENTORY")" || state=unavailable ;;
            esac
            if [[ "$state" == unavailable ]]; then
                CV_EXTRA_STATES+=(unavailable) CV_EXTRA_COUNTS+=('') CV_EXTRA_REASONS+=(invalid_reference_inventory)
                continue
            fi
            state=unavailable
            reason=target_inventory_unavailable
            case "$domain" in
                homebrew-casks) target="$(brew list --cask)" && state=available ;;
                app-store)
                    if command -v mas >/dev/null 2>&1; then
                        target="$(MAS_NO_AUTO_INDEX=1 mas list)" && state=available
                    else reason=dependency_unavailable; fi ;;
                vscode-extensions)
                    if command -v code >/dev/null 2>&1; then
                        target="$(code --list-extensions)" && state=available
                    else reason=dependency_unavailable; fi ;;
            esac
            if [[ "$state" == available ]]; then
                count=0 reason=''
                local -a candidates=()
                while IFS= read -r item; do
                    [[ -n "$item" ]] || continue
                    case "$domain" in
                        homebrew-casks) identity="$item"; [[ "$identity" =~ ^[A-Za-z0-9][A-Za-z0-9+_.@-]*$ ]] ;;
                        app-store) identity="${item%% *}"; [[ "$item" == *' '* && "$identity" =~ ^[0-9]+$ ]] ;;
                        vscode-extensions) identity="$item"; [[ "$identity" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*\.[A-Za-z0-9][A-Za-z0-9_-]*$ ]] ;;
                    esac
                    if [[ $? -ne 0 ]]; then state=unavailable reason=invalid_target_inventory; break; fi
                    candidates+=("$identity")
                done <<< "$target"
                if [[ "$state" == available ]]; then
                    for identity in "${candidates[@]}"; do
                        found=false
                        while IFS= read -r item; do
                            [[ "$domain" != app-store ]] || item="${item%%|*}"
                            if [[ "$item" == "$identity" ]]; then found=true; break; fi
                        done <<< "$source"
                        if [[ "$found" == false ]]; then
                            CV_EXTRA_ROWS+=("$domain" "$identity")
                            count=$((count+1))
                        fi
                    done
                    CV_EXTRA_TOTAL=$((CV_EXTRA_TOTAL+count))
                else
                    count=''
                fi
            fi
        fi
        CV_EXTRA_STATES+=("$state") CV_EXTRA_COUNTS+=("$count") CV_EXTRA_REASONS+=("$reason")
    done
}

comparison_report() {
    comparison_project
    section 'Environment Comparison'
    info "Verdict: $CV_VERDICT"
    [[ "$CV_ALSO_INCOMPLETE" != true ]] || info 'Comparison also incomplete.'
    info "Reference: selected environment; current: this Mac; run: $GV_STATUS"
    info "Observation: $GV_STARTED_AT — $GV_FINISHED_AT"
    info "Matching: $CV_MATCHING; missing: $CV_MISSING; differing: $CV_DIFFERING; unverified: $CV_UNVERIFIED"
    info "Unsupported subset: $CV_UNSUPPORTED; unresolved references: $CV_UNRESOLVED"
    info 'Extra:'
    local j
    for ((j=0; j<${#CV_EXTRA_DOMAINS[@]}; j++)); do
        if [[ "${CV_EXTRA_STATES[j]}" == available ]]; then
            info "  ${CV_EXTRA_DOMAINS[j]}: ${CV_EXTRA_COUNTS[j]}"
        else
            info "  ${CV_EXTRA_DOMAINS[j]}: ${CV_EXTRA_STATES[j]} — ${CV_EXTRA_REASONS[j]}"
        fi
    done
    info '  homebrew-packages: unavailable — source inventory excludes dependency formulae'
    info '  scalar/payload/workspace domains: not_applicable'
    local i
    for ((i=0; i<${#CV_ROWS[@]}; i+=7)); do
        info "${CV_ROWS[i]}: ${CV_ROWS[i+1]} / ${CV_ROWS[i+2]} / ${CV_ROWS[i+3]}; ${CV_ROWS[i+4]}${CV_ROWS[i+5]:+; phase=${CV_ROWS[i+5]}}${CV_ROWS[i+6]:+; support=${CV_ROWS[i+6]}}"
    done
    for ((i=0; i<${#GV_C[@]}; i+=4)); do
        [[ "${GV_C[i+2]}" != unresolved ]] || info "Unresolved: ${GV_C[i]} / ${GV_C[i+1]} (selected reference)"
    done
    for ((i=0; i<${#CV_EXTRA_ROWS[@]}; i+=2)); do
        info "extra: ${CV_EXTRA_ROWS[i]} / ${CV_EXTRA_ROWS[i+1]}"
    done
}

# Internal only. Reuses selected scope and production inspectors; never Apply.
comparison_run() {
    CV_KIND=() CV_ACTIVE=true
    verification_reset comparison
    verification_run >/dev/null
    CV_ACTIVE=false
    comparison_report
    return 0
}
