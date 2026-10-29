# Macseed — Product Direction and Delivery Sequence

- **Decision date:** 2026-10-29
- **Status:** Product direction agreed; implementation and GUI changes pending
- **Repository:** `jetiaks-AKS/macseed`
- **Working branch:** `develop`
- **Baseline at documentation review:** `fa464c48ef1fd42a4e7c79c7856729d516e4cdf7`

**Scope of this document:** Approved product positioning, priorities and deferrals. [Vision](VISION.md) owns enduring product principles; [Roadmap](../ROADMAP.md) owns current stage status and execution order; [TODO](../TODO.md) owns open actions. [Desktop](DESKTOP.md), [Capture / Restore](CAPTURE-RESTORE.md), [Core](core/APPLICATION-INTERFACE.md) and [Configuration](toolkit/CONFIGURATION.md) retain their implementation contracts. This dated decision record does not replace those owners.

> **Interpretation rule:** An approved product direction is not an implemented feature, a passed automated test, a real-Mac qualification, or release readiness. Preserve those distinctions in every document and UI claim.

## 1. Product promise

Macseed is a focused native macOS utility for **capturing, rebuilding, comparing and safely reapplying essential, supported working-environment state**. It should reduce setup work on a clean Mac while remaining useful on an existing Mac months or years later.

Its principal value is **fresh application/tool installation, supported macOS preference restoration and reusable Saved Environments**—not the number of developer-oriented domains supported.

**Tagline:** Capture. Rebuild. Continue.

Macseed is not a replacement for Migration Assistant, Time Machine, a filesystem backup, a complete Mac clone or a universal third-party application configuration migrator. Avoid stale caches, logs, sessions, unqualified preferences and broad copying of application data. Do not claim that an entire machine or application health is verified merely because supported requirements matched.

Macseed must remain maintainable by a small developer project. Prefer a reliable, limited end-to-end outcome over broad feature coverage and new frameworks.

## 2. Three equally important everyday workflows

1. **Capture this Mac:** Observe the supported current environment, let the user explicitly select meaningful items and categories, and save a private `.mbt` Saved Environment.
2. **Restore a Mac:** On either a clean or an already-used Mac, inspect a selected `.mbt`, narrow its captured requirements, show a fresh non-mutating Preview, obtain confirmation, apply only safely actionable changes and verify the supported result. Matching state must be a no-op. An unsafe or ambiguous reinstall/repair must be declined, not forced.
3. **Environment Status:** Compare a selected Saved Environment with the current Mac read-only. Explain confirmed matches, differences, missing items, unsupported coverage and observation uncertainty. Offer the already implemented handoff to Restore; the user must still inspect, select, preview and confirm. Reusing the *same* Saved Environment at a later date is a first-class workflow.

**Implementation boundary at review:** Existing Bundle-backed Status and its `Review in Restore` handoff operate within their documented supported Bundle scope. New Workspace Topology Bundles are not yet supported by Environment Status. The handoff passes only the Bundle reference, without selecting differences or starting Prepare/Preview/Execute. Restore owns inspection, selection, Preview and confirmation under its normal session/freshness rules; the same Bundle preserves its existing session. See the [implemented handoff](DESKTOP.md#bundle-handoff). Phase 6 is intended to address topology-aware Status, not to silently add automatic selective Apply.

`.mbt` is a requirements/reference artifact, not an image of installed binaries, an offline installer collection or an archive of arbitrary working files. Restoring an older reference may use available current application versions and may expose macOS incompatibilities; those are coverage/compatibility outcomes, not reasons for destructive cleanup. Normal Bundle configuration is **not encrypted**. Only explicitly selected SSH identity payloads use the separate `age` encryption contract.

## 3. Product capabilities and visibility

| Area | Product decision | Implementation / qualification boundary |
| --- | --- | --- |
| Homebrew Casks | **Primary:** safe automatic fresh install and qualified repair | Use native Homebrew/qualified adapter behavior; no generic force reinstall or user-data removal. |
| Homebrew Formulae | **Primary:** restore selected tools/packages | Reuse existing Core and verification contracts. |
| App Store apps | **Primary:** Assisted Restore | User installs through App Store; Core observes and verifies. Do not revive automatic MASHelper/XPC work. |
| macOS Settings | **Primary:** maximize useful **reliably supported** settings | Extend by evidence, with honest stored-value vs effective-behavior Verification and cross-version compatibility. No undocumented/destructive shortcuts. |
| Saved Environment / Status | **Primary:** reusable reference, explicit comparison and manual reapplication | Preserve the existing Bundle V1 and Core pipeline. No auto cleanup, background drift daemon or separate comparison engine. |
| VS Code Settings / Extensions | **Optional Application Extras:** keep existing supported scope | Do not promise an adapter catalog. Assess other applications separately only if evidence warrants it. |
| Git configuration, repositories, linked worktrees | **Advanced — for experienced users** | Keep and qualify current supported scope. Do not reopen unlimited Git topology or transport coverage. |
| SSH configuration / selected SSH identities | **Advanced — for experienced users** | Keep limited SSH Host contract and optional separately encrypted identity migration; Desktop secret flow remains Stage 16H, not a shipped feature. |
| Zsh / Shell | **Advanced — for experienced users** | Retain bounded `.zshrc` contract and its explicit exclusions; do not modify user configurations just to satisfy Discovery. |
| `.code-workspace` descriptors | **Advanced:** preserve completed bounded implementation | Only supported names/folder relationships; arbitrary settings, launch and tasks data are not transferred. |
| Workspace Folders (structure only) | **Not a valuable standalone everyday feature:** hide from ordinary UX **after dependency/impact audit** | Do not delete current Core contract or break Git/descriptor dependencies. No UI change has been implemented by this decision. |
| Workspace file content transfer | **Deferred possible optional capability**, not required for 1.0 | Only after value, safety, provenance, conflict, permissions, privacy, and transport/storage contract assessment. No general folder migrator/backup. |
| Universal secrets / passwords / Keychain copy | **Out of scope** | Use existing Apple/third-party mechanisms. SSH identity transfer is a bounded separate exception, not a general vault. |
| Universal vendor app installers/config adapters | **Out of scope for 1.0** | Existing Stage 11 adapter decision remains deferred; avoid high-maintenance integration catalogs. |

## 4. Native Desktop presentation direction — planned, not implemented

Retain the established three destinations: **Capture this Mac**, **Restore a Mac**, **Environment Status**. Retain the accepted Minimal Premium foundation, existing Core V1 protocol, single-operation and Preview/Verification boundaries.

Within Capture, Restore and Status, favor consistent, understandable groupings:

- **Applications & Tools:** App Store, Homebrew Applications (Casks), Homebrew Packages (Formulae).
- **macOS Settings:** Finder, Dock, Windows, Keyboard, Trackpad, Screenshots and later carefully qualified additions.
- **Application Extras:** existing VS Code Extensions and Settings; no implied future app support commitment.
- **Advanced — For experienced users** (collapsed/opt-in): Git, SSH, Shell, Repositories, Worktrees, bounded VS Code workspace descriptors and optional Secure Transfer when implemented in Desktop.

These are **planned information architecture decisions**, not permission to change the current selection behavior before impact analysis. Grouping must not compromise Core item/category selection modes, source-selection ceilings, dependencies, accessibility, Preview, independent verification, legacy Bundles or the already accepted UX. A separate Advanced engine, permanent expert-mode fork or additional wizard screens are not desired.

## 5. Delivery sequence and gates

### Checkpoint 0 — Documentation first

Record this approved product direction in the authoritative repository docs. Align [Vision](VISION.md), [Roadmap](../ROADMAP.md), [TODO](../TODO.md), [Desktop](DESKTOP.md) and the [documentation index](README.md) with brief accurate references. Preserve historical completed stages and existing implementation boundaries. **No Core, SwiftUI or test changes in this checkpoint.** Do not publish new feature claims as completed.

### Checkpoint 1 — Workspace Phase 6: topology-aware Environment Status

Complete **read-only** comparison of supported Workspace Topology V1 Bundles, including the bounded base-repository/linked-worktree relationships and selected VS Code workspace descriptors where the existing supported contracts permit. Reuse the authoritative Core comparison and verification facts and the Desktop presentation model. Preserve legacy Bundle Status behavior and the explicit Status → Restore handoff. Unsupported cases must produce honest coverage/attention, not fabricated Match. No target mutation, no auto-select differences, no automatic Restore, and no new general file transfer.

Before implementation, perform a narrowly scoped contract/impact inspection; implement in a bounded slice with **focused tests for new functionality** and explicit unsupported/legacy cases. Do not make unrelated failing historical assertions the purpose of Phase 6.

### Checkpoint 2 — Workspace closure and real-world qualification

Complete representative controlled real-Mac Capture → Restore Preview → Execute → Global Verification → Status for supported topology, with preservation of tracked/staged/untracked/ignored files, branch occupancy/conflicts, interrupted/re-entry behavior and repeat/no-op. Qualify Phase 5 `.code-workspace` descriptor restoration where selected. Do not claim full workspace content migration. Do not broaden SSH transport, filters or Git LFS by default. Complete product-safe behavior before asserting Workspace feature readiness.

### Checkpoint 3 — Consolidated test/CI stabilization

Repair known stale regression/Swift test assumptions in one scoped stabilization effort, and diagnose any actual production issues separately. CI #123 legacy item-scope assertion fixes landed in `fa464c4` after Desktop `ca45fd3`. [CI #124 Desktop](https://github.com/jetiaks-AKS/macseed/actions/runs/40832024401/job/123308547377) failed at `CaptureTests.swift:532`, whose assertion still hard-codes `16` capture events; verify the exact contract before changing it. [TODO](../TODO.md#consolidated-testci-stabilization) tracks this debt. This documentation checkpoint makes no claim about the other CI #124 jobs or final aggregate result.

Run focused affected suites and **the entire Desktop gate including suites previously hidden by an earlier failure** before an intentionally consolidated hosted CI. Do not weaken assertions, silently skip tests or change CI workflow merely to obtain green status. Avoid repeated long hosted runs for small intermediate changes.

### Checkpoint 4 — Product Scope Revision / read-only impact audit

Audit all current Core/Desktop categories, dependencies, selection modes, Status and Bundle compatibility, and the accepted GUI. Produce a decision/impact matrix: retain primary, group under Application Extras, move to Advanced, hide empty Workspace Folders after dependency checks, freeze growth, or defer. Assess whether simple proposed GUI grouping works without model/protocol changes. **Audit first; no GUI or Core rewrite in the audit checkpoint.** Historical Stage 10/11/12 completion labels remain unchanged.

### Checkpoint 5 — Small-scope UX realignment

Implement the approved grouping consistently across Capture/Restore/Status and label Advanced appropriately. Hide the standalone empty Workspace Folders from ordinary UX only when dependencies and compatibility have been proven safe. Preserve existing working flows and tested selection semantics. Do not introduce Profiles/History/automatic drift monitors, automatic selective Apply or a second Restore model.

### Checkpoint 6 — Finish remaining Stage 16 qualification

Resume the remaining mandatory supported-domain work based on the narrowed product priorities: Homebrew real install/repair qualification, macOS Settings stored/effective behavior, supported Zsh/SSH/Git configuration, VS Code dependencies, optional Secure SSH Desktop (16H), completion (16I), integration/runtime hardening (16K) and bounded Stage 3C re-entry/recovery. Distinguish critical release gates from optional Advanced refinements. Update TODO according to measured value and risk; do not expand feature breadth automatically.

### Checkpoint 7 — Stage 17, Early Access and Macseed 1.0

Produce a correctly bundled, writable-runtime-safe, signed/notarized app; prove clean-Mac Capture/Restore/Status on supported Apple Silicon and qualify Intel independently before claiming support. Conduct a small external Early Access (Roadmap proposes approximately 10–20 technical users), fix validated UX/compatibility problems and release only against documented scope.

### After 1.0 — optional, demand-driven

Possible Saved Environment history/profiles, confirmed-difference preselection for Restore, semantic drift workflows and bounded selected folder-content transfer. These should reuse Core and the existing **Prepare → Preview → Confirm → Execute → Verify** path, not introduce a parallel configuration engine. No background monitoring, extra database or universal migration capability without a demonstrated need.

## 6. Working and release discipline

- **One bounded checkpoint at a time:** read/audit contracts → address the selected scope → focused tests → inspect diffs → record accepted evidence → move to next checkpoint.
- **CI strategy:** while Phase 6 is underway, use proportional focused verification for the new behavior; defer existing unrelated CI assertion churn to Checkpoint 3. Never omit tests of newly changed functionality or interpret a failing run as release readiness.
- **Documentation truth:** [Roadmap](../ROADMAP.md) records outcomes/stage status, [TODO](../TODO.md) concrete open actions, [Desktop](DESKTOP.md) as-implemented UX and planned changes clearly separated, [Changelog](../CHANGELOG.md) only completed release-visible work. This document records product decisions and their agreed sequence; Roadmap tracks execution.
- **Git:** work on `develop`; preserve `main`, released history and all local commits. Avoid force-push, destructive reset and unreviewed cross-cutting changes. A documentation-only local commit may be kept unpushed and later published with validated implementation to avoid unnecessary hosted CI cycles.
- **Privacy and safety:** no implicit deletions; Bundle ordinary metadata is private but not encrypted; SSH private identity migration requires explicit consent and its separate encrypted contract. Do not weaken idempotency, failure-state honesty or conflict preservation for UI convenience.

## 7. Next action

After completing Checkpoint 0, prepare a narrow Phase 6 implementation task based on the current Core comparison and Workspace topology contracts. The documentation checkpoint itself authorizes no implementation. Do not start GUI realignment, workspace content transfer, broad developer-environment expansions or general CI refactoring during it.
