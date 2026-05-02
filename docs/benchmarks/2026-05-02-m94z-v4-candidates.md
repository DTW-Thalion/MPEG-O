# M94.Z V4 candidate prototype — chr22 results

- Date: 2026-05-02
- Host: TTI-PC-0001 (Linux 6.6.87.2-microsoft-standard-WSL2)
- Git HEAD: `24d98c9`
- BAM load: 3.92s
- Spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage1-design.md`

## Per-candidate compression

Total file size = qualities body + ~44 MB non-qualities (constant across candidates, from chr22 L1+L3 baseline). Ratio is total / CRAM 3.1 (86.094 MB).

| Candidate | Description | Body MB | Total MB | × CRAM | Pass 1.15x | Encode s |
|---|---|---:|---:|---:|---|---:|
| c0 | V3 baseline mirror (sloc=14, low-bit hash prev_q ring) | 69.2598 | 113.2498 | 1.3154 | ✗ | 10.98 |
| c1 | CRAM-faithful: 4+3+2 prev_q + 4 pos + 3 length + 1 revcomp (sloc=17) | 64.2375 | 108.2275 | 1.2571 | ✗ | 12.64 |
| c2 | Equal-precision history, drop length: 4+4+4 prev_q + 4 pos + 1 revcomp (sloc=17) | 63.9618 | 107.9518 | 1.2539 | ✗ | 11.89 |
| c3 | Length-heavy: 8 prev_q + 4 pos + 4 length + 1 revcomp (sloc=17) | 64.4353 | 108.4253 | 1.2594 | ✗ | 10.21 |
| c4 | SplitMix64 hash on CRAM 3.1 feature vec → 12-bit (sloc=12, 4096 ctx) | 74.9816 | 118.9716 | 1.3819 | ✗ | 11.83 |

## Per-candidate diagnostics

| Candidate | sloc | n_active | distinct_ctx | symbols/ctx |
|---|---:|---:|---:|---:|
| c0 | 14 | 16384 | 16384 | 10889 |
| c1 | 17 | 6769 | 6769 | 26357 |
| c2 | 17 | 45259 | 45259 | 3942 |
| c3 | 17 | 1471 | 1471 | 121285 |
| c4 | 12 | 4096 | 4096 | 43557 |

## Top-10 most-frequent contexts per candidate

### c0

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 13107 | 5,854,339 |
| 2 | 819 | 5,554,033 |
| 3 | 4915 | 4,564,943 |
| 4 | 9011 | 4,490,737 |
| 5 | 11195 | 1,951,851 |
| 6 | 0 | 1,830,349 |
| 7 | 7099 | 1,787,645 |
| 8 | 7098 | 859,429 |
| 9 | 10939 | 854,937 |
| 10 | 6843 | 828,791 |

### c1

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 19802 | 3,763,529 |
| 2 | 86874 | 3,708,869 |
| 3 | 19290 | 3,410,527 |
| 4 | 87386 | 3,369,874 |
| 5 | 87898 | 3,261,746 |
| 6 | 88410 | 3,147,268 |
| 7 | 18778 | 3,146,808 |
| 8 | 18266 | 2,995,426 |
| 9 | 20314 | 2,915,961 |
| 10 | 86362 | 2,839,498 |

### c2

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 27306 | 3,403,057 |
| 2 | 109226 | 3,166,848 |
| 3 | 23210 | 3,150,496 |
| 4 | 105130 | 3,077,986 |
| 5 | 113322 | 2,989,410 |
| 6 | 19114 | 2,794,284 |
| 7 | 117418 | 2,688,334 |
| 8 | 65536 | 2,438,474 |
| 9 | 15018 | 2,426,671 |
| 10 | 31402 | 2,338,159 |

### c3

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 84010 | 1,860,590 |
| 2 | 84266 | 1,838,935 |
| 3 | 18218 | 1,838,378 |
| 4 | 17962 | 1,824,459 |
| 5 | 81922 | 1,555,223 |
| 6 | 85289 | 1,530,952 |
| 7 | 20226 | 1,500,916 |
| 8 | 17193 | 1,494,518 |
| 9 | 85033 | 1,413,647 |
| 10 | 17450 | 1,411,383 |

### c4

| Rank | Context ID | Count |
|---:|---:|---:|
| 1 | 656 | 1,471,506 |
| 2 | 2087 | 1,311,658 |
| 3 | 493 | 1,247,640 |
| 4 | 833 | 1,211,053 |
| 5 | 1879 | 1,141,215 |
| 6 | 149 | 1,119,976 |
| 7 | 2847 | 1,075,002 |
| 8 | 3446 | 1,045,790 |
| 9 | 1873 | 1,040,999 |
| 10 | 2727 | 901,483 |

## §5 decision-rule outcome

**Case:** `all_fail_recharter`

Best candidate **c2** lands at 1.2539x CRAM, between V3's 1.3154x and the 1.15x target. All candidates fail the hard gate. Re-charter Task #84: extend feature set (distance_from_end, mate-pair, error-context) or renegotiate the v1.2.0 gate.

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

