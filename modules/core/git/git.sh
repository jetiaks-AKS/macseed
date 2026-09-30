#!/bin/bash

GIT_CONFIGURATION_FILE="${BLUEPRINT_GENERATED_DIR:-config/generated}/git.conf"
GIT_CONFIGURATION_KEYS=(user.name user.email init.defaultBranch pull.rebase core.editor user.useConfigOnly pull.ff)
GIT_CONFIGURATION_SET=(false false false false false false false)
GIT_CONFIGURATION_VALUES=("" "" "" "" "" "" "")
GIT_CONFIGURATION_SELECTED=(true true true true true true true)
GIT_CONFIGURATION_ACTIONS=()
GIT_GLOBAL_COUNTS=()
GIT_GLOBAL_VALUES=()
GIT_GLOBAL_ORIGINS=()
GIT_GLOBAL_WRITE_PATH=""
GIT_GLOBAL_EXTERNAL=false

git_configuration_index() {
    local normalized
    normalized="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
        user.name) echo 0 ;;
        user.email) echo 1 ;;
        init.defaultbranch) echo 2 ;;
        pull.rebase) echo 3 ;;
        core.editor) echo 4 ;;
        user.useconfigonly) echo 5 ;;
        pull.ff) echo 6 ;;
        *) return 1 ;;
    esac
}

git_configuration_scope_selected() {
    if declare -F blueprint_exists >/dev/null && blueprint_exists &&
       declare -F blueprint_item_section_exists >/dev/null &&
       blueprint_item_section_exists git-configuration &&
       [[ -z "$(blueprint_selected_items git-configuration)" ]]; then
        return 1
    fi
    return 0
}

git_configuration_editor_binary() {
    case "$1" in
        vi|vim|nano|nvim) printf '%s\n' "$1" ;;
        'code --wait') printf '%s\n' code ;;
        *) return 1 ;;
    esac
}

git_configuration_editor_available() {
    local binary path
    binary="$(git_configuration_editor_binary "$1")" || return 1
    path="$(type -P "$binary")" || return 1
    [[ -f "$path" && -x "$path" ]]
}

git_configuration_normalize_boolean() {
    local normalized
    normalized="$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')"
    case "$normalized" in
        ""|true|yes|on|1) printf '%s\n' true ;;
        false|no|off|0) printf '%s\n' false ;;
        *) return 1 ;;
    esac
}

git_configuration_validate_value() {
    local key="$1" value="$2"
    case "$key" in
        user.name|user.email)
            [[ -n "$value" && "$value" =~ [^[:space:]] &&
               ! "$value" =~ [[:cntrl:]] ]]
            ;;
        init.defaultBranch)
            git check-ref-format --branch "$value" >/dev/null 2>&1
            ;;
        pull.rebase)
            case "$value" in true|false|merges|interactive) return 0 ;; esac
            return 1
            ;;
        core.editor)
            git_configuration_editor_binary "$value" >/dev/null
            ;;
        user.useConfigOnly)
            [[ "$value" == true || "$value" == false ]]
            ;;
        pull.ff)
            [[ "$value" == true || "$value" == false || "$value" == only ]]
            ;;
        *) return 1 ;;
    esac
}

# Return 1 for external ownership and 2 for an observation error.
git_global_observe() {
    local mode="${1:-target}"
    local dot="$HOME/.gitconfig" xdg_root="${XDG_CONFIG_HOME:-$HOME/.config}"
    local xdg="$xdg_root/git/config" path parent owner stream
    local scope origin record key value index
    GIT_GLOBAL_COUNTS=(0 0 0 0 0 0 0)
    GIT_GLOBAL_VALUES=("" "" "" "" "" "" "")
    GIT_GLOBAL_ORIGINS=("" "" "" "" "" "" "")
    GIT_GLOBAL_WRITE_PATH=""
    GIT_GLOBAL_EXTERNAL=false

    [[ -n "$HOME" && "$HOME" == /* && -d "$HOME" && ! -L "$HOME" ]] || return 2
    if [[ -n "${GIT_CONFIG_GLOBAL+x}" ]]; then
        GIT_GLOBAL_EXTERNAL=true
        return 1
    fi
    [[ "$xdg_root" == /* ]] || return 2
    if [[ -L "$xdg_root" || -L "$xdg_root/git" ]]; then
        GIT_GLOBAL_EXTERNAL=true
        return 1
    fi
    for path in "$dot" "$xdg"; do
        parent="${path%/*}"
        if [[ -L "$path" || -L "$parent" ]]; then
            GIT_GLOBAL_EXTERNAL=true
            return 1
        fi
        if [[ -e "$path" ]]; then
            [[ -f "$path" && -r "$path" ]] || return 2
            owner="$(stat -f '%u' "$path")" || return 2
            if [[ "$owner" != "$(id -u)" ]]; then
                GIT_GLOBAL_EXTERNAL=true
                return 1
            fi
        fi
    done
    if [[ "$mode" == target ]]; then
        [[ ! -e "$dot" || -w "$dot" ]] || return 2
    fi
    GIT_GLOBAL_WRITE_PATH="$dot"
    if [[ ! -e "$dot" && -e "$xdg" ]]; then
        if [[ "$mode" == target ]]; then
            [[ -w "$xdg" ]] || return 2
        fi
        GIT_GLOBAL_WRITE_PATH="$xdg"
    fi
    [[ -e "$dot" || -e "$xdg" ]] || return 0

    stream="$(mktemp)" || return 2
    # Git's --global query can select ~/.gitconfig when both global files
    # exist. Probe that layer, then inventory each validated physical file.
    if ! git config --global --no-includes --null --list --show-origin --show-scope > "$stream" 2>/dev/null; then
        rm -f "$stream"
        return 2
    fi
    for path in "$xdg" "$dot"; do
        [[ -e "$path" ]] || continue
        if ! git config --file "$path" --no-includes --null --list --show-origin --show-scope > "$stream" 2>/dev/null; then
            rm -f "$stream"
            return 2
        fi
        while IFS= read -r -d '' scope &&
              IFS= read -r -d '' origin &&
              IFS= read -r -d '' record; do
            [[ "$scope" == command && "$origin" == "file:$path" &&
               "$record" == *$'\n'* ]] || {
                rm -f "$stream"
                return 2
            }
            key="${record%%$'\n'*}"
            value="${record#*$'\n'}"
            case "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" in
                include.path|includeif.*) GIT_GLOBAL_EXTERNAL=true ;;
            esac
            index="$(git_configuration_index "$key")" || continue
            GIT_GLOBAL_COUNTS[$index]=$((GIT_GLOBAL_COUNTS[$index] + 1))
            GIT_GLOBAL_VALUES[$index]="$value"
            GIT_GLOBAL_ORIGINS[$index]="$path"
        done < "$stream"
    done
    rm -f "$stream"
    [[ "$GIT_GLOBAL_EXTERNAL" == false ]] || return 1
    return 0
}

load_git_configuration() {
    local config_file="${1:-$GIT_CONFIGURATION_FILE}" listed key index value stream
    local counts=(0 0 0 0 0 0 0)
    [[ -f "$config_file" && -r "$config_file" ]] || {
        error "$config_file not found or unreadable; run Discovery again"
        return 2
    }
    stream="$(mktemp)" || return 2
    if ! git config --file "$config_file" --no-includes --null --list > "$stream" 2>/dev/null; then
        rm -f "$stream"
        error "Invalid generated Git configuration; run Discovery again"
        return 2
    fi
    GIT_CONFIGURATION_SET=(false false false false false false false)
    GIT_CONFIGURATION_VALUES=("" "" "" "" "" "" "")
    GIT_CONFIGURATION_SELECTED=(true true true true true true true)
    while IFS= read -r -d '' listed; do
        [[ "$listed" == *$'\n'* ]] || { rm -f "$stream"; return 2; }
        key="${listed%%$'\n'*}"
        value="${listed#*$'\n'}"
        index="$(git_configuration_index "$key")" || {
            rm -f "$stream"
            error "Unknown generated Git configuration key: $key"
            return 2
        }
        counts[$index]=$((counts[$index] + 1))
        if [[ ${counts[$index]} -ne 1 ]] ||
           ! git_configuration_validate_value "${GIT_CONFIGURATION_KEYS[$index]}" "$value"; then
            rm -f "$stream"
            error "Invalid or duplicate generated Git setting: $key"
            return 2
        fi
        GIT_CONFIGURATION_SET[$index]=true
        GIT_CONFIGURATION_VALUES[$index]="$value"
    done < "$stream"
    rm -f "$stream"
    if declare -F blueprint_exists >/dev/null && blueprint_exists &&
       declare -F blueprint_item_section_exists >/dev/null &&
       blueprint_item_section_exists git-configuration; then
        for index in 0 1 2 3 4 5 6; do
            blueprint_item_selected git-configuration "${GIT_CONFIGURATION_KEYS[$index]}" ||
                GIT_CONFIGURATION_SELECTED[$index]=false
        done
    fi
    return 0
}

is_git_installed() { command -v git >/dev/null 2>&1; }
check_git() {
    if is_git_installed; then success "Git already installed"; return 0; fi
    error "Git is not installed"
    return 2
}

inspect_git_configuration() {
    local index key warnings=false result
    GIT_CONFIGURATION_ACTIONS=(skip skip skip skip skip skip skip)
    load_git_configuration || return 2
    git_global_observe
    result=$?
    if [[ $result -eq 1 ]]; then
        warning "Global Git configuration is externally managed"
        return 1
    fi
    if [[ $result -ne 0 ]]; then
        error "Failed to inspect direct global Git configuration"
        return 2
    fi
    for index in 0 1 2 3 4 5 6; do
        [[ "${GIT_CONFIGURATION_SET[$index]}" == true &&
           "${GIT_CONFIGURATION_SELECTED[$index]}" == true ]] || continue
        key="${GIT_CONFIGURATION_KEYS[$index]}"
        if [[ ${GIT_GLOBAL_COUNTS[$index]} -gt 1 ]]; then
            warning "Multiple direct global Git values: $key"
            warnings=true
        elif [[ ${GIT_GLOBAL_COUNTS[$index]} -eq 1 ]]; then
            if [[ "${GIT_GLOBAL_VALUES[$index]}" != "${GIT_CONFIGURATION_VALUES[$index]}" ]]; then
                warning "Existing Git setting differs; preserving: $key"
                warnings=true
            fi
        elif [[ "$key" == core.editor ]] &&
             ! git_configuration_editor_available "${GIT_CONFIGURATION_VALUES[$index]}"; then
            warning "Git editor dependency unavailable: $key"
            warnings=true
        else
            GIT_CONFIGURATION_ACTIONS[$index]=create
        fi
    done
    [[ "$warnings" == false ]]
}

check_git_configuration() {
    local result index
    inspect_git_configuration
    result=$?
    [[ $result -ne 2 ]] || return 2
    for index in 0 1 2 3 4 5 6; do
        [[ "${GIT_CONFIGURATION_ACTIONS[$index]:-skip}" != create ]] || return 1
    done
    return "$result"
}

preview_git_configuration() {
    local result index
    inspect_git_configuration
    result=$?
    [[ $result -ne 2 ]] || return 2
    for index in 0 1 2 3 4 5 6; do
        [[ "${GIT_CONFIGURATION_ACTIONS[$index]:-skip}" == create ]] || continue
        preview_action "Would set Git setting: ${GIT_CONFIGURATION_KEYS[$index]}"
    done
    return "$result"
}

configure_git() {
    local result index key expected_path warnings=false
    inspect_git_configuration
    result=$?
    [[ $result -ne 2 ]] || return 2
    [[ "$GIT_GLOBAL_EXTERNAL" == false ]] || return 1
    [[ $result -eq 0 ]] || warnings=true
    local planned=("${GIT_CONFIGURATION_ACTIONS[@]}")
    for index in 0 1 2 3 4 5 6; do
        [[ "${planned[$index]:-skip}" == create ]] || continue
        key="${GIT_CONFIGURATION_KEYS[$index]}"
        git_global_observe
        result=$?
        if [[ $result -eq 1 ]]; then
            warning "Global Git configuration became externally managed"
            warnings=true
            continue
        fi
        if [[ $result -ne 0 ]]; then
            error "Failed to inspect direct global Git configuration"
            return 2
        fi
        if [[ ${GIT_GLOBAL_COUNTS[$index]} -ne 0 ]] ||
           { [[ "$key" == core.editor ]] &&
             ! git_configuration_editor_available "${GIT_CONFIGURATION_VALUES[$index]}"; }; then
            warning "Git setting changed or dependency unavailable: $key"
            warnings=true
            continue
        fi
        expected_path="$GIT_GLOBAL_WRITE_PATH"
        action "Configuring Git setting: $key"
        if ! git config --global --add "$key" "${GIT_CONFIGURATION_VALUES[$index]}"; then
            declare -F verification_operation_hook >/dev/null && verification_operation_hook git-configuration "$key" create failure
            error "Failed to configure Git setting: $key"
            return 2
        fi
        # Shared lifecycle flag is read by the calling module wrapper.
        # shellcheck disable=SC2034
        MODULE_CHANGED=true
        declare -F verification_operation_hook >/dev/null && verification_operation_hook git-configuration "$key" create success
        git_global_observe
        result=$?
        if [[ $result -ne 0 || "$GIT_GLOBAL_WRITE_PATH" != "$expected_path" ||
              ${GIT_GLOBAL_COUNTS[$index]} -ne 1 ||
              "${GIT_GLOBAL_ORIGINS[$index]}" != "$expected_path" ||
              "${GIT_GLOBAL_VALUES[$index]}" != "${GIT_CONFIGURATION_VALUES[$index]}" ]]; then
            local verify_result=1
            [[ $result -eq 0 ]] || verify_result=2
            declare -F verification_post_hook >/dev/null && verification_post_hook "$verify_result"
            error "Git configuration verification failed: $key"
            return 2
        fi
    done
    [[ "$warnings" == false ]] || return 1
    success "Git configuration verified"
    return 0
}

# Compare direct global values using the production provenance reader. Source
# mode omits target writability gates; mutation policy continues using target.
verify_git_configuration() {
    verification_category_selected git-configuration || return 0
    local keys="" index key result
    if ! git_configuration_scope_selected; then
        verification_coverage git-configuration scope excluded unknown
        return 0
    fi
    load_git_configuration || { verification_input_error git-configuration; return 0; }
    for index in 0 1 2 3 4 5 6; do
        [[ "${GIT_CONFIGURATION_SET[$index]}" != true ]] || keys="${keys}${keys:+$'\n'}${GIT_CONFIGURATION_KEYS[$index]}"
    done
    verification_select_subjects git-configuration "$keys" || return 2
    [[ ${#GV_SUBJECTS[@]} -gt 0 ]] || return 0
    git_global_observe source
    result=$?
    for key in "${GV_SUBJECTS[@]}"; do
        index="$(git_configuration_index "$key")" || return 2
        case "$result" in
            1) verification_result git-configuration "$key" direct_global_value 2 external_management ;;
            0)
                if [[ ${GIT_GLOBAL_COUNTS[$index]} -eq 1 &&
                      "${GIT_GLOBAL_VALUES[$index]}" == "${GIT_CONFIGURATION_VALUES[$index]}" ]]; then
                    verification_result git-configuration "$key" direct_global_value 0
                else
                    if [[ ${GIT_GLOBAL_COUNTS[$index]} -eq 0 ]]; then
                        verification_result git-configuration "$key" direct_global_value 1 '' absent
                    else
                        verification_result git-configuration "$key" direct_global_value 1 '' different
                    fi
                fi ;;
            *) verification_result git-configuration "$key" direct_global_value 2 ;;
        esac
    done
}
