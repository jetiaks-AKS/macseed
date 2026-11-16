# Internal Shell structural parser

This reference owns the dormant native helper interface. The
[Shell configuration contract](../toolkit/CONFIGURATION.md#shell--zsh-configuration)
owns product behavior. This checkpoint does not enable Functions migration,
change Aliases & Scripts v5 or implement `shell-state:1`.

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

An error has only `schema`, `profile`, `status: "error"`, an allowlisted `code`,
and `definitions: []`. Codes are:

`invalid_request`, `input_io`, `input_limit`, `invalid_encoding`, `syntax_invalid`,
`boundary_uncertain`, `nesting_limit`, `node_limit`, `definition_count_limit`,
`definition_size_limit`, `name_count_limit`, `allocation_limit`, `output_limit`,
`timeout`, `cancelled`, `process_failed`, `memory_limit`, `internal_error`.

The future caller must require successful process exit, exactly one complete
record, supported schema/profile, exact input digest/length, bounded counts and
valid ranges before using any definition. Launch failure, crash, unknown exit,
missing/truncated/oversized output or malformed response means no usable evidence.
The caller must bound transport, launch and cancellation itself, suppress raw
stderr and map failures to existing typed Core diagnostics. There is no current
Capture/Rebuild/Check caller and no PATH or legacy parser fallback.

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

From the repository root, with Apple Xcode/Command Line Tools and developer Python:

```bash
python3 -B scripts/build-shell-parser.py --output /absolute/new/task-directory/package
./scripts/test.sh --suite scripts/test-shell-parser.py --output /absolute/task-directory/results
```

The default build produces ARM64, x86_64 and universal executables, licenses and
`build.json` (compiler/SDK, source pins, binary sizes and hashes). `--arch arm64`
or `--arch x86_64` selects one target. Builds are offline; no npm, Node, Go, Rust,
Homebrew or grammar generator is needed. The delivered executable uses only
macOS system libraries. The target minimum is macOS 14.0, matching Desktop.
Reproducibility means pinned source inputs and recorded toolchain; byte identity
across different Apple compiler/SDK releases is not promised.

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

This is implemented infrastructure, not production Functions acceptance. Still open:
independent Zsh syntax oracle, wider option/grammar combinations and unusual span
forms, sustained fuzzing/native-code review, aggregate source-operation budgets,
physical Intel, execution on macOS 14, signed/notarized clean-Mac packaging,
runtime helper authentication and future Core/Native integration. Local corpus,
sanitizer or Rosetta results do not close those gates. Typed Shell Core integration
requires the next review; Bundle capabilities 1–5 remain unchanged.
