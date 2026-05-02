# M94.Z V4 candidate prototype — multi-corpus comparison

> **Update 2 (PacBio HiFi added).** The Illumina-only conclusion
> ("c3 is cross-corpus winner") **does not survive contact with
> PacBio HiFi data.** On HG002 PacBio HiFi (~18.5 kb CCS reads,
> qualities clustering at Q93+), **c0 (V3 baseline) wins outright**
> and every bit-pack candidate does worse. The right codec depends
> on the platform's quality-distribution shape. Re-charter framing
> updated again — the design choice is now "pick a single codec
> that's competent across platforms" vs "platform-adaptive codec."

> **Update 1 (Illumina cross-corpus).** The original §5
> conclusion was based on `chr22_na12878_mapped` alone. Extending to
> NA12878 WES + HG002 Illumina 2×250: chr22-only winner (c2) does not
> generalize; c3 wins on 2 of 3 Illumina corpora.
> SplitMix64-hash (c4) was worst on every Illumina corpus.

- Date: 2026-05-02
- Spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage1-design.md`
- Plan: `docs/superpowers/plans/2026-05-02-l2x-m94z-richer-context-stage1.md`
- Per-corpus result docs:
  - chr22: `docs/benchmarks/2026-05-02-m94z-v4-candidates.md`
  - WES: `docs/benchmarks/2026-05-02-m94z-v4-na12878_wes_chr22.md`
  - HG002 Illumina 2×250: `docs/benchmarks/2026-05-02-m94z-v4-hg002_illumina_2x250_chr22.md`
  - HG002 PacBio HiFi: `docs/benchmarks/2026-05-02-m94z-v4-hg002_pacbio_hifi.md`

## 1. Corpora

| Slug | Source | Reads | Qualities | Mean read | Coverage pattern |
|---|---|---:|---:|---:|---|
| `chr22_na12878_mapped` | GIAB NA12878 chr22 (Illumina HiSeq 2×100, lean+mapped) | 1,766,433 | 178,409,733 | 101 bp | WGS, uniform |
| `na12878_wes_chr22` | GIAB Garvan_NA12878 HiSeq exome chr22 slice | 992,974 | 95,035,281 | 95.7 bp | exome capture, variable |
| `hg002_illumina_2x250_chr22` | GIAB HG002 NIST Illumina 2×250bp chr22 (1M-read subset of 10.6M-read full chr22) | 997,415 | 248,184,765 | 248.7 bp | WGS, uniform |
| `hg002_pacbio_hifi` | GIAB HG002 PacBio HiFi CCS (raw FASTQ → BAM via `samtools import`, ~14K-read subset from `m64011_190830_220126.fastq.gz`) | 14,284 | 264,190,341 | 18,495 bp | long-read, narrow Q (Q60+) |

The first three corpora are all Illumina; PacBio HiFi (long-read,
narrow Q-distribution) is the platform diversity probe. **All public
PacBio HiFi BAMs we initially tried** (NIST GIAB GRCh38/GRCh37
alignment variants, PacBio cloud HG002-CpG-methylation-202202 dataset,
both aligned and raw `hifi_reads.bam`) **had `SEQ` and `QUAL`
stripped to `*`**. The workaround was to fetch the raw `*.fastq.gz`
files (which preserve QUAL as ASCII), stream a partial download
through `head` to limit record count, and pipe to `samtools import`
to produce an unaligned BAM. See `feedback_pacbio_hifi_qual_stripped`
memory.

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

### hg002_pacbio_hifi (PacBio HiFi CCS, ~18.5 kb reads)

| Cand | Body MB | B/qual | vs c0 |
|---|---:|---:|---:|
| **c0** | **109.68** | **0.415** | — |
| c1 | 112.21 | 0.425 | +2.3% |
| c2 | 112.44 | 0.426 | +2.5% |
| c3 | 112.08 | 0.424 | +2.2% |
| c4 | 113.22 | 0.428 | +3.2% |

**Every richer-context candidate is *worse* than V3 baseline c0.**
PacBio HiFi qualities cluster heavily at Q60+ (byte values ≥ 93,
many at the maximum Q93 = `~`). The narrow value range means:
- prev_q[0] is nearly constant across positions → deeper history (c1,
  c2) provides almost no conditioning gain.
- The richer-feature candidates spread their data across more
  contexts (c2 uses 65,319 of 131,072 possible at sloc=17), each
  with sparse statistics and similar near-constant freq tables —
  the freq-table overhead per context outweighs the marginal
  conditioning gain.
- c0's smaller table (16,384 contexts at sloc=14) concentrates more
  symbols per context, giving the adaptive RC kernel cleaner freq
  estimates.

The B/qual range (0.42 vs Illumina's 0.26-0.39) reflects that
PacBio HiFi qualities are themselves higher-entropy in raw bytes
(more distinct Q values used) but contain less *informative*
structure for codec exploitation — most prediction power is already
captured by the unconditional symbol distribution. CRAM 3.1's
0.20-0.25 B/qual target is an Illumina figure; PacBio HiFi has a
fundamentally different ceiling.

## 3. Cross-corpus winner depends on platform — no single best

No single candidate wins across all corpora. The winner depends on
the platform's quality-distribution shape:

| Cand | chr22 | WES | HG002 2×250 | PacBio HiFi | mean rank |
|---|---:|---:|---:|---:|---:|
| **c0 (V3, sloc=14)** | 4 | 3 | 4 | **1** | 3.0 |
| c1 (4+3+2 prev_q, length, sloc=17) | 2 | 4 | 3 | 2 | 2.75 |
| **c2** (4+4+4 prev_q, no length, sloc=17) | **1** | 2 | 2 | 4 | 2.25 |
| **c3** (8 prev_q, length, sloc=17) | 3 | **1** | **1** | 3 | 2.0 |
| c4 (SplitMix64 hash, sloc=12) | 5 | 5 | 5 | 5 | **5.0** |

c3 has the best mean rank but only by virtue of two strong wins
(WES, HG002 2×250) — it's middle-of-the-pack on chr22 and PacBio.
c0 (V3 baseline) is the only candidate that wins outright on PacBio
HiFi.

### Why the platform matters

**Illumina (chr22, WES, HG002 2×250):** quality bytes span Q0-Q40
(34 distinct values when `(q-33)>>0` though most cluster in Q15-30).
Adjacent Q values carry information about base-call confidence;
context-conditional freq tables for prev_q[0]-prev_q[2] capture real
local correlation. c3's 8-bit full-Phred prev_q[0] + length_bucket
extracts more signal than c0's 4-bit hash prev_q ring on chr22 —
and the gap widens on WES (variable read lengths → length_bucket
carries real signal) and HG002 2×250 (longer reads → more position
variance). Within Illumina, c3 dominates.

**PacBio HiFi:** quality bytes cluster at Q60+ (byte values ≥ 93)
with a peak at Q93 (`~`). Most prev_q windows are nearly constant.
Per-context freq tables converge to nearly-identical
near-deterministic distributions. Conditioning power vanishes;
splitting into more contexts (sloc=17) only fragments the data
without informational benefit. c0's 16K context space is already
enough to soak up the residual variance. **c0 wins.**

### Implication for Stage 2

There is **no single static bit-pack design that wins across
platforms**. Three viable directions for Stage 2:

1. **Per-platform codec selection.** Sender includes a "quality
   profile" metadata flag (Illumina / PacBio HiFi / ONT / etc.); the
   wire format carries an `sloc` parameter the encoder picks based
   on the data's empirical entropy. Decode is unaffected — it just
   reads `sloc` from the header.
2. **Adaptive sloc per block.** Encoder measures quality entropy
   over the block, picks `sloc` to balance freq-table overhead vs
   conditioning power. No platform tag needed; the data tells the
   encoder. Slightly more encoder complexity.
3. **Ship c3 as default, fall back to c0 when the data doesn't
   benefit.** Encoder runs both candidates on a sample, picks the
   smaller. Adds encode wall but no wire-format complication.

The one option Stage 2 should NOT take: lock in c3 as a static
choice without an adaptive mechanism. PacBio HiFi proves c3 is
strictly worse on long-read data.

## 4. Cross-corpus loser: c4 (SplitMix64 hash, CRAM-exact)

c4 is the worst candidate on every corpus, ranging from 2.3-3.2%
worse than c0 (PacBio) to 20.9% worse (WES). The CRAM 3.1 fqzcomp
default of 4096 contexts (sloc=12) is too few for any of these
corpora at their context-feature density. The hash-escalation path
(Option A from brainstorming) is conclusively refuted across
platforms — Illumina or PacBio. **Stage 2 should not adopt
SplitMix64 hashing.**

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

The Stage 1 §5 outcome `all_fail_recharter` is now strengthened by
PacBio HiFi data. The cross-platform signal:

1. **No single static bit-pack design wins across platforms.** c3
   dominates Illumina; c0 (V3 baseline) dominates PacBio HiFi. Stage
   2 must either pick an adaptive mechanism or lock in to a single
   platform.
2. **Stage 2 design directions** (see §3 "Implication for Stage 2"
   above):
   - Per-platform codec selection via header flag
   - Adaptive `sloc` per block based on measured entropy
   - Two-pass encode (try c3 + c0, pick smaller)
3. **Bit-pack > hash universally confirmed.** No hash-based
   escalation needed for any platform.
4. **PacBio HiFi B/qual ceiling is around 0.42** with the current
   feature set; that may be near-optimal for narrow Q-distribution
   data and additional features (mate-pair, error-context) may not
   move the needle. Illumina retains room to grow toward CRAM 3.1's
   0.20-0.25 B/qual via richer features.
5. **The 1.15× CRAM gate is chr22-v1.2.0-specific and not directly
   applicable to other corpora.** Re-charter discussion should
   distinguish "chr22 v1.2.0 release gate" from "M94.Z multi-platform
   robustness" — they are different acceptance criteria.

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

- ✅ **PacBio HiFi sourcing.** Solved by streaming the raw GIAB
  `*.fastq.gz` files (which preserve QUAL as ASCII) and piping
  through `samtools import` to produce an unaligned BAM. See
  `feedback_pacbio_hifi_qual_stripped` memory. The harness handles
  unaligned BAMs without changes (no genomic positions needed for
  the qualities-only analysis).
- **ONT.** User dropped from this round; adding HG001 ONT (chr22
  slice or raw FASTQ subset) would test the second long-read
  platform with a different quality distribution shape from PacBio
  HiFi (ONT typically Q5-Q20 vs HiFi Q60+).
- **Sample variability within a platform.** A second Illumina source
  (different lab, different binning policy, different prep) would
  test whether platform calibration drift matters for the right c3
  vs c0 choice within Illumina.
- **Re-run on full HG002 Illumina (10.6M reads).** This run used a
  1M-read subset for tractability; the full 2.6B-quality corpus
  would test scale effects on `n_active` and per-context freq
  convergence.
- **PacBio HiFi at larger scale.** This run used 14K reads
  (~264M qualities) — comparable per-quality count to chr22
  but only 14K distinct reads. Repeat with 50K-100K reads to see
  if the c0-wins ranking holds at scale or if c3's extra contexts
  start to pay off when there's more data per context.
