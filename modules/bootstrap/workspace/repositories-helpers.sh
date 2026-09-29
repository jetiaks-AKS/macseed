#!/bin/bash

# ==========================================
# Repository Helpers
# ==========================================

# ==========================================
# Repository Exists (0 present, 1 absent, 2 observation error)
# ==========================================

repository_exists() {

    local repository_path="$1"

    local ancestor="$repository_path"
    while [[ ! -e "$ancestor" && ! -L "$ancestor" ]]; do
        ancestor="$(dirname "$ancestor")"
    done
    [[ -d "$ancestor" && -r "$ancestor" && -x "$ancestor" ]] || return 2
    [[ -e "$repository_path" || -L "$repository_path" ]] || return 1
    return 0

}

# ==========================================
# Repository Is Git (0 usable worktree, 1 non-worktree, 2 read error)
# ==========================================

repository_is_git() {

    local repository_path="$1"

    local worktree
    [[ -d "$repository_path" && -r "$repository_path" && -x "$repository_path" ]] || return 2
    # Require a repository rooted here, not an enclosing parent repository.
    [[ -e "$repository_path/.git" || -L "$repository_path/.git" ]] || return 1
    worktree="$(git -C "$repository_path" rev-parse --is-inside-work-tree)" || return 2
    case "$worktree" in
        true) return 0 ;;
        false) return 1 ;;
        *) return 2 ;;
    esac

}

# ==========================================
# Repository Origin
# ==========================================

repository_origin() {

    local repository_path="$1"

    git -C "$repository_path" remote get-url origin || return 2

}

# ==========================================
# Repository Branch
# ==========================================

repository_branch() {

    local repository_path="$1"

    git -C "$repository_path" branch --show-current || return 2

}

# ==========================================
# Clone Repository
# ==========================================

repository_clone() {

    local remote="$1"
    local path="$2"

    git clone "$remote" "$path"

}

# ==========================================
# Repository Is Clean (0 clean, 1 tracked/staged changes, 2 read error)
# ==========================================

repository_is_clean() {

    local repository_path="$1"

    local worktree_result index_result
    git -C "$repository_path" diff --quiet
    worktree_result=$?
    git -C "$repository_path" diff --cached --quiet
    index_result=$?
    [[ $worktree_result -le 1 && $index_result -le 1 ]] || return 2
    [[ $worktree_result -eq 0 && $index_result -eq 0 ]] || return 1
    return 0

}

# ==========================================
# Repository Checkout
# ==========================================

repository_checkout() {

    local repository_path="$1"
    local branch="$2"

    git -C "$repository_path" checkout "$branch" >/dev/null 2>&1

}

# ==========================================
# Preview Repository
# ==========================================

repository_preview() {

    local repository="$1"
    local path="$2"
    local expected_remote="$3"
    local expected_branch="$4"
    local inspection_result
    local current_remote
    local current_branch

    repository_exists "$path"
    inspection_result=$?

    case $inspection_result in
        1)
            preview_action "Would clone repository: $repository"
            return 0
            ;;
        2)
            error "Failed to inspect repository destination"
            return 2
            ;;
    esac

    repository_is_git "$path"
    inspection_result=$?
    if [[ $inspection_result -eq 2 ]]; then
        error "Failed to inspect Git worktree"
        return 2
    fi
    if [[ $inspection_result -eq 1 ]]; then
        warning "Directory is not a Git repository"
        return 1
    fi

    if ! current_remote=$(repository_origin "$path") || [[ -z "$current_remote" ]]; then
        error "Failed to observe repository origin"
        return 2
    fi

    if [[ "$current_remote" != "$expected_remote" ]]; then
        warning "Remote does not match"
        return 1
    fi

    if ! current_branch=$(repository_branch "$path"); then
        error "Failed to observe repository branch"
        return 2
    fi

    [[ "$current_branch" == "$expected_branch" ]] && return 0

    repository_is_clean "$path"
    inspection_result=$?
    if [[ $inspection_result -eq 2 ]]; then
        error "Failed to inspect repository changes"
        return 2
    fi
    if [[ $inspection_result -eq 1 ]]; then
        warning "Branch does not match"
        warning "Repository has uncommitted changes"
        return 1
    fi

    preview_action "Would switch repository branch: $repository -> $expected_branch"
    return 0
}

# ==========================================
# Verify Repository
# ==========================================

repository_verify() {

    local path="$1"
    local expected_remote="$2"
    local expected_branch="$3"

    local repository_subject="${4:-$path}"
    local repository_cloned=false
    local repository_checked_out=false

    local inspection_result
    repository_exists "$path"
    inspection_result=$?
    if [[ $inspection_result -eq 2 ]]; then
        error "Failed to inspect repository destination"
        return 2
    fi

    if [[ $inspection_result -eq 1 ]]; then

        action "Cloning repository..."

        if ! repository_clone "$expected_remote" "$path"; then
            declare -F verification_operation_hook >/dev/null && verification_operation_hook git-repositories "$repository_subject" clone failure
            error "Failed to clone repository"
            return 2
        fi

        MODULE_CHANGED=true
        repository_cloned=true
        declare -F verification_operation_hook >/dev/null && verification_operation_hook git-repositories "$repository_subject" clone success

        repository_exists "$path"
        inspection_result=$?
        if [[ $inspection_result -ne 0 ]]; then
            declare -F verification_post_hook >/dev/null && verification_post_hook "$inspection_result"
            error "Failed to verify cloned repository destination"
            return 2
        fi

    fi

    if [[ "$repository_cloned" == false ]]; then
        success "Repository found"
    fi

    repository_is_git "$path"
    inspection_result=$?
    if [[ $inspection_result -eq 2 ]]; then
        error "Failed to inspect Git worktree"
        return 2
    fi
    if [[ $inspection_result -eq 1 ]]; then
        if [[ "$repository_cloned" == true ]]; then
            declare -F verification_post_hook >/dev/null && verification_post_hook 1
            error "Cloned destination is not a usable Git repository"
            return 2
        fi
        warning "Directory is not a Git repository"
        return 1
    fi

    success "Git repository detected"

    local current_remote

    if ! current_remote=$(repository_origin "$path") || [[ -z "$current_remote" ]]; then
        error "Failed to observe repository origin"
        return 2
    fi

    if [[ "$current_remote" != "$expected_remote" ]]; then
        if [[ "$repository_cloned" == true ]]; then
            declare -F verification_post_hook >/dev/null && verification_post_hook 1
            error "Cloned repository origin verification failed"
            return 2
        fi
        warning "Remote does not match"
        return 1
    fi

    success "Remote verified"

    if [[ "$repository_cloned" == true ]]; then
        success "Repository cloned"
    fi

    local current_branch

    if ! current_branch=$(repository_branch "$path"); then
        error "Failed to observe repository branch"
        return 2
    fi

if [[ "$current_branch" != "$expected_branch" ]]; then

    warning "Branch does not match"

    repository_is_clean "$path"
    inspection_result=$?
    if [[ $inspection_result -eq 2 ]]; then
        error "Failed to inspect repository changes"
        return 2
    fi
    if [[ $inspection_result -eq 1 ]]; then
        warning "Repository has uncommitted changes"
        return 1
    fi

    action "Restoring branch..."

    if ! repository_checkout "$path" "$expected_branch"; then
        declare -F verification_operation_hook >/dev/null && verification_operation_hook git-repositories "$repository_subject" checkout failure
        error "Failed to restore branch"
        return 2
    fi

    # Shared lifecycle flag is read by the calling module wrapper.
    # shellcheck disable=SC2034
    MODULE_CHANGED=true
    repository_checked_out=true
    declare -F verification_operation_hook >/dev/null && verification_operation_hook git-repositories "$repository_subject" checkout success

    if ! current_branch=$(repository_branch "$path"); then
        error "Failed to observe repository branch"
        return 2
    fi

    if [[ "$current_branch" != "$expected_branch" ]]; then
        declare -F verification_post_hook >/dev/null && verification_post_hook 1
        error "Branch verification failed"
        return 2
    fi

    success "Branch restored"

fi

if [[ "$repository_cloned" == false && "$repository_checked_out" == false ]]; then
    declare -F verification_operation_hook >/dev/null && verification_operation_hook git-repositories "$repository_subject" restore noop
fi
success "Branch verified"

return 0

}

# Shared read-only inspection. Results: 0 match, 1 mismatch, 2 observation
# error, 3 dependent predicate not observed. Origin and branch are independent.
# shellcheck disable=SC2034
repository_inspect() {
    local path="$1" expected_remote="$2" expected_branch="$3" result value
    REPOSITORY_WORKTREE_RESULT=2
    REPOSITORY_ORIGIN_RESULT=3
    REPOSITORY_BRANCH_RESULT=3
    if [[ -f "$path" && ! -L "$path" ]]; then
        REPOSITORY_WORKTREE_RESULT=1
        return 0
    fi
    repository_exists "$path"
    result=$?
    if [[ $result -eq 1 ]]; then
        REPOSITORY_WORKTREE_RESULT=1
        return 0
    fi
    [[ $result -eq 0 ]] || return 0
    repository_is_git "$path"
    result=$?
    REPOSITORY_WORKTREE_RESULT=$result
    [[ $result -eq 0 ]] || return 0
    REPOSITORY_ORIGIN_RESULT=2
    if value="$(repository_origin "$path")" && [[ -n "$value" ]]; then
        REPOSITORY_ORIGIN_RESULT=1
        [[ "$value" != "$expected_remote" ]] || REPOSITORY_ORIGIN_RESULT=0
    fi
    REPOSITORY_BRANCH_RESULT=2
    if value="$(repository_branch "$path")"; then
        REPOSITORY_BRANCH_RESULT=1
        [[ "$value" != "$expected_branch" ]] || REPOSITORY_BRANCH_RESULT=0
    fi
    return 0
}
