# TTI-O Test Strategy

This document describes the layered test suite introduced by v0.9 and
how CI exercises each layer. It covers all three language
implementations (Python, Java, ObjC) and both the default pull-request
path and the nightly stress job.

## Layered test suites

The Python test suite is organised into five sibling directories, each
covering a distinct concern:

| Directory | Purpose | Default CI | Nightly CI |
|-----------|---------|:----------:|:----------:|
| `tests/` (flat root) | Unit + per-module correctness (120 ms - 60 s) | ✅ | ✅ |
| `tests/integration/` | Format round-trips, vendor importers, cross-provider | ✅ | ✅ |
| `tests/security/` | Encryption lifecycle, key rotation, signature verification | ✅ | ✅ |
| `tests/validation/` | Cross-language smoke, external-tool (XSD, pyteomics) | ✅ | ✅ |
| `tests/stress/` | 100K spectra, 4-thread concurrency, provider benchmarks | — | ✅ |

Java and ObjC don't split along these lines — they use a single test
tree (`java/src/test/java/...` and `objc/Tests/*.m`) and cover the
same concerns through individual test files.

## Marker-based gating

`python/tests/conftest.py` registers these markers. The default
pytest invocation applies the filter
`-m "not stress and not requires_network and not aspirational"`.

| Marker | Gates on | Auto-skip when |
|--------|----------|---------------|
| `stress` | Long-running fixtures + benchmarks | default filter |
| `requires_network` | Fixture downloads, XSD fetches | default filter |
| `requires_s3` | S3 / MinIO endpoint | `TTIO_S3_FIXTURE_URL` unset |
| `requires_pyteomics` | Third-party cross-reader | `pyteomics` not importable |
| `requires_pymzml` | Third-party cross-reader | `pymzml` not importable |
| `requires_isatools` | Third-party validator | `isatools` not importable |
| `requires_pyimzml` | imzML reader cross-check | `pyimzml` not importable |
| `requires_opentims` | Bruker timsTOF decoder | `opentimspy` not importable |
| `requires_thermorawfileparser` | Thermo delegation | CLI not on PATH |

The auto-skip hook is implemented in `pytest_collection_modifyitems`
— if a test carries `@pytest.mark.requires_X` but package `X` isn't
importable, it's converted to a `skip` at collection time with a
helpful reason string.

## Fixture management

`tests/fixtures/download.py` is the single source of truth for
pinned external fixtures. Each `FixtureSpec` carries:

- `url` (GitHub raw, PSI mirror, or stable archive) *or*
- `in_repo_path` (committed under `objc/Tests/Fixtures/`)

URL fixtures are SHA-256-pinned in `checksums.json`; in-repo
fixtures are tracked by git. Run
`python -m tests.fixtures.download fetch <name>` to cache a network
fixture locally — tests call `downloaded_fixture("name")` to
resolve it or skip cleanly.

Synthetic fixtures (deterministic seeded numpy arrays) are produced
by `tests/fixtures/generate.py`. They're cached per session under
`tests/fixtures/_generated/` and regenerate automatically when
absent.

## v0.9 M64 — Cross-tool validation

`tests/validation/test_m64_cross_tool_validation.py` adds:

1. **PSI mzML 1.1 XSD validation** via `lxml.etree.XMLSchema` against
   the PSI upstream schema. Gated `@requires_network` for schema
   download; xfailed on the known `<precursor>/<activation>` defect
   until the v1.0 mzML-fidelity milestone.
2. **nmrML XSD validation** — same pattern. xfailed until nmrML
   exporter emits the `version` attribute and canonical element order.
3. **pyteomics + pymzml cross-reader tests** — assert that third-party
   mzML consumers successfully open and iterate our exports.
4. **ISA-Tab isatools validation** — assert our bundle passes the
   isatools validator. xfailed on the known INVESTIGATION
   PUBLICATIONS-section gap until v1.0.
5. **Backward-compatibility** — every committed `.tio` fixture under
   `objc/Tests/Fixtures/ttio/` (5 fixtures spanning v0.1-v0.8
   format layouts) must still open cleanly on the current Python
   reader.
6. **Well-formed XML baseline** — even when XSDs are unreachable, the
   mzML and nmrML outputs must parse via `lxml.etree.XMLParser`.

## CI topology

`.github/workflows/ci.yml` runs these jobs:

**On every push + PR:**

| Job | What |
|-----|------|
| `objc-build-test` | GNUstep + libobjc2 + libTTIO + test runner (307 tests as of v0.11.0) |
| `python-test` | `tests/` default filter, Python 3.11 + 3.12 matrix (1443 tests as of v0.11.0) |
| `java-test` | Maven `verify`, JDK 17 (695 tests as of v0.11.0) |
| `cross-compat` | Python smoke tests that subprocess into `TtioVerify` + `TtioSign` binaries (44 combinations as of v0.11.0) |
| `python-validation` | `tests/validation + tests/integration + tests/security` with `[integration]` extras installed |

**Nightly (02:30 UTC):**

| Job | What |
|-----|------|
| `python-stress` | `tests/stress` 100 K-spectrum, concurrent-read, provider benchmark suite with 10 min/test timeout |

The cross-compat job gates on `objc-build-test` + `python-test` +
`java-test` so a stack break in any language surfaces before the
subprocess verification runs.

## Release readiness checklist (M64 acceptance)

- [x] mzML writer output parses in pyteomics + pymzml
- [x] mzML PSI XSD validation ran (xfailed on activation defect)
- [x] nmrML well-formed XML verified
- [x] nmrML XSD validation ran (xfailed on version attribute)
- [x] isatools validator ran against ISA-Tab output (xfailed on PUBLICATIONS section)
- [x] Every committed historical `.tio` fixture still readable
- [x] Integration CI job added
- [x] Nightly stress CI job added
- [x] Tag `v0.9.0` pushed (`eaac284`)

The three xfails are v1.0 concerns deliberately — they represent
real exporter defects that don't block v0.9 shipping. The tests run
in CI and surface the error log so the defects stay visible.

## v0.11 M73 — Raman/IR cross-language conformance

`python/tests/integration/test_raman_ir_cross_language.py` adds a
subprocess-driven harness that proves JCAMP-DX 5.01 AFFN output is
bit-identical across the Python / Java / ObjC writers, and that each
implementation's reader accepts every other's output. The ObjC CLI
driver (`TtioJcampDxDump`) ships under `objc/Tools/`; the Java driver
is built ad-hoc into `/tmp/` per test run. Runtime resolution of
`libTTIO.so.0` in the ObjC subprocess path uses an injected
`LD_LIBRARY_PATH` pointing at `objc/Source/obj`. The harness
contributes 6 tests to the 44 cross-compat-job total.

## v1.0 — genomic transport cross-language conformance

Two parallel 3×3 (writer × reader) Python/Java/ObjC matrices live
under `python/tests/validation/`:

- **`test_m89_cross_language.py`** — per-AU mode. Asserts semantic
  round-trip of chromosomes, positions, mapping_qualities, flags,
  sequences, and qualities for each of the 9 (writer, reader)
  cells. The `mate_chromosome` SAM sentinels (`=`, `""`) are
  deliberately not asserted verbatim — the v2 mate codec
  normalizes them at write time, so per-AU mode delivers a
  semantic round-trip rather than a byte-verbatim one. 9 cells.
- **`test_phase_2c_t_bulk_mode.py`** — bulk mode (Phase 2c-T).
  Same 3×3 matrix, same fixture skeleton but richer (varied
  read_names, mate_chromosomes mix of `=`/explicit chrom). Adds a
  byte-identity assertion: the `mate_info/inline_v2` and
  `read_names` (NAME_TOKENIZED_V2) blobs in the round-tripped
  `.tio` MUST equal the source `.tio`'s blob bytes. This proves
  the bulk-mode wire contract (`bulk_mode_v2_blobs` feature
  flag) holds across all 9 language combinations. 9 cells.

Both suites require `libttio_rans` at runtime
(`TTIO_RANS_LIB_PATH` env var, or `native/_build/libttio_rans.so`
on a default WSL build); the bulk-mode suite skips entirely when
the library cannot be located. The Java cells additionally require
the JNI library directory on `java.library.path` — handled
automatically by the resolver in `test_cross_language_smoke.py`.

Storage-provider parity for bulk mode is covered by
`python/tests/validation/test_phase_2c_t_storage_providers.py`,
which writes a `WrittenGenomicRun` carrying `bulk_v2_blobs` into
each of `memory://`, `sqlite://`, and (when the optional `zarr`
extra is installed) `zarr://`, then asserts the on-disk blob
bytes match the source HDF5 file's blobs.

## Optional vendor-format test fixtures

Most Python tests run end-to-end without external setup. A handful
of vendor-format integration tests are gated on user-supplied
fixtures (proprietary instrument data) plus optional binary tools.
Each gate degrades to a clean `pytest.skip(...)` when its
prerequisites are missing, so a default `pytest` invocation never
errors on these.

### Thermo `.raw` delegation

`python/tests/integration/test_thermo_delegation.py` shells out to
the user-installed `ThermoRawFileParser` CLI. The end-to-end
`test_thermo_raw_to_ttio_delegation` cell needs both:

1. **The CLI on `PATH`** — gated by `shutil.which("ThermoRawFileParser")`
   (or the lowercase alias) in `python/tests/conftest.py`. The
   conftest auto-skips when the binary is missing; cells that
   exercise the missing-binary error path still run.
2. **A real `.raw` fixture** at `TTIO_THERMO_RAW_FIXTURE`.

Reproducible setup that unblocks the Thermo delegation test:

```bash
# Linux (WSL Ubuntu 24.04). The v1.4.5 release runs on Mono.
sudo apt install -y mono-complete

mkdir -p ~/opt/ThermoRawFileParser
curl -sL -o /tmp/trfp.zip \
  https://github.com/CompOmics/ThermoRawFileParser/releases/download/v1.4.5/ThermoRawFileParser1.4.5.zip
unzip -q -o /tmp/trfp.zip -d ~/opt/ThermoRawFileParser

cat > ~/.local/bin/ThermoRawFileParser <<'EOF'
#!/usr/bin/env bash
exec mono "$HOME/opt/ThermoRawFileParser/ThermoRawFileParser.exe" "$@"
EOF
chmod +x ~/.local/bin/ThermoRawFileParser

# Public test fixture from the upstream repo (~1.5 MB, MIT-licensed).
mkdir -p ~/fixtures/thermo
curl -sL -o ~/fixtures/thermo/small.RAW \
  https://raw.githubusercontent.com/compomics/ThermoRawFileParser/master/ThermoRawFileParserTest/Data/small.RAW

export PATH="$HOME/.local/bin:$PATH"
export TTIO_THERMO_RAW_FIXTURE="$HOME/fixtures/thermo/small.RAW"
pytest python/tests/integration/test_thermo_delegation.py
```

### Bruker `.d` (TDF)

`python/tests/test_bruker_tdf.py` and
`python/tests/integration/test_bruker_tdf_integration.py` need:

1. **`opentimspy` + `opentims-bruker-bridge`** — `pip install ttio[bruker]`
   (or `pip install opentimspy opentims-bruker-bridge`). The
   bridge package ships the `libtimsdata.so` Bruker reader.
2. **A real `.d` directory** at `TTIO_BRUKER_TDF_FIXTURE`.

A small public fixture (~1 MB total) ships in the ProteoWizard
test corpus under Apache-2.0 licensing:

```bash
mkdir -p ~/fixtures/bruker/diaPASEF.d
base="https://raw.githubusercontent.com/ProteoWizard/pwiz/master/pwiz/data/vendor_readers/Bruker/Reader_Bruker_Test.data/diaPASEF.d"
curl -sL -o ~/fixtures/bruker/diaPASEF.d/analysis.tdf     "$base/analysis.tdf"
curl -sL -o ~/fixtures/bruker/diaPASEF.d/analysis.tdf_bin "$base/analysis.tdf_bin"

export TTIO_BRUKER_TDF_FIXTURE=~/fixtures/bruker/diaPASEF.d
pytest python/tests/test_bruker_tdf.py \
       python/tests/integration/test_bruker_tdf_integration.py
```

### Waters `.raw` (MassLynx)

`python/tests/integration/test_waters_masslynx.py` is more
constrained because the converter (`masslynxraw` /
`MassLynxRaw.exe`) is built on the proprietary Waters MassLynxRaw
SDK and ships only on Windows. The error-contract and
mock-converter cells (`test_missing_binary_raises_clear_error`,
`test_missing_input_raises_filenotfound`,
`test_file_not_directory_raises`, `test_mock_converter_roundtrip`,
`test_env_var_override`) always run and exercise the delegation
pipeline end-to-end via a tiny shell stub.

The real-fixture cell `test_real_masslynx_roundtrip` is gated on
both:

1. **A `masslynxraw` / `MassLynxRaw.exe` binary on PATH** —
   Windows-only, license-gated. Linux developers can use a
   `wine`-wrapped MassLynxRaw.exe in principle, but verifying the
   licensing and bundled DLLs is out of scope here.
2. **A Waters `.raw` directory** at `TTIO_MASSLYNX_FIXTURE`. A
   tiny public fixture (~2 KB total, Apache-2.0 licensed) is
   available from ProteoWizard's test corpus under
   `pwiz/data/vendor_readers/Waters/Reader_Waters_Test.data/Minimal_DDA.raw/`
   (12 small files: `_FUNC{001..003}.{DAT,IDX,STS}`, `_FUNCTNS.INF`,
   `_HEADER.TXT`, `_extern.inf`).

The fixture alone is not sufficient — without the converter
binary, the test will skip cleanly with
`"masslynxraw / MassLynxRaw.exe not on PATH"`.
