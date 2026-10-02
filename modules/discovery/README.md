# Discovery Engine

Discovery observes supported current state and publishes local Generated
Configuration for Blueprint and Bootstrap. It does not install software, apply
system settings or migrate user content. Domain publication is its permitted
side effect; shared startup may write logs and check prerequisites.

Exporters cover Homebrew, App Store, Git, SSH configuration, Zsh, VS Code,
Workspace and supported macOS settings. Each observes its own domain and follows
**Collect → Validate → Serialize → Safe Publication**. Replace generated files
only after successful preparation; handled failure preserves previous valid state.
Exits are `0` success, `1` warning, `2` error.

[Configuration](../../docs/toolkit/CONFIGURATION.md) owns formats and publication
boundaries; [Architecture](../../docs/toolkit/ARCHITECTURE.md) owns the state flow.
