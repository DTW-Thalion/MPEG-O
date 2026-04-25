# TTI-O v0.6 API Review

> **Milestone:** M41 (API Review checkpoint)  
> **Final slice:** M41.8 — commit `13c024e`  
> **Date:** 2026-04-16  
> **Author:** Generated from per-slice plan and commit data; normative reference is ObjC.

This document is the headline deliverable of Milestone 41. It answers the
question: "If I am using Python class X, what is its equivalent in Java and
Objective-C?" For every public class in the TTI-O v0.6 surface, the
three-column tables below give the ObjC, Python, and Java identifiers, their
stability classification, and any method-level parity notes. Resolved
inconsistencies are listed under each subsystem; deferred items are called out
explicitly.

---

## 1. Scope and Stability Policy

### Coverage

Three language implementations are reviewed:

- **Objective-C** — normative reference. ObjC headers define the canonical API
  shape. All parity decisions in M41 were resolved against ObjC.
- **Python** — `ttio.*` package, Python 3.11+, NumPy-style docstrings.
- **Java** — `com.dtwthalion.tio.*`, JDK 17, Javadoc.

The review covers all eight subsystems addressed in M41 slices 41.1 through
41.8. Internal helpers (see §1.3 below) are excluded from the parity guarantee.

### Stability classifications

Every public API surface carries one of three stability labels:

**Stable**
: Core data model, domain protocols, value classes, spectrum hierarchy, run
  and image classes, query builder, import/export readers and writers.
  API surface is pinned for v0.6. Changes to Stable APIs require a deprecation
  cycle and a minor-version bump. The ObjC header, Python docstring, and Java
  Javadoc each carry the line `API status: Stable.`

**Provisional (per M39)**
: The storage-provider subsystem (`StorageProvider`, `StorageGroup`,
  `StorageDataset`, `CompoundField`, `Hdf5Provider`, `MemoryProvider`, and the
  provider registry). Shipped in Milestone 39 with the explicit understanding
  that the interface contracts may change before v1.0 as experience accumulates
  with Zarr and SQLite backends. Marked `API status: Provisional — may change
  before v1.0.` in each language.

**Internal**
: Language-idiomatic helpers with no cross-language parity guarantee:

  | Helper | Language | Notes |
  |---|---|---|
  | `ttio.importers._base64_zlib` | Python | Private module (underscore-prefixed) |
  | `ttio._numpress` | Python | Private module |
  | `ttio._hdf5_io` | Python | Private HDF5 compound-IO helper |
  | `com.dtwthalion.tio.MiniJson` | Java | Internal JSON micro-parser |
  | `com.dtwthalion.tio.hdf5.Hdf5CompoundIO` | Java | Internal HDF5 compound-IO |
  | `TTIOBase64` | ObjC | ObjC wrapper; Java uses `java.util.Base64` stdlib directly |
  | `TTIOHDF5File` | ObjC | ObjC HDF5 file handle; Java has `Hdf5File` in hdf5 subpackage |

### Three-language namespace rule

A public class or function exists in all three languages unless explicitly
listed under a subsystem's **Deferred** block or classified as **Internal**.
When a class exists in only one or two languages, the missing cell is noted as
`—` in the parity table.

---

## 2. Namespace Summary

| Language | Top-level namespace | Class-naming convention |
|---|---|---|
| Objective-C | `TTIO` prefix | `TTIOClassName` — no namespaces in ObjC; prefix is the namespace |
| Python | `ttio.*` packages | `snake_case` modules, `PascalCase` classes |
| Java | `com.dtwthalion.tio.*` | `PascalCase` classes; subpackages: `protocols`, `protection`, `providers`, `importers`, `exporters`, `hdf5` |

**Note on Java groupId:** The Java artifact groupId migrates from
`com.dtwthalion` to `global.thalion` in M40 (pending). This document uses the
current `com.dtwthalion.tio.*` names throughout. A one-line update to this
table and the parity cells below is the only change needed when M40 lands.

---

## 3. Per-Subsystem Parity

---

### Slice 41.1 — Domain Protocols + Value Classes

**Commit:** `d63018a` `M41.1: Domain protocols + ValueClasses parity`

#### Domain Protocols

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOCVAnnotatable` | `ttio.protocols.CVAnnotatable` | `com.dtwthalion.tio.protocols.CVAnnotatable` | Stable |
| `TTIOEncryptable` | `ttio.protocols.Encryptable` | `com.dtwthalion.tio.protocols.Encryptable` | Stable |
| `TTIOIndexable` | `ttio.protocols.Indexable` | `com.dtwthalion.tio.protocols.Indexable` | Stable |
| `TTIOProvenanceable` | `ttio.protocols.Provenanceable` | `com.dtwthalion.tio.protocols.Provenanceable` | Stable |
| `TTIOStreamable` | `ttio.protocols.Streamable` | `com.dtwthalion.tio.protocols.Streamable` | Stable |

#### Value Classes

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOAxisDescriptor` | `ttio.axis_descriptor.AxisDescriptor` | `com.dtwthalion.tio.AxisDescriptor` | Stable |
| `TTIOCVParam` | `ttio.cv_param.CVParam` | `com.dtwthalion.tio.CVParam` | Stable |
| `TTIOEncodingSpec` | `ttio.encoding_spec.EncodingSpec` | `com.dtwthalion.tio.EncodingSpec` | Stable |
| `TTIOValueRange` | `ttio.value_range.ValueRange` | `com.dtwthalion.tio.ValueRange` | Stable |
| `TTIOEnums` (enums module) | `ttio.enums` | `com.dtwthalion.tio.Enums` | Stable |

#### Method-level notes

**CVAnnotatable** — 6-method surface, identical semantics in all three
languages. Naming follows language idiom:

| ObjC selector | Python method | Java method |
|---|---|---|
| `addCVParam:` | `add_cv_param(param)` | `addCvParam(CVParam)` |
| `removeCVParam:` | `remove_cv_param(param)` | `removeCvParam(CVParam)` |
| `allCVParams` | `all_cv_params()` | `allCvParams()` |
| `cvParamsForAccession:` | `cv_params_for_accession(accession)` | `cvParamsForAccession(String)` |
| `cvParamsForOntologyRef:` | `cv_params_for_ontology_ref(ontology_ref)` | `cvParamsForOntologyRef(String)` |
| `hasCVParamWithAccession:` | `has_cv_param_with_accession(accession)` | `hasCvParamWithAccession(String)` |

**AxisDescriptor** — Python and Java field names aligned to ObjC after M41.1:

| ObjC property | Python field | Java accessor | Note |
|---|---|---|---|
| `valueRange` | `value_range` | `valueRange()` | Python: was missing; Java: renamed from `range` |
| `samplingMode` | `sampling_mode` | `samplingMode()` | Java: renamed from `mode` |

**CVParam** — ObjC has `ontologyRef` and separate `unit`; Python previously
had `unit_accession`/`unit_name` split; Java record already matched ObjC:

| ObjC property | Python field | Java record component |
|---|---|---|
| `ontologyRef` | `ontology_ref` | `ontologyRef` |
| `accession` | `accession` | `accession` |
| `name` | `name` | `name` |
| `value` | `value` | `value` |
| `unit` | `unit` | `unit` |

**EncodingSpec** — `little_endian: bool` replaced by `byte_order: ByteOrder`
in Python (M41.1); `compression_level` dropped (moved to provider config);
`element_size()` method added in Python and Java.

**Enums / Precision** — Java `Precision` ordinals reordered to match ObjC
`NS_ENUM` values; `UINT8` removed from Java (not present in ObjC). Python and
Java both gain `ByteOrder` enum and `Compression.NUMPRESS_DELTA`.

**ValueRange** — Java gains `span()` and `contains(double)` methods to match
ObjC `TTIOValueRange`; Python already had equivalents.

#### Fixes applied in M41.1

- Python `AxisDescriptor` was missing `value_range` field — added.
- Java `AxisDescriptor.range` renamed to `valueRange`; `mode` renamed to
  `samplingMode` — all call sites updated.
- Python `CVParam` had `unit_accession`/`unit_name` as separate fields;
  collapsed into single `unit` field matching ObjC — importers and tests
  updated.
- Python `CVParam` was missing `ontology_ref` field — added; importers
  updated to populate it from accession prefix.
- Python `EncodingSpec` replaced `little_endian: bool` with
  `byte_order: ByteOrder` enum field.
- Python `EncodingSpec` gained `element_size()` method (e.g. 8 for FLOAT64).
- Java `EncodingSpec` gained `elementSize()` method.
- Java `Enums.Precision` ordinals reordered to match ObjC; `UINT8` removed.
- Python and Java both gained `Compression.NUMPRESS_DELTA` enum value.
- Python and Java gained `ByteOrder` enum (`LITTLE_ENDIAN`, `BIG_ENDIAN`).
- Java `ValueRange` gained `span()` and `contains(double)` to match ObjC.
- Python `protocols` subpackage created (`ttio.protocols.__init__.py`).
- Java `protocols` package created (`com.dtwthalion.tio.protocols`).
- All five domain protocol interfaces created in Python and Java.

#### Deferred

- Python/Java `CVTermMapper` full `ontology_ref` population — touched
  minimally in 41.1; full alignment delivered in M41.8.

---

### Slice 41.2 — Core + Spectra

**Commit:** `621d9b9` `M41.2: Core + Spectra parity`

#### Classes

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOSignalArray` | `ttio.signal_array.SignalArray` | `com.dtwthalion.tio.SignalArray` | Stable |
| `TTIONumpress` | `ttio._numpress` (internal) | `com.dtwthalion.tio.NumpressCodec` | Internal (Python); Stable (Java/ObjC public surface) |
| `TTIOSpectrum` | `ttio.spectrum.Spectrum` | `com.dtwthalion.tio.Spectrum` | Stable |
| `TTIOMassSpectrum` | `ttio.mass_spectrum.MassSpectrum` | `com.dtwthalion.tio.MassSpectrum` | Stable |
| `TTIONMRSpectrum` | `ttio.nmr_spectrum.NMRSpectrum` | `com.dtwthalion.tio.NMRSpectrum` | Stable |
| `TTIONMR2DSpectrum` | `ttio.nmr_2d.NMR2DSpectrum` | `com.dtwthalion.tio.NMR2DSpectrum` | Stable |
| `TTIOFreeInductionDecay` | `ttio.fid.FreeInductionDecay` | `com.dtwthalion.tio.FreeInductionDecay` | Stable |
| `TTIOChromatogram` | `ttio.chromatogram.Chromatogram` | `com.dtwthalion.tio.Chromatogram` | Stable |

#### Method-level notes

**SignalArray** — now conforms to `CVAnnotatable` in all three languages.
Python `axis` is nullable (`AxisDescriptor | None`); Java axis nullable.
Convenience constructors: Python `from_numpy()`, Java `ofDoubles()`/`ofFloats()`.
Python exposes `__len__`; Java exposes `length()`.

**Numpress** — encode/decode method names are a known stylistic difference
(see §4). Java gains `scaleForRange(double min, double max)` to match ObjC's
`+scaleForRangeMin:max:` selector; Java's `computeScale(double[])` is retained
as a convenience wrapper.

**Spectrum (base class)** — Python renamed `channels` → `signal_arrays` to
match ObjC `signalArrays`. Both Python and Java gained `axes: list[AxisDescriptor]`
and base-class `precursor_mz`/`precursor_charge` fields (moved from
`MassSpectrum`).

| ObjC property | Python field | Java field/accessor | Note |
|---|---|---|---|
| `signalArrays` | `signal_arrays` | `signalArrays()` | Python: renamed from `channels` |
| `axes` | `axes` | `axes()` | Added to base in both langs |
| `precursorMz` | `precursor_mz` | `precursorMz()` | Moved from MassSpectrum to base |
| `precursorCharge` | `precursor_charge` | `precursorCharge()` | Moved from MassSpectrum to base |
| `indexPosition` | `index_position` | `indexPosition()` | Unchanged |
| `scanTimeSeconds` | `scan_time_seconds` | `scanTimeSeconds()` | Unchanged |

**MassSpectrum** — MS-specific fields that were on the base `Spectrum` in
Python (`ms_level`, `polarity`, `base_peak_intensity`, `retention_time`,
`run_name`) moved down to `MassSpectrum`. Both langs gained typed
`mz_array()`/`mzArray()` and `intensity_array()`/`intensityArray()` returning
`SignalArray`. `scan_window`/`scanWindow` added as `ValueRange | None`.

**NMRSpectrum** — Python `nucleus` renamed to `nucleus_type` (ObjC parity).
Python and Java gained `spectrometer_frequency_mhz`/`spectrometerFrequencyMhz`.
Both langs gained `chemical_shift_array()`/`chemicalShiftArray()` and
`intensity_array()`/`intensityArray()` returning `SignalArray`.

**NMR2DSpectrum** — Python replaced `f1_scale`/`f2_scale` arrays with
`f1_axis`/`f2_axis: AxisDescriptor`. Both langs now extend `Spectrum`.

**FreeInductionDecay** — both langs now extend `SignalArray`. Fields aligned
to ObjC: `dwell_time_seconds`/`dwellTimeSeconds`, `scan_count`/`scanCount`,
`receiver_gain`/`receiverGain`.

**Chromatogram** — both langs now extend `Spectrum`. Raw time/intensity arrays
replaced by `time_array`/`timeArray` and `intensity_array`/`intensityArray`
returning `SignalArray`. Fields retained: `chromatogram_type`, `target_mz`,
`precursor_mz`, `product_mz`.

#### Fixes applied in M41.2

- Python `SignalArray` gained `CVAnnotatable` conformance (`cv_params` list +
  6 methods); `axis` made nullable.
- Java `SignalArray` gained explicit `implements CVAnnotatable`.
- Java `NumpressCodec` gained `scaleForRange(double, double)` matching ObjC.
- Python `Spectrum.channels` renamed to `signal_arrays`; MS-specific fields
  dropped from base.
- Both langs: base `Spectrum` gained `axes` and `precursor_mz`/`precursor_charge`.
- Python `MassSpectrum` gained typed `mz_array()`/`intensity_array()` returning
  `SignalArray`; `scan_window: ValueRange | None`.
- Python `NMRSpectrum.nucleus` renamed to `nucleus_type`; added
  `spectrometer_frequency_mhz`.
- Java `NMRSpectrum` gained typed `chemicalShiftArray()`/`intensityArray()`.
- Python `NMR2DSpectrum` refactored to inherit `Spectrum`; `f1_scale`/`f2_scale`
  → `f1_axis`/`f2_axis: AxisDescriptor`.
- Java `NMR2DSpectrum` made to extend `Spectrum`; added `indexPosition`.
- Both langs: `FreeInductionDecay` refactored to extend `SignalArray`; field
  names aligned to ObjC (`dwell_time_seconds`, `scan_count`, `receiver_gain`).
- Both langs: `Chromatogram` refactored to extend `Spectrum`; `time_array`/
  `intensity_array` returning `SignalArray` replacing raw arrays.
- Importer and exporter call sites updated for all renamed fields.

#### Deferred

- None from this slice. All Numpress encode/decode naming differences are
  preserved as known stylistic differences (§4).

---

### Slice 41.3 — Run + Image

**Commit:** `8b300a9` `M41.3: Run + Image parity`

#### Classes

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOAcquisitionRun` | `ttio.acquisition_run.AcquisitionRun` | `com.dtwthalion.tio.AcquisitionRun` | Stable |
| `TTIOInstrumentConfig` | `ttio.instrument_config.InstrumentConfig` | `com.dtwthalion.tio.InstrumentConfig` | Stable |
| `TTIOSpectrumIndex` | `ttio.acquisition_run.SpectrumIndex` | `com.dtwthalion.tio.SpectrumIndex` | Stable |
| `TTIOMSImage` | `ttio.ms_image.MSImage` | `com.dtwthalion.tio.MSImage` | Stable |

#### Method-level notes

**AcquisitionRun** — now conforms to `Indexable`, `Streamable`, and
`Provenanceable` in Python and Java (matching ObjC conformances). `Encryptable`
conformance was deferred from this slice and delivered in M41.5.

**SpectrumIndex** — gained element-at accessors and range-query methods in
both languages:

| ObjC method | Python method | Java method |
|---|---|---|
| `offsetAtIndex:` | `offset_at(i)` | `offsetAt(int)` |
| `lengthAtIndex:` | `length_at(i)` | `lengthAt(int)` |
| `retentionTimeAtIndex:` | `retention_time_at(i)` | `retentionTimeAt(int)` |
| `msLevelAtIndex:` | `ms_level_at(i)` | `msLevelAt(int)` |
| `polarityAtIndex:` | `polarity_at(i)` | `polarityAt(int)` |
| `precursorMzAtIndex:` | `precursor_mz_at(i)` | `precursorMzAt(int)` |
| `precursorChargeAtIndex:` | `precursor_charge_at(i)` | `precursorChargeAt(int)` |
| `basePeakIntensityAtIndex:` | `base_peak_intensity_at(i)` | `basePeakIntensityAt(int)` |
| `indicesInRetentionTimeRange:` | `indices_in_retention_time_range(vr)` | `indicesInRetentionTimeRange(ValueRange)` |
| `indicesForMsLevel:` | `indices_for_ms_level(level)` | `indicesForMsLevel(int)` |

**MSImage** — ObjC `TTIOMSImage` inherits from `TTIOSpectralDataset`.
Python and Java use composition instead (see Known Stylistic Differences §4).
Dataset-level fields added to Python and Java `MSImage` as direct members:

| ObjC (inherited) property | Python field | Java field |
|---|---|---|
| `title` | `title` | `title` |
| `isaInvestigationId` | `isa_investigation_id` | `isaInvestigationId` |
| `identifications` | `identifications` | `identifications` |
| `quantifications` | `quantifications` | `quantifications` |
| `provenanceRecords` | `provenance_records` | `provenanceRecords` |
| `tileSize` | `tile_size` | `tileSize` |

**InstrumentConfig** — fields already matched ObjC prior to M41; docstring
and xref parity only in this slice.

#### Fixes applied in M41.3

- Python and Java `AcquisitionRun` gained `Indexable`, `Streamable`, and
  `Provenanceable` conformance.
- Python and Java `SpectrumIndex` gained 8 element-at accessors and 2
  range-query methods.
- Python and Java `MSImage` gained 5 dataset-level composition fields (`title`,
  `isa_investigation_id`, `identifications`, `quantifications`,
  `provenance_records`) plus `tile_size`.
- GSdoc / NumPy / Javadoc cross-language xref blocks added to all four ObjC
  headers.

#### Deferred

- `AcquisitionRun` `Encryptable` conformance — delivered in M41.5.
- `MSImage` extending `SpectralDataset` — preserved as composition and
  documented as a known stylistic difference (§4). Not a target for future
  milestones unless the lifecycle mismatch is resolved.

---

### Slice 41.4 — Dataset

**Commit:** `551e157` `M41.4: Dataset parity`

#### Classes

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOIdentification` | `ttio.identification.Identification` | `com.dtwthalion.tio.Identification` | Stable |
| `TTIOProvenanceRecord` | `ttio.provenance.ProvenanceRecord` | `com.dtwthalion.tio.ProvenanceRecord` | Stable |
| `TTIOQuantification` | `ttio.quantification.Quantification` | `com.dtwthalion.tio.Quantification` | Stable |
| `TTIOTransitionList` | `ttio.transition_list.TransitionList` | `com.dtwthalion.tio.TransitionList` | Stable |
| `TTIOTransition` (nested) | `ttio.transition_list.Transition` | `com.dtwthalion.tio.TransitionList.Transition` | Stable |
| `TTIOSpectralDataset` | `ttio.spectral_dataset.SpectralDataset` | `com.dtwthalion.tio.SpectralDataset` | Stable |
| `TTIOCompoundIO` | `ttio._hdf5_io` (internal) | `com.dtwthalion.tio.hdf5.Hdf5CompoundIO` (internal) | Internal |

#### Method-level notes

**Identification** — Java previously used raw JSON strings for `evidenceChainJson`.
Now exposes typed `List<String>` via `evidenceChain()` record component; the
raw JSON getter is preserved as a computed property for serialization.

**ProvenanceRecord** — Java previously had `inputRefsJson`, `outputRefsJson`,
`parametersJson` as raw strings. Now typed:

| ObjC property | Python field | Java accessor | Previous Java form |
|---|---|---|---|
| `inputRefs` | `input_refs: list[str]` | `inputRefs(): List<String>` | `inputRefsJson()` raw string |
| `outputRefs` | `output_refs: list[str]` | `outputRefs(): List<String>` | `outputRefsJson()` raw string |
| `parameters` | `parameters: dict[str, str]` | `parameters(): Map<String,String>` | `parametersJson()` raw string |

Both Python and Java `ProvenanceRecord` gained `contains_input_ref(ref)` /
`containsInputRef(String)` method matching ObjC `containsInputRef:`.
Raw JSON getters (`inputRefsJson()`, `outputRefsJson()`, `parametersJson()`)
preserved on Java for downstream serialization callers.

**TransitionList.Transition** — Python `retention_time_window` upgraded from
`tuple[float, float]` to `ValueRange`. Java gained `retentionTimeWindow` field;
dropped non-ObjC `name` field (pre-release, no callers). Both langs gained
`count()` and `transition_at_index(i)` / `transitionAtIndex(int)` on
`TransitionList`.

**SpectralDataset** — docstring + xref parity only in this slice; `Encryptable`
conformance deferred to M41.5.

**CompoundIO** — ObjC has a public `TTIOCompoundIO` class. Python's equivalent
is underscore-prefixed (`_hdf5_io.py`); Java's is in the `hdf5` subpackage
(`Hdf5CompoundIO`). These are **Internal** and carry no parity guarantee.
Documented as a known stylistic difference (§4).

#### Fixes applied in M41.4

- Java `Identification` and `ProvenanceRecord` gained typed list/map record
  components, replacing raw-JSON-string workarounds.
- Java `AcquisitionRun.parseStringArray` workaround removed (now that
  `inputRefs`/`outputRefs` are typed).
- Python `TransitionList.Transition.retention_time_window` changed from
  `tuple[float, float]` to `ValueRange`.
- Java `TransitionList.Transition` gained `retentionTimeWindow`, dropped
  `name` field.
- Both langs gained `count()` and `transitionAtIndex(int)` /
  `transition_at_index(i)` on `TransitionList`.
- Both Python and Java `ProvenanceRecord` gained `contains_input_ref` /
  `containsInputRef`.
- `MiniJson` (Java internal) gained `parseStringMap` helper for typed reads.
- GSdoc xref blocks added to six ObjC headers.

#### Deferred

- `SpectralDataset` `Encryptable` conformance — delivered in M41.5.

---

### Slice 41.5 — Protection

**Commit:** `fc88d8e` `M41.5: Protection parity`

#### Classes

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOAccessPolicy` | `ttio.access_policy.AccessPolicy` | `com.dtwthalion.tio.protection.AccessPolicy` | Stable |
| `TTIOAnonymizer` | `ttio.anonymization` (module) | `com.dtwthalion.tio.protection.Anonymizer` | Stable |
| `TTIOEncryptionManager` | `ttio.encryption` (module) | `com.dtwthalion.tio.protection.EncryptionManager` | Stable |
| `TTIOKeyRotationManager` | `ttio.key_rotation` (module) | `com.dtwthalion.tio.protection.KeyRotationManager` | Stable |
| `TTIOSignatureManager` | `ttio.signatures` (module) | `com.dtwthalion.tio.protection.SignatureManager` | Stable |
| `TTIOVerifier` | `ttio.verifier.Verifier` | `com.dtwthalion.tio.protection.Verifier` | Stable |
| `TTIOVerificationStatus` | `ttio.verifier.VerificationStatus` | `com.dtwthalion.tio.protection.VerificationStatus` | Stable |

**Note on manager idioms:** ObjC uses class methods (e.g.
`+[TTIOEncryptionManager encryptData:withKey:error:]`). Python uses module-level
functions (e.g. `ttio.encryption.encrypt_bytes(plaintext, key)`).
Java uses a mix of static and instance methods. These are preserved as known
stylistic differences (§4).

#### Method-level notes

**Encryptable conformance on AcquisitionRun and SpectralDataset** — delivered
in this slice for both Python and Java; surface only in M41.5 (raising
stubs on `encrypt_with_key` / `decrypt_with_key`), **full delegation
completed post-M41.9** via new `encrypt_intensity_channel_in_run` helper on
`ttio.encryption` / `EncryptionManager.encryptIntensityChannelInRun`.

| ObjC method | Python method | Java method | Status |
|---|---|---|---|
| `accessPolicy` | `access_policy()` | `accessPolicy()` | Functional |
| `setAccessPolicy:` | `set_access_policy(policy)` | `setAccessPolicy(AccessPolicy)` | Functional |
| `encryptWithKey:error:` | `encrypt_with_key(key, level)` | `encryptWithKey(byte[], EncryptionLevel)` | Functional |
| `decryptWithKey:error:` | `decrypt_with_key(key) -> bytes` | `decryptWithKey(byte[])` | Functional |

Python uses `SpectralDataset.open(path, writable=True)` to keep the file
in R/W mode during the encrypt session; Java matches the ObjC pattern
(close the dataset before calling `run.encryptWithKey`; the persistence
context on the run allows the delegation to re-open the file R/W).

**Verifier** — class was missing entirely in Python and Java; added in this
slice. `VerificationStatus` enum with 4 states
(`VALID`, `INVALID`, `NOT_SIGNED`, `ERROR`) added to both languages.

**AccessPolicy** — value class missing in Python and Java; added in this slice.

#### Fixes applied in M41.5

- Python and Java gained `AccessPolicy` value class (was missing entirely).
- Python and Java gained `Verifier` class and `VerificationStatus` enum.
- Python `AcquisitionRun` and `SpectralDataset` gained `Encryptable`
  conformance (deferred from M41.3/M41.4).
- Java `AcquisitionRun` and `SpectralDataset` gained `Encryptable` conformance.
- `encrypt_with_key`/`decrypt_with_key` raise intentionally during M41.5
  (pending context); **fully implemented post-M41.9** via new
  `encrypt_intensity_channel_in_run` helper + persistence-context wiring.
- GSdoc xref blocks added to six ObjC protection headers.

#### Deferred

- Java `KeyRotationManager` and `SignatureManager` static-vs-instance shape
  differences preserved as known stylistic differences; no further alignment
  planned for v0.6.

---

### Slice 41.6 — Query

**Commit:** `00b9f2b` `M41.6: Query parity`

#### Classes

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOQuery` | `ttio.query.Query` | `com.dtwthalion.tio.Query` | Stable |
| `TTIOStreamReader` | `ttio.stream_reader.StreamReader` | `com.dtwthalion.tio.StreamReader` | Stable |
| `TTIOStreamWriter` | `ttio.stream_writer.StreamWriter` | `com.dtwthalion.tio.StreamWriter` | Stable |

#### Method-level notes

**Query** — fluent builder. All methods return `self`/`this` for chaining.
`matching_indices()`/`matchingIndices()` performs AND-intersection of all
applied filters, returning `list[int]`/`List<Integer>`.

| ObjC selector | Python method | Java method |
|---|---|---|
| `onIndex:` | `Query.on_index(index)` | `Query.onIndex(SpectrumIndex)` |
| `withRetentionTimeRange:` | `with_retention_time_range(vr)` | `withRetentionTimeRange(ValueRange)` |
| `withMsLevel:` | `with_ms_level(level)` | `withMsLevel(int)` |
| `withPolarity:` | `with_polarity(polarity)` | `withPolarity(Polarity)` |
| `withPrecursorMzRange:` | `with_precursor_mz_range(vr)` | `withPrecursorMzRange(ValueRange)` |
| `withBasePeakIntensityAtLeast:` | `with_base_peak_intensity_at_least(t)` | `withBasePeakIntensityAtLeast(double)` |
| `matchingIndices` | `matching_indices()` | `matchingIndices()` |

**StreamReader** — thin wrapper over `AcquisitionRun`'s `Streamable` surface
(M41.3), adding file-path construction sugar. Python uses context manager
(`__enter__`/`__exit__`); Java implements `AutoCloseable` with try-with-resources.

**StreamWriter** — incremental append + whole-file regenerative flush.
`append_spectrum` / `appendSpectrum` buffers in memory. `flush()`
materializes the `.tio` file by packing buffered spectra into an
`AcquisitionRun` and delegating to Python `SpectralDataset.write_minimal`
/ Java `SpectralDataset.create`. **Full integration completed post-M41.9**;
all surface methods are functional.

| ObjC selector | Python method | Java method | Status |
|---|---|---|---|
| `appendSpectrum:` | `append_spectrum(spectrum)` | `appendSpectrum(MassSpectrum)` | Functional |
| `spectrumCount` | `spectrum_count` | `spectrumCount()` | Functional |
| `flushWithError:` | `flush()` | `flush()` | Functional |

**Note:** Java `Hdf5File` surface uses `openReadOnly(path)` (not the
hypothetical `open(path, false)` in the original plan); `StreamReader` was
adapted accordingly.

#### Fixes applied in M41.6

- Python and Java gained `Query` class (was missing entirely).
- Python and Java gained `StreamReader` class (was missing entirely).
- Python and Java gained `StreamWriter` class (was missing entirely).
- GSdoc xref blocks added to three ObjC query headers.

#### Deferred

- None. `StreamWriter.flush` integration with `SpectralDataset` write path
  was surface-only in M41.6; **fully implemented post-M41.9** —
  `flush()` now materializes a valid `.tio` file.

---

### Slice 41.7 — Storage Providers

**Commit:** `d57a036` `M41.7: Storage providers parity`

#### Classes

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOStorageProvider` | `ttio.providers.StorageProvider` | `com.dtwthalion.tio.providers.StorageProvider` | Provisional (per M39) |
| `TTIOStorageGroup` | `ttio.providers.StorageGroup` | `com.dtwthalion.tio.providers.StorageGroup` | Provisional (per M39) |
| `TTIOStorageDataset` | `ttio.providers.StorageDataset` | `com.dtwthalion.tio.providers.StorageDataset` | Provisional (per M39) |
| `TTIOCompoundField` | `ttio.providers.CompoundField` | `com.dtwthalion.tio.providers.CompoundField` | Provisional (per M39) |
| `TTIOHDF5Provider` | `ttio.providers.Hdf5Provider` | `com.dtwthalion.tio.providers.Hdf5Provider` | Provisional (per M39) |
| `TTIOMemoryProvider` | `ttio.providers.MemoryProvider` | `com.dtwthalion.tio.providers.MemoryProvider` | Provisional (per M39) |
| `TTIOProviderRegistry` | `ttio.providers` (module-level) | `com.dtwthalion.tio.providers.ProviderRegistry` | Provisional (per M39) |

**Note on Provisional status:** All storage-provider classes are marked
`API status: Provisional — may change before v1.0.` in their docstrings.
The implementations shipped in Milestone 39; M41.7 added uniform documentation
and cross-language xref blocks.

#### Method-level notes

**ProviderRegistry** — an intentional language-idiomatic divergence (see §4):
ObjC and Java use a `ProviderRegistry` class with class/static methods.
Python uses module-level functions (`ttio.providers.register_provider(name, factory)`,
`ttio.providers.open_provider(url)`, `ttio.providers.discover_providers()`).
This is a known stylistic difference, not a parity gap.

**StorageProvider / StorageGroup / StorageDataset** — abstract interfaces in
all three languages. Protocol method surface matches; Python uses `ABC`,
Java uses `interface`, ObjC uses `@protocol`.

**CompoundField** — value class (ObjC struct-like, Python dataclass, Java
record). Fields `name` and `kind` match across all three; `kind` is a
4-member enum (`UINT32`, `INT64`, `FLOAT64`, `VL_STRING`).

#### Fixes applied in M41.7

- Cross-language xref blocks and `API status: Provisional` lines added to
  all provider-subsystem classes in all three languages.
- Parity smoke tests added: Python (+2), Java (+2).

#### Deferred

- Zarr and SQLite provider implementations — deferred to post-v0.6.
- Provider interface versioning strategy — deferred to post-v0.6 when Provisional
  moves to Stable.

---

### Slice 41.8 — Import/Export

**Commit:** `13c024e` `M41.8: Import/Export parity`

#### Classes

| Objective-C | Python | Java | Stability |
|---|---|---|---|
| `TTIOMzMLReader` | `ttio.importers.mzml` (module) | `com.dtwthalion.tio.importers.MzMLReader` | Stable |
| `TTIOMzMLWriter` | `ttio.exporters.mzml` (module) | `com.dtwthalion.tio.exporters.MzMLWriter` | Stable |
| `TTIONmrMLReader` | `ttio.importers.nmrml` (module) | `com.dtwthalion.tio.importers.NmrMLReader` | Stable |
| `TTIONmrMLWriter` | `ttio.exporters.nmrml` (module) | `com.dtwthalion.tio.exporters.NmrMLWriter` | Stable |
| `TTIOThermoRawReader` | `ttio.importers.thermo_raw` (module) | `com.dtwthalion.tio.importers.ThermoRawReader` | Stable |
| `TTIOISAExporter` | `ttio.exporters.isa` (module) | `com.dtwthalion.tio.exporters.ISAExporter` | Stable |
| `TTIOCVTermMapper` | `ttio.importers.cv_term_mapper` (module) | `com.dtwthalion.tio.importers.CVTermMapper` | Stable |
| `TTIOBase64` | `ttio.importers._base64_zlib` (internal) | `java.util.Base64` (stdlib, no wrapper) | Internal |
| — | `ttio.importers.ImportResult` | — | Internal (Python-only helper) |

#### Method-level notes

**CVTermMapper** — `precisionFor` returns `Precision.FLOAT64` for unknown
accessions in all three languages, matching the safe-default contract.
Previously Java returned `null`; fixed in a post-M41.9 commit by aligning
Java's default to FLOAT64 and adding a companion `isPrecisionAccession(String)`
helper for dispatch code that needs to distinguish "unknown cvParam" from
"actually FLOAT64". The `MzMLReader` was updated to gate on
`isPrecisionAccession` before calling `precisionFor`, matching ObjC's
membership-check-first dispatch pattern. No remaining cross-language
behavior divergences in the v0.6 surface.

**Base64** — ObjC wraps Base64 in `TTIOBase64` (public). Python has a private
`_base64_zlib` helper (internal). Java uses `java.util.Base64` from the
standard library directly with no wrapper class. Round-trip byte compatibility
is verified by cross-compat tests (8/8). This is documented as an Internal
helper; no parity requirement.

**ImportResult** — Python `ImportResult` / `ImportedSpectrum` DTO is a
Python-idiomatic convenience with no ObjC or Java equivalent. ObjC and Java
use inline structures for the same purpose. Classified as Internal.

#### Fixes applied in M41.8

- Cross-language xref blocks added to all Import/Export ObjC headers.
- Python module docstrings updated with Cross-language equivalents footers.
- Java classes updated with Javadoc extensions.
- Python parity tests added for CVTermMapper accession lookup and Base64
  round-trip (+2 tests).
- Java parity test added for CVTermMapper accession lookup (+1 test).
- `CVTermMapper.precisionFor` Java divergence (`null` vs `FLOAT64`) documented
  in commit message and this review; behavior not changed in this slice.
  **Fixed post-M41.9** by making Java return `Precision.FLOAT64` default and
  adding `isPrecisionAccession(String)` helper; `MzMLReader` dispatch updated
  to match ObjC's membership-first pattern.

#### Deferred

- Java Base64 wrapper class — not planned; stdlib usage is idiomatic and
  preferred.

---

## 4. Known Stylistic Differences (Not Divergences)

The following differences are deliberate language-idiomatic choices. They are
not parity gaps. Adding them to this section is a commitment that they will
**not** be "fixed" unless a consensus across all three language communities
exists.

### 4.1 Naming conventions

ObjC uses labeled selectors (`cvParamsForAccession:`), Python uses
`snake_case` keyword args (`cv_params_for_accession(accession)`), Java uses
`camelCase` (`cvParamsForAccession(String accession)`). This pattern is
universal across the entire API surface and is not enumerated class-by-class.

### 4.2 Error conveyance

| Language | Pattern |
|---|---|
| Objective-C | `NSError **` out-parameter; returns `nil` or `NO` on failure |
| Python | Raises `ValueError`, `RuntimeError`, or domain-specific exceptions |
| Java | Raises `IllegalArgumentException`, `IllegalStateException`, or checked exceptions |

No class carries explicit error-type parity requirements. The semantics (what
constitutes an error) are identical; the conveyance mechanism is idiomatic.

### 4.3 Resource management

| Language | Pattern |
|---|---|
| Objective-C | Manual retain/release (ARC); `NSError **` + `BOOL` return for I/O |
| Python | Context managers (`with StreamReader(...) as r:`) via `__enter__`/`__exit__` |
| Java | `AutoCloseable` + try-with-resources (`try (StreamReader r = ...)`) |

`StreamReader` and `SpectralDataset` follow this pattern. No ObjC equivalent
of context managers; callers are responsible for lifecycle.

### 4.4 Idiomatic conveniences

Python classes expose `__len__` and `__iter__` where natural:
- `SignalArray.__len__` → `len(sa)`
- `TransitionList.__iter__` and `__len__` → `len(tl)`, `for t in tl:`

Java exposes `toString()` overrides and `equals()`/`hashCode()` on record
types (`CVParam`, `ValueRange`, `CompoundField`).

ObjC exposes `description` (equivalent to `toString`) and uses `isEqual:`.

These are idiomatic language conveniences. No cross-language parity requirement.

### 4.5 Registry idiom

The storage-provider registry diverges intentionally:
- ObjC: `TTIOProviderRegistry` class with class methods.
- Java: `com.dtwthalion.tio.providers.ProviderRegistry` class with static
  methods.
- Python: module-level functions in `ttio.providers` (`register_provider()`,
  `open_provider()`, `discover_providers()`).

### 4.6 Base64 handling

ObjC provides a public `TTIOBase64` wrapper class. Java uses `java.util.Base64`
from the standard library with no wrapper. Python has a private
`ttio.importers._base64_zlib` helper that is not part of the public API.
Round-trip byte compatibility is verified by cross-compat fixtures.

### 4.7 MSImage inheritance vs composition

ObjC: `TTIOMSImage` inherits from `TTIOSpectralDataset` — file-container
semantics propagate via inheritance.

Python and Java: `SpectralDataset` is a resource-holding file handle whose
lifecycle (open/close) does not map cleanly to an MSImage subclass.
`MSImage` uses composition — the five dataset-level fields (`title`,
`isa_investigation_id`, `identifications`, `quantifications`,
`provenance_records`) live on `MSImage` directly as plain fields.

This difference is structural and intentional. It is not expected to change
in v0.6 or v1.0 without rearchitecting the Python/Java `SpectralDataset`.

### 4.8 CompoundIO accessibility

ObjC `TTIOCompoundIO` is a public class. Python's equivalent is
`ttio._hdf5_io` (private by underscore convention). Java's equivalent is
`com.dtwthalion.tio.hdf5.Hdf5CompoundIO` (in an `hdf5` subpackage,
effectively semi-internal). No parity requirement across these three; they are
all classified as **Internal**.

### 4.9 Numpress encode/decode naming

ObjC: `encodeFloat64:count:scale:outDeltas:` — verbose labeled selector.
Python (`_numpress` private): `encode()` / `decode()`.
Java (public `NumpressCodec`): `linearEncode()` / `linearDecode()`.

The Java names are idiomatic for the Numpress linear algorithm. The ObjC/Python
names are generic. These names were considered for alignment in M41.2 and
deliberately left as-is.

### 4.10 Encryptable methods — resolved

`encrypt_with_key` / `decrypt_with_key` on `AcquisitionRun` and
`SpectralDataset` raised `NotImplementedError` / `UnsupportedOperationException`
during M41.5 (surface only). **Fully implemented post-M41.9** via new
`encrypt_intensity_channel_in_run` helper on `ttio.encryption` / Java
`EncryptionManager.encryptIntensityChannelInRun`, plus persistence-context
wiring on `AcquisitionRun` + `SpectralDataset`. All three languages now
perform real AES-256-GCM encryption of the intensity channel with
byte-identical wire format. Python uses `SpectralDataset.open(path,
writable=True)` to keep the file R/W during the encrypt session; Java
matches the ObjC close-then-encrypt pattern (retain run reference, close
dataset, call `run.encryptWithKey(key, level)` which re-opens R/W via
the persistence context).

### 4.11 StreamWriter.flush — resolved

`StreamWriter.flush()` raised during M41.6 pending the write-path
integration. **Fully implemented post-M41.9**: `flush()` in both
Python and Java packs buffered `MassSpectrum` objects into an
`AcquisitionRun` and materializes a valid `.tio` file by delegating
to Python's `SpectralDataset.write_minimal` / Java's
`SpectralDataset.create`.
The ObjC `flushWithError:` has the same deferred status. Not a divergence.

### 4.12 Java CVTermMapper.precisionFor — resolved

Previously Java's `CVTermMapper.precisionFor(String)` returned `null` for
an unrecognised accession while ObjC and Python returned `Precision.FLOAT64`
as a safe default. **Fixed post-M41.9**: Java now returns FLOAT64 default
too, and adds an `isPrecisionAccession(String)` helper for dispatch code
(e.g. `MzMLReader`) that needs to distinguish "unknown cvParam" from
"actually FLOAT64". The `MzMLReader` dispatcher was updated to gate on
`isPrecisionAccession` before calling `precisionFor`, matching ObjC's
membership-first dispatch pattern. No remaining behavior divergences in
the v0.6 surface.

---

## 5. Appendix — Audit Methodology

This review was conducted as part of Milestone 41 of TTI-O v0.6 development.
For each of the eight subsystems (slices 41.1–41.8), Objective-C headers were
read as the normative reference; Python and Java counterparts were audited for
class-shape parity, field/property parity, and method-surface parity.
Divergences were classified into five categories: **Missing-member**
(a method or field present in ObjC but absent in Python or Java),
**Shape-drift** (inheritance or composition differs), **Signature-drift**
(parameter types differ beyond language idiom), **Naming-drift** (names differ
beyond the snake_case / camelCase / labeled-selector convention), and
**Extra-member** (a method or field present in Python or Java with no ObjC
equivalent). Language-idiomatic differences (naming conventions, error
conveyance, resource management, registry patterns) were preserved as known
stylistic differences (§4) rather than resolved against ObjC. All Missing-member
and Signature-drift gaps were resolved within the slice that introduced them;
Shape-drift differences are documented per-subsystem. The audit was re-verified
at each slice boundary by running `./build.sh check` (ObjC), `pytest` (Python),
and `mvn verify` (Java) and confirming that three-way cross-compatibility
fixtures round-trip (8/8). Final test counts at M41.9 completion:
ObjC 867 assertions, Python 184, Java 126. Post-M41.9 behavior fixes
(CVTermMapper.precisionFor, real Encryptable delegation, StreamWriter.flush)
bring counts to Python 187, Java 128.

To reproduce this review for a future milestone: read ObjC headers in
`objc/Source/` as normative; compare field names, method names, and parameter
types against Python `python/src/ttio/` and Java
`java/src/main/java/com/dtwthalion/ttio/`; apply the same five-category
classification; preserve all entries in §4 unless a consensus decision to
align exists.

---

## 6. Appendix B — SQLite Provider: Provisional Stress-Test Findings

Post-v0.6.0, a third storage provider (`SqliteProvider`) was implemented in
all three languages as a stress test of the Provisional storage-provider
subsystem. The explicit goal was to accumulate cross-backend experience
so the subsystem can move Provisional → Stable in v0.7 with known
interface gaps documented rather than discovered mid-migration.

### Deliverables

| Language | File | Tests |
|---|---|---|
| Python | `ttio/providers/sqlite.py` (700 LoC) | 24 tests |
| Java | `com.dtwthalion.tio.providers.SqliteProvider` (670 LoC) | 24 tests |
| Objective-C | `TTIOSqliteProvider.m` (~850 LoC) | 132 assertions |

Schema identical across all three (DDL, PRAGMAs, little-endian BLOB layout,
JSON compound encoding). Cross-language compat verified manually: a
`.tio.sqlite` written by any implementation is byte-identically readable
by the other two.

**Commits:**
- `44baf65` — Python SqliteProvider + structural round-trip test (A+C₁)
- `b3d5b46` — Java + ObjC SqliteProvider (B)

### 6.1 Interface gaps surfaced

These are the 13 gaps the tri-language stress test surfaced. Each should
be resolved or consciously accepted before the storage-provider subsystem
moves to Stable in v0.7.

#### Cross-backend abstraction leaks (all languages)

**Gap 1 — `open` classmethod vs instance-mutating usage.** The ABC / protocol
declares `open` as a factory-style classmethod in Python and similar in
Java, but callers commonly write `p = Provider(); p.open(path)` expecting
`p` to be mutated. A classmethod receives `cls`, not the instance, so this
pattern silently does nothing. MemoryProvider has the same latent issue.
**Resolution candidates:** pick one style (factory classmethod OR two-phase
init-then-connect) and enforce it across all providers.

**Gap 2 — Compound `read()` return type divergence.** The ABC promises a
structured `ndarray` for compound datasets; SQLite stores compound rows as
JSON and returns `list[dict]` (Python) / `List<Map<String,Object>>` (Java).
Converting JSON rows to a typed structured array is expensive and lossy for
VL_STRING fields. **Resolution candidates:** (a) accept backend-specific
compound return types in the ABC contract, or (b) mandate a common
intermediate shape (e.g. list-of-dicts) across all backends, including HDF5.

**Gap 3 — `chunks` / `compression` / `compression_level` no-ops on SQLite.**
SQLite stores datasets as contiguous BLOBs; no chunked I/O, no filter
pipeline. Parameters are accepted for interface compatibility and silently
ignored. **Resolution candidate:** ABC should expose a
`supports_chunking()` / `supports_compression()` capability query so callers
can degrade gracefully; or mandate that providers raise
`NotImplementedError` on unsupported capabilities.

**Gap 4 — `read(offset, count)` for N-D primitives is full-BLOB-deserialize.**
SQLite BLOBs are opaque; hyperslab-style range reads require deserializing
the full dataset first. Acceptable for the stress-test role; disqualifies
SQLite for large imaging cubes where HDF5's chunked reads are essential.
**Resolution candidate:** document this as a performance characteristic,
not a correctness gap.

**Gap 5 — `provider_name` shape inconsistency.** Python ABC declares it as
`@property`; ObjC and Java expose it as a method. Mechanical for callers
to navigate but easy to get wrong when writing new tests. **Resolution:**
converge on one style in the Provisional review.

#### Language-specific gaps

**Gap 6 — JDBC `PRAGMA`-in-transaction constraint (Java only).**
`PRAGMA journal_mode = WAL` throws if executed inside an open transaction.
Must apply PRAGMAs in auto-commit mode before switching to
`setAutoCommit(false)`. No equivalent constraint in Python's `sqlite3`
module. Encoded as a fixed convention in the Java SqliteProvider.

**Gap 7 — `Enums.Precision` transitively loads HDF5 JNI (Java only).**
Unexpected architectural finding: `Enums.Precision` has a static
initializer that loads `HDF5Constants`, which requires the native HDF5 JNI
library and SLF4J on the classpath. A SqliteProvider with zero HDF5
dependency still drags HDF5 into the classpath the moment it references
`Precision`. Pre-existing architectural coupling, exposed by this slice.
**Resolution candidate:** factor Precision's HDF5 type-constants into a
separate `Precision.Hdf5Types` companion class that only loads on demand.

**Gap 8 — `StorageDataset` missing `deleteAttribute` / `attributeNames`
in the Java interface.** Python ABC declares both on `StorageDataset`;
Java interface omits them. Java SqliteDataset implements them as concrete
(non-interface) methods. **Resolution:** add these to the Java interface
in the Provisional review. See also gap 13.

**Gap 9 — ND write shape-update edge case (Java only).** Python's `write()`
updates `shape_json` to `arr.shape` (numpy carries the shape through).
Java's `writeAll(Object)` must special-case 1-D vs N-D array types.
Currently handled as a defensive in-place fix; not a protocol-level issue
but worth documenting.

**Gap 10 — `NSNumber objCType` ambiguity (ObjC only).** Detecting whether
a boxed `NSNumber` originated from a `float` vs `double` literal is
implementation-defined. ObjC SqliteProvider guards with both checks; the
`attr_type='float'` path fires correctly regardless of the box width.

**Gap 11 — Transaction model divergence.** ObjC and Java batch writes in
explicit `BEGIN ... COMMIT` transactions; Python commits per-write. The
batch style is faster for bulk loads but loses the most recent uncommitted
operation on crash. A future `beginTransaction` / `commitTransaction`
method on the ABC would let callers opt into batching explicitly.

**Gap 12 — `nativeHandle` returns nil for `sqlite3 *` (ObjC only).** ARC
cannot safely bridge-cast a raw C pointer to `id`. The protocol promises
a native handle for byte-level callers (signatures, encryption); SQLite's
`sqlite3 *` requires either an `NSValue` wrapper or a custom opaque
wrapper class. Currently returns `nil` and is documented.

**Gap 13 — `deleteAttributeNamed` missing from ObjC `<TTIOStorageDataset>`
protocol.** Matches gap 8 in Java. Systemic across the two typed
languages — the Python ABC has it, ObjC and Java protocols don't.

### 6.2 Recommendations for v0.7 Provisional → Stable review

1. **Resolve `open` shape** (gap 1) — pick one pattern, enforce in ABC and all three reference implementations.
2. **Resolve compound `read()` return type** (gap 2) — this is the most consequential abstraction leak; either admit backend-specific return types or mandate a uniform shape.
3. **Add capability queries** (gap 3) — `supports_chunking`, `supports_compression` on the protocol so callers can degrade.
4. **Add `deleteAttribute` + `attributeNames` to `StorageDataset`** in Java and ObjC protocols (gaps 8 and 13).
5. **Refactor `Precision` HDF5 coupling** (gap 7) so non-HDF5 providers don't drag HDF5 JNI.
6. **Add transaction-batch methods** to the protocol (gap 11) so the model is explicit rather than per-provider-convention.

The remaining gaps (4, 5, 6, 9, 10, 12) are either performance characteristics
or language-idiom-specific implementation notes that should be documented
as expected behavior rather than changed.

### 6.3 Test count impact

Post-SQLite-work totals:
- ObjC 999 assertions (867 M41 baseline + 132 SQLite)
- Python 211 tests (187 M41 baseline + 24 SQLite)
- Java 152 tests (128 M41 baseline + 24 SQLite)
- HDF5 cross-compat 8/8 unchanged.
