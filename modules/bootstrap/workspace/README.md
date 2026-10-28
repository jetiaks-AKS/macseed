# Bootstrap Workspace

Restores supported folder structure and Git repositories from Workspace Discovery.
Ordinary Bootstrap consumes `folders.conf` and `repositories.conf` required by the
selected scope; structured Restore also consumes qualified topology/descriptor metadata. Validate required input before mkdir, clone or checkout; missing, unreadable
or malformed input returns `2` without partial application. Empty selections do
not require unrelated files. Without Blueprint, compatible all-inclusive behavior
remains.

Create selected missing safe folders. Blueprint normally offers only
`workspace`-classified folders; `user`/`system` observations remain generated data.
Clone absent repositories and inspect existing worktrees, origin and branch.
Preserve conflicting/non-Git destinations, dirty tracked/staged state, remotes and
untracked files; Git may safely refuse checkout. Observation failures block action
rather than becoming a mismatch. Repeat only necessary changes and verify results.

`inventory.conf` and `vscode-workspaces.conf` are not Bootstrap inputs.
Selected `.code-workspace` relationships are restored without overwriting files through
the [Core descriptor consumer](../../../docs/toolkit/CONFIGURATION.md#vs-code-workspace-descriptor-restoration--phase-5).
Exact validation, branch,
remote and exit rules belong to
[Configuration](../../../docs/toolkit/CONFIGURATION.md#workspace-bootstrap-actionability).
