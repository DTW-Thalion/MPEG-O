# MPEG-O Test Strategy

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
| `requires_s3` | S3 / MinIO endpoint | `MPGO_S3_FIXTURE_URL` unset |
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
5. **Backward-compatibility** — every committed `.mpgo` fixture under
   `objc/Tests/Fixtures/mpgo/` (5 fixtures spanning v0.1-v0.8
   format layouts) must still open cleanly on the current Python
   reader.
6. **Well-formed XML baseline** — even when XSDs are unreachable, the
   mzML and nmrML outputs must parse via `lxml.etree.XMLParser`.

## CI topology

`.github/workflows/ci.yml` runs these jobs:

**On every push + PR:**

| Job | What |
|-----|------|
| `objc-build-test` | GNUstep + libobjc2 + libMPGO + test runner (1202 tests) |
| `python-test` | `tests/` default filter, Python 3.11 + 3.12 matrix |
| `java-test` | Maven `verify`, JDK 17 (232 tests) |
| `cross-compat` | Python smoke tests that subprocess into `MpgoVerify` + `MpgoSign` binaries |
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
- [x] Every committed historical `.mpgo` fixture still readable
- [x] Integration CI job added
- [x] Nightly stress CI job added
- [ ] Tag `v0.9.0` pushed — user-gated per binding decision

The three xfails are v1.0 concerns deliberately — they represent
real exporter defects that don't block v0.9 shipping. The tests run
in CI and surface the error log so the defects stay visible.
