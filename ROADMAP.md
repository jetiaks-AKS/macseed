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
| 11 — Application Configuration Modules | Audited / Deferred | No additional adapters justified by the assessed portability, privacy and value |
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
identifiers, not execution order.

| Direction / slice | Status | Outcome / remaining boundary |
|---|---|---|
| 16A — Product / UX contract | Defined | Native Protocol V1 client; Core remains authoritative |
| 16B — Native shell and design | Completed | Approved Minimal Premium, navigation, shared components and Debug fixtures |
| 16C — Runtime and capabilities | Implemented; hardening open | Owned Core processes and validated transport; packaged writable workspace unqualified |
| 16D — Environment Status | Completed | Read-only comparison; Saved Environment reference and Restore handoff accepted |
| 16E — Capture | Completed in supported scope | Real inventory/selection, preparation and publication; secure interaction remains 16H |
| 16F — Restore preparation | Completed in supported scope | Inspection, selection, prerequisites and fresh Preview |
| 16G — Restore execution | Implemented; qualification open | Core Rebuild/Verification; Cask requirements, MAS and interruption/re-entry gaps remain |
| 16H — Secure SSH interactions | Open | Desktop FD/challenge bridge and secure Capture/Restore qualification |
| 16I — Verification and completion | Partially complete | Existing Result contract implemented; final category/item UI and completion qualification remain |
| 16J — Logging & Diagnostics | Completed | Typed persistent logs, history, Important/All and immutable Diagnostic Report preview/copy/save |
| 16K — Desktop integration hardening | Partially complete | Bundle-backed Status completed; runtime, transport, security, accessibility and packaged-state hardening remain |
| Visual Unification | Completed | Approved shared style; remaining functional Result UI is a separate bounded task |
| Restore Cancellation Safety | Partially complete | Stage 1–2 fail-closed handling and limited Homebrew Graceful Stop implemented; Stage 3C and installer quiescence open |
| Unified UI Scenario Catalog | Deferred tooling | Existing Debug fixtures retained; optional Lite catalog after functional priorities |

Stage 16J is closed by this documentation iteration. It preserves two independent
levels: Core/CLI technical logs and private Desktop operation records. Reports are
privacy-safe projections of Desktop evidence, not complete Core logs or recovery
journals. Local validation and manually accepted Operation Logs UX are documented
in [Desktop](docs/DESKTOP.md#local-logs-and-diagnostic-report); report-panel manual
checks and signed/clean-Mac qualification remain separate.

<a id="current-practical-execution-order"></a>

## Current Execution Order

Complete one bounded checkpoint at a time:

1. **Stage 16J — closed:** Logging & Diagnostics implementation, local validation
   and documentation are complete; retain the recorded qualification limits.
2. **Homebrew Cask / Tailscale:** investigate and fix unsupported execution
   requirements, including `tailscale-app` installation on a clean Mac. Prior
   successful Install evidence does not qualify all current metadata or Repair.
3. **Restore Final Result UI:** reuse Environment Status's expandable categories,
   item results, counts and truthful statuses. Running categories stay collapsed;
   terminal categories expose details. Qualify Working · Needs Attention everywhere
   applicable without changing Core result/Verification semantics.
4. **MAS automatic restoration and remaining Restore functionality:** safely
   qualify App Store authorization/install; automatic MAS Restore is mandatory
   before 1.0. Complete Secure SSH Desktop integration (16H) and remaining
   supported-domain gaps through the existing Core.
5. **Reliability / security:** Stage 3C Cask interruption/recovery safety, installer
   and privileged-process quiescence, remaining Homebrew/Repair, Zsh, watchdog,
   partial/interrupted Verification, stale plans, Workspace review, accessibility
   and Runtime hardening. No diagnostic log substitutes for recovery authority.
6. **Stage 17 — Distribution & Clean-Mac Qualification.**
7. **Early Access / Alpha.**
8. **Macseed 1.0.**

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
planned. Full cloning, general backup, arbitrary user-data migration and automatic
removal remain outside scope. Revalidate version-dependent settings when migration
to macOS 27 actually occurs; it is not the next functional checkpoint.
