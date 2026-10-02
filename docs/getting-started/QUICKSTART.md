# Macseed CLI Quick Start

Use the current CLI to configure this Mac or move supported state between Macs.
Native Desktop is planned and is not needed for these workflows.

## Prepare

Current CLI prerequisites include macOS 15+, Git, Xcode Command Line Tools,
internet and an administrator account for the workflows that need them.
Homebrew can be offered interactively when missing. Optional application domains
need `mas` for App Store and `code` for VS Code extensions; secure identity
transfer needs `age`. Python 3 is needed for Bundle and secure operations.

Clone on each Mac:

```bash
git clone git@github.com:jetiaks-AKS/macseed.git
cd macseed
./bootstrap.sh --help
./bootstrap.sh --version
```

Run `bootstrap.sh` from this root. Bootstrap installs the optional `bs` launcher;
after installation, `bs` works from any directory. An unrelated `bs` is not replaced.

## Configure this Mac

```bash
./bootstrap.sh --workflow
# After bs is installed:
bs workflow
```

Workflow offers/requires Discovery, lets you choose a Blueprint and shows Preview.
It applies only after `Apply these changes with Bootstrap? [y/N]`. No planned
changes means no Bootstrap. `q`/`Q` cancels selection without saving.
Discovery publishes local generated state; Apply can install apps, write settings
and restart affected macOS processes. Review the plan before confirming.

## Move to a new Mac

1. On the source Mac, run `./bootstrap.sh --capture` or `bs capture`. Select the
   supported state, review Preview and optionally select SSH identities. Capture
   creates one private `exports/bootstrap-*.mbt` without replacing normal source
   Generated Configuration or Blueprint.
2. Review and transfer that Bundle privately. Its normal configuration is
   **not encrypted**; only selected identities in `secure.age` are encrypted.
   Keep the Bundle passphrase separately.
3. On the target Mac, run `./bootstrap.sh --restore /absolute/path/environment.mbt`
   or `bs restore /absolute/path/environment.mbt`. Review source selection, disable
   unwanted groups and inspect Preview. Restore may first recover an interrupted
   local publication. Cancelling before Apply preserves unpublished staged state.
4. Confirm `Apply this selection with Bootstrap? [y/N]`. Selected secure import
   validates all pairs and requires typing `import` before dependent clones.
   Conflicts, errors or cancellation stop dependent restoration. Later failure can
   leave partial changes; it does not roll back imported keys or installs.
5. Review Verification. Later use `bs workflow` from ordinary local state and
   explicit `bs compare` for Environment Comparison. Without the launcher, use
   matching `bootstrap.sh` modes from the root.

For a protected SSH identity, Capture asks for its **existing key passphrase**.
The **new Bundle passphrase** encrypts `secure.age` and is needed at Restore;
it is a different secret. If the CLI `age` prompt is left empty, record the
passphrase it generates and shows once. Missing `age` is offered explicitly,
never installed silently. Keys retain their original encryption.

Macseed reinstalls applications and clones repositories from remotes. It does
not copy working trees, `.git`, documents, libraries, caches, sessions or databases.
Supported settings are reconstructed; arbitrary Zsh/VS Code contents may be
source-specific. Selected SSH identities are the supported physical secure transfer.

## Individual controls

Use `bs discover`, `bs blueprint`, `bs preview`, `bs bootstrap` or their
`bootstrap.sh` modes when individual control is useful; they are not mandatory
steps before Capture/Restore. Check can request administrator authentication and
offer Homebrew installation. Generated Configuration and Blueprint are private
local files, not Git content. Manual transfer of reviewed `config/generated/`
and optional `config/blueprint.conf` remains supported; without Blueprint the
established all-inclusive behavior applies.

Use `--verbose` for diagnostics and `logs/latest.log` for the latest run.
Ordinary CLI lifecycle exits are `0` success, `1` warnings, `2` errors; execution
success is distinct from verified conformity. Comparison does not remove extras.

See [Capture / Restore](../CAPTURE-RESTORE.md), [CLI](../toolkit/CLI.md),
[Configuration](../toolkit/CONFIGURATION.md) and the standalone
[secure identity commands](../toolkit/SSH-IDENTITY-MIGRATION.md) for details.
