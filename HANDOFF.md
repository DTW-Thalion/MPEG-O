# MPEG-O v0.9 — Integration Tests + Format Expansion

> **Status:** v0.8.0 is **complete** (57 milestones). ObjC 1133
> assertions, Python 341 tests, Java 207 tests. Four storage
> providers (HDF5, Memory, SQLite, Zarr) in all three languages.
> PQC active (ML-KEM-1024, ML-DSA-87). This session executes
> **Milestones 57–64** to build a comprehensive integration test
> suite exercising real-world data and workflows, implement three
> new format importers (imzML, mzTab, Waters MassLynx), and add
> stress testing at scale.

---

## First Steps

1. `git clone https://github.com/DTW-Thalion/MPEG-O.git && cd MPEG-O && git pull`
2. Read: `ARCHITECTURE.md`, `docs/format-spec.md`, `docs/providers.md`,
   `docs/vendor-formats.md`, `docs/api-stability-v0.8.md`
3. Verify all three builds:
   ```bash
   cd objc && ./build.sh check
   cd ../python && pip install -e ".[test,import,crypto,zarr]" && pytest
   cd ../java && mvn verify -B
   ```
4. Tag v0.8.0 if not already tagged.

---

## Binding Decisions — All Prior (1–46) Active, Plus:

47. **Integration tests are Python-primary.** The integration test
    suite lives under `python/tests/integration/`,
    `python/tests/security/`, `python/tests/stress/`, and
    `python/tests/validation/`. Python's `pytest` ecosystem
    (markers, parametrize, fixtures, tmp_path) is the richest for
    this kind of testing. ObjC and Java get targeted integration
    tests for cross-language scenarios but do not duplicate the
    full Python matrix.
48. **Test fixtures are not committed to the repo if > 1 MB.** A
    `python/tests/fixtures/download.py` script fetches large
    fixtures from PRIDE, MetaboLights, BMRB, and imzml.org. CI
    caches them. SHA-256 checksums verify integrity. Small
    synthetic fixtures (< 1 MB) are generated in conftest.py.
49. **pytest markers gate external dependencies.** Tests requiring
    tools or network use `@pytest.mark.requires_thermorawfileparser`,
    `@pytest.mark.requires_opentims`, `@pytest.mark.requires_network`,
    `@pytest.mark.requires_s3`, `@pytest.mark.stress`,
    `@pytest.mark.aspirational`. Default CI runs
    `pytest -m "not stress and not requires_network"`. Nightly CI
    runs the full suite.
50. **imzML import is a first-class feature, not a stub.** The
    imzML format (XML metadata + binary .ibd) is the dominant MS
    imaging interchange format. MPEG-O's MSImage container already
    exists; M59 fills the ingestion path.
51. **Waters MassLynx: delegation pattern** identical to Thermo.
    Shell out to user-installed masslynxraw or Waters Connect API.
    No proprietary code in MPEG-O.
52. **mzTab import maps to Identification + Quantification.** mzTab
    is a results format, not raw data. The importer reads mzTab
    and populates the `.mpgo` identification and quantification
    compound datasets, optionally linking to an existing .mpgo that
    contains the referenced spectra.

---

## Dependency Graph

```
  M57 (Test infra + fixtures)
       |
       +------------------+--------------------+
       v                  v                    v
  M58 (Format            M59 (imzML          M60 (mzTab
   round-trips)           importer)            importer)
       |                  |                    |
       |                  |                    |
       +------------------+--------+-----------+
                                   |
                                   v
                       M64.5 (Caller refactor:
                        provider-aware writers)
                                   |
       +---------------------------+----------+
       v                  v                   |
  M61 (E2E workflows    M63 (Waters           |
   + security)            MassLynx)           |
       |                  |                   |
       v                  |                   |
  M62 (Stress +           |                   |
   cross-provider)        |                   |
       |                  |                   |
       +--------+---------+-------------------+
                |
                v
           M64 (Cross-tool validation + v0.9.0)
```

M57 is prerequisite for everything. M58-M60 are independent and ship
their cross-provider matrices with `not-yet-wired` skips. M64.5 is the
**caller-refactor gate** that wires every convenience writer through
the StorageProvider abstraction so those matrices actually run; it
must complete before M61/M62 to avoid wasted matrix work. M61 depends
on M58 (uses format round-trip infrastructure). M62 depends on M61
(uses workflow fixtures). M63 is independent. M64 is the release gate.

---

## Milestone 57 — Test Infrastructure + Fixture Management

**License:** LGPL-3.0

### Deliverables

**Directory structure:**

```
python/tests/
+-- integration/              # Format conversions, workflows
+-- security/                 # Encrypt, sign, rotate, anonymize
+-- stress/                   # Large-scale, concurrent, benchmark
+-- validation/               # Cross-tool, schema, backward compat
+-- fixtures/
|   +-- download.py           # Fetch large fixtures from public repos
|   +-- generate.py           # Create synthetic fixtures for CI
|   +-- checksums.json        # SHA-256 for every downloaded file
|   +-- README.md             # Provenance: source, license, expected values
+-- conftest.py               # Shared fixtures, markers, skip logic
```

**`download.py`** fetches and caches:
- BSA digest mzML from PRIDE (PXD000561 or equivalent, ~15 MB)
- MTBLS1 NMR files from MetaboLights (~5 MB)
- BMRB glucose reference (bmse000297, ~200 KB)
- opentims test `.d` directory (~50 MB)
- imzML reference files from imzml.org (continuous + processed, ~5 MB each)
- Cached in `~/.cache/mpgo-test-fixtures/` (XDG_CACHE_HOME aware)
- `checksums.json` validates every download

**`generate.py`** creates synthetic fixtures:
- `synth_bsa.mpgo` — 500 MS1 + 200 MS2 spectra, 50 BSA peptide
  identifications with known m/z and scores
- `synth_multimodal.mpgo` — 100 MS spectra + 10 NMR spectra in
  same container, with linked identifications
- `synth_100k.mpgo` — 100,000 spectra for stress tests
  (m/z = uniform 100-1000, intensity = random, realistic RT ramp)
- `synth_saav.mpgo` — dataset with 5 SAAV-linked identifications
  for anonymization testing
- `synth_metabolites.mpgo` — dataset with rare metabolite
  identifications for metabolomics anonymization

**`conftest.py`** markers:

```python
def pytest_configure(config):
    config.addinivalue_line("markers", "requires_thermorawfileparser: skip without ThermoRawFileParser")
    config.addinivalue_line("markers", "requires_opentims: skip without opentimspy")
    config.addinivalue_line("markers", "requires_network: skip without network (downloads fixtures)")
    config.addinivalue_line("markers", "requires_s3: skip without S3/MinIO endpoint")
    config.addinivalue_line("markers", "stress: long-running stress test")
    config.addinivalue_line("markers", "aspirational: requires not-yet-implemented feature")
```

**CI configuration:**
- Default: `pytest -m "not stress and not requires_network and not aspirational"`
- Nightly: `pytest` (full suite, network allowed, stress included)
- Add `[project.optional-dependencies] integration` to pyproject.toml:
  `["pyteomics", "pymzml", "isatools", "lxml", "opentimspy"]`

### Acceptance

- [ ] `download.py` fetches BSA mzML, verifies SHA-256
- [ ] `generate.py` creates all synthetic fixtures
- [ ] conftest.py registers all markers
- [ ] `pytest --co -m "not stress"` discovers tests without errors
- [ ] CI default run skips network/stress tests cleanly

---

## Milestone 58 — Format Conversion Round-Trip Tests

**License:** LGPL-3.0

### `python/tests/integration/test_mzml_roundtrip.py`

Parametrized over fixtures and providers:

```python
@pytest.mark.parametrize("provider", ["hdf5", "memory", "sqlite", "zarr"])
@pytest.mark.parametrize("fixture", ["tiny_pwiz", "1min", "bsa_digest"])
def test_mzml_full_roundtrip(fixture, provider, tmp_path):
    """mzML → .mpgo (on provider) → mzML → compare"""
```

**Verification per spectrum:**
- m/z array: `np.allclose(original, roundtrip, atol=0, rtol=1e-9)`
- Intensity array: same tolerance
- MS level: exact match
- Polarity: exact match
- Retention time: `abs(orig - rt) < 0.001` (1 ms)
- Precursor m/z (MS2): within float64 epsilon
- Precursor charge: exact match
- Scan window bounds: exact match

**Verification aggregate:**
- Spectrum count: exact match
- Chromatogram count: exact match (TIC, XIC if present)
- Feature flags: appropriate flags emitted

**Edge cases:**
- Empty spectrum (0 peaks) round-trips
- Very large spectrum (10K+ peaks) round-trips without OOM
- 32-bit float precision preserved (not silently promoted to 64-bit)
- Zlib-compressed source produces identical values to uncompressed

### `python/tests/integration/test_nmrml_roundtrip.py`

Same pattern for nmrML:
- FID complex128 values: real + imaginary within epsilon
- Chemical shift arrays: within epsilon
- Nucleus type, frequency, sweep width: exact match
- Number of scans: exact match

### `python/tests/integration/test_thermo_delegation.py`

```python
@pytest.mark.requires_thermorawfileparser
def test_thermo_raw_to_mpgo(thermo_fixture, tmp_path):
    """Thermo .raw → .mpgo via ThermoRawFileParser delegation → verify"""
```

### `python/tests/integration/test_bruker_tdf.py`

```python
@pytest.mark.requires_opentims
def test_bruker_tdf_import(bruker_fixture, tmp_path):
    """Bruker .d → .mpgo → verify frame count, ion mobility channel"""
```

### Acceptance

- [ ] mzML round-trip passes for all fixtures × all 4 providers
- [ ] nmrML round-trip passes for all fixtures × all 4 providers
- [ ] Thermo delegation test passes (when ThermoRawFileParser available)
- [ ] Bruker TDF test passes (when opentimspy available)
- [ ] Edge cases: empty spectrum, large spectrum, precision preservation
- [ ] All conversion fidelity criteria from the test strategy verified

---

## Milestone 59 — imzML Importer + MS Imaging Integration Tests

**License:** Apache-2.0 (importer), LGPL-3.0 (tests)

### imzML Importer

**Python: `mpeg_o.importers.imzml`**

```python
def read(imzml_path: str | Path, ibd_path: str | Path | None = None) -> SpectralDataset:
    """Import an imzML + .ibd file pair into an MPEG-O MSImage.

    If ibd_path is None, looks for a .ibd file alongside the .imzML
    with matching UUID.

    Supports both continuous and processed imzML modes.
    """
```

Uses `pyimzML` (`pip install pyimzml`) for parsing, or direct XML
parse + binary read if pyimzML is unavailable.

**ObjC: `MPGOImzMLReader` in `Import/`**

Direct XML parse of .imzML + binary read of .ibd. Maps spatial
coordinates (x, y, z) to MSImage grid. Handles both continuous
(shared m/z axis) and processed (per-pixel m/z) modes.

**Java: `ImzMLReader.java` in `importers/`**

Same approach: SAXParser for .imzML, RandomAccessFile for .ibd,
UUID validation for file pairing.

### HDF5/Provider Layout

imzML data maps to the existing MSImage container:
- `/study/image_cube/` with `[height, width, spectral_points]` dataset
- Spatial metadata: pixel size, scan pattern, origin coordinates
- For processed mode: per-pixel m/z arrays stored in signal channels
  with per-pixel spectrum index entries

### Integration Tests

```python
@pytest.mark.parametrize("mode", ["continuous", "processed"])
def test_imzml_import_roundtrip(mode, imzml_fixture, tmp_path):
    """imzML+.ibd → .mpgo MSImage → verify spatial + spectral data"""
```

Verify:
- Pixel count matches imzML spectrumList count
- Spatial coordinates (x, y) map correctly to grid
- m/z and intensity values within float64 epsilon
- UUID from .imzML preserved as provenance metadata
- Continuous mode: shared m/z axis stored once
- Processed mode: per-pixel m/z arrays preserved

### Acceptance

- [ ] Continuous imzML reference file imports correctly
- [ ] Processed imzML reference file imports correctly
- [ ] Spatial coordinates map to MSImage grid
- [ ] m/z and intensity values verified against pyimzML reference extraction
- [ ] Python, ObjC, Java importers produce identical .mpgo for same input
- [ ] imzML → .mpgo → verify in all three languages

---

## Milestone 60 — mzTab Importer + Identification Pipeline Tests

**License:** Apache-2.0

### mzTab Importer

**Python: `mpeg_o.importers.mztab`**

```python
def read(mztab_path: str | Path, *,
         link_to: SpectralDataset | None = None) -> SpectralDataset:
    """Import identification and quantification results from mzTab.

    If link_to is provided, the identifications are added to the
    existing dataset (matching by spectrum reference). Otherwise
    a new dataset is created with identifications only.

    Supports mzTab 1.0 (proteomics) and mzTab-M 2.0 (metabolomics).
    """
```

**Mapping:**
- mzTab PSM section → MPEG-O Identification records
- mzTab PRT section → MPEG-O Quantification records (protein-level)
- mzTab PEP section → peptide-level quantification
- mzTab SML section (mzTab-M) → metabolite Identification records
- mzTab MTD section → study metadata, instrument, software provenance
- `ms_run[1]-location` → source file provenance reference

**ObjC: `MPGOMzTabReader` in `Import/`**
**Java: `MzTabReader.java` in `importers/`**

Tab-separated parsing (no XML); simple line-by-line reader.

### Integration Tests

```python
def test_mztab_proteomics_import(mztab_fixture, tmp_path):
    """mzTab 1.0 → .mpgo identifications → verify PSM count + scores"""

def test_mztab_metabolomics_import(mztab_m_fixture, tmp_path):
    """mzTab-M 2.0 → .mpgo identifications → verify metabolite annotations"""

def test_mztab_link_to_existing(bsa_mpgo, mztab_fixture, tmp_path):
    """Import mzTab into existing .mpgo → identifications linked to spectra"""
```

### Acceptance

- [ ] mzTab 1.0 import: PSM count, scores, spectrum refs match source
- [ ] mzTab-M 2.0 import: metabolite IDs match source
- [ ] Linking to existing .mpgo: identifications reference correct spectra
- [ ] Quantification values round-trip correctly
- [ ] Provenance records created for import operation
- [ ] All three language implementations parse same mzTab identically

---

## Milestone 61 — End-to-End Workflow + Security Lifecycle Tests

**License:** LGPL-3.0

### `python/tests/integration/test_workflows.py`

**Workflow 1: BSA Proteomics Pipeline**
```python
def test_bsa_pipeline(bsa_mzml, tmp_path):
    # 1. Import mzML → .mpgo
    # 2. Verify spectrum count, RT range, MS1/MS2 distribution
    # 3. Query: MS2 with precursor m/z 547.27 ± 0.5
    # 4. Add BSA peptide identifications
    # 5. Export to mzML → verify spectra present
    # 6. Export to ISA-Tab → verify structure
    # 7. Sign → verify
    # 8. Encrypt intensity → verify m/z still queryable
    # 9. Decrypt → verify original intensities
    # 10. Anonymize (strip metadata) → verify serial removed
    # 11. Verify provenance chain records all operations
```

**Workflow 2: Multi-Modal MS + NMR**
```python
def test_multimodal_study(ms_fixture, nmr_fixture, tmp_path):
    # 1. Import mzML as MS run
    # 2. Import nmrML as NMR run into same dataset
    # 3. Query MS: RT predicate; Query NMR: chemical shift range
    # 4. Add cross-modal identifications
    # 5. Export ISA-Tab: both assays appear
    # 6. Export mzML (MS only), nmrML (NMR only)
```

**Workflow 3: Key Rotation Lifecycle**
```python
def test_key_rotation_lifecycle(tmp_path):
    # 1. Create dataset, encrypt with KEK-A (ML-KEM-1024)
    # 2. Verify only KEK-A can decrypt
    # 3. Rotate: KEK-A → KEK-B
    # 4. Verify KEK-B decrypts, KEK-A fails
    # 5. Verify rotation < 100ms
    # 6. Verify key history audit trail
    # 7. Cross-language: rotate in Python, verify in Java (subprocess)
```

**Workflow 4: Clinical Anonymization**
```python
def test_clinical_anonymization(saav_fixture, tmp_path):
    # 1. Import dataset with SAAV identifications
    # 2. Apply policy: redact SAAV + strip metadata
    # 3. Verify SAAV spectra removed
    # 4. Verify non-SAAV spectra intact
    # 5. Verify metadata stripped
    # 6. Verify signed provenance
    # 7. Verify original unmodified
```

### `python/tests/security/`

Full security lifecycle matrix:

```python
@pytest.mark.parametrize("provider", ["hdf5", "memory", "sqlite", "zarr"])
class TestEncryptionLifecycle:
    def test_encrypt_decrypt_roundtrip(self, provider, tmp_path): ...
    def test_wrong_key_fails_cleanly(self, provider, tmp_path): ...
    def test_mz_readable_while_encrypted(self, provider, tmp_path): ...
    def test_double_encrypt_errors(self, provider, tmp_path): ...
    def test_encrypt_empty_dataset(self, provider, tmp_path): ...

@pytest.mark.parametrize("provider", ["hdf5", "memory", "sqlite", "zarr"])
class TestSignatureLifecycle:
    def test_sign_verify(self, provider, tmp_path): ...
    def test_tamper_detection(self, provider, tmp_path): ...
    def test_v2_hmac_backward_compat(self, provider, tmp_path): ...
    def test_v3_mldsa_cross_provider(self, provider, tmp_path): ...
    def test_unsigned_returns_notsigned(self, provider, tmp_path): ...
    def test_provenance_chain_signing(self, provider, tmp_path): ...

@pytest.mark.parametrize("provider", ["hdf5", "memory", "sqlite", "zarr"])
class TestAnonymizationLifecycle:
    def test_saav_redaction(self, provider, tmp_path): ...
    def test_intensity_masking(self, provider, tmp_path): ...
    def test_mz_coarsening(self, provider, tmp_path): ...
    def test_chemical_shift_coarsening(self, provider, tmp_path): ...
    def test_rare_metabolite_masking(self, provider, tmp_path): ...
    def test_metadata_stripping(self, provider, tmp_path): ...
    def test_original_unmodified(self, provider, tmp_path): ...
```

### Acceptance

- [ ] All 4 workflow scenarios pass
- [ ] Encryption lifecycle: 5 scenarios × 4 providers = 20 tests pass
- [ ] Signature lifecycle: 6 scenarios × 4 providers = 24 tests pass
- [ ] Anonymization lifecycle: 7 scenarios × 4 providers = 28 tests pass
- [ ] PQC v3 signatures verified across providers
- [ ] Cross-language key rotation verified

---

## Milestone 62 — Stress Tests + Cross-Provider Benchmarks

**License:** LGPL-3.0

### `python/tests/stress/test_large_file.py`

```python
@pytest.mark.stress
class TestLargeFile:
    def test_write_100k_spectra(self, tmp_path):
        """Write 100,000 spectra. Target: < 30 seconds."""

    def test_read_100k_sequential(self, large_fixture):
        """Read all 100K spectra sequentially. Target: < 20 seconds."""

    def test_random_access_100_from_100k(self, large_fixture):
        """Random access 100 spectra from 100K. Target: < 500 ms."""

    def test_index_scan_100k(self, large_fixture):
        """Full header scan of 100K spectra. Target: < 50 ms."""

    def test_encrypt_100k(self, large_fixture, tmp_path):
        """Encrypt 100K spectra intensity channels. Target: < 60 seconds."""

    def test_sign_100k(self, large_fixture, tmp_path):
        """Sign 100K spectra. Target: < 30 seconds."""
```

### `python/tests/stress/test_concurrent_access.py`

```python
@pytest.mark.stress
class TestConcurrency:
    def test_4_readers_concurrent(self, large_fixture):
        """4 threads reading different spectra — no crashes, correct data."""

    def test_writer_blocks_readers(self, tmp_path):
        """1 writer + 4 readers — writer has exclusive access."""

    def test_8_threads_querying_index(self, large_fixture):
        """8 threads running index queries — correct results."""
```

### `python/tests/stress/test_provider_benchmark.py`

```python
@pytest.mark.stress
@pytest.mark.parametrize("provider", ["hdf5", "sqlite", "zarr", "memory"])
class TestProviderBenchmark:
    def test_write_10k_spectra(self, provider, tmp_path):
        """Write 10K spectra. Log time and file size."""

    def test_read_10k_spectra(self, provider, fixture_10k):
        """Read 10K spectra. Log time."""

    def test_random_access_100(self, provider, fixture_10k):
        """Random access 100 spectra from 10K. Log time."""

    def test_compound_write_1k_idents(self, provider, tmp_path):
        """Write 1K identifications. Log time."""

    def test_file_size_10k(self, provider, fixture_10k):
        """Report file size for 10K spectra with zlib compression."""
```

Results logged to `tests/stress/benchmark_results.json` for
tracking over time.

### `python/tests/stress/test_cloud_access.py`

```python
@pytest.mark.requires_s3
class TestCloudAccess:
    def test_open_from_s3(self, s3_fixture_url):
        """Open .mpgo from mock S3 — index fetched, metadata readable."""

    def test_selective_spectrum_fetch(self, s3_fixture_url):
        """Fetch 10 spectra — total bytes < 30% of file size."""

    def test_query_without_full_download(self, s3_fixture_url):
        """RT-range query executes without downloading full file."""
```

### Acceptance

- [ ] 100K write/read/query performance targets met
- [ ] Concurrent access: no crashes, correct data
- [ ] Provider benchmark results logged for all 4 providers
- [ ] Cloud access: selective fetch verified
- [ ] All stress tests complete within 10 minutes total

---

## Milestone 63 — Waters MassLynx Importer

**License:** Apache-2.0

Same delegation pattern as Thermo. Shell out to user-installed
MassLynx conversion tool (or `masslynxraw` Python package).

**Python: `mpeg_o.importers.waters_masslynx`**

```python
def read(raw_dir: str | Path, *,
         converter: str | None = None) -> SpectralDataset:
    """Import a Waters .raw directory via delegation.

    Searches PATH for 'masslynxraw' or uses the converter parameter.
    Falls back to clear error with installation guidance.
    """
```

**ObjC:** `MPGOWatersMassLynxReader` — `NSTask` delegation
**Java:** `WatersMassLynxReader.java` — `ProcessBuilder` delegation

**`docs/vendor-formats.md` update:** Waters section with installation
guidance, .raw directory structure overview, known limitations.

### Acceptance

- [ ] Python import works when converter available
- [ ] ObjC/Java delegation works
- [ ] Missing converter → clear error with guidance
- [ ] Mock-converter unit test works in CI
- [ ] `docs/vendor-formats.md` updated

---

## Milestone 64 — Cross-Tool Validation + v0.9.0 Release

**License:** LGPL-3.0

### `python/tests/validation/`

**mzML Schema Validation:**
```python
def test_mzml_export_validates_xsd(bsa_mpgo, tmp_path):
    """Export mzML, validate against mzML 1.1.1 XSD."""
    # Uses lxml.etree.XMLSchema or xmllint subprocess
```

**nmrML Schema Validation:**
```python
def test_nmrml_export_validates_xsd(nmr_mpgo, tmp_path):
    """Export nmrML, validate against nmrML XSD."""
```

**ISA-Tab Validation:**
```python
@pytest.mark.requires_isatools
def test_isa_export_validates(multimodal_mpgo, tmp_path):
    """Export ISA-Tab, validate with isatools.isatab.validate()."""
```

**Cross-Reader Verification:**
```python
@pytest.mark.requires_pyteomics
def test_mzml_readable_by_pyteomics(exported_mzml):
    """Verify pyteomics can read our mzML export."""

@pytest.mark.requires_pymzml
def test_mzml_readable_by_pymzml(exported_mzml):
    """Verify pymzml can read our mzML export."""
```

**Backward Compatibility:**
```python
@pytest.mark.parametrize("version", ["v01", "v02", "v03", "v04", "v05", "v06", "v07", "v08"])
def test_old_fixture_readable(version, fixture_dir):
    """Every .mpgo fixture from every prior release still readable."""
```

### Documentation

- `docs/test-strategy.md` — the integration test strategy report
  (committed from the report we produced)
- `python/tests/README.md` — how to run tests, marker descriptions,
  fixture download instructions
- Update `WORKPLAN.md` with M57-M64
- Update `README.md` with test suite documentation

### CI Expansion

```yaml
  integration-test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - run: sudo apt-get install -y libhdf5-dev libxml2-utils
      - run: cd python && pip install -e ".[test,import,crypto,zarr,integration]"
      - run: cd python && pytest tests/integration tests/security tests/validation -v --tb=short
        # Note: stress tests run in nightly job only

  stress-test:
    if: github.event_name == 'schedule'  # nightly cron
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
      - run: cd python && pip install -e ".[test,import,crypto,zarr,integration]"
      - run: cd python && pytest tests/stress -v --tb=short -m stress
```

### Release

```bash
git tag -a v0.9.0 -m "MPEG-O v0.9.0: integration test suite, imzML/mzTab/Waters importers, stress tests, cross-tool validation"
git push origin v0.9.0
```

### Acceptance

- [ ] mzML export validates against XSD
- [ ] nmrML export validates against XSD
- [ ] ISA-Tab validates with isatools (when available)
- [ ] pyteomics and pymzml can read our exports (when available)
- [ ] All v0.1-v0.8 fixtures still readable
- [ ] Integration test CI job green
- [ ] Stress test nightly job green
- [ ] Tag v0.9.0 pushed

---

## Milestone 64.5 — Caller Refactor: Provider-Aware Convenience Writers

**License:** LGPL-3.0

### Why

`v0.6` shipped the `StorageProvider` abstraction and *read*-side
provider awareness on `SpectralDataset.open`. Bulk write paths were
explicitly deferred — `ARCHITECTURE.md` "Caller refactor status"
table lists them as "Still native — use
`dataset.provider.native_handle()`". As of v0.8 the deferral remains:
every convenience writer opens `h5py.File` directly. That makes the
4-provider parametrize matrices in M58/M61/M62 collapse to HDF5-only,
even though Memory/SQLite/Zarr providers are fully implemented at the
storage layer (proven by `test_canonical_bytes_cross_backend.py`).

M64.5 closes the gap: every writer routes through the
`StorageProvider` protocol, the matrix tests light up across all four
backends, and the v0.9.0 release legitimately delivers what the v0.8
docs already advertise ("4-provider cross-lang parity").

### Binding decisions (M64.5)

53. **Default provider stays HDF5.** Every writer accepts a new
    `provider=` kwarg whose default is HDF5 so existing callers and
    on-disk semantics are preserved bit-for-bit.
54. **Native handle escape hatch is deprecated, not removed.** Code
    that genuinely needs HDF5-specific features (chunking layout,
    SWMR, fsspec routing) can still call
    `provider.native_handle()`; the escape hatch is documented as a
    no-go for new write paths but kept for cloud/streaming code.
55. **Cross-backend canonical bytes are the contract.**
    `read_canonical_bytes` already produces identical output across
    HDF5/Memory/SQLite/Zarr. Writers are correct iff a write through
    any provider produces the same canonical bytes when re-read
    through any other compatible provider.
56. **One commit per writer family**, mirroring the M-series
    convention. Suggested commit boundaries align with §"Refactor
    targets" below so each lands its own checkpoint.

### Refactor targets

| # | Writer | Source file | Currently native because… |
|---|---|---|---|
| 1 | `SpectralDataset.write_minimal` | `spectral_dataset.py:378` | Opens `h5py.File(p, "w")` directly; calls `_write_run` / `_write_identifications` / `_write_quantifications` / `_write_provenance` against `h5py.Group`. |
| 2 | `_write_run` (signal channels) | `spectral_dataset.py:458` | Bulk writes to `parent.create_dataset` with HDF5-specific chunk + zlib kwargs. |
| 3 | `_write_identifications` / `_write_quantifications` / `_write_provenance` | `spectral_dataset.py:529 / 559 / 586` | Build numpy structured arrays and pass to HDF5 compound dataset API. |
| 4 | `AcquisitionRun.encrypt_with_key` / `decrypt_with_key` | `acquisition_run.py` | Reads/writes signal channel bytes via `h5py.Dataset`. |
| 5 | `AcquisitionRun` write-back of NumPress / LZ4-compressed channels | `acquisition_run.py` (`_numpress_channels`, `_signal_cache`) | Codec round-trip writes through HDF5 chunked datasets. |
| 6 | `MSImage` cube writes | `ms_image.py` | `create_dataset_nd` is provider-aware but bulk image-cube writes still use `h5py.Group.create_dataset`. |
| 7 | `EncryptionManager` | `encryption.py` (referenced by `dataset.encrypt_with_key`) | AES-GCM ciphertext written back via raw HDF5; needs `StorageDataset.write` + canonical-bytes path. |
| 8 | `SignatureManager.sign_dataset` (HMAC v2 + ML-DSA-87 v3) | `protection/signature.py` | Reads canonical bytes (provider-aware) but writes signature attribute via `h5py`. |
| 9 | `KeyRotationManager.rotate_keys` | `protection/key_rotation.py` | Re-encrypts signal channels in place; same HDF5 dependency as #4 + #7. |
| 10 | `Anonymizer.anonymize` | `anonymization.py` | Reads source via provider, but writes the anonymized output via `SpectralDataset.write_minimal` — inherits #1's HDF5 lock-in. |
| 11 | `StreamWriter` | `stream_writer.py` | Streaming append-only writer; currently `h5py.File`-only. |
| 12 | Encrypted-attribute helpers | `encryption.py`, `protection/*.py` | Several read/write attribute helpers reach for `h5py.AttributeManager`. |

### Deliverables

**`src/mpeg_o/spectral_dataset.py`**

* `SpectralDataset.write_minimal(path, ..., provider="hdf5")` — new
  kwarg accepting either a string (registered provider name) or a
  pre-opened `StorageProvider`. When a string is given, the writer
  uses `open_provider(path, provider=provider, mode="w")`. When a
  provider object is given, the caller owns its lifecycle.
* `_write_run` / `_write_identifications` / `_write_quantifications`
  / `_write_provenance` accept a `StorageGroup` instead of an
  `h5py.Group`. Compound datasets go through
  `group.create_compound_dataset(name, fields, n)`; signal channels
  through `group.create_dataset(name, precision, n).write(buf)`.
  Chunking + compression hints are passed via the
  `StorageGroup.create_dataset` `compression=` / `chunks=` kwargs
  that `base.py` already accepts.

**`src/mpeg_o/providers/base.py`**

* Audit `StorageGroup.create_dataset` / `create_compound_dataset`
  signatures to confirm every kwarg the HDF5 writer relies on
  (chunking, compression level, fill value) is part of the protocol.
  Add any missing parameters; default-implement them no-op for
  Memory if the backend can't honour them.

**`src/mpeg_o/{providers/memory.py, providers/sqlite.py, providers/zarr.py}`**

* Implement any newly-required `create_dataset` / write parameters.
* Confirm `write_canonical_bytes` round-trips through each backend
  for all 4 spectrum-channel codecs (raw, zlib, NumPress-delta, LZ4).

**`src/mpeg_o/{acquisition_run.py, ms_image.py}`**

* Replace `self.group.create_dataset(...)` calls with
  `self.storage_group.create_dataset(...)`. Preserve the
  `provider.native_handle()` escape only behind a `_legacy_h5py=True`
  internal kwarg that the deprecated streaming path keeps using.

**`src/mpeg_o/{encryption.py, protection/signature.py,
protection/key_rotation.py, anonymization.py}`**

* Move bulk byte writes to `StorageDataset.write_canonical_bytes`
  (or equivalent helper to be added). Signature/HMAC value storage
  goes through `StorageGroup.set_attribute(name, value)` (already in
  the protocol).
* `Anonymizer.anonymize(out_path, *, provider="hdf5")` — surface the
  same kwarg as `write_minimal` so callers can pin output backend.

**Tests — provider matrix unblock**

* `python/tests/integration/_provider_matrix.py` ships in M58 with
  `WRITE_PROVIDERS_WIRED = False`. Flip to `True` here. The 4-provider
  parametrize matrices in M58/M61/M62 stop skipping with
  *"not yet wired through SpectralDataset.write_minimal"* and run
  natively across HDF5/Memory/SQLite/Zarr.
* New test:
  `tests/integration/test_writer_canonical_bytes_cross_provider.py`
  — write the same logical .mpgo through each of the 4 providers,
  read back through each of the 4, assert canonical bytes match
  across all 16 cells. Target ~3 minutes runtime.
* Cross-language: at least one M64.5 test exports an .mpgo via
  Memory provider in Python, hands the resulting in-memory store to
  the ObjC `mpgo-verify` CLI via stdin or temp file. (Only worth
  doing if Memory provider exposes a serialize-to-bytes path; if
  not, defer to M64-style cross-tool validation.)

### Acceptance

- [ ] `SpectralDataset.write_minimal(provider="memory" | "sqlite" |
      "zarr")` produces a readable .mpgo whose canonical bytes match
      the HDF5 reference for the same input.
- [ ] All four protection classes (Encryption, Signature,
      KeyRotation, Anonymization) operate against any of the 4
      providers, verified by per-provider tests.
- [ ] M58/M61/M62 4-provider parametrize matrices stop skipping for
      Memory/SQLite/Zarr after `WRITE_PROVIDERS_WIRED = True` is
      flipped.
- [ ] Existing 356-test suite stays green at every step.
- [ ] `ARCHITECTURE.md` "Caller refactor status" table updated:
      every row except the legacy streaming path shows
      "**Provider-aware**".
- [ ] Sphinx doc build (`python/docs/`) regenerated; docstrings
      updated to describe the new `provider=` kwarg.

### Scheduling note

M64.5 is logically a v0.9 sub-milestone. The dependency graph above
places it **before M61** so the security/anonymization/stress
matrices (which expand the parametrize to ~80 test cases combined)
land already-wired, not as 60+ new skips. If schedule pressure
forces M61/M62 to run first, plan a follow-up pass after M64.5 to
delete the skip helpers and re-baseline counts.

### Rollback

Each writer-family commit can be reverted independently. The
`provider="hdf5"` default means a partial rollback never breaks an
on-disk file; it only takes the corresponding non-HDF5 cells back to
"skipped".

---

## Known Gotchas

**Inherited (1–45):** All prior gotchas active.

**New (v0.9):**

46. **pyimzML installation.** `pip install pyimzml` is the standard
    package. It depends on numpy and lxml. If unavailable, the
    imzML importer falls back to direct XML + binary parsing.

47. **mzTab version detection.** mzTab 1.0 (proteomics) starts with
    `MTD\tmzTab-version\t1.0`. mzTab-M 2.0 (metabolomics) starts
    with `MTD\tmzTab-version\t2.0.0-M`. The parser must detect the
    version on the first line and dispatch accordingly.

48. **imzML .ibd binary offsets.** The .imzML XML contains byte
    offsets into the .ibd binary file. These are absolute byte
    positions. The parser must validate that offsets + array lengths
    don't exceed .ibd file size (common corruption case).

49. **imzML UUID pairing.** The .imzML and .ibd are linked by UUID.
    If the UUID in the .imzML doesn't match the .ibd header, the
    import must fail with a clear error, not silently proceed.

50. **Stress test determinism.** The 100K synthetic fixture must use
    a seeded RNG (`np.random.default_rng(42)`) so benchmark
    results are reproducible across runs.

51. **Waters MassLynx binary names.** The conversion tool may be
    called `masslynxraw`, `MassLynxRaw.exe`, or be accessed via
    Waters Connect API. Check all three; use `MASSLYNXRAW` env
    var as override.

52. **isatools compatibility.** The `isatools` package has breaking
    API changes between versions. Pin to `isatools>=0.14,<1.0` and
    catch `ImportError` for graceful skip.

---

## Execution Checklist

1. Tag v0.8.0 if needed.
2. **M57:** Test infrastructure + fixtures. **Pause.**
3. **M58:** Format conversion round-trip tests. **Pause.**
4. **M59:** imzML importer + tests. **Pause.**
5. **M60:** mzTab importer + tests. **Pause.**
6. **M64.5:** Caller refactor — provider-aware writers. **Pause.**
   (Run before M61/M62 so the security + stress matrices ship
   already-wired across all 4 providers.)
7. **M61:** E2E workflows + security tests. **Pause.**
8. **M62:** Stress tests + benchmarks. **Pause.**
9. **M63:** Waters MassLynx importer. **Pause.**
10. **M64:** Cross-tool validation + v0.9.0 release.

**CI must be green before any milestone is complete.**

---

## Deferred to v1.0+

| Item | Description |
|---|---|
| M40 PyPI + Maven Central | Publish when ready for external users |
| FIPS compliance mode | Algorithm allow-list lockdown |
| Streaming transport | MPEG-G Part 2 real-time protocol |
| ParquetProvider | Columnar alternative backend |
| Raman/IR support | New Spectrum subclasses |
| DBMS transport | Postgres/MySQL blob storage |
| v1.0 API freeze | After production feedback on v0.9 |
