"""
Unit tests for the transport progress-callback plumbing
(`_report_progress` helper + the `progress=` kwargs on
`UploadClient.upload_bytes` / `DownloadClient.download`).

The end-to-end "callback fires with rising bytes" behaviour is
exercised by the live-daemon smoke; here we pin the pure contract:
the helper forwards args and never lets a throwing callback escape.
"""
from __future__ import annotations

import inspect

from ttio.workbench.transport.upload import UploadClient, _report_progress
from ttio.workbench.transport.download import DownloadClient


def test_report_progress_forwards_args():
    seen = []
    _report_progress(lambda d, t: seen.append((d, t)), 5, 10)
    assert seen == [(5, 10)]


def test_report_progress_none_is_noop():
    # Must not raise when no callback is supplied.
    _report_progress(None, 1, 2)


def test_report_progress_swallows_callback_exception():
    def boom(d, t):
        raise RuntimeError("callback blew up")
    # Must not propagate -- a throwing callback can't abort a transfer.
    _report_progress(boom, 3, 4)


def test_report_progress_passes_unknown_total():
    seen = []
    _report_progress(lambda d, t: seen.append((d, t)), 1024, -1)
    assert seen == [(1024, -1)]


def test_upload_bytes_accepts_progress_kwarg():
    sig = inspect.signature(UploadClient.upload_bytes)
    assert "progress" in sig.parameters
    assert sig.parameters["progress"].kind is inspect.Parameter.KEYWORD_ONLY


def test_download_accepts_progress_kwarg():
    sig = inspect.signature(DownloadClient.download)
    assert "progress" in sig.parameters
    assert sig.parameters["progress"].kind is inspect.Parameter.KEYWORD_ONLY
