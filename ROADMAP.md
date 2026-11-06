# Roadmap

Strategic outcomes and stage status. [Product Direction](docs/PRODUCT-DIRECTION.md)
records the approved product decisions; this Roadmap owns their current execution
order. [Desktop](docs/DESKTOP.md) owns interaction
contracts, [TODO](TODO.md) owns concrete unfinished actions, and
[Changelog](CHANGELOG.md) owns completed release-visible history.

## Current project status

- **Completed:** Core/CLI 3.4.0 and Stages 1–15, supported native Capture/Rebuild/Check
  flows, accepted Native UI Alignment, Stage 16J diagnostics and Stage 16H SSH
  identity migration. These are bounded milestones, not a finished Desktop release.
- **Implemented — Qualification Open:** development-runtime execution, completion
  and integration, native Workspace E2E, Homebrew Setup Installer handoff and the
  remaining supported-domain, lifecycle, security and accessibility gates.
- **Latest checkpoint:** Roadmap/product clarity and contextual Selection guidance
  are finalized within the accepted scope. Local validation and wording/typography
  refinements do not close broader visual, hosted CI or release qualification gates.
  **Next functional checkpoint:** SSH Environment Completion — Developer Environment Closure.
- **Before Macseed 1.0:** finish the remaining Stage 16 and bounded Stage 3C work,
  qualify a fresh development-runtime E2E, then deliver Stage 17 packaging,
  clean-Mac qualification and Early Access. Autonomous signed distribution is planned.

Follow the [Current Execution Order](#current-practical-execution-order); a listed
priority is not authorization to start another checkpoint. Implementation, local
validation, manual/visual acceptance, hosted CI and release qualification remain
separate evidence levels.

## Completed milestones — chronological history

### Foundation and stable CLI milestones

| Stage | Status | Outcome |
|---|---|---|
| 1 — Core | Completed | Modular utilities, logging, preflight and Configuration Engine |
| 2 — Discovery Engine | Completed | Observation of supported environment state with safe publication |
| 3 — Generated Configuration | Completed | Private derived state connecting observation to restoration |
| 4 — Bootstrap Engine | Completed | Idempotent restoration with local Check → Apply → Verify |
| 5 — Blueprint Engine | Completed | Category/item selection, validation and safe interactive saving |
| 6 — Reliability & Release Hardening | Completed | Input, publication, observation and lifecycle contracts hardened |
| 7 — Release 3.0.0 | Completed | Stable Discovery → Generated Configuration → Blueprint → Bootstrap |
| 8 — Dry-run / Preview and Release 3.1.0 | Completed | Read-only Preview and guided Workflow |
| 9 — macOS Coverage Expansion | Completed; release 3.2.0 | Supported Finder, Dock, Window Management, Keyboard, Trackpad and Screenshots settings |
| 10 — Shell & Developer Environment | Completed; release 3.2.0 | Restricted standalone Zsh, direct global Git settings and SSH Host profiles |
| 11 — Application Configuration Modules | Completed assessment; adapters deferred | No additional adapters justified by the assessed portability, privacy and value |
| 12 — Secure Migration Engine | Completed v1; release 3.3.0 | Explicit encrypted SSH identity transfer and one-Bundle Capture / Restore |
| 13 — Reporting & Global Verification | Completed | Selected conformity and coverage gaps, separate from operation outcomes |
| 14 — Environment Comparison | Completed | Explicit read-only comparison; extras require completeness evidence, never authorize removal |
| 15 — Core Application Interface | Completed | Protocol V1 over production Core: capabilities, inspect, Prepare/Execute, progress and Verification |

Stage 11's assessment deferred new adapters; existing VS Code support remains.
Additional tool managers and generic PATH/binary restoration are outside the
completed scope. Historical Core/CLI releases and tags retain their meaning;
current Core/CLI is 3.4.0. The [Core reference](docs/core/APPLICATION-INTERFACE.md)
owns the implemented application contract.

### Desktop acceptance history

The records below preserve the development sequence and their original scope.
Commit references and past green CI establish historical baselines, not validation
of current HEAD or completion of outstanding native and packaged gates.

#### Homebrew and Restore resilience

The historical Homebrew baseline is `778b816`, with subsequent real-Mac
qualification (2026-10-17). Assisted App Store Restore is completed and integrated
into `develop`; later product gates remain open.

**D1–D4/R5 is accepted within its implementation and automated integration scope**
at [03198a2](https://github.com/jetiaks-AKS/macseed/commit/03198a2010d554c5f87f73c3260ef2f34af0fc89),
with successful [CI #96](https://github.com/jetiaks-AKS/macseed/actions/runs/40069974279).
Its general Restore resilience audit is closed. Native lifecycle, universal progress
qualification and recovery remain open under the [Core process contract](docs/core/APPLICATION-INTERFACE.md#external-process-waiting-and-git-clone-r5).
CI tuning is maintenance; [Contributing](CONTRIBUTING.md#focused-feedback-and-ci)
owns canonical test execution and timing evidence.

#### Desktop CI validation

**COMPLETE — [CI #108](https://github.com/jetiaks-AKS/macseed/actions/runs/40287367098),
published commit `411cd712`.** The hosted Debug build, all eight Desktop suites,
both Restore subsets and native assertions passed with lint, all four Core shards
and `validate`. This closes hosted Desktop validation, not distribution or remaining
Stage 16 qualification. CI #109 subsequently confirmed Desktop after lint running
alongside Core with the same mandatory gate. [Contributing](CONTRIBUTING.md#focused-feedback-and-ci)
owns the run links, Desktop duration and measured serial/parallel comparison.

#### Workspace implementation and bounded Core acceptance

Phase 1 contracts are reviewed and published. Phase 2 implements
bounded Discovery, explicit Capture selection and Bundle inspection; the Capture
role-overlap fix is published and its real-Mac Capture gate accepted. Phase 3
Restore Preview is published and includes an accepted matching real-Mac Preview.
Phase 4 Core Execute/Global Verification and Desktop integration are published in
`12beaa6`; Phase 5 selected descriptor Capture/Restore and relationship verification
are published in `7ac0408`. Disposable fixtures cover these implementations.
**Phase 6 — topology-aware Environment Status is complete within its validated
comparison scope.** Focused Core/Desktop validation passed; the user confirmed
four Git repositories and six Workspace Folders as Already Matches on a real Mac
after rebuilding the current Desktop. It compares supported topology and
selected descriptor relationships without target mutation or configuration publication,
preserving legacy Comparison and the Bundle-only Restore handoff.

**Bounded Workspace Core E2E accepted — 2026-10-30, `ed521e7`.** The recorded real-Mac
acceptance and disposable fixtures cover the following on Apple Silicon/macOS 27.2
with the development runtime. The comprehensive audit did not locate the raw report;
this preserves the owner-recorded acceptance without claiming a new run or artifact path:

- Core Capture → Preview → Execute, **6/6 Global Verification** and **6/6 Core
  Environment Comparison** against the same saved Bundle: base, linked and nested
  repositories, two folders and one selected `.code-workspace` descriptor.
  Independent Git/filesystem checks confirm topology and descriptor relationships.
- Tracked/staged/untracked/ignored preservation, conflict safeguards and repeat/no-op.
  Protection passes in conflict cases do not imply successful restoration.
- Controlled Graceful Stop and safe fresh Preview/Execute re-entry, followed by
  repeat/no-op. The **SIGTERM fail-closed interruption fence** is accepted separately:
  retained uncertainty blocks retry before new publication; it does not establish
  completed reconciliation or recovery.

#### Product direction, Native UI Alignment and later CI baselines

Documentation Checkpoint 0 records the [approved product direction](docs/PRODUCT-DIRECTION.md#5-delivery-sequence-and-gates);
the current execution order below supersedes historical next-action notes.
[CI #127](https://github.com/jetiaks-AKS/macseed/actions/runs/40914838447) passed at
`ed521e7`: lint, all four Core regression shards, Desktop and `validate`.
Earlier CI #123/#124 assertion failures are not active blockers at this baseline.
The consolidated CI evidence assessment and revised Product Scope audit are accepted;
CI #127 remains historical evidence, not validation of later changes.
Native UI Alignment is implemented and explicitly visually accepted on 2026-11-02.
It and the subsequent Homebrew Setup implementation are published on `develop`
through `ac6c5bd`. At that baseline, [CI #135](https://github.com/jetiaks-AKS/macseed/actions/runs/41678025367)
passed lint and all four regression shards, but Desktop compilation failed before
tests ran. Subsequent compilation/assertion repairs passed
[CI #137](https://github.com/jetiaks-AKS/macseed/actions/runs/41773961712) at `716dbfed`.
These are historical baselines, not current-HEAD validation. Visual acceptance,
local tests, hosted CI and release qualification remain distinct.

The approved [hierarchy/defaults](docs/PRODUCT-DIRECTION.md#4-native-desktop-presentation-direction--planned-not-implemented)
and [Desktop UI](docs/DESKTOP.md#macseed-native-ui--design--interaction-contract)
remain closed visual milestones. Their acceptance does not close later refinement
or capability qualification. Functional Restore Result/Visual Unification is
implemented and manually accepted; controlled real-Mac Early Cancelled/Partial
Stopped checks retain their accepted scope.
The accepted alignment covers Home/workflow naming, native Sidebar/Settings/About,
Capture's accordion and publication Result, Restore Selection/Preview and flat
outcome-specific Progress/Result, and static Status diagnostic sections with
adaptive count columns.

Stage 16J is complete. It preserves two independent
levels: Core/CLI technical logs and private Desktop operation records. Reports are
privacy-safe projections of Desktop evidence, not complete Core logs or recovery
journals. Local validation and manually accepted Operation Logs UX are documented
in [Desktop](docs/DESKTOP.md#local-logs-and-diagnostic-report); report-panel manual
checks and signed/clean-Mac qualification remain separate.

#### Stage 16H SSH Identities — accepted 2026-11-05

Automatic and manual external SSH Capture → Rebuild → Verification are accepted,
including byte matching, permissions/fingerprints and repeated Preview/no-op.
Migration is opt-in/default-off, encrypted in `secure.age`, and uses bundled age;
all identities currently restore to `~/.ssh`. Broader SSH Configuration and custom
restore destinations are planned under the next checkpoint. Stage 17 remains separate.

## Stage 16 — Native Macseed Desktop

**In Development.** Slice IDs 16A–16K are historical identifiers, not execution
order. Completed slices retain their supported scope; the entire stage remains open.

Statuses are **Completed**, **Implemented — Qualification Open**, **In Development**,
**Next**, and **Planned / Deferred**. Implementation completion does not imply all
manual, security, accessibility, runtime or release gates have passed.

| Slice | Status | Outcome / remaining boundary |
|---|---|---|
| 16A — Product / UX contract | Completed | Defined native Protocol V1 client contract; Core remains authoritative |
| 16B — Native shell and design | Completed | Approved Minimal Premium, navigation, shared components and Debug fixtures |
| 16C — Runtime and capabilities | Implemented — Qualification Open | Owned Core processes and validated development transport; hardening remains. Checkout-independent packaged writable runtime is planned under Stage 17 |
| 16D — Environment Status | Completed | Read-only comparison; Saved Environment reference and Restore handoff accepted |
| 16E — Capture | Completed | Supported inventory/selection, preparation and publication; secure identities completed under 16H |
| 16F — Restore preparation | Completed | Supported inspection, selection, prerequisites and fresh Preview |
| 16G — Restore execution | Implemented — Qualification Open | Core Rebuild/Verification and Assisted App Store Restore; continuing Cask and interruption/re-entry qualification |
| 16H — Secure SSH Identities | Completed | Accepted 2026-11-05; [identity migration evidence and fixed destinations](#stage-16h-ssh-identities--accepted-2026-11-05) |
| 16I — Verification and completion | Implemented — Qualification Open | Manually accepted final category/item Result, disjoint confirmed cards and Process/Verification separation; completion edge cases remain |
| 16J — Logging & Diagnostics | Completed | Typed persistent logs, history, Important/All and immutable Diagnostic Report preview/copy/save; report-panel manual checks and packaged qualification stay separate |
| 16K — Desktop integration hardening | In Development | Bundle-backed Status completed; runtime, transport, security, accessibility and packaged-state hardening remain |

### Cross-cutting Desktop milestones and remaining gates

These retain their established names without adding stage numbers.

| Milestone | Status | Qualification boundary |
|---|---|---|
| Native UI Alignment / Visual Unification | Completed | Visually accepted 2026-11-02; [historical scope and subsequent baselines](#product-direction-native-ui-alignment-and-later-ci-baselines) |
| Restore Cancellation Safety | Implemented — Qualification Open | Operation-wide checkpoint Graceful Stop and separate Force Stop, automated tests and controlled real-Mac checks; Stage 3C and broader installer quiescence remain open |
| Homebrew Setup | Implemented — Qualification Open | Real standard Installer handoff and installation qualification remain open separately from Cask Restore |
| Settings Tools & Dependencies | Implemented — Qualification Open | Existing Homebrew controls moved out of General; read-only diagnostics reuse the bundled age validator; General and Operation Logs retain behavior. Native visual acceptance is pending |
| Unified UI Scenario Catalog | Planned / Deferred | Existing Debug fixtures retained; optional Lite tooling after functional priorities |

[Desktop qualification](docs/DESKTOP.md#recent-restore-qualification-and-performance)
owns representative real-Mac results and their limits; [Configuration](docs/toolkit/CONFIGURATION.md)
owns domain capabilities. Remaining qualification does not reopen accepted UI
implementations or the closed general D1–D4/R5 Restore audit.

<a id="current-practical-execution-order"></a>

## Current Execution Order

This is the single authoritative execution sequence toward Macseed 1.0.
Complete one bounded checkpoint at a time, preserving accepted scope and evidence.

1. **Documentation consolidation and product clarity — Completed within the approved scope.**
   Roadmap, positioning and contextual Selection wording/typography are finalized.
   Remaining qualification gates and completed contracts retain their boundaries.
2. **[SSH Environment Completion — Developer Environment Closure](#ssh-environment-completion--developer-environment-closure) — Next.**
   Complete SSH Configuration and optional identity destination integration under
   the approved Selection/Preview/Rebuild contract. It is planned, not implemented;
   this documentation task does not start it.
3. **Remaining native Workspace qualification and related supported-scope checks.**
   Use the retained selected Bundle after proving native HOME/Core/journal/preferences
   isolation. Qualify counts, read-only matching and explicit Missing/Different
   handoff without Apply. Preserve the accepted bounded Core E2E and Phase 6 scope.
4. **Bounded Stage 3C recovery/reconciliation.** Extend existing durable journals,
   Stop and safety fences with operation-owned evidence, reconciliation and safe
   re-entry under the [Core contract](docs/core/APPLICATION-INTERFACE.md#stage-3c-reconciliation-boundary).
   Uncertain or foreign evidence stays blocked; no automatic journal clearing or
   rollback. Successful blocking is not completed recovery; recovery qualification
   follows this implementation rather than being inferred from step 3.
5. **Remaining Stage 16 qualification.** Close the [supported-domain gates](TODO.md#remaining-supported-domain-restore-qualification),
   Homebrew Setup Installer gate, completion (16I), lifecycle, integration, security,
   accessibility and runtime hardening (16K). Account for the 23 Graceful Stop tests
   outside canonical coverage. Recovery gates depend on step 4; preserve accepted
   Assisted Restore behavior and distinguish mandatory gates from optional scope.
6. **Fresh development-runtime Capture → Rebuild → Verify → Check → no-op E2E.**
   Use current supported scope, confirmed backup protection and independent evidence.
   This gate does not replace packaged clean-Mac qualification.
7. **[Stage 17 — autonomous distribution](#stage-17--distribution--clean-mac-e2e).**
   Implement and qualify checkout-independent bundled Core/Python/tool placement,
   a managed writable workspace, signing/notarization and DMG delivery after the
   agreed Stage 16 closure. UI acceptance does not start packaging automatically.
8. **Clean-Mac qualification and [Early Access](#early-access--alpha).** Qualify full
   packaged workflows on each claimed platform, then validate with external technical
   users and resolve observed compatibility/UX failures before public launch.
9. **[Macseed 1.0](#macseed-10).** Close mandatory product gates, document supported
   scope/limits and complete Early Access qualification before release.

## SSH Environment Completion — Developer Environment Closure

**Next — planned, not implemented.** Following completed Stage 16H SSH Identities,
complete practical SSH Configuration across Discovery → Capture → Preview →
Restore → Verification, then integrate optional per-identity restore destinations
(default `~/.ssh`) in the existing Rebuild Selection Customize… sheet. Preview
remains read-only; no new screen or SSH manager. Validate `IdentityFile` against
selected destinations, require explicit authorization for configuration corrections,
retain genuine unsafe/unsupported/conflicting findings and Secure Migration v1
compatibility, and later qualify joint E2E with custom destinations and repeated no-op.
[Capture / Restore](docs/CAPTURE-RESTORE.md#ssh-environment-completion--developer-environment-closure)
owns the contract; [TODO](TODO.md#ssh-environment-completion--developer-environment-closure)
owns unfinished actions. Stage 17 and the other remaining gates are unchanged.

## Complete Workspace & Git Worktree Restoration

**Implemented — Qualification Open.** [Completed phases and bounded Core E2E evidence](#workspace-implementation-and-bounded-core-acceptance)
remain accepted; the following gates qualify that existing capability.

**Still open:** native Desktop E2E with this selected Bundle (**NOT RUN** because
safe native HOME/journal isolation was not established), full SIGTERM
reconciliation/recovery, and [packaged/clean-Mac qualification](#stage-17--distribution--clean-mac-e2e).
Prior native Status/handoff acceptance remains valid within its independent scope;
it does not replace the missing same-Bundle GUI gate. Workspace and Stage 16/17
are not complete. CI #127 supplies successful hosted validation, not these real gates.
[Configuration](docs/toolkit/CONFIGURATION.md#linked-git-worktree-capability-limits)
owns the contracts and compatibility limits. Independent-clone fallback is forbidden.

- Discover repositories and linked worktrees, identify common Git directories
  and capture their topology and checkout relationships.
- Restore base repositories and linked worktrees in a safe dependency order;
  validate remotes, branches and paths, including occupied branches and conflicting
  worktree destinations.
- Preserve existing tracked, staged, untracked and ignored files. Cover Workspace
  folder structure and VS Code workspace relationships through Selection, Preview,
  explicit conflict handling and Global Verification.
- Establish idempotency, fresh-inspection retry and representative real-world
  gates, including repeat/no-op convergence.

Expanding the bounded local clone SSH profile/identity support, adding proxies or
migrating additional SSH configuration requires a separate Git/SSH-stage decision.
Current exclusions remain in force; filters and Git LFS are neither supported nor
automatically approved for implementation.

Any transfer of unique Workspace data requires a separate bounded secure migration
contract; preserving existing files does not implement that transfer. Current
Folders restores structure only; unrestricted project-content copying and general
backup remain outside scope.

## Stage 17 — Distribution & Clean-Mac E2E

**Planned.** Deliver a private writable Core workspace while signed resources stay
read-only; implement and qualify checkout-independent bundled Core/Python and
secure tools required by the selected release scope. Sign the app and nested
runtime with Developer ID / Hardened Runtime, notarize/staple, produce a DMG and
validate downloaded-app Gatekeeper behavior. Prove Capture → Restore → Verify on
clean Apple Silicon and read-only Status against the same Saved Environment;
qualify Intel separately before claiming support. Validate
operation logs, interruption evidence and exact report preview/export/privacy in
the packaged application. [Distribution](docs/DISTRIBUTION.md) owns these gates.

## Early Access / Alpha

**Planned before 1.0.** Approximately 10–20 technical external users exercise real
Capture/Restore/Status workflows and voluntarily share privacy-safe reports/issues.
Resolve observed compatibility and UX failures before public launch; local
fixtures and development builds do not replace this product validation.

## Macseed 1.0

**Planned.** The first complete native Desktop release builds on the mature CLI
Core. Close mandatory Restore capability, reliability/security and distribution
gaps, document supported scope and remaining limitations, and complete Early
Access feedback qualification. No release date or current CI/release success is
implied by completed Stage 16J.

<a id="environment-manager--post-10--future-direction"></a>

## Post-1.0 / Future Direction

Workspace file-content transfer, additional application adapters, Environment
Manager capabilities and automatic updates are not prerequisites for Macseed 1.0.
General backup and unrestricted file migration remain outside product scope.

**Possible, demand-driven Environment Manager capabilities:** independent Profiles,
Saved Environment History, Semantic Comparison, Drift Detection and explicit
Selective Apply followed by Verification. These are not requirements for 1.0.
Build on Saved Environments and the existing Core; no parallel configuration,
Restore or Verification engine, database or versioning subsystem without a proven
need. No background monitoring is planned. Allow multiple Saved Environment
references rather than one permanent Bundle. Current Bundle-backed Status/handoff
does not implement these capabilities.
Future Apply must follow Prepare → Preview → Confirm → Execute → Verify;
comparison remains read-only and absence never authorizes deletion.

Investigate bounded Workspace/local unique-data transfer only through a separate
value, provenance and safety contract; current Folders reconstructs structure only.
Direct/vendor restoration, additional secure migration and application adapters
require independent value/security/maintenance assessment. No plugin framework is
planned. Full cloning, general backup, arbitrary user-data migration, automatic
removal and unconditional whole-Mac rollback remain outside scope. Remaining
macOS 27 visual/cross-version qualification is tracked in TODO, not the next
functional checkpoint.

### Future whole-application updates

**Approved future direction; not implemented.** After Stage 17 signing/distribution,
qualify a separate Settings Updates tab with manual and explicitly configured
automatic modes. Signed, verified atomic replacement updates all bundled components
together and defers during owned operations. Framework selection remains separate;
[Distribution](docs/DISTRIBUTION.md#future-whole-application-updates) owns the contract.
This does not start implementation or change the current checkpoint order.
