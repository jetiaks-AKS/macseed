#!/bin/bash

set -u

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
    scripts/test-discovery-summary.sh
    scripts/test-dry-run-cli.sh
    scripts/test-git-generated-state.sh
    scripts/test-homebrew-discovery.sh
    scripts/test-homebrew-preflight.sh
    scripts/test-macos-bootstrap.sh
    scripts/test-macos-discovery.sh
    scripts/test-preview-applications.sh
    scripts/test-preview-integration.sh
    scripts/test-restore-prerequisites.py
    scripts/test-shell-zsh.sh
    scripts/test-ssh-generated-state.sh
    scripts/test-ssh-identity-migrate.sh
    scripts/test-vscode-settings.sh
    scripts/test-workspace-bootstrap.sh
    scripts/test-workspace-discovery.sh
    scripts/test-workspace-folders.sh
)

output_file="$(mktemp)" || exit 2
trap 'rm -f "$output_file"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

for suite in "${SUITES[@]}"; do
    if [[ ! -f "$suite" ]]; then
        printf 'Missing required suite: %s\n' "$suite" >&2
        exit 2
    fi
done

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
