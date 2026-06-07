# Perf P1e — cross-SDK perf-parity check — Design

**Date:** 2026-06-07
**Origin:** perf-suite analysis coverage gap (no cross-SDK perf-parity check). Final P1 sub-cycle
(after P0, P1a–P1d).
**Scope:** A tool + report that flags per-metric timing outliers across the Python/Java/ObjC
baselines, so large unexplained cross-SDK gaps surface for investigation instead of hiding in
`baseline.json`. Perf-tooling only — no SDK product code.

## Problem
The three harnesses bench the same operations, but nothing checks whether they perform
*comparably*. Reading `baseline.json` by hand, several metrics differ by 100–700× across SDKs —
some legitimate (ObjC `import.bam` spawns samtools via NSTask; Java `spectra.build` JITs to
~0ms), some meaningless (sub-µs metrics where the fastest SDK rounds to 0.00ms), and some
genuine concerns (Python `streaming.read` 1355ms vs Java 1.9ms; `ms.sqlite.read` 1147ms vs
2.2ms; `transport.plain.encode` 2465ms vs 163ms). We want these surfaced and triaged.

## Design

### Tool: `tools/perf/check_parity.py`
Reads `baseline.json`, and for every metric present in ALL three SDK sections (excluding
`*_mb` size metrics):
1. Compute `ratio = max(ms) / min(ms)` across the three SDKs.
2. **Absolute floor on the MIN:** if the minimum value across SDKs is below `min_abs_ms`
   (reuse `_meta.min_abs_ms` = 5ms), skip the ratio — a few-µs absolute difference produces a
   meaningless 1000× ratio (e.g. `spectra.build.*` where Java ≈ 0.00ms). Report these as
   `below-floor (informational)`, never a parity failure.
3. **Allow-list** (`_meta.parity_allow` in baseline.json): metric → short reason for a known,
   legitimate cross-SDK gap (e.g. `import.bam`: "ObjC spawns samtools via NSTask";
   `signatures.pqc.sign`: "Java BouncyCastle vs liboqs C"). Allow-listed metrics are reported
   with their reason and never fail.
4. **Flag** any remaining metric whose ratio ≥ `parity_ratio_threshold` (`_meta`, default
   `10.0`) as a parity outlier.
5. Emit a Markdown table (ratio, per-SDK ms, verdict: OK / below-floor / allow-listed / FLAG)
   and exit non-zero if any un-allow-listed, above-floor metric exceeds the threshold — so it
   can gate a manual parity review (same manual-only usage as the rest of the suite).

`_meta` additions to `baseline.json`:
- `parity_ratio_threshold`: 10.0
- `parity_allow`: `{ "<metric>": "<reason>", ... }`

### Report: `docs/benchmarks/2026-06-07-perf-xsdk-parity.md`
Snapshot of the current parity state in three buckets:
- **At parity** (ratio < threshold): the bulk — confirms the harnesses are comparable there.
- **Legitimately different** (allow-listed): each with its reason.
- **Flagged for follow-up**: the genuine concerns (Python `streaming.read`, `ms.sqlite.read`,
  `transport.plain.encode`, etc.) — documented as "investigate whether real SDK slowness or
  non-comparable workload," NOT fixed here (out of scope; becomes follow-up issues).

### TDD
`tools/perf/test_check_parity.py`: unit-test the ratio math, the min-abs floor (a sub-floor
metric never flags), the allow-list (an allow-listed high-ratio metric never flags), and the
threshold (an above-floor non-allow-listed metric over threshold DOES flag, under does not).

## Invariants & verification
- Perf-tooling only — no SDK product code; reads baseline.json (+ adds `_meta` keys).
- `check_parity.py` runs against the committed baseline and produces the table; exit code
  reflects un-allow-listed above-floor outliers.
- Unit tests cover ratio / floor / allow-list / threshold.
- The report enumerates every flagged metric with a disposition (allow-list reason or
  follow-up).

## Success criteria
`check_parity.py` (+ tests) flags cross-SDK timing outliers with an abs floor and an allow-list;
`baseline.json` gains `parity_ratio_threshold` + `parity_allow`; a parity report documents the
current state and lists genuine concerns as follow-ups. One PR.

## Out of scope
Investigating/fixing the flagged outliers themselves (e.g. why Python streaming/sqlite reads are
slow) — those become separate issues. This sub-cycle delivers the detector + triage, completing
the P1 coverage-gap campaign.
