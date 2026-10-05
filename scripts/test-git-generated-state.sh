#!/bin/bash
# Focused Git global-state lifecycle tests. All Git writes use a disposable HOME.
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM
REAL_GIT="$(command -v git)"
ORIGINAL_PATH="$PATH"
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL
VERBOSE=false
MODULE_CHANGED=false
TEST_GIT_MODE=normal
TEST_GIT_WROTE=false
FAILURES=0
MESSAGES=""

mkdir -p "$HOME" "$TEST_ROOT/bin"
cd "$TEST_ROOT" || exit 1
source "$PROJECT_ROOT/modules/core/common/common.sh"
source "$PROJECT_ROOT/modules/discovery/discovery.sh"
source "$PROJECT_ROOT/modules/core/git/git.sh"
source "$PROJECT_ROOT/modules/discovery/git.sh"
source "$PROJECT_ROOT/modules/blueprint/blueprint.sh"

log() { :; }
action() { MESSAGES+="|$1"; }
detail() { :; }
success() { MESSAGES+="|$1"; }
warning() { MESSAGES+="|$1"; }
error() { MESSAGES+="|$1"; }
preview_action() { MESSAGES+="|$1"; }
git() {
    if [[ "$TEST_GIT_MODE" == read-failure && "$*" == *"--show-origin --show-scope"* ]]; then
        return 2
    fi
    if [[ "$TEST_GIT_MODE" == write-failure && "$*" == "config --global --add "* ]]; then
        return 2
    fi
    if [[ "$TEST_GIT_MODE" == verify-failure && "$TEST_GIT_WROTE" == true &&
          "$*" == *"--show-origin --show-scope"* ]]; then
        return 2
    fi
    "$REAL_GIT" "$@"
    local result=$?
    if [[ "$TEST_GIT_MODE" == verify-failure && "$*" == "config --global --add "* &&
          $result -eq 0 ]]; then
        TEST_GIT_WROTE=true
    fi
    return "$result"
}
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILURES=$((FAILURES + 1)); }
assert_status() {
    local label="$1" expected="$2"
    shift 2
    MESSAGES=""
    "$@" >/dev/null
    local actual=$?
    [[ $actual -eq $expected ]] && pass "$label" || fail "$label (got $actual, expected $expected)"
}
reset_fixture() {
    rm -rf "$HOME" "$TEST_ROOT/config"
    mkdir -p "$HOME"
    TEST_GIT_MODE=normal
    TEST_GIT_WROTE=false
    MODULE_CHANGED=false
    MESSAGES=""
}
generated_value() {
    mkdir -p config/generated
    touch config/generated/git.conf
    "$REAL_GIT" config --file config/generated/git.conf "$1" "$2"
}
global_value() { "$REAL_GIT" config --global "$1" "$2"; }
assert_global() {
    local label="$1" key="$2" expected="$3" actual
    actual="$("$REAL_GIT" config --global --no-includes --get "$key")"
    [[ "$actual" == "$expected" ]] && pass "$label" || fail "$label"
}
assert_unset() {
    local label="$1" key="$2"
    "$REAL_GIT" config --global --no-includes --get "$key" >/dev/null 2>&1
    local status=$?
    [[ $status -ne 0 ]] && pass "$label" ||
        fail "$label (status $status, dotgitconfig exists: $([[ -e "$HOME/.gitconfig" ]] && echo yes || echo no))"
}
blueprint_fixture() {
    cp "$PROJECT_ROOT/config/blueprint.example.conf" config/blueprint.conf
}

# Seven-key producer and generated-input allowlist.
reset_fixture
global_value user.name 'Fixture User'
global_value user.email fixture@example.invalid
global_value init.defaultBranch main
global_value pull.rebase false
global_value core.editor vim
global_value user.useConfigOnly yes
global_value pull.ff only
assert_status 'Discovery exports seven direct keys' 0 discover_git
keys="$("$REAL_GIT" config --file config/generated/git.conf --no-includes --name-only --list)"
[[ "$(printf '%s\n' "$keys" | wc -l | tr -d ' ')" == 7 ]] &&
[[ "$("$REAL_GIT" config --file config/generated/git.conf --get user.useConfigOnly)" == true ]] &&
[[ "$("$REAL_GIT" config --file config/generated/git.conf --get pull.ff)" == only ]] &&
pass 'seven-key order and boolean normalization' || fail 'seven-key order and boolean normalization'
assert_status 'generated seven-key input validates' 0 load_git_configuration

reset_fixture
generated_value user.name 'Fixture User'
generated_value user.email fixture@example.invalid
generated_value init.defaultBranch main
generated_value pull.rebase false
generated_value core.editor vim
generated_value user.useConfigOnly true
generated_value pull.ff only
assert_status 'seven-key clean target Bootstrap' 0 configure_git
[[ "$("$REAL_GIT" config --global --no-includes --name-only --list | wc -l | tr -d ' ')" == 7 ]] &&
pass 'all seven settings created' || fail 'all seven settings created'

for pair in 'pull.rebase:yes:true' 'pull.rebase:off:false' \
            'user.useConfigOnly:no:false' 'user.useConfigOnly:on:true' \
            'pull.ff:0:false' 'pull.ff:1:true' 'pull.ff:only:only'; do
    reset_fixture
    IFS=: read -r key raw expected <<< "$pair"
    global_value "$key" "$raw"
    assert_status "Discovery normalizes $key=$raw" 0 discover_git
    assert_global "source remains $raw" "$key" "$raw"
    actual="$("$REAL_GIT" config --file config/generated/git.conf --get "$key")"
    [[ "$actual" == "$expected" ]] && pass "snapshot is $expected" || fail "snapshot is $expected"
done

reset_fixture
assert_status 'all absent publishes empty snapshot' 0 discover_git
[[ ! -s config/generated/git.conf ]] && pass 'empty snapshot is valid' || fail 'empty snapshot is valid'
global_value user.name Existing
assert_status 'absent source key is unmanaged' 0 configure_git
assert_global 'absent source preserves target' user.name Existing
[[ "$MODULE_CHANGED" == false ]] && pass 'no change accounting for unmanaged key' || fail 'no change accounting'

for key in alias.unsafe include.path user.name pull.rebase user.useConfigOnly pull.ff core.editor init.defaultBranch; do
    reset_fixture
    case "$key" in
        alias.unsafe) value='!echo no' ;;
        include.path) value="$HOME/other" ;;
        user.name) value='' ;;
        pull.rebase) value='bad' ;;
        user.useConfigOnly) value='bad' ;;
        pull.ff) value='bad' ;;
        core.editor) value='sh -c bad' ;;
        init.defaultBranch) value='' ;;
    esac
    generated_value "$key" "$value"
    assert_status "generated rejects $key" 2 load_git_configuration
done
reset_fixture
generated_value user.name First
"$REAL_GIT" config --file config/generated/git.conf --add user.name Second
assert_status 'generated duplicate rejected' 2 load_git_configuration
for editor in 'vim -f' '/usr/bin/vim' '"vim"' 'EDITOR=vim vim' 'vim; false' '$(false)'; do
    reset_fixture
    generated_value core.editor "$editor"
    assert_status "unsafe editor form rejected" 2 load_git_configuration
done
reset_fixture
mkdir -p config/generated
printf '[broken\n' > config/generated/git.conf
assert_status 'malformed generated syntax rejected' 2 load_git_configuration

# Unsupported individual source keys are omitted, not serialized.
reset_fixture
global_value user.name 'Fixture User'
global_value core.editor 'sh -c bad'
assert_status 'unsupported source editor gives warning' 1 discover_git
[[ "$("$REAL_GIT" config --file config/generated/git.conf --name-only --list)" == user.name ]] &&
pass 'unsupported editor excluded' || fail 'unsupported editor excluded'
reset_fixture
global_value user.name $'bad\nname'
assert_status 'control character source excluded' 1 discover_git
[[ ! -s config/generated/git.conf ]] && pass 'unsafe identity not published' || fail 'unsafe identity not published'
reset_fixture
global_value user.name Direct
global_value include.path "$HOME/missing"
assert_status 'direct plus include publishes empty snapshot' 1 discover_git
[[ ! -s config/generated/git.conf ]] && pass 'include prevents flattening' || fail 'include prevents flattening'
reset_fixture
global_value include.path "$HOME/missing"
assert_status 'include-only source publishes empty snapshot' 1 discover_git
[[ ! -s config/generated/git.conf ]] && pass 'include-only stays unmanaged' || fail 'include-only stays unmanaged'
reset_fixture
global_value user.name Good
assert_status 'valid snapshot seeded' 0 discover_git
before="$(cksum config/generated/git.conf)"
printf '[broken\n' > "$HOME/.gitconfig"
assert_status 'fatal source parse error' 2 discover_git
[[ "$(cksum config/generated/git.conf)" == "$before" ]] &&
pass 'fatal observation preserves prior snapshot' || fail 'fatal observation preserves prior snapshot'

# Check, Preview, Apply, Verify, conflict and idempotence.
reset_fixture
generated_value user.name Desired
assert_status 'Preview plans missing key' 0 preview_git_configuration
[[ "$MESSAGES" == *'Would set Git setting: user.name'* && ! -e "$HOME/.gitconfig" ]] &&
pass 'Preview is non-mutating' || fail 'Preview is non-mutating'
assert_status 'Bootstrap creates missing key' 0 configure_git
assert_global 'created value verified' user.name Desired
[[ "$MODULE_CHANGED" == true ]] && pass 'MODULE_CHANGED after write' || fail 'MODULE_CHANGED after write'
MODULE_CHANGED=false
assert_status 'second Bootstrap no-op' 0 configure_git
[[ "$MODULE_CHANGED" == false ]] && pass 'second run has no write' || fail 'second run has no write'

reset_fixture
generated_value user.name Desired
global_value user.name Existing
assert_status 'different target warns' 1 configure_git
assert_global 'different target preserved' user.name Existing
[[ "$MODULE_CHANGED" == false ]] && pass 'conflict does not mark changed' || fail 'conflict change accounting'
assert_status 'conflict Preview warns' 1 preview_git_configuration
reset_fixture
generated_value user.name Desired
global_value user.name One
"$REAL_GIT" config --global --add user.name Two
assert_status 'target multivar warns' 1 configure_git
[[ "$("$REAL_GIT" config --global --get-all user.name | wc -l | tr -d ' ')" == 2 ]] &&
pass 'target multivar preserved' || fail 'target multivar preserved'

reset_fixture
generated_value user.name Desired
global_value include.path "$HOME/missing"
assert_status 'target include blocks Apply' 1 configure_git
assert_unset 'target include leaves key absent' user.name
reset_fixture
generated_value user.name Desired
global_value pull.ff only
TEST_GIT_MODE=read-failure
assert_status 'observation error blocks Apply' 2 configure_git
assert_unset 'observation error leaves target absent' user.name
reset_fixture
generated_value user.name Desired
TEST_GIT_MODE=write-failure
assert_status 'write error returns 2' 2 configure_git
[[ "$MODULE_CHANGED" == false ]] && pass 'failed write not counted' || fail 'failed write counted'
reset_fixture
generated_value user.name Desired
TEST_GIT_MODE=verify-failure
assert_status 'Verify failure returns 2' 2 configure_git
[[ "$MODULE_CHANGED" == true ]] && pass 'successful write counted despite Verify failure' ||
    fail 'successful write lost after Verify failure'

# XDG topology and direct origins.
reset_fixture
generated_value user.name Desired
mkdir -p "$XDG_CONFIG_HOME/git"
"$REAL_GIT" config --file "$XDG_CONFIG_HOME/git/config" pull.ff only
assert_status 'only XDG target applies' 0 configure_git
[[ ! -e "$HOME/.gitconfig" ]] && pass 'only XDG remains single origin' || fail 'only XDG origin'
assert_global 'XDG value created' user.name Desired
reset_fixture
generated_value user.name Desired
global_value pull.ff only
mkdir -p "$XDG_CONFIG_HOME/git"
"$REAL_GIT" config --file "$XDG_CONFIG_HOME/git/config" user.email xdg@example.invalid
assert_status 'both files, selected key absent' 0 configure_git
[[ "$("$REAL_GIT" config --file "$HOME/.gitconfig" --get user.name)" == Desired ]] &&
pass 'both files use normal dotgitconfig write' || fail 'both files write location'
reset_fixture
generated_value user.name Desired
global_value user.name Desired
mkdir -p "$XDG_CONFIG_HOME/git"
"$REAL_GIT" config --file "$XDG_CONFIG_HOME/git/config" user.name Desired
assert_status 'same key in both origins warns' 1 configure_git
[[ "$MODULE_CHANGED" == false ]] && pass 'ambiguous origin no write' || fail 'ambiguous origin wrote'
reset_fixture
generated_value user.name Desired
assert_status 'no global files target applies' 0 configure_git
[[ -f "$HOME/.gitconfig" ]] && pass 'no-file target creates dotgitconfig' || fail 'no-file target'

# Editor dependency and item selection.
reset_fixture
generated_value core.editor vim
assert_status 'available editor eligible' 0 configure_git
assert_global 'editor created' core.editor vim
reset_fixture
generated_value core.editor 'code --wait'
PATH="$TEST_ROOT/bin:/usr/bin:/bin"
assert_status 'unavailable code dependency warns' 1 configure_git
assert_unset 'unavailable editor not written' core.editor
PATH="$ORIGINAL_PATH"
reset_fixture
generated_value user.name Selected
generated_value pull.ff only
mkdir -p config
blueprint_fixture
printf '[git-configuration]\npull.ff\n' >> config/blueprint.conf
assert_status 'partial Git items apply' 0 configure_git
assert_unset 'unselected identity untouched' user.name
assert_global 'selected pull.ff created' pull.ff only
reset_fixture
generated_value user.name Selected
mkdir -p config
blueprint_fixture
printf '[git-configuration]\n' >> config/blueprint.conf
git_configuration_scope_selected
[[ $? -eq 1 ]] && pass 'explicit empty Git section disables scope' || fail 'explicit empty Git scope'
reset_fixture
generated_value user.name Selected
mkdir -p config
blueprint_fixture
assert_status 'old Blueprint retains all-present behavior' 0 configure_git
assert_global 'old Blueprint applies identity' user.name Selected
reset_fixture
generated_value user.name Selected
mkdir -p config
blueprint_fixture
sed -i '' 's/git-configuration="true"/git-configuration="false"/' config/blueprint.conf
blueprint_category_enabled git-configuration
[[ $? -eq 1 ]] && pass 'disabled Git category skipped by dispatcher' || fail 'disabled Git category'
reset_fixture
generated_value user.name Selected
mkdir -p config
blueprint_fixture
printf '[git-configuration]\npull.ff\n' >> config/blueprint.conf
assert_status 'selected absent key is stale warning' 1 blueprint_validate_selected_items
assert_status 'selected absent key makes no mutation' 0 configure_git
assert_unset 'stale item creates no target value' pull.ff

reset_fixture
generated_value user.useConfigOnly true
assert_status 'useConfigOnly without identity is valid' 0 configure_git
assert_global 'useConfigOnly restored without invented identity' user.useConfigOnly true
assert_unset 'identity still absent' user.email
reset_fixture
generated_value pull.ff only
generated_value pull.rebase true
assert_status 'pull.ff and pull.rebase coexist' 0 configure_git
assert_global 'pull.ff restored' pull.ff only
assert_global 'pull.rebase restored' pull.rebase true

reset_fixture
mkdir -p "$XDG_CONFIG_HOME/git"
"$REAL_GIT" config --file "$XDG_CONFIG_HOME/git/config" user.name XDG
assert_status 'XDG-only source discovered' 0 discover_git
[[ "$("$REAL_GIT" config --file config/generated/git.conf --get user.name)" == XDG ]] &&
pass 'XDG direct source captured' || fail 'XDG direct source captured'
reset_fixture
global_value user.name Dot
mkdir -p "$XDG_CONFIG_HOME/git"
"$REAL_GIT" config --file "$XDG_CONFIG_HOME/git/config" user.name XDG
assert_status 'duplicate source origins warn' 1 discover_git
[[ ! -s config/generated/git.conf ]] &&
pass 'ambiguous source key excluded' || fail 'ambiguous source key excluded'

reset_fixture
generated_value user.name Selected
global_value pull.ff only
GIT_CONFIG_GLOBAL="$TEST_ROOT/other.gitconfig"
assert_status 'global override blocks Apply' 1 configure_git
unset GIT_CONFIG_GLOBAL
assert_unset 'override causes no write' user.name
reset_fixture
generated_value user.name Selected
printf '[user]\n name = Existing\n' > "$TEST_ROOT/foreign.gitconfig"
ln -s "$TEST_ROOT/foreign.gitconfig" "$HOME/.gitconfig"
assert_status 'global symlink blocks Apply' 1 configure_git
[[ "$("$REAL_GIT" config --file "$TEST_ROOT/foreign.gitconfig" --get user.name)" == Existing ]] &&
pass 'symlink destination untouched' || fail 'symlink destination untouched'

# Restore updates selected scalar drift while preserving native origin safety.
BUNDLE_RESTORE_ACTIVE=true
reset_fixture
generated_value user.name Desired
global_value user.name Existing
assert_status 'Restore Preview plans scalar drift' 0 preview_git_configuration
[[ "${GIT_CONFIGURATION_ACTIONS[0]}" == restore ]] && pass 'Restore action is planned' || fail 'Restore action missing'
assert_status 'Restore updates scalar' 0 configure_git
assert_global 'Restore saved scalar applied' user.name Desired
assert_status 'Restore second Preview no-op' 0 preview_git_configuration
[[ "${GIT_CONFIGURATION_ACTIONS[0]}" == skip ]] && pass 'Restore repeat no-op' || fail 'Restore repeated write planned'
reset_fixture
generated_value user.name Desired
global_value pull.ff only
mkdir -p "$XDG_CONFIG_HOME/git"
"$REAL_GIT" config --file "$XDG_CONFIG_HOME/git/config" user.name Existing
assert_status 'Restore updates unique XDG origin with dot file present' 0 configure_git
[[ "$("$REAL_GIT" config --file "$XDG_CONFIG_HOME/git/config" --get user.name)" == Desired ]] && pass 'XDG scalar restored in place' || fail 'XDG scalar not restored'
"$REAL_GIT" config --file "$HOME/.gitconfig" --get user.name >/dev/null && fail 'Restore duplicated scalar into dot file' || pass 'Restore keeps single origin'
reset_fixture
generated_value user.name Desired
global_value user.name Existing
"$REAL_GIT" config --global --add user.name Second
assert_status 'Restore protects multiple values' 1 configure_git
[[ "$MODULE_CHANGED" == false ]] && pass 'Restore multivar no mutation' || fail 'Restore mutated multivar'
reset_fixture
generated_value user.name Desired
global_value include.path "$HOME/missing"
assert_status 'Restore protects includes' 1 configure_git
assert_unset 'Restore include no mutation' user.name
reset_fixture
generated_value user.name Desired
TEST_GIT_MODE=read-failure
global_value pull.ff only
assert_status 'Restore observation error blocks mutation' 2 configure_git
assert_unset 'Restore read failure no mutation' user.name
unset BUNDLE_RESTORE_ACTIVE

if [[ $FAILURES -ne 0 ]]; then
    printf '%s Git test(s) failed\n' "$FAILURES"
    exit 1
fi
echo 'Git generated-state tests passed'
