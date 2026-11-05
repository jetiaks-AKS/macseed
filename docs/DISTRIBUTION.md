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
user-visible Core/Python/CLI files are needed in the DMG. Internal Core/Python
paths remain undecided; the age helper location is fixed below. Desktop must not
require a repository clone, standalone
CLI installation or manual Python installation on a clean Mac. Standalone `bs`
remains independently supported for CLI/source users; Desktop does not fork Core.
Installing a Terminal command from Desktop is not a Stage 16 commitment.

Homebrew, `mas`, VS Code CLI and Git are prerequisites only for relevant selected
work according to Core. Desktop Secure Transfer uses bundled age and requires no
separate age or Homebrew installation. Other package composition and supported
architectures remain subject to qualification; signing credentials/infrastructure
are not assumed available.

## Bundled age — required for Desktop 1.0

**Implemented locally (Stage 16H checkpoint 4); Stage 17 qualification remains open.**
The authoritative artifacts are the official [age v1.3.2 release](https://github.com/FiloSottile/age/releases/tag/v1.3.2),
not an installed Homebrew binary. Both archives were authenticated on 2026-11-05
using their upstream Sigsum proofs, the two keys published in
[upstream SIGSUM.md](https://github.com/FiloSottile/age/blob/v1.3.2/SIGSUM.md),
and `sigsum-verify` v0.13.1 with its `sigsum-generic-2025-1` trust policy; both
verifications succeeded before executing the arm64 artifact. Public keys and
proofs are retained in `desktop/Macseed/Dependencies/age-v1.3.2/`.

| Official artifact | Archive SHA-256 | Extracted `age` SHA-256 |
| --- | --- | --- |
| `age-v1.3.2-darwin-arm64.tar.gz` | `e2020b073c44f692685a24d6abc378817eb81ffaaf49fd0531ef8565f767f2f5` | `4012dfc2725883beafb710894af4f599b7a94f8c8e0f51f02cc96ab8df33915e` |
| `age-v1.3.2-darwin-amd64.tar.gz` | `1d1e4bc66e1427edad7739ae7616157de0e79db8b6d2a1497d7d9925fb06a539` | `0c2fbcffab91d0af398162a8ed792e096916c8c47c3c400e303904431103f492` |

The single pin source is `modules/migration/age_runtime.py`. The archives contain
thin Mach-O executables for arm64 and x86_64 respectively; their `LC_BUILD_VERSION`
minimum is macOS 13.0. Desktop still targets macOS 14.0. Current local execution
qualification is arm64 only: verifying the Intel bytes does not qualify Intel,
Rosetta, universal packaging or the oldest supported macOS.

`prepare-runtime.sh` invokes `prepare-age.py` for one explicit target architecture.
Both the shell build and Xcode preparation use this path. It downloads a missing
archive from the fixed HTTPS release URL into ignored
`desktop/Macseed/build/Dependencies/age-v1.3.2/`; cached bytes are rehashed on every
use. A checksum mismatch fails preparation. Before publication it rejects duplicate,
extra, linked or unsafe archive entries and checks the extracted executable's hash
and architecture. Only the executable and complete upstream license are copied,
with fixed permissions; the other upstream tools/plugins are not shipped.
Sigsum/Go were used to establish the pins, not added as application or normal build
dependencies. Future pin changes require fresh upstream provenance verification.

- Executable: `Macseed.app/Contents/Helpers/age` (0755).
- Redistribution notice: `Contents/Resources/ThirdPartyNotices/age-LICENSE.txt`.
  Full upstream notice SHA-256: `afbdb4e07a359499db587ae632815809b1fc1670a92d5449af112ce9a67833a2`.
  Preserve the included age and Go BSD 3-Clause notices, conditions and disclaimers;
  do not imply endorsement. See [upstream license](https://github.com/FiloSottile/age/blob/v1.3.2/LICENSE).

Desktop supplies its explicit application path to Core through public launch
metadata. Core requires the exact helper location, rejects symlink traversal,
hardlinks, unsafe ownership/modes and nonregular files, and checks architecture
and the pinned executable bytes. It checks again after secure input before tool
execution. Desktop never falls back to PATH/Homebrew age; missing or damaged
helpers block selected secure work through existing errors while ordinary work
continues. The development app/checkout remain trusted code; this is not a claim
of signed distribution or resistance to concurrent modification by their owner.
Standalone CLI retains PATH resolution and `bundle_offer_age()` with explicit
Homebrew installation consent. No tool is downloaded or installed at application
runtime. No independent age updater exists: updates ship with Macseed releases.

`Contents/Helpers` is a [standard nested-code location](https://developer.apple.com/library/archive/technotes/tn2206/_index.html).
Stage 17 must sign the nested age executable and other nested code **before** sealing
the outer app, then qualify Developer ID, Hardened Runtime, entitlements,
notarization, stapling, DMG/Gatekeeper and clean-Mac secure workflows. Re-signing
changes executable bytes: Stage 17 must bind post-signing integrity to the verified
upstream input and release signing identity, without disabling validation. Never
modify a signed app to update age at runtime. Core/Python still use the development
checkout; autonomous packaging is not implemented by this checkpoint.

## Future whole-application updates

**Approved direction; not implemented.** A future Settings **Updates** tab will
support manual **Check for Updates…**, release review and user-confirmed
installation. Background checking will be configurable; automatic installation
requires an explicit approved user preference and a safe lifecycle. The exact
framework and implementation will be selected and qualified separately after
Stage 17 distribution/signing is ready. No placeholder tab or controls exist now.

Use a signed, verified update mechanism with atomic replacement of the entire
`Macseed.app`: native Desktop, bundled Core, Python/runtime, age and other packaged
components form one release. Never independently replace signed age within an
installed app, and never update external user-managed Homebrew, Git or other tools
as part of an app update. Installation must defer until active Capture, Rebuild,
Secure Transfer and every other owned Core operation are safely finished; checking
for a release is not permission to interrupt them. Stage 17 owns final signed-code
integrity qualification; Settings diagnostics reuse that single runtime policy.

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
