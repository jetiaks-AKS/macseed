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
