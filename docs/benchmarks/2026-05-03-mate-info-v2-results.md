# mate_info v2 chr22 results — 2026-05-03

## Summary

mate_info v2 (codec id 13, CRAM-style inline mate-pair encoding) ships
in v1.7 as the default mate-pair codec.

**End-to-end gate result:** encoding chr22 NA12878 lean+mapped
(1,766,433 records) without other codec overrides (plain gzip on all
channels):

| Configuration | File size | Savings vs v1 |
|---|---:|---:|
| v1 baseline (M82 compound, gzip) | 286,926,668 bytes (273.635 MB) | — |
| v2 default (inline_v2, rANS-O0)  | 236,676,757 bytes (225.713 MB) | **47.922 MB (17.5%)** |

The 5 MB hard gate **passes with 47.9 MB savings**.

The large gap compared to the ~7 MB per-substream prediction from T11 is
expected: the gate test uses the M82 compound dataset (VL_STRING chrom +
int64 pos + int32 tlen, HDF5 gzip) as the v1 baseline, which compresses
very poorly (~50 MB total) vs the v2 inline blob (~4.7 MB). The ~7 MB
prediction was for the full-stack benchmark path (REF_DIFF + FQZCOMP +
NAME_TOKENIZED active), where mate_info already had per-field rANS overrides
applied. Both measurements are correct; they measure different v1 reference
points.

**In-context savings (full codec stack):** the
`docs/benchmarks/2026-05-01-chr22-byte-breakdown.md` §2 diagnostic
measured `signal:mate_info` at **11,493,862 bytes (11.49 MB)** in the
prior full-stack encoding (with per-field NAME_TOKENIZED + RANS_ORDER1
overrides). The T11 oracle measured the inline_v2 blob alone at
**4,665,251 bytes (4.45 MB)**. Delta: **~6.8 MB saved** within the
full-stack context — aligns with the 7 MB design target.

## Setup

- Corpus: `data/genomic/na12878/na12878.chr22.lean.mapped.bam`
  (145 MB, 1,766,433 records)
- Native lib: `native/_build/libttio_rans.so` (commit `b68e132`)
- Env: `TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so`
- Test: `python/tests/integration/test_mate_info_v2_compression_gate.py`
- Gate: savings >= 5 MB (PASS: 47.922 MB)

## Ratio comparison

The gate test uses **no** codec overrides (plain gzip on all channels) to
isolate the mate_info channel contribution cleanly.

| Configuration | File size | Notes |
|---|---:|---|
| v1 (M82 compound, VL_STRING chrom, gzip) | 273.635 MB | opt_disable_inline_mate_info_v2=True |
| v2 default (inline_v2 blob, rANS-O0)     | 225.713 MB | opt_disable_inline_mate_info_v2=False (default) |
| CRAM 3.1 (external reference)             |  86.09 MB  | samtools view -C with hs37d5 chr22 ref |

The gate test does not close on CRAM because it omits the full codec
stack (REF_DIFF sequences, FQZCOMP qualities, NAME_TOKENIZED read_names,
DELTA_RANS_ORDER0 positions). Those are orthogonal channels already
shipping in v1.6. The mate_info channel is the T15 focus.

## Cross-corpus encoded blob sizes

From the T11 cross-language byte-exact gate (encoded inline_v2 blob
measured in isolation, without HDF5 framing):

| Corpus | n records | Encoded blob | B/rec | vs raw 16 B/rec |
|--------|----------:|-------------:|------:|----------------:|
| chr22 NA12878 lean+mapped | 1,766,433 | 4,665,251 | 2.64 | 6.06× |
| WES NA12878 chr22         |   992,974 | ~2.6 MB    | 2.65 | 6.04× |
| HG002 Illumina 2×250 chr22|   997,415 | ~2.9 MB    | 2.93 | 5.46× |
| HG002 PacBio HiFi         |    14,284 | ~3 KB      | 0.22 | 72.65× |

"Raw 16 B/rec" = int32 chrom_id + int64 pos + int32 tlen per record.

PacBio HiFi compresses extraordinarily well because most reads have
no mate (MF=2 NO_MATE class), reducing the per-record encoding to
varint(0)=1 byte for both NP and TS substreams.

## Cross-language byte-exact gate

12/12 PASS (4 corpora × Python+Java+ObjC). The shared-C-kernel pattern
(libttio_rans single source of truth) eliminates cross-language
encoding drift — verified via SHA-256 hash comparison in
`python/tests/integration/test_mate_info_v2_cross_language.py`.

## Per-substream MF class breakdown (chr22)

From the T11 oracle on chr22 (1,766,433 records):

| MF class | Meaning | Approx fraction |
|----------|---------|-----------------|
| 0 = SAME_CHROM_NEARBY  | mate on same chrom, |delta_pos| < 2^16 | ~87% |
| 1 = SAME_CHROM_FAR     | mate on same chrom, |delta_pos| >= 2^16 | ~1% |
| 2 = NO_MATE            | unmapped or unpaired | ~5% |
| 3 = DIFF_CHROM         | mate on different chrom | ~7% |

SAME_CHROM_NEARBY is the dominant class — the bulk of NP bytes are
zigzag-varint deltas that fit in 1–2 bytes. The DIFF_CHROM class uses
absolute mate_pos (full 8-byte int64), which is why the blob is still
~2.64 B/rec rather than sub-1 B/rec.

## Container layout (chr22)

The 4,665,251-byte chr22 blob breaks down as:

- 34 bytes container header (magic + version + 4 × substream lengths)
- MF substream: raw-pack (values 0–3, each 1 byte)
- NS substream: varint-encoded chrom_ids for DIFF_CHROM records
- NP substream: zigzag-varint of mate_pos deltas (SAME_CHROM) or
  absolutes (DIFF_CHROM); 0 for NO_MATE/SAME_CHROM_FAR
- TS substream: zigzag-varint of template_lengths; 0 for NO_MATE

All four substreams are individually rANS-ORDER0 compressed via the
auto-pick threshold (rANS if compressed < raw; raw-pack otherwise).

## Conclusion

mate_info v2 ships in v1.7 as the default mate-pair encoding.
The opt-out flag `WrittenGenomicRun.opt_disable_inline_mate_info_v2`
(Python) / `optDisableInlineMateInfoV2` (Java/ObjC) preserves v1
round-trip when needed.

**Hard gate: 47.922 MB savings on chr22 (gate = 5 MB). PASS.**

**Out of scope for this release** (separate cycles, per #11 plan):
- REF_DIFF v2 (sequences channel) — ~3-5 MB additional savings
- NameTokenized v2 (read_names channel) — ~3-4 MB additional savings
- #10 offsets-cumsum (structural HDF5 framing change)
- #13 V5 multi-stream rANS

## References

- Spec: `docs/superpowers/specs/2026-05-03-mate-info-v2-design.md`
- Plan: `docs/superpowers/plans/2026-05-03-mate-info-v2.md`
- Wire format: `docs/format-spec.md` §10.9b
- Cross-language gate: `python/tests/integration/test_mate_info_v2_cross_language.py`
- Compression gate: `python/tests/integration/test_mate_info_v2_compression_gate.py`
- Prior byte breakdown: `docs/benchmarks/2026-05-01-chr22-byte-breakdown.md`
