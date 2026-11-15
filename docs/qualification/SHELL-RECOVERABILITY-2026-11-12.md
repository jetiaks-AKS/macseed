# Shell alias recoverability — 2026-11-12

Current status: **Aliases & Scripts v5 — Implemented / Real GUI E2E Accepted**
within the [A/B/C scope below](#real-gui-abc-acceptance--2026-11-15). Broader Shell
coverage remains partial.

Historical status on 2026-11-12: **PARTIAL.** This retains the accepted read-only
assessment of the accumulated uncommitted capability-3 checkpoint on `develop`,
based on `7cf6c402c876a162d6596e4b4890997b60a2ca03`. It is not hosted, clean-Mac or
interactive-shell qualification. Capture Prepare repair alone did not close
these recovery gaps. The [Configuration contract](../toolkit/CONFIGURATION.md#remaining-shell-recovery-integration-planned)
owns the concrete future integration plan.

## Observation boundary

Twelve static aliases were identified through the qualified source graph. Startup
files were read as data without execution, indiscriminate HOME traversal or writes.
The targeted script review did not execute or transfer the script. Observed file
bytes and checked metadata were unchanged. Only user-authorized alias names and
sanitized classifications are retained here; no command bodies, private paths,
repository addresses, credentials or script contents are included.

## Recoverability on a clean destination

| Alias | Classification | Sanitized reason / remaining requirement |
| --- | --- | --- |
| `vps` | External prerequisites | Startup/source reconstruction and qualified local SSH prerequisites; remote connectivity/authentication are separate operational claims. |
| `macpro` | External prerequisites | Same startup and local SSH dependency boundary. |
| `macpro-lan` | External prerequisites | Same local recovery boundary; network reachability is not a declaration-restoration test. |
| `ll` | Fully recoverable within the qualified static scope | Independently selected standard alias can be reconstructed in a missing default startup file. |
| `la` | Fully recoverable within the qualified static scope | Same independent-selection boundary. |
| `c.` | External prerequisites | Editor CLI is unqualified, not proven absent; startup/source reconstruction also remains required. |
| `reload` | Unsupported or uncertain completeness | The full startup behavior is not captured; definition/file presence does not prove recovery of that behavior. |
| `projects` | Managed source blocker | Requires owner-restored source checkout, startup relationship and qualified destination directory. |
| `bootstrap` | Managed source blocker plus missing dependency | The destination directory is absent on the observed source Mac as well. |
| `dotfiles` | Managed source blocker | Requires owner-restored source checkout, startup relationship and qualified destination directory. |
| `infra` | Managed source blocker | Static provenance is confirmed; source checkout, startup relationship and destination checkout/directory must be restored. |
| `adns` | Automatic transfer unsupported; completeness uncertain | Script control flow, privilege use and external/transitive dependencies exceed the bounded wrapper contract; a Git-backed route needs separate qualification. |

At that checkpoint, only `ll` and `la`, selected independently, qualified for clean-HOME recovery
without external preparation. Selecting all twelve was blocked, without partial
automatic publication. None of the twelve became fully recoverable solely by
granting file-transfer consent. These are configuration-recovery classifications,
not promises about subsequent command execution.

## Managed sources and script dependency

The four managed definitions were traced to a tracked source in one Git repository.
The `infra` destination and `adns` dependency involve a second repository. Both local
worktrees passed existing read-only Git/topology and inert-hook inspection; observed
source bytes matched tracked content. Remote accessibility and availability of the
required commits were **NOT TESTED**. None of the four aliases is blocked solely
by source ownership on an empty destination: startup relationships also need recovery,
and `bootstrap` has an additional missing directory.

The supported manual route is explicit selection/restoration of qualified repositories
and folders through existing Workspace capabilities, owner-provided startup integration,
then fresh Shell Preview. Resolve necessary local SSH prerequisites through their
existing owner first. No managed source is overwritten or synthesized as unmanaged.

The real `adns` dependency is safely observable and executable. Supporting safe `0755`
permissions removed one unnecessary restriction, but did not qualify its body for
transfer. Existing-dependency Match remains metadata availability, not byte equality,
transitive-dependency qualification or successful execution. A sensitive-content
indicator was ambiguous; it did not establish that a credential was present.

## Retained validation and open gates

The preceding local checkpoint passed 12 focused Recovery cases, one Capture API
case, two Restore API cases and one Bundle compatibility case, with two affected
Recovery cases repeated after the final correction. Sanitized fixtures covered
consent, safe modes, startup activation exclusion, directory dependencies, managed
source blockers, concurrent changes, Verify, Check and repeat/no-op. External managed
recovery was simulated; these tests do not prove a real remote checkout or manager
integration. Native/legacy evidence was reused only for unchanged code.

Full local regression, application-wide E2E, hosted CI and real destination-Mac
recovery were **NOT RUN**. The gaps in the matrix and the planned Core integration
remain open independently of Capture Prepare/Confirmation correctness.

## Real GUI A/B/C acceptance — 2026-11-15

The user accepted the accumulated uncommitted `develop` checkpoint based on
`7cf6c402c876a162d6596e4b4890997b60a2ca03`, using the actual native Capture,
Rebuild and Check flows on macOS. This is bounded real-Mac evidence, not hosted CI,
distribution qualification or execution of arbitrary Shell configuration.

| Case | Accepted objects |
| --- | --- |
| A | One standalone alias |
| B | One alias and its explicitly selected executable Shell script |
| C | One independently selected extensionless script with no alias reference |

Capture saved two aliases and two script files. Initial Check reported **4 Match**;
controlled removal produced **4 Missing**. After the scoped Restore corrections
and separately authorized archival of failed-operation evidence, real GUI Rebuild
restored all four objects. Final Check reported **4 Match**; a fresh Preview reported
**4 Already Match**, zero planned changes. Independent read-only production readers
confirmed the same four identities and no writes or directory creation.

Both script files matched the Bundle byte-for-byte and by SHA-256 with mode `0700`.
Their saved and restored quarantine state was absent; quarantined-file behavior is
covered separately by focused positive and fail-closed tests. The existing dynamic
tracked `.zshrc` retained all 3649 unrelated baseline bytes, ownership, mode `0644`,
UF_TRACKED, document ID and required xattrs. Atomic safe-save changed the inode and
OS-owned provenance as documented; the original inode and metadata remained in
completed predecessor evidence. Independent integrity postflight: **PASS**.

Final authorized fixture cleanup removed only the exact 143-byte alias suffix and
the two fingerprint-verified scripts. Disposable tracked-file qualification preceded
descriptor-bound in-place truncation. Postflight confirmed baseline bytes, unchanged
inode/document ID/UF_TRACKED/owner/mode and unrelated metadata; mtime/ctime and
OS-owned provenance changed as explicitly permitted. At cleanup postflight, both
Bundle copies, original backups, archived failure evidence and completed predecessor
evidence were intact. The user subsequently removed or moved the Bundle copies and
fixture directory; retained source and recovery evidence passed the final review.
Cleanup is a one-time acceptance operation, not a production alias-deletion feature.

The existing **partial Shell coverage** warning remains. This acceptance proves
saved declarations and selected file transfer, not complete effective dynamic Shell
state, managed-dotfile integration, transitive dependencies or script execution.
Standalone Functions and other future Shell slices retain the Roadmap order.
