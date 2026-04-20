"""Tests for mpeg_o.transport.server / .client (v0.10 M68).

The fixture builder from ``test_transport_codec`` is re-used so the
server tests share a deterministic dataset shape with the offline
codec tests.
"""
from __future__ import annotations

import asyncio
import json
from pathlib import Path

import numpy as np
import pytest

pytest.importorskip("websockets")

from mpeg_o.enums import AcquisitionMode, Polarity
from mpeg_o.spectral_dataset import SpectralDataset, WrittenRun
from mpeg_o.transport.client import TransportClient
from mpeg_o.transport.packets import PacketType
from mpeg_o.transport.server import TransportServer, serving


def _make_fixture(path: Path, *, n_spectra: int = 5) -> Path:
    points = 3
    total = n_spectra * points
    mz = np.arange(total, dtype="<f8") + 100.0
    intensity = (np.arange(total, dtype="<f8") + 1.0) * 100.0
    offsets = np.arange(0, total, points, dtype="<u8")
    lengths = np.full(n_spectra, points, dtype="<u4")
    rts = np.linspace(1.0, float(n_spectra), n_spectra, dtype="<f8")
    ms_levels = np.array(
        [1 if i % 2 == 0 else 2 for i in range(n_spectra)], dtype="<i4"
    )
    polarities = np.full(n_spectra, int(Polarity.POSITIVE), dtype="<i4")
    precursor_mzs = np.array(
        [0.0 if ms_levels[i] == 1 else 500.0 + 10.0 * i for i in range(n_spectra)],
        dtype="<f8",
    )
    precursor_charges = np.array(
        [0 if ms_levels[i] == 1 else 2 for i in range(n_spectra)], dtype="<i4"
    )
    base_peak = np.array(
        [float(intensity[i * points:(i + 1) * points].max()) for i in range(n_spectra)],
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
        title="M68 server fixture",
        isa_investigation_id="ISA-M68-TEST",
        runs={"run_0001": run},
    )
    return path


@pytest.fixture
def mpgo_fixture(tmp_path):
    return _make_fixture(tmp_path / "src.mpgo")


class TestServerBasics:

    @pytest.mark.asyncio
    async def test_unfiltered_stream_full_dataset(self, mpgo_fixture, tmp_path):
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets()
        types = [h.packet_type for h, _ in packets]
        # 1 StreamHeader + 1 DatasetHeader + 5 AUs + 1 EndOfDataset + 1 EndOfStream
        assert types[0] == int(PacketType.STREAM_HEADER)
        assert types[-1] == int(PacketType.END_OF_STREAM)
        au_count = sum(1 for t in types if t == int(PacketType.ACCESS_UNIT))
        assert au_count == 5

    @pytest.mark.asyncio
    async def test_client_materializes_to_file(self, mpgo_fixture, tmp_path):
        output = tmp_path / "client_out.mpgo"
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            rt = await client.stream_to_file(output)
        try:
            assert rt.title == "M68 server fixture"
            assert rt.isa_investigation_id == "ISA-M68-TEST"
            assert "run_0001" in rt.all_runs
            assert len(rt.all_runs["run_0001"]) == 5
        finally:
            rt.close()


class TestFilters:

    @pytest.mark.asyncio
    async def test_ms_level_filter(self, mpgo_fixture):
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(filters={"ms_level": 2})
        au_count = sum(
            1 for h, _ in packets if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        # 5-spectrum fixture alternates 1,2,1,2,1 → 2 MS2s.
        assert au_count == 2

    @pytest.mark.asyncio
    async def test_rt_range_filter(self, mpgo_fixture):
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(
                filters={"rt_min": 2.5, "rt_max": 4.0}
            )
        au_count = sum(
            1 for h, _ in packets if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        # RTs are 1.0..5.0; 2.5..4.0 matches indices with rt in {3.0, 4.0} → 2.
        assert au_count == 2

    @pytest.mark.asyncio
    async def test_precursor_mz_filter(self, mpgo_fixture):
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(
                filters={"precursor_mz_min": 510.0, "precursor_mz_max": 520.0}
            )
        au_count = sum(
            1 for h, _ in packets if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        # MS2 spectra at indices 1 and 3 have precursor 510.0 and 530.0 →
        # only index 1 matches [510..520].
        assert au_count == 1

    @pytest.mark.asyncio
    async def test_combined_filters(self, mpgo_fixture):
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(
                filters={"ms_level": 2, "rt_max": 2.5}
            )
        au_count = sum(
            1 for h, _ in packets if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        # Only MS2 at rt ≤ 2.5 → index 1 (rt=2.0, ms_level=2) matches.
        assert au_count == 1

    @pytest.mark.asyncio
    async def test_max_au_cap(self, mpgo_fixture):
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(filters={"max_au": 2})
        au_count = sum(
            1 for h, _ in packets if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        assert au_count == 2

    @pytest.mark.asyncio
    async def test_no_matches_returns_headers_only(self, mpgo_fixture):
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            client = TransportClient(f"ws://127.0.0.1:{srv.port}")
            packets = await client.fetch_packets(filters={"ms_level": 99})
        au_count = sum(
            1 for h, _ in packets if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        assert au_count == 0
        # StreamHeader + DatasetHeader + EndOfDataset + EndOfStream still present.
        assert packets[0][0].packet_type == int(PacketType.STREAM_HEADER)
        assert packets[-1][0].packet_type == int(PacketType.END_OF_STREAM)


class TestConcurrency:

    @pytest.mark.asyncio
    async def test_multiple_concurrent_clients(self, mpgo_fixture):
        async with serving(mpgo_fixture, host="127.0.0.1", port=0) as srv:
            url = f"ws://127.0.0.1:{srv.port}"
            # Two concurrent fetches, one filtered and one full.
            full = TransportClient(url).fetch_packets()
            filtered = TransportClient(url).fetch_packets(
                filters={"ms_level": 2}
            )
            full_packets, filt_packets = await asyncio.gather(full, filtered)
        full_au = sum(
            1 for h, _ in full_packets
            if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        filt_au = sum(
            1 for h, _ in filt_packets
            if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        assert full_au == 5
        assert filt_au == 2

    @pytest.mark.asyncio
    async def test_graceful_shutdown(self, mpgo_fixture):
        server = TransportServer(mpgo_fixture, host="127.0.0.1", port=0)
        await server.start()
        try:
            client = TransportClient(f"ws://127.0.0.1:{server.port}")
            packets = await client.fetch_packets()
            assert len(packets) > 0
        finally:
            await server.stop()
