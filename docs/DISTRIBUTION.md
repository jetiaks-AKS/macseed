# Distribution & Clean-Mac E2E

**Planned — Stage 17.** A source-built development `Macseed.app` exists; a qualified
packaged, signed/notarized app and DMG do not. Current development paths use the
repository [CLI](toolkit/CLI.md) or [Desktop source build](../desktop/Macseed/README.md).
Completed UI, diagnostics and controlled real-Mac Restore checks do not replace
packaged clean-Mac qualification.

## Delivery boundary

Stage 16 implements the application's Core/runtime integration contract.
Stage 17 proves that the distributed application contains the runtime and works
outside the developer checkout.

- Bundle Core, Python/runtime and resources; separate signed read-only files from
  user-writable state.
- Apply Developer ID signing to the app and nested executables, enable Hardened
  Runtime and justify required entitlements.
- Complete notarization, stapling and DMG delivery; validate Gatekeeper after
  download and installation in Applications.
- Qualify runtime placement, dependencies, permissions, temporary state and
  secret input on supported macOS versions.
- Prove clean Apple Silicon E2E; qualify Intel runtime and workflows separately
  before claiming support.

The intended delivery is a normal `Macseed-1.0.dmg` containing `Macseed.app`,
installed by moving it to `/Applications`. The app packages its native executable,
the same shared Core implementation and required runtime/resources. No separate
user-visible Core/Python/CLI files are needed in the DMG. Exact internal bundle
paths remain undecided. Desktop must not require a repository clone, standalone
CLI installation or manual Python installation on a clean Mac. Standalone `bs`
remains independently supported for CLI/source users; Desktop does not fork Core.
Installing a Terminal command from Desktop is not a Stage 16 commitment.

## MAS and prerequisite delivery direction

**PLANNED for 1.0:** bundle reviewed, signed MAS with Macseed and update it only
with the app; no separate MAS auto-updater. End users must not need Xcode,
development certificates, Homebrew or manual installation of internal CLI tools
to launch Desktop. Developer certificates and Xcode are development/build inputs.
Homebrew remains a selected-Restore dependency: detect it and offer a managed
installation with explicit confirmation. Today missing Homebrew still requires
external installation; that managed flow is not implemented. If automatic MAS
installation is unavailable, explain the blocked item and offer manual App Store
installation followed by fresh inspection/verification, without promising
entitlement detection or silently retrying privileged work.

**PARTIAL development evidence:** signed bundled MAS arm64 and root-controlled
helper diagnostics passed; see [TrustedMAS](../desktop/AuthorizationPoC/TrustedMAS/README.md).
This does not qualify production delivery, Developer ID/notarization, clean-Mac
runtime, secure helper/MAS updates or rollback. The development certificate pin,
unsigned local packages and manually corrected parent permissions are not release
configuration. Qualify protected placement, full dependency/license notices,
atomic updates with retained validated generations and unknown-operation blocking.
The [Installer layout issue](../desktop/AuthorizationPoC/TrustedMAS/PACKAGING-ISSUE.md)
requires fresh-install and upgrade qualification. Never execute a user-writable
Homebrew chain or assume codesign verification alone protects a mutable source.

Other dependencies (VS Code CLI, Git, `age`) remain scoped to selected work under
Core. Exact package composition and supported architectures need qualification.

## Acceptance flow

```text
Configured Mac → Capture → private Bundle transfer
→ clean Mac → install Macseed.app → Preview / prerequisites
→ confirm Restore → selected Secure Restore → Verify → explicit Compare
```

Also qualify missing dependencies → external installation → Check Again → new
Preview → confirmation, plus cancellation, conflicts, partial failure and retry.
Repeated identical Restore should skip matching supported state. Mock and local
Core tests do not replace packaged qualification.

Qualify private structured logs and operation/interruption Details in the signed,
notarized app. Verify Diagnostic Report sanitization, complete preview and exact
export in the packaged clean-Mac flow, including partial failure and secure
cancellation. No automatic diagnostic submission is part of qualification.

The intended first complete Desktop release is **Macseed 1.0**, with no promised
date and no rewriting of toolkit/CLI v1.x–v3.3.x history, constants or tags.
The current [Release Process](git/RELEASE-PROCESS.md) remains the repository/CLI
procedure; this document does not invent signing commands. Actions are in
[TODO](../TODO.md).
