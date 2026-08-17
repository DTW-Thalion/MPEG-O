"""AcquisitionRun.iter_spectra / channel_range with per-block codec 17 decode."""
from __future__ import annotations

import numpy as np

from test_spectral_stream_writer import _run
from ttio.spectral_dataset import SpectralDataset


def test_iter_spectra_matches_getitem_and_decodes_per_block(tmp_path):
    run = _run(4000, 700)     # 2.8 M points, 3 codec-17 blocks per channel
    p = str(tmp_path / "a.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={"r": run})
    with SpectralDataset.open(p) as ds:
        r = ds.all_runs["r"]
        n = 0
        for i, sp in enumerate(r.iter_spectra(batch=256)):
            if i % 997 == 0 or i in (1497, 1498, 2995):
                for c in ("mz", "intensity"):
                    assert np.array_equal(np.asarray(sp.signal_array(c).data),
                                          run.channel_data[c][i * 700:(i + 1) * 700]), (i, c)
            n += 1
        assert n == 4000
        # 3 blocks per channel; each decoded once during the ordered walk.
        assert r._fdz_blocks_decoded["mz"] <= 4
        # random access still exact and touches one block per lookup
        sp = r[3999]
        assert np.array_equal(np.asarray(sp.signal_array("mz").data), run.channel_data["mz"][-700:])
        assert r._fdz_blocks_decoded["mz"] <= 5


def test_channel_range_crosses_block_boundary(tmp_path):
    from ttio.codecs import float_delta_zstd as fdz
    run = _run(2, fdz.BLOCK_SIZE)   # exactly 2 blocks per channel
    p = str(tmp_path / "b.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={"r": run})
    with SpectralDataset.open(p) as ds:
        r = ds.all_runs["r"]
        start, count = fdz.BLOCK_SIZE - 5, 11
        got = r.channel_range("mz", start, count)
        assert np.array_equal(got, run.channel_data["mz"][start:start + count])
        assert np.array_equal(r.channel_range("intensity", 0, 3), run.channel_data["intensity"][:3])
        assert len(r.channel_range("mz", 7, 0)) == 0


def test_transport_hot_path_reads_windows_not_whole_channels(tmp_path):
    from ttio.transport import file_to_transport, transport_to_file
    run = _run(3000, 700)
    p = str(tmp_path / "c.tio")
    SpectralDataset.write_minimal(p, title="t", isa_investigation_id="i", runs={"r": run})
    tis = str(tmp_path / "c.tis")
    file_to_transport(p, tis, use_compression=True)
    rt = transport_to_file(tis, str(tmp_path / "rt.tio"))
    try:
        rr = rt.all_runs["r"]
        assert len(rr) == 3000
        for i in (0, 1500, 2999):
            assert np.array_equal(np.asarray(rr[i].signal_array("mz").data),
                                  run.channel_data["mz"][i * 700:(i + 1) * 700])
    finally:
        rt.close()
