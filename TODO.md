# TODO

Concrete unfinished actions only. Functional Restore Result/Visual Unification,
operation-wide Graceful Stop implementation, performance optimization and Stage 16J
Logging & Diagnostics are implemented. Their remaining qualification gates below
do not reopen completed UI work. Stage 16 as a whole remains open; follow the single
[Current Execution Order](ROADMAP.md#current-practical-execution-order).

<a id="restorehomebrew-checkpoint--08e2b469"></a>

## Continuing Homebrew qualification

Clean Install qualification is recorded in
[Desktop](docs/DESKTOP.md#recent-restore-qualification-and-performance). MAS Restore
is the next mandatory functional priority. Unsafe Tailscale Repair remains
Unsupported (`ownership_unproven`); in-place Repair is not implemented.

- [ ] Broaden representative Homebrew Install/Repair → Verify → fresh no-op gates
  as compatibility maintenance. Keep ambiguous/damaged privileged Repair states
  fail-closed and retain action-specific requirements/ownership evidence.

## macOS settings manual qualification

Focused fixtures and the Desktop Debug build cover the settings/Capture UX
checkpoint. The [2026-10-17 real Restore](docs/toolkit/CONFIGURATION.md#controlled-macos-27-restore-qualification)
confirmed 37/37 saved values, not all visual effects; MAS Restore priority is unchanged.

- [ ] Qualify the real visual effect of Screenshots Window shadow and Floating
  thumbnail on macOS 27, including repeat/no-op behavior.
- [ ] Complete real Apply and visual-behavior qualification of the four new
  WindowManager preferences on macOS 27, including mode dependencies, session
  refresh and repeat/no-op. `EnableTilingByEdgeDrag` and `EnableTopTilingByEdgeDrag`
  already matched in the controlled test, so their write paths remain untested.
  Stored-preference Verification alone does not establish live effect.

<a id="broad-restore-manual-gate--2026-10-05"></a>

## Mandatory Restore capability gaps

- [ ] **MAS automatic restoration — mandatory before 1.0:** close real Desktop
  authorization → install → post-Verify → repeat/no-op qualification. Core already
  has the non-interactive `sudo -n` install path and mock coverage; complete any
  missing safe authorization interaction through that boundary. Deselecting MAS
  or showing `authorization_required` does not close the task. Preserve account,
  entitlement and privileged-child interruption safeguards.
- [ ] **Secure SSH Desktop (16H):** implement/qualify the inherited FD/challenge
  bridge, opt-in Capture encryption and Restore unlock/import confirmation over
  the existing engine; qualify age/OpenSSH PTY behavior. Extend privacy/report
  fixtures for secure operations without exporting keys, names or secret input.
- [ ] Run a controlled real Desktop Zsh drift → Preview → Rebuild → Verification
  → independent check → idempotent Preview gate, with safe backup.
- [ ] Close the remaining supported Git/SSH configuration, VS Code and macOS
  settings qualification matrix: matching state, drift, conflicts, observation
  failure and repeat/no-op. Preserve accepted flows and record any unsupported
  scope through the [capability process](CONTRIBUTING.md#capability-qualification).
  VS Code dependency protection must remain explicit in install/re-entry results;
  current Restore has no uninstall consumer.
- [ ] Define whether configurable Workspace discovery roots are needed (current
  folder discovery observes immediate HOME children), and qualify existing folder/
  repository conflict preservation and repeat/no-op under that supported contract.
  Folders remains structure-only; unique-data transfer is a separate
  [future direction](ROADMAP.md#post-10--future-direction).

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

- [ ] **Stage 3C:** implement durable ordinary-Cask journal/reconciliation and safe
  re-entry, including operation-owned DMG evidence. Do not delete user data or
  detach unrelated volumes.
- [ ] Qualify native installer Stop timing and detached/privileged process
  quiescence; controlled real-Mac Stop cases and the historical Firefox smoke
  test do not prove universal safety.
- [ ] Qualify MAS interruption separately, plus Formula, VS Code Extensions and
  Git re-entry. Operation-wide Stop admission does not qualify every native lifecycle.
- [ ] Independently qualify a real approximately 180-second no-progress watchdog
  stall, owned descendant termination and continued independent work.
- [ ] **16K:** qualify unexercised stale-input/plan and transport/terminal failures,
  close/reopen/quit ownership, plus remaining accessibility and flow/security
  hardening. Retain the accepted real stale_plan/re-preview gate and keep
  unavailable outcomes unknown. Confirmed Environment Status
  Cancel/reference retention and corrected `bundle_unavailable` classification
  are implemented, not outstanding fixes.
- [ ] Keep the controlled Restore safety backup at
  `~/Desktop/macseed-full-restore-gate-20261005-124533` until remaining controlled
  qualification is complete; it is not Runtime input.

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

- [ ] Consider Unified UI Scenario Catalog / Lite after functional priorities:
  a small Debug-only set of applicable Ready, Working, Already Matches,
  Needs Attention, Error, Cancelled and Interrupted states using production/shared
  views. Preserve existing fixtures/DemoSession; no parallel components or large
  tooling framework. See the [catalog contract](docs/DESKTOP.md#unified-ui-scenario-catalog--deferred-uidev-tooling).
- [ ] Complete visual/device-behavior qualification of `Clicking`,
  `TrackpadRightClick` and other version-dependent settings on macOS 27; the
  controlled Restore confirmed saved values only.
