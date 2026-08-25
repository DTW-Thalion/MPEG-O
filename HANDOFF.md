# HANDOFF — M99/M99.1 streaming per-AU protection

**As of 2026-08-25.** M99 makes per-AU protection cover what the
genomic write path actually produces: `encrypt_per_au` raised
`KeyError` on any run in the default `blocks_v1` layout, so nothing
written by the current genomic writers could be encrypted at all.
The walkers in all 3 SDKs now stream `blocks_v1` runs block by block
(format-spec §9.1.1, binding decisions §93–§95), which also removes
the whole-channel memory ceiling: peak RSS follows the block policy
(64 MB default), not the channel size. Phase 0 proved per-block
re-encode byte-determinism and the AU arithmetic on probes before
any implementation. M99.1 hardens the restore contract — writer
policy and the reference set persist as run attrs, the encrypt-time
gate is gone, restore falls back to an index rewrite — and carries
`blocks_v1` runs on the encrypted transport stream via the
transport-spec v0.12 sidecar packets. Branch:
`m99-streaming-per-au`.

| Task | Scope | Status | Spec proof |
|---|---|---|---|
| **Phase 0** | Probes: `encrypt_per_au` raises on blocks_v1; per-block re-encode is byte-deterministic across all channels and codecs (REF_DIFF_V2 included) under the sticky qualities discipline; per-block decode + global-AU GCM round-trips 10,000/10,000 AUs incl. zero-length reads | ✅ 2026-08-25 (design-docs spec note + probes) | required before the walker design froze |
| **A Python** | Block-streaming encrypt walker (per-block decode → per-read AUs, global numbering, extendable segments append, restorability verified per block before any deletion) + block-streaming decrypt-in-place (per-block segment-row reads, re-encode, byte-identity restore, index untouched); `au_base`/`offset_base` plumbing; RSS-bound test: 0.0 MB peak growth over ~104 MB of decoded channels | ✅ 8 tests | — |
| **B ObjC** | Mirror walkers in `TTIOPerAUFile`; `TTIOCompoundIO` extendable compounds gain VL fields + ranged reads; `TTIOPerAUEncryption` auBase/offsetBase; `TTIOBlockView` skipChannels | ✅ 58 M99 assertions incl. the send guard | — |
| **C Java** | Mirror walkers in `PerAUFile`; `Hdf5CompoundIO` VL extendable append + `readCompoundFullRange` (explicit memory spaces — H5S_ALL with a hyperslab file selection overruns the compact buffer); `VlBytesFFM` memory-space overloads; compound adapter `readSlice` hyperslab; `BlockTable`/`BlockView` public walker surface | ✅ 6 tests | — |
| **D Conformance** | 3×3 encryptor × decryptor matrix over stream-written blocks_v1 fixtures (cross-chromosome mates + zero-length reads; embedded-reference REF_DIFF_V2), byte-identical blobs + index in every cell (`tests/validation/test_m99_blocks_v1_matrix.py`) | ✅ 18/18 cells | — |
| **E Transport guard** | A `.tis` stream of a blocks_v1 per-AU container receives to a file decrypt-in-place cannot restore (the stream does not carry the blocks_v1 sidecars); all three senders now refuse with a clear error | ✅ ×3, superseded by I | wire extension deferred (own Phase 0) |
| **F Docs** | format-spec §9.1.1, binding decisions §93–§95, CHANGELOG, cross-language-matrix row, this file | ✅ | — |
| **G M99.1 policy persist + fallback** | Writers persist `@ref_diff_slice_bytes` / `@opt_disable_qualities_v5` when non-default, walkers honour them, the encrypt-time re-encode/byte-compare gate is removed ×3 SDKs, and restore rewrites `blocks/index` when a re-encoded blob misses its recorded ranges instead of refusing | ✅ ×3 SDKs, policy + fallback tests each | — |
| **H M99.1 reference_md5s** | Writers persist `@reference_md5s` (chromosome → hex reference-set digest) for REF_DIFF_V2 runs; restore rebuilds `reference_chrom_seqs` through the reference resolver (embedded or `REF_PATH`), so `embed_reference=False` runs encrypt and restore | ✅ ×3 SDKs, unembedded 2-chromosome REF_PATH round trips | digest = the blob-header md5 the resolver verifies |
| **I M99.1 transport sidecars** | Transport-spec v0.12: `GenomicRunSidecar` (0x1C) + `BlockSidecar` (0x1D) + required `transport_blocks_v1` feature token; senders emit instead of refusing, receivers rebuild the blocks_v1 shape, decrypt-in-place on the received container is byte-identical | ✅ ×3 SDKs + 3×3 send × receive matrix (27/27 with the per-AU plane) | Phase 0 Python prototype + spec §4.24 before ObjC/Java |

Restore contract (M99.1): decrypt-in-place re-encodes each block
through the block writer, replicating the stream writer's sticky
qualities strategy (block 0 auto-tunes, the winner read back from
the encoded stream pins the rest) and honouring the persisted policy
attrs, and appends the blobs into recreated channel datasets. When
every blob lands on the recorded ranges the index is untouched and
the restore is byte-identical; otherwise the index is rewritten to
the ranges actually written and the file stays consistent and
readable. REF_DIFF_V2 references resolve from `/study/references/`
or `REF_PATH` via `@reference_md5s`.

Known limits, deliberate: the MS (codec-17) and assembly-graph
per-AU paths stay whole-channel (FDZ1 per-block streaming and graph
channel framing are separable follow-ups; the graph case is a wire
change); the encrypted stream does not carry embedded reference
bytes, so a received REF_DIFF container restores via `REF_PATH`;
pre-v0.12 receivers skip the sidecar packets and rebuild an
unrestorable legacy-shaped container, detectable only through the
`transport_blocks_v1` feature token.

Suite state at handoff (post-M99.1): Python 2714 pass 0 fail; ObjC
5340 pass / 3 known-environmental TestM90Final failures; Java 1644
tests 0 failures 18 skipped.

---

## When to overwrite this file

This `HANDOFF.md` is replaced *per active milestone* — the git
history (`git log -- HANDOFF.md`) shows that pattern (M81 →
M82 → … → M98 → this). When the next multi-language milestone kicks
off, overwrite this file with the milestone's plan + task table;
otherwise small post-v1.0 follow-ups go to PRs + CHANGELOG only.

For ongoing work not coordinated through HANDOFF, see:

- `CHANGELOG.md` § `[Unreleased]` — what's landed since the last
  tag.
- `WORKPLAN.md` — milestone history + binding decisions (§93–§95
  are M99's).
- `tti-workbench-server` repository — daemon-side workstreams.
