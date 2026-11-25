# Capture / Restore

Macseed reconstructs selected supported environment state:
**Capture → Rebuild → Verify**. CLI and development Desktop use the same production
Core. This document owns the workflow; [Desktop qualification](DESKTOP.md#recent-restore-qualification-and-performance)
records bounded real-Mac evidence, and [TODO](../TODO.md#remaining-supported-domain-restore-qualification)
tracks remaining supported-domain gates. Accepted flows do not establish universal
Install/Repair, complete visual effects or packaged clean-Mac readiness.

## What travels

Capture observes Homebrew/App Store applications, VS Code extensions/settings,
global Git configuration, supported SSH Host profiles, standalone Zsh `.zshrc` or qualified static aliases,
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

Shell Capture preserves historical standalone snapshots and discovers independent
static aliases across qualified startup files and bounded HOME-relative source chains.
Capture/Rebuild Selection uses **Shell → Custom Commands → Aliases & Functions /
Scripts**, with individual alias rows and default-off per-file script consent.
**Add Script…** inside expanded Capture Scripts opens the native multiple-file picker,
including when no aliases or scripts were discovered. Picked standalone files are
checked by Core, deduplicated with alias-linked files and added unchecked. Select
their checkboxes to authorize inclusion. Rejected files show a reason; other valid
files in the same picker selection remain available. No script is run or changed.
Parent selection requires a separate informed choice before granting executable
transfer. Selecting a Capture file explicitly authorizes its automatic Core check;
only qualified files retain selection. No separate inspection action is required. Unsupported files stay visible as dependencies
and do not prevent alias-only Capture. A rejected script Prepare can return to
retained Selection; the next Prepare revalidates all current evidence. Core preserves
portable provenance and reconstructs selected closed static source chains, including
qualified missing directories/files and required source relationships. Existing
content and conflicting definitions are preserved. Selected script
files, executable or non-executable, require per-file consent in Capture Selection and independently in Rebuild
Selection; Capture consent is not inherited. Confirmation is read-only and summarizes
the selected files and unencrypted-code boundary inside Shell. Preview shows actual
actions/blockers with compact script context; Progress/Result use flat category rows
under Standard Setup / For Experienced Users, and Check
keeps direct diagnostics and matching results. No file metadata inflates alias counts. Capabilities 4/5 also allow an independently
selected file without aliases; this is one file requirement, with no alias or
startup reconstruction. See the [workflow-specific Desktop contract](DESKTOP.md#check-environment-status). Arbitrary
file migration and unresolved dependencies remain outside the qualified scope. Capability-3/4/5
Verification/Check includes qualified dependencies; partial Shell coverage remains
separate. Repeat Restore converges to no-op within that supported scope.

Scripts v5 uses unchanged `MBT-BUNDLE-1` with a bounded manifest and separate raw
file members: up to 128 files, 1 MiB each, and 16 MiB aggregate original content.
Harmless macOS encoding/download annotations are allowed under a closed policy.
Quarantine is preserved before atomic publication and checked afterward; it never
becomes a trust or execution grant. Existing targets are never overwritten.
Supported Shell/Python files can be executable or non-executable; extensionless
files need a supported shebang. Original supported permissions and bytes are
preserved. Missing safe parent directories inside destination HOME are created
as 0700 before file publication. Ownership, symlink, source freshness, no-clobber,
Git-managed destination and independent Restore consent checks remain enforced.
Legacy capabilities 1/2/3/4 remain readable under their original contracts.
File transfer never establishes safe execution or internal dependency availability.
Sensitive-content indicators block transfer, but absence of an indicator does not
prove a secret-free file; normal Bundle contents remain unencrypted.

Capture counts Aliases & Functions, Scripts, Variables & PATH and Shell Settings independently as functional domains
in Selection, Confirmation and Result, while retaining one physical Shell Core
module. Each selected declaration and unique script counts once; manual
and alias-linked discovery of the same file is deduplicated. Check emits file-level
bytes/mode evidence separately from definition matches.
Scripts transfers explicitly selected files, not directories. It is not a script
editor, launcher, dependency manager or general-purpose backup. Scan Folder and
Automation/LaunchAgents are deferred in the [Roadmap](../ROADMAP.md#post-10--future-direction).
**Aliases & Scripts v5 — Implemented / Real GUI E2E Accepted.** The
[A/B/C evidence](qualification/SHELL-RECOVERABILITY-2026-11-12.md#real-gui-abc-acceptance--2026-11-15)
records two aliases and two scripts captured, deliberately removed and restored,
four final Match results, a no-op Preview and independent source-integrity checks.
The existing partial Shell coverage warning remains outside that accepted scope.
Legacy whole-file requirements use **Shell Settings → Saved Zsh file** and retain absent-
target-only restoration. [Unified Aliases & Functions](toolkit/CONFIGURATION.md#unified-aliases--functions-b4)
supports mixed typed Capture/Restore/Verify/Check with explicit Native selection and
independent Scripts consent. The [real-Mac B4 acceptance](qualification/SHELL-UNIFIED-B4-2026-11-17.md#real-mac-gui-acceptance-2026-11-18)
restored all eight selected requirements, verified the commands and Script files,
and converged on a no-op Rebuild. Automated Check leaves runtime activation unverified.
[Variables & PATH](qualification/SHELL-VARIABLES-PATH-2026-11-20.md#controlled-real-mac-acceptance)
passed controlled mixed real-Mac acceptance. [Shell Settings](qualification/SHELL-SETTINGS-B6A-2026-11-25.md)
passed controlled real-Mac Capture, Restore, Verify and Check. Further integrations
require a separate product decision. Apart from the Scripts entry needed to add files, no empty
future categories, source browser or background monitoring is introduced. The
[Shell contract](toolkit/CONFIGURATION.md#shell--zsh-configuration) owns exact safety
and compatibility limits. Functional fixtures do not qualify effective interactive
startup or full Native Desktop/packaged clean-Mac E2E.

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
in For Experienced Users → SSH → SSH Keys, and uses the
existing Core engine through native secure fields and a separate inherited FD.
Desktop Restore selects the whole encrypted package or an authenticated identity subset,
defaults off, and requires
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
Choosing a key destination does not rewrite SSH Configuration. Explicitly review and
approve an `IdentityFile` correction if it expects another
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

**Implemented — joint real-Mac qualification remains open.** Bounded SSH Configuration
supports Discovery, Capture, Preview, Restore and Verification, including `IdentityFile`,
`IdentitiesOnly`, `AddKeysToAgent` and `UseKeychain` within the
[supported configuration contract](toolkit/CONFIGURATION.md#explicit-identityfile-resolution-and-v2-restore).
Stage 16H identity-transfer acceptance retains its original scope.

Accepted Slice 3 implements optional per-identity restore directories, defaulting to
`~/.ssh`. Configuration belongs in the existing Rebuild **SELECTION** screen through a compact **Customize…**
sheet and native macOS folder picker. Accepting defaults requires no extra steps.
Preserve **SELECTION = configure; PREVIEW = read-only validation; REBUILD = execute**:
no destination editing in Preview, new top-level screen or separate SSH manager.

Slice 4B qualifies `IdentityFile` references against local keys and authenticated selected
identity destinations. **For Experienced Users → SSH → Configuration → Host** shows an inline
correction only for a selected reference needing attention: original reference,
qualified proposal and explicit approval. Custom destinations never rewrite paths
automatically; approved corrections and remaining unresolved references are counted
separately.
Configuration and SSH Keys (the existing Secure Transfer domain) remain independently selectable beneath the
presentation-only SSH disclosure in Capture and Rebuild. Original IdentityFile
references are preserved during safe configuration-only restoration; missing or
unverified keys produce one advisory, not a publication blocker. Explicit approved
corrections still require qualified evidence. Configuration Verification and key
qualification are separate; neither claims remote authentication.
Safe create/no-op/missing-Host merge retains existing conflicting Hosts unchanged.
[Configuration](toolkit/CONFIGURATION.md#explicit-identityfile-resolution-and-v2-restore)
owns publication, dependency and stale-plan safeguards. SSH-dependent Git clones use
bounded local qualification and fresh Execute checks after selected identity import
and configuration publication; HTTPS and local Git operations remain independent.
Secure Migration v1 and Bundle compatibility are preserved.

Check authenticates saved keys and compares exact private/public bytes read-only at
default or explicit custom locations. Its one aggregate SSH Configuration `config`
result stays separate from SSH Keys. A reference warning can clear only when Core
proves complete, unambiguous correspondence between the configured paths and the
authenticated selected pairs in that operation. This includes passphrase-protected
files but does not prove private-key usability or remote authentication. Legacy
partial configuration coverage remains Needs Attention. See the
[Check evidence contract](core/APPLICATION-INTERFACE.md#optional-protected-ssh-check).

Unified Developer UI is visually accepted; implementation and local fixture results
do not establish hosted CI or joint real-Mac E2E qualification. Joint SSH Configuration
and identity E2E still must cover default/custom destinations, dependent Git clones,
Verification, Check and repeated no-op. Stage 16/17 qualification remains open.

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
