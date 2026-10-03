# Macseed Desktop foundation

Stage 16B provides the approved native SwiftUI design. Stage 16C adds the real
Protocol V1 process boundary and a capability check on normal launch. Real task
flows are not connected yet. DEBUG design preview retains deterministic Capture,
Restore and Status fixtures with an explicit sample notice; it launches no Core.
No Discovery, Bundle creation, Restore or secure migration is run by this shell.

## Build and launch

From the repository root, with Apple Command Line Tools and the macOS SDK:

```bash
./desktop/Macseed/build.sh Debug --test
open desktop/Macseed/build/Debug/Macseed.app
```

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

Status compares against a sample Generated Configuration reference, not a Bundle.
Settings has only informative General and Privacy / Diagnostics tabs. No decorative
preferences, log folder, report export, updater or telemetry are implemented.
Normal macOS About is supplied by the application lifecycle.

## Structure and validation

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

For the focused native checkbox test in a logged-in macOS GUI session, after the
Debug test build:

```bash
desktop/Macseed/build/Debug/PresentationTests --native-controls
```

This checks actual NSButton mixed states/actions and checkbox/label hit bounds;
it does not perform end-to-end mouse automation of the full SwiftUI window.

Tests cover parent/child selection and counts, Back guards, result disclosure,
prerequisites, operation ownership, stopped A → fresh B,
result scope and fixture determinism. Release compilation excludes fixtures, demo
session, state picker and sample interaction views; it checks real Core capabilities
and leaves task flows explicitly unavailable. A binary string check guards accidental sample leakage.
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
- `ProductionWorkspace.swift`: approved shell with real capability readiness,
  cancellation and typed error guidance. Real task screens remain unavailable.
- `CoreRuntimeTests.swift`: deterministic fake-child transport/lifecycle tests
  plus a read-only real Core capabilities smoke test in both configurations.

`prepare-runtime.sh` is shared by local and Xcode builds. It generates a private
build resource `CoreRuntime.plist` with Version=1, Mode=development and explicit
absolute CoreRoot/PythonExecutable. Python is resolved by Apple's developer tools
at build time; launching the app does not invoke Homebrew or install anything.
Development builds need that checkout/runtime to remain available.

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
keeps structured events in memory only; logging/report sanitization and export
remain 16J. Operation completion never substitutes for Verification.

Cancellation signals the owned root group. Core owns its tool groups and handled
cleanup; forced termination cannot guarantee all separately owned descendants or
in-flight mutations are settled. Missing terminal evidence is interruption, not
rollback or confirmed no-change. There is no cooperative item-boundary stop.
Application Quit waits for cancellation; closing a window leaves the shared client
owned by the running app. Real workflow close/quit UX must be qualified with 16G.
Execute requests selecting secure identities fail before launch with
`secureBridgeUnavailable`; the separate inherited socket FD bridge remains 16H.

The canonical product contract is [Desktop](../../docs/DESKTOP.md). Stage 16D adds
real Environment Status reference selection and structured comparison projection;
Capture/Restore, secure migration and diagnostics remain their later slices.
