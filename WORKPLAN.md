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

- [ ] `make` in `objc/` produces `libMPGO.so` (or platform equivalent).
- [ ] `make check` in `objc/` runs `MPGOTests` and all value class tests PASS.
- [ ] Each value class: construction, equality, hashing, copying, NSCoding round-trip.
- [ ] Edge cases covered: nil optional fields, zero-width ranges, extreme precisions.

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

- [ ] Create / open / close an HDF5 file; file exists on disk.
- [ ] Write & read float64 dataset, values match within 1e-12 epsilon.
- [ ] Write & read chunked+compressed int32 dataset, byte-exact match.
- [ ] Write & read complex128 dataset, real and imaginary components intact.
- [ ] Partial read: write 1000 elements, read elements 500–599, verify.
- [ ] `MPGOSignalArray` HDF5 round-trip: write → read → `-isEqual:` true.
- [ ] Benchmark: 1M float64 elements, write < 100 ms, read < 100 ms (logged, PASS if under).
- [ ] Error path: opening nonexistent file returns nil with populated `NSError`, no crash.

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

- [ ] Construct a realistic 200-peak centroided MassSpectrum, round-trip, verify equality.
- [ ] Construct a 32768-point NMR FID, round-trip, verify real/imag intact.
- [ ] Construct a 2D NMR intensity matrix (e.g. 512×1024), round-trip, verify.
- [ ] Chromatogram round-trip for each type (TIC, XIC, SRM).
- [ ] MassSpectrum rejects construction with mismatched mz/intensity lengths.

---

## Milestone 4 — AcquisitionRun + SpectrumIndex (Access Unit model)

**Deliverables**

- `MPGOAcquisitionRun` managing an ordered, heterogeneous collection of Spectrum objects.
- `MPGOSpectrumIndex` — offsets + lengths + compound headers dataset.
- `MPGOInstrumentConfig` value class.
- Signal-channel separation: writing a run extracts all mz values into one contiguous dataset, all intensities into another, all scan metadata into a compound dataset.
- `MPGOIndexable` + `MPGOStreamable` fully exercised on runs.

**Acceptance Criteria**

- [ ] Create a 1000-spectrum run, write to HDF5.
- [ ] Random-access read of spectrum 0, 500, 999 — verify each without reading unrelated spectra (confirm via HDF5 chunk access counts or dataset region selection).
- [ ] Range query "RT between 10.0 and 12.0 minutes" returns expected subset.
- [ ] Streaming iteration through all 1000 spectra yields correct order.
- [ ] `MPGOInstrumentConfig` round-trip as HDF5 compound attribute.

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

- [ ] Build a dataset with 2 MS runs + 1 NMR run, 10 identifications, 5 quantifications, multi-step provenance.
- [ ] Write to `.mpgo`, close, reopen, verify every field matches.
- [ ] Provenance chain queryable by input entity reference.
- [ ] TransitionList round-trip preserves collision energies and RT windows.

---

## Milestone 6 — MSImage (Spatial Extension)

**Deliverables**

- `MPGOMSImage` extending `MPGOSpectralDataset` with spatial grid indexing.
- Tile-based Access Units (32×32 pixel default).
- HDF5 3D layout `[x, y, spectral_points]` with tile-aligned chunking.

**Acceptance Criteria**

- [ ] Create a 64×64 pixel MSImage with synthetic spectra.
- [ ] Write to HDF5, reopen.
- [ ] Read tile (0..31, 0..31) without reading the other three tiles.
- [ ] Round-trip equality for the full image.

---

## Milestone 7 — Protection / Encryption

**Deliverables**

- `MPGOEncryptionManager` using AES-256-GCM (CommonCrypto or OpenSSL).
- `MPGOAccessPolicy` stored as JSON in `/protection/access_policies`.
- `MPGOEncryptable` conformance on `MPGOAcquisitionRun` and `MPGOSpectralDataset`.
- Selective encryption: encrypt `intensity_values` dataset while leaving `mz_values` and `scan_metadata` unencrypted.
- Encryption metadata (algorithm, IV, auth tag) as HDF5 attributes.

**Acceptance Criteria**

- [ ] Encrypt an AcquisitionRun's intensity channel with a test key.
- [ ] Verify unencrypted metadata (mz, scan headers) readable without key.
- [ ] Decrypt with correct key → byte-exact match to original intensities.
- [ ] Decrypt with wrong key → authenticated-decryption failure (GCM tag mismatch), no silent corruption.
- [ ] Access policy JSON readable independently of key management.

---

## Milestone 8 — Query API + Streaming

**Deliverables**

- `MPGOQuery` class performing compressed-domain queries via SpectrumIndex header scanning.
- Predicate support: RT range, MS level, polarity, precursor m/z range, base peak intensity threshold.
- `MPGOStreamWriter` — append spectra to an open `.mpgo` file incrementally.
- `MPGOStreamReader` — sequential read with prefetch buffering.

**Acceptance Criteria**

- [ ] Query a 10,000-spectrum dataset for "MS2 with RT in [10, 12] and precursor in [500, 550]".
- [ ] Instrumentation confirms only AU headers are read; signal channel data is untouched until matching spectra are explicitly loaded.
- [ ] StreamWriter writes 500 spectra incrementally; file is valid after each flush.
- [ ] StreamReader reads the same 500 spectra in order, values match originals.
- [ ] Query performance: 10k-spectrum header scan completes in < 50 ms (logged, PASS if under).

---

## Overall Release Criteria (v0.1.0-alpha)

- [ ] All eight milestones complete with all tests passing locally (WSL) and in GitHub Actions CI.
- [ ] README, ARCHITECTURE, WORKPLAN, and all `docs/` files finalized.
- [ ] No warnings under `-Wall -Wextra` with clang.
- [ ] Tag `v0.1.0-alpha` pushed to `DTW-Thalion/MPEG-O`.
