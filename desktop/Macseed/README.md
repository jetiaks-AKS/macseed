# Macseed Desktop development

Native SwiftUI Desktop consumes Core/CLI 3.4.0 through Protocol V1. Normal Debug
and Release run real capabilities, Capture, Restore and Environment Status.
Explicit DEBUG design-preview uses samples and launches no Core.
[Desktop](../../docs/DESKTOP.md) owns UX, runtime and safety contracts;
[Roadmap](../../ROADMAP.md#current-practical-execution-order) owns implementation order.
Desktop CI is complete at `411cd712` / CI #108; distribution remains unqualified.

## Requirements

- macOS with Apple Command Line Tools or full Xcode, the macOS SDK, `xcrun`,
  Swift compiler and Xcode-resolved Python 3.
- A retained Macseed checkout for the development Core runtime. Homebrew/tools
  are prerequisites only for selected Core work, not universal app-launch requirements.
- A logged-in macOS GUI/WindowServer session for native layout and interaction
  assertions; a headless/sandbox-limited result does not establish native behavior.

Recorded tested toolchains are the local macOS 26.7.1 / Apple Silicon / Swift 6.4
Command Line Tools baseline and CI #109's Xcode 26.6 / Swift 6.3.3 / Python 3.9.6.
These are validation results, not minimum compiler requirements. Compatibility
with older Swift 5.2.4 is **not established**; no minimum supported Swift compiler
has been qualified. `-swift-version 5` selects a language mode, not Swift 5.2.4
compiler compatibility.

CI explicitly checks Python 3.9+. Development builds resolve `python3` with `xcrun`;
the Desktop runtime validates its name and executable path, without a numeric
version check. The CI threshold does not establish a production runtime minimum.
Packaged Python compatibility remains a Stage 17 qualification gate.

Deployment target is macOS 14; macOS 14, Intel and the Xcode project build path
need separate qualification. Development metadata `0.1.0` is not a product release
or a change to Core/CLI 3.4.0. Neither configuration establishes signed/notarized
distribution qualification.

## Build and launch

Run from the repository root:

```bash
./desktop/Macseed/build.sh Debug
open "$PWD/desktop/Macseed/build/Debug/Macseed.app"
```

An ordinary build does not compile or run tests. Release uses the same sources:

```bash
./desktop/Macseed/build.sh Release
open "$PWD/desktop/Macseed/build/Release/Macseed.app"
```

Before rebuilding, ensure the output app has no active operation. Open that exact
path without creating another instance over active work; do not interrupt Restore
or overwrite an installed `/Applications` copy. Normal launch only checks Core
capabilities: **Ready · Macseed Core** does not run or qualify Capture/Restore/Compare.
Choose workflows explicitly; real Capture publishes a Bundle and real Rebuild can
mutate the Mac. Manual gates require appropriate scope/side-effect authorization.

Alternatively open `Macseed.xcodeproj`, select the shared **Macseed** scheme and
Run (Debug). With full Xcode, the equivalent build is:

```bash
xcodebuild -project desktop/Macseed/Macseed.xcodeproj -scheme Macseed \
  -configuration Debug -derivedDataPath desktop/Macseed/DerivedData build
open desktop/Macseed/DerivedData/Build/Products/Debug/Macseed.app
```

Build products, module caches and optional render fixtures remain in ignored
`build/` / `DerivedData/`. These are development outputs, not distributable artifacts.

## Runtime preparation

Both build paths invoke `prepare-runtime.sh RESOURCE_DIRECTORY`. It resolves the
checkout and Python using `xcrun --find python3`, then generates
`Contents/Resources/CoreRuntime.plist` with Version=1, Mode=development and absolute
CoreRoot/PythonExecutable. Launch does not search for a checkout, install tools or
fall back to samples. Rebuild if the checkout/runtime path moves.

After building, inspect the app's Info.plist, executable and runtime descriptor:

```bash
plutil -p desktop/Macseed/build/Debug/Macseed.app/Contents/Info.plist
plutil -p desktop/Macseed/build/Debug/Macseed.app/Contents/Resources/CoreRuntime.plist
```

Mode must be `development`, CoreRoot the intended checkout and PythonExecutable
an existing executable. Core is referenced, not embedded. The child uses the real
user HOME with controlled PATH/environment and private temporary operation state.
Core-only changes in that checkout do not need a Swift rebuild; descriptor/resource
changes do. Missing runtime/protocol failure stays explicit.

A future bundled descriptor uses relative CorePath/PythonPath confined to resources.
Current Core logs/configuration need a private writable workflow workspace; signed
resources cannot serve as that root. Bundled workflow resolution rejects writes
with `writableCoreRequired`. Secure Execute currently fails before launch with
`secureBridgeUnavailable`; the inherited socket bridge remains Stage 16H.
[Desktop runtime](../../docs/DESKTOP.md#implemented-runtime-boundary) owns behavior,
and [Distribution](../../docs/DISTRIBUTION.md) owns packaged runtime qualification.

## Canonical validation

Use the existing entrypoint for an authorized Desktop validation checkpoint:

```bash
./desktop/Macseed/build.sh Debug --test
# When Release validation is required:
./desktop/Macseed/build.sh Release --test
```

`build.sh` is the single inventory owner. It compiles each executable once and runs
these eight suites sequentially:

1. PresentationTests
2. DiagnosticReportTests
3. OperationLogViewTests
4. OperationLogTests
5. CoreRuntimeTests
6. EnvironmentStatusTests
7. CaptureTests
8. RestoreTests

The same Restore executable also runs `--final-restore-ux-only` and
`--assisted-appstore-only`; it does not repeat the full suite. Capture/Restore use
`--no-renders`, omitting large screenshot matrices while retaining model/Core
assertions. Full PresentationTests retains bounded native layout assertions,
including responsive 420/785/985 pt coverage. Release additionally checks sample
exclusion. Core-backed fixtures use disposable HOME/tools/Bundles; they do not
qualify real installations or replace manual/clean-Mac gates.

`MACSEED_DESKTOP_SUMMARY` optionally selects the safe Markdown summary destination:
stage labels, passed/failed/not-run, exit and elapsed time, with compilation separate
from execution. Assertion counts are unknown. Hosted configuration, mandatory
fail-closed `validate`, privacy and timing evidence are in
[Contributing](../../CONTRIBUTING.md#focused-feedback-and-ci).

Run affected focused harnesses first. Production presentation/state changes include
both feature tests and PresentationTests; full canonical validation belongs at
implementation checkpoint closure. Repository regression and Desktop validation
run sequentially on one local machine because temporary-state observations overlap.
Documentation-only changes use consistency/link review and `git diff --check`,
without builds, syntax checks or runtime tests.

## Focused Desktop tests

Run already-built harnesses from **desktop/Macseed**: PresentationTests uses
relative paths. Build the matching configuration first if sources have changed.

```bash
cd desktop/Macseed
./build/Debug/PresentationTests --workflow-layout-only
./build/Debug/PresentationTests --workflow-scroll-only
./build/Debug/PresentationTests --workflow-controls-only
./build/Debug/PresentationTests --native-controls
./build/Debug/PresentationTests --preview-expansion-only
```

| Selector | Purpose / limits |
|---|---|
| `--workflow-layout-only` | Aggregation, recursive disclosure, count geometry and native viewports; six representative PNGs under ignored `build/Debug/` |
| `--workflow-scroll-only` | ProductionWorkspace with disposable Protocol fixture; result arrival, native wheel to bottom/back, disclosure and changed Compare Again at 1000 × 700 and 1200 × 800 |
| `--workflow-controls-only` | Leaf indicators, native selection controls, log visibility, status alignment and recursive macOS disclosure |
| `--native-controls` | Actual NSButton mixed states/actions and checkbox/label bounds; not full-window mouse automation |
| `--preview-expansion-only` | Bounded Preview expansion probe; `--stress` expands the optional benchmark |

Native tests need WindowServer access. The selectors use fixtures, not real Core
workflows. For optional Capture/Restore rendering, omit `--no-renders`:

```bash
# Still in desktop/Macseed:
./build/Debug/RestoreTests "$(cd ../.. && pwd -P)" "$(xcrun --find python3)" --preview-appstore-layout-only
./build/Debug/CaptureTests "$(cd ../.. && pwd -P)" "$(xcrun --find python3)"
```

These optional render/stress matrices are not additions to the standard gate.
Use the existing selectors; do not create a parallel test runner/inventory.

## Inspect the design

Start a separate DEBUG sample instance only when no active real work conflicts:

```bash
open -n desktop/Macseed/build/Debug/Macseed.app --args --design-preview
```

In Xcode, use that Run argument only for sample review. **Demo States** loads
stable states, including secure sheet, prerequisites, progress, stopped Restore,
clean/attention results. Advance Scan with **Show Sample Scan Results** and Rebuild
with **Next Sample Event**; there are no installer timers/estimated percentages.
Sample Bundles A/B do not use a real picker/parser. Sample selection can be more
fine-grained than V1 category-only domains; never promote it into production scope.

Use no real secrets. Secure-sheet text stays UI-local and clears on submission or
dismissal. Back is disabled during scanning, secure input and Rebuild; return from
a result requires a fresh review. Demo Status uses a sample Generated Configuration
reference. Logs/reports consume persisted Runtime records, not demo fixtures.
Release excludes SampleProvider, DemoSession, picker and sample interaction views;
Runtime and DemoSession must remain separate. The full Scenario Catalog is deferred.

## Source map and contract owners

| Files under `Sources/` | Responsibility / authoritative behavior |
|---|---|
| `MacseedApp.swift`, `ContentView.swift`, `ProductionWorkspace.swift` | Scenes, reusable shell, real runtime/task ownership |
| `Presentation.swift`, `TaskComponents.swift`, `Branding.swift` | Shared display values, rows/count/disclosure geometry and identity; no domain algorithms |
| `CoreProtocol.swift`, `CoreLocation.swift`, `CoreTransport.swift`, `CoreRuntime.swift` | Requests, runtime resolution, owned process/JSONL boundary and observable lifecycle |
| `CoreCapture.swift`, `CaptureModel.swift`, `CaptureView.swift` | [Capture](../../docs/DESKTOP.md#capture-this-mac) mapping, state and presentation |
| `CoreRestore*.swift`, `Restore*.swift` | [Restore](../../docs/DESKTOP.md#restore-a-mac), fresh-plan selection, progress and evidence-based Result |
| `CoreComparison.swift`, `EnvironmentStatusModel.swift`, `EnvironmentStatusView.swift` | [Environment Status](../../docs/DESKTOP.md#environment-status), explicit reference and validated projections |
| `OperationLog.swift`, `OperationLogView.swift`, `DiagnosticReport.swift` | [Logs, storage/privacy and reports](../../docs/DESKTOP.md#local-logs-and-diagnostic-report) |
| `SampleProvider.swift`, `DemoSession.swift` | DEBUG-only fixtures/transitions |

`Tests/` contains executable harnesses; `Info.plist` and `Macseed.xcodeproj` own app
target metadata/shared scheme. `build.sh` compiles the same sources with Apple's
SDK without third-party build dependencies. Shared UI and truthful result rules
belong to [Desktop](../../docs/DESKTOP.md#workflow-layout-and-disclosure), exact
transport/operation contracts to [Core](../../docs/core/APPLICATION-INTERFACE.md).

## Branding assets

`Branding.swift` owns the shared leaf/hero. From this directory, run
`./generate-app-icon.sh` to regenerate committed AppIcon PNGs and
`Resources/Macseed.icns`, then rebuild. Temporary exports stay under ignored `build/`.
Both build paths use the static ICNS; quit/reopen if macOS caches an older Dock icon.

## Performance diagnostics

Follow [Core trace activation and limits](../../docs/core/APPLICATION-INTERFACE.md#opt-in-restore-performance-trace).
Launch the executable directly with its two explicit opt-in variables and a fresh
private output directory; an already-running app does not inherit new variables.
Trace is off by default, outside Protocol V1/Diagnostic Report, and never proves
Restore success. [Bounded measurements](../../docs/DESKTOP.md#recent-restore-qualification-and-performance)
distinguish real read-only observations, disposable Execute and native qualification.
