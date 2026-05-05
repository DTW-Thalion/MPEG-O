"""Decode a .tis transport stream into a .tio file ().

Parallel to Java {@code global.thalion.ttio.tools.TransportDecodeCli}
and ObjC {@code TtioTransportDecode}.

Usage:
    python -m ttio.tools.transport_decode_cli <input.tis> <output.tio>
"""
from __future__ import annotations

import argparse
import sys

from ttio.transport.codec import transport_to_file


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Decode an TTI-O transport stream into a .tio file."
    )
    parser.add_argument("input", help="path to a .tis file")
    parser.add_argument("output", help="path to write the .tio file")
    args = parser.parse_args(argv)
    ds = transport_to_file(args.input, args.output)
    ds.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
