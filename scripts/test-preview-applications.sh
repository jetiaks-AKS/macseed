#!/bin/bash

# ==========================================
# Applications Preview Harness
# ==========================================

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
COMMAND_LOG="$TEST_ROOT/commands.log"
OBSERVATION_LOG="$TEST_ROOT/observations.log"
export HOME="$TEST_ROOT"
export BLUEPRINT_GENERATED_DIR="$TEST_ROOT/generated"
TEST_FAILURES=0
VERBOSE=false
MODULE_CHANGED=false
BLUEPRINT_PRESENT=false
SELECTED_ITEMS=""

trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

source "$PROJECT_ROOT/modules/core/common/common.sh"

action() { echo "[....] $*"; }
detail() { :; }
success() { :; }
warning() { echo "[WARN] $*"; }
error() { echo "[ERROR] $*"; }

blueprint_exists() { [[ "$BLUEPRINT_PRESENT" == true ]]; }
blueprint_selected_items() { printf '%s\n' "$SELECTED_ITEMS"; }
blueprint_item_selected() {
    [[ "$BLUEPRINT_PRESENT" != true ]] || grep -Fxq -- "$2" <<< "$SELECTED_ITEMS"
}
blueprint_generated_file() {
    case "$1" in
        homebrew-packages) echo "$TEST_ROOT/brew-packages.conf" ;;
        homebrew-casks) echo "$TEST_ROOT/brew-casks.conf" ;;
        app-store) echo "$TEST_ROOT/appstore.conf" ;;
        vscode-extensions) echo "$TEST_ROOT/vscode-extensions.conf" ;;
    esac
}

FORMULA_STATUS=0
CASK_LIST_STATUS=0
CASK_INFO_STATUS=0
MAS_STATUS=0
CODE_STATUS=0
CASK_METADATA=default

brew() {
    if [[ "$*" == 'list --formula --full-name' ]]; then
        echo formula-list >> "$OBSERVATION_LOG"
        cat "$TEST_ROOT/formula-installed"
        return "$FORMULA_STATUS"
    fi
    if [[ "$*" == 'list --cask' ]]; then
        echo cask-list >> "$OBSERVATION_LOG"
        cat "$TEST_ROOT/cask-installed"
        return "$CASK_LIST_STATUS"
    fi
    if [[ "$1" == --prefix ]]; then
        printf '%s\n' "$TEST_ROOT/brew"
        return 0
    fi
    if [[ "$1" == info ]]; then
        echo cask-info >> "$OBSERVATION_LOG"
        local metadata="$CASK_METADATA" installed=null
        grep -Fxq "$4" "$TEST_ROOT/cask-installed" && installed='"1.0"'
        if [[ "$metadata" == default ]]; then
            metadata="$(jq -n --arg target "$TEST_ROOT/Applications/$4.app" '{casks:[{artifacts:[{app:[($target | split("/") | last)],target:$target}]}]}')"
        fi
        jq --arg token "$4" --argjson installed "$installed" '.casks[0] += {token:$token,installed:$installed}' <<< "$metadata"
        return "$CASK_INFO_STATUS"
    fi
    printf 'brew %s\n' "$*" >> "$COMMAND_LOG"
    return 2
}

mas() {
    if [[ "$1" == list ]]; then
        echo mas-list >> "$OBSERVATION_LOG"
        cat "$TEST_ROOT/mas-installed"
        return "$MAS_STATUS"
    fi
    printf 'mas %s\n' "$*" >> "$COMMAND_LOG"
    return 2
}

code() {
    if [[ "$1" == --list-extensions ]]; then
        echo code-list >> "$OBSERVATION_LOG"
        cat "$TEST_ROOT/code-installed"
        return "$CODE_STATUS"
    fi
    printf 'code %s\n' "$*" >> "$COMMAND_LOG"
    return 2
}

source "$PROJECT_ROOT/modules/apps/brew-packages.sh"
source "$PROJECT_ROOT/modules/apps/brew-casks.sh"
source "$PROJECT_ROOT/modules/apps/appstore.sh"
source "$PROJECT_ROOT/modules/vscode/extensions.sh"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; ((TEST_FAILURES++)); }

reset_state() {
    : > "$COMMAND_LOG"
    : > "$OBSERVATION_LOG"
    : > "$TEST_ROOT/formula-installed"
    : > "$TEST_ROOT/cask-installed"
    : > "$TEST_ROOT/mas-installed"
    : > "$TEST_ROOT/code-installed"
    FORMULA_STATUS=0
    CASK_LIST_STATUS=0
    CASK_INFO_STATUS=0
    MAS_STATUS=0
    CODE_STATUS=0
    CASK_METADATA=default
    BLUEPRINT_PRESENT=false
    SELECTED_ITEMS=""
    MODULE_CHANGED=false
    mkdir -p "$TEST_ROOT/Applications/correct-cask.app/Contents/MacOS"
    printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.example.correct</string><key>CFBundleExecutable</key><string>correct</string></dict></plist>' > "$TEST_ROOT/Applications/correct-cask.app/Contents/Info.plist"
    printf '#!/bin/sh\n' > "$TEST_ROOT/Applications/correct-cask.app/Contents/MacOS/correct"
    chmod 700 "$TEST_ROOT/Applications/correct-cask.app/Contents/MacOS/correct"
}

run_case() {
    "$1" > "$TEST_ROOT/output" 2>&1
    STATUS=$?
    OUTPUT="$(cat "$TEST_ROOT/output")"
}

expect_status() {
    local expected="$1"
    local label="$2"
    if [[ $STATUS -eq $expected ]]; then
        pass "$label"
    else
        fail "$label (expected $expected, got $STATUS)"
    fi
}

expect_message() {
    local expected="$1"
    local label="$2"
    if [[ "$OUTPUT" == *"$expected"* ]]; then
        pass "$label"
    else
        fail "$label (output='$OUTPUT')"
    fi
}

expect_no_mutation() {
    local label="$1"
    if [[ ! -s "$COMMAND_LOG" && "$MODULE_CHANGED" == false ]]; then
        pass "$label"
    else
        fail "$label"
    fi
}

# Formulae: installed, mixed planned state, observation error, selection, repeat.
reset_state
printf 'alpha\nbeta\n' > "$TEST_ROOT/brew-packages.conf"
printf 'alpha\n' > "$TEST_ROOT/formula-installed"
run_case preview_brew_packages
expect_status 0 "formula Preview succeeds for mixed state"
expect_message "Would install Homebrew formula: beta" "formula Preview plans the absent item"
[[ "$OUTPUT" != *'formula: alpha'* ]] || fail "installed formula was planned"
FIRST_OUTPUT="$OUTPUT"
run_case preview_brew_packages
[[ "$OUTPUT" == "$FIRST_OUTPUT" ]] && pass "formula Preview output is idempotent" || fail "formula Preview output changed"
expect_no_mutation "formula Preview performs no mutation"

reset_state
printf 'alpha\n' > "$TEST_ROOT/brew-packages.conf"
FORMULA_STATUS=2
run_case preview_brew_packages
expect_status 2 "formula observation error returns 2"
expect_no_mutation "formula observation error performs no mutation"

reset_state
printf 'alpha\nbeta\n' > "$TEST_ROOT/brew-packages.conf"
BLUEPRINT_PRESENT=true
SELECTED_ITEMS=beta
run_case preview_brew_packages
[[ "$OUTPUT" == *'formula: beta'* && "$OUTPUT" != *'formula: alpha'* &&
   "$(cat "$OBSERVATION_LOG")" == formula-list ]] &&
    pass "formula Preview inspects only the Blueprint subset" ||
    fail "formula Preview selection changed"

# Casks: correct, absent, reinstall-required, error, selection, mixed/repeat.
reset_state
printf 'correct-cask\nabsent-cask\n' > "$TEST_ROOT/brew-casks.conf"
printf 'correct-cask\n' > "$TEST_ROOT/cask-installed"
run_case preview_brew_casks
expect_status 0 "cask Preview succeeds for mixed state"
expect_message "Would install Homebrew cask: absent-cask" "cask Preview plans install"
[[ "$OUTPUT" != *'cask: correct-cask'* ]] || fail "correct cask was planned"
FIRST_OUTPUT="$OUTPUT"
run_case preview_brew_casks
[[ "$OUTPUT" == "$FIRST_OUTPUT" ]] && pass "cask Preview output is idempotent" || fail "cask Preview output changed"
expect_no_mutation "cask Preview performs no mutation"

reset_state
printf 'broken-cask\n' > "$TEST_ROOT/brew-casks.conf"
printf 'broken-cask\n' > "$TEST_ROOT/cask-installed"
CASK_METADATA="$(jq -n --arg target "$TEST_ROOT/Applications/Missing.app" '{casks:[{artifacts:[{app:["Missing.app"],target:$target}]}]}')"
run_case preview_brew_casks
expect_status 0 "cask reinstall Preview succeeds"
expect_message "Would repair Homebrew cask: broken-cask" "cask Preview distinguishes reinstall"
expect_no_mutation "cask reinstall Preview performs no mutation"

reset_state
printf 'broken-cask\n' > "$TEST_ROOT/brew-casks.conf"
CASK_LIST_STATUS=2
run_case preview_brew_casks
expect_status 2 "cask observation error returns 2"
expect_no_mutation "cask observation error performs no mutation"

reset_state
printf 'first-cask\nsecond-cask\n' > "$TEST_ROOT/brew-casks.conf"
BLUEPRINT_PRESENT=true
SELECTED_ITEMS=second-cask
run_case preview_brew_casks
[[ "$OUTPUT" == *'cask: second-cask'* && "$OUTPUT" != *'cask: first-cask'* &&
   "$(cat "$OBSERVATION_LOG")" == $'cask-info\ncask-list' ]] &&
    pass "cask Preview inspects only the Blueprint subset" ||
    fail "cask Preview selection changed"

# App Store: installed, mixed planned state, error, selection, repeat.
reset_state
printf '111|Installed App\n222|Missing App\n' > "$TEST_ROOT/appstore.conf"
printf '111 Installed App (1.0)\n' > "$TEST_ROOT/mas-installed"
run_case preview_appstore_apps
expect_status 0 "App Store Preview succeeds for mixed state"
expect_message "Would install App Store app: Missing App (222)" "App Store Preview plans the absent ID"
[[ "$OUTPUT" != *'Installed App (111)'* ]] || fail "installed App Store ID was planned"
FIRST_OUTPUT="$OUTPUT"
run_case preview_appstore_apps
[[ "$OUTPUT" == "$FIRST_OUTPUT" ]] && pass "App Store Preview output is idempotent" || fail "App Store Preview output changed"
expect_no_mutation "App Store Preview performs no mutation"

reset_state
printf '111|App\n' > "$TEST_ROOT/appstore.conf"
MAS_STATUS=2
run_case preview_appstore_apps
expect_status 2 "App Store observation error returns 2"
expect_no_mutation "App Store observation error performs no mutation"

reset_state
printf '111|First App\n222|Second App\n' > "$TEST_ROOT/appstore.conf"
BLUEPRINT_PRESENT=true
SELECTED_ITEMS=222
run_case preview_appstore_apps
[[ "$OUTPUT" == *'Second App (222)'* && "$OUTPUT" != *'First App (111)'* &&
   "$(cat "$OBSERVATION_LOG")" == mas-list ]] &&
    pass "App Store Preview inspects only the Blueprint subset" ||
    fail "App Store Preview selection changed"

# Extensions: installed, mixed planned state, error, selection, repeat.
reset_state
printf 'installed.extension\nmissing.extension\n' > "$TEST_ROOT/vscode-extensions.conf"
printf 'installed.extension\n' > "$TEST_ROOT/code-installed"
run_case preview_vscode_extensions
expect_status 0 "VS Code Preview succeeds for mixed state"
expect_message "Would install VS Code extension: missing.extension" "VS Code Preview plans the absent ID"
[[ "$OUTPUT" != *'extension: installed.extension'* ]] || fail "installed extension was planned"
FIRST_OUTPUT="$OUTPUT"
run_case preview_vscode_extensions
[[ "$OUTPUT" == "$FIRST_OUTPUT" ]] && pass "VS Code Preview output is idempotent" || fail "VS Code Preview output changed"
expect_no_mutation "VS Code Preview performs no mutation"

reset_state
printf 'publisher.extension\n' > "$TEST_ROOT/vscode-extensions.conf"
CODE_STATUS=2
run_case preview_vscode_extensions
expect_status 2 "VS Code observation error returns 2"
expect_no_mutation "VS Code observation error performs no mutation"

reset_state
printf 'first.extension\nsecond.extension\n' > "$TEST_ROOT/vscode-extensions.conf"
BLUEPRINT_PRESENT=true
SELECTED_ITEMS=second.extension
run_case preview_vscode_extensions
[[ "$OUTPUT" == *'extension: second.extension'* && "$OUTPUT" != *'extension: first.extension'* &&
   "$(cat "$OBSERVATION_LOG")" == code-list ]] &&
    pass "VS Code Preview inspects only the Blueprint subset" ||
    fail "VS Code Preview selection changed"

reset_state
BLUEPRINT_PRESENT=true
SELECTED_ITEMS=""
for preview_function in preview_brew_packages preview_brew_casks \
    preview_appstore_apps preview_vscode_extensions; do
    run_case "$preview_function"
    if [[ $STATUS -eq 0 && -z "$OUTPUT" && ! -s "$OBSERVATION_LOG" ]]; then
        pass "$preview_function skips an empty Blueprint scope"
    else
        fail "$preview_function inspected an empty Blueprint scope"
    fi
done

expect_no_mutation "all application Preview paths avoid install commands and MODULE_CHANGED"

if [[ $TEST_FAILURES -eq 0 ]]; then
    echo "All Applications Preview tests passed"
    exit 0
fi

echo "$TEST_FAILURES Applications Preview test(s) failed" >&2
exit 1
