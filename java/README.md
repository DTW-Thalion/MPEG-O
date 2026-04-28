# TTI-O — Java Implementation

Java implementation of the TTI-O multi-omics spectral data container,
at full feature parity with the Objective-C and Python implementations.

Package: `global.thalion.ttio`
License: LGPL-3.0-or-later (core), Apache-2.0 (importers/exporters)

## Prerequisites

- JDK 17+
- Maven 3.8+
- System HDF5 libraries with Java bindings:

```bash
# Ubuntu/Debian
sudo apt-get install libhdf5-dev libhdf5-java libhdf5-jni
```

**Note:** CI uses the same `apt` packages. GitHub Packages auth
(for `hdf5-java-jni` 2.0+) is not required when using system packages.

## Build & Test

```bash
cd java
mvn verify -B
```

The Surefire plugin is configured with `-Djava.library.path` pointing to
the system HDF5 JNI shared library. If your distro installs it elsewhere,
override via:

```bash
mvn verify -Dhdf5.native.path=/path/to/jni/dir
```

## Architecture

The Java implementation mirrors the three-layer ObjC/Python pattern:

| Layer | Java Package | Description |
|-------|-------------|-------------|
| HDF5 wrappers | `global.thalion.ttio.hdf5` | `Hdf5File`, `Hdf5Group`, `Hdf5Dataset`, `Hdf5CompoundIO`, `NativeStringPool`, `NativeBytesPool` |
| Storage providers | `global.thalion.ttio.providers` | `Hdf5Provider`, `MemoryProvider`, `SqliteProvider`, `ZarrProvider` (`StorageProvider` / `StorageGroup` / `StorageDataset` protocols) |
| Protocols | `global.thalion.ttio.protocols` | `Run`, `Indexable`, `Streamable`, `Provenanceable`, `Encryptable`, `CVAnnotatable` |
| Core + enums | `global.thalion.ttio` | `SignalArray`, `Spectrum`, `AcquisitionRun`, `SpectralDataset`, `FeatureFlags`, `NumpressCodec`, `ProvenanceRecord` |
| Genomics | `global.thalion.ttio.genomics` | `AlignedRead`, `GenomicIndex`, `GenomicRun`, `WrittenGenomicRun` |
| Codecs | `global.thalion.ttio.codecs` | `Rans`, `BasePack`, `QualityBinned`, `NameTokenizer` |
| Transport | `global.thalion.ttio.transport` | `TransportWriter`, `TransportReader`, `AUFilter`, `WebSocketServer`, `WebSocketClient` |
| Importers | `global.thalion.ttio.importers` | `MzMLReader`, `NmrMLReader`, `CVTermMapper`, `BamReader`, `CramReader` |
| Exporters | `global.thalion.ttio.exporters` | `MzMLWriter`, `NmrMLWriter`, `ISAExporter`, `BamWriter`, `CramWriter` |
| Protection | `global.thalion.ttio.protection` | `EncryptionManager`, `SignatureManager`, `KeyRotationManager`, `Anonymizer`, `PostQuantumCrypto` |

See [`../ARCHITECTURE.md`](../ARCHITECTURE.md) for the full class mapping
table and design notes.

## Test Suite (755 tests, 0 failures, 0 errors, 0 skipped)

The suite spans HDF5 wrappers, the four storage providers, all six data
primitives, the genomic stack (M82 + M83–M86 codec wiring + M87/M88
SAM/BAM/CRAM importers + M88 exporters), the .tis transport (M89
including genomic AU multiplexing), full M90 genomic encryption +
signatures + anonymisation, the Phase 1+2 abstraction polish (`Run`
protocol conformance + modality-agnostic helpers + per-run compound
provenance dual-write/dual-read), and the cross-language byte-parity
harness (M51 dumper + M82.4 genomic conformance fixtures + M86 codec
fixtures).

## Test Fixtures

Test resources at `src/test/resources/ttio/` contain the canonical ObjC
reference `.tio` files. XML fixtures (`tiny.pwiz.1.1.mzML`,
`bmse000325.nmrML`, `1min.mzML`) are used for import round-trip testing.

## Cross-Language Compatibility

The Java implementation is byte-compatible with ObjC and Python for:
- AES-256-GCM encryption (same IV/tag layout, same ciphertext)
- HMAC-SHA256 `v2:` canonical signatures (little-endian normalization)
- Numpress-delta encoding (deterministic scale + delta output)
- HDF5 signal channel layout (chunked float64, zlib level 6)
- Feature flag JSON serialization
