"""Tests for the ``_hdf5_io`` helper module."""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest

from mpeg_o import _hdf5_io as io


# -------------------------------------------------------------- attributes ---


def test_fixed_string_attr_round_trip(tmp_path: Path) -> None:
    p = tmp_path / "attrs.h5"
    with h5py.File(p, "w") as f:
        io.write_fixed_string_attr(f, "mpeg_o_format_version", "1.1")
        io.write_fixed_string_attr(f, "title", "my study")
    with h5py.File(p, "r") as f:
        assert io.read_string_attr(f, "mpeg_o_format_version") == "1.1"
        assert io.read_string_attr(f, "title") == "my study"


def test_fixed_string_attr_matches_objc_layout(tmp_path: Path) -> None:
    """The Python writer emits NULLTERM fixed-length strings sized to
    ``len(value) + 1``; h5py enforces a real terminator byte, so the
    extra byte is required for round-trip. The ObjC writer uses size =
    ``len(value)`` but its reader always allocates ``size + 1``, so either
    layout is mutually readable."""
    p = tmp_path / "attrs.h5"
    with h5py.File(p, "w") as f:
        io.write_fixed_string_attr(f, "title", "full MS with annotations")
    with h5py.File(p, "r") as f:
        aid = h5py.h5a.open(f.id, b"title")
        tid = aid.get_type()
        assert tid.get_class() == h5py.h5t.STRING
        assert tid.get_size() == len("full MS with annotations") + 1
        assert tid.get_strpad() == h5py.h5t.STR_NULLTERM


def test_fixed_string_attr_empty_and_overwrite(tmp_path: Path) -> None:
    p = tmp_path / "attrs.h5"
    with h5py.File(p, "w") as f:
        io.write_fixed_string_attr(f, "x", "short")
        io.write_fixed_string_attr(f, "x", "much longer replacement")
        io.write_fixed_string_attr(f, "empty", "")
    with h5py.File(p, "r") as f:
        assert io.read_string_attr(f, "x") == "much longer replacement"
        assert io.read_string_attr(f, "empty") == ""
        assert io.read_string_attr(f, "absent", default="D") == "D"


def test_int_attr_round_trip(tmp_path: Path) -> None:
    p = tmp_path / "ints.h5"
    with h5py.File(p, "w") as f:
        io.write_int_attr(f, "spectrum_count", 42)
    with h5py.File(p, "r") as f:
        assert io.read_int_attr(f, "spectrum_count") == 42
        assert io.read_int_attr(f, "missing") is None


# ----------------------------------------------------------- signal channels ---


def test_signal_channel_round_trip_small(tmp_path: Path) -> None:
    p = tmp_path / "sig.h5"
    data = np.linspace(100.0, 2000.0, 80, dtype=np.float64)
    with h5py.File(p, "w") as f:
        g = f.create_group("signal_channels")
        ds = io.write_signal_channel(g, "mz_values", data)
        assert ds.compression == "gzip"
        assert ds.chunks == (80,)  # clamped to length
    with h5py.File(p, "r") as f:
        roundtrip = io.read_signal_channel(f["signal_channels"], "mz_values")
        np.testing.assert_array_equal(roundtrip, data)


def test_signal_channel_chunking_for_large(tmp_path: Path) -> None:
    p = tmp_path / "sig.h5"
    data = np.arange(100_000, dtype=np.float64)
    with h5py.File(p, "w") as f:
        g = f.create_group("signal_channels")
        ds = io.write_signal_channel(g, "intensity_values", data)
        assert ds.chunks == (io.DEFAULT_SIGNAL_CHUNK,)


def test_signal_channel_rejects_non_1d(tmp_path: Path) -> None:
    p = tmp_path / "sig.h5"
    with h5py.File(p, "w") as f:
        g = f.create_group("s")
        with pytest.raises(ValueError):
            io.write_signal_channel(g, "bad", np.zeros((3, 3)))


# ------------------------------------------------------- compound datasets ---


def test_compound_dataset_round_trip_with_vl_strings(tmp_path: Path) -> None:
    p = tmp_path / "compound.h5"
    records = [
        {"run_name": "run_0001", "spectrum_index": 0,
         "chemical_entity": "CHEBI:15000", "confidence_score": 0.5,
         "evidence_chain_json": '["MS:1002217"]'},
        {"run_name": "run_0001", "spectrum_index": 3,
         "chemical_entity": "CHEBI:15377", "confidence_score": 0.91,
         "evidence_chain_json": '["MS:1002217","PRIDE:0000033"]'},
    ]
    fields = [
        ("run_name", io.vl_str()),
        ("spectrum_index", "<u4"),
        ("chemical_entity", io.vl_str()),
        ("confidence_score", "<f8"),
        ("evidence_chain_json", io.vl_str()),
    ]
    with h5py.File(p, "w") as f:
        g = f.create_group("study")
        io.write_compound_dataset(g, "identifications", records, fields)
    with h5py.File(p, "r") as f:
        out = io.read_compound_dataset(f["study"], "identifications")
        assert out == records


def test_compound_dataset_empty(tmp_path: Path) -> None:
    p = tmp_path / "empty.h5"
    fields = [("a", "<i4"), ("b", io.vl_str())]
    with h5py.File(p, "w") as f:
        g = f.create_group("g")
        io.write_compound_dataset(g, "t", [], fields)
    with h5py.File(p, "r") as f:
        assert io.read_compound_dataset(f["g"], "t") == []


# ------------------------------------------------------------ feature flags ---


def test_feature_flags_round_trip(tmp_path: Path) -> None:
    p = tmp_path / "flags.h5"
    feats = ["base_v1", "compound_identifications", "opt_digital_signatures"]
    with h5py.File(p, "w") as f:
        io.write_feature_flags(f, "1.1", feats)
    with h5py.File(p, "r") as f:
        version, features = io.read_feature_flags(f)
        assert version == "1.1"
        assert features == feats
        assert io.is_legacy_v1(f) is False


def test_feature_flags_legacy_v1_detection(tmp_path: Path) -> None:
    p = tmp_path / "legacy.h5"
    with h5py.File(p, "w") as f:
        io.write_fixed_string_attr(f, "mpeg_o_version", "1.0.0")
    with h5py.File(p, "r") as f:
        assert io.is_legacy_v1(f) is True
        version, features = io.read_feature_flags(f)
        assert version == "1.0.0"
        assert features == []


# ------------------------------------------- real fixture interop ---


def test_reads_features_from_objc_fixture(minimal_ms_fixture: Path) -> None:
    with h5py.File(minimal_ms_fixture, "r") as f:
        version, features = io.read_feature_flags(f)
        assert version == "1.1"
        assert "base_v1" in features
        assert "compound_identifications" in features
        assert io.is_legacy_v1(f) is False


def test_reads_signal_channel_from_objc_fixture(minimal_ms_fixture: Path) -> None:
    with h5py.File(minimal_ms_fixture, "r") as f:
        sig = f["study/ms_runs/run_0001/signal_channels"]
        mz = io.read_signal_channel(sig, "mz_values")
        intensity = io.read_signal_channel(sig, "intensity_values")
        assert mz.dtype == np.float64
        assert intensity.dtype == np.float64
        assert mz.shape == intensity.shape
        assert mz.shape[0] == 80  # 10 spectra * 8 points (from fixture)


def test_reads_compound_identifications_from_fixture(full_ms_fixture: Path) -> None:
    with h5py.File(full_ms_fixture, "r") as f:
        idents = io.read_compound_dataset(f["study"], "identifications")
        assert len(idents) == 10
        first = idents[0]
        assert first["run_name"] == "run_0001"
        assert first["chemical_entity"].startswith("CHEBI:")
        assert 0.0 <= first["confidence_score"] <= 1.0
        assert first["evidence_chain_json"].startswith("[")
