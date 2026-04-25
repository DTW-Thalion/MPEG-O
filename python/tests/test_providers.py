"""Contract + round-trip tests for the storage provider abstraction —
Milestone 39 Part A/B/D.

Parametrised across the two shipping providers so that every
behavioural test runs through both paths. If ``SpectralDataset``
functions identically over ``MemoryProvider`` and ``Hdf5Provider``,
the protocol contract is correct.
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.enums import Compression, Precision
from ttio.providers import (
    CompoundField,
    CompoundFieldKind,
    StorageProvider,
    discover_providers,
    open_provider,
    register_provider,
)
from ttio.providers.hdf5 import Hdf5Provider
from ttio.providers.memory import MemoryProvider


# ── Fixture helpers ───────────────────────────────────────────────────

@pytest.fixture
def hdf5_url(tmp_path: Path) -> str:
    return str(tmp_path / "provider.h5")


@pytest.fixture
def memory_url() -> str:
    url = "memory://test-providers"
    yield url
    MemoryProvider.discard_store(url)


def _open_w(provider: str, url: str) -> StorageProvider:
    return open_provider(url, provider=provider, mode="w")


def _open_r(provider: str, url: str) -> StorageProvider:
    return open_provider(url, provider=provider, mode="r")


PROVIDERS = ("hdf5", "memory")


# ── Discovery ────────────────────────────────────────────────────────


def test_discover_returns_both_default_providers() -> None:
    providers = discover_providers()
    assert "hdf5" in providers
    assert "memory" in providers
    assert providers["hdf5"] is Hdf5Provider
    assert providers["memory"] is MemoryProvider


def test_register_overrides_builtin() -> None:
    class Stub(StorageProvider):
        @classmethod
        def open(cls, path_or_url, *, mode="r", **kwargs):
            return cls()
        provider_name = "stub"
        def root_group(self): raise NotImplementedError
        def is_open(self): return True
        def close(self): pass

    register_provider("hdf5", Stub)
    try:
        assert discover_providers()["hdf5"] is Stub
    finally:
        register_provider("hdf5", Hdf5Provider)


def test_open_by_url_scheme_resolves(tmp_path: Path) -> None:
    p = tmp_path / "scheme.h5"
    prov = open_provider(f"file://{p}", mode="w")
    assert prov.provider_name() == "hdf5"
    prov.close()

    prov2 = open_provider("memory://scheme-test", mode="w")
    assert prov2.provider_name() == "memory"
    MemoryProvider.discard_store("memory://scheme-test")


def test_open_dual_style_hdf5(tmp_path: Path) -> None:
    """Appendix B Gap 1: both factory and instance-mutation styles work."""
    p1 = tmp_path / "factory.h5"
    prov1 = Hdf5Provider.open(str(p1), mode="w")
    assert prov1.is_open()
    prov1.close()

    p2 = tmp_path / "instance.h5"
    prov2 = Hdf5Provider()
    assert not prov2.is_open()
    returned = prov2.open(str(p2), mode="w")
    assert returned is prov2  # instance-mutation returns self
    assert prov2.is_open()
    prov2.close()


def test_open_dual_style_memory() -> None:
    """Appendix B Gap 1: MemoryProvider supports both call styles."""
    prov1 = MemoryProvider.open("memory://gap1-factory", mode="w")
    assert prov1.is_open()
    prov1.close()
    MemoryProvider.discard_store("memory://gap1-factory")

    prov2 = MemoryProvider()
    assert not prov2.is_open()
    returned = prov2.open("memory://gap1-instance", mode="w")
    assert returned is prov2
    assert prov2.is_open()
    prov2.close()
    MemoryProvider.discard_store("memory://gap1-instance")


# ── Group + attribute round-trip ─────────────────────────────────────


@pytest.mark.parametrize("provider", PROVIDERS)
def test_nested_groups_and_attributes(provider: str,
                                        hdf5_url: str,
                                        memory_url: str) -> None:
    url = memory_url if provider == "memory" else hdf5_url
    with _open_w(provider, url) as p:
        root = p.root_group()
        root.set_attribute("title", "round-trip")
        study = root.create_group("study")
        study.set_attribute("version", 11)
        runs = study.create_group("ms_runs")
        runs.create_group("run_0001")
        assert root.has_child("study")
        assert study.has_child("ms_runs")
        assert runs.has_child("run_0001")

    with _open_r(provider, url) as p:
        root = p.root_group()
        title = root.get_attribute("title")
        # HDF5 returns bytes; MemoryProvider returns what was stored
        if isinstance(title, bytes):
            title = title.decode()
        assert title == "round-trip"
        assert root.has_child("study")
        assert "study" in root.child_names()


# ── Primitive dataset round-trip ─────────────────────────────────────


@pytest.mark.parametrize("provider", PROVIDERS)
def test_primitive_dataset_roundtrip(provider: str,
                                       hdf5_url: str,
                                       memory_url: str) -> None:
    url = memory_url if provider == "memory" else hdf5_url
    expected = np.array([1.0, 2.5, 3.14, -0.001, 1e10], dtype="<f8")

    with _open_w(provider, url) as p:
        ds = p.root_group().create_dataset("values", Precision.FLOAT64,
                                             length=len(expected))
        ds.write(expected)
        assert ds.length == len(expected)
        assert ds.precision == Precision.FLOAT64

    with _open_r(provider, url) as p:
        ds = p.root_group().open_dataset("values")
        np.testing.assert_array_equal(ds.read(), expected)
        np.testing.assert_array_equal(ds.read(offset=1, count=2), expected[1:3])


@pytest.mark.parametrize("provider", PROVIDERS)
def test_primitive_dataset_int64(provider: str,
                                   hdf5_url: str,
                                   memory_url: str) -> None:
    url = memory_url if provider == "memory" else hdf5_url
    expected = np.array([-1, 0, 1, 1 << 40], dtype="<i8")

    with _open_w(provider, url) as p:
        ds = p.root_group().create_dataset("ints", Precision.INT64,
                                             length=len(expected))
        ds.write(expected)

    with _open_r(provider, url) as p:
        got = p.root_group().open_dataset("ints").read()
        np.testing.assert_array_equal(got, expected)


# ── Compound dataset round-trip (all kinds) ─────────────────────────


@pytest.mark.parametrize("provider", PROVIDERS)
def test_compound_dataset_roundtrip(provider: str,
                                      hdf5_url: str,
                                      memory_url: str) -> None:
    url = memory_url if provider == "memory" else hdf5_url
    schema = [
        CompoundField("run_name", CompoundFieldKind.VL_STRING),
        CompoundField("spectrum_index", CompoundFieldKind.UINT32),
        CompoundField("chemical_entity", CompoundFieldKind.VL_STRING),
        CompoundField("confidence_score", CompoundFieldKind.FLOAT64),
        CompoundField("evidence_chain_json", CompoundFieldKind.VL_STRING),
    ]
    if provider == "hdf5":
        import h5py
        vl = h5py.string_dtype(encoding="utf-8")
        dt = np.dtype([
            ("run_name", vl), ("spectrum_index", "<u4"),
            ("chemical_entity", vl), ("confidence_score", "<f8"),
            ("evidence_chain_json", vl),
        ])
    else:
        dt = np.dtype([
            ("run_name", object), ("spectrum_index", "<u4"),
            ("chemical_entity", object), ("confidence_score", "<f8"),
            ("evidence_chain_json", object),
        ])
    records = np.array([
        ("run_A", 0, "CHEBI:15377", 0.95, "[\"MS2 match\"]"),
        ("run_B", 3, "HMDB:0001234", 0.72, "[]"),
    ], dtype=dt)

    with _open_w(provider, url) as p:
        ds = p.root_group().create_compound_dataset(
                "identifications", schema, count=len(records))
        ds.write(records)
        assert ds.compound_fields == tuple(schema)
        assert ds.length == len(records)

    with _open_r(provider, url) as p:
        got = p.root_group().open_dataset("identifications").read()
        assert len(got) == 2
        run_name_0 = got[0]["run_name"]
        if isinstance(run_name_0, bytes):
            run_name_0 = run_name_0.decode()
        assert run_name_0 == "run_A"
        assert int(got[1]["spectrum_index"]) == 3
        assert got[0]["confidence_score"] == pytest.approx(0.95)


@pytest.mark.parametrize("provider", PROVIDERS)
def test_read_rows_normalises_compound(provider: str,
                                         hdf5_url: str,
                                         memory_url: str) -> None:
    """Appendix B Gap 2: read_rows() returns list[dict] regardless of
    backend so callers can iterate compound rows without knowing
    whether read() returned a structured ndarray or a list[dict]."""
    url = memory_url if provider == "memory" else hdf5_url
    schema = [
        CompoundField("run_name", CompoundFieldKind.VL_STRING),
        CompoundField("idx", CompoundFieldKind.UINT32),
        CompoundField("score", CompoundFieldKind.FLOAT64),
    ]
    if provider == "hdf5":
        import h5py
        vl = h5py.string_dtype(encoding="utf-8")
        dt = np.dtype([("run_name", vl), ("idx", "<u4"), ("score", "<f8")])
    else:
        dt = np.dtype([("run_name", object), ("idx", "<u4"), ("score", "<f8")])
    records = np.array(
        [("runA", 0, 0.1), ("runB", 1, 0.2), ("runC", 2, 0.3)],
        dtype=dt,
    )

    with _open_w(provider, url) as p:
        ds = p.root_group().create_compound_dataset("rows", schema, count=3)
        ds.write(records)

    with _open_r(provider, url) as p:
        ds = p.root_group().open_dataset("rows")
        rows = ds.read_rows()
        assert isinstance(rows, list)
        assert len(rows) == 3
        assert all(isinstance(r, dict) for r in rows)
        # Normalise VL-string so assertions work uniformly across backends.
        def _str(v: object) -> str:
            return v.decode() if isinstance(v, bytes) else str(v)
        assert _str(rows[0]["run_name"]) == "runA"
        assert int(rows[2]["idx"]) == 2
        assert rows[1]["score"] == pytest.approx(0.2)


@pytest.mark.parametrize("provider", PROVIDERS)
def test_read_rows_rejects_primitive(provider: str,
                                       hdf5_url: str,
                                       memory_url: str) -> None:
    url = memory_url if provider == "memory" else hdf5_url
    with _open_w(provider, url) as p:
        ds = p.root_group().create_dataset(
            "primitive", Precision.FLOAT64, length=3)
        ds.write(np.array([1.0, 2.0, 3.0]))

    with _open_r(provider, url) as p:
        ds = p.root_group().open_dataset("primitive")
        with pytest.raises(TypeError, match="compound"):
            ds.read_rows()


# ── Attribute delete ─────────────────────────────────────────────────


@pytest.mark.parametrize("provider", PROVIDERS)
def test_delete_attribute(provider: str,
                            hdf5_url: str,
                            memory_url: str) -> None:
    url = memory_url if provider == "memory" else hdf5_url
    with _open_w(provider, url) as p:
        g = p.root_group()
        g.set_attribute("scratch", "x")
        assert g.has_attribute("scratch")
        g.delete_attribute("scratch")
        assert not g.has_attribute("scratch")


# ── Transport: fsspec path via file:// scheme ──────────────────────


# ── N-D datasets + native-handle escape ───────────────────────────


@pytest.mark.parametrize("provider", PROVIDERS)
def test_nd_dataset_roundtrip(provider: str,
                                hdf5_url: str,
                                memory_url: str) -> None:
    url = memory_url if provider == "memory" else hdf5_url
    cube = np.arange(24, dtype="<f8").reshape((2, 3, 4))

    with _open_w(provider, url) as p:
        ds = p.root_group().create_dataset_nd(
                "cube", Precision.FLOAT64, cube.shape,
                chunks=(1, 3, 4))
        ds.write(cube)
        assert ds.shape == (2, 3, 4)
        assert ds.chunks == (1, 3, 4) or ds.chunks is None

    with _open_r(provider, url) as p:
        ds = p.root_group().open_dataset("cube")
        assert ds.shape == (2, 3, 4)

    if provider == "memory":
        MemoryProvider.discard_store(url)


def test_hdf5_native_handle_returns_h5py_file(hdf5_url: str) -> None:
    import h5py
    with open_provider(hdf5_url, mode="w") as p:
        handle = p.native_handle()
        assert isinstance(handle, h5py.File)


def test_memory_native_handle_is_none(memory_url: str) -> None:
    with open_provider(memory_url, mode="w") as p:
        assert p.native_handle() is None
    MemoryProvider.discard_store(memory_url)


def test_spectral_dataset_open_wires_provider(tmp_path: Path) -> None:
    """SpectralDataset.open routes through Hdf5Provider and exposes it
    on the ``provider`` attribute; closing flows through the provider."""
    from ttio import SpectralDataset
    import h5py

    path = tmp_path / "wired.tio"
    with h5py.File(path, "w") as f:
        f.attrs["ttio_format_version"] = "1.1"
        f.attrs["ttio_features"] = "[\"base_v1\"]"
        f.create_group("study")

    with SpectralDataset.open(path) as ds:
        assert ds.provider is not None
        assert ds.provider.provider_name() == "hdf5"
        # ds.file is the same h5py.File as provider.native_handle()
        assert ds.provider.native_handle() is ds.file


def test_hdf5_provider_accepts_file_scheme(tmp_path: Path) -> None:
    """The Hdf5Provider's fsspec-style URL router must strip file://
    and open the path directly. This locks the v0.6 behaviour used by
    callers that pass fully-qualified URLs."""
    path = tmp_path / "scheme_smoke.h5"
    with open_provider(f"file://{path}", mode="w") as p:
        root = p.root_group()
        root.create_dataset("x", Precision.FLOAT64, length=1).write(
                np.array([1.0]))

    with open_provider(f"file://{path}", mode="r") as p:
        assert p.root_group().open_dataset("x").read().tolist() == [1.0]
