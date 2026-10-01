# Macseed Architecture

English | [Русский](ARCHITECTURE.ru.md)

## Purpose

Workflow uses Discovery → Blueprint → Preview → Bootstrap on the current Mac.
Capture orchestrates those existing components in private staging on the source
Mac and publishes a Bootstrap Bundle. Restore validates and previews staged
input on the target Mac, then publishes the ordinary generated/Blueprint pair
before Bootstrap. Publication recovery protects the previous local pair.
Restore Bootstrap validates all selected input, prepares prerequisites, then
uses the existing SSH configuration consumer and explicitly confirmed Secure
Credentials importer before Workspace cloning. A prerequisite failure stops
dependent restoration; later failures do not roll back imported identities. The Bundle
is transport only, so later Workflow runs from local state.

The structured Core interface now supports `restore_execute` for a temporary,
limited application-safe subset. It repeats Bundle validation, narrowing and
production Preview, recomputes `prepared_plan_id`, and rejects stale plans before
readiness or publication. The ID identifies the plan confirmed by the caller;
it is not authorization. Its read-only readiness gate accepts selected Homebrew
formulae when Homebrew is usable, including an installation under the supported
architecture prefix that needs process PATH activation. It rejects absent or
broken Homebrew before publication, without silently omitting selected work.
Selected secure identity work requires the separate inherited secret channel. Automatic Homebrew installation is currently unavailable;
guided prerequisite handling is the required 4.0 baseline. The current subset
also includes ordinary settings and Workspace folders;
application coverage must grow toward
the existing practical CLI Restore capabilities before native app Restore is
considered complete. Secure Restore uses the existing importer through a transient credential bridge.
Owned Bootstrap children have no interactive stdin or
controlling terminal, Macseed does not ask its own questions, and sudo uses
non-interactive authorization. External tools or macOS may still create
independent GUI dialogs. A separate descriptor marks when target mutation may
start, and the owned process group can be cancelled without changing the
human CLI path. Production Global Verification provides aggregate conformity
facts separately from execution status. Failure after the mutation boundary
may leave partial target changes; publication recovery is not a transactional
rollback of Bootstrap.

The ordinary path reconstructs selected state supported by Bootstrap consumers.
Applications are installed, repositories are cloned, and supported settings
are configured; working trees and user data are not copied. SSH Configuration
is a reconstructable set of Host profiles. Only explicitly selected SSH
private/public identities cross the separate encrypted Secure Migration
boundary in `secure.age`. This is not general machine or data migration.

Macseed is a modular Bash system for discovering and
reproducing supported parts of a macOS working environment. This document
defines the current component responsibilities, state flow, boundaries, and
architectural invariants. Development sequencing belongs in the Roadmap;
configuration formats and value-level contracts belong in Configuration.

### Application Secure SSH Restore

The future Desktop launcher creates one anonymous connected Unix stream socket
pair and passes only Core's endpoint as an inherited descriptor greater than 2:
`modules/core/application-interface/core.sh --secure-fd N`. This is launch
metadata, not a JSON parameter. Core validates the descriptor and disables
inheritance; path-resolution children close it before running external tools.
Callers without a valid channel still receive `secure_bridge_required`.
Structured JSON stdin and JSONL stdout carry only operation data and safe events.

Each private frame starts with an unsigned four-byte big-endian body length
(1–2048 bytes). Core challenges contain JSON **metadata only**: `type=challenge`,
`protocol_version=1`, `operation_id`, a fresh 32-hex-digit `challenge_id`, `kind`,
and `attempt` (1–3). Kinds are `bundle_unlock`, `ssh_key_unlock`, and
`import_confirmation`. Responses are binary: the 16-byte decoded challenge ID,
then `S` plus a UTF-8 passphrase, `Y` alone to confirm, or `C` alone to cancel.
Passphrases are limited to 128 bytes and exclude control characters. Response
JSON, mismatched IDs, unsolicited input, invalid lengths, EOF and timeout fail
closed. A complete response has a 120-second deadline; secret tools have a
30-second deadline. The peer keeps its endpoint open until Core closes it or
explicit cancellation is intended. No listener or filesystem secret IPC is created.

Execute fully re-prepares, checks the expected plan and readiness, rechecks
source/stage fingerprints, and publishes the ordinary pair before importing
**that operation's staged** `secure.age`. Core owns the existing Stage 12 importer
in a separate process group and relays challenges over a second anonymous socket
pair. Only the importer receives that internal descriptor. Secret-consuming
children receive only their isolated PTY and, for age, the pinned ciphertext FD.
The PTY has echo disabled before any secret is written, is never Core's
controlling TTY, and its prompts/output never enter JSONL or logs. Bundle unlock
and individual protected-key unlock are separate interactions, each with at
most three attempts. Keys retain their original encryption and validation.
The existing import confirmation is adapted to the private channel; an identical
identity plan needs neither confirmation nor publication.

The importer retains Stage 12 protected staging, payload/pair validation,
conflict checks, no-clobber publication, permission checks and cleanup. It asks
Core to acknowledge the mutation boundary immediately before creating `.ssh`
or publishing the first identity in an existing directory. Reading a secret,
decrypting and validating do not mark target mutation. Failures after this
boundary remain conservative even if the importer removes its own new files.
Peer EOF, explicit cancellation and Core SIGTERM stop the owned process group;
Cancellation signals are deferred while private staging is removed; cleanup after
SIGKILL or power loss is not guaranteed.

Core validates the existing attempt-bound importer evidence and closes the
secret channel before ordinary Bootstrap. Only non-secret evidence reaches
Bootstrap through an anonymous temporary file descriptor, consumed and closed
before other children run. Production Global Verification retains
`identity_pair_matches_package`; it does not claim remote authentication or
Keychain/agent state. Typed importer failures also use this evidence for
Verification when available. A transport failure may leave Verification not run.
A failed secure import stops dependent restoration. A successful import precedes
the ordinary Bootstrap prerequisites and SSH configuration consumer, and thus
precedes Workspace cloning. The terminal CLI keeps its existing ordering and UX.
Secure-only application execution bypasses generic administrator preflight;
user SSH identity import needs no administrator authorization. Mixed plans
retain their existing authorization requirements.

Passphrases are transient process/PTY memory only: no secret argv, environment,
JSON, generated state, logs or files are introduced. Python and OS memory do not
provide a guaranteed zeroization, swap or crash-dump exclusion. Protected keys
may request unlock again during later production revalidation; passphrases are
not cached between identities or operations. The bridge depends on age terminal
input and OpenSSH `ssh-keygen -y` stdin fallback (`RP_ALLOW_STDIN`, present in
OpenSSH 8.1). Desktop is not implemented; runtime packaging and testing across
supported macOS/age/OpenSSH versions remain required.

### Application cask coverage

With usable Homebrew, already satisfied selected casks require no installation.
Missing casks are accepted only when Homebrew JSON identifies an official
`homebrew/cask` app-only install: `app` artifacts, optional inactive `uninstall`
or `zap` metadata, no install hooks, extra dependencies beyond macOS/architecture,
caveats (including Rosetta), container override or rename steps. Every app target
must be absent directly under writable `/Applications`. Disabled casks and all
other artifact classes, including `pkg`, `installer`, `binary` and `suite`, are
outside this initial subset. Registered casks with missing targets need repair
and are blocked; application mode does not reinstall them.

The gate inspects only selected work before publication and rechecks missing
casks in the production installer. `cask_execution_requirements_unsupported`,
`cask_metadata_unavailable`, `cask_authorization_required`, `cask_target_conflict`
and `cask_repair_not_supported` preserve the complete plan. Structured failures
include `category` and a one-based `selected_item_index` in validated generated
selection order, without exposing tokens, paths or installer output.
Accepted installs use the ordinary cask consumer with explicit `/Applications`
placement, no sudo, ask mode, auto-update, install cleanup or install upgrade;
owned stdin/process semantics and the existing mutation boundary apply.
Production cask inspection and Global Verification remain authoritative. Failures
may leave partial changes; independent macOS/vendor GUI dialogs are not suppressed.
Ordinary CLI cask behavior is unchanged. Homebrew absence retains its prerequisite
condition; Secure Restore requires its separate secret channel.

### Application VS Code extension coverage

Selected extensions use the existing ID configuration, Preview, installation
consumer and Global Verification. Application context prefers `code` from PATH;
if absent, it can directly use stable VS Code's documented
`Contents/Resources/app/bin/code` under `/Applications/Visual Studio Code.app`
or `$HOME/Applications/Visual Studio Code.app`. Two bundles without an explicit
PATH choice produce `vscode_cli_ambiguous`; custom locations and variants require
an explicit `code` in PATH. No shell profile, symlink or permanent PATH is changed.

Only selected extension work requires the CLI. Before publication,
`vscode_cli_required` reports absence and `vscode_cli_unavailable` reports an
unusable launcher or failed production inventory. Structured Preview preserves
such conditions as warnings so readiness can return the typed prerequisite;
future Desktop guidance and Check Again remain planned. A usable CLI must already
exist before publication, including when the plan also contains a VS Code cask.

The ordinary `--install-extension <ID>` command installs missing IDs; satisfied
IDs are skipped without force, update-all, uninstall or new version semantics.
CLI dependency/extension-pack handling remains its existing production behavior.
Owned stdin/TTY/process semantics and the existing mutation boundary apply;
Marketplace or network failure is an execution failure, not a prior capability
rejection. Production inspection verifies installed IDs, not versions, enablement
or extension runtime behavior. VS Code settings and human CLI PATH behavior are
unchanged. No separate extension inventory or verifier is introduced.

### Application repository reconstruction

Selected Git repositories use the existing Workspace configuration, portable
source-HOME → target-HOME mapping, Preview, clone/branch consumer and Global
Verification. Reconstruction clones the recorded remote; it does not migrate
working trees or `.git` directories. Existing repositories are never pulled,
updated or assigned a different remote. A clean branch mismatch retains the
production checkout behavior; tracked/staged changes prevent checkout.

Git is required only for selected repository work. Local readiness returns
`git_required`, `git_unavailable` or `repository_target_conflict` before
publication. Existing non-repositories, mismatched origins and unsafe branch
changes are preserved. Structured Preview retains these conditions as warnings
for the typed readiness gate. Invalid or unsafe selected input remains blocked.
No network authentication is attempted during readiness.

Application clone disables terminal/askpass prompting and credential helpers
for that command only; Macseed supplies no credentials. HTTPS public remotes
can clone; authenticated remotes fail if authorization is unavailable through
this constrained execution. SSH uses existing configuration and agent identities
with BatchMode, StrictHostKeyChecking=yes, UpdateHostKeys=no and CheckHostIP=no;
unknown/changed host keys fail rather than being accepted or added. Explicit
application SSH command options override Git SSH launcher overrides. No global
Git/SSH configuration is changed. Credential-bearing HTTP(S) URLs and URL
query/fragment metadata are rejected; clone output is suppressed to keep remote
URLs out of logs. Owned stdin, process cancellation and mutation boundaries apply.

Remote/network/authentication failures are execution failures after mutation may
have started. Failed clones can leave partial directories; no automatic cleanup
or rollback is performed. Re-entry recomputes Preview and inspects that state.
Global Verification retains worktree/origin/branch predicates. Human CLI clone
behavior is unchanged; Secure Restore requires its separate secret channel.

### Application Mac App Store coverage

Selected App Store applications use the existing numeric-ID configuration,
Preview, MAS install consumer and Global Verification. A usable PATH `mas` is
required for selected work because production `mas list` is also the authoritative
installed-state observer; no replacement inventory is added. No selected apps
means no MAS prerequisite. Installed selected IDs are skipped, while missing IDs
use `mas install <ID>` without force, purchase/get, or global upgrade.

Local readiness returns `mas_required` for absence or `mas_unavailable` for an
unusable executable/version command or failed production inventory, before Bundle
publication. Structured Preview retains inventory failures as warnings so the
typed readiness gate can report them. Installing `mas` through Homebrew is an
external prerequisite in this path, even if the plan also selects that formula;
no second package pass or automatic Homebrew bootstrap is introduced. Desktop
can explain the prerequisite and offer Check Again after external preparation.

Current mas documents root privileges and an existing signed-in App Store Apple
Account for installation. Application install uses `sudo -n` with the resolved
CLI and `MAS_NO_AUTO_INDEX=1`, preserving mas's invoking-user context and preventing
password fallback if local authorization expires. The existing local authorization
gate remains in place. No supported reliable account/entitlement preflight is
used; Macseed does not inspect private account databases or manage Apple ID login.
Account, purchase, storefront and network failures remain runtime execution
failures rather than an unsupported capability. Independent macOS/App Store GUI
dialogs are not suppressed. Vendor output is hidden in application context,
including inventory stderr, to avoid exposing account information in logs.

Owned stdin/TTY/cancellation and the existing mutation boundary apply. Failed
installation preserves `target_mutation_may_have_started=true`, without rollback
or uninstall. Post-install production inspection and Global Verification retain
numeric-ID presence semantics and Spotlight limitations. Repeated Restore skips
satisfied IDs. Human CLI MAS behavior is unchanged; Secure Restore requires its separate secret channel.

## Restore prerequisites

The accepted Core/Desktop model distinguishes unsupported Restore work from a
supported capability with an unsatisfied prerequisite. Checks depend on the
selected plan: continue when satisfied; safely satisfy and verify a prerequisite
when supported; otherwise return a typed condition for Desktop guidance and
external action. Re-entry uses **re-inspect → recompute Preview → rerun idempotent
work**, without transactional resume. This model is a product contract to
implement, not a claim that every prerequisite flow exists today.

Homebrew must not be required merely to launch Macseed, inspect a Bundle,
Preview, restore unrelated categories, Verify or Compare. It is required only
for selected work that depends on it. Today usable Homebrew permits supported
formula restoration; absence returns `homebrew_installation_requires_interaction`
before publication, while broken or partial installations retain
`homebrew_unavailable`. For 4.0, Desktop must explain the selected work's need
for Homebrew and offer installation instructions and **Check Again**. Automatic
bootstrap is optional pending Desktop authorization design; a privileged
helper/XPC subsystem is not required solely for it.

`age` is a prerequisite only for selected Secure Restore work that needs it.
With a valid secret channel, readiness returns `age_required` when absent and
`age_unavailable` when unusable, before publication. Application mode never
installs it interactively. Desktop prerequisite guidance and a possible safe
formula installation remain future work. Command Line Tools likewise belong to operations that
need them; external installation should lead to guidance and re-check. Current
CLI preflight checks CLT broadly; the plan-sensitive model is intended behavior.

External prerequisite installation is acceptable when automation would add
disproportionate privileged-system complexity. It does not narrow Restore
coverage: casks, MAS apps, VS Code extensions, Git repositories and Secure SSH
Restore remain Macseed execution responsibilities as their paths become
application-safe.

## Current architecture

```text
Current Mac
    ↓
Discovery
    ↓
Generated Configuration
    ↓
Blueprint / Desired Selection
    ↓
Preview
    ↓
Bootstrap
    ↓
Target Mac
```

Discovery records supported observed state. Generated Configuration stores
those machine-specific values. Blueprint optionally selects the restoration
scope. Preview reports supported changes without applying them. Bootstrap
applies the selected supported values on the target Mac.

## State and responsibility model

Toolkit separates observed values from desired selection:

```text
Observed State
    ↓
Generated Configuration
    +
Blueprint Desired Selection
    ↓
Selected Supported State
    ├── Preview
    └── Bootstrap
```

- **Observed State** is supported state detected on the source Mac.
- **Generated Configuration** is the local representation of observed values.
- **Blueprint Desired Selection** contains categories and items included in the
  restoration scope.
- **Selected Supported State** is the intersection of generated values,
  Blueprint selection, and current consumer support.

Blueprint does not own, copy, or rewrite discovered values. Preview does not
own configuration or define another desired-state model. Bootstrap does not
discover source state. These responsibilities remain separate.

## Current architectural contracts

### Discovery

Discovery observes its supported domain without mutating that domain. Its
publication lifecycle is an architectural invariant:

```text
Collect → Validate → Serialize → Safe Publication
```

Generated output is replaced only after the complete candidate has been
collected, validated, and serialized successfully. A handled failure preserves
the previous valid generated state. Discovery records configuration and
metadata; it does not copy user documents or repository contents.

### Generated Configuration

`config/generated/` contains private, local, machine-specific derived state and
is excluded from Git. Producer and consumer formats must remain compatible,
and generated content must always be parsed as data rather than executed.
It is not a credential vault: producers must not knowingly publish passwords,
tokens, private keys, or embedded URL credentials there.

Most generated files publish independently. `workspace.conf` also publishes
independently, while `folders.conf`, `repositories.conf`,
`vscode-workspaces.conf`, and `inventory.conf` form one consistency group and
publish as a single Workspace snapshot.

Generated state can contain personal paths, Git identity, repository URLs, and
editor settings. Opaque VS Code and Zsh snapshots may still contain sensitive
content; no general secret-free guarantee is implied. Generated state must be
reviewed and protected before external transfer. Exact file
formats and portability rules are defined in [Configuration](CONFIGURATION.md).

### Blueprint

Blueprint validates and stores Desired Selection in private local
`config/blueprint.conf`. It selects discovered categories and items without
duplicating their values from Generated Configuration.

When Blueprint is absent, consumers retain compatible all-inclusive behavior
for the supported generated scope. A legacy Blueprint that omits a newer
category remains valid and leaves that category disabled until explicit
migration.

### Preview

Preview is a read-only mode of the existing restoration model. It consumes the
same Generated Configuration, Blueprint Desired Selection, validation rules,
and observation semantics as Bootstrap rather than introducing a second
desired-state model.

Preview reports planned supported changes, distinguishes observation failure
from confirmed absence or mismatch, and does not mutate target state. It does
not own or rewrite configuration. Its result can gate Bootstrap in Guided
Workflow.

### Bootstrap

Bootstrap applies selected supported values through the module-level lifecycle:

```text
Check → Apply → Verify
```

Required selected input is validated before mutation. Observation failure is
distinct from legitimate absence or mismatch and must not be converted into
“apply required.” Modules apply only confirmed necessary changes, preserve
existing data where safety is uncertain, and remain idempotent.

Verify is a local post-apply check performed when the resulting managed state
is observable by the module. It does not imply aggregate verification of the
whole Mac or effective visual verification beyond the module's stated
contract.

Discovery of VS Code Workspace metadata and generation of
`vscode-workspaces.conf` are implemented. Bootstrap restoration of
`.code-workspace` remains intentionally disconnected until a safe restoration
consumer is implemented.

### Core boundary

`modules/core/` owns shared output, logging, lifecycle orchestration, preflight,
configuration infrastructure, and common environment services. Domain-specific
Discovery, Preview, and Bootstrap behavior remains outside Core.

macOS producers and consumers share a typed supported-record boundary.
Screenshot restoration additionally crosses into filesystem safety; its path,
portability, and category-specific behavior are defined in
[Configuration](CONFIGURATION.md), not duplicated here.

## Guided Workflow

Guided Workflow orchestrates existing modes rather than introducing another
configuration source or desired-state engine:

```text
Readiness / optional Discovery
    ↓
Blueprint
    ↓
Preview
    ↓
Conditional Bootstrap
```

Blueprint cancellation stops the workflow. Preview errors block Bootstrap.
When changes are planned, Bootstrap requires explicit user confirmation; zero
planned changes do not invoke Bootstrap. Each underlying mode retains its own
responsibility, validation, logging, Summary, and public status semantics.
Inputs are revalidated before actual Apply where required. State is not frozen
between Preview and confirmation. Global Verification observes the selected
state after Bootstrap or after Preview when Bootstrap is not run.

## Verification boundary

Local Verify remains part of module lifecycles. Global Verification
adds a read-only observation pass after Bootstrap (including Restore Bootstrap)
and after Workflow Preview when Bootstrap is not run. It verifies selected
Homebrew formula and cask installation predicates, App Store application IDs,
direct global Git values, supported SSH and Zsh config payloads, VS Code
extension IDs and settings payload, Workspace folders and repository
worktree/origin/branch, and generated settings for Finder, Dock, Windows,
Keyboard, Trackpad and Screenshots. Selected Secure Restore SSH identities use terminal evidence from the importer.
A failed Restore prerequisite still produces a report for the selected scope.
Startup validation/preflight failures and cancellation before Preview retain
existing early exits without a verification pass.

These predicates retain production reader semantics: installation does not
prove application runtime health, file equality does not prove effective app
settings, and macOS checks confirm stored preference values/types, not UI effects.
Screenshots location preference and destination directory are independently
observed. Missing `mas` or `code` leaves selected items unverified; verification
never installs dependencies. Zsh preserves snapshot ownership boundaries and
does not add permission requirements to identical target content.

Secure Restore adds `identity_pair_matches_package` evidence only after the
existing importer finishes validation or rollback. It means byte equality with
the validated package pair, pair correspondence and existing filesystem safety
checks, at the importer observation time. It does not verify authentication,
agent, Keychain or network state. Bootstrap/Workflow without Secure Restore have
no managed identity requirement.

The opt-in importer publishes versioned non-secret terminal records to a private
0700 directory / 0600 file. A strict reader validates ownership, file identity,
framing, attempt binding and child status, then removes the transport and passes
records through a dedicated fd to the existing collector. Records contain target
basenames, conformity, timestamps and typed reasons; no keys, fingerprints,
passphrases, hashes or plaintext paths. The collector never rereads private keys
or decrypts the package. Missing/invalid evidence leaves coverage unresolved and
the report incomplete without changing the importer exit code. Rollback
invalidates preliminary positive evidence. The observation interval includes
importer timestamps; later target changes are not rechecked. Signal/power-loss
cleanup limitations of Secure Migration remain unchanged.

The internal flow is:

```text
Generated + Blueprint → resolved scope + unresolved references
                      → production domain readers → collector → report
```

`modules/core/verification/verification.sh` owns process-local Verification,
Coverage, Operation and Diagnostic records and deterministic counters. Domain
consumers own comparisons; `modules/verification/verification.sh` resolves scope
and dispatches them. Records contain subject/predicate identities, not desired
values. They are internal Bash data, not a public interface or persisted API.

Conformity (`verified`, `mismatch`, `unverified`), verification support,
coverage and diagnostics are independent. Operations retain their own outcomes;
an earlier operation failure can coexist with a verified final observation.
Partial SSH source coverage does not invalidate a matching supported payload.
Stale references stay unresolved; absent requirements never become verified.
Legacy source provenance remains unknown unless the snapshot explicitly records it.

The run binds records to an origin, input digest, observation interval and
operation context. Input identity is checked before and after the pass; change
or invalid input makes the report incomplete. Target observations are sequential,
not an atomic snapshot. Resolved predicate counts partition by conformity;
unsupported is a subset of unverified, while unresolved references and diagnostic
counts are separate. The human-readable report starts with one of four verdicts:
`Verification incomplete` when the run is incomplete or selected requirements
remain unverified/unresolved; `Differences detected` for a complete run with a
confirmed mismatch (also noting incomplete coverage when present);
`Selected requirements verified` when every resolved selected predicate is
verified and no selected reference is unresolved; or `No managed requirements`
when coverage proves the selected scope is empty. Unknown empty source inventory
cannot prove absence. Legacy source provenance remains unknown and is shown as a
scope caveat; it does not prevent a verdict for actually selected requirements.
Diagnostics and operation outcomes are reported separately from conformity.
`Selected requirements verified` refers only to selected supported Macseed
requirements observed during this run. It does not establish whole-Mac identity,
application runtime health, effective visual macOS settings, remote SSH access,
or an unchanged target after the sequential observation pass. Existing public exit codes
continue to describe command execution; they are not environment conformity.
The verifier never invokes Discovery publication, installers, clone/checkout,
preference writes or process restarts. Temporary validation files are permitted.

## Environment Comparison

The read-only Comparison operation is exposed explicitly through `bs compare`
and `./bootstrap.sh --compare`. It compares the selected reference environment
with the current Mac, reusing production inspectors and process-local
Verification/Coverage facts. It projects a resolved
predicate to `matching`, `missing`, `differing`, or `unverified`. A mismatch is
`missing` or `differing` only when the inspector supplies a typed observation;
an unknown mismatch is unverified for Comparison. Unsupported remains a subset
of unverified, and unresolved selections remain Coverage gaps. Operations do not
determine comparison categories.

Comparison has its own verdict: `Differences detected`, `Comparison incomplete`,
`No differences detected`, or `No comparable requirements`. Confirmed differences
take precedence in a complete run, with incomplete coverage stated separately.
Extra comparison uses complete, digest-bound captured inventories for Homebrew
casks, App Store IDs, and VS Code extension IDs. It excludes items captured but
not selected by Blueprint. A missing or stale per-domain marker means unknown
source completeness, so extra is unavailable rather than zero. Formula Discovery
exports only requested formulae, and scalar/payload/Workspace domains do not
support extra. Only trusted Restore importer
evidence can compare SSH identities. The default report shows typed differences
without expected/actual values, private content, or remote URLs. Comparison does
not Apply, remove, or plan cleanup, and is not automatically run by Bootstrap,
Workflow, or Restore. Its facts remain transient; there is no persisted
Comparison interface.

## Planned Core/GUI boundary

A native macOS application, expected to use SwiftUI, is planned as a
presentation and orchestration layer. It will consume a stable machine-readable
structured Core interface rather than parse human CLI output or logs. The interface will expose
Discovery, selected environment, planning/Preview, Verification, Comparison, and
operation results. Core remains
authoritative for validation, planning, and mutation; the GUI does not
reimplement Discovery, Blueprint, Preview, Bootstrap, Capture, or Restore in
Swift. The interface format and GUI UX remain to be designed.

## Documentation ownership

This document owns stable architectural responsibilities and boundaries.
Current formats and value-level contracts are in
[Configuration](CONFIGURATION.md), operational behavior in [CLI](CLI.md) and
[Quick Start](../getting-started/QUICKSTART.md), development direction in
[ROADMAP.md](../../ROADMAP.md), near-term work in [TODO.md](../../TODO.md), and
completed history in [CHANGELOG.md](../../CHANGELOG.md).

Return to the [main README](../../README.md).
