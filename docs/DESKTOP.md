# Macseed Desktop

Native SwiftUI Desktop is a development client of the same **Core/CLI 3.4.0** as
`bs`: **Capture → Rebuild → Verify**. Real Capture, Restore Prepare/Execute,
Bundle-backed Environment Status and its Restore handoff are implemented. Visually
accepted Home, Capture, Restore, Environment Status, Settings/About and Stage 16J
diagnostics are the current foundation. Native UI Alignment is **Visually Accepted**
by explicit user approval on **2026-11-02**. Stage 16 remains open;
completed flows do not establish full capability,
secure interaction or packaged clean-Mac qualification.

This document owns native presentation, interaction and runtime boundaries.
[Protocol V1](core/APPLICATION-INTERFACE.md) owns operations, selection, prerequisites,
records and secret input. Desktop consumes structured facts, never CLI/log text or
a second Swift implementation of Core behavior. Normal launch checks real Core
capabilities; samples exist only in explicit DEBUG design-preview mode.

Assisted App Store Restore is current: select requirements, install manually in
Apple App Store, then refresh Core verification. Confirmed Cask/App Store identity
overlap uses Cask-first precedence; unresolved evidence retains both requirements.
Automatic MAS install/helper paths are retired; `archive/mas-automatic-restore-v4`
is historical research material requiring a separate explicit decision.

**Desktop CI validation is COMPLETE** at `411cd712` / [CI #108](https://github.com/jetiaks-AKS/macseed/actions/runs/40287367098),
including all eight suites, both Restore subsets and native PresentationTests.
[Contributing](../CONTRIBUTING.md#focused-feedback-and-ci) owns mandatory Core +
Desktop + `validate` gates and measured CI timings. [Roadmap](../ROADMAP.md#current-practical-execution-order)
owns stage status/order and Workspace Phase 6 acceptance. The historical CI milestone
does not assert current HEAD success; [TODO](../TODO.md#consolidated-testci-stabilization)
tracks known test debt.
[Desktop development](../desktop/Macseed/README.md) owns build, launch and test commands.

## Implemented runtime boundary

Desktop resolves an explicit development runtime descriptor or future relative
bundled resources, launches one owned Core process group per request and consumes
validated JSONL separately from stderr. It preserves V1 identifiers, sequence,
phase and additive metadata. Missing runtime/protocol failure is typed and never
falls back to samples. Development descriptors bind absolute Core/Python paths;
future bundled paths remain within resources after symlink resolution. HOME is the
real user's home; PATH/environment are controlled, optional Homebrew locations do
not require installation. Private operation directories are removed after owned
process termination. See [runtime preparation](../desktop/Macseed/README.md#runtime-preparation).

Transport validates envelopes/version, operation ID, increasing sequence, framing,
lifecycle and terminal/exit consistency. Unknown fields/events are preserved, never
interpreted as completion. Stdout JSONL and stderr drain separately; stderr retains
only byte count/read error, never raw persisted/rendered text. Runtime retains at
most 256 history events with explicit truncation and keeps the latest result;
validated records reach the independent log before eviction. JSONL limits are
64 MiB per event and 256 MiB per operation, distinct from Core's per-record limits.
Cancellation signals the owned root group with bounded TERM/KILL escalation;
Core owns its tool groups, so forced root termination cannot prove all effects settled.
The native outcome records whether a process actually launched. A client encoder
rejection (`request_too_large`) is Failed Before Launch, with no Core terminal or
Verification, in the existing Operation Log/Diagnostic Report presentation. Older
logs with this client-only code are also identifiable; missing events or a generic
interruption alone never prove that launch did not occur.

This boundary is implemented, not packaged clean-Mac proof. Core's root-relative
logs/config require a private writable workflow workspace before signed-resource
workflow qualification; current bundled resolution rejects those writes. Selected
Secure Capture, selected Secure Restore Execute and authenticated secure Preview
comparison open the same 16H socket bridge. `restore_prepare` and ordinary
operations do not open a secret channel.
Handled cancellation retains Core evidence; forced termination without a terminal
event is interruption with unknown effects, never rollback or item-boundary stop.
Diagnostic persistence and Result presentation are implemented; broader completion
and native lifecycle qualification remain open.

## Window and navigation

Use one main window with **Home**, **Capture**, **Rebuild** and
**Check** in the sidebar. These are the user-facing names for the
Capture, Restore and Environment Status workflows; operational terminology and
internal identifiers retain their meaning. An operation detail view belongs to
the active flow. Settings → Operation Logs opens the shared native log window;
results and terminal failures/cancellations offer View Log for their own operation
when its journal exists. Ordinary Capture Review/confirmation and Restore
Selection/Preview omit the local link. A failed Prepare retained on an intermediate
screen may expose only its matching operation's journal; Settings history remains available.
Use native file dialogs, accessible controls, text plus icons for status, and
keyboard navigation. Never rely on color alone.

Startup reads Homebrew availability. When the
[Homebrew reminder gate](#homebrew-setup--implemented-visually-accepted) applies,
the dedicated setup window precedes Home; continuing or dismissing it starts no
workflow. Installation requires explicit initiation and hands a verified package
to standard macOS Installer, or opens the manual Terminal route. Home exposes
Capture, Rebuild and Check, a short explanation of supported environment state,
and **Ready** when its Core/runtime capability check succeeds. Launch does not
automatically scan, rebuild, compare, install Homebrew or request administrator
authentication.
Capability failure shows **Needs Attention**, with launch/runtime guidance and
**Check Again**. Capability availability is not readiness for a selected Restore.

Each destination uses one stable content area whose state changes, with one
primary action, inline status blocks, expandable rows and disclosure groups.
Logical Core phases are not separate screens. Review, selection, Preview and
prerequisites share that area; short focused interactions use sheets, and alerts
are reserved for justified explicit decisions. If the user can safely complete the
task without another screen or dialog, do not add one.
Keep only one Core operation active per application instance; disable competing
starts and offer return to the active operation. Navigating away must not silently
cancel or detach it. Closing during work offers Keep Working or the applicable
Cancel / Stop Rebuild action; wait for owned-process termination before closing. No background daemon or
persistent resumable job is introduced.

## Shared design system — approved foundation and functional consistency

Macseed Minimal Premium is the accepted foundation. Shared domain/item rows,
status vocabulary, spacing, disclosures and accessibility use the same presentation
model across **Preview → Rebuild → Verification → Result**. Remaining 16I/16K
accessibility and edge-case qualification does not reopen accepted functional UI.

Restore's reference hierarchy is **Domain → Items**. The top attention summary
owns only affected areas and counts, with warning icons; it has no item-detail
disclosure. Prerequisites separately explain execution requirements with compact,
independently expandable rows: Ready when satisfied, visible status when blocked.
The lower domain sections own concrete items and short user-facing reasons. Technical
diagnostics belong in the existing Operation Log, without workflow disclosures or copy
fallbacks. Across Capture, Restore and Environment Status, keep one short explanation
(and a second sentence only for a necessary action or blocking consequence). Group shared
prerequisites only by compatible domain, scope, reason and action; preserve independent
item problems and item counters. Repeated records are not separate user actions.
Retain truthful Needs Attention versus Unverified evidence in all phases.

<a id="planned-product-grouping--not-implemented"></a>

## Product grouping — native UI alignment accepted

The approved [Product Direction](PRODUCT-DIRECTION.md#4-native-desktop-presentation-direction--planned-not-implemented)
and revised impact audit retain the three destinations and accepted native foundation.
GUI realignment uses the shared Desktop-only `WorkspacePresentationTaxonomy`.
Capture and Restore were explicitly approved on **2026-11-01**; the full native
interface is **Visually Accepted** on **2026-11-02**, including Home, Sidebar,
Settings/About and Environment Status. Restore includes Selection, Preview,
Progress and the outcome-specific Result;
the [native UI contract](#macseed-native-ui--design--interaction-contract) records
the current implementation and its approval boundaries.
The approved target grouping is:

- **Applications & Tools:** App Store, Homebrew Applications and Homebrew Packages.
- **macOS Settings:** existing supported domains and only subsequently qualified additions.
- **Application Extras → VS Code:** collapsible application group; Extensions retain
  item selection and Settings retains whole-category selection.
- **Advanced — For experienced users:** collapsed/opt-in Git, repositories/worktrees,
  Workspace Folders, SSH, Shell / Zsh and **VS Code Workspace**. Capture places
  **Secure Transfer** directly below Advanced as a sibling under **For Experienced Users**,
  with its own explicit, default-off identity selection. Restore also defaults
  `include_secure` to false; explicit selection enables the encrypted package.

Descriptors are **HIDE / FREEZE** from ordinary UX, with explicit Advanced Capture
and Restore selection, default OFF. Preserve Core/tests/Bundle V1 and legacy
Restore/Verification/Status; never select dependencies automatically. Workspace
Folders retains its Core domain and explicit selection contract, OFF. Capture Review
keeps **Workspace Folders** directly reachable in Advanced, including folder-only Capture.
Restore exposes captured folders in Advanced, including folder-only Bundles.
Neither feature introduces general content transfer.

**Implemented in Capture and Restore Selection:** ordinary eligible requirements
default ON and all Advanced OFF. Both have native tri-state master checkboxes in
the four section headers and the VS Code subgroup; macOS keeps six independent
child selectors. Text Select All / Deselect All buttons are replaced by these
scoped masters. Capture has separate ordinary and experienced section disclosure
controls; Restore Selection retains its ordinary and Advanced controls.
Expansion never changes selection or resets the other scope. Advanced-only Bundles
remain explicitly selectable; an empty draft does not trigger automatic inclusion.
Status always compares the complete saved reference, including Advanced, with
collapsed differences/unsupported/attention preserved in summaries.

**Workflow boundary:** Capture uses the hierarchy in Review and Confirmation;
its Result summarizes publication without a category tree. Restore uses the hierarchy
in Selection and automatic Preview, then flat ordered domain lists in Progress and
Result. Environment Status uses static section headings and expandable diagnostic
category rows, without VS Code or Advanced parent accordions.
The taxonomy classifies original Core domain
rows once; Application Extras/VS Code and Advanced add no requirements or counts,
and unknown domains retain Other Findings. It owns no selection, protocol or
disclosure state. Capture reuses native disclosure/accessibility patterns and its
existing selection maps. Restore's cancellation baseline follows its ordinary/Advanced
defaults, and selection edits require fresh preparation. Core GROUPS and Bundle ceilings remain unchanged.
No new application adapter, placeholder or separate engine is introduced.
[Roadmap](../ROADMAP.md#current-practical-execution-order) owns sequence.

## Macseed Native UI — Design & Interaction Contract

This section owns the reusable visual and interaction contract, checked against
the **local implementation on 2026-11-02**. Local source, successful builds and
fixture screenshots establish implementation evidence, not visual acceptance or
packaged qualification. Product grouping remains governed by the decisions above;
this contract does not authorize another workflow's redesign.

### Approval boundaries

| Status | Scope |
|---|---|
| **Implemented — Visually Accepted** | The entire current Capture UI, explicitly approved by the user on **2026-11-01**: Unified Accordion, all group and VS Code master checkboxes, 0/12/24/36 pt hierarchical indentation, shared ordinary and independent Advanced Expand/Collapse controls, VS Code presentation, Advanced styling, read-only Confirmation and the final minimal Result layout. Existing native foundation and scoped selection contracts remain accepted. |
| **Implemented — Visually Accepted** | Restore Selection, Preview, Progress and Result, explicitly approved by the user on **2026-11-01**. Acceptance includes the Bundle-scoped accordion and defaults, detailed read-only Preview, flat Progress/Result lists, completed Result labels/filtering and the corrected Stopped Result described below. |
| **Implemented — Visually Accepted** | Environment Status: static section headings, expandable diagnostic categories, full matching/difference/attention visibility and adaptive numeric-badge columns. Explicit final approval: **2026-11-02**. |
| **Implemented — Visually Accepted** | Home, Sidebar, compact General Settings, native About and consistent workflow naming/descriptions throughout the native UI. Explicit final approval: **2026-11-02**. |

Native UI visual acceptance does not imply completion of future integration,
end-to-end or release qualification, including packaging and clean-Mac validation.
Remaining Stage 16/17 gates retain their separately documented status.

### Home and native navigation — Visually Accepted

Home displays **Macseed** and **A smarter way to capture, rebuild, and check your Mac setup.**
The three cards, sidebar destinations and workflow headers use the same `ProductTask.title` /
`subtitle` copy, including Home accessibility labels and DEBUG workflow headers:

| Workflow | Display title | Introductory description |
|---|---|---|
| Capture | Capture | Capture apps, settings, and workspace. |
| Restore | Rebuild | Rebuild from a saved environment. |
| Environment Status | Check | Check a saved environment. |

`ProductTask.rawValue` and the `All Tasks` tag remain internal navigation keys;
they are not displayed as workflow titles. Rebuild Preview, Capture Again,
Review in Rebuild, Verification and other action/state labels remain distinct.
Workflow-facing progress, errors and footers use Check/Rebuild; item-level restore
verbs and structured Core operation/diagnostic identifiers retain their meaning.

The main window retains a **1000 × 700 pt content minimum**, **1200 × 800 pt**
preferred size and **215 pt** native sidebar. Home's centered content caps at
**1080 pt**. The hero uses a **112 pt** icon, **24 pt** horizontal gap, **32 pt**
padding and **210 pt** minimum height. `WorkspaceActionLayout` uses three equal
columns above its **660 pt** breakpoint, **16 pt** gaps and the tallest card's
measured height; narrower contexts stack the cards. Cards retain **22 pt** padding,
**16 pt** vertical gaps, **90 × 90 pt** icon slots, top-aligned title/description
slots with **42 / 56 pt** minimum heights and **26 pt** bottom navigation controls.
Wrapped text preserves shared content origins, colors and card geometry.

The sidebar keeps Home's house and the existing blue/green/violet workflow icons.
Settings remains below the navigation list, separated by a divider and using the
neutral gear. Its `SettingsLink` and **Macseed → Settings… (`⌘,`)** open the same
Settings scene. General's **About Macseed…** and **Macseed → About Macseed** use
the same standard About presentation; neither introduces a sidebar destination.
See [native appearance and Settings](#native-appearance-and-settings) for controls
and metadata boundaries.

### Capture Review — implemented structure and geometry

Both Review and Confirmation use **Standard Setup** and **For Experienced Users**
as sibling category section names. `CaptureGroupedContent` renders one ordinary
bordered accordion containing
**Applications & Tools**, **macOS Settings** and **Application Extras**. Application
Extras contains the **VS Code** subgroup, then **Extensions** and **Settings**.
**For Experienced Users** precedes one shared bordered container with two sibling
rows: **Advanced**, then **Secure Transfer**, separated by one standard inset divider.
There is no gap or second border between them; expanded content stays inside the
shared 8 pt rounded surface. Both reuse the ordinary container's header columns,
horizontal padding and 48 pt row height, with independent disclosure. Advanced
holds Git Configuration, Git Repositories / Worktrees, Workspace Folders, SSH
Configuration, Shell / Zsh and VS Code Workspace. It retains its warm title/icon
accent; Secure Transfer retains blue. The shared surface remains neutral in
Light/Dark. Unknown domains remain visible as Other Findings.
Presentation parents add no requirements or duplicate counts.

Each sibling owns one master checkbox. Advanced's master/status cover only its
eligible configuration descendants and never change SSH identities. Secure Transfer
reuses the identity selection: Off/Partial selects all eligible identities; All clears
them. Individual controls update the same state; status is Off, N of M selected or
All Selected. There is no shared parent selector or second identity master.
The experienced section's Expand All controls both sibling groups and their nested
disclosures, independently of either master checkbox. Secure-only Capture remains
available with every ordinary category deselected; Confirmation keeps the prepared
secure scope read-only in the same shared hierarchy.

The following are implemented point values, not proposed targets. They describe
Review only. `CaptureReviewPresentation.hierarchyStep` is **12 pt**. Offsets apply
once to each row's leading content, relative to the existing selection-column
baseline, rather than accumulating padding on nested containers:

| Review level | Examples | Additional leading offset | Selection-slot origin from container edge |
|---|---|---:|---:|
| 1 — Main group | Applications & Tools, macOS Settings, Application Extras, Advanced, Secure Transfer | 0 pt | 40 pt |
| 2 — Domain / subgroup | Homebrew Packages, Finder, Git Configuration, VS Code | 12 pt | 52 pt |
| 3 — Child domain / item | Extensions, Settings, package names, Git/folder items, SSH identities | 24 pt | 64 pt |
| 4 — Nested item | Individual VS Code extensions | 36 pt | 76 pt |

The 40 pt baseline is the existing **16 pt** row edge inset plus
`CaptureChildRowGrid.leadingInset` (**24 pt**). Group headers reach the same baseline
with a 12 pt leading chevron slot and 12 pt gap. Native checkbox glyphs sit within
the slots below; item rows have no icon and retain their compact checkbox/text gap.
The table does not imply identical text origins for icon-bearing domains and items.

| Geometry | Current implementation |
|---|---|
| Leading controls | Group/subgroup: left chevron, checkbox, icon, title. Domain: checkbox, icon, title; its expandable disclosure stays at the far right. Only expandable rows have chevrons. `CaptureAccordionStyle` keeps the leading chevron stationary when the subgroup's selection slot is indented. |
| Selection and icons | Group/domain checkbox slots are 28 pt wide; normally 28 pt high, with 48 pt slots for macOS category rows. Selection-to-icon and icon-to-title gaps are 12 pt; icons reserve 22 pt. Item checkbox slots are 20 × 28 pt, followed by an 8 pt text gap. |
| Status rail | `CaptureRowColumns` reserves 200 pt for status, with a 12 pt title/status gap. The existing 26 pt trailing disclosure reservation and 16 pt right inset remain unchanged at every depth. Neutral status text reserves the same 22 pt icon slot plus 7 pt gap as diagnostic statuses. Indentation reduces leading-content space, not the status/disclosure position. |
| Heights and spacing | Group/domain headers have a 48 pt minimum height, with 6 pt vertical padding inside `CaptureRowColumns`. Item labels have a 28 pt minimum height plus 2 pt padding above/below; long labels can wrap. Accordion member stacks use zero inter-row spacing; dividers retain 16 pt horizontal insets. |
| Surfaces and list | `WorkspaceCardSurface` uses an 8 pt radius and quaternary border. `CaptureGroupedContent` spaces its principal blocks by 12 pt; `WorkflowList` uses 20 pt between its children. The workspace margin remains 28 pt. Advanced adds a neutral quaternary background at 0.2 opacity. |
| Advanced separator | `WorkspaceSectionHeader` uses 13 pt semibold text, a 1.5 pt divider, 12 pt top and 4 pt bottom padding. Its disclosure control stays right-aligned on the same heading line. |

Group titles use `.headline`; VS Code and domain titles use `.body.weight(.medium)`;
item labels use `.body`. Status text is `.callout`, secondary counts/explanations
use `.caption` where implemented, and chevrons use semibold `.caption`. Preserve
system typography, SF Symbols, blue domain icons and native accent-based
checkboxes; native inactive appearance remains system-controlled. Use secondary
neutral styling for unsupported/unavailable state, orange for attention and green
for confirmed completion. Status text/icons accompany color. The Advanced group
header has the implemented warm title/icon tint; its surface remains neutral.
The Review summary orders Selected Domains (with selected-items text), Selected SSH
Identities when nonzero, then Needs Attention only
when its count is positive.

### Capture Review — selection and disclosure

The ordinary group headers, Advanced, Secure Transfer and VS Code have native tri-state masters:
**checked** means all eligible descendants, **unchecked** none, and **mixed** a
partial selection. Clicking checked clears the eligible scope; clicking unchecked
or mixed selects that group's eligible scope. Ordinary/Advanced `CaptureGroupControls` uses
`CaptureReviewPresentation.bulkCategories`, `CaptureModel.bulkState(for:)` and
`toggleCategories`; `NativeSelectionCheckbox` retains native checkbox/accessibility
semantics and a separate hit target from disclosure. An empty eligible scope has
no active master and an Unavailable summary. Secure Transfer reuses its existing
`selectAllSecureIdentities` / `selectSecureIdentity` callbacks and shared selected-ID set.

Application Extras and its VS Code subgroup currently cover the same two Core
domains, `vscode-extensions` and `vscode-settings`; their states stay synchronized
without duplicating requirements. Extensions retains individual item selection;
Settings retains whole-category selection. macOS keeps six independent domain
selectors with read-only preference details. Other domain/item controls use the
existing `selectCategory` / `selectItem` operations and stable Core IDs. Standalone
Selected / Not Selected text is omitted where a row checkbox already expresses
that fact; meaningful item counts, aggregate summaries and diagnostics remain.

Every fresh Scan selects eligible ordinary requirements and leaves Advanced,
Secure Transfer and unknown domains OFF; all section and nested disclosures start collapsed.
Unsupported, unavailable and observation-error domains are never selected. The
Advanced master explicitly selects/clears all eligible Advanced domains and their
items, including Workspace Folders. It leaves ordinary choices intact. Ordinary
actions and disclosures never select dependencies; Core still validates explicitly
selected workspace/descriptor dependencies. No additional selection engine or
request fields are introduced.

Review and Confirmation each have **two section-level Expand All / Collapse All
controls** when both sections are present. The ordinary control sits beside
**Standard Setup** on both screens and affects only Applications & Tools, macOS
Settings, Application Extras and their applicable nested disclosures.
The **For Experienced Users** control affects both Advanced and Secure Transfer,
including applicable nested disclosures. Both headers and controls live inside
`WorkflowList`, scroll with their content and retain the 42 pt trailing inset.
There are no pinned, floating or per-category bulk disclosure controls.

**Review and select** and **Included in this capture** remain plain informational
headings in their general workflow header areas, outside the category scroll view.
Neither owns a disclosure control; each appears once above the category sections.

Each category keeps its own chevron. `CaptureExpandButton`,
`CaptureHierarchy.disclosureIDs` and `WorkflowExpansion` show Collapse All only when
every applicable disclosure in that section is open; a mixed state shows Expand
All. Collapse All clears the section's child expansion, preserving the other
section. Disclosure never changes selection, counters or preparation, starts secure
input or calls Core. The bottom action bar stays fixed outside the scrolling list.

Implementation locations: [CaptureView.swift](../desktop/Macseed/Sources/CaptureView.swift)
owns `CaptureView`, `CaptureGroupControls` and `CaptureMacOSSettingsView`;
[CapturePresentation.swift](../desktop/Macseed/Sources/CapturePresentation.swift)
owns `CaptureGroupedContent`, `CaptureGroupHeader`, `CaptureCategorySelectionView`,
`CaptureItemSelectionRow`, `CaptureSettingsSubcategoryView` and `CaptureReviewMetrics`;
[ContentView.swift](../desktop/Macseed/Sources/ContentView.swift) owns native
checkboxes, category icons/titles and surfaces;
[TaskComponents.swift](../desktop/Macseed/Sources/TaskComponents.swift) owns the
status dimensions, domain disclosure style and workflow viewport.

### Capture Confirmation — separate read-only presentation

`CaptureTaskPresentation` projects the authoritative prepared selection into
`TaskDomainList` with `captureHierarchy`, `CaptureConfirmationItems` and macOS
settings details. **Included in this capture** preserves compact wrapping names
for applications/extensions and compact macOS preference labels, with Ready to Save
summaries and separate independent warnings. There are **no selection checkboxes**.
Only groups included in the effective prepared selection appear. Ordinary categories
share one container; included Advanced and Secure Transfer share the second. Empty
sections and their controls are omitted, including the ordinary section for a
secure-only Capture. Both section headers and controls scroll with their content,
using the same disclosure scopes as Review; Back and Create Saved Environment stay
fixed below the viewport.

Preserve `CaptureIncludedSettingsList`, `CaptureCompactLabel` and
`SettingsFlowLayout`: the flow places labels left-to-right, wrapping at available
width, with **5 pt horizontal** and **4 pt row** gaps. Chips use `.callout`,
**8 pt horizontal / 4 pt vertical** padding and a **5 pt** corner radius;
included-settings and confirmation-item content retain their **36 pt leading /
8 pt vertical** padding. Review's existing compact preference labels also retain
this wrapping behavior. Do not apply the new Review indentation offsets to
Confirmation, alter its row spacing/statuses or turn compact content into vertical
item lists. Source membership and warnings remain distinct from selection UI.

### Capture Result — minimal publication outcome

The visually accepted minimal design is specific to Capture. Clean validated publication shows
one green **Save Complete** card with authoritative saved domains/items counts,
then the Bundle filename, actual destination and **Reveal in Finder**. There is no
repeated category tree, hidden full inventory or per-category success list.

Publication with selected-scope limitations retains Save Complete and adds a
separate amber **Needs Attention** card, followed only by affected selected
categories and concise safe explanations with View Log guidance. Independent
issues remain separate; duplicate evidence does not create extra issues.
Unselected SSH observations and unsupported/unavailable inventory are not failed
saved requirements. Missing selected evidence remains unverified, not an all-clear
claim. Failed, interrupted or uncertain publication must not render success.

`CaptureModel.resultPresentation` gates the result on validated publication;
`CaptureResultPresentation`, `CaptureResultOutcomes` and `CaptureResultContent`
render it, using `CaptureBundleLocationView` and the existing fixed footer actions
View Log, Capture Again and Done. Publication proves the saved Bundle, not
application health or target verification. See [Capture](#capture-this-mac)
for the publication and re-entry contract. The final current Capture Result layout
is **Visually Accepted** within the Capture UI scope above.

### Restore Selection — Visually Accepted

`RestoreSelectionContent` reuses `CaptureGroupedContent`, `CaptureGroupHeader`,
`CaptureRowColumns`, native checkboxes and the accepted Capture Unified Accordion.
One ordinary container holds Applications & Tools (App Store Applications, Homebrew
Applications, Homebrew Packages), macOS Settings and Application Extras → VS Code →
Extensions / Settings under **Standard Setup**. Below **For Experienced Users**,
Advanced contains Git Configuration, Git Repositories / Worktrees, Workspace Folders,
SSH Configuration, Shell / Zsh and VS Code Workspace, in that order. Stage 16H adds
Secure Transfer as Advanced's independent sibling in the same bordered container
when the Bundle includes `secure.age`. Its default-off checkbox selects the whole
package. The prior ordinary Selection visual acceptance is retained; Stage 16H
identity workflows have the accepted manual E2E evidence below.

The inspected Bundle is the strict scope ceiling. Absent/Capture-excluded domains
and empty groups are hidden; captured unavailable/unsupported evidence remains
explainable. Unknown captured domains retain Other Findings. Fresh inspection selects
eligible ordinary requirements; Advanced and unknown domains default OFF. All
disclosures start collapsed. Advanced-only/folder-only Bundles require explicit
selection, without automatically selecting dependencies or expanding Bundle scope.

`RestoreGroupControls` applies group and VS Code masters only to eligible captured
descendants: all checked, none unchecked, partial mixed. Clicking mixed selects the
eligible scope. VS Code Extensions retains item selection and Settings category
selection. Checkbox and disclosure targets are independent. Ordinary and Advanced
Expand All / Collapse All controls affect their own trees only. Back, Refresh Preview
and Result re-entry preserve explicit selection; new inspection establishes defaults.
Selection changes invalidate preparation; cancellation compares with those defaults.
Inspection supplies aggregate macOS domains, not an invented per-setting inventory.

### Rebuild Preview — Visually Accepted

`RestorePreviewContent` retains **Rebuild Preview**, its read-only notice and the
**Automatic Rebuild** summary caption. The existing cards appear when their count
is nonzero: green **Already Match**, blue **Changes Planned**, amber **Need Attention**.
`RestorePreviewMetrics` counts automatic Core plan rows once; these are Preview
observations/plans, not completed work or Verification. Manual App Store requirements
are excluded from those metrics.

The scrolling content contains **Prerequisites** when applicable, **Manual
Installation** when effective App Store scope is present, then **Automatic Rebuild
Tasks** when automatic domains exist. Fix Issues and its approval explanation remain
available when supported. Prerequisites retain category names, Action Required,
specific reasons and their own disclosures; there is no standalone duplicate Action
Required label or general Tasks heading. Blockers and operation availability remain
Core-owned and visible.

`TaskDomainList` with `restorePreviewHierarchy` uses one ordinary accordion for
Applications & Tools (Homebrew Applications / Packages), macOS Settings with its
existing preference details, and Application Extras → VS Code → Extensions / Settings.
Advanced uses the same domain order as Selection in a separate container. Only the
effective selected plan appears; empty groups are hidden and unknown rows retain
Other Findings. No dependency is added for visual symmetry. App Store stays solely
in Manual Installation, linking to the separate [manual screen](#assisted-app-store-restore).

Aggregate numeric badges appear only on Applications & Tools, macOS Settings,
Application Extras and Advanced; nested categories retain meaningful status labels
without badges. Group totals aggregate original plan rows, not child totals added
again. All expandable automatic rows have far-right chevrons. Expand All / Collapse
All sits beside Automatic Rebuild Tasks and controls its group, VS Code, domain and
macOS child disclosures together; it does not control Prerequisites or the manual
screen. Detailed planned actions, matching items, unsupported/unavailable findings,
diagnostic explanations and item checks keep their existing renderers.

Preview has no selection or master checkboxes and no Capture-specific Ready to Save /
Saved labels. Changes use **Back → Restore Selection → fresh Preview**. Refresh
performs Core Prepare; Rebuild requires current prepared scope, readiness and explicit
confirmation, with Core revalidation before mutation. Disclosure never prepares or
executes work. The native scrollbar remains visible, with a Preview-only 18 pt
trailing scroll-content margin and compensating −18 pt outer padding in the pinned
layout, reserving scrollbar space without changing the content grid.

### Restore Progress — Visually Accepted

`RestoreRebuildProgressContent` and `RestoreExecutionCategories` render one flat
bordered list of selected automatic domain rows, without Applications & Tools,
Settings, Git or Workspace section headings. Order is Homebrew Applications,
Homebrew Packages, existing macOS Settings domain(s), VS Code Extensions, VS Code
Settings, Git Configuration, Git Repositories / Worktrees, Workspace Folders, SSH
Configuration, Shell / Zsh and VS Code Workspace. Missing domains are not invented;
unknown selected domains follow the known rows. Stable Core IDs and existing row
names remain unchanged. Manual App Store work is not an executing automatic row.

Rows remain compact, without accordions or selection controls. Real phase/activity
records drive Waiting, Working, Working · Needs Attention, Awaiting Verification
and supported terminal states. The activity indicator is indeterminate; no synthetic
completion percentage is shown. **Stop Rebuild** and **Force Stop** stay in the fixed
footer with separate confirmations. Graceful Stop finishes admitted indivisible work
and stops new admission where supported; Force Stop does not prove quiescence or
rollback. Handled stop, failed and unknown outcomes remain distinct under the
[cancellation contract](#restore-cancellation-safety).

### Restore Result — Visually Accepted

`RestoreResultContent` keeps the operation outcome heading, a Rebuild Summary
completion/Verification card and conditional Needs Attention card, one flat
**Details by Category** container, legend and fixed Done / Refresh
Preview / View Log actions. Refresh Preview remains outcome-dependent. Domain order
matches Progress, with App Store Applications first when supported manual work is
outstanding. Categories start collapsed; nested macOS categories, item explanations
and Expand All / Collapse All retain their existing behavior.

For completed execution, the first card is **Complete — N Verified**. It counts
unique selected requirements that needed restoration in Preview and have a visible,
successfully verified Result item, excluding pre-existing Already Matches and manual
App Store work. It is a conformity count, not a mutation count. **Needs Attention**
uses `RestoreResultSummary.attentionCaption`: evidenced restore issues, apps to install
or apps to check, with correct plurals; incomplete issue counts use **Rebuild work
needs review** rather than an invented number. Needs Attention appears only for
confirmed attention items, a real uncounted issue or an unknown attention count;
a clean zero-issue result omits it. The completion/Verification card always remains.
Confirmed Stopped with Verification not run retains neutral **Not Run** presentation.

`RestoreResultDetails` omits pre-existing matches and empty categories, retaining
planned-and-verified requirements, confirmed changes and actual problems or uncertain
work. A successful category says **Complete**; a successful item shows one green
**Verified**. Installed, Cloned, Created and Applied are not duplicate visible labels.
Planned settings can be Verified without mutation receipts; verification alone never
creates an Applied claim. Failed, Needs Attention, Unverified, relevant Skipped,
Not Run, Partial and Outcome Unknown remain evidence-dependent. Independent category
diagnostics survive an empty item list; original execution evidence stays in the model
and diagnostics. A clean no-change result says no changes were needed, without a
matching inventory. Manual-only outstanding work keeps **Rebuild Completed**; actual
execution problems retain their distinct outcome heading.

The App Store Result row contains only its category, Needs Attention, outstanding
count and **Review App Store Apps**. Names, installation buttons and installation
instructions belong only to the separate manual screen; opening it does not change
selection or evidence.

For a confirmed stopped outcome with `unknown_consequences=false` and final
`verification.status=not_run`, the first card is neutral **Verification — Not Run**,
never a green verified-success card. **Rebuild Stopped**, operation-bound **Stopped
by User** and the warning that completed changes remain are preserved; stopping
before target mutation retains **Rebuild Cancelled**. The Result-only stopped filter
keeps reported completed/attempted work, genuine interruptions, independent problems
and genuinely uncertain consequences of attempted work. It omits untouched selection
and harmless no-ops instead of enumerating the Bundle as Outcome Unknown. Unchecked
App Store requirements do not become confirmed problems. No item becomes Verified
without final Verification. Retry requires **Refresh Preview**, not Resume or rollback.

This narrow stopped projection does not apply to failed, interrupted or unknown-
consequence outcomes. Those retain their existing evidence and uncertainty; partial
completion is not full success. Non-completed outcomes use the first-card title
**Verification**, not Complete. The authoritative [result contract](#restore-result-contract)
and Core terminal evidence remain unchanged.

### Restore geometry — shared primitives and intentional differences

These are source-defined dimensions, not a new layout specification. Selection
shares the Capture geometry above; Preview and Result retain their detailed Restore
columns rather than adopting Capture's compact confirmation chips or minimal Result.

| Element | Current components and measurements |
|---|---|
| Selection hierarchy | `CaptureReviewPresentation.hierarchyStep` is 12 pt: relative offsets 0/12/24/36 pt over the 24 pt `CaptureChildRowGrid` baseline. `RestoreAreaSelectionView` uses 28 pt checkbox slots, 12 pt gaps and 22 pt icons. `CaptureRowColumns` retains the 200 pt status rail, 12 pt column gap, 26 pt trailing disclosure reservation and 16 pt container inset. |
| Selection disclosure | `CaptureGroupHeader` keeps group/subgroup chevrons left and domain disclosures right. Ordinary and Advanced `CaptureExpandButton` controls retain their separate scopes and 42 pt trailing inset. Selection masters are absent from Preview, Progress and Result. |
| Surfaces and spacing | `WorkspaceCardSurface` has an 8 pt radius and quaternary border; workspace margin is 28 pt. Accordion rows have zero stack spacing and 16 pt divider insets. Advanced has a neutral quaternary background at 0.2 opacity and the existing warm header tint. `WorkspaceSectionHeader` uses 13 pt semibold (15 pt when prominent), 1.5 pt divider, 12 pt top / 4 pt bottom padding. |
| Cards | `WorkspaceMetricCard` uses a 44 pt circle icon, 12 pt padding/gap and 8 pt radius. `WorkspaceThreeMetrics` uses 80 pt card height, 10 pt gaps and 220 pt minimum width in its horizontal fit, with a vertical fallback. Restore preserves its own titles, counts and explanations. |
| Preview columns | `RestorePreviewRow`, `RestoreResultColumns`, `RestoreTrailingControls` and `RestoreTrailingReference` share measured Status / Count / Chevron alignment with Manual Installation. Status references use 200 pt; main groups allow natural status width beside their badges. Group leading reservation is 24 pt, plus 12 pt for VS Code; domain title offsets are 36 pt, or 48 pt under VS Code. Headers retain 48 pt minimum height. The automatic list uses 12 pt section spacing. |
| Progress rows | Existing 48 pt minimum row height, 6 pt vertical / 16 pt horizontal padding, 12 pt horizontal gap and 200 pt status rail; narrow rows use the existing vertical fallback. No expandable tree or progress percentage is introduced. |
| Result columns | Category headers retain 48 pt minimum height and 6 pt vertical padding. Result indentation remains 52 pt per nested category depth, plus 36 pt for item titles; items retain 28 pt minimum height and 7 pt vertical padding. Status references remain 200 pt, icons 22 pt with 7 pt text gap, chevrons 12 pt; count pills remain at least 32 × 23 pt. Narrow columns stack when the measured trailing lane leaves less than 180 pt for the title. |

`WorkspaceCategoryTitle` / `WorkspaceCategoryStyle`, native controls, SF Symbols,
system typography and semantic colors remain shared. Group titles use `.headline`,
domain/subgroup titles `.body.weight(.medium)`, statuses `.callout` and secondary
explanations `.caption`. Prerequisites, operation activity, action details and
independent Verification evidence intentionally make Restore more detailed than
Capture. Implementation owners are [RestoreView.swift](../desktop/Macseed/Sources/RestoreView.swift),
[RestoreModel.swift](../desktop/Macseed/Sources/RestoreModel.swift),
[RestoreTasks.swift](../desktop/Macseed/Sources/RestoreTasks.swift) and
[TaskComponents.swift](../desktop/Macseed/Sources/TaskComponents.swift), using the
Capture/shared components linked above. No Core, Bundle or Protocol behavior follows
from visual acceptance.

### Environment Status — Visually Accepted

The **Check** workflow retains full read-only diagnostics and the
existing Match / Differences Found / Needs Attention cards. It compares the
complete selected Bundle reference, independently of Restore defaults or selection.
Matching requirements remain visible; there is no Issues Only filter.

`EnvironmentComparisonView.visibleSections` presents only existing scoped category
rows beneath static `WorkspaceSectionHeader` text/dividers, in this order:

- **Applications & Tools:** App Store Applications, Homebrew Applications,
  Homebrew Packages.
- **Settings:** macOS Settings, with its existing independently expandable children.
- **Application Extras:** VS Code Extensions, VS Code Settings.
- **For Experienced Users:** Git Configuration, Git Repositories / Worktrees,
  Workspace Folders, SSH Configuration, Shell / Zsh and VS Code Workspace when present.
- **Other Findings:** unclassified scoped evidence when present.

Empty headings are hidden. There is no expandable section header, Advanced parent
accordion or VS Code parent accordion. Individual categories retain disclosures,
status labels, nonzero numeric badges and complete item explanations. Disclosures
start collapsed; Expand All / Collapse All includes macOS children. These controls
never run comparison or change the reference. Extras, excluded/no-requirement rows
and extra-only categories retain their existing main-window visibility rules and
remain in underlying evidence; independently supported problems are not filtered out.

The Status-only `EnvironmentComparisonRowLayout` preserves the original **160–240 pt**
trailing allocation until its measured badge rail needs more width. It shares the
widest visible category/child count samples across sibling rows: **152 pt** for the
status label, **8 pt** gap and the measured rail. Three minimum-width pills need
**268 pt**, four **306 pt**; longer numbers are measured rather than clipped.
One/two-badge rows retain the existing allocation when no sibling needs more.
The caller separately reserves **16 pt** edge insets and **14 + 12 pt** for the
chevron/gap; items reserve the same **26 pt**. Leading indentation remains **24 pt**
per depth, reducing to **8 pt** in narrow text space, plus **34 pt** for nested items.
Category rows retain **6 pt** vertical padding; items retain **7 pt** and a **28 pt**
minimum height. Count pills keep their shared dimensions, typography and colors.
Pinned content reserves an **18 pt** native-scrollbar margin without a second scroll view.

The [Status evidence/count contract](#status-presentation-and-counts), fixed footer,
explicit Check Again and Bundle-only Review in Rebuild handoff are unchanged.

### Shared language and intentional workflow differences

Reuse typography, semantic colors, icons, container styling, consistent spacing,
appropriate hierarchy indentation, status alignment, disclosure conventions and
Advanced's visual separation. **Visual consistency does not mean identical screen
layouts.** Do not impose the same card count, tree depth, disclosure structure or
level of detail on all three workflows.

| Workflow | Accepted presentation responsibility |
|---|---|
| **Capture** | Select supported state and create a saved environment; a minimal publication Result is appropriate. |
| **Restore** | The implemented Selection, Preview, Progress and outcome-specific Result above are **Visually Accepted**. Preserve their detailed execution, prerequisite and Verification presentation; do not replace them with Capture's simplified Result. |
| **Environment Status** | Visually accepted static sections and full read-only diagnostics: matching state, differences, unsupported/unavailable observations and independent problems remain distinguishable. It has no selection checkboxes and is not reduced to a single success card. |

All three layouts are accepted. Their different selection, execution, prerequisite,
publication and Verification responsibilities remain intentional; visual acceptance
does not extend Core capabilities or close remaining qualification gates.

## Native appearance and Settings

Use native SwiftUI controls, standard checkboxes/toggles, SF Symbols, system
typography, semantic colors and native light/dark appearance. Keep keyboard and
accessibility behavior, text plus icons, quiet hierarchy and restrained surfaces;
avoid terminal styling, excessive cards, decorative gradients and unnecessary modals.
The shell uses an inset/material sidebar, neutral workspace and rounded header.
Blue denotes interaction/selection; Light and Dark share the same spatial hierarchy.

General Settings owns one persistent Appearance enum: System (default), Light,
Dark. System removes the override; Light/Dark set application appearance as the
single owner. Windows, SwiftUI content, Settings and native dialogs inherit it,
without separate color-scheme overrides. This has no Core/Blueprint/Bundle meaning.
Operation Logs opens the shared viewer/history; Diagnostic Report belongs to the
selected operation. General is **440 pt** wide and vertically content-sized, retaining
the Appearance control and Operation Logs tab. Obsolete development instructions
are absent; DEBUG functionality is unchanged.

### Homebrew setup — implemented, visually accepted

Homebrew setup is a single native SwiftUI window shared by first launch, General's
**Tools & Dependencies**, and selected Rebuild prerequisites. The approved Home and
workflow contents remain unchanged. A synchronous main-thread entry pumps its run
loop while a bounded read-only check runs asynchronously, then starts the regular
SwiftUI app outside any suspended concurrency job. This avoids holding MainActor
inside `App.main`. The startup gate has a six-second fallback to Home/Unknown; a
late result cannot reopen setup over Home. Disabled reminders open Home immediately
and check availability afterward.

On macOS 15+, only confirmed absence on a supported platform presents setup first;
Home is suppressed and not created behind it. Healthy, broken, unknown and
unsupported configurations open normal Home without flashing setup. macOS 14 keeps
normal Home launch and manual dependency guidance. Public scene launch/restoration
controls prevent restoration from bypassing the initial gate. Setup becomes key;
Not Now, native close, or a successful fresh Check Again opens Home. General offers
**Setup…** when Available, **Install…** for supported absence, and **Details…** for
diagnostic states. Setup opened from Settings stays open after Check Again, keeps Home available,
and returns focus to Settings on Done or native close. Available shows a positive
status with no missing warning or installation choices. Completing or dismissing setup
updates scene launch policy, so closing Home and reopening the app during the same
launch does not repeat the reminder.

**Show Homebrew setup reminders on startup** defaults on. The setup checkbox is an
inverse draft of that preference at automatic startup: Not Now commits it; the native close control
never commits it. A previously explicit deferral is migrated. Settings can always
open setup and re-enable reminders. Manual setup omits the startup checkbox and
never changes the preference on opening or closing. Suppression never alters actual prerequisites.
The compact warning uses a semantic yellow icon, dark gold text in Light Mode and
system yellow text in Dark Mode; no large warning surface is added.
The 700 pt setup content uses native content sizing, with no repeated window-title
heading. Two full-width native buttons offer **Install with macOS Installer** and
**Install via Terminal**. Initially neither method is expanded. Installer starts
the download immediately; Terminal replaces its content with manual instructions.
Switching to Terminal, Check Again, Not Now or closing setup cancels pending
acquisition/verification. Verification uses **Cancel**. Cancellation immediately
invalidates progress updates and the handoff intent; another attempt waits until
the cancelled worker finishes. Late results/errors cannot open Installer.

The app-local Swift probe requires no source checkout, Python, shell profile or
developer tools. It checks canonical `/opt/homebrew` and legacy
`/usr/local/Homebrew` layouts, rejecting unexpected symlinks, ownership and
world-writable files or non-administrator group-writable files rather than executing
arbitrary PATH candidates. A noncanonical PATH candidate blocks an absence claim. `brew
--version` and `brew --prefix` must succeed with consistent output. Each read has a
two-second deadline, 64 KiB output ceiling, an isolated process group, EOF and a
fresh process-group check before success; the root is held unreaped during cleanup
to avoid signaling a recycled PID. The environment disables updates, analytics and
sudo and excludes inherited shell/Ruby/Homebrew overrides. Partial installations,
permissions failures, unexpected locations and incomplete observations fail closed.
This is basic availability, not selected Rebuild capability or cryptographic
attestation of user-owned Homebrew. Noncanonical installations are not automatically
executed or repaired. Core installation, supervision, Protocol V1 and Bundle
contracts remain unchanged; the former private Python setup worker is retired.

**Upstream policy reviewed 2026-11-03:** [installation guidance](https://docs.brew.sh/Installation)
and the [current official shell installer](https://github.com/Homebrew/install/blob/HEAD/install.sh)
restrict new installation to Apple Silicon; the installer defines macOS 15 as its
oldest supported version and 28 as the next unsupported version. Macseed therefore
offers automatic pkg acquisition and the Terminal command for macOS 15–27 on Apple Silicon. Intel,
older systems, unknown architecture and unqualified future versions receive no
installer action. Existing Intel Homebrew can still be observed as usable. This
policy is independent of Macseed's macOS 14 deployment target and must be reviewed
when upstream support changes.

`HomebrewPackage.swift` owns acquisition, independent of Core and Rebuild. It resolves
the [official latest release API](https://api.github.com/repos/Homebrew/brew/releases/latest),
rejects drafts/prereleases and inconsistent metadata, and selects exactly one
`Homebrew.pkg`. An immutable plan binds release/asset IDs, stable version, exact
official asset URL, size and SHA-256. Metadata is limited to 2 MiB/30 seconds;
packages to the advertised size, at most 512 MiB/15 minutes. The ephemeral
URLSession streams to an exclusive mode-0600 partial file. Redirects are limited
to the planned URL and the Homebrew/brew repository's path on GitHub's release
asset CDN; HTTPS, normal TLS validation and bounded redirect counts are mandatory.

Before opening the system Installer, Macseed requires the official release plan,
size/SHA-256, a valid `pkgutil --check-signature` result and the exact pinned
publisher **Developer ID Installer: Patrick Linnane (927JGANW46)**. The pin follows
Homebrew maintainer/signer confirmation in [discussion #5557](https://github.com/orgs/Homebrew/discussions/5557),
reviewed 2026-11-03; rotation requires another explicit review. Generic Apple signing
is insufficient. Bounded, cancellable `xar --dump-toc` reads only certificate metadata,
never payloads. All three DER certificate fingerprints must match pkgutil's signing
chain, and the leaf common name must match the pin. Certificate dates must be current
both before and after trust evaluation; a historical timestamp does not extend them.

`security verify-cert` independently evaluates that chain with Apple's specific
Developer ID Installer policy, OID `1.2.840.113635.100.1.103`, and requires a positive
OCSP revocation response (a still-valid cached response is allowed). The result
must be implicit system trust with revocation checked; user-explicit trust and
unknown result formats are refused. Apple's
[policy definition](https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecPolicy.c)
and [identifier list](https://github.com/apple-oss-distributions/Security/blob/main/OSX/sec/Security/SecPolicy.list)
define Apple anchors, three certificates, Developer ID intermediate/Installer leaf
markers, the Installer EKU and strong keys. Unknown/unsupported policy, unavailable
revocation evidence, invalid dates or uncertain chain trust blocks handoff. Temporary
DER files are private, exclusive, removed after evaluation and covered by abandoned
staging cleanup; no certificate is imported into a keychain.

| Observed system assessment state | Required policy before handoff |
| --- | --- |
| Enabled | Complete, accepted, non-overridden structured assessment with the pinned origin and `Notarized Developer ID`, plus every authenticity check above. |
| Disabled | Exact `spctl --status` disabled result and a complete structured `security disabled` override; these are **not Gatekeeper approval**. Every independent authenticity check above must pass. |
| Unknown, inconsistent or rejected | Fail closed, including a negative original verdict hidden under an override, any assessment error, unexpected override or changed mode. |

System status and raw assessment are checked again after certificate evaluation;
SHA-256 and actual Homebrew absence are rechecked before external handoff. The
disabled path authenticates the expected Homebrew release bytes and Apple-issued
signing identity. It does **not** establish independent notarization, a malware scan,
Gatekeeper approval or safety of every action in the publisher's installer. Missing
stapling alone is not failed notarization. Both paths require the user's explicit
**Install with macOS Installer** action; macOS Installer retains its ordinary prompts
and authorization. Macseed never silently installs, changes security settings,
removes quarantine or overrides an explicit rejection. **Open Official Download
Page** remains the fallback for failed or uncertain identity/trust.

Private mode-0700 staging lives under the app's HomebrewPackages cache. Failed or
cancelled acquisition/verification removes its directory after the worker returns.
A process-held file lock protects active work from other instances and cleanup;
abandoned acquisitions are swept at model creation and before another download.
Before the non-cancellable external handoff, Macseed records the kernel boot-session
UUID. The read-only package then survives setup/app closure and uncertain launch
failures. A different boot session proves its old Installer/installerd readers
cannot remain active; the next Macseed launch or download safely removes it.
Installer exit, elapsed time and PID reuse are not deletion evidence. Legacy files
without a marker are conservatively adopted for the current boot. Unknown ownership,
unsafe paths or unavailable boot identity fail closed. At most four staged packages
(up to 2 GiB of package data) are admitted; a full cache blocks further downloads
with restart/reopen guidance and the official-page fallback. No in-use package is
deleted to make room. Opening Installer does not imply installation or readiness;
macOS handles authorization, and only **Check Again** can establish availability.
No shell installer, `sudo installer`, password collection or automatic Rebuild is used.

**Install via Terminal** displays the command
from [brew.sh](https://brew.sh/), with Copy Command and Open Terminal. Macseed never
executes that command, injects keystrokes, handles passwords or changes shell files.
The user runs the installer and handles authorization externally. Page/Terminal
opening is not installation evidence; failure/cancellation remains absent, broken
or unknown until a fresh check establishes usability.

From Prerequisites, Check Again also requests fresh Core Prepare and regenerates
Preview, retaining selection and never starting Rebuild. The native setup window
and reminder control are visually accepted; this is separate from installer qualification. Injected platform checks do not qualify
real macOS 15/26/27 or Intel hardware, and neither fixtures nor a development build
qualify clean-Mac installation. Native checks on an Apple Silicon development Mac running macOS 27.2 covered the
actual Debug app's initial scene, focus, both external-action intents, reminders
across launches, Settings entry, native close, fresh checks, delayed/unknown startup,
and healthy real Homebrew. Native Tab/Return passed with Keyboard Navigation
explicitly enabled for the check and restored afterward; Escape passed in the
ordinary session. Browser/Terminal/clipboard effects were injected in the UI matrix;
no installation was attempted. The real RestoreModel plus its isolated Core fixture
verified fresh Prepare/Preview and no Execute. These boundaries are distinct from
real installer/clean-Mac qualification. See the
[focused native startup runner](../desktop/Macseed/README.md) for acceptance scope.

**Package qualification:** on 2026-11-03 the official 7.0.12 asset (release
431225594, asset 701066861, 152451269 bytes) matched its release SHA-256 and pinned
signer. `pkgutil` reported the Apple chain and trusted notarization. This host's
Gatekeeper result was `accepted` with `override=security disabled`; the raw result
contained no negative original verdict. [Apple's assessment implementation](https://github.com/apple-oss-distributions/Security/blob/main/OSX/libsecurity_codesigning/lib/SecAssessment.cpp)
explains why the override is not approval. `stapler validate` exited 65 because the
asset has no stapled ticket; independent notarization remains **unconfirmed**.
`stapler` is only a developer diagnostic, not a runtime requirement or an admission
gate in the disabled-authenticity policy.

The complete production verifier passed read-only on those same release bytes with
the disabled policy: signing-chain binding, the specific Apple Developer ID Installer
policy, current certificate dates and positive revocation evidence passed. This
qualifies local package authentication, **not real Installer launch or installation**.
Injected tests cover enabled acceptance/rejection, disabled authenticated/invalid
signer/checksum cases, unknown status, cancellation and healthy-Homebrew protection;
additional cases reject invalid signatures, overridden original denials, certificate
substitution, uncertain trust and validity/mode changes during verification. Real
Homebrew remained usable with unchanged brew bytes and Cellar/Caskroom versions.

Focused tests cover all requested Download/Verification cancellation and dismissal
paths, rapid repeated clicks, late success/error/progress, manual-window close and
uncertain handoff failure. Network/trust/Installer dependencies are injected; native
window close and the cancellable process reader are exercised directly. Cache tests
simulate boot changes and abandoned owners; no reboot or installation is performed.
Light/Dark presentation checks retain approved geometry and render the verification
**Cancel** label. Real Installer launch/installation remains **unqualified** and was
not attempted; macOS 15/26, clean Macs and other hardware require their own real gates.

The standard About panel shows the existing icon/name, tagline, version and build
from `CFBundleShortVersionString` / `CFBundleVersion`, and the Core capability
`productVersion` only when available. It includes MIT License,
[GitHub Project](https://github.com/jetiaks-AKS/macseed) and
[Report an Issue](https://github.com/jetiaks-AKS/macseed/issues). No versions are
hardcoded, no Core operation is started by About, and both entry points use
`MacseedAbout.show`. Default Bundle location, confirmation
preferences, Open Logs Folder and an updater are not implemented controls.
Preferences must never bypass fresh-plan confirmation or secure import consent.

The approved blue/lilac leaf is shared by Sidebar, Home and AppIcon. Home's hero
and three action tiles share a centered 1080 pt maximum-width container; three
columns remain at supported main-window widths, stacking only in narrower contexts.
Text spacing stays stable and Settings is pinned below sidebar navigation.
Capture, Restore and Status use blue, green and violet task icons/action cards;
Settings keeps a neutral gear. Only explicit actions start work.

Both build paths use static `Macseed.icns` through `CFBundleIconFile`, also applied
to the running app. Asset variants come from the same mark; system-icon scale is
22% larger without changing Hero/sidebar scale. See [asset generation](../desktop/Macseed/README.md#branding-assets).
Native sidebar checks measure usable detail width after safe-area insets; raw
frame width alone is not sidebar occupancy. Retain native assertions and investigate
new failures without reopening the accepted design merely from historical incidents.

<a id="capture-this-mac"></a>

## Capture

**Scan → Review / Select → Destination / fresh preparation → Confirm → Result**
uses content states in one workspace, not mandatory wizard pages.

1. Scan calls `capture_prepare` with `selection: null`. Indeterminate progress uses
   real Core phase messages, without numeric domain progress. Private staging does
   not replace ordinary Generated Configuration/Blueprint or rebuild the source Mac.
2. Review uses Core inventory status and `selection_mode`. After each fresh Scan,
   select eligible ordinary requirements; leave Advanced and unknown domains OFF.
   This changes Desktop defaults only: Scan still observes the complete inventory.
   Unavailable, observation-error and unsupported
   rows stay unselected with reasons. Category-only rows have one checkbox and
   read-only details; item domains support all/none/mixed selection and bulk actions.
   Whole-category and subset selection never overlap. Empty scope disables saving
   with **Choose supported state to capture**. Fully selected item domains send
   whole-category V1 selection; partial domains send IDs. Oversized partial requests
   fail visibly under the existing V1 limit and need a fresh scan/narrower selection.
3. Review uses one ordinary bordered accordion containing **Applications & Tools**,
   **macOS Settings** and **Application Extras**, plus one separate neutral **Advanced**
   container. All four sections, nested VS Code and domains
   start collapsed after every fresh Scan. Disclosures are independent; expanding
   never selects, prepares or calls Core. Headers use a leading chevron, master checkbox, symbol,
   title and eligible-selection status: All Selected, Partially Selected, Not
   Selected, or Unavailable for an empty eligible scope. Parents add no requirements
   or duplicate counts. Unknown domains remain visible as Other Findings and default OFF.

   Four section masters and the VS Code subgroup master replace text selection
   buttons. Two shared disclosure controls cover ordinary and Advanced independently;
   the [native UI contract](#macseed-native-ui--design--interaction-contract) owns their positions and Review-only geometry.
   macOS retains six independent Finder, Dock, Windows, Keyboard, Trackpad and
   Screenshots selectors; preference labels remain read-only. VS Code Extensions
   retains item selection and Settings whole-category selection. Leading indentation
   leaves domain statuses and trailing disclosure arrows aligned; long item labels
   wrap. Review retains one scrolling list and a fixed action footer.

   Unselected optional limitations do not become selection warnings. Selected
   limitations and real observation errors remain visible; observation errors are
   marked Scan Incomplete. Global metrics count selected limitations and all
   observation errors, while a failed Scan retains its existing failure route.

   **VS Code Workspace** retains `vscode-workspaces` and exact item IDs. Advanced
   directly exposes Workspace Folders, including folder-only Capture. Explicit
   Advanced master selection includes every eligible Advanced domain and
   its items, including folders; clicking a mixed master completes that scope. Ordinary
   actions and disclosure never select dependencies. Core inventory supplies no
   dependency graph, so Desktop does not infer relationships or hide selectors.
   Unknown domains stay outside bulk selection. Core Prepare still validates explicit
   folder/base/parent dependencies and typed conflicts retain Review Selection.

   Confirmation uses the same containers with only the authoritative prepared
   scope, read-only child rows and Ready to Save section summaries. Result shows publication
   outcomes and only affected selected categories. No synthetic
   parent requirements or counts are added. Legacy Bundle and Restore are unchanged.
   Secure Transfer is Advanced's sibling under For Experienced Users and starts off
   on every Scan. Its existing master and individual checkboxes use actual Core
   candidate IDs; Advanced bulk actions never change identities. No secure selection
   sends `secure_identities: []` as before.
4. A native save dialog chooses the destination; Desktop normalizes exactly one
   `.mbt` suffix, then prepares the chosen selection again. Inline confirmation
   shows destination and **Included in this capture**, without repeated aggregate
   counts. Wrapping neutral labels retain independent item/category warnings;
   preparation diagnostics stay in Operation Logs. Back edits Review without resetting
   explicit Advanced choices. Eligible pre-publication dependency failures retain the
   same choices through Review Selection. Edits discard old preparation; defaults are
   reapplied only by a new Scan. Whole domains
   remain whole; macOS details name selected subdomains, and VS Code Settings
   describes `settings.json` only. Fresh confirmation reflects newly observed scope.
5. **Create Saved Environment** sends that preparation's ID. Execute rescans;
   changed inventory requires fresh Review/confirmation, never a silent retry.
   Existing output requires explicit Replace in the Save Panel. Replacement is
   digest-bound; Core validates the new Bundle before atomic publication, preserving
   the old Bundle on failure. Stale preparation shows **Capture Preparation Is
   Outdated** and **Scan Again**, retaining `stale_prepared_capture` and cautious
   publication evidence. Failed/interrupted attempts also require a fresh scan.
6. **Save Complete** requires validated successful Bundle publication. One green
   outcome card contains the exact published domain/item counts. When selected
   scope has qualified limitations, an adjacent amber **Needs Attention** card counts
   distinct affected Core domains; cards stack only when the detail width cannot
   accommodate both. The existing Bundle filename, destination and Reveal in Finder
   follow immediately. A clean result ends there. A limited result adds only affected
   category names and safe explanations with View Log guidance, without another
   summary, repeated count, tree or nested item disclosures. Duplicate structured
   facts appear once; independent issues remain separate. Unselected SSH observations
   and unsupported/unavailable inventory do not become saved-scope problems. Missing
   selected-category observation evidence remains Unverified despite confirmed
   publication. Capture does not claim application health, target Restore or final
   Verification. Failure/cancellation after publication retains the reported location
   and publication fact without success, cleanup or rollback claims.

Scan, Checking Your Environment and Saving Your Environment show compact Core
phases, spinner and cancellation. There is no per-item publication progress, so
no invented waiting task list. **Included in this capture** retains the authoritative
prepared selection and independent ordinary/Advanced expansion. Underlying result
facts still require confirmed domain inclusion and consistent published item counts;
insufficient evidence never becomes a verified category. Core supplies no omitted-item
inventory/count. These are capture facts, not target Verification.

A clean Result fits the minimum 1000 × 700 pt window without detail scrolling.
Only selected limitations add the optional attention section; longer warning lists
use the existing scroll viewport. Primary actions remain
outside scrolling content. Reveal in Finder sits beside the saved file; View Log is
left, Capture Again then Done are right. Capture Again scans
fresh; Done returns to initial Capture without scanning or switching tasks.

Accepted real-Mac cases cover full/category/item capture, publication with and
without warnings, Reveal in Finder, cancellation, stale preparation after source
drift and a successful fresh Scan. This does not qualify macOS visual effects:
[Configuration](toolkit/CONFIGURATION.md#macos-settings) owns exact observed keys,
compatibility and stored-value semantics; [TODO](../TODO.md#macos-settings-manual-qualification)
retains native settings gates.

Secure SSH remains within Capture, not a Credentials area/password vault. The
[16H Capture interaction](#secure-interactions) uses optional, default-off SSH identity
selection and safe names/types/public fingerprints; identities are encrypted separately.
Ordinary SSH configuration stays independent; ordinary Bundle data is private but
unencrypted. Prepare neither unlocks nor proves key pairs. Missing secure tools
permit guidance or continuing without identities; selecting none permits an
ordinary Bundle. Passphrases use a focused native secure sheet.

## Workflow layout and disclosure

Capture Review, Confirmation and Result; Restore Selection, Preview, Rebuild and
Result; and Environment Status results keep fixed information, a scrolling workflow
content region when needed, and the existing fixed action footer. Capture Review's
ordinary disclosure control scrolls with its list; Advanced's control stays with
its divider heading. Capture Result uses outcome cards and affected-category
explanations, not a category tree.
Manual Installation and Automatic Rebuild Tasks share Preview's list viewport.
Preview keeps operation availability, the available Fix Issues action and its
approval guidance above the list. The list contains the single Prerequisites heading
and specific issues when present. A compact read-only notice sits beside the
Rebuild Preview heading; Selection has no duplicate read-only notice.
Headers and progress remain live while the list scrolls. Screens without a list
retain their ordinary content layout. The supported minimum window stays 1000 × 700.

Existing count pills share Restore's oval shape (minimum 32 × 23 pt, 6 pt horizontal
insets and monospaced caption digits). Each tree reserves a common count rail and
an independent rightmost disclosure position. Category status text, icons, colors and
horizontal anchors remain unchanged; counts wrap below if space is limited.
Manual Installation uses the same Preview status column as Automatic Rebuild Tasks.
Matching Preview and Status leaves share a plain green checkmark with the accessible
name Already Matches; category statuses retain their text. Compact Capture Result
outcome cards and affected-category explanations wrap within the detail width.
Leaf rows have no disclosure indicator without an expansion action. Selection
checkboxes appear only for supported selection; checkbox/label hit targets remain
separate from disclosure, and verified status checks remain distinct.
Capture's textual item summaries remain text, and zero counts remain hidden.

Expand All / Collapse All operates on stable IDs for its available scope (ordinary
or experienced independently in Capture; ordinary or Advanced in Restore Selection),
including Finder, Dock, Windows, Keyboard, Trackpad and Screenshots before their
views are created. A partially open tree offers Expand All. Collapse All clears
child disclosure state too. Selection, prerequisites, dialogs and Core operations
are independent of these local presentation actions.

<a id="restore-a-mac"></a>

## Rebuild (Restore)

**Choose Bundle → Selection → Preview → Rebuild → Result**. Inspection and
Verification occur within these states; prerequisites do not add wizard pages.

### Selection and fresh Preview

A native `.mbt` picker starts Core `bundle_inspect`, which owns validation,
categories/counts and encrypted-component presence. Invalid/unavailable/unsupported
input shows **Can't Prepare Restore**, a typed reason and Choose Saved Environment. Inspection
neither proves readiness nor exposes private values. Restore requires the advertised
V1 fine-selection capability; older Core gets an explicit compatibility state.

**Restore Selection — implemented and Visually Accepted.** See the
[accepted Selection contract](#restore-selection--visually-accepted).
Core inventory owns modes, eligibility and stable IDs. The inspected Bundle is the
maximum scope: absent or Capture-excluded requirements and empty presentation groups
are hidden. Legacy inspection without presence flags requires affirmative captured
scope evidence. Captured unsupported/unavailable requirements retain their diagnostics.
Category-only domains remain whole; item domains permit whole/subset scope. Current
Desktop sends `include_secure: false`; encrypted material is reported separately.

Selection reuses the accepted Capture accordion and its 0/12/24/36 pt hierarchy,
200 pt status rail and disclosure placement without changing Capture geometry.
One ordinary container holds **Applications & Tools**, captured **macOS Settings**
domains and **Application Extras → VS Code → Extensions / Settings**. The separate
**Advanced** container holds captured Git Configuration, Git Repositories / Worktrees,
Workspace Folders, SSH Configuration, Shell / Zsh and VS Code Workspace requirements.
Unknown captured domains retain Other Findings. Group and VS Code tri-state masters
affect only eligible captured descendants. Ordinary and Advanced Expand/Collapse All
controls are independent; disclosure changes never change selection or call Core.

Fresh inspection selects eligible ordinary requirements; Advanced and unknown domains
start unselected. An Advanced-only Bundle needs explicit selection before Preview is
available. Back, Refresh Preview and re-entry preserve deliberate choices; selection
edits invalidate preparation through the existing lifecycle. Review cancellation
compares against these initial defaults. Inspection does not provide individual macOS
preference keys, so Selection displays only its actual aggregate domains. VS Code
Workspaces retains per-descriptor stable IDs and safe names;
missing folder/base/parent dependencies require explicit selection correction.
Preview retains planned create/change, matching and conflict findings; Result uses
the [accepted outcome-specific labels and filtering](#restore-result--visually-accepted).
See the [descriptor contract](toolkit/CONFIGURATION.md#vs-code-workspace-descriptor-restoration--phase-5).
Fully/partially/not-selected counts describe selectable Core categories,
exclude unavailable categories and do not replace Preview item metrics.

Selection status and Preview Rebuild stay in the fixed footer. Preparation shows
indeterminate **Preparing Rebuild Preview**, explaining that target state is unchanged.
`restore_prepare` returns prerequisites, plan and matching/changed scope. Bundle
changes invalidate preparation. The production UI changes selection through
**Back → Review → fresh Preview**; Preview has no selection checkboxes. The model's
draft-edit path retains immutable Preview evidence and disables Rebuild until explicit
**Refresh Preview**. Counts/readiness still describe the prepared scope. Excluded
domains remain available for reselection; excluding SSH removes its prerequisite
without weakening checks when selected. Back retains selection but requires fresh
Prepare. Failed/cancelled/interrupted refreshes clear old Preview evidence.

**Rebuild Preview — implemented and Visually Accepted.** Automatic
Restore Tasks uses one ordinary accordion for Applications & Tools, macOS Settings
and Application Extras → VS Code, plus an experienced container below
For Experienced Users. Advanced and selected Secure Transfer are sibling rows in
that container. Only domains in the effective plan appear; unknown domains
retain Other Findings. Domain actions, statuses, diagnostics and nested macOS
preference details retain their existing renderers. Numeric badges appear only on
the four ordinary/Advanced main groups and the selected Secure Transfer sibling,
aggregating original plan rows once; nested domains retain their status labels.
The Secure Transfer extension has separate Stage 16H manual E2E acceptance;
the historical ordinary Preview visual acceptance is unchanged. Automatic task disclosures use the far-right indicator without
moving titles or status columns. Preview has no selection controls. Expand All /
Collapse All sits beside Automatic Rebuild Tasks and retains its group, VS Code
and macOS child scope. Prerequisites retain their category statuses, explanations
and disclosures; the duplicate overall status and general Tasks heading are omitted.
Section spacing is compact; Manual Installation, summary cards and footer remain.

Summary cards are **Already Match → Changes Planned → Need Attention**.
Nonzero Match/Planned/Attention badges use green/blue/amber in that order and count
Core plan items once: child counts are not added again to their parent. Manual App
Store requirements never inflate automatic metrics. Prerequisite summaries identify
affected areas/counts; lower domains own concrete items and short reasons.

Preview exposes reported installs, settings writes, backups, clones/branch actions
and restarts. Unknown observation is never a planned mutation. No private values,
remote URLs or credentials are needed to explain actions. Homebrew Applications and
Packages stay separate through Preview, Rebuild and Result. Qualified repairs show
Will Repair / Ready to Repair and Repairing; finishing execution awaits Verification.

Desktop supports topology-aware Rebuild Preview and confirmed Rebuild through Core.
Clone, Add Worktree and HEAD changes use existing progress and Verification-aware
Result presentation. Dependent actions show Conditional until Core can inspect the
created base; conflicts and Unsupported/Unverified requirements stay visible.
Rebuild requires ready prerequisites and executable changes. An all-matching plan
shows No Changes Required; it does not start Execute. Partial/unknown outcomes do
not become full Success. Graceful Stop and fresh-plan re-entry retain the existing
lifecycle. See the [Workspace contract](toolkit/CONFIGURATION.md#topology-restore-execute--phase-4).

### Prerequisites and consent

All-satisfied prerequisites use a concise Ready summary with optional disclosure;
redundant ready rows without actions are hidden. Independent actionable/manual
conditions remain visible. Group only compatible domain/scope/reason/action records,
without changing item counts or hiding independent problems. Core reports all cask
conditions and the first operation-wide blocker in other domains; resolving one
may reveal another. Do not imply exhaustive readiness.

**Fix Issues…** appears only for supported PKG preparation or Automation access.
Ordinary Preview never prompts for permission or downloads installers. Fix Issues
checks Automation first, prompting only if undetermined; denied/restricted access
needs System Settings or administrator recovery. Explain System Events access for
login-item inspection. A fresh Prepare clears only resolved warnings, retaining
independent issues and the same current selection.

PKG preparation lists concrete casks and requests separate consent to download and
inspect inert installers. Consent binds the displayed identities/current selection;
changed or expired identities need new consent. Refusing PKG-only preparation keeps
Preview; after an Automation check it rechecks without PKG consent. Inspection
produces a new Preview requiring separate Rebuild confirmation. Exact lifetime,
identity and execution rules belong to the [Core contract](core/APPLICATION-INTERFACE.md#explicit-pkg-installer-preparation).

Rosetta remains an item-scoped manual Terminal prerequisite with **Refresh Preview**;
Fix Issues never installs it. Distinguish a required installation from a failed
check. Missing Homebrew requires external installation. Explain Command Line Tools,
`mas`, VS Code CLI or network only when relevant. A missing/damaged bundled age
requires rebuilding/reinstalling Macseed, not installing an external tool. Administrator, Apple ID,
SSH agent/known-host and vendor authorization are external actions; native dialogs
may appear. Never invent Fix All or feed credentials into Core's closed stdin.
`safely_satisfiable` is a Core capability, not authorization for a client mutation.
Homebrew confirmation explains its separate masked administrator prompt.

Item-local unsupported casks/no-action conflicts remain visible while independent
executable work can proceed; global prerequisites still block Rebuild. Unsupported
is not promised to become executable after recheck. An all-unsupported or zero-change
plan has no executable Rebuild. Privileged uncertainty blocks Homebrew re-entry even
if payload checks succeed. No force overwrite, reset, cleanup or removal is offered.
Unknown reasons get neutral guidance and their code in Operation Logs.

### Rebuild and Result navigation

Rebuild requires a ready, current prepared plan with executable changes and unchanged
selection. Native confirmation sends the exact ID/selection; it never silently
prepares again. Core revalidates before mutation. A later network/account/tool
failure remains possible. **Restore Plan Is Outdated** directs `stale_plan` to
Refresh Preview; “no changes” is shown only with explicit no-mutation evidence.
Structured freshness evidence retains prepared/requested/recomputed IDs and available
component fingerprints; missing components remain unknown, and changed planning
facts do not prove target mutation. [Core](core/APPLICATION-INTERFACE.md#restore-plans-and-re-entry)
owns the fields. Workflow uses concise guidance and View Log; diagnostic export
uses the shared immutable report under its existing privacy allowlist.

Activity uses real phases/records, never synthetic percentages. Normal Execute
includes Core Verification; incomplete/failed/interrupted work retains only available
evidence. Result distinguishes completion, attention, failure, cancellation and unknown
effects under the [result contract](#restore-result-contract). **Refresh Preview /
Check Current State** retains Bundle/selection and prepares afresh; **Done** clears
the session. Re-entry is not Resume. Session ownership survives window closure;
close/reopen/quit behavior still needs remaining lifecycle qualification.

Stop Rebuild always confirms, with Continue Rebuild the default/Escape action.
Accepted Graceful Stop finishes indivisible work/post-checks and stops new admission;
Force Stop is a separately confirmed emergency action. Neither implies rollback or
universal native-installer interruption. See [cancellation](#restore-cancellation-safety).

### Assisted App Store Restore

App Store Applications comes first inside Applications & Tools in Selection,
followed by Homebrew Applications and Homebrew Packages. VS Code Extensions and
Settings appear under Application Extras → VS Code.
Selection counts retain requested Bundle IDs; Preview uses effective requirements
after confirmed Cask precedence. Refresh/back navigation preserves requested scope.
Unresolved overlap retains both requirements; App Store-only selection stays valid.
Identity, cache/provenance and protected App Store target rules are owned by
[Configuration](toolkit/CONFIGURATION.md#other-application-generated-inputs).

Preview puts one App Store card under **Manual Installation**, after applicable
Prerequisites and before **Automatic Rebuild Tasks**. There is no general Tasks
heading. Expand All / Collapse All sits beside Automatic Rebuild Tasks and changes
only its local automatic disclosure tree. Manual/automatic rows share status geometry;
width references contain distinct status/disclosure combinations, not copies of the
whole inventory per row. **Review App Store Apps** opens a dedicated screen without
reloading the Bundle or changing selection.

That screen shows **Installed — N of M selected**, or **All Installed**. Needs
Attention has no aggregate number; its text separates missing/unverified counts.
Hide zero metrics. All effective apps appear immediately in one surface, ordered
Missing, Unverified, Installed, without a repeated category header/disclosure.
Missing/Unverified rows retain **Open in App Store** via validated numeric IDs and
`NSWorkspace`. Opening a page changes no installation evidence. **Not in App Store**
means the provider requirement is unsatisfied, not physical absence.

**Refresh Status** performs existing Core preparation with the same selection.
From Result it starts a fresh Preview; returning without refresh preserves Result.
**Cancel Refresh** is available only during that screen's read-only Prepare and
uses CoreRuntime cancellation bound to its operation ID. Confirmed cancellation
shows **Refresh cancelled**, retains the Bundle and selection, and enables Back
and retry. A valid completion wins a cancellation race; missing terminal evidence
shows an interrupted refresh instead. Failed/cancelled refresh clears stale
installation claims; no Execute stop or confirmation is involved. App Store-only plans have no
executable Rebuild; manual issues do not block independent automatic work. Apple
App Store owns installation/account authorization. MASHelper/XPC and automatic MAS
installation remain retired, including deployment/registration paths.

Result presents the execution outcome, then **Rebuild Summary**:
the completion/Verification card always remains; Needs Attention appears only for
confirmed attention items, a real uncounted issue or an unknown attention count.
A clean zero-issue result omits Needs Attention. Complete / N Verified and the
conditional Needs Attention card retain their evidence-based descriptions
(apps to install, apps to check, restore issues or work needing review). Complete counts unique selected
requirements that were planned for restoration and now have a visible Verified result;
pre-existing matches are excluded. Unknown attention counts remain unnumbered.
For partial, failed, interrupted or stopped execution, the first card says Verification
instead of Complete; the authoritative outcome heading remains. Confirmed Stopped
with Verification not run uses neutral Verification / Not Run. Completed execution
with only manual work remains completed; real failure,
partial/interrupted/stopped outcomes retain their meaning. No repeated attention
section or separate Verification-details disclosure is added.

Previously planned requirements remain visible as Verified even without mutation
receipts. Verification counts final conformity, never inferred writes; item receipts
and domain-level changes retain their original scope in diagnostics. Missing mutation
receipts alone do not create Needs Attention. Successful categories display Complete;
successful items display one Verified label, without duplicate action labels.
Result keeps Needs Attention, Failed and Unverified, retaining relevant
Skipped, Not Run and unknown outcomes. Execution details remain in diagnostics.
A clean result with no changes or issues says no changes were needed.
Stable requirement identities merge repeated operation/Verification consequences.
Linked launcher diagnostics describe one current-operation issue; a destination
conflict does not prove a foreign installation. Manual IDs count once and never as
automatic successes. Independent category issues remain; uncertain independent issue
counts omit the number. Unrun requirements and unreported restarts are not failures
or successes. Models, logs and reports preserve conformity/completeness separately.

Restore Progress and Result render existing domain rows in one flat container,
without intermediate section headings, following the accepted Restore category order.
**Details by Category** puts the App Store Applications row first when manual scope
still needs attention. Result includes previously planned requirements with final
outcomes, confirmed changes and outstanding or uncertain work. Requirements already
matching before Restore and empty categories are omitted. Selected
category-level diagnostics remain even when all their item rows are omitted. Manual
App Store Result contains only the category, outstanding count, Needs Attention and
Review App Store Apps; the dedicated screen owns app names and installation actions.
Result categories start collapsed;
Progress stays compact and retains its complete selected scope.
Expand All / Collapse All and the fixed footer remain. Short explanations preserve
independent problems; technical evidence belongs in View Log.
Confirmed Stopped with no unknown consequences and Verification not run uses the
neutral **Verification — Not Run** card and the attempted-work filter, excluding
untouched requirements and unchecked manual apps. See the complete
[accepted Result contract](#restore-result--visually-accepted) for outcome boundaries.

<a id="environment-status"></a>

## Check (Environment Status)

Environment Status supports legacy Bundles and validated Workspace Topology v1
Bundles, including selected base/linked/nested checkouts, Workspace Folder structure
and VS Code descriptor relationships. [Configuration](toolkit/CONFIGURATION.md#topology-environment-status--phase-6)
owns the bounded comparison contract. [Roadmap](../ROADMAP.md#complete-workspace--git-worktree-restoration)
records Phase 6 and bounded real-Mac Core E2E acceptance; native Desktop E2E with
that selected Bundle, full SIGTERM recovery and packaged qualification remain open.
The existing layout and [Bundle-only handoff](#bundle-handoff) are preserved.

**Choose reference → Compare → Result** uses inline Domain → Items disclosures.
The initial Choose Saved Environment card owns reference selection and its read-only
notice. Normal Desktop selects an explicit `.mbt` through a native picker, displays
the filename and clears old results without comparing automatically. Generated
Configuration/Blueprint controls are not exposed. Never substitute ambient state,
run Discovery or compare a new scan of this Mac with itself.

Core `environment_compare` validates/stages the Bundle privately, preserves its
Blueprint/provenance, compares read-only and removes staging without publication or
secure decryption. Older capability evidence gets an explicit compatibility state.
References are window-session-local. **Check This Mac**, **Check Again**, Cancel
and Choose a Different Environment are explicit; Restore never auto-runs Compare.

Only a completed validated result can show conformity. Failed/interrupted/malformed
or contradictory results and mutation/publication claims cannot retain a clean prior
conclusion. Empty comparable scope says **No comparable requirements**; invalid or
unavailable input asks for another reference, changed input needs a fresh check.
Confirmed Cancel returns to selection retaining the Bundle; missing terminal evidence
is interrupted/unknown. Internal staging/reporting I/O failure is not automatically
`bundle_unavailable`, which describes source availability.

### Status presentation and counts

Results show Match, **Differences Found** and Needs Attention; Not Applicable appears
only for Core Coverage `no_requirement`. Zero metrics are hidden. Excluded,
unsupported, unverified and unresolved scope never becomes Match. Different/Missing
are red, Match green, attention/unsupported/unverified amber. Different + Missing
forms the red Differences Found summary, with a compact nonzero breakdown; precise
leaf statuses and Core predicate totals remain intact.

Needs Attention counts independent unverified/unresolved evidence, including
Unsupported once. Confirmed differences and dependent checks blocked by a proven
absent repository do not add attention counts. Uncountable independent diagnostics
show **Unsupported or incomplete checks** without a fabricated number. Overall
confirmed differences alone produce Differences Found; incomplete run integrity
prevents a clean conclusion. Category Needs Attention takes precedence when
independent warnings/gaps coexist with differences.

Details use the [accepted static sections](#environment-status--visually-accepted);
macOS Settings nests independently collapsed Finder, Dock, Windows, Keyboard,
Trackpad and Screenshots with Capture's labels. Git Repositories / Worktrees precedes
Workspace Folders in For Experienced Users. Matching categories show Already
Matches plus applicable counts; matching leaves use an accessible checkmark without
generic subtitles. Problem rows retain short explanations and independent diagnostics
correlated by owner/domain/item ID; technical evidence stays in Operation Logs.
App Store names use validated Bundle labels; missing labels stay neutral, IDs remain
in Core/model evidence. Absent `stored_preference` means the saved preference is
not explicitly set, not that a feature is missing or a system default was inferred.

Category pills count visible logical items; Different/Missing combine once. Each
legacy repository gets one outcome from Worktree/Origin/Branch evidence: an absent
worktree with only dependent prerequisite failures is Missing; incomplete/unsupported or
independent failures retain attention. Core predicates/IDs remain unchanged.
Topology checkouts use one `topology` predicate; descriptors require
`folder_relationships`, not file presence. Technical facts correlate by exact
record/domain/item identity. Validated repository names and descriptor basenames
are display-only; missing or unsafe metadata uses neutral labels. A confirmed
relationship/HEAD/origin difference is Different even when Restore cannot safely
change it. Missing dependencies, conflicts and unsupported/failed observations
remain Needs Attention; they never become Match or implied Restore permission.
Excluded inventory, extras and extra-availability rows are hidden only in the main
window, including extra-only categories. Extras affect none of the main outcome
counts; logs/reports retain their existing projections. Unavailable evidence is not
zero. [Core comparison](core/APPLICATION-INTERFACE.md#verification-and-environment-status)
owns provenance and provider-specific App Store absence; no cleanup/removal is implied.

A shared lane covers categories, macOS children and leaves, retaining the baseline
160–240 pt allocation and expanding to the measured visible badge combination as
documented above. Indentation affects names only; sibling rows share the measured
status/count alignment. Chevrons use
a separate trailing rail. Result actions use the fixed footer; Choose/Failure
controls stay with content, Cancel left below the process card. Whole-tree
Expand/Collapse includes macOS children before views are created.

### Bundle handoff

Status and Restore keep independent session state. Entering Status without a
reference takes the current Restore Bundle, but still needs explicit fresh Compare.
A completed Bundle-based result with Core-confirmed Different/Missing offers
**Review in Rebuild** beside Check Again. Coverage warnings alone, development
references, failed/cancelled/active comparisons do not. Active operations and Rebuild
confirmation block handoff without stopping/replacing work.

Only the original `.mbt` URL is passed: no automatic difference selection, Prepare,
Preview or Execute. An empty Restore session performs its own read-only inspection
and ordinary Selection. The same Bundle preserves Selection/Preview and existing
error/refresh semantics. Replacing another session requires **Replace Current Restore
Session?**: Cancel leaves both sessions intact; Use Selected Environment inspects
fresh. Comparison never proves Restore eligibility. Inspection errors remain ordinary
Restore errors; the user explicitly selects, previews and confirms Rebuild.

Bundle-backed Status and this handoff have real-Mac GUI acceptance; runtime/packaging
hardening remains separate. [Future Environment Manager](../ROADMAP.md#environment-manager--post-10--future-direction)
may use multiple references but adds no current Profiles, History, Drift Detection
or Selective Apply. Any future confirmed Apply must reuse Restore Prepare → Preview
→ Confirm → Execute → Verify, with no second engine or deletion inferred from absence.

## Status vocabulary and evidence

Use this small shared vocabulary, with flow-specific titles such as Bundle Created,
Working, Cancelled, Stopped or Interrupted when appropriate. Presentation does
not change Core status, verdict precedence or operation exits.

| UI status | Evidence and meaning |
|---|---|
| Ready | Current step can proceed; not a whole-Mac health verdict |
| Needs Attention | Prerequisite, warning, mismatch, unresolved/unverified scope, partial evidence or interrupted work; show what remains |
| Can't Prepare Restore | Invalid/unsupported Bundle or preparation cannot complete under the current contract; explain scope and alternative |
| Verified | Core confirms selected requirements with sufficient complete evidence; never inferred from operation success alone |
| Already Matches | Preview `satisfied`, or Compare matching evidence; no change needed for that observed scope |
| Not Supported | Core explicitly marks unsupported coverage or execution; distinguish them in the explanation |

Keep operation outcome separate from environment conformity. A failed operation
can have verified items; successful execution can have unverified requirements.
Unsupported is included in unverified, not an additional total. Preserve unresolved
coverage and incomplete/partial/truncated/invalid/not-run details. Differences and
coverage gaps can coexist. Do not show a green overall success when run integrity
is incomplete. Proven empty scope is a no-op, not Verified.

No-change Preview shows **Already Matches** for observed satisfied rows and
“No changes planned”; unknown or pending secure work prevents an all-matching claim.
Zero-change plans do not enable Rebuild; Preview is not final Verify. Clean Result
uses **Rebuild Completed** for the selected supported scope, with evidence-based
category details. Process completion never substitutes for conformity; a stalled
download needs fresh inspection after network/VPN recovery, not a hidden retry.
Counts never mix operation records with unique verified items or double-count
Unsupported. Technical evidence belongs in Operation Logs/Diagnostic Report.
No status proves application health, visual effects, remote SSH authentication,
agent/Keychain readiness or whole-Mac identity.

### Restore result contract

Restore presents Core evidence through dedicated Preview, Progress and Result views.
Progress uses fixed-height category rows and real structured activity. Active work
shows **Working** unless a known problem requires **Needs Attention**. Existing
problem evidence remains in the model without a redundant warning banner below the
running list. Completed/no-op execution items await Verification;
Preview and operation receipts alone never make category statuses green. Complete
category Verification evidence permits independent **Completed** / **Already Matches**
finalization without resetting confirmed categories merely because another phase starts.
Latest category operation, Verification and Coverage records remain in memory
for the current Restore even when the transport event window advances. This
projection is separate from persistent diagnostic logs and is not a Resume journal.

Result finalizes categories independently from complete, plan-bound Verification
of their selected requirements. Missing operation receipts alone are not failures;
Verification confirms final state, not which client performed a mutation. Auxiliary
macOS process restarts are execution steps, not final-state requirements: complete
`stored_preference` evidence must cover every selected setting, without requiring
restart receipts. Other auxiliary actions require execution evidence or a clean
authoritative outcome. Insufficient final evidence is **Unverified**; **Awaiting
Verification** is reserved for running work.
A structured `stale_plan` with `failed_before_mutation`, explicit no target mutation,
and `verification.status=not_run` shows neutral **Not Run** for categories with no
execution/Verification evidence. Other failures retain their evidence-based statuses;
unavailable Verification counts remain unavailable.
A supported item-local skip can produce **Partial Rebuild** only with
confirmed independent success, consistent Verification and no unexplained failure.
The original Core terminal failure remains available.

Result keeps the operation outcome in its heading and the summary documented in
the [accepted Result presentation](#restore-result--visually-accepted).
Complete / N Verified counts only visible planned-and-verified automatic requirements,
once per stable identity; pre-existing matches and manual work are excluded. Needs
Attention uses an evidence-based caption, not a generic item total. The completion/
Verification card always remains. Needs Attention appears only for confirmed attention
items, a real uncounted issue or an unknown attention count; a clean zero-issue result
omits it. Unknown counts remain unnumbered. There is no separate Skipped summary card or
Verification-details panel. Confirmed Stopped with Verification not run and no unknown
consequences uses neutral Verification / Not Run and only reported work or independent
problems; absence of evidence for untouched requirements is not a failure count.

Category/item counters still classify evidenced plan rows into disjoint Success,
Needs Attention and neutral Skipped. Applied/Already Matches without Verification
is explicitly not verified and never enters the top verified-success total.
Failure, mismatch, conflict or blocking unsupported evidence takes precedence;
neutral skips need an eligible reported reason. Not Run/unestablished rows are not
failed/skipped and do not manufacture numeric outcomes. Coverage gaps and incomplete
scope remain visible; global Mismatch/Unverified/Unresolved totals and terminal
codes stay in model/log/report evidence without becoming extra workflow cards.

Confirmed user Stop/Force Stop intent is kept only for the current operation ID in
memory: Stopped by User requires a matching handled stop outcome; Force Stop Requested
never replaces an Interrupted outcome or claims that all work stopped.
The persistent Operation Log preserves safe structured diagnostics; its Diagnostic
Report owns preview, copy and save. Workflow screens have no technical disclosure
or copy fallback. If the matching log is unavailable, say so without a dead link.
Categories convey verified work without a repeated successful-area summary; actions
remain in the fixed footer.

| Result | Required meaning |
|---|---|
| Rebuild Completed | Clean completed outcome, or completed execution with only manual App Store work outstanding; the latter retains Needs Attention and manual review. The Complete / N Verified card counts requirements and is not a separate overall-success verdict. |
| Rebuild Completed with Issues | Completed execution with automatic issues; retain their evidence and explanations |
| Partial Rebuild | Supported independent work completed alongside an item-local skip, with the required typed evidence; the Core failure terminal is preserved |
| Failed | Actual prerequisite, execution or runtime failure prevents completed work under the operation contract |
| Stopped | User cancellation after execution begins, with sufficient evidence of handled termination; completed changes may remain |
| Interrupted/Unknown | Terminal evidence is missing, invalid or incomplete; completion and effects cannot be established |

Known unsupported remaining state alone must not become a generic execution failure.
A blocking prerequisite still prevents execution. A supported item-local skip may
be presented as Partial Rebuild only when Core proves completed independent work
and the required complete final evidence; it does not turn Core failure into success.
Preserve Core terminal codes, exits and Verification verdicts in diagnostic evidence. Current
Protocol V1 can retain exit `2` / `bootstrap_failed` for item failures with
`independent_work_completed=true`; the
[Core evidence contract](core/APPLICATION-INTERFACE.md#independent-homebrew-items)
remains authoritative. User stop with incomplete termination evidence is
Interrupted/Unknown, not a confirmed Stopped result. Cancellation before execution
remains Cancelled. No result promises rollback or whole-Mac identity.

## Restore Result columns

Restore Result's **Details by Category** uses one result-only row layout with
reserved **Status | Count | Chevron** columns across categories, nested settings
and individual items. Missing counts or chevrons retain their cells; left title
indentation still indicates hierarchy. Text wraps within its column as width or
text size changes. Status classification is unchanged; Preview and Capture use the shared workflow
layout described above while retaining their own status and summary semantics.

## Recent Restore qualification and performance

Qualification is bounded by selected scope and observed evidence. Accepted Capture,
Restore/Result, Bundle Status/handoff, shared UI and Operation Logs do not close
Stage 16H, remaining 16I/16K, Stage 3C recovery or packaged clean-Mac gates.

| Retained evidence | What it establishes / does not establish |
|---|---|
| Controlled real Restore, 24 October 2026, baseline `1bd8d85` | User confirmation and retained typed result: exit `0`, **136/136 Verified**, `unknown_consequences=false`; included a Git clone and Firefox reinstall. Not a clean-Mac or linked-worktree topology gate. |
| Existing-Bundle Rebuild, 21 October 2026 | Launcher and complete **118/118 Verified**, zero mismatch/unverified/unresolved. A fresh full Capture → Rebuild → Verify from a new Bundle remains open. |
| [Controlled macOS 27 Restore](toolkit/CONFIGURATION.md#controlled-macos-27-restore-qualification) | **37/37 saved values matched** independently; not full visual effects, every key/write path or cross-version qualification. |
| Homebrew, baseline `778b816` and real-Mac confirmation, 17 October 2026 | Tailscale 1.104.1 PKG Preparation → Clean Install → Verification → fresh matching Preview passed. Unsafe Repair stays Unsupported (`ownership_unproven`); in-place Repair is not implemented. Separate Homebrew removal was not a Macseed capability. |
| Earlier Repair/no-op gates | Keka, Termius and VLC passed Repair → Verify → fresh no-op; generated completions qualified through the Codex cask. Broader metadata/state combinations remain open. |
| User-confirmed VS Code installation | Previously missing extensions were installed. No retained date/build/log or independent inventory measurement was established; reinstall is not pending, while independent inventory/Preview and Extension Pack dependency closure remain open. |
| Partial and stale-plan results | Confirmed independent work can coexist with a Tailscale mismatch and Rebuild Needs Attention. A real stale plan was rejected before mutation with neutral Not Run categories, then fresh Preview/Rebuild succeeded. These do not establish all interruption/completeness cases. |

The [accepted D1–D4/R5 baseline](../ROADMAP.md#current-practical-execution-order)
closes its implementation/automated integration queue, not native process/installer
quiescence, recovery, broad Git capability or release readiness. Keep those gates in
[TODO](../TODO.md), without reopening accepted UI work.

Performance uses the existing [opt-in Core trace](core/APPLICATION-INTERFACE.md#opt-in-restore-performance-trace)
and [pass-local observation rules](core/APPLICATION-INTERFACE.md#verification-and-environment-status).
For reproduction, retain the same Bundle/selection/runtime, record cache/load/tool
conditions, compare complete outcomes and exclude only documented volatile fields.
A disposable installed-state fixture is not an installation benchmark. Existing
[development commands](../desktop/Macseed/README.md#performance-diagnostics) and
production fixtures are the reproducible entry points; historical pairs below are
observations, not a benchmark distribution or a guaranteed CI/per-Mac target.

| Comparable pair at preparation/noop checkpoint ([`d93f9ba`](https://github.com/jetiaks-AKS/macseed/commit/d93f9ba), baseline `1bd8d85`) | Before | After | Retained result |
|---|---:|---:|---|
| Real read-only Environment Status | 19.44 s | 15.00 s | 126 matching, 5 differing, 1 extra; only observation timestamps differ |
| Real read-only Restore Prepare | 31.61 s | 22.39 s | Same complete plan/readiness; all 15 Casks satisfied |
| Disposable noop Execute | 54.96 s | 43.54 s | **62/62 Verified**, exit 0, no unknown consequences; ordered evidence preserved |

Each pair was one same-Mac run with the same Saved Environment and production
Desktop runtime/Xcode Python; caches were not cleared. Warm-cache/load effects
remain possible. The disposable scope used 22 formulas, 24 extensions, 15 Casks and
one folder with native-tool stand-ins rejecting installs. Event equivalence excluded
observation timestamps and prepared-plan identity; Prepare additionally normalized
private fixture roots/stage identity. Nested spans are inclusive, not additive.
No separate Desktop event-delivery stall was established. Earlier differing-action
Restore timings do not establish comparable speedup; Git history retains that detail.
Fresh Apply admission, post-checks, final Verification and every item record remain
mandatory. Neither performance improvements nor test fixtures prove native health,
visual effects, authentication or installer recovery.

## Desktop Visual Unification — Completed

The original Environment Status foundation supplied shared category vocabulary,
icons, surfaces and disclosures. **Native UI Alignment is now complete and visually
accepted on 2026-11-02** across Home, Sidebar, Settings/About, Capture, Restore and
Status. The [native UI contract](#macseed-native-ui--design--interaction-contract)
records the final workflow-specific layouts and naming; it does not require
identical trees or reopen accepted screens. No Core selection,
execution or Verification semantics change with layout. Running Restore rows remain
compact/non-expandable; terminal rows start collapsed and expose safe plan names
plus item-local evidence, including stopped/failed outcomes. Expansion runs no Core
operation. macOS children retain independent disclosure and exact shared labels.

Each terminal item contributes to at most one Success, Needs Attention or Skipped
counter. Verified takes precedence over Applied; Applied/Already Matches without
Verification is explicitly unverified. Current failure/block/conflict takes priority
over earlier Apply without discarding that fact. Execution records match both plan
action and item. Outcome Unknown and confirmed Not Run create no numeric outcome.
Unreported auxiliary restart rows are hidden/countless only when no specific or
unexplained scope failure needs them; never infer Apply or Verification. Category-only
coverage and independent problems remain visible. Running categories have no redundant
lower warning banner; Stop uses neutral Stopping Rebuild wording. Long installer waits
remain a lifecycle limitation, not a reason to alter presentation timeouts.

<a id="restore-cancellation-safety"></a>

## Restore Cancellation Safety — implementation and remaining qualification

Stage 1–2 fail-closed cancellation and operation-wide checkpoint Graceful Stop are
implemented. Negative stop results or unavailable process observation preserve
`unknown_consequences`; Desktop reports Interrupted/Unknown rather than confirmed
termination. [Core](core/APPLICATION-INTERFACE.md#restore-graceful-stop-checkpoints)
owns exact admission, checkpoint and terminal semantics.

Requests latch during preparation and module work. Active indivisible actions and
required post-checks finish; safe checkpoints stop later work around publication,
modules/items/settings categories and Verification. Atomic publication, clone/install,
Git/SSH/Shell configuration and secure import are not interrupted by Graceful Stop.
Already-running Verification may finish; handled Stop does not start a new full-scope
Verification. Homebrew native-launch admission is atomic and receives no graceful
signal. Partial records and actual publication/mutation facts remain authoritative.

Desktop distinguishes delivered **Stop Requested**, accepted **Stopping Rebuild**,
**Stop Unavailable**, delivery failure and terminal **Stopped by User**. Rejected
requests do not leave Stop Requested on an ordinary final result. State is bound to
the operation ID. Force Stop is separately confirmed and available during waiting;
TERM/KILL can leave unknown detached/privileged effects. Neither path promises
rollback, Resume, automatic installer kill/DMG cleanup or global quiescence.

Graceful waiting has no guaranteed bound for an unresponsive installer. Automated
checkpoint/launch-race fixtures and controlled real-Mac Early Cancelled / Partial
Stopped cases passed, but do not qualify every installer timing or interruption.
Existing durable lifecycle/admission journals and uncertainty fences remain implemented;
[Stage 3C reconciliation](core/APPLICATION-INTERFACE.md#stage-3c-reconciliation-boundary),
operation-owned DMG evidence and safe re-entry remain open. Diagnostic logs confer
no recovery authority; manual App Store
installation is outside Core's cancellation boundary. Never detach unrelated volumes
or delete user data to recover.

Retained evidence for those open gates:

- **Firefox busy-DMG incident, 13 October 2026:** Stop during installation was
  followed by `item_install_failed`; direct Homebrew also reported `hdiutil: attach
  failed` / resource busy, and an attached Firefox DMG was observed. Restore later
  succeeded after the mount issue was resolved. This is consistent with interrupted
  cleanup; instrumented evidence did not establish the exact orphaning mechanism.
- **Firefox smoke check, 14 October 2026:** Desktop reported Rebuild Stopped /
  Verification Not Run. Subsequent checks found installed Firefox 157.0.1, its app,
  no Firefox DMG and fresh Preview with 120 Already Match / zero changes/attention.
  No event log tied Stop acceptance to active installation; this does not prove
  interruption during native install or universal installer safety.

## Progress, cancellation and re-entry

Use indeterminate progress with named phases and the latest safe category/item.
Render actual phase, execution/record and Capture/secure events; completed phases
are not percentages. Prepare/Inspect may expose only start/result: show Checking
without invented substeps. A result stays provisional until valid terminal evidence;
invalid transport or unexpected exit is Interrupted, never inferred completion.

Before target mutation, **Cancel** ends the operation. Say “No target changes
occurred” only with Core evidence; local configuration publication is separate.
Once mutation may have begun, use **Stop Rebuild** with native confirmation:
“Stop rebuilding? Macseed will stop further work. Changes already completed will
remain. You can inspect the Mac and plan another rebuild later.” Missing effect
facts stay unknown. [Graceful/Force Stop](#restore-cancellation-safety) retains its
operation-bound delivery/acceptance/uncertainty rules and native lifecycle limits.
Secret sheets may send secret-channel cancellation; handle Capture/Restore failed
cancellation codes and Compare's separate cancelled event without conflating them.

Stopped Result preserves partial actions, matching/remaining scope only where
evidenced, publication and possible mutation. Missing records are Not confirmed,
not an exact remaining-item cursor. Changes may remain; there is no rollback.
Re-entry inspects afresh, prepares/previews, confirms, then idempotently applies
remaining differences. Remembered inputs are draft choices, not authorization or
stored-cursor Resume. After prerequisites use Check Again; stale plans return to
Preview. `recovery_required` directs to existing CLI publication recovery, never
silent Desktop recovery. Whole-Mac transactional rollback is outside 1.0 scope.

### Stopped Bundle A, then Bundle B

Choosing Bundle B starts a new Restore operation with new operation IDs. Discard
Bundle A's prepared plan and confirmation; inspect/validate B, inspect the current
Mac through fresh Prepare, show B's fresh Preview and require normal Rebuild
confirmation. State already changed by A is part of the current observed Mac.
Never reuse A's plan or remove state introduced by A merely because it is absent
from B. Absence from a Bundle is not a removal instruction; Macseed 1.0 is not a
cleanup/reconciliation engine. A compact inline notice may mention the stopped
rebuild, without an extra blocking modal. The fresh Preview is the safety gate.

## Secure interactions

**Stage 16H SSH Identities — COMPLETED (2026-11-05).** The user accepted the
following manual E2E results; this final pre-commit check records that evidence
without repeating the real-user SSH workflows:

| Accepted manual check | Result |
| --- | --- |
| Automatic SSH Capture → Rebuild → Verification | PASS |
| Manual external SSH Capture → Rebuild → Verification | PASS |
| Byte-for-byte matching | PASS |
| Permissions and fingerprints | PASS |
| Repeated Preview / Already Matches / no-op | PASS |

Supported identities are encrypted in `secure.age`; external pairs can be added
manually. All identities currently restore into `~/.ssh`; custom restore destinations
are **not implemented**. The accepted comparison includes one Secure Transfer
requirement and disables Rebuild for a confirmed no-op. This closes the supported
identity checkpoint, not hosted CI, Stage 17 distribution or clean-Mac qualification.
[SSH Environment Completion — Developer Environment Closure](CAPTURE-RESTORE.md#ssh-environment-completion--developer-environment-closure)
is **NEXT / PLANNED**, with configuration/destination integration owned there.

Core owns Secure Migration. `CoreRuntime` opens `CoreSecureTransport` only for
Capture Execute with explicit identity IDs, Restore Execute with explicit
`include_secure: true`, or the selected read-only `secure_restore_compare` operation. Ordinary operations retain their existing launch path.
The selected Macseed 1.0 scope requires 16H and bundled age. Pinned, verified age
v1.3.2 is implemented locally in `Contents/Helpers/age`. `CoreLocationResolver`
binds every production launch to its app; Core validates the fixed helper path,
file safety, architecture and pinned bytes for Capture encryption, Preview and
Restore decryption. No external age/Homebrew fallback or runtime download exists.
Missing/damaged helpers block selected secure work in the existing failure or
prerequisite surface, with rebuild/reinstall guidance; ordinary work continues.
CLI consent-based installation is unchanged. Age updates ship with Macseed
releases. [Distribution](DISTRIBUTION.md#bundled-age--required-for-desktop-10) owns
provenance, redistribution and remaining Stage 17 signing/clean-Mac qualification.

Capture validates typed candidate inventory and preparation counts, shows names,
types and public fingerprints in the Secure Transfer sibling group, and defaults every identity off.
Prepare does not unlock keys or establish cryptographic pairing. Execute rechecks the prepared ID,
validates all selected pairs and exports `secure.age` with Core's existing engine.
Results require matching preparation/destination, publication evidence and the
secure-component flag; the displayed encrypted count comes from that bound
selection, not an inferred per-key result. Ordinary partial coverage remains visible.

**Add SSH Identity…** in the same Secure Transfer disclosure opens a single-file
native `NSOpenPanel`. Core checks that explicitly chosen private file and its
adjacent `.pub`, including safe sources outside `~/.ssh`/HOME; there is no recursive
search. Validated candidates use the existing name/type/public-fingerprint rows,
with a small Manually Added label and Remove action. Adding starts unchecked;
Remove forgets the candidate without deleting files. The one existing tri-state
master and independent disclosure retain their semantics. Advanced selection and
ordinary domain/item counts remain separate; secure-only Capture is supported.

Review and confirmation explain the fixed destination `~/.ssh/<validated-name>`
in the receiving HOME and the `IdentityFile` limitation. No custom destination or
source path is stored in the Bundle; the existing encrypted v1 names authenticate
the destination. Existing Preview/Result secondary detail gives the same bounded
configuration reminder, without inferring a Host-profile relationship. Core source
checks and format compatibility are owned by [Secure Migration](toolkit/SSH-IDENTITY-MIGRATION.md#manually-selected-desktop-sources).

Source references remain in the current Capture session and private operation
staging, never persistent preferences or ordinary requests/events/logs. Only
explicitly selected manual references enter Prepare/Execute; adding/removing or
changing selection invalidates preparation. New scan, Cancel Review and Done clear
session references. Core rejects changed sources before publication. Candidate
inspection uses the existing cancellable runtime without a secret channel;
encrypted execution keeps the existing FD challenges and operation ownership.
This extension is included in the accepted Stage 16H identity scope. Broader
release and packaged qualification remain separate.

Secure Execute and authenticated secure comparison open the separate inherited Unix-socket FD bridge. Native secure
text fields handle Bundle encryption and protected-key unlock, with distinct
labels; keys retain their original encryption. Import confirmation is an explicit
Import/Cancel decision during Restore, not a passphrase or automatic consent.
Secret responses never enter JSON requests.
Bind each response to the active operation/challenge ID and kind, honor Core's
attempt and timeout limits, and clear transient field content on submission,
challenge replacement, cancellation or close. No persistent secret storage,
clipboard automation or log capture. Never claim complete memory erasure.

The Unlock SSH Key dialog now shows Core-validated name, key type, public
fingerprint and reliable position/total from the active authenticated FD challenge.
The narrow secure-channel v2 extension applies only to `ssh_key_unlock`; Bundle
and import-consent challenges retain v1. Core and Desktop require exact fields and
matching operation, nonce and retry context. Labels are never inferred from UI
order. This context stays in the active dialog and transient transport state, not
ordinary events, operation records, logs, diagnostics or error descriptions.
The earlier generic-dialog limitation is resolved in the completed identity
checkpoint; complete 1.0 qualification remains separate.

Restore Selection reuses the Capture hierarchy: Standard Setup has one ordinary
container; For Experienced Users has one container with Advanced and Secure
Transfer sibling rows. Secure Transfer retains its independent Selected/Off
master but has no disclosure in Selection. Its description is always visible:
“Encrypted SSH identities. Preview checks which keys already match this Mac.
Missing keys can be imported during Rebuild without overwriting existing keys.”
Experienced Expand/Collapse controls Advanced and its nested categories only;
Capture and Preview retain their meaningful Secure Transfer disclosures.
Secure Transfer is absent without `secure.age`, otherwise defaults off and selects
the whole package. When off it is absent from Preview, confirmation, Progress and Result.
Secure-only Rebuild is supported; identities never enter ordinary Advanced counts.

The existing Preview button runs ordinary `restore_prepare`, then automatically
runs authenticated read-only `secure_restore_compare` when Secure Transfer is
selected. The existing secure dialog requests only the Bundle passphrase, never
an SSH-key passphrase; there is no extra button, screen or card. Complete Preview appears only after comparison
resolves. `restore_prepare` itself still accepts no secrets and performs no decryption.
Comparison reuses authenticated age decryption, strict archive/manifest/hash
validation, OpenSSH public/envelope checks and race-safe exact target-byte checks.
It does not unlock encrypted private keys or claim cryptographic private/public
pair validity. Import confirmation, target writes, configuration publication and
import receipts remain excluded. Execute independently derives and verifies every
private/public pair, with original key encryption preserved. Successful pair proof
may be reused only for the exact same private/public bytes within that worker;
file ownership, modes, links and target state are still rechecked. No passphrases
or validation proofs cross operations.

The one package requirement maps `all_match` to Already Matches, `import_required`
to Changes Planned when readiness permits, and `conflict` to Needs Attention.
Expanded “Encrypted SSH identity package” uses the existing secondary text:
“All saved SSH identities already match this Mac. Nothing to restore.”,
“Some saved SSH identities are missing. Rebuild can import them without overwriting
existing keys.”, or “An existing SSH identity conflicts with the saved version.
No keys will be overwritten.” These descriptions require a confirmed comparison.
Existing metrics and category pills consume the same task; ordinary/Advanced counts
are unchanged and zero pills/cards stay hidden. Partial match plus missing identities
is one planned requirement, not a key count. Secure-only confirmed match disables
Rebuild. Mixed work retains secure scope and revalidates it during execution.
Cancellation, rejected input, unavailable tools, timeout or incomplete evidence use
existing preparation errors; they never fabricate a match, planned import or conflict.

Prepare and Compare reuse the same compact selection: full item domains use their
existing category shorthand, while partial selections retain every explicit Core ID.
Canonical scope validation remains separate, and the comparison receipt preserves
the compact representation so Execute does not retransmit a full inventory.

Comparison is bound to source fingerprint, prepared ID, exact selection, comparison
operation and a private target-observation digest for executable decisions. Selection,
source, Back/Refresh or a new session invalidates it. Every Preview compares afresh.
Execute checks the binding, re-unlocks without cached secrets and rejects a changed
target before secure mutation, retaining no-clobber checks around explicit consent.
Preview places Secure Transfer after Advanced in their existing shared container;
no decrypted identity names or per-key Restore selection are exposed.

Existing Rebuild confirmation explains no-clobber import. Execute handles
`bundle_unlock`, identity-bound `ssh_key_unlock`, and mandatory explicit
`import_confirmation` through the existing secure dialog and FD. Core completes
import before dependent Bootstrap work. Progress retains the existing flat list
with one Secure Transfer row and evidence-based waiting/input/import/verification
states. Existing Result, Stop and interruption layouts are reused.

Core projects its validated importer receipt into existing operation, coverage and
verification records for `encrypted_identity_set` before the post-import Stop
checkpoint. Desktop retains those records across subsequent work and history
truncation. Only positive import and conformity evidence marks this one logical
requirement Verified; exit zero or phase completion alone cannot. A no-op stays
Already Matches; conflicts preserve target files. Stop retains verified imports,
while missing evidence and interruption remain unverified/unknown. Cancelling
secure input alone does not establish that the whole Rebuild stopped or that no
mutation began. Force Stop keeps existing unknown-consequence and re-entry fences.
Secret-channel content and isolated PTY traffic never enter Details or diagnostics.

Checkpoint 3 local evidence belongs to `RestoreTests --secure-restore-only` and
`PresentationTests --secure-restore-only`: disposable HOME/identities, production
CoreRuntime/importer, typed preparation, selection/counts, challenge lifecycle,
no-clobber/no-op, stale plans, Stop evidence and native 580/1040 pt Light/Dark
fixtures. Checkpoint 3B adds `RestoreTests --secure-compare-only` and
`PresentationTests --secure-compare-only`, plus the focused
`RestoreTests --secure-compare-binding-only` Execute checks: automatic prompts, authenticated
match/missing/partial/conflict, no-op gating, target content/metadata preservation,
private staging cleanup, stale bindings, FD interruption and diagnostic privacy.
Existing transport/Capture/ordinary Restore evidence is reused. These automated
fixtures are distinct from the accepted manual E2E recorded above and do not
establish broad regression, hosted or packaged qualification.

The passphrase-refinement checkpoint adds focused `--secure-passphrase-only`
Restore/Presentation checks and `CoreRuntimeTests --secure-context-only`, plus
`ChallengeContextTests` / `PairProofTests` in the Core secure harness. Disposable
production Capture supplies protected and plain keys; Preview needs one Bundle
prompt and zero key prompts, with unchanged target bytes/metadata and cleaned
staging. Execute covers identity-bound retries, distinct protected keys, exact-byte
proof reuse, changed targets and authoritative Verification. Selection, result text
and secure-dialog layouts are checked at 580/1040 pt in Light/Dark. Earlier evidence
is retained alongside the accepted manual E2E above; no broader release acceptance
is inferred.

## Generic rendering and Protocol V1 fit

The production presentation catalog owns labels, icons, colors, action verbs and
typed reason/prerequisite guidance. It translates Core IDs without becoming an
inventory, observer, readiness engine or domain state model. New items reuse rows;
new categories/reasons normally need catalog entries, not bespoke screens.

| UI input | Structured Core source |
|---|---|
| Selection | Inventory status/mode, groups, stable item IDs and eligible counts |
| Labels and plan | Safe labels/display names, action/disposition/reason and change flags |
| Prerequisites | Readiness domain/code/status/scope and execution bridge conditions |
| Activity/outcome | Ordered events, phase/operation records, terminal and mutation/publication facts |
| Conformity | Verification/Coverage/Comparison records, verdict/counts and actual detail completeness |

Unknown IDs use neutral labels; unknown enum values remain diagnostic codes and
cannot imply success or a supported action. Category-only settings never gain
per-setting selection/editing through rendering. Exact fields, limits, secret
channels and compatibility belong to [Protocol V1](core/APPLICATION-INTERFACE.md).
Decrypted identity selection during Prepare and Desktop recovery remain unsupported;
any extension needs a Core contract decision/test evidence, never a client parser.

## Unified UI Scenario Catalog — deferred UI/dev tooling

The full catalog is deferred, not a functional prerequisite. Existing DEBUG samples,
DemoSession and design-preview remain. A later Lite catalog may cover representative
Ready, Working, Already Matches, Needs Attention, Error, Cancelled and Interrupted
states for Capture/Restore/Status. It owns synthetic fixtures/navigation only:
**fixtures → production presentation models → production/shared views**.
No Core mutation, second UI implementation or copied obsolete styling is allowed.
Small focused fixtures/PresentationTests may support current work without constructing
the catalog. [TODO](../TODO.md#deferred-tooling-and-maintenance) owns future work.

## Local logs and Diagnostic Report

**Stage 16J completed.** Two logging levels remain independent:

- **Core / CLI technical logs:** existing `modules/core/logger/logger.sh`,
  `logs/history` and `logs/latest.log`; unchanged by Desktop logging.
- **Desktop Operation Log:** typed, persisted, sanitized Protocol V1 records for
  Capture Prepare/Execute, Bundle inspection, Restore Prepare/Execute and
  Environment Status Compare. This is not a complete Core/CLI technical journal.

Desktop does not parse `latest.log`, CLI messages or raw stdout/stderr, merge these
levels, add a third logger or extend Protocol V1 for correlation. The Desktop
request ID identifies the operation; it does not prove linkage to a particular Core
technical-log file. Workflow screens use short messages and the existing log viewer,
never access to arbitrary Core logs. Application observation failures add a bounded
typed projection of tool/probe, failure layer, duration, native exit or signal and
confirmed quiescence. Raw output, argv, environment and file contents are excluded.

### Storage and completeness

Foundation Application Support stores one typed NDJSON file per Core operation in
`org.macseed.desktop/Operations`, with 0700 directories and 0600 files. Limits are
8 MiB per journal, 16 KiB per record, 100 operations, 64 MiB total and 30-day
retention. A reserved budget permits explicit truncation/finish records. Cleanup
and confirmed **Clear Logs** delete only recognized inactive Store-owned journals;
active journals, Core logs, Bundles and unrelated files are preserved.

Ownership, regular-file, hardlink and symlink checks protect storage; locks protect
active journals across Store instances. Sanitization and append/read work run off
MainActor with bounded ingress. Closed vocabularies and bounded evidence drop
unknown/private values. Private item identities become per-operation local aliases;
the private identity-to-alias mapping is not saved. Omitted evidence and truncation
are explicit. Events include client receipt times, Core sequences/types and safe
phase/domain/action/reason/count/Verification facts. Client records identify only
confirmed transport/stop requests or delivery evidence, without invented Core
sequences or a promise of safe rollback.

Append and controlled sync preserve complete valid prefixes after a crash. A
missing finish, invalid terminal evidence or damaged/partial tail does not establish
success. Persistence failure changes diagnostic availability, not Capture, Restore
or Status outcomes. Reopening history never retries or resumes a workflow. Signed
application resources remain read-only; private Desktop log placement does not
solve the separate packaged Core writable-workspace requirement.

### Viewer and history

**Settings → Operation Logs** opens one shared native window with compact Previous
Operations history. Local **View Log** opens Capture Execute and Restore Execute in
their Result screens, and Environment Compare in Status results. Failed and cancelled
screens retain their own operation reference. A failed Prepare on an intermediate
screen can expose its matching journal. Ordinary Review, Selection, confirmation
and Preview omit local log links and unavailable-log placeholders, as does active
work. A local entry initially selects its
corresponding operation, including when another flow ran more recently. Selection switches summary, timeline,
reader cursor and disclosure state together; obsolete asynchronous reads cannot
repopulate a different operation.

**Important** shows deduplicated issues and key events. **All** provides access to
every saved event through bounded incremental pages, including earlier events
outside the 512-record visible window. This does not recover records never saved
because of truncation or omissions. The viewer can follow an active operation from
Settings; disk reading stays off MainActor. Technical Details uses bounded native
TextKit rendering and complete safe detail copying. Stop/Force Stop continues
through the existing Runtime controls.

Summary separates **Process Result**, **Verification** and **Log completeness**.
Only available counters are shown. Successful execution can coexist with incomplete
Verification or an incomplete log; Log Incomplete is a neutral diagnostic limitation,
not an execution error. Truncated, unavailable, interrupted/unknown and partial
evidence remain explicit.

### Diagnostic Report snapshot and privacy

**Diagnostic Report** in Operation Logs captures the selected operation into one
immutable UTF-8 snapshot. A simple monospaced TextKit preview displays it;
**Copy Report** copies it and **Save Report…** writes the same bytes to a text file
through the native save panel. **Refresh Report** explicitly creates a replacement
snapshot; incoming events do not silently change an open report. Cancelling Save
writes nothing; a write error retains the snapshot and shows a safe error message.

An independent strict export allowlist projects already sanitized typed records.
It includes available application/Core versions, report-host macOS version and Mac
architecture, operation type/action/IDs/times, process exit/reason/terminal validity,
Verification status/details completeness/verdict/counters, phase chronology,
errors/warnings/skipped/unsupported and evidenced Graceful Stop/Force Stop facts.
Publication, possible target mutation and unknown-consequences flags appear only
when recorded. Missing facts remain unknown rather than fabricated zero counts.

Export excludes even local item aliases, user/object names, paths, filenames,
repository names/remotes, setting contents, environment, SSH material, credentials,
tokens, arbitrary Core text, raw output and Protocol payloads, including nested
fields. Only closed codes, validated versions, bounded counts and typed flags cross
the report boundary; sanitization is not merely regex replacement of dumped data.
No telemetry, automatic upload or implicit Core/CLI-log access is introduced.

Generation streams existing reader pages off MainActor with bounded memory. Report
text is capped at 256 KiB with explicit chronology omissions and retained summary;
this report cap is separate from persistent-log truncation. Incomplete, damaged,
truncated and unavailable sources are stated honestly, including missing finish
records. The report is an operation snapshot, not a crash dump or full machine inventory.

### Qualification and remaining checks

Operation Logs UX is manually accepted. Foundation/viewer/report tests cover nested
privacy exclusions, immutable exact preview/copy/save bytes, explicit refresh,
save cancellation/errors, unavailable/crash-tail sources, close-during-load and
bounded native rendering of a 6000-record fixture. CI #108 includes the diagnostic
suites and native PresentationTests. This does not qualify user-driven report
scrolling, native Save panel interaction or signed/notarized clean-Mac behavior.
Those checks remain in [TODO](../TODO.md#distribution-prerequisites-and-packaged-runtime-16k--stage-17);
Secure Capture and Restore have disposable-key log/report privacy fixtures; broader
real application and packaged privacy qualification remains open.

## Implementation slices and qualification

[Roadmap](../ROADMAP.md#stage-16--native-macseed-desktop) owns the historical slice
IDs and completion table; they are identifiers, not a new execution order. Supported
16B–16G flows, Result/Visual Unification and 16J diagnostics are implemented;
16H SSH Identities is completed. SSH Environment Completion is the next planned
checkpoint; remaining 16I/16K cases and Stage 3C recovery stay open.
Accepted UI/controlled Stop checks do not establish universal native lifecycle safety.

The repository Core/external Python runtime is not an installed-app distribution.
[Distribution](DISTRIBUTION.md) owns Stage 17 signed/notarized, checkout-independent
clean-Mac proof, including logs, interruption and exact report-export privacy.
[TODO](../TODO.md) owns unfinished actions; Early Access and Macseed 1.0 gates remain
in Roadmap. Current Core/CLI 3.4.0 and released toolkit history retain their meaning.
