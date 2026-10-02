# Macseed

**Capture → Rebuild → Verify**

Macseed captures the supported parts of a working Mac, reconstructs them on
another Mac, and reports what matches the selected environment. It reduces
manual setup while preserving existing user state when safe convergence is
not possible.

Applications are installed again, repositories are cloned from remotes, and
supported settings are restored. Macseed does not clone a Mac or transfer
arbitrary user files, application databases, caches or sessions. Explicitly
selected SSH identities can travel in an encrypted payload.

## Use Macseed today

The official CLI supports these workflows:

```bash
bs workflow                         # Select, preview and apply on this Mac
bs capture                          # Create a private Bundle on the source Mac
bs restore /path/to/environment.mbt  # Rebuild on the target Mac
bs compare                          # Compare selected state with this Mac
```

Clone the repository on each Mac. Before `bs` is installed, run the equivalent
`./bootstrap.sh --workflow`, `--capture`, `--restore <bundle>` or `--compare`
from its root. See the [CLI Quick Start](docs/getting-started/QUICKSTART.md).

Supported state includes Homebrew and App Store applications, VS Code,
Git and SSH configuration, standalone Zsh configuration, Workspace structure
and repositories, and selected macOS settings. Capture produces one private
`.mbt` Bundle; its normal configuration is **not encrypted**. Review it and
transfer it privately. Only the optional SSH identity payload is encrypted.

Global Verification reports selected requirements after Apply. Explicit
Environment Comparison reports differences and supported extras without
removing anything. See [Capture / Restore](docs/CAPTURE-RESTORE.md) for boundaries.

## Project status

The current Core/CLI version is **3.4.0**, including Global Verification,
Environment Comparison and the completed Protocol V1 application interface.
Macseed Core owns the behavior shared by its clients.

A native SwiftUI **Macseed Desktop** is the next stage; `Macseed.app` is not
implemented yet. The CLI remains supported. The first complete Desktop product
release is planned as **Macseed 1.0**, preserving the toolkit/CLI release history.

## Documentation

- [Documentation index](docs/README.md) and [Vision](docs/VISION.md)
- [Architecture](docs/toolkit/ARCHITECTURE.md)
- [CLI](docs/toolkit/CLI.md) and [Configuration](docs/toolkit/CONFIGURATION.md)
- [Core application interface](docs/core/APPLICATION-INTERFACE.md)
- [Desktop](docs/DESKTOP.md) and [Distribution](docs/DISTRIBUTION.md)
- [Roadmap](ROADMAP.md) and [Changelog](CHANGELOG.md)
- [Russian convenience copies](docs/ru/INDEX.md) — English is authoritative

## Support and license

Macseed is free and open source under the [MIT License](LICENSE).
Voluntary support is available on [Boosty](https://boosty.to/jetiaks/donate).
