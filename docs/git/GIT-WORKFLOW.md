# Git Workflow

This document owns everyday branch and worktree practices for Macseed developers
and AI agents. [Release Process](RELEASE-PROCESS.md) owns version preparation and
publication. Completing a feature does not start a release or declare Macseed 1.0
ready.

## Branch roles

| Branch | Purpose |
|---|---|
| `develop` | Main integration branch for active development; completed features return here after validation. |
| `main` | Stable project history; updated only through separately agreed stabilization or release work, never automatically after a feature checkpoint. |
| `feat/*` | Temporary branches for independent features, optionally developed, validated and committed in separate worktrees; for example, `feat/assisted-appstore-restore`. |
| `archive/*` | Historical experimental or completed work; for example, `archive/mas-automatic-restore-v4`. Never merge an archive wholesale into `develop` or delete it without a separate decision. |

Use `develop` by default. Work on a feature branch only when the task authorizes
it. Before edits, verify the actual directory, branch, HEAD and status against the
task; an editor window or familiar folder name is not evidence. Stop on a mismatch
instead of switching branches automatically. Preserve unrelated local changes.
Git mutations require the authorization described in [AGENTS](../../AGENTS.md#git-process).

## How worktrees relate

Worktrees share one Git history, object database and branch refs. Each has its own
working directory, checked-out HEAD and index. A worktree is not a separate clone.
Different branches can be open simultaneously; Git normally prevents checking out
the same branch in two worktrees.

```text
Shared Git history / objects / refs
  +-- develop worktree: own files and index
  +-- feature worktree: own files and index
  +-- archive worktree: own files and index
```

Uncommitted edits and validation results in one worktree do not automatically apply
to another. Removing a worktree folder through Finder leaves Git registration
behind; finish with `git worktree remove` after the checks below.

## Current local example

**Current development environment — local example, not a required repository layout.**

Snapshot: **21 October 2026**. Reinspect before relying on this state.

| Directory | Branch | Purpose |
|---|---|---|
| `~/Projects/macseed` | `archive/mas-automatic-restore-v4` | Historical worktree; physically holds the shared `.git`. |
| `~/Projects/macseed-develop` | `develop` | Primary permanent development checkout. |
| `~/Projects/macseed-assisted` | `feat/assisted-appstore-restore` | Completed temporary feature worktree awaiting removal. |
| `~/Projects/bootstrap-branch-test` | Unconfirmed | Separate old directory; do not classify without inspection. |

`develop` and the assisted feature branch both point to `0a344696`
(`0a34469636fb20b60ea7aac9d3307a5327665d6c`). The locally recorded `origin/develop`
has not been updated and is seven commits behind; no remote refresh is implied by
this snapshot. `main` was not changed by this feature integration.

The shared Git directory is `~/Projects/macseed/.git`. Removing or moving that
directory without a dedicated migration breaks the other worktrees. An archived
branch does not make its hosting directory disposable.

The archive worktree retains **13 untracked files** outside its Git commit.
Historical materials are also preserved in a private archive outside the
repository. A branch or commit alone does not preserve untracked files; do not
delete them as part of routine worktree cleanup.

## Development sequence

1. Start from an up-to-date `develop` as the agreed integration base.
2. Inspect status and compare the starting branch with that base.
   Remote-tracking refs may be stale; fetching or synchronizing requires
   authorization to update Git state.
3. Create a feature branch/worktree when the task's size warrants isolation and
   that work is authorized.
4. Implement the scoped change and run focused existing checks.
5. Complete the agreed full validation gate before integration. Documentation-only
   work uses diff/link checks; follow [Contributing](../../CONTRIBUTING.md#validation-and-handoff)
   for code validation, including sequential repository and Desktop gates.
6. Make logical commits when authorized, reviewing the diff and staging explicit
   paths; exclude private/generated state, logs and temporary artifacts.
7. Inspect the Git graph and determine whether fast-forward integration is possible.
8. Integrate into the separate `develop` worktree using an authorized safe method;
   prefer fast-forward when the graph permits it.
9. Verify the resulting working tree and history.
10. Update external Launcher or other dependencies to a retained checkout before
    removing a temporary worktree; obtain authorization for those changes.
11. Confirm data preservation and commit integration, then remove the completed
    temporary worktree with Git when authorized.
12. Push only with separate authorization. Feature completion does not update `main`.

Do not require rebase, squash or force push. If fast-forward is impossible, stop
for a separate integration decision rather than rewriting history automatically.

## Command examples

These are examples for an authorized future task, not commands to execute merely
because this document is being read. Replace placeholder paths with inspected
locations. Check each result before the next mutation.

### Inspect the current context

```bash
pwd -P
git status --short --branch
git rev-parse --show-toplevel
git rev-parse HEAD
git worktree list --porcelain
git branch -vv
git rev-parse --git-common-dir
```

### Create a feature worktree

From the inspected, clean and current `develop` checkout, first confirm that the
new branch name is unused. Check that the target path is absent, including a
dangling symlink:

```bash
feature_worktree="../macseed-example-feature"
if [ -e "$feature_worktree" ] || [ -L "$feature_worktree" ]; then
    printf 'Stop: target path already exists: %s\n' "$feature_worktree" >&2
else
    git worktree add -b feat/example-feature "$feature_worktree" develop
fi
```

Inspect the new worktree's branch, HEAD and status before editing there.

### Integrate with fast-forward

Use the existing `develop` worktree; do not try to check out `develop` inside a
feature worktree while it is already checked out elsewhere.

```bash
cd /path/to/develop-worktree
git status --short --branch
git log --graph --oneline --decorate develop feat/example-feature -12
git merge-base --is-ancestor develop feat/example-feature
```

Confirm the branch is `develop`, status is clean, the agreed validation has passed
and the ancestry command returned `0` before an authorized integration:

```bash
git merge --ff-only feat/example-feature
git status --short --branch
git log --graph --oneline --decorate -6
```

A nonzero ancestry result or failed fast-forward requires a separate decision.
Release integration into `main` follows [Release Process](RELEASE-PROCESS.md),
including its release merge policy; the feature fast-forward preference does not
replace it. Run branch-specific release steps in the corresponding worktree when
that branch is already checked out elsewhere.

### Remove a completed worktree

Before using `git worktree remove <path>`, confirm:

- Its tracked and staged state is clean; inspect with
  `git -C "<path>" status --short --untracked-files=all --ignored`.
- There are no unique untracked or ignored files needing preservation, including
  private configuration or local artifacts; preserve them separately first.
- `git merge-base --is-ancestor feat/example-feature develop` returns `0`, proving
  the feature commits are integrated.
- Launcher `bs`, editor tasks and other external dependencies no longer use it.
- It does not host the shared Git directory, and removal is authorized.

From a retained worktree, outside the directory being removed:

```bash
git worktree remove "<path>"
git worktree list --porcelain
git status --short --branch
```

If removal refuses, inspect the cause and preserve data; do not force removal or
delete the directory manually. Removing a worktree does not delete its branch.

## Launcher ownership

`bs` is Macseed's CLI launcher; it delegates to the canonical `bootstrap.sh`
entrypoint. A system symlink can bind it to a particular worktree. After changing
the primary checkout, inspect the actual symlink target and run the existing
ownership check from the intended checkout:

```bash
./scripts/install-bs.sh --check
```

`bs check` performs system preflight and is not a Launcher installation check.
Never remove a checkout while the active Launcher points to it, overwrite another
checkout's symlink by bypassing the installer's protections, or use the archived
Automatic MAS checkout as the active CLI. See [CLI](../toolkit/CLI.md) for usage.

Confirmed in the snapshot above:
`/opt/homebrew/bin/bs` → `~/Projects/macseed-develop/bin/bs`.
The Launcher has already moved and its ownership check passed.

## Automatic MAS archive

`archive/mas-automatic-restore-v4` preserves experimental development evidence.
The active architecture uses Assisted App Store Restore; legacy MASHelper and
automatic installation are outside the current execution path and permanently
retired. Historical materials and experimental untracked files are preserved
separately from active development.

The archive can inform separately scoped future research; it does not authorize
reactivating retired install, helper, authorization or deployment paths, or
automatically merging its architecture into `develop`. See
[Desktop](../DESKTOP.md) for the current App Store contract.
