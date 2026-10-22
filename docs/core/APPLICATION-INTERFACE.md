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
| `capture_execute` | `selection`, `destination`, `expected_prepared_capture_id`, optional `replacement_sha256` | Fresh observation and Bundle publication |
| `restore_prepare` | `path`, `disabled_groups`, `include_secure`, optional `selection`, `installer_preparations` | Bundle validation, Preview and prerequisites; no publication or Apply |
| `restore_execute` | `path`, `disabled_groups`, `include_secure`, `expected_prepared_plan_id`, optional `selection` | Fresh preparation, local-state publication and restoration |
| `environment_compare` | `generated_dir`, `blueprint_path` **or** `bundle_path` | Explicit read-only reference-to-current-Mac comparison |

Capture publication remains no-clobber by default. After explicit native Save Panel
Replace confirmation, Desktop may supply `replacement_sha256`: the SHA-256 of the
observed existing regular, user-owned destination. Core rejects a changed file,
creates and validates the replacement privately, then atomically publishes it.
Creation, validation or publication failure preserves the previous Bundle.

Bundle `path` and `generated_dir` are absolute. `blueprint_path` is absolute or
`null`; null explicitly selects no Blueprint, without falling back to a local
saved selection. Compare alternatively accepts exactly `bundle_path`, an absolute
regular Bundle file path; mixed reference fields are rejected. No mode is inferred
from extension. `features.bundle_comparison.version = 1` advertises this additive
Protocol V1 form. Legacy Generated Configuration requests remain unchanged.

Bundle comparison fingerprints the source before validation, uses existing Bundle
inspection/unpacking into owner-private temporary staging, checks source identity
before and after comparison, and cleans staging on success/failure/cancellation.
The saved Blueprint limits selected requirements; retained inventory/provenance
preserves existing extras evidence without selecting excluded items. The adapter
runs the same read-only comparison engine, never configuration/Blueprint publication,
Apply or secure decryption/import. Encrypted `secure.age` remains opaque in temporary
staging. Additive `reference_presentation` carries authoritative Bundle groups and
`app_store_names` keyed by stable numeric item ID. Names come only from validated
Bundle `appstore.conf`, using the same safe label projection as Restore; no metadata
lookup or predicate change is involved. Optional `setting_labels` maps macOS domain
and stable comparison item IDs to labels from Capture’s existing `included_settings`
helper and `modules/settings/macos/records.sh`; missing labels keep technical IDs.
Legacy/missing metadata has a conservative
Desktop fallback. Failure codes include `bundle_unavailable`, `bundle_invalid`,
`unsupported_bundle` and `reference_changed`; no private archive contents are emitted.
`bundle_unavailable` requires an availability error on the selected source path;
internal staging/reporting I/O failures use `comparison_unavailable`. Confirmed
Compare cancellation remains a separate terminal fact, not a missing-Bundle result.

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

When selected Cask and App Store requirements have a confirmed shared application
identity, Prepare applies Cask-first precedence. `selection` remains the canonical
requested selection; additive `effective_selection` and `application_duplicates`
(`app_store_item_id`, `cask_item_id` pairs) describe the exact reduction. These
fields are absent when no duplicate is confirmed. `summary` describes the effective
publication scope; unresolved identity preserves both requirements. Desktop
validates each reduction against the requested inventory and uses the effective
scope for confirmation and strict publication-count validation.

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
selection, including the effective scope and confirmed duplicate pairs when present,
then uses production Preview, portability and Bundle checks. Execute receives the
original requested selection and recomputes precedence before checking the ID.
Bundle packing uses that freshly validated effective scope without a second
identity lookup. This adds no archive fields and does not rewrite existing Bundles.
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
Rows additionally report `source_present`: whether the domain's ordinary source
file exists in the validated archive. A present empty file remains present.
`capture_selected` reports whole-category inclusion or nonempty selected Blueprint
items, independently of retained complete inventories. Desktop hides explicit
absence and explicit exclusion in Selection; missing fields retain rows and
diagnostics. Selection eligibility and Restore draft selection are unchanged.

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

Prepare returns canonical requested `selection`: sorted category-only domain IDs
and sorted item-ID subsets, expanding whole item domains. New finer selection is
bound into `prepared_plan_id`; Execute repeats the same validated private staged
Blueprint narrowing and rejects mismatched/stale plans before publication/mutation.
Equivalent whitelist representations canonicalize to the same effective scope.
Legacy requests receive the additive public selection/correlation fields after
legacy identity calculation. The source Bundle, ordinary generated state,
persistent Blueprint and mutation consumers remain unchanged during preparation.
`include_secure` and the separate secret transport remain independent.

For proven, selected Cask/App Store overlaps, Core applies
[Cask precedence](../toolkit/CONFIGURATION.md) to the private Blueprint. Additive
`effective_selection` and `application_duplicates` fields occur only when an App
Store requirement is suppressed. Each duplicate contains `app_store_item_id` and
`cask_item_id`, both existing opaque Selection IDs. `selection` retains user intent
for refresh/Execute validation; counts, plan, readiness and Verification use
`effective_selection`. The only permitted reduction is the listed App Store IDs,
each paired with a retained selected Cask. No successful MAS installation is
inferred. Both requested scope and the deduplication decision are plan-bound.
Positive catalog bindings use the bounded private cache described in Configuration;
network loss alone does not change a still-confirmed decision. Cache timestamps
are not plan inputs; the effective staged requirements and qualification remain so.
Execute repeats qualification and rejects changed decisions as `stale_plan`.
Older nonduplicate responses retain their existing fields and behavior; clients
which cannot validate an effective reduction must reject it rather than guess.

Prepare validates/unpacks into private staging, narrows selection and runs the
production Preview. It returns:

- `prepared_plan_id`, selected groups/categories and item counts;
- `modules`, `plan`, `has_planned_changes`, `has_executable_changes`, `warning_count`, `error_count`;
- optional `scope_warnings`: domain names for warning modules without an explanatory
  attention row. These are distinct from item counters and readiness blockers;
  `warning_count` remains the complete module count, including Assisted App Store;
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
`check_policy=all_cask_item_conditions_then_first_operation_blocker_per_domain`,
`reentry=restore_prepare`. Conditions contain `domain`, `code`, `status`, `scope`,
and optionally a cask `selected_item_index` in selected Blueprint order.
Statuses are `satisfied`, `safely_satisfiable`, `external_action_required`,
`unsupported`. Domains report all encountered item-local skips before their first
operation-wide blocker. `scope=operation` retains whole-operation blocking.
For `homebrew-casks`, `cask_execution_requirements_unsupported` and
`cask_target_conflict` with an item index use `scope=item`: the item stays selected
and blocked, while independent planned work may proceed. `cask_rosetta_required`
with an item index also uses `scope=item`,
with status `external_action_required`; it skips only that Cask until manual
preparation and fresh Preview. Other prerequisite failures retain operation-wide blocking.
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

### Explicit PKG installer preparation

For an unregistered native PKG cask without usable captured/local payload
requirements, a blocked plan row may include `installer_preparation_id` and
`diagnostic: {primitive: "pkgutil", condition: "preparation_required"}`. The stable
reason remains `cask_execution_requirements_unsupported`; no installation is planned
yet. Known unsupported profiles do not offer preparation. Ordinary Prepare,
readiness and Verification never download archives.

After explicit consent listing the casks, `restore_prepare` accepts optional
`installer_preparations`: 1–32 unique opaque IDs from the retained plan. Consent is
for this request only, not future downloads or Rebuild. Core validates the complete
approved list against the selected Bundle/selection and current metadata before
calling the existing inert inspector. Failure returns `pkg_preparation_failed`
without publishing configuration or installing applications. No URLs or local
archive paths enter this contract. Older requests remain unchanged;
`features.pkg_installer_preparation.version=1` advertises the additive support.

Only portable app/receipt requirements are retained under private Homebrew workflow
state (`pkg-preparations`, directories 0700/files 0600), bound to Bundle/staged
selection fingerprints and installer metadata, including token, version, URL,
checksum and artifacts. Registration/time observations are not installer identity.
Records expire after 30 minutes, with bounded lazy cleanup during explicit
preparation (maximum 64 records/temporaries); ordinary Preview only reads evidence.
Archives and consent are not retained; interruption may leave only a private,
unusable temporary requirements file for later expiry cleanup. The source `.mbt`
is never modified. Expired/changed evidence requires new explicit consent.

Successful preparation returns a fresh plan. Execute repeats preparation and
native qualification without download permission, then uses ordinary Homebrew
Install and actual target receipts/payload Verification. Evidence never creates
receipts or authorizes ambiguous Repair. A native command's success alone cannot
establish installation. Rebuild confirmation remains separate.

Optional diagnostic response fields preserve V1 requests and the existing plan-ID
calculation. Prepare returns `plan_diagnostics`: SHA-256 fingerprints for `bundle`,
`stage`, canonical `selection`, preparation `parameters`, `plan`, `readiness`
(excluding external-tool provenance), and `modules`. These fingerprints are
computed before public row correlation and never authorize execution.
On a freshness refusal, Execute adds `plan_validation` with allowlisted `check`
(`prepared_plan_id` or `input_recheck`), `expected_id`, `recomputed_id` and the
recomputed `components`. Input rechecks also report Boolean
`bundle_changed_after_prepare` / `stage_changed_after_prepare`.
Desktop compares against the retained Prepare fingerprints in **Copy Diagnostic
Details**, without sending a baseline back to Core. Missing evidence is unknown;
a changed planning fingerprint alone does not establish actual target-state drift.
No paths, settings values, Bundle contents, free-form diagnostics or secrets enter
these fields. Older clients can ignore them and older Core responses remain usable.

Failure to run the required process observer before Bootstrap returns
`process_observation_unavailable`, preserving publication/mutation facts.
It is distinct from `bundle_unavailable`, which still reports inaccessible input.


Pending local publication returns `recovery_required`. Prepare does not recover
or mutate it; the existing CLI Restore owns recovery.

### Plan-sensitive application execution

| Selected work | Current application contract |
|---|---|
| Homebrew formulae | Usable Homebrew; an existing installation may be activated in the child PATH. Missing/broken Homebrew needs external action; no automatic installation |
| Casks | The Homebrew provider uses nonempty typed payload predicates, independently of registration. Qualified apps/suites, typed relocated payloads, binary/static ancillary links, declarative wrappers, bounded generic artifacts and observable native packages can install or repair through Homebrew. Requirements, ownership, historical cleanup and privilege are qualified separately. Unknown executable behavior fails closed |
| VS Code extensions | Usable `code` in PATH or the official stable CLI in `/Applications` or `$HOME/Applications`. Two copies without an explicit choice are ambiguous. CLI is required before publication even if VS Code's cask is selected |
| Git repositories | Usable Git and safe destinations. Clones use recorded remotes without credential/askpass prompts; SSH uses existing config/agent and strict known-host checking. HTTP(S) credentials and URL query/fragment are prohibited |
| App Store | Assisted Restore only: fresh read-only `mas list` inventory by numeric ID; missing/unverified items never block independent Restore work. No automatic installation, privileged fallback, or account probing |
| Secure SSH | Usable `age` and the separate secret bridge; importing user keys does not require administrator authorization |

App Store Preview rows use `action: inspect`: `satisfied` means installed in the
current validated inventory; `warning` / `manual_installation_required` means
missing; `unknown` / `observation_failed` means unverified. These rows are never
executable changes. Bootstrap retains its existing App Store module entrypoint but
only observes; a missing/uncertain item yields warning `1`, preserves
`MODULE_CHANGED`, and does not prevent later modules or Global Verification.
Verification performs a separate fresh inventory and reports verified, mismatch
or unverified. A successful page-open action is never evidence. Numeric `ID|label`
Bundle records and selection correlation are unchanged. Observation uses exact IDs,
not names; unavailable, failed or malformed inventory cannot establish presence or
absence. As before, this is inventory presence, not receipt signature or entitlement
validation. Spotlight indexing limitations of `mas list` still apply.


Cask repair is `reinstall` in Protocol V1 and delegates to native
`brew reinstall --cask TOKEN`; fresh installation uses `brew install --cask TOKEN`.
Macseed does not implement artifacts or edit Homebrew receipts/Caskroom. Ordinary
Restore never requests `--zap`, `--force` or `--adopt`.

Registration and a valid nonempty payload requirement must both match before an
item is satisfied. Apps require an Info.plist identity and executable; suites
require valid application members. Links must resolve to their declared executable
or cask-owned staged payload. Wrappers allow executable/arguments and bounded
locale/terminal environment declarations, not arbitrary content. Relocated artifacts
use explicitly supported standard destinations. Package evidence combines exact
macOS receipt IDs with actual required apps/files; receipts alone cannot verify a
package. Shared/ambiguous package ownership blocks cleanup.

PKG state inspection does not download installer archives to discover expected
payloads. Preview/readiness, Apply admission and Verification use local receipt
contents, typed metadata and portable captured payload requirements. Without
enough local payload evidence, the item remains unsupported/unverified; this does
not make every PKG unsupported. Homebrew still owns downloads during qualified
installation, and source requirements alone never establish target conformity.

Qualified generated completions use the public
`generate_completions_from_executable` declaration, an associated declared binary
or application executable, bounded completion commands/formats and standard shell
destinations. Observe and Capture read nonempty, user-owned regular output files;
they never invoke the generator. Native Homebrew owns generation during lifecycle
execution. Installation requires a checksum and available macOS sandbox support.
Repair binds historical/current generation semantics and requires Macseed's saved
output hashes before replacing remaining completion files; foreign or edited output
fails closed. Missing generated output remains drift even if Homebrew exits zero.

Current installation and historical cleanup are independently qualified. Compatible
version/checksum changes and newly qualified `quit` directives do not require
whole-definition equality. Replacement identities, saved destinations and current
requirements remain bound. Existing relocated replacements, pins, opaque hooks,
uninspectable history and broad destructive selectors block repair. Macseed prefers
its own post-Verification contract records; legacy inert JSON receipt/config evidence
has a structurally checked, fail-closed compatibility reader. No Ruby API, Ruby
execution, timestamp snapshot selection or private wrapper-directory layout is used.
Public current JSON is not claimed to be historical lifecycle evidence.

Qualified cleanup includes exact `quit`/service/package identities and bounded
`delete`, `trash`, `rmdir`, and login items whose application relationship is
observable. Active services need owned plist/program evidence; unknown jobs and
foreign login items fail closed. Existing configuration data without independent
ownership is preserved. Declared absent preference-file cleanup can be authorized;
absence does not imply native cleanup is unprivileged.

Unprivileged execution retains `HOMEBREW_NO_SUDO=1`. An
`authorized_native_lifecycle` profile runs Homebrew as its managing user, using
native sudo suboperations. Execute uses a fixed masked askpass prompt through
`sudo -A -v`; passwords go directly from the helper to sudo, never through Core,
Protocol, argv, environment values, files or logs. Preview does not authenticate.
The contract is requalified after authorization and before native mutation.
Checksummed HTTPS downloads retain Homebrew's checksum verification. Standard
`no_check` declarative payloads explicitly use HTTPS/source trust, not a claimed
checksum or publisher signature; unchecked native packages remain unsupported.
For native PKG Repair, caveats are informational only after the complete installed
and current lifecycle, exact receipts and cleanup ownership qualify. Private
receipt-backed `pkg_ownership` provenance detects stale source/receipt identities
and changed receipt-owned cleanup files; fingerprints do not establish ownership.
Unreceipted legacy wrappers cannot be adopted from path or content and remain
Unsupported (`ownership_unproven`). No in-place Repair is implemented; see the
[PKG Repair contract](../toolkit/HOMEBREW-CAPABILITIES.md#receipt-backed-pkg-repair-provenance).

Rosetta availability is a read-only, item-scoped prerequisite; see the
[provider contract](../toolkit/HOMEBREW-CAPABILITIES.md#rosetta-prerequisite).
Unqualified activation/license requirements, manual/script installers,
flight blocks, unqualified generated executable behavior and kernel-extension cleanup still
need external action or additional capability support.

Each privileged lifecycle holds a private lock and durable uncertainty journal.
A nonzero/aborted privileged operation is conservatively unknown because root
children or installer services may survive. Further mutation stops; Prepare blocks new Restore execution, including unrelated
selected domains, with `privileged_lifecycle_unknown`. Payload Verification remains
independent and cannot clear the journal. Manual process/state inspection is required
before explicitly reconciling this quarantine; no automatic rollback or safe root
cancellation is claimed. Completed native lifecycle plus quiescent tracked processes
allows final independent Verification and repeat-run idempotency.

### External tool adapter results

The concrete Homebrew adapter exposes contract version 1 with `tool`, `state`,
`compatibility`, `reason`, `operation`, `provenance` and `capabilities`. Normalized
states are `satisfied`, `installable`, `repairable`, `unsupported`, `incompatible`
and `observation_error`. Compatibility distinguishes `compatible`,
`item_unsupported`, `tool_unavailable`, `capability_unavailable`,
`metadata_incompatible` and `observation_failure`.

Readiness adds `external_tools` capability/provenance records and a `compatibility`
field on relevant conditions. `homebrew_capability_unavailable` and
`homebrew_metadata_incompatible` block the operation; unsupported individual
artifact semantics retain the existing item-scoped reason.
`cask_launchctl_observation_failed` is an observation failure, never absence.
Public `brew help` command/option availability and actual inventory/JSON shape are
checked; observed version alone neither grants nor denies compatibility.

Blocked cask rows may add a bounded `diagnostic: {primitive, condition}`; matching
item-correlated readiness conditions preserve it. The context contains no paths
or raw output and participates in plan identity. It explains the existing reason
without changing readiness scope or authorizing mutation. See the
[capability matrix](../toolkit/HOMEBREW-CAPABILITIES.md).

Qualified planned cask rows add `qualification_id` and `authorization_required`;
these fields participate in prepared-plan identity. Provider results also carry
typed `evidence` and an action-specific `execution` contract. Credentials are not
part of either value.

Native command construction, artifact/receipt qualification, observation,
dependency metadata and post-install observation belong to the Homebrew adapter.
Domain consumers retain selection, lifecycle hooks and Verification reporting.
The adapter repeats all repair checks inside the same watchdog after dependency
resolution and immediately before native execution. The qualification digest and
authorization requirement are prepared-plan fields; a changed digest skips mutation. Changed preconditions
emit a structured skipped operation reason, prevent that item's native mutation
and preserve independent work and final Verification. No preview or precondition
snapshot provides an atomic filesystem/launchd guarantee.

Internet is required for missing automatic installs/clones, and Command Line Tools
for missing Homebrew formulae/casks. Qualified Homebrew authorization follows the
selected plan. Manual App Store installation uses Apple App Store's own account
and authorization outside Core; there is no MAS installation or sudo prerequisite.
Unrelated prerequisites do not block settings-only or Secure-only plans.
Selected SSH configuration is an existing operation-wide Restore prerequisite.
Preparation and Execute reuse its read-only inspector: conflicts or excluded source
report `ssh_configuration_not_ready`, and observation failures report
`ssh_configuration_observation_failed`, before configuration publication or Apply.
Matching partial snapshots and absent source requirements retain their existing behavior.
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
from JSONL and terminates owned processes on forced cancellation. Graceful Stop
uses the safe checkpoints below. Private staging is
cleaned on handled exit; SIGKILL/power loss cannot guarantee cleanup. There is no
daemon, XPC service, persistent session/resume database or Bootstrap transaction.

### Restore Graceful Stop checkpoints

The existing private control pipe and locked state now cover the whole Execute
operation, starting before preparation. A delivered `S` is latched independently
of the current module and emits the existing `graceful_stop_accepted` event.
Preparation completes to its next checkpoint; atomic publication finishes before
Stop is applied. No Bootstrap starts after an observed pre-Bootstrap stop.
The same controller/state is shared with OwnedBootstrap; there is no second reader.

Bootstrap checks Stop before/after modules, between Workspace folder/repository
items, VS Code/App Store items and macOS settings categories, and before/after
Global Verification. A clone, individual install with required local post-checks,
settings-category application, Git configuration, SSH/Shell application and secure
import remain indivisible. A Verification already in progress may finish; Stop does
not start a new full-scope Verification. Homebrew admission still orders Stop and
native launch under the same `flock`; Graceful Stop never signals an active installer.
Errors retain precedence and partial records/publication/mutation facts are preserved.

An active installer may take unbounded time after accepted Stop: the ordinary
no-progress termination remains suppressed while stopping. Force Stop is separate
and may leave unknown consequences. This is not rollback, Resume, Stage 3C durable
ordinary-Cask reconciliation, or qualification of arbitrary privileged descendants.
Automated fixtures establish checkpoint behavior, not real-Mac installer safety.

### Independent Homebrew items

Application Restore watches each formula/cask metadata/install subprocess for
**180 seconds without observable progress**, rather than limiting total runtime.
Owned writable regular-file growth, advancing artifact read offsets (excluding
logs, locks and terminal output), and compiler/linker CPU time reset the timer. Curl/Ruby CPU activity,
process liveness and diagnostic output do not count. Progress observations remain
private; they are not percentages, network speed or proof of installation.

Accepted item-local `cask_target_conflict`, `cask_rosetta_required` and
`cask_execution_requirements_unsupported` casks remain visible in Prepare and final
results without becoming executable actions. Global prerequisites remain blocking.
Core carries
their identities in private per-operation state; the production consumer records
`skipped` / `cask_execution_requirements_unsupported` without invoking their
installer, even if metadata later becomes eligible. It also repeats the existing
artifact safety gate for planned casks. Supported independent items and domains
continue, retaining production ordering, cancellation and watchdog behavior.
Cask dependencies are recursively qualified before planning native installation;
accepted skips also seed the Homebrew dependency gate. Broken registered dependencies
are not silently treated as repairable by a parent install. Selection and prepared-plan binding remain intact.

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

## Opt-in Restore performance trace

For a diagnostic run only, start Desktop from a shell with an explicitly private
output directory (use a fresh directory for each operation):

```bash
trace_dir="$(mktemp -d /private/tmp/macseed-performance.XXXXXXXX)"
MACSEED_PERFORMANCE_TRACE=1 MACSEED_PERFORMANCE_TRACE_DIR="$trace_dir" \
  /path/to/Macseed.app/Contents/MacOS/Macseed
# After the operation: read "$trace_dir/totals.json".
```

The executable must be launched directly; an already-running Desktop process does
not inherit newly set shell variables. No workflow runs merely by enabling trace.
Desktop forwards only `MACSEED_PERFORMANCE_TRACE=1` and a nonempty
`MACSEED_PERFORMANCE_TRACE_DIR` from its parent environment; it neither creates
the directory nor inherits arbitrary diagnostic variables. Core retains ownership,
permission and symlink checks. Quit the diagnostic instance and launch normally
to disable it. Unset/`0` starts no clock helpers and writes no trace. Capture and Environment Status are not
instrumented by this Restore trace.

`totals.json` is a private `0600` aggregate in a user-owned `0700` directory. It
contains fixed metric names and `count`, `seconds`, `max_seconds` only; no item
identifiers, argv, paths, URLs, Bundle data or secrets. Concurrent writers merge
under a file lock. Scopes distinguish `preview`, `requirements`, `publication`,
`bootstrap`, `verification` and the outer `core` process. Timings include Bundle
validation/unpack and fingerprints, readiness passes, startup validation, Bootstrap
launch-to-first-lifecycle delivery and the shell interval before the Launcher module, Cask metadata/prefix/inventory commands and external observer
commands. The explicit PKG inspector retains a download timer, but state
classification no longer invokes that download. Timings also include unsupported
classification and Verification domains.

Python uses `time.monotonic()`. Bash uses one persistent opt-in clock helper per
Bootstrap process, with acknowledged begin/end messages; no Python is launched
per measurement. Nested timings are inclusive and must not be summed as disjoint
phases. `cask.unsupported` measures classification that returned unsupported,
not installation. Metrics aggregate across items: a maximum does not identify a
specific Cask. Instrumentation adds diagnostic IPC/I/O overhead; it is for locating
expensive work, not comparing small timing differences. The helper flushes on idle
and exit; allow a second after completion before reading. Forced termination can
omit unfinished/unflushed spans. Invalid/unwritable output or unavailable helper
disables diagnostics without changing operation outcomes. No trace enters Protocol
V1, operation JSONL or Diagnostic Report. This trace is not restoration evidence.

## Verification and Environment Status

Each structured Restore Preview, read-only readiness invocation and Global
Verification domain pass obtains fresh formula, App Store and VS Code inventories. Cask passes reuse only their
common prefix/registration inventory; item metadata and payload observations stay
independent. These shell-local snapshots never survive into Apply or a later
pass. Capture and ordinary CLI Preview retain their existing observation path.
Failed or malformed inventories remain observation errors, not absence.
Inventory-based Verification records use the snapshot's observation timestamp.
Readiness reports validate their private inputs once while retaining live-state
checks per domain and mandatory fresh readiness before publication/execution.

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

These are predicate-level counts: a repository can contribute separate Worktree,
Origin and Branch results. Desktop may aggregate its visible repository row and
category badges by stable item identity, without replacing these Core totals.
Comparison preserves the reference Blueprint; unlike Restore Prepare, it does not
apply Cask-first narrowing or return `effective_selection`. A legacy reference
selecting both Telegram Cask and its App Store ID therefore retains both
provider-specific requirements, even when their application identity overlaps.
A matching Cask cannot satisfy the App Store predicate. Extending Comparison to
an effective scope requires an explicit contract decision covering records,
counts, verdict and source-inventory provenance together.

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
Private subjects use opaque IDs; Restore repositories use selection indices. Bundle-backed
Comparison may expose optional `reference_presentation.repository_labels` only in
successful result display metadata: exact opaque repository IDs map to safe names
from the validated selected Blueprint. Labels reuse Restore sanitization and
Capture's restricted repository-name character/length rules. They are local UI
metadata, not diagnostic identities; diagnostic records, failure payloads and
exported diagnostics must not include these labels. Clients must use neutral
repository labels when trusted metadata is absent or unsafe.
Public fingerprints appear only in Capture SSH candidate inventory. Capture's
absolute `destination` result returns the necessary path supplied by the client.
