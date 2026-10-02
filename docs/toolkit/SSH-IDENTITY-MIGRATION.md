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
