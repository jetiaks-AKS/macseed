# TODO

Concrete unfinished work. Outcomes and stage status are in [Roadmap](ROADMAP.md).

## Stage 16 — Desktop integration

Implement the [Desktop contract](docs/DESKTOP.md) in vertical slices:

- [ ] 16H: Secure FD/challenge bridge, SSH opt-in, encryption/unlock/import
  confirmation and application age/OpenSSH PTY qualification.
- [ ] 16I: Concise Result with mandatory Core Verification and expandable
  attention/coverage details, no-op and incomplete states.
- [ ] 16J: Structured operation Details, private bounded log retention/clear,
  privacy-safe Diagnostic Report with complete preview and exact export.
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
- [ ] 16K: Desktop flow/runtime/transport/security/accessibility hardening,
  including stale plans, interruptions and diagnostics acceptance.

### Broad Restore manual gate — 2026-10-05

Gate remains **pending**. Preview-only findings do not validate Execute or final
Verification. Retain the controlled-drift safety backup at
`~/Desktop/macseed-full-restore-gate-20261005-124533`; this is a temporary manual-gate
note, never product configuration or runtime input.

- [x] **Git Repositories Preview identity — manually verified.** Recheck with
  `Test_1.mbt` passed: `macseed` → OK / Already Matches;
  `bootstrap-branch-test` → Ready to Restore / Will clone repository.
- [ ] **Restore orchestration — fixed in working tree; broad manual gate pending.**
  Item-local `cask_execution_requirements_unsupported` stays selected and visible,
  is skipped during Execute, and permits supported independent work when no
  operation-wide blocker exists. Rebuild requires remaining executable changes;
  final Verification drives Rebuild Completed with Issues when appropriate.
  Firefox support itself remains unimplemented. Recheck with the fresh Debug app
  before closing this finding; preserve whole-operation safety prerequisites.
- [ ] **Homebrew cask classification — diagnosed; manual gate pending.** The
  apparent regression is newly exposed policy coverage: the unchanged classifier
  rejects Firefox/Keka `command_wrapper` artifacts and IINA's `binary` artifact.
  Earlier readiness stopped at Firefox and never classified the later missing
  casks; their Ready to Install labels were not proof of execution support.
  Read-only checks of current Homebrew metadata confirm AppCleaner/Plex are
  app-only and eligible, while Firefox/IINA/Keka remain unsupported. Blueprint
  and configuration indices in `Test_1.mbt` agree; differing-order regression
  coverage must retain each finding's item identity and prepared-plan binding.
  Keep unsupported items skipped and visible; qualify any future binary/wrapper
  support separately without weakening the current safe-cask policy. Rebuild
  being enabled does not close orchestration: real Execute/Verification is pending.
- [ ] **MAS Restore — open; mandatory before 1.0.** Amphetamine reports
  `authorization_required` and prevents Rebuild. Implement safe automatic Mac App
  Store restoration with partial-success/non-blocking semantics where appropriate;
  retain privileged-child interruption concerns in qualification.
- [ ] **Git Configuration — Restore scalar drift fixed in working tree; manual
  Execute+Verify pending.** Selected single direct values now plan `set_setting`
  and restore saved values; matching/unselected keys remain no-op. Ambiguous
  origins/multiple values and external-management protections remain. Recheck
  controlled `core.editor` / `init.defaultBranch` drift with the fresh Debug app;
  `pull.rebase` was Already Matches and is not a failure.
- [ ] **VS Code extension dependency — observed regression use case.** Manual
  removal of `ms-azuretools.vscode-containers` failed because
  `ms-azuretools.vscode-docker` depends on it. This uninstall failure is not a
  Macseed bug; preserve the scenario as dependency-handling coverage.
- [ ] **Homebrew watchdog broad manual gate — pending.** Controlled drift leaves
  casks `appcleaner`, `iina`, `keka`, `plex` and formulae `age`, `bat`, `knot`, `mtr`
  absent. With the DIRECT route, validate AppCleaner stalling and
  `item_stalled_timeout` after approximately 180 seconds without meaningful
  progress; later independent work must continue with no orphan brew/curl
  descendants. Final Verification is authoritative; partial success must report
  Rebuild Completed with Issues, and fresh Preview must show only genuinely
  unresolved state.
- [ ] **Workspace — Preview passed; Execute+Verify pending.** `VSCode` and
  `Работа` were intentionally moved out of their target paths; Preview correctly
  reports Ready to Create. Existing workspace folders remain no-op. Validate
  Execute and final Verification.
- [ ] **macOS Settings — Preview passed; Execute+Verify pending.** Finder/Dock
  drift was detected for `AppleShowAllExtensions`, `ShowPathbar`, `ShowStatusBar`,
  `_FXSortFoldersFirst`, Dock `autohide` and `show-recents`, including required
  affected-process restart where applicable. Validate Execute and Verification.
- [ ] **VS Code Settings / Extensions — Preview passed; Execute+Verify pending.**
  `settings.json` drift reports Ready to Restore; missing debugpy and Remote
  SSH-related extensions are detected. Validate Execute and Verification.
- [ ] **Zsh Restore — not yet manually validated.** Add explicit controlled-drift
  Restore coverage before considering broad validation complete.
- [ ] **Broad gate completion — pending.** After correctness/orchestration fixes,
  pass controlled drift → Preview → Rebuild → final Verification → independent
  external checks → fresh Preview with zero changes except intentionally
  unresolved/unsupported items. Do not declare completion before this sequence
  passes.

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
