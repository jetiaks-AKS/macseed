# Automatic MAS Restore v4 archive

Branch: `archive/mas-automatic-restore-v4`. Base develop commit: `0983927004419b15467303b3b638e172d5462344`.
This is a preservation checkpoint, not a release or successful end-to-end MAS
qualification. Assisted App Store Restore is the selected direction for 1.0;
its implementation and removal of the automatic path are explicitly deferred.
Older README/Roadmap/checkpoint claims are preserved as historical text, not a
current capability promise. The production implementation contract is README.md
in this directory. No archived source, test, build or deployment entrypoint is
authorization to install, register a helper, migrate state or perform cleanup.

## Preserved material

The checkpoint retains Core consumer/inventory/Preview/Verification changes,
Desktop integration, MASHelper/MASClient/XPC, journal v3/v4 migration and immutable
history, recovery/reconciliation/grants, ownership/suspended lifecycle, fixtures,
source tests, signing/build/deployment scripts and third-party notices.
Unmodified Core Discovery, Bundle, Blueprint and other-domain Restore remain in
the inherited Git tree. Vendor/SourceProvenance retains the source commit,
compatibility patch, exact dependency lockfile and build instructions without
binaries or local inventory. Existing development certificate/hash pins are
public verification identifiers, not signing credentials.

TrustedMAS historical source preserves unique process-observation and targeted
identity policies, crash/orphan tests and qualification/controlled-install source.
Its shared source symlinks resolve to archived production implementations or
LegacyFixtures; production test runners do not depend on the experiment tree.
The original UID-only experiment and obsolete packaging scripts are superseded
and excluded. Historical runtime reports and local cleanup inventories remain
outside Git; links to those intentionally omitted records are historical only.
No runtime journal or recovery evidence from the user's Mac is included.

## Deliberately excluded working-tree files

- `desktop/AuthorizationPoC/App.swift`
- `desktop/AuthorizationPoC/Helper.swift`
- `desktop/AuthorizationPoC/History/README.md`
- `desktop/AuthorizationPoC/History/trusted-build.sh`
- `desktop/AuthorizationPoC/History/trusted-package.sh`
- `desktop/AuthorizationPoC/History/uid-build.sh`
- `desktop/AuthorizationPoC/README.md`
- `desktop/AuthorizationPoC/Shared.swift`
- `desktop/AuthorizationPoC/TrustedMAS/CONTROLLED-BLACKMAGIC.md`
- `desktop/AuthorizationPoC/TrustedMAS/CONTROLLED-INSTALL-STAGE1.md`
- `desktop/AuthorizationPoC/TrustedMAS/LIVE-RESULTS-2026-10-18.md`
- `desktop/PrivilegedMAS/CLEANUP.md`
- `desktop/PrivilegedMAS/cleanup-temporary.json`

These files are left on disk unchanged. Ignored build outputs, packages, apps,
logs, staging, credentials and all protected system state are also excluded.
Raw historical evidence is not needed to compile the production implementation;
legacy evidence hashes in source are preserved without inventing replacement
bytes. Old experiment reproduction may need separately retained private evidence.

## Safe handoff to develop (not performed here)

Keep this archive branch immutable after verification and publication. Do not
merge/cherry-pick the entire archive to develop: it enables the automatic path.
Use a separate clean worktree based on the recorded develop commit, first checking
whether develop has advanced and preserving any unrelated changes. Retain the
archive worktree and excluded local material until a separate cleanup decision.

- Keep inherited Discovery, Bundle, Blueprint, selection, other-category Core
  execution and Homebrew behavior unchanged.
- Port `modules/apps/appstore_inventory.py` and the input/inventory/Preview/
  Verification portions of `modules/apps/appstore.sh` with their focused tests.
  Review every hunk: do not port install/XPC/sudo admission as assisted behavior.
- Review `CoreLocation.swift` independently for bundled read-only inventory;
  do not carry automatic `MACSEED_MAS_ADAPTER` injection into assisted execution.
- Preserve generic result/selection safeguards in RestoreModel/Tasks/View and
  relevant tests. MAS authorization, Recovery UI and helper Settings are separate
  automatic-path changes, not prerequisites for Assisted Restore.
- Do not copy the bootstrap helper-authorization bypass, prepare-mas build hook,
  helper targets or deployment requirements wholesale. Read-only MAS packaging,
  if retained, needs its own explicit product/build scope in the next stage.
- Rewrite current product documentation only when the assisted capability exists;
  historical roadmap claims here are not current requirements.
- Validate migrated Core/Preview/Verification and Desktop presentation with
  focused tests before any later commit. No functional tests were rerun merely
  to create this archive. System helper retirement and preserved unknown/evidence
  remain a separate authorized task, never an incidental effect of Git checkout.
