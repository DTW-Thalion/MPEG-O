# CHANGELOG

All notable changes to the TTI-O multi-omics data standard reference
implementation.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/); the
public API is stable from onward.

---

## [Unreleased]

## [1.4.1] - 2026-05-11

### Fixed

- **`tio-browser` Windows: opens `.tio` files with genomic data.** v1.4.0
  launched cleanly on Windows (after the MinGW DLL closure was bundled),
  but it could not open `.tio` files containing BAM/CRAM-style genomic
  data because the Java implementation shelled out to the
  `samtools` CLI binary — not installed on a fresh Windows machine.
  Replaced the samtools subprocess across `BamReader`, `BamWriter`,
  `CramReader`, and `CramWriter` with [htsjdk](https://github.com/samtools/htsjdk)
  4.1.3 — the pure-Java SAM/BAM/CRAM library used by GATK, Picard, and
  IGV. No external binary required at runtime; tio-browser now works
  end-to-end on Windows with only a JDK 17+ installed.

### Internal

- `htsjdk` added as a Maven runtime dependency (`com.github.samtools:htsjdk:4.1.3`).
- `BamReader.SamtoolsNotFoundException` retained as a no-throw alias
  for source compat with callers and tests that catch it.
- `BamReader.isSamtoolsAvailable()` returns `true` unconditionally
  (htsjdk is always available as a Maven dep).
- CRAM reference handling: custom `InMemoryFastaReferenceSource`
  bypasses htsjdk's stock `ReferenceSource` strict length/MD5
  validation, matching samtools' lenient default behaviour. Existing
  samtools-produced CRAMs (with placeholder `@SQ LN`) decode without
  modification.
- `BamReader` static initializer sets
  `samjdk.cram.use_alignment_md5_check=false` for the same reason.
- `WrittenGenomicRun.qualities` byte semantics preserved: ASCII Phred+33
  on the cross-language wire (M87/M88 convention); htsjdk's raw-Phred
  byte arrays are converted with ±33 in the reader/writer.
- 0-byte BAM/SAM rejection: explicit `Files.size(path) == 0` check
  before opening (htsjdk would otherwise treat as a 0-record BAM).

## [1.4.0] - 2026-05-09

### Changed

- **`tio-browser` distribution model: per-platform JARs.** Replaces the
  prior universal shaded JAR with three platform-specific JARs
  (`tio-browser-1.4.0-linux-x64.jar`, `tio-browser-1.4.0-mac-aarch64.jar`,
  `tio-browser-1.4.0-win-x64.jar`). Each JAR is ~31 MB instead of the
  universal-with-HDF5 alternative (~64 MB), carries only its own
  platform's natives, and **bundles HDF5 1.14 + the LZ4 filter plugin**
  so `java -jar tio-browser-1.4.0-<your-os>.jar` on a fresh machine
  works out of the box with only a JDK 17+ — no system HDF5 install
  required.
- New `Hdf5NativeLoader` extracts the bundled HDF5 native libs to a
  per-JVM temp dir at `App.start()`, calls `System.load` in dependency
  order (hdf5 → hdf5_hl → hdf5_java), and registers the LZ4 plugin
  search path via `H5.H5PLappend`. Idempotent; throws
  `Hdf5NativeLoadException` on hard failures (modal Alert + exit, with
  a headless detector that suppresses the exit during TestFX runs).
- Wrong-JAR-for-OS detection: running `tio-browser-1.4.0-linux-x64.jar`
  on a Mac shows a clear modal Alert with the correct download name.
- `release-shaded-jar.yml` workflow restructured: each platform's
  build job now produces its own complete shaded JAR end-to-end (no
  separate assembly job). Workflow grants `contents: write`
  permission so the auto-publish step works without the v1.3.0 manual
  workaround.
- `jarhdf5` switched from `<scope>system</scope>` to a vendored
  `org.hdfgroup:jarhdf5:1.14.6` Maven dep at `tio-browser/local-repo/`,
  so the JHI5 classes ship in each per-platform shaded JAR.

## [1.3.0] - 2026-05-09

### Added

- **`tio-browser` desktop GUI (Phases 0–13 + native bundling)** —
  JavaFX desktop application for inspecting `.tio` datasets, peer to
  the Java / Python / ObjC reference implementations. Cross-platform
  shaded jar bundles `libttio_rans_jni` for **Linux x86_64**, **macOS
  Apple Silicon (arm64)**, and **Windows x86_64**; end users can run
  `java -jar tio-browser-<ver>-shaded.jar` without any toolchain
  setup beyond a JDK 17+ runtime.

  - **Phase 8** — Import wizard: 13-format dispatch (mzML, ImzML,
    nmrML, JCAMP-DX, BAM/SAM/CRAM, FASTA, FASTQ, mzTab, Thermo,
    Waters, Bruker), drag-and-drop with format auto-detection.
  - **Phase 9** — Export dialog: 11 export formats with eligibility-
    based greying when the open `.tio` doesn't contain the required
    run kind.
  - **Phase 10/11** — Transport: download `.tis` streams from
    `http(s)`/`ws(s)` URLs into a local `.tio`; upload a local `.tio`
    as a `.tis` byte stream to the same URL families. Server-side
    filters (run kind, dataset-id list, RT range) let clients fetch
    subsets without downloading the whole file.
  - **Phase 12** — Diagnostics dialog (Tools → Diagnostics): probes
    HDF5 JNI, `samtools`, `ThermoRawFileParser`, `masslynxraw`, and
    the Bruker Python helper. Greys out Import/Export format rows
    whose binary isn't available, with tooltips listing the missing
    dep. Re-probe button picks up newly-installed binaries without
    restarting the app via a listener bus.
  - **Phase 13** — Distribution: `--open <path>` CLI flag for the
    shaded JAR opens a dataset at launch; `mvn -P native-package
    package` runs `jpackage` to produce platform-native installers
    (`.deb`/`.rpm`/`.dmg`/`.msi`) at `target/installer/`. `NativeLibraryLoader` resolves the
  library via `System.loadLibrary` → bundled-resource extract →
  graceful degradation (Intel Mac and other unbundled platforms get
  a placeholder in the genomic Read Inspector; all non-genomic
  features keep working). Built and validated via the
  `release-shaded-jar.yml` GitHub Actions matrix workflow
  (`ubuntu-22.04` + `macos-14` arm64 + `windows-2022` MinGW UCRT64).
  See [`tio-browser/README.md`](tio-browser/README.md) for the
  install matrix, build-from-source instructions, release path, and
  rationale for arm64-only macOS / MinGW-w64 Windows.

- `Quantification.unit` field (Java / Python / ObjC) — optional
  per-quantification unit string (e.g. `"fmol"`, `"ng/mL"`). Stored
  as a JSON-array sidecar attribute `@quantification_units` on
  `/study/quantifications` for backward-compat (legacy datasets read
  back with empty units). Surfaced as a column in `tio-browser`'s
  Quantifications tab.

- `MassSpectrum.isCentroided()` / `is_centroided` / `isCentroided`
  (Java / Python / ObjC) — per-spectrum centroid-vs-profile
  classification, stored as a parallel-array column
  `spectrum_index/centroideds` (int32, 0=profile, 1=centroided).
  Wire-format additive optional column; legacy files read as
  `false` for all rows. Used by `tio-browser`'s spectrum plot to
  auto-select stem rendering for centroided MS.

- `AcquisitionRun.spectra() : List<Spectrum>` (Java) /
  `acquisition_run.spectra` property (Python) /
  `-[TTIOAcquisitionRun spectra]` (ObjC) — modality-uniform spectrum
  enumeration, replacing the `for(i)+objectAtIndex+instanceof`
  pattern. Includes new `AcquisitionMode` constants
  `RAMAN` / `IR` / `UV_VIS` (ordinals 9 / 10 / 11) and an
  `AcquisitionRun.solvent` attribute (default `""`) for NMR runs.

- `ReferenceImport.writeToDataset` (Java),
  `-[TTIOReferenceImport writeToDataset:overwrite:error:]` (ObjC) —
  public counterpart to Python's `ReferenceImport.write_to_dataset`,
  closing the cross-language API parity gap on the reference-write
  path. Each language now has matching `readFromGroup` /
  `writeToDataset` symmetry. All three writers produce a
  byte-identical `/study/references/<uri>/` subtree (same `@md5`,
  `@reference_uri`, per-chromosome `@length`, and ZLIB-compressed
  UINT8 `data`); verified by structural comparison across Python,
  Java, and ObjC fixtures.

---

## [1.2.0] — 2026-05-08

### Added
- **`MSImage.mz_axis`**: shared m/z spectral axis on `MSImage` across
  Java, Python, and ObjC. Persisted as a 1-D FLOAT64 dataset under
  `/study/image_cube/mz_axis`. Required for imzML export of an
  `MSImage`-bearing `.tio`.
- **`MSImage.toPixelSpectra()` / `to_pixel_spectra()` / `-pixelSpectra`**:
  continuous-mode projection of the cube into per-pixel `(mz, intensity)`
  records suitable for `ImzMLWriter.write`.
- **`SpectralDataset.image()` / `.image` / `-msImage`**: accessor on the
  open dataset returning the materialised `MSImage` if `/study/image_cube`
  is present. Pattern mirrors the 1.1.0 `references()` accessor.
- **Python `SpectralDataset.write_minimal(image=...)`**: high-level
  kwarg writes the image cube alongside runs.
- **Python `MSImage.write_to(study_group)` / `MSImage.read_from(study_group)`**:
  standalone storage methods mirroring Java's `writeTo` / `readFrom`.
- **ObjC `TTIOPixelSpectrum`**: new value class for `-pixelSpectra` output.

### Backwards compatibility
- v1.1.x `.tio` files without `mz_axis` read as empty axis; the imzML
  exporter raises a clear error pointing at re-import.
- v1.1.x readers transparently skip the `mz_axis` dataset when reading
  v1.2.0-written files.

### Cross-language conformance
- New `python/tests/conformance/test_msimage_xlang.py` asserts byte-equal
  `mz_axis` payloads when written by Python and read back by Java + ObjC.
- Bug fix: `Hdf5Group.openDataset` (Java) now correctly handles N-D datasets,
  fixing a silent length-truncation that previously made Python-written
  `.tio` files unreadable from Java.

## [1.1.0] — 2026-05-06

Pure additive release. No wire-format change: `.tio` files written
by 1.0.0 are read identically by 1.1.0 and vice versa.

### Added

- `SpectralDataset.references()` (Java),
  `SpectralDataset.references` property (Python), and
  `[TTIOSpectralDataset references]` (ObjC) — enumerates embedded
  references at `/study/references/<reference_uri>/` for opened
  datasets, keyed by reference URI. Datasets written without
  embedded references (writer flag `embedReference = false`) return
  an empty map regardless of whether individual genomic runs carry a
  `referenceUri`. Cross-language parity verified by
  `python/tests/conformance/test_references_xlang.py` (9 directed
  pairs).
- `ReferenceImport.readFromGroup` (Java) /
  `ReferenceImport.read_from_group` (Python) /
  `+[TTIOReferenceImport readFromGroup:]` (ObjC) — factory that
  materialises a `ReferenceImport` from its on-disk group.

### Fixed

- ObjC writer's reference-embed path no longer requires `libttio_rans`
  to be available. Embedding `/study/references/<uri>/...` is pure HDF5
  I/O and now fires whenever `embedReference=YES` on a
  `TTIOWrittenGenomicRun`, matching Python's behavior. Signal-channel
  encoding via REF_DIFF_V2 still gates on the native lib (unchanged).
  Resolves the writer-gate asymmetry finding from Phase 0 Task 0.6.

### Changed

- Unified `@md5` attribute computation on
  `/study/references/<uri>/` to a single seq-only form across all
  writers and helpers. Previously, REF_DIFF_V2 auto-embed used
  `MD5(seq_a || seq_b || ...)` (sorted by name) while FASTA-import
  writers and the public canonical helpers
  (`compute_reference_md5` / `ReferenceImport.computeMd5` /
  `+[TTIOReferenceImport computeMd5WithChromosomes:sequences:]`)
  used `MD5(name_a || 0x0A || seq_a || 0x0A || ...)`. All three
  paths now agree on the seq-only form, which was already the
  authoritative on-disk digest. Existing v1.0.0 files written via
  REF_DIFF_V2 auto-embed are unchanged (their on-disk `@md5` was
  already seq-only). Existing v1.0.0 files written via FASTA-import
  retain their on-disk `@md5` verbatim through the v1.1.0
  `read_from_group` / `readFromGroup` path; only the auto-recompute
  fallback (when `md5=None` / `md5=null` / `md5:nil` is passed to
  the constructor) now produces a seq-only digest. Resolves the
  three-form `@md5` finding from Phase 0 Task 0.6.

### Notes

- ObjC has no canonical library-version constant; the version bump
  applies only to the Java pom and Python `__version__` /
  `pyproject.toml` metadata.
- The on-disk reference layout itself is unchanged from 1.0.0 —
  v1.1.0 only fills in the previously-missing read path. See
  `docs/format-spec.md` §10.10 (subsection "Reading embedded
  references") for the exact byte layout and the `@md5` form note.

---

## [post-v1.0.0 perf + parity tweaks — included in 1.1.0]

All correctness-neutral (same wire bytes, same on-disk container).
Headline numbers + reproducer instructions consolidated in
`docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md`
§11.

### Performance

- **24× FASTQ re-export speedup** (Python). The hot loop in
  `FastqWriter.write(GenomicRun, ...)` materialised one
  `AlignedRead` per record, which decoded cigar + mate triple
  for every read — fields FASTQ does not need. Now pre-fetches
  the whole `sequences` + `qualities` byte buffers + read-names
  list once, slices in-memory. 11K reads/s → 265K reads/s on
  1M reads × 100bp (commit `ae9441d`).
- **Java + ObjC FASTQ writer bulk-fetch parity** mirrors the
  same fix. Java now sustains ~750K reads/s on the same 1M
  workload; ObjC ~635K reads/s (commit `0f99852`). New
  microbenches: `FastqBulkBenchTest` (Java, opt-in via
  `-DTTIO_FASTQ_BENCH=1`) + `objc/Tools/obj/TtioFastqBench`.
- **Java transport genomic encode 33 → 235K reads/s (+612%)** at
  100K reads × 100bp (commits `758b340` + `701f310`). Two
  fixes: (1) memoised `GenomicRun.isMateInfoInlineV2()` after
  noticing the probe reopened the `mate_info` HDF5 group 3× per
  record (300K group opens at 100K reads, ~2.2s of pure
  framework overhead — ObjC already cached this via
  `_mateInfoLinkType`), and (2) eager-cached the M82 compound
  fall-through of `cigarAt` + bypassed per-record `AlignedRead`
  materialisation in `TransportWriter`. At 1M reads: 328K rps.
  Java is now ~40% faster than ObjC on this workload. New
  microbench: `TransportEncodeBenchTest`.
- **ObjC transport genomic encode 70 → 164K reads/s (+134%)**
  (commit `d5e2e25`). Same per-record `[grun readAtIndex:i]` →
  `dataUsingEncoding:` re-encode roundtrip Java had. Now bulk-
  fetches `wholeSequencesData` / `wholeQualitiesData` /
  `allReadNames` once. New microbench: `TtioTransportEncodeBench`.
- **Python + ObjC `cigar_at` eager-cache (parity with Java)**
  (commit `7ac32e4`). M82 compound fall-through no longer
  re-decodes per call. Python: 10 → 36K rps at 100K reads
  transport encode (+260%). ObjC: net-neutral on the test
  fixture but protective for any NSData-typed compound returns.
- **Byte-channel cache audit** (`GenomicRun.byteChannelSlice` /
  `-byteChannelSliceNamed:`). The codec-compressed path cached;
  the uncompressed path returned the raw HDF5 buffer per call,
  so `sequencesFull` / `-wholeSequencesData` warmups were
  silently a no-op for files written with `signal_compression =
  NONE`. Fixed in both Java + ObjC (commit `221611c`).

### Cross-language parity gates

- **nmrML 3-way probe parity** — `NmrMLProbe.java`,
  `TtioNmrMLProbe.m`, and a Python harness drive all three
  readers against synthetic + `bmse000325` inputs and assert
  bit-exact JSON for `numberOfScans` /
  `spectrometerFrequencyMHz` / `fidReal` / `fidImag` (commit
  `8c6b8b0`).
- **mzML 3-way probe parity** — `MzMLProbe.java`,
  `TtioMzMLProbe.m`, and `test_mzml_cross_lang_parity.py` cover
  synthetic + `tiny.pwiz.1.1.mzML` fixtures with full mz +
  intensity arrays plus precursor / polarity / RT scalars.

### mzML reader bug-fixes

- **Java**: `endElement("binary")` no longer skips spectra with
  empty `<binary></binary>` arrays (PSI-MS reference fixture
  intentionally tests this via its "spectrum with no data"
  userParam). 4-spectrum `tiny.pwiz` now reports 4 spectra (was
  3) (commit `01ca2b4`).
- **Python + ObjC**: `<referenceableParamGroupRef>` is now
  resolved. Both readers buffer cvParams under each
  `<referenceableParamGroup id="...">` and replay them when a
  spectrum / chromatogram cites the group via
  `<referenceableParamGroupRef ref="...">`. Polarity (and any
  other CV param) on referenced groups now reaches the
  per-spectrum surface (same commit).

### Documentation

- `docs/cross-language-matrix.md` gains entries for the two new
  probe-style parity tests + CLI inventory rows for the four
  new probe binaries.
- `docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md`
  §11 documents the post-v1.0.0 perf tweaks with reproducer
  invocations.

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

### Cross-language nmrML reader parity

The Python `ImportResult` gained four nmrML acquisition-parameter
fields on 2026-05-05 (`spectrometer_frequency_mhz`,
`number_of_scans`, `fid_real`, `fid_imag`); Java and ObjC sibling
readers now surface the same fields:

- **Java** `NmrMLReader.NmrMLResult` exposes
  `spectrometerFrequencyMHz()`, `numberOfScans()`, `fidReal()`,
  `fidImag()`. The parser also accepts
  `<irradiationFrequency value="...">` directly inside
  `<acquisitionParameterSet>` (matches Python; previously
  required `<directDimensionParameterSet>`).
- **ObjC** `TTIONmrMLReader` now also exposes deinterleaved
  `fidReal` / `fidImag` `NSData` properties alongside the
  pre-existing `spectrometerFrequencyMHz` / `numberOfScans`.

### Native codec fixes

- **NAME_TOKENIZED_V2** (codec id 15): decoder MATCH path no
  longer rejects valid encoded blobs whose pool entry has a
  different total token count than the block's column shape.
  Surfaced by the production-corpus decode benchmark on real
  Illumina BAMs with mixed flowcell prefixes (e.g. `H2YHMBCXX`
  tokenises to 3 tokens vs `H2YT5BCXX`'s 5 tokens because of
  the internal digit). Permanent regression guard at
  `python/tests/test_name_tokenizer_v2_native.py::test_mixed_flowcell_token_count_regression`;
  minimal failing fixture preserved at
  `python/tests/fixtures/codecs/name_tok_v2_corrupt_94.txt`.
- **Bruker TDF importer**: `frame2retention_time` returned a 1-D
  ndarray under opentimspy ≥ 1.2 even for scalar input; the
  per-frame list comprehension produced a `(n, 1)` 2-D
  `retention_times` buffer that the writer rejected. Now passes
  the whole `frame_ids` array at once.
- **Zarr 3.x empty-chunk**: `ZarrProvider.create_dataset` now
  clamps chunk dims to ≥ 1 so empty datasets (length == 0) build
  cleanly under zarr-python 3.x.

### Format support — Bruker .tsf

`ttio.importers.bruker_tdf.read_metadata()` now recognises both
`analysis.tdf` (TIMS) and `analysis.tsf` (non-TIMS Bruker QTOF /
MALDI) `.d` directories. The SQLite metadata schema is shared,
so frame counts / retention times / instrument-vendor strings
parse identically. Full per-frame `read()` is TDF-only in v1.0
(opentimspy is TDF-only); calling it on a `.tsf` directory raises
`BrukerTDFUnavailableError` with a pointer at the
`msconvert` → mzML workaround.

### Performance — benchmark suites + microbench tooling

Three new perf harnesses for release-to-release tracking:

- **`python/tests/stress/test_fasta_fastq_benchmark.py`** —
  five scenarios per fixture size (FASTQ export / import,
  FASTA export / import, FASTQ → `.tio` → FASTQ round-trip)
  at 1K, 10K, plus opt-in 100K and 1M reads via
  `TTIO_INCLUDE_LONG_TAIL=1`.
- **`python/tests/stress/test_production_corpus_benchmark.py`** —
  BAM → `.tio` → decode-all-reads cycle against the real corpora
  under `data/genomic/` (synthetic, na12878 chr22, na12878 WES,
  hg002 Illumina subset, hg002 PacBio). The full 1.6 GB
  hg002 chr22 BAM is opt-in via `TTIO_INCLUDE_FULL_CORPUS=1`.
- **`global.thalion.ttio.tools.Benchmark` (Java) +
  `TtioBenchmark` (ObjC)** — pair with the Python harnesses to
  give cross-language perf-tracking parity. Both emit the same
  JSON schema so a single `jq` over the three result files
  diffs cleanly.

Headline numbers consolidated in
`docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md`.

### Build + dev workflow

- **`scripts/dev-setup.sh`** — one-shot Python developer setup:
  builds `libttio_rans.so` + JNI wrapper, installs the package
  with the broadest test extras, prints required env-var
  exports. PEP 668 (Ubuntu 24.04+ externally-managed) friendly.
- **`scripts/fetch-vendor-fixtures.sh`** — downloads + sha256-
  verifies the public Thermo `small.RAW` (MIT, ~1.5 MB) and
  Bruker `diaPASEF.d` (Apache-2.0, ~1 MB) fixtures from upstream
  repos. Manifests pinned at `data/vendor/{thermo,bruker}/*.sha256`.
- **CI** (`.github/workflows/ci.yml`):
  - All Python jobs (`python-test`, `python-validation`,
    `python-stress`) now build the native rANS library + JNI
    wrapper before running pytest. Previously skipped ~90 v2-codec
    tests silently because the runtime library was never present.
  - New `python-vendor-fixtures` job exercises the Bruker TDF +
    Thermo `.raw` integration paths on every push/PR (mono +
    ThermoRawFileParser v1.4.5 + sha256-pinned fixtures).
- **`CONTRIBUTING.md`** added — top-level entry point with
  quick-start, repo layout, per-language test commands, optional
  fixture flow, code style notes.
