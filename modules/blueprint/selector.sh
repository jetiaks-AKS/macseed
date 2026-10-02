#!/bin/bash

# ==========================================
# Interactive Blueprint Selector
# ==========================================

BLUEPRINT_PAGE_SIZE=20
BLUEPRINT_SELECTOR_ITEMS=()
BLUEPRINT_SELECTOR_LABELS=()
BLUEPRINT_SELECTOR_SELECTED=()
BLUEPRINT_PARSED_INDICES=()
BLUEPRINT_SELECTOR_TEMP_FILE=""

blueprint_selector_cleanup() {
    [[ -n "$BLUEPRINT_SELECTOR_TEMP_FILE" ]] &&
        rm -f "$BLUEPRINT_SELECTOR_TEMP_FILE"
}

blueprint_selector_generated_ready() {
    local section
    local file

    for section in homebrew-packages homebrew-casks app-store \
        vscode-extensions workspace-folders git-repositories; do
        if blueprint_exists && [[ -z "$(blueprint_selected_items "$section")" ]]; then
            continue
        fi
        file="$(blueprint_generated_file "$section")" || return 2
        [[ -f "$file" && -r "$file" ]] || {
            error "Generated configuration is unavailable."
            info "Run: ./bootstrap.sh --discover"
            return 2
        }
    done

    return 0
}

blueprint_selector_load_items() {
    local section="$1"
    local file
    local first
    local second

    BLUEPRINT_SELECTOR_ITEMS=()
    BLUEPRINT_SELECTOR_LABELS=()
    BLUEPRINT_SELECTOR_SELECTED=()
    file="$(blueprint_generated_file "$section")" || return 2
    if [[ ! -f "$file" ]] && blueprint_exists &&
       [[ -z "$(blueprint_selected_items "$section")" ]]; then
        return 0
    fi

    case "$section" in
        homebrew-packages|homebrew-casks|vscode-extensions)
            while IFS= read -r first || [[ -n "$first" ]]; do
                [[ -z "$first" || "$first" == \#* ]] && continue
                BLUEPRINT_SELECTOR_ITEMS+=("$first")
                BLUEPRINT_SELECTOR_LABELS+=("$first")
            done < "$file"
            ;;
        app-store)
            while IFS='|' read -r first second || [[ -n "$first" ]]; do
                [[ -z "$first" || "$first" == \#* ]] && continue
                BLUEPRINT_SELECTOR_ITEMS+=("$first")
                BLUEPRINT_SELECTOR_LABELS+=("${second:-$first}")
            done < "$file"
            ;;
        workspace-folders)
            while IFS= read -r first || [[ -n "$first" ]]; do
                [[ -z "$first" || "$first" == \#* ]] && continue
                BLUEPRINT_SELECTOR_ITEMS+=("$first")
                BLUEPRINT_SELECTOR_LABELS+=("$first")
            done < <(blueprint_workspace_folder_candidates "$file")
            ;;
        git-repositories)
            while IFS= read -r first; do
                BLUEPRINT_SELECTOR_ITEMS+=("$first")
                BLUEPRINT_SELECTOR_LABELS+=("$first")
            done < <(config_sections "$file")
            ;;
        git-configuration)
            load_git_configuration || return 2
            local index
            for index in 0 1 2 3 4 5 6; do
                [[ "${GIT_CONFIGURATION_SET[$index]}" == true ]] || continue
                BLUEPRINT_SELECTOR_ITEMS+=("${GIT_CONFIGURATION_KEYS[$index]}")
                BLUEPRINT_SELECTOR_LABELS+=("${GIT_CONFIGURATION_KEYS[$index]}")
            done
            ;;
    esac

    local index
    for ((index = 0; index < ${#BLUEPRINT_SELECTOR_ITEMS[@]}; index++)); do
        if blueprint_exists &&
           { [[ "$section" != git-configuration ]] ||
             blueprint_item_section_exists git-configuration; }; then
            if blueprint_item_selected "$section" "${BLUEPRINT_SELECTOR_ITEMS[$index]}"; then
                BLUEPRINT_SELECTOR_SELECTED+=(true)
            else
                BLUEPRINT_SELECTOR_SELECTED+=(false)
            fi
        else
            BLUEPRINT_SELECTOR_SELECTED+=(true)
        fi
    done
}

blueprint_selector_set_all() {
    local value="$1"
    local index

    for ((index = 0; index < ${#BLUEPRINT_SELECTOR_SELECTED[@]}; index++)); do
        BLUEPRINT_SELECTOR_SELECTED[$index]="$value"
    done
}

blueprint_selector_parse_numbers() {
    local input="$1"
    local count="$2"
    local normalized
    local token
    local start
    local end
    local number
    local seen=" "

    BLUEPRINT_PARSED_INDICES=()
    normalized="${input//,/ }"
    [[ -n "${normalized//[[:space:]]/}" ]] || return 1

    for token in $normalized; do
        if [[ "$token" =~ ^([1-9][0-9]*)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="$start"
        elif [[ "$token" =~ ^([1-9][0-9]*)-([1-9][0-9]*)$ ]]; then
            start="${BASH_REMATCH[1]}"
            end="${BASH_REMATCH[2]}"
            [[ $start -le $end ]] || return 1
        else
            return 1
        fi

        [[ $end -le $count ]] || return 1

        for ((number = start; number <= end; number++)); do
            if [[ "$seen" != *" $number "* ]]; then
                BLUEPRINT_PARSED_INDICES+=("$((number - 1))")
                seen="${seen}${number} "
            fi
        done
    done

    return 0
}

blueprint_selector_select_items() {
    local title="$1"
    local count="${#BLUEPRINT_SELECTOR_ITEMS[@]}"
    local page=0
    local pages=$(((count + BLUEPRINT_PAGE_SIZE - 1) / BLUEPRINT_PAGE_SIZE))
    local input
    local index
    local start
    local end

    while true; do
        start=$((page * BLUEPRINT_PAGE_SIZE))
        end=$((start + BLUEPRINT_PAGE_SIZE))
        [[ $end -gt $count ]] && end=$count

        echo
        echo "$title — $((page + 1))/$pages"
        echo

        for ((index = start; index < end; index++)); do
            if [[ "${BLUEPRINT_SELECTOR_SELECTED[$index]}" == true ]]; then
                printf '%3d. [x] %s\n' "$((index + 1))" "${BLUEPRINT_SELECTOR_LABELS[$index]}"
            else
                printf '%3d. [ ] %s\n' "$((index + 1))" "${BLUEPRINT_SELECTOR_LABELS[$index]}"
            fi
        done

        echo
        echo "Toggle items: 1,3,5   1 3 5   5-9   1,3,7-10"
        echo "[N] Next  [P] Previous  [A] All  [0] None  [D] Done"
        echo "Enter = Done"
        printf '> (Q cancels): '
        IFS= read -r input || return 1

        case "$input" in
            [qQ]) return 3 ;; # Propagate cancellation to blueprint_selector_run.
            "")
                return 0
                ;;
            [nN])
                [[ $page -lt $((pages - 1)) ]] && ((page++))
                ;;
            [pP])
                [[ $page -gt 0 ]] && ((page--))
                ;;
            [aA])
                blueprint_selector_set_all true
                ;;
            0)
                blueprint_selector_set_all false
                ;;
            [dD])
                return 0
                ;;
            *)
                if ! blueprint_selector_parse_numbers "$input" "$count"; then
                    error "Invalid selection."
                    continue
                fi

                for index in "${BLUEPRINT_PARSED_INDICES[@]}"; do
                    if [[ "${BLUEPRINT_SELECTOR_SELECTED[$index]}" == true ]]; then
                        BLUEPRINT_SELECTOR_SELECTED[$index]=false
                    else
                        BLUEPRINT_SELECTOR_SELECTED[$index]=true
                    fi
                done
                ;;
        esac
    done
}

blueprint_selector_choose_items() {
    local section="$1"
    local title="$2"
    local input

    blueprint_selector_load_items "$section" || return 2
    [[ ${#BLUEPRINT_SELECTOR_ITEMS[@]} -gt 0 ]] || return 0

    while true; do
        echo
        echo "$title (${#BLUEPRINT_SELECTOR_ITEMS[@]} found)"
        echo
        echo "[A] All"
        echo "[N] None"
        echo "[E] Edit"
        echo
        printf 'Choice [A/N/E] (Enter keeps current, Q cancels): '
        IFS= read -r input || return 1

        case "$input" in
            [qQ]) return 3 ;; # Propagate cancellation to blueprint_selector_run.
            "")
                return 0
                ;;
            [aA])
                blueprint_selector_set_all true
                return 0
                ;;
            [nN])
                blueprint_selector_set_all false
                return 0
                ;;
            [eE])
                blueprint_selector_select_items "$title"
                return $?
                ;;
            *)
                error "Choose A, N, or E."
                ;;
        esac
    done
}

blueprint_selector_store_items() {
    local variable="$1"
    local values=""
    local index

    for ((index = 0; index < ${#BLUEPRINT_SELECTOR_ITEMS[@]}; index++)); do
        if [[ "${BLUEPRINT_SELECTOR_SELECTED[$index]}" == true ]]; then
            values="${values}${values:+
}${BLUEPRINT_SELECTOR_ITEMS[$index]}"
        fi
    done

    printf -v "$variable" '%s' "$values"
}

blueprint_selector_prompt_category() {
    local category="$1"
    local title="$2"
    local variable="$3"
    local current=true
    local input
    local prompt
    local source_file=""

    case "$category" in
        git-configuration) source_file="$BLUEPRINT_GENERATED_DIR/git.conf" ;;
        ssh-configuration) source_file="$BLUEPRINT_GENERATED_DIR/ssh/config.snapshot" ;;
        vscode-settings) source_file="$BLUEPRINT_GENERATED_DIR/vscode/settings.json" ;;
        shell-zsh) source_file="$BLUEPRINT_GENERATED_DIR/shell/zshrc.snapshot" ;;
        macos-*) source_file="$BLUEPRINT_GENERATED_DIR/macos/${category#macos-}.conf" ;;
    esac
    if blueprint_exists && ! blueprint_category_enabled "$category" &&
       [[ -n "$source_file" && ! -f "$source_file" ]]; then
        printf -v "$variable" '%s' false
        info "$title: unavailable"
        return 0
    fi

    if blueprint_exists && ! blueprint_category_enabled "$category"; then
        current=false
    fi

    while true; do
        [[ "$current" == true ]] && prompt='[Y/n]' || prompt='[y/N]'
        echo
        echo "$title"
        printf 'Restore? %s (Q cancels): ' "$prompt"
        IFS= read -r input || return 1

        case "$input" in
            [qQ]) return 3 ;; # Propagate cancellation to blueprint_selector_run.
            "") ;;
            [yY]|[yY][eE][sS]) current=true ;;
            [nN]|[nN][oO]) current=false ;;
            *) error "Choose Y or N."; continue ;;
        esac

        printf -v "$variable" '%s' "$current"
        return 0
    done
}

blueprint_selector_count_lines() {
    local value="$1"
    [[ -n "$value" ]] && printf '%s\n' "$value" | wc -l | tr -d ' ' || echo 0
}

blueprint_selector_yes_no() {
    [[ "$1" == true ]] && echo Yes || echo No
}

blueprint_selector_write() {
    local output_file="$1"

    {
        echo '[categories]'
        echo "git-configuration=\"$BLUEPRINT_GIT_CONFIGURATION\""
        echo "ssh-configuration=\"$BLUEPRINT_SSH_CONFIGURATION\""
        echo "vscode-settings=\"$BLUEPRINT_VSCODE_SETTINGS\""
        echo "shell-zsh=\"$BLUEPRINT_SHELL_ZSH\""
        echo "macos-finder=\"$BLUEPRINT_MACOS_FINDER\""
        echo "macos-dock=\"$BLUEPRINT_MACOS_DOCK\""
        echo "macos-windows=\"$BLUEPRINT_MACOS_WINDOWS\""
        echo "macos-keyboard=\"$BLUEPRINT_MACOS_KEYBOARD\""
        echo "macos-trackpad=\"$BLUEPRINT_MACOS_TRACKPAD\""
        echo "macos-screenshots=\"$BLUEPRINT_MACOS_SCREENSHOTS\""
        echo
        for section in homebrew-packages homebrew-casks app-store vscode-extensions workspace-folders git-repositories git-configuration; do
            echo "[$section]"
            case "$section" in
                homebrew-packages) printf '%s\n' "$BLUEPRINT_HOME_BREW_PACKAGES" ;;
                homebrew-casks) printf '%s\n' "$BLUEPRINT_HOME_BREW_CASKS" ;;
                app-store) printf '%s\n' "$BLUEPRINT_APP_STORE" ;;
                vscode-extensions) printf '%s\n' "$BLUEPRINT_VSCODE_EXTENSIONS" ;;
                workspace-folders) printf '%s\n' "$BLUEPRINT_WORKSPACE_FOLDERS" ;;
                git-repositories) printf '%s\n' "$BLUEPRINT_GIT_REPOSITORIES" ;;
                git-configuration) printf '%s\n' "$BLUEPRINT_GIT_CONFIGURATION_ITEMS" ;;
            esac
            echo
        done
    } > "$output_file"
}

blueprint_selector_run() {
    local result
    blueprint_selector_edit
    result=$?
    if [[ $result -eq 3 ]]; then
        if [[ -n "$BLUEPRINT_SELECTOR_TEMP_FILE" ]]; then
            blueprint_selector_cleanup
            BLUEPRINT_SELECTOR_TEMP_FILE=""
            trap - INT TERM
        fi
        log "[BLUEPRINT] RESULT: CANCELLED"
        success "Blueprint changes cancelled; no file changes were saved"
        return 0
    fi
    return "$result"
}

blueprint_selector_edit() {
    BLUEPRINT_SELECTOR_SAVED=false
    log "[BLUEPRINT] START"

    if blueprint_exists; then
        blueprint_validate_syntax || return 2
    fi
    blueprint_selector_generated_ready || return 2
    log "[BLUEPRINT] Generated configuration: Ready"

    if blueprint_exists; then
        blueprint_validate
        local validation_result=$?
        [[ $validation_result -ne 2 ]] || return 2
        if [[ $validation_result -eq 0 ]]; then
            log "[BLUEPRINT] Existing configuration: Valid"
        fi
    fi

    echo
    echo "=========================================="
    echo " Blueprint"
    echo "=========================================="

    if blueprint_exists; then
        echo
        echo "Editing existing Blueprint: $BLUEPRINT_FILE"
    else
        echo
        echo "Creating new Blueprint"
    fi

    echo
    echo "Applications"
    blueprint_selector_choose_items homebrew-packages "Homebrew Packages" || return $?
    blueprint_selector_store_items BLUEPRINT_HOME_BREW_PACKAGES
    blueprint_selector_choose_items homebrew-casks "Homebrew Casks" || return $?
    blueprint_selector_store_items BLUEPRINT_HOME_BREW_CASKS
    blueprint_selector_choose_items app-store "App Store Applications" || return $?
    blueprint_selector_store_items BLUEPRINT_APP_STORE
    blueprint_selector_choose_items vscode-extensions "VS Code Extensions" || return $?
    blueprint_selector_store_items BLUEPRINT_VSCODE_EXTENSIONS

    echo
    echo "Workspace"
    blueprint_selector_choose_items workspace-folders "Workspace Folders" || return $?
    blueprint_selector_store_items BLUEPRINT_WORKSPACE_FOLDERS
    blueprint_selector_choose_items git-repositories "Git Repositories" || return $?
    blueprint_selector_store_items BLUEPRINT_GIT_REPOSITORIES

    echo
    echo "Settings"
    blueprint_selector_prompt_category git-configuration "Git Configuration" BLUEPRINT_GIT_CONFIGURATION || return $?
    BLUEPRINT_GIT_CONFIGURATION_ITEMS=""
    if [[ "$BLUEPRINT_GIT_CONFIGURATION" == true ]]; then
        blueprint_selector_choose_items git-configuration "Git settings" || return $?
        blueprint_selector_store_items BLUEPRINT_GIT_CONFIGURATION_ITEMS
    fi
    local ssh_payload ssh_result
    ssh_payload="$(mktemp)" || return 2
    ssh_snapshot_validate "$ssh_payload"
    ssh_result=$?
    rm -f "$ssh_payload"
    if [[ $ssh_result -eq 2 ]]; then
        error "Generated SSH snapshot is invalid"
        return 2
    fi
    if [[ $ssh_result -eq 0 && ( "$SSH_SNAPSHOT_STATUS" == ready || "$SSH_SNAPSHOT_STATUS" == partial ) ]]; then
        info "SSH configuration: $SSH_SNAPSHOT_COUNT eligible profiles"
        blueprint_selector_prompt_category ssh-configuration "SSH Configuration" BLUEPRINT_SSH_CONFIGURATION || return $?
    else
        BLUEPRINT_SSH_CONFIGURATION=false
        info "SSH configuration: unavailable"
    fi
    blueprint_selector_prompt_category vscode-settings "VS Code Settings" BLUEPRINT_VSCODE_SETTINGS || return $?
    local zsh_status
    zsh_snapshot_validate
    zsh_status=$?
    if [[ $zsh_status -eq 2 ]]; then
        error "Generated Zsh snapshot is invalid"
        return 2
    fi
    if [[ $zsh_status -eq 0 && "$ZSH_SNAPSHOT_STATUS" == eligible ]]; then
        blueprint_selector_prompt_category shell-zsh "Shell / Zsh configuration" BLUEPRINT_SHELL_ZSH || return $?
    else
        BLUEPRINT_SHELL_ZSH=false
        if [[ $zsh_status -eq 1 || "$ZSH_SNAPSHOT_STATUS" == absent ]]; then
            info "Shell / Zsh configuration: unavailable"
        else
            info "Shell / Zsh configuration: excluded ($ZSH_SNAPSHOT_REASON)"
        fi
    fi
    blueprint_selector_prompt_category macos-finder "Finder" BLUEPRINT_MACOS_FINDER || return $?
    blueprint_selector_prompt_category macos-dock "Dock" BLUEPRINT_MACOS_DOCK || return $?
    blueprint_selector_prompt_category macos-windows "Window Management" BLUEPRINT_MACOS_WINDOWS || return $?
    blueprint_selector_prompt_category macos-keyboard "Keyboard" BLUEPRINT_MACOS_KEYBOARD || return $?
    blueprint_selector_prompt_category macos-trackpad "Trackpad" BLUEPRINT_MACOS_TRACKPAD || return $?
    blueprint_selector_prompt_category macos-screenshots "Screenshots" BLUEPRINT_MACOS_SCREENSHOTS || return $?

    BLUEPRINT_SELECTOR_TEMP_FILE="$(mktemp "${BLUEPRINT_FILE}.tmp.XXXXXX")" || return 2
    trap 'blueprint_selector_cleanup' INT TERM
    blueprint_selector_write "$BLUEPRINT_SELECTOR_TEMP_FILE" || {
        blueprint_selector_cleanup
        trap - INT TERM
        return 2
    }

    echo
    echo "=========================================="
    echo " Blueprint Summary"
    echo "=========================================="
    echo
    echo "Applications"
    printf '  Homebrew packages     %s\n' "$(blueprint_selector_count_lines "$BLUEPRINT_HOME_BREW_PACKAGES") / $(blueprint_generated_item_count homebrew-packages)"
    printf '  Homebrew casks        %s\n' "$(blueprint_selector_count_lines "$BLUEPRINT_HOME_BREW_CASKS") / $(blueprint_generated_item_count homebrew-casks)"
    printf '  App Store             %s\n' "$(blueprint_selector_count_lines "$BLUEPRINT_APP_STORE") / $(blueprint_generated_item_count app-store)"
    printf '  VS Code extensions    %s\n' "$(blueprint_selector_count_lines "$BLUEPRINT_VSCODE_EXTENSIONS") / $(blueprint_generated_item_count vscode-extensions)"
    echo
    echo "Workspace"
    printf '  Workspace folders     %s\n' "$(blueprint_selector_count_lines "$BLUEPRINT_WORKSPACE_FOLDERS") / $(blueprint_generated_item_count workspace-folders)"
    printf '  Git repositories      %s\n' "$(blueprint_selector_count_lines "$BLUEPRINT_GIT_REPOSITORIES") / $(blueprint_generated_item_count git-repositories)"
    echo
    echo "Settings"
    printf '  Git Configuration      %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_GIT_CONFIGURATION")"
    printf '  SSH Configuration      %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_SSH_CONFIGURATION")"
    printf '  VS Code Settings       %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_VSCODE_SETTINGS")"
    printf '  Shell / Zsh            %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_SHELL_ZSH")"
    printf '  Finder                 %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_MACOS_FINDER")"
    printf '  Dock                   %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_MACOS_DOCK")"
    printf '  Window Management      %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_MACOS_WINDOWS")"
    printf '  Keyboard               %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_MACOS_KEYBOARD")"
    printf '  Trackpad               %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_MACOS_TRACKPAD")"
    printf '  Screenshots            %s\n' "$(blueprint_selector_yes_no "$BLUEPRINT_MACOS_SCREENSHOTS")"
    echo

    local input
    while true; do
        printf 'Save Blueprint? [Y/n] (Q cancels): '
        IFS= read -r input || {
            blueprint_selector_cleanup
            trap - INT TERM
            return 1
        }
        case "$input" in
            [qQ]) return 3 ;; # Propagate cancellation to blueprint_selector_run.
            ""|[yY]|[yY][eE][sS]) break ;;
            [nN]|[nN][oO])
                return 3
                ;;
            *) error "Choose Y or N." ;;
        esac
    done

    BLUEPRINT_FILE="$BLUEPRINT_SELECTOR_TEMP_FILE" blueprint_validate || {
        blueprint_selector_cleanup
        trap - INT TERM
        return 2
    }
    if ! mv "$BLUEPRINT_SELECTOR_TEMP_FILE" "$BLUEPRINT_FILE"; then
        blueprint_selector_cleanup
        trap - INT TERM
        return 2
    fi
    BLUEPRINT_SELECTOR_TEMP_FILE=""
    trap - INT TERM
    # Shared state is read by another sourced module.
    # shellcheck disable=SC2034
    BLUEPRINT_SELECTOR_SAVED=true
    log "[BLUEPRINT] RESULT: SAVED"
    success "Blueprint saved to $BLUEPRINT_FILE"
    if [[ -z "${BUNDLE_CAPTURE_ACTIVE:-}" ]]; then
        info "For SSH identity migration, export separately on the source Mac after preparing Toolkit state: ./scripts/ssh-identity-migrate.sh export --output /absolute/path/package.age"
    fi
}
