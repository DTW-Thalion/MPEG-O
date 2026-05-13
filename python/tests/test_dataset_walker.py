"""Unit tests for :func:`ttio.transport.walker.walk_dataset`."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.transport import (
    AccessUnitEvent,
    AUFilter,
    DatasetHeaderEvent,
    EndOfDatasetEvent,
    EndOfStreamEvent,
    StreamHeaderEvent,
    walk_dataset,
)


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
        [0.0 if ms_levels[i] == 1 else 500.0 + 10.0 * i
         for i in range(n_spectra)],
        dtype="<f8",
    )
    precursor_charges = np.array(
        [0 if ms_levels[i] == 1 else 2 for i in range(n_spectra)],
        dtype="<i4",
    )
    base_peak = np.array(
        [float(intensity[i * points:(i + 1) * points].max())
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
        title="walker fixture",
        isa_investigation_id="ISA-WALKER",
        runs={"run_0001": run},
    )
    return path


@pytest.fixture
def ttio_fixture(tmp_path):
    return _make_fixture(tmp_path / "walker.tio")


def test_unfiltered_walk_emits_full_event_sequence(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    events = list(walk_dataset(dataset))
    # 1 StreamHeader + 1 DatasetHeader + 5 AUs + 1 EndOfDataset + 1 EOS.
    assert isinstance(events[0], StreamHeaderEvent)
    assert events[0].n_datasets == 1
    assert events[0].title == "walker fixture"
    assert isinstance(events[1], DatasetHeaderEvent)
    assert events[1].dataset_id == 1
    assert events[1].name == "run_0001"
    aus = [e for e in events if isinstance(e, AccessUnitEvent)]
    assert len(aus) == 5
    assert [e.au_sequence for e in aus] == [0, 1, 2, 3, 4]
    eods = [e for e in events if isinstance(e, EndOfDatasetEvent)]
    assert len(eods) == 1 and eods[0].final_au_sequence == 5
    assert isinstance(events[-1], EndOfStreamEvent)


def test_ms_level_filter_keeps_matching_aus(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    flt = AUFilter(ms_level=1)
    aus = [e for e in walk_dataset(dataset, flt)
            if isinstance(e, AccessUnitEvent)]
    # Indexes 0,2,4 have ms_level=1.
    assert len(aus) == 3
    assert [e.au_sequence for e in aus] == [0, 2, 4]


def test_max_au_cap_honoured(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    flt = AUFilter(max_au=2)
    aus = [e for e in walk_dataset(dataset, flt)
            if isinstance(e, AccessUnitEvent)]
    assert len(aus) == 2


def test_dataset_id_filter_skips_other_datasets(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    flt = AUFilter(dataset_id=99)  # no such dataset
    events = list(walk_dataset(dataset, flt))
    aus = [e for e in events if isinstance(e, AccessUnitEvent)]
    dshs = [e for e in events if isinstance(e, DatasetHeaderEvent)]
    eods = [e for e in events if isinstance(e, EndOfDatasetEvent)]
    assert aus == []
    assert dshs == []
    assert eods == []
    # StreamHeader + EndOfStream always emit.
    assert isinstance(events[0], StreamHeaderEvent)
    assert isinstance(events[-1], EndOfStreamEvent)


def test_walker_reusable_across_multiple_walks(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    a = list(walk_dataset(dataset))
    b = list(walk_dataset(dataset))
    # Compare by event types + dataset_id / au_sequence for AU events.
    def _key(events):
        return [(type(e).__name__,
                 getattr(e, "dataset_id", None),
                 getattr(e, "au_sequence", None))
                for e in events]
    assert _key(a) == _key(b)


def test_au_event_carries_real_access_unit(ttio_fixture):
    dataset = SpectralDataset.open(ttio_fixture)
    aus = [e for e in walk_dataset(dataset)
            if isinstance(e, AccessUnitEvent)]
    # AccessUnit should have the same number of channels we wrote.
    assert len(aus[0].au.channels) == 2  # mz + intensity
    # MS spectrum → spectrum_class == 0.
    assert aus[0].au.spectrum_class == 0
