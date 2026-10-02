# Macseed CLI

The official CLI uses `bootstrap.sh` as its production entrypoint and `bin/bs`
as an optional short launcher. Run `bootstrap.sh` from the repository root;
`bs` resolves that root from any working directory. Desktop does not deprecate it.
Start with the [CLI Quick Start](../getting-started/QUICKSTART.md).

## Commands

| Short command | Repository command | Behavior |
|---|---|---|
| `bs check` | `./bootstrap.sh --check` | Check prerequisites and Core; may request administrator authentication or offer Homebrew installation |
| `bs discover` | `./bootstrap.sh --discover` | Observe supported state and publish local Generated Configuration |
| `bs blueprint` | `./bootstrap.sh --blueprint` | Select from inventory and save private Blueprint |
| `bs preview` | `./bootstrap.sh --dry-run` | Inspect selected changes without applying them |
| `bs bootstrap` | `./bootstrap.sh --bootstrap` | Apply selected supported state and verify results |
| `bs workflow` | `./bootstrap.sh --workflow` | Guided Discovery / selection / Preview / confirmed Apply |
| `bs capture` | `./bootstrap.sh --capture` | Create a private selected `.mbt` Bundle |
| `bs restore <bundle>` | `./bootstrap.sh --restore <bundle>` | Validate, narrow, preview and confirm Bundle restoration |
| `bs compare` | `./bootstrap.sh --compare` | Explicit read-only selected-reference comparison with this Mac |
| `bs help` | `./bootstrap.sh --help` | Show usage |
| — | `./bootstrap.sh --version` | Show current product version |

Use one execution mode per invocation. Missing/conflicting modes return `1`.
Add `--verbose` to `bootstrap.sh` for diagnostic detail; `bs` accepts only its
command and the Restore path, not additional flags. Help and version do not run
workflows.
Check is not read-only; Discovery replaces local generated state. Bootstrap,
Workflow Apply and Restore perform real system/user configuration changes.

## Guided Workflow and selection

Workflow checks local generated state and offers/requires Discovery as needed.
It edits Blueprint, runs Preview, and asks `Apply these changes with Bootstrap?
[y/N]` only when changes are planned. Preview errors stop the flow. Zero-change
Workflow finishes without Bootstrap. Published Bundle state may be partial when
its saved selection excludes missing domains.

Blueprint stores choices, not discovered values. Item selection offers All,
None or Edit with 20-item pages; numbers/ranges toggle choices. `q`/`Q` cancels
at any prompt without saving, and stops Workflow before Preview. Save is atomic.
The selector Summary confirms selected/total items and setting categories.
Format and compatibility belong to [Configuration](CONFIGURATION.md).

## Preview

```text
CLI → logger → Blueprint validation → selected-input validation
→ read-only preflight → Core inspection → domain Preview → Summary → exit
```

Preview does not run `sudo -v`, install Homebrew or execute Bootstrap mutations.
It may write logs and temporary validation files. Plans cover applications, Git,
SSH, VS Code settings, Zsh, Workspace and macOS, including needed process restarts.
Matching and excluded items do not become planned changes.

Startup validation/preflight errors stop the run. After Core/domain inspection
errors, later read-only inspections continue; a helper may stop its remaining
items. Planned changes alone return `0`; warnings return `1`; errors take
precedence with `2`. Malformed Blueprint/required input returns `2`; stale
selection warns. Optional VS Code settings absence retains warning behavior.

Preview counts inspection-wrapper calls, including Core and Blueprint validation
when present, rather than items. It does not use `MODULE_CHANGED` or report installs.
Screenshots plans distinguish directory creation, preference write and restart;
directory-only changes still trigger Workflow confirmation, without a restart.
Domain validation, conflict and path rules belong to Configuration.

## Bootstrap and launcher

Bootstrap validates selected inputs before preflight and uses existing consumers'
Check → Apply → Verify lifecycle. Depending on scope, it installs packages/apps,
writes settings, creates folders or clones/checks repositories. Changed Finder,
Dock and screenshot preferences may restart Finder, Dock or SystemUIServer.
Global Verification follows eligible runs; it reports selected conformity
separately from execution status and does not redefine public exits.

Bootstrap installs/verifies `bs` using `scripts/install-bs.sh`. Discovery,
Blueprint, Preview and zero-change Workflow do not install it. A correct existing
symlink is accepted; an unrelated `bs` is never replaced. Manual installation or
repair uses `./scripts/install-bs.sh`; `--check` checks launcher state. A moved
repository requires repairing the link. Homebrew-free Restore may defer launcher
setup with warning; `bootstrap.sh` remains available from the root.

## Capture and Restore

Capture performs staged Discovery, selection and Preview, then optional secure
identity export, portability validation and Bundle publication under `exports/`.
It preserves ordinary source Generated Configuration and Blueprint.
Missing optional `mas`/`code` inventories require confirmation to continue without
those items. Selecting identities may offer an explicit `age` install through
Homebrew; users can continue without identities or cancel if declined.

Restore validates/unpacks the Bundle, recovers pending local publication where
needed, shows source selection and lets users disable groups. Preview runs before
`Apply this selection with Bootstrap? [y/N]`; cancellation here does not publish
staged state. Apply publishes local Generated Configuration / Blueprint and runs
Bootstrap. After preflight/Homebrew preparation, selected SSH configuration and
Secure Restore precede dependent Workspace clones. Missing `age` may be offered
explicitly; import requires typing `import`. Conflict, failure or cancellation
stops dependent restoration. Later failure does not undo imported identities.

Workflow subsequently uses ordinary published local state without the Bundle.
[Capture / Restore](../CAPTURE-RESTORE.md) owns transfer boundaries;
[Configuration](CONFIGURATION.md) owns Bundle/path/publication rules. Application
execution has a separate structured [Core contract](../core/APPLICATION-INTERFACE.md).

## Compare and verification

`bs compare` compares local selected Generated Configuration with the current Mac.
It does not run Discovery, Bootstrap, administrator preflight or cleanup, and is
never invoked automatically after Bootstrap/Workflow/Restore. It reports matching,
missing, differing and unverified requirements and informational extras only with
complete source provenance and valid target enumeration.

Global Verification can report Selected requirements verified, Differences
detected, Verification incomplete or No managed requirements.
Comparison can report No differences detected, Differences detected,
Comparison incomplete or No comparable requirements. These describe selected
scope, not whole-Mac identity, runtime health or removal recommendations.

## Output, logging and exit status

Normal output is compact; `--verbose` adds `detail` diagnostics. Shared message
functions are `action`, `success`, `warning`, `error`, `info`, `detail`.
History logs retain lifecycle diagnostics without making terminal output an API.

- `logs/latest.log` is the latest run; `logs/history/` retains earlier runs.
- Check / Bootstrap lifecycle summaries count checked modules, installed/skipped
  outcomes, warnings, errors and duration as applicable.
- Discovery uses Modules Processed, Warnings, Errors and Duration. Processed counts
  `run_module` calls, including Core, not discovered items or published files.
- Preview uses Modules Inspected, Warnings, Errors and Duration.
- Blueprint-aware Bootstrap summarizes selected/total scope and Enabled/Skipped
  settings. Enabled means selected, not changed.

Warnings/errors count lifecycle outcomes rather than every printed message.
Summary headline prioritizes errors, then warnings, then success; terminal and
logs use the same counters. Global Verification is additional reporting, not a
replacement for execution Summary.

Workflow exits normally use `0` success, `1` warnings, `2` errors. CLI Capture/
Restore user cancellation can complete without Apply; standalone secure commands
have their own cancellation statuses. Signal interruption logs interruption and
keeps cleanup bounded; it does not promise rollback. See
[Secure SSH Identity Migration](SSH-IDENTITY-MIGRATION.md) for standalone commands.
