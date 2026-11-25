# Shell Settings B6A — controlled real-Mac acceptance

Recorded on 2026-11-25 for the local B6A patch on `develop` based on `e1a8ebd`.
The operator completed functional and visual acceptance using the Native development
app and a fresh Capture with `shell-state:3` placement evidence. The five selected
requirements were AUTO_CD enabled, BEEP disabled, HISTSIZE and SAVEHIST each set to
1,000,000, and the Emacs editing mode.

| Operator observation | Result |
| --- | --- |
| Real Capture | PASS. The corrected placement contract was used for `Test_4.mbt`. |
| Independent Check after controlled removal | 117 Match / 5 Missing. The five missing requirements were the selected Shell Settings. |
| Rebuild Preview | 5 Planned / 0 Blocked. |
| Native Restore and Verify | PASS on two real cycles. Each reported 5 Verified. |
| Independent Check after restoration | 122 Match. |
| Repeat Preview | No-op. |
| Final Native presentation | Accepted across Capture, Rebuild and Check. Shell Settings uses the Shell accent, subgroup disclosures and selection controls. Rebuild Progress stays flat. Result preserves individual outcomes and counts. |
| Final QA cleanup | PASS. The operator restored the original startup file and retained the QA backups and archives. |

During documentation review, a read-only SHA-256 comparison of the current
`.zshrc`, the original backup and the original digest in the QA manifest agreed
on `15d61a5cdecb9ef47be506c1dfbacb10827f69a268c2e7ee4b0daf7bc22d79da`.

The earlier focused Native checks covered light and dark rendering, subgroup
counts of 2/2/1, independent disclosures, and a mixed Shell Result with verified,
attention and skipped outcomes. Permanent parser and Capture API fixtures cover
changed executable predecessors, load order, ambiguous placement, conflicts,
stale preparation and preservation of unrelated target bytes.

The accepted scope is saved startup declarations on the exercised routes.
The [placement contract](../toolkit/CONFIGURATION.md#shell-settings-b6a) describes
the remaining qualification limits. Hosted CI for this patch and final packaged
clean-Mac qualification remain open.

## Isolated symbolic source regression

A fresh five-setting Capture followed by removal of only the declarations reproduced
**0 Planned / 5 Blocked** with `shell_source_prerequisite`. The original placement
record identified the source invocation. It contained no evidence for the file
selected by the variable.

The corrected production API fixture binds a directory under `$HOME`, sets literal
theme and plugin preferences, and sources `"$ZSH/oh-my-zsh.sh"`. The disposable
script contains a comment and `setopt interactivecomments`. Only the five selected
declarations travel in the Bundle. Independent source and target HOMEs exercise
portable resolution. Preview reported **5 Planned / 0 Blocked**, Execute reported
**5 Verified**, and independent Check returned **5 Match**. Repeat Preview and
Execute were a no-op. The target retained its original prefix and sourced file.

The second fixture uses `.`, a different variable and a different filename. It
covers changed or missing dependencies, symlinks, shadowed commands, duplicate
or changed placement, stale Prepare and older v3 records without the required
source evidence. A conflicting option in the sourced file excludes that option
from fresh Capture while an independent option remains selectable.

These fixtures qualify the [bounded source relationship](../toolkit/CONFIGURATION.md#shell-settings-b6a).
A framework script that performs nested loading or arbitrary initialization remains
outside this evidence. The operator’s real-Mac acceptance above is a separate run.
