# Macseed Vision

Macseed helps people build and maintain a supported working environment on a new
or existing Mac with less manual setup and a result they can inspect. Fresh
application/tool installation, supported macOS settings and **reusable Saved
Environments** are its primary value. The product tagline is
**Capture. Rebuild. Continue.** The engineering lifecycle is
**Capture → Rebuild → Verify**.
Users choose what matters, review the changes, and see which selected
requirements were verified and which still need attention.

**Capture this Mac, Restore a Mac and Environment Status are equally important.**
A Saved Environment is a reusable reference for selected requirements: capture
once, compare read-only later, then explicitly review, preview and confirm safe
reapplication through Restore. Matching state should require no changes.
Comparison never automatically selects differences or starts Restore.

## Product focus

Everyday value centers on applications, tools and reliably supported macOS settings.
Developer workflows remain optional advanced capabilities within their qualified
Git, Workspace, SSH and Shell contracts. Existing VS Code Settings/Extensions are
optional application extras; they do not imply a universal adapter catalog.
These priorities preserve the scope of existing supported capabilities.
The approved [Product Direction](PRODUCT-DIRECTION.md) records the capability
decisions and planned GUI grouping; Advanced and Application Extras are not yet
implemented presentation groups.

## Product principles

Macseed is deliberately scoped: breadth is secondary to completeness. Prefer a
smaller set of valuable capabilities implemented completely and reliably, with
complexity and maintenance costs suitable for a small developer project.
Supported capabilities should provide meaningful end-to-end value through
**Capture/Observe → Classify/Plan → Rebuild/Transfer → Verify**, as applicable;
checklist coverage alone does not justify a feature.

- Observe before changing; distinguish absence from an observation failure.
- Make selection explicit and show a Preview before Apply.
- Preserve existing data when safe convergence cannot be established.
- Repeat safely: already matching supported state should converge to no-op.
- Report execution outcomes separately from final conformity and coverage gaps.
- Keep private identity transfer separate from ordinary reconstructable state.
- Keep everyday flows simple and put diagnostic detail where it is needed.

Verification must be honest about its scope. A verified selected requirement
is not proof that the entire Mac is identical or that every application works.
Comparison helps explain differences; it does not imply cleanup or removal.

## Boundaries

Macseed reconstructs supported configuration, installs applications, and clones
repositories. It is not a full Mac clone, backup, Migration Assistant replacement,
arbitrary file migrator or application-session copier. Documents, libraries,
databases and runtime state belong to dedicated transfer or backup tools.
Reconstruct what can be safely reacquired; transfer unique portable state only
under a bounded safe contract; leave caches, logs, temporary/derived state and
obsolete artifacts out of migration. This classification is not permission to
delete existing target state. Selected SSH identities are the currently supported
secure physical transfer.

Current Workspace Folders restores structure only. Future work may investigate
bounded transfer of useful unique workspace/local data; that requires an explicit
product and safety contract, not a general backup or file-migration engine, and is
not required for 1.0. Hiding standalone folder structure from ordinary UX first
requires a dependency/compatibility audit; the current Core contract remains intact.

New application adapters require a clear portable contract and enough user
value to justify their security and maintenance cost. Macseed should remain
focused rather than grow into a universal configuration framework or recipe
catalog. Existing VS Code support remains part of the product. Complexity,
security risk and maintenance cost justify narrowing, deferring or rejecting
capabilities whose user value is insufficient. For high-value capabilities,
investigate a bounded safe implementation before reducing the intended outcome.

Applications are a primary focus: continue qualifying existing Homebrew coverage.
Current App Store Restore is assisted: capture requirements, select and preview,
install manually in Apple App Store, then refresh and verify through Core.
Confirmed shared identity gives Homebrew Cask precedence; unresolved identity
preserves both requirements. Automatic MAS development is archived, outside the
active implementation path. Direct/vendor application restoration is not current work.

## Direction

One authoritative Core serves the official CLI and the native Desktop under
development.
Desktop should make Capture, Restore and Environment Status approachable without
reimplementing their behavior. Missing prerequisites should lead to clear guidance
and a fresh check, rather than being mistaken for permanent lack of support.

The next outcomes are completion of the native Desktop and a qualified signed distribution.
The first complete Desktop release is planned as Macseed 1.0, built on the mature
Core from the toolkit/CLI v1.x–v3.4.x line. This does not rename released history
or change the current version. See the [Roadmap](../ROADMAP.md) for stages and
[Architecture](toolkit/ARCHITECTURE.md) for technical boundaries.
