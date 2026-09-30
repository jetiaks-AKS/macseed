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
REAL_GIT="$(builtin command -v git)"
builtin command mkdir -p "$HOME" "$BLUEPRINT_GENERATED_DIR/workspace" "$BLUEPRINT_GENERATED_DIR/ssh" "$BLUEPRINT_GENERATED_DIR/macos"
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
source modules/discovery/discovery.sh
source modules/bootstrap/workspace/workspace.sh
source modules/settings/macos/macos.sh
source modules/verification/verification.sh
source modules/verification/comparison.sh
log() { :; }
FAILURES=0
CASES=0
BREW_STATE=present
GIT_STATE=normal
CASK_STATE=present
MAS_STATE=present
CODE_STATE=present
DEFAULTS_STATE=match
DEFAULTS_NUMBER=64.0
MUTATIONS="$TEST_ROOT/mutations"
: > "$MUTATIONS"
mutate() { printf '%s\n' "$*" >> "$MUTATIONS"; return 99; }
brew() {
    case "$*" in
        'list --cask')
            case "$CASK_STATE" in absent) return 0 ;; error) return 2 ;; esac
            printf 'example\n'
            [[ "$CASK_STATE" != extra ]] || printf 'additional\n'
            return 0 ;;
        'info --json=v2 --cask example')
            [[ "$CASK_STATE" != metadata-error ]] || return 2
            printf '{"casks":[{"artifacts":[{"target":"%s"}]}]}\n' "$HOME/cask-app"
            return 0 ;;
    esac
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
mas() {
    [[ "$*" == list ]] || { mutate "mas $*"; return 99; }
    case "$MAS_STATE" in present) printf '123 Example (1.0)\n' ;; extra) printf '123 Example (1.0)\n456 Other (2.0)\n' ;; absent) : ;; *) return 2 ;; esac
}
code() {
    [[ "$*" == --list-extensions ]] || { mutate "code $*"; return 99; }
    case "$CODE_STATE" in present) printf 'example.extension\n' ;; extra) printf 'example.extension\nother.extension\n' ;; absent) : ;; *) return 2 ;; esac
}
# Deterministic missing dependencies even on a developer Mac with mas/code.
command() {
    if [[ "${1:-}" == -v ]]; then
        [[ "${2:-}" != mas || "$MAS_STATE" != missing ]] || return 1
        [[ "${2:-}" != code || "$CODE_STATE" != missing ]] || return 1
    fi
    builtin command "$@"
}
defaults() {
    case "${1:-}" in read|read-type) ;; *) mutate "defaults $*"; return 99 ;; esac
    [[ "$DEFAULTS_STATE" != error ]] || return 2
    if [[ "$DEFAULTS_STATE" == missing ]]; then printf 'does not exist\n'; return 1; fi
    if [[ "$1" == read-type ]]; then
        if [[ "$DEFAULTS_STATE" == wrong-type ]]; then printf 'Type is array\n'
        elif [[ "$3" == location ]]; then printf 'Type is string\n'
        elif [[ "$3" == tilesize ]]; then printf 'Type is float\n'
        else printf 'Type is boolean\n'; fi
    elif [[ "$3" == location ]]; then
        if [[ "$DEFAULTS_STATE" == mismatch ]]; then printf '%s/other\n' "$HOME"
        else printf '%s/Screenshots\n' "$HOME"; fi
    elif [[ "$3" == tilesize ]]; then printf '%s\n' "$DEFAULTS_NUMBER"
    elif [[ "$DEFAULTS_STATE" == mismatch ]]; then printf '0\n'
    else printf '1\n'; fi
}
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
# Casks now use the existing production installation predicate.
command mkdir "$HOME/cask-app"
BREW_STATE=present
printf 'example\n' > "$BLUEPRINT_GENERATED_DIR/brew-casks.conf"
sed '/^\[homebrew-casks\]/a\
example
' "$BLUEPRINT_FILE" > "$TEST_ROOT/blueprint-new"
command mv "$TEST_ROOT/blueprint-new" "$BLUEPRINT_FILE"
verification_reset bootstrap
verification_run > "$TEST_ROOT/uncovered-report"
assert record_is example installed verified
assert test "$GV_UNSUPPORTED" -eq 0
assert test ! -s "$MUTATIONS"

# Batch 2 adapters with no Blueprint: generated requirements are the scope.
command rm "$BLUEPRINT_FILE"
for state in present absent error metadata-error; do
    CASK_STATE="$state"
    verification_reset bootstrap
    verify_brew_casks
    case "$state" in present) expected=verified ;; absent) expected=mismatch ;; *) expected=unverified ;; esac
    assert record_is example installed "$expected"
done
CASK_STATE=present
command rmdir "$HOME/cask-app"
verification_reset bootstrap
verify_brew_casks
assert record_is example installed mismatch
command mkdir "$HOME/cask-app"

printf '123|Example\n' > "$BLUEPRINT_GENERATED_DIR/appstore.conf"
printf 'example.extension\n' > "$BLUEPRINT_GENERATED_DIR/vscode-extensions.conf"
for state in present absent missing error; do
    MAS_STATE="$state" CODE_STATE="$state"
    case "$state" in present) expected=verified ;; absent) expected=mismatch ;; *) expected=unverified ;; esac
    verification_reset bootstrap
    verify_appstore_apps
    assert record_is 123 installed "$expected"
    if [[ "$state" == missing ]]; then assert has_code dependency_unavailable; fi
    verification_reset bootstrap
    verify_vscode_extensions
    assert record_is example.extension installed "$expected"
    if [[ "$state" == missing ]]; then assert has_code dependency_unavailable; fi
done
MAS_STATE=present CODE_STATE=present

command mkdir -p "$BLUEPRINT_GENERATED_DIR/shell"
printf '# standalone fixture\n' > "$TEST_ROOT/zsh-payload"
write_zsh_fixture() (
    chmod() { command chmod "$@"; }
    zsh_snapshot_write "$ZSH_SNAPSHOT_FILE" "$@"
)
write_zsh_fixture eligible - "$TEST_ROOT/zsh-payload"
command cp "$TEST_ROOT/zsh-payload" "$HOME/.zshrc"
command chmod 644 "$HOME/.zshrc"
verification_reset bootstrap
verify_zsh
assert record_is .zshrc file_content verified
printf '# different\n' >> "$HOME/.zshrc"
verification_reset bootstrap
verify_zsh
assert record_is .zshrc file_content mismatch
command rm "$HOME/.zshrc"
verification_reset bootstrap
verify_zsh
assert record_is .zshrc file_content mismatch
command ln -s "$TEST_ROOT/zsh-payload" "$HOME/.zshrc"
verification_reset bootstrap
verify_zsh
assert record_is .zshrc file_content unverified
assert has_code observation_failed
command rm "$HOME/.zshrc"
command mkdir "$HOME/.zshrc"
verification_reset bootstrap
verify_zsh
assert record_is .zshrc file_content unverified
command rmdir "$HOME/.zshrc"
write_zsh_fixture excluded external-owner
verification_reset bootstrap
verify_zsh
assert has_code external_management
assert test "${#GV_V[@]}" -eq 0
write_zsh_fixture absent -
verification_reset bootstrap
verify_zsh
assert test "${GV_C[2]}" = no_requirement
assert test "${GV_C[3]}" = observed_absent
assert test "${#GV_V[@]}" -eq 0
write_zsh_fixture eligible - "$TEST_ROOT/zsh-payload"
command cp "$TEST_ROOT/zsh-payload" "$HOME/.zshrc"

settings_dir="$HOME/Library/Application Support/Code/User"
command mkdir -p "$settings_dir" "$BLUEPRINT_GENERATED_DIR/vscode"
printf '{"editor.fontSize":14}\n' > "$BLUEPRINT_GENERATED_DIR/vscode/settings.json"
command cp "$BLUEPRINT_GENERATED_DIR/vscode/settings.json" "$settings_dir/settings.json"
verification_reset bootstrap
verify_vscode_settings
assert record_is settings.json file_content verified
printf '{}\n' > "$settings_dir/settings.json"
verification_reset bootstrap
verify_vscode_settings
assert record_is settings.json file_content mismatch
command rm "$settings_dir/settings.json"
command mkdir "$settings_dir/settings.json"
verification_reset bootstrap
verify_vscode_settings
assert record_is settings.json file_content unverified
assert has_code observation_failed
command rmdir "$settings_dir/settings.json"
command cp "$BLUEPRINT_GENERATED_DIR/vscode/settings.json" "$settings_dir/settings.json"

printf 'Projects|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
verification_reset bootstrap
verify_workspace_folders
assert record_is Projects directory mismatch
command mkdir "$HOME/Projects"
verification_reset bootstrap
verify_workspace_folders
assert record_is Projects directory verified
printf '../escape|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
verification_reset bootstrap
verify_workspace_folders
assert has_code input_invalid
assert test "${#GV_V[@]}" -eq 0
printf 'Projects|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
command rmdir "$HOME/Projects"
printf 'not a directory\n' > "$HOME/Projects"
verification_reset bootstrap
verify_workspace_folders
assert has_code input_invalid
assert test "${#GV_V[@]}" -eq 0
command rm "$HOME/Projects"
command mkdir "$HOME/Projects"

printf 'com.apple.finder|ShowPathbar|bool|true\n' > "$FINDER_CONFIG"
for state in match mismatch missing error wrong-type; do
    DEFAULTS_STATE="$state"
    verification_reset bootstrap
    verify_macos_scalar_category finder "$FINDER_CONFIG"
    case "$state" in match) expected=verified ;; mismatch|missing) expected=mismatch ;; *) expected=unverified ;; esac
    assert record_is com.apple.finder/ShowPathbar stored_preference "$expected"
    if [[ "$expected" == unverified ]]; then assert has_code observation_failed; fi
done
DEFAULTS_STATE=match
printf 'com.apple.dock|tilesize|int|64\n' > "$DOCK_CONFIG"
verification_reset bootstrap
verify_macos_scalar_category dock "$DOCK_CONFIG"
assert record_is com.apple.dock/tilesize stored_preference verified
printf 'com.apple.dock|tilesize|float|64.00\n' > "$DOCK_CONFIG"
verification_reset bootstrap
verify_macos_scalar_category dock "$DOCK_CONFIG"
assert record_is com.apple.dock/tilesize stored_preference verified
DEFAULTS_NUMBER=65.0
verification_reset bootstrap
verify_macos_scalar_category dock "$DOCK_CONFIG"
assert record_is com.apple.dock/tilesize stored_preference mismatch
DEFAULTS_NUMBER=64.0
printf 'NSGlobalDomain|NSCloseAlwaysConfirmsChanges|bool|true\n' > "$WINDOWS_CONFIG"
printf 'NSGlobalDomain|ApplePressAndHoldEnabled|bool|true\n' > "$KEYBOARD_CONFIG"
printf 'com.apple.AppleMultitouchTrackpad|Clicking|bool|true\n' > "$TRACKPAD_CONFIG"
# shellcheck disable=SC2088
printf '%s\n' 'com.apple.screencapture|location|string|~/Screenshots/' > "$SCREENSHOTS_CONFIG"
verification_reset bootstrap
verify_screenshots
assert record_is com.apple.screencapture/location stored_preference verified
assert record_is destination directory mismatch
command mkdir "$HOME/Screenshots"
verification_reset bootstrap
verify_screenshots
assert record_is destination directory verified
DEFAULTS_STATE=error
verification_reset bootstrap
verify_screenshots
assert record_is com.apple.screencapture/location stored_preference unverified
assert record_is destination directory verified
DEFAULTS_STATE=match
command rmdir "$HOME/Screenshots"
command mkdir "$TEST_ROOT/outside"
command ln -s "$TEST_ROOT/outside" "$HOME/Screenshots"
verification_reset bootstrap
verify_screenshots
assert record_is com.apple.screencapture/location stored_preference verified
assert record_is destination directory unverified
assert has_code observation_failed
command rm "$HOME/Screenshots"
command mkdir "$HOME/Screenshots"

# All normal domains together, with independent operation history and secure gap.
find "$HOME" -type f -exec shasum -a 256 {} \; | sort > "$TEST_ROOT/batch2-before"
verification_reset restore
verification_operation app-store 123 install failure
BUNDLE_RESTORE_SECURE_FILE="$TEST_ROOT/opaque-secure.age"
verification_run > "$TEST_ROOT/batch2-report"
assert test "$GV_STATUS" = incomplete
assert test "$GV_TOTAL" -eq 20
assert test "$GV_VERIFIED" -eq 16
assert test "$GV_MISMATCH" -eq 4
assert record_is jq installed mismatch
assert test "$GV_UNVERIFIED" -eq 0
assert test "$GV_UNSUPPORTED" -eq 0
assert test "$GV_UNRESOLVED" -eq 1
assert has_code operation_failed
assert has_code prerequisite_unmet
assert grep -q 'SSH identity evidence is from this Restore importer' "$TEST_ROOT/batch2-report"
find "$HOME" -type f -exec shasum -a 256 {} \; | sort > "$TEST_ROOT/batch2-after"
assert cmp -s "$TEST_ROOT/batch2-before" "$TEST_ROOT/batch2-after"
assert test ! -s "$MUTATIONS"

# Stage 13 verdict and renderer cases use only process-local records.
verification_reset bootstrap
GV_STATUS=complete
verification_coverage demo item resolved observed_present
verification_record demo item installed verified supported now
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'Selected requirements verified'
assert grep -q 'Verdict: Selected requirements verified' "$TEST_ROOT/verdict"
assert test "$(grep -c 'demo / item / installed' "$TEST_ROOT/verdict")" -eq 0
verification_diagnostic run partial_source_coverage warning scope
verification_operation demo item install failure
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'Selected requirements verified'
assert grep -q 'Operation: demo / item / install: failure' "$TEST_ROOT/verdict"
verification_reset bootstrap
GV_STATUS=complete
verification_record demo one installed mismatch supported now
verification_diagnostic "$GV_LAST_REF" confirmed_mismatch warning observation
verification_record demo two installed unverified supported ''
verification_diagnostic "$GV_LAST_REF" observation_failed error observation
verification_operation demo one install success
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'Differences detected'
assert test "$GV_INCOMPLETE_COVERAGE" = true
assert grep -q 'Verification also incomplete' "$TEST_ROOT/verdict"
assert grep -q 'confirmed_mismatch; phase=observation' "$TEST_ROOT/verdict"
assert grep -q 'final differences detected' "$TEST_ROOT/verdict"
verification_reset bootstrap
GV_STATUS=complete
verification_record demo item installed unverified supported ''
verification_diagnostic "$GV_LAST_REF" observation_failed error observation
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'Verification incomplete'
verification_reset bootstrap
GV_STATUS=complete
verification_unsupported demo item installed
verification_coverage demo stale unresolved unknown
verification_diagnostic "$GV_LAST_REF" selected_input_unresolved warning scope
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'Verification incomplete'
assert test "$GV_TOTAL" -eq 1
assert test "$GV_UNVERIFIED" -eq 1
assert test "$GV_UNSUPPORTED" -eq 1
assert test "$GV_UNRESOLVED" -eq 1
assert grep -q 'stale: unresolved selected reference; selected_input_unresolved; phase=scope' "$TEST_ROOT/verdict"
verification_reset bootstrap
GV_STATUS=complete
verification_coverage demo scope no_requirement observed_absent
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'No managed requirements'
verification_reset bootstrap
GV_STATUS=complete
verification_coverage demo scope no_requirement unknown
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'Verification incomplete'
assert grep -q 'provenance: unknown' "$TEST_ROOT/verdict"
verification_reset bootstrap
GV_STATUS=cancelled
verification_record demo item installed mismatch supported now
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'Verification incomplete'
verification_reset workflow
GV_STATUS=complete
verification_coverage demo scope excluded unknown
verification_report > "$TEST_ROOT/verdict"
assert grep -q 'Apply: not run' "$TEST_ROOT/verdict"
verification_reset restore
GV_STATUS=complete
BUNDLE_RESTORE_SECURE_FILE="$TEST_ROOT/opaque-secure.age"
verify_ssh_identity_evidence
verification_report > "$TEST_ROOT/verdict"
assert test "$GV_VERDICT" = 'Verification incomplete'
assert grep -q 'secure-selection: unresolved selected reference' "$TEST_ROOT/verdict"

# Comparison consumes the same transient facts; typed observations never carry values.
CV_KIND=() CV_ACTIVE=true
verification_reset comparison
GV_STATUS=complete
verification_record demo a installed verified supported now
verification_record demo b installed mismatch supported now
comparison_note absent "$GV_LAST_REF"
verification_record demo c installed mismatch supported now
comparison_note different "$GV_LAST_REF"
verification_record demo d installed mismatch supported now
verification_record demo e installed unverified supported ''
verification_unsupported demo f installed
verification_coverage demo stale unresolved unknown
comparison_report > "$TEST_ROOT/comparison"
assert test "$CV_MATCHING" -eq 1
assert test "$CV_MISSING" -eq 1
assert test "$CV_DIFFERING" -eq 1
assert test "$CV_UNVERIFIED" -eq 3
assert test "$CV_UNSUPPORTED" -eq 1
assert test "$CV_UNRESOLVED" -eq 1
assert test "$CV_UNKNOWN_DIFFERENCE" -eq 1
assert test "$CV_VERDICT" = 'Differences detected'
assert test "$CV_ALSO_INCOMPLETE" = true
assert grep -q 'reference_inventory_completeness_unknown' "$TEST_ROOT/comparison"
assert grep -q 'unknown_difference' "$TEST_ROOT/comparison"
CV_KIND=()
verification_reset comparison
GV_STATUS=complete
verification_record demo a installed verified supported now
comparison_report > "$TEST_ROOT/comparison"
assert test "$CV_VERDICT" = 'No differences detected'
CV_KIND=()
verification_reset comparison
GV_STATUS=complete
verification_coverage demo scope excluded unknown
comparison_report > "$TEST_ROOT/comparison"
assert test "$CV_VERDICT" = 'No comparable requirements'
CV_KIND=()
verification_reset comparison
GV_STATUS=complete
verification_coverage demo scope no_requirement unknown
comparison_report > "$TEST_ROOT/comparison"
assert test "$CV_VERDICT" = 'Comparison incomplete'
CV_KIND=()
verification_reset comparison
GV_STATUS=incomplete
verification_record demo a installed mismatch supported now
comparison_note absent "$GV_LAST_REF"
comparison_report > "$TEST_ROOT/comparison"
assert test "$CV_VERDICT" = 'Comparison incomplete'
CV_ACTIVE=false

# Real selected readers retain their classifications and do not expose values.
CV_KIND=() CV_ACTIVE=true
verification_reset comparison
GIT_STATE=normal
printf '[user]\nname = Secret Identity\n' > "$GIT_CONFIGURATION_FILE"
printf '[user]\nname = Other Secret\n' > "$HOME/.gitconfig"
verify_git_configuration
comparison_report > "$TEST_ROOT/comparison"
assert grep -q 'differing: git-configuration / user.name' "$TEST_ROOT/comparison"
assert test "$(grep -Ec 'Secret Identity|Other Secret' "$TEST_ROOT/comparison")" -eq 0
printf '[user]\n' > "$HOME/.gitconfig"
CV_KIND=()
verification_reset comparison
verify_git_configuration
comparison_report > "$TEST_ROOT/comparison"
assert grep -q 'missing: git-configuration / user.name' "$TEST_ROOT/comparison"
CV_ACTIVE=false

# The internal entrypoint uses the full existing pass without target mutations.
BREW_STATE=present
GIT_STATE=normal
DEFAULTS_STATE=match
command rm "$BLUEPRINT_FILE" 2>/dev/null
comparison_run > "$TEST_ROOT/comparison"
assert grep -q 'Environment Comparison' "$TEST_ROOT/comparison"
assert test ! -s "$MUTATIONS"
assert test "$CV_UNSUPPORTED" -eq 0

# Complete inventory markers prove zero and extras without promoting exclusions.
printf 'example\n' > "$BLUEPRINT_GENERATED_DIR/brew-casks.conf"
printf '123|Example\n' > "$BLUEPRINT_GENERATED_DIR/appstore.conf"
printf 'example.extension\n' > "$BLUEPRINT_GENERATED_DIR/vscode-extensions.conf"
command mkdir -p "$BLUEPRINT_GENERATED_DIR/provenance"
for domain in homebrew-casks app-store vscode-extensions; do
    provenance_paths "$domain"
    digest="$(shasum -a 256 "$PROVENANCE_INVENTORY")"
    printf 'complete %s\n' "${digest%% *}" > "$PROVENANCE_MARKER"
done
assert provenance_complete homebrew-casks
CASK_STATE=present MAS_STATE=present CODE_STATE=present
CV_KIND=() CV_ACTIVE=true
verification_reset comparison
GV_STATUS=complete
verification_record demo item installed verified supported now
comparison_report > "$TEST_ROOT/comparison"
assert test "$CV_EXTRA_TOTAL" -eq 0
assert grep -q 'homebrew-casks: 0' "$TEST_ROOT/comparison"
CASK_STATE=extra MAS_STATE=extra CODE_STATE=extra
comparison_report > "$TEST_ROOT/comparison"
assert test "$CV_EXTRA_TOTAL" -eq 3
assert test "$CV_VERDICT" = 'Differences detected'
assert grep -q 'extra: homebrew-casks / additional' "$TEST_ROOT/comparison"
assert grep -q 'extra: app-store / 456' "$TEST_ROOT/comparison"
assert grep -q 'extra: vscode-extensions / other.extension' "$TEST_ROOT/comparison"
assert test "$(grep -Ec 'Example|Other \(' "$TEST_ROOT/comparison")" -eq 0
CASK_STATE=error
comparison_report > "$TEST_ROOT/comparison"
assert grep -q 'homebrew-casks: unavailable' "$TEST_ROOT/comparison"
assert test "$CV_EXTRA_TOTAL" -eq 2
CASK_STATE=present MAS_STATE=present CODE_STATE=present
printf 'tampered\n' > "$BLUEPRINT_GENERATED_DIR/brew-casks.conf"
comparison_report > "$TEST_ROOT/comparison"
assert grep -q 'homebrew-casks: unavailable' "$TEST_ROOT/comparison"
assert test "$CV_VERDICT" = 'No differences detected'

# Full captured inventory is the exclusion baseline, even with a narrow Blueprint.
printf 'example\nadditional\n' > "$BLUEPRINT_GENERATED_DIR/brew-casks.conf"
provenance_paths homebrew-casks
digest="$(shasum -a 256 "$PROVENANCE_INVENTORY")"
printf 'complete %s\n' "${digest%% *}" > "$PROVENANCE_MARKER"
printf '[homebrew-casks]\nexample\n' > "$BLUEPRINT_FILE"
CASK_STATE=extra
comparison_report > "$TEST_ROOT/comparison"
assert grep -q 'homebrew-casks: 0' "$TEST_ROOT/comparison"
assert test "$(grep -c 'extra: homebrew-casks' "$TEST_ROOT/comparison")" -eq 0
command rm "$BLUEPRINT_FILE"

# A complete empty reference inventory is distinct from an unknown empty one.
: > "$BLUEPRINT_GENERATED_DIR/brew-casks.conf"
provenance_paths homebrew-casks
digest="$(shasum -a 256 "$PROVENANCE_INVENTORY")"
printf 'complete %s\n' "${digest%% *}" > "$PROVENANCE_MARKER"
CASK_STATE=present
comparison_report > "$TEST_ROOT/comparison"
assert grep -q 'homebrew-casks: 1' "$TEST_ROOT/comparison"
assert test "$CV_VERDICT" = 'Differences detected'
CV_ACTIVE=false

printf 'Global Verification focused: %s assertions, %s failures\n' "$CASES" "$FAILURES"
[[ "$FAILURES" -eq 0 ]]
