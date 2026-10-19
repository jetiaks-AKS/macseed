# Archived MAS 7.0.0 build inputs

Source: https://github.com/mas-cli/mas, tag `v7.0.0`, commit
`7c70ffdfd9f71a654300a78b3b627782e6abe1b4`.

`swift64.patch` is the original two-line compatibility patch, byte-for-byte.
`Package.resolved` is the unchanged upstream dependency lockfile. `manifest.json`
retains the four original build/provenance hashes; local runtime inventory facts
are deliberately omitted. No MAS executable, certificate private key, or runtime
journal is stored here.

Historical build procedure: use Xcode 27.1 / Swift 6.4 and a clean checkout of the
exact source commit. Apply `swift64.patch` once after `git apply --check`, verify
the lockfile hash, then run `Scripts/build '' -c release --force-resolved-versions`.
Warnings-as-errors remain enabled. No Homebrew source or wrapper is needed.
Copy `.build/release/mas` to a fresh staging directory before binary modification.
Inspect load commands; the reviewed build removed these two LC_RPATH entries:
`/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift-6.2/macosx`
and `@loader_path`, retaining `/usr/lib/swift`. Sign the staged copy with the
reviewed Apple Development identity, Hardened Runtime, timestamp disabled, and
identifier `org.macseed.development.bundled-mas`. Inspect architecture, dependencies,
RPATH and code signature before considering execution. The historical artifact
is arm64 only. No installation command is part of reproduction.

Reproduction of the source build is distinct from reproducing the exact signed
artifact. A new signature/toolchain may change its hash. Existing production
trust pins must not be bypassed to accept a different artifact. The archived
`prepare-mas.sh` still expects a separately reviewed external artifact directory
containing `mas`, `manifest.json`, `swift64.patch`, and `REPRODUCE.md`; select it via
`MACSEED_MAS_ARTIFACT_DIR`. Signing identity and artifact pins remain prerequisites.
An ordinary Debug build may omit privileged MAS when those inputs are unavailable.
No independently reproduced binary or clean-Mac qualification is claimed.
