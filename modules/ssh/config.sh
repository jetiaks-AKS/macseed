#!/bin/bash

SSH_SNAPSHOT_FILE="${SSH_SNAPSHOT_FILE:-${BLUEPRINT_GENERATED_DIR:-config/generated}/ssh/config.snapshot}"
SSH_SNAPSHOT_STATUS=""
SSH_SNAPSHOT_COUNT=0
SSH_SNAPSHOT_EXCLUDED=0
SSH_TARGET_STATUS=""
SSH_SOURCE_PARTIAL=false

ssh_configuration_scope_selected() {
    blueprint_exists || [[ -e "$SSH_SNAPSHOT_FILE" || -L "$SSH_SNAPSHOT_FILE" ]]
}

# Parse only the deliberately restricted v1 grammar. Output is canonical
# configuration; stdout contains counts only, never infrastructure values.
ssh_config_parse() {
    local input="$1" output="$2" mode="${3:-source}"
    local original_bytes clean_bytes
    original_bytes="$(wc -c < "$input")" || return 2
    clean_bytes="$(set -o pipefail; LC_ALL=C tr -d '\000' < "$input" | wc -c)" || return 2
    [[ "$original_bytes" == "$clean_bytes" ]] || return 2
    : > "$output" || return 2
    LC_ALL=C awk -v output="$output" -v mode="$mode" '
        function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
        function bad_value(k, v, n) {
            if (k == "hostname") return v !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/
            if (k == "user") return v !~ /^[A-Za-z_][A-Za-z0-9._-]*$/
            if (k == "tcpkeepalive") return v != "yes" && v != "no"
            if (k == "port" || k == "serveraliveinterval" ||
                k == "serveralivecountmax" || k == "connecttimeout") {
                if (v !~ /^(0|[1-9][0-9]*)$/ || length(v) > 5) return 1
                n = v + 0
                if (k == "port") return n < 1 || n > 65535
                if (k == "serveraliveinterval") return n > 3600
                if (k == "serveralivecountmax") return n > 20
                return n < 1 || n > 300
            }
            return 1
        }
        function canonical(k) {
            if (k == "hostname") return "HostName"
            if (k == "user") return "User"
            if (k == "port") return "Port"
            if (k == "serveraliveinterval") return "ServerAliveInterval"
            if (k == "serveralivecountmax") return "ServerAliveCountMax"
            if (k == "tcpkeepalive") return "TCPKeepAlive"
            if (k == "connecttimeout") return "ConnectTimeout"
            return ""
        }
        function finish() {
            if (!in_block) return
            if (block_bad || !seen["hostname"]) excluded++
            else { printf "%s", block > output; eligible++ }
        }
        {
            line = $0
            if (mode == "snapshot" && NR <= 4) {
                if (NR == 1 && line != "# toolkit-ssh-snapshot: 1") fatal = 1
                if (NR == 2 && line !~ /^# status: (absent-directory|absent-config|empty|ready|partial|unsupported|external)$/) fatal = 1
                if (NR == 3 && line !~ /^# excluded-profiles: (0|[1-9][0-9]*)$/) fatal = 1
                if (NR == 4 && line != "") fatal = 1
                next
            }
            sub(/\r$/, "", line)
            if (index(line, "\r")) { fatal = 1; next }

            line = trim(line)

            # Blank lines and full-line comments are semantically inert.
            # Their contents are never serialized into the generated snapshot.
            if (line == "" || line ~ /^#/) next

            # Configuration syntax itself remains deliberately ASCII-only in v1.
            if (line ~ /[^\t -~]/) { fatal = 1; next }
            if (line ~ /^[A-Za-z][A-Za-z0-9]*=/) {
                key = line; sub(/=.*/, "", key); key = tolower(key)
                if (key == "host" || key == "include" || key == "match" || !in_block) structural = 1
                else block_bad = 1
                next
            }
            if (line !~ /^[A-Za-z][A-Za-z0-9]*[ \t]+[^ \t]/) { fatal = 1; next }
            key = line; sub(/[ \t].*$/, "", key); key = tolower(key)
            value = line; sub(/^[^ \t]+[ \t]+/, "", value); value = trim(value)
            if (key == "include" || key == "match") { structural = 1; next }
            if (key == "host") {
                finish(); in_block = 1; block_bad = 0; delete seen
                if (value !~ /^[A-Za-z0-9][A-Za-z0-9._-]*$/ || aliases[value]++) structural = 1
                block = "Host " value "\n"
                next
            }
            if (!in_block) { structural = 1; next }
            name = canonical(key)
            if (name == "" || value ~ /[ \t#"\047\\=]/ || bad_value(key, value) || seen[key]++) block_bad = 1
            else block = block "    " name " " value "\n"
        }
        END {
            if (mode == "snapshot" && NR < 4) fatal = 1
            finish()
            if (fatal) exit 2
            print eligible+0, excluded+0, structural+0
        }
    ' "$input"
}

ssh_snapshot_validate() {
    local payload="$1" file="${2:-$SSH_SNAPSHOT_FILE}" metrics expected status excluded canonical
    SSH_SNAPSHOT_STATUS=""; SSH_SNAPSHOT_COUNT=0; SSH_SNAPSHOT_EXCLUDED=0
    [[ -e "$file" || -L "$file" ]] || return 1
    [[ ! -L "$file" && -f "$file" && -r "$file" &&
       ! -L "${file%/*}" && -d "${file%/*}" &&
       "$(stat -f '%u' "${file%/*}" 2>/dev/null)" == "$(id -u)" &&
       "$(stat -f '%u' "$file" 2>/dev/null)" == "$(id -u)" &&
       "$(stat -f '%Lp' "$file" 2>/dev/null)" == 600 ]] || return 2
    metrics="$(ssh_config_parse "$file" "$payload" snapshot)" || return 2
    read -r SSH_SNAPSHOT_COUNT expected canonical <<< "$metrics"
    [[ "$expected" == 0 && "$canonical" == 0 ]] || return 2
    status="$(sed -n '2p' "$file")" || return 2
    excluded="$(sed -n '3p' "$file")" || return 2
    status="${status#\# status: }"
    excluded="${excluded#\# excluded-profiles: }"
    case "$status" in
        ready) [[ $SSH_SNAPSHOT_COUNT -gt 0 && "$excluded" == 0 ]] || return 2 ;;
        partial) [[ $SSH_SNAPSHOT_COUNT -gt 0 && $excluded -gt 0 ]] || return 2 ;;
        unsupported) [[ $SSH_SNAPSHOT_COUNT -eq 0 && $excluded -gt 0 ]] || return 2 ;;
        absent-directory|absent-config|empty|external)
            [[ $SSH_SNAPSHOT_COUNT -eq 0 && "$excluded" == 0 ]] || return 2 ;;
        *) return 2 ;;
    esac
    canonical="$(mktemp)" || return 2
    { printf '# toolkit-ssh-snapshot: 1\n# status: %s\n# excluded-profiles: %s\n\n' "$status" "$excluded"; cat "$payload"; } > "$canonical" || { rm -f "$canonical"; return 2; }
    cmp -s "$file" "$canonical"
    expected=$?
    rm -f "$canonical"
    [[ $expected -eq 0 ]] || return 2
    SSH_SNAPSHOT_STATUS="$status"; SSH_SNAPSHOT_EXCLUDED="$excluded"
    return 0
}

ssh_snapshot_write() {
    local output="$1" status="$2" excluded="$3" payload="$4" checked
    { printf '# toolkit-ssh-snapshot: 1\n# status: %s\n# excluded-profiles: %s\n\n' "$status" "$excluded"; cat "$payload"; } > "$output" || return 2
    chmod 600 "$output" || return 2
    checked="$(mktemp)" || return 2
    ssh_snapshot_validate "$checked" "$output"
    local result=$?
    rm -f "$checked"
    return "$result"
}

ssh_target_inspect() {
    local payload="$1" directory="$HOME/.ssh" target="$HOME/.ssh/config"
    SSH_TARGET_STATUS="error"
    [[ "$HOME" == /* && -d "$HOME" && ! -L "$HOME" &&
       "$(stat -f '%u' "$HOME" 2>/dev/null)" == "$(id -u)" ]] || return 2
    if [[ ! -e "$directory" && ! -L "$directory" ]]; then SSH_TARGET_STATUS=absent-directory; return 0; fi
    if [[ -L "$directory" ]]; then SSH_TARGET_STATUS=external; return 1; fi
    [[ -d "$directory" ]] || return 2
    if [[ "$(stat -f '%u' "$directory" 2>/dev/null)" != "$(id -u)" ||
          "$(stat -f '%Lp' "$directory" 2>/dev/null)" != 700 ]]; then SSH_TARGET_STATUS=external; return 1; fi
    if [[ ! -e "$target" && ! -L "$target" ]]; then SSH_TARGET_STATUS=absent-config; return 0; fi
    if [[ -L "$target" ]]; then SSH_TARGET_STATUS=external; return 1; fi
    [[ -f "$target" && -r "$target" ]] || return 2
    if [[ "$(stat -f '%u' "$target" 2>/dev/null)" != "$(id -u)" ||
          "$(stat -f '%Lp' "$target" 2>/dev/null)" != 600 ]]; then SSH_TARGET_STATUS=external; return 1; fi
    cmp -s "$target" "$payload"
    local comparison=$?
    case "$comparison" in
        0) SSH_TARGET_STATUS=identical ;;
        1) SSH_TARGET_STATUS=different ;;
        *) return 2 ;;
    esac
    return 0
}

ssh_configuration_inspect() {
    local payload="$1" result
    SSH_SOURCE_PARTIAL=false
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
    if [[ $result -eq 1 || "$SSH_TARGET_STATUS" == different ]]; then
        warning "Existing SSH configuration is preserved"
        return 1
    fi
    return 0
}

preview_ssh_configuration() {
    local payload result
    payload="$(mktemp)" || return 2
    ssh_configuration_inspect "$payload"; result=$?
    if [[ $result -eq 0 && "$SSH_TARGET_STATUS" == absent-* ]]; then
        preview_action "Would restore SSH configuration: $SSH_SNAPSHOT_COUNT eligible profiles"
    fi
    rm -f "$payload"
    [[ $result -ne 3 ]] || return 0
    [[ $result -ne 0 || "$SSH_SOURCE_PARTIAL" != true ]] || return 1
    return "$result"
}

bootstrap_ssh_configuration() {
    local payload result target="$HOME/.ssh/config" directory="$HOME/.ssh" temporary
    payload="$(mktemp)" || return 2
    ssh_configuration_inspect "$payload"; result=$?
    if [[ $result -ne 0 ]]; then rm -f "$payload"; [[ $result -ne 3 ]] || return 0; return "$result"; fi
    if [[ "$SSH_TARGET_STATUS" == identical ]]; then
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
    rm -f "$temporary" || { rm -f "$payload"; error "Failed to clean SSH staging file"; return 2; }
    ssh_target_inspect "$payload"; result=$?
    rm -f "$payload"
    [[ $result -eq 0 && "$SSH_TARGET_STATUS" == identical ]] || { error "SSH configuration verification failed"; return 2; }
    success "SSH configuration restored"
    [[ "$SSH_SOURCE_PARTIAL" != true ]] || return 1
    return 0
}
