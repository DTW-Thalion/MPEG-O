# MPEG-O Architecture

MPEG-O adapts the MPEG-G (ISO/IEC 23092) architectural pattern — hierarchical containers, descriptor streams, access units, selective encryption, and compressed-domain query — to the needs of multi-omics analytical data, specifically mass spectrometry and NMR spectroscopy.

As of v0.5.0 there are three interoperable reference implementations:

- **Objective-C / GNUstep** (`objc/`, LGPL-3.0) — the normative
  implementation. Every format guarantee in `docs/format-spec.md` is
  rooted here. 836 assertions passing across M1–M30.
- **Python (`mpeg-o` package)** (`python/`, LGPL-3.0 core +
  Apache-2.0 importers/exporters) — a full reader/writer on top of
  `h5py` + `numpy` that mirrors the Objective-C class hierarchy
  1-to-1. 120 tests passing. Cross-language parity is asserted at
  every milestone: the Python reader opens every ObjC reference
  fixture, the Python writer produces files the ObjC `MpgoVerify`
  CLI decodes without
  error, and `v2:` HMAC signatures plus Numpress-delta scale
  factors are byte-identical between the two.
- **Java (`com.dtwthalion.mpgo`)** (`java/`, LGPL-3.0 core +
  Apache-2.0 importers/exporters) — Maven + JDK 17 implementation
  mirroring the ObjC/Python class hierarchy. 62 tests passing.
  Uses `javax.crypto` for AES-256-GCM and HMAC-SHA256 (no external
  crypto dependency). HDF5 via system `libhdf5-java` bindings.
  Three-way cross-implementation conformance verified at every
  milestone via CI.

All three implementations express the architecture in three layers:

1. **Layer 1 — Protocols**: capability interfaces
2. **Layer 2 — Abstract base classes**: domain-agnostic primitives
3. **Layer 3 — Concrete domain classes**: MS- and NMR-specific subclasses

---

## Layer 1 — Protocols

Protocols define capabilities that can be mixed into any class. A class may conform to any combination.

| Protocol | Purpose | Key Methods |
|---|---|---|
| `MPGOIndexable` | Random access by index, key, or range | `-objectAtIndex:`, `-objectForKey:`, `-objectsInRange:` |
| `MPGOStreamable` | Sequential access with seek | `-nextObject`, `-seekToPosition:`, `-currentPosition`, `-hasMore`, `-reset` |
| `MPGOCVAnnotatable` | Controlled-vocabulary annotation | `-addCVParam:`, `-cvParamsForAccession:`, `-allCVParams`, `-hasCVParamWithAccession:` |
| `MPGOProvenanceable` | W3C PROV-compatible processing history | `-addProcessingStep:`, `-provenanceChain`, `-inputEntities`, `-outputEntities` |
| `MPGOEncryptable` | MPEG-G-style multi-level protection | `-encryptWithKey:level:`, `-decryptWithKey:`, `-accessPolicy`, `-setAccessPolicy:` |

### Encryption levels

```objc
typedef NS_ENUM(NSUInteger, MPGOEncryptionLevel) {
    MPGOEncryptionLevelNone = 0,
    MPGOEncryptionLevelDatasetGroup,    // Entire study
    MPGOEncryptionLevelDataset,          // A single AcquisitionRun
    MPGOEncryptionLevelDescriptorStream, // A single signal channel (e.g. intensity)
    MPGOEncryptionLevelAccessUnit        // An individual spectrum
};
```

This mirrors MPEG-G's hierarchy of protection scopes, enabling selective encryption — for example, encrypting quantitative intensity values while leaving m/z and scan metadata readable for indexing and search.

---

## Layer 2 — Abstract Base Classes

Conformance below reflects the **v0.1.0-alpha** implementation. Several
classes that the original design declared as conforming to
`MPGOEncryptable` / `MPGOProvenanceable` / `MPGOCVAnnotatable` instead
delegate to the relevant managers in v0.1; see "Implementation notes
(v0.1.0-alpha)" below.

| Class | Inherits | Conforms To | Key Properties |
|---|---|---|---|
| `MPGOSignalArray` | `NSObject` | `MPGOCVAnnotatable` | `buffer` (NSData), `length`, `encoding`, `axis` |
| `MPGOAxisDescriptor` | `NSObject` | `NSCoding`, `NSCopying` | `name`, `unit`, `valueRange`, `samplingMode` |
| `MPGOEncodingSpec` | `NSObject` | `NSCoding`, `NSCopying` | `precision`, `compressionAlgorithm`, `byteOrder` |
| `MPGOValueRange` | `NSObject` | `NSCoding`, `NSCopying` | `minimum`, `maximum` |
| `MPGOCVParam` | `NSObject` | `NSCoding`, `NSCopying` | `ontologyRef`, `accession`, `name`, `value`, `unit` |
| `MPGOSpectrum` | `NSObject` | — | `signalArrays` (NSDictionary), `axes`, `indexPosition`, `scanTimeSeconds`, `precursorMz`, `precursorCharge` |
| `MPGOAcquisitionRun` | `NSObject` | `MPGOIndexable`, `MPGOStreamable` | `spectrumIndex`, `instrumentConfig`, `acquisitionMode`; lazy hyperslab reads when read from disk |
| `MPGOSpectralDataset` | `NSObject` | — | `title`, `isaInvestigationId`, `msRuns`, `nmrRuns`, `identifications`, `quantifications`, `provenanceRecords`, `transitions` |
| `MPGOIdentification` | `NSObject` | `NSCopying` | `runName`, `spectrumIndex`, `chemicalEntity`, `confidenceScore`, `evidenceChain` |
| `MPGOQuantification` | `NSObject` | `NSCopying` | `chemicalEntity`, `sampleRef`, `abundance`, `normalizationMethod` |
| `MPGOProvenanceRecord` | `NSObject` | `NSCopying` | `inputRefs`, `software`, `parameters`, `outputRefs`, `timestampUnix` |
| `MPGOInstrumentConfig` | `NSObject` | `NSCoding`, `NSCopying` | `manufacturer`, `model`, `serialNumber`, `sourceType`, `analyzerType`, `detectorType` |
| `MPGOSpectrumIndex` | `NSObject` | — | `offsets`, `lengths`, `retentionTimes`, `msLevels`, `polarities`, `precursorMzs`, `precursorCharges`, `basePeakIntensities` (parallel C arrays) |
| `MPGOTransitionList` | `NSObject` | — | ordered `MPGOTransition` array |
| `MPGOMSImage` | `NSObject` | — | `width`, `height`, `spectralPoints`, `tileSize`, `cube`; tile-aligned 3-D HDF5 storage |
| `MPGOQuery` | `NSObject` | — | builder over `MPGOSpectrumIndex`; predicates: RT, MS level, polarity, precursor m/z, base peak |
| `MPGOStreamWriter` / `MPGOStreamReader` | `NSObject` | — | incremental append with periodic flush; sequential read |
| `MPGOEncryptionManager` | `NSObject` | — | static AES-256-GCM helpers (OpenSSL EVP) |
| `MPGOAccessPolicy` | `NSObject` | `NSCopying` | JSON-encoded policy persisted under `/protection/access_policies` |

---

## Layer 3 — Concrete Domain Classes

| Class | Extends | Domain-Specific Properties |
|---|---|---|
| `MPGOMassSpectrum` | `MPGOSpectrum` | `mzArray`, `intensityArray` (mandatory, equal length); `msLevel`, `polarity`, `scanWindow` (optional) |
| `MPGONMRSpectrum` | `MPGOSpectrum` | `chemicalShiftArray`, `intensityArray`, `nucleusType`, `spectrometerFrequencyMHz` |
| `MPGONMR2DSpectrum` | `MPGOSpectrum` | `intensityMatrix` (flattened row-major float64), `width`, `height`, `f1Axis`, `f2Axis`, `nucleusF1`, `nucleusF2` |
| `MPGOFreeInductionDecay` | `MPGOSignalArray` | Complex128 buffer (interleaved real/imag), `dwellTimeSeconds`, `scanCount`, `receiverGain` |
| `MPGOChromatogram` | `MPGOSpectrum` | `timeArray`, `intensityArray`, `type` (TIC / XIC / SRM), `targetMz`, `precursorProductMz`, `productMz` |
| `MPGOTransition` / `MPGOTransitionList` | `NSObject` | precursor → product m/z, collision energy, RT window |

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
  (`project.entry-points."mpeg_o.providers"` in `pyproject.toml`).
* **Java** — `java.util.ServiceLoader` with a service file at
  `META-INF/services/com.dtwthalion.mpgo.providers.StorageProvider`.
* **ObjC** — `+load` registration into `MPGOProviderRegistry`.

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

Transport is **orthogonal** to storage. Python's `Hdf5Provider.open`
routes cloud URLs (`s3://…`, `http://…`) through `fsspec` so
S3/HTTP access works without a separate transport class. Java
cloud access and ObjC ROS3 are deferred to v0.7+ (see
`HANDOFF.md`).

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
| `Hdf5Provider.native_handle()` | Returns underlying `h5py.File` / `Hdf5File` / `MPGOHDF5File` for byte-level code that hasn't been ported yet |
| `EncryptionManager` (`encrypt_intensity_channel_in_group` + `read_encrypted_channel`) | **Provider-aware** — both helpers dispatch via isinstance: HDF5 keeps the legacy multi-dataset rewrite path, non-HDF5 routes through StorageGroup `create_dataset` / `open_dataset` / `delete_child` (M64.5 phase B) |
| `SignatureManager` (`sign_dataset` / `verify_dataset`) | **Provider-aware** — h5py callers go through the legacy fast path; `StorageDataset` callers delegate to the M54.1 `sign_storage_dataset` / `verify_storage_dataset` siblings (M64.5 phase B) |
| `Anonymizer.anonymize` | **Provider-aware** — accepts a `provider=` kwarg passed through to `write_minimal` (M64.5 phase B) |
| `MSImage` cube writes | **Still native** — use `dataset.provider.native_handle()` (M64.5 phase C candidate) |
| `KeyRotationManager` (`enable_envelope_encryption` / `unwrap_dek` / `rotate_key` / `key_history`) | **Still native** — operates on `h5py.File`; envelope key wrap + multi-step rotation is the largest remaining surface (M64.5 phase C) |

**Cross-provider proof.** `python/tests/integration/test_mzml_roundtrip.py`
and `test_nmrml_roundtrip.py` parametrize over all four providers and
round-trip mzML / nmrML through `Memory`, `SQLite`, `Zarr` backends
in CI. `python/tests/security/test_protection_cross_provider.py`
extends the same matrix to encrypt-then-decrypt and sign-then-verify
paths, proving the protection classes are correct across backends
(12 cells, all green). The remaining `MSImage` cube writes and
`KeyRotationManager` are scoped for M64.5 phase C and are not on the
v0.9.0 release blocker list.

---

## HDF5 Container Mapping

MPEG-O files are HDF5 files with the `.mpgo` extension. The internal hierarchy mirrors the MPEG-G file model:

```
/                                       # Root (= MPEG-G File)
├── @mpeg_o_version                     # "1.0.0"
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
- (BOOL)writeToGroup:(MPGOHDF5Group *)group name:(NSString *)name error:(NSError **)error;
+ (instancetype)readFromGroup:(MPGOHDF5Group *)group name:(NSString *)name error:(NSError **)error;
```

In-memory objects can be constructed, mutated, and held without
touching HDF5 at all — persistence is explicit. `MPGOSpectralDataset`
provides file-level entry points (`-writeToFilePath:error:` /
`+readFromFilePath:error:`) and `MPGOStreamWriter` / `MPGOStreamReader`
support incremental ingestion of large runs.

## Thread Safety

**Opt-in reader-writer locking since v0.4 (Milestone 23).**

### Objective-C: `MPGOHDF5File`

Each `MPGOHDF5File` owns a `pthread_rwlock_t`. Every public method on
`MPGOHDF5Group` and `MPGOHDF5Dataset` acquires either the shared (read)
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
the dataset carries an `mpeg_o._rwlock.RWLock` (writer-preferring,
stdlib-only). `read_lock()` and `write_lock()` are context managers that
are *no-ops* when `thread_safe` was not requested, so call sites can use
them unconditionally:

```python
with SpectralDataset.open("dataset.mpgo", thread_safe=True) as ds:
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
`MPGO` prefix. Files under `python/src/mpeg_o/` are keyed by
snake_case module names.

| Objective-C class                | Python class                              | Module                              |
|----------------------------------|-------------------------------------------|-------------------------------------|
| `MPGOSignalArray`                | `SignalArray`                             | `mpeg_o.signal_array`               |
| `MPGOSpectrum`                   | `Spectrum`                                | `mpeg_o.spectrum`                   |
| `MPGOMassSpectrum`               | `MassSpectrum`                            | `mpeg_o.mass_spectrum`              |
| `MPGONMRSpectrum`                | `NMRSpectrum`                             | `mpeg_o.nmr_spectrum`               |
| `MPGONMR2DSpectrum`              | `NMR2DSpectrum`                           | `mpeg_o.nmr_2d`                     |
| `MPGOFreeInductionDecay`         | `FreeInductionDecay`                      | `mpeg_o.fid`                        |
| `MPGOChromatogram`               | `Chromatogram`                            | `mpeg_o.chromatogram`               |
| `MPGOAcquisitionRun`             | `AcquisitionRun` + `SpectrumIndex`        | `mpeg_o.acquisition_run`            |
| `MPGOSpectralDataset`            | `SpectralDataset`                         | `mpeg_o.spectral_dataset`           |
| `MPGOMSImage`                    | `MSImage`                                 | `mpeg_o.ms_image`                   |
| `MPGOIdentification`             | `Identification`                          | `mpeg_o.identification`             |
| `MPGOQuantification`             | `Quantification`                          | `mpeg_o.quantification`             |
| `MPGOProvenanceRecord`           | `ProvenanceRecord`                        | `mpeg_o.provenance`                 |
| `MPGOTransitionList`             | `TransitionList` / `Transition`           | `mpeg_o.transition_list`            |
| `MPGOFeatureFlags`               | `FeatureFlags`                            | `mpeg_o.feature_flags`              |
| `MPGOInstrumentConfig`           | `InstrumentConfig`                        | `mpeg_o.instrument_config`          |
| `MPGOEncryptionManager`          | `mpeg_o.encryption` module                | `mpeg_o.encryption`                 |
| `MPGOSignatureManager`           | `mpeg_o.signatures` module                | `mpeg_o.signatures`                 |
| `MPGONumpress`                   | `mpeg_o._numpress` module                 | `mpeg_o._numpress`                  |
| `MPGOMzMLReader` (Apache-2.0)    | `mpeg_o.importers.mzml`                   | `mpeg_o.importers.mzml`             |
| `MPGONmrMLReader` (Apache-2.0)   | `mpeg_o.importers.nmrml`                  | `mpeg_o.importers.nmrml`            |
| `MPGOMzMLWriter` (Apache-2.0)    | `mpeg_o.exporters.mzml`                   | `mpeg_o.exporters.mzml`             |
| `MPGOCVTermMapper`               | `mpeg_o.importers.cv_term_mapper`         | `mpeg_o.importers.cv_term_mapper`   |
| *(new in v0.3)*                  | `mpeg_o.remote` (fsspec URL dispatcher)   | `mpeg_o.remote`                     |

---

## Java Class Mapping (v0.5, M31–M35)

| ObjC Class | Java Class | Package |
|------------|-----------|---------|
| `MPGOSignalArray` | `SignalArray` | `com.dtwthalion.mpgo` |
| `MPGOSpectrum` | `Spectrum` | `com.dtwthalion.mpgo` |
| `MPGOMassSpectrum` | `MassSpectrum` | `com.dtwthalion.mpgo` |
| `MPGONMRSpectrum` | `NMRSpectrum` | `com.dtwthalion.mpgo` |
| `MPGONMR2DSpectrum` | `NMR2DSpectrum` | `com.dtwthalion.mpgo` |
| `MPGOFreeInductionDecay` | `FreeInductionDecay` | `com.dtwthalion.mpgo` |
| `MPGOChromatogram` | `Chromatogram` | `com.dtwthalion.mpgo` |
| `MPGOSpectrumIndex` | `SpectrumIndex` | `com.dtwthalion.mpgo` |
| `MPGOAcquisitionRun` | `AcquisitionRun` | `com.dtwthalion.mpgo` |
| `MPGOSpectralDataset` | `SpectralDataset` | `com.dtwthalion.mpgo` |
| `MPGOMSImage` | `MSImage` | `com.dtwthalion.mpgo` |
| `MPGOFeatureFlags` | `FeatureFlags` | `com.dtwthalion.mpgo` |
| `MPGOIdentification` | `Identification` | `com.dtwthalion.mpgo` (record) |
| `MPGOQuantification` | `Quantification` | `com.dtwthalion.mpgo` (record) |
| `MPGOProvenanceRecord` | `ProvenanceRecord` | `com.dtwthalion.mpgo` (record) |
| `MPGOEncryptionManager` | `EncryptionManager` | `com.dtwthalion.mpgo.protection` |
| `MPGOSignatureManager` | `SignatureManager` | `com.dtwthalion.mpgo.protection` |
| `MPGOKeyRotationManager` | `KeyRotationManager` | `com.dtwthalion.mpgo.protection` |
| `MPGOAnonymizer` | `Anonymizer` | `com.dtwthalion.mpgo.protection` |
| `MPGOMzMLReader` | `MzMLReader` | `com.dtwthalion.mpgo.importers` |
| `MPGOMzMLWriter` | `MzMLWriter` | `com.dtwthalion.mpgo.exporters` |
| `MPGONmrMLReader` | `NmrMLReader` | `com.dtwthalion.mpgo.importers` |
| `MPGONmrMLWriter` | `NmrMLWriter` | `com.dtwthalion.mpgo.exporters` |
| `MPGOISAExporter` | `ISAExporter` | `com.dtwthalion.mpgo.exporters` |
| `MPGONumpress` | `NumpressCodec` | `com.dtwthalion.mpgo` |
| `MPGOHDF5File` | `Hdf5File` | `com.dtwthalion.mpgo.hdf5` |
| `MPGOHDF5Group` | `Hdf5Group` | `com.dtwthalion.mpgo.hdf5` |
| `MPGOHDF5Dataset` | `Hdf5Dataset` | `com.dtwthalion.mpgo.hdf5` |

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
| **zlib** (default) | `H5P_DEFLATE` filter, level 6                | No     | `MPGOCompressionZlib` via `H5Pset_deflate`            | `compression="gzip"` on `h5py.create_dataset`     |
| **LZ4**            | HDF5 filter 32004 (plugin-gated)             | No     | `MPGOCompressionLZ4` via `H5Pset_filter(32004)`       | `compression="lz4"` via `hdf5plugin.LZ4()`        |
| **Numpress-delta** | MPGO transform → int64 deltas + zlib         | Yes    | `MPGOCompressionNumpressDelta` via `MPGONumpress`     | `signal_compression="numpress_delta"`             |

LZ4 availability is runtime-detected via `H5Zfilter_avail(32004)` in ObjC and `hdf5plugin.PLUGIN_PATH` + `h5py.h5z.filter_avail(32004)` in Python; both implementations skip their LZ4 tests cleanly when the filter is absent. Numpress-delta is always available because it is a pure-library transform that produces an ordinary int64 HDF5 dataset.

---

## Cloud-native access (v0.3, M20, Python-only)

`SpectralDataset.open("s3://bucket/file.mpgo")` detects URL schemes via `mpeg_o.remote.is_remote_url` and routes them through `fsspec.open(url, "rb")`. The resulting seekable byte stream is handed to `h5py.File`, which then reads only the HDF5 chunks touched by the caller. Supported schemes include `file://`, `http(s)://`, `s3://`, `gs://`, `gcs://`, `az://`, `abfs(s)://`; the backend dependencies live behind the `cloud` optional extra.

Performance characteristics (observed on a 15 MB fixture served over localhost with a 64 KiB fsspec block cache):

- 10 random spectra from a 1,000-spectrum file: ~50 ms wall clock.
- Fraction of file bytes actually transferred: ~24%.

The Objective-C implementation reads only POSIX files in v0.3 because `libhdf5` consumes files via Virtual File Drivers (VFDs) rather than arbitrary byte streams. Integrating `libhdf5`'s ROS3 VFD (or a custom libcurl-backed VFD) is a tracked follow-up in `WORKPLAN.md`.

---

## Implementation notes (v0.1.0-alpha)

A few deliberate simplifications keep v0.1's surface area small. None
affect on-disk readability via standard HDF5 tools.

* **`MPGOEncryptable` is delegated, not directly conformed.**
  `MPGOAcquisitionRun` and `MPGOSpectralDataset` do not yet conform to
  `MPGOEncryptable` themselves; selective encryption of the intensity
  channel is performed via the static `MPGOEncryptionManager` API
  against an open `.mpgo` path. A v0.2 milestone may thread the
  protocol through both classes' init/read paths.

* **`MPGOProvenanceable` is satisfied at the dataset level.**
  Provenance is stored as an array of `MPGOProvenanceRecord` on
  `MPGOSpectralDataset` rather than per-run. The dataset-level
  `-provenanceRecordsForInputRef:` query satisfies the workplan
  acceptance criterion.

* **Identifications, quantifications, and provenance are JSON-encoded.**
  Stored as JSON strings under `/study/`'s scalar attributes rather than
  as bespoke HDF5 compound types. The data is fully round-trippable and
  inspectable with any JSON-aware tool, at the cost of slightly larger
  on-disk footprint than a packed compound layout.

* **`MPGOSpectrumIndex` uses parallel 1-D datasets.** The MPEG-G design
  spec calls for a single compound `headers` dataset; v0.1 stores eight
  parallel datasets (offsets, lengths, retention_times, ms_levels,
  polarities, precursor_mzs, precursor_charges, base_peak_intensities)
  for simpler readout from non-Cocoa tools and a smaller HDF5 wrapper
  surface.

* **`MPGOMSImage` is standalone, not a `MPGOSpectralDataset` subclass.**
  The cube lives under `/image_cube/` and can coexist with a `/study/`
  written by `MPGOSpectralDataset` in the same `.mpgo` file. Inheritance
  may be added in a later milestone.

* **Mass-spectrum runs only.** `MPGOAcquisitionRun` accepts only
  `MPGOMassSpectrum` instances. NMR runs live as named arrays of
  `MPGONMRSpectrum` directly under `MPGOSpectralDataset.nmrRuns`. Mixed
  runs are a planned post-1.0 extension.

* **`MPGONMR2DSpectrum` flattens its matrix.** The 2-D intensity matrix
  is stored as a 1-D `MPGOSignalArray` with `width` × `height` bytes
  plus shape attributes, rather than a native 2-D HDF5 dataset. Round-
  trip equality is byte-exact; native multi-dim datasets may follow.

* **`-fblocks` is disabled on the apt gnustep-1.8 toolchain path.**
  `libMPGO` itself uses no block-based APIs; CI builds against
  source-built `libobjc2` (gnustep-2.0 non-fragile ABI) where blocks
  are available.
