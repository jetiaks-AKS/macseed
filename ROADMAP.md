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
broad Restore gate substantially passed at checkpoint `3e555fba`; compatibility
and remaining qualification are open.** Complete the SwiftUI client for
Capture this Mac, Restore a Mac and Environment Status.
Provide prerequisite guidance, Check Again, structured
progress/results, separate secret input and cancellation over the existing Core.
Desktop Secure SSH Capture/Restore remains unfinished (16H). Deliver persistent
structured operation logs, live View Log and a redacted Diagnostic Report with
exact preview/export. The next UX outcome is a reusable unified Macseed design
system, first applied to Restore, then Capture, Environment Status, All Tasks and
Settings, with Domain → Items shared across Preview/Rebuild/Verification/Result.
Automatic MAS Restore is mandatory before 1.0; authorization/install qualification
remains unresolved. Continue representative qualification of existing Homebrew
coverage over the established capability-based compatibility boundary. Investigate
useful bounded Workspace/Data semantics while preserving today's structure-only
Folders behavior. Close the existing SSH/Zsh/Git/VS Code/macOS Settings and
application-state gaps according to their value and safety contracts. Detailed
actions and qualification evidence belong to [TODO](TODO.md).
Complete Saved Environment/Bundle-backed Status before 1.0; the current internal
reference picker is a temporary development bridge (see [Desktop](docs/DESKTOP.md)).

This stage defines and implements bundled Core/runtime placement, writable
application state, a controlled child environment and the Swift Protocol V1
launcher. It must qualify the Core/Python and age/OpenSSH integration needed by
the application. See [Desktop](docs/DESKTOP.md).

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

Post-1.0 possibilities include environment snapshots/history, semantic comparison
and change detection, profiles, selective restore and a broader Environment Manager
direction. Preserve these as ideas only; no design or schedule is committed.
Direct/vendor application restoration is a distant possibility requiring separate
value, provenance, security and maintenance assessment, not a current subsystem or
task. Further secure migration and application adapters likewise require bounded
value and safety assessment. A plugin framework is not currently planned.
Arbitrary user-data migration, full cloning and automatic removal of extra state
remain outside product scope.

Revalidate version-dependent settings when the actual migration to macOS 27
occurs; this is a compatibility milestone, not the next product stage.
