# MPEG-O Architecture

MPEG-O adapts the MPEG-G (ISO/IEC 23092) architectural pattern — hierarchical containers, descriptor streams, access units, selective encryption, and compressed-domain query — to the needs of multi-omics analytical data, specifically mass spectrometry and NMR spectroscopy.

The Objective-C reference implementation expresses this architecture in three layers:

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

**Not thread-safe in v0.1.** Concurrent access to a single `MPGOHDF5File` from multiple threads is undefined. Clients must serialize access externally. A future version may adopt HDF5's thread-safe build (`--enable-threadsafe`) with explicit locking.

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
