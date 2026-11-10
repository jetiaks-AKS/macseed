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

Configured [Full CI #161](https://github.com/jetiaks-AKS/macseed/actions/runs/42836491162)
completed successfully at `a289442ffe032c8e5477d2c7cdb84aaf6d7c1f5a` across two attempts.
Attempt 1 passed lint, Desktop and regression shards 1 and 4; shards 2 and 3 were
cancelled. Attempt 2 reran shards 2 and 3 and the aggregate validation, retaining
the other successful jobs. This qualifies the configured inventory, not the
standalone coverage and release gates tracked in [TODO](../../TODO.md#cancellation-recovery-and-runtime-reliability).
The subsequent optimization checkpoint remains **HOSTED NOT YET VERIFIED**.

## Reports

- [Test suite audit and optimization — 2026-11-10](TEST-SUITE-AUDIT-2026-11-10.md) —
  complete source inventory, CI #161 timing evidence, bounded optimizations and
  focused local validation; optimized hosted Full CI remains unmeasured.

- [Full CI Phase 1 — 2026-11-10](FULL-CI-PHASE1-2026-11-10.md) — focused fixes,
  bounded Desktop diagnostics, native mouse-tracking correction and case scheduling;
  the configured hosted follow-up completed successfully in CI #161 as recorded above.
- [SSH Core E2E — 2026-11-10](SSH-E2E-2026-11-10.md) — partial
  qualification, focused convergence and Capture privacy follow-ups;
  positive Git-over-SSH and native/hosted gates remain open.
