#!/bin/bash

set -u

# Keep test imports and their subprocesses from polluting project fixtures.
export PYTHONDONTWRITEBYTECODE=1

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
cd "$PROJECT_ROOT" || exit 2

SUITES=(
    scripts/test-application-discovery.sh
    scripts/test-blueprint-bootstrap.sh
    scripts/test-blueprint-selector.sh
    scripts/test-blueprint.sh
    scripts/test-bootstrap-applications.sh
    scripts/test-bootstrap-bundle.py
    scripts/test-bootstrap-startup.sh
    scripts/test-bs-launcher.sh
    scripts/test-bundle-publication-safety.py
    scripts/test-configuration-preview.sh
    scripts/test-core-lifecycle.sh
    scripts/test-capture-api.py
    scripts/test-environment-compare.py
    scripts/test-core-application-interface.py
    scripts/test-discovery-summary.sh
    scripts/test-dry-run-cli.sh
    scripts/test-git-generated-state.sh
    scripts/test-global-verification.sh
    scripts/test-homebrew-discovery.sh
    scripts/test-homebrew-preflight.sh
    scripts/test-macos-bootstrap.sh
    scripts/test-macos-discovery.sh
    scripts/test-preview-applications.sh
    scripts/test-preview-integration.sh
    scripts/test-restore-prerequisites.py
    scripts/test-restore-prepare.py
    scripts/test-restore-selection.py
    scripts/test-secure-restore.py
    scripts/test-shell-zsh.sh
    scripts/test-ssh-generated-state.sh
    scripts/test-ssh-identity-evidence.py
    scripts/test-ssh-identity-migrate.sh
    scripts/test-vscode-settings.sh
    scripts/test-workspace-bootstrap.sh
    scripts/test-workspace-discovery.sh
    scripts/test-workspace-folders.sh
)

usage() {
    printf 'Usage: scripts/test.sh [--shard INDEX/TOTAL] [--list]\n'
}

shard_index=1
shard_total=1
shard_seen=false
list_only=false
while (($#)); do
    case "$1" in
        --shard)
            if [[ "$shard_seen" == true || $# -lt 2 || ! "$2" =~ ^([1-9][0-9]?)/([1-9][0-9]?)$ ]]; then
                usage >&2
                exit 2
            fi
            shard_index="${BASH_REMATCH[1]}"
            shard_total="${BASH_REMATCH[2]}"
            if ((shard_index > shard_total || shard_total > ${#SUITES[@]})); then
                usage >&2
                exit 2
            fi
            shard_seen=true
            shift 2 ;;
        --list) list_only=true; shift ;;
        --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

for suite in "${SUITES[@]}"; do
    if [[ ! -f "$suite" ]]; then
        printf 'Missing required suite: %s\n' "$suite" >&2
        exit 2
    fi
done

# Round-robin selection keeps one canonical inventory and stable suite order.
selected_suites=()
for ((i = 0; i < ${#SUITES[@]}; i++)); do
    if ((i % shard_total == shard_index - 1)); then
        selected_suites+=("${SUITES[i]}")
    fi
done
SUITES=("${selected_suites[@]}")

if [[ "$list_only" == true ]]; then
    printf '%s\n' "${SUITES[@]}"
    exit 0
fi

output_file="$(mktemp)" || exit 2
trap 'rm -f "$output_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for ((i = 0; i < ${#SUITES[@]}; i++)); do
    suite="${SUITES[i]}"
    printf '[%d/%d] %s\n' "$((i + 1))" "${#SUITES[@]}" "$suite"

    case "$suite" in
        *.sh) bash "$suite" >"$output_file" 2>&1 ;;
        *.py) python3 "$suite" >"$output_file" 2>&1 ;;
    esac
    status=$?

    if ((status != 0)); then
        cat "$output_file" >&2
        printf 'FAILED: %s (exit %d)\n' "$suite" "$status" >&2
        exit "$status"
    fi
done

printf 'All %d regression suites passed.\n' "${#SUITES[@]}"
