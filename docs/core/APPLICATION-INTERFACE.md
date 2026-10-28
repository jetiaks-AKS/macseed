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

Prepare validates explicit Workspace dependencies before confirmation. Missing
selected checkout base/parent dependencies report `workspace_dependency_missing`;
conflicting destinations or aliases report `workspace_path_conflict`. A folder
and checkout at the exact same validated path are compatible roles; folder-only
selection does not implicitly require Git. Clients may return
to selection review and prepare again; Core never adds or removes selected items.
Other invalid Workspace metadata reports `invalid_workspace_selection`, while
unreadable staged input reports `capture_inventory_invalid`. These fixed codes
contain no private values. Prepare failure precedes Bundle publication.

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

Topology Bundle Prepare uses the same Selection, private staging and plan records.
Git rows retain positional `item_id` and opaque `selection_item_id`, with additive
`checkout_id`, `checkout_role` (`base`/`linked`), `head_kind`, `dependency_ids`, and,
when observed, `local_changes`/`protected_files` booleans. `add_worktree` is a planned
action; `switch_branch` with `head_kind=detached` means an exact detached HEAD target.
No origin, absolute path, OID or file content is exposed. Safe typed reasons use the
`workspace_` prefix. Missing selected base/parent dependencies fail Prepare with
`workspace_dependency_missing`; selection is never expanded implicitly. The domain
contract lists the evidence boundaries in
[Configuration](../toolkit/CONFIGURATION.md#topology-restore-preview--phase-3).

Topology evidence contributes to `prepared_plan_id` and the optional diagnostic
`workspace_observation` digest. Core Execute admits qualified topology plans through
the existing publication and owned Bootstrap lifecycle. A private context binds the
confirmed actions and source/staged/published identities; Workspace rechecks these
before each action. Conditional dependent rows retain `disposition=planned` and
`workspace_dependency_pending` (or `workspace_commit_after_clone`), without claiming
that branch/object availability has already been established.

Readiness and `has_executable_changes` control Desktop Rebuild as for other domains;
all-matching plans require no Execute. Item conflicts/unsupported observations remain
visible and are never converted into mutations. Operation/lifecycle records use the
existing shapes. Global Verification reports `topology` conformity for selected Git
checkouts and `directory` conformity for folders; Git exit 0 alone is insufficient.
Unknown consequences retain the existing durable Execute fence. See the
[execution and recovery limits](../toolkit/CONFIGURATION.md#topology-restore-execute--phase-4).
Selected `vscode-workspaces` items retain stable `workspace-<sha256>` identities in
Capture, Restore Selection, plan and operation records. Preview uses `create_workspace`
for absent descriptors and the existing satisfied/conflict/unknown dispositions.
Global Verification emits `folder_relationships`, checking ordered paths and display
names after selected dependencies. No descriptor content or private absolute paths
enter these records. See the [descriptor contract](../toolkit/CONFIGURATION.md#vs-code-workspace-descriptor-restoration--phase-5).
Environment Status remains unsupported for these extensions. Ordinary legacy Bundle
behavior is unchanged.

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
Clients can compare against retained Prepare fingerprints without sending a baseline
back to Core. Missing evidence is unknown; a changed planning fingerprint alone does
not establish actual target-state drift. [Desktop](../DESKTOP.md#rebuild-and-result-navigation)
owns current presentation and diagnostic access.
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

Formula execution uses the same `active.json` and lifecycle lock with write-ahead
publication before its outer metadata/native chain. Homebrew dependency metadata
observers also establish active state before launch. Private files and directory
entries must both pass fsync before any affected subprocess starts; preparation,
publication or durability failure denies launch. Nested Formula supervisors inherit
the validated owner lock descriptor; they cannot clear the parent's journal.

Unconfirmed quiescence overrides zero and nonzero exits with
`privileged_lifecycle_unknown`. The operation marker blocks later items/modules;
the durable active record survives supervisor termination and failed diagnostic
updates, blocking fresh Execute before publication even without Homebrew selected.
Only the owning supervisor can publish confirmed quiescence. A successful,
quiescent operation removes its own record; a confirmed safe item failure retains
`quiescent`/`failure` state and allows independent work. Active/unknown records are
never cleared by failed operations, later observation or Verification.

This closes D1's detected-uncertainty and durable re-entry gap. ProcessTree still
cannot prove absence of children that detached before observation or of external
service activity outside its tracked identities/session. Real native/watchdog
qualification and ordinary-Cask recovery remain separate open gates.

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

Application `result`/`failed`/`cancelled` payloads may include bounded
`observation_diagnostics`: tool (`homebrew`/`other`), probe class, typed failure
reason, `phase: observation`, `duration_ms`, `quiescent` and an optional
`native_exit_code` or `native_signal`. This separates launch/process observation,
native Homebrew failure, deadline, output limit, surviving worker and unconfirmed
quiescence. Private operation scratch transports at most 64 failure records to
the existing Protocol projection; it is not a persistent log. No arguments,
paths, environment, exception text or process output are included. Desktop retains
a bounded allowlisted projection in its existing Operation Log/Diagnostic Report;
this does not change workflow statuses or imply complete raw diagnostics.

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

An active installer may continue until the aggregate execution deadline after
accepted Stop: the ordinary no-progress termination remains suppressed while stopping. Force Stop is separate
and may leave unknown consequences. This is not rollback, Resume, Stage 3C durable
ordinary-Cask reconciliation, or qualification of arbitrary privileged descendants.
Automated fixtures establish checkpoint behavior, not real-Mac installer safety.

### Independent macOS settings

Application Restore validates all selected macOS configuration inputs, including
the Screenshots destination safety checks, before applying the first category.
It uses `run_module` over the existing `apply_macos_components` dispatcher:
Finder, Dock, Windows, Keyboard, Trackpad and Screenshots each retain their own
Check → Apply → Verify sequence. A category observation error skips its Apply;
an Apply or local Verify failure retains partial changes. Independently checked
categories continue, while the aggregate remains failed with existing counters
and category failure records. Normal Global Verification still follows safe
partial failures; it does not erase the execution failure.

Invalid selected inputs block the entire group. Existing Stop checkpoints and the
external-tool unknown-consequences marker block subsequent categories. Ordinary
CLI retains its aggregate `run_configuration` Check gate. Disposable fixtures
(`bash scripts/test-macos-bootstrap.sh --d4-only`) cover these boundaries; they do
not qualify real macOS 27 visual effects or remaining native Restore gates.

### External process waiting and Git clone (R5)

Application process bounds and the shared durable-admission fence are implemented;
the [D1–D4/R5 repair queue is accepted](../../ROADMAP.md#current-practical-execution-order)
within its documented implementation and automated integration boundaries.
This is not native lifecycle qualification. Existing ProcessTree birth identities,
private sessions, private directory checks and atomic/fsynced journal publication
remain authoritative. No second execution engine or Protocol V2 is introduced.

| Operation / caller | Mode and budget | Progress evidence | Quiescence / re-entry |
|---|---|---|---|
| `repository_clone` → `clone_execution.py` | Restore Execute only; 7,200 s per clone | Local Git `Receiving objects`, `Resolving deltas`, `Updating files` increasing numeric counters/received bytes: 600 s without advancement while a reported phase is incomplete | Bounded owned TERM/KILL/reap and pipe EOF; known partial destination retained and fenced; unknown blocks every fresh Execute |
| VS Code extension install / Execute inventory | Existing Restore lifecycle; 3,600 / 120 s | Deadline only | R5A durable uncertainty and continuation rules retained; open output writer cannot be success |
| VS Code Discovery, Preview/readiness, Comparison, secure verify-only; assisted App Store `mas list` | Read-only inventory: 120 s | Deadline only | Complete bounded output required; no persistent observer journal/lock |
| Git repository/configuration reads, developer-tool readiness, macOS scalar reads | Application read-only calls: 30 s | Deadline only | Failed read remains observation failure, never absence/match |
| Capture macOS settings serialization | 30 s for all sequential reads in one category | Deadline only | Existing Bash serializer inside one owned observer; atomic publication waits for quiescence, EOF and validation |
| Homebrew shell inventories/metadata; Python provider reads | Application reads: 120 s inventories, 30 s provider/local reads | Deadline only; existing Homebrew installation progress policy unchanged | Read-only route, no installer lifecycle adoption |
| Preview, staged Capture/Discovery, Comparison, final Verification | 900 s aggregate phase budget; readiness 180 s | Deadline only | Failed/incomplete result; final Verification retains operation context until collection |
| Owned application Bootstrap | 86,400 s last-resort aggregate budget | Deadline only, including otherwise unqualified local subprocesses | Interrupted mutation is unknown; no independent continuation or automatic retry |
| Watchdog `ps` / `lsof`, report drain, final child reap | 2 s per kernel observer; 32 chunks per drain; 1 s final reap | No inferred progress | Failed observation cannot certify quiescence |

Budgets are production policy constants; tests inject short budgets without changing
production defaults. Completed Git phases revert to deadline-only waiting until a
new numeric phase starts. Increasing received-byte totals also count, even inside
one large object. Remote messages, stdout volume, a live PID and generic
CPU activity never reset the clone no-progress timer. Authentication, DNS, initial
negotiation and unreported local work remain deadline-only. The overall no-progress
qualification checkpoint therefore remains open.

Clone admission requires application Restore flags and a private execution-state
directory. Missing/invalid state does not select native Git. Before launch, the
GitClone lifecycle lock and `active.json` under
`~/Library/Application Support/Macseed/GitClone/` and the existing operation-local
`external-tool-active.json` are durably published. Publication failure denies launch;
active state survives supervisor death. Only its owner publishes confirmed completion.

The clone passes the selected branch directly to Git and retains the original remote.
It disables prompts, credential helpers, hooks, templates, automatic maintenance,
recursive submodules and local hardlink cloning for that command. Configured filters
(including LFS), URL rewriting/includes, global remote/upload-pack customization and
Git routing overrides are declined before mutation. Supported transports are local
paths/file, HTTPS and SSH. SSH uses a private, bounded snapshot of the local
`~/.ssh/config` when present, preserving native `Host` matching, hostname/user/port,
identity/certificate files and ordinary connection settings. Includes, Match/exec,
providers, agent routing and delegated transports are declined before launch.
Missing config uses `-F /dev/null`. Strict known-host verification, no host-key
updates, no multiplexing, proxies, forwarding, local commands or agent additions
remain mandatory command overrides. No global Git/SSH
configuration, known_hosts, keys, shared master or agent is changed or terminated.
See [Git clone](https://git-scm.com/docs/git-clone) and
[OpenSSH configuration](https://man.openbsd.org/ssh_config) for command semantics.

A confirmed terminated controlled clone may leave a known partial destination.
It is never deleted or repaired. A durable path-digest fence prevents treating even
an apparently valid `.git` as ready on Preview, Verification or another Execute.
The failure record stays a failure. Later repositories may run only at disjoint
resolved destinations without linked/shared Git metadata; earlier successful Changed
state and ordinary Global Verification are retained. This does not extend D3 checkout-refusal evidence to partial clones.
Stop still acts at item checkpoints; Force Cancel terminates owned work.
Unconfirmed process observation/termination or state publication leaves unknown
consequences and blocks later modules and fresh Execute, even with Git unselected.
There is no journal-clear, rollback, cleanup or automatic retry command.
The global external-process fence is checked before recomputing Execute preparation:
an existing unknown lifecycle retains `privileged_lifecycle_unknown` even when
the interrupted work also changed Preview. Publication checks remain fresh.

Clone failures carry bounded typed authentication, host-key, branch/source,
configuration, observation or lifecycle reasons. When available, the native exit
is retained separately as `native_exit_code` in the operation record and existing
Desktop Log. Raw stderr, SSH configuration, identities and remote URLs are not
exported. The result row shows one short explanation, retaining independent
Verification findings without replacing the operation failure.

Homebrew application reads set `HOMEBREW_NO_ANALYTICS=1` and
`HOMEBREW_NO_AUTO_UPDATE=1` per process. This prevents detached analytics workers
without changing global Homebrew preferences or accepting live workers as success.

Read-only calls use bounded nonblocking output collection and confirm owned-tree
termination plus pipe EOF. A reaped root, EOF and a final empty owned-tree scan
complete a read without redundant stop scans; failures still require bounded
termination and EOF confirmation. Timeouts/errors do not publish an empty inventory.
These calls create no durable mutation state and never clear safety journals. Within an
existing Execute, unconfirmed termination marks the operation unsafe; its parent
retains the write-ahead `ExternalProcesses/active.json` fence using the same journal
primitives. A last-resort Bootstrap deadline also retains this fence. Readiness only
reads it. Read-only failure alone does not imply installer uncertainty. Python shell
entrypoints use `-B`, including Capture helpers, to prevent startup/import bytecode
writes into the observed HOME.

Capture groups each macOS category's short `defaults read-type/read` calls inside
one supervised serializer, avoiding repeated Python startup and nested process-table
scans. The private child admits only these read commands; ordinary CLI and other
application reads retain their existing routes. Warning/error classification and
the existing candidate-file validation/publication remain production-owned.

Before launching a mutating OwnedBootstrap, its parent takes the private
`ExternalProcesses/lifecycle.lock` and publishes an owner-bound `active.json`
with file and directory fsync. Failed admission prevents the subprocess launch;
a parent crash before collection leaves `active` blocking fresh Execute. The
child's readiness may recognize its own admission only through the inherited,
inode-checked lock descriptor and matching owner token. Another Execute cannot
adopt it. Bundle publication and Secure Migration retain their separate contracts.

Collection may finalize only the same owner's active record, after normal root
exit, observed tree quiescence and no uncertainty marker. A mutation must also
have reached traversal completion or an accepted Graceful Stop checkpoint.
Confirmed ordinary failure is not success, but does not leave a false global
block. Hard cancellation, abnormal exit and unconfirmed completion retain blocking
active/unknown state, even when owned processes were stopped. A valid quiescent
record permits later admission; existing unknown or foreign records are never
automatically cleared. Force Cancel with retained uncertainty returns
`privileged_lifecycle_unknown`, exit `2`, with `unknown_consequences=true` and the
existing mutation/publication facts. Observed child termination alone cannot turn
it into `cancelled` / `130`. An accepted Graceful Stop finishes the current
indivisible work and reaches a confirmed safe boundary; without uncertainty its
handled result remains `cancelled` / `130`.

Preview/Prepare, Comparison and secure verify-only create
no such journal or lock. Disposable fault injection covers admission write failure,
parent exit after mutation before collection, blocked retry, owner protection and
normal completion/re-entry; it is not real-Mac or power-loss qualification. There
is no recovery, journal-clear or bypass operation.

Limitations: ProcessTree covers observed descendants and private-session members,
not a child that escapes before observation, arbitrary external services or concurrent
unowned changes. Unsupported clone delegation is declined rather than qualified.
The 24-hour aggregate bound is not per-command lifecycle qualification for existing
checkout, preferences or other local mutations. Blocking filesystem/kernel calls,
including an uninterruptible fsync, are outside a Python subprocess deadline.
Real network/large-repository budgets, SSH transport, native Stop timing, detached
workers and reconciliation remain qualification work. Focused CI entry:
`scripts/test-external-process-reliability.py`; all mutations use disposable fixtures.

### Bounded VS Code CLI execution

Inside application Restore Execute, the extension module and final Verification
use supervised `--list-extensions` and `--install-extension` calls over Core's
existing `ProcessTree`. Absolute policy budgets are
120 seconds for inventory and 3,600 seconds for one extension installation,
including its CLI-managed dependencies. They bound waiting; they do not detect
absent progress. No terminal output, CPU sample or Homebrew `ProgressProbe` resets
these budgets. Downloads can run for the entire installation budget. Exceeding it
is `vscode_install_deadline` (inventory: `vscode_inventory_deadline`), never a
claim that a slow operation made no progress. Real budget qualification remains open.

The shared `vscode_cli()` retains its native shell invocation. Ordinary CLI keeps
its native contract. Application Preview, Prepare/readiness, Capture/Discovery,
Comparison and secure verify-only inventory use the bounded read-only observer
above, without permanent VS Code lifecycle state. Installation lifecycle
supervision remains explicit to Restore and its final extension Verification.

The supervised route requires application mode, active Bundle Restore,
`MODE=--bootstrap`, and no Preview/secure verify-only scope. Its dedicated Bash
consumer supplies `MACSEED_VSCODE_SUPERVISED_RESTORE=true` to Python. Both inventory
and installation then require a valid operation-state directory before any durable
state is created; missing state denies launch without a native fallback.
The owned Bootstrap keeps that operation-state directory alive through final
Verification and removes it only after the child exits and lifecycle facts are
collected. Readiness observations within Execute still use the read-only route.
Installation diagnostics follow the selected route: native installs retain the
bounded output classifier plus captured native/reader exit statuses; supervised
installs consume the supervisor's typed result and additionally require quiescence.
Native execution never claims ProcessTree quiescence it did not observe.

The supervisor starts a private session, drains output without forwarding it,
and reuses birth-identity/session tracking and bounded TERM → KILL termination.
It also bounds the root wait after termination. Failed process observation or
unconfirmed termination cannot become Success, including after native exit zero.
Only validated extension IDs leave inventory; installation output reaches only
the existing bounded, closed `network_reset` classifier. URLs, credentials,
profile paths and arbitrary arguments/output never enter reports or logs.

Before either supervised CLI call, the existing private-directory/atomic-journal primitives
publish and fsync VS Code safety state under
`~/Library/Application Support/Macseed/VSCode/active.json`, holding its lifecycle
lock and publish the existing operation-local `external-tool-active.json` marker.
The global `--pending` check only reads existing state, including in Prepare and
live readiness; it creates no journal, lock or directory and never clears one.
Failure to establish durable state denies launch. Confirmed ordinary completion
publishes a quiescent success/failure record and removes only its own operation
marker. Interrupted, timed-out or unobservable calls retain blocking active or
unknown state, including if the supervisor dies or a diagnostic update fails.

An interrupted installation stays unknown even when the observed tree stops;
unchanged inventory cannot rule out detached/delegated background work. Later
modules are blocked by the operation marker, and the global readiness gate denies
fresh Restore before publication even with Applications unselected. Existing V1
`unknown_consequences` / `privileged_lifecycle_unknown` carry this fail-closed
result; the legacy code name does not imply that VS Code ran privileged.
Verification and another Preview cannot clear the journal. No automatic retry,
rollback or journal reconciliation is introduced.
Prepare's per-domain readiness report can be empty when Applications are disabled;
the mandatory live Execute gate still rejects that plan before publication.

Independent continuation remains limited to a normally exited `network_reset`
failure, confirmed observed quiescence, successful diagnostics and a fresh
unchanged inventory with the requested ID still absent. Native signals, deadline,
observation/quiescence failure and unknown errors do not authorize another install.
Surviving observed workers after root exit are terminated, but retain unknown
consequences (`vscode_process_interrupted`); a killed worker is not a normal
quiescent completion.
The disposable orphan-worker fixture covers root exit zero with a live owned
worker, confirmed and unconfirmed termination, retained unknown journals and
blocked fresh Execute before publication, including without Applications selected.
Graceful Stop still waits for the existing item checkpoints; it does not signal
active VS Code work. Hard Cancel preserves uncertainty instead of reporting safe
cancellation from command termination alone.

The [macOS launcher](https://github.com/microsoft/vscode/blob/main/resources/darwin/bin/code.sh)
can redirect through remote IPC. An inherited `VSCODE_IPC_HOOK_CLI` or resolved
`remote-cli` path is declined before launch; no remote target is silently changed.
ProcessTree still cannot prove absence of children detached before observation,
external services or concurrent unowned VS Code activity. Read-only observers are
bounded separately above; real termination/re-entry and Extension Pack dependency
closure remain separate qualification work. Disposable coverage:
`python3 scripts/test-vscode-extensions.py --r5a-only`. The focused
`--routing-only` selector also checks native/typed diagnostic separation,
operation-state admission and lifetime, and full HOME snapshots for
Prepare/readiness, Comparison and secure failure verify-only. The latter uses a
separate secure Bundle and the real verification dispatch. Snapshots include
caches, bytecode and lifecycle state without exclusions; only mock interpreters
receive a mock-local bytecode setting. Production reporting disables bytecode
before imports and at its Bash entry point.

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
to disable it. Unset/`0` starts no clock helpers and writes no trace. The same
explicit opt-in also measures Capture Prepare and Environment Status reads.

`totals.json` is a private `0600` aggregate in a user-owned `0700` directory. It
contains fixed metric names and `count`, `seconds`, `max_seconds` only; no item
identifiers, argv, paths, URLs, Bundle data or secrets. Concurrent writers merge
under a file lock. Scopes distinguish `preview`, `requirements`, `publication`,
`bootstrap`, `verification` and the outer `core` process. Timings include Bundle
validation/unpack and fingerprints, readiness passes, startup validation, Bootstrap
launch-to-first-lifecycle delivery and the shell interval before the Launcher module, Cask metadata/prefix/inventory commands and external observer
commands. The explicit PKG inspector retains a download timer, but state
classification no longer invokes that download. Timings also include unsupported
classification and Verification domains, plus `observation.read` and
`observer.process_table` call counts and durations. Formula/VS Code inventory and
module spans, `readiness.lifecycle`, and `reporting.record` separate native reads,
journal checks and ordered operation-record serialization.

Python uses `time.monotonic()`. Bash uses one persistent opt-in clock helper per
Bootstrap process, with acknowledged begin/end messages; no Python is launched
per measurement. Nested timings are inclusive and must not be summed as disjoint
phases. `cask.unsupported` measures classification that returned unsupported,
not installation. Metrics aggregate across items: a maximum does not identify a
specific Cask. Instrumentation adds diagnostic IPC/I/O overhead; it is for locating
expensive work, not comparing small timing differences. The helper flushes on idle
and an acknowledged finish request. An opt-in Bash EXIT hook waits for its own
clock helper and forcibly reaps a stuck helper after a bounded wait, preserving
the command's exit status. An existing EXIT hook is left intact and prevents
starting the clock. Forced termination can omit unfinished/unflushed spans.
The final shell `wait` reaps that same nonprivileged Python child after normal
exit or SIGKILL; the helper neither changes identity nor launches delegated work.
This bounds ordinary user-space stalls, including interpreter finalization, but
is not a hard wall-clock guarantee against an unresponsive kernel or storage stack.
Invalid/unwritable output or unavailable helper
disables diagnostics without changing operation outcomes. No trace enters Protocol
V1, operation JSONL or Diagnostic Report. This trace is not restoration evidence.

## Verification and Environment Status

Each structured Restore Preview, read-only readiness invocation and Global
Verification domain pass obtains fresh formula, App Store and VS Code inventories.
Cask passes reuse their common prefix/registration inventory and batch public
metadata for 2–128 selected tokens. A batch must contain exactly one row for every
selected token and no other tokens. Failed, malformed or incomplete batches provide
no evidence; the pass falls back to independent per-item reads with their existing
error classification. Single-item and larger scopes use the per-item path.
Receipt, payload, ownership and installation requirements are still checked per
item. Snapshots stay shell-local to that read-only pass; Cask Apply requalification
and post-Apply checks retain fresh per-item observations. Capture and ordinary CLI
Preview retain their existing observation path.

During application Restore, each formula or supervised VS Code module obtains one
fresh, complete, validated inventory for consecutive Already Matches records.
An absent item in a reused snapshot requires a fresh read before installation.
Every installation attempt invalidates the snapshot; successful installation still
requires observed post-Apply verification. Each selected item retains its own
operation record and Stop checkpoint. A later module invocation and final Global
Verification start fresh. Failed or malformed inventories remain observation
errors, never absence or Match.

| Repeated work | Purpose and retained boundary | Reuse within one pass |
|---|---|---|
| Cask public metadata | Current provider facts; separate receipt/payload/ownership checks | One complete batch in each read-only pass |
| Formula/VS Code inventory | Observe installed IDs; fresh pre/post-Apply and final Verification | One validated snapshot for consecutive noops |
| Bundle/plan validation and readiness | Fresh Execute preparation, pre-publication admission and Bootstrap startup | No reuse across those boundaries |
| Lifecycle journals and item records | Block uncertain re-entry; preserve every outcome and event order | No removal or batching; trace measures their cost |

Inventory-based Verification records use the snapshot's observation timestamp.
Application macOS scalar Preview, category Check and Verification batch native
`defaults read-type`/`read` calls inside one owned observer per selected category,
reusing the authoritative comparison and byte validation. The private snapshot is
local to that call; Apply's per-record pre-check and post-check read fresh state.
Batch failure remains an inspection error. Capture already uses category batches;
ordinary CLI reads retain their existing path. No snapshot crosses operations.
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
| Operation | `record_id`, `domain`, `item_id`, `action`, `outcome`, nullable `reason`; application clone may add bounded `native_exit_code` |
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
