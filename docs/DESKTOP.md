# Macseed Desktop

**Stage 16B–16E implemented and manually approved. Next: 16F Restore Prepare.**
Normal launch checks real Core capabilities over Protocol V1. The approved sample
flows remain available only in explicit DEBUG design-preview mode. Environment
Status uses real read-only Core comparison. Capture scans/selects/prepares and
publishes a real Saved Environment through Core. Restore is not connected yet;
private SSH identity transfer remains 16H.
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
Real Restore presentation and diagnostic persistence/export remain their named slices.

## Window and navigation

Use one main window with three sidebar destinations: **Capture this Mac**,
**Restore a Mac**, and **Environment Status**. An operation detail view belongs to
the active flow; diagnostics are available from its Details and the Help menu.
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

Settings remains small: General may offer a default Bundle location and useful
confirmation preferences if implementation demonstrates value. Preferences must
not bypass fresh-plan confirmation or secure import consent. Privacy / Diagnostics
provides diagnostic controls and Open Logs Folder where appropriate, preserving
private storage and sanitization. Reserve Updates only if the eventual Stage 17
mechanism needs it; no updater is defined here. Use standard macOS About behavior,
not a custom About settings page. Diagnostics remains contextual through View
Details and Export Diagnostic Report, not a primary raw-log destination.

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
4. Choose a new destination in the native save dialog, then prepare the chosen
   selection again. Desktop normalizes the filename to exactly one `.mbt` suffix.
   Compact confirmation shows prepared area/item counts, included area summaries,
   destination and relevant warnings; detailed inventory stays in Review via Back.
   Category-only areas show Included; macOS Settings shows selected child scope.
   Confirm **Create Saved Environment** using that
   preparation's ID. Execute rescans; changed inventory requires fresh Review and
   confirmation. Never overwrite an existing Bundle; choose another destination.
5. Result says **Environment Saved** only with successful publication evidence. Show
   selected scope and the chosen location, with Reveal in Finder. Capture does not
   claim target restoration or final Verification. If cancellation/failure follows
   publication, retain the reported publication and chosen location alongside the
   interruption; do not label the operation successful or imply removal/rollback.

Stage 16E uses real V1 Capture in normal Debug/Release. Category-only rows have one
category checkbox and read-only details; item-mode rows have native all/none/mixed
selection and bulk actions. Groups remain collapsed by default. Confirmation is
inline with the exact prepared scope and destination. User-facing counts use
areas and items; the macOS Settings group and included-settings labels add no
selection counts. Result scope comes from the
published Bundle metadata; selected-category event warnings remain disclosed.
Stale preparation or any failed/interrupted attempt requires a fresh scan and
confirmation, never a silent execute retry. Capture leaves ordinary local
Generated Configuration/Blueprint untouched and does not rebuild the source Mac.
The [development guide](../desktop/Macseed/README.md#real-capture-16e) provides the
manual gate launch command. The user verified the real-Mac end-to-end gate,
including publication with one `.mbt` extension, warnings and Reveal in Finder.

Secure SSH remains part of Capture, not a top-level Credentials area or general
password vault. Selecting none still allows an ordinary Bundle. Passphrase input
uses a focused native secure sheet when required.

## Restore a Mac

**Choose Bundle → Review + Preview → Rebuild → Result**

Inspection and Core Verification run within these states; neither requires a
separate page. Prerequisites appear inline only when needed.

1. Open uses a native `.mbt` picker; `bundle_inspect` validates and returns format,
   categories/counts and encrypted-component presence. Invalid/unavailable or
   unsupported Bundles show **Can't Restore**, a typed explanation and Choose
   Another Bundle. Inspection does not promise readiness or expose private values.
2. Review allows disabling the authoritative groups: Applications, VS Code
   Settings, Homebrew, macOS Settings, Shell, Git, SSH Configuration and Workspace.
   Included ordinary groups default on; secure import defaults off, even when
   present. Groups can be narrowed, never expanded beyond Bundle content. Item
   details are informational: Protocol V1 does not allow item-level Restore edits.
3. `restore_prepare` supplies both prerequisites and Preview in the same Review
   area, alongside category selection, already-matching summary and changes.
   Selection changes invalidate the displayed preparation and confirmation.
4. Inline prerequisites show selected-work conditions, **How to Resolve /
   Instructions** and **Check Again**; no dedicated prerequisite page by default.
   Recheck calls fresh Prepare with the same current inputs,
   then shows the new Preview for confirmation. Core reports the first blocker
   per domain; resolving one may reveal another. Do not imply exhaustive readiness.
5. Preview groups actions by category, showing changes, already matching items,
   conflicts, warnings and unknown observations. Call out installs, settings writes,
   backups, repository clones/branch actions and process restarts where reported.
   Never turn unknown observation into a proposed change. Private setting contents,
   remote URLs and credentials are not needed to explain the action.
6. **Rebuild** confirms the selected scope and fresh plan. Disable it for unresolved
   environmental blockers, unsupported selected execution, or missing execution
   bridge. `pending_unlock` is an expected secure step, not proof of a conflict.
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
ability, not permission for a new Desktop mutation. Unsupported execution requires
changing scope or another supported route; Check Again cannot promise to fix it.

Warnings remain visible without automatically blocking a valid Core plan.
Conflicts show affected scope and a safe next step; never offer force overwrite,
reset, cleanup or removal. Unknown reason codes use a neutral explanation and
technical code in Details, rather than guessed remediation.

## Environment Status

**Choose reference → Compare → Result**, with inline expandable Details.
Inspection and comparison are logical work, not additional navigation pages.

The reference is explicit: a user-selected Generated Configuration directory and
an optional Blueprint file, or explicitly no Blueprint. Explain this as “Compare
this Mac with a saved configuration.” Show which reference is in use; do not
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

Implemented in normal Debug/Release: native folder/optional Blueprint selection,
explicit reference paths, Core comparison and fresh **Check Again**. Reference changes
clear previous results; choosing another folder also clears the previous Blueprint.
Summary omits zero counts and identifies unsupported/unknown-difference subsets.
Collapsed categories expose descendant attention; details preserve matching, missing,
different, unverified, unsupported and unresolved facts, plus Coverage/diagnostics.
Unavailable extra evidence is disclosed as unavailable; only Core-confirmed available
extras appear as items. Invalid reference, failed/interrupted operation or malformed
result evidence cannot render a clean conclusion. Results/errors stay inline.
The [development guide](../desktop/Macseed/README.md#real-environment-status-16d)
provides the manual launch command. Stage 16D's real-Mac manual gate is approved.

### Required final product reference before Macseed 1.0

The current Generated Configuration folder/optional Blueprint picker is a
**temporary development bridge**, not the intended final Desktop UX. Ordinary
users must not need to find `config/generated`, choose a Blueprint file or
understand those internal mechanisms.

The final flow uses **Saved Environment / Bundle** consistently: Capture creates
one, Restore selects one, and Environment Status selects one to compare with this
Mac. After Restore, that Saved Environment must also be available as the natural
reference for verification/status without asking for internal directories.
Blueprint may remain Core's internal selection mechanism; users normally express
selection through Capture/Restore category/item controls.

Complete this in future Stage 16 integration/hardening before 1.0. The likely
boundary is safely validated Bundle staging/reference extraction over the existing
comparison engine. Current Protocol V1 accepts Generated Configuration only;
qualify the required Core contract explicitly then. Stage 16E implements neither
Bundle-backed comparison nor a client-side Bundle parser or speculative V1 change.

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
No technical Verification page is required. Otherwise say **“Rebuild completed
with attention needed”** when execution completed, or the actual failed/stopped
outcome, with evidence-backed ready/attention counts and **View Details**. Use Core
counts without conflating operation records with unique verified items or counting
unsupported twice. Technical details retain “Selected requirements verified,” gaps
and per-item evidence. Verification always runs in normal Restore; its UI becomes
prominent when attention is needed. Capture/Status likewise expose only relevant
outcomes by default. None of these states proves app runtime health, visual effects,
remote SSH authentication, agent/Keychain readiness or whole-Mac identity.

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
rebuild later.” Show “Stopping…” until owned-process termination.

**Current V1 constraint:** stopping sends the supported signal to Core, which
terminates owned process groups using SIGTERM and, if needed, SIGKILL. It can
interrupt an in-flight tool. There is no graceful stop-at-item-boundary request or
acknowledgement; Desktop must not claim it waits for an item to finish. Boundary-aware
stopping is desirable where practical but requires a separately scoped Core contract
change, not a UI workaround. “Safe Stop” means no rollback promise and fresh
re-inspection, not guaranteed atomic item completion or unchanged current work.
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

Use a small presentation catalog for domain/group labels, icons, action verbs,
status text and typed reason/prerequisite guidance. It translates Core identifiers;
it is not a second inventory, observer, readiness engine or domain state model.

| Generic UI input | Existing structured source |
|---|---|
| Categories and selection controls | Capture `inventory.domain/status/reason/selection_mode`; Restore selected groups/categories/counts |
| Items and labels | Capture `item_id/label`; Preview `domain/item_id`, optional repository `display_name`; opaque IDs get neutral labels |
| Actions and plan state | Preview `action/disposition/reason`, `has_planned_changes`, module summaries |
| Prerequisites | `readiness.conditions` domain/code/status and optional selected-item index; execution-launch bridge condition |
| Progress and operation outcome | Event type/sequence/phase, operation records, terminal code and publication/mutation flags |
| Verification and coverage | Core summary/verdict/counts and Verification/Coverage/Operation/Diagnostic records with actual detail status |
| Comparison | Summary, comparison records, support/reasons, extra-domain availability and extra items |

New items in an existing domain use the same rows and controls. New categories or
reason codes may need catalog entries, usually no bespoke screen. Unknown IDs use
safe generic labels; unknown enum values retain their code in Details and prevent
an unsupported success/action inference. Do not extract human labels from CLI logs.
Category-only settings stay category-only; no per-setting Capture control or
private-value editor is promised. `capabilities` advertises operations and version,
not a rich UI metadata registry. Existing fields suffice for this bounded UX.

**Protocol-fit assessment:** the flows above use only existing V1 operations,
structured results/events and the separate secret channel, without human stdout,
stderr or log parsing. No blocking Core/API gap was found for these flows using signal-based Stop Rebuild;
graceful item-boundary stopping is not provided, as specified above. Comparing
a Bundle directly is unavailable in current V1 and tracked as the required final
product reference above. Item-level Restore editing, decrypted identity selection
during Prepare and Desktop recovery remain outside the current contract. Any
extension needs a precise Core contract decision, not a client-side parser.

## Local logs and Diagnostic Report

Stage 16 includes local structured operation logs and user-requested support
reports. Logs record client receipt timestamp (distinct from Core `observed_at`),
Macseed/Core version, operation ID/type, event sequence/type, phase, safe domain/item
reference, warning/conflict/error code, prerequisite, Verification outcome and
cancellation/interruption. Client-only events are explicitly marked and do not
fabricate Core sequence numbers. Log partial operations and transport failures as
such. Core events do not supply every log field; client time/platform context fills
only client-owned metadata. No raw JSONL archive or arbitrary payload dumping.

Keep logs in defined private user-writable application storage with owner-only
permissions, bounded retention/rotation and a user-accessible Clear Logs action.
Log retention, storage placement and serialization limits must be fixed during
implementation. Operation Details is a readable projection of structured facts,
with technical codes behind disclosure. No raw stdout/stderr viewer is required.

**Create Diagnostic Report** is an explicit user action from Help or operation
Details. Build a sanitized snapshot containing Macseed/Core version, macOS
version/build, architecture, operation type/ID, selected-category counts, relevant
capabilities/prerequisites, sanitized event timeline, Verification/Comparison
summary, detail completeness and typed errors/reasons. Include interrupted-run
context without claiming completion. Missing context is marked unavailable.

Preview the complete export content, not just a summary. The native save action
writes exactly the reviewed immutable snapshot; any regeneration requires another
preview. Export a readable UTF-8 structured report with a report schema version.
The user may attach it to a GitHub Issue/support request. Desktop does not upload,
open a prefilled issue containing diagnostic data, send telemetry, integrate crash
reporting SaaS or submit background network requests.

### Privacy and sanitization boundary

Sanitize before persistence, Details rendering and report assembly. Use a typed
allowlist of fields and validated values, then a stricter export projection.
Operation IDs generated by Desktop contain no personal data. Replace private item
subjects with report-local aliases; omit public SSH fingerprints and key filenames
from exported support context. Treat labels/IDs as potentially personal even when
Core considers them display-safe. Export counts and stable domain/reason/action
codes rather than arbitrary user strings; unknown fields are dropped. Never rely
only on pattern-based replacement after dumping payloads.

Exclude passwords/passphrases, secret frames/challenge responses, private key
material, tokens/API keys, Git credentials, embedded URL credentials, environment
variables and tool output. Omit unnecessary personal filesystem paths, Bundle
names/destinations, usernames, repository names/remotes and setting contents.
Interactive views may show the user-selected Bundle location or safe Capture
labels when needed for the task; those values do not cross the persistent
log/report boundary. Platform context is limited to the stated OS/build/architecture;
no arbitrary machine inventory. Error text comes from typed codes and the
presentation catalog, never unsanitized exceptions or subprocess output.

Dedicated Stage 16 regression tests must cover secrets in nested/unknown fields,
credential-bearing URLs, paths, labels/IDs, malformed events, partial failures,
secure cancellation/timeouts and report regeneration. Assert absence in logs,
Details and reports, preservation of useful typed support context, and byte-for-byte
preview/export identity. Tests use disposable fixtures; never real keys or secrets.

## Implementation slices and qualification

| Slice | Deliverable |
|---|---|
| 16B — Native shell and design foundation | Native navigation, stable content states, small Settings, reusable rows, vocabulary, accessibility and empty states |
| 16C — Core process integration and capabilities | Core/Python layout, writable state/temp, controlled child HOME/PATH/environment, JSONL validation, process ownership and cancellation; structured sanitized logging foundation |
| 16D — Environment Status | Explicit reference picker, read-only Compare, summary and record details |
| 16E — Capture | Inventory/selection, fresh preparation, Bundle publication and interruption states; secure opt-in completed in 16H |
| 16F — Restore preparation | Bundle inspection, group selection, prerequisites, Check Again, Preview and fresh confirmation |
| 16G — Restore execution | Rebuild phases, records, Stop Rebuild over current signal cancellation, partial failure and re-entry |
| 16H — Secure SSH interactions | FD bridge/challenges, encryption/unlock/import confirmation and age/OpenSSH PTY qualification for Capture and Restore |
| 16I — Verification and completion | Concise Result with disclosed verdict/coverage, no-op, already-matching and incomplete outcomes |
| 16J — Diagnostics and support | Operation Details, retention/clear controls, Diagnostic Report preview/export and dedicated sanitization tests |
| 16K — Desktop integration hardening | Full flow/transport/security/accessibility checks, stale inputs, interruptions and diagnostic acceptance |

Every slice uses existing Core operations; early flow slices retain incomplete
features as unavailable rather than pretending secure or verification support.
Logging sanitization starts in 16C, before recording flow events; 16J completes the
support experience. Today's repository Core and external Python are not an
installed-app runtime. Stage 16 must qualify runtime and secure tool integration.

[Distribution](DISTRIBUTION.md) owns Stage 17 signed/notarized packaged clean-Mac
proof, including operation logs, interruption details and exact Diagnostic Report
preview/export privacy. [TODO](../TODO.md) owns unfinished implementation work.
Before **Macseed 1.0**, an Early Access/Alpha phase with approximately 10–20
technical external users will validate real Capture/Restore flows using voluntarily
shared privacy-safe reports/issues; resolve real compatibility and UX problems
before public launch. This is product validation, not another framework.
The mature toolkit/CLI history and current 3.4.0 Core/CLI version remain intact.
