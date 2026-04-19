# CHANGELOG

All notable changes to the MPEG-O multi-omics data standard reference
implementation. Dates are release dates; the repository commits record
the actual timeline.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/) — the
leading `0.` means the public API is still stabilising; see
`docs/api-stability-v0.8.md` for the per-symbol stability tags.

---

## [v0.9.0] — 2026-04-19

### Added
- **M57** Integration test infrastructure + fixture management
  (`download.py`, pinned source URLs, in-repo fallbacks).
- **M58** Cross-tool round-trip integration tests: mzML, nmrML,
  Thermo `.raw`, Bruker `.d`.
- **M59** imzML + `.ibd` importer. Python reference, then
  Objective-C + Java for three-language parity.
- **M60** mzTab importer (proteomics 1.0 + metabolomics 2.0.0-M)
  across Python + ObjC + Java.
- **M61** End-to-end workflow + security-lifecycle test matrix
  (84 cross-provider cells: encryption, signature, anonymization).
- **M62** Stress + cross-provider benchmark suite (31 stress-marked
  cells); cross-language stress + validation suites for all three
  languages.
- **M63** Waters MassLynx `.raw` importer (Python + ObjC + Java),
  delegation pattern through `MassLynxRawReader` where SDK present,
  open-source fallback otherwise.
- **M64** Cross-tool validation + nightly stress CI; closed
  several v1.0 exporter gaps surfaced by xfails.
- **mzML, nmrML, ISA-Tab, imzML, mzTab exporters** (the latter
  two new in v0.9). Every format MPEG-O reads, it can now write.
  - **nmrML** spectrum1D XSD gap closed via interleaved `(x,y)`
    encoding (M64 follow-up).
  - **imzML** exporter across all three languages (commit
    `ff0f201`); fixed an importer cv-accession misclassification
    (`MS:1000030`/`MS:1000031` are vendor / instrument-model, not
    IMS mode).
  - **mzTab** exporter across all three languages (commit
    `3c67ba9`), round-trips bit-identically through the reader.

### Changed
- **Zarr v2 → v3 on-disk migration** across all three language
  providers. Each node is now a single `zarr.json` file
  (`node_type: group | array`) with attributes nested inside;
  array chunks live under a `c/` prefix (`c/0/1/2`); dtypes use
  canonical names (`float64`, `int32`, ...). Compression on read
  accepts the `gzip` codec written by zarr-python's `GzipCodec`.
  - Python uses zarr-python 3.x (`LocalStore`, `FsspecStore`,
    `MemoryStore`, `create_array(compressors=...)`).
  - Java + ObjC self-contained writers/readers updated to emit and
    parse v3 layout byte-for-byte against zarr-python output.
  - No backward-compat shim — pre-deployment, no v2 stores in the
    wild. Read side does still accept legacy v2 dtype strings
    (`<f8`, `<i4`, ...) for safety.
- **M64.5** caller-refactor across all three languages so
  `SpectralDataset.open` / `write_minimal` dispatch on URL scheme
  (HDF5 / Memory / SQLite / Zarr). Phase A (Python), phase B
  (provider-aware Encryption/Signature/Anonymizer), phase C
  (KeyRotationManager + MSImage cube cross-provider). Java + ObjC
  follow-up landed `ProviderRegistry.open` and
  `+readViaProviderURL:` paths. 39 of 39 cross-provider cells
  pass; the remaining `memory`-as-cross-process xfail is by design.
- **Performance**: instrumented all three languages, shipped three
  targeted optimisations, dropped 5.6 MB of dead-weight from the
  ObjC harness, and brought Java index-format parity. Pure-C
  baseline now exists; ObjC sits at ~1.3× over raw C (documented
  in `tools/perf/`).

### Test counts
- Python 586 pass / 11 skip / 4 xfail (was 341)
- Objective-C 1271 PASS (was 656)
- Java 245 pass (was 207)

---

## [v0.8.0] — 2026-04-18

### Added
- **M49** Post-quantum crypto: ML-KEM-1024 (FIPS 203) envelope
  key-wrap and ML-DSA-87 (FIPS 204) dataset signatures. New `v3:`
  signature-attribute prefix; `opt_pqc_preview` feature flag
  auto-set whenever either primitive runs. Python and Objective-C
  use liboqs; Java uses Bouncy Castle 1.80+. Rationale: `docs/pqc.md`.
  - **M49.1** ObjC dataset / envelope integration via
    `MPGOSignatureManager` + `MPGOKeyRotationManager`.
- **M52** Java and Objective-C `ZarrProvider` ports. Self-contained
  LocalStore implementations — no external zarr library dependency.
  Same on-disk layout as the Python reference so all three languages
  cross-read one another's stores. (On-disk format migrated from
  Zarr v2 to v3 in v0.9; see Unreleased.)
- **M53** Bruker timsTOF `.d` importer. SQLite metadata reads
  natively in every language; binary frame decompression uses
  `opentimspy` + `opentims-bruker-bridge` in Python and subprocesses
  into the Python helper from Java / Objective-C. New
  `inv_ion_mobility` signal channel preserves the 2-D timsTOF
  geometry per-peak. Details: `docs/vendor-formats.md`.
- **M54 + M54.1** 32-cell cross-language × cross-provider PQC
  conformance matrix: primitive ML-DSA / ML-KEM, v3 signatures on
  HDF5 / Zarr / SQLite, v2+v3 coexistence, v0.7 backward-compat.
  New `com.dtwthalion.mpgo.tools.PQCTool` (Java) and
  `MpgoPQCTool` (ObjC) CLIs drive the harness. New Python
  `sign_storage_dataset` / `verify_storage_dataset` provider-agnostic
  helpers.

### Changed
- **Binding decision 42 (revised)** — see `docs/pqc.md`. Python
  `cryptography` 46 does not yet expose ML-KEM / ML-DSA, so
  Python + ObjC use `liboqs` instead of the originally-planned
  OpenSSL 3.5 path. Java keeps the Bouncy Castle plan.
- `CipherSuite` catalog: `ml-kem-1024` and `ml-dsa-87` graduate
  from `reserved` to `active`. `shake256` remains reserved.
  ML-DSA-87 public-key size corrected from 4864 → 2592 bytes
  (FIPS 204 §4).
- `validate_key(algorithm, key)` now rejects asymmetric algorithms
  with an explicit redirect to `validate_public_key` /
  `validate_private_key`. Symmetric-only by design.
- `java/run-tool.sh` git mode promoted from 100644 to 100755 so
  the parity tests stop skipping on fresh clones.

### Deprecated
- `v0.7` API surface marks nothing new as removed in v0.8. See
  `docs/api-stability-v0.8.md` for the v1.0 deprecation candidates.

### Fixed
- Python + Objective-C provider `read_canonical_bytes` on signed
  datasets now round-trips through every shipping provider
  (HDF5, Memory, SQLite, Zarr).

---

## [v0.7.0] — 2026-04-18

### Added
- **M41** SQLite storage provider across ObjC / Python / Java.
- **M43** `read_canonical_bytes()` protocol method enables
  cross-backend signature verification.
- **M44** Protocol-native `AcquisitionRun` and `MSImage` — upper
  layers go through `StorageGroup` instead of raw HDF5 handles.
- **M45** `create_dataset_nd` across all providers; native N-D
  image cubes + 2-D NMR matrices via the protocol.
- **M46** Python `ZarrProvider` reference implementation (stretch;
  Java / ObjC ports land in v0.8 M52).
- **M47** Wrapped-key blob format v1.2 — algorithm-discriminated
  envelope (`magic "MW" | version | algorithm_id | ct_len |
  md_len | metadata | ciphertext`). Reserves `algorithm_id=0x0001`
  for ML-KEM-1024 (activated in v0.8 M49).
- **M48** `CipherSuite` catalog with reserved PQC algorithm IDs
  and an `algorithm=` keyword parameter threaded through
  encryption / signing / wrapping.
- **M50** Cross-language consistency hardening (six Appendix-B
  gap resolutions: `open()` signatures, `readRows()`, capability
  queries, `provider_name` shape, precision decoupling, attribute
  del/enum).
- **M51** Compound write byte-parity harness across three
  languages — 9-cell interop grid.

### Changed
- `mpeg_o_format_version` bumps from `1.1` to `1.2`.
- Default wrapped-key layout is v1.2 (71 bytes for AES-GCM);
  v1.1 (60-byte fixed) remains readable indefinitely.

### Baseline
- Objective-C: 1057 assertions pass.
- Python: 284 tests pass.
- Java: 179 tests pass.

---

## [v0.6.1] — 2026-02

SQLite provider stress-test; six Appendix-B gap fixes shipped
inline (dual-style `open()`, `read_rows()` protocol method,
capability queries, etc.).

## [v0.6.0] — 2026-02

- **M33-M39** Storage provider abstraction land. Three-language
  parity across HDF5, Memory, and (v0.7) SQLite backends.
- Java reaches full feature parity with ObjC and Python.

## [v0.5.0] — 2025-12

- **M30-M33** Three-way conformance test harness across the
  three languages; shared fixture generator.
- Three-language feature parity achieved on the M11-M29
  milestone block.

## [v0.4.0] — 2025-10

- **M25** Envelope encryption + key rotation: DEK + KEK model,
  `/protection/key_info/` group layout.
- **M26-M28** Spectral anonymisation pipeline, nmrML writer,
  chromatogram API.
- `opt_key_rotation`, `opt_anonymized` feature flags.

## [v0.3.0] — 2025-08

- **M17-M24** Compound per-run provenance, `v2:` canonical-byte
  signatures, LZ4 + Numpress-delta compression, chromatogram
  import (M24).

## [v0.2.0] — 2025-06

- **M11-M16** Core dataset model: `/study/ms_runs/*/spectrum_index`,
  signal-channels group, compound `identifications` /
  `quantifications` / `provenance` datasets, v1 HMAC signatures.
- `mpeg_o_format_version = "1.1"` and `mpeg_o_features` JSON
  array introduced.

## [v0.1.0-alpha] — 2025-04

- **M1-M10** Initial ObjC reference implementation with HDF5
  backing store. Core spectrum hierarchy
  (`MPGOMassSpectrum`, `MPGONMRSpectrum`, `MPGOFreeInductionDecay`,
  `MPGOMSImage`). Basic mzML reader.

---

## Notes on format compatibility

- **Write-forward** — readers must refuse files carrying a
  required feature they don't recognise. Optional features
  (prefixed `opt_`) are ignored.
- **Read-backward** — every reader reads the full v0.1 through
  v0.8 range. The v1.1 wrapped-key blob (60-byte fixed) remains
  decryptable indefinitely (HANDOFF binding #38).
- Classical HMAC-SHA256 signatures (`v2:` prefix) continue to
  verify after the v0.8 PQC activation; post-quantum signatures
  (`v3:` prefix) raise `UnsupportedAlgorithmError` on v0.7-and-
  earlier readers, which is the correct behaviour.
