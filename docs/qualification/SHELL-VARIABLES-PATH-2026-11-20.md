# Variables & PATH Native qualification

## Controlled real-Mac acceptance

**PASS.** The operator completed the mixed B4+B5 Native lifecycle on the QA Mac
with `Macseed_B5_Mixed_QA.mbt`. The eight controlled requirements were two
variables, one PATH operation, two aliases, one function and two executable
Scripts. Check totals below cover the selected Bundle scope. Restore reports
the eight requirements rebuilt after removal.

| Operation | Observed result |
| --- | --- |
| Mixed Capture and Bundle publication | PASS |
| Initial independent Check | 88 Match |
| Controlled removal and Check | 8 test requirements removed. 80 Match / 8 Missing |
| Rebuild Preview | 8 Planned / 0 Blocked |
| Real Native Restore | 8 Verified |
| Independent Check after Restore | 88 Match |
| Actual login and interactive Zsh execution | PASS for LOGIN and BIN, PATH ordering, both aliases, the function and both executable Scripts |
| Repeat Preview | Zero changes |
| Final QA cleanup | PASS. The SHA-256 of each original startup file, `.zprofile` and `.zshrc`, returned to its baseline. Held Script backups, test archives and historical predecessor evidence were preserved. |

This accepts the B5 Variables & PATH functional checkpoint within the exercised
scope. The operator verified runtime behavior separately from Core's declaration
checks. Hosted CI, packaged clean-Mac and full-product E2E remain open.

## Local integration scope

The focused Native entry point is `CaptureTests <checkout> <xcrun-python3> --environment-lifecycle-only`.
It drives the production Capture, Restore and Check models against a disposable
Core checkout, source HOME and target HOME. Only the host tools used by unrelated
setup prerequisites are fixtures. The parser comes from the authenticated Debug
bundle. Script consent, prepared IDs, publication and verification use Protocol V1.
The mixed scenario renders Selection, Preview, Result and Check at 580 and 985 pt.

The separate `ShellParser.test_homebrew_initializer_restore_presentation` case
uses a synthetic enrolled prefix and release pin. It checks login-stage shellenv
publication, interactive PATH placement, repeat no-op and rejection after a provider
file changes. A real custom-prefix installation remains a separate gate.

Local arm64 results on 2026-11-20 used the uncommitted B5B–B5D patch on
`develop` at `e7ad172`.

| Focused case | Result |
| --- | --- |
| Variables-only Bundle | PASS. One domain, two items. An intervening edit invalidated Execute and survived. Fresh Preview and Execute restored both requirements. Result and independent Check agreed. Repeat Preview offered no write. |
| Mixed Custom Commands and Variables & PATH | PASS. Three domains, four items, including an explicitly authorized script. Cancel preserved selection. All four requirements verified. Both render widths passed. |
| Conflict, dependent PATH and unqualified initializer | PASS. One independent alias verified. The original conflicting declaration survived and the three blocked requirements stayed visible. |
| Qualified Homebrew fixture | PASS. The target received the qualified shellenv invocation and PATH in their saved startup stages. Repeated publication was a no-op. Changed provider bytes failed qualification. |
| Protocol and archive boundaries | PASS. The production recovery case exercised B5-only and mixed Prepare/Execute/Verify/Check. Typed Bundle integrity cases covered v1, unknown features, malformed members and tampering. |

The focused `CaptureTests --environment-only` render and accessibility checks
also passed. The final `./desktop/Macseed/build.sh Debug` build passed. The
development descriptor identifies this checkout and Xcode Python. The rebuilt
arm64 parser passed its manifest digest and code signature checks, and the
bundled arm64 age v1.3.2 passed the production verifier.

The Native tests checked source bytes, script consent, functional counts, the
universal confirmation, independent comparison and zero actionable issues for
a fully verified selection. The operator's real-Mac results are recorded above.

## Source-Mac conformity regression

The user reported 16 unverified Shell requirements and one partial coverage
record in the GUI for `Test_3.mbt`. Read-only Shell inspection of that same
schema 2 archive on the source Mac reproduced the item results. The 12 Aliases,
two Functions, PATH prepend and Homebrew initializer all had matching declaration
bytes and load routes. One selected Script already matched.

| Requirements | First failing Core check | After the first correction |
| --- | --- | --- |
| Four Aliases | The v2 planner checked external management before comparing the existing definitions. | Four Match through B4 conformity. |
| Eight Aliases and two Functions | The v2 planner required every outer startup statement to be understood. | Ten Match through B4 conformity. |
| PATH prepend | The same completeness check rejected bounded surrounding statements in a byte-identical source with identical load sites. | Match at the saved placement. |
| Homebrew initializer | The inspected launcher, dispatcher and shellenv digest tuple was absent from the reviewed release set. | Unverified. The declaration matches, while the installation prerequisite remains open. |

The first corrected Shell plan had zero candidate writes. With the rebuilt Debug
parser, both Shell `inspect` and `compare` returned 16 matching items, one
unverified initializer and one separate partial coverage record. Selecting
the other 16 items in a disposable reference returned 16 matches and informational
`activation_unknown` in both modes. The original archive digest stayed stable.
The source-Mac inspection used the Shell reader only. GUI recheck and real
Restore remain outside this evidence.

### Final coverage and Homebrew Check

The next user-operated GUI Check reported 133 Match and two Needs Attention.
The Shell reader reproduced 16 matching items and one unverified initializer.
Its separate scope warning was derived solely from the initializer's status.
The observer reported only `unsupported_context`. Core now derives scope from
the source observation and retains independent failures such as unresolved loads.

The installed launcher, dispatcher, shellenv and OS helper matched all four
files at official release commit `c6069d2a943b71b0a90d91fc1ac93cb9c1634dcc`.
Only the dispatcher differed from 7.0.15. In 7.0.11 its group check invokes
`id` before shellenv, after the launcher resets PATH. The profile binds that
system dependency as well as all four Homebrew files. Both Shell readers then
returned 17 matches and informational activation scope on the original archive,
with zero proposed writes. This was a read-only Core check. [Homebrew 7.0.11](https://github.com/Homebrew/brew/releases/tag/7.0.11)

For broader release coverage, a candidate maintenance contract is an independently
signed, updateable catalog of reviewed shellenv execution profiles. Verify the
upstream release attestation against the Homebrew repository identity, derive
file digests from its bound commit tree and review changes to dispatch, helper
lookups and emitted Zsh before signing a profile. A local Git tag or installer
receipt cannot establish the current bytes. At runtime a catalog would also
need an authenticated signing root, rollback protection and revocation, alongside
the existing live file and freshness checks. Current builds ship reviewed profiles
with Core and perform qualification offline. [GitHub immutable release attestations](https://docs.github.com/en/enterprise-cloud%40latest/code-security/concepts/supply-chain-security/immutable-releases)

## Cross-domain partial selection on the QA Mac

These three revisions passed production Bundle validation. The current
`Test_3.mbt` supersedes the archive of that name in the earlier investigation.
Both production Shell readers used the Debug application's pinned parser and
the development Core checkout. Counts below cover Shell requirements only.
After controlled removal, the user observed 80 Match / 8 Missing across the
mixed Bundle and 55 Already Match / 8 Changes Planned in the chosen Preview.

| Archive and SHA-256 prefix | Before, Check | After, Check | After, Preview |
| --- | --- | --- | --- |
| `Test_3.mbt` · `28474db637d1` | 1 matching, 1 missing, 3 unverified | 1 matching, 3 missing, 1 unverified | 1 satisfied, 1 planned, 3 blocked |
| `Macseed_B5_Mixed_QA.mbt` · `941070fb3750` | 17 matching, 8 missing | 17 matching, 8 missing | 17 satisfied, 8 planned |
| `Test_Shell_4.mbt` · `ed7a2ae6dc8f` | 1 missing, 6 unverified | 6 missing, 1 unverified | 4 planned, 3 blocked |

The two root source records agree across all three archives. Their captured
file sizes were 146 bytes for the login profile and 4,006 bytes for the
interactive startup file. Whole-source fingerprints survived the narrow saves.
The complete snapshot also retains the Homebrew initializer, the preceding PATH
operation, other definitions and a sourced-file route. The then-truncated
targets and the candidate containing only selected statements cannot reproduce
the original whole-source fingerprints. Unselected comment and statement bytes
are outside the transfer contract.

Selecting only the eight missing QA requirements from the complete archive
previously gave six source prerequisites and two planned files. With the
corrected projection, all eight qualify. Selecting just the custom directory
binding also qualifies from that archive. Selecting only the dependent PATH
remains blocked in all three archives because its required directory binding
is absent. Selecting both PATH operations in the complete archive keeps the
earlier operation matching.

In the historical narrow archives, Core can observe both independent variable
declarations as absent. The saved root visits alone cannot establish a safe
insertion across the bounded external initialization. The PATH consumer also
lacks proof of its earlier PATH operation and cannot obtain its custom directory
binding from a qualified plan. In the narrow mixed archive the two aliases and
one function independently qualify at their B4 interactive source. The selected
missing script requires its own Execute authorization. This investigation used
read-only inspection.

### Independent Check after the mixed Restore

The three saved B5 declaration byte ranges moved 30 bytes earlier. Their bytes,
root identities, load contexts and relative order still matched. Core now
qualifies the existing literal LOGIN assignment in the earlier login profile.
In the two historical narrow Bundles, BIN lacks saved evidence of its placement
relative to initialization in the interactive stage. The dependent PATH also
lacks evidence for its preceding PATH operation. Both remain Unverified.

| Bundle | Post-Restore Shell-only Check after the LOGIN correction |
| --- | --- |
| `Test_3.mbt` · `28474db637d1` | 3 Match / 2 Unverified |
| `Test_Shell_4.mbt` · `ed7a2ae6dc8f` | 5 Match / 2 Unverified |
| `Macseed_B5_Mixed_QA.mbt` · `941070fb3750` | 25 Match |

The current narrow writer retained the omitted-declaration and binding evidence
from the complete capture. The same two narrow selections gave 5/5 and 7/7
Match on the restored sources. A fresh capture of just the three restored B5
declarations gave 3/3 Match. These comparisons proposed zero Shell writes.

## Permanent regression coverage

| Permanent fixture | Qualification |
| --- | --- |
| `ShellParser.test_partial_selection_dependency_matrix` | B4-only, B5-only, single, mixed and transitive reads with existing, missing and changed producers; preserved source bytes and repeat no-op |
| `ShellParser.test_physical_occurrence_and_dependency_publication_order` | Unique and ambiguous ordinal shifts, existing consumer with a missing producer, cross-file ordering |
| `ShellParser.test_historical_partial_absence_and_selection_evidence_integrity` | Historical narrow source evidence, management and opaque barriers, malformed evidence, independent B4 recovery |
| `ShellParser.test_narrow_bindings_across_source_visits_and_defaults` | Nested login source, shifted visit indices, empty and unset variables, required and optional reads |
| `ShellParser.test_shifted_existing_declarations_in_narrow_post_restore_check` | Historical and current narrow snapshots after placement shifts, bounded later initialization, same-stage or dynamic barriers, conflict and absence |
| `ShellParser.test_environment_cross_stage_and_narrowed_bindings`, `ShellParser.test_partial_tail_requires_anchors_dependency_order_and_safe_destination` | Existing unselected bindings, LOGIN and interactive contexts, order across external initialization and unsafe destinations |
| `CaptureTests.test_environment_recovery_after_selected_tail_removal` | Complete mixed reference and selection across the two startup stages |
| `CaptureTests.test_environment_narrow_saved_tail_recovery` | Narrow saved archive with independent source evidence and explicit script consent |
| `CaptureTests.test_environment_narrow_restore_tail_recovery` | Complete archive narrowed during Restore, independent Check of the saved scope |
| `CaptureTests.test_environment_production_recovery` | B5-only and mixed Protocol V1, dependent PATH and independent recovery alongside a conflict |
| `CaptureTests.test_environment_capture_mixed_selection_privacy_and_archive_gate` | Exact plaintext selection, private exclusions, safe inventory and Bundle capability checks |
| `BundleTests.test_typed_shell_capture_inspection_integrity_and_runtime_boundary`, `BundleTests.test_scripts_v5_members_integrity_selection_and_legacy_limits` | Typed Bundle decoding, legacy formats, integrity, member limits and unknown required features |
| Native `CaptureTests.environmentSelectionCheck`, `CaptureTests.environmentLifecycle` | Selection, consent, Capture, Restore model, Preview, Verify, independent Check and no-op |
| Native `RestoreTests.shellRecoveryCoreChecks`, `PresentationTests.shellAliasPresentationChecks`, `PresentationTests.shellProgressChecks` | B4 file consent and blocked plans, B5 Preview evidence and the single flat Progress row for single and mixed selections |

On arm64 at `e7ad172` with the working-tree correction, 20 distinct focused
Shell cases, four Protocol V1 cases and one Bundle integrity case passed.
The narrow saved-archive lifecycle also passed a final repeat with the final
load-site evidence encoding. The disposable tests checked stale Execute, denied
script consent, conflict preservation, verified publication, independent Check
and repeat no-op. Bash syntax and whitespace review passed.

## Final Protocol V1 and Check presentation checks

The typed v2 skip list covers selected declarations, up to 512 including at most
256 aliases. Script rows remain independent. The legacy v5 list covers up to
256 aliases and 128 file candidates. Both require a unique, non-actionable Shell
plan row for each skipped identity. The private Restore request can carry the
full typed selection of 512 declarations plus 128 Scripts. Per-file consent,
inventory membership and prepared-plan freshness still apply.

| Focused case | Observed result |
| --- | --- |
| Native `CaptureTests.environmentLifecycle` (`--environment-function-preview-only`) | PASS with production Capture and Prepare in a disposable HOME. Native constructed Preview, preserved the conflicting Function, and retained independent planned requirements including the variable. |
| `PresentationTests.shellSkipProtocolChecks` | PASS at both format limits, including 512 skipped declarations with 128 Scripts still planned. Malformed IDs, duplicate or unselected skips, excess counts and inconsistent rows were rejected. |
| `CaptureTests.test_restore_manifest_typed_selection_bounds`, `CaptureTests.test_v5_request_manifest_maximum_selection_and_fail_closed` | PASS for the typed and legacy request limits and rejection of invalid manifests. |
| `PresentationTests.shellConsistencyChecks` | PASS at 580 and 985 pt in Light and Dark. The fixed Details by Category heading and both scrolling section headers were checked. Their inline actions matched Rebuild Selection geometry. Each acted only on its own descendants, with synchronized labels after individual toggles and refresh. |

## Reference procedure for a disposable two-item GUI fixture

This earlier procedure describes a separate two-item fixture. The mixed real-Mac
acceptance above records the actual run and the artifacts its operator preserved.

Use a dedicated local macOS test account with an actual GUI login, its own
development checkout of the tested patch and a Debug app bound to that checkout.
Restore publishes configuration under the development Core root. Keep the app,
checkout, logs, Bundle and target HOME separate from the everyday account and
the accepted B4 evidence. A temporary HOME passed to an app launched from the
everyday account does not qualify this gate.

1. In the test account, quit Macseed and start a fresh terminal. Confirm the
   account, checkout, app descriptor and initial Git status. Use an empty
   test checkout configuration (no existing private Blueprint or generated
   configuration). Keep the baseline and Bundle in a new private directory.
   Run each command block as a sourced Zsh script in the same terminal so a
   failed guard returns from the block. Stop on any failure or unexpected file.

   ```zsh
   umask 077
   b5_run=$(mktemp -d "$TMPDIR/macseed-b5-gui.XXXXXXXX") || return 1
   b5_rc="$HOME/.zshrc"
   [[ ! -e "$b5_rc" && ! -L "$b5_rc" ]] || return 1
   [[ ! -e "$HOME/.zshenv" && ! -L "$HOME/.zshenv" ]] || return 1
   b5_baseline() {
     for f in "$HOME/.zshrc" "$HOME/.zprofile" "$HOME/.zlogin" "$HOME/.zshenv"; do
       if [[ -L "$f" ]]; then return 1
       elif [[ -f "$f" ]]; then stat -f '%Sp %u %g %N' "$f" && shasum -a 256 "$f"
       elif [[ ! -e "$f" ]]; then print -r -- "absent $f"
       else return 1
       fi
     done
   }
   b5_history() {
     for f in "$HOME"/.macseed-shell-{predecessor,pending}-*(N); do print -r -- "$f"; done
   }
   b5_history > "$b5_run/history-before" || return 1
   b5_baseline > "$b5_run/before" || return 1
   cat > "$b5_run/expected" <<'ZSH'
   export MACSEED_B5_GUI_ROOT="$HOME/macseed-b5-gui"
   path=("$MACSEED_B5_GUI_ROOT/bin" $path)
   ZSH
   (setopt noclobber; cat "$b5_run/expected" > "$b5_rc") || return 1
   ```

2. Open this checkout’s Macseed.app. In Capture, clear the ordinary selection
   and select exactly the two fixture declarations under Shell → Variables &
   PATH. Leave Custom Commands and Secure Transfer clear. Inspect their Info.
   Save as `$b5_run/variables.mbt` using the actual directory shown by
   `print -r -- "$b5_run"`. Confirm one functional domain and two items in
   Save Complete. Open the Bundle in Rebuild Selection and check the two
   labels and their origins. Run independent Check and require two matches.
   Record the archive digest with `shasum -a 256 "$b5_run/variables.mbt"`.
3. Check that Capture preserved the file. Remove only the test-owned file
   under its original absence precondition. Keep the expected bytes and Bundle.

   ```zsh
   [[ -f "$b5_rc" && ! -L "$b5_rc" && -O "$b5_rc" ]] &&
     cmp -s "$b5_rc" "$b5_run/expected" && /bin/rm "$b5_rc" || return 1
   b5_baseline > "$b5_run/missing" && cmp "$b5_run/before" "$b5_run/missing" || return 1
   ```

4. In Rebuild, select the two declarations alone. Preview must show two
   planned restorations. Check that the destination is still absent. Use Back,
   return to Preview and Refresh Preview. Cancel the universal confirmation
   once and verify absence again. Stop here for **explicit user authorization
   for this account, Bundle, target file and two declarations**. If a prerequisite
   or extra action appears, stop and retain the evidence.
5. After approval, choose Rebuild. Observe progress and require two Verified
   requirements and zero actionable issues in Result. Confirm the saved bytes
   with `cmp "$b5_run/expected" "$b5_rc"`. Run independent Check against the
   same Bundle and require two matches. Separately start a new interactive Zsh
   in this test account to check the actual fixture values.

   ```zsh
   /usr/bin/env -i HOME="$HOME" PATH=/usr/bin:/bin TERM=dumb /bin/zsh -ic \
     '[[ "$MACSEED_B5_GUI_ROOT" == "$HOME/macseed-b5-gui" && "$path[1]" == "$MACSEED_B5_GUI_ROOT/bin" ]]' || return 1
   stat -f '%i %m %z %Sp %u %g' "$b5_rc" > "$b5_run/restored-stat" || return 1
   ```

6. Reopen the same Bundle with both declarations selected. Require two Already
   Matches, zero planned changes and an inactive Rebuild action. Confirm repeat
   Preview and Check preserved the file, then remove only the verified fixture.
   A fresh creation produces one empty predecessor directory. Confirm that the
   new directory appeared during this test. Stop and retain it if it contains
   anything or a pending directory appeared. Historical entries stay in place.

   ```zsh
   stat -f '%i %m %z %Sp %u %g' "$b5_rc" | cmp "$b5_run/restored-stat" - || return 1
   [[ -f "$b5_rc" && ! -L "$b5_rc" && -O "$b5_rc" ]] &&
     cmp -s "$b5_rc" "$b5_run/expected" && /bin/rm "$b5_rc" || return 1
   b5_history > "$b5_run/history-after" || return 1
   b5_new=("${(@f)$(LC_ALL=C comm -13 <(LC_ALL=C sort "$b5_run/history-before") <(LC_ALL=C sort "$b5_run/history-after"))}")
   [[ ${#b5_new} == 1 && -d "${b5_new[1]}" && ! -L "${b5_new[1]}" &&
      -O "${b5_new[1]}" && "${b5_new[1]}" == "$HOME"/.macseed-shell-predecessor-* ]] || return 1
   /bin/rmdir "${b5_new[1]}" || return 1
   b5_history | cmp "$b5_run/history-before" - || return 1
   b5_baseline > "$b5_run/after" && cmp "$b5_run/before" "$b5_run/after" || return 1
   ```

7. Recheck the archive digest and Git status. Record the two labels, results,
   app revision and final baseline comparison. Retain evidence on any divergence.
   After recording acceptance, clean up the run directory.

   ```zsh
   /bin/rm "$b5_run"/{before,expected,variables.mbt,missing,restored-stat,after,history-before,history-after} &&
     /bin/rmdir "$b5_run"
   ```

   Retire the dedicated checkout and test account through their owner after review of the Core-generated state.
   No step requires changes to the B4 archive, managed dotfiles or provider setup.
