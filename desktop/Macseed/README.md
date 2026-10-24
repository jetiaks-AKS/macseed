# Macseed Desktop foundation

Stage 16B provides the approved native SwiftUI design. Stage 16C adds the real
Protocol V1 process boundary and a capability check on normal launch. Stage 16D
connects real read-only Environment Status, manually approved. Stage 16E connects
real Capture with its end-to-end manual gate approved. Stage 16F implements real
Restore Prepare; its real-Bundle manual gate is approved. Stage 16G connects real
Restore Execute with its controlled mutation/Verification/idempotence gate approved.
DEBUG design preview retains deterministic Capture,
Restore and Status fixtures with an explicit sample notice; it launches no Core.
Capture reads supported state into private staging and can publish a new Saved
Environment. Restore inspection/Preview is read-only; execution is available
through Core after explicit confirmation. Secure migration remains unavailable until 16H.

## Build and launch

From the repository root, with Apple Command Line Tools and the macOS SDK:

```bash
./desktop/Macseed/build.sh Debug
open "$PWD/desktop/Macseed/build/Debug/Macseed.app"
```

This ordinary development build does not compile or run test executables. Use
`Debug --test` only for separately requested Desktop validation, as described below.
Before rebuilding, ensure this output app has no active operation; do not interrupt
Restore or overwrite an installed `/Applications` copy. Open the exact built path
without starting a second instance over active work. Normal launch performs only
the Core capabilities check; **Ready · Macseed Core** confirms that check, not any
Capture/Restore/Compare workflow.

For the approved sample UX, explicitly opt in on a new DEBUG instance:

```bash
open -n desktop/Macseed/build/Debug/Macseed.app --args --design-preview
```

Alternatively open `Macseed.xcodeproj` in Xcode, select the shared **Macseed**
scheme and Run (Debug). Add `--design-preview` to Run arguments only when reviewing
sample UI. With full Xcode installed:

```bash
xcodebuild -project desktop/Macseed/Macseed.xcodeproj -scheme Macseed \
  -configuration Debug -derivedDataPath desktop/Macseed/DerivedData build
open desktop/Macseed/DerivedData/Build/Products/Debug/Macseed.app
```

Local development output has no distribution signing; no signing/notarization
qualification is claimed. Minimum deployment target is macOS 14, matching the native APIs used.
Validation so far is macOS 26.7.1 / Apple Silicon with Swift 6.4 Command Line Tools;
macOS 14, Intel and the Xcode build path require separate qualification. Desktop
foundation version 0.1.0 is local development metadata, not a product release or
change to the Core/CLI 3.4.0 version.

## Inspect the design

In `--design-preview` mode, choose a primary task from Home or the sidebar. **Demo States** in the toolbar
loads deterministic states, including a secure sheet, prerequisites, progress,
stopped Restore, clean completion and attention result. Scanning advances with
**Show Sample Scan Results**. Rebuild advances only with **Next Sample Event**;
there is no timer-based installer animation or percentage estimate.

Capture Review supports selectable sample child items and native all/none/mixed
category checkboxes. Parent selection selects/deselects all children; checkbox
and label hit targets are separate from category disclosure. Title/arrow expands
the category. Counts reflect the selected child items. Secure SSH identities stay
separate and optional. This sample per-item granularity is broader than V1's
category-only domains; real Capture integration must honor the `selection_mode`
retained by the runtime model rather than send unsupported per-setting selections.
Create Bundle produces a sample result only. The secure sheet accepts UI-local
sample text, clears it on submission/dismissal, and passes no secret to the model.
Use no real secrets in the preview.

Restore uses sample Bundles A/B, never a real file picker or Swift Bundle parser.
Homebrew prerequisite guidance is inline; Check Again loads the available-tool
fixture. Restore group selection mirrors V1; item details are read-only. Excluding
Homebrew removes its prerequisite. Rebuild confirms the current sample Review.
Stop Rebuild uses a native alert, retains partial evidence and requires a fresh
Preview on re-entry. Choosing B after stopping A resets selection/preparation and
shows a compact notice; no cleanup is inferred. Verification is fixture evidence
in Result, with attention details disclosed on demand.

The toolbar Back action returns to the previous safe content state. It is disabled
during scanning, secure input and Rebuild. Back from a Restore result creates a
fresh Review, never resumes a progress cursor or old confirmation. Clean results
keep View Details collapsed; attention results show problem rows directly, with
technical reasons still collapsed.

Design-preview Status compares against a sample Generated Configuration reference, not a Bundle.
Settings keeps native Appearance and the shared Operation Logs history entry.
Operation Logs/Diagnostic Report consume persisted Runtime records, not demo
fixtures. No log-folder shortcut, updater or telemetry is implemented.
Normal macOS About is supplied by the application lifecycle.

## Structure and validation

For scoped development slices, run affected focused tests, the relevant Debug
build and `git diff --check` (plus syntax/lint when code requires it). Run canonical
`./scripts/test.sh` full regression at major checkpoints/releases or when broad
contracts require it, not mechanically after every small slice. Documentation-only
changes require consistency/link review and diff-check, not runtime tests or builds.
The canonical `Debug --test` command below runs all eight registered Desktop
suites sequentially: PresentationTests, DiagnosticReportTests, OperationLogViewTests,
OperationLogTests, CoreRuntimeTests, EnvironmentStatusTests, CaptureTests and
RestoreTests. Each executable is compiled once. Restore additionally runs its
existing final-UX and Assisted App Store flow subsets using that same executable;
the full Restore suite is not repeated.

Standard coverage includes Selection/Preview state, Assisted App Store navigation
and Refresh, requested/effective Capture scope and real Bundle publication,
Result/Verification projection and responsive status/column geometry at
420/785/985 points. Capture and Restore use `--no-renders` to omit their large
window/screenshot matrices; model/Core assertions still run, and the complete
PresentationTests suite retains bounded native layout assertions. Production Core
tests use disposable HOME/tools/Bundles, not real Capture/Rebuild or installations.
Native layout checks require a logged-in macOS GUI session.

- `Sources/Presentation.swift`: small shared display values, no domain algorithms.
- `Sources/ContentView.swift`: native reusable views and task content.
- `Sources/MacseedApp.swift`: app and Settings scenes.
- `Sources/SampleProvider.swift`: isolated deterministic fixtures, compiled only in DEBUG.
- `Sources/DemoSession.swift`: in-memory demo transitions, compiled only in DEBUG.
- `Tests/PresentationTests.swift`: executable focused assertions using real model transitions.
- `Info.plist`, `Macseed.xcodeproj`: native app target and shared scheme.
- `build.sh`: builds the same sources with the installed Apple SDK, without dependencies.

```bash
./desktop/Macseed/build.sh Debug --test
./desktop/Macseed/build.sh Release --test
```

For optional screenshots or performance investigation, run the already-built
harnesses from `desktop/Macseed`:

```bash
cd desktop/Macseed
./build/Debug/RestoreTests "$(cd ../.. && pwd -P)" "$(xcrun --find python3)" --preview-appstore-layout-only
./build/Debug/CaptureTests "$(cd ../.. && pwd -P)" "$(xcrun --find python3)"
./build/Debug/PresentationTests --preview-expansion-only
```

Existing focused flags remain available. Omitting `--no-renders` enables
Capture/Restore screenshots; `--stress` expands the optional Preview benchmark.
These specialized matrices and benchmarks are not required by the standard gate.

For the focused native checkbox test in a logged-in macOS GUI session, after the
Debug test build:

```bash
cd desktop/Macseed
./build/Debug/PresentationTests --native-controls
```

This checks actual NSButton mixed states/actions and checkbox/label hit bounds;
it does not perform end-to-end mouse automation of the full SwiftUI window.

Tests cover parent/child selection and counts, Back guards, result disclosure,
prerequisites, operation ownership, stopped A → fresh B,
result scope and fixture determinism. Release compilation excludes fixtures, demo
session, state picker and sample interaction views; it checks real Core capabilities
and uses real Capture, Restore Prepare and Environment Status. Restore execution requires an accepted prepared Preview and explicit confirmation; its controlled mutation/Verification/idempotence manual gate is approved. A binary string check guards accidental sample leakage.
The real runtime stays separate from DemoSession. Future task adapters map Core
facts into the existing presentation values; they must not turn DemoSession into
a production observer/planner/verification engine.

## Real runtime boundary (16C)

- `CoreProtocol.swift`: typed requests for all seven V1 operations, lossless JSON
  envelopes/open event vocabulary, capabilities and inventory selection metadata.
- `CoreLocation.swift`: explicit development/bundled descriptor resolution and
  controlled HOME/PATH/TMPDIR. Missing runtime is a typed error, never repo search
  or sample fallback. Known Homebrew tool locations are optional PATH entries,
  not application launch prerequisites; no installation is attempted.
- `CoreTransport.swift`: one POSIX-spawned owned process group/request, stdin EOF,
  separate stdout JSONL/stderr drains, sequence/lifecycle/exit validation and
  SIGTERM followed by bounded SIGKILL escalation. No human CLI parsing.
- `CoreRuntime.swift`: MainActor observable lifecycle, phase/events/result,
  publication/mutation evidence, exit and typed errors. Holds at most 256 history
  events (with a truncation flag); latest result stays available. JSONL limits are
  64 MiB per event and 256 MiB per operation, not Core's per-record limits.
- `OperationLog.swift`: typed privacy projection and private bounded Application
  Support journals, background append/read/retention, crash-tail handling and
  Runtime diagnostic availability. No raw Protocol or process-output archive.
- `OperationLogView.swift`: shared native viewer/history, bounded incremental All
  and Important projection; operation-specific View Log and Settings history access.
- `DiagnosticReport.swift`: independent export allowlist, background bounded report
  generation, immutable UTF-8 preview/copy/save and explicit refresh.
- `ProductionWorkspace.swift`: approved shell with real capability readiness,
  Capture/Status navigation, cancellation and typed error guidance.
- `CoreRuntimeTests.swift`: deterministic fake-child transport/lifecycle tests
  plus a read-only real Core capabilities smoke test in both configurations.
- `OperationLogTests.swift`: disposable storage/process fixtures for sanitization,
  permissions, caps, retention, crash/restart, Stop evidence and result independence.
- `OperationLogViewTests.swift`: selection/lifecycle, bounded full-history access,
  presentation and Runtime controls.
- `DiagnosticReportTests.swift`: privacy, exact UTF-8 bytes, immutable/refresh
  snapshots, partial/unavailable sources, save errors and bounded native preview.

`prepare-runtime.sh` is shared by local and Xcode builds. It generates a private
build resource `CoreRuntime.plist` with Version=1, Mode=development and explicit
absolute CoreRoot/PythonExecutable. Python is resolved by Apple's developer tools
at build time; launching the app does not invoke Homebrew or install anything.
Development builds need that checkout/runtime to remain available.
After a build, check `Macseed.app/Contents/Info.plist`, its executable and
`Contents/Resources/CoreRuntime.plist`: Mode must be `development`, CoreRoot must
be the selected checkout, and PythonExecutable must exist and be executable.
Core is referenced from that checkout, not embedded in the development app.

A future packaged resource descriptor uses Mode=bundled with relative CorePath
and PythonPath, confined to the resource directory including symlink resolution.
No final bundle layout or packaged Python composition is fixed here; Stage 17
must provide and qualify them. This does not assume system Python on a clean Mac.

**Current placement limit:** authoritative Core writes logs/private configuration
under its own root. Bundled signed resources cannot be used as a writable workflow
root. Capabilities/Bundle inspection can resolve there; other operations return
`writableCoreRequired`. A managed private writable Core workspace is required
before packaged workflow qualification. No files are copied into state or published
speculatively by this slice. Temporary operation directories are private and removed
after process termination. HOME is the actual user's home, not a replacement profile.

Events preserve unknown fields/types; invalid envelope/version, wrong operation
ID, non-increasing sequence, bad lifecycle/framing or inconsistent terminal exit
fails explicitly. Unknown events do not become completion. Stderr is drained and
tracked only as byte count/read error, never raw persisted/rendered output. Runtime
keeps a bounded structured in-memory buffer and records validated events through
the independent persistent Desktop Operation Log before eviction. Stage 16J
viewing/history and report export are implemented. Operation completion never
substitutes for Verification.

Cancellation signals the owned root group. Core owns its tool groups and handled
cleanup; forced termination cannot guarantee all separately owned descendants or
in-flight mutations are settled. Missing terminal evidence is interruption, not
rollback or confirmed no-change. Restore Graceful Stop now latches operation-wide,
finishes the active indivisible action/post-checks and stops admission at safe
checkpoints. Homebrew native-launch admission remains atomic. Force Stop is the
separate signal path; neither proves universal privileged quiescence or recovery.
Application Quit waits for cancellation; closing a window leaves the shared client
owned by the running app. Restore retains session ownership across window close/reopen; close/quit interaction
remains subject to Stage 16K lifecycle hardening.
Execute requests selecting secure identities fail before launch with
`secureBridgeUnavailable`; the separate inherited socket FD bridge remains 16H.

## Real Environment Status (16D)

Normal Debug and Release use **Choose Saved Environment…** to select a `.mbt`
file, display its name and require **Compare This Mac** explicitly. There are no
Generated Configuration/Blueprint controls in production Status. Compare uses the
additive Protocol V1 `bundle_path` request; older Core capability evidence produces
an explicit compatibility state. Core validates/stages the Bundle privately and
preserves its selected requirements and completeness evidence. Comparison remains
read-only, with no publication, Apply or secure decryption.

The process card shows indeterminate activity with Cancel left below it. Only Result
actions use the fixed footer; other actions remain beside their content. Results show
Match, Different and Missing cards, with Not Applicable shown only when nonzero,
and collapsed category/item lists with concise explanations. Technical evidence opens
through the existing Operation Log.
Compare Again creates a fresh request; choosing another Bundle clears the old
result. Failure, cancellation, interruption and incomplete evidence cannot preserve
a clean prior result. Competing operations and navigation remain disabled during
comparison. No Discovery is run.

With no Status reference, entering Status offers the current Restore session's
Bundle without automatic comparison; Core revalidates it when Compare is chosen.
References remain session-local. Stage 16K Bundle-backed Environment Status is
accepted after real-Mac GUI qualification; runtime/distribution hardening remains
separate unfinished work. The subsequent **Review in Restore** handoff is implemented
and manually approved as a separate change. Its visibility, session protection and
inspection-only behavior are specified in the [Bundle handoff contract](../../docs/DESKTOP.md#bundle-handoff).

`CoreComparison.swift` decodes V1 comparison/Coverage/diagnostic/extra evidence.
`EnvironmentStatusModel.swift` projects only a completed, validated result into
existing generic display values, preserving the Core verdict and distinct states.
It rejects incomplete/contradictory payloads and mutation/publication claims.
`EnvironmentStatusView.swift` reuses approved category/item/technical disclosures;
collapsed groups retain warning indicators. Zero-count summary entries are omitted.
Unsupported and unknown differences remain subsets of unverified. Excluded and
no-requirement Coverage are not reported as matching. Private opaque IDs use a
neutral item label, not a recovered private name.

Extras require Core `available` evidence for casks/App Store/VS Code extensions
with consistent per-domain counts/items. Missing provenance remains **Unavailable**
in details, never a proven zero; extra items do not imply removal. Comparison is
read-only and neither installs nor repairs anything.

`EnvironmentStatusTests.swift` covers projection/error/refresh behavior, Debug
sample isolation and the Swift → real Core → Status path with disposable reference,
HOME and reader fixtures. Mutation sentinels and reference/HOME snapshots protect
the automated boundary. The user-run Stage 16D manual gate was approved.
Automated fixtures do not replace
the real-Mac manual gates.

After the Debug build, the single command from the repository root for the manual
gate against real Core is:

```bash
open -n desktop/Macseed/build/Debug/Macseed.app
```

Choose **Environment Status**, select a Saved Environment `.mbt`, then
**Compare This Mac**. No `--design-preview` argument is used.

## Real Capture (16E)

Normal Debug/Release: **Scan this Mac → Review and select → Choose Destination…
→ fresh preparation → inline confirmation → Create Saved Environment → Environment
Saved**. Scan and preparation read this Mac into private Core staging without
replacing ordinary local Generated Configuration/Blueprint. There is no Homebrew
installation prerequisite for Capture. Only Core inventory drives selection.

`CoreCapture.swift` decodes prepare/publication evidence. `CaptureModel.swift`
owns content state, selected scope and the exact preparation binding. `CaptureView.swift`
reuses native checkboxes and collapsed categories/details. `items` mode uses item
subsets, all/none/mixed and bulk actions; `category` mode sends a whole domain with
no per-setting controls. Unknown modes and non-present state cannot be selected.
Selection counts distinguish areas from items. macOS Settings groups six real
domains; read-only included-settings labels add no selectable items. Private SSH identities
are explicitly unavailable here and always excluded (`secure_identities: []`).

The native save panel chooses a new file; Desktop normalizes its name to one
`.mbt` suffix. Review owns the live selection cards; compact inline confirmation
shows the destination, wrapping read-only content and independent warnings, with
Back returning to detailed Review. Existing output requires explicit Replace in
the native Save Panel, with digest-bound validation before atomic replacement.
Core owns canonical/user-owned parent validation and rechecks
destination/publication. Execute uses the selected preparation's ID and rescans;
stale rejection needs a fresh scan/review/confirmation, with no silent retry.

Activity shows real phase messages without numeric domain counts or percentages;
Core observation events remain internal. Only completed
publication with consistent Core destination/binding/Bundle metadata yields
**Environment Saved** and **Reveal in Finder**. Result cards use published domain/item
counts; Needs Attention counts captured Core domains with event warnings. The
Captured Environment list uses Completed/Needs Attention/Unverified according to
available inclusion evidence. Core event warnings stay visible.
Cancellation/failure after reported publication retains that fact/location without
claiming success; missing evidence is unknown, not cleanup/rollback. Forced process
termination retains the 16C descendant/private-staging limitations.

`CaptureTests.swift` covers selection modes/counts, fresh preparation/destination,
confirmation, publication/warnings, stale/failure/interruption/cancel and no sample
fallback. A disposable HOME/tools fixture exercises real Capture, a private `.mbt`,
authoritative Bundle inspection, real stale rejection and category-only saving
without Homebrew, while checking unchanged HOME and ordinary configuration. It
does not perform the real-Mac manual gate. The user has approved that end-to-end
gate, including real publication, warnings and Reveal in Finder.

After the Debug build, launch normal development mode from the repository root:

```bash
open -n desktop/Macseed/build/Debug/Macseed.app
```

Choose **Capture this Mac** for the manual gate. Use no `--design-preview` argument.

The canonical [Desktop contract](../../docs/DESKTOP.md#required-final-product-reference-before-macseed-10)
owns Bundle-backed Environment Status, now completed separately in Stage 16K.
The historical Capture slice did not implement Bundle comparison or change V1.
Restore, secure transfer, diagnostic export and packaged-runtime qualification
were separate slices.

## Real Restore Prepare (16F)

Normal launch uses **Choose Saved Environment… → real inspection → selection →
Preview → Ready to Rebuild / Needs Attention**. Core must advertise fine Restore
selection; old runtimes show compatibility guidance. Group membership, labels,
modes, eligibility and stable item IDs come from Core inventory. The macOS parent
uses advertised group children; item domains support independent whole/subset
selection. No preference-key or private identity selection is offered.

Each Preview/Check Again performs fresh `restore_prepare` with the current source
and selection, `disabled_groups: []`, `include_secure: false`. Structured plan rows
correlate via `selection_item_id`; readiness distinguishes satisfied, safely
satisfiable, external and unsupported conditions. Selection/Bundle/Back changes
invalidate the plan; failed/cancelled/interrupted refreshes clear old evidence.
The displayed plan retains its exact ID and canonical selection.

Stage 16G enables Rebuild for ready plans with real changes after confirmation.
Execute uses Core; Safe Stop preserves possible changes and requires fresh Preview.
Private identity imports remain unavailable. Native sheets inherit the application Appearance. The
manual gate passed with a real Stage 16E Saved Environment; tests use disposable
fixtures, including production Core inspection/Preview with unchanged Bundle,
HOME and normal configuration. Run `RestoreTests` through `build.sh Debug --test`.

Stage 16G's controlled manual gate passed: one disposable Workspace folder was
created, externally confirmed and Core-verified. A fresh Preview then showed
Already Matches, zero changes and disabled Rebuild. Secure SSH remains Stage 16H.

### Branding assets

`Sources/Branding.swift` owns the shared leaf silhouette and Home hero. To refresh
all committed AppIcon PNG variants and `Resources/Macseed.icns`, run
`./generate-app-icon.sh` from this directory, then rebuild. Both build paths use
the static ICNS resource, also applied to the running app at launch. The system
leaf is 22% larger; Hero/sidebar keep their approved scale. Home shares a centered
1080 pt container for its hero and three tiles; Settings is pinned below navigation.
Quit and reopen the app if macOS shows a cached Dock icon.

### Restore Selection presentation

Inspection reports `source_present` and Blueprint-derived `capture_selected`.
Selection hides explicit absence/exclusion, including inventory-only domains,
while retaining whole selected categories, real limitations and unknown evidence.
Draft selection and execution remain Core-owned. Preview cards follow Already
Match → Changes Planned → Need Attention; detailed item rows are unchanged.

## Performance diagnostics

Core optimization and opt-in aggregate Performance Trace are implemented through
`c06e530`. Desktop's minimal child environment forwards only the two explicit
trace variables when enabled; Core still validates the private output directory.
See [trace activation and limits](../../docs/core/APPLICATION-INTERFACE.md#opt-in-restore-performance-trace)
and [real-Mac observations](../../docs/DESKTOP.md#recent-restore-qualification-and-performance).
The trace is off by default, outside Protocol V1 and Diagnostic Report, and contains
no private item identifiers. It does not establish restoration success.

## Next functional priorities and deferred tooling

The Minimal Premium leaf logo/App Icon, Home, Sidebar, Settings and adaptive tiles
are approved. Capture was checked on a real Mac; Restore Selection, Preview,
Progress and Result are approved. Stage 16 remains open.

Bundle-backed Environment Status is implemented and accepted after real-Mac GUI
qualification, using the existing read-only comparison engine. Capture saves,
Restore rebuilds from, and Status compares against a Saved Environment (`.mbt`);
the Restored Bundle is a natural reference. Preserve source selection/Blueprint,
unknown evidence and Bundle format; no SwiftUI Bundle parser. Minimal Protocol V1
extensions require audit, not assumptions about current API support.

Stage 16J Logging & Diagnostics is complete. Settings →
Operation Logs opens the shared native window; local View Log selects the matching
completed operation in Capture Review/confirmation/Result, Restore Selection/Preview/Result
and Environment Status, including failures. No local link opens a previous Rebuild
from Preview; active operations remain accessible through Settings history.
Important shows compact deduplicated issues; All reaches every saved event through
bounded pages beyond the 512-record visible window. Process Result, Verification
and Log completeness remain independent; incomplete successful logs are neutral.

Private Application Support journals use 0700 directories / 0600 files, with
8 MiB per operation, 16 KiB records, 100 operations, 64 MiB total and 30-day
retention. Clear Logs preserves active and unrelated files. Reports use an
independent strict allowlist and one immutable UTF-8 snapshot for Preview, Copy
and Save; only explicit Refresh replaces it. Reading/formatting is off MainActor,
report text is bounded to 256 KiB and native TextKit owns scrolling. Core technical
logs stay independent; reports contain no raw Protocol/process output or private
object identities. See the [logging contract](../../docs/DESKTOP.md#local-logs-and-diagnostic-report).

Local DiagnosticReportTests, related viewer tests, full PresentationTests and a
Debug build passed; the native 6000-record report fixture stayed bounded and
responsive. Operation Logs UX was manually accepted. Report Save panel interaction
and user-driven scrolling still need manual checks; no signed/clean-Mac or hosted
CI success is claimed. Final Restore Result categories/disclosures and confirmed
Successful / Needs Attention / Skipped cards are implemented and manually accepted;
Verified evidence is distinct from Applied, and Process Result from Verification.
Controlled Early Cancelled/Partial Stopped checks are accepted. These do not close
all 16I/16K qualification, Stage 3C or native installer quiescence. The accepted
D1–D4/R5 baseline and next checkpoints are recorded in the authoritative
[Roadmap](../../ROADMAP.md#current-practical-execution-order): closure documentation
and the current development build/launch are complete; Desktop CI comes next,
before Workspace/Worktrees, Secure SSH and remaining Restore qualification.
Assisted App Store Restore is an accepted
development milestone, with manual installation and fresh Core verification;
automatic MAS development is archived on `archive/mas-automatic-restore-v4`.

The full Debug Scenario Catalog is deferred UI/dev tooling, not cancelled. Retain
Debug design-preview, sample fixtures and DemoSession; a small Lite catalog over
production models/views may follow functional priorities. Focused fixtures/tests
need not wait for it. Follow [Roadmap](../../ROADMAP.md#current-practical-execution-order)
for the remaining functional, Secure SSH, reliability and distribution priorities.
