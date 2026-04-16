# Vendor Format Integration Guide

This document covers the status and integration patterns for vendor-specific
mass spectrometry and NMR data formats in MPEG-O.

## Thermo .raw (v0.5+ — stub in v0.4)

**Status:** API stub defined; implementation deferred.

Thermo Scientific `.raw` files are the most common proprietary MS format
in proteomics and metabolomics. They are binary, undocumented, and can
only be read via the **Thermo RawFileReader SDK** (free-as-in-beer
license, Windows/.NET only) or community wrappers.

**Integration path (v0.5+):**

* **ObjC:** Link against a C wrapper around `ThermoFisher.CommonCore.RawFileReader`
  (via Mono/.NET interop or a pre-built native bridge). The `MPGOThermoRawReader`
  class defines the stable API.
* **Python:** Use `pythonnet` to call the .NET SDK, or use the
  `pymsfilereader` / `pyRawFileReader` community packages.
* **Java:** JNI bridge to the .NET SDK via jni4net or similar.

**Key data to extract:** scan headers (RT, MS level, polarity, precursor
m/z/charge), profile or centroid m/z+intensity arrays, TIC/BPC
chromatograms, instrument method metadata.

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
