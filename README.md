# Macseed

**A smarter way to capture, rebuild, and check your Mac setup.**

Macseed is a **Mac setup reconstruction and verification utility**. Capture saves
a reusable description of supported environment state, Rebuild reconstructs it on
a new or existing Mac, and Check shows what matches and what still needs attention.
These three workflows are equally important. Macseed reduces manual setup while
preserving existing user state when safe convergence is not possible. Its
engineering lifecycle is **Capture → Rebuild → Verify**.
Macseed favors a smaller set of valuable, complete and reliable capabilities
over broad shallow coverage.

Applications are installed again, repositories are cloned from remotes, and
supported settings are restored. Macseed does not clone a Mac or transfer
arbitrary user files, application databases, caches, sessions or local project data.
Explicitly selected SSH identities can travel in an encrypted payload. Macseed
does not replace Migration Assistant or Time Machine.

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

Supported state is grouped by how people use it:

- **Standard Setup:** applications and tools, supported macOS settings, and
  VS Code settings and extensions.
- **For Experienced Users:** optional Git configuration, repositories and supported
  worktrees, Workspace folder structure, supported SSH host settings, encrypted SSH
  identity migration, standalone Zsh configuration and supported VS Code workspace
  relationships. Folders and workspace references do not transfer project files;
  repository restoration does not copy local changes.

Capture produces one private `.mbt` Saved Environment. Its normal configuration is
**not encrypted**; review it and transfer it privately. Only the optional SSH
identity payload is encrypted.

Global Verification reports selected requirements after Apply. **Check** compares
a Saved Environment read-only, explaining confirmed matches, differences and
coverage gaps. **Review in Rebuild** is an explicit handoff; it does not apply
changes or remove extras. See [Capture / Restore](docs/CAPTURE-RESTORE.md) for boundaries.

## Project status

The current Core/CLI version is **3.4.0**, including Global Verification,
Environment Comparison and the completed Protocol V1 application interface.
Macseed Core owns the behavior shared by its clients.

Native SwiftUI **Macseed Desktop** presents **Capture**, **Rebuild** (Restore
Prepare/Execute) and **Check** (read-only Bundle-backed comparison/handoff).
Functional Restore Result and Visual Unification are implemented and manually accepted. Stage 16J Operation Logs
and Diagnostic Reports are complete. Operation-wide checkpoint Graceful Stop and
separate Force Stop are implemented, with controlled real-Mac Stop checks accepted.
Performance optimization and an opt-in private trace are implemented through
`c06e530`; individual real-Mac measurements and limits are recorded in
[Desktop qualification](docs/DESKTOP.md#recent-restore-qualification-and-performance).

**Stage 16 remains open.** Assisted App Store Restore is an accepted development
milestone: capture requirements, select/preview, install manually in Apple App Store
and refresh Core verification. Confirmed identity overlap uses Cask-first precedence;
automatic MAS development is archived on `archive/mas-automatic-restore-v4`.
Stage 16H SSH identity migration is completed and manually accepted; identities
remain opt-in, with default `~/.ssh` or explicit safe custom destinations. Independent
SSH Configuration / SSH Keys selection, authorized IdentityFile corrections and
SSH → Git dependencies are implemented. Unified Developer UI is visually accepted.
Secure Check compares authenticated saved key files and their configured references;
it does not prove private-key usability or remote authentication. SSH Configuration
keeps one aggregate `config` result. Joint real-Mac SSH E2E and hosted qualification
of the current Secure Check checkpoint remain open.
Continuing Homebrew qualification, remaining completion/runtime qualification and
Stage 3C durable recovery remain open. Stage 17 packaged
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
- [Git Workflow](docs/git/GIT-WORKFLOW.md) and [Release Process](docs/git/RELEASE-PROCESS.md)
- [Russian convenience copies](docs/ru/INDEX.md) — English is authoritative

## Support and license

Macseed is free and open source under the [MIT License](LICENSE).
Voluntary support is available on [Boosty](https://boosty.to/jetiaks/donate).
