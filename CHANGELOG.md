# CHANGELOG

All notable changes to the TTI-O multi-omics data standard reference
implementation.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/); the
public API is stable from onward.

---

## [v1.0.0] — 2026-05-04 — first stable release

This is the first stable release of TTI-O. The format string is
`ttio_format_version = "1.0"`; container ABI, codec wire formats,
encryption envelope, and digital-signature canonicalisations are
contractually frozen at this point. Pre-v1.0 development was never
publicly released; that history lives in `git log`.

### Format

- HDF5-backed `.tio` container; opaque `study/` group with per-modality
  child groups (`ms_runs/`, `genomic_runs/`, `chromatograms/`,
  `nmr_runs/`, `image_cubes/`, …).
- Deterministic write order; the Python, Java, and Objective-C
  reference implementations all produce byte-identical output for the
  same input. Cross-language byte-equality is part of the contract,
  not a coincidence — see `pytest -m integration`.
- Feature-flag preamble (`ttio_features` JSON array attribute) for
  forward-compatible optional capabilities. ISA-Tab investigation
  linkage on every container.

### Codecs

| Id | Symbol               | Description                                          | Channels                                              |
|---:|----------------------|------------------------------------------------------|-------------------------------------------------------|
| 0  | NONE                 | Passthrough                                          | any                                                   |
| 1  | ZLIB                 | HDF5 deflate filter (level 6 default)                | any                                                   |
| 2  | LZ4                  | HDF5 filter id 32004 (~35× faster write than zlib)   | any                                                   |
| 3  | NUMPRESS_DELTA       | Numpress + delta encode (sub-ppm lossy)              | numeric MS m/z channels                               |
| 4  | RANS_ORDER0          | rANS order-0 entropy coder                           | sequences / qualities / cigars / integers             |
| 5  | RANS_ORDER1          | rANS order-1 entropy coder                           | sequences / qualities / cigars / integers             |
| 6  | BASE_PACK            | 2-bit ACGT pack with sidecar mask for IUPAC bases    | sequences                                             |
| 7  | QUALITY_BINNED       | Illumina-8 binning (lossy, CRUMBLE-derived)          | qualities                                             |
| 11 | DELTA_RANS_ORDER0    | Delta + rANS-O0                                      | sortable integer channels                             |
| 12 | FQZCOMP_NX16_Z       | CRAM-mimic adaptive quality (V4 only, magic `M94Z`)  | qualities                                             |
| 13 | MATE_INLINE_V2       | Inlined mate_info v2 (single channel)                | mate_info compound                                    |
| 14 | REF_DIFF_V2          | Reference-diff v2 (slice-based, embedded reference)  | sequences                                             |
| 15 | NAME_TOKENIZED_V2    | 8-substream multi-token columnar codec               | read_names                                            |

Ids 8, 9, 10 are reserved on the wire (Java enum ordinal stability)
but carry no live codec. Reader paths reject them with migration
errors. Codec wire formats are documented in `docs/codecs/*.md`;
per-channel pipeline wiring is documented in `docs/format-spec.md`
§10.4–§10.10.

### Modalities

- Mass spectrometry: LC-MS, MS-image cubes, ion mobility, profile +
  centroid spectra.
- Nuclear magnetic resonance: 1-D and native 2-D (HSQC, COSY, NOESY).
- Vibrational imaging: Raman, IR.
- UV-Vis spectra.
- Two-dimensional correlation spectroscopy (2DCOS).
- Chromatograms.
- Genomic alignment runs: full BAM/CRAM importer parity, per-record
  metadata, codec-aware channel wiring.

### Format I/O — FASTA / FASTQ

- **FASTA importer**: `FastaReader` reads reference genomes (for
  embedding at `/study/references/<uri>/`, paired with BAM/CRAM
  input) or unaligned reads (panels, target lists, quality-stripped
  reads → `WrittenGenomicRun` with SAM unmapped sentinels). gzip
  auto-detected via magic bytes regardless of extension.
- **FASTA exporter**: `FastaWriter` writes a `ReferenceImport` or a
  `WrittenGenomicRun` to FASTA with configurable line wrap
  (default 60 chars) and a samtools-compatible `.fai` index
  emitted alongside.
- **FASTQ importer**: `FastqReader` parses 4-line records into
  unaligned `WrittenGenomicRun` instances. Phred offset is auto-
  detected (`33` modern Illumina / Sanger vs `64` legacy
  Illumina); detected source recorded for round-trip planning.
  Internal storage normalises to Phred+33.
- **FASTQ exporter**: `FastqWriter` writes a run to FASTQ with
  Phred+33 default and Phred+64 selectable. The `0xFF` "qualities
  unknown" sentinel is mapped to Phred 0 (`!`) on output so the
  result is always parseable.
- **Cross-language byte equality**: Python, Java, and ObjC produce
  byte-identical FASTA + FASTQ output for the same input — proven
  by the `test_fasta_fastq_cross_language.py` 3-way harness.
- **CLIs**: Python `python -m ttio.tools.{fasta,fastq}_{import,export}_cli`,
  Java `FastaRoundTrip` / `FastqRoundTrip`, ObjC `TtioFastaRoundTrip`
  / `TtioFastqRoundTrip`.

### Encryption + signing

- **Per-AU encryption** (AES-256-GCM) on signal-channel datasets and
  compound-metadata payloads. Versioned wrapped-key blob carries DEK
  rotation history; envelope decryption supported via local key, KMS,
  or user-supplied callback.
- **Digital signatures**: HMAC-SHA256 (canonical) plus post-quantum
  ML-DSA via liboqs. Signatures verify identically across all three
  reference implementations.

### Language bindings

- **Python** (`pip install ttio`): full read/write/encryption/sign;
  ctypes wrapper for the native rANS / v2-codec library.
- **Java** (Maven Central `global.thalion:ttio`): full parity; JNI
  wrapper for the same native library.
- **Objective-C** (GNUstep): full parity; native library linked
  directly. `objc/Tools/MakeFixtures` produces the canonical
  cross-language reference fixtures.

### Cross-language guarantee

Byte-equal output for shared codec paths under the test corpora in
`data/genomic/` (NA12878 chr22, NA12878 WES, HG002 Illumina 2×250,
HG002 PacBio HiFi subset). Verified on every commit via
`pytest -m integration`; SHA-256 hashes match Python ↔ Java ↔
Objective-C.

### Native library

`libttio_rans` (CMake / clang) ships the v2 codec kernels (rANS,
ref_diff_v2, mate_info_v2, name_tokenized_v2, fqzcomp_nx16_z V4).
Mandatory at runtime for genomic-run write/read on all three
language bindings (`TTIO_RANS_LIB_PATH` env var, or `libttio_rans.so` /
`.dylib` / `.jni` on the loader search path).

### Transport — genomic bulk mode (Phase 2c-T)

- New packet types `BlobV2MateInfo` (0x09), `BlobV2RefDiff` (0x0A),
  `BlobV2NameTok` (0x0B) carry the verbatim v2 codec blobs
  (`mate_info/inline_v2`, `sequences/refdiff_v2`,
  `read_names/name_tok_v2`) on the wire. See
  `docs/transport-spec.md` §3.2 / §4.10–4.12 / §5.8 / §6.4.
- Stream-level feature flag `bulk_mode_v2_blobs` (required, no
  `opt_` prefix). Receivers that cannot honor verbatim blob
  injection refuse the stream.
- CLIs accept `--bulk` on encode: Python
  `python -m ttio.tools.transport_encode_cli --bulk`, Java
  `TransportEncodeCli --bulk`, ObjC `TtioTransportEncode --bulk`.
- Cross-language byte-identity verified by the 9-cell
  Python/Java/ObjC matrix in
  `python/tests/validation/test_phase_2c_t_bulk_mode.py`.
- Storage-provider parity: HDF5, memory://, sqlite://, and zarr://
  write paths all honor `bulk_v2_blobs` and write the verbatim
  blob bytes — see
  `python/tests/validation/test_phase_2c_t_storage_providers.py`.
- Measured speedup: receiver-side decode runs **1.36×–1.43× faster**
  in bulk mode (10K and 50K-read fixtures); encode is near-parity
  (≤3% delta), wire size grows ~4% from the additional blob
  packets. See
  `docs/benchmarks/2026-05-05-phase-2c-T-bulk-mode.md`.
