#!/bin/bash

set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR" || exit 1

TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
export HOME="$TEST_DIR"
export BLUEPRINT_GENERATED_DIR="$TEST_DIR/generated"

VERBOSE=false
MODULE_CHANGED=false
BLUEPRINT_PRESENT=false
SELECTED_ITEMS=""
COMMAND_LOG="$TEST_DIR/commands.log"
OBSERVATION_LOG="$TEST_DIR/observations.log"

action() { echo "[ .. ] $*"; }
detail() { :; }
success() { echo "[ OK ] $*"; }
warning() { echo "[WARN] $*"; }
error() { echo "[ERR ] $*"; }
blueprint_exists() { [[ "$BLUEPRINT_PRESENT" == true ]]; }
blueprint_selected_items() { printf '%s\n' "$SELECTED_ITEMS"; }
blueprint_item_selected() {
    [[ "$BLUEPRINT_PRESENT" != true ]] || grep -Fxq "$2" <<< "$SELECTED_ITEMS"
}
blueprint_generated_file() {
    case "$1" in
        app-store) printf '%s\n' "$TEST_DIR/appstore.conf" ;;
        vscode-extensions) printf '%s\n' "$TEST_DIR/vscode-extensions.conf" ;;
        homebrew-casks) printf '%s\n' "$TEST_DIR/brew-casks.conf" ;;
        homebrew-packages) printf '%s\n' "$TEST_DIR/brew-packages.conf" ;;
    esac
}

MAS_LIST_STATUS=0
MAS_LIST_OUTPUT=""
MAS_INSTALL_STATUS=0
mas() {
    [[ "${MAS_NO_AUTO_INDEX:-}" == 1 ]] || fail "mas call lost MAS_NO_AUTO_INDEX=1"
    case "$1" in
        list)
            printf 'mas list\n' >> "$OBSERVATION_LOG"
            if [[ -s "$TEST_DIR/MAS-installed" && $MAS_VERIFY_STATUS -ne 0 ]]; then
                return "$MAS_VERIFY_STATUS"
            fi
            cat "$TEST_DIR/MAS-installed"
            printf '%s' "$MAS_LIST_OUTPUT"
            return "$MAS_LIST_STATUS"
            ;;
        install)
            printf 'mas install %s\n' "$2" >> "$COMMAND_LOG"
            [[ "$2" != "$MAS_FAIL_ITEM" ]] || return 2
            if [[ $MAS_INSTALL_STATUS -eq 0 && $MAS_INSTALL_MAKES_PRESENT == true ]]; then
                printf '%s Mock App (1.0)\n' "$2" >> "$TEST_DIR/MAS-installed"
            fi
            return "$MAS_INSTALL_STATUS"
            ;;
    esac
}

CODE_LIST_STATUS=0
CODE_LIST_OUTPUT=""
CODE_INSTALL_STATUS=0
code() {
    case "$1" in
        --list-extensions)
            printf 'code list\n' >> "$OBSERVATION_LOG"
            if [[ -s "$TEST_DIR/CODE-installed" && $CODE_VERIFY_STATUS -ne 0 ]]; then
                return "$CODE_VERIFY_STATUS"
            fi
            cat "$TEST_DIR/CODE-installed"
            printf '%s' "$CODE_LIST_OUTPUT"
            return "$CODE_LIST_STATUS"
            ;;
        --install-extension)
            printf 'code install %s\n' "$2" >> "$COMMAND_LOG"
            [[ "$2" != "$CODE_FAIL_ITEM" ]] || return 2
            if [[ $CODE_INSTALL_STATUS -eq 0 && $CODE_INSTALL_MAKES_PRESENT == true ]]; then
                printf '%s\n' "$2" >> "$TEST_DIR/CODE-installed"
            fi
            return "$CODE_INSTALL_STATUS"
            ;;
    esac
}

BREW_LIST_STATUS=0
BREW_INFO_STATUS=0
BREW_INSTALL_STATUS=0
BREW_INSTALL_MAKES_PRESENT=false
BREW_INSTALLED_FILE="$TEST_DIR/brew-installed"
CASK_METADATA='default'
FORMULA_INSTALLED_FILE="$TEST_DIR/formula-installed"
FORMULA_READ_STATUS=0
FORMULA_READ_FAIL_AT=0
FORMULA_VERIFY_READ_STATUS=0
FORMULA_INSTALL_FAIL_PACKAGE=""
FORMULA_INSTALL_MAKES_PRESENT=true
FORMULA_INSTALL_COUNT=0
brew() {
    if [[ "$*" == 'list --formula --full-name' ]]; then
        printf 'brew formula list\n' >> "$OBSERVATION_LOG"
        [[ $FORMULA_READ_STATUS -eq 0 ]] || return "$FORMULA_READ_STATUS"
        if [[ "$(grep -c '^brew formula list$' "$OBSERVATION_LOG")" -eq $FORMULA_READ_FAIL_AT ]]; then
            return 2
        fi
        if [[ $FORMULA_INSTALL_COUNT -gt 0 && $FORMULA_VERIFY_READ_STATUS -ne 0 ]]; then
            return "$FORMULA_VERIFY_READ_STATUS"
        fi
        cat "$FORMULA_INSTALLED_FILE"
        return 0
    fi

    if [[ "$1" == install && "$2" != --cask ]]; then
        printf 'brew install %s\n' "$2" >> "$COMMAND_LOG"
        ((FORMULA_INSTALL_COUNT++))
        [[ "$2" != "$FORMULA_INSTALL_FAIL_PACKAGE" ]] || return 2
        if [[ "$FORMULA_INSTALL_MAKES_PRESENT" == true ]]; then
            printf '%s\n' "$2" >> "$FORMULA_INSTALLED_FILE"
        fi
        return 0
    fi

    if [[ "$1" == list && "$2" == --cask ]]; then
        printf 'brew list\n' >> "$OBSERVATION_LOG"
        cat "$BREW_INSTALLED_FILE"
        return "$BREW_LIST_STATUS"
    fi

    if [[ "$1" == --prefix ]]; then
        printf '%s\n' "$TEST_DIR/brew"
        return 0
    fi

    if [[ "$1" == info ]]; then
        local metadata="$CASK_METADATA" installed=null
        grep -Fxq "$4" "$BREW_INSTALLED_FILE" && installed='"1.0"'
        if [[ "$metadata" == default ]]; then
            metadata="$(jq -n --arg target "$TEST_DIR/Applications/$4.app" '{casks:[{artifacts:[{app:[($target | split("/") | last)],target:$target}]}]}')"
        fi
        if jq -e '.casks | length == 1' <<< "$metadata" >/dev/null 2>&1; then
            metadata="$(jq --arg token "$4" --argjson installed "$installed" '.casks[0] += {token:$token,installed:$installed}' <<< "$metadata")"
        fi
        printf '%s\n' "$metadata"
        return "$BREW_INFO_STATUS"
    fi

    if [[ "$1" == install || "$1" == reinstall ]]; then
        printf 'brew %s %s\n' "$1" "$3" >> "$COMMAND_LOG"
        [[ "$3" != "$CASK_FAIL_ITEM" ]] || return 2
        if [[ "$BREW_INSTALL_STATUS" -eq 0 ]]; then
            if [[ "$BREW_INSTALL_MAKES_PRESENT" == true ]]; then
                printf '%s\n' "$3" >> "$BREW_INSTALLED_FILE"
                fixture_app "$TEST_DIR/Applications/$3.app"
            fi
            if [[ "$CASK_REPAIR_TARGETS" == true ]]; then
                fixture_app "$TEST_DIR/Applications/First App.app"
            fixture_app "$TEST_DIR/Applications/Second App.app"
            fi
            BREW_INFO_STATUS="$CASK_VERIFY_INFO_STATUS"
        fi
        return "$BREW_INSTALL_STATUS"
    fi

    return 2
}
command -v jq >/dev/null 2>&1 || { echo "Tests require jq" >&2; exit 1; }

source modules/apps/appstore.sh
source modules/vscode/extensions.sh
source modules/apps/brew-casks.sh
source modules/apps/brew-packages.sh

fixture_app() {
    mkdir -p "$1/Contents/MacOS"
    printf '%s\n' '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleIdentifier</key><string>org.example.fixture</string><key>CFBundleExecutable</key><string>fixture</string></dict></plist>' > "$1/Contents/Info.plist"
    printf '#!/bin/sh\n' > "$1/Contents/MacOS/fixture"
    chmod 700 "$1/Contents/MacOS/fixture"
}

pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }
assert_status() {
    local expected="$1"
    local actual="$2"
    local name="$3"
    [[ "$actual" -eq "$expected" ]] && pass "$name" || fail "$name (expected $expected, got $actual)"
}
assert_no_mutation() {
    local name="$1"
    [[ ! -s "$COMMAND_LOG" ]] && pass "$name" || fail "$name"
}
assert_no_false_success() {
    local output="$1"
    local name="$2"
    if grep -Eq 'installed successfully|applications are ready|extensions are ready|casks are ready|Packages are ready|All .* installed' <<< "$output"; then
        fail "$name"
    fi
    pass "$name"
}
reset_state() {
    : > "$COMMAND_LOG"
    : > "$OBSERVATION_LOG"
    : > "$BREW_INSTALLED_FILE"
    : > "$FORMULA_INSTALLED_FILE"
    FORMULA_READ_STATUS=0
    FORMULA_READ_FAIL_AT=0
    FORMULA_VERIFY_READ_STATUS=0
    FORMULA_INSTALL_FAIL_PACKAGE=""
    FORMULA_INSTALL_MAKES_PRESENT=true
    FORMULA_INSTALL_COUNT=0
    MODULE_CHANGED=false
    BLUEPRINT_PRESENT=false
    SELECTED_ITEMS=""
    MAS_LIST_STATUS=0
    MAS_LIST_OUTPUT=""
    MAS_INSTALL_STATUS=0
    MAS_VERIFY_STATUS=0
    MAS_FAIL_ITEM=""
    MAS_INSTALL_MAKES_PRESENT=true
    : > "$TEST_DIR/MAS-installed"
    CODE_LIST_STATUS=0
    CODE_LIST_OUTPUT=""
    CODE_INSTALL_STATUS=0
    CODE_VERIFY_STATUS=0
    CODE_FAIL_ITEM=""
    CODE_INSTALL_MAKES_PRESENT=true
    : > "$TEST_DIR/CODE-installed"
    BREW_LIST_STATUS=0
    BREW_INFO_STATUS=0
    BREW_INSTALL_STATUS=0
    BREW_INSTALL_MAKES_PRESENT=false
    CASK_METADATA='default'
    CASK_FAIL_ITEM=""
    CASK_REPAIR_TARGETS=false
    CASK_VERIFY_INFO_STATUS=0
    rm -rf "$TEST_DIR/Applications"
    mkdir -p "$TEST_DIR/Applications"
}

printf '111|Installed App\n222|Missing App\n' > "$TEST_DIR/appstore.conf"
printf 'installed.extension\nmissing.extension\n' > "$TEST_DIR/vscode-extensions.conf"
printf 'example-cask\n' > "$TEST_DIR/brew-casks.conf"

# Formula lifecycle uses real production validation and inspection helpers.
# Execute directly: a subshell would hide MODULE_CHANGED from assertions.
run_formula_case() {
    install_brew_packages > "$TEST_DIR/formula.out" 2>&1
    status=$?
    output="$(cat "$TEST_DIR/formula.out")"
}
reset_formula_case() {
    reset_state
    printf 'alpha\nbeta\n' > "$TEST_DIR/brew-packages.conf"
}

reset_formula_case
printf 'alpha\nbeta\n' > "$FORMULA_INSTALLED_FILE"
run_formula_case
assert_status 0 "$status" "already-installed formulae succeed"
assert_no_mutation "already-installed formulae perform no installs"
[[ "$MODULE_CHANGED" == false ]] || fail "already-installed formulae set Changed"
pass "already-installed formulae preserve Changed=false"

reset_formula_case
printf 'alpha\n' > "$FORMULA_INSTALLED_FILE"
run_formula_case
assert_status 0 "$status" "absent formula installs and verifies"
[[ "$(cat "$COMMAND_LOG")" == 'brew install beta' && "$MODULE_CHANGED" == true ]] || fail "formula install/Changed mismatch"
[[ "$(grep -c '^brew formula list$' "$OBSERVATION_LOG")" -eq 3 ]] || fail "formula verification observation missing"
grep -Fxq beta "$FORMULA_INSTALLED_FILE" || fail "formula not installed"
pass "formula install is verified and records Changed=true"
: > "$COMMAND_LOG"
MODULE_CHANGED=false
run_formula_case
assert_status 0 "$status" "repeated formula run succeeds"
assert_no_mutation "repeated formula run is idempotent"
[[ "$MODULE_CHANGED" == false ]] || fail "idempotent run set Changed"

for read_failure in 1 2 7; do
    reset_formula_case
    FORMULA_READ_STATUS=$read_failure
    run_formula_case
    assert_status 2 "$status" "formula inventory failure $read_failure returns 2"
    assert_no_mutation "formula inventory failure $read_failure blocks installs"
    assert_no_false_success "$output" "formula inventory failure has no success"
    [[ "$MODULE_CHANGED" == false ]] || fail "formula read error set Changed"
done

reset_formula_case
FORMULA_INSTALL_FAIL_PACKAGE=alpha
run_formula_case
assert_status 2 "$status" "failed first formula install returns 2"
[[ "$MODULE_CHANGED" == false && "$(cat "$COMMAND_LOG")" == 'brew install alpha' ]] || fail "failed first install changed state or continued"
[[ "$(grep -c '^brew formula list$' "$OBSERVATION_LOG")" -eq 1 ]] || fail "failed install reached Verify"
assert_no_false_success "$output" "failed first formula install has no success"

reset_formula_case
FORMULA_INSTALL_FAIL_PACKAGE=beta
run_formula_case
assert_status 2 "$status" "later formula failure returns 2 after earlier success"
[[ "$MODULE_CHANGED" == true && "$(cat "$FORMULA_INSTALLED_FILE")" == alpha ]] || fail "partial mutation was lost"
[[ "$output" == *'alpha installed successfully'* && "$output" != *'beta installed successfully'* && "$output" != *'Packages are ready'* ]] || fail "partial failure success messages are misleading"
pass "non-transactional formula failure retains earlier mutation and honest output"

reset_formula_case
FORMULA_READ_FAIL_AT=3
run_formula_case
assert_status 2 "$status" "later formula observation error preserves earlier successful install"
[[ "$MODULE_CHANGED" == true && "$(cat "$COMMAND_LOG")" == 'brew install alpha' ]] || fail "later read error lost mutation or attempted another install"
[[ "$output" == *'alpha installed successfully'* && "$output" != *'beta installed successfully'* && "$output" != *'Packages are ready'* ]] || fail "later read error emitted false completion"

for verify_failure in absent read-error; do
    reset_formula_case
    if [[ "$verify_failure" == absent ]]; then
        FORMULA_INSTALL_MAKES_PRESENT=false
    else
        FORMULA_VERIFY_READ_STATUS=2
    fi
    run_formula_case
    assert_status 2 "$status" "formula post-install $verify_failure returns 2"
    [[ "$MODULE_CHANGED" == true && "$(cat "$COMMAND_LOG")" == 'brew install alpha' ]] || fail "Verify failure lost mutation or continued installs"
    assert_no_false_success "$output" "formula Verify failure emits no success"
done

for invalid in '-force' 'has space' '../outside' '/tmp/formula.rb' 'formula.rb' 'https://example.org/a' 'alpha|extra' 'owner//name' 'name;command' $'name\r'; do
    reset_formula_case
    printf 'alpha\n%s\n' "$invalid" > "$TEST_DIR/brew-packages.conf"
    run_formula_case
    assert_status 2 "$status" "invalid formula record '$invalid' returns 2"
    assert_no_mutation "late invalid formula blocks earlier valid install"
    [[ "$MODULE_CHANGED" == false && ! -s "$OBSERVATION_LOG" ]] || fail "invalid formula input reached observation or changed state"
done

reset_formula_case
rm "$TEST_DIR/brew-packages.conf"
run_formula_case
assert_status 2 "$status" "missing formula input returns 2"
assert_no_mutation "missing formula input blocks installs"

reset_formula_case
chmod 000 "$TEST_DIR/brew-packages.conf"
run_formula_case
chmod 600 "$TEST_DIR/brew-packages.conf"
assert_status 2 "$status" "unreadable formula input returns 2"
assert_no_mutation "unreadable formula input blocks installs"

reset_formula_case
printf '# comment\n\n' > "$TEST_DIR/brew-packages.conf"
run_formula_case
assert_status 0 "$status" "empty/comment-only formula input remains valid"
assert_no_mutation "empty formula input installs nothing"

reset_formula_case
BLUEPRINT_PRESENT=true
SELECTED_ITEMS=beta
run_formula_case
assert_status 0 "$status" "Blueprint formula subset installs and verifies"
[[ "$(cat "$COMMAND_LOG")" == 'brew install beta' ]] || fail "Blueprint formula subset changed"
pass "Blueprint excludes unselected formulae"

reset_formula_case
BLUEPRINT_PRESENT=true
SELECTED_ITEMS=""
rm "$TEST_DIR/brew-packages.conf"
run_formula_case
assert_status 0 "$status" "empty Blueprint formula selection needs no input"
[[ ! -s "$COMMAND_LOG" && ! -s "$OBSERVATION_LOG" && "$MODULE_CHANGED" == false ]] || fail "empty Blueprint scope observed or mutated"

reset_formula_case
printf '# names and final line without newline\nopenssl@3\nowner/tap/tool' > "$TEST_DIR/brew-packages.conf"
run_formula_case
assert_status 0 "$status" "versioned and qualified formula names retain their format"
[[ "$(cat "$COMMAND_LOG")" == $'brew install openssl@3\nbrew install owner/tap/tool' ]] || fail "formula names were transformed or dropped"

reset_formula_case
printf 'tool\n' > "$TEST_DIR/brew-packages.conf"
printf 'owner/tap/tool\n' > "$FORMULA_INSTALLED_FILE"
run_formula_case
assert_status 0 "$status" "Discovery short name recognizes installed tap formula"
assert_no_mutation "installed tap short name is not reinstalled"
printf 'other/tap/tool\n' >> "$FORMULA_INSTALLED_FILE"
run_formula_case
assert_status 2 "$status" "ambiguous installed short name returns 2"
assert_no_mutation "ambiguous formula inspection blocks installs"

reset_formula_case
printf 'homebrew/core/alpha\n' > "$TEST_DIR/brew-packages.conf"
printf 'alpha\n' > "$FORMULA_INSTALLED_FILE"
run_formula_case
assert_status 0 "$status" "explicit core formula recognizes canonical inventory name"
assert_no_mutation "qualified core formula is not reinstalled"

reset_formula_case
printf 'owner/tap/tool\n' > "$TEST_DIR/brew-packages.conf"
printf 'other/tap/tool\n' > "$FORMULA_INSTALLED_FILE"
run_formula_case
assert_status 0 "$status" "qualified formula installs despite same basename from another tap"
[[ "$(cat "$COMMAND_LOG")" == 'brew install owner/tap/tool' ]] || fail "qualified formula ignored tap identity"

reset_formula_case
printf 'alpha\nalpha\n' > "$TEST_DIR/brew-packages.conf"
run_formula_case
assert_status 0 "$status" "duplicate valid formula records are idempotent"
[[ "$(cat "$COMMAND_LOG")" == 'brew install alpha' ]] || fail "duplicate record installed twice"

reset_formula_case
VERBOSE=true
FORMULA_INSTALL_FAIL_PACKAGE=alpha
run_formula_case
VERBOSE=false
assert_status 2 "$status" "verbose formula install failure returns 2"
[[ "$MODULE_CHANGED" == false ]] || fail "verbose failed formula install set Changed"
assert_no_false_success "$output" "verbose failed formula install emits no success"

# Complete required application inputs must validate before observation/apply.
run_application_input_case() {
    "$validation_consumer" > "$TEST_DIR/input-validation.out" 2>&1
    status=$?
    output="$(cat "$TEST_DIR/input-validation.out")"
}

for input_domain in casks appstore extensions; do
    case "$input_domain" in
        casks)
            validation_consumer=install_brew_casks
            input_file="$TEST_DIR/brew-casks.conf"
            valid_first=example-cask
            valid_last=other-cask@2
            selected_item=other-cask@2
            expected_install='brew install other-cask@2'
            invalid_records=('-force' 'bad token' '../local' '/tmp/local.rb' 'owner/tap/cask' 'https://example.org/cask' 'local.rb' 'local.json' 'local.sh' 'local.dmg' 'local.pkg' 'bad|token' $'bad\r')
            ;;
        appstore)
            validation_consumer=install_appstore_apps
            input_file="$TEST_DIR/appstore.conf"
            valid_first='111|Installed App'
            valid_last='222|Приложение (Test) & Tools'
            selected_item=222
            expected_install='mas install 222'
            invalid_records=('abc|Name' '-1|Name' '|Name' '123' '123|' '123|Name|Extra' '12 3|Name' '123|   ' '123| Name' '123|Name ' '123|--help' $'123|Bad\tName' 'https://example.org|Name' '$(command)|Name' $'123|Name\r')
            ;;
        extensions)
            validation_consumer=install_vscode_extensions
            input_file="$TEST_DIR/vscode-extensions.conf"
            valid_first=installed.extension
            valid_last=Publisher-2.extension_name-3
            selected_item=Publisher-2.extension_name-3
            expected_install='code install Publisher-2.extension_name-3'
            invalid_records=('-force' 'publisher' '.extension' 'publisher.' 'publisher.extension.extra' 'publisher.bad name' 'publisher/extension' './local.vsix' 'local.vsix' 'https://example.org/ext' 'publisher.extension@1.0' 'publisher.ext;command' $'publisher.ext\r')
            ;;
    esac

    reset_state
    BREW_INSTALL_MAKES_PRESENT=true
    printf '# comment\n\n%s\n%s' "$valid_first" "$valid_last" > "$input_file"
    run_application_input_case
    assert_status 0 "$status" "$input_domain valid input and final line without newline"
    [[ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" -eq 2 && "$MODULE_CHANGED" == true ]] || fail "$input_domain lost a valid record"
    pass "$input_domain preserves names, comments, blank lines, and last record"

    for invalid_record in "${invalid_records[@]}"; do
        for invalid_position in early late; do
            reset_state
            if [[ "$invalid_position" == early ]]; then
                printf '%s\n%s\n' "$invalid_record" "$valid_first" > "$input_file"
            else
                printf '%s\n%s' "$valid_first" "$invalid_record" > "$input_file"
            fi
            run_application_input_case
            assert_status 2 "$status" "$input_domain rejects $invalid_position invalid record '$invalid_record'"
            [[ ! -s "$COMMAND_LOG" && ! -s "$OBSERVATION_LOG" && "$MODULE_CHANGED" == false ]] || fail "$input_domain validation reached observation/mutation"
            assert_no_false_success "$output" "$input_domain invalid input has no false success"
        done
    done

    for invalid_file in missing unreadable directory; do
        reset_state
        printf '%s\n' "$valid_first" > "$input_file"
        case "$invalid_file" in
            missing) rm "$input_file" ;;
            unreadable) chmod 000 "$input_file" ;;
            directory) rm "$input_file"; mkdir "$input_file" ;;
        esac
        run_application_input_case
        case "$invalid_file" in
            unreadable) chmod 600 "$input_file" ;;
            directory) rmdir "$input_file" ;;
        esac
        assert_status 2 "$status" "$input_domain $invalid_file required input returns 2"
        [[ ! -s "$COMMAND_LOG" && ! -s "$OBSERVATION_LOG" && "$MODULE_CHANGED" == false ]] || fail "$input_domain invalid file changed state"
    done

    reset_state
    printf '# only a comment\n\n' > "$input_file"
    run_application_input_case
    assert_status 0 "$status" "$input_domain comment-only input remains valid"
    assert_no_mutation "$input_domain empty input performs no installs"

    reset_state
    BREW_INSTALL_MAKES_PRESENT=true
    BLUEPRINT_PRESENT=true
    SELECTED_ITEMS="$selected_item"
    printf '%s\n%s' "$valid_first" "$valid_last" > "$input_file"
    run_application_input_case
    assert_status 0 "$status" "$input_domain Blueprint subset remains supported"
    [[ "$(cat "$COMMAND_LOG")" == "$expected_install" ]] || fail "$input_domain Blueprint selection changed"
    pass "$input_domain installs exactly the selected item"

    # A nonempty scope requires the complete file, even a late unselected row.
    reset_state
    BLUEPRINT_PRESENT=true
    SELECTED_ITEMS="$selected_item"
    printf '%s\n-bad' "$valid_last" > "$input_file"
    run_application_input_case
    assert_status 2 "$status" "$input_domain selected scope validates its complete required input"
    assert_no_mutation "$input_domain late invalid unselected record blocks partial apply"

    for unused_input in missing malformed; do
        reset_state
        BLUEPRINT_PRESENT=true
        if [[ "$unused_input" == missing ]]; then
            rm -f "$input_file"
        else
            printf '%s\n' '-bad' > "$input_file"
        fi
        run_application_input_case
        assert_status 0 "$status" "$input_domain empty Blueprint scope ignores $unused_input input"
        [[ ! -s "$COMMAND_LOG" && ! -s "$OBSERVATION_LOG" && "$MODULE_CHANGED" == false ]] || fail "$input_domain empty scope inspected input"
    done
done

# Required input errors take precedence over optional CLI availability warnings.
command() {
    if [[ "${1:-}" == -v && "${2:-}" == "$missing_cli" ]]; then
        return 1
    fi
    builtin command "$@"
}
for missing_cli in brew mas code; do
    reset_state
    case "$missing_cli" in
        brew) validation_consumer=install_brew_casks; input_file="$TEST_DIR/brew-casks.conf"; valid_first=example-cask; missing_cli_status=2 ;;
        mas) validation_consumer=install_appstore_apps; input_file="$TEST_DIR/appstore.conf"; valid_first='111|Installed App'; missing_cli_status=1 ;;
        code) validation_consumer=install_vscode_extensions; input_file="$TEST_DIR/vscode-extensions.conf"; valid_first=installed.extension; missing_cli_status=1 ;;
    esac
    printf '%s\n' '-bad' > "$input_file"
    run_application_input_case
    assert_status 2 "$status" "invalid input returns 2 even without $missing_cli"
    printf '%s\n' "$valid_first" > "$input_file"
    run_application_input_case
    assert_status "$missing_cli_status" "$status" "valid input preserves missing $missing_cli status"
    assert_no_mutation "missing $missing_cli performs no installs"
done
unset -f command
# Restore fixtures for the existing consumer lifecycle regression cases.
printf '111|Installed App\n222|Missing App\n' > "$TEST_DIR/appstore.conf"
printf 'installed.extension\nmissing.extension\n' > "$TEST_DIR/vscode-extensions.conf"
printf 'example-cask\n' > "$TEST_DIR/brew-casks.conf"

# App Store observation, apply, and failure semantics.
reset_state
MAS_LIST_OUTPUT=$'111 Installed App (1.0)\n'
output="$(install_appstore_apps)"; status=$?
assert_status 0 "$status" "App Store populated inventory preserves normal installation"
[[ "$(grep -c '^mas list$' "$OBSERVATION_LOG")" == 3 ]] || fail "App Store must check both items and verify the install"
pass "App Store checks both items and verifies the install"
[[ "$(cat "$COMMAND_LOG")" == "mas install 222" ]] || fail "App Store installs only the missing application"
pass "App Store installs only the missing application"

reset_state
output="$(install_appstore_apps)"; status=$?
assert_status 0 "$status" "App Store legitimate empty inventory remains valid"
[[ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" == 2 ]] || fail "App Store empty inventory installs both missing applications"
pass "App Store empty inventory installs both missing applications"

reset_state
MAS_LIST_STATUS=2
output="$(install_appstore_apps 2>&1)"; status=$?
assert_status 2 "$status" "App Store enumeration failure returns 2"
assert_no_mutation "App Store enumeration failure performs zero installs"
assert_no_false_success "$output" "App Store enumeration failure emits no false success"

reset_state
MAS_INSTALL_STATUS=2
install_appstore_apps > "$TEST_DIR/mutation.out" 2>&1; status=$?
output="$(cat "$TEST_DIR/mutation.out")"
assert_status 2 "$status" "App Store installation failure returns 2"
assert_no_false_success "$output" "App Store installation failure emits no false success"
[[ "$MODULE_CHANGED" == false ]] || fail "App Store failed installation does not report a change"
pass "App Store failed installation does not report a change"

# VS Code observation, apply, and failure semantics.
reset_state
CODE_LIST_OUTPUT=$'installed.extension\n'
output="$(install_vscode_extensions)"; status=$?
assert_status 0 "$status" "VS Code populated inventory preserves normal installation"
[[ "$(grep -c '^code list$' "$OBSERVATION_LOG")" == 3 ]] || fail "VS Code must check both items and verify the install"
pass "VS Code checks both items and verifies the install"
[[ "$(cat "$COMMAND_LOG")" == "code install missing.extension" ]] || fail "VS Code installs only the missing extension"
pass "VS Code installs only the missing extension"

reset_state
output="$(install_vscode_extensions)"; status=$?
assert_status 0 "$status" "VS Code legitimate empty inventory remains valid"
[[ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" == 2 ]] || fail "VS Code empty inventory installs both missing extensions"
pass "VS Code empty inventory installs both missing extensions"

reset_state
CODE_LIST_STATUS=2
output="$(install_vscode_extensions 2>&1)"; status=$?
assert_status 2 "$status" "VS Code enumeration failure returns 2"
assert_no_mutation "VS Code enumeration failure performs zero installs"
assert_no_false_success "$output" "VS Code enumeration failure emits no false success"

reset_state
CODE_INSTALL_STATUS=2
install_vscode_extensions > "$TEST_DIR/mutation.out" 2>&1; status=$?
output="$(cat "$TEST_DIR/mutation.out")"
assert_status 2 "$status" "VS Code installation failure returns 2"
assert_no_false_success "$output" "VS Code installation failure emits no false success"
[[ "$MODULE_CHANGED" == false ]] || fail "VS Code failed installation does not report a change"
pass "VS Code failed installation does not report a change"

# Exercise the real lifecycle directly so Changed survives in the test shell.
for lifecycle_domain in appstore extensions; do
    if [[ "$lifecycle_domain" == appstore ]]; then
        validation_consumer=install_appstore_apps
        input_file="$TEST_DIR/appstore.conf"
        first_record='497799835|Xcode'
        second_record='222|Another App'
        first_id=497799835
        second_id=222
        second_label='Another App'
        prefix=MAS
    else
        validation_consumer=install_vscode_extensions
        input_file="$TEST_DIR/vscode-extensions.conf"
        first_record=publisher.extension
        second_record=other.extension
        first_id=publisher.extension
        second_id=other.extension
        second_label=other.extension
        prefix=CODE
    fi
    printf '%s\n' "$first_record" > "$input_file"

    reset_state
    printf '%s\n' "$first_id" > "$TEST_DIR/$prefix-installed"
    run_application_input_case
    assert_status 0 "$status" "$lifecycle_domain exact ID already present"
    assert_no_mutation "$lifecycle_domain exact ID skips installation"
    [[ "$MODULE_CHANGED" == false ]] || fail "already present item set Changed"

    reset_state
    run_application_input_case
    assert_status 0 "$status" "$lifecycle_domain successful install is verified"
    [[ "$MODULE_CHANGED" == true ]] || fail "successful install lost Changed"
    [[ "$(wc -l < "$OBSERVATION_LOG" | tr -d ' ')" == 2 ]] || fail "missing Check or Verify"
    : > "$COMMAND_LOG"
    MODULE_CHANGED=false
    run_application_input_case
    assert_status 0 "$status" "$lifecycle_domain repeated run succeeds"
    assert_no_mutation "$lifecycle_domain repeated run is idempotent"
    [[ "$MODULE_CHANGED" == false ]] || fail "idempotent run set Changed"

    for verify_failure in absent error; do
        reset_state
        if [[ "$verify_failure" == absent ]]; then
            export "${prefix}_INSTALL_MAKES_PRESENT=false"
        else
            export "${prefix}_VERIFY_STATUS=2"
        fi
        run_application_input_case
        assert_status 2 "$status" "$lifecycle_domain Verify $verify_failure returns 2"
        [[ "$MODULE_CHANGED" == true ]] || fail "successful mutation must retain Changed after Verify failure"
        [[ "$(wc -l < "$COMMAND_LOG" | tr -d ' ')" == 1 ]] || fail "Verify failure must follow one install"
        [[ "$(wc -l < "$OBSERVATION_LOG" | tr -d ' ')" == 2 ]] || fail "Verify failure must follow re-observation"
        assert_no_false_success "$output" "$lifecycle_domain Verify $verify_failure has no success"
    done

    reset_state
    printf '%s\n%s\n' "$first_record" "$second_record" > "$input_file"
    export "${prefix}_FAIL_ITEM=$second_id"
    run_application_input_case
    assert_status 2 "$status" "$lifecycle_domain later install failure returns 2"
    [[ "$MODULE_CHANGED" == true ]] || fail "later failure cleared earlier Changed"
    [[ "$output" != *'are ready'* && "$output" != *"$second_label installed successfully"* ]] || fail "later failure reports success"
    pass "$lifecycle_domain retains earlier successful mutation without module success"
done

# Names and numeric substrings must never establish App Store presence.
validation_consumer=install_appstore_apps
printf '497799835|Xcode\n' > "$TEST_DIR/appstore.conf"
for inventory in '999 Xcode Helper (1.0)' '4977998350 Xcode (1.0)' '1497799835 Xcode (1.0)' '0497799835 Xcode (1.0)'; do
    reset_state
    MAS_LIST_OUTPUT="$inventory"
    run_application_input_case
    assert_status 0 "$status" "App Store ignores nonmatching inventory: $inventory"
    [[ "$(cat "$COMMAND_LOG")" == 'mas install 497799835' ]] || fail "App Store matched name or partial ID"
done
reset_state
MAS_LIST_OUTPUT='497799835 Renamed Application (1.0)'
run_application_input_case
assert_status 0 "$status" "App Store exact ID matches regardless of name"
assert_no_mutation "App Store name is display-only"

# Existing VS Code matching remains case-sensitive and whole-line.
validation_consumer=install_vscode_extensions
printf 'publisher.extension\n' > "$TEST_DIR/vscode-extensions.conf"
for inventory in Publisher.extension publisher.extension-extra; do
    reset_state
    CODE_LIST_OUTPUT="$inventory"
    run_application_input_case
    assert_status 0 "$status" "VS Code preserves exact case-sensitive matching: $inventory"
    [[ "$(cat "$COMMAND_LOG")" == 'code install publisher.extension' ]] || fail "VS Code normalized or partially matched an ID"
done
printf '111|Installed App\n222|Missing App\n' > "$TEST_DIR/appstore.conf"
printf 'installed.extension\nmissing.extension\n' > "$TEST_DIR/vscode-extensions.conf"

# Homebrew Cask tri-state observation and verified installation.
reset_state
printf 'example-cask\n' > "$BREW_INSTALLED_FILE"
fixture_app "$TEST_DIR/Applications/example-cask.app"
is_cask_installed example-cask; status=$?
assert_status 0 "$status" "installed Homebrew cask is recognized"

reset_state
is_cask_installed example-cask; status=$?
assert_status 1 "$status" "absent Homebrew cask is distinguished from failure"

reset_state
BREW_LIST_STATUS=2
output="$(install_brew_casks 2>&1)"; status=$?
assert_status 2 "$status" "Homebrew cask inventory failure returns 2"
assert_no_mutation "Homebrew cask inventory failure performs zero installs"
assert_no_false_success "$output" "Homebrew cask inventory failure emits no false success"

reset_state
printf 'example-cask\n' > "$BREW_INSTALLED_FILE"
BREW_INFO_STATUS=2
output="$(install_brew_casks 2>&1)"; status=$?
assert_status 2 "$status" "Homebrew cask metadata failure returns 2"
assert_no_mutation "Homebrew cask metadata failure performs zero installs"

reset_state
printf 'example-cask\n' > "$BREW_INSTALLED_FILE"
CASK_METADATA='{invalid json'
output="$(install_brew_casks 2>&1)"; status=$?
assert_status 2 "$status" "Homebrew cask metadata parsing failure returns 2"
assert_no_mutation "Homebrew cask parsing failure performs zero installs"

reset_state
BREW_INSTALL_MAKES_PRESENT=true
output="$(install_brew_casks 2>&1)"; status=$?
assert_status 0 "$status" "Homebrew cask installation success is verified"
grep -Fq 'installed successfully' <<< "$output" || fail "verified Homebrew cask installation emits success"
pass "verified Homebrew cask installation emits success"

reset_state
output="$(install_brew_casks 2>&1)"; status=$?
assert_status 2 "$status" "Homebrew cask verification failure returns 2"
assert_no_false_success "$output" "Homebrew cask verification failure emits no false success"

reset_state
BREW_INSTALL_STATUS=2
install_brew_casks > "$TEST_DIR/mutation.out" 2>&1; status=$?
output="$(cat "$TEST_DIR/mutation.out")"
assert_status 2 "$status" "Homebrew cask mutation failure returns 2"
assert_no_false_success "$output" "Homebrew cask mutation failure emits no false success"
[[ "$MODULE_CHANGED" == false ]] || fail "Homebrew cask failed installation does not report a change"
pass "Homebrew cask failed installation does not report a change"
[[ "$(grep -c '^brew list$' "$OBSERVATION_LOG")" == 1 ]] || fail "failed cask install skips post-install verification"
pass "failed cask install skips post-install verification"

reset_state
printf 'example-cask\n' > "$BREW_INSTALLED_FILE"
CASK_METADATA="$(jq -n --arg target "$TEST_DIR/Applications/missing-example.app" '{casks:[{artifacts:[{app:["missing-example.app"],target:$target}]}]}')"
BREW_INSTALL_STATUS=2
install_brew_casks > "$TEST_DIR/mutation.out" 2>&1; status=$?
output="$(cat "$TEST_DIR/mutation.out")"
assert_status 2 "$status" "Homebrew cask reinstall failure returns 2"
[[ "$(cat "$COMMAND_LOG")" == "brew reinstall example-cask" ]] || fail "missing cask artifact selects reinstall"
pass "missing cask artifact selects reinstall"
assert_no_false_success "$output" "Homebrew cask reinstall failure emits no false success"
[[ "$(grep -c '^brew list$' "$OBSERVATION_LOG")" == 1 ]] || fail "failed cask reinstall skips post-install verification"
pass "failed cask reinstall skips post-install verification"

reset_state
VERBOSE=true
BREW_INSTALL_STATUS=2
install_brew_cask example-cask install > "$TEST_DIR/mutation.out" 2>&1; status=$?
VERBOSE=false
output="$(cat "$TEST_DIR/mutation.out")"
assert_status 2 "$status" "verbose Homebrew cask mutation failure returns 2"
assert_no_false_success "$output" "verbose cask mutation failure emits no false success"
[[ ! -s "$OBSERVATION_LOG" ]] || fail "verbose failed cask mutation skips verification"
pass "verbose failed cask mutation skips verification"

# Real jq and filesystem inspection of every relocated artifact target.
cask_artifact_fixture() {
    CASK_METADATA="$(jq -n --arg first "$TEST_DIR/Applications/First App.app" --arg second "$TEST_DIR/Applications/Second App.app" '
        {casks:[{token:"example-cask",artifacts:[
            {app:["First App.app"],target:$first},
            {app:["Second App.app"],target:$second},
            {uninstall:[{quit:"org.example.app"}]}, {zap:[{trash:"~/Library/Example"}]}]}]}')"
}
validation_consumer=install_brew_casks
for cask_case in correct install reinstall verify-install verify-reinstall observation-error later-failure; do
    reset_state
    printf 'example-cask\n' > "$TEST_DIR/brew-casks.conf"
    cask_artifact_fixture
    BREW_INSTALL_MAKES_PRESENT=true
    CASK_REPAIR_TARGETS=true
    expected_status=0
    case "$cask_case" in
        correct)
            printf 'example-cask\n' > "$BREW_INSTALLED_FILE"
            fixture_app "$TEST_DIR/Applications/First App.app"
            fixture_app "$TEST_DIR/Applications/Second App.app"
            ;;
        reinstall|verify-reinstall)
            printf 'example-cask\n' > "$BREW_INSTALLED_FILE"
            fixture_app "$TEST_DIR/Applications/First App.app"
            ;;
        later-failure)
            printf 'example-cask\nother-cask\n' > "$TEST_DIR/brew-casks.conf"
            CASK_FAIL_ITEM=other-cask
            expected_status=2
            ;;
        observation-error) CASK_VERIFY_INFO_STATUS=2; expected_status=2 ;;
    esac
    if [[ "$cask_case" == verify-* ]]; then
        CASK_REPAIR_TARGETS=false
        expected_status=2
    fi
    run_application_input_case
    assert_status "$expected_status" "$status" "cask lifecycle $cask_case"
    if [[ "$cask_case" == correct ]]; then
        assert_no_mutation "all cask targets present skips Apply"
        [[ "$MODULE_CHANGED" == false ]] || fail "correct cask set Changed"
    else
        [[ "$MODULE_CHANGED" == true ]] || fail "$cask_case lost successful mutation"
        if [[ "$cask_case" == *reinstall ]]; then
            [[ "$(cat "$COMMAND_LOG")" == 'brew reinstall example-cask' ]] || fail "missing second target must select reinstall"
        fi
        if [[ "$cask_case" == verify-* || "$cask_case" == observation-error ]]; then
            assert_no_false_success "$output" "cask $cask_case emits no success"
        fi
    fi
    if [[ "$expected_status" == 0 ]]; then
        : > "$COMMAND_LOG"
        MODULE_CHANGED=false
        run_application_input_case
        assert_status 0 "$status" "cask $cask_case rerun succeeds"
        assert_no_mutation "cask $cask_case rerun is idempotent"
        [[ "$MODULE_CHANGED" == false ]] || fail "cask rerun set Changed"
    fi
done

# Invalid metadata is observation failure, including a malformed later target.
for bad_metadata in '{}' '{"casks":[]}' '{"casks":[{"artifacts":{}}]}' '{"casks":[{"artifacts":[{"target":"/missing"},{"target":42}]}]}' '{"casks":[{"artifacts":[{"target":"relative.app"}]}]}'; do
    reset_state
    printf 'example-cask\n' > "$BREW_INSTALLED_FILE"
    printf 'example-cask\n' > "$TEST_DIR/brew-casks.conf"
    CASK_METADATA="$bad_metadata"
    run_application_input_case
    assert_status 2 "$status" "malformed cask metadata is observation error"
    assert_no_mutation "malformed cask metadata blocks reinstall"
    [[ "$MODULE_CHANGED" == false ]] || fail "metadata error set Changed"
done

# Blueprint-disabled item categories do not observe or mutate.
reset_state
BLUEPRINT_PRESENT=true
output="$(install_appstore_apps)"; status=$?
assert_status 0 "$status" "empty Blueprint App Store selection skips observation"
output="$(install_vscode_extensions)"; status=$?
assert_status 0 "$status" "empty Blueprint VS Code selection skips observation"
output="$(install_brew_casks)"; status=$?
assert_status 0 "$status" "empty Blueprint cask selection skips observation"
assert_no_mutation "empty Blueprint application selections perform zero mutations"

# Existing run_module lifecycle preserves local error 2 and later success cannot erase it.
source modules/core/common/common.sh
log() { :; }
BLUEPRINT_PRESENT=false

reset_state
MAS_LIST_STATUS=2
run_module "App Store" install_appstore_apps > "$TEST_DIR/run-module.out" 2>&1; status=$?
assert_status 2 "$status" "App Store observation failure reaches run_module as error 2"
[[ "$ERROR_COUNT" -eq 1 ]] || fail "App Store run_module records the error"
pass "App Store run_module records the error"

reset_state
CODE_LIST_STATUS=2
run_module "VS Code Extensions" install_vscode_extensions > "$TEST_DIR/run-module.out" 2>&1; status=$?
assert_status 2 "$status" "VS Code observation failure reaches run_module as error 2"
[[ "$ERROR_COUNT" -eq 2 ]] || fail "VS Code run_module records the error"
pass "VS Code run_module records the error"

reset_state
BREW_LIST_STATUS=2
run_module "Homebrew Casks" install_brew_casks > "$TEST_DIR/run-module.out" 2>&1; status=$?
assert_status 2 "$status" "Homebrew cask observation failure reaches run_module as error 2"
[[ "$ERROR_COUNT" -eq 3 ]] || fail "Homebrew cask run_module records the error"
pass "Homebrew cask run_module records the error"

reset_formula_case
FORMULA_READ_STATUS=2
run_module "Homebrew Packages" install_brew_packages > "$TEST_DIR/run-module.out" 2>&1; status=$?
assert_status 2 "$status" "formula observation failure reaches run_module as error 2"
[[ "$ERROR_COUNT" -eq 4 && "$MODULE_CHANGED" == false ]] || fail "formula error accounting changed"
assert_no_mutation "formula lifecycle observation failure performs zero installs"

later_success() { return 0; }
run_module "Later Success" later_success > "$TEST_DIR/run-module.out" 2>&1
toolkit_exit_code; status=$?
assert_status 2 "$status" "later module success cannot erase application observation errors"

echo
echo "All Bootstrap application safety tests passed"
