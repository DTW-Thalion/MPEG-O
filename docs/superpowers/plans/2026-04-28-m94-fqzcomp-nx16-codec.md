# M94 — FQZCOMP_NX16 Codec Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the FQZCOMP_NX16 lossless quality codec (codec id 10) to TTI-O across all three languages, matching CRAM 3.1's quality compression and closing ~55 MB of the v1.2.0 chr22 compression gap.

**Architecture:** fqzcomp-Nx16 (Bonfield 2022, CRAM 3.1 default) — context-modeled adaptive arithmetic coding with 4-way interleaved rANS for SIMD parallelism. Context vector: `(prev_q[0..2], position_bucket, revcomp_flag, length_bucket)` hashed to a uint16 context index. Each context maintains a 256-entry adaptive symbol-frequency table with deterministic halve-with-floor-1 renormalisation at the 4096 max-count boundary. Python implementation links to a C extension (Cython>=3.0); ObjC + Java are native.

**Tech Stack:** Python 3.11+ with C extension (Cython), ObjC + GNUstep + libobjc2, Java 17 + Maven. rANS dependency on existing M83 codec.

**Spec reference:** `docs/superpowers/specs/2026-04-28-m93-m94-m95-codec-design.md` §3 (M94), §11 (perf gates), §12 (binding decisions 80d, 80e). M93's pattern (`docs/superpowers/plans/2026-04-28-m93-ref-diff-codec.md`) is the template — wire-format header + canonical fixtures + 3-language byte-exact + M86 pipeline integration + auto-default in `DEFAULT_CODECS_V1_5`.

---

## File structure

### Python (reference + C extension)

| Path | Action | Responsibility |
|---|---|---|
| `python/src/ttio/enums.py` | modify | Add `Compression.FQZCOMP_NX16 = 10` |
| `python/src/ttio/codecs/fqzcomp_nx16.py` | create | Public Python API + ctypes/cffi shim (~250 lines) |
| `python/src/ttio/codecs/_fqzcomp_nx16/` | create dir | C extension source |
| `python/src/ttio/codecs/_fqzcomp_nx16/_fqzcomp_nx16.c` | create | Inner state machine (~500 lines C) |
| `python/src/ttio/codecs/_fqzcomp_nx16/setup_helpers.py` | create | Cython/setuptools build glue |
| `python/src/ttio/codecs/__init__.py` | modify | Re-export `fqzcomp_nx16_encode`/`fqzcomp_nx16_decode` |
| `python/src/ttio/genomic/_default_codecs.py` | modify | Add `qualities → FQZCOMP_NX16` to `DEFAULT_CODECS_V1_5` |
| `python/src/ttio/spectral_dataset.py` | modify | Add FQZCOMP_NX16 to `_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL["qualities"]`; route through codec when selected |
| `python/src/ttio/genomic_run.py` | modify | Add FQZCOMP_NX16 read dispatch on qualities channel |
| `python/pyproject.toml` | modify | Add `Cython>=3.0` to `[build-system].requires`, configure extension build |
| `python/tests/test_m94_fqzcomp_unit.py` | create | Unit tests (header, context model, adaptive update, 4-way state) |
| `python/tests/test_m94_canonical_fixtures.py` | create | 8 canonical .bin fixtures (write+validate) |
| `python/tests/test_m94_fqzcomp_pipeline.py` | create | M86 pipeline integration |
| `python/tests/perf/test_m94_throughput.py` | create | Throughput regression smoke (≥30 MB/s Python via C ext) |
| `python/tests/fixtures/codecs/fqzcomp_nx16_*.bin` | create | 8 canonical fixtures (a-h per spec §3 M94) |

### Objective-C

| Path | Action | Responsibility |
|---|---|---|
| `objc/Source/HDF5/TTIOEnums.h` | modify | Add `TTIOCompressionFqzcompNx16 = 10` |
| `objc/Source/Codecs/TTIOFqzcompNx16.h` | create | Public API |
| `objc/Source/Codecs/TTIOFqzcompNx16.m` | create | Native impl (~1500 lines) |
| `objc/Source/Dataset/TTIOSpectralDataset.m` | modify | M86 hook + `qualities` allowed-codec extend + read-side dispatch |
| `objc/Source/Dataset/TTIOGenomicRun.m` | modify | Read dispatch on qualities channel |
| `objc/Tests/TestM94FqzcompUnit.m` | create | Unit tests |
| `objc/Tests/TestM94FqzcompPipeline.m` | create | Pipeline integration |
| `objc/Tests/Fixtures/codecs/fqzcomp_nx16_*.bin` | create | Verbatim from Python |
| `objc/GNUmakefile` + `objc/Tests/GNUmakefile` | modify | Build wiring |

### Java

| Path | Action | Responsibility |
|---|---|---|
| `java/src/main/java/global/thalion/ttio/Enums.java` | modify | Add `Compression.FQZCOMP_NX16` (ordinal 10) |
| `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16.java` | create | Native impl (~1500 lines) |
| `java/src/main/java/global/thalion/ttio/SpectralDataset.java` | modify | M86 hook + qualities allowed-codec extend |
| `java/src/main/java/global/thalion/ttio/genomics/GenomicRun.java` | modify | Read dispatch on qualities channel |
| `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16UnitTest.java` | create | Unit tests |
| `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16PipelineTest.java` | create | Pipeline integration |
| `java/src/test/resources/ttio/codecs/fqzcomp_nx16_*.bin` | create | Verbatim from Python |

### Documentation

| Path | Action |
|---|---|
| `docs/codecs/fqzcomp_nx16.md` | create — full M94 codec spec |
| `docs/format-spec.md` | modify — add §10.11, codec table row |
| `WORKPLAN.md` | modify — mark M94 shipped |
| `CHANGELOG.md` | modify — M94 entry under [Unreleased] |
| `ARCHITECTURE.md` | modify — codec stack table row |

---

## Phase 1 — Python reference + C extension (Tasks 1–10)

### Task 1: enum + Cython build deps

- Add `Compression.FQZCOMP_NX16 = 10` to `enums.py`
- Add `Cython>=3.0` to `pyproject.toml` `[build-system].requires`
- Create `python/src/ttio/codecs/_fqzcomp_nx16/` directory with `__init__.py`
- Stub `python/src/ttio/codecs/fqzcomp_nx16.py` raising `NotImplementedError` from both `encode()` and `decode()`
- Create `python/tests/test_m94_fqzcomp_unit.py` with one test: enum value is 10

### Task 2: wire-format header pack/unpack

Per spec §3 M94 wire format. 50 + L bytes total. Magic "FQZN", flags byte (bits 0-3 context flags + bits 4-5 padding_count), context_model_params 16 bytes (context_table_size_log2, learning_rate, max_count, freq_table_init, context_hash_seed, reserved). Python-only (header logic doesn't need C ext).

### Task 3: read-length table compression

The variable-length read_length_table is rANS_ORDER0-compressed. Reuse existing `ttio.codecs.rans.encode/decode`. Header carries `rlt_compressed_len`.

### Task 4: context model in C

Implement context vector hashing in C. Function: `uint16_t fqzn_context(uint8_t prev_q0, prev_q1, prev_q2, uint8_t pos_bucket, uint8_t revcomp, uint8_t length_bucket, uint32_t seed)`. Uses xxhash3 or a simple murmur-style mixer; deterministic.

### Task 5: adaptive frequency table

256-entry uint16 array per context. After each symbol: `freq[s] += learning_rate (=16)`; if `max(freq) > max_count (=4096)` then halve all entries with floor of 1. **Critical: deterministic and identical across implementations** — write a unit test that exercises the exact step-count where renormalisation fires and asserts the post-renorm table.

### Task 6: 4-way interleaved rANS in C

Four parallel rANS encoders/decoders operating on round-robin substreams. Reuse the rANS state primitives from M83 (renormalisation constants, output bit order). Output bytes interleaved round-robin.

### Task 7: top-level encode/decode

- `encode(qualities: bytes, read_lengths: list[int], reverse_complement_flags: list[int]) -> bytes`
- `decode(encoded: bytes) -> bytes` (read_lengths + revcomp flags are recovered from the header)

### Task 8: 8 canonical fixtures (per spec §3 M94)

(a) all-Q40, (b) typical Illumina profile (~Q30 mean, Q20-Q40 range), (c) PacBio HiFi profile (~Q40 majority), (d) 4-read minimum, (e) 1M reads, (f) reverse-complement majority, (g) right-at-renormalisation-boundary (carefully constructed input that fires renorm at a known step), (h) symbol freq saturation.

### Task 9: M86 pipeline integration

Same pattern as M93's `_write_sequences_ref_diff`:
- Add `Compression.FQZCOMP_NX16` to `_ALLOWED_OVERRIDE_CODECS_BY_CHANNEL["qualities"]`
- New `_write_qualities_fqzcomp_nx16(sc, run)` helper
- Per-run revcomp_flags derived from `run.flags` bit 16 (SAM REVERSE flag)
- Per-run read_lengths from `run.lengths`
- Read dispatch in `genomic_run.py` mirroring M93's pattern

### Task 10: defaults + perf smoke

- Update `DEFAULT_CODECS_V1_5` to add `qualities → FQZCOMP_NX16`
- `python/tests/perf/test_m94_throughput.py` asserting Python encode ≥30 MB/s (with C ext) on 100K reads × 100bp qualities

---

## Phase 2 — ObjC normative parity (~7 tasks)

Mirrors M93's Phase 2 structure: enum + skeleton + header + context model + adaptive freq + 4-way rANS + top-level encode/decode + canonical fixture round-trip + M86 integration.

ObjC implementation is native (no C ext indirection). The challenge is matching the C-extension byte output exactly. Pattern: implement in plain C inside `TTIOFqzcompNx16.m` using the SAME state machine as the Python C extension; ObjC just wraps NSData/NSError around it.

**Build expectation**: 3131 → ~3170 PASS (40 new tests).

---

## Phase 3 — Java parity (~7 tasks)

Mirrors M93's Phase 3. Java's lack of native `uint16` for the context-table indices and `uint32` for rANS state requires `int`/`long` with explicit `& 0xFFFF` / `& 0xFFFFFFFFL` discipline.

Per the design spec §3 M94, this is **the hardest cross-language byte-exact piece** because:
- Adaptive frequency tables update at every symbol
- The renormalisation schedule must match across implementations to the symbol
- Java unsigned-arithmetic ceremony adds ~20-30% line count over the C/ObjC versions

**Build expectation**: 781 → ~810 PASS (30 new tests).

---

## Phase 4 — Cross-language conformance + integration

- 8 canonical fixtures md5sum-verified across `python/tests/fixtures/codecs/`, `objc/Tests/Fixtures/codecs/`, `java/src/test/resources/ttio/codecs/`
- Each language decodes all 8 fixtures byte-exact
- Each language's encode produces byte-identical fixture bytes
- chr22 mapped-only benchmark: TTI-O size drops from 191 MB → ~136 MB (qualities channel: 110 MB → ~55 MB)
- M93 + M94 combined ratio target: ~1.6× CRAM (within reach of v1.2.0 1.15× gate after M95 ships)

---

## Phase 5 — Documentation

- `docs/codecs/fqzcomp_nx16.md` — full algorithm + wire format + binding decisions §80d, §80e + per-language perf
- `docs/format-spec.md` — codec table row, §10.11
- `WORKPLAN.md` — M94 marked shipped under Phase 9
- `CHANGELOG.md` — M94 entry
- `ARCHITECTURE.md` — codec stack table row 10

---

## Acceptance gates (post-M94)

- All Python tests pass + ≥30 MB/s Python encode (C ext)
- All ObjC tests pass + ≥100 MB/s encode
- All Java tests pass + ≥60 MB/s encode
- 8 canonical fixtures byte-exact across all three languages
- chr22 mapped-only TTI-O size ≤ 145 MB (predicted ~136 MB)
- v1.2.0 final compression gate (`test_m93_compression_gate.py`) automatically engages once `fqzcomp_nx16.py` is present — once M95 ships too, the gate must pass at ≤1.15× CRAM
