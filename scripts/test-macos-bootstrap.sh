#!/bin/bash

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
cd "$PROJECT_ROOT" || exit 1

HOME="$TEST_ROOT/home"
STATE_FILE="$TEST_ROOT/defaults-state"
MUTATION_LOG="$TEST_ROOT/mutations"
OBSERVATION_LOG="$TEST_ROOT/observations"
VERBOSE=false
MODULE_CHANGED=false
ENABLED_CATEGORIES="all"
READ_TYPE_FAILURE=""
READ_FAILURE=""
WRITE_STATUS=0
WRITE_FAILURE_KEY=""
POST_WRITE_MODE="match"
KILLALL_STATUS=0
FINDER_RESTART_MODE=match
DOCK_RESTART_MODE=match
MKDIR_STATUS=0
MKDIR_NO_CREATE=false
STAT_FAILURE=false
TEST_FAILURES=0

mkdir -p "$HOME" "$TEST_ROOT/generated/macos"
: > "$STATE_FILE"
: > "$MUTATION_LOG"
: > "$OBSERVATION_LOG"

source modules/core/common/common.sh
source modules/settings/macos/macos.sh

FINDER_CONFIG="$TEST_ROOT/generated/macos/finder.conf"
DOCK_CONFIG="$TEST_ROOT/generated/macos/dock.conf"
WINDOWS_CONFIG="$TEST_ROOT/generated/macos/windows.conf"
KEYBOARD_CONFIG="$TEST_ROOT/generated/macos/keyboard.conf"
TRACKPAD_CONFIG="$TEST_ROOT/generated/macos/trackpad.conf"
SCREENSHOTS_CONFIG="$TEST_ROOT/generated/macos/screenshots.conf"
cd "$TEST_ROOT" || exit 1

log() { :; }
blueprint_category_enabled() {
    [[ "$ENABLED_CATEGORIES" == all ]] || grep -Fxq "$1" <<< "$ENABLED_CATEGORIES"
}
killall() {
    printf 'killall:%s\n' "$1" >> "$MUTATION_LOG"
    if [[ "$1" == Finder ]]; then
        case "$FINDER_RESTART_MODE" in
            mismatch) state_set com.apple.finder NewWindowTarget string PfDe ;;
            observation-error) READ_FAILURE='com.apple.finder|NewWindowTarget' ;;
        esac
    fi
    if [[ "$1" == Dock ]]; then
        case "$DOCK_RESTART_MODE" in
            mismatch) state_set com.apple.dock orientation string left ;;
            observation-error) READ_FAILURE='com.apple.dock|orientation' ;;
        esac
    fi
    return "$KILLALL_STATUS"
}
mkdir() {
    local target="${!#}"
    if [[ "$target" == "$HOME/Captures"* ]]; then
        printf 'mkdir:%s\n' "$target" >> "$MUTATION_LOG"
        [[ $MKDIR_STATUS -eq 0 ]] || return "$MKDIR_STATUS"
        [[ "$MKDIR_NO_CREATE" != true ]] || return 0
    fi
    command mkdir "$@"
}
state_get() {
    local domain="$1"
    local key="$2"
    local field="$3"
    awk -F '|' -v domain="$domain" -v key="$key" -v field="$field" \
        '$1 == domain && $2 == key { print $field; found=1; exit } END { if (!found) exit 1 }' \
        "$STATE_FILE"
}
state_set() {
    local domain="$1"
    local key="$2"
    local type="$3"
    local value="$4"
    awk -F '|' -v domain="$domain" -v key="$key" \
        '$1 != domain || $2 != key' "$STATE_FILE" > "$STATE_FILE.next"
    printf '%s|%s|%s|%s\n' "$domain" "$key" "$type" "$value" >> "$STATE_FILE.next"
    mv "$STATE_FILE.next" "$STATE_FILE"
}
defaults() {
    local operation="$1"
    local domain="$2"
    local key="$3"

    printf '%s:%s:%s\n' "$operation" "$domain" "$key" >> "$OBSERVATION_LOG"

    case "$operation" in
        read-type)
            if [[ "$READ_TYPE_FAILURE" == "$domain|$key" ]]; then
                echo "unexpected defaults failure" >&2
                return 2
            fi
            local native_type
            native_type="$(state_get "$domain" "$key" 3)" || {
                echo "The domain/default pair of ($domain, $key) does not exist" >&2
                return 1
            }
            case "$native_type" in
                bool) echo "Type is boolean" ;;
                int) echo "Type is integer" ;;
                string) echo "Type is string" ;;
                *) echo "Type is $native_type" ;;
            esac
            ;;
        read)
            [[ "$READ_FAILURE" != "$domain|$key" ]] || return 2
            state_get "$domain" "$key" 4
            ;;
        write)
            printf 'write:%s:%s:%s:%s\n' "$domain" "$key" "$4" "$5" >> "$MUTATION_LOG"
            [[ $WRITE_STATUS -eq 0 ]] || return "$WRITE_STATUS"
            [[ "$key" != "$WRITE_FAILURE_KEY" ]] || return 2
            local native_type="${4#-}"
            local written_value="$5"
            if [[ "$POST_WRITE_MODE" == mismatch ]]; then
                written_value="unexpected"
            elif [[ "$POST_WRITE_MODE" == observation-error ]]; then
                READ_TYPE_FAILURE="$domain|$key"
            fi
            state_set "$domain" "$key" "$native_type" "$written_value"
            if [[ "$domain|$key" == 'NSGlobalDomain|AppleKeyboardUIMode' ]]; then
                case "$POST_WRITE_MODE" in
                    keyboard-final-mismatch) state_set NSGlobalDomain KeyRepeat int 99 ;;
                    keyboard-final-error) READ_FAILURE='NSGlobalDomain|KeyRepeat' ;;
                esac
            fi
            if [[ "$domain|$key" == 'NSGlobalDomain|AppleWindowTabbingMode' ]]; then
                case "$POST_WRITE_MODE" in
                    windows-final-mismatch) state_set NSGlobalDomain AppleActionOnDoubleClick string Fill ;;
                    windows-final-error) READ_FAILURE='NSGlobalDomain|AppleActionOnDoubleClick' ;;
                esac
            fi
            if [[ "$domain|$key" == 'com.apple.AppleMultitouchTrackpad|TrackpadRightClick' ]]; then
                case "$POST_WRITE_MODE" in
                    trackpad-final-mismatch) state_set com.apple.AppleMultitouchTrackpad Clicking bool false ;;
                    trackpad-final-error) READ_FAILURE='com.apple.AppleMultitouchTrackpad|Clicking' ;;
                esac
            fi
            ;;
        *) return 2 ;;
    esac
}

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; ((TEST_FAILURES++)); }
expect_status() {
    local expected="$1" actual="$2" label="$3"
    [[ "$actual" -eq "$expected" ]] && pass "$label" || fail "$label (expected $expected, got $actual)"
}
assert_no_mutation() {
    [[ ! -s "$MUTATION_LOG" ]] && pass "$1" || fail "$1"
}
assert_no_success() {
    if grep -Eq 'configured successfully|already configured' <<< "$1"; then
        fail "$2"
    else
        pass "$2"
    fi
}
reset_case() {
    : > "$STATE_FILE"
    : > "$MUTATION_LOG"
    : > "$OBSERVATION_LOG"
    : > "$FINDER_CONFIG"
    : > "$DOCK_CONFIG"
    : > "$WINDOWS_CONFIG"
    : > "$KEYBOARD_CONFIG"
    : > "$TRACKPAD_CONFIG"
    : > "$SCREENSHOTS_CONFIG"
    chmod u+rwx "$HOME/Captures" 2>/dev/null || :
    rm -rf "$HOME/Captures" "$HOME/Link" "$HOME/Escape" "$HOME/Broken" "$HOME/Loop" "$HOME/Screenshots"
    MODULE_CHANGED=false
    ENABLED_CATEGORIES="all"
    READ_TYPE_FAILURE=""
    READ_FAILURE=""
    WRITE_STATUS=0
    WRITE_FAILURE_KEY=""
    POST_WRITE_MODE="match"
    KILLALL_STATUS=0
    FINDER_RESTART_MODE=match
    DOCK_RESTART_MODE=match
    MKDIR_STATUS=0
    MKDIR_NO_CREATE=false
    STAT_FAILURE=false
}

stat() {
    if [[ "$STAT_FAILURE" == true ]]; then echo 'stat: observation failure' >&2; return 2; fi
    command stat "$@"
}
run() {
    "$@" > "$TEST_ROOT/output" 2>&1
    status=$?
    output="$(cat "$TEST_ROOT/output")"
}
record() { printf '%s\n' "$2" > "$1"; }
shots() { printf 'com.apple.screencapture|location|string|%s\n' "$1" > "$SCREENSHOTS_CONFIG"; }
assert_changed() { [[ "$MODULE_CHANGED" == "$1" ]] && pass "$2" || fail "$2"; }
assert_count() {
    local actual
    actual="$(grep -c "$1" "$MUTATION_LOG" || true)"
    [[ "$actual" == "$2" ]] && pass "$3" || fail "$3 ($actual)"
}
assert_observation_count() {
    local actual
    actual="$(grep -c "$1" "$OBSERVATION_LOG" || true)"
    [[ "$actual" == "$2" ]] && pass "$3" || fail "$3 ($actual)"
}

# Production schema rejects unsafe records before writes, including late errors.
invalid_records=(
    'com.apple.finder|ShowPathbar|bool|true|extra'
    'unknown.domain|ShowPathbar|bool|true'
    'com.apple.finder|unknown|bool|true'
    'com.apple.dock|autohide|bool|true'
    'com.apple.finder|ShowPathbar|string|true'
    'com.apple.finder|ShowPathbar|bool|maybe'
    'com.apple.finder|FXPreferredViewStyle|string|a|b'
    'malformed'
    $'com.apple.finder|FXPreferredViewStyle|string|a\tb'
    $'com.apple.finder|FXPreferredViewStyle|string|a\nb'
    'com.apple.finder|ShowStatusBar|bool|true'
)
for bad in "${invalid_records[@]}"; do
    reset_case
    printf 'com.apple.finder|ShowStatusBar|bool|true\n%s\n' "$bad" > "$FINDER_CONFIG"
    run apply_defaults_config "$FINDER_CONFIG" finder
    expect_status 2 "$status" "invalid or duplicate category record rejected"
    assert_no_mutation "invalid late record blocks all writes"
done
reset_case
printf 'com.apple.finder|FXPreferredViewStyle|string|a\000b\n' > "$FINDER_CONFIG"
run apply_defaults_config "$FINDER_CONFIG" finder
expect_status 2 "$status" 'NUL rejected before shell parsing'
assert_no_mutation 'NUL record performs no write'

# All existing category identities and empty files remain valid.
reset_case
record "$DOCK_CONFIG" 'com.apple.dock|tilesize|float|65.000000'
state_set com.apple.dock tilesize float 65
run preview_defaults_config "$DOCK_CONFIG" dock
expect_status 0 "$status" 'Dock float numeric equivalent is unchanged in Preview'
[[ "$DEFAULTS_PREVIEW_CHANGED" == false ]] && pass 'Dock float Preview preserves numeric semantics' || fail 'Dock float Preview numeric comparison'
run check_defaults_config "$DOCK_CONFIG" dock
expect_status 0 "$status" 'Dock float numeric equivalent validates and checks'
reset_case
record "$DOCK_CONFIG" 'com.apple.dock|tilesize|float|65.5'
state_set com.apple.dock tilesize int 65
run preview_defaults_config "$DOCK_CONFIG" dock
expect_status 0 "$status" 'Dock fractional float Preview succeeds'
[[ "$output" == *'65 -> 65.5'* ]] && pass 'Dock fractional Preview displays numeric values' || fail 'Dock fractional Preview values'
run apply_defaults_config "$DOCK_CONFIG" dock
expect_status 0 "$status" 'Dock fractional float applies and verifies'
grep -Fq 'write:com.apple.dock:tilesize:-float:65.5' "$MUTATION_LOG" && pass 'Dock fractional value written as float' || fail 'Dock float write type/value'
reset_case
record "$DOCK_CONFIG" 'com.apple.dock|tilesize|float|65.5'
state_set com.apple.dock tilesize string 65.5
run apply_defaults_config "$DOCK_CONFIG" dock
expect_status 2 "$status" 'Incompatible Dock plist type blocks Apply'
assert_no_mutation 'Incompatible Dock plist type causes no write'
reset_case
record "$DOCK_CONFIG" 'com.apple.dock|tilesize|float|invalid'
run apply_defaults_config "$DOCK_CONFIG" dock
expect_status 2 "$status" 'Invalid Dock float record blocks Apply'
assert_no_mutation 'Invalid Dock float record causes no write'

reset_case
for pair in finder dock keyboard trackpad screenshots; do
    run validate_defaults_config "$TEST_ROOT/generated/macos/$pair.conf" "$pair"
    expect_status 0 "$status" "empty $pair remains valid"
done
record "$TRACKPAD_CONFIG" 'NSGlobalDomain|com.apple.trackpad.scaling|int|1'
state_set NSGlobalDomain com.apple.trackpad.scaling int 1
run apply_trackpad_settings
expect_status 2 "$status" 'stale Trackpad scaling record rejected'
assert_no_mutation 'stale Trackpad scaling rejected before mutation'
[[ ! -s "$OBSERVATION_LOG" ]] && pass 'stale Trackpad scaling rejected before inspection' || fail 'stale Trackpad scaling reached inspection'
record "$KEYBOARD_CONFIG" 'NSGlobalDomain|KeyRepeat|int|-03'
state_set NSGlobalDomain KeyRepeat int -3
run check_keyboard
expect_status 0 "$status" 'integer normalization preserved without invented ranges'
record "$FINDER_CONFIG" 'com.apple.finder|FXPreferredViewStyle|string|'
state_set com.apple.finder FXPreferredViewStyle string ''
run check_finder
expect_status 0 "$status" 'empty generic string remains present'

# Missing final newline must be read by Check, Preview and Apply.
reset_case
printf 'com.apple.finder|ShowPathbar|bool|true' > "$FINDER_CONFIG"
state_set com.apple.finder ShowPathbar bool 0
run check_finder
expect_status 1 "$status" 'EOF Check observes the final record'
run preview_macos_category "$FINDER_CONFIG" Finder finder
expect_status 0 "$status" 'EOF Preview succeeds'
[[ "$output" == *'false -> true'* ]] && pass 'EOF Preview includes record' || fail 'EOF Preview lost record'
assert_no_mutation 'EOF Preview is read-only'
run apply_defaults_config "$FINDER_CONFIG" finder
expect_status 0 "$status" 'EOF Apply writes and verifies record'
assert_changed true 'EOF Apply records mutation'
: > "$MUTATION_LOG"
MODULE_CHANGED=false
run apply_defaults_config "$FINDER_CONFIG" finder
expect_status 0 "$status" 'second Apply succeeds'
assert_changed false 'second Apply unchanged'
assert_no_mutation 'second Apply has zero writes'

# Tri-state observations, mutation evidence, and failures run in THIS shell.
for mode in match mismatch observation-error write-failure already-correct absent read-error type-error bad-value wrong-type; do
    reset_case
    record "$KEYBOARD_CONFIG" 'NSGlobalDomain|KeyRepeat|int|2'
    state_set NSGlobalDomain KeyRepeat int 1
    expected=2; changed=false
    case "$mode" in
        match) expected=0; changed=true ;;
        mismatch|observation-error) POST_WRITE_MODE="$mode"; changed=true ;;
        write-failure) WRITE_STATUS=2 ;;
        already-correct) state_set NSGlobalDomain KeyRepeat int 2; expected=0 ;;
        absent) : > "$STATE_FILE"; expected=0; changed=true ;;
        read-error) READ_FAILURE='NSGlobalDomain|KeyRepeat' ;;
        type-error) READ_TYPE_FAILURE='NSGlobalDomain|KeyRepeat' ;;
        bad-value) state_set NSGlobalDomain KeyRepeat int malformed ;;
        wrong-type) state_set NSGlobalDomain KeyRepeat string 1 ;;
    esac
    run apply_keyboard_settings
    expect_status "$expected" "$status" "Keyboard $mode status"
    assert_changed "$changed" "Keyboard $mode accounting"
    [[ $expected -eq 0 ]] || assert_no_success "$output" "Keyboard $mode no false success"
    case "$mode" in already-correct|read-error|type-error|bad-value|wrong-type) assert_no_mutation "$mode no mutation" ;; esac
done

# Finder/Dock Preview restart deduplication and Blueprint gates.
reset_case
record "$FINDER_CONFIG" $'com.apple.finder|ShowPathbar|bool|1\ncom.apple.finder|ShowStatusBar|bool|1'
ENABLED_CATEGORIES=macos-finder
MODULE_CHANGED=preserved
run preview_macos_settings
expect_status 0 "$status" 'multiple Finder absent values planned'
[[ "$(grep -c 'Would restart process: Finder' <<< "$output")" == 1 ]] && pass 'Finder restart once' || fail 'Finder restart count'
assert_changed preserved 'Preview preserves MODULE_CHANGED'
assert_no_mutation 'Finder Preview no mutation'
first_preview="$output"
run preview_macos_settings
[[ "$output" == "$first_preview" ]] && pass 'repeated Preview stable' || fail 'unstable Preview'
record "$DOCK_CONFIG" $'com.apple.dock|autohide|bool|1\ncom.apple.dock|show-recents|bool|0'
ENABLED_CATEGORIES=macos-dock
run preview_macos_settings
[[ $status -eq 0 && "$(grep -c 'Would restart process: Dock' <<< "$output")" == 1 ]] && pass 'Dock restart once' || fail 'Dock restart count'
READ_TYPE_FAILURE='com.apple.dock|autohide'
run preview_macos_settings
expect_status 2 "$status" 'Preview observation error'
[[ "$output" != *Would* ]] || fail 'error invented plan'
ENABLED_CATEGORIES=macos-finder
run preview_macos_settings
expect_status 0 "$status" 'disabled Dock not inspected'
KILLALL_STATUS=2
MODULE_CHANGED=false
run apply_finder_settings
expect_status 2 "$status" 'Finder restart failure'
assert_changed true 'Finder restart failure retains writes'
assert_no_success "$output" 'Finder restart failure no success'


# Stage 9B: exact old/new Finder inventory uses the shared production consumer.
FINDER_OLD_RECORDS=$'NSGlobalDomain|AppleShowAllExtensions|bool|1\ncom.apple.finder|ShowPathbar|bool|1\ncom.apple.finder|ShowStatusBar|bool|1\ncom.apple.finder|FXPreferredViewStyle|string|Nlsv\ncom.apple.finder|FXDefaultSearchScope|string|SCcf\ncom.apple.finder|_FXSortFoldersFirst|bool|1\ncom.apple.finder|FXRemoveOldTrashItems|bool|0'
FINDER_NEW_RECORDS=$'com.apple.finder|AppleShowAllFiles|bool|1\ncom.apple.finder|NewWindowTarget|string|PfHm\ncom.apple.finder|ShowHardDrivesOnDesktop|bool|1\ncom.apple.finder|ShowExternalHardDrivesOnDesktop|bool|1\ncom.apple.finder|ShowMountedServersOnDesktop|bool|1\ncom.apple.finder|FXEnableExtensionChangeWarning|bool|1'
finder_fixture() {
    record "$FINDER_CONFIG" "$FINDER_OLD_RECORDS"$'\n'"$FINDER_NEW_RECORDS"
    local domain key type value
    while IFS='|' read -r domain key type value; do
        state_set "$domain" "$key" "$type" "$value"
    done < "$FINDER_CONFIG"
}

reset_case
record "$FINDER_CONFIG" "$FINDER_OLD_RECORDS"
run validate_defaults_config "$FINDER_CONFIG" finder
expect_status 0 "$status" 'old seven-setting Finder file remains accepted'
while IFS='|' read -r domain key type value; do
    reset_case
    record "$FINDER_CONFIG" "$domain|$key|$type|$value"
    run validate_defaults_config "$FINDER_CONFIG" finder
    expect_status 0 "$status" "$key schema accepted"
    run validate_defaults_config "$FINDER_CONFIG" dock
    expect_status 2 "$status" "$key category crossover rejected"
    wrong_type=string
    [[ "$type" != string ]] || wrong_type=bool
    for invalid in "com.apple.dock|$key|$type|$value" "$domain|$key|$wrong_type|$value" "$domain|$key|$type|$value"$'\n'"$domain|$key|$type|$value"; do
        record "$FINDER_CONFIG" "$invalid"
        run apply_finder_settings
        expect_status 2 "$status" "$key invalid domain/type/duplicate blocked"
        assert_no_mutation "$key invalid input blocks writes/restart"
    done
    # Every new preference participates in typed Apply and repeat idempotency.
    record "$FINDER_CONFIG" "$domain|$key|$type|$value"
    run apply_finder_settings
    expect_status 0 "$status" "$key absent target restored"
    assert_changed true "$key successful write accounted"
    assert_count '^write:' 1 "$key exactly one write"
    assert_count '^killall:Finder' 1 "$key exactly one restart"
    : > "$MUTATION_LOG"
    MODULE_CHANGED=false
    run apply_finder_settings
    expect_status 0 "$status" "$key repeated Apply succeeds"
    assert_changed false "$key repeated Apply unchanged"
    assert_no_mutation "$key repeated Apply no writes/restart"
done <<< "$FINDER_NEW_RECORDS"

for target in PfCm PfVo PfHm PfDe PfDo PfAF PfLo arbitrary ''; do
    reset_case
    record "$FINDER_CONFIG" "com.apple.finder|NewWindowTarget|string|$target"
    run validate_defaults_config "$FINDER_CONFIG" finder
    case "$target" in PfLo|arbitrary|'') expected=2 ;; *) expected=0 ;; esac
    expect_status "$expected" "$status" "NewWindowTarget enum '$target'"
done
for target in $'PfHm|extra' $'PfHm\t' $'PfHm\nextra'; do
    record "$FINDER_CONFIG" "com.apple.finder|NewWindowTarget|string|$target"
    run validate_defaults_config "$FINDER_CONFIG" finder
    expect_status 2 "$status" 'unsafe NewWindowTarget scalar rejected'
done

for mode in matching bool multiple target absent observation-error invalid-enum; do
    reset_case
    finder_fixture
    ENABLED_CATEGORIES=macos-finder
    case "$mode" in
        bool|multiple) state_set com.apple.finder AppleShowAllFiles bool false ;;
        target) state_set com.apple.finder NewWindowTarget string PfDe ;;
        absent) awk -F '|' '$2 != "ShowMountedServersOnDesktop"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        observation-error) READ_FAILURE='NSGlobalDomain|AppleShowAllExtensions' ;;
        invalid-enum) printf 'com.apple.finder|NewWindowTarget|string|PfLo\n' > "$FINDER_CONFIG" ;;
    esac
    [[ "$mode" != multiple ]] || state_set com.apple.finder NewWindowTarget string PfDo
    MODULE_CHANGED=preserved
    PREVIEW_HAS_CHANGES=false
    run preview_macos_settings
    case "$mode" in
        observation-error|invalid-enum) expected=2; plans=0 ;;
        matching) expected=0; plans=0 ;;
        multiple) expected=0; plans=2 ;;
        *) expected=0; plans=1 ;;
    esac
    expect_status "$expected" "$status" "Finder Preview $mode"
    [[ "$(grep -c 'Would change macOS setting:' <<< "$output" || true)" == "$plans" ]] || fail "$mode setting plan count"
    restarts=0; [[ $plans -eq 0 ]] || restarts=1
    [[ "$(grep -c 'Would restart process: Finder' <<< "$output" || true)" == "$restarts" ]] || fail "$mode restart plan count"
    if [[ $plans -gt 0 ]]; then
        [[ "$PREVIEW_HAS_CHANGES" == true ]] || fail "$mode lost explicit Preview signal"
    else
        [[ "$PREVIEW_HAS_CHANGES" == false ]] || fail "$mode invented Preview signal"
    fi
    case "$mode" in
        multiple) [[ "$output" == *'AppleShowAllFiles (false -> true)'*'NewWindowTarget (PfDo -> PfHm)'*'Would restart process: Finder'* ]] || fail 'Finder plan order/values' ;;
        target) [[ "$output" == *'NewWindowTarget (PfDe -> PfHm)'* ]] || fail 'Finder target plan value' ;;
        absent) [[ "$output" == *'ShowMountedServersOnDesktop (absent -> true)'* ]] || fail 'Finder absent plan' ;;
        invalid-enum) [[ ! -s "$OBSERVATION_LOG" ]] || fail 'invalid enum reached inspection' ;;
    esac
    assert_changed preserved "$mode Preview preserves MODULE_CHANGED"
    assert_no_mutation "$mode Preview has no writes/restart"
done

for mode in matching bool multiple target absent write-failure verify-mismatch verify-error restart-failure later-write-failure final-mismatch final-error; do
    reset_case
    finder_fixture
    ENABLED_CATEGORIES=macos-finder
    expected=0; changed=true; writes=1; restarts=1
    case "$mode" in
        matching) changed=false; writes=0; restarts=0 ;;
        bool) state_set com.apple.finder AppleShowAllFiles bool false ;;
        multiple|later-write-failure)
            state_set com.apple.finder AppleShowAllFiles bool false
            state_set com.apple.finder NewWindowTarget string PfDe
            writes=2 ;;
        absent) awk -F '|' '$2 != "NewWindowTarget"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        *) state_set com.apple.finder NewWindowTarget string PfDe ;;
    esac
    case "$mode" in
        write-failure) WRITE_STATUS=2; expected=2; changed=false; restarts=0 ;;
        verify-mismatch) POST_WRITE_MODE=mismatch; expected=2; restarts=0 ;;
        verify-error) POST_WRITE_MODE=observation-error; expected=2; restarts=0 ;;
        restart-failure) KILLALL_STATUS=2; expected=2 ;;
        later-write-failure) WRITE_FAILURE_KEY=NewWindowTarget; expected=2; restarts=0 ;;
        final-mismatch) FINDER_RESTART_MODE=mismatch; expected=2 ;;
        final-error) FINDER_RESTART_MODE=observation-error; expected=2 ;;
    esac
    run apply_macos_settings
    expect_status "$expected" "$status" "Finder Bootstrap $mode"
    assert_changed "$changed" "$mode mutation accounting"
    assert_count '^write:' "$writes" "$mode write count"
    assert_count '^killall:Finder' "$restarts" "$mode restart count"
    if [[ $expected -ne 0 ]]; then
        assert_no_success "$output" "$mode has no false success"
    else
        : > "$MUTATION_LOG"
        run apply_macos_settings
        expect_status 0 "$status" "$mode second Bootstrap succeeds"
        assert_changed false "$mode second Bootstrap unchanged"
        assert_no_mutation "$mode second Bootstrap no writes/restart"
    fi
done

reset_case
finder_fixture
MODULE_CHANGED=true
run apply_finder_settings
expect_status 0 "$status" 'matching Finder with earlier module mutation succeeds'
assert_changed true 'earlier module mutation preserved'
assert_no_mutation 'earlier module mutation does not trigger Finder restart'
ENABLED_CATEGORIES=macos-dock
: > "$OBSERVATION_LOG"
run preview_macos_settings
expect_status 0 "$status" 'disabled Finder skipped by existing category gate'
[[ ! -s "$OBSERVATION_LOG" ]] || fail 'disabled Finder inspected'
ENABLED_CATEGORIES=all
state_set com.apple.finder AppleShowAllFiles bool false
run apply_macos_settings
expect_status 0 "$status" 'no Blueprint includes expanded Finder'
assert_count '^write:' 1 'all-inclusive applies new Finder preference'
assert_count '^killall:Finder' 1 'all-inclusive Finder restart once'

# Stage 9C: exact old/new Dock inventory uses the shared production consumer.
DOCK_OLD_RECORDS=$'com.apple.dock|autohide|bool|1\ncom.apple.dock|show-recents|bool|0\ncom.apple.dock|tilesize|int|48\ncom.apple.dock|magnification|bool|1\ncom.apple.dock|largesize|int|64'
DOCK_NEW_RECORDS=$'com.apple.dock|orientation|string|bottom\ncom.apple.dock|mineffect|string|genie\ncom.apple.dock|minimize-to-application|bool|1\ncom.apple.dock|show-process-indicators|bool|1\ncom.apple.dock|launchanim|bool|1\ncom.apple.dock|mru-spaces|bool|0'
dock_fixture() {
    record "$DOCK_CONFIG" "$DOCK_OLD_RECORDS"$'\n'"$DOCK_NEW_RECORDS"
    local domain key type value
    while IFS='|' read -r domain key type value; do
        state_set "$domain" "$key" "$type" "$value"
    done < "$DOCK_CONFIG"
}

reset_case
record "$DOCK_CONFIG" "$DOCK_OLD_RECORDS"
run validate_defaults_config "$DOCK_CONFIG" dock
expect_status 0 "$status" 'old five-setting Dock file remains accepted'
while IFS='|' read -r domain key type value; do
    reset_case
    record "$DOCK_CONFIG" "$domain|$key|$type|$value"
    run validate_defaults_config "$DOCK_CONFIG" dock
    expect_status 0 "$status" "$key schema accepted"
    run validate_defaults_config "$DOCK_CONFIG" finder
    expect_status 2 "$status" "$key category crossover rejected"
    wrong_type=string
    [[ "$type" != string ]] || wrong_type=bool
    for invalid in "com.apple.finder|$key|$type|$value" "$domain|$key|$wrong_type|$value" "$domain|$key|$type|$value"$'\n'"$domain|$key|$type|$value"; do
        record "$DOCK_CONFIG" "$invalid"
        run apply_dock_settings
        expect_status 2 "$status" "$key invalid domain/type/duplicate blocked"
        assert_no_mutation "$key invalid input blocks writes/restart"
    done
    # Every new preference participates in typed Apply and repeat idempotency.
    record "$DOCK_CONFIG" "$domain|$key|$type|$value"
    run apply_dock_settings
    expect_status 0 "$status" "$key absent target restored"
    assert_changed true "$key successful write accounted"
    assert_count '^write:' 1 "$key exactly one write"
    assert_count '^killall:Dock' 1 "$key exactly one restart"
    : > "$MUTATION_LOG"
    MODULE_CHANGED=false
    run apply_dock_settings
    expect_status 0 "$status" "$key repeated Apply succeeds"
    assert_changed false "$key repeated Apply unchanged"
    assert_no_mutation "$key repeated Apply no writes/restart"
done <<< "$DOCK_NEW_RECORDS"

for key in orientation mineffect; do
    for value in left bottom right genie scale arbitrary ''; do
        reset_case
        record "$DOCK_CONFIG" "com.apple.dock|$key|string|$value"
        run validate_defaults_config "$DOCK_CONFIG" dock
        expected=2
        case "$key:$value" in orientation:left|orientation:bottom|orientation:right|mineffect:genie|mineffect:scale) expected=0 ;; esac
        expect_status "$expected" "$status" "Dock $key enum '$value'"
    done
    for value in $'bottom|extra' $'bottom\t' $'bottom\nextra'; do
        record "$DOCK_CONFIG" "com.apple.dock|$key|string|$value"
        run validate_defaults_config "$DOCK_CONFIG" dock
        expect_status 2 "$status" "unsafe Dock $key scalar rejected"
    done
done

for mode in matching bool multiple target mineffect absent observation-error invalid-enum; do
    reset_case
    dock_fixture
    ENABLED_CATEGORIES=macos-dock
    case "$mode" in
        bool) state_set com.apple.dock minimize-to-application bool false ;;
        multiple)
            state_set com.apple.dock launchanim bool false
            state_set com.apple.dock mru-spaces bool true ;;
        target) state_set com.apple.dock orientation string left ;;
        mineffect) state_set com.apple.dock mineffect string scale ;;
        absent) awk -F '|' '$2 != "show-process-indicators"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        observation-error) READ_FAILURE='com.apple.dock|autohide' ;;
        invalid-enum) printf 'com.apple.dock|orientation|string|PfLo\n' > "$DOCK_CONFIG" ;;
    esac
    MODULE_CHANGED=preserved
    PREVIEW_HAS_CHANGES=false
    run preview_macos_settings
    case "$mode" in
        observation-error|invalid-enum) expected=2; plans=0 ;;
        matching) expected=0; plans=0 ;;
        multiple) expected=0; plans=2 ;;
        *) expected=0; plans=1 ;;
    esac
    expect_status "$expected" "$status" "Dock Preview $mode"
    [[ "$(grep -c 'Would change macOS setting:' <<< "$output" || true)" == "$plans" ]] || fail "$mode setting plan count"
    restarts=0; [[ $plans -eq 0 ]] || restarts=1
    [[ "$(grep -c 'Would restart process: Dock' <<< "$output" || true)" == "$restarts" ]] || fail "$mode restart plan count"
    if [[ $plans -gt 0 ]]; then
        [[ "$PREVIEW_HAS_CHANGES" == true ]] || fail "$mode lost explicit Preview signal"
    else
        [[ "$PREVIEW_HAS_CHANGES" == false ]] || fail "$mode invented Preview signal"
    fi
    case "$mode" in
        multiple) [[ "$output" == *'launchanim (false -> true)'*'mru-spaces (true -> false)'*'Would restart process: Dock'* ]] || fail 'Dock new-setting plan order/values' ;;
        target) [[ "$output" == *'orientation (left -> bottom)'* ]] || fail 'Dock target plan value' ;;
        mineffect) [[ "$output" == *'mineffect (scale -> genie)'* ]] || fail 'Dock effect plan value' ;;
        absent) [[ "$output" == *'show-process-indicators (absent -> true)'* ]] || fail 'Dock absent plan' ;;
        invalid-enum) [[ ! -s "$OBSERVATION_LOG" ]] || fail 'invalid enum reached inspection' ;;
    esac
    assert_changed preserved "$mode Preview preserves MODULE_CHANGED"
    assert_no_mutation "$mode Preview has no writes/restart"
done

for mode in matching bool multiple target mineffect absent observation-error write-failure verify-mismatch verify-error restart-failure later-write-failure final-mismatch final-error; do
    reset_case
    dock_fixture
    ENABLED_CATEGORIES=macos-dock
    expected=0; changed=true; writes=1; restarts=1
    case "$mode" in
        matching) changed=false; writes=0; restarts=0 ;;
        bool) state_set com.apple.dock minimize-to-application bool false ;;
        mineffect) state_set com.apple.dock mineffect string scale ;;
        multiple)
            state_set com.apple.dock launchanim bool false
            state_set com.apple.dock mru-spaces bool true
            writes=2 ;;
        later-write-failure)
            state_set com.apple.dock minimize-to-application bool false
            state_set com.apple.dock orientation string left
            writes=2 ;;
        absent) awk -F '|' '$2 != "orientation"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        *) state_set com.apple.dock orientation string left ;;
    esac
    case "$mode" in
        observation-error) READ_FAILURE='com.apple.dock|autohide'; expected=2; changed=false; writes=0; restarts=0 ;;
        write-failure) WRITE_STATUS=2; expected=2; changed=false; restarts=0 ;;
        verify-mismatch) POST_WRITE_MODE=mismatch; expected=2; restarts=0 ;;
        verify-error) POST_WRITE_MODE=observation-error; expected=2; restarts=0 ;;
        restart-failure) KILLALL_STATUS=2; expected=2 ;;
        later-write-failure) WRITE_FAILURE_KEY=minimize-to-application; expected=2; restarts=0 ;;
        final-mismatch) DOCK_RESTART_MODE=mismatch; expected=2 ;;
        final-error) DOCK_RESTART_MODE=observation-error; expected=2 ;;
    esac
    run apply_macos_settings
    expect_status "$expected" "$status" "Dock Bootstrap $mode"
    assert_changed "$changed" "$mode mutation accounting"
    assert_count '^write:' "$writes" "$mode write count"
    assert_count '^killall:Dock' "$restarts" "$mode restart count"
    if [[ $expected -ne 0 ]]; then
        assert_no_success "$output" "$mode has no false success"
    else
        : > "$MUTATION_LOG"
        run apply_macos_settings
        expect_status 0 "$status" "$mode second Bootstrap succeeds"
        assert_changed false "$mode second Bootstrap unchanged"
        assert_no_mutation "$mode second Bootstrap no writes/restart"
    fi
done

reset_case
dock_fixture
MODULE_CHANGED=true
run apply_dock_settings
expect_status 0 "$status" 'matching Dock with earlier module mutation succeeds'
assert_changed true 'earlier module mutation preserved'
assert_no_mutation 'earlier module mutation does not trigger Dock restart'
ENABLED_CATEGORIES=macos-finder
: > "$OBSERVATION_LOG"
run preview_macos_settings
expect_status 0 "$status" 'disabled Dock skipped by existing category gate'
[[ ! -s "$OBSERVATION_LOG" ]] || fail 'disabled Dock inspected'
ENABLED_CATEGORIES=all
state_set com.apple.dock minimize-to-application bool false
run apply_macos_settings
expect_status 0 "$status" 'no Blueprint includes expanded Dock'
assert_count '^write:' 1 'all-inclusive applies new Dock preference'
assert_count '^killall:Dock' 1 'all-inclusive Dock restart once'

# Stage 9E.1/9E.6: Window Management uses five scalar records and no restart.
WINDOWS_RECORDS=$'NSGlobalDomain|AppleActionOnDoubleClick|string|Minimize\nNSGlobalDomain|AppleWindowTabbingMode|string|fullscreen\nNSGlobalDomain|NSCloseAlwaysConfirmsChanges|bool|1\nNSGlobalDomain|NSQuitAlwaysKeepsWindows|bool|1\ncom.apple.WindowManager|HideDesktop|bool|1'
windows_fixture() {
    record "$WINDOWS_CONFIG" "$WINDOWS_RECORDS"
    local domain key type value
    while IFS='|' read -r domain key type value; do
        state_set "$domain" "$key" "$type" "$value"
    done < "$WINDOWS_CONFIG"
}

while IFS='|' read -r domain key type value; do
    reset_case
    record "$WINDOWS_CONFIG" "$domain|$key|$type|$value"
    run validate_defaults_config "$WINDOWS_CONFIG" windows
    expect_status 0 "$status" "$key Window Management schema accepted"
    run validate_defaults_config "$WINDOWS_CONFIG" dock
    expect_status 2 "$status" "$key Window Management crossover rejected"
    wrong_type=string
    [[ "$type" != string ]] || wrong_type=bool
    wrong_domain=com.apple.WindowManager
    [[ "$domain" != com.apple.WindowManager ]] || wrong_domain=NSGlobalDomain
    for invalid in "$wrong_domain|$key|$type|$value" "$domain|$key|$wrong_type|$value" "$domain|$key|$type|$value"$'\n'"$domain|$key|$type|$value"; do
        record "$WINDOWS_CONFIG" "$invalid"
        run apply_windows_settings
        expect_status 2 "$status" "$key invalid domain/type/duplicate blocked"
        assert_no_mutation "$key invalid Window Management input blocks writes"
    done
    record "$WINDOWS_CONFIG" "$domain|$key|$type|$value"
    run apply_windows_settings
    expect_status 0 "$status" "$key absent Window Management target restored"
    assert_changed true "$key Window Management write accounted"
    assert_count '^write:' 1 "$key Window Management one write"
    assert_count '^killall:' 0 "$key Window Management no restart"
    : > "$MUTATION_LOG"
    MODULE_CHANGED=false
    run apply_windows_settings
    expect_status 0 "$status" "$key repeated Window Management Apply succeeds"
    assert_changed false "$key repeated Window Management Apply unchanged"
    assert_no_mutation "$key repeated Window Management Apply no mutation"
done <<< "$WINDOWS_RECORDS"

for desired in true false; do
    reset_case
    record "$WINDOWS_CONFIG" "com.apple.WindowManager|HideDesktop|bool|$desired"
    state_set com.apple.WindowManager HideDesktop bool "$([[ "$desired" == true ]] && echo false || echo true)"
    MODULE_CHANGED=preserved
    PREVIEW_HAS_CHANGES=false
    run preview_macos_settings
    expect_status 0 "$status" "HideDesktop $desired semantic Preview succeeds"
    expected_plan='Would show Desktop items'
    [[ "$desired" == true ]] && expected_plan='Would hide Desktop items'
    [[ "$output" == *"$expected_plan"* ]] || fail "HideDesktop $desired semantic Preview missing"
    [[ "$output" != *'com.apple.WindowManager'* && "$output" != *'HideDesktop'* ]] || fail "HideDesktop $desired Preview exposed private identity"
    assert_changed preserved "HideDesktop $desired Preview preserves MODULE_CHANGED"
    assert_no_mutation "HideDesktop $desired Preview remains read-only"

    MODULE_CHANGED=false
    run apply_windows_settings
    expect_status 0 "$status" "HideDesktop $desired mismatch restored"
    assert_changed true "HideDesktop $desired write accounted"
    assert_count '^write:com.apple.WindowManager:HideDesktop:' 1 "HideDesktop $desired one write"
    assert_count '^killall:' 0 "HideDesktop $desired no restart"
    : > "$MUTATION_LOG"
    MODULE_CHANGED=false
    run apply_windows_settings
    expect_status 0 "$status" "HideDesktop $desired repeated Apply succeeds"
    assert_changed false "HideDesktop $desired repeated Apply unchanged"
    assert_no_mutation "HideDesktop $desired repeated Apply no-op"
done

reset_case
record "$WINDOWS_CONFIG" 'com.apple.WindowManager|HideDesktop|bool|true'
READ_TYPE_FAILURE='com.apple.WindowManager|HideDesktop'
run apply_windows_settings
expect_status 2 "$status" 'HideDesktop observation error fails'
assert_changed false 'HideDesktop observation error unchanged'
assert_no_mutation 'HideDesktop observation error blocks write'

for mode in write-failure verify-mismatch verify-error; do
    reset_case
    record "$WINDOWS_CONFIG" 'com.apple.WindowManager|HideDesktop|bool|true'
    case "$mode" in
        write-failure) WRITE_STATUS=2 ;;
        verify-mismatch) POST_WRITE_MODE=mismatch ;;
        verify-error) POST_WRITE_MODE=observation-error ;;
    esac
    run apply_windows_settings
    expect_status 2 "$status" "HideDesktop $mode fails"
    assert_count '^write:com.apple.WindowManager:HideDesktop:' 1 "HideDesktop $mode one write attempt"
    assert_count '^killall:' 0 "HideDesktop $mode no restart"
    assert_no_success "$output" "HideDesktop $mode no false success"
done

reset_case
windows_fixture
state_set NSGlobalDomain AppleActionOnDoubleClick string Fill
: > "$OBSERVATION_LOG"
run apply_windows_settings
expect_status 0 "$status" 'final Windows Check includes matching HideDesktop'
assert_observation_count '^read-type:com.apple.WindowManager:HideDesktop$' 2 'HideDesktop inspected during Apply and final Check'
assert_observation_count '^read:com.apple.WindowManager:HideDesktop$' 2 'HideDesktop value read during Apply and final Check'
assert_count '^killall:' 0 'final HideDesktop Check has no restart'

for value in Minimize Maximize Fill None invalid ''; do
    reset_case
    record "$WINDOWS_CONFIG" "NSGlobalDomain|AppleActionOnDoubleClick|string|$value"
    run validate_defaults_config "$WINDOWS_CONFIG" windows
    expected=0
    case "$value" in Minimize|Maximize|Fill|None) ;; *) expected=2 ;; esac
    expect_status "$expected" "$status" "AppleActionOnDoubleClick enum '$value'"
done
for value in manual always fullscreen invalid ''; do
    reset_case
    record "$WINDOWS_CONFIG" "NSGlobalDomain|AppleWindowTabbingMode|string|$value"
    run validate_defaults_config "$WINDOWS_CONFIG" windows
    expected=0
    case "$value" in manual|always|fullscreen) ;; *) expected=2 ;; esac
    expect_status "$expected" "$status" "AppleWindowTabbingMode enum '$value'"
done

for mode in matching enum multiple absent observation-error invalid-enum; do
    reset_case
    windows_fixture
    ENABLED_CATEGORIES=macos-windows
    case "$mode" in
        enum|multiple) state_set NSGlobalDomain AppleActionOnDoubleClick string Fill ;;
        absent) awk -F '|' '$2 != "AppleWindowTabbingMode"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        observation-error) READ_FAILURE='NSGlobalDomain|AppleActionOnDoubleClick' ;;
        invalid-enum) printf 'NSGlobalDomain|AppleActionOnDoubleClick|string|invalid\n' > "$WINDOWS_CONFIG" ;;
    esac
    [[ "$mode" != multiple ]] || state_set NSGlobalDomain NSCloseAlwaysConfirmsChanges bool false
    MODULE_CHANGED=preserved
    PREVIEW_HAS_CHANGES=false
    run preview_macos_settings
    case "$mode" in observation-error|invalid-enum) expected=2; plans=0 ;; matching) expected=0; plans=0 ;; multiple) expected=0; plans=2 ;; *) expected=0; plans=1 ;; esac
    expect_status "$expected" "$status" "Window Management Preview $mode"
    [[ "$(grep -c 'Would change macOS setting:' <<< "$output" || true)" == "$plans" ]] || fail "$mode Window Management plan count"
    [[ "$output" != *'Would restart process:'* ]] || fail "$mode Window Management unexpected restart plan"
    assert_changed preserved "$mode Window Management Preview preserves MODULE_CHANGED"
    assert_no_mutation "$mode Window Management Preview no writes/restart"
done

for mode in matching enum bool multiple absent observation-error write-failure verify-mismatch verify-error later-write-failure final-mismatch final-error; do
    reset_case
    windows_fixture
    ENABLED_CATEGORIES=macos-windows
    expected=0; changed=true; writes=1
    case "$mode" in
        matching) changed=false; writes=0 ;;
        enum) state_set NSGlobalDomain AppleActionOnDoubleClick string Fill ;;
        bool) state_set NSGlobalDomain NSQuitAlwaysKeepsWindows bool false ;;
        multiple|later-write-failure|final-mismatch|final-error)
            state_set NSGlobalDomain AppleActionOnDoubleClick string Fill
            state_set NSGlobalDomain AppleWindowTabbingMode string manual
            writes=2 ;;
        absent) awk -F '|' '$2 != "AppleWindowTabbingMode"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        *) state_set NSGlobalDomain AppleActionOnDoubleClick string Fill ;;
    esac
    case "$mode" in
        observation-error) READ_FAILURE='NSGlobalDomain|AppleActionOnDoubleClick'; expected=2; changed=false; writes=0 ;;
        write-failure) WRITE_STATUS=2; expected=2; changed=false ;;
        verify-mismatch) POST_WRITE_MODE=mismatch; expected=2 ;;
        verify-error) POST_WRITE_MODE=observation-error; expected=2 ;;
        later-write-failure) WRITE_FAILURE_KEY=AppleWindowTabbingMode; expected=2 ;;
        final-mismatch) POST_WRITE_MODE=windows-final-mismatch; expected=2 ;;
        final-error) POST_WRITE_MODE=windows-final-error; expected=2 ;;
    esac
    run apply_macos_settings
    expect_status "$expected" "$status" "Window Management Bootstrap $mode"
    assert_changed "$changed" "$mode Window Management mutation accounting"
    assert_count '^write:' "$writes" "$mode Window Management write count"
    assert_count '^killall:' 0 "$mode Window Management no restart"
    if [[ $expected -ne 0 ]]; then
        assert_no_success "$output" "$mode Window Management no false success"
    else
        : > "$MUTATION_LOG"
        MODULE_CHANGED=false
        run apply_macos_settings
        expect_status 0 "$status" "$mode second Window Management Bootstrap succeeds"
        assert_changed false "$mode second Window Management Bootstrap unchanged"
        assert_no_mutation "$mode second Window Management Bootstrap no mutation"
    fi
done

# Stage 9D: exact old/new Keyboard inventory uses the shared production consumer.
KEYBOARD_OLD_RECORDS=$'NSGlobalDomain|KeyRepeat|int|2\nNSGlobalDomain|InitialKeyRepeat|int|15'
KEYBOARD_NEW_RECORDS=$'NSGlobalDomain|ApplePressAndHoldEnabled|bool|1\nNSGlobalDomain|AppleKeyboardUIMode|int|3\nNSGlobalDomain|NSAutomaticCapitalizationEnabled|bool|1\nNSGlobalDomain|NSAutomaticSpellingCorrectionEnabled|bool|1\nNSGlobalDomain|NSAutomaticPeriodSubstitutionEnabled|bool|1\nNSGlobalDomain|NSAutomaticQuoteSubstitutionEnabled|bool|1\nNSGlobalDomain|NSAutomaticDashSubstitutionEnabled|bool|1'
keyboard_fixture() {
    record "$KEYBOARD_CONFIG" "$KEYBOARD_OLD_RECORDS"$'\n'"$KEYBOARD_NEW_RECORDS"
    local domain key type value
    while IFS='|' read -r domain key type value; do
        state_set "$domain" "$key" "$type" "$value"
    done < "$KEYBOARD_CONFIG"
}

reset_case
record "$KEYBOARD_CONFIG" "$KEYBOARD_OLD_RECORDS"
run validate_defaults_config "$KEYBOARD_CONFIG" keyboard
expect_status 0 "$status" 'old two-setting Keyboard file remains accepted'
while IFS='|' read -r domain key type value; do
    reset_case
    record "$KEYBOARD_CONFIG" "$domain|$key|$type|$value"
    run validate_defaults_config "$KEYBOARD_CONFIG" keyboard
    expect_status 0 "$status" "$key schema accepted"
    run validate_defaults_config "$KEYBOARD_CONFIG" finder
    expect_status 2 "$status" "$key category crossover rejected"
    wrong_type=string
    [[ "$type" != string ]] || wrong_type=bool
    for invalid in "com.apple.finder|$key|$type|$value" "$domain|$key|$wrong_type|$value" "$domain|$key|$type|$value"$'\n'"$domain|$key|$type|$value"; do
        record "$KEYBOARD_CONFIG" "$invalid"
        run apply_keyboard_settings
        expect_status 2 "$status" "$key invalid domain/type/duplicate blocked"
        assert_no_mutation "$key invalid input blocks writes/restart"
    done
    # Every new preference participates in typed Apply and repeat idempotency.
    record "$KEYBOARD_CONFIG" "$domain|$key|$type|$value"
    run apply_keyboard_settings
    expect_status 0 "$status" "$key absent target restored"
    assert_changed true "$key successful write accounted"
    assert_count '^write:' 1 "$key exactly one write"
    assert_count '^killall:' 0 "$key no restart"
    : > "$MUTATION_LOG"
    MODULE_CHANGED=false
    run apply_keyboard_settings
    expect_status 0 "$status" "$key repeated Apply succeeds"
    assert_changed false "$key repeated Apply unchanged"
    assert_no_mutation "$key repeated Apply no writes/restart"
done <<< "$KEYBOARD_NEW_RECORDS"

while IFS='|' read -r domain key type value; do
    [[ "$type" == bool ]] || continue
    for value in 0 1 true false invalid; do
        reset_case
        record "$KEYBOARD_CONFIG" "$domain|$key|bool|$value"
        case "$value" in 1|true) actual=1 ;; *) actual=0 ;; esac
        state_set "$domain" "$key" bool "$actual"
        run check_keyboard
        expected=0; [[ "$value" != invalid ]] || expected=2
        expect_status "$expected" "$status" "$key bool representation $value"
        assert_no_mutation "$key Check no mutation"
    done
done <<< "$KEYBOARD_NEW_RECORDS"
for value in 0 1 2 3 -7 08 12345 invalid 1.5 ''; do
    reset_case
    record "$KEYBOARD_CONFIG" "NSGlobalDomain|AppleKeyboardUIMode|int|$value"
    actual="$value"; [[ "$value" != 08 ]] || actual=8
    state_set NSGlobalDomain AppleKeyboardUIMode int "$actual"
    run check_keyboard
    case "$value" in invalid|1.5|'') expected=2 ;; *) expected=0 ;; esac
    expect_status "$expected" "$status" "AppleKeyboardUIMode integer '$value' without new range"
done

for mode in matching bool multiple target absent observation-error invalid-record; do
    reset_case
    keyboard_fixture
    ENABLED_CATEGORIES=macos-keyboard
    case "$mode" in
        bool|multiple) state_set NSGlobalDomain ApplePressAndHoldEnabled bool false ;;
        target) state_set NSGlobalDomain AppleKeyboardUIMode int 0 ;;
        absent) awk -F '|' '$2 != "NSAutomaticDashSubstitutionEnabled"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        observation-error) READ_FAILURE='NSGlobalDomain|KeyRepeat' ;;
        invalid-record) printf 'NSGlobalDomain|AppleKeyboardUIMode|int|invalid\n' > "$KEYBOARD_CONFIG" ;;
    esac
    [[ "$mode" != multiple ]] || state_set NSGlobalDomain AppleKeyboardUIMode int 2
    MODULE_CHANGED=preserved
    PREVIEW_HAS_CHANGES=false
    run preview_macos_settings
    case "$mode" in
        observation-error|invalid-record) expected=2; plans=0 ;;
        matching) expected=0; plans=0 ;;
        multiple) expected=0; plans=2 ;;
        *) expected=0; plans=1 ;;
    esac
    expect_status "$expected" "$status" "Keyboard Preview $mode"
    [[ "$(grep -c 'Would change macOS setting:' <<< "$output" || true)" == "$plans" ]] || fail "$mode setting plan count"
    [[ "$output" != *'Would restart process:'* ]] || fail "$mode unexpected restart plan"
    if [[ $plans -gt 0 ]]; then
        [[ "$PREVIEW_HAS_CHANGES" == true ]] || fail "$mode lost explicit Preview signal"
    else
        [[ "$PREVIEW_HAS_CHANGES" == false ]] || fail "$mode invented Preview signal"
    fi
    case "$mode" in
        multiple) [[ "$output" == *'ApplePressAndHoldEnabled (false -> true)'*'AppleKeyboardUIMode (2 -> 3)'* ]] || fail 'Keyboard plan order/values' ;;
        target) [[ "$output" == *'AppleKeyboardUIMode (0 -> 3)'* ]] || fail 'Keyboard target plan value' ;;
        absent) [[ "$output" == *'NSAutomaticDashSubstitutionEnabled (absent -> true)'* ]] || fail 'Keyboard absent plan' ;;
        invalid-record) [[ ! -s "$OBSERVATION_LOG" ]] || fail 'invalid enum reached inspection' ;;
    esac
    assert_changed preserved "$mode Preview preserves MODULE_CHANGED"
    assert_no_mutation "$mode Preview has no writes/restart"
done

for mode in matching bool multiple target absent observation-error write-failure verify-mismatch verify-error later-write-failure final-mismatch final-error; do
    reset_case
    keyboard_fixture
    ENABLED_CATEGORIES=macos-keyboard
    expected=0; changed=true; writes=1; restarts=0
    case "$mode" in
        matching) changed=false; writes=0; restarts=0 ;;
        bool) state_set NSGlobalDomain ApplePressAndHoldEnabled bool false ;;
        multiple|later-write-failure)
            state_set NSGlobalDomain ApplePressAndHoldEnabled bool false
            state_set NSGlobalDomain AppleKeyboardUIMode int 0
            writes=2 ;;
        absent) awk -F '|' '$2 != "AppleKeyboardUIMode"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        *) state_set NSGlobalDomain AppleKeyboardUIMode int 0 ;;
    esac
    case "$mode" in
        observation-error) READ_FAILURE='NSGlobalDomain|KeyRepeat'; expected=2; changed=false; writes=0; restarts=0 ;;
        write-failure) WRITE_STATUS=2; expected=2; changed=false; restarts=0 ;;
        verify-mismatch) POST_WRITE_MODE=mismatch; expected=2; restarts=0 ;;
        verify-error) POST_WRITE_MODE=observation-error; expected=2; restarts=0 ;;
        later-write-failure) WRITE_FAILURE_KEY=AppleKeyboardUIMode; expected=2; restarts=0 ;;
        final-mismatch) POST_WRITE_MODE=keyboard-final-mismatch; expected=2 ;;
        final-error) POST_WRITE_MODE=keyboard-final-error; expected=2 ;;
    esac
    run apply_macos_settings
    expect_status "$expected" "$status" "Keyboard Bootstrap $mode"
    assert_changed "$changed" "$mode mutation accounting"
    assert_count '^write:' "$writes" "$mode write count"
    assert_count '^killall:' "$restarts" "$mode restart count"
    if [[ $expected -ne 0 ]]; then
        assert_no_success "$output" "$mode has no false success"
    else
        : > "$MUTATION_LOG"
        run apply_macos_settings
        expect_status 0 "$status" "$mode second Bootstrap succeeds"
        assert_changed false "$mode second Bootstrap unchanged"
        assert_no_mutation "$mode second Bootstrap no writes/restart"
    fi
done

reset_case
keyboard_fixture
MODULE_CHANGED=true
run apply_keyboard_settings
expect_status 0 "$status" 'matching Keyboard with earlier module mutation succeeds'
assert_changed true 'earlier module mutation preserved'
assert_no_mutation 'earlier module mutation does not trigger Keyboard restart'
ENABLED_CATEGORIES=macos-finder
: > "$OBSERVATION_LOG"
run preview_macos_settings
expect_status 0 "$status" 'disabled Keyboard skipped by existing category gate'
[[ ! -s "$OBSERVATION_LOG" ]] || fail 'disabled Keyboard inspected'
ENABLED_CATEGORIES=all
state_set NSGlobalDomain ApplePressAndHoldEnabled bool false
run apply_macos_settings
expect_status 0 "$status" 'no Blueprint includes expanded Keyboard'
assert_count '^write:' 1 'all-inclusive applies new Keyboard preference'
assert_count '^killall:' 0 'all-inclusive Keyboard no restart'

# Stage 9E.3: Trackpad keeps exactly two primary stored boolean preferences.
TRACKPAD_RECORDS=$'com.apple.AppleMultitouchTrackpad|Clicking|bool|1\ncom.apple.AppleMultitouchTrackpad|TrackpadRightClick|bool|1'
trackpad_fixture() {
    record "$TRACKPAD_CONFIG" "$TRACKPAD_RECORDS"
    state_set com.apple.AppleMultitouchTrackpad Clicking bool 1
    state_set com.apple.AppleMultitouchTrackpad TrackpadRightClick bool 1
}

while IFS='|' read -r domain key type value; do
    reset_case
    record "$TRACKPAD_CONFIG" "$domain|$key|$type|$value"
    run validate_defaults_config "$TRACKPAD_CONFIG" trackpad
    expect_status 0 "$status" "$key Trackpad schema accepted"
    for invalid in "com.apple.driver.AppleBluetoothMultitouch.trackpad|$key|$type|$value" \
                   "NSGlobalDomain|$key|$type|$value" \
                   "$domain|$key|int|1"; do
        record "$TRACKPAD_CONFIG" "$invalid"
        run apply_trackpad_settings
        expect_status 2 "$status" "$key unsupported domain/type rejected"
        assert_no_mutation "$key unsupported input blocks writes"
    done
done <<< "$TRACKPAD_RECORDS"

for mode in matching mismatch absent observation-error invalid-type stale-scaling; do
    reset_case
    trackpad_fixture
    ENABLED_CATEGORIES=macos-trackpad
    case "$mode" in
        mismatch) state_set com.apple.AppleMultitouchTrackpad Clicking bool 0 ;;
        absent) awk -F '|' '$2 != "Clicking"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        observation-error) READ_TYPE_FAILURE='com.apple.AppleMultitouchTrackpad|Clicking' ;;
        invalid-type) record "$TRACKPAD_CONFIG" 'com.apple.AppleMultitouchTrackpad|Clicking|int|1' ;;
        stale-scaling) record "$TRACKPAD_CONFIG" 'NSGlobalDomain|com.apple.trackpad.scaling|int|1' ;;
    esac
    MODULE_CHANGED=preserved
    PREVIEW_HAS_CHANGES=false
    run preview_macos_settings
    case "$mode" in
        matching) expected=0; plans=0 ;;
        mismatch|absent) expected=0; plans=1 ;;
        *) expected=2; plans=0 ;;
    esac
    expect_status "$expected" "$status" "Trackpad Preview $mode"
    [[ "$(grep -c 'Would change macOS setting:' <<< "$output" || true)" == "$plans" ]] || fail "$mode Trackpad plan count"
    [[ "$output" != *'Would restart process:'* ]] || fail "$mode Trackpad unexpected restart plan"
    assert_changed preserved "$mode Trackpad Preview preserves MODULE_CHANGED"
    assert_no_mutation "$mode Trackpad Preview remains read-only"
    case "$mode" in invalid-type|stale-scaling) [[ ! -s "$OBSERVATION_LOG" ]] || fail "$mode Trackpad input reached inspection" ;; esac
done

for mode in matching mismatch multiple absent observation-error write-failure verify-mismatch verify-error later-write-failure final-mismatch final-error; do
    reset_case
    trackpad_fixture
    ENABLED_CATEGORIES=macos-trackpad
    expected=0; changed=true; writes=1
    case "$mode" in
        matching) changed=false; writes=0 ;;
        mismatch) state_set com.apple.AppleMultitouchTrackpad Clicking bool 0 ;;
        multiple|later-write-failure)
            state_set com.apple.AppleMultitouchTrackpad Clicking bool 0
            state_set com.apple.AppleMultitouchTrackpad TrackpadRightClick bool 0
            writes=2 ;;
        absent) awk -F '|' '$2 != "Clicking"' "$STATE_FILE" > "$STATE_FILE.next"; mv "$STATE_FILE.next" "$STATE_FILE" ;;
        *) state_set com.apple.AppleMultitouchTrackpad TrackpadRightClick bool 0 ;;
    esac
    case "$mode" in
        observation-error) READ_TYPE_FAILURE='com.apple.AppleMultitouchTrackpad|Clicking'; expected=2; changed=false; writes=0 ;;
        write-failure) WRITE_STATUS=2; expected=2; changed=false ;;
        verify-mismatch) POST_WRITE_MODE=mismatch; expected=2 ;;
        verify-error) POST_WRITE_MODE=observation-error; expected=2 ;;
        later-write-failure) WRITE_FAILURE_KEY=TrackpadRightClick; expected=2 ;;
        final-mismatch) POST_WRITE_MODE=trackpad-final-mismatch; expected=2 ;;
        final-error) POST_WRITE_MODE=trackpad-final-error; expected=2 ;;
    esac
    run apply_macos_settings
    expect_status "$expected" "$status" "Trackpad Bootstrap $mode"
    assert_changed "$changed" "$mode Trackpad mutation accounting"
    assert_count '^write:' "$writes" "$mode Trackpad write count"
    assert_count '^killall:' 0 "$mode Trackpad no restart/signals"
    if grep -Eq 'Bluetooth|ByHost|IOHID' "$MUTATION_LOG"; then
        fail "$mode Trackpad wrote unsupported external/device state"
    else
        pass "$mode Trackpad avoids Bluetooth/ByHost/IOHID writes"
    fi
    if [[ $expected -ne 0 ]]; then
        assert_no_success "$output" "$mode Trackpad has no false success"
    else
        if [[ "$mode" != matching ]]; then
            [[ "$output" == *'Trackpad preferences configured successfully'* ]] || fail "$mode Trackpad truthful success missing"
        fi
        : > "$MUTATION_LOG"
        MODULE_CHANGED=false
        run apply_macos_settings
        expect_status 0 "$status" "$mode second Trackpad Bootstrap succeeds"
        assert_changed false "$mode second Trackpad Bootstrap unchanged"
        assert_no_mutation "$mode second Trackpad Bootstrap no-op"
    fi
done

reset_case
trackpad_fixture
MODULE_CHANGED=true
run apply_trackpad_settings
expect_status 0 "$status" 'matching Trackpad with earlier module mutation succeeds'
assert_changed true 'earlier mutation survives matching Trackpad'
assert_no_mutation 'matching Trackpad does not restart or write'

# Screenshot path validation: fixtures only, never real user directories.
for bad in '' relative '~otheruser/Shot' '$VAR/Shot' '$HOME/Shot' '${HOME}/Shot' '$(touch sentinel)' '`touch sentinel`' "$HOME/../escape" "$HOME/./bad" "$HOME//bad" $'/tmp/a\nb' $'/tmp/a\tb'; do
    reset_case
    shots "$bad"
    run validate_screenshots_config
    expect_status 2 "$status" "unsafe Screenshot path rejected: $bad"
    assert_no_mutation 'unsafe path has no mutation'
done
[[ ! -e sentinel ]] || fail 'shell data was executed'

reset_case
shots "$HOME/Captures/Nested/Deep"
run check_screenshots
expect_status 1 "$status" 'nested missing destination is creatable'
assert_no_mutation 'nested Check is read-only'
reset_case
# The literal tilde is fixture/config input expanded by the consumer.
# shellcheck disable=SC2088
shots '~/Captures'
run apply_screenshots_settings
expect_status 0 "$status" 'leading tilde destination restored'
[[ "$(state_get com.apple.screencapture location 4)" == "$HOME/Captures" ]] && pass 'tilde resolved to absolute preference' || fail 'tilde resolution'

reset_case
command mkdir -p "$TEST_ROOT/outside" "$HOME/Captures"
ln -s "$HOME/Captures" "$HOME/Link"
shots "$HOME/Link"
run validate_screenshots_config
expect_status 0 "$status" 'safe internal directory symlink accepted'
ln -s "$TEST_ROOT/outside" "$HOME/Escape"
shots "$HOME/Escape"
run validate_screenshots_config
expect_status 2 "$status" 'HOME escaping symlink rejected'
ln -s "$HOME/missing" "$HOME/Broken"
shots "$HOME/Broken"
run validate_screenshots_config
expect_status 2 "$status" 'dangling symlink rejected'
ln -s "$HOME/Loop" "$HOME/Loop"
shots "$HOME/Loop"
run validate_screenshots_config
expect_status 2 "$status" 'symlink loop rejected'
shots "$TEST_ROOT/outside"
run validate_screenshots_config
expect_status 0 "$status" 'existing writable outside directory accepted'
shots "$TEST_ROOT/missing-outside"
run validate_screenshots_config
expect_status 2 "$status" 'missing outside tree rejected'
shots "/Volumes/toolkit-missing-$RANDOM-$RANDOM/Captures"
run validate_screenshots_config
expect_status 2 "$status" 'missing mount destination rejected'
reset_case
printf file > "$HOME/Captures"
shots "$HOME/Captures"
run validate_screenshots_config
expect_status 2 "$status" 'wrong filesystem type rejected'
reset_case
command mkdir -p "$HOME/Captures"
chmod 000 "$HOME/Captures"
shots "$HOME/Captures"
run validate_screenshots_config
expect_status 2 "$status" 'inaccessible destination rejected'
chmod 700 "$HOME/Captures"
STAT_FAILURE=true
run check_screenshots
expect_status 2 "$status" 'filesystem observation failure is not absence'

# Complete Screenshot Preview decision table, including explicit plan signal.
for mode in noop preference directory both unsafe; do
    reset_case
    shots "$HOME/Captures"
    state_set com.apple.screencapture location string "$HOME/Captures"
    case "$mode" in
        noop|preference) command mkdir -p "$HOME/Captures" ;;
        unsafe) printf file > "$HOME/Captures" ;;
    esac
    case "$mode" in preference|both|unsafe) state_set com.apple.screencapture location string "$HOME/Old" ;; esac
    MODULE_CHANGED=preserved
    PREVIEW_HAS_CHANGES=false
    run preview_screenshots_settings
    if [[ "$mode" == unsafe ]]; then
        expect_status 2 "$status" 'unsafe Preview error'
        [[ "$output" != *Would* && "$PREVIEW_HAS_CHANGES" == false ]] || fail 'unsafe actionable plan'
    else
        expect_status 0 "$status" "Screenshot Preview $mode"
        case "$mode" in
            noop) [[ "$output" != *Would* && "$PREVIEW_HAS_CHANGES" == false ]] || fail 'no-op plan' ;;
            directory)
                [[ "$output" == *'Would create screenshots directory'* && "$output" != *'Would change'* && "$output" != *'Would restart'* && "$PREVIEW_HAS_CHANGES" == true ]] || fail 'mkdir-only Preview' ;;
            preference)
                [[ "$output" != *'Would create'* && "$output" == *'Would change'* && "$output" == *'Would restart'* ]] || fail 'preference-only Preview' ;;
            both)
                [[ "$output" == *'Would create'*'Would change'*'Would restart'* ]] || fail 'both plan order' ;;
        esac
    fi
    assert_changed preserved "Preview $mode preserves accounting"
    assert_no_mutation "Preview $mode no filesystem/preferences/restart"
done

for mode in directory preference both mkdir-failure mkdir-verify write-failure pref-verify pref-read-error restart-failure; do
    reset_case
    shots "$HOME/Captures/Nested"
    state_set com.apple.screencapture location string "$HOME/Old"
    expected=0; changed=true
    case "$mode" in
        directory) state_set com.apple.screencapture location string "$HOME/Captures/Nested" ;;
        preference|write-failure|pref-verify|pref-read-error|restart-failure) command mkdir -p "$HOME/Captures/Nested" ;;
    esac
    case "$mode" in
        mkdir-failure) MKDIR_STATUS=2; expected=2; changed=false ;;
        mkdir-verify) MKDIR_NO_CREATE=true; expected=2 ;;
        write-failure) WRITE_STATUS=2; expected=2; changed=false ;;
        pref-verify) POST_WRITE_MODE=mismatch; expected=2 ;;
        pref-read-error) POST_WRITE_MODE=observation-error; expected=2 ;;
        restart-failure) KILLALL_STATUS=2; expected=2 ;;
    esac
    run apply_screenshots_settings
    expect_status "$expected" "$status" "Screenshot Apply $mode"
    assert_changed "$changed" "Screenshot Apply $mode accounting"
    [[ $expected -eq 0 ]] || assert_no_success "$output" "$mode no false success"
    case "$mode" in
        directory|mkdir-failure|mkdir-verify)
            assert_count '^killall:' 0 "$mode no restart"
            assert_count '^write:' 0 "$mode no preference write" ;;
        preference|both|restart-failure) assert_count '^killall:SystemUIServer' 1 "$mode restart once" ;;
    esac
    [[ ! -e "$HOME/Screenshots" ]] || fail 'unrelated hard-coded directory created'
    if [[ $expected -eq 0 ]]; then
        : > "$MUTATION_LOG"
        MODULE_CHANGED=false
        run apply_screenshots_settings
        expect_status 0 "$status" "$mode second Apply succeeds"
        assert_changed false "$mode second Apply unchanged"
        assert_no_mutation "$mode second Apply no mutations"
    fi
done
reset_case
# Screenshot EOF and missing location retain the documented distinct semantics.
printf 'com.apple.screencapture|location|string|%s' "$HOME/Captures" > "$SCREENSHOTS_CONFIG"
run apply_screenshots_settings
expect_status 0 "$status" 'Screenshot final line without newline restored'
reset_case
run apply_screenshots_settings
expect_status 0 "$status" 'absent location is unmanaged'
assert_no_mutation 'absent location creates no fallback'
ENABLED_CATEGORIES=macos-keyboard
record "$KEYBOARD_CONFIG" 'NSGlobalDomain|KeyRepeat|int|2'
run apply_macos_settings
expect_status 0 "$status" 'enabled category lifecycle remains compatible'
: > "$MUTATION_LOG"
ENABLED_CATEGORIES=all
run apply_macos_settings
expect_status 0 "$status" 'no-Blueprint behavior remains compatible'
assert_no_mutation 'no-Blueprint matching state unchanged'

# Later successful category must not erase a failure or apply an unobserved state.
check_finder() { return 2; }
check_dock() { return 1; }
apply_finder_settings() { fail 'failed Check reached Finder Apply'; }
apply_dock_settings() { printf 'apply:dock\n' >> "$MUTATION_LOG"; return 0; }
ENABLED_CATEGORIES=$'macos-finder\nmacos-dock'
run apply_macos_components
expect_status 2 "$status" 'later category success preserves earlier error'
[[ "$(cat "$MUTATION_LOG")" == apply:dock ]] || fail 'category Check dispatch changed'

[[ $TEST_FAILURES -eq 0 ]] || { echo "$TEST_FAILURES macOS Bootstrap test(s) failed"; exit 1; }
echo 'All macOS Bootstrap consumer safety tests passed'
