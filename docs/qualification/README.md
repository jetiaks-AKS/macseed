# Qualification evidence

Store significant, reusable, sanitized E2E and integration qualification reports here.
Use dated file names (`TOPIC-YYYY-MM-DD.md`) and distinguish actual PASS, FAIL,
BLOCKED and NOT RUN evidence. Record isolation, tested revision, boundaries and
remaining gates; do not commit credentials, personal inventories, raw logs or
routine test output. Add focused follow-ups to an existing report when appropriate.

[ROADMAP](../../ROADMAP.md) owns current status and execution order;
[TODO](../../TODO.md) owns unfinished work. Link to evidence instead of repeating
test logs in either document. Preserve historical observations and repair links
when reports are moved.

## Reports

- [Full CI Phase 1 — 2026-11-10](FULL-CI-PHASE1-2026-11-10.md) — focused fixes,
  bounded Desktop diagnostics and case scheduling; exact hosted GUI stall cause
  and next Full CI qualification remain open.
- [SSH Core E2E — 2026-11-10](SSH-E2E-2026-11-10.md) — partial
  qualification, focused convergence and Capture privacy follow-ups;
  positive Git-over-SSH and native/hosted gates remain open.
