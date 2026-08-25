# HANDOFF — M99 streaming per-AU protection

**As of 2026-08-25.** M99 makes per-AU protection cover what the
genomic write path actually produces: `encrypt_per_au` raised
`KeyError` on any run in the default `blocks_v1` layout, so nothing
written by the current genomic writers could be encrypted at all.
The walkers in all 3 SDKs now stream `blocks_v1` runs block by block
(format-spec §9.1.1, binding decisions §93–§95), which also removes
the whole-channel memory ceiling: peak RSS follows the block policy
(64 MB default), not the channel size. Phase 0 proved per-block
re-encode byte-determinism and the AU arithmetic on probes before
any implementation. Branch: `m99-streaming-per-au`.

| Task | Scope | Status | Spec proof |
|---|---|---|---|
| **Phase 0** | Probes: `encrypt_per_au` raises on blocks_v1; per-block re-encode is byte-deterministic across all channels and codecs (REF_DIFF_V2 included) under the sticky qualities discipline; per-block decode + global-AU GCM round-trips 10,000/10,000 AUs incl. zero-length reads | ✅ 2026-08-25 (design-docs spec note + probes) | required before the walker design froze |
| **A Python** | Block-streaming encrypt walker (per-block decode → per-read AUs, global numbering, extendable segments append, restorability verified per block before any deletion) + block-streaming decrypt-in-place (per-block segment-row reads, re-encode, byte-identity restore, index untouched); `au_base`/`offset_base` plumbing; RSS-bound test: 0.0 MB peak growth over ~104 MB of decoded channels | ✅ 8 tests | — |
| **B ObjC** | Mirror walkers in `TTIOPerAUFile`; `TTIOCompoundIO` extendable compounds gain VL fields + ranged reads; `TTIOPerAUEncryption` auBase/offsetBase; `TTIOBlockView` skipChannels | ✅ 58 M99 assertions incl. the send guard | — |
| **C Java** | Mirror walkers in `PerAUFile`; `Hdf5CompoundIO` VL extendable append + `readCompoundFullRange` (explicit memory spaces — H5S_ALL with a hyperslab file selection overruns the compact buffer); `VlBytesFFM` memory-space overloads; compound adapter `readSlice` hyperslab; `BlockTable`/`BlockView` public walker surface | ✅ 6 tests | — |
| **D Conformance** | 3×3 encryptor × decryptor matrix over stream-written blocks_v1 fixtures (cross-chromosome mates + zero-length reads; embedded-reference REF_DIFF_V2), byte-identical blobs + index in every cell (`tests/validation/test_m99_blocks_v1_matrix.py`) | ✅ 18/18 cells | — |
| **E Transport guard** | A `.tis` stream of a blocks_v1 per-AU container receives to a file decrypt-in-place cannot restore (the stream does not carry the blocks_v1 sidecars); all three senders now refuse with a clear error | ✅ ×3 | wire extension deferred (own Phase 0) |
| **F Docs** | format-spec §9.1.1, binding decisions §93–§95, CHANGELOG, cross-language-matrix row, this file | ✅ | — |

Restore contract: decrypt-in-place re-encodes each block through the
block writer, replicating the stream writer's sticky qualities
strategy (block 0 auto-tunes, the winner read back from the encoded
stream pins the rest), and appends byte-identical blobs into
recreated channel datasets — the block index is never rewritten.
Encrypt refuses any run whose blobs are not byte-reproducible
(unpersisted writer policy such as a non-default
`ref_diff_slice_bytes`), and REF_DIFF_V2 runs must carry their
reference embedded in `/study/references/`.

Known limits, deliberate: the MS (codec-17) and assembly-graph
per-AU paths stay whole-channel (FDZ1 per-block streaming and graph
channel framing are separable follow-ups; the graph case is a wire
change); the v1.0 encrypted transport cannot carry blocks_v1
containers (senders refuse; carrying the sidecars is a
transport-spec extension with its own Phase 0); external REF_PATH
references are not accepted for restore (the md5 the file records
lives in the deleted blob).

Suite state at handoff: Python 2694 pass 0 fail; ObjC 5283 pass /
3 known-environmental TestM90Final failures; Java 1637 tests 0
failures 18 skipped.

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
