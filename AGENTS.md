# AGENTS.md — Macseed

## Working model

Macseed reconstructs supported environment state: **Capture → Rebuild → Verify**.
Core owns Discovery, Generated Configuration, Selection / Blueprint, Preview,
Bootstrap, Verification, Comparison, Bundle and Secure Migration. The official CLI
is implemented; native SwiftUI Desktop is planned and must consume the same Core.
Current code version is 3.4.0; Stage 15 Protocol V1 is complete. Desktop/runtime
integration is Stage 16; packaging and clean-Mac qualification are Stage 17.

Read existing code and consumers before proposing changes. Prefer minimal safe
changes and existing helpers over replacements or new abstractions. Follow
**Check → Apply → Verify** and do not expand task scope to adjacent findings.
Audit/review is read-only unless implementation is explicitly requested.

## Repository and entry points

Run Macseed commands from the repository root because `bootstrap.sh` sources
relative paths. `bin/bs` is an optional launcher; `bootstrap.sh` remains the
canonical production CLI entrypoint. See [CLI](docs/toolkit/CLI.md) for modes.

- `modules/core/`: shared infrastructure and application Protocol adapter.
- `modules/discovery/`: observation/exporters.
- `modules/blueprint/`: selection/parser/selector.
- `modules/bootstrap/`: Workspace consumers.
- `modules/apps/`, `modules/vscode/`, `modules/settings/macos/`: domain consumers.
- `modules/verification/`: production Verification/Comparison projections.
- `modules/bundle/`, `modules/migration/`: Bundle and separate secure identity paths.
- `config/`: static configuration; `config/generated/`: private local derived state.
- `settings/`: source settings; `scripts/`: canonical runners and focused harnesses.

Do not move domain logic into shared Core utilities. Use `config_sections` and
`config_get` for sectional Workspace data; use native Git readers for `git.conf`.
Desktop consumes structured Protocol V1 JSON/JSONL, never terminal/log parsing,
interactive terminal emulation or a second Swift implementation of Core behavior.
The adapter must reuse authoritative production paths.

## Discovery and local state

Discovery observes only its own domain, without installs, system writes, branch
switches or user-file migration. Its domain side effect is publishing local
`config/generated/`; infrastructure can write logs and run relevant preflight.

Collect, validate and serialize before publication. Handled failure preserves
previous valid state. Connect exporters to `modules/discovery/discovery.sh` and
use existing logging helpers. Workspace `folders.conf`, `repositories.conf`,
`vscode-workspaces.conf`, `inventory.conf` publish as one grouped snapshot;
`workspace.conf` remains independent.

Generated Configuration is derived input, not trusted executable configuration
or a credential vault. Never `source`/`eval` generated data or hard-code user values
that belong there. Native `git.conf` is read with
`git config --file ... --no-includes`. Keep generated data and private Blueprint
ignored by Git and separate from static config. Preserve producer/consumer formats.

Blueprint selects without overwriting observed values. Malformed input returns
`2` and blocks Apply; stale selection warns with `1`. Save is atomic; `q`/`Q`
cancellation preserves the original. No Blueprint retains compatible all-inclusive
behavior; old missing categories retain their established disabled semantics.

## Mutation and verification

Validate all required selected inputs before the first mutation. Missing,
unreadable or malformed required input returns `2`; optional warning/skip is
allowed only by its existing domain contract. Observe before Apply; observation
error is not absence or a reason to mutate. Skip matching state, verify observable
results and never report success after a failed mutation or required local Verify.

Set `MODULE_CHANGED=true` only after real successful change. Use `run_module` /
`run_configuration` when appropriate. Ordinary module exits are `0` success,
`1` warning, `2` error; structured application exits have their own reference.
Global Verification reports selected conformity separately from operation exits.
Unsupported is a subset of unverified; unresolved scope remains distinct.

Preserve Bootstrap dependency order. Restore's selected SSH configuration and
secure identity import must precede dependent Workspace clones. Ordinary Bootstrap
does not import identities. Do not reorder existing steps without demonstrated need.

Preview validates selected input and uses read-only preflight/inspection without
Apply, `sudo -v`, Homebrew installation or `MODULE_CHANGED`. Startup failures stop;
Core/domain inspection errors remain counted while later inspections continue.
Planned actions alone return `0`, warning `1`, error `2`. Summary counts inspection
calls, not items. Comparison is explicit/read-only and never auto-runs or plans
removal. Extras require complete digest-bound source provenance and valid enumeration.

### Protect user state

Workspace reconstructs folders and repositories, not contents. Never delete or
replace existing directories, silently change remotes, switch dirty tracked/staged
state, remove conflicting untracked files, reset, clean, force-push or force checkout.
Warn/stop unsafe actions; Git may refuse checkout due to untracked conflicts.
`.code-workspace` metadata is discovered but has no restoration consumer.

Real Apply can install apps/packages, write global Git/macOS settings, clone
repositories, copy VS Code settings with backup and restart affected processes.
New mutations require current-state checks, idempotency, input validation,
conflict protection and post-apply verification. Add paired Discovery when the
domain should travel between Macs; explain noticeable side effects to users.

### Bundle, secure input and re-entry

Capture/Restore use the production `.mbt` / `MBT-BUNDLE-1` format. Normal Bundle
configuration is private but unencrypted; checksums are not source authentication.
Private identities use separate encrypted Secure Migration and no-clobber import.
Secrets never enter ordinary JSONL, argv, environment, generated config or logs.
Use disposable fixtures for secure tests rather than real `~/.ssh` mutation.

Prepare is not Apply. Execute recomputes authoritative preparation and rejects
stale plans before publication; prepared IDs are not authorization or transactions.
Distinguish pre-publication failure, publication and possible target mutation.
Recovery protects local configuration publication, not installs/settings/imports.
Retry means fresh inspection/Preview and idempotency, not persistent transaction resume.
Never infer verified identities from exit `0` without valid importer evidence.

## Documentation ownership and anti-drift

English is canonical for product, architecture, developer and reference documents.
Russian documents under `docs/ru/` are optional convenience copies that may lag;
do not create parallel Russian copies of new technical contracts.

Identify the owner before editing, update it first, and touch other documents only
when necessary for accuracy. The [documentation index](docs/README.md) maps owners:
README introduces the product; Vision owns principles; Architecture owns stable
boundaries; Capture / Restore owns the workflow; CLI owns terminal behavior;
Core reference owns Protocol/execution; Configuration owns data/domain contracts;
Desktop/Distribution own their planned boundaries.

Roadmap contains major outcomes/status, not an implementation log. Architecture
is not a changelog or API dump. TODO contains unfinished actionable work only;
remove completed entries. CHANGELOG records completed release-visible changes.
Never rewrite released history for current branding or language. Keep detailed
contracts with one owner; link instead of duplicating them. Feature work does not
require updating every major document. Prefer concise direct English and do not
expand Roadmap/Architecture because implementation was complicated.

## Logging and validation

Use `action`, `success`, `warning`, `error`, `info`, `detail` from
`modules/core/common/common.sh`. Keep default output compact; diagnostic detail
uses `detail`. Normal lifecycle runs finish with the existing Summary. Local logs
under `logs/` must not enter Git.

Validate proportionally. Documentation-only changes use diff/link review and
`git diff --check`; do not run regression/syntax checks, macOS preference/PID
inspection or workflows merely for documentation. For code, run focused existing
harnesses first. Use `scripts/test.sh` for justified full integration/release
validation and `scripts/lint.sh` for ShellCheck. Do not replace canonical runners.
Minimum Bash syntax verification:

```bash
find modules scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n bootstrap.sh
```

`--help`/`--version` do not run workflows. Do not run Bootstrap without explicit
request; do not run Discovery for read-only analysis because it replaces generated
state. Check also creates logs, requests administrator authentication and may offer
Homebrew installation. Real workflows require authorization for their side effects.

Finish substantial changes with scope/contracts/security review, appropriate
focused validation, `git diff --check`, status and documentation ownership review.
Report validation, limitations and publication state precisely.

## Git process

Check the branch before edits. Development belongs on `develop`; `main` is stable
releases only. If not on `develop`, report and wait for a decision; never switch
branches automatically over local changes. Preserve unrelated work.

Do not commit/push unless authorized. Never push, merge, tag, rebase, force-push
or modify remote state without explicit request. Before authorized commits review
status and diff/stat, stage explicit target files, and exclude generated state,
logs, exports, `.env` and temporary files. One logical task per commit, with short
English `type: lowercase description`; types: `feat`, `fix`, `refactor`, `docs`,
`style`, `chore`, `release`. No broad rename, formatting or refactor without scope.
