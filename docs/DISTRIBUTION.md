# Distribution & Clean-Mac E2E

**Planned — Stage 17.** A packaged, signed and notarized `Macseed.app` and DMG
do not exist yet. Current users use the repository and [CLI](toolkit/CLI.md).

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

Homebrew, `mas`, VS Code CLI, Git and `age` are prerequisites for selected work
according to
Core, not universal application launch requirements. Exact package composition
and supported architectures remain undecided; signing credentials/infrastructure
are not assumed available.

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
