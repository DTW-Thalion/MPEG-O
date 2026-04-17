# Migration Guide: mzML and nmrML to MPEG-O (v0.6)

## Audience and prerequisites

This guide is for developers who already have mzML or nmrML tooling and want to
write MPEG-O (`.mpgo`) files instead. It covers only the Python implementation.

**You need:**

- Python 3.11 or later
- An MPEG-O v0.6 checkout (PyPI publishing is deferred to M40; install from source)
- For Thermo `.raw` input: ThermoRawFileParser on your `PATH` (see section 6)

---

## Install

Install from the `python/` subdirectory of the MPEG-O checkout:

```
cd /path/to/MPEG-O/python
pip install -e ".[test,import]"
```

The `import` extra pulls in lxml, numpy, and h5py. The `test` extra adds pytest
and related tools. When M40 ships the PyPI-published package will be:

```
pip install mpeg-o
```

The public API shown in this guide will remain stable across that transition.

---

## 1. mzML to MPEG-O

### 1.1 Python quickstart

`mpeg_o.importers.mzml.read()` is a streaming SAX parser. It returns an
`ImportResult` — a lightweight in-memory container — rather than a live
`SpectralDataset`, because no backing HDF5 file exists yet. Call
`result.to_mpgo()` to flush to disk.

```python
from mpeg_o.importers.mzml import read as read_mzml

# Parse mzML into memory
result = read_mzml("sample.mzML")

# Write to an MPEG-O file
result.to_mpgo("sample.mpgo")
```

`to_mpgo()` returns the resolved `Path` of the written file. If you want to
pass optional feature flags (e.g. `"numpress-delta"`) at write time:

```python
result.to_mpgo("sample.mpgo", features=["numpress-delta"])
```

Quick sanity check before writing:

```python
print(f"Parsed {result.spectrum_count} spectra from {result.source_file}")
# e.g. "Parsed 39 spectra from sample.mzML"
```

### 1.2 Semantic mapping: mzML to MPEG-O

| mzML element / attribute                         | MPEG-O equivalent                                                      |
|--------------------------------------------------|------------------------------------------------------------------------|
| `<run>`                                          | `AcquisitionRun` (keyed `"run_0001"` in `SpectralDataset.ms_runs`)    |
| `<spectrum>`                                     | `MassSpectrum` (MS1 / MS2 distinguished by `ms_level`)                |
| `<cvParam>`                                      | `CVParam` (preserves `ontology_ref`, `accession`, `name`, `value`, `unit`) |
| `<scan startTime>`                               | `Spectrum.scan_time_seconds`                                           |
| `<scanWindow lowerLimit>` / `<upperLimit>`       | `MassSpectrum.scan_window: ValueRange`                                 |
| `<precursor selectedIon m/z>`                    | `Spectrum.precursor_mz`                                                |
| `<precursor charge>`                             | `Spectrum.precursor_charge`                                            |
| polarity `cvParam` (MS:1000129 / MS:1000130)     | `MassSpectrum.polarity: Polarity`                                      |
| `<dataProcessing>`                               | `ProvenanceRecord` (best-effort mapping per M41.4)                     |
| `<instrumentConfiguration>`                      | `AcquisitionRun.instrument_config: InstrumentConfig`                   |
| `<chromatogram>` (TIC / XIC / SRM)               | `Chromatogram` (type preserved on `chromatogram_type`)                 |

The importer preserves all `<binaryDataArray>` encodings (base64, zlib, 32/64-bit
float) and converts them to `float64` numpy arrays in memory.

### 1.2a Inspecting ImportResult before writing

`ImportResult` is a plain dataclass you can interrogate before committing to
disk. This is useful for validation pipelines that need to filter or annotate
spectra before writing.

```python
from mpeg_o.importers.mzml import read as read_mzml

result = read_mzml("sample.mzML")

# MS spectra
print(f"MS spectra:       {len(result.ms_spectra)}")

# Chromatograms (TIC, XIC, SRM)
print(f"Chromatograms:    {len(result.chromatograms)}")

# Provenance records (from <dataProcessing>)
print(f"Provenance items: {len(result.provenance)}")

# Inspect the first spectrum
if result.ms_spectra:
    s = result.ms_spectra[0]
    print(f"  first spectrum: {s.mz_or_chemical_shift.shape[0]} points, "
          f"rt={s.retention_time:.2f}s, ms_level={s.ms_level}, "
          f"polarity={s.polarity}")
```

You can mutate or filter `result.ms_spectra` before calling `to_mpgo()` if you
need to strip certain scan levels, correct polarity flags, or attach
identifications.

### 1.3 Round-trip verification

After writing, open the `.mpgo` file and confirm the run loaded correctly:

```python
from mpeg_o import SpectralDataset

ds = SpectralDataset.open("sample.mpgo")
run = ds.ms_runs["run_0001"]
print(f"Wrote {run.count()} spectra.")
ds.close()
```

For a more thorough check, iterate spectra and inspect the signal arrays:

```python
from mpeg_o import SpectralDataset

ds = SpectralDataset.open("sample.mpgo")
run = ds.ms_runs["run_0001"]

for i in range(min(3, run.count())):
    spectrum = run[i]
    mz_arr = spectrum.signal_arrays["mz"]
    intensity_arr = spectrum.signal_arrays["intensity"]
    print(
        f"  spectrum {i}: {len(mz_arr)} points, "
        f"rt={spectrum.scan_time_seconds:.2f}s, "
        f"ms_level={spectrum.ms_level}"
    )

ds.close()
```

If chromatograms were present in the source mzML, they are stored inside
`run_0001` and accessible via `run.chromatograms`.

---

## 2. nmrML to MPEG-O

### 2.1 Python quickstart

The nmrML importer follows the same `read()` / `to_mpgo()` pattern:

```python
from mpeg_o.importers.nmrml import read as read_nmrml

result = read_nmrml("sample.nmrML")
result.to_mpgo("sample.mpgo")
```

Print a summary before writing:

```python
print(f"Parsed {result.spectrum_count} NMR spectra, nucleus={result.nucleus_type!r}")
# e.g. "Parsed 1 NMR spectra, nucleus='1H'"
```

### 2.2 Semantic mapping: nmrML to MPEG-O

| nmrML element / CV term                             | MPEG-O equivalent                                                        |
|-----------------------------------------------------|--------------------------------------------------------------------------|
| `<spectrum1D>`                                      | `NMRSpectrum` (keyed in `SpectralDataset.nmr_runs["nmr_run"]`)          |
| NMR:1000001 (spectrometer frequency)                | `NMRSpectrum.spectrometer_frequency_mhz`                                |
| NMR:1000002 (nucleus)                               | `NMRSpectrum.nucleus_type` (normalised, e.g. `"1H"`, `"13C"`)          |
| NMR:1000003 (number of scans)                       | `FreeInductionDecay.scan_count`                                         |
| NMR:1000004 (dwell time)                            | `FreeInductionDecay.dwell_time_seconds`                                 |
| `<xAxis>` chemical shift axis                       | `NMRSpectrum.chemical_shift_array: SignalArray`                         |
| `<yAxis>` intensity axis                            | `NMRSpectrum.intensity_array: SignalArray`                              |
| `<fidData>` complex128 FID                          | `FreeInductionDecay` (subclass of `SignalArray`, per M41.2)             |

The importer normalises nucleus names: nmrML strings like `"H1"` or `"proton"`
are all stored as `"1H"`. If the nucleus cannot be determined from the CV terms,
`nucleus_type` is left as an empty string.

### 2.3 Round-trip verification

NMR runs are stored in `SpectralDataset.nmr_runs` (distinct from `ms_runs`):

```python
from mpeg_o import SpectralDataset

ds = SpectralDataset.open("sample.mpgo")
run = ds.nmr_runs["nmr_run"]
print(f"Wrote {run.count()} NMR spectra.")
ds.close()
```

Inspect the first spectrum's signal arrays:

```python
from mpeg_o import SpectralDataset

ds = SpectralDataset.open("sample.mpgo")
run = ds.nmr_runs["nmr_run"]

spectrum = run[0]
cs_arr = spectrum.signal_arrays["chemical_shift"]
intensity_arr = spectrum.signal_arrays["intensity"]
print(
    f"  chemical shift range: {float(cs_arr.data[0]):.2f} to "
    f"{float(cs_arr.data[-1]):.2f} ppm, "
    f"{len(cs_arr)} points"
)

ds.close()
```

---

## 3. Where the fixtures live

The canonical reference fixtures used by the cross-compatibility test suite are
in `objc/Tests/Fixtures/` inside the MPEG-O checkout. The Python tests
(`python/tests/test_importers.py`) reference them from there.

| Fixture file                       | Type   | Description                                          |
|------------------------------------|--------|------------------------------------------------------|
| `tiny.pwiz.1.1.mzML`               | mzML   | ProteoWizard minimal fixture, base64 + zlib arrays  |
| `1min.mzML`                        | mzML   | Real-world vendor file, 39 spectra, big-endian f32  |
| `bmse000325.nmrML`                 | nmrML  | BMRB metabolomics NMR, 1H at 500 MHz                |

These are the files exercised by `pytest python/tests/test_importers.py`. For
cross-language tests (Python, ObjC, Java roundtrip), see
`python/tests/test_cross_compat.py`.

The `data/` directory at the repo root currently contains:

```
data/metabolite_prevalence.json
```

That file is a reference metabolite table used by the quantification subsystem,
not an mzML/nmrML input. All XML import fixtures are under `objc/Tests/Fixtures/`.

---

## 4. Common pitfalls

### ThermoRawFileParser must be on PATH for .raw input

The Thermo importer (`mpeg_o.importers.thermo_raw`) shells out to
`ThermoRawFileParser` (or a path you supply via the `thermorawfileparser=`
kwarg). If the binary is not on `PATH` and no path is supplied, the importer
raises `FileNotFoundError`. Install ThermoRawFileParser from
https://github.com/compomics/ThermoRawFileParser and confirm it is on your
`PATH` before calling `thermo_raw.read()`.

### Feature flags are opt-in

Optional behaviors — numpress-delta compression, per-run provenance, ISA-Tab
export — are enabled by passing `features=` to `to_mpgo()`. A file written
without a feature flag will not contain those data even if the source had them.
The full list of recognized flags is in `docs/feature-flags.md`.

### signal_arrays, not channels

The dict of `SignalArray` objects on a `Spectrum` is called `signal_arrays`
(renamed in M41.2). Code written against earlier milestones that uses `.channels`
will raise `AttributeError`. Update all call sites:

```python
# Before M41.2 (wrong for v0.6):
mz = spectrum.channels["mz"]

# v0.6 (correct):
mz = spectrum.signal_arrays["mz"]
```

### ImportResult is not SpectralDataset

`read()` returns `ImportResult`, which is an in-memory structure without a
backing HDF5 file. It does not have `.ms_runs`, `.open()`, or `.write()`. Call
`result.to_mpgo(path)` first, then `SpectralDataset.open(path)` to get a live
dataset handle.

### NMR runs live in nmr_runs, not ms_runs

After importing nmrML, the run is stored under `SpectralDataset.nmr_runs["nmr_run"]`.
Accessing `ds.ms_runs["nmr_run"]` will raise `KeyError`.

### File handles must be closed

`SpectralDataset.open()` returns a live HDF5 handle. Always close it when done:

```python
ds = SpectralDataset.open("sample.mpgo")
try:
    # ... work with ds ...
    pass
finally:
    ds.close()
```

Or use the context manager if available in your version.

---

## 5. End-to-end example

The following script imports a real-world mzML file, writes MPEG-O, and verifies
the round-trip in one pass:

```python
import sys
from pathlib import Path
from mpeg_o.importers.mzml import read as read_mzml
from mpeg_o import SpectralDataset

def convert_and_verify(mzml_path: str, out_path: str) -> None:
    # Step 1: parse
    result = read_mzml(mzml_path)
    print(f"Parsed {result.spectrum_count} spectra from {Path(mzml_path).name}")

    # Step 2: write
    written = result.to_mpgo(out_path)
    print(f"Wrote {written}")

    # Step 3: verify
    ds = SpectralDataset.open(written)
    try:
        run = ds.ms_runs["run_0001"]
        print(f"Round-trip OK: {run.count()} spectra in run_0001")
    finally:
        ds.close()

if __name__ == "__main__":
    convert_and_verify(sys.argv[1], sys.argv[2])
```

Run it:

```
python convert.py objc/Tests/Fixtures/1min.mzML out/1min.mpgo
# Parsed 39 spectra from 1min.mzML
# Wrote out/1min.mpgo
# Round-trip OK: 39 spectra in run_0001
```

For nmrML, swap in the nmrML importer and use `nmr_runs`:

```python
import sys
from pathlib import Path
from mpeg_o.importers.nmrml import read as read_nmrml
from mpeg_o import SpectralDataset

def convert_and_verify_nmr(nmrml_path: str, out_path: str) -> None:
    result = read_nmrml(nmrml_path)
    print(f"Parsed {result.spectrum_count} NMR spectra, nucleus={result.nucleus_type!r}")

    written = result.to_mpgo(out_path)
    print(f"Wrote {written}")

    ds = SpectralDataset.open(written)
    try:
        run = ds.nmr_runs["nmr_run"]
        print(f"Round-trip OK: {run.count()} NMR spectra in nmr_run")
    finally:
        ds.close()

if __name__ == "__main__":
    convert_and_verify_nmr(sys.argv[1], sys.argv[2])
```

---

## 6. See also

- `docs/api-review-v0.6.md` — three-column parity map (Python / ObjC / Java)
  with stability markers for every public class and method.
- `docs/format-spec.md` — on-disk HDF5 layout: group hierarchy, dataset names,
  attribute types, feature-flag encoding.
- `docs/feature-flags.md` — complete list of optional feature flags and their
  effects on the written file.
- `python/tests/test_importers.py` — pytest tests exercising both importers
  against the canonical fixtures, including `ImportResult` attribute validation,
  provenance mapping, and chromatogram decoding.
- `python/tests/test_cross_compat.py` — cross-language round-trip tests.

