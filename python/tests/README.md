# TTI-O Python test suite

## Running

```bash
cd python
pip install -e ".[test,import,crypto,codecs]"
pytest                                  # default CI filter
pytest -m stress                        # stress suite only
pytest tests/validation                 # cross-tool validation
pytest tests/integration tests/security # integration + security
```

The default invocation applies `-m "not stress and not
requires_network and not aspirational"`, so long-running or
network-gated tests auto-skip. The nightly CI unsets the filter
and runs the full set with a 10-minute-per-test timeout.

## Optional extras

```bash
# For the M64 cross-tool validation tests
pip install -e ".[integration]"

# For the M60 mzTab + M59 imzML cross-reader tests
pip install pyimzml pymzml pyteomics

# For the M64 ISA-Tab validation
pip install isatools
```

Each optional library is gated by its own `@pytest.mark.requires_X`
decorator. Tests auto-skip with a clear reason when the package
isn't importable.

## Layout

- `tests/` — unit + per-module correctness
- `tests/integration/` — format round-trips, vendor importers,
  cross-provider matrix
- `tests/security/` — encryption / signatures / key rotation
- `tests/validation/` — cross-language smoke + external-tool
  (XSD, pyteomics, pymzml, isatools)
- `tests/stress/` — nightly-only: 100 K spectra, concurrency,
  benchmarks
- `tests/fixtures/` — download registry + synthetic generators

See `docs/test-strategy.md` for the full layered-suite explanation
and CI topology.

## Environment variables

| Variable | Purpose |
|----------|---------|
| `TTIO_S3_FIXTURE_URL` | S3 / MinIO endpoint for cloud-access stress tests |
| `TTIO_BRUKER_TDF_FIXTURE` | Path to a real Bruker `.d` directory for timsTOF round-trip |
| `TTIO_MASSLYNX_FIXTURE` | Path to a Waters `.raw` directory for MassLynx round-trip |
| `TTIO_PYTHON` | Python interpreter path (Java + ObjC subprocess bruker_tdf_cli) |
| `THERMORAWFILEPARSER` | Path to ThermoRawFileParser binary |
| `MASSLYNXRAW` | Path to Waters MassLynx converter |
