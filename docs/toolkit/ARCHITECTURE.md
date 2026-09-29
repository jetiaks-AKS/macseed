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
between Preview and confirmation, and Global Verification is not currently part
of Workflow.

## Verification boundary

Local Verify is part of current module lifecycles. Planned Global Verification
will aggregate observable results for the selected desired environment after
normal Bootstrap/Workflow and, where applicable, Restore. It builds on local
Verify without replacing or duplicating it, and distinguishes verified state,
mismatch, warnings or unsupported state, and observation or verification
errors. Command success alone does not establish environment-level conformity.

## Planned Core/GUI boundary

A native SwiftUI macOS application is planned as a presentation and
orchestration layer. It will consume a stable machine-readable structured Core
interface rather than parse human CLI output or logs. The interface will expose
Discovery, selected environment, planning/Preview, verification, and operation
results. Core remains
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
