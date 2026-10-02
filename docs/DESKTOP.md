# Macseed Desktop

**Planned — Stage 16.** `Macseed.app` is not implemented. The intended native
Swift/SwiftUI application is a client of existing Macseed Core. The official CLI
remains supported.

## Product flows

- **Capture this Mac:** obtain Core inventory, choose supported state, review a
  fresh prepared selection and create the Bundle after confirmation.
- **Restore a Mac:** inspect a Bundle, narrow groups, review the plan and
  prerequisites, confirm a fresh plan, execute and display Verification.
- **Environment Status:** display matching, missing, differing and unverified
  requirements, reasons and coverage; show extras only where Core establishes them.

Missing dependencies lead to prerequisite guidance, external action and
**Check Again**. A new check produces a new plan requiring confirmation.
Interruption does not create a resumable transaction; the next attempt starts
with fresh inspection. Automatic Homebrew installation is not required for the
first Desktop.

## Responsibility boundary

Desktop launches Protocol V1 operations, reads JSONL, displays structured
progress/results, supplies separate secret input and owns user cancellation.
Core retains validation, selection, Preview, execution, Verification, Comparison
and Secure Migration. Desktop must not parse human CLI output or duplicate these
algorithms. Independent macOS or vendor authorization dialogs may still appear.
The implemented transport and secret boundary belong to the
[Core reference](core/APPLICATION-INTERFACE.md).

Stage 16 must implement Core/runtime placement, writable state and temporary
storage, controlled child HOME/PATH/environment, the Swift launcher, JSONL and
secret FD bridges, and process ownership/cancellation. Qualify Python/Core and
age/OpenSSH PTY interaction. Today's repository-based Core and external Python 3
do not constitute an installed-app runtime.

[Distribution](DISTRIBUTION.md) owns signed delivery and packaged clean-Mac proof;
[TODO](../TODO.md) tracks unfinished actions. The first complete Desktop release
is planned as **Macseed 1.0**, preserving the mature toolkit/CLI history and the
current 3.3.0 code version.
