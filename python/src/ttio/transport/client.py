"""WebSocket transport client ()."""
from __future__ import annotations

import asyncio
import json
import struct
from pathlib import Path
from typing import Any, AsyncIterator

try:
    import websockets
except ImportError as exc:  # pragma: no cover
    raise ImportError(
        "ttio.transport.client requires the `websockets` package. "
        "Install with `pip install ttio[network]`."
    ) from exc

from ..spectral_dataset import SpectralDataset
from .codec import TransportReader
from .packets import (
    HEADER_SIZE,
    PacketFlag,
    PacketHeader,
    PacketType,
    crc32c,
)


class TransportClient:
    """Connect to a :class:`TransportServer` and receive a filtered stream."""

    def __init__(self, url: str):
        """Construct a client bound to a transport-server endpoint.

        Parameters
        ----------
        url : str
            A ``ws://`` or ``wss://`` URI naming the
            :class:`TransportServer` endpoint. The URL is stored
            verbatim; the WebSocket is opened on each
            :meth:`iter_packets` / :meth:`fetch_packets` /
            :meth:`stream_to_file` call.
        """
        self._url = url

    async def fetch_packets(
        self, *, filters: dict[str, Any] | None = None
    ) -> list[tuple[PacketHeader, bytes]]:
        """Open one connection, send the query, return every packet.

        Convenience wrapper around :meth:`iter_packets` that drains the
        iterator into a list. Suitable for small streams; large streams
        should iterate to keep peak memory bounded.

        Parameters
        ----------
        filters : dict, optional
            Server-side filter dictionary forwarded as the query JSON
            body. ``None`` (default) downloads the full stream.

        Returns
        -------
        list of (PacketHeader, bytes)
            All packets in emission order, including the terminal
            ``EndOfStream`` frame.

        Raises
        ------
        websockets.exceptions.ConnectionClosed
            If the server closes the connection before
            ``EndOfStream``.
        ValueError
            On a malformed wire frame (short header, truncated
            payload, or CRC-32C mismatch).
        """
        packets: list[tuple[PacketHeader, bytes]] = []
        async for packet in self.iter_packets(filters=filters):
            packets.append(packet)
        return packets

    async def iter_packets(
        self, *, filters: dict[str, Any] | None = None
    ) -> AsyncIterator[tuple[PacketHeader, bytes]]:
        """Connect, send the query, yield ``(header, payload)`` pairs.

        Opens a fresh WebSocket to the configured URL with
        ``permessage-deflate`` disabled, sends the JSON query frame,
        and yields each binary packet the server emits in order.
        Iteration terminates after the server emits an
        ``EndOfStream`` packet or closes the connection.

        Parameters
        ----------
        filters : dict, optional
            Server-side filter dictionary forwarded as the query JSON
            body. ``None`` (default) downloads the full stream.

        Yields
        ------
        tuple of (PacketHeader, bytes)
            One pair per server-emitted binary frame. The header is
            decoded from the leading :data:`HEADER_SIZE` bytes; the
            payload is the raw bytes immediately after. If the frame
            carries a CRC-32C trailer it is verified before the pair
            is yielded.

        Raises
        ------
        ValueError
            On a short header, truncated payload, missing CRC, or
            CRC-32C mismatch.
        websockets.exceptions.ConnectionClosed
            If the connection drops mid-stream.
        """
        query = json.dumps({"type": "query", "filters": filters or {}})
        # compression=None: not every peer negotiates permessage-deflate
        # correctly. Disabling keeps wire-format interop simple — the
        # packet payloads already support opt-in CRC-32C; compression
        # is orthogonal and belongs at the packet level (§4.3).
        async with websockets.connect(self._url, compression=None) as ws:
            await ws.send(query)
            async for message in ws:
                if isinstance(message, str):
                    # Server errors may arrive as text; skip quietly.
                    continue
                raw = bytes(message)
                header, payload = _split_packet(raw)
                yield header, payload
                if header.packet_type == int(PacketType.END_OF_STREAM):
                    return

    async def stream_to_file(
        self,
        output_path: str | Path,
        *,
        filters: dict[str, Any] | None = None,
        provider: str = "hdf5",
    ) -> SpectralDataset:
        """Stream a filtered dataset directly into a ``.tio`` file.

        Drains :meth:`fetch_packets`, replays the captured bytes
        through a :class:`TransportReader`, and writes the result via
        :meth:`SpectralDataset.write_minimal` under the chosen
        provider.

        Parameters
        ----------
        output_path : str or pathlib.Path
            Destination ``.tio`` path. Created if absent; truncated if
            present.
        filters : dict, optional
            Server-side filter dictionary forwarded to the server.
            ``None`` (default) downloads the full stream.
        provider : str, optional
            Storage provider name to materialise into (default
            ``"hdf5"``). See :class:`ttio.providers.base.StorageProvider`.

        Returns
        -------
        SpectralDataset
            Freshly materialised dataset opened for read.

        Raises
        ------
        websockets.exceptions.ConnectionClosed
            If the server closes the connection before
            ``EndOfStream``.
        ValueError
            On a malformed wire frame propagated up from
            :meth:`iter_packets`.
        """
        packets = await self.fetch_packets(filters=filters)
        # Reuse the offline reader's materialization logic by serializing
        # the packets into a byte buffer and feeding them through it.
        import io
        buffer = io.BytesIO()
        for header, payload in packets:
            buffer.write(header.to_bytes())
            buffer.write(payload)
            if header.flags & int(PacketFlag.HAS_CHECKSUM):
                buffer.write(struct.pack("<I", crc32c(payload)))
        buffer.seek(0)
        reader = TransportReader(buffer)
        return reader.read_to_dataset(output_path=output_path, provider=provider)


def _split_packet(raw: bytes) -> tuple[PacketHeader, bytes]:
    if len(raw) < HEADER_SIZE:
        raise ValueError(
            f"transport frame shorter than header: {len(raw)}/{HEADER_SIZE}"
        )
    header = PacketHeader.from_bytes(raw[:HEADER_SIZE])
    end = HEADER_SIZE + header.payload_length
    if len(raw) < end:
        raise ValueError(
            f"transport frame truncated: {len(raw)}/{end}"
        )
    payload = raw[HEADER_SIZE:end]
    if header.flags & int(PacketFlag.HAS_CHECKSUM):
        if len(raw) < end + 4:
            raise ValueError("frame missing CRC-32C")
        (expected,) = struct.unpack("<I", raw[end:end + 4])
        if expected != crc32c(payload):
            raise ValueError(
                f"CRC-32C mismatch on packet type 0x{header.packet_type:02x}"
            )
    return header, payload
