"""v0.10 M69: AcquisitionSimulator determinism and AU-shape tests."""
from __future__ import annotations

import io
from pathlib import Path

import pytest

from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType
from ttio.transport.simulator import AcquisitionSimulator


class TestSimulatorBasics:

    def test_stream_count(self, tmp_path):
        sim = AcquisitionSimulator(scan_rate=10, duration=2.0, seed=1)
        buf = io.BytesIO()
        with TransportWriter(buf) as tw:
            n = sim.stream_to_writer(tw)
        assert n == 20  # 10 Hz * 2 s
        buf.seek(0)
        with TransportReader(buf) as tr:
            packets = list(tr.iter_packets())
        au_count = sum(
            1 for h, _ in packets if h.packet_type == int(PacketType.ACCESS_UNIT)
        )
        assert au_count == 20

    def test_deterministic_with_seed(self, tmp_path):
        a = io.BytesIO()
        with TransportWriter(a) as tw:
            AcquisitionSimulator(seed=42, duration=1.0, scan_rate=5).stream_to_writer(tw)
        b = io.BytesIO()
        with TransportWriter(b) as tw:
            AcquisitionSimulator(seed=42, duration=1.0, scan_rate=5).stream_to_writer(tw)
        # Byte-identical except for the per-packet timestamp_ns (which
        # is not stable across runs). Compare only the payload bytes.
        a.seek(0); b.seek(0)
        with TransportReader(a) as ra, TransportReader(b) as rb:
            pa = [(h.packet_type, payload) for h, payload in ra.iter_packets()]
            pb = [(h.packet_type, payload) for h, payload in rb.iter_packets()]
        assert pa == pb

    def test_different_seeds_differ(self):
        a = io.BytesIO()
        with TransportWriter(a) as tw:
            AcquisitionSimulator(seed=1, duration=1.0, scan_rate=5).stream_to_writer(tw)
        b = io.BytesIO()
        with TransportWriter(b) as tw:
            AcquisitionSimulator(seed=2, duration=1.0, scan_rate=5).stream_to_writer(tw)
        assert a.getvalue() != b.getvalue()

    def test_rt_monotonic(self):
        buf = io.BytesIO()
        with TransportWriter(buf) as tw:
            AcquisitionSimulator(
                scan_rate=20, duration=1.5, seed=7
            ).stream_to_writer(tw)
        buf.seek(0)
        from ttio.transport.packets import AccessUnit
        last_rt = -1.0
        with TransportReader(buf) as tr:
            for h, payload in tr.iter_packets():
                if h.packet_type != int(PacketType.ACCESS_UNIT):
                    continue
                au = AccessUnit.from_bytes(payload)
                assert au.retention_time >= last_rt
                last_rt = au.retention_time

    def test_ms1_fraction_approximate(self):
        # With ms1_fraction=0.5 and 200 scans, expect ~100 MS1. Allow
        # generous tolerance because it's stochastic.
        buf = io.BytesIO()
        with TransportWriter(buf) as tw:
            AcquisitionSimulator(
                scan_rate=100, duration=2.0, ms1_fraction=0.5, seed=123
            ).stream_to_writer(tw)
        buf.seek(0)
        from ttio.transport.packets import AccessUnit
        ms1 = ms2 = 0
        with TransportReader(buf) as tr:
            for h, payload in tr.iter_packets():
                if h.packet_type != int(PacketType.ACCESS_UNIT):
                    continue
                au = AccessUnit.from_bytes(payload)
                if au.ms_level == 1:
                    ms1 += 1
                else:
                    ms2 += 1
        assert ms1 + ms2 == 200
        # 0.4..0.6 range for 50% fraction with 200 samples.
        assert 80 <= ms1 <= 120

    def test_ms2_precursors_come_from_ms1(self):
        """MS2 AUs should have nonzero precursor_mz pulled from the
        most recent MS1."""
        buf = io.BytesIO()
        with TransportWriter(buf) as tw:
            AcquisitionSimulator(
                scan_rate=50, duration=2.0, ms1_fraction=0.3, seed=9
            ).stream_to_writer(tw)
        buf.seek(0)
        from ttio.transport.packets import AccessUnit
        ms2_with_precursor = 0
        ms2_total = 0
        with TransportReader(buf) as tr:
            for h, payload in tr.iter_packets():
                if h.packet_type != int(PacketType.ACCESS_UNIT):
                    continue
                au = AccessUnit.from_bytes(payload)
                if au.ms_level == 2:
                    ms2_total += 1
                    if au.precursor_mz > 0:
                        ms2_with_precursor += 1
        # Every MS2 after the first MS1 should have a precursor.
        assert ms2_total > 0
        # Allow up to 1 MS2 without a precursor (if it fires before
        # any MS1).
        assert ms2_with_precursor >= ms2_total - 1

    def test_materializes_as_valid_ttio(self, tmp_path):
        mots = tmp_path / "sim.tis"
        with TransportWriter(mots) as tw:
            AcquisitionSimulator(seed=42, duration=1.0, scan_rate=5).stream_to_writer(tw)
        from ttio.transport.codec import transport_to_file
        ttio = transport_to_file(mots, tmp_path / "sim.tio")
        try:
            assert ttio.title == "Simulated acquisition"
            assert "simulated_run" in ttio.all_runs
            assert len(ttio.all_runs["simulated_run"]) == 5
        finally:
            ttio.close()


class TestAsyncStream:
    """Wall-clock pacing of the async simulator stream.

    Driven via ``asyncio.run`` so the test works whether or not the
    optional ``pytest-asyncio`` plugin is installed. Previous form
    used ``@pytest.mark.asyncio``, which silently produced
    "async def functions are not natively supported" failures when
    the plugin was absent — i.e. on the default ``pip install -e
    'python[test]'`` environment.
    """

    def test_async_stream_respects_rate(self, tmp_path):
        """5 Hz over 0.5s should take roughly 0.5s of wall-clock
        time. Allow 2x slack for CI noise."""
        import asyncio
        import time as _t
        buf = io.BytesIO()
        sim = AcquisitionSimulator(scan_rate=5, duration=0.5, seed=11)

        async def _run() -> tuple[int, float]:
            with TransportWriter(buf) as tw:
                start = _t.monotonic()
                n = await sim.stream(tw)
                return n, _t.monotonic() - start

        n, elapsed = asyncio.run(_run())
        assert n == 2
        assert 0.3 <= elapsed <= 1.5, f"elapsed={elapsed}"
