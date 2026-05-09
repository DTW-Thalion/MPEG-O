"""Unit tests for :mod:`ttio.encryption` error branches and
non-HDF5 (StorageGroup) provider paths.

Complements ``test_encryption.py`` (round-trip + ObjC-fixture parity)
by hitting:

- IV/tag length mismatches in :func:`decrypt_bytes`
- StorageGroup-backed paths in :func:`read_encrypted_channel`,
  :func:`encrypt_intensity_channel_in_group`, and
  :func:`decrypt_intensity_channel_in_group`
- File-path level wrappers (:func:`encrypt_intensity_channel_in_run`,
  :func:`decrypt_intensity_channel_in_run`,
  :func:`decrypt_intensity_channel_in_run_in_place`) for
  ``FileNotFoundError``, missing-run, and key-length validation.
"""
from __future__ import annotations

from pathlib import Path

import h5py
import numpy as np
import pytest

from ttio.encryption import (
    AES_KEY_LEN,
    SealedBlob,
    decrypt_bytes,
    decrypt_intensity_channel_in_group,
    decrypt_intensity_channel_in_run,
    decrypt_intensity_channel_in_run_in_place,
    encrypt_bytes,
    encrypt_intensity_channel_in_group,
    encrypt_intensity_channel_in_run,
    read_encrypted_channel,
)


# ----------------------------------------------------- helpers ---

KEY = bytes(range(AES_KEY_LEN))


def _make_minimal_run(path: Path, run_name: str = "run_0001") -> None:
    """Write the smallest valid HDF5 fixture that has a signal_channels
    group with intensity_values plaintext."""
    with h5py.File(path, "w") as f:
        f.attrs["ttio_format_version"] = "0.6"
        study = f.create_group("study")
        runs = study.create_group("ms_runs")
        runs.attrs["_run_names"] = run_name
        from ttio.enums import AcquisitionMode
        g = runs.create_group(run_name)
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
        sc.create_dataset(
            "mz_values",
            data=np.array([100.0, 200.0, 300.0, 400.0], dtype="<f8"),
        )
        sc.create_dataset(
            "intensity_values",
            data=np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8"),
        )


# --------------------------------------------- decrypt_bytes branches ---


class TestDecryptBytesBranches:
    def test_iv_length_mismatch_raises(self) -> None:
        good = encrypt_bytes(b"hello", KEY)
        bad_iv_blob = SealedBlob(
            ciphertext=good.ciphertext, iv=b"\x00" * 11, tag=good.tag
        )
        with pytest.raises(ValueError, match="IV/tag length mismatch"):
            decrypt_bytes(bad_iv_blob, KEY)

    def test_tag_length_mismatch_raises(self) -> None:
        good = encrypt_bytes(b"hello", KEY)
        bad_tag_blob = SealedBlob(
            ciphertext=good.ciphertext, iv=good.iv, tag=b"\x00" * 15
        )
        with pytest.raises(ValueError, match="IV/tag length mismatch"):
            decrypt_bytes(bad_tag_blob, KEY)


# ----------------------------------- read_encrypted_channel branches ---


class TestReadEncryptedChannelBranches:
    def test_h5py_channel_not_encrypted_raises(self, tmp_path: Path) -> None:
        # File has plaintext intensity_values but no intensity_values_encrypted.
        path = tmp_path / "plain.tio"
        _make_minimal_run(path)
        with h5py.File(path, "r") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            with pytest.raises(KeyError, match="not encrypted"):
                read_encrypted_channel(sig, "intensity", KEY)

    def test_h5py_round_trip_via_in_group_helper(self, tmp_path: Path) -> None:
        # Encrypt via the in_group helper, then decrypt via read_encrypted_channel.
        path = tmp_path / "enc.tio"
        _make_minimal_run(path)
        with h5py.File(path, "r+") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            encrypt_intensity_channel_in_group(sig, KEY)
        with h5py.File(path, "r") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            recovered = read_encrypted_channel(sig, "intensity", KEY)
        np.testing.assert_array_equal(
            recovered, np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")
        )


# ------------------- in_group helpers — key length validation ---


class TestInGroupKeyValidation:
    def test_encrypt_in_group_rejects_short_key(self, tmp_path: Path) -> None:
        path = tmp_path / "x.tio"
        _make_minimal_run(path)
        with h5py.File(path, "r+") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            with pytest.raises(ValueError, match="32 bytes"):
                encrypt_intensity_channel_in_group(sig, b"short")

    def test_decrypt_in_group_rejects_short_key(self, tmp_path: Path) -> None:
        path = tmp_path / "x.tio"
        _make_minimal_run(path)
        with h5py.File(path, "r+") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            with pytest.raises(ValueError, match="32 bytes"):
                decrypt_intensity_channel_in_group(sig, b"short")


# --------------- file-path API: error branches + happy path ---


class TestFilePathApiErrorBranches:
    def test_encrypt_in_run_rejects_short_key(self, tmp_path: Path) -> None:
        path = tmp_path / "any.tio"
        # Don't bother making the file — key check is first.
        with pytest.raises(ValueError, match="32 bytes"):
            encrypt_intensity_channel_in_run(str(path), "run_0001", b"short")

    def test_encrypt_in_run_missing_file(self, tmp_path: Path) -> None:
        with pytest.raises(FileNotFoundError, match="File not found"):
            encrypt_intensity_channel_in_run(
                str(tmp_path / "nope.tio"), "run_0001", KEY
            )

    def test_encrypt_in_run_missing_run(self, tmp_path: Path) -> None:
        path = tmp_path / "missing_run.tio"
        _make_minimal_run(path, run_name="run_actual")
        with pytest.raises(FileNotFoundError, match="not found"):
            encrypt_intensity_channel_in_run(str(path), "run_ghost", KEY)

    def test_decrypt_in_run_rejects_short_key(self, tmp_path: Path) -> None:
        path = tmp_path / "any.tio"
        with pytest.raises(ValueError, match="32 bytes"):
            decrypt_intensity_channel_in_run(str(path), "run_0001", b"short")

    def test_decrypt_in_run_missing_file(self, tmp_path: Path) -> None:
        with pytest.raises(FileNotFoundError, match="File not found"):
            decrypt_intensity_channel_in_run(
                str(tmp_path / "nope.tio"), "run_0001", KEY
            )

    def test_decrypt_in_run_missing_run(self, tmp_path: Path) -> None:
        path = tmp_path / "f.tio"
        _make_minimal_run(path, run_name="run_actual")
        with pytest.raises(KeyError, match="not found"):
            decrypt_intensity_channel_in_run(str(path), "run_ghost", KEY)

    def test_decrypt_in_place_rejects_short_key(self, tmp_path: Path) -> None:
        path = tmp_path / "any.tio"
        with pytest.raises(ValueError, match="32 bytes"):
            decrypt_intensity_channel_in_run_in_place(
                str(path), "run_0001", b"short"
            )

    def test_decrypt_in_place_missing_file(self, tmp_path: Path) -> None:
        with pytest.raises(FileNotFoundError, match="File not found"):
            decrypt_intensity_channel_in_run_in_place(
                str(tmp_path / "nope.tio"), "run_0001", KEY
            )

    def test_decrypt_in_place_missing_run(self, tmp_path: Path) -> None:
        path = tmp_path / "f.tio"
        _make_minimal_run(path, run_name="run_actual")
        with pytest.raises(KeyError, match="not found"):
            decrypt_intensity_channel_in_run_in_place(
                str(path), "run_ghost", KEY
            )


# --------------------- file-path API happy path round-trip ---


class TestFilePathRoundTrip:
    def test_encrypt_then_decrypt_in_run(self, tmp_path: Path) -> None:
        path = tmp_path / "rt.tio"
        _make_minimal_run(path)

        encrypt_intensity_channel_in_run(str(path), "run_0001", KEY)
        with h5py.File(path, "r") as f:
            sc = f["study/ms_runs/run_0001/signal_channels"]
            assert "intensity_values_encrypted" in sc
            assert "intensity_values" not in sc

        recovered = decrypt_intensity_channel_in_run(str(path), "run_0001", KEY)
        np.testing.assert_array_equal(
            recovered, np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8")
        )

    def test_decrypt_in_place_round_trip(self, tmp_path: Path) -> None:
        path = tmp_path / "rt.tio"
        _make_minimal_run(path)
        encrypt_intensity_channel_in_run(str(path), "run_0001", KEY)
        decrypt_intensity_channel_in_run_in_place(str(path), "run_0001", KEY)
        with h5py.File(path, "r") as f:
            sc = f["study/ms_runs/run_0001/signal_channels"]
            assert "intensity_values_encrypted" not in sc
            assert "intensity_values" in sc
            np.testing.assert_array_equal(
                sc["intensity_values"][()],
                np.array([1.0, 2.0, 3.0, 4.0], dtype="<f8"),
            )


# ------------------ idempotency branches ---


class TestIdempotency:
    def test_encrypt_in_group_idempotent_on_already_encrypted(
        self, tmp_path: Path
    ) -> None:
        path = tmp_path / "i.tio"
        _make_minimal_run(path)
        with h5py.File(path, "r+") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            encrypt_intensity_channel_in_group(sig, KEY)
            # Second call must be a silent no-op — exercises the early
            # return branch.
            encrypt_intensity_channel_in_group(sig, KEY)

    def test_decrypt_in_group_idempotent_on_already_plaintext(
        self, tmp_path: Path
    ) -> None:
        path = tmp_path / "i.tio"
        _make_minimal_run(path)
        with h5py.File(path, "r+") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            # No encrypted channel present — decrypt should be a no-op.
            decrypt_intensity_channel_in_group(sig, KEY)

    def test_encrypt_raises_when_intensity_values_missing(
        self, tmp_path: Path
    ) -> None:
        path = tmp_path / "noiv.tio"
        _make_minimal_run(path)
        with h5py.File(path, "r+") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            del sig["intensity_values"]
            with pytest.raises(KeyError, match="intensity_values not found"):
                encrypt_intensity_channel_in_group(sig, KEY)


# --------------- non-HDF5 StorageGroup paths (Memory provider) ---


class TestMemoryProviderEncryption:
    """Exercise the StorageGroup-backed branches in
    ``_encrypt_intensity_in_signal_group`` / ``read_encrypted_channel``
    / ``_decrypt_intensity_in_signal_group``. These hit lines 222-241
    and 293-307 / 343-355 in the source."""

    def _make_memory_signal_group(self):
        from ttio.providers.memory import MemoryProvider
        from ttio.enums import Precision
        # Use a unique URL per test; provider stores are process-global.
        provider = MemoryProvider.open(
            f"memory://enc_test_{id(self)}", mode="w"
        )
        root = provider.root_group()
        sig = root.create_group("signal_channels")
        sig.create_dataset(
            "intensity_values", Precision.FLOAT64, length=5
        ).write(np.array([1.0, 2.5, 3.5, 4.0, 5.0], dtype="<f8"))
        return provider, sig

    def test_encrypt_in_memory_provider_round_trip(self) -> None:
        provider, sig = self._make_memory_signal_group()
        try:
            encrypt_intensity_channel_in_group(sig, KEY)
            assert sig.has_child("intensity_values_encrypted")
            assert not sig.has_child("intensity_values")
            assert sig.has_child("intensity_iv")
            assert sig.has_child("intensity_tag")
            assert sig.has_attribute("intensity_ciphertext_bytes")
            assert sig.has_attribute("intensity_original_count")
            assert sig.has_attribute("intensity_algorithm")

            recovered = read_encrypted_channel(sig, "intensity", KEY)
            np.testing.assert_array_equal(
                recovered, np.array([1.0, 2.5, 3.5, 4.0, 5.0], dtype="<f8")
            )

            # Decrypt back to plaintext via the in-group helper.
            decrypt_intensity_channel_in_group(sig, KEY)
            assert sig.has_child("intensity_values")
            assert not sig.has_child("intensity_values_encrypted")
            np.testing.assert_array_equal(
                sig.open_dataset("intensity_values").read(),
                np.array([1.0, 2.5, 3.5, 4.0, 5.0], dtype="<f8"),
            )
        finally:
            provider.close()

    def test_memory_provider_encrypt_idempotent(self) -> None:
        provider, sig = self._make_memory_signal_group()
        try:
            encrypt_intensity_channel_in_group(sig, KEY)
            # Second call: hits the StorageGroup branch's
            # ``has_child("intensity_values_encrypted")`` early return.
            encrypt_intensity_channel_in_group(sig, KEY)
        finally:
            provider.close()

    def test_memory_provider_encrypt_missing_intensity_raises(self) -> None:
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://noenc_{id(self)}", mode="w"
        )
        try:
            sig = provider.root_group().create_group("signal_channels")
            # No intensity_values dataset.
            with pytest.raises(KeyError, match="intensity_values not found"):
                encrypt_intensity_channel_in_group(sig, KEY)
        finally:
            provider.close()

    def test_memory_provider_read_encrypted_missing_raises(self) -> None:
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://nomiss_{id(self)}", mode="w"
        )
        try:
            sig = provider.root_group().create_group("signal_channels")
            with pytest.raises(KeyError, match="not encrypted"):
                read_encrypted_channel(sig, "intensity", KEY)
        finally:
            provider.close()

    def test_memory_provider_decrypt_idempotent_when_already_plaintext(
        self,
    ) -> None:
        from ttio.providers.memory import MemoryProvider
        provider = MemoryProvider.open(
            f"memory://nodec_{id(self)}", mode="w"
        )
        try:
            sig = provider.root_group().create_group("signal_channels")
            # No encrypted dataset present — early-return path.
            decrypt_intensity_channel_in_group(sig, KEY)
        finally:
            provider.close()
