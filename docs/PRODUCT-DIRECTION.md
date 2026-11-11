# Macseed — Product Direction

<a id="macseed--product-direction-and-delivery-sequence"></a>

- **Decision date:** 2026-10-29
- **Revision:** 2026-11-06 — Macseed 1.0 positioning and Roadmap ownership clarified
- **Status:** Native UI baseline visually accepted; later refinements and release qualification retain their own gates
- **Repository:** `jetiaks-AKS/macseed`
- **Working branch:** `develop`
- **Historical baseline at the 2026-11-02 documentation review:** `fa464c48ef1fd42a4e7c79c7856729d516e4cdf7`
- **Published baseline for GUI realignment:** `ed521e7`; CI #127 successful

**Scope of this document:** Approved product positioning, priorities and deferrals. [Vision](VISION.md) owns enduring product principles; [Roadmap](../ROADMAP.md) owns current stage status and execution order; [TODO](../TODO.md) owns open actions. [Desktop](DESKTOP.md), [Capture / Restore](CAPTURE-RESTORE.md), [Core](core/APPLICATION-INTERFACE.md) and [Configuration](toolkit/CONFIGURATION.md) retain their implementation contracts. This dated decision record does not replace those owners.

> **Interpretation rule:** An approved product direction is not an implemented feature, a passed automated test, a real-Mac qualification, or release readiness. Preserve those distinctions in every document and UI claim.

## 1. Product promise

Macseed is a **Mac setup reconstruction and verification utility**. Users save a
reusable description of supported environment state, rebuild it on a new or
existing Mac, and check what matches. The native Desktop makes these workflows
approachable while the official CLI remains supported.

The approved 1.0 scope combines **applications and tools, supported macOS and
VS Code settings, and reusable Saved Environments** with optional advanced Git,
Workspace, SSH and Shell capabilities. Advanced describes user needs and scope;
it carries the same safety and verification standards as Standard Setup.

**Tagline:** A smarter way to capture, rebuild, and check your Mac setup.

Macseed is not a replacement for Migration Assistant, Time Machine, a filesystem backup, a complete Mac clone or a universal third-party application configuration migrator. Avoid stale caches, logs, sessions, unqualified preferences and broad copying of application data. Do not claim that an entire machine or application health is verified merely because supported requirements matched.

Macseed must remain maintainable by a small developer project. Prefer a reliable, limited end-to-end outcome over broad feature coverage and new frameworks.

## 2. Three equally important everyday workflows

1. **Capture:** Observe the supported current environment, let the user explicitly select meaningful items and categories, and save a private `.mbt` Saved Environment.
2. **Rebuild (Restore):** On either a clean or an already-used Mac, inspect a selected `.mbt`, narrow its captured requirements, show a fresh non-mutating Preview, obtain confirmation, apply only safely actionable changes and verify the supported result. Matching state must be a no-op. An unsafe or ambiguous reinstall/repair must be declined, not forced.
3. **Check (Environment Status):** Compare a selected Saved Environment with the current Mac read-only. Explain confirmed matches, differences, missing items, unsupported coverage and observation uncertainty. Offer the already implemented **Review in Rebuild** handoff; the user must still inspect, select, preview and confirm. Reusing the *same* Saved Environment at a later date is a first-class workflow.

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
| Git configuration, repositories, linked worktrees | **For Experienced Users → Git** | Keep and qualify current supported scope, including implemented bounded SSH clone dependencies. Do not reopen unlimited Git topology or transport coverage. |
| SSH configuration / selected SSH identities | **For Experienced Users → SSH → Configuration / SSH Keys** | Independent selection; separately encrypted, opt-in/default-off identities. Configuration restoration, explicit IdentityFile corrections, authenticated per-identity selection and safe custom destinations are implemented; `~/.ssh` remains the default. Stage 16H manual acceptance retains its original scope; joint SSH E2E stays open. |
| Zsh / Shell | **For Experienced Users → Shell** | Retain bounded `.zshrc` contract and its explicit exclusions; do not modify user configurations just to satisfy Discovery. |
| `.code-workspace` descriptors | **For Experienced Users → Workspace, default OFF; scope frozen for 1.0** | Preserve Core, tests, Bundle V1, legacy selected-descriptor Restore, Verification and Status. No feature expansion or dependency auto-selection; only supported names/folder relationships. |
| Workspace Folders (structure only) | **For Experienced Users → Workspace, default OFF; no ordinary promotion** | Preserve the Core domain, explicit folder-only Capture, descriptor dependencies and folder-only Bundle Restore selectors. Both accepted selection screens expose folders. No general file-content migration. |
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

A separate **For Experienced Users** container exposes sibling Git, SSH, Workspace
and Shell groups. The accepted Unified Developer UI keeps Configuration and SSH Keys
independently selectable under SSH, with explicit default-off identity selection.
Rebuild supports whole-package or authenticated per-identity selection and optional
safe custom destinations. Descriptors/folders remain
explicitly selectable under the frozen compatibility contract, without ordinary
promotion or dependency auto-selection.

**Selection policy — implemented in Capture and Restore:** eligible ordinary
requirements default ON; developer and unknown domains default OFF. Fresh Scan or
Bundle inspection starts disclosures collapsed. Eligible group headers
have scoped tri-state masters, with separate Standard Setup/For Experienced Users Expand/Collapse
controls. Checkbox and disclosure actions are independent. Back/Refresh preserve
explicit choices; selection changes require fresh preparation. Workspace Folders
is directly reachable under Workspace, including folder-only scope. Core owns dependency
validation; empty developer-only drafts do not automatically enable Preview.

The inspected Bundle is Restore's strict scope ceiling. Absent/excluded requirements
and empty groups are hidden; selected limitations remain explainable. Rebuild Preview
retains detailed planned/matching/attention evidence and prerequisites, with automatic
tasks grouped separately from manual App Store installation. It is read-only. Progress
and Result use flat ordered domain lists. Completed Result shows visible planned-and-
verified requirements and actual problems, omitting pre-existing matches; stopped
Result retains reported work and uncertainty without inventing unchecked failures.

**Check remains read-only:** Standard Setup and For Experienced Users group diagnostic
rows with the established category order, icons, summary cards and numeric badges.
It compares the saved reference, including developer/descriptors, retaining matching
requirements, differences, attention and item-level details. SSH Configuration uses
one aggregate `config` requirement, with Core-qualified saved Host detail directly
under its existing collapsed category. Preview uses current selected Host detail,
ordinary matching suppression and only genuinely authorized planned changes. These
details add no Core requirements, categories or result-success claims. Check item
statistics count qualified Hosts in place of their owning aggregate, consistently
across category, SSH parent and summary cards. Preview counts qualified Host outcomes
the same way; execution/Result accounting stays aggregate. Independent future SSH
requirements can use the same hierarchy with their own Core-qualified identities.
Secure Check can resolve reference coverage only through complete same-operation path/pair correspondence
with authenticated saved keys; byte equality proves neither key usability nor remote
authentication. Legacy partial coverage stays visible. Empty groups are hidden and
numeric rails preserve actual counts; no matching records are invented.

VS Code and Advanced are presentation groups, never new Core domains. Core GROUPS,
Bundle ceilings, IDs, item/category modes, evidence and native accessibility semantics
remain intact. No new adapter, dependency engine, automatic Apply or extra wizard
follows from visual acceptance. Remaining capability/runtime/packaging qualification
is tracked separately in Roadmap and TODO.

<a id="5-delivery-sequence-and-gates"></a>

## 5. Historical checkpoints and qualification boundaries

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
implements configuration restoration, optional safe custom destinations, independent
selection and bounded SSH → Git dependencies; joint real-Mac qualification remains open.
Bundled age is required for 1.0 and pinned v1.3.2 is implemented: Desktop Secure Transfer needs
no separate age/Homebrew installation. CLI installation consent is unchanged; age
updates arrive with Macseed releases, without a runtime updater. Core Secure
Migration remains the engine; migration defaults off. Broader release qualification
remains open; signing/notarization and clean-Mac proof belong to
[Stage 17](DISTRIBUTION.md).

Follow [Roadmap's current execution order](../ROADMAP.md#current-practical-execution-order)
for the remaining qualification gates. Existing journals, Stop and fences stay
implemented; blocked retry is not recovery. Do not expand feature breadth or
repeat accepted gates without a specific remaining evidence need.

### Checkpoint 7 — Stage 17, Early Access and Macseed 1.0

Produce a correctly bundled, writable-runtime-safe, signed/notarized app; prove clean-Mac Capture/Restore/Status on supported Apple Silicon and qualify Intel independently before claiming support. Conduct a small external Early Access (Roadmap proposes approximately 10–20 technical users), fix validated UX/compatibility problems and release only against documented scope.

### After 1.0 — optional, demand-driven

Possible Saved Environment history/profiles, confirmed-difference preselection for Restore, semantic drift workflows and bounded selected folder-content transfer. These should reuse Core and the existing **Prepare → Preview → Confirm → Execute → Verify** path, not introduce a parallel configuration engine. No background monitoring, extra database or universal migration capability without a demonstrated need.

## 6. Working and release discipline

- **One bounded checkpoint at a time:** read/audit contracts → address the selected scope → focused tests → inspect diffs → record accepted evidence → move to next checkpoint.
- **CI strategy:** follow [risk-based local validation](../CONTRIBUTING.md#risk-based-local-validation): focused cases for incremental changes, reusable unchanged PASS evidence and explicitly justified broader runs for substantive integration/release checkpoints or demonstrated risks. Mandatory CI gates retain their complete configured coverage. CI #127 is a historical baseline, not validation of subsequent changes; preserve changed-behavior tests and do not treat historical failures as active debt without evidence.
- **Documentation truth:** [Roadmap](../ROADMAP.md) records outcomes/stage status, [TODO](../TODO.md) concrete open actions, [Desktop](DESKTOP.md) as-implemented UX and planned changes clearly separated, [Changelog](../CHANGELOG.md) only completed release-visible work. This document records product decisions; Roadmap alone owns the current execution sequence.
- **Git:** work on `develop`; preserve `main`, released history and all local commits. Avoid force-push, destructive reset and unreviewed cross-cutting changes. A documentation-only local commit may be kept unpushed and later published with validated implementation to avoid unnecessary hosted CI cycles.
- **Privacy and safety:** no implicit deletions; Bundle ordinary metadata is private but not encrypted; SSH private identity migration requires explicit consent and its separate encrypted contract. Do not weaken idempotency, failure-state honesty or conflict preservation for UI convenience.

## 7. Next action

Continue qualification of
**[SSH Environment Completion — Developer Environment Closure](CAPTURE-RESTORE.md#ssh-environment-completion--developer-environment-closure)**,
whose bounded implementation is complete after Stage 16H identity migration. Preserve
Selection = configure, Preview = read-only validation and Rebuild = execute;
configuration corrections require explicit authorization. Unified Developer UI is
visually accepted; local Secure Check tests, real-Mac joint E2E and hosted CI are
separate evidence levels. [Roadmap](../ROADMAP.md#current-practical-execution-order)
owns current execution order and qualification status. Documentation or CI
maintenance does not start Stage 17 or workspace content transfer.
