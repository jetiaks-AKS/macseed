#!/bin/bash

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 1
TOOLKIT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)" || exit 1
LAUNCHER="$TOOLKIT_ROOT/bin/bs"

link_points_to_launcher() {
    local link_path="$1"
    local link_target link_directory target_directory hops=0

    [[ -L "$link_path" ]] || return 1
    while [[ -L "$link_path" ]]; do
        ((hops+=1))
        [[ $hops -le 40 ]] || return 1
        link_target="$(readlink "$link_path")" || return 1
        link_directory="$(cd "$(dirname "$link_path")" && pwd -P)" || return 1
        [[ "$link_target" == /* ]] || link_target="$link_directory/$link_target"
        target_directory="$(cd "$(dirname "$link_target")" && pwd -P)" || return 1
        link_path="$target_directory/$(basename "$link_target")"
    done
    [[ "$link_path" == "$LAUNCHER" ]]
}

if [[ ! -x "$LAUNCHER" ]]; then
    printf 'Error: launcher is missing or not executable: %s\n' "$LAUNCHER" >&2
    exit 3
fi

if [[ -n "${BS_INSTALL_DIR:-}" ]]; then
    INSTALL_DIR="$BS_INSTALL_DIR"
elif command -v brew >/dev/null 2>&1; then
    INSTALL_DIR="$(brew --prefix)/bin" || {
        printf 'Error: failed to resolve the Homebrew prefix\n' >&2
        exit 3
    }
elif [[ "$(uname -m)" == arm64 ]]; then
    INSTALL_DIR="/opt/homebrew/bin"
else
    INSTALL_DIR="/usr/local/bin"
fi

INSTALL_PATH="$INSTALL_DIR/bs"
existing_command="$(command -v bs 2>/dev/null || true)"
CHECK_ONLY=false

case "${1:-}" in
    "") ;;
    --check) CHECK_ONLY=true ;;
    *)
        printf 'Error: unsupported installer option: %s\n' "$1" >&2
        exit 2
        ;;
esac

if [[ "$existing_command" == "$LAUNCHER" ]]; then
    [[ "$CHECK_ONLY" == true ]] || printf 'bs is already available at %s\n' "$existing_command"
    exit 0
fi

if [[ -n "$existing_command" ]] && link_points_to_launcher "$existing_command"; then
    [[ "$CHECK_ONLY" == true ]] || printf 'bs is already available at %s\n' "$existing_command"
    exit 0
fi

if [[ -n "$existing_command" && "$existing_command" != "$INSTALL_PATH" ]]; then
    printf 'Error: another bs command already exists at %s\n' "$existing_command" >&2
    exit 2
fi

if [[ -L "$INSTALL_PATH" ]]; then
    if link_points_to_launcher "$INSTALL_PATH"; then
        if [[ "$CHECK_ONLY" == true ]]; then
            exit 1
        fi
        printf 'bs is already installed at %s\n' "$INSTALL_PATH"
        exit 0
    fi
    printf 'Error: refusing to replace existing symlink: %s\n' "$INSTALL_PATH" >&2
    exit 2
fi

if [[ -e "$INSTALL_PATH" ]]; then
    printf 'Error: refusing to replace existing file: %s\n' "$INSTALL_PATH" >&2
    exit 2
fi

if [[ "$CHECK_ONLY" == true ]]; then
    exit 1
fi

if [[ ! -d "$INSTALL_DIR" || ! -w "$INSTALL_DIR" ]]; then
    printf 'Error: install directory is missing or not writable: %s\n' "$INSTALL_DIR" >&2
    exit 1
fi

if ! ln -s "$LAUNCHER" "$INSTALL_PATH"; then
    printf 'Error: failed to install bs at %s\n' "$INSTALL_PATH" >&2
    exit 1
fi

printf 'Installed bs at %s\n' "$INSTALL_PATH"
