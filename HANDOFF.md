# MPEG-O v0.3 — Continuation Session Prompt

> **Status:** v0.2.0 is **complete** (656 tests passing in CI). This
> session executes **Milestones 16–22** to produce the **v0.3.0**
> release. The headline deliverable is the **Python `mpeg-o` package**.

---

## First Steps on This Machine

1. Clone or pull the repo:
   ```bash
   git clone https://github.com/DTW-Thalion/MPEG-O.git
   cd MPEG-O && git pull
   ```

2. **Read these files in full** — they are the source of truth:
   - `README.md`, `ARCHITECTURE.md`, `WORKPLAN.md`
   - `docs/format-spec.md` — the normative HDF5 layout (Python must match this exactly)
   - `docs/feature-flags.md` — feature registry with reserved v0.3 flags
   - `objc/Tests/Fixtures/mpgo/` — reference `.mpgo` fixtures for cross-compat testing
   - `objc/Source/Import/` — mzML/nmrML readers (Python equivalents needed)
   - `.github/workflows/ci.yml` — current CI (ObjC only; Python job to be added)

3. **Verify ObjC build:** `cd objc && ./build.sh check` → must show 656 tests passing

4. **Tag v0.2.0** if not already tagged:
   ```bash
   git tag -a v0.2.0 -m "MPEG-O v0.2.0: mzML/nmrML import, modality-agnostic runs, compound HDF5 types, digital signatures, formal versioning"
   git push origin v0.2.0
   ```

---

## What v0.2.0 Delivered

- **M1–M8 (v0.1.0-alpha):** Six primitives, HDF5 container, signal channels, spectrum index, query, streaming, AES-256-GCM encryption. 379 tests.
- **M9:** mzML reader — SAX parser, base64+zlib, `MPGOCVTermMapper`, real HUPO-PSI fixtures.
- **M10:** Protocol conformance — modality-agnostic runs (MS+NMR), per-run provenance via `@provenance_json`, `MPGOEncryptable` on runs.
- **M11:** Native HDF5 compound types — `MPGOHDF5CompoundType`, `MPGOFeatureFlags` (`@mpeg_o_format_version = "1.1"`), `MPGOCompoundIO`, dataset-level encryption, v0.1 JSON fallback.
- **M12:** MSImage inherits `MPGOSpectralDataset`, native rank-2 NMR datasets with dimension scales, `opt_native_2d_nmr` flag.
- **M13:** nmrML reader — real BMRB fixture (`bmse000325.nmrML`), 16384-sample FID.
- **M14:** Digital signatures — HMAC-SHA256, `MPGOVerifier`, provenance chain signing, `opt_digital_signatures` flag. Sign ~9ms / verify ~5ms.
- **M15:** Format spec, feature-flags doc, 5 reference fixtures, fixture generator tool.

### Known v0.2 Limitations to Resolve in v0.3

1. **Per-run provenance uses `@provenance_json` string attribute** instead of compound dataset. Reserved flag: `compound_per_run_provenance`.
2. **Signatures cover native-endian bytes** — not portable across architectures. Reserved flag: `opt_canonical_signatures`.
3. **No mzML export** — import only.
4. **No Python implementation** — `python/README.md` is a stub.
5. **No cloud-native access.**
6. **Only zlib compression** — no LZ4 or Numpress.

---

## Binding Decisions — Do Not Override

### From v0.1 + v0.2 sessions

1. **Milestone-by-milestone checkpoints.** Complete N, commit, CI green, pause for user review. Do not chain milestones.
2. **Clang-only for ObjC.** ARC required; `build.sh` enforces `CC=clang OBJC=clang`.
3. **Immutable value classes** return `self` from `-copyWithZone:`.
4. **No thread safety until v0.4.** Document as "not thread-safe."
5. **CRLF/LF via `.gitattributes`.** Do not modify.
6. **Shell scripts need executable bit.** `git update-index --chmod=+x`.
7. **HDF5 via C API** with thin ObjC wrappers. Check returns. Close `hid_t`.
8. **`.mpgo` extension.** Internally valid HDF5.
9. **`NSError **` out-params.** Never throw for expected errors.
10. **Test isolation.** Temp files in `/tmp/mpgo_test_*`, cleaned after.
11. **Commit discipline.** One commit per milestone, `Co-Authored-By` trailer.
12. **CI must be green** before any milestone is complete.
13. **ARC on libMPGO, MRC on test harness.** Preserve the split.
14. **Apache-2.0 on import/export layer.** Core stays LGPL-3.0.

### From v0.3 planning session

15. **PyPI package name: `mpeg-o`** (import as `mpeg_o`).
16. **Python 3.11+ minimum.** Enables `StrEnum`, better typing (`Self`).
17. **Cloud access via `fsspec`** for multi-cloud abstraction.
18. **Numpress: clean-room implementation** from Teleman et al., *MCP* 13(6), 2014.
19. **Thread safety deferred to v0.4.** No concurrency work in v0.3.

---

## Milestone Dependency Graph

```
  Milestone 16 (Python core reader/writer)
       |
       +--------------------+----------------------+
       v                    v                      v
  Milestone 17         Milestone 18           Milestone 20
  (Compound provenance) (Canonical sigs)      (Cloud-native)
       |                    |                      |
       +--------+-----------+                      |
                v                                  |
           Milestone 19                            |
           (mzML writer)                           |
                |                                  |
                v                                  |
           Milestone 21                            |
           (LZ4 + Numpress)                        |
                |                                  |
                +--------------+-------------------+
                               v
                        Milestone 22
                        (v0.3.0 release)
```

M16 is the critical path. M17+M18 (ObjC) can start in parallel. M20 (cloud) depends on M16 but is otherwise independent.

---

## Milestone 16 — Python Package: Core Reader/Writer

**Track:** Python stream
**License:** LGPL-3.0 (core), Apache-2.0 (`importers/`, `exporters/`)

### Package structure

```
python/
+-- pyproject.toml
+-- src/mpeg_o/
|   +-- __init__.py             # Public API surface
|   +-- enums.py                # Precision, Compression, Polarity, SamplingMode (StrEnum)
|   +-- value_range.py          # ValueRange (frozen dataclass)
|   +-- cv_param.py             # CVParam (frozen dataclass)
|   +-- axis_descriptor.py      # AxisDescriptor (frozen dataclass)
|   +-- encoding_spec.py        # EncodingSpec (frozen dataclass)
|   +-- signal_array.py         # SignalArray <-> numpy.ndarray
|   +-- spectrum.py             # Spectrum base class
|   +-- mass_spectrum.py        # MassSpectrum
|   +-- nmr_spectrum.py         # NMRSpectrum
|   +-- nmr_2d.py               # NMR2DSpectrum (native 2D h5py dataset)
|   +-- fid.py                  # FreeInductionDecay
|   +-- chromatogram.py         # Chromatogram
|   +-- acquisition_run.py      # AcquisitionRun + SpectrumIndex
|   +-- instrument_config.py    # InstrumentConfig (frozen dataclass)
|   +-- spectral_dataset.py     # SpectralDataset -- root .mpgo reader/writer
|   +-- ms_image.py             # MSImage (SpectralDataset subclass)
|   +-- identification.py       # Identification
|   +-- quantification.py       # Quantification
|   +-- provenance.py           # ProvenanceRecord
|   +-- transition_list.py      # TransitionList
|   +-- feature_flags.py        # FeatureFlags reader/writer
|   +-- encryption.py           # AES-256-GCM via cryptography library
|   +-- signatures.py           # HMAC-SHA256 sign/verify
|   +-- _hdf5_io.py             # Internal h5py helpers
+-- src/mpeg_o/importers/       # Apache-2.0
|   +-- __init__.py
|   +-- mzml.py                 # mzML reader (xml.etree.ElementTree)
|   +-- nmrml.py                # nmrML reader
|   +-- cv_term_mapper.py       # PSI-MS + nmrCV accession mappings
+-- src/mpeg_o/exporters/       # Apache-2.0 (placeholder for M19)
|   +-- __init__.py
+-- tests/
    +-- conftest.py              # pytest fixtures, tmp_path, ObjC fixture paths
    +-- test_value_classes.py
    +-- test_signal_array.py
    +-- test_spectrum.py
    +-- test_mass_spectrum.py
    +-- test_nmr_spectrum.py
    +-- test_nmr_2d.py
    +-- test_fid.py
    +-- test_chromatogram.py
    +-- test_acquisition_run.py
    +-- test_spectral_dataset.py
    +-- test_ms_image.py
    +-- test_identification.py
    +-- test_provenance.py
    +-- test_feature_flags.py
    +-- test_encryption.py
    +-- test_signatures.py
    +-- test_mzml_reader.py
    +-- test_nmrml_reader.py
    +-- test_cross_compat.py     # THE critical test -- ObjC <-> Python interop
```

### pyproject.toml

```toml
[build-system]
requires = ["hatchling"]
build-backend = "hatchling.build"

[project]
name = "mpeg-o"
version = "0.3.0a1"
description = "Python reader/writer for the MPEG-O multi-omics data standard"
requires-python = ">=3.11"
license = {text = "LGPL-3.0-or-later"}
dependencies = [
    "h5py>=3.0",
    "numpy>=1.24",
]

[project.optional-dependencies]
crypto = ["cryptography>=41.0"]
import = ["lxml"]
cloud = ["fsspec", "s3fs", "aiohttp"]
test = ["pytest>=7", "cryptography>=41.0", "lxml"]
all = ["mpeg-o[crypto,import,cloud]"]

[tool.hatch.build.targets.wheel]
packages = ["src/mpeg_o"]
```

### Design idioms

- **Frozen dataclasses** for value types: `CVParam`, `AxisDescriptor`, `EncodingSpec`, `ValueRange`, `InstrumentConfig`
- **`StrEnum`** for all enums (Python 3.11+):
  ```python
  class Precision(StrEnum):
      FLOAT32 = "float32"
      FLOAT64 = "float64"
      INT32 = "int32"
      COMPLEX128 = "complex128"
  ```
- **`numpy.ndarray`** as signal buffer: `SignalArray.data` is numpy; `SignalArray.from_numpy(arr, axis=..., encoding=...)` constructs
- **Context managers** for file handles:
  ```python
  with SpectralDataset.open("file.mpgo") as ds:
      run = ds.ms_runs["run_0001"]
      spectrum = run[0]
      mz = spectrum.mz_array.data  # numpy array
  ```
- **Lazy loading:** `AcquisitionRun` reads spectrum index on open, loads signal data only on access
- **Type hints** throughout; `py.typed` marker for PEP 561
- **Pure Pythonic API:** no ObjC patterns, no NSData, no NSArray

### HDF5 I/O layer (`_hdf5_io.py`)

Critical bridge — must produce HDF5 files byte-compatible with ObjC implementation. Key functions:

```python
def write_signal_channel(group, name, data, chunk_size=16384,
                         compression="gzip", compression_level=6):
    """Write a 1-D signal channel with chunking and compression."""

def read_signal_channel(group, name):
    """Read a signal channel, handling compressed and uncompressed."""

def write_compound_dataset(group, name, records, fields):
    """Write compound dataset. fields=[(name, h5py_type), ...].
    VL strings use h5py.string_dtype()."""

def read_compound_dataset(group, name):
    """Read compound dataset into list of dicts."""

def write_feature_flags(root, version, features):
    """Write @mpeg_o_format_version and @mpeg_o_features."""

def read_feature_flags(root):
    """Read version + features. Returns ("1.0.0", []) for v0.1."""

def is_legacy_v1(root):
    """True if no @mpeg_o_features attribute."""
```

### SpectralDataset reader logic

`SpectralDataset.open(path)` must handle:

1. Open via `h5py.File(path, "r")`
2. Read `@mpeg_o_format_version` + `@mpeg_o_features` (or detect v0.1 legacy)
3. Navigate `/study/` group
4. For each `ms_runs/run_NNNN/`:
   - Read `spectrum_index/` (offsets, lengths, headers)
   - Lazily defer signal channel reads
   - Read `instrument_config/` attributes
   - Read `provenance/` (compound dataset or `@provenance_json` fallback)
5. Read `/study/identifications` (compound or `@identifications_json`)
6. Read `/study/quantifications` (compound or `@quantifications_json`)
7. Read `/study/provenance/` (dataset-level)
8. Detect NMR runs, MSImage cube, 2D NMR datasets
9. Check encryption markers (`@encrypted`), signatures

### Cross-implementation contract

**The most important acceptance criterion in v0.3.** `test_cross_compat.py` does:
1. For each fixture in `objc/Tests/Fixtures/mpgo/`: open with Python, verify spectrum counts, array values (float64 epsilon), identifications, quantifications, feature flags
2. Write a test dataset from Python to temp `.mpgo`
3. Verify field-by-field against known expected values (or run ObjC verifier)

### mzML and nmrML importers

Port ObjC SAX parsers to Python using `xml.etree.ElementTree`:
- `mpeg_o.importers.mzml.read(path) -> SpectralDataset`
- `mpeg_o.importers.nmrml.read(path) -> SpectralDataset`
- `cv_term_mapper.py` — same hardcoded PSI-MS and nmrCV mappings as ObjC
- Base64: `base64.b64decode()` + `zlib.decompress()` from stdlib
- Handle `referenceableParamGroup` expansion, `defaultArrayLength` validation

### Encryption and signatures

- `mpeg_o.encryption`: `cryptography` library for AES-256-GCM (`AESGCM`)
- `mpeg_o.signatures`: `hmac` + `hashlib` from stdlib for HMAC-SHA256
- Must produce identical ciphertext/MAC as ObjC for same key and data

### Acceptance criteria

- [ ] `pip install -e ".[test]"` succeeds on Python 3.11, 3.12
- [ ] Read every ObjC reference fixture -- all values match
- [ ] Write -> read in Python round-trip verified
- [ ] Write from Python -> compare against known expected values
- [ ] Read ObjC-encrypted .mpgo -> decrypt -> values match
- [ ] Read ObjC-signed .mpgo -> verify -> Valid
- [ ] Feature flags identical to ObjC
- [ ] mzML import: synthetic + HUPO-PSI fixtures, round-trip
- [ ] nmrML import: synthetic + BMRB fixture, round-trip
- [ ] `pytest` 100% green

### Commit message

```
Milestone 16: Python mpeg-o package -- core reader/writer + importers

- Full reader/writer for .mpgo files via h5py
- Value classes as frozen dataclasses with StrEnum
- Lazy-loading AcquisitionRun with SpectrumIndex
- mzML and nmrML importers (Apache-2.0)
- AES-256-GCM encryption and HMAC-SHA256 signatures
- Cross-implementation tests against ObjC reference fixtures
- pyproject.toml with hatchling build, Python 3.11+
```

---

## Milestone 17 — Compound Per-Run Provenance (Objective-C)

**Track:** ObjC hardening | **License:** LGPL-3.0

### Deliverables

- Migrate per-run provenance from `@provenance_json` to compound dataset at `/study/ms_runs/run_NNNN/provenance/steps`
- Same compound type as dataset-level provenance
- Reader detects `@provenance_json` (v0.2) vs compound (v0.3)
- `compound_per_run_provenance` feature flag
- Deprecate `@provenance_json` with `MPGO_DEPRECATED_MSG`
- Python reader (M16) handles both layouts

### Acceptance criteria

- [ ] New files use compound provenance per run
- [ ] v0.2 `@provenance_json` files still readable
- [ ] Feature flag emitted
- [ ] Python handles both layouts

### Commit message

```
Milestone 17: Compound per-run provenance

- Per-run provenance as HDF5 compound dataset
- compound_per_run_provenance feature flag
- @provenance_json deprecated with fallback reader
```

---

## Milestone 18 — Canonical Byte-Order Signatures (Objective-C + Python)

**Track:** ObjC hardening | **License:** LGPL-3.0

### Deliverables

- Normalize to canonical little-endian before hashing: `H5T_IEEE_F64LE`, `H5T_STD_U32LE` as mem_type (ObjC); `dtype='<f8'` (Python)
- Compound datasets: normalize numeric members; VL strings already BO-independent
- Format: `"v2:" + base64(mac)` prefix
- Verify attempts v2 first, v1 fallback with warning
- `opt_canonical_signatures` feature flag
- ObjC and Python produce identical v2 signatures

### Acceptance criteria

- [ ] Canonical signatures verify across emulated endianness
- [ ] v0.2 signatures verify in compat mode
- [ ] Compound type sigs stable across padding
- [ ] Cross-language parity

### Commit message

```
Milestone 18: Canonical byte-order signatures

- LE normalization before HMAC
- "v2:" prefix for version detection
- v1 backward compat
- opt_canonical_signatures feature flag
- Cross-language parity verified
```

---

## Milestone 19 — mzML Writer (Objective-C + Python)

**Track:** Export | **License:** Apache-2.0

### Deliverables

- **ObjC:** `MPGOMzMLWriter` in `objc/Source/Export/`
- **Python:** `mpeg_o.exporters.mzml` in `python/src/mpeg_o/exporters/`
- Reverse CVTermMapper: MPGO enum -> PSI-MS accession
- Base64 + optional zlib for binary arrays
- `indexedmzML` wrapper with byte-offset index
- Chromatogram output
- Apache-2.0 headers on all Export files
- Add Export files to `objc/Source/GNUmakefile`

### Acceptance criteria

- [ ] Round-trip: mzML -> .mpgo -> mzML -> compare (float64 epsilon)
- [ ] Output re-parseable by readers
- [ ] Chromatograms included
- [ ] indexedmzML offsets byte-correct
- [ ] ObjC and Python produce structurally identical XML

### Commit message

```
Milestone 19: mzML writer (Objective-C + Python)

- MPGOMzMLWriter (Apache-2.0)
- mpeg_o.exporters.mzml (Apache-2.0)
- Reverse CVTermMapper
- indexedmzML with byte-offset index
```

---

## Milestone 20 — Cloud-Native Access Prototype (Python)

**Track:** Infrastructure | **License:** LGPL-3.0

### Deliverables

- `mpeg_o.remote` module using `fsspec`
- `SpectralDataset.open("s3://bucket/file.mpgo")` detects URL, delegates
- Strategy: `fsspec.open(url, "rb")` -> `h5py.File(fileobj, "r")`
- Spectrum index fetched first, signal chunks lazy
- Query via index headers without full download
- CI test via `moto` (mock S3) or local HTTP server

### Acceptance criteria

- [ ] Open .mpgo from mock S3 (moto)
- [ ] Spectrum index fetched with minimal I/O
- [ ] Individual spectrum does not download full file
- [ ] Remote query works
- [ ] 10 spectra from 1000-spectrum file < 2 seconds (logged)

### Commit message

```
Milestone 20: Cloud-native access prototype

- mpeg_o.remote with fsspec
- Transparent s3:// / gs:// / az:// URL handling
- Lazy chunk-level reads
- CI test with moto mock S3
```

---

## Milestone 21 — Compression Codecs: LZ4 + Numpress (Objective-C + Python)

**Track:** Infrastructure | **License:** LGPL-3.0

### LZ4

- **ObjC:** HDF5 filter plugin (filter ID 32004). `H5Pset_filter`. Check `H5Zfilter_avail(32004)` at runtime; skip tests if unavailable.
- **Python:** `hdf5plugin` package provides LZ4 filter. Add to `[project.optional-dependencies] codecs`.
- New enum: `Compression.LZ4` / `MPGOCompressionLZ4`

### Numpress

Clean-room from Teleman et al., *MCP* 13(6):1537-1542, 2014, doi:10.1074/mcp.O114.037879

- `numpress_linear_encode` / `numpress_linear_decode`
- Fixed-point scaling factor + delta-encoded integers
- Lossy, < 1 ppm relative error for m/z
- Store in HDF5 dataset with `@numpress_fixed_point` attribute
- **ObjC:** `objc/Source/Core/MPGONumpress.h/.m`
- **Python:** `src/mpeg_o/_numpress.py` (pure Python + numpy)
- New enum: `Compression.NUMPRESS_DELTA` / `MPGOCompressionNumpressDelta`

### Benchmark

10,000-spectrum synthetic LC-MS run. Compare zlib-6 vs LZ4 vs Numpress+zlib. Log sizes and read speeds.

### Acceptance criteria

- [ ] LZ4 round-trip in both languages
- [ ] Numpress m/z within < 1 ppm relative error
- [ ] Cross-language: ObjC LZ4 readable by Python, vice versa
- [ ] Cross-language: ObjC Numpress readable by Python, vice versa
- [ ] LZ4 decompression 2-5x faster than zlib (logged)

### Commit message

```
Milestone 21: LZ4 + Numpress compression codecs

- LZ4 via HDF5 filter plugin + hdf5plugin
- Numpress linear (clean-room, Teleman et al. 2014)
- Cross-language codec interop
- Benchmark: LZ4 vs zlib
```

---

## Milestone 22 — v0.3.0 Release

**Track:** Cross-cutting

### Documentation

- Update `docs/format-spec.md`: compound per-run provenance, `v2:` signature format, LZ4/Numpress
- Update `docs/feature-flags.md`: new flags
- Update `README.md`: Python install, usage, dual-language badges
- Update `ARCHITECTURE.md`: Python class mapping, cloud design, codec matrix

### CI expansion

Add to `.github/workflows/ci.yml`:

```yaml
  python-test:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        python-version: ['3.11', '3.12']
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: ${{ matrix.python-version }}
      - run: sudo apt-get install -y libhdf5-dev
      - run: cd python && pip install -e ".[test,import]"
      - run: cd python && pytest -v --tb=short

  cross-compat:
    needs: [objc-build-test, python-test]
    runs-on: ubuntu-latest
    # Build ObjC fixtures, install Python, cross-verify both directions
```

### Publish

```bash
cd python && pip install build twine
python -m build
twine upload --repository testpypi dist/*
```

### Release

```bash
git tag -a v0.3.0 -m "MPEG-O v0.3.0: Python mpeg-o package, mzML export, canonical signatures, cloud access, LZ4/Numpress codecs"
git push origin v0.3.0
```

### Acceptance criteria

- [ ] ObjC: all tests pass (656 + M17/M18/M19/M21 tests)
- [ ] Python: all tests pass on 3.11 and 3.12
- [ ] Every fixture readable by both implementations
- [ ] v0.1 and v0.2 backward compat preserved
- [ ] `mpeg-o` installable from TestPyPI
- [ ] CI: ObjC + Python + cross-compat, all green
- [ ] Tag `v0.3.0` pushed

---

## Known Gotchas

### Inherited (v0.1/v0.2)

1. **HDF5 paths:** apt `/usr/include/hdf5/serial/`, source `/usr/local`. `HDF5_PREFIX` override.
2. **Testing.h vs ARC:** `-fno-objc-arc` on test binary. Preserve split.
3. **test-tool.make:** Custom `check::` target with LD_LIBRARY_PATH.
4. **Runtime ABI:** `ifeq ($(MPGO_OBJC_RUNTIME),gnustep-2.0)` pattern.
5. **-fblocks:** gnustep-2.0 only.
6. **LF enforcement:** `.gitattributes`. Fix with `git add --renormalize .`
7. **NSXMLParser needs libxml2.** Already in CI.

### New (v0.3)

8. **h5py compound types:** Use `np.dtype` with named fields matching `docs/format-spec.md` exactly. VL strings via `h5py.string_dtype()`.
9. **h5py file-like for cloud:** `h5py.File(fileobj, "r")` needs `.read()/.seek()/.tell()`. `fsspec.open()` satisfies this. h5py may buffer aggressively -- test actual I/O.
10. **AES-256-GCM cross-language parity:** `cryptography` AESGCM and OpenSSL produce identical output for same key+IV+plaintext. Use **fixed test IV** (not `os.urandom()`) for cross-language verification.
11. **Numpress precision:** Lossy. Tests use relative error: `abs(actual - expected) / max(abs(expected), 1.0) < 1e-6`.
12. **LZ4 filter availability:** Ubuntu `libhdf5-dev` may lack LZ4 plugin. Python `hdf5plugin` bundles its own. ObjC: check `H5Zfilter_avail(32004)` at runtime, skip if unavailable.
13. **PyPI name collision:** Verify `mpeg-o` availability before publishing: `pip index versions mpeg-o`.
14. **pytest temp files:** Use `tmp_path` fixture, not `/tmp/` directly.

---

## Execution Checklist

1. Tag v0.2.0 if needed. Push.
2. **Milestone 16:** Python core -- scaffold, reader, writer, importers, cross-compat. **Pause for user review.**
3. **Milestone 17:** Compound per-run provenance (ObjC). **Pause for user review.**
4. **Milestone 18:** Canonical signatures (ObjC + Python). **Pause for user review.**
5. **Milestone 19:** mzML writer (ObjC + Python). **Pause for user review.**
6. **Milestone 20:** Cloud-native access (Python). **Pause for user review.**
7. **Milestone 21:** LZ4 + Numpress (ObjC + Python). **Pause for user review.**
8. **Milestone 22:** Docs, CI, TestPyPI, tag v0.3.0.

**CI must be green before any milestone is complete.**

---

## Deferred to v0.4+

| Item | Description |
|---|---|
| Thread safety | HDF5 `--enable-threadsafe` + locking |
| `opt_key_rotation` | Envelope-style multi-key wrapping |
| Java stream | `com.dtwthalion.mpgo` with HDF5-Java |
| Spectral anonymization | SAAV-containing spectrum redaction |
| ISA-Tab export | Write ISA from SpectralDataset |
| Streaming transport | MPEG-G Part 2 equivalent |
| Zarr backend | Alternative cloud-native storage |
| DuckDB query layer | SQL interface via extension |
