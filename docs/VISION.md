# Macseed Vision

Macseed helps people move a supported working environment to a new Mac with
less manual setup and a result they can inspect: **Capture → Rebuild → Verify**.
Users choose what matters, review the changes, and see which selected
requirements were verified and which still need attention.

## Product principles

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
Selected SSH identities are the currently supported secure physical transfer.

New application adapters require a clear portable contract and enough user
value to justify their security and maintenance cost. Macseed should remain
focused rather than grow into a universal configuration framework or recipe
catalog. Existing VS Code support remains part of the product.

## Direction

One authoritative Core serves the official CLI and the planned native Desktop.
Desktop should make Capture, Restore and Environment Status approachable without
reimplementing their behavior. Missing prerequisites should lead to clear guidance
and a fresh check, rather than being mistaken for permanent lack of support.

The next outcomes are a native application and a qualified signed distribution.
The first complete Desktop release is planned as Macseed 1.0, built on the mature
Core from the toolkit/CLI v1.x–v3.3.x line. This does not rename released history
or change the current version. See the [Roadmap](../ROADMAP.md) for stages and
[Architecture](toolkit/ARCHITECTURE.md) for technical boundaries.
