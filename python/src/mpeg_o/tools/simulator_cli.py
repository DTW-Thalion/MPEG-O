"""Command-line simulator entry point (v0.10 M69).

Usage:
    python -m mpeg_o.tools.simulator_cli <output.mots>
        [--scan-rate 10] [--duration 10] [--ms1-fraction 0.3]
        [--mz-min 100] [--mz-max 2000] [--n-peaks 200] [--seed 42]

Writes a full transport stream (StreamHeader → DatasetHeader →
AccessUnits → EndOfDataset → EndOfStream) to ``<output.mots>`` using
deterministic synthetic spectra. The output file can be fed back
through ``TransportReader`` or served via
``transport_server_cli``-equivalent tools.
"""
from __future__ import annotations

import argparse
import sys

from mpeg_o.transport.codec import TransportWriter
from mpeg_o.transport.simulator import AcquisitionSimulator


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Generate a synthetic MPEG-O transport stream."
    )
    parser.add_argument("output", help="path to write the .mots file")
    parser.add_argument("--scan-rate", type=float, default=10.0,
                        help="scans per second (default: 10)")
    parser.add_argument("--duration", type=float, default=10.0,
                        help="total acquisition seconds (default: 10)")
    parser.add_argument("--ms1-fraction", type=float, default=0.3,
                        help="fraction of MS1 scans (default: 0.3)")
    parser.add_argument("--mz-min", type=float, default=100.0)
    parser.add_argument("--mz-max", type=float, default=2000.0)
    parser.add_argument("--n-peaks", type=int, default=200)
    parser.add_argument("--seed", type=int, default=42)
    args = parser.parse_args(argv)

    sim = AcquisitionSimulator(
        scan_rate=args.scan_rate,
        duration=args.duration,
        ms1_fraction=args.ms1_fraction,
        mz_range=(args.mz_min, args.mz_max),
        n_peaks=args.n_peaks,
        seed=args.seed,
    )
    with TransportWriter(args.output) as tw:
        n = sim.stream_to_writer(tw)
    print(f"{n} access units written to {args.output}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
