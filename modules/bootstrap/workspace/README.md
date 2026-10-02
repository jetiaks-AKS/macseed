# Bootstrap Workspace

Restores supported folder structure and Git repositories from Workspace Discovery.
It consumes only `folders.conf` and `repositories.conf` required by the selected
scope. Validate required input before mkdir, clone or checkout; missing, unreadable
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
`.code-workspace` restoration is not implemented. Exact validation, branch,
remote and exit rules belong to
[Configuration](../../../docs/toolkit/CONFIGURATION.md#workspace-bootstrap-actionability).
