"""``mpgo-sign`` — HMAC-SHA256 signer for MPEG-O datasets (M75).

Python equivalent of the Objective-C ``MpgoSign`` tool. Opens an
``.mpgo`` file, navigates to the HDF5 dataset path, and signs it in
place with the v0.3 canonical HMAC-SHA256 path (``v2:`` prefix).

Usage::

    mpgo-sign <path-to.mpgo> <dataset-path> <key-hex>

``<key-hex>`` is 64 hexadecimal characters (32 bytes, HMAC-SHA256 key).

Exit codes
----------
- ``0`` — signed successfully.
- ``1`` — sign failed (I/O, dataset missing, etc).
- ``2`` — usage error.
"""
from __future__ import annotations

import argparse
import sys

import h5py

from .. import signatures


def _parse_key_hex(key_hex: str) -> bytes:
    if len(key_hex) != 64:
        raise SystemExit(
            f"mpgo-sign: expected 64-character hex key, got {len(key_hex)}"
        )
    try:
        return bytes.fromhex(key_hex)
    except ValueError as e:
        raise SystemExit(f"mpgo-sign: invalid hex key: {e}") from e


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="mpgo-sign",
        description="Sign an HDF5 dataset inside a .mpgo file with HMAC-SHA256.",
    )
    parser.add_argument("path", help="path to .mpgo file")
    parser.add_argument("dataset", help="HDF5 dataset path, e.g. /study/ms_runs/run_0001/mz_values")
    parser.add_argument("key_hex", help="64-character hex HMAC-SHA256 key")
    args = parser.parse_args(argv)

    key = _parse_key_hex(args.key_hex)

    try:
        with h5py.File(args.path, "r+") as f:
            try:
                dataset = f[args.dataset]
            except KeyError:
                sys.stderr.write(f"mpgo-sign: dataset not found: {args.dataset}\n")
                return 1
            if not isinstance(dataset, h5py.Dataset):
                sys.stderr.write(
                    f"mpgo-sign: path is not a dataset: {args.dataset}\n"
                )
                return 1
            signatures.sign_dataset(dataset, key)
    except OSError as e:
        sys.stderr.write(f"mpgo-sign: failed to open {args.path}: {e}\n")
        return 1
    return 0


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
