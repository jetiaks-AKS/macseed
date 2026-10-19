# Desktop MAS adapter — current integration boundary

The main Desktop build contains a restricted signed XPC client, SMAppService
helper and reviewed MAS 7.0.0. Core remains authoritative for Bundle selection,
Preview, Bootstrap order, progress, operation records and final Verification.
`MACSEED_MAS_ADAPTER` selects the fixed bridge for the existing app-store consumer;
CLI runs without that bridge retain their existing sudo contract. No Bundle, UID,
password, executable path or environment is passed through privileged XPC.

**Production recovery policy is implemented; its new live paths remain unqualified.**
A qualified, uninterrupted MAS exit plus independent bundle/signature/receipt
Verification produces `succeeded_verified`; a verified existing app produces
`already_present`. Both permit the next selected item. Unknown attempts stay
immutable and block automatic continuation. Explicit, expiring, per-ID recovery
grants can authorize a new attempt without manufacturing historical success.
Neither normal success nor risk acceptance asserts global Apple-service quiescence.

## Sources and trust

`Shared/Journal.swift`, `OperationLifetime.swift` and `Trust.swift` are promoted
from TrustedMAS; PoC source links use the same implementations. Production has its
own typed contract, Store and helper entry point; it exposes fixed install,
per-ID admission, status and Desktop-only recovery operations. The signed client has no arbitrary root-command facility.

The Debug build pins the previously reviewed Apple Development certificate and
MAS hash/source/patch manifest. It embeds Hardened Runtime signed components,
provenance and reviewed third-party notices. Build input locations are configurable
with `MACSEED_MAS_ARTIFACT_DIR` and `MACSEED_MAS_NOTICES_DIR`; defaults use the
existing qualified artifacts under `/private/tmp`. They are build dependencies,
not runtime paths. If those inputs/signing identity are absent, ordinary Debug
still builds without this privileged capability. Release does not package it until
distribution signing is explicitly configured. Never distribute this Debug build.

The application must be root-owned at
`/Library/Application Support/MacseedDesktop/Macseed.app`, with root-owned,
non-writable, ACL-free ancestry. Desktop checks before registration; helper checks
again. Build never installs/registers it. Root executes neither checkout nor
Homebrew MAS. The helper copies the fixed bundled source into closed root staging,
checks the copied signature and pinned hash, fsyncs and atomically publishes a
root-owned 0500 `mas-<SHA256>` under `/Library/Application Support/MacseedMAS`
(0700). `state.json` and `operation.lock` are 0600, protected/no-follow, with an
exclusive lock. Existing generations are not overwritten or deleted. Updates and
rollback retain the same journal; unknown remains blocking across app/MAS changes.
Existing PoC directories and journals are unrelated and untouched.

## Execution and verification

At confirmed Rebuild, only planned missing MAS entries request native SMAppService
approval. Rebuild waits asynchronously for native approval for up to two minutes,
then verifies a versioned authenticated XPC readiness response before continuing
the same confirmed plan. Duplicate clicks and Cancel cannot launch Execute.
Unknown/busy/session/incompatible-helper responses stop before Execute. If approval
is still pending, macOS requests restart, or authorization is refused, no install
starts: follow the displayed system instruction, then refresh Preview/Rebuild.
Debug Settings is diagnostic/unregister only; manual registration is not required.
Core installs only selected IDs not present in a fresh user inventory. Helper
rechecks inventory under lock and skips a race-to-already-installed ID.

Each privileged child follows durable launching intent → START_SUSPENDED → birth
identity and kqueue binding → durable resume intent → SIGCONT → bounded wait.
Install wait is 900 seconds; inventory wait is 30 seconds; client wait is 990.
These bounds never promise cancellation of Apple services. Fork/exec, lost identity,
disconnect, timeout, verification mismatch or incomplete owner recovery block retry.
A crash leaves durable launching/running, recovered to unknown under lock.

Helper checks inventory ID, direct bundle metadata, strict Apple-anchored code
signature and the receipt's CMS signature using the Mac App Store receipt policy
at the signed creation date. Signed receipt identifier/version must match.
Device binding and entitlement are not asserted. Missing/invalid evidence is
unverified, not absence. MAS inventory uses Spotlight, so a second inventory is
not an independent filesystem check. Recovery also inspects application folders
for partial downloads; private Apple queues remain unobservable. An operator
must review visible App Store downloads before consenting to residual risk.

MAS 7.0.0 awaits its download observer; it also has a PKInstallErrorDomain fallback
that spawns installer/mdimport. That descendant path is **not qualified** here:
NOTE_FORK/NOTE_EXEC remain unknown, not an ignored event or success. Account,
region and GUI/bootstrap context still require live install qualification.
Vendor output/account data never enters Core logs.

Before invoking XPC, Core writes its existing external-tool uncertainty marker.
Force Stop or parent loss cannot make a detached helper operation look complete.
The bridge disconnects when killed; the helper preserves unknown and does not
kill resumed privileged children or Apple services. Closing the window preserves
the shared Restore model; quitting follows existing Core cancellation semantics.

## Local validation

Build: `./desktop/Macseed/build.sh Debug`.
Desktop fixtures: `./desktop/Macseed/build.sh Debug --test`.
Adapter fixtures: `./desktop/PrivilegedMAS/test.sh "$PWD/desktop/Macseed/build/Debug/Macseed.app"`.
Core fixtures are in `scripts/test-restore-prepare.py`; new Desktop bridge tests
use disposable `.mbt` files and mocked MAS/client. They cover missing/present IDs,
selection of multiple entries, no sudo dependency, unknown propagation, refusal,
no automatic retry and stopping before the next mutation. Native lifetime tests
remain rootless fixtures; static signing checks do not replace live XPC qualification.

## Developer build / run / deploy

```sh
./desktop/Macseed/build.sh Debug
python3 desktop/Macseed/develop.py status
python3 desktop/Macseed/develop.py open
```

Without a protected installation, `open` starts the checkout GUI, which can inspect
and preview but cannot register the privileged MAS helper. With an installation,
`open` verifies it matches the current build; it refuses to open a stale version.
After explicit system-deployment approval, update with:

```sh
python3 desktop/Macseed/develop.py deploy
python3 desktop/Macseed/develop.py open
```

Quit Macseed before deployment. The developer script runs unprivileged. Only fixed
Apple system copy/inspection utilities use sudo; passwords go to sudo's own TTY,
never Python, argv, environment or a file. No root shell or checkout executable
runs as root. It creates a fixed root-only `.incoming` directory under the
protected parent, copies data, rejects unexpected objects/links/ACLs/modes,
compares every file to the pre-copy manifest and checks exact signed identities
before publishing. A failed check retains private staging and stops. Nothing
registers a helper or starts Restore automatically. This mechanism still needs
its first real system gate; local tests do not qualify privileged deployment.

The helper CodeDirectory, bundled MAS bytes and daemon plist define update
compatibility. Signing-time-only changes do not force re-registration. A compatible
GUI update preserves native registration. A changed helper/MAS/plist requires
native unregister first; a loaded helper must return authenticated non-busy status.
Debug Settings → App Store Helper shows native registration and provides async
unregister, refusing while this Desktop owns an active Core operation. Unregister
preserves all journals and does not claim to stop Apple services. The developer
status command inspects deployment without connecting to or registering a helper.

Previous signed app is retained as `Macseed.previous.app`; older backups are moved
to UUID-named siblings. A failed publish restores the previous app when possible.
After separately approved rollback, quit the GUI, unregister an incompatible
helper, verify the selected backup, preserve the current app under a different
protected backup name and restore the previous app at the fixed path. Rollback
never deletes or clears `MacseedMAS` state. Backups/private failed staging need
explicit reviewed cleanup. Debug still uses this checkout and Xcode Python;
this is not clean-Mac or distribution packaging.

No new Installer receipts are created by this workflow. The previously prepared
`MacseedDesktopMASLiveTest-v1.pkg` predates these changes: do not install it as the
current build. Third-party notices now live under `Vendor/ThirdPartyLicenses`;
the reviewed MAS artifact/provenance remain explicit external build inputs. No
Homebrew or developer tools are needed to execute bundled MAS itself; the current
Debug Core runtime still needs its declared development dependencies.

## First user-driven live test

1. Open the protected main Macseed, choose the real `.mbt`, select only Blackmagic
   Disk Speed Test **425264550** within App Store and deselect other categories.
2. Preview must show Missing. An already installed app is skipped, never removed.
3. Choose Rebuild and confirm. Approve the native background helper if requested;
   Rebuild continues automatically after approval and authenticated readiness;
   refresh Preview only if the wait ends or macOS requires a restart. No automatic retry follows.
4. Inspect Installation, independent Verification and Result. Verified normal
   success permits sequential items; timeout, disconnect, unqualified descendants
   or mismatched evidence produce Interrupted/Unknown and stop MAS mutations.
5. For unknown open **App Store Recovery**. Check Installation records evidence;
   cancellation targets only the bound process. An ownership gap requires a Mac
   restart and fresh review. Restart closes old OS process lifetime, not Apple work.
6. Only after review, inspect App Store downloads and explicitly allow one retry
   or the displayed remaining IDs. Refresh Preview with exactly that selection.
   No installation starts from Recovery, no automatic retry occurs, and permission
   expires in ten minutes. A new unknown invalidates remaining permissions.

## Production recovery

The signed Desktop calls the existing helper's bounded `recovery` endpoint;
MASClient cannot request recovery. Actions are fixed (`status`, `verify`,
`terminate`, `forceTerminate`, `reconcile`, `acceptRetry`, `acceptRemaining`),
with an operation ID and explicit confirmation for everything except status. No PID, executable, environment or
signal number comes from XPC. Console/session checks and both ownership locks
remain mandatory. Recovery during an active helper call returns busy: Stop or
900-second timeout must release the original owner first. Stop is still not a
promise to terminate MAS or Apple services.
After a helper update, **Enable Helper for Recovery** reuses native approval
without starting Restore. Accepting unknown for recovery readiness does not
relax installation admission.

Cancellation requires the journal-bound boot/birth identity, the current helper
as parent, protected MAS code, a kernel task audit token/PID version and a kqueue
exit observer. An exclusive durable intent precedes one SIGTERM and a maximum
30-second wait. A separate user confirmation can request one SIGKILL only after
recorded SIGTERM delivery and timeout. Missing result, identity mismatch, reboot,
reparenting, failed observation or an existing intent blocks automatic retry.
Debug native unregister first requests `prepareUnregister`: the helper checks all
recorded children and diagnostic ownership, then freezes new admission under its
coordinator lock. Missing exit evidence blocks unregister. This is not permission
to retry an installation.
The new cancellation implementation is fixture-tested; its deployed XPC/native
signal path still needs a separately authorized system qualification.

`recovery-<operation UUID>/` in the production state directory retains the exact
original journal, signal intents/results, verification evidence and operator
reviews (root-only). Read-only MAS inventory uses the same suspended lifecycle
and its own diagnostic journal inside that archive. A diagnostic interruption
blocks another diagnostic launch. After reboot, a separate explicit read-only
review can archive and resolve that non-mutating diagnostic; it never resolves
the original installation. Late direct-child reaping after Stop/timeout
writes `child-exit-<launch UUID>.json`; it never rewrites the mutation journal.
Existing protected external SIGKILL evidence is accepted only when the original
journal hash, operation, boot/birth identity, token version and executable match.

### Attempts, review and one-time admission

Schema v4 separates attempts/outcomes, review records, decisions and grants. The
first state-changing helper request archives exact v3 bytes as
`history-<SHA256>.json` before publishing the migrated head. It never resolves an
old unknown. At 32 active records, a hash-linked immutable snapshot preserves
history; unresolved barriers and the last attempt remain in the bounded head.
The same lock protects migration, review, grant consumption and launch intent.
No archive or original recovery evidence is deleted. A crash before head
publication leaves an idempotently reusable archive; a crash after grant
consumption cannot reuse permission.

A review binds operation digest, authenticated caller/session, boot, observation
and expiry. Explicit acceptance additionally records the operator's report of
no related active App Store download. This is disclosed residual-risk acceptance,
not machine proof of queue quiescence. Partial downloads, incomplete verification,
known active owned work, same-boot ownership gaps, trust/storage errors, stale
review and mismatched identity refuse permission. A reboot alone never grants it.

A grant lists exact numeric IDs and preallocated new attempt UUIDs. Core checks
per-ID admission during Prepare; helper rechecks ownership, session and fresh
inventory under its global lock. Grant consumption and new intent are one atomic
journal publication before spawn. If the app appeared, verified no-op replaces
install. A retry grant is not a remaining-app grant. The next interrupted attempt
becomes the recovery barrier and invalidates unused permissions. A successful
retry records an admission decision linking to the preserved unknown, never
changes the old outcome. Ordinary fresh Restore still requires its own confirmation.

Controlled cancellation continues to require process-bound audit identity. A
late child exit does not close the descendant-observation gap after timeout.
The existing Blackmagic unknown is readable without invented identity; same-boot
review requests restart when ownership cannot be closed. Existing external
SIGKILL evidence remains bound to the archived original bytes. This implementation
has not changed the installed app, root journal, registration or current incident.

Focused checks: `bash desktop/PrivilegedMAS/test-admission.sh`,
`bash desktop/PrivilegedMAS/test-recovery.sh`, Desktop MASAuthorization and
Presentation tests, and selected MAS cases in `scripts/test-restore-prepare.py`.
These are fixtures/read-only signature checks, not a real install qualification.

## Old experiments

PoC runtime entrypoints are archived and production tests now own required legacy
fixtures. Historical sources and live evidence are retained. See the exact
[cleanup manifest](CLEANUP.md); unresolved journals are preserved separately and
never used as evidence about the production state space. System cleanup and the
first deployment/live Restore require separate explicit approval.

Release gates: real sequential install and explicit recovery-grant qualification,
user-session/receipt and MAS descendant fallback qualification, root helper
crash/orphan cases, Developer ID signing/notarization, reviewed
update/downgrade deployment, clean-Mac Core/Python runtime, Intel qualification,
license audit completeness and testing without Xcode/Homebrew. Apple Development
and successful `codesign --verify` alone are not distribution qualification.
