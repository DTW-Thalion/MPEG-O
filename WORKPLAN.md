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
- [ ] Tag `v0.2.0` pushed to `DTW-Thalion/MPEG-O` *(user-gated per binding decision)*.

## v0.3 Deferred Follow-Ups

Items explicitly scoped out of their originating v0.3 milestone and
parked here for a later pass. Each one has a pointer to where in the
code the gap currently lives so it can be picked up without re-reading
the full milestone history.

### Milestone 19 — mzML Writer

- [ ] **Chromatogram emission in the mzML writer.**
      `MPGOMzMLWriter` currently emits only `<spectrumList>`; a
      `<chromatogramList>` is never written. Blocked on
      `MPGOAcquisitionRun` growing a first-class chromatogram API
      (today the type exists via `MPGOChromatogram` but is not stored
      on a run). Once the run model exposes chromatograms, both the
      ObjC writer and `mpeg_o.exporters.mzml` should walk that list
      into a second `<index name="chromatogram">` block inside the
      existing `<indexList>`. Touches:
      `objc/Source/Export/MPGOMzMLWriter.m`,
      `python/src/mpeg_o/exporters/mzml.py`,
      `objc/Tests/TestMilestone19.m`,
      `python/tests/test_mzml_writer.py`.

- [ ] **Direct byte-for-byte parity test between the ObjC and Python
      mzML writers.** Both implementations currently share the same
      XML template and are individually round-trip-tested through
      their respective readers, but no test runs both writers on the
      same input and diffs the bytes. The minimum delta is a tiny
      `objc/Tools/MpgoToMzML.m` CLI (modelled on `MpgoVerify` and
      `MpgoSign`) that takes a `.mpgo` path and writes an `.mzML` to
      a second path; the Python side then adds a test that invokes
      it via subprocess, calls `mpeg_o.exporters.mzml.write_dataset`
      on the same input, and asserts byte-for-byte equality (or a
      structural compare if any intentional formatting differences
      remain). Touches: `objc/Tools/MpgoToMzML.m` (new),
      `objc/Tools/GNUmakefile`,
      `python/tests/test_mzml_writer.py`.

