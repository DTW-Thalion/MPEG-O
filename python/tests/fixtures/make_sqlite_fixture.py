#!/usr/bin/env python3
"""Emit a canonical ``.tio.sqlite`` fixture for the Java cross-language test.

Builds the exact tree that ``SqliteProviderTest.mpegOShapedTreeRoundTrip``
constructs on the Java side, so the Java suite can read a *Python-written*
SQLite file and assert the provider's on-disk layout (little-endian BLOBs,
JSON compound rows, shared DDL + attribute typing) is cross-language
compatible. Invoked from
``SqliteProviderTest.crossLanguagePythonWrittenFileReadback`` via the repo's
venv Python; skipped there when the ``ttio`` package is not importable.

Usage::

    python make_sqlite_fixture.py <output-path.tio.sqlite>
"""
from __future__ import annotations

import sys

import numpy as np

from ttio.enums import Precision
from ttio.providers.base import CompoundField, CompoundFieldKind
from ttio.providers.sqlite import SqliteProvider

# Precision -> numpy dtype, so _pack() byte-encodes each channel at the
# declared width (matching the Java writer's precision tags).
_DTYPE = {
    Precision.UINT32: np.uint32,
    Precision.INT32: np.int32,
    Precision.FLOAT64: np.float64,
}


def _linspace(start: float, end: float, count: int) -> np.ndarray:
    # Matches Java SqliteProviderTest.linspace exactly:
    # arr[i] = start + (end - start) * i / (count - 1).
    i = np.arange(count, dtype=np.float64)
    return start + (end - start) * i / (count - 1)


def _ds(group, name, precision: Precision, values) -> None:
    arr = np.asarray(values, dtype=_DTYPE[precision])
    ds = group.create_dataset(name, precision, int(arr.shape[0]))
    ds.write(arr)


def build(path: str) -> None:
    p = SqliteProvider()
    p.open(path, mode="w")
    try:
        root = p.root_group()
        root.set_attribute("ttio_format_version", "0.6-sqlite")

        study = root.create_group("study")
        study.set_attribute("title", "End-to-end")

        runs = study.create_group("ms_runs")
        run0 = runs.create_group("run_0001")
        run0.set_attribute("acquisition_mode", 0)  # int -> value_type 'int'
        run0.set_attribute("spectrum_class", "TTIOMassSpectrum")

        idx = run0.create_group("spectrum_index")
        _ds(idx, "offsets", Precision.UINT32, [0, 4, 8])
        _ds(idx, "lengths", Precision.UINT32, [4, 4, 4])
        _ds(idx, "retention_times", Precision.FLOAT64, [1.0, 2.0, 3.0])
        _ds(idx, "ms_levels", Precision.INT32, [1, 1, 1])
        _ds(idx, "polarities", Precision.INT32, [1, 1, 1])
        _ds(idx, "precursor_mzs", Precision.FLOAT64, [0.0, 0.0, 0.0])
        _ds(idx, "precursor_charges", Precision.INT32, [0, 0, 0])
        _ds(idx, "base_peak_intensities", Precision.FLOAT64, [100.0, 200.0, 300.0])

        sig = run0.create_group("signal_channels")
        sig.set_attribute("channel_names", "mz,intensity")
        _ds(sig, "mz_values", Precision.FLOAT64, _linspace(100.0, 400.0, 12))
        _ds(sig, "intensity_values", Precision.FLOAT64, _linspace(1.0, 12.0, 12))

        cfg = run0.create_group("instrument_config")
        cfg.set_attribute("manufacturer", "Thermo")
        cfg.set_attribute("model", "Orbitrap Eclipse")

        idents = study.create_compound_dataset(
            "identifications",
            fields=[
                CompoundField(name="run_name", kind=CompoundFieldKind.VL_STRING),
                CompoundField(name="spectrum_index", kind=CompoundFieldKind.UINT32),
                CompoundField(name="chemical_entity", kind=CompoundFieldKind.VL_STRING),
                CompoundField(name="confidence_score", kind=CompoundFieldKind.FLOAT64),
            ],
            count=1,
        )
        idents.write([
            {
                "run_name": "run_0001",
                "spectrum_index": 0,
                "chemical_entity": "CHEBI:17234",
                "confidence_score": 0.95,
            }
        ])
    finally:
        p.close()


if __name__ == "__main__":
    if len(sys.argv) != 2:
        print("usage: make_sqlite_fixture.py <output.tio.sqlite>", file=sys.stderr)
        sys.exit(2)
    build(sys.argv[1])
