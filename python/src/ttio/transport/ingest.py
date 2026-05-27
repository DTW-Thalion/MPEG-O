"""Callback-driven incremental transport-stream parser.

Sits next to :class:`ttio.transport.codec.TransportReader`: where the
reader assumes you have the whole stream up front and want every
packet back at once, the ingest is for callers (e.g. the TTI-O
Workbench Server's WebSocket upload session) that feed bytes in
chunks as they arrive and want each packet delivered as soon as it's
complete.

Lifecycle::

    ingest = TransportIngest(
        on_packet=handle_packet,
        on_end_of_stream=handle_eos,
        on_error=handle_error,
    )
    # ... when bytes arrive ...
    ingest.feed(chunk)            # callbacks fire per packet
    # ... on producer EOF ...
    ingest.finish()               # raises if trailing partial

Validates everything :class:`TransportReader` validates — magic,
version, header CRC, payload CRC when the ``HAS_CHECKSUM`` flag is
set, AU-sequence monotonicity, StreamHeader-first — but does so
packet-by-packet instead of in one pass. A failed validation halts
the ingest; the rolling buffer is discarded and any subsequent
:meth:`feed` raises :class:`TransportIngestError`.

Not thread-safe: a single ingest instance must be driven from one
thread. The server pattern is one ingest per WS connection, owned by
the worker task that accepted the connection.

Cross-language equivalents:
  - Objective-C: ``TTIOTransportIngest``
  - Java:        ``global.thalion.ttio.transport.TransportIngest``
"""
from __future__ import annotations

import struct
from dataclasses import dataclass
from typing import Callable, Optional

from .packets import (
    HEADER_SIZE,
    AccessUnit,  # noqa: F401  (re-export hint for callers)
    PacketFlag,
    PacketHeader,
    PacketType,
    crc32c,
)


_CRC_STRUCT = struct.Struct("<I")


class TransportIngestError(ValueError):
    """Raised by :class:`TransportIngest` for any parse failure.

    Inherits :class:`ValueError` so callers using the same
    ``except ValueError:`` blocks as :class:`TransportReader` keep
    working unchanged.
    """


@dataclass(frozen=True, slots=True)
class PacketRecord:
    """One complete packet delivered to the ``on_packet`` callback."""

    header: PacketHeader
    payload: bytes


PacketCallback = Callable[[PacketRecord], None]
EndOfStreamCallback = Callable[[], None]
ErrorCallback = Callable[[TransportIngestError], None]


class TransportIngest:
    """Incremental packet parser. See module docstring."""

    __slots__ = (
        "_on_packet",
        "_on_end_of_stream",
        "_on_error",
        "_buffer",
        "_last_au_sequence_by_dataset",
        "_saw_stream_header",
        "_packet_count",
        "_is_finished",
    )

    def __init__(
        self,
        *,
        on_packet: PacketCallback,
        on_end_of_stream: Optional[EndOfStreamCallback] = None,
        on_error: Optional[ErrorCallback] = None,
    ):
        self._on_packet = on_packet
        self._on_end_of_stream = on_end_of_stream
        self._on_error = on_error
        self._buffer = bytearray()
        # #139: AU sequences are per-dataset, not stream-wide. Each
        # dataset's AUs start at 0 (walker.py: ``for j, spectrum in
        # enumerate(run)``); enforcing a single stream-wide counter
        # rejected legitimate multi-accessor v0.11 streams. Track
        # per ``dataset_id``; a dataset's first AU is "any value
        # goes" (matched by ``dict.get -> None``).
        self._last_au_sequence_by_dataset: dict[int, int] = {}
        self._saw_stream_header = False
        self._packet_count = 0
        self._is_finished = False

    # -------------------------------------------------------- properties

    @property
    def packet_count(self) -> int:
        """Total packets emitted so far. Useful for resumable-upload
        progress reporting."""
        return self._packet_count

    @property
    def buffered_bytes(self) -> int:
        """Bytes currently buffered awaiting a complete packet."""
        return len(self._buffer)

    @property
    def is_finished(self) -> bool:
        """``True`` once the ingest has received and emitted an
        EndOfStream packet, or has been put into the failed state by a
        parse error. Further :meth:`feed` calls on a finished ingest
        raise."""
        return self._is_finished

    # -------------------------------------------------------- feed/finish

    def feed(self, data: bytes) -> None:
        """Feed a chunk of transport bytes.

        As packets complete, delivers each to ``on_packet`` synchronously
        on the calling thread. Raises :class:`TransportIngestError` on
        the first parse error; the ``on_error`` callback is also invoked
        in that case (so callers may choose either failure-handling
        style).
        """
        if self._is_finished:
            raise self._fail("feed on finished ingest")
        if not data:
            return
        self._buffer.extend(data)
        self._drain()

    def finish(self) -> None:
        """Signal end-of-input.

        If the rolling buffer contains a partial packet (header without
        payload, payload without CRC, …) raises with a "truncated"
        message and fires the error callback. If the last successfully
        parsed packet was EndOfStream this is a no-op.
        """
        if self._is_finished:
            return
        if len(self._buffer) == 0:
            raise self._fail("stream ended without EndOfStream packet")
        raise self._fail(
            f"stream ended with {len(self._buffer)} bytes buffered "
            "(partial packet)"
        )

    # -------------------------------------------------------- drain loop

    def _drain(self) -> None:
        buf = self._buffer
        while len(buf) >= HEADER_SIZE:
            try:
                header = PacketHeader.from_bytes(bytes(buf[:HEADER_SIZE]))
            except ValueError as exc:
                raise self._fail(str(exc)) from exc

            if (not self._saw_stream_header
                    and header.packet_type != int(PacketType.STREAM_HEADER)):
                raise self._fail("first packet must be StreamHeader")

            has_crc = bool(header.flags & int(PacketFlag.HAS_CHECKSUM))
            trailing = 4 if has_crc else 0
            needed = HEADER_SIZE + header.payload_length + trailing
            if len(buf) < needed:
                # Wait for more bytes.
                return

            payload = bytes(buf[HEADER_SIZE:HEADER_SIZE + header.payload_length])

            if has_crc:
                crc_offset = HEADER_SIZE + header.payload_length
                (advertised,) = _CRC_STRUCT.unpack_from(buf, crc_offset)
                computed = crc32c(payload)
                if advertised != computed:
                    raise self._fail(
                        f"CRC-32C mismatch on packet type 0x{header.packet_type:02x}: "
                        f"advertised 0x{advertised:08x}, computed 0x{computed:08x}"
                    )

            if header.packet_type == int(PacketType.ACCESS_UNIT):
                # #139: monotonicity is per-dataset. ``dict.get -> None``
                # encodes "first AU in this dataset" — any value goes,
                # including 0 (the walker's natural starting point).
                last = self._last_au_sequence_by_dataset.get(
                    header.dataset_id
                )
                if last is not None and header.au_sequence <= last:
                    raise self._fail(
                        f"AU sequence regressed in dataset "
                        f"{header.dataset_id}: got {header.au_sequence}, "
                        f"last seen {last}"
                    )
                self._last_au_sequence_by_dataset[header.dataset_id] = (
                    header.au_sequence
                )

            if header.packet_type == int(PacketType.STREAM_HEADER):
                self._saw_stream_header = True

            # Advance the buffer in-place, then dispatch.
            del buf[:needed]
            self._packet_count += 1
            self._on_packet(PacketRecord(header=header, payload=payload))

            if header.packet_type == int(PacketType.END_OF_STREAM):
                self._is_finished = True
                # Tolerate trailing bytes after EndOfStream — some
                # producers pad. Drop them so the next feed() rejects.
                self._buffer.clear()
                if self._on_end_of_stream is not None:
                    self._on_end_of_stream()
                return

    # -------------------------------------------------------- failure

    def _fail(self, message: str) -> TransportIngestError:
        err = TransportIngestError(message)
        self._is_finished = True
        self._buffer.clear()
        if self._on_error is not None:
            self._on_error(err)
        return err


__all__ = [
    "PacketRecord",
    "TransportIngest",
    "TransportIngestError",
]
