# Internal Shell structural parser

This reference owns the native helper interface and its protected Core caller. The
[Shell configuration contract](../toolkit/CONFIGURATION.md#shell--zsh-configuration)
owns product behavior. The helper does not enable Functions migration, change
Aliases & Scripts v5 or serialize `shell-state:1`; the separate
[B1 codec foundation](../toolkit/CONFIGURATION.md#typed-shell-state-foundation-b1)
consumes its structural evidence; [B2B Capture](../toolkit/CONFIGURATION.md#functions-capture--bundle-b2b)
publishes explicitly selected Functions. [B3 Restore/Check](../toolkit/CONFIGURATION.md#functions-restore-verify--check-b3)
reuses the same parser for independent saved-definition and target admission.

## Ownership and pinned dependencies

`modules/shell/parser/helper.c` belongs to Shell Core, not SwiftUI. It uses only
Tree-sitter's parsing API. It does not execute, source, expand, format or rewrite
Shell text; read referenced paths; discover tools through PATH; decide eligibility;
or send logs/events. One invocation handles one source with the fixed
`zsh-default-1` profile, without fallback or an extended-glob mode switch.

Vendored upstream archives and MIT notices are in `modules/shell/parser/vendor/`.
The runtime archive also contains the required Unicode/ICU notice at
`lib/src/unicode/LICENSE`; the build copies its exact bytes into each package.
`pins.json` records source URLs, revisions and SHA-256 archive hashes:

| Component | Version | Revision |
|---|---|---|
| [konomanoasa/tree-sitter-zsh](https://github.com/konomanoasa/tree-sitter-zsh/tree/17651db6e3a413b22e148c8a57726d4b392d10f7) | 0.8.0 | `17651db6e3a413b22e148c8a57726d4b392d10f7` |
| [Tree-sitter runtime](https://github.com/tree-sitter/tree-sitter/tree/3fb7be49145acfb07e33b61ed5689e2b6771b2e9) | 0.27.2 | `3fb7be49145acfb07e33b61ed5689e2b6771b2e9` |

The grammar ABI is 15. The build verifies archive hashes before extraction,
compiles the default `src/parser.c`, scanner and C runtime without changing vendor
code, and preserves notices. Although the source archive also contains upstream's
other grammar, it is never compiled or selected. Dependency updates follow the
[bundled dependency maintenance policy](../DISTRIBUTION.md#bundled-dependency-maintenance).

## Private interface

Invoke the exact bundled `Contents/Helpers/macseed-shell-parser` executable with
no arguments. Send original UTF-8 source bytes on stdin and close it. No paths or
source text belong in argv or environment. `--version` returns fixed build/profile
identifiers and performs no parsing. Unknown arguments fail closed.

Stdout contains one bounded JSON object plus LF. Exit `0` means complete structural
success; exit `2` means rejection. A successful response contains:

```json
{"schema":1,"profile":"zsh-default-1","status":"ok","code":"ok","bytes":11,"sha256":"fb5caeeae17285f13e90ac772474ddafde161dbd655dd9674081b27c847012f2","nodes":24,"syntax_depth":2,"allocation_peak":18126,"definitions":[{"span":[0,10],"body":[4,10],"parent":-1,"depth":6,"names":[[0,1]]}]}
```

This example describes `f() { :; }` followed by LF; allocation/node measurements
are diagnostic counters, not compatibility constants. All ranges are half-open
**byte** offsets in the exact digest-bound input, never character offsets. Core
must retain those original bytes. `span` contains the definition unit including
syntactic redirects or anonymous arguments. Leading comments and following
statement terminators/trivia are excluded; interior bytes, CRLF and continuations
are preserved. `body` is the grammar body range and can include syntactic suffixes;
it is not a standalone payload or a promise of delayed execution.

`names` contains raw word spans without unquoting or expansion. Zero names means
anonymous; multiple names remain one structural unit. `parent` is the enclosing
definition's zero-based index, or `-1`; nested definitions are evidence inside their
parent, not independently selectable items. `depth` is AST depth, not load depth.
No source text, identifiers, paths, AST dumps or vendor error messages are emitted.
Success metadata and input hashes are private data, not ordinary operation logs.
The B5B helper also returns `statements`, an ordered list of byte spans for whole
outer sublists directly under the program list. More than 512 sublists yields
`null` and no B5 admission for that source. An older authenticated helper without
this field still supplies B4 Function evidence. Core checks foreground boundaries
and applies the closed declaration grammar independently to each admitted span.

An error has only `schema`, `profile`, `status: "error"`, an allowlisted `code`,
and `definitions: []`. Codes are:

`invalid_request`, `input_io`, `input_limit`, `invalid_encoding`, `syntax_invalid`,
`boundary_uncertain`, `nesting_limit`, `node_limit`, `definition_count_limit`,
`definition_size_limit`, `name_count_limit`, `allocation_limit`, `output_limit`,
`timeout`, `cancelled`, `process_failed`, `memory_limit`, `internal_error`.

The Core caller requires successful process exit, exactly one complete
record, supported schema/profile, exact input digest/length, bounded counts and
valid ranges before using any definition. Launch failure, crash, unknown exit,
missing/truncated/oversized output or malformed response means no usable evidence.
The caller bounds transport and cancellation, suppresses raw stderr and exposes
fixed failure codes. There is no current production
Capture/Rebuild/Check caller and no PATH or legacy parser fallback.

## Core caller (B2A)

Protected observation requires macOS 14.4 or later. Core checks the public
`NSTask.setLaunchRequirementData:` API before launching anything. Before reading
startup files it also requires a fresh enforcement preflight described below.
An unavailable API or unproven enforcement returns `shell_observation_functions_unavailable`,
never an empty successful observation or an unprotected launch. The application
and standalone native helper still target macOS 14.0; Aliases & Scripts v5 is unchanged.

`modules/shell/parser_client.py` accepts exactly one explicit trusted development
package or Macseed.app root, plus a required `manifest_sha256` from trusted Core/build
code. It resolves only `macseed-shell-parser` and `build.json` in a package, or
`Contents/Helpers/macseed-shell-parser` and
`Contents/Resources/ThirdPartyNotices/shell-parser-build.json` in an app. Source data,
user configuration and parser-specific environment overrides must never select these values.

B2B's Core adapter resolves the existing `MACSEED_DESKTOP_BUNDLE` launch context
or the fixed `<CoreRoot>/desktop/Macseed/build/Debug/Macseed.app` development location.
There is no parser-specific environment override, PATH search or adjacent-manifest
trust fallback. Development app preparation records the controlled build's digest
as `ShellParserManifestSHA256` in the existing `CoreRuntime.plist`. The adapter reads
that descriptor through the caller's no-follow guards and requires Version 1,
development mode and the current CoreRoot. The descriptor belongs to the trusted
Core deployment, not observed HOME data. Missing/stale anchors disable Functions
only. Release-mode descriptor/anchor authentication remains Stage 17 work.

**Trust anchor:** the expected manifest digest must be captured from a controlled
build result (`build()` returns it; the build CLI prints it), or authenticated Core
release metadata. Reading a runtime manifest or adjacent checksum and hashing it
is not authorization. The parser never does that automatically. Missing anchors,
manifest changes, stale requirements and binary changes fail closed. Replacing both
executable and writable manifest cannot grant a new identity under the existing
anchor. The development Core/checkout and the caller supplying this anchor remain
trusted code; this does not protect a compromised Core process. Stage 17 must bind
the anchor to authenticated release code, not add a mutable runtime trust file.

The caller checks no-follow ownership/modes/ACLs, file stability, the anchored
manifest's pinned sources, architecture and executable SHA-256/size. It rejects
sanitized packages. The code-file bound is 32 MiB and manifest bound 64 KiB.
Manifest schema 2 records the native and observation minimum versions, compiler,
Swift compiler, build macOS, SDK, source pins and binary records. Each binary's
`launch` schema 1 contains a per-architecture `cdhashes` map and base64
`requirement_data` (at most 4 KiB decoded). SHA-256 checks whole-file integrity;
CDHash identifies the code directory chosen by the OS for execution.

Core loads only system Foundation/libobjc through Python's `ctypes`. It sets the
build-generated launch requirement on `NSTask` before `launchAndReturnError:`.
API presence alone does not establish enforcement: macOS can report a constraint
violation while allowing execution. Before observing HOME, Core runs only the fixed
Apple `/usr/bin/true` through this same transport: a successful unconstrained control,
the anchored parser-only CDHash requirement (which excludes this executable), and
another successful unconstrained control. The constrained probe must have empty
output, terminate with SIGKILL, and provide a matching public Darwin kqueue
`NOTE_EXIT_DETAIL` / `NOTE_EXIT_CSERROR` receipt for that child. A plain signal,
launch error, timeout, missing/late event or successful constrained execution never
authorizes the parser. Cancellation and cleanup failures retain their fixed codes.
Neither SIP status nor system logs are consulted. Each probe retains the existing
three-second transport bound and cleanup; there are no retries. The receipt is
instance-local, reused across source files, and refreshed for every observation.

Only after this gate does Core rely on the kernel to enforce the accepted
CodeDirectoryHash set at execution, including
when the pathname changes after file validation. No separate Swift executable,
custom dylib, runtime compiler, runtime `codesign`, PATH parser or ordinary `Popen`
fallback is used. Post-launch file checks detect changes but are not the execution
authorization boundary. Launch can yield a task subsequently killed by the OS;
only a successful exit plus complete validated response can provide evidence.
This relies on the trusted OS retaining its enforcement policy during the observation;
it does not protect against a privileged actor changing that policy or Core itself.
The gate can conservatively make Functions unavailable if its exit receipt is lost.
[Hosted run #43918737369](https://github.com/jetiaks-AKS/macseed/actions/runs/43918737369)
qualified the gate's fail-closed behavior on macOS 26.7.2 ARM64: the constrained
Apple executable exited successfully, Functions were refused, and an actual
replacement executable never created its marker. This is not active-Functions
qualification on that runner or full B2B CI acceptance.

Platform-dependent tests classify enforcement with independent benign controls
and the unchanged trusted build requirement before corrupting any fixture. On
enforcing systems the original execution, signature, re-signing, malformed-requirement
and substitution assertions remain mandatory; `functions_unavailable` fails them.
On non-enforcing systems the tests require explicit refusal before parser execution,
HOME reads or response admission, including real swaps with forged valid responses.
A PASS in that mode qualifies refusal only: active observation, resource/lifecycle
and Capture-to-Bundle scenarios remain unexercised on that host. Deterministic
ignored-constraint fixtures exercise the refusal branches locally; they do not
establish OS enforcement. Native corpus, B1 codec and Bundle validation remain
independent of Functions availability.

Each task has a minimal fixed environment, `/` working directory and discarded
stderr. Core verifies its private process group; NSTask is not assumed to create
a session. Stdin stays open until existing `item_execution.ProcessTree` captures
ownership. Its opt-in group tracking finds worker descendants after abnormal
parent exit and excludes reused root identities. Existing callers retain their
session behavior. A live owned root also permits group cleanup if process-table
inspection fails; that failure remains explicit. This is not a guarantee about
unobserved detached work or external services.

Nonblocking pipes retain the three-second transport deadline, cancellation and
stdout bound strictly below 128 KiB. Foundation owns direct-child termination and
reaping; Core never competes with it through `waitpid`. TERM/KILL, pipe closure,
Foundation object release and quiescence checks run on every exit. Kernel launch,
filesystem and process-table latency are not a hard three-second total bound;
process probes retain their two-second limit and cleanup remains separately bounded.

Stdout must contain exactly one valid B1 `parser_response`; `function_evidence`
additionally admits individual named units. Native error envelopes require exit 2
and an allowlisted code. Other exits, malformed/incomplete/oversized output and
cleanup failures provide no usable definitions. Public errors contain fixed codes,
never NSError descriptions, raw stderr, source, names or paths. The
[B2A observation contract](../toolkit/CONFIGURATION.md#read-only-functions-observation-b2a)
owns source qualification and aggregate budgets.

## Admission and limits

The entire document is rejected on invalid UTF-8 (including overlong encodings,
surrogates or out-of-range codepoints), NUL, any ERROR/MISSING node, parse timeout,
uncertain byte boundary or exceeded budget. A good definition before a malformed
one is not salvaged. The adapter checks input bounds, UTF-8 boundaries, containment,
ordered name spans, body and nested-unit correspondence. It removes only validated
trailing whitespace outside the last direct child; it never regenerates code.

Heredocs inside complex bodies are supported. Definition-suffix heredocs whose
payload lies outside the definition node are explicitly rejected as
`boundary_uncertain`. Each definition's heredoc redirect/body accounting is
independent of its nested definitions; parent bytes cannot conceal an incomplete
nested unit. Further span forms require separate qualification.

| Resource, per invocation | Enforced profile |
|---|---|
| Input / definition unit | 128 KiB / 64 KiB |
| Definition units / names per unit | 512 / 16 |
| Tree nodes / total AST depth | 65,536 / 256 |
| Counted syntactic nesting | 32; nested functions, groups, expansions and control clauses |
| Runtime + scanner allocations | 128 MiB live, including headers and transient realloc storage; 1,000,000 allocations |
| Worker CPU / stack | 2 seconds / 8 MiB via OS limits |
| Parse callback deadline | 1 second |
| Parent watchdog | 2 seconds including stdin, parse and traversal; bounded 100 ms final response write |
| Worker RSS | 192 MiB sampled by the supervisor, roughly every 10 ms |
| Public response | Less than 128 KiB; no partial definitions on an encoded rejection |

RSS sampling is not a hard OS resident-memory cap; transient peaks can occur
between samples. The allocation cap is independent and hard. AST nesting is
checked after parsing; scanner/parser work before that check is contained by the
allocator, CPU, stack and watchdog limits. These are initial profile limits, not
minimum-macOS or physical-Intel performance acceptance.

The parent reads bounded input and forks one worker. All Tree-sitter and scanner
allocations use the guarded allocator (`TREE_SITTER_REUSE_ALLOCATOR`). Allocation
exhaustion exits the worker instead of returning a NULL pointer to unchecked
upstream code. The parent buffers a fixed-size worker record, checks its exit and
validates ranges again before serializing. Worker assertions/crashes cannot expose
raw stderr. Core dumps are disabled. SIGINT/SIGTERM cancel the parent, which kills
and reaps the worker. Timeout, RSS, overflow and protocol failures also reap it.
No persistent daemon, source files, temporary source copies or log files are used.

The grammar uses a fixed static syntax interpretation. As described in upstream's
[parsing policy](https://github.com/konomanoasa/tree-sitter-zsh/blob/17651db6e3a413b22e148c8a57726d4b392d10f7/PARSING_POLICY.md),
alias definitions, options and `emulate` do not change parsing of subsequent text.
Structural success does not resolve effective Shell ambiguity, load order,
conditional activation, aliases, hooks, dependencies or Restore eligibility.

## Build and focused validation

From the repository root, on macOS 14.4+ with Apple Xcode/Command Line Tools
(including Swift) and developer Python:

```bash
python3 -B scripts/build-shell-parser.py --output /absolute/new/task-directory/package
./scripts/test.sh --suite scripts/test-shell-parser.py --output /absolute/task-directory/results
```

The default build produces ARM64, x86_64 and universal executables, licenses and
`build.json` (toolchains/host, source pins, final signed binary sizes, SHA-256,
CDHash sets and launch requirements). The build result additionally returns an
out-of-band `manifest_sha256`; it is not a self-authenticating manifest field. `--arch arm64`
or `--arch x86_64` selects one target. Builds are offline; no npm, Node, Go, Rust,
Homebrew or grammar generator is needed. The delivered executable uses only
macOS system libraries. The native helper and Desktop minimum remain macOS 14.0;
the protected observation caller requires 14.4. Swift is a build-time dependency,
not an end-user toolchain requirement.
Reproducibility means pinned source inputs and recorded toolchain; byte identity
across different Apple compiler/SDK releases is not promised.

Development builds ad-hoc sign each final thin/universal helper with a fixed
identifier and no timestamp, then obtain the signed architecture CDHashes through
Apple `codesign`. `scripts/shell-parser-requirement.swift` uses the public
`LaunchCodeRequirement`/`CodeDirectoryHash` API to encode opaque requirement data.
The encoder stays in temporary build scratch and is never packaged. Encoding is
deterministic for the recorded build environment; no private DER format is generated
or interpreted by Core. All identities and whole-file hashes describe the same
post-signing bytes.

Re-signing can change both SHA-256 and CDHash. After final Developer ID signing,
Stage 17 must regenerate identities, requirement data, manifest and its trusted
anchor **before** sealing the outer app. `launch_metadata()` inspects already signed
artifacts without changing their signer. Runtime regeneration or trusting a newly
inspected executable is forbidden. No installed signed app is modified to refresh
these values. Developer ID/Hardened Runtime/notarization remain unqualified here.

Standalone packages include `zsh-LICENSE`, `runtime-LICENSE` and
`runtime-unicode-LICENSE`, unchanged from upstream. App preparation installs them
in `Contents/Resources/ThirdPartyNotices/` as `shell-parser-zsh-LICENSE.txt`,
`shell-parser-runtime-LICENSE.txt` and `shell-parser-runtime-unicode-LICENSE.txt`,
alongside `shell-parser-build.json`.

`desktop/Macseed/prepare-runtime.sh` and its Xcode input/output declarations include
the helper in development app preparation with notices. This adds no invocation
to Core workflows. Preparation preserves unrelated bundle files and rejects unsafe
output links; it is a build operation, not a runtime install or update mechanism.
Stage 17 still owns signed nested-code validation and distribution.

The focused suite builds a native package by default. Developers can supply a
fresh package with `MACSEED_TEST_PARSER_PACKAGE=/absolute/package`; when it includes
the x86_64 slice, the same corpus runs there (Rosetta on ARM64). A missing slice
is reported as SKIP. `--sanitize --arch arm64` produces a separate developer
ASan/UBSan package; sanitized binaries cannot be installed with `--resources`.
Build scratch and test fixtures use lifecycle-owned temporary directories; callers
own and remove explicit package/report destinations.

The original 83 authored fixtures, hashes and golden spans were recovered unchanged
from the 2026-11-15 qualification archive. `scripts/fixtures/shell-parser/README.md`
records provenance. Tests also cover the original 570 proper-prefix truncations,
encoding, sizes/counts/nesting, heredoc boundaries, seeded mutations, allocation
overflow, worker crash/hang/output failure, RSS supervision, cancellation, privacy
and development bundling. Fault injection is a separate test executable; the
production helper exposes no fault switches or environment overrides.

## Remaining qualification

Core Functions Capture/Bundle and bounded Restore/Verify/Check are implemented;
complete Functions migration is not qualified. Still open:
independent Zsh syntax oracle, wider option/grammar combinations and unusual span
forms (including complete CRLF documents: the qualified corpus covers interior CRLF
with LF after the closing unit), sustained fuzzing/native-code review, representative aggregate-operation qualification,
physical Intel, protected execution on macOS 14.4 and the unavailable branch on
14.0–14.3, signed/notarized clean-Mac packaging and authenticated release-anchor
provisioning, and representative Native visual/real-Mac qualification. B4 adds the
unified Native adapter and disposable mixed-transfer integration test. Local corpus,
sanitizer or Rosetta results do not close those gates. The B1 codec and B2A observer
are used by Functions Capture/Bundle and bounded exact-definition Restore/Check.
Broader target/dependency support and release qualification remain open.
Bundle capabilities 1–5 remain unchanged.

B4 Capture's independent-declaration projection and portable Restore destination
are owned by [Configuration](../toolkit/CONFIGURATION.md#unified-aliases--functions-b4).
They reuse this unchanged parser/launch contract; parsing whole-source syntax does
not establish runtime activation or authorize unrelated startup initialization.
