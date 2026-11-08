# TODO

Concrete unfinished actions only; follow the [Current Execution Order](ROADMAP.md#current-practical-execution-order).
Completed milestones, including Desktop CI, belong to Roadmap; qualification
below does not reopen accepted UI or the completed D1–D4/R5 implementation audit.
Close future gates with the evidence location, revision, host/runtime, selected scope
and result. Preserve accepted evidence and obtain only missing evidence under the
authorized gate; an interrupted run is not a full PASS and does not justify broad reruns.

## Complete Workspace & Git Worktree Restoration

Follow the [capability checkpoint and accepted bounded Core E2E scope](ROADMAP.md#complete-workspace--git-worktree-restoration);
the [current limits](docs/toolkit/CONFIGURATION.md#linked-git-worktree-capability-limits)
separate implemented Core Capture/Restore from remaining capability and real-Mac gates.

### Remaining Workspace E2E qualification

- [ ] Complete native Desktop E2E with the retained selected Workspace Bundle.
  This gate is **NOT RUN**: first establish safe native HOME/Core/journal/preferences
  isolation, then verify the saved reference, six matching requirements, group/item
  counts and read-only behavior. Qualify [Review in Rebuild](docs/DESKTOP.md#bundle-handoff)
  separately with confirmed Missing/Different and no Apply; all-matching results
  intentionally offer no handoff. Prior independent GUI acceptance does not close this gate.
- [ ] Qualify full SIGTERM reconciliation/recovery and successful fresh re-entry
  after the [Stage 3C reconciliation implementation](docs/core/APPLICATION-INTERFACE.md#stage-3c-reconciliation-boundary),
  beyond the accepted fail-closed fence. Inspect retained uncertainty and reconcile
  only with sufficient evidence before fresh Preview/Execute, Verification and no-op;
  blocked retry is not completed recovery. No automatic journal clearing or rollback.

Packaged/clean-Mac qualification remains under [distribution prerequisites](#distribution-prerequisites-and-packaged-runtime-16k--stage-17).
These remaining gates do not authorize workspace content transfer or expanded
SSH/filter/LFS support, and bounded Core acceptance does not close Workspace or Stage 16/17.

## Consolidated test/CI stabilization

The [successful CI #127 baseline](ROADMAP.md#product-direction-native-ui-alignment-and-later-ci-baselines)
supersedes the earlier CI #123/#124 failure notes. The Capture event-count repair
is already present in `a1fa2a5`; it checks exact inventory correspondence rather
than a fixed count. Those historical failures are not current open defects.

The consolidated evidence assessment is accepted; no repair task remains from
those failures. Run additional canonical validation for identified gaps or changes,
without weakening assertions, skipping tests or changing workflows merely to obtain PASS.

- [ ] Stabilize Secure Restore test runtime after [CI #153](https://github.com/jetiaks-AKS/macseed/actions/runs/42480406327).
  The suite exceeded its approximately 750-second deadline (752.009s including termination),
  independently of the stale capabilities assertion. Inspect per-case timing and
  cleanup evidence before a bounded optimization or partition change; do not
  raise timeouts blindly. The SSH checkpoint validates selected cases only and
  does not close this hosted runtime gate.

<a id="secure-ssh-desktop-16h"></a>

## SSH Environment Completion — Developer Environment Closure

**NEXT / PLANNED — not implemented.** Stage 16H identity completion and accepted
manual evidence belong to [Roadmap](ROADMAP.md#stage-16--native-macseed-desktop)
and [Desktop](docs/DESKTOP.md#secure-interactions). Follow the
[workflow contract](docs/CAPTURE-RESTORE.md#ssh-environment-completion--developer-environment-closure):

- [ ] Complete practical SSH Configuration Discovery, Capture, Preview, Restore and
  Verification, prioritizing `IdentityFile`, `IdentitiesOnly`, `AddKeysToAgent`,
  `UseKeychain` and other safely portable directives.
- [ ] Add optional per-identity destinations in existing Rebuild Selection through
  a compact Customize… sheet and native folder picker; default `~/.ssh` requires
  no extra steps. Keep Preview read-only and Rebuild responsible for execution;
  no destination editing in Preview, top-level screen or SSH manager.
- [ ] Validate `IdentityFile` against selected destinations; require explicit
  authorization for every proposed SSH configuration correction, never silent rewriting.
- [ ] Correct false Needs Attention results without hiding unsupported, conflicting
  or unsafe configurations, retaining Secure Migration v1 Bundle compatibility.
- [ ] Later qualify joint SSH Configuration + identities E2E, including default/custom
  destinations, Verification and repeated no-op.

## Remaining supported-domain Restore qualification

<a id="restorehomebrew-checkpoint--08e2b469"></a>

### Continuing Homebrew qualification

Clean Install qualification is recorded in
[Desktop](docs/DESKTOP.md#recent-restore-qualification-and-performance). Continue
the remaining supported-domain Restore gates below. Unsafe Tailscale Repair remains
Unsupported (`ownership_unproven`); in-place Repair is not implemented.

- [ ] Broaden representative Homebrew Install/Repair → Verify → fresh no-op gates
  as compatibility maintenance. Keep ambiguous/damaged privileged Repair states
  fail-closed and retain action-specific requirements/ownership evidence.
- [ ] Qualify the [published Homebrew Setup](docs/DESKTOP.md#homebrew-setup--implemented-visually-accepted)'s
  real standard Installer handoff, package retention while Installer is active,
  cancellation/return/recheck and enabled-Gatekeeper behavior on claimed hosts.
  Keep real clean-Mac installation under the separately authorized distribution gate;
  independent package authentication with Gatekeeper disabled does not establish notarization.

### macOS settings manual qualification

Preserve the [stored-value qualification boundary](docs/toolkit/CONFIGURATION.md#controlled-macos-27-restore-qualification);
these tasks require native effects or unexercised writes, not another fixture pass.

- [ ] Qualify the real visual effect of Screenshots Window shadow and Floating
  thumbnail on macOS 27, including repeat/no-op behavior.
- [ ] Qualify Screenshot destination restoration using the Save To UI and an
  actual system-shortcut screenshot, then repeat/no-op across macOS 15/26/27.
  Test Intel macOS 15 separately from Apple Silicon macOS 27, including transfers
  in both directions, absent/default Desktop, stale keys, recording separation,
  boolean effects and refresh. The version-aware backend and nine-direction
  fixtures are implemented; native 27.2 location Restore was accepted on
  2026-10-28. Broader cross-version and visual-effect gates remain open. See the
  [Screenshots contract](docs/toolkit/CONFIGURATION.md#screenshots).
- [ ] Complete real Apply and visual-behavior qualification of the four new
  WindowManager preferences on macOS 27, including mode dependencies, session
  refresh and repeat/no-op. `EnableTilingByEdgeDrag` and `EnableTopTilingByEdgeDrag`
  already matched in the controlled test, so their write paths remain untested.
  Stored-preference Verification alone does not establish live effect.
- [ ] Complete visual/device-behavior qualification of `Clicking`,
  `TrackpadRightClick` and other version-dependent settings on macOS 27; the
  controlled Restore confirmed saved values only. Qualify each claimed device/version
  under the [supported-domain matrix](#remaining-mandatory-supported-domain-qualification).

<a id="broad-restore-manual-gate--2026-10-05"></a>
<a id="mandatory-restore-capability-gaps"></a>

### Remaining mandatory supported-domain qualification

- [ ] Complete a fresh full Capture → Rebuild → independent Verify → Check → no-op
  gate from a newly captured Bundle on the current Mac after explicit scope approval and fresh
  Preview. Preserve archive/worktree state, resolve or explicitly exclude conflicts
  through supported selection, and
  check repeat/no-op convergence. This does not replace Stage 17 clean-Mac gates.
- [ ] Run a controlled real Desktop Zsh drift → Preview → Rebuild → Verification
  → independent check → idempotent Preview gate, with safe backup.
- [ ] Close the remaining supported Git/SSH configuration, VS Code and macOS
  settings qualification matrix: matching state, drift, conflicts, observation
  failure and repeat/no-op. Preserve accepted flows and record any unsupported
  scope through the [capability process](CONTRIBUTING.md#capability-qualification).
  VS Code dependency protection must remain explicit in install/re-entry results;
  current Restore has no uninstall consumer.

### VS Code Restore requalification

[Accepted installation evidence](docs/DESKTOP.md#recent-restore-qualification-and-performance)
does not require reinstalling extensions; only the checks below remain.

- [ ] Record independent installed-inventory and fresh-Preview evidence for the
  user-confirmed installation, retaining the targeted checks for
  `ms-azuretools.vscode-containers`, `ms-azuretools.vscode-docker` and
  `usernamehw.errorlens`; repeat installation is not required.
- [ ] Separately qualify VS Code Extension Pack dependency closure; installed-ID
  presence alone does not establish that every required dependency is installed.

## Remaining completion qualification (16I)

- [ ] Real-Mac qualify unexercised final-result combinations: absent/malformed terminal
  evidence, incomplete/not-run Verification, unresolved coverage, Applied without
  Verified and interrupted partial work. Preserve disjoint confirmed counters and
  separate Process Result / Verification. Final category/item UI, nested macOS
  settings and accepted Early Cancelled/Partial Stopped presentation are complete.

## Cancellation, recovery and runtime reliability

Operation-wide checkpoint Graceful Stop, durable lifecycle/admission journals,
process budgets and safety fences are implemented. Graceful Stop has controlled
real-Mac acceptance; [Desktop](docs/DESKTOP.md#restore-cancellation-safety) records its
scope. The [Stage 3C contract](docs/core/APPLICATION-INTERFACE.md#stage-3c-reconciliation-boundary)
separates these foundations from missing reconciliation. Diagnostic records and
blocked retry do not establish recovery or installer quiescence.

D1–D4/R5 implementation and automated integration are accepted. The real lifecycle,
broader Git and macOS 27 gates below remain separate from that completed repair queue.

- [ ] **Stage 3C:** extend the existing durable lifecycle/admission journals with
  ordinary-Cask operation-owned resource evidence, reconciliation and safe re-entry,
  including DMG ownership, under the [shared reconciliation contract](docs/core/APPLICATION-INTERFACE.md#stage-3c-reconciliation-boundary).
  Do not delete user data or detach unrelated volumes.
- [ ] Define, implement and qualify the user route after unknown consequences under
  that [Stage 3C contract](docs/core/APPLICATION-INTERFACE.md#stage-3c-reconciliation-boundary): inspect retained
  evidence, reconcile only with sufficient authority, then allow fresh preparation
  and explicit execution when safe. No automatic journal clearing or whole-Mac rollback.
- [ ] Qualify native installer Stop timing and detached/privileged process
  quiescence; controlled real-Mac Stop cases and the historical Firefox smoke
  test do not prove universal safety.
- [ ] Qualify Formula and VS Code Extensions re-entry, plus Git lifecycles beyond the
  [accepted Workspace Core cases](ROADMAP.md#complete-workspace--git-worktree-restoration). Operation-wide Stop
  admission does not qualify every native lifecycle; App Store installation is
  manual and outside Core's installer cancellation boundary.
- [ ] Qualify application Restore's VS Code CLI absolute budgets, real owned-process
  termination and, after [Stage 3C implementation](docs/core/APPLICATION-INTERFACE.md#stage-3c-reconciliation-boundary),
  durable re-entry/reconciliation; interrupted installs remain
  fail-closed even after observed tree termination. Fixtures do not qualify detached workers or
  external services.
- [ ] Real-Mac qualify implemented application clone budgets, SSH transport,
  partial-destination fencing and owned termination, including the implemented
  bounded local SSH snapshot. Filters/LFS, unsupported SSH directives/proxies and
  detached/delegated work remain outside the contract.
- [ ] Qualify implemented application observer/aggregate deadlines and unknown
  re-entry fences against real tools. Existing checkout and local mutations have
  an aggregate execution bound, not new per-command lifecycle qualification.
  Calibrate large clone, installer and aggregate deadlines from real measurements;
  absolute deadlines are not evidence of progress or a universal stall detector.
  See the [R5 process map](docs/core/APPLICATION-INTERFACE.md#external-process-waiting-and-git-clone-r5).
- [ ] Qualify numeric Git clone phase progress on real repositories and define
  reliable evidence for remaining external commands/unreported phases; absolute
  deadlines alone do not establish a stall.
- [ ] Independently qualify a real approximately 180-second no-progress watchdog
  stall, owned descendant termination and continued independent work.
- [ ] Account for the **23 tests** in `scripts/test-homebrew-graceful-stop.py`,
  currently outside canonical/CI coverage, in the canonical regression inventory;
  verify isolation/coverage without weakening assertions. Explicitly classify the
  older Stage 1 `scripts/test-restore-cancellation-mocks.py` diagnostic harness and
  its nonduplicated contracts. Preserve the canonical runner and four-shard CI structure.
- [ ] **16K:** qualify unexercised stale-input/plan and transport/terminal failures,
  close/reopen/quit ownership, plus remaining accessibility and flow/security
  hardening. Retain the accepted real stale_plan/re-preview gate and keep
  unavailable outcomes unknown.
- [ ] Locate and confirm the controlled-Restore safety backup last recorded at
  `~/Desktop/macseed-full-restore-gate-20261005-124533`. The read-only check on
  26 October 2026 found no copy at that path or reliable private location record.
  Preserve any retained copy until controlled Restore qualification is complete;
  do not delete it. The backup is not Runtime input.

## Distribution prerequisites and packaged runtime (16K / Stage 17)

- [ ] Implement/qualify a managed private writable Core workspace for root-relative
  logs and configuration; preserve read-only signed resources and the controlled
  child environment. Current bundled workflow roots are rejected.
- [ ] Implement and qualify checkout-independent bundled Core/Python and secure-tool
  placement; do not assume developer tools or system Python on a clean Mac.
- [ ] Sign nested age/runtime before the outer app with Developer ID and configure
  Hardened Runtime; bind post-signing helper integrity to verified upstream bytes
  and the release identity without weakening runtime validation.
- [ ] Complete notarization, stapling, DMG and downloaded-app Gatekeeper checks.
- [ ] Qualify packaged Capture → Restore → Verify and read-only Saved Environment
  Status on clean Apple Silicon.
- [ ] Qualify Intel runtime/E2E separately before claiming support, if included.
- [ ] Validate Operation Logs, interruption details and Diagnostic Report privacy /
  exact snapshot export in the signed/notarized app and clean-Mac flows.
- [ ] Manually verify Diagnostic Report Save panel cancellation/error handling and
  user-driven scrolling; programmatic byte-identity/TextKit tests are not these gates.

## Settings and future application updates

- [ ] Manually accept the implemented Tools & Dependencies tab in the native app:
  General Appearance/About, moved Homebrew controls/reminders, bundled age status
  and Check Again, Operation Logs, and Light/Dark compact layout.
- [ ] After Stage 17 distribution/signing is ready, choose and qualify the updater
  framework and a separate Updates tab under the
  [whole-app contract](docs/DISTRIBUTION.md#future-whole-application-updates): manual
  check/review/confirmed install; configurable background checking; explicit opt-in
  automatic installation; signed, verified atomic replacement of all bundled
  components; safe deferral during owned operations. No updater is implemented.

## Early Access / Macseed 1.0

- [ ] Run real Capture/Restore/Status validation with approximately 10–20 technical external
  users; collect only voluntarily shared privacy-safe reports/issues.
- [ ] Resolve observed compatibility/UX problems before public 1.0 launch.
- [ ] After mandatory capability/reliability/distribution gaps close, prepare supported
  scope, limitations and release documentation for the first native Desktop release.

## Deferred product capabilities

These are optional future decisions, not Workspace closure or 1.0 requirements.

- [ ] If demand warrants, assess any expansion of bounded local clone SSH profiles/
  identity routing, additional migration or proxy support under a separate Git/SSH
  contract. Keep existing exclusions; filters/LFS require their own scope decision.
- [ ] Assess any future unique Workspace-data transfer for value, provenance,
  conflicts, permissions, privacy and transport/storage safety before defining a
  bounded secure migration contract. Keep current folder restoration structure-only.

## Deferred tooling and maintenance

- [ ] Maintain CI weights from complete safe reports and measure the hosted Quick
  five-minute/full regression 15–20-minute targets. Quick, targeted execution,
  RestorePrepare partitioning and diagnostics are implemented and accepted;
  further tuning is maintenance, not an R5 closure condition. See
  [testing instructions](CONTRIBUTING.md#focused-feedback-and-ci).
- [ ] Reconcile scoped ShellCheck SC2034 diagnostics in `bootstrap.sh` and macOS
  Discovery with their cross-file consumers before adding annotations, if still
  present in the affected scope; do not suppress diagnostics without evidence.
- [ ] Consider Unified UI Scenario Catalog / Lite after functional priorities:
  a small Debug-only set of applicable Ready, Working, Already Matches,
  Needs Attention, Error, Cancelled and Interrupted states using production/shared
  views. Preserve existing fixtures/DemoSession; no parallel components or large
  tooling framework. See the [catalog contract](docs/DESKTOP.md#unified-ui-scenario-catalog--deferred-uidev-tooling).
