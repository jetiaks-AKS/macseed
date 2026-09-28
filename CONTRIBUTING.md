# Contributing

Thank you for contributing to Macseed.

## Workflow

- Start development from `develop`.
- `main` contains stable releases only; do not develop directly on `main`.
- Keep each commit limited to one logical task.
- Use English commit messages in the form `type: short description`.
- Supported commit types are `feat`, `fix`, `refactor`, `docs`, `style`,
  `chore`, and `release`.
- Do not commit generated configuration, logs, exports, environment files,
  local Blueprint state, or temporary files.

Before editing, understand the current working tree and confirm that local
`develop` is synchronized with `origin/develop`. Preserve unrelated local
changes.

---

## Project model

The current Toolkit workflow is:

```text
Discovery
    ↓
Generated Configuration
    ↓
Blueprint
    ↓
Bootstrap
```

Discovery observes supported state and publishes machine-specific Generated
Configuration.

Blueprint selects the restoration scope without duplicating discovered values.

Bootstrap combines that selection with Generated Configuration and safely
applies supported state.

Dry-run / Preview is part of the current implementation contract. Aggregate
Global Verification remains a planned extension.

For architectural details, see
[`docs/toolkit/ARCHITECTURE.md`](docs/toolkit/ARCHITECTURE.md).

---

## Change principles

Keep changes focused and preserve existing contracts unless the task explicitly
requires changing them.

Discovery changes must:

- observe rather than configure the system;
- validate and serialize new state before publication;
- preserve previous valid Generated Configuration on handled failure.

Bootstrap changes must:

- distinguish observation failures from legitimate differences;
- validate required Generated Configuration before mutation;
- avoid unnecessary changes;
- preserve existing user state;
- verify applied state where supported.

Do not introduce silent destructive behavior such as:

- `git reset --hard`;
- `git clean`;
- force-push;
- forced checkout over local changes;
- deletion or replacement of user data without an explicit safe contract.

Update documentation when externally visible behavior or a documented contract
changes.

Use:

- `docs/toolkit/ARCHITECTURE.md` for architecture;
- `ROADMAP.md` for implementation stages and future development;
- `TODO.md` for immediate technical backlog;
- `CHANGELOG.md` for completed release-visible changes.

---

## Validation

Use the focused regression harnesses relevant to the changed area.
Run the complete local regression suite with `scripts/test.sh`.

Existing coverage includes Blueprint, Discovery, applications, Git, Workspace,
and macOS consumer behavior. Do not create a new test script solely to mirror
every production module; extend the closest focused harness when practical.

For Bash changes, run the relevant regression tests and at minimum:

```bash
find modules scripts -type f -name '*.sh' -print0 | xargs -0 -n1 bash -n
bash -n bootstrap.sh
git diff --check
```

Safe CLI sanity checks that do not execute a real Discovery or Bootstrap
workflow are:

```bash
./bootstrap.sh --help
./bootstrap.sh --version
```

Run real:

```bash
./bootstrap.sh --check
./bootstrap.sh --discover
./bootstrap.sh --blueprint
./bootstrap.sh --bootstrap
./bootstrap.sh --workflow
```

only when the task explicitly requires the corresponding workflow and its side
effects are understood.

Before handing off a change, inspect:

```bash
git diff --check
git diff --stat
git status --short
```

---

## Pull requests and releases

Open contributions against `develop`.

Release integration into `main`, version changes, release notes, tags, and
publishing follow the maintainer release process.

See [`docs/git/RELEASE-PROCESS.md`](docs/git/RELEASE-PROCESS.md) for the
current release procedure.
