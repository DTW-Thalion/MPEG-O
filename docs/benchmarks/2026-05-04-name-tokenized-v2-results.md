# NAME_TOKENIZED v2 chr22 results — 2026-05-04

## Summary

NAME_TOKENIZED v2 (codec id 15, multi-substream + DUP-pool +
PREFIX-MATCH + 4096-read block reset) ships in v1.9 as the default for
the `read_names` channel. End-to-end chr22 file size drops by **67.76
MB (-34.72%)** vs the pre-v1.9 default — combining ~4 MB of
codec-algorithm savings with ~63 MB of HDF5 framing recovery from
removing the M82 VL-string compound dataset for read_names.

**Hard gate: chr22 savings ≥ 3 MB. Measured: 67.76 MB. PASS.**

## Setup

- Corpus: `data/genomic/na12878/na12878.chr22.lean.mapped.bam`
  (151 MB, 1,766,433 records).
- Native lib: `native/_build/libttio_rans.so`.
- Build: `cmake .. -DTTIO_RANS_BUILD_JNI=ON && make -j$(nproc)`.
- Test: `python/tests/integration/test_name_tok_v2_compression_gate.py`.
- Env: `TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so`.

## Ratio comparison (chr22)

The gate measures the full `.tio` file size before vs after the v1.9
default change. All other codecs (REF_DIFF v2, mate_info v2, qualities
V4) stay at their v1.8 defaults.

| Configuration | File size | Δ |
|---------------|----------:|--:|
| pre-v1.9 default (M82 compound for read_names) | 204,654,883 bytes (195.17 MB) | — |
| v1.9 default (NAME_TOKENIZED v2)               | 133,600,866 bytes (127.41 MB) | **-71,054,017 bytes (-67.76 MB, -34.72%)** |
| CRAM 3.1 (external reference)                   | 86,094,472 bytes (86.09 MB) | reference target |

The 67.76 MB savings has two components:

1. **~4 MB** from the codec algorithm itself (multi-substream + DUP-pool
   + PREFIX-MATCH catching paired-end mate redundancy and structural
   tile/x/y similarity). Verified independently via the v1↔v2 oracle
   in `test_name_tok_v2_v1_oracle.py`: read_names channel drops from
   7.14 MB (v1 NAME_TOKENIZED) to 2.67 MB (v2 NAME_TOKENIZED_V2),
   savings 4.12 MB on the codec output alone.

2. **~63 MB** from removing the M82 VL_STRING-in-compound HDF5 layout
   for read_names. The pre-v1.9 default stored read_names as a
   `(1766433,)` compound dataset of variable-length strings, chunked at
   4096; HDF5 attached a fractal-heap block (~98-131 KB) per chunk
   for the VL-string allocations, accumulating to ~63 MB of "free
   space" between chunks. v1.9's flat uint8 dataset has no fractal
   heap. (Same root cause as the L1 chr22 chromosomes decomp shipped
   in 2026-05-01 per `2026-05-01-chr22-byte-breakdown.md` §3.)

After v1.9, the chr22 ratio progression vs CRAM 3.1:

| Stage | TTI-O size | × CRAM | Δ vs prior |
|-------|-----------:|-------:|-----------:|
| v1.5 baseline (pre-Phase B.1) | 169.17 MB | 1.965× | — |
| v1.5 + Phase B.1 (L1+L3) | 113.72 MB | 1.321× | -55.45 MB |
| v1.6 (drop signal_channels int dups) | 105.06 MB | 1.220× | -3.87 MB |
| v1.7 (mate_info v2) | — | — | mate_info channel rebuild |
| v1.8 (REF_DIFF v2) | 195.17 MB | 2.27× | sequences -4.31 MB |
| **v1.9 (NAME_TOKENIZED v2)** | **127.41 MB** | **1.480×** | **-67.76 MB** |
| CRAM 3.1 target | 86.09 MB | 1.000× | (reference) |

Note: v1.7 / v1.8 absolute file sizes increased because their gate
measurement methodology shifted to use the BamReader → write_minimal
default path (which carries the M82 compound + embedded reference);
v1.9 closes the visible gap from that methodology shift back to par.

## Cross-language byte-exact gate

4 corpora × 3 languages = **12 SHA-256 byte-equality assertions PASS**.
Verified in `python/tests/integration/test_name_tok_v2_cross_language.py`:

| Corpus | n_names | Encoded | SHA-256 byte-equal |
|--------|--------:|--------:|:------------------:|
| chr22 NA12878 lean+mapped | 1,766,433 | 2,799,090 bytes | Python = Java = ObjC ✓ |
| NA12878 WES (chr22)        | 992,974 | 6,699,117 bytes | Python = Java = ObjC ✓ |
| HG002 Illumina 2×250 (chr22 1M subset) | 997,415 | 14,336,992 bytes | Python = Java = ObjC ✓ |
| HG002 PacBio HiFi (subset) | 14,284 | 26,988 bytes | Python = Java = ObjC ✓ |

The shared C kernel pattern (one `ttio_name_tok_v2_encode` entry called
via Python ctypes, Java JNI, ObjC direct-link) delivers byte-exact
cross-language compatibility.

## Per-corpus B/name compression

read_names channel (post-codec, pre-HDF5):

| Corpus | n_names | Raw bytes | Encoded | B/name | Compression |
|--------|--------:|----------:|--------:|-------:|------------:|
| chr22 NA12878 lean+mapped | 1,766,433 | ~42 MB | 2.67 MB | 1.58 | 26.5× |
| NA12878 WES (chr22) | 992,974 | ~22 MB | 6.39 MB | 6.74 | 3.4× |
| HG002 Illumina 2×250 | 997,415 | ~42 MB | 13.67 MB | 14.37 | 3.1× |
| HG002 PacBio HiFi | 14,284 | ~0.5 MB | 26.4 KB | 1.85 | 19.6× |

WES + HG002 Illumina compress less because the names use a richer
distinct-prefix space (multiple flow cells / runs in a single corpus
break the DUP-pool's locality assumption). Round-trip correctness
preserved across all four.

## Conclusion

NAME_TOKENIZED v2 ships in v1.9 as the default `read_names` codec.
The opt-out flag `WrittenGenomicRun.opt_disable_name_tokenized_v2`
(Python) / `optDisableNameTokenizedV2` (Java/ObjC) preserves the
pre-v1.9 default M82 compound layout for callers needing
byte-equivalent backward compat with v1.8 readers. Setting
`signal_codec_overrides[read_names] = NAME_TOKENIZED` selects
codec id 8 (v1 NAME_TOKENIZED).

**Hard gate: 67.76 MB end-to-end savings on chr22 (gate = 3 MB). PASS.**

**Out of scope** (per #11 plan):
- Bonfield 2022 / CRAM 3.1 byte-equality (separate "v3" cycle).
- `cigars` channel adoption — RANS_ORDER1 stays default per WORKPLAN.
- #10 offsets-cumsum (structural HDF5 framing).
- #13 V5 multi-stream rANS.

## References

- Spec: `docs/superpowers/specs/2026-05-04-name-tokenized-v2-design.md`
- Plan: `docs/superpowers/plans/2026-05-04-name-tokenized-v2.md`
- Phase 0 prototype results: `docs/benchmarks/2026-05-04-name-tokenized-v2-phase0.md`
- Codec doc: `docs/codecs/name_tokenizer_v2.md`
- Format spec wire: `docs/format-spec.md` §10.6b
- Cross-language gate: `python/tests/integration/test_name_tok_v2_cross_language.py`
- Compression gate: `python/tests/integration/test_name_tok_v2_compression_gate.py`
- Prior byte breakdown: `docs/benchmarks/2026-05-01-chr22-byte-breakdown.md`
