"""Streaming spectral importers: mzML through SpectralStreamWriter."""
from __future__ import annotations

import resource
from pathlib import Path

import numpy as np
import pytest

from ttio.importers import mzml as mzml_imp
from ttio.importers import registry
from ttio.spectral_dataset import SpectralDataset

REPO = Path(__file__).resolve().parents[2]
TINY = REPO / "java/src/test/resources/tiny.pwiz.1.1.mzML"
ONE_MIN = REPO / "objc/Tests/Fixtures/1min.mzML"


def _spectra_of(path):
    """(id order) list of (mz, intensity) arrays via the whole-file reader."""
    res = mzml_imp.read(path)
    return [(s.mz_or_chemical_shift, s.intensity, s.retention_time, s.ms_level, s.precursor_mz)
            for s in res.ms_spectra]


@pytest.mark.parametrize("src", [TINY, ONE_MIN])
def test_mzml_stream_matches_whole_file_import(tmp_path, src):
    if not src.exists():
        pytest.skip(str(src))
    expected = _spectra_of(src)
    stream = mzml_imp.MzMLStream(src, batch_spectra=7)
    batches = list(stream.iter_batches())
    assert sum(int(b.offsets.shape[0]) for b in batches) == len(expected)
    assert len(batches) == (len(expected) + 6) // 7
    out = tmp_path / "s.tio"
    registry.encode("mzml", [str(src)], str(out), batch_spectra=7)
    with SpectralDataset.open(str(out)) as ds:
        run = ds.all_runs["run_0001"]
        assert len(run) == len(expected)
        for i in (0, len(expected) // 2, len(expected) - 1):
            mz, it, rt, lvl, pmz = expected[i]
            sp = run[i]
            assert np.array_equal(np.asarray(sp.signal_array("mz").data), mz)
            assert np.array_equal(np.asarray(sp.signal_array("intensity").data), it)
            assert sp.scan_time_seconds == rt and sp.ms_level == lvl
            assert sp.precursor_mz == pmz
        # chromatograms parsed after the spectra travel with the run
        whole = mzml_imp.read(src)
        assert len(run.chromatograms) == len(whole.chromatograms)


def test_mzml_stream_memory_ceiling(tmp_path):
    from psims.mzml import MzMLWriter
    big = tmp_path / "big.mzML"
    n, pts = 200_000, 100
    rng = np.random.default_rng(5)
    with MzMLWriter(str(big)) as w:
        w.controlled_vocabularies()
        with w.run(id="r"):
            with w.spectrum_list(count=n):
                for i in range(n):
                    mz = np.sort(rng.uniform(100, 2000, pts))
                    it = rng.uniform(0, 1e5, pts)
                    w.write_spectrum(mz, it, id=f"scan={i + 1}", centroided=True,
                                     scan_start_time=i * 0.01, params=[{"ms level": 1}])
    before = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    out = tmp_path / "big.tio"
    registry.encode("mzml", [str(big)], str(out), batch_spectra=4096)
    after = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    assert (after - before) / 1024 < 2000, f"peak RSS grew by {(after - before) / 1024:.0f} MB"
    with SpectralDataset.open(str(out)) as ds:
        assert len(ds.all_runs["run_0001"]) == n
