# MPEG-O — Java Implementation

Java implementation of the MPEG-O multi-omics spectral data container,
mirroring the Objective-C reference implementation architecture.

Package: `com.dtwthalion.mpgo`  
License: LGPL-3.0-or-later (core), Apache-2.0 (importers/exporters)

## Prerequisites

- JDK 17+
- Maven 3.8+
- System HDF5 libraries with Java bindings:

```bash
# Ubuntu/Debian
sudo apt-get install libhdf5-dev libhdf5-java libhdf5-jni
```

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
| HDF5 wrappers | `com.dtwthalion.mpgo.hdf5` | `Hdf5File`, `Hdf5Group`, `Hdf5Dataset`, `Hdf5CompoundType` |
| Enums | `com.dtwthalion.mpgo` | `Enums.Precision`, `Enums.Compression`, etc. |
| Core (M32+) | `com.dtwthalion.mpgo` | `SignalArray`, `Spectrum`, `AcquisitionRun`, `SpectralDataset` |

See [`../ARCHITECTURE.md`](../ARCHITECTURE.md) and [`../WORKPLAN.md`](../WORKPLAN.md)
for the canonical class hierarchy and milestone plan.

## Test Fixtures

Test resources at `src/test/resources/mpgo/` are symlinked to the canonical
ObjC fixtures at `objc/Tests/Fixtures/mpgo/`. These are the cross-language
conformance files used by all three implementations.
