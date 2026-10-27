# Macseed Desktop

Native SwiftUI Desktop is a development client of the same **Core/CLI 3.4.0** as
`bs`: **Capture → Rebuild → Verify**. Real Capture, Restore Prepare/Execute,
Bundle-backed Environment Status and its Restore handoff are implemented. Their
accepted UI, final Restore Result and Stage 16J diagnostics are the current
foundation. Stage 16 remains open; completed flows do not establish full capability,
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
owns stage status/order; Workspace & Git Worktree Restoration is next.
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

This boundary is implemented, not packaged clean-Mac proof. Core's root-relative
logs/config require a private writable workflow workspace before signed-resource
workflow qualification; current bundled resolution rejects those writes. Secure
Execute needs the future 16H socket bridge and is rejected before launch today.
Handled cancellation retains Core evidence; forced termination without a terminal
event is interruption with unknown effects, never rollback or item-boundary stop.
Diagnostic persistence and Result presentation are implemented; broader completion
and native lifecycle qualification remain open.

## Window and navigation

Use one main window with three sidebar destinations: **Capture this Mac**,
**Restore a Mac**, and **Environment Status**. An operation detail view belongs to
the active flow. Settings → Operation Logs opens the shared native log window;
results and terminal failures/cancellations offer View Log for their own operation
when its journal exists. Ordinary Capture Review/confirmation and Restore
Selection/Preview omit the local link. A failed Prepare retained on an intermediate
screen may expose only its matching operation's journal; Settings history remains available.
Use native file dialogs, accessible controls, text plus icons for status, and
keyboard navigation. Never rely on color alone.

First launch shows the three actions, a short explanation of supported environment
state, and **Ready** when the Core/runtime capability check succeeds. It does not
scan, restore, compare or request administrator authentication automatically.
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
selected operation. Use standard macOS About. Default Bundle location, confirmation
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

## Capture this Mac

**Scan → Review / Select → Destination / fresh preparation → Confirm → Result**
uses content states in one workspace, not mandatory wizard pages.

1. Scan calls `capture_prepare` with `selection: null`. Indeterminate progress uses
   real Core phase messages, without numeric domain progress. Private staging does
   not replace ordinary Generated Configuration/Blueprint or rebuild the source Mac.
2. Review uses Core inventory status and `selection_mode`. Initially select all
   present ordinary scope visibly; unavailable, observation-error and unsupported
   rows stay unselected with reasons. Category-only rows have one checkbox and
   read-only details; item domains support all/none/mixed selection and bulk actions.
   Whole-category and subset selection never overlap. Empty scope disables saving
   with **Choose supported state to capture**. Fully selected item domains send
   whole-category V1 selection; partial domains send IDs. Oversized partial requests
   fail visibly under the existing V1 limit and need a fresh scan/narrower selection.
3. Review shows Selected Domains, Selected Items and Needs Attention. Unsupported
   state alone is not an attention warning. Categories start collapsed in shared
   order: Applications & Tools, Settings, Git, SSH Configuration, Workspace, then
   Shell when present. Git Repositories belongs to Workspace. macOS Settings nests
   Finder, Dock, Windows, Keyboard, Trackpad and Screenshots with independent native
   domain checkboxes. Included-setting labels are read-only, add no selection counts
   and never synthesize defaults. Secure Transfer remains a separate capability;
   current Capture always sends `secure_identities: []`.
4. A native save dialog chooses the destination; Desktop normalizes exactly one
   `.mbt` suffix, then prepares the chosen selection again. Inline confirmation
   shows destination and **Included in this capture**, without repeated aggregate
   counts. Wrapping neutral labels retain independent item/category warnings;
   preparation diagnostics stay in Operation Logs. Back edits Review. Whole domains
   remain whole; macOS details name selected subdomains, and VS Code Settings
   describes `settings.json` only. Fresh confirmation reflects newly observed scope.
5. **Create Saved Environment** sends that preparation's ID. Execute rescans;
   changed inventory requires fresh Review/confirmation, never a silent retry.
   Existing output requires explicit Replace in the Save Panel. Replacement is
   digest-bound; Core validates the new Bundle before atomic publication, preserving
   the old Bundle on failure. Stale preparation shows **Capture Preparation Is
   Outdated** and **Scan Again**, retaining `stale_prepared_capture` and cautious
   publication evidence. Failed/interrupted attempts also require a fresh scan.
6. **Environment Saved** requires consistent successful publication evidence.
   Domains Saved / Items Saved come from published metadata; Needs Attention counts
   captured Core domains with event warnings. Capture does not claim target Restore
   or final Verification. Failure/cancellation after publication retains the reported
   location and publication fact without success, cleanup or rollback claims.

Scan, Checking Your Environment and Saving Your Environment show compact Core
phases, spinner and cancellation. There is no per-item publication progress, so
no invented waiting task list. **Captured Environment** follows Review order.
Completed requires confirmed domain inclusion and consistent published item counts
bound to prepared selection. Known limitations show Needs Attention; insufficient
item evidence stays Unverified without an invented list. Core supplies no omitted-item
inventory/count. These are capture states, not target Verification.

Review and Result omit zero Needs Attention cards and let other cards fill the
space. Confirmation/Result use compact read-only details. Primary actions remain
outside scrolling content. Result shares one status column across macOS parent,
children and VS Code Settings; arrows retain a separate rightmost rail. Labels
wrap before statuses even at narrow widths. Reveal in Finder sits beside the saved
file; View Log is left, Capture Again then Done are right. Capture Again scans
fresh; Done returns to initial Capture without scanning or switching tasks.

Accepted real-Mac cases cover full/category/item capture, publication with and
without warnings, Reveal in Finder, cancellation, stale preparation after source
drift and a successful fresh Scan. This does not qualify macOS visual effects:
[Configuration](toolkit/CONFIGURATION.md#macos-settings) owns exact observed keys,
compatibility and stored-value semantics; [TODO](../TODO.md#macos-settings-manual-qualification)
retains native settings gates.

Secure SSH remains within Capture, not a Credentials area/password vault. The
future [16H interaction](#secure-interactions) uses optional, default-off SSH identity
selection, safe names/types/public fingerprints and **Encrypted separately**.
Ordinary SSH configuration stays independent; ordinary Bundle data is private but
unencrypted. Prepare neither unlocks nor proves key pairs. Missing secure tools
permit guidance or continuing without identities; selecting none permits an
ordinary Bundle. Passphrases use a focused native secure sheet.

## Workflow layout and disclosure

Capture Review, Confirmation and Result; Restore Selection, Preview, Rebuild and
Result; and Environment Status results keep three regions: fixed information and
list controls, one scrolling category tree, and the existing fixed action footer.
Manual Installation and Automatic Restore Tasks share Preview's list viewport.
Preview keeps a brief prerequisite status, the available Fix Issues action and its
approval guidance above the list. The list contains the single Prerequisites heading
and specific issues when present. A compact read-only notice sits beside the
Restore Preview heading; Selection has no duplicate read-only notice.
Headers and progress remain live while the list scrolls. Screens without a list
retain their ordinary content layout. The supported minimum window stays 1000 × 700.

Existing count pills share Restore's oval shape (minimum 32 × 23 pt, 6 pt horizontal
insets and monospaced caption digits). Each tree reserves a common count rail and
an independent rightmost disclosure position. Category status text, icons, colors and
horizontal anchors remain unchanged; counts wrap below if space is limited.
Manual Installation uses the same Preview status column as Automatic Restore Tasks.
Matching Preview and Status leaves share a plain green checkmark with the accessible
name Already Matches; category statuses retain their text. Capture Result labels
wrap before the status column, and nested Capture selection/confirmation statuses
align with their parent status.
Leaf rows have no disclosure indicator without an expansion action. Selection
checkboxes appear only for supported selection; checkbox/label hit targets remain
separate from disclosure, and verified status checks remain distinct.
Capture's textual item summaries remain text, and zero counts remain hidden.

Expand All / Collapse All operates on stable IDs for the whole available tree,
including Finder, Dock, Windows, Keyboard, Trackpad and Screenshots before their
views are created. A partially open tree offers Expand All. Collapse All clears
child disclosure state too. Selection, prerequisites, dialogs and Core operations
are independent of these local presentation actions.

## Restore a Mac

**Choose Bundle → Selection → Preview → Rebuild → Result**. Inspection and
Verification occur within these states; prerequisites do not add wizard pages.

### Selection and fresh Preview

A native `.mbt` picker starts Core `bundle_inspect`, which owns validation,
categories/counts and encrypted-component presence. Invalid/unavailable/unsupported
input shows **Can't Restore**, a typed reason and Choose Another Bundle. Inspection
neither proves readiness nor exposes private values. Restore requires the advertised
V1 fine-selection capability; older Core gets an explicit compatibility state.

Core inventory owns groups, modes, eligibility and stable IDs. Available ordinary
scope defaults on; domains explicitly absent or Blueprint-excluded are hidden,
including full inventories with zero selected items. Selected limitations stay
visible; absent evidence stays conservative. Selection never exceeds eligible Bundle
content. Category-only domains remain whole; item domains permit whole/subset scope.
Current Desktop sends `include_secure: false`; encrypted material is reported separately.

Sections are Applications & Tools, Settings, Shell, Git, SSH Configuration and
Workspace. Settings has one aggregate macOS toggle over captured/available advertised
domains, plus VS Code Settings; ordinary Restore Selection does not expose individual
macOS children/preferences. Applications & Tools/Workspace domains remain independently
selectable. Fully/partially/not-selected counts describe selectable Core categories,
exclude unavailable categories and do not replace Preview item metrics.

Selection status and Preview Restore stay in the fixed footer. Preparation shows
indeterminate **Preparing Restore Preview**, explaining that target state is unchanged.
`restore_prepare` returns prerequisites, plan and matching/changed scope. Bundle
changes invalidate preparation. Preview checkbox edits change only the local draft:
no Core call, retained evidence marked stale and Rebuild disabled until explicit
**Refresh Preview**. Counts/readiness still describe the prepared scope. Excluded
domains remain available for reselection; excluding SSH removes its prerequisite
without weakening checks when selected. Back retains selection but requires fresh
Prepare. Failed/cancelled/interrupted refreshes clear old Preview evidence.

Preview follows selection taxonomy, with collapsed domain rows and nested macOS
details. Summary cards are **Already Match → Changes Planned → Need Attention**.
Nonzero Match/Planned/Attention badges use green/blue/amber in that order and count
Core plan items once: child counts are not added again to their parent. Manual App
Store requirements never inflate automatic metrics. Prerequisite summaries identify
affected areas/counts; lower domains own concrete items and short reasons.

Preview exposes reported installs, settings writes, backups, clones/branch actions
and restarts. Unknown observation is never a planned mutation. No private values,
remote URLs or credentials are needed to explain actions. Homebrew Applications and
Packages stay separate through Preview, Rebuild and Result. Qualified repairs show
Will Repair / Ready to Repair and Repairing; finishing execution awaits Verification.

Desktop supports topology-aware Restore Preview and confirmed Rebuild through Core.
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
`mas`, VS Code CLI, network or `age` only when relevant. Administrator, Apple ID,
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
Check Current State** retains Bundle/selection and prepares afresh; **Finish** clears
the session. Re-entry is not Resume. Session ownership survives window closure;
close/reopen/quit behavior still needs remaining lifecycle qualification.

Stop Rebuild always confirms, with Continue Rebuild the default/Escape action.
Accepted Graceful Stop finishes indivisible work/post-checks and stops new admission;
Force Stop is a separately confirmed emergency action. Neither implies rollback or
universal native-installer interruption. See [cancellation](#restore-cancellation-safety).

### Assisted App Store Restore

App Store Applications comes first inside Applications & Tools in Selection,
followed by Homebrew Applications, Homebrew Packages and VS Code Extensions.
Selection counts retain requested Bundle IDs; Preview uses effective requirements
after confirmed Cask precedence. Refresh/back navigation preserves requested scope.
Unresolved overlap retains both requirements; App Store-only selection stays valid.
Identity, cache/provenance and protected App Store target rules are owned by
[Configuration](toolkit/CONFIGURATION.md#other-application-generated-inputs).

Preview puts one App Store card under **Manual Installation**, directly below Tasks,
then **Automatic Restore Tasks**. Expand All / Collapse All stays above both sections
and changes local disclosure only. Manual/automatic rows share status geometry;
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
Failed refresh clears stale installation claims. App Store-only plans have no
executable Rebuild; manual issues do not block independent automatic work. Apple
App Store owns installation/account authorization. MASHelper/XPC and automatic MAS
installation remain retired, including deployment/registration paths.

Result presents the execution outcome, then **Restore Summary**: confirmed automatic
work under Successful and outstanding automatic/manual issues under Needs Attention,
for example “1 restore issue · 1 app to install”; uncertain installations are “apps
to check.” Completed execution with only manual work remains completed; real failure,
partial/interrupted/stopped outcomes retain their meaning. No repeated attention
section or separate Verification-details disclosure is added.

Stable requirement identities merge repeated operation/Verification consequences.
Linked launcher diagnostics describe one current-operation issue; a destination
conflict does not prove a foreign installation. Manual IDs count once and never as
automatic successes. Independent category issues remain; uncertain independent issue
counts omit the number. Unrun requirements and unreported restarts are not failures
or successes. Models, logs and reports preserve conformity/completeness separately.

**Details by Category** keeps automatic domains and one App Store Applications row,
last within the same Applications & Tools surface. Its disclosure has a short manual
summary and Review App Store Apps, not the inventory. Categories start collapsed;
Expand All / Collapse All and the fixed footer remain. Short explanations preserve
independent problems; technical evidence belongs in View Log.

## Environment Status

Environment Status does not yet support topology Bundles, even when Restore Preview
fully confirms Already Match. The comparison flow below remains available for
supported legacy Bundles; [Configuration](toolkit/CONFIGURATION.md#topology-restore-preview--phase-3)
owns the capability limits.

**Choose reference → Compare → Result** uses inline Domain → Items disclosures.
The initial Choose Saved Environment card owns reference selection and its read-only
notice. Normal Desktop selects an explicit `.mbt` through a native picker, displays
the filename and clears old results without comparing automatically. Generated
Configuration/Blueprint controls are not exposed. Never substitute ambient state,
run Discovery or compare a new scan of this Mac with itself.

Core `environment_compare` validates/stages the Bundle privately, preserves its
Blueprint/provenance, compares read-only and removes staging without publication or
secure decryption. Older capability evidence gets an explicit compatibility state.
References are window-session-local. **Compare This Mac**, **Compare Again**, Cancel
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

Details use shared grouping; macOS Settings nests independently collapsed Finder,
Dock, Windows, Keyboard, Trackpad and Screenshots with Capture's labels. Git
Repositories appears after Workspace Folders. Matching categories show Already
Matches plus applicable counts; matching leaves use an accessible checkmark without
generic subtitles. Problem rows retain short explanations and independent diagnostics
correlated by owner/domain/item ID; technical evidence stays in Operation Logs.
App Store names use validated Bundle labels; missing labels stay neutral, IDs remain
in Core/model evidence. Absent `stored_preference` means the saved preference is
not explicitly set, not that a feature is missing or a system default was inferred.

Category pills count visible logical items; Different/Missing combine once. Each
repository gets one outcome from Worktree/Origin/Branch evidence: an absent worktree
with only dependent prerequisite failures is Missing; incomplete/unsupported or
independent failures retain attention. Core predicates/IDs remain unchanged.
Excluded inventory, extras and extra-availability rows are hidden only in the main
window, including extra-only categories. Extras affect none of the main outcome
counts; logs/reports retain their existing projections. Unavailable evidence is not
zero. [Core comparison](core/APPLICATION-INTERFACE.md#verification-and-environment-status)
owns provenance and provider-specific App Store absence; no cleanup/removal is implied.

A shared 160–240 pt status lane covers categories, macOS children and leaves;
indentation affects names only and narrows without shifting statuses. Chevrons use
a separate trailing rail. Result actions use the fixed footer; Choose/Failure
controls stay with content, Cancel left below the process card. Whole-tree
Expand/Collapse includes macOS children before views are created.

### Bundle handoff

Status and Restore keep independent session state. Entering Status without a
reference takes the current Restore Bundle, but still needs explicit fresh Compare.
A completed Bundle-based result with Core-confirmed Different/Missing offers
**Review in Restore** beside Compare Again. Coverage warnings alone, development
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
| Can't Restore | Invalid/unsupported Bundle or selected work cannot execute under the current contract; explain scope and alternative |
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
A supported item-local skip can produce **Rebuild Needs Attention** only with
confirmed independent success, consistent Verification and no unexplained failure.
The original Core terminal failure remains available.

Result keeps the operation outcome in its heading and shows the consolidated
Successful / Needs Attention summary described [above](#assisted-app-store-restore).
Successful counts only verified automatic requirements, once per stable identity;
manual work is separate. Zero metrics are hidden and uncertain issue counts omit
the number. There is no separate Skipped summary card or Verification-details panel.

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
| Complete | Executable work completed, with complete terminal/Verification evidence and no remaining issues in selected supported scope |
| Completed with Issues | Executable work completed, but known unresolved/unsupported outcomes or evidenced item failures remain; disclose them |
| Failed | Actual prerequisite, execution or runtime failure prevents completed work under the operation contract |
| Stopped | User cancellation after execution begins, with sufficient evidence of handled termination; completed changes may remain |
| Interrupted/Unknown | Terminal evidence is missing, invalid or incomplete; completion and effects cannot be established |

Known unsupported remaining state alone must not become a generic execution failure.
A blocking prerequisite still prevents execution. An item failure may be presented
as Completed with Issues only when Core proves completed independent work and the
required complete final evidence; it does not turn Core failure into success.
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

Environment Status is the accepted visual reference; Capture/Restore share its
category order, blue icons, surfaces, cards and disclosure behavior. No selection,
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
Stage 3C ordinary-Cask durable reconciliation, operation-owned DMG evidence and safe
re-entry remain open. Diagnostic logs confer no recovery authority; manual App Store
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

**Planned Desktop contract — Stage 16H.** Core has the separate secret-channel
engine; current Desktop rejects secure Execute before launch. The following
interaction requirements are not implemented Desktop functionality.

Execute alone opens the separate inherited Unix-socket FD bridge. Use native secure
text fields for Bundle encryption/unlock and protected-key unlock, with distinct
labels; keys retain their original encryption. Import confirmation is an explicit
Yes/Cancel decision, not a passphrase. Do not send secret responses in JSON requests.
Bind each response to the active operation/challenge ID and kind, honor Core's
attempt and timeout limits, and clear transient field content on submission,
challenge replacement, cancellation or close. No persistent secret storage,
clipboard automation or log capture. Never claim complete memory erasure.

Show that secure validation/import is pending until Execute provides evidence.
Preparation cannot enumerate decrypted Restore identities; do not promise a
per-key Restore selection screen. Import uses existing no-clobber Core behavior;
conflicts/errors remain visible. Secret-channel content and isolated PTY traffic
must never enter operation Details or diagnostics.

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
future Secure SSH needs corresponding privacy fixtures.

## Implementation slices and qualification

[Roadmap](../ROADMAP.md#stage-16--native-macseed-desktop) owns the historical slice
IDs and completion table; they are identifiers, not a new execution order. Supported
16B–16G flows, Result/Visual Unification and 16J diagnostics are implemented;
16H secure integration, remaining 16I/16K cases and Stage 3C recovery stay open.
Accepted UI/controlled Stop checks do not establish universal native lifecycle safety.

The repository Core/external Python runtime is not an installed-app distribution.
[Distribution](DISTRIBUTION.md) owns Stage 17 signed/notarized, checkout-independent
clean-Mac proof, including logs, interruption and exact report-export privacy.
[TODO](../TODO.md) owns unfinished actions; Early Access and Macseed 1.0 gates remain
in Roadmap. Current Core/CLI 3.4.0 and released toolkit history retain their meaning.
