"""v1.0 encrypted transport round-trip tests.

Covers the full loop: plaintext → encrypted .mpgo → transport
stream → decrypted .mpgo → decrypt plaintext, and variants with
encrypted AU headers.
"""
from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("cryptography")
pytest.importorskip("h5py")

from mpeg_o.enums import AcquisitionMode, Polarity
from mpeg_o.encryption_per_au import decrypt_per_au_file, encrypt_per_au_file
from mpeg_o.feature_flags import (
    OPT_ENCRYPTED_AU_HEADERS,
    OPT_PER_AU_ENCRYPTION,
)
from mpeg_o.spectral_dataset import SpectralDataset, WrittenRun
from mpeg_o.transport.codec import TransportReader, TransportWriter
from mpeg_o.transport.encrypted import (
    is_per_au_encrypted,
    read_encrypted_to_file,
    write_encrypted_dataset,
)
from mpeg_o.transport.packets import PacketFlag, PacketType


KEY = b"\xCD" * 32


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
        spectrum_class="MPGOMassSpectrum",
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
        title="encrypted transport fixture",
        isa_investigation_id="ISA-ENCTRANS",
        runs={"run_0001": run},
    )
    return path


class TestDetection:

    def test_is_per_au_encrypted_before_encrypt(self, tmp_path):
        p = _make_plaintext(tmp_path / "src.mpgo")
        assert not is_per_au_encrypted(str(p))

    def test_is_per_au_encrypted_after_encrypt(self, tmp_path):
        p = _make_plaintext(tmp_path / "src.mpgo")
        encrypt_per_au_file(str(p), KEY)
        assert is_per_au_encrypted(str(p))


class TestEncryptedChannelRoundTrip:
    """ENCRYPTED-only mode (plaintext filter header)."""

    def _encrypt_then_stream(self, tmp_path: Path):
        src = _make_plaintext(tmp_path / "src.mpgo")
        encrypt_per_au_file(str(src), KEY)
        stream = io.BytesIO()
        with TransportWriter(stream) as tw:
            write_encrypted_dataset(tw, str(src))
        stream.seek(0)
        return src, stream

    def test_stream_contains_protection_metadata(self, tmp_path):
        _, stream = self._encrypt_then_stream(tmp_path)
        packet_types = []
        with TransportReader(stream) as tr:
            for header, _ in tr.iter_packets():
                packet_types.append(header.packet_type)
        assert int(PacketType.PROTECTION_METADATA) in packet_types

    def test_encrypted_flag_on_aus(self, tmp_path):
        _, stream = self._encrypt_then_stream(tmp_path)
        with TransportReader(stream) as tr:
            for header, _ in tr.iter_packets():
                if header.packet_type == int(PacketType.ACCESS_UNIT):
                    assert header.flags & int(PacketFlag.ENCRYPTED)
                    assert not (header.flags & int(PacketFlag.ENCRYPTED_HEADER))

    def test_full_roundtrip(self, tmp_path):
        src, stream = self._encrypt_then_stream(tmp_path)
        rt_path = tmp_path / "rt.mpgo"
        meta = read_encrypted_to_file(stream, rt_path)
        assert meta["title"] == "encrypted transport fixture"
        assert meta["runs"]["run_0001"]["n_spectra"] == 5
        # Receiver-side file is encrypted too.
        assert is_per_au_encrypted(str(rt_path))

        # Decrypt both ends; signal values must match.
        originals = decrypt_per_au_file(str(src), KEY)["run_0001"]
        rt_values = decrypt_per_au_file(str(rt_path), KEY)["run_0001"]
        for cname in ("mz", "intensity"):
            np.testing.assert_array_equal(originals[cname], rt_values[cname])


class TestEncryptedHeaderRoundTrip:
    """ENCRYPTED | ENCRYPTED_HEADER mode."""

    def _encrypt_headers_then_stream(self, tmp_path: Path):
        src = _make_plaintext(tmp_path / "src.mpgo")
        encrypt_per_au_file(str(src), KEY, encrypt_headers=True)
        stream = io.BytesIO()
        with TransportWriter(stream) as tw:
            write_encrypted_dataset(tw, str(src))
        stream.seek(0)
        return src, stream

    def test_both_flags_set_on_aus(self, tmp_path):
        _, stream = self._encrypt_headers_then_stream(tmp_path)
        with TransportReader(stream) as tr:
            for header, _ in tr.iter_packets():
                if header.packet_type == int(PacketType.ACCESS_UNIT):
                    assert header.flags & int(PacketFlag.ENCRYPTED)
                    assert header.flags & int(PacketFlag.ENCRYPTED_HEADER)

    def test_full_roundtrip_with_headers(self, tmp_path):
        src, stream = self._encrypt_headers_then_stream(tmp_path)
        rt_path = tmp_path / "rt.mpgo"
        meta = read_encrypted_to_file(stream, rt_path)
        assert meta["runs"]["run_0001"]["encrypted_headers"] is True
        assert is_per_au_encrypted(str(rt_path))

        # Both files should carry opt_encrypted_au_headers.
        import h5py
        with h5py.File(str(rt_path), "r") as f:
            raw = f.attrs.get("mpeg_o_features", b"[]")
            if isinstance(raw, bytes):
                raw = raw.decode()
            assert OPT_ENCRYPTED_AU_HEADERS in raw

        originals = decrypt_per_au_file(str(src), KEY)["run_0001"]
        rt_values = decrypt_per_au_file(str(rt_path), KEY)["run_0001"]
        for cname in ("mz", "intensity"):
            np.testing.assert_array_equal(originals[cname], rt_values[cname])
        # Header decrypt recovers fields on the receiver side.
        assert "__au_headers__" in rt_values
        orig_headers = originals["__au_headers__"]
        rt_headers = rt_values["__au_headers__"]
        assert orig_headers == rt_headers
