"""Decode a .mots transport stream into a .mpgo file (v0.10 M70).

Parallel to Java {@code com.dtwthalion.mpgo.tools.TransportDecodeCli}
and ObjC {@code MpgoTransportDecode}.

Usage:
    python -m mpeg_o.tools.transport_decode_cli <input.mots> <output.mpgo>
"""
from __future__ import annotations

import argparse
import sys

from mpeg_o.transport.codec import transport_to_file


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Decode an MPEG-O transport stream into a .mpgo file."
    )
    parser.add_argument("input", help="path to a .mots file")
    parser.add_argument("output", help="path to write the .mpgo file")
    args = parser.parse_args(argv)
    ds = transport_to_file(args.input, args.output)
    ds.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
