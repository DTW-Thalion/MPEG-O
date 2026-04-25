"""``ttio-pqc`` — Python post-quantum crypto CLI (M75).

Python equivalent of the Objective-C ``TtioPQCTool`` (``objc/Tools/
TtioPQCTool.m``) and Java ``com.dtwthalion.ttio.tools.PQCTool``. The
subcommand grammar is 1-to-1 across the three languages so the
cross-language conformance harness (``python/tests/
test_m54_pqc_conformance.py``) can drive any of the three via identical
argument strings.

All file arguments are raw bytes (no hex wrapping) so round-trip byte
equality is exact.

Subcommands::

    ttio-pqc sig-keygen       PK_OUT  SK_OUT
    ttio-pqc sig-sign         SK_IN   MSG_IN  SIG_OUT
    ttio-pqc sig-verify       PK_IN   MSG_IN  SIG_IN       (exit 0/1/2)
    ttio-pqc kem-keygen       PK_OUT  SK_OUT
    ttio-pqc kem-encaps       PK_IN   CT_OUT  SS_OUT
    ttio-pqc kem-decaps       SK_IN   CT_IN   SS_OUT
    ttio-pqc hdf5-sign        FILE    DS_PATH  SK_IN
    ttio-pqc hdf5-verify      FILE    DS_PATH  PK_IN       (exit 0/1/2)
    ttio-pqc provider-sign    URL     DS_PATH  SK_IN
    ttio-pqc provider-verify  URL     DS_PATH  PK_IN       (exit 0/1/2)

The verify subcommands return ``0`` for a valid signature, ``1`` for an
invalid one, and ``2`` for any other error (matches the peer tools).

Requires the ``[pqc]`` optional extra (``pip install 'ttio[pqc]'``).
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import h5py

from .. import pqc, signatures
from ..providers import open_provider
from ..providers.base import StorageDataset, StorageGroup


USAGE = (
    "usage: ttio-pqc <subcommand> [args...]\n"
    "  sig-keygen       PK_OUT  SK_OUT\n"
    "  sig-sign         SK_IN   MSG_IN  SIG_OUT\n"
    "  sig-verify       PK_IN   MSG_IN  SIG_IN\n"
    "  kem-keygen       PK_OUT  SK_OUT\n"
    "  kem-encaps       PK_IN   CT_OUT  SS_OUT\n"
    "  kem-decaps       SK_IN   CT_IN   SS_OUT\n"
    "  hdf5-sign        FILE    DS_PATH  SK_IN\n"
    "  hdf5-verify      FILE    DS_PATH  PK_IN\n"
    "  provider-sign    URL     DS_PATH  SK_IN\n"
    "  provider-verify  URL     DS_PATH  PK_IN\n"
)


def _read_bytes(path: str) -> bytes:
    return Path(path).read_bytes()


def _write_bytes(path: str, data: bytes) -> None:
    Path(path).write_bytes(data)


def _sig_keygen(args: list[str]) -> int:
    if len(args) < 2:
        sys.stderr.write("usage: sig-keygen PK_OUT SK_OUT\n")
        return 2
    kp = pqc.sig_keygen()
    _write_bytes(args[0], kp.public_key)
    _write_bytes(args[1], kp.private_key)
    return 0


def _sig_sign(args: list[str]) -> int:
    if len(args) < 3:
        sys.stderr.write("usage: sig-sign SK_IN MSG_IN SIG_OUT\n")
        return 2
    sk = _read_bytes(args[0])
    msg = _read_bytes(args[1])
    sig = pqc.sig_sign(sk, msg)
    _write_bytes(args[2], sig)
    return 0


def _sig_verify(args: list[str]) -> int:
    if len(args) < 3:
        sys.stderr.write("usage: sig-verify PK_IN MSG_IN SIG_IN\n")
        return 2
    pk = _read_bytes(args[0])
    msg = _read_bytes(args[1])
    sig = _read_bytes(args[2])
    return 0 if pqc.sig_verify(pk, msg, sig) else 1


def _kem_keygen(args: list[str]) -> int:
    if len(args) < 2:
        sys.stderr.write("usage: kem-keygen PK_OUT SK_OUT\n")
        return 2
    kp = pqc.kem_keygen()
    _write_bytes(args[0], kp.public_key)
    _write_bytes(args[1], kp.private_key)
    return 0


def _kem_encaps(args: list[str]) -> int:
    if len(args) < 3:
        sys.stderr.write("usage: kem-encaps PK_IN CT_OUT SS_OUT\n")
        return 2
    pk = _read_bytes(args[0])
    ct, ss = pqc.kem_encapsulate(pk)
    _write_bytes(args[1], ct)
    _write_bytes(args[2], ss)
    return 0


def _kem_decaps(args: list[str]) -> int:
    if len(args) < 3:
        sys.stderr.write("usage: kem-decaps SK_IN CT_IN SS_OUT\n")
        return 2
    sk = _read_bytes(args[0])
    ct = _read_bytes(args[1])
    ss = pqc.kem_decapsulate(sk, ct)
    _write_bytes(args[2], ss)
    return 0


def _hdf5_sign(args: list[str]) -> int:
    if len(args) < 3:
        sys.stderr.write("usage: hdf5-sign FILE DS_PATH SK_IN\n")
        return 2
    sk = _read_bytes(args[2])
    with h5py.File(args[0], "r+") as f:
        dataset = f[args[1]]
        if not isinstance(dataset, h5py.Dataset):
            sys.stderr.write(f"not a dataset: {args[1]}\n")
            return 2
        signatures.sign_dataset(dataset, sk, algorithm="ml-dsa-87")
    return 0


def _hdf5_verify(args: list[str]) -> int:
    if len(args) < 3:
        sys.stderr.write("usage: hdf5-verify FILE DS_PATH PK_IN\n")
        return 2
    pk = _read_bytes(args[2])
    with h5py.File(args[0], "r") as f:
        dataset = f[args[1]]
        if not isinstance(dataset, h5py.Dataset):
            sys.stderr.write(f"not a dataset: {args[1]}\n")
            return 2
        try:
            ok = signatures.verify_dataset(dataset, pk, algorithm="ml-dsa-87")
        except Exception as e:  # noqa: BLE001 — match peer tool (exit 2 on error)
            sys.stderr.write(f"verify error: {e}\n")
            return 2
    return 0 if ok else 1


def _open_storage_dataset(provider, path: str) -> StorageDataset:
    trimmed = path.lstrip("/")
    parts = trimmed.split("/")
    node: StorageGroup = provider.root_group()
    for segment in parts[:-1]:
        node = node.open_group(segment)
    return node.open_dataset(parts[-1])


def _provider_sign(args: list[str]) -> int:
    if len(args) < 3:
        sys.stderr.write("usage: provider-sign URL DS_PATH SK_IN\n")
        return 2
    sk = _read_bytes(args[2])
    provider = open_provider(args[0], mode="r+")
    try:
        dataset = _open_storage_dataset(provider, args[1])
        signatures.sign_storage_dataset(dataset, sk, algorithm="ml-dsa-87")
    finally:
        provider.close()
    return 0


def _provider_verify(args: list[str]) -> int:
    if len(args) < 3:
        sys.stderr.write("usage: provider-verify URL DS_PATH PK_IN\n")
        return 2
    pk = _read_bytes(args[2])
    provider = open_provider(args[0], mode="r")
    try:
        dataset = _open_storage_dataset(provider, args[1])
        try:
            ok = signatures.verify_storage_dataset(
                dataset, pk, algorithm="ml-dsa-87"
            )
        except Exception as e:  # noqa: BLE001 — match peer tool
            sys.stderr.write(f"verify error: {e}\n")
            return 2
    finally:
        provider.close()
    return 0 if ok else 1


_DISPATCH = {
    "sig-keygen": _sig_keygen,
    "sig-sign": _sig_sign,
    "sig-verify": _sig_verify,
    "kem-keygen": _kem_keygen,
    "kem-encaps": _kem_encaps,
    "kem-decaps": _kem_decaps,
    "hdf5-sign": _hdf5_sign,
    "hdf5-verify": _hdf5_verify,
    "provider-sign": _provider_sign,
    "provider-verify": _provider_verify,
}


def main(argv: list[str] | None = None) -> int:
    argv = sys.argv[1:] if argv is None else list(argv)
    if not argv or argv[0] in ("-h", "--help"):
        sys.stderr.write(USAGE)
        return 0 if argv and argv[0] in ("-h", "--help") else 2
    sub = argv[0]
    handler = _DISPATCH.get(sub)
    if handler is None:
        sys.stderr.write(f"unknown subcommand: {sub}\n{USAGE}")
        return 2
    try:
        return handler(argv[1:])
    except Exception as e:  # noqa: BLE001 — mirror peer tools' exit-2 policy
        sys.stderr.write(f"ttio-pqc {sub} failed: {e}\n")
        return 2


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
