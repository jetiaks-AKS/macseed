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
broken Homebrew, and selected casks, App Store apps, VS Code extensions, Git
repositories, or secure identity work before publication, without silently
omitting selected work. Homebrew installation itself remains a temporary coverage
gap. The current subset also includes ordinary settings and Workspace folders;
application coverage must grow toward
the existing practical CLI Restore capabilities before native app Restore is
considered complete. Secure Restore awaits a dedicated credential bridge.
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
