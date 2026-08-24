# HANDOFF — M97 long-read profile

**As of 2026-08-24.** M97 adapts the genomic container surface for
long-read assembly inputs: PacBio HiFi, ONT ultra-long, Hi-C and
parental short reads feeding the T2T assembly pipeline (external
A-series repo). Scope was fixed by the A0 ingest probe
(`tti-assemble/docs/probe-report-a0.md`); the probe cleared integer
widths, `.tis` AU limits, block-level slicing, and codec defaults from
the original worry list, leaving the four items below. Branch:
`m97-long-read-profile`.

| Task | Scope | Status | Spec proof |
|---|---|---|---|
| **Phase 0** | `slice_bytes` writer-only proof: hand-reassembled containers byte-identical; non-uniform byte-budget slices decode byte-exact with the unmodified decoder | ✅ 2026-08-24 (`tools/perf/refdiff_slice_bytes_prototype/`) | required before any SDK work (wire-change gate) |
| **T1** | `@read_role` UTF-8 run attribute (vocabulary per Binding Decision §84) + write-side population on `WrittenGenomicRun` / stream-writer options / import CLIs, read accessors, all 3 SDKs | ✅ implemented + tested | — |
| **T2** | QUALITY_BINNED rejected as a `qualities` override on HiFi/PacBio/ONT/Nanopore platforms (§86), whole-channel and stream writers, all 3 SDKs | ✅ implemented + tested | — |
| **T3** | REF_DIFF_V2 `slice_bytes` byte budget (§85, §87): C kernel + `max_encoded_size2`, 3 SDK writers (`ref_diff_slice_bytes` / `refDiffSliceBytes`), both layouts | ✅ implemented + tested | Phase 0 |
| **T4** | Fixtures: cross-language non-uniform-slice byte-equality case (`test_ref_diff_v2_cross_language.py` + CLI `slice_bytes` args), HiFi + ONT-UL shapes through the 3x3 transport matrix (`test_m97_long_read_matrix.py`) | ✅ implemented + verified 3-way byte-equal | — |

Deliberately out of scope, per the probe review:
`AcquisitionMode.GENOMIC_LONGREAD` / `GENOMIC_HIC` (nothing dispatches
on them yet), qualities-codec re-tuning (the M94.Z per-block
auto-tuner already picks V4 on HiFi and V5 on ONT), and the `.tis`
run-metadata JSON, which does not carry `@read_role` — a transport
round-trip preserves read content but drops the attribute; adding the
key is additive JSON if a later milestone needs it.

Suite state at handoff: native ctest 30/30; ObjC 5187 pass / 3
known-environmental TestM90Final failures; Python 2621 pass; Java
1624 tests 0 failures. The M97 tests assert the mechanism engaged —
slice counts are parsed out of the emitted blobs on every writer
path, not inferred from a green round-trip.

---

## When to overwrite this file

This `HANDOFF.md` is replaced *per active milestone* — the git
history (`git log -- HANDOFF.md`) shows that pattern (M81 →
M82 → … → M88.1 → FD-1 stub → this). When the next multi-language
milestone kicks off (e.g. M98 `AssemblyGraph`), overwrite this file
with the milestone's plan + task table; otherwise small post-v1.0
follow-ups go to PRs + CHANGELOG only.

For ongoing work not coordinated through HANDOFF, see:

- `CHANGELOG.md` § `[Unreleased]` — what's landed since the last
  tag.
- `WORKPLAN.md` — milestone history + binding decisions (§84–§87
  are M97's).
- `tti-workbench-server` repository — daemon-side workstreams.
