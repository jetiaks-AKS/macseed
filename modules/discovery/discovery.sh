#!/bin/bash

# ==========================================
# Discovery Controller
# ==========================================

source "$(dirname "${BASH_SOURCE[0]}")/../verification/provenance.sh"

discovery_publish_file() {

    local output_file="$1"
    local serializer="$2"
    shift 2

    local output_dir
    local temporary_file

    output_dir="$(dirname "$output_file")" || return 2

    mkdir -p "$output_dir" || return 2

    temporary_file="$(mktemp "${output_file}.tmp.XXXXXX")" || return 2

    if ! "$serializer" "$temporary_file" "$@"; then
        rm -f "$temporary_file"
        return 2
    fi

    if ! mv "$temporary_file" "$output_file"; then
        rm -f "$temporary_file"
        return 2
    fi

    return 0

}

# ==========================================

run_discovery() {

    run_module "Homebrew Discovery" discover_homebrew

    run_module "App Store Discovery" discover_appstore

    run_module "Git Discovery" discover_git

    run_module "SSH Discovery" discover_ssh_configuration

    run_module "VS Code Discovery" discover_vscode

    run_module "Zsh Discovery" discover_zsh

    run_module "macOS Discovery" discover_macos

    run_module "Workspace Discovery" discover_workspace

}
