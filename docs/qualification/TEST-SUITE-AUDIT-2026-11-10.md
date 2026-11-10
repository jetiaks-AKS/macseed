# Test suite audit and optimization — 10 November 2026

## Scope and result

Baseline: `develop`, `a289442ffe032c8e5477d2c7cdb84aaf6d7c1f5a`.
This checkpoint audits the tracked test sources, their entrypoints, fixtures,
assertions, architectural boundaries and available hosted timings. It changes
test infrastructure only. Production sources, protocol/security contracts and
the Full CI workflow/gates are unchanged. Fast/Full separation is deferred.

The complete Python method ledger and native entrypoint ledger are below.
The 26 shell harnesses are sequential programs with parameterized assertion
blocks, not independently selectable unittest methods; their domains, failure
groups and actual whole-process costs are inventoried separately. Static call
sites, subtests and native `precondition` statements are not claimed as executed
case counts. Generated binaries, screenshots, copied tests under `logs/`, and the
untracked `NativeSidebarRepro.swift` are not source-controlled test inventory.

No entire test method or suite was proven obsolete. All 724 canonical Python
methods remain. Five redundant full screenshot roundtrips are consolidated into
four backend combinations; eight repeated invocations of four constant Restore
contract groups are consolidated into their standard invocation. Native workflows,
unique negative cases, mutation/atomicity, cancellation and independent Verification
checks remain. Useful standalone tests outside Full CI are coverage gaps, not dead
code to delete. Exact-body AST comparison found no duplicate Python method bodies;
that check alone is not proof of behavioral uniqueness.

Implemented improvements:

- Compile the common production Swift sources once for ten Debug test executables.
  Preserve the smaller source sets of CoreRuntimeTests and OperationLogTests.
- Restrict later Desktop Workspace/application-overlap fixtures to the collectors
  they exercise, following the existing disposable Secure Capture fixture pattern.
- Consolidate equivalent screenshot backend scenarios and repeated Restore model checks.
- Refresh scheduling weights from all successful #161 partitions; retain a
  conservative old weight for the changed screenshot method.
- Unbuffer Capture progress and report its expensive groups separately. The enclosing
  `realCore` timing includes Workspace/overlap; those times must not be summed.

**Qualification:** focused local results are recorded below. Optimized hosted Full
CI is NOT RUN. No full local Core regression or full Desktop run, commit, push,
workflow dispatch or workflow against the developer's own HOME/configuration occurred.
Real Core operations ran only in the documented disposable test fixtures.

## Hosted baseline and critical path

[CI #161](https://github.com/jetiaks-AKS/macseed/actions/runs/42836491162) is a
successful **second attempt**, not one uninterrupted green Full execution.
The repository SHA is identical across both attempts.

| Evidence | Actual duration / provenance |
| --- | --- |
| Attempt 2 | 15:42:21–16:27:55 UTC: **45:34**. Only shards 2 and 3 were rerun; prior successful jobs were retained. |
| Attempt 1 | Shards 2 and 3 were cancelled; lint, shards 1 and 4, and Desktop passed. Its aggregate failed. |
| Entire run history | 14:40:35–16:27:55 UTC: **1:47:20**, including two attempts and scheduling gaps; not normal Full CI runtime. |
| Desktop job | Attempt 1, job `129937563514`: **41:08**; build/test step **40:42**. |
| Core successful process totals | Shards 1/2/3/4: **2783.183 / 2688.999 / 1820.020 / 2673.773 s**. |
| Core payload aggregate | **9965.975 s**, parallel runner work; do not add this to Desktop wall time. |
| Swift compilation | Test executables **745.881 s**; app/runtime preparation **62.888 s**; combined **808.769 s (13:28.8)**. |
| CaptureTests | **1260.067 s (21:00.1)**. |

The four downloaded safe artifacts are `13778925372` (shard 1), `13781184432`
(2), `13780222996` (3), and `13778565250` (4). All 59 successful suite-partition
records are PASS and contain exactly **724 PASS Python methods**, no skips.
Five split suites account for 346 methods; 39 suites remain whole. Source AST IDs
and loader IDs are checked against this inventory. The canonical plan has
**385 units**, assigned once across four disjoint shards.

Timing sources are job/step timestamps and typed safe artifact records. Desktop
stage costs are differences between adjacent unbuffered `Running:` timestamps;
they include negligible stage-summary overhead. Most old Capture messages were
buffered until exit, so #161 does **not** provide trustworthy per-helper Capture
times. They are not invented from those messages. Other native groups without
timing records are marked unmeasured within their measured suite.

The workflow runs lint and regression independently; Desktop waits for lint only;
`validate` waits for lint, every regression shard and Desktop. A successful
single-attempt reconstruction using #161 job costs is therefore dominated by the
approximately 46-minute Core shard, with provisioning/queue variation, rather than
the sum of jobs. The literal 45:34 retry duration is not a valid all-jobs baseline.

### Twenty most expensive non-overlapping measured units

The table below ranks Desktop stages, individual Python methods and whole shell
processes. It excludes their enclosing suite totals to avoid double counting.

| Rank | Measured unit | Seconds | Scope |
| ---: | --- | ---: | --- |
| 1 | `CaptureTests` | 1260.067 | Desktop stage |
| 2 | `test_restore_prepare.RestorePrepareTests.test_screenshots_cross_version_matrix` | 607.590 | Core method |
| 3 | `Compile RestoreTests` | 303.512 | Desktop stage |
| 4 | `test_workspace_topology_execute.TopologyExecuteTests.test_switch_and_exact_detached` | 268.644 | Core method |
| 5 | `test_workspace_topology_execute.TopologyExecuteTests.test_add_multiple_linked_and_repeat` | 258.943 | Core method |
| 6 | `test_capture_api.CaptureTests.test_macos_included_settings_are_effective_value_free_metadata` | 244.372 | Core method |
| 7 | `OperationLogViewTests` | 170.601 | Desktop stage |
| 8 | `test_workspace_topology_execute.TopologyExecuteTests.test_graceful_stop_finishes_owned_step_and_fresh_retry` | 164.833 | Core method |
| 9 | `test_restore_prepare.RestorePrepareTests.test_repository_clone_convergence_and_existing_coverage` | 159.093 | Core method |
| 10 | `scripts/test-macos-bootstrap.sh` | 152.113 | Core shell harness |
| 11 | `test_restore_prepare.RestorePrepareTests.test_assisted_appstore_mixed_restore_and_manual_convergence` | 141.881 | Core method |
| 12 | `scripts/test-preview-integration.sh` | 130.993 | Core shell harness |
| 13 | `test_restore_prepare.RestorePrepareTests.test_qualified_cask_cli_artifacts` | 127.325 | Core method |
| 14 | `test_workspace_topology_execute.TopologyExecuteTests.test_success_exit_without_result_is_not_verified` | 121.862 | Core method |
| 15 | `test_capture_api.CaptureTests.test_vscode_descriptors_selected_metadata_only_and_legacy_omission` | 118.843 | Core method |
| 16 | `test_capture_api.CaptureTests.test_ssh_host_capture_subset_full_empty_and_readonly_check` | 117.717 | Core method |
| 17 | `test_capture_api.CaptureTests.test_ssh_host_capture_stale_ids_scope_and_ambiguous_source` | 116.785 | Core method |
| 18 | `test_workspace_topology_execute.TopologyExecuteTests.test_descriptor_after_clone_and_linked_checkout` | 115.492 | Core method |
| 19 | `test_capture_api.CaptureTests.test_topology_capture_full_partial_dependencies_and_restore_block` | 102.928 | Core method |
| 20 | `test_workspace_topology_execute.TopologyExecuteTests.test_partial_worktree_retained_and_retry_fenced` | 101.834 | Core method |

## Coverage decisions and optimizations

### Screenshot backend equivalence

`screenshots_location_backend` has one branch for 10.14–15 and 26, and a separate
branch for 27. Bundle v1 stores logical `location`; it does not encode the source
OS key choice. The existing nine scenarios used synthetic version strings on the
same host, not nine real operating-system qualifications.

The method now checks the production backend selector for all nine supported
version aliases and rejects 28, then retains full Capture → Bundle → Prepare →
Execute → independent Verification → fresh Prepare → repeated Execute for:
26→26, 26→27, 27→26 and 27→27. Each keeps its own temporary HOME, target preference
state, Bundle, write/restart record and cleanup. All original per-roundtrip
assertions remain, including unchanged recording/legacy preferences and no-op.

| Removed repeated roundtrip | Previously verified | Equivalent remaining roundtrip |
| --- | --- | --- |
| 15→15 | Legacy producer and legacy consumer | 26→26, plus explicit 15 backend binding |
| 15→26 | Legacy producer and legacy consumer | 26→26, plus explicit 15 backend binding |
| 26→15 | Legacy producer and legacy consumer | 26→26, plus explicit 15 backend binding |
| 15→27 | Legacy producer and split-key consumer | 26→27, plus explicit 15 backend binding |
| 27→15 | Split-key producer and legacy consumer | 27→26, plus explicit 15 backend binding |

This removes 20 repeated production Core requests and five source-serialization/
packaging setups. It does not move those operations into another phase. Invalid
types, observation errors, unsupported targets and path/preservation cases remain
in the macOS Discovery/Bootstrap, Preview and other Restore tests.

### Capture integration fixtures

The first `realCore` scenario still executes all production collectors and checks
exact domain-event coverage, optional Workspace presence, selected publication,
0600 permissions, authoritative Bundle inspection, stale input, category-only
Capture without Homebrew, replacement/no-clobber, injected publication failures,
and HOME/configuration preservation.

Only the subsequent Workspace and overlap scenarios omit unrelated Git-settings,
SSH-config, VS Code settings and macOS collectors in their private copied Core.
Workspace retains its real Workspace and shell collectors and all five native Git
fixtures. Shell supplies the independent selected category in the neither-folder-
nor-repository combination. Overlap retains real application collectors/catalog
logic and omits Workspace and shell. Selection dependencies, all four role
combinations, actual publication/inspection, no-mutation snapshots and changed-
decision stale rejection remain. The secure fixture and its actual crypto/channel,
privacy, cancellation, bad bundled-helper and no-clobber checks remain.

An initial focused run exposed an empty-scope fixture error when shell was omitted
from Workspace. Core correctly rejected publication. The fixture was corrected to
retain shell; no assertion or production behavior was weakened. Cleanup was
confirmed after that failed iteration.

### Swift compilation

The existing whole-module Debug build still rebuilt almost the same production
source set ten times. A bounded prototype compared the same baseline test sources,
same Swift/SDK, Debug flags and populated module cache, sequentially:

| Local compile | Previous | Shared object/module |
| --- | ---: | ---: |
| CaptureTests | 20.408 s | 7.105 s |
| RestoreTests | 57.375 s | 42.970 s |
| Shared production sources | Repeated in each executable | 13.634 s once |

These are single local measurements, not hosted ratios or statistical benchmarks.
The implementation uses `-enable-testing` and generated `@testable import` wrappers,
preserving `#filePath`/diagnostic source locations. It rebuilds the object/module on
every invocation; there is no persistent fixture/result/module cache to invalidate.
`-Onone`, assertions, debug symbols and DEBUG remain. Test bodies remain separate
executables. The app and Release builds and the two smaller Core executable source
sets are unchanged. Shared compilation is an explicit failing/not-run summary stage.

### Restore modes

The standard run and both extra modes repeated identical `topologyPreviewChecks`,
`assistedAppStoreChecks` (including application precedence), `taskPresentationChecks`
and `restoreEvidenceChecks`, plus their adjacent constant result assertions.
They have no dependency on the two modes' later workflow fixtures. They now run
once in the mandatory standard invocation: **12 named-group invocations → 4**.

Both extra invocations remain mandatory. Final UX uses a distinct 104-folder/
15-App-Store-item fixture and no secure component. Assisted App Store exercises
Refresh cancellation/ownership, requested/effective scope, manual navigation,
Installed/Missing/Unverified and failed rechecks. These are not equivalent to the
standard run. Real Prepare and unique transport/mutation cases are not removed.
The recently repaired native mouse-release/event-loop fixture is unchanged.

### Runner, scheduling and fixtures

`test.sh` remains the sole 44-suite inventory. `test_runner.py`, `test_unittest.py`
and `desktop_test_runner.py` are unchanged: deterministic planning, complete union,
fail-closed worker results, exit propagation, private TMPDIR, process ownership,
deadlines, cleanup and safe diagnostic boundaries remain. The new shared-compile
stage is covered by the existing runner test, now checking compile failure as well
as suite failure. No test executable can run past a failed compile.

Weights now use #161's 44 complete successful suite totals and all 346 split-case
measurements. No missing IDs remain. The old screenshot timing is deliberately
retained and labeled as pre-optimization, not presented as a new measurement.
Refreshed planned loads are **2502.428 / 2503.130 / 2503.192 / 2503.098 s**.
The actual old assignment on the same completed evidence was uneven (above).

Repeated setup is not the principal Core bottleneck: the largest cases spend
roughly 0.02–0.70 s in setup and tens/hundreds of seconds in actual preparation,
execution, observation and Verification. `workspace_fixture.py` already constructs
small native Git objects/indexes without repeated Git setup commands. Sharing
mutable HOME, journals, keys or target state would invalidate safety/isolation
contracts for little setup savings. It is not introduced.

Real sleeps in cancellation/watchdog fixtures maintain live children or progress
and are bounded by the exercised deadline/cleanup. Native settling waits belong to
layout/interaction assertions. Their presence alone is not evidence of waste.
The observed process polling and preservation snapshots remain: they prove cleanup,
freshness or unchanged target state. No broad UI matrix reduction was justified;
different widths/appearances/scroll positions can expose different native behavior.

## Counts, performance and remaining bottlenecks

| Count | Before | After |
| --- | ---: | ---: |
| Canonical Core suites | 44 | 44 |
| Canonical Python methods | 724 | 724 |
| Shell harnesses | 26 | 26 |
| Split cases + whole planning units | 346 + 39 | 346 + 39 |
| Desktop suites / invocations | 12 / 14 | 12 / 14 |
| Additional tracked Python methods outside Full CI | 52 | 52 |
| Full screenshot roundtrip scenarios | 9 | 4 |
| Repeated named Restore contract-group invocations | 12 | 4 |
| Entire methods/suites removed | — | 0 |
| Redundant scenario invocations removed | — | 5 screenshot + 8 Restore group invocations |

Native tests are custom executable programs, not a discoverable XCTest case list.
Their functions include fixture/render helpers and `main`; counting those as test
cases would be misleading. The native ledger enumerates every static function and
explicit selector, while the suite table maps significant behavior groups.

### Focused local measurements

Local environment: Apple Silicon, macOS 27.2, Swift 6.4.2 with Swift-5 language
mode, Xcode-resolved Python. Hosted #161 used Xcode 26.6 / Swift 6.3.3.
All compile/test workloads below ran sequentially; these are single observations.

| Same-host focused Capture scope | Before | After | Saved |
| --- | ---: | ---: | ---: |
| Workspace selection/publication | 152.304 s | 115.185 s | 37.119 s |
| Application overlap/stale decision | 113.337 s | 88.129 s | 25.208 s |
| Combined two scopes | 265.641 s | 203.314 s | **62.327 s (23.5%)** |

The before executables used baseline fixtures with only the same focused selectors
added. The after executables retained their assertions and narrowed collectors.
Times include the unchanged process supervisor; all four final runs reported
`cleanup: confirmed`. These measurements do not establish a 23.5% reduction for
all CaptureTests or for hosted CI. The original full Capture invocation was not rerun.

All twelve final Debug harness source sets compile. A bounded compile-only pass
(shared module plus twelve executables; no app build or tests) took 90 s locally.
Renaming generated wrappers to avoid a new `#fileID` path-collision warning was
followed by recompiling the ten affected wrappers (73 s); unchanged common objects
and the two smaller executables retained their previous PASS. The wrapper naming
change does not change compiler options or production/test source semantics.
`OperationLogViewTests --summary-only` additionally passed its real `#filePath`
source reads. There is no complete same-host old/new twelve-executable benchmark;
only the two controlled comparisons above support a compilation speedup claim.

The reduced screenshot method passed locally in **199.955 s** (whole selected-suite
process 200.261 s), including four complete Core roundtrips, alias/unsupported
selection checks and cleanup. Its #161 time was 607.590 s for nine roundtrips on
a different hosted environment; these are not a controlled before/after comparison.
Five of nine equivalent expensive rounds were removed, but their hosted savings
remain an estimate until remeasurement.

Restore's repeated constant groups were demonstrably removed, but no reliable
same-host before/after timing isolates their small cost. No numerical saving is
claimed for that consolidation. No expensive work was moved to another phase.

Expected optimized Full critical path: **about 42 minutes plus runner provisioning/
queue time**, based on the conservative refreshed Core plan and measured local
Desktop reductions. It is an estimate, not acceptance or a promise. Reducing the
screenshot scenario cost while retaining its conservative weight benefits its own
shard; other shards may remain near 41:43. Do not subtract all saved test seconds
from workflow wall time. A new single-attempt hosted run is needed to measure actual
critical path and refresh the changed method's weight.

Remaining costly cases intentionally retain real boundaries: Git clone/worktree
mutation and repeat convergence, process cancellation/unknown consequences, secure
identity transport/import, Capture publication and independent Verification. Moving
these to mocks or a nonmandatory tier is not justified here. OperationLogView's
native table/history scenarios are expensive but exercise a different boundary
from storage/model tests. The OS/Swift versions differ locally and on #161; compiler
and native GUI speedup cannot be extrapolated exactly.

## Validation and limitations

New focused evidence (all workloads sequential):

| Scope | Result / evidence |
| --- | --- |
| Compile-only source inventory | **PASS**: common module and all 12 harnesses; ten final wrappers recompiled after correcting source-location warnings. No app or full suite was run. Local drivers: `logs/test-audit/compile-only.sh`, `recompile-wrappers.sh`; summaries: `compile-summary.md`, `wrappers-summary.md`. |
| Two changed Capture fixtures | **PASS**: before and corrected-after `--workspace-core-only` / `--overlap-core-only`, all selected publication/dependency/stale/preservation assertions; cleanup confirmed. Driver `logs/test-audit/capture-focused.py`; saved wrappers and results under `logs/test-audit/compile/`. |
| Native mouse tracking | **PASS**: `PresentationTests --selection-help-only`, 37.521 s; all eight capture/rebuild × width × appearance combinations, queued mouse release and final return to async main. Existing native assertions unchanged. |
| Secure selection/operation binding | **PASS**: Capture `--secure-invalidation-only` (1.336 s), `--secure-selection-only` (0.738 s). |
| Consolidated Restore groups/modes | **PASS**: `--presentation-only` (0.732 s), `--final-restore-ux-only --no-renders` (3.360 s), `--assisted-appstore-only --no-renders` (3.408 s). |
| Shared-module consumers | **PASS**: OperationLogView `--summary-only` including source reads (0.752 s), HomebrewLaunch (1.121 s), Settings (1.040 s). Settings uses the existing Debug app only as a read-only source for disposable authenticated-helper fixtures. |
| Desktop process safety | All nine final executable runs reported **PASS / cleanup confirmed** through the unchanged `desktop_test_runner.py`. Exact sequential argv are in `logs/test-audit/desktop-focused.py`; results in `desktop-focused.json`. |
| Changed screenshot method | **PASS**: the one selected method, 199.955 s; four full roundtrips, all alias/unsupported bindings; complete worker report, no cleanup error and no skips. `logs/test-audit/screenshots/safe/summary.json`. |
| Runner contract checks | **PASS**: four selected methods, 3.102 s total; shared-compile/suite exit 17 propagates, later work is NOT RUN, exact partitions and read-only selection hold. `logs/test-audit/runner/safe/summary.json`. |
| Inventory / scheduling | **PASS**: 44 canonical suites; loader IDs exactly equal all 724 #161 PASS IDs; 346 measured split cases + 39 whole suites produce 385 units with complete disjoint four-shard assignment. All weights equal the successful #161 artifact values. |
| Static checks | **PASS**: Python AST for changed scripts, timing JSON/provenance, canonical `scripts/lint.sh`, focused ShellCheck for `desktop/Macseed/build.sh`, required Bash syntax, relative documentation links/anchors and `git diff --check`. |

Focused Core commands:

```bash
./scripts/test.sh --suite scripts/test-restore-prepare.py \
  --case RestorePrepareTests.test_screenshots_cross_version_matrix \
  --output logs/test-audit/screenshots
./scripts/test.sh --suite scripts/test-test-runner.py \
  --case RunnerTests.test_real_ids_are_exact_disjoint_and_new_cases_are_assigned \
  --case RunnerTests.test_case_weights_preserve_budget_and_conservative_unknowns \
  --case RunnerTests.test_desktop_stage_summary_records_running_failed_and_not_run \
  --case RunnerTests.test_case_sharded_cli_selection_is_read_only \
  --output logs/test-audit/runner
```

Desktop commands pass through the unchanged supervisor with explicit deadlines;
Capture/Restore receive the repository and Xcode Python arguments. The local drivers
are review artifacts, not a replacement runner or a new committed test framework.

Resolved validation iterations: the first sandboxed Desktop launch returned
`observation_error` before starting the executable; it was rerun with process-table
access. The first narrowed Workspace fixture failed because its independent shell
category had been removed; the corrected fixture passed with every assertion
intact. A new generated-wrapper `#fileID` warning was fixed by a distinct wrapper
basename and verified by recompilation and source-reading execution. No unresolved
focused failure remains. No failure was converted to SKIP.

Reused evidence: #161 at the baseline SHA for unchanged production contracts and
unchanged tests. Compilation changes affect the test linkage boundary, so baseline
PASS does not qualify the optimized executables; focused new checks and the pending
hosted gate are kept separate. Full local Core, full Desktop, real-Mac E2E, Release
build/distribution and new hosted CI are NOT RUN by task scope. No manual visual
acceptance is claimed. In particular, the full Capture crypto/publication run,
full Restore, remaining Presentation/OperationLogView cases, EnvironmentStatus,
HomebrewSetup, HomebrewPackage and DiagnosticReport execution were not repeated.
CoreRuntime/OperationLog executions retain baseline evidence because their source
sets and compilation options are unchanged. Newly shared consumers still require
the existing hosted gate; compilation alone does not close that gap. Existing Swift
concurrency warnings under Swift-5 language mode are not suppressed or treated as
a new product change.

## Changed files and review artifacts

| File | Change |
| --- | --- |
| [`CONTRIBUTING.md`](../../CONTRIBUTING.md) | Test-infrastructure owner: measured timing provenance, shared compilation and fixture boundaries. |
| [`desktop/Macseed/build.sh`](../../desktop/Macseed/build.sh) | One Debug common module, preserved source locations, explicit compile stage and original small/Release paths. |
| [`CaptureTests.swift`](../../desktop/Macseed/Tests/CaptureTests.swift) | Two narrowed disposable collectors, focused selectors and unbuffered group timings. |
| [`RestoreTests.swift`](../../desktop/Macseed/Tests/RestoreTests.swift) | Constant contracts run once; both mandatory specialized workflows remain. |
| [`scripts/test-restore-prepare.py`](../../scripts/test-restore-prepare.py) | Four backend crossings plus complete cheap version-selector coverage. |
| [`scripts/test-test-runner.py`](../../scripts/test-test-runner.py) | Stage regression covers shared-compile failure and suite failure without compiling. |
| [`scripts/test-timings.json`](../../scripts/test-timings.json) | Successful #161 weights/provenance; conservative changed-method weight. |
| [`docs/qualification/README.md`](README.md) | Evidence index. |
| [`docs/qualification/TEST-SUITE-AUDIT-2026-11-10.md`](TEST-SUITE-AUDIT-2026-11-10.md) | This consolidated qualification record and full inventory. |

Documentation ownership was reviewed: CONTRIBUTING owns execution/test policy;
this report owns the audit evidence. No product contract, Roadmap milestone,
release-visible feature or production behavior changed, so other product owners
and CHANGELOG are unchanged.

The complete unstaged patch, including this new report, is saved locally as
`logs/test-audit/checkpoint.patch`.
It is an ignored review artifact, not a test source or a published attachment.
Full updated files remain in the working tree. Sanitized conclusions and inventory
are recorded here; raw/local logs and downloaded artifacts remain ignored.

Final branch/HEAD: `develop` / `a289442ffe032c8e5477d2c7cdb84aaf6d7c1f5a`.
The index is empty; all checkpoint changes are unstaged. No commit, push or dispatch.

```text
 M CONTRIBUTING.md
 M desktop/Macseed/Tests/CaptureTests.swift
 M desktop/Macseed/Tests/RestoreTests.swift
 M desktop/Macseed/build.sh
 M docs/qualification/README.md
 M scripts/test-restore-prepare.py
 M scripts/test-test-runner.py
 M scripts/test-timings.json
?? desktop/Macseed/Tests/NativeSidebarRepro.swift
?? docs/qualification/TEST-SUITE-AUDIT-2026-11-10.md
```

The pre-existing untracked `NativeSidebarRepro.swift` is untouched and excluded from
the patch. Its before/after SHA-256 is
`8cf3e1b91ed0b878efe0178be78956f873b5c896ef6f28af2c68e89e0019f7cf`.


## Complete inventory and behavioral coverage

Classification: **KEEP** = required distinct boundary; **OPTIMIZE** = retain behavior,
reduce cost; **MERGE** = consolidate equivalent repetitions; **REMOVE** = obsolete
or fully redundant source test; **QUALIFICATION ONLY** = explicit native/manual
qualification rather than every checkpoint. No whole source test is classified REMOVE.

### All 44 canonical Core suites

| Suite | Python methods | #161 process s | Decision and unique coverage / overlap boundary |
| --- | ---: | ---: | --- |
| [test-test-runner](../../scripts/test-test-runner.py) | 20 | 28.056 | **OPTIMIZE** — Runner: deterministic exact partitions, new/missing IDs, safe results, deadlines, cancellation and owned cleanup. Desktop supervisor/stage failures are distinct from product runtime tests. |
| [test-application-discovery](../../scripts/test-application-discovery.sh) | shell | 1.649 | **KEEP** — Production exporters with external spies: App Store/VS Code enumeration, exact format, empty/absent/error, atomic publication and lifecycle exits. Producer boundary differs from consumers. |
| [test-blueprint-bootstrap](../../scripts/test-blueprint-bootstrap.sh) | shell | 1.658 | **KEEP** — Blueprint consumers/orchestration: all-inclusive compatibility, disabled/partial scope, workspace eligibility, macOS categories and lifecycle Summary. Parser/selector suites do not execute this boundary. |
| [test-blueprint-selector](../../scripts/test-blueprint-selector.sh) | shell | 9.287 | **KEEP** — Interactive selector: item/page/range toggles, old scope, malformed input, atomic save, q/Q/EOF preservation and logs. CLI interaction differs from parser validation. |
| [test-blueprint](../../scripts/test-blueprint.sh) | shell | 1.181 | **KEEP** — Parser/validator: accepted schema, malformed and stale data, missing/old categories, candidate classification and normalization. Keep producer and consumer validation separately. |
| [test-bootstrap-applications](../../scripts/test-bootstrap-applications.sh) | shell | 14.902 | **KEEP** — Production domain consumers: formula/cask/VS Code selected installs, verification, partial failure, Changed accounting and assisted App Store no-install guards. Retired MAS install is a forbidden-call tripwire, not obsolete automatic restoration. |
| [test-bootstrap-bundle](../../scripts/test-bootstrap-bundle.py) | 68 | 68.996 | **KEEP** — BundleTests 31: selected/legacy format, checksums, privacy, CLI/secure consent and grouped recovery. TopologyTests 21: schema/capability/alias/dependency bounds. WorkspaceDiscoveryTests 16: real Git observation and atomic grouped publication. Distinct from application-protocol transport. |
| [test-bootstrap-startup](../../scripts/test-bootstrap-startup.sh) | shell | 0.375 | **KEEP** — Startup ordering: validate before preflight/mutation, error/stale propagation and performance-helper dependency. Entrypoint fence, not domain behavior. |
| [test-bs-launcher](../../scripts/test-bs-launcher.sh) | shell | 0.745 | **KEEP** — Launcher/install adapter: argv dispatch, arbitrary cwd, correct/foreign/dangling links, repeated no-op, permission errors and Bootstrap integration. Preserve unrelated launchers. |
| [test-bundle-publication-safety](../../scripts/test-bundle-publication-safety.py) | 9 | 1.593 | **KEEP** — PublicationSafetyTests 6: crash at each durable publication/recovery boundary and preserve unproven paths. TarHeaderSafetyTests 3: hostile raw archive sizes/counts terminate. Process-crash evidence differs from in-process exceptions. |
| [test-configuration-preview](../../scripts/test-configuration-preview.sh) | shell | 0.437 | **KEEP** — Read-only Git and VS Code settings consumers: match/missing/different/error and late observation failure. No mutation or Changed state. |
| [test-core-lifecycle](../../scripts/test-core-lifecycle.sh) | shell | 0.441 | **KEEP** — Shared shell lifecycle: check/apply/inspection exit precedence, Changed and explicit planned-action counters. Does not duplicate domain post-apply verification. |
| [test-capture-api](../../scripts/test-capture-api.py) | 42 | 1894.354 | **KEEP** — Production protocol Capture: 42 methods covering inventory/private staging, SSH Host subset/coverage, provider overlap, Workspace/VS Code metadata, selection, stale/no-clobber, macOS metadata, cancellation and secure channels. Separate from Swift decoding and lower-level Bundle checks. |
| [test-environment-compare](../../scripts/test-environment-compare.py) | 58 | 226.470 | **KEEP** — SSHMergeTests 11: safe merge/races/recovery. CompareTests 34: read-only saved/generated provenance, incomplete/unverified scope, privacy and cancellation. TopologyCompareTests 13: independent native Git/descriptor evidence. Check equality never implies authentication. |
| [test-core-application-interface](../../scripts/test-core-application-interface.py) | 5 | 3.921 | **KEEP** — Protocol entrypoint: capabilities, invalid/enveloped requests, Bundle inspection, error taxonomy and human CLI compatibility. Kept alongside lower-level decoders. |
| [test-discovery-summary](../../scripts/test-discovery-summary.sh) | shell | 2.870 | **KEEP** — Controller/terminal/log Summary contracts for populated/partial/error observations and state preservation. Not a second exporter implementation. |
| [test-dry-run-cli](../../scripts/test-dry-run-cli.sh) | shell | 24.780 | **KEEP** — CLI/workflow routing: no Apply/admin/setup during Preview/Capture observation, startup validation, selected domains, malformed input and Summary. Real entrypoint spies differ from focused consumer checks. |
| [test-git-generated-state](../../scripts/test-git-generated-state.sh) | shell | 6.830 | **KEEP** — Native Git reader/export/consumer: seven keys, normalization, ambiguity/XDG/multivar/include/link protection, observation errors, no-clobber and repeat. Values remain data. |
| [test-global-verification](../../scripts/test-global-verification.sh) | shell | 16.090 | **KEEP** — Independent production readers: selected conformity, unsupported/unresolved/extras, digest provenance, privacy, exact snapshots, absent tools and operation/result separation across domains. Not replaced by successful Apply. |
| [test-homebrew-discovery](../../scripts/test-homebrew-discovery.sh) | shell | 2.594 | **KEEP** — Formula/cask exporters: requested inventory, empty versus failed/absent observation, complete provenance, atomic serialization/publication and lifecycle. No real package install. |
| [test-homebrew-preflight](../../scripts/test-homebrew-preflight.sh) | shell | 0.411 | **KEEP** — Preflight policy: absent/present/error, read-only behavior and installer admission. Observation error cannot mean absent. |
| [test-macos-bootstrap](../../scripts/test-macos-bootstrap.sh) | shell | 152.113 | **KEEP** — Six production settings consumers: input/type/enum validation before writes, tri-state reads, partial failure, local Verify, restart deduplication, selection, process boundaries, screenshot backend and repeat/no-op. Rich shell matrix has no independent case selector. |
| [test-macos-discovery](../../scripts/test-macos-discovery.sh) | shell | 35.363 | **KEEP** — Six producer schemas: exact inventories, native scalar types, supported/unknown enums, optional absence, effective defaults, unsafe values and atomic snapshot preservation. Consumer tests do not prove export behavior. |
| [test-preview-applications](../../scripts/test-preview-applications.sh) | shell | 2.043 | **KEEP** — Formula/cask/App Store/VS Code observers: selected scope, empty/unsupported/failed inventories and truthful plans without mutation. |
| [test-preview-integration](../../scripts/test-preview-integration.sh) | shell | 130.993 | **KEEP** — Real CLI plus all domains: stable mixed Preview, warning/error continuation, malformed selected input, disabled invalid scopes, workflow selection/save/cancel/EOF and zero-plan exits. Lower-layer assertions do not prove orchestration. |
| [test-restore-prerequisites](../../scripts/test-restore-prerequisites.py) | 13 | 75.702 | **KEEP** — Production terminal Restore dependency gates: validate all inputs, SSH config/import before Git, denial/decryption/conflict, absent tools and activated Homebrew environment. Distinct from structured Restore API. |
| [test-item-stall](../../scripts/test-item-stall.py) | 26 | 334.687 | **KEEP** — WatchdogTests 8: real progress/live children. RestoreStallTests 4: stalled item, independent continuation and Verify. FormulaQuiescenceTests 7 and FormulaDurabilityTests 7: unknown cleanup, write-ahead state and re-entry fences. Long child sleeps are deliberately interrupted. |
| [test-external-tools](../../scripts/test-external-tools.py) | 8 | 54.179 | **KEEP** — Homebrew adapter: capability/version metadata, unreadable/unknown state, launchctl identity/ownership, dependency re-observation and optional Bundle provenance. No names/version heuristics substitute for evidence. |
| [test-external-process-reliability](../../scripts/test-external-process-reliability.py) | 26 | 100.534 | **KEEP** — 26 cases: native clone, observation pipes/EOF, process ownership/descendants, deadlines, journals, denied cleanup, privacy and integrated independent failure/Verification. Different from internal watchdog unit state. |
| [test-homebrew-capabilities](../../scripts/test-homebrew-capabilities.py) | 86 | 108.938 | **KEEP** — CapabilityTests 69: artifacts/PKG/receipt/Rosetta/launchctl/login-item/authorization evidence and fail-closed negatives. RestoreCapabilityTests 6: integrated preparation/Execute/Verify and unknown state. ApplicationIdentityTests 11: catalog/cache/ambiguity/Cask-first correspondence. No automatic MAS revival. |
| [test-restore-prepare](../../scripts/test-restore-prepare.py) | 138 | 3273.500 | **OPTIMIZE** — RestorePrepareTests 105: production Preview/Execute, selected prerequisites, all consumers, mutation/verification, publication, cancellation, stale plans and provider ownership. TopologyPreviewTests 33: real Git freshness/index/hooks/path protection. Only equivalent screenshot roundtrip repetitions are consolidated. |
| [test-restore-selection](../../scripts/test-restore-selection.py) | 48 | 263.257 | **KEEP** — IdentityDependencyTests 8, IdentityResolutionTests 19: safe path/pair qualification and explicit corrections. SelectionTests 21: real scope projection, SSH binding/approval, independent categories, freshness and no-op. Selection is not authorization. |
| [test-secure-restore](../../scripts/test-secure-restore.py) | 84 | 772.158 | **KEEP** — SecureRestoreTests 66: authenticated import, selected/custom destinations, privacy, retry/consent, malformed/changed input, cancellation and independent Verify/no-op. PairProofTests 1, ChallengeContextTests 4, ChannelTests 13: race, strict identity/frame/fd/secret boundaries. Repeated-noop and initially-identical targets are different states. |
| [test-secure-check](../../scripts/test-secure-check.py) | 15 | 46.454 | **KEEP** — IdentityObservationTests 3: safe saved-byte comparison. SecureCheckTests 12: authenticated Bundle scope, changed/partial/unsafe state, exact same-operation reference correspondence, cancellation, no writes and no fabricated key-usability/authentication claims. |
| [test-shell-zsh](../../scripts/test-shell-zsh.sh) | shell | 4.590 | **KEEP** — Discovery/format/Preview/Apply: eligible/absent/excluded input, private/nonportable/dependent content, hashes/length, source/target links, conflicts, legacy selection and repeat preservation. |
| [test-ssh-generated-state](../../scripts/test-ssh-generated-state.sh) | shell | 21.339 | **KEEP** — SSH config producer/consumer: v1/v2 schema, independent references, unsupported/ambiguous profiles, native parser, private source paths, symlink/race protection and legacy compatibility. No network authentication. |
| [test-ssh-identity-evidence](../../scripts/test-ssh-identity-evidence.py) | 14 | 4.771 | **KEEP** — 14 importer/evidence-consumer cases: matching/conflict/partial/unsafe, cancellation/unlock/decryption failures, rollback, strict authenticated receipt transport and no inference from exit zero. Distinct from saved-byte Secure Check. |
| [test-ssh-identity-migrate](../../scripts/test-ssh-identity-migrate.sh) | shell | 39.242 | **KEEP** — CLI identity/package/PTY contract: safe discovery/pairs, encrypted export/import, protected keys, malformed payloads, links/permissions, no-clobber and exact evidence. Real crypto and terminal consent remain. |
| [test-vscode-settings](../../scripts/test-vscode-settings.sh) | shell | 1.238 | **KEEP** — Opaque settings consumer: source/target/backup safety, matching/different/missing/error, permissions and repeated idempotency. Exporter checks cannot replace destination protection. |
| [test-vscode-extensions](../../scripts/test-vscode-extensions.py) | 30 | 201.939 | **KEEP** — DiagnosticReader 1; Bootstrap 9; Restore 3; CLIWatchdog 9; WatchdogRestore 1; ExecutionBoundary 7. Exact IDs, independent failures, bounded output/ownership, cancellation, durable unknown/re-entry and final Verify. Real subprocess paths retained. |
| [test-workspace-bootstrap](../../scripts/test-workspace-bootstrap.sh) | shell | 6.674 | **KEEP** — Folder/repository consumers: selected candidates, canonical readers, invalid input, existing/untracked/dirty state, remote/branch preservation and honest lifecycle. Topology API integration covers additional linked-worktree behavior. |
| [test-workspace-discovery](../../scripts/test-workspace-discovery.sh) | shell | 4.827 | **KEEP** — Grouped snapshot exporter: folders/repositories/descriptors/inventory, empty versus partial/error, format/permissions, every publication rename rollback and post-commit cleanup warning. workspace.conf remains independent. |
| [test-workspace-folders](../../scripts/test-workspace-folders.sh) | shell | 0.408 | **KEEP** — Classification/candidate contract: visible ordinary folders and exclusions remain name/classification driven. Distinct from creation and topology. |
| [test-workspace-topology-execute](../../scripts/test-workspace-topology-execute.py) | 34 | 2023.386 | **KEEP** — 34 real native Git/descriptor cases: clone/worktrees/branch/detached/nested dependency, SSH-before-Git, preserve dirty/conflicting paths, freshness, no false success, repeat/no-op and stop/unknown fences. Preview-only tests cannot replace mutation qualification. |

### All Desktop suites and extra modes

| Suite/mode | Compile s | Execute s | Boundary / decision |
| --- | ---: | ---: | --- |
| [PresentationTests](../../desktop/Macseed/Tests/PresentationTests.swift) | 71.409 | 51.717 | Native SwiftUI/AppKit + projection contracts, widths/themes/scroll/alignment, hierarchy/selection, secure dialog and errors, result/status semantics and the eight-combination queued mouse-release/event-loop fixture. KEEP native matrices; compilation OPTIMIZE. Focused-only legacy visual routes remain available. |
| [SettingsTests](../../desktop/Macseed/Tests/SettingsTests.swift) | 57.215 | 1.364 | Native resolver → bounded reader → authenticated bundled-age inspection, read-only app snapshot, missing/corrupt/linked helper and no external fallback. KEEP; differs from pure Python packaging tests. |
| [HomebrewSetupTests](../../desktop/Macseed/Tests/HomebrewSetupTests.swift) | 51.224 | 0.712 | Model/read-only probe: supported host, preferences/reminders, explicit install-method actions, stale observation, usable/absent/broken/unknown and bounded native reader. KEEP; no host install. |
| [HomebrewPackageTests](../../desktop/Macseed/Tests/HomebrewPackageTests.swift) | 36.261 | 3.331 | Installer/package plan, trusted fixture metadata/signature/hash/origin, consent, lifecycle/cancel/cache races and no-clobber. KEEP; native installer real qualification is separate. |
| [HomebrewLaunchTests](../../desktop/Macseed/Tests/HomebrewLaunchTests.swift) | 28.910 | 0.555 | Synchronous app entry plus suspended MainActor, timeout/late-completion and responsive Home. KEEP; async model tests cannot qualify this stack. |
| [DiagnosticReportTests](../../desktop/Macseed/Tests/DiagnosticReportTests.swift) | 30.776 | 1.263 | Immutable report/UTF-8, allowlisted privacy, async reads, snapshot/cancellation/close lifecycle and bounded report size. KEEP; viewer integration is separate. |
| [OperationLogViewTests](../../desktop/Macseed/Tests/OperationLogViewTests.swift) | 35.289 | 170.601 | Native table/history paging, selected-log report, close/switch/large details, keyboard/layout/scroll and runtime stop ownership. KEEP despite cost; storage checks do not cover AppKit transactions. |
| [OperationLogTests](../../desktop/Macseed/Tests/OperationLogTests.swift) | 10.193 | 5.776 | Safe structured event serialization, disk permissions/retention/caps, crash recovery, corrupted input and actual runtime/cancellation persistence. KEEP; original small compilation set retained. |
| [CoreRuntimeTests](../../desktop/Macseed/Tests/CoreRuntimeTests.swift) | 7.397 | 25.138 | Strict JSONL/event lifecycle, request/env/fd/secure challenge transport, real child exit/EOF, cancellation and escalation; actual production Core capability/inspection adapter. KEEP; original small compilation set retained. |
| [EnvironmentStatusTests](../../desktop/Macseed/Tests/EnvironmentStatusTests.swift) | 48.624 | 83.682 | Comparison/verification projections, grouped taxonomy/partial coverage, native layouts, saved-file Secure Check challenge/state/binding/privacy and real read-only Core comparison. KEEP. |
| [CaptureTests](../../desktop/Macseed/Tests/CaptureTests.swift) | 65.071 | 1260.067 | Model selection/errors/results + native fixture routes; full collector integration, Workspace role/dependency and provider overlap, bundled crypto/secret transport and publication. OPTIMIZE two later collector fixtures; no security scenario removed. |
| [RestoreTests](../../desktop/Macseed/Tests/RestoreTests.swift) | 303.512 | 14.848 | Decoder/evidence/selection and state machine, secure/SSH focused routes, mock transport result/cancel/ownership and production Bundle Prepare. MERGE repeated constant groups across modes; unique workflow assertions KEEP. |
| RestoreTests `--final-restore-ux-only --no-renders` | reused executable | 6.037 | KEEP: distinct large selection/result fixture, ordinary/secure availability and final-state/action scope. Four repeated constant groups MERGE into standard run. |
| RestoreTests `--assisted-appstore-only --no-renders` | reused executable | 7.718 | KEEP: dedicated manual provider navigation, Refresh cancellation/ownership, scope restoration and failed rechecks. Four repeated constant groups MERGE into standard run. |

### Standalone scripts, diagnostic entrypoints and helpers

| Entrypoint/helper | Classification, invocation and retained value |
| --- | --- |
| `scripts/test-homebrew-graceful-stop.py` (23 methods) | KEEP, **outside Full CI**. Native admission/postchecks, repeated Stop/races/channel loss, other domains, actual consumers and publication checkpoints. Existing TODO already records the missing canonical gate. Do not call these redundant just because item-stall tests exist. |
| `scripts/test-restore-cancellation-mocks.py` (10 methods) | KEEP, standalone diagnostic. Owned plain/child/TERM-ignoring/remembered-detached trees, denied observation/kill and explicit detached-before-first-scan limitation. Some overlap with runner/reliability cases, but coverage is not identical; no removal without per-boundary consolidation. |
| `scripts/test-external-ssh-identities.py` (10 methods) | KEEP, **outside Full CI**. External source type/pair/path/link/owner/mode/count/case-collision and operation-bound private control-file validation. Unique producer safety coverage; recommend a separately validated canonical admission. |
| `desktop/Macseed/Tests/BundledAgeTests.py` (9 methods) | KEEP, **outside Full CI**. Pinned archive/license, installation/cache/archive rejection, path/link substitution, settings inspector and CLI fallback contracts. SettingsTests/Secure Capture cover consumers, not every archive producer negative. |
| `desktop/Macseed/Tests/ExternalIdentityTests.swift` | KEEP, standalone native external-identity integration, real encrypted Capture → selected Rebuild → verification/no-op, secure channels, changed/cancelled inputs and private logs. `--legacy-only` is a compatibility route, not dead historical code. Not compiled by the 12-suite runner. |
| `scripts/test-homebrew-startup.py` | QUALIFICATION ONLY. Explicit real Debug-app GUI startup, windows/focus/keyboard/geometry/package/UX-polish modes; owns its app, reports and cleanup. Needs unlocked GUI/accessibility context and can produce screenshots. Not suitable for silently adding to every checkpoint. |
| `scripts/workspace_fixture.py` | KEEP shared fixture generator: small native Git objects/index/worktree metadata; consumers use real Git readers/mutators. No fixture-state cache. |
| `scripts/fixtures/restore-cancellation-process.py` | KEEP helper for standalone cancellation diagnostics; creates controlled descendant/session/TERM behaviors, never a test inventory entry by itself. |
| `desktop/Macseed/Tests/SecureRestoreFixture.py` | KEEP disposable Core/HOME/tool/key/Bundle generator for secure/native tests; passphrase/private transport separate from ordinary JSON/argv. Export/rebuild cases own cleanup. |
| `desktop/Macseed/Tests/Fixtures/HomebrewPackageTrust.json` | KEEP pinned trust-evidence fixture used by HomebrewPackageTests. Not generated test output. |
| `scripts/test.sh`, `test_runner.py`, `test_unittest.py`, `test-timings.json` | KEEP canonical inventory, deterministic scheduling, exact completion/exit semantics and typed safe timings. Only weights and the existing stage regression change. |
| `scripts/desktop_test_runner.py`, `desktop/Macseed/build.sh` | KEEP ownership/deadline supervisor and canonical build/test inventory. OPTIMIZE Debug compilation only; app/Release and all mandatory invocations retained. |
| `.github/workflows/ci.yml`, `scripts/lint.sh` | KEEP unchanged mandatory lint, four Core shards, Desktop and always-run aggregate. No Fast/Full split or gate suppression. |

All tracked `test-*`, `Tests/*`, fixture and runner paths were reconciled with
`git ls-files` and their call sites. No unreferenced static Swift check function was
found (protocol requirements such as `reduce` are not dead-code candidates).
There is no claim that every focused selector runs in the default suite. The
52 standalone Python methods, external native harness and real-GUI startup modes
remain outside #161; no green status is inferred for them. Existing documentation
already owns the Graceful Stop/cancellation gap; this report additionally identifies
the external-identity and bundled-age producer gaps. Their new mandatory scheduling
is deferred rather than silently expanding this performance checkpoint.


### Python method ledger

Every method below was examined through its source, calls/assertions and group
boundary. The method name identifies its specific positive/negative scenario; the
suite table supplies its feature, architecture layer and overlapping owners.
Times include setup/body/cleanup from #161. `—` means absent from #161, not zero.
KEEP retains the entire method, including all loops/subtests and unique assertions,
except the explicitly documented screenshot consolidation (OPTIMIZE).

<details>
<summary>desktop/Macseed/Tests/BundledAgeTests.py — 9 methods; outside Full CI</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `BundledAgeTests.test_pinned_archives_and_license` | — | KEEP |
| `BundledAgeTests.test_external_absent_fake_or_different_never_selected` | — | KEEP |
| `BundledAgeTests.test_missing_corrupt_and_mode_fail_closed` | — | KEEP |
| `BundledAgeTests.test_links_and_path_substitution_fail_closed` | — | KEEP |
| `BundledAgeTests.test_cache_reuse_and_invalid_cache_rejected` | — | KEEP |
| `BundledAgeTests.test_archive_extra_traversal_duplicate_and_links_rejected` | — | KEEP |
| `BundledAgeTests.test_settings_diagnostic_identity_and_read_only` | — | KEEP |
| `BundledAgeTests.test_settings_failures_share_runtime_boundary` | — | KEEP |
| `BundledAgeTests.test_cli_keeps_path_resolution` | — | KEEP |

</details>

<details>
<summary>scripts/test-bootstrap-bundle.py — 68 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `BundleTests.test_ssh_snapshot_versions_and_bundle_capability` | 0.013 | KEEP |
| `BundleTests.test_ssh_snapshot_malformed_or_misversioned_payload_is_rejected` | 0.009 | KEEP |
| `BundleTests.test_portable_paths_and_selected_allowlist` | 0.006 | KEEP |
| `BundleTests.test_windows_expansion_preserves_legacy_bundles` | 0.020 | KEEP |
| `BundleTests.test_screenshot_booleans_preserve_location_and_legacy_bundles` | 0.026 | KEEP |
| `BundleTests.test_unselected_inventory_is_not_carried` | 0.004 | KEEP |
| `BundleTests.test_complete_inventory_keeps_excluded_items_for_comparison` | 0.009 | KEEP |
| `BundleTests.test_invalid_completeness_marker_rejected` | 0.003 | KEEP |
| `BundleTests.test_unselected_complete_inventories_omitted_and_legacy_bundle_readable` | 0.017 | KEEP |
| `BundleTests.test_partially_selected_complete_inventories_remain_full` | 0.008 | KEEP |
| `BundleTests.test_unselected_completeness_does_not_hide_unsafe_or_stale_input` | 0.012 | KEEP |
| `BundleTests.test_only_selected_git_values_are_carried` | 0.060 | KEEP |
| `BundleTests.test_staged_capture_keeps_working_blueprint` | 0.009 | KEEP |
| `BundleTests.test_secure_payload_stays_opaque_and_outside_generated` | 0.006 | KEEP |
| `BundleTests.test_cancel_before_publication_preserves_staging` | 0.090 | KEEP |
| `BundleTests.test_external_screenshot_rejected` | 0.003 | KEEP |
| `BundleTests.test_external_repository_rejected` | 0.003 | KEEP |
| `BundleTests.test_integrity_and_malformed_archive` | 0.018 | KEEP |
| `BundleTests.test_narrow_only_removes` | 0.004 | KEEP |
| `BundleTests.test_restore_groups_cover_every_transferable_scope` | 0.003 | KEEP |
| `BundleTests.test_vscode_settings_can_be_disabled_without_expanding_source_selection` | 0.004 | KEEP |
| `BundleTests.test_restore_menu_disables_vscode_settings` | 0.334 | KEEP |
| `BundleTests.test_summary_lists_selected_states_without_aggregation` | 0.006 | KEEP |
| `BundleTests.test_publication_failure_and_interrupted_recovery` | 0.032 | KEEP |
| `BundleTests.test_each_publication_rename_failure_restores_pair` | 0.030 | KEEP |
| `BundleTests.test_completion_marker_failure_restores_previous_pair` | 0.013 | KEEP |
| `BundleTests.test_marker_before_first_rename_and_changed_state` | 0.006 | KEEP |
| `BundleTests.test_restore_stages_preview_then_publishes_for_bootstrap` | 1.324 | KEEP |
| `BundleTests.test_apply_gate_to_real_secure_import_in_isolated_home` | 5.951 | KEEP |
| `BundleTests.test_integrated_capture_unlocks_selected_key_once` | 3.336 | KEEP |
| `BundleTests.test_restore_preview_plans_missing_homebrew_only_in_context` | 0.080 | KEEP |
| `TopologyTests.test_schema_multiple_worktrees_duplicate_basenames_and_stable_ids` | 0.340 | KEEP |
| `TopologyTests.test_named_and_detached_heads_do_not_relax_legacy_consumer` | 0.663 | KEEP |
| `TopologyTests.test_missing_unselected_base_and_selection_narrowing` | 1.758 | KEEP |
| `TopologyTests.test_paths_roots_nested_dependencies_and_aliases` | 0.849 | KEEP |
| `TopologyTests.test_target_filesystem_aliases_errors_and_no_mutation` | 0.003 | KEEP |
| `TopologyTests.test_folder_checkout_roles_remain_in_selected_bundle` | 0.958 | KEEP |
| `TopologyTests.test_folder_structure_does_not_require_unselected_git_dependencies` | 1.104 | KEEP |
| `TopologyTests.test_role_overlap_does_not_mask_real_destination_conflicts` | 0.283 | KEEP |
| `TopologyTests.test_role_overlap_keeps_filesystem_alias_and_symlink_guards` | 0.379 | KEEP |
| `TopologyTests.test_malformed_topology_no_secret_or_machine_fields` | 0.917 | KEEP |
| `TopologyTests.test_sectional_values_are_data_and_missing_git_cannot_prompt` | 0.620 | KEEP |
| `TopologyTests.test_topology_markers_cannot_downgrade_to_legacy` | 0.022 | KEEP |
| `TopologyTests.test_bundle_v1_extension_checksums_capabilities_and_old_allowlist` | 0.696 | KEEP |
| `TopologyTests.test_required_capabilities_and_limits_are_enforced` | 0.902 | KEEP |
| `TopologyTests.test_runtime_unpack_inspect_publish_and_grouped_publication_remain_closed` | 0.904 | KEEP |
| `TopologyTests.test_protocol_allows_preview_but_rejects_stale_identity_before_target_mutation` | 7.802 | KEEP |
| `TopologyTests.test_invalid_pack_preserves_output_and_existing_state` | 0.663 | KEEP |
| `TopologyTests.test_vscode_relationships_are_separately_selected_and_metadata_only` | 1.253 | KEEP |
| `TopologyTests.test_vscode_folder_only_capability_and_no_implicit_selection` | 0.016 | KEEP |
| `TopologyTests.test_legacy_blueprint_and_sectional_selection_are_unchanged` | 0.021 | KEEP |
| `TopologyTests.test_git_capability_detection_never_guesses_support_from_version` | 0.005 | KEEP |
| `WorkspaceDiscoveryTests.test_discovery_blueprint_cli_preview_preserves_ordinary_repository_actions` | 7.665 | KEEP |
| `WorkspaceDiscoveryTests.test_cli_linked_topology_refuses_before_any_workspace_mutation` | 6.342 | KEEP |
| `WorkspaceDiscoveryTests.test_cli_topology_admission_keeps_schema_and_target_guards` | 3.602 | KEEP |
| `WorkspaceDiscoveryTests.test_descriptor_missing_folder_preserves_valid_independent_metadata` | 1.269 | KEEP |
| `WorkspaceDiscoveryTests.test_descriptor_access_failure_preserves_previous_grouped_snapshot` | 1.535 | KEEP |
| `WorkspaceDiscoveryTests.test_descriptor_unstable_or_lost_observation_is_not_missing_folder` | 0.389 | KEEP |
| `WorkspaceDiscoveryTests.test_native_topology_duplicate_nested_detached_and_no_mutation` | 1.488 | KEEP |
| `WorkspaceDiscoveryTests.test_unsafe_origins_filters_and_unborn_repositories_are_excluded` | 0.676 | KEEP |
| `WorkspaceDiscoveryTests.test_ssh_origin_and_observation_errors_are_distinct_from_absence` | 0.373 | KEEP |
| `WorkspaceDiscoveryTests.test_independent_equal_origins_full_and_partial_bundle_roundtrip` | 4.594 | KEEP |
| `WorkspaceDiscoveryTests.test_locked_missing_prunable_and_external_groups_are_not_flattened` | 0.511 | KEEP |
| `WorkspaceDiscoveryTests.test_missing_base_and_gitfile_external_are_unsupported` | 0.018 | KEEP |
| `WorkspaceDiscoveryTests.test_capabilities_and_malformed_porcelain_fail_closed` | 0.072 | KEEP |
| `WorkspaceDiscoveryTests.test_safe_roots_symlinks_and_observation_failure` | 0.988 | KEEP |
| `WorkspaceDiscoveryTests.test_remote_privacy_and_jsonc_folder_relationships_only` | 0.390 | KEEP |
| `WorkspaceDiscoveryTests.test_group_publication_rollback_and_optional_sidecar_retirement` | 6.752 | KEEP |

</details>

<details>
<summary>scripts/test-bundle-publication-safety.py — 9 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `PublicationSafetyTests.test_preparation_and_each_publication_step_recover_then_retry` | 0.440 | KEEP |
| `PublicationSafetyTests.test_interruption_before_marker_has_no_prepared_state` | 0.087 | KEEP |
| `PublicationSafetyTests.test_committed_publication_survives_interrupted_cleanup` | 0.069 | KEEP |
| `PublicationSafetyTests.test_unrelated_prepared_names_survive_publication_and_recovery` | 0.066 | KEEP |
| `PublicationSafetyTests.test_unexpected_recovery_entry_is_preserved_for_manual_review` | 0.076 | KEEP |
| `PublicationSafetyTests.test_legacy_pre_marker_state_retries_without_deleting_unproven_paths` | 0.004 | KEEP |
| `TarHeaderSafetyTests.test_negative_and_signed_sizes_terminate` | 0.125 | KEEP |
| `TarHeaderSafetyTests.test_nonoctal_and_empty_sizes_terminate` | 0.181 | KEEP |
| `TarHeaderSafetyTests.test_entry_count_and_size_are_bounded_during_raw_scan` | 0.182 | KEEP |

</details>

<details>
<summary>scripts/test-capture-api.py — 42 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `CaptureTests.test_ssh_host_capture_subset_full_empty_and_readonly_check` | 117.717 | KEEP |
| `CaptureTests.test_ssh_host_capture_partial_coverage_and_v2_preserved` | 31.289 | KEEP |
| `CaptureTests.test_ssh_host_capture_stale_ids_scope_and_ambiguous_source` | 116.785 | KEEP |
| `CaptureTests.test_inventory_absence_error_privacy_and_determinism` | 25.150 | KEEP |
| `CaptureTests.test_app_identity_and_safe_display_label` | 14.974 | KEEP |
| `CaptureTests.test_unselected_application_inventories_not_saved` | 21.519 | KEEP |
| `CaptureTests.test_partial_app_store_capture_retains_comparison_inventory` | 25.940 | KEEP |
| `CaptureTests.test_stale_ice_capture_with_installed_thaw` | 86.269 | KEEP |
| `CaptureTests.test_overlap_prepare_execute_and_effective_publication` | 39.640 | KEEP |
| `CaptureTests.test_overlap_without_evidence_preserves_both_requirements` | 30.214 | KEEP |
| `CaptureTests.test_overlap_changed_decision_rejects_before_publication` | 27.862 | KEEP |
| `CaptureTests.test_overlap_explicit_subset_and_appstore_only` | 31.478 | KEEP |
| `CaptureTests.test_workspace_folders_success_is_selectable` | 26.124 | KEEP |
| `CaptureTests.test_git_repositories_success_is_selectable` | 28.480 | KEEP |
| `CaptureTests.test_vscode_descriptors_selected_metadata_only_and_legacy_omission` | 118.843 | KEEP |
| `CaptureTests.test_role_overlap_both_selected_publish_and_inspect` | 42.458 | KEEP |
| `CaptureTests.test_role_overlap_folder_only_publish_and_inspect` | 43.710 | KEEP |
| `CaptureTests.test_role_overlap_git_only_publish_and_inspect` | 66.239 | KEEP |
| `CaptureTests.test_role_overlap_neither_selected_publish_and_inspect` | 49.053 | KEEP |
| `CaptureTests.test_review_destination_fresh_prepare_workspace_selection_matrix` | 63.318 | KEEP |
| `CaptureTests.test_review_conflicts_are_typed_and_explicit_correction_prepares` | 54.030 | KEEP |
| `CaptureTests.test_missing_staged_input_is_not_a_workspace_selection_conflict` | 0.104 | KEEP |
| `CaptureTests.test_workspace_observation_failure_remains_non_selectable` | 37.838 | KEEP |
| `CaptureTests.test_topology_capture_full_partial_dependencies_and_restore_block` | 102.928 | KEEP |
| `CaptureTests.test_topology_git_capability_is_explicitly_unsupported` | 12.691 | KEEP |
| `CaptureTests.test_invalid_selection_and_unavailable_rejection` | 48.461 | KEEP |
| `CaptureTests.test_malformed_observed_inventory_is_not_selectable` | 16.447 | KEEP |
| `CaptureTests.test_bundle_publication_validation_and_restore` | 32.533 | KEEP |
| `CaptureTests.test_stale_and_failure_leave_no_bundle` | 29.049 | KEEP |
| `CaptureTests.test_item_subset_blueprint_projection` | 21.420 | KEEP |
| `CaptureTests.test_production_scan_private_values_not_exposed` | 16.975 | KEEP |
| `CaptureTests.test_macos27_optional_preferences_capture` | 16.610 | KEEP |
| `CaptureTests.test_macos_metadata_does_not_change_prepared_identity` | 0.173 | KEEP |
| `CaptureTests.test_window_manager_included_settings_only_observed` | 37.530 | KEEP |
| `CaptureTests.test_macos_included_settings_are_effective_value_free_metadata` | 244.372 | KEEP |
| `CaptureTests.test_cancellation_cleanup_and_no_terminal_input` | 3.816 | KEEP |
| `CaptureTests.test_secure_source_stamp_stale` | 33.773 | KEEP |
| `CaptureTests.test_empty_scope_and_unsafe_destination` | 33.876 | KEEP |
| `CaptureTests.test_secure_metadata_and_missing_channel` | 28.960 | KEEP |
| `CaptureTests.test_secure_capture_and_protected_unlock` | 40.404 | KEEP |
| `CaptureTests.test_secure_capture_without_key_unlock` | 31.542 | KEEP |
| `CaptureTests.test_secure_cancel_does_not_publish` | 41.392 | KEEP |

</details>

<details>
<summary>scripts/test-core-application-interface.py — 5 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `CoreInterfaceTests.test_capabilities` | 0.146 | KEEP |
| `CoreInterfaceTests.test_invalid_requests` | 1.569 | KEEP |
| `CoreInterfaceTests.test_human_cli_unchanged` | 0.243 | KEEP |
| `CoreInterfaceTests.test_bundle_inspect` | 1.054 | KEEP |
| `CoreInterfaceTests.test_bundle_request_validation` | 0.565 | KEEP |

</details>

<details>
<summary>scripts/test-environment-compare.py — 58 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `SSHMergeTests.test_merge_preserves_bytes_behavior_metadata_and_repeat` | 0.057 | KEEP |
| `SSHMergeTests.test_multiple_missing_with_existing_match_and_comments_only` | 0.001 | KEEP |
| `SSHMergeTests.test_conflicting_ambiguous_and_unsupported_profiles_refused` | 0.001 | KEEP |
| `SSHMergeTests.test_links_permissions_ownership_acl_and_metadata_refused` | 0.035 | KEEP |
| `SSHMergeTests.test_unsafe_ancestor_and_unqualified_filesystem_refused` | 0.013 | KEEP |
| `SSHMergeTests.test_stale_bytes_and_identical_inode_replacement_refused` | 0.013 | KEEP |
| `SSHMergeTests.test_publication_failure_retains_predecessor_and_blocks_retry` | 0.020 | KEEP |
| `SSHMergeTests.test_staging_failure_retains_pending_without_touching_config` | 0.014 | KEEP |
| `SSHMergeTests.test_last_gap_directory_replacement_preserves_both_locations` | 0.026 | KEEP |
| `SSHMergeTests.test_last_gap_edit_is_retained_and_never_rolled_back` | 0.017 | KEEP |
| `SSHMergeTests.test_interruption_after_swap_retains_actual_predecessor` | 0.064 | KEEP |
| `CompareTests.test_ssh_supported_profile_conformity` | 12.805 | KEEP |
| `CompareTests.test_ssh_case_variant_aliases_remain_unverified` | 14.530 | KEEP |
| `CompareTests.test_ssh_partial_coverage_remains_incomplete` | 2.964 | KEEP |
| `CompareTests.test_ssh_v2_references_are_not_identity_evidence` | 3.178 | KEEP |
| `CompareTests.test_ssh_none_and_unsupported_target_coverage` | 2.845 | KEEP |
| `CompareTests.test_ssh_merge_and_uncertain_publication_check` | 2.914 | KEEP |
| `CompareTests.test_bundle_reference_selection_and_read_only` | 10.860 | KEEP |
| `CompareTests.test_bundle_app_store_presentation_names` | 1.639 | KEEP |
| `CompareTests.test_telegram_cask_does_not_satisfy_selected_app_store_requirement` | 4.435 | KEEP |
| `CompareTests.test_bundle_repository_display_labels_keep_diagnostics_private` | 2.906 | KEEP |
| `CompareTests.test_bundle_macos_labels_reuse_capture_definitions` | 1.869 | KEEP |
| `CompareTests.test_bundle_invalid_unsafe_and_changed` | 2.597 | KEEP |
| `CompareTests.test_bundle_cancellation_cleanup` | 2.436 | KEEP |
| `CompareTests.test_cancel_during_bundle_validation` | 1.889 | KEEP |
| `CompareTests.test_cancel_cleanup_error_is_not_bundle_unavailable` | 0.933 | KEEP |
| `CompareTests.test_cancel_descendant_kill_denied` | 2.795 | KEEP |
| `CompareTests.test_cancel_does_not_hide_source_error` | 0.808 | KEEP |
| `CompareTests.test_matching_and_projections` | 1.468 | KEEP |
| `CompareTests.test_missing` | 1.501 | KEEP |
| `CompareTests.test_differing_and_sensitive_contents` | 1.614 | KEEP |
| `CompareTests.test_observation_failure_is_unverified` | 1.501 | KEEP |
| `CompareTests.test_unresolved_selection` | 1.351 | KEEP |
| `CompareTests.test_invalid_reference` | 0.743 | KEEP |
| `CompareTests.test_invalid_domain_input` | 1.352 | KEEP |
| `CompareTests.test_unavailable_and_request_validation` | 0.436 | KEEP |
| `CompareTests.test_extra_provenance` | 5.659 | KEEP |
| `CompareTests.test_determinism_and_bounds` | 2.921 | KEEP |
| `CompareTests.test_invalid_and_truncated_reporting_fails_closed` | 0.528 | KEEP |
| `CompareTests.test_cancellation_owned_group` | 0.664 | KEEP |
| `CompareTests.test_cancellation_stops_term_ignoring_grandchild` | 1.808 | KEEP |
| `CompareTests.test_production_operation_support_and_unknown_difference` | 1.534 | KEEP |
| `CompareTests.test_git_identity_privacy` | 2.024 | KEEP |
| `CompareTests.test_empty_scope_and_explicit_no_blueprint` | 3.099 | KEEP |
| `CompareTests.test_cli_compatibility` | 0.510 | KEEP |
| `TopologyCompareTests.test_matching_privacy_stable_identities_and_counts` | 14.912 | KEEP |
| `TopologyCompareTests.test_missing_base_does_not_match_dependents` | 3.089 | KEEP |
| `TopologyCompareTests.test_missing_linked_and_independent_clone_relationship` | 13.334 | KEEP |
| `TopologyCompareTests.test_origin_and_head_differences_are_not_missing` | 16.165 | KEEP |
| `TopologyCompareTests.test_nested_checkout_dependency` | 14.738 | KEEP |
| `TopologyCompareTests.test_descriptor_match_missing_difference_and_dependency` | 21.872 | KEEP |
| `TopologyCompareTests.test_descriptor_folder_only_and_symlink_conflict` | 7.279 | KEEP |
| `TopologyCompareTests.test_capability_and_observation_failures` | 7.099 | KEEP |
| `TopologyCompareTests.test_changed_evidence_never_retains_match_or_difference` | 0.438 | KEEP |
| `TopologyCompareTests.test_live_changed_observation_and_locked_metadata` | 7.884 | KEEP |
| `TopologyCompareTests.test_non_git_destination_and_symlink_never_match` | 8.642 | KEEP |
| `TopologyCompareTests.test_changed_bundle_and_stage_cannot_publish_results` | 7.768 | KEEP |
| `TopologyCompareTests.test_invalid_dependency_payload_rejected_before_observation` | 1.232 | KEEP |

</details>

<details>
<summary>scripts/test-external-process-reliability.py — 26 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `ReliabilityTests.test_real_clone_success_selected_branch_and_no_clobber` | 0.506 | KEEP |
| `ReliabilityTests.test_progress_counts_and_long_work_within_budget` | 0.763 | KEEP |
| `ReliabilityTests.test_clone_ssh_identity_admission_and_typed_native_failure` | 0.740 | KEEP |
| `ReliabilityTests.test_macos_read_batch_matches_scalar_and_refreshes_before_apply` | 3.806 | KEEP |
| `ReliabilityTests.test_deadline_partial_clone_and_no_progress_are_distinct` | 0.947 | KEEP |
| `ReliabilityTests.test_cancel_and_root_exit_worker_have_owned_bounded_cleanup` | 0.606 | KEEP |
| `ReliabilityTests.test_unconfirmed_quiescence_and_state_failure_deny_reentry` | 0.296 | KEEP |
| `ReliabilityTests.test_confirmed_clone_cleanup_runs_once_before_verification` | 0.274 | KEEP |
| `ReliabilityTests.test_failed_clone_cleanup_stays_unknown_after_successful_retry` | 0.327 | KEEP |
| `ReliabilityTests.test_confirmed_clone_tree_still_requires_pipe_eof` | 0.219 | KEEP |
| `ReliabilityTests.test_sigterm_cancellation_kills_term_ignoring_descendant` | 1.717 | KEEP |
| `ReliabilityTests.test_write_ahead_failure_and_crash_keep_launch_or_reentry_blocked` | 0.253 | KEEP |
| `ReliabilityTests.test_observation_exit_read_preserves_bytes_limits_and_fresh_scans` | 0.012 | KEEP |
| `ReliabilityTests.test_observation_completion_failure_retains_unknown_and_final_eof` | 0.215 | KEEP |
| `ReliabilityTests.test_observation_root_exit_and_sigterm_clean_term_ignoring_pipe_worker` | 3.360 | KEEP |
| `ReliabilityTests.test_observation_deadline_pipe_worker_and_no_home_writes` | 3.896 | KEEP |
| `ReliabilityTests.test_homebrew_observation_disables_detached_analytics_per_read` | 0.123 | KEEP |
| `ReliabilityTests.test_observation_failure_projection_preserves_layer_not_private_output` | 0.328 | KEEP |
| `ReliabilityTests.test_observation_failure_is_not_empty_success_or_permission_to_mutate` | 0.898 | KEEP |
| `ReliabilityTests.test_watchdog_kernel_wait_is_bounded` | 0.163 | KEEP |
| `ReliabilityTests.test_production_execute_failure_continues_independent_and_verifies` | 44.740 | KEEP |
| `ReliabilityTests.test_unknown_blocks_execute_even_without_git_selection` | 3.685 | KEEP |
| `ReliabilityTests.test_external_admission_write_failure_prevents_mutation` | 3.799 | KEEP |
| `ReliabilityTests.test_external_parent_crash_after_mutation_blocks_fresh_execute` | 8.474 | KEEP |
| `ReliabilityTests.test_external_completion_ownership_and_read_only_routes` | 19.015 | KEEP |
| `ReliabilityTests.test_read_only_vscode_routing_preserves_snapshot_and_error` | 0.668 | KEEP |

</details>

<details>
<summary>scripts/test-external-ssh-identities.py — 10 methods; outside Full CI</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `ExternalIdentityTests.test_supported_types_and_source_scope` | — | KEEP |
| `ExternalIdentityTests.test_missing_public_pair` | — | KEEP |
| `ExternalIdentityTests.test_mismatched_or_unsupported_pair` | — | KEEP |
| `ExternalIdentityTests.test_symlink_hardlink_and_fifo` | — | KEEP |
| `ExternalIdentityTests.test_unsafe_modes_and_parent` | — | KEEP |
| `ExternalIdentityTests.test_parent_alias_and_traversal` | — | KEEP |
| `ExternalIdentityTests.test_size_name_and_public_selection_limits` | — | KEEP |
| `ExternalIdentityTests.test_control_is_operation_bound_and_count_bounded` | — | KEEP |
| `ExternalIdentityTests.test_case_insensitive_destination_collision` | — | KEEP |
| `ExternalIdentityTests.test_private_reference_file_safety` | — | KEEP |

</details>

<details>
<summary>scripts/test-external-tools.py — 8 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `ExternalToolTests.test_supported_capabilities_formula_and_cask_states` | 3.225 | KEEP |
| `ExternalToolTests.test_unknown_and_malformed_metadata_fail_closed` | 2.943 | KEEP |
| `ExternalToolTests.test_capability_missing_and_tool_unavailable` | 0.299 | KEEP |
| `ExternalToolTests.test_failed_observation_cannot_reuse_previous_satisfied_state` | 0.593 | KEEP |
| `ExternalToolTests.test_launchctl_absent_is_repairable_job_file_error_block` | 10.968 | KEEP |
| `ExternalToolTests.test_launchctl_label_grammar_and_receipt_mismatch` | 1.507 | KEEP |
| `ExternalToolTests.test_launchctl_reobserved_after_dependencies_blocks_mutation` | 20.851 | KEEP |
| `ExternalToolTests.test_bundle_provenance_optional_and_version_not_a_gate` | 13.313 | KEEP |

</details>

<details>
<summary>scripts/test-homebrew-capabilities.py — 86 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `CapabilityTests.test_metadata_batch_requires_complete_unique_selected_scope` | 0.250 | KEEP |
| `CapabilityTests.test_appstore_marker_blocks_registered_cask_without_claiming_ownership` | 0.010 | KEEP |
| `CapabilityTests.test_provider_change_invalidates_existing_reinstall_qualification` | 0.008 | KEEP |
| `CapabilityTests.test_rosetta_prerequisite_states_and_refresh` | 0.015 | KEEP |
| `CapabilityTests.test_rosetta_observation_failures_and_unrequired_cask` | 0.006 | KEEP |
| `CapabilityTests.test_generated_completion_capture_native_install_verify_repeat` | 0.071 | KEEP |
| `CapabilityTests.test_generated_completion_damage_and_foreign_outputs_fail_closed` | 0.015 | KEEP |
| `CapabilityTests.test_generated_completion_command_shell_integrity_boundaries` | 0.003 | KEEP |
| `CapabilityTests.test_generated_completion_evolution_binds_arguments_and_targets` | 0.010 | KEEP |
| `CapabilityTests.test_nonempty_requirements_registration_not_payload` | 0.005 | KEEP |
| `CapabilityTests.test_invalid_empty_bundle_and_foreign_destination` | 0.005 | KEEP |
| `CapabilityTests.test_current_quit_evolution_and_inactive_zap` | 0.004 | KEEP |
| `CapabilityTests.test_payload_identity_change_does_not_authorize_old_removal` | 0.006 | KEEP |
| `CapabilityTests.test_links_wrappers_and_static_ancillary_files` | 0.008 | KEEP |
| `CapabilityTests.test_relocated_payload_classes` | 0.008 | KEEP |
| `CapabilityTests.test_static_links_suite_and_relocated_file_verification` | 0.035 | KEEP |
| `CapabilityTests.test_package_local_evidence_never_downloads_during_classification` | 0.011 | KEEP |
| `CapabilityTests.test_pkg_explicit_consent_preparation_reuse_and_invalidation` | 0.013 | KEEP |
| `CapabilityTests.test_pkg_consent_only_prepares_listed_current_installers` | 0.012 | KEEP |
| `CapabilityTests.test_pkg_preparation_storage_rejects_foreign_links_and_special_files` | 0.007 | KEEP |
| `CapabilityTests.test_pkg_incomplete_capture_preserves_receipt_identity` | 0.020 | KEEP |
| `CapabilityTests.test_pkg_preparation_does_not_expand_repair_or_opaque_profiles` | 0.020 | KEEP |
| `CapabilityTests.test_performance_external_timing_is_private_and_observational` | 0.003 | KEEP |
| `CapabilityTests.test_public_native_package_inspection_binds_checksum_identity_and_target` | 0.114 | KEEP |
| `CapabilityTests.test_native_package_caveats_clean_install_and_repair_are_distinct` | 0.010 | KEEP |
| `CapabilityTests.test_native_package_clean_install_rejects_receipts_and_delete_residuals` | 0.009 | KEEP |
| `CapabilityTests.test_absent_package_install_does_not_require_repair_cleanup_capability` | 0.011 | KEEP |
| `CapabilityTests.test_native_package_verification_cannot_satisfy_receipt_only` | 0.003 | KEEP |
| `CapabilityTests.test_pkg_repair_legacy_receipt_ownership_and_caveats` | 0.006 | KEEP |
| `CapabilityTests.test_pkg_repair_manifest_and_missing_app` | 0.018 | KEEP |
| `CapabilityTests.test_pkg_repair_rejects_modified_or_replaced_component` | 0.008 | KEEP |
| `CapabilityTests.test_pkg_repair_rejects_stale_source_metadata_and_receipts` | 0.011 | KEEP |
| `CapabilityTests.test_pkg_repair_legacy_unreceipted_wrapper_is_not_adopted` | 0.016 | KEEP |
| `CapabilityTests.test_pkg_repair_caveats_do_not_allow_unknown_lifecycle` | 0.005 | KEEP |
| `CapabilityTests.test_package_receipt_plus_real_payload_and_repair` | 0.008 | KEEP |
| `CapabilityTests.test_payload_observation_is_independent_of_unsafe_cleanup` | 0.038 | KEEP |
| `CapabilityTests.test_package_components_share_one_required_app` | 0.003 | KEEP |
| `CapabilityTests.test_package_fresh_install_and_missing_shared_receipt` | 0.006 | KEEP |
| `CapabilityTests.test_captured_package_fresh_install_has_payload_postconditions` | 0.010 | KEEP |
| `CapabilityTests.test_exact_cleanup_and_authorization_separate_from_support` | 0.010 | KEEP |
| `CapabilityTests.test_service_and_login_item_fail_closed` | 0.009 | KEEP |
| `CapabilityTests.test_public_service_evidence_matches_loaded_program` | 0.014 | KEEP |
| `CapabilityTests.test_launchctl_missing_and_declared_owned_orphan` | 0.043 | KEEP |
| `CapabilityTests.test_launchctl_foreign_conflicting_plist_and_live_orphans` | 0.014 | KEEP |
| `CapabilityTests.test_launchctl_ambiguous_domains_and_malformed_evidence` | 0.004 | KEEP |
| `CapabilityTests.test_duplicate_service_plist_ownership_is_ambiguous` | 0.008 | KEEP |
| `CapabilityTests.test_launchctl_scopes_records_and_ignores_mach_endpoints_and_implicit_list` | 0.022 | KEEP |
| `CapabilityTests.test_current_only_xpc_requires_exact_native_identity_and_path` | 0.006 | KEEP |
| `CapabilityTests.test_login_item_unrelated_duplicate_does_not_poison_selected_identity` | 0.002 | KEEP |
| `CapabilityTests.test_diagnostic_contract_excludes_free_text_and_unknown_fields` | 0.003 | KEEP |
| `CapabilityTests.test_malformed_launch_inventory_cannot_mean_absence` | 0.002 | KEEP |
| `CapabilityTests.test_login_item_owned_absent_and_declared_missing_target` | 0.003 | KEEP |
| `CapabilityTests.test_login_item_foreign_duplicate_and_unproven_orphan` | 0.003 | KEEP |
| `CapabilityTests.test_login_item_metadata_evolution_and_installed_identity_binding` | 0.004 | KEEP |
| `CapabilityTests.test_login_item_authorization_and_unavailability_are_not_conflicts` | 0.007 | KEEP |
| `CapabilityTests.test_automation_never_executes_without_nonprompting_permission` | 0.022 | KEEP |
| `CapabilityTests.test_owned_dangling_link_is_repairable_foreign_link_is_conflict` | 0.004 | KEEP |
| `CapabilityTests.test_public_package_receipt_interface_and_existing_shared_files` | 0.004 | KEEP |
| `CapabilityTests.test_requirements_conflicts_integrity_and_opaque_behavior` | 0.009 | KEEP |
| `CapabilityTests.test_cask_dependencies_qualified_and_bound` | 0.009 | KEEP |
| `CapabilityTests.test_capture_requirements_and_saved_identity_fail_closed` | 0.005 | KEEP |
| `CapabilityTests.test_captured_bundle_identity_rejects_foreign_replacement` | 0.006 | KEEP |
| `CapabilityTests.test_observation_errors_are_not_absence` | 0.003 | KEEP |
| `CapabilityTests.test_native_privileged_lifecycle_success_and_unknown_quarantine` | 0.009 | KEEP |
| `CapabilityTests.test_authorization_denial_does_not_start_mutation` | 0.005 | KEEP |
| `CapabilityTests.test_changes_during_authorization_block_native_operation` | 0.010 | KEEP |
| `CapabilityTests.test_private_journal_and_credentials_boundary` | 0.006 | KEEP |
| `CapabilityTests.test_privileged_descendants_are_not_reported_quiescent` | 0.003 | KEEP |
| `CapabilityTests.test_process_stop_waits_for_kill_confirmation` | 0.002 | KEEP |
| `RestoreCapabilityTests.test_privileged_restore_native_mock_and_repeat_run` | 39.810 | KEEP |
| `RestoreCapabilityTests.test_uncertain_privileged_failure_stops_and_blocks_reentry` | 32.064 | KEEP |
| `RestoreCapabilityTests.test_provider_diagnostic_roundtrip_and_readiness_binding` | 5.741 | KEEP |
| `RestoreCapabilityTests.test_preview_and_readiness_collect_all_items_after_primitive_failure` | 9.612 | KEEP |
| `RestoreCapabilityTests.test_missing_qualification_cannot_be_replaced_by_diagnostics` | 9.353 | KEEP |
| `RestoreCapabilityTests.test_captured_capabilities_roundtrip_and_selection_validation` | 9.354 | KEEP |
| `ApplicationIdentityTests.test_positive_catalog_binding_survives_offline_without_renewal` | 0.022 | KEEP |
| `ApplicationIdentityTests.test_expired_invalid_or_unsafe_cache_cannot_suppress` | 0.021 | KEEP |
| `ApplicationIdentityTests.test_cache_write_failure_keeps_lookup_truthful_and_storage_bounded` | 0.018 | KEEP |
| `ApplicationIdentityTests.test_provider_bound_identity_not_names_or_bare_bundle_id` | 0.017 | KEEP |
| `ApplicationIdentityTests.test_single_provider_and_explicit_mas_selection_never_lookup` | 0.001 | KEEP |
| `ApplicationIdentityTests.test_ambiguous_cask_or_catalog_identity_never_suppresses` | 0.069 | KEEP |
| `ApplicationIdentityTests.test_catalog_validates_numeric_id_platform_and_uniqueness` | 0.001 | KEEP |
| `ApplicationIdentityTests.test_lookup_is_bounded_optional_and_tls_verified` | 0.002 | KEEP |
| `ApplicationIdentityTests.test_optional_metadata_invalid_types_and_excessive_nesting_are_unresolved` | 0.009 | KEEP |
| `ApplicationIdentityTests.test_legacy_qualified_evidence_is_retained_and_not_a_fallback` | 0.002 | KEEP |
| `ApplicationIdentityTests.test_capture_atomic_bundle_and_legacy_private_selection` | 0.198 | KEEP |

</details>

<details>
<summary>scripts/test-homebrew-graceful-stop.py — 23 methods; outside Full CI</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `GracefulMocks.test_before_native_launch` | — | KEEP |
| `GracefulMocks.test_cask_finishes_and_postchecks_then_no_item` | — | KEEP |
| `GracefulMocks.test_formula_finishes` | — | KEEP |
| `GracefulMocks.test_between_items_and_repeated_stop` | — | KEEP |
| `GracefulMocks.test_race` | — | KEEP |
| `GracefulMocks.test_failed_installer_retains_failure` | — | KEEP |
| `GracefulMocks.test_channel_loss_freezes_admission` | — | KEEP |
| `GracefulMocks.test_non_homebrew_scope_accepts_and_retains_stop` | — | KEEP |
| `GracefulMocks.test_scope_returns_idle_after_module` | — | KEEP |
| `GracefulMocks.test_non_homebrew_current_module_finishes_then_stops` | — | KEEP |
| `GracefulMocks.test_bootstrap_next_module_never_runs` | — | KEEP |
| `GracefulMocks.test_force_stop_during_wait` | — | KEEP |
| `GracefulMocks.test_terminal_requires_accepted_stop` | — | KEEP |
| `GracefulMocks.test_settings_checkpoint_stops_before_next_category` | — | KEEP |
| `GracefulMocks.test_settings_error_wins_and_has_scope_record` | — | KEEP |
| `GracefulMocks.test_owned_bootstrap_shares_controller_without_closing_it` | — | KEEP |
| `GracefulMocks.test_restore_preparation_stop_preserves_flags` | — | KEEP |
| `GracefulMocks.test_restore_publication_finishes_before_stop` | — | KEEP |
| `GracefulMocks.test_restore_stop_before_preparation` | — | KEEP |
| `GracefulMocks.test_real_cask_consumer_postchecks` | — | KEEP |
| `GracefulMocks.test_real_cask_consumer_failure_wins_over_stop` | — | KEEP |
| `GracefulMocks.test_real_formula_consumer_postchecks` | — | KEEP |
| `GracefulMocks.test_item_executor_actual_native_gate` | — | KEEP |

</details>

<details>
<summary>scripts/test-item-stall.py — 26 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `WatchdogTests.test_dependency_identity_validation` | 0.001 | KEEP |
| `WatchdogTests.test_no_total_runtime_limit` | 0.000 | KEEP |
| `WatchdogTests.test_completed_process_is_not_reclassified_as_stalled` | 0.489 | KEEP |
| `WatchdogTests.test_real_file_growth` | 2.504 | KEEP |
| `WatchdogTests.test_artifact_read_progress` | 1.965 | KEEP |
| `WatchdogTests.test_stall_kills_separate_group_descendant` | 1.962 | KEEP |
| `WatchdogTests.test_short_lived_parent_does_not_leave_group_child` | 0.320 | KEEP |
| `WatchdogTests.test_cancellation` | 0.827 | KEEP |
| `RestoreStallTests.test_production_cask_stall_continues_and_verifies` | 52.291 | KEEP |
| `RestoreStallTests.test_production_cask_repair_stall_continues_and_verifies` | 41.548 | KEEP |
| `RestoreStallTests.test_production_formula_dependency_is_structured_skip` | 22.115 | KEEP |
| `RestoreStallTests.test_dependency_block_and_independent_continuation` | 0.416 | KEEP |
| `FormulaQuiescenceTests.test_native_exit_zero_failure_and_timeout_retain_uncertainty` | 0.019 | KEEP |
| `FormulaQuiescenceTests.test_denied_descendant_cleanup_blocks_following_item` | 0.026 | KEEP |
| `FormulaQuiescenceTests.test_failed_cleanup_observation_is_not_safe_success` | 0.002 | KEEP |
| `FormulaQuiescenceTests.test_metadata_uncertainty_prevents_native_install` | 0.065 | KEEP |
| `FormulaQuiescenceTests.test_outer_native_uncertainty_and_confirmed_local_failures` | 0.060 | KEEP |
| `FormulaQuiescenceTests.test_core_result_and_durable_reentry_gate` | 62.865 | KEEP |
| `FormulaQuiescenceTests.test_confirmed_quiescence_preserves_success_and_independent_continuation` | 78.288 | KEEP |
| `FormulaDurabilityTests.test_missing_item_state_prevents_journal_and_launch` | 0.001 | KEEP |
| `FormulaDurabilityTests.test_persistent_prepare_failures_prevent_every_launch` | 0.057 | KEEP |
| `FormulaDurabilityTests.test_durable_state_precedes_metadata_and_native_and_safe_failures_continue` | 0.124 | KEEP |
| `FormulaDurabilityTests.test_postlaunch_uncertainty_survives_failed_updates_and_metadata_blocks_native` | 0.080 | KEEP |
| `FormulaDurabilityTests.test_unsafe_journal_paths_never_launch_or_clobber_foreign_state` | 0.021 | KEEP |
| `FormulaDurabilityTests.test_mock_chain_keeps_safe_success_and_independent_failure` | 58.354 | KEEP |
| `FormulaDurabilityTests.test_supervisor_crash_keeps_reentry_blocked_including_without_homebrew` | 9.469 | KEEP |

</details>

<details>
<summary>scripts/test-restore-cancellation-mocks.py — 10 methods; outside Full CI</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `CancellationMocks.test_01_plain` | — | KEEP |
| `CancellationMocks.test_02_child` | — | KEEP |
| `CancellationMocks.test_03_ignores_term` | — | KEEP |
| `CancellationMocks.test_04_detached_remembered` | — | KEEP |
| `CancellationMocks.test_05_denied_child_owned_cancel` | — | KEEP |
| `CancellationMocks.test_06_observer_unavailable` | — | KEEP |
| `CancellationMocks.test_09_owned_normal_cancel` | — | KEEP |
| `CancellationMocks.test_terminal_unknown_propagation` | — | KEEP |
| `CancellationMocks.test_07_detached_before_first_scan` | — | KEEP |
| `CancellationMocks.test_08_item_watchdog_cancel` | — | KEEP |

</details>

<details>
<summary>scripts/test-restore-prepare.py — 138 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `RestorePrepareTests.test_selected_prerequisite_conflict_blocks_casks_before_publication` | 12.803 | KEEP |
| `RestorePrepareTests.test_ssh_semantic_match_is_noop_without_publication` | 7.476 | KEEP |
| `RestorePrepareTests.test_ssh_merge_prepare_execute_repeat_and_stale_evidence` | 28.923 | KEEP |
| `RestorePrepareTests.test_ssh_v2_config_only_preserves_missing_reference` | 35.950 | KEEP |
| `RestorePrepareTests.test_ssh_selection_rebinds_prepared_scope_and_preserves_repairs` | 20.281 | KEEP |
| `RestorePrepareTests.test_ssh_exclusion_preserves_item_scoped_unsupported_casks` | 13.325 | KEEP |
| `RestorePrepareTests.test_selected_prerequisite_matching_partial_absent_and_unselected` | 24.987 | KEEP |
| `RestorePrepareTests.test_structured_folder_actions_and_selected_scope` | 3.335 | KEEP |
| `RestorePrepareTests.test_settings_without_unrelated_application_preflight` | 9.893 | KEEP |
| `RestorePrepareTests.test_windows_expansion_preview_is_read_only` | 2.241 | KEEP |
| `RestorePrepareTests.test_screenshot_desktop_preview_and_unqualified_target` | 10.138 | KEEP |
| `RestorePrepareTests.test_unsupported_screenshot_with_independent_readiness_domain` | 5.361 | KEEP |
| `RestorePrepareTests.test_screenshots_cross_version_matrix` | 607.590 | OPTIMIZE |
| `RestorePrepareTests.test_macos27_optional_absence_and_independent_preview` | 3.378 | KEEP |
| `RestorePrepareTests.test_screenshot_booleans_preview_is_scalar_and_read_only` | 1.782 | KEEP |
| `RestorePrepareTests.test_macos_scalar_projection_without_values_or_global_dependencies` | 5.934 | KEEP |
| `RestorePrepareTests.test_git_identity_values_redacted_and_restore_planned` | 3.285 | KEEP |
| `RestorePrepareTests.test_formula_prerequisites_and_reentry` | 29.066 | KEEP |
| `RestorePrepareTests.test_installed_homebrew_activation_is_projected_consistently` | 5.940 | KEEP |
| `RestorePrepareTests.test_repository_readiness_and_private_projection` | 5.395 | KEEP |
| `RestorePrepareTests.test_vscode_prerequisites_and_safe_resolution` | 4.036 | KEEP |
| `RestorePrepareTests.test_assisted_appstore_prepare_never_requires_authorization` | 5.367 | KEEP |
| `RestorePrepareTests.test_secure_prepare_launch_requirement_and_no_unrelated_preflight` | 2.867 | KEEP |
| `RestorePrepareTests.test_mixed_prepare_reports_independent_blockers` | 16.584 | KEEP |
| `RestorePrepareTests.test_cask_unsupported_classification_in_prepare` | 3.613 | KEEP |
| `RestorePrepareTests.test_pkg_payload_predicates_preserve_diagnostic` | 6.268 | KEEP |
| `RestorePrepareTests.test_pkg_checksum_mismatch_preserves_diagnostic` | 6.271 | KEEP |
| `RestorePrepareTests.test_pkg_consent_prepare_reuse_execute_and_noop` | 30.580 | KEEP |
| `RestorePrepareTests.test_pkg_consent_is_bound_to_metadata_bundle_selection_and_expiry` | 43.509 | KEEP |
| `RestorePrepareTests.test_pkg_incomplete_capture_and_conflicting_receipt_fail_closed` | 49.942 | KEEP |
| `RestorePrepareTests.test_pkg_without_local_payload_is_unsupported_without_download` | 8.669 | KEEP |
| `RestorePrepareTests.test_execution_events_changed_noop_and_detailed_records` | 34.008 | KEEP |
| `RestorePrepareTests.test_detailed_execution_failure_and_mutation_risk` | 17.357 | KEEP |
| `RestorePrepareTests.test_production_record_projection_mismatch_unsupported_and_operation_separation` | 7.628 | KEEP |
| `RestorePrepareTests.test_git_scalar_restore_selection_idempotence_and_stale_plan` | 25.600 | KEEP |
| `RestorePrepareTests.test_git_restore_has_typed_operation_and_verified_conformity` | 14.735 | KEEP |
| `RestorePrepareTests.test_reporting_live_drain_bound_and_privacy` | 0.256 | KEEP |
| `RestorePrepareTests.test_execute_process_observer_failure_is_not_bundle_unavailable` | 2.263 | KEEP |
| `RestorePrepareTests.test_stale_input_recheck_reports_only_fingerprints_and_flags` | 5.789 | KEEP |
| `RestorePrepareTests.test_missing_bundle_retains_bundle_unavailable` | 1.720 | KEEP |
| `RestorePrepareTests.test_opt_in_performance_trace_preserves_protocol` | 24.365 | KEEP |
| `RestorePrepareTests.test_prepare_plan_and_recomputation` | 4.936 | KEEP |
| `RestorePrepareTests.test_secure_and_invalid_selection` | 2.417 | KEEP |
| `RestorePrepareTests.test_application_readiness_is_read_only_and_typed` | 3.740 | KEEP |
| `RestorePrepareTests.test_formula_readiness_keeps_casks_separate` | 5.526 | KEEP |
| `RestorePrepareTests.test_cask_execution_and_convergence` | 59.027 | KEEP |
| `RestorePrepareTests.test_cask_repair_prepare_execute_and_convergence` | 50.989 | KEEP |
| `RestorePrepareTests.test_cask_repair_rejects_unsafe_or_ambiguous_state` | 5.437 | KEEP |
| `RestorePrepareTests.test_cask_repair_final_verification_and_stale_plan` | 34.918 | KEEP |
| `RestorePrepareTests.test_cask_repair_fresh_install_and_cli_only_damage` | 11.820 | KEEP |
| `RestorePrepareTests.test_cask_repair_safe_stop_owns_child_processes` | 18.507 | KEEP |
| `RestorePrepareTests.test_cask_failure_preserves_mutation_boundary` | 23.211 | KEEP |
| `RestorePrepareTests.test_cask_readiness_states_and_other_categories` | 9.785 | KEEP |
| `RestorePrepareTests.test_rosetta_prerequisite_is_item_local_and_refreshable` | 62.747 | KEEP |
| `RestorePrepareTests.test_ownership_conflict_skips_item_and_preserves_independent_work` | 29.509 | KEEP |
| `RestorePrepareTests.test_unsupported_cask_continues_independent_formula` | 28.380 | KEEP |
| `RestorePrepareTests.test_mixed_unsupported_casks_keep_selection_and_execute_safe_items` | 55.753 | KEEP |
| `RestorePrepareTests.test_cask_artifact_requirements_do_not_leak_across_orders` | 64.105 | KEEP |
| `RestorePrepareTests.test_accepted_unsupported_item_stays_skipped_after_late_metadata_change` | 33.221 | KEEP |
| `RestorePrepareTests.test_only_unsupported_work_cannot_execute` | 7.300 | KEEP |
| `RestorePrepareTests.test_unsupported_cask_preserves_global_blocker_and_stale_plan` | 21.319 | KEEP |
| `RestorePrepareTests.test_qualified_cask_cli_artifacts` | 127.325 | KEEP |
| `RestorePrepareTests.test_cask_metadata_artifact_boundary` | 15.107 | KEEP |
| `RestorePrepareTests.test_vscode_restore_production_and_convergence` | 85.958 | KEEP |
| `RestorePrepareTests.test_vscode_bundled_cli_without_path` | 14.594 | KEEP |
| `RestorePrepareTests.test_vscode_prerequisites_before_publication` | 21.633 | KEEP |
| `RestorePrepareTests.test_vscode_install_failure_preserves_mutation` | 16.657 | KEEP |
| `RestorePrepareTests.test_vscode_bundle_ambiguity_and_broken_launcher` | 12.787 | KEEP |
| `RestorePrepareTests.test_repository_preview_identity_with_reversed_config_order` | 29.217 | KEEP |
| `RestorePrepareTests.test_repository_clone_convergence_and_existing_coverage` | 159.093 | KEEP |
| `RestorePrepareTests.test_repository_conflicts_before_publication` | 35.606 | KEEP |
| `RestorePrepareTests.test_repository_git_prerequisites` | 9.399 | KEEP |
| `RestorePrepareTests.test_repository_partial_failure_and_ssh_boundary` | 22.405 | KEEP |
| `RestorePrepareTests.test_repository_unselected_and_human_clone` | 5.823 | KEEP |
| `RestorePrepareTests.test_repository_unavailable_branch_is_execution_failure` | 15.576 | KEEP |
| `RestorePrepareTests.test_repository_credentials_rejected_privately` | 0.649 | KEEP |
| `RestorePrepareTests.test_readiness_report_validates_private_inputs_once` | 8.147 | KEEP |
| `RestorePrepareTests.test_assisted_appstore_mixed_restore_and_manual_convergence` | 141.881 | KEEP |
| `RestorePrepareTests.test_duplicate_effective_scope_execute_verify_and_noop` | 44.756 | KEEP |
| `RestorePrepareTests.test_duplicate_legacy_and_explicit_appstore_only` | 12.674 | KEEP |
| `RestorePrepareTests.test_duplicate_cask_failure_never_falls_back_or_verifies` | 31.281 | KEEP |
| `RestorePrepareTests.test_duplicate_receipt_protection_and_unrelated_work` | 29.131 | KEEP |
| `RestorePrepareTests.test_duplicate_offline_cache_stabilizes_legacy_prepare_execute_and_refresh` | 56.325 | KEEP |
| `RestorePrepareTests.test_duplicate_cache_loss_and_offline_reject_stale_plan_without_mutation` | 18.107 | KEEP |
| `RestorePrepareTests.test_preview_scope_warning_is_separate_from_matching_items` | 1.734 | KEEP |
| `RestorePrepareTests.test_provider_marker_is_item_local_and_selection_preserves_other_work` | 39.036 | KEEP |
| `RestorePrepareTests.test_launcher_conflict_is_typed_and_never_becomes_appstore_failure` | 16.065 | KEEP |
| `RestorePrepareTests.test_assisted_appstore_unverified_does_not_block_workspace` | 55.050 | KEEP |
| `RestorePrepareTests.test_assisted_appstore_existing_bundle_blackmagic_record` | 4.519 | KEEP |
| `RestorePrepareTests.test_mas_installed_and_unselected` | 17.735 | KEEP |
| `RestorePrepareTests.test_execute_selected_formula_through_production_module` | 76.692 | KEEP |
| `RestorePrepareTests.test_execute_repreviews_and_publishes_only_after_gates` | 8.829 | KEEP |
| `RestorePrepareTests.test_execute_rejects_target_change_and_publication_failure` | 6.115 | KEEP |
| `RestorePrepareTests.test_execute_readiness_failures_never_publish` | 15.854 | KEEP |
| `RestorePrepareTests.test_execute_verification_and_partial_failure_states` | 13.670 | KEEP |
| `RestorePrepareTests.test_execute_failure_after_publication_before_mutation` | 4.264 | KEEP |
| `RestorePrepareTests.test_execute_verification_incomplete_is_not_execution_failure` | 3.973 | KEEP |
| `RestorePrepareTests.test_execute_cancellation_stops_owned_group` | 5.981 | KEEP |
| `RestorePrepareTests.test_owned_process_boundary_and_group_cancellation` | 0.663 | KEEP |
| `RestorePrepareTests.test_production_bootstrap_boundary_and_module_changed` | 5.455 | KEEP |
| `RestorePrepareTests.test_application_child_has_no_input_or_controlling_terminal` | 0.310 | KEEP |
| `RestorePrepareTests.test_human_sudo_fallback_and_application_prompt_guard` | 0.093 | KEEP |
| `RestorePrepareTests.test_recovery_and_failures_leave_state_untouched` | 0.310 | KEEP |
| `RestorePrepareTests.test_secure_without_component_and_preview_failure` | 1.136 | KEEP |
| `RestorePrepareTests.test_cancellation_cleans_stage` | 0.233 | KEEP |
| `TopologyPreviewTests.test_full_multiple_linked_repeat_identity` | 20.602 | KEEP |
| `TopologyPreviewTests.test_ordinary_missing_clone_and_shared_folder_destination` | 5.743 | KEEP |
| `TopologyPreviewTests.test_matching_linked_group_does_not_audit_project_contents` | 23.365 | KEEP |
| `TopologyPreviewTests.test_matching_checkout_skips_file_budgets_but_switch_retains_them` | 14.984 | KEEP |
| `TopologyPreviewTests.test_shared_existing_folder_does_not_inherit_git_blocker` | 7.127 | KEEP |
| `TopologyPreviewTests.test_noop_skips_file_observation_and_unsupported_reasons_are_allowlisted` | 2.927 | KEEP |
| `TopologyPreviewTests.test_absent_linked_local_branch_and_detached_object` | 8.298 | KEEP |
| `TopologyPreviewTests.test_partial_selection_and_all_four_folder_git_combinations` | 15.015 | KEEP |
| `TopologyPreviewTests.test_nested_repositories_parent_dependency_and_duplicate_basenames` | 16.046 | KEEP |
| `TopologyPreviewTests.test_branch_switch_and_dirty_preservation` | 29.039 | KEEP |
| `TopologyPreviewTests.test_staged_changes_and_protected_ignored_untracked_files` | 16.400 | KEEP |
| `TopologyPreviewTests.test_protected_file_blocks_branch_switch` | 12.481 | KEEP |
| `TopologyPreviewTests.test_occupied_branch_origin_and_independent_clone_conflicts` | 17.736 | KEEP |
| `TopologyPreviewTests.test_detached_unavailable_and_missing_local_branch` | 13.605 | KEEP |
| `TopologyPreviewTests.test_missing_base_blocks_dependents_without_clone_fallback` | 3.354 | KEEP |
| `TopologyPreviewTests.test_registered_missing_destination_and_nested_folder_dependency` | 10.253 | KEEP |
| `TopologyPreviewTests.test_destination_conflict_symlink_and_access_errors` | 15.415 | KEEP |
| `TopologyPreviewTests.test_git_capability_and_observation_failure_are_not_absence` | 9.250 | KEEP |
| `TopologyPreviewTests.test_corrupt_required_git_metadata_is_unverified` | 2.180 | KEEP |
| `TopologyPreviewTests.test_index_flags_cannot_hide_tracked_changes` | 4.466 | KEEP |
| `TopologyPreviewTests.test_native_index_modes_and_flags_remain_fail_closed` | 7.186 | KEEP |
| `TopologyPreviewTests.test_index_change_between_observations_remains_unverified` | 4.686 | KEEP |
| `TopologyPreviewTests.test_branch_syntax_success_is_shared_only_within_one_plan` | 2.270 | KEEP |
| `TopologyPreviewTests.test_checkout_revision_metadata_is_fresh` | 10.680 | KEEP |
| `TopologyPreviewTests.test_checkout_revision_metadata_rejects_incomplete_or_failed_reads` | 5.901 | KEEP |
| `TopologyPreviewTests.test_file_open_races_are_bounded_and_never_read_replacements` | 0.720 | KEEP |
| `TopologyPreviewTests.test_executable_checkout_hooks_block_switch_but_preserve_match` | 27.583 | KEEP |
| `TopologyPreviewTests.test_file_observation_deadline_and_volume_remain_bounded` | 0.431 | KEEP |
| `TopologyPreviewTests.test_linked_worktrees_use_shared_hooks_and_nonexecutables_are_inert` | 31.985 | KEEP |
| `TopologyPreviewTests.test_hooks_path_overrides_block_actions_without_following_them` | 16.861 | KEEP |
| `TopologyPreviewTests.test_clone_hook_routing_and_includes_fail_closed` | 5.998 | KEEP |
| `TopologyPreviewTests.test_detached_switch_named_oid_diagnostic_and_operation_lock` | 26.487 | KEEP |
| `TopologyPreviewTests.test_unstable_observation_is_not_a_plan_and_status_reobserves` | 8.442 | KEEP |

</details>

<details>
<summary>scripts/test-restore-prerequisites.py — 13 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `RestorePrerequisites.test_clean_home_settings_only_and_optional_launcher` | 6.642 | KEEP |
| `RestorePrerequisites.test_full_preview_cancel_does_not_create_ssh_or_publish` | 5.436 | KEEP |
| `RestorePrerequisites.test_selected_ssh_configuration_precedes_repository_transport` | 11.310 | KEEP |
| `RestorePrerequisites.test_invalid_selected_ssh_blocks_before_publication` | 1.180 | KEEP |
| `RestorePrerequisites.test_other_invalid_selected_input_blocks_ssh_mutation` | 4.397 | KEEP |
| `RestorePrerequisites.test_ssh_configuration_conflict_preserves_target_and_stops_clone` | 4.675 | KEEP |
| `RestorePrerequisites.test_confirmed_secure_import_precedes_repository_transport` | 10.842 | KEEP |
| `RestorePrerequisites.test_declined_secure_import_stops_clone` | 7.910 | KEEP |
| `RestorePrerequisites.test_selected_identity_without_ssh_configuration_precedes_clone` | 6.809 | KEEP |
| `RestorePrerequisites.test_decryption_failure_stops_clone` | 7.824 | KEEP |
| `RestorePrerequisites.test_secure_conflict_preserves_pair_and_stops_clone` | 7.543 | KEEP |
| `RestorePrerequisites.test_homebrew_activation_in_parent_and_downstream_process` | 0.372 | KEEP |
| `RestorePrerequisites.test_ssh_observation_rejects_invalid_existing_paths` | 0.066 | KEEP |

</details>

<details>
<summary>scripts/test-restore-selection.py — 48 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `IdentityDependencyTests.test_order_shared_local_and_missing` | 0.030 | KEEP |
| `IdentityDependencyTests.test_none_implicit_legacy_and_absolute_never_read` | 0.010 | KEEP |
| `IdentityDependencyTests.test_missing_nested_and_unsafe_paths` | 0.020 | KEEP |
| `IdentityDependencyTests.test_partial_case_parent_and_public_mismatch` | 0.047 | KEEP |
| `IdentityDependencyTests.test_locked_and_invalid_files_are_not_satisfied` | 0.284 | KEEP |
| `IdentityDependencyTests.test_authenticated_destinations_exclusions_and_ambiguity` | 0.050 | KEEP |
| `IdentityDependencyTests.test_changed_observation_and_bound_budget` | 0.054 | KEEP |
| `IdentityDependencyTests.test_private_derivation_transport_and_cleanup` | 0.024 | KEEP |
| `IdentityResolutionTests.test_v2_local_order_shared_create_verify_noop` | 0.266 | KEEP |
| `IdentityResolutionTests.test_v2_none_and_no_file_creation` | 0.053 | KEEP |
| `IdentityResolutionTests.test_original_references_are_advisory_but_corrections_stay_strict` | 0.046 | KEEP |
| `IdentityResolutionTests.test_advisory_absence_does_not_hide_new_intermediate_directory` | 0.062 | KEEP |
| `IdentityResolutionTests.test_config_only_merge_keeps_reference_order_and_conflict_guards` | 0.110 | KEEP |
| `IdentityResolutionTests.test_config_only_does_not_grant_git_authentication` | 0.069 | KEEP |
| `IdentityResolutionTests.test_execution_context_large_snapshot_and_protected_original` | 0.147 | KEEP |
| `IdentityResolutionTests.test_explicit_local_approval_and_original_conflict` | 0.189 | KEEP |
| `IdentityResolutionTests.test_approved_noop_rejects_unsafe_stale_and_unresolved_targets` | 0.187 | KEEP |
| `IdentityResolutionTests.test_inline_review_qualifies_proposals_without_granting_consent` | 0.090 | KEEP |
| `IdentityResolutionTests.test_empty_review_shared_keys_and_actionable_limit` | 0.024 | KEEP |
| `IdentityResolutionTests.test_merge_preserves_unrelated_profiles_and_partial_source` | 0.136 | KEEP |
| `IdentityResolutionTests.test_stale_key_target_approval_and_bundle` | 0.072 | KEEP |
| `IdentityResolutionTests.test_unsafe_case_symlink_and_existing_conflicting_host` | 0.082 | KEEP |
| `IdentityResolutionTests.test_expected_identity_requires_selected_destination_and_verified_import` | 0.024 | KEEP |
| `IdentityResolutionTests.test_preview_context_cannot_apply_and_approval_cannot_be_implicit` | 0.034 | KEEP |
| `IdentityResolutionTests.test_uncertain_creation_retains_recovery_and_blocks_reentry` | 0.047 | KEEP |
| `IdentityResolutionTests.test_dependency_change_at_merge_preserves_pending_predecessor` | 0.068 | KEEP |
| `IdentityResolutionTests.test_check_dependency_qualification_remains_separate_from_config_conflict` | 0.021 | KEEP |
| `SelectionTests.test_matching_hosts_with_locked_key_configuration_only` | 12.254 | KEEP |
| `SelectionTests.test_ssh_dependency_prepare_binding_and_selection` | 14.293 | KEEP |
| `SelectionTests.test_ssh_subset_execute_verify_noop_and_unselected_conflict` | 17.245 | KEEP |
| `SelectionTests.test_ssh_review_and_readiness_fixture_matrix` | 33.280 | KEEP |
| `SelectionTests.test_large_v2_snapshot_prepare_execute_context` | 7.941 | KEEP |
| `SelectionTests.test_v2_private_review_local_approval_execute_and_stale` | 13.484 | KEEP |
| `SelectionTests.test_v2_no_file_execute_noop_and_selected_stale` | 30.451 | KEEP |
| `SelectionTests.test_v2_partial_creation_retains_unresolved_coverage` | 8.212 | KEEP |
| `SelectionTests.test_ssh_full_legacy_empty_and_independent_secure_selection` | 30.572 | KEEP |
| `SelectionTests.test_ssh_selection_stale_ids_bundle_and_target_bindings` | 16.539 | KEEP |
| `SelectionTests.test_ssh_subset_conflicts_and_ambiguous_target_remain_blocked` | 25.799 | KEEP |
| `SelectionTests.test_ssh_subset_v2_qualified_no_file_and_unresolved_identity` | 10.248 | KEEP |
| `SelectionTests.test_ssh_subset_preserves_partial_coverage_and_independent_categories` | 8.955 | KEEP |
| `SelectionTests.test_homebrew_token_labels_from_saved_bundle_keep_identity_and_privacy` | 0.298 | KEEP |
| `SelectionTests.test_protocol_inventory_prepare_binding_and_stale_execute` | 19.122 | KEEP |
| `SelectionTests.test_invalid_and_disabled_requests` | 1.800 | KEEP |
| `SelectionTests.test_all_modes_narrowing_identity_privacy_and_category_flags` | 0.085 | KEEP |
| `SelectionTests.test_captured_app_names_preserve_identity_and_round_trip` | 0.053 | KEEP |
| `SelectionTests.test_whole_domains_and_each_macos_domain` | 0.202 | KEEP |
| `SelectionTests.test_real_macos_domain_and_git_subset_preview` | 3.455 | KEEP |
| `SelectionTests.test_capability_and_null_legacy` | 3.776 | KEEP |

</details>

<details>
<summary>scripts/test-secure-check.py — 15 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `IdentityObservationTests.test_matching_missing_different_private_public_partial` | 0.008 | KEEP |
| `IdentityObservationTests.test_permissions_links_acl_collision_and_custom_destination` | 0.017 | KEEP |
| `IdentityObservationTests.test_changed_target_and_failed_observation_never_match` | 0.004 | KEEP |
| `SecureCheckTests.test_authenticated_missing_matching_repeat_and_read_only` | 4.225 | KEEP |
| `SecureCheckTests.test_same_fingerprint_different_private_bytes_and_public_bytes` | 3.071 | KEEP |
| `SecureCheckTests.test_subset_custom_destination_excluded_protected_identity` | 2.852 | KEEP |
| `SecureCheckTests.test_complete_scope_preserves_matching_and_missing_per_identity` | 3.064 | KEEP |
| `SecureCheckTests.test_cancel_wrong_passphrase_empty_selection_and_stale_bundle` | 4.539 | KEEP |
| `SecureCheckTests.test_protected_saved_reference_matches_only_its_authenticated_destination` | 9.013 | KEEP |
| `SecureCheckTests.test_reference_scope_excludes_unselected_keys_and_partial_observations` | 4.524 | KEEP |
| `SecureCheckTests.test_reference_correlation_requires_live_unambiguous_safe_evidence` | 1.570 | KEEP |
| `SecureCheckTests.test_independent_local_pair_qualification` | 2.203 | KEEP |
| `SecureCheckTests.test_invalid_encrypted_payload_and_partial_unsafe_target` | 4.432 | KEEP |
| `SecureCheckTests.test_public_envelope_validation_and_bundle_unlock_cancellation` | 3.256 | KEEP |
| `SecureCheckTests.test_no_secure_component_identity_mismatch_and_unsafe_destination` | 3.194 | KEEP |

</details>

<details>
<summary>scripts/test-secure-restore.py — 84 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `SecureRestoreTests.test_real_secure_import_and_global_verification` | 8.079 | KEEP |
| `SecureRestoreTests.test_identical_noop` | 5.601 | KEEP |
| `SecureRestoreTests.test_protected_key_separate_unlock` | 12.136 | KEEP |
| `SecureRestoreTests.test_key_retry` | 6.185 | KEEP |
| `SecureRestoreTests.test_key_retry_exhausted` | 8.070 | KEEP |
| `SecureRestoreTests.test_bundle_retry` | 8.676 | KEEP |
| `SecureRestoreTests.test_bundle_retry_exhausted` | 6.064 | KEEP |
| `SecureRestoreTests.test_confirmation_cancel` | 5.254 | KEEP |
| `SecureRestoreTests.test_peer_eof` | 3.271 | KEEP |
| `SecureRestoreTests.test_sigterm` | 6.497 | KEEP |
| `SecureRestoreTests.test_malformed_frame` | 4.079 | KEEP |
| `SecureRestoreTests.test_oversized_frame` | 4.564 | KEEP |
| `SecureRestoreTests.test_invalid_payload` | 7.375 | KEEP |
| `SecureRestoreTests.test_target_conflict` | 5.091 | KEEP |
| `SecureRestoreTests.test_missing_channel` | 3.959 | KEEP |
| `SecureRestoreTests.test_invalid_descriptor` | 5.124 | KEEP |
| `SecureRestoreTests.test_age_broken` | 9.824 | KEEP |
| `SecureRestoreTests.test_stale_plan` | 9.036 | KEEP |
| `SecureRestoreTests.test_age_absent` | 12.492 | KEEP |
| `SecureRestoreTests.test_age_child_failure` | 8.386 | KEEP |
| `SecureRestoreTests.test_secure_child_failure` | 3.212 | KEEP |
| `SecureRestoreTests.test_channel_timeout` | 4.441 | KEEP |
| `SecureRestoreTests.test_another_ciphertext_cannot_use_plan` | 4.665 | KEEP |
| `SecureRestoreTests.test_post_publication_failure_preserves_mutation` | 7.439 | KEEP |
| `SecureRestoreTests.test_secret_fd_and_argv_environment_isolation` | 8.228 | KEEP |
| `SecureRestoreTests.test_ordinary_scope_does_not_need_age_or_channel` | 1.195 | KEEP |
| `SecureRestoreTests.test_bundle_cancel` | 4.368 | KEEP |
| `SecureRestoreTests.test_confirmation_eof` | 5.137 | KEEP |
| `SecureRestoreTests.test_public_mode_600_noop_preserved` | 8.063 | KEEP |
| `SecureRestoreTests.test_unusable_age_executable` | 5.979 | KEEP |
| `SecureRestoreTests.test_repeated_restore_is_noop` | 16.867 | KEEP |
| `SecureRestoreTests.test_unsolicited_extra_frame` | 4.978 | KEEP |
| `SecureRestoreTests.test_wrong_challenge_id` | 6.787 | KEEP |
| `SecureRestoreTests.test_confirmation_invalid_action` | 5.716 | KEEP |
| `SecureRestoreTests.test_bundle_passphrase_does_not_unlock_key` | 8.793 | KEEP |
| `SecureRestoreTests.test_sigterm_after_publication_cleans_own_files` | 6.175 | KEEP |
| `SecureRestoreTests.test_stage_ciphertext_symlink_rejected` | 8.141 | KEEP |
| `SecureRestoreTests.test_git_clone_after_protected_import_and_ssh_publication` | 47.457 | KEEP |
| `SecureRestoreTests.test_v2_secure_expected_import_precedes_configuration` | 17.376 | KEEP |
| `SecureRestoreTests.test_v2_import_evidence_must_cover_verified_receipt` | 9.354 | KEEP |
| `SecureRestoreTests.test_v2_secure_custom_correction_requires_approval` | 42.719 | KEEP |
| `SecureRestoreTests.test_inline_secure_review_is_explicit_read_only_and_destination_bound` | 5.057 | KEEP |
| `SecureRestoreTests.test_v2_failed_cancelled_import_and_changed_target_never_publish` | 25.384 | KEEP |
| `SecureRestoreTests.test_dependency_default_authenticated_and_read_only` | 13.394 | KEEP |
| `SecureRestoreTests.test_dependency_custom_selected_excluded_and_changed_mapping` | 21.414 | KEEP |
| `SecureRestoreTests.test_dependency_conflict_and_absolute_stay_unqualified` | 7.821 | KEEP |
| `SecureRestoreTests.test_dependency_private_evidence_fails_closed` | 20.176 | KEEP |
| `SecureRestoreTests.test_selective_protected_excluded_conflict_and_repeat` | 22.007 | KEEP |
| `SecureRestoreTests.test_selective_selected_conflict_blocks_subset` | 14.200 | KEEP |
| `SecureRestoreTests.test_selective_unselected_default_conflict_and_inactive_destination` | 26.055 | KEEP |
| `SecureRestoreTests.test_selective_multiple_locations_and_legacy_whole_package` | 16.241 | KEEP |
| `SecureRestoreTests.test_selective_invalid_context_and_unknown_ids` | 7.750 | KEEP |
| `SecureRestoreTests.test_selective_zero_does_not_import_and_allows_ordinary` | 24.371 | KEEP |
| `SecureRestoreTests.test_selective_stale_selection_bundle_and_destination` | 11.390 | KEEP |
| `SecureRestoreTests.test_selective_excluded_malformed_entry_still_rejected` | 10.705 | KEEP |
| `SecureRestoreTests.test_selective_password_cancel_and_interrupted_subset` | 37.741 | KEEP |
| `SecureRestoreTests.test_custom_destinations_mixed_and_repeated_preview` | 21.771 | KEEP |
| `SecureRestoreTests.test_custom_destinations_multiple_and_matching_pair` | 18.660 | KEEP |
| `SecureRestoreTests.test_custom_destination_conflict_blocks_entire_package` | 7.940 | KEEP |
| `SecureRestoreTests.test_custom_destination_changed_after_preview` | 12.633 | KEEP |
| `SecureRestoreTests.test_custom_destination_unsafe_and_case_collisions` | 21.991 | KEEP |
| `SecureRestoreTests.test_custom_inventory_wrong_password_cancel_and_bundle_binding` | 8.008 | KEEP |
| `SecureRestoreTests.test_custom_destination_identity_binding_and_required_compare` | 13.129 | KEEP |
| `SecureRestoreTests.test_custom_destination_failed_and_interrupted_publication` | 16.923 | KEEP |
| `SecureRestoreTests.test_custom_destination_target_change_during_consent` | 9.806 | KEEP |
| `SecureRestoreTests.test_custom_destination_acl_and_disappearance` | 7.903 | KEEP |
| `PairProofTests.test_target_change_between_comparison_and_proof_is_not_matching` | 0.019 | KEEP |
| `ChallengeContextTests.test_exact_context_and_compatibility` | 0.000 | KEEP |
| `ChallengeContextTests.test_invalid_identity_fails_closed` | 0.001 | KEEP |
| `ChallengeContextTests.test_identity_is_bound_to_strict_challenge` | 0.000 | KEEP |
| `ChallengeContextTests.test_duplicate_fields_rejected_before_forwarding` | 0.000 | KEEP |
| `ChannelTests.test_stdin_descriptor_rejected` | 0.002 | KEEP |
| `ChannelTests.test_regular_file_rejected` | 0.000 | KEEP |
| `ChannelTests.test_wrong_nonce` | 0.000 | KEEP |
| `ChannelTests.test_control_bytes_rejected` | 0.000 | KEEP |
| `ChannelTests.test_secret_in_ordinary_json_rejected` | 0.212 | KEEP |
| `ChannelTests.test_connected_socket_is_noninheritable` | 0.000 | KEEP |
| `ChannelTests.test_zero_length_frame` | 0.001 | KEEP |
| `ChannelTests.test_partial_frame_deadline` | 0.172 | KEEP |
| `ChannelTests.test_confirmation_secret_rejected` | 0.000 | KEEP |
| `ChannelTests.test_secret_limit` | 0.000 | KEEP |
| `ChannelTests.test_empty_secret_rejected` | 0.000 | KEEP |
| `ChannelTests.test_invalid_utf8_rejected` | 0.000 | KEEP |
| `ChannelTests.test_tool_echo_and_controlling_tty` | 0.090 | KEEP |

</details>

<details>
<summary>scripts/test-ssh-identity-evidence.py — 14 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `IdentityEvidence.test_import_and_identical` | 0.510 | KEEP |
| `IdentityEvidence.test_different_conflict` | 0.291 | KEEP |
| `IdentityEvidence.test_partial_and_unsafe_conflict` | 0.414 | KEEP |
| `IdentityEvidence.test_cancel` | 0.226 | KEEP |
| `IdentityEvidence.test_decrypt_failure` | 0.270 | KEEP |
| `IdentityEvidence.test_mismatched_pair_and_malformed` | 0.362 | KEEP |
| `IdentityEvidence.test_unlock_failure` | 0.350 | KEEP |
| `IdentityEvidence.test_post_validation_rollback` | 0.235 | KEEP |
| `IdentityEvidence.test_strict_reader` | 0.400 | KEEP |
| `IdentityEvidence.test_restore_transport_collector` | 0.336 | KEEP |
| `IdentityEvidence.test_missing_evidence_never_verified` | 0.023 | KEEP |
| `IdentityEvidence.test_transport_cleanup_failure_preserves_result` | 0.016 | KEEP |
| `IdentityEvidence.test_invalid_transport_is_incomplete` | 0.446 | KEEP |
| `IdentityEvidence.test_standalone_no_evidence` | 0.235 | KEEP |

</details>

<details>
<summary>scripts/test-test-runner.py — 20 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `RunnerTests.test_real_ids_are_exact_disjoint_and_new_cases_are_assigned` | 1.327 | KEEP |
| `RunnerTests.test_case_weights_preserve_budget_and_conservative_unknowns` | 0.009 | KEEP |
| `RunnerTests.test_desktop_exit_and_observation_failure_are_truthful` | 1.207 | KEEP |
| `RunnerTests.test_desktop_deadline_stops_owned_descendants` | 5.241 | KEEP |
| `RunnerTests.test_desktop_surviving_child_cannot_pass` | 0.809 | KEEP |
| `RunnerTests.test_desktop_cancellation_stops_owned_work` | 0.518 | KEEP |
| `RunnerTests.test_desktop_sample_excludes_raw_process_data` | 0.014 | KEEP |
| `RunnerTests.test_desktop_unconfirmed_cleanup_cannot_pass` | 0.025 | KEEP |
| `RunnerTests.test_desktop_stage_summary_records_running_failed_and_not_run` | 0.092 | KEEP |
| `RunnerTests.test_case_sharded_cli_selection_is_read_only` | 9.611 | KEEP |
| `RunnerTests.test_discovery_errors_and_empty_suites_fail_closed` | 0.022 | KEEP |
| `RunnerTests.test_multiple_failures_keep_safe_logs_summary_and_reproduction` | 1.394 | KEEP |
| `RunnerTests.test_local_fail_fast` | 0.653 | KEEP |
| `RunnerTests.test_existing_skip_and_incomplete_worker` | 1.171 | KEEP |
| `RunnerTests.test_dirty_cleanup_stops_after_assertion` | 0.704 | KEEP |
| `RunnerTests.test_cleanup_error_stops_even_after_teardown` | 0.908 | KEEP |
| `RunnerTests.test_surviving_process_stops_later_suites` | 0.726 | KEEP |
| `RunnerTests.test_deadline_reports_error_and_stops_owned_work` | 1.030 | KEEP |
| `RunnerTests.test_shell_assertions_are_safe_but_unclassified_exit_stops` | 1.131 | KEEP |
| `RunnerTests.test_cancel_records_error_and_not_run` | 0.635 | KEEP |

</details>

<details>
<summary>scripts/test-vscode-extensions.py — 30 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `DiagnosticReaderTests.test_closed_classification_and_bounded_drain` | 0.014 | KEEP |
| `ExtensionBootstrapTests.test_success_and_repeated_noop` | 3.312 | KEEP |
| `ExtensionBootstrapTests.test_reset_continues_independent_and_preserves_native_exit` | 4.250 | KEEP |
| `ExtensionBootstrapTests.test_dependency_failure_is_not_pack_success` | 4.503 | KEEP |
| `ExtensionBootstrapTests.test_unknown_and_contradictory_errors_stop_and_do_not_leak` | 4.314 | KEEP |
| `ExtensionBootstrapTests.test_inventory_errors_stop_immediately` | 2.072 | KEEP |
| `ExtensionBootstrapTests.test_large_stdout_and_stderr_are_drained_without_leaking` | 1.052 | KEEP |
| `ExtensionBootstrapTests.test_invalid_configuration_precedes_all_installs` | 0.027 | KEEP |
| `ExtensionBootstrapTests.test_prior_changes_survive_unknown_failure_and_false_success_stops` | 3.853 | KEEP |
| `ExtensionBootstrapTests.test_stop_after_success_or_failure_prevents_new_launches` | 2.852 | KEEP |
| `ExtensionRestoreTests.test_partial_execution_verification_privacy_and_fresh_preview` | 34.514 | KEEP |
| `ExtensionRestoreTests.test_unknown_raw_output_never_enters_protocol_or_core_log` | 15.486 | KEEP |
| `ExtensionRestoreTests.test_cancellation_stops_active_cli_and_never_starts_later_items` | 12.949 | KEEP |
| `CLIWatchdogTests.test_long_progress_and_quiescent_success` | 2.209 | KEEP |
| `CLIWatchdogTests.test_inventory_deadline_blocks_native_install` | 1.348 | KEEP |
| `CLIWatchdogTests.test_install_deadline_stops_owned_tree_and_never_leaks` | 2.407 | KEEP |
| `CLIWatchdogTests.test_unconfirmed_stop_blocks_all_later_mutations` | 3.418 | KEEP |
| `CLIWatchdogTests.test_exit_zero_does_not_override_unconfirmed_quiescence` | 0.189 | KEEP |
| `CLIWatchdogTests.test_orphan_worker_after_root_exit_zero` | 9.045 | KEEP |
| `CLIWatchdogTests.test_observer_failure_retains_uncertainty` | 1.475 | KEEP |
| `CLIWatchdogTests.test_durability_failure_and_ipc_decline_launch` | 0.004 | KEEP |
| `CLIWatchdogTests.test_supervisor_crash_keeps_write_ahead_state` | 0.319 | KEEP |
| `CLIWatchdogRestoreTests.test_unknown_result_and_reentry_without_extensions` | 22.349 | KEEP |
| `ExecutionBoundaryTests.test_prepare_and_readiness_preserve_lifecycle` | 7.829 | KEEP |
| `ExecutionBoundaryTests.test_compare_verification_preserves_lifecycle` | 6.251 | KEEP |
| `ExecutionBoundaryTests.test_secure_failure_verification_preserves_lifecycle` | 12.673 | KEEP |
| `ExecutionBoundaryTests.test_execute_keeps_context_through_final_verification` | 19.943 | KEEP |
| `ExecutionBoundaryTests.test_missing_or_invalid_state_has_no_native_fallback` | 0.961 | KEEP |
| `ExecutionBoundaryTests.test_native_and_supervised_diagnostics_keep_statuses` | 3.669 | KEEP |
| `ExecutionBoundaryTests.test_execute_inventory_deadline_prevents_install` | 18.204 | KEEP |

</details>

<details>
<summary>scripts/test-workspace-topology-execute.py — 34 methods; canonical</summary>

| Method | #161 s | Decision |
| --- | ---: | --- |
| `TopologyExecuteTests.test_ssh_selected_alias_publication_before_clone` | 24.860 | KEEP |
| `TopologyExecuteTests.test_ssh_v1_selected_alias_and_uri` | 47.866 | KEEP |
| `TopologyExecuteTests.test_ssh_local_key_and_stale_identity` | 8.311 | KEEP |
| `TopologyExecuteTests.test_ssh_local_configuration_clone_and_stale_config` | 45.206 | KEEP |
| `TopologyExecuteTests.test_ssh_missing_required_key_and_independent_https` | 22.640 | KEEP |
| `TopologyExecuteTests.test_ssh_conflict_and_independent_https_with_unsupported_ssh` | 38.562 | KEEP |
| `TopologyExecuteTests.test_ssh_private_import_binding_and_approved_destination` | 1.930 | KEEP |
| `TopologyExecuteTests.test_ssh_shared_file_transition_and_dependency_ids` | 1.568 | KEEP |
| `TopologyExecuteTests.test_descriptor_folder_only_create_verify_and_repeat` | 18.235 | KEEP |
| `TopologyExecuteTests.test_descriptor_after_clone_and_linked_checkout` | 115.492 | KEEP |
| `TopologyExecuteTests.test_descriptor_partial_selection_and_missing_dependencies` | 70.548 | KEEP |
| `TopologyExecuteTests.test_descriptor_matching_jsonc_and_conflict_preserve_bytes` | 14.498 | KEEP |
| `TopologyExecuteTests.test_descriptor_symlink_escape_and_observation_error` | 10.785 | KEEP |
| `TopologyExecuteTests.test_descriptor_target_change_rejects_before_publication` | 2.455 | KEEP |
| `TopologyExecuteTests.test_descriptor_tracked_by_parent_is_preserved_before_branch_switch` | 63.014 | KEEP |
| `TopologyExecuteTests.test_matching_noop` | 85.153 | KEEP |
| `TopologyExecuteTests.test_add_multiple_linked_and_repeat` | 258.943 | KEEP |
| `TopologyExecuteTests.test_clone_and_detached_linked_in_one_restore` | 88.153 | KEEP |
| `TopologyExecuteTests.test_switch_and_exact_detached` | 268.644 | KEEP |
| `TopologyExecuteTests.test_folder_only` | 10.143 | KEEP |
| `TopologyExecuteTests.test_partial_selection_leaves_linked_absent` | 47.551 | KEEP |
| `TopologyExecuteTests.test_shared_existing_folder_verifies_despite_git_conflict` | 17.582 | KEEP |
| `TopologyExecuteTests.test_target_change_rejects_before_publication` | 15.329 | KEEP |
| `TopologyExecuteTests.test_detached_base_clone` | 46.880 | KEEP |
| `TopologyExecuteTests.test_clone_prerequisites_block_before_publication` | 5.819 | KEEP |
| `TopologyExecuteTests.test_nested_checkout_and_folder_dependencies` | 89.817 | KEEP |
| `TopologyExecuteTests.test_missing_local_branch_after_clone_is_blocked_without_creation` | 32.121 | KEEP |
| `TopologyExecuteTests.test_success_exit_without_result_is_not_verified` | 121.862 | KEEP |
| `TopologyExecuteTests.test_partial_worktree_retained_and_retry_fenced` | 101.834 | KEEP |
| `TopologyExecuteTests.test_source_bundle_changed_is_stale` | 17.456 | KEEP |
| `TopologyExecuteTests.test_branch_disappears_without_implicit_tracking_branch` | 68.203 | KEEP |
| `TopologyExecuteTests.test_unknown_consequences_fence_precedes_publication` | 9.299 | KEEP |
| `TopologyExecuteTests.test_force_stop_retains_unknown_fence` | 85.021 | KEEP |
| `TopologyExecuteTests.test_graceful_stop_finishes_owned_step_and_fresh_retry` | 164.833 | KEEP |

</details>


### Native static-function and selector ledger

All tracked Swift test sources are listed, including the standalone external-
identity harness. This is a source inventory, not an assertion-count claim. The
default entrypoints and two build.sh subsets are the Full coverage; other selectors
remain available for focused/qualification work. Presence in a file does not imply
execution in Full CI. Render-only paths behind `--no-renders` are not newly removed
by this checkpoint and must not be claimed as hosted visual qualification.

<details>
<summary>CaptureTests.swift</summary>

**Functions (includes helpers):** `write`, `quote`, `snapshot`, `row`, `focusDiscovery`, `sshHostSelectionChecks`, `render`, `developerSelectionChecks`, `main`, `secureSelectionChecks`, `waitUntil`, `realCore`, `captureResultChecks`, `capturePolicyChecks`, `captureVisualChecks`, `captureDisclosureChecks`, `accordionNativeChecks`, `capturePolishGeometryChecks`, `captureStatusOrigin`, `workspacePrepare`, `overlapCore`, `secureCaptureChecks`, `secureCaptureContractChecks`, `secureCaptureInvalidationCheck`, `overlapContractRejections`.

**Explicit selectors/options:** `--capture-disclosure-only`, `--capture-policy-only`, `--capture-result-only`, `--capture-visual-only`, `--check`, `--developer-selection-only`, `--no-renders`, `--overlap-core-only`, `--result-actions-only`, `--secure-capture-only`, `--secure-invalidation-only`, `--secure-selection-only`, `--ssh-confirmation-only`, `--ssh-host-selection-only`, `--workspace-core-only`.

</details>

<details>
<summary>CoreRuntimeTests.swift</summary>

**Functions (includes helpers):** `performanceTraceEnvironment`, `encodedEvent`, `stream`, `script`, `fixture`, `run`, `main`, `secureFixture`, `secureTransportTests`, `assertNoPersistedSecret`.

**Explicit selectors/options:** `--graceful-control-only`, `--secure-context-only`, `--secure-transport-only`.

</details>

<details>
<summary>DiagnosticReportTests.swift</summary>

**Functions (includes helpers):** `check`, `checkBackground`, `header`, `event`, `finish`, `makeReport`, `contractChecks`, `privacyChecks`, `write`, `storeAndSnapshotChecks`, `performanceAndLifecycleChecks`, `main`.

**Explicit selectors/options:** none; default main.

</details>

<details>
<summary>EnvironmentStatusTests.swift</summary>

**Functions (includes helpers):** `reduce`, `row`, `payload`, `data`, `presentation`, `rejected`, `write`, `quote`, `render`, `nativeStatusAnchorChecks`, `categorySemanticsCases`, `finalConsistencyChecks`, `renderResultViewport`, `conciseMessageChecks`, `legacySSHCoverageChecks`, `topologyChecks`, `groupedPresentationChecks`, `secureRender`, `secureCheckTests`, `main`, `snapshot`, `realCoreTest`.

**Explicit selectors/options:** `--concise-messages-only`, `--secure-check-only`, `--status-grouping-only`.

</details>

<details>
<summary>ExternalIdentityTests.swift</summary>

**Functions (includes helpers):** `main`.

**Explicit selectors/options:** `--capture-source`, `--custom-destinations-only`, `--legacy-only`, `--passphrase-source`.

</details>

<details>
<summary>HomebrewLaunchTests.swift</summary>

**Functions (includes helpers):** `main`.

**Explicit selectors/options:** none; default main.

</details>

<details>
<summary>HomebrewPackageTests.swift</summary>

**Functions (includes helpers):** `plan`, `rejects`, `signature`, `assessment`, `main`, `trustChecks`, `officialFile`, `eventually`, `lifecycleChecks`, `cacheChecks`, `officialDownload`.

**Explicit selectors/options:** `--assess`, `--check-signature`, `--ignore-cache`, `--no-cache`, `--official-download`, `--official-file`, `--raw`, `--status`, `--trust-only`, `--type`.

</details>

<details>
<summary>HomebrewSetupTests.swift</summary>

**Functions (includes helpers):** `main`.

**Explicit selectors/options:** `--version`.

</details>

<details>
<summary>OperationLogTests.swift</summary>

**Functions (includes helpers):** `check`, `event`, `outcome`, `terminal`, `logPath`, `newStore`, `request`, `raw`, `append`, `expectFailure`, `sanitizerTests`, `storageTests`, `capTests`, `crashTests`, `fixture`, `runtimeTests`, `cancellationTests`, `main`.

**Explicit selectors/options:** none; default main.

</details>

<details>
<summary>OperationLogViewTests.swift</summary>

**Functions (includes helpers):** `check`, `event`, `outcome`, `storeChecks`, `runtimeChecks`, `main`, `diagnosticReportIntegrationChecks`, `runChecks`, `fullHistoryReportChecks`, `presentationUXChecks`, `closeUXChecks`, `summaryPolishChecks`, `largeDetailsChecks`, `switchingChecks`, `nativeViewerChecks`.

**Explicit selectors/options:** `--diagnostic-report-only`, `--saved-log-copies`, `--summary-only`, `--switching-only`, `--ux-close-only`.

</details>

<details>
<summary>PresentationTests.swift</summary>

**Functions (includes helpers):** `reduce`, `capturePreviewRefinementChecks`, `previewCleanupChecks`, `captureConfirmationPrivacyChecks`, `externalIdentityChecks`, `settingsToolsChecks`, `securePassphraseChecks`, `bundledAgeErrorChecks`, `secureStartupErrorChecks`, `prelaunchRequestChecks`, `secureComparisonChecks`, `secureRestoreAvailabilityChecks`, `secureRestoreChecks`, `captureDisclosureChecks`, `secureSelectionChecks`, `secureCaptureChecks`, `homebrewSetupChecks`, `sidebarLayoutChecks`, `captureResultActionsChecks`, `restoreSummaryChecks`, `renderRestoreV2`, `renderInitialStates`, `renderHomeBranding`, `appIconChecks`, `renderUnifiedSettings`, `presentationTaxonomyChecks`, `visualContractChecks`, `finalCorrectionChecks`, `restoreMacOSChecks`, `finalUIAlignmentChecks`, `executionVisualChecks`, `neutralUnverifiedChecks`, `summaryMetricVisibilityChecks`, `minimalResultSummaryChecks`, `resultCleanupChecks`, `operationLogChecks`, `restoreResultSummaryChecks`, `textStatusLayoutChecks`, `unsupportedRepairExplanationChecks`, `screenshotsIncludedSettingsChecks`, `windowsIncludedSettingsChecks`, `captureCompactSettingsChecks`, `captureResultAlignmentChecks`, `restoreResultColumnsChecks`, `resultStatusAlignmentChecks`, `previewColumnGeometryChecks`, `appStoreVisualChecks`, `previewExpansionPerformanceChecks`, `conciseWorkflowChecks`, `workflowDescendantChecks`, `workflowStatusScrollChecks`, `workflowInteractiveControlsChecks`, `workflowLayoutChecks`, `finalCapturePreviewAlignmentChecks`, `restorePreviewNoticesChecks`, `topologyPreviewChecks`, `restoreActualChangesChecks`, `restoreStoppedResultChecks`, `renderActualChanges`, `restoreFlatCategoryChecks`, `restorePreviewGroupingChecks`, `restoreSelectionAccordionChecks`, `sshResolutionPresentationChecks`, `developerSelectionChecks`, `selectionHelpChecks`, `selectionHelpChecksInEventLoop`, `developerIconChecks`, `main`, `runChecks`, `workflowContractChecks`, `sampleInteractionChecks`.

**Explicit selectors/options:** `--appearance-read`, `--appstore-visual-only`, `--bundled-age-only`, `--capture-checkpoint-only`, `--capture-disclosure-only`, `--capture-preview-refinement-only`, `--capture-result-actions-only`, `--concise-workflows-only`, `--developer-icons-only`, `--developer-selection-only`, `--execution-visual-only`, `--external-identities-only`, `--final-alignment-only`, `--final-corrections`, `--final-ui-only`, `--fix-issues-only`, `--homebrew-setup-only`, `--minimal-result-summary-only`, `--native-controls`, `--native-help-screenshot`, `--neutral-unverified-only`, `--no-renders`, `--operation-log-only`, `--pkg-preparation-only`, `--prelaunch-request-only`, `--preview-appstore-layout-only`, `--preview-cleanup-only`, `--preview-column-geometry-only`, `--preview-expansion-only`, `--preview-notices-only`, `--restore-actual-changes-only`, `--restore-flat-categories-only`, `--restore-macos-only`, `--restore-only`, `--restore-preview-grouping-only`, `--restore-render-only`, `--restore-result-columns-only`, `--restore-selection-only`, `--restore-stopped-result-only`, `--result-cleanup-only`, `--rosetta-only`, `--screenshots-included-only`, `--secure-availability-only`, `--secure-capture-only`, `--secure-compare-only`, `--secure-dialog-only`, `--secure-passphrase-only`, `--secure-restore-only`, `--secure-selection-only`, `--secure-startup-only`, `--selection-help-only`, `--selection-preview-only`, `--settings-tools-only`, `--sidebar-layout-only`, `--ssh-resolution-only`, `--status-grouping-only`, `--stress`, `--summary-metrics-only`, `--text-status-layout-only`, `--topology-preview-only`, `--unsupported-repair-explanation-only`, `--visual-contract-only`, `--windows-included-only`, `--workflow-contracts-only`, `--workflow-controls-only`, `--workflow-descendants-only`, `--workflow-layout-only`, `--workflow-scroll-only`.

</details>

<details>
<summary>RestoreTests.swift</summary>

**Functions (includes helpers):** `secureRestoreLayout`, `securePassphraseChecks`, `secureStartupChecks`, `secureRequestBudgetChecks`, `secureComparisonChecks`, `secureRestoreChecks`, `secureRestoreContractChecks`, `write`, `renderSSHFixture`, `sshResolutionChecks`, `sshHostSelectionChecks`, `render`, `taskPresentationChecks`, `restoreEvidenceChecks`, `applicationPrecedenceChecks`, `assistedAppStoreChecks`, `topologyPreviewChecks`, `appStoreRefreshCancellationChecks`, `selectionAccordionRender`, `selectionAccordionChecks`, `secureDestinationUIChecks`, `developerSelectionChecks`, `main`, `realPrepare`.

**Explicit selectors/options:** `--appstore-refresh-cancel-only`, `--assisted-appstore-only`, `--bundled-age-only`, `--capture-source`, `--developer-selection-only`, `--expect-aliased-failure`, `--final-restore-ux-only`, `--fix-issues-only`, `--fixtures-only`, `--homebrew-setup-only`, `--independent-ownership-only`, `--large-selection`, `--no-renders`, `--passphrase-source`, `--pkg-preparation-only`, `--plan-session-only`, `--presentation-only`, `--preview-appstore-layout-only`, `--restore-macos-only`, `--review-cancel-only`, `--rosetta-only`, `--secure-compare-binding-only`, `--secure-compare-only`, `--secure-destination-ui-only`, `--secure-destinations-only`, `--secure-identity-selection-only`, `--secure-passphrase-only`, `--secure-request-budget-only`, `--secure-restore-only`, `--secure-startup-only`, `--selection-accordion-only`, `--selection-preview-only`, `--ssh-host-selection-only`, `--ssh-resolution-only`, `--status-handoff-only`, `--topology-preview-only`, `--two-identities`.

</details>

<details>
<summary>SettingsTests.swift</summary>

**Functions (includes helpers):** `main`.

**Explicit selectors/options:** none; default main.

</details>
