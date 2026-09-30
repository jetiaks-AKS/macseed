#!/bin/bash

# ==========================================
# Homebrew Discovery Harness
# ==========================================

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

TEST_FAILURES=0
FORMULA_MODE=normal
CASK_MODE=normal
BREW_CALLS="$TEST_ROOT/brew-calls.log"
SUCCESS_MESSAGES=""
ERROR_MESSAGES=""

source "$PROJECT_ROOT/modules/core/common/common.sh"
source "$PROJECT_ROOT/modules/core/homebrew/homebrew.sh"
source "$PROJECT_ROOT/modules/discovery/discovery.sh"

log() { :; }
action() { :; }
detail() { :; }
error() {
    ERROR_MESSAGES="${ERROR_MESSAGES}${ERROR_MESSAGES:+
}$1"
}
success() {
    SUCCESS_MESSAGES="${SUCCESS_MESSAGES}${SUCCESS_MESSAGES:+
}$1"
}

brew() {
    printf '%s\n' "$*" >> "$BREW_CALLS"

    case "$*" in
        "list --formula --installed-on-request")
            case "$FORMULA_MODE" in
                normal) printf '%s\n' git wget ;;
                empty) : ;;
                failure) return 1 ;;
            esac
            ;;
        "list --formula")
            printf '%s\n' dependency-only git wget
            ;;
        "list --cask")
            case "$CASK_MODE" in
                normal) printf '%s\n' firefox visual-studio-code ;;
                empty) : ;;
                failure) return 1 ;;
            esac
            ;;
        *)
            return 2
            ;;
    esac
}

source "$PROJECT_ROOT/modules/discovery/homebrew.sh"

pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1"
    ((TEST_FAILURES++))
}

reset_fixture() {
    rm -rf "$TEST_ROOT/config"
    : > "$BREW_CALLS"
    SUCCESS_MESSAGES=""
    ERROR_MESSAGES=""
}

restore_serializer() {
    source "$PROJECT_ROOT/modules/discovery/homebrew.sh"
}

helper_temporary_files() {
    find config/generated -type f -name '*.conf.tmp.*' -print 2>/dev/null
}

cd "$TEST_ROOT" || exit 1

reset_fixture
homebrew_availability() { return 1; }
discover_homebrew >/dev/null
absence_status=$?
if [[ $absence_status -eq 2 && "$ERROR_MESSAGES" == *'Homebrew is not installed'* &&
      ! -e config/generated/brew-packages.conf && ! -e config/generated/brew-casks.conf &&
      ! -s "$BREW_CALLS" ]]; then
    pass "confirmed Homebrew absence has no fabricated inventory"
else
    fail "confirmed absence was not preserved as a Discovery prerequisite error"
fi

reset_fixture
homebrew_availability() { return 2; }
discover_homebrew >/dev/null
observation_status=$?
if [[ $observation_status -eq 2 && "$ERROR_MESSAGES" == *'Failed to inspect Homebrew availability'* &&
      "$ERROR_MESSAGES" != *'Homebrew is not installed'* && ! -s "$BREW_CALLS" ]]; then
    pass "Homebrew observation failure remains distinct from absence"
else
    fail "Homebrew observation failure was mistaken for absence"
fi
source "$PROJECT_ROOT/modules/core/homebrew/homebrew.sh"

reset_fixture
FORMULA_MODE=normal
export_brew_packages >/dev/null
formula_status=$?
if [[ $formula_status -eq 0 ]] &&
   grep -Fxq 'list --formula --installed-on-request' "$BREW_CALLS" &&
   ! grep -Fxq 'list --formula' "$BREW_CALLS" &&
   [[ "$(cat config/generated/brew-packages.conf)" == $'git\nwget' ]] &&
   ! grep -q 'dependency-only' config/generated/brew-packages.conf &&
   [[ "$SUCCESS_MESSAGES" == *'2 Formulae exported'* ]]; then
    pass "formula Discovery exports requested formulae in the existing format"
else
    fail "formula Discovery command, filtering, format, or status is incorrect"
fi

reset_fixture
FORMULA_MODE=empty
export_brew_packages >/dev/null
empty_status=$?
if [[ $empty_status -eq 0 &&
      -f config/generated/brew-packages.conf &&
      ! -s config/generated/brew-packages.conf &&
      "$SUCCESS_MESSAGES" == *'0 Formulae exported'* ]]; then
    pass "empty requested formula inventory remains a valid empty export"
else
    fail "empty formula inventory behavior changed"
fi

reset_fixture
FORMULA_MODE=failure
mkdir -p config/generated
printf 'existing-formula\n' > config/generated/brew-packages.conf
before_checksum="$(cksum config/generated/brew-packages.conf)"
export_brew_packages >/dev/null
failure_status=$?
after_checksum="$(cksum config/generated/brew-packages.conf)"
if [[ $failure_status -eq 2 && "$before_checksum" == "$after_checksum" ]] &&
   [[ "$ERROR_MESSAGES" == *'Failed to inventory Homebrew Formulae'* ]] &&
   [[ "$SUCCESS_MESSAGES" != *'Formulae exported'* ]] &&
   [[ -z "$(helper_temporary_files)" ]]; then
    pass "formula failure returns 2 without replacing or falsely exporting"
else
    fail "formula failure did not preserve output or propagate status 2"
fi


reset_fixture
FORMULA_MODE=normal
mkdir -p config/generated
printf 'existing-formula\n' > config/generated/brew-packages.conf
before_checksum="$(cksum config/generated/brew-packages.conf)"
serialize_brew_inventory() {
    printf 'partial-formula\n' > "$1"
    return 2
}
export_brew_packages >/dev/null
formula_serialization_status=$?
after_checksum="$(cksum config/generated/brew-packages.conf)"
restore_serializer
if [[ $formula_serialization_status -eq 2 && "$before_checksum" == "$after_checksum" ]] &&
   [[ "$ERROR_MESSAGES" == *'Failed to publish Homebrew Formulae'* ]] &&
   [[ "$SUCCESS_MESSAGES" != *'Formulae exported'* ]] &&
   [[ -z "$(helper_temporary_files)" ]]; then
    pass "formula serialization failure preserves output and cleans temporary files"
else
    fail "formula serialization failure changed output, leaked a temporary file, or reported success"
fi


reset_fixture
FORMULA_MODE=normal
mkdir -p config/generated
printf 'existing-formula\n' > config/generated/brew-packages.conf
before_checksum="$(cksum config/generated/brew-packages.conf)"
mv() { return 1; }
export_brew_packages >/dev/null
formula_publication_status=$?
unset -f mv
after_checksum="$(cksum config/generated/brew-packages.conf)"
if [[ $formula_publication_status -eq 2 && "$before_checksum" == "$after_checksum" ]] &&
   [[ "$ERROR_MESSAGES" == *'Failed to publish Homebrew Formulae'* ]] &&
   [[ "$SUCCESS_MESSAGES" != *'Formulae exported'* ]] &&
   [[ -z "$(helper_temporary_files)" ]]; then
    pass "formula publication failure preserves output and cleans temporary files"
else
    fail "formula publication failure changed output, leaked a temporary file, or reported success"
fi

reset_fixture
FORMULA_MODE=failure
CASK_MODE=normal
mkdir -p config/generated
printf 'existing-formula\n' > config/generated/brew-packages.conf
discover_homebrew >/dev/null
formula_controller_status=$?
if [[ $formula_controller_status -eq 2 ]] &&
   ! grep -Fxq 'list --cask' "$BREW_CALLS" &&
   [[ "$SUCCESS_MESSAGES" != *'Homebrew Discovery completed'* ]]; then
    pass "formula failure stops Homebrew Discovery with status 2"
else
    fail "formula failure was not propagated through Homebrew Discovery"
fi

reset_fixture
FORMULA_MODE=failure
CASK_MODE=normal
MODULES_CHECKED=0
INSTALLED_COUNT=0
SKIPPED_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0
run_module "Homebrew Discovery" discover_homebrew >/dev/null
formula_lifecycle_status=$?
if [[ $formula_lifecycle_status -eq 2 &&
      $MODULES_CHECKED -eq 1 &&
      $ERROR_COUNT -eq 1 &&
      $WARNING_COUNT -eq 0 ]]; then
    pass "formula failure reaches the existing module error lifecycle"
else
    fail "formula failure did not reach the module error lifecycle"
fi

reset_fixture
FORMULA_MODE=normal
CASK_MODE=normal
export_brew_casks >/dev/null
cask_status=$?
if [[ $cask_status -eq 0 ]] &&
   provenance_complete homebrew-casks &&
   grep -Fxq 'list --cask' "$BREW_CALLS" &&
   [[ "$(cat config/generated/brew-casks.conf)" == $'firefox\nvisual-studio-code' ]] &&
   [[ "$SUCCESS_MESSAGES" == *'2 Casks exported'* ]]; then
    pass "cask Discovery command and generated format remain unchanged"
else
    fail "cask Discovery behavior changed"
fi

# A failed later enumeration leaves the previous complete snapshot intact.
before_marker="$(cat config/generated/provenance/homebrew-casks.sha256)"
CASK_MODE=failure
export_brew_casks >/dev/null
if [[ $? -eq 2 && "$(cat config/generated/provenance/homebrew-casks.sha256)" == "$before_marker" ]] &&
   provenance_complete homebrew-casks; then
    pass "failed cask enumeration cannot publish false completeness"
else
    fail "failed cask enumeration changed completeness"
fi

reset_fixture
CASK_MODE=empty
export_brew_casks >/dev/null
empty_cask_status=$?
if [[ $empty_cask_status -eq 0 &&
      -f config/generated/brew-casks.conf &&
      ! -s config/generated/brew-casks.conf &&
      "$SUCCESS_MESSAGES" == *'0 Casks exported'* ]]; then
    pass "empty cask inventory remains a valid empty export"
else
    fail "empty cask inventory behavior changed"
fi

reset_fixture
CASK_MODE=failure
mkdir -p config/generated
printf 'existing-cask\n' > config/generated/brew-casks.conf
before_checksum="$(cksum config/generated/brew-casks.conf)"
export_brew_casks >/dev/null
cask_failure_status=$?
after_checksum="$(cksum config/generated/brew-casks.conf)"
if [[ $cask_failure_status -eq 2 && "$before_checksum" == "$after_checksum" ]] &&
   [[ "$ERROR_MESSAGES" == *'Failed to inventory Homebrew Casks'* ]] &&
   [[ "$SUCCESS_MESSAGES" != *'Casks exported'* ]] &&
   [[ -z "$(helper_temporary_files)" ]]; then
    pass "cask failure returns 2 without replacing or falsely exporting"
else
    fail "cask failure did not preserve output or propagate status 2"
fi


reset_fixture
CASK_MODE=normal
mkdir -p config/generated
printf 'existing-cask\n' > config/generated/brew-casks.conf
before_checksum="$(cksum config/generated/brew-casks.conf)"
serialize_brew_inventory() {
    printf 'partial-cask\n' > "$1"
    return 2
}
export_brew_casks >/dev/null
cask_serialization_status=$?
after_checksum="$(cksum config/generated/brew-casks.conf)"
restore_serializer
if [[ $cask_serialization_status -eq 2 && "$before_checksum" == "$after_checksum" ]] &&
   [[ "$ERROR_MESSAGES" == *'Failed to publish Homebrew Casks'* ]] &&
   [[ "$SUCCESS_MESSAGES" != *'Casks exported'* ]] &&
   [[ -z "$(helper_temporary_files)" ]]; then
    pass "cask serialization failure preserves output and cleans temporary files"
else
    fail "cask serialization failure changed output, leaked a temporary file, or reported success"
fi


reset_fixture
CASK_MODE=normal
mkdir -p config/generated
printf 'existing-cask\n' > config/generated/brew-casks.conf
before_checksum="$(cksum config/generated/brew-casks.conf)"
mv() { return 1; }
export_brew_casks >/dev/null
cask_publication_status=$?
unset -f mv
after_checksum="$(cksum config/generated/brew-casks.conf)"
if [[ $cask_publication_status -eq 2 && "$before_checksum" == "$after_checksum" ]] &&
   [[ "$ERROR_MESSAGES" == *'Failed to publish Homebrew Casks'* ]] &&
   [[ "$SUCCESS_MESSAGES" != *'Casks exported'* ]] &&
   [[ -z "$(helper_temporary_files)" ]]; then
    pass "cask publication failure preserves output and cleans temporary files"
else
    fail "cask publication failure changed output, leaked a temporary file, or reported success"
fi

reset_fixture
FORMULA_MODE=normal
CASK_MODE=failure
mkdir -p config/generated
printf 'existing-cask\n' > config/generated/brew-casks.conf
discover_homebrew >/dev/null
cask_controller_status=$?
if [[ $cask_controller_status -eq 2 ]] &&
   [[ "$SUCCESS_MESSAGES" != *'Homebrew Discovery completed'* ]]; then
    pass "cask failure stops Homebrew Discovery with status 2"
else
    fail "cask failure was not propagated through Homebrew Discovery"
fi


reset_fixture
FORMULA_MODE=normal
CASK_MODE=normal
MODULES_CHECKED=0
INSTALLED_COUNT=0
SKIPPED_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0
run_module "Homebrew Discovery" discover_homebrew >/dev/null
homebrew_lifecycle_status=$?
if [[ $homebrew_lifecycle_status -eq 0 &&
      $MODULES_CHECKED -eq 1 &&
      $ERROR_COUNT -eq 0 &&
      $WARNING_COUNT -eq 0 &&
      "$SUCCESS_MESSAGES" == *'Homebrew Discovery completed'* ]]; then
    pass "successful Homebrew Discovery reaches the existing module lifecycle"
else
    fail "successful Homebrew Discovery did not preserve lifecycle status 0"
fi

if [[ $TEST_FAILURES -ne 0 ]]; then
    echo
    echo "$TEST_FAILURES Homebrew Discovery test(s) failed"
    exit 1
fi

echo
echo "All Homebrew Discovery tests passed"
