"""Targeted error-branch / edge-case tests for ``ttio.transport.codec``.

Companion to ``tests/test_transport_codec.py`` — that file covers
the happy-path file → transport → file round-trips. This file fills
in the error branches and rare paths the default suite doesn't reach:

- :class:`TransportReader` truncation / non-monotonic / bulk-mode
  feature failure modes,
- ``_apply_wire_codec`` / ``_decode_wire_codec`` dispatch for genomic
  UINT8 codecs (RANS / BASE_PACK + unsupported id),
- ``_ingest_access_unit`` (slow path) precision / compression /
  mismatched-length branches,
- ``_spectrum_to_access_unit`` mass-spectrum + compression branches,
- ``write_blob_v2_*`` writer-side helpers,
- empty genomic run (``n_reads == 0``) emission path.
"""
from __future__ import annotations

import io
import struct
import zlib
from pathlib import Path

import numpy as np
import pytest

from ttio.enums import AcquisitionMode, Compression, Polarity, Precision
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.transport.codec import (
    TransportReader,
    TransportWriter,
    _apply_wire_codec,
    _decode_wire_codec,
    _ingest_access_unit,
    _spectrum_to_access_unit,
    file_to_transport,
    transport_to_file,
)
from ttio.transport.packets import (
    BULK_MODE_V2_BLOBS_FEATURE,
    HEADER_MAGIC,
    VERSION,
    AccessUnit,
    ChannelData,
    PacketFlag,
    PacketHeader,
    PacketType,
    pack_blob_mate_info,
    pack_blob_name_tok,
    pack_blob_ref_diff,
    pack_string,
)


# ---------------------------------------------------------- helpers


def _make_minimal_dataset(path: Path, *, n_spectra: int = 3) -> Path:
    """Write a small MS dataset to ``path`` (mirrors the helper in
    ``test_transport_codec.py``)."""
    points_per_spectrum = 4
    total_points = n_spectra * points_per_spectrum
    mz_all = np.arange(total_points, dtype="<f8") + 100.0
    intensity_all = (np.arange(total_points, dtype="<f8") + 1.0) * 1000.0
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz_all, "intensity": intensity_all},
        offsets=np.array(
            [i * points_per_spectrum for i in range(n_spectra)], dtype="<u8"
        ),
        lengths=np.full(n_spectra, points_per_spectrum, dtype="<u4"),
        retention_times=np.arange(n_spectra, dtype="<f8") + 1.0,
        ms_levels=np.ones(n_spectra, dtype="<i4"),
        polarities=np.full(n_spectra, int(Polarity.POSITIVE), dtype="<i4"),
        precursor_mzs=np.zeros(n_spectra, dtype="<f8"),
        precursor_charges=np.zeros(n_spectra, dtype="<i4"),
        base_peak_intensities=np.full(n_spectra, 4000.0, dtype="<f8"),
    )
    SpectralDataset.write_minimal(
        path,
        title="codec-unit-test fixture",
        isa_investigation_id="ISA-CODEC-UNIT",
        runs={"run_0001": run},
    )
    return path


# Hand-rolled header packing (same encoding as PacketHeader.to_bytes).
_HEADER_FMT = "<2sBBHHIIQ"


def _hand_packet(
    *,
    packet_type: int,
    payload: bytes,
    flags: int = 0,
    dataset_id: int = 0,
    au_sequence: int = 0,
    timestamp: int = 0,
) -> bytes:
    header = struct.pack(
        _HEADER_FMT,
        HEADER_MAGIC,
        VERSION,
        packet_type & 0xFF,
        flags & 0xFFFF,
        dataset_id & 0xFFFF,
        au_sequence & 0xFFFFFFFF,
        len(payload) & 0xFFFFFFFF,
        timestamp & 0xFFFFFFFFFFFFFFFF,
    )
    return header + payload


def _stream_header_payload(features: list[str], *, n_datasets: int = 0) -> bytes:
    return (
        pack_string("1.2", width=2)
        + pack_string("title", width=2)
        + pack_string("isa", width=2)
        + struct.pack("<H", len(features) & 0xFFFF)
        + b"".join(pack_string(f, width=2) for f in features)
        + struct.pack("<H", n_datasets & 0xFFFF)
    )


# ============================================================ wire-codec dispatch


class TestWireCodecDispatch:
    """``_apply_wire_codec`` / ``_decode_wire_codec`` round-trip + reject."""

    def test_codec_none_is_identity(self):
        assert _apply_wire_codec(b"hello", 0) == b"hello"
        assert _decode_wire_codec(b"hello", 0) == b"hello"

    def test_codec_rans_order0_round_trip(self):
        plaintext = b"AAAACCCCGGGGTTTTAAAACCCCGGGGTTTTAAAACCCCGGGGTTTT"
        encoded = _apply_wire_codec(plaintext, int(Compression.RANS_ORDER0))
        assert encoded != plaintext
        assert _decode_wire_codec(encoded, int(Compression.RANS_ORDER0)) == plaintext

    def test_codec_rans_order1_round_trip(self):
        plaintext = b"ACGT" * 32
        encoded = _apply_wire_codec(plaintext, int(Compression.RANS_ORDER1))
        assert _decode_wire_codec(encoded, int(Compression.RANS_ORDER1)) == plaintext

    def test_codec_base_pack_round_trip(self):
        # base_pack only encodes ACGT — give it a clean ACGT input.
        plaintext = b"ACGTACGT"
        encoded = _apply_wire_codec(plaintext, int(Compression.BASE_PACK))
        assert _decode_wire_codec(encoded, int(Compression.BASE_PACK)) == plaintext

    def test_codec_unsupported_apply_raises(self):
        # ZLIB (1) is intentionally not in the genomic dispatch table —
        # genomic UINT8 channels use NONE / RANS / BASE_PACK only.
        with pytest.raises(NotImplementedError, match="codec id"):
            _apply_wire_codec(b"x", int(Compression.ZLIB))

    def test_codec_unsupported_decode_raises(self):
        with pytest.raises(NotImplementedError, match="codec id"):
            _decode_wire_codec(b"x", int(Compression.ZLIB))


# ============================================================ TransportWriter API


class TestTransportWriterMisc:

    def test_use_compression_property_reflects_init(self, tmp_path):
        out = tmp_path / "out.tis"
        with TransportWriter(out, use_compression=True) as tw:
            assert tw.use_compression is True
        with TransportWriter(out, use_compression=False) as tw:
            assert tw.use_compression is False

    def test_write_blob_v2_mate_info_emits_packet(self):
        # Calling the helper directly emits one BLOB_V2_MATE_INFO
        # packet with the correct payload. Avoids the full
        # write_dataset path so we exercise the helper in isolation.
        buf = io.BytesIO()
        with TransportWriter(buf) as tw:
            tw.write_blob_v2_mate_info(
                dataset_id=2, chrom_names=["chr1", "chr2"], blob=b"\x01\x02",
            )
        buf.seek(0)
        types: list[int] = []
        with TransportReader(buf) as tr:
            # iter_packets requires a header presence on each pkt; the
            # blob helper shipped just one packet, so iter terminates
            # once the underlying stream is exhausted.
            for h, _payload in tr.iter_packets():
                types.append(int(h.packet_type))
        assert types == [int(PacketType.BLOB_V2_MATE_INFO)]

    def test_write_blob_v2_ref_diff_emits_packet(self):
        buf = io.BytesIO()
        with TransportWriter(buf) as tw:
            tw.write_blob_v2_ref_diff(
                dataset_id=3, reference_uri="GRCh38.p14", blob=b"x",
            )
        buf.seek(0)
        with TransportReader(buf) as tr:
            types = [int(h.packet_type) for h, _ in tr.iter_packets()]
        assert types == [int(PacketType.BLOB_V2_REF_DIFF)]

    def test_write_blob_v2_name_tok_emits_packet(self):
        buf = io.BytesIO()
        with TransportWriter(buf) as tw:
            tw.write_blob_v2_name_tok(dataset_id=4, blob=b"tok")
        buf.seek(0)
        with TransportReader(buf) as tr:
            types = [int(h.packet_type) for h, _ in tr.iter_packets()]
        assert types == [int(PacketType.BLOB_V2_NAME_TOK)]


# ============================================================ TransportReader truncation


class TestTransportReaderTruncation:

    def test_truncated_header_raises(self):
        # Stream cuts off in the middle of the header.
        bad = b"TI\x01\x03\x00\x00"  # 6 bytes — far short of HEADER_SIZE
        with pytest.raises(ValueError, match="truncated header"):
            with TransportReader(io.BytesIO(bad)) as tr:
                list(tr.iter_packets())

    def test_truncated_payload_raises(self):
        # Header claims payload_length=100 but only 5 bytes follow.
        header = struct.pack(
            _HEADER_FMT,
            HEADER_MAGIC, VERSION,
            int(PacketType.STREAM_HEADER) & 0xFF,
            0, 0, 0, 100, 0,
        )
        bad = header + b"hello"
        with pytest.raises(ValueError, match="truncated payload"):
            with TransportReader(io.BytesIO(bad)) as tr:
                list(tr.iter_packets())

    def test_truncated_crc_raises(self):
        # HAS_CHECKSUM flag set, payload is correct length but CRC bytes
        # are missing → truncated CRC-32C.
        payload = b"AB"
        header = struct.pack(
            _HEADER_FMT,
            HEADER_MAGIC, VERSION,
            int(PacketType.STREAM_HEADER) & 0xFF,
            int(PacketFlag.HAS_CHECKSUM) & 0xFFFF,
            0, 0, len(payload), 0,
        )
        bad = header + payload + b"\x00"  # only 1 of 4 CRC bytes
        with pytest.raises(ValueError, match="truncated CRC"):
            with TransportReader(io.BytesIO(bad)) as tr:
                list(tr.iter_packets())


# ============================================================ TransportReader bulk-mode


class TestBulkModeReader:

    def test_bulk_mode_declared_but_no_blobs_rejected(self, tmp_path):
        """StreamHeader features list contains the bulk-mode flag, but
        no Blob* packets arrive — the reader must fail closed (§6.4)."""
        buf = io.BytesIO()
        # StreamHeader payload with the bulk feature set, n_datasets=0
        sh_payload = _stream_header_payload(
            [BULK_MODE_V2_BLOBS_FEATURE], n_datasets=0,
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh_payload,
        ))
        # Followed straight by EndOfStream — no blobs.
        buf.write(_hand_packet(
            packet_type=int(PacketType.END_OF_STREAM), payload=b"",
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match=BULK_MODE_V2_BLOBS_FEATURE):
            transport_to_file(buf, tmp_path / "rt.tio")

    def test_bulk_mode_blob_dataset_id_mismatch_rejected(self, tmp_path):
        """A BlobV2MateInfo packet whose payload dataset_id differs
        from the header.dataset_id must be rejected."""
        buf = io.BytesIO()
        sh_payload = _stream_header_payload(
            [BULK_MODE_V2_BLOBS_FEATURE], n_datasets=1,
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh_payload,
        ))
        # DatasetHeader for dataset_id=1 (genomic).
        dh_payload = (
            struct.pack("<H", 1)
            + pack_string("genomic_0001")
            + struct.pack("<B", 7)  # acquisition_mode
            + pack_string("TTIOGenomicRead")
            + struct.pack("<B", 0)  # n_channels
            + pack_string("{}", width=4)
            + struct.pack("<I", 0)  # expected_au_count
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh_payload,
            dataset_id=1,
        ))
        # Blob payload claims dataset_id=99 but header.dataset_id=1.
        bad_blob = pack_blob_mate_info(
            dataset_id=99, chrom_names=[], blob=b"",
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.BLOB_V2_MATE_INFO),
            payload=bad_blob,
            dataset_id=1,
        ))
        buf.write(_hand_packet(
            packet_type=int(PacketType.END_OF_STREAM), payload=b"",
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="BlobV2MateInfo dataset_id"):
            transport_to_file(buf, tmp_path / "rt.tio")

    def test_duplicate_blob_v2_mate_info_rejected(self, tmp_path):
        buf = io.BytesIO()
        sh = _stream_header_payload(
            [BULK_MODE_V2_BLOBS_FEATURE], n_datasets=1,
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        dh = (
            struct.pack("<H", 1)
            + pack_string("g")
            + struct.pack("<B", 7)
            + pack_string("TTIOGenomicRead")
            + struct.pack("<B", 0)
            + pack_string("{}", width=4)
            + struct.pack("<I", 0)
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh, dataset_id=1,
        ))
        blob = pack_blob_mate_info(dataset_id=1, chrom_names=[], blob=b"")
        # Emit the same blob twice — second arrival must fail.
        for _ in range(2):
            buf.write(_hand_packet(
                packet_type=int(PacketType.BLOB_V2_MATE_INFO),
                payload=blob, dataset_id=1,
            ))
        buf.write(_hand_packet(
            packet_type=int(PacketType.END_OF_STREAM), payload=b"",
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="duplicate BlobV2MateInfo"):
            transport_to_file(buf, tmp_path / "rt.tio")

    def test_blob_v2_ref_diff_dataset_id_mismatch_rejected(self, tmp_path):
        buf = io.BytesIO()
        sh = _stream_header_payload(
            [BULK_MODE_V2_BLOBS_FEATURE], n_datasets=1,
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        dh = (
            struct.pack("<H", 1)
            + pack_string("g")
            + struct.pack("<B", 7)
            + pack_string("TTIOGenomicRead")
            + struct.pack("<B", 0)
            + pack_string("{}", width=4)
            + struct.pack("<I", 0)
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh, dataset_id=1,
        ))
        bad_blob = pack_blob_ref_diff(
            dataset_id=42, reference_uri="x", blob=b"",
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.BLOB_V2_REF_DIFF),
            payload=bad_blob, dataset_id=1,
        ))
        buf.write(_hand_packet(
            packet_type=int(PacketType.END_OF_STREAM), payload=b"",
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="BlobV2RefDiff dataset_id"):
            transport_to_file(buf, tmp_path / "rt.tio")

    def test_duplicate_blob_v2_ref_diff_rejected(self, tmp_path):
        buf = io.BytesIO()
        sh = _stream_header_payload(
            [BULK_MODE_V2_BLOBS_FEATURE], n_datasets=1,
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        dh = (
            struct.pack("<H", 1) + pack_string("g")
            + struct.pack("<B", 7) + pack_string("TTIOGenomicRead")
            + struct.pack("<B", 0) + pack_string("{}", width=4)
            + struct.pack("<I", 0)
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh, dataset_id=1,
        ))
        blob = pack_blob_ref_diff(dataset_id=1, reference_uri="x", blob=b"")
        for _ in range(2):
            buf.write(_hand_packet(
                packet_type=int(PacketType.BLOB_V2_REF_DIFF),
                payload=blob, dataset_id=1,
            ))
        buf.write(_hand_packet(
            packet_type=int(PacketType.END_OF_STREAM), payload=b"",
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="duplicate BlobV2RefDiff"):
            transport_to_file(buf, tmp_path / "rt.tio")

    def test_blob_v2_name_tok_dataset_id_mismatch_rejected(self, tmp_path):
        buf = io.BytesIO()
        sh = _stream_header_payload(
            [BULK_MODE_V2_BLOBS_FEATURE], n_datasets=1,
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        dh = (
            struct.pack("<H", 1) + pack_string("g")
            + struct.pack("<B", 7) + pack_string("TTIOGenomicRead")
            + struct.pack("<B", 0) + pack_string("{}", width=4)
            + struct.pack("<I", 0)
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh, dataset_id=1,
        ))
        bad_blob = pack_blob_name_tok(dataset_id=42, blob=b"")
        buf.write(_hand_packet(
            packet_type=int(PacketType.BLOB_V2_NAME_TOK),
            payload=bad_blob, dataset_id=1,
        ))
        buf.write(_hand_packet(
            packet_type=int(PacketType.END_OF_STREAM), payload=b"",
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="BlobV2NameTok dataset_id"):
            transport_to_file(buf, tmp_path / "rt.tio")

    def test_duplicate_blob_v2_name_tok_rejected(self, tmp_path):
        buf = io.BytesIO()
        sh = _stream_header_payload(
            [BULK_MODE_V2_BLOBS_FEATURE], n_datasets=1,
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        dh = (
            struct.pack("<H", 1) + pack_string("g")
            + struct.pack("<B", 7) + pack_string("TTIOGenomicRead")
            + struct.pack("<B", 0) + pack_string("{}", width=4)
            + struct.pack("<I", 0)
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh, dataset_id=1,
        ))
        blob = pack_blob_name_tok(dataset_id=1, blob=b"")
        for _ in range(2):
            buf.write(_hand_packet(
                packet_type=int(PacketType.BLOB_V2_NAME_TOK),
                payload=blob, dataset_id=1,
            ))
        buf.write(_hand_packet(
            packet_type=int(PacketType.END_OF_STREAM), payload=b"",
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="duplicate BlobV2NameTok"):
            transport_to_file(buf, tmp_path / "rt.tio")

    def test_duplicate_stream_header_rejected(self, tmp_path):
        buf = io.BytesIO()
        sh = _stream_header_payload([], n_datasets=0)
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        # Second StreamHeader is illegal.
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="duplicate StreamHeader"):
            transport_to_file(buf, tmp_path / "rt.tio")


# ============================================================ slow-path ingest


class TestIngestAccessUnitSlowPath:
    """``_ingest_access_unit`` is the dataclass-based slow path
    (``_ingest_access_unit_bytes`` is the fast path used by
    ``read_to_dataset``). Exercising it directly covers lines 1294-1332.
    """

    def _empty_rd(self, channel_names: list[str]) -> dict:
        return {
            "channels": {c: [] for c in channel_names},
            "offsets": [],
            "lengths": [],
            "retention_times": [],
            "ms_levels": [],
            "polarities": [],
            "precursor_mzs": [],
            "precursor_charges": [],
            "base_peak_intensities": [],
            "running_offset": 0,
        }

    def test_appends_one_au(self):
        rd = self._empty_rd(["mz", "intensity"])
        au = AccessUnit(
            spectrum_class=0, acquisition_mode=0, ms_level=2, polarity=0,
            retention_time=42.0, precursor_mz=500.0, precursor_charge=2,
            ion_mobility=0.0, base_peak_intensity=1e6,
            channels=[
                ChannelData("mz", int(Precision.FLOAT64),
                            int(Compression.NONE), 3,
                            struct.pack("<ddd", 1.0, 2.0, 3.0)),
                ChannelData("intensity", int(Precision.FLOAT64),
                            int(Compression.NONE), 3,
                            struct.pack("<ddd", 10.0, 20.0, 30.0)),
            ],
        )
        _ingest_access_unit(rd, au)
        assert rd["lengths"] == [3]
        assert rd["offsets"] == [0]
        assert rd["retention_times"] == [42.0]
        assert rd["ms_levels"] == [2]
        assert rd["precursor_mzs"] == [500.0]
        assert rd["precursor_charges"] == [2]
        assert rd["base_peak_intensities"] == [1e6]

    def test_zlib_compressed_channel_decompressed(self):
        rd = self._empty_rd(["mz"])
        raw = struct.pack("<ddd", 1.0, 2.0, 3.0)
        compressed = zlib.compress(raw)
        au = AccessUnit(
            spectrum_class=0, acquisition_mode=0, ms_level=1, polarity=0,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[
                ChannelData("mz", int(Precision.FLOAT64),
                            int(Compression.ZLIB), 3, compressed),
            ],
        )
        _ingest_access_unit(rd, au)
        np.testing.assert_array_equal(
            rd["channels"]["mz"][0],
            np.array([1.0, 2.0, 3.0], dtype="<f8"),
        )

    def test_unsupported_precision_raises(self):
        rd = self._empty_rd(["mz"])
        au = AccessUnit(
            spectrum_class=0, acquisition_mode=0, ms_level=1, polarity=0,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[
                ChannelData("mz", int(Precision.UINT8),  # not FLOAT64
                            int(Compression.NONE), 1, b"\x00"),
            ],
        )
        with pytest.raises(NotImplementedError, match="precision"):
            _ingest_access_unit(rd, au)

    def test_unsupported_compression_raises(self):
        rd = self._empty_rd(["mz"])
        au = AccessUnit(
            spectrum_class=0, acquisition_mode=0, ms_level=1, polarity=0,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[
                ChannelData("mz", int(Precision.FLOAT64),
                            int(Compression.LZ4),  # unsupported in slow path
                            1, struct.pack("<d", 1.0)),
            ],
        )
        with pytest.raises(NotImplementedError, match="compression"):
            _ingest_access_unit(rd, au)

    def test_mismatched_channel_lengths_rejected(self):
        # Two channels in one AU with different lengths violate the
        # invariant that channel arrays in one AU share a common
        # n_elements value.
        rd = self._empty_rd(["mz", "intensity"])
        au = AccessUnit(
            spectrum_class=0, acquisition_mode=0, ms_level=1, polarity=0,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[
                ChannelData("mz", int(Precision.FLOAT64),
                            int(Compression.NONE), 2,
                            struct.pack("<dd", 1.0, 2.0)),
                ChannelData("intensity", int(Precision.FLOAT64),
                            int(Compression.NONE), 3,
                            struct.pack("<ddd", 10.0, 20.0, 30.0)),
            ],
        )
        with pytest.raises(ValueError, match="mismatched lengths"):
            _ingest_access_unit(rd, au)


# ============================================================ fast-path errors


class TestIngestAccessUnitBytesErrors:
    """``_ingest_access_unit_bytes`` is exercised end-to-end through
    :class:`TransportReader.read_to_dataset` on real round-trips. Here
    we cover its error branches by feeding pathological streams."""

    def test_au_payload_below_prefix_size_rejected(self, tmp_path):
        # An AU packet whose payload is < 38 bytes must surface the
        # "access unit payload too short" error from
        # _ingest_access_unit_bytes (line 1225).
        buf = io.BytesIO()
        sh = _stream_header_payload([], n_datasets=1)
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        dh = (
            struct.pack("<H", 1) + pack_string("r")
            + struct.pack("<B", 0)
            + pack_string("TTIOMassSpectrum")
            + struct.pack("<B", 1)  # one channel
            + pack_string("mz")
            + pack_string("{}", width=4)
            + struct.pack("<I", 0)
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh, dataset_id=1,
        ))
        # Truncated AU payload — only 10 bytes.
        buf.write(_hand_packet(
            packet_type=int(PacketType.ACCESS_UNIT),
            payload=b"\x00" * 10,
            dataset_id=1, au_sequence=0,
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="too short"):
            transport_to_file(buf, tmp_path / "rt.tio")

    def test_au_with_mismatched_channel_lengths_rejected(self, tmp_path):
        """Two channels in one AU with different element counts — must
        surface the 'mismatched lengths' error from line 1267."""
        # Build an AU directly with two channels of different length.
        # Manually pack the AU body since ChannelData.to_bytes is happy
        # to accept any (n_elements, data) pair.
        prefix = struct.pack(
            "<BBBBddBddB",
            0,  # MS
            0, 1, 0,
            0.0, 0.0,
            0,
            0.0, 0.0,
            2,  # 2 channels
        )
        ch_mz = (
            struct.pack("<H", 2) + b"mz"
            + struct.pack("<BBII", int(Precision.FLOAT64),
                          int(Compression.NONE), 2, 16)
            + struct.pack("<dd", 1.0, 2.0)
        )
        ch_int = (
            struct.pack("<H", 9) + b"intensity"
            + struct.pack("<BBII", int(Precision.FLOAT64),
                          int(Compression.NONE), 3, 24)
            + struct.pack("<ddd", 10.0, 20.0, 30.0)
        )
        au_payload = prefix + ch_mz + ch_int

        buf = io.BytesIO()
        sh = _stream_header_payload([], n_datasets=1)
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        dh = (
            struct.pack("<H", 1) + pack_string("r")
            + struct.pack("<B", 0)
            + pack_string("TTIOMassSpectrum")
            + struct.pack("<B", 2)
            + pack_string("mz") + pack_string("intensity")
            + pack_string("{}", width=4)
            + struct.pack("<I", 0)
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh, dataset_id=1,
        ))
        buf.write(_hand_packet(
            packet_type=int(PacketType.ACCESS_UNIT),
            payload=au_payload,
            dataset_id=1, au_sequence=0,
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="mismatched lengths"):
            transport_to_file(buf, tmp_path / "rt.tio")


# ============================================================ genomic ingest errors


class TestIngestGenomicAccessUnit:

    def test_non_genomic_class_in_genomic_dataset_rejected(self, tmp_path):
        """An AU with spectrum_class != 5 routed to a genomic dataset
        accumulator (because its DatasetHeader said TTIOGenomicRead)
        must raise (line 1120)."""
        buf = io.BytesIO()
        sh = _stream_header_payload([], n_datasets=1)
        buf.write(_hand_packet(
            packet_type=int(PacketType.STREAM_HEADER), payload=sh,
        ))
        dh = (
            struct.pack("<H", 1) + pack_string("g")
            + struct.pack("<B", 7)
            + pack_string("TTIOGenomicRead")
            + struct.pack("<B", 0)
            + pack_string("{}", width=4)
            + struct.pack("<I", 0)
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.DATASET_HEADER),
            payload=dh, dataset_id=1,
        ))
        # AU with spectrum_class=0 (MS) — wrong for a genomic header.
        au = AccessUnit(
            spectrum_class=0,
            acquisition_mode=0, ms_level=1, polarity=0,
            retention_time=0.0, precursor_mz=0.0, precursor_charge=0,
            ion_mobility=0.0, base_peak_intensity=0.0,
            channels=[],
        )
        buf.write(_hand_packet(
            packet_type=int(PacketType.ACCESS_UNIT),
            payload=au.to_bytes(),
            dataset_id=1, au_sequence=0,
        ))
        buf.seek(0)
        with pytest.raises(ValueError, match="spectrum_class"):
            transport_to_file(buf, tmp_path / "rt.tio")


# ============================================================ _spectrum_to_access_unit


class TestSpectrumToAccessUnit:
    """Exercise the per-Spectrum AU builder used by the WebSocket
    server. ``test_transport_codec.py``'s round-trips don't drive this
    helper — they go through the bulk path."""

    def test_mass_spectrum_uncompressed(self, tmp_path):
        src = _make_minimal_dataset(tmp_path / "src.tio")
        ds = SpectralDataset.open(src)
        try:
            run = ds.all_runs["run_0001"]
            spectrum = run[0]
            au = _spectrum_to_access_unit(spectrum, run, use_compression=False)
            # MS class is 0; ms_level and polarity come from the
            # MassSpectrum branch.
            assert au.spectrum_class == 0
            assert au.ms_level == 1
            # Channels should be FLOAT64 / NONE compression.
            assert all(ch.precision == int(Precision.FLOAT64) for ch in au.channels)
            assert all(ch.compression == int(Compression.NONE) for ch in au.channels)
            assert {ch.name for ch in au.channels} == {"mz", "intensity"}
        finally:
            ds.close()

    def test_mass_spectrum_with_zlib_compression(self, tmp_path):
        src = _make_minimal_dataset(tmp_path / "src.tio")
        ds = SpectralDataset.open(src)
        try:
            run = ds.all_runs["run_0001"]
            spectrum = run[0]
            au = _spectrum_to_access_unit(spectrum, run, use_compression=True,
                                          compression_codec="zlib")
            assert all(ch.compression == int(Compression.ZLIB) for ch in au.channels)
            # The compressed bytes round-trip through zlib.decompress.
            for ch in au.channels:
                decoded = zlib.decompress(ch.data)
                arr = np.frombuffer(decoded, dtype="<f8")
                assert arr.size == ch.n_elements
        finally:
            ds.close()


# ============================================================ writer-side empty / bulk


class TestWriterEdgeCases:

    def test_empty_genomic_run_emits_zero_aus(self, tmp_path):
        """An empty WrittenGenomicRun (n_reads == 0) hits the
        ``seq_full = b""`` branch in ``_emit_genomic_run_access_units``
        (lines 498-499)."""
        from ttio.written_genomic_run import WrittenGenomicRun
        run = WrittenGenomicRun(
            acquisition_mode=7,
            reference_uri="GRCh38.p14",
            platform="ILLUMINA",
            sample_name="NA12878",
            positions=np.zeros(0, dtype=np.int64),
            mapping_qualities=np.zeros(0, dtype=np.uint8),
            flags=np.zeros(0, dtype=np.uint32),
            sequences=np.zeros(0, dtype=np.uint8),
            qualities=np.zeros(0, dtype=np.uint8),
            offsets=np.zeros(0, dtype=np.uint64),
            lengths=np.zeros(0, dtype=np.uint32),
            cigars=[],
            read_names=[],
            mate_chromosomes=[],
            mate_positions=np.zeros(0, dtype=np.int64),
            template_lengths=np.zeros(0, dtype=np.int32),
            chromosomes=[],
        )
        src = tmp_path / "empty.tio"
        SpectralDataset.write_minimal(
            src, title="empty", isa_investigation_id="ISA-EMPTY",
            runs={}, genomic_runs={"genomic_0001": run},
        )
        buf = io.BytesIO()
        file_to_transport(src, buf)
        buf.seek(0)
        types: list[int] = []
        with TransportReader(buf) as tr:
            for header, _payload in tr.iter_packets():
                types.append(int(header.packet_type))
        # StreamHeader, DatasetHeader, EndOfDataset, EndOfStream — no AUs.
        assert int(PacketType.ACCESS_UNIT) not in types
        assert types[0] == int(PacketType.STREAM_HEADER)
        assert types[-1] == int(PacketType.END_OF_STREAM)

    def test_bulk_mode_no_genomic_runs_does_not_set_feature(self, tmp_path):
        """``use_bulk_mode=True`` on a dataset with NO genomic runs is
        silently a no-op — the ``BULK_MODE_V2_BLOBS_FEATURE`` flag must
        NOT appear in the StreamHeader features list (line 342 only
        runs when both bulk AND a genomic run are present)."""
        src = _make_minimal_dataset(tmp_path / "src.tio")
        buf = io.BytesIO()
        # MS-only dataset with use_bulk_mode=True.
        with TransportWriter(buf, use_bulk_mode=True) as tw:
            ds = SpectralDataset.open(src)
            try:
                tw.write_dataset(ds)
            finally:
                ds.close()
        buf.seek(0)
        # The StreamHeader payload's features list should not contain
        # the bulk feature flag (no genomic runs to bulk-carry).
        with TransportReader(buf) as tr:
            header, payload = next(tr.iter_packets())
        assert int(header.packet_type) == int(PacketType.STREAM_HEADER)
        assert BULK_MODE_V2_BLOBS_FEATURE.encode("utf-8") not in payload


def _make_genomic_dataset(path: Path) -> Path:
    """Write a genomic .tio with the v2 codec defaults so the writer
    finds ``mate_info/inline_v2`` and ``read_names`` codec=15 on disk
    (exercises the bulk emit path)."""
    from ttio.written_genomic_run import WrittenGenomicRun
    n_reads = 4
    read_length = 12
    sequences = np.frombuffer(b"ACGTACGTACGT" * n_reads, dtype=np.uint8)
    qualities = np.frombuffer(
        bytes([30] * (n_reads * read_length)), dtype=np.uint8,
    )
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 50, -1], dtype=np.int64),
        mapping_qualities=np.array([60, 55, 40, 0], dtype=np.uint8),
        flags=np.array([0x0003, 0x0003, 0x0003, 0x0004], dtype=np.uint32),
        sequences=sequences, qualities=qualities,
        offsets=np.arange(n_reads, dtype=np.uint64) * read_length,
        lengths=np.full(n_reads, read_length, dtype=np.uint32),
        cigars=[f"{read_length}M"] * n_reads,
        read_names=[f"read_{i}" for i in range(n_reads)],
        mate_chromosomes=[""] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "*"],
    )
    SpectralDataset.write_minimal(
        path, title="bulk-mode unit fixture",
        isa_investigation_id="ISA-BULK-UNIT",
        runs={}, genomic_runs={"genomic_0001": run},
    )
    return path


class TestBulkModeWriter:
    """Exercise ``_emit_genomic_run_v2_blobs`` (lines 415-468) by
    encoding a genomic dataset with the v2 blobs on disk under
    ``use_bulk_mode=True``.
    """

    def test_bulk_mode_emits_blob_packets(self, tmp_path):
        src = _make_genomic_dataset(tmp_path / "g.tio")
        buf = io.BytesIO()
        file_to_transport(src, buf, use_bulk_mode=True)
        buf.seek(0)
        types: list[int] = []
        with TransportReader(buf) as tr:
            for header, _payload in tr.iter_packets():
                types.append(int(header.packet_type))
        # mate_info inline_v2 + read_names codec=15 should both
        # produce one Blob packet each. sequences is a flat dataset
        # (no refdiff_v2 child) so no BLOB_V2_REF_DIFF.
        assert int(PacketType.BLOB_V2_MATE_INFO) in types
        assert int(PacketType.BLOB_V2_NAME_TOK) in types
        assert int(PacketType.BLOB_V2_REF_DIFF) not in types

    def test_bulk_mode_round_trip_via_read_to_dataset(self, tmp_path):
        """End-to-end: encode w/ bulk mode then decode through
        ``read_to_dataset``. Exercises the receiver-side BlobV2*
        dispatch (lines 932-969) and the BulkV2Blobs construction
        (lines 1030-1033)."""
        src = _make_genomic_dataset(tmp_path / "g.tio")
        stream = tmp_path / "g.tis"
        file_to_transport(src, stream, use_bulk_mode=True)
        rt = transport_to_file(stream, tmp_path / "rt.tio")
        try:
            assert "genomic_0001" in rt.genomic_runs
            assert len(rt.genomic_runs["genomic_0001"]) == 4
        finally:
            rt.close()


class TestBulkModeMultiBlock:
    """A blocks_v1 run with more than one block has no single blob per
    channel, so bulk mode falls back to per-AU carriage for it."""

    def test_multi_block_run_is_sent_per_au(self, tmp_path):
        from _genomic_fixture import make_written_genomic_run
        from ttio.genomic import GenomicStreamWriter
        run = make_written_genomic_run(n_reads=40, read_len=20, paired=True)
        src = tmp_path / "mb.tio"
        SpectralDataset.write_minimal(src, title="mb", isa_investigation_id="ISA-MB", runs={})
        with SpectralDataset.open(src, writable=True) as ds, GenomicStreamWriter(
                ds.study_group, "genomic_0001", acquisition_mode=run.acquisition_mode,
                reference_uri=run.reference_uri, platform=run.platform,
                sample_name=run.sample_name, block_reads=15) as w:
            w.append_batch(run)
        stream = tmp_path / "mb.tis"
        file_to_transport(src, stream, use_bulk_mode=True)
        types: list[int] = []
        with TransportReader(stream) as tr:
            for header, _payload in tr.iter_packets():
                types.append(int(header.packet_type))
        assert int(PacketType.BLOB_V2_MATE_INFO) not in types
        assert int(PacketType.BLOB_V2_NAME_TOK) not in types
        rt = transport_to_file(stream, tmp_path / "rt.tio")
        try:
            g = rt.genomic_runs["genomic_0001"]
            assert len(g) == 40
            assert [r.read_name for r in g] == run.read_names
        finally:
            rt.close()


class TestSpectrumWithoutSignalArray:
    """Spectrum.has_signal_array(name) returning False makes
    ``_spectrum_to_access_unit`` skip the channel (line 765)."""

    def test_skips_channel_without_signal_array(self, monkeypatch, tmp_path):
        src = _make_minimal_dataset(tmp_path / "src.tio")
        ds = SpectralDataset.open(src)
        try:
            run = ds.all_runs["run_0001"]
            spectrum = run[0]
            # Wrap to inject a synthetic channel name that doesn't
            # exist on the spectrum. We monkey-patch the run's
            # channel_names list to include an extra entry; the
            # codec should silently skip it.
            extra_names = list(run.channel_names) + ["__nonexistent__"]
            monkeypatch.setattr(run, "channel_names", extra_names)
            au = _spectrum_to_access_unit(spectrum, run)
            # Only the real channels should appear.
            assert {ch.name for ch in au.channels} == {"mz", "intensity"}
        finally:
            ds.close()
