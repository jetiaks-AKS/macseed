# TODO

Concrete unfinished work. Outcomes and stage status are in [Roadmap](ROADMAP.md).

## Stage 16 — Desktop integration

Implement the [Desktop contract](docs/DESKTOP.md) in vertical slices:

- [ ] 16B: Native shell/navigation, reusable category/item views, status vocabulary,
  accessibility and first-launch/empty states.
- [ ] 16C: Bundled Core/Python layout, private writable state/temp, controlled
  child HOME/PATH/environment, Swift Protocol V1 JSONL launcher, process ownership
  and cancellation; typed sanitized logging foundation.
- [ ] 16D: Environment Status with explicit Generated Configuration/Blueprint
  reference, Compare summary and structured details.
- [ ] 16E: Capture scan/selection, fresh preparation/confirmation, publication and
  interruption states.
- [ ] 16F: Restore inspection/group selection, prerequisite guidance, Check Again,
  Preview and fresh-plan confirmation.
- [ ] 16G: Restore execution/progress, cancellation, partial failure and re-entry.
- [ ] 16H: Secure FD/challenge bridge, SSH opt-in, encryption/unlock/import
  confirmation and application age/OpenSSH PTY qualification.
- [ ] 16I: Final Verification/coverage, completion, no-op and incomplete states.
- [ ] 16J: Structured operation Details, private bounded log retention/clear,
  privacy-safe Diagnostic Report with complete preview and exact export.
- [ ] 16J: Dedicated sanitization regression fixtures for secrets, URLs, paths,
  labels, unknown/malformed fields, partial failure/cancellation and preview/export
  identity; preserve useful typed support context.
- [ ] 16K: Desktop flow/runtime/transport/security/accessibility hardening,
  including stale plans, interruptions and diagnostics acceptance.

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

- [ ] Fix the known GitHub Actions harness failure involving Python `__pycache__`.
- [ ] Revalidate `Clicking`, `TrackpadRightClick` and other version-dependent
  settings when migration to macOS 27 actually occurs.
