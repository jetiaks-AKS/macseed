# TODO

Concrete unfinished actions. Stage 16J is closed; implemented logging/report work
is recorded in [Desktop](docs/DESKTOP.md#local-logs-and-diagnostic-report) and
[Changelog](CHANGELOG.md). Stage 16 as a whole remains open. The single authoritative
[Current Execution Order](ROADMAP.md#current-practical-execution-order) is:
closed 16J → Cask/Tailscale → Restore Final Result UI → MAS/remaining Restore gaps
→ reliability/security → Stage 17 → Early Access → 1.0.

<a id="restorehomebrew-checkpoint--08e2b469"></a>

## Next — Homebrew Cask / Tailscale

- [ ] Investigate and fix unsupported Cask execution requirements, including
  `tailscale-app`; qualify installation on a clean Mac through the existing generic
  capability boundary. Historical successful Install/matching observation does not
  prove compatibility with all current metadata, universal Repair, VPN activation
  or application runtime health.
- [ ] Broaden representative Homebrew Install/Repair → Verify → fresh no-op gates
  as compatibility maintenance. Keep ambiguous/damaged privileged Repair states
  fail-closed and retain action-specific requirements/ownership evidence.

## Next — Restore Final Result UI / completion (16I)

- [ ] Complete remaining Result/completion qualification: preserve Core terminal
  outcome separately from Verification, expose partial/incomplete/unresolved
  evidence, and show only confirmed available counts.
- [ ] Check remaining functional UI consistency across Preview → Rebuild →
  Verification → Result and Settings using shared Domain → Items presentation,
  native accessibility and approved Minimal Premium components.

<a id="broad-restore-manual-gate--2026-10-05"></a>

## Mandatory Restore capability gaps

- [ ] **MAS automatic restoration — mandatory before 1.0:** qualify authorization,
  install and post-verification. Deselecting MAS or showing `authorization_required`
  does not close this task. Retain operation-wide prerequisites and privileged-child
  interruption protection until safe behavior is qualified.
- [ ] **Secure SSH Desktop (16H):** implement/qualify the inherited FD/challenge
  bridge, opt-in Capture encryption and Restore unlock/import confirmation over
  the existing engine; qualify age/OpenSSH PTY behavior. Extend privacy/report
  fixtures for secure operations without exporting keys, names or secret input.
- [ ] Run a controlled real Desktop Zsh drift → Preview → Rebuild → Verification
  → independent check → idempotent Preview gate, with safe backup.
- [ ] Review SSH/Zsh/Git/VS Code/macOS Settings and application-state gaps through
  the [capability process](CONTRIBUTING.md#capability-qualification); retain supported
  scope and existing safety contracts. Direct/vendor restoration is not current work.
- [ ] Add/retain VS Code dependency regression coverage for uninstall refusal when
  `ms-azuretools.vscode-docker` depends on `ms-azuretools.vscode-containers`; do not
  mistake the external tool's dependency protection for a Macseed failure.
- [ ] Review Workspace semantics and configurable discovery roots (current folder
  discovery observes immediate HOME children). Folders remains structure-only;
  assess useful unique/local data transfer only after research, a capability matrix
  and explicit product/safety contract, never as an implicit backup/migration engine.

## Cancellation, recovery and runtime reliability

Stage 1–2 fail-closed cancellation and operation-wide checkpoint Graceful Stop are implemented;
[Desktop](docs/DESKTOP.md#restore-cancellation-safety) records the incident/smoke-test
limits. Diagnostic records do not establish durable recovery or installer safety.

- [ ] **Stage 3C:** implement durable ordinary-Cask journal/reconciliation and safe
  re-entry, including operation-owned DMG evidence. Do not delete user data or
  detach unrelated volumes.
- [ ] Qualify native installer Stop timing and detached/privileged process
  quiescence; mock tests and the Firefox smoke test do not prove universal safety.
- [ ] Qualify MAS interruption separately, plus Formula, VS Code Extensions and
  Git re-entry. Operation-wide Stop admission does not qualify every native lifecycle.
- [ ] Independently qualify a real approximately 180-second no-progress watchdog
  stall, owned descendant termination and continued independent work.
- [ ] **16K:** qualify stale plans/inputs, partial or interrupted operations,
  incomplete Verification, transport failures and close/reopen/quit ownership;
  complete flow/security/accessibility hardening without weakening unknown outcomes.
- [ ] Keep the controlled Restore safety backup at
  `~/Desktop/macseed-full-restore-gate-20261005-124533` until remaining controlled
  qualification is complete; it is not Runtime input.

## Distribution and packaged runtime (16K / Stage 17)

- [ ] Qualify a managed private writable Core workspace for root-relative logs and
  configuration; preserve read-only signed resources and a controlled child environment.
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
- [ ] Close mandatory capability/reliability/distribution gaps and prepare supported
  scope, limitations and release documentation for the first native Desktop release.

## Deferred tooling and maintenance

- [ ] Consider Unified UI Scenario Catalog / Lite after functional priorities:
  a small Debug-only set of applicable Ready, Working, Already Matches,
  Needs Attention, Error, Cancelled and Interrupted states using production/shared
  views. Preserve existing fixtures/DemoSession; no parallel components or large
  tooling framework. See the [catalog contract](docs/DESKTOP.md#unified-ui-scenario-catalog--deferred-uidev-tooling).
- [ ] Revalidate `Clicking`, `TrackpadRightClick` and other version-dependent
  settings when migration to macOS 27 actually occurs.
