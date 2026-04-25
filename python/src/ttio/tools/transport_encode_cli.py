"""Encode a .tio file as a .tis transport stream (v0.10 M70).

Parallel to Java {@code global.thalion.ttio.tools.TransportEncodeCli}
and ObjC {@code TtioTransportEncode}.

Usage:
    python -m ttio.tools.transport_encode_cli <input.tio> <output.tis>
        [--checksum]
"""
from __future__ import annotations

import argparse
import sys

from ttio.transport.codec import file_to_transport


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Encode a .tio file as an TTI-O transport stream."
    )
    parser.add_argument("input", help="path to a .tio file")
    parser.add_argument("output", help="path to write the .tis stream")
    parser.add_argument("--checksum", action="store_true",
                        help="emit per-packet CRC-32C checksums")
    args = parser.parse_args(argv)
    file_to_transport(args.input, args.output, use_checksum=args.checksum)
    return 0


if __name__ == "__main__":
    sys.exit(main())
