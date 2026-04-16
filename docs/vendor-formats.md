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

## Bruker TDF (v0.5+ — deferred)

**Status:** Not started; deferred to v0.5+.

Bruker timsTOF data is stored in `.d` directories containing a `analysis.tdf`
SQLite database plus binary `.tdf_bin` frame files. The `timsdata` C library
(Bruker-provided, free license) is required for frame decompression.

**Integration path:** Wrap `timsdata.dll`/`libtimsdata.so` via FFI. Each
TIMS frame maps to a set of MPEG-O spectra indexed by mobility (1/K0).

## Waters MassLynx (v0.5+ — deferred)

**Status:** Not started; deferred to v0.5+.

Waters MassLynx raw data lives in `.raw` directories (confusingly, same
extension as Thermo but a directory, not a file). The format is
undocumented; the community `masslynxreader` Python package provides
partial read support.

**Integration path:** Use `masslynxreader` for Python; C/ObjC would need
a port or FFI bridge.
