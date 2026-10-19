> Historical experiment, superseded by `desktop/PrivilegedMAS/`. Build/package
> entrypoints are archived under `desktop/AuthorizationPoC/History/`; do not run
> the historical commands below. Live evidence remains authoritative for its gate.

> Current source candidate: [Controlled Blackmagic v7](CONTROLLED-BLACKMAGIC.md).
> It has not been installed or live-qualified. Historical deployment evidence below
> does not qualify the new install path.

# Trusted MAS deployment development checkpoint

Source candidate v5 adds suspended owned launch, schema 3 lifetime records and
targeted controlled admission. It is locally tested, not installed; both MAS launch
gates remain disabled. Installed v4 is unregistered; legacy reconciliation remains
blocked by a separate operator-policy requirement in the new source; see [current checkpoint](CONTROLLED-INSTALL-STAGE1.md). The text below
describes the previously qualified diagnostic deployment. The pinned LIVE-RESULTS
evidence document is intentionally unchanged.

This separate app/helper does not participate in production Restore. The diagnostic baseline exposes no install, get, update, reset, shell execution
or arbitrary executable/UID/environment input. Its XPC operations are `deploy`,
`version`, `list`, `state`; Stage 1 adds typed preflight/reconciliation/install
selectors with live install independently disabled in app and helper. The original UID
AuthorizationPoC remains unchanged.

## Trust and deployment contract

The reviewed artifact is the patched upstream MAS v7.0.0 commit
`7c70ffdfd9f71a654300a78b3b627782e6abe1b4`; its compatibility patch digest is
`f7c6b6ad069f67992cefdf6fc1925167091b4c4ae3578ee7ac58de7dbedf04fd`.
`build.sh` snapshots the previously built artifact, checks the pinned provenance,
and packages the manifest, patch, reproduction notes and third-party notices in
the signed outer app. The development signature attests this reviewed payload;
it is not independent proof of a reproducible source-to-binary build.

Root does not trust the source pathname or a caller-supplied hash. It copies the
fixed bundled MAS through an opened file descriptor to an exclusive staging file
inside `/Library/Application Support/MacseedTrustedMASPoC` (root, 0700), validates
that closed-to-users snapshot with Security.framework against the Apple anchor,
exact certificate/identifier, and separately pinned reviewed digest, fsyncs, and
publishes with `renameatx_np(RENAME_EXCL)`. The executable is root-owned 0500.
Directory traversal uses openat/O_NOFOLLOW, checks root ownership, writable mode
bits and extended ACLs. Root state/lock files are private, no-follow, single-link
regular files. Symlinked ancestors or conflicting existing payloads fail closed.
Revalidation occurs before each execution. No executable is run from checkout,
Homebrew or /private/tmp. Protection assumes the OS/root administrator is trusted.

The PoC app itself must be deployed root-owned at
`/Library/Application Support/MacseedTrustedMASPoC-App/MacseedTrustedMASPoC.app`
with root-owned, non-writable, ACL-free ancestors before registration. The existing
/Applications directory is admin-group writable and is not used for this PoC. The prepared local installer package has no scripts and is unsigned
as a package; its nested app/helper/MAS are development-signed. Installing this
development package requires explicit user consent and macOS Installer approval.
It is not a distribution-ready package. Never register the temporary build.

## Caller/session and runtime limits

Both XPC peers pin certificate and identifier. The helper obtains UID, GID and
audit-session ID from NSXPCConnection, checks graphical-session attributes through
SessionGetInfo and matches the current console user at admission and each call.
It does not accept these identities in the request. Client disconnect before
admission prevents starting work; disconnect during work persists unknown when
the operation returns. A helper crash leaves running on disk, which blocks restart
and is converted to unknown on the next valid request.

Only the installed root-controlled MAS can execute, with fixed arguments and a
constructed system PATH/environment. SUDO_UID/GID come from the authenticated
caller and bind MAS effective identity; they do NOT prove GUI/bootstrap context.
Results explicitly report `gui_bootstrap_unproven`. Inventory projection returns
numeric IDs only, not account data or vendor stderr. Matching user inventory alone
does not prove account/entitlement or GUI-bootstrap equivalence. No launchctl
context-switch workaround is used.

The artifact's direct dependencies and sole /usr/lib/swift RPATH were inspected in
the preceding checkpoint. Actual loaded mappings through the privileged path and
clean-Mac runtime without Xcode/Homebrew are pending real qualification.

## Lifecycle and updates

An in-process lock and root-private flock serialize operations. Persistent state
is written atomically and fsynced: running/completed/failed/unknown. Any uncertain
operation failure, response/output timeout or disconnect during execution leaves
unknown; no retry or public reset exists. Known read-only success becomes completed.
Failed is reserved for future proven pre-execution failures; current uncertain
failures conservatively become unknown. A 30-second diagnostic timeout does not
signal the child and never treats PID disappearance as Apple-service quiescence.
Normal child exit proves only this diagnostic invocation completed.

This checkpoint never replaces an installed different generation and never rolls
back automatically. Re-deploy of the exact verified payload is a no-op. A future
update must have a new reviewed signed manifest, fully validated private staging,
an exclusive lifecycle lock and an atomic generation switch; retain the old
verified generation. Explicit rollback must revalidate its signature/dependencies
and may switch only with no active/unknown operation. No MAS install rollback or
external-service completion guarantee is implied.

## Validation and manual gates

Build outside checkout with a fresh output directory:

```sh
bash desktop/AuthorizationPoC/TrustedMAS/build.sh /private/tmp/UNIQUE_OUTPUT
```

The build verifies nested signatures and runs offline tests for invalid operations,
wrong UID/session, unknown restart refusal, trusted/foreign/tampered MAS validation
and an empty ACL. These tests do not qualify root publication, overlapping live
XPC calls, crash durability or runtime rejection of foreign clients.

Before root changes or registration, show and approve the exact package/app/state
paths. Then: install the root-owned app; register and approve its helper; Deploy;
verify ownership/modes/signatures and no-clobber re-deploy; run GUI version/list;
compare numeric IDs with user inventory; test rejection of foreign/ad-hoc clients
while a trusted client succeeds; test duplicates and interruption without installs.
Afterwards unregister and verify service/process cleanup. Keep the protected MAS
and unknown state until explicitly approving removal; do not reset global trust
or background-item settings.

## Third-party notices

The app includes MAS MIT license; BigInt, Chronometer, Sextant, Spanker and SwiftSoup
license files; Hitch's MIT license from README and its MD5 attribution header;
gram, swift-json, swift-argument-parser, swift-atomics and swift-collections Apache
licenses and available NOTICE files. The Hitch MD5 header includes BSD/MIT
attributions. A release notice audit, including embedded third-party sources and
Swift runtime redistribution if ever bundled, remains a distribution gate.

## Bundled MAS build evidence

IMPLEMENTED / locally VERIFIED: official tag `v7.0.0` at the commit above, arm64
Release built with frozen dependencies on Swift 6.4. Only redundant `unsafe` before
`withUnsafePointer` (MAS.Config.swift) and `items.joined` (Printer.swift) was removed;
other safety annotations, warnings-as-errors and Package.resolved were preserved.
The signed artifact has Hardened Runtime. Direct Mach-O dependencies are system
paths (including private CommerceKit/StoreFoundation); remaining LC_RPATH is
`/usr/lib/swift`. No Homebrew wrapper is needed for the qualified version/list
commands. On macOS 26.7.1, version reported 7.0.0+ and list --json matched all 16
Homebrew MAS inventory IDs with a system-only PATH. This is not clean-Mac proof.

Staging `/private/tmp/macseed-mas-swift64-artifact/` contains `mas`, `swift64.patch`,
`manifest.json` and `REPRODUCE.md`; build.sh seals copies in the app resources.
Signed MAS SHA-256:
`d10cc734ca3e3af8b403a5b30215dbb6b8b179632451e9bb381376061a0808bf`.
The manifest pins source, patch, resolved dependencies and signed artifact; the
reproduction notes describe build and RPATH normalization. Reproducible procedure
is documented; independent bit-for-bit reproduction has not been demonstrated.
A SHA or matching path alone never authenticates a user-writable executable.

Homebrew's user-writable symlink/wrapper/libexec chain is unsuitable for privileged
execution. Ad-hoc signing does not establish reviewed provenance. The solution
qualified here is signed bundled payload, protected staging and root publication,
not trusting Homebrew paths or executing the temporary artifact as root.
