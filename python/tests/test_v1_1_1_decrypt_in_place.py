"""v1.1.1 parity: SpectralDataset.decrypt_in_place(path, key).

Covers the upstream-first piece of the TTI-O-MCP-Server M5
``ttio_decrypt_file`` tool: the existing v1.1.0 ``decrypt_with_key``
is read-only, so the admin flow that persists plaintext back to disk
needs a dedicated API. This suite verifies the classmethod reverses
``encrypt_with_key(..., DATASET)`` cleanly across single- and
multi-run fixtures.
"""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio import SpectralDataset
from ttio.enums import AcquisitionMode, EncryptionLevel


def _write_fixture(path: Path, run_names: list[str]) -> None:
    with h5py.File(path, "w") as f:
        f.attrs["ttio_format_version"] = "1.1"
        study = f.create_group("study")
        runs = study.create_group("ms_runs")
        runs.attrs["_run_names"] = ",".join(run_names)
        for rname in run_names:
            g = runs.create_group(rname)
            g.attrs["acquisition_mode"] = np.int64(AcquisitionMode.MS1_DDA)
            g.attrs["spectrum_class"] = "TTIOMassSpectrum"
            idx = g.create_group("spectrum_index")
            idx.create_dataset("offsets", data=np.array([0], dtype="<u8"))
            idx.create_dataset("lengths", data=np.array([4], dtype="<u4"))
            idx.create_dataset("retention_times", data=np.array([0.0], dtype="<f8"))
            idx.create_dataset("ms_levels", data=np.array([1], dtype="<i4"))
            idx.create_dataset("polarities", data=np.array([1], dtype="<i4"))
            idx.create_dataset("precursor_mzs", data=np.array([0.0], dtype="<f8"))
            idx.create_dataset("precursor_charges", data=np.array([0], dtype="<i4"))
            idx.create_dataset("base_peak_intensities", data=np.array([0.0], dtype="<f8"))
            sc = g.create_group("signal_channels")
            sc.attrs["channel_names"] = "mz,intensity"
            sc.create_dataset("mz_values",
                              data=np.array([100.0, 200.0, 300.0, 400.0], dtype="<f8"))
            sc.create_dataset("intensity_values",
                              data=np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8"))


def test_decrypt_in_place_restores_plaintext_single_run(tmp_path: Path) -> None:
    path = tmp_path / "a.tio"
    _write_fixture(path, ["run_0001"])
    key = bytes(range(32))
    expected = np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")

    with SpectralDataset.open(str(path), writable=True) as ds:
        ds.encrypt_with_key(key, EncryptionLevel.DATASET)

    SpectralDataset.decrypt_in_place(str(path), key)

    # File is now byte-compatible with the pre-encryption layout: root
    # @encrypted cleared, intensity_values back, encrypted siblings gone.
    with h5py.File(str(path), "r") as f:
        assert "encrypted" not in f.attrs
        sc = f["study/ms_runs/run_0001/signal_channels"]
        assert "intensity_values" in sc
        assert "intensity_values_encrypted" not in sc
        assert "intensity_iv" not in sc
        assert "intensity_tag" not in sc
        np.testing.assert_array_equal(sc["intensity_values"][()], expected)

    with SpectralDataset.open(str(path)) as ds:
        assert not ds.is_encrypted
        assert ds.encrypted_algorithm == ""
        spec = ds.ms_runs["run_0001"][0]
        np.testing.assert_array_equal(spec.intensity_array.data, expected)


def test_decrypt_in_place_handles_multi_run_dataset(tmp_path: Path) -> None:
    path = tmp_path / "b.tio"
    _write_fixture(path, ["run_A", "run_B", "run_C"])
    key = bytes(range(32))
    expected = np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")

    with SpectralDataset.open(str(path), writable=True) as ds:
        ds.encrypt_with_key(key, EncryptionLevel.DATASET)

    SpectralDataset.decrypt_in_place(str(path), key)

    with SpectralDataset.open(str(path)) as ds:
        assert not ds.is_encrypted
        for rname in ("run_A", "run_B", "run_C"):
            np.testing.assert_array_equal(
                ds.ms_runs[rname][0].intensity_array.data,
                expected,
                err_msg=f"{rname}: intensity mismatch after decrypt_in_place",
            )


def test_decrypt_in_place_idempotent_on_plaintext_file(tmp_path: Path) -> None:
    path = tmp_path / "c.tio"
    _write_fixture(path, ["run_0001"])
    key = bytes(range(32))

    # No encryption applied — decrypt_in_place should be a no-op that
    # still succeeds (no encrypted channels to strip, no root attr).
    SpectralDataset.decrypt_in_place(str(path), key)

    with SpectralDataset.open(str(path)) as ds:
        assert not ds.is_encrypted
        expected = np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")
        np.testing.assert_array_equal(
            ds.ms_runs["run_0001"][0].intensity_array.data, expected
        )


def test_decrypt_in_place_rejects_short_key(tmp_path: Path) -> None:
    path = tmp_path / "d.tio"
    _write_fixture(path, ["run_0001"])
    with pytest.raises(ValueError, match="32 bytes"):
        SpectralDataset.decrypt_in_place(str(path), b"too short")


def test_decrypt_in_place_missing_file(tmp_path: Path) -> None:
    with pytest.raises(FileNotFoundError):
        SpectralDataset.decrypt_in_place(str(tmp_path / "nope.tio"), bytes(32))
