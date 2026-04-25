"""WebSocket transport server (v0.10 M68).

The server hosts a single :class:`SpectralDataset` and accepts one or
more simultaneous WebSocket clients. Each client sends a JSON query
message describing optional filters; the server then streams the
dataset's transport packets back as one binary WebSocket frame per
packet.

Wire flow:

1. Client connects.
2. Client sends text frame: ``{"type": "query", "filters": {...}}``
   (empty filters = full stream).
3. Server emits StreamHeader, all DatasetHeaders, then AUs (filtered
   by the query), EndOfDataset per dataset, and EndOfStream.
4. Connection closes.

``StreamHeader`` / ``DatasetHeader`` / ``EndOfDataset`` /
``EndOfStream`` are always emitted so the client has a complete
container skeleton regardless of filter selectivity (§7 of
``docs/transport-spec.md``).
"""
from __future__ import annotations

import asyncio
import json
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator

try:
    import websockets
    from websockets.asyncio.server import ServerConnection
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "ttio.transport.server requires the `websockets` package. "
        "Install with `pip install ttio[network]`."
    ) from exc

from ..spectral_dataset import SpectralDataset
from .codec import (
    _SPECTRUM_CLASS_TO_WIRE,
    _instrument_config_json,
    _spectrum_to_access_unit,
)
from .filters import AUFilter
from .packets import (
    HEADER_SIZE,
    PacketFlag,
    PacketHeader,
    PacketType,
    now_ns,
    pack_string,
)

import struct


class TransportServer:
    """WebSocket server streaming a :class:`SpectralDataset` on demand."""

    def __init__(
        self,
        dataset_source: SpectralDataset | str | Path,
        *,
        host: str = "localhost",
        port: int = 9700,
    ):
        self._dataset_source = dataset_source
        self._host = host
        self._port = port
        self._ws_server: Any | None = None
        self._active_connections: set[Any] = set()
        self._stop_event: asyncio.Event | None = None

    @property
    def port(self) -> int:
        return self._port

    @property
    def host(self) -> str:
        return self._host

    async def start(self) -> None:
        """Start serving. Returns once the socket is listening."""
        self._stop_event = asyncio.Event()
        self._ws_server = await websockets.serve(
            self._handle_client, self._host, self._port
        )
        # Resolve the actual bound port (useful when ``port=0``).
        for sock in self._ws_server.sockets:
            self._port = sock.getsockname()[1]
            break

    async def wait_closed(self) -> None:
        assert self._ws_server is not None
        await self._ws_server.wait_closed()

    async def stop(self) -> None:
        if self._ws_server is None:
            return
        # Close all active client connections gracefully.
        for ws in list(self._active_connections):
            try:
                await ws.close(code=1001, reason="server shutdown")
            except Exception:
                pass
        self._ws_server.close()
        await self._ws_server.wait_closed()
        self._ws_server = None

    async def _handle_client(self, websocket: ServerConnection) -> None:
        self._active_connections.add(websocket)
        try:
            # Wait for the query message (with a reasonable timeout).
            try:
                raw = await asyncio.wait_for(websocket.recv(), timeout=30.0)
            except asyncio.TimeoutError:
                await websocket.close(code=1008, reason="no query received")
                return
            query = _parse_query(raw)
            await self._stream_dataset(websocket, query)
        except websockets.exceptions.ConnectionClosed:
            return
        finally:
            self._active_connections.discard(websocket)

    async def _stream_dataset(self, websocket: Any, query: AUFilter) -> None:
        dataset = _resolve_dataset(self._dataset_source)
        owns_dataset = not isinstance(self._dataset_source, SpectralDataset)
        try:
            await _emit_stream(websocket, dataset, query)
        finally:
            if owns_dataset:
                dataset.close()


def _resolve_dataset(
    source: SpectralDataset | str | Path,
) -> SpectralDataset:
    if isinstance(source, SpectralDataset):
        return source
    return SpectralDataset.open(source)


def _parse_query(raw: Any) -> AUFilter:
    if isinstance(raw, (bytes, bytearray)):
        text = bytes(raw).decode("utf-8")
    else:
        text = str(raw)
    try:
        payload = json.loads(text)
    except json.JSONDecodeError:
        return AUFilter()
    if not isinstance(payload, dict):
        return AUFilter()
    return AUFilter.from_dict(payload.get("filters") or {})


async def _emit_stream(
    websocket: Any,
    dataset: SpectralDataset,
    query: AUFilter,
) -> None:
    runs = list(dataset.all_runs.items())
    features = list(dataset.feature_flags.features)

    # StreamHeader
    await _send_packet(
        websocket,
        PacketType.STREAM_HEADER,
        _stream_header_payload(
            format_version="1.2",
            title=dataset.title or "",
            isa_investigation=dataset.isa_investigation_id or "",
            features=features,
            n_datasets=len(runs),
        ),
    )

    # DatasetHeaders
    for i, (name, run) in enumerate(runs, start=1):
        if query.dataset_id is not None and i != query.dataset_id:
            continue
        payload = _dataset_header_payload(
            dataset_id=i,
            name=name,
            acquisition_mode=int(run.acquisition_mode),
            spectrum_class=run.spectrum_class,
            channel_names=list(run.channel_names),
            instrument_json=_instrument_config_json(run),
            expected_au_count=len(run),
        )
        await _send_packet(
            websocket, PacketType.DATASET_HEADER, payload, dataset_id=i
        )

    # AccessUnits (with filtering + max_au cap)
    emitted = 0
    for i, (_name, run) in enumerate(runs, start=1):
        if query.dataset_id is not None and i != query.dataset_id:
            continue
        for j, spectrum in enumerate(run):
            au = _spectrum_to_access_unit(spectrum, run)
            if not query.matches(au, i):
                continue
            if query.max_au is not None and emitted >= query.max_au:
                break
            await _send_packet(
                websocket,
                PacketType.ACCESS_UNIT,
                au.to_bytes(),
                dataset_id=i,
                au_sequence=j,
            )
            emitted += 1
        if query.max_au is not None and emitted >= query.max_au:
            break

    # EndOfDataset per run
    for i, (_name, run) in enumerate(runs, start=1):
        if query.dataset_id is not None and i != query.dataset_id:
            continue
        eod_payload = struct.pack("<HI", i & 0xFFFF, len(run) & 0xFFFFFFFF)
        await _send_packet(
            websocket, PacketType.END_OF_DATASET, eod_payload, dataset_id=i
        )

    # EndOfStream
    await _send_packet(websocket, PacketType.END_OF_STREAM, b"")


async def _send_packet(
    websocket: Any,
    packet_type: PacketType,
    payload: bytes,
    *,
    dataset_id: int = 0,
    au_sequence: int = 0,
) -> None:
    header = PacketHeader(
        packet_type=int(packet_type),
        flags=0,
        dataset_id=dataset_id,
        au_sequence=au_sequence,
        payload_length=len(payload),
        timestamp_ns=now_ns(),
    )
    await websocket.send(header.to_bytes() + payload)


def _stream_header_payload(
    *,
    format_version: str,
    title: str,
    isa_investigation: str,
    features: list[str],
    n_datasets: int,
) -> bytes:
    return (
        pack_string(format_version, width=2)
        + pack_string(title, width=2)
        + pack_string(isa_investigation, width=2)
        + struct.pack("<H", len(features) & 0xFFFF)
        + b"".join(pack_string(f, width=2) for f in features)
        + struct.pack("<H", n_datasets & 0xFFFF)
    )


def _dataset_header_payload(
    *,
    dataset_id: int,
    name: str,
    acquisition_mode: int,
    spectrum_class: str,
    channel_names: list[str],
    instrument_json: str,
    expected_au_count: int,
) -> bytes:
    return (
        struct.pack("<H", dataset_id & 0xFFFF)
        + pack_string(name)
        + struct.pack("<B", int(acquisition_mode) & 0xFF)
        + pack_string(spectrum_class)
        + struct.pack("<B", len(channel_names) & 0xFF)
        + b"".join(pack_string(c) for c in channel_names)
        + pack_string(instrument_json, width=4)
        + struct.pack("<I", expected_au_count & 0xFFFFFFFF)
    )


@asynccontextmanager
async def serving(
    dataset_source: SpectralDataset | str | Path,
    *,
    host: str = "localhost",
    port: int = 0,
) -> AsyncIterator[TransportServer]:
    """Async context manager: start a server, yield it, stop on exit."""
    server = TransportServer(dataset_source, host=host, port=port)
    await server.start()
    try:
        yield server
    finally:
        await server.stop()
