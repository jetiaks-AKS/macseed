# Homebrew Cask capability matrix

Configuration owns this domain contract; see [Configuration](CONFIGURATION.md).
This matrix describes the current provider in
`modules/apps/adapters/homebrew_cask.py`, not Homebrew's entire feature set.
Qualification is **primitive + state + ownership evidence**, never a cask-name
or version allowlist. Public `brew info --json=v2`, inventory and native macOS
observations are data. Homebrew alone performs installation and cleanup.

## State matrix

**S** = satisfied observable payload, **I/R** = installable when unregistered /
repairable when registered and both current install and installed cleanup qualify.
**C** = conflict / unproven ownership, **O** = observation failure,
**U** = unsupported capability, **A** = authorization prerequisite or qualified
native administrator authorization, **Q** = interrupted lifecycle quarantine.
These labels summarize existing provider states; they do not add a state machine.

| Current primitive | Valid / present | Missing | Damaged | Stale / orphan | Foreign ownership | Ambiguous ownership | Observation failure | Authorization | Installed/current evolution | Unknown privileged lifecycle |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| `app` | S: bundle ID and executable | I/R | Existing non-package damaged app: C; package-backed damage: R with exclusive receipts | Absent exact target: I/R; remaining unproven app: C | C, including wrong captured ID or symlink | C | O | A if destination not writable | R only with same replacement identity and installed appdir | Q |
| `suite` | S: nonempty valid members; captured member requirements retained | I/R | Existing partial non-package suite: C | Remaining unproven suite: C | C | C | O | A if destination not writable | Same artifact identity, target, appdir and bounded cleanup required | Q |
| Relocated bundles | S: bundle metadata, executable where required | I/R | Existing non-package bundle: C | Remaining unproven bundle: C | C | C | O | A if destination not writable; keyboard layouts use native authorization | Same artifact identity and exact replacement target required | Q |
| Relocated/static files and `artifact` | S: regular nonempty file at bounded declared target | I/R | Registered empty regular file: R if cleanup qualifies | Missing exact target: I/R | Symlink / unexpected type: C | Unprovable cleanup: C | O | A if destination not writable | Exact identity/target and installed cleanup required | Q |
| `binary`, `manpage`, static shell completions | S: owned symlink; executable check for binary | I/R | Owned dangling/non-executable link: R | Link inside exact Caskroom namespace or exact declared app source: R | Wrong source / ordinary replacement file: C | Unprovable source: C | O | A if destination not writable | Old/current artifact identities and targets required | Q |
| `command_wrapper` | S: executable symlink in exact cask namespace | I/R | Owned dangling/non-executable link: R | Owned cask-namespace link: R | Foreign link / regular replacement: C | C | O | A if destination not writable | Same wrapper identity/target; bounded executable, arguments and environment metadata | Q |
| Generated completions | S: regular nonempty outputs plus separately declared executable | I/R | Missing/empty outputs: R only with required provenance for remaining outputs | Existing outputs require matching Macseed-owned hashes during Repair | C | C | O | A if destination not writable | Generator, command, shell, format and targets must remain compatible | Q |
| `pkg` / `pkgutil` | S: exact receipts plus nonempty required real payload | Fresh I; registered missing required receipt: C | R with exclusive package ownership and qualifying old/current cleanup | Receipt alone never S; bounded missing payload can be R | Shared/unselected owners: C | C | O | Native administrator authorization | Changed archive/version allowed; exact cleanup receipt set and replacement evidence required | Q |
| `quit` | Exact declared bundle IDs; not a payload predicate | Bounded declared lifecycle accepted | Does not establish payload/ownership | Cannot alone authorize any orphan | Wildcards / non-ID selectors: U | Unprovable surrounding cleanup: C | Surrounding contract O | Homebrew owns quit behavior | Old/current declarations independently qualified; versions not compared | Q |
| `launchctl` | Exact loaded program + owned plist; shared LaunchAgents allowed in GUI/user domain | No service/plist: accepted | Malformed evidence: O; incompatible ownership: C | Inactive service beneath exact missing app, installed declaration or exact current-declared native XPC identity/path, no conflicting plist: R | Outside expected payload: C | Multiple concrete domains / fallback-only identity: C | O; malformed inventory cannot mean absence | System daemon/plist requires native authorization; plistless system orphan: C | Both old and current cleanup qualified; new orphan identity requires direct native XPC evidence; otherwise C | Q; live unproven orphan: C |
| `login_item` | Unique declared identity pointing at exact expected app | Absent identity: accepted | Concrete different target: C | Observed unavailable target + exact missing app + installed declaration: R | Different concrete app: C | Duplicate name / multiple expected apps: O/C | O, separate from ownership conflict | Automation denial/consent unavailable is readiness; Preview never asks | Both lifecycle contracts qualified; missing-target orphan requires installed declaration | Q if surrounding native lifecycle is unknown |
| `delete`, `trash`, `rmdir` | Exact declared payload/package file or proven app-owned link | Bounded exact absent target accepted; absent system preference plist is a declared effect | Only within existing ownership contract | No arbitrary service/file cleanup or inferred namespace | C | C | O | `delete` or unwritable parent uses native authorization | Old/current cleanup independently qualify; no glob/parent deletion contract | Q |
| Conflicts / dependencies / platform | Exact public inventories, declared cask/formula dependencies and numeric platform constraints | Homebrew may install qualified dependencies | Broken registered cask dependency: C | Unprovable dependency/ownership: fail closed | Declared installed conflict: C | Cycles/unbounded declarations: U | O | Privilege of qualified dependencies propagates | Compatible metadata evolution allowed; incompatible platform/identity blocked | Q |

Relocated types are the explicit existing set: `app`, `suite`, `font`,
`colorpicker`, `dictionary`, `input_method`, `internet_plugin`, `keyboard_layout`,
`prefpane`, `mdimporter`, `qlplugin`, `screen_saver`, `service`, `audio_unit_plugin`,
`vst_plugin`, `vst3_plugin`. Static completions cover bash, zsh, fish and PowerShell.
No arbitrary new artifact or lifecycle types are enabled by this matrix.

## Closed gaps and preserved limits

Previously every loaded launch service needed a normal plist, even an inactive
XPC service whose exact app had disappeared. The bounded orphan contract now
requires one concrete user/GUI domain, one program, an inactive state without a
PID, a structural `Contents/MacOS` or `Contents/XPCServices/*.xpc/Contents/MacOS`
relationship to the exact absent app, and installed lifecycle identity evidence.
A current-only declaration additionally requires native `type=XPCService`, an exact
`bundle id` equal to the selected service label, and a `path` binding the XPC
bundle to its observed program. It cannot qualify an ordinary undeclared service.
All normal plist locations are enumerated, including alternate filenames with the
same Label. Unrelated malformed/unreadable records do not poison selected labels;
a selected canonical plist or selected service record remains required evidence.
Explicit GUI/user/system service tables define membership; Mach endpoints and the
caller-dependent implicit `launchctl list` are not service ownership evidence.
A conflicting plist, live service, system orphan, malformed inventory
or ambiguous domain prevents Repair. The observer never unloads a service.

Previously a declared login item with an unavailable target was conflated with a
foreign target. Repair now requires an installed declaration, one exact expected
app and its absence. An arbitrary matching name is insufficient. Duplicate
identities, concrete foreign targets and an existing app with unavailable login
item target remain fail closed. Homebrew performs any login-item cleanup.

Automation is checked using public
[AEDeterminePermissionToAutomateTarget](https://developer.apple.com/documentation/coreservices/aedeterminepermissiontoautomatetarget(_:_:_:_:))
with `askUserIfNeeded=false`. The permission check and read-only AppleScript use
public OSA APIs in the same sender process. Denial/consent-required results are
readiness requirements; unavailable System Events and malformed results are
observation failures. Desktop requests consent only during user-initiated **Check Again** when the
nonprompting permission check reports undetermined consent, then automatically
rechecks Preview. Already authorized access needs no prompt; denied/restricted
access remains actionable without repeated consent prompts. Real TCC sender attribution and
orphan convergence still require the manual gate; automated tests use fixtures.

The existing provider result may carry a bounded
`diagnostic: {primitive, condition}`. It contains no paths, free text or raw tool
output. Preview rows and matching readiness conditions preserve it through
Protocol V1; planning identity includes it. Desktop shows readable guidance,
with reason/context behind disclosure. Stable top-level reasons are retained.

Remaining limits are intentional: no arbitrary scripts/flight blocks, wildcard
cleanup/receipt selectors, force/adopt/zap, arbitrary service removal, or repair
of an existing damaged relocated payload without a sufficient ownership contract.
Generated-completion integrity, package ownership, selected-item skips,
dependencies, watchdog and unknown-consequence quarantine remain unchanged.

[Homebrew's public Cask Cookbook](https://docs.brew.sh/Cask-Cookbook) defines the
upstream artifact/lifecycle surface; it does not prove that every primitive or
state is safe for Macseed. Registration and empty predicates never prove payload.
Final Core Verification and a fresh Preview establish convergence.

Preview and readiness report every selected cask independently. A primitive
failure blocks only casks requiring that primitive; the execution gate still
stops before mutation. Login-item Automation is inspected only when the selected
repair lifecycle requires it.

### Clean native package installation

Supported `pkg` Install treats public Homebrew caveats as installation information,
retained in the bound execution requirements, rather than requiring Repair cleanup
capabilities. Uninstall-only directives are not executed or qualified for Install;
Repair still qualifies both historical and current cleanup. This does not qualify
Rosetta requirements, executable Cask installers,
unknown artifacts or system-extension activation. Exact package selectors must have
no receipts, and expected payload plus declared delete targets must be absent; existing state is never
adopted or cleaned by Install. Native installer authorization remains separate from
support. Homebrew owns package scripts, which may launch applications or present
vendor dialogs; package installation does not promise unattended application setup.
If source predicates are unavailable, Preview downloads the checksum-bound package
and inspects it with public `pkgutil --expand-full` in private temporary storage;
no scripts or installer are executed. The bounded fallback accepts exact selected
receipt IDs and root `.app` installation locations in `/Applications`, with valid
source bundle identity/executable. It rejects other layouts and uses 128 MiB download,
60-second transfer, 8192-entry and 512 MiB expanded-size limits. Network/inspection
failure blocks only the affected package. Temporary data is removed after inspection.
Verification requires receipt-backed typed payload observation on disk, never cask
registration or a receipt alone. Captured source payload predicates add stronger
pre-install postconditions where available. Repair with unresolved caveats remains
unsupported; extension/VPN activation and license conditions remain vendor/user work.
