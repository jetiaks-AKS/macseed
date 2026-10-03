# Macseed Desktop foundation

Stage 16B is a native SwiftUI design preview, not a Core client yet. Debug supports
interactive Capture, Restore and Environment Status using deterministic fixtures.
The permanent sample notice is intentional. No Core processes, file inspection,
Bundle creation, installs, settings changes or secure migration occur.

## Build and launch

From the repository root, with Apple Command Line Tools and the macOS SDK:

```bash
./desktop/Macseed/build.sh Debug --test
open desktop/Macseed/build/Debug/Macseed.app
```

Alternatively open `Macseed.xcodeproj` in Xcode, select the shared **Macseed**
scheme and Run (Debug). With full Xcode installed:

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

Choose a primary task from Home or the sidebar. **Demo States** in the toolbar
loads deterministic states, including a secure sheet, prerequisites, progress,
stopped Restore, clean completion and attention result. Scanning advances with
**Show Sample Scan Results**. Rebuild advances only with **Next Sample Event**;
there is no timer-based installer animation or percentage estimate.

Capture Review supports selectable sample child items and native all/none/mixed
category checkboxes. Parent selection selects/deselects all children; checkbox
and label hit targets are separate from category disclosure. Title/arrow expands
the category. Counts reflect the selected child items. Secure SSH identities stay
separate and optional. This sample per-item granularity is broader than V1's
category-only domains; Stage 16C must honor actual Core `selection_mode` rather than
send unsupported per-setting selections.
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
session, state picker and sample interaction views; it shows a clear unavailable
Core-integration state. A binary string check guards accidental sample leakage.
A future Protocol adapter must feed presentation facts and own production lifecycle;
it must not turn DemoSession into a production observer/planner/verification engine.
Close/quit handling for real owned child processes remains Stage 16C work.

The canonical product contract is [Desktop](../../docs/DESKTOP.md). Core transport,
real workflows, secure migration, logging and report export remain later slices.
