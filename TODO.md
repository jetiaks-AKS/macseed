# TODO

Concrete unfinished work. Outcomes and stage status are in [Roadmap](ROADMAP.md).

## Stage 16 — Desktop integration

Implement the [Desktop contract](docs/DESKTOP.md) in vertical slices:

- [ ] 16H: Secure FD/challenge bridge, SSH opt-in, encryption/unlock/import
  confirmation and application age/OpenSSH PTY qualification.
- [ ] 16I: Complete remaining completion qualification beyond the now-implemented
  and checkpoint-qualified Restore [result contract](docs/DESKTOP.md#restore-result-contract);
  retain mandatory Core Verification and truthful incomplete-result evidence.
- [ ] 16J: First audit existing Core/CLI logging and Desktop event diagnostics,
  preserving two independent levels and safe evidence-based correlation.
- [ ] 16J: Persistent private structured operation logs with bounded retention/clear,
  live **View Log**, and a redacted Diagnostic Report with complete preview and
  exact export; current in-memory details are not persistent diagnostics.
- [ ] 16J: Dedicated sanitization regression fixtures for secrets, URLs, paths,
  labels, unknown/malformed fields, partial failure/cancellation and preview/export
  identity; preserve useful typed support context.
- [ ] 16K: Qualify managed private writable Core workspace for root-relative
  logs/config before packaged workflows; retain signed resources read-only.
- [ ] Functional UI consistency during Compatibility & Reliability: reuse
  qualified Restore/Capture presentation in Environment Status and Settings. Use Domain → Items and
  one presentation model across Preview → Rebuild → Verification → Result,
  retaining native accessibility and Core-owned semantics.
- [ ] 16K: Desktop flow/runtime/transport/security/accessibility hardening,
  including stale plans, interruptions and diagnostics acceptance.

### Restore Cancellation Safety — remaining qualification and recovery

Desktop Visual Unification is completed; its contract and the user-reproduced
2026-10-13 Firefox busy-DMG incident are recorded in
[Desktop](docs/DESKTOP.md#restore-cancellation-safety). No cancellation fixes are
claimed by the visual checkpoint. Stage 1–2 fail-closed cancellation and limited
Homebrew Graceful Stop are now implemented; 25 mock tests, related checks and a
Debug build passed. The bounded Firefox smoke test is recorded in Desktop.

- [ ] Implement Stage 3C durable ordinary-Cask journal/reconciliation and safe re-entry
  without deleting user data or detaching unrelated volumes.
- [ ] Qualify native installer Stop timing and detached/privileged process quiescence;
  mock coverage and the Firefox smoke test do not establish full interruption safety.
- [ ] Qualify MAS separately, plus Formula, VS Code Extensions and Git re-entry;
  Homebrew Graceful Stop is not a universal cancellation mechanism.

### Restore/Homebrew checkpoint — 08e2b469

Checkpoint `08e2b469ba714a6eb32a3293296943b774653415` advances the earlier
`3e555fba` broad gate. It includes capability-based Homebrew qualification, generic
clean native package Install and bounded Repair; System Events / Automation
readiness with Check Again; selection-aware blockers; draft selection with explicit
Refresh Preview and a fixed Preview footer; dedicated Preview / Progress / Result,
Awaiting Verification, clean Result without internal reason codes and issue/failure
diagnostics. Real Restore converged to a fresh Everything Already Matches Preview;
clean Tailscale installation and subsequent matching observation passed. Git scalar
drift remains independently verified and idempotent. This is supported-scope
evidence, not closure of all compatibility, secure or clean-Mac qualification.
Retain the safety backup at `~/Desktop/macseed-full-restore-gate-20261005-124533`
until remaining controlled checks are complete; it is not runtime input.

- [ ] **Homebrew compatibility qualification.** The External Tool Compatibility
  Layer, generic Cask capability model and authorized native lifecycle are
  established. Real Repair → Verify → fresh no-op gates passed for Keka, Termius
  and VLC; generated completions were validated through Codex. The SSH Restore
  readiness bug found during the real gate is fixed. Run broader representative
  gates as continuing compatibility qualification/maintenance. Clean Tailscale
  Install is qualified; universal Tailscale Repair is not. Ambiguous/damaged
  privileged Repair states remain fail-closed; installation does not prove VPN
  activation or application runtime health.
- [ ] **MAS Restore — mandatory before 1.0.** Safe automatic App Store restoration
  remains required; authorization/install qualification is unresolved. Amphetamine
  reports `authorization_required`; deselecting MAS allowed the broad gate to
  proceed but does not qualify MAS. Retain operation-wide prerequisites and
  privileged-child interruption protection until a safe contract is qualified.
- [ ] **Workspace product review.** Workspace Folders restores directory
  structure only, never user file contents. Review user-facing semantics and
  configurable discovery roots; current folder discovery classifies immediate
  children of HOME. Investigate bounded transfer of useful unique workspace/local
  data only after research, a capability matrix and an explicit product/safety
  contract; do not silently introduce a general backup/file-migration engine.
- [ ] **Real Desktop Zsh Restore gate.** Run controlled drift → Preview → Rebuild
  → Verification → independent check → idempotent Preview with safe backup.
- [ ] **Watchdog targeted qualification.** Independently qualify a real
  approximately 180-second no-progress stall, owned descendant termination and
  continued independent work where the broad gate did not exercise that failure.
- [ ] **VS Code dependency coverage.** Retain the observed case where removal of
  `ms-azuretools.vscode-containers` is refused because `ms-azuretools.vscode-docker`
  depends on it; this uninstall refusal is not a Macseed bug.

The passed checkpoint includes repository Preview identity correlation and
item-local unsupported orchestration. Selected differing Git scalars now plan
`set_setting`, restore saved values and verify; matching/unselected keys remain
no-op, and ambiguous origins/multiple values and observation errors stay protected.
The former `core.editor` / `init.defaultBranch` `target_conflict` drift bug is fixed
and verified end-to-end; it is no longer open gate work.

### Current execution order

Historical Stage 16 slice identifiers remain unchanged. Complete one checkpoint
at a time, in this practical order:

1. [Restore Cancellation Safety](docs/DESKTOP.md#restore-cancellation-safety): complete
   Stage 3C durable re-entry protection and installer/process-quiescence qualification
   after implemented Stage 1–2 and Homebrew Graceful Stop.
2. Desktop Operation Logging & Diagnostics: first audit the two existing logging levels.
3. Automatic MAS Restore qualification, mandatory before 1.0.
4. Secure SSH Desktop integration (16H) over the existing Core engine.
5. Compatibility & Reliability: remaining Result, Zsh, Homebrew/Repair, watchdog,
   partial/interrupted operations, stale plans, Workspace review, functional
   consistency, accessibility and runtime hardening.
6. Stage 17 Distribution & Clean-Mac Qualification: private writable runtime/workspace,
   signing, Hardened Runtime, notarization/stapling, DMG, Gatekeeper, clean Apple
   Silicon and separate Intel qualification where support is claimed.
7. Early Access / Alpha.
8. Macseed 1.0.

### Deferred UI/dev tooling

- [ ] Unified UI Scenario Catalog / possible Lite: retain existing Debug
  design-preview, sample fixtures and DemoSession. After functional priorities,
  consider a small Debug-only set of Capture/Restore/Status states (Ready, Working,
  Already Matches, Needs Attention, Error, Cancelled, Interrupted where applicable)
  using production presentation models/shared views and approved Minimal Premium.
  Minimize infrastructure; no parallel components or copied obsolete design.
  Small focused fixtures and PresentationTests may accompany functional changes
  without a complete catalog first. See the
  [catalog contract](docs/DESKTOP.md#unified-ui-scenario-catalog--deferred-uidev-tooling).

## Stage 17 — Distribution

- [ ] Sign the app and nested runtime with Developer ID; configure Hardened Runtime.
- [ ] Complete notarization, stapling, DMG and downloaded-app Gatekeeper checks.
- [ ] Qualify packaged runtime and full clean Apple Silicon Capture/Restore E2E.
- [ ] Qualify Intel runtime and E2E before claiming Intel support, if included.
- [ ] Validate local logs, operation/interruption details and Diagnostic Report
  preview/export privacy in the signed/notarized app and clean-Mac E2E.

## Before Macseed 1.0 — Early Access/Alpha

- [ ] Run real Capture/Restore validation with approximately 10–20 technical
  external users; collect voluntarily shared privacy-safe reports/issues.
- [ ] Resolve observed compatibility/UX problems before the public 1.0 launch.

## Supported capability gaps

- [ ] Review remaining SSH/Zsh/Git/VS Code/macOS Settings and application-state
  gaps against meaningful end-to-end value; retain existing contracts and qualify
  bounded improvements through the [capability process](CONTRIBUTING.md#capability-qualification).
  Do not introduce Direct/vendor application restoration as current work.

## Maintenance and compatibility

- [ ] Revalidate `Clicking`, `TrackpadRightClick` and other version-dependent
  settings when migration to macOS 27 actually occurs.
