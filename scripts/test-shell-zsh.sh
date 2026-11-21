#!/bin/bash

set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
export HOME="$TEST_ROOT/home"
mkdir -p "$HOME" "$TEST_ROOT/config/generated"
ZSH_SNAPSHOT_FILE="$TEST_ROOT/config/generated/shell/zshrc.snapshot"
BLUEPRINT_FILE="$TEST_ROOT/blueprint.conf"
BLUEPRINT_GENERATED_DIR="$TEST_ROOT/config/generated"
FAILURES=0
MESSAGES=""
MODULE_CHANGED=false

action() { :; }
success() { MESSAGES="$MESSAGES|$1"; }
warning() { MESSAGES="$MESSAGES|$1"; }
error() { MESSAGES="$MESSAGES|$1"; }
info() { MESSAGES="$MESSAGES|$1"; }
preview_action() { MESSAGES="$MESSAGES|$1"; }
source "$PROJECT_ROOT/modules/shell/zsh.sh"
source "$PROJECT_ROOT/modules/blueprint/blueprint.sh"

check() {
    local label="$1" expected="$2" actual
    shift 2
    MESSAGES=""
    "$@" >/dev/null
    actual=$?
    if [[ $actual -eq $expected ]]; then
        echo "PASS: $label"
    else
        echo "FAIL: $label (expected $expected, got $actual)" >&2
        ((FAILURES++))
    fi
}

assert() {
    local label="$1"
    shift
    if "$@"; then echo "PASS: $label"; else
        echo "FAIL: $label" >&2
        ((FAILURES++))
    fi
}

write_raw() {
    local status="$1" reason="$2" length="$3" hash="$4" payload="${5:-}"
    {
        printf 'MBT-ZSHRC-1\nstatus=%s\nreason=%s\nlength=%s\nsha256=%s\n---\n' \
            "$status" "$reason" "$length" "$hash"
        printf '%s' "$payload"
    } > "$ZSH_SNAPSHOT_FILE"
    chmod 600 "$ZSH_SNAPSHOT_FILE"
}

assert_status() { [[ "$ZSH_SNAPSHOT_STATUS" == "$1" ]]; }
assert_reason() { [[ "$ZSH_SNAPSHOT_REASON" == "$1" ]]; }
assert_no_payload() { [[ "$(wc -c < "$ZSH_SNAPSHOT_FILE")" -eq "$ZSH_SNAPSHOT_OFFSET" ]]; }

check "absent source" 1 discover_zsh
check "absent artifact validates" 0 zsh_snapshot_validate
assert "absent status" assert_status absent
assert "absent carries no payload" assert_no_payload

printf 'alias ll="ls -la"\n' > "$HOME/.zshrc"
check "new static aliases use item-level Capture" 1 discover_zsh
check "source-aware alias artifact validates" 0 zsh_snapshot_validate
assert "new aliases declare capability 3 recovery format" test "$(head -n 1 "$ZSH_SNAPSHOT_FILE")" = MBT-ZSH-ALIASES-3

printf 'export EDITOR=vim\n# preserved trailing line\n' > "$HOME/.zshrc"
check "simple source eligible" 0 discover_zsh
check "eligible artifact validates" 0 zsh_snapshot_validate
assert "eligible status" assert_status eligible
assert "snapshot is private" test "$(stat -f '%Lp' "$ZSH_SNAPSHOT_FILE")" = 600
assert "payload preserves exact bytes" bash -c 'tail -c +"$1" "$2" | cmp -s - "$3"' _ \
    "$((ZSH_SNAPSHOT_OFFSET + 1))" "$ZSH_SNAPSHOT_FILE" "$HOME/.zshrc"

rm "$HOME/.zshrc"
check "Preview plans absent target" 0 preview_zsh
assert "Preview reports plan" test "$MESSAGES" = '|Would restore Zsh configuration'
assert "Preview does not create target" test ! -e "$HOME/.zshrc"
MODULE_CHANGED=false
check "Bootstrap restores absent target" 0 bootstrap_zsh
assert "Bootstrap records mutation" test "$MODULE_CHANGED" = true
assert "restored mode is private" test "$(stat -f '%Lp' "$HOME/.zshrc")" = 600
assert "restored bytes match" cmp -s "$HOME/.zshrc" <(printf 'export EDITOR=vim\n# preserved trailing line\n')
MODULE_CHANGED=false
check "identical Bootstrap is no-op" 0 bootstrap_zsh
assert "identical run records no mutation" test "$MODULE_CHANGED" = false
check "identical Preview is no-op" 0 preview_zsh
chmod 644 "$HOME/.zshrc"
MODULE_CHANGED=false
check "equal target with different mode is no-op" 0 bootstrap_zsh
assert "equal target mode untouched" test "$(stat -f '%Lp' "$HOME/.zshrc")" = 644
assert "equal target mode causes no mutation" test "$MODULE_CHANGED" = false

printf 'alias other="true"\n' > "$HOME/.zshrc"
MODULE_CHANGED=false
check "different target is conflict" 1 bootstrap_zsh
assert "different target untouched" test "$(cat "$HOME/.zshrc")" = 'alias other="true"'
assert "conflict records no mutation" test "$MODULE_CHANGED" = false
check "different target Preview warns" 1 preview_zsh
rm "$HOME/.zshrc"
ln -s "$TEST_ROOT/elsewhere" "$HOME/.zshrc"
check "target symlink refused" 2 bootstrap_zsh
assert "target symlink untouched" test -L "$HOME/.zshrc"
rm "$HOME/.zshrc"

printf 'export API_TOKEN=redacted\n' > "$HOME/.zshrc"
check "sensitive source excluded" 1 discover_zsh
check "excluded artifact validates" 0 zsh_snapshot_validate
assert "sensitive reason" assert_reason sensitive-content
assert "excluded removes prior payload" assert_no_payload
assert "messages contain no secret value" bash -c '[[ "$1" != *redacted* ]]' _ "$MESSAGES"
check "excluded Preview warns" 1 preview_zsh
printf 'TOKEN=redacted\n' > "$HOME/.zshrc"
check "bare sensitive assignment excluded" 1 discover_zsh
check "bare sensitive artifact validates" 0 zsh_snapshot_validate
assert "bare sensitive reason" assert_reason sensitive-content

index=0
for assignment in \
    'TOKEN=value' \
    'TOKEN =value' \
    'TOKEN = value' \
    'export TOKEN=value' \
    'export TOKEN =value' \
    'export TOKEN = value' \
    'typeset API_KEY=value' \
    'typeset API_KEY =value' \
    'typeset API_KEY = value' \
    'export API_TOKEN = redacted' \
    'MY_SECRET = redacted' \
    'AWS_ACCESS_KEY = redacted'; do
    ((index++))
    printf '%s\n' "$assignment" > "$HOME/.zshrc"
    check "sensitive assignment form $index excluded" 1 discover_zsh
    assert "sensitive form $index does not appear in messages" \
        bash -c '[[ "$1" != *redacted* && "$1" != *value* ]]' _ "$MESSAGES"
    check "sensitive assignment form $index validates" 0 zsh_snapshot_validate
    assert "sensitive assignment form $index has stable reason" assert_reason sensitive-content
done

printf 'export HTTPS_PROXY=https://user:redacted@example.invalid/proxy\n' > "$HOME/.zshrc"
check "authenticated URL excluded" 1 discover_zsh
assert "URL credentials absent from messages" bash -c '[[ "$1" != *redacted* ]]' _ "$MESSAGES"
check "authenticated URL artifact validates" 0 zsh_snapshot_validate
assert "authenticated URL has stable reason" assert_reason sensitive-content

for private_source in 'COLOR=ghp_1234567890abcdef' 'MY_SETTING="custom value"' 'typeset -A labels=(work private)' 'export NORMAL="${API_KEY:-fallback}"' '# TOKEN = documented here'; do
    printf '%s\n' "$private_source" > "$HOME/.zshrc"
    check "unreviewed plaintext excluded before whole-file publication" 1 discover_zsh
    assert "private whole-file bytes absent" assert_status excluded
    assert "restricted declaration excluded" assert_reason sensitive-content
done

printf '# Local shell preferences\n' > "$HOME/.zshrc"
check "benign comment remains eligible" 0 discover_zsh
check "benign comment artifact validates" 0 zsh_snapshot_validate
assert "benign comment eligible status" assert_status eligible

printf 'alias x="/Users/example/bin/tool"\n' > "$HOME/.zshrc"
check "source HOME path excluded" 1 discover_zsh
check "portability artifact validates" 0 zsh_snapshot_validate
assert "portability reason" assert_reason portability
printf 'source "$HOME/other.zsh"\n' > "$HOME/.zshrc"
check "sourced dependency excluded" 1 discover_zsh
check "dependency artifact validates" 0 zsh_snapshot_validate
assert "dependency reason" assert_reason dependency
printf 'alias normal="true"\n' > "$HOME/.zshrc"
check "source-aware aliases after exclusions" 1 discover_zsh
rm "$HOME/.zshrc"
check "eligible to absent transition" 1 discover_zsh
check "transition validates" 0 zsh_snapshot_validate
assert "transition removes stale bytes" assert_no_payload

printf 'alias x="true"\n' > "$TEST_ROOT/external"
ln -s "$TEST_ROOT/external" "$HOME/.zshrc"
check "source symlink excluded" 1 discover_zsh
check "external-owner artifact validates" 0 zsh_snapshot_validate
assert "external-owner reason" assert_reason external-owner
rm "$HOME/.zshrc"
printf 'source "$HOME/.dotfiles/shell.zsh"\n' > "$HOME/.zshrc"
check "dotfiles source excluded" 1 discover_zsh
check "dotfiles artifact validates" 0 zsh_snapshot_validate
assert "dotfiles external owner" assert_reason external-owner
rm "$HOME/.zshrc"
mkdir "$HOME/.zshrc"
check "unexpected source type excluded" 1 discover_zsh
rm -r "$HOME/.zshrc"

printf 'alias x="true"\n' > "$HOME/.zshrc"
chmod 000 "$HOME/.zshrc"
check "unreadable source is observation error" 2 discover_zsh
chmod 600 "$HOME/.zshrc"

printf 'export EDITOR=vim\n' > "$HOME/.zshrc"
check "eligible before publication failure" 0 discover_zsh
before="$(shasum -a 256 "$ZSH_SNAPSHOT_FILE")"
mv() { return 1; }
check "publication failure returns error" 2 discover_zsh
unset -f mv
assert "failure preserves valid snapshot" test "$(shasum -a 256 "$ZSH_SNAPSHOT_FILE")" = "$before"
cp() { return 1; }
check "observation failure returns error" 2 discover_zsh
unset -f cp
assert "observation failure preserves snapshot" test "$(shasum -a 256 "$ZSH_SNAPSHOT_FILE")" = "$before"

printf 'source optional.zsh\nalias portable="ls -la"\n' > "$HOME/.zshrc"
mv() { return 1; }
check "alias publication failure returns error" 2 discover_zsh
unset -f mv
assert "alias publication failure preserves previous snapshot" test "$(shasum -a 256 "$ZSH_SNAPSHOT_FILE")" = "$before"
check "mixed source retains portable aliases" 1 discover_zsh
check "alias extension validates" 0 zsh_snapshot_validate
assert "mixed source uses additive format" test "$ZSH_SNAPSHOT_FORMAT" = aliases
assert "alias snapshot stays private" test "$(stat -f '%Lp' "$ZSH_SNAPSHOT_FILE")" = 600
assert "excluded dependency is not stored" bash -c '! grep -q optional.zsh "$1"' _ "$ZSH_SNAPSHOT_FILE"

write_raw eligible - 1 "$(printf x | shasum -a 256 | cut -d ' ' -f1)" x
check "valid raw eligible" 0 zsh_snapshot_validate
write_raw eligible - 2 "$(printf x | shasum -a 256 | cut -d ' ' -f1)" x
check "wrong payload length" 2 zsh_snapshot_validate
write_raw eligible - 1 "$(printf y | shasum -a 256 | cut -d ' ' -f1)" x
check "wrong payload hash" 2 zsh_snapshot_validate
write_raw absent - 0 - x
check "stale absent payload" 2 zsh_snapshot_validate
write_raw excluded dependency 1 - x
check "stale excluded payload" 2 zsh_snapshot_validate
write_raw excluded unknown 0 -
check "unknown exclusion reason" 2 zsh_snapshot_validate
write_raw unknown - 0 -
check "unknown status" 2 zsh_snapshot_validate
write_raw absent - 0 -
sed '1s/MBT-ZSHRC-1/MBT-ZSHRC-2/' "$ZSH_SNAPSHOT_FILE" > "$TEST_ROOT/bad"
mv "$TEST_ROOT/bad" "$ZSH_SNAPSHOT_FILE"
chmod 600 "$ZSH_SNAPSHOT_FILE"
check "invalid schema" 2 zsh_snapshot_validate
printf 'MBT-ZSHRC-1\nstatus=eligible\n' > "$ZSH_SNAPSHOT_FILE"
chmod 600 "$ZSH_SNAPSHOT_FILE"
check "truncated artifact" 2 zsh_snapshot_validate
check "malformed Preview fails" 2 preview_zsh
MODULE_CHANGED=false
rm "$HOME/.zshrc"
check "malformed Bootstrap fails" 2 bootstrap_zsh
assert "malformed input creates no target" test ! -e "$HOME/.zshrc"
assert "malformed input records no mutation" test "$MODULE_CHANGED" = false

check "no Blueprint enables shell category" 0 blueprint_category_enabled shell-zsh
printf '[categories]\ngit-configuration="true"\n' > "$BLUEPRINT_FILE"
check "old Blueprint disables shell category" 1 blueprint_category_enabled shell-zsh

if [[ $FAILURES -gt 0 ]]; then
    echo "$FAILURES shell/Zsh tests failed" >&2
    exit 1
fi
echo "Shell/Zsh tests passed"
