#!/bin/bash

set -u

# Keep test imports and their subprocesses from polluting project fixtures.
export PYTHONDONTWRITEBYTECODE=1

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)" || exit 2
cd "$PROJECT_ROOT" || exit 2

SUITES=(
    scripts/test-test-runner.py
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
    scripts/test-item-stall.py
    scripts/test-external-tools.py
    scripts/test-external-process-reliability.py
    scripts/test-homebrew-capabilities.py
    scripts/test-restore-prepare.py
    scripts/test-restore-selection.py
    scripts/test-secure-restore.py
    scripts/test-shell-zsh.sh
    scripts/test-ssh-generated-state.sh
    scripts/test-ssh-identity-evidence.py
    scripts/test-ssh-identity-migrate.sh
    scripts/test-vscode-settings.sh
    scripts/test-vscode-extensions.py
    scripts/test-workspace-bootstrap.sh
    scripts/test-workspace-discovery.sh
    scripts/test-workspace-folders.sh
    scripts/test-workspace-topology-execute.py
)

# The inventory above is authoritative; weights never select coverage.
exec python3 -B scripts/test_runner.py "${SUITES[@]}" -- "$@"
