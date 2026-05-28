"""``ttio-verify`` — HMAC-SHA256 signature verifier.

Python CLI frontend for :class:`ttio.verifier.Verifier`. Opens a
``.tio`` file, navigates to the given HDF5 dataset, reads the
``@ttio_signature`` attribute, and reports the :class:`VerificationStatus`.

Usage::

    ttio-verify <path-to.tio> <dataset-path> <key-hex>

``<key-hex>`` is 64 hexadecimal characters (32-byte HMAC-SHA256 key).

Output
------
Prints the status name (``VALID``, ``INVALID``, ``NOT_SIGNED``, ``ERROR``)
to stdout.

Exit codes (mirror :class:`ttio.verifier.VerificationStatus`)
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
    """Decode a 64-character hex string into a 32-byte HMAC key.

    Raises :class:`SystemExit` with an explanatory message when the
    length is wrong or the string is not valid hex.
    """
    if len(key_hex) != 64:
        raise SystemExit(
            f"ttio-verify: expected 64-character hex key, got {len(key_hex)}"
        )
    try:
        return bytes.fromhex(key_hex)
    except ValueError as e:
        raise SystemExit(f"ttio-verify: invalid hex key: {e}") from e


def main(argv: list[str] | None = None) -> int:
    """Verify the HMAC-SHA256 signature on one HDF5 dataset.

    Parses three positional arguments (``path``, ``dataset``,
    ``key_hex``), reads the ``@ttio_signature`` attribute, and prints
    the resulting :class:`VerificationStatus` name to stdout.

    Parameters
    ----------
    argv : list[str], optional
        Argument vector. Defaults to ``sys.argv[1:]`` when ``None``.

    Returns
    -------
    int
        Mirrors :class:`VerificationStatus` integer values: ``0`` valid,
        ``1`` invalid, ``2`` not signed, ``3`` error.
    """
    parser = argparse.ArgumentParser(
        prog="ttio-verify",
        description="Verify a canonical HMAC-SHA256 signature on an HDF5 "
                     "dataset inside a .tio file.",
    )
    parser.add_argument("path", help="path to .tio file")
    parser.add_argument("dataset", help="HDF5 dataset path")
    parser.add_argument("key_hex", help="64-character hex HMAC-SHA256 key")
    args = parser.parse_args(argv)

    key = _parse_key_hex(args.key_hex)

    try:
        with h5py.File(args.path, "r") as f:
            try:
                dataset = f[args.dataset]
            except KeyError:
                sys.stderr.write(f"ttio-verify: dataset not found: {args.dataset}\n")
                print(VerificationStatus.ERROR.name)
                return int(VerificationStatus.ERROR)
            if not isinstance(dataset, h5py.Dataset):
                sys.stderr.write(
                    f"ttio-verify: path is not a dataset: {args.dataset}\n"
                )
                print(VerificationStatus.ERROR.name)
                return int(VerificationStatus.ERROR)
            canonical = _dataset_canonical_bytes(dataset)
            stored = _read_vl_string_attr(dataset, SIGNATURE_ATTR)
    except OSError as e:
        sys.stderr.write(f"ttio-verify: failed to open {args.path}: {e}\n")
        print(VerificationStatus.ERROR.name)
        return int(VerificationStatus.ERROR)

    status = Verifier.verify(canonical, stored, key)
    print(status.name)
    return int(status)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
