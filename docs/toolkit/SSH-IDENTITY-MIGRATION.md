# Secure SSH Identity Migration

Secure Migration v1 transfers explicitly selected existing SSH identities through
an encrypted package, separately from Discovery, Generated Configuration,
Blueprint and ordinary Bootstrap. Recommended one-Bundle integration is described
in [Capture / Restore](../CAPTURE-RESTORE.md). This reference owns the standalone
commands, key eligibility and encrypted package contract.

## Standalone commands

Run from the repository root with `age` and Python 3 available; these standalone
commands do not install prerequisites:

```bash
./scripts/ssh-identity-migrate.sh list
./scripts/ssh-identity-migrate.sh export --output /absolute/path/package.age
./scripts/ssh-identity-migrate.sh import --input /absolute/path/package.age
```

Export lists eligible pairs under `~/.ssh`, accepts terminal selection, shows the
selection and requires exact `export`. Existing output is never replaced.
`age` requests a new package passphrase through the terminal. Transfer privately
and keep the passphrase separate. Protected keys require their existing SSH-key
passphrase during pair validation. Confirmed incorrect passphrases get up to three
attempts before excluding that pair; other validation errors do not trigger retries.

Import decrypts, validates the complete package and shows a plan. Any conflict
blocks the whole transfer. Identical pairs remain unchanged. New pairs require
exact `import`; existing keys are never replaced. Verification checks local files
and key pairing, not network authentication.

For a manual migration, prepare dependencies/configuration separately. Homebrew
Discovery can select installed `age` as a formula; refresh Discovery if installed
later. Ordinary Bootstrap does not import identities automatically. Integrated
Bundle Restore instead invokes this same engine before dependent Workspace clones.
Application mode uses the [Core secret bridge](../core/APPLICATION-INTERFACE.md),
not terminal emulation.

## Keys and package

Eligible keys are direct user-owned OpenSSH Ed25519, RSA or ECDSA
nistp256/nistp384/nistp521 private files with matching `.pub`. Required modes are
`0600` private, `0600` or `0644` public, `0700` for `~/.ssh`. Symlinks, hard links,
FIDO keys, DSA, certificates, agent state, known_hosts and Keychain are outside v1.

### Manually selected Desktop sources

Desktop **Add SSH Identity…** accepts one explicitly chosen private file and its
adjacent `<name>.pub`, including files outside `~/.ssh` or outside HOME. It never
searches recursively, generates a public key or changes source permissions.
The standard `~/.ssh` scanner and standalone CLI selection remain unchanged.

Core requires canonical absolute paths (at most 1024 UTF-8 bytes), user-owned
regular files with one link, private mode `0600`, public mode `0600` or `0644`,
and at most 1 MiB per file. Every parent is opened without following links;
ancestors must belong to root/current user and prohibit group/other writes.
Root-owned sticky `1777` ancestors are allowed, but the immediate parent must be
user-owned without shared write access. Aliases, traversal, symlinks, hard links,
devices, sockets and FIFOs fail closed. File identities/content and parent identity
are checked during observation and bound to preparation, then rechecked at export
and before publication. Source files are never modified.

Names contain 1–80 ASCII letters, digits, dots, underscores or hyphens, starting
with a letter/digit. `.pub` names and SSH control names (`config`, `known_hosts`,
`known_hosts2`, `authorized_keys`, `authorized_keys2`, `environment`, `rc`) are
rejected case-insensitively. At most 32 combined candidates are allowed; duplicate
destination names (case-insensitive) or public fingerprints are rejected. Add and
Prepare validate the public pair metadata without unlocking; Execute reuses full
cryptographic pair validation, including protected-key challenges.

The default destination is `~/.ssh/<validated-name>` in the receiving HOME.
The existing encrypted v1 manifest authenticates the name and pair bytes; source
paths never enter the Bundle. There is **no format change** or second importer: legacy Bundles keep their
semantics, and older v1 CLI importers restore these packages to `~/.ssh`. Desktop
can optionally choose existing directories through the private mapping below. Missing `.ssh` is handled by
the existing importer; partial/differing/unsafe pairs block the transfer and target
changes invalidate Preview. No source-directory reconstruction is attempted.

SSH Configuration is not rewritten. Capture explains the destination before
publication; existing Preview/Result detail reminds users to review `IdentityFile`
if it expects another location. This is not evidence of a particular Host-profile
mismatch or restored network authentication. No host relationships are inferred.
Source references live only in the Capture session and private operation staging;
they are excluded from ordinary JSONL, logs, diagnostics, Blueprint and settings.
Keychain, agents, GPG, tokens, arbitrary files/directories and other sensitive-data
types remain outside this contract.

### Optional Desktop Restore directories

Secure Transfer remains default-off. Initial opt-in selects the entire encrypted
package. With negotiated selection support, the existing **SSH Keys** Customize
sheet can select an explicit subset by authenticated identity ID and retain a
destination for each key. Excluded keys remain in the Bundle and on the Mac;
their destination controls are inactive and their paths are not inspected.
**Customize…** in Rebuild Selection explicitly unlocks the Bundle and validates
all archive entries, manifest hashes, names and OpenSSH public/envelope metadata
before showing any identities. This read-only operation neither imports keys nor
requires protected-key passphrases. Execute performs full cryptographic pair
validation and protected-key prompts only for selected identities. Malformed
entries, manifest/hash mismatches and invalid public/envelope metadata anywhere
in the package still reject it, including excluded entries. Default whole-package
Restore requires no Customize step or extra unlock.

Each authenticated identity can use an existing directory chosen with the native
folder picker; **Use Default** restores `~/.ssh`. Private/public filenames never
change. The session mapping binds the complete identity set (including both file
hashes) to the selected Bundle bytes. It is not saved in the Bundle, Blueprint or
preferences. [Core](../core/APPLICATION-INTERFACE.md#private-restore-destinations)
owns the private operation transport and capability negotiation.

Custom paths must be canonical absolute paths, at most 1024 UTF-8 bytes, with no
symlinks/aliases or traversal. Core pins all directory components, requires
root/current-user ancestors without shared write access (root-owned sticky `1777`
ancestors are allowed), and an existing current-user-owned destination with owner
read/write/search and no group/other writes. Extended ACL grants are rejected;
deny-only ACLs retain their restrictions. Existing directories are never created,
chmodded or chowned. Only the legacy default `~/.ssh` may be created during Execute.
Existing pairs retain the same ownership, regular-file, single-link and mode checks.
Case-insensitive name collisions, partial, unsafe or differing pairs block the
selected subset before import. Conflicts at excluded targets do not block it.

Changing selection or destinations discards preparation, Preview and Secure Compare evidence.
Prepare binds directory identities; Compare inspects exact bytes at the selected
locations; Execute revalidates Bundle, identity set, directories and target evidence
before consent and publication. Matching pairs remain unchanged. Post-import
Verification covers only selected identities at their selected destinations.
Zero selection means no secure work: Desktop switches Secure Transfer off and
ordinary selected categories can continue. No empty import success is produced.
Customize retains choices; selecting the parent when the subset is empty explicitly
selects all keys again. Opening Customize never enables transfer.
Cancellation/failure keeps existing
no-clobber and best-effort cleanup of this attempt's own files; it is not an atomic
rollback across directories. SIGKILL or loss of power can leave partial/unknown state.

Custom paths do not rewrite `IdentityFile`, select SSH Configuration or establish
Host-profile dependencies. The UI retains unresolved-dependency guidance. Combined
SSH integration and Secure Check remain outside this slice.

The private mapping v2 adds explicit selection to the complete authenticated
identity inventory. Mapping v1 and standalone CLI retain whole-package behavior;
new clients require advertised selection support and older Core rejects v2
rather than importing everything. Bundle v1 and `secure.age` v1 are unchanged.

### Encrypted representation

The package is age passphrase ciphertext containing a tar with strict version-1
manifest. Member order is `manifest`, then ordered `keys/<name>` and
`keys/<name>.pub` pairs. Manifest magic is `toolkit-ssh-identities`, `version=1`,
`count=N`; each tab-separated pair record contains name, type, SHA-256 fingerprint,
private size/hash and public size/hash. Limits: 32 pairs, 1 MiB per file,
32 MiB per package. Keys retain their original encryption.

Export does not create a plaintext tar file; selected pairs stage privately under
`/private/tmp`. Import temporarily writes a plaintext tar there with `0600`.
Temporary directories are `0700` and cleaned on exit/SIGINT/SIGTERM. SIGKILL or
power loss can leave temporary files or an incomplete new target pair; inspect
`/private/tmp/ssh-migrate-*` and target names manually after such interruption.

Exits: `0` success/identical state, `1` cancellation/conflict, `2` validation,
dependency, encryption or publication error, `130` signal interruption.
