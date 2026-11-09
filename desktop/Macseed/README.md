# Macseed Desktop development

Native SwiftUI Desktop consumes Core/CLI 3.4.0 through Protocol V1. Normal Debug
and Release run real capabilities through **Capture**, **Rebuild** and **Check**.
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
or overwrite an installed `/Applications` copy. Startup reads Homebrew availability;
Home performs the Core capability check. When the
[Homebrew reminder gate](../../docs/DESKTOP.md#homebrew-setup--implemented-visually-accepted)
applies, its dedicated setup window precedes Home. Continuing or dismissing setup
starts no workflow. Installation requires explicit initiation and hands a verified
package to standard macOS Installer, or opens the manual Terminal route. Otherwise
Home exposes Capture, Rebuild and Check. Launch does not automatically scan, rebuild
or install Homebrew; **Ready · Macseed Core** does not qualify Capture/Restore/Compare.
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

Both build paths invoke `prepare-runtime.sh RESOURCE_DIRECTORY ARCHITECTURE`.
`prepare-age.py` verifies and reuses the pinned official archive cache, downloading
only when absent, and copies age v1.3.2 into `Contents/Helpers/age` with the upstream
license in `Contents/Resources/ThirdPartyNotices/`. Initial preparation needs network
access or the verified cache. One explicit arm64/x86_64 target is required; Intel
execution and universal packaging remain unqualified. See the
[provenance and distribution contract](../../docs/DISTRIBUTION.md#bundled-age--required-for-desktop-10).
No runtime download or external age/Homebrew fallback occurs. Preparation resolves the
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
with `writableCoreRequired`. Selected secure operations use the implemented
Stage 16H inherited socket bridge and validated bundled age; ordinary operations
continue if that helper is unavailable.
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
these twelve suites sequentially:

1. PresentationTests
2. SettingsTests
3. HomebrewSetupTests
4. HomebrewPackageTests
5. HomebrewLaunchTests
6. DiagnosticReportTests
7. OperationLogViewTests
8. OperationLogTests
9. CoreRuntimeTests
10. EnvironmentStatusTests
11. CaptureTests
12. RestoreTests

`SettingsTests <core-root> <python> <app-bundle>` copies the selected build's age
helper into a disposable app fixture and verifies read-only diagnostics, failure
boundaries, recheck coalescing and reused Homebrew controls. It never executes age
or installs tools. Settings layout checks run in full `PresentationTests` and are
also available through `--settings-tools-only`; native visual acceptance remains
separate.

`HomebrewSetupTests` uses injected observations/external actions and disposable fake
executables. `HomebrewLaunchTests` covers the synchronous entry stack, an actually
suspended check, a bounded startup timeout and late completion. Neither installs
Homebrew. `RestoreTests <core-root> <python> --homebrew-setup-only --no-renders`
uses the existing disposable Core fixture for setup → fresh Prepare/Preview,
including reminder suppression and no Execute.

After building Debug, `python3 -B scripts/test-homebrew-startup.py` from the repository
root exercises the **actual app**, serially, in an unlocked GUI session with native
accessibility access. Its explicit `--homebrew-setup-test` configuration, isolated
preference suites and control files are DEBUG-only; they override only setup state
and external-action sinks, never Core readiness or restoration. Public AXPress
invokes the real controls. The last scenario observes the real installed Homebrew
read-only. Window-only screenshots and traces stay ignored under
`build/Debug/HomebrewStartup`. A full matrix PASS is required; incomplete runs do
not establish native acceptance. Browser/Terminal launches and clipboard writes
remain simulated in this automated matrix. Release excludes the injection driver. With macOS Keyboard Navigation enabled,
`python3 -B scripts/test-homebrew-startup.py --keyboard-only` verifies native
Tab traversal and Return through public CoreGraphics key events on only the test
app. The runner never changes that system preference. Escape is covered by the
regular matrix; a window-level focus result with Keyboard Navigation disabled is
reported as unqualified traversal with exit 2, not a passing keyboard gate. The
complete matrix requires Keyboard Navigation enabled; `--keyboard-only` is available
for an explicitly authorized supplemental check.

For setup presentation and Settings refinements, `--ux-polish-only` limits the
native runner to method switching, Light/Dark geometry and screenshots, manual
focus/reminder preservation, startup continuation, same-session reopening and
read-only healthy Homebrew. It uses public accessibility frames and produces
`ux-polish-report.json` plus `polish-*.png` under the same output directory.
`PresentationTests --homebrew-setup-only` checks compact content sizing and the
unchanged Settings width; the model and launch suites cover the shared state and
async gate. These focused checks do not rerun or replace the full platform matrix.

`HomebrewPackageTests` uses injected metadata, URLSession/URLProtocol responses,
signature/trust outcomes and Installer actions. It exercises actual model cancellation,
native window close, late completions, duplicate-click guards and boot-bound cache
retention/cleanup with simulated boot changes. It also rejects an inert malformed
package using the real read-only verifier. Its explicit `--official-download` mode
resolves/downloads the current official asset with the production client and runs
read-only verification plus the independent `stapler validate` developer diagnostic;
it **never opens Installer**. `--official-file /private/staging/Homebrew.pkg /path/release.json`
validates an existing private package against retained official release metadata,
without downloading or launching it. `--trust-only` runs the eight policy scenarios
with injected system results and simulated handoff, plus read-only before/after
checks of this development host's existing Homebrew. Ordinary suite execution uses
an injected healthy observation instead of requiring real Homebrew. The public DER
fixture in `Tests/Fixtures/HomebrewPackageTrust.json` is bound to its recorded release;
fixture policy time is fixed, while production uses current certificate validity.
A blocked real trust gate exits 2 and is not installation acceptance. Acquisition/trust ownership and retained
handoff storage are documented in [Desktop](../../docs/DESKTOP.md#homebrew-setup--implemented-visually-accepted).

`python3 -B scripts/test-homebrew-startup.py --package-only` captures the actual Debug
app's stacked buttons, download/progress/cancel/retry, verification, safe fallback
and Terminal states in Light/Dark. Network and Installer outcomes are injected in
every debug startup fixture, including fixtures that observe real installed
Homebrew. These screenshots demonstrate native UI behavior, not a real installation.

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

Use [risk-based local validation](../../CONTRIBUTING.md#risk-based-local-validation):
incremental changes use relevant feature and/or presentation cases and retain prior
PASS evidence when the tested code and assumptions are unchanged. Complete suites
require a concrete justification before execution at a substantive integration/release
checkpoint or for a demonstrated risk; small corrections do not automatically rerun
full PresentationTests or feature suites. Mandatory Desktop CI coverage is unchanged.
Repository regression and Desktop validation
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
| `--workflow-scroll-only` | ProductionWorkspace with disposable Protocol fixture; result arrival, native wheel to bottom/back, disclosure and changed Check Again at 1000 × 700 and 1200 × 800 |
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
