"""Dataset-level envelope-encryption ``dek_wrapped`` cross-language CLI.

Drives the public envelope-encryption API
(:func:`ttio.key_rotation.enable_envelope_encryption` /
:func:`ttio.key_rotation.unwrap_dek`) so the cross-language conformance
harness can prove that a ``/protection/key_info/dek_wrapped`` dataset
written by one language is correctly read **and unwrapped** by the
others.

This guards the bug fixed on ``fix/dek-wrapped-xlang``: Java/ObjC used
to store ``dek_wrapped`` as an ``int32``-packed, 4-byte-padded dataset
while Python stored the spec-compliant ``uint8[N]`` exact-length blob,
so a file written by one language crashed/corrupted when read by
another. All three now write ``uint8[N]``.

Mirrors:
  * Objective-C ``TtioDekEnvelope``
    (``objc/Tools/TtioDekEnvelope.m``).
  * Java ``global.thalion.ttio.tools.DekEnvelopeCli``.

Usage::

    python -m ttio.tools.dek_envelope_cli wrap <out.tio> <kek-file> \\
        [--algorithm aes-256-gcm|ml-kem-1024] [--dek-out <hex-file>]
    python -m ttio.tools.dek_envelope_cli unwrap <in.tio> <kek-file> \\
        [--algorithm aes-256-gcm|ml-kem-1024]

``wrap`` generates a fresh random DEK (the production path), wraps it
under the KEK read from ``kek-file``, persists ``key_info``, and prints
the plaintext DEK as lowercase hex to stdout (also to ``--dek-out`` when
given). ``unwrap`` opens the file, unwraps with the KEK, and prints the
recovered DEK as lowercase hex. Cross-language equality of the recovered
DEK against the writer's reported DEK proves the on-disk layout is
interoperable.

For ``--algorithm aes-256-gcm`` the ``kek-file`` is a 32-byte symmetric
key. For ``--algorithm ml-kem-1024`` it is the ML-KEM key material: the
1568-byte encapsulation **public** key for ``wrap`` and the 3168-byte
decapsulation **private** key for ``unwrap``.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import h5py

from ttio.key_rotation import enable_envelope_encryption, unwrap_dek

_AES = "aes-256-gcm"
_MLKEM = "ml-kem-1024"


def _read_kek(path: str, algorithm: str) -> bytes:
    data = Path(path).read_bytes()
    if algorithm == _AES and len(data) != 32:
        raise SystemExit(
            f"aes-256-gcm KEK file {path!r} must be 32 bytes, got {len(data)}"
        )
    return data


def _do_wrap(args: argparse.Namespace) -> int:
    kek = _read_kek(args.kek, args.algorithm)
    with h5py.File(args.output, "w") as f:
        dek = enable_envelope_encryption(
            f, kek, kek_id=args.kek_id, algorithm=args.algorithm
        )
    dek_hex = dek.hex()
    if args.dek_out:
        Path(args.dek_out).write_text(dek_hex + "\n")
    sys.stdout.write(dek_hex + "\n")
    return 0


def _do_unwrap(args: argparse.Namespace) -> int:
    kek = _read_kek(args.kek, args.algorithm)
    with h5py.File(args.input, "r") as f:
        dek = unwrap_dek(f, kek, algorithm=args.algorithm)
    sys.stdout.write(dek.hex() + "\n")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="cmd", required=True)

    wrap = subs.add_parser("wrap")
    wrap.add_argument("output")
    wrap.add_argument("kek")
    wrap.add_argument("--algorithm", default=_AES, choices=[_AES, _MLKEM])
    wrap.add_argument("--kek-id", default="kek-xlang", dest="kek_id")
    wrap.add_argument("--dek-out", default=None, dest="dek_out")
    wrap.set_defaults(func=_do_wrap)

    unwrap = subs.add_parser("unwrap")
    unwrap.add_argument("input")
    unwrap.add_argument("kek")
    unwrap.add_argument("--algorithm", default=_AES, choices=[_AES, _MLKEM])
    unwrap.set_defaults(func=_do_unwrap)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
