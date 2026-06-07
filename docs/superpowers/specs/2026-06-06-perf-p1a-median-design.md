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

---

## Addendum (2026-06-07) — empirical pivot: min-of-N + floor + 10× + two-tier, manual-only

Implementation surfaced data that overturned the central assumption above (median-of-N
would *enable* a ~15% gate). What the measurements showed, and the resulting design:

1. **Median-of-N was insufficient.** After porting median-of-5 to all three harnesses and
   re-baselining, two back-to-back drift runs (identical code) still showed worst
   regression-direction drift of **18.6%** and **50.4%** on a real 24ms op
   (`delta_rans_decode`). The dev box's between-run jitter alone reaches ~50%; median within
   a single run cannot remove it. The 50% P0 gate was already flaky (both runs FAILed).

2. **Switched median → min-of-N (default reps 5 → 7).** The minimum is the least-interfered
   sample (contention only ever makes an op slower), so it is the most reproducible estimate
   of true cost. This cut the noisy-metric count from 32 to ~8 and brought the compute/codec
   metrics (where real algorithmic regressions show up) to ~6–18% drift.

3. **Added an absolute floor (`_meta.min_abs_ms`, 5ms).** Sub-ms metrics
   (`spectra.build.*` ~0.0001ms, `ms.memory.*`) swing +100–266% on pure noise. The floor
   suppresses a metric only when BOTH baseline and new are below it, so a genuine
   sub-floor→above-floor jump still fails. Implemented + unit-tested in `compare_baseline.py`.

4. **Bigger workload (`PERF_N` 10000 → 100000).** 10× lengthens ops so fixed jitter is a
   smaller fraction. This stabilised most storage I/O to <3% (`ms.zarr.write` 35%→2%,
   `ms.hdf5.*`, `ms.sqlite.*`, `jcamp.raman/uvvis_read` ~40%→<1%). A small enumerable tail
   stays ~30–40% regardless (`ms.zarr.read`, `jcamp.ir_*` — `ir` is first-in-group and eats
   cold-cache cost): irreducible OS page-cache/ordering jitter on a shared Windows/WSL box.

5. **Two-tier threshold (`_meta.metric_overrides`).** A tight global threshold gates the
   compute-bound metrics that matter; a small documented per-metric override (~50%) covers
   the inherently-noisy storage reads so they can't force the global gate loose. Standard
   practice for perf bots (V8/Chromium). Implemented + unit-tested in `compare_baseline.py`.

6. **Removed from CI; now manual-only.** `baseline.json` is calibrated to the maintainer's
   local box; GitHub `ubuntu-latest` runners are noisier and would produce non-comparable
   numbers. The `perf-regression` job is deleted from `.github/workflows/ci.yml`; the suite
   is run manually/occasionally (e.g. around a major release) via
   `bash tools/perf/run_perf_ci.sh` on the box that captured the baseline. Removing the
   runtime constraint is what made the 10× workload affordable.

**Revised success criteria:** min-of-7 in all three harnesses (`--reps`, default 7);
`compare_baseline.py` gains `min_abs_ms` floor + `metric_overrides` (both unit-tested);
`PERF_N`/`PERF_PEAKS` configurable (default 100000/16); baseline re-captured at 10×; global
threshold set to the data-supported value with a short, documented override list for the
noisy storage reads; perf job removed from CI and documented as a manual command; numbers
report written. One PR.
