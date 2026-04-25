"""v1.0 per-AU encryption CLI for cross-language conformance testing.

Provides encrypt/decrypt and transport-stream encrypt/decrypt
subcommands that mirror the Java ``global.thalion.ttio.tools.PerAUCli``
and Objective-C ``TtioPerAU`` tool. All three implementations MUST
produce byte-equivalent outputs given identical inputs; the
cross-language conformance harness (``tests/integration/
test_per_au_cross_language.py``) drives this via subprocess.

Usage:
    python -m ttio.tools.per_au_cli encrypt   <in.tio> <out.tio> <key-file> [--headers]
    python -m ttio.tools.per_au_cli decrypt   <in.tio> <out.mpad> <key-file>
    python -m ttio.tools.per_au_cli send      <in.tio> <out.tis> [--provider NAME]
    python -m ttio.tools.per_au_cli recv      <in.tis> <out.tio>
    python -m ttio.tools.per_au_cli transcode <in.tio> <out.tio> <key-file> [--headers] [--rekey <new-key-file>]

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

from ttio.encryption_per_au import decrypt_per_au, encrypt_per_au
from ttio.transport.encrypted import (
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
    from ttio.transport.codec import TransportWriter
    with TransportWriter(args.output) as writer:
        write_encrypted_dataset(writer, args.input, provider=args.provider)
    return 0


def _do_recv(args: argparse.Namespace) -> int:
    read_encrypted_to_file(args.input, args.output)
    return 0


def _do_transcode(args: argparse.Namespace) -> int:
    """Migrate a file to opt_per_au_encryption. Three sources supported:

    1. Plaintext .tio (no encryption): copies + calls encrypt_per_au.
    2. opt_per_au_encryption already present: decrypts then re-encrypts
       (useful for rotating the DEK via --rekey or toggling --headers).
    3. v0.x opt_dataset_encryption: prints a migration hint and exits
       non-zero; users must first decrypt channels via the v0.x API.
    """
    from ttio.feature_flags import OPT_DATASET_ENCRYPTION
    from ttio.providers.registry import open_provider
    from ttio import _hdf5_io as io

    key = _read_key(args.key)
    new_key = _read_key(args.rekey) if args.rekey else key

    with open_provider(args.input, mode="r") as sp:
        root = sp.root_group()
        _, features = io.read_feature_flags(root)

    if OPT_DATASET_ENCRYPTION in features:
        raise SystemExit(
            f"{args.input} carries opt_dataset_encryption (v0.x). "
            "Decrypt channels via v0.x `SpectralDataset.decrypt()` first, "
            "then transcode the plaintext result."
        )

    shutil.copyfile(args.input, args.output)
    if "opt_per_au_encryption" in features:
        # Re-encrypt path: decrypt → overwrite with fresh IVs + new key.
        plain = decrypt_per_au(args.output, key)
        # Rewrite channels as plaintext values datasets so the
        # encrypt_per_au helper finds them.
        import h5py
        with h5py.File(args.output, "a") as f:
            for run_name, run in plain.items():
                sig = f[f"study/ms_runs/{run_name}/signal_channels"]
                for ch, data in run.items():
                    if ch == "__au_headers__":
                        continue
                    seg_name = f"{ch}_segments"
                    if seg_name in sig:
                        del sig[seg_name]
                    if f"{ch}_values" in sig:
                        del sig[f"{ch}_values"]
                    sig.create_dataset(f"{ch}_values", data=data)
                    # Drop the per-channel metadata left by the v1.0 writer.
                    for attr in (f"{ch}_algorithm", f"{ch}_wrapped_dek",
                                  f"{ch}_kek_algorithm"):
                        if attr in sig.attrs:
                            del sig.attrs[attr]
                # If the source had opt_encrypted_au_headers, reconstruct
                # the six plaintext index arrays so encrypt_per_au can
                # read them back.
                if run.get("__au_headers__"):
                    idx = f[f"study/ms_runs/{run_name}/spectrum_index"]
                    if "au_header_segments" in idx:
                        del idx["au_header_segments"]
                    hdrs = run["__au_headers__"]
                    idx.create_dataset("retention_times",
                        data=np.array([h["retention_time"] for h in hdrs],
                                      dtype="<f8"))
                    idx.create_dataset("ms_levels",
                        data=np.array([h["ms_level"] for h in hdrs],
                                      dtype="<i4"))
                    idx.create_dataset("polarities",
                        data=np.array([h["polarity"] for h in hdrs],
                                      dtype="<i4"))
                    idx.create_dataset("precursor_mzs",
                        data=np.array([h["precursor_mz"] for h in hdrs],
                                      dtype="<f8"))
                    idx.create_dataset("precursor_charges",
                        data=np.array([h["precursor_charge"] for h in hdrs],
                                      dtype="<i4"))
                    idx.create_dataset("base_peak_intensities",
                        data=np.array([h["base_peak_intensity"] for h in hdrs],
                                      dtype="<f8"))
            # Drop v1.0 feature flags so encrypt_per_au reintroduces them.
            current = bytes(f.attrs["ttio_features"]).decode("utf-8")
            kept = [x for x in json.loads(current)
                     if x not in ("opt_per_au_encryption",
                                   "opt_encrypted_au_headers")]
            f.attrs["ttio_features"] = json.dumps(kept)

    encrypt_per_au(args.output, new_key, encrypt_headers=args.headers)
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

    tc = subs.add_parser("transcode")
    tc.add_argument("input")
    tc.add_argument("output")
    tc.add_argument("key")
    tc.add_argument("--headers", action="store_true")
    tc.add_argument("--rekey", default=None,
                     help="re-wrap DEK with a new key (path to 32-byte key file)")
    tc.set_defaults(func=_do_transcode)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":  # pragma: no cover
    sys.exit(main())
