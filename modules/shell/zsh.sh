#!/bin/bash

# A single data artifact contains a fixed header and an optional opaque payload.
ZSH_SNAPSHOT_FILE="${ZSH_SNAPSHOT_FILE:-${BLUEPRINT_GENERATED_DIR:-config/generated}/shell/zshrc.snapshot}"
ZSH_SNAPSHOT_STATUS=""
ZSH_SNAPSHOT_REASON=""
ZSH_SNAPSHOT_LENGTH=0
ZSH_SNAPSHOT_OFFSET=0
ZSH_EXCLUSION_REASON=""

zsh_home_valid() {
    [[ "$HOME" == /* && "$HOME" != *[[:cntrl:]]* &&
       -d "$HOME" && ! -L "$HOME" &&
       "$(stat -f '%u' "$HOME" 2>/dev/null)" == "$(id -u)" ]]
}

zsh_snapshot_hash() {
    local value
    value="$(shasum -a 256 "$1" 2>/dev/null)" || return 2
    printf '%s\n' "${value%% *}"
}

zsh_snapshot_validate() {
    local file="${1:-$ZSH_SNAPSHOT_FILE}"
    local schema status reason length hash separator actual total offset digest
    local LC_ALL=C

    ZSH_SNAPSHOT_STATUS=""
    ZSH_SNAPSHOT_REASON=""
    ZSH_SNAPSHOT_LENGTH=0
    ZSH_SNAPSHOT_OFFSET=0

    [[ -e "$file" || -L "$file" ]] || return 1
    [[ ! -L "$file" && -f "$file" && -r "$file" &&
       ! -L "${file%/*}" && ! -L "${file%/*/*}" &&
       "$(stat -f '%u' "${file%/*}" 2>/dev/null)" == "$(id -u)" ]] || return 2
    [[ "$(stat -f '%u' "$file" 2>/dev/null)" == "$(id -u)" ]] || return 2
    [[ "$(stat -f '%Lp' "$file" 2>/dev/null)" == 600 ]] || return 2
    total="$(wc -c < "$file" 2>/dev/null)" || return 2
    total="${total//[[:space:]]/}"
    [[ "$total" =~ ^[0-9]+$ && $total -le 66000 ]] || return 2

    exec 3< "$file" || return 2
    IFS= read -r schema <&3 && IFS= read -r status <&3 &&
        IFS= read -r reason <&3 && IFS= read -r length <&3 &&
        IFS= read -r hash <&3 && IFS= read -r separator <&3
    local read_result=$?
    exec 3<&-
    [[ $read_result -eq 0 && "$schema" == MBT-ZSHRC-1 &&
       "$separator" == --- ]] || return 2
    offset=$(( ${#schema} + ${#status} + ${#reason} + ${#length} + ${#hash} + ${#separator} + 6 ))
    [[ "$length" =~ ^length=(0|[1-9][0-9]{0,4})$ ]] || return 2
    actual="${BASH_REMATCH[1]}"
    [[ $actual -le 65536 && $total -eq $((offset + actual)) ]] || return 2

    case "$status:$reason" in
        status=eligible:reason=-)
            [[ "$hash" =~ ^sha256=([0-9a-f]{64})$ ]] || return 2
            digest="${BASH_REMATCH[1]}"
            local measured
            measured="$(set -o pipefail; tail -c +"$((offset + 1))" "$file" | shasum -a 256)" || return 2
            [[ "${measured%% *}" == "$digest" ]] || return 2
            ZSH_SNAPSHOT_STATUS=eligible
            ;;
        status=absent:reason=-)
            [[ $actual -eq 0 && "$hash" == sha256=- ]] || return 2
            ZSH_SNAPSHOT_STATUS=absent
            ;;
        status=excluded:reason=external-owner|status=excluded:reason=sensitive-content|status=excluded:reason=portability|status=excluded:reason=dependency|status=excluded:reason=unsupported-source)
            [[ $actual -eq 0 && "$hash" == sha256=- ]] || return 2
            ZSH_SNAPSHOT_STATUS=excluded
            ZSH_SNAPSHOT_REASON="${reason#reason=}"
            ;;
        *) return 2 ;;
    esac

    ZSH_SNAPSHOT_LENGTH="$actual"
    ZSH_SNAPSHOT_OFFSET="$offset"
    return 0
}

zsh_snapshot_write() {
    local file="$1" status="$2" reason="$3" payload="${4:-}"
    local length=0 hash=-
    if [[ "$status" == eligible ]]; then
        length="$(wc -c < "$payload")" || return 2
        length="${length//[[:space:]]/}"
        hash="$(zsh_snapshot_hash "$payload")" || return 2
    fi
    {
        printf 'MBT-ZSHRC-1\nstatus=%s\nreason=%s\nlength=%s\nsha256=%s\n---\n' \
            "$status" "$reason" "$length" "$hash"
        [[ "$status" != eligible ]] || cat "$payload"
    } > "$file" || return 2
    chmod 600 "$file" || return 2
    zsh_snapshot_validate "$file"
}

zsh_snapshot_publish() {
    local status="$1" reason="$2" payload="${3:-}"
    local dir="${ZSH_SNAPSHOT_FILE%/*}" temporary
    [[ -d "${dir%/*}" && ! -L "${dir%/*}" ]] || return 2
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        (umask 077; mkdir "$dir") || return 2
    fi
    [[ -d "$dir" && ! -L "$dir" &&
       "$(stat -f '%u' "$dir" 2>/dev/null)" == "$(id -u)" ]] || return 2
    chmod 700 "$dir" || return 2
    [[ ! -L "$ZSH_SNAPSHOT_FILE" ]] || return 2
    temporary="$(mktemp "$ZSH_SNAPSHOT_FILE.tmp.XXXXXX")" || return 2
    if ! zsh_snapshot_write "$temporary" "$status" "$reason" "$payload" ||
       ! mv -f "$temporary" "$ZSH_SNAPSHOT_FILE"; then
        rm -f "$temporary"
        return 2
    fi
    return 0
}

# Known hazards only; no shell parser or claim that other content is safe.
zsh_snapshot_hazard() {
    local file="$1" result
    ZSH_EXCLUSION_REASON=""
    LC_ALL=C grep -aEiq '(chezmoi|(^|[^[:alnum:]_])(yadm|stow)([^[:alnum:]_]|$)|(^|[/~])\.?([[:alnum:]_-]*dotfiles)(/|$))' "$file"
    result=$?
    [[ $result -le 1 ]] || return 2
    if [[ $result -eq 0 ]]; then
        ZSH_EXCLUSION_REASON=external-owner
        return 0
    fi
    LC_ALL=C grep -aEiq '^[[:space:]]*((export|typeset)[[:space:]]+)?[[:alnum:]_]*(TOKEN|PASSWORD|SECRET|API_KEY|ACCESS_KEY|PRIVATE_KEY|CREDENTIAL)[[:alnum:]_]*[[:space:]]*=|https?://[^[:space:]/@]+:[^[:space:]/@]+@' "$file"
    result=$?
    [[ $result -le 1 ]] || return 2
    if [[ $result -eq 0 ]]; then
        ZSH_EXCLUSION_REASON=sensitive-content
        return 0
    fi
    LC_ALL=C grep -aEq '/Users/[^/[:space:]]+/|/opt/homebrew|/usr/local' "$file"
    result=$?
    [[ $result -le 1 ]] || return 2
    if [[ $result -eq 0 ]]; then
        ZSH_EXCLUSION_REASON=portability
        return 0
    fi
    LC_ALL=C grep -aEq '(^|[[:space:];|&])(source|\.)[[:space:]]+|(^|[[:space:];|&])eval[[:space:]]+|\$\(|`' "$file"
    result=$?
    [[ $result -le 1 ]] || return 2
    if [[ $result -eq 0 ]]; then
        ZSH_EXCLUSION_REASON=dependency
        return 0
    fi
    return 1
}

discover_zsh() {
    local source_file="$HOME/.zshrc" captured size stripped before after reason
    local result=0 hazard_result
    action "Inspecting Zsh configuration..."
    if ! zsh_home_valid; then
        error "Failed to inspect Zsh HOME"
        return 2
    fi
    if [[ -n "${ZDOTDIR:-}" && "$ZDOTDIR" != "$HOME" ]]; then
        reason=unsupported-source
    elif [[ ! -e "$source_file" && ! -L "$source_file" ]]; then
        reason=absent
    elif [[ -L "$source_file" ]]; then
        reason=external-owner
    elif [[ ! -f "$source_file" ]]; then
        reason=unsupported-source
    elif [[ ! -r "$source_file" ]]; then
        error "Failed to read Zsh configuration"
        return 2
    else
        before="$(stat -f '%d:%i:%z:%m' "$source_file" 2>/dev/null)" || return 2
        captured="$(mktemp)" || return 2
        chmod 600 "$captured" || { rm -f "$captured"; return 2; }
        if ! cp "$source_file" "$captured"; then
            rm -f "$captured"
            error "Failed to read Zsh configuration"
            return 2
        fi
        after="$(stat -f '%d:%i:%z:%m' "$source_file" 2>/dev/null)" || {
            rm -f "$captured"
            return 2
        }
        if [[ "$before" != "$after" || -L "$source_file" ]] ||
           ! cmp -s "$source_file" "$captured"; then
            rm -f "$captured"
            error "Zsh configuration changed during inspection"
            return 2
        fi
        size="$(wc -c < "$captured")" || { rm -f "$captured"; return 2; }
        size="${size//[[:space:]]/}"
        stripped="$(set -o pipefail; LC_ALL=C tr -d '\000' < "$captured" | wc -c)" || {
            rm -f "$captured"
            return 2
        }
        stripped="${stripped//[[:space:]]/}"
        if [[ $size -gt 65536 || "$size" != "$stripped" ]]; then
            reason=unsupported-source
        else
            zsh_snapshot_hazard "$captured"
            hazard_result=$?
            case "$hazard_result" in
                0) reason="$ZSH_EXCLUSION_REASON" ;;
                1) reason=eligible ;;
                *) rm -f "$captured"; error "Failed to inspect Zsh configuration"; return 2 ;;
            esac
        fi
    fi

    case "$reason" in
        eligible) zsh_snapshot_publish eligible - "$captured" || result=2 ;;
        absent) zsh_snapshot_publish absent - || result=2 ;;
        *) zsh_snapshot_publish excluded "$reason" || result=2 ;;
    esac
    [[ -z "${captured:-}" ]] || rm -f "$captured"
    if [[ $result -eq 2 ]]; then
        error "Failed to publish Zsh configuration"
        return 2
    fi
    if [[ "$reason" == eligible ]]; then
        success "Zsh configuration eligible for snapshot"
        return 0
    fi
    if [[ "$reason" == absent ]]; then
        warning "Zsh configuration absent"
    else
        warning "Zsh configuration excluded: $reason"
    fi
    return 1
}

zsh_snapshot_inspect_target() {
    local target="$HOME/.zshrc" target_size measured
    zsh_home_valid || return 2
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        return 1 # Confirmed absence.
    fi
    [[ ! -L "$target" && -f "$target" && -r "$target" ]] || return 2
    target_size="$(wc -c < "$target" 2>/dev/null)" || return 2
    target_size="${target_size//[[:space:]]/}"
    [[ "$target_size" == "$ZSH_SNAPSHOT_LENGTH" ]] || return 3
    measured="$(zsh_snapshot_hash "$target")" || return 2
    local snapshot_digest
    snapshot_digest="$(sed -n '5p' "$ZSH_SNAPSHOT_FILE")" || return 2
    [[ "$measured" == "${snapshot_digest#sha256=}" ]] && return 0
    return 3 # Different regular file.
}

preview_zsh() {
    local result
    zsh_snapshot_validate
    result=$?
    [[ $result -ne 2 ]] || { error "Invalid generated Zsh snapshot"; return 2; }
    if [[ $result -eq 1 ]]; then
        if blueprint_exists; then
            error "Selected Zsh snapshot is missing"
            return 2
        fi
        return 0
    fi
    case "$ZSH_SNAPSHOT_STATUS" in
        absent) warning "Zsh configuration absent from source"; return 1 ;;
        excluded) warning "Zsh configuration excluded: $ZSH_SNAPSHOT_REASON"; return 1 ;;
    esac
    zsh_snapshot_inspect_target
    result=$?
    case "$result" in
        0) success "Zsh configuration already matches"; return 0 ;;
        1) preview_action "Would restore Zsh configuration"; return 0 ;;
        3) warning "Existing .zshrc differs; no replacement planned"; return 1 ;;
        *) error "Failed to inspect Zsh destination"; return 2 ;;
    esac
}

bootstrap_zsh() {
    local result target="$HOME/.zshrc" temporary
    zsh_snapshot_validate
    result=$?
    [[ $result -ne 2 ]] || { error "Invalid generated Zsh snapshot"; return 2; }
    if [[ $result -eq 1 ]]; then
        if blueprint_exists; then
            error "Selected Zsh snapshot is missing"
            return 2
        fi
        return 0
    fi
    case "$ZSH_SNAPSHOT_STATUS" in
        absent) warning "Zsh configuration absent from source"; return 1 ;;
        excluded) warning "Zsh configuration excluded: $ZSH_SNAPSHOT_REASON"; return 1 ;;
    esac
    zsh_snapshot_inspect_target
    result=$?
    case "$result" in
        0) success "Zsh configuration already matches"; return 0 ;;
        3) warning "Existing .zshrc differs; no replacement made"; return 1 ;;
        1) ;;
        *) error "Failed to inspect Zsh destination"; return 2 ;;
    esac
    temporary="$(mktemp "$target.tmp.XXXXXX")" || return 2
    if ! tail -c +"$((ZSH_SNAPSHOT_OFFSET + 1))" "$ZSH_SNAPSHOT_FILE" > "$temporary" ||
       ! chmod 600 "$temporary"; then
        rm -f "$temporary"
        error "Failed to stage Zsh configuration"
        return 2
    fi
    # Refuse a target created after inspection; avoid mv replacing it.
    if [[ -e "$target" || -L "$target" ]]; then
        rm -f "$temporary"
        warning "Zsh destination changed before publication"
        return 1
    fi
    if ! ln "$temporary" "$target"; then
        rm -f "$temporary"
        error "Failed to publish Zsh configuration"
        return 2
    fi
    # Shared lifecycle flag is read by the calling module wrapper.
    # shellcheck disable=SC2034
    MODULE_CHANGED=true
    if ! rm -f "$temporary"; then
        error "Failed to clean up Zsh staging file"
        return 2
    fi
    zsh_snapshot_inspect_target
    result=$?
    if [[ $result -ne 0 || "$(stat -f '%Lp' "$target" 2>/dev/null)" != 600 ||
          "$(stat -f '%u' "$target" 2>/dev/null)" != "$(id -u)" ]]; then
        error "Zsh configuration verification failed"
        return 2
    fi
    success "Zsh configuration restored"
    return 0
}
