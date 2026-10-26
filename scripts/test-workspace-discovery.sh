#!/bin/bash

# ==========================================
# Workspace Discovery Safe Snapshot Harness
# ==========================================

set -u

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT INT TERM

TEST_FAILURES=0
VERBOSE=false
SUCCESS_MESSAGES=""
WARNING_MESSAGES=""
ERROR_MESSAGES=""
DETAIL_MESSAGES=""

log() { :; }
action() { :; }
detail() { DETAIL_MESSAGES="${DETAIL_MESSAGES}${DETAIL_MESSAGES:+
}$1"; }
success() {
    SUCCESS_MESSAGES="${SUCCESS_MESSAGES}${SUCCESS_MESSAGES:+
}$1"
}
warning() {
    WARNING_MESSAGES="${WARNING_MESSAGES}${WARNING_MESSAGES:+
}$1"
}
error() {
    ERROR_MESSAGES="${ERROR_MESSAGES}${ERROR_MESSAGES:+
}$1"
}

source "$PROJECT_ROOT/modules/core/common/common.sh"
source "$PROJECT_ROOT/modules/discovery/discovery.sh"
source "$PROJECT_ROOT/modules/discovery/workspace.sh"

# common.sh defines output helpers; replace them with capture helpers.
action() { :; }
detail() { DETAIL_MESSAGES="${DETAIL_MESSAGES}${DETAIL_MESSAGES:+
}$1"; }
success() {
    SUCCESS_MESSAGES="${SUCCESS_MESSAGES}${SUCCESS_MESSAGES:+
}$1"
}
warning() {
    WARNING_MESSAGES="${WARNING_MESSAGES}${WARNING_MESSAGES:+
}$1"
}
error() {
    ERROR_MESSAGES="${ERROR_MESSAGES}${ERROR_MESSAGES:+
}$1"
}

ORIGINAL_SERIALIZE_WORKSPACE="$(declare -f serialize_workspace)"
ORIGINAL_EXPORT_WORKSPACE="$(declare -f export_workspace)"
ORIGINAL_EXPORT_SNAPSHOT="$(declare -f export_workspace_snapshot)"
ORIGINAL_EXPORT_FOLDERS="$(declare -f export_workspace_folders)"
ORIGINAL_EXPORT_REPOSITORIES="$(declare -f export_workspace_repositories)"
ORIGINAL_EXPORT_VSCODE="$(declare -f export_vscode_workspaces)"
ORIGINAL_EXPORT_INVENTORY="$(declare -f export_workspace_inventory)"
ORIGINAL_PUBLISH_MEMBER="$(declare -f workspace_publish_member)"
ORIGINAL_PUBLISH_SNAPSHOT="$(declare -f workspace_publish_snapshot)"
ORIGINAL_GET_REMOTE="$(declare -f get_repository_remote)"
ORIGINAL_GET_BRANCH="$(declare -f get_repository_current_branch)"
ORIGINAL_GET_DEFAULT_BRANCH="$(declare -f get_repository_default_branch)"
ORIGINAL_GET_STATUS="$(declare -f get_repository_status)"

pass() { echo "PASS: $1"; }
fail() {
    echo "FAIL: $1"
    ((TEST_FAILURES++))
}

reset_messages() {
    SUCCESS_MESSAGES=""
    WARNING_MESSAGES=""
    ERROR_MESSAGES=""
    DETAIL_MESSAGES=""
}

reset_functions() {
    eval "$ORIGINAL_SERIALIZE_WORKSPACE"
    eval "$ORIGINAL_EXPORT_WORKSPACE"
    eval "$ORIGINAL_EXPORT_SNAPSHOT"
    eval "$ORIGINAL_EXPORT_FOLDERS"
    eval "$ORIGINAL_EXPORT_REPOSITORIES"
    eval "$ORIGINAL_EXPORT_VSCODE"
    eval "$ORIGINAL_EXPORT_INVENTORY"
    eval "$ORIGINAL_PUBLISH_MEMBER"
    eval "$ORIGINAL_PUBLISH_SNAPSHOT"
    eval "$ORIGINAL_GET_REMOTE"
    eval "$ORIGINAL_GET_BRANCH"
    eval "$ORIGINAL_GET_DEFAULT_BRANCH"
    eval "$ORIGINAL_GET_STATUS"
    unset -f find 2>/dev/null || true
}

reset_case() {
    reset_functions
    reset_messages
    rm -rf "$TEST_ROOT/case"
    mkdir -p "$TEST_ROOT/case/home" "$TEST_ROOT/case/config/generated/workspace"
    HOME="$TEST_ROOT/case/home"
    cd "$TEST_ROOT/case" || exit 1
}

assert_no_snapshot_artifacts() {
    local artifacts
    artifacts="$(command find config/generated/workspace -maxdepth 1 \
        \( -name '.snapshot-stage.*' -o -name '.snapshot-backup.*' -o -name '*.tmp.*' \) \
        -print)"
    [[ -z "$artifacts" ]]
}

write_old_snapshot() {
    local output_dir="config/generated/workspace"
    printf 'old folders\n' > "$output_dir/folders.conf"
    : > "$output_dir/repositories.conf"
    printf 'old workspaces\n' > "$output_dir/vscode-workspaces.conf"
    rm -f "$output_dir/inventory.conf"
}

old_snapshot_preserved() {
    local output_dir="config/generated/workspace"
    [[ "$(cat "$output_dir/folders.conf")" == "old folders" ]] &&
    [[ -f "$output_dir/repositories.conf" && ! -s "$output_dir/repositories.conf" ]] &&
    [[ "$(cat "$output_dir/vscode-workspaces.conf")" == "old workspaces" ]] &&
    [[ ! -e "$output_dir/inventory.conf" ]]
}

prepare_simple_home() {
    PYTHONPATH="$PROJECT_ROOT/scripts" python3 -B - <<'PYFIXTURE'
import os
from pathlib import Path
from workspace_fixture import repository
home = Path(os.environ['HOME'])
repository(home, 'Projects/repo')
(home / 'Desktop').mkdir()
(home / 'Projects/project.code-workspace').write_text('{"folders":[{"path":"repo"}]}')
PYFIXTURE
}

mock_repository_metadata() {
    : # Metadata now comes from native read-only Git fixtures above.
}

write_valid_repository_config() {
    local output_file="$1"

    cat > "$output_file" <<'EOF'
[repository]
NAME="repository"
PATH="/tmp/repository"
REMOTE=""
DEFAULT_BRANCH=""
CURRENT_BRANCH=""
HAS_UNCOMMITTED_CHANGES="false"
HAS_VSCODE_FOLDER="true"
HAS_SETTINGS="false"
HAS_TASKS="true"
HAS_LAUNCH="false"
HAS_EXTENSIONS="true"

EOF
}

# ==========================================
# Successful full snapshot and formats
# ==========================================

reset_case
prepare_simple_home
mock_repository_metadata

discover_workspace >/dev/null
full_status=$?

if [[ $full_status -eq 0 ]] &&
   grep -Fxq 'Desktop|user' config/generated/workspace/folders.conf &&
   grep -Fxq 'Projects|workspace' config/generated/workspace/folders.conf &&
   grep -Fxq 'NAME="repo"' config/generated/workspace/repositories.conf &&
   grep -Fxq 'CURRENT_BRANCH="main"' config/generated/workspace/repositories.conf &&
   grep -Fxq 'PATH="~/Projects/project.code-workspace"' config/generated/workspace/vscode-workspaces.conf &&
   grep -Fxq 'TOTAL_FOLDERS=2' config/generated/workspace/inventory.conf &&
   grep -Fxq 'WORKSPACE_FOLDERS=1' config/generated/workspace/inventory.conf &&
   grep -Fxq 'TOTAL_REPOSITORIES=1' config/generated/workspace/inventory.conf &&
   [[ "$SUCCESS_MESSAGES" == *'Workspace exported'* ]] &&
   [[ "$SUCCESS_MESSAGES" == *'Workspace Discovery completed'* ]] &&
   assert_no_snapshot_artifacts; then
    pass "full Workspace snapshot preserves formats and same-generation inventory"
else
    fail "full Workspace snapshot or generated formats failed"
fi

if grep -Fxq "WORKSPACE_ROOT=\"$HOME\"" config/generated/workspace/workspace.conf &&
   grep -Fxq "WORKSPACE_NAME=\"$(basename "$HOME")\"" config/generated/workspace/workspace.conf &&
   grep -Eq '^SCAN_DATE="[0-9]{4}-[0-9]{2}-[0-9]{2}"$' config/generated/workspace/workspace.conf; then
    pass "workspace.conf populated format remains unchanged"
else
    fail "workspace.conf populated format changed"
fi

private_modes=true
[[ "$(stat -f '%Lp' config/generated/workspace)" == 700 &&
   "$(stat -f '%Lp' config/generated/workspace/workspace.conf)" == 600 ]] ||
    private_modes=false
for snapshot_file in folders.conf repositories.conf vscode-workspaces.conf inventory.conf; do
    [[ "$(stat -f '%Lp' "config/generated/workspace/$snapshot_file")" == 600 ]] ||
        private_modes=false
done
if [[ "$private_modes" == true ]]; then
    pass "Workspace generated directory and published files have private modes"
else
    fail "Workspace generated output is not private"
fi

# ==========================================
# Controller and run_module propagation
# ==========================================

reset_case
export_workspace() { error "injected workspace failure"; return 2; }
export_workspace_snapshot() { return 0; }
# Shared counters consumed by the sourced lifecycle helper.
# shellcheck disable=SC2034
MODULES_CHECKED=0 INSTALLED_COUNT=0 SKIPPED_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0
run_module "Workspace Discovery" discover_workspace >/dev/null
controller_status=$?

if [[ $controller_status -eq 2 && $ERROR_COUNT -eq 1 &&
      "$ERROR_MESSAGES" == *'Workspace Discovery completed with errors'* &&
      "$SUCCESS_MESSAGES" != *'Workspace Discovery completed'* ]]; then
    pass "Workspace controller and run_module propagate status 2 without false completion"
else
    fail "Workspace controller/run_module failure propagation changed"
fi

reset_case
export_workspace() { warning "injected workspace warning"; return 1; }
export_workspace_snapshot() { return 0; }
# Shared counters consumed by the sourced lifecycle helper.
# shellcheck disable=SC2034
MODULES_CHECKED=0 INSTALLED_COUNT=0 SKIPPED_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0
run_module "Workspace Discovery" discover_workspace >/dev/null
controller_status=$?

if [[ $controller_status -eq 1 && $WARNING_COUNT -eq 1 && $ERROR_COUNT -eq 0 &&
      "$WARNING_MESSAGES" == *'Workspace Discovery completed with warnings'* ]]; then
    pass "Workspace controller and run_module preserve warning status 1"
else
    fail "Workspace controller/run_module warning propagation changed"
fi

# ==========================================
# workspace.conf preservation
# ==========================================

reset_case
printf 'previous workspace bytes\n' > config/generated/workspace/workspace.conf
serialize_workspace() { return 2; }
export_workspace >/dev/null
workspace_status=$?

if [[ $workspace_status -eq 2 &&
      "$(cat config/generated/workspace/workspace.conf)" == "previous workspace bytes" &&
      "$SUCCESS_MESSAGES" != *'Workspace exported'* ]] &&
   assert_no_snapshot_artifacts; then
    pass "workspace.conf serialization failure preserves previous state"
else
    fail "workspace.conf serialization failure was destructive or falsely successful"
fi

reset_case
printf 'previous workspace bytes\n' > config/generated/workspace/workspace.conf
discovery_publish_file() { return 2; }
export_workspace >/dev/null
workspace_status=$?

if [[ $workspace_status -eq 2 &&
      "$(cat config/generated/workspace/workspace.conf)" == "previous workspace bytes" &&
      "$SUCCESS_MESSAGES" != *'Workspace exported'* ]]; then
    pass "workspace.conf publication failure preserves previous state"
else
    fail "workspace.conf publication failure semantics changed"
fi

# Restore the real shared helper after the local injection.
unset -f discovery_publish_file
source "$PROJECT_ROOT/modules/discovery/discovery.sh"

# ==========================================
# Folder empty and serialization failure
# ==========================================

reset_case
mock_repository_metadata
export_workspace_snapshot >/dev/null
empty_status=$?

if [[ $empty_status -eq 0 &&
      -f config/generated/workspace/folders.conf &&
      ! -s config/generated/workspace/folders.conf &&
      ! -s config/generated/workspace/repositories.conf &&
      ! -s config/generated/workspace/vscode-workspaces.conf ]] &&
   grep -Fxq 'TOTAL_FOLDERS=0' config/generated/workspace/inventory.conf &&
   grep -Fxq 'TOTAL_REPOSITORIES=0' config/generated/workspace/inventory.conf; then
    pass "legitimate empty Workspace observation publishes a valid empty snapshot"
else
    fail "legitimate empty Workspace observation failed"
fi

reset_case
write_old_snapshot
export_workspace_folders() {
    printf 'partial\n' > "$1"
    error "injected folder serialization failure"
    return 2
}
export_workspace_snapshot >/dev/null
folder_failure_status=$?

if [[ $folder_failure_status -eq 2 ]] && old_snapshot_preserved &&
   [[ "$SUCCESS_MESSAGES" != *'folder(s) exported'* ]] &&
   assert_no_snapshot_artifacts; then
    pass "folder preparation failure preserves the complete previous snapshot"
else
    fail "folder preparation failure damaged the previous snapshot"
fi

reset_case
write_old_snapshot
printf 'TOTAL_REPOSITORIES=9\n' > config/generated/workspace/inventory.conf
export_workspace_repositories() {
    error "injected repository failure"
    return 2
}
export_workspace_snapshot >/dev/null
repository_snapshot_status=$?

if [[ $repository_snapshot_status -eq 2 &&
      "$(cat config/generated/workspace/inventory.conf)" == 'TOTAL_REPOSITORIES=9' &&
      "$SUCCESS_MESSAGES" != *'Workspace inventory generated'* ]] &&
   assert_no_snapshot_artifacts; then
    pass "repository failure cannot publish a false zero-repository inventory"
else
    fail "repository failure replaced the previous inventory"
fi

# Native topology traversal, origins, HEAD, aliases and observation failures are
# covered by WorkspaceDiscoveryTests in test-bootstrap-bundle.py using the same
# production observer. These shell cases retain publication/lifecycle coverage.

# ==========================================
# VS Code Workspace traversal semantics
# ==========================================

reset_case
mkdir -p "$HOME/Projects"
printf 'Projects|workspace\n' > "$TEST_ROOT/case/folders.conf"
export_vscode_workspaces \
    "$TEST_ROOT/case/vscode.conf" "$TEST_ROOT/case/folders.conf" "$TEST_ROOT/case" >/dev/null
vscode_status=$?

if [[ $vscode_status -eq 0 && -f "$TEST_ROOT/case/vscode.conf" && ! -s "$TEST_ROOT/case/vscode.conf" ]]; then
    pass "no VS Code workspace files remains legitimate empty success"
else
    fail "empty VS Code workspace observation failed"
fi

reset_case
mkdir -p "$HOME/Projects"
printf 'Projects|workspace\n' > "$TEST_ROOT/case/folders.conf"
find() {
    printf '%s\n' "$HOME/Projects/partial.code-workspace"
    return 2
}
export_vscode_workspaces \
    "$TEST_ROOT/case/vscode.conf" "$TEST_ROOT/case/folders.conf" "$TEST_ROOT/case" >/dev/null
vscode_status=$?

if [[ $vscode_status -eq 2 && ! -s "$TEST_ROOT/case/vscode.conf" ]]; then
    pass "VS Code traversal failure after partial result does not serialize partial state"
else
    fail "partial VS Code traversal was treated as success"
fi

# ==========================================
# Inventory prerequisite and structure checks
# ==========================================

reset_case
export_workspace_inventory \
    "$TEST_ROOT/case/inventory.conf" "$TEST_ROOT/case/missing-folders" "$TEST_ROOT/case/missing-repositories" >/dev/null
inventory_status=$?

if [[ $inventory_status -eq 2 && ! -e "$TEST_ROOT/case/inventory.conf" ]]; then
    pass "missing inventory prerequisites fail instead of becoming zero counts"
else
    fail "missing inventory prerequisites were accepted"
fi

reset_case
printf 'Broken|unknown\n' > "$TEST_ROOT/case/folders.conf"
: > "$TEST_ROOT/case/repositories.conf"
export_workspace_inventory \
    "$TEST_ROOT/case/inventory.conf" "$TEST_ROOT/case/folders.conf" "$TEST_ROOT/case/repositories.conf" >/dev/null
inventory_status=$?

if [[ $inventory_status -eq 2 && "$ERROR_MESSAGES" == *'Workspace inventory prerequisites are malformed'* ]]; then
    pass "malformed staged folder input blocks inventory generation"
else
    fail "malformed staged inventory input was accepted"
fi

reset_case
printf 'Projects|workspace\n' > "$TEST_ROOT/case/folders.conf"
printf '[broken]\nPATH="missing required fields"\n' > "$TEST_ROOT/case/repositories.conf"
export_workspace_inventory \
    "$TEST_ROOT/case/inventory.conf" "$TEST_ROOT/case/folders.conf" "$TEST_ROOT/case/repositories.conf" >/dev/null
inventory_status=$?

if [[ $inventory_status -eq 2 &&
      "$ERROR_MESSAGES" == *'Workspace inventory prerequisites are malformed'* ]]; then
    pass "malformed staged repository input blocks inventory generation"
else
    fail "malformed staged repository input was accepted"
fi

# ==========================================
# Group publication rollback at every member
# ==========================================

for failure_position in 1 2 3 4; do
    reset_case
    prepare_simple_home
    mock_repository_metadata
    write_old_snapshot
    publish_position=0
    workspace_publish_member() {
        ((publish_position++))
        if [[ $publish_position -eq $failure_position ]]; then
            return 2
        fi
        mv "$1" "$2"
    }

    export_workspace_snapshot >/dev/null
    publication_status=$?

    if [[ $publication_status -eq 2 ]] && old_snapshot_preserved &&
       [[ "$SUCCESS_MESSAGES" != *'folder(s) exported'* ]] &&
       [[ "$SUCCESS_MESSAGES" != *'Workspace inventory generated'* ]] &&
       assert_no_snapshot_artifacts; then
        pass "publication failure at member $failure_position rolls back the complete snapshot"
    else
        fail "publication failure at member $failure_position left a partial snapshot"
    fi
done

# Inspect transient member and rollback-copy modes before publication finishes.
reset_case
prepare_simple_home
mock_repository_metadata
write_old_snapshot
previous_umask="$(umask)"
umask 022
transient_private=true
workspace_publish_member() {
    local staged_dir="${1%/*}" generated_dir="${2%/*}" file backup_dir
    [[ "$(stat -f '%Lp' "$staged_dir")" == 700 ]] || transient_private=false
    for file in "$staged_dir"/*; do
        [[ "$(stat -f '%Lp' "$file")" == 600 ]] || transient_private=false
    done
    for backup_dir in "$generated_dir"/.snapshot-backup.*; do
        [[ "$(stat -f '%Lp' "$backup_dir")" == 700 ]] || transient_private=false
        for file in "$backup_dir"/*; do
            [[ "$(stat -f '%Lp' "$file")" == 600 ]] || transient_private=false
        done
    done
    command mv "$1" "$2"
}
export_workspace_snapshot >/dev/null
private_publication_status=$?
umask "$previous_umask"
if [[ $private_publication_status -eq 0 && "$transient_private" == true ]] &&
   assert_no_snapshot_artifacts; then
    pass "Workspace staging and rollback files remain private under umask 022"
else
    fail "Workspace staging or rollback files had nonprivate modes"
fi

# ==========================================
# Post-publication cleanup warning semantics
# ==========================================

reset_case
output_dir="config/generated/workspace"
staging_dir="$(mktemp -d "$output_dir/.snapshot-stage.XXXXXX")"
for snapshot_file in folders.conf repositories.conf vscode-workspaces.conf inventory.conf; do
    printf 'old %s\n' "$snapshot_file" > "$output_dir/$snapshot_file"
    printf 'new %s\n' "$snapshot_file" > "$staging_dir/$snapshot_file"
done
rm() {
    if [[ "$1" == "-rf" && "$2" == *'/.snapshot-backup.'* && "$3" == *'/.snapshot-stage.'* ]]; then
        return 2
    fi
    command rm "$@"
}

workspace_publish_snapshot "$staging_dir" "$output_dir" >/dev/null
cleanup_publish_status=$?

cleanup_snapshot_is_new=true
for snapshot_file in folders.conf repositories.conf vscode-workspaces.conf inventory.conf; do
    if [[ "$(cat "$output_dir/$snapshot_file")" != "new $snapshot_file" ]]; then
        cleanup_snapshot_is_new=false
    fi
done

if [[ $cleanup_publish_status -eq 1 && "$cleanup_snapshot_is_new" == true &&
      "$WARNING_MESSAGES" == *'Workspace snapshot published, but temporary cleanup failed'* &&
      "$ERROR_MESSAGES" != *'Failed to roll back'* ]]; then
    pass "post-publication cleanup failure returns 1 without rolling back committed state"
else
    fail "post-publication cleanup failure misreported or rolled back committed state"
fi
unset -f rm
command rm -rf "$output_dir"/.snapshot-backup.* "$output_dir"/.snapshot-stage.*

reset_case
prepare_simple_home
mock_repository_metadata
rm() {
    if [[ "$1" == "-rf" && "$2" == *'/.snapshot-backup.'* && "$3" == *'/.snapshot-stage.'* ]]; then
        return 2
    fi
    command rm "$@"
}

export_workspace_snapshot >/dev/null
cleanup_export_status=$?

if [[ $cleanup_export_status -eq 1 &&
      "$WARNING_MESSAGES" == *'Workspace snapshot published, but temporary cleanup failed'* &&
      "$ERROR_MESSAGES" != *'Failed to publish Workspace generated snapshot'* &&
      "$SUCCESS_MESSAGES" == *'2 folder(s) exported'* &&
      "$SUCCESS_MESSAGES" == *'1 repository exported'* &&
      "$SUCCESS_MESSAGES" == *'1 VS Code workspace(s) exported'* &&
      "$SUCCESS_MESSAGES" == *'Workspace inventory generated'* ]]; then
    pass "snapshot exporter preserves cleanup warning and committed-success messages"
else
    fail "snapshot exporter collapsed cleanup warning into publication failure"
fi
unset -f rm
command rm -rf "$output_dir"/.snapshot-backup.* "$output_dir"/.snapshot-stage.*

reset_case
prepare_simple_home
mock_repository_metadata
rm() {
    if [[ "$1" == "-rf" && "$2" == *'/.snapshot-backup.'* && "$3" == *'/.snapshot-stage.'* ]]; then
        return 2
    fi
    command rm "$@"
}
# Shared counters consumed by the sourced lifecycle helper.
# shellcheck disable=SC2034
MODULES_CHECKED=0 INSTALLED_COUNT=0 SKIPPED_COUNT=0
WARNING_COUNT=0
ERROR_COUNT=0

run_module "Workspace Discovery" discover_workspace >/dev/null
cleanup_module_status=$?

if [[ $cleanup_module_status -eq 1 && $WARNING_COUNT -eq 1 && $ERROR_COUNT -eq 0 &&
      "$WARNING_MESSAGES" == *'Workspace snapshot published, but temporary cleanup failed'* &&
      "$WARNING_MESSAGES" == *'Workspace Discovery completed with warnings'* &&
      "$ERROR_MESSAGES" != *'Failed to publish Workspace generated snapshot'* ]]; then
    pass "discover_workspace and run_module preserve post-publication warning status 1"
else
    fail "post-publication warning did not propagate through Workspace lifecycle"
fi
unset -f rm
command rm -rf "$output_dir"/.snapshot-backup.* "$output_dir"/.snapshot-stage.*

# ==========================================
# Repository boolean validation
# ==========================================

reset_case
write_valid_repository_config "$TEST_ROOT/case/repositories.conf"
if workspace_validate_repositories "$TEST_ROOT/case/repositories.conf"; then
    pass "repository validator accepts exact true and false boolean fields"
else
    fail "repository validator rejected valid boolean fields"
fi

boolean_fields=(
    HAS_UNCOMMITTED_CHANGES
    HAS_VSCODE_FOLDER
    HAS_SETTINGS
    HAS_TASKS
    HAS_LAUNCH
    HAS_EXTENSIONS
)

for boolean_field in "${boolean_fields[@]}"; do
    write_valid_repository_config "$TEST_ROOT/case/repositories.conf"
    awk -v key="$boolean_field" '
        index($0, key "=") == 1 { print key "=\"invalid\""; next }
        { print }
    ' "$TEST_ROOT/case/repositories.conf" > "$TEST_ROOT/case/repositories.invalid"
    mv "$TEST_ROOT/case/repositories.invalid" "$TEST_ROOT/case/repositories.conf"

    if ! workspace_validate_repositories "$TEST_ROOT/case/repositories.conf"; then
        pass "repository validator rejects arbitrary quoted $boolean_field"
    else
        fail "repository validator accepted arbitrary quoted $boolean_field"
    fi
done

reset_case
prepare_simple_home
write_old_snapshot
export_workspace_repositories() {
    write_valid_repository_config "$1"
    awk '
        /^HAS_SETTINGS=/ { print "HAS_SETTINGS=\"invalid\""; next }
        { print }
    ' "$1" > "$3/repositories.invalid"
    mv "$3/repositories.invalid" "$1"
    return 0
}
export_workspace_snapshot >/dev/null
malformed_boolean_status=$?

if [[ $malformed_boolean_status -eq 2 ]] && old_snapshot_preserved &&
   [[ "$ERROR_MESSAGES" == *'Failed to prepare Git Repositories snapshot'* ]] &&
   [[ "$SUCCESS_MESSAGES" != *'Workspace inventory generated'* ]] &&
   assert_no_snapshot_artifacts; then
    pass "malformed repository boolean blocks grouped publication and inventory"
else
    fail "malformed repository boolean reached published state or inventory"
fi

reset_case
printf 'Projects|workspace\n' > "$TEST_ROOT/case/folders.conf"
write_valid_repository_config "$TEST_ROOT/case/repositories.conf"
awk '
    /^HAS_TASKS=/ { print "HAS_TASKS=\"invalid\""; next }
    { print }
' "$TEST_ROOT/case/repositories.conf" > "$TEST_ROOT/case/repositories.invalid"
mv "$TEST_ROOT/case/repositories.invalid" "$TEST_ROOT/case/repositories.conf"
export_workspace_inventory \
    "$TEST_ROOT/case/inventory.conf" "$TEST_ROOT/case/folders.conf" "$TEST_ROOT/case/repositories.conf" >/dev/null
malformed_inventory_status=$?

if [[ $malformed_inventory_status -eq 2 && ! -e "$TEST_ROOT/case/inventory.conf" ]]; then
    pass "inventory cannot convert malformed repository booleans into valid counts"
else
    fail "inventory accepted malformed repository boolean state"
fi

# ==========================================
# Final result
# ==========================================

if [[ $TEST_FAILURES -ne 0 ]]; then
    echo
    echo "$TEST_FAILURES Workspace Discovery test(s) failed"
    exit 1
fi

echo
echo "All Workspace Discovery tests passed"
