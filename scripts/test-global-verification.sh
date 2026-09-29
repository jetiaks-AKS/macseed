#!/bin/bash
# Production readers on disposable input/target; all verifier mutations forbidden.
set -u
PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT" || exit 2
TEST_ROOT="$(mktemp -d)" || exit 2
trap 'command rm -rf "$TEST_ROOT"' EXIT INT TERM
export HOME="$TEST_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config"
export GIT_CONFIG_NOSYSTEM=1
unset GIT_CONFIG_GLOBAL
BLUEPRINT_GENERATED_DIR="$TEST_ROOT/generated"
BLUEPRINT_FILE="$TEST_ROOT/blueprint.conf"
VERBOSE=false
REAL_GIT="$(command -v git)"
command mkdir -p "$HOME" "$BLUEPRINT_GENERATED_DIR/workspace" "$BLUEPRINT_GENERATED_DIR/ssh" "$BLUEPRINT_GENERATED_DIR/macos"
source modules/core/common/common.sh
source modules/core/config/config.sh
source modules/core/verification/verification.sh
source modules/blueprint/blueprint.sh
source modules/core/git/git.sh
source modules/apps/brew-packages.sh
source modules/apps/brew-casks.sh
source modules/apps/appstore.sh
source modules/vscode/extensions.sh
source modules/vscode/settings.sh
source modules/ssh/config.sh
source modules/shell/zsh.sh
source modules/discovery/workspace.sh
source modules/bootstrap/workspace/workspace.sh
source modules/settings/macos/macos.sh
source modules/verification/verification.sh
log() { :; }
FAILURES=0
CASES=0
BREW_STATE=present
GIT_STATE=normal
MUTATIONS="$TEST_ROOT/mutations"
: > "$MUTATIONS"
mutate() { printf '%s\n' "$*" >> "$MUTATIONS"; return 99; }
brew() {
    if [[ "$*" != 'list --formula --full-name' ]]; then mutate "brew $*"; return 99; fi
    case "$BREW_STATE" in
        present) printf 'git\n' ;;
        absent) : ;;
        error) return 2 ;;
        changed) printf 'git\n'; printf 'jq\n' >> "$BLUEPRINT_GENERATED_DIR/brew-packages.conf" ;;
    esac
}
git() {
    case " $* " in
        *' clone '*|*' checkout '*|*' --add '*|*' --set '*|*' --unset '*) mutate "git $*"; return 99 ;;
    esac
    if [[ "$GIT_STATE" == origin-error && "$*" == *"remote get-url origin"* ]]; then return 2; fi
    if [[ "$GIT_STATE" == error && "$*" == *--show-origin* ]]; then return 2; fi
    "$REAL_GIT" "$@"
}
defaults() { mutate "defaults $*"; }
killall() { mutate "killall $*"; }
sudo() { mutate "sudo $*"; }
repository_clone() { mutate clone; }
repository_checkout() { mutate checkout; }
repository_verify() { mutate repository_verify; }
install_brew_packages() { mutate install; }
bootstrap_ssh_configuration() { mutate ssh-apply; }
configure_git() { mutate git-apply; }
# Initialization and temp cleanup are allowed; target writes are never allowed.
mkdir() { mutate "mkdir $*"; }
cp() { mutate "cp $*"; }
mv() { mutate "mv $*"; }
ln() { mutate "ln $*"; }
chmod() { mutate "chmod $*"; }
assert() {
    CASES=$((CASES+1))
    if "$@"; then printf 'PASS: %s\n' "$*"; else
        printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES+1))
    fi
}
record_is() {
    local subject="$1" predicate="$2" expected="$3" i
    for ((i=0; i<${#GV_V[@]}; i+=6)); do
        if [[ "${GV_V[i+1]}" == "$subject" && "${GV_V[i+2]}" == "$predicate" ]]; then
            [[ "${GV_V[i+3]}" == "$expected" ]]
            return $?
        fi
    done
    return 1
}
has_code() {
    local i
    for ((i=0; i<${#GV_D[@]}; i+=4)); do [[ "${GV_D[i+1]}" != "$1" ]] || return 0; done
    return 1
}
write_blueprint() {
    cat > "$BLUEPRINT_FILE" <<BP
[categories]
git-configuration="true"
ssh-configuration="true"
vscode-settings="false"
shell-zsh="false"
macos-finder="false"
macos-dock="false"
macos-windows="false"
macos-keyboard="false"
macos-trackpad="false"
macos-screenshots="false"
[homebrew-packages]
git
${1:-}
[homebrew-casks]
[app-store]
[vscode-extensions]
[workspace-folders]
[git-repositories]
demo
BP
}
printf 'git\n' > "$BLUEPRINT_GENERATED_DIR/brew-packages.conf"
for state in present absent error; do
    verification_reset bootstrap
    BREW_STATE="$state"
    verify_brew_packages
    case "$state" in present) expected=verified ;; absent) expected=mismatch ;; error) expected=unverified ;; esac
    assert record_is git installed "$expected"
done
BREW_STATE=present
write_blueprint stale
verification_reset bootstrap
verify_brew_packages
verification_aggregate
assert test "$GV_UNRESOLVED" -eq 1
assert test "$GV_TOTAL" -eq 1
assert has_code selected_input_unresolved
command rm "$BLUEPRINT_FILE"

printf '[user]\nname = Example\n' > "$GIT_CONFIGURATION_FILE"
printf '[user]\nname = Example\n' > "$HOME/.gitconfig"
command chmod 400 "$HOME/.gitconfig"
verification_reset bootstrap
verify_git_configuration
assert record_is user.name direct_global_value verified
command chmod 600 "$HOME/.gitconfig"
printf '[user]\nname = Different\n' > "$HOME/.gitconfig"
verification_reset bootstrap
verify_git_configuration
assert record_is user.name direct_global_value mismatch
printf '[user]\nname = Example\nname = Example\n' > "$HOME/.gitconfig"
verification_reset bootstrap
verify_git_configuration
assert record_is user.name direct_global_value mismatch
printf '[include]\npath = elsewhere\n' > "$HOME/.gitconfig"
verification_reset bootstrap
verify_git_configuration
assert record_is user.name direct_global_value unverified
assert has_code external_management
GIT_STATE=error
verification_reset bootstrap
verify_git_configuration
assert record_is user.name direct_global_value unverified
assert has_code observation_failed
GIT_STATE=normal
printf '[user]\nname = Example\n' > "$HOME/.gitconfig"

command mkdir -p "$HOME/.ssh"
command chmod 700 "$HOME/.ssh"
printf 'Host example\n    HostName example.invalid\n\n' > "$HOME/.ssh/config"
command chmod 600 "$HOME/.ssh/config"
# Generate a canonical payload with the same production parser, not Discovery.
ssh_config_parse "$HOME/.ssh/config" "$TEST_ROOT/payload" source >/dev/null
command cp "$TEST_ROOT/payload" "$HOME/.ssh/config"
{ printf '# toolkit-ssh-snapshot: 1\n# status: partial\n# excluded-profiles: 2\n\n'; cat "$TEST_ROOT/payload"; } > "$SSH_SNAPSHOT_FILE"
command chmod 600 "$SSH_SNAPSHOT_FILE"
verification_reset bootstrap
verify_ssh_configuration
assert record_is config supported_config_match verified
assert has_code partial_source_coverage
printf '# different\n' >> "$HOME/.ssh/config"
verification_reset bootstrap
verify_ssh_configuration
assert record_is config supported_config_match mismatch

cat > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf" <<REPO
[demo]
NAME="demo"
PATH="$HOME/demo"
REMOTE="https://example.invalid/desired.git"
CURRENT_BRANCH="main"
DEFAULT_BRANCH="main"
HAS_UNCOMMITTED_CHANGES="false"
HAS_VSCODE_FOLDER="false"
HAS_SETTINGS="false"
HAS_TASKS="false"
HAS_LAUNCH="false"
HAS_EXTENSIONS="false"
REPO
verification_reset bootstrap
verify_workspace_repositories
assert record_is demo worktree mismatch
assert record_is demo origin unverified
assert record_is demo branch unverified
assert has_code prerequisite_unmet
printf 'occupied
' > "$HOME/demo"
verification_reset bootstrap
verify_workspace_repositories
assert record_is demo worktree mismatch
command rm "$HOME/demo"
"$REAL_GIT" init -q "$HOME/demo"
"$REAL_GIT" -C "$HOME/demo" symbolic-ref HEAD refs/heads/main
"$REAL_GIT" -C "$HOME/demo" remote add origin https://example.invalid/wrong.git
verification_reset bootstrap
verify_workspace_repositories
assert record_is demo worktree verified
assert record_is demo origin mismatch
assert record_is demo branch verified
GIT_STATE="origin-error"
verification_reset bootstrap
verify_workspace_repositories
assert record_is demo origin unverified
assert record_is demo branch verified
GIT_STATE=normal
"$REAL_GIT" -C "$HOME/demo" symbolic-ref HEAD refs/heads/other
verification_reset bootstrap
verify_workspace_repositories
assert record_is demo branch mismatch

verification_reset bootstrap
verification_operation homebrew-packages git install failure
verify_brew_packages
assert record_is git installed verified
assert has_code operation_failed
assert test "${GV_O[3]}" = failure

verification_reset bootstrap
verification_coverage future selected resolved unknown
verification_unsupported future selected known_predicate
verification_coverage homebrew-packages stale unresolved unknown
verification_diagnostic "$GV_LAST_REF" selected_input_unresolved warning scope
verification_aggregate
assert test "$GV_TOTAL" -eq 1
assert test "$GV_UNVERIFIED" -eq 1
assert test "$GV_UNSUPPORTED" -eq 1
assert test "$GV_UNRESOLVED" -eq 1

# Exercise hooks on the actual consumer, with a command stub that fails or
# succeeds without installing anything. This is outside the verifier spy run.
formula_operation_case() (
    source modules/apps/brew-packages.sh
    local mode="$1" installed=false result
    brew() {
        if [[ "$1" == install ]]; then
            [[ "$mode" != failure ]] || return 2
            installed=true
            return 0
        fi
        if [[ "$installed" == true ]]; then
            case "$mode" in verified) printf 'git\n' ;; absent) : ;; error) return 2 ;; esac
        fi
    }
    verification_reset bootstrap
    install_brew_packages >/dev/null
    result=$?
    if [[ "$mode" == failure ]]; then
        [[ $result -eq 2 && "${GV_O[3]}" == failure ]] || return 1
        brew() { printf 'git\n'; }
        verify_brew_packages
        record_is git installed verified && has_code operation_failed
    elif [[ "$mode" == verified ]]; then
        [[ $result -eq 0 && "${GV_O[3]}" == success ]]
    else
        [[ $result -eq 2 && "${GV_O[3]}" == success ]] || return 1
        if [[ "$mode" == absent ]]; then has_code confirmed_mismatch; else has_code observation_failed; fi
    fi
)
for mode in failure verified absent error; do assert formula_operation_case "$mode"; done

# Exact target bytes remain unchanged by the full read-only pass.
find "$HOME" -type f -exec shasum -a 256 {} \; | sort > "$TEST_ROOT/before"
write_blueprint
verification_reset workflow
verification_run > "$TEST_ROOT/report"
assert test "$GV_STATUS" = complete
assert test "$GV_ORIGIN" = workflow
BREW_STATE=changed
verification_reset restore
verification_run > "$TEST_ROOT/changed-report"
assert test "$GV_STATUS" = incomplete
assert has_code input_changed
find "$HOME" -type f -exec shasum -a 256 {} \; | sort > "$TEST_ROOT/after"
assert cmp -s "$TEST_ROOT/before" "$TEST_ROOT/after"
assert test ! -s "$MUTATIONS"
# Coverage-only casks never call a cask reader/installer on the target.
BREW_STATE=present
printf 'example\n' > "$BLUEPRINT_GENERATED_DIR/brew-casks.conf"
sed '/^\[homebrew-casks\]/a\
example
' "$BLUEPRINT_FILE" > "$TEST_ROOT/blueprint-new"
command mv "$TEST_ROOT/blueprint-new" "$BLUEPRINT_FILE"
verification_reset bootstrap
verification_run > "$TEST_ROOT/uncovered-report"
assert record_is example installed unverified
assert test "$GV_UNSUPPORTED" -eq 1
assert test ! -s "$MUTATIONS"

printf 'Global Verification focused: %s assertions, %s failures\n' "$CASES" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
