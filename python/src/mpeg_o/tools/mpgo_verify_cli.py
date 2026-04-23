"""``mpgo-verify`` — HMAC-SHA256 signature verifier (M75).

Python CLI frontend for :class:`mpeg_o.verifier.Verifier`. Opens a
``.mpgo`` file, navigates to the given HDF5 dataset, reads the
``@mpgo_signature`` attribute, and reports the :class:`VerificationStatus`.

Usage::

    mpgo-verify <path-to.mpgo> <dataset-path> <key-hex>

``<key-hex>`` is 64 hexadecimal characters (32-byte HMAC-SHA256 key).

Output
------
Prints the status name (``VALID``, ``INVALID``, ``NOT_SIGNED``, ``ERROR``)
to stdout.

Exit codes (mirror :class:`mpeg_o.verifier.VerificationStatus`)
--------------------------------------------------------------
- ``0`` — ``VALID``.
- ``1`` — ``INVALID``.
- ``2`` — ``NOT_SIGNED``.
- ``3`` — ``ERROR`` (I/O failure, dataset missing, key-shape mismatch).
"""
from __future__ import annotations

import argparse
import sys

import h5py

from ..signatures import SIGNATURE_ATTR, _dataset_canonical_bytes, _read_vl_string_attr
from ..verifier import Verifier, VerificationStatus


def _parse_key_hex(key_hex: str) -> bytes:
    if len(key_hex) != 64:
        raise SystemExit(
            f"mpgo-verify: expected 64-character hex key, got {len(key_hex)}"
        )
    try:
        return bytes.fromhex(key_hex)
    except ValueError as e:
        raise SystemExit(f"mpgo-verify: invalid hex key: {e}") from e


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="mpgo-verify",
        description="Verify a canonical HMAC-SHA256 signature on an HDF5 "
                     "dataset inside a .mpgo file.",
    )
    parser.add_argument("path", help="path to .mpgo file")
    parser.add_argument("dataset", help="HDF5 dataset path")
    parser.add_argument("key_hex", help="64-character hex HMAC-SHA256 key")
    args = parser.parse_args(argv)

    key = _parse_key_hex(args.key_hex)

    try:
        with h5py.File(args.path, "r") as f:
            try:
                dataset = f[args.dataset]
            except KeyError:
                sys.stderr.write(f"mpgo-verify: dataset not found: {args.dataset}\n")
                print(VerificationStatus.ERROR.name)
                return int(VerificationStatus.ERROR)
            if not isinstance(dataset, h5py.Dataset):
                sys.stderr.write(
                    f"mpgo-verify: path is not a dataset: {args.dataset}\n"
                )
                print(VerificationStatus.ERROR.name)
                return int(VerificationStatus.ERROR)
            canonical = _dataset_canonical_bytes(dataset)
            stored = _read_vl_string_attr(dataset, SIGNATURE_ATTR)
    except OSError as e:
        sys.stderr.write(f"mpgo-verify: failed to open {args.path}: {e}\n")
        print(VerificationStatus.ERROR.name)
        return int(VerificationStatus.ERROR)

    status = Verifier.verify(canonical, stored, key)
    print(status.name)
    return int(status)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
