# Macseed Desktop

**Stage 16 remains in development. Supported 16B–16G flows and the final Restore
Result UI are implemented and manually accepted; 16J is complete. Secure SSH
Desktop integration remains open in 16H.**
Normal launch checks real Core capabilities over Protocol V1. The approved sample
flows remain available only in explicit DEBUG design-preview mode. Environment
Status uses real read-only Core comparison. Capture scans/selects/prepares and
publishes a real Saved Environment through Core. Restore inspects a Saved Environment
and prepares a read-only Preview, then executes through Core with confirmation,
structured progress, Safe Stop and Verification-aware results/fresh-plan re-entry.
Historical checkpoint `08e2b469ba714a6eb32a3293296943b774653415` advanced
Restore presentation/recovery and capability-based Homebrew qualification.
That real Restore converged to a fresh **Everything Already Matches** Preview; clean
Tailscale installation and subsequent matching observation passed. Earlier Repair
→ Verify → fresh no-op gates for Keka, Termius and VLC and generated completions
through Codex remain valid. Clean Install does not qualify universal Tailscale
Repair: ambiguous/damaged privileged Repair states remain fail-closed. Continuing
compatibility qualification, MAS, Desktop Zsh and Secure SSH remain open. The
[latest qualification snapshot](#recent-restore-qualification-and-performance)
records the qualified Tailscale 1.104.1 Clean Install and the remaining unsafe
Repair boundary; neither qualifies every metadata/state combination.
Private SSH identity transfer remains unavailable until 16H. Bundle-backed
Environment Status (Stage 16K) is complete; the subsequent Status → Restore handoff is implemented and manually
approved. Desktop Visual Unification is complete.
[Restore Cancellation Safety](#restore-cancellation-safety) is in progress: Stage 1–2
and operation-wide checkpoint Graceful Stop are implemented/automated-tested, with
controlled real-Mac cancellation checks accepted. Stage 3C and broader installer
qualification remain open. Stage 16J Logging & Diagnostics is complete;
remaining cancellation/recovery work is not closed by diagnostics.
Practical priorities are owned by
[Roadmap](../ROADMAP.md#current-practical-execution-order).
Build and review instructions are in
[Desktop development](../desktop/Macseed/README.md). Macseed is one product with a shared Core and two official frontends: CLI (`bs`) and Desktop.
The official CLI remains supported. **Simple by default. Detailed on demand.**

This document owns Desktop presentation and interaction. The implemented
[Protocol V1](core/APPLICATION-INTERFACE.md) owns transport, operation semantics,
selection, prerequisites, records and secret input. Desktop consumes those facts;
it does not recreate Discovery, Preview, Capture, Restore or Verification in Swift.

## Implemented runtime boundary

Desktop resolves an explicit development runtime descriptor or future relative
bundled resources, launches one owned Core process group per request and consumes
validated JSONL separately from stderr. It preserves V1 identifiers, sequence,
phase and additive metadata. Missing runtime/protocol failure is typed and never
falls back to samples. See [development/runtime details](../desktop/Macseed/README.md).

This boundary is implemented, not packaged clean-Mac proof. Core's root-relative
logs/config require a private writable workflow workspace before signed-resource
workflow qualification; current bundled resolution rejects those writes. Secure
Execute needs the future 16H socket bridge and is rejected before launch today.
Handled cancellation retains Core evidence; forced termination without a terminal
event is interruption with unknown effects, never rollback or item-boundary stop.
Diagnostic persistence, viewing and report export are implemented in Stage 16J.
Restore Result presentation is
implemented and checkpoint-qualified; broader completion qualification remains open.

## Window and navigation

Use one main window with three sidebar destinations: **Capture this Mac**,
**Restore a Mac**, and **Environment Status**. An operation detail view belongs to
the active flow. Settings → Operation Logs opens the shared native log window;
terminal flow results offer a local View Log for the corresponding operation.
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

Macseed Minimal Premium is the approved style. The leaf logo/system App Icon,
Home, Sidebar, Settings and adaptive tiles are complete; Capture was checked on a
real Mac, and Restore Selection, Preview, Progress and Result are approved.
Remaining consistency qualification in 16I/16K checks this implemented foundation
in Environment Status and Settings, including accessibility and unexercised edge
cases; the accepted functional UI is not pending reimplementation. Shared domain/item rows, status vocabulary,
spacing, disclosures and accessibility must consume the same presentation model
across **Preview → Rebuild → Verification → Result**.

Restore's reference hierarchy is **Domain → Items**. The top attention summary
owns only affected areas and counts, with warning icons; it has no item-detail
disclosure. Prerequisites separately explain execution requirements with compact,
independently expandable rows: Ready when satisfied, visible status when blocked.
The lower domain sections own concrete items, user-facing reasons and temporary
nested technical diagnostics. Avoid a second item-detail representation above them.
Retain truthful Needs Attention versus Unverified evidence in all phases.

## Native appearance and Settings

Use native SwiftUI controls, standard checkboxes/toggles, SF Symbols, system
typography, generous spacing, restrained status indicators and native light/dark
appearance. Use standard open/save dialogs, sheets, alerts and disclosure groups,
with keyboard and accessibility behavior. Keep the visual hierarchy quiet; avoid
web/DevOps dashboard aesthetics, terminal styling, excessive cards, custom controls,
persistent technical information and unnecessary modals.

The shared shell uses an inset/material sidebar, a neutral workspace and a
restrained rounded header/information surface across all tasks. Native blue is
reserved for interaction/selection; borders use semantic system colors. Light
and Dark share the same spatial hierarchy, with minimal cards and no decorative
gradients or heavy shadows.

General Settings includes a native segmented Appearance control: System (default),
Light and Dark. Only this enum value persists in Desktop UserDefaults. System
removes the appearance override and follows macOS automatically; Light/Dark set
application appearance as the single owner; windows, SwiftUI content, Settings
and native dialogs inherit it without separate color-scheme overrides. This
preference has no Core, Blueprint or Bundle meaning.

Settings remains small: General owns Appearance; Operation Logs opens the shared
viewer/history without a second storage implementation. A default Bundle location,
confirmation preferences and Open Logs Folder remain conditional future options,
not implemented controls. Preferences must not bypass fresh-plan confirmation or
secure import consent. Reserve Updates only if the eventual Stage 17 mechanism
needs it; no updater is defined here. Use standard macOS About behavior, not a
custom About settings page. Diagnostic Report is an explicit action for the
selected operation in Operation Logs; there is no raw-log destination.

Initial Capture, Restore and Status share a tinted primary action card beneath
WorkspaceHeader: blue Scan, green saved-environment selection and violet Compare.
Only their explicit existing actions start the next workflow step. The Macseed leaf
mark is a shared blue/lilac vector used in the sidebar, Home hero and AppIcon.
Home uses a blue/lilac hero and three tinted action tiles; tiles stay in three
columns at supported main-window widths and stack only in narrower contexts.
Hero and tiles share a centered container capped at 1080 pt; tile text regions
retain stable spacing. Settings is pinned below the sidebar navigation list.
Task icons consistently use blue Capture, green Restore and violet Status;
Settings retains a neutral gear. Workflow content and semantics remain unchanged.
Both Xcode and local builds use static `Macseed.icns` through `CFBundleIconFile`.
The asset-catalog sizes and ICNS are reproducibly exported from the same UI mark
with `desktop/Macseed/generate-app-icon.sh`; temporary exports stay under ignored
`build/`. macOS may retain an older Dock icon for an already-running app until it
is quit and reopened. The running app sets its icon from the packaged ICNS.
The system icon enlarges the same leaf by 22%; Hero/sidebar scales stay unchanged.
Branding/Home presentation is finalized and user-approved independently of the
remaining Desktop functional work.

The user approved the current Branding/Home and Capture/Restore UI milestone on
a real Mac. Focused Core selection tests, RestoreTests, PresentationTests and a
Debug build passed; these checks are not a full regression or completion of Stage 16.

## Capture this Mac

**Scan → Review / Select → Destination / fresh preparation → Confirm → Result**

These are content states, not mandatory wizard pages.

1. Scan calls `capture_prepare` with `selection: null`. Show an indeterminate
   scan using Core phase messages without numeric domain progress. Scanning stages private
   inventory; it does not replace ordinary Generated Configuration.
2. Review renders inventory status and `selection_mode`. Initially select all
   present ordinary categories/items, visibly; unavailable, observation-error and
   unsupported rows remain unselected with reasons. The user can narrow whole
   categories or item subsets where Core permits. No hidden selection or overlap
   between a whole category and its subset. An empty selection keeps saving
   disabled with “Choose supported state to capture.”
   Review shows Selected Domains, Selected Items and Needs Attention cards;
   unsupported state alone is not an attention warning.
   Fully selected item domains use V1 whole-category selection to keep large
   inventories compact; partial domains send item IDs. Fresh confirmation shows
   the newly observed scope. Oversized partial requests fail visibly within the
   existing V1 request limit and require a fresh scan and narrower selection.
3. Secure Transfer is separate and optional. Stage 16E exposes no private identity
   controls and always sends `secure_identities: []`; ordinary SSH configuration
   remains independent. In 16H, within the same Review, **Secure Transfer** shows
   **SSH identities**, their count and “Encrypted separately.” Selection is explicit
   opt-in and defaults off. Show eligible safe key names,
   types and public fingerprints, distinguish SSH configuration from private
   identities, and explain that ordinary Bundle settings are private but unencrypted.
   Keys travel in a separately encrypted component. Preparation does not unlock
   them or prove their pairs; unavailable secure tools show guidance or allow
   continuing without identities.
4. Choose a destination in the native save dialog, then prepare the chosen
   selection again. Desktop normalizes the filename to exactly one `.mbt` suffix.
   Confirmation shows the
   destination and **Included in this capture**, without repeated aggregate counts.
   Read-only details use wrapping neutral labels followed by independent item and
   category warnings with collapsed Technical Details. Back edits the selection.
   Category-only domains retain whole-category scope. macOS Settings shows labels
   for selected Finder, Dock, Windows, Keyboard, Trackpad and Screenshots domains.
   VS Code Settings describes JSON configuration containing `settings.json` only;
   other whole-domain configurations have a bounded inclusion explanation.
   Confirm **Create Saved Environment** using that
   preparation's ID. Execute rescans; changed inventory requires fresh Review and
   confirmation. Existing Bundles require explicit Replace confirmation in the
   native Save Panel.
   Replacement is bound to the observed file digest; Core validates the new Bundle
   before atomic publication, preserving the previous Bundle on failure.
5. Result says **Environment Saved** only with successful publication evidence. Show
   **Domains Saved** and **Items Saved** from validated publication metadata,
   **Needs Attention** as the number of captured Core domains with event warnings,
   and the published destination, with Reveal in Finder. Capture does not
   claim target restoration or final Verification. If cancellation/failure follows
   publication, retain the reported publication and chosen location alongside the
   interruption; do not label the operation successful or imply removal/rollback.

On successful Capture, Reveal in Finder sits beside the saved `.mbt` name/path.
The footer keeps View Log on the left and Capture Again, then Done on the right.
Capture Again starts a fresh scan; Done returns to the initial **Capture this Mac**
state without scanning or navigating to another task. Capture Result shares one
status column across macOS Settings, its six child domains and VS Code Settings;
disclosure arrows retain a separate rightmost column, including narrow layouts.

The current settings checkpoint adds Window shadow / Floating thumbnail and four
Windows controls through the existing Core. Included Settings lists only observed
records, never synthesized defaults; older Bundles remain compatible. Exact keys
and semantics belong to [Configuration](toolkit/CONFIGURATION.md#window-management)
and [Screenshots](toolkit/CONFIGURATION.md#screenshots).
Focused Discovery/Capture/Preview/Apply/Verification/Bundle fixtures and related
Swift PresentationTests passed; the Debug build passed. These are automated
fixture/build results, not real macOS 27 Apply or visual-effect qualification.
The [remaining manual gates](../TODO.md#macos-settings-manual-qualification) stay open.

Stage 16E uses real V1 Capture in normal Debug/Release. Category-only rows have one
category checkbox and read-only details; item-mode rows have native all/none/mixed
selection and bulk actions. Review follows Environment Status's visual groups:
Applications & Tools, Settings, Git, SSH Configuration, Workspace, then Shell when
present. Git Repositories belongs to Workspace. Categories remain collapsed by default.
Capture and Restore share Status's section headers, blue category icons, row surfaces,
metric-card geometry and footer spacing; their models and status/count meanings stay
independent. macOS Settings nests Finder, Dock, Windows, Keyboard, Trackpad and
Screenshots using available Core data and exact supported display labels. Nested
read-only settings do not add selection capabilities. Review retains independent
native domain/item checkboxes. Confirmation and Result use compact read-only details.
Primary actions remain outside the scrolling content. Secure Transfer
is a separate capability disclosure. Confirmation is inline with the exact prepared
scope and destination. User-facing counts use
domains and items; the macOS Settings group and included-settings labels add no
selection counts. Result scope comes from the
published Bundle metadata; selected-category event warnings remain disclosed.
Scan, Checking Your Environment and Saving Your Environment use compact progress
with real Core phase messages, a spinner and cancellation. Core does not report per-item Capture
execution progress, so no waiting task list is shown during publication;
**Captured Environment** follows Review order. Completed requires confirmed domain
inclusion and, for item domains, consistent published counts over the bound prepared
selection. Known limitations show Needs Attention; insufficient item evidence stays
Unverified without inventing an item list. These are capture states, not target
Verification. Core provides no separate inventory/count of omitted items. Result
warnings come from selected-category event evidence.
Stale preparation or any failed/interrupted attempt requires a fresh scan and
confirmation, never a silent execute retry. The exact `stale_prepared_capture` code
shows **Capture Preparation Is Outdated** and asks for Scan Again, preserving the
original technical code and cautious publication message. Capture leaves ordinary
local Generated Configuration/Blueprint untouched and does not rebuild the source Mac.
The [development guide](../desktop/Macseed/README.md#real-capture-16e) provides the
manual gate launch command. The user verified the real-Mac end-to-end gate,
including publication with one `.mbt` extension, warnings and Reveal in Finder.

Capture UI is finalized independently of the remaining Stage 16 work. User-confirmed
real-Mac GUI scenarios cover full capture, category subsets, item subsets, successful
publication with SSH limitations and without warnings, cancellation, stale preparation
after a Mac state change, and successful capture after a fresh Scan. Targeted
CaptureTests/PresentationTests and a Debug build validate the presentation checkpoint;
these manual scenarios are not a full automated regression.

Secure SSH remains part of Capture, not a top-level Credentials area or general
password vault. Selecting none still allows an ordinary Bundle. Passphrase input
uses a focused native secure sheet when required.

## Restore a Mac

**Choose Bundle → Review + Preview → Rebuild → Result**

Restore Preview summary cards follow **Already Match → Changes Planned → Need
Attention**; the existing detailed task rows, statuses and disclosures are retained.

Inspection and Core Verification run within these states; neither requires a
separate page. Prerequisites appear inline only when needed.

1. Open uses a native `.mbt` picker; `bundle_inspect` validates and returns format,
   categories/counts and encrypted-component presence. Invalid/unavailable or
   unsupported Bundles show **Can't Restore**, a typed explanation and Choose
   Another Bundle. Inspection does not promise readiness or expose private values.
2. Stage 16F requires `features.restore_selection.version = 1`; an older Core
   shows an explicit compatibility state. Core inspection owns groups, domain
   labels/modes, availability and stable item IDs. Available ordinary scope defaults
   on. Selection hides domains explicitly absent from the archive or excluded in
   its Blueprint, including retained full inventory with zero selected items.
   Whole selected categories and selected content with limitations stay visible;
   missing presence/selection evidence retains conservative diagnostics.
   Whole domains and item subsets can be selected independently; category-only
   domains remain whole. Desktop sections are Applications & Tools, Settings, Shell,
   Git, SSH Configuration and Workspace. Settings presents one macOS Settings
   aggregate toggle over all captured/available Core-advertised macOS domains,
   plus VS Code Settings. Core retains independent macOS domain capability; normal
   Desktop selection does not expose those children or individual preferences.
   Applications & Tools/Workspace domains remain independently selectable. Selection never
   expands beyond eligible Bundle content. Secure material is reported separately;
   `include_secure: false` is always sent in 16F.
Preview is attention-first and follows the selection taxonomy. Domain rows are
collapsed by default, with real item results available on expansion. macOS Settings
aggregates selected Core domains; underlying setting results remain in Details.
All-satisfied prerequisites use one concise Ready row with optional disclosure;
actionable conditions remain visible in affected prerequisite area rows. The top
attention summary lists affected areas/counts only; lower domains own item details.
Summary counts come from Core plan dispositions.

Selection shows fully/partially/not-selected counts for selectable underlying Core
categories; unavailable categories are excluded and item-level Preview metrics are
unchanged. Selection status and Preview Restore stay in a fixed footer. During
inspection/preparation, an indeterminate Preparing Restore Preview activity explains
that target state is unchanged; no intermediate phases or percentages are inferred.

3. `restore_prepare` supplies both prerequisites and Preview in the same Review
   area, alongside category selection, already-matching summary and changes.
   Bundle changes invalidate the displayed preparation; Preview selection edits
   retain its evidence as stale until explicit Refresh Preview.
   Cancelled, failed or interrupted refreshes clear the old Preview. Back retains
   selection and requires a fresh Prepare.
4. **Fix Issues…** appears when structured state offers supported PKG preparation
   or Automation access. The duplicate **Needs Preparation** block is removed;
   **Refresh Preview** performs reinspection. Unsupported rows explain the limitation,
   and text wraps without overlapping status labels.
   Ready prerequisites without preparation actions are hidden. Manual blockers retain
   their instructions without promising an automatic fix. Specific structured causes
   replace duplicate aggregate inspection consequences; Core evidence remains intact.
   Fix Issues checks Automation permission first, prompting only if undetermined,
   then requests separate consent for explicitly listed PKG installers. A fresh
   Prepare retains unresolved conditions and errors. Denied/restricted access requires
   System Settings or administrator recovery; ordinary Preview never requests permission.
   The explanation states that login-item inspection requires System Events access;
   a successful recheck replaces permission warnings while retaining independent item issues.
   Recheck calls fresh Prepare with the same current inputs,
   then shows the new Preview for confirmation. Core reports all cask item conditions
   and the first operation-wide blocker in other domains; resolving one may reveal another.
   Unsupported independent casks retain Needs Attention while Rebuild is enabled
   for remaining executable work. Existing no-action conflicts also remain
   visible without requesting their mutation; their consumer semantics are
   unchanged. An all-unsupported plan offers no Rebuild.
   A Rosetta prerequisite stays on the affected Cask with a manual Terminal
   installation instruction and **Refresh Preview**; Fix Issues never installs
   Rosetta. Technical Details distinguish unavailable Rosetta from observation
   failure. Independent executable work remains available.
   Do not imply exhaustive readiness.
5. Preview groups actions by category, showing changes, already matching items,
   conflicts, warnings and unknown observations. Call out installs, settings writes,
   backups, repository clones/branch actions and process restarts where reported.
   Never turn unknown observation into a proposed change. Private setting contents,
   remote URLs and credentials are not needed to explain the action.
Stage 16F's real-Bundle manual gate passed with `Test_1.mbt`.

Stage 16G enables Rebuild only for a current ready prepared plan with planned
changes and unchanged selection. A native confirmation is required; Execute sends
the exact prepared ID and selection without silently preparing again. Core revalidates
staleness/prerequisites before mutation. Zero-change plans remain Preview outcomes.
A confirmed `stale_plan` Result says **Restore Plan Is Outdated** and directs the user
to **Refresh Preview**. It states that no changes were made only when Core explicitly
reports no target mutation. The original failure outcome and diagnostic code remain.
For freshness failures, **Copy Diagnostic Details** includes the Desktop prepared,
Execute requested and Core recomputed IDs, plus per-component fingerprint changes
when available. Unknown components remain unknown; changed planning evidence does
not by itself prove target-state changes. See the
[Core diagnostic contract](core/APPLICATION-INTERFACE.md#restore-plans-and-re-entry).
Indeterminate activity uses structured Core phases/records, never synthetic percentages.
Stop Rebuild confirms for every active Rebuild, with Continue Rebuild as the
default and Escape action. An accepted operation-wide graceful request waits for
the current indivisible action and required post-checks, then prevents further
admission at safe checkpoints. Force Stop is a separate confirmed emergency action
using owned-process cancellation. Individual native operations are not universally
interruptible or real-Mac qualified. Completed changes may remain; there is no rollback.
Missing terminal
or malformed result evidence is interrupted/unknown, not success. Results require
structured Verification for clean completion and distinguish attention, cancellation,
failure and interruption. Refresh Preview / Check Current State retains the chosen
Bundle and selection while running fresh Restore Prepare; Finish explicitly clears
the session. Re-entry is not Resume.
The app retains Restore session ownership across window closure; Quit confirms and
waits for owned cancellation. Window-close/quit interaction remains part of Stage 16K
qualification. Private SSH identities remain Stage 16H (`include_secure: false`).
The initial Stage 16G one-folder gate qualified creation and idempotence. The
subsequent broad Restore gate substantially passed with real Rebuild/Verification;
selected `core.editor` / `init.defaultBranch` drift was restored, independently
verified and Already Matches on fresh Preview. Repository identity correlation and
item-local unsupported orchestration are included in the checkpoint. Remaining
compatibility and targeted qualification belong to [TODO](../TODO.md), including
the real Desktop Zsh gate and Secure SSH. Safe Stop/interruption fixture coverage
does not replace all real-process or packaged-runtime qualification.

6. **Rebuild** confirms the selected scope and fresh plan. Disable it for unresolved
   operation-wide environmental blockers or a missing execution bridge.
   Item-local unsupported casks do not block independent executable work; a plan
   with no executable changes has no Rebuild. Preview domain checkboxes change
   the local draft selection without requesting Core. A draft differing from the
   prepared selection disables Rebuild and labels the retained Preview as stale.
   Refresh Preview runs one Prepare with the final draft; counts and readiness
   continue to describe the prepared scope until that refresh completes.
   Excluded domains remain available for reselection; excluding selected SSH removes
   its prerequisite without weakening SSH checks when selected. Back, Refresh
   Preview and Rebuild stay in a fixed footer outside the scrolling task content.
   `pending_unlock` is an expected
   secure step, not proof of a conflict.
   A ready plan still permits later network, account or tool failures. Execute
   revalidates the prepared ID; stale plans return to Prepare/Preview/confirmation.
7. Rebuild shows actual structured phases and records. Core Verification remains
   mandatory in the normal execution path and feeds Result without another screen.
   Interrupted/failed work may have only partial evidence; never imply Verification
   completed when it did not. Confirm Rebuild in the Review area; add a sheet/alert
   only when a specific risk justifies it, not another confirmation page.

Missing Homebrew needs external installation; Desktop does not automatically
install it. Explain selected dependencies such as Command Line Tools, `mas`, VS
Code CLI, network or `age` only when relevant. Do not invent a “Fix All” action or
feed authentication into Core's closed interactive stdin. Administrator, Apple ID,
SSH agent/known-host and vendor authorization are external actions as applicable;
independent macOS/vendor dialogs may appear. `safely_satisfiable` describes Core's
ability, not permission for a new Desktop mutation. Unsupported casks stay visible
and skipped while safe independent work can proceed; Check Again cannot promise
to make unsupported artifacts executable. Cask capability classes and native
Repair are qualified semantically, without name exceptions. Preview identifies
administrator authorization; the Rebuild confirmation explains the separate masked
Homebrew prompt. Privileged uncertainty blocks Homebrew re-entry and is not cleared
by a successful payload check. See the
[Core execution policy](core/APPLICATION-INTERFACE.md). Automatic MAS Restore
remains mandatory before 1.0; the authorization/
install gate is unresolved. Deselecting MAS for the passed gate does not resolve it.

Restore preserves Homebrew Applications and Homebrew Packages as separate task
domains through Preview, Rebuild and Result. Qualified missing-app repairs show
Will Repair / Ready to Repair and Repairing activity. Finished items await
Verification rather than retaining Working or implying success.

Warnings remain visible without automatically blocking a valid Core plan.
Conflicts show affected scope and a safe next step; never offer force overwrite,
reset, cleanup or removal. Unknown reason codes use a neutral explanation and
technical code in Details, rather than guessed remediation.

## Environment Status

**Choose reference → Compare → Result**, with inline expandable Details.
Inspection and comparison are logical work, not additional navigation pages.
The initial Choose Saved Environment card owns reference selection and the read-only notice.
Results use the fixed action footer, semantic Match/Different/Missing/
Not Applicable metrics and whole-row Domain → Items disclosures. Not Applicable
counts only Core Coverage `no_requirement`; excluded, unverified, unsupported,
unresolved and extra facts retain their own labels in summary/details. Domain
rows show only nonzero count pills and indicate additional findings without changing
Core comparison statuses or taxonomy.

The reference is explicit: a user-selected Saved Environment (`.mbt`). Explain
this as “Compare your Mac with a saved environment.” Show which reference is in
use; do not
silently substitute ambient configuration, run Discovery or compare a Mac with a
new scan of itself. First entry without a reference asks the user to choose one.

Validate through `environment_compare`, then show matching, missing, differing,
unverified and unresolved counts, with category and item details. A successful
operation may still find differences. Extra items are informational and visible
only where Core proves complete provenance and successful enumeration; unavailable
extra evidence is not zero. Never offer cleanup or infer removal plans.

An empty comparable scope says “No comparable requirements”; unavailable/invalid
references ask for another reference, and changed references require a fresh check.
Compare is an explicit read-only action; do not auto-run it after Restore.

### Bundle handoff

Both directions retain independent Status and Restore session state. On first
opening Status without a reference, the current Restore Bundle becomes its reference;
comparison still requires an explicit action and fresh Core validation.

A completed Status result with a Bundle reference and Core-confirmed Different or
Missing offers **Review in Restore** in the fixed result footer, beside **Compare
Again**. No handoff is offered for a development reference, before/during comparison,
a failed/cancelled result or coverage warnings alone. Active operations and Restore
Rebuild confirmation block the transition without stopping or replacing their work.

The action passes the original `.mbt` URL to the existing Restore workflow. An empty
session starts Restore's own read-only Bundle inspection and ordinary Selection.
The same Bundle preserves existing Selection and Preview, including existing error
and refresh/recovery semantics. Replacing another session requires **Replace Current
Restore Session?**: **Cancel** leaves Status and the prior Restore session unchanged;
**Use Selected Environment** inspects the new Bundle afresh. Prior comparison is
not proof of Restore eligibility; inspection failures retain normal Restore errors.

Only the Bundle is passed, with no automatic selection of Different/Missing items,
Prepare, Preview or Execute. The user selects components and explicitly requests
Preview and Rebuild. Status reference/result and the reverse Restore → Status flow
are preserved. Status → Restore handoff was implemented after completed Stage 16K
and passed manual GUI acceptance.

Implemented in normal Debug/Release: native Bundle file selection, the selected
filename, Core comparison and fresh **Compare Again**. Reference changes clear
previous results.
Status shows Match, Different and Missing cards; Not Applicable appears only when
nonzero. Blue category icons are preserved. Details reuse Core/Restore grouping,
with one macOS Settings disclosure over participating child domains; Git Repositories
appears in Workspace after Workspace Folders. Excluded inventory is hidden only in presentation.
Diagnostics correlate to comparison items by their record owner and domain/item ID;
matching evidence and independent warnings remain within one row. Matching items
show a compact accessible checkmark without generic subtitles or Technical Details;
problem items retain reasons and useful technical evidence. macOS child domains use
independent collapsed disclosures inside macOS Settings; Expand All controls only
main categories. Setting names reuse Capture labels.
Category rows retain nonzero Core-record count pills. Already Matches indicates
confirmed conformity; independent verification or coverage problems show Needs
Attention. Confirmed differences alone produce Differences Found overall.
Only Result actions use a fixed footer outside
ScrollView; Choose/Failure actions stay with their content and Cancel sits left below
the process card.
App Store display names come from the validated Bundle/Restore label projection;
missing names retain a neutral label and numeric ID in Technical Details.
Summary omits zero counts and identifies unsupported/unknown-difference subsets.
Collapsed categories expose descendant attention; details preserve matching, missing,
different, unverified, unsupported and unresolved facts, plus Coverage/diagnostics.
Unavailable extra evidence is disclosed as unavailable; only Core-confirmed available
extras appear as items. Invalid reference, failed/interrupted operation or malformed
result evidence cannot render a clean conclusion. Results/errors stay inline.
The [development guide](../desktop/Macseed/README.md#real-environment-status-16d)
provides the manual launch command. The earlier Stage 16D manual gate was approved;
Stage 16K Bundle-backed Status is accepted after real-Mac GUI qualification.

Confirmed Environment Status Cancel returns to reference selection while retaining
the chosen Bundle. A missing/invalid terminal outcome remains interrupted/unknown;
it is not inferred to be successful cancellation. Internal staging/reporting I/O
failures no longer masquerade as `bundle_unavailable`, which is reserved for source
Bundle availability failures. This does not change Restore Stop semantics.

### Required final product reference before Macseed 1.0

Normal Desktop now selects a Saved Environment `.mbt` through a native file picker;
the Generated Configuration/Blueprint development bridge is no longer exposed.
Selection shows the filename and clears old results without automatically comparing.
Compare This Mac, Cancel, Compare Again and Choose a Different Environment remain
explicit actions. Comparison metrics, collapsed Domain → Items and Technical
Details preserve Core verdict/completeness and extra evidence.

The final flow uses **Saved Environment / Bundle** consistently: Capture creates
one, Restore selects one, and Environment Status selects one to compare with this
Mac. After Restore, that Saved Environment must also be available as the natural
reference for verification/status without asking for internal directories.
Blueprint may remain Core's internal selection mechanism; users normally express
selection through Capture/Restore category/item controls.

The additive Protocol V1 `bundle_path` comparison form and capability marker are
implemented. Core validates and privately stages the Bundle, preserves its Blueprint
selection/provenance, compares read-only and removes staging without publication or
secure decryption. Desktop retains Bundle references only for the current window
session. The [Bundle handoff](#bundle-handoff) reuses this reference without cached
Verification evidence. Existing Debug sample
flows are unchanged. Focused automated checks and real-Mac GUI qualification are
complete for Stage 16K Bundle-backed Status. Packaging/runtime hardening remains
separate unfinished work.

Bundle-backed Status also provides the foundation for the
[future Environment Manager](../ROADMAP.md#environment-manager--post-10--future-direction).
Stage 16K must avoid unnecessary binding to one permanent reference while adding
no Profiles, History, Drift Detection or Selective Apply now. Future user-selected
and confirmed Apply from Status must reuse Restore Prepare → Preview → Confirm →
Execute → Verify; comparison stays read-only, with no second Restore/Verification
engine and no deletion implied by absent profile items.

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

For no-change Preview show **Already Matches** for observed satisfied rows and
“No changes planned” for the plan. Unknown or pending secure work prevents an
all-matching claim. If the user chooses Rebuild to verify a no-change plan, use the
normal fresh confirmation and execution contract; Preview alone is not final Verify.
When execution completes and relevant selected requirements verify with complete
evidence and no remaining attention, Result says **“Your environment is ready.”**
A short scope line makes clear this means the selected supported environment.
No technical Verification page is required. Use the Restore result contract below
for remaining outcomes; show verified areas and specific unresolved items. A stalled
download advises checking the network or VPN before a fresh Preview. Keep
aggregate/technical reasons in Details and expose **View Details**.
Use Core counts without conflating operation records with unique verified items or
counting unsupported twice. Technical details retain “Selected requirements verified,” gaps
and per-item evidence. Verification always runs in normal Restore; its UI becomes
prominent when attention is needed. Capture/Status likewise expose only relevant
outcomes by default. None of these states proves app runtime health, visual effects,
remote SSH authentication, agent/Keychain readiness or whole-Mac identity.

### Restore result contract

Restore presents Core evidence through dedicated Preview, Progress and Result views.
Progress uses fixed-height category rows and real structured activity. Active work
shows **Working** unless a known problem requires **Needs Attention**, with warnings
retained below the list. Completed execution and no-change plans await Verification;
Preview and operation receipts alone never make category statuses green. Complete
category Verification evidence permits independent **Completed** / **Already Matches**
finalization without resetting confirmed categories merely because another phase starts.
Latest category operation, Verification and Coverage records remain in memory for the current Restore even when the transport's
bounded event window advances; no persistent journal is created.

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

Result keeps the operation outcome in its heading/compact status and a separate
Verification completeness line. At most three positive-count cards summarize selected
plan rows: Successful, Needs Attention and neutral Skipped. Zero-count cards are
hidden; unavailable counts are not fabricated as zero. Their disjoint breakdowns use
the same row classification as categories, never global Verification predicates.
Applied or Already Matches without Verification remains positive, explicitly marked
not verified; a confirmed failure, mismatch, conflict or blocking unsupported state
takes priority. Neutral skips require a reported skip with an eligible reason.
Unestablished/not-run rows do not become failed or skipped; the incomplete-scope
explanation appears only when such rows actually exist. A confirmed unsupported
outcome is counted as Needs Attention, not automatically as unknown.
Positive global Mismatch/Unverified counts and Unresolved remain separate text,
not additional cards. Missing counts remain unknown. Process Result stays independent.
Confirmed user Stop/Force Stop intent is kept only for the current operation ID in
memory: Stopped by User requires a matching handled stop outcome; Force Stop Requested
never replaces an Interrupted outcome or claims that all work stopped.
The persistent Operation Log preserves safe structured diagnostics. The lower
collapsed Technical Details/copy fallback appears only when View Log is unavailable.
**Copy Diagnostic Details** copies the available
allowlisted terminal, execution, Verification, coverage and diagnostic fields,
including successful evidence. Raw process output, arbitrary payload fields and
secrets are excluded; this is not a raw Core log. Categories convey verified work
without a repeated successful-area summary. Clean Result also offers diagnostic copying;
actions remain in the fixed footer. This does not close packaged-runtime qualification.

User-confirmed real-Mac GUI validation covered Preview → Rebuild → Verification,
the running **Waiting**, **Working** and **Awaiting Verification** states, and
evidence-based **Completed** / **Already Matches**. An earlier Partial Restore with the known
`tailscale-app` limitation reported **Mismatch: 1**, **Unverified: 0**; this historical
observation is superseded for current status by the snapshot below. An intentional
`stale_plan` was rejected before target mutation and displayed **Restore Plan Is
Outdated** with nine neutral **Not Run** categories. **Refresh Preview → Rebuild**
in the same session then completed successfully without another `stale_plan`.

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
Preserve Core terminal codes, exits and Verification verdicts in Details. Current
Protocol V1 can retain exit `2` / `bootstrap_failed` for item failures with
`independent_work_completed=true`; the
[Core evidence contract](core/APPLICATION-INTERFACE.md#independent-homebrew-items)
remains authoritative. User stop with incomplete termination evidence is
Interrupted/Unknown, not a confirmed Stopped result. Cancellation before execution
remains Cancelled. No result promises rollback or whole-Mac identity.

Fix Issues also handles explicit PKG installer preparation. When Core offers a
preparation identity for a clean native package, Desktop lists the concrete casks
and asks before downloading/inspecting them. A PKG-only refusal retains the existing
Preview; if Automation was already checked, refusal rechecks without PKG consent.
Consent applies only to the displayed identities and current selection; after
inspection a new Preview requires a separate Rebuild confirmation. A changed or
expired identity requires new consent. No archive download occurs on ordinary
Refresh Preview. Tailscale 1.104.1 passed preparation, Clean Install, Verification
and a fresh matching Preview; this does not qualify unsafe Repair. See the
[Core contract](core/APPLICATION-INTERFACE.md#explicit-pkg-installer-preparation).

## Recent Restore qualification and performance

Current checkpoint: `778b816`, with subsequent user-confirmed real-Mac evidence
(2026-10-17). Tailscale 1.104.1 passed **PKG Preparation → Clean Install →
Verification → fresh matching Preview**. Receipt-backed PKG Repair provenance is
implemented, but unsafe Tailscale Repair remains **Unsupported**
(`ownership_unproven`); in-place Repair is not implemented. Homebrew removal of
Tailscale was performed separately from Macseed and is not a Restore capability.

A real Partial Restore completed with **105 Verified and one Tailscale Mismatch**,
correctly showing **Rebuild Needs Attention**. Item-local `cask_target_conflict`
and `cask_execution_requirements_unsupported` preserve independent executable work
unless a global prerequisite blocks it. MAS Restore is the next mandatory
functional priority; Secure SSH and the remaining release gates stay open.

Historical performance evidence at `c06e530` (2026-10-16): user-reported controlled
real-Mac checks accepted the final category/item Result UI, nested macOS settings,
compact confirmed counters, Early Cancelled and Partial Stopped presentation.
This closes the functional Result UI checkpoint, not all Stage 16I completion,
interruption/accessibility or packaged-runtime gates.

The performance checkpoint reuses per-pass inventories and input validation,
removes duplicate Bundle validation without weakening integrity/stale-plan gates,
and removes PKG downloads from Cask state classification. Local receipts, metadata
and captured payload contracts retain conservative unsupported/unverified outcomes.
[Core](core/APPLICATION-INTERFACE.md#opt-in-restore-performance-trace) owns the opt-in
trace and measurement contract. It is disabled by default and outside Protocol V1.

| User-reported real-Mac measurement | Before | After |
|---|---:|---:|
| Restore Execute | 191.2 s | 87.2 s (about 54.4% lower) |
| Readiness requirements | 30.47 s | about 9.8–10.8 s |
| Homebrew Cask Verification | Not isolated in the comparison | about 6.23 s |

Repeated approximately 20-second PKG downloads were eliminated. These are individual
runs with differing conditions/actions, not a controlled benchmark or guaranteed
performance on another Mac. Existing focused tests cover local PKG evidence,
no-download classification, Verification, trace behavior and Desktop's environment
allowlist; this documentation audit did not rerun tests or workflows.

At that historical performance checkpoint, Restore reported **127/128 Verified, 1 unsupported/unverified,
0 Mismatch**, with `tailscale-app` unresolved. **Process Result: Failed**,
**Reason: `bootstrap_failed`**, **Verification verdict: `incomplete`** remain the
historical facts, superseded for current qualification by the bounded results above.
Verification collection completeness and conformity verdict are
separate; global predicate counts are not Successful plan-row counts. Removing
network delays does not qualify Tailscale installation/repair, VPN activation or
application health, and does not convert this partial result into success.

## Desktop Visual Unification — Completed

Environment Status is the approved visual reference. Capture and Restore Selection,
Preview, Execution and Result share category ordering, blue SF Symbols, section
headers/dividers, grouped surfaces and metric-card styling. Git Repositories belongs
to Workspace. Domain IDs, selection granularity, Core execution and Verification
remain authoritative and unchanged.

Restore Result follows the [Restore result contract](#restore-result-contract),
including conditional plan-row cards, neutral category Unverified and fallback
Technical Details. Logging & Diagnostics was completed separately in Stage 16J;
terminal Restore categories now reuse Environment Status's disclosure style,
functional sections, shared category icons/surfaces and compact colored counters.
Running categories remain compact and non-expandable. Terminal rows expose safe
Preview names and existing item-local operation/Verification evidence, including
stopped and failed results. Applied, Already Matches and Verified are independent
evidence. Each terminal item contributes to at most one counter: Success, Needs
Attention or Skipped. Blocking unsupported skips remain Needs Attention. Verified
evidence takes precedence over Applied in the item label and Successful breakdown;
Applied/Already Matches without that evidence is explicitly not verified. Independent
Verification problems remain visible. The running
category list has no lower warning banner. Final categories support Expand All /
Collapse All and start collapsed. Successful items omit local Technical Details;
problem evidence remains local and in the shared log. Current failed/blocked/conflict
evidence takes priority over earlier Applied evidence without discarding that action.
Unreported auxiliary macOS restart rows are hidden when no specific or unexplained
scope failure requires them; they contribute no outcome count and never imply Apply
or Verification. Underlying plan/evidence remains available for diagnostics.
Final category rows retain one evidence-based status and number-only pills with
accessible labels; one legend explains their colors. macOS Settings uses independent
collapsed Finder/Dock/Windows/Keyboard/Trackpad/Screenshots children and shared exact
setting labels. Execution records are matched to the plan action as well as item.
Running Stop uses neutral Stopping Rebuild wording. Long Graceful Stop waits remain
an external-lifecycle limitation; this presentation change does not alter timeouts.
Unknown item outcomes show Outcome Unknown; confirmed absence of execution shows
Not Run. Neither creates a numeric result. Preview blocked/conflict reasons retain
their own meaning rather than becoming Verification failures. Positive counters count evidenced plan
items, not Verification predicates. Category-only coverage and incomplete evidence
remain visible through category status and View Log or fallback Technical Details. No new
operations run when expanding results. Functional categories/disclosures and real
stopped-result presentation are manually accepted. Unexercised accessibility,
window-size and completion edge cases remain bounded qualification work.

<a id="restore-cancellation-safety"></a>

## Restore Cancellation Safety — implementation and remaining qualification

Stage 1–2 fail-closed cancellation is implemented. A negative `ProcessTree.stop()`
result or unavailable process observation preserves `unknown_consequences` through
`OwnedBootstrap.cancel()` and Core terminal reporting; Desktop presents the existing
Interrupted/Unknown outcome rather than claiming confirmed termination.

Operation-wide Restore Graceful Stop is implemented over the existing private
control pipe and locked controller. Requests latch during preparation and every
module scope. Safe checkpoints apply Stop around preparation/publication/Bootstrap,
between modules, Workspace folder/repository items, VS Code/App Store items and
macOS settings categories, and before/after Global Verification. Atomic publication,
a current clone/install with post-checks, settings category, Git configuration,
SSH/Shell application and secure import finish as indivisible work. Already-running
Verification may finish; handled Stop does not start a new full-scope Verification.
Homebrew retains atomic Stop/native-launch admission and never receives a Graceful
Stop signal. Partial records and actual publication/mutation facts remain authoritative.

Desktop distinguishes delivered **Stop Requested**, accepted **Stopping Rebuild**,
**Stop Unavailable**, delivery failure and terminal **Stopped by User**. Rejected
requests do not leave Stop Requested on an ordinary final result. Force Stop stays
separate, confirmed and available while waiting; its existing TERM/KILL mechanics
may leave unknown detached/privileged effects. Stop-state is operation-bound.

Graceful waiting has no guaranteed time bound for an unresponsive active installer.
No automatic installer kill, rollback, Resume or DMG cleanup is introduced. Re-entry
requires fresh Prepare → Preview → Execute. Stage 3C ordinary-Cask durable
journal/reconciliation and complete installer-quiescence qualification remain open.

Unreported auxiliary Finder/Dock restart rows are hidden only without a specific
or unexplained scope failure, and never count as success. Independent category
problems remain visible; aggregates explained by established item problems do not
repeat a generic warning. Raw plan/evidence and logs remain intact.

Automated Stop fixtures pass 23 checks, including pre-preparation, preparation,
publication, non-Homebrew scopes, repeated requests, module/settings boundaries,
shared-controller ownership and native launch races. These fixtures establish automated checkpoint behavior. The user subsequently
confirmed operation-wide Graceful Stop and Early Cancelled / Partial Stopped on a
real Mac. Those controlled scenarios do not qualify every installer timing,
detached/privileged process or interruption path. The historical Firefox evidence
below retains its original narrower scope.

### Firefox Cask incident — 2026-10-13

The user reproduced the following sequence:

1. Stop Rebuild was requested during the Homebrew Cask installation of Firefox.
2. Firefox remained uninstalled; a subsequent Restore reported `item_install_failed`.
3. Direct Homebrew installation also failed with
   `hdiutil: attach failed - Ресурс занят` (resource busy).
4. `hdiutil info` showed a Firefox DMG still attached under
   `/private/tmp/homebrew-dmg...`.
5. After resolving the attached-image issue, another Macseed Restore succeeded:
   All Done, Verification Complete, Homebrew Applications — Completed.

This is a reproduced reinstallation failure associated with a busy DMG. The sequence
is consistent with interruption leaving an attached image, but the precise mechanism
of an orphaned mount has not been established by instrumented tracing. It warrants
a separate Cancellation Safety stage; this checkpoint implements no mount cleanup.

### Firefox Graceful Stop smoke test — 2026-10-14

The user removed Firefox beforehand and ran Restore from `Test_1.mbt`, then pressed
Stop Rebuild. Desktop showed **Rebuild Stopped** and **Verification Not Run**.
Subsequent user checks found:

- `brew list --cask --versions firefox` → `firefox 157.0.1`.
- `/Applications/Firefox.app` existed.
- `hdiutil info` showed no Firefox DMG.
- A fresh Restore Preview reported **120 Already Match**, **0 Changes Planned** and
  **0 Need Attention**.

This smoke test passed, but an event log did not confirm the exact Stop-acceptance
time relative to completion of the native installation. It does not establish full
installer-interruption qualification or prove Stop was accepted during installation.

Remaining Cancellation Safety work includes Stage 3C durable ordinary-Cask
journal/reconciliation, operation-owned DMG/re-entry evidence, detached/privileged
process quiescence and separate MAS and other-category qualification. It must protect
user data and never detach unrelated volumes. Completed Stage 16J diagnostics
records evidence; it provides no durable recovery/reconciliation or re-entry authority.

## Progress, cancellation and re-entry

Use indeterminate progress plus named phases and the latest safe category/item.
Render `phase_started`, `phase_completed`, Capture/secure events and Restore
`execution_event`/record events. Completed-phase markers do not imply a percentage;
there is no reliable total-work estimate. Prepare/Inspect may expose only start and
result: show “Checking…” without fabricated substeps. Keep Details collapsible.

Before target mutation begins, **Cancel** ends the operation. Say “No target
changes occurred” only when Core evidence establishes that fact; local configuration
publication is a separate effect. Once mutation may have begun, use **Stop Rebuild**.
A small native confirmation says: “Stop rebuilding? Macseed will stop further work.
Changes already completed will remain. You can inspect the Mac and plan another
rebuild later.” Delivered requests show “Stop Requested”; accepted requests show
“Stopping Rebuild” while the current indivisible work finishes. Emergency Force Stop
retains separate cancellation reporting.

**Current V1 constraint:** operation-wide checkpoint Graceful Stop reuses the existing capability,
a private control channel and structured acknowledgement/events; existing V1 terminal
semantics are retained. Force Stop uses signals and may interrupt an in-flight tool.
Neither path promises global detached-process quiescence, atomic installation or
rollback. Native lifecycle boundaries require real-Mac qualification; fresh re-inspection
is required before another Restore.
Transactional rollback is explicitly outside Macseed 1.0 scope.

Secret sheets may send secret-channel cancellation. Handle Capture/Restore
`failed` cancellation codes and Compare's `cancelled` event. A result is provisional
until the terminal event; missing terminal event, invalid transport or unexpected
exit is Interrupted, never successful completion. If publication or mutation facts
have not arrived, conservatively treat effects as unknown and use Stop Rebuild
rather than promising no changes.

After stopping show a compact Result: completed actions, already matching where
known, remaining/not processed where evidenced, and Needs Attention. Do not infer
an exact remaining-item cursor from missing records; say “Not confirmed” when work
or verification is unknown. Preserve partial evidence, publication facts and
possible target mutation; changes may remain and the Mac was not rolled back.

Re-entry inspects the current Mac again, creates a fresh plan/Preview, confirms
it, then applies remaining differences while already-satisfied items become no-ops.
There is no stored-item-cursor Resume. Remembered inputs are draft choices requiring
revalidation, never continuing authorization. `recovery_required` directs users to
existing CLI Restore recovery; Desktop must not silently recover publication state.
After prerequisites use Check Again; stale plans return to Review/Preview.

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

The production presentation catalog/mapping owns canonical domain/group labels,
icons, colors, action verbs, status text and typed reason/prerequisite guidance
used by production views. It translates Core identifiers;
it is not a second inventory, observer, readiness engine or domain state model.

| Generic UI input | Existing structured source |
|---|---|
| Categories and selection controls | Capture `inventory.domain/status/reason/selection_mode`; Restore selected groups/categories/counts |
| Items and labels | Capture `item_id/label`; Preview `domain/item_id`, optional repository `display_name`; opaque IDs get neutral labels |
| Actions and plan state | Preview `action/disposition/reason`, `has_planned_changes`, `has_executable_changes`, module summaries |
| Prerequisites | `readiness.conditions` domain/code/status/scope and optional selected-item index; execution-launch bridge condition |
| Progress and operation outcome | Event type/sequence/phase, operation records, terminal code and publication/mutation flags |
| Verification and coverage | Core summary/verdict/counts and Verification/Coverage/Operation/Diagnostic records with actual detail status |
| Comparison | Summary, comparison records, support/reasons, extra-domain availability and extra items |

New items in an existing domain use the same rows and controls. New categories or
reason codes may need catalog entries, usually no bespoke screen. Unknown IDs use
safe generic labels; unknown enum values retain their code in Details and prevent
an unsupported success/action inference. Do not extract human labels from CLI logs.
Category-only settings stay category-only; no per-setting Capture control or
private-value editor is promised. `capabilities` advertises operations, version and the additive Restore selection
feature. Restore group/domain modes and inventory come from Core, not a Swift
support catalog.

**Protocol-fit assessment:** the flows above use only existing V1 operations,
structured results/events and the separate secret channel, without human stdout,
stderr or log parsing. Operation-wide checkpoint Graceful Stop reuses the additive
Homebrew capability and private control channel; no new public V1 status is introduced.
Signal-based Force Stop does not guarantee safe completion of an active installation.
Global child-process quiescence, ordinary-Cask durable recovery and other-category
qualification remain open in the [Cancellation Safety checkpoint](#restore-cancellation-safety).
Any further Protocol V1 changes require test evidence. Comparing
a Bundle directly is supported by the additive `bundle_path` form described above.
Fine ordinary Restore selection is Core-supported;
decrypted identity selection during Prepare and Desktop recovery remain outside
the current contract. Any
extension needs a precise Core contract decision, not a client-side parser.

## Unified UI Scenario Catalog — deferred UI/dev tooling

The planned catalog is a Debug-only synthetic presentation harness, distinct from
the production presentation catalog/mapping above. It renders production models
and views without Core mutation:

```text
Synthetic Scenario Fixtures
          ↓
Production Presentation Models
          ↓
Production Views / Shared Components
```

The Debug catalog owns fixtures and navigation only. Production owns semantic
status, labels, icons, colors, cards/rows, disclosures and action presentation;
the catalog must not duplicate production UI. Intended coverage includes Restore,
Capture, Environment Status and useful shared semantic states/components.

The full catalog is deferred, not cancelled and not a prerequisite for functional
work. Existing Debug design-preview, sample fixtures and DemoSession remain;
they partially provide scenario tooling, not the complete unified catalog.
After functional priorities, consider a Lite set of representative Capture,
Restore and Status states: Ready, Working, Already Matches, Needs Attention,
Error, Cancelled and Interrupted where applicable. Reuse approved Minimal Premium
production presentation models/shared views, with minimal fixture/navigation
infrastructure and no parallel components or copied obsolete preview styling.
Small focused fixtures and PresentationTests may be added as needed during
functional development without constructing the full catalog first.

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
technical-log file. Existing flow Technical Details / Copy Diagnostic Details
remain separate presentations, not access to arbitrary Core logs.

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
Operations history. A local **View Log** appears only after an established terminal
result in Capture, Restore and Environment Status, including failed, needs-attention
and stopped results. It is absent during active work and intermediate stages;
Inspect/Preview logs remain accessible through Settings history. A local entry
initially selects its corresponding operation. Selection switches summary, timeline,
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

Local foundation/viewer/report tests and Debug builds passed. Stage 16J.4 validation
included DiagnosticReportTests, related OperationLogViewTests, one full
PresentationTests run and a Debug build. Tests covered nested privacy exclusions,
exact preview/copy/save bytes, snapshot stability/explicit refresh, save cancellation
and errors, unavailable/crash-tail sources, close-during-load, and bounded generation
with a native TextKit preview of a 6000-record fixture. Operation Logs UX was manually
accepted by the user. The report's native Save panel interaction and user-driven
scrolling were not manually verified in that implementation pass. No hosted CI or
signed/notarized clean-Mac result is claimed. Stage 17 must qualify those packaged
flows; future Secure SSH integration needs corresponding privacy fixtures.

## Implementation slices and qualification

| Slice | Deliverable |
|---|---|
| 16B — Native shell and design foundation | Native navigation, stable content states, small Settings, reusable rows, vocabulary, accessibility and empty states |
| 16C — Core process integration and capabilities | Core/Python layout, writable state/temp, controlled child HOME/PATH/environment, JSONL validation, process ownership and cancellation |
| 16D — Environment Status | Explicit reference picker, read-only Compare, summary and record details |
| 16E — Capture | Inventory/selection, fresh preparation, Bundle publication and interruption states; secure interactions remain 16H |
| 16F — Restore preparation | Core-supported domain/item selection, Bundle inspection, prerequisites, Check Again, Preview and fresh confirmation |
| 16G — Restore execution | Implemented: Rebuild phases/records, operation-wide checkpoint Graceful Stop, separate Force Stop, partial failure and fresh-plan re-entry; capability/installer qualification remains open |
| 16H — Secure SSH interactions | FD bridge/challenges, encryption/unlock/import confirmation and age/OpenSSH PTY qualification for Capture and Restore |
| 16I — Verification and completion | Functional Result UI implemented/manually accepted; confirmed plan-row cards and item evidence; remaining completion edge-case qualification open |
| 16J — Diagnostics and support | Completed: persisted typed logs, shared viewer/history, Important/All, retention/clear and immutable Diagnostic Report preview/copy/save |
| 16K — Desktop integration hardening | Full flow/transport/security/accessibility checks, stale inputs, interruptions and diagnostic acceptance |

Slice identifiers above retain their historical meaning; practical execution order
is tracked in [Roadmap](../ROADMAP.md#current-practical-execution-order).

Every slice uses existing Core operations; early flow slices retain incomplete
features as unavailable rather than pretending secure or verification support.
Persistent logging sanitizes before recording flow events; completed 16J owns the
Desktop logging and support experience, not Core technical logging or recovery.
Today's repository Core and external Python are not an installed-app runtime.
Stage 16 must qualify runtime and secure tool integration.

[Distribution](DISTRIBUTION.md) owns Stage 17 signed/notarized packaged clean-Mac
proof, including operation logs, interruption details and exact Diagnostic Report
preview/export privacy. [TODO](../TODO.md) owns unfinished implementation work.
Before **Macseed 1.0**, an Early Access/Alpha phase with approximately 10–20
technical external users will validate real Capture/Restore flows using voluntarily
shared privacy-safe reports/issues; resolve real compatibility and UX problems
before public launch. This is product validation, not another framework.
The mature toolkit/CLI history and current 3.4.0 Core/CLI version remain intact.
