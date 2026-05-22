#!/usr/bin/env python3
"""Executable spec-proof for FD-1 Phase A — multi-recipient ProtectionMetadata.

Demonstrates, against the *real* current decoder
(`ttio.transport.encrypted._decode_protection_metadata`), that the
append-only multi-recipient layout proposed in
``2026-05-21-fd1-phase-a-multi-recipient-protection-metadata-spec.md`` is
backward-compatible:

  P1  a single-recipient new-format packet is byte-identical to today's.
  P2  the current reader parses a 2-recipient packet without error and
      recovers the PRIMARY recipient (it ignores the trailing block).
  P3  the proposed new decoder recovers all N recipients.
  P4  today's packets still decode under the current reader (regression).

Run: ``python3 docs/superpowers/specs/2026-05-21-fd1-phase-a-proof.py``
(requires an editable ttio install). Exits non-zero on any failed proof.
"""
import struct

from ttio.transport.codec import pack_string, unpack_string
from ttio.transport.encrypted import _decode_protection_metadata


def encode_current(cs, kek, wrapped, sig="", pk=b""):
    """Today's §4.4 single-recipient payload (mirrors
    `_emit_protection_metadata`)."""
    return (pack_string(cs, width=2) + pack_string(kek, width=2)
            + struct.pack("<I", len(wrapped)) + wrapped
            + pack_string(sig, width=2) + struct.pack("<I", len(pk)) + pk)


def encode_multi(cs, kek_primary, wrapped_primary, additional, sig="", pk=b""):
    """Proposed append-only multi-recipient payload. `additional` is a list
    of (recipient_id, kek_algorithm, wrapped_dek); the trailing block is
    emitted ONLY when non-empty, so single-recipient stays byte-identical."""
    payload = encode_current(cs, kek_primary, wrapped_primary, sig, pk)
    if additional:
        payload += struct.pack("<H", len(additional))
        for rid, kalg, wd in additional:
            payload += (pack_string(rid, width=2) + pack_string(kalg, width=2)
                        + struct.pack("<I", len(wd)) + wd)
    return payload


def decode_multi(payload):
    """Proposed new decoder: primary (in-band) + optional trailing recipients."""
    off = 0
    cs, off = unpack_string(payload, off, width=2)
    kek, off = unpack_string(payload, off, width=2)
    (wl,) = struct.unpack_from("<I", payload, off); off += 4
    wrapped = bytes(payload[off:off + wl]); off += wl
    sig, off = unpack_string(payload, off, width=2)
    (pl,) = struct.unpack_from("<I", payload, off); off += 4
    pk = bytes(payload[off:off + pl]); off += pl
    recipients = [("", kek, wrapped)]            # primary; id "" by convention
    if off < len(payload):
        (n,) = struct.unpack_from("<H", payload, off); off += 2
        for _ in range(n):
            rid, off = unpack_string(payload, off, width=2)
            kalg, off = unpack_string(payload, off, width=2)
            (wl2,) = struct.unpack_from("<I", payload, off); off += 4
            wd = bytes(payload[off:off + wl2]); off += wl2
            recipients.append((rid, kalg, wd))
    return {"cipher_suite": cs, "signature_algorithm": sig,
            "public_key": pk, "recipients": recipients}


def main() -> int:
    SERVER = b"\x11" * 48
    RESEARCHER = b"\x22" * 1639

    cur = encode_current("aes-256-gcm", "aes-256-gcm", SERVER)
    new1 = encode_multi("aes-256-gcm", "aes-256-gcm", SERVER, additional=[])
    assert cur == new1, "P1: single-recipient not byte-identical"
    print("P1 single-recipient byte-identical to current:", cur == new1)

    multi = encode_multi("aes-256-gcm", "aes-256-gcm", SERVER,
                         additional=[("researcher", "ml-kem-1024", RESEARCHER)])
    got = _decode_protection_metadata(multi)     # the REAL current reader
    assert got["cipher_suite"] == "aes-256-gcm"
    assert got["wrapped_dek"] == SERVER, "P2: primary not recovered"
    print("P2 current reader tolerates trailing + recovers primary:",
          got["wrapped_dek"] == SERVER)

    dN = decode_multi(multi)
    assert len(decode_multi(new1)["recipients"]) == 1
    assert len(dN["recipients"]) == 2
    assert dN["recipients"][0][2] == SERVER
    assert dN["recipients"][1] == ("researcher", "ml-kem-1024", RESEARCHER)
    print("P3 new decoder recovers", len(dN["recipients"]), "recipients")

    assert _decode_protection_metadata(cur)["wrapped_dek"] == SERVER
    print("P4 current packet still decodes: True")
    print("ALL PROOFS PASS")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
