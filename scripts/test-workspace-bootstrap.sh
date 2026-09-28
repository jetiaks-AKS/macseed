#!/bin/bash

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'chmod -R u+rwX "$TEST_ROOT" 2>/dev/null; rm -rf "$TEST_ROOT"' EXIT INT TERM

cd "$PROJECT_ROOT" || exit 1

HOME="$TEST_ROOT/home"
BLUEPRINT_GENERATED_DIR="$TEST_ROOT/generated"
VERBOSE=false
BLUEPRINT_PRESENT=false
SELECTED_FOLDERS=""
SELECTED_REPOSITORIES=""
MUTATION_LOG="$TEST_ROOT/mutations.log"
TEST_FAILURES=0

mkdir -p "$HOME" "$BLUEPRINT_GENERATED_DIR/workspace"
: > "$MUTATION_LOG"

source modules/core/common/common.sh
source modules/core/config/config.sh
source modules/blueprint/blueprint.sh
source modules/discovery/workspace.sh
source modules/bootstrap/workspace/workspace.sh

log() { :; }
section() { :; }
detail() { :; }
info() { :; }
action() { :; }
success() { printf 'SUCCESS:%s\n' "$*"; }
warning() { printf 'WARNING:%s\n' "$*"; }
error() { printf 'ERROR:%s\n' "$*"; }

blueprint_exists() { [[ "$BLUEPRINT_PRESENT" == true ]]; }
blueprint_selected_items() {
    case "$1" in
        workspace-folders) printf '%s\n' "$SELECTED_FOLDERS" ;;
        git-repositories) printf '%s\n' "$SELECTED_REPOSITORIES" ;;
    esac
}
blueprint_item_selected() {
    [[ "$BLUEPRINT_PRESENT" != true ]] && return 0
    case "$1" in
        workspace-folders) grep -Fxq -- "$2" <<< "$SELECTED_FOLDERS" ;;
        git-repositories) grep -Fxq -- "$2" <<< "$SELECTED_REPOSITORIES" ;;
    esac
}
blueprint_generated_file() {
    case "$1" in
        workspace-folders) printf '%s\n' "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf" ;;
        git-repositories) printf '%s\n' "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf" ;;
        *) return 1 ;;
    esac
}

repository_clone() {
    printf 'clone:%s:%s\n' "$1" "$2" >> "$MUTATION_LOG"
    return 0
}
repository_checkout() {
    printf 'checkout:%s:%s\n' "$1" "$2" >> "$MUTATION_LOG"
    return 0
}
repository_verify() {
    repository_clone "$2" "$1"
}
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1" >&2; ((TEST_FAILURES++)); }
expect_status() {
    local expected="$1"
    local actual="$2"
    local label="$3"
    [[ "$actual" -eq "$expected" ]] && pass "$label" || fail "$label (expected $expected, got $actual)"
}
assert_no_mutation() {
    local label="$1"
    if [[ ! -s "$MUTATION_LOG" && ! -d "$HOME/Projects" && ! -d "$HOME/Other" ]]; then
        pass "$label"
    else
        fail "$label"
    fi
}
reset_case() {
    chmod -R u+rwX "$BLUEPRINT_GENERATED_DIR" 2>/dev/null || true
    rm -rf "$HOME/Projects" "$HOME/Other" "$BLUEPRINT_GENERATED_DIR/workspace"
    mkdir -p "$BLUEPRINT_GENERATED_DIR/workspace"
    : > "$MUTATION_LOG"
    BLUEPRINT_PRESENT=false
    SELECTED_FOLDERS=""
    SELECTED_REPOSITORIES=""
    MODULE_CHANGED=false
}
write_valid_folders() {
    printf 'Projects|workspace\nOther|user\n' > \
        "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
}
write_repository_section() {
    local identifier="$1"
    local path="$2"
    cat <<EOF
[$identifier]
NAME="$identifier"
PATH="$path"
REMOTE="git@example.com:$identifier.git"
DEFAULT_BRANCH="main"
CURRENT_BRANCH="main"
HAS_UNCOMMITTED_CHANGES="false"
HAS_VSCODE_FOLDER="false"
HAS_SETTINGS="false"
HAS_TASKS="false"
HAS_LAUNCH="false"
HAS_EXTENSIONS="false"
EOF
}
write_valid_repositories() {
    {
        write_repository_section selected-repository "$HOME/Projects/selected-repository"
        echo
        write_repository_section other-repository "$HOME/Other/other-repository"
    } > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
}

# Valid no-Blueprint input retains all-inclusive behavior.
reset_case
write_valid_folders
write_valid_repositories
output="$(bootstrap_workspace)"; status=$?
expect_status 0 "$status" "valid Workspace generated state continues to work"
if [[ "$output" != *'Restoring VS Code workspace'* &&
      "$output" != *'VS Code workspace restored'* ]]; then
    pass "Workspace Bootstrap emits no false VS Code workspace restoration"
else
    fail "Workspace Bootstrap emitted false VS Code workspace restoration"
fi
if [[ -d "$HOME/Projects" && -d "$HOME/Other" &&
      "$(grep -c '^clone:' "$MUTATION_LOG")" -eq 2 ]]; then
    pass "no-Blueprint Workspace behavior remains all-inclusive"
else
    fail "no-Blueprint Workspace behavior changed"
fi

# Complete folder validation occurs before mkdir.
reset_case
printf 'Projects|invalid\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
write_valid_repositories
output="$(bootstrap_workspace 2>&1)"; status=$?
expect_status 2 "$status" "malformed folder record returns 2"
assert_no_mutation "malformed folder input causes zero Workspace mutations"
[[ "$output" != *'SUCCESS:Workspace Bootstrap completed'* ]] || fail "malformed folders emitted false Workspace success"
pass "malformed folder input emits no Workspace completion success"

reset_case
write_valid_repositories
output="$(bootstrap_workspace 2>&1)"; status=$?
expect_status 2 "$status" "missing required folder input returns 2"
assert_no_mutation "missing folder input fails before mutation"

reset_case
write_valid_folders
write_valid_repositories
chmod 000 "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
output="$(bootstrap_workspace 2>&1)"; status=$?
chmod 600 "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
expect_status 2 "$status" "unreadable required folder input returns 2"
assert_no_mutation "unreadable folder input fails before mutation"

# Complete repository validation occurs before earlier folder creation.
reset_case
write_valid_folders
printf '[broken]\nPATH="%s"\n' "$HOME/Projects/broken" > \
    "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
output="$(bootstrap_workspace 2>&1)"; status=$?
expect_status 2 "$status" "malformed repository record returns 2"
assert_no_mutation "malformed repository input blocks mkdir, clone, and checkout"
[[ "$output" != *'SUCCESS:Workspace Bootstrap completed'* ]] || fail "malformed repositories emitted false Workspace success"
pass "malformed repository input emits no Workspace completion success"

reset_case
write_valid_folders
write_valid_repositories
sed 's/HAS_SETTINGS="false"/HAS_SETTINGS="invalid"/' \
    "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf" > "$TEST_ROOT/repositories.invalid"
mv "$TEST_ROOT/repositories.invalid" "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 2 "$status" "invalid repository boolean is rejected"
assert_no_mutation "invalid repository boolean causes zero Workspace mutations"

reset_case
write_valid_folders
{
    write_repository_section duplicate "$HOME/Projects/one"
    echo
    write_repository_section duplicate "$HOME/Projects/two"
} > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 2 "$status" "duplicate repository identifier is rejected"
assert_no_mutation "duplicate repository identifier causes zero Workspace mutations"

reset_case
write_valid_folders
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 2 "$status" "missing required repository input returns 2"
assert_no_mutation "missing repository input fails before folder mutation"

reset_case
write_valid_folders
write_valid_repositories
chmod 000 "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
bootstrap_workspace >/dev/null 2>&1; status=$?
chmod 600 "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
expect_status 2 "$status" "unreadable required repository input returns 2"
assert_no_mutation "unreadable repository input fails before folder mutation"

# Blueprint selections determine which inputs are required, not how they are parsed.
reset_case
write_valid_folders
write_valid_repositories
BLUEPRINT_PRESENT=true
SELECTED_FOLDERS="Projects"
SELECTED_REPOSITORIES="selected-repository"
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 0 "$status" "valid selected Workspace entries continue to work"
if [[ -d "$HOME/Projects" && ! -d "$HOME/Other" &&
      "$(grep -c '^clone:' "$MUTATION_LOG")" -eq 1 &&
      "$(cat "$MUTATION_LOG")" == *selected-repository* ]]; then
    pass "Blueprint Workspace filtering remains unchanged"
else
    fail "Blueprint Workspace filtering changed"
fi

reset_case
BLUEPRINT_PRESENT=true
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 0 "$status" "empty Blueprint Workspace selections preserve skip behavior"
assert_no_mutation "empty Blueprint Workspace selections do not validate or mutate"

# Actionability failures must stop all Workspace mutations, including late rows.
for bad_folder in '../outside' 'Projects/../../outside' '/outside' 'Projects|extra' $'Bad\tFolder'; do
    reset_case
    write_valid_repositories
    printf 'Projects|workspace\n%s|workspace' "$bad_folder" > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
    bootstrap_workspace >/dev/null 2>&1; status=$?
    expect_status 2 "$status" "reject late unsafe folder: $bad_folder"
    assert_no_mutation 'late unsafe folder blocks all mutations'
done
reset_case
write_valid_repositories
printf 'Projects/Nested Folder|workspace' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 0 "$status" 'nested relative folder without final newline is accepted'
[[ -d "$HOME/Projects/Nested Folder" ]] || fail 'nested folder lost spaces or last line'

for invalid_field in 'PATH=""' 'REMOTE=""' 'CURRENT_BRANCH=""' 'CURRENT_BRANCH="--force"' 'CURRENT_BRANCH="bad..branch"' 'CURRENT_BRANCH="HEAD"' 'CURRENT_BRANCH="@{-1}"' 'REMOTE="-upload-pack"' 'REMOTE="https://"' 'NAME=""' "PATH=\"$HOME/../outside\"" $'REMOTE="bad\tremote"'; do
    reset_case
    write_valid_folders
    {
        write_repository_section good "$HOME/Projects/good"
        write_repository_section bad "$HOME/Other/bad" | awk -v replacement="$invalid_field" '
            BEGIN { split(replacement, fields, "=") }
            index($0, fields[1] "=") == 1 { print replacement; next }
            { print }
        '
    } > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
    bootstrap_workspace >/dev/null 2>&1; status=$?
    expect_status 2 "$status" "reject late invalid repository field: $invalid_field"
    assert_no_mutation 'late invalid repository blocks folders and clone/checkout'
done

reset_case
write_valid_folders
write_repository_section 'repository with spaces' "$HOME/Projects/repository with spaces" > "$TEST_ROOT/spaced"
printf '%s' "$(cat "$TEST_ROOT/spaced")" > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
BLUEPRINT_PRESENT=true
SELECTED_FOLDERS=Projects
SELECTED_REPOSITORIES='repository with spaces'
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 0 "$status" 'selected repository ID with spaces and no final newline'
[[ "$(grep -c '^clone:' "$MUTATION_LOG")" == 1 && "$(cat "$MUTATION_LOG")" == *'/repository with spaces'* ]] || fail 'repository text was split'

reset_case
write_valid_folders
write_valid_repositories
# Duplicate fields are malformed even when every required field is present.
printf 'PATH="%s"\n' "$HOME/Other/duplicate" >> "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 2 "$status" 'extra repository field rejected'
assert_no_mutation 'extra field blocks mutation'

reset_case
command mkdir -p "$TEST_ROOT/outside"
ln -s "$TEST_ROOT/outside" "$HOME/Projects"
write_valid_folders
write_valid_repositories
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 2 "$status" 'symlink escaping HOME rejected before Apply'
[[ ! -s "$MUTATION_LOG" ]] || fail 'escaping symlink reached repository mutation'

reset_case
BLUEPRINT_PRESENT=true
SELECTED_FOLDERS=Projects
write_valid_folders
printf 'malformed unrelated repositories' > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 0 "$status" 'disabled repository scope ignores unrelated malformed input'

reset_case
BLUEPRINT_PRESENT=true
SELECTED_FOLDERS=Projects
printf 'Projects|workspace\n../unselected|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 0 "$status" 'unselected folder actionability does not expand selected scope'

for supported_remote in 'git@example.com:team/repo.git' 'ssh://git@example.com/team/repo.git' 'https://example.com/team/repo.git' '/local/source repo.git'; do
    reset_case
    write_valid_folders
    write_repository_section example "$HOME/Projects/example" | awk -v remote="$supported_remote" '
        /^REMOTE=/ { print "REMOTE=\"" remote "\""; next }
        { print }
    ' > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
    bootstrap_workspace >/dev/null 2>&1; status=$?
    expect_status 0 "$status" "supported remote syntax: $supported_remote"
done

# Existing run_module lifecycle records validation error 2 permanently.
reset_case
write_valid_folders
printf '[broken]\n' > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
WARNING_COUNT=0
ERROR_COUNT=0
MODULES_CHECKED=0
run_module "Workspace" bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 2 "$status" "Workspace validation failure reaches run_module"
[[ "$ERROR_COUNT" -eq 1 ]] && pass "run_module records Workspace validation error" || fail "run_module lost Workspace validation error"
later_success() { return 0; }
run_module "Later Success" later_success >/dev/null 2>&1
toolkit_exit_code; status=$?
expect_status 2 "$status" "later success cannot erase Workspace validation error"
assert_no_mutation "Workspace lifecycle failure performs zero mutations"

# W2 exercises production observation and restore decisions, mocking only Git.
source modules/bootstrap/workspace/repositories-helpers.sh
git() {
    if [[ "$1" == check-ref-format ]]; then command git "$@"; return $?; fi
    if [[ "$1" == clone ]]; then
        printf 'clone:%s\n' "$3" >> "$MUTATION_LOG"
        [[ "$CLONE_STATUS" -eq 0 ]] || return "$CLONE_STATUS"
        if [[ "$CLONE_CREATES_REPOSITORY" == true ]]; then
            mkdir -p "$3/.git"
        fi
        OBSERVED_REMOTE="$CLONE_OBSERVED_REMOTE"
        [[ "$CLONE_VERIFY_MODE" == normal ]] || OBSERVATION_MODE="$CLONE_VERIFY_MODE"
        return 0
    fi
    local repo_path="$2"
    shift 2
    case "$1" in
        rev-parse) [[ "$OBSERVATION_MODE" != worktree-error ]] || return 128; echo true ;;
        remote)
            [[ "$OBSERVATION_MODE" != remote-error ]] || return 128
            if [[ "$repo_path" == */second ]]; then echo git@example.com:second.git; else echo "$OBSERVED_REMOTE"; fi
            ;;
        branch)
            [[ "$OBSERVATION_MODE" != branch-error && "$repo_path" != "$FAIL_BRANCH_PATH" ]] || return 128
            echo "$OBSERVED_BRANCH"
            ;;
        diff)
            if [[ "$*" == 'diff --cached --quiet' ]]; then return "$INDEX_STATUS"; fi
            return "$WORKTREE_STATUS"
            ;;
        checkout)
            printf 'checkout:%s:%s\n' "$repo_path" "$2" >> "$MUTATION_LOG"
            [[ "$CHECKOUT_STATUS" -eq 0 ]] || return "$CHECKOUT_STATUS"
            [[ "$CHECKOUT_UPDATES_BRANCH" != true ]] || OBSERVED_BRANCH="$2"
            [[ "$CHECKOUT_VERIFY_MODE" == normal ]] || OBSERVATION_MODE="$CHECKOUT_VERIFY_MODE"
            ;;
        *) return 128 ;;
    esac
}
reset_observation() {
    reset_case
    mkdir -p "$HOME/Projects/example/.git"
    OBSERVATION_MODE=normal
    OBSERVED_REMOTE='git@example.com:example.git'
    OBSERVED_BRANCH=main
    WORKTREE_STATUS=0
    INDEX_STATUS=0
    FAIL_BRANCH_PATH=""
    CLONE_STATUS=0
    CLONE_CREATES_REPOSITORY=true
    CLONE_OBSERVED_REMOTE='git@example.com:example.git'
    CLONE_VERIFY_MODE=normal
    CHECKOUT_STATUS=0
    CHECKOUT_UPDATES_BRANCH=true
    CHECKOUT_VERIFY_MODE=normal
}
for scenario in clean worktree-file empty-remote dirty staged-error dirty-and-error branch-error detached different remote-error remote-mismatch worktree-error non-git absent; do
    reset_observation
    expected=0
    expected_mutations=0
    case "$scenario" in
        worktree-file) rmdir "$HOME/Projects/example/.git"; printf 'gitdir: /mock/worktree\n' > "$HOME/Projects/example/.git" ;;
        empty-remote) OBSERVED_REMOTE=""; expected=2 ;;
        dirty) OBSERVED_BRANCH=other; WORKTREE_STATUS=1; expected=1 ;;
        staged-error) OBSERVED_BRANCH=other; INDEX_STATUS=128; expected=2 ;;
        dirty-and-error) OBSERVED_BRANCH=other; WORKTREE_STATUS=1; INDEX_STATUS=128; expected=2 ;;
        branch-error|remote-error|worktree-error) OBSERVATION_MODE="$scenario"; expected=2 ;;
        remote-mismatch) OBSERVED_REMOTE=git@example.com:other.git; expected=1 ;;
        different) OBSERVED_BRANCH=other; expected_mutations=1 ;;
        detached) OBSERVED_BRANCH=""; expected_mutations=1 ;;
        non-git) rmdir "$HOME/Projects/example/.git"; expected=1 ;;
        absent) rmdir "$HOME/Projects/example/.git" "$HOME/Projects/example"; expected_mutations=1 ;;
    esac
    repository_verify "$HOME/Projects/example" 'git@example.com:example.git' main > "$TEST_ROOT/observation-output" 2>&1
    status=$?
    expect_status "$expected" "$status" "repository observation: $scenario"
    [[ "$(wc -l < "$MUTATION_LOG" | tr -d ' ')" == "$expected_mutations" ]] || fail "$scenario made an unexpected mutation"
    if [[ "$expected_mutations" == 0 && "$MODULE_CHANGED" != false ]]; then fail "$scenario set Changed"; fi
    if [[ "$scenario" == dirty ]]; then
        [[ "$(cat "$TEST_ROOT/observation-output")" == *'uncommitted changes'* ]] || fail 'dirty state lost warning'
    fi
done

for status_pair in '0 0 0' '1 0 1' '0 1 1' '128 0 2' '1 128 2'; do
    reset_observation
    read -r WORKTREE_STATUS INDEX_STATUS expected <<< "$status_pair"
    repository_is_clean "$HOME/Projects/example"; status=$?
    expect_status "$expected" "$status" "clean-state statuses: $status_pair"
done

reset_observation
chmod 000 "$HOME/Projects/example"
repository_verify "$HOME/Projects/example" 'git@example.com:example.git' main >/dev/null 2>&1; status=$?
chmod 700 "$HOME/Projects/example"
expect_status 2 "$status" 'unreadable destination is an inspection error'
[[ ! -s "$MUTATION_LOG" ]] || fail 'unreadable destination caused mutation'

reset_observation
mkdir -p "$HOME/Projects/second/.git"
{
    write_repository_section example "$HOME/Projects/example"
    write_repository_section second "$HOME/Projects/second"
} > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
FAIL_BRANCH_PATH="$HOME/Projects/second"
bootstrap_workspace_repositories >/dev/null 2>&1; status=$?
expect_status 2 "$status" 'later inspection error propagates as module error 2'
[[ ! -s "$MUTATION_LOG" ]] || fail 'later ambiguous branch caused mutation'
BLUEPRINT_PRESENT=true
SELECTED_REPOSITORIES=example
bootstrap_workspace_repositories >/dev/null 2>&1; status=$?
expect_status 0 "$status" 'Blueprint excludes failing unselected repository'
[[ ! -s "$MUTATION_LOG" ]] || fail 'selected correct repository changed'

# W3 clone and checkout mutations must complete production Verify before success.
for clone_case in success failure missing-destination worktree-error remote-error remote-mismatch; do
    reset_observation
    rmdir "$HOME/Projects/example/.git" "$HOME/Projects/example"
    expected=2
    # Hyphenated values are literal test scenario names.
    # shellcheck disable=SC2100
    case "$clone_case" in
        success) expected=0 ;;
        failure) CLONE_STATUS=128 ;;
        missing-destination) CLONE_CREATES_REPOSITORY=false ;;
        worktree-error) CLONE_VERIFY_MODE=worktree-error ;;
        remote-error) CLONE_VERIFY_MODE=remote-error ;;
        remote-mismatch) CLONE_OBSERVED_REMOTE='git@example.com:wrong.git' ;;
    esac
    repository_verify "$HOME/Projects/example" 'git@example.com:example.git' main > "$TEST_ROOT/mutation-output" 2>&1
    status=$?
    expect_status "$expected" "$status" "clone lifecycle: $clone_case"
    if [[ "$clone_case" == failure ]]; then
        [[ "$MODULE_CHANGED" == false ]] || fail 'failed clone set Changed'
    else
        [[ "$MODULE_CHANGED" == true ]] || fail "$clone_case lost retained clone mutation"
    fi
    if [[ "$expected" == 2 && "$(cat "$TEST_ROOT/mutation-output")" == *'SUCCESS:Repository cloned'* ]]; then
        fail "$clone_case reported clone success before Verify"
    fi
    if [[ "$clone_case" == success ]]; then
        : > "$MUTATION_LOG"
        MODULE_CHANGED=false
        repository_verify "$HOME/Projects/example" 'git@example.com:example.git' main >/dev/null 2>&1; status=$?
        expect_status 0 "$status" 'verified clone rerun succeeds'
        [[ ! -s "$MUTATION_LOG" && "$MODULE_CHANGED" == false ]] || fail 'verified clone rerun mutated'
    fi
done

for checkout_case in success failure verify-mismatch verify-error detached; do
    reset_observation
    OBSERVED_BRANCH=other
    expected=2
    # Hyphenated values are literal test scenario names.
    # shellcheck disable=SC2100
    case "$checkout_case" in
        success) expected=0 ;;
        failure) CHECKOUT_STATUS=128 ;;
        verify-mismatch) CHECKOUT_UPDATES_BRANCH=false ;;
        verify-error) CHECKOUT_VERIFY_MODE=branch-error ;;
        detached) OBSERVED_BRANCH=""; expected=0 ;;
    esac
    repository_verify "$HOME/Projects/example" 'git@example.com:example.git' main > "$TEST_ROOT/mutation-output" 2>&1
    status=$?
    expect_status "$expected" "$status" "checkout lifecycle: $checkout_case"
    if [[ "$checkout_case" == failure ]]; then
        [[ "$MODULE_CHANGED" == false ]] || fail 'failed checkout set Changed'
    else
        [[ "$MODULE_CHANGED" == true ]] || fail "$checkout_case lost retained checkout mutation"
    fi
    if [[ "$expected" == 2 && "$(cat "$TEST_ROOT/mutation-output")" == *'SUCCESS:Branch restored'* ]]; then
        fail "$checkout_case reported branch success before Verify"
    fi
    if [[ "$expected" == 0 ]]; then
        : > "$MUTATION_LOG"
        MODULE_CHANGED=false
        repository_verify "$HOME/Projects/example" 'git@example.com:example.git' main >/dev/null 2>&1; status=$?
        expect_status 0 "$status" "$checkout_case branch rerun succeeds"
        [[ ! -s "$MUTATION_LOG" && "$MODULE_CHANGED" == false ]] || fail "$checkout_case branch rerun mutated"
    fi
done

reset_observation
mkdir -p "$HOME/Projects/second/.git"
OBSERVED_BRANCH=other
CHECKOUT_STATUS=0
repository_verify "$HOME/Projects/example" 'git@example.com:example.git' main >/dev/null 2>&1
[[ "$MODULE_CHANGED" == true ]] || fail 'first successful checkout did not set Changed'
CHECKOUT_STATUS=128
OBSERVED_BRANCH=other
repository_verify "$HOME/Projects/second" 'git@example.com:second.git' main >/dev/null 2>&1; status=$?
expect_status 2 "$status" 'later checkout failure returns 2'
[[ "$MODULE_CHANGED" == true ]] || fail 'later checkout failure cleared earlier Changed'

# W4 exercises the production folder inspector and Apply/Verify lifecycle.
FOLDER_MKDIR_TARGET=""
FOLDER_MKDIR_MODE=normal
mkdir() {
    local target="${!#}"
    if [[ -n "$FOLDER_MKDIR_TARGET" && "$target" == "$FOLDER_MKDIR_TARGET" ]]; then
        printf 'mkdir:%s\n' "$target" >> "$MUTATION_LOG"
        case "$FOLDER_MKDIR_MODE" in
            fail) return 1 ;;
            wrong-type) printf 'not a directory\n' > "$target"; return 0 ;;
        esac
    fi
    command mkdir "$@"
}
reset_folder_lifecycle() {
    reset_case
    FOLDER_MKDIR_TARGET=""
    FOLDER_MKDIR_MODE=normal
    printf 'Projects|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
}

reset_folder_lifecycle
command mkdir -p "$HOME/Projects"
bootstrap_workspace_folders >/dev/null 2>&1; status=$?
expect_status 0 "$status" 'existing folder succeeds'
[[ ! -s "$MUTATION_LOG" && "$MODULE_CHANGED" == false ]] || fail 'existing folder mutated or set Changed'

reset_folder_lifecycle
FOLDER_MKDIR_TARGET="$HOME/Projects"
bootstrap_workspace_folders > "$TEST_ROOT/folder-output" 2>&1; status=$?
expect_status 0 "$status" 'absent folder is created and verified'
[[ -d "$HOME/Projects" && "$MODULE_CHANGED" == true ]] || fail 'created folder was not retained or recorded'
[[ "$(cat "$TEST_ROOT/folder-output")" == *'SUCCESS:Workspace folder created: Projects'* ]] || fail 'verified folder success missing'
: > "$MUTATION_LOG"
MODULE_CHANGED=false
bootstrap_workspace_folders >/dev/null 2>&1; status=$?
expect_status 0 "$status" 'folder rerun is idempotent'
[[ ! -s "$MUTATION_LOG" && "$MODULE_CHANGED" == false ]] || fail 'folder rerun mutated'

for folder_failure in mkdir verify; do
    reset_folder_lifecycle
    FOLDER_MKDIR_TARGET="$HOME/Projects"
    if [[ "$folder_failure" == mkdir ]]; then
        FOLDER_MKDIR_MODE=fail
    else
        FOLDER_MKDIR_MODE=wrong-type
    fi
    bootstrap_workspace_folders > "$TEST_ROOT/folder-output" 2>&1; status=$?
    expect_status 2 "$status" "folder $folder_failure failure returns 2"
    if [[ "$folder_failure" == mkdir ]]; then
        [[ "$MODULE_CHANGED" == false ]] || fail 'failed mkdir set Changed without retained creation'
    else
        [[ "$MODULE_CHANGED" == true ]] || fail 'post-mkdir mismatch lost retained mutation'
    fi
    [[ "$(cat "$TEST_ROOT/folder-output")" != *'SUCCESS:Workspace folder created'* ]] || fail "$folder_failure reported success before Verify"
done

reset_folder_lifecycle
printf 'wrong type\n' > "$HOME/Projects"
bootstrap_workspace_folders >/dev/null 2>&1; status=$?
expect_status 2 "$status" 'wrong-type existing folder path is an error'
[[ ! -s "$MUTATION_LOG" && "$MODULE_CHANGED" == false ]] || fail 'wrong-type path reached Apply'

reset_folder_lifecycle
command mkdir -p "$HOME/Projects"
chmod 000 "$HOME/Projects"
bootstrap_workspace_folders >/dev/null 2>&1; status=$?
chmod 700 "$HOME/Projects"
expect_status 2 "$status" 'folder read/access failure is an observation error'
[[ ! -s "$MUTATION_LOG" && "$MODULE_CHANGED" == false ]] || fail 'folder observation error reached Apply'

reset_folder_lifecycle
printf 'Projects|workspace\nOther|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
FOLDER_MKDIR_TARGET="$HOME/Other"
FOLDER_MKDIR_MODE=fail
bootstrap_workspace_folders >/dev/null 2>&1; status=$?
expect_status 2 "$status" 'later folder failure returns 2'
[[ -d "$HOME/Projects" && "$MODULE_CHANGED" == true ]] || fail 'later folder failure cleared earlier creation'

reset_folder_lifecycle
printf 'Projects|workspace\nOther|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
BLUEPRINT_PRESENT=true
SELECTED_FOLDERS=Projects
FOLDER_MKDIR_TARGET="$HOME/Projects"
bootstrap_workspace_folders >/dev/null 2>&1; status=$?
expect_status 0 "$status" 'Blueprint folder subset succeeds'
[[ -d "$HOME/Projects" && ! -e "$HOME/Other" ]] || fail 'Blueprint folder subset created an unselected folder'

reset_folder_lifecycle
write_valid_repositories
printf 'Projects|workspace\nOther|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
FOLDER_MKDIR_TARGET="$HOME/Other"
FOLDER_MKDIR_MODE=fail
bootstrap_workspace >/dev/null 2>&1; status=$?
expect_status 2 "$status" 'folder lifecycle error propagates through Workspace'
[[ "$MODULE_CHANGED" == true && "$(grep -c '^clone:' "$MUTATION_LOG")" == 0 ]] ||
    fail 'folder error did not retain Changed or allowed repository mutation'

# Workspace Preview reuses the W1-W4 readers and inspection helpers without Apply.
PREVIEW_ACTIONS=""
PREVIEW_WARNINGS=""
PREVIEW_ERRORS=""
action() { PREVIEW_ACTIONS="${PREVIEW_ACTIONS}${PREVIEW_ACTIONS:+|}$*"; }
warning() { PREVIEW_WARNINGS="${PREVIEW_WARNINGS}${PREVIEW_WARNINGS:+|}$*"; }
error() { PREVIEW_ERRORS="${PREVIEW_ERRORS}${PREVIEW_ERRORS:+|}$*"; }
reset_preview_messages() {
    PREVIEW_ACTIONS=""
    PREVIEW_WARNINGS=""
    PREVIEW_ERRORS=""
    : > "$MUTATION_LOG"
    MODULE_CHANGED=preserved
}

reset_folder_lifecycle
command mkdir -p "$HOME/Projects"
reset_preview_messages
preview_workspace_folders; status=$?
expect_status 0 "$status" 'Preview existing folder succeeds'
[[ -z "$PREVIEW_ACTIONS" && "$MODULE_CHANGED" == preserved && ! -s "$MUTATION_LOG" ]] ||
    fail 'Preview existing folder planned or mutated'

reset_folder_lifecycle
FOLDER_MKDIR_TARGET="$HOME/Projects"
reset_preview_messages
preview_workspace_folders; status=$?
expect_status 0 "$status" 'Preview absent folder succeeds'
[[ "$PREVIEW_ACTIONS" == "Would create workspace folder: $HOME/Projects" &&
   ! -e "$HOME/Projects" && "$MODULE_CHANGED" == preserved && ! -s "$MUTATION_LOG" ]] ||
    fail 'Preview absent folder plan or mutation is incorrect'
first_preview="$PREVIEW_ACTIONS"
reset_preview_messages
preview_workspace_folders; status=$?
[[ $status -eq 0 && "$PREVIEW_ACTIONS" == "$first_preview" && ! -s "$MUTATION_LOG" ]] ||
    fail 'repeated folder Preview is unstable or mutating'

reset_folder_lifecycle
printf 'wrong type\n' > "$HOME/Projects"
reset_preview_messages
preview_workspace_folders; status=$?
expect_status 2 "$status" 'Preview wrong-type folder is an observation error'
[[ -z "$PREVIEW_ACTIONS" && ! -s "$MUTATION_LOG" ]] || fail 'wrong-type folder Preview mutated'

reset_folder_lifecycle
command mkdir -p "$HOME/Projects"
chmod 000 "$HOME/Projects"
reset_preview_messages
preview_workspace_folders; status=$?
chmod 700 "$HOME/Projects"
expect_status 2 "$status" 'Preview inaccessible folder is an observation error'
[[ -z "$PREVIEW_ACTIONS" && ! -s "$MUTATION_LOG" ]] || fail 'folder observation error Preview mutated'

for scenario in correct absent different detached dirty remote-mismatch branch-error remote-error worktree-error non-git; do
    reset_observation
    reset_preview_messages
    expected=0
    case "$scenario" in
        absent) rmdir "$HOME/Projects/example/.git" "$HOME/Projects/example" ;;
        different) OBSERVED_BRANCH=other ;;
        detached) OBSERVED_BRANCH="" ;;
        dirty) OBSERVED_BRANCH=other; WORKTREE_STATUS=1; expected=1 ;;
        remote-mismatch) OBSERVED_REMOTE=git@example.com:other.git; expected=1 ;;
        branch-error|remote-error|worktree-error) OBSERVATION_MODE="$scenario"; expected=2 ;;
        non-git) rmdir "$HOME/Projects/example/.git"; expected=1 ;;
    esac
    repository_preview example "$HOME/Projects/example" 'git@example.com:example.git' main
    status=$?
    expect_status "$expected" "$status" "repository Preview: $scenario"
    case "$scenario" in
        absent) [[ "$PREVIEW_ACTIONS" == 'Would clone repository: example' ]] || fail 'absent repository clone plan is incorrect' ;;
        different|detached) [[ "$PREVIEW_ACTIONS" == 'Would switch repository branch: example -> main' ]] || fail "$scenario branch plan is incorrect" ;;
        dirty) [[ -z "$PREVIEW_ACTIONS" && "$PREVIEW_WARNINGS" == *'uncommitted changes'* ]] || fail 'dirty repository policy changed' ;;
        remote-mismatch) [[ -z "$PREVIEW_ACTIONS" && "$PREVIEW_WARNINGS" == *'Remote does not match'* ]] || fail 'remote mismatch policy changed' ;;
        correct) [[ -z "$PREVIEW_ACTIONS" ]] || fail 'correct repository produced a plan' ;;
    esac
    [[ ! -s "$MUTATION_LOG" && "$MODULE_CHANGED" == preserved ]] || fail "$scenario Preview mutated or changed state"
done

reset_observation
mkdir -p "$HOME/Projects/second/.git"
{
    write_repository_section example "$HOME/Projects/example"
    write_repository_section second "$HOME/Projects/second"
} > "$BLUEPRINT_GENERATED_DIR/workspace/repositories.conf"
BLUEPRINT_PRESENT=true
SELECTED_REPOSITORIES=example
FAIL_BRANCH_PATH="$HOME/Projects/second"
reset_preview_messages
preview_workspace_repositories; status=$?
expect_status 0 "$status" 'repository Preview preserves Blueprint subset'
[[ -z "$PREVIEW_ACTIONS" && ! -s "$MUTATION_LOG" ]] || fail 'unselected repository was inspected or mutated'

reset_folder_lifecycle
printf 'Projects|workspace\nOther|workspace\n' > "$BLUEPRINT_GENERATED_DIR/workspace/folders.conf"
BLUEPRINT_PRESENT=true
SELECTED_FOLDERS=Projects
command mkdir -p "$HOME/Projects"
printf 'wrong type\n' > "$HOME/Other"
reset_preview_messages
preview_workspace_folders; status=$?
expect_status 0 "$status" 'folder Preview preserves Blueprint subset'
[[ -z "$PREVIEW_ACTIONS" && ! -s "$MUTATION_LOG" ]] || fail 'unselected folder was inspected or mutated'

echo
if [[ $TEST_FAILURES -eq 0 ]]; then
    echo "All Workspace Bootstrap validation tests passed"
    exit 0
fi

echo "$TEST_FAILURES Workspace Bootstrap validation test(s) failed" >&2
exit 1
