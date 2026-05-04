"""v1.0 per-AU encryption file-level round-trip tests."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

import h5py

from ttio.enums import AcquisitionMode, Polarity
from ttio.encryption_per_au import decrypt_per_au_file, encrypt_per_au_file
from ttio.feature_flags import (
    OPT_ENCRYPTED_AU_HEADERS,
    OPT_PER_AU_ENCRYPTION,
)
from ttio.spectral_dataset import SpectralDataset, WrittenRun


KEY = b"\xAB" * 32  # deterministic test key


def _make_plaintext(path: Path, n_spectra: int = 5,
                     points_per_spectrum: int = 4) -> Path:
    total = n_spectra * points_per_spectrum
    mz = np.arange(total, dtype="<f8") + 100.0
    intensity = (np.arange(total, dtype="<f8") + 1.0) * 10.0
    offsets = np.arange(0, total, points_per_spectrum, dtype="<u8")
    lengths = np.full(n_spectra, points_per_spectrum, dtype="<u4")
    rts = np.arange(n_spectra, dtype="<f8") * 1.5
    ms_levels = np.array(
        [1 if i % 2 == 0 else 2 for i in range(n_spectra)], dtype="<i4"
    )
    polarities = np.full(n_spectra, int(Polarity.POSITIVE), dtype="<i4")
    precursor_mzs = np.array(
        [0.0 if ms_levels[i] == 1 else 500.0 + i for i in range(n_spectra)],
        dtype="<f8",
    )
    precursor_charges = np.array(
        [0 if ms_levels[i] == 1 else 2 for i in range(n_spectra)], dtype="<i4"
    )
    base_peak = np.array(
        [float(intensity[i * points_per_spectrum:(i + 1) * points_per_spectrum].max())
         for i in range(n_spectra)],
        dtype="<f8",
    )
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=rts,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=precursor_mzs,
        precursor_charges=precursor_charges,
        base_peak_intensities=base_peak,
    )
    SpectralDataset.write_minimal(
        path,
        title="per-AU encryption fixture",
        isa_investigation_id="ISA-PERAU",
        runs={"run_0001": run},
    )
    return path


# ---------------------------------------------------------- channel-only


class TestPerAuEncryptionChannels:

    def test_encrypt_writes_segments_and_sets_flag(self, tmp_path):
        path = _make_plaintext(tmp_path / "src.tio")
        encrypt_per_au_file(str(path), KEY)

        with h5py.File(str(path), "r") as f:
            sig = f["study/ms_runs/run_0001/signal_channels"]
            assert "mz_segments" in sig
            assert "intensity_segments" in sig
            assert "mz_values" not in sig
            assert "intensity_values" not in sig
            # Algorithm attribute attached.
            algo = sig.attrs["mz_algorithm"]
            if isinstance(algo, bytes):
                algo = algo.decode()
            assert algo == "aes-256-gcm"
            features_json = f.attrs.get("ttio_features", b"[]")
            if isinstance(features_json, bytes):
                features_json = features_json.decode()
            assert OPT_PER_AU_ENCRYPTION in features_json
            assert OPT_ENCRYPTED_AU_HEADERS not in features_json

    def test_decrypt_recovers_plaintext_values(self, tmp_path):
        path = _make_plaintext(tmp_path / "src.tio")
        # Capture original plaintext before encrypt mutates the file.
        with SpectralDataset.open(path) as ds:
            run = ds.all_runs["run_0001"]
            originals = {
                c: np.concatenate([
                    np.asarray(run[i].signal_array(c).data)
                    for i in range(len(run))
                ])
                for c in run.channel_names
            }
        encrypt_per_au_file(str(path), KEY)
        recovered = decrypt_per_au_file(str(path), KEY)["run_0001"]
        for c in originals:
            np.testing.assert_array_equal(originals[c], recovered[c])

    def test_wrong_key_fails_decrypt(self, tmp_path):
        path = _make_plaintext(tmp_path / "src.tio")
        encrypt_per_au_file(str(path), KEY)
        bad_key = b"\x00" * 32
        with pytest.raises(Exception):
            decrypt_per_au_file(str(path), bad_key)


# ---------------------------------------------------------- with headers


class TestPerAuEncryptionWithHeaders:

    def test_encrypt_headers_writes_au_header_segments(self, tmp_path):
        path = _make_plaintext(tmp_path / "src.tio")
        encrypt_per_au_file(str(path), KEY, encrypt_headers=True)
        with h5py.File(str(path), "r") as f:
            idx = f["study/ms_runs/run_0001/spectrum_index"]
            assert "au_header_segments" in idx
            for plain_name in ("retention_times", "ms_levels", "polarities",
                                "precursor_mzs", "precursor_charges",
                                "base_peak_intensities"):
                assert plain_name not in idx
            # lengths stays plaintext (structural). v1.10 #10: offsets
            # is no longer written on disk; it's computed from cumsum.
            assert "offsets" not in idx
            assert "lengths" in idx
            features_json = f.attrs.get("ttio_features", b"[]")
            if isinstance(features_json, bytes):
                features_json = features_json.decode()
            assert OPT_ENCRYPTED_AU_HEADERS in features_json
            assert OPT_PER_AU_ENCRYPTION in features_json

    def test_decrypt_with_headers_recovers_fields(self, tmp_path):
        path = _make_plaintext(tmp_path / "src.tio", n_spectra=3)
        # Capture originals.
        with h5py.File(str(path), "r") as f:
            idx = f["study/ms_runs/run_0001/spectrum_index"]
            orig_rts = idx["retention_times"][...]
            orig_ms = idx["ms_levels"][...]
            orig_pmz = idx["precursor_mzs"][...]

        encrypt_per_au_file(str(path), KEY, encrypt_headers=True)
        recovered = decrypt_per_au_file(str(path), KEY)["run_0001"]
        headers = recovered["__au_headers__"]
        assert len(headers) == 3
        for i in range(3):
            assert headers[i]["retention_time"] == pytest.approx(float(orig_rts[i]))
            assert headers[i]["ms_level"] == int(orig_ms[i])
            assert headers[i]["precursor_mz"] == pytest.approx(float(orig_pmz[i]))

    def test_row_swap_rejected_end_to_end(self, tmp_path):
        """Swap two rows of the on-disk channel segments. Decrypt must
        reject (AAD binds ciphertext to au_sequence)."""
        path = _make_plaintext(tmp_path / "src.tio", n_spectra=3)
        encrypt_per_au_file(str(path), KEY)
        with h5py.File(str(path), "r+") as f:
            segs_ds = f["study/ms_runs/run_0001/signal_channels/intensity_segments"]
            arr = segs_ds[...]
            arr[[0, 1]] = arr[[1, 0]]
            segs_ds[...] = arr
        with pytest.raises(Exception):
            decrypt_per_au_file(str(path), KEY)
