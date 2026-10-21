# Macseed

**Capture. Rebuild. Continue.**

Macseed captures the supported parts of a working Mac, reconstructs them on
another Mac, and reports what matches the selected environment. It reduces
manual setup while preserving existing user state when safe convergence is
not possible. Its engineering lifecycle is **Capture → Rebuild → Verify**.
Macseed favors a smaller set of valuable, complete and reliable capabilities
over broad shallow coverage.

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

Native SwiftUI **Macseed Desktop** has real Capture, Restore Prepare/Execute and
read-only Bundle-backed Environment Status/handoff. Functional Restore Result and
Visual Unification are implemented and manually accepted. Stage 16J Operation Logs
and Diagnostic Reports are complete. Operation-wide checkpoint Graceful Stop and
separate Force Stop are implemented, with controlled real-Mac Stop checks accepted.
Performance optimization and an opt-in private trace are implemented through
`c06e530`; individual real-Mac measurements and limits are recorded in
[Desktop qualification](docs/DESKTOP.md#recent-restore-qualification-and-performance).

**Stage 16 remains open.** Assisted App Store Restore is an accepted development
milestone: capture requirements, select/preview, install manually in Apple App Store
and refresh Core verification. Confirmed identity overlap uses Cask-first precedence;
automatic MAS development is archived on `archive/mas-automatic-restore-v4`.
Continuing Homebrew qualification, Secure SSH Desktop, remaining completion/runtime
qualification and Stage 3C durable recovery remain open. Stage 17 packaged
clean-Mac qualification and Early Access
precede **Macseed 1.0**, the first complete Desktop product release. See the
[Current Execution Order](ROADMAP.md#current-practical-execution-order). The CLI
remains supported and released toolkit/CLI history is preserved.

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
