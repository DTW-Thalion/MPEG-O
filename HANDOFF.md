# HANDOFF — M73: Modality Abstraction + Genomic Enumerations

**Scope:** Add the foundational enumeration values, modality attribute,
feature flag, and transport spectrum_class that all subsequent genomic
milestones (M74–M87) depend on. Touches all three languages. No new
domain classes yet — this is purely the type-system and wire-format
groundwork.

**Branch from:** `main` at `v0.10.0` (or whatever HEAD is).

**CI must be green before this milestone is complete.** All existing
tests must continue to pass — this milestone is purely additive.

---

## 1. Enum Extensions

### 1a. Python — `python/src/mpeg_o/enums.py`

Add `UINT8 = 6` to `Precision`:

```python
class Precision(IntEnum):
    FLOAT32 = 0
    FLOAT64 = 1
    INT32 = 2
    INT64 = 3
    UINT32 = 4
    COMPLEX128 = 5
    UINT8 = 6           # v0.11 M73: genomic quality scores + packed bases
```

Update `numpy_dtype()`:

```python
def numpy_dtype(self) -> str:
    return {
        ...existing entries...
        Precision.UINT8: "u1",
    }[self]
```

Add genomic compression values to `Compression`:

```python
class Compression(IntEnum):
    NONE = 0
    ZLIB = 1
    LZ4 = 2
    NUMPRESS_DELTA = 3
    # v0.11 M73: genomic codecs (clean-room implementations)
    RANS_ORDER0 = 4
    RANS_ORDER1 = 5
    BASE_PACK = 6
    QUALITY_BINNED = 7
    NAME_TOKENIZED = 8
```

Add `GENOMIC_WGS = 7` and `GENOMIC_WES = 8` to `AcquisitionMode`:

```python
class AcquisitionMode(IntEnum):
    MS1_DDA = 0
    MS2_DDA = 1
    DIA = 2
    SRM = 3
    NMR_1D = 4
    NMR_2D = 5
    IMAGING = 6
    GENOMIC_WGS = 7   # v0.11 M73
    GENOMIC_WES = 8   # v0.11 M73
```

### 1b. Objective-C — `objc/Source/ValueClasses/MPGOEnums.h`

```objc
typedef NS_ENUM(NSUInteger, MPGOPrecision) {
    MPGOPrecisionFloat32 = 0,
    MPGOPrecisionFloat64,
    MPGOPrecisionInt32,
    MPGOPrecisionInt64,
    MPGOPrecisionUInt32,
    MPGOPrecisionComplex128,
    MPGOPrecisionUInt8          // v0.11 M73
};

typedef NS_ENUM(NSUInteger, MPGOCompression) {
    MPGOCompressionNone = 0,
    MPGOCompressionZlib,
    MPGOCompressionLZ4,
    MPGOCompressionNumpressDelta,
    MPGOCompressionRansOrder0,     // v0.11 M73
    MPGOCompressionRansOrder1,     // v0.11 M73
    MPGOCompressionBasePack,       // v0.11 M73
    MPGOCompressionQualityBinned,  // v0.11 M73
    MPGOCompressionNameTokenized   // v0.11 M73
};

typedef NS_ENUM(NSUInteger, MPGOAcquisitionMode) {
    MPGOAcquisitionModeMS1DDA = 0,
    MPGOAcquisitionModeMS2DDA,
    MPGOAcquisitionModeDIA,
    MPGOAcquisitionModeSRM,
    MPGOAcquisitionMode1DNMR,
    MPGOAcquisitionMode2DNMR,
    MPGOAcquisitionModeImaging,
    MPGOAcquisitionModeGenomicWGS,  // v0.11 M73
    MPGOAcquisitionModeGenomicWES   // v0.11 M73
};
```

Update `MPGOEncodingSpec.m` `-elementSize` to handle `MPGOPrecisionUInt8`:

```objc
case MPGOPrecisionUInt8: return 1;
```

### 1c. Java — `java/src/main/java/com/dtwthalion/mpgo/Enums.java`

```java
public enum Precision {
    FLOAT32(4),
    FLOAT64(8),
    INT32(4),
    INT64(8),
    UINT32(4),
    COMPLEX128(16),
    UINT8(1);           // v0.11 M73

    // existing elementSize field + constructor unchanged
}

public enum Compression {
    NONE,
    ZLIB,
    LZ4,
    NUMPRESS_DELTA,
    RANS_ORDER0,        // v0.11 M73
    RANS_ORDER1,        // v0.11 M73
    BASE_PACK,          // v0.11 M73
    QUALITY_BINNED,     // v0.11 M73
    NAME_TOKENIZED      // v0.11 M73
}

public enum AcquisitionMode {
    MS1_DDA, MS2_DDA, DIA, SRM,
    NMR_1D, NMR_2D, IMAGING,
    GENOMIC_WGS,        // v0.11 M73
    GENOMIC_WES          // v0.11 M73
}
```

### 1d. Provider UINT8 support

Each provider must handle `UINT8` in `createDataset` / `readAll` /
`writeAll` / `readSlice`:

**Python `mpeg_o/providers/hdf5.py`:** Map `Precision.UINT8` to
`numpy.dtype("u1")` in the dtype lookup. `h5py` handles uint8
natively — no special case needed beyond the dtype mapping.

**Python `mpeg_o/providers/memory.py`:** Already stores raw arrays;
`numpy.dtype("u1")` just works.

**Python `mpeg_o/providers/sqlite.py`:** Stores blob data; uint8
arrays serialise as `<u1` bytes. Add `Precision.UINT8` to the
precision-name ↔ dtype mapping tables.

**Python `mpeg_o/providers/zarr.py`:** `_DTYPE_TO_PRECISION` dict
needs `"uint8": Precision.UINT8`.

**ObjC providers:** `Hdf5Provider` needs `MPGOPrecisionUInt8` →
`H5T_NATIVE_UINT8` in the HDF5 type dispatch. `MemoryProvider` and
`SqliteProvider` need the precision name string `"uint8"` added.

**Java providers:** `Hdf5Provider` needs `Precision.UINT8` →
`HDF5Constants.H5T_NATIVE_UINT8` in `hdf5TypeFor()`. Read/write
paths need a `byte[]` branch alongside the existing `double[]`,
`int[]`, `long[]`, `float[]` branches. `MemoryProvider` and
`SqliteProvider` need `"uint8"` in their precision-name tables.

---

## 2. Transport: spectrum_class = 5 (GenomicRead)

### 2a. Python — `python/src/mpeg_o/transport/packets.py`

In the `AccessUnit` class, the `spectrum_class` doc comment already
lists values 0–4. Add:

```python
#   5 = GenomicRead
```

The `to_bytes()` and `from_buffer()` methods are generic over
`spectrum_class` — they serialise whatever uint8 value is set. No
code change needed for encode/decode. But add a named constant:

```python
SPECTRUM_CLASS_GENOMIC_READ = 5
```

The **AU fixed-prefix layout** currently has spectral-specific fields
(retention_time, precursor_mz, ion_mobility, etc.) that don't apply
to genomic reads. For M73, genomic AUs reuse the same 38-byte prefix
with genomic-appropriate values:

- `retention_time` → 0.0 (unused for genomic)
- `precursor_mz` → 0.0 (unused)
- `precursor_charge` → 0 (unused)
- `ion_mobility` → 0.0 (unused)
- `base_peak_intensity` → 0.0 (unused)

The genomic-specific prefix (chromosome, position, mapq, flags)
arrives in M82 as an AU payload extension. M73 just ensures the
codec doesn't crash on `spectrum_class=5`.

### 2b. ObjC — `objc/Source/Transport/MPGOAccessUnit.h`

Update the doc comment for `spectrumClass`:

```objc
 *   0 = MassSpectrum, 1 = NMRSpectrum, 2 = NMR2D,
 *   3 = FID, 4 = MSImagePixel, 5 = GenomicRead
```

No encode/decode changes — the wire format is already generic.

### 2c. Java — `java/src/main/java/com/dtwthalion/mpgo/transport/AccessUnit.java`

Same doc comment update. No code changes.

---

## 3. Feature Flag

### 3a. `docs/feature-flags.md`

Add to the registry table:

```markdown
| `opt_genomic` | v0.11 M73 | Genomic sequencing data present. Readers
  that don't support genomic runs should skip them gracefully. |
```

### 3b. Python — feature flag emission

In `mpeg_o/spectral_dataset.py` (or wherever `mpeg_o_features` JSON
array is written), the `opt_genomic` flag should be added when any
run in the dataset has `modality == "genomic_sequencing"`. This is
wired in M74 when `GenomicRun.write_to_group()` is implemented;
for M73, just ensure the feature-flag machinery can handle the
string.

---

## 4. Modality Attribute Convention

### 4a. Binding decision 60

`modality` is a **UTF-8 string attribute** on each run group, not an
enum integer. Values: `"mass_spectrometry"`, `"nmr"`,
`"genomic_sequencing"`. Default when absent: `"mass_spectrometry"`.

### 4b. AcquisitionRun backward compat

In `AcquisitionRun.open()` (Python, ObjC, Java), when reading an
existing run group:

```python
modality = read_string_attr(group, "modality", default="mass_spectrometry")
```

No error if the attribute is missing — old files written before
v0.11 simply don't have it. The run proceeds as a mass-spec run.

For M73, don't add `modality` to `AcquisitionRun.write_to_group()`
yet — that comes in M74 when `GenomicRun` ships. M73 only adds the
read-side handling so existing code doesn't break when it encounters
the attribute written by future versions.

---

## 5. `_ELEMENT_SIZE` / `element_size()` Updates

**Python `encoding_spec.py`:**

```python
_ELEMENT_SIZE: dict[Precision, int] = {
    ...existing...
    Precision.UINT8: 1,
}
```

**ObjC `MPGOEncodingSpec.m`:** Add `case MPGOPrecisionUInt8: return 1;`
to `-elementSize`.

**Java `Enums.java`:** Already handled — `UINT8(1)` in the enum
constructor.

---

## 6. Tests

### 6a. Python — `python/tests/test_m73_genomic_enums.py`

New test file. Contents:

1. **UINT8 provider round-trip** — for each provider (HDF5, Memory,
   SQLite, Zarr): create a 1000-element UINT8 dataset with values
   0–255 (repeating). Write, close, reopen, read. Assert byte-exact
   match.

2. **UINT8 partial read** — write 1000 UINT8 elements, read slice
   [500:600], verify.

3. **Compression enum persistence** — write an HDF5 attribute with
   value `Compression.RANS_ORDER0.value` (= 4), read back, assert
   `== 4`. Repeat for all five new values (4–8).

4. **AcquisitionMode enum values** — assert `AcquisitionMode.GENOMIC_WGS == 7`
   and `AcquisitionMode.GENOMIC_WES == 8`.

5. **Transport spectrum_class=5** — construct an `AccessUnit` with
   `spectrum_class=5`, encode to bytes, decode, assert all fields
   survive. Channels should be empty list (no signal data in this
   test — M74 adds real channels).

6. **Modality attribute backward compat** — create a v0.10-style
   .mpgo file (no modality attribute on run groups). Open with
   v0.11 code. Assert `modality` defaults to `"mass_spectrometry"`.

7. **Modality attribute explicit** — write a run group with
   `@modality = "genomic_sequencing"`. Read back. Assert value.

### 6b. ObjC — add to existing test runner

Add a `TestMilestone73` section in `objc/Tests/MPGOTestRunner.m`:

1. UINT8 dataset round-trip via `MPGOHDF5Provider`.
2. UINT8 dataset round-trip via `MPGOMemoryProvider`.
3. `MPGOPrecisionUInt8` element size == 1.
4. New compression enum values exist and have expected integer values.
5. Transport `MPGOAccessUnit` with `spectrumClass=5` round-trip.
6. Modality attribute read with default.

### 6c. Java — `java/src/test/java/com/dtwthalion/mpgo/M73GenomicEnumsTest.java`

1. UINT8 round-trip on Hdf5Provider.
2. UINT8 round-trip on MemoryProvider.
3. Compression ordinal values: `RANS_ORDER0.ordinal() == 4`, etc.
4. AcquisitionMode ordinal values: `GENOMIC_WGS.ordinal() == 7`.
5. Transport AccessUnit with spectrumClass=5 round-trip.

---

## 7. Documentation

### 7a. `docs/format-spec.md`

Add a new §10 stub:

```markdown
## §10 Genomic Container Layout (v0.11, `opt_genomic`)

_Full specification in M74. This section reserved._

### §10.1 Modality attribute

Each run group MAY carry a `@modality` UTF-8 string attribute:

| Value | Meaning |
|---|---|
| `"mass_spectrometry"` | Default. MS runs. |
| `"nmr"` | NMR spectroscopy runs. |
| `"genomic_sequencing"` | Aligned genomic sequencing reads. |

Files without the attribute are treated as `"mass_spectrometry"`.
```

### 7b. `WORKPLAN.md`

Append the v0.11 genomic integration workplan block (the
`WORKPLAN-GENOMICS.md` content) at the end of the existing
WORKPLAN.md.

### 7c. `CHANGELOG.md`

Add a v0.11.0 section (unreleased) with M73 entries.

---

## 8. Gotchas

59. **Enum ordinal stability.** The integer values of `Precision`,
    `Compression`, and `AcquisitionMode` are persisted on disk as
    HDF5 integer attributes. Once shipped, values cannot be reordered
    or renumbered without breaking backward compatibility. The new
    values (UINT8=6, RANS_ORDER0=4, etc.) are append-only and
    must match across all three languages.

60. **Java `Precision` switch exhaustiveness.** Java `switch`
    statements on `Precision` in `Hdf5Provider`, `MemoryProvider`,
    `SqliteProvider`, `ZarrProvider`, and `Hdf5Group.hdf5TypeFor()`
    may fail to compile if they use `->` (arrow) syntax with no
    `default` branch and the enum gains a new constant. Search for
    `switch.*Precision` across the Java source and add `UINT8` to
    every exhaustive switch, or add a `default` throwing
    `UnsupportedOperationException`.

61. **ObjC `elementSize` default return.** The `MPGOEncodingSpec`
    `-elementSize` method has a trailing `return 0;` after the
    switch. Adding `MPGOPrecisionUInt8` to the switch is sufficient;
    the default-zero fallthrough is safe but log a warning if you
    prefer.

62. **Python Compression gap.** Note that `RANS_ORDER0 = 4` (not 5)
    because `NUMPRESS_DELTA = 3` and we're incrementing sequentially.
    The WORKPLAN-GENOMICS.md originally said values 5–9; the
    authoritative values are in this HANDOFF (4–8). Update
    WORKPLAN-GENOMICS.md if needed.

63. **Zarr provider dtype mapping.** The `_DTYPE_TO_PRECISION` dict
    in `zarr.py` maps numpy dtype *names* (e.g., `"float64"`) to
    Precision values. Add `"uint8": Precision.UINT8`. The inverse
    mapping in `_precision_to_dtype` (if it exists) also needs the
    entry.

---

## Acceptance Criteria

- [ ] All existing tests pass (zero regressions).
- [ ] `Precision.UINT8` round-trips through all four Python providers
      (HDF5, Memory, SQLite, Zarr). Write 1000 values, read back,
      byte-exact match.
- [ ] `Precision.UINT8` round-trips through ObjC HDF5 + Memory
      providers.
- [ ] `Precision.UINT8` round-trips through Java HDF5 + Memory
      providers.
- [ ] `Compression` enum values 4–8 persist as HDF5 integer
      attributes and survive round-trip in all three languages.
- [ ] `AcquisitionMode.GENOMIC_WGS` == 7,
      `AcquisitionMode.GENOMIC_WES` == 8 in all three languages.
- [ ] Transport `AccessUnit` with `spectrum_class=5` encodes and
      decodes without error in all three languages.
- [ ] Existing v0.10 `.mpgo` files open without error; `modality`
      attribute absent → default `"mass_spectrometry"`.
- [ ] `@modality = "genomic_sequencing"` persists and reads back
      correctly.
- [ ] `docs/format-spec.md` §10 stub committed.
- [ ] `docs/feature-flags.md` updated with `opt_genomic`.
- [ ] CI green across all three languages.

---

## Binding Decisions

| # | Decision | Rationale |
|---|---|---|
| 60 | `modality` is a UTF-8 string attribute, not an enum integer. | Extensible for future modalities (transcriptomics, epigenomics) without enum-value coordination. |
| 62 (clarified) | Compression enum: RANS_ORDER0=4, RANS_ORDER1=5, BASE_PACK=6, QUALITY_BINNED=7, NAME_TOKENIZED=8. | Sequential after NUMPRESS_DELTA=3. Values are on-disk integers — immutable once shipped. |
