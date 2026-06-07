# Perf-Suite Repair — P0 (make it run + honest re-baseline) — Design

**Date:** 2026-06-06
**Origin:** `docs/architecture/2026-06-06-perf-suite-analysis.md` findings F-PERF-1..4,
recommendations R-PERF-1..4, 8, 10.
**Scope:** Make the cross-SDK perf harness run again on any checkout, make the CI
perf-regression gate actually fail on a broken/regressed run, port the v1→v2 codec
benchmarks across all three harnesses, and re-capture `tools/perf/baseline.json` to produce
updated numbers. Perf-tooling + CI config only — **no SDK/product code change**. P1 (new
coverage benches) is a separate later cycle.

## Problem (from the analysis)
The perf suite is broken and the CI gate is a silent no-op:
- **F-PERF-1:** `ci.yml:600` runs `run_perf_ci.sh | tee perf-report.md`; the `| tee` masks the
  non-zero exit (GHA default `run:` shell has no `pipefail`) → job green while running nothing.
- **F-PERF-2:** `build_and_run_{python,java,objc}_full.sh` hardcode `ROOT="$HOME/TTI-O"` → wrong
  path in CI (`/home/runner/TTI-O` vs the `/home/runner/work/...` checkout) → file-not-found.
- **F-PERF-3:** all three harnesses reference removed v1 codecs (`name_tokenizer`, `ref_diff`
  → `*_v2`): Python import-errors; Java `ProfileHarnessFull.java:435,482` won't compile
  (`NameTokenizer`/`RefDiff` deleted); ObjC `profile_objc_full.m:992-993,1057,1127` won't
  compile (`TTIONameTokenizer.h`/`TTIORefDiff.h` deleted).
- **F-PERF-4:** `baseline.json` frozen 2026-04-27/30, un-reproducible against current code.

## Changes

### 1. Script-relative root (`tools/perf/build_and_run_{python,java,objc}_full.sh`)
Replace `ROOT="$HOME/TTI-O"` with
`ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"` so the harness resolves
relative to the script, on any checkout. Restore the executable bit (`chmod +x
tools/perf/*.sh`, committed via `git update-index --chmod=+x`).

### 2. CI gate that bites (`.github/workflows/ci.yml`, perf-regression step ~600)
Stop masking the exit code: run `tools/perf/run_perf_ci.sh` **without** `| tee` (capture the
report via `run_perf_ci.sh | tee perf-report.md` is the masking culprit — replace with
`set -o pipefail; run_perf_ci.sh 2>&1 | tee perf-report.md`, or run then `cat`). Simplest:
```yaml
        run: |
          chmod +x tools/perf/*.sh
          set -o pipefail
          tools/perf/run_perf_ci.sh 2>&1 | tee perf-report.md
```
Also add a guard in `run_perf_ci.sh` (or the step) that **fails if any expected
`_out_*/full.json` is missing or empty** before/after the compare, so a harness that
produces no output fails loudly rather than comparing nothing.

### 3. Port v1→v2 codec benches (all three harnesses; keep existing scenario keys)
The benchmark scenario keys (`name_tokenized_encode/decode`, `ref_diff_encode/decode`) stay
the same — they now measure the live v2 codecs. Per harness:
- **`name_tokenizer` → `name_tokenizer_v2`** — drop-in: `encode(names)->bytes`,
  `decode(blob)->list[str]` (Python); `NameTokenizerV2.encode/decode` (Java);
  `TTIONameTokenizerV2`/`TTIONameTokenizerV2Encode` (ObjC).
- **`ref_diff` → `ref_diff_v2`** — needs extra inputs the harness must build from the
  synthetic reads it already generates: `offsets` (uint64, n_reads+1), `reference_md5`
  (16-byte md5 of the synthetic reference), `reference_uri` (a constant string like
  `"synthetic://ref"`). Python signature: `encode(sequences, offsets, positions,
  cigar_strings, reference, reference_md5, reference_uri)`; match the Java
  `RefDiffV2`/ObjC `TTIORefDiffV2` equivalents. Decode takes `(encoded, positions,
  cigar_strings, reference, n_reads)`.
The implementer reads each `*_v2` codec's exact signature before wiring it.

### 4. Re-capture baseline + numbers report
Run the repaired harness on current `main` (offline/synthetic), all three SDKs, and commit
the refreshed `tools/perf/baseline.json` via `run_perf_ci.sh --update-baseline`. Write
`docs/benchmarks/2026-06-06-perf-refresh.md` with the new per-SDK numbers and deltas vs the
old 2026-04-27/30 baseline (expect wins from #217/#218/#202 vectorizations; note the v2
codec scenarios are now a *different* codec than the old baseline measured).

### 5. Hygiene
Rename the CI job (drop "Python + ObjC" → e.g. "Performance regression (all SDKs,
push-to-main)") and fix the stale "Java intentionally absent in v1" comment in
`run_perf_ci.sh` (Java is wired in).

## Local-baseline caveat (important)
The committed baseline is captured on the dev box; the CI perf job runs on a GHA runner
whose absolute timings can differ materially (±10–30%). Because P0 also makes the gate
*enforce*, the **first post-merge push-to-main perf run may flag environment-variance
"regressions"** and turn that job red (it runs after merge, so it doesn't block anything).
Mitigation, included in the plan: after P0 merges, watch the first CI perf run; if it flags
variance-only regressions, re-baseline from the CI run's uploaded `full.json` artifacts via a
small follow-up `--update-baseline` commit (or temporarily widen `regression_threshold_pct`).
This is the standard "local baseline first, CI-calibrate on first run" two-step.

## Invariants & verification
- Tooling + CI only — no `src/`/SDK product code change (harnesses call existing public codec
  APIs only).
- All three harnesses compile/run locally via `bash tools/perf/run_perf_ci.sh` and each emits
  a non-empty `_out_*/full.json`.
- Gate-bites proof: temporarily break a harness (or point at a missing json) and confirm
  `run_perf_ci.sh` exits non-zero AND the CI step would fail (no `| tee` masking).
- `baseline.json` refreshed; `compare_baseline.py` against it reports clean (0 regressions)
  on a second run.

## Success criteria
`bash tools/perf/run_perf_ci.sh` runs all three SDK harnesses end-to-end and compares to a
freshly-captured baseline with no regressions; the CI step fails on a broken/empty run; the
v1→v2 codec benches measure the live codecs; updated numbers are committed
(`baseline.json` + `docs/benchmarks/2026-06-06-perf-refresh.md`). One PR.

## Out of scope (P1, next cycle)
Real-format import benches (BAM/mzML/nmrML), PQC sign/verify, `mate_info_v2`, chained
real-data pipeline, cross-SDK perf parity (R-PERF-5..7). PR-time perf smoke (R-PERF-9).
