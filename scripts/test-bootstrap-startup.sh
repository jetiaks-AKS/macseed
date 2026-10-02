#!/bin/bash

# ==========================================
# Bootstrap Startup Validation Harness
# ==========================================

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_FAILURES=0
BLUEPRINT_PRESENT=false
BLUEPRINT_STATUS=0
INPUT_STATUS=0
STARTUP_STEPS=""
BLUEPRINT_BOOTSTRAP_SUMMARY=false
ERROR_COUNT=0
MODE="--bootstrap"

blueprint_exists() {
    [[ "$BLUEPRINT_PRESENT" == true ]]
}

blueprint_validate() {
    return "$BLUEPRINT_STATUS"
}

bootstrap_validate_selected_inputs() {
    STARTUP_STEPS="${STARTUP_STEPS}${STARTUP_STEPS:+ }Bootstrap Input Validation"
    return "$INPUT_STATUS"
}

run_module() {
    STARTUP_STEPS="${STARTUP_STEPS}${STARTUP_STEPS:+ }$1"
    "$2"
}

run_inspection() {
    run_module "$@"
}

startup_function="$(awk '
    /^bootstrap_run_startup_validation\(\)/ { capture = 1 }
    capture { print }
    capture && /^}/ { exit }
' "$PROJECT_ROOT/bootstrap.sh")"

[[ -n "$startup_function" ]] || exit 2
eval "$startup_function"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; ((TEST_FAILURES++)); }

reset_case() {
    BLUEPRINT_PRESENT=false
    BLUEPRINT_STATUS=0
    INPUT_STATUS=0
    STARTUP_STEPS=""
    BLUEPRINT_BOOTSTRAP_SUMMARY=false
    # The fixture variable is read by sourced production code.
    # shellcheck disable=SC2034
    ERROR_COUNT=0
    # The fixture variable is read by sourced production code.
    # shellcheck disable=SC2034
    MODE="--bootstrap"
}

expect_case() {
    local label="$1"
    local expected_status="$2"
    local expected_steps="$3"
    local status

    bootstrap_run_startup_validation >/dev/null
    status=$?

    if [[ $status -eq $expected_status && "$STARTUP_STEPS" == "$expected_steps" ]]; then
        pass "$label"
    else
        fail "$label (status=$status, steps='$STARTUP_STEPS')"
    fi
}

reset_case
BLUEPRINT_PRESENT=true
BLUEPRINT_STATUS=2
expect_case "malformed Blueprint blocks generated validation and later startup" 2 \
    "Blueprint Validation"

reset_case
BLUEPRINT_PRESENT=true
BLUEPRINT_STATUS=1
expect_case "stale Blueprint remains a warning gate and continues" 0 \
    "Blueprint Validation Bootstrap Input Validation"

if [[ "$BLUEPRINT_BOOTSTRAP_SUMMARY" == true ]]; then
    pass "stale Blueprint keeps Blueprint Summary enabled"
else
    fail "stale Blueprint disabled Blueprint Summary"
fi

reset_case
BLUEPRINT_PRESENT=true
INPUT_STATUS=2
expect_case "malformed selected generated input blocks later startup" 2 \
    "Blueprint Validation Bootstrap Input Validation"

reset_case
expect_case "missing Blueprint keeps all-inclusive validation path" 0 \
    "Bootstrap Input Validation"

preflight_line="$(rg -n '^[[:space:]]*run_preflight_checks$' "$PROJECT_ROOT/bootstrap.sh" | cut -d: -f1)"
validation_line="$(rg -n '^[[:space:]]*if ! bootstrap_run_startup_validation; then$' "$PROJECT_ROOT/bootstrap.sh" | cut -d: -f1)"

if [[ -n "$preflight_line" && -n "$validation_line" && $validation_line -lt $preflight_line ]]; then
    pass "startup validation runs before preflight and Core modules"
else
    fail "startup validation order changed (validation=$validation_line, preflight=$preflight_line)"
fi

if [[ $TEST_FAILURES -eq 0 ]]; then
    echo "All Bootstrap startup validation tests passed"
    exit 0
fi

echo "$TEST_FAILURES Bootstrap startup validation test(s) failed" >&2
exit 1
