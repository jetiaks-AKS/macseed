# Contributing

Develop on `develop`; `main` contains stable releases. Before editing, inspect
the branch, working tree and relevant implementation. Preserve unrelated local
changes and existing contracts. Keep commits limited to one logical task, using
English `type: short description` with `feat`, `fix`, `refactor`, `docs`, `style`,
`chore` or `release`. Never commit generated state, Blueprint, logs, exports,
`.env` or temporary files.

## Architecture and change principles

Macseed Core owns Discovery, selection, Preview, Apply, Verification, Comparison,
Bundle and Secure Migration. The CLI is implemented; Desktop is a native client
under development using the same Core. Global Verification and Protocol V1 are
implemented, not future features. Read [Architecture](docs/toolkit/ARCHITECTURE.md) before changing boundaries.

Discovery observes and validates before safe publication; handled failures preserve
previous valid state. Bootstrap distinguishes observation errors from differences,
validates selected input before mutation, preserves conflicts, skips matching state
and verifies observable results. No silent reset, clean, forced checkout, remote
replacement or user-data deletion. Generated state is data, never executed.

Application changes reuse production operations and structured records. Keep
secret input outside JSONL, argv, environment and logs. Operation success and final
conformity remain separate. Protocol/domain details belong to their references.

## Capability qualification

For substantial external-tool, privileged, migration or user-data capabilities,
follow **Research/Inspection → capability matrix → product contract → architecture
→ implementation → representative real gates → independent verification →
repeat/no-op convergence**, where applicable. The matrix should distinguish
supported, unsupported and unknown capabilities and the evidence required for
observation, execution and verification. Agree the bounded user outcome and safety
contract before implementation; reuse existing architecture and authoritative paths.
Research depth must match risk and complexity; simple changes do not require this
full process. Mocks alone do not establish real-tool qualification.

Prefer generic capability-based implementations over application-name/version
special cases where practical. Fail closed when required evidence is unavailable;
unknown observation is not absence. See [Vision](docs/VISION.md) for the scope and
value criteria used to narrow, defer or reject work.

## Documentation

English is authoritative; [Russian copies](docs/ru/INDEX.md) are optional convenience
material and may lag behind. Do not create parallel translations of new references.
Identify the owner of a changed fact using the [documentation index](docs/README.md)
and update it first. Update other documents only if their text becomes inaccurate.
Keep Architecture about boundaries, Roadmap about outcomes/status, TODO about
unfinished actions and Changelog about completed changes. Preserve released history.

## Validation and handoff

Run focused existing tests for changed behavior. The canonical full regression
runner is `scripts/test.sh`; ShellCheck is `scripts/lint.sh`. Use the full suite
for integration/release gates or justified broad risk, not every small change.
When Desktop production presentation/state semantics change, focused validation
must include both the relevant feature tests and `PresentationTests`. Run full
canonical validation at implementation checkpoint closure. Canonical repository
regression and Desktop validation must run sequentially unless temporary-state
isolation has explicitly been proven. Complete one checkpoint at a time without
unrelated task hopping.

### Focused feedback and CI

```bash
./scripts/test.sh --quick
./scripts/test.sh --suite scripts/test-dry-run-cli.sh
./scripts/test.sh --suite scripts/test-restore-prepare.py \
  --case RestorePrepareTests.test_cask_execution_and_convergence
./scripts/test.sh --shard 1/4 --list
./scripts/test.sh --ci --shard 1/4
```

No arguments run the full inventory sequentially. Quick selects existing
entrypoint, mode, fixture-dependency and runner checks; it is not full acceptance.
Its hosted budget is a target of five minutes, pending hosted measurement. Local
execution on 23 October 2026 took about 19 seconds. Use focused checks first and
honor task-specific limits on full local runs. Repeat `--case` to select several
methods in one process; full IDs from `--list` or `Class.method` are accepted.

`scripts/test.sh` owns the only suite inventory. `--list` prints the selected plan
and all partitions as JSON without executing tests. Four CI runners use longest
estimated work first to balance whole suites and independent RestorePrepare
methods. IDs come from the existing unittest loader; setup, cleanup, subtests and
conditional skips are retained. The planner checks exact ID union and disjointness,
missing suites, discovery errors and empty partitions before execution. Methods
remain sequential in one interpreter per assigned suite. RestorePrepare methods
own separate temporary projects, HOME and safety state; other suites stay whole.

`scripts/test-timings.json` contains weights, never a second test inventory. Current
weights use completed suites from CI `39977240274`, older complete measurements
from `39919575036` where needed, and four local case measurements. Failed/truncated
suite durations are excluded. Unmeasured methods share the remaining measured
suite weight; new suites receive a provisional 180 seconds. New IDs are always
assigned. Update weights from complete safe reports, retaining their provenance.
The initial plan estimates about 18.9 minutes per runner, excluding provisioning;
this is not a measured hosted speedup. Historical weights, unmeasured methods and
the new external-process suite remain sources of uncertainty.

Each run writes a private ignored `logs/regression/<run>/` directory; `--output`
can select a new destination. `safe/summary.md` and `.json` list PASS, FAIL, ERROR,
SKIP and NOT RUN, slow suites/cases and exact reproduction commands. Per-suite
safe logs/JSON include exception types and source locations, unittest setup/body/
teardown/cleanup time and Prepare/Execute helper counts. Nested timing fields
overlap and must not be added together. `raw/` is private local debugging output;
never upload it. CI publishes only `safe/` as job summaries and seven-day artifacts,
without exception values, environment, user file contents or Core operation logs.

Local runs stop after the first failing suite. `--ci` continues after ordinary
assertion failures only when the worker completed, its owned processes are gone
and its private temporary directory is empty. Cleanup errors, surviving processes,
invalid/incomplete results, cancellation and deadlines stop the shard and mark
remaining work NOT RUN. Existing conditional skips remain visible. Process
ownership reuses Core's observed-descendant/private-session boundary; it cannot
prove absence of a child that detached before observation. Fixtures must retain
their own cleanup contracts. No HOME, journal, installed-state or test-result cache
is shared between tests or CI runs.

Suite deadlines are three estimated durations plus 60 seconds, with a five-minute
minimum; a case also has a fifteen-minute ceiling. Expiry reports ERROR and attempts
owned cleanup, never success. CI keeps lint and every regression shard mandatory;
`validate` rejects failure, cancellation or missing execution. Concurrency cancels
stale development runs only within the same workflow and branch/PR group.

For Bash changes, include syntax checks:

```bash
find modules scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n bootstrap.sh
```

Documentation-only changes normally need diff and local-link review plus
`git diff --check`, without functional tests or observation of real macOS settings.
Help/version are safe CLI checks. Real Check, Discovery, Bootstrap or Workflow
require explicit task authorization and understood side effects.

Before handoff, review `git diff`, `git diff --stat` and `git status --short`.
Stage explicit paths only after scope review. Contributions target `develop`;
version changes and publication follow [Release Process](docs/git/RELEASE-PROCESS.md).
