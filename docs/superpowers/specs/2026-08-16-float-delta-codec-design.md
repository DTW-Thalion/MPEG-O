# FLOAT_DELTA_ZSTD — spectral float64 channel codec (codec id 17)

> **Status (2026-08-16).** Spec-proof phase output of the 2026-08
> compression audit's R1. Measured bake-off on real Orbitrap data
> (PXD000001) plus synthetic NMR / Raman corpora; design decided,
> implementation NOT started — this document is the gate.

> **Out of scope:**
> - A Pco/ALP-class binning codec (revisit as codec id 18 only if the
>   residual gap over this codec ever justifies a Rust dependency or
>   a from-scratch C entropy pipeline; see §3).
> - Lossy tiers of any kind (audit R7 — separate policy decision).
> - Integer index channels (`positions` et al. already have
>   DELTA_RANS_ORDER0; spectrum_index arrays are noise-level bytes).
> - Changing the genomic channels (already CRAM-class).

## 0. Why this spec exists

The 2026-08 compression audit measured the spectral float64 channels
as the format's largest untapped surface. After #280 (byte-shuffle
default) the shipping baseline on PXD000001 MS1 profile m/z is
137.1 MB via the HDF5 filter pipeline; the same channel stored as a
single whole-stream codec blob reaches 59-68 MB losslessly with a
transform that is a few dozen lines per language. Two structural
facts drive the design:

1. **The win is in the transform, not the coder.** Plain zstd-9 on
   raw channel bytes saves 0.2%. Delta on the u64 bit pattern plus a
   byte-plane transpose ahead of the same coder saves 61%.
2. **Whole-stream beats per-chunk.** The HDF5 filter pipeline
   compresses each 16384-element chunk independently; the identical
   shuffle+zstd stack applied to the whole channel is 37% smaller
   (85.5 vs 134.8 MB on MS1 m/z). The genomic codecs (§10.4 ids
   4-15) already store whole-stream blobs with `@compression` and no
   HDF5 filter for exactly this reason; this codec adopts the same
   shape for spectral channels.

## 1. Goal

Add compression codec id `FLOAT_DELTA_ZSTD = 17` for float64 signal
channels (`mz`, `intensity`, `chemical_shift`, FID channels, and any
future float64 channel), storing the channel as a flat uint8 dataset
carrying a self-contained codec stream, dispatched via the existing
`@compression` attribute exactly like ids 4-15. Opt-in first
(`signal_codec_overrides`), default-on for MS channels in a later
release once fielded.

## 2. The algorithm

Per block of `B = 1 Mi` values (last block short):

```
1. view the float64 values as uint64 (bit pattern, no numeric change)
2. transform T, chosen per block by exact size comparison:
     T=0  none
     T=1  delta:  d[0] = u[0]; d[i] = u[i] - u[i-1]  (mod 2^64)
3. byte-plane transpose: emit plane 0 (LSB of every value), then
   plane 1, ... plane 7 — 8 planes of block_len bytes
4. zstd-compress the concatenated planes (level 9 default;
   writer-tunable 1-19, wire-invisible)
```

Decode inverts: zstd -> un-transpose -> (cumsum if T=1) -> view as
float64. Everything is exact integer/bit manipulation; the values
are bit-identical, NaNs and signed zeros included.

The per-block transform selector exists because the two transforms
win on different channels: at level 9, delta wins where the values
ride a smooth grid (MS1 profile m/z: 67.6 MB delta vs 94.4 none)
and none wins where the mantissas are noise-dominated (MS1
intensity: 58.8 none vs 64.8 delta). The encoder tries both and
keeps the smaller; one byte per block records the choice.

### 2.1 Wire format

```
Offset  Size  Field
0       4     magic   "FDZ1"
4       1     version (0x01)
5       1     flags   (bit 0: reserved, 0)
6       8     n_values          (u64 LE)
14      4     block_size        (u32 LE, values per block; 1 Mi default)
18      4     n_blocks          (u32 LE)
22      var   n_blocks x block:
                1  transform     (0x00 none, 0x01 delta)
                4  body_length   (u32 LE)
                body: one zstd frame (RFC 8878) of the transposed
                      planes for this block
```

Integers little-endian per the §10.7 contract. Each block is
independently decodable; the per-block framing gives coarse random
access (decode-once-cache remains the expected read path, matching
the M86 dispatch discipline).

### 2.2 On-disk schema

`signal_channels/<channel>_values` (MS layout) becomes a flat 1-D
UINT8 dataset holding the FDZ1 stream, `@compression = 17`, **no
HDF5 filter** (the stream is high-entropy). Readers that predate the
codec fail with their existing unknown-codec-id error — the same
write-forward discipline as ids 12-15. The `@<channel>_original_count`
attribute is not needed; `n_values` lives in the stream header.

## 3. Bake-off results (the numbers behind the choice)

Corpus: PXD000001 (Thermo Orbitrap Velos, TMT 60-min HCD), first
30M points; MS2 centroid complete; synthetic-but-physical NMR FID
(decaying sinusoids + noise) and Raman cube (Lorentzian peaks over
smooth spatial fields + shot noise), labelled synthetic. All
lossless rows verified bit-exact on round-trip. Wall times on the
dev workstation, single-threaded, relative not absolute.

Sizes in MB. `d17-auto` = this codec with the per-block selector
(best of none/delta shown; measured per whole channel, a per-block
selector can only do better). `current` = the shipping shuffle+gzip
default after #280.

| channel (raw)              | gzip6 pre-#280 | current | d17-auto L9 | d17-auto L19 | pco  | alp-est |
|----------------------------|---------------:|--------:|------------:|-------------:|-----:|--------:|
| ms1_mz (234.2)             |          173.9 |   129.3 |        67.6 |         59.0 | 61.9 |   182.6 |
| ms1_intensity (234.2)      |           66.7 |    60.1 |        58.8 |         54.7 | 50.7 |   167.2 |
| ms2_mz (6.1)               |            2.8 |     1.9 |        1.75 |         1.73 | 1.68 |     5.2 |
| ms2_intensity (6.1)        |            3.2 |     2.6 |        2.61 |         2.55 | 2.47 |     5.3 |
| four channels (480.6)      |          246.6 |   193.9 |       130.8 |        117.9 | 116.8 |      — |
| nmr_fid, synth (33.6)      |           32.4 |    29.0 |        28.8 |         28.5 | 28.9 |    29.6 |
| raman_cube, synth (75.5)   |           70.3 |    60.0 |        61.1 |         59.3 | 59.3 |    64.3 |

Speeds at the level-9 default on the two big channels: encode
~100 MB/s, decode ~580 MB/s single-threaded (Pco: ~470 / ~1800 MB/s
— faster, but both are far above ingest rates). Level 19 is a
20-25x encode-cost archive setting, wire-invisible.

The synthetic FID and cube rows are noise-bound at realistic SNR —
every candidate lands at x1.2-1.3 — so the codec neither helps nor
hurts there; the Phase 2 default flip covers MS channels only, and
the cube keeps its tile-chunked HDF5 filters for random access.

Reading of the table:

- **ALP-class is the wrong shape for spectral data.** Profile m/z is
  not decimal (classic path drowns in exceptions) and ALP has no
  delta stage, so the estimate lands at x1.28 — worse than plain
  gzip. Eliminated on data, not taste.
- **Pco is the ceiling but not by much.** Across the four MS
  channels this codec matches Pco within 1% at level 19 (117.9 vs
  116.8 MB, and it beats Pco outright on profile m/z) and sits
  within 12% at the level-9 default. Pco would cost either a Rust
  dependency in a C/Python/Java/ObjC stack or a from-scratch C
  reimplementation of its binning + tANS pipeline; a 1-12% residual
  does not justify that. Revisit as codec id 18 only if it ever
  does.
- **The in-house rANS cannot replace zstd here.** Information-
  theoretic floors for per-plane rANS-O1 on the transposed delta
  stream: 86.5 MB on MS1 m/z vs 67.6 actual for zstd-9 — the
  cross-position matching zstd brings is worth ~28%. This is the one
  place the shared-C-kernel + in-house-entropy pattern of ids 4-15
  is measurably insufficient.

## 4. The determinism decision (needs sign-off)

Every codec so far (ids 4-15) guarantees byte-exact encoded streams
across the three languages via a single shared C kernel. A zstd
entropy stage breaks that guarantee unless all three languages call
the same zstd build:

- **Option A — vendor a pinned zstd into `native/` and put the whole
  codec in `libttio_rans`** like every other codec. Keeps the
  byte-exact-encode invariant. Costs: ~800 KB of vendored BSD-3
  amalgamation, a native-build dependency for a spectral-path codec,
  and lockstep zstd upgrades.
- **Option B (recommended) — per-language encoders over the zstd
  dependencies #282 already added** (zstandard / aircompressor /
  libzstd). The invariant weakens to: decoders MUST accept any
  spec-conforming stream; encoders MAY differ byte-wise across
  languages. Precedent already exists on both neighbouring layers:
  the transport wire's zlib/zstd payloads are not byte-exact across
  languages today, and file-level conformance is explicitly logical
  ("HDF5 storage is not deterministic across SDKs"). Signatures are
  unaffected either way — §10c canonical bytes hash the DECODED
  values. Conformance shape: a golden ENCODED fixture that all three
  decoders must decode bit-exactly, plus 3x3 write/read logical
  round-trips, plus the transform-selector decision locked by a
  shared table (the selector compares exact sizes, so it can differ
  across languages only where encoders differ — the fixture pins the
  DECODE side, the round-trips pin correctness).

Option B ships in days; Option A in weeks. The recommendation is B,
recorded here for an explicit yes/no.

## 5. Rollout

1. Phase 1: encoder/decoder in Python + Java + ObjC behind
   `signal_codec_overrides[<channel>] = 17`, golden decode fixture,
   round-trip + xlang tests, spec §10.4 row. No default change.
2. Phase 2 (separate PR, after soak): default MS float64 channels to
   id 17, `opt_disable_float_delta` writer flag per the mate_info v2
   opt-out pattern; refresh benchmark docs.
3. Not scheduled: cube/2-D datasets keep the HDF5 filter pipeline for
   tile access; revisit only with a real imaging corpus in hand.

## 6. Validation plan

- Unit: round-trip on the audit's edge-case battery (empty, single
  value, all-identical, NaN/Inf/-0.0 mixes, monotone grids, noise,
  block-boundary lengths B-1/B/B+1).
- Golden: one fixed encoded stream per transform, decoded bit-exact
  in all three languages.
- Property: hypothesis round-trip on random float64 arrays (Python).
- Conformance: accessor-matrix cell with the override on, 3 encoders
  x 3 decoders, logical equality.
- Perf gate: encode >= 50 MB/s, decode >= 200 MB/s single-threaded on
  the CI runner at level 9 (both hold with wide margin locally).

## 7. Open questions for review

1. Option A vs B in §4 (recommendation: B).
2. Default block size 1 Mi values (8 MiB raw) — fine? Smaller blocks
   improve random access, cost ratio.
3. Name: `FLOAT_DELTA_ZSTD` (content-descriptive, matches the
   DELTA_RANS_ORDER0 lineage). Alternative: `F64_TRANSPOSE_ZSTD`.
4. Should Phase 2's default flip also cover NMR FID channels? The
   synthetic FID corpus says the gain there is marginal (noise-bound
   at x1.2 for every candidate), so the draft answer is MS channels
   only; a real FID corpus could reopen it.
