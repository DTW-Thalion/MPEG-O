# MPEG-O v0.11 — Vibrational Spectroscopy (Raman + IR)

> **Status (2026-04-21):** M73 implementation complete across all
> three languages, awaiting user sign-off before tagging v0.11.0.
> Four new domain classes per language (RamanSpectrum, IRSpectrum,
> RamanImage, IRImage), JCAMP-DX 5.01 AFFN reader + writer with
> byte-identical cross-language output, cross-language conformance
> harness (6 tests, Python↔Java + Python↔ObjC green), new ObjC CLI
> tool `MpgoJcampDxDump`. Test totals: 1443 ObjC / 695 Python / 307
> Java / 44 cross-language, all green. HDF5 layout documented in
> `docs/format-spec.md` §7a (`raman_image_cube` / `ir_image_cube`
> groups); JCAMP-DX integration documented in
> `docs/vendor-formats.md`.
>
> **Prior (2026-04-20):** v0.10.0 shipped; tag `a609aa9` on commit
> `c9fe137` pushed per user sign-off. Transport codec (M67),
> WebSocket client + server (M68 / M68.5), simulator (M69),
> bidirectional conformance (M70), selective access +
> ProtectionMetadata (M71), per-AU encryption (v1.0 scope — Phases
> A–E). Two pre-existing Thermo-mock ObjC failures remain
> environment-specific.
>
> Prior context: v0.9.0 / v0.9.1 tagged and pushed. Four storage
> providers (HDF5, Memory, SQLite, Zarr v3), seven importers, seven
> exporters (including imzML and mzTab), PQC crypto, integration +
> stress + security test suites.

---

## First Steps

1. `git clone https://github.com/DTW-Thalion/MPEG-O.git && cd MPEG-O && git pull`
2. Read: `ARCHITECTURE.md`, `docs/format-spec.md`, `docs/providers.md`,
   `docs/pqc.md`, `CHANGELOG.md`
3. Verify all three builds:
   ```bash
   cd objc && ./build.sh check
   cd ../python && pip install -e ".[test,import,crypto,zarr]" && pytest
   cd ../java && mvn verify -B
   ```

---

## Binding Decisions — All Prior (1–52) Active, Plus:

53. **Transport format is a binary framing protocol, not a new
    container format.** Transport packets wrap the same logical
    data as the file format — Access Units, metadata, protection
    descriptors — in a self-describing binary frame suitable for
    network delivery and real-time streaming. The file format
    remains the authoritative at-rest representation.
54. **Bidirectional conversion is normative.** Any valid `.mpgo`
    file can be serialized into a transport stream and any valid
    transport stream can be materialized into a `.mpgo` file,
    with zero data loss and bit-identical signal values. This is
    the MPEG-G Part 1 § "Transport and Storage" contract.
55. **Access Unit = one spectrum.** The natural streaming unit for
    LC-MS is a single scan. For NMR, it's a single FID transient.
    For MS imaging, it's a single pixel's spectrum. For timsTOF,
    it's a single PASEF frame. The AU header carries enough
    metadata for compressed-domain filtering (RT, MS level,
    polarity, precursor m/z) without decoding the signal payload.
56. **Transport is provider-agnostic.** The transport codec reads
    from / writes to any storage provider. File → stream iterates
    the provider's SpectrumIndex; stream → file writes through
    the provider's StorageGroup API. The transport layer never
    touches HDF5/SQLite/Zarr directly.
57. **Network layer uses WebSocket.** TCP is too low-level (no
    framing). HTTP chunked transfer works but is unidirectional.
    gRPC adds a protobuf dependency. WebSocket gives bidirectional
    framed messages, works through proxies, and has mature libraries
    in all three languages (Python: `websockets`, Java: `java-websocket`,
    ObjC: raw `CFStream` or `nw_connection`).
58. **Selective access via query parameters on the stream.** The
    server filters AUs before sending them. The client specifies
    RT range, MS level, precursor m/z range, polarity, and
    maximum AU count. This is the htsget equivalent: "give me
    the MS2 spectra matching this precursor from this dataset."
59. **Encrypted transport reuses the file-format protection model.**
    If a dataset is encrypted at rest, transport AUs carry the
    same per-stream encryption. The KEK/DEK envelope travels in
    a ProtectionMetadata packet at stream start. The receiver
    needs the same key to decrypt, whether reading from file or
    stream.

---

## Dependency Graph

```
  M65 (Exporter fixes + v0.9.0 tag)
       |
       v
  M66 (Transport format spec)
       |
       v
  M67 (Transport codec — all three languages)
       |
       +------------------+
       v                  v
  M68 (Network layer    M69 (Acquisition
   WebSocket server)      simulator)
       |                  |
       +--------+---------+
                |
                v
  M70 (Bidirectional conversion + conformance)
       |
       v
  M71 (Selective access + encrypted transport)
       |
       v
  M72 (v0.10.0 release)
```

M65 is prerequisite (clean baseline). M66 is the spec that M67
implements. M68 and M69 are independent once M67 lands. M70
validates the codec. M71 adds query filtering and encryption. M72
releases.

---

## Milestone 65 — Exporter Defect Fixes + v0.9.0 Tag — COMPLETE

Fixes shipped in commits 65c3666 (mzML activation + isolation-window
cvParams, ISA-Tab PUBLICATIONS) and 6b26f2e (nmrML spectrum1D XSD
closure). v0.9.0 tagged at 228eeb5; v0.9.1 follow-up tagged at
fd0c06c carrying the exporter closures plus imzML/mzTab exporters
and Zarr v3 migration.

Historical spec retained below for audit.

### Historical: Milestone 65 — Exporter Defect Fixes + v0.9.0 Tag

**License:** Apache-2.0 (exporters), LGPL-3.0 (tests)

### Fix 1: mzML precursor/activation cvParams

The mzML exporter writes `<precursor>` elements but omits
`<activation>` child elements and some precursor cvParams
(isolation window, selected ion m/z).

**Fix:** In `mpeg_o.exporters.mzml` (Python), `MPGOMzMLWriter` (ObjC),
`MzMLWriter.java`:
- Emit `<activation>` with `MS:1000133` (CID) or appropriate
  dissociation method cvParam from the spectrum's CV annotations
- Emit `MS:1000827` (isolation window target m/z)
- Emit `MS:1000828` / `MS:1000829` (isolation window lower/upper offset)
  when available
- Default to CID when no dissociation method is annotated

### Fix 2: nmrML version attribute

The nmrML exporter emits `version="1.0"` but the nmrML XSD
expects `version="1.0.rc1"` (the current released schema version).

**Fix:** Change the version attribute to match the XSD.

### Fix 3: ISA-Tab PUBLICATIONS section

The ISA-Tab exporter omits the `STUDY PUBLICATIONS` section
from the Investigation file.

**Fix:** Emit the section header and any publication metadata from
the dataset's provenance chain (DOIs, PubMed IDs if present).
If no publications are available, emit the section header with
no rows (valid per ISA-Tab spec).

### Tag

```bash
git tag -a v0.9.0 -m "MPEG-O v0.9.0: integration tests, imzML/mzTab/Waters importers+exporters, stress tests, cross-tool validation, performance optimization"
git push origin v0.9.0
```

### Acceptance

- [ ] mzML export of MS2 spectra includes `<activation>` elements
- [ ] mzML export validates against PSI XSD (the previously xfailed test now passes)
- [ ] nmrML export validates against nmrML XSD
- [ ] ISA-Tab export includes STUDY PUBLICATIONS section
- [ ] All three previously-xfailed tests now pass (remove xfail markers)
- [ ] v0.9.0 tag pushed
- [ ] CHANGELOG.md updated

---

## Milestone 66 — Transport Format Specification

**License:** LGPL-3.0

### `docs/transport-spec.md`

The normative specification of the MPEG-O transport format. Modeled
on MPEG-G ISO/IEC 23092-1 §7 (Transport Format).

### Wire Format

All multi-byte integers are little-endian. All floating-point values
are IEEE 754 little-endian.

```
Transport Stream = PacketHeader Payload PacketHeader Payload ... EOS

PacketHeader (24 bytes, fixed):
  magic:           bytes[2]    = "MO"
  version:         uint8       = 0x01
  packet_type:     uint8       (see below)
  flags:           uint16      (bit 0: encrypted, bit 1: compressed,
                                bit 2: has_checksum)
  dataset_id:      uint16      (identifies the AcquisitionRun)
  au_sequence:     uint32      (monotonically increasing per dataset)
  payload_length:  uint32      (bytes of payload following this header)
  timestamp_ns:    uint64      (nanosecond Unix timestamp of packet creation)

Packet Types:
  0x01  StreamHeader        — format version, dataset group metadata
  0x02  DatasetHeader       — run metadata (acquisition mode, instrument,
                              feature flags, channel names)
  0x03  AccessUnit          — one spectrum's worth of signal data
  0x04  ProtectionMetadata  — KEK info, wrapped DEK, signature pubkey
  0x05  Annotation          — identification/quantification record
  0x06  Provenance          — processing step record
  0x07  Chromatogram        — chromatogram data point batch
  0x08  EndOfDataset        — signals end of a specific dataset_id
  0xFF  EndOfStream         — signals end of the entire transport stream
```

### Access Unit Payload (packet_type = 0x03)

```
AU Payload:
  spectrum_class:     uint8     (0=MassSpectrum, 1=NMRSpectrum, 2=NMR2D,
                                 3=FID, 4=MSImagePixel)
  acquisition_mode:   uint8     (matches MPGOAcquisitionMode enum)
  ms_level:           uint8
  polarity:           uint8     (0=positive, 1=negative, 2=unknown)
  retention_time:     float64   (seconds)
  precursor_mz:       float64   (0.0 if MS1 or NMR)
  precursor_charge:   uint8     (0 if MS1 or NMR)
  ion_mobility:       float64   (0.0 if not applicable)
  base_peak_intensity: float64
  n_channels:         uint8     (number of signal channels following)
  
  For each channel (n_channels times):
    channel_name_len: uint16
    channel_name:     bytes[channel_name_len]  (UTF-8, e.g. "mz", "intensity")
    precision:        uint8     (0=float32, 1=float64, 2=int32, 3=int64, 4=complex128)
    compression:      uint8     (0=none, 1=zlib, 2=lz4, 3=numpress_delta)
    n_elements:       uint32
    data_length:      uint32    (compressed byte length)
    data:             bytes[data_length]

  # MSImagePixel extension (spectrum_class == 4):
  pixel_x:            uint32
  pixel_y:            uint32
  pixel_z:            uint32
```

### StreamHeader Payload (packet_type = 0x01)

```
  format_version_len: uint16
  format_version:     bytes[format_version_len]  (e.g. "1.2")
  title_len:          uint16
  title:              bytes[title_len]
  isa_id_len:         uint16
  isa_investigation:  bytes[isa_id_len]
  n_features:         uint16
  features:           repeated { uint16 len, bytes[len] }  (feature flag strings)
  n_datasets:         uint16   (number of DatasetHeaders to follow)
```

### DatasetHeader Payload (packet_type = 0x02)

```
  dataset_id:         uint16   (matches PacketHeader.dataset_id)
  name_len:           uint16
  name:               bytes[name_len]  (run name, e.g. "run_0001")
  acquisition_mode:   uint8
  spectrum_class_len: uint16
  spectrum_class:     bytes[spectrum_class_len]  (e.g. "MPGOMassSpectrum")
  n_channels:         uint8
  channel_names:      repeated { uint16 len, bytes[len] }
  instrument_json_len: uint32
  instrument_json:    bytes[instrument_json_len]  (InstrumentConfig as JSON)
  expected_au_count:  uint32   (0 if unknown / real-time)
```

### ProtectionMetadata Payload (packet_type = 0x04)

```
  cipher_suite_len:   uint16
  cipher_suite:       bytes[cipher_suite_len]  (e.g. "aes-256-gcm")
  kek_algorithm_len:  uint16
  kek_algorithm:      bytes[kek_algorithm_len] (e.g. "ml-kem-1024")
  wrapped_dek_len:    uint32
  wrapped_dek:        bytes[wrapped_dek_len]
  signature_algo_len: uint16
  signature_algorithm: bytes[signature_algo_len]
  public_key_len:     uint32
  public_key:         bytes[public_key_len]
```

### Checksum

When `flags & 0x04` (has_checksum), the payload is followed by a
4-byte CRC-32C (Castagnoli) checksum of the payload bytes. The
checksum is NOT part of `payload_length`.

### Ordering Rules

1. `StreamHeader` MUST be the first packet.
2. `DatasetHeader` packets MUST precede any `AccessUnit` for that
   `dataset_id`.
3. `ProtectionMetadata` MUST precede any encrypted `AccessUnit`.
4. `AccessUnit` packets for a given `dataset_id` MUST be in
   `au_sequence` order.
5. `AccessUnit` packets from different `dataset_id`s MAY be
   interleaved (multiplexed).
6. `EndOfDataset` MUST follow the last `AccessUnit` for its
   `dataset_id`.
7. `EndOfStream` MUST be the final packet.

### Acceptance

- [ ] `docs/transport-spec.md` committed with full wire format
- [ ] Packet header and all payload formats fully specified
- [ ] Ordering rules documented
- [ ] Bidirectional conversion semantics documented
- [ ] Cross-references to `format-spec.md` for shared types

---

## Milestone 67 — Transport Codec (All Three Languages) — COMPLETE

Landed per-language codecs with round-trip green in each suite:
Python 578 / Java 253 / ObjC 1301. Cross-language byte-level interop
covered via identical CRC-32C known-vector tests and byte-exact
packet layout tests in every language; full cross-language subprocess
round-trip tests live in M70.

Shipped:
- Python: `python/src/mpeg_o/transport/{__init__.py,packets.py,codec.py}`
  + `tests/test_transport_packets.py` + `tests/test_transport_codec.py`.
- ObjC: `objc/Source/Transport/{MPGOTransportPacket,MPGOAccessUnit,
  MPGOTransportWriter,MPGOTransportReader}.{h,m}` + `Tests/TestTransportCodec.m`
  (wired through MPGOTestRunner).
- Java: `java/src/main/java/com/dtwthalion/mpgo/transport/{PacketType,
  PacketHeader,ChannelData,AccessUnit,Crc32c,TransportWriter,
  TransportReader}.java` + `TransportCodecTest.java`.

M67 scope: FLOAT64 / Compression.NONE on the wire; spectrum classes
MassSpectrum + MSImagePixel exercised; ProtectionMetadata /
Annotation / Provenance / Chromatogram packet slots recognized by
the reader but deferred to M70/M71 for full materialization.

Historical spec retained below for audit.

### Historical: Milestone 67 — Transport Codec (All Three Languages)

**License:** LGPL-3.0

Implements the transport serializer (file → stream) and
deserializer (stream → file) in all three languages.

### Python: `mpeg_o.transport`

```python
# mpeg_o/transport/codec.py

class TransportWriter:
    """Serialize an MPEG-O dataset into a transport byte stream."""

    def __init__(self, output: BinaryIO | Path):
        """Write transport packets to a file or stream."""

    def write_dataset(self, dataset: SpectralDataset) -> None:
        """Serialize an entire dataset: StreamHeader + DatasetHeaders
        + AccessUnits + EndOfDataset + EndOfStream."""

    def write_stream_header(self, dataset: SpectralDataset) -> None: ...
    def write_dataset_header(self, run_name: str, run: AcquisitionRun) -> None: ...
    def write_access_unit(self, dataset_id: int, au_seq: int,
                          spectrum: Spectrum, run: AcquisitionRun) -> None: ...
    def write_end_of_dataset(self, dataset_id: int) -> None: ...
    def write_end_of_stream(self) -> None: ...


class TransportReader:
    """Deserialize a transport byte stream into MPEG-O objects."""

    def __init__(self, input: BinaryIO | Path):
        """Read transport packets from a file or stream."""

    def read_to_dataset(self, provider: str = "hdf5",
                        output_path: str | Path | None = None) -> SpectralDataset:
        """Materialize the transport stream into a SpectralDataset
        on the specified provider."""

    def iter_packets(self) -> Iterator[TransportPacket]: ...
    def iter_access_units(self, dataset_id: int | None = None) -> Iterator[AccessUnit]: ...


# Convenience functions
def file_to_transport(mpgo_path: str | Path,
                      output: BinaryIO | Path,
                      *, provider: str = "hdf5") -> None:
    """Convert a .mpgo file to a transport stream."""

def transport_to_file(input: BinaryIO | Path,
                      mpgo_path: str | Path,
                      *, provider: str = "hdf5") -> SpectralDataset:
    """Convert a transport stream to a .mpgo file."""
```

### Python: `mpeg_o/transport/packets.py`

```python
@dataclass(frozen=True)
class PacketHeader:
    magic: bytes          # b"MO"
    version: int          # 1
    packet_type: int      # PacketType enum
    flags: int
    dataset_id: int
    au_sequence: int
    payload_length: int
    timestamp_ns: int

    HEADER_SIZE = 24

    def to_bytes(self) -> bytes: ...

    @classmethod
    def from_bytes(cls, data: bytes) -> "PacketHeader": ...


class PacketType(IntEnum):
    STREAM_HEADER = 0x01
    DATASET_HEADER = 0x02
    ACCESS_UNIT = 0x03
    PROTECTION_METADATA = 0x04
    ANNOTATION = 0x05
    PROVENANCE = 0x06
    CHROMATOGRAM = 0x07
    END_OF_DATASET = 0x08
    END_OF_STREAM = 0xFF


@dataclass
class AccessUnit:
    """One spectrum as a transport-layer object."""
    spectrum_class: int
    acquisition_mode: int
    ms_level: int
    polarity: int
    retention_time: float
    precursor_mz: float
    precursor_charge: int
    ion_mobility: float
    base_peak_intensity: float
    channels: dict[str, ChannelData]  # name → (precision, compression, data)

    # MSImage extension
    pixel_x: int = 0
    pixel_y: int = 0
    pixel_z: int = 0

    def to_bytes(self) -> bytes: ...

    @classmethod
    def from_bytes(cls, data: bytes) -> "AccessUnit": ...
```

### ObjC: `objc/Source/Transport/`

```
MPGOTransportWriter.h / .m
MPGOTransportReader.h / .m
MPGOTransportPacket.h / .m
MPGOAccessUnit.h / .m         (transport-layer AU value class)
```

Same API shape: `MPGOTransportWriter` takes an `NSOutputStream` or
path; `MPGOTransportReader` takes an `NSInputStream` or path.
Binary encoding via direct C struct packing — no intermediate
serialization library.

### Java: `com.dtwthalion.mpgo.transport`

```
TransportWriter.java
TransportReader.java
TransportPacket.java
AccessUnit.java               (transport-layer AU record)
PacketType.java               (enum)
```

Uses `java.nio.ByteBuffer` with `ByteOrder.LITTLE_ENDIAN` for
encoding/decoding.

### Acceptance

- [ ] Python: `file_to_transport("test.mpgo", "test.mots")` produces valid stream
- [ ] Python: `transport_to_file("test.mots", "roundtrip.mpgo")` produces valid file
- [ ] ObjC: same round-trip
- [ ] Java: same round-trip
- [ ] Cross-language: Python-written stream readable by ObjC and Java
- [ ] Cross-language: ObjC-written stream readable by Python and Java
- [ ] AU ordering rules enforced (rejects out-of-order packets)
- [ ] CRC-32C checksums validated when present
- [ ] Empty dataset round-trips (no AUs, just headers)
- [ ] Multi-run dataset round-trips (interleaved AUs from multiple runs)

---

## Milestone 68 — Network Transport Layer (WebSocket Server) — COMPLETE

Shipped Python server + Python/Java/ObjC clients. Test counts:
Python 588 / Java 256 / ObjC 1313.

- **Python** `mpeg_o.transport.server.TransportServer` +
  `mpeg_o.transport.client.TransportClient`: asyncio + `websockets`
  library. Full server-side filtering (ms_level, rt range,
  precursor m/z range, polarity, dataset_id, max_au cap). StreamHeader,
  DatasetHeaders, EndOfDataset, and EndOfStream always emitted so
  filtered streams still produce a valid container skeleton.
  `mpeg_o.tools.transport_server_cli` provides
  `python -m mpeg_o.tools.transport_server_cli <path> --port 0` which
  prints `PORT=<n>` on stdout (used by Java and ObjC tests to spawn a
  server subprocess).
- **Java** `com.dtwthalion.mpgo.transport.TransportClient` via
  `org.java-websocket:Java-WebSocket 1.5.7`. `fetchPackets(filters)`
  collects all records; `streamToFile` materializes through the
  existing offline `TransportReader`. Tests spawn the Python server
  subprocess to validate full + filtered streams and end-to-end
  materialization.
- **ObjC** `MPGOTransportClient` via `libwebsockets-dev` 4.3.3.
  Synchronous blocking API (`fetchPacketsWithFilters:timeout:error:`
  runs a private `lws_service` loop until EndOfStream / close /
  timeout). `opaque_user_data` carries a `(__bridge void *)` back to
  the Objective-C instance in the C callback. Tests spawn the Python
  server subprocess via NSTask; NSTask is allowed to read the
  server's stdout until `PORT=<n>` appears.

Acceptance checklist satisfied in Python (server) and all three
language clients: full stream, ms_level filter, RT-range filter,
precursor m/z filter, combined filters, max_au cap, no-match case,
concurrent clients, graceful shutdown.

Deferred to M71: encrypted transport + selective-access performance
benchmarks. Deferred to follow-up: `wss://` TLS support in the ObjC
client (libwebsockets has SSL but currently untested here).

Historical spec retained below for audit.

### Historical: Milestone 68 — Network Transport Layer (WebSocket Server)

**License:** LGPL-3.0

A WebSocket server that serves MPEG-O transport streams over the
network. Clients connect, optionally specify query filters, and
receive a filtered stream of transport packets.

### Python: `mpeg_o.transport.server`

```python
class TransportServer:
    """WebSocket server that streams MPEG-O data to clients."""

    def __init__(self, dataset: SpectralDataset | Path, *,
                 host: str = "localhost", port: int = 9700):
        """Serve a dataset (or path to one) over WebSocket."""

    async def start(self) -> None:
        """Start the server. Blocks until stopped."""

    async def stop(self) -> None:
        """Graceful shutdown."""
```

### Client

```python
class TransportClient:
    """WebSocket client that receives MPEG-O transport streams."""

    def __init__(self, url: str = "ws://localhost:9700"):
        """Connect to a transport server."""

    async def request_stream(self, *,
                              rt_min: float | None = None,
                              rt_max: float | None = None,
                              ms_level: int | None = None,
                              precursor_mz_min: float | None = None,
                              precursor_mz_max: float | None = None,
                              polarity: int | None = None,
                              max_au: int | None = None,
                              dataset_id: int | None = None,
                              ) -> AsyncIterator[TransportPacket]:
        """Request a filtered stream of transport packets."""

    async def stream_to_file(self, output_path: Path, *,
                              provider: str = "hdf5",
                              **query) -> SpectralDataset:
        """Stream filtered data directly into a .mpgo file."""
```

### Protocol

Client connects via WebSocket. Sends a JSON query message:

```json
{
  "type": "query",
  "filters": {
    "rt_min": 10.0,
    "rt_max": 12.0,
    "ms_level": 2,
    "precursor_mz_min": 500.0,
    "precursor_mz_max": 550.0,
    "max_au": 1000
  }
}
```

Server responds with binary WebSocket frames, each containing one
transport packet. Server applies filters to the SpectrumIndex
before emitting AUs — only matching spectra are serialized and sent.

An empty `filters` object (or omitted) streams the entire dataset.

### Dependencies

- Python: `websockets` (asyncio WebSocket library)
- Java: `org.java-websocket` (Maven: `org.java-websocket:Java-WebSocket`)
- ObjC: `nw_connection` (Network.framework) or raw BSD sockets

### Acceptance

- [ ] Server starts, client connects, receives StreamHeader
- [ ] Unfiltered stream delivers all AUs in order
- [ ] RT-range filter delivers only matching AUs
- [ ] MS-level filter works
- [ ] Precursor m/z filter works
- [ ] Combined filters (AND logic) work
- [ ] `max_au` cap works
- [ ] Client materializes stream to .mpgo file
- [ ] Server handles multiple concurrent clients
- [ ] Graceful shutdown (EndOfStream sent to all clients)

---

## Milestone 69 — Acquisition Simulator — COMPLETE (3-language parity)

Shipped AcquisitionSimulator in all three languages with equivalent
APIs, CLI tools, and deterministic-under-seed semantics.

Counts: Python 596 / Java 261 / ObjC 1324.

**Python** — `mpeg_o.transport.simulator.AcquisitionSimulator`:
synchronous `stream_to_writer(writer)` for offline fixture builds,
async `stream(writer)` for paced real-time output. CLI
`python -m mpeg_o.tools.simulator_cli <output.mots>` with flags
`--scan-rate --duration --ms1-fraction --mz-min --mz-max --n-peaks
--seed`. 8 tests.

**Java** — `com.dtwthalion.mpgo.transport.AcquisitionSimulator`:
`streamToWriter(writer)` plus `streamPaced(writer)` (blocking
Thread.sleep pacing; lives on the caller's thread). CLI
`java -cp <classpath> com.dtwthalion.mpgo.tools.SimulatorCli
<output.mots> ...`. 5 JUnit tests.

**ObjC** — `MPGOAcquisitionSimulator` in
`objc/Source/Transport/`: `streamToWriter:error:` + paced variant.
Uses POSIX `drand48_r` for reentrant deterministic RNG. CLI
`MpgoSimulator` at `objc/Tools/` (new binary wired via
`MpgoSimulator_OBJC_FILES` in `Tools/GNUmakefile`). 11 PASS
assertions via `TestAcquisitionSimulator.m`.

All three CLIs share flag names (`--scan-rate --duration
--ms1-fraction --mz-min --mz-max --n-peaks --seed`) so scripts can
switch between them transparently. Cross-language byte-identity
under the same seed is NOT guaranteed (each language's RNG
differs); within-language determinism IS guaranteed.

**Known parity gap inherited from M68**: live streaming
(simulator → WebSocket server → clients) is Python-only because
Java and ObjC do not yet ship TransportServer. Each language's
simulator is self-contained for the offline-fixture use case
(simulator → .mots file → TransportReader → .mpgo). M68.5
follow-up will add Java + ObjC TransportServer to close the
live-streaming gap; tracked as a parity backfill in the Deferred
section.

Historical spec retained below for audit.

### Historical: Milestone 69 — Acquisition Simulator

**License:** LGPL-3.0

A mock instrument that produces transport packets in real-time,
simulating a live LC-MS acquisition. Used for testing real-time
streaming without a physical instrument.

### Python: `mpeg_o.transport.simulator`

```python
class AcquisitionSimulator:
    """Simulates an LC-MS instrument producing spectra in real-time."""

    def __init__(self, *,
                 scan_rate: float = 10.0,    # scans per second
                 duration: float = 60.0,     # total run time in seconds
                 ms1_fraction: float = 0.3,  # fraction of MS1 vs MS2
                 mz_range: tuple[float, float] = (100.0, 2000.0),
                 n_peaks: int = 200,         # avg peaks per spectrum
                 seed: int = 42):
        """Configure the simulator."""

    async def stream(self, output: TransportWriter) -> None:
        """Emit transport packets at the configured scan rate.
        Blocks for `duration` seconds, producing spectra in real-time."""

    def stream_to_server(self, server: TransportServer) -> None:
        """Feed the simulator into a running server so clients
        receive live data."""
```

The simulator produces:
1. `StreamHeader` packet at t=0
2. `DatasetHeader` packet with `expected_au_count=0` (real-time)
3. `AccessUnit` packets at `scan_rate` Hz, with realistic:
   - Monotonically increasing retention times
   - Alternating MS1/MS2 scans based on `ms1_fraction`
   - MS2 precursors drawn from MS1 base peaks (data-dependent)
   - Random but realistic m/z and intensity distributions
4. `EndOfDataset` + `EndOfStream` at t=duration

### CLI Tool

```bash
# Start a simulator serving on WebSocket
python -m mpeg_o.transport.simulator --scan-rate 10 --duration 60 --port 9700

# Client connects and saves to file
python -m mpeg_o.transport.client ws://localhost:9700 --output live.mpgo
```

### Acceptance

- [ ] Simulator produces packets at configured scan rate (±10%)
- [ ] RT values are monotonically increasing
- [ ] MS2 precursors reference realistic MS1 peaks
- [ ] Client receives and materializes a valid .mpgo file
- [ ] Simulator + server + client pipeline works end-to-end
- [ ] Deterministic output with seed (reproducible for tests)

---

## Milestone 70 — Bidirectional Conversion Conformance — COMPLETE (3-language parity)

Shipped encode/decode CLIs + conformance tests in all three
languages plus cross-language subprocess tests. Counts:
Python 606 / Java 270 / ObjC 1339.

**Encode/decode CLIs (new):**
- Python: `python -m mpeg_o.tools.transport_encode_cli <in.mpgo> <out.mots>`
  and `python -m mpeg_o.tools.transport_decode_cli`.
- Java: `com.dtwthalion.mpgo.tools.TransportEncodeCli` /
  `TransportDecodeCli`.
- ObjC: `MpgoTransportEncode` / `MpgoTransportDecode` in
  `objc/Tools/`.

**In-language conformance (4 tests each):**
- Single-run round-trip, multi-run round-trip, large-spectra
  round-trip, CRC-32C-checksummed round-trip. Every signal sample
  compared bit-for-bit; RT + precursor_mz compared to 1e-12.
- Python: `tests/test_transport_conformance.py`.
- Java: `TransportConformanceTest.java`.
- ObjC: `TestTransportConformance.m`.

**Cross-language conformance (Python drives, 6 tests):**
- Python ↔ Java encode/decode exchange (both directions).
- Python ↔ ObjC encode/decode exchange (both directions).
- Java ↔ ObjC encode/decode exchange (Python orchestrates both
  CLIs, verifies signal equality).
- Tests skip automatically when `mvn compile` or `./build.sh`
  has not been run — no hard dependency on all three toolchains.

**Scope restrictions** (deferred to M71 as planned):
- Compressed channel wire format (zlib / lz4 / numpress-delta) is
  still FLOAT64 + NONE only. All in-language tests exercise the
  uncompressed path; codec preservation follows M71.
- Encrypted / signed dataset round-trips are M71 scope.
- Bruker ion-mobility and MSImage-pixel round-trips: AU supports
  the fields, but importer-specific integration tests land with
  the M71 selective-access work.

Historical spec retained below for audit.

### Historical: Milestone 70 — Bidirectional Conversion Conformance

**License:** LGPL-3.0

The acid test: file ↔ transport ↔ file round-trip produces
bit-identical signal data.

### Tests

```python
class TestBidirectionalConversion:

    @pytest.mark.parametrize("provider", ["hdf5", "memory", "sqlite", "zarr"])
    def test_file_to_transport_to_file(self, provider, bsa_fixture, tmp_path):
        """BSA .mpgo → transport stream → .mpgo on provider → compare"""
        # Every spectrum: m/z, intensity within float64 epsilon
        # Identifications, quantifications, provenance: exact match
        # Feature flags: exact match
        # Instrument config: exact match

    def test_multirun_interleaved(self, multimodal_fixture, tmp_path):
        """MS + NMR dataset → transport (interleaved) → file → compare"""

    def test_msimage_pixel_roundtrip(self, imzml_fixture, tmp_path):
        """MSImage dataset → transport (pixel AUs) → file → compare"""

    def test_bruker_ion_mobility_roundtrip(self, bruker_fixture, tmp_path):
        """Bruker dataset with ion mobility → transport → file → compare"""

    def test_encrypted_dataset_roundtrip(self, encrypted_fixture, tmp_path):
        """Encrypted dataset → transport (with ProtectionMetadata) → file → decrypt → compare"""

    def test_signed_dataset_roundtrip(self, signed_fixture, tmp_path):
        """Signed dataset → transport → file → verify signature"""

    @pytest.mark.parametrize("codec", ["none", "zlib", "lz4", "numpress_delta"])
    def test_codec_preservation(self, codec, tmp_path):
        """Compression codec preserved through transport round-trip"""
```

### Cross-Language Conformance

```python
class TestCrossLanguageTransport:

    def test_python_stream_readable_by_java(self, bsa_fixture, tmp_path):
        """Python writes transport → Java reads → verify"""

    def test_python_stream_readable_by_objc(self, bsa_fixture, tmp_path):
        """Python writes transport → ObjC reads → verify"""

    def test_java_stream_readable_by_python(self, bsa_fixture, tmp_path):
        """Java writes transport → Python reads → verify"""

    def test_objc_stream_readable_by_python(self, bsa_fixture, tmp_path):
        """ObjC writes transport → Python reads → verify"""
```

Uses the existing cross-language subprocess pattern: Python test
invokes `java -jar mpgo-tools.jar transport-encode ...` and
`objc/Tools/MpgoTransportEncode ...` then reads the output.

### Acceptance

- [ ] BSA round-trip: all values within float64 epsilon
- [ ] Multi-run interleaved: both runs reconstructed correctly
- [ ] MSImage pixel round-trip: spatial coordinates + spectral data
- [ ] Ion mobility channel preserved through round-trip
- [ ] Encrypted dataset: ProtectionMetadata transmitted, decryptable after
- [ ] Signed dataset: signature verifiable after round-trip
- [ ] All codecs preserved (none, zlib, lz4, numpress_delta)
- [ ] Cross-language: 4 exchange tests pass

---

## Milestone 71 — Selective Access + Encrypted Transport — COMPLETE (3-language parity)

Shipped selective-access performance tests and ProtectionMetadata
packet wire format across all three languages. Counts: Python 617
/ Java 279 / ObjC 1359.

**Selective access** (6 tests × 3 langs = 18 tests):
- 600-scan fixture spanning RT [0, 60s] with alternating MS1/MS2.
- `rt_min=10, rt_max=12` delivers <5% of AUs (the htsget
  contract from `docs/transport-spec.md` §7).
- `ms_level=2` halves the stream (exactly 300 AUs on the 600-scan
  fixture).
- Combined `rt + ms_level` produces the intersection (~50% of
  rt-only); `max_au=100` caps at exactly 100 AUs with
  EndOfStream intact; impossible filter (ms_level=99) yields
  skeleton-only (StreamHeader / DatasetHeader / EndOfDataset /
  EndOfStream, zero AUs).

**ProtectionMetadata packet** (wire round-trip, 3 langs):
- Python helpers in `tests/test_transport_selective_access.py`;
  Java `com.dtwthalion.mpgo.transport.ProtectionMetadata`;
  ObjC `MPGOProtectionMetadata` (`objc/Source/Transport/`).
- Tests exercise the AES-256-GCM + RSA-OAEP profile and the
  PQC profile (ML-KEM-1024 + ML-DSA-87 with 1568-byte
  wrapped_dek + 2592-byte public_key).
- `PacketFlag.ENCRYPTED` travels on the AU packet header;
  encode/decode round-trip verified in every language,
  composable with `HAS_CHECKSUM`.

**Follow-ups (v1.0 scope — shipped in v0.10.0 / remaining)**:

- [x] **Full encrypted round-trip integration — SHIPPED.** The v1.0
  design pass became `docs/transport-encryption-design.md`; the
  adopted path is option (a), per-AU encryption. Ships as
  `opt_per_au_encryption` (and optional `opt_encrypted_au_headers`)
  with a new `<channel>_segments` / `au_header_segments` VL_BYTES
  compound layout (see `docs/format-spec.md` §9.1). Each spectrum
  is a separate AES-256-GCM op with fresh IV and AAD bound to
  `(dataset_id, au_sequence, channel_name | "header" | "pixel")`;
  ciphertext bytes pass through the transport unmodified. Cross-
  language conformance harness (`test_per_au_cross_language.py`)
  drives `per_au_cli` in all three languages via subprocess and
  byte-compares a canonical "MPAD" decryption dump — 38/38
  combinations green.
- [ ] LZ4 and Numpress-delta wire codecs. ZLIB landed in M71.5
  (opt-in `use_compression=True` on the writer, auto-handled
  on read). The remaining two follow the same pattern but
  need the Python + Java + ObjC codec modules wired through.
  Still deferred — not blocking for v0.10.0 and the opt-in wire
  mechanism (flag bit 1 `COMPRESSED`) is already reserved.
- [ ] Bruker ion-mobility importer-specific integration. Still
  deferred.

Historical spec retained below for audit.

### Historical: Milestone 71 — Selective Access + Encrypted Transport

**License:** LGPL-3.0

### Selective Access

Extend the network server to support query-filtered streaming
with performance measurements.

```python
class TestSelectiveAccess:

    def test_rt_range_filter_reduces_transfer(self, large_fixture, tmp_path):
        """Request RT 10-12 from 60-min run → <5% of AUs transferred"""

    def test_ms2_only_filter(self, large_fixture, tmp_path):
        """Request ms_level=2 → only MS2 AUs delivered"""

    def test_precursor_filter(self, large_fixture, tmp_path):
        """Request precursor 500-550 m/z → matching MS2 AUs only"""

    def test_combined_filters(self, large_fixture, tmp_path):
        """RT + MS level + precursor → intersection"""

    def test_max_au_cap(self, large_fixture, tmp_path):
        """max_au=100 → exactly 100 AUs delivered + EndOfStream"""

    def test_empty_filter_returns_all(self, fixture, tmp_path):
        """No filters → full stream"""

    def test_no_matches_returns_empty(self, fixture, tmp_path):
        """Impossible filter → StreamHeader + EndOfStream only"""
```

### Encrypted Transport

If the source dataset is encrypted, the transport stream preserves
the encryption:

1. `ProtectionMetadata` packet emitted before encrypted AUs
2. `AccessUnit` payloads for encrypted channels carry ciphertext
3. The receiver stores the encrypted data and ProtectionMetadata;
   decryption happens after materialization, using the same key
   management as the file format

```python
class TestEncryptedTransport:

    def test_encrypted_stream_carries_protection_packet(self, encrypted_fixture):
        """ProtectionMetadata packet present in stream"""

    def test_encrypted_au_not_readable_without_key(self, encrypted_fixture, tmp_path):
        """Materialize encrypted stream → intensity not readable without key"""

    def test_encrypted_au_decryptable_with_key(self, encrypted_fixture, tmp_path):
        """Materialize → decrypt with correct key → values match original"""

    def test_pqc_encrypted_transport(self, pqc_fixture, tmp_path):
        """ML-KEM-1024 encrypted dataset → transport → file → decrypt"""
```

### Acceptance

- [ ] RT filter reduces AU count to expected subset
- [ ] MS level filter works
- [ ] Precursor filter works
- [ ] Combined filters produce intersection
- [ ] max_au cap enforced
- [ ] Encrypted transport carries ProtectionMetadata
- [ ] Encrypted AUs decryptable after materialization
- [ ] PQC-encrypted transport round-trips correctly
- [ ] Selective access on encrypted dataset works (filter on unencrypted AU headers)

---

## Milestone 72 — v0.10.0 Release — SHIPPED

**Deliverables**

- [x] `docs/transport-spec.md` — normative transport format specification
- [x] `docs/transport-encryption-design.md` — per-AU encryption
      design (promoted to SHIPPED status 2026-04-20)
- [x] Updated `ARCHITECTURE.md` — v0.10 implementation counts,
      transport section, per-AU encryption narrative
- [x] Updated `README.md` — v0.10.0 capabilities, doc links,
      cross-language harness mention
- [x] Updated `WORKPLAN.md` — M66–M72 + v1.0 encryption acceptance
      checkboxes
- [x] Updated `CHANGELOG.md` with v0.10.0 entry
- [x] CI: transport codec tests + bidirectional conversion +
      cross-language conformance (38 cells)
- [x] Tag v0.10.0 pushed as `a609aa9` on commit `c9fe137` (2026-04-20)

### Acceptance

- [x] All three languages green (1430 ObjC / 682 Python / 298 Java)
- [x] Transport codec round-trip passes in all three languages (M70)
- [x] Cross-language transport exchange passes (M70 + the per-AU
      cross-language harness, 38/38 combinations)
- [x] Network server/client functional (M68 / M68.5)
- [x] Acquisition simulator produces valid stream (M69)
- [x] Selective access reduces transfer size (M71 `AUFilter`)
- [x] Encrypted transport works (v1.0 per-AU encryption Phases D, E)
- [x] Bidirectional conversion is bit-identical for signal data
- [x] v0.1–v0.9 backward compat preserved (file format unchanged;
      per-AU encryption is additive and feature-flagged)
- [x] Tag pushed (`v0.10.0` → `a609aa9` on commit `c9fe137`)

---

## v1.0 Per-AU Encryption — SHIPPED in v0.10.0 (2026-04-20)

Design: `docs/transport-encryption-design.md`; on-disk layout:
`docs/format-spec.md` §9.1; wire semantics: `docs/transport-spec.md`
§4.3 and §6.

**Phases completed (all three languages):**

- **A** — Per-AU primitives: AAD helpers, `ChannelSegment` /
  `HeaderSegment` / `AUHeaderPlaintext` records, encrypt /
  decrypt channel + header segments with AAD binding.
- **B** — `VL_BYTES` `CompoundField.Kind` on the provider
  abstraction; HDF5 provider wiring. Java uses `NativeBytesPool`
  backed by `sun.misc.Unsafe` to pack `hvl_t` slots (JHI5 1.10
  doesn't marshal VL-in-compound directly). SQLite / Zarr fail
  loud at the compound-write boundary.
- **C** — File-level `encrypt_per_au` / `decrypt_per_au`
  orchestrator via `StorageProvider`; rewrites `<channel>_values`
  to `<channel>_segments` + optional `au_header_segments`,
  drops plaintext.
- **D** — `EncryptedTransport` writer + reader; AU packets carry
  `FLAG_ENCRYPTED` (+ optional `FLAG_ENCRYPTED_HEADER`); ciphertext
  passes through the wire unmodified.
- **E** — Cross-language conformance harness; `per_au_cli` /
  `PerAUCli` / `MpgoPerAU` expose `{encrypt, decrypt, send, recv,
  transcode}`; `decrypt` emits a canonical "MPAD" binary dump for
  byte-level cross-language comparison. 38/38 combinations green.

**Tooling:**

- `transcode` subcommand handles plaintext → per-AU and
  per-AU → per-AU (with optional `--rekey` for DEK rotation).
  v0.x `opt_dataset_encryption` files fail loud with a migration
  hint directing users to decrypt via v0.x `SpectralDataset.decrypt()`
  first.

**Durability fix:** Java's `Hdf5File.close()` now calls `H5Fflush`
before `H5Fclose`. Without the explicit flush, writes to a Python-
created h5py file silently didn't persist (H5Fclose skipped the
flush when child group handles leaked via unclosed adapters even
though TWR closed the top-level handles in order).

---

## File Extension

Transport streams use the `.mots` extension (**M**PEG-**O**
**T**ransport **S**tream). This parallels MPEG-G's `.mgg` (file)
vs `.mggts` (transport) convention.

---

## Known Gotchas

**Inherited (1–52):** All prior gotchas active.

**New (v0.10):**

53. **Endianness.** The transport format is little-endian throughout.
    All three languages must use explicit LE encoding, not native
    byte order. Python: `struct.pack('<...')`. Java:
    `ByteBuffer.order(ByteOrder.LITTLE_ENDIAN)`. ObjC: direct
    byte manipulation (x86_64 and ARM64 are both LE, but be
    explicit).

54. **WebSocket frame size limits.** WebSocket frames can be up to
    2^63 bytes but intermediary proxies often enforce smaller limits
    (e.g., 64 KB). Large AU payloads (>64 KB) should be split into
    WebSocket continuation frames automatically by the library.
    Test with large spectra (>10K peaks).

55. **Async in ObjC.** Python and Java have mature async/WebSocket
    libraries. ObjC's `nw_connection_t` (Network.framework) is
    available on macOS/iOS but not on GNUstep/Linux. For the ObjC
    implementation, use raw BSD sockets with `select()` or `poll()`
    and implement the WebSocket framing manually (RFC 6455). Or
    use a C WebSocket library like `libwebsockets`.

56. **CRC-32C vs CRC-32.** The spec uses CRC-32C (Castagnoli), not
    the more common CRC-32 (ISO 3309). CRC-32C has better error
    detection and hardware acceleration on modern CPUs. Python:
    `crcmod.predefined.mkCrcFun('crc-32c')` or
    `google-crc32c`. Java: `java.util.zip.CRC32C` (JDK 9+).
    ObjC: SSE4.2 `_mm_crc32_u64` intrinsic or software fallback.

57. **Multiplexed AU ordering.** When streaming a multi-run dataset,
    AUs from different `dataset_id`s may be interleaved. The
    receiver must buffer by `dataset_id` and write each run
    independently. Test with 3+ runs interleaved.

58. **Real-time backpressure.** The acquisition simulator produces
    packets at a fixed rate. If the client can't consume fast
    enough, the WebSocket buffer grows. The server should implement
    backpressure (pause sending when the client's receive buffer
    exceeds a threshold). Use WebSocket flow control.

---

## Execution Checklist

1. **M65:** Fix 3 exporter defects + tag v0.9.0. **Complete.**
2. **M66:** Transport format spec document. **Complete.**
3. **M67:** Transport codec (all three languages). **Complete.**
4. **M68:** WebSocket server + client. **Complete.**
5. **M69:** Acquisition simulator. **Complete.**
6. **M70:** Bidirectional conversion conformance. **Complete.**
7. **M71:** Selective access + encrypted transport. **Complete.**
8. **M72:** Tag v0.10.0. **Complete.**
9. **M73:** Vibrational spectroscopy (Raman + IR) — 4 classes per
   language, JCAMP-DX 5.01 AFFN reader/writer, cross-language
   conformance. **Implementation complete — pending v0.11.0 tag.**

**CI must be green before any milestone is complete.**

---

## Deferred to v1.0+

| Item | Description |
|---|---|
| M40 PyPI + Maven Central | Publish when ready for external users |
| FIPS compliance mode | Algorithm allow-list lockdown |
| ParquetProvider | Columnar alternative backend |
| DBMS transport | Postgres/MySQL blob storage |
| htsget-style REST API | HTTP range-request protocol (formalized from MCP Server) |
| Annotation overlay | External annotation files referencing spectra without modifying original |
| v1.0 API freeze | After production feedback on streaming |

### Parity backfill queue

3-language parity is a binding decision (see the binding decisions
section above). Pre-existing asymmetries are backfilled
opportunistically; the list below tracks open items. COMPLETED
entries are retained as audit trail until v1.0.

- **M68.5 — COMPLETE** (Java + ObjC TransportServer). Shipped
  `com.dtwthalion.mpgo.transport.TransportServer` via
  `org.java-websocket.server.WebSocketServer`,
  `MPGOTransportServer` via libwebsockets server mode, plus
  matching CLI tools (`com.dtwthalion.mpgo.tools.TransportServerCli`
  and `objc/Tools/MpgoTransportServer`). `MPGOAUFilter` /
  `com.dtwthalion.mpgo.transport.AUFilter` mirror Python's
  `AUFilter` for query parsing. All three servers implement the
  same filter set (ms_level, rt range, precursor m/z, polarity,
  dataset_id, max_au). Verified cross-language: Python client
  against Java server and Python client against ObjC server both
  return identical packet counts (14 packets / 10 AUs on the
  minimal_ms fixture). Java 266 / ObjC 1335 test counts.
  Incidental cleanup: Python client now uses `compression=None`
  on `websockets.connect` — the packet-level CRC-32C field
  handles integrity; permessage-deflate would duplicate the
  concern and complicate cross-language interop with
  Java-WebSocket's default handshake.
