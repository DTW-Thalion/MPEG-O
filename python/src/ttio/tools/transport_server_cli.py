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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Serve an TTI-O .tio file over WebSocket transport."
    )
    parser.add_argument("ttio_path", help="path to a .tio file")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0,
                        help="0 = pick any free port (default)")
    args = parser.parse_args(argv)

    async def run() -> None:
        server = TransportServer(args.ttio_path, host=args.host, port=args.port)
        await server.start()
        # Print once, flush, keep serving until the parent closes stdin
        # or sends SIGTERM.
        print(f"PORT={server.port}", flush=True)
        try:
            await server.wait_closed()
        except asyncio.CancelledError:
            pass
        finally:
            await server.stop()

    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
