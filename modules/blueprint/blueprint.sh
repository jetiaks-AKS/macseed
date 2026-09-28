#!/bin/bash

# ==========================================
# Blueprint Selection
# ==========================================

BLUEPRINT_FILE="${BLUEPRINT_FILE:-config/blueprint.conf}"
BLUEPRINT_GENERATED_DIR="${BLUEPRINT_GENERATED_DIR:-config/generated}"
# Shared state is read by another sourced module.
# shellcheck disable=SC2034
BLUEPRINT_BOOTSTRAP_SUMMARY=false

# ==========================================
# Blueprint Exists
# ==========================================

blueprint_exists() {

    local blueprint_file="${1:-$BLUEPRINT_FILE}"

    [[ -f "$blueprint_file" ]]

}

# ==========================================
# Supported Names
# ==========================================

blueprint_category_supported() {

    case "$1" in
        git-configuration|ssh-configuration|vscode-settings|shell-zsh|macos-finder|macos-dock|macos-windows|macos-keyboard|macos-trackpad|macos-screenshots)
            return 0
            ;;
        *)
            return 1
            ;;
    esac

}

blueprint_item_section_supported() {

    case "$1" in
        homebrew-packages|homebrew-casks|app-store|vscode-extensions|workspace-folders|git-repositories|git-configuration)
            return 0
            ;;
        *)
            return 1
            ;;
    esac

}

# ==========================================
# Selection Queries
# ==========================================

blueprint_category_enabled() {

    local category="$1"
    local blueprint_file="${2:-$BLUEPRINT_FILE}"

    blueprint_category_supported "$category" || return 2

    if ! blueprint_exists "$blueprint_file"; then
        return 0
    fi

    local value

    value="$(awk -v category="$category" '
        $0 == "[categories]" {
            in_categories = 1
            next
        }

        /^\[/ {
            in_categories = 0
        }

        in_categories && $0 ~ "^" category "=" {
            sub("^" category "=\"", "")
            sub("\"$", "")
            print
            exit
        }
    ' "$blueprint_file")"

    case "$value" in
        true)
            return 0
            ;;
        false)
            return 1
            ;;
        "")
            [[ "$category" == macos-windows || "$category" == shell-zsh || "$category" == ssh-configuration ]] && return 1
            return 2
            ;;
        *)
            return 2
            ;;
    esac

}

blueprint_selected_items() {

    local section="$1"
    local blueprint_file="${2:-$BLUEPRINT_FILE}"

    blueprint_item_section_supported "$section" || return 2
    blueprint_exists "$blueprint_file" || return 1

    awk -v target="$section" '
        $0 == "[" target "]" {
            in_section = 1
            next
        }

        /^\[/ {
            in_section = 0
        }

        in_section && $0 !~ /^[[:space:]]*$/ && $0 !~ /^[[:space:]]*#/ {
            print
        }
    ' "$blueprint_file"

}

blueprint_item_section_exists() {
    local section="$1"
    local blueprint_file="${2:-$BLUEPRINT_FILE}"
    blueprint_item_section_supported "$section" || return 2
    blueprint_exists "$blueprint_file" || return 1
    grep -Fxq -- "[$section]" "$blueprint_file"
}

blueprint_item_selected() {

    local section="$1"
    local item="$2"
    local blueprint_file="${3:-$BLUEPRINT_FILE}"

    blueprint_item_section_supported "$section" || return 2

    if ! blueprint_exists "$blueprint_file"; then
        return 0
    fi

    if [[ "$section" == git-configuration ]] &&
       ! blueprint_item_section_exists "$section" "$blueprint_file"; then
        return 0
    fi

    if [[ "$section" == "workspace-folders" ]] &&
       ! blueprint_workspace_folder_candidate "$item"; then
        return 1
    fi

    blueprint_selected_items "$section" "$blueprint_file" |
        grep -Fxq -- "$item"

}

# ==========================================
# Syntax Validation
# ==========================================

blueprint_validate_syntax() {

    local blueprint_file="${1:-$BLUEPRINT_FILE}"
    local validation_output
    local validation_result

    validation_output="$(awk '
        BEGIN {
            sections["categories"] = 1
            sections["homebrew-packages"] = 1
            sections["homebrew-casks"] = 1
            sections["app-store"] = 1
            sections["vscode-extensions"] = 1
            sections["workspace-folders"] = 1
            sections["git-repositories"] = 1
            sections["git-configuration"] = 1

            categories["git-configuration"] = 1
            categories["ssh-configuration"] = 1
            categories["vscode-settings"] = 1
            categories["shell-zsh"] = 1
            categories["macos-finder"] = 1
            categories["macos-dock"] = 1
            categories["macos-windows"] = 1
            categories["macos-keyboard"] = 1
            categories["macos-trackpad"] = 1
            categories["macos-screenshots"] = 1
        }

        function invalid(message) {
            print message
            has_errors = 1
        }

        /^[[:space:]]*$/ || /^[[:space:]]*#/ {
            next
        }

        /^\[/ {
            if ($0 !~ /^\[[a-z-]+\]$/) {
                invalid("Malformed Blueprint section at line " NR)
                current_section = ""
                next
            }

            current_section = substr($0, 2, length($0) - 2)

            if (!(current_section in sections)) {
                invalid("Unknown Blueprint section: " current_section)
                next
            }

            section_count[current_section]++

            if (section_count[current_section] > 1) {
                invalid("Duplicate Blueprint section: " current_section)
            }

            next
        }

        current_section == "" {
            invalid("Blueprint data outside a section at line " NR)
            next
        }

        current_section == "categories" {
            separator = index($0, "=")
            key = separator ? substr($0, 1, separator - 1) : $0

            if (!(key in categories)) {
                invalid("Unknown Blueprint category: " key)
                next
            }

            if ($0 != key "=\"true\"" && $0 != key "=\"false\"") {
                invalid("Invalid boolean for Blueprint category: " key)
                next
            }

            category_count[key]++

            if (category_count[key] > 1) {
                invalid("Duplicate Blueprint category: " key)
            }

            next
        }

        {
            if (index($0, "=") != 0) {
                invalid("Assignment syntax is not allowed in Blueprint item sections at line " NR)
                next
            }

            if ($0 ~ /^[[:space:]]/ || $0 ~ /[[:space:]]$/) {
                invalid("Blueprint item has leading or trailing whitespace at line " NR)
                next
            }

            if ($0 ~ /[[:space:]]#/) {
                invalid("Inline Blueprint comments are not supported at line " NR)
                next
            }

            item_key = current_section SUBSEP $0
            if (current_section == "git-configuration" &&
                $0 != "user.name" && $0 != "user.email" &&
                $0 != "init.defaultBranch" && $0 != "pull.rebase" &&
                $0 != "core.editor" && $0 != "user.useConfigOnly" &&
                $0 != "pull.ff") {
                invalid("Unsupported Git Blueprint item: " $0)
                next
            }
            item_count[item_key]++

            if (item_count[item_key] > 1) {
                invalid("Duplicate Blueprint item in " current_section ": " $0)
            }
        }

        END {
            for (section in sections) {
                if (section == "git-configuration" && section_count[section] == 0) {
                    continue
                }
                if (section_count[section] != 1) {
                    invalid("Missing Blueprint section: " section)
                }
            }

            for (category in categories) {
                if ((category == "macos-windows" || category == "shell-zsh" || category == "ssh-configuration") && category_count[category] == 0) {
                    continue
                }
                if (category_count[category] != 1) {
                    invalid("Missing Blueprint category: " category)
                }
            }

            exit(has_errors ? 2 : 0)
        }
    ' "$blueprint_file")"
    validation_result=$?

    if [[ -n "$validation_output" ]]; then
        while IFS= read -r message; do
            error "$message"
        done <<< "$validation_output"
    fi

    return "$validation_result"

}

# ==========================================
# Generated State Validation
# ==========================================

blueprint_generated_file() {

    case "$1" in
        homebrew-packages)
            echo "$BLUEPRINT_GENERATED_DIR/brew-packages.conf"
            ;;
        homebrew-casks)
            echo "$BLUEPRINT_GENERATED_DIR/brew-casks.conf"
            ;;
        app-store)
            echo "$BLUEPRINT_GENERATED_DIR/appstore.conf"
            ;;
        vscode-extensions)
            echo "$BLUEPRINT_GENERATED_DIR/vscode-extensions.conf"
            ;;
        workspace-folders)
            echo "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
            ;;
        git-repositories)
            echo "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
            ;;
        git-configuration)
            echo "$BLUEPRINT_GENERATED_DIR/git.conf"
            ;;
        *)
            return 1
            ;;
    esac

}

blueprint_workspace_folder_candidates() {

    local generated_file="${1:-$BLUEPRINT_GENERATED_DIR/workspace/folders.conf}"

    [[ -f "$generated_file" ]] || return 1

    awk -F '|' '$2 == "workspace" { print $1 }' "$generated_file"

}

blueprint_workspace_folder_candidate() {

    local item="$1"
    local generated_file="${2:-$BLUEPRINT_GENERATED_DIR/workspace/folders.conf}"

    [[ -f "$generated_file" ]] || return 1

    awk -F '|' -v item="$item" '
        $1 == item && $2 == "workspace" { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "$generated_file"

}

blueprint_generated_has_item() {

    local section="$1"
    local item="$2"
    local generated_file

    generated_file="$(blueprint_generated_file "$section")" || return 1
    [[ -f "$generated_file" ]] || return 1

    case "$section" in
        homebrew-packages|homebrew-casks|vscode-extensions)
            grep -Fxq -- "$item" "$generated_file"
            ;;
        app-store|workspace-folders)
            awk -F '|' -v item="$item" '$1 == item { found = 1 } END { exit(found ? 0 : 1) }' \
                "$generated_file"
            ;;
        git-repositories)
            grep -Fxq -- "[$item]" "$generated_file"
            ;;
        git-configuration)
            git config --file "$generated_file" --no-includes --name-only --list 2>/dev/null |
                grep -Fxiq -- "$item"
            ;;
    esac

}

blueprint_validate_repository_identifiers() {

    local repositories_file="$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"

    [[ -f "$repositories_file" ]] || return 0

    local duplicate_identifiers

    duplicate_identifiers="$(awk '
        /^\[[^]]+\]$/ {
            identifier = substr($0, 2, length($0) - 2)
            count[identifier]++

            if (count[identifier] == 2) {
                print identifier
            }
        }
    ' "$repositories_file")"

    if [[ -z "$duplicate_identifiers" ]]; then
        return 0
    fi

    while IFS= read -r identifier; do
        error "Ambiguous generated repository identifier: $identifier"
    done <<< "$duplicate_identifiers"

    return 2

}

blueprint_validate_selected_items() {

    local blueprint_file="${1:-$BLUEPRINT_FILE}"
    local validation_result=0
    local section
    local item

    for section in \
        homebrew-packages \
        homebrew-casks \
        app-store \
        vscode-extensions \
        workspace-folders \
        git-repositories \
        git-configuration; do

        while IFS= read -r item; do
            [[ -z "$item" ]] && continue

            if [[ "$section" == "workspace-folders" ]] &&
               blueprint_generated_has_item "$section" "$item" &&
               ! blueprint_workspace_folder_candidate "$item"; then
                continue
            fi

            if ! blueprint_generated_has_item "$section" "$item"; then
                warning "Stale Blueprint item in $section: $item"
                validation_result=1
            fi
        done < <(blueprint_selected_items "$section" "$blueprint_file")

    done

    return "$validation_result"

}

# ==========================================
# Blueprint Validation
# ==========================================

blueprint_validate() {

    local blueprint_file="${1:-$BLUEPRINT_FILE}"
    local validation_result=0
    local result

    if ! blueprint_exists "$blueprint_file"; then
        return 0
    fi

    blueprint_validate_syntax "$blueprint_file" || return 2

    blueprint_validate_repository_identifiers
    result=$?

    if [[ $result -gt $validation_result ]]; then
        validation_result=$result
    fi

    blueprint_validate_selected_items "$blueprint_file"
    result=$?

    if [[ $result -gt $validation_result ]]; then
        validation_result=$result
    fi

    if [[ $validation_result -eq 0 ]]; then
        success "Blueprint configuration is valid"
    fi

    return "$validation_result"

}

# ==========================================
# Bootstrap Summary
# ==========================================

blueprint_generated_item_count() {

    local section="$1"
    local generated_file

    generated_file="$(blueprint_generated_file "$section")" || return 1
    [[ -f "$generated_file" ]] || {
        echo 0
        return 0
    }

    case "$section" in
        git-repositories)
            config_sections "$generated_file" | awk 'NF { count++ } END { print count + 0 }'
            ;;
        workspace-folders)
            blueprint_workspace_folder_candidates "$generated_file" |
                awk 'NF { count++ } END { print count + 0 }'
            ;;
        *)
            awk 'NF && $0 !~ /^[[:space:]]*#/ { count++ } END { print count + 0 }' \
                "$generated_file"
            ;;
    esac

}

blueprint_selected_item_count() {

    local section="$1"

    if [[ "$section" == "workspace-folders" ]]; then
        local item
        local count=0

        while IFS= read -r item; do
            [[ -n "$item" ]] || continue
            blueprint_workspace_folder_candidate "$item" && ((count++))
        done < <(blueprint_selected_items "$section")

        echo "$count"
        return 0
    fi

    blueprint_selected_items "$section" |
        awk 'NF { count++ } END { print count + 0 }'

}

blueprint_summary_item() {

    local label="$1"
    local section="$2"
    local line

    printf -v line '  %-22s %s / %s selected' \
        "$label" \
        "$(blueprint_selected_item_count "$section")" \
        "$(blueprint_generated_item_count "$section")"
    echo "$line"
    log "$line"

}

blueprint_summary_category() {

    local label="$1"
    local category="$2"
    local state=Skipped
    local line

    blueprint_category_enabled "$category" && state=Enabled
    printf -v line '  %-22s %s' "$label" "$state"
    echo "$line"
    log "$line"

}

blueprint_show_bootstrap_summary() {

    echo "Applications"
    log "Applications"
    blueprint_summary_item "Homebrew packages" homebrew-packages
    blueprint_summary_item "Homebrew casks" homebrew-casks
    blueprint_summary_item "App Store" app-store
    blueprint_summary_item "VS Code extensions" vscode-extensions

    echo
    log ""
    echo "Workspace"
    log "Workspace"
    blueprint_summary_item "Folders" workspace-folders
    blueprint_summary_item "Git repositories" git-repositories

    echo
    log ""
    echo "Settings"
    log "Settings"
    blueprint_summary_category "Git Configuration" git-configuration
    blueprint_summary_category "SSH Configuration" ssh-configuration
    blueprint_summary_category "VS Code Settings" vscode-settings
    blueprint_summary_category "Shell / Zsh" shell-zsh
    blueprint_summary_category "Finder" macos-finder
    blueprint_summary_category "Dock" macos-dock
    blueprint_summary_category "Window Management" macos-windows
    blueprint_summary_category "Keyboard" macos-keyboard
    blueprint_summary_category "Trackpad" macos-trackpad
    blueprint_summary_category "Screenshots" macos-screenshots

    echo
    log ""
    echo "Result"
    log "Result"
    local line
    printf -v line '  %-22s %s' "Warnings" "$WARNING_COUNT"
    echo "$line"
    log "$line"
    printf -v line '  %-22s %s' "Errors" "$ERROR_COUNT"
    echo "$line"
    log "$line"

}
