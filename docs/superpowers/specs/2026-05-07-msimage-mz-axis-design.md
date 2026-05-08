# MSImage `mz_axis` cross-language parity — design

**Status:** Approved (2026-05-07)
**Authors:** Todd White + Claude
**Library version target:** `global.thalion:ttio` 1.1.0 → 1.2.0 (additive minor)
**Motivation PR:** unblocks imzML export in [tio-browser PR #29](https://github.com/DTW-Thalion/TTI-O/pull/29)

---

## Problem

`MSImage` represents a 3-D imaging-mass-spectrometry intensity cube but stores
**only** the cube — no spectral (m/z) axis. Sister class `RamanImage` already
carries a `wavenumbers` axis (Java + Python). The omission means an `MSImage`
read out of a `.tio` cannot be re-projected into the per-pixel `(mz, intensity)`
records that `ImzMLWriter.write` requires, so the imzML row in tio-browser's
Phase 9 export dialog is wired as a stub raising
`UnsupportedOperationException("not yet wired")`.

Closing this gap requires:

1. A persisted m/z axis on `MSImage` in all three reference languages.
2. An `MSImage → List<PixelSpectrum>` bridge usable by `ImzMLWriter.write`.
3. An `SpectralDataset.image()` accessor (currently absent — `MSImage` is read
   directly from a `StorageGroup` in Java and Python, bypassing the dataset
   wrapper).

## Non-goals

- Removing the ObjC `TTIOMSImage : TTIOSpectralDataset` subclass relationship.
  ObjC keeps its inheritance pattern; Java and Python keep composition. The
  asymmetry is documented in existing class doc-comments. A future ObjC
  composition refactor would also need to address `TTIORamanImage` — out of
  scope here.
- Adding HDF5 persistence to Python `RamanImage`. Today Python `RamanImage`
  is a value class without I/O, mirroring the pre-fix Python `MSImage` state.
  The same composition pattern this spec installs for `MSImage` will apply
  when Raman is fixed, but it is deferred (no current consumer).
- Migrating legacy `.tio` files. v1.1.x files without `mz_axis` remain
  readable; the imzML exporter raises a clear error when the axis is absent,
  pointing the caller at a re-import workflow.
- Changing the imzML import path. Today the Python imzml importer materialises
  pixels as a regular MS run with `(mz, intensity)` channel arrays plus
  provenance-encoded coordinates. That path is orthogonal to `MSImage` and
  remains as-is.

---

## Storage layout

One additive 1-D dataset under the existing `/study/image_cube/` group. No
new attributes, no new feature flag.

```
/study/image_cube/
├── @width             (int64 attr)        existing
├── @height            (int64 attr)        existing
├── @spectral_points   (int64 attr)        existing
├── @tile_size         (int64 attr)        existing (ObjC only)
├── @pixel_size_x      (double attr)       existing
├── @pixel_size_y      (double attr)       existing
├── @scan_pattern      (string attr)       existing
├── intensity          (FLOAT64, [h,w,sp]) existing — 3-D row-major
└── mz_axis            (FLOAT64, [sp])     NEW — 1-D shared m/z axis
```

**Decisions:**

- `mz_axis` is a **dataset, not an attribute.** Large arrays don't belong in
  HDF5 attributes (64KB ceiling). Mirrors how `RamanImage` stores
  `wavenumbers`.
- Precision: `FLOAT64` little-endian — same as `intensity`.
- Length when present: MUST equal `@spectral_points`. Validated on read.
- Length when absent (legacy files): zero — readers report empty axis.
- Compression: ZLIB level 6, single-chunk (`chunks=[sp]`) — same as `intensity`.
- No feature flag — presence-or-absence of the dataset is the signal. This
  matches `RamanImage.wavenumbers` precedent. The existing
  `OPT_NATIVE_MSIMAGE_CUBE` flag already governs the cube as a whole.

**Forward-compat for v1.1.x readers:** an unknown `mz_axis` dataset is silently
ignored by HDF5's open schema. v1.1.x readers continue to round-trip a
v1.2.0-written file (minus the new axis) without errors.

---

## API surface

### Java (`global.thalion.ttio.MSImage`)

```java
private final double[] mzAxis;  // length 0 (legacy) or == spectralPoints

// New designated 15-arg ctor; both existing ctors delegate with mzAxis = new double[0].
public MSImage(int width, int height, int spectralPoints, int tileSize,
               double pixelSizeX, double pixelSizeY, String scanPattern,
               double[] intensityCube, double[] mzAxis,
               String title, String isaInvestigationId,
               List<Identification> identifications,
               List<Quantification> quantifications,
               List<ProvenanceRecord> provenanceRecords);

public double[] mzAxis() { return mzAxis; }

/** Materialise this image as a continuous-mode pixel list for ImzMLWriter.
 *  Throws IllegalStateException when mzAxis is empty. */
public List<global.thalion.ttio.importers.ImzMLReader.PixelSpectrum> toPixelSpectra();
```

`writeTo(StorageGroup)` writes a `mz_axis` 1-D dataset when
`mzAxis.length > 0`. `readFrom(StorageGroup)` opens `mz_axis` if present;
otherwise returns the existing constructor with `mzAxis = new double[0]`.

**`SpectralDataset.image()` accessor** (NEW, lazy, cached):

```java
/** The embedded MSImage if this dataset has a /study/image_cube group; null otherwise. */
public MSImage image();
```

Pattern mirrors `references()` from Phase 0 of the tio-browser plan.

### Python (`ttio.ms_image.MSImage`)

```python
@dataclass(slots=True)
class MSImage:
    # ... existing fields ...
    mz_axis: np.ndarray = field(default_factory=lambda: np.zeros(0))

    def __post_init__(self) -> None:
        # ... existing validations ...
        if self.mz_axis.size > 0:
            if self.mz_axis.ndim != 1 or self.mz_axis.shape[0] != self.spectral_points:
                raise ValueError(
                    f"mz_axis shape {self.mz_axis.shape} does not match "
                    f"spectral_points={self.spectral_points}")

    def write_to(self, study_group: StorageGroup) -> None: ...
    @classmethod
    def read_from(cls, study_group: StorageGroup) -> "MSImage | None": ...
    def to_pixel_spectra(self) -> list[ImzMLPixelSpectrum]: ...
```

**High-level kwarg on `SpectralDataset.write_minimal`:**

```python
SpectralDataset.write_minimal(path, ..., image: MSImage | None = None)
```

When `image` is non-`None`, the writer calls `image.write_to(study_group)`
after the runs are written but before close.

**Open-side accessor:**

```python
class SpectralDataset:
    @property
    def image(self) -> "MSImage | None": ...   # lazy, cached
```

### Objective-C (`TTIOMSImage`)

Subclass relationship `TTIOMSImage : TTIOSpectralDataset` preserved.

```objc
@interface TTIOMSImage : TTIOSpectralDataset

/** Length-spectralPoints float64 array; nil for legacy files. */
@property (readonly, copy) NSData *mzAxis;

// New designated initialiser with mzAxis: parameter; existing 5-arg + 13-arg
// initialisers delegate with mzAxis = nil.
- (instancetype)initWithTitle:(NSString *)title
           isaInvestigationId:(NSString *)isaId
              identifications:(NSArray *)identifications
              quantifications:(NSArray *)quantifications
            provenanceRecords:(NSArray *)provenance
                        width:(NSUInteger)width
                       height:(NSUInteger)height
               spectralPoints:(NSUInteger)spectralPoints
                     tileSize:(NSUInteger)tileSize
                   pixelSizeX:(double)pixelSizeX
                   pixelSizeY:(double)pixelSizeY
                  scanPattern:(NSString *)scanPattern
                         cube:(NSData *)cube
                       mzAxis:(nullable NSData *)mzAxis;

/** List of TTIOPixelSpectrum value objects (continuous mode).
 *  Raises NSInternalInconsistencyException when mzAxis is nil. */
- (NSArray<TTIOPixelSpectrum *> *)pixelSpectra;

@end
```

`-writeAdditionalStudyContent:` extended to write `mz_axis` dataset when
`_mzAxis != nil && _mzAxis.length > 0`. `-readAdditionalStudyContent:` opens
the dataset if present; populates field; otherwise leaves `_mzAxis = nil`.

**New value class** `TTIOPixelSpectrum` (`objc/Source/Image/TTIOPixelSpectrum.{h,m}`):

```objc
@interface TTIOPixelSpectrum : NSObject
@property (readonly) NSUInteger x;
@property (readonly) NSUInteger y;
@property (readonly) NSUInteger z;
@property (readonly, copy) NSData *mz;          // float64
@property (readonly, copy) NSData *intensity;   // float64
@end
```

**`TTIOSpectralDataset` accessor:**

```objc
@interface TTIOSpectralDataset (Image)
@property (readonly, nullable) TTIOMSImage *msImage;
@end
```

For a `.tio` file opened as plain `TTIOSpectralDataset`, the property
materialises an MSImage via `+readFromFilePath:` if the file carries a
`/study/image_cube` group. For an open `TTIOMSImage` instance, returns `self`
(the subclass relationship makes this trivial).

---

## Backwards compatibility & error handling

### Reading legacy v1.1.x files (no `mz_axis` dataset)

| Lang | `mzAxis` value |
|---|---|
| Java | `new double[0]` |
| Python | `np.zeros(0)` |
| ObjC | `nil` |

No errors, no warnings — legacy files Just Work for everything except imzML
export.

### Writing

- If the axis is non-empty, persist the 1-D dataset.
- If the axis is empty, omit the dataset entirely (no zero-length stub).
- Validation at construction time: when non-empty, the axis length MUST
  equal `spectralPoints`. Otherwise raise `IllegalArgumentException` /
  `ValueError` / `NSInvalidArgumentException`.

### imzML exporter contract

`MSImage.toPixelSpectra()` (Java/ObjC) / `to_pixel_spectra()` (Python) raises
when the axis is empty:

> `MSImage has no mz_axis; cannot project to imzML pixels. The .tio was`
> `written before format v1.2 added the spectral axis. Re-import from a`
> `source format that carries m/z calibration (imzML, mzML), or supply`
> `mz_axis explicitly.`

This bubbles cleanly through `ExportTask.exportImzML()` and surfaces in the
tio-browser dialog as a standard failure alert.

### Round-trip guarantees

- A `.tio` written by ttio v1.2.0 with a populated `mz_axis` round-trips
  byte-equal through Java, Python, and ObjC readers (cross-language conformance
  test, below).
- A `.tio` written by v1.1.x is readable by v1.2.0 (legacy → empty axis).
- A v1.1.x reader silently ignores a v1.2.0-written `mz_axis` dataset — no
  errors, just no axis access.

---

## Testing strategy

### Per-language unit tests (TDD)

| Language | Test class | Assertions |
|---|---|---|
| Java | `MSImageMzAxisTest.java` (new) | write+read round-trip; legacy file (no `mz_axis`) returns empty; ctor validation rejects mismatched length; `toPixelSpectra()` happy path + empty-axis raises |
| Python | `tests/test_ms_image_mz_axis.py` (new) | same matrix using HDF5 provider via `open_provider` |
| ObjC | `Tests/TestMSImageMzAxis.m` (new) | same matrix via `+writeToFilePath:` / `+readFromFilePath:` |

### Cross-language conformance test

`python/tests/conformance/test_msimage_xlang.py` (new):

1. Python writes a synthesized `MSImage` (4×3 grid, 8 spectral points,
   `mz_axis = np.linspace(100.0, 1000.0, 8)`, intensity = deterministic ramp)
   via `MSImage.write_to()`.
2. Test invokes Java reader (`mvn exec:java
   -Dexec.mainClass=global.thalion.ttio.tools.MSImageReadDump`) and ObjC reader
   (`./ms_image_read_dump <path>`) as subprocesses, each emitting `mz_axis`
   bytes (8 × 8 = 64 bytes) to stdout.
3. Asserts byte-equality of the 64-byte payload across all three languages.

Pattern follows `python/tests/conformance/test_references_xlang.py` from
Phase 0 of the tio-browser plan.

### `SpectralDataset` accessor tests

| Language | Test |
|---|---|
| Java | `SpectralDatasetTest.imageAccessorReturnsMaterialisedMSImage` + `imageAccessorReturnsNullWhenAbsent` |
| Python | equivalent in `test_spectral_dataset.py` |
| ObjC | extension of `Tests/TestMilestone12.m` covering the new `msImage` property |

### tio-browser side (separate PR, after library merge)

- Bump `<ttio.version>` from `1.1.0` to `1.2.0` in `tio-browser/pom.xml`.
- Replace the `imzML` stub in `ExportTask.exportImzML()` with a call to
  `dataset.image().toPixelSpectra()` followed by `ImzMLWriter.write(...)`.
- Add an `imzML` round-trip test: synthesize an `MSImage`-bearing `.tio` in
  test setup → export to imzML via `ExportTask` → re-import via Phase 8's
  `ImportTask` → assert `mz_axis` and `intensity` byte-equal.
- Confirm `MS_IMAGE_PRESENT` eligibility flips correctly given the synthesized
  fixture.

### Native library gate

None. `MSImage` doesn't touch `libttio_rans` (no codecs involved); these tests
run cleanly without the JNI library on `LD_LIBRARY_PATH`.

---

## Version bump

`global.thalion:ttio` 1.1.0 → 1.2.0 (additive minor — new optional field +
new accessor; no wire-breaking change). Bumped in:

- `java/pom.xml` (`<version>1.2.0</version>`)
- `python/pyproject.toml` (`version = "1.2.0"`)
- `objc/Source/TTIOVersion.h` (or equivalent version constant)
- `WORKPLAN.md` / `CHANGELOG.md` entry under `[1.2.0]`

`format_version` attribute in the file header stays at `"1.0"` — the wire
format is additive, not breaking, and v1.0 readers transparently skip the
unknown dataset.

---

## PR sequencing

1. **Library PR** (this spec) — branch `msimage-mz-axis`, off `main`. Lands
   the schema + 3-language API + conformance test + version bump.
2. **tio-browser update on PR #29** — after library merge, rebase the
   `phase-9-export-dialog` branch onto `main`, bump `<ttio.version>` to
   `1.2.0`, replace imzML stub, add round-trip test, push update to PR #29.

---

## Out-of-scope follow-ups (tracked for later)

- Python `RamanImage` HDF5 persistence (currently a pure value class).
  Same composition pattern this spec installs for `MSImage` applies.
- ObjC composition refactor (drop `TTIOMSImage : TTIOSpectralDataset` and
  `TTIORamanImage : TTIOSpectralDataset` subclass relationships in favour of
  matching Java/Python). Worth doing eventually for strict cross-language
  parity, but separate from closing the imzML gap.
- Higher-level `MSImage.toPixelSpectra()` modes — currently only continuous
  mode (one shared `mz_axis`) is supported. Processed mode (per-pixel
  variable-length axes) would need a different storage layout and isn't
  required by current `ImzMLWriter` use cases.
