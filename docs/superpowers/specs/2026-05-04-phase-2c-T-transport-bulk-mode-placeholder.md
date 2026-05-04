# Phase 2c-T placeholder — transport bulk-mode wire format (carries v2 blobs natively)

**Date:** 2026-05-04
**Status:** PLACEHOLDER — needs brainstorm + full spec before implementation.
**Trigger:** scheduled after Phase 2c lands. User decision 2026-05-04
selected option (b): split off transport from Phase 2c codec removal.

## Problem statement

Phase 2b dropped `opt_disable_inline_mate_info_v2=True` from
`python/src/ttio/transport/codec.py:850`. That kwarg previously
preserved verbatim SAM mate_chromosome sentinels (`=`, `""`) across the
wire by forcing the receiver to write the v1 mate_info layout. With
Phase 2b's removal, the receiver writes v2, which normalises `=` → the
resolved chrom name and `""` → `*`. m89 cross-language transport tests
(in particular the `*-encode_objc-decode` cells) hit this drift.

Phase 2c removes the v1 mate_info layout entirely, so the v1 escape
hatch is permanently unavailable. Phase 2c-T must reconcile.

## Architectural constraints

Transport is **3-language full-stack** (Python + Java + ObjC), each
with TransportWriter / TransportReader / PacketHeader / AccessUnit.

Wire format is **per-AU** (one packet per read) — designed for live
acquisition streaming. v2 codecs are inherently **per-block** (~4096
reads per block).

The v2 normalization happens because the receiver currently:
1. Reads disjoint per-read fields from per-AU packets
2. Reconstructs a full WrittenGenomicRun in memory
3. Calls write_minimal which re-encodes via v2 codec dispatch
4. v2 codec normalises mate_chromosomes during encode

## Design space

### Option (i) bulk-mode wire format (user's chosen direction)

Add a new packet type / mode for non-streaming bulk transfer:
- `BLOB_V2_MATE_INFO` packet type carrying the inline_v2 blob bytes verbatim
- `BLOB_V2_REF_DIFF_SEQUENCES` packet type carrying the refdiff_v2 blob bytes
- `BLOB_V2_NAME_TOK_READ_NAMES` packet type carrying the name_tok_v2 blob bytes
- Per-AU index metadata (offsets, lengths, chromosomes, positions, mapq, flags) still ships per-AU
- Bulk encoder reads the source `.tio`'s v2 blobs from
  `signal_channels/<channel>/{inline_v2|refdiff_v2|name_tok_v2}` and ships verbatim
- Bulk decoder writes the v2 blob bytes back into the target `.tio`'s
  `signal_channels/<channel>/...` without going through v2 encode
- Per-AU streaming mode (live acquisition) continues with current per-AU dispatch + accepts that mate_chromosome normalization may occur

### Option (ii) sender-side pre-normalization

Keep per-AU wire format unchanged. At the SENDER side, before
serializing per-AU, normalize mate_chromosomes the same way v2 would
(`""` → `*`, `=` → resolved chrom name). Receiver writes locally as
v2; v2 codec is a no-op on the already-normalized values.

Smaller change but doesn't solve the broader "per-AU vs blob" tension.

### Option (iii) hybrid

Bulk encoders auto-detect: if source has v2 blobs on disk, use option
(i); if source is v1-style or per-AU streaming, use option (ii). Most
flexible but most code.

User selected: **option (i)** (bulk-mode with native v2 blob carriage).

## Required deliverables (rough)

1. **Spec doc**: extend or replace `docs/transport-spec.md` §3.2 with
   new packet types + bulk-mode protocol.
2. **Python**: new packet types in `transport/packets.py`; sender +
   receiver code in `transport/codec.py`; new bulk-mode CLI flag in
   `transport_encode_cli` / `transport_decode_cli`.
3. **Java**: new `PacketType` enum values; `TransportWriter` /
   `TransportReader` updates; bulk-mode in `TransportEncodeCli` /
   `TransportDecodeCli`.
4. **ObjC**: new packet type constants in `TTIOTransportPacket.h`;
   `TTIOTransportWriter` / `TTIOTransportReader` updates; bulk-mode in
   `TtioTransportEncode` / `TtioTransportDecode` tools.
5. **Cross-language byte-identity verification**: extend or replace
   `python/tests/validation/test_m89_cross_language.py` to exercise
   bulk mode. The 9-cell matrix should now produce byte-identical
   round-trips.
6. **Auto-detect / mode flag**: bulk encoder reads source `.tio`,
   auto-selects per-AU vs bulk-mode based on whether v2 blobs are
   present (always true under v1.0+).

## Estimated work

Multi-session (likely 3-4 sessions):
- Session 1: brainstorm + wire format spec + Python prototype
- Session 2: Java + ObjC ports
- Session 3: cross-language verification + edge cases + docs
- Session 4: review + cleanup

## Resume-ready prompt for Phase 2c-T

> Brainstorm the transport bulk-mode wire format change (Phase 2c-T).
> Read `docs/superpowers/specs/2026-05-04-phase-2c-T-transport-bulk-mode-placeholder.md`
> for context. User selected option (i) — carry v2 blobs natively in
> a new bulk-mode packet type. Produce a full spec, then a phased
> implementation plan.
