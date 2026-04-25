# TTI-O — Python Implementation

Python reader/writer for the TTI-O multi-omics data standard (`.tio` files).
Byte-compatible with the Objective-C reference implementation — see
[`../docs/format-spec.md`](../docs/format-spec.md) for the normative HDF5 layout.

## Install (development)

```bash
cd python
python -m venv .venv
. .venv/bin/activate
pip install -e ".[test,import,crypto]"
pytest
```

Requires Python 3.11+ and a system HDF5 library (`libhdf5-dev` on Ubuntu).

## Usage

```python
from ttio import SpectralDataset

with SpectralDataset.open("example.tio") as ds:
    run = ds.ms_runs["run_0001"]
    spectrum = run[0]
    mz = spectrum.mz_array.data        # numpy float64 array
    intensity = spectrum.intensity_array.data
```

## Licensing

- **Core** (`ttio` package, excluding `importers/` and `exporters/`): LGPL-3.0-or-later
- **Importers / exporters** (`ttio.importers`, `ttio.exporters`): Apache-2.0

## Cross-compatibility

The `tests/test_cross_compat.py` suite reads every reference fixture under
`../objc/Tests/Fixtures/ttio/` and, when the ObjC build tree is available,
verifies Python-written files through the `ttio-verify` tool. This guarantees
byte-for-byte interoperability with the Objective-C reference implementation.
