# Phase 2c-T — Transport Bulk-Mode Wire Spec (v2 blob carriage)

**Date:** 2026-05-05
**Status:** APPROVED — supersedes the placeholder at
`docs/superpowers/specs/2026-05-04-phase-2c-T-transport-bulk-mode-placeholder.md`.
**Format spec touch-up:** new §3.2 packet types and a new §4.10 in
`docs/transport-spec.md` (folded in by the Python implementation step).

## 1. Problem and goal

The per-AU genomic transport (transport-spec §4.3.1, GenomicRead
extension) decomposes a `WrittenGenomicRun` into one packet per read.
The receiver reconstructs `WrittenGenomicRun` and calls
`SpectralDataset.write_minimal`, which re-encodes the run's
`mate_info`, `read_names`, and (when applicable) `sequences` channels
via the v2 codecs (`MATE_INLINE_V2 = 13`, `NAME_TOKENIZED_V2 = 15`,
`REF_DIFF_V2 = 14`).

> **Note on the original framing.** The placeholder spec
> (2026-05-04) claimed bulk-mode was needed to preserve the SAM
> sentinels `=` and `""` in `mate_chromosome` byte-for-byte across
> transport. That premise was incorrect: the v2 mate codec
> normalizes those sentinels at **write time**, not transport time.
> Once a `WrittenGenomicRun` is written to disk via the v2 codec,
> the original `=` / `""` distinction is gone — `=` becomes the
> resolved chromosome name and `""` becomes `*`, both stored
> permanently in the codec blob. Per-AU transport doesn't lose
> anything that the source `.tio` still has.
>
> What bulk-mode actually delivers in this codebase:
>
> 1. **Receiver-side performance** — skip the v2 codec encode pass
>    on the receiver. For large runs this is the single most
>    expensive step in `transport_to_file`.
> 2. **Cross-language byte-identity insurance** — if a future
>    Java or ObjC v2 encoder ever drifts byte-wise from Python's
>    encoder, bulk-mode preserves blob byte-identity that per-AU
>    mode would lose.
> 3. **A formal contract** — receivers that opt into the
>    `bulk_mode_v2_blobs` feature flag promise verbatim blob
>    write-out, which is checkable by hashing
>    `mate_info/inline_v2` etc. across source and round-tripped
>    `.tio`.
>
> Within-Python testing confirms the v2 codecs in this
> implementation are deterministic — per-AU and bulk-mode produce
> identical blob bytes today. The bulk-mode surface exists so the
> contract holds even if that determinism property is ever broken.

Per-AU mode remains the wire-format default for live acquisition (no
v2 blobs exist until block-flush). Bulk-mode is a *post-acquisition*
mode that requires v2 blobs already on disk in the source `.tio`.

## 2. Architectural framing

### 2.1 What stays per-AU

Bulk-mode is **additive**. Every per-AU `AccessUnit` (transport-spec
§4.3.1) is still emitted exactly as today, with the per-AU genomic
suffix (chromosome / position / mapq / flags / mate extension) and per-AU
UINT8 string channels (`cigar`, `read_name`, `mate_chromosome`).

Reasons to keep per-AU AUs in bulk-mode:

1. **Selective access still works.** A query with
   `chromosome="chr1", position_min=…` filters AUs identically across
   per-AU and bulk modes. The blob packets carry no filter-key index;
   filtering against them would require partial blob decode (defeating
   the bulk premise).
2. **Index arrays come from AUs.** `chromosomes`, `positions`,
   `mapping_qualities`, `flags`, `offsets`, `lengths` are not
   v2-codec-encoded — they live in `genomic_index/` and are best
   reconstructed from per-AU streams. The per-AU path already does
   this.
3. **Forward compatibility.** A receiver that does not understand the
   new packet types can still produce a correct (if mate-normalized)
   `.tio` by skipping the unknown packets — readers MUST skip
   unrecognised types and continue (transport-spec implicit; made
   explicit in §6 below).

### 2.2 What bulk-mode adds

Three new packet types carry the verbatim v2 blob bytes for one
genomic dataset_id between its DatasetHeader and EndOfDataset:

| Code   | Name                  | Payload §  |
|-------:|-----------------------|------------|
| `0x09` | `BlobV2MateInfo`      | §3.1       |
| `0x0A` | `BlobV2RefDiff`       | §3.2       |
| `0x0B` | `BlobV2NameTok`       | §3.3       |

Plus one stream-level feature flag in the StreamHeader's `features`
list (transport-spec §4.1):

- `bulk_mode_v2_blobs` (without `opt_` prefix, so it is **required**
  per `feature-flags.md` — receivers that cannot honor verbatim blob
  injection MUST refuse the stream).

### 2.3 Mode selection

The sender (writer side) selects mode at stream open:

- **per-AU mode** (default): every behavior matches transport-spec
  v0.10. No blob packets. No `bulk_mode_v2_blobs` feature flag.
- **bulk mode**: the writer probes the source `.tio` for v2 blobs.
  If present, emit them as `BlobV2*` packets between
  `DatasetHeader` and `EndOfDataset` for the matching
  `dataset_id`, and add `bulk_mode_v2_blobs` to the stream's
  features list. Per-AU AccessUnits are still emitted in either
  mode.

CLI flag: `--bulk` on `transport_encode_cli` (and equivalents) to
opt in. When the source is missing v2 blobs (e.g. a per-AU live
acquisition snapshot, or an MS-only `.tio`), `--bulk` is a no-op
warning rather than an error — the encoder degrades gracefully to
per-AU mode and reports through stderr.

## 3. Wire formats

All multi-byte fields little-endian. Strings are UTF-8 with a
`uint16` length prefix (or `uint32` where noted), NOT NUL-terminated.

### 3.1 BlobV2MateInfo (`0x09`)

Carries `<run>/signal_channels/mate_info/inline_v2` and its
adjacent `<run>/signal_channels/mate_info/chrom_names` table
(transport-spec §4.3 layout for genomic runs).

```
dataset_id:           uint16            # matches header.dataset_id
codec_id:             uint8             # MUST be 13 (MATE_INLINE_V2)
n_chrom_names:        uint16            # entries in chrom_names table
chrom_names:          repeated { uint16 len, bytes[len] }
                                        # mate-info chromosome name table,
                                        # in the order written by
                                        # ttio.codecs.mate_info_v2 (sorted
                                        # ascending — see ref impl).
blob_length:          uint32
blob:                 bytes[blob_length]
                                        # the full inline_v2 codec output
                                        # bytes. The blob is opaque to
                                        # transport — only the codec
                                        # decoder dispatches on its
                                        # internals.
```

`dataset_id` MUST equal `header.dataset_id` (sanity check; receivers
SHOULD reject on mismatch).

`codec_id` is fixed at 13 in v1.0 of bulk-mode but is included on
the wire for forward-compat with future mate codecs (and to make
each blob packet self-describing).

### 3.2 BlobV2RefDiff (`0x0A`)

Carries `<run>/signal_channels/sequences/refdiff_v2` for
ref-diff-encoded sequence channels.

```
dataset_id:           uint16            # matches header.dataset_id
codec_id:             uint8             # MUST be 14 (REF_DIFF_V2)
reference_uri_len:    uint16
reference_uri:        bytes[len]        # MUST equal the run's
                                        # /reference_uri attr; receiver
                                        # validates the matching
                                        # reference is embedded under
                                        # /study/references/<uri>/.
blob_length:          uint32
blob:                 bytes[blob_length]
```

If the source `.tio`'s `sequences` channel is plain `uint8` (no
ref-diff was applied — small reads, missing reference, or a
ref-diff opt-out flag), this packet is **not emitted** for that
dataset. The receiver writes `sequences` as an uncompressed
`uint8` dataset reconstructed from the per-AU stream — same as
per-AU mode.

### 3.3 BlobV2NameTok (`0x0B`)

Carries `<run>/signal_channels/read_names/name_tok_v2`.

```
dataset_id:           uint16            # matches header.dataset_id
codec_id:             uint8             # MUST be 15 (NAME_TOKENIZED_V2)
blob_length:          uint32
blob:                 bytes[blob_length]
```

The current `read_names` storage layout is a single uint8 dataset
at `signal_channels/read_names` with `@compression = 15` and the
codec blob inline (no sub-group). The blob packet ships those bytes
verbatim and replays them on the receiver.

## 4. Ordering rules (extends transport-spec §5)

1. `BlobV2*` packets MUST appear AFTER the matching
   `DatasetHeader` (same `dataset_id`) and BEFORE the matching
   `EndOfDataset`.
2. `BlobV2*` packets MAY be interleaved with `AccessUnit` packets.
   They MAY also appear before any AU, after every AU, or anywhere
   in between within their dataset's range.
3. At most ONE `BlobV2MateInfo`, ONE `BlobV2RefDiff`, and ONE
   `BlobV2NameTok` per `dataset_id`. Receivers MUST reject duplicates.
4. `BlobV2*` packets carry `au_sequence = 0`.

## 5. Receiver semantics (extends transport-spec §6.2)

When a `BlobV2*` packet arrives in bulk-mode:

1. The receiver buffers the blob bytes keyed by `(dataset_id, codec_id)`.
2. On `EndOfDataset` for that dataset, the receiver still constructs a
   `WrittenGenomicRun` from the per-AU accumulator (chromosomes,
   positions, mapq, flags, sequences, qualities, cigars, read_names,
   mate_chromosomes, mate_positions, template_lengths).
3. **Verbatim-blob injection.** Before calling `write_minimal` (or
   the language equivalent), the receiver supplies the buffered blobs
   via a new opt-in API (concrete name per language; Python:
   `WrittenGenomicRun.bulk_v2_blobs={"mate_info": (chrom_names, blob),
   "ref_diff": (reference_uri, blob), "name_tok": blob}`). The
   `write_minimal` path detects these and writes them verbatim to the
   matching HDF5 paths, **skipping the v2 encode step**.
4. For any v2 blob NOT supplied (e.g. only mate_info was sent), the
   v2 encoder runs as in per-AU mode for that channel.

The per-AU sequences/qualities/cigar/read_name/mate_chromosome data
collected during step 2 is **discarded** for the channels overridden
in step 3. The mate_chromosomes list collected from per-AU is not
written to disk when `mate_info` blob was supplied; the blob is
authoritative. (This is exactly the source of the byte-verbatim
guarantee — the receiver does not look at the normalized per-AU
mate_chromosome strings when the verbatim blob is in hand.)

### 5.1 Validation

Receivers MUST verify:

- `codec_id` matches the slot in §3.x (13 / 14 / 15).
- For `BlobV2RefDiff`: `reference_uri` matches the source's
  `WrittenGenomicRun.reference_uri` (rejects pasting a ref-diff blob
  encoded against a different reference).
- The chromosome name table inside `BlobV2MateInfo` is consistent
  with the chrom_names list the v2 mate decoder expects (same
  count/order as the source). Receivers do not need to decode the
  blob — but the table is replayed verbatim along with the blob.

## 6. Forward / backward compat

- A v0.10 receiver (no bulk-mode support) sees an unknown packet
  type and unknown feature flag. The flag is mandatory
  (no `opt_` prefix), so the receiver MUST reject the stream rather
  than silently producing a half-decoded `.tio`. This is the right
  default: bulk-mode streams encode information that per-AU mode
  cannot reconstruct, and decoding only the per-AU half would
  produce a `.tio` with mate-normalized blobs labeled "bulk" —
  worse than rejection.
- A bulk-mode receiver MAY consume a per-AU stream — the absence of
  `bulk_mode_v2_blobs` simply means no blob packets arrive, and the
  v2 encoder runs as before.

## 7. Test corpus

The existing m89 fixture
(`python/tests/validation/test_m89_cross_language.py`) uses
`mate_chromosomes=[""] * n_reads`. Bulk-mode tests need a richer
fixture that exercises the byte-verbatim guarantee:

- `mate_chromosomes = ["=", "=", "chr2", "", "chr3"]`
- mixed `mate_positions` (including `-1` for unpaired)
- non-trivial `read_names` (varied widths, dot/colon/underscore mix)
- assertion: `gr.index.mate_chromosomes == source.mate_chromosomes`
  (byte-equality, not just semantic equivalence)

The 3×3 (writer × reader) language matrix MUST pass with bulk-mode
on the same 9 combinations as per-AU. Per-AU 3×3 keeps passing as
the regression baseline (no mate-verbatim assertion — per-AU mode
deliberately does not promise it).

## 8. Implementation plan

### 8.1 Python (Phase 2c-T-1)

1. Add `BLOB_V2_MATE_INFO`, `BLOB_V2_REF_DIFF`, `BLOB_V2_NAME_TOK`
   to `PacketType` in `python/src/ttio/transport/packets.py`.
2. Add packet payload struct helpers (encode/decode) in `packets.py`.
3. Add `TransportWriter._emit_v2_blobs(dataset_id, run)` invoked
   from `_emit_genomic_run_access_units` when bulk-mode is active.
4. Add `TransportReader` blob accumulator + verbatim injection at
   `read_to_dataset` step. Wire into `WrittenGenomicRun.write_minimal`
   via a new `bulk_v2_blobs` kwarg on the run constructor (or on
   `write_minimal` directly — choose whichever has cleaner signature).
5. CLI: `transport_encode_cli --bulk` flag.
6. Tests: `test_m89_cross_language.py` parametrize over per-AU vs
   bulk mode; bulk-mode adds the byte-verbatim mate assertion.

### 8.2 Java (Phase 2c-T-2)

Mirror Python changes in:
- `java/src/main/java/global/thalion/ttio/transport/PacketType.java`
- `java/src/main/java/global/thalion/ttio/transport/TransportWriter.java`
- `java/src/main/java/global/thalion/ttio/transport/TransportReader.java`
- `java/src/main/java/global/thalion/ttio/tools/TransportEncodeCli.java`
- `java/src/main/java/global/thalion/ttio/tools/TransportDecodeCli.java`

### 8.3 ObjC (Phase 2c-T-3)

Mirror in:
- `objc/Source/Transport/TTIOTransportPacket.h` (constants)
- `objc/Source/Transport/TTIOTransportWriter.{h,m}`
- `objc/Source/Transport/TTIOTransportReader.{h,m}`
- `objc/Tools/TtioTransportEncode.m`
- `objc/Tools/TtioTransportDecode.m`

### 8.4 Cross-language verification (Phase 2c-T-4)

Extend `python/tests/validation/test_m89_cross_language.py`:
- Add a `_FIXTURE_BULK` source with non-trivial mate / name fields.
- Parametrize 9-cell matrix over `mode in {"per_au", "bulk"}`.
- Bulk-mode cells assert byte-verbatim mate_chromosome,
  mate_position, template_length, read_name.
- Per-AU cells keep the existing semantic-only assertions.
