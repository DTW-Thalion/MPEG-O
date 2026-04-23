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

## v0.7.0 — Storage & Crypto Abstraction Hardening (SHIPPED 2026-04-18)

Full milestone block lives in `HANDOFF.md` (`## v0.7 Milestone Block`).
Summary:

**Track A — Storage abstraction (close remaining HDF5 couplings)**
- [x] **M43** Storage byte-level protocol (`read_canonical_bytes`)
- [x] **M44** Run / Image protocol-native access (drop `h5py.Group`
      from `AcquisitionRun` / `MSImage`)
- [x] **M45** `create_dataset_nd` completion across all providers
- [x] **M46** ZarrProvider Python reference implementation (Java + ObjC
      ports land in v0.8 M52)

**Track B — Crypto agility (PQC-ready abstraction)**
- [x] **M47** Crypto algorithm discriminator in on-disk format —
      wrapped-key blob v1.2 (`"MW" | version | algorithm_id | ct_len |
      md_len | metadata | ciphertext`); format version bumps 1.1 → 1.2.
- [x] **M48** Algorithm-parameter API generalization — `CipherSuite`
      catalog with `algorithm=` kwarg threaded through encryption /
      signing / wrapping; reserves ML-KEM-1024 + ML-DSA-87 IDs for M49.
- [ ] **M49** PQC preview mode — *deferred to v0.8.0 (shipped there).*

**Track C — Cross-language consistency polish (v0.6.1 review findings)**
- [x] **M50** Consistency hardening (six Appendix-B gap resolutions:
      dual-style `open()`, required `readRows()`, capability queries,
      `provider_name` shape, precision decoupling, attribute del/enum).
- [x] **M51** Cross-language byte-parity for compound writes —
      9-cell interop grid (Python × Java × ObjC writers/readers all
      byte-identical).

### Release criteria
- [x] ObjC 1057 assertions / Python 284 tests / Java 179 tests pass.
- [x] `CHANGELOG.md` v0.7.0 entry.
- [x] Annotated `v0.7.0` tag pushed to `DTW-Thalion/MPEG-O`.

**v0.7.0 status:** Shipped.

---

## v0.8.0 — PQC Preview + Bruker TDF + Cross-language PQC Conformance (SHIPPED 2026-04-18)

- [x] **M49** Post-quantum crypto preview — ML-KEM-1024 (FIPS 203)
      envelope key-wrap + ML-DSA-87 (FIPS 204) dataset signatures.
      New `v3:` signature-attribute prefix; `opt_pqc_preview` feature
      flag auto-set whenever either primitive runs. Python + ObjC use
      liboqs; Java uses Bouncy Castle 1.80+. Rationale: `docs/pqc.md`.
  - [x] **M49.1** ObjC dataset / envelope integration via
        `MPGOSignatureManager` + `MPGOKeyRotationManager`.
- [x] **M52** Java + ObjC `ZarrProvider` ports — self-contained
      LocalStore implementations, no external zarr library dependency.
      Cross-reads Python `zarr-python` stores byte-for-byte. (On-disk
      format migrated v2 → v3 in v0.9.1; see below.)
- [x] **M53** Bruker timsTOF `.d` importer in all three languages.
      SQLite metadata reads natively per-language; binary frame
      decompression uses `opentimspy` + `opentims-bruker-bridge`
      (Python) with Java/ObjC subprocess-delegating to the Python
      helper. New `inv_ion_mobility` signal channel preserves the 2-D
      timsTOF geometry per-peak. Details: `docs/vendor-formats.md`.
- [x] **M54 + M54.1** 32-cell cross-language × cross-provider PQC
      conformance matrix: primitive ML-DSA / ML-KEM, v3 signatures on
      HDF5 / Zarr / SQLite, v2+v3 coexistence, v0.7 backward-compat.
      New Java `PQCTool` + ObjC `MpgoPQCTool` CLIs drive the harness;
      new Python `sign_storage_dataset` / `verify_storage_dataset`
      provider-agnostic helpers.

### Release criteria
- [x] `CipherSuite` catalog: `ml-kem-1024` + `ml-dsa-87` graduate
      `reserved → active`; ML-DSA-87 public-key size corrected
      4864 → 2592 bytes (FIPS 204 §4).
- [x] `validate_key()` rejects asymmetric algorithms with explicit
      redirect to `validate_public_key` / `validate_private_key`.
- [x] Python + ObjC provider `read_canonical_bytes` round-trips on
      signed datasets across all four shipping providers.
- [x] `CHANGELOG.md` v0.8.0 entry; `docs/pqc.md` + `docs/api-stability-v0.8.md`.
- [x] Annotated `v0.8.0` tag pushed.

**v0.8.0 status:** Shipped.

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
v0.9.1 follow-up (see next block).

## v0.9.1 — Exporter Fidelity + Zarr v3 Migration (SHIPPED 2026-04-19)

Patch release closing the v1.0 exporter gaps surfaced by M64 xfails
and migrating the Zarr on-disk format to v3.

- [x] **mzTab exporter** across Python + ObjC + Java (`3c67ba9`) —
      proteomics 1.0 (MTD + PSH/PSM + PRH/PRT) + metabolomics 2.0.0-M
      (MTD + SMH/SML). Round-trips bit-identically through the reader.
- [x] **imzML exporter** across Python + ObjC + Java (`ff0f201`) —
      continuous + processed modes; rejects divergent mz axis in
      continuous mode; UUID normalisation. Same commit corrects the
      importer's cv-accession classification for `MS:1000030` /
      `MS:1000031` (vendor / instrument-model, not IMS mode).
- [x] **nmrML `<spectrum1D>` XSD gap** closed via interleaved `(x,y)`
      encoding (`6b26f2e`); reader auto-detects interleaved vs y-only.
- [x] **mzML + ISA-Tab validator closure** + nmrML wrapper improvements
      (`65c3666`) — eleven `docs/v1.0-gaps.md` "Fix status" rows
      flipped to ✅; only `activation_method` / `isolation_window`
      data-model extension remains open (v1.0 item).
- [x] **v1.0 gap audit document** (`docs/v1.0-gaps.md`) covering all
      exporter + importer xfails surfaced by M64 (`4f17789`).
- [x] **Zarr v2 → v3 on-disk migration** across all three languages
      (`391a7d2` + `da13fed`). Single `zarr.json` per node, nested
      attributes, `c/` chunk prefix, canonical dtype names. Python
      uses zarr-python 3.x; Java + ObjC self-contained writers updated
      to emit and parse v3 byte-for-byte against the Python reference.
      No backward-compat shim — pre-deployment, no v2 stores in the
      wild. Read side still accepts legacy v2 dtype strings for safety.
- [x] Unit-level coverage for the new writers (`2f35bd2`).

### Release criteria
- [x] Python 586 pass / 11 skip / 4 xfail; ObjC 1271 PASS; Java 245 pass.
- [x] `CHANGELOG.md` v0.9.1 entry.
- [x] Annotated `v0.9.1` tag pushed (`fa3ee21`).

**v0.9.1 status:** Shipped.

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
- [x] Annotated `v0.11.0` tag.

**v0.11.0 status:** Shipped.

## v0.11.1 — M73.1 JCAMP-DX compression + UV-Vis + 2D-COS (2026-04-21)

Patch release completing the three items deferred from v0.11.0.
Three-language parity preserved — every surface ships in Python,
Objective-C, and Java.

### Shipped

- [x] **JCAMP-DX 5.01 PAC / SQZ / DIF / DUP compression reader** in
      all three languages. `has_compression()` sentinel scan excludes
      `e`/`E` so AFFN scientific notation doesn't false-trigger; a
      dedicated decoder handles the full SQZ (`@`, `A-I`, `a-i`),
      DIF (`%`, `J-R`, `j-r`), and DUP (`S-Z`, `s`) alphabets plus
      the Y-check convention. X values reconstructed from `FIRSTX`
      / `LASTX` / `NPOINTS`. Writers remain AFFN-only.
- [x] **`UVVisSpectrum` class** — 1-D UV/visible absorption spectrum
      keyed by `"wavelength"` (nm) + `"absorbance"`, with
      `pathLengthCm` + `solvent` metadata. Reader dispatches
      `UV/VIS SPECTRUM`, `UV-VIS SPECTRUM`, `UV/VISIBLE SPECTRUM`;
      writer emits `##DATA TYPE=UV/VIS SPECTRUM` with NANOMETERS +
      ABSORBANCE units and `##$PATH LENGTH CM` / `##$SOLVENT` LDRs.
- [x] **`TwoDimensionalCorrelationSpectrum` class** — Noda 2D-COS
      with rank-2 synchronous (in-phase) + asynchronous (quadrature)
      correlation matrices sharing a single variable axis. Matrices
      are row-major `float64`, size-by-size; construction validates
      rank, shape match, and squareness. Gated behind new
      `opt_native_2d_cos` feature flag.

### Release criteria

- [x] 1536 ObjC assertions / 765 Python tests / 331 Java tests pass.
- [x] `CHANGELOG.md` v0.11.1 entry.
- [x] Annotated `v0.11.1` tag.

### Deferred to v0.12.0

- 2-D JCAMP-DX (NTUPLES / PAGE) for imaging cubes — ASCII cubes
  remain impractical at 10–100 MB per map; native HDF5 groups
  remain the canonical form.
- JCAMP-DX compressed-writer emission (reader is sufficient for
  cross-vendor import; bit-accurate round-trips favour AFFN).
- 2D-COS computation primitives (generalised decomposition,
  statistical significance testing) — only the storage class is
  shipped here.
- Hyperspectral-image analysis primitives beyond the tile-chunk
  cube already supported.

---

## Cross-language parity audit (2026-04-21, post-v0.11.1)

Direct inventory of the Python / Java / ObjC source trees against the
three-language-parity rule (Python, Java, ObjC all expose the same
classes **and** CLI tools; each stands alone). Verified by file-system
enumeration of `python/src/mpeg_o/`,
`java/src/main/java/com/dtwthalion/mpgo/`, and `objc/Source/` +
`objc/Tools/` at commit `4dfa103`.

### Domain model — full parity

All 13 spectrum / image classes present in every language:
`Spectrum`, `MassSpectrum`, `NMRSpectrum`, `NMR2DSpectrum`,
`FreeInductionDecay`, `Chromatogram`, `RamanSpectrum` (v0.11.0),
`IRSpectrum` (v0.11.0), `UVVisSpectrum` (v0.11.1),
`TwoDimensionalCorrelationSpectrum` (v0.11.1), `MSImage`,
`RamanImage` (v0.11.0), `IRImage` (v0.11.0). Shared base / run /
dataset / identification / quantification / transition-list /
instrument-config / provenance all present in every language.

### Importers — full parity (8 readers per language)

`mzML`, `nmrML`, `mzTab`, `imzML`, `Thermo .raw` (delegation),
`Bruker .d` TDF, `Waters .raw` MassLynx (delegation), `JCAMP-DX 5.01`
(with AFFN + PAC / SQZ / DIF / DUP decoder).

### Exporters — full parity (6 writers per language)

`mzML`, `nmrML`, `mzTab`, `imzML` (shipped v0.9.1), `ISA-Tab`,
`JCAMP-DX` (AFFN-only; compressed writer deferred to v0.12.0).

### Providers — full parity (4 backends per language)

`HDF5`, `Memory`, `SQLite`, `Zarr v3`. All four support
`read_canonical_bytes`, `create_dataset_nd`, VL_BYTES compound for
per-AU encryption.

### Protection — full parity

`CipherSuite` catalog, `EncryptionManager`, `PerAUEncryption` +
`PerAUFile` (v1.0), `KeyRotationManager`, `SignatureManager` (HMAC +
`v3:` PQC prefix), `PostQuantumCrypto` (ML-KEM-1024 + ML-DSA-87),
`AccessPolicy`, `Anonymizer`, `Verifier`.

### Transport — full parity

`.mots` codec (9 packet types), `TransportClient`, `TransportServer`,
`AcquisitionSimulator`, `EncryptedTransport`, `AUFilter`,
`ProtectionMetadata`.

### CLI tools

Core parity (6 tools, every language):
`per_au_cli` / `PerAUCli` / `MpgoPerAU`,
`simulator_cli` / `SimulatorCli` / `MpgoSimulator`,
`transport_encode_cli` / `TransportEncodeCli` / `MpgoTransportEncode`,
`transport_decode_cli` / `TransportDecodeCli` / `MpgoTransportDecode`,
`transport_server_cli` / `TransportServerCli` / `MpgoTransportServer`,
`dump_identifications` / `DumpIdentifications` / `MpgoDumpIdentifications`.

Documented asymmetries (intentional, test-harness plumbing):

| Tool | Python | Java | ObjC | Rationale |
|------|:------:|:----:|:----:|-----------|
| `MakeFixtures` | — | — | ✓ | Fixture generator consumed by Python/Java test suites. |
| `MpgoJcampDxDump` | — | — | ✓ | ObjC subprocess driver for the Python JCAMP-DX conformance harness. |
| `MpgoToMzML` | — | — | ✓ | Byte-parity driver for `test_mzml_writer_parity.py`. |
| `MpgoSign` | — | — | ✓ | Signing CLI (Python + Java use library API via tests). |
| `MpgoVerify` / `mpgo-verify` | module only | ✓ | ✓ | CLI parity polish candidate (v0.12.0). |
| `MpgoPQCTool` / `mpgo-pqc` | module only | ✓ | ✓ | CLI parity polish candidate (v0.12.0). |
| `CanonicalJson` | ✓ (internal) | ✓ | — | Used by test harness; ObjC equivalent is `MPGOCanonicalBytes`. |
| `bruker_tdf_cli` | ✓ | — | — | Python bridge wrapping `opentimspy`; Java/ObjC subprocess into the Python helper. |

### Open v1.0 data-model gap

**`activation_method` + `isolation_window` in `MassSpectrum`** — the
only remaining "must-fix for v1.0" item from `docs/v1.0-gaps.md`.
Fields exist nowhere in the on-disk format today; fix requires a
format bump, a new compound schema column in `spectrum_index`, and
reader + writer changes in all three languages.

---

## v0.12.0 — Planned

Scope accumulated from v0.11.1 deferred notes + the single remaining
v1.0 data-model gap + CLI parity polish. Three-language parity rule
holds for every line item.

### Must-have

- [x] **M74** `activation_method` + `isolation_window` data-model
      extension. `MassSpectrum` gains an `ActivationMethod` enum
      (`CID / HCD / ETD / UVPD / ECD / EThcD / none`) + an
      `IsolationWindow` value class (`target_mz`, `lower_offset`,
      `upper_offset`). `spectrum_index` compound gains four parallel
      columns. mzML reader populates from cvParams inside
      `<precursor>`; mzML writer emits `<activation>` with the
      preserved method plus a complete `<isolationWindow>` block.
      Closes the last v1.0 gap from `docs/v1.0-gaps.md`. Format
      version bumps to `1.3` only when any run carries the optional
      columns; `opt_ms2_activation_detail` feature flag advertises
      the extension. *Shipped 2026-04-22 across all three languages
      as five sequential slices: A (enum + value class, `beb2bc7`),
      B (spectrum_index schema, `736ecef`), C (mzML reader,
      `9340007`), D (mzML writer, `c502d68`), E (feature flag +
      format bump + round-trip tests, `e96105f`).*
- [x] **M75** Python CLI parity polish — add `mpgo-verify`,
      `mpgo-sign`, `mpgo-pqc` console_scripts to `pyproject.toml`
      backed by the existing `verifier.py` / `signatures.py` /
      `pqc.py` modules. Brings Python up to Java + ObjC CLI surface
      for the three protection tools. *Shipped 2026-04-23 as commit
      `e9f2d2b`, with 13 new CLI-parity tests in
      `python/tests/test_m75_cli_parity.py` exercising console-script
      entry-point resolution, HMAC sign/verify round-trip, and PQC
      sig/KEM/HDF5 round-trips against the ObjC/Java subcommand
      grammar 1:1.*

### Nice-to-have

- [x] **M76** JCAMP-DX compressed-writer emission (PAC / SQZ / DIF)
      in all three languages. AFFN remains the default for bit-accurate
      round-trips; compressed output is opt-in via a writer flag.
      Gates on a cross-language byte-parity conformance test for each
      compression form. *Shipped 2026-04-23 across five sliced commits
      — `9437a1b` (Slice A: Python reference encoder +
      `_jcamp_encode`, reader PAC-detection, 37 unit tests),
      `de377d6` (Slice B: `conformance/jcamp_dx/` golden fixtures +
      regeneration script + Python conformance test),
      `d889b19` (Slice C: Java `JcampDxEncoding` enum +
      `JcampDxEncode` helper + writer overloads, 3/3
      `JcampDxM76ConformanceTest` green, 345/345 full suite),
      `4787aa2` (Slice D: ObjC `MPGOJcampDxEncoding` NS_ENUM +
      `MPGOJcampDxEncode` helper + writer overloads, 3/3
      `testM76JcampConformance` green, 1637/0 full suite), and this
      docs flip. The compressed encoder emits an explicit Y-check
      token on every non-first line to defeat the decoder's
      prev-last-y collision on plateau boundaries; YFACTOR is chosen
      per-spectrum as `10 ** (ceil(log10(max_abs)) - 7)` for ~7
      significant digits of integer-scaled Y precision; rounding is
      explicit half-away-from-zero so all three languages agree on
      `.5` ties.*
- [x] **M77** 2D-COS computation primitives — generalised
      synchronous / asynchronous decomposition from a perturbation
      series (Noda's Hilbert-transform approach), plus a statistical
      significance test. Ships as library API in all three languages
      with a shared reference fixture. Output format already defined
      by `TwoDimensionalCorrelationSpectrum` (v0.11.1). *(Python
      [df321d5], fixture [2dfe27d], Java [6f4f115], ObjC [2f02ffa].
      API: `hilbert_noda_matrix(m)` / `compute(dynamic_spectra,
      reference=None, …)` / `disrelation_spectrum(sync, async)` in
      each language. Reference defaults to column-wise mean
      (standard mean-centered 2D-COS); explicit-reference mode
      enables difference 2D-COS. Synchronous Φ = (1/(m−1)) Ãᵀ Ã is
      symmetric; asynchronous Ψ = (1/(m−1)) Ãᵀ N Ã is antisymmetric
      where N is the discrete Hilbert-Noda matrix
      N[j,k] = 1/(π(k−j)). Statistical significance: disrelation
      spectrum |Φ|/(|Φ|+|Ψ|) ∈ [0,1], NaN where both matrices
      vanish. Cross-language gate is float-tolerance
      (rtol=1e-9, atol=1e-12) on a shared
      `conformance/two_d_cos/{dynamic,sync,async}.csv` fixture, not
      byte-parity — BLAS accumulation order differs across
      implementations.)*
- [x] **M78** Round out mzTab PEH/PEP + SFH/SMF/SEH/SME — requires
      new `Feature` value class beside `Identification` and
      `Quantification` (flagged "deferred further" in
      `docs/v1.0-gaps.md`). Three-language parity for the value class
      + importer + exporter. *(Shipped: Python `Feature` +
      PEH/PEP/SFH/SMF/SEH/SME emission + back-fill; Java `Feature`
      record + round-trip; ObjC `MPGOFeature` + reader/writer
      parity. Rank↔confidence mapping (rank N ↔ confidence 1/N) with
      gating rule "SEH/SME only when features present" preserves
      plain-SML round-trips. Shared fixtures at
      `conformance/mztab_features/{proteomics,metabolomics}.mztab`;
      cross-language gate is float-tolerance on
      `exp_mass_to_charge` and `retention_time_in_seconds`.)*

### Deferred further (not v0.12 scope)

- 2-D JCAMP-DX (NTUPLES / PAGE) — ASCII cubes impractical at
  10–100 MB; native HDF5 groups remain canonical.
- Hyperspectral-image analysis primitives beyond tile-chunk cubes.
- mzML `<softwareList>` / `<dataProcessingList>` content-chain
  emission (provenance is already stored; this is pure XML
  restructuring for reviewer-facing completeness).

### Release criteria (v0.12.0)

- [x] M74 + M75 shipped; M76–M78 shipped or re-deferred explicitly.
      *(All five shipped.)*
- [x] All three test suites green; cross-language conformance matrix
      extended to cover M74 round-trip (mzML → MPGO → mzML preserves
      activation + isolation). *(Python 875, Java 373, ObjC 1704/0.)*
- [x] `CHANGELOG.md` v0.12.0 entry; `docs/v1.0-gaps.md` "Must-fix for
      v1.0" list empty. *(Both flipped 2026-04-23.)*
- [x] Annotated `v0.12.0` tag. *(Tagged + pushed 2026-04-23.)*

## v1.0.0 — First stable release (SHIPPED 2026-04-23)

Pure promote from v0.12.0. No new code; v1.0.0 signals SemVer-stable
public API and that `docs/v1.0-gaps.md` Must-fix and Nice-to-have
lists are both empty.

### Changed

- `python/pyproject.toml` — `version` 0.8.0 → 1.0.0; classifier
  `Development Status :: 3 - Alpha` → `5 - Production/Stable`.
- `java/pom.xml` — `version` 0.8.0 → 1.0.0.
- `CHANGELOG.md` — new `[v1.0.0]` entry above the v0.12.0 block.
- `HANDOFF.md` / `README.md` / `docs/version-history.md` — status
  rows refreshed.

### Deferred past v1.0.0

- **M40 PyPI + Maven Central publishing** — wait on external account
  / API-token setup; target v1.0.1.
- **mzML `<softwareList>` / `<dataProcessingList>`** content-chain
  emission — reviewer-facing XML restructure.
- **Hyperspectral-image analysis primitives** — scope expansion
  beyond tile-chunk cubes.
