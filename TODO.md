# TODO

Concrete unfinished work. Outcomes and stage status are in [Roadmap](ROADMAP.md).

## Stage 16 — Desktop integration

Implement the [Desktop contract](docs/DESKTOP.md) in vertical slices:

- [ ] 16H: Secure FD/challenge bridge, SSH opt-in, encryption/unlock/import
  confirmation and application age/OpenSSH PTY qualification.
- [ ] 16I: Qualify remaining completion UX over implemented mandatory Core
  Verification, attention/coverage, no-op and incomplete-result states.
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
- [ ] Unified reusable Macseed design system: apply first to Restore, then reuse
  in Capture, Environment Status, All Tasks and Settings. Use Domain → Items and
  one presentation model across Preview → Rebuild → Verification → Result,
  retaining native accessibility and Core-owned semantics.
- [ ] 16K: Desktop flow/runtime/transport/security/accessibility hardening,
  including stale plans, interruptions and diagnostics acceptance.

### Broad Restore manual gate — 2026-10-05

The gate **substantially passed** at checkpoint `3e555fba`: real Rebuild and Core
Verification succeeded. Git Configuration scalar drift passed Restore, independent
verification and an idempotent fresh Preview. This is supported-scope evidence,
not completion of all compatibility, secure or clean-Mac qualification.
Retain the safety backup at `~/Desktop/macseed-full-restore-gate-20261005-124533`
until remaining controlled checks are complete; it is not runtime input.

- [ ] **Homebrew compatibility qualification.** The External Tool Compatibility
  Layer, generic Cask capability model and authorized native lifecycle are
  established. Real Repair → Verify → fresh no-op gates passed for Keka, Termius
  and VLC; generated completions were validated through Codex. The SSH Restore
  readiness bug found during the real gate is fixed. Run broader representative
  gates before claiming complete Homebrew closure; Tailscale's ownership/activation
  boundary remains fail-closed and must not be counted as satisfied.
- [ ] **MAS Restore — mandatory before 1.0.** Safe automatic App Store restoration
  remains required; authorization/install qualification is unresolved. Amphetamine
  reports `authorization_required`; deselecting MAS allowed the broad gate to
  proceed but does not qualify MAS. Retain operation-wide prerequisites and
  privileged-child interruption protection until a safe contract is qualified.
- [ ] **Workspace product review.** Workspace Folders restores directory
  structure only, never user file contents. Review user-facing semantics and
  configurable discovery roots; current folder discovery classifies immediate
  children of HOME. Do not imply document/data migration or silently broaden scope.
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

## Maintenance and compatibility

- [ ] Revalidate `Clicking`, `TrackpadRightClick` and other version-dependent
  settings when migration to macOS 27 actually occurs.
