# Macseed Configuration

This reference owns Generated Configuration, Blueprint, Bundle data formats and
domain producer/consumer contracts. [Capture / Restore](../CAPTURE-RESTORE.md)
owns the workflow; [Core](../core/APPLICATION-INTERFACE.md) owns application
execution restrictions and Protocol V1.

## State model

```text
Discovery → Generated Configuration + Blueprint Desired Selection
          → Selected Supported State → Preview / Bootstrap / Verification
```

Observed State is discovered supported state. Generated Configuration represents
its machine-specific values; Blueprint selects categories/items without copying
or overwriting those values. Consumers apply only selected supported requirements.

## Bootstrap Bundle v1

Capture creates a private `bootstrap-*.mbt` tar archive using `MBT-BUNDLE-1`,
with `manifest.json`, `blueprint.conf`, supported `generated/` files and optional
`secure.age`. Manifest format version is `1`; it records file names, sizes and
SHA-256 checksums. Validation detects corruption/incompleteness, not authenticity.
Archive validation rejects unsafe paths, links, unexpected members and malformed
content. Current bounds are 48 MiB per archive, 33 MiB per member and 32 entries.

Allowed generated content covers Homebrew, App Store, VS Code extension inventories
and selected Git, Workspace folders/repositories, SSH configuration, Zsh,
VS Code settings and macOS settings. `workspace.conf`, `vscode-workspaces.conf`
and `inventory.conf` have no restoration consumer and are excluded. Unselected
inventory entries are omitted unless digest-bound completeness requires retaining
the full inventory for Comparison. Retained inventory never expands Apply.

Capture stages Discovery, Blueprint and Preview privately; it does not replace
ordinary source state. Source selection is the Restore ceiling. Restore can
disable groups, including VS Code Settings independently, but cannot add missing
categories/items. Programs, working trees and user data are not archived.

The Bundle is `0600`, staging directories `0700`. Normal configuration is
unencrypted and may expose personal data. Only explicitly selected SSH pairs
are encrypted in `secure.age`. Before unlocking, validation establishes ciphertext
presence, header, size and checksum; plaintext package validity requires `age`
and the passphrase. Keys retain their original encryption. See
[Secure SSH Identity Migration](SSH-IDENTITY-MIGRATION.md) for package details.

### Paths and publication

Workspace repository paths inside source HOME become relative HOME paths in the
Bundle and are validated under target HOME on Restore. Folders create structure;
repositories are cloned from recorded remotes. Screenshot destinations inside
source HOME become `~/`; an external absolute destination blocks Capture of that
selected category. Git identity, SSH remote users and arbitrary Zsh/VS Code values
are not rewritten. Arbitrary Zsh/VS Code content is not guaranteed portable.

Restore validates the archive and previews staged input before replacing local
state. After confirmation, `config/generated/` and `config/blueprint.conf` are
published with a private recovery copy and pending marker. They are two paths,
not one filesystem transaction. Failure before committing the new pair restores
the previous pair; after commitment, recovery removes the marker. A later CLI
Restore recovers known state before selection/Preview, or stops on ambiguity.
Application Prepare instead reports `recovery_required` without recovery.

Publication recovery does not roll back target installs/settings/imports.
After publication, ordinary Workflow uses local state and no longer needs the
Bundle. Partial generated state is valid for the saved selection; missing
unselected domains are allowed, selected required input blocks continuation.

## Generated Configuration

`config/generated/` is private local derived state, excluded from Git. It may
contain personal paths, Git identity, repository URLs and application settings.
It is not a credential vault. Producers must not intentionally publish passwords,
tokens, private keys or credential-bearing URLs. Opaque VS Code/Zsh snapshots
can still contain sensitive content; their checks do not prove absence of secrets.
Review and protect data before transferring it.

Exporters use **Collect → Validate → Serialize → Safe Publication**. A generated
file is replaced only after preparing valid new state. Handled collection,
serialization or publication failure preserves the previous valid file.
Most files publish independently. Workspace metadata `workspace.conf` is
independent; `folders.conf`, `repositories.conf`, `vscode-workspaces.conf` and
`inventory.conf` are a grouped snapshot published together.

Configuration is data, never shell code: generated content is never `source`d or
`eval`uated. Use the domain's existing reader, including the Configuration Engine
for sectional Workspace files and native Git parsing for `git.conf`.

## Blueprint

Private `config/blueprint.conf` stores Desired Selection and is excluded from Git.
See [blueprint.example.conf](../../config/blueprint.example.conf) and the
[Blueprint module guide](../../modules/blueprint/README.md) for structure and
selector behavior. Item sections select inventories; category flags select settings.

Normal Workspace Folder candidates are exactly `workspace`-classified records.
Observed `user`/`system` folders remain generated data. Saving normalizes legacy
choices; cancellation preserves the original Blueprint.

Absent Blueprint retains all-inclusive compatibility for supported generated
scope. Malformed Blueprint returns `2` and blocks mutation; stale selection
warns with `1`. Old Blueprints without `macos-windows`, `shell-zsh` or
`ssh-configuration` remain valid with those categories disabled until saved anew.

## Common consumer contract

Validate all required input for the selected scope before its first mutation.
Missing, unreadable or malformed required input returns `2`; optional input uses
warning/skip only where defined below. Empty/disabled scope does not require
unrelated files. Observation failure is distinct from confirmed absence or mismatch.
Apply only confirmed actionable changes and verify them where observable.
Matching supported state is no-op. CLI uses `0` success, `1` warning, `2` error;
application prerequisites/exits have their own Core contract.

## Shell / Zsh configuration

Only `$HOME/.zshrc` is supported. Discovery reads it as data without prompting.
Readable eligible regular files are `eligible`, confirmed absence is `absent`.
Symlinks, external ownership, sensitive assignments/credential URLs, absolute
`/Users/<name>/`, `/opt/homebrew` or `/usr/local` paths, external `source` / `.`,
`eval`, command substitution and unsupported type/content produce `excluded`.
Reasons are `external-owner`, `sensitive-content`, `portability`, `dependency`,
`unsupported-source`. Read/observation errors return `2` and preserve the old
snapshot. Static checks detect known risks, not every secret/dependency/side effect.

`config/generated/shell/zshrc.snapshot` contains `MBT-ZSHRC-1`, `status`, `reason`,
`length`, `sha256`, separator `---`, then exact `.zshrc` bytes only for eligible
state. Absent/excluded states have no payload. Length/hash are validated before
use; a malformed selected snapshot returns `2`. Publishing absent/excluded
replaces an earlier eligible payload. Snapshot mode is `0600`. Discovery,
validation, Preview and Verify never execute it.

Blueprint category is `shell-zsh`. Without Blueprint, an older generated tree
with no snapshot skips the domain; explicit selection requires the snapshot.
Selected absent/excluded state warns and offers no restoration. Preview never
prints content, commands, addresses or values.

Bootstrap creates `.zshrc` only for confirmed absence and safe HOME, with `0600`
staged publication. Verify checks bytes, type, ownership and mode without Zsh.
An identical regular target is preserved including its mode; a different file
warns without backup, merge or replacement. Symlink/unexpected type/observation
error blocks creation. Other Zsh startup files, sourced trees, frameworks and
automatic HOME/Homebrew-prefix rewriting are unsupported.

## macOS settings

Records are `domain|key|type|value`. Types are `bool`, `int`, `string`, with
integer/float compatibility specifically for Dock size properties according to
the plist. `modules/settings/macos/records.sh` supplies shared category-aware
validation before Discovery publication, startup and consumption. File names do
not determine allowed keys.

| Category | Domain | Keys / type |
|---|---|---|
| Finder | `NSGlobalDomain` | `AppleShowAllExtensions` / bool |
| Finder | `com.apple.finder` | `ShowPathbar`, `ShowStatusBar`, `_FXSortFoldersFirst`, `FXRemoveOldTrashItems` / bool; `FXPreferredViewStyle`, `FXDefaultSearchScope` / string |
| Finder | `com.apple.finder` | `AppleShowAllFiles`, `ShowHardDrivesOnDesktop`, `ShowExternalHardDrivesOnDesktop`, `ShowMountedServersOnDesktop`, `FXEnableExtensionChangeWarning` / bool; `NewWindowTarget` / string enum |
| Dock | `com.apple.dock` | `autohide`, `show-recents`, `magnification` / bool; `tilesize`, `largesize` / int or float according to plist |
| Dock | `com.apple.dock` | `orientation`, `mineffect` / string enum; `minimize-to-application`, `show-process-indicators`, `launchanim`, `mru-spaces` / bool |
| Window Management | `NSGlobalDomain` | `AppleActionOnDoubleClick`, `AppleWindowTabbingMode` / string enum; `NSCloseAlwaysConfirmsChanges`, `NSQuitAlwaysKeepsWindows` / bool |
| Window Management | `com.apple.WindowManager` | `HideDesktop` / bool |
| Keyboard | `NSGlobalDomain` | `KeyRepeat`, `InitialKeyRepeat`, `AppleKeyboardUIMode` / int |
| Keyboard | `NSGlobalDomain` | `ApplePressAndHoldEnabled`, `NSAutomaticCapitalizationEnabled`, `NSAutomaticSpellingCorrectionEnabled`, `NSAutomaticPeriodSubstitutionEnabled`, `NSAutomaticQuoteSubstitutionEnabled`, `NSAutomaticDashSubstitutionEnabled` / bool |
| Trackpad | `com.apple.AppleMultitouchTrackpad` | `Clicking`, `TrackpadRightClick` / bool |
| Screenshots | `com.apple.screencapture` | `location` / string with path policy below |

Unknown/cross-category keys, wrong types, duplicate domain/key pairs, wrong field
counts, ASCII control bytes including NUL, delimiters inside values and multiline
scalars return `2`. Bytes are checked before shell parsing, without silently
losing meaningful trailing newlines. Bool accepts `0/1/true/false`; int accepts
an optionally negative integer. No unproven ranges or general float contract
are introduced.

Blank/whitespace-only lines and empty category files are valid; the final record
without newline is processed. Absent source preference creates no record;
absent record never removes a target setting. Empty ordinary strings differ from
absence; empty paths/enums are invalid. Validation failure preserves the previous
snapshot. Consumers verify stored typed values, not visible application effects.

### Finder

`macos-finder` accepts old seven-record files and empty files. `NewWindowTarget`
accepts only `PfCm`, `PfVo`, `PfHm`, `PfDe`, `PfDo`, `PfAF`. `PfLo` and
`NewWindowTargetPath` are unsupported. Consumers reject invalid enum input before
observation/mutation. Discovery skips safe unsupported enums with warning `1`
while publishing other valid records; read/native-type/unsafe-scalar errors return
`2` and preserve the old file. Absent keys remain unmanaged.
Preview plans one restart for changes; Apply restarts Finder at most once after
successful changed writes. Matching state causes neither writes nor restart.

### Dock

`macos-dock` preserves old five-record and empty-file compatibility.
`orientation` accepts `left/bottom/right`; `mineffect` accepts `genie/scale`.
Invalid/empty enums are rejected by consumers; safe unsupported source enums
are skipped with warning. Observation/type/scalar/candidate errors preserve the
old snapshot with `2`. Preview plans one restart; Apply restarts Dock at most
once after successful changed writes. Dock items (`persistent-apps`,
`persistent-others`, `recent-apps`), hot corners and other Mission Control/Spaces
settings are unsupported.

### Window Management

`macos-windows` uses `macos/windows.conf` for the five allowed preferences.
`AppleActionOnDoubleClick` accepts `Minimize/Maximize/Fill/None`;
`AppleWindowTabbingMode` accepts `manual/always/fullscreen`. Other/empty values
are rejected by consumers; safe unsupported source enums warn and are skipped.
`HideDesktop=true` hides standard Desktop items; false shows them. Preview uses
semantic hide/show messages. Absent preferences remain unmanaged.
`NSQuitAlwaysKeepsWindows` transfers without inversion; System Settings' “Close
windows when quitting an application” switch has the inverse meaning.
No process restart or visible-effect guarantee applies. Tiling, wallpaper-click
Desktop behavior, Dock items and Menu Bar/Control Center configuration are unsupported.

### Keyboard

`macos-keyboard` preserves old two-record and empty-file compatibility.
`AppleKeyboardUIMode` uses integer normalization without an added range;
switches use bool. Discovery serializes present valid preferences and validates
the whole candidate. It does not synthesize Apple defaults. Errors preserve the
old file with `2`. No process restart or live-effect guarantee applies. Shortcuts,
input sources/layouts, dictation, text replacements, per-app and hardware-specific
keyboard configuration are unsupported.

### Trackpad

`macos-trackpad` supports only Apple trackpad `Clicking` (tap-to-click) and
`TrackpadRightClick` (secondary click) as bool. Absence remains unmanaged;
observation/type/validation error preserves the old snapshot with `2`.
There is no restart, immediate-effect, external Magic Trackpad, Bluetooth/ByHost
or all-device restoration guarantee. Legacy
`NSGlobalDomain|com.apple.trackpad.scaling|int|...` is rejected before mutation;
refresh it through Discovery. Speed, Natural Scrolling and extra gestures lack
a proven effective-restoration contract and are unsupported.

### Screenshots

The sole destination source is `location` in `macos/screenshots.conf`; there is
no static `SCREENSHOTS_DIR` fallback. An absent record creates no directory.

- Accept absolute paths and leading `~/` resolved under current HOME; compare and
  store the resolved absolute path.
- Reject `$HOME`, `${HOME}`, other variable expansion, backticks, backslashes,
  relative paths, `~otheruser`, empty values, `.`/`..`, repeated `/`, control bytes
  and `|`. No general shell expansion occurs.
- Create missing directories/parents only inside HOME after validating the whole
  path and existing components. Files, inaccessible components, dangling/looping
  symlinks and symlink escapes return `2`.
- Existing directory symlinks inside HOME require their physical target to remain
  inside physical HOME. Outside-HOME destinations must already resolve to an
  accessible writable directory; external symlinks are allowed on those terms.
- Missing `/Volumes/...` is an error, not permission to create a mount point.
  No chmod/chown or silent `/Users/old-user` rewrite occurs.
- Destination requires write/execute access. Observation failure is not absence;
  path checks are not a race-free sandbox.

Preview distinguishes directory creation, preference write and restart, in that
order. Directory-only change needs no SystemUIServer restart. Prepare/verify the
directory before writing the preference; failure blocks the write. Restart only
after preference change. Verification does not take a real screenshot.

## Homebrew formula generated state

`brew-packages.conf` has one formula name per line. Names may be short or
`owner/tap/formula`; every component starts with an ASCII letter/digit and then
uses letters, digits, `+`, `_`, `.`, `@`, `-`. Reject whitespace, option-like
values, paths, URLs and `.rb` references. Empty lines, comments starting with `#`
and a final line without newline are supported.

Validate the entire required list, including unselected entries, before install.
Missing/unreadable/invalid files block installs; empty Blueprint scope requires
neither this file nor Homebrew. Presence comes from successful
`brew list --formula --full-name`: short names match a formula identity, qualified
names match the exact tap. Ambiguous names and inventory errors block install.
Check presence again after installation.

## Other application generated inputs

After complete publication of `brew-casks.conf`, `appstore.conf` or
`vscode-extensions.conf`, Discovery publishes
`provenance/<domain>.sha256` containing `complete <sha256>` for the exact full
inventory bytes. Empty inventory can be complete. Missing, invalid or mismatched
markers mean unknown completeness; legacy state remains compatible. Capture
retains these inventory/marker pairs even with narrower selection, preventing
excluded source items from becoming false extras. Without a marker, transfer is
selected-only. Formulae get no marker because Discovery exports only the
installed-on-request subset.

All three lists accept blank lines, leading-`#` comments and final entries without
newline. Read/validate the entire required file before observing/installing; a
late invalid entry cannot allow partial application of earlier entries.

| File | Entry contract |
|---|---|
| `brew-casks.conf` | Short token, ASCII letter/digit followed by letters/digits/`+`/`_`/`.`/`@`/`-`. No slashes, URLs, option-like tokens, tap-qualified syntax, or `.rb/.json/.sh/.bash/.zsh/.dmg/.pkg/.zip` endings |
| `appstore.conf` | Exactly `ID\|name`; ASCII numeric ID, nonempty name without leading `-`, edge whitespace, controls or extra `\|`. Internal spaces, Unicode and punctuation remain |
| `vscode-extensions.conf` | Exactly `publisher.extension`; each part starts with ASCII letter/digit followed by letters/digits/`_`/`-`. No paths, URLs, versions or local `.vsix` references |

Empty Blueprint scope needs neither the file nor CLI. Nonempty scope validates
the whole required file before filtering; unrelated files are not required.
Invalid input takes precedence over missing CLI. In the ordinary CLI consumer,
missing `mas`/`code` warns; missing Homebrew errors. Application readiness is
stricter and belongs to the Core reference.

App Store presence uses exact ID, VS Code exact case-sensitive extension ID.
Inventory errors are not absence; exact presence is verified after installation.
Cask presence requires public Homebrew registration and nonempty typed payload
predicates. Apps require valid bundle metadata/executables, links require owned
sources, and packages require exact macOS receipts plus actual required payload.
An empty observation set or receipt alone never proves satisfaction. Optional
`homebrew-casks.json` captures selected requirement identities and portable package
postconditions; registration with missing payload remains explicitly different.
Native Install/Repair qualification separately checks installation, historical
cleanup, ownership, requirements and privilege. Homebrew owns all lifecycle writes.
Unknown observation is not absence; unknown execution behavior fails closed.
See the [execution policy](../core/APPLICATION-INTERFACE.md).

## Workspace Bootstrap actionability

`workspace/folders.conf` uses `folder|classification`;
`workspace/repositories.conf` uses sections with `NAME`, `PATH`, `REMOTE`,
`CURRENT_BRANCH` and Discovery metadata. Apply uses `CURRENT_BRANCH`, not `BRANCH`.
`workspace.conf` describes observed source HOME; target root remains current HOME.
Workspace Folders recreates directory structure only, not user file contents.
Folder Discovery currently classifies immediate children of HOME; configurable
discovery roots and bounded useful unique-data transfer remain future investigations,
requiring explicit product/safety contracts rather than a general backup engine
([TODO](../../TODO.md#broad-restore-manual-gate--2026-10-05)).

Validate both required inputs and build a full selected snapshot before any
Workspace mutation. Use the Configuration Engine for sections/values, reading
section IDs with spaces line by line. Final lines without newline and blank lines
are supported; no new comment/escaping syntax is added.

Selected folders accept simple/nested relative paths including spaces. Reject
absolute paths, empty components, `.`/`..`, controls and existing symlink escapes
from HOME. Repository `PATH` must be an absolute descendant of current HOME under
the same rules; existing components must be directories.

The snapshot validator checks structure. Selected `NAME`, `REMOTE`,
`CURRENT_BRANCH` must be nonempty; controls and ambiguous action-field quotes are
invalid. Backslashes in section IDs are unsupported by the Configuration Engine.
Remotes retain SSH/scp, URL and local-path forms; reject empty/option-like values,
edge whitespace and empty URL/scp components without network requests.
Discovery strips HTTP(S) userinfo without preserving credentials; query/fragment
or unsupported userinfo excludes the repository with warning. Ordinary SSH/scp
usernames remain. Workspace generated directory mode is `0700`; grouped files
are `0600`. Validate branches locally with `git check-ref-format --branch`,
rejecting option-like values and shorthand requiring Git expansion.

Required-input error, including a late bad entry, blocks mkdir/clone/checkout.
Empty scope does not require its file. Validate whole-file structure and selected
item actionability. Create folders only on confirmed safe absence; wrong type,
unsafe links and access error block `mkdir -p`. Verify created directories; matching
ones are unchanged. Folder failure blocks repository restoration.

### Workspace repository inspection

Check access to the existing destination ancestor before clone. An existing
non-Git directory is a conflict. `.git` directories/worktree-files require successful
`git rev-parse --is-inside-work-tree`; Git/access errors return `2`.
Origin mismatch warns without replacement; failed origin read, including missing
origin, blocks action. Successful empty `branch --show-current` means detached
HEAD, permitting safe branch restoration after confirming clean state. Failed
branch reads are not mismatches.

Clean-state checks use both tracked/staged `git diff --quiet` forms. Untracked
files are not a new dirty criterion; Git may refuse conflicting checkout and
those files remain intact. Observation errors block that repository's action.
Clone only on confirmed absence; verify destination/worktree/exact origin.
Checkout only on confirmed branch mismatch or detached HEAD with clean state;
verify exact `CURRENT_BRANCH` afterwards. Failed observation or mismatch is an
error. No reset, clean, forced checkout or automatic remote change occurs.

## VS Code settings lifecycle

`vscode/settings.json` is an optional byte-for-byte snapshot. Missing source
warns with `1`; existing source must be a readable regular file or returns `2`.
Contents, including JSONC comments, are not transformed or newly JSON-parsed.

Read source fully before Apply; `cmp` distinguishes equality, absence/difference
and observation error. Equal state changes no directories, backup or settings.
On difference, create missing destination directories, preserve existing settings
in `settings.json.bootstrap.bak`, then publish the new file.
Copies stage beside destination and publish by rename, avoiding truncated files.
Handled errors clean temporary files. Differing settings symlinks and backup
symlinks are not replaced; an equal settings symlink remains valid no-op.
If backup publication succeeds but settings publication fails, preserve the backup
and intact original settings. Verify exact bytes after publication.

## Git generated state

`git.conf` is native non-executable Git config containing only `user.name`,
`user.email`, `init.defaultBranch`, `pull.rebase`, `core.editor`,
`user.useConfigOnly`, `pull.ff`. Read via `git config --file ... --no-includes`;
reject unknown/duplicate keys, never execute the file.

Discovery reads direct global-file entries with origin checks. `include`/
`includeIf` in `~/.gitconfig` or XDG global files makes the category externally
managed: Discovery publishes an empty snapshot with warning; target Preview/
Bootstrap preserves such configuration. Included files are not transferred.
Ambiguous keys across direct global files are excluded at source and block target
action. `GIT_CONFIG_GLOBAL`, symlinks and foreign ownership block automatic Apply.

Absent key means unmanaged, not deletion. Category is `git-configuration`;
optional same-named item section selects individual keys. An absent item section
in an old Blueprint selects all present keys; an explicit empty section selects
none. Stale absent-key selection warns without deletion. Without Blueprint all
present supported keys participate.

`user.name`/`user.email` must be nonempty single-line control-free strings.
Git validates `init.defaultBranch`. `pull.rebase` accepts
`true/false/merges/interactive`; `user.useConfigOnly` accepts `true/false`;
`pull.ff` accepts `true/false/only`. Discovery normalizes Git-valid boolean forms.
`core.editor` supports only `vi`, `vim`, `nano`, `nvim`, `code --wait` when the
executable is available in PATH; it is neither run for testing nor installed.

Preview shows keys, not values. Bootstrap creates only selected missing direct
global entries and verifies value/origin. Matching state is no-op; differing or
multiple values and unavailable editors warn and preserve the target. Observation
failure blocks mutation; unrelated entries remain. Ordinary Bootstrap does not replace values.

Bundle Restore plans `set_setting` for selected differing scalars and restores the
saved value in its unique validated physical origin. It re-observes count/value/
origin before writing with native Git fixed-value matching, then verifies the
saved value and single origin. Matching values are no-op; unselected keys remain
untouched. Multiple values/origins, includes, externally managed files, unavailable
saved editors and observation errors retain their existing protections. Restore
never removes keys or changes Capture semantics.

## SSH configuration

`ssh/config.snapshot` is a `0600` versioned snapshot of canonical supported Host
profiles. Discovery reads only `~/.ssh/config` as data and publishes atomically;
read/parse failure preserves the previous snapshot. `Include`, `Match`, global
settings and ambiguous Host patterns exclude the entire source. An unsupported
directive in an independent Host block excludes that block.

Supported profiles have one literal `Host`, required `HostName`, and optional
`User`, `Port`, `ServerAliveInterval`, `ServerAliveCountMax`, `TCPKeepAlive`,
`ConnectTimeout`. Category is `ssh-configuration`. Preview exposes only profile
counts/warnings, not addresses, users or aliases.

Bootstrap creates `~/.ssh` (`0700`) and `config` (`0600`) only if target config is
absent, using no-clobber publication and byte/metadata verification. Differing
existing files, symlinks and foreign ownership are preserved. Keys, certificates,
known_hosts, authorized_keys, Keychain, agent and credential references are not
part of SSH configuration restoration; connection/authentication is not tested.
Explicit identity transfer belongs to Secure Migration. Partial supported Host
snapshots can verify matching target profiles without weakening Preview/Apply
conflict rules.

## Selected-state consumers

Bootstrap validates Blueprint and required selected inputs before preflight/Core
checks. Empty scopes do not introduce unrelated requirements. Preview uses the
same input/selection contracts without Apply. Global Verification observes selected
results after Bootstrap/Workflow/applicable Restore. Explicit Comparison projects
existing Verification/Coverage facts without a second configuration model or target
mutation. Architectural responsibilities are in [Architecture](ARCHITECTURE.md).
