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

| Class | Inherits | Conforms To | Key Properties |
|---|---|---|---|
| `MPGOSignalArray` | `NSObject` | `MPGOCVAnnotatable` | `dataType`, `buffer` (NSData), `axisDescriptor`, `encodingSpec`, `cvAnnotations` |
| `MPGOAxisDescriptor` | `NSObject` | — | `name`, `unit`, `valueRange`, `samplingMode` (uniform / non-uniform) |
| `MPGOEncodingSpec` | `NSObject` | — | `precision`, `compressionAlgorithm`, `byteOrder` |
| `MPGOValueRange` | `NSObject` | — | `minimum`, `maximum` |
| `MPGOCVParam` | `NSObject` | — | `ontologyRef`, `accession`, `name`, `value`, `unit` |
| `MPGOSpectrum` | `NSObject` | `MPGOCVAnnotatable`, `MPGOIndexable` | `signalArrays` (NSDictionary), `coordinateAxes`, `indexPosition`, `scanTime`, `precursorInfo` |
| `MPGOAcquisitionRun` | `NSObject` | `MPGOIndexable`, `MPGOStreamable`, `MPGOProvenanceable`, `MPGOEncryptable` | `spectra`, `chromatograms`, `instrumentConfig`, `sourceFiles`, `provenance` |
| `MPGOSpectralDataset` | `NSObject` | `MPGOIndexable`, `MPGOEncryptable`, `MPGOProvenanceable` | `runs`, `identifications`, `quantifications`, `studyMetadata` |
| `MPGOIdentification` | `NSObject` | `MPGOCVAnnotatable` | `spectrumRef`, `chemicalEntity`, `confidenceScore`, `evidenceChain` |
| `MPGOQuantification` | `NSObject` | `MPGOCVAnnotatable` | `abundanceValue`, `sampleRef`, `normalizationMetadata` |
| `MPGOProvenanceRecord` | `NSObject` | — | `inputEntities`, `software`, `parameters`, `outputEntities`, `timestamp` |
| `MPGOInstrumentConfig` | `NSObject` | `MPGOCVAnnotatable` | `manufacturer`, `model`, `serialNumber`, `sourceType`, `analyzerType`, `detectorType` |
| `MPGOSpectrumIndex` | `NSObject` | — | `offsets` (uint64[]), `lengths` (uint32[]), `headers` (compound[]) |

---

## Layer 3 — Concrete Domain Classes

| Class | Extends | Domain-Specific Properties |
|---|---|---|
| `MPGOMassSpectrum` | `MPGOSpectrum` | `mzArray`, `intensityArray` (mandatory); `ionMobilityArray` (optional); `msLevel`, `polarity`, `scanWindow` |
| `MPGONMRSpectrum` | `MPGOSpectrum` | `chemicalShiftArray`, `intensityArray`, `nucleusType`, `spectrometerFrequency` |
| `MPGONMR2DSpectrum` | `MPGOSpectrum` | `intensityMatrix` (2D SignalArray), `f1AxisDescriptor`, `f2AxisDescriptor`, `experimentType` |
| `MPGOFreeInductionDecay` | `MPGOSignalArray` | `realComponent`, `imaginaryComponent`, `dwellTime`, `numberOfScans`, `receiverGain` |
| `MPGOChromatogram` | `NSObject` (`MPGOCVAnnotatable`) | `timeArray`, `intensityArray`, `chromatogramType` (TIC / XIC / SRM) |
| `MPGOMSImage` | `MPGOSpectralDataset` | `spatialDimensions`, `pixelSize`, `scanPattern`, `gridSpectra` |
| `MPGOTransitionList` | `NSObject` | `transitions` (precursor→product with RT windows, collision energy) |

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
- (BOOL)writeToHDF5Group:(MPGOHDF5Group *)group withName:(NSString *)name error:(NSError **)error;
+ (instancetype)readFromHDF5Group:(MPGOHDF5Group *)group withName:(NSString *)name error:(NSError **)error;
```

In-memory objects can be constructed, mutated, and held without touching HDF5 at all — persistence is explicit. The `MPGOSpectralDataset` class wraps an `MPGOHDF5File` and provides stream writers/readers for incremental ingestion.

## Thread Safety

**Not thread-safe in v0.1.** Concurrent access to a single `MPGOHDF5File` from multiple threads is undefined. Clients must serialize access externally. A future version may adopt HDF5's thread-safe build (`--enable-threadsafe`) with explicit locking.
