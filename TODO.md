# TODO

Concrete unfinished work. Outcomes and stage status are in [Roadmap](ROADMAP.md).

## Stage 16 — Desktop integration

- [ ] Define and implement bundled Core/runtime layout and Python availability.
- [ ] Move application writes to a defined user-writable state/temp location.
- [ ] Define controlled HOME, PATH and environment for the Core child.
- [ ] Implement the Swift Protocol V1 launcher and JSONL transport.
- [ ] Bridge inherited secret FD input and owned-process cancellation.
- [ ] Build Capture, Restore and Environment Status flows with structured results.
- [ ] Implement prerequisite guidance, Check Again and fresh-plan confirmation.
- [ ] Qualify the application Core/runtime and age/OpenSSH secure path.

## Stage 17 — Distribution

- [ ] Sign the app and nested runtime with Developer ID; configure Hardened Runtime.
- [ ] Complete notarization, stapling, DMG and downloaded-app Gatekeeper checks.
- [ ] Qualify packaged runtime and full clean Apple Silicon Capture/Restore E2E.
- [ ] Qualify Intel runtime and E2E before claiming Intel support, if included.

## Maintenance and compatibility

- [ ] Fix the known GitHub Actions harness failure involving Python `__pycache__`.
- [ ] Revalidate `Clicking`, `TrackpadRightClick` and other version-dependent
  settings when migration to macOS 27 actually occurs.
