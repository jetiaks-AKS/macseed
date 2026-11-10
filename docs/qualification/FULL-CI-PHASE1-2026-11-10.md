# Full CI Phase 1 — 10 November 2026

Status: **IMPLEMENTED / FOCUSED LOCALLY VERIFIED / HOSTED NOT YET VERIFIED**.
The exact native call responsible for the CI #159 PresentationTests stall remains
**UNRESOLVED**. This checkpoint bounds that failure and adds diagnostics; it does
not claim to have reproduced or eliminated the hosted GUI stall.

Base: `develop`, `dd954c05aa9df54d447bea41385c34ab8087ede5`.
No commit, push, workflow dispatch, full local regression or full Desktop run.
Fast/Full separation and branch protection are unchanged.

## Evidence and failure causes

Inspected [CI #159](https://github.com/jetiaks-AKS/macseed/actions/runs/42779173712)
job logs and all four safe regression artifacts, plus the four artifacts and Desktop
log from green [CI #151](https://github.com/jetiaks-AKS/macseed/actions/runs/42463259149)
at `441a8e130cb2f19dd47f431a01c34502b4f3025a`.
Raw operation output, credentials, user inventories and process dumps are not
included in this report.

| Failure | Evidence and cause | Correction |
| --- | --- | --- |
| Regression 1: `ApplicationIdentityTests.test_capture_atomic_bundle_and_legacy_private_selection` | Assertion at `test-homebrew-capabilities.py:1699`; locally reproduced `False != True`. Commit `97ce01d` intentionally drops completeness inventories for a domain with no selected requirements after Cask precedence. The test still expected App Store inventory when a completeness marker existed. | Update that expectation; assert both inventory and marker are absent. Retain overlap, atomicity, source-preservation and legacy-sidecar assertions. |
| Regression 2: `TopologyPreviewTests.test_matching_checkout_skips_file_budgets_but_switch_retains_them` | Assertions at `test-restore-prepare.py:3791`. Git file-budget blockers were correct, but the independent existing folder became `inspect/blocked` instead of `none/satisfied`. | Fix the SSH projection described below; retain the original test. |
| Regression 3: `TopologyPreviewTests.test_git_capability_and_observation_failure_are_not_absence` | Assertion at line 3997. The SSH pass replaced independent `workspace_git_unsupported` reasons on dependent checkouts with `workspace_dependency_pending`. | Same production correction; retain exact unsupported/observation-failure assertions. |
| Regression 3: `TopologyPreviewTests.test_shared_existing_folder_does_not_inherit_git_blocker` | Assertion at line 3805. An existing folder inherited its Git checkout's hook blocker through the SSH pass. | Same correction; preserve folder satisfaction and the subsequent symlink-conflict/no-mutation checks. |
| Regression 4: Secure Restore | Typed result: `ERROR`, code `124`, reason `deadline`, 752.381 s. The stale 230.553 s suite weight generated a 751.659 s deadline. 66 cases completed PASS in 746.270 s; 18 lacked completion, and four later suite assignments were NOT RUN. This is aggregate budget exhaustion, not evidence of a single hung case or leaked process. | Case partitioning and current measured weights, preserving the existing timeout formula and cleanup rules. |
| Desktop | App build completed in 43.825 s and PresentationTests compilation in 47.583 s. Execution began at 08:03:59 UTC; two PASS messages appeared, followed by cancellation at 08:47:30 UTC. There was no native-stage watchdog or granular progress/sample evidence. | Independent process supervisor, native checkpoints and incremental stage summaries. Exact hosted native cause remains open. |

The topology defect is in `modules/ssh/git_dependencies.py:project`: it accumulated
all existing blockers and propagated them again, even with an empty SSH rules map.
The corrected pass considers only planned actions. New SSH blockers still propagate
through pending Git/folder/VS Code dependencies; existing satisfied, conflicting,
unsupported and unknown observations keep their original evidence. The existing
SSH transition case now additionally checks those preservation boundaries.

## Desktop investigation and containment

The entrypoint is an async `@MainActor main`. After developer-icon and topology
checks, its first new operation is `selectionHelpChecks()`. This check creates
NSHostingView/NSWindow fixtures, yields with the existing async settling helper,
delivers native mouse events synchronously, and exercises popover dismissal,
scrolling, resizing and category removal. It does not create Core subprocesses.
Its optional synchronous `screencapture` path is not enabled in CI. Other synchronous
process waits and nested RunLoop helpers occur later and cannot be assigned as
the cause from the available log.

CI #151 and #159 used the same `macos-26-arm64/20261102.0473.1` image, macOS 26.7.2,
Xcode 26.6 and Swift 6.3.3. The new help check was absent from #151. Environment
preflight succeeded in #159; that alone neither proves nor disproves a subsequent
WindowServer, event-tracking or MainActor problem. No hosted stack trace survives.

A bounded local probe on macOS 27.2 / Swift 6.4.2 made progress through several help
combinations, was intentionally stopped after 20 seconds, and confirmed process
cleanup. Its sample showed active rendering/event-loop work, not a reproduced
deadlock. The final focused help check passed all eight Capture/Rebuild × size ×
appearance combinations in 37.381 seconds. No GUI assertion was removed or skipped.
This local platform differs from hosted CI and cannot establish its internal cause.

`scripts/desktop_test_runner.py` now supervises PresentationTests outside Swift's
actor/event loop. Its 600-second execution deadline is independent of the unchanged
45-minute job cap (green #151 execution was 83.219 seconds). It observes ownership
before releasing a gated child, retains nonzero exits, cleans observed descendants,
and fails on surviving work or unconfirmed cleanup. Timeout is ERROR/124, never PASS.
Unavailable or stuck GUI dependencies therefore cannot consume the entire job
without a bounded failure. A one-second sample has its own five-second limit;
only fixed framework markers and PresentationTests source line numbers are emitted.
Raw stacks are discarded. Existing observed-descendant/private-session limitations
still apply; detached work missed before observation is not claimed to be covered.

Native help logs identify window creation, layout, mouse input and dismissal phases.
The build summary is atomically published at stage boundaries, so an external hard
kill leaves an honest `running` stage and subsequent `not-run` entries. Ordinary
failures retain their exit code and mark the current stage failed.

## Core scheduling and timing

The canonical `scripts/test.sh` inventory remains 44 suites. Secure Restore (84
methods) and Restore Selection (48 methods) join the three existing split suites.
All five use per-case mutable fixtures; they have no shared mutable class setup.
Real key/age processes retain their existing owners and cleanup paths. Global
temporary-directory checks still forbid concurrent suites on one machine.
The four hosted shards use separate VMs, and assigned cases remain sequential in
one interpreter per suite. No shared HOME, credentials, results or fixture cache
is introduced. The unittest loader/result semantics are unchanged.

Read-only planning confirms **346 case IDs + 39 whole suites = 385 units**, each
assigned exactly once, deterministic, with no omissions or intersections. New IDs
remain discoverable even without timings. All original test methods are retained;
runner coverage is expanded. The twelve Desktop suites and both Restore subsets
are unchanged. Lint, four regression shards, Desktop and aggregate `validate` remain
mandatory in the existing Full CI workflow.

Weights prefer completed PASS records from #159, with #151 fallback. Provenance is
recorded in `test-timings.json`: 44 suite measurements and 340 measured cases across
the five split suites; six cases retain conservative unknown estimates. Failed,
unfinished and partial-suite durations are not promoted to full measurements.
Completed individual PASS cases from partial suites remain case measurements.
`active_case` is now retained in safe runner diagnostics to distinguish interrupted
work from never-started cases in the NOT RUN completion inventory.

| Timing scope | Before | After | Qualification |
| --- | ---: | ---: | --- |
| Secure Restore whole-suite estimate | 230.553 s | 1114.795 s total planned case weight | Current coverage plus historical PASS cases and four conservative unknown cases; not a measured complete current-suite duration. |
| Secure Restore assigned case weight per shard | One whole unit | 225.714 / 275.482 / 307.171 / 306.428 s | 20 / 20 / 23 / 21 cases; budgets derived by the unchanged formula. |
| Restore Selection whole-suite stored measurement | 25.123 s | 223.353 s | Complete hosted PASS #159; planned case total is 251.236 s after conservative per-case minima. |
| Old assignment evaluated with refreshed evidence | 2194.929 / 2565.005 / 2468.577 / 2974.490 s | — | Estimate, including the complete current case inventory. |
| New assignment with the same evidence | — | 2551.852 / 2550.870 / 2551.809 / 2550.875 s | Estimated longest shard 49:34 → 42:32, about 14.2%; excludes provisioning and additional split-suite startup. |

The suite deadline remains `max(300, 3 * estimated_seconds + 60)` and the individual
case ceiling remains 900 seconds. No global deadline increase or concurrency was
introduced. Secure Restore setup consumed only 3.378 seconds across its first 66
completed cases in #159; caching mutable security setup would add risk for little
benefit. No repeated-setup cache was added.

## Desktop compilation

In #151 the twelve test executable compilations consumed 767.818 seconds (12:48),
excluding the application build. The existing script repeatedly compiles overlapping
sources as independent modules. A small supported compiler-mode change avoids
repeated frontend work: Debug test executables now use `-whole-module-optimization`
alongside unchanged `-Onone`, `-g` and `-D DEBUG`. Assertions remain enabled.
Application/Release compilation, source sets, executables and test invocations are
unchanged. No new build system, shared library or product module refactor is used.

One sequential local comparison compiling the same updated PresentationTests source
with an already populated module cache measured **24.97 s → 19.29 s** (22.7%). The
second run may benefit from warmer filesystem caches; this is a single local
measurement, not a statistical benchmark or a hosted speedup claim. The resulting
whole-module executable passed the focused native help case. Other executable
compilation/runtime compatibility remains part of the next hosted gate.

## Focused validation

Every named failing case was reproduced separately before correction, with confirmed
cleanup, and rerun separately afterward using the canonical runner:

| `./scripts/test.sh --suite … --case …` | Result | Case time |
| --- | --- | ---: |
| `scripts/test-homebrew-capabilities.py`, `ApplicationIdentityTests.test_capture_atomic_bundle_and_legacy_private_selection` | PASS | 0.020 s |
| `scripts/test-restore-prepare.py`, `TopologyPreviewTests.test_matching_checkout_skips_file_budgets_but_switch_retains_them` | PASS | 22.520 s |
| `scripts/test-restore-prepare.py`, `TopologyPreviewTests.test_git_capability_and_observation_failure_are_not_absence` | PASS | 8.008 s |
| `scripts/test-restore-prepare.py`, `TopologyPreviewTests.test_shared_existing_folder_does_not_inherit_git_blocker` | PASS | 6.561 s |
| `scripts/test-workspace-topology-execute.py`, `TopologyExecuteTests.test_ssh_shared_file_transition_and_dependency_ids` | PASS | 0.745 s |

- `./scripts/test.sh --suite scripts/test-test-runner.py`: 19/19 PASS, 13.129 s.
  Covers planning, selection, timeout, cancellation, isolation, safe diagnostics,
  surviving processes and unconfirmed cleanup; no Macseed full workflows.
- Added afterward: `--case RunnerTests.test_desktop_stage_summary_records_running_failed_and_not_run`:
  PASS, 0.034 s. Reuses the real build stage functions with a disposable failing
  command; observes the RUNNING snapshot, preserves exit 17, and prevents later work.
  The previous 19 results remain applicable; their implementation/dependencies did
  not change when this independent test was added.
- `python3 -B ../../scripts/desktop_test_runner.py --timeout 120 <focused-binary> --selection-help-only`
  from `desktop/Macseed`: PASS, 37.381 s, cleanup confirmed, eight native combinations.
- Two sequential PresentationTests-only compilations: PASS. No app/full Desktop build.
- `./scripts/test.sh --ci --shard 1/4 --list`, independent exact-union/disjointness
  verification, unchanged inventory/subset checks: PASS.
- Changed Python AST/JSON validation, required Bash syntax checks (including
  `desktop/Macseed/build.sh`), focused ShellCheck for that build script, local
  documentation-link review and `git diff --check`: PASS.

Prior hosted PASS artifacts were reused for diagnosis and scheduling, not acceptance
of changed code. Full local Core, complete Secure Restore/Restore Selection, complete
Desktop suites, real-Mac SSH E2E and new hosted CI: **NOT RUN** by task scope. No
manual visual acceptance is claimed. No cleanup remained unconfirmed.

## Phase 2 recommendation — design only

1. Keep the canonical Full inventory and `validate` aggregate. Run Full on PRs into
   `main`, main integration, explicit manual invocation and periodic qualification.
   A release/integration must bind successful Full evidence to its actual commit.
2. Add Fast for regular `develop` pushes and development PRs, with a distinct
   `fast-validate` status. Fast never produces a successful Full/`validate` result.
3. Use a small explicit dependency map from changed files to existing cases/suites.
   Documentation-only changes use documentation checks; domain changes include
   affected producers and consumers. Shared contracts, runner/workflow changes,
   unknown paths, missing merge bases or selection errors conservatively require
   Full rather than treating an empty selection as success.
4. Avoid overlapping push/PR triggers for the same purpose. Use a common concurrency
   identity for each tier/ref; cancel obsolete development work, preserve integration
   and release qualification. Reuse a completed hosted result only for the exact
   same SHA, workflow and coverage identity; never reuse an ancestor's status for a
   new merge commit. Manual/periodic qualification must be able to request a fresh run.
5. Preserve required-check compatibility before changing triggers. Current repository
   consumers are `ci.yml`'s always-run `validate` job depending on lint, regression and
   Desktop, plus the engineering contract in CONTRIBUTING. Read-only GitHub inspection
   found no classic protection on `main` or `develop` (404). The active
   [Protect main ruleset](https://github.com/jetiaks-AKS/macseed/rules/20908506) contains
   deletion and non-fast-forward restrictions, with no required status-check rule.
   Thus the workflow gate exists, but repository-level required-status enforcement
   was not found. Any protection change needs its own explicit publication decision;
   Fast must not substitute for Full on integration PRs.

No Phase 2 workflow, trigger, status or protection change is implemented here.

## Changed files and remaining gate

- `CONTRIBUTING.md`: runner/diagnostic owner documentation and evidence link.
- `desktop/Macseed/Tests/PresentationTests.swift`: progress checkpoints only.
- `desktop/Macseed/build.sh`: bounded PresentationTests, persistent stage summary,
  Debug test compilation mode.
- `docs/qualification/README.md`: report index.
- `docs/qualification/FULL-CI-PHASE1-2026-11-10.md`: this consolidated report.
- `modules/ssh/git_dependencies.py`: restrict propagation to planned work.
- `scripts/desktop_test_runner.py`: new bounded native supervisor.
- `scripts/test-homebrew-capabilities.py`: synchronize excluded-domain expectation.
- `scripts/test-test-runner.py`: planning and native supervisor/summary regressions.
- `scripts/test-timings.json`: measured weights and provenance.
- `scripts/test-workspace-topology-execute.py`: SSH propagation preservation checks.
- `scripts/test_runner.py`: two additional case-sharded suites and active-case evidence.

All changes are unstaged; HEAD remains the stated base. The complete review patch is
generated locally at `logs/ci-phase1/checkpoint.patch`, including new files. It is an
ignored review artifact, not a tracked test log. The pre-existing untracked
`desktop/Macseed/Tests/NativeSidebarRepro.swift` is unchanged (SHA-256
`8cf3e1b91ed0b878efe0178be78956f873b5c896ef6f28af2c68e89e0019f7cf`).

Remaining gate: review, then separately authorized publication and one real hosted
Full run. That run must validate every regression partition and Desktop executable,
the compiler-mode change on hosted Swift, and whether native help finishes. If it
stalls, the new checkpoints and bounded safe sample should identify the blocked
operation. Until that evidence exists, the exact Desktop stall and overall Full CI
reliability/performance qualification remain open.
