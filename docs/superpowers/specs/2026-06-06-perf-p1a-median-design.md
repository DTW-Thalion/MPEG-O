# Perf P1a — Median-of-N Gate Robustness — Design

**Date:** 2026-06-06
**Origin:** `docs/architecture/2026-06-06-perf-suite-analysis.md` (R-PERF-9 follow-up) +
`docs/benchmarks/2026-06-06-perf-refresh.md` (gate-noise finding). First sub-cycle of P1.
**Scope:** Reduce perf-harness run-to-run variance via op-level median-of-N timing across all
three SDK harnesses, then re-capture the baseline and tighten the regression gate from the
P0 stopgap of 50% back toward ~15%. Perf-tooling only; no SDK product code.

## Problem
P0 restored the perf gate but found single-iteration timing varies **20–46% run-to-run**
(same machine, back-to-back) — so the threshold had to be widened to 50% to avoid
false-positive spam. That's too loose to catch real regressions. Median-of-N timing cuts
the variance so the gate can return to a meaningful threshold.

## Design

### Op-level median timing (build data once; time the op N times; take the median)
Each harness already isolates the *timed op* from data setup. Wrap the op in a median helper:
- **Python (`tools/perf/profile_python_full.py`):** enhance the existing
  `_timed(fn, *args, **kwargs)` to run `fn` `reps` times and return `(median_seconds,
  last_result)`. A discarded warmup call runs first. Every bench already calls `_timed`, so
  this is a **single-function change** — no per-site edits.
- **Java (`tools/perf/ProfileHarnessFull.java`):** add a helper
  `static double timedMedianMs(int reps, Runnable op)` (warmup once, run `reps` times,
  return the median elapsed ms). Refactor the ~15 inline `long s = System.nanoTime(); …;
  metric = (System.nanoTime()-s)/1e6` sites to `metric = timedMedianMs(REPS, () -> op())`.
  Keep the existing one-time HotSpot warmup at startup.
- **ObjC (`tools/perf/profile_objc_full.m`):** add a helper
  `static double timedMedian(int reps, void (^op)(void))` (warmup once, run `reps` times,
  return the median elapsed seconds). Refactor the ~15 inline `double t0 = nowSeconds(); …;
  putSeconds(out, key, nowSeconds()-t0)` sites to `putSeconds(out, key, timedMedian(REPS,
  ^{ op; }))`.

### Parameters
- **`REPS = 5`** (median of 5) plus one discarded warmup → 6 op executions per metric.
- Configurable via a `--reps N` CLI flag in each harness (default 5). `run_perf_ci.sh` passes
  the default; a `--reps 1` reproduces the old single-iteration behavior.

### Re-baseline + tighten threshold
1. Re-capture `tools/perf/baseline.json` with the median harness (`run_perf_ci.sh
   --update-baseline`).
2. **Verify variance dropped:** run `run_perf_ci.sh` (no update) back-to-back against the new
   baseline and measure the max metric drift. Set `regression_threshold_pct` to **~15%** if
   the observed drift is comfortably under 15%; if drift is still higher, set the threshold
   to ~2× the observed drift and note it (don't pick a number the data won't support).
3. Update `docs/benchmarks/2026-06-06-perf-refresh.md` (or a new dated note) with the
   median-based numbers + the measured post-median drift + the chosen threshold.

### Edge cases
- Benches that mutate state (write files, encrypt in place) must be safe to run N times —
  each rep should target a fresh temp path / fresh buffer (the data is built once but the
  *output* per rep must not collide). Verify each refactored site re-targets output per rep
  or operates on a copy. Where a bench genuinely can't repeat cheaply (e.g. an in-place
  destructive op), either snapshot-and-restore per rep or leave it at reps=1 with a comment.
- Clean up the accumulated `_out_*/ttio-codecs-*` temp dirs (173 stale ones observed) — add
  a cleanup at harness start or in the wrapper (hygiene; not strictly required).

## Invariants & verification
- Perf-tooling only — no `src/`/SDK product code; benches measure the same operations.
- All three harnesses run end-to-end via `run_perf_ci.sh` and emit non-empty `full.json`.
- Median is genuinely op-level (data built once per bench, op executed N times) — confirm by
  reading each refactored site.
- Back-to-back `run_perf_ci.sh` drift is measured and the threshold is set to a value the
  data supports (~15% target).
- The gate still bites (a forced regression > threshold fails `compare_baseline.py`).

## Success criteria
Median-of-N timing in all three harnesses (`--reps`, default 5); baseline re-captured;
measured back-to-back drift << the P0 50% (target <15%); threshold tightened to ~15% (or the
data-supported value); numbers report updated. One PR.

## Out of scope (later P1 sub-cycles)
P1b Java transport-input alignment; P1c real-format import benches (BAM/mzML/nmrML); P1d PQC
+ mate_info_v2 benches; P1e cross-SDK perf-parity check.
