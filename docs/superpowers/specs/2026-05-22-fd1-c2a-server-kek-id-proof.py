#!/usr/bin/env python3
"""Executable spec-proof for FD-1 Phase C-2a — server_kek_id in
ProtectionMetadata.

Demonstrates, against the *real* current decoder
(`ttio.transport.encrypted._decode_protection_metadata` +
`_decode_recipient_block`), that appending an optional `server_kek_id`
field after the Phase A recipient block is backward-compatible:

  P1  a packet with NO additional recipients and NO server_kek_id is
      byte-identical to today's §4.4 single-recipient payload.
  P2  the current reader parses a packet that DOES carry server_kek_id
      (with or without additional recipients) without error and recovers
      the primary (+ any additional) recipient -- it ignores the trailing
      server_kek_id field.
  P3  the proposed C-2a decoder recovers server_kek_id and all recipients.
  P4  regression: today's §4.4 and Phase A multi-recipient packets still
      decode under both the current reader and the C-2a decoder (which
      reports server_kek_id = None for them).

Run: python3 docs/superpowers/specs/2026-05-22-fd1-c2a-server-kek-id-proof.py
(requires an editable ttio install). Exits non-zero on any failed proof.
"""
import struct
import sys

from ttio.transport.packets import pack_string, unpack_string
from ttio.transport.encrypted import (
    _decode_protection_metadata,
    _decode_recipient_block,
)


# ── encoders ─────────────────────────────────────────────────────────

def encode_current(cs, kek, wrapped, sig="", pk=b""):
    """Today's §4.4 single-recipient payload."""
    return (pack_string(cs, width=2) + pack_string(kek, width=2)
            + struct.pack("<I", len(wrapped)) + wrapped
            + pack_string(sig, width=2) + struct.pack("<I", len(pk)) + pk)


def encode_phasea_multi(cs, kek, wrapped, additional, sig="", pk=b""):
    """Phase A: append a recipient block ONLY when there are additional
    recipients (single-recipient stays byte-identical to §4.4)."""
    payload = encode_current(cs, kek, wrapped, sig, pk)
    if additional:
        payload += struct.pack("<H", len(additional))
        for rid, kalg, wd in additional:
            payload += (pack_string(rid, width=2) + pack_string(kalg, width=2)
                        + struct.pack("<I", len(wd)) + wd)
    return payload


def encode_c2a(cs, kek, wrapped, additional, server_kek_id=None,
               sig="", pk=b""):
    """Phase C-2a: the trailing section is emitted iff there are additional
    recipients OR a server_kek_id. Layout after the five §4.4 fields:

        additional_recipient_count  u16
        <count> recipient entries
        [ server_kek_id  u16 len + UTF-8 ]   # iff present

    server_kek_id presence is detected on read by "bytes remain after the
    recipient block". A single-recipient server-processable container thus
    emits count=0 + server_kek_id (Phase A readers MAY tolerate count=0)."""
    payload = encode_current(cs, kek, wrapped, sig, pk)
    if additional or server_kek_id:
        payload += struct.pack("<H", len(additional))
        for rid, kalg, wd in additional:
            payload += (pack_string(rid, width=2) + pack_string(kalg, width=2)
                        + struct.pack("<I", len(wd)) + wd)
        if server_kek_id:
            payload += pack_string(server_kek_id, width=2)
    return payload


# ── proposed C-2a decoder (what the impl will do) ────────────────────

def decode_c2a(payload):
    """Decode the five §4.4 fields, the optional Phase A recipient block,
    then the optional trailing server_kek_id."""
    off = 0
    cs, off = unpack_string(payload, off, width=2)
    kek, off = unpack_string(payload, off, width=2)
    (wl,) = struct.unpack_from("<I", payload, off); off += 4
    wrapped = bytes(payload[off:off + wl]); off += wl
    sig, off = unpack_string(payload, off, width=2)
    (pkl,) = struct.unpack_from("<I", payload, off); off += 4
    off += pkl  # public_key
    recipients = [("", kek, wrapped)]
    server_kek_id = None
    if off < len(payload):
        extra, off = _decode_recipient_block(payload, off)
        recipients.extend(extra)
        if off < len(payload):
            server_kek_id, off = unpack_string(payload, off, width=2)
    return {"recipients": recipients, "server_kek_id": server_kek_id}


# ── proofs ───────────────────────────────────────────────────────────

CS, KEK = "aes-256-gcm", "aes-256-gcm"
SERVER = b"\x11" * 48
RESEARCHER = b"\x22" * 1568
KID = "server:kek-proj-adni"


def check(name, ok):
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}")
    return ok


def main():
    ok = True

    # P1 — no additional, no server_kek_id => byte-identical to §4.4.
    p_byok = encode_c2a(CS, "none", b"", [], None)
    ok &= check("P1 single/BYOK (no server_kek_id) is byte-identical to §4.4",
                p_byok == encode_current(CS, "none", b""))

    # P2 — current reader tolerates server_kek_id (single-recipient case:
    # count=0 + server_kek_id) and recovers the primary.
    p_single_kid = encode_c2a(CS, KEK, SERVER, [], KID)
    pm = _decode_protection_metadata(p_single_kid)
    ok &= check("P2a current reader recovers primary from a server_kek_id "
                "packet (count=0 trailing)",
                pm["recipients"] == [("", KEK, SERVER)])

    # P2 — current reader tolerates server_kek_id alongside additional
    # recipients, recovering primary + additional, ignoring server_kek_id.
    p_multi_kid = encode_c2a(CS, KEK, SERVER,
                             [("researcher", "ml-kem-1024", RESEARCHER)], KID)
    pm = _decode_protection_metadata(p_multi_kid)
    ok &= check("P2b current reader recovers primary + additional from a "
                "server_kek_id packet",
                pm["recipients"] == [("", KEK, SERVER),
                                     ("researcher", "ml-kem-1024", RESEARCHER)])

    # P3 — C-2a decoder recovers server_kek_id + all recipients.
    d = decode_c2a(p_single_kid)
    ok &= check("P3a C-2a decoder recovers server_kek_id (single recipient)",
                d["server_kek_id"] == KID
                and d["recipients"] == [("", KEK, SERVER)])
    d = decode_c2a(p_multi_kid)
    ok &= check("P3b C-2a decoder recovers server_kek_id + additional",
                d["server_kek_id"] == KID
                and d["recipients"] == [("", KEK, SERVER),
                                        ("researcher", "ml-kem-1024", RESEARCHER)])

    # P4 — regression: §4.4 and Phase A packets decode; C-2a decoder reports
    # server_kek_id None for them.
    p_phasea = encode_phasea_multi(CS, KEK, SERVER,
                                   [("researcher", "ml-kem-1024", RESEARCHER)])
    pm = _decode_protection_metadata(p_phasea)
    d = decode_c2a(p_phasea)
    ok &= check("P4a Phase A multi packet decodes; C-2a server_kek_id is None",
                pm["recipients"] == [("", KEK, SERVER),
                                     ("researcher", "ml-kem-1024", RESEARCHER)]
                and d["server_kek_id"] is None)
    d = decode_c2a(encode_current(CS, "none", b""))
    ok &= check("P4b §4.4 BYOK packet: C-2a server_kek_id is None",
                d["server_kek_id"] is None and d["recipients"] == [("", "none", b"")])

    print("\nC-2a spec-proof:", "ALL PASS" if ok else "FAILED")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
