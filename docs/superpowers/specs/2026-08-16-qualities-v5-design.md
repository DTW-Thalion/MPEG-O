# Qualities V5 — sequence-motif context for FQZCOMP_NX16_Z (codec id 12)

- Status: designed, awaiting implementation
- Bake-off: `docs/benchmarks/2026-08-16-qualities-v5-bakeoff.md`
- Prior flavor: M94.Z V4 (CRAM 3.1 fqzcomp port),
  `native/src/m94z_v4_wire.h`, `native/src/fqzcomp_qual.h`
- R6 of the compression audit.

## 0. Why this spec exists

V4 compresses the qualities channel to 0.358 B/q on chr22 NA12878
against a CRAM-class floor of 0.20-0.25. The audit estimated ~14%
further from fqzcomp5-style sequence-motif context. The bake-off
measured the real shape: 22.7% on chr22 (2012-era Illumina 100 bp),
4.4% on PacBio HiFi, and a LOSS on WES capture and HG002 2x250 —
sequence context splits the adaptive contexts, and on platforms
without motif-correlated quality structure the dilution costs more
than the signal pays. The design therefore never commits a file to
sequence context: the encoder tries it and keeps it only when it
wins by exact size.

## 1. Goal

Add sequence-context strategies to the codec-12 auto-tune set and a
V5 stream flavor that carries their output, such that:

- files where sequence context wins shrink by the measured margins;
- files where it loses are byte-identical to today's V4 output and
  remain readable by existing releases;
- the qualities decoder consumes decoded sequence bytes as side
  input only for V5 streams, and only ever sees V5 streams for runs
  whose sequences channel is present and base-parallel.

## 2. The algorithm

The quality model is V4's shape: one adaptive 256-symbol frequency
model per context (`c_simple_model.h` semantics), coded with the
CRAM range coder. V5 changes only the context word. Per read, with
`i` the position, `len` the read length and `q` the quality value:

```
qctx   = (qctx << qshift) + q            after coding q; reset 0 per read
seqctx = ((seqctx << 2) | bcode) & ((1 << sbits) - 1)
         rolled BEFORE coding q_i, so the window INCLUDES the
         current base; reset 0 per read
bcode  = A/a:0 C/c:1 G/g:2 T/t:3, any other byte (N included): 0
pos    = MIN((1 << pbits) - 1, (len - 1 - i) >> pshift)

ctx    = (qctx & ((1 << qbits) - 1))
       | pos    << qbits
       | seqctx << (qbits + pbits)
```

There is no delta field in the V5 strategies (the bake-off winners
carry none); a future strategy that needs one bumps `param_version`.

The two shipped strategies, from the bake-off plateau:

| id | name | qbits | qshift | pbits | pshift | sbits | ctx bits |
|---:|---|---:|---:|---:|---:|---:|---:|
| 5 | S5 (Illumina-2012 class) | 6 | 5 | 7 | 0 | 5 | 18 |
| 6 | S6 (HiFi class) | 8 | 5 | 4 | 0 | 6 | 18 |

18 context bits mean (1<<18) adaptive models, ~268 MB transient at
encode and decode. Both sides allocate per call and free on return,
as the V4 path does.

### 2.1 Wire format

V5 reuses the M94.Z outer header (`m94z_v4_wire.h`) with
`version = 5`. Flags bit 0 (`has_cram_body`) MUST be 0; flags bit 1
(`has_seqctx_body`) MUST be 1. The pad_count convention and the
deflated read-length table are unchanged. The body that follows the
RLT is:

```
offset  size  field
  0       1   param_version = 1
  1       1   strategy_id (5 or 6; provenance only, decoders use
              the explicit fields below)
  2       1   qbits
  3       1   qshift
  4       1   pbits
  5       1   pshift
  6       1   sbits
  7       1   reserved = 0
  8     var   range-coded quality stream
```

Decoders MUST decode from the explicit parameter fields, so a
future strategy is a new id plus values, not a decoder change.

### 2.2 Encoder selection

`strategy_hint = -1` (auto-tune, the default) encodes candidate
bodies for V4 presets 0-4 plus S5 and S6 and keeps the smallest.
S5/S6 are tried only when the caller supplies sequences whose total
length equals the qualities length. When a V4 preset wins, the
emitted stream is version 4 and byte-identical to today's encoder
output. `strategy_hint` 0-4 keeps its current meaning; 5-6 force a
sequence strategy and error without sequences.

The single native implementation in `libttio_rans` serves all three
languages (Python ctypes, Java JNI, ObjC direct link), so encoder
output is byte-identical across languages by construction. The
golden fixture still pins the decode side as the conformance
contract, matching the V4 arrangement.

### 2.3 Decode and ordering

`ttio_fqzcomp_qual_uncompress` gains a sequences argument (NULL for
V4 streams). A V5 stream with NULL or length-mismatched sequences
fails with a distinct error code — never a garbage decode.

Reader wiring: `CodecContext` grows a `sequences` field. The
GenomicRun open path decodes the sequences channel before the
qualities channel and hands the decoded bytes to codec 12; the
existing lazy per-read materialization is unchanged. If sequences
decoding fails (e.g. REF_DIFF_V2 with a missing external
reference), V5 qualities decoding reports that upstream failure
rather than its own.

Transport verbatim blobs (Phase 2c-T) pass qualities bytes through
untouched and are version-agnostic. Per-AU encryption reads the
qualities channel as bytes and is unaffected.

### 2.4 Writer gate and opt-out

`WrittenGenomicRun.opt_disable_qualities_v5` (Python) /
`optDisableQualitiesV5` (Java, ObjC), default false, removes S5/S6
from the tried set — the V3/V4 rollout opt-out pattern. Runs
without a base-parallel sequences channel never try S5/S6, so
sequence-less files cannot become V5 by construction.

## 3. Bake-off numbers behind the choice

Best candidate vs best no-sequence baseline, B/q, both measured in
the prototype (its baseline reproduces production V4 to within 0.6%:
0.3600 vs the auto-tuned 0.358 on chr22, 0.2798 vs 0.280 on WES).
Full tables and the rejected forms — hashed k-mers, predecessor-only
windows — are in the benchmark doc:

| corpus | baseline | with seq context | delta |
|---|---:|---:|---:|
| chr22 NA12878 100 bp | 0.3600 | 0.2782 | -22.7% |
| PacBio HiFi | 0.4151 | 0.3967 | -4.4% |
| NA12878 WES capture | 0.2798 | 0.2859 | +2.2% (V4 kept) |
| HG002 2x250 | 0.2758 | 0.2760 | +0.1% (V4 kept) |

Every bake-off size was produced by a model that round-tripped
bit-exactly in the same run.

## 4. Compatibility

- Readers of this release and later read V4 and V5.
- Older readers keep reading every file where a V4 strategy won.
  A V5 file fails in an older reader at the version-byte check in
  `ttio_m94z_v4_unpack` — a clean error, not a misdecode.
- No change to the codec id (12), the `@compression` attribute, the
  channel layout, or any other channel.
- Encode cost: two extra auto-tune candidates when sequences are
  present (~1.5-2x current auto-tune wall on the qualities channel).

## 5. Validation plan

1. Golden V5 fixture (S5 parameters, mixed-motif synthetic input
   with known bases) decoded bit-exactly by all three wrappers, next
   to the V4 fixture in each suite.
2. C-level round-trip tests over the edge battery: empty, one read,
   len-1 reads, N-heavy sequences, 93-value HiFi-like quals,
   uppercase/lowercase bases.
3. Encoder-pick tests: a motif-correlated slice must emit version 5
   and beat V4's size; a WES-like slice must emit byte-identical V4.
4. Gate tests: no sequences supplied → V4 emitted; V5 stream decoded
   without sequences → distinct error; sequences length mismatch →
   distinct error.
5. Cross-language conformance edge: a V5 .tio written by Python
   opens in Java and ObjC through the file-level path (the #285
   lesson: file-level round-trip in every language, not just
   codec-level unit tests).
6. Perf suite: qualities encode/decode benches gain a V5 row;
   existing V4 baselines must not shift.

## 6. Open questions for review

1. S5+S6 only, or also keep a third strategy slot reserved in the
   auto-tune loop for a future platform class? (Spec ships two; the
   wire format already accommodates more via explicit parameters.)
2. Should auto-tune skip S5/S6 below a minimum channel size (the
   268 MB transient for tiny AUs buys nothing)? Proposed: skip when
   n_qualities < 1 MiB; the pick-by-size rule makes this purely a
   resource guard.
