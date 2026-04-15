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
| **Objective-C (GNUStep)** | Active — reference implementation | `objc/` |
| Python | Planned | `python/` |
| Java | Planned | `java/` |

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

```bash
. /usr/share/GNUstep/Makefiles/GNUstep.sh
cd objc
make
make check
```

## Documentation

- [`ARCHITECTURE.md`](ARCHITECTURE.md) — Full class hierarchy, protocols, and HDF5 container mapping
- [`WORKPLAN.md`](WORKPLAN.md) — Milestone plan with acceptance criteria
- [`docs/primitives.md`](docs/primitives.md) — The six data primitives specification
- [`docs/container-design.md`](docs/container-design.md) — HDF5 container layout
- [`docs/class-hierarchy.md`](docs/class-hierarchy.md) — UML-style class descriptions
- [`docs/ontology-mapping.md`](docs/ontology-mapping.md) — CV annotation and BFO/PSI-MS/nmrCV mapping

## License

LGPL-3.0. See [`LICENSE`](LICENSE).
