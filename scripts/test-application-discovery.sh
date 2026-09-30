#!/bin/bash

# ==========================================
# Application Discovery Publication Harness
# ==========================================

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

TEST_FAILURES=0
VERBOSE=false
MAS_AVAILABLE=true
MAS_MODE=normal
CODE_AVAILABLE=true
CODE_MODE=normal
SUCCESS_MESSAGES=""
WARNING_MESSAGES=""
ERROR_MESSAGES=""
MAS_CALLS="$TEST_ROOT/mas-calls.log"
CODE_CALLS="$TEST_ROOT/code-calls.log"

source "$PROJECT_ROOT/modules/core/common/common.sh"
source "$PROJECT_ROOT/modules/discovery/discovery.sh"

log() { :; }
action() { :; }
detail() { :; }
success() {
    SUCCESS_MESSAGES="${SUCCESS_MESSAGES}${SUCCESS_MESSAGES:+
}$1"
}
warning() {
    WARNING_MESSAGES="${WARNING_MESSAGES}${WARNING_MESSAGES:+
}$1"
}
error() {
    ERROR_MESSAGES="${ERROR_MESSAGES}${ERROR_MESSAGES:+
}$1"
}

command() {
    if [[ "${1:-}" == "-v" ]]; then
        case "${2:-}" in
            mas) [[ "$MAS_AVAILABLE" == true ]] ;;
            code) [[ "$CODE_AVAILABLE" == true ]] ;;
            *) builtin command "$@" ;;
        esac
        return $?
    fi

    builtin command "$@"
}

mas() {
    printf '%s|%s\n' "${MAS_NO_AUTO_INDEX:-}" "$*" >> "$MAS_CALLS"
    [[ "$*" == "list" ]] || return 2

    case "$MAS_MODE" in
        normal)
            printf '%s\n' \
                '222 Second Application (2.0)' \
                '111 First Application (Preview) (1.5)'
            ;;
        empty)
            :
            ;;
        failure)
            return 1
            ;;
    esac
}

code() {
    printf '%s\n' "$*" >> "$CODE_CALLS"
    [[ "$*" == "--list-extensions" ]] || return 2

    case "$CODE_MODE" in
        normal)
            printf '%s\n' publisher.z-extension publisher.a-extension
            ;;
        empty)
            :
            ;;
        failure)
            return 1
            ;;
    esac
}

source "$PROJECT_ROOT/modules/discovery/appstore.sh"
source "$PROJECT_ROOT/modules/discovery/vscode.sh"

HOME="$TEST_ROOT/home"

pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1"
    ((TEST_FAILURES++))
}

reset_fixture() {
    rm -rf "$TEST_ROOT/config" "$HOME"
    mkdir -p "$HOME"
    : > "$MAS_CALLS"
    : > "$CODE_CALLS"
    MAS_AVAILABLE=true
    MAS_MODE=normal
    CODE_AVAILABLE=true
    CODE_MODE=normal
    SUCCESS_MESSAGES=""
    WARNING_MESSAGES=""
    ERROR_MESSAGES=""
}

reset_counters() {
    MODULES_CHECKED=0
    INSTALLED_COUNT=0
    SKIPPED_COUNT=0
    WARNING_COUNT=0
    ERROR_COUNT=0
}

publication_temporary_files() {
    find config/generated -type f -name '*.tmp.*' -print 2>/dev/null
}

cd "$TEST_ROOT" || exit 1

# ==========================================
# App Store Discovery
# ==========================================

reset_fixture
discover_appstore >/dev/null
app_status=$?
expected_apps=$'222|Second Application\n111|First Application (Preview)'
if [[ $app_status -eq 0 &&
      -f config/generated/provenance/app-store.sha256 &&
      "$(cat config/generated/appstore.conf)" == "$expected_apps" &&
      "$(cat "$MAS_CALLS")" == '1|list' &&
      "$SUCCESS_MESSAGES" == *'2 App Store application(s) exported'* ]] &&
   provenance_complete app-store; then
    pass "App Store publishes the existing ordered ID/name format"
else
    fail "App Store populated format, ordering, command, or count changed"
fi

reset_fixture
MAS_MODE=empty
discover_appstore >/dev/null
app_empty_status=$?
if [[ $app_empty_status -eq 0 &&
      -f config/generated/appstore.conf &&
      ! -s config/generated/appstore.conf &&
      "$SUCCESS_MESSAGES" == *'0 App Store application(s) exported'* ]] &&
   provenance_complete app-store; then
    pass "empty App Store observation publishes a valid empty file"
else
    fail "empty App Store observation semantics changed"
fi

reset_fixture
MAS_AVAILABLE=false
mkdir -p config/generated
printf 'existing-app\n' > config/generated/appstore.conf
before_checksum="$(cksum config/generated/appstore.conf)"
discover_appstore >/dev/null
app_unavailable_status=$?
after_checksum="$(cksum config/generated/appstore.conf)"
if [[ $app_unavailable_status -eq 1 && "$before_checksum" == "$after_checksum" &&
      "$WARNING_MESSAGES" == *'mas is not installed'* &&
      -z "$SUCCESS_MESSAGES" && -z "$(publication_temporary_files)" ]]; then
    pass "missing mas remains warning 1 and preserves App Store state"
else
    fail "missing mas changed status, output, or generated state"
fi

reset_fixture
MAS_MODE=failure
mkdir -p config/generated
printf 'existing-app\n' > config/generated/appstore.conf
before_checksum="$(cksum config/generated/appstore.conf)"
discover_appstore >/dev/null
app_failure_status=$?
after_checksum="$(cksum config/generated/appstore.conf)"
if [[ $app_failure_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to inventory App Store applications'* &&
      "$SUCCESS_MESSAGES" != *'exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "mas list failure returns 2 and preserves App Store state"
else
    fail "mas list failure was destructive or reported false success"
fi

reset_fixture
mkdir -p config/generated
printf 'existing-app\n' > config/generated/appstore.conf
before_checksum="$(cksum config/generated/appstore.conf)"
awk() { return 1; }
discover_appstore >/dev/null
app_serialization_status=$?
unset -f awk
after_checksum="$(cksum config/generated/appstore.conf)"
if [[ $app_serialization_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to publish App Store applications'* &&
      "$SUCCESS_MESSAGES" != *'exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "App Store serialization failure preserves state and cleans temporary files"
else
    fail "App Store serialization failure changed state or leaked temporary output"
fi

reset_fixture
mkdir -p config/generated
printf 'existing-app\n' > config/generated/appstore.conf
before_checksum="$(cksum config/generated/appstore.conf)"
mv() { return 1; }
discover_appstore >/dev/null
app_publication_status=$?
unset -f mv
after_checksum="$(cksum config/generated/appstore.conf)"
if [[ $app_publication_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to publish App Store applications'* &&
      "$SUCCESS_MESSAGES" != *'exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "App Store publication failure preserves state and cleans temporary files"
else
    fail "App Store publication failure changed state or leaked temporary output"
fi

for lifecycle_case in success warning error; do
    reset_fixture
    reset_counters
    case "$lifecycle_case" in
        success) expected_status=0; expected_warnings=0; expected_errors=0 ;;
        warning) MAS_AVAILABLE=false; expected_status=1; expected_warnings=1; expected_errors=0 ;;
        error) MAS_MODE=failure; expected_status=2; expected_warnings=0; expected_errors=1 ;;
    esac
    run_module "App Store Discovery" discover_appstore >/dev/null
    lifecycle_status=$?
    if [[ $lifecycle_status -eq $expected_status &&
          $MODULES_CHECKED -eq 1 &&
          $WARNING_COUNT -eq $expected_warnings &&
          $ERROR_COUNT -eq $expected_errors ]]; then
        pass "App Store run_module propagates $expected_status"
    else
        fail "App Store run_module failed to propagate $expected_status"
    fi
done

# ==========================================
# VS Code Extensions Discovery
# ==========================================

reset_fixture
export_vscode_extensions >/dev/null
extension_status=$?
expected_extensions=$'publisher.a-extension\npublisher.z-extension'
if [[ $extension_status -eq 0 &&
      "$(cat config/generated/vscode-extensions.conf)" == "$expected_extensions" &&
      "$(cat "$CODE_CALLS")" == '--list-extensions' &&
      "$SUCCESS_MESSAGES" == *'2 Extensions exported'* ]]; then
    pass "VS Code Extensions publishes the existing sorted line format"
else
    fail "VS Code Extensions format, sorting, command, or count changed"
fi

reset_fixture
CODE_MODE=empty
export_vscode_extensions >/dev/null
extension_empty_status=$?
if [[ $extension_empty_status -eq 0 &&
      -f config/generated/vscode-extensions.conf &&
      ! -s config/generated/vscode-extensions.conf &&
      "$SUCCESS_MESSAGES" == *'0 Extensions exported'* ]]; then
    pass "empty VS Code extension observation publishes a valid empty file"
else
    fail "empty VS Code extension observation semantics changed"
fi

reset_fixture
CODE_AVAILABLE=false
mkdir -p config/generated
printf 'existing.extension\n' > config/generated/vscode-extensions.conf
before_checksum="$(cksum config/generated/vscode-extensions.conf)"
export_vscode_extensions >/dev/null
extension_unavailable_status=$?
after_checksum="$(cksum config/generated/vscode-extensions.conf)"
if [[ $extension_unavailable_status -eq 1 && "$before_checksum" == "$after_checksum" &&
      "$WARNING_MESSAGES" == *'VS Code CLI not found'* &&
      -z "$SUCCESS_MESSAGES" && -z "$(publication_temporary_files)" ]]; then
    pass "missing code remains warning 1 and preserves extension state"
else
    fail "missing code changed status, output, or generated state"
fi

reset_fixture
CODE_MODE=failure
mkdir -p config/generated
printf 'existing.extension\n' > config/generated/vscode-extensions.conf
before_checksum="$(cksum config/generated/vscode-extensions.conf)"
export_vscode_extensions >/dev/null
extension_failure_status=$?
after_checksum="$(cksum config/generated/vscode-extensions.conf)"
if [[ $extension_failure_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to inventory VS Code Extensions'* &&
      "$SUCCESS_MESSAGES" != *'exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "extension enumeration failure returns 2 and preserves state"
else
    fail "extension enumeration failure was destructive or reported false success"
fi

reset_fixture
mkdir -p config/generated
printf 'existing.extension\n' > config/generated/vscode-extensions.conf
before_checksum="$(cksum config/generated/vscode-extensions.conf)"
sort() { return 1; }
export_vscode_extensions >/dev/null
extension_serialization_status=$?
unset -f sort
after_checksum="$(cksum config/generated/vscode-extensions.conf)"
if [[ $extension_serialization_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to publish VS Code Extensions'* &&
      "$SUCCESS_MESSAGES" != *'exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "VS Code sort failure preserves state and cleans temporary files"
else
    fail "VS Code sort failure changed state or leaked temporary output"
fi

reset_fixture
mkdir -p config/generated
printf 'existing.extension\n' > config/generated/vscode-extensions.conf
before_checksum="$(cksum config/generated/vscode-extensions.conf)"
mv() { return 1; }
export_vscode_extensions >/dev/null
extension_publication_status=$?
unset -f mv
after_checksum="$(cksum config/generated/vscode-extensions.conf)"
if [[ $extension_publication_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to publish VS Code Extensions'* &&
      "$SUCCESS_MESSAGES" != *'exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "VS Code publication failure preserves state and cleans temporary files"
else
    fail "VS Code publication failure changed state or leaked temporary output"
fi

# ==========================================
# VS Code Settings Discovery
# ==========================================

settings_source="$HOME/Library/Application Support/Code/User/settings.json"
settings_output="config/generated/vscode/settings.json"

reset_fixture
mkdir -p "$(dirname "$settings_source")"
printf '{"editor.fontFamily":"Quoted \\"Font\\"", "literal":"$HOME"}' > "$settings_source"
export_vscode_settings >/dev/null
settings_status=$?
if [[ $settings_status -eq 0 && -f "$settings_output" ]] &&
   cmp -s "$settings_source" "$settings_output" &&
   [[ "$SUCCESS_MESSAGES" == *'VS Code Settings exported'* ]]; then
    pass "VS Code Settings publishes a byte-for-byte opaque copy"
else
    fail "VS Code Settings populated copy or success behavior changed"
fi

reset_fixture
mkdir -p "$(dirname "$settings_source")"
: > "$settings_source"
export_vscode_settings >/dev/null
settings_status=$?
if [[ $settings_status -eq 0 && -f "$settings_output" && ! -s "$settings_output" &&
      "$SUCCESS_MESSAGES" == *'VS Code Settings exported'* ]]; then
    pass "empty VS Code Settings source publishes a valid zero-byte destination"
else
    fail "empty VS Code Settings source behavior changed"
fi

reset_fixture
mkdir -p "$(dirname "$settings_output")"
printf 'previous settings bytes\n' > "$settings_output"
before_checksum="$(cksum "$settings_output")"
export_vscode_settings >/dev/null
settings_status=$?
after_checksum="$(cksum "$settings_output")"
if [[ $settings_status -eq 1 && "$before_checksum" == "$after_checksum" &&
      "$WARNING_MESSAGES" == *'VS Code settings not found'* &&
      "$SUCCESS_MESSAGES" != *'VS Code Settings exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "missing VS Code Settings source warns and preserves generated state"
else
    fail "missing VS Code Settings source changed state or success semantics"
fi

reset_fixture
mkdir -p "$settings_source" "$(dirname "$settings_output")"
printf 'previous settings bytes\n' > "$settings_output"
before_checksum="$(cksum "$settings_output")"
export_vscode_settings >/dev/null
settings_status=$?
after_checksum="$(cksum "$settings_output")"
if [[ $settings_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to publish VS Code Settings'* &&
      "$SUCCESS_MESSAGES" != *'VS Code Settings exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "uncopyable existing VS Code Settings source returns 2 and preserves state"
else
    fail "uncopyable VS Code Settings source was destructive or falsely successful"
fi

reset_fixture
mkdir -p "$(dirname "$settings_source")" "$(dirname "$settings_output")"
printf 'new settings bytes\n' > "$settings_source"
printf 'previous settings bytes\n' > "$settings_output"
before_checksum="$(cksum "$settings_output")"
serialize_vscode_settings() { return 2; }
export_vscode_settings >/dev/null
settings_status=$?
unset -f serialize_vscode_settings
source "$PROJECT_ROOT/modules/discovery/vscode.sh"
after_checksum="$(cksum "$settings_output")"
if [[ $settings_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to publish VS Code Settings'* &&
      "$SUCCESS_MESSAGES" != *'VS Code Settings exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "VS Code Settings serializer failure preserves state and cleans temporary files"
else
    fail "VS Code Settings serializer failure changed state or leaked temporary output"
fi

reset_fixture
mkdir -p "$(dirname "$settings_source")" "$(dirname "$settings_output")"
printf 'new settings bytes\n' > "$settings_source"
printf 'previous settings bytes\n' > "$settings_output"
before_checksum="$(cksum "$settings_output")"
mv() { return 1; }
export_vscode_settings >/dev/null
settings_status=$?
unset -f mv
after_checksum="$(cksum "$settings_output")"
if [[ $settings_status -eq 2 && "$before_checksum" == "$after_checksum" &&
      "$ERROR_MESSAGES" == *'Failed to publish VS Code Settings'* &&
      "$SUCCESS_MESSAGES" != *'VS Code Settings exported'* &&
      -z "$(publication_temporary_files)" ]]; then
    pass "VS Code Settings publication failure preserves state and cleans temporary files"
else
    fail "VS Code Settings publication failure changed state or leaked temporary output"
fi

# ==========================================
# VS Code Controller and Lifecycle
# ==========================================

for controller_case in settings_success settings_warning settings_error extensions_warning extensions_error; do
    reset_fixture
    expected_status=0

    case "$controller_case" in
        settings_success)
            mkdir -p "$(dirname "$settings_source")"
            printf '{}\n' > "$settings_source"
            ;;
        settings_warning)
            expected_status=1
            ;;
        settings_error)
            mkdir -p "$settings_source"
            expected_status=2
            ;;
        extensions_warning)
            mkdir -p "$(dirname "$settings_source")"
            printf '{}\n' > "$settings_source"
            CODE_AVAILABLE=false
            expected_status=1
            ;;
        extensions_error)
            mkdir -p "$(dirname "$settings_source")"
            printf '{}\n' > "$settings_source"
            CODE_MODE=failure
            expected_status=2
            ;;
    esac

    discover_vscode >/dev/null
    vscode_controller_status=$?
    if [[ $vscode_controller_status -eq $expected_status ]]; then
        pass "VS Code controller aggregates $controller_case as $expected_status"
    else
        fail "VS Code controller failed to aggregate $controller_case"
    fi
done

for lifecycle_case in success warning error; do
    reset_fixture
    reset_counters
    mkdir -p "$(dirname "$settings_source")"
    printf '{}\n' > "$settings_source"
    case "$lifecycle_case" in
        success) expected_status=0; expected_warnings=0; expected_errors=0 ;;
        warning) CODE_AVAILABLE=false; expected_status=1; expected_warnings=1; expected_errors=0 ;;
        error) CODE_MODE=failure; expected_status=2; expected_warnings=0; expected_errors=1 ;;
    esac
    run_module "VS Code Discovery" discover_vscode >/dev/null
    lifecycle_status=$?
    if [[ $lifecycle_status -eq $expected_status &&
          $MODULES_CHECKED -eq 1 &&
          $WARNING_COUNT -eq $expected_warnings &&
          $ERROR_COUNT -eq $expected_errors ]]; then
        pass "VS Code run_module propagates $expected_status"
    else
        fail "VS Code run_module failed to propagate $expected_status"
    fi
done

if [[ $TEST_FAILURES -ne 0 ]]; then
    echo
    echo "$TEST_FAILURES Application Discovery test(s) failed"
    exit 1
fi

echo
echo "All Application Discovery tests passed"
