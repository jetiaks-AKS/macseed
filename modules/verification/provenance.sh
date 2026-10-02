#!/bin/bash

# Domain-level observation of the existing full generated inventory. A digest
# makes a stale marker unknown after any later inventory replacement.
provenance_paths() {
    case "$1" in
        homebrew-casks) PROVENANCE_FILE=brew-casks.conf ;;
        app-store) PROVENANCE_FILE=appstore.conf ;;
        vscode-extensions) PROVENANCE_FILE=vscode-extensions.conf ;;
        *) return 2 ;;
    esac
    PROVENANCE_ROOT="${BLUEPRINT_GENERATED_DIR:-config/generated}"
    PROVENANCE_INVENTORY="$PROVENANCE_ROOT/$PROVENANCE_FILE"
    PROVENANCE_MARKER="$PROVENANCE_ROOT/provenance/$1.sha256"
}

provenance_serialize() {
    printf 'complete %s\n' "$2" > "$1"
}

provenance_publish() {
    provenance_paths "$1" || return 2
    local digest
    digest="$(shasum -a 256 "$PROVENANCE_INVENTORY")" || return 2
    digest="${digest%% *}"
    discovery_publish_file "$PROVENANCE_MARKER" provenance_serialize "$digest"
}

provenance_complete() {
    provenance_paths "$1" || return 1
    [[ -f "$PROVENANCE_MARKER" && ! -L "$PROVENANCE_MARKER" &&
       -f "$PROVENANCE_INVENTORY" && ! -L "$PROVENANCE_INVENTORY" &&
       -r "$PROVENANCE_MARKER" && -r "$PROVENANCE_INVENTORY" ]] || return 1
    local marker actual
    marker="$(cat "$PROVENANCE_MARKER")" || return 1
    [[ "$marker" =~ ^complete\ [0-9a-f]{64}$ ]] || return 1
    actual="$(shasum -a 256 "$PROVENANCE_INVENTORY")" || return 1
    [[ "$marker" == "complete ${actual%% *}" ]]
}
