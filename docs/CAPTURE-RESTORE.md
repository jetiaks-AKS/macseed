# Capture / Restore

Macseed reconstructs selected supported environment state:
**Capture → Rebuild → Verify**. CLI and development Desktop use the same production
Core. This document owns the workflow; [Desktop qualification](DESKTOP.md#recent-restore-qualification-and-performance)
records bounded real-Mac evidence, and [TODO](../TODO.md#remaining-supported-domain-restore-qualification)
tracks remaining supported-domain gates. Accepted flows do not establish universal
Install/Repair, complete visual effects or packaged clean-Mac readiness.

## What travels

Capture observes Homebrew/App Store applications, VS Code extensions/settings,
global Git configuration, supported SSH Host profiles, standalone Zsh `.zshrc`,
Workspace folders/repositories and supported macOS settings. Blueprint selects
categories and items; values remain in Generated Configuration. With no Blueprint,
the established all-inclusive compatibility behavior applies. Application Capture
builds a Blueprint from the confirmed selection.

Desktop calls the captured `.mbt` a **Saved Environment**: scan, choose supported
categories/items, choose a new destination, confirm freshly prepared scope and
save. Category-only domains stay whole; private SSH identities use the separate
[completed Stage 16H flow](#secure-identities). See
[Desktop](DESKTOP.md#capture-this-mac) for presentation and
[Environment Status](DESKTOP.md#environment-status) for implemented Bundle comparison.

Restore installs tools/applications, clones repositories from recorded remotes,
creates folders and restores selected settings. Git working files, `.git`, documents,
media, databases, caches and sessions are not copied. Only explicitly selected
`.code-workspace` folder relationships and display names are eligible Bundle metadata;
Restore recreates those relationships after their explicitly selected dependencies.
Arbitrary descriptor content is excluded; existing conflicting files are preserved.
Current Workspace Folders restores structure only. Future bounded transfer of
useful unique workspace/local data requires a separate explicit product and safety
contract; it is not implemented and does not imply general file migration.
Reconstruct safely reacquirable state, transfer unique portable state only where a
safe contract exists, and exclude disposable/derived state and obsolete artifacts
from migration. This does not authorize target cleanup.
Exact domain limits belong to [Configuration](toolkit/CONFIGURATION.md).

App Store Restore is assisted: Capture saves requirements, Restore selects and
previews them, and the user installs manually through Apple App Store before
refreshing Core verification. Confirmed shared identity gives Homebrew Cask
precedence; unresolved identity preserves both requirements. Automatic MAS
development is [archived](toolkit/ARCHITECTURE.md), outside the current workflow.

## Bundle and selection

Capture stages and validates data privately without replacing the source Mac's
ordinary Generated Configuration or Blueprint. It creates one private `.mbt`
using Bootstrap Bundle v1. Normal configuration is **not encrypted**; only
explicitly selected SSH key pairs are encrypted in `secure.age`.

Legacy Bundles retain supported Restore for ordinary Git repositories. New Workspace
Topology v1 Bundles support Capture, Rebuild Preview and confirmed Core Rebuild with
Global Verification. Selected base repositories precede linked/nested checkouts;
conditional branches/commits are checked again after Clone. Existing files are
preserved, and a matching repeat Preview needs no Rebuild. Selected VS Code workspace
descriptors are created without overwriting existing files; folder relationships and
display names are verified. Read-only Environment Status compares supported topology
and selected descriptor relationships against the original Bundle, preserving its
selection. Review in Rebuild passes only that Bundle and requires fresh Restore
inspection and confirmation. Technical details and recovery
limits belong to the [Workspace contract](toolkit/CONFIGURATION.md#topology-restore-execute--phase-4).

Settings inclusion, supported keys, unmanaged absence and the qualified Screenshot
Desktop-default exception belong to [Configuration](toolkit/CONFIGURATION.md#macos-settings).
Bundle v1 retains compatibility with older settings files; Capture result actions
and publication-backed counts belong to [Desktop](DESKTOP.md#capture-this-mac).

Review the Bundle and transfer it privately. Macseed does not provide transport
or synchronization. Checksums detect damage, not source authenticity.

Source selection is the Restore ceiling: groups can be disabled, absent
requirements cannot be added. Proven complete inventories may be retained for
later Comparison without expanding Apply. Supported HOME paths are normalized
by Bundle rules; arbitrary Zsh/VS Code content is not rewritten or guaranteed
portable.

## Prepare, apply and re-entry

Restore validates, narrows and previews staged state before Apply. Ordinary
`restore_prepare` does not decrypt identities; selected Desktop Secure Transfer
adds the separate authenticated [read-only comparison](#secure-identities).
Neither preparation nor comparison changes target configuration. After confirmation,
supported Restore Execute publishes ordinary local Generated Configuration and
Blueprint, applies the selected state and reports Verification. Later Workflow
uses that local state.

Publication recovery protects the previous local configuration pair at defined
failure points. It does not roll back installs, settings or key imports. Late
failure can leave partial changes. Re-entry means inspecting again, previewing
again and repeating idempotent actions. Matching supported state should converge
to no-op; genuine unsafe/ambiguous conflicts remain for user resolution. Selected
supported scalar Git settings with ordinary value drift are planned changes:
Restore writes the saved value, verifies it and then converges to Already Matches.
Unselected settings remain untouched; observation errors never mean absence.

Application Prepare returns a plan and prerequisites. Execute rebuilds them and
rejects a stale ID before publication. External prerequisite resolution requires
Refresh Preview and confirmation of the new plan. Desktop offers Fix Issues… for
available consent-bound preparation. Local unsupported Casks remain selected and
skipped while independent executable work proceeds; global prerequisites still
block execution. CLI confirmation uses the terminal.
See [Core interface](core/APPLICATION-INTERFACE.md) and [CLI](toolkit/CLI.md).

## Secure identities

**Stage 16H SSH Identities — COMPLETED (2026-11-05).** Core/CLI secure migration
and native Secure Capture/Restore are implemented and manually accepted in the
supported identity scope. Desktop Capture offers explicit, default-off identities
in Secure Transfer, beside Advanced under For Experienced Users, and uses the
existing Core engine through native secure fields and a separate inherited FD.
Desktop Restore selects the whole encrypted package, defaults off, and requires
authenticated read-only comparison through the existing Preview button. Matching
identities count as Already Match; missing identities as one planned requirement;
conflicts block import. Preview requests only the Bundle passphrase and compares
validated package/file state byte-for-byte, without unlocking individual keys.
This does not establish cryptographic validity of encrypted private keys. Actual
Rebuild requests the Bundle passphrase afresh, cryptographically validates every
private/public pair and obtains separate import confirmation. Protected-key prompts
identify the actual validated name, type and public fingerprint through transient
FD-only context. Exact-byte proof may avoid redundant key prompts within that
operation; passphrases are never cached or reused between operations. Existing
no-clobber import and verified evidence feed native Rebuild results. Desktop uses
verified bundled age without a separate age/Homebrew installation; CLI behavior
is unchanged. [Desktop](DESKTOP.md#secure-interactions) records accepted manual
E2E evidence; [Stage 17](DISTRIBUTION.md) still owns distribution and clean-Mac qualification.

Desktop **Add SSH Identity…** also admits explicitly chosen safe SSH pairs outside
`~/.ssh`, including a user-owned directory outside HOME. The adjacent `.pub` is
required; there is no recursive search, automatic selection or source modification.
Candidates join the same default-off selection and can be removed without deleting
files. Capture Review/confirmation explains the default destination
`~/.ssh/<validated-name>` in the receiving HOME. Source locations are not restored.
Rebuild Selection optionally configures existing custom directories through
[Customize](toolkit/SSH-IDENTITY-MIGRATION.md#optional-desktop-restore-directories). Existing Secure Migration v1 and `.mbt`
formats remain unchanged; names and bytes stay authenticated inside `secure.age`.
Prepare binds source evidence; Execute revalidates sources and cryptographic pairs.
Preview still unlocks only the Bundle, compares exact intended targets without
mutation and counts Secure Transfer as one requirement. The existing importer
preserves no-clobber, explicit consent, target freshness and verified evidence.
SSH Configuration is not rewritten: review `IdentityFile` if it expects another
location. This reminder does not infer private Host-profile relationships.
See [source safety and compatibility](toolkit/SSH-IDENTITY-MIGRATION.md#manually-selected-desktop-sources).

SSH Configuration is reconstructable Host-profile data. SSH identities are
separately selected existing private/public pairs handled by Secure Migration,
outside Generated Configuration and ordinary Bootstrap. The existing protected
SSH-key passphrase differs from the new `secure.age` passphrase. Store the Bundle
passphrase separately; imported keys retain their original encryption.

Import validates the complete package and all pairs, preserves matching files
and blocks the entire transfer on conflict. New files never replace existing
keys. Failed import stops dependent restoration, including clones; later failures
do not undo already imported identities. Applications supply a separate secret
channel; CLI uses terminal input. Package limits and standalone commands belong
to [Secure SSH Identity Migration](toolkit/SSH-IDENTITY-MIGRATION.md).

### SSH Environment Completion — Developer Environment Closure

**IN PROGRESS — combined integration remains planned.** Complete practical SSH Configuration support
across Discovery, Capture, Preview, Restore and Verification, prioritizing
`IdentityFile`, `IdentitiesOnly`, `AddKeysToAgent`, `UseKeychain` and other safely
portable SSH directives. This extends the bounded configuration contract without
reopening completed Stage 16H identity transfer.

Accepted Slice 3 implements optional per-identity restore directories, defaulting to
`~/.ssh`. Configuration belongs in the existing Rebuild **SELECTION** screen through a compact **Customize…**
sheet and native macOS folder picker. Accepting defaults requires no extra steps.
Preserve **SELECTION = configure; PREVIEW = read-only validation; REBUILD = execute**:
no destination editing in Preview, new top-level screen or separate SSH manager.

Validate `IdentityFile` references against the actual selected identity destinations.
Never silently rewrite SSH configuration; every proposed correction requires explicit
authorization. Resolve false Needs Attention results while preserving genuine
unsupported, conflicting and unsafe findings. Keep Secure Migration v1 Bundle
compatibility. A later joint SSH Configuration + identity E2E must cover default and
custom destinations, Verification and repeated no-op. The optional destination
slice does not complete this integration checkpoint.

## Results

Verification reports selected requirements, conformity and gaps with reasons.
Successful execution does not imply whole-Mac identity or application health.
Environment Comparison is a separate explicit observation; extras need sufficient
provenance and never imply removal. Start with the current
[CLI Quick Start](getting-started/QUICKSTART.md).

## External tool provenance and compatibility

New Capture state records the observed Homebrew version in optional Bundle v1
manifest metadata: `external_tools.homebrew.version`. It is diagnostic provenance,
not a Restore requirement. Older Bundles without the field remain valid, and
capture/target versions may differ when the required capabilities are present.
Bundle v1 additionally permits optional `generated/homebrew-casks.json` with
selected typed payload requirements and source observation status. Older Bundles
remain valid; missing payloads are never captured as verified installation evidence.

Restore uses domain-owned external-tool adapters for capability-based compatibility;
unknown metadata or lifecycle semantics fail closed. Homebrew owns native install
and reinstall. Repair checks run again immediately before native execution, with
the existing item watchdog, Safe Stop and authoritative final Verification.
See [Core execution policy](core/APPLICATION-INTERFACE.md#external-tool-adapter-results).
