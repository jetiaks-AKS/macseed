# Changelog

All significant changes to **Macseed** are documented
in this file.

The format is based on the principles of **Keep a Changelog**.

---

## Unreleased

### Added

* Added Protocol V1 `restore_execute` for the initial application-safe Restore
  subset. It re-previews and rejects stale plans, checks execution readiness
  before publication, runs production Bootstrap in an owned process group, and
  reports mutation risk separately from aggregate Global Verification.

* Completed Stage 14 Environment Comparison with read-only selected-requirement
  projection, typed differences, per-domain digest-bound source completeness,
  and informational extra inventory comparison for casks, App Store IDs, and
  VS Code extension IDs. Legacy inventory remains compatible with extra unknown.
  Added public `bs compare` and `./bootstrap.sh --compare` entrypoints; comparison
  remains explicit and never removes extra items.

* Completed Stage 13 human-readable Global Verification reporting with four
  scope-aware readiness verdicts, actionable typed reasons, separate operation
  outcomes, and unchanged public command exit codes.

### Fixed

* Verify supported SSH profiles in a partial snapshot against matching target
  profiles without weakening Bootstrap/Preview configuration conflict protection.
* Accept App Store inventory rows with aligned numeric IDs, prevent `mas list`
  Spotlight auto-indexing during comparison, and print the Comparison heading once.
* Accept a clean Mac without an SSH directory, and prepare selected SSH
  configuration and explicitly confirmed identities before Restore clones
  Workspace repositories, after full Preview and input validation.
* Activate newly installed Homebrew in the running process and defer the
  optional launcher with a warning during Homebrew-free Restore.

## [3.3.0] - 2026-09-26

Macseed: Capture. Rebuild. Continue. Stage 12 / Bootstrap Bundle Capture &
Restore and secure SSH identity migration are released in this version.

### Added

* Added private Bootstrap Bundle v1 Capture/Restore orchestration over staged
  Discovery, Blueprint, Preview and Bootstrap, with optional encrypted SSH
  identities, narrow HOME path normalization, and recoverable local publication.
* Added Stage 12 v1 secure SSH identity list, encrypted export and validated
  no-clobber import as a separate CLI.
* Accepted integer and float representations of supported Dock size preferences
  in Discovery, Preview and Bootstrap after real Capture compatibility testing.

## [3.2.0] - 2026-09-24

Minor release completing the supported macOS settings expansion, adding
restricted Zsh, global Git and SSH client configuration restoration, and
strengthening Guided Workflow, launcher, Generated Configuration and Workspace
security contracts. Stage 11 was closed as Audited / Deferred; Secure Migration
remains planned future work and is not part of this release.

### Added

* Stage 10 is complete. Limited Zsh, global Git and SSH restoration are
  implemented; Apple Terminal remains deferred after the Stage 11 audit.
  Existing Homebrew restoration covers the core CLI scope. Additional tool
  managers remain deferred, and generic PATH/binary restoration is rejected.

* SSH configuration restoration now supports a private snapshot of simple,
  independent Host profiles. Blueprint, Preview and Bootstrap preserve existing
  target configuration, while clean-target Apply verifies a `0700` directory
  and `0600` config. Keys, credentials and learned trust are excluded.

* Global Git configuration now supports seven selected scalar settings,
  including `user.useConfigOnly` and `pull.ff`. Direct global provenance,
  conservative include/XDG ownership, unmanaged absent keys, conflict
  preservation, editor dependency checks, and precise Check → Apply → Verify
  keep unrelated target settings intact.

* Stage 10A: added a limited `.zshrc` snapshot with conservative Discovery
  exclusions, one Blueprint category, read-only Preview, and restore only when
  the target is absent. Generated shell data remains private and is never
  executed during inspection or verification.

* Stage 9E.6: completed Stage 9 macOS settings expansion by adding the stored
  `HideDesktop` bool preference to `macos-windows`. Preview describes whether
  Desktop items would be hidden or shown; Apply uses the existing typed Windows
  lifecycle without a process restart or a claim of visual-state verification.
* Stage 9 is complete. Natural Scrolling, wallpaper-click behavior, Dock Items,
  Menu Bar / Control Center and other private or version-sensitive candidates
  remain deferred to a future explicit compatibility or feature project.

* Stage 9E.3: narrowed `macos-trackpad` to the two reliable primary stored bool
  preferences `Clicking` and `TrackpadRightClick`. Trackpad Apply now performs a
  final stored-state Check without process restart or external-device writes.
* Removed unreliable tracking-speed restoration from the supported Trackpad
  contract. Stale generated `com.apple.trackpad.scaling` records are rejected
  before inspection or mutation and can be refreshed through Discovery.

* Stage 9E.1: expanded `macos-dock` from nine to eleven settings with
  `launchanim` and `mru-spaces`, retaining one Dock restart only after writes.
* Added `macos-windows` with four typed `NSGlobalDomain` preferences, strict
  title-bar/tab enums, stored-value Preview/Verify, and no process restart.
  Legacy Blueprints keep the new category disabled until explicitly migrated.

* Stage 9D: expanded `macos-keyboard` from two to nine supported settings with
  press-and-hold, keyboard UI mode, automatic capitalization/spelling/period
  substitution, and smart quote/dash substitution. `AppleKeyboardUIMode` uses
  the existing integer contract without a new range; six new keys use bool.
* Keyboard Apply performs a final Check of all managed preferences after typed
  writes/read-back. Preview and Bootstrap require no process restart; repeated
  identical runs perform no writes.

* Stage 9C: expanded `macos-dock` from five to nine supported settings with
  `orientation` (`left/bottom/right`), `mineffect` (`genie/scale`),
  `minimize-to-application`, and `show-process-indicators`. Discovery omits
  unsupported scalar enums with a warning; consumers reject invalid generated values.
* Dock Apply restarts Dock only after actual preference writes, then performs a
  final managed-state Check. No-op and repeated identical runs do not restart Dock.

* Stage 9B: added six Finder preferences, bringing support to 13 settings in the
  existing `macos-finder` category: hidden files, new-window target, Desktop hard
  disks/external disks/servers, and filename-extension change warnings.
  `NewWindowTarget` accepts only `PfCm/PfVo/PfHm/PfDe/PfDo/PfAF`; Discovery omits
  unsupported scalar targets with a warning, while consumers reject them.
* Finder Apply restarts Finder only after actual writes and performs a final
  managed-state Check after restart; no-op Apply does not restart Finder.

* Added the repository-owned `bs` launcher with `workflow`, `discover`,
  `blueprint`, `preview`, `bootstrap`, and `check` commands, plus an idempotent
  PATH symlink installer that refuses conflicting existing `bs` entries.
  Bootstrap now runs that installer through a `Check → Apply → Verify`
  self-setup lifecycle; the installer remains available for manual repair.
* Added `--workflow`: Generated Configuration readiness check, optional or
  required Discovery, required Blueprint Save, automatic Preview, and explicit
  Bootstrap confirmation when planned changes exist.
* Added immediate `q` / `Q` cancellation at every Blueprint prompt, including
  nested Edit prompts. Cancellation preserves the saved Blueprint and stops a
  Guided Workflow before Preview and Bootstrap.
* Guided Workflow now finishes without a Bootstrap prompt when Preview reports
  zero planned changes, while preserving Preview warning and error semantics.

### Fixed

* Stage 9A: validate current macOS category/domain/key/type records and reject
  duplicates, unsafe scalar bytes and malformed candidate files before Discovery
  publication or Bootstrap mutation. Preserve final records without a newline.
* Retain macOS Changed accounting after successful writes followed by failed
  Verify or restart, without reporting false success.
* Prepare and verify the generated Screenshot destination instead of creating
  an unrelated hard-coded directory. Detect directory-only changes in Check,
  Preview and Guided Workflow; restart SystemUIServer only for preference writes.
* Validate Screenshot paths before Bootstrap startup mutations; preserve existing
  directories, reject unsafe paths, and never create a missing outside-HOME tree.

### Changed

* Removed unused static `SCREENSHOTS_DIR`; generated location is the sole source.
* Prioritized Stage 9 macOS Coverage Expansion. Global Verification is
  Future / Optional. Trackpad
  float support remains deferred; Stage 9A retains the existing integer contract.

## [3.1.0] - 07.09.2026

Minor release adding a complete read-only Preview of the selected Bootstrap
scope and strengthening the lifecycle guarantees that Preview relies on.

### Added

* Added `--dry-run` as an exclusive execution mode with read-only startup,
  Blueprint-aware selection, status `0 / 1 / 2`, and a Preview Summary using
  Modules Inspected, Warnings, Errors, and Duration.
* Added planned actions for Homebrew formulae and casks, App Store applications,
  VS Code extensions and settings, Git configuration, Workspace folders,
  repository clones and branch switches, and typed macOS settings.
* Added macOS plans for the existing Screenshots directory action and required
  Finder, Dock, and SystemUIServer restarts.

### Changed

* Preview reuses production validation, selection, and inspection helpers.
  Planned changes remain successful observations rather than warnings and do
  not affect Bootstrap Changed-state accounting.
* Bootstrap startup validates Blueprint and selected required generated input
  before prerequisite or target-state mutation.
* Discovery Summary now uses Discovery-specific Modules Processed, Warnings,
  and Errors labels while Check and Bootstrap summaries retain their contracts.

### Fixed

* Corrected generic `Check -> Apply -> Verify` propagation so Apply failures
  cannot be hidden by a later Check.
* Hardened formula, cask, App Store, VS Code extension, VS Code settings, and
  Workspace consumers against malformed input, observation failures, false
  success, partial inspection, and missing post-Apply verification.
* App Store presence checks now use exact numeric IDs; cask verification checks
  every supported artifact target.
* Workspace folder, clone, and branch restoration now verify retained mutations
  and preserve accurate Changed state across later failures.

### Safety / Reliability

* Preview performs no target-state mutation: it skips `sudo` authentication,
  installers, configuration writes, filesystem restoration, macOS defaults
  writes, and process restarts. Internal Toolkit logging and temporary
  validation files remain allowed.
* Homebrew prerequisite inspection distinguishes confirmed absence from an
  observation error, preventing inspection failures from entering the installer
  path.

### Tests / Documentation

* Added focused lifecycle coverage across Applications, VS Code, Workspace,
  macOS, startup, and Blueprint behavior.
* Added real-entrypoint Preview integration coverage with mutation spies,
  target-state snapshots, mixed-domain plans, stable output, warning/error
  propagation, and terminal/logger Summary parity.
* Updated CLI, configuration, architecture, agent, roadmap, and user guidance
  for the completed Preview contract. Global Verification remains planned.

## [3.0.0] - 18.08.2026

Major release introducing **Blueprint** as the selection layer between
Generated Configuration and Bootstrap, together with reliability hardening
across Discovery, Bootstrap, Workspace, Git, Applications, and macOS Settings.

The current Toolkit workflow is:

```text
Discovery
    ↓
Generated Configuration
    ↓
Blueprint
    ↓
Bootstrap
````

Blueprint is optional. Without a local Blueprint, Bootstrap preserves the
legacy all-inclusive behavior.

### Added

#### Blueprint

* Added Blueprint as a separate selection layer between Generated Configuration
  and Bootstrap.
* Added local `config/blueprint.conf`.
* Added Blueprint parser and validation.
* Added item-level selection for:

  * Homebrew Packages;
  * Homebrew Casks;
  * App Store applications;
  * VS Code Extensions;
  * Workspace Folders;
  * Git Repositories.
* Added category-level selection for:

  * Git Configuration;
  * VS Code Settings;
  * Finder;
  * Dock;
  * Keyboard;
  * Trackpad;
  * Screenshots.
* Added interactive Blueprint creation and editing through `--blueprint`.
* Added All, None, and Edit modes for discovered item groups.
* Added numeric, comma-separated, space-separated, range, and mixed-range
  selection.
* Added pagination for larger item groups.
* Blueprint selector pages now display up to 20 items.
* Added loading and editing of an existing Blueprint.
* Added safe cancellation without modifying the existing Blueprint.
* Added `config/blueprint.example.conf`.
* Blueprint remains local and is excluded from Git.

#### Regression Testing

* Added focused regression harnesses for Blueprint parser and validation.
* Added focused regression harnesses for the interactive Blueprint selector.
* Added Blueprint-aware Bootstrap regression coverage.
* Added focused Application Discovery and Bootstrap consumer regression tests.
* Added Homebrew Discovery regression coverage.
* Added Git Generated State regression coverage.
* Added macOS Discovery and Bootstrap regression coverage.
* Added Workspace Discovery regression coverage.
* Added Workspace Bootstrap regression coverage.
* Added Workspace Folders regression coverage.

---

### Changed

#### Architecture

* The implemented Toolkit workflow is now:

```text
Discovery
    ↓
Generated Configuration
    ↓
Blueprint
    ↓
Bootstrap
```

* Generated Configuration remains the owner of machine-specific observed
  values.
* Blueprint owns Desired Selection and restoration scope.
* Blueprint does not copy, own, or rewrite discovered values.
* Bootstrap combines Blueprint selection with Generated Configuration values.
* Without Blueprint, Bootstrap preserves legacy all-inclusive processing.
* The existing module-level lifecycle remains `Check → Apply → Verify`.
* Global Verification remains a planned future capability.
* Dry-run / Preview remains planned and is not part of the 3.0.0 release.

#### Discovery

* Discovery exporters now use safe publication for Generated Configuration.
* New generated state is published only after successful observation,
  validation, and serialization.
* A handled observation, serialization, or publication failure preserves the
  previous valid generated file.
* Most generated files are published independently.
* Workspace derived files:

  * `folders.conf`;
  * `repositories.conf`;
  * `vscode-workspaces.conf`;
  * `inventory.conf`
    are published as one grouped snapshot.
* Observation failures are no longer automatically interpreted as component
  absence.

#### Git Configuration

* `config/generated/git.conf` now uses native Git config format.
* Supported generated Git values are read through
  `git config --file ... --no-includes`.
* Generated Git configuration is never executed through `source` or `eval`.
* Generated Git state is limited to supported global Git configuration keys.
* Git Generated State validation has been hardened.

#### Bootstrap

* Bootstrap now supports Blueprint-aware item and category filtering.
* Required generated input is validated before the first mutation where
  required by the selected scope.
* Observation semantics were hardened to distinguish:

  * present state;
  * absent state;
  * observation failure.
* Application consumers no longer interpret failed state checks as missing
  applications.
* Workspace Bootstrap validates required generated input before mutation.
* Existing Git repositories are validated before branch restoration.
* Repository remote URLs are verified against Generated Configuration.
* Branch restoration is performed only for clean repositories with matching
  remotes.
* Existing repository data and Git remotes are not rewritten when validation
  fails.
* macOS Bootstrap consumers now validate supported generated values by type.
* Added post-write verification for supported macOS Settings.
* Status propagation for `0 / 1 / 2` has been hardened.
* Bootstrap Summary now reflects Blueprint selection.
* Warning and error states no longer produce false success in the final
  lifecycle result.

#### Blueprint Selector

* Increased Blueprint selector page size from 10 to 20 items.
* Global item numbering is preserved across pages.
* Next and Previous navigation remains available for larger lists.
* Existing checkbox state is preserved when editing a Blueprint.

---

### Fixed

#### Discovery

* Fixed loss of previous valid Generated Configuration after handled Discovery
  failures.
* Fixed unsafe publication paths where incomplete observed state could replace
  previously valid generated state.
* Fixed handling of observation failures that could otherwise be interpreted
  as empty state.

#### Applications

* Fixed Application consumers treating failed installed-state checks as
  application absence.
* Fixed unsafe apply decisions caused by ambiguous observation results.

#### Git Configuration

* Fixed validation of malformed or unsupported Git Generated State.
* Fixed Git configuration read and apply error handling.
* Fixed unsafe interpretation of generated Git configuration.

#### Workspace

* Fixed Workspace Bootstrap validation so missing, unreadable, or malformed
  required generated input fails before the first mutation.
* Fixed repository validation and branch restoration warning propagation.
* Existing repositories with mismatching remotes are left unchanged.
* Repositories with uncommitted changes are not switched to another branch.
* Processing continues for remaining repositories when an individual
  repository requires manual attention.

#### macOS Settings

* Fixed validation of generated macOS values before apply.
* Fixed handling of unsupported or malformed typed values.
* Added verification of supported settings after write.
* Fixed cases where an apply operation could report success without confirming
  the resulting state.

#### Lifecycle and Summary

* Fixed propagation of warning and error statuses through Bootstrap lifecycle.
* Fixed false-success final Bootstrap results.
* Fixed Summary behavior so warning and error conditions are reflected
  correctly.

---

### Documentation

* Architecture documentation was aligned with the implemented
  Discovery → Generated Configuration → Blueprint → Bootstrap model.
* Configuration documentation was aligned with Observed State, Desired
  Selection, Generated Configuration, and Blueprint ownership.
* The distinction between local module Verify and planned global Verification
  was clarified.
* CLI Output and Logging documentation was consolidated.
* Quick Start was updated to the current supported workflow.
* Project documentation was simplified by removing obsolete and duplicated
  documents.
* Vision was updated while preserving the long-term project direction.
* Roadmap and TODO were aligned with the implemented 3.0.0 state.
* Module-level documentation was aligned with current production behavior.
* VS Code Workspace metadata Discovery remains implemented, while
  `.code-workspace` restoration remains outside production Bootstrap
  orchestration.

---

## [2.0.1] - 13.08.2026

Stabilization release after **2.0.0 Stable**.

### Added

#### Logging

* Added support for separate history log files for each Toolkit mode.
* Logs now automatically receive a prefix depending on the mode:

  * `bootstrap-YYYY-MM-DD_HH-MM-SS.log`
  * `check-YYYY-MM-DD_HH-MM-SS.log`
  * `discover-YYYY-MM-DD_HH-MM-SS.log`
* Added a unified `logs/latest.log` containing the latest Toolkit run.
* Added a timestamp to each log-file entry.
* Added handling of Toolkit interruption through `INT` and `TERM`.
* When Toolkit is interrupted, the log is correctly closed with the
  `Interrupted` status.
* Added protection against closing Logger more than once.

#### Module Lifecycle Logging

* Added logging for the start of each module execution.
* Added logging for each module execution result.
* Added logging of the `MODULE_CHANGED` state.
* Added recording of the following results:

  * `SUCCESS`
  * `WARNING`
  * `ERROR`
  * `UNKNOWN`
* Added equivalent logging for configuration modules.

#### Configuration

* Added a policy excluding `config/generated/` from Git.
* Generated Configuration is now treated as machine-specific configuration.
* Generated Configuration continues to be used locally for
  Discovery → Bootstrap, but must not be included in the public repository.

---

### Changed

#### Logging

* Logger is now initialized before the first informational Toolkit message.
* Mode is determined centrally for all supported modes:

  * `Check`
  * `Bootstrap`
  * `Discovery`
* Improved separation between Compact and Verbose Output.
* Detailed output continues to be controlled through `detail()`.
* Logger shutdown is centralized through `close_logger()`.
* Summary and final execution parameters are written to both history-log and
  `latest.log`.

#### Module Lifecycle

* `run_module()` is now centrally responsible for:

  * running the module;
  * counting checked modules;
  * determining state changes;
  * counting Installed / Skipped;
  * handling Warning / Error;
  * logging the result.
* `run_configuration()` now follows the same module lifecycle principle.
* Module Lifecycle logging no longer depends on an individual module.

#### Configuration

* Local machine-specific Generated Configuration is no longer part of the
  public Git state of the project.
* Git configuration was cleaned of personal user values:

  * `GIT_USER_NAME`
  * `GIT_USER_EMAIL`
* The public version of `config/git.conf` no longer contains personal Git
  identity settings.

---

### Fixed

#### Logging

* Fixed history-log creation for `--check`.
* Fixed history-log creation for `--discover`.
* Fixed history-log creation for `--bootstrap`.
* Fixed updating `logs/latest.log` after Toolkit completion.
* Fixed logging shutdown when the process is interrupted.
* Fixed the absence of a unified completion status in an interrupted log.
* Fixed Logger initialization before the first `info()` call.

#### Module Lifecycle

* Fixed the absence of unified result logging in `run_module()`.
* Fixed missing `MODULE_CHANGED` logging for modules.
* Fixed handling of an unknown module return code.
* Fixed result logging in `run_configuration()`.
* Fixed consistency of Installed / Skipped / Warnings / Errors statistics.

#### Workspace

* Fixed a situation where Bootstrap displayed Git branch mismatch warnings
  after switching the working project from `feature/mac-blueprint` to
  `develop`.
* Generated Workspace Configuration now correctly reflects the current working
  branch after running Discovery.
* Bootstrap continues processing remaining repositories when an individual
  repository requires manual attention and finishes Workspace with a warning.
* Missing or unreadable Workspace configuration now correctly returns a
  warning.
* Failure to create a Workspace folder now returns an error.

#### Exit Codes

* CLI now returns the final execution status:

  * `0` — success;
  * `1` — warning;
  * `2` — error.
* Error has priority over warning in the final Toolkit status.
* A preflight error now terminates Toolkit with exit code `2`.

#### Bootstrap Apply

* Git configuration now checks apply errors and the result of final
  configuration verification.
* Applying VS Code Settings now reports errors when creating the directory,
  backing up settings, or copying settings.

---

### Documentation

* Project documentation was aligned with the current architecture after the
  2.0.0 release.
* Documented that `config/generated/` contains machine-specific data and must
  not be included in the public repository.
* Documented the current model:
  **Discovery → Generated Configuration → Bootstrap**.
* Documented the separation between the current Toolkit implementation and
  future architectural stages.
* Added the implementation plan for a separate **Dry-run Mode**.
* Dry-run is considered the next stage before further development of the
  Blueprint approach.
* Documented the need for further Summary improvements for `--discover` mode.

---

## [2.0.0] - 09.08.2026

First stable Toolkit version based on the
**Discovery → Generated Configuration → Bootstrap** architecture.

### Added

#### Discovery Engine

* Added a complete Discovery Engine.
* Added automatic analysis of the current macOS working environment.
* Added discovery of Homebrew Packages and Casks.
* Added discovery of App Store applications.
* Added Git Configuration export.
* Added discovery of VS Code Extensions and Settings.
* Added Workspace structure discovery.
* Added discovery of Git Repositories and their metadata.
* Added Workspace Inventory.
* Added automatic configuration generation in `config/generated/`.

#### Workspace Bootstrap

* Added Workspace Bootstrap.
* Added Workspace structure restoration.
* Added Git Repository restoration.
* Added Remote URL verification.
* Added current Git branch verification.
* Added working Git branch restoration.
* Added Workspace Bootstrap integration with Generated Configuration.

#### Configuration

* Added a unified Configuration Engine.
* Bootstrap was migrated to use Generated Configuration.
* Removed duplication of user settings between Discovery and Bootstrap.
* Established the principle:

```text
Discovery
    ↓
Generated Configuration
    ↓
Bootstrap
```

#### CLI & Output

* Added a complete `--verbose` mode.
* Added compact output mode by default.
* Added a unified detailed-output mechanism through `detail()`.
* Discovery displays discovered objects in Verbose Mode.
* Added information about generated configuration files being created.
* Summary was adapted to the Toolkit execution mode.

---

### Changed

#### Architecture

* Toolkit moved from primarily manual configuration to the
  **Discovery → Generated Configuration → Bootstrap** model.
* Generated Configuration became the primary data source for Bootstrap.
* Workspace was separated into dedicated Discovery and Bootstrap areas.
* macOS Settings configuration was migrated to Generated Configuration.
* Documentation was revised to reflect the target project architecture.

#### Output

* Unified Compact and Verbose Mode behavior.
* Discovery modules use a unified informational message format.
* Removed unnecessary output duplication.
* Summary now correctly reflects the execution mode:
  Discovery, Bootstrap, or Check.

---

### Fixed

* Fixed App Store Discovery format in Generated Configuration.
* Fixed App Store application display in Verbose Mode.
* Fixed Verbose Output for VS Code Discovery.
* Fixed Verbose Output for Workspace Discovery.
* Fixed repeated Dock Discovery import.
* Fixed minor Workspace Discovery issues.
* Fixed general Summary text for different Toolkit modes.
* Fixed Generated Configuration compatibility with the format used by
  Bootstrap.

---

### Documentation

* Reworked the main project README.
* Updated architecture documentation.
* Updated ROADMAP.
* Updated TODO.
* Documentation was separated by purpose.
* Documented the target Toolkit development model.
* Documented the separation between the current implementation and future
  architectural stages.

---

## [1.1.0] - 04.08.2026

### Added

#### Core

* Added modular Toolkit architecture.
* Added unified logging system (`INFO`, `OK`, `WARN`, `ERROR`).
* Added check mode (`--check`).
* Added Bootstrap mode (`--bootstrap`).
* Added `--help`.
* Added `--version`.
* Added Toolkit startup screen displaying version and operating mode.

#### Homebrew

* Automatic Homebrew installation.
* Installed Homebrew verification.
* Automatic installation of CLI packages from the configuration file.
* Automatic installation of GUI applications (Casks) from the configuration
  file.
* Support for `brew install --cask --adopt` for existing applications.
* Added automatic Homebrew Cask restoration.
* Added result verification after installation (Verify After Apply).

#### Git

* Git installation verification.
* Automatic Git configuration.

#### SSH

* SSH configuration verification.

#### Terminal

* Terminal readiness verification.

#### App Store

* Added Mac App Store support through `mas`.
* Automatic application installation from `config/appstore.conf`.
* Verification of already installed applications before installation.

#### VS Code

* VS Code CLI (`code`) availability verification.
* Automatic extension installation from `config/vscode-extensions.conf`.
* Verification of already installed extensions.
* Automatic installation of missing extensions only.
* Automatic application of `settings.json`.
* Backup of existing VS Code settings.
* Verification that settings are current before applying them.

#### macOS

* Added modular Finder configuration.
* Added modular Dock configuration.
* Added modular Keyboard configuration.
* Added modular Trackpad configuration.
* Added modular Screenshots configuration.
* Added idempotent verification of current settings before applying changes.

#### Configuration

* Added configuration files:

  * `brew-packages.conf`
  * `brew-casks.conf`
  * `appstore.conf`
  * `vscode-extensions.conf`
* Added `settings/` directory.
* Added VS Code settings templates.

#### Project

* Added unified project structure.
* Added support for separate modules.
* Added separation into:

  * `modules`
  * `config`
  * `settings`
* Added `TODO.md`.
* Added `macos.sh` module.
* Added macOS settings export scripts.
* Added macOS settings analysis scripts.

#### Output

* Added `--verbose` mode.
* Added compact output mode by default.
* Added detailed output support (`detail()`).
* Added Quiet Mode for installation operations.
* Added final Summary with extended statistics.

---

### Changed

* Completely reworked the Toolkit command-line interface.
* Unified the style of all Toolkit modules.
* Unified function naming.
* Unified the `MODULE_CHANGED` principle.
* Significantly reduced Toolkit output volume.
* Implemented Compact / Verbose modes.
* All install modules were migrated to Quiet Mode.
* Improved project structure.
* Improved code readability.
* Updated project documentation.
* Toolkit moved to stable version `1.1.0`.

---

### Fixed

* Fixed Summary statistics calculation.
* Fixed changed-module detection logic.
* Fixed Homebrew Cask handling after manually removing applications.
* Fixed automatic restoration of missing Homebrew Casks.
* Fixed Homebrew Cask installation result verification.
* Fixed App Store application installation logic.
* Fixed VS Code extension verification logic.
* Fixed VS Code settings application logic.
* Fixed Finder checks.
* Fixed Dock checks.
* Fixed minor Bootstrap issues.

---

## [1.0.0] - 03.08.2026

First stable release of Mac Bootstrap Toolkit.

### Added

#### Core

- Added the initial modular Toolkit architecture.
- Added a unified status system using `INFO`, `OK`, `WARN`, and `ERROR`.
- Added system check mode (`--check`).
- Added full Bootstrap mode (`--bootstrap`).
- Added `--help`.
- Added `--version`.

#### Preflight

- Added Internet connectivity checks.
- Added Xcode Command Line Tools checks.
- Added macOS version compatibility checks.
- Added administrator privilege checks.

#### Homebrew

- Added Homebrew availability checks.
- Added automatic Homebrew installation.
- Added Homebrew package installation.
- Added Homebrew Cask installation.

#### Git

- Added Git installation checks.
- Added Git configuration checks.
- Added automatic Git configuration.

#### SSH

- Added SSH configuration checks.

#### Terminal

- Added Terminal readiness checks.

#### App Store

- Added App Store application installation through `mas`.
- Added checks for already installed App Store applications.

#### VS Code

- Added VS Code extension installation.
- Added `settings.json` application.
- Added backup of existing VS Code settings.
- Added checks for already current VS Code settings.

#### macOS

- Added Finder configuration.
- Added Dock configuration.
- Added Keyboard configuration.
- Added Trackpad configuration.
- Added Screenshots configuration.
- Added idempotent application of supported macOS settings.

### Changed

- Finalized the initial Bootstrap framework.
- Standardized the Bootstrap modules in English.
- Established the first stable modular project structure.
- Established idempotent configuration as a core Toolkit principle.

### Documentation

- Finalized the Roadmap for the first stable release.
- Updated Quick Start requirements for supported macOS, Internet access, and
  administrator privileges.
- Marked version 1.0.0 as the first stable Mac Bootstrap Toolkit release.
