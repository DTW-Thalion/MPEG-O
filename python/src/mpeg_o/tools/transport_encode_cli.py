"""Encode a .mpgo file as a .mots transport stream (v0.10 M70).

Parallel to Java {@code com.dtwthalion.mpgo.tools.TransportEncodeCli}
and ObjC {@code MpgoTransportEncode}.

Usage:
    python -m mpeg_o.tools.transport_encode_cli <input.mpgo> <output.mots>
        [--checksum]
"""
from __future__ import annotations

import argparse
import sys

from mpeg_o.transport.codec import file_to_transport


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Encode a .mpgo file as an MPEG-O transport stream."
    )
    parser.add_argument("input", help="path to a .mpgo file")
    parser.add_argument("output", help="path to write the .mots stream")
    parser.add_argument("--checksum", action="store_true",
                        help="emit per-packet CRC-32C checksums")
    args = parser.parse_args(argv)
    file_to_transport(args.input, args.output, use_checksum=args.checksum)
    return 0


if __name__ == "__main__":
    sys.exit(main())
