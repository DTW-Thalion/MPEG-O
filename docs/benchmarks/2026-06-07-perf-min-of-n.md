# Perf P1a — min-of-N gate robustness (2026-06-07)

**Scope:** Make the cross-SDK perf gate trustworthy enough to tighten the regression
threshold from the P0 stopgap of 50% back toward a meaningful value. Perf-tooling only — no
SDK product code; the benches measure the same operations as before.

**Outcome:** Threshold tightened **50% → 15%** on the regression-critical compute / transport /
codec paths, via four changes: min-of-N timing, an absolute floor, a 10× workload, and a
small two-tier override list. The suite is now **manual-only** (removed from CI).

See `docs/superpowers/specs/2026-06-06-perf-p1a-median-design.md` (+ its 2026-06-07 addendum)
for the design and the empirical pivot from the originally-planned median-of-N.

## How to run (manual)

```bash
# On the box that captured tools/perf/baseline.json (numbers are hardware-specific):
bash tools/perf/run_perf_ci.sh                   # gate vs baseline (~15-20 min at n=100000)
bash tools/perf/run_perf_ci.sh --update-baseline # accept new numbers as the baseline
PERF_N=10000 bash tools/perf/run_perf_ci.sh      # quick smoke run (~3-5 min)
```

Not run in CI: the baseline is calibrated to local hardware; GitHub `ubuntu-latest` runners
are noisier and produce non-comparable numbers. The `perf-regression` job was removed from
`.github/workflows/ci.yml`.

## What each lever bought (worst regression-direction drift, two back-to-back runs)

Drift = abs % difference of a metric between two runs of identical code (so it is pure
run-to-run noise). "above floor" = baseline ≥ 5ms (sub-ms metrics are meaningless in %).

| Configuration | worst +drift above 5ms floor | # metrics >15% (≥5ms) |
| --- | ---: | ---: |
| P0: single iteration, n=10000 | ~50% (both runs FAILed the 50% gate) | many |
| median-of-5, n=10000 | 18.6% / 50.4% | 8 |
| **min-of-7, n=10000** | 42.5% / 42.8% | 8 (storage I/O) |
| **min-of-7, n=100000 (10×)** | **15.4% / 14.3%** | **1** (`ms.sqlite.write`) |

- **median → min-of-N (default reps 5 → 7).** The minimum is the least-interfered sample
  (contention only ever makes an op slower), so it is the most reproducible estimate of true
  cost. Cut the noisy-metric count from 32 (median) to ~8 and brought all compute/codec
  metrics to ~6–18%.
- **Absolute floor (`min_abs_ms` = 5ms).** Sub-ms metrics (`spectra.build.*` ~0.0001ms,
  `ms.memory.*` ~0.4ms) swing +100–266% on pure jitter. The floor suppresses a metric only
  when BOTH baseline and new are below it, so a genuine sub-floor→above-floor jump still fails.
- **10× workload (`PERF_N` 10000 → 100000).** Lengthens ops so fixed jitter is a small
  fraction. Stabilised the storage I/O that min-of-N alone could not: `ms.zarr.read`
  42% → 3.4%, `ms.zarr.write` 35% → 5%, `jcamp.ir_read` 40% → 5.3%,
  `jcamp.raman/uvvis_read` ~40% → <1%.

## Residual noise after all levers (10×, min-of-7) — the override list

Above the 5ms floor, across both drift runs, only four metrics exceed 15% (either
direction, so symmetric-noise-safe). Everything else — all transport, all codecs except
`rans_o1_decode`, all storage except `sqlite.write`, all spectra — is **≤8.5%**.

| metric | observed drift | gate treatment | why |
| --- | ---: | --- | --- |
| `encryption.genomic.encrypt` | +25% … −85% | override 1000 (report-only) | **bench-validity bug:** 3.7ms to AES 10.48MB is physically impossible; the op measures something degenerate. Flagged for P1d. |
| `encryption.genomic.decrypt` | −57% | override 1000 (report-only) | same as above |
| `ms.sqlite.write` | +14–15% | override 30% | sqlite fsync latency; reproducible ~15%, given ~2× margin |
| `codecs.rans_o1_decode` | ±17% | override 30% | reproducible ~17%; given ~2× margin |

Everything not on this list is gated at the tight **15%** global threshold — so a genuine
≥15% regression in any codec, transport path, or the bulk of storage ops is caught.

## Final gate configuration (`tools/perf/baseline.json` `_meta`)

```json
"regression_threshold_pct": 15.0,
"min_abs_ms": 5.0,
"metric_overrides": {
  "encryption.genomic.encrypt": 1000.0,
  "encryption.genomic.decrypt": 1000.0,
  "ms.sqlite.write": 30.0,
  "codecs.rans_o1_decode": 30.0
}
```

Gate verified against a fresh run: **clean** at these settings (`OK — no regressions above
±15.0%`) and still **bites** at `--threshold 0.001` (`FAIL`). `compare_baseline.py` floor +
override logic covered by `tools/perf/test_compare_baseline.py` (9 tests).

## Representative baseline numbers (n=100000, min-of-7, this box)

Full numbers in `tools/perf/baseline.json`. Headline ops (Python, ms):

| op | ms |
| --- | ---: |
| `transport.plain` encode / decode | see baseline.json |
| `codecs.genomic.fqzcomp_nx16_z` encode / decode | ~424 / ~397 |
| `codecs.genomic.ref_diff` encode / decode | ~164 / ~89 |
| `codecs.genomic.delta_rans` encode / decode | ~22 / ~21 |
| `ms.hdf5` write / read | see baseline.json |

(Cross-SDK comparison is deferred to P1e; Java `transport.plain` still uses a ~26× larger
input than Python/ObjC — P1b.)

## Follow-ups

- **P1b** (next): align Java `transport.plain` input size with Python/ObjC.
- **P1d:** investigate the `encryption.genomic.encrypt/decrypt` bench validity (impossible
  timing); once fixed, drop the report-only overrides.
