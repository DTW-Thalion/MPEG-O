# chr22 .tio byte breakdown — Task #82 Phase A diagnostic

**Goal:** identify where the 70 MB excess (TTI-O 169 MB vs CRAM target
99 MB) is hiding, before committing to any structural change.

**Environment:** post-Phase-11 main (HEAD `44270db`), 2026-05-01.
Fixture: `data/genomic/na12878/na12878.chr22.lean.mapped.bam`
(151.42 MB BAM → CRAM 86.09 MB → TTI-O 169.17 MB).

## 1. Top-line ratio

| Format | Size       | vs BAM | vs CRAM |
|--------|-----------:|-------:|--------:|
| BAM    | 151.42 MB  | 1.000× | 1.759×  |
| CRAM   |  86.09 MB  | 0.569× | 1.000×  |
| TTI-O  | 169.17 MB  | 1.117× | **1.965×** |
| **Target (1.15× CRAM)** | **99.01 MB** | 0.654× | 1.150× |

**Excess to shave: 70.16 MB (41.5% of current TTI-O file).**

## 2. Where are the bytes?

| Category                 |        Bytes |  % file |
|--------------------------|-------------:|--------:|
| signal:qualities (M94.Z) | 69,730,304 | **41.22%** |
| **HDF5 framework residual** | 42,570,213 | **25.16%** |
| signal:mate_info         | 11,493,862 | 6.79%  |
| signal:sequences (REF_DIFF) | 11,337,728 | 6.70%  |
| genomic_index            | 10,879,161 | 6.43%  |
| references (embedded chr22) |  9,851,763 | 5.82%  |
| signal:read_names (NAME_TOKENIZED) | 7,143,424 | 4.22% |
| signal:positions (DELTA_RANS) | 2,809,635 | 1.66% |
| signal:cigars (rANS-O1)  |  2,097,152 | 1.24%  |
| signal:flags             |    941,257 | 0.56%  |
| signal:mapping_qualities |    307,648 | 0.18%  |
| run_provenance           |        267 | 0.00%  |

Two buckets dominate: **qualities (41%) and HDF5 framework residual
(25%)**. Together that's 66% of the file, and any meaningful gap-closing
plan has to address them.

## 3. The HDF5 "framework residual" is one dataset

Free space inside the file: **0** (per `H5Fget_freespace`). So the
42.6 MB isn't waste — it's bytes between data chunks where HDF5 puts
its own structures (B-trees, object headers, fractal heap blocks).
Walking the chunk-byte-offset array shows where:

| Gap size | Where (pre-chunk → next-chunk) |
|---:|---|
| 12,589,376 B | (start of `genomic_index/chromosomes` dataset) |
| 131,072 B   | between `genomic_index/chromosomes` chunks (×4) |
| 102,496 B   | between `chromosomes` chunks (×7)             |
|  98,304 B   | between `chromosomes` chunks (×400+)          |

**All large gaps cluster around `genomic_index/chromosomes`.** That
dataset has shape `(1766433,)`, dtype `[('value', 'O')]` (a compound
holding a single VL-string field), chunked at `(4096,)` = 432 chunks.

Each chunk is followed by a 98–131 KB block, which is HDF5's fractal
heap for the variable-length strings inside the compound type. 432
chunks × ~98 KB/gap ≈ 42 MB.

**The actual data:** all 1,766,433 entries are the byte-string `b'22'`.
Every read in this fixture maps to chromosome 22. We are spending
42 MB of fractal-heap overhead to repeat one short string 1.77M times
in a VL-string compound.

This is an M82-era container shape that didn't get migrated when M86
Phase F decomposed the `signal_channels/mate_info` compound into
parallel uint8/int64/int32 columns. The same decomposition applied to
`genomic_index/chromosomes` would replace the compound with a flat
column (uint8 / uint16 chrom-id + a small string lookup table) and
**eliminate the entire 42 MB**.

## 4. Qualities are still 0.395 bytes/quality

Raw qualities = 1,766,433 reads × 100 bp = 176,643,300 bytes.
M94.Z-encoded = 69,712,776 bytes. **Compression ratio = 0.395
bytes/quality.** CRAM 3.1 fqzcomp-Nx16 typically reaches
0.20–0.25 bytes/quality on similar Q20–Q40 Illumina data, so qualities
carry ~25–35 MB of headroom against CRAM-class compression.

This is codec-tier work — independent of the HDF5 framing fix.
Levers worth exploring (in approximate order of likely yield):

1. Adaptive freq updates inside a block (CRAM does this; M94.Z is
   static-per-block by design — see
   `docs/superpowers/specs/2026-04-29-m94z-cram-mimic-design.md` §1.3).
2. Larger context window (current `qbits=12, pbits=2, sloc=14` =
   16384 contexts; CRAM uses up to 4096 contexts but with adaptive
   updates it sees more effective patterns).
3. Per-quality bucket model (htslib's fqzcomp tracks `prev_qual` more
   aggressively).

All three would break the on-wire byte format. Either the codec id
bumps (12 → 13 say) and v1.5 readers stay valid, or M94.Z is
versioned at `version_byte = 3` (currently 1 = pure-language,
2 = libttio_rans body).

## 5. Other notable items

- **`genomic_index/positions` (2.81 MB) duplicates `signal_channels/positions` (2.81 MB).**
  The index column was meant for random-access seek-by-position, but
  the same data lives uncompressed in the signal channel. ~3 MB
  potentially recoverable by computing the index lazily or storing
  only deltas.
- **`references/1/chromosomes/22/data` (9.85 MB)** is the embedded
  chr22 reference (51 Mbp deflate-compressed). Useful for fully
  self-contained `.tio` files but optional — CRAM does not embed by
  default. Making this opt-in (already supported per spec) and
  defaulting off saves 10 MB on this fixture.
- **`signal_channels/mate_info/chrom` (5.3 MB)** is the flat uint8
  column produced by M86 Phase F. Reasonable for 1.77M
  NAME_TOKENIZED-encoded chrom names. Not the hot spot.

## 6. Suggested Phase B levers

Ranked by expected savings × difficulty:

| ID | Lever | Savings | Difficulty | Wire impact |
|----|-------|--------:|------------|-------------|
| L1 | Decompose `genomic_index/chromosomes` from VL-string compound to uint16 chrom-id + string lookup | **~42 MB** | Low — same template as M86 Phase F mate_info decomp | Wire break: minor (one column shape) |
| L2 | Tune M94.Z toward CRAM fqzcomp parity | ~25 MB | High — codec design + spec proof per `feedback_phase_0_spec_proof` | Wire break: major (new codec id) |
| L3 | Default `embed_reference=False`, opt-in via writer arg | ~10 MB | Trivial — flag flip + smoke-test fixture refresh | Backwards-compat |
| L4 | Drop `genomic_index/positions` (duplicate of signal channel) or store deltas only | ~3 MB | Easy | Wire break: minor |
| L5 | Tune `genomic_index/offsets` (uint64 → varint or base+i32) | ~2 MB | Easy | Wire break: minor |

**L1 alone** lands the file at ~127 MB = 1.476× CRAM. Combined with
L3 → 117 MB = 1.36× CRAM. L1 + L3 + L4 + L5 → 112 MB = 1.30× CRAM.
**L1 + L2 + L3 + L4 + L5 → ~87 MB = 1.01× CRAM** (target met or
beaten).

L1 is the single biggest, lowest-risk win. L2 is the only one that
requires codec-level work and a spec-proof phase per the wire-format-
break checklist.

## 7. Phase B.1 progress — actual savings

| Stage | TTI-O size | × CRAM | Δ | Lever |
|-------|-----------:|-------:|---:|-------|
| Pre-L1 | 169.17 MB | **1.965×** | — | baseline |
| L1 (Python+Java+ObjC) | 123.61 MB | 1.436× | -45.56 MB | chromosome_ids + names |
| L3 (Python+Java+ObjC) | 113.72 MB | **1.321×** | -9.89 MB | default embed_reference=False |

**Cumulative:** -55.45 MB (33% smaller). Closed 60% of the gap to the
1.15× CRAM target.

### L4 / L5 status (deferred)

* **L4 — drop genomic_index/{positions, mapping_qualities, flags}
  duplicates:** estimated ~4 MB. Implementation attempt revealed an
  architectural conflict — when v1.5 auto-codec defaults are active
  (which is the chr22 benchmark's case AND most production paths),
  ``signal_channels/{positions, mapping_qualities, flags}`` are stored
  as rANS-encoded byte streams, not raw integer arrays. The
  ``GenomicIndex`` reader can't simply pivot to read from there
  without going through the codec dispatch in
  ``GenomicRun._int_channel_array``, which has chicken-and-egg
  ordering against ``GenomicIndex.read``. Reverted; needs a
  pre-Phase-A redesign. Tracked as deferred.

* **L5 — tune genomic_index/offsets encoding:** estimated ~1-2 MB
  (uint64 → uint32 + gzip, or DELTA_RANS). Modest payoff against the
  risk of breaking >4 GB-offset files (uint32 overflow at 4 GB total
  read-data; reachable on deep WGS). Deferred.

## 8. Phase B.2 (L2) results — adaptive M94.Z V3 (Range Coder)

Measured 2026-05-02 at HEAD `72eb845` with
`TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so`
(absolute path required — `$PWD` does not survive nested `wsl … bash -c`
invocations, see `feedback_msys2_paths`). Qualities-stream version byte
verified `0x03` end-to-end.

| Stage | TTI-O | × CRAM | qualities | B/qual | Δ vs prev |
|---|---:|---:|---:|---:|---:|
| Pre-L2 (post-L1+L3, V1 static) | 113.72 MB | 1.321× | 69.73 MB | 0.395 | — |
| L2 — adaptive M94.Z V3 (sloc=14) | **113.33 MB** | **1.316×** | 69.34 MB | 0.393 | **−0.39 MB** |

**Phase 4 hard gate: FAILED.** Target was ≤ 99 MB (1.15× CRAM); we are
14.32 MB over. Per spec §10, this blocks Phase 5 (Java JNI) and Phase 6
(ObjC) wrappers — those only run after the gate passes.

The key finding is the **0.002 B/qual** delta on chr22 qualities
(0.395 → 0.393). Per-symbol adaptive frequencies alone, on top of the
same context formula (`prev_q × pos_bucket × revcomp`, sloc=14), do
not move the needle. Block sizes (~177 M qualities ÷ 16 384 contexts ≈
10 800 symbols/ctx) are large enough that V1's per-block static
frequency fit is already near-optimal for that context model.
Adaptivity essentially saves only the freq-tables sidecar (~5–10 KB),
which amortizes to rounding error at chr22 scale. The fixtures showed
dramatic V3 drops (`m94z_b` 49 945 → 22 188 bytes, 0.444 → 0.197 B/sym)
because at small scale the freq-tables blob dominates V1 overhead — at
chr22 scale that blob amortizes to nothing.

The Range-Coder pivot itself is sound: the V3 wire format, C kernel
(`ttio_rans_encode_block_adaptive` / `ttio_rans_decode_block_adaptive_m94z`),
and Python ctypes wrapper all ship working with 553 M94.Z tests green.
That infrastructure is reusable for any future richer-context attempt.

**What's needed to close the gap:** a richer **context model**, not a
better entropy coder. CRAM 3.1 fqzcomp's actual edge over us comes from
context features we don't capture — per-quality bucket selectors
(`last_qN` ladder), 2-symbol joint history (not bit-packed shift
register), rare-symbol escape models, per-position model mixing,
length bucket, distance from read start. Each is its own subsystem.
Tracked as **WORKPLAN Task #84** (richer-context M94.Z).

Encode wall: 25.83 s (numpy-vectorized context derivation + first-
encounter pass, see §8.1 below). Decode wall: 19.15 s (V3 native
fast-path).

### 8.1 V3 encode perf — vectorization follow-up

The first V3 wrapper landed at HEAD `72eb845` did context derivation
(`_build_context_seq`) and the sparse-→-dense first-encounter pass in
pure Python loops over the full 178 M-quality sequence — no Cython,
no numpy. cProfile + wall-clock cross-check on chr22 attributed
~89 s of the 110 s wall to `_build_context_seq` alone (178 M calls
each into `m94z_context` and `position_bucket_pbits`), and ~7 s to the
dict-based first-encounter pass.

Both paths were rewritten using numpy at HEAD `<this commit>`:

* `_build_context_seq_arr_vec` — iterates `p = 0..max_len-1` (≤ 101
  on chr22) and updates `n_reads` per-read `prev_q` ring states in
  parallel. Output is `ndarray[uint16]` — zero-copy ctypes view into
  the C kernel's `dense_seq` buffer.
* `_vectorize_first_encounter` — exploits the bounded value range
  (`[0, 1 << sloc)` = 16 384 buckets) to do a scatter-min via
  `np.minimum.at`, then `argsort(first_idx, kind="stable")` to recover
  the encounter order. Identical `sparse_ids` ordering to the dict-loop.

Result on chr22: encode wall **124.79 s → 25.83 s (4.8×)**; output
byte-exact (113.3261 MB / qualities 69 299 472 bytes / version byte
`0x03` all match the pre-vectorization run). 553 M94.Z tests green;
full Python suite 1811 passed.

## 9. Remaining 1.32× → 1.15× gap (~14 MB)

Almost the entire remaining gap is **qualities** (post-V3 still 61% of
the file at 0.393 bytes/quality vs CRAM's ~0.20-0.25). Closing this
needs codec-level work on M94.Z — richer context model (length bucket,
distance from read start, error context), per-quality bucket modelling,
or a fundamentally different scheme (e.g. neural / mixture model). That
is **WORKPLAN Task #84**, multi-week scope, and requires a math/spec
proof phase per ``feedback_phase_0_spec_proof`` before implementation.

## 10. Reproducing this report

```bash
# Fresh chr22 benchmark
.venv/bin/python -m tools.benchmarks.cli run \
    --dataset chr22_na12878_mapped \
    --formats bam,cram,ttio \
    --json-out /tmp/bench.json

# Categorise dataset bytes
.venv/bin/python tools/benchmarks/tio_byte_breakdown.py \
    tools/benchmarks/_work/chr22_na12878_mapped/ttio/chr22_na12878_mapped.tio \
    --cram tools/benchmarks/_work/chr22_na12878_mapped/cram/chr22_na12878_mapped.cram

# Find big gaps in the file (HDF5 metadata clusters)
.venv/bin/python tools/benchmarks/tio_gap_audit.py \
    tools/benchmarks/_work/chr22_na12878_mapped/ttio/chr22_na12878_mapped.tio

# Per-dataset chunk audit (chunk count, sizes, B/chunk)
.venv/bin/python tools/benchmarks/tio_chunk_audit.py \
    tools/benchmarks/_work/chr22_na12878_mapped/ttio/chr22_na12878_mapped.tio
```

Scripts live at `tools/benchmarks/tio_byte_breakdown.py`,
`tio_chunk_audit.py`, `tio_gap_audit.py` for reproducibility.
