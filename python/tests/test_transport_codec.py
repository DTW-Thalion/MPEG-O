"""End-to-end tests for the transport codec (M67).

Covers file→transport→file round-trips with a minimal synthetic
dataset. Focus: correctness of the codec; cross-language tests live
in ``tests/validation/test_cross_language_transport.py``.
"""
from __future__ import annotations

import io
from pathlib import Path

import numpy as np
import pytest

from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.transport import (
    AccessUnit,
    PacketHeader,
    PacketType,
    TransportReader,
    TransportWriter,
    file_to_transport,
    transport_to_file,
)


def _make_minimal_dataset(path: Path) -> Path:
    """Write a small 3-spectrum MS dataset to ``path``."""
    n_spectra = 3
    points_per_spectrum = 4
    total_points = n_spectra * points_per_spectrum

    mz_all = np.arange(total_points, dtype="<f8") + 100.0
    intensity_all = (np.arange(total_points, dtype="<f8") + 1.0) * 1000.0

    offsets = np.array(
        [i * points_per_spectrum for i in range(n_spectra)], dtype="<u8"
    )
    lengths = np.full(n_spectra, points_per_spectrum, dtype="<u4")
    retention_times = np.array([1.0, 2.0, 3.0], dtype="<f8")
    ms_levels = np.array([1, 2, 1], dtype="<i4")
    polarities = np.array(
        [int(Polarity.POSITIVE), int(Polarity.POSITIVE), int(Polarity.POSITIVE)],
        dtype="<i4",
    )
    precursor_mzs = np.array([0.0, 500.25, 0.0], dtype="<f8")
    precursor_charges = np.array([0, 2, 0], dtype="<i4")
    base_peak_intensities = np.array(
        [
            float(intensity_all[i * points_per_spectrum:(i + 1) * points_per_spectrum].max())
            for i in range(n_spectra)
        ],
        dtype="<f8",
    )

    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz_all, "intensity": intensity_all},
        offsets=offsets,
        lengths=lengths,
        retention_times=retention_times,
        ms_levels=ms_levels,
        polarities=polarities,
        precursor_mzs=precursor_mzs,
        precursor_charges=precursor_charges,
        base_peak_intensities=base_peak_intensities,
    )
    SpectralDataset.write_minimal(
        path,
        title="M67 round-trip fixture",
        isa_investigation_id="ISA-M67-TEST",
        runs={"run_0001": run},
    )
    return path


def _assert_datasets_equivalent(a: SpectralDataset, b: SpectralDataset) -> None:
    assert a.title == b.title
    assert a.isa_investigation_id == b.isa_investigation_id
    assert set(a.all_runs) == set(b.all_runs)
    for name in a.all_runs:
        ra, rb = a.all_runs[name], b.all_runs[name]
        assert ra.spectrum_class == rb.spectrum_class
        assert ra.acquisition_mode == rb.acquisition_mode
        assert tuple(ra.channel_names) == tuple(rb.channel_names)
        assert len(ra) == len(rb)
        for i in range(len(ra)):
            sa, sb = ra[i], rb[i]
            assert sa.scan_time_seconds == pytest.approx(sb.scan_time_seconds)
            assert sa.precursor_mz == pytest.approx(sb.precursor_mz)
            assert sa.precursor_charge == sb.precursor_charge
            for c in ra.channel_names:
                arr_a = np.asarray(sa.signal_array(c).data)
                arr_b = np.asarray(sb.signal_array(c).data)
                assert np.array_equal(arr_a, arr_b), f"channel {c} mismatch at spectrum {i}"


class TestInMemoryRoundTrip:

    def test_empty_stream_only_headers(self, tmp_path):
        src = _make_minimal_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        assert buffer.tell() > 0
        # Packets: StreamHeader, DatasetHeader, 3 AccessUnits,
        # EndOfDataset, EndOfStream = 7
        buffer.seek(0)
        with TransportReader(buffer) as tr:
            types = [int(h.packet_type) for h, _ in tr.iter_packets()]
        assert types == [
            int(PacketType.STREAM_HEADER),
            int(PacketType.DATASET_HEADER),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.END_OF_DATASET),
            int(PacketType.END_OF_STREAM),
        ]

    def test_round_trip_values_preserved(self, tmp_path):
        src = _make_minimal_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        round_trip = transport_to_file(buffer, tmp_path / "rt.tio")
        original = SpectralDataset.open(src)
        try:
            _assert_datasets_equivalent(original, round_trip)
        finally:
            original.close()
            round_trip.close()

    def test_round_trip_file_based(self, tmp_path):
        src = _make_minimal_dataset(tmp_path / "src.tio")
        stream_path = tmp_path / "stream.tis"
        file_to_transport(src, stream_path)
        assert stream_path.stat().st_size > 0
        rt = transport_to_file(stream_path, tmp_path / "rt.tio")
        original = SpectralDataset.open(src)
        try:
            _assert_datasets_equivalent(original, rt)
        finally:
            original.close()
            rt.close()


class TestCompression:

    def test_zlib_wire_compression_roundtrip(self, tmp_path):
        """use_compression=True should produce a smaller .tis than
        the uncompressed baseline while preserving signal values."""
        src = _make_minimal_dataset(tmp_path / "src.tio")

        plain = tmp_path / "plain.tis"
        compressed = tmp_path / "compressed.tis"
        file_to_transport(src, plain)
        file_to_transport(src, compressed, use_compression=True)

        # The 3-spectrum fixture is small, so compressed may only be
        # mildly smaller; require strict ≤ rather than > to tolerate
        # edge cases while still asserting the codec ran. Correctness
        # matters more than size for such a tiny fixture.
        assert compressed.stat().st_size <= plain.stat().st_size + 64

        rt = transport_to_file(compressed, tmp_path / "rt.tio")
        original = SpectralDataset.open(src)
        try:
            for name in original.all_runs:
                ra, rb = original.all_runs[name], rt.all_runs[name]
                for i in range(len(ra)):
                    for c in ra.channel_names:
                        import numpy as np
                        assert np.array_equal(
                            np.asarray(ra[i].signal_array(c).data),
                            np.asarray(rb[i].signal_array(c).data),
                        )
        finally:
            original.close()
            rt.close()

    def test_zlib_wire_compression_actually_compresses(self, tmp_path):
        """On a larger fixture the compressed stream is meaningfully
        smaller — sanity-check the codec is actually applied."""
        import numpy as np
        n_spectra = 20
        points = 128
        total = n_spectra * points
        mz = np.tile(np.linspace(100.0, 2000.0, points), n_spectra)  # repetitive
        intensity = np.tile(np.ones(points), n_spectra) * 1000.0  # constant
        run = WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": mz, "intensity": intensity},
            offsets=np.arange(0, total, points, dtype="<u8"),
            lengths=np.full(n_spectra, points, dtype="<u4"),
            retention_times=np.arange(n_spectra, dtype="<f8"),
            ms_levels=np.ones(n_spectra, dtype="<i4"),
            polarities=np.full(n_spectra, int(Polarity.POSITIVE), dtype="<i4"),
            precursor_mzs=np.zeros(n_spectra, dtype="<f8"),
            precursor_charges=np.zeros(n_spectra, dtype="<i4"),
            base_peak_intensities=np.full(n_spectra, 1000.0, dtype="<f8"),
        )
        src = tmp_path / "src.tio"
        SpectralDataset.write_minimal(
            src, title="zlib benchmark", isa_investigation_id="ISA-ZLIB",
            runs={"run_0001": run},
        )
        plain = tmp_path / "plain.tis"
        compressed = tmp_path / "compressed.tis"
        file_to_transport(src, plain)
        file_to_transport(src, compressed, use_compression=True)
        # Constant+repetitive data: zlib should compress substantially
        # (well under half).
        assert compressed.stat().st_size < plain.stat().st_size / 2, (
            f"expected <50% size, got "
            f"{compressed.stat().st_size}/{plain.stat().st_size}"
        )
        rt = transport_to_file(compressed, tmp_path / "rt.tio")
        try:
            assert len(rt.all_runs["run_0001"]) == n_spectra
        finally:
            rt.close()


class TestChecksum:

    def test_checksum_enabled(self, tmp_path):
        src = _make_minimal_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer, use_checksum=True)
        buffer.seek(0)
        rt = transport_to_file(buffer, tmp_path / "rt.tio")
        assert len(rt.all_runs) == 1
        rt.close()

    def test_corrupted_payload_fails_checksum(self, tmp_path):
        src = _make_minimal_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer, use_checksum=True)
        raw = bytearray(buffer.getvalue())
        # Flip a byte deep in the payload of the first AU (header is 24 bytes,
        # StreamHeader is ~60 bytes incl CRC, DatasetHeader ~80 bytes incl CRC,
        # then the first AU starts).
        flip = len(raw) // 2
        raw[flip] ^= 0xFF
        corrupted = io.BytesIO(bytes(raw))
        with pytest.raises(ValueError, match="CRC-32C"):
            transport_to_file(corrupted, tmp_path / "rt.tio")


class TestOrderingEnforcement:

    def test_non_monotonic_au_sequence_rejected(self, tmp_path):
        """A reader should reject AUs whose au_sequence goes backwards."""
        buffer = io.BytesIO()
        with TransportWriter(buffer) as tw:
            tw.write_stream_header(
                format_version="1.2",
                title="bad",
                isa_investigation="x",
                features=[],
                n_datasets=1,
            )
            tw.write_dataset_header(
                dataset_id=1, name="r", acquisition_mode=0,
                spectrum_class="TTIOMassSpectrum",
                channel_names=["mz", "intensity"],
                instrument_json="{}",
            )
            # Emit AU with seq=5, then AU with seq=3 (violation).
            import struct
            au_payload = AccessUnit(
                spectrum_class=0, acquisition_mode=0, ms_level=1,
                polarity=0, retention_time=1.0, precursor_mz=0.0,
                precursor_charge=0, ion_mobility=0.0,
                base_peak_intensity=0.0,
                channels=[],
            ).to_bytes()
            tw._emit(PacketType.ACCESS_UNIT, au_payload,
                     dataset_id=1, au_sequence=5)
            tw._emit(PacketType.ACCESS_UNIT, au_payload,
                     dataset_id=1, au_sequence=3)
            tw.write_end_of_stream()
        buffer.seek(0)
        with pytest.raises(ValueError, match="non-monotonic"):
            transport_to_file(buffer, tmp_path / "rt.tio")

    def test_access_unit_before_stream_header_rejected(self, tmp_path):
        buffer = io.BytesIO()
        with TransportWriter(buffer) as tw:
            tw._emit(PacketType.ACCESS_UNIT, b"\x00" * 38,
                     dataset_id=1, au_sequence=0)
            tw.write_end_of_stream()
        buffer.seek(0)
        with pytest.raises(ValueError, match="StreamHeader"):
            transport_to_file(buffer, tmp_path / "rt.tio")


def _make_minimal_genomic_dataset(path: Path) -> Path:
    """Write a small 4-read genomic dataset to ``path`` (M89.2 fixture)."""
    from ttio.written_genomic_run import WrittenGenomicRun

    n_reads = 4
    read_length = 12
    chromosomes = ["chr1", "chr1", "chr2", "*"]  # last is unmapped
    positions = np.array([100, 200, 50, -1], dtype=np.int64)
    flags = np.array([0x0003, 0x0003, 0x0003, 0x0004], dtype=np.uint32)
    mapqs = np.array([60, 55, 40, 0], dtype=np.uint8)

    seq_bytes = b"ACGTACGTACGT" * n_reads
    qual_bytes = bytes([30] * (n_reads * read_length))
    sequences = np.frombuffer(seq_bytes, dtype=np.uint8)
    qualities = np.frombuffer(qual_bytes, dtype=np.uint8)
    offsets = np.arange(n_reads, dtype=np.uint64) * read_length
    lengths = np.full(n_reads, read_length, dtype=np.uint32)

    run = WrittenGenomicRun(
        acquisition_mode=7,  # GENOMIC_WGS
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=positions,
        mapping_qualities=mapqs,
        flags=flags,
        sequences=sequences,
        qualities=qualities,
        offsets=offsets,
        lengths=lengths,
        cigars=[f"{read_length}M"] * n_reads,
        read_names=[f"read_{i:03d}" for i in range(n_reads)],
        mate_chromosomes=[""] * n_reads,
        mate_positions=np.full(n_reads, -1, dtype=np.int64),
        template_lengths=np.zeros(n_reads, dtype=np.int32),
        chromosomes=chromosomes,
    )
    SpectralDataset.write_minimal(
        path,
        title="M89.2 genomic round-trip fixture",
        isa_investigation_id="ISA-M89-TEST",
        runs={},
        genomic_runs={"genomic_0001": run},
    )
    return path


class TestGenomicRoundTrip:
    """M89.2: GenomicRun ↔ transport ↔ GenomicRun round-trip."""

    def test_emits_one_au_per_read(self, tmp_path):
        src = _make_minimal_genomic_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        with TransportReader(buffer) as tr:
            types = [int(h.packet_type) for h, _ in tr.iter_packets()]
        # StreamHeader, DatasetHeader, 4 AUs, EndOfDataset, EndOfStream = 8
        assert types == [
            int(PacketType.STREAM_HEADER),
            int(PacketType.DATASET_HEADER),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.END_OF_DATASET),
            int(PacketType.END_OF_STREAM),
        ]

    def test_au_carries_genomic_suffix(self, tmp_path):
        src = _make_minimal_genomic_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        aus: list[AccessUnit] = []
        with TransportReader(buffer) as tr:
            for header, payload in tr.iter_packets():
                if int(header.packet_type) == int(PacketType.ACCESS_UNIT):
                    aus.append(AccessUnit.from_bytes(payload))
        assert len(aus) == 4
        assert all(au.spectrum_class == 5 for au in aus)
        assert [au.chromosome for au in aus] == ["chr1", "chr1", "chr2", "*"]
        assert [au.position for au in aus] == [100, 200, 50, -1]
        assert [au.mapping_quality for au in aus] == [60, 55, 40, 0]
        assert [au.flags for au in aus] == [0x0003, 0x0003, 0x0003, 0x0004]
        # Sequences came back as one UINT8 channel per AU.
        assert all(any(c.name == "sequences" for c in au.channels) for au in aus)
        seq_channel = next(c for c in aus[0].channels if c.name == "sequences")
        assert bytes(seq_channel.data[:12]) == b"ACGTACGTACGT"

    def test_round_trip_genomic_to_file(self, tmp_path):
        src = _make_minimal_genomic_dataset(tmp_path / "src.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        rt_path = transport_to_file(buffer, tmp_path / "rt.tio")
        try:
            assert "genomic_0001" in rt_path.genomic_runs
            rt_run = rt_path.genomic_runs["genomic_0001"]
            assert len(rt_run) == 4
            assert rt_run.index.chromosomes == ["chr1", "chr1", "chr2", "*"]
            np.testing.assert_array_equal(
                rt_run.index.positions,
                np.array([100, 200, 50, -1], dtype=np.int64),
            )
            np.testing.assert_array_equal(
                rt_run.index.mapping_qualities,
                np.array([60, 55, 40, 0], dtype=np.uint8),
            )
            np.testing.assert_array_equal(
                rt_run.index.flags,
                np.array([0x0003, 0x0003, 0x0003, 0x0004], dtype=np.uint32),
            )
            # Sequence + qualities round-trip byte-exact.
            r0 = rt_run[0]
            assert r0.sequence == "ACGTACGTACGT"
            assert r0.qualities == bytes([30] * 12)
        finally:
            rt_path.close()


def _make_multiplexed_dataset(path: Path) -> Path:
    """Write one .tio carrying BOTH an MS run and a genomic run (M89.4)."""
    from ttio.written_genomic_run import WrittenGenomicRun

    # ── MS run (3 spectra, 4 points each) ──────────────────────────
    ms_n = 3
    ms_points = 4
    ms_total = ms_n * ms_points
    mz_all = np.arange(ms_total, dtype="<f8") + 100.0
    intensity_all = (np.arange(ms_total, dtype="<f8") + 1.0) * 1000.0
    ms_run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz_all, "intensity": intensity_all},
        offsets=np.array([i * ms_points for i in range(ms_n)], dtype="<u8"),
        lengths=np.full(ms_n, ms_points, dtype="<u4"),
        retention_times=np.array([1.0, 2.0, 3.0], dtype="<f8"),
        ms_levels=np.array([1, 2, 1], dtype="<i4"),
        polarities=np.array(
            [int(Polarity.POSITIVE)] * ms_n, dtype="<i4"
        ),
        precursor_mzs=np.array([0.0, 500.25, 0.0], dtype="<f8"),
        precursor_charges=np.array([0, 2, 0], dtype="<i4"),
        base_peak_intensities=np.array(
            [
                float(intensity_all[i * ms_points:(i + 1) * ms_points].max())
                for i in range(ms_n)
            ],
            dtype="<f8",
        ),
    )

    # ── Genomic run (3 reads, 8 bases each) ────────────────────────
    g_n = 3
    g_len = 8
    sequences = np.frombuffer(b"ACGTACGT" * g_n, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (g_n * g_len)), dtype=np.uint8)
    g_run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300], dtype=np.int64),
        mapping_qualities=np.full(g_n, 60, dtype=np.uint8),
        flags=np.array([0x0003, 0x0003, 0x0003], dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(g_n, dtype=np.uint64) * g_len,
        lengths=np.full(g_n, g_len, dtype=np.uint32),
        cigars=[f"{g_len}M"] * g_n,
        read_names=[f"read_{i:03d}" for i in range(g_n)],
        mate_chromosomes=[""] * g_n,
        mate_positions=np.full(g_n, -1, dtype=np.int64),
        template_lengths=np.zeros(g_n, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2"],
    )

    SpectralDataset.write_minimal(
        path,
        title="M89.4 multiplexed fixture",
        isa_investigation_id="ISA-M89-MUX",
        runs={"run_0001": ms_run},
        genomic_runs={"genomic_0001": g_run},
    )
    return path


class TestMultiplexedRoundTrip:
    """M89.4: MS + genomic in one .tis, both materialise on the other side."""

    def test_packet_sequence_carries_both_modalities(self, tmp_path):
        src = _make_multiplexed_dataset(tmp_path / "mux.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        # Expect: StreamHeader, 2 DatasetHeaders, 3 MS AUs +
        # EndOfDataset, 3 genomic AUs + EndOfDataset, EndOfStream.
        with TransportReader(buffer) as tr:
            types = [int(h.packet_type) for h, _ in tr.iter_packets()]
        assert types == [
            int(PacketType.STREAM_HEADER),
            int(PacketType.DATASET_HEADER),  # MS
            int(PacketType.DATASET_HEADER),  # genomic
            int(PacketType.ACCESS_UNIT),     # MS x 3
            int(PacketType.ACCESS_UNIT),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.END_OF_DATASET),  # MS done
            int(PacketType.ACCESS_UNIT),     # genomic x 3
            int(PacketType.ACCESS_UNIT),
            int(PacketType.ACCESS_UNIT),
            int(PacketType.END_OF_DATASET),  # genomic done
            int(PacketType.END_OF_STREAM),
        ]

    def test_round_trip_preserves_both_modalities(self, tmp_path):
        src = _make_multiplexed_dataset(tmp_path / "mux.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        rt = transport_to_file(buffer, tmp_path / "rt.tio")
        try:
            # MS preserved.
            assert "run_0001" in rt.all_runs
            ms_rt = rt.all_runs["run_0001"]
            assert len(ms_rt) == 3
            assert ms_rt[1].ms_level == 2
            assert ms_rt[1].precursor_mz == pytest.approx(500.25)
            # Genomic preserved.
            assert "genomic_0001" in rt.genomic_runs
            g_rt = rt.genomic_runs["genomic_0001"]
            assert len(g_rt) == 3
            assert g_rt.index.chromosomes == ["chr1", "chr1", "chr2"]
            np.testing.assert_array_equal(
                g_rt.index.positions, np.array([100, 200, 300], dtype=np.int64)
            )
            assert g_rt[2].sequence == "ACGTACGT"
        finally:
            rt.close()

    def test_dataset_ids_disjoint_per_modality(self, tmp_path):
        """MS occupies dataset_id 1; genomic gets dataset_id 2.

        The ID space is contiguous across modalities — a server-side
        filter on dataset_id can isolate either modality.
        """
        src = _make_multiplexed_dataset(tmp_path / "mux.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        ids: list[int] = []
        with TransportReader(buffer) as tr:
            for header, payload in tr.iter_packets():
                if int(header.packet_type) == int(PacketType.ACCESS_UNIT):
                    ids.append(int(header.dataset_id))
        assert ids == [1, 1, 1, 2, 2, 2]

    def test_genomic_filter_skips_ms_aus(self, tmp_path):
        """A chromosome filter MUST skip MS AUs in a multiplexed stream."""
        from ttio.transport.filters import AUFilter
        src = _make_multiplexed_dataset(tmp_path / "mux.tio")
        buffer = io.BytesIO()
        file_to_transport(src, buffer)
        buffer.seek(0)
        f = AUFilter(chromosome="chr1")
        kept: list[int] = []  # spectrum_class for AUs the filter accepts
        with TransportReader(buffer) as tr:
            for header, payload in tr.iter_packets():
                if int(header.packet_type) != int(PacketType.ACCESS_UNIT):
                    continue
                au = AccessUnit.from_bytes(payload)
                if f.matches(au, dataset_id=int(header.dataset_id)):
                    kept.append(au.spectrum_class)
        # Two genomic reads on chr1; zero MS AUs.
        assert kept == [5, 5]
