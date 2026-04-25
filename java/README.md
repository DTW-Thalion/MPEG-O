# TTI-O — Java Implementation

Java implementation of the TTI-O multi-omics spectral data container,
at full feature parity with the Objective-C and Python implementations.

Package: `com.dtwthalion.ttio`
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
| HDF5 wrappers | `com.dtwthalion.ttio.hdf5` | `Hdf5File`, `Hdf5Group`, `Hdf5Dataset`, `Hdf5CompoundType` |
| Core + enums | `com.dtwthalion.ttio` | `SignalArray`, `Spectrum`, `AcquisitionRun`, `SpectralDataset`, `FeatureFlags`, `NumpressCodec` |
| Importers | `com.dtwthalion.ttio.importers` | `MzMLReader`, `NmrMLReader`, `CVTermMapper`, `ThermoRawReader` (stub) |
| Exporters | `com.dtwthalion.ttio.exporters` | `MzMLWriter`, `NmrMLWriter`, `ISAExporter` |
| Protection | `com.dtwthalion.ttio.protection` | `EncryptionManager`, `SignatureManager`, `KeyRotationManager`, `Anonymizer` |

See [`../ARCHITECTURE.md`](../ARCHITECTURE.md) for the full 28-class mapping
table and design notes.

## Test Suite (62 tests)

| Test Class | Count | Coverage |
|-----------|-------|---------|
| `Hdf5FileTest` | 8 | File/group/attribute operations |
| `Hdf5DatasetTest` | 9 | All precisions, compression, hyperslab |
| `SpectralDatasetTest` | 9 | Round-trips, fixtures, MSImage |
| `ImportExportTest` | 10 | mzML, nmrML, ISA, Thermo stub |
| `ProtectionTest` | 14 | Encrypt, sign, key rotation, anonymize |
| `AdvancedFeaturesTest` | 12 | Thread safety, LZ4, Numpress-delta |

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
