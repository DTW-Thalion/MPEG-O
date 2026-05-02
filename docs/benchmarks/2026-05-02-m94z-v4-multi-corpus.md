# M94.Z V4 candidate prototype — multi-corpus comparison

> **Update to the Stage 1 chr22-only result.** The original §5
> conclusion was based on `chr22_na12878_mapped` alone; this doc
> extends the comparison to two additional Illumina corpora. The
> chr22-only winner (c2) does **not** generalize: c3 wins on 2 of 3
> corpora and c2 wins on the third by a razor-thin margin. The
> SplitMix64-hash baseline (c4) is the worst candidate on every
> corpus. Re-charter framing updated.

- Date: 2026-05-02
- Spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage1-design.md`
- Plan: `docs/superpowers/plans/2026-05-02-l2x-m94z-richer-context-stage1.md`
- Per-corpus result docs:
  - chr22: `docs/benchmarks/2026-05-02-m94z-v4-candidates.md`
  - WES: `docs/benchmarks/2026-05-02-m94z-v4-na12878_wes_chr22.md`
  - HG002 Illumina 2×250: `docs/benchmarks/2026-05-02-m94z-v4-hg002_illumina_2x250_chr22.md`

## 1. Corpora

| Slug | Source | Reads | Qualities | Mean read | Coverage pattern |
|---|---|---:|---:|---:|---|
| `chr22_na12878_mapped` | GIAB NA12878 chr22 (Illumina HiSeq 2×100, lean+mapped) | 1,766,433 | 178,409,733 | 101 bp | WGS, uniform |
| `na12878_wes_chr22` | GIAB Garvan_NA12878 HiSeq exome chr22 slice | 992,974 | 95,035,281 | 95.7 bp | exome capture, variable |
| `hg002_illumina_2x250_chr22` | GIAB HG002 NIST Illumina 2×250bp chr22 (1M-read subset of 10.6M-read full chr22) | 997,415 | 248,184,765 | 248.7 bp | WGS, uniform |

All Illumina. **HG002 PacBio HiFi was attempted but every public BAM
we checked (NIST GIAB GRCh38/GRCh37 alignment variants, PacBio cloud
HG002-CpG-methylation-202202 dataset, both aligned and raw
`hifi_reads.bam`) had `SEQ` and `QUAL` stripped to `*`** — the
PacBio HiFi public-data ecosystem treats per-base qualities as
expendable because CCS reads cluster at Q30+ and storage cost
dominates. A future round must source PacBio HiFi from a less-
processed pipeline (subreads.bam pre-CCS, or PacBio Sequel II raw
output) to test long-read platform diversity.

## 2. Per-corpus winners

For each corpus, body bytes (raw RC body, no header/prelude) and
B/qual (= body / n_qualities). Lower is better.

### chr22_na12878_mapped (Illumina 100bp, NA12878 WGS)

| Cand | Body MB | B/qual | vs c0 |
|---|---:|---:|---:|
| c0 | 69.26 | 0.388 | — |
| c1 | 64.24 | 0.360 | -7.2% |
| **c2** | **63.96** | **0.358** | **-7.6%** |
| c3 | 64.44 | 0.361 | -7.0% |
| c4 | 74.98 | 0.420 | +8.3% |

### na12878_wes_chr22 (Illumina ~95bp, NA12878 WES capture)

| Cand | Body MB | B/qual | vs c0 |
|---|---:|---:|---:|
| c0 | 26.63 | 0.280 | — |
| c1 | 27.70 | 0.292 | +4.0% |
| c2 | 27.20 | 0.286 | +2.1% |
| **c3** | **25.85** | **0.272** | **-2.9%** |
| c4 | 32.19 | 0.339 | +20.9% |

### hg002_illumina_2x250_chr22 (Illumina 250bp, HG002 WGS)

| Cand | Body MB | B/qual | vs c0 |
|---|---:|---:|---:|
| c0 | 65.72 | 0.265 | — |
| c1 | 64.91 | 0.262 | -1.2% |
| c2 | 64.51 | 0.260 | -1.8% |
| **c3** | **64.16** | **0.259** | **-2.4%** |
| c4 | 73.48 | 0.296 | +11.8% |

## 3. Cross-corpus winner: c3

c3 (length-heavy: 8 bit prev_q full-Phred + 4 bit pos + 4 bit length
+ 1 bit revcomp, sloc=17) wins outright on the WES and HG002 Illumina
2×250 corpora and is within 0.7% of c2 on chr22. Across all three:

| Cand | chr22 rank | WES rank | HG002 2×250 rank | mean rank |
|---|---:|---:|---:|---:|
| c0 (V3) | 4 | 3 | 4 | 3.67 |
| c1 | 2 | 4 | 3 | 3.00 |
| c2 | **1** | 2 | 2 | 1.67 |
| **c3** | 3 | **1** | **1** | **1.67** |
| c4 (hash) | 5 | 5 | 5 | 5.00 |

Tied mean rank between c2 and c3, with c3 winning the more diverse
corpora (variable read lengths via WES, longer reads via 2×250).

### Why c3 beats c2 on length-variable / non-100bp Illumina

c2's "drop length, equal-precision history" bet wins on chr22's
uniform 100 bp reads because length_bucket adds zero conditioning
power and the 4 extra bits c2 reinvested in `prev_q[2]` give a
real (small) edge.

But on WES (variable read lengths from exon-by-exon capture) and
HG002 2×250 (250 bp instead of 100 bp), `length_bucket` carries real
signal — different read-length classes have different per-position
quality decay profiles. c3's full-Phred 8-bit prev_q[0] also
distinguishes adjacent Q values that c2's 4-bit-binned `prev_q[0..2]`
collapses, which matters when the quality distribution has narrow
modes.

The key Stage 2 design implication: **prefer c3's bit budget over
c2's** if we want a single static codec design that works robustly
across Illumina coverage patterns and read lengths.

## 4. Cross-corpus loser: c4 (SplitMix64 hash, CRAM-exact)

c4 is the worst candidate on every corpus, ranging from 8.3% worse
than c0 (chr22) to 20.9% worse (WES). The CRAM 3.1 fqzcomp default
of 4096 contexts (sloc=12) is too few for any of these corpora at
their context-feature density. The hash-escalation path (Option A
from brainstorming) is conclusively refuted across Illumina diversity.
**Stage 2 should not adopt SplitMix64 hashing.**

## 5. Diagnostic: c3's `n_active` collapse on WES

On WES, c3 collapses to **5,686 distinct contexts** (out of 131,072
possible at sloc=17). This is partly because:
- WES reads are captured from exon regions; revcomp distribution and
  position-bucket distribution have natural pattern repetition.
- Length-bucket-4 splits 95.7 bp reads across 2-3 buckets; each
  bucket × revcomp × pos × 256 prev_q values × revcomp = ~4-6 K
  populated cells.

The collapse means many would-be contexts go unused, but the
adaptive RC kernel handles sparse contexts well — the actively-used
contexts simply get more symbols each, which sharpens their freq
tables. c3's win on WES is despite (and partly because of) the
collapse: the right contexts get more data.

## 6. Re-charter implications

The Stage 1 §5 outcome `all_fail_recharter` (chr22-only) is reinforced:
no candidate hits the 1.15× CRAM gate on the chr22 reference — the
gate reflects v1.2.0's framework cost which is irrelevant on
non-chr22 datasets. The cross-corpus signal is more useful for the
re-brainstorm session:

1. **c3 is the strongest existing candidate** for a Stage 2 codec.
   Bit budget: 8 bit prev_q[0] + 4 bit pos + 4 bit length + 1 bit
   revcomp, sloc=17. Implements value-aligned `_q_to_8bit` via
   `(q-33).clip(0,255)` and CRAM-finer `_length_bucket_4bit` (16
   buckets, finer than CRAM 3.1 default 8).
2. **The bit-pack > hash hypothesis is confirmed across corpora.**
   No hash-based escalation needed.
3. **The remaining gap to CRAM 3.1's 0.20-0.25 B/qual** (we're at
   0.26-0.39 B/qual depending on corpus) is roughly half the
   B/qual the spec target wanted. Likely sources:
   - Multi-symbol history (chr22 c1's 4+3+2 prev_q didn't help, but
     a richer non-bit-pack model might — e.g. mixture of
     prev_q-conditional submodels)
   - Mate-pair features (paired-end orientation/distance)
   - Error-context (post-mismatch quality bias)
   - Distance-from-read-end (cycle-bias on the trailing end)
4. **PacBio HiFi platform diversity remains untested.** A re-charter
   session that sources HG002 PacBio HiFi with QUAL preserved (e.g.
   from raw subreads or a different pipeline) would be valuable
   before any Stage 2 implementation since long-read characteristics
   differ fundamentally.

## 7. Reproducing this report

Per-corpus harness invocation:

```bash
TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so \
TTIO_PROTOTYPE_BAM=<absolute-path-to-bam> \
TTIO_PROTOTYPE_NAME=<slug> \
    .venv/bin/python -m tools.perf.m94z_v4_prototype.harness
```

Each invocation produces `docs/benchmarks/2026-05-02-m94z-v4-<slug>.md`.

## 8. Open follow-ups

- **PacBio HiFi sourcing.** Find a public HG002 (or any) PacBio HiFi
  BAM that retains per-base qualities. Try PacBio's bioinformatics
  test datasets, or convert from FASTQ via `samtools import`.
- **ONT.** User dropped from this round but adding HG001 ONT (chr22
  slice) is the highest-value missing platform.
- **Sample variability within a platform.** A second NA12878
  Illumina source (different lab, different read length, different
  binning policy) would test whether platform calibration drift
  matters for the right c3 vs c2 choice.
- **Re-run on full HG002 Illumina (10.6M reads).** This run used a
  1M-read subset for tractability; the full 2.6B-quality corpus
  would test scale effects on `n_active` and per-context freq
  convergence.
