# Vendor Format Integration Guide

This document covers the status and integration patterns for vendor-specific
mass spectrometry and NMR data formats in MPEG-O.

## Thermo .raw (v0.6+ — delegation to ThermoRawFileParser)

**Status:** Implemented via delegation. No proprietary code ships
with MPEG-O; the converter is resolved at runtime.

Thermo Scientific `.raw` files are the most common proprietary MS
format in proteomics and metabolomics. The format has no open spec;
reading it requires Thermo's closed-source `RawFileReader` .NET
assembly. The CompOmics team's [ThermoRawFileParser][trfp] wraps
that assembly in a CLI that emits mzML / MGF / parquet. MPEG-O
delegates to that CLI and parses the emitted mzML with its existing
reader.

[trfp]: https://github.com/compomics/ThermoRawFileParser

### Installation

| Method | Command | Notes |
|---|---|---|
| **Conda/Mamba** | `conda install -c bioconda thermorawfileparser` | Ships a self-contained build; no Mono needed. |
| **BioContainers (Docker)** | `docker pull quay.io/biocontainers/thermorawfileparser:<tag>` | Bind-mount your `.raw` into the container. |
| **Release tarball** | Download `ThermoRawFileParser.zip` from the [releases page][trfp-rel] | Requires Mono ≥ 6.x for the `.exe` build; the self-contained Linux build needs no extra runtime. |
| **Nix** | `nix-shell -p thermorawfileparser` | |

[trfp-rel]: https://github.com/compomics/ThermoRawFileParser/releases

### Binary resolution (all three languages)

1. Explicit argument (`thermorawfileparser=` in Python;
   `ThermoRawReader.read(path, binPath)` in Java; env var for ObjC).
2. `THERMORAWFILEPARSER` environment variable (absolute path).
3. `ThermoRawFileParser` on `PATH` (.NET 8 self-contained build).
4. `ThermoRawFileParser.exe` on `PATH` — invoked via `mono` if present.

If none resolves, the importer raises a clear error that references
this document. The input file is validated **before** the binary
lookup, so missing-file errors surface even when the parser isn't
installed.

### Command invoked

```
<binary> -i <path/to/sample.raw> -o <tmpdir> -f 2
```

`-f 2` selects mzML output. The importer reads
`<tmpdir>/<stem>.mzML` — or the first `*.mzML` in the temp dir if
naming differs — via the existing mzML parser, then deletes the temp
directory.

### What is recovered

Everything the mzML bridge preserves: scan headers (RT, MS level,
polarity, precursor m/z + charge), profile or centroid m/z + intensity
arrays, TIC/BPC chromatograms. Thermo-specific extended method
metadata that the bridge drops is not carried into MPEG-O by this
path — if that data is load-bearing, you will need a direct reader.

## Bruker TDF (v0.8 M53 — shipped)

**Status:** Implemented. Metadata reads natively in all three
languages; binary frame decompression uses `opentimspy` (Python) or
delegates to the Python helper via subprocess (Java, Objective-C).

Bruker timsTOF `.d` directories hold two files:

* `analysis.tdf` — a plain SQLite database with metadata tables
  (`Frames`, `GlobalMetadata`, `Properties`, `Precursors`, ...).
* `analysis.tdf_bin` or `analysis.tdf_raw` — a binary blob with
  ZSTD-compressed frame data plus a scan-to-ion index.

The SQLite half is openly readable from the standard library in
every language. The binary half is read via the open-source
[`opentimspy`][opentimspy] Python package (wraps `libtimsdata.so` from
the paired [`opentims-bruker-bridge`][bridge] wheel). **No proprietary
Bruker SDK is involved** — the bridge wheel embeds the open reference
implementation of the documented frame format.

[opentimspy]: https://pypi.org/project/opentimspy/
[bridge]: https://pypi.org/project/opentims-bruker-bridge/

### Installation

```bash
pip install 'mpeg-o[bruker]'
```

This pulls `opentimspy` + `opentims-bruker-bridge`. The bridge wheel
ships prebuilt `libtimsdata.so` (Linux), `libtimsdata.dylib` (macOS),
and `libtimsdata.dll` (Windows) — no extra toolchain required.

### Binary path resolution (Java + Objective-C)

The Java `BrukerTDFReader` and Objective-C `MPGOBrukerTDFReader`
read SQLite metadata natively but subprocess to Python for binary
frame data. Python interpreter lookup order:

1. `MPGO_PYTHON` environment variable (absolute path).
2. `python3` on `PATH`.
3. `python` on `PATH`.

The chosen interpreter must have `mpeg-o[bruker]` installed.

### What is recovered

Per-peak arrays for every MS1 frame (MS2 optional via `--ms2` /
`ms2=True`):

* **m/z** — calibrated mass-to-charge, float64 Da.
* **intensity** — raw peak intensity, float64.
* **inv_ion_mobility** — inverse reduced ion mobility (1/K₀),
  float64 Vs/cm². This is the **third signal channel** added in
  v0.8 M53 — timsTOF frames are 2-D acquisitions and the ion-mobility
  axis must round-trip per-peak, not per-spectrum.

Frame-level metadata (retention time, MS level) and instrument
config (vendor, model, acquisition software) are populated from the
`Frames`, `GlobalMetadata`, and `Properties` tables.

### Round-trip verification

The Python test `tests/test_bruker_tdf.py::test_real_tdf_round_trip`
takes an optional `MPGO_BRUKER_TDF_FIXTURE` environment variable
pointing at a real Bruker `.d` directory. When set, it round-trips
through `read()` and asserts that:

* Frame count matches `analysis.tdf`'s `Frames` table.
* The written `.mpgo` has `mz`, `intensity`, and `inv_ion_mobility`
  signal channels with identical shapes.
* m/z and intensity match the opentimspy reference extraction.

The test is skipped when the environment variable is not set
(i.e., on CI and when no real fixture is available).

### Command invoked (Java + ObjC)

```
<python> -m mpeg_o.importers.bruker_tdf_cli \
    --input <path/to/run.d> \
    --output <path/to/target.mpgo> [--title "..."] [--ms2]
```

Exit codes: 0 = success, 2 = bad args, 3 = `opentimspy` missing, 4 = I/O.

### Scope

v0.8 M53 ships metadata + binary-data extraction. MS2 precursor
threading into the compound schema and native C ports of the frame
decoder (removing the Python helper dependency for Java and ObjC)
are v0.9 concerns.

## Waters MassLynx (v0.5+ — deferred)

**Status:** Not started; deferred to v0.5+.

Waters MassLynx raw data lives in `.raw` directories (confusingly, same
extension as Thermo but a directory, not a file). The format is
undocumented; the community `masslynxreader` Python package provides
partial read support.

**Integration path:** Use `masslynxreader` for Python; C/ObjC would need
a port or FFI bridge.
