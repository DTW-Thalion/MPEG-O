"""Acquisition simulator (v0.10 M69).

Produces synthetic TTI-O transport packets that mimic an LC-MS
instrument acquiring in real time. Two output modes:

- ``stream_to_writer(writer)`` — synchronous; produce every packet
  as fast as the writer can accept, no wall-clock pacing. Intended
  for offline fixture generation.
- ``stream(output)`` — async, produces packets at the configured
  scan rate in wall-clock time. Intended for live-streaming via a
  WebSocket, a ``TransportWriter`` hooked to a network sink, or any
  other async sink.

Cross-language equivalents: Java
``com.dtwthalion.ttio.transport.AcquisitionSimulator``, ObjC
``TTIOAcquisitionSimulator``.
"""
from __future__ import annotations

import asyncio
import random
import struct
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, BinaryIO

from .codec import (
    TransportWriter,
    _POLARITY_TO_WIRE,
    _SPECTRUM_CLASS_TO_WIRE,
)
from .packets import AccessUnit, ChannelData, PacketType
from ..enums import AcquisitionMode, Compression, Polarity, Precision


@dataclass
class SimulatorConfig:
    """Reproducible simulator parameters."""

    scan_rate: float = 10.0         # scans per second
    duration: float = 10.0          # seconds
    ms1_fraction: float = 0.3       # probability a scan is MS1
    mz_min: float = 100.0
    mz_max: float = 2000.0
    n_peaks: int = 200              # avg peaks per spectrum
    seed: int = 42

    @property
    def scan_count(self) -> int:
        return max(1, int(self.scan_rate * self.duration))

    @property
    def scan_interval(self) -> float:
        return 1.0 / self.scan_rate


class AcquisitionSimulator:
    """Simulates an LC-MS instrument producing spectra in real-time."""

    RUN_NAME = "simulated_run"
    DATASET_ID = 1
    FORMAT_VERSION = "1.2"
    TITLE = "Simulated acquisition"
    ISA_INVESTIGATION_ID = "ISA-SIMULATOR"

    def __init__(
        self,
        *,
        scan_rate: float = 10.0,
        duration: float = 10.0,
        ms1_fraction: float = 0.3,
        mz_range: tuple[float, float] = (100.0, 2000.0),
        n_peaks: int = 200,
        seed: int = 42,
    ):
        mz_min, mz_max = mz_range
        self._cfg = SimulatorConfig(
            scan_rate=scan_rate,
            duration=duration,
            ms1_fraction=ms1_fraction,
            mz_min=mz_min,
            mz_max=mz_max,
            n_peaks=n_peaks,
            seed=seed,
        )

    @property
    def config(self) -> SimulatorConfig:
        return self._cfg

    # ---------------------------------------------------------- synchronous

    def stream_to_writer(self, writer: TransportWriter) -> int:
        """Emit the full packet sequence to ``writer`` and return the
        number of AUs produced. No wall-clock pacing — useful for
        generating fixtures deterministically."""
        rng = random.Random(self._cfg.seed)
        writer.write_stream_header(
            format_version=self.FORMAT_VERSION,
            title=self.TITLE,
            isa_investigation=self.ISA_INVESTIGATION_ID,
            features=["base_v1"],
            n_datasets=1,
        )
        writer.write_dataset_header(
            dataset_id=self.DATASET_ID,
            name=self.RUN_NAME,
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            spectrum_class="TTIOMassSpectrum",
            channel_names=["mz", "intensity"],
            instrument_json=_SIMULATED_INSTRUMENT_JSON,
            expected_au_count=self._cfg.scan_count,
        )
        last_ms1_peak: float = 0.0
        for i in range(self._cfg.scan_count):
            au, last_ms1_peak = _generate_au(self._cfg, rng, i, last_ms1_peak)
            writer.write_access_unit(
                dataset_id=self.DATASET_ID, au_sequence=i, au=au
            )
        writer.write_end_of_dataset(
            dataset_id=self.DATASET_ID,
            final_au_sequence=self._cfg.scan_count,
        )
        writer.write_end_of_stream()
        return self._cfg.scan_count

    # ---------------------------------------------------------- asynchronous

    async def stream(self, writer: TransportWriter) -> int:
        """Async pacing: emit AUs at ``scan_rate`` Hz in wall-clock
        time. Returns the total AU count once ``duration`` seconds
        have elapsed (or the scan budget is exhausted).
        """
        rng = random.Random(self._cfg.seed)
        writer.write_stream_header(
            format_version=self.FORMAT_VERSION,
            title=self.TITLE,
            isa_investigation=self.ISA_INVESTIGATION_ID,
            features=["base_v1"],
            n_datasets=1,
        )
        writer.write_dataset_header(
            dataset_id=self.DATASET_ID,
            name=self.RUN_NAME,
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            spectrum_class="TTIOMassSpectrum",
            channel_names=["mz", "intensity"],
            instrument_json=_SIMULATED_INSTRUMENT_JSON,
            expected_au_count=0,  # 0 = real-time / unknown
        )
        start = time.monotonic()
        interval = self._cfg.scan_interval
        last_ms1_peak: float = 0.0
        for i in range(self._cfg.scan_count):
            au, last_ms1_peak = _generate_au(self._cfg, rng, i, last_ms1_peak)
            writer.write_access_unit(
                dataset_id=self.DATASET_ID, au_sequence=i, au=au
            )
            # Sleep until the next scan's wall-clock slot.
            target = start + (i + 1) * interval
            delay = target - time.monotonic()
            if delay > 0:
                await asyncio.sleep(delay)
        writer.write_end_of_dataset(
            dataset_id=self.DATASET_ID,
            final_au_sequence=self._cfg.scan_count,
        )
        writer.write_end_of_stream()
        return self._cfg.scan_count


_SIMULATED_INSTRUMENT_JSON = (
    '{"analyzer_type": "", "detector_type": "", '
    '"manufacturer": "TTI-O simulator", "model": "synthetic-v1", '
    '"serial_number": "", "source_type": ""}'
)


def _generate_au(
    cfg: SimulatorConfig,
    rng: random.Random,
    i: int,
    last_ms1_peak: float,
) -> tuple[AccessUnit, float]:
    """Produce one synthetic AccessUnit + updated MS1-peak memory."""
    rt = i * cfg.scan_interval
    is_ms1 = rng.random() < cfg.ms1_fraction
    ms_level = 1 if is_ms1 else 2

    # Number of peaks: Poisson-ish around n_peaks.
    jitter = rng.randint(-cfg.n_peaks // 4, cfg.n_peaks // 4)
    n_peaks = max(1, cfg.n_peaks + jitter)

    mzs = sorted(rng.uniform(cfg.mz_min, cfg.mz_max) for _ in range(n_peaks))
    intensities = [rng.uniform(10.0, 1.0e6) for _ in range(n_peaks)]

    # MS2 precursors are drawn from the most recent MS1 base peak.
    if is_ms1:
        base_peak_mz = mzs[max(range(n_peaks), key=lambda k: intensities[k])]
        last_ms1_peak = base_peak_mz
        precursor_mz = 0.0
        precursor_charge = 0
    else:
        precursor_mz = last_ms1_peak if last_ms1_peak > 0 else rng.uniform(
            cfg.mz_min, cfg.mz_max
        )
        precursor_charge = rng.choice([2, 3])

    base_peak_intensity = max(intensities)

    mz_bytes = struct.pack(f"<{n_peaks}d", *mzs)
    int_bytes = struct.pack(f"<{n_peaks}d", *intensities)

    au = AccessUnit(
        spectrum_class=_SPECTRUM_CLASS_TO_WIRE["TTIOMassSpectrum"],
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        ms_level=ms_level,
        polarity=_POLARITY_TO_WIRE[Polarity.POSITIVE],
        retention_time=rt,
        precursor_mz=precursor_mz,
        precursor_charge=precursor_charge,
        ion_mobility=0.0,
        base_peak_intensity=base_peak_intensity,
        channels=[
            ChannelData(
                name="mz",
                precision=int(Precision.FLOAT64),
                compression=int(Compression.NONE),
                n_elements=n_peaks,
                data=mz_bytes,
            ),
            ChannelData(
                name="intensity",
                precision=int(Precision.FLOAT64),
                compression=int(Compression.NONE),
                n_elements=n_peaks,
                data=int_bytes,
            ),
        ],
    )
    return au, last_ms1_peak
