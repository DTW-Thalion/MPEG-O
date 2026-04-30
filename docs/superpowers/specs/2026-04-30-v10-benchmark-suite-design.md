# V10 — Comprehensive Benchmark Suite

> **Status:** design approved 2026-04-30.
> Extends the existing V2 perf infrastructure (`tools/perf/`) with
> genomic codec, genomic pipeline, encryption, and streaming benchmarks
> across Python, Java, and Objective-C.

## 1. Goal

Add the six missing performance dimensions to TTI-O's perf regression
infrastructure so that every major code path — spectral and genomic —
has cross-language throughput tracking with automated CI regression
detection.

**Out of scope:** Coverage hardening (CLI mains, branch coverage) is
deferred to a separate C-series milestone.

---

## 2. Existing Infrastructure

V10 extends, not replaces, the V2 perf infrastructure:

- **`tools/perf/baseline.json`** — per-language baseline timings
  (Python, Java, ObjC). Currently covers: ms (4 providers), transport,
  encryption, signatures, jcamp, spectra.build, codecs (rans_o0/o1,
  base_pack, quality_binned, name_tokenized).
- **`tools/perf/compare_baseline.py`** — flattens JSON, computes
  per-metric deltas, reports Markdown table, exits non-zero on
  regression ≥10%.
- **`tools/perf/run_perf_ci.sh`** — orchestrates Python/ObjC/Java
  harnesses, feeds results to compare_baseline.py.
- **`tools/perf/profile_python_full.py`** — multi-function Python
  harness emitting `{results: {group: {phase: secs}}}` JSON.
- **`tools/perf/ProfileHarnessFull.java`** — equivalent Java harness (JSON output).
- **`tools/perf/profile_objc_full.m`** — equivalent ObjC harness (JSON output).
- **`python/tests/perf/test_m93_throughput.py`** etc. — supplementary
  `@pytest.mark.perf` hard-floor gates for individual codecs.

**What's missing:**

| Dimension | Status |
|-----------|--------|
| Genomic codec throughput (REF_DIFF, FQZCOMP_NX16, FQZCOMP_NX16_Z, DELTA_RANS) | MISSING |
| E2E genomic write (WrittenGenomicRun → .tio) | MISSING |
| E2E genomic read (.tio → iterate all reads) | MISSING |
| Random access read latency | MISSING |
| Encryption at genomic scale (10 MiB) | MISSING |
| Streaming throughput (.tis write/read) | MISSING |

---

## 3. Benchmark Groups

### B1: `codecs.genomic` — Per-codec encode/decode

Isolated encode/decode timings for the four genomic codecs not yet in
the harness. Each codec gets a production-scale input (~10 MiB) so the
inner loops are hot for seconds, not milliseconds.

**Workloads (deterministic seeds, identical across languages):**

| Codec | Input | Size |
|-------|-------|------|
| REF_DIFF | 100K reads × 100bp, 100Kbp reference, seeded ACGT mutations | ~10 MiB raw sequences |
| FQZCOMP_NX16 | 100K reads × 100bp quality strings, Q20-Q40 LCG (seed 0xBEEF) | ~10 MiB |
| FQZCOMP_NX16_Z | Same quality input as FQZCOMP_NX16 | ~10 MiB |
| DELTA_RANS | 1.25M sorted ascending int64 positions, LCG deltas 100-500 | ~10 MiB |

**Metrics (seconds):**

| Key | Description |
|-----|-------------|
| `codecs.ref_diff_encode` | REF_DIFF encode |
| `codecs.ref_diff_decode` | REF_DIFF decode |
| `codecs.fqzcomp_nx16_encode` | FQZCOMP_NX16 (v1) encode |
| `codecs.fqzcomp_nx16_decode` | FQZCOMP_NX16 (v1) decode |
| `codecs.fqzcomp_nx16_z_encode` | FQZCOMP_NX16_Z (CRAM-mimic) encode |
| `codecs.fqzcomp_nx16_z_decode` | FQZCOMP_NX16_Z (CRAM-mimic) decode |
| `codecs.delta_rans_encode` | DELTA_RANS encode |
| `codecs.delta_rans_decode` | DELTA_RANS decode |

Input data is generated and held in memory before the timer starts.
Only the codec call is timed.

### B2: `genomic.write` — E2E sequential write

Build a 100K-read WrittenGenomicRun with all channels populated, write
to a temp .tio file. Clock starts after data generation, ends after
file close.

**Channels populated:**
- `positions` — sorted ascending int64, LCG deltas 100-500
- `flags` — 5 dominant uint32 values {0, 16, 83, 99, 163}
- `mapping_qualities` — uint8 Q0-Q60
- `sequences` — ACGTACGT pattern with seeded mutations, 100bp per read
- `qualities` — Q20-Q40 LCG profile, 100bp per read
- `cigars` — "100M" (all fully aligned)
- `read_names` — Illumina-style tokenized names
- `mate_chromosomes`, `mate_positions`, `template_lengths` — seeded

Total raw data: ~80 MB across all channels.

**Metrics:**

| Key | Description |
|-----|-------------|
| `genomic.write` | Wall-clock seconds for full pipeline write |
| `genomic.write_mb` | Raw input size in MB (informational, not regression-tracked) |

### B3: `genomic.read` — E2E sequential read

Open the .tio file written by B2, iterate all 100K reads materializing
each AlignedRead. Clock covers open → full iteration → close.

| Key | Description |
|-----|-------------|
| `genomic.read` | Wall-clock seconds for full pipeline read |

### B4: `genomic.random_access` — Random seek latency

From the same .tio file, access 1000 randomly-selected read indices
(deterministic seed). Report median and 99th-percentile per-read
latency.

| Key | Description |
|-----|-------------|
| `genomic.random_access_p50` | Median per-read access time (seconds) |
| `genomic.random_access_p99` | 99th percentile per-read access time (seconds) |

### B5: `encryption.genomic` — AES-256-GCM at genomic scale

Encrypt then decrypt a 10 MiB byte payload via the per-AU AES-256-GCM
API. Uses the same `encrypt_bytes` / `decrypt_bytes` path as spectral
encryption. Confirms no size-dependent performance cliff.

| Key | Description |
|-----|-------------|
| `encryption.genomic_encrypt` | AES-256-GCM encrypt 10 MiB |
| `encryption.genomic_decrypt` | AES-256-GCM decrypt 10 MiB |
| `encryption.genomic_bytes_mb` | Payload size in MB (informational) |

### B6: `streaming` — .tis write/read throughput

Write 10K spectra to a .tis file via StreamWriter, then read all back
via StreamReader. Uses the harness's standard workload (n=10000,
peaks=16, matching the existing spectral benchmark sizing).

| Key | Description |
|-----|-------------|
| `streaming.write` | Wall-clock seconds to write 10K spectra |
| `streaming.read` | Wall-clock seconds to read all back |

### B7: CI wiring

No new infrastructure. The existing pipeline handles everything:

1. `run_perf_ci.sh` invokes the `*_full` harnesses → JSON output.
2. `compare_baseline.py` flattens JSON, diffs against `baseline.json`.
3. New keys appear as `NEW` on first run.
4. Maintainer runs `--update-baseline` to capture initial numbers.
5. Subsequent runs detect regressions at the 10% threshold.

The supplementary `test_m95_throughput.py` hard-floor gate follows the
existing M93/M94/M94.Z pattern: `@pytest.mark.perf`, conservative
`MIN_ENCODE_MBPS` floor, assertion with diagnostic message.

---

## 4. Files to Modify

### Python

| File | Change |
|------|--------|
| `tools/perf/profile_python_full.py` | Add `bench_codecs_genomic`, `bench_genomic_write`, `bench_genomic_read`, `bench_genomic_random_access`, `bench_streaming` functions. Register in `BENCHMARKS` dict. Add imports for `ref_diff`, `fqzcomp_nx16`, `fqzcomp_nx16_z`, `delta_rans`, `WrittenGenomicRun`, `GenomicRun`, `StreamWriter`, `StreamReader`, `encrypt_bytes`, `decrypt_bytes`. |
| `python/tests/perf/test_m95_throughput.py` | New file. `@pytest.mark.perf` hard-floor gate for DELTA_RANS encode/decode throughput. |

### Java

| File | Change |
|------|--------|
| `tools/perf/ProfileHarnessFull.java` | Add matching genomic benchmark methods emitting the same JSON keys. Import `RefDiff`, `DeltaRans`, `FqzcompNx16`, `FqzcompNx16Z`, `WrittenGenomicRun`, `GenomicRun`, `StreamWriter`, `StreamReader`, `EncryptionManager`. |

### ObjC

| File | Change |
|------|--------|
| `tools/perf/profile_objc_full.m` | Add matching genomic benchmark functions. Import `TTIORefDiff`, `TTIODeltaRans`, `TTIOFqzcompNx16`, `TTIOFqzcompNx16Z`, `TTIOWrittenGenomicRun`, `TTIOGenomicRun`, `TTIOStreamWriter`, `TTIOStreamReader`, `TTIOEncryptionManager`. |

### Infrastructure

| File | Change |
|------|--------|
| `tools/perf/baseline.json` | Add initial baseline values for all new keys under `python`, `java`, `objc` sections (captured via `--update-baseline` after first run). |
| `tools/perf/run_perf_ci.sh` | No changes needed. |
| `tools/perf/compare_baseline.py` | No changes needed. |
| `.github/workflows/ci.yml` | No changes needed. |

---

## 5. Synthetic Data Generation

All workloads use deterministic seeds so runs are reproducible and
cross-language throughput comparisons are meaningful.

**Seeds:**
- Quality data: LCG seed `0xBEEF` (matches existing M94/M94.Z perf tests)
- Position data: LCG seed `0xBEEF`, deltas 100-500
- Sequence mutations: `np.random.default_rng(42)` (Python), equivalent seeded RNG in Java/ObjC
- Random access indices: `np.random.default_rng(99)` for 1000 indices in [0, 100K)
- Read names: sequential `M88_{i:08d}:{lane}:{tile}` pattern (matches existing name_tokenized bench)

**Cross-language parity:** Each language implements the same LCG/seed
to produce byte-identical input data. This is already proven by the
M94.Z perf test which uses the same `0xBEEF` LCG across Python, ObjC,
and Java.

---

## 6. Regression Detection

The existing `compare_baseline.py` handles all regression detection:

- **Threshold:** 10% (configurable via `--threshold` or
  `baseline.json _meta.regression_threshold_pct`).
- **Direction:** Only slower-than-baseline fails. Faster is reported
  as `WIN`.
- **New metrics:** Reported as `NEW` (no fail) until baseline is
  captured.
- **Dropped metrics:** Reported as `DROPPED` (no fail).

The supplementary `@pytest.mark.perf` tests provide an additional
safety net with absolute floors (e.g., DELTA_RANS encode ≥ X MB/s)
that catch catastrophic regressions even when the baseline hasn't been
captured yet.

---

## 7. Binding Decisions

| # | Decision | Rationale |
|---|----------|-----------|
| §V10a | Extend existing `profile_*_full` harnesses rather than creating parallel genomic harnesses. | One CI invocation, one baseline file, unified cross-language comparison table. |
| §V10b | 10 MiB codec workloads, 100K-read genomic pipeline workloads. | Production-representative sizing. Ensures inner loops are hot for seconds, not milliseconds. Small workloads mask real bottlenecks. |
| §V10c | Deterministic seeds matching existing patterns (0xBEEF LCG, `default_rng(42)`). | Reproducible, cross-language comparable, no random-jitter headroom in regression budget. |
| §V10d | Streaming benchmark uses spectral data (10K spectra × 16 peaks), not genomic. | StreamWriter/StreamReader are spectral-oriented APIs. Genomic data flows through WrittenGenomicRun, not streaming. |
| §V10e | Coverage hardening deferred to C-series. | Different kind of work (writing tests for error paths vs. measuring throughput). Keeps V10 focused. |
| §V10f | `encryption.genomic` is a scale test, not a new API test. | Same `encrypt_bytes`/`decrypt_bytes` path; confirms no size-dependent perf cliff at 10 MiB vs. the existing ~0.33 MiB spectral benchmark. |

---

## 8. References

- Existing perf infrastructure: `docs/verification-workplan.md` §V2
- Existing codec benchmarks: `tools/perf/profile_python_full.py` `bench_codecs()`
- M93 perf gate: `python/tests/perf/test_m93_throughput.py`
- M94.Z perf gate: `python/tests/perf/test_m94z_throughput.py`
- M94.Z ObjC perf test: `objc/Tests/TestM94ZFqzcompPerf.m`
