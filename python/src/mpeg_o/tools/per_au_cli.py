"""v1.0 per-AU encryption CLI for cross-language conformance testing.

Provides encrypt/decrypt and transport-stream encrypt/decrypt
subcommands that mirror the Java ``com.dtwthalion.mpgo.tools.PerAUCli``
and Objective-C ``MpgoPerAU`` tool. All three implementations MUST
produce byte-equivalent outputs given identical inputs; the
cross-language conformance harness (``tests/integration/
test_per_au_cross_language.py``) drives this via subprocess.

Usage:
    python -m mpeg_o.tools.per_au_cli encrypt  <in.mpgo> <out.mpgo> <key-file> [--headers]
    python -m mpeg_o.tools.per_au_cli decrypt  <in.mpgo> <out.mpad> <key-file>
    python -m mpeg_o.tools.per_au_cli send     <in.mpgo> <out.mots> [--provider NAME]
    python -m mpeg_o.tools.per_au_cli recv     <in.mots> <out.mpgo>

Decryption writes an "MPAD" binary dump compatible with the Java and
Objective-C sides (see ``PerAUCli.java`` Javadoc for the byte
layout). Cross-language byte equality on the .mpad artefact proves
per-AU encryption parity end-to-end.
"""
from __future__ import annotations

import argparse
import json
import shutil
import struct
import sys
from pathlib import Path

import numpy as np

from mpeg_o.encryption_per_au import decrypt_per_au, encrypt_per_au
from mpeg_o.transport.encrypted import (
    read_encrypted_to_file,
    write_encrypted_dataset,
)

_MPAD_MAGIC = b"MPAD"


def _read_key(path: str) -> bytes:
    data = Path(path).read_bytes()
    if len(data) != 32:
        raise SystemExit(
            f"key file {path!r} must contain exactly 32 bytes, got {len(data)}"
        )
    return data


def _do_encrypt(args: argparse.Namespace) -> int:
    shutil.copyfile(args.input, args.output)
    encrypt_per_au(args.output, _read_key(args.key),
                    encrypt_headers=args.headers)
    return 0


def _json_double(value: float) -> str:
    if float(value).is_integer():
        return f"{float(value):.1f}"
    return repr(float(value))


def _headers_json(rows) -> str:
    """Emit a deterministic JSON array identical to Java's
    ``PerAUCli.auHeadersJson``. Keys are emitted in this exact order:
    acquisition_mode, base_peak_intensity, ion_mobility, ms_level,
    polarity, precursor_charge, precursor_mz, retention_time."""
    parts = []
    for r in rows:
        parts.append(
            "{"
            f"\"acquisition_mode\":{int(r['acquisition_mode'])},"
            f"\"base_peak_intensity\":{_json_double(r['base_peak_intensity'])},"
            f"\"ion_mobility\":{_json_double(r['ion_mobility'])},"
            f"\"ms_level\":{int(r['ms_level'])},"
            f"\"polarity\":{int(r['polarity'])},"
            f"\"precursor_charge\":{int(r['precursor_charge'])},"
            f"\"precursor_mz\":{_json_double(r['precursor_mz'])},"
            f"\"retention_time\":{_json_double(r['retention_time'])}"
            "}"
        )
    return "[" + ",".join(parts) + "]"


def _do_decrypt(args: argparse.Namespace) -> int:
    plain = decrypt_per_au(args.input, _read_key(args.key))
    entries: dict[str, bytes] = {}
    for run_name, run in plain.items():
        for ch, arr in run.items():
            if ch == "__au_headers__":
                entries[f"{run_name}__au_headers_json"] = \
                    _headers_json(arr).encode("utf-8")
            else:
                entries[f"{run_name}__{ch}"] = \
                    np.asarray(arr, dtype="<f8").tobytes()

    with open(args.output, "wb") as fp:
        fp.write(_MPAD_MAGIC)
        fp.write(struct.pack("<I", len(entries)))
        for key in sorted(entries):
            key_bytes = key.encode("utf-8")
            fp.write(struct.pack("<H", len(key_bytes)))
            fp.write(key_bytes)
            value = entries[key]
            fp.write(struct.pack("<I", len(value)))
            fp.write(value)
    return 0


def _do_send(args: argparse.Namespace) -> int:
    from mpeg_o.transport.codec import TransportWriter
    with TransportWriter(args.output) as writer:
        write_encrypted_dataset(writer, args.input, provider=args.provider)
    return 0


def _do_recv(args: argparse.Namespace) -> int:
    read_encrypted_to_file(args.input, args.output)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subs = parser.add_subparsers(dest="cmd", required=True)

    enc = subs.add_parser("encrypt")
    enc.add_argument("input")
    enc.add_argument("output")
    enc.add_argument("key")
    enc.add_argument("--headers", action="store_true")
    enc.set_defaults(func=_do_encrypt)

    dec = subs.add_parser("decrypt")
    dec.add_argument("input")
    dec.add_argument("output")
    dec.add_argument("key")
    dec.set_defaults(func=_do_decrypt)

    snd = subs.add_parser("send")
    snd.add_argument("input")
    snd.add_argument("output")
    snd.add_argument("--provider", default=None)
    snd.set_defaults(func=_do_send)

    rcv = subs.add_parser("recv")
    rcv.add_argument("input")
    rcv.add_argument("output")
    rcv.set_defaults(func=_do_recv)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
