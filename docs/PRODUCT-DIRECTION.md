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

**Tagline:** A smarter way to capture, rebuild, and check your Mac setup.

Macseed is not a replacement for Migration Assistant, Time Machine, a filesystem backup, a complete Mac clone or a universal third-party application configuration migrator. Avoid stale caches, logs, sessions, unqualified preferences and broad copying of application data. Do not claim that an entire machine or application health is verified merely because supported requirements matched.

Macseed must remain maintainable by a small developer project. Prefer a reliable, limited end-to-end outcome over broad feature coverage and new frameworks.

## 2. Three equally important everyday workflows

1. **Capture:** Observe the supported current environment, let the user explicitly select meaningful items and categories, and save a private `.mbt` Saved Environment.
2. **Rebuild (Restore):** On either a clean or an already-used Mac, inspect a selected `.mbt`, narrow its captured requirements, show a fresh non-mutating Preview, obtain confirmation, apply only safely actionable changes and verify the supported result. Matching state must be a no-op. An unsafe or ambiguous reinstall/repair must be declined, not forced.
3. **Check (Environment Status):** Compare a selected Saved Environment with the current Mac read-only. Explain confirmed matches, differences, missing items, unsupported coverage and observation uncertainty. Offer the already implemented handoff to Restore; the user must still inspect, select, preview and confirm. Reusing the *same* Saved Environment at a later date is a first-class workflow.

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
| SSH configuration / selected SSH identities | **Advanced / Secure Transfer — for experienced users** | Keep SSH configuration in Advanced and Capture identities in its independent Secure Transfer sibling. Keep the limited Host contract and separately encrypted, strictly opt-in/default-off identity migration. Stage 16H SSH Identities is completed and manually accepted with native Secure Capture, whole-package Restore and bundled age v1.3.2; all identities currently restore to `~/.ssh`. SSH Configuration/destination completion is next, not implemented. |
| Zsh / Shell | **Advanced — for experienced users** | Retain bounded `.zshrc` contract and its explicit exclusions; do not modify user configurations just to satisfy Discovery. |
| `.code-workspace` descriptors | **HIDE / FREEZE for 1.0:** no ordinary promotion; explicit Advanced Capture and Restore selection, default OFF | Preserve Core, tests, Bundle V1, legacy selected-descriptor Restore, Verification and Status. No feature expansion or dependency auto-selection; only supported names/folder relationships. |
| Workspace Folders (structure only) | **Collapsed Advanced compatibility selector, default OFF; no ordinary promotion** | Preserve the Core domain, explicit folder-only Capture, descriptor dependencies and folder-only Bundle Restore selectors. Both accepted selection screens expose folders in Advanced. No general file-content migration. |
| Workspace file content transfer | **Deferred possible optional capability**, not required for 1.0 | Only after value, safety, provenance, conflict, permissions, privacy, and transport/storage contract assessment. No general folder migrator/backup. |
| Universal secrets / passwords / Keychain copy | **Out of scope** | Use existing Apple/third-party mechanisms. SSH identity transfer is a bounded separate exception, not a general vault. |
| Universal vendor app installers/config adapters | **Out of scope for 1.0** | Existing Stage 11 adapter decision remains deferred; avoid high-maintenance integration catalogs. |

<a id="4-native-desktop-presentation-direction--planned-not-implemented"></a>

## 4. Native Desktop presentation direction

The accepted native navigation is **Home**, **Capture**, **Rebuild**
and **Check**. Home, Sidebar and workflow headers share the approved
names/descriptions; the tagline is **A smarter way to capture, rebuild, and check your Mac setup.**
Compact General Settings and standard About are available from native application menus,
with Settings also at the bottom of the sidebar and About in General. Settings now
has General, Tools & Dependencies, and Operation Logs tabs; Tools & Dependencies
reuses Homebrew controls and adds read-only bundled age diagnostics. This Settings
checkpoint is implemented locally; its native visual acceptance remains pending.
A separate Updates tab is approved future functionality: manual check/review and
confirmed installation, configurable background checking, and automatic installation
only with an explicit approved preference and safe lifecycle. Whole-app replacement,
operation deferral and Stage 17 dependencies belong to the
[distribution contract](DISTRIBUTION.md#future-whole-application-updates); no updater
or placeholder tab is implemented. The
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
VS Code Workspace when present. Under **For Experienced Users**, Capture and Restore place
explicit, default-off **Secure Transfer** directly below **Advanced** as an independent
sibling, with no shared selector. Restore selects the encrypted SSH package as a whole. Descriptors/folders remain
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
and empty groups are hidden; selected limitations remain explainable. Rebuild Preview
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

The checkpoint IDs below preserve the approved historical slices. [Roadmap's current
execution order](../ROADMAP.md#current-practical-execution-order) owns the remaining
Macseed 1.0 sequence; completed checkpoints are not new implementation or rerun tasks.

### Checkpoint 0 — Documentation first

The approved product direction is recorded in the authoritative repository docs.
Keep [Vision](VISION.md), [Roadmap](../ROADMAP.md), [TODO](../TODO.md), [Desktop](DESKTOP.md)
and the [documentation index](README.md) aligned while preserving historical
completed stages and current implementation/qualification boundaries.

### Checkpoint 1 — Workspace Phase 6: topology-aware Environment Status

**Complete within the validated comparison scope.** Read-only comparison covers
supported Workspace Topology V1 relationships and selected VS Code descriptors,
reusing Core facts and preserving legacy Bundle Status and explicit Status → Restore
handoff. Unsupported coverage remains honest; no target mutation, auto-selection,
automatic Restore or general file transfer is introduced. [Roadmap](../ROADMAP.md#complete-workspace--git-worktree-restoration)
records the accepted evidence and remaining native qualification.

### Checkpoint 2 — Workspace closure and real-world qualification

**Bounded Core E2E accepted:** Capture → Preview → Execute → Global Verification →
Status, including **6/6 Verification and 6/6 Comparison**, selected descriptors,
file preservation, conflicts, repeat/no-op, controlled Stop/re-entry and the SIGTERM
fence. Native same-Bundle Desktop E2E, full reconciliation/recovery and packaged
qualification remain open. This is qualification of existing Workspace capability,
not authorization for content migration or expanded SSH/filter/LFS support.

### Checkpoint 3 — Consolidated test/CI stabilization

The consolidated evidence assessment is accepted at `ed521e7` / [CI #127](https://github.com/jetiaks-AKS/macseed/actions/runs/40914838447): lint, four regression shards, Desktop and validate succeeded. Historical CI #123/#124 assertions were repaired; Capture inventory correspondence replaced the fixed event count in `a1fa2a5`. No active regression debt is established by those historical failures. Additional runs or repairs require current evidence or implementation changes; green CI does not close native/packaged qualification gates or prove future GUI behavior.

### Checkpoint 4 — Product Scope Revision / read-only impact audit

The revised read-only audit and 13-column impact matrix are approved. The accepted inventory, dependencies and compatibility analysis underpin section 4. The former ordinary VS Code descriptor placement and retain-all-defaults recommendation are superseded. Default-policy changes require bounded Desktop model work, with no Core/Bundle format change. Historical Stage 10/11/12 completion labels remain unchanged.

### Checkpoint 5 — Native UI Alignment: implemented and visually accepted

Home/Sidebar/Settings/About, Capture Selection/Confirmation/Result, Restore
Selection/Preview/Progress/completed and stopped Result, and Environment Status
have explicit user visual approval. Final naming is consistent throughout the native
application. The historical slice IDs are retained; no visual work remains in those
slices. The UI and subsequent Homebrew Setup implementation are published through
`ac6c5bd`; visual acceptance, retained local validation and hosted qualification
remain separate. This does not close remaining native lifecycle, capability or
packaged qualification, and adds no Core feature or parallel Restore model.

### Checkpoint 6 — Finish remaining Stage 16 qualification

The 2026-11-04 product decision includes Secure SSH Desktop (16H) in Macseed 1.0.
Stage 16H SSH Identities is now completed with accepted automatic/manual external
Capture → Rebuild → Verification, byte matching, permissions/fingerprints and no-op.
[SSH Environment Completion — Developer Environment Closure](CAPTURE-RESTORE.md#ssh-environment-completion--developer-environment-closure)
is NEXT / PLANNED, not implemented; all identities currently restore to `~/.ssh`.
Bundled age is required for 1.0 and pinned v1.3.2 is implemented: Desktop Secure Transfer needs
no separate age/Homebrew installation. CLI installation consent is unchanged; age
updates arrive with Macseed releases, without a runtime updater. Core Secure
Migration remains the engine; migration defaults off. Broader release qualification
remains open; signing/notarization and clean-Mac proof belong to
[Stage 17](DISTRIBUTION.md).

Follow Roadmap's order: SSH Environment Completion, remaining native Workspace
qualification, bounded Stage 3C reconciliation, then
remaining supported-domain, Homebrew Setup Installer, lifecycle, completion (16I)
and integration/runtime (16K) gates. Existing journals, Stop and fences stay
implemented; blocked retry is not recovery. Finish with fresh end-to-end
Capture → Rebuild → Verify → Check → no-op evidence before Stage 17. Do not expand
feature breadth or repeat accepted gates without a specific remaining evidence need.

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

Native UI Alignment and the subsequent Homebrew Setup implementation are published
on `develop` through `ac6c5bd`. Visual acceptance, retained local validation and hosted
qualification remain distinct; CI #127 is a historical accepted baseline.
[Roadmap](../ROADMAP.md#current-practical-execution-order) records CI #135's Desktop
compilation failure and the approved remaining 1.0 sequence. Continue with native
same-Bundle Workspace qualification, bounded reconciliation/safe re-entry and the
remaining Stage 16 gates. Preserve approved UI and real-Mac acceptance; do not
automatically begin Stage 17 or expand into workspace content transfer.
