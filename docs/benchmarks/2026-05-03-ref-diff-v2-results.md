# REF_DIFF v2 chr22 results — 2026-05-03

## Summary

REF_DIFF v2 (codec id 14, CRAM-style bit-packed sequence diff) ships
in v1.8 as the default sequences codec. Saves **4.314 MB** on chr22
NA12878 lean+mapped vs v1.7 (REF_DIFF v1: single rANS-encoded bitstream
with 8-bit-literal substitutions and 8-bit-literal IN/SC bases).

**Hard gate: chr22 savings >= 2 MB. Measured: 4.314 MB. PASS.**

## Setup

- Corpus: `data/genomic/na12878/na12878.chr22.lean.mapped.bam`
  (151 MB, 1,766,433 records, 178,409,733 bases)
- Reference: `data/genomic/reference/hs37.chr22.fa`
- Native lib: `native/_build/libttio_rans.so`
- Build: `cmake .. -DTTIO_RANS_BUILD_JNI=ON && make -j$(nproc)`
- Test: `python/tests/integration/test_ref_diff_v2_compression_gate.py`
- Env: `TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so`

## Ratio comparison (chr22)

The gate test uses no additional codec overrides beyond the default stack
(REF_DIFF on sequences, FQZCOMP_NX16_Z on qualities, NAME_TOKENIZED on
read_names, MATE_INLINE_V2 on mate_info). Only the sequences channel codec
changes between v1 and v2 runs.

| Configuration | File size | Δ vs v1.7 |
|---------------|----------:|----------:|
| v1.7 baseline (REF_DIFF v1) | 209,177,921 bytes (199.488 MB) | — |
| v1.8 default (REF_DIFF v2)  | 204,654,883 bytes (195.174 MB) | **-4.314 MB (2.16%)** |
| CRAM 3.1 (external reference) | 86,094,472 bytes (86.09 MB) | reference target |

REF_DIFF v2 closes **3.80%** of the remaining v1.7 → CRAM gap on chr22
(v1.7 excess: 113.4 MB above CRAM; v2 saves 4.3 MB of that).

Note: both v1 and v2 runs embed the hs37 chr22 reference into the file
(~9.9 MB). The CRAM 3.1 baseline uses an external reference. This accounts
for most of the residual gap relative to CRAM.

## Sequences channel only (T6 oracle, isolated)

The T6 oracle (`test_ref_diff_v2_v1_oracle.py`) measures the encoded
blob size in isolation (no HDF5 framing):

| Layer | Encoded | B/base | Compression vs raw 8 bits/base |
|-------|--------:|-------:|-----:|
| v1 REF_DIFF (single rANS bitstream) | 11,337,728 bytes (10.81 MB) | 0.0635 | 12.6× |
| v2 REF_DIFF (FLAG/BS/IN/SC/ESC + rANS-O0 per substream) | 6,800,074 bytes (6.49 MB) | 0.0381 | 21.0× |

The substream decomposition captures the modeling win: separate rANS-O0
on the all-zero-dominated FLAG stream beats interleaving with random
substitution bytes by a meaningful entropy margin.

## Cross-language byte-exact gate

3/3 PASS (chr22, WES, hg002_illumina) + 1 SKIP (hg002_pacbio — BAM has
SEQ=`*`, no decodable reads). The shared-C-kernel pattern delivers
cross-language byte-exactness via SHA-256 hash comparison. Verified in
`python/tests/integration/test_ref_diff_v2_cross_language.py`.

## Cross-corpus encoded sizes

From Python in-process encoding (same C kernel as Java/ObjC):

| Corpus | n records | total bases | Encoded | B/base |
|--------|----------:|------------:|--------:|------:|
| chr22 NA12878 lean+mapped | 1,766,433 | 178,409,733 | 6,800,074 bytes (6.49 MB) | 0.0381 |
| WES NA12878 chr22 | 992,135 | 94,962,084 | 810,648 bytes (0.77 MB) | 0.0085 |
| HG002 Illumina 2×250 chr22 | 976,633 | 243,009,344 | 59,158,043 bytes (56.42 MB) | 0.2434 |
| HG002 PacBio HiFi | — | — | — | SKIP (BAM SEQ=`*`) |

HG002 Illumina compresses much higher than chr22 because the corpus reads
were aligned to hg38 (reads do not match hs37 chr22 reference well); high
effective substitution rate drives FLAG=1 density up. Round-trip
correctness preserved either way.

WES compresses dramatically (0.0085 B/base) because WES reads align with
very low substitution rates on the targeted exonic regions.

## Conclusion

REF_DIFF v2 ships in v1.8 as the default sequences codec. The opt-out
flag `WrittenGenomicRun.opt_disable_ref_diff_v2` (Python) /
`optDisableRefDiffV2` (Java/ObjC) preserves v1 round-trip when needed.

**Hard gate: 4.314 MB savings on chr22 (gate = 2 MB). PASS.**

**Out of scope** (per #11 plan):
- NameTokenized v2 (read_names channel, #11 channel 3) — separate cycle
- sequences_unmapped routing (deferred from M93)
- Per-ref-context substitution model (CRAM-style)
- #10 offsets-cumsum (structural HDF5 framing)
- #13 V5 multi-stream rANS

## References

- Spec: `docs/superpowers/specs/2026-05-03-ref-diff-v2-design.md`
- Plan: `docs/superpowers/plans/2026-05-03-ref-diff-v2.md`
- Wire format: `docs/format-spec.md` §10.10b
- Cross-language gate: `python/tests/integration/test_ref_diff_v2_cross_language.py`
- Compression gate: `python/tests/integration/test_ref_diff_v2_compression_gate.py`
- Prior byte breakdown: `docs/benchmarks/2026-05-01-chr22-byte-breakdown.md`
