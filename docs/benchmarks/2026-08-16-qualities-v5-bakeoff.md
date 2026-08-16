# Qualities V5 bake-off — sequence-motif context (R6 spec-proof)

- Date: 2026-08-16
- Follow-up to R6 of the compression audit; informs the V5 spec.
- Prototype: `tools/perf/m94z_v4_prototype/fqzcomp_seqctx_ref.c`
  (V4-shaped adaptive model + htscodecs range coder, seq-context
  field spliced into the context word; every run decodes its own
  output and fails on mismatch, so all sizes are from decodable
  models). Grid drivers: `run_seqctx_grid.sh`, `run_seqctx_grid2.sh`;
  tables: `seqctx_report.py`. Throwaway code, per the V4 precedent.
- Corpora: the 4 BAMs from the V4 multi-corpus run, extracted with
  `extract_seqctx_inputs.py` (QUAL + parallel SEQ + lengths). All
  reads in all 4 corpora carry SEQ, so no reads were excluded.

## Candidate key

`m0` = no sequence context (V4-shaped baseline). `m1 winNc` = packed
window of the current base and N predecessors, 2 bits each. `m2 winNp`
= predecessors only. `m3 hash kK>Bb` = multiplicative hash of the
last K bases folded to B bits. `qN` = quality-history bits (`/S`
suffix = qshift when not 5), `pN` = position bits, `sN` = sequence
bits. Context total is capped at 18 bits ((1<<18) * ~1 KB adaptive
models = 268 MB transient at encode; 16-bit configs use 67 MB).

## Conclusions

1. The win exists and is large exactly where quality values carry
   motif-correlated error structure: chr22 NA12878 (2012-era
   Illumina 100 bp) improves 22.7%, PacBio HiFi 4.4%. WES capture
   and HG002 2x250 get WORSE under every sequence-context candidate
   (best attempts +2.2% and +0.1%): splitting the adaptive contexts
   costs more than the motif signal pays on those platforms.
2. The winning form everywhere is the packed window INCLUDING the
   current base (m1). Predecessors-only (m2) and hashed k-mers (m3)
   lose on every corpus — the current base is the signal, and hash
   folding destroys the locality the model exploits.
3. The optimum is a flat plateau (chr22: q6/s5 0.2782, q6/s4 0.2795,
   q7/s4 0.2798), so a small fixed set of strategies captures it:
   `q6 p7 s5` (Illumina-2012 class) and `q8 p4 s6` (HiFi class).
4. Design consequence: V5 adds sequence-context strategies to the
   V4 auto-tune set and the encoder keeps the smaller body by exact
   size, the codec-17 selector idiom. Corpora where sequence context
   loses pay encode time (~1.5-2x per candidate tried), never bytes.
   The writer gates V5 on SEQ presence (per-read parallel bases);
   sequence-less runs stay V4 by construction.
5. Against the audit anchor: V4 chr22 = 0.358 B/q vs CRAM-class
   0.20-0.25; V5 at 0.2782 closes roughly half the remaining gap.

## Per-corpus results

Sorted by size; bold = smaller than the best m0 baseline. B/q =
bytes per quality. Walls are single runs, single-thread - indicative
only; sizes are the decision metric and are deterministic.

### chr22 (baseline m0 q10 p7 = 0.3600 B/q)

| candidate | bytes | B/q | vs base | wall s |
|---|---:|---:|---:|---:|
| **m1 q6 p7 s5 win2c** | 49,640,805 | 0.2782 | -22.7% | 12 |
| **m1 q6 p7 s4 win2c** | 49,862,878 | 0.2795 | -22.4% | 8 |
| **m1 q7 p7 s4 win2c** | 49,923,420 | 0.2798 | -22.3% | 12 |
| **m1 q5 p7 s4 win2c** | 50,107,926 | 0.2809 | -22.0% | 7 |
| **m1 q4 p7 s6 win3c** | 52,024,999 | 0.2916 | -19.0% | 9 |
| **m1 q6 p6 s6 win3c** | 53,282,938 | 0.2987 | -17.0% | 10 |
| **m1 q8 p7 s3 win1c** | 53,829,174 | 0.3017 | -16.2% | 12 |
| **m1 q8 p6 s4 win2c** | 53,942,358 | 0.3024 | -16.0% | 10 |
| **m1 q6/3 p7 s4 win2c** | 53,948,903 | 0.3024 | -16.0% | 11 |
| **m1 q8 p4 s6 win3c** | 56,588,771 | 0.3172 | -11.9% | 7 |
| **m1 q8 p7 s2 win1c** | 56,811,813 | 0.3184 | -11.5% | 10 |
| **m1 q10 p7 s1 win0c** | 60,271,414 | 0.3378 | -6.2% | 11 |
| **m2 q8 p6 s4 win2p** | 62,386,215 | 0.3497 | -2.9% | 11 |
| m0 q10 p7 | 64,223,419 | 0.3600 | +0.0% | 9 |
| m0 q8 p7 | 64,960,392 | 0.3641 | +1.1% | 6 |
| m3 q8 p4 s6 hash k6>6b | 69,065,604 | 0.3871 | +7.5% | 10 |
| m3 q8 p4 s6 hash k8>6b | 69,999,506 | 0.3924 | +9.0% | 10 |

### wes (baseline m0 q8 p7 = 0.2798 B/q)

| candidate | bytes | B/q | vs base | wall s |
|---|---:|---:|---:|---:|
| m0 q8 p7 | 26,592,676 | 0.2798 | +0.0% | 2 |
| m0 q10 p7 | 26,624,035 | 0.2801 | +0.1% | 3 |
| m1 q10 p7 s1 win0c | 27,174,463 | 0.2859 | +2.2% | 4 |
| m1 q8 p7 s2 win1c | 27,319,257 | 0.2875 | +2.7% | 4 |
| m1 q8 p4 s6 win3c | 27,582,354 | 0.2902 | +3.7% | 3 |
| m1 q6 p7 s4 win2c | 27,856,319 | 0.2931 | +4.8% | 4 |
| m1 q8 p7 s3 win1c | 28,081,701 | 0.2955 | +5.6% | 6 |
| m3 q8 p4 s6 hash k6>6b | 28,287,767 | 0.2977 | +6.4% | 4 |
| m3 q8 p4 s6 hash k8>6b | 28,328,832 | 0.2981 | +6.5% | 4 |
| m1 q8 p6 s4 win2c | 28,353,700 | 0.2983 | +6.6% | 6 |
| m2 q8 p6 s4 win2p | 28,553,861 | 0.3005 | +7.4% | 6 |
| m1 q4 p7 s6 win3c | 29,523,965 | 0.3107 | +11.0% | 5 |

### x250 (baseline m0 q10 p7 = 0.2758 B/q)

| candidate | bytes | B/q | vs base | wall s |
|---|---:|---:|---:|---:|
| m0 q10 p7 | 729,295,346 | 0.2758 | +0.0% | 58 |
| m1 q10 p7 s1 win0c | 730,029,591 | 0.2760 | +0.1% | 78 |
| m1 q8 p7 s2 win1c | 739,891,197 | 0.2798 | +1.5% | 77 |
| m0 q8 p7 | 740,573,575 | 0.2800 | +1.5% | 50 |
| m1 q8 p7 s3 win1c | 740,942,021 | 0.2802 | +1.6% | 100 |
| m1 q8 p6 s4 win2c | 743,550,937 | 0.2812 | +2.0% | 81 |
| m2 q8 p6 s4 win2p | 745,400,259 | 0.2819 | +2.2% | 80 |
| m1 q8 p4 s6 win3c | 745,603,748 | 0.2819 | +2.2% | 76 |
| m1 q6 p7 s4 win2c | 748,880,761 | 0.2832 | +2.7% | 84 |
| m3 q8 p4 s6 hash k6>6b | 752,976,649 | 0.2847 | +3.2% | 78 |
| m3 q8 p4 s6 hash k8>6b | 753,609,325 | 0.2850 | +3.3% | 79 |
| m1 q4 p7 s6 win3c | 786,906,620 | 0.2976 | +7.9% | 94 |

### hifi (baseline m0 q10 p7 = 0.4151 B/q)

| candidate | bytes | B/q | vs base | wall s |
|---|---:|---:|---:|---:|
| **m1 q8 p4 s6 win3c** | 104,815,527 | 0.3967 | -4.4% | 7 |
| **m1 q8 p6 s4 win2c** | 105,452,081 | 0.3992 | -3.8% | 5 |
| **m1 q6 p6 s6 win3c** | 105,618,241 | 0.3998 | -3.7% | 6 |
| **m1 q7 p7 s4 win2c** | 106,111,571 | 0.4016 | -3.2% | 5 |
| **m1 q6 p7 s5 win2c** | 106,603,020 | 0.4035 | -2.8% | 5 |
| **m1 q6 p7 s4 win2c** | 106,706,317 | 0.4039 | -2.7% | 5 |
| **m1 q4 p7 s6 win3c** | 107,054,097 | 0.4052 | -2.4% | 5 |
| **m1 q5 p7 s4 win2c** | 107,078,580 | 0.4053 | -2.4% | 5 |
| **m1 q6/3 p7 s4 win2c** | 107,483,881 | 0.4068 | -2.0% | 5 |
| **m1 q8 p7 s3 win1c** | 108,704,254 | 0.4115 | -0.9% | 5 |
| m0 q10 p7 | 109,669,498 | 0.4151 | +0.0% | 4 |
| m1 q10 p7 s1 win0c | 110,005,858 | 0.4164 | +0.3% | 5 |
| m2 q8 p6 s4 win2p | 110,241,402 | 0.4173 | +0.5% | 5 |
| m0 q8 p7 | 110,519,690 | 0.4183 | +0.8% | 4 |
| m1 q8 p7 s2 win1c | 110,662,271 | 0.4189 | +0.9% | 5 |
| m3 q8 p4 s6 hash k6>6b | 112,201,901 | 0.4247 | +2.3% | 9 |
| m3 q8 p4 s6 hash k8>6b | 112,359,563 | 0.4253 | +2.5% | 9 |
