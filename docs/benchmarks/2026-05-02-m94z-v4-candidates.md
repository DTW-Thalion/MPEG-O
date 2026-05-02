# M94.Z V4 candidate prototype — chr22 results

- Date: 2026-05-02
- Host: TTI-PC-0001 (Linux 6.6.87.2-microsoft-standard-WSL2)
- Git HEAD: `1e7f3f6`
- BAM load: 3.94s
- Spec: `docs/superpowers/specs/2026-05-02-l2x-m94z-richer-context-stage1-design.md`

## Per-candidate compression

Total file size = qualities body + ~44 MB non-qualities (constant across candidates, from chr22 L1+L3 baseline). Ratio is total / CRAM 3.1 (86.094 MB).

| Candidate | Description | Body MB | Total MB | × CRAM | Pass 1.15x | Encode s |
|---|---|---:|---:|---:|---|---:|
| c0 | V3 baseline mirror (sloc=14, low-bit hash prev_q ring) | 69.2598 | 113.2498 | 1.3154 | ✗ | 11.00 |
| c1 | CRAM-faithful: 4+3+2 prev_q + 4 pos + 3 length + 1 revcomp (sloc=17) | 64.1501 | 108.1401 | 1.2561 | ✗ | 12.07 |
| c2 | Equal-precision history, drop length: 4+4+4 prev_q + 4 pos + 1 revcomp (sloc=17) | 63.9618 | 107.9518 | 1.2539 | ✗ | 12.05 |
| c3 | Length-heavy: 8 prev_q + 4 pos + 4 length + 1 revcomp (sloc=17) | 64.4353 | 108.4253 | 1.2594 | ✗ | 10.11 |
| c4 | SplitMix64 hash on CRAM 3.1 feature vec → 12-bit (sloc=12, 4096 ctx) | 74.9816 | 118.9716 | 1.3819 | ✗ | 12.00 |

## Per-candidate diagnostics

| Candidate | sloc | n_active | distinct_ctx | symbols/ctx |
|---|---:|---:|---:|---:|
| c0 | 14 | 16384 | 16384 | 10889 |
| c1 | 17 | 12165 | 12165 | 14666 |
| c2 | 17 | 45259 | 45259 | 3942 |
| c3 | 17 | 1471 | 1471 | 121285 |
| c4 | 12 | 4096 | 4096 | 43557 |

## §5 decision-rule outcome

**Case:** `all_fail_recharter`

Best candidate **c2** lands at 1.2539x CRAM, between V3's 1.3154x and the 1.15x target. All candidates fail the hard gate. Re-charter Task #84: extend feature set (distance_from_end, mate-pair, error-context) or renegotiate the v1.2.0 gate.

## Errors

(none)

