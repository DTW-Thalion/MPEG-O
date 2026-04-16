# MPEG-O

[![MPGO CI](https://github.com/DTW-Thalion/MPEG-O/actions/workflows/ci.yml/badge.svg)](https://github.com/DTW-Thalion/MPEG-O/actions/workflows/ci.yml)
[![License: LGPL v3 (core) / Apache-2.0 (import/export)](https://img.shields.io/badge/License-LGPL_v3_%2F_Apache--2.0-blue.svg)](https://www.gnu.org/licenses/lgpl-3.0)
[![Python: 3.11+](https://img.shields.io/badge/python-3.11%2B-blue.svg)](https://www.python.org/)

**MPEG-O** is a reference implementation of a unified multi-omics data standard that brings mass spectrometry (MS) and nuclear magnetic resonance (NMR) spectroscopy data under a single container, class hierarchy, and access model. Its architecture is modeled on **MPEG-G** (ISO/IEC 23092), the ISO/IEC standard for genomic information representation, adapting MPEG-G's hierarchical access units, descriptor streams, selective encryption, and compressed-domain query model to the needs of analytical spectroscopy and spectrometry.

The standard is built around **six shared data primitives** and an **HDF5-based container** that mirrors the MPEG-G file model.

## The Six Data Primitives

| Primitive | Purpose |
|---|---|
| **SignalArray** | Typed, axis-annotated numeric buffer with encoding spec (float32/64, int32, complex128). The atomic unit of measured signal. |
| **Spectrum** | Named dictionary of SignalArrays with coordinate axes and controlled-vocabulary metadata. The generic spectral observation. |
| **AcquisitionRun** | Ordered, indexable, streamable collection of Spectrum objects sharing an instrument configuration and provenance chain. |
| **CVAnnotation** | Controlled-vocabulary parameter (ontology reference + accession + value + unit) attached to any annotatable object. |
| **Identification** | Link from a spectrum (or spectrum region) to a chemical entity, with confidence score and evidence chain. |
| **ProvenanceRecord** | W3C PROV-compatible record of processing history: input entities → activity → output entities. |

## MPEG-G → MPEG-O Architectural Mapping

| MPEG-G Concept | MPEG-O Equivalent |
|---|---|
| File | `.mpgo` HDF5 container |
| Dataset Group | `MPGOSpectralDataset` (= ISA Investigation / Study root) |
| Dataset | `MPGOAcquisitionRun` |
| Access Unit | `MPGOSpectrumIndex` entry + associated signal-channel slice |
| Descriptor Streams | `/signal_channels/` HDF5 datasets (m/z, intensity, ion mobility, scan metadata) |
| Data Classes | Acquisition modes (MS1, MS2, DIA, SRM, 1D-NMR, 2D-NMR, …) |
| Multi-level Protection | `MPGOEncryptable` protocol with per-dataset, per-stream, and per-AU encryption |
| Compressed-domain Query | `MPGOQuery` scanning AU headers without decompressing signal data |

## Implementation Streams

This repository hosts three implementation streams. The **Objective-C** stream under `objc/` is the normative reference implementation.

| Stream | Status | Directory |
|---|---|---|
| **Objective-C (GNUstep)** | **v0.4.0 — Milestones 1–25, 27–29 complete, 836 assertions passing** | `objc/` |
| **Python (`mpeg-o`)**     | **v0.4.0 — Cross-language parity with ObjC, 120 tests passing** | `python/` |
| Java | v0.5.0 — Full feature parity (M31–M36). Maven + JDK 17. | `java/` |

### v0.1.0-alpha capabilities

* **Foundation** — five capability protocols (`MPGOIndexable`, `MPGOStreamable`, `MPGOCVAnnotatable`, `MPGOProvenanceable`, `MPGOEncryptable`) plus the immutable value classes `MPGOValueRange`, `MPGOEncodingSpec`, `MPGOAxisDescriptor`, `MPGOCVParam`.
* **HDF5 wrappers** — thin Cocoa wrappers over the libhdf5 C API (`MPGOHDF5File`, `MPGOHDF5Group`, `MPGOHDF5Dataset`, `MPGOHDF5Errors`, `MPGOHDF5Types`) supporting `float32` / `float64` / `int32` / `int64` / `uint32` / `complex128` (compound), chunked storage, and zlib compression. Hyperslab partial reads, automatic runtime ABI detection, and `NSError` out-parameters on every fallible call.
* **Signal arrays** — `MPGOSignalArray` is the atomic typed-buffer unit, conforms to `MPGOCVAnnotatable`, and round-trips through HDF5 with axis descriptors and JSON-encoded CV annotations.
* **Spectrum classes** — `MPGOSpectrum` base plus `MPGOMassSpectrum`, `MPGONMRSpectrum`, `MPGONMR2DSpectrum`, `MPGOFreeInductionDecay` (Complex128-backed), and `MPGOChromatogram` (TIC/XIC/SRM).
* **Acquisition runs** — `MPGOAcquisitionRun` conforms to `MPGOIndexable` + `MPGOStreamable`. Writing channelizes every spectrum into contiguous `mz_values` + `intensity_values` datasets; reading is lazy and uses HDF5 hyperslab selection so a random-access spectrum read only touches its own chunks. `MPGOSpectrumIndex` carries seven parallel scan-metadata arrays (offsets, lengths, RT, MS level, polarity, precursor m/z, base peak) for compressed-domain queries.
* **Spectral datasets** — `MPGOSpectralDataset` is the root `.mpgo` container object. Holds named MS runs, named NMR-spectrum collections, identifications, quantifications, W3C PROV provenance records, and SRM/MRM transition lists. Multi-run round-trip and provenance lookup by input ref are first-class.
* **MS imaging** — `MPGOMSImage` stores a 3-D `[height, width, spectralPoints]` HDF5 dataset with tile-aligned chunking; tile reads (default 32×32 pixels) hit exactly the chunks they need.
* **Selective encryption** — `MPGOEncryptionManager` (AES-256-GCM via OpenSSL) encrypts an acquisition run's intensity channel in place while leaving `mz_values` and the spectrum index readable as plaintext. Wrong keys fail cleanly via GCM tag mismatch — never partial bytes. `MPGOAccessPolicy` persists JSON-encoded subject/stream/key-id metadata under `/protection/access_policies` independently of any key store.
* **Query + streaming** — `MPGOQuery` builds compressed-domain predicates (RT range, MS level, polarity, precursor m/z range, base peak threshold) over an in-memory index without touching signal channels; a 10k-spectrum scan runs in ~0.2 ms in CI. `MPGOStreamWriter` / `MPGOStreamReader` provide incremental write + sequential read over runs of arbitrary size.

Continuous integration runs every push on `ubuntu-latest` with **clang + libobjc2 + gnustep-base built from source** (the `gnustep-2.0` non-fragile ABI), then exercises the full test suite.

### v0.2.0 capabilities (additions to v0.1)

* **mzML import** — `MPGOMzMLReader` is a SAX parser (`NSXMLParser`) that consumes PSI-MS mzML 1.1 files, decodes base64 binary arrays (with optional zlib inflate), maps CV accessions via `MPGOCVTermMapper`, and produces an `MPGOSpectralDataset` with a populated MS run. Tested against the canonical `tiny.pwiz.1.1.mzML` and `1min.mzML` fixtures from HUPO-PSI.
* **nmrML import** — `MPGONmrMLReader` handles nmrML 1.0+ including vendor-realistic files: element-based acquisition parameters, int32/int64 FID payloads widened to complex128 on import, dimension scale extraction. Validated against `bmse000325.nmrML` from the BMRB via the nmrML project.
* **Modality-agnostic runs** — `MPGOAcquisitionRun` now accepts any `MPGOSpectrum` subclass. Signal channel serialization is name-driven (`<channel>_values`), so MS runs are binary-compatible with v0.1 while NMR runs produce `chemical_shift_values` + `intensity_values`. Runs formally conform to `<MPGOProvenanceable>` + `<MPGOEncryptable>` with per-run provenance chains, protocol-based encrypt/decrypt delegating to `MPGOEncryptionManager`.
* **Native HDF5 compound types** — identifications, quantifications, and dataset-level provenance migrate from JSON string attributes to native HDF5 compound datasets with variable-length C strings. Spectrum index carries an optional rank-1 `headers` compound dataset for `h5dump` readability alongside the parallel 1-D arrays. `MPGOHDF5CompoundType` wraps `H5Tcreate(H5T_COMPOUND, ...)` with VL string helpers.
* **Feature flags + format version** — every v0.2 file carries `@mpeg_o_format_version = "1.1"` and a JSON array `@mpeg_o_features` on the root group. `MPGOFeatureFlags` provides the registry; `opt_`-prefixed features are informational while non-prefixed features are required.
* **Dataset-level encryption** — `MPGOSpectralDataset` conforms to `<MPGOEncryptable>` end-to-end. A single `encryptWithKey:level:error:` call encrypts every run's intensity channel, seals the compound identification/quantification datasets, and writes the `@encrypted` root marker and `@access_policy_json`. `-closeFile` releases the HDF5 handle so the encryption manager can reopen read-write.
* **MSImage inheritance** — `MPGOMSImage` inherits from `MPGOSpectralDataset`, so image datasets carry identifications/quantifications/provenance/access-policy for free. The 3-D cube lives at `/study/image_cube/` with spatial metadata (`pixelSizeX/Y`, `scanPattern`); v0.1 `/image_cube/` layout remains readable via auto-detection.
* **Native 2-D NMR** — `MPGONMR2DSpectrum` writes a proper rank-2 HDF5 dataset (`intensity_matrix_2d`) with F1/F2 dimension scales attached via `H5DSattach_scale`. Readers prefer the native 2-D form and fall back to the v0.1 flattened 1-D array.
* **HMAC-SHA256 digital signatures** — `MPGOSignatureManager` signs HDF5 dataset bytes and provenance chains; `MPGOVerifier` reports Valid/Invalid/NotSigned/Error. 1M-element float64 sign + verify runs in ~15 ms combined.
* **Format specification** — [`docs/format-spec.md`](docs/format-spec.md) documents every group, dataset, attribute, and compound type in enough detail for a conforming Python/Rust/Go reader. [`docs/feature-flags.md`](docs/feature-flags.md) is the feature string registry. Reference `.mpgo` fixtures under `objc/Tests/Fixtures/mpgo/` (generated by `objc/Tools/MakeFixtures`) provide canonical smoke-test files.

v0.1 `.mpgo` files written by libMPGO v0.1.0-alpha remain fully readable by v0.2.0 code — the readers detect the absence of `@mpeg_o_features` and dispatch to JSON fallback paths.

### v0.3.0 capabilities (additions to v0.2)

* **Python `mpeg-o` package** — a full reader/writer for the `.mpgo` format built on `h5py` + `numpy`, mirroring the ObjC class hierarchy 1-to-1. Ships an editable layout under `python/src/mpeg_o/` with `importers/` (mzML + nmrML), `exporters/` (mzML), and `_numpress` codec helpers. PyPI name: **`mpeg-o`** (import as `mpeg_o`). Requires Python 3.11+. Every v0.2 reference fixture (`minimal_ms`, `full_ms`, `nmr_1d`, `encrypted`, `signed`) is loaded byte-compatibly by the Python reader, and a new `MpgoVerify` + `MpgoSign` ObjC CLI pair tests the other direction (Python-written files decoded by the ObjC reference reader).
* **Compound per-run provenance** — `MPGOAcquisitionRun` persists its provenance chain as a compound HDF5 dataset at `/study/ms_runs/<run>/provenance/steps`, reusing the 5-field type from dataset-level `/study/provenance`. The legacy `@provenance_json` mirror is kept in place so the v0.2 signature manager continues to work. Feature flag: `compound_per_run_provenance`.
* **Canonical byte-order signatures** — `MPGOSignatureManager` now hashes a canonical little-endian byte stream (atomic numeric datasets via LE memory types, compound datasets field-by-field with VL strings emitted as `u32_le(len) || bytes`). Signatures carry a `"v2:"` prefix; v0.2 native-byte signatures remain verifiable via an automatic fallback path. Cross-language byte-identical MACs between ObjC and Python by construction. Feature flag: `opt_canonical_signatures`.
* **mzML writer** — `MPGOMzMLWriter` + `mpeg_o.exporters.mzml` emit indexed-mzML from a `SpectralDataset`, with byte-correct `<indexList>` offsets per spectrum and optional zlib compression of binary arrays. Licensed Apache-2.0 alongside the import layer.
* **Cloud-native access (Python)** — `SpectralDataset.open("s3://bucket/file.mpgo")` routes URLs through `fsspec`. HTTP, S3, GCS, and Azure backends are supported through fsspec plugins; the reader pulls only the HDF5 metadata and a handful of chunks per touched spectrum. Benchmark: 10 random spectra from a 15 MB remote file in ~50 ms, ~24% of file bytes transferred.
* **LZ4 + Numpress-delta compression** — optional signal-channel codecs. LZ4 via HDF5 filter 32004 (plugin-gated, skipped cleanly at runtime when unavailable) is ~35× faster on write / ~2× faster on read than zlib. Numpress-delta is a clean-room implementation of Teleman et al. 2014 (*MCP* 13(6)) with sub-ppm relative error for typical m/z data. Both codecs are cross-language byte-identical between ObjC and Python.

### v0.4.0 capabilities (additions to v0.3)

* **Thread safety (M23)** — `MPGOHDF5File` carries a `pthread_rwlock_t` that serializes writes and allows concurrent reads. Python side: opt-in `SpectralDataset.open(..., thread_safe=True)` with a writer-preferring `RWLock`. Degrades to exclusive locking on non-threadsafe libhdf5 builds.
* **Chromatogram API (M24)** — `MPGOAcquisitionRun.chromatograms` persists TIC/XIC/SRM traces under `<run>/chromatograms/` with a parallel-array chromatogram index. mzML writer emits `<chromatogramList>` + `<index name="chromatogram">` with byte-correct offsets; reader parses them back.
* **Envelope encryption + key rotation (M25)** — DEK encrypts data, KEK wraps DEK. `/protection/key_info/` stores the 60-byte wrapped DEK blob + KEK metadata. Rotation re-wraps in O(1) without touching signal datasets. Feature flag: `opt_key_rotation`.
* **ISA-Tab / ISA-JSON export (M27)** — `MPGOISAExporter` / `mpeg_o.exporters.isa` produces investigation/study/assay TSV files + ISA-JSON from a `SpectralDataset`. Licensed Apache-2.0.
* **Spectral anonymization (M28)** — policy-based pipeline (SAAV redaction, intensity masking, m/z coarsening, rare-metabolite suppression, metadata stripping) that reads a dataset and writes a new `.mpgo`. Audit trail via provenance record. Feature flag: `opt_anonymized`.
* **nmrML writer (M29)** — serializes `NMRSpectrum` + FID to nmrML XML with acquisition parameters and base64 spectrum arrays. Round-trips through the existing nmrML reader.
* **Thermo RAW stub (M29)** — `MPGOThermoRawReader` / `mpeg_o.importers.thermo_raw` stub; returns not-implemented error with SDK guidance. See `docs/vendor-formats.md`.

## Python Installation

```bash
# Core reader/writer only
pip install mpeg-o

# With every optional extra (crypto, import, cloud, codecs)
pip install 'mpeg-o[all]'
```

Individual extras:

| Extra     | Pulls in                                    | Needed for                                            |
|-----------|---------------------------------------------|-------------------------------------------------------|
| `crypto`  | `cryptography>=41.0`                        | AES-256-GCM encryption / decryption of signal channels |
| `import`  | `lxml`                                      | mzML / nmrML importers (`mpeg_o.importers`)           |
| `cloud`   | `fsspec`, `s3fs`, `aiohttp`                 | `s3://` / `http(s)://` / `gs://` / `az://` open paths |
| `codecs`  | `hdf5plugin>=4.0`                           | LZ4 signal-channel compression                        |

### Python quick start

```python
from mpeg_o import SpectralDataset

with SpectralDataset.open("example.mpgo") as ds:
    run = ds.ms_runs["run_0001"]
    spectrum = run[0]                      # lazy read
    mz = spectrum.mz_array.data            # numpy float64
    intensity = spectrum.intensity_array.data

# Cloud-native access through fsspec:
with SpectralDataset.open("s3://my-bucket/run.mpgo", anon=False) as ds:
    ...
```

Run the Python test suite (requires libhdf5-dev + the `test` extra):

```bash
cd python
pip install -e '.[test,codecs]'
pytest
```

### Building the Java implementation

```bash
# Prerequisites: JDK 17+, Maven 3.8+, libhdf5-dev, libhdf5-java, libhdf5-jni
sudo apt-get install openjdk-17-jdk-headless maven libhdf5-dev libhdf5-java libhdf5-jni

cd java
mvn verify -B
```

## Building the Objective-C Reference Implementation

Requires **GNUstep Base**, **GNUstep Make**, a compatible **Objective-C compiler** (clang, ARC required), **libhdf5** (≥ 1.10), **zlib**, and **OpenSSL/libcrypto**. Optional: the LZ4 HDF5 filter plugin (filter id 32004) for `MPGOCompressionLZ4` support; M21 tests skip cleanly when the plugin isn't loadable.

### Ubuntu / Debian / WSL

```bash
sudo apt-get update
sudo apt-get install -y \
    gnustep-devel gnustep-make libgnustep-base-dev \
    libhdf5-dev zlib1g-dev libssl-dev \
    clang gobjc
```

### Build & Test

The `objc/build.sh` wrapper checks dependencies, sources the GNUstep
environment, and invokes `make` with `clang` selected as the Objective-C
compiler (the build requires ARC, which `gcc`'s `gobjc` does not support).

```bash
cd objc
./build.sh           # build libMPGO and the test runner
./build.sh check     # build, then run the test suite
```

Run `./check-deps.sh` directly to see exactly which prerequisites are present
or missing without invoking the build.

### API documentation

GSDoc-style HTML API documentation can be generated via `autogsdoc` (ships
with gnustep-base). The wiring lives in `objc/Documentation/`; from `objc/`:

```bash
make docs        # generates Documentation/html/
make docs-clean
```

The `Documentation/` subproject is intentionally not part of the default
build so the test suite has no autogsdoc dependency. See
`objc/Documentation/GNUmakefile` for a note on a known autogsdoc-from-source
issue that some libs-base builds exhibit. To build manually:

```bash
. /usr/share/GNUstep/Makefiles/GNUstep.sh
cd objc
make CC=clang OBJC=clang
make CC=clang OBJC=clang check
```

The Objective-C runtime ABI (`gnustep-1.8` legacy or `gnustep-2.0` non-fragile)
is auto-detected from the installed `libgnustep-base.so`, so the same command
works on both Debian/Ubuntu's apt packages and source builds against
`libobjc2`.

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Full class hierarchy, protocols, and HDF5 container mapping
- [`WORKPLAN.md`](WORKPLAN.md) — Milestone plan with acceptance criteria
- [`docs/architectural-primitives.md`](docs/architectural-primitives.md) — Background analysis: the six primitives, five container philosophies, and the case for an MPEG-G-derived multi-omics standard
- [`docs/primitives.md`](docs/primitives.md) — The six data primitives specification
- [`docs/container-design.md`](docs/container-design.md) — HDF5 container layout
- [`docs/class-hierarchy.md`](docs/class-hierarchy.md) — UML-style class descriptions
- [`docs/ontology-mapping.md`](docs/ontology-mapping.md) — CV annotation and BFO/PSI-MS/nmrCV mapping

## License

LGPL-3.0. See [`LICENSE`](LICENSE).
