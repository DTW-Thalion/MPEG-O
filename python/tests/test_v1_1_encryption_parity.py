"""v1.1 parity: encrypt → close → reopen → is_encrypted → decrypt → read.

Covers the two bugs reported in the MPEG-O-MCP-Server M5 handoff:
 * Issue A: SpectralDataset.is_encrypted / encrypted_algorithm lost state
   across close/reopen.
 * Issue B: decrypt_with_key(key) left spec.intensity_array unusable
   because the in-memory channel cache was never rehydrated.

Byte-level parity with the ObjC/Java equivalents is exercised by
test_cross_compat.py; this file pins the Python surface so we notice
if the accessors regress without needing an ObjC fixture.
"""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np

from mpeg_o import SpectralDataset
from mpeg_o.enums import AcquisitionMode, EncryptionLevel


def _write_fixture(path: Path, run_names: list[str]) -> None:
    with h5py.File(path, "w") as f:
        f.attrs["mpeg_o_format_version"] = "1.1"
        study = f.create_group("study")
        runs = study.create_group("ms_runs")
        runs.attrs["_run_names"] = ",".join(run_names)
        for rname in run_names:
            g = runs.create_group(rname)
            g.attrs["acquisition_mode"] = np.int64(AcquisitionMode.MS1_DDA)
            g.attrs["spectrum_class"] = "MPGOMassSpectrum"
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


def test_issue_a_encrypted_state_survives_close_reopen(tmp_path: Path) -> None:
    path = tmp_path / "a.mpgo"
    _write_fixture(path, ["run_0001"])
    key = bytes(range(32))

    with SpectralDataset.open(str(path), writable=True) as ds:
        assert not ds.is_encrypted
        assert ds.encrypted_algorithm == ""
        ds.encrypt_with_key(key, EncryptionLevel.DATASET)
        assert ds.is_encrypted, "must flip in-memory immediately after encrypt"
        assert ds.encrypted_algorithm == "aes-256-gcm"

    # The critical assertion: state must persist to disk and be visible
    # to a fresh reader (this was Issue A).
    with SpectralDataset.open(str(path)) as ds:
        assert ds.is_encrypted
        assert ds.encrypted_algorithm == "aes-256-gcm"


def test_issue_b_decrypt_rehydrates_intensity_for_spectra(tmp_path: Path) -> None:
    path = tmp_path / "b.mpgo"
    _write_fixture(path, ["run_0001"])
    key = bytes(range(32))
    expected = np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")

    with SpectralDataset.open(str(path), writable=True) as ds:
        ds.encrypt_with_key(key, EncryptionLevel.DATASET)

    with SpectralDataset.open(str(path)) as ds:
        assert ds.is_encrypted
        run = ds.ms_runs["run_0001"]
        result = run.decrypt_with_key(key)
        # decrypt_with_key still returns the raw bytes for backward
        # compatibility with callers that want to do their own parsing.
        raw = np.frombuffer(result, dtype="<f8")
        np.testing.assert_array_equal(raw, expected)

        # Issue B: the spectrum API must see the decrypted intensities
        # without the caller having to parse bytes themselves.
        spec = run[0]
        np.testing.assert_array_equal(spec.intensity_array.data, expected)


def test_issue_b_dataset_level_decrypt_rehydrates_all_runs(tmp_path: Path) -> None:
    path = tmp_path / "c.mpgo"
    _write_fixture(path, ["run_A", "run_B"])
    key = bytes(range(32))
    expected = np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")

    with SpectralDataset.open(str(path), writable=True) as ds:
        ds.encrypt_with_key(key, EncryptionLevel.DATASET)

    with SpectralDataset.open(str(path)) as ds:
        assert ds.is_encrypted
        ds.decrypt_with_key(key)
        for rname in ("run_A", "run_B"):
            run = ds.ms_runs[rname]
            np.testing.assert_array_equal(run[0].intensity_array.data, expected,
                                          err_msg=f"{rname}: intensity mismatch")
