"""Entry-point for spawning a transport server as a subprocess.

Usage:
    python -m ttio.tools.transport_server_cli <ttio-path> [--port 0] [--host 127.0.0.1]

The bound port is printed to stdout as ``PORT=<n>`` on a single line so
callers can capture it. The process runs until terminated.
"""
from __future__ import annotations

import argparse
import asyncio
import sys

from ttio.transport.server import TransportServer


async def serve(
    ttio_path: str,
    *,
    host: str = "127.0.0.1",
    port: int = 0,
    on_ready=None,
) -> None:
    """Serve a .tio file over WebSocket transport until cancelled.

    The bound port is reported via ``on_ready(port)`` if given, else
    printed to stdout as ``PORT=<n>`` (the CLI default). Runs until the
    surrounding task is cancelled or the server is closed.
    """
    server = TransportServer(ttio_path, host=host, port=port)
    await server.start()
    if on_ready is not None:
        on_ready(server.port)
    else:
        print(f"PORT={server.port}", flush=True)
    try:
        await server.wait_closed()
    except asyncio.CancelledError:
        pass
    finally:
        await server.stop()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Serve an TTI-O .tio file over WebSocket transport."
    )
    parser.add_argument("ttio_path", help="path to a .tio file")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0,
                        help="0 = pick any free port (default)")
    args = parser.parse_args(argv)

    try:
        asyncio.run(serve(args.ttio_path, host=args.host, port=args.port))
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
