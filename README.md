# MPEG-O

[![MPGO CI](https://github.com/DTW-Thalion/MPEG-O/actions/workflows/ci.yml/badge.svg)](https://github.com/DTW-Thalion/MPEG-O/actions/workflows/ci.yml)
[![License: LGPL v3](https://img.shields.io/badge/License-LGPL_v3-blue.svg)](https://www.gnu.org/licenses/lgpl-3.0)

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
| **Objective-C (GNUStep)** | **v0.1.0-alpha — Milestones 1–8 complete, 379 tests passing in CI** | `objc/` |
| Python | Planned | `python/` |
| Java | Planned | `java/` |

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

## Building the Objective-C Reference Implementation

Requires **GNUStep Base**, **GNUStep Make**, a compatible **Objective-C compiler** (clang or gobjc), **libhdf5** (≥ 1.10), **zlib**, and — for Milestone 7 — **OpenSSL/libcrypto**.

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
or missing without invoking the build. To build manually:

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
- [`docs/primitives.md`](docs/primitives.md) — The six data primitives specification
- [`docs/container-design.md`](docs/container-design.md) — HDF5 container layout
- [`docs/class-hierarchy.md`](docs/class-hierarchy.md) — UML-style class descriptions
- [`docs/ontology-mapping.md`](docs/ontology-mapping.md) — CV annotation and BFO/PSI-MS/nmrCV mapping

## License

LGPL-3.0. See [`LICENSE`](LICENSE).
