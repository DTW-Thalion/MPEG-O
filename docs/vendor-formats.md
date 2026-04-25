# Vendor Format Integration Guide

This document covers the status and integration patterns for vendor-specific
mass spectrometry and NMR data formats in TTI-O.

## Thermo .raw (v0.6+ — delegation to ThermoRawFileParser)

**Status:** Implemented via delegation. No proprietary code ships
with TTI-O; the converter is resolved at runtime.

Thermo Scientific `.raw` files are the most common proprietary MS
format in proteomics and metabolomics. The format has no open spec;
reading it requires Thermo's closed-source `RawFileReader` .NET
assembly. The CompOmics team's [ThermoRawFileParser][trfp] wraps
that assembly in a CLI that emits mzML / MGF / parquet. TTI-O
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
metadata that the bridge drops is not carried into TTI-O by this
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

The Java `BrukerTDFReader` and Objective-C `TTIOBrukerTDFReader`
read SQLite metadata natively but subprocess to Python for binary
frame data. Python interpreter lookup order:

1. `TTIO_PYTHON` environment variable (absolute path).
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
takes an optional `TTIO_BRUKER_TDF_FIXTURE` environment variable
pointing at a real Bruker `.d` directory. When set, it round-trips
through `read()` and asserts that:

* Frame count matches `analysis.tdf`'s `Frames` table.
* The written `.tio` has `mz`, `intensity`, and `inv_ion_mobility`
  signal channels with identical shapes.
* m/z and intensity match the opentimspy reference extraction.

The test is skipped when the environment variable is not set
(i.e., on CI and when no real fixture is available).

### Command invoked (Java + ObjC)

```
<python> -m ttio.importers.bruker_tdf_cli \
    --input <path/to/run.d> \
    --output <path/to/target.tio> [--title "..."] [--ms2]
```

Exit codes: 0 = success, 2 = bad args, 3 = `opentimspy` missing, 4 = I/O.

### Scope

v0.8 M53 ships metadata + binary-data extraction. MS2 precursor
threading into the compound schema and native C ports of the frame
decoder (removing the Python helper dependency for Java and ObjC)
are v0.9 concerns.

## Waters MassLynx (v0.9 M63 — delegation pattern)

**Status:** Implemented via delegation, in all three languages. No
proprietary code ships with TTI-O; the converter is resolved at
runtime exactly like the Thermo integration.

Waters MassLynx raw data lives in `.raw` **directories** (same
extension as Thermo but a directory, not a file — a common source of
confusion). The format is undocumented; access requires Waters'
`MassLynxRaw` SDK or a community CLI wrapper. TTI-O delegates to
a user-installed `masslynxraw` command (or `MassLynxRaw.exe` on
Windows / via Mono), which emits mzML; TTI-O then parses the mzML
with its existing reader.

### Installation

Waters tooling is less standardised than Thermo's; the most common
deployment patterns are:

| Method | Command / path | Notes |
|---|---|---|
| **Community `masslynxraw` wrapper** | `pip install masslynxraw` then `masslynxraw -i <raw-dir> -o <out>` | Python wrapper; invokes the SDK via cffi. Requires the Waters SDK installed separately. |
| **Waters Connect API** | Vendor-provided MSI/DMG | Ships a `MassLynxRaw.exe` or equivalent CLI. |
| **In-house scripts** | Any argv-compatible `-i <raw-dir> -o <out-dir>` CLI | Pass an explicit `converter=` argument; TTI-O invokes it verbatim. |

### Binary resolution order

Same pattern as Thermo:

1. Explicit `converter=` argument (Python / Java) or
   `converter:` kwarg (ObjC).
2. `MASSLYNXRAW` environment variable.
3. `masslynxraw` on `PATH` (native).
4. `MassLynxRaw.exe` on `PATH` — invoked via `mono` on non-Windows.

When resolution fails, all three implementations raise a
`FileNotFoundError` / `IOException` / `NSError` with a pointer to
this document.

### API

| Language | Entry point |
|---|---|
| Python | `ttio.importers.waters_masslynx.read(raw_dir, *, converter=None)` |
| ObjC | `+[TTIOWatersMassLynxReader readFromDirectoryPath:converter:error:]` |
| Java | `WatersMassLynxReader.read(String dirPath, String converter)` |

### CLI contract

TTI-O invokes the converter with:

```
<converter> -i <input-raw-dir> -o <output-dir>
```

and expects an `.tio`-ready mzML in the output directory, named
`<basename>.mzML` where `<basename>` is the `.raw` directory name with
its trailing `.raw` stripped. If the converter uses different flags,
wrap it with a small shim that accepts the TTI-O contract.

### Testing without Waters tooling

The test suites ship a POSIX shell **mock converter** that emits a
fixed-size stub mzML. This proves the delegation pipeline
(resolver → subprocess → output parse) end-to-end without installing
the vendor SDK:

* Python: `tests/integration/test_waters_masslynx.py::test_mock_converter_roundtrip`
* ObjC: `Tests/TestWatersMassLynxReader.m` (the "mock converter" set)
* Java: `WatersMassLynxReaderTest.mockConverter_roundTrip`

Set `TTIO_MASSLYNX_FIXTURE` to a real Waters `.raw` directory and
ensure `masslynxraw` is on PATH to exercise the vendor-tooling path
in nightly CI.

## JCAMP-DX 5.01 (v0.11 M73 — vibrational spectra; v0.11.1 M73.1 adds compression + UV-Vis)

**Status:** Native reader and writer in all three languages.
No external dependency; the format is plain ASCII with a documented
IUPAC spec.

JCAMP-DX is the de-facto interchange format for 1-D vibrational
spectra (Raman, IR, UV-Vis, NMR). M73 targets the AFFN
`##XYDATA=(X++(Y..Y))` dialect at spec level 5.01 — the most
interoperable subset. Writers in all three languages emit AFFN only
(bit-accurate round-trips over the byte savings). Readers in v0.11.1
additionally decode the §5.9 compressed dialects (PAC / SQZ / DIF /
DUP); see "Compressed-form reader" below.

### API

| Language | Reader | Writer |
|---|---|---|
| Python | `ttio.importers.jcamp_dx.read_spectrum(path)` | `ttio.exporters.jcamp_dx.write_raman_spectrum` / `write_ir_spectrum` / `write_uv_vis_spectrum` |
| ObjC | `+[TTIOJcampDxReader readSpectrumFromPath:error:]` | `+[TTIOJcampDxWriter writeRamanSpectrum:...]` / `writeIRSpectrum:` / `writeUVVisSpectrum:` |
| Java | `JcampDxReader.readSpectrum(Path)` | `JcampDxWriter.writeRamanSpectrum` / `writeIRSpectrum` / `writeUVVisSpectrum` |

The reader dispatches on `##DATA TYPE=`:
`RAMAN SPECTRUM` → `RamanSpectrum`;
`INFRARED ABSORBANCE` / `INFRARED TRANSMITTANCE` → `IRSpectrum`
with the matching `TTIOIRMode`; `INFRARED SPECTRUM` falls back to
`##YUNITS=` for mode detection (`ABSORBANCE` substring →
absorbance, otherwise transmittance);
`UV/VIS SPECTRUM` / `UV-VIS SPECTRUM` / `UV/VISIBLE SPECTRUM` →
`UVVisSpectrum` (v0.11.1). Any other `DATA TYPE` is rejected.

### Compressed-form reader (v0.11.1)

The reader auto-detects SQZ / DIF / DUP / PAC bodies by scanning
for compression sentinel chars (`@A-IJ-Ra-ij-rSTUVWXYZs`), excluding
`e`/`E` so AFFN scientific notation (`1.2e-3`) doesn't false-trigger.
On a compressed body, it delegates to a per-language decoder:

| Language | Decoder |
|---|---|
| Python | `ttio.importers._jcamp_decode.decode_xydata` |
| ObjC | `+[TTIOJcampDxDecode decodeLines:firstx:deltax:xfactor:yfactor:outXs:outYs:error:]` |
| Java | `com.dtwthalion.ttio.importers.JcampDxDecode.decode` |

Each decoder implements the full SQZ alphabet (`@`, `A-I`, `a-i`),
DIF alphabet (`%`, `J-R`, `j-r`), DUP alphabet (`S-Z`, `s`), plus
the DIF Y-check convention (the repeated leading Y of the next
line, within 1e-9 of the previous line's last Y, is dropped) and
X-reconstruction from `##FIRSTX=` / `##LASTX=` / `##NPOINTS=`.

### Wire-level determinism

All three writers emit LDRs in a fixed order with `%.10g`
floating-point formatting. Given the same logical spectrum, the
three writers produce byte-identical output. This is verified by
`python/tests/integration/test_raman_ir_cross_language.py::test_jcamp_layout_is_deterministic`,
which locks the LDR prefix so a drift between language
implementations is caught in code review.

The cross-language conformance harness additionally feeds a
Python-generated `.jdx` to small subprocess drivers built on top
of the ObjC (`objc/Tools/TtioJcampDxDump`) and Java (compiled
ad-hoc into `/tmp/mpgo_m73_driver/`) readers, then compares the
parsed `(wavenumber, intensity)` arrays bit-for-bit. The tests
skip on dev boxes where the ObjC/Java sides aren't built and run
in full in CI.

### What is NOT covered

* 2-D JCAMP-DX (`##NTUPLES=`, `##PAGE=`) for imaging / 2-D NMR —
  ASCII cubes are impractical at 10–100 MB per map. Raman and IR
  cubes are stored in native HDF5 groups (`docs/format-spec.md`
  §7a) instead.
* Compressed **writers** — all three languages emit AFFN only. A
  compressed input can be round-tripped through the reader and
  re-emitted as AFFN without loss.
* Mass-spectrum `##DATA TYPE=` variants (`MASS SPECTRUM`) — the
  reader rejects them explicitly. Mass spectra round-trip through
  mzML.

### M73.1 additions (v0.11.1)

* PAC / SQZ / DIF / DUP compressed `##XYDATA=` reader in all three
  languages.
* `UVVisSpectrum` class and `UV/VIS SPECTRUM` / `UV-VIS SPECTRUM` /
  `UV/VISIBLE SPECTRUM` reader dispatch.
* `UVVisSpectrum` JCAMP-DX writer emitting `##DATA TYPE=UV/VIS
  SPECTRUM` with `##XUNITS=NANOMETERS`, `##YUNITS=ABSORBANCE`, and
  `##$PATH LENGTH CM` / `##$SOLVENT` custom LDRs.
