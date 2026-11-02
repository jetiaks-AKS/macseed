# Macseed — Product Direction and Delivery Sequence

- **Decision date:** 2026-10-29
- **Revision:** 2026-11-02 — Native UI Alignment implemented and visually accepted
- **Status:** All native UI workflows visually accepted; local validation and Git checkpoint readiness remain separate from release qualification
- **Repository:** `jetiaks-AKS/macseed`
- **Working branch:** `develop`
- **Baseline at documentation review:** `fa464c48ef1fd42a4e7c79c7856729d516e4cdf7`
- **Published baseline for GUI realignment:** `ed521e7`; CI #127 successful

**Scope of this document:** Approved product positioning, priorities and deferrals. [Vision](VISION.md) owns enduring product principles; [Roadmap](../ROADMAP.md) owns current stage status and execution order; [TODO](../TODO.md) owns open actions. [Desktop](DESKTOP.md), [Capture / Restore](CAPTURE-RESTORE.md), [Core](core/APPLICATION-INTERFACE.md) and [Configuration](toolkit/CONFIGURATION.md) retain their implementation contracts. This dated decision record does not replace those owners.

> **Interpretation rule:** An approved product direction is not an implemented feature, a passed automated test, a real-Mac qualification, or release readiness. Preserve those distinctions in every document and UI claim.

## 1. Product promise

Macseed is a focused native macOS utility for **capturing, rebuilding, comparing and safely reapplying essential, supported working-environment state**. It should reduce setup work on a clean Mac while remaining useful on an existing Mac months or years later.

Its principal value is **fresh application/tool installation, supported macOS preference restoration and reusable Saved Environments**—not the number of developer-oriented domains supported.

**Tagline:** Capture. Rebuild. Continue.

Macseed is not a replacement for Migration Assistant, Time Machine, a filesystem backup, a complete Mac clone or a universal third-party application configuration migrator. Avoid stale caches, logs, sessions, unqualified preferences and broad copying of application data. Do not claim that an entire machine or application health is verified merely because supported requirements matched.

Macseed must remain maintainable by a small developer project. Prefer a reliable, limited end-to-end outcome over broad feature coverage and new frameworks.

## 2. Three equally important everyday workflows

1. **Save Your Setup (Capture):** Observe the supported current environment, let the user explicitly select meaningful items and categories, and save a private `.mbt` Saved Environment.
2. **Rebuild Your Setup (Restore):** On either a clean or an already-used Mac, inspect a selected `.mbt`, narrow its captured requirements, show a fresh non-mutating Preview, obtain confirmation, apply only safely actionable changes and verify the supported result. Matching state must be a no-op. An unsafe or ambiguous reinstall/repair must be declined, not forced.
3. **Compare Your Setup (Environment Status):** Compare a selected Saved Environment with the current Mac read-only. Explain confirmed matches, differences, missing items, unsupported coverage and observation uncertainty. Offer the already implemented handoff to Restore; the user must still inspect, select, preview and confirm. Reusing the *same* Saved Environment at a later date is a first-class workflow.

**Current implementation boundary:** Bundle-backed Status supports the bounded Workspace Topology comparison contract. [Roadmap](../ROADMAP.md#complete-workspace--git-worktree-restoration) records Phase 6 and accepted bounded Core E2E evidence, with same-Bundle native GUI, full SIGTERM recovery and packaged qualification still open. The [implemented handoff](DESKTOP.md#bundle-handoff) passes only the Bundle reference, without selecting differences or starting Prepare/Preview/Execute. Restore owns inspection, selection, Preview and confirmation; the same Bundle preserves its existing session. Status compares the complete saved reference, independently of Restore's local selection.

`.mbt` is a requirements/reference artifact, not an image of installed binaries, an offline installer collection or an archive of arbitrary working files. Restoring an older reference may use available current application versions and may expose macOS incompatibilities; those are coverage/compatibility outcomes, not reasons for destructive cleanup. Normal Bundle configuration is **not encrypted**. Only explicitly selected SSH identity payloads use the separate `age` encryption contract.

## 3. Product capabilities and visibility

| Area | Product decision | Implementation / qualification boundary |
| --- | --- | --- |
| Homebrew Casks | **Primary:** safe automatic fresh install and qualified repair | Use native Homebrew/qualified adapter behavior; no generic force reinstall or user-data removal. |
| Homebrew Formulae | **Primary:** restore selected tools/packages | Reuse existing Core and verification contracts. |
| App Store apps | **Primary:** Assisted Restore | User installs through App Store; Core observes and verifies. Do not revive automatic MASHelper/XPC work. |
| macOS Settings | **Primary:** maximize useful **reliably supported** settings | Extend by evidence, with honest stored-value vs effective-behavior Verification and cross-version compatibility. No undocumented/destructive shortcuts. |
| Saved Environment / Status | **Primary:** reusable reference, explicit comparison and manual reapplication | Preserve the existing Bundle V1 and Core pipeline. No auto cleanup, background drift daemon or separate comparison engine. |
| VS Code Settings / Extensions | **Application Extras → VS Code:** Extensions and Settings only | Independent item/category selection. New application support requires confirmed demand, a separate product decision, qualified Core support and tests; no placeholders or universal adapter framework. |
| Git configuration, repositories, linked worktrees | **Advanced — for experienced users** | Keep and qualify current supported scope. Do not reopen unlimited Git topology or transport coverage. |
| SSH configuration / selected SSH identities | **Advanced — for experienced users** | Keep limited SSH Host contract and optional separately encrypted identity migration; Desktop secret flow remains Stage 16H, not a shipped feature. |
| Zsh / Shell | **Advanced — for experienced users** | Retain bounded `.zshrc` contract and its explicit exclusions; do not modify user configurations just to satisfy Discovery. |
| `.code-workspace` descriptors | **HIDE / FREEZE for 1.0:** no ordinary promotion; explicit Advanced Capture and Restore selection, default OFF | Preserve Core, tests, Bundle V1, legacy selected-descriptor Restore, Verification and Status. No feature expansion or dependency auto-selection; only supported names/folder relationships. |
| Workspace Folders (structure only) | **Collapsed Advanced compatibility selector, default OFF; no ordinary promotion** | Preserve the Core domain, explicit folder-only Capture, descriptor dependencies and folder-only Bundle Restore selectors. Both accepted selection screens expose folders in Advanced. No general file-content migration. |
| Workspace file content transfer | **Deferred possible optional capability**, not required for 1.0 | Only after value, safety, provenance, conflict, permissions, privacy, and transport/storage contract assessment. No general folder migrator/backup. |
| Universal secrets / passwords / Keychain copy | **Out of scope** | Use existing Apple/third-party mechanisms. SSH identity transfer is a bounded separate exception, not a general vault. |
| Universal vendor app installers/config adapters | **Out of scope for 1.0** | Existing Stage 11 adapter decision remains deferred; avoid high-maintenance integration catalogs. |

<a id="4-native-desktop-presentation-direction--planned-not-implemented"></a>

## 4. Native Desktop presentation direction

The accepted native navigation is **Home**, **Save Your Setup**, **Rebuild Your Setup**
and **Compare Your Setup**. Home, Sidebar and workflow headers share the approved
names/descriptions; the tagline remains **Capture. Rebuild. Continue.** Compact
General Settings and standard About are available from native application menus,
with Settings also at the bottom of the sidebar and About in General. The
[Desktop UI contract](DESKTOP.md#macseed-native-ui--design--interaction-contract)
owns the implemented copy, measurements and interaction rules.

**Native UI Alignment is implemented and visually accepted on 2026-11-02.** The
accepted Minimal Premium foundation, Core V1 protocol, single-operation ownership
and Preview/Verification boundaries remain unchanged.

Capture and Restore Selection use one ordinary accordion:

- **Applications & Tools:** App Store, Homebrew Applications (Casks), Homebrew Packages (Formulae).
- **macOS Settings:** the existing supported domains.
- **Application Extras → VS Code:** Extensions retain item selection; Settings retains category selection.

A separate **Advanced — For Experienced Users** container exposes Git Configuration,
Git Repositories / Worktrees, Workspace Folders, SSH Configuration, Shell / Zsh and
VS Code Workspace when present. Capture keeps its unavailable Secure Transfer
presentation here; Secure SSH Desktop remains Stage 16H. Descriptors/folders remain
explicitly selectable under the frozen compatibility contract, without ordinary
promotion or dependency auto-selection.

**Selection policy — implemented in Capture and Restore:** eligible ordinary
requirements default ON; Advanced and unknown domains default OFF. Fresh Scan or
Bundle inspection starts disclosures collapsed. The four group headers and VS Code
have scoped tri-state masters, with separate ordinary/Advanced Expand/Collapse
controls. Checkbox and disclosure actions are independent. Back/Refresh preserve
explicit choices; selection changes require fresh preparation. Workspace Folders
is directly reachable in Advanced, including folder-only scope. Core owns dependency
validation; empty Advanced-only drafts do not automatically enable Preview.

The inspected Bundle is Restore's strict scope ceiling. Absent/excluded requirements
and empty groups are hidden; selected limitations remain explainable. Restore Preview
retains detailed planned/matching/attention evidence and prerequisites, with automatic
tasks grouped separately from manual App Store installation. It is read-only. Progress
and Result use flat ordered domain lists. Completed Result shows visible planned-and-
verified requirements and actual problems, omitting pre-existing matches; stopped
Result retains reported work and uncertainty without inventing unchecked failures.

**Environment Status intentionally differs:** static Applications & Tools, Settings,
Application Extras and For Experienced Users headings contain ordinary diagnostic
category rows. There is no parent VS Code/Advanced accordion or selection UI. It
compares the complete saved reference, including Advanced/descriptors, retaining
matching requirements, differences, attention and item-level details. Empty headings
are hidden; numeric rails adapt to visible badge combinations without changing counts.

VS Code and Advanced are presentation groups, never new Core domains. Core GROUPS,
Bundle ceilings, IDs, item/category modes, evidence and native accessibility semantics
remain intact. No new adapter, dependency engine, automatic Apply or extra wizard
follows from visual acceptance. Remaining capability/runtime/packaging qualification
is tracked separately in Roadmap and TODO.

## 5. Delivery sequence and gates

### Checkpoint 0 — Documentation first

Record this approved product direction in the authoritative repository docs. Align [Vision](VISION.md), [Roadmap](../ROADMAP.md), [TODO](../TODO.md), [Desktop](DESKTOP.md) and the [documentation index](README.md) with brief accurate references. Preserve historical completed stages and existing implementation boundaries. **No Core, SwiftUI or test changes in this checkpoint.** Do not publish new feature claims as completed.

### Checkpoint 1 — Workspace Phase 6: topology-aware Environment Status

Complete **read-only** comparison of supported Workspace Topology V1 Bundles, including the bounded base-repository/linked-worktree relationships and selected VS Code workspace descriptors where the existing supported contracts permit. Reuse the authoritative Core comparison and verification facts and the Desktop presentation model. Preserve legacy Bundle Status behavior and the explicit Status → Restore handoff. Unsupported cases must produce honest coverage/attention, not fabricated Match. No target mutation, no auto-select differences, no automatic Restore, and no new general file transfer.

Before implementation, perform a narrowly scoped contract/impact inspection; implement in a bounded slice with **focused tests for new functionality** and explicit unsupported/legacy cases. Do not make unrelated failing historical assertions the purpose of Phase 6.

### Checkpoint 2 — Workspace closure and real-world qualification

Complete representative controlled real-Mac Capture → Restore Preview → Execute → Global Verification → Status for supported topology, with preservation of tracked/staged/untracked/ignored files, branch occupancy/conflicts, interrupted/re-entry behavior and repeat/no-op. Qualify Phase 5 `.code-workspace` descriptor restoration where selected. Do not claim full workspace content migration. Do not broaden SSH transport, filters or Git LFS by default. Complete product-safe behavior before asserting Workspace feature readiness.

### Checkpoint 3 — Consolidated test/CI stabilization

The consolidated evidence assessment is accepted at `ed521e7` / [CI #127](https://github.com/jetiaks-AKS/macseed/actions/runs/40914838447): lint, four regression shards, Desktop and validate succeeded. Historical CI #123/#124 assertions were repaired; Capture inventory correspondence replaced the fixed event count in `a1fa2a5`. No active regression debt is established by those historical failures. Additional runs or repairs require current evidence or implementation changes; green CI does not close native/packaged qualification gates or prove future GUI behavior.

### Checkpoint 4 — Product Scope Revision / read-only impact audit

The revised read-only audit and 13-column impact matrix are approved. The accepted inventory, dependencies and compatibility analysis underpin section 4. The former ordinary VS Code descriptor placement and retain-all-defaults recommendation are superseded. Default-policy changes require bounded Desktop model work, with no Core/Bundle format change. Historical Stage 10/11/12 completion labels remain unchanged.

### Checkpoint 5 — Native UI Alignment: implemented and visually accepted

Home/Sidebar/Settings/About, Capture Selection/Confirmation/Result, Restore
Selection/Preview/Progress/completed and stopped Result, and Environment Status
have explicit user visual approval. Final naming is consistent throughout the native
application. The historical slice IDs are retained; no visual work remains in those
slices. Consolidated local validation and explicit Git approval establish checkpoint
readiness separately. This does not close remaining native lifecycle, capability or
packaged qualification, and adds no Core feature or parallel Restore model.

### Checkpoint 6 — Finish remaining Stage 16 qualification

Resume the remaining mandatory supported-domain work based on the narrowed product priorities: Homebrew real install/repair qualification, macOS Settings stored/effective behavior, supported Zsh/SSH/Git configuration, VS Code dependencies, optional Secure SSH Desktop (16H), completion (16I), integration/runtime hardening (16K) and bounded Stage 3C re-entry/recovery. Distinguish critical release gates from optional Advanced refinements. Update TODO according to measured value and risk; do not expand feature breadth automatically.

### Checkpoint 7 — Stage 17, Early Access and Macseed 1.0

Produce a correctly bundled, writable-runtime-safe, signed/notarized app; prove clean-Mac Capture/Restore/Status on supported Apple Silicon and qualify Intel independently before claiming support. Conduct a small external Early Access (Roadmap proposes approximately 10–20 technical users), fix validated UX/compatibility problems and release only against documented scope.

### After 1.0 — optional, demand-driven

Possible Saved Environment history/profiles, confirmed-difference preselection for Restore, semantic drift workflows and bounded selected folder-content transfer. These should reuse Core and the existing **Prepare → Preview → Confirm → Execute → Verify** path, not introduce a parallel configuration engine. No background monitoring, extra database or universal migration capability without a demonstrated need.

## 6. Working and release discipline

- **One bounded checkpoint at a time:** read/audit contracts → address the selected scope → focused tests → inspect diffs → record accepted evidence → move to next checkpoint.
- **CI strategy:** use proportional focused verification for each implementation slice and canonical validation at closure. CI #127 is the published baseline, not validation of subsequent changes. Never omit changed-behavior tests or treat historical failures as active debt without evidence.
- **Documentation truth:** [Roadmap](../ROADMAP.md) records outcomes/stage status, [TODO](../TODO.md) concrete open actions, [Desktop](DESKTOP.md) as-implemented UX and planned changes clearly separated, [Changelog](../CHANGELOG.md) only completed release-visible work. This document records product decisions and their agreed sequence; Roadmap tracks execution.
- **Git:** work on `develop`; preserve `main`, released history and all local commits. Avoid force-push, destructive reset and unreviewed cross-cutting changes. A documentation-only local commit may be kept unpushed and later published with validated implementation to avoid unnecessary hosted CI cycles.
- **Privacy and safety:** no implicit deletions; Bundle ordinary metadata is private but not encrypted; SSH private identity migration requires explicit consent and its separate encrypted contract. Do not weaken idempotency, failure-state honesty or conflict preservation for UI convenience.

## 7. Next action

Close the accepted UI Alignment checkpoint with synchronized owner documentation,
one consolidated local validation and an accumulated-diff review. Commit/push requires
separate explicit approval; visual acceptance does not imply hosted validation.
After checkpoint approval, follow Roadmap's remaining Stage 16 priorities without
reopening accepted UI or automatically beginning Stage 17, performance optimization,
new Core capabilities or workspace content transfer.
