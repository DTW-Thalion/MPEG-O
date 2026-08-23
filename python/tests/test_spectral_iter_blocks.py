"""``AcquisitionRun.for_each_block``: the spectral parallel block consumer.

Parity with Objective-C ``-iterBlocksFrom:to:threads:error:usingBlock:``
and Java ``AcquisitionRun.iterBlocks``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import threading
from pathlib import Path

import numpy as np
import pytest

from ttio import SpectralDataset, WrittenRun
from ttio.enums import AcquisitionMode

# The FDZ1 block is 2**20 values and is not configurable, so the corpus
# is sized past it on purpose: 600 spectra of 2000 points is 1200000
# values per channel, which is 2 blocks. A smaller corpus is a single
# block and never crosses a unit boundary.
N_SPEC = 600
N_PTS = 2000


def _make_run(codec: str | None = None) -> WrittenRun:
    """m/z value j of spectrum i is 1000*i + j, so a spectrum's content
    names the spectrum and no assertion needs a derived index."""
    offsets = np.arange(N_SPEC, dtype=np.uint64) * N_PTS
    lengths = np.full(N_SPEC, N_PTS, dtype=np.uint32)
    mz = np.concatenate([1000.0 * i + np.arange(N_PTS, dtype=np.float64)
                         for i in range(N_SPEC)])
    intensity = np.concatenate([((np.arange(N_PTS, dtype=np.float64) + 7 * i) % 977)
                                for i in range(N_SPEC)])
    kw = {"signal_compression": codec} if codec else {}
    return WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.linspace(0.0, float(N_SPEC), N_SPEC, dtype=np.float64),
        ms_levels=np.ones(N_SPEC, dtype=np.int32),
        polarities=np.ones(N_SPEC, dtype=np.int32),
        precursor_mzs=np.zeros(N_SPEC, dtype=np.float64),
        precursor_charges=np.zeros(N_SPEC, dtype=np.int32),
        base_peak_intensities=np.full(N_SPEC, 100.0, dtype=np.float64),
        **kw)


def _write(tmp_path_factory, name: str, codec: str | None) -> Path:
    out = tmp_path_factory.mktemp(name) / f"{name}.tio"
    SpectralDataset.write_minimal(
        out, title=name, isa_investigation_id=f"TTIO:{name}",
        runs={"run_0001": _make_run(codec)})
    return out


@pytest.fixture(scope="module")
def corpus(tmp_path_factory) -> Path:
    """Codec 17 channels, so units come from the FDZ1 block tables."""
    return _write(tmp_path_factory, "fdz", None)


@pytest.fixture(scope="module")
def batched_corpus(tmp_path_factory) -> Path:
    """Numpress channels have no FDZ1 stream, so units are spectrum
    counts."""
    return _write(tmp_path_factory, "npz", "numpress_delta")


def _collect(run, threads=None, start=0, stop=None):
    """m/z[0] per run index, gathered through for_each_block."""
    got: dict[int, float] = {}
    units: list[int] = []
    lock = threading.Lock()

    def fn(view, view_start, first_spectrum, n_spectra):
        local = {}
        for k in range(n_spectra):
            sp = view[view_start + k]
            local[first_spectrum + k] = float(np.asarray(sp.mz_array.data)[0])
        with lock:
            got.update(local)
            units.append(n_spectra)

    run.for_each_block(fn, start, stop, threads=threads)
    return got, units


def test_the_corpus_spans_several_units(corpus, batched_corpus):
    """Without this the suite is a false green: a single-unit corpus
    passes every assertion below without ever crossing a boundary."""
    with SpectralDataset.open(corpus) as ds:
        run = ds.ms_runs["run_0001"]
        assert run._fdz_channels, "the codec-17 corpus lost its FDZ1 channels"
        assert len(run._spectral_units(0, N_SPEC)) >= 2
    with SpectralDataset.open(batched_corpus) as ds:
        run = ds.ms_runs["run_0001"]
        assert not run._fdz_channels, "the numpress corpus kept an FDZ1 channel"
        assert len(run._spectral_units(0, N_SPEC)) >= 2


@pytest.mark.parametrize("threads", [None, 1, 2, 4, 8])
def test_every_spectrum_carries_its_own_content(corpus, threads):
    with SpectralDataset.open(corpus) as ds:
        got, units = _collect(ds.ms_runs["run_0001"], threads=threads)
    assert len(got) == N_SPEC, f"visited {len(got)} of {N_SPEC} in {len(units)} units"
    for i in range(N_SPEC):
        assert got[i] == pytest.approx(1000.0 * i), f"spectrum {i} carried {got[i]}"


def test_units_tile_the_range_without_gap_or_overlap(corpus):
    with SpectralDataset.open(corpus) as ds:
        units = ds.ms_runs["run_0001"]._spectral_units(0, N_SPEC)
    expect = 0
    for _blk, first, count, vstart, vend in units:
        assert first == expect, f"gap or overlap at {expect}"
        assert count >= 1, "empty unit emitted"
        assert vend > vstart
        expect = first + count
    assert expect == N_SPEC


def test_a_range_starting_part_way_in_reports_run_global_indices(corpus):
    """The shape that returned the wrong records on the genomic side."""
    lo, hi = 37, 461
    with SpectralDataset.open(corpus) as ds:
        got, _ = _collect(ds.ms_runs["run_0001"], threads=2, start=lo, stop=hi)
    assert sorted(got) == list(range(lo, hi))
    for i in range(lo, hi):
        assert got[i] == pytest.approx(1000.0 * i)


def test_matches_iter_spectra(corpus):
    with SpectralDataset.open(corpus) as ds:
        run = ds.ms_runs["run_0001"]
        ordered = [float(np.asarray(sp.mz_array.data)[0]) for sp in run.iter_spectra()]
        got, _ = _collect(run, threads=4)
    assert ordered == [got[i] for i in range(N_SPEC)]


def test_spectrum_count_batches_deliver_every_spectrum(batched_corpus):
    """The tier used when no channel carries an FDZ1 stream."""
    with SpectralDataset.open(batched_corpus) as ds:
        got, _ = _collect(ds.ms_runs["run_0001"], threads=4)
    assert len(got) == N_SPEC
    for i in range(N_SPEC):
        # Numpress is fixed point, so compare within its quantisation.
        assert got[i] == pytest.approx(1000.0 * i, rel=1e-6)


def test_empty_range_visits_nothing(corpus):
    calls = []
    with SpectralDataset.open(corpus) as ds:
        ds.ms_runs["run_0001"].for_each_block(lambda *a: calls.append(a), 5, 5)
    assert calls == []
