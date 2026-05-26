# Transport Spec — Complete `.tio` Coverage (v0.11)

**Status:** Draft for review
**Date:** 2026-05-25
**Author:** Todd White / The Thalion Initiative
**Scope:** `docs/transport-spec.md` v0.10 → v0.11; Java/Python/ObjC `TransportWriter`+`TransportReader`; `tti-workbench-server` ingest path; cross-language conformance fixtures.

---

## 1. Problem statement

Live testing on 2026-05-25 exposed a silent data-loss bug: uploading a FASTA-reference `.tio` (~105 MB on disk) to the workbench server produced a fully-registered 180-byte server-side container with zero sequence content. The encoder emitted only `STREAM_HEADER` + `END_OF_STREAM` — no payload — because `TransportWriter.writeDataset(SpectralDataset)` only iterates `msRuns()` and `genomicRuns()`. Reference data lives at `dataset.references()` and was never serialised.

This is one instance of a class of bug: **any `.tio` content type that lacks a writer iteration is silently dropped at the transport boundary**. The current `.tis` protocol does not have complete coverage of the `.tio` format.

This spec defines v0.11 of the transport protocol with complete `.tio` coverage and a conformance test architecture designed to catch this class of bug going forward.

## 2. Coverage audit

### 2.1 `.tio` content surface (per `SpectralDataset` public API)

| Accessor | `.tio` location | `.tis` v0.10 coverage |
|---|---|---|
| `featureFlags()` | `/feature_flags/*` | ✅ StreamHeader carries the feature list |
| `title()`, `isaInvestigationId()` | top-level attrs | ✅ StreamHeader |
| `msRuns()` (AcquisitionRun: MS/NMR/Raman/IR/UV-Vis) | `/study/{ms,nmr,raman,ir,uv_vis}_runs/...` | ✅ DatasetHeader + AccessUnit + Chromatogram + Annotation + Provenance + EndOfDataset |
| `genomicRuns()` (GenomicRun) | `/study/genomic_runs/...` | ✅ DatasetHeader + AccessUnit (with M89.1 extension) + BulkMode-V2 blobs + EndOfDataset |
| `references()` (FASTA-encoded refs) | `/study/references/<uri>/chromosomes/...` | **❌ no packet type — dropped silently** |
| `image()` (`MSImage` / vibrational imaging cubes) | `/study/image/...`, `/study/raman_image/...`, etc. | **⚠ partial** — AccessUnit §4.3 has a "MSImagePixel extension" (`spectrum_class == 4`) for per-pixel data, but: (a) no DatasetHeader convention names the image, (b) the cube's m/z axis + grid metadata aren't framed, (c) vibrational/UV-Vis imaging cubes (§7a/§7b in format-spec) have no transport path |
| `identifications()` (mzTab PSMs/peptides/proteins) | `/study/identifications/*` compound dataset | **❌ no packet type — dropped silently** |
| `quantifications()` (mzTab quant rows) | `/study/quantifications/*` compound dataset | **❌ no packet type — dropped silently** |
| `provenanceRecords()` (dataset-level) | `/study/provenance/*` compound dataset | **❌ no packet type — dropped silently** (the `0x06` Provenance packet exists but `writeDataset` only emits it per-run, never for the dataset top-level) |
| `isEncrypted()`, `encryptedAlgorithm()` | `/study/@encrypted` + `/study/encryption/*` | ⚠ `ProtectionMetadata` packet (0x04) carries per-dataset keys but the spec is ambiguous on whether the dataset-level `@encrypted` algorithm name is reproduced |
| Subject / sample metadata | `/study/subjects/*`, `/study/samples/*` (format-spec §11 — present in v1.5+ datasets) | **❌ no packet type — dropped silently** |

### 2.2 Why none of this is in the existing conformance test suite

`java/src/test/java/global/thalion/ttio/transport/TransportConformanceTest.java` (≈220 LOC, 14 tests) round-trips only `buildDataset(dir, runs, spectra, channels)` outputs — a synthetic builder that produces **MS acquisition runs only**. No references, no images, no identifications, no quantifications, no genomic runs at the top level (genomic round-trip is exercised by separate M86/M89 test files, but in isolation).

The cross-language conformance pairs (`python/tests/test_transport_conformance.py` and parity matrix) use the same fixture shape: MS-only or genomic-only. The "55/55 pass" headline from M81 conformance was real but covered a narrow slice of the format surface.

**The class of bug we missed:** *"if accessor X is not iterated by `writeDataset`, then content X is silently dropped on round-trip — and the round-trip test still passes because the reader also silently produces empty X."*

Two reading sites + two writing sites, both blind to the gap, equals an untestable surface unless the test corpus exercises it explicitly. The next conformance suite (§7 of this spec) is built around enumerating every accessor and requiring round-trip equality for each.

## 3. Design principles

1. **Coverage:** every public accessor on `SpectralDataset` MUST have a defined transport representation. New accessors added to `SpectralDataset` MUST be accompanied by a new packet type (or extension to an existing one) before they ship.
2. **Backward compat:** v0.10 readers MUST be able to read v0.11 streams that don't contain new packet types. A v0.10 reader encountering a v0.11-only packet MUST skip it (forward-compatible via the length-prefixed wire frame) without failing.
3. **Self-describing:** every payload section carries its own length and type. No inferring section boundaries from cross-packet state.
4. **Filterable where it matters:** large datasets (references with thousands of chromosomes, image cubes with millions of pixels) must support selective access via per-record packets, not monolithic blobs. Tabular metadata (identifications, quantifications, subjects, samples) can be batched into single packets because they're small.
5. **Cross-language parity is non-negotiable.** Java + Python + ObjC writers and readers ship together. No language-specific extensions.

## 4. New packet types

Wire byte allocations are appended to the existing `PacketType` enum (0x01–0x0B, 0xFF reserved). New range: `0x10–0x2F` for v0.11 additions, leaving 0x0C–0x0F free for any v0.10.x emergency additions.

### 4.1 `REFERENCE_GROUP_HEADER` (0x10)

One per `ReferenceImport` in the dataset. Declares an `(reference_uri, chromosome_count, total_bases, md5_hex)` tuple. Subsequent `REFERENCE_CHROMOSOME` packets carry the actual contig data, terminated by `END_OF_REFERENCE_GROUP`.

Payload layout:
```
uint16 uri_length
bytes  uri_utf8[uri_length]
uint32 chromosome_count
uint64 total_bases
bytes  md5_hex[32]   // ASCII hex; matches format-spec §11 @md5 attr
```

### 4.2 `REFERENCE_CHROMOSOME` (0x11)

One per contig within a reference group. Order MUST match the sorted-name order used on disk (format-spec §11).

Payload layout:
```
uint16 name_length
bytes  name_utf8[name_length]
uint64 length          // bases (also encoded as the length attribute on disk)
uint8  encoding        // 0 = uncompressed UINT8, 1 = ZLIB-compressed
uint32 payload_length
bytes  payload[payload_length]   // raw bases or zlib stream
```

The encoding byte mirrors the format-spec's Perf-A decision (skip ZLIB below 4 KB) and lets the writer choose per chromosome. Reader handles both.

### 4.3 `END_OF_REFERENCE_GROUP` (0x12)

Terminator; payload is a single `uint32 chromosome_count_seen` so the reader can assert against the header.

### 4.4 `IMAGE_HEADER` (0x13)

One per `MSImage` / vibrational / UV-Vis imaging cube (format-spec §7, §7a, §7b). Declares grid + axis metadata.

Payload layout:
```
uint8  modality       // 0=MS, 1=Raman, 2=IR, 3=UV-Vis (matches AcquisitionMode ordinals for imaging modes)
uint32 width
uint32 height
uint32 spectrum_bins  // per-pixel intensity samples
double pixel_size_x
double pixel_size_y
uint8  scan_pattern   // 0=flyback, 1=meander, 2=random
uint8  axis_kind      // 0=mz, 1=wavenumber, 2=wavelength, 3=ppm
uint32 axis_length
double axis[axis_length]   // shared axis (continuous mode) or zeroes (processed mode)
uint8  is_continuous  // 0/1; if 0, each pixel carries its own axis
uint16 title_length
bytes  title_utf8[title_length]
uint16 isa_id_length
bytes  isa_id_utf8[isa_id_length]
```

### 4.5 `IMAGE_PIXEL` (0x14)

One per pixel. For continuous-mode cubes, only intensities. For processed-mode, intensities + per-pixel axis.

Payload layout (continuous mode):
```
uint32 x
uint32 y
uint8  precision      // 0=float32, 1=float64
uint8  compression    // 0=none, 1=zstd, 2=zlib
uint32 payload_length
bytes  intensities[payload_length]
```

Processed-mode adds `uint32 axis_length` + `bytes axis_payload` after `intensities`. The `IMAGE_HEADER.is_continuous == 0` toggles which shape readers expect.

### 4.6 `END_OF_IMAGE` (0x15)

Payload: `uint32 pixel_count_seen` for cross-check.

### 4.7 `IDENTIFICATIONS_TABLE` (0x16)

Single packet carrying the full `identifications` compound dataset as a length-prefixed **Apache Arrow IPC stream**.

Payload layout:
```
uint32 arrow_ipc_length
bytes  arrow_ipc[arrow_ipc_length]   // a self-describing Arrow IPC stream
                                      // (schema message + record-batch messages)
```

The Arrow IPC stream is the canonical Arrow inter-process format
(magic `ARROW1` + schema flatbuffer + record-batch flatbuffers + EOS).
It carries its own schema, dictionary encoding, and null bitmaps; no
TLV envelope on top is needed. Writers MUST emit one IPC stream per
packet covering all rows of that table.

### 4.8 `QUANTIFICATIONS_TABLE` (0x17)

Identical wire shape to `IDENTIFICATIONS_TABLE` (Arrow IPC stream),
distinct packet type so receivers can dispatch without parsing the
payload first.

### 4.9 `DATASET_PROVENANCE` (0x18)

Distinct from the per-run `PROVENANCE` packet (0x06). Carries the dataset-level provenance chain (format-spec §6.3).

Payload layout (mirrors per-run PROVENANCE structure):
```
uint32 record_count
// Per record (already defined in v0.10 §4.6, reused verbatim):
  int64  timestamp_unix
  uint16 software_length;  bytes software[]
  uint16 parameters_length; bytes parameters_json[]
  uint16 input_refs_length; bytes input_refs_csv[]
  uint16 output_refs_length; bytes output_refs_csv[]
```

### 4.10 `SUBJECT_METADATA` (0x19) and `SAMPLE_METADATA` (0x1A)

For format-spec §11 subject/sample groups. Each is a single packet
carrying the table as an Arrow IPC stream (same wire shape as 0x16
and 0x17). Servers ingesting these MUST write them into the on-disk
`/study/subjects/*` and `/study/samples/*` groups.

### 4.11 `ENCRYPTION_ALGORITHM` (0x1B)

Carries the dataset-level `@encrypted` algorithm name when present, so `isEncrypted()` round-trips correctly. Single packet, payload is just a length-prefixed UTF-8 string. Per-AU `ProtectionMetadata` (0x04) continues to carry the per-key material.

## 5. Ordering rules (additions to v0.10 §5)

After `StreamHeader`, before any `DatasetHeader` / `AccessUnit`:

1. Zero or more `ENCRYPTION_ALGORITHM` packets (dataset-level).
2. Zero or more `DATASET_PROVENANCE` packets.
3. Zero or more `SUBJECT_METADATA` and `SAMPLE_METADATA` packets.
4. Zero or more reference groups (`REFERENCE_GROUP_HEADER` → N × `REFERENCE_CHROMOSOME` → `END_OF_REFERENCE_GROUP`).
5. Zero or more image cubes (`IMAGE_HEADER` → N × `IMAGE_PIXEL` → `END_OF_IMAGE`).
6. Zero or more tabular metadata packets (`IDENTIFICATIONS_TABLE`, `QUANTIFICATIONS_TABLE`).
7. Then the existing v0.10 run sequences (DatasetHeader + AUs + Chromatograms + Annotations + per-run Provenance + EndOfDataset).
8. `EndOfStream` last.

Sections 1–6 are all optional. A reference-only `.tio` produces sections 1 (if encrypted) + 4 + 8.

## 6. Backward compatibility

Existing v0.10 readers (Java, Python, ObjC, workbench-server) MUST be updated to **skip unknown packet types gracefully** rather than fail. The 24-byte packet header includes `payload_length`, so a skipping reader knows how many bytes to consume even when the type byte is unknown to it.

v0.10 writer remains the default until v0.11 is rolled out to all three language SDKs + the workbench server. A `StreamHeader` feature flag `"transport_v0_11"` is set when any v0.11-only packet is present in the stream; readers that don't understand v0.11 reject such streams with a clear error message ("transport stream requires v0.11 transport-spec; this reader is v0.10").

## 7. Conformance test architecture

**The existing conformance suite is the root cause we missed this.** Fix: rebuild the conformance harness around **accessor-level coverage**, not synthetic-builder happy-paths.

### 7.1 The accessor matrix test

A single test method, parameterised over every public accessor on `SpectralDataset`:

```java
@ParameterizedTest
@MethodSource("everyDatasetAccessor")
void roundTripPreservesAccessor(AccessorSpec accessor) throws Exception {
    Path src = makeFixtureWith(accessor);          // produces a .tio with ONLY this accessor populated
    Path tis = tioToTis(src);
    Path rt  = tisToTio(tis);
    accessor.assertContentEquals(src, rt);
}
```

`AccessorSpec` enumerates: `featureFlags`, `title`, `isaInvestigationId`, `msRuns`, `genomicRuns`, `references`, `image`, `identifications`, `quantifications`, `provenanceRecords`, `encryptedAlgorithm`, `subjects`, `samples`. Adding a new accessor to `SpectralDataset` triggers a test compile error (the enum must be extended), which forces the transport coverage decision before the accessor ships.

### 7.2 Cross-modality matrix

A second test exercises **all combinations** of two accessors populated:

```java
@ParameterizedTest
@MethodSource("everyAccessorPair")
void roundTripPreservesPair(AccessorSpec a, AccessorSpec b) ...
```

Catches the class of bug where two writers' iteration orders conflict (e.g., ProvenanceRecord write order changes based on whether references are present).

### 7.3 Coverage-gap watchdog

A meta-test that asserts the **size of the encoded `.tis` is proportional to the source `.tio`'s data content**:

```java
long sourceDataBytes = countActualPayloadBytes(src);   // sum of dataset content
long tisSize = Files.size(tis);
assertThat(tisSize).isGreaterThan(sourceDataBytes / 100); // sanity floor
```

If source is 105 MB and `.tis` is 180 bytes, this fires immediately. Crude but catches *every* future "writer silently drops X" bug.

### 7.4 Cross-language parity

Once Java reaches v0.11 conformance, the same fixture suite drives Python (`pytest python/tests/test_transport_conformance.py`) and ObjC (`objc/Tests/TTIOTransportConformanceTest.m`). The CI workflow gates on all three passing.

### 7.5 Test-corpus expansion

New shared fixtures (under `java/src/test/resources/ttio/fixtures/`):

- `reference_only.tio` — single `ReferenceImport`, 3 contigs, ~10 KB total
- `multi_reference.tio` — 2 ReferenceImports, mixed contig sizes (including <4 KB to exercise Perf A's contiguous-uncompressed path)
- `image_ms_continuous.tio` — small 4×4 MSImage cube
- `image_raman.tio` — vibrational imaging cube (format-spec §7a)
- `identifications_only.tio` — mzTab-derived
- `quantifications_only.tio`
- `everything.tio` — fixture containing one of every accessor, used as the smoke-test target

## 8. Phased rollout

| Stage | Scope | Acceptance |
|---|---|---|
| **0** | Add new packet types (0x10–0x1B) to `PacketType` enum in all three languages, no writer/reader logic yet. Update `transport-spec.md` with §4.13–§4.23 covering the new types. Land the conformance test harness in §7 with all tests marked `@Disabled("v0.11 — pending writer")`. | All three SDKs build; transport-spec.md captures v0.11; tests compile but are skipped. |
| **1** | Java writer: `TransportWriter.writeDataset` emits the new packet types. Java reader: `TransportReader.materializeTo` consumes them. Enable §7.1 + §7.3 tests for Java. | Java round-trip green for every accessor. |
| **2** | Python writer + reader parity. Enable §7.1 + §7.3 for Python. | Python round-trip green. |
| **3** | ObjC writer + reader parity. Enable §7.1 + §7.3 for ObjC. | ObjC round-trip green. |
| **4** | Cross-language conformance (§7.4) — every fixture round-trips through every language pair. | 13 fixtures × 9 directional pairs = 117 assertions, all green. |
| **5** | `tti-workbench-server` ingest path: handle the new packet types, write them into the on-disk container. End-to-end smoke from tio-browser. | The 105 MB FASTA-reference round-trip succeeds with byte-equality of references. |
| **6** | Format-spec / transport-spec doc passes; `[Unreleased]` → v1.6 release notes; cross-lang library version bump to 1.4.0. | All docs current; semver bump; CHANGELOG entries on both repos. |

## 9. Resolved decisions

- **Q1 — Tabular format:** **Arrow IPC** (0x16, 0x17, 0x19, 0x1A). Industry standard, self-describing schema + dictionary encoding + null bitmaps in one stream, no in-house TLV envelope to maintain across three languages.
- **Q2 — Image pixel rate:** **One packet per pixel** for selective-access consistency with the rest of the protocol. Batched form deferred to v0.12 contingent on profiling evidence.
- **Q3 — Reference bulk mode:** Not in v0.11. Per-chromosome packets already preserve on-disk compressed layout; no bulk-mode equivalent needed.

Resolved 2026-05-25 by the project lead.

## 10. Non-goals

- This spec does NOT introduce new compute on the server (no transcoding, no re-compression, no codec changes).
- It does NOT change any v0.10 packet's wire format. All v0.10 packets remain valid in v0.11 streams.
- It does NOT change `.tio` file format. v0.11 transport reads from existing format-spec v1.5 `.tio` files without modification.
- It does NOT introduce streaming or chunking for tabular packets (identifications/quantifications). If those grow beyond ~100 MB, a v0.12 chunked extension can be added.
