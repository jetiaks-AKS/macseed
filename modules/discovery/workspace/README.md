# Workspace Discovery

Workspace Discovery describes HOME, user/workspace folders, Git repositories,
`.code-workspace` metadata and inventory. It does not copy, archive, back up or
transfer user content.

Outputs are under `config/generated/workspace/`: independent `workspace.conf` and
a grouped snapshot of `folders.conf`, `repositories.conf`, `vscode-workspaces.conf`,
`inventory.conf` and optional `topology.json` / `vscode-workspaces.json`. Derived files use the same staged generation. Publish only
after collecting, serializing and validating the entire group. Handled failure
returns an error and preserves the previous group; a partial candidate is not
successful Discovery. Cleanup failure after complete publication warns without
rolling back the published group.

[Configuration](../../../docs/toolkit/CONFIGURATION.md#workspace-bootstrap-actionability)
owns formats, path/remote safety and consumer limits. Explicitly selected
`.code-workspace` relationships feed the existing Core Restore topology consumer;
arbitrary descriptor content is excluded.
