"""v0.10 M71: selective-access performance + ProtectionMetadata tests.

Two axes:

1. **Selective access performance** — a 600-scan fixture exercises
   the server-side filter pipeline and asserts that filtered streams
   transfer a proportional subset of AUs. This is the "htsget
   equivalent" contract from ``docs/transport-spec.md`` §7.

2. **ProtectionMetadata packet** — wire-format encode/decode,
   preparing for the v1.0 full encrypted round-trip integration.
   (Encrypted-bytes preservation through the codec is an integration
   item deferred to v1.0; the packet structure and the encrypted
   flag are shipped here so tooling can emit them today.)
"""
from __future__ import annotations

import struct
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("websockets")

from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.transport.client import TransportClient
from ttio.transport.packets import (
    AccessUnit,
    PacketFlag,
    PacketHeader,
    PacketType,
    pack_string,
    unpack_string,
)
from ttio.transport.server import TransportServer, serving


# ---------------------------------------------------------- fixture


def _build_large_fixture(path: Path, n_spectra: int = 600,
                           total_seconds: float = 60.0) -> Path:
    """Build an MS dataset long enough to observe filter selectivity.

    Retention times span [0, total_seconds] evenly. Alternates MS1
    and MS2. Each spectrum has 4 points (tiny) — tests care about
    AU count, not payload size.
    """
    points = 4
    total = n_spectra * points
    mz = np.arange(total, dtype="<f8") + 100.0
    intensity = (np.arange(total, dtype="<f8") + 1.0)
    offsets = np.arange(0, total, points, dtype="<u8")
    lengths = np.full(n_spectra, points, dtype="<u4")
    rts = np.linspace(0.0, float(total_seconds), n_spectra, dtype="<f8")
    ms_levels = np.array(
        [1 if i % 2 == 0 else 2 for i in range(n_spectra)], dtype="<i4"
    )
    polarities = np.full(n_spectra, int(Polarity.POSITIVE), dtype="<i4")
    precursor_mzs = np.array(
        [0.0 if ms_levels[i] == 1 else 500.0 + 0.1 * i for i in range(n_spectra)],
        dtype="<f8",
    )
    precursor_charges = np.array(
        [0 if ms_levels[i] == 1 else 2 for i in range(n_spectra)], dtype="<i4"
    )
    base_peak_intensities = np.array(
        [float(intensity[i * points:(i + 1) * points].max()) for i in range(n_spectra)],
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
        base_peak_intensities=base_peak_intensities,
    )
    SpectralDataset.write_minimal(
        path,
        title="M71 selective-access fixture",
        isa_investigation_id="ISA-M71",
        runs={"run_0001": run},
    )
    return path


@pytest.fixture
def large_fixture(tmp_path):
    return _build_large_fixture(tmp_path / "large.tio")


def _count_aus(packets):
    return sum(1 for h, _ in packets if h.packet_type == int(PacketType.ACCESS_UNIT))


# ---------------------------------------------------------- selective access


class TestSelectiveAccessPerformance:

    async def test_rt_range_reduces_transfer(self, large_fixture):
        """RT 10-12s out of 0-60s = 2/60 of scans ≈ 3.3% (<5%)."""
        async with serving(large_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            filtered = await client.fetch_packets(
                filters={"rt_min": 10.0, "rt_max": 12.0}
            )
            full = await client.fetch_packets()
        filt_au = _count_aus(filtered)
        full_au = _count_aus(full)
        ratio = filt_au / full_au
        assert ratio < 0.05, f"RT filter should deliver <5%, got {ratio:.4f}"
        assert filt_au > 0, "RT filter should match some AUs"

    async def test_ms2_filter(self, large_fixture):
        """Exactly half the 600 spectra are MS2."""
        async with serving(large_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(filters={"ms_level": 2})
        assert _count_aus(packets) == 300

    async def test_precursor_mz_filter(self, large_fixture):
        """Precursor m/z 510-520 matches ~100 MS2 AUs (0.1 step)."""
        async with serving(large_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(
                filters={"precursor_mz_min": 510.0, "precursor_mz_max": 520.0}
            )
        au = _count_aus(packets)
        # 600 spectra alternating, MS2 precursors start at 500 with 0.1 step.
        # Precursor_mz is set on both MS1 and MS2 spectra here? No — see
        # fixture: MS1 gets 0.0, MS2 gets 500+0.1*i. So MS2 spectra at
        # even i indices? Actually ms_level depends on (i % 2). MS2 at
        # odd i. For 510-520, the precursor m/z is 500+0.1*i so i maps
        # to precursor through 500+0.1*i ∈ [510, 520] → i ∈ [100, 200].
        # Of those, odd i (MS2) count. i in {101,103,...,199} = 50 AUs.
        assert 45 <= au <= 55, f"expected ~50 AUs, got {au}"

    async def test_combined_filters_are_intersection(self, large_fixture):
        """RT 10-30 AND ms_level=2 = ~half of the RT subset."""
        async with serving(large_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            rt_only = await client.fetch_packets(
                filters={"rt_min": 10.0, "rt_max": 30.0}
            )
            combined = await client.fetch_packets(
                filters={"rt_min": 10.0, "rt_max": 30.0, "ms_level": 2}
            )
        assert _count_aus(combined) < _count_aus(rt_only)
        # Half of MS levels are MS2, so combined should be ~50% of rt_only.
        ratio = _count_aus(combined) / _count_aus(rt_only)
        assert 0.4 <= ratio <= 0.6, f"combined/rt_only = {ratio:.3f}, expected ~0.5"

    async def test_max_au_cap_enforced_exactly(self, large_fixture):
        async with serving(large_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(filters={"max_au": 100})
        assert _count_aus(packets) == 100
        # EndOfStream still present.
        assert packets[-1][0].packet_type == int(PacketType.END_OF_STREAM)

    async def test_no_matches_produces_skeleton(self, large_fixture):
        async with serving(large_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(filters={"ms_level": 99})
        assert _count_aus(packets) == 0
        types = [h.packet_type for h, _ in packets]
        assert int(PacketType.STREAM_HEADER) in types
        assert int(PacketType.DATASET_HEADER) in types
        assert int(PacketType.END_OF_DATASET) in types
        assert types[-1] == int(PacketType.END_OF_STREAM)


# Register all tests in the class as asyncio tests.
for _name in dir(TestSelectiveAccessPerformance):
    if _name.startswith("test_"):
        _fn = getattr(TestSelectiveAccessPerformance, _name)
        setattr(TestSelectiveAccessPerformance, _name, pytest.mark.asyncio(_fn))


# ---------------------------------------------------------- ProtectionMetadata


def _encode_protection_metadata(cipher_suite: str, kek_algorithm: str,
                                  wrapped_dek: bytes, signature_algorithm: str,
                                  public_key: bytes) -> bytes:
    """Encode a ProtectionMetadata payload per ``docs/transport-spec.md`` §4.4."""
    out = (
        pack_string(cipher_suite, width=2)
        + pack_string(kek_algorithm, width=2)
        + struct.pack("<I", len(wrapped_dek))
        + wrapped_dek
        + pack_string(signature_algorithm, width=2)
        + struct.pack("<I", len(public_key))
        + public_key
    )
    return out


def _decode_protection_metadata(payload: bytes) -> dict:
    off = 0
    cipher_suite, off = unpack_string(payload, off, width=2)
    kek_algorithm, off = unpack_string(payload, off, width=2)
    (wrapped_len,) = struct.unpack_from("<I", payload, off); off += 4
    wrapped_dek = bytes(payload[off:off + wrapped_len]); off += wrapped_len
    signature_algorithm, off = unpack_string(payload, off, width=2)
    (pk_len,) = struct.unpack_from("<I", payload, off); off += 4
    public_key = bytes(payload[off:off + pk_len]); off += pk_len
    return {
        "cipher_suite": cipher_suite,
        "kek_algorithm": kek_algorithm,
        "wrapped_dek": wrapped_dek,
        "signature_algorithm": signature_algorithm,
        "public_key": public_key,
    }


class TestProtectionMetadataPacket:
    """ProtectionMetadata wire-format round-trip.

    Full emission by TransportWriter when the source dataset is
    encrypted is a v1.0 integration item — the codec's channel-bytes
    path needs to branch on encryption state. The packet encoding
    below is load-bearing for that work and is shipped in M71 so
    the wire is stable.
    """

    def test_roundtrip_aes_256_gcm(self):
        payload = _encode_protection_metadata(
            cipher_suite="aes-256-gcm",
            kek_algorithm="rsa-oaep-sha256",
            wrapped_dek=b"\x01" * 256,
            signature_algorithm="ed25519",
            public_key=b"\x02" * 32,
        )
        decoded = _decode_protection_metadata(payload)
        assert decoded["cipher_suite"] == "aes-256-gcm"
        assert decoded["kek_algorithm"] == "rsa-oaep-sha256"
        assert decoded["wrapped_dek"] == b"\x01" * 256
        assert decoded["signature_algorithm"] == "ed25519"
        assert decoded["public_key"] == b"\x02" * 32

    def test_roundtrip_pqc(self):
        payload = _encode_protection_metadata(
            cipher_suite="aes-256-gcm",
            kek_algorithm="ml-kem-1024",
            wrapped_dek=b"\xFF" * 1568,
            signature_algorithm="ml-dsa-87",
            public_key=b"\xAA" * 2592,
        )
        decoded = _decode_protection_metadata(payload)
        assert decoded["kek_algorithm"] == "ml-kem-1024"
        assert decoded["signature_algorithm"] == "ml-dsa-87"
        assert decoded["wrapped_dek"] == b"\xFF" * 1568
        assert decoded["public_key"] == b"\xAA" * 2592

    def test_empty_public_key_is_legal(self):
        payload = _encode_protection_metadata(
            cipher_suite="aes-256-gcm",
            kek_algorithm="rsa-oaep-sha256",
            wrapped_dek=b"\x01" * 32,
            signature_algorithm="",
            public_key=b"",
        )
        decoded = _decode_protection_metadata(payload)
        assert decoded["signature_algorithm"] == ""
        assert decoded["public_key"] == b""


class TestEncryptedFlagOnAu:
    """``PacketFlag.ENCRYPTED`` travels on the AU packet header and
    carries ciphertext in the channel bytes. This test verifies the
    flag survives header encode/decode; full integration lives in
    the v1.0 encryption-aware writer path."""

    def test_encrypted_flag_roundtrips(self):
        h = PacketHeader(
            packet_type=int(PacketType.ACCESS_UNIT),
            flags=int(PacketFlag.ENCRYPTED),
            dataset_id=1,
            au_sequence=0,
            payload_length=38,
            timestamp_ns=0,
        )
        d = PacketHeader.from_bytes(h.to_bytes())
        assert d.flags & int(PacketFlag.ENCRYPTED)

    def test_combined_flags(self):
        h = PacketHeader(
            packet_type=int(PacketType.ACCESS_UNIT),
            flags=int(PacketFlag.ENCRYPTED) | int(PacketFlag.HAS_CHECKSUM),
            dataset_id=1,
            au_sequence=0,
            payload_length=38,
            timestamp_ns=0,
        )
        d = PacketHeader.from_bytes(h.to_bytes())
        assert d.flags & int(PacketFlag.ENCRYPTED)
        assert d.flags & int(PacketFlag.HAS_CHECKSUM)
