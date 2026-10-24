# Roadmap

Strategic outcomes and stage status. [Desktop](docs/DESKTOP.md) owns interaction
contracts, [TODO](TODO.md) owns concrete unfinished actions, and
[Changelog](CHANGELOG.md) owns completed release-visible history.

## Foundation and stable CLI milestones

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

## Stage 16 — Native Macseed Desktop

**In progress.** Completed slices do not establish full Restore qualification,
secure integration or packaged clean-Mac readiness. Slice IDs are historical
identifiers, not execution order. The historical Homebrew baseline is `778b816`,
with subsequent real-Mac qualification (2026-10-17). Assisted App Store Restore is
completed and integrated into `develop`; later product gates remain open.
Implemented means code exists; automated-tested and
real-Mac qualified describe separate evidence. Partial qualification does not close
open/deferred gates, and no completed slice alone establishes release readiness.

| Direction / slice | Status | Outcome / remaining boundary |
|---|---|---|
| 16A — Product / UX contract | Defined | Native Protocol V1 client; Core remains authoritative |
| 16B — Native shell and design | Completed | Approved Minimal Premium, navigation, shared components and Debug fixtures |
| 16C — Runtime and capabilities | Implemented; hardening open | Owned Core processes and validated transport; packaged writable workspace unqualified |
| 16D — Environment Status | Completed | Read-only comparison; Saved Environment reference and Restore handoff accepted |
| 16E — Capture | Completed in supported scope | Real inventory/selection, preparation and publication; secure interaction remains 16H |
| 16F — Restore preparation | Completed in supported scope | Inspection, selection, prerequisites and fresh Preview |
| 16G — Restore execution | Implemented; qualification open | Core Rebuild/Verification and Assisted App Store Restore; continuing Cask and interruption/re-entry qualification |
| 16H — Secure SSH interactions | Open | Desktop FD/challenge bridge and secure Capture/Restore qualification |
| 16I — Verification and completion | UI implemented/manually accepted; qualification open | Final category/item Result, disjoint confirmed cards and Process/Verification separation; remaining completion edge cases open |
| 16J — Logging & Diagnostics | Completed | Typed persistent logs, history, Important/All and immutable Diagnostic Report preview/copy/save |
| 16K — Desktop integration hardening | Partially complete | Bundle-backed Status completed; runtime, transport, security, accessibility and packaged-state hardening remain |
| Visual Unification | Completed/manually accepted | Environment Status-style categories, disclosures, local results and compact counters, including final Restore Result |
| Restore Cancellation Safety | Implemented; partially qualified | Operation-wide checkpoint Graceful Stop and separate Force Stop; automated tests and controlled real-Mac Early Cancelled/Partial Stopped checks; Stage 3C and broader installer quiescence open |
| Unified UI Scenario Catalog | Deferred tooling | Existing Debug fixtures retained; optional Lite catalog after functional priorities |

Stage 16J is complete. It preserves two independent
levels: Core/CLI technical logs and private Desktop operation records. Reports are
privacy-safe projections of Desktop evidence, not complete Core logs or recovery
journals. Local validation and manually accepted Operation Logs UX are documented
in [Desktop](docs/DESKTOP.md#local-logs-and-diagnostic-report); report-panel manual
checks and signed/clean-Mac qualification remain separate.

<a id="current-practical-execution-order"></a>

## Current Execution Order

Complete one bounded checkpoint at a time. Functional Restore Result/Visual
Unification, operation-wide Graceful Stop implementation and Stage 16J are already
implemented; remaining qualifications do not reopen those UI implementations.

Tailscale 1.104.1 passed PKG Preparation → Clean Install → Verification → fresh
matching Preview. Receipt-backed PKG Repair provenance is implemented; unsafe
Tailscale Repair remains Unsupported (`ownership_unproven`), with no in-place
Repair. Independent Restore continues safe work around item-local Cask conflicts;
a real Partial Restore reported 105 Verified and one Tailscale Mismatch with
**Rebuild Needs Attention**. These bounded gates do not close Stage 16.

Assisted App Store Restore now captures requirements, supports selection/Preview,
manual installation in Apple App Store and fresh Core verification. Confirmed
identity overlap follows Cask-first precedence. Automatic MAS development is
preserved on `archive/mas-automatic-restore-v4` and is outside the active path.
The Assisted Restore milestone's Stage 5 Core/Desktop regression gate passed.
A [controlled Rebuild from the existing `Test_1.mbt` on 2026-10-21](docs/DESKTOP.md#recent-restore-qualification-and-performance)
passed Launcher and Global Verification. A fresh full Capture → Rebuild →
Verification gate from a new Bundle remains outstanding. This completed development
milestone does not complete Stage 16 or make Macseed 1.0 release-ready.

The VS Code Restore Reliability checkpoint completed on 2026-10-22 adds safe typed
`network_reset` diagnostics. Independent extension installs continue only after a
confirmed network reset and a fresh, valid, unchanged inventory with the failed
requirement still absent. Unknown errors and safety violations still stop further
installs. The checkpoint's Core regression gate passed **40/40** suites. Real
[VS Code qualification](TODO.md#vs-code-restore-requalification) retains the
user-confirmed installation of previously missing extensions; dependency closure
and independent follow-up evidence remain separate.

**D1–D4/R5 repair queue: accepted and closed within the documented implementation
and automated integration boundaries.** The accepted baseline is
[03198a2010d554c5f87f73c3260ef2f34af0fc89](https://github.com/jetiaks-AKS/macseed/commit/03198a2010d554c5f87f73c3260ef2f34af0fc89),
with [CI #96 / 40069974279](https://github.com/jetiaks-AKS/macseed/actions/runs/40069974279)
completed successfully, including lint, all four regression shards and `validate`.
The shared durable-admission gap was closed in `b196a660`; the baseline aligns
Force Cancel fixtures with retained unknown consequences and blocked re-entry.
The general Restore resilience audit and this repair queue are not pending reruns.
The [Core reference](docs/core/APPLICATION-INTERFACE.md#external-process-waiting-and-git-clone-r5)
retains the exact limits: native lifecycle gates, universal no-progress detection,
recovery and release readiness are not closed by this acceptance.

Quick, suite/case selection, weighted RestorePrepare case distribution and safe
diagnostic reports are implemented (`1b0d10c`), using the canonical inventory.
Further CI weight/target calibration is maintenance, not a new R5 closure gate;
[Contributing](CONTRIBUTING.md#focused-feedback-and-ci) owns runner usage and timing evidence.

0. **Documentation and current development app — completed:** the accepted baseline
   and retained work are reconciled; the ordinary Debug build and launch from
   `macseed-develop` are confirmed, with **Ready · Macseed Core 3.4.0** observed.
   The development descriptor references this checkout; Core is not embedded.
   This closes the organizational checkpoint, not additional Restore qualification.
1. **[Desktop CI validation](#desktop-ci-validation):** add hosted native-client
   validation through existing build/test entrypoints; complete after an actual
   hosted pass with useful, privacy-safe failure reporting.
2. **[Complete Workspace & Git Worktree Restoration](#complete-workspace--git-worktree-restoration):**
   review architecture/data contracts, then qualify the agreed end-to-end path,
   file preservation, conflicts and repeat/no-op convergence.
3. **Secure SSH Desktop (16H):** implement and qualify the inherited secret-channel
   interaction, encryption/unlock/import confirmation and secure privacy coverage
   through representative Capture/Restore gates.
4. **Remaining supported-domain Restore qualification:** continue Homebrew
   compatibility, real Zsh, macOS visual effects, Extension Pack dependencies and
   the remaining [TODO matrix](TODO.md#remaining-supported-domain-restore-qualification).
   Close each supported scope with real Verify and repeat/no-op evidence;
   preserve the accepted Assisted Restore flow and prior user confirmations.
5. **Recovery / Stage 3C and remaining 16I/16K qualification:** establish a safe
   route after unknown consequences, durable reconciliation and re-entry; qualify
   native quiescence, measured budgets/progress, incomplete Verification, stale
   inputs, transport, accessibility and lifecycle ownership. Complete against
   representative failure/re-entry gates; diagnostic logs alone grant no recovery authority.
6. **[Stage 17 — Distribution & Clean-Mac Qualification](#stage-17--distribution--clean-mac-e2e):**
   qualify a checkout-independent packaged runtime, signing/notarization and full
   clean-Mac workflows on each claimed platform.
7. **[Early Access / Alpha](#early-access--alpha):** validate with external technical
   users and resolve observed compatibility/UX failures before public launch.
8. **[Macseed 1.0](#macseed-10):** close mandatory product gates, document supported
   scope/limits and complete Early Access qualification before release.

Real-Mac performance observations and their differing-run limitations are recorded
in [Desktop qualification](docs/DESKTOP.md#recent-restore-qualification-and-performance),
not a performance guarantee or closure of Homebrew capability qualification.

A [controlled macOS 27 Restore](docs/toolkit/CONFIGURATION.md#controlled-macos-27-restore-qualification)
confirmed 37/37 saved preference values with zero differences. This bounded result
does not close visual-effect or remaining settings qualification gates.

The bounded macOS settings expansion and Capture Result refinements are
implemented with focused automated coverage. Their remaining macOS 27 manual
qualification is tracked in [TODO](TODO.md#macos-settings-manual-qualification);
this does not close Stage 16 or the remaining supported-domain Restore gates.

## Desktop CI validation

**Planned next checkpoint.** Add hosted macOS Desktop build, presentation and
Core/runtime integration validation through existing canonical entrypoints.
Retain the repository CI gate and run repository/Desktop validation sequentially
unless temporary-state isolation is explicitly proven. Confirm an actual hosted
pass before claiming Desktop CI coverage; this is not distribution qualification.

## Complete Workspace & Git Worktree Restoration

**Planned capability checkpoint.** Requires its own architecture and data-contract
review before implementation; no partial support or independent-clone fallback is
approved. [Configuration](docs/toolkit/CONFIGURATION.md#linked-git-worktree-capability-limits)
records the current Discovery/Capture and Restore limitations.

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

Supported SSH profiles, identity selection and proxies for clone require a separate
Git/SSH-stage decision. Current bounded clone exclusions remain in force; filters
and Git LFS are neither supported nor automatically approved for implementation.

Any transfer of unique Workspace data requires a separate bounded secure migration
contract; preserving existing files does not implement that transfer. Current
Folders restores structure only; unrestricted project-content copying and general
backup remain outside scope.

## Stage 17 — Distribution & Clean-Mac E2E

**Planned.** Deliver a private writable Core workspace while signed resources stay
read-only; qualify bundled Core/Python and age/OpenSSH. Sign the app and nested
runtime with Developer ID / Hardened Runtime, notarize/staple, produce a DMG and
validate downloaded-app Gatekeeper behavior. Prove Capture → Restore → Verify on
clean Apple Silicon; qualify Intel separately before claiming support. Validate
operation logs, interruption evidence and exact report preview/export/privacy in
the packaged application. [Distribution](docs/DISTRIBUTION.md) owns these gates.

## Early Access / Alpha

**Planned before 1.0.** Approximately 10–20 technical external users exercise real
Capture/Restore workflows and voluntarily share privacy-safe reports/issues.
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

**Environment Manager:** independent Profiles, Saved Environment History, Semantic
Comparison, Drift Detection and explicit Selective Apply followed by Verification.
Build on Saved Environments and the existing Core; no parallel configuration,
Restore or Verification engine, database or versioning subsystem without a proven
need. Allow multiple Saved Environment references rather than one permanent
Bundle. Current Bundle-backed Status/handoff does not implement these capabilities.
Future Apply must follow Prepare → Preview → Confirm → Execute → Verify;
comparison remains read-only and absence never authorizes deletion.

Investigate bounded Workspace/local unique-data transfer only through a separate
value, provenance and safety contract; current Folders reconstructs structure only.
Direct/vendor restoration, additional secure migration and application adapters
require independent value/security/maintenance assessment. No plugin framework is
planned. Full cloning, general backup, arbitrary user-data migration, automatic
removal and unconditional whole-Mac rollback remain outside scope. Revalidate
version-dependent settings when migration to macOS 27 actually occurs; it is not
the next functional checkpoint.
