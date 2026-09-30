#!/bin/bash

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
TEST_ROOT="$(cd "$TEST_ROOT" && pwd -P)"
FIXTURE="$TEST_ROOT/toolkit"
INSTALL_DIR="$TEST_ROOT/bin"
TEST_FAILURES=0

trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

mkdir -p "$FIXTURE/bin" "$FIXTURE/scripts" "$INSTALL_DIR" "$TEST_ROOT/outside"
cp "$PROJECT_ROOT/bin/bs" "$FIXTURE/bin/bs"
cp "$PROJECT_ROOT/scripts/install-bs.sh" "$FIXTURE/scripts/install-bs.sh"
mkdir -p "$FIXTURE/modules/core/launcher"
cp "$PROJECT_ROOT/modules/core/launcher/launcher.sh" \
    "$FIXTURE/modules/core/launcher/launcher.sh"
chmod +x "$FIXTURE/bin/bs" "$FIXTURE/scripts/install-bs.sh"

cat > "$FIXTURE/bootstrap.sh" <<'STUB'
#!/bin/bash
printf '%s|%s\n' "$PWD" "$*" >> "$BS_TEST_DISPATCH"
exit "${BS_TEST_STATUS:-0}"
STUB
chmod +x "$FIXTURE/bootstrap.sh"

pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1" >&2; ((TEST_FAILURES++)); }

run_bs() {
    : > "$TEST_ROOT/dispatch"
    (
        cd "$TEST_ROOT/outside" || exit 2
        BS_TEST_DISPATCH="$TEST_ROOT/dispatch" BS_TEST_STATUS="${BS_TEST_STATUS:-0}" \
            "$FIXTURE/bin/bs" "$@"
    ) > "$TEST_ROOT/output" 2>&1
    BS_STATUS=$?
}

for help_args in "" help --help -h; do
    if [[ -n "$help_args" ]]; then
        run_bs "$help_args"
    else
        run_bs
    fi
    if [[ $BS_STATUS -eq 0 && ! -s "$TEST_ROOT/dispatch" ]] &&
       grep -q 'Usage: bs <command>' "$TEST_ROOT/output"; then
        pass "help form '${help_args:-no arguments}'"
    else
        fail "help form '${help_args:-no arguments}'"
    fi
done

while IFS='|' read -r command mode; do
    run_bs "$command"
    expected="$FIXTURE|$mode"
    if [[ $BS_STATUS -eq 0 && "$(cat "$TEST_ROOT/dispatch")" == "$expected" ]]; then
        pass "$command maps to $mode from outside the repository"
    else
        fail "$command mapping or working directory"
    fi
done <<'MAPPINGS'
workflow|--workflow
discover|--discover
blueprint|--blueprint
preview|--dry-run
compare|--compare
bootstrap|--bootstrap
check|--check
MAPPINGS

run_bs unknown
if [[ $BS_STATUS -ne 0 && ! -s "$TEST_ROOT/dispatch" ]] &&
   grep -q 'unknown command' "$TEST_ROOT/output"; then
    pass "unknown command is rejected without dispatch"
else
    fail "unknown command behavior"
fi

BS_TEST_STATUS=2 run_bs preview
[[ $BS_STATUS -eq 2 ]] && pass "production exit status is preserved" ||
    fail "production exit status was changed"

BS_TEST_STATUS=2 run_bs compare
[[ $BS_STATUS -eq 2 ]] && pass "compare exit status is preserved" ||
    fail "compare exit status was changed"

PATH="$INSTALL_DIR:/usr/bin:/bin" BS_INSTALL_DIR="$INSTALL_DIR" \
    "$FIXTURE/scripts/install-bs.sh" --check
missing_check_status=$?
if [[ $missing_check_status -eq 1 && ! -e "$INSTALL_DIR/bs" ]]; then
    pass "installer check reports missing launcher without mutation"
else
    fail "installer check-only missing state"
fi

PATH="$INSTALL_DIR:/usr/bin:/bin" BS_INSTALL_DIR="$INSTALL_DIR" \
    "$FIXTURE/scripts/install-bs.sh" > "$TEST_ROOT/install-output" 2>&1
install_status=$?
PATH="$INSTALL_DIR:/usr/bin:/bin" BS_INSTALL_DIR="$INSTALL_DIR" \
    "$FIXTURE/scripts/install-bs.sh" >> "$TEST_ROOT/install-output" 2>&1
repeat_status=$?
if [[ $install_status -eq 0 && $repeat_status -eq 0 && -L "$INSTALL_DIR/bs" &&
      "$(readlink "$INSTALL_DIR/bs")" == "$FIXTURE/bin/bs" ]]; then
    pass "PATH installation is idempotent"
else
    fail "PATH installation idempotence"
fi

PATH="$INSTALL_DIR:/usr/bin:/bin" BS_INSTALL_DIR="$INSTALL_DIR" \
    "$FIXTURE/scripts/install-bs.sh" --check
check_status=$?
if [[ $check_status -eq 0 && -L "$INSTALL_DIR/bs" ]]; then
    pass "installer check reports the official launcher without mutation"
else
    fail "installer check-only success state"
fi

PATH="/usr/bin:/bin" BS_INSTALL_DIR="$INSTALL_DIR" \
    "$FIXTURE/scripts/install-bs.sh" --check
off_path_check_status=$?
PATH="/usr/bin:/bin" BS_INSTALL_DIR="$INSTALL_DIR" \
    "$FIXTURE/scripts/install-bs.sh" > "$TEST_ROOT/off-path-install-output" 2>&1
off_path_install_status=$?
if [[ $off_path_check_status -eq 1 && $off_path_install_status -eq 0 &&
      -L "$INSTALL_DIR/bs" ]]; then
    pass "off-PATH correct install symlink is missing to check but idempotent to install"
else
    fail "off-PATH correct symlink semantics"
fi

rm "$INSTALL_DIR/bs"
mkdir "$TEST_ROOT/other-bin"
ln -s ../toolkit/bin/bs "$TEST_ROOT/other-bin/bs"
PATH="$TEST_ROOT/other-bin:$INSTALL_DIR:/usr/bin:/bin" \
    BS_INSTALL_DIR="$INSTALL_DIR" "$FIXTURE/scripts/install-bs.sh" \
    > "$TEST_ROOT/existing-correct-output" 2>&1
correct_status=$?
if [[ $correct_status -eq 0 && ! -e "$INSTALL_DIR/bs" ]] &&
   grep -q 'already available' "$TEST_ROOT/existing-correct-output"; then
    pass "existing correct PATH symlink is accepted"
else
    fail "existing correct PATH symlink handling"
fi

rm "$TEST_ROOT/other-bin/bs"
printf '#!/bin/bash\n' > "$INSTALL_DIR/bs"
chmod +x "$INSTALL_DIR/bs"
PATH="$INSTALL_DIR:/usr/bin:/bin" BS_INSTALL_DIR="$INSTALL_DIR" \
    "$FIXTURE/scripts/install-bs.sh" > "$TEST_ROOT/conflict-output" 2>&1
conflict_status=$?
PATH="$INSTALL_DIR:/usr/bin:/bin" BS_INSTALL_DIR="$INSTALL_DIR" \
    "$FIXTURE/scripts/install-bs.sh" --check > "$TEST_ROOT/conflict-check-output" 2>&1
conflict_check_status=$?
if [[ $conflict_status -ne 0 && ! -L "$INSTALL_DIR/bs" ]] &&
   [[ $conflict_check_status -eq 2 ]] &&
   grep -q 'refusing to replace existing file' "$TEST_ROOT/conflict-output"; then
    pass "existing unrelated bs file is preserved"
else
    fail "existing bs conflict behavior"
fi

MODULE_INSTALLER="$FIXTURE/scripts/install-bs.sh"
MODULE_CALLS="$TEST_ROOT/module-calls"
MODULE_MARKER="$TEST_ROOT/module-installed"
cat > "$MODULE_INSTALLER" <<'INSTALLER'
#!/bin/bash
printf '%s\n' "${1:-install}" >> "$MODULE_CALLS"
case "$MODULE_SCENARIO:${1:-install}" in
    correct:--check) exit 0 ;;
    missing:--check|repeat:--check)
        [[ -e "$MODULE_MARKER" ]] && exit 0 || exit 1
        ;;
    missing:install|repeat:install) touch "$MODULE_MARKER"; exit 0 ;;
    conflict:--check) echo 'Error: another bs command already exists' >&2; exit 2 ;;
    unwritable:--check|install-failure:--check|verify-failure:--check)
        [[ -e "$MODULE_MARKER" ]] || exit 1
        [[ "$MODULE_SCENARIO" != verify-failure ]] || exit 2
        exit 0
        ;;
    unwritable:install) echo 'Error: install directory is not writable' >&2; exit 1 ;;
    install-failure:install) echo 'Error: installer failed' >&2; exit 1 ;;
    verify-failure:install) touch "$MODULE_MARKER"; exit 0 ;;
esac
exit 2
INSTALLER
chmod +x "$MODULE_INSTALLER"

success() { MODULE_OUTPUT="${MODULE_OUTPUT}SUCCESS:$1\n"; }
action() { MODULE_OUTPUT="${MODULE_OUTPUT}ACTION:$1\n"; }
error() { MODULE_OUTPUT="${MODULE_OUTPUT}ERROR:$1\n"; }
cd "$FIXTURE" || exit 2
source "$FIXTURE/modules/core/launcher/launcher.sh"

run_module_case() {
    MODULE_SCENARIO="$1"
    export MODULE_SCENARIO MODULE_CALLS MODULE_MARKER
    MODULE_CHANGED=false
    MODULE_OUTPUT=""
    : > "$MODULE_CALLS"
    rm -f "$MODULE_MARKER"
    configure_bs_launcher
    MODULE_STATUS=$?
}

run_module_case missing
if [[ $MODULE_STATUS -eq 0 && "$MODULE_CHANGED" == true &&
      "$(cat "$MODULE_CALLS")" == $'--check\ninstall\n--check' ]] &&
   [[ "$MODULE_OUTPUT" == *'installed and verified'* ]]; then
    pass "Bootstrap lifecycle installs and verifies missing bs"
else
    fail "missing bs lifecycle"
fi

run_module_case correct
if [[ $MODULE_STATUS -eq 0 && "$MODULE_CHANGED" == false &&
      "$(cat "$MODULE_CALLS")" == --check ]] &&
   [[ "$MODULE_OUTPUT" == *'already configured'* ]]; then
    pass "correct bs remains unchanged"
else
    fail "already-correct bs lifecycle"
fi

run_module_case repeat
first_status=$MODULE_STATUS
first_changed=$MODULE_CHANGED
MODULE_CHANGED=false
MODULE_OUTPUT=""
: > "$MODULE_CALLS"
configure_bs_launcher
second_status=$?
if [[ $first_status -eq 0 && "$first_changed" == true && $second_status -eq 0 &&
      "$MODULE_CHANGED" == false && "$(cat "$MODULE_CALLS")" == --check ]]; then
    pass "repeated Bootstrap launcher setup is idempotent"
else
    fail "repeated launcher lifecycle"
fi

for failure_case in conflict unwritable install-failure verify-failure; do
    run_module_case "$failure_case"
    if [[ $MODULE_STATUS -eq 2 && "$MODULE_CHANGED" == false &&
          "$MODULE_OUTPUT" != *SUCCESS:* ]] &&
       ! grep -q sudo "$MODULE_CALLS"; then
        pass "$failure_case is reported without false success or sudo"
    else
        fail "$failure_case failure lifecycle"
    fi
done

bootstrap_launcher_line="$(rg -n 'run_module "bs Launcher" configure_bs_launcher' \
    "$PROJECT_ROOT/bootstrap.sh" | cut -d: -f1)"
bootstrap_case_line="$(rg -n '^[[:space:]]*--bootstrap\)' \
    "$PROJECT_ROOT/bootstrap.sh" | tail -1 | cut -d: -f1)"
workspace_line="$(rg -n 'run_module "Workspace" bootstrap_workspace' \
    "$PROJECT_ROOT/bootstrap.sh" | cut -d: -f1)"
if [[ -n "$bootstrap_launcher_line" && -n "$bootstrap_case_line" &&
      $bootstrap_launcher_line -gt $bootstrap_case_line &&
      $bootstrap_launcher_line -lt $workspace_line ]]; then
    pass "launcher setup is scoped to Bootstrap before domain mutation"
else
    fail "launcher Bootstrap integration point"
fi

[[ $TEST_FAILURES -eq 0 ]] || exit 1
printf 'All bs launcher tests passed\n'
