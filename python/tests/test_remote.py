"""M20 cloud-native access tests.

Covers four dimensions:

1. URL detection — :func:`mpeg_o.remote.is_remote_url` routes local
   paths and URL schemes correctly.
2. ``file://`` round trip — :meth:`SpectralDataset.open` can consume a
   ``file://`` URL via fsspec and produce the same in-memory view as a
   local path open.
3. ``http://`` lazy access — a background ``ThreadingHTTPServer``
   serves a large ``.mpgo`` over HTTP with range-request support; the
   Python reader loads metadata only and random-access-reads individual
   spectra without downloading the whole file.
4. Benchmark — 10 random spectra from a 1000-spectrum file are pulled
   in well under the 2-second acceptance budget on a localhost server.
"""
from __future__ import annotations

import contextlib
import functools
import http.server
import socketserver
import threading
import time
from pathlib import Path

import numpy as np
import pytest

from mpeg_o import SpectralDataset, WrittenRun
from mpeg_o.enums import AcquisitionMode
from mpeg_o.remote import is_remote_url, open_remote_file


# ---------------------------------------------------------------- fixtures ---


def _make_run(n_spec: int, n_pts: int) -> WrittenRun:
    offsets = np.arange(n_spec, dtype=np.uint64) * n_pts
    lengths = np.full(n_spec, n_pts, dtype=np.uint32)
    # Use a deterministic PRNG so the payload is effectively incompressible —
    # otherwise HDF5's default zlib compression flattens 1000 tiled copies of
    # a linspace down to kilobytes and the lazy-read benchmark degenerates
    # into "download everything because the file is tiny".
    rng = np.random.default_rng(0x4D20)  # "M20"
    mz = (100.0 + rng.uniform(0.0, 1500.0, size=n_spec * n_pts)).astype(np.float64)
    intensity = (1.0 + rng.exponential(100.0, size=n_spec * n_pts)).astype(np.float64)
    return WrittenRun(
        spectrum_class="MPGOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": mz, "intensity": intensity},
        offsets=offsets,
        lengths=lengths,
        retention_times=np.linspace(0.0, float(n_spec), n_spec, dtype=np.float64),
        ms_levels=np.ones(n_spec, dtype=np.int32),
        polarities=np.ones(n_spec, dtype=np.int32),
        precursor_mzs=np.zeros(n_spec, dtype=np.float64),
        precursor_charges=np.zeros(n_spec, dtype=np.int32),
        base_peak_intensities=np.full(n_spec, 1000.0, dtype=np.float64),
    )


@pytest.fixture()
def small_mpgo(tmp_path: Path) -> Path:
    out = tmp_path / "small.mpgo"
    SpectralDataset.write_minimal(
        out, title="remote small", isa_investigation_id="MPGO:remote",
        runs={"run_0001": _make_run(n_spec=5, n_pts=8)},
    )
    return out


@pytest.fixture(scope="module")
def large_mpgo(tmp_path_factory: pytest.TempPathFactory) -> Path:
    """1000-spectrum fixture, built once per module so the benchmark
    test pays the construction cost only once."""
    tmp_path = tmp_path_factory.mktemp("m20_large")
    out = tmp_path / "large.mpgo"
    # 1000 × 1024 × 8 B × 2 channels ≈ 16 MB. Bigger than the 5 MB default
    # fsspec block cache so lazy reads are observable.
    SpectralDataset.write_minimal(
        out, title="remote large", isa_investigation_id="MPGO:large",
        runs={"run_0001": _make_run(n_spec=1000, n_pts=1024)},
    )
    return out


# HTTP server that supports ``Range`` requests so h5py can seek+read
# individual chunks rather than downloading the whole file. Python's
# ``SimpleHTTPRequestHandler`` handles ``Range`` natively; we install a
# wrapper around ``self.wfile`` to count the bytes that actually leave
# the server without interfering with the range-truncation path.
class _CountingWriter:
    def __init__(self, inner, counter_cls):
        self._inner = inner
        self._counter_cls = counter_cls

    def write(self, data):
        self._counter_cls.bytes_served += len(data)
        return self._inner.write(data)

    def __getattr__(self, name):
        return getattr(self._inner, name)


class _RangeRequestHandler(http.server.SimpleHTTPRequestHandler):
    """Minimal HTTP/1.1 ``Range`` support on top of
    :class:`SimpleHTTPRequestHandler`. Python's stdlib does not handle
    Range headers natively; fsspec's ``HTTPFileSystem`` requires them
    in order to take seek-friendly partial reads, so we implement the
    subset needed by h5py (single ``bytes=start-end`` form)."""

    bytes_served = 0

    def log_message(self, format, *args):  # noqa: N802 — stdlib override
        pass  # suppress noisy stderr during tests

    def setup(self):
        super().setup()
        self.wfile = _CountingWriter(self.wfile, type(self))

    def send_head(self):
        range_header = self.headers.get("Range")
        if not range_header:
            # Announce range support even on 200 replies so fsspec's
            # probing path recognises the server.
            resp = super().send_head()
            return resp
        # Parse ``bytes=start-end`` / ``bytes=start-`` / ``bytes=-suffix``
        if not range_header.startswith("bytes="):
            self.send_error(416, "unsupported range unit")
            return None
        try:
            path = self.translate_path(self.path)
            import os
            size = os.path.getsize(path)
            spec = range_header[len("bytes="):]
            start_s, _, end_s = spec.partition("-")
            if start_s == "":
                # suffix form: last N bytes
                suffix = int(end_s)
                start = max(0, size - suffix)
                end = size - 1
            else:
                start = int(start_s)
                end = int(end_s) if end_s else size - 1
            if start > end or end >= size:
                self.send_response(416)
                self.send_header("Content-Range", f"bytes */{size}")
                self.end_headers()
                return None
            length = end - start + 1
            import io as _io
            f = open(path, "rb")
            f.seek(start)
            # Wrap in a limited reader so copyfile() honours the slice.
            class _Limited:
                def __init__(self, inner, n):
                    self._inner = inner
                    self._remaining = n
                def read(self, size=-1):
                    if self._remaining <= 0:
                        return b""
                    if size is None or size < 0 or size > self._remaining:
                        size = self._remaining
                    chunk = self._inner.read(size)
                    self._remaining -= len(chunk)
                    return chunk
                def close(self):
                    self._inner.close()
            limited = _Limited(f, length)
            self.send_response(206)
            self.send_header("Accept-Ranges", "bytes")
            self.send_header("Content-Type", self.guess_type(path))
            self.send_header("Content-Length", str(length))
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
            self.end_headers()
            return limited
        except FileNotFoundError:
            self.send_error(404)
            return None
        except Exception as exc:  # pragma: no cover
            self.send_error(500, str(exc))
            return None

    def do_HEAD(self):  # noqa: N802 — stdlib override
        # Advertise Range support so fsspec's HEAD probe picks it up.
        f = self.send_head()
        # send_head may return a file handle in the base class; close it.
        if hasattr(f, "close"):
            try:
                f.close()
            except Exception:
                pass

    def end_headers(self):  # noqa: N802 — stdlib override
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()


@contextlib.contextmanager
def _serve_directory(directory: Path):
    # SimpleHTTPRequestHandler takes ``directory`` as an __init__ kwarg,
    # so bind it via functools.partial rather than a subclass attribute.
    _RangeRequestHandler.bytes_served = 0
    handler = functools.partial(
        _RangeRequestHandler, directory=str(directory),
    )

    class _QuietServer(socketserver.ThreadingMixIn,
                       http.server.HTTPServer):
        daemon_threads = True
        allow_reuse_address = True

    with _QuietServer(("127.0.0.1", 0), handler) as httpd:
        host, port = httpd.server_address
        thread = threading.Thread(target=httpd.serve_forever, daemon=True)
        thread.start()
        try:
            yield f"http://{host}:{port}", _RangeRequestHandler
        finally:
            httpd.shutdown()
            thread.join(timeout=2.0)


# ----------------------------------------------------------------- tests ---


def test_is_remote_url_detects_schemes() -> None:
    assert is_remote_url("s3://bucket/file.mpgo")
    assert is_remote_url("http://example.com/file.mpgo")
    assert is_remote_url("https://example.com/file.mpgo")
    assert is_remote_url("gs://bucket/file.mpgo")
    assert is_remote_url("az://container/file.mpgo")
    assert is_remote_url("file:///tmp/file.mpgo")


def test_is_remote_url_ignores_local_paths(tmp_path: Path) -> None:
    assert not is_remote_url(tmp_path / "local.mpgo")
    assert not is_remote_url("./relative/local.mpgo")
    assert not is_remote_url("/absolute/local.mpgo")
    # Windows drive letter parses as scheme "c" — must NOT be routed.
    assert not is_remote_url(r"C:\Users\toddw\local.mpgo")


def test_file_url_round_trip(small_mpgo: Path) -> None:
    url = f"file://{small_mpgo.resolve()}"
    with SpectralDataset.open(url) as ds:
        assert ds.title == "remote small"
        assert list(ds.ms_runs.keys()) == ["run_0001"]
        run = ds.ms_runs["run_0001"]
        assert len(run) == 5
        first = run[0]
        assert first.mz_array.data.shape == (8,)


def test_http_remote_open_and_lazy_spectrum_read(small_mpgo: Path) -> None:
    with _serve_directory(small_mpgo.parent) as (base_url, handler_cls):
        url = f"{base_url}/{small_mpgo.name}"
        with SpectralDataset.open(url) as ds:
            assert ds.title == "remote small"
            run = ds.ms_runs["run_0001"]
            # Touch one spectrum to force a signal-channel read.
            spec = run[2]
            assert spec.mz_array.data.shape == (8,)
        served = handler_cls.bytes_served

    # The file is tiny (~15 KB); the open+read path must not exceed
    # twice the total file size even with HDF5 fetching a few
    # metadata chunks. For a real large file this would be a tiny
    # fraction of the total.
    assert served > 0
    assert served < 2 * small_mpgo.stat().st_size


def test_http_remote_random_access_benchmark(large_mpgo: Path) -> None:
    """Acceptance: 10 random spectra from a 1000-spectrum file in
    under 2 seconds via HTTP + fsspec + h5py, plus a sanity check
    that we did not download the entire file."""
    file_size = large_mpgo.stat().st_size
    with _serve_directory(large_mpgo.parent) as (base_url, handler_cls):
        url = f"{base_url}/{large_mpgo.name}"

        # Pin a small fsspec block size so each HDF5 chunk pull round-trips
        # as its own HTTP range request. Without this, fsspec's default
        # 5 MB block cache would swallow the whole file on the first read.
        start = time.perf_counter()
        with SpectralDataset.open(url, block_size=65536) as ds:
            run = ds.ms_runs["run_0001"]
            indices = [0, 37, 101, 200, 333, 500, 617, 777, 888, 999]
            values = []
            for i in indices:
                spec = run[i]
                values.append(float(spec.mz_array.data[0]))
        elapsed = time.perf_counter() - start
        served = handler_cls.bytes_served

    assert len(values) == 10
    assert elapsed < 2.0, f"10-spectrum random access took {elapsed:.2f}s"
    # The handoff acceptance criterion is "individual spectrum does
    # not download full file". Ten random spectra with the current
    # HDF5 signal chunk size (DEFAULT_SIGNAL_CHUNK = 65536 elements
    # = 512 KB per chunk) should touch a bounded subset of chunks
    # plus metadata / spectrum_index. We assert an 80% ceiling to
    # accommodate HDF5's chunk cache, fsspec's block quantisation,
    # and the per-chunk decompression. The prior 60% target assumed
    # a 16384-element chunk; the larger default trades bandwidth for
    # write throughput.
    assert served < 0.80 * file_size, (
        f"served {served} bytes of {file_size}; "
        f"lazy read path may be pulling too much"
    )
    # Log what we saw so the benchmark is visible in -v output.
    print(
        f"[m20 bench] {len(indices)} spectra from {file_size} B file "
        f"in {elapsed*1000:.1f} ms, {served} B transferred "
        f"({served / file_size:.1%} of total)"
    )
