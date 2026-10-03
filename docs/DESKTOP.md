# Macseed Desktop

**Stage 16A — product and UX contract defined; implementation planned.**
`Macseed.app` and its Swift/SwiftUI implementation do not exist yet. Macseed is
one product with a shared Core and two official frontends: CLI (`bs`) and Desktop.
The official CLI remains supported. **Simple by default. Detailed on demand.**

This document owns Desktop presentation and interaction. The implemented
[Protocol V1](core/APPLICATION-INTERFACE.md) owns transport, operation semantics,
selection, prerequisites, records and secret input. Desktop consumes those facts;
it does not recreate Discovery, Preview, Capture, Restore or Verification in Swift.

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

Each flow has a step indicator, one primary next action and Back where safe.
Review screens show category summaries first, expandable item rows and Details.
Keep only one Core operation active per application instance; disable competing
starts and offer return to the active operation. Navigating away must not silently
cancel or detach it. Closing during work offers Keep Working or Cancel Operation;
wait for owned-process termination before closing. No background daemon or
persistent resumable job is introduced.

## Capture this Mac

**Scan → Review → Secure Items → Create Bundle → Done**

1. Scan calls `capture_prepare` with `selection: null`. Show an indeterminate
   scan with observed categories as Core reports them. Scanning stages private
   inventory; it does not replace ordinary Generated Configuration.
2. Review renders inventory status and `selection_mode`. Initially select all
   present ordinary categories/items, visibly; unavailable, observation-error and
   unsupported rows remain unselected with reasons. The user can narrow whole
   categories or item subsets where Core permits. No hidden selection or overlap
   between a whole category and its subset. An empty selection keeps Create Bundle
   disabled with “Choose supported state to capture.”
3. Secure Items is explicit opt-in and defaults off. Show eligible safe key names,
   types and public fingerprints, distinguish SSH configuration from private
   identities, and explain that ordinary Bundle settings are private but unencrypted.
   Keys travel in a separately encrypted component. Preparation does not unlock
   them or prove their pairs; unavailable secure tools show guidance or allow
   continuing without identities.
4. Prepare the chosen selection again. Show canonical selection/counts and a
   native save dialog for a new `.mbt` file. Confirm **Create Bundle** using that
   preparation's ID. Execute rescans; changed inventory requires fresh Review and
   confirmation. Never overwrite an existing Bundle; choose another destination.
5. Done says **Bundle Created** only with successful publication evidence. Show
   selected scope and the chosen location, with Reveal in Finder. Capture does not
   claim target restoration or final Verification. If cancellation/failure follows
   publication, say a Bundle was created and retain its location alongside the
   interruption; do not label it an unpublished failure.

## Restore a Mac

**Open Bundle → Inspect → Review → Prerequisites → Preview → Rebuild → Verify → Done**

1. Open uses a native `.mbt` picker; `bundle_inspect` validates and returns format,
   categories/counts and encrypted-component presence. Invalid/unavailable or
   unsupported Bundles show **Can't Restore**, a typed explanation and Choose
   Another Bundle. Inspection does not promise readiness or expose private values.
2. Review allows disabling the authoritative groups: Applications, VS Code
   Settings, Homebrew, macOS Settings, Shell, Git, SSH Configuration and Workspace.
   Included ordinary groups default on; secure import defaults off, even when
   present. Groups can be narrowed, never expanded beyond Bundle content. Item
   details are informational: Protocol V1 does not allow item-level Restore edits.
3. `restore_prepare` supplies both prerequisites and Preview. The displayed steps
   organize that one result; they are not separate domain checks implemented in
   Desktop. Selection changes invalidate the displayed preparation and confirmation.
4. Prerequisites shows selected-work conditions, practical guidance and
   **Check Again**. Recheck calls fresh Prepare with the same current inputs,
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
7. Rebuild shows actual structured phases and records; Verify presents Core's
   evidence, then Done presents completion and remaining attention items.

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

**Inspect → Compare → Summary → Details**

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

## Status vocabulary and evidence

Use this small shared vocabulary, with flow-specific titles such as Bundle Created,
Working, Cancelled or Interrupted when appropriate. Presentation does not change
Core status, verdict precedence or operation exits.

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
Final Verification says “Selected requirements verified” and exposes gaps and
per-item evidence. It does not prove app runtime health, visual preference effects,
remote SSH authentication, agent/Keychain readiness or whole-Mac identity.

## Progress, cancellation and re-entry

Use indeterminate progress plus named phases and the latest safe category/item.
Render `phase_started`, `phase_completed`, Capture/secure events and Restore
`execution_event`/record events. Completed-phase markers do not imply a percentage;
there is no reliable total-work estimate. Prepare/Inspect may expose only start and
result: show “Checking…” without fabricated substeps. Keep Details collapsible.

Cancel sends the supported signal to the owned Core process; secret dialogs can
send the secret-channel cancellation response. Show “Cancelling…” until termination.
Handle Capture/Restore `failed` cancellation codes and Compare's `cancelled` event.
A result is provisional until the terminal event; missing terminal event, invalid
transport or unexpected exit is Interrupted, never successful completion.

On failure/cancellation show available publication and possible-target-mutation
facts. After mutation may have started, say changes may remain; there is no rollback
promise. If a process dies before facts arrive, effects are unknown. Re-entry means
fresh inspection/preparation and confirmation, not Resume. Preserve safe local
operation details for support; remembered input paths require revalidation.
`recovery_required` directs users to existing CLI Restore recovery; Desktop must
not silently recover publication state. After prerequisite resolution use Check
Again, and after stale plans return to Review/Preview. These routes retain user
choices only as draft inputs, never as continuing authorization.

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
stderr or log parsing. No blocking Core/API gap was found for this scope. Comparing
a Bundle directly, item-level Restore editing, decrypted identity selection during
Prepare and Desktop recovery are unavailable and are deliberately outside the
first Desktop contract. A future requirement for any of them needs a precise Core
contract decision, not a client-side Bundle parser or speculative workaround.

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
| 16B — Native shell and design foundation | Navigation, step layout, reusable rows, vocabulary, accessibility and empty states |
| 16C — Core process integration and capabilities | Core/Python layout, writable state/temp, controlled child HOME/PATH/environment, JSONL validation, process ownership and cancellation; structured sanitized logging foundation |
| 16D — Environment Status | Explicit reference picker, read-only Compare, summary and record details |
| 16E — Capture | Inventory/selection, fresh preparation, Bundle publication and interruption states; secure opt-in completed in 16H |
| 16F — Restore preparation | Bundle inspection, group selection, prerequisites, Check Again, Preview and fresh confirmation |
| 16G — Restore execution | Rebuild phases, records, cancellation, partial failure and re-entry |
| 16H — Secure SSH interactions | FD bridge/challenges, encryption/unlock/import confirmation and age/OpenSSH PTY qualification for Capture and Restore |
| 16I — Verification and completion | Verdict/coverage presentation, no-op, already-matching and incomplete outcomes |
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
