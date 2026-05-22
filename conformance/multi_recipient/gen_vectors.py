#!/usr/bin/env python3
"""Generate the FD-1 Phase A multi-recipient ProtectionMetadata golden
vectors from the Python reference encoder.

Run from the repo root:
    python conformance/multi_recipient/gen_vectors.py

Writes ``conformance/multi_recipient/vectors.json``. The committed JSON is
the cross-language byte contract: Python / Java / ObjC conformance tests
each encode the inputs and assert the bytes equal the golden hex here.

Do NOT hand-edit ``vectors.json``; re-run this generator and review the
diff. A change to the golden bytes is a wire-format change and must be
justified against the Phase A spec.
"""
from __future__ import annotations

import json
from pathlib import Path

from ttio.transport.encrypted import (
    _encode_protection_trailing,
    _encode_recipient_block,
    _emit_protection_metadata,
)


class _CapturingWriter:
    def __init__(self):
        self.payload = None

    def _emit(self, packet_type, payload, *, dataset_id):
        self.payload = payload


def _body(cipher_suite, kek_algorithm, wrapped_dek, additional,
          server_kek_id=None):
    w = _CapturingWriter()
    _emit_protection_metadata(
        w, dataset_id=1, cipher_suite=cipher_suite,
        kek_algorithm=kek_algorithm, wrapped_dek=wrapped_dek,
        signature_algorithm="", public_key=b"",
        additional_recipients=additional, server_kek_id=server_kek_id)
    return w.payload


def _fill(spec):
    """{'fill': '0x11', 'len': 48} -> bytes."""
    return bytes([int(spec["fill"], 16)]) * spec["len"]


# ── Vector definitions (§6 of the Phase A spec) ──────────────────────
# wrapped DEKs are given as {fill,len} so the JSON stays compact; each
# language reconstructs the same bytes. signature_algorithm / public_key
# are empty in every vector (Java/ObjC always emit empty here), so the
# full body is reproducible byte-identically in all three languages.

SERVER = {"fill": "0x11", "len": 48}        # AES-wrapped DEK
RESEARCHER = {"fill": "0x22", "len": 1568}  # ml-kem-1024 ciphertext size
AUDITOR = {"fill": "0x44", "len": 512}      # rsa-4096-oaep size
PQC = {"fill": "0x33", "len": 1568}

VECTORS = [
    {
        "name": "prot_single_byok",
        "description": "1 recipient, empty wrapped DEK (BYOK). No trailing "
                       "block; byte-identical to transport-spec §4.4.",
        "cipher_suite": "aes-256-gcm",
        "kek_algorithm": "none",
        "wrapped_dek": {"fill": "0x00", "len": 0},
        "additional_recipients": [],
    },
    {
        "name": "prot_single_envelope",
        "description": "1 recipient, aes-256-gcm wrapped DEK (server-KEK "
                       "envelope). No trailing block.",
        "cipher_suite": "aes-256-gcm",
        "kek_algorithm": "aes-256-gcm",
        "wrapped_dek": SERVER,
        "additional_recipients": [],
    },
    {
        "name": "prot_single_pqc",
        "description": "1 recipient, ml-kem-1024 wrapped DEK (BYOK/PQC). No "
                       "trailing block.",
        "cipher_suite": "aes-256-gcm",
        "kek_algorithm": "ml-kem-1024",
        "wrapped_dek": PQC,
        "additional_recipients": [],
    },
    {
        "name": "prot_multi_server_researcher",
        "description": "2 recipients: primary = server aes-256-gcm KEK; "
                       "additional[0] = researcher ml-kem-1024 (FD-1 output).",
        "cipher_suite": "aes-256-gcm",
        "kek_algorithm": "aes-256-gcm",
        "wrapped_dek": SERVER,
        "additional_recipients": [
            {"recipient_id": "researcher", "kek_algorithm": "ml-kem-1024",
             "wrapped_dek": RESEARCHER},
        ],
    },
    {
        "name": "prot_multi_three",
        "description": "3 recipients, mixed algorithms, to exercise the loop.",
        "cipher_suite": "aes-256-gcm",
        "kek_algorithm": "aes-256-gcm",
        "wrapped_dek": SERVER,
        "additional_recipients": [
            {"recipient_id": "researcher", "kek_algorithm": "ml-kem-1024",
             "wrapped_dek": RESEARCHER},
            {"recipient_id": "auditor", "kek_algorithm": "rsa-4096-oaep",
             "wrapped_dek": AUDITOR},
        ],
    },
    {
        "name": "prot_server_kek_id_single",
        "description": "FD-1 C-2a: single-recipient server-processable. No "
                       "additional recipients, so the trailing section is "
                       "count=0 + server_kek_id.",
        "cipher_suite": "aes-256-gcm",
        "kek_algorithm": "aes-256-gcm",
        "wrapped_dek": SERVER,
        "additional_recipients": [],
        "server_kek_id": "server:kek-proj-adni",
    },
    {
        "name": "prot_server_kek_id_multi",
        "description": "FD-1 C-2a: server-processable + a researcher "
                       "recipient. Trailing = recipient block + server_kek_id.",
        "cipher_suite": "aes-256-gcm",
        "kek_algorithm": "aes-256-gcm",
        "wrapped_dek": SERVER,
        "additional_recipients": [
            {"recipient_id": "researcher", "kek_algorithm": "ml-kem-1024",
             "wrapped_dek": RESEARCHER},
        ],
        "server_kek_id": "server:kek-proj-adni",
    },
]


def main():
    out_vectors = []
    for v in VECTORS:
        additional = [
            (r["recipient_id"], r["kek_algorithm"], _fill(r["wrapped_dek"]))
            for r in v["additional_recipients"]
        ]
        server_kek_id = v.get("server_kek_id")
        body = _body(v["cipher_suite"], v["kek_algorithm"],
                     _fill(v["wrapped_dek"]), additional, server_kek_id)
        block = _encode_recipient_block(additional)
        # The full trailing section after the five §4.4 fields (recipient
        # block + optional server_kek_id) -- the unit ObjC pins.
        trailing = _encode_protection_trailing(additional, server_kek_id)
        out_vectors.append({
            "name": v["name"],
            "description": v["description"],
            "cipher_suite": v["cipher_suite"],
            "kek_algorithm": v["kek_algorithm"],
            "wrapped_dek": v["wrapped_dek"],
            "signature_algorithm": "",
            "public_key": {"fill": "0x00", "len": 0},
            "additional_recipients": v["additional_recipients"],
            "server_kek_id": server_kek_id,
            "recipient_block_hex": block.hex(),
            "trailing_hex": trailing.hex(),
            "body_hex": body.hex(),
        })

    # Pre-Phase-A primary recovery (spec §4 P2, §6 (d)): an un-upgraded
    # reader of the 2-recipient vector parses only the five §4.4 fields and
    # recovers the primary recipient. Frozen here so all languages assert a
    # legacy reader still works against a real multi-recipient packet.
    pre = next(v for v in out_vectors
               if v["name"] == "prot_multi_server_researcher")
    doc = {
        "_comment": "FD-1 Phase A multi-recipient ProtectionMetadata golden "
                    "vectors. Generated by gen_vectors.py from the Python "
                    "reference encoder. Do not hand-edit. The recipient_block "
                    "and full body hex are the cross-language byte contract "
                    "(Python == Java == ObjC).",
        "spec": "docs/superpowers/specs/"
                "2026-05-21-fd1-phase-a-multi-recipient-protection-metadata-"
                "spec.md",
        "vectors": out_vectors,
        "pre_phase_a_primary": {
            "_comment": "An un-upgraded (pre-Phase-A) reader of "
                        "prot_multi_server_researcher recovers exactly this "
                        "primary recipient and ignores the trailing block.",
            "from_vector": pre["name"],
            "primary_kek_algorithm": pre["kek_algorithm"],
            "primary_wrapped_dek": pre["wrapped_dek"],
        },
    }
    out_path = Path(__file__).resolve().parent / "vectors.json"
    out_path.write_text(json.dumps(doc, indent=2) + "\n")
    print(f"wrote {out_path} ({len(out_vectors)} vectors)")


if __name__ == "__main__":
    main()
