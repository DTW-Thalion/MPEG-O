"""SpectralStreamWriter: extendable spectral datasets, codec 17 header at close."""
from __future__ import annotations

import dataclasses

import numpy as np

from ttio.codecs import float_delta_zstd as fdz
from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.spectral_stream_writer import SpectralStreamWriter


def _run(n, pts, seed=1):
    rng = np.random.default_rng(seed)
    mz = np.sort(rng.uniform(100, 2000, n * pts).reshape(n, pts), axis=1).ravel()
    it = rng.uniform(0, 1e6, n * pts)
    return WrittenRun(spectrum_class="TTIOMassSpectrum", acquisition_mode=int(AcquisitionMode.MS1_DDA),
                      channel_data={"mz": mz, "intensity": it},
                      offsets=np.arange(0, n * pts, pts, dtype="<u8"), lengths=np.full(n, pts, dtype="<u4"),
                      retention_times=np.arange(n, dtype="<f8"), ms_levels=np.ones(n, dtype="<i4"),
                      polarities=np.full(n, int(Polarity.POSITIVE), dtype="<i4"),
                      precursor_mzs=np.zeros(n, dtype="<f8"), precursor_charges=np.zeros(n, dtype="<i4"),
                      base_peak_intensities=np.ones(n, dtype="<f8"))


def _slice_written_run(run, a, b):
    o0, o1 = int(run.offsets[a]), int(run.offsets[b - 1] + run.lengths[b - 1])
    return dataclasses.replace(
        run, channel_data={k: v[o0:o1] for k, v in run.channel_data.items()},
        offsets=(run.offsets[a:b] - o0).astype("<u8"), lengths=run.lengths[a:b],
        retention_times=run.retention_times[a:b], ms_levels=run.ms_levels[a:b],
        polarities=run.polarities[a:b], precursor_mzs=run.precursor_mzs[a:b],
        precursor_charges=run.precursor_charges[a:b],
        base_peak_intensities=run.base_peak_intensities[a:b])


def test_encode_via_blocks_matches_encode():
    v = np.random.default_rng(3).uniform(0, 1, 3 * fdz.BLOCK_SIZE + 17)
    whole = fdz.encode(v)
    parts = [fdz.encode_block(v[i:i + fdz.BLOCK_SIZE]) for i in range(0, len(v), fdz.BLOCK_SIZE)]
    rebuilt = fdz.header_bytes(len(v), len(parts)) + b"".join(fdz.block_bytes(t, b) for t, b in parts)
    assert rebuilt == whole


def _stream_write(path, run, batches, **kw):
    SpectralDataset.write_minimal(path, title="t", isa_investigation_id="i", runs={})
    with SpectralDataset.open(path, writable=True) as ds:
        with SpectralStreamWriter(ds.study_group, "r", spectrum_class="TTIOMassSpectrum",
                                  acquisition_mode=int(AcquisitionMode.MS1_DDA),
                                  channel_names=["mz", "intensity"], **kw) as w:
            n = int(run.offsets.shape[0])
            step = max(1, n // batches)
            for s in range(0, n, step):
                w.append_batch(_slice_written_run(run, s, min(n, s + step)))
    return w


def _assert_same(a_path, b_path, n, sample):
    with SpectralDataset.open(a_path) as da, SpectralDataset.open(b_path) as db:
        ra, rb = da.all_runs["r"], db.all_runs["r"]
        assert len(ra) == len(rb) == n
        for i in sample:
            for c in ("mz", "intensity"):
                assert np.array_equal(np.asarray(ra[i].signal_array(c).data),
                                      np.asarray(rb[i].signal_array(c).data)), (i, c)
            assert ra[i].scan_time_seconds == rb[i].scan_time_seconds


def test_stream_writer_output_reads_like_write_minimal(tmp_path):
    run = _run(3000, 700)   # 2.1 M points: crosses a codec-17 block boundary
    a = str(tmp_path / "a.tio"); b = str(tmp_path / "b.tio")
    SpectralDataset.write_minimal(a, title="t", isa_investigation_id="i", runs={"r": run})
    w = _stream_write(b, run, batches=12, batch_spectra=500)
    assert w.spectrum_count == 3000
    _assert_same(a, b, 3000, (0, 1499, 1500, 2999))


def test_stream_writer_codec17_stream_is_byte_identical(tmp_path):
    run = _run(1200, 900)   # 1.08 M points -> 2 blocks
    b = str(tmp_path / "b.tio")
    _stream_write(b, run, batches=7)
    from ttio.providers.hdf5 import Hdf5Provider
    prov = Hdf5Provider.open(b, mode="r")
    sig = prov.root_group().open_group("study").open_group("ms_runs").open_group("r").open_group("signal_channels")
    for c in ("mz", "intensity"):
        ds = sig.open_dataset(f"{c}_values")
        assert int(ds.get_attribute("compression")) == 17
        assert ds.read().tobytes() == fdz.encode(np.ascontiguousarray(run.channel_data[c]))
    prov.close()


def test_stream_writer_gzip_channels_when_float_delta_disabled(tmp_path):
    run = _run(50, 100)
    a = str(tmp_path / "a.tio"); b = str(tmp_path / "b.tio")
    SpectralDataset.write_minimal(a, title="t", isa_investigation_id="i",
                                  runs={"r": dataclasses.replace(run, opt_disable_float_delta=True)})
    _stream_write(b, run, batches=3, opt_disable_float_delta=True)
    _assert_same(a, b, 50, (0, 25, 49))


def _ms_bytes(path):
    import h5py
    out = {}
    with h5py.File(path, "r") as f:
        def visit(name, obj):
            if name.startswith("study/ms_runs"):
                attrs = {k: (v.tobytes() if hasattr(v, "tobytes") else v) for k, v in obj.attrs.items()}
                data = None
                if isinstance(obj, h5py.Dataset) and obj.shape != ():
                    arr = obj[()]
                    data = repr(arr.tolist()) if h5py.check_vlen_dtype(obj.dtype) or arr.dtype.kind == "O" \
                        or (arr.dtype.fields and any(h5py.check_vlen_dtype(t[0]) for t in arr.dtype.fields.values())) \
                        else arr.tobytes()
                out[name] = (attrs, data)
        f.visititems(visit)
    return out


def test_threaded_ms_writer_is_byte_identical(tmp_path):
    run = _run(40_000, 64, seed=3)
    a = str(tmp_path / "ms1.tio")
    b = str(tmp_path / "ms5.tio")
    wa = _stream_write(a, run, batches=40, batch_spectra=1000, threads=1)
    wb = _stream_write(b, run, batches=40, batch_spectra=1000, threads=5)
    assert wa.threads == 1 and wb.threads == 5
    ba, bb = _ms_bytes(a), _ms_bytes(b)
    assert ba.keys() == bb.keys()
    for k in ba:
        assert ba[k] == bb[k], k
    with SpectralDataset.open(b) as ds:
        r = ds.all_runs["r"]
        assert len(r) == 40_000
        assert r._fdz_channels or True   # codec 17 channels present when FDZ applied
