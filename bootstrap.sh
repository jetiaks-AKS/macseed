#!/bin/bash

# ==========================================
# Core
# ==========================================

source modules/core/common/common.sh
source modules/core/logger/logger.sh
source modules/core/homebrew/homebrew.sh
source modules/core/git/git.sh
source modules/core/ssh/ssh.sh
source modules/core/terminal/terminal.sh
source modules/core/launcher/launcher.sh
source modules/core/preflight/preflight.sh
source modules/core/config/config.sh
source modules/core/verification/verification.sh

# ==========================================
# Blueprint
# ==========================================

source modules/blueprint/blueprint.sh
source modules/blueprint/selector.sh

# ==========================================
# Applications
# ==========================================

source modules/apps/brew-packages.sh
source modules/apps/brew-casks.sh
source modules/apps/appstore.sh

# ==========================================
# VS Code
# ==========================================

source modules/vscode/extensions.sh
source modules/vscode/settings.sh

# ==========================================
# Shell
# ==========================================

source modules/shell/zsh.sh
source modules/ssh/config.sh

# ==========================================
# macOS Settings
# ==========================================

source modules/settings/macos/macos.sh

# ==========================================
# Discovery
# ==========================================

source modules/discovery/discovery.sh
source modules/discovery/homebrew.sh
source modules/discovery/git.sh
source modules/discovery/ssh.sh
source modules/discovery/vscode.sh
source modules/discovery/macos/macos.sh
source modules/discovery/appstore.sh
source modules/discovery/workspace.sh

# ==========================================
# Bootstrap
# ==========================================

source modules/bootstrap/workspace/workspace.sh
source modules/bundle/commands.sh
source modules/verification/verification.sh

# ==========================================
# Toolkit Configuration
# ==========================================

source config/toolkit.conf

# ==========================================
# Toolkit Mode
# ==========================================

MODE=""
EXECUTION_MODE_COUNT=0
VERBOSE=false
RESTORE_BUNDLE=""
if [[ "${1:-}" == --restore && $# -eq 2 ]]; then
    RESTORE_BUNDLE="$2"
    set -- "$1"
fi

for arg in "$@"; do

    case "$arg" in

        --check)

            MODE="--check"
            ((EXECUTION_MODE_COUNT++))
            ;;

        --bootstrap)

            MODE="--bootstrap"
            ((EXECUTION_MODE_COUNT++))
            ;;

        --discover)

            MODE="--discover"
            ((EXECUTION_MODE_COUNT++))
            ;;

        --blueprint)

            MODE="--blueprint"
            ((EXECUTION_MODE_COUNT++))
            ;;

        --workflow)

            MODE="--workflow"
            ((EXECUTION_MODE_COUNT++))
            ;;

        --capture)
            MODE="--capture"
            ((EXECUTION_MODE_COUNT++))
            ;;

        --restore)
            MODE="--restore"
            ((EXECUTION_MODE_COUNT++))
            ;;

        --dry-run)

            MODE="--dry-run"
            ((EXECUTION_MODE_COUNT++))
            ;;

        -v|--verbose)

            VERBOSE=true
            ;;

        --version)

            echo "$TOOLKIT_NAME"
            echo "Version $TOOLKIT_VERSION"
            exit 0
            ;;

        --help)

            cat << EOF

==========================================
 Macseed — Capture. Rebuild. Continue.
==========================================

Usage:

  ./bootstrap.sh --check
      Check system configuration

  ./bootstrap.sh --bootstrap
      Bootstrap this Mac

  ./bootstrap.sh --discover
      Analyze current Mac and generate Bootstrap configuration

  ./bootstrap.sh --blueprint
      Select what Bootstrap should restore

  ./bootstrap.sh --dry-run
      Preview selected Bootstrap changes without target mutation

  ./bootstrap.sh --workflow
      Guide Discovery, Blueprint, Preview, and confirmed Bootstrap

  ./bootstrap.sh --capture
      Create a private Bootstrap Bundle from this Mac

  ./bootstrap.sh --restore /absolute/path/bundle.mbt
      Restore selected environment from a Bootstrap Bundle

Options:

  -v, --verbose
      Show detailed output

  ./bootstrap.sh --version
      Show Toolkit version

  ./bootstrap.sh --help
      Show this help

EOF

            exit 0
            ;;

        *)

            error "Unknown option: $arg"

            echo
            echo "Use:"
            echo "  ./bootstrap.sh --help"

            exit 1
            ;;

    esac

done

if [[ $EXECUTION_MODE_COUNT -ne 1 ]]; then
    error "Select exactly one execution mode"
    echo
    echo "Use:"
    echo "  ./bootstrap.sh --help"
    exit 1
fi

if [[ "$MODE" != --restore && -e config/.bundle-publication ]]; then
    error "Incomplete Bundle publication requires bs restore recovery before another Toolkit mode"
    exit 2
fi

MODE_NAME="Unknown"

case "$MODE" in

    --check)
        MODE_NAME="Check"
        ;;

    --bootstrap)
        MODE_NAME="Bootstrap"
        ;;

    --discover)
        MODE_NAME="Discovery"
        ;;

    --blueprint)
        MODE_NAME="Blueprint"
        ;;

    --dry-run)
        MODE_NAME="Preview"
        ;;
    --capture)
        MODE_NAME="Capture"
        ;;
    --restore)
        MODE_NAME="Restore"
        ;;

esac

# ==========================================
# Bootstrap Input Validation
# ==========================================

bootstrap_item_scope_selected() {

    local section="$1"

    if blueprint_exists && [[ -z "$(blueprint_selected_items "$section")" ]]; then
        return 1
    fi

    return 0

}

bootstrap_validate_selected_inputs() {

    local config_file
    local source_result

    workspace_validate_bootstrap_inputs || return 2

    if blueprint_category_enabled git-configuration &&
       git_configuration_scope_selected; then
        load_git_configuration || return 2
    fi

    if bootstrap_item_scope_selected homebrew-packages; then
        config_file="$(blueprint_generated_file homebrew-packages)"
        read_brew_packages_configuration "$config_file" >/dev/null || return 2
    fi

    if bootstrap_item_scope_selected homebrew-casks; then
        config_file="$(blueprint_generated_file homebrew-casks)"
        read_brew_casks_configuration "$config_file" >/dev/null || return 2
    fi

    if bootstrap_item_scope_selected app-store; then
        config_file="$(blueprint_generated_file app-store)"
        read_appstore_configuration "$config_file" >/dev/null || return 2
    fi

    if bootstrap_item_scope_selected vscode-extensions; then
        config_file="$(blueprint_generated_file vscode-extensions)"
        read_vscode_extensions_configuration "$config_file" >/dev/null || return 2
    fi

    if blueprint_category_enabled vscode-settings; then
        validate_vscode_settings_source "${BLUEPRINT_GENERATED_DIR:-config/generated}/vscode/settings.json"
        source_result=$?
        [[ $source_result -ne 2 ]] || return 2
    fi

    if blueprint_category_enabled shell-zsh; then
        zsh_snapshot_validate
        source_result=$?
        [[ $source_result -ne 2 ]] || return 2
        if [[ $source_result -eq 1 ]] && blueprint_exists; then
            error "Selected Zsh snapshot is missing"
            return 2
        fi
    fi

    if blueprint_category_enabled ssh-configuration && ssh_configuration_scope_selected; then
        local ssh_payload ssh_result
        ssh_payload="$(mktemp)" || return 2
        ssh_snapshot_validate "$ssh_payload"
        ssh_result=$?
        rm -f "$ssh_payload"
        if [[ $ssh_result -eq 2 ]]; then
            error "Invalid selected SSH snapshot"
            return 2
        fi
        if [[ $ssh_result -eq 1 ]] && blueprint_exists; then
            error "Selected SSH snapshot is missing"
            return 2
        fi
    fi

    if blueprint_category_enabled macos-finder; then
        validate_defaults_config "$FINDER_CONFIG" finder || return 2
    fi

    if blueprint_category_enabled macos-dock; then
        validate_defaults_config "$DOCK_CONFIG" dock || return 2
    fi

    if blueprint_category_enabled macos-windows; then
        validate_defaults_config "$WINDOWS_CONFIG" windows || return 2
    fi

    if blueprint_category_enabled macos-keyboard; then
        validate_defaults_config "$KEYBOARD_CONFIG" keyboard || return 2
    fi

    if blueprint_category_enabled macos-trackpad; then
        validate_defaults_config "$TRACKPAD_CONFIG" trackpad || return 2
    fi

    if blueprint_category_enabled macos-screenshots; then
        validate_screenshots_config || return 2
    fi

    return 0

}

bootstrap_run_startup_validation() {

    local blueprint_result=0
    local bootstrap_validation_result

    if blueprint_exists; then
        if [[ "$MODE" == "--dry-run" ]]; then
            run_inspection "Blueprint Validation" blueprint_validate
        else
            run_module "Blueprint Validation" blueprint_validate
        fi
        blueprint_result=$?
        [[ $blueprint_result -ne 2 ]] && BLUEPRINT_BOOTSTRAP_SUMMARY=true
    fi

    if [[ $blueprint_result -ne 2 ]]; then
        bootstrap_validate_selected_inputs
        bootstrap_validation_result=$?
        [[ $bootstrap_validation_result -ne 2 ]] || ((ERROR_COUNT++))
    else
        bootstrap_validation_result=2
    fi

    if [[ $blueprint_result -ne 2 && $bootstrap_validation_result -ne 2 ]]; then
        return 0
    fi

    return 2

}

run_preview() {

    # Continue later read-only inspections; run_inspection retains every status.

    run_inspection "Homebrew Packages Preview" preview_brew_packages
    run_inspection "Homebrew Casks Preview" preview_brew_casks
    run_inspection "App Store Preview" preview_appstore_apps
    run_inspection "VS Code Extensions Preview" preview_vscode_extensions

    if blueprint_category_enabled git-configuration &&
       git_configuration_scope_selected; then
        run_inspection "Git Configuration Preview" preview_git_configuration
    fi

    if blueprint_category_enabled vscode-settings; then
        run_inspection "VS Code Settings Preview" preview_vscode_settings
    fi

    if blueprint_category_enabled shell-zsh; then
        run_inspection "Zsh Configuration Preview" preview_zsh
    fi

    if blueprint_category_enabled ssh-configuration && ssh_configuration_scope_selected; then
        run_inspection "SSH Configuration Preview" preview_ssh_configuration
    fi

    run_inspection "Workspace Folders Preview" preview_workspace_folders
    run_inspection "Workspace Repositories Preview" preview_workspace_repositories
    run_inspection "macOS Settings Preview" preview_macos_settings
    return 0

}

# A restored Bundle carries only selected generated inputs. Without a Blueprint,
# retain the all-inclusive Discovery inventory requirement.
workflow_generated_ready() (
    if blueprint_exists; then
        blueprint_validate
        [[ $? -ne 2 ]] || return 2
        if blueprint_category_enabled vscode-settings; then
            validate_vscode_settings_source "${BLUEPRINT_GENERATED_DIR:-config/generated}/vscode/settings.json" || return 2
        fi
    else
        blueprint_exists() { return 1; }
    fi
    blueprint_selector_generated_ready || return 2
    bootstrap_validate_selected_inputs
)

workflow_confirm() {
    local input
    while true; do
        printf '%s ' "$1"
        IFS= read -r input || return 1
        case "$input" in
            "") [[ "$2" == yes ]]; return $? ;;
            [yY]|[yY][eE][sS]) return 0 ;;
            [nN]|[nN][oO]) return 1 ;;
            *) info "Choose Y or N." ;;
        esac
    done
}

run_workflow() {
    local refresh=false result workflow_result=0
    local WORKFLOW_ACTIVE=true

    if workflow_generated_ready; then
        workflow_confirm "Refresh generated configuration from this Mac? [y/N]" no && refresh=true
    else
        info "No usable generated configuration found (missing, unreadable, or invalid input)."
        info "Discovery is required before continuing."
        workflow_confirm "Run Discovery now? [Y/n]" yes || {
            info "Workflow cancelled."
            return 0
        }
        refresh=true
    fi

    if [[ "$refresh" == true ]]; then
        run_mode --discover Discovery
        result=$?
        [[ $result -le 1 ]] || return "$result"
        workflow_result=$result
        workflow_generated_ready || return 2
    fi

    run_mode --blueprint Blueprint
    result=$?
    if [[ $result -eq 3 ]]; then
        info "Workflow cancelled."
        return "$workflow_result"
    fi
    [[ $result -eq 0 ]] || return "$result"

    run_mode --dry-run Preview
    result=$?
    # Internal Preview signals: no plans, with success (3) or warnings (4).
    if [[ $result -eq 3 || $result -eq 4 ]]; then
        [[ $result -ne 4 ]] || workflow_result=1
        run_mode --verification-internal Verification not_run
        info "Workflow finished."
        return "$workflow_result"
    fi
    [[ $result -le 1 ]] || return "$result"
    [[ $result -eq 0 ]] || workflow_result=1

    if workflow_confirm "Apply these changes with Bootstrap? [y/N]" no; then
        run_mode --bootstrap Bootstrap
        result=$?
        [[ $result -le 1 ]] || return "$result"
        [[ $result -eq 0 ]] || workflow_result=1
    else
        run_mode --verification-internal Verification skipped
        info "Workflow finished without applying changes."
    fi
    return "$workflow_result"
}

# Subshells keep each production stage's logger, traps and counters independent.
run_mode() (
MODE="$1"
MODE_NAME="$2"
PREVIEW_HAS_CHANGES=false

verification_reset bootstrap
if [[ "${BUNDLE_RESTORE_ACTIVE:-false}" == true ]]; then
    GV_ORIGIN=restore
elif [[ "${WORKFLOW_ACTIVE:-false}" == true ]]; then
    GV_ORIGIN=workflow
fi

# ==========================================
# Initialize Logger
# ==========================================

init_logger

if [[ "$MODE" == --verification-internal ]]; then
    verification_operation orchestration bootstrap execute "${3:-not_run}"
    verification_run
    close_logger
    exit 0
fi

info "Mode: $MODE_NAME"

if [[ "$VERBOSE" == true ]]; then
    info "Output: Verbose"
fi

echo
echo "=========================================="
echo " $TOOLKIT_NAME"
echo "=========================================="
echo
echo "Version : $TOOLKIT_VERSION"
echo "Mode    : $MODE_NAME"
echo

if [[ "$MODE" == "--blueprint" ]]; then
    blueprint_selector_run
    blueprint_result=$?
    close_logger
    if [[ "${WORKFLOW_ACTIVE:-false}" == true && $blueprint_result -le 1 &&
          "${BLUEPRINT_SELECTOR_SAVED:-false}" != true ]]; then
        exit 3 # Internal cancellation signal; standalone selector is unchanged.
    fi
    exit "$blueprint_result"
fi

if [[ "$MODE" == "--bootstrap" || "$MODE" == "--dry-run" ]]; then
    if ! bootstrap_run_startup_validation; then
        show_summary
        close_logger
        exit 2
    fi
fi


# ==========================================
# Preflight Checks
# ==========================================

if [[ "$MODE" == "--dry-run" ]]; then
    run_read_only_preflight_checks
else
    run_preflight_checks
fi

if [[ $? -ne 0 ]]; then

    ((ERROR_COUNT++))

    show_summary
    close_logger
    exit 2

fi

# ==========================================
# System Check
# ==========================================

if [[ "$MODE" == "--dry-run" ]]; then
    run_inspection "Homebrew" check_homebrew_read_only
elif [[ "$MODE" == "--discover" ]]; then
    run_module "Homebrew" check_homebrew_read_only
elif [[ "$MODE" == "--bootstrap" && "${BUNDLE_RESTORE_ACTIVE:-false}" == true &&
        -z "$(blueprint_selected_items homebrew-packages)" &&
        -z "$(blueprint_selected_items homebrew-casks)" ]]; then
    run_module "Homebrew" check_homebrew_read_only
else
    run_module "Homebrew" check_homebrew
fi
if [[ "$MODE" == "--dry-run" ]]; then
    run_inspection "Git" check_git
    run_inspection "SSH" check_ssh
    run_inspection "Terminal" check_terminal
else
    run_module "Git" check_git
    run_module "SSH" check_ssh
    run_module "Terminal" check_terminal
fi


# ==========================================
# Execution
# ==========================================

case "$MODE" in

    --check)

        ;;

    --bootstrap)

        if [[ "${BUNDLE_RESTORE_ACTIVE:-false}" == true ]]; then
            run_module "Restore SSH Prerequisites" bundle_restore_prerequisites
            prerequisite_result=$?
            if [[ $prerequisite_result -ne 0 ]]; then
                verification_operation orchestration bootstrap execute skipped prerequisite_failed
                verification_run
                show_summary
                toolkit_exit_code
                prerequisite_result=$?
                close_logger
                exit "$prerequisite_result"
            fi
        fi

        run_module "bs Launcher" configure_bs_launcher

        run_module "Workspace" bootstrap_workspace

        echo

        if blueprint_category_enabled git-configuration &&
           git_configuration_scope_selected; then
            run_module "Git Configuration" configure_git
        fi

        run_module "Homebrew Packages" install_brew_packages

        run_module "Homebrew Casks" install_brew_casks

        run_module "App Store" install_appstore_apps

        run_module "VS Code Extensions" install_vscode_extensions

        if blueprint_category_enabled vscode-settings; then
            run_module "VS Code Settings" apply_vscode_settings
        fi

        if blueprint_category_enabled shell-zsh; then
            run_module "Zsh Configuration" bootstrap_zsh
        fi

        if blueprint_category_enabled ssh-configuration && ssh_configuration_scope_selected; then
            run_module "SSH Configuration" bootstrap_ssh_configuration
        fi

        if blueprint_category_enabled macos-finder ||
           blueprint_category_enabled macos-dock ||
           blueprint_category_enabled macos-windows ||
           blueprint_category_enabled macos-keyboard ||
           blueprint_category_enabled macos-trackpad ||
           blueprint_category_enabled macos-screenshots; then
            apply_macos_settings
        fi

        ;;

    --discover)

        run_discovery

        ;;

    --dry-run)

        run_preview

        ;;

esac

if [[ "$MODE" == --bootstrap ]]; then
    toolkit_exit_code
    bootstrap_operation_result=$?
    if [[ $bootstrap_operation_result -eq 2 ]]; then
        verification_operation orchestration bootstrap execute failure
    else
        verification_operation orchestration bootstrap execute success
    fi
    verification_run
fi

show_summary

toolkit_exit_code
result=$?
if [[ "$MODE" == --bootstrap && $result -le 1 ]]; then
    info "For SSH identity migration, after age is available, import separately: ./scripts/ssh-identity-migrate.sh import --input /absolute/path/package.age"
fi
if [[ "$MODE" == --dry-run && "${WORKFLOW_ACTIVE:-false}" == true &&
      $result -le 1 && "$PREVIEW_HAS_CHANGES" == false ]]; then
    success "No changes to apply"
    close_logger
    exit $((result + 3)) # Internal no-plan signal; public Preview stays 0/1/2.
fi

close_logger
exit "$result"

)

if [[ "$MODE" == "--capture" ]]; then
    bundle_capture
elif [[ "$MODE" == "--restore" ]]; then
    bundle_restore "$RESTORE_BUNDLE"
elif [[ "$MODE" == "--workflow" ]]; then
    run_workflow
else
    run_mode "$MODE" "$MODE_NAME"
fi
exit $?
