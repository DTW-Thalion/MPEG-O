# L2.X — M94.Z V4 (CRAM 3.1 fqzcomp port) — Stage 2 design

> **Status (2026-05-02).** Brainstormed 2026-05-02 immediately after
> the Stage 1 multi-corpus prototype landed at HEAD `43682c6`. Stage 1
> empirically refuted the "TTI-O bit-pack discipline" hypothesis as
> a static codec choice; this Stage 2 design adopts a faithful CRAM 3.1
> fqzcomp_qual port.

> **WORKPLAN entry:** Task #84 Stage 2 — richer-context M94.Z (CRAM
> port).

> **Two-stage spec.** Stage 1 (the prototype) shipped at HEAD `8b74dcf`
> + multi-corpus extension at `43682c6`. Stage 2 (this document)
> defines the production codec replacement. Stage 3 (Java/ObjC
> wrappers) is its own future spec, written only after Stage 2 lands.

## 0. Why this spec exists

Stage 1 measured 5 candidate context-model designs across 4 corpora
(chr22 NA12878 + WES NA12878 + HG002 Illumina 2×250 + HG002 PacBio
HiFi). The findings:

- **No single static bit-pack design wins across platforms.** c3
  (length-heavy 8-bit prev_q + 4-bit pos + 4-bit length + 1-bit
  revcomp, sloc=17) dominates Illumina. c0 (V3 baseline, sloc=14)
  dominates PacBio HiFi. The "TTI-O bit-pack discipline" we adopted
  in M94.Z V1 was a self-imposed encoder-internal constraint, not
  architecturally motivated.
- **The hash-escalation hypothesis is conclusively refuted.** c4
  (SplitMix64 hash on CRAM 3.1's 28-bit feature vector → 12-bit
  index) is the worst candidate on every corpus we measured.
- **TTI-O framework overhead is negligible** (HDF5 residual = 0.12 MB
  on a 113 MB chr22 file; 0.1%). The 25 % gap to CRAM 3.1 (107.95 MB
  best vs 86.09 MB CRAM) is essentially all in the quality codec.
- **Mimicking CRAM 3.1 fqzcomp loses zero TTI-O architectural
  capability.** Codec choice is per-channel; multi-omics integration,
  storage providers (HDF5/Zarr/SQLite/memory), encrypted transport,
  and per-channel composition all live above the codec layer.

Conclusion: **port CRAM 3.1's fqzcomp_qual into TTI-O.** Stage 2 ships
the port; Stage 3 ports the Python wrapper to Java + ObjC after the
Python+native path is byte-exact across all corpora.

## 1. Goal

Replace M94.Z V3's bit-pack context model with a byte-compatible port
of CRAM 3.1 fqzcomp_qual, giving TTI-O Illumina compression matching
CRAM 3.1's reference (~0.20-0.25 B/qual) and platform-adaptivity via
CRAM's auto-tuning mechanism (parameter selection per block based on
quality histogram analysis).

## 2. Scope

**In scope:**
- Native C port of `htscodecs/fqzcomp_qual.c` (compress + decompress)
  into `native/src/`. No runtime dependency on htscodecs.
- M94.Z V4 wire format: outer M94.Z framing wraps a CRAM-byte-
  compatible inner body. Decoder strips M94.Z header and hands the
  inner blob to our C port.
- Python ctypes wrapper update (`python/src/ttio/codecs/fqzcomp_nx16_z.py`)
  to dispatch V4 by default when `_HAVE_NATIVE_LIB`; V3 stays as the
  no-native fallback and the read-compat path for legacy files.
- chr22 + WES + HG002 Illumina 2×250 + HG002 PacBio HiFi byte-equality
  validation against `htscodecs` reference (test-time link only; not
  a runtime dependency).
- Per-phase byte-equality unit tests + per-corpus integration tests.
- Stage 2 spec doc + WORKPLAN update + memory updates.

**Out of scope (deferred to Stage 3 or later):**
- Java JNI wrapper (Stage 3)
- ObjC direct-linkage wrapper (Stage 3)
- ONT platform corpus validation (no source data with QUAL preserved)
- V3 deprecation / removal (separate minor release after V4 soak)
- CRAM `.cram` container compatibility (we wrap CRAM body in M94.Z
  V4 framing, not a `.cram` file)
- Stage 1 prototype harness changes — its work is done; it stays as
  research code in `tools/perf/m94z_v4_prototype/` for re-runs if
  ever needed.

## 3. CRAM context model adopted

V3's M94.Z had: `prev_q` ring (qbits = 12) + `pos_bucket` (pbits = 2) +
`revcomp` (1 bit). 4 dimensions (counting revcomp separately). Fixed
parameters across all blocks.

V4 adopts CRAM 3.1's full feature set, all variable per block:

| Dimension | Bits | Description |
|---|---|---|
| `qctx` | qbits = 0..12 | Quality history ring; `qshift` controls how many bits per symbol enter the ring (1-6) |
| `p` | pbits = 0..7 | Coarse position-in-read bucket; `pshift` shifts position |
| `delta` | dbits = 0..3 | Running count of quality changes within the read; capped at `1 << dbits - 1` |
| `selector` | 1-2 bits | READ1/READ2 split (`do_r2`); optional quality-bin selector (`do_qa`) for splitting the model into 2 or 4 by per-read average quality |

Total context width fits in 16 bits (CRAM's hard limit). The bit
positions for each dimension within the 16-bit context are themselves
parameters: `qloc`, `sloc`, `ploc`, `dloc`. CRAM's encoder picks all
parameters per block via histogram analysis.

### 3.1 Auto-tuning + parameter strategy presets

CRAM 3.1's reference implementation ships 5 presets, plus auto-detect
via histogram analysis at encode time:

| Strategy | Target | Defaults |
|---|---|---|
| 0 | Generic / unknown | qbits=10, qshift=5 |
| 1 | HiSeq 2000 | qbits=8, qshift=4, do_r2=1 |
| 2 | MiSeq | qbits=12, qshift=6 |
| 3 | IonTorrent | adaptive |
| 4 | Custom / user-overridden | per call |

Plus heuristic adjustments (from htscodecs):
- **Low-entropy** (NovaSeq-like, ≤4 distinct Q values): qshift=2,
  reduced pbits.
- **Moderate-entropy** (HiSeqX-like, ≤8 distinct Q values): qbits=9,
  qshift=3.
- **Small-input shortcut** (<300 KB): simplified context (qbits=qshift,
  dbits=2).

V4 ports all 5 strategies and the auto-tune logic verbatim from
`htscodecs/fqzcomp_qual.c`. The encoder runs the histogram pass over
the input qualities at the start of each block, picks the best
strategy + parameter combination, encodes them in the CRAM body
header, and runs the standard codec.

The Stage 1 finding "c0 wins on PacBio HiFi" is hypothesized to be
solved by the auto-tune low-entropy heuristic (PacBio HiFi qualities
cluster at Q60+, effectively low-entropy in distinct-symbol count).
Phase 0 of the implementation plan validates this empirically before
the port begins.

## 4. V4 wire format

Outer framing keeps M94.Z's structure for compatibility with TTI-O's
existing codec dispatch in `python/src/ttio/spectral_dataset.py:_write_qualities_fqzcomp_nx16_z`.
Inner body is byte-compatible with `htscodecs/fqzcomp_qual_compress`
output for the same input and parameters.

```
Offset  Size   Field
──────  ────   ─────────────────────────────────────────────
0       4      magic = "M94Z"
4       1      version = 4
5       1      flags
                 bit 0:   has_cram_body (must be 1 for V4; 0 reserved)
                 bit 4-5: pad_count (0..3, V3 convention preserved)
                 other:   reserved (must be 0)
6       8      num_qualities    (uint64 LE)
14      8      num_reads        (uint64 LE)
22      4      rlt_compressed_len (uint32 LE)
26      var    read_length_table (deflated; V3 convention)
26+R    4      cram_body_len (uint32 LE) — length of inner CRAM blob
30+R    var    cram_body — byte-compatible with htscodecs
                  fqzcomp_qual_compress output

(R = rlt_compressed_len. Total size = 30 + R + cram_body_len.)
```

The inner `cram_body` is what `htscodecs` would emit for the same
input and parameter choices. CRAM's own per-block parameter header
(qbits/qshift/pbits/dbits/qloc/sloc/ploc/dloc/strategy_index/selector
flags) is encoded *inside* the cram_body — we do not re-encode them
in the outer M94.Z header.

V3's `state_init`, `freq_tables_compressed`, and `context_params`
fields are removed from V4 (CRAM does not use them; the inner body
carries everything).

### 4.1 Decoder dispatch

Reader checks magic + version:
- `M94Z` v1 → V1 path (existing static-per-block freq, Cython-accelerated)
- `M94Z` v2 → V2 path (existing native rANS dispatch)
- `M94Z` v3 → V3 path (existing adaptive RC, Python-only with sloc=14)
- `M94Z` v4 → V4 path (this spec; native CRAM port)

No version negotiation; the writer picks per `prefer_v3` / `prefer_v4`
kwargs and the new env var `TTIO_M94Z_VERSION` (extends the V3 env
var). Default order: V4 > V3 > V2 > V1, falling back to V1 if no
native lib is available.

## 5. Phased implementation

Five phases (P1-P5), each with a byte-equality gate. Phase 0 is a
pre-port sanity check.

### Phase 0 — htscodecs PacBio HiFi sanity check

Before any port work, verify the auto-tune-saves-PacBio-HiFi
hypothesis empirically.

Build htscodecs at `tools/perf/htscodecs/` (test-time only, not
shipped). Run htscodecs CLI on our PacBio HiFi subset
(`/home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam`,
14,284 reads / 264 M qualities) and measure B/qual.

**Decision rule:**
- If htscodecs ≤ 0.32 B/qual on PacBio HiFi → auto-tune saves us;
  proceed with the port as designed (Phase 1).
- If htscodecs ≈ 0.42 B/qual on PacBio HiFi (similar to our c0) →
  PacBio HiFi is platform-hard regardless of CRAM. Flag as known
  limitation in the eventual results doc; **still proceed** with
  the port because Stage 1 showed all other corpora benefit, and
  V4-on-PacBio is no worse than V3 baseline.

Phase 0 takes ~30 minutes (htscodecs build + one run). Outcome must
be committed to the eventual benchmark doc before Phase 1 starts.

### Phase 1 — RC primitives byte-equal htscodecs

**Files:**
- New: `native/src/rc_cram.c` — Subbotin Range Coder primitives matching
  CRAM 3.1's byte-pairing exactly (no context model, just raw RC
  encode/decode of a flat freq table)
- New: `native/src/rc_cram.h` — public RC API header
- New: `native/tests/test_rc_cram_byte_equal.c` — synthetic flat-freq
  inputs encoded by us and by htscodecs; assert byte-equal output

**Gate:** byte-equal htscodecs on synthetic uniform-freq inputs (e.g.,
1 M random uint8 with fixed flat freq table). If any byte differs,
debug before proceeding to P2.

The existing `native/src/rans_encode_adaptive.c` /
`rans_decode_adaptive.c` (V3's RC kernel) are NOT modified. V4 uses
the new `rc_cram.c` primitives because CRAM's RC has subtle
differences (state init, lane handling, renorm threshold) from our
V3 implementation — we don't try to retrofit V3's RC to CRAM
compatibility.

### Phase 2 — Context model with fixed strategy

**Files:**
- New: `native/src/fqzcomp_qual.c` — port of htscodecs equivalent;
  initially supports only one strategy (HiSeq, strategy_index = 1).
  No auto-tuning; parameters hardcoded.
- New: `native/src/fqzcomp_qual.h` — public API
  (`ttio_fqzcomp_qual_compress`, `ttio_fqzcomp_qual_uncompress`)
- New: `native/tests/test_fqzcomp_qual_strategy1.c` — chr22 fixture
  encoded by us and by htscodecs (with `--strategy=1`); byte-equal

**Gate:** byte-equal htscodecs on chr22 with htscodecs invoked via
`fqzcomp_qual --strategy=1`. Both must produce the exact same
compressed body bytes.

### Phase 3 — Auto-tuning + 5 presets

**Files:**
- Modify: `native/src/fqzcomp_qual.c` — add the histogram-analysis
  pass and the 5-strategy preset table. Parameter selection at
  encode time.
- New: `native/tests/test_fqzcomp_qual_autotune.c` — encode each of
  the 4 corpora with our port + htscodecs (both in auto-tune mode);
  assert byte-equal body bytes AND identical parameter selection
  (we should pick the same strategy as htscodecs for each corpus)

**Gate:** byte-equal htscodecs across all 4 corpora when both pick
the same auto-tuned strategy. If we and htscodecs ever pick
different strategies on the same input, the auto-tune port has a bug;
debug before proceeding.

### Phase 4 — V4 wire format + Python wrapper

**Files:**
- Modify: `native/include/ttio_rans.h` — add `ttio_fqzcomp_qual_v4_*`
  entry points wrapping the inner `fqzcomp_qual` blob with M94.Z V4
  outer framing
- New: `native/src/m94z_v4_wire.c` — pack/unpack the M94.Z V4 outer
  header
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py` — add
  `_encode_v4_native`, `_decode_v4_via_native`; default `prefer_v4`
  to `True` when `_HAVE_NATIVE_LIB`; extend `TTIO_M94Z_VERSION` env
  var to accept `"4"`
- Modify: `python/tests/test_m94z_v4_dispatch.py` — new (~10 tests):
  smoke roundtrips, env-var routing, V4-vs-V3 cross-decode, V4
  default detection, byte-equal vs htscodecs (gated on
  htscodecs-test-availability)
- Modify: existing `test_m94z_v3_dispatch.py` etc. — V3 default tests
  become explicit `prefer_v4=False, prefer_v3=True`

**Gate:** chr22 round-trip via Python wrapper produces byte-equal
recovered qualities. V3 reads still work. Existing 553-test M94.Z
suite stays green.

### Phase 5 — Cross-corpus validation + spec docs + WORKPLAN

**Files:**
- New: `docs/benchmarks/2026-05-02-m94z-v4-stage2-results.md` — final
  per-corpus B/qual + byte-equality status across all 4 corpora
- Modify: `docs/codecs/fqzcomp_nx16_z.md` — document V4 wire format,
  the auto-tune mechanism, and the V3-as-fallback path
- Modify: `WORKPLAN.md` Task #84 entry — Stage 2 done, list outcomes
  per corpus
- Modify: project memory `project_tti_o_v1_2_codecs.md`

**Gate:** all 4 corpora pass byte-equality with htscodecs reference.
Stage 2 spec marked complete; Task #84 ships.

If any corpus fails byte-equality at Phase 5 — investigate. The
phased structure means the failure must be in the V4 wire format
(P4) since P1, P2, P3 already gated.

## 6. Acceptance criteria

Stage 2 is done when ALL of:

1. P0 sanity check completed and outcome documented.
2. P1, P2, P3 byte-equality gates passed and committed.
3. P4 wire format works end-to-end in Python; V3 reads still work.
4. P5 byte-equality across all 4 corpora.
5. Full Python test suite green (1811+ tests + new V4 dispatch tests).
6. WORKPLAN Task #84 Stage 2 entry updated.
7. Spec doc (this file) committed and user-reviewed.
8. Stage 3 spec — Java/ObjC wrappers — explicitly registered as a
   follow-up but **not** written or implemented.

The 1.15× CRAM gate from v1.2.0 is **not** a Stage 2 acceptance
criterion — it's a v1.2.0 release-readiness criterion that depends
on Stage 2 outcomes. If V4 byte-equals htscodecs, the chr22 ratio
improves to whatever CRAM 3.1 hits on the same data (~0.20-0.25
B/qual → roughly 1.0-1.1× CRAM target file size); if it falls short,
v1.2.0 release decision is a separate conversation.

## 7. Risks + mitigations

| Risk | Mitigation |
|---|---|
| RC primitives drift between us + htscodecs (subtle bit-ordering, renorm threshold) | Phase 1 dedicated gate before any context model investment |
| Auto-tuning algorithm is data-dependent and our port picks a different strategy than htscodecs on edge cases | Phase 3 gate asserts strategy + body byte-equality together; debug if ever divergent |
| PacBio HiFi doesn't benefit from auto-tune | Phase 0 verifies before port; if htscodecs ≈ 0.42 on PacBio, document as known platform limitation, V4 still ships for Illumina wins |
| htscodecs source license / vendoring concerns | htscodecs is BSD-3; the C source is small enough to vendor at `tools/perf/htscodecs/` for test-time use without runtime dep concern. We do NOT vendor; we link at test time only |
| Java/ObjC bit-rot during Stage 2 (V3 stays Python-only) | Stage 3 explicitly tracks; Stage 2 doesn't touch Java/ObjC code |
| Performance regression vs V3's 25.83 s on chr22 | Auto-tune adds an O(n) histogram pass (~1 s) + parameter-encoding overhead (~ms). Realistic projection: 30-40 s encode wall. Acceptable for compression that beats V3 by ~30% |
| V4 wire format change breaks production code paths | V3 stays as readable; new files default to V4 only when native lib is available; old code paths reading V3 untouched |

## 8. References

- L2 spec (V3): `docs/superpowers/specs/2026-05-01-l2-m94z-adaptive-design.md`
- Stage 1 spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage1-design.md`
- Stage 1 plan: `docs/superpowers/plans/2026-05-02-l2x-m94z-richer-context-stage1.md`
- Stage 1 cross-corpus results: `docs/benchmarks/2026-05-02-m94z-v4-multi-corpus.md`
- M94 v1 doc (CRAM-mimic with SplitMix64 — historical):
  `docs/codecs/fqzcomp_nx16.md`
- M94.Z (current bit-pack) doc: `docs/codecs/fqzcomp_nx16_z.md`
- htscodecs reference: `https://github.com/samtools/htscodecs/blob/master/htscodecs/fqzcomp_qual.c`
- hts-specs CRAM 3.1 PDF: `https://samtools.github.io/hts-specs/CRAMv3.pdf`
- Memory:
  - `feedback_phase_0_spec_proof` — proof-before-implementation
    requirement for codec rewrites (this spec IS the proof phase
    for V4; auto-tune saves PacBio is verified empirically in P0)
  - `feedback_pacbio_hifi_qual_stripped` — workaround for PacBio
    BAM availability
  - `feedback_pwd_mangling_in_nested_wsl` — absolute paths required
    for native lib loading in test scripts
  - `feedback_crlf_on_wsl_clones` — CRLF discipline after
    `\\wsl.localhost\…` edits
  - `project_tti_o_v1_2_codecs` — overall project context
