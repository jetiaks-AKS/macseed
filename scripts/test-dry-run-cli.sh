#!/bin/bash

# ==========================================
# Dry-run CLI and Startup Harness
# ==========================================

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
FIXTURE_ROOT="$TEST_ROOT/project"
MOCK_BIN="$TEST_ROOT/bin"
SPY_FILE="$TEST_ROOT/spy.log"
TEST_FAILURES=0

trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

mkdir -p "$FIXTURE_ROOT" "$MOCK_BIN"
cp "$PROJECT_ROOT/bootstrap.sh" "$FIXTURE_ROOT/bootstrap.sh"

while IFS= read -r source_file; do
    mkdir -p "$FIXTURE_ROOT/$(dirname "$source_file")"
    printf '%s\n' '#!/bin/bash' > "$FIXTURE_ROOT/$source_file"
done < <(awk '/^source / { print $2 }' "$PROJECT_ROOT/bootstrap.sh")

cp "$PROJECT_ROOT/modules/core/common/common.sh" \
    "$FIXTURE_ROOT/modules/core/common/common.sh"
cp "$PROJECT_ROOT/modules/core/logger/logger.sh" \
    "$FIXTURE_ROOT/modules/core/logger/logger.sh"
cp "$PROJECT_ROOT/modules/core/homebrew/homebrew.sh" \
    "$FIXTURE_ROOT/modules/core/homebrew/homebrew.sh"
cp "$PROJECT_ROOT/modules/core/preflight/preflight.sh" \
    "$FIXTURE_ROOT/modules/core/preflight/preflight.sh"
cp "$PROJECT_ROOT/modules/discovery/homebrew.sh" \
    "$FIXTURE_ROOT/modules/discovery/homebrew.sh"

write_fixture_file() {
    local relative_path="$1"
    shift
    printf '%s\n' "$@" > "$FIXTURE_ROOT/$relative_path"
}

write_fixture_file modules/core/verification/verification.sh \
    'verification_reset() { :; }' \
    'verification_operation() { :; }' \
    'verification_run() { :; }'

write_fixture_file config/toolkit.conf \
    'TOOLKIT_NAME="Mac Bootstrap Toolkit Test"' \
    'TOOLKIT_VERSION="test"' \
    'MIN_MACOS_VERSION=13'

write_fixture_file modules/blueprint/blueprint.sh \
    'BLUEPRINT_BOOTSTRAP_SUMMARY=false' \
    'blueprint_exists() { [[ "${TEST_BLUEPRINT_PRESENT:-false}" == true ]]; }' \
    'blueprint_validate() { return "${TEST_BLUEPRINT_STATUS:-0}"; }' \
    'blueprint_selected_items() { printf "%s\n" selected; }' \
    'blueprint_category_enabled() {' \
    '    blueprint_exists || return 0' \
    '    case "$1" in' \
    '        git-configuration) [[ "${TEST_GIT_ENABLED:-true}" == true ]] ;;' \
    '        vscode-settings) [[ "${TEST_VSCODE_SETTINGS_ENABLED:-true}" == true ]] ;;' \
    '        *) return 0 ;;' \
    '    esac' \
    '}' \
    'blueprint_generated_file() { printf "%s\n" generated; }'

write_fixture_file modules/core/git/git.sh \
    'load_git_configuration() { return "${TEST_INPUT_STATUS:-0}"; }' \
    'git_configuration_scope_selected() { return 0; }' \
    'check_git() { return 0; }' \
    'preview_git_configuration() { printf "%s\n" git-config-preview >> "$TEST_SPY_FILE"; }' \
    'configure_git() { printf "%s\n" git-config-write >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/core/ssh/ssh.sh \
    'check_ssh() { return 0; }'

write_fixture_file modules/ssh/config.sh \
    'ssh_configuration_scope_selected() { return 0; }' \
    'ssh_snapshot_validate() { : > "$1"; return 0; }' \
    'preview_ssh_configuration() { printf "%s\n" ssh-preview >> "$TEST_SPY_FILE"; }' \
    'bootstrap_ssh_configuration() { printf "%s\n" ssh-write >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/core/terminal/terminal.sh \
    'check_terminal() { return 0; }'

write_fixture_file modules/core/launcher/launcher.sh \
    'configure_bs_launcher() { printf "%s\n" launcher-setup >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/apps/brew-packages.sh \
    'read_brew_packages_configuration() { return "${TEST_INPUT_STATUS:-0}"; }' \
    'preview_brew_packages() { if [[ "${TEST_HAS_PLANS:-true}" == true ]]; then preview_action "Would install fixture formula"; fi; printf "%s\n" formula-preview >> "$TEST_SPY_FILE"; [[ "${TEST_PREVIEW_ERROR:-false}" != true ]] || return 2; }' \
    'install_brew_packages() { printf "%s\n" brew-install >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/apps/brew-casks.sh \
    'read_brew_casks_configuration() { return "${TEST_INPUT_STATUS:-0}"; }' \
    'preview_brew_casks() { printf "%s\n" cask-preview >> "$TEST_SPY_FILE"; }' \
    'install_brew_casks() { printf "%s\n" brew-cask-install >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/apps/appstore.sh \
    'read_appstore_configuration() { return "${TEST_INPUT_STATUS:-0}"; }' \
    'preview_appstore_apps() { printf "%s\n" appstore-preview >> "$TEST_SPY_FILE"; }' \
    'install_appstore_apps() { printf "%s\n" mas-install >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/vscode/extensions.sh \
    'read_vscode_extensions_configuration() { return "${TEST_INPUT_STATUS:-0}"; }' \
    'preview_vscode_extensions() { printf "%s\n" extensions-preview >> "$TEST_SPY_FILE"; }' \
    'install_vscode_extensions() { printf "%s\n" code-install >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/vscode/settings.sh \
    'validate_vscode_settings_source() { return 0; }' \
    'preview_vscode_settings() { printf "%s\n" vscode-settings-preview >> "$TEST_SPY_FILE"; }' \
    'apply_vscode_settings() { printf "%s\n" vscode-write >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/shell/zsh.sh \
    'zsh_snapshot_validate() { ZSH_SNAPSHOT_STATUS=eligible; return 0; }' \
    'preview_zsh() { printf "%s\n" zsh-preview >> "$TEST_SPY_FILE"; }' \
    'bootstrap_zsh() { printf "%s\n" zsh-write >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/settings/macos/macos.sh \
    'FINDER_CONFIG=finder' \
    'DOCK_CONFIG=dock' \
    'WINDOWS_CONFIG=windows' \
    'KEYBOARD_CONFIG=keyboard' \
    'TRACKPAD_CONFIG=trackpad' \
    'SCREENSHOTS_CONFIG=screenshots' \
    'validate_screenshots_config() { return "${TEST_INPUT_STATUS:-0}"; }' \
    'validate_defaults_config() { return "${TEST_INPUT_STATUS:-0}"; }' \
    'check_macos_settings() { return 1; }' \
    'preview_macos_settings() { printf "%s\n" macos-preview >> "$TEST_SPY_FILE"; }' \
    'apply_macos_settings() { printf "%s\n" defaults-write >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/bootstrap/workspace/workspace.sh \
    'workspace_validate_bootstrap_inputs() { return "${TEST_INPUT_STATUS:-0}"; }' \
    'preview_workspace_folders() { printf "%s\n" workspace-folders-preview >> "$TEST_SPY_FILE"; }' \
    'preview_workspace_repositories() { printf "%s\n" workspace-repositories-preview >> "$TEST_SPY_FILE"; }' \
    'bootstrap_workspace() { printf "%s\n" workspace-mutation >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/blueprint/selector.sh \
    'blueprint_selector_run() { printf "%s\n" blueprint-selector >> "$TEST_SPY_FILE"; }'

write_fixture_file modules/discovery/discovery.sh \
    'run_discovery() { if [[ "${TEST_DISCOVERY_REAL_HOMEBREW:-false}" == true ]]; then run_module "Homebrew Discovery" discover_homebrew; else printf "%s\n" discovery >> "$TEST_SPY_FILE"; fi; }'

write_mock() {
    local name="$1"
    shift
    printf '%s\n' '#!/bin/bash' "$@" > "$MOCK_BIN/$name"
    chmod +x "$MOCK_BIN/$name"
}

write_mock ping 'exit 0'
write_mock xcode-select 'exit 0'
write_mock sw_vers 'printf "%s\n" 14'
write_mock sudo 'printf "%s\n" sudo >> "$TEST_SPY_FILE"; exit 0'
write_mock curl \
    'case "$*" in' \
    '    *-fsSI*) exit 0 ;;' \
    '    *) printf "%s\n" homebrew-installer >> "$TEST_SPY_FILE"; exit 2 ;;' \
    'esac'
write_mock mas 'printf "%s\n" mas-command >> "$TEST_SPY_FILE"; exit 2'
write_mock code 'printf "%s\n" code-command >> "$TEST_SPY_FILE"; exit 2'
write_mock defaults 'printf "%s\n" defaults-command >> "$TEST_SPY_FILE"; exit 2'
write_mock killall 'printf "%s\n" killall >> "$TEST_SPY_FILE"; exit 2'
write_mock git 'exit 0'

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; ((TEST_FAILURES++)); }

run_entrypoint() {
    : > "$SPY_FILE"
    (
        cd "$FIXTURE_ROOT" || exit 2
        PATH="$MOCK_BIN:/usr/bin:/bin" \
        TEST_SPY_FILE="$SPY_FILE" \
        TEST_BLUEPRINT_PRESENT="${TEST_BLUEPRINT_PRESENT:-false}" \
        TEST_BLUEPRINT_STATUS="${TEST_BLUEPRINT_STATUS:-0}" \
        TEST_INPUT_STATUS="${TEST_INPUT_STATUS:-0}" \
        TEST_HAS_PLANS="${TEST_HAS_PLANS:-true}" \
        TEST_GIT_ENABLED="${TEST_GIT_ENABLED:-true}" \
        TEST_VSCODE_SETTINGS_ENABLED="${TEST_VSCODE_SETTINGS_ENABLED:-true}" \
        TEST_DISCOVERY_REAL_HOMEBREW="${TEST_DISCOVERY_REAL_HOMEBREW:-false}" \
            ./bootstrap.sh "$@"
    ) > "$TEST_ROOT/output" 2>&1
    ENTRYPOINT_STATUS=$?
    ENTRYPOINT_OUTPUT="$(cat "$TEST_ROOT/output")"
    ENTRYPOINT_SPY="$(cat "$SPY_FILE")"
}

assert_status() {
    local expected="$1"
    local label="$2"
    if [[ $ENTRYPOINT_STATUS -eq $expected ]]; then
        pass "$label"
    else
        fail "$label (expected $expected, got $ENTRYPOINT_STATUS)"
    fi
}

write_mock brew 'exit 0'
TEST_BLUEPRINT_PRESENT=false TEST_BLUEPRINT_STATUS=0 TEST_INPUT_STATUS=0 \
    run_entrypoint --dry-run
assert_status 0 "--dry-run is accepted"
if [[ "$ENTRYPOINT_OUTPUT" == *'Mode    : Preview'* &&
      "$ENTRYPOINT_OUTPUT" == *'Modules Inspected :'* &&
      "$ENTRYPOINT_OUTPUT" != *'Installed       :'* &&
      "$ENTRYPOINT_OUTPUT" != *'Skipped         :'* ]]; then
    pass "Preview uses mode-appropriate Summary"
else
    fail "Preview output or Summary is incorrect"
fi
if [[ "$ENTRYPOINT_SPY" == *git-config-preview* &&
      "$ENTRYPOINT_SPY" == *vscode-settings-preview* &&
      "$ENTRYPOINT_SPY" == *zsh-preview* &&
      "$ENTRYPOINT_SPY" == *ssh-preview* &&
      "$ENTRYPOINT_SPY" == *workspace-folders-preview* &&
      "$ENTRYPOINT_SPY" == *workspace-repositories-preview* &&
      "$ENTRYPOINT_SPY" == *macos-preview* ]]; then
    pass "Preview dispatch includes all implemented domains"
else
    fail "Preview dispatch omitted a completed domain: $ENTRYPOINT_SPY"
fi

run_entrypoint --check --discover
assert_status 1 "conflicting execution modes are rejected"

run_entrypoint --dry-run --dry-run
assert_status 1 "duplicate execution modes are rejected"

run_entrypoint
assert_status 1 "missing execution mode is rejected"

run_entrypoint --help
assert_status 0 "--help behavior is preserved"

run_entrypoint --version
assert_status 0 "--version behavior is preserved"

run_entrypoint --check
assert_status 0 "a single existing mode still works"

run_entrypoint --discover
assert_status 0 "Discovery dispatch remains available"
[[ "$ENTRYPOINT_SPY" == *discovery* ]] || fail "Discovery dispatch was skipped"

mv "$MOCK_BIN/brew" "$TEST_ROOT/brew-present"
TEST_DISCOVERY_REAL_HOMEBREW=true run_entrypoint --discover <<< y
assert_status 2 "Discovery reports absent Homebrew without an inventory"
[[ "$ENTRYPOINT_OUTPUT" == *'Homebrew is not installed'* &&
   "$ENTRYPOINT_OUTPUT" != *'Install Homebrew?'* &&
   "$ENTRYPOINT_SPY" != *homebrew-installer* ]] ||
    fail "Discovery offered or ran the Homebrew installer: $ENTRYPOINT_OUTPUT / $ENTRYPOINT_SPY"

: > "$SPY_FILE"
(
    cd "$FIXTURE_ROOT" || exit 2
    PATH="$MOCK_BIN:/usr/bin:/bin" TEST_SPY_FILE="$SPY_FILE" \
        TEST_DISCOVERY_REAL_HOMEBREW=true \
        BUNDLE_COMMANDS_FILE="$PROJECT_ROOT/modules/bundle/commands.sh" \
        /bin/bash -c 'log(){ :; }; source modules/core/common/common.sh; source "$BUNDLE_COMMANDS_FILE"; bundle_capture'
) <<< y > "$TEST_ROOT/capture-output" 2>&1
capture_status=$?
if [[ $capture_status -eq 2 && "$(cat "$TEST_ROOT/capture-output")" == *'Homebrew is not installed'* &&
      "$(cat "$TEST_ROOT/capture-output")" != *'Install Homebrew?'* &&
      "$(cat "$SPY_FILE")" != *homebrew-installer* ]]; then
    pass "Capture staged Discovery never offers or runs Homebrew installation"
else
    fail "Capture staged Discovery mutated or misreported absent Homebrew (status $capture_status): $(cat "$TEST_ROOT/capture-output") / $(cat "$SPY_FILE")"
fi
mv "$TEST_ROOT/brew-present" "$MOCK_BIN/brew"
run_entrypoint --blueprint
assert_status 0 "Blueprint selector dispatch remains available"
[[ "$ENTRYPOINT_SPY" == blueprint-selector ]] || fail "Blueprint selector reached normal preflight"

run_entrypoint --dry-run --verbose
assert_status 0 "--verbose remains compatible with Preview"

rm -f "$MOCK_BIN/brew"
run_entrypoint --dry-run
assert_status 1 "absent Homebrew remains a Preview warning"
if [[ "$ENTRYPOINT_SPY" != *sudo* && "$ENTRYPOINT_SPY" != *homebrew-installer* ]]; then
    pass "Preview skips sudo and the Homebrew installer"
else
    fail "Preview reached sudo or the Homebrew installer: $ENTRYPOINT_SPY"
fi

for forbidden in brew-install brew-cask-install mas-install code-install \
    workspace-mutation vscode-write defaults-write defaults-command killall git-config-write; do
    if [[ "$ENTRYPOINT_SPY" == *"$forbidden"* ]]; then
        fail "Preview performed forbidden action: $forbidden"
    fi
done

if [[ $TEST_FAILURES -eq 0 ]]; then
    pass "Preview performs no domain target mutations"
fi

write_mock brew 'exit 0'
TEST_BLUEPRINT_PRESENT=true TEST_BLUEPRINT_STATUS=2 TEST_INPUT_STATUS=0 \
    run_entrypoint --dry-run
assert_status 2 "malformed Blueprint returns 2"
if [[ -z "$ENTRYPOINT_SPY" ]]; then
    pass "malformed Blueprint blocks prerequisite and target actions"
else
    fail "malformed Blueprint allowed actions: $ENTRYPOINT_SPY"
fi

TEST_BLUEPRINT_PRESENT=true TEST_BLUEPRINT_STATUS=0 TEST_INPUT_STATUS=2 \
    run_entrypoint --dry-run
assert_status 2 "malformed selected generated input returns 2"
if [[ -z "$ENTRYPOINT_SPY" ]]; then
    pass "malformed generated input blocks prerequisite and target actions"
else
    fail "malformed generated input allowed actions: $ENTRYPOINT_SPY"
fi

TEST_BLUEPRINT_PRESENT=true TEST_BLUEPRINT_STATUS=1 TEST_INPUT_STATUS=0 \
    run_entrypoint --dry-run
assert_status 1 "stale Blueprint remains a warning"
if [[ "$ENTRYPOINT_SPY" != *sudo* ]]; then
    pass "stale Blueprint continues through read-only startup"
else
    fail "stale Blueprint Preview reached sudo"
fi

TEST_BLUEPRINT_PRESENT=false TEST_BLUEPRINT_STATUS=0 TEST_INPUT_STATUS=0 \
    run_entrypoint --dry-run
assert_status 0 "Preview without Blueprint keeps all-inclusive compatibility"

TEST_BLUEPRINT_PRESENT=true TEST_BLUEPRINT_STATUS=0 TEST_INPUT_STATUS=0 \
TEST_GIT_ENABLED=false TEST_VSCODE_SETTINGS_ENABLED=false \
    run_entrypoint --dry-run
assert_status 0 "disabled configuration categories keep Preview successful"
if [[ "$ENTRYPOINT_SPY" != *git-config-preview* &&
      "$ENTRYPOINT_SPY" != *vscode-settings-preview* ]]; then
    pass "Blueprint-disabled Git and VS Code settings are not inspected"
else
    fail "Blueprint-disabled configuration category reached Preview"
fi

TEST_BLUEPRINT_PRESENT=false TEST_BLUEPRINT_STATUS=0 TEST_INPUT_STATUS=0 \
    run_entrypoint --bootstrap
assert_status 0 "normal Bootstrap still completes through its existing path"
if [[ "$ENTRYPOINT_SPY" == *sudo* &&
      "$ENTRYPOINT_SPY" == *launcher-setup* &&
      "$ENTRYPOINT_SPY" == *workspace-mutation* &&
      "$ENTRYPOINT_SPY" == *brew-install* &&
      "$ENTRYPOINT_SPY" == *mas-install* &&
      "$ENTRYPOINT_SPY" == *code-install* &&
      "$ENTRYPOINT_SPY" == *defaults-write* ]]; then
    pass "normal Bootstrap retains preflight and domain orchestration"
else
    fail "normal Bootstrap path changed: $ENTRYPOINT_SPY"
fi

for mode in --check --discover --blueprint --dry-run; do
    run_entrypoint "$mode" </dev/null
    [[ "$ENTRYPOINT_SPY" != *launcher-setup* ]] ||
        fail "$mode invoked launcher installation"
done

# Workflow integration uses the same entrypoint, logger and wrappers as above.
write_fixture_file modules/blueprint/selector.sh \
    'blueprint_selector_generated_ready() { return 0; }' \
    'blueprint_selector_run() {' \
    '    echo blueprint-selector >> "$TEST_SPY_FILE"' \
    '    BLUEPRINT_SELECTOR_SAVED=true' \
    '}'

run_entrypoint --workflow --check
assert_status 1 "workflow is an exclusive mode"
run_entrypoint --workflow <<< $'n\nn'
assert_status 0 "workflow reuses input and declines Apply"
[[ "$ENTRYPOINT_SPY" == blueprint-selector$'\n'git-config-preview* ||
   "$ENTRYPOINT_SPY" == blueprint-selector$'\n'formula-preview* ]] || fail "selector must precede Preview"
[[ "$ENTRYPOINT_SPY" != *sudo* && "$ENTRYPOINT_SPY" != *mutation* ]] || fail "decline reached mutations"

run_entrypoint --workflow --verbose <<< $'n\ny'
assert_status 0 "workflow confirms Bootstrap after Preview"
[[ "$ENTRYPOINT_SPY" == *macos-preview*sudo*launcher-setup*workspace-mutation* ]] || fail "Apply preceded Preview"
[[ "$ENTRYPOINT_OUTPUT" == *'Modules Inspected :'* && "$ENTRYPOINT_OUTPUT" == *'Output: Verbose'* ]] || fail "workflow lost Preview Summary or verbose"

TEST_INPUT_STATUS=2 run_entrypoint --workflow <<< n
assert_status 0 "unusable input decline is clean cancellation"
[[ -z "$ENTRYPOINT_SPY" ]] || fail "unusable input decline ran stages"
TEST_INPUT_STATUS=2 run_entrypoint --workflow <<< ''
assert_status 2 "Discovery default yes revalidates generated input"
[[ "$ENTRYPOINT_SPY" == *discovery* && "$ENTRYPOINT_SPY" != *blueprint-selector* ]] || fail "invalid post-Discovery state reached selector"

run_entrypoint --workflow <<< $'y\nn'
assert_status 0 "explicit refresh runs Discovery"
[[ "$ENTRYPOINT_SPY" == *discovery*blueprint-selector*formula-preview* ]] || fail "refresh order differs"

TEST_BLUEPRINT_PRESENT=true TEST_BLUEPRINT_STATUS=1 run_entrypoint --workflow <<< $'n\nn'
assert_status 1 "Preview warnings survive Apply decline"
TEST_BLUEPRINT_PRESENT=true TEST_BLUEPRINT_STATUS=1 run_entrypoint --workflow <<< $'n\ny'
assert_status 1 "Preview warnings survive successful Bootstrap"
TEST_BLUEPRINT_PRESENT=true TEST_PREVIEW_ERROR=true run_entrypoint --workflow <<< $'n\ny'
assert_status 2 "Preview error blocks Bootstrap"
[[ "$ENTRYPOINT_OUTPUT" != *'Apply these changes'* && "$ENTRYPOINT_SPY" != *sudo* ]] || fail "failed Preview offered Apply"

for warning_status in 0 1; do
    {
        TEST_HAS_PLANS=false TEST_BLUEPRINT_PRESENT=true TEST_BLUEPRINT_STATUS="$warning_status" \
            run_entrypoint --workflow
        IFS= read -r unread_confirmation
    } <<< $'n\ny'
    assert_status "$warning_status" "zero plans preserves Preview status $warning_status"
    [[ "$unread_confirmation" == y ]] || fail "zero plans read Bootstrap input"
    [[ "$ENTRYPOINT_OUTPUT" == *'No changes to apply'* &&
       "$ENTRYPOINT_OUTPUT" != *'Apply these changes'* && "$ENTRYPOINT_SPY" != *sudo* &&
       "$ENTRYPOINT_SPY" != *launcher-setup* &&
       "$ENTRYPOINT_SPY" != *mutation* ]] || fail "zero plans offered or executed Bootstrap"
done
TEST_HAS_PLANS=false TEST_BLUEPRINT_PRESENT=true TEST_PREVIEW_ERROR=true run_entrypoint --workflow <<< $'n\ny'
assert_status 2 "zero plans never masks Preview errors"
[[ "$ENTRYPOINT_OUTPUT" != *'No changes to apply'* && "$ENTRYPOINT_OUTPUT" != *'Apply these changes'* ]] || fail "Preview error treated as no changes"
run_entrypoint --workflow <<< $'n\n'
assert_status 0 "planned changes Enter declines Bootstrap"
[[ "$ENTRYPOINT_SPY" != *sudo* ]] || fail "Enter ran Bootstrap"
TEST_HAS_PLANS=false run_entrypoint --dry-run
assert_status 0 "standalone zero-plan Preview retains success"
[[ "$ENTRYPOINT_OUTPUT" != *'Workflow finished'* && "$ENTRYPOINT_OUTPUT" != *'Apply these changes'* ]] || fail "standalone Preview entered workflow"

write_fixture_file modules/discovery/discovery.sh \
    'run_discovery() { ((ERROR_COUNT++)); }'
run_entrypoint --workflow <<< y
assert_status 2 "Discovery errors stop workflow"
[[ "$ENTRYPOINT_SPY" != *blueprint-selector* ]] || fail "Discovery error reached selector"
write_fixture_file modules/discovery/discovery.sh \
    'run_discovery() { ((WARNING_COUNT++)); }'
run_entrypoint --workflow <<< $'y\nn'
assert_status 1 "Discovery warning continues with usable input and is preserved"
[[ "$ENTRYPOINT_SPY" == *blueprint-selector*formula-preview* ]] || fail "Discovery warning blocked valid inventory"

for selector_status in 0 1 2; do
    write_fixture_file modules/blueprint/selector.sh \
        'blueprint_selector_generated_ready() { return 0; }' \
        "blueprint_selector_run() { BLUEPRINT_SELECTOR_SAVED=false; return $selector_status; }"
    run_entrypoint --workflow <<< $'n\ny'
    expected=0
    [[ $selector_status -ne 2 ]] || expected=2
    assert_status "$expected" "selector unsaved status $selector_status stops workflow"
    [[ -z "$ENTRYPOINT_SPY" ]] || fail "unsaved selector reached Preview/Apply"
done

if [[ $TEST_FAILURES -eq 0 ]]; then
    echo "All dry-run CLI and startup tests passed"
    exit 0
fi

echo "$TEST_FAILURES dry-run CLI/startup test(s) failed" >&2
exit 1
