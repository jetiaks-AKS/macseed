#!/bin/bash

# Application Capture invokes existing exporters independently, into owned staging.
capture_observe() {
    local domain="$1" exporter="$2" dependency="${3:-}" result status reason='' index
    if [[ -n "$dependency" ]] && ! command -v "$dependency" >/dev/null 2>&1; then
        result=1
        status=unavailable
        reason=tool_unavailable
    else
        "$exporter"
        result=$?
        status=present
        [[ $result -lt 2 ]] || { status=observation_error; reason=observation_failed; }
        [[ $result -ne 1 ]] || reason=source_partial
    fi
    local file
    file="$BLUEPRINT_GENERATED_DIR/$(python3 modules/core/application-interface/capture.py --path "$domain")" || return 2
    local items=() labels=()
    if [[ "$status" != observation_error && -f "$file" ]]; then
        local validator=''
        case "$domain" in
            homebrew-packages) validator=read_brew_packages_configuration ;;
            homebrew-casks) validator=read_brew_casks_configuration ;;
            app-store) validator=read_appstore_configuration ;;
            vscode-extensions) validator=read_vscode_extensions_configuration ;;
            workspace-folders) validator=workspace_validate_folders ;;
            git-repositories) validator=workspace_validate_repositories ;;
        esac
        if [[ -n "$validator" ]] && ! "$validator" "$file" >/dev/null; then
            status=observation_error; reason=inventory_invalid
        fi
        if [[ "$status" == observation_error ]]; then
            : # Invalid observed data is never projected as selectable inventory.
        elif blueprint_item_section_supported "$domain"; then
            blueprint_selector_load_items "$domain" || { status=observation_error; reason=inventory_invalid; }
            items=("${BLUEPRINT_SELECTOR_ITEMS[@]}")
            labels=("${BLUEPRINT_SELECTOR_LABELS[@]}")
            [[ ${#items[@]} -gt 0 ]] || { status=unavailable; reason=no_supported_items; }
        elif [[ "$domain" == shell-zsh ]]; then
            zsh_snapshot_validate "$file" || { status=observation_error; reason=inventory_invalid; }
            case "$ZSH_SNAPSHOT_STATUS" in
                absent) status=unavailable; reason=source_absent ;;
                excluded) status=unsupported; reason=source_excluded ;;
            esac
        elif [[ "$domain" == ssh-configuration ]]; then
            local payload
            payload="$(mktemp)" || return 2
            ssh_snapshot_validate "$payload" "$file" || { status=observation_error; reason=inventory_invalid; }
            rm -f "$payload"
            [[ "$SSH_SNAPSHOT_STATUS" != unsupported && "$SSH_SNAPSHOT_STATUS" != external ]] || { status=unsupported; reason=source_excluded; }
            if [[ "$status" == present && "$SSH_SNAPSHOT_COUNT" -eq 0 ]]; then status=unavailable; reason=no_supported_items; fi
        elif [[ ! -s "$file" ]]; then
            status=unavailable; reason=no_supported_items
        fi
    elif [[ "$status" != observation_error ]]; then
        status=unavailable
        [[ "$reason" == tool_unavailable ]] || reason=source_absent
    fi
    {
        printf '%s\0' "$domain" "$status" "$reason"
        for index in "${!items[@]}"; do printf '%s\0' "${items[$index]}" "${labels[$index]}"; done
    } | python3 modules/core/application-interface/capture.py --row "$MACSEED_CAPTURE_INVENTORY" || return 2
    return 0
}

capture_discovery() {
    capture_observe homebrew-packages export_brew_packages brew || return 2
    capture_observe homebrew-casks export_brew_casks brew || return 2
    capture_observe app-store discover_appstore mas || return 2
    capture_observe git-configuration discover_git git || return 2
    capture_observe ssh-configuration discover_ssh_configuration || return 2
    capture_observe vscode-extensions export_vscode_extensions code || return 2
    capture_observe vscode-settings export_vscode_settings || return 2
    capture_observe shell-zsh discover_zsh || return 2
    local domain
    for domain in finder dock windows keyboard trackpad screenshots; do
        capture_observe "macos-$domain" "export_${domain}_settings" || return 2
    done
    # Workspace snapshot is a single production observation/publication group.
    discover_workspace
    local capture_workspace_discovery_status=$?
    capture_workspace_result() { return "$capture_workspace_discovery_status"; }
    capture_observe workspace-folders capture_workspace_result || return 2
    capture_observe git-repositories capture_workspace_result || return 2
    return 0
}
