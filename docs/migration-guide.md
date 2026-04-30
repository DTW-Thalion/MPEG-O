# Migration Guide: mzML, nmrML, SAM/BAM/CRAM to TTI-O (current: v1.2)

## Audience and prerequisites

This guide is for developers who already have mzML / nmrML / SAM / BAM /
CRAM tooling and want to write TTI-O (`.tio`) files instead. It covers
only the Python implementation; the ObjC and Java surfaces mirror it
(see [ARCHITECTURE.md](../ARCHITECTURE.md) for the cross-language map).

**You need:**

- Python 3.11 or later
- A TTI-O v1.2 checkout (PyPI publishing is deferred until the M40
  account-setup work clears; install from source today)
- For Thermo `.raw` input: ThermoRawFileParser on your `PATH` (see section 6)
- For SAM / BAM / CRAM input: `samtools` (≥ 1.19) on your `PATH`
- For a non-HDF5 backend: `pip install 'ttio[zarr]'`

---

## Install

Install from the `python/` subdirectory of the TTI-O checkout:

```
cd /path/to/TTI-O/python
pip install -e ".[test,import]"
```

The `import` extra pulls in lxml, numpy, and h5py. The `test` extra adds pytest
and related tools. When M40 ships the PyPI-published package will be:

```
pip install ttio
```

The public API shown in this guide will remain stable across that transition.

---

## 1. mzML to TTI-O

### 1.1 Python quickstart

`ttio.importers.mzml.read()` is a streaming SAX parser. It returns an
`ImportResult` — a lightweight in-memory container — rather than a live
`SpectralDataset`, because no backing HDF5 file exists yet. Call
`result.to_ttio()` to flush to disk.

```python
from ttio.importers.mzml import read as read_mzml

# Parse mzML into memory
result = read_mzml("sample.mzML")

# Write to an TTI-O file
result.to_ttio("sample.tio")
```

`to_ttio()` returns the resolved `Path` of the written file. If you want to
pass optional feature flags (e.g. `"numpress-delta"`) at write time:

```python
result.to_ttio("sample.tio", features=["numpress-delta"])
```

Quick sanity check before writing:

```python
print(f"Parsed {result.spectrum_count} spectra from {result.source_file}")
# e.g. "Parsed 39 spectra from sample.mzML"
```

### 1.2 Semantic mapping: mzML to TTI-O

| mzML element / attribute                         | TTI-O equivalent                                                      |
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
from ttio.importers.mzml import read as read_mzml

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

You can mutate or filter `result.ms_spectra` before calling `to_ttio()` if you
need to strip certain scan levels, correct polarity flags, or attach
identifications.

### 1.3 Round-trip verification

After writing, open the `.tio` file and confirm the run loaded correctly:

```python
from ttio import SpectralDataset

ds = SpectralDataset.open("sample.tio")
run = ds.ms_runs["run_0001"]
print(f"Wrote {run.count()} spectra.")
ds.close()
```

For a more thorough check, iterate spectra and inspect the signal arrays:

```python
from ttio import SpectralDataset

ds = SpectralDataset.open("sample.tio")
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

## 2. nmrML to TTI-O

### 2.1 Python quickstart

The nmrML importer follows the same `read()` / `to_ttio()` pattern:

```python
from ttio.importers.nmrml import read as read_nmrml

result = read_nmrml("sample.nmrML")
result.to_ttio("sample.tio")
```

Print a summary before writing:

```python
print(f"Parsed {result.spectrum_count} NMR spectra, nucleus={result.nucleus_type!r}")
# e.g. "Parsed 1 NMR spectra, nucleus='1H'"
```

### 2.2 Semantic mapping: nmrML to TTI-O

| nmrML element / CV term                             | TTI-O equivalent                                                        |
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
from ttio import SpectralDataset

ds = SpectralDataset.open("sample.tio")
run = ds.nmr_runs["nmr_run"]
print(f"Wrote {run.count()} NMR spectra.")
ds.close()
```

Inspect the first spectrum's signal arrays:

```python
from ttio import SpectralDataset

ds = SpectralDataset.open("sample.tio")
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
in `objc/Tests/Fixtures/` inside the TTI-O checkout. The Python tests
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

The Thermo importer (`ttio.importers.thermo_raw`) shells out to
`ThermoRawFileParser` (or a path you supply via the `thermorawfileparser=`
kwarg). If the binary is not on `PATH` and no path is supplied, the importer
raises `FileNotFoundError`. Install ThermoRawFileParser from
https://github.com/compomics/ThermoRawFileParser and confirm it is on your
`PATH` before calling `thermo_raw.read()`.

### Feature flags are opt-in

Optional behaviors — numpress-delta compression, per-run provenance, ISA-Tab
export — are enabled by passing `features=` to `to_ttio()`. A file written
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
`result.to_ttio(path)` first, then `SpectralDataset.open(path)` to get a live
dataset handle.

### NMR runs live in nmr_runs, not ms_runs

After importing nmrML, the run is stored under `SpectralDataset.nmr_runs["nmr_run"]`.
Accessing `ds.ms_runs["nmr_run"]` will raise `KeyError`.

### File handles must be closed

`SpectralDataset.open()` returns a live HDF5 handle. Always close it when done:

```python
ds = SpectralDataset.open("sample.tio")
try:
    # ... work with ds ...
    pass
finally:
    ds.close()
```

Or use the context manager if available in your version.

---

## 5. End-to-end example

The following script imports a real-world mzML file, writes TTI-O, and verifies
the round-trip in one pass:

```python
import sys
from pathlib import Path
from ttio.importers.mzml import read as read_mzml
from ttio import SpectralDataset

def convert_and_verify(mzml_path: str, out_path: str) -> None:
    # Step 1: parse
    result = read_mzml(mzml_path)
    print(f"Parsed {result.spectrum_count} spectra from {Path(mzml_path).name}")

    # Step 2: write
    written = result.to_ttio(out_path)
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
python convert.py objc/Tests/Fixtures/1min.mzML out/1min.tio
# Parsed 39 spectra from 1min.mzML
# Wrote out/1min.tio
# Round-trip OK: 39 spectra in run_0001
```

For nmrML, swap in the nmrML importer and use `nmr_runs`:

```python
import sys
from pathlib import Path
from ttio.importers.nmrml import read as read_nmrml
from ttio import SpectralDataset

def convert_and_verify_nmr(nmrml_path: str, out_path: str) -> None:
    result = read_nmrml(nmrml_path)
    print(f"Parsed {result.spectrum_count} NMR spectra, nucleus={result.nucleus_type!r}")

    written = result.to_ttio(out_path)
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

## 6. Migrating from v0.6 to v0.7

v0.7 is backward-compatible at the Python API level — **no existing
call needs to change**. The additions are opt-in:

### 6.1 Switch to a different storage backend

Any call that opened a file directly now takes a URL and routes to the
matching provider:

```python
from ttio.providers import open_provider

# Default — HDF5 (unchanged from v0.6)
with open_provider("run.tio", mode="r") as p:
    ...

# In-process scratch
with open_provider("memory://scratch", mode="w") as p:
    ...

# SQLite (v0.6.1)
with open_provider("sqlite:///tmp/run.db", mode="w") as p:
    ...

# Zarr (v0.7, needs `pip install 'ttio[zarr]'`)
with open_provider("zarr:///tmp/store.zarr", mode="w") as p:
    ...
with open_provider("zarr+s3://bucket/key.zarr", mode="r") as p:
    ...
```

See `docs/providers.md` for the feature matrix across providers.

### 6.2 Request a specific crypto algorithm

`encrypt_bytes`, `decrypt_bytes`, `sign_dataset`, `verify_dataset`,
and `enable_envelope_encryption` gained optional `algorithm=`
parameters that validate against the `CipherSuite` catalog. Default
behaviour is unchanged (`aes-256-gcm` / `hmac-sha256`):

```python
from ttio.encryption import encrypt_bytes

ct, iv, tag = encrypt_bytes(b"payload", key32,
                             algorithm="aes-256-gcm")  # explicit
```

Reserved algorithm IDs for ML-KEM-1024, ML-DSA-87, and SHAKE-256 are
present in the catalog but raise `UnsupportedAlgorithmError` until
v0.8+.

### 6.3 Adopt the versioned wrapped-key blob

New key-rotation callers should let the default take care of it —
v0.7 writers emit the v1.2 blob format by default when the
`wrapped_key_v2` feature flag is enabled on the file. Legacy
60-byte v1.1 blobs remain readable indefinitely (binding decision
38). See `docs/format-spec.md §5b.2` for the exact byte layout.

### 6.4 `read_canonical_bytes` for cross-backend signing

If you implemented custom signing on top of v0.6's `native_handle()`,
switch to the protocol-native path:

```python
sig_input = dataset.read_canonical_bytes()
```

This returns the same bytes regardless of provider (HDF5 / Memory /
SQLite / Zarr), so signatures verify across backend transitions.
Binding decision 37.

---

## 7. Migrating from v0.7 to v0.8

Additive: `opt_pqc_preview` enables ML-KEM-1024 envelope wrapping and
ML-DSA-87 signatures alongside the classical AES-256-GCM + HMAC-SHA256
defaults. Install with `pip install 'ttio[pqc]'` (Python) or add the
Bouncy Castle 1.80+ artefact (Java); ObjC links `liboqs` directly. No
on-disk layout change is forced; the flag simply signals the reader
that a `v3:` signature attribute or an ML-KEM-1024 wrapped key may be
present. v0.7-and-earlier readers can still open v0.8 files that
don't actually use PQC primitives. See `docs/pqc.md`.

## 8. Migrating from v0.8 to v0.9

Provider abstraction hardened across all three languages (SQLite and
Zarr v3 backends complete). Zarr v2 stores migrate to v3 on write;
reads of v2 stores remain supported. v0.9.1 shipped the mzTab and
imzML exporters and fixed the last three M64 xfails (nmrML
`<spectrum1D>` content model, mzML `<activation>`, ISA-Tab
PUBLICATIONS). No new feature flags; no code changes required for
existing callers.

## 9. Migrating from v0.9 to v0.10 — streaming transport

New in v0.10: the `.tis` streaming transport format
(`docs/transport-spec.md`) with nine packet types and optional
CRC-32C framing. The transport layer is additive — existing `.tio`
files continue to open unchanged. `TransportWriter` /
`TransportReader` plus `TransportClient` / `TransportServer` are new
APIs; see `docs/api-stability-v0.8.md` §4.1 for the stable surface.

## 10. Migrating to v1.0 per-AU encryption (`opt_per_au_encryption`)

The v1.0 per-Access-Unit encryption flag shipped in v0.10.0. Three
starting points:

**a) Plaintext → per-AU encrypted.** Use the `transcode` subcommand
of the per-AU CLI (or call `encrypt_per_au` / `PerAUFile.encryptFile`
/ `+[TTIOPerAUFile encryptFilePath:...]` directly):

```bash
# Python
python -m ttio.tools.per_au_cli transcode input.tio output.tio key.bin --headers

# Java
java -cp ... global.thalion.ttio.tools.PerAUCli encrypt input.tio output.tio key.bin --headers

# ObjC
TtioPerAU encrypt input.tio output.tio key.bin --headers
```

`--headers` additionally encrypts the 36-byte semantic header
(retention time, ms level, polarity, precursor m/z, precursor
charge, base peak intensity, ion mobility, acquisition mode). Drop
the flag to keep those values plaintext so servers can filter AUs
without the key.

**b) Rotating the DEK on a per-AU encrypted file.** Use the same
`transcode` subcommand with `--rekey`:

```bash
python -m ttio.tools.per_au_cli transcode \
  already_encrypted.tio rotated.tio old_key.bin --rekey new_key.bin --headers
```

The tool decrypts with the old key into a scratch layout (rewriting
`<channel>_values` + plaintext `spectrum_index` arrays inside the
output file before re-encrypting), then re-encrypts with the new key
and fresh IVs. Old-key decryption of `rotated.tio` fails cleanly
via AES-GCM tag mismatch.

**c) v0.x `opt_dataset_encryption` → v1.0 per-AU.** The v0.x channel-
level AES-GCM model shares a single IV + tag per channel per run;
this cannot be converted in place to the per-spectrum layout without
materialising the plaintext. Two-step migration:

```python
import numpy as np
from ttio import SpectralDataset
# 1. Open with the v0.x API and decrypt into a plaintext scratch copy.
with SpectralDataset.open("v0x_encrypted.tio") as src:
    src.decrypt(key=dek)
    src.save_as("plaintext_scratch.tio")
# 2. Encrypt forward through the v1.0 path.
import subprocess, sys
subprocess.check_call([sys.executable, "-m", "ttio.tools.per_au_cli",
                        "transcode", "plaintext_scratch.tio",
                        "v1_encrypted.tio", "key.bin", "--headers"])
```

The `transcode` CLI refuses `opt_dataset_encryption` inputs with a
clear error message rather than silently doing the wrong thing.

**Storage-backend caveat.** Per-AU encryption requires `VL_BYTES`
compound field support. The HDF5 and Memory providers support it
today; SQLite and Zarr raise `NotImplementedError` /
`UnsupportedOperationException` at the `create_compound_dataset`
boundary until their JSON-based compound paths grow base64
transport for bytes. When using SQLite or Zarr containers, keep
encryption at the v0.x channel level or copy into HDF5 before
transcoding.

## 11. Migrating from v0.10 to v0.11 — Raman and IR spectroscopy (M73)

Additive: two new modalities joined MS and NMR as first-class
citizens. No existing call changes; no feature flag was introduced.

### 11.1 New classes (Python / Java / ObjC)

| Concept | Python | Java | ObjC |
|---|---|---|---|
| Raman point spectrum | `ttio.RamanSpectrum` | `global.thalion.ttio.RamanSpectrum` | `TTIORamanSpectrum` |
| IR point spectrum | `ttio.IRSpectrum` | `global.thalion.ttio.IRSpectrum` | `TTIOIRSpectrum` |
| Raman hyperspectral cube | `ttio.RamanImage` | `global.thalion.ttio.RamanImage` | `TTIORamanImage` |
| IR hyperspectral cube | `ttio.IRImage` | `global.thalion.ttio.IRImage` | `TTIOIRImage` |
| IR mode enum | `ttio.IRMode` | `global.thalion.ttio.IRMode` | `TTIOIRMode` |

Both spectrum classes share the same shape: `wavenumber_array` +
`intensity_array` (cm⁻¹ x, arbitrary y), plus modality-specific
metadata — Raman carries `excitation_wavelength_nm`,
`laser_power_mw`, `integration_time_sec`; IR carries `mode`
(`TRANSMITTANCE` / `ABSORBANCE`), `resolution_cm_inv`,
`number_of_scans`.

### 11.2 HDF5 layout for hyperspectral cubes

`RamanImage` / `IRImage` serialize to dedicated HDF5 groups per
study: `/study/raman_image_cube/` and `/study/ir_image_cube/`. The
layout mirrors `/study/msimage_cube/` — a rank-3 intensity cube
with tile chunking and a rank-1 shared wavenumber axis as a sibling
dataset. A study may carry **either** a Raman cube or an IR cube,
not both (mutually exclusive per the format spec). See
`docs/format-spec.md` §7a.

### 11.3 JCAMP-DX import / export (point spectra)

All three languages ship a JCAMP-DX 5.01 AFFN reader and writer:

```python
from ttio.importers.jcampdx import read as read_jcampdx
result = read_jcampdx("sample.jdx")
result.to_ttio("sample.tio")

from ttio.exporters.jcampdx import write as write_jcampdx
write_jcampdx(spectrum, "out.jdx")
```

Dispatch on `##DATA TYPE=` between Raman and IR is automatic on
read. The writer emits deterministic `%.10g` AFFN output — byte-
identical across the three languages, proven by the cross-language
conformance harness (`python/tests/integration/test_raman_ir_cross_language.py`).

**Scope:** 1-D `##XYDATA=(X++(Y..Y))` only. Out of scope (tracked
for v0.11.1 / v0.12.0): 2-D NTUPLES blocks, PAC/SQZ/DIF
compressions, 2D-COS correlation maps, UV-Vis (`INFRARED SPECTRUM`
only; UV-Vis `##DATA TYPE=UV/VIS SPECTRUM` is rejected). See
`docs/vendor-formats.md` for the full import/export surface.

### 11.4 What did NOT change in v0.11

- No feature-flag additions (`base_v1` still covers both modalities).
- No change to mzML / nmrML / ISA-Tab writers.
- No change to existing MS / NMR classes.
- No change to per-AU encryption, transport, or provider surfaces.

v0.10 callers upgrade transparently; only codepaths that
explicitly want Raman or IR need to reach for the new classes.

## 12. Migrating from v1.1.x to v1.2 — genomic data + mixed-modality runs

v1.2 is the project's largest single-version expansion: an
end-to-end genomic data pathway alongside the spectroscopy/
spectrometry stack, plus a `Run` protocol that unifies the MS and
genomic surfaces. **Wire-format compatibility is a clean break
from v1.1.x readers** per Binding Decision §74 — the M80 rebrand
drops `mpgo` / `MPGO` for `ttio` / `TTIO`, the `.mpgo` extension
for `.tio`, and the `MO` transport magic for `TI`. There is no
dual-read shim. Files written by v1.1.x cannot be read by v1.2,
and vice versa.

### 12.1 Convert SAM / BAM / CRAM to TTI-O

The v1.2 line ships SAM/BAM (M87) and CRAM (M88) importers in all
three languages. They wrap `samtools view -h` as a subprocess —
no htslib link, no Python C-extension build — and produce a
`WrittenGenomicRun` ready to write through `SpectralDataset.write_minimal`.

```python
from ttio.importers.bam import BamReader
from ttio import SpectralDataset

# BAM → TTI-O
written_run = BamReader("sample.bam").to_genomic_run(name="run_0001")
SpectralDataset.write_minimal(
    "sample.tio",
    title="WGS sample 0001",
    isa_investigation_id="EXAMPLE:WGS:0001",
    runs={"run_0001": written_run},
)
```

CRAM additionally requires a reference FASTA:

```python
from ttio.importers.cram import CramReader

written_run = CramReader("sample.cram", "GRCh38.fa").to_genomic_run(
    name="run_0001",
)
```

Both readers accept an optional `region="chr1:1000-2000"` kwarg
that passes through verbatim to `samtools view` for region-scoped
imports. The shared `bam_dump` CLI auto-dispatches on `.cram`
paths via `--reference <fasta>` (M88.1). On the read side,
`GenomicRun` exposes per-read access via `run[i]` (returns
`AlignedRead`), plus
`GenomicIndex.indices_for_region(chrom, start, end)` for region
scans without decoding payloads.

### 12.2 Write a genomic run by hand (no SAM/BAM source)

```python
import numpy as np
from ttio import SpectralDataset, WrittenGenomicRun
from ttio.enums import AcquisitionMode

n = 4
reads = WrittenGenomicRun(
    acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
    reference_uri="GRCh38.p14",
    platform="ILLUMINA",
    sample_name="NA12878",
    positions=np.array([1000, 1100, 2000, 2100], dtype=np.int64),
    mapping_qualities=np.array([60, 60, 55, 55], dtype=np.uint8),
    flags=np.array([0, 0, 16, 16], dtype=np.uint32),
    sequences=np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8),
    qualities=np.full(8 * n, 30, dtype=np.uint8),
    offsets=np.arange(n, dtype=np.uint64) * 8,
    lengths=np.full(n, 8, dtype=np.uint32),
    cigars=["8M"] * n,
    read_names=[f"r{i}" for i in range(n)],
    mate_chromosomes=["*"] * n,
    mate_positions=np.full(n, -1, dtype=np.int64),
    template_lengths=np.zeros(n, dtype=np.int32),
    chromosomes=["chr1", "chr1", "chr2", "chr2"],
)
SpectralDataset.write_minimal(
    "sample.tio",
    title="manual write",
    isa_investigation_id="EXAMPLE:GEN:MANUAL",
    runs={"run_0001": reads},
)
```

The genomic codec stack (M83 rANS, M84 BASE_PACK, M85 quality
binning, M85.B name tokenisation, M86 pipeline wiring) attaches
via `signal_codec_overrides` on `WrittenGenomicRun`; see
[`docs/codecs/`](codecs/) for selection guidance.

### 12.3 Mixed-modality writes (Phase 1+2)

A single `.tio` may carry MS, NMR, and genomic runs. Pass them in
a single `runs={...}` dict — `write_minimal` dispatches on type:

```python
SpectralDataset.write_minimal(
    "multiomics.tio",
    title="NA12878 multi-omics",
    isa_investigation_id="EXAMPLE:OMICS:0001",
    runs={
        "wgs_run":         genomic_run,    # WrittenGenomicRun
        "proteomics_run":  ms_run,          # WrittenRun
        "metabolomics_run": nmr_run,        # WrittenRun
    },
)
```

Read-side cross-modality query uses the modality-agnostic
helpers introduced in Phase 1+2:

```python
ds = SpectralDataset.open("multiomics.tio")

# All runs across modalities (canonical accessor)
for name, run in ds.runs.items():
    print(name, type(run).__name__, len(run))

# Filter by sample URI (matches against provenance input_refs).
# Cross-modality requires that runs share a sample-keyed
# provenance input_ref — see python/tests/integration/test_m91_*.py
# for the canonical pattern.
for name, run in ds.runs_for_sample("sample://NA12878").items():
    print(name, type(run).__name__, run.acquisition_mode)

# Filter by modality
from ttio import GenomicRun
genomic_only = ds.runs_of_modality(GenomicRun)
```

Both `AcquisitionRun` and `GenomicRun` conform to the `Run`
protocol (`name`, `acquisition_mode`, `__len__`, `__getitem__`,
`provenance_chain`), so client code can iterate without
bifurcating by modality.

### 12.4 What did NOT change

- Existing MS / NMR / Raman / IR / UV-Vis / 2D-COS APIs:
  unchanged. v1.1.x callers that only touch spectroscopy data
  upgrade transparently — `write_minimal(runs=...)` with an
  all-MS dict is the same call as `write_minimal(ms_runs=...)`
  (the latter remains supported as an alias).
- Per-AU encryption, transport, JCAMP-DX, mzTab, ISA-Tab,
  storage providers, signature verification: all unchanged.
- Format-version attribute: bumps from `1.3` to `1.4` only when
  genomic content is present; pure-spectroscopy files written by
  v1.2 still carry `@ttio_format_version = "1.3"` and round-trip
  on a v1.1.x reader (modulo the rebrand, see below).

### 12.5 The rebrand: identifiers that changed

| Old (v1.1.x and earlier) | New (v1.2) |
|---|---|
| `mpeg_o` Python package | `ttio` |
| `MPGOSpectralDataset` etc. | `TTIOSpectralDataset` |
| `.mpgo` file extension | `.tio` |
| `.mots` transport extension | `.tis` |
| Transport magic `"MO"` | `"TI"` |
| `result.to_mpgo(path)` | `result.to_ttio(path)` |

Code written against v1.1.x or earlier needs a one-time
sed-style rename. There is no dual-import shim.

## 13. See also

- `docs/api-review-v0.7.md` — three-column parity map (Python / ObjC / Java)
  with stability markers for every public class and method, plus
  Appendix A (stylistic differences), B (gap summary), and C
  (cross-language error-domain mapping).
- `docs/api-review-v0.6.md` — the v0.6 baseline (kept for diff visibility).
- `docs/format-spec.md` — on-disk HDF5 layout: group hierarchy, dataset names,
  attribute types, feature-flag encoding, v1.2 wrapped-key blob spec.
- `docs/feature-flags.md` — complete list of feature flags and their
  effects on the written file.
- `docs/providers.md` — storage provider feature matrix (HDF5 /
  Memory / SQLite / Zarr).
- `python/tests/test_importers.py` — pytest tests exercising both importers
  against the canonical fixtures, including `ImportResult` attribute validation,
  provenance mapping, and chromatogram decoding.
- `python/tests/test_cross_compat.py` — cross-language round-trip tests.
- `python/tests/test_compound_writer_parity.py` — cross-language
  compound-dataset byte-parity harness (M51).

