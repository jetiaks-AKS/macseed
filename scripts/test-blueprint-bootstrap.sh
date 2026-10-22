#!/bin/bash

# ==========================================
# Blueprint Bootstrap Filtering Harness
# ==========================================

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"

trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

BLUEPRINT_FILE="$TEST_ROOT/blueprint.conf"
BLUEPRINT_GENERATED_DIR="$TEST_ROOT/generated"
HOME="$TEST_ROOT/home"
VERBOSE=false
MODULE_CHANGED=false
TEST_FAILURES=0
PROCESSED_ITEMS=""

source "$PROJECT_ROOT/modules/core/common/common.sh"

log() { :; }
section() { :; }
action() { :; }
detail() { :; }
info() { :; }
success() { :; }
warning() { :; }
error() { :; }

source "$PROJECT_ROOT/modules/core/config/config.sh"
source "$PROJECT_ROOT/modules/blueprint/blueprint.sh"
source "$PROJECT_ROOT/modules/apps/brew-packages.sh"
source "$PROJECT_ROOT/modules/apps/brew-casks.sh"
source "$PROJECT_ROOT/modules/apps/appstore.sh"
source "$PROJECT_ROOT/modules/vscode/extensions.sh"
source "$PROJECT_ROOT/modules/settings/macos/macos.sh"
source "$PROJECT_ROOT/modules/discovery/workspace.sh"
source "$PROJECT_ROOT/modules/bootstrap/workspace/validation.sh"
source "$PROJECT_ROOT/modules/bootstrap/workspace/folders.sh"
source "$PROJECT_ROOT/modules/bootstrap/workspace/repositories.sh"

command() {
    return 0
}

brew() {
    if [[ "$1" == list ]]; then
        if [[ "$*" == 'list --formula --full-name' ]]; then
            printf '%s\n' ${PROCESSED_ITEMS:-}
            return 0
        fi
        return 1
    fi

    PROCESSED_ITEMS="${PROCESSED_ITEMS}${PROCESSED_ITEMS:+ }$2"
}

mas() {
    if [[ "$*" == list && "${MAS_NO_AUTO_INDEX:-}" == 1 ]]; then
        printf '%s\n' '111 Selected App (1.0)' '222 Unselected App (1.0)'
        return 0
    fi
    printf '%s\n' "$*" >> "$TEST_ROOT/forbidden-mas-calls"
    return 99
}

code() {
    if [[ "$1" == --list-extensions ]]; then
        printf '%s\n' ${PROCESSED_ITEMS:-}
        return 0
    fi
    PROCESSED_ITEMS="${PROCESSED_ITEMS}${PROCESSED_ITEMS:+ }$2"
}

# This filtering harness observes parent-shell state, as does the Cask stub
# below. Real CLI installs cross a process boundary; their output/lifecycle is
# covered by test-vscode-extensions.py instead of this in-memory counter.
install_vscode_extension() {
    PROCESSED_ITEMS="${PROCESSED_ITEMS}${PROCESSED_ITEMS:+ }$1"
}

is_cask_installed() {
    return 1
}

install_brew_cask() {
    PROCESSED_ITEMS="${PROCESSED_ITEMS}${PROCESSED_ITEMS:+ }$1"
}

repository_verify() {
    PROCESSED_ITEMS="${PROCESSED_ITEMS}${PROCESSED_ITEMS:+ }$(basename "$1")"
}

pass() {
    echo "PASS: $1"
}

fail() {
    echo "FAIL: $1"
    ((TEST_FAILURES++))
}

expect_processed() {
    local label="$1"
    local expected="$2"

    shift 2
    PROCESSED_ITEMS=""
    MODULE_CHANGED=false

    "$@" >/dev/null

    if [[ "$PROCESSED_ITEMS" == "$expected" ]]; then
        pass "$label"
    else
        fail "$label (expected '$expected', got '$PROCESSED_ITEMS')"
    fi
}

verification_application_operation_hook() {
    [[ "$1" == app-store && "$3" == inspect && "$4" == noop ]] || return 2
    PROCESSED_ITEMS="${PROCESSED_ITEMS}${PROCESSED_ITEMS:+ }$2"
}

expect_appstore_observed() {
    local label="$1" expected="$2" status
    PROCESSED_ITEMS=""
    MODULE_CHANGED=false
    : > "$TEST_ROOT/forbidden-mas-calls"
    install_appstore_apps >/dev/null
    status=$?
    if [[ $status -eq 0 && "$PROCESSED_ITEMS" == "$expected" &&
          "$MODULE_CHANGED" == false && ! -s "$TEST_ROOT/forbidden-mas-calls" ]]; then
        pass "$label"
    else
        fail "$label (status=$status, observed='$PROCESSED_ITEMS', expected='$expected', changed=$MODULE_CHANGED)"
    fi
}

expect_status() {
    local label="$1"
    local expected="$2"

    shift 2
    "$@" >/dev/null
    local actual=$?

    if [[ $actual -eq $expected ]]; then
        pass "$label -> $actual"
    else
        fail "$label (expected $expected, got $actual)"
    fi
}

run_bootstrap_orchestration() {
    local orchestration

    orchestration="$(awk '
        /^[[:space:]]*run_module "Workspace" bootstrap_workspace$/ {
            capture = 1
        }

        capture && /^[[:space:]]*;;$/ {
            exit
        }

        capture {
            print
        }
    ' "$PROJECT_ROOT/bootstrap.sh")"

    [[ -n "$orchestration" ]] || return 2
    eval "$orchestration"
}

reset_orchestration() {
    MODULES_CHECKED=0
    INSTALLED_COUNT=0
    SKIPPED_COUNT=0
    WARNING_COUNT=0
    ERROR_COUNT=0
    PROCESSED_ITEMS=""
}

record_orchestration_step() {
    PROCESSED_ITEMS="${PROCESSED_ITEMS}${PROCESSED_ITEMS:+ }$1"
}

bootstrap_workspace() {
    record_orchestration_step workspace
}

configure_git() {
    record_orchestration_step git-configuration
}

git_configuration_scope_selected() { return 0; }
ssh_configuration_scope_selected() { return 1; }

apply_vscode_settings() {
    record_orchestration_step vscode-settings
}

bootstrap_zsh() {
    record_orchestration_step shell-zsh
}

apply_macos_settings() {
    record_orchestration_step macos-settings
}

write_blueprint() {
    local include_items="${1:-true}"
    local include_all_items="${2:-false}"

    {
        echo '[categories]'
        echo 'git-configuration="true"'
        echo 'ssh-configuration="true"'
        echo 'vscode-settings="true"'
        echo 'macos-finder="true"'
        echo 'macos-dock="true"'
        echo 'macos-windows="true"'
        echo 'macos-keyboard="true"'
        echo 'macos-trackpad="true"'
        echo 'macos-screenshots="true"'
        echo
        echo '[homebrew-packages]'
        [[ "$include_items" == true ]] && echo 'selected-package'
        [[ "$include_all_items" == true ]] && echo 'unselected-package'
        echo
        echo '[homebrew-casks]'
        [[ "$include_items" == true ]] && echo 'selected-cask'
        [[ "$include_all_items" == true ]] && echo 'unselected-cask'
        echo
        echo '[app-store]'
        [[ "$include_items" == true ]] && echo '111'
        [[ "$include_all_items" == true ]] && echo '222'
        echo
        echo '[vscode-extensions]'
        [[ "$include_items" == true ]] && echo 'selected.extension'
        [[ "$include_all_items" == true ]] && echo 'unselected.extension'
        echo
        echo '[workspace-folders]'
        [[ "$include_items" == true ]] && echo 'SelectedFolder'
        [[ "$include_all_items" == true ]] && echo 'UnselectedFolder'
        [[ "$include_items" == true ]] && echo 'LegacyUserFolder'
        [[ "$include_items" == true ]] && echo 'LegacySystemFolder'
        echo
        echo '[git-repositories]'
        [[ "$include_items" == true ]] && echo 'selected-repository'
        [[ "$include_all_items" == true ]] && echo 'unselected-repository'
    } > "$BLUEPRINT_FILE"
}

set_blueprint_category() {
    local category="$1"
    local enabled="$2"

    sed -i.bak \
        "s/^${category}=\"[^\"]*\"$/${category}=\"${enabled}\"/" \
        "$BLUEPRINT_FILE"
    rm -f "$BLUEPRINT_FILE.bak"
}

write_generated_state() {
    mkdir -p "$BLUEPRINT_GENERATED_DIR/workspace" "$HOME"

    printf '%s\n' selected-package unselected-package > \
        "$BLUEPRINT_GENERATED_DIR/brew-packages.conf"
    printf '%s\n' selected-cask unselected-cask > \
        "$BLUEPRINT_GENERATED_DIR/brew-casks.conf"
    printf '%s\n' '111|Selected App' '222|Unselected App' > \
        "$BLUEPRINT_GENERATED_DIR/appstore.conf"
    printf '%s\n' selected.extension unselected.extension > \
        "$BLUEPRINT_GENERATED_DIR/vscode-extensions.conf"
    printf '%s\n' \
        'SelectedFolder|workspace' \
        'UnselectedFolder|workspace' \
        'LegacyUserFolder|user' \
        'LegacySystemFolder|system' > \
        "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"

    {
        echo '[selected-repository]'
        echo "PATH=\"$HOME/SelectedFolder/selected-repository\""
        echo 'REMOTE="git@example.com:selected/repository.git"'
        echo 'CURRENT_BRANCH="main"'
        echo 'NAME="repository"'
        echo 'DEFAULT_BRANCH="main"'
        for key in HAS_UNCOMMITTED_CHANGES HAS_VSCODE_FOLDER HAS_SETTINGS HAS_TASKS HAS_LAUNCH HAS_EXTENSIONS; do
            printf '%s="false"\n' "$key"
        done
        echo
        echo '[unselected-repository]'
        echo "PATH=\"$HOME/UnselectedFolder/unselected-repository\""
        echo 'REMOTE="git@example.com:unselected/repository.git"'
        echo 'CURRENT_BRANCH="main"'
        echo 'NAME="repository"'
        echo 'DEFAULT_BRANCH="main"'
        for key in HAS_UNCOMMITTED_CHANGES HAS_VSCODE_FOLDER HAS_SETTINGS HAS_TASKS HAS_LAUNCH HAS_EXTENSIONS; do
            printf '%s="false"\n' "$key"
        done
    } > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
}

write_generated_state

expect_processed "missing Blueprint keeps all Homebrew packages eligible" \
    "selected-package unselected-package" install_brew_packages
expect_processed "missing Blueprint keeps all Homebrew casks eligible" \
    "selected-cask unselected-cask" install_brew_casks
expect_appstore_observed "missing Blueprint observes all App Store IDs without installation" \
    "111 222"
expect_processed "missing Blueprint keeps all VS Code extensions eligible" \
    "selected.extension unselected.extension" install_vscode_extensions
bootstrap_workspace_folders >/dev/null
if [[ -d "$HOME/SelectedFolder" && -d "$HOME/UnselectedFolder" &&
      -d "$HOME/LegacyUserFolder" && -d "$HOME/LegacySystemFolder" ]]; then
    pass "missing Blueprint keeps all workspace folders eligible"
else
    fail "missing Blueprint did not keep all workspace folders eligible"
fi
expect_processed "missing Blueprint keeps all repositories eligible" \
    "selected-repository unselected-repository" bootstrap_workspace_repositories

rm -rf "$HOME/SelectedFolder" "$HOME/UnselectedFolder" \
    "$HOME/LegacyUserFolder" "$HOME/LegacySystemFolder"
write_blueprint

expect_processed "Blueprint filters Homebrew packages" \
    "selected-package" install_brew_packages
expect_processed "Blueprint filters Homebrew casks" \
    "selected-cask" install_brew_casks
expect_appstore_observed "Blueprint filters assisted App Store observation by ID" \
    "111"
expect_processed "Blueprint filters VS Code extensions" \
    "selected.extension" install_vscode_extensions
bootstrap_workspace_folders >/dev/null
if [[ -d "$HOME/SelectedFolder" &&
      ! -d "$HOME/UnselectedFolder" &&
      ! -d "$HOME/LegacyUserFolder" &&
      ! -d "$HOME/LegacySystemFolder" ]]; then
    pass "Blueprint filters candidates and ignores hidden legacy folder selections"
else
    fail "Blueprint workspace folder filtering failed"
fi
expect_processed "Blueprint filters repositories by identifier" \
    "selected-repository" bootstrap_workspace_repositories

rm -rf "$HOME/SelectedFolder" "$HOME/UnselectedFolder" \
    "$HOME/LegacyUserFolder" "$HOME/LegacySystemFolder"
write_blueprint false

expect_processed "empty Homebrew package section processes zero items" \
    "" install_brew_packages
expect_processed "empty Homebrew cask section processes zero items" \
    "" install_brew_casks
expect_appstore_observed "empty App Store section observes zero items" ""
expect_processed "empty VS Code extension section processes zero items" \
    "" install_vscode_extensions
bootstrap_workspace_folders >/dev/null
if [[ ! -d "$HOME/SelectedFolder" && ! -d "$HOME/UnselectedFolder" ]]; then
    pass "empty workspace folder section processes zero items"
else
    fail "empty workspace folder section processed items"
fi
expect_processed "empty repository section processes zero items" \
    "" bootstrap_workspace_repositories

write_blueprint
echo '[malformed' >> "$BLUEPRINT_FILE"
expect_status "malformed Blueprint prevents filtered operations" 2 \
    blueprint_validate "$BLUEPRINT_FILE"

write_blueprint
sed -i.bak 's/selected-package/stale-package/' "$BLUEPRINT_FILE"
rm -f "$BLUEPRINT_FILE.bak"
expect_status "stale selection preserves warning status" 1 \
    blueprint_validate "$BLUEPRINT_FILE"

write_blueprint
{
    echo
    echo '[selected-repository]'
    echo 'PATH="/duplicate"'
} >> "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
expect_status "repository collision remains an error" 2 \
    blueprint_validate "$BLUEPRINT_FILE"

install_brew_packages() {
    record_orchestration_step homebrew-packages
}

install_brew_casks() {
    record_orchestration_step homebrew-casks
}

install_appstore_apps() {
    record_orchestration_step app-store
}

install_vscode_extensions() {
    record_orchestration_step vscode-extensions
}

rm -f "$BLUEPRINT_FILE"
reset_orchestration
run_bootstrap_orchestration >/dev/null
expected_steps="workspace git-configuration homebrew-packages homebrew-casks app-store vscode-extensions vscode-settings shell-zsh macos-settings"

if [[ "$PROCESSED_ITEMS" == "$expected_steps" ]]; then
    pass "missing Blueprint keeps category consumers in Bootstrap orchestration"
else
    fail "missing Blueprint category orchestration (processed='$PROCESSED_ITEMS')"
fi

write_blueprint
set_blueprint_category git-configuration false
set_blueprint_category vscode-settings false
reset_orchestration
run_bootstrap_orchestration >/dev/null
expected_steps="workspace homebrew-packages homebrew-casks app-store vscode-extensions macos-settings"

if [[ "$PROCESSED_ITEMS" == "$expected_steps" ]]; then
    pass "disabled Git and VS Code Settings do not disable VS Code extensions"
else
    fail "Git and VS Code category filtering (processed='$PROCESSED_ITEMS')"
fi

set_blueprint_category macos-finder false
set_blueprint_category macos-dock false
set_blueprint_category macos-windows false
set_blueprint_category macos-keyboard false
set_blueprint_category macos-trackpad false
set_blueprint_category macos-screenshots false
reset_orchestration
run_bootstrap_orchestration >/dev/null
expected_steps="workspace homebrew-packages homebrew-casks app-store vscode-extensions"

if [[ "$PROCESSED_ITEMS" == "$expected_steps" ]]; then
    pass "disabled categories omit Git, VS Code Settings, and macOS orchestration"
else
    fail "disabled category orchestration (processed='$PROCESSED_ITEMS')"
fi

CHECK_RESULT=0

check_finder() {
    record_orchestration_step check-finder
    return "$CHECK_RESULT"
}

check_dock() {
    record_orchestration_step check-dock
    return "$CHECK_RESULT"
}

check_windows() {
    record_orchestration_step check-windows
    return "$CHECK_RESULT"
}

check_keyboard() {
    record_orchestration_step check-keyboard
    return "$CHECK_RESULT"
}

check_trackpad() {
    record_orchestration_step check-trackpad
    return "$CHECK_RESULT"
}

check_screenshots() {
    record_orchestration_step check-screenshots
    return "$CHECK_RESULT"
}

apply_finder_settings() {
    record_orchestration_step apply-finder
}

apply_dock_settings() {
    record_orchestration_step apply-dock
}

apply_keyboard_settings() {
    record_orchestration_step apply-keyboard
}

apply_trackpad_settings() {
    record_orchestration_step apply-trackpad
}

apply_windows_settings() {
    record_orchestration_step apply-windows
}

apply_screenshots_settings() {
    record_orchestration_step apply-screenshots
}

rm -f "$BLUEPRINT_FILE"
PROCESSED_ITEMS=""
check_macos_settings
expected_steps="check-finder check-dock check-windows check-keyboard check-trackpad check-screenshots"

if [[ "$PROCESSED_ITEMS" == "$expected_steps" ]]; then
    pass "missing Blueprint keeps all macOS modules eligible"
else
    fail "missing Blueprint macOS eligibility (processed='$PROCESSED_ITEMS')"
fi

write_blueprint
PROCESSED_ITEMS=""
check_macos_settings

if [[ "$PROCESSED_ITEMS" == "$expected_steps" ]]; then
    pass "true Blueprint categories keep all macOS modules eligible"
else
    fail "true Blueprint macOS eligibility (processed='$PROCESSED_ITEMS')"
fi

set_blueprint_category macos-finder false
set_blueprint_category macos-dock false
set_blueprint_category macos-windows false
set_blueprint_category macos-keyboard false
set_blueprint_category macos-trackpad false
set_blueprint_category macos-screenshots false
PROCESSED_ITEMS=""
check_macos_settings

if [[ -z "$PROCESSED_ITEMS" ]]; then
    pass "false Blueprint categories skip all macOS module checks"
else
    fail "false Blueprint macOS checks (processed='$PROCESSED_ITEMS')"
fi

write_blueprint
set_blueprint_category macos-dock false
set_blueprint_category macos-trackpad false
PROCESSED_ITEMS=""
check_macos_settings
expected_steps="check-finder check-windows check-keyboard check-screenshots"

if [[ "$PROCESSED_ITEMS" == "$expected_steps" ]]; then
    pass "mixed Blueprint categories check macOS modules independently"
else
    fail "mixed Blueprint macOS checks (processed='$PROCESSED_ITEMS')"
fi

CHECK_RESULT=1
PROCESSED_ITEMS=""
apply_macos_components
expected_steps="check-finder apply-finder check-windows apply-windows check-keyboard apply-keyboard check-screenshots apply-screenshots"

if [[ "$PROCESSED_ITEMS" == "$expected_steps" ]]; then
    pass "mixed Blueprint categories apply macOS modules independently"
else
    fail "mixed Blueprint macOS apply (processed='$PROCESSED_ITEMS')"
fi

success() { echo "[ OK ] $1"; }
warning() { echo "[WARN] $1"; }
error() { echo "[ERROR] $1"; }

write_generated_state
write_blueprint true true
MODE="--bootstrap"
START_TIME=""
BLUEPRINT_BOOTSTRAP_SUMMARY=true
WARNING_COUNT=0
ERROR_COUNT=0
before_warnings=$WARNING_COUNT
before_errors=$ERROR_COUNT
toolkit_exit_code
before_status=$?
summary_output="$(show_summary)"
toolkit_exit_code
after_status=$?

if [[ "$summary_output" == *'Bootstrap completed successfully'* &&
      "$summary_output" == *'Homebrew packages      2 / 2 selected'* &&
      "$summary_output" == *'Homebrew casks         2 / 2 selected'* &&
      "$summary_output" == *'App Store              2 / 2 selected'* &&
      "$summary_output" == *'VS Code extensions     2 / 2 selected'* &&
      "$summary_output" == *'Folders                2 / 2 selected'* &&
      "$summary_output" == *'Git repositories       2 / 2 selected'* &&
      "$summary_output" == *'SSH Configuration      Enabled'* &&
      $WARNING_COUNT -eq $before_warnings &&
      $ERROR_COUNT -eq $before_errors &&
      $before_status -eq 0 && $after_status -eq 0 ]]; then
    pass "Blueprint Bootstrap Summary reports full selections and preserves success status"
else
    fail "Blueprint full-selection Summary or success preservation failed"
fi

write_blueprint
set_blueprint_category ssh-configuration false
set_blueprint_category vscode-settings false
set_blueprint_category macos-dock false
set_blueprint_category macos-trackpad false
MODE="--bootstrap"
START_TIME=""
BLUEPRINT_BOOTSTRAP_SUMMARY=true
WARNING_COUNT=2
ERROR_COUNT=1
before_warnings=$WARNING_COUNT
before_errors=$ERROR_COUNT
toolkit_exit_code
before_status=$?
summary_output="$(show_summary)"
toolkit_exit_code
after_status=$?

if [[ "$summary_output" == *'Bootstrap completed with errors'* &&
      "$summary_output" != *'Bootstrap completed successfully'* &&
      "$summary_output" == *'Homebrew packages      1 / 2 selected'* &&
      "$summary_output" == *'Homebrew casks         1 / 2 selected'* &&
      "$summary_output" == *'App Store              1 / 2 selected'* &&
      "$summary_output" == *'VS Code extensions     1 / 2 selected'* &&
      "$summary_output" == *'Folders                1 / 2 selected'* &&
      "$summary_output" == *'Git repositories       1 / 2 selected'* &&
      "$summary_output" == *'Git Configuration      Enabled'* &&
      "$summary_output" == *'SSH Configuration      Skipped'* &&
      "$summary_output" == *'VS Code Settings       Skipped'* &&
      "$summary_output" == *'Finder                 Enabled'* &&
      "$summary_output" == *'Dock                   Skipped'* &&
      "$summary_output" == *'Keyboard               Enabled'* &&
      "$summary_output" == *'Trackpad               Skipped'* &&
      "$summary_output" == *'Screenshots            Enabled'* &&
      "$summary_output" == *'Warnings               2'* &&
      "$summary_output" == *'Errors                 1'* &&
      $WARNING_COUNT -eq $before_warnings &&
      $ERROR_COUNT -eq $before_errors &&
      $before_status -eq 2 && $after_status -eq 2 ]]; then
    pass "Blueprint Bootstrap Summary reports partial selections and mixed categories without changing status"
else
    fail "Blueprint partial Summary or lifecycle preservation failed"
fi

write_blueprint false
WARNING_COUNT=0
ERROR_COUNT=0
summary_warning_module() { return 1; }
summary_success_module() { return 0; }
run_module "Summary Warning" summary_warning_module >/dev/null
run_module "Summary Later Success" summary_success_module >/dev/null
before_warnings=$WARNING_COUNT
before_errors=$ERROR_COUNT
toolkit_exit_code
before_status=$?
summary_output="$(show_summary)"
toolkit_exit_code
after_status=$?

if [[ "$summary_output" == *'Bootstrap completed with warnings'* &&
      "$summary_output" != *'Bootstrap completed successfully'* &&
      "$summary_output" == *'Homebrew packages      0 / 2 selected'* &&
      "$summary_output" == *'App Store              0 / 2 selected'* &&
      "$summary_output" == *'Folders                0 / 2 selected'* &&
      "$summary_output" == *'Git repositories       0 / 2 selected'* &&
      $WARNING_COUNT -eq $before_warnings &&
      $ERROR_COUNT -eq $before_errors &&
      $before_status -eq 1 && $after_status -eq 1 ]]; then
    pass "Blueprint Bootstrap Summary reports zero selections and preserves stale warning status"
else
    fail "Blueprint zero-selection Summary or warning preservation failed"
fi

rm -f "$BLUEPRINT_FILE"
MODULES_CHECKED=7
INSTALLED_COUNT=2
SKIPPED_COUNT=5
WARNING_COUNT=0
ERROR_COUNT=0
summary_output="$(show_summary)"

if [[ "$summary_output" == *'Modules Checked : 7'* &&
      "$summary_output" == *'Bootstrap completed successfully'* &&
      "$summary_output" != *'Applications'* &&
      "$summary_output" != *'selected'* ]]; then
    pass "missing Blueprint retains the legacy Bootstrap Summary"
else
    fail "missing Blueprint showed a misleading Blueprint Summary"
fi

WARNING_COUNT=1
ERROR_COUNT=0
before_warnings=$WARNING_COUNT
before_errors=$ERROR_COUNT
toolkit_exit_code
before_status=$?
summary_output="$(show_summary)"
toolkit_exit_code
after_status=$?

if [[ "$summary_output" == *'Bootstrap completed with warnings'* &&
      "$summary_output" != *'Bootstrap completed successfully'* &&
      "$summary_output" == *'Warnings        : 1'* &&
      $WARNING_COUNT -eq $before_warnings &&
      $ERROR_COUNT -eq $before_errors &&
      $before_status -eq 1 && $after_status -eq 1 ]]; then
    pass "legacy Bootstrap Summary reports warnings without changing status"
else
    fail "legacy warning Summary or lifecycle preservation failed"
fi

WARNING_COUNT=1
ERROR_COUNT=1
before_warnings=$WARNING_COUNT
before_errors=$ERROR_COUNT
toolkit_exit_code
before_status=$?
summary_output="$(show_summary)"
toolkit_exit_code
after_status=$?

if [[ "$summary_output" == *'Bootstrap completed with errors'* &&
      "$summary_output" != *'Bootstrap completed successfully'* &&
      "$summary_output" == *'Warnings        : 1'* &&
      "$summary_output" == *'Errors          : 1'* &&
      $WARNING_COUNT -eq $before_warnings &&
      $ERROR_COUNT -eq $before_errors &&
      $before_status -eq 2 && $after_status -eq 2 ]]; then
    pass "legacy Bootstrap Summary gives errors precedence without changing status"
else
    fail "legacy error-precedence Summary or lifecycle preservation failed"
fi

if [[ $TEST_FAILURES -ne 0 ]]; then
    echo
    echo "$TEST_FAILURES Blueprint Bootstrap filtering test(s) failed"
    exit 1
fi

echo
echo "All Blueprint Bootstrap filtering tests passed"
