# MPEG-O Workplan

Eight milestones, each with concrete deliverables and acceptance criteria. Milestones are strictly sequential — each builds on the previous.

---

## Milestone 1 — Foundation (Protocols + Value Classes)

**Deliverables**

- All five protocol headers under `objc/Source/Protocols/`:
  - `MPGOIndexable.h`
  - `MPGOStreamable.h`
  - `MPGOCVAnnotatable.h`
  - `MPGOProvenanceable.h`
  - `MPGOEncryptable.h`
- Value classes under `objc/Source/ValueClasses/`:
  - `MPGOCVParam` — `ontologyRef`, `accession`, `name`, `value`, `unit`
  - `MPGOAxisDescriptor` — `name`, `unit`, `valueRange`, `samplingMode`
  - `MPGOEncodingSpec` — `precision`, `compressionAlgorithm`, `byteOrder`
  - `MPGOValueRange` — `minimum`, `maximum`
- All value classes conform to `NSCoding` and `NSCopying`, with overridden `-isEqual:` and `-hash`.
- GNUStep Make build system compiling `libMPGO` as a shared library.
- Test binary `MPGOTests` runnable via `make check`.

**Acceptance Criteria**

- [x] `make` in `objc/` produces `libMPGO.so` (or platform equivalent).
- [x] `make check` in `objc/` runs `MPGOTests` and all value class tests PASS.
- [x] Each value class: construction, equality, hashing, copying, NSCoding round-trip.
- [x] Edge cases covered: nil optional fields, zero-width ranges, extreme precisions.

---

## Milestone 2 — SignalArray + HDF5 Wrapper

**Deliverables**

- HDF5 wrappers under `objc/Source/HDF5/`:
  - `MPGOHDF5File` — thin wrapper around `H5Fcreate`/`H5Fopen`/`H5Fclose`
  - `MPGOHDF5Group` — `H5Gcreate2`/`H5Gopen2`/`H5Gclose`
  - `MPGOHDF5Dataset` — `H5Dcreate2`/`H5Dwrite`/`H5Dread`/`H5Dclose`
  - `MPGOHDF5Attribute` — `H5Acreate2`/`H5Awrite`/`H5Aread`
- Type support: `float32`, `float64`, `int32`, `int64`, `uint32`, `complex128` (compound).
- Chunked storage via `H5Pset_chunk`.
- zlib compression via `H5Pset_deflate` (levels 0–9).
- `MPGOSignalArray` full implementation with HDF5 persistence.
- CVAnnotation storage on SignalArray that survives HDF5 round-trip.

**Acceptance Criteria**

- [x] Create / open / close an HDF5 file; file exists on disk.
- [x] Write & read float64 dataset, values match within 1e-12 epsilon.
- [x] Write & read chunked+compressed int32 dataset, byte-exact match.
- [x] Write & read complex128 dataset, real and imaginary components intact.
- [x] Partial read: write 1000 elements, read elements 500–599, verify.
- [x] `MPGOSignalArray` HDF5 round-trip: write → read → `-isEqual:` true.
- [x] Benchmark: 1M float64 elements, write < 100 ms, read < 100 ms (logged, PASS if under).
- [x] Error path: opening nonexistent file returns nil with populated `NSError`, no crash.

---

## Milestone 3 — Spectrum + Concrete Spectrum Classes

**Deliverables**

- `MPGOSpectrum` base class: named-SignalArray dictionary + coordinate axes + index position + scan time + optional precursor info.
- `MPGOMassSpectrum` with mandatory mz+intensity arrays, MS level, polarity, optional scan window.
- `MPGONMRSpectrum` with chemical shift + intensity, nucleus type, spectrometer frequency.
- `MPGONMR2DSpectrum` with 2D intensity matrix and F1/F2 axis descriptors.
- `MPGOFreeInductionDecay` extending SignalArray with real/imaginary components, dwell time, scan count, receiver gain.
- `MPGOChromatogram` with time/intensity arrays and TIC/XIC/SRM type enum.
- HDF5 serialization following the container design: each Spectrum is an HDF5 group; its SignalArrays are datasets within.

**Acceptance Criteria**

- [x] Construct a realistic 200-peak centroided MassSpectrum, round-trip, verify equality.
- [x] Construct a 32768-point NMR FID, round-trip, verify real/imag intact.
- [x] Construct a 2D NMR intensity matrix (e.g. 512×1024), round-trip, verify.
- [x] Chromatogram round-trip for each type (TIC, XIC, SRM).
- [x] MassSpectrum rejects construction with mismatched mz/intensity lengths.

---

## Milestone 4 — AcquisitionRun + SpectrumIndex (Access Unit model)

**Deliverables**

- `MPGOAcquisitionRun` managing an ordered, heterogeneous collection of Spectrum objects.
- `MPGOSpectrumIndex` — offsets + lengths + compound headers dataset.
- `MPGOInstrumentConfig` value class.
- Signal-channel separation: writing a run extracts all mz values into one contiguous dataset, all intensities into another, all scan metadata into a compound dataset.
- `MPGOIndexable` + `MPGOStreamable` fully exercised on runs.

**Acceptance Criteria**

- [x] Create a 1000-spectrum run, write to HDF5.
- [x] Random-access read of spectrum 0, 500, 999 — verify each without reading unrelated spectra (confirm via HDF5 chunk access counts or dataset region selection).
- [x] Range query "RT between 10.0 and 12.0 minutes" returns expected subset.
- [x] Streaming iteration through all 1000 spectra yields correct order.
- [x] `MPGOInstrumentConfig` round-trip as HDF5 compound attribute.

---

## Milestone 5 — SpectralDataset + Identification + Quantification + Provenance

**Deliverables**

- `MPGOSpectralDataset` as the root `.mpgo` file object managing `/study/`.
- `MPGOIdentification` linking spectrum refs to chemical entities + confidence + evidence chain.
- `MPGOQuantification` with abundance, sample reference, normalization metadata.
- `MPGOProvenanceRecord` with W3C PROV chain: inputs → activity (software + params) → outputs → timestamp.
- `MPGOTransitionList` for SRM/MRM transition definitions.
- Full HDF5 round-trip of a multi-run dataset with identifications and quantifications.

**Acceptance Criteria**

- [x] Build a dataset with 2 MS runs + 1 NMR run, 10 identifications, 5 quantifications, multi-step provenance.
- [x] Write to `.mpgo`, close, reopen, verify every field matches.
- [x] Provenance chain queryable by input entity reference.
- [x] TransitionList round-trip preserves collision energies and RT windows.

---

## Milestone 6 — MSImage (Spatial Extension)

**Deliverables**

- `MPGOMSImage` extending `MPGOSpectralDataset` with spatial grid indexing.
- Tile-based Access Units (32×32 pixel default).
- HDF5 3D layout `[x, y, spectral_points]` with tile-aligned chunking.

**Acceptance Criteria**

- [x] Create a 64×64 pixel MSImage with synthetic spectra.
- [x] Write to HDF5, reopen.
- [x] Read tile (0..31, 0..31) without reading the other three tiles.
- [x] Round-trip equality for the full image.

---

## Milestone 7 — Protection / Encryption

**Deliverables**

- `MPGOEncryptionManager` using AES-256-GCM (CommonCrypto or OpenSSL).
- `MPGOAccessPolicy` stored as JSON in `/protection/access_policies`.
- `MPGOEncryptable` conformance on `MPGOAcquisitionRun` and `MPGOSpectralDataset`.
- Selective encryption: encrypt `intensity_values` dataset while leaving `mz_values` and `scan_metadata` unencrypted.
- Encryption metadata (algorithm, IV, auth tag) as HDF5 attributes.

**Acceptance Criteria**

- [x] Encrypt an AcquisitionRun's intensity channel with a test key.
- [x] Verify unencrypted metadata (mz, scan headers) readable without key.
- [x] Decrypt with correct key → byte-exact match to original intensities.
- [x] Decrypt with wrong key → authenticated-decryption failure (GCM tag mismatch), no silent corruption.
- [x] Access policy JSON readable independently of key management.

---

## Milestone 8 — Query API + Streaming

**Deliverables**

- `MPGOQuery` class performing compressed-domain queries via SpectrumIndex header scanning.
- Predicate support: RT range, MS level, polarity, precursor m/z range, base peak intensity threshold.
- `MPGOStreamWriter` — append spectra to an open `.mpgo` file incrementally.
- `MPGOStreamReader` — sequential read with prefetch buffering.

**Acceptance Criteria**

- [x] Query a 10,000-spectrum dataset for "MS2 with RT in [10, 12] and precursor in [500, 550]".
- [x] Instrumentation confirms only AU headers are read; signal channel data is untouched until matching spectra are explicitly loaded.
- [x] StreamWriter writes 500 spectra incrementally; file is valid after each flush.
- [x] StreamReader reads the same 500 spectra in order, values match originals.
- [x] Query performance: 10k-spectrum header scan completes in < 50 ms (logged, PASS if under).

---

## Overall Release Criteria (v0.1.0-alpha)

- [x] All eight milestones complete with all tests passing locally (WSL) and in GitHub Actions CI. **379 tests pass on `ubuntu-latest`; benchmarks: 1M float64 write/read ~3 ms, 1000-spectrum run write ~22 ms, 10k-spectrum query scan ~0.2 ms.**
- [x] README, ARCHITECTURE, WORKPLAN, and all `docs/` files finalized.
- [x] No warnings under `-Wall -Wextra` with clang.
- [x] Tag `v0.1.0-alpha` pushed to `DTW-Thalion/MPEG-O`.

---

# v0.2.0 Milestones (M9–M15)

## Milestone 9 — mzML Reader

**Deliverables**

- `MPGOMzMLReader` SAX parser via `NSXMLParser` (Apache-2.0 in `Import/`).
- `MPGOBase64` decoder + optional zlib inflate.
- `MPGOCVTermMapper` hard-coded PSI-MS accession mappings.
- Real fixtures: `tiny.pwiz.1.1.mzML` + `1min.mzML` from HUPO-PSI.

**Acceptance Criteria**

- [x] Parses centroided mzML and verifies spectrum count + m/z/intensity arrays.
- [x] Handles zlib-compressed binary arrays.
- [x] Full round-trip: mzML → MPGO → `.mpgo` → read-back.
- [x] Malformed XML returns nil with NSError.

## Milestone 10 — Protocol Conformance + Modality-Agnostic Runs

**Deliverables**

- `MPGOAcquisitionRun` accepts any `MPGOSpectrum` subclass (MS + NMR proven).
- Name-driven signal channel serialization; v0.1 MS layout binary-compatible.
- `<MPGOProvenanceable>` + `<MPGOEncryptable>` conformance on runs.
- `MPGOEncryptionManager` file-path API marked with `MPGO_DEPRECATED_MSG`.

**Acceptance Criteria**

- [x] 100 MS + 50 NMR runs round-trip; compound header spot-check.
- [x] Per-run provenance chain round-trip via `@provenance_json`.
- [x] Protocol encrypt with persistence context delegates to encryption manager.
- [x] NMR query + streaming round-trip.
- [x] v0.1 backward compat via inline-synthesized legacy layout.

## Milestone 11 — Native HDF5 Compound Types

**Deliverables**

- `MPGOHDF5CompoundType` wrapper (H5Tcreate compound + VL string helper).
- `MPGOFeatureFlags` versioning utility (`@mpeg_o_format_version`, `@mpeg_o_features`).
- `MPGOCompoundIO` for identifications / quantifications / dataset provenance / index headers.
- `MPGOSpectralDataset.closeFile` + full `<MPGOEncryptable>` conformance.
- Sealed compound blobs + `@encrypted` marker + `@access_policy_json`.

**Acceptance Criteria**

- [x] 100 idents / 50 quants / 5 prov records round-trip via compound.
- [x] Feature flags present, queryable, JSON fallback for v0.1 files.
- [x] Compound headers readable via `H5Dread` hyperslab.
- [x] Dataset-level encrypt seals compound datasets and protects intensity channels.
- [x] Performance: 10 k identifications write/read < 50 ms each.

## Milestone 12 — MSImage Inheritance + Native 2D NMR

**Deliverables**

- `MPGOMSImage` inherits `MPGOSpectralDataset`; cube at `/study/image_cube/`.
- Spatial metadata properties (`pixelSizeX/Y`, `scanPattern`).
- `MPGONMR2DSpectrum` writes native rank-2 dataset `intensity_matrix_2d` with `H5DSattach_scale` dim scales.
- `opt_native_2d_nmr` and `opt_native_msimage_cube` feature flags.

**Acceptance Criteria**

- [x] Inherited idents/quants/provenance round-trip through MSImage.
- [x] v0.1 `/image_cube` fallback via inline-synthesized legacy layout.
- [x] 256×128 HSQC rank-2 dataset + scale count verified via direct H5 inspection.
- [x] v0.1 flattened 2D NMR fallback after deleting native dataset.

## Milestone 13 — nmrML Reader

**Deliverables**

- `MPGONmrMLReader` SAX parser for nmrML 1.0+ (Apache-2.0 in `Import/`).
- nmrCV accession predicates on `MPGOCVTermMapper`.
- Real fixture: `bmse000325.nmrML` from BMRB via the nmrML project.
- Real-file parser extensions: element-based acquisition params, int32/int64 FID widening.

**Acceptance Criteria**

- [x] Synthetic FID + spectrum1D round-trip with exact byte match.
- [x] Real BMRB fixture: numberOfScans, nucleus, frequency, sweep width, 16384-sample FID extracted correctly.
- [x] Round-trip nmrML → MPGO → `.mpgo` → read-back.
- [x] Malformed XML returns nil with NSError.

## Milestone 14 — Digital Signatures + Integrity Verification

**Deliverables**

- `MPGOSignatureManager` HMAC-SHA256 over dataset bytes via OpenSSL.
- `MPGOVerifier` higher-level status API (Valid/Invalid/NotSigned/Error).
- Provenance chain signing on `@provenance_json`.
- `opt_digital_signatures` feature flag.

**Acceptance Criteria**

- [x] Sign + verify intensity channel; tamper one byte → Invalid with descriptive error.
- [x] Unsigned dataset returns NotSigned cleanly.
- [x] Provenance chain sign + verify.
- [x] 1M float64 sign ~9 ms / verify ~5 ms (< 100 ms target).

## Milestone 15 — Format Specification + v0.2.0 Release

**Deliverables**

- `docs/format-spec.md` — complete HDF5 layout spec for third-party readers.
- `docs/feature-flags.md` — registry with semantics and introducing milestone.
- `objc/Tools/MakeFixtures` — reference fixture generator.
- Reference `.mpgo` fixtures under `objc/Tests/Fixtures/mpgo/`.
- WORKPLAN updated; README + ARCHITECTURE notes on v0.2 changes.

**Acceptance Criteria**

- [x] format-spec.md is self-contained (third-party Python reader implementable).
- [x] feature-flags.md covers all v0.2 flags plus v0.3 reserved slots.
- [x] 5 reference fixtures generated deterministically and documented.
- [x] M9–M15 all green; full suite passes with zero non-deprecation warnings.

## Overall Release Criteria (v0.2.0)

- [x] All seven v0.2 milestones complete with tests passing locally and in CI. **656 tests pass.**
- [x] v0.1.0-alpha `.mpgo` files remain readable via v0.2 fallback paths (verified in TestMilestone10, TestMilestone11, TestMilestone12).
- [x] No non-deprecation warnings under `-Wall -Wextra` with clang.
- [x] `docs/format-spec.md` and `docs/feature-flags.md` published.
- [x] Reference `.mpgo` fixtures under `objc/Tests/Fixtures/mpgo/` committed.
- [x] Tag `v0.2.0` pushed to `DTW-Thalion/MPEG-O` (`61a3968`).

## v0.3 Deferred Follow-Ups

Items explicitly scoped out of their originating v0.3 milestone and
parked here for a later pass. Each one has a pointer to where in the
code the gap currently lives so it can be picked up without re-reading
the full milestone history.

### Milestone 19 — mzML Writer

- [x] **Chromatogram emission in the mzML writer.** *Shipped with
      M24 (v0.4.0) once `MPGOAcquisitionRun.chromatograms` became a
      first-class property.* All three mzML writers now walk
      `run.chromatograms` into a `<chromatogramList>` followed by a
      second `<index name="chromatogram">` entry inside the
      `<indexList>`:
      `objc/Source/Export/MPGOMzMLWriter.m:293`,
      `python/src/mpeg_o/exporters/mzml.py:217`,
      `java/src/main/java/com/dtwthalion/mpgo/exporters/MzMLWriter.java:176`.
      Round-trip covered by `TestMilestone24.m` and
      `test_milestone24_chromatograms.py`.

- [x] **Direct byte-for-byte parity test between the ObjC and Python
      mzML writers.** *Shipped and green.* `objc/Tools/MpgoToMzML.m`
      is a minimal CLI modelled on `MpgoVerify` / `MpgoSign`, and
      `python/tests/test_mzml_writer_parity.py` drives both writers
      on the same fixture and structurally diffs the output (masking
      indexListOffset, fileChecksum, and absolute-byte offset
      attributes that encode file state). The harness caught a real
      cross-language read-path bug on first run: ObjC's
      `MPGOHDF5Group.openDatasetNamed:` didn't probe for
      `H5T_NATIVE_UINT64` and fell through to `MPGOPrecisionFloat64`,
      so Python-written `spectrum_index/offsets` (uint64 per
      format-spec §6) were read with an implicit HDF5 int-to-float
      conversion and `MPGOMzMLWriter` silently dropped every spectrum
      after index 0 when `spectrumAtIndex:` returned nil. Fix: the
      precision probe now maps `H5T_NATIVE_UINT64 → MPGOPrecisionInt64`
      (bit-identical for non-negative values). Parity test now
      passes.

### Milestone 20 — Cloud-Native Access

- [x] **Objective-C cloud-native `.mpgo` access.** *Shipped via
      option 1 (ROS3 VFD).* Apt's `libhdf5-dev` on modern Debian /
      Ubuntu ships `H5Pset_fapl_ros3` enabled — the WORKPLAN's
      original assumption that a libhdf5 rebuild would be required
      is stale, so the CI-rebuild subtask is obviated.
      `MPGOHDF5File` grows `+openS3URL:region:accessKeyId:
      secretAccessKey:sessionToken:error:` plus an `+isS3Supported`
      capability probe; `s3://` canonical URLs are translated to
      `https://bucket.s3.region.amazonaws.com/key` internally before
      being passed to `H5Fopen` with a ROS3-configured FAPL.
      `objc/check-deps.sh` probes the linked `libhdf5.so` for
      `H5Pset_fapl_ros3` and reports ROS3 availability in the
      pre-build check. `objc/Tests/TestCloudAccess.m` covers
      `+isS3Supported` and the unresolvable-bucket error path (no
      network required). Options 2 (custom VFD) and 3
      (download-then-open fallback) remain deferred — option 1
      covers S3 and any S3-compatible endpoint (MinIO, LocalStack,
      etc.) which is the overwhelmingly common cloud topology.

      The on-disk `.mpgo` layout is unchanged by any of these, so
      the milestone is a *transport* concern, not a *format* one.
      Cloud-hosted files written from Python (including those that
      carry v2 canonical signatures and compound per-run provenance)
      are already readable by the ObjC reader as soon as they reach
      a POSIX path.

      Touches (option 1 path): `objc/Source/HDF5/MPGOHDF5File.{h,m}`
      (new `openS3URL:` entry point), `objc/check-deps.sh` (probe
      for ROS3), `.github/workflows/ci.yml` (libhdf5 rebuild step),
      new `objc/Tests/TestCloudAccess.m` with an S3 mock harness.



---

## v0.3.0 and v0.4.0

Milestones 16–22 (v0.3.0: Python package, compound per-run provenance,
canonical signatures, mzML writer, cloud access, LZ4/Numpress codecs,
release prep) and Milestones 23–30 (v0.4.0: thread safety, chromatogram
API, key rotation, ISA-Tab/JSON export, spectral anonymization, nmrML
writer, Thermo RAW stub, release prep) are tracked in `HANDOFF.md`.

Java implementation (M26) is deferred to v0.5+.

---

## v0.5.0 — Java Feature Parity (M31–M36)

Milestones 31–36 are tracked in `HANDOFF.md`. Summary:

- [x] **M31** Java CI + Maven scaffold + HDF5 wrappers (17 tests)
- [x] **M32** Java core: primitives, runs, dataset, MSImage (26 tests)
- [x] **M33** Java import/export: mzML, nmrML, ISA, Thermo stub (36 tests)
- [x] **M34** Java protection: encrypt, sign, key rotation, anonymize (50 tests)
- [x] **M35** Java advanced: thread safety, LZ4, Numpress-delta (62 tests)
- [x] **M36** Three-way conformance + v0.5.0 release (62 tests)

---

## v0.6.0 and v0.6.1 (SHIPPED 2026-04-17 / 2026-04-17)

Milestones 37–42 and follow-up slices live in `HANDOFF.md`
(historical record section). Summary:

- [x] **M37** Java compound dataset I/O + JSON parsing
- [x] **M38** Thermo `.raw` import via ThermoRawFileParser delegation
- [x] **M39** Storage / Transport provider abstraction (all three languages)
- [ ] **M40** PyPI + Maven Central publishing *(deferred — external
      infrastructure gated)*
- [x] **M41** API review checkpoint (three-language parity)
- [x] **M42** v0.6.0 release — tag pushed
- [x] **v0.6.1** SQLite provider + Appendix B gap resolutions + full
      API docs (Sphinx / Javadoc / autogsdoc) + ObjC cloud-native ROS3
      reads

End-of-v0.6.1 test counts: ObjC 1002 assertions, Python 219, Java 152.

---

## v0.7.0 — Storage & Crypto Abstraction Hardening (PLANNED)

Full milestone block lives in `HANDOFF.md` (`## v0.7 Milestone Block`).
Summary:

**Track A — Storage abstraction (close remaining HDF5 couplings)**
- [ ] **M43** Storage byte-level protocol (`read_canonical_bytes`)
- [ ] **M44** Run / Image protocol-native access (drop `h5py.Group`
      from `AcquisitionRun` / `MSImage`)
- [ ] **M45** `create_dataset_nd` completion across all providers
- [ ] **M46** ZarrProvider Python reference implementation *(stretch)*

**Track B — Crypto agility (PQC-ready abstraction)**
- [ ] **M47** Crypto algorithm discriminator in on-disk format
      (versioned wrapped-key blob; v1.2 format bump)
- [ ] **M48** Algorithm-parameter API generalization (`CipherSuite`
      catalog)
- [ ] **M49** PQC preview mode — ML-KEM-1024 + ML-DSA-87 *(stretch,
      gated on liboqs / Bouncy Castle PQC maturity)*

**Track C — Cross-language consistency polish (v0.6.1 review findings)**
- [ ] **M50** Consistency hardening (six independent sub-items:
      `open()` docs, ObjC `readRows:` required, Java typed exceptions,
      `@since` audit, error-domain mapping, Gap 7 cross-refs)
- [ ] **M51** Cross-language byte-parity for compound writes

**v0.7.0 minimum cut:** M43, M44, M45, M47, M48, M50 (must-have).
M46, M51 stretch; M49 deferred to v0.8+.

---

## v0.9.0 — Integration Testing + Vendor Import Completion

Shipped as commits on `main`; tag `v0.9.0` → `eaac284`.

- **M57** Test infra + fixtures (`e4f2ae4`) — markers, download
  registry, synthetic generators, checksum pinning
- **M58** Format round-trips (`d2b0de0`) — mzML / nmrML / Thermo /
  Bruker TDF integration matrix
- **M59** imzML importer (`f1fcce6` + `1753776`) — Python + Java +
  ObjC with continuous/processed mode support
- **M60** mzTab importer (`2fa6023`) — proteomics 1.0 + metabolomics
  2.0.0-M
- **M61** End-to-end workflow + security lifecycle (`c44365b`)
- **M62** Stress + cross-provider benchmarks (`2aa4937` + `fa2a14f`)
  — 31 stress cells, 3-language smoke
- **M62.1** Cross-language cross-provider interop (`7d7f55d`) —
  SQLite dtype parity, Java Zarr zlib, ObjC read-via-provider
- **M63** Waters MassLynx importer (`50c2514`) — delegation pattern
  mirroring Thermo
- **M64** Cross-tool validation (this commit) — PSI XSD, pyteomics,
  pymzml, isatools, backward-compat, nightly-stress CI
- **M64.5** Caller refactor (`c00c3e0` + `73b7143` + `c3f69c9` +
  `b932ed2`) — writer + reader + protection classes + KeyRotation +
  MSImage all provider-aware; SpectralDataset URL-scheme dispatch
  across Python / Java / ObjC

### Performance analysis (parallel effort, not a milestone)

- Instrumented all three languages (`tools/perf/`): cProfile
  (Python), JFR (Java), phase-timing + pure-C baseline (ObjC)
- Shipped three targeted optimisations (`122ace7`): ObjC
  `writeMinimal` fast path, HDF5 chunk-size tuning, ObjC concat
  improvement
- Documented residual ObjC wrapper overhead (`b1a966b`) — at the
  libhdf5 floor; call stacks validated across all three languages

**v0.9.0 status:** Shipped (tag `v0.9.0` → `eaac284`). The three
xfailed exporter-fidelity defects (mzML precursor/activation, nmrML
version attribute, ISA-Tab PUBLICATIONS section) were closed in the
v0.9.1 follow-up (tag `v0.9.1` → `fa3ee21`) via commits `65c3666`
and `6b26f2e`.

## v0.10.0 — Streaming Transport + Per-AU Encryption (SHIPPED 2026-04-20)

### Milestones M66–M72 (streaming transport layer)

- [x] **M66** — Transport spec docs (`docs/transport-spec.md`,
      packet types, wire format, flag bits, ordering rules).
- [x] **M67** — Transport codec (`.mots` writer / reader) in all
      three languages, CRC-32C optional, nine packet types.
- [x] **M68** — WebSocket transport client (libwebsockets for ObjC,
      `websockets` for Python, Java-WebSocket for Java).
- [x] **M68.5** — Transport server (same library trio).
- [x] **M69** — Acquisition simulator replays fixtures at
      wall-clock pace.
- [x] **M70** — Bidirectional conformance matrix: every pair of
      writers × readers across {Python, ObjC, Java} round-trips
      byte-identically.
- [x] **M71** — Selective access (`AUFilter`) + ProtectionMetadata
      packet with `cipher_suite`, `kek_algorithm`, `wrapped_dek`,
      `signature_algorithm`, `public_key`.
- [x] **M72** — Integration, CHANGELOG, architecture docs.

### v1.0 per-AU encryption (shipped in v0.10.0)

Five phases across all three languages:

- [x] **Phase A** — per-AU primitives: AAD helpers
      (`aad_for_channel` / `aad_for_header` / `aad_for_pixel`),
      `ChannelSegment` / `HeaderSegment` / `AUHeaderPlaintext`
      records, 36-byte semantic header pack / unpack,
      `encrypt_channel_to_segments` / `decrypt_channel_from_segments`,
      `encrypt_header_segments` / `decrypt_header_segments`.
- [x] **Phase B** — `VL_BYTES` `CompoundField.Kind` on the
      provider abstraction; HDF5 provider wiring (Java uses
      `NativeBytesPool` backed by `sun.misc.Unsafe` to pack
      `hvl_t` slots; SQLite / Zarr fail loud with
      `NotImplementedError` at the compound-write boundary).
- [x] **Phase C** — file-level `encrypt_per_au` / `decrypt_per_au`
      orchestrator routed through `StorageProvider` for
      backend-agnostic plaintext ↔ `<channel>_segments` rewrite.
- [x] **Phase D** — `EncryptedTransport` writer + reader; emits /
      consumes AU packets with `FLAG_ENCRYPTED` (+
      `FLAG_ENCRYPTED_HEADER`) bits; ciphertext bytes pass through
      the wire unmodified.
- [x] **Phase E** — cross-language conformance harness
      (`tests/integration/test_per_au_cross_language.py`) drives
      `per_au_cli` / `PerAUCli` / `MpgoPerAU` via subprocess and
      byte-compares a canonical "MPAD" decryption dump; 38/38
      combinations passing across every encrypt × decrypt × headers
      × language triple.

### Tooling + migration

- [x] `per_au_cli` / `PerAUCli` / `MpgoPerAU` CLIs with
      `{encrypt, decrypt, send, recv, transcode}` subcommands.
- [x] `transcode --rekey` for DEK rotation; clear migration hint
      when the source carries v0.x `opt_dataset_encryption`.
- [x] Java `Hdf5File.close()` flush-before-close durability fix
      (required for writes on Python-created h5py files to
      persist after handle leaks).

### Release criteria

- [x] 1430 ObjC assertions / 682 Python tests / 298 Java tests
      pass; 38/38 cross-language conformance cells green.
- [x] `CHANGELOG.md` v0.10.0 entry.
- [x] Docs refreshed (`format-spec.md`, `transport-spec.md`,
      `transport-encryption-design.md`, `feature-flags.md`,
      `api-stability-v0.8.md`, `README.md`, `ARCHITECTURE.md`,
      `HANDOFF.md`, this file).
- [x] Annotated `v0.10.0` tag pushed (`a609aa9` on commit `c9fe137`).

**v0.10.0 status:** Shipped (tag `v0.10.0` → `a609aa9` on `c9fe137`).

## v0.11.0 — Vibrational Spectroscopy (Raman + IR)

### Milestone M73 — vibrational modalities

- [x] **Four new domain classes per language:** `RamanSpectrum`,
      `IRSpectrum`, `RamanImage`, `IRImage`. Raman carries
      excitation / laser power / integration time; IR carries the
      new `IRMode` enum (`TRANSMITTANCE=0` / `ABSORBANCE=1`),
      spectral resolution, and scan count. Image classes hold
      rank-3 intensity cubes with a shared rank-1 wavenumber axis.
- [x] **HDF5 layout:** `/study/raman_image_cube/` and
      `/study/ir_image_cube/` groups documented in
      `docs/format-spec.md` §7a; chunking mirrors the MSImage
      convention (`(tile_size, tile_size, spectral_points)` tiles,
      `zlib -6`).
- [x] **JCAMP-DX 5.01 AFFN reader + writer** in all three
      languages (`##XYDATA=(X++(Y..Y))` dialect). Writers emit
      LDRs in a fixed order with `%.10g` formatting — byte-identical
      output for identical input; readers dispatch on
      `##DATA TYPE=` with `##YUNITS=` fallback for the bare
      `INFRARED SPECTRUM` variant. PAC / SQZ / DIF compression and
      2-D NTUPLES are out of scope (the reader rejects unknown
      types rather than guessing).
- [x] **ObjC CLI `MpgoJcampDxDump`** — tiny subprocess driver
      matching the existing CLI family so the Python conformance
      harness can compare parses bit-for-bit.
- [x] **Cross-language conformance test**
      (`python/tests/integration/test_raman_ir_cross_language.py`)
      — Python↔Java and Python↔ObjC JCAMP-DX round-trips plus a
      deterministic-layout lock. 6 cells, all green. Skips on dev
      boxes where the Java/ObjC sides aren't built.

### Release criteria

- [x] 1443 ObjC assertions / 695 Python tests / 307 Java tests
      pass; 44/44 cross-language conformance cells green (38 per-AU
      + 6 JCAMP-DX).
- [x] `CHANGELOG.md` v0.11.0 entry.
- [x] Docs refreshed (`format-spec.md` §7a, `vendor-formats.md`,
      `class-hierarchy.md` Layer 3c, `README.md`,
      `ARCHITECTURE.md`, `HANDOFF.md`, this file).
- [x] M73 commit `f93180b` pushed to `origin/main`.
- [ ] Annotated `v0.11.0` tag — pending user sign-off.

**v0.11.0 status:** Implementation shipped on commit `f93180b`
(2026-04-21); awaiting tag.

### Deferred to v0.11.1 / v0.12.0

- 2-D JCAMP-DX (NTUPLES / PAGE) for imaging cubes — ASCII cubes
  are impractical at 10–100 MB per map; native HDF5 groups remain
  the canonical form.
- JCAMP-DX legacy compression (PAC / SQZ / DIF).
- 2D-COS (2-D correlation spectroscopy) and hyperspectral-image
  analysis primitives.
- UV-Vis as a third vibrational-class `Spectrum` subclass (the
  reader currently rejects `##DATA TYPE=UV/VIS SPECTRUM`).
