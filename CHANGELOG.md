# CHANGELOG

All notable changes to the MPEG-O multi-omics data standard reference
implementation. Dates are release dates; the repository commits record
the actual timeline.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/) — the
leading `0.` means the public API is still stabilising; see
`docs/api-stability-v0.8.md` for the per-symbol stability tags.

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
  Zarr v2 DirectoryStore implementations — no external zarr library
  dependency. Same on-disk layout as the Python reference so all
  three languages cross-read one another's stores.
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
