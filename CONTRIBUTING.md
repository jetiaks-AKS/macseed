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
Keep only substantive, sanitized E2E/qualification reports under
[docs/qualification/](docs/qualification/README.md), not the `docs/` root.
Routine test output stays untracked; Roadmap/TODO link to evidence rather than
reproduce logs. Preserve historical reports and update moved-file links.

## Validation and handoff

### Risk-based local validation

Choose validation from the actual diff, affected contracts and demonstrated risk.
Incremental changes use focused existing cases; neither a small correction nor
calling it an implementation checkpoint requires complete affected suites.

- **Synchronize tests:** before changing production code, find dependent tests for
  behavior, APIs, state, UI strings and file contracts. Update obsolete expectations
  with the change; prefer semantic assertions over incidental source-text matching.
- **Use focused coverage:** run the smallest cases that cover the changed behavior
  and affected consumers. Desktop changes need relevant feature and/or presentation
  cases according to the diff, not automatic full `PresentationTests`, `CaptureTests`
  or `RestoreTests`. A successful build alone does not prove behavioral correctness.
- **Reuse prior PASS evidence:** retain its command, scope, revision or patch context,
  result and relevant environment assumptions. Reuse it when diff review confirms
  that the tested code, dependencies, fixtures, contracts and assumptions remain
  unchanged. Revalidate the specific gap when they change or evidence is incomplete;
  do not restart completed suites merely because adjacent work or documentation changed.
- **Protect security boundaries:** changes to authentication, consent, validation,
  privacy, ownership/path/link checks, freshness, no-clobber mutation or cancellation
  require focused positive and fail-closed negative tests for the affected boundary.
  Unchanged boundary coverage may reuse valid prior evidence. Never weaken, skip or
  remove valid safety assertions to obtain PASS.
- **Justify broader runs before starting:** use complete suites or broad regression
  at substantive integration/release checkpoints or for a demonstrated risk. State
  the changed contract or concrete gap, why focused cases and retained evidence are
  insufficient, the exact proposed scope/command and expected cost. A generic
  checkpoint-closure rule is not justification. Honor task limits and stop rules;
  this policy does not authorize otherwise prohibited runs.
- **Report evidence precisely:** distinguish newly executed PASS, reused prior PASS,
  FAIL/ERROR, SKIP and NOT RUN, with reasons and remaining uncertainty. Unexecuted
  suites are never newly passed; retained evidence does not establish a current
  hosted run, visual acceptance or real-Mac/release qualification.

Mandatory CI gates and their complete configured coverage remain unchanged; local
evidence reuse never substitutes for required CI execution. Use the canonical
`scripts/test.sh` runner and `scripts/lint.sh` for ShellCheck. Repository regression
and Desktop validation remain sequential unless temporary-state isolation is proven.
Complete one checkpoint at a time without unrelated task hopping. Documentation-only
edits retain the diff/link and `git diff --check` policy below.

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
estimated work first to balance whole suites and independent methods from
`test-restore-prepare.py`, `test-capture-api.py`,
`test-workspace-topology-execute.py`, `test-secure-restore.py` and
`test-restore-selection.py`. IDs come from the existing unittest loader;
setup, cleanup, subtests and conditional skips are retained. The planner checks exact ID union and disjointness,
missing suites, discovery errors and empty partitions before execution. Methods
remain sequential in one interpreter per assigned suite. These five suites use
per-case temporary projects, HOME and safety state, without shared mutable
class/module fixtures; other suites stay whole. Capture and secure identity
global temporary-directory inventory checks still prohibit concurrent suites
on one host. CI shards use separate VMs.

`scripts/test-timings.json` contains weights, never a second test inventory.
Weights use the successful partitions of [CI #161](https://github.com/jetiaks-AKS/macseed/actions/runs/42836491162)
(`a289442f`): shards 1 and 4 from attempt 1, shards 2 and 3 from attempt 2.
All 44 suites and 346 methods in the five split suites have PASS measurements;
failed/unfinished work is excluded. The reduced screenshot backend matrix retains
its pre-optimization weight conservatively until hosted remeasurement. Local timings
and estimates are not relabeled as hosted measurements. Unknown methods receive at
least 60 seconds or their share of the remaining suite budget; new suites receive
180 seconds. Measured startup overhead is distributed without reducing case times.
New IDs are always assigned. Refreshed weights predict about 41 min 43 s per shard,
excluding provisioning and scheduling; that is an estimate, not a new hosted PASS.
See the [suite audit](docs/qualification/TEST-SUITE-AUDIT-2026-11-10.md) for the complete
inventory, retained coverage, removed repetitions and baseline attempt distinction.

Each run writes a private ignored `logs/regression/<run>/` directory; `--output`
can select a new destination. `safe/summary.md` and `.json` list PASS, FAIL, ERROR,
SKIP and NOT RUN, slow suites/cases and exact reproduction commands. Per-suite
safe logs/JSON include exception types and source locations, unittest setup/body/
teardown/cleanup time, Prepare/Execute helper counts and the active case at interruption.
An unfinished case remains NOT RUN in the completion inventory; `active_case`
distinguishes interrupted work from cases that never started. Nested timing fields
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

Desktop CI uses only `./desktop/Macseed/build.sh Debug --test`, after lint succeeds,
in parallel with the four Core shards. Each job has its own GitHub-hosted VM,
checkout, working directory and temporary state; fixture HOME/tools remain local
to that job. No shared cache, artifact input or external mutable fixture state
connects Core and Desktop. This does not relax sequential Core/Desktop validation
on a single local machine, where temporary-directory observations can overlap.
The required `validate` check retains `if: always()` and dependencies
`[lint, regression, desktop]`; all three must report `success`. Failure,
cancellation, skipped or missing execution cannot pass the gate.
The twelve suites and two Restore subsets retain their fixture isolation
and native assertions; [build.sh](desktop/Macseed/build.sh) owns the inventory.
Capture/Restore keep `--no-renders`. Debug tests compile their common production
sources once per invocation as an internal, testable Swift module, retaining
`-Onone`, `-g`, `DEBUG` and whole-module compilation. Ten test executables link that
object; the two Core transport/storage executables keep their smaller source sets.
Generated import wrappers preserve original source locations. There is no persistent
binary/result cache; compile failure stops execution. App and Release builds keep
their existing source sets and compilation path.

The two additional Restore workflows retain their own fixtures and assertions;
constant model/decoder groups run once in the mandatory standard invocation.
Capture's full collector scenario remains production. Its later Workspace and
application-overlap fixtures omit unrelated collectors only in disposable Core
copies, retaining actual selected collectors, transport, publication and stale checks.
Capture emits unbuffered progress and named group timings; the encompassing real-Core
time includes Workspace/overlap and must not be added to them.
The runner's selected
Xcode, SDK, Swift and Xcode-resolved Python are checked before execution. Safe GUI
session facts help diagnose WindowServer failures; they never replace native tests.

`build.sh` optionally writes `MACSEED_DESKTOP_SUMMARY`: fixed stage labels,
passed/failed/not-run, process exit status and elapsed seconds, with compilation
separate from execution. It publishes the summary atomically at every stage boundary;
a force-killed job can leave `running`, which is never interpreted as PASS.
PresentationTests executes under `scripts/desktop_test_runner.py` with a 600-second
wall deadline independent of MainActor/WindowServer (CI #151 execution: 83 seconds).
The supervisor retains nonzero exits, checks process ownership before launch,
cleans observed descendants on timeout/cancellation and rejects unconfirmed cleanup.
On timeout it emits only allowlisted framework markers and PresentationTests source
line numbers from a bounded sample; raw stacks are discarded. Native help checkpoints
identify window creation, layout, input and dismissal phases. No native assertion is
skipped, and the 45-minute hosted limit remains unchanged. Assertion counts remain
unknown. CI appends this to
`GITHUB_STEP_SUMMARY` even after failure and rejects missing reports. Desktop
uploads no artifacts or raw logs.

[CI #108](https://github.com/jetiaks-AKS/macseed/actions/runs/40287367098), at
`411cd712a1091d67da28b13b6982901259dc00c9` on 26 October 2026, completed lint,
all four Core shards, the Desktop Debug build, all eight Desktop suites, both
Restore subsets and `validate`, including native PresentationTests assertions.
The Desktop job took **13 min 15 s**; total CI elapsed was **38 min 12 s**, with
Desktop still waiting for Core. The slowest Core shard took **24 min 44 s**.
[CI #109](https://github.com/jetiaks-AKS/macseed/actions/runs/40322214728), at
`e2d6e77`, confirmed the parallel schedule with every required job successful,
the same eight suites/two subsets and native PresentationTests executed. Lint
finished at 12:25:36 UTC; Desktop started at 12:25:40 while all four Core shards
were running. Total CI elapsed was **24 min 45 s**, **13 min 27 s (35.2%) less**
than #108; Desktop itself took **19 min 29 s** and the slowest Core shard
**24 min 35 s**. Elapsed totals use run creation through final update. These are
two observed hosted runs, not a benchmark distribution or a future duration guarantee.

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
