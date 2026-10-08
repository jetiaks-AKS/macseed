# TODO

Concrete unfinished work. Outcomes and stage status are in [Roadmap](ROADMAP.md).

## Stage 16 — Desktop integration

Implement the [Desktop contract](docs/DESKTOP.md) in vertical slices:

- [ ] Unified UI Scenario Catalog: Debug-only synthetic fixtures/navigation over
  production presentation models/views; structural coverage for Restore, Capture,
  Environment Status and shared semantic states. See the
  [catalog contract](docs/DESKTOP.md#unified-ui-scenario-catalog--next-implementation-checkpoint).
- [ ] 16H: Secure FD/challenge bridge, SSH opt-in, encryption/unlock/import
  confirmation and application age/OpenSSH PTY qualification.
- [ ] 16I: Complete remaining completion qualification beyond the now-implemented
  and checkpoint-qualified Restore [result contract](docs/DESKTOP.md#restore-result-contract);
  retain mandatory Core Verification and truthful incomplete-result evidence.
- [ ] 16J: Persistent private structured operation logs with bounded retention/clear,
  live **View Log**, and a redacted Diagnostic Report with complete preview and
  exact export; current in-memory details are not persistent diagnostics.
- [ ] 16J: Dedicated sanitization regression fixtures for secrets, URLs, paths,
  labels, unknown/malformed fields, partial failure/cancellation and preview/export
  identity; preserve useful typed support context.
- [ ] 16K: Qualify managed private writable Core workspace for root-relative
  logs/config before packaged workflows; retain signed resources read-only.
- [ ] 16K: Complete Bundle-backed Environment Status before 1.0: validated
  staging/reference extraction over the existing comparison engine, including the
  restored Saved Environment as natural status reference. Replace the temporary
  internal folder/Blueprint picker; qualify the Core contract when implementing.
  See [final product reference](docs/DESKTOP.md#required-final-product-reference-before-macseed-10).
- [ ] Desktop UI consistency/unification after the Scenario Catalog: reuse
  qualified Restore presentation in Capture, Environment Status, All Tasks and Settings. Use Domain → Items and
  one presentation model across Preview → Rebuild → Verification → Result,
  retaining native accessibility and Core-owned semantics.
- [ ] 16K: Desktop flow/runtime/transport/security/accessibility hardening,
  including stale plans, interruptions and diagnostics acceptance.

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

1. Unified UI Scenario Catalog.
2. Desktop UI consistency/unification.
3. Persistent operation journal / View Log / Diagnostic Report.
4. Remaining capability qualification and product gaps (including MAS, Workspace/Data,
   real Zsh and watchdog gates).
5. Secure SSH Desktop integration.
6. Saved Environment / Bundle-backed Environment Status.
7. Stage 16 integration hardening.
8. Stage 17 distribution / clean-Mac E2E.
9. Early Access / Alpha.
10. Macseed 1.0.

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
