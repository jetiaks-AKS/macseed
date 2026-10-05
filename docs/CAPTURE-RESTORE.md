# Capture / Restore

Macseed reconstructs selected supported environment state:
**Capture → Rebuild → Verify**. The CLI implements this workflow today. Desktop
Capture uses the same production Core; its Stage 16E end-to-end manual gate is approved.
Desktop Restore preparation/execution uses the same Core. Its broad manual gate
substantially passed at checkpoint `3e555fba`; compatibility and remaining Desktop
qualification are tracked in [TODO](../TODO.md#broad-restore-manual-gate--2026-10-05).

## What travels

Capture observes Homebrew/App Store applications, VS Code extensions/settings,
global Git configuration, supported SSH Host profiles, standalone Zsh `.zshrc`,
Workspace folders/repositories and supported macOS settings. Blueprint selects
categories and items; values remain in Generated Configuration. With no Blueprint,
the established all-inclusive compatibility behavior applies. Application Capture
builds a Blueprint from the confirmed selection.

Desktop calls the captured `.mbt` a **Saved Environment**: scan, choose supported
categories/items, choose a new destination, confirm freshly prepared scope and
save. Category-only domains stay whole; private SSH identities remain outside
Stage 16E. See [Desktop](DESKTOP.md#capture-this-mac) for presentation and the
deferred final product reference requirement for Environment Status.

Restore installs tools/applications, clones repositories from recorded remotes,
creates folders and restores selected settings. Working trees, `.git`, documents,
media, databases, caches and sessions are not copied. `.code-workspace` metadata
is discovered but has no restoration consumer and is excluded from Bundles.
Exact domain limits belong to [Configuration](toolkit/CONFIGURATION.md).

## Bundle and selection

Capture stages and validates data privately without replacing the source Mac's
ordinary Generated Configuration or Blueprint. It creates one private `.mbt`
using Bootstrap Bundle v1. Normal configuration is **not encrypted**; only
explicitly selected SSH key pairs are encrypted in `secure.age`.
Review the Bundle and transfer it privately. Macseed does not provide transport
or synchronization. Checksums detect damage, not source authenticity.

Source selection is the Restore ceiling: groups can be disabled, absent
requirements cannot be added. Proven complete inventories may be retained for
later Comparison without expanding Apply. Supported HOME paths are normalized
by Bundle rules; arbitrary Zsh/VS Code content is not rewritten or guaranteed
portable.

## Prepare, apply and re-entry

Restore validates, narrows and previews staged state before Apply. Preview does
not decrypt identities or change target configuration. After confirmation,
Restore publishes ordinary local Generated Configuration and Blueprint, applies
the selected state and reports Verification. Later Workflow uses that local state.

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
Check Again and confirmation of the new plan. CLI confirmation uses the terminal.
See [Core interface](core/APPLICATION-INTERFACE.md) and [CLI](toolkit/CLI.md).

## Secure identities

Core/CLI secure migration is implemented; the Desktop Secure SSH Capture/Restore
bridge and real application qualification remain unfinished (Stage 16H).

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

## Results

Verification reports selected requirements, conformity and gaps with reasons.
Successful execution does not imply whole-Mac identity or application health.
Environment Comparison is a separate explicit observation; extras need sufficient
provenance and never imply removal. Start with the current
[CLI Quick Start](getting-started/QUICKSTART.md).
