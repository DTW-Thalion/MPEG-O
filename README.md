# TTI-O

[![TTIO CI](https://github.com/DTW-Thalion/TTI-O/actions/workflows/ci.yml/badge.svg)](https://github.com/DTW-Thalion/TTI-O/actions/workflows/ci.yml)
[![License: LGPL v3 (core) / Apache-2.0 (import/export)](https://img.shields.io/badge/License-LGPL_v3_%2F_Apache--2.0-blue.svg)](https://www.gnu.org/licenses/lgpl-3.0)
[![Python: 3.11+](https://img.shields.io/badge/python-3.11%2B-blue.svg)](https://www.python.org/)
[![Java: 17+](https://img.shields.io/badge/java-17%2B-blue.svg)](https://www.java.com/)

**TTI-O** is a reference implementation of a unified multi-omics data standard that brings mass spectrometry (MS), nuclear magnetic resonance (NMR), vibrational spectroscopy (Raman + IR), UV/Vis, and **genomic sequencing** data under a single container, class hierarchy, and access model. Its architecture is modeled on **MPEG-G** (ISO/IEC 23092), the ISO/IEC standard for genomic information representation, adapting MPEG-G's hierarchical access units, descriptor streams, selective encryption, and compressed-domain query model to the needs of both analytical spectroscopy/spectrometry AND genomic data.

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

## MPEG-G → TTI-O Architectural Mapping

| MPEG-G Concept | TTI-O Equivalent |
|---|---|
| File | `.tio` HDF5 container |
| Dataset Group | `TTIOSpectralDataset` (= ISA Investigation / Study root) |
| Dataset | `TTIOAcquisitionRun` |
| Access Unit | `TTIOSpectrumIndex` entry + associated signal-channel slice |
| Descriptor Streams | `/signal_channels/` HDF5 datasets (m/z, intensity, ion mobility, scan metadata) |
| Data Classes | Acquisition modes (MS1, MS2, DIA, SRM, 1D-NMR, 2D-NMR, Raman, IR, …) |
| Multi-level Protection | `TTIOEncryptable` protocol with per-dataset, per-stream, and per-AU encryption |
| Compressed-domain Query | `TTIOQuery` scanning AU headers without decompressing signal data |

## Implementation Streams

This repository hosts three implementation streams. The **Objective-C** stream under `objc/` is the normative reference implementation.

| Stream | Status | Directory |
|---|---|---|
| **Objective-C (GNUstep)** | **Normative reference — 3026 PASS / 0 failures.** Current release: v1.0.0. | `objc/` |
| **Python (`ttio`)**       | **Full parity with ObjC and Java, Python 3.11+.** | `python/` |
| **Java (`global.thalion.ttio`)** | **783/0/0/4 — full parity with ObjC and Python, JDK 17, Maven.** | `java/` |

A **cross-language conformance harness** drives the per-AU encryption CLI and
the JCAMP-DX bridge through small subprocess drivers in all three languages
and byte-compares the artefacts — 44+ combinations green (per-AU encrypt ×
decrypt × headers and JCAMP-DX Raman/IR). See
`python/tests/integration/test_per_au_cross_language.py` and
`python/tests/integration/test_raman_ir_cross_language.py`.

## Features

All features below are available in across the three
implementation streams.

### Domain modalities

* **Mass spectrometry** — MS¹ / MS² / DIA / SRM spectra as `MassSpectrum`, with `mz_values` + `intensity_values` signal channels and a parallel `SpectrumIndex` carrying offsets, lengths, RT, MS level, polarity, precursor m/z, base peak, isolation-window bounds, activation method and energy, and ion-mobility values (`inv_ion_mobility` for timsTOF).
* **NMR** — 1-D `NMRSpectrum` with `chemical_shift_values` + `intensity_values`, native rank-2 `NMR2DSpectrum` (F1/F2 dimension scales via `H5DSattach_scale`), and complex128-backed `FreeInductionDecay` (FID).
* **Vibrational spectroscopy** — `RamanSpectrum` / `IRSpectrum` keyed by `wavenumber` + `intensity` with laser / excitation / integration-time (Raman) or mode / resolution / scan-count (IR) metadata. `RamanImage` / `IRImage` rank-3 cubes mirror MS-imaging tile chunking.
* **UV/Visible** — `UVVisSpectrum` keyed by `wavelength` (nm) + `absorbance`, with `pathLengthCm` + `solvent` metadata.
* **2D correlation spectroscopy (2D-COS)** — `TwoDimensionalCorrelationSpectrum` holds synchronous + asynchronous rank-2 correlation matrices over a shared variable axis; gated behind `opt_native_2d_cos`.
* **Chromatograms** — TIC / XIC / SRM traces persist as `Chromatogram` with a parallel-array chromatogram index, round-tripped via `<chromatogramList>` + `<index name="chromatogram">` in the mzML writer.
* **MS imaging** — `MSImage` stores a 3-D `[height, width, spectralPoints]` HDF5 dataset with tile-aligned chunking (default 32×32 pixel tiles); inherits identifications / quantifications / provenance / access-policy from `SpectralDataset`.
* **Genomic sequencing** — `GenomicRun` is a parallel run-and-element hierarchy alongside the spectrum-based classes. `AlignedRead` is the per-read value class (read_name, chromosome, position, mapping_quality, cigar, sequence, qualities, flags, mate-pair info — modelled on SAM/BAM). `GenomicIndex` carries parallel-array per-read scalars (offsets, lengths, chromosomes, positions, mapping qualities, flags) for region / unmapped / flag queries. `WrittenGenomicRun` is the write-side container. Storage under `/study/genomic_runs/<name>/` with `signal_channels/` for per-base byte arrays (sequences, qualities) and per-read parallel arrays (positions, flags, mapping_qualities) plus VL_STRING compounds (cigars, read_names, mate_info). See [`docs/genomic-runs.md`](docs/genomic-runs.md) for the data-model walkthrough.

### Genomic compression codecs

A complete genomic codec stack ships across all three languages with cross-language byte-exact conformance:

* **rANS order-0 / order-1** (codec ids `4` / `5`) — clean-room implementation of the range Asymmetric Numeral Systems entropy coder from Duda 2014 (arXiv:1311.2540). Wire format, frequency-table normalisation, and state width all specified for byte-identical output across Python / ObjC / Java. Python ships a Cython accelerator at `ttio.codecs._rans._rans` that runs faster than ObjC's hand-rolled C; the pure-Python reference at `ttio.codecs.rans` remains the byte-exact fallback. See [`docs/codecs/rans.md`](docs/codecs/rans.md).
* **BASE_PACK** (codec id `6`) — 2-bit ACGT packing with a sparse position+byte sidecar mask for non-ACGT bytes (`N`, IUPAC ambiguity codes, soft-masking lowercase, gaps). Lossless on the full 256-byte alphabet; case-sensitive (preserves soft-masking convention). See [`docs/codecs/base_pack.md`](docs/codecs/base_pack.md).
* **QUALITY_BINNED** (codec id `7`) — fixed Illumina-8 / CRUMBLE-derived 8-bin Phred quantisation with 4-bit-packed bin indices. Lossy by construction; round-trip via bin centres. See [`docs/codecs/quality.md`](docs/codecs/quality.md).
* **DELTA_RANS_ORDER0** (codec id `11`) — delta + zigzag + LEB128 + rANS order-0 wrapper for sorted-ascending integer channels. Auto-default for `positions` on genomic runs. See [`docs/codecs/delta_rans.md`](docs/codecs/delta_rans.md).
* **FQZCOMP_NX16_Z** (codec id `12`) — CRAM-mimic lossless quality codec (V4 wire format, magic `M94Z`). Static-per-block frequency tables, 16-bit renormalisation, `T = 4096` fixed (`T | b·L` exactly — byte-pairing invariant). Default for the `qualities` channel. See [`docs/codecs/fqzcomp_nx16_z.md`](docs/codecs/fqzcomp_nx16_z.md).
* **MATE_INLINE_V2** (codec id `13`) — inlined per-record mate_info (chrom + pos + tlen) as a single channel. See [`docs/codecs/mate_info_v2.md`](docs/codecs/mate_info_v2.md).
* **REF_DIFF_V2** (codec id `14`) — reference-aligned sequence-diff codec for genomic `sequences` channels. Slice-based wire format with embedded reference at `/study/references/<reference_uri>/`; closes ~80% of the chr22 sequence-channel compression gap to CRAM 3.1. Falls back to BASE_PACK silently when the reference is unavailable at write. See [`docs/codecs/ref_diff_v2.md`](docs/codecs/ref_diff_v2.md).
* **NAME_TOKENIZED_V2** (codec id `15`) — 8-substream multi-token columnar codec for read names. FLAG / POOL_IDX / MATCH_K / COL_TYPES / NUM_DELTA / DICT_CODE / DICT_LIT / VERB_LIT substreams; per-block reset every 4096 reads; auto-picked rANS-O0 vs raw passthrough per substream. ~67 MB savings on chr22 NA12878 vs a VL-string compound layout. See [`docs/codecs/name_tokenizer_v2.md`](docs/codecs/name_tokenizer_v2.md).
* **Pipeline wiring** — every genomic-run channel in `signal_channels/` accepts at least one codec via `WrittenGenomicRun.signal_codec_overrides`. Per-channel `@compression` attribute; lazy whole-channel decode + per-instance cache. The cigars channel accepts rANS-O0/O1; per-channel codec selection guidance is documented in [`docs/format-spec.md`](docs/format-spec.md) §10.4–§10.10.
* **`libttio_rans`** — native C library at `native/` providing AVX2/SSE4.1/scalar SIMD-dispatched rANS kernels and the v2-codec C kernels (`ref_diff_v2`, `mate_info_v2`, `name_tok_v2`, `fqzcomp_qual` V4). Consumed by Python (ctypes), Java (JNI), and ObjC (direct linkage). **Required at runtime** for genomic-run write/read on all three bindings — set `TTIO_RANS_LIB_PATH` or place `libttio_rans.{so,dylib,jni}` on the loader search path. See [`docs/native-rans-library.md`](docs/native-rans-library.md).

### The six data primitives

* **SignalArray** — atomic typed-buffer unit conforming to `CVAnnotatable`; round-trips with axis descriptors and CV annotations. Supports `float32` / `float64` / `int32` / `int64` / `uint32` / `complex128`.
* **Spectrum** — named dictionary of SignalArrays with coordinate axes and CV metadata; specialized by MS / NMR / Raman / IR / UV-Vis / 2D-COS subclasses and persisted through the generic path with `@ttio_class` attributes.
* **AcquisitionRun** — ordered, indexable, streamable collection of Spectrum objects sharing an instrument configuration and provenance chain. Accepts any Spectrum subclass; signal-channel serialization is name-driven. Conforms to `Indexable` + `Streamable` + `Provenanceable` + `Encryptable` with per-run provenance chains. Also conforms to the modality-agnostic `Run` protocol (Phase 1+2; same surface as `GenomicRun`) so cross-modality code can iterate `dataset.runs.values()` uniformly and call `runs_for_sample(uri)` / `runs_of_modality(cls)` regardless of modality.
* **CVAnnotation** — controlled-vocabulary parameter (ontology reference + accession + value + unit) attachable to any annotatable object. PSI-MS / nmrCV / Unimod accessions mapped via `CVTermMapper`.
* **Identification** — link from a spectrum (or region) to a chemical entity, with confidence score and evidence chain. Persisted as a native HDF5 compound dataset.
* **ProvenanceRecord** — W3C PROV-compatible record (input entities → activity → output entities). Persists both as a compound dataset at `/study/provenance` and per-run at `<run>/provenance/steps` (Phase 2: dual-write across all three languages on the HDF5 fast path; legacy `@provenance_json` mirror retained for non-HDF5 providers and pre-Phase-2 readers).

### Container, storage providers, and I/O

* **`.tio` HDF5 container** — root `SpectralDataset` holds named MS runs, NMR/Raman/IR/UV-Vis spectrum collections, identifications, quantifications, PROV provenance records, and SRM/MRM transition lists. Fully specified in [`docs/format-spec.md`](docs/format-spec.md); current format string is `ttio_format_version = "1.0"`.
* **Feature flags** — root-level `@ttio_format_version` + JSON `@ttio_features`. `opt_`-prefixed flags are informational; unprefixed flags are required. Registry at [`docs/feature-flags.md`](docs/feature-flags.md).
* **Storage-provider abstraction** — `StorageProvider` / `StorageGroup` / `StorageDataset` protocols. Four interchangeable backends: **HDF5** (reference), **Memory** (transient), **SQLite** (full group/dataset/attribute/compound tree as rows), **Zarr v3** (on-disk + in-memory + S3). `open_provider("scheme://...")` dispatches by URL scheme. All three language implementations accept any provider URL through both `+writeMinimalToPath:` and `-writeToFilePath:` for MS-only datasets; NMR runs and Image-subclass datasets continue to require an HDF5 backing file (H5DSset_scale dimension scales / native 3D cubes have no protocol equivalents).
* **Byte-level canonical bytes** — `read_canonical_bytes()` returns a little-endian byte stream regardless of backend or host endianness; every provider returns bit-equal bytes for the same logical data — the protocol-native path for signatures and encryption.
* **Full-rank N-D datasets** — `create_dataset_nd` works across all providers via a flat-BLOB + `@__shape_<name>__` attribute pattern.
* **VL_BYTES compound field kind** — variable-length byte segments in compound rows across all providers; Java's HDF5 provider uses a native `hvl_t` raw-buffer pool to work around JHI5 1.10's marshalling gap.
* **Cloud-native access** — Python `SpectralDataset.open("s3://bucket/run.tio")` routes through `fsspec` (HTTP / S3 / GCS / Azure); alternatively stream HDF5 metadata + chunks directly over S3 / HTTPS via libhdf5's **ROS3 VFD**. Benchmark: 10 random spectra from a 15 MB remote file in ~50 ms, ~24% of bytes transferred.
* **Thread safety** — `HDF5File` carries a `pthread_rwlock_t` serializing writes and allowing concurrent reads; Python side opt-in via `SpectralDataset.open(..., thread_safe=True)` with a writer-preferring `RWLock`. Degrades to exclusive locking on non-threadsafe libhdf5 builds.
* **Chunked + compressed storage** — zlib via HDF5, plus optional **LZ4** (filter 32004; ~35× faster write / ~2× faster read than zlib) and **Numpress-delta** (sub-ppm relative error for m/z). Both cross-language byte-identical between ObjC and Python. LZ4 skips cleanly at runtime when the plugin isn't loadable.
* **Streaming + query** — `StreamWriter` / `StreamReader` for incremental write + sequential read over runs of arbitrary size. `Query` evaluates compressed-domain predicates (RT range, MS level, polarity, precursor m/z range, base peak threshold) over the in-memory index without touching signal channels; a 10k-spectrum scan runs in ~0.2 ms in CI.

### Importers

* **mzML 1.1** — SAX-parsed, base64 + zlib-aware, CV-mapped; populates activation method, isolation window, ion mobility, and chromatograms.
* **nmrML 1.0+** — element-based acquisition parameters, int32/int64 FID payloads widened to complex128 on import, dimension-scale extraction. Validated against BMRB `bmse000325.nmrML`.
* **JCAMP-DX 5.01** — AFFN `##XYDATA=(X++(Y..Y))` plus the full §5.9 **compressed dialect (PAC / SQZ / DIF / DUP)**. Reader auto-detects compression via a sentinel-char scan that excludes `e`/`E` so AFFN scientific notation doesn't false-trigger. Dispatches on `##DATA TYPE=` to Raman, IR (transmittance + absorbance), and UV/Vis. 2-D NTUPLES is intentionally out of scope.
* **Bruker timsTOF `.d`** — SQLite metadata reads natively in every language (`java.sql`, `libsqlite3`, stdlib `sqlite3`); binary frame decompression via `opentimspy` + `opentims-bruker-bridge` (Python native; Java / ObjC subprocess the Python helper). `inv_ion_mobility` channel preserves the 2-D timsTOF geometry per-peak. Install with `pip install 'ttio[bruker]'`.
* **Thermo `.raw`** — shells out to `ThermoRawFileParser` and ingests the resulting mzML.
* **SAM/BAM** — `BamReader` / `SamReader` wrap `samtools view -h` as a subprocess (no htslib link); convert SAM/BAM input to `WrittenGenomicRun` instances. SAM header parsed for `@SQ` (reference dictionary), `@RG` (sample + platform), `@PG` (provenance chain). Optional region filter passes through to samtools verbatim. Cross-language `bam_dump` CLI emits canonical JSON byte-identical across Python / ObjC / Java. Requires `samtools` on PATH at runtime; `BamReader` class is loadable without it (error fires only at first import call). See [`docs/vendor-formats.md`](docs/vendor-formats.md) §SAM/BAM.
* **CRAM** — `CramReader` / `TTIOCramReader` extends the BAM reader with a mandatory reference FASTA argument injected as `samtools view --reference <fasta>`. Reuses the SAM-text parsing path; produces `WrittenGenomicRun` instances with the same shape as `BamReader`. Reference rejection is enforced at construction (Python `TypeError` / ObjC `NS_UNAVAILABLE` / Java null-rejection). The shared `bam_dump` CLI auto-dispatches to the CRAM reader on `.cram` paths via a `--reference <fasta>` flag; the cross-language harness verifies byte-identical canonical JSON for both BAM and CRAM. See [`docs/vendor-formats.md`](docs/vendor-formats.md) §CRAM.

### Exporters

* **mzML (indexed)** — `MzMLWriter` emits indexed-mzML with byte-correct `<indexList>` offsets per spectrum, optional zlib compression of binary arrays, and `<chromatogramList>` with a byte-correct chromatogram index. Licensed Apache-2.0. PSI-MS CV accessions for activation method and isolation window (MS:1000133 CID, MS:1000422 HCD, MS:1000598 ETD, MS:1000250 ECD, MS:1003246 UVPD, MS:1003181 EThcD; MS:1000827/828/829 for isolation window).
* **nmrML** — serializes `NMRSpectrum` + FID with acquisition parameters and base64 spectrum arrays; round-trips through the reader.
* **JCAMP-DX 5.01 (AFFN)** — writer emits LDRs in fixed order with `%.10g` formatting, producing byte-identical output across the three languages for identical input. Compression variants remain read-only for now (bit-accurate round-trips > byte savings at this stage).
* **imzML** — continuous + processed modes, UUID normalisation.
* **mzTab** — proteomics 1.0 and metabolomics 2.0.0-M dialects.
* **ISA-Tab / ISA-JSON** — investigation/study/assay TSV files + ISA-JSON from a `SpectralDataset`. Licensed Apache-2.0.
* **SAM/BAM/CRAM** — `BamWriter` / `CramWriter` (and ObjC / Java equivalents) compose SAM text in memory from a `WrittenGenomicRun` and pipe it through `samtools view -b` (BAM) or `samtools view -C | samtools sort -O cram` (CRAM, two-stage). All 11 SAM columns always emitted with sentinel fills; RNEXT collapses to `=` when mate matches a mapped read; QUAL is ASCII Phred+33 verbatim. Lossless BAM↔BAM, CRAM↔CRAM, and BAM↔CRAM round-trips through `.tio` per the genomic-export conformance suite. See [`docs/vendor-formats.md`](docs/vendor-formats.md) §SAM/BAM/CRAM Export.

### Streaming transport (`.tis`)

* **Packet codec** — 24-byte headers, nine packet types: StreamHeader, DatasetHeader, AccessUnit, ProtectionMetadata, Annotation, Provenance, Chromatogram, EndOfDataset, EndOfStream. Three-language parity; bidirectional conformance matrix (any writer × any reader). Optional CRC-32C per packet. See [`docs/transport-spec.md`](docs/transport-spec.md).
* **WebSocket client + server** — libwebsockets (ObjC), `websockets` (Python), Java-WebSocket (Java). Stream `.tio` as `.tis` over `ws://` / `wss://`.
* **Acquisition simulator** — replays a fixture at wall-clock pace to exercise client/server scheduling.
* **Selective access** — per-packet `AUFilter` for client-driven filtering without decryption; ProtectionMetadata packet carries `cipher_suite`, `kek_algorithm`, `wrapped_dek`, `signature_algorithm`, `public_key`. `AUFilter` includes chromosome + position-range predicates so subscribers can scope a stream to a genomic region without decrypting AUs they won't read.
* **Genomic AUs + multiplexing** — `.tis` carries genomic AUs with a `chromosome + position + mapq + flags` prefix when `spectrum_class == 5`; MS and genomic runs interleave in a single stream and dispatch per-AU on the `spectrum_class` byte. 3×3 cross-language transport matrix green for both encode and decode directions.

### Protection: encryption, integrity, and key management

* **Classical AEAD** — AES-256-GCM via OpenSSL / JCE / cryptography library. Wrong keys fail cleanly via GCM tag mismatch, never partial bytes.
* **Selective dataset encryption** — encrypts an acquisition run's intensity channel in place while leaving `mz_values` and the spectrum index readable as plaintext. Whole-dataset seal via `encryptWithKey:level:error:` also encrypts compound identification/quantification datasets.
* **Envelope encryption + key rotation** — DEK encrypts data, KEK wraps DEK. `/protection/key_info/` stores the wrapped-DEK blob + KEK metadata. Rotation re-wraps in O(1) without touching signal datasets.
* **Versioned wrapped-key blob** — `[magic "MW" | version 0x02 | algorithm_id | ct_len | md_len | metadata | ciphertext]`.
* **Crypto algorithm agility** — `CipherSuite` static catalog (AEAD / KEM / MAC / Signature / Hash / XOF). `encrypt_bytes`, `sign_dataset`, `enable_envelope_encryption` all take opt-in `algorithm=` parameters. Fixed allow-list, not plugin-registered.
* **Per-Access-Unit encryption** — `opt_per_au_encryption` with the `<channel>_segments` VL_BYTES compound layout (see [`docs/format-spec.md`](docs/format-spec.md) §9.1). Each spectrum is a separate AES-256-GCM op with fresh IV and AAD = `dataset_id || au_sequence || channel_name`; ciphertext can't be replayed against a different AU or envelope. Optional `opt_encrypted_au_headers` also encrypts the 36-byte semantic header.
* **HMAC-SHA256 signatures (`v2:`)** — canonical little-endian byte stream hashed field-by-field (VL strings as `u32_le(len) || bytes`). Cross-language byte-identical by construction.
* **Post-quantum signatures + KEM (`v3:`)** — ML-KEM-1024 (FIPS 203) envelope key-wrap and ML-DSA-87 (FIPS 204) dataset signatures. Python + ObjC via [`liboqs`](https://github.com/open-quantum-safe/liboqs); Java via Bouncy Castle 1.80+. Opt-in via `pip install 'ttio[pqc]'`; classical AES-256-GCM + HMAC-SHA256 remain the defaults. Feature flag: `opt_pqc_preview`. See [`docs/pqc.md`](docs/pqc.md).
* **Access policy** — `AccessPolicy` persists JSON-encoded subject/stream/key-id metadata under `/protection/access_policies` independently of any key store.
* **Spectral anonymization** — policy-based pipeline (SAAV redaction, intensity masking, m/z coarsening, rare-metabolite suppression, metadata stripping). Audit trail via provenance record. Feature flag: `opt_anonymized`.
* **Genomic encryption + anonymisation** — per-AU AES-256-GCM on genomic signal channels with AAD = `dataset_id || au_sequence || channel_name`; ML-DSA-87 signatures over the chromosomes VL compound; region-based encryption (encrypt chr6 / HLA, leave chr1 in clear) with a per-region key map keyed on the reserved `_headers` key; genomic anonymiser (strip read names, randomise quality on a seeded RNG, mask SAM-overlapping regions). MPAD transport debug magic is `"MPA1"` with a per-entry dtype byte so genomic UINT8 channels survive without a float64 cast.

### Cross-language conformance

* **Three-language parity** — Objective-C (GNUstep) normative reference, Python (`ttio`, Python 3.11+), Java (`global.thalion.ttio`, JDK 17 + Maven). Every cross-language round-trip test passes byte-for-byte, driven by shared format fixtures.
* **Compound byte-parity harness** — three dumper CLIs (Python `python -m ttio.tools.dump_identifications`, Java `DumpIdentifications`, ObjC `TtioDumpIdentifications`) emit identifications / quantifications / study-level provenance / `ms_per_run_provenance` (per-run provenance flattened by sorted run-name + per-run sequence index, Phase 2) as byte-identical canonical JSON; pairwise-diffed in CI.
* **Per-AU encryption CLIs** — `per_au_cli` (Python), `PerAUCli` (Java), `TtioPerAU` (ObjC) all expose `{encrypt, decrypt, send, recv, transcode}` subcommands. `decrypt` emits a canonical "MPAD" dump for byte-compare; `transcode --rekey` rotates DEKs.
* **PQC conformance matrix** — 32-cell verification across languages × providers (primitive ML-DSA / ML-KEM sign-verify-encaps-decaps, `v3:` signatures on HDF5 / Zarr / SQLite, v2+v3 coexistence).
* **JCAMP-DX conformance** — 6 integration tests compare bit-for-bit parses across Python↔Java and Python↔ObjC. ObjC CLI `TtioJcampDxDump`.
* **API stability audit** — every public API classified Stable / Provisional / Deprecated in [`docs/api-stability.md`](docs/api-stability.md).

### Foundation

* **Capability protocols** — `Indexable`, `Streamable`, `CVAnnotatable`, `Provenanceable`, `Encryptable` and the immutable value classes `ValueRange`, `EncodingSpec`, `AxisDescriptor`, `CVParam` — the vocabulary every domain class implements.
* **HDF5 layer** — thin wrappers over the libhdf5 C API supporting hyperslab partial reads, chunked storage, zlib compression, compound types with VL strings, and `Error` out-parameters on every fallible call. Runtime ABI auto-detection across `gnustep-1.8` legacy and `gnustep-2.0` non-fragile.

### Format compatibility

v1.0.0 is the first stable release of TTI-O. The container ABI, codec
wire formats, encryption envelope, and digital-signature
canonicalisations are contractually frozen at this point — the format
string is `ttio_format_version = "1.0"`. earlier development files
were never publicly released, so v1.0 readers are not expected to
ingest them; that history lives in `git log`. Any future format
revision will read v1.0 containers (forward compatibility is part of
the contract).

### Continuous integration

Runs every push on `ubuntu-latest` with **clang + libobjc2 + gnustep-base built from source** (the `gnustep-2.0` non-fragile ABI), then exercises the full test suite across all three languages.

## Python Installation

```bash
# Core reader/writer only
pip install ttio

# With every optional extra (crypto, import, cloud, codecs)
pip install 'ttio[all]'
```

Individual extras:

| Extra         | Pulls in                                                                      | Needed for                                                                                |
|---------------|-------------------------------------------------------------------------------|-------------------------------------------------------------------------------------------|
| `crypto`      | `cryptography>=41.0`                                                          | AES-256-GCM encryption / decryption of signal channels                                    |
| `import`      | `lxml`                                                                        | mzML / nmrML importers (`ttio.importers`)                                                 |
| `cloud`       | `fsspec`, `s3fs`, `aiohttp`                                                   | `s3://` / `http(s)://` / `gs://` / `az://` open paths                                     |
| `codecs`      | `hdf5plugin>=4.0`                                                             | LZ4 signal-channel compression                                                            |
| `zarr`        | `zarr>=3.0`                                                                   | `ZarrProvider` — `zarr://`, `zarr+s3://`, `zarr+memory://` URLs (Zarr v3 on-disk format) |
| `pqc`         | `liboqs-python>=0.14`                                                         | Post-quantum signatures (ML-DSA-87) and KEM (ML-KEM-1024) — `v3:` envelope wrap          |
| `bruker`      | `opentimspy`, `opentims-bruker-bridge`                                        | Bruker timsTOF `.d` importer                                                             |
| `network`     | `websockets>=12.0`                                                            | `.tis` streaming transport over WebSocket                                                |
| `integration` | `pyimzml`, `pyteomics`, `pymzml`, `isatools`                                  | Cross-tool validation harnesses (mzML XSD checks, mzTab importer fixtures, ISA-Tab tests) |
| `test`        | pytest, pytest-asyncio, pytest-cov, hypothesis, **+ all of the above except `integration`** | Full local dev environment for `pytest`                                                   |
| `all`         | `[crypto,import,cloud,codecs,zarr,pqc,bruker]`                                | Everything except `test` + `integration`                                                  |

### Python quick start

```python
from ttio import SpectralDataset

with SpectralDataset.open("example.tio") as ds:
    run = ds.ms_runs["run_0001"]
    spectrum = run[0]                      # lazy read
    mz = spectrum.mz_array.data            # numpy float64
    intensity = spectrum.intensity_array.data

# Cloud-native access through fsspec:
with SpectralDataset.open("s3://my-bucket/run.tio", anon=False) as ds:
    ...
```

Run the Python test suite. The `[test]` extra already pulls in
pytest, pytest-asyncio, pytest-cov, hypothesis, cryptography, lxml,
fsspec, aiohttp, hdf5plugin, zarr, liboqs-python, opentimspy +
bridge, and websockets — enough for the full unit + property-based
+ stress + V-series suite. Add `[integration]` for the cross-tool
validation harnesses (mzML XSD, pyteomics, pymzml, isatools-driven
ISA-Tab tests):

```bash
sudo apt install libhdf5-dev libhdf5-serial-dev samtools
python3 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip setuptools wheel
pip install -e 'python[test,integration]'
cd python && pytest
```

Expected on a healthy install: full test suite passes; the only
skips are platform-conditional fixtures and the xfails are documented
future-work markers.

Coverage report:

```bash
cd python && pytest --cov=src/ttio --cov-report=term --cov-report=html
# HTML report at python/htmlcov/index.html
```

### Building the Java implementation

```bash
# Prerequisites: JDK 17+, Maven 3.8+, libhdf5-dev, libhdf5-java, libhdf5-jni
sudo apt-get install openjdk-17-jdk-headless maven libhdf5-dev libhdf5-java libhdf5-jni

cd java
mvn verify -B
```

## Building the Objective-C Reference Implementation

Requires **GNUstep Base**, **GNUstep Make**, a compatible **Objective-C compiler** (clang, ARC required), **libhdf5** (≥ 1.10), **zlib**, and **OpenSSL/libcrypto**. Optional: the LZ4 HDF5 filter plugin (filter id 32004) for `TTIOCompressionLZ4` support; LZ4-dependent tests skip cleanly when the plugin isn't loadable.

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
./build.sh           # build libTTIO and the test runner
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
- [`CHANGELOG.md`](CHANGELOG.md) — Release notes
- [`docs/architectural-primitives.md`](docs/architectural-primitives.md) — Background analysis: the six primitives, five container philosophies, and the case for an MPEG-G-derived multi-omics standard
- [`docs/primitives.md`](docs/primitives.md) — The six data primitives specification
- [`docs/container-design.md`](docs/container-design.md) — HDF5 container layout
- [`docs/class-hierarchy.md`](docs/class-hierarchy.md) — UML-style class descriptions
- [`docs/ontology-mapping.md`](docs/ontology-mapping.md) — CV annotation and BFO/PSI-MS/nmrCV mapping
- [`docs/format-spec.md`](docs/format-spec.md) — On-disk `.tio` format specification (v1.0 container)
- [`docs/transport-spec.md`](docs/transport-spec.md) — `.tis` streaming transport format
- [`docs/transport-encryption-design.md`](docs/transport-encryption-design.md) — Per-AU encryption design
- [`docs/feature-flags.md`](docs/feature-flags.md) — Feature-flag registry
- [`docs/providers.md`](docs/providers.md) — Storage provider feature matrix (HDF5 / Memory / SQLite / Zarr) and compound-field-kind support
- [`docs/api-stability.md`](docs/api-stability.md) — Per-symbol stability classification across all three languages
- [`docs/pqc.md`](docs/pqc.md) — Post-quantum crypto: ML-KEM-1024 + ML-DSA-87
- [`docs/migration-guide.md`](docs/migration-guide.md) — Migration guide from mzML / nmrML
- [`docs/vendor-formats.md`](docs/vendor-formats.md) — Vendor format support (Thermo `.raw`, Bruker `.d`, Waters MassLynx, JCAMP-DX Raman/IR/UV-Vis incl. compressed dialects)

## License

LGPL-3.0. See [`LICENSE`](LICENSE).
