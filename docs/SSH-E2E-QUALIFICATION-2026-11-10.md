> **Current outcome:** approved-correction no-op and the bounded Capture inventory
> correction are **LOCALLY VERIFIED PASS**. Positive Core Git-over-SSH remains
> **BLOCKED** by native SSH sandbox initialization and Internet readiness.
> Native SSH belongs to the full application-wide Desktop E2E after functional
> development in an isolated macOS test account; hosted CI was not run.
> Sections 1–13 retain the original run unchanged, section 14 retains the no-op fix
> evidence, and sections 15–16 record the remaining Core/privacy follow-up.
> [Roadmap](../ROADMAP.md#ssh-environment-completion--developer-environment-closure)
> owns current gate order; historical failure and Git-state statements remain dated evidence.

# Joint SSH real-Mac E2E qualification — 10 November 2026

**Baseline:** `821ba853183ec06f455fe90f42d43d7d3c6e1f47`, branch `develop`.
**Overall:** **PARTIAL — one reproduced convergence failure; native and successful SSH-clone gates remain open.**

This is one integrated qualification of unchanged production Core, executed on a
real Mac through its application CLI. It is not native Desktop, hosted CI, a
packaged build, or clean-Mac qualification. No production code, tests or accepted UI
were changed. No commit or push was performed.

The [Roadmap](../ROADMAP.md#ssh-environment-completion--developer-environment-closure)
owns gate status; [TODO](../TODO.md#ssh-environment-completion--developer-environment-closure)
owns unfinished work. This report owns the evidence from this run.

## 1. Environment and isolation

The host reported macOS `27.2`, Darwin `27.2.0`, arm64; real tools were
OpenSSH `10.5p1`, LibreSSL `3.3.6`, age `v1.3.2`, system Git and Xcode Python 3.9.
No tools were installed. CLI age resolution was used; Desktop's bundled-helper
qualification was not rerun.

A uniquely named, mode-0700 directory under `/private/tmp` contained a `git archive`
copy of the exact baseline, separate source/target HOMEs, per-operation private
directories, generated keys, Bundles, Git fixtures and the temporary SSH server.
All 295 tracked files in the runtime copy matched the development checkout before
documentation edits. The production runtime was neither patched nor mocked.

Each Core process received an explicit environment: disposable `HOME`, private
`TMPDIR`, controlled `PATH`, `GIT_CONFIG_NOSYSTEM=1`, `GIT_CONFIG_GLOBAL=/dev/null`,
and an owned `BS_INSTALL_DIR`. The already-configured test launcher pointed into
the disposable runtime. Capture/Restore generated state and logs belonged to that
copy. The runtime's journal implementations use the supplied Core HOME.

A macOS sandbox additionally denied reads of the real user's HOME, direct writes
outside the allowlist, execution of `sudo`, and outbound non-loopback IP traffic.
The write allowlist covered the owned root, PTYs and inspected Core/macOS temporary
file patterns. Unix IPC remained available. The trusted read-only `/bin/ps` alone
ran outside the sandbox: its setuid executable is otherwise rejected by macOS,
and production Core requires it for process ownership observation. No process
supervision checks were bypassed. Native `mktemp` storage was explicitly allowed
after its real location was observed; initial sandbox setup errors did not modify
production code or user targets.

Active probes confirmed denial of real HOME directory reads, writes outside the
allowlist and external IP connections. Production temporary-directory inventories
were checked for leftovers. Cleanup never swept unrelated temporary files.

**Native Desktop: BLOCKED / NOT RUN.** No dedicated test account or previously
proven native boundary was established. `CoreLocation` defaults to
`NSHomeDirectory()`; setting a temporary environment HOME does not establish native
isolation. No account, system SSH setting, Remote Login service, global Git
configuration or administrator authorization was changed. No fixture screenshots
were substituted for execution.

## 2. Capture

**PASS for the isolated SSH-only captures.** Sources contained two valid Host
profiles, explicit IdentityFile references and two independent generated Ed25519
pairs, one password-protected. A separate source represented portable custom paths.
The Git source added a third supported Host and disposable repository requirements.

Production `capture_prepare` enumerated and selected the sources;
`capture_execute` requested `ssh_key_unlock` and `bundle_encrypt` over the private
channel and published real `.mbt` files. `bundle.validate_archive` verified the
production format and checksums. Later secure inventory and comparisons decrypted
and authenticated the complete `secure.age` package. Checksums do not authenticate
the ordinary Bundle payload; the encrypted component has the separate authenticated
boundary.

Both SSH-only positive Bundles contained exactly:

```text
blueprint.conf
generated/ssh/config.snapshot
secure.age
```

Only SSH Configuration and explicitly selected identities were enabled. No
application, Homebrew, macOS-settings or unrelated configuration payload was in
these Bundles. Source SSH file bytes and metadata remained unchanged. Capture
created private staging, logs and the requested Bundle.

**Observed scope limitation:** the initial Capture with optional provider tools
available in PATH retained a 16-row App Store inventory and an empty VS Code
inventory, with completeness digests, although those categories were unselected.
It therefore failed this task's strict no-unrelated-payload expectation. This follows
the existing `bundle.completeness_files()` behavior used for comparison provenance;
it is not evidence that those applications were selected for restoration.
Read-only provider commands also created caches/logs in the disposable source HOME.
Their contents and identifiers are not published here. That private Bundle was
deleted during cleanup. The subsequent minimum-tool PATH exposed real age/OpenSSH
without optional provider executables and produced the exact SSH-only payload above.
No product filtering rule was changed.

## 3. Selection and Preview

**PASS.** `bundle_inspect`, authenticated `secure_restore_inventory`, ordinary
`restore_prepare` and authenticated `secure_restore_compare` exercised:

| Scope | Observed result | Target mutation |
|---|---|---|
| Configuration only, secure transfer off | Configuration planned independently; missing references remain advisory | None |
| One selected protected key, Configuration off | Exact v2 subset; `import_required` | None |
| Both keys at default locations | Configuration create plus pending secure import | None |
| Both keys in a safe, existing custom directory | Destination-bound comparison; missing original references remain unresolved | None |
| Explicitly approved reference corrections | Private review and approvals make the corrected configuration ready | None |
| Saved portable custom paths | Matching destination correspondence without a correction approval | None |

Whole-HOME snapshots included file hashes, modes, ownership, inodes, sizes, mtime
and ctime. They were equal before/after each successful Preview/Compare.
Comparisons requested only `bundle_unlock`, never key unlock or import consent.
Ordinary output retained `remote_authentication: not_assessed`.

`ssh_restore_review` used the production private reference file; approved changes
were sent in the bounded private approval envelope. Custom mappings used version 2,
the complete authenticated identity set and explicit selected flags. Paths and
identity associations were not placed in ordinary request parameters or this report.

## 4. Rebuild and ordering

**PASS for default, saved-custom and explicitly corrected custom imports.** Each
full Rebuild authenticated the Bundle's encrypted component, separately unlocked
the protected key and received explicit `import_confirmation`. Both pairs were
restored without overwriting unrelated files. Custom directories already existed
and retained their ownership and permissions. Corrected IdentityFile references pointed
to the approved custom directory; no duplicate pair appeared at the default path.

**PASS for selected-key-only Execute.** One protected pair was imported and verified;
the excluded key and SSH configuration remained absent. This exercised actual
selection behavior beyond Preview.

For each full successful operation, ordinary events recorded:

```text
sequence 4–5   local generated-configuration publication
sequence 6–14  secure import
sequence 15    Bootstrap begins
sequence 17    SSH Configuration creation succeeds
sequence 32    Bootstrap completes
```

This proves import preceded target SSH Configuration publication in the executed
scenarios. The earlier `publication` phase concerns Macseed's local generated
configuration, not the target SSH config. Successful import → config → SSH clone
ordering remains **NOT RUN**, because no positive SSH clone could complete safely.

Filesystem changes were confined to owned fixture state: selected target files,
runtime generated configuration, operation staging, logs and journals.

## 5. Independent Verification

**PASS.** Independent filesystem checks established exact private/public byte
equality with generated source pairs, regular single-link files, current-user
ownership, private mode `0600`, public mode `0644` and default `.ssh` mode `0700`.
Native `ssh-keygen -lf` independently matched public fingerprints. Configuration
content was compared semantically using the supported parser, and explicit
correction destinations were checked in the actual target file.

Production Global Verification for each full positive Rebuild reported:

```json
{"status":"complete","verdict":"selected_requirements_verified",
 "selected_count":3,"verified_count":3,"mismatch_count":0,
 "unverified_count":0,"unresolved_count":0,"error_count":0}
```

The key-only subset reported one verified requirement. This combines importer
cryptographic evidence with independent saved-file checks; Check alone was never
treated as proof of private-key usability or remote authentication.

## 6. Secure Check

**PASS at the Core evidence boundary for default and saved custom paths.**
`environment_compare` plus `secure_check_compare` ran against the same Bundle used
by the respective Rebuild. Each produced one aggregate SSH Configuration `config`
match and exactly two per-identity secure matches. No individual Host matching rows
or duplicate identity rows appeared. The secure result reported
`ssh_reference_coverage: resolved`, including the password-protected matching key.
Only the Bundle passphrase was requested.

The explicit `secure_check_inventory` operation was also authenticated against the
restored default target. Its complete identity mapping agreed with the earlier
inventory, and the target HOME remained unchanged.

Core's ordinary comparison intentionally remained `incomplete` with one matching
configuration and one unresolved reference scope before the secure result was
combined. The private secure result resolved that scope without adding a fabricated
Host match. The evidence supports three selected matches after the documented
client composition. **The actual native combined headline and counts were NOT RUN**;
this report does not present a calculated total as an observed Desktop result.

For explicitly corrected paths checked against the original Bundle, ordinary Check
reported one differing configuration plus unresolved reference coverage, while
both selected custom-location pairs matched. That is a real saved-state difference:
the original Bundle retains the old paths, and Check does not reuse Restore approvals.
The saved-custom-path positive scenario separately demonstrated resolved coverage.

All successful Checks preserved complete target HOME snapshots and Bundle bytes.
Their terminal evidence stated `read_only: true`, `publication_occurred: false` and
`target_mutation_may_have_started: false`. Temporary decryption/staging was cleaned.

## 7. Repeated no-op

**PASS for default and saved portable custom paths.** Repeated Prepare/secure
Compare returned `all_match`; independent file checks and repeated ordinary/secure
Check retained the same results. Deliberately invoking Execute when nothing remained
to do returned exit `2`, `no_executable_work`, before publication, secrets or target
mutation. This is the documented no-work gate, not a failed import. Whole target
HOME snapshots remained equal. There was no second Apply or new Global Verification
receipt; repeated read-only comparison and independent checks supplied the evidence.

**FAIL for repeated Prepare after an approved path correction.** Initial corrected
Rebuild and Verification succeeded, but the next Prepare with the same Bundle,
selection, mapping and approvals produced:

```text
config row:      satisfied
publication:     blocked / ssh_configuration_not_ready
readiness.ready: false
ssh_resolution:  action=blocked, ready=false
```

The read-only focused reproduction found that the approved effective snapshot's
merge plan was `noop`, while production `restore_resolution.inspect()` raised
`original_target_conflict`. The cause is the original-profile conformity guard in
`modules/ssh/restore_resolution.py`: it checks the unchanged saved Host before
planning the corrected effective snapshot. A previously applied correction therefore
looks like a conflicting original profile. No files changed during reproduction.

This is a convergence gap, not evidence of unsafe publication. The guard protects
existing differing Hosts and was not weakened or bypassed. No production fix was
attempted, and joint qualification cannot be marked complete.

## 8. Essential negative scenarios

Each case used a separate disposable state, except authenticated Check cancellation
which intentionally used an already verified disposable target and prior private
result. There was no fault injection into user files.

| Scenario | Status | Expected and observed evidence | Target mutation |
|---|---|---|---|
| Wrong Bundle passphrase | PASS | Three unlock challenges, exit 2, `secure_unlock_rejected`; no usable Check result | None |
| Cancelled Bundle unlock | PASS | Exit 130, `secure_cancelled`; previous private result bytes preserved | None |
| Cancelled import consent | PASS | Protected-key validation followed by cancellation; no pair/config imported | None; local runtime configuration publication had occurred |
| Missing selected source key | PASS | Capture rejected the retained selection with `invalid_secure_selection`; no Bundle published | None |
| Missing selected target key / reference | PASS | One matching pair, one missing pair; coverage `unresolved` | None |
| Existing conflicting destination | PASS | Compare `conflict`; Execute `secure_target_conflict`; entire selected import blocked | None |
| Matching pair at a different mapped path | PASS | Bytes matched, but reference coverage remained `unresolved`, even with another matching copy at the configured path | None |
| Unsafe symlink destination | PASS | Check returned `unverified`, never matching/missing; Prepare rejected with `secure_target_conflict` | None |
| Cancel Change Location preserving UI results | BLOCKED / NOT RUN | Requires isolated native UI; preserving a prior Core private result does not prove sheet cancellation behavior | No native operation |
| Unqualified SSH-dependent clone | PASS | Actual Execute skipped clone with `git_ssh_identity_unresolved`; repository remained absent | Only independent selected config/folder work |

No destructive process termination was used. The owned test daemon was stopped
normally. Broader recovery/fault-injection qualification was not started.

## 9. Git transport and independent work

**Positive Git-over-SSH E2E: BLOCKED.** A real disposable seed and bare remote were
created with repository-local Git settings; local fixture clones used native Git.
An ephemeral nonprivileged `sshd` configuration passed `sshd -t` and the owned daemon
started on loopback only. It used a generated host key and generated authorized key,
disabled password/PAM authentication and forwarding, and forced read-only
`git-upload-pack` for the owned remote.

The standalone SSH clone attempt exited `128` during key exchange. The server
reported `sandbox initialization failed: Operation not permitted` and
`ssh_sandbox_child: sandbox_init: Operation not permitted [preauth]`.
Running the daemon outside isolation or changing system SSH was not attempted.

Production selected-SSH Preview and Execute independently hit `internet_required`:
the current readiness check requires an external Internet probe even for this
loopback clone. Execute stopped before publication, import or target mutation.
Neither the standalone transport attempt nor these plans count as a successful
production SSH clone.

Read-only native `ssh -G` additionally confirmed that its default known-hosts files
resolve through the account HOME. This matters for any future safe clone setup;
temporary environment HOME alone is insufficient for those native defaults.

For the negative production Execute, SSH Configuration and an independent folder
were restored, but the unqualified repository was skipped. Its process exited `0`
while Verification correctly reported `differences_detected`, 2 verified and
1 mismatch out of 3 selected requirements. No clone success was inferred from exit 0.

A `file://` source origin was excluded by the current Capture topology contract;
this was not counted as supported local-origin E2E. A separate, uncontacted HTTPS
requirement used a reserved `.invalid` domain. The production dependency assessor
left HTTPS planned while blocking the SSH requirement; the later ordinary Preview
network-readiness overlay marked both `internet_required`. **Dependency separation:
PASS. Actual independent HTTPS clone: NOT RUN** because network access was unavailable.
No real server, personal GitHub repository or production remote was contacted.

## 10. Native, hosted and remaining gates

| Boundary | Qualification from this run |
|---|---|
| Production Core application CLI on this Mac | Bounded PASS cases above; correction-repeat FAIL |
| Legacy interactive terminal Capture/Restore | NOT RUN; structured production Core was the execution interface |
| Native Desktop mutation / full joint flow | BLOCKED / NOT RUN: no proven native isolation |
| Actual Desktop headline/count composition and Change Location cancellation | NOT RUN |
| Successful SSH transport and import → configuration → clone | BLOCKED |
| Hosted CI, packaged app, clean Mac / Stage 17 | NOT RUN |

Existing Protocol, Secure Check, PresentationTests, EnvironmentStatusTests and
RestoreTests PASS was supplied as prior checkpoint context, not re-executed or
independently refreshed here. No broad regression, full suite, build, lint or CI run
was started. No local result was promoted to hosted or visual acceptance.

## 11. Operation and evidence ledger

Every production request used the unchanged entrypoint from the disposable runtime:

```text
bash modules/core/application-interface/core.sh [--secure-fd <inherited-socket-fd>]
```

Stdin carried Protocol V1 JSON with a unique operation ID. Secrets travelled only
through challenge-bound private socket frames; test key generation used a hidden
PTY, not password argv/environment. The following are the exact operation families
and parameter contracts used; private paths and identity relationships are omitted.

| Operation | Parameters / recorded scopes |
|---|---|
| `capture_prepare` | `selection: null`, then explicit categories/items/secure identities |
| `capture_execute` | Same selection, owned `.mbt` destination, fresh `expected_prepared_capture_id` |
| `bundle_inspect` | Saved Bundle `path` |
| `secure_restore_inventory` | Saved Bundle `path`, private FD |
| `restore_prepare` | `path`, `disabled_groups: []`, `include_secure`, optional independent `selection`, private destination/approval flags |
| `secure_restore_compare` | Same scope plus `expected_prepared_plan_id`, private FD |
| `ssh_restore_review` | `path`, ordinary SSH `selection`; private review response |
| `restore_execute` | Same prepared scope, exact plan ID and bound `secure_comparison` when supplied; separate consent |
| `environment_compare` | `bundle_path` |
| `secure_check_inventory` | `path`, exact `expected_bundle_id`, private FD; authenticated inventory only |
| `secure_check_compare` | `path`, exact `expected_bundle_id`, `custom_destinations: true`, private selected mapping and FD |

Principal positive operation IDs were `capture-*`, `default-initial-*`,
`default-execute`, `default-check-*`, `default-repeat-*`, `custom-approved-*`,
`custom-execute`, `custom-check-*`, `portable-capture-*`, `portable-initial-*`,
`portable-execute`, `portable-check-*`, `portable-repeat-*` and `subset-execute*`.
Negative IDs were `negative-password-*`, `negative-consent-*`, `negative-conflict-*`,
`negative-check-*`, `negative-prepare-symlink`, `negative-selected-source-missing`
and `git-unqualified-*`. Git readiness was recorded by `git-selected-prepare`,
`git-readiness-execute` and `git-independent-*`.

Independent evidence consisted of actual file bytes/metadata, native public-key
fingerprints, production verification records, authenticated private Check receipts,
typed terminal events, source inspection and the bounded no-op reproduction.
The 44 runtime log files were scanned for the generated passwords and private-key
markers; none were found. The sanitized results above are retained; raw private
requests, identity inventories and logs are not published.

## 12. Preservation and cleanup

Before/after metadata snapshots confirmed no change to the real `.ssh`, real global
Git config, existing Macseed state/journals, development generated configuration,
Blueprint, logs or the protected `NativeSidebarRepro.swift`. The protected file's
SHA-256 was also unchanged. Existing Bundles and repositories were not workflow
inputs or mutation targets; the production copy's tracked files remained identical.

The real preferences-directory metadata snapshot changed in 16 entries during the
active user session. No preferences Apply was executed, and the sandbox denied
direct real-HOME writes; this run did not establish attribution for those changes.
It therefore does not claim byte-for-byte preservation of the entire live preferences
directory or whole-machine quiescence.

Before final cleanup, the secure temporary-directory set matched its baseline;
there were no remaining Core observation/items/clone/stop temporary directories.
The owned `sshd` had stopped; a final process-table check found no owned daemon.
**Cleanup PASS:** the uniquely owned test root was deleted after validating its
owner, mode, canonical path and creation record. Generated test keys, passwords,
all test Bundles, source/target HOMEs, bare repositories, server configuration,
runtime copy, driver and raw evidence were removed. The pre-existing secure
temporary-directory set remained unchanged. No unrelated resource was deleted.

## 13. Final Git state

Only this report, `ROADMAP.md` and `TODO.md` are documentation changes.
`desktop/Macseed/Tests/NativeSidebarRepro.swift` remains unchanged and untracked.
Diff/link review, report privacy checks and `git diff --check` passed. HEAD remains
the stated baseline; the index is unchanged and empty of staged changes.

```text
 M ROADMAP.md
 M TODO.md
?? desktop/Macseed/Tests/NativeSidebarRepro.swift
?? docs/SSH-E2E-QUALIFICATION-2026-11-10.md
```

No staging, commit, push, branch switch or remote Git operation was performed.

## 14. Approved-correction no-op follow-up

**LOCALLY VERIFIED PASS — fix tested against baseline `821ba853`, 10 November 2026.**
This supersedes only the approved-correction repeat failure in section 7. Sections
1–13 remain the original evidence; the complete joint qualification stays open.

### Change and preserved boundaries

`modules/ssh/restore_resolution.py::inspect()` now obtains the safely inspected
effective configuration's merge action before applying the original-Host conflict
guard. Only `conflicting_profiles` with effective action `noop` is exempted.
Actual configuration mutation retains the original conflict guard; a different
unapproved selected Host is still rejected by the effective merge planner.
Unsafe/unsupported targets, uncertain publication, explicit approvals, Bundle
binding, target freshness and dependency qualification remain enforced.

The only production change is this local ordering/condition adjustment. SSH Import,
Secure Check, Git execution, UI and their contracts were not changed. Two tests
that encoded the erroneous repeat failure were synchronized, a focused safety case
was added, and the existing protected-key correction case now checks repetition.

### Focused regression evidence

Both commands ran through the canonical runner, sequentially, with approved native
process observation. Output directories were private disposable evidence storage:

```bash
./scripts/test.sh --suite scripts/test-restore-selection.py \
  --case test_explicit_local_approval_and_original_conflict \
  --case test_approved_noop_rejects_unsafe_stale_and_unresolved_targets \
  --case test_v2_private_review_local_approval_execute_and_stale \
  --output /private/tmp/macseed-ssh-noop-fix-_mig1rme/tests-selection
./scripts/test.sh --suite scripts/test-secure-restore.py \
  --case test_v2_secure_custom_correction_requires_approval \
  --output /private/tmp/macseed-ssh-noop-fix-_mig1rme/tests-secure
```

| Focused case | Result | Evidence |
|---|---|---|
| Explicit local approval and original conflict | PASS, 0.092 s | Approved Apply then ready/no-op and unchanged state; absent approval, mutation needing the original guard, and a different unapproved Host remain rejected |
| Approved no-op safety/freshness | PASS, 0.088 s | Unsafe mode, symlink, hardlink, unsupported Include, pending publication, stale Bundle approval, absent consent and same-byte target replacement remain rejected; missing key remains unqualified |
| Core private approval Execute and stale plan | PASS, 16.712 s | Successful Restore then ready/no-op; subsequent target edit rejects Execute as `stale_plan` before publication or target mutation |
| Protected secure custom correction | PASS, 27.229 s | Successful protected import then environment-ready/no-op Prepare; fresh authenticated Compare returns `all_match`, resolution ready, with unchanged target |

**4 PASS, 0 FAIL, 0 ERROR, 0 SKIP.** Runner elapsed times were 17.395 s and
27.686 s. Python compilation of the three changed files and `git diff --check`
passed. No Bash source changed, so shell syntax checks were not needed.

### Single-scenario production Core reproduction

The previous root had already been deleted. A fresh disposable root recreated the
same isolation design from section 1, with all IP networking denied. All 295 tracked
runtime files were compared against `821ba853`; only `restore_resolution.py` differed,
using the exact working-tree fix. Real tools and production Core were used without
mocks, helper substitutions or process-supervision bypasses.

Production Capture prepared one fresh SSH-only Bundle solely as this scenario's
fixture: two selected pairs, one protected, and two Host profiles. Its validated
payload was exactly `blueprint.conf`, `generated/ssh/config.snapshot`, `secure.age`.
Both identities were mapped to an existing safe custom directory and both path
corrections were explicitly approved through the private envelope.

| Operation | Observed result |
|---|---|
| Initial Prepare and authenticated Compare | Ready; `import_required`; Preview/Compare preserved the target |
| Restore Execute | Exit 0; Bundle unlock, key unlock and explicit import consent; Verification `selected_requirements_verified`, 3/3, zero mismatch/unresolved/error |
| Repeated Prepare, same Bundle/selection/mapping/approvals | Exit 0; `readiness.ready=true`; configuration `satisfied`; `ssh_resolution.action=noop`; zero blocked rows |
| Further read-only Prepare on that same restored target | Same ready/no-op result; complete target snapshot unchanged |

Restored private/public bytes matched the source; modes were 0600/0644, ownership
was correct, approved references were present and default-location duplicates were
absent. Read-only repeat snapshots covered hashes, mode, owner/group, inode, size,
mtime and ctime; source SSH state and Bundle bytes were also unchanged during repeat.

A protected key still yields `ssh_resolution.pending=true`, `ready=false` before
fresh authenticated comparison. The ordinary plan retains `pending_unlock` and
`has_planned_changes=true` for the secure set; this does not mean the configuration
needs rewriting. The focused protected-key case above separately proved the fresh
`all_match` transition. Repeated secure Compare and repeated Execute were **NOT RUN**
in this production reproduction; no second Restore was performed.

Two disposable-driver issues were corrected without production changes: terminal
`completed` events need not contain `data`, and the driver initially expected global
`has_planned_changes=false` before secure unlock. The latter assertion stopped after
the successful repeated Prepare; a final read-only Prepare verified preservation.
Neither driver issue was a product failure or an additional E2E scenario.

### Evidence reuse, preservation and scope

The unchanged import, Secure Check, Git and UI implementations retain their prior
bounded evidence recorded in sections 2–10 at `821ba853`; this follow-up refreshes
only the changed approved-correction behavior. Prior native and hosted gaps remain
open. Full E2E, full regression/feature suites, builds, lint, SSH clones, Secure Check,
UI and CI were **NOT RUN** in this follow-up. Focused positive, conflict and
fail-closed tests plus the exact failing Core scenario cover this local change.

Before/after metadata inventories matched for real `.ssh`, global Git config,
Macseed state, development generated configuration, Blueprint and logs.
`NativeSidebarRepro.swift` retained its SHA-256. The original report text is preserved
verbatim between the current-outcome banner and this addendum; Roadmap/TODO own
the current gate status and execution order. Ordinary reproduction output was checked
for the generated secrets while they were in memory; eight runtime logs contained
no private-key marker. This is not a new whole-machine or native qualification.

Only the three code/test files, this report and the existing Roadmap/TODO changes
belong to the checkpoint. No staging, commit, push, branch switch or CI operation
was performed. Temporary cleanup and final review are recorded below.

**Final review and cleanup: PASS.** The owned mode-0700 root was removed after
checking its recorded path, owner, mode and preservation evidence. Generated test
keys, Bundle, runtime, private controls and raw test evidence were deleted. No owned
Core process remained; the inspected Core/secure temporary-directory prefixes were
empty. Documentation paths, the follow-up anchor, Python syntax and whitespace
checks passed. At the end of that qualification run, the branch was `develop`, HEAD
was `821ba853`, and the index was unchanged with no staged changes. Work stopped
for review before publication.

## 15. Remaining Core Git-over-SSH qualification

**BLOCKED — bounded follow-up on 10 November 2026, baseline `821ba853` plus the
accepted no-op fix.** No readiness, SSH Import, Git execution or UI code changed.
The six-file accepted checkpoint was preserved; the original SSH regression cases
were not rerun. Native Desktop and hosted CI were not executed.

### Readiness root cause and change boundary

The failure is an overbroad Internet prerequisite for a local operation, separate
from SSH dependency qualification and the server's sandbox failure:

1. `modules/core/application-interface/core.py::preview()` reduces planned topology
   clones to `workspace_clone: bool` and passes that flag to `prepared_requirements()`.
   Prepare, Execute's `readiness()` and the later Bootstrap environment carry
   `MACSEED_WORKSPACE_CLONE_REQUIRED`; the prerequisite boundary does not carry a
   verified effective network destination.
2. `bootstrap.sh::bootstrap_application_readiness_timed()` marks every required
   topology clone as `needs_network=true`. Its legacy repository path also treats
   every absent repository as requiring Internet access.
3. `modules/core/preflight/preflight.sh::check_internet()` probes `https://github.com`
   and `https://brew.sh`. Failure becomes `internet_required` in the domain readiness
   report and in Execute before publication. The isolated environment intentionally
   denies those non-loopback probes.

The supported origin parser admits the fixture's ordinary `ssh://user@host:port/path`
form. Production `git_dependencies.assess()` independently returned
`git_ssh_local_ready` for its generated key and explicitly approved absolute
IdentityFile. Thus this was neither an unsupported URL nor an unresolved key.

**No narrowly local readiness fix was applied.** Dropping the prerequisite or
exempting a loopback-looking URL would be unsound: an allowed SSH `HostName` can
redirect that URL to a non-loopback destination, and ordinary remote/HTTPS clones
must retain their checks. A correct change needs a private, freshness-bound
classification of the actual effective endpoint across the legacy/topology paths,
Prepare, Execute and Bootstrap, including pending configuration and mixed remote
scopes. That changes the existing readiness contract beyond a local predicate;
the task explicitly required reporting such a broader design instead of expanding
it. No new environment switch, URL form, transport substitution or test-only bypass
was introduced. This readiness limitation remains open, not fixed or qualified.

### Actual isolated transport and production Core attempt

A fresh mode-0700 owned root contained a baseline runtime, a disposable native Git
seed/bare remote, separate source/target HOME directories and generated Ed25519
client/host keys. The Git probe used the accepted SSH no-op fix as its only runtime
code overlay. No real key, repository, application inventory or server was used.

The sandbox denied real-HOME reads, writes outside the owned/inspected temporary
allowlist, `sudo`, and non-loopback IP traffic. Active denial probes passed. Native
`sshd` bound only to `127.0.0.1` on an ephemeral unprivileged port, with one generated
authorized key, public-key-only authentication, no forwarding and a forced native
`git-upload-pack` restricted to the disposable bare remote. Standalone native Git
used explicit private known-hosts and IdentityFile paths with strict host checking.
`sshd -t` succeeded; no system Remote Login or system daemon configuration changed.

| Observation | Result |
|---|---|
| Native Git-over-SSH transport | BLOCKED; Git exited nonzero during key exchange; server logged `sandbox initialization failed: Operation not permitted` and `ssh_sandbox_child: sandbox_init: Operation not permitted [preauth]` |
| Production local key/configuration qualification | PASS, `git_ssh_local_ready`; explicit approval supplied through the operation-bound private envelope |
| Production `restore_prepare` | Exit 0; environment readiness false with `git-repositories / internet_required` |
| Production `restore_execute` with its fresh plan | Exit 2, `internet_required`; `publication_occurred=false`, `target_mutation_may_have_started=false` |
| Repeated Prepare of the same blocked case | Same blocker; complete target snapshot unchanged |
| Actual production clone, checked-out state, independent Verify and repeat/no-op | NOT RUN beyond the readiness gate; repository remained absent; no successful-clone claim |

The client key/configuration already existed in this disposable target; no import
was needed or performed. There is no new import → configuration → successful clone
ordering evidence. Existing bounded import/configuration ordering evidence remains
in section 4. A repeated blocked Prepare is not convergence/no-op qualification.

The owned daemon was stopped normally after the transport failure. No unrestricted
server, security-control change, production network connection or unsafe workaround
was attempted. The earlier native account-HOME caveat remains relevant to any later
client isolation design; temporary environment HOME alone does not qualify it.

Fixture preparation required the platform's `localhost` sandbox address syntax,
canonical SSH snapshot serialization and explicit approval for the absolute test
IdentityFile. An initial unapproved fixture correctly produced
`git_ssh_identity_unresolved`; it was not counted as the qualified readiness case.
These were disposable setup corrections, not product repairs. The execution
approval review initially retained the preceding documentation-only restriction;
the user supplied direct chat authorization before any daemon or Core workflow ran.

## 16. Capture unselected-inventory privacy review

**AUDIT COMPLETE; bounded correction LOCALLY VERIFIED.** The remaining question is
product disclosure for full inventories retained inside partially selected domains.
No new privacy setting, consent policy or UI change was introduced.

### What was retained and why

`modules/bundle/bundle.py::completeness_files()` previously retained every observed
complete pair, regardless of whether that domain had selected requirements:

| Inventory in the ordinary Bundle | Data retained | Associated marker |
|---|---|---|
| `generated/brew-casks.conf` | Full installed Cask tokens admitted by Discovery | `generated/provenance/homebrew-casks.sha256` |
| `generated/appstore.conf` | Numeric application IDs and application names; Discovery removes the trailing version | `generated/provenance/app-store.sha256` |
| `generated/vscode-extensions.conf` | Full `publisher.extension` identifiers | `generated/provenance/vscode-extensions.sha256` |

Markers contain `complete <sha256>` for exact inventory bytes, not encryption or
source authentication. These production exporters do not add account identifiers,
usernames, installation paths, credentials or timestamps to these lists. App names
and extension/Cask choices can nevertheless reveal personal interests, work tools
or an organization's extensions. Empty complete inventories were retained too.
Formulae have no completeness marker because their observation is only the
installed-on-request subset. Other selected Bundle configuration has its own
privacy contract; this audit is not a claim that the entire Bundle lacks personal data.

Retention was intentional and documented in Configuration: it supplies the full
source baseline for comparison, independently of the narrower Restore selection.
`selected_payload()` preserves a full list when its marker is present;
`comparison_extra()` validates completeness and enumerates the target before
reporting items absent from the whole source inventory. Narrowing that baseline
would create false extras. Removing its marker would make extras unavailable;
keeping the old digest with narrowed bytes would be invalid. None of those changes
was made.

The key distinction is that `comparison_extra()` first checks selected Blueprint
scope. For an entirely unselected category it returns `not_applicable` /
`category_excluded` without consuming the inventory or probing that target provider.
Its retained data is therefore unnecessary for current Check. The original broad
retention rule was compatible with V1 but collected more plaintext than this scope
needed. This justified the bounded writer correction below.

### Capture UI disclosure and product decision

Source inspection found the current confirmation message in
`CaptureModel.confirmationPrivacyMessage()`: saved settings are not encrypted,
with separate SSH encryption wording when applicable. `CaptureView` renders that
message above the selection-derived “Included in this capture” list. This explains
encryption, but does not explicitly disclose retained inventories of unchecked
items. No native rendering or visual acceptance is claimed in this review.

**Recommendation for product approval:** explain the full comparison baseline for
partially selected application categories in the existing Save confirmation,
distinguishing retained inventory from items eligible for restoration. Retain the
current completeness/extras semantics. Any further consent or data-minimization
policy needs an explicit product decision; this task neither invents nor implements
one. Previously saved Bundles may still contain wholly excluded inventories and
are not silently rewritten.

### Minimal correction and compatibility

`completeness_files()` now receives the effective Blueprint and returns a valid
inventory/marker pair only when its domain has at least one selected requirement.
It still reads and validates observed marker/file safety and digest **before**
excluding a pair, so exclusion cannot conceal unsafe or stale provenance. The
selection ceiling, partial-selection baseline, archive format/version, reader,
comparison logic and source observation remain unchanged.

The owner contract in [Configuration](toolkit/CONFIGURATION.md#other-application-generated-inputs)
and the proportional Unreleased changelog entry describe this writer-only change.
No Bash production code changed. There is no readiness or Capture UI patch.

A separate production Core Capture fixture used synthetic `mas`/`code` executables
inside the same sandbox, with two invented app records and two invented extension
IDs. The optional-provider outputs were fixtures; the production Capture, Discovery,
selection, packing and validation paths were not patched or mocked. No personal
application inventory was queried. Only SSH Configuration was selected; no SSH
identities, restore workflow or Secure Check was run in this fixture.

| Production Capture fixture | Validated payload, excluding `manifest.json` |
|---|---|
| Before correction | `blueprint.conf`, `generated/ssh/config.snapshot`, both App Store/VS Code inventories and their two digest markers |
| After correction | Exactly `blueprint.conf`, `generated/ssh/config.snapshot` |

Both used real `capture_prepare` → `capture_execute`, exit 0. New output passed the
reader from baseline `821ba853`; the current reader accepted the old Bundle with
its retained inventories unchanged. Focused Bundle cases also covered all three
domains, selected subsets and old V1 unpacking. No Bundle format migration is needed.

### Focused validation and evidence reuse

Canonical runners executed sequentially; no broad suite was run:

```bash
./scripts/test.sh --suite scripts/test-bootstrap-bundle.py \
  --case test_unselected_complete_inventories_omitted_and_legacy_bundle_readable \
  --case test_partially_selected_complete_inventories_remain_full \
  --case test_unselected_completeness_does_not_hide_unsafe_or_stale_input \
  --case test_complete_inventory_keeps_excluded_items_for_comparison \
  --case test_invalid_completeness_marker_rejected \
  --output /private/tmp/macseed-ssh-core-qualification-002px9fn/tests-bundle
./scripts/test.sh --suite scripts/test-capture-api.py \
  --case test_unselected_application_inventories_not_saved \
  --case test_partial_app_store_capture_retains_comparison_inventory \
  --output /private/tmp/macseed-ssh-core-qualification-002px9fn/tests-capture
./scripts/test.sh --suite scripts/test-environment-compare.py \
  --case test_bundle_reference_selection_and_read_only \
  --case test_extra_provenance \
  --output /private/tmp/macseed-ssh-core-qualification-002px9fn/tests-comparison
```

| Focused scope | Result | Runner time |
|---|---|---:|
| Bundle omission, partial baseline, legacy V1 and unsafe/stale provenance | 5 PASS | 0.456 s |
| Capture API entirely unselected and partially selected inventories | 2 PASS | 32.891 s |
| Existing comparison selection/read-only and extras-provenance cases | 2 PASS | 26.562 s |

**9 PASS, 0 FAIL, 0 ERROR, 0 SKIP.** Unsafe symlink and stale digest cases still reject
publication. Existing comparison assertions were not edited or weakened. No Bash
syntax sweep was needed because no Bash source changed.

The four no-op cases and exact production reproduction in section 14 are reused,
not rerun: their production SSH code/tests were unchanged, their fixtures carry no
completeness inventories, and the original isolated SSH-only Bundles contained no
such inventories. The unchanged import, Secure Check and Git execution boundaries
retain only their prior documented evidence. Historical native, successful-clone
and hosted gaps are not promoted to PASS.

Full Protocol, RestoreTests, PresentationTests, EnvironmentStatusTests, Secure Check
scenarios, complete SSH Capture/Rebuild E2E, builds, broad regression and CI were
**NOT RUN**. Native Desktop SSH remains deferred to the one application-wide gate
after functional development, using a separately isolated macOS test account.
The earlier 16 live preference-metadata changes remain unattributed historical
evidence; no preference mutation, new preference audit or speculative fix was made.

### Scope and handoff

This follow-up changes `modules/bundle/bundle.py`, its focused tests in
`scripts/test-bootstrap-bundle.py` and `scripts/test-capture-api.py`, the owning
`docs/toolkit/CONFIGURATION.md`, `CHANGELOG.md`, and the existing report/Roadmap/TODO.
The accepted SSH production fix and its two test files remain byte-for-byte intact.
The complete checkpoint patch against `821ba853` includes these eleven files:

```text
CHANGELOG.md
ROADMAP.md
TODO.md
docs/SSH-E2E-QUALIFICATION-2026-11-10.md
docs/toolkit/CONFIGURATION.md
modules/bundle/bundle.py
modules/ssh/restore_resolution.py
scripts/test-bootstrap-bundle.py
scripts/test-capture-api.py
scripts/test-restore-selection.py
scripts/test-secure-restore.py
```

`desktop/Macseed/Tests/NativeSidebarRepro.swift` is excluded, unchanged and untracked.
No staging, commit, push or CI operation was performed during this follow-up.
Final preservation, documentation checks and cleanup are recorded below.

**Final preservation and cleanup: PASS.** Metadata inventories matched for real
SSH state, global Git config, Macseed state, development generated configuration,
Blueprint and logs. Accepted SSH code/tests and the protected Swift file retained
their SHA-256 values; report sections 1–14 remained verbatim. No owned daemon/Core
process or inspected Core/secure temporary prefix remained. After validating its
recorded path, owner and mode, the owned root was deleted, including generated
keys, Bundles, private controls, runtime and raw evidence. No unrelated resource
was removed. Documentation validation checked 99 local links and 80 anchors;
`git diff --check` and the untracked report whitespace check passed. External URLs
were not network-checked. A complete checkpoint patch is supplied separately at
handoff; it contains no fixture credentials or protected Swift-file change.

At this handoff, branch was `develop`, HEAD was
`821ba853183ec06f455fe90f42d43d7d3c6e1f47`, and the index had no staged changes:

```text
 M CHANGELOG.md
 M ROADMAP.md
 M TODO.md
 M docs/toolkit/CONFIGURATION.md
 M modules/bundle/bundle.py
 M modules/ssh/restore_resolution.py
 M scripts/test-bootstrap-bundle.py
 M scripts/test-capture-api.py
 M scripts/test-restore-selection.py
 M scripts/test-secure-restore.py
?? desktop/Macseed/Tests/NativeSidebarRepro.swift
?? docs/SSH-E2E-QUALIFICATION-2026-11-10.md
```
