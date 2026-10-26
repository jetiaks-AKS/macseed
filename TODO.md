# TODO

Concrete unfinished actions only; follow the [Current Execution Order](ROADMAP.md#current-practical-execution-order).
Completed milestones, including Desktop CI, belong to Roadmap; qualification
below does not reopen accepted UI or the completed D1–D4/R5 implementation audit.

## Complete Workspace & Git Worktree Restoration

Follow the [planned capability checkpoint](ROADMAP.md#complete-workspace--git-worktree-restoration);
the [current limits](docs/toolkit/CONFIGURATION.md#linked-git-worktree-capability-limits)
remain in force until a reviewed contract is implemented.

- [ ] Review topology/identity, Capture/Bundle compatibility and Restore ordering
  contracts before coding; decide discovery roots and branch/path conflict policy.
- [ ] Decide any expansion of current bounded local clone SSH profiles/identity
  routing and additional migration/proxy support in the Git/SSH contract. Keep
  exclusions until qualified; filters/LFS require a separate scope decision.
- [ ] Implement the agreed Discovery → Selection → Capture → Preview → Restore
  → Verification path, including Workspace folders and VS Code workspace relations.
- [ ] Qualify file preservation, occupied branches, conflicting paths, observation
  failure, retry and repeat/no-op with disposable fixtures and representative real gates.
- [ ] Define any unique Workspace-data transfer through a separate bounded secure
  migration contract; keep current folder restoration structure-only.

## Secure SSH Desktop (16H)

- [ ] **Secure SSH Desktop (16H):** implement/qualify the inherited FD/challenge
  bridge, opt-in Capture encryption and Restore unlock/import confirmation over
  the existing engine; qualify age/OpenSSH PTY behavior. Extend privacy/report
  fixtures for secure operations without exporting keys, names or secret input.

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

### macOS settings manual qualification

Preserve the [stored-value qualification boundary](docs/toolkit/CONFIGURATION.md#controlled-macos-27-restore-qualification);
these tasks require native effects or unexercised writes, not another fixture pass.

- [ ] Qualify the real visual effect of Screenshots Window shadow and Floating
  thumbnail on macOS 27, including repeat/no-op behavior.
- [ ] Qualify Screenshot destination restoration using the Save To UI and an
  actual system-shortcut screenshot, then repeat/no-op on macOS 26 and 27.
  Resolve macOS 27 split location/target keys, default Desktop, old/new-key
  precedence, recording separation and refresh before enabling location writes
  there. The shared reader currently blocks 27/unknown targets; fixture coverage
  is not native 26↔27 acceptance. See the
  [Screenshots contract](docs/toolkit/CONFIGURATION.md#screenshots).
- [ ] Complete real Apply and visual-behavior qualification of the four new
  WindowManager preferences on macOS 27, including mode dependencies, session
  refresh and repeat/no-op. `EnableTilingByEdgeDrag` and `EnableTopTilingByEdgeDrag`
  already matched in the controlled test, so their write paths remain untested.
  Stored-preference Verification alone does not establish live effect.

<a id="broad-restore-manual-gate--2026-10-05"></a>

### Mandatory Restore capability gaps

- [ ] Complete a fresh full Capture → Rebuild → Verification gate from a newly
  captured Bundle on the current Mac after explicit scope approval and fresh
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

Operation-wide checkpoint Graceful Stop is implemented and has controlled real-Mac
acceptance; [Desktop](docs/DESKTOP.md#restore-cancellation-safety) records its scope.
Diagnostic records do not establish durable recovery or installer quiescence.

D1–D4/R5 implementation and automated integration are accepted. The real lifecycle,
broader Git and macOS 27 gates below remain separate from that completed repair queue.

- [ ] **Stage 3C:** implement durable ordinary-Cask journal/reconciliation and safe
  re-entry, including operation-owned DMG evidence. Do not delete user data or
  detach unrelated volumes.
- [ ] Define and qualify the user route after unknown consequences: inspect retained
  evidence, reconcile only with sufficient authority, then allow fresh preparation
  and explicit execution when safe. No automatic journal clearing or whole-Mac rollback.
- [ ] Qualify native installer Stop timing and detached/privileged process
  quiescence; controlled real-Mac Stop cases and the historical Firefox smoke
  test do not prove universal safety.
- [ ] Qualify Formula, VS Code Extensions and Git re-entry. Operation-wide Stop
  admission does not qualify every native lifecycle; App Store installation is
  manual and outside Core's installer cancellation boundary.
- [ ] Qualify application Restore's VS Code CLI absolute budgets, real owned-process
  termination and durable re-entry/reconciliation; interrupted installs remain
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
- [ ] Qualify bundled Core/Python and secure tool placement; do not assume developer
  tools or system Python on a clean Mac.
- [ ] Sign the app/nested runtime with Developer ID and configure Hardened Runtime.
- [ ] Complete notarization, stapling, DMG and downloaded-app Gatekeeper checks.
- [ ] Qualify packaged Capture → Restore → Verify on clean Apple Silicon.
- [ ] Qualify Intel runtime/E2E separately before claiming support, if included.
- [ ] Validate Operation Logs, interruption details and Diagnostic Report privacy /
  exact snapshot export in the signed/notarized app and clean-Mac flows.
- [ ] Manually verify Diagnostic Report Save panel cancellation/error handling and
  user-driven scrolling; programmatic byte-identity/TextKit tests are not these gates.

## Early Access / Macseed 1.0

- [ ] Run real Capture/Restore validation with approximately 10–20 technical external
  users; collect only voluntarily shared privacy-safe reports/issues.
- [ ] Resolve observed compatibility/UX problems before public 1.0 launch.
- [ ] After mandatory capability/reliability/distribution gaps close, prepare supported
  scope, limitations and release documentation for the first native Desktop release.

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
- [ ] Complete visual/device-behavior qualification of `Clicking`,
  `TrackpadRightClick` and other version-dependent settings on macOS 27; the
  controlled Restore confirmed saved values only.
