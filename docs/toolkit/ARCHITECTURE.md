# Macseed Architecture

Macseed has one authoritative Core and two client boundaries. The CLI is
implemented; native Desktop is under development with Stage 16B–16G complete.
Packaged distribution and clean-Mac qualification remain planned.

```text
Macseed
├── Core
│   ├── Discovery and Selection / Blueprint
│   ├── Preview and Bootstrap
│   ├── Verification and Comparison
│   └── Bundle and Secure Migration
├── CLI: bs / bootstrap.sh
└── Desktop: Macseed.app (under development)
```

These are responsibility boundaries, not a proposal to move production files.
The current Bash/Python implementation stays in the existing repository layout.

## State and control flow

The engineering lifecycle is **Capture → Rebuild → Verify**. Internally:

```text
Discover → Select → Preview → Apply → Verify
    │         │
    ▼         ▼
Generated   Blueprint
Configuration (Desired Selection)
```

Discovery observes supported state. Generated Configuration stores derived
machine-specific values; Blueprint selects from that inventory without
copying or overwriting it. Together they define selected supported requirements.
Without Blueprint, the established all-inclusive compatibility behavior applies.

Preview inspects those requirements without applying them. Bootstrap validates
selected input, observes target state and uses **Check → Apply → Verify**.
Observation errors must not become “apply required.” Global Verification then
reports selected conformity and coverage independently of operation success.
Comparison is an explicit observational projection of those same facts.

## Responsibilities and entry points

| Component | Responsibility / implementation |
|---|---|
| Discovery | Domain exporters under `modules/discovery/`; local generated publication |
| Selection | `modules/blueprint/`; validation, filtering and terminal selector |
| Preview / Bootstrap | Existing domain readers and consumers orchestrated by `bootstrap.sh` |
| Verification / Comparison | `modules/verification/`; reuse domain observations, no second configuration model |
| Bundle | `modules/bundle/`; validation, selected transport state and recoverable publication |
| Secure Migration | `modules/migration/`; separately selected encrypted SSH identity transfer |
| CLI | `bootstrap.sh` is the production entrypoint; `bin/bs` dispatches to it from the repository root |
| Application interface | `modules/core/application-interface/`; Protocol V1 adapter over production paths |
| Desktop | Swift/SwiftUI client under development consuming structured Core events and results |

Shared utilities remain in `modules/core/`; domain behavior stays with its
existing owner. The application adapter composes authoritative paths rather
than replacing them. Desktop must not parse terminal/log output, emulate
interactive CLI workflows or implement its own Capture, Restore, Verify,
Compare or secure importer.

## External tool compatibility boundary

External tools are concrete providers behind small domain-owned adapters. Core
consumes normalized capabilities and state (`satisfied`, `installable`,
`repairable`, `unsupported`, `incompatible`, `observation_error`), rather than
external artifact or lifecycle rules. The shared value contract lives in
`modules/core/external_tool.py`; the Homebrew provider lives in
`modules/apps/adapters/`. MAS, Git and VS Code have not been migrated.

Compatibility is determined by observed public CLI capabilities, understood
metadata and qualified item semantics. Unknown schema, artifact or operation
behavior fails closed. Tool version is provenance, not a version allowlist or
an exact captured/target version requirement. Native lifecycle operations remain
owned by the external tool; Macseed never loads private Homebrew Ruby code or
reimplements uninstall. Installed inert receipts are conservative safety evidence,
not executable definitions. Ambiguous evidence blocks repair.

Safety-sensitive preconditions are observed again inside the owned-item execution
boundary after dependency resolution, immediately before native mutation. This
reduces state drift; external filesystem/launchd changes are not atomic with the
native command. Existing cancellation, watchdog and final Verification remain
Core-owned. This is a static adapter boundary, not a plugin framework.

## Publication and mutation boundaries

Exporters collect, validate and serialize before replacing a generated file.
Handled failure preserves previous valid state. The four derived Workspace
files form a grouped snapshot; other publications retain their own boundaries.
Generated data is parsed as data, never `source`d or `eval`uated, and is not a
credential vault.

Capture uses private staging and creates a validated Bundle without replacing
the source Mac's ordinary generated state or Blueprint. Restore validates,
narrows and previews staged input before publishing local desired state and
applying it. Application Execute repeats preparation and rejects a stale plan
before publication. A prepared ID is neither authorization nor a transaction.

Publication recovery protects the local Generated Configuration / Blueprint
pair where defined. It does not undo application installations, settings writes
or imported identities. Re-entry requires re-inspection, a new Preview and
idempotent execution; there is no persistent transaction/resume database.
See [Capture / Restore](../CAPTURE-RESTORE.md) for the workflow.

## Safety and security invariants

- Required selected input is validated before mutation. Optional-input behavior
  follows each domain contract; absence and observation error remain distinct.
- Conflicts preserve existing state. No automatic remote replacement, destructive
  checkout, Git reset/clean or deletion of untracked data is introduced.
- Matching supported state avoids redundant changes. Verification checks what
  the production observer can establish, not visual effects or whole-Mac identity.
- Secure identities remain outside normal generated configuration and Bootstrap.
  Selected Secure Restore finishes before dependent Workspace clones.
- Passphrases and import confirmation use a separate secret channel, never
  ordinary JSONL, argv, environment, generated state or logs.
- Bundle checksums detect corruption, not source authenticity. Normal Bundle
  configuration is private but unencrypted; only `secure.age` is encrypted.
- Extras require complete source provenance and valid target enumeration;
  Comparison is informational and never plans removal or runs automatically.

## Application and runtime boundary

Protocol V1 supplies capabilities, Bundle inspection, Capture/Restore preparation
and execution, and Environment Comparison / Status. Core owns request validation,
plan-sensitive prerequisites, production execution, records and owned-process
cancellation. Clients provide user confirmation, prerequisite guidance and
secret input, and display Core's structured progress and results.

Current execution uses the repository layout and external Python 3. Stage 16
has implemented the native client/runtime boundary and controlled child environment;
private writable workflow state and remaining integration still need qualification.
Stage 17 qualifies the packaged application on clean Macs. A SwiftUI app exists;
signed/notarized distribution is not yet qualified. See the current
[Desktop runtime boundary](../DESKTOP.md#implemented-runtime-boundary).

Detailed transport, readiness, mutation and reporting semantics belong to
[Core Application Interface](../core/APPLICATION-INTERFACE.md). Data formats and
domain safety limits belong to [Configuration](CONFIGURATION.md). Product intent,
stages and released history belong to [Vision](../VISION.md),
[Roadmap](../../ROADMAP.md) and [Changelog](../../CHANGELOG.md).
