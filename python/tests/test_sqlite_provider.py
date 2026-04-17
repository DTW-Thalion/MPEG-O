"""Tests for mpeg_o.providers.sqlite.SqliteProvider.

Covers Task C1: structural round-trip stress-test of the Provisional
provider abstraction per the M41 design spec.
"""
from __future__ import annotations

import numpy as np
import pytest

from mpeg_o.providers.sqlite import SqliteProvider
from mpeg_o.providers.base import CompoundField, CompoundFieldKind
from mpeg_o.enums import Precision


def test_provider_name_and_registration():
    from mpeg_o.providers import discover_providers
    # Clear the registry cache so the entry-point / fallback logic fires.
    import mpeg_o.providers.registry as _reg
    _reg._REGISTRY.clear()
    providers = discover_providers()
    assert "sqlite" in providers
    p = providers["sqlite"]()
    assert p.provider_name == "sqlite"


def test_open_create_close(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    assert p.is_open()
    root = p.root_group()
    assert root is not None
    p.close()
    assert not p.is_open()


def test_open_as_classmethod(tmp_path):
    """open() works as a classmethod too."""
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider.open(path, mode="w")
    assert p.is_open()
    assert p.provider_name == "sqlite"
    p.close()


def test_context_manager(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    with SqliteProvider.open(path, mode="w") as p:
        assert p.is_open()
    assert not p.is_open()


def test_groups_roundtrip(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    study = root.create_group("study")
    ms_runs = study.create_group("ms_runs")
    run_0001 = ms_runs.create_group("run_0001")
    _sig = run_0001.create_group("signal_channels")

    assert "study" in root.child_names()
    assert "signal_channels" in run_0001.child_names()
    assert root.has_child("study")

    # Re-open and verify
    p.close()
    q = SqliteProvider()
    q.open(path, mode="r")
    r2 = q.root_group()
    assert "study" in r2.child_names()
    s2 = r2.open_group("study")
    assert "ms_runs" in s2.child_names()
    q.close()


def test_open_group_missing_raises(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    with pytest.raises(KeyError):
        root.open_group("does_not_exist")
    p.close()


def test_create_group_duplicate_raises(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    root.create_group("a")
    with pytest.raises(ValueError):
        root.create_group("a")
    p.close()


def test_delete_child_group(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    root.create_group("g1")
    assert root.has_child("g1")
    root.delete_child("g1")
    assert not root.has_child("g1")
    p.close()


def test_delete_child_dataset(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    ds = root.create_dataset("d1", precision=Precision.FLOAT64, length=4)
    ds.write(np.array([1.0, 2.0, 3.0, 4.0]))
    assert root.has_child("d1")
    root.delete_child("d1")
    assert not root.has_child("d1")
    p.close()


def test_primitive_dataset_1d_roundtrip(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()

    # Write
    original = np.array([1.5, 2.5, 3.5, 4.5], dtype="<f8")
    ds = root.create_dataset("intensity", precision=Precision.FLOAT64, length=len(original))
    ds.write(original)

    # Read back via same provider
    ds2 = root.open_dataset("intensity")
    assert ds2.precision == Precision.FLOAT64
    assert ds2.length == 4
    assert ds2.shape == (4,)
    read_back = ds2.read()
    np.testing.assert_array_equal(read_back, original)

    # Re-open provider
    p.close()
    q = SqliteProvider()
    q.open(path, mode="r")
    ds3 = q.root_group().open_dataset("intensity")
    np.testing.assert_array_equal(ds3.read(), original)
    q.close()


def test_primitive_dataset_read_slice(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    data = np.arange(10, dtype="<f8")
    ds = root.create_dataset("v", precision=Precision.FLOAT64, length=10)
    ds.write(data)

    ds2 = root.open_dataset("v")
    np.testing.assert_array_equal(ds2.read(offset=2, count=3), data[2:5])
    np.testing.assert_array_equal(ds2.read(offset=7), data[7:])
    p.close()


def test_primitive_dataset_nd_roundtrip(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()

    cube = np.arange(60, dtype="<f8").reshape(3, 4, 5)
    ds = root.create_dataset_nd("cube", precision=Precision.FLOAT64, shape=(3, 4, 5))
    ds.write(cube)

    read = root.open_dataset("cube").read()
    assert read.shape == (3, 4, 5)
    np.testing.assert_array_equal(read, cube)
    p.close()


def test_all_precisions_roundtrip(tmp_path):
    """Every Precision enum value survives a write/read cycle."""
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()

    cases: list[tuple[Precision, np.ndarray]] = [
        (Precision.FLOAT32, np.array([1.0, 2.0], dtype="<f4")),
        (Precision.FLOAT64, np.array([3.0, 4.0], dtype="<f8")),
        (Precision.INT32,   np.array([-1, 2], dtype="<i4")),
        (Precision.INT64,   np.array([-9999999999, 9999999999], dtype="<i8")),
        (Precision.UINT32,  np.array([0, 2**32 - 1], dtype="<u4")),
        (Precision.COMPLEX128, np.array([1+2j, 3+4j], dtype="<c16")),
    ]
    for prec, arr in cases:
        ds = root.create_dataset(prec.name, precision=prec, length=len(arr))
        ds.write(arr)

    for prec, arr in cases:
        back = root.open_dataset(prec.name).read()
        np.testing.assert_array_equal(back, arr,
                                      err_msg=f"precision {prec.name} mismatch")
    p.close()


def test_compound_dataset_roundtrip(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    fields = [
        CompoundField(name="run_name", kind=CompoundFieldKind.VL_STRING),
        CompoundField(name="spectrum_index", kind=CompoundFieldKind.UINT32),
        CompoundField(name="confidence_score", kind=CompoundFieldKind.FLOAT64),
    ]
    ds = root.create_compound_dataset("identifications", fields=fields, count=2)
    rows = [
        {"run_name": "run_0001", "spectrum_index": 42, "confidence_score": 0.95},
        {"run_name": "run_0001", "spectrum_index": 55, "confidence_score": 0.72},
    ]
    ds.write(rows)
    read = root.open_dataset("identifications").read()
    assert read == rows
    p.close()


def test_attributes_roundtrip(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    study = root.create_group("study")
    study.set_attribute("title", "Test study")
    study.set_attribute("spectrum_count", 100)
    study.set_attribute("threshold", 0.05)
    assert study.get_attribute("title") == "Test study"
    assert study.get_attribute("spectrum_count") == 100
    assert study.get_attribute("threshold") == 0.05
    assert sorted(study.attribute_names()) == ["spectrum_count", "threshold", "title"]
    p.close()


def test_attribute_has_delete(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    g = root.create_group("g")
    g.set_attribute("x", 42)
    assert g.has_attribute("x")
    assert not g.has_attribute("y")
    g.delete_attribute("x")
    assert not g.has_attribute("x")
    p.close()


def test_attribute_missing_raises(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    with pytest.raises(KeyError):
        root.get_attribute("nonexistent")
    p.close()


def test_dataset_attributes(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    root = p.root_group()
    ds = root.create_dataset("v", precision=Precision.FLOAT64, length=2)
    ds.set_attribute("units", "m/z")
    ds.set_attribute("count", 2)
    assert ds.get_attribute("units") == "m/z"
    assert ds.get_attribute("count") == 2
    assert sorted(ds.attribute_names()) == ["count", "units"]
    ds.delete_attribute("count")
    assert not ds.has_attribute("count")
    p.close()


def test_read_only_rejects_writes(tmp_path):
    path = str(tmp_path / "t.mpgo.sqlite")
    # Create file first
    with SqliteProvider.open(path, mode="w") as p:
        root = p.root_group()
        root.create_group("g")

    # Re-open read-only, verify writes are blocked
    q = SqliteProvider()
    q.open(path, mode="r")
    root = q.root_group()
    with pytest.raises(IOError):
        root.create_group("new")
    with pytest.raises(IOError):
        root.set_attribute("x", 1)
    q.close()


def test_supports_url():
    assert SqliteProvider.supports_url("sqlite:///path/to/data.mpgo.sqlite")
    assert SqliteProvider.supports_url("/data/file.mpgo.sqlite")
    assert SqliteProvider.supports_url("/data/file.sqlite")
    assert not SqliteProvider.supports_url("memory://foo")
    assert not SqliteProvider.supports_url("/data/file.mpgo.h5")


def test_native_handle(tmp_path):
    import sqlite3
    path = str(tmp_path / "t.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")
    handle = p.native_handle()
    assert isinstance(handle, sqlite3.Connection)
    p.close()


def test_mode_r_missing_file_raises(tmp_path):
    path = str(tmp_path / "does_not_exist.mpgo.sqlite")
    p = SqliteProvider()
    with pytest.raises(FileNotFoundError):
        p.open(path, mode="r")


def test_mode_a_creates_if_missing(tmp_path):
    path = str(tmp_path / "new.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="a")
    assert p.is_open()
    p.root_group().create_group("g")
    p.close()
    # File should now exist and be readable
    q = SqliteProvider()
    q.open(path, mode="r")
    assert q.root_group().has_child("g")
    q.close()


def test_mpeg_o_shaped_tree_roundtrip(tmp_path):
    """C1 — round-trip a tree structured like a real .mpgo file.

    This exercises the full provider protocol in the exact pattern
    SpectralDataset would use if it were wired through providers.
    """
    path = str(tmp_path / "spectral.mpgo.sqlite")
    p = SqliteProvider()
    p.open(path, mode="w")

    root = p.root_group()
    root.set_attribute("mpeg_o_format_version", "0.6-sqlite")
    study = root.create_group("study")
    study.set_attribute("title", "End-to-end")

    runs_group = study.create_group("ms_runs")
    run0 = runs_group.create_group("run_0001")
    run0.set_attribute("acquisition_mode", 0)   # MS1_DDA
    run0.set_attribute("spectrum_class", "MPGOMassSpectrum")

    # spectrum_index: 8 parallel 1-D datasets
    idx = run0.create_group("spectrum_index")
    n = 3

    def put_1d(name, arr, prec):
        ds = idx.create_dataset(name, precision=prec, length=n)
        ds.write(arr)

    put_1d("offsets",               np.array([0, 4, 8],         dtype="<u4"), Precision.UINT32)
    put_1d("lengths",               np.array([4, 4, 4],         dtype="<u4"), Precision.UINT32)
    put_1d("retention_times",       np.array([1.0, 2.0, 3.0],   dtype="<f8"), Precision.FLOAT64)
    put_1d("ms_levels",             np.array([1, 1, 1],         dtype="<i4"), Precision.INT32)
    put_1d("polarities",            np.array([1, 1, 1],         dtype="<i4"), Precision.INT32)
    put_1d("precursor_mzs",         np.array([0.0, 0.0, 0.0],   dtype="<f8"), Precision.FLOAT64)
    put_1d("precursor_charges",     np.array([0, 0, 0],         dtype="<i4"), Precision.INT32)
    put_1d("base_peak_intensities", np.array([100.0, 200.0, 300.0], dtype="<f8"), Precision.FLOAT64)

    # signal_channels: mz + intensity concatenated
    sig = run0.create_group("signal_channels")
    sig.set_attribute("channel_names", "mz,intensity")
    mz_all = np.linspace(100, 400, 12).astype("<f8")
    i_all  = np.linspace(1, 12, 12).astype("<f8")
    mz_ds = sig.create_dataset("mz_values", precision=Precision.FLOAT64, length=len(mz_all))
    mz_ds.write(mz_all)
    i_ds = sig.create_dataset("intensity_values", precision=Precision.FLOAT64, length=len(i_all))
    i_ds.write(i_all)

    # instrument_config (attributes on a group, no datasets)
    cfg = run0.create_group("instrument_config")
    cfg.set_attribute("manufacturer", "Thermo")
    cfg.set_attribute("model", "Orbitrap Eclipse")

    # A compound dataset at study level (identifications)
    idents = study.create_compound_dataset("identifications", fields=[
        CompoundField(name="run_name",       kind=CompoundFieldKind.VL_STRING),
        CompoundField(name="spectrum_index", kind=CompoundFieldKind.UINT32),
        CompoundField(name="chemical_entity", kind=CompoundFieldKind.VL_STRING),
        CompoundField(name="confidence_score", kind=CompoundFieldKind.FLOAT64),
    ], count=1)
    idents.write([{
        "run_name": "run_0001", "spectrum_index": 0,
        "chemical_entity": "CHEBI:17234", "confidence_score": 0.95,
    }])

    p.close()

    # ── Re-open and verify EVERY byte matches ───────────────────────────
    q = SqliteProvider()
    q.open(path, mode="r")
    r2 = q.root_group()
    assert r2.get_attribute("mpeg_o_format_version") == "0.6-sqlite"
    s2 = r2.open_group("study")
    assert s2.get_attribute("title") == "End-to-end"
    runs2 = s2.open_group("ms_runs")
    run_back = runs2.open_group("run_0001")
    assert run_back.get_attribute("acquisition_mode") == 0
    assert run_back.get_attribute("spectrum_class") == "MPGOMassSpectrum"

    idx2 = run_back.open_group("spectrum_index")
    np.testing.assert_array_equal(
        idx2.open_dataset("retention_times").read(),
        np.array([1.0, 2.0, 3.0], dtype="<f8"),
    )
    np.testing.assert_array_equal(
        idx2.open_dataset("ms_levels").read(),
        np.array([1, 1, 1], dtype="<i4"),
    )

    sig2 = run_back.open_group("signal_channels")
    assert sig2.get_attribute("channel_names") == "mz,intensity"
    np.testing.assert_array_equal(
        sig2.open_dataset("mz_values").read(),
        mz_all,
    )
    np.testing.assert_array_equal(
        sig2.open_dataset("intensity_values").read(),
        i_all,
    )

    cfg2 = run_back.open_group("instrument_config")
    assert cfg2.get_attribute("manufacturer") == "Thermo"
    assert cfg2.get_attribute("model") == "Orbitrap Eclipse"

    idents_back = s2.open_dataset("identifications").read()
    assert idents_back == [{
        "run_name": "run_0001", "spectrum_index": 0,
        "chemical_entity": "CHEBI:17234", "confidence_score": 0.95,
    }]

    q.close()
