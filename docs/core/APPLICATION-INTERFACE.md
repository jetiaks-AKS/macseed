# Macseed Core — Protocol V1

This reference owns the implemented application-facing contract. Overall
boundaries are in [Architecture](../toolkit/ARCHITECTURE.md); the user workflow
is in [Capture / Restore](../CAPTURE-RESTORE.md).

## Launch and transport

One process serves one operation:

```text
modules/core/application-interface/core.sh [--secure-fd N]
```

Send one JSON object on stdin and close it. Core emits JSONL events on stdout;
stderr is not protocol transport. The launcher resolves the repository root;
production children run from that root. Python 3 must be available. Installed-app
runtime and writable-state placement are still Stage 16 work.

Requests require `protocol_version: 1`, `operation_id` and `operation`.
All operations except `capabilities` require `parameters`. Only the specified
fields are accepted; duplicate JSON keys are rejected. The request limit is
4096 bytes. `operation_id` is 1–64 characters matching `[A-Za-z0-9_-]`.
Prepared IDs are 64 lowercase hexadecimal characters.

```json
{"protocol_version":1,"operation_id":"inspect-1","operation":"bundle_inspect","parameters":{"path":"/absolute/path/environment.mbt"}}
```

## Operations

| `operation` | Exact `parameters` fields | Behavior |
|---|---|---|
| `capabilities` | Omit `parameters` | Returns `protocol_version`, `product_version`, `operations` |
| `bundle_inspect` | `path` | Returns Bundle summary and Core-owned `restore_selection` inventory; no Apply |
| `capture_prepare` | `selection` | Private staged observation and prepared selection |
| `capture_execute` | `selection`, `destination`, `expected_prepared_capture_id` | Fresh observation and new Bundle publication |
| `restore_prepare` | `path`, `disabled_groups`, `include_secure`, optional `selection` | Bundle validation, Preview and prerequisites; no publication or Apply |
| `restore_execute` | Restore fields plus `expected_prepared_plan_id` | Fresh preparation, local-state publication and restoration |
| `environment_compare` | `generated_dir`, `blueprint_path` | Explicit read-only reference-to-current-Mac comparison |

Bundle `path` and `generated_dir` are absolute. `blueprint_path` is absolute or
`null`; null explicitly selects no Blueprint, without falling back to a local
saved selection. Compare accepts Generated Configuration, not a Bundle.

## Capture selection and preparation

Prepare with `selection: null` discovers inventory without selecting requirements.
Then prepare again with the chosen selection, for example:

```json
{"categories":[],"items":{"homebrew-packages":["git"]},"secure_identities":[]}
```

`categories` selects whole domains; `items` selects subsets of Blueprint item
categories; `secure_identities` selects separate SSH candidates. Duplicates,
unknown IDs and overlap between a whole domain and its item subset are invalid.
Unobserved state cannot be selected for transfer.

Prepare returns `prepared_capture_id`, `inventory`, `secure_identities`, canonical
`selection` and `summary`. Inventory rows contain `domain`, `status`, nullable
`reason`, `selection_mode` and `items` with `item_id`/`label`. Status is `present`,
`unavailable`, `observation_error` or `unsupported`; selection mode is `items` or
`category`. Reasons distinguish missing sources/tools from read errors. Eligible
SSH candidates expose safe names, key types, public fingerprints and
`candidate_requires_pair_validation`; Prepare does not unlock keys.
Inventory limits are 2048 items per domain and 1 MiB internally.

The six category-only `macos-*` inventory rows add `included_settings`, an array
of `{ "id": "autohide", "label": "Auto-hide" }` entries. IDs identify preference
keys within that domain. This read-only projection describes only records in the
same validated staged observation, including any supported remainder after a
partial warning. Absent/skipped records are omitted; unavailable or failed domains
have an empty array. Inventory describes the observed domain; category selection
still decides whether that domain is saved. Values are never exposed. Definitions and labels are owned
together by the existing macOS scalar contract. Older clients may ignore this
additive V1 field; it creates no item selection and does not change the prepared
ID binding or Execute semantics.

Execute requires a non-null selection and the ID from Prepare for that selection.
It repeats Discovery and binds the ID to staged data, candidate metadata and
selection, then uses production Preview, portability and Bundle checks.
`stale_prepared_capture` requires fresh preparation and confirmation.

`destination` must be an absolute `.mbt` path whose existing parent is canonical
and user-owned. Existing files are never replaced. Success returns
`publication_occurred`, `destination`, `bundle` information and
`prepared_capture_id`. Ordinary Generated Configuration and Blueprint are unchanged.

## Restore plans and re-entry

`disabled_groups` is a unique list drawn from `Applications`, `VS Code Settings`,
`Homebrew`, `macOS Settings`, `Shell`, `Git`, `SSH Configuration`, `Workspace`.
`include_secure` is boolean; true requires `secure.age`. Selection can be narrowed
by group. The additive fine-selection capability also permits domain/item
narrowing within captured eligible content; selection never expands Bundle scope.

### Additive ordinary Restore selection

Capabilities advertises `features.restore_selection` with `version: 1`,
`inventory: "bundle_inspect"` and `selection_modes: ["category", "items"]`.
Clients must check this before sending the new field to an older Core.

`bundle_inspect.restore_selection` contains authoritative `groups` (`id`,
`domains`) and `inventory`. Each row has `domain`, safe `label`, `selection_mode`,
`availability` (`available` or `unavailable`), nullable `reason`, and `items`
with `item_id`/`label`. This is captured selection eligibility, not current-Mac
execution readiness. Missing or ineligible content is unavailable with
`no_selectable_content`; malformed/unsupported Bundles still fail inspection.

Items are supported for formulae, casks, App Store IDs, extensions, eligible
Workspace folders, repositories and supported Git configuration keys. VS Code
settings, Zsh, SSH configuration and each of the six macOS domains are whole-domain
only. Individual macOS preference keys and secure identities are not selectable
through this inventory.

Prepare and Execute accept optional ordinary `selection`:

```json
{"categories":["macos-finder"],"items":{"homebrew-packages":["restore:<sha256>"]}}
```

Absent/null preserves the legacy group-only path, including its prepared ID.
A non-null object is an explicit whitelist; empty arrays/object select no ordinary
content. Whole item domains include every eligible captured item. Item subsets
must be nonempty and use Core-issued IDs. Unknown IDs, unavailable content,
duplicates, whole/subset overlap and item selection in category-only domains
return `invalid_selection`. Disabled groups remain an upper bound; attempting to
re-enable their content fails. The existing 4096-byte request limit still applies.

IDs are SHA-256 tokens over domain and original item identity, not array position,
values, remotes or narrowed order. Safe identifier labels are exposed; unsafe
identifiers receive a neutral label. App Store display labels use captured application
names from `appstore.conf` where available, independently of stable App Store IDs.
Repository positional Preview `item_id`
remains unchanged; additive `selection_item_id` correlates selectable plan rows
with inventory IDs. Secure material and preference values are never projected.

Prepare returns canonical effective `selection`: sorted category-only domain IDs
and sorted item-ID subsets, expanding whole item domains. New finer selection is
bound into `prepared_plan_id`; Execute repeats the same validated private staged
Blueprint narrowing and rejects mismatched/stale plans before publication/mutation.
Equivalent whitelist representations canonicalize to the same effective scope.
Legacy requests receive the additive public selection/correlation fields after
legacy identity calculation. The source Bundle, ordinary generated state,
persistent Blueprint, mutation consumers and CLI selection remain unchanged.
`include_secure` and the separate secret transport remain independent.

Prepare validates/unpacks into private staging, narrows selection and runs the
production Preview. It returns:

- `prepared_plan_id`, selected groups/categories and item counts;
- `modules`, `plan`, `has_planned_changes`, `has_executable_changes`, `warning_count`, `error_count`;
- `include_secure`, `secure_restore_status`, `preview_detail_level`;
- `readiness` with environmental prerequisites.

Plan rows contain `domain`, `item_id`, `action`, `disposition`, nullable `reason`;
repository rows may have a safe `display_name`. Dispositions are `satisfied`,
`planned`, `blocked`, `conflict`, `warning`, `unknown`, `pending_unlock`.
An unknown observation must not become an Apply decision. For supported selected
scalar Git settings, ordinary value drift yields `set_setting` / `planned`, not
`target_conflict`. Execute re-observes the unique direct origin, restores and
verifies the saved value; a matching subsequent Prepare is `satisfied`. Unselected
keys and ambiguous/error protections are unchanged; see
[Git configuration](../toolkit/CONFIGURATION.md#git-generated-state).

Readiness contains `ready`, `ready_scope=environment`, `conditions`,
`check_policy=item_local_then_first_operation_blocker_per_domain`,
`reentry=restore_prepare`. Conditions contain `domain`, `code`, `status`, `scope`,
and optionally a cask `selected_item_index` in selected Blueprint order.
Statuses are `satisfied`, `safely_satisfiable`, `external_action_required`,
`unsupported`. Domains report all encountered item-local skips before their first
operation-wide blocker. `scope=operation` retains whole-operation blocking.
Only `homebrew-casks` / `cask_execution_requirements_unsupported` with an item index
uses `scope=item`: the item stays selected and blocked, while independent planned
work may proceed. Other prerequisite failures retain operation-wide blocking.
`ready` expresses environmental safety; `has_executable_changes` requires a
remaining planned action (or selected secure work). An all-unsupported plan offers
no Rebuild; Execute returns `no_executable_work` before publication.
`secure_bridge_required` with `scope=execution_launch` concerns Execute launch,
not environmental readiness. Prepare accepts no secrets.

Execute repeats the same preparation, compares `expected_prepared_plan_id`,
and rechecks launch prerequisites and source/staged fingerprints. `stale_plan`
rejects publication. After external preparation, use **Check Again → Prepare
→ confirm the new plan**. Neither ID nor `ready` is authorization, a transaction
or proof that target state cannot change.

Pending local publication returns `recovery_required`. Prepare does not recover
or mutate it; the existing CLI Restore owns recovery.

### Plan-sensitive application execution

| Selected work | Current application contract |
|---|---|
| Homebrew formulae | Usable Homebrew; an existing installation may be activated in the child PATH. Missing/broken Homebrew needs external action; no automatic installation |
| Casks | Satisfied items are skipped. New installs require qualified app-only `homebrew/cask` metadata, free accessible direct `/Applications` targets, no hooks, extra dependencies, caveats, container override or rename. `pkg`/installer, `binary`, `command_wrapper` and repair/reinstall are blocked |
| VS Code extensions | Usable `code` in PATH or the official stable CLI in `/Applications` or `$HOME/Applications`. Two copies without an explicit choice are ambiguous. CLI is required before publication even if VS Code's cask is selected |
| Git repositories | Usable Git and safe destinations. Clones use recorded remotes without credential/askpass prompts; SSH uses existing config/agent and strict known-host checking. HTTP(S) credentials and URL query/fragment are prohibited |
| App Store | Usable `mas` before publication and existing account/entitlement state; missing IDs need non-interactive `sudo -n` authorization. Core does not manage Apple ID or promise account/entitlement validation before install |
| Secure SSH | Usable `age` and the separate secret bridge; importing user keys does not require administrator authorization |

Internet is required for missing installs/clones, Command Line Tools for missing
Homebrew formulae/casks, and administrator authorization for missing MAS apps.
Unrelated prerequisites do not block settings-only or Secure-only plans.
Network, Marketplace, account and clone failures can still occur during execution;
a missing prerequisite is distinct from unsupported execution. Independent macOS
or vendor dialogs are not suppressed. CLI retains its own preflight policy.

## Events, completion and mutation

Each event has `protocol_version`, `operation_id`, increasing `sequence`, `type`
and optional `data`. Accepted operations begin with `started`; request rejection
may emit `failed` without it. Success emits `result`, then `completed`. Failures
carry a stable `data.code`.

Progress uses `phase_started` / `phase_completed`, `capture_category`,
`secure_packaging`, `secure_challenge_waiting`, `secure_publication_started` and
`execution_event` where applicable. Restore also emits `operation_record`,
`verification_record`, `coverage_record`, `diagnostic_record`.

A handled operation has exactly one terminal event. Capture/Restore cancellation
uses `failed` with `cancelled` or `secure_cancelled`; Compare uses `cancelled`.
Process exits are `0` for completion, `2` for failure, `130` for handled cancellation.
CLI's `0/1/2` lifecycle is a separate contract.

Restore distinguishes `publication_started`, `publication_occurred`,
`target_mutation_may_have_started`, `execution_status`, `bootstrap_status` and
`secure_restore_status`. Results include Verification, warnings and errors;
partial records and reasons remain available on failure. Failure after publication
or mutation does not imply rollback. Capture cancellation after Bundle publication
retains `publication_occurred=true`.

Core owns child process groups, closes interactive stdin, isolates tool output
from JSONL and terminates owned processes on cancellation. Private staging is
cleaned on handled exit; SIGKILL/power loss cannot guarantee cleanup. There is no
daemon, XPC service, persistent session/resume database or Bootstrap transaction.

### Independent Homebrew items

Application Restore watches each formula/cask metadata/install subprocess for
**180 seconds without observable progress**, rather than limiting total runtime.
Owned writable regular-file growth, advancing artifact read offsets (excluding
logs, locks and terminal output), and compiler/linker CPU time reset the timer. Curl/Ruby CPU activity,
process liveness and diagnostic output do not count. Progress observations remain
private; they are not percentages, network speed or proof of installation.

Accepted unsupported casks remain visible in Prepare and final results. Core carries
their identities in private per-operation state; the production consumer records
`skipped` / `cask_execution_requirements_unsupported` without invoking their
installer, even if metadata later becomes eligible. It also repeats the existing
artifact safety gate for planned casks. Supported independent items and domains
continue, retaining production ordering, cancellation and watchdog behavior.
Current safe casks exclude formula/cask dependencies; accepted skips also seed the
Homebrew dependency gate. Selection and prepared-plan binding remain intact.

A stalled item records `failure` / `item_stalled_timeout`. Core terminates its
owned process tree, including descendants in Homebrew-created process groups,
within a private session using TERM followed by KILL. Other selected independent
Homebrew items continue.
Homebrew JSON dependency metadata gates later items against an operation-local
failed/unverified-item ledger, cleared only by local Verify; failed dependencies record `skipped` / `dependency_failed`.
Unknown dependency metadata blocks that item with `dependency_observation_failed`.
Existing prerequisite gates and execution order remain authoritative. This
watchdog does not cover unowned VS Code app processes, MAS or other domains.

Normal final Verification still runs after item failures. Core retains failure
exit `2` and `bootstrap_failed`; additive `independent_work_completed=true` means
Bootstrap reached the end of independent-work traversal, not successful conformity.
Clients may present partial success only with that evidence, complete final
Verification/details, matching prepared-plan identity and successful operation
records with matching verified observations. Failure, cancellation and interruption never authorize rollback or resume.
The temporary failed-item ledger is private and removed on handled completion.

## Verification and Environment Status

Results project existing Verification, Coverage and Operation records, without
a second observer. `verification` contains status, verdict and counts. Restore
places details in `verification.details`; Compare uses `records`. Detail objects
contain `status`, `verification_records`, `coverage_records`, `operation_records`,
`diagnostics`, `module_outcomes`.

| Record | Fields / meaning |
|---|---|
| Verification | `record_id`, `domain`, `item_id`, `predicate`, `conformity` (`verified`, `mismatch`, `unverified`), `support`, nullable `observed_at` |
| Coverage | `record_id`, `domain`, `item_id`, `disposition`, `source_status`; resolved/unresolved/excluded/no_requirement remain distinct. Restore omits excluded rows; Compare retains them |
| Operation | `record_id`, `domain`, `item_id`, `action`, `outcome`, nullable `reason` |
| Diagnostic | Record owner with `code`, `severity`, `phase` |

Operation success does not prove conformity. Unsupported is part of unverified;
unresolved is counted separately. Installation does not establish application
health; a stored preference does not prove a visual effect. Observations are
sequential. SSH `identity_pair_matches_package` describes local importer evidence
at observation time, not network authentication, agent or Keychain readiness.

Compare returns `read_only=true`, `publication_occurred=false`,
`target_mutation_may_have_started=false`, `comparison`, `comparison_records`,
`verification`, `records`, `extra`. Comparison rows contain `record_id`, `domain`,
`item_id`, `comparison_kind`, nullable `reason`/`phase`, `support`. Kinds are
matching/missing/differing/unverified; mismatch of unknown difference type remains
unverified with `unknown_difference`.

Comparison counts are matching, missing, differing, unverified, unsupported,
unresolved, extra, unknown_difference. Verdicts are `incomplete`,
`differences_detected`, `no_differences_detected`, `no_comparable_requirements`.
`also_incomplete` preserves coverage gaps alongside proven differences. Incomplete
run integrity takes precedence; otherwise differences precede verification gaps,
confirmed matching requirements or proven empty scope.

`extra.domains` contains status/count/reason; `extra.items` exposes safe IDs.
Extras are supported only for casks, App Store and VS Code extensions with complete
digest-bound source inventory and valid successful target enumeration. Excluded
Blueprint items in the full source inventory do not become extras. Missing evidence
means unavailable, not zero. Formulae and other domains do not gain extras or removal.

Reference is never substituted. Typed failures include `reference_unavailable`,
`reference_invalid`, `reference_changed`, `comparison_reporting_incomplete`.
Observation errors and optional inputs retain production Coverage/Verification
semantics. Completed comparison can still report differences or unverified state.

Internal records are limited to 4096 bytes and 8192 records per subprocess;
these are not aggregate `result` event limits. Detail status is
complete/partial/truncated/invalid/not_run. Compare rejects incomplete record
transfer; Restore retains available details with their actual status. Order and
IDs derive deterministically from source records; timestamps remain actual observations.

## Separate secret channel and privacy

The client passes one endpoint of an anonymous connected Unix stream socket pair
as an inherited FD greater than 2, using `--secure-fd N`. This is launch metadata,
not a JSON field. It is required only for Execute with selected identities.
Core validates the channel and restricts inheritance; ordinary Bootstrap children
do not receive it. Secrets must not enter JSONL, argv, environment, Generated
Configuration, logs or persistent secret-response files.

Frames use a four-byte unsigned big-endian length followed by 1–2048 body bytes.
Challenge JSON metadata contains `type=challenge`, `protocol_version=1`,
`operation_id`, fresh 32-hex `challenge_id`, `kind`, `attempt` (1–3).
Restore kinds are bundle_unlock/ssh_key_unlock/import_confirmation; Capture kinds
are bundle_encrypt/ssh_key_unlock. A response is 16 decoded challenge-ID bytes,
followed by:

- `S` and a nonempty UTF-8 passphrase of at most 128 bytes without control characters;
- `Y` alone for import confirmation;
- `C` alone for cancellation.

JSON responses, wrong IDs, unsolicited input, invalid sizes, EOF and timeout
block execution. Response timeout is 120 seconds; the secret tool timeout is
30 seconds. Keep the endpoint open until Core finishes or cancellation completes.
Age/OpenSSH use an isolated PTY with echo disabled; PTY content never enters
protocol/logs. Bundle and protected-key passphrases differ; keys retain their
original encryption. Full memory/swap/crash-dump erasure is not guaranteed.
Runtime/age/OpenSSH qualification belongs to [Desktop](../DESKTOP.md) and
[Distribution](../DISTRIBUTION.md).

Ordinary records expose safe IDs, setting keys and typed reasons, not original
Git identities, setting contents, credentials, private keys, remote URLs or commands.
Private subjects use opaque IDs; Restore repositories use selection indices.
Public fingerprints appear only in Capture SSH candidate inventory. Capture's
absolute `destination` result returns the necessary path supplied by the client.
