# Roadmap

Major stages and product outcomes. Detailed contracts belong to the
[documentation](docs/README.md), unfinished actions to [TODO](TODO.md), and
implementation/release history to [Changelog](CHANGELOG.md).

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
| 11 — Application Configuration Modules | Audited / Deferred | No additional adapters justified by the assessed portability, privacy and value |
| 12 — Secure Migration Engine | Completed v1; release 3.3.0 | Explicit encrypted SSH identity transfer and one-Bundle Capture / Restore |

Additional tool managers and generic PATH/binary restoration are outside the
completed developer-environment scope. Application adapters may be reconsidered
when a specific safe portable contract has enough user value; the Stage 11
assessment does not prohibit such extensions. Existing VS Code support remains.

## Stage 13 — Reporting & Global Verification

**Completed.** Reports selected requirements, conformity and verification gaps
after Bootstrap, Workflow and applicable Restore, separately from operation
outcomes. It does not claim whole-Mac identity or application runtime health.

## Stage 14 — Environment Comparison

**Completed.** Explicit read-only comparison with the current Mac, including
informational extras where source completeness and target enumeration are
proven. No cleanup or removal behavior.

## Stage 15 — Core Application Interface

**Completed.** Protocol V1 exposes capabilities, Bundle inspection, Capture
preparation/execution, Restore preparation/execution and Environment Status.
The interface reuses production Core behavior, reports structured progress and
verification, protects secrets, and revalidates plans before mutation.
See the [Core reference](docs/core/APPLICATION-INTERFACE.md).

This completes the application-facing contract; application runtime integration
and packaged clean-Mac qualification remain the next stages.

## Stage 16 — Native Macseed Desktop

**Product/UX contract defined (16A); native sample-data foundation implemented
(16B); runtime (16C) and Environment Status (16D) manually approved; real Capture
(16E), Restore Prepare (16F) and Restore execution (16G) manually approved. The
Restore presentation/recovery and Homebrew compatibility advanced substantially
through checkpoint `08e2b469`: real Restore converged to a fresh Everything Already
Matches Preview, including clean Tailscale Install and matching observation.
Capture UI is finalized and manually qualified for full/partial selection,
publication with/without warnings, cancellation and stale preparation/re-scan.
Macseed Minimal Premium, the leaf logo/system App Icon, Home, Sidebar, Settings
and adaptive tiles are finalized and user-approved. Capture was checked on a real
Mac; Restore Selection, Preview, Progress and Result are approved. Further Desktop
functional development and qualification remain open. Bundle-backed Environment
Status (16K) is complete in `c529092`; the subsequent Status → Restore Bundle
handoff is implemented and GUI-approved as a separate follow-up.
Remaining Stage 16 qualification is open.** The base SwiftUI Capture, Restore and
Environment Status flows are implemented and have passed their corresponding GUI
acceptance. Stage 16 remains unfinished: Cancellation Safety, Logging & Diagnostics,
Secure SSH, MAS and further functional qualification are still ahead.
Desktop Secure SSH Capture/Restore remains unfinished (16H). Deliver persistent
structured operation logs, live View Log and a redacted Diagnostic Report with
exact preview/export. Desktop Visual Unification is complete. Restore Cancellation
Safety is the next standalone checkpoint; Operation Logging & Diagnostics follows
with a separate architecture audit. The Unified UI
Scenario Catalog remains deferred UI/dev tooling, with a possible Lite version
after functional priorities; existing Debug previews and fixtures are retained.
Automatic MAS Restore is mandatory before 1.0; authorization/install qualification
remains unresolved. Homebrew now primarily needs continuing compatibility
qualification/maintenance over the established capability-based boundary; it is
not the primary architecture blocker. Ambiguous/damaged privileged Repair states
remain fail-closed; clean Tailscale Install does not qualify universal Repair. Investigate
useful bounded Workspace/Data semantics while preserving today's structure-only
Folders behavior. Close the existing SSH/Zsh/Git/VS Code/macOS Settings and
application-state gaps according to their value and safety contracts. Detailed
actions and qualification evidence belong to [TODO](TODO.md).
Saved Environment/Bundle-backed Status now replaces the internal reference picker
(see [Desktop](docs/DESKTOP.md#environment-status)).

This stage defines and implements bundled Core/runtime placement, writable
application state, a controlled child environment and the Swift Protocol V1
launcher. It must qualify the Core/Python and age/OpenSSH integration needed by
the application. See [Desktop](docs/DESKTOP.md).

### Current practical execution order

Existing Stage 16 slice identifiers (16H Secure SSH, 16I completion, 16J diagnostics,
16K hardening) retain their historical meaning; they do not prescribe today's
implementation order. Complete one bounded checkpoint at a time:

1. [Restore Cancellation Safety](docs/DESKTOP.md#restore-cancellation-safety): qualify
   interrupted installers, operation-owned DMG handling, process quiescence and safe re-entry.
2. Desktop Operation Logging & Diagnostics: first audit the two existing logging levels.
3. Automatic MAS Restore qualification, mandatory before 1.0.
4. Secure SSH Desktop integration (16H) over the existing Core engine.
5. Compatibility & Reliability: remaining Result, Zsh, Homebrew/Repair, watchdog,
   partial/interrupted operations, stale plans, Workspace review, functional
   consistency, accessibility and runtime hardening.
6. Stage 17 Distribution & Clean-Mac Qualification: private writable runtime/workspace,
   signing, Hardened Runtime, notarization/stapling, DMG, Gatekeeper, clean Apple
   Silicon and separate Intel qualification where support is claimed.
7. Early Access / Alpha.
8. Macseed 1.0.

Status must compare the current Mac with a Saved Environment (`.mbt`), using the
existing Core comparison engine and source selection/Blueprint semantics. The
Restored Saved Environment is its natural reference. Keep Status read-only, unknown
evidence truthful and the Bundle format unchanged; do not parse Bundles in SwiftUI.
Any minimal Protocol V1 extension requires technical audit first.

Logging retains two independent levels: existing Core/CLI technical logs and a
private persistent Desktop Operation Log over structured Protocol V1 events.
Audit their diagnostic completeness and safe correlation before implementation;
never replace the Core logger, merge raw logs/events or introduce a third subsystem.
See the [Desktop logging contract](docs/DESKTOP.md#local-logs-and-diagnostic-report).

## Stage 17 — Distribution & Clean-Mac E2E

**Planned.** Deliver and qualify the application through Developer ID signing,
Hardened Runtime, notarization, stapling, DMG and Gatekeeper validation. Prove
packaged runtime behavior and Capture → Restore → Verify on clean Apple Silicon
hardware; qualify Intel separately where support is intended.
Validate operation logging, interruption details and Diagnostic Report
preview/export and privacy in the signed/notarized application and clean-Mac flow.
See [Distribution](docs/DISTRIBUTION.md).

The first complete native Desktop release is planned as **Macseed 1.0**, built on
the mature toolkit/CLI v1.x–v3.4.x Core. Current Core/CLI version is 3.4.0; published
versions and tags retain their historical meaning. No release date is promised.

Before public 1.0 launch, run an **Early Access/Alpha** with approximately 10–20
technical external users exercising real Capture/Restore workflows. Collect
voluntarily shared privacy-safe diagnostic reports/issues and resolve real-world
compatibility and UX problems. This is a product validation milestone.

## Later directions

### Environment Manager — Post-1.0 / Future Direction

Bundle-backed Environment Status is the foundation for a future Macseed
Environment Manager: management of supported Mac environment state beyond
Capture → Rebuild → Verify. This direction has no committed schedule or release
scope and does not expand current Stage 16 work.

Potential capabilities are independent **Profiles** (Main, Development, Minimal
and user-defined), **Environment History** of saved states/snapshots, **Semantic
Comparison** with a chosen profile/snapshot, **Drift Detection**, **Selective Apply**
of explicitly selected differences, and subsequent **Verification** through Core.

Profiles and History should build on the existing Saved Environment model;
a separate configuration system requires demonstrated justification. Allow multiple
reference environments rather than permanently assuming one global `.mbt`.
Completed Stage 16K covers Bundle selection and safe read-only comparison using
the existing Core engine and Blueprint selection semantics, and the Restored Bundle
as a natural reference. The subsequent handoff passes only the Bundle into existing
Restore selection; it does not automatically select differences. Profiles, History,
Drift Detection and Selective Apply are future capabilities, not part of that implementation; introduce no profile storage,
database, versioning or new Core entities without a current need.

Comparison remains read-only. Future targeted restoration initiated from Status
must use the existing **Restore Prepare → Preview → Confirm → Execute → Verify**
path with explicit user selection and confirmation, never a second Restore or
Verification engine. Absence from a profile does not authorize deletion from the Mac.

Direct/vendor application restoration is a distant possibility requiring separate
value, provenance, security and maintenance assessment, not a current subsystem or
task. Further secure migration and application adapters likewise require bounded
value and safety assessment. A plugin framework is not currently planned.
Arbitrary user-data migration, full cloning and automatic removal of extra state
remain outside product scope.

Revalidate version-dependent settings when the actual migration to macOS 27
occurs; this is a compatibility milestone, not the next product stage.
