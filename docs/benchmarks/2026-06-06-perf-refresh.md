# TTI-O Performance Refresh — 2026-06-06 (post-repair re-baseline)

First trustworthy cross-SDK perf numbers since the suite was repaired (perf-suite P0:
`docs/superpowers/specs/2026-06-06-perf-repair-p0-design.md`). The harness had been broken
and the CI gate a silent no-op since the codec-v2/registry refactors — see
`docs/architecture/2026-06-06-perf-suite-analysis.md`. These numbers replace the stale
2026-04-27/30 baseline in `tools/perf/baseline.json`.

**Environment:** WSL2 Ubuntu 24.04, single core, dev box (`/home/toddw`); JDK 25; native
`libttio_rans` + `/usr/local` HDF5; `n=10000 peaks=16`; synthetic data (offline). Numbers
are **dev-box local** — CI-runner timings will differ; the ±10% gate + post-merge
re-baseline absorb that.

## Headline numbers (selected scenarios; ms = milliseconds, single timed iteration)

| Scenario | Python | Java | ObjC |
|----------|-------:|-----:|-----:|
| `ms.hdf5` write | 57 | 50 | 60 |
| `ms.hdf5` read | ~10 | 7 | 6 |
| `transport.plain` encode | 248 | 68† | 100 |
| `transport.plain` decode | 333 | — | 82 |
| `encryption` encrypt / decrypt | ~261 / ~132 | — | 86 / 66 |
| `codecs.genomic` ref_diff enc / dec | 182 / 114 | 117 / 99 | 95 / 74 |
| `codecs.genomic` fqzcomp_nx16_z enc | 510 | 442 | 403 |
| `codecs.genomic` delta_rans enc / dec | — | 111 / 66 | 22 / 61 |
| `genomic` write / read | 976 / 1968 | 872 / 663 | 841 / 168 |
| `genomic` random-access p50 / p99 | — | 0.4 / 0.5 | 0.4 / 0.4 |

The authoritative, full per-scenario numbers live in `tools/perf/baseline.json` (15 scenario
groups × 3 SDKs, 58 metrics each, 0 null). This table is a human-readable digest.

†See the Java-transport note below.

## What changed vs the old (2026-04-27/30) baseline
- **ref_diff / name_tokenized are now the V2 codecs.** The old baseline measured the v1
  pure-language codecs (since removed). V2 is native-backed (`libttio_rans`), so the new
  ref_diff numbers (~95–182 ms enc) are **dramatically faster** than the old v1 figures
  (~1.1–1.3 s) — but this is an algorithm/implementation change, **not** a like-for-like
  speedup. Treat ref_diff/name_tokenized as a fresh baseline, not a delta.
- Genomic + DELTA_RANS paths reflect the recent vectorization PRs (#217 Python DELTA_RANS +
  signal-channels handle cache; #218 Java/ObjC GenomicIndex; #202 region queries).
- All other scenarios (ms.*, transport, encryption, streaming, jcamp, signatures, rANS,
  base_pack, quality_binned) are within run-to-run jitter of the old numbers.

## Known cross-SDK non-comparabilities (P1 follow-ups)
- **Java `transport.plain` source is ~8.68 MB vs Python/ObjC ~0.33 MB** — the Java
  `benchTransport` builds a ~26× larger synthetic `.tio` than the other two harnesses, so
  the Java transport encode/decode numbers are **not** comparable to Python/ObjC's. This is
  a pre-existing harness inconsistency (predates the P0 repair). P1 should align the
  transport input size across SDKs for true cross-SDK parity.
- **Python `genomic` read (1968 ms) is ~3× Java / ~12× ObjC** — a real gap (pure-Python
  iteration), a candidate optimization target.
- The ObjC non-HDF5 provider writes (`ms.memory/sqlite/zarr`) now populate (the harness
  repair fixed them); they were `null` in the old baseline.

## How these were captured
```
cd ~/TTI-O
JAVA_HOME=~/jdk25 TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so \
  bash tools/perf/run_perf_ci.sh --update-baseline
```
Offline/synthetic, ~5–10 min, all three SDKs. The CI `perf-regression` job (now enforcing
again after the P0 fix) compares future push-to-main runs against this baseline at ±10%.

## Caveat (re-baseline calibration)
This baseline is dev-box local. The first post-merge CI perf run may flag environment-variance
"regressions" (CI runner vs dev box); if so, re-baseline from that run's uploaded `full.json`
artifacts (the documented "local baseline first, CI-calibrate on first run" two-step).
