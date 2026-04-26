# TTI-O Architecture

TTI-O adapts the MPEG-G (ISO/IEC 23092) architectural pattern — hierarchical containers, descriptor streams, access units, selective encryption, and compressed-domain query — to the needs of multi-omics analytical data: mass spectrometry, NMR, and vibrational spectroscopy (Raman + IR).

As of v0.11.1 there are three interoperable reference implementations:

- **Objective-C / GNUstep** (`objc/`, LGPL-3.0) — the normative
  implementation. Every format guarantee in `docs/format-spec.md` is
  rooted here. 1536 assertions passing.
- **Python (`ttio` package)** (`python/`, LGPL-3.0 core +
  Apache-2.0 importers/exporters) — a full reader/writer on top of
  `h5py` + `numpy` that mirrors the Objective-C class hierarchy
  1-to-1. 765 tests passing.
- **Java (`global.thalion.ttio`)** (`java/`, LGPL-3.0 core +
  Apache-2.0 importers/exporters) — Maven + JDK 17 implementation
  mirroring the ObjC/Python class hierarchy. 331 tests passing.
  Uses `javax.crypto` for AES-256-GCM and HMAC-SHA256 (no external
  crypto dependency). HDF5 via system `libhdf5-java` bindings.

Three-way cross-implementation conformance is asserted at every
milestone: Python drives ObjC and Java subprocesses through
`tests/integration/` harnesses and compares byte-level artefacts.
As of v0.11.1, 44 combinations pass — the v0.10 per-AU encryption
matrix (`test_per_au_cross_language.py`, 38 cells) plus the
JCAMP-DX Raman/IR conformance harness
(`test_raman_ir_cross_language.py`, 6 cells). Any language pair
can exchange encrypted files, transport streams, and vibrational
spectra bit-for-bit.

All three implementations express the architecture in three layers:

1. **Layer 1 — Protocols**: capability interfaces
2. **Layer 2 — Abstract base classes**: domain-agnostic primitives
3. **Layer 3 — Concrete domain classes**: MS / NMR / Raman / IR subclasses

---

## Layer 1 — Protocols

Protocols define capabilities that can be mixed into any class. A class may conform to any combination.

| Protocol | Purpose | Key Methods |
|---|---|---|
| `TTIOIndexable` | Random access by index, key, or range | `-objectAtIndex:`, `-objectForKey:`, `-objectsInRange:` |
| `TTIOStreamable` | Sequential access with seek | `-nextObject`, `-seekToPosition:`, `-currentPosition`, `-hasMore`, `-reset` |
| `TTIOCVAnnotatable` | Controlled-vocabulary annotation | `-addCVParam:`, `-cvParamsForAccession:`, `-allCVParams`, `-hasCVParamWithAccession:` |
| `TTIOProvenanceable` | W3C PROV-compatible processing history | `-addProcessingStep:`, `-provenanceChain`, `-inputEntities`, `-outputEntities` |
| `TTIOEncryptable` | MPEG-G-style multi-level protection | `-encryptWithKey:level:`, `-decryptWithKey:`, `-accessPolicy`, `-setAccessPolicy:` |

### Encryption levels

```objc
typedef NS_ENUM(NSUInteger, TTIOEncryptionLevel) {
    TTIOEncryptionLevelNone = 0,
    TTIOEncryptionLevelDatasetGroup,    // Entire study
    TTIOEncryptionLevelDataset,          // A single AcquisitionRun
    TTIOEncryptionLevelDescriptorStream, // A single signal channel (e.g. intensity)
    TTIOEncryptionLevelAccessUnit        // An individual spectrum
};
```

This mirrors MPEG-G's hierarchy of protection scopes, enabling selective encryption — for example, encrypting quantitative intensity values while leaving m/z and scan metadata readable for indexing and search.

**v0.10 per-Access-Unit encryption.** The `AccessUnit` level was
realised in v0.10.0 as the `opt_per_au_encryption` feature flag, with
the on-disk layout documented in `docs/format-spec.md` §9.1 and the
wire semantics in `docs/transport-spec.md` §4.3 and `docs/transport-
encryption-design.md`. Each spectrum is a separate AES-256-GCM
operation with a fresh IV and AAD bound to `(dataset_id, au_sequence,
channel_name | "header" | "pixel")`. The `<channel>_values` dataset
is replaced by a `<channel>_segments` compound with VL_BYTES slots
for `iv`, `tag`, and `ciphertext`. When `opt_encrypted_au_headers`
is also set, the 36-byte semantic header travels encrypted in
`spectrum_index/au_header_segments`. Transport peers carry the
ciphertext verbatim — servers never decrypt in transit.

---

## Layer 2 — Abstract Base Classes

Conformance below reflects the **v0.1.0-alpha** implementation. Several
classes that the original design declared as conforming to
`TTIOEncryptable` / `TTIOProvenanceable` / `TTIOCVAnnotatable` instead
delegate to the relevant managers in v0.1; see "Implementation notes
(v0.1.0-alpha)" below.

| Class | Inherits | Conforms To | Key Properties |
|---|---|---|---|
| `TTIOSignalArray` | `NSObject` | `TTIOCVAnnotatable` | `buffer` (NSData), `length`, `encoding`, `axis` |
| `TTIOAxisDescriptor` | `NSObject` | `NSCoding`, `NSCopying` | `name`, `unit`, `valueRange`, `samplingMode` |
| `TTIOEncodingSpec` | `NSObject` | `NSCoding`, `NSCopying` | `precision`, `compressionAlgorithm`, `byteOrder` |
| `TTIOValueRange` | `NSObject` | `NSCoding`, `NSCopying` | `minimum`, `maximum` |
| `TTIOCVParam` | `NSObject` | `NSCoding`, `NSCopying` | `ontologyRef`, `accession`, `name`, `value`, `unit` |
| `TTIOSpectrum` | `NSObject` | — | `signalArrays` (NSDictionary), `axes`, `indexPosition`, `scanTimeSeconds`, `precursorMz`, `precursorCharge` |
| `TTIOAcquisitionRun` | `NSObject` | `TTIOIndexable`, `TTIOStreamable` | `spectrumIndex`, `instrumentConfig`, `acquisitionMode`; lazy hyperslab reads when read from disk |
| `TTIOGenomicRun` (v0.11, M82) | `NSObject` | `TTIOIndexable`, `TTIOStreamable` | `genomicIndex`, `referenceUri`, `platform`, `sampleName`, `acquisitionMode`; element type is `TTIOAlignedRead`, not `TTIOSpectrum`. Lazy hyperslab reads on `signal_channels/sequences` and `qualities`; compound rows (cigars, read_names, mate_info) cached on first access |
| `TTIOGenomicIndex` (v0.11, M82) | `NSObject` | — | `offsets`, `lengths`, `chromosomes`, `positions`, `mappingQualities`, `flags` (parallel arrays); `indicesForRegion:`, `indicesForUnmapped`, `indicesForFlag:` query helpers |
| `TTIOWrittenGenomicRun` (v0.11, M82) | `NSObject` | — | Pure write-side container passed to `+writeMinimalToPath:...:genomicRuns:`. Mirrors the field set of `TTIOWrittenRun` for the genomic side |
| `TTIOSpectralDataset` | `NSObject` | — | `title`, `isaInvestigationId`, `msRuns`, `nmrRuns`, `genomicRuns` (v0.11, M82), `identifications`, `quantifications`, `provenanceRecords`, `transitions` |
| `TTIOIdentification` | `NSObject` | `NSCopying` | `runName`, `spectrumIndex`, `chemicalEntity`, `confidenceScore`, `evidenceChain` |
| `TTIOQuantification` | `NSObject` | `NSCopying` | `chemicalEntity`, `sampleRef`, `abundance`, `normalizationMethod` |
| `TTIOProvenanceRecord` | `NSObject` | `NSCopying` | `inputRefs`, `software`, `parameters`, `outputRefs`, `timestampUnix` |
| `TTIOInstrumentConfig` | `NSObject` | `NSCoding`, `NSCopying` | `manufacturer`, `model`, `serialNumber`, `sourceType`, `analyzerType`, `detectorType` |
| `TTIOSpectrumIndex` | `NSObject` | — | `offsets`, `lengths`, `retentionTimes`, `msLevels`, `polarities`, `precursorMzs`, `precursorCharges`, `basePeakIntensities` (parallel C arrays) |
| `TTIOTransitionList` | `NSObject` | — | ordered `TTIOTransition` array |
| `TTIOMSImage` | `NSObject` | — | `width`, `height`, `spectralPoints`, `tileSize`, `cube`; tile-aligned 3-D HDF5 storage |
| `TTIOQuery` | `NSObject` | — | builder over `TTIOSpectrumIndex`; predicates: RT, MS level, polarity, precursor m/z, base peak |
| `TTIOStreamWriter` / `TTIOStreamReader` | `NSObject` | — | incremental append with periodic flush; sequential read |
| `TTIOEncryptionManager` | `NSObject` | — | static AES-256-GCM helpers (OpenSSL EVP) |
| `TTIOAccessPolicy` | `NSObject` | `NSCopying` | JSON-encoded policy persisted under `/protection/access_policies` |

---

## Layer 3 — Concrete Domain Classes

| Class | Extends | Domain-Specific Properties |
|---|---|---|
| `TTIOMassSpectrum` | `TTIOSpectrum` | `mzArray`, `intensityArray` (mandatory, equal length); `msLevel`, `polarity`, `scanWindow` (optional) |
| `TTIONMRSpectrum` | `TTIOSpectrum` | `chemicalShiftArray`, `intensityArray`, `nucleusType`, `spectrometerFrequencyMHz` |
| `TTIONMR2DSpectrum` | `TTIOSpectrum` | `intensityMatrix` (flattened row-major float64), `width`, `height`, `f1Axis`, `f2Axis`, `nucleusF1`, `nucleusF2` |
| `TTIORamanSpectrum` (v0.11) | `TTIOSpectrum` | `wavenumberArray`, `intensityArray`, `excitationWavelengthNm`, `laserPowerMw`, `integrationTimeSec` |
| `TTIOIRSpectrum` (v0.11) | `TTIOSpectrum` | `wavenumberArray`, `intensityArray`, `mode` (`TTIOIRMode` — transmittance/absorbance), `resolutionCmInv`, `numberOfScans` |
| `TTIORamanImage` (v0.11) | `NSObject` | `width`, `height`, `spectralPoints`, `tileSize`, `intensityCube` (float64[H][W][SP]), `wavenumbers` (float64[SP]), `excitationWavelengthNm`, `laserPowerMw` |
| `TTIOIRImage` (v0.11) | `NSObject` | `width`, `height`, `spectralPoints`, `tileSize`, `intensityCube`, `wavenumbers`, `mode`, `resolutionCmInv` |
| `TTIOUVVisSpectrum` (v0.11.1) | `TTIOSpectrum` | `wavelengthArray` (nm), `absorbanceArray`, `pathLengthCm`, `solvent` |
| `TTIOTwoDimensionalCorrelationSpectrum` (v0.11.1) | `TTIOSpectrum` | `variableAxis` (float64[N]), `synchronousMatrix` (float64[N×N] row-major), `asynchronousMatrix` (float64[N×N] row-major); feature-flagged `opt_native_2d_cos` |
| `TTIOFreeInductionDecay` | `TTIOSignalArray` | Complex128 buffer (interleaved real/imag), `dwellTimeSeconds`, `scanCount`, `receiverGain` |
| `TTIOChromatogram` | `TTIOSpectrum` | `timeArray`, `intensityArray`, `type` (TIC / XIC / SRM), `targetMz`, `precursorProductMz`, `productMz` |
| `TTIOTransition` / `TTIOTransitionList` | `NSObject` | precursor → product m/z, collision energy, RT window |
| `TTIOAlignedRead` (v0.11, M82) | `NSObject` | `readName`, `chromosome`, `position`, `mappingQuality`, `cigar`, `sequence`, `qualities`, `flags`, `mateChromosome`, `matePosition`, `templateLength`. Pure value class — does **not** extend `TTIOSpectrum`. See "Genomic abstraction-layer divergence" below for why |

---

## Genomic abstraction-layer divergence (v0.11, M82)

M82 added a parallel run-and-element hierarchy alongside the
spectrum-based classes. The two hierarchies share API surface up to a
point — and then diverge irreducibly. This section documents *where*
that divergence is, layer by layer, so future maintainers know which
abstractions can be extended generically and which can't.

The layered analysis below applies identically to all three reference
implementations (Objective-C, Python, Java).

### Layer A — Storage substrate: fully shared, zero divergence

`StorageProvider` / `StorageGroup` / `StorageDataset` and the four
backends (HDF5, Memory, SQLite, Zarr) make no distinction between MS
and genomic data. Compound datasets, VL_STRING handling, the
AU/encryption layer, signature paths, feature flags — all of it is
modality-agnostic. M82's only intrusions into this layer were:

- One new `Precision.UINT64` enum value for genomic offset arrays.
- One new `OPT_GENOMIC` feature flag and a format-version bump to
  `1.4` when genomic content is present.

Both are additive; neither bifurcates a code path.

### Layer B — `SpectralDataset` container: mostly shared, narrow bifurcation

The top-level container holds both run modalities as sibling typed
collections:

```java
private final Map<String, AcquisitionRun>  msRuns;
private final Map<String, GenomicRun>      genomicRuns;  // M82.3
```

Everything else on `SpectralDataset` is modality-agnostic: `title`,
`isaInvestigationId`, `featureFlags`, `identifications()`,
`quantifications()`, `provenanceRecords()`, `close()`, plus the entire
signature/encryption path. The bifurcation here is *narrow* — two
parallel typed getters and two parallel branches inside `create(...)`
and `open(...)`. A generic "open a `.tio` and walk the runs" tool can
stay polymorphic up to this point, treating each map separately.

### Layer C — Run-level: shared only via generic protocols

`AcquisitionRun` and `GenomicRun` both implement the same trio of
generic access protocols:

- `Indexable<T>` — random access, returns one `T` per index.
- `Streamable<T>` — sequential iteration with seek.
- `AutoCloseable` (Java) / NSObject lifecycle (ObjC) / context manager
  (Python) — resource cleanup.

`AcquisitionRun` also implements `Provenanceable` and `Encryptable`;
`GenomicRun` does not (yet — those would be additive when needed).
Beyond those interfaces the field sets diverge entirely:

| Concern | `AcquisitionRun` | `GenomicRun` |
|---|---|---|
| Element type | `Spectrum` | `AlignedRead` |
| Index type | `SpectrumIndex` | `GenomicIndex` |
| Acquisition metadata | `instrumentConfig`, `nucleusType`, `spectrometerFrequencyMHz` | `referenceUri`, `platform`, `sampleName` |
| Per-element typed channels | m/z + intensity (float64) | sequences + qualities (uint8) |
| Auxiliary data | `chromatograms` (TIC/XIC/SRM) | mate-info, cigars, read-names compounds |
| Storage subgroup | `/study/ms_runs/<name>/` | `/study/genomic_runs/<name>/` |

**There is no shared `Run` base class, and adding one would only buy
generic iteration** — instrument-config-vs-reference-uri is a real
domain difference, not an artifact of the implementation.

### Layer D — Element-level: hard wall

`Spectrum` (the class hierarchy: `MassSpectrum`, `NMRSpectrum`,
`IRSpectrum`, `RamanSpectrum`, `NMR2DSpectrum`, `UVVisSpectrum`,
`TwoDimensionalCorrelationSpectrum`, `Chromatogram`) and
`AlignedRead` (Java record / ObjC value class / Python frozen
dataclass) share *zero* interface. They're both leaves of their
respective trees, but the element-type abstraction is exactly where
the divergence is irreducible:

- A spectrum has a coordinate axis (m/z, chemical shift, wavenumber,
  wavelength) and an intensity axis. The Spectrum hierarchy
  parameterises by axis semantics.
- A read has a string sequence, a Phred quality byte array, a CIGAR
  string, a chromosome, a 0-based position, and SAM flag bits. None
  of these have a coordinate-axis interpretation.

Forcing both under a common parent (`Datum`, `Observation`, `Element`,
…) would be a YAGNI abstraction — there is no operation that
meaningfully spans both element types.

### Summary: where the API can stay polymorphic

| Layer | Sharing | Where divergence enters |
|---|---|---|
| **A. Storage** | 100% shared | n/a |
| **B. Container** | Shared except parallel typed `msRuns` / `genomicRuns` collections | Two parallel getters + parallel write branches |
| **C. Run** | Shared via `Indexable<T>` / `Streamable<T>` / `AutoCloseable` | Element type `T` and concrete field set |
| **D. Element** | None | Entirely separate types — `Spectrum` ≠ `AlignedRead` |

A generic "iterate any run and yield elements" function works across
both modalities. Anything that needs to look at run-specific
metadata, or any per-element field, must bifurcate. This is by design
— pushing the abstraction further would obscure real domain
differences without enabling any concrete client code.

### Cross-cutting parallels (no shared interface, mirrored shape)

These pairs follow the same *pattern* in their respective domains but
deliberately do not share a base class — they are documented together
to make the parallel structure obvious:

- `WrittenRun` ↔ `WrittenGenomicRun` (write-side containers, both
  Java records / ObjC value classes)
- `SpectrumIndex` ↔ `GenomicIndex` (parallel-array index containers)
- `MassSpectrum.mzArray, .intensityArray` ↔ `AlignedRead.sequence,
  .qualities` (per-element typed channels)

Pre-M82 readers (lacking the `OPT_GENOMIC` feature flag) simply see
`genomicRuns == {}` and an empty `/study/genomic_runs/` group; no
existing MS-only client code path is affected.

---

## Storage Provider Abstraction (v0.6, M39)

The data model and API are the standard; the storage backend is a
**pluggable implementation detail**. Two providers ship:

```
                 ┌─────────────────────────┐
                 │  SpectralDataset / ...  │   upper layers
                 └────────────┬────────────┘
                              │ talks only to protocols
                              ▼
        ┌─────────────────────────────────────────────┐
        │ <StorageProvider> / <StorageGroup> /         │
        │         <StorageDataset>                     │
        └────────────┬────────────────────┬────────────┘
                     │                    │
                     ▼                    ▼
            ┌─────────────────┐  ┌─────────────────┐
            │  Hdf5Provider   │  │ MemoryProvider  │
            │   (h5py/libhdf5)│  │ (dict-tree)     │
            └─────────────────┘  └─────────────────┘
```

Providers register via platform-native discovery:

* **Python** — `importlib.metadata` entry points
  (`project.entry-points."ttio.providers"` in `pyproject.toml`).
* **Java** — `java.util.ServiceLoader` with a service file at
  `META-INF/services/global.thalion.ttio.providers.StorageProvider`.
* **ObjC** — `+load` registration into `TTIOProviderRegistry`.

Each language exposes the same **capability floor**:

| Capability | Required |
|---|---|
| Hierarchical groups | ✓ |
| Named 1-D typed datasets | ✓ |
| Partial/hyperslab reads | ✓ |
| Chunked storage | ✓ |
| Compression (zlib, LZ4) | ✓ |
| Compound types with VL strings | ✓ |
| Scalar + array attributes on groups and datasets | ✓ |

`MemoryProvider` exists so the abstraction is provable: if round-trip
tests pass identically over `Hdf5Provider` and `MemoryProvider`, the
protocol contract is correct. Future providers (Zarr, SQLite, …) are
drop-in additions.

### Transport

Two orthogonal axes:

1. **Storage transport** — Python's `Hdf5Provider.open` routes cloud
   URLs (`s3://…`, `http://…`) through `fsspec`; ObjC adds ROS3 in
   v0.7+. Memory / SQLite / Zarr backends are reached by URL scheme
   (`memory://…`, `sqlite://…`, `zarr://…`).

2. **Streaming transport (v0.10)** — the `.tis` wire format
   documented in `docs/transport-spec.md`. 24-byte packet headers
   carry nine packet types (StreamHeader, DatasetHeader, AccessUnit,
   ProtectionMetadata, Annotation, Provenance, Chromatogram,
   EndOfDataset, EndOfStream). `TransportWriter` / `TransportReader`
   in all three languages produce / consume the same byte stream;
   `TransportClient` / `TransportServer` wrap the codec in a
   WebSocket frame. Encrypted AUs travel with the ciphertext
   unmodified — the server never decrypts in transit, so selective-
   access filtering is driven by plaintext AU filter fields (or
   the ProtectionMetadata header) rather than the payload. See
   `docs/transport-encryption-design.md` §6.

### Transport ↔ file bidirectionality

`TransportReader.materialize_to(path)` and the ObjC / Java
equivalents write a `.tio` from a `.tis` stream; the inverse
`TransportWriter.write_dataset(dataset)` emits the stream from a
file. The bidirectional conformance test (M70) asserts that any
writer × reader pair across {Python, ObjC, Java} produces
byte-identical round trips.

### Caller refactor status

v0.6 shipped the abstraction and the entry-point refactor for HDF5;
v0.9 M64.5 phase A wired bulk reads + writes through the protocol so
Memory / SQLite / Zarr backends round-trip end-to-end:

| Class | Status |
|---|---|
| `SpectralDataset.open` | **Provider-aware** — URL scheme dispatches to MemoryProvider / SqliteProvider / ZarrProvider; bare paths default to HDF5 (M64.5) |
| `SpectralDataset.write_minimal` | **Provider-aware** — `provider=` kwarg picks backend; HDF5 fast path keeps legacy byte layout (M64.5) |
| `_write_run` / `_write_identifications` / `_write_quantifications` / `_write_provenance` | **Provider-aware** via the StorageGroup protocol; HDF5 helpers in `_hdf5_io.py` dispatch on isinstance for byte parity (M64.5) |
| `AcquisitionRun.open` + `_read_chromatograms` + `write_chromatograms_to_run_group` | **Provider-aware** — cold-path attribute and dataset reads go through StorageGroup primitives (M64.5) |
| `Hdf5Provider.native_handle()` | Returns underlying `h5py.File` / `Hdf5File` / `TTIOHDF5File` for byte-level code that hasn't been ported yet |
| `EncryptionManager` (`encrypt_intensity_channel_in_group` + `read_encrypted_channel`) | **Provider-aware** — both helpers dispatch via isinstance: HDF5 keeps the legacy multi-dataset rewrite path, non-HDF5 routes through StorageGroup `create_dataset` / `open_dataset` / `delete_child` (M64.5 phase B) |
| `SignatureManager` (`sign_dataset` / `verify_dataset`) | **Provider-aware** — h5py callers go through the legacy fast path; `StorageDataset` callers delegate to the M54.1 `sign_storage_dataset` / `verify_storage_dataset` siblings (M64.5 phase B) |
| `Anonymizer.anonymize` | **Provider-aware** — accepts a `provider=` kwarg passed through to `write_minimal` (M64.5 phase B) |
| `KeyRotationManager` (`enable_envelope_encryption` / `unwrap_dek` / `rotate_key` / `key_history` / `has_envelope_encryption`) | **Provider-aware** — accepts `h5py.File`, `StorageProvider`, or `SpectralDataset`. HDF5 keeps the legacy uint8 `dek_wrapped` layout; non-HDF5 providers pack the wrapped blob into a UINT32 array with a companion `dek_wrapped_byte_length` attribute (the protocol has no UINT8 precision). Internal helpers route via the new `_native_h5_from()` shim (M64.5 phase C) |
| MSImage cube `create_dataset_nd` | **Provider-aware** — every shipping provider implements rank-3 `create_dataset_nd` for `[height, width, spectral_points]` cubes; cross-provider parity proven by `tests/integration/test_msimage_cube_cross_provider.py`. A higher-level MSImage *writer* on top of `SpectralDataset.write_minimal` is a v1.0+ item but not blocked by the protocol (M64.5 phase C) |

**Cross-provider proof.** Five integration matrices exercise the
4-provider grid in CI: `test_mzml_roundtrip.py` (8 cells),
`test_nmrml_roundtrip.py` (3 cells),
`test_protection_cross_provider.py` (12 cells: encrypt+decrypt,
wrong-key, sign+verify), `test_key_rotation_cross_provider.py`
(12 cells: wrap, wrong-KEK, rotate+history), and
`test_msimage_cube_cross_provider.py` (4 cells: `[h,w,sp]` cube
round-trip). All 39 cross-provider cells pass on HDF5, Memory,
SQLite, and Zarr. The caller refactor is now complete for v0.9.0;
no rows in this table say "Still native".

### Cross-language URL-scheme dispatch (v0.9 M64.5-objc-java)

Python's `SpectralDataset.open(url)` detected URL schemes after
M64.5 phase A; the v0.9 follow-up extends the same dispatch to the
Java and ObjC entry points:

| Language | `open(url)` | `create(url, ...)` | Notes |
|---|---|---|---|
| Python  | All 4 providers | All 4 providers | HDF5 fast path + StorageGroup path (M64.5 phase A) |
| Java    | All 4 providers | All 4 providers | M64.5-objc-java: `ProviderRegistry.open` + JSON-attribute metadata path. `ZarrProvider` reads gzip-compressed Zarr v3 chunks via JDK `GZIPInputStream`. |
| ObjC    | All 4 providers (read) | HDF5 only | v0.9 follow-up: `+readViaProviderURL:` uses `TTIOProviderRegistry` + new `TTIOAcquisitionRun readFromStorageGroup:` + new `TTIOSpectrumIndex readFromStorageGroup:` + JSON-attribute metadata. `TTIOZarrProvider` reads gzip-compressed Zarr v3 chunks via libz. Write-side caller refactor is a v1.0+ item. |

**Cross-language cross-provider interop** is tested by
`python/tests/validation/test_cross_language_smoke.py` — 10 cells:

* HDF5: Python writes, ObjC + Java both read (3 tests, all pass)
* 4-provider Java read matrix: HDF5 / SQLite / Zarr pass;
  `memory` xfails (in-process-only by design — separate JVM
  cannot see the Python process's memory stores)
* ObjC reads Python-written SQLite + Zarr via the new
  `+readViaProviderURL:` path (2 cells, both pass)
* ObjC non-HDF5 URL error path: verified

9 of 10 cells pass; the one xfail is a fundamental process-boundary
limit rather than an implementation gap. Persistent-file interop
(HDF5 / SQLite / Zarr) is full-matrix across all three languages.

**v1.0+ follow-ups**:

* ObjC *write* via provider URL — currently HDF5-only; producers
  should use Python or Java for non-HDF5 writes.
* Python SQLite `spectrum_index` UINT64 native support — v0.9
  maps `<u8` to INT64 at the provider boundary (byte-lossless
  because offsets are always < 2^63).
* Java / ObjC Zarr blosc / lz4 / zstd decode — v0.9 handles the
  `gzip` codec written by zarr-python's default `GzipCodec`.
  Python uses zarr-python's full codec catalog.

---

## HDF5 Container Mapping

TTI-O files are HDF5 files with the `.tio` extension. The internal hierarchy mirrors the MPEG-G file model:

```
/                                       # Root (= MPEG-G File)
├── @ttio_version                     # "1.0.0"
├── /study/                             # Dataset Group (= ISA Investigation)
│   ├── @isa_investigation_id
│   ├── /metadata/                      # Study-level CV annotations
│   │   └── cv_params                   # Compound HDF5 dataset of CVParam records
│   ├── /run_0001/                      # Dataset (= AcquisitionRun)
│   │   ├── @acquisition_mode           # Data Class enum
│   │   ├── @instrument_config          # Compound HDF5 type
│   │   ├── /provenance/                # ProvenanceRecord chain
│   │   │   └── steps                   # Compound dataset: input/software/params/output/ts
│   │   ├── /signal_channels/           # Descriptor Streams
│   │   │   ├── mz_values               # float64 dataset, chunked + zlib
│   │   │   ├── intensity_values        # float32 dataset, chunked + zlib
│   │   │   ├── ion_mobility_values     # float64 dataset (optional)
│   │   │   └── scan_metadata           # Compound dataset (RT, ms_level, polarity, …)
│   │   ├── /spectrum_index/            # Access Unit index
│   │   │   ├── offsets                 # uint64[] — byte offsets into signal channels
│   │   │   ├── lengths                 # uint32[] — number of points per spectrum
│   │   │   └── headers                 # Compound dataset — queryable AU headers
│   │   └── /chromatograms/
│   │       ├── tic_time                # float64
│   │       └── tic_intensity           # float32
│   ├── /run_0002/                      # (additional runs)
│   │   └── …
│   ├── /identifications/               # Linked identifications
│   │   ├── spectrum_refs               # uint32[]
│   │   ├── chemical_entities           # variable-length string dataset
│   │   ├── scores                      # float64[]
│   │   └── evidence                    # Compound dataset
│   └── /quantifications/
│       ├── abundance_values            # float64[]
│       └── sample_refs                 # variable-length string dataset
└── /protection/                        # MPEG-G multi-level encryption metadata
    ├── access_policies                 # JSON policy definitions (dataset)
    └── key_info                        # Key management metadata (NO keys stored here)
```

### Key design choices

1. **Signal-channel separation.** Rather than storing each spectrum as a blob, m/z values and intensity values from all spectra in a run are stored in two contiguous HDF5 datasets. A SpectrumIndex maps spectrum index → (offset, length) pairs within those channels. This matches MPEG-G's descriptor streams and enables columnar access patterns and better compression ratios.

2. **Chunked + compressed.** All signal channels are chunked (default 64 KiB target) and zlib-compressed (default level 6). Chunk boundaries align to spectrum boundaries where possible.

3. **Compressed-domain query via AU headers.** The `/spectrum_index/headers` compound dataset stores scan time, MS level, polarity, precursor m/z, and base peak intensity for every spectrum — without touching the actual signal arrays. Queries like "all MS2 spectra with RT in [10, 12] minutes and precursor m/z near 523.2" are answered by scanning this header table alone.

4. **Selective encryption.** Because the signal channels are separate HDF5 datasets, any subset can be encrypted independently. A typical protection policy: encrypt `intensity_values` but leave `mz_values`, `scan_metadata`, and `spectrum_index` in the clear, allowing an untrusted party to perform structural/peak-list queries without revealing quantitative information.

5. **Provenance as first-class data.** The `/provenance/` group stores a W3C PROV-compatible chain: every processing step records input entities, the software + parameters that produced it, output entities, and a timestamp. Chains are queryable and cryptographically verifiable.

---

## Object Lifecycle & Persistence Model

Every persistent class implements a pair of methods:

```objc
- (BOOL)writeToGroup:(TTIOHDF5Group *)group name:(NSString *)name error:(NSError **)error;
+ (instancetype)readFromGroup:(TTIOHDF5Group *)group name:(NSString *)name error:(NSError **)error;
```

In-memory objects can be constructed, mutated, and held without
touching HDF5 at all — persistence is explicit. `TTIOSpectralDataset`
provides file-level entry points (`-writeToFilePath:error:` /
`+readFromFilePath:error:`) and `TTIOStreamWriter` / `TTIOStreamReader`
support incremental ingestion of large runs.

## Thread Safety

**Opt-in reader-writer locking since v0.4 (Milestone 23).**

### Objective-C: `TTIOHDF5File`

Each `TTIOHDF5File` owns a `pthread_rwlock_t`. Every public method on
`TTIOHDF5Group` and `TTIOHDF5Dataset` acquires either the shared (read)
or exclusive (write) lock on the owning file for the duration of its
HDF5 calls:

* Read lock: `openGroupNamed:`, `hasChildNamed:`, `openDatasetNamed:`,
  `stringAttributeNamed:`, `integerAttributeNamed:`, `hasAttributeNamed:`,
  `readDataWithError:`, `readDataAtOffset:count:error:`.
* Write lock: `createGroupNamed:`, `createDatasetNamed:…`, `setStringAttribute:`,
  `setIntegerAttribute:`, `writeData:error:`.

`-isThreadSafe` reports `YES` iff both (a) the wrapper rwlock initialised
successfully **and** (b) the linked libhdf5 reports
`H5is_library_threadsafe() == true`. When (b) is false, the wrapper enters
**degraded mode**: readers are silently promoted to exclusive-lock
acquisition so we never reenter a non-thread-safe libhdf5 from two
threads concurrently. This keeps the safety guarantee regardless of how
HDF5 was built, at the cost of reader parallelism. CI logs the runtime
mode via a one-shot `H5is_library_threadsafe` probe.

### Python: `SpectralDataset`

Opt-in via `SpectralDataset.open(path, thread_safe=True)`. When enabled,
the dataset carries an `ttio._rwlock.RWLock` (writer-preferring,
stdlib-only). `read_lock()` and `write_lock()` are context managers that
are *no-ops* when `thread_safe` was not requested, so call sites can use
them unconditionally:

```python
with SpectralDataset.open("dataset.tio", thread_safe=True) as ds:
    with ds.read_lock():
        ids = ds.identifications()
```

Internal accessors (`identifications`, `quantifications`, `provenance`,
`close`) already acquire the appropriate lock. Deep traversal via
`ds.ms_runs['run0'].spectra[...]` is **not** protected automatically —
wrap such access sites in `ds.read_lock()` if multiple threads share the
dataset.

Python threads are serialised by h5py/cython through the GIL for the
duration of each HDF5 C call, so the RW lock's role is to protect
*composite* operations from writer interleaving, not to substitute for
libhdf5's thread-safety.

### What thread-safety does *not* buy you

HDF5's threadsafe mode uses a global library mutex, so "2-4× parallel
read speedup" is not physically achievable for pure HDF5 I/O regardless
of our wrapper — the library serialises below. The measured benefit of
M23 is:

1. Crash-safety under concurrent access (safety, not speed).
2. Writer exclusion — in-flight writes never interleave with readers,
   eliminating a class of torn-read bugs.
3. Low single-thread overhead (<15 % in the benchmark, see
   `python/tests/test_milestone23_benchmark.py`).

Parallel decode/decompress on top of the HDF5 critical path is a
potential v0.5 optimisation (not in scope for M23).

---

## Python class mapping (v0.3, M16)

The Python package mirrors the Objective-C hierarchy without the
`TTIO` prefix. Files under `python/src/ttio/` are keyed by
snake_case module names.

| Objective-C class                | Python class                              | Module                              |
|----------------------------------|-------------------------------------------|-------------------------------------|
| `TTIOSignalArray`                | `SignalArray`                             | `ttio.signal_array`               |
| `TTIOSpectrum`                   | `Spectrum`                                | `ttio.spectrum`                   |
| `TTIOMassSpectrum`               | `MassSpectrum`                            | `ttio.mass_spectrum`              |
| `TTIONMRSpectrum`                | `NMRSpectrum`                             | `ttio.nmr_spectrum`               |
| `TTIONMR2DSpectrum`              | `NMR2DSpectrum`                           | `ttio.nmr_2d`                     |
| `TTIORamanSpectrum` (v0.11)      | `RamanSpectrum`                           | `ttio.raman_spectrum`             |
| `TTIOIRSpectrum` (v0.11)         | `IRSpectrum`                              | `ttio.ir_spectrum`                |
| `TTIOUVVisSpectrum` (v0.11.1)    | `UVVisSpectrum`                           | `ttio.uv_vis_spectrum`            |
| `TTIOTwoDimensionalCorrelationSpectrum` (v0.11.1) | `TwoDimensionalCorrelationSpectrum` | `ttio.two_dimensional_correlation_spectrum` |
| `TTIOFreeInductionDecay`         | `FreeInductionDecay`                      | `ttio.fid`                        |
| `TTIOChromatogram`               | `Chromatogram`                            | `ttio.chromatogram`               |
| `TTIOAcquisitionRun`             | `AcquisitionRun` + `SpectrumIndex`        | `ttio.acquisition_run`            |
| `TTIOSpectralDataset`            | `SpectralDataset`                         | `ttio.spectral_dataset`           |
| `TTIOMSImage`                    | `MSImage`                                 | `ttio.ms_image`                   |
| `TTIORamanImage` (v0.11)         | `RamanImage`                              | `ttio.raman_image`                |
| `TTIOIRImage` (v0.11)            | `IRImage`                                 | `ttio.ir_image`                   |
| `TTIOIdentification`             | `Identification`                          | `ttio.identification`             |
| `TTIOQuantification`             | `Quantification`                          | `ttio.quantification`             |
| `TTIOProvenanceRecord`           | `ProvenanceRecord`                        | `ttio.provenance`                 |
| `TTIOTransitionList`             | `TransitionList` / `Transition`           | `ttio.transition_list`            |
| `TTIOFeatureFlags`               | `FeatureFlags`                            | `ttio.feature_flags`              |
| `TTIOInstrumentConfig`           | `InstrumentConfig`                        | `ttio.instrument_config`          |
| `TTIOEncryptionManager`          | `ttio.encryption` module                | `ttio.encryption`                 |
| `TTIOSignatureManager`           | `ttio.signatures` module                | `ttio.signatures`                 |
| `TTIONumpress`                   | `ttio._numpress` module                 | `ttio._numpress`                  |
| `TTIOMzMLReader` (Apache-2.0)    | `ttio.importers.mzml`                   | `ttio.importers.mzml`             |
| `TTIONmrMLReader` (Apache-2.0)   | `ttio.importers.nmrml`                  | `ttio.importers.nmrml`            |
| `TTIOMzMLWriter` (Apache-2.0)    | `ttio.exporters.mzml`                   | `ttio.exporters.mzml`             |
| `TTIOCVTermMapper`               | `ttio.importers.cv_term_mapper`         | `ttio.importers.cv_term_mapper`   |
| *(new in v0.3)*                  | `ttio.remote` (fsspec URL dispatcher)   | `ttio.remote`                     |

---

## Java Class Mapping (v0.5, M31–M35)

| ObjC Class | Java Class | Package |
|------------|-----------|---------|
| `TTIOSignalArray` | `SignalArray` | `global.thalion.ttio` |
| `TTIOSpectrum` | `Spectrum` | `global.thalion.ttio` |
| `TTIOMassSpectrum` | `MassSpectrum` | `global.thalion.ttio` |
| `TTIONMRSpectrum` | `NMRSpectrum` | `global.thalion.ttio` |
| `TTIONMR2DSpectrum` | `NMR2DSpectrum` | `global.thalion.ttio` |
| `TTIORamanSpectrum` (v0.11) | `RamanSpectrum` | `global.thalion.ttio` |
| `TTIOIRSpectrum` (v0.11) | `IRSpectrum` | `global.thalion.ttio` |
| `TTIOUVVisSpectrum` (v0.11.1) | `UVVisSpectrum` | `global.thalion.ttio` |
| `TTIOTwoDimensionalCorrelationSpectrum` (v0.11.1) | `TwoDimensionalCorrelationSpectrum` | `global.thalion.ttio` |
| `TTIOFreeInductionDecay` | `FreeInductionDecay` | `global.thalion.ttio` |
| `TTIOChromatogram` | `Chromatogram` | `global.thalion.ttio` |
| `TTIOSpectrumIndex` | `SpectrumIndex` | `global.thalion.ttio` |
| `TTIOAcquisitionRun` | `AcquisitionRun` | `global.thalion.ttio` |
| `TTIOSpectralDataset` | `SpectralDataset` | `global.thalion.ttio` |
| `TTIOMSImage` | `MSImage` | `global.thalion.ttio` |
| `TTIORamanImage` (v0.11) | `RamanImage` | `global.thalion.ttio` |
| `TTIOIRImage` (v0.11) | `IRImage` | `global.thalion.ttio` |
| `TTIOFeatureFlags` | `FeatureFlags` | `global.thalion.ttio` |
| `TTIOIdentification` | `Identification` | `global.thalion.ttio` (record) |
| `TTIOQuantification` | `Quantification` | `global.thalion.ttio` (record) |
| `TTIOProvenanceRecord` | `ProvenanceRecord` | `global.thalion.ttio` (record) |
| `TTIOEncryptionManager` | `EncryptionManager` | `global.thalion.ttio.protection` |
| `TTIOSignatureManager` | `SignatureManager` | `global.thalion.ttio.protection` |
| `TTIOKeyRotationManager` | `KeyRotationManager` | `global.thalion.ttio.protection` |
| `TTIOAnonymizer` | `Anonymizer` | `global.thalion.ttio.protection` |
| `TTIOMzMLReader` | `MzMLReader` | `global.thalion.ttio.importers` |
| `TTIOMzMLWriter` | `MzMLWriter` | `global.thalion.ttio.exporters` |
| `TTIONmrMLReader` | `NmrMLReader` | `global.thalion.ttio.importers` |
| `TTIONmrMLWriter` | `NmrMLWriter` | `global.thalion.ttio.exporters` |
| `TTIOISAExporter` | `ISAExporter` | `global.thalion.ttio.exporters` |
| `TTIONumpress` | `NumpressCodec` | `global.thalion.ttio` |
| `TTIOHDF5File` | `Hdf5File` | `global.thalion.ttio.hdf5` |
| `TTIOHDF5Group` | `Hdf5Group` | `global.thalion.ttio.hdf5` |
| `TTIOHDF5Dataset` | `Hdf5Dataset` | `global.thalion.ttio.hdf5` |

Java uses `AutoCloseable` + try-with-resources instead of ObjC `-dealloc`. Thread
safety via `ReentrantReadWriteLock` on `Hdf5File` (same model as ObjC's
`pthread_rwlock_t`). Value types use Java records (JDK 17). Crypto via
`javax.crypto` (no external dependency). Maven build with system HDF5 1.10
bindings (`libhdf5-java`).

---

### Key design idioms

- **Frozen dataclasses** for immutable value types
  (`ValueRange`, `CVParam`, `AxisDescriptor`, `EncodingSpec`,
  `InstrumentConfig`, `Identification`, `Quantification`,
  `ProvenanceRecord`, `FeatureFlags`).
- **`IntEnum`**, not `StrEnum`, for all format enums
  (`Precision`, `Compression`, `Polarity`, `SamplingMode`,
  `AcquisitionMode`, `ChromatogramType`, `EncryptionLevel`). Each
  one persists as an integer HDF5 attribute, so `IntEnum` values
  are a direct pass-through and remove a translation table that
  would otherwise need to stay in sync with the ObjC
  `NS_ENUM(NSUInteger, ...)` declarations.
- **Lazy signal access** — `AcquisitionRun` pre-loads the spectrum
  index (small, eager) at open time and slices signal channels
  from the HDF5 dataset only when a spectrum is touched.
  Numpress-delta channels are the one exception: they're eagerly
  decoded at open because the inverse cumsum needs the running-sum
  prefix of the whole channel.
- **String attributes** written as fixed-length NULLTERM strings
  sized to `len(value) + 1` (h5py enforces a trailing null byte
  on write, while the ObjC writer uses `len(value)` with no
  terminator — both layouts are mutually readable).

---

## Compression codec matrix (v0.3, M21)

| Codec              | Transport                                    | Lossy? | ObjC support                                          | Python support                                    |
|--------------------|----------------------------------------------|--------|-------------------------------------------------------|---------------------------------------------------|
| **zlib** (default) | `H5P_DEFLATE` filter, level 6                | No     | `TTIOCompressionZlib` via `H5Pset_deflate`            | `compression="gzip"` on `h5py.create_dataset`     |
| **LZ4**            | HDF5 filter 32004 (plugin-gated)             | No     | `TTIOCompressionLZ4` via `H5Pset_filter(32004)`       | `compression="lz4"` via `hdf5plugin.LZ4()`        |
| **Numpress-delta** | TTIO transform → int64 deltas + zlib         | Yes    | `TTIOCompressionNumpressDelta` via `TTIONumpress`     | `signal_compression="numpress_delta"`             |

LZ4 availability is runtime-detected via `H5Zfilter_avail(32004)` in ObjC and `hdf5plugin.PLUGIN_PATH` + `h5py.h5z.filter_avail(32004)` in Python; both implementations skip their LZ4 tests cleanly when the filter is absent. Numpress-delta is always available because it is a pure-library transform that produces an ordinary int64 HDF5 dataset.

---

## Cloud-native access (v0.3, M20, Python-only)

`SpectralDataset.open("s3://bucket/file.tio")` detects URL schemes via `ttio.remote.is_remote_url` and routes them through `fsspec.open(url, "rb")`. The resulting seekable byte stream is handed to `h5py.File`, which then reads only the HDF5 chunks touched by the caller. Supported schemes include `file://`, `http(s)://`, `s3://`, `gs://`, `gcs://`, `az://`, `abfs(s)://`; the backend dependencies live behind the `cloud` optional extra.

Performance characteristics (observed on a 15 MB fixture served over localhost with a 64 KiB fsspec block cache):

- 10 random spectra from a 1,000-spectrum file: ~50 ms wall clock.
- Fraction of file bytes actually transferred: ~24%.

The Objective-C implementation reads only POSIX files in v0.3 because `libhdf5` consumes files via Virtual File Drivers (VFDs) rather than arbitrary byte streams. Integrating `libhdf5`'s ROS3 VFD (or a custom libcurl-backed VFD) is a tracked follow-up in `WORKPLAN.md`.

---

## Implementation notes (v0.1.0-alpha)

A few deliberate simplifications keep v0.1's surface area small. None
affect on-disk readability via standard HDF5 tools.

* **`TTIOEncryptable` is delegated, not directly conformed.**
  `TTIOAcquisitionRun` and `TTIOSpectralDataset` do not yet conform to
  `TTIOEncryptable` themselves; selective encryption of the intensity
  channel is performed via the static `TTIOEncryptionManager` API
  against an open `.tio` path. A v0.2 milestone may thread the
  protocol through both classes' init/read paths.

* **`TTIOProvenanceable` is satisfied at the dataset level.**
  Provenance is stored as an array of `TTIOProvenanceRecord` on
  `TTIOSpectralDataset` rather than per-run. The dataset-level
  `-provenanceRecordsForInputRef:` query satisfies the workplan
  acceptance criterion.

* **Identifications, quantifications, and provenance are JSON-encoded.**
  Stored as JSON strings under `/study/`'s scalar attributes rather than
  as bespoke HDF5 compound types. The data is fully round-trippable and
  inspectable with any JSON-aware tool, at the cost of slightly larger
  on-disk footprint than a packed compound layout.

* **`TTIOSpectrumIndex` uses parallel 1-D datasets.** The MPEG-G design
  spec calls for a single compound `headers` dataset; v0.1 stores eight
  parallel datasets (offsets, lengths, retention_times, ms_levels,
  polarities, precursor_mzs, precursor_charges, base_peak_intensities)
  for simpler readout from non-Cocoa tools and a smaller HDF5 wrapper
  surface.

* **`TTIOMSImage` is standalone, not a `TTIOSpectralDataset` subclass.**
  The cube lives under `/image_cube/` and can coexist with a `/study/`
  written by `TTIOSpectralDataset` in the same `.tio` file. Inheritance
  may be added in a later milestone.

* **Mass-spectrum runs only.** `TTIOAcquisitionRun` accepts only
  `TTIOMassSpectrum` instances. NMR runs live as named arrays of
  `TTIONMRSpectrum` directly under `TTIOSpectralDataset.nmrRuns`. Mixed
  runs are a planned post-1.0 extension.

* **`TTIONMR2DSpectrum` flattens its matrix.** The 2-D intensity matrix
  is stored as a 1-D `TTIOSignalArray` with `width` × `height` bytes
  plus shape attributes, rather than a native 2-D HDF5 dataset. Round-
  trip equality is byte-exact; native multi-dim datasets may follow.

* **`-fblocks` is disabled on the apt gnustep-1.8 toolchain path.**
  `libTTIO` itself uses no block-based APIs; CI builds against
  source-built `libobjc2` (gnustep-2.0 non-fragile ABI) where blocks
  are available.
