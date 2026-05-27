"""Streaming behaviour test for :meth:`UploadClient.upload_path`.

Mirrors Java PR #178: peak heap during file upload must be
O(chunk_size), not O(payload). We assert it via a fake ``_ws`` that
records every chunk size and confirms each is <= chunk_size.

A 100 MB sparse file is used as the payload so the test runs quickly
and uses little disk; the streaming path can still tell us when a
slurp would have happened (it would deliver ``len == 100 MB`` in one
send).
"""
from __future__ import annotations

import asyncio
import os
from pathlib import Path

import pytest

from ttio.workbench.transport.upload import (
    UploadClient,
    UploadResult,
    _report_progress,
)


CHUNK_SIZE = 64 * 1024
FILE_SIZE = 100 * 1024 * 1024  # 100 MB sparse file


class _FakeWebSocket:
    """Minimal WS double: records every send size."""

    def __init__(self) -> None:
        self.sends: list[int] = []
        self.max_send_size: int = 0

    async def send(self, data) -> None:
        n = len(data)
        self.sends.append(n)
        if n > self.max_send_size:
            self.max_send_size = n

    async def recv(self):
        # Block forever; the test will explicitly short-circuit the recv path.
        await asyncio.sleep(3600)

    async def close(self) -> None:
        pass


@pytest.fixture
def sparse_tis(tmp_path: Path) -> Path:
    p = tmp_path / "huge.tis"
    # os.truncate creates a sparse file -- zero bytes are not allocated on
    # most filesystems (ext4 / NTFS / APFS / btrfs).
    with p.open("wb") as fh:
        fh.truncate(FILE_SIZE)
    assert p.stat().st_size == FILE_SIZE
    return p


def _build_upload_client_with_fake_ws(fake_ws: _FakeWebSocket) -> UploadClient:
    client = UploadClient(
        host="ignored", port=0,
        token="ignored-token", owner="tester",
        project="proj", container_uri="uri:tio:test",
        chunk_size=CHUNK_SIZE,
    )
    # Bypass handshake state.
    client._ws = fake_ws  # type: ignore[assignment]
    client._resume_handle = "stg-test"
    return client


@pytest.mark.asyncio
async def test_upload_path_streams_with_bounded_memory(
    sparse_tis: Path, monkeypatch,
) -> None:
    """The full file should arrive in `ceil(FILE_SIZE / CHUNK_SIZE)`
    chunks, each <= CHUNK_SIZE. No single send may carry the whole
    payload (which would mean the code slurped via Path.read_bytes).
    """
    fake_ws = _FakeWebSocket()
    client = _build_upload_client_with_fake_ws(fake_ws)

    # Patch _handshake / _drain_acks / _wait_for_done so we exercise just
    # the streaming send loop.
    async def _noop_handshake(_resume):
        return None

    async def _noop_drain(*, non_blocking: bool):
        return None

    async def _fake_wait_for_done():
        return UploadResult(
            container_uri="uri:tio:test",
            last_acked_au_sequence=0,
            resume_handle="stg-test",
        )

    monkeypatch.setattr(client, "_handshake", _noop_handshake)
    monkeypatch.setattr(client, "_drain_acks", _noop_drain)
    monkeypatch.setattr(client, "_wait_for_done", _fake_wait_for_done)

    seen: list[tuple[int, int]] = []
    result = await client.upload_path(
        sparse_tis,
        progress=lambda d, t: seen.append((d, t)),
    )

    # Bounded memory assertion: every send must be at most CHUNK_SIZE.
    assert fake_ws.max_send_size <= CHUNK_SIZE, (
        f"max send size {fake_ws.max_send_size} exceeds chunk_size {CHUNK_SIZE} "
        f"-- streaming is broken (file was probably slurped via read_bytes)."
    )

    # Total bytes sent equals file size.
    assert sum(fake_ws.sends) == FILE_SIZE

    # Result + progress.
    assert result.container_uri == "uri:tio:test"
    assert seen[0] == (0, FILE_SIZE)
    assert seen[-1] == (FILE_SIZE, FILE_SIZE)


def test_upload_path_accepts_progress_kwarg() -> None:
    import inspect
    sig = inspect.signature(UploadClient.upload_path)
    assert "progress" in sig.parameters
    assert sig.parameters["progress"].kind is inspect.Parameter.KEYWORD_ONLY


def test_workbench_client_exposes_upload_path() -> None:
    """The high-level WorkbenchClient should expose ``upload_path``."""
    import inspect
    from ttio.workbench.client import WorkbenchClient
    assert hasattr(WorkbenchClient, "upload_path")
    sig = inspect.signature(WorkbenchClient.upload_path)
    assert "path" in sig.parameters
    assert "progress" in sig.parameters
