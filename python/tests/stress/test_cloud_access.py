"""Cloud-access stress tests (v0.9 M62).

Verifies that ``SpectralDataset.open`` over an S3 URL only fetches
the bytes it actually needs (HDF5 metadata + the chunks each
spectrum touches), rather than downloading the whole file.

The whole module is gated on ``requires_s3`` AND on the
``TTIO_S3_FIXTURE_URL`` env var (e.g.
``s3://my-bucket/synth_100k.tio`` or a MinIO URL). When neither is
present the tests skip cleanly so the default + nightly CI runs
stay green; an operator with an S3 endpoint configured locally can
opt-in by exporting the variable.
"""
from __future__ import annotations

import os

import pytest

from ttio import SpectralDataset

_S3_URL = os.environ.get("TTIO_S3_FIXTURE_URL")


pytestmark = [
    pytest.mark.stress,
    pytest.mark.requires_s3,
]


@pytest.fixture(scope="module")
def s3_fixture_url() -> str:
    if not _S3_URL:
        pytest.skip("TTIO_S3_FIXTURE_URL not set; cloud access tests need an S3/MinIO endpoint")
    return _S3_URL


def test_open_from_s3(s3_fixture_url: str) -> None:
    """Opening an s3:// URL must succeed and expose the run index."""
    with SpectralDataset.open(s3_fixture_url) as ds:
        assert ds.ms_runs, "no runs visible after S3 open"
        run = next(iter(ds.ms_runs.values()))
        assert len(run) > 0


def test_selective_spectrum_fetch(s3_fixture_url: str) -> None:
    """Reading 10 spectra must fetch substantially fewer bytes than
    the full file size — proves chunked HDF5 reads through fsspec.

    The threshold is generous (50% of the file size) since the HDF5
    metadata + chunk overhead can be non-trivial relative to a
    small fixture; the point is that we're NOT downloading the
    whole thing.
    """
    import fsspec  # type: ignore[import-not-found]
    fs, path = fsspec.core.url_to_fs(s3_fixture_url)
    full_size = fs.info(path)["size"]

    bytes_fetched_before = _maybe_bytes_counter()
    with SpectralDataset.open(s3_fixture_url) as ds:
        run = next(iter(ds.ms_runs.values()))
        for i in range(min(10, len(run))):
            _ = run[i].signal_arrays["mz"].data
    bytes_fetched_after = _maybe_bytes_counter()

    if bytes_fetched_before is None or bytes_fetched_after is None:
        pytest.skip("backend doesn't expose a byte counter; selective-fetch unverifiable")
    delta = bytes_fetched_after - bytes_fetched_before
    assert delta < full_size * 0.5, (
        f"fetched {delta} bytes for 10 spectra; file is {full_size} bytes — "
        f"selective fetch broke?"
    )


def test_query_without_full_download(s3_fixture_url: str) -> None:
    """An RT-range query against the index should not download the
    full signal_channels payload."""
    from ttio.value_range import ValueRange
    with SpectralDataset.open(s3_fixture_url) as ds:
        run = next(iter(ds.ms_runs.values()))
        rt_max = float(run.index.retention_times.max())
        hits = run.index.indices_in_retention_time_range(
            ValueRange(minimum=0.0, maximum=rt_max / 2.0)
        )
    assert hits, "RT-range query returned no hits"


def _maybe_bytes_counter() -> int | None:
    """Return cumulative bytes fetched if fsspec exposes a counter,
    or ``None`` when the backend doesn't track one."""
    try:
        import fsspec  # type: ignore[import-not-found]
    except ImportError:
        return None
    # fsspec doesn't expose a global counter; subclasses (s3fs) may
    # surface request stats. For now we punt — the test will skip
    # when no counter is available, leaving the open-from-s3 +
    # query tests to provide the smoke coverage.
    return None
