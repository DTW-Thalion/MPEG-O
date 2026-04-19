"""v0.7 M46 — ZarrProvider contract test matrix.

Re-runs the core provider-protocol assertions against the Zarr
backend. Imports skip gracefully if the optional ``zarr`` dependency
is absent, so HDF5-only CI keeps working.
"""
from __future__ import annotations

import sys
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("zarr", minversion="3.0")

from mpeg_o.enums import Compression, Precision  # noqa: E402
from mpeg_o.providers import (  # noqa: E402
    CompoundField,
    CompoundFieldKind,
    discover_providers,
    open_provider,
)
from mpeg_o.providers.zarr import ZarrProvider  # noqa: E402


# ── Fixtures ──────────────────────────────────────────────────────────


@pytest.fixture
def dir_url(tmp_path: Path) -> str:
    return f"zarr://{tmp_path / 'store.zarr'}"


@pytest.fixture
def mem_url():
    # Unique-per-test suffix so parallel runs don't collide.
    url = f"zarr+memory://test-{id(object())}"
    yield url
    ZarrProvider.discard_memory_store(url)


# ── Discovery ────────────────────────────────────────────────────────


def test_zarr_discovered_by_registry() -> None:
    providers = discover_providers()
    assert "zarr" in providers
    assert providers["zarr"] is ZarrProvider


def test_scheme_routes_to_zarr_provider(dir_url: str) -> None:
    with open_provider(dir_url, mode="w") as p:
        assert p.provider_name() == "zarr"
        assert p.supports_chunking() is True
        assert p.supports_compression() is True


def test_memory_scheme_routes_to_zarr_provider(mem_url: str) -> None:
    with open_provider(mem_url, mode="w") as p:
        assert p.provider_name() == "zarr"


def test_dual_style_open() -> None:
    """Appendix B Gap 1: factory and instance styles both work."""
    url1 = "zarr+memory://dual-factory"
    try:
        prov1 = ZarrProvider.open(url1, mode="w")
        assert prov1.is_open()
        prov1.close()
    finally:
        ZarrProvider.discard_memory_store(url1)

    url2 = "zarr+memory://dual-instance"
    try:
        prov2 = ZarrProvider()
        assert not prov2.is_open()
        returned = prov2.open(url2, mode="w")
        assert returned is prov2
        assert prov2.is_open()
        prov2.close()
    finally:
        ZarrProvider.discard_memory_store(url2)


# ── Group + attribute round-trip ─────────────────────────────────────


def test_nested_groups_and_attributes(dir_url: str) -> None:
    with open_provider(dir_url, mode="w") as p:
        root = p.root_group()
        root.set_attribute("title", "zarr-rt")
        study = root.create_group("study")
        study.set_attribute("version", 11)
        runs = study.create_group("ms_runs")
        runs.create_group("run_0001")
        assert root.has_child("study")
        assert study.has_child("ms_runs")
        assert runs.has_child("run_0001")

    with open_provider(dir_url, mode="r") as p:
        root = p.root_group()
        assert root.get_attribute("title") == "zarr-rt"
        assert root.has_child("study")
        assert "study" in root.child_names()


def test_attribute_list_and_delete(dir_url: str) -> None:
    with open_provider(dir_url, mode="w") as p:
        g = p.root_group()
        g.set_attribute("scratch", "x")
        g.set_attribute("kept", "y")
        assert "scratch" in g.attribute_names()
        assert "kept" in g.attribute_names()
        g.delete_attribute("scratch")
        assert not g.has_attribute("scratch")
        assert g.has_attribute("kept")


# ── Primitive dataset round-trip ─────────────────────────────────────


def test_primitive_dataset_roundtrip(dir_url: str) -> None:
    expected = np.array([1.0, 2.5, 3.14, -0.001, 1e10], dtype="<f8")

    with open_provider(dir_url, mode="w") as p:
        ds = p.root_group().create_dataset(
            "values", Precision.FLOAT64,
            length=len(expected),
            chunk_size=2,
            compression=Compression.ZLIB,
        )
        ds.write(expected)
        assert ds.length == len(expected)
        assert ds.precision == Precision.FLOAT64
        assert ds.chunks is not None

    with open_provider(dir_url, mode="r") as p:
        ds = p.root_group().open_dataset("values")
        np.testing.assert_array_equal(ds.read(), expected)
        np.testing.assert_array_equal(
            ds.read(offset=1, count=2), expected[1:3])


def test_primitive_int64_and_uint32(dir_url: str) -> None:
    ints = np.array([-1, 0, 1, 1 << 40], dtype="<i8")
    uints = np.array([0, 1, 2**31, 2**32 - 1], dtype="<u4")

    with open_provider(dir_url, mode="w") as p:
        root = p.root_group()
        root.create_dataset("ints", Precision.INT64,
                             length=len(ints)).write(ints)
        root.create_dataset("uints", Precision.UINT32,
                             length=len(uints)).write(uints)

    with open_provider(dir_url, mode="r") as p:
        got_ints = p.root_group().open_dataset("ints").read()
        got_uints = p.root_group().open_dataset("uints").read()
    np.testing.assert_array_equal(got_ints, ints)
    np.testing.assert_array_equal(got_uints, uints)


# ── N-D dataset ──────────────────────────────────────────────────────


def test_nd_dataset_roundtrip(dir_url: str) -> None:
    cube = np.arange(24, dtype="<f8").reshape((2, 3, 4))

    with open_provider(dir_url, mode="w") as p:
        ds = p.root_group().create_dataset_nd(
            "cube", Precision.FLOAT64, cube.shape,
            chunks=(1, 3, 4))
        ds.write(cube)
        assert ds.shape == (2, 3, 4)
        assert ds.chunks == (1, 3, 4)

    with open_provider(dir_url, mode="r") as p:
        ds = p.root_group().open_dataset("cube")
        assert ds.shape == (2, 3, 4)
        np.testing.assert_array_equal(ds.read(), cube)


# ── Compound dataset round-trip ──────────────────────────────────────


def test_compound_dataset_roundtrip(dir_url: str) -> None:
    schema = [
        CompoundField("run_name", CompoundFieldKind.VL_STRING),
        CompoundField("spectrum_index", CompoundFieldKind.UINT32),
        CompoundField("chemical_entity", CompoundFieldKind.VL_STRING),
        CompoundField("confidence_score", CompoundFieldKind.FLOAT64),
        CompoundField("evidence_chain_json", CompoundFieldKind.VL_STRING),
    ]
    rows = [
        {"run_name": "run_A", "spectrum_index": 0,
         "chemical_entity": "CHEBI:15377", "confidence_score": 0.95,
         "evidence_chain_json": "[\"MS2 match\"]"},
        {"run_name": "run_B", "spectrum_index": 3,
         "chemical_entity": "HMDB:0001234", "confidence_score": 0.72,
         "evidence_chain_json": "[]"},
    ]

    with open_provider(dir_url, mode="w") as p:
        ds = p.root_group().create_compound_dataset(
            "identifications", schema, count=len(rows))
        ds.write(rows)
        assert ds.compound_fields == tuple(schema)
        assert ds.length == len(rows)

    with open_provider(dir_url, mode="r") as p:
        got = p.root_group().open_dataset("identifications").read()
        assert len(got) == 2
        assert got[0]["run_name"] == "run_A"
        assert int(got[1]["spectrum_index"]) == 3
        assert got[0]["confidence_score"] == pytest.approx(0.95)


def test_read_rows_normalises_compound(dir_url: str) -> None:
    """Appendix B Gap 2: read_rows() yields list[dict] regardless of
    underlying backend — Zarr's compound path stores rows as JSON so
    read() is already list[dict], but the contract still needs to
    hold."""
    schema = [
        CompoundField("run_name", CompoundFieldKind.VL_STRING),
        CompoundField("idx", CompoundFieldKind.UINT32),
        CompoundField("score", CompoundFieldKind.FLOAT64),
    ]
    rows = [{"run_name": f"run{i}", "idx": i, "score": 0.1 * i}
            for i in range(3)]

    with open_provider(dir_url, mode="w") as p:
        ds = p.root_group().create_compound_dataset("rows", schema, count=3)
        ds.write(rows)

    with open_provider(dir_url, mode="r") as p:
        got = p.root_group().open_dataset("rows").read_rows()
        assert isinstance(got, list)
        assert len(got) == 3
        assert got[0]["run_name"] == "run0"
        assert int(got[2]["idx"]) == 2
        assert got[1]["score"] == pytest.approx(0.1)


def test_read_rows_rejects_primitive(dir_url: str) -> None:
    with open_provider(dir_url, mode="w") as p:
        ds = p.root_group().create_dataset(
            "primitive", Precision.FLOAT64, length=3)
        ds.write(np.array([1.0, 2.0, 3.0]))

    with open_provider(dir_url, mode="r") as p:
        ds = p.root_group().open_dataset("primitive")
        with pytest.raises(TypeError, match="compound"):
            ds.read_rows()


# ── Canonical-bytes parity (M43 integration) ─────────────────────────


def test_primitive_canonical_bytes(dir_url: str) -> None:
    data = np.array([1.0, 2.0, 3.0], dtype="<f8")
    with open_provider(dir_url, mode="w") as p:
        ds = p.root_group().create_dataset(
            "x", Precision.FLOAT64, length=len(data))
        ds.write(data)
        got = ds.read_canonical_bytes()
    assert got == data.tobytes()


def test_compound_canonical_bytes_matches_hdf5(dir_url: str,
                                                  tmp_path: Path) -> None:
    """The canonical-bytes stream for a given compound record set is
    backend-invariant. This is the M43 guarantee that M46 inherits —
    ZarrProvider is a fourth provider; its canonical bytes must match
    the Hdf5Provider's byte-for-byte."""
    schema = [
        CompoundField("run_name", CompoundFieldKind.VL_STRING),
        CompoundField("idx", CompoundFieldKind.UINT32),
        CompoundField("score", CompoundFieldKind.FLOAT64),
    ]
    rows = [
        {"run_name": "A", "idx": 0, "score": 0.5},
        {"run_name": "Bxy", "idx": 12345, "score": 1.5},
    ]

    with open_provider(dir_url, mode="w") as zp:
        cds = zp.root_group().create_compound_dataset(
            "ids", schema, count=len(rows))
        cds.write(rows)
    with open_provider(dir_url, mode="r") as zp:
        zarr_bytes = zp.root_group().open_dataset("ids").read_canonical_bytes()

    hdf5_path = tmp_path / "h.h5"
    # Hdf5Provider's compound write() expects a structured ndarray,
    # not list[dict] — so build the structured form from the same rows.
    import h5py
    vl = h5py.string_dtype(encoding="utf-8")
    dt = np.dtype([("run_name", vl), ("idx", "<u4"), ("score", "<f8")])
    hdf5_rows = np.array(
        [(r["run_name"], r["idx"], r["score"]) for r in rows], dtype=dt)
    with open_provider(str(hdf5_path), mode="w") as hp:
        cds = hp.root_group().create_compound_dataset(
            "ids", schema, count=len(rows))
        cds.write(hdf5_rows)
    with open_provider(str(hdf5_path), mode="r") as hp:
        hdf5_bytes = hp.root_group().open_dataset("ids").read_canonical_bytes()

    assert zarr_bytes == hdf5_bytes


# ── Memory backing ────────────────────────────────────────────────────


def test_memory_store_persists_within_process(mem_url: str) -> None:
    """Two opens of the same zarr+memory:// URL share the same tree."""
    with open_provider(mem_url, mode="w") as p:
        p.root_group().set_attribute("persist", "yes")

    with open_provider(mem_url, mode="r") as p:
        assert p.root_group().get_attribute("persist") == "yes"


def test_discard_memory_store_wipes(mem_url: str) -> None:
    with open_provider(mem_url, mode="w") as p:
        p.root_group().set_attribute("k", "v")
    ZarrProvider.discard_memory_store(mem_url)

    # After discard, opening with mode="r" against the missing store
    # will return a fresh (empty) handle — zarr's open_group creates
    # on demand. We only need to verify the old attr is gone.
    with open_provider(mem_url, mode="w") as p:
        assert not p.root_group().has_attribute("k")


# ── Native handle ────────────────────────────────────────────────────


def test_native_handle_is_zarr_group(dir_url: str) -> None:
    import zarr
    with open_provider(dir_url, mode="w") as p:
        handle = p.native_handle()
        # v1.0 zarr-python 3.x: Group moved from zarr.hierarchy.Group
        # to the top-level zarr.Group export.
        assert isinstance(handle, zarr.Group)
