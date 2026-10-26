#!/bin/bash
source "$(dirname "${BASH_SOURCE[0]}")/../../core/application-interface/observation.sh" || return 2

# ==========================================
# Repository Helpers
# ==========================================

get_repository_remote() {

    local repository_path="$1"
    local remotes

    remotes="$(application_observe local git -C "$repository_path" remote 2>/dev/null)" || return 2

    if ! grep -Fxq origin <<< "$remotes"; then
        return 1
    fi

    application_observe local git -C "$repository_path" remote get-url origin 2>/dev/null || return 2

}

# Remove HTTP(S) URL userinfo before it can reach generated state or logs.
# SSH URL usernames and scp-style usernames are not authentication secrets.
workspace_remote_for_snapshot() {

    local remote="$1" scheme rest authority suffix userinfo host

    if [[ "$remote" != *://* ]]; then
        printf '%s\n' "$remote"
        return 0
    fi

    scheme="${remote%%://*}"
    rest="${remote#*://}"
    authority="${rest%%[/?#]*}"
    suffix="${rest#"$authority"}"

    # Query and fragment data may carry credentials and are not needed for clone.
    [[ -n "$authority" && "$suffix" != *\?* && "$suffix" != *\#* ]] || return 1

    if [[ "$authority" != *@* ]]; then
        printf '%s\n' "$remote"
        return 0
    fi

    userinfo="${authority%@*}"
    host="${authority##*@}"
    [[ -n "$host" ]] || return 1

    case "$scheme" in
        http|https)
            printf '%s://%s%s\n' "$scheme" "$host" "$suffix"
            ;;
        ssh)
            # A single ordinary SSH username is useful and carries no password.
            [[ "$userinfo" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
            printf '%s\n' "$remote"
            ;;
        *) return 1 ;;
    esac

}

get_repository_current_branch() {

    application_observe local git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null

    local result=$?
    [[ $result -eq 1 ]] && return 1
    [[ $result -eq 0 ]] && return 0
    return 2

}

get_repository_default_branch() {

    local repository_path="$1"
    local head_ref

    head_ref="$(application_observe local git -C "$repository_path" symbolic-ref --quiet --short \
        refs/remotes/origin/HEAD 2>/dev/null)"

    local result=$?
    [[ $result -eq 1 ]] && return 1
    [[ $result -eq 0 ]] || return 2

    printf '%s\n' "${head_ref#origin/}"

}

get_repository_status() {

    local status_output

    status_output="$(application_observe local git -C "$1" status --porcelain 2>/dev/null)" || return 2

    if [[ -n "$status_output" ]]; then
        echo "true"
    else
        echo "false"
    fi

}

# ==========================================
# Workspace Repositories Discovery
# ==========================================

export_workspace_repositories() {
    action "Exporting Git Repositories..."
    local working_dir="$3"
    WORKSPACE_REMOTE_WARNING=false
    if ! python3 -B "$WORKSPACE_TOPOLOGY_HELPER" "$working_dir"; then
        error "Failed to prepare Git topology observation"
        return 2
    fi
    if grep -Eq '^[A-Z_]+=[1-9][0-9]*$' "$working_dir/inventory.extra"; then
        warning "Workspace observation contains unsupported metadata or redacted origin userinfo"
        # Shared with the snapshot controller.
        # shellcheck disable=SC2034
        WORKSPACE_REMOTE_WARNING=true
    fi
    return 0
}
