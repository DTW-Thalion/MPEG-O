# M94.Z V4 candidate prototype — hg002_pacbio_hifi results

- Dataset name: `hg002_pacbio_hifi`
- BAM: `/home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam`
- Date: 2026-05-02
- Host: TTI-PC-0001 (Linux 6.6.87.2-microsoft-standard-WSL2)
- Git HEAD: `ef818e4`
- BAM load: 1.53s
- n_qualities: 264,190,341 ; n_reads: 14,284
- CRAM reference: 86,094,472 bytes (86.094 MB)
- Spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage1-design.md`

## Per-candidate compression

For non-chr22 datasets the +44 MB non-qualities constant and the 1.15× CRAM gate are NOT directly applicable — the cross-dataset signal is the per-candidate body bytes and B/qual ranking. The total/×CRAM columns are still reported using the chr22 framework as a rough yardstick.

| Candidate | Description | Body MB | B/qual | Total MB | × CRAM | Pass 1.15x | Encode s |
|---|---|---:|---:|---:|---:|---|---:|
| c0 | V3 baseline mirror (sloc=14, low-bit hash prev_q ring) | 109.6797 | 0.4152 | 153.6697 | 1.7849 | ✗ | 15.77 |
| c1 | CRAM-faithful: 4+3+2 prev_q + 4 pos + 3 length + 1 revcomp (sloc=17) | 112.2145 | 0.4247 | 156.2045 | 1.8143 | ✗ | 18.77 |
| c2 | Equal-precision history, drop length: 4+4+4 prev_q + 4 pos + 1 revcomp (sloc=17) | 112.4384 | 0.4256 | 156.4284 | 1.8169 | ✗ | 17.41 |
| c3 | Length-heavy: 8 prev_q + 4 pos + 4 length + 1 revcomp (sloc=17) | 112.0838 | 0.4243 | 156.0738 | 1.8128 | ✗ | 15.01 |
| c4 | SplitMix64 hash on CRAM 3.1 feature vec → 12-bit (sloc=12, 4096 ctx) | 113.2181 | 0.4285 | 157.2081 | 1.8260 | ✗ | 17.51 |

## Per-candidate diagnostics

| Candidate | sloc | n_active | distinct_ctx | symbols/ctx |
|---|---:|---:|---:|---:|
| c0 | 14 | 16384 | 16384 | 16125 |
| c1 | 17 | 11656 | 11656 | 22666 |
| c2 | 17 | 65319 | 65319 | 4045 |
| c3 | 17 | 4370 | 4370 | 60455 |
| c4 | 12 | 4096 | 4096 | 64500 |

## Top-10 most-frequent contexts per candidate

### c0

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 12014 | 24,041,128 |
| 2 | 7918 | 23,984,266 |
| 3 | 16110 | 23,835,670 |
| 4 | 3822 | 23,660,835 |
| 5 | 7902 | 538,821 |
| 6 | 11998 | 538,475 |
| 7 | 3806 | 534,196 |
| 8 | 16094 | 531,265 |
| 9 | 11982 | 521,898 |
| 10 | 7886 | 521,667 |

### c1

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 61951 | 11,837,609 |
| 2 | 61439 | 11,832,657 |
| 3 | 62975 | 11,823,424 |
| 4 | 62463 | 11,820,416 |
| 5 | 60927 | 11,816,153 |
| 6 | 63487 | 11,803,377 |
| 7 | 63999 | 11,790,557 |
| 8 | 60415 | 11,790,343 |
| 9 | 59903 | 11,780,284 |
| 10 | 64511 | 11,773,871 |

### c2

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 36863 | 11,104,752 |
| 2 | 32767 | 11,100,255 |
| 3 | 45055 | 11,088,966 |
| 4 | 40959 | 11,087,483 |
| 5 | 28671 | 11,083,038 |
| 6 | 49151 | 11,070,142 |
| 7 | 53247 | 11,059,077 |
| 8 | 24575 | 11,058,052 |
| 9 | 20479 | 11,047,850 |
| 10 | 57343 | 11,042,011 |

### c3

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 59485 | 9,683,342 |
| 2 | 59229 | 9,680,960 |
| 3 | 58973 | 9,672,075 |
| 4 | 59997 | 9,670,800 |
| 5 | 59741 | 9,667,347 |
| 6 | 60253 | 9,651,041 |
| 7 | 58717 | 9,642,471 |
| 8 | 60509 | 9,634,446 |
| 9 | 58461 | 9,632,312 |
| 10 | 60765 | 9,614,489 |

### c4

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 184 | 5,854,613 |
| 2 | 650 | 5,849,349 |
| 3 | 1319 | 5,797,546 |
| 4 | 2402 | 5,796,042 |
| 5 | 919 | 5,793,562 |
| 6 | 2180 | 5,789,158 |
| 7 | 252 | 5,788,748 |
| 8 | 4021 | 5,777,228 |
| 9 | 845 | 5,770,763 |
| 10 | 3914 | 5,765,231 |

## §5 decision-rule outcome

**Case:** `no_improvement`

Best candidate **c0** at 1.7849x CRAM matches or exceeds c0's 1.7849x. Fundamental model wrong; brainstorm again from scratch.

## Errors

(none)

## Deferred verification

Round-trip verification (decode + byte-equality of recovered
qualities vs input, per spec §6.4 + §8 acceptance criterion #3)
was not run in Stage 1. The compressed-size numbers are
indicative — they reflect what the V3 RC kernel produced for
each candidate's sparse_seq, not whether decode-side context
re-derivation can recover the input. **If Stage 2 ever opens,
the winning candidate must be round-trip-verified before any
production work.**

