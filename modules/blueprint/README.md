# Blueprint MVP

[Russian convenience copy](../../docs/ru/BLUEPRINT.md) — English is authoritative.

Blueprint is the user-selection layer between Generated Configuration and
Bootstrap. It provides parsing, validation, item-level and category/module-level
Bootstrap filtering, plus the interactive `--blueprint` selector. Stages 1–5 are complete
and end-to-end verified; Blueprint is included in stable release 3.0.0.

The user-specific file is `config/blueprint.conf`. It is ignored by Git and is
not an output of ordinary Discovery. Capture builds a staged Blueprint from
its selected scope; Restore publishes the validated selected Blueprint.
`config/blueprint.example.conf` contains the tracked neutral example.

The format contains one required `[categories]` section and six required item
sections:

- `[homebrew-packages]`
- `[homebrew-casks]`
- `[app-store]`
- `[vscode-extensions]`
- `[workspace-folders]`
- `[git-repositories]`

An empty item section selects zero items. When `config/blueprint.conf` is
absent, Bootstrap retains its legacy all-inclusive behavior.

The API in `blueprint.sh` is:

- `blueprint_exists [file]`
- `blueprint_category_enabled category [file]`
- `blueprint_selected_items section [file]`
- `blueprint_item_selected section item [file]`
- `blueprint_validate [file]`

Validation returns `0` for a valid or absent Blueprint, `1` for a valid
Blueprint with stale selected items, and `2` for malformed or ambiguous input.
Validation never rewrites the Blueprint.

Discovery still scans every supported area, while Blueprint stores only the
user's selection. Generated Configuration remains the source of actual values.
When a Blueprint exists, Bootstrap filters Homebrew packages, Homebrew casks,
App Store applications, VS Code extensions, workspace folders, and Git
repositories by their corresponding item sections.

Workspace Discovery keeps observed `system`, `user`, and `workspace` folder
records in `folders.conf`. Blueprint exposes only records classified exactly as
`workspace` as normal Workspace Folder candidates. Saving an existing
Blueprint normalizes legacy `user` and `system` selections away; cancelling
preserves the original file. Without Blueprint, Bootstrap retains its broad
legacy behavior.

The `[categories]` section independently controls Git Configuration, SSH
Configuration, VS Code Settings, Shell / Zsh, and the Finder, Dock, Window
Management, Keyboard, Trackpad, and Screenshots macOS modules. VS Code
extensions remain controlled separately by their item section.

Blueprints created before `macos-windows`, `shell-zsh`, or `ssh-configuration`
remain valid and keep those categories disabled until explicitly migrated.
Saving through the selector writes the new categories explicitly. Without
Blueprint, supported categories remain all-inclusive.

Create or edit the local Blueprint with:

```text
./bootstrap.sh --discover
./bootstrap.sh --blueprint
./bootstrap.sh --bootstrap
```

The selector offers All, None, or Edit for each discovered item area. Edit mode
shows the current checkbox state on pages of 20 items. Entered numbers toggle
those checkboxes; they may be separated by commas or spaces and may include
ranges such as `5-9` or mixed input such as `1,3,7-10`. Running `--blueprint`
again loads the current choices for editing.

The selector writes only after confirmation. Enter `q` or `Q` at any prompt,
including Edit, to cancel immediately. Cancelling leaves an existing Blueprint
unchanged and does not create a new one; in `--workflow` it also stops the
workflow before Preview.

The Blueprint remains local, private, and ignored by Git. Dry-run / Preview is
implemented.

With Blueprint enabled, the final Bootstrap Summary reports selected/total
item counts and Enabled/Skipped setting categories. Detailed item output
remains available through `--verbose`.
