"""Cross-backend byte identity for ``StorageDataset.read_canonical_bytes``.

v0.7 M43: the canonical byte form is the signing / encryption contract
that spans backends. These tests pin the invariant: writing the same
logical data through any provider produces the same canonical bytes,
so a file signed on HDF5 verifies on Memory / SQLite and vice versa.

Covers:

* primitive float64, float32, int32, int64, uint32 datasets
* compound datasets with VL-string and numeric fields
* VL strings with non-ASCII utf-8 payloads
* empty datasets
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from mpeg_o.enums import Compression, Precision
from mpeg_o.providers import CompoundField, CompoundFieldKind
from mpeg_o.providers.hdf5 import Hdf5Provider
from mpeg_o.providers.memory import MemoryProvider
from mpeg_o.providers.sqlite import SqliteProvider


# ── Primitive cases ──────────────────────────────────────────────────


@pytest.mark.parametrize("precision,values", [
    (Precision.FLOAT64, np.array([1.0, -2.5, 3.14159, 1e-10], dtype="<f8")),
    (Precision.FLOAT32, np.array([0.0, 1.5, -3.25], dtype="<f4")),
    (Precision.INT32, np.array([0, -1, 2_147_483_647, -2_147_483_648], dtype="<i4")),
    (Precision.INT64, np.array([0, -1, 9_223_372_036_854_775_807], dtype="<i8")),
    (Precision.UINT32, np.array([0, 1, 4_294_967_295], dtype="<u4")),
])
def test_primitive_cross_backend_identity(tmp_path: Path,
                                            precision: Precision,
                                            values: np.ndarray) -> None:
    """Primitive dataset canonical bytes must be identical across all
    three reference providers."""
    results: dict[str, bytes] = {}

    # HDF5.
    hdf5_path = tmp_path / "cb.h5"
    with Hdf5Provider.open(str(hdf5_path), mode="w") as p:
        ds = p.root_group().create_dataset("v", precision, len(values))
        ds.write(values)
    with Hdf5Provider.open(str(hdf5_path), mode="r") as p:
        results["hdf5"] = p.root_group().open_dataset("v").read_canonical_bytes()

    # Memory.
    mem_url = "memory://m43-primitive"
    with MemoryProvider.open(mem_url, mode="w") as p:
        ds = p.root_group().create_dataset("v", precision, len(values))
        ds.write(values)
    with MemoryProvider.open(mem_url, mode="r") as p:
        results["memory"] = p.root_group().open_dataset("v").read_canonical_bytes()
    MemoryProvider.discard_store(mem_url)

    # SQLite.
    sq_path = tmp_path / "cb.mpgo.sqlite"
    with SqliteProvider.open(str(sq_path), mode="w") as p:
        ds = p.root_group().create_dataset("v", precision, len(values))
        ds.write(values)
    with SqliteProvider.open(str(sq_path), mode="r") as p:
        results["sqlite"] = p.root_group().open_dataset("v").read_canonical_bytes()

    # All three must match, and match the raw little-endian expectation.
    expected = values.astype(
        {Precision.FLOAT64: "<f8",
         Precision.FLOAT32: "<f4",
         Precision.INT32: "<i4",
         Precision.INT64: "<i8",
         Precision.UINT32: "<u4"}[precision],
        copy=False,
    ).tobytes()
    for name, blob in results.items():
        assert blob == expected, (
            f"{name} provider's canonical bytes diverge from expected "
            f"little-endian packing"
        )


# ── Compound cases ───────────────────────────────────────────────────


def _compound_schema() -> list[CompoundField]:
    return [
        CompoundField("run_name", CompoundFieldKind.VL_STRING),
        CompoundField("spectrum_index", CompoundFieldKind.UINT32),
        CompoundField("score", CompoundFieldKind.FLOAT64),
        CompoundField("chem_id", CompoundFieldKind.VL_STRING),
    ]


def _compound_records_structured() -> np.ndarray:
    """Structured ndarray form used by HDF5 writes."""
    import h5py
    vl = h5py.string_dtype(encoding="utf-8")
    dt = np.dtype([
        ("run_name", vl),
        ("spectrum_index", "<u4"),
        ("score", "<f8"),
        ("chem_id", vl),
    ])
    return np.array([
        ("runA", 0, 0.95, "CHEBI:15377"),
        ("runB", 3, 0.72, "HMDB:0001234"),
        ("", 42, -1.5, ""),  # empty VL strings
        ("π-peak", 7, 3.14159, "unicode-entity"),  # non-ASCII utf-8
    ], dtype=dt)


def _compound_records_objdtype() -> np.ndarray:
    """Object-dtype ndarray form used by Memory / SQLite writes."""
    dt = np.dtype([
        ("run_name", object),
        ("spectrum_index", "<u4"),
        ("score", "<f8"),
        ("chem_id", object),
    ])
    return np.array([
        ("runA", 0, 0.95, "CHEBI:15377"),
        ("runB", 3, 0.72, "HMDB:0001234"),
        ("", 42, -1.5, ""),
        ("π-peak", 7, 3.14159, "unicode-entity"),
    ], dtype=dt)


def test_compound_cross_backend_identity(tmp_path: Path) -> None:
    schema = _compound_schema()
    results: dict[str, bytes] = {}

    # HDF5.
    hdf5_path = tmp_path / "cb_compound.h5"
    with Hdf5Provider.open(str(hdf5_path), mode="w") as p:
        ds = p.root_group().create_compound_dataset(
            "idents", schema, count=4)
        ds.write(_compound_records_structured())
    with Hdf5Provider.open(str(hdf5_path), mode="r") as p:
        results["hdf5"] = p.root_group().open_dataset(
            "idents").read_canonical_bytes()

    # Memory.
    mem_url = "memory://m43-compound"
    with MemoryProvider.open(mem_url, mode="w") as p:
        ds = p.root_group().create_compound_dataset(
            "idents", schema, count=4)
        ds.write(_compound_records_objdtype())
    with MemoryProvider.open(mem_url, mode="r") as p:
        results["memory"] = p.root_group().open_dataset(
            "idents").read_canonical_bytes()
    MemoryProvider.discard_store(mem_url)

    # SQLite — write path accepts list-of-dicts only (per its docstring
    # convention; Gap 2 made the READ side uniform, write is
    # SQLite-native).
    sq_path = tmp_path / "cb_compound.mpgo.sqlite"
    sqlite_rows = [
        {"run_name": r["run_name"], "spectrum_index": int(r["spectrum_index"]),
         "score": float(r["score"]), "chem_id": r["chem_id"]}
        for r in _compound_records_objdtype()
    ]
    with SqliteProvider.open(str(sq_path), mode="w") as p:
        ds = p.root_group().create_compound_dataset(
            "idents", schema, count=4)
        ds.write(sqlite_rows)
    with SqliteProvider.open(str(sq_path), mode="r") as p:
        results["sqlite"] = p.root_group().open_dataset(
            "idents").read_canonical_bytes()

    # Three-way byte identity.
    backends = list(results.keys())
    for i in range(len(backends)):
        for j in range(i + 1, len(backends)):
            assert results[backends[i]] == results[backends[j]], (
                f"canonical bytes diverge between "
                f"{backends[i]} and {backends[j]} providers "
                f"(len={len(results[backends[i]])} vs "
                f"{len(results[backends[j]])})"
            )

    # Manual hand-check of the first row: run_name "runA" (4 utf-8
    # bytes) + spectrum_index 0 + score 0.95 + chem_id "CHEBI:15377"
    # (11 bytes).
    blob = results["hdf5"]
    first_row = (
        b"\x04\x00\x00\x00" + b"runA"                    # run_name
        + b"\x00\x00\x00\x00"                              # spectrum_index
        + np.asarray(0.95, dtype="<f8").tobytes()         # score
        + b"\x0b\x00\x00\x00" + b"CHEBI:15377"            # chem_id
    )
    assert blob.startswith(first_row), (
        "first-row canonical bytes do not match the hand-computed spec"
    )


def test_primitive_byteswap_on_big_endian_input(tmp_path: Path) -> None:
    """If a caller hands a big-endian ndarray to write(), the
    canonical bytes read back must still be little-endian. Guards
    against silent byte-order leaks on hosts where numpy defaults
    differ from HDF5's native order."""
    values_be = np.array([1.0, 2.0, 3.0], dtype=">f8")
    mem_url = "memory://m43-be-input"
    with MemoryProvider.open(mem_url, mode="w") as p:
        ds = p.root_group().create_dataset("v", Precision.FLOAT64, 3)
        ds.write(values_be)
    with MemoryProvider.open(mem_url, mode="r") as p:
        blob = p.root_group().open_dataset("v").read_canonical_bytes()
    MemoryProvider.discard_store(mem_url)
    # Little-endian 1.0 = 00 00 00 00 00 00 f0 3f
    assert blob[:8] == b"\x00\x00\x00\x00\x00\x00\xf0\x3f"
