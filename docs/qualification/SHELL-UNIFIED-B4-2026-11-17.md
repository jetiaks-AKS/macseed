# Unified Shell B4 — local integration evidence

Baseline: `develop` at `cd6c894955b221eb14989bba372cc22746c9c1f0`, with the
uncommitted B4 implementation. This is local automated qualification, not hosted
CI, manual visual acceptance or signed-distribution qualification.
Environment: macOS 27.2.1 (26B131), ARM64, system Xcode Python and Debug Swift build.

Automated scenarios use disposable source/target HOME directories and guarded fixture
tools. The explicit real-source case below reads the actual HOME but restores only
into a disposable target. User startup files are never executed. The genuine bundled parser uses
the unchanged protected launch gate; active enforcement was established locally.

## Core mixed transfer — PASS

Canonical case in `scripts/test-capture-api.py`:
`CaptureTests.test_mixed_alias_function_production_capture_restore_verify_check`.

- Scan exposes four aliases and three functions from a shared literal source chain.
- Explicit all-selection publishes seven typed requirements; a mixed subset publishes
  exactly four, preserving original definition bytes, including UTF-8/interior CRLF.
- Bundle inspection and read-only Restore Preview retain individual identities.
- Restore preserves unrelated target aliases/functions and source bytes. Verify and
  Check report the selected aliases/functions as matching; source HOME is unchanged.
- Repeat Restore preserves inode/mtime. A stale approval is rejected and a competing
  definition remains untouched. No fixture execution marker is created.

## Native to production Core — PASS

Existing `CaptureTests` harness with `--mixed-shell-only --no-renders`, compiled
against the common Debug test-support module using the `build.sh` compilation
pattern and bounded by `scripts/desktop_test_runner.py`.

- Real `CaptureModel` Scan, None/Partial/All selection, Prepare and Execute keep
  seven explicit IDs, with separate Scripts authorization empty.
- Confirmation reports four aliases and three functions; the genuine Bundle has
  seven requirements.
- Real `RestoreModel` inspection/selection/Preview, confirmation cancellation and
  approved Execute preserve unrelated target bytes and restore all seven definitions.
- Real `EnvironmentStatusModel` Check reports seven Match items under
  Shell → Custom Commands → Aliases & Functions, with validated Function names.
- Active scenario took 57.277 seconds; process supervision confirmed cleanup.

Targeted existing Native Shell selection/presentation checks also passed, including
Script consent, label-integrity fallback, missing/differing states, coverage and
native help/consent interaction. This does not substitute for human visual approval.

## Safety and remaining gates

Focused domain/Bundle tests cover one source writer, definition/load ordering,
ambiguous names, malformed content/member references, explicit pruning, unsafe
targets, stale/cancelled publication, resource limits and private diagnostics.
Scripts retain independent v5 consent, exact bytes, mode and quarantine.

Final focused validation: 11 parser/state cases, four Bundle cases, the strict Core
capabilities case and six Capture cases passed through `scripts/test.sh --suite …
--case …`, with clean owned TMPDIR teardown. The mixed Core case above is additional.
The final complex-Function + Script E2E passed in 47.087 seconds; the revised source
exclusion/order case passed in 14.822 seconds. Final `build.sh Debug`, Python/Bash
syntax, changed documentation links and `git diff --check` passed. Failures found
during implementation (fixture API/selection assumptions and typed Script
staging/context) were corrected and their affected cases rerun; none remain open.

Task-owned fixtures, screenshots, build/test scratch and raw logs were removed,
including the identified fixture left by an early Native assertion crash. The usable
Debug app and its runtime were retained. No user HOME, Git index, commits or CI were changed.

The parser pins, launch enforcement, legacy capabilities 1–5 and CI topology are
unchanged. Full local Core/Desktop regression, additional hosted jobs, physical Intel,
minimum-macOS runs, real-user-HOME Apply and Stage 17 signing/notarization were NOT RUN.
Non-enforcing systems remain unavailable for typed definitions; this active-platform
run does not newly qualify that platform branch. Broader dynamic/managed-source and
dependency support, independent syntax/native robustness, representative real-Mac and
manual visual qualification remain open in [TODO](../../TODO.md).

The [Shell contract](../toolkit/CONFIGURATION.md#unified-aliases--functions-b4) owns
supported behavior. Match proves definition/source conformity, never execution.

## Independent declarations and portable Restore — prior local follow-up

Fifteen affected cases passed through the canonical runner, with clean owned TMPDIR
teardown: eleven `test-shell-parser.py` cases and four `test-capture-api.py` cases.
Scope includes realistic initialization, conditional/substitution/pipeline exclusions,
identical repeated bindings, byte/order integrity, source safety, resource/cancellation
guards, managed startup connection, dormant-unselected refusal, interruption/retry,
stale plans, conflicts, Scripts v5 consent/quarantine and legacy Capture.

`CaptureTests.test_independent_fourteen_definitions_portable_restore_and_check`
passed with a disposable 12-alias/two-function source containing excluded initialization
and a qualified source chain: production Capture → Bundle → clean-target managed
Restore → 14 Verified → 14 Match → no-op. Removing startup integration removes Match;
stale approval and conflicting definitions preserve target data. This is synthetic
14-item qualification, not the requested real-source acceptance.

At that checkpoint the real production Scan reported `shell_functions.status: observed`, codes
`ambiguous_function` and `unsupported_context`, 12 eligible aliases and one eligible
function. Both original named functions are structurally valid. One has a second,
byte-identical definition in a statically sourced file, loaded in both interactive
contexts. The then-current repeated-binding policy excluded it. Requesting all
14 IDs returned `capture_functions_unavailable` before publication; no duplicate
or unsupported-source evidence was suppressed to reach the expected count.

The 13 independently qualified real declarations completed production Capture,
one typed Bundle, inspection, Preview and approved Restore into a clean disposable
HOME, followed by 13 Verified, 13 Match and a repeat with unchanged inode/mtime/bytes.
Restore used the controlled definitions file and qualified startup connection.
The target used unmodified production Core/bootstrap/Shell with guarded platform
prerequisite/launcher fixtures, not real host mutation. Every saved span matched
the original bytes. Actual startup bytes/metadata remained unchanged; the private
Bundle, target HOME and runtime copies were removed.

The initial isolated-target probe omitted `Contents/Helpers` when copying runtime
Resources and correctly failed parser authentication. Copying the complete helper
package fixed the fixture; production launch enforcement was not altered. Earlier
test failures in the lexical marker and missing-selected-function diagnostic were
corrected and their affected canonical cases rerun successfully.

**That checkpoint's real 14-item acceptance was BLOCKED.** Its synthetic 14-item
and real 13-item transfers did not satisfy the requested gate. The later explicitly
authorized equivalent-definition correction is recorded below; the original HOME
was not edited to remove the repeated definition.

Focused Native follow-up also passed: `PresentationTests --shell-aliases-only
--no-renders` (1.008 s) and `CaptureTests --mixed-shell-only --no-renders` (59.646 s),
with Debug assertions and confirmed process cleanup. The seven-item Native source
now includes excluded command-substitution, export and option initialization.
Selection/Confirmation/Result/Restore/Check retain the unified names/order; qualified
items retain one truthful coverage warning, and Rebuild confirmation describes the
possible controlled definitions/startup writes before explicit approval. Human visual
acceptance remains separate.

The follow-up `./desktop/Macseed/build.sh Debug` passed. The parser manifest anchor
is unchanged from the accepted package. Changed Python and repository Bash syntax,
local documentation references and `git diff --check` passed. No full regression,
additional hosted job, minimum-macOS/physical-Intel run or Stage 17 qualification was
performed. Unaffected prior B4 Bundle/codec, parser-corpus and protected-launch
evidence is reused only for unchanged contracts.

All follow-up disposable fixtures, native compiler scratch, private Bundles and seven
task-owned regression report directories were removed. The usable Debug app/runtime
was retained. The Git index is empty, and `NativeSidebarRepro.swift` is unchanged.

## Equivalent Functions — real 14-item acceptance PASS

The explicitly authorized correction coalesces only qualified equivalent Function
occurrences. Exact bytes, parser profile and relative name/body/definition spans
must agree; every physical mention must be admitted and all relevant sources/loads
must remain safe and freshness-bound. Unsupported source/binding syntax, conflicting
names, intervening outer statements that could change definition-time semantics,
and possible subsequent dynamic overrides refuse equivalence. The
[Shell contract](../toolkit/CONFIGURATION.md#unified-aliases--functions-b4) owns the
complete criteria. B1 IDs/schema and parser pins/security are unchanged.

Real production Core acceptance on the same ARM64 macOS 27.2.1 environment:

- Scan: 12 aliases + two functions = 14 unique selectable IDs; `shell_functions.status`
  is `observed`, with only `unsupported_context` for excluded initialization.
- All 14 selections completed Prepare/Execute into one genuine typed `.mbt`.
  Equivalent occurrences contributed one Function ID and one canonical exact payload.
  Every saved span matched the corresponding original source bytes.
- Bundle inspection and read-only Preview retained all 14. Approved production Core
  Restore into a clean disposable HOME returned 14 Verified; Check returned 14 Match.
- The portable target contained exactly `.zshrc` and `.macseed-shell-definitions.zsh`,
  with one static startup connection and one physical definition of the formerly
  repeated Function. No redundant source file or hook was recreated.
- Repeat Restore was a no-op with unchanged inode, mtime, ctime and bytes. All observed
  original HOME source files retained their bytes and metadata. No Shell source/body
  was executed, and no definition bytes appeared in ordinary Core output.

The target ran unmodified production Core/bootstrap/Shell with the genuine copied
Helpers/Resources package and canonical guarded platform-prerequisite/launcher tools.
This qualifies the real-source/disposable-HOME workflow, not a separate physical
clean Mac or signed distribution. The private Bundle and target were removed.

Thirteen affected canonical cases finished PASS, with clean owned TMPDIR teardown:
ten parser/B1 cases and three Capture cases. New cases cover equivalent definitions
in different files, repeated source loading, duplicate statements, exact canonical
payloads and one-definition Restore/no-op. Negative controls cover differing bytes,
Alias/Function and unsupported binding collisions, intervening alias/option changes,
dynamic source/dot-source/eval, conditional/cyclic relationships, unsafe and changing
sources, and target conflicts. The extended production 14-item E2E passed in 153.649 s:
changing only a second copy's comment returns `stale_prepared_capture`; changing its
definition returns `capture_functions_unavailable`, both before publication. Scripts
v5 consent/quarantine and legacy Capture controls also passed (50.620 s and 57.955 s).

One initial negative test found that an unreadable second source could leave a peer
apparently unique. The observation owner now rejects that inference; the negative
case and final equivalence cases were rerun successfully. No open FAIL/ERROR remains.

Changed Python syntax, documentation references and `git diff --check` passed.
Prior Native presentation/mixed E2E, Debug build, unchanged parser-corpus/protected
launch and Bundle-schema evidence is reused; no Swift, native helper, parser transport,
packaging or capability changes were made in this correction. Full regression,
additional hosted CI, visual acceptance, minimum-macOS/physical-Intel and Stage 17
qualification were NOT RUN and remain separate gates. Four task-owned regression
report directories and all private temporary fixtures were removed; the existing
67-MiB Debug app/runtime was preserved. No staging, commit or push occurred.

## Core post-publication inspection correction

The reported real archive with 12 Aliases, 2 Functions and 2 Scripts passed
`validate_archive()` but failed `inspect_bundle()`: target-path projection had
replaced portable Workspace repository paths before exact capability validation.
Inspection now checks projected paths on a copy and retains the original archive
evidence. The original archive was preserved and passes both independent checks.

Read-only production observation of the real HOME, using an isolated Core copy
and the authenticated bundled parser, captured those 16 Shell items plus 4
Workspace repositories into a private temporary Bundle. Native reached Save Complete
after `phase_completed`, `result`, `completed`; independent inspection passed.
All 16 Shell payloads matched the original archive byte for byte. Observed source
bytes, modes, inodes and modification times remained unchanged. No user Shell code
was executed and no real-HOME Restore was performed.

Focused canonical tests cover typed Shell with two Scripts and portable Workspace
topology, retained target/invalid-archive rejection, and a corrupted post-pack
publication returning `failed/capture_failed` with publication evidence and no
success events. The disposable Native mixed case also covers this combination.
This is local Core/Native qualification; hosted CI, manual visual approval,
minimum-macOS/physical-Intel and Stage 17 gates remain separate.
