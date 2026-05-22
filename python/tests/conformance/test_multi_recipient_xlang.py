"""Cross-language conformance for the FD-1 Phase A multi-recipient
``ProtectionMetadata`` wire format (spec §6, Phase A-4).

The golden byte vectors live in ``conformance/multi_recipient/vectors.json``
and are asserted byte-equal by the Python, Java, and ObjC suites. This is
the Python side: it pins the full coverage (it is the reference encoder the
vectors were generated from), so a regression here means the golden file is
stale or the encoder drifted.

Because every language asserts against the *same* committed hex, byte-parity
across Python / Java / ObjC is transitive (all three == golden ⇒ all equal).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import json
from pathlib import Path

import pytest

from ttio.transport.encrypted import (
    _decode_protection_metadata,
    _decode_recipient_block,
    _emit_protection_metadata,
    _encode_recipient_block,
)
from ttio.transport.packets import unpack_string

_REPO = Path(__file__).resolve().parents[3]
_VECTORS = _REPO / "conformance" / "multi_recipient" / "vectors.json"


def _fill(spec: dict) -> bytes:
    return bytes([int(spec["fill"], 16)]) * spec["len"]


def _load() -> dict:
    return json.loads(_VECTORS.read_text())


def _additional(vector: dict) -> "list[tuple[str, str, bytes]]":
    return [
        (r["recipient_id"], r["kek_algorithm"], _fill(r["wrapped_dek"]))
        for r in vector["additional_recipients"]
    ]


class _CapturingWriter:
    def __init__(self):
        self.payload = None

    def _emit(self, packet_type, payload, *, dataset_id):
        self.payload = payload


def _emit_body(vector: dict) -> bytes:
    w = _CapturingWriter()
    _emit_protection_metadata(
        w, dataset_id=1, cipher_suite=vector["cipher_suite"],
        kek_algorithm=vector["kek_algorithm"],
        wrapped_dek=_fill(vector["wrapped_dek"]),
        signature_algorithm=vector["signature_algorithm"],
        public_key=_fill(vector["public_key"]),
        additional_recipients=_additional(vector))
    return w.payload


_DOC = _load()
_VECTOR_IDS = [v["name"] for v in _DOC["vectors"]]


@pytest.fixture(params=_DOC["vectors"], ids=_VECTOR_IDS)
def vector(request):
    return request.param


def test_recipient_block_encodes_to_golden(vector):
    """encode(additional) == recipient_block_hex (the cross-lang contract)."""
    block = _encode_recipient_block(_additional(vector))
    assert block.hex() == vector["recipient_block_hex"]


def test_recipient_block_round_trips(vector):
    """decode∘encode = id on the trailing block."""
    additional = _additional(vector)
    block = bytes.fromhex(vector["recipient_block_hex"])
    if not block:
        assert additional == []
        return
    decoded, off = _decode_recipient_block(block, 0)
    assert off == len(block)
    assert decoded == additional


def test_full_body_encodes_to_golden(vector):
    """The complete protection-metadata body equals body_hex (§4.4 primary
    fields + the optional trailing block)."""
    assert _emit_body(vector).hex() == vector["body_hex"]


def test_full_body_decodes_to_recipient_list(vector):
    """Decoding body_hex recovers the primary (index 0) plus every
    additional recipient with id / kek / wrapped DEK."""
    body = bytes.fromhex(vector["body_hex"])
    pm = _decode_protection_metadata(body)
    recipients = pm["recipients"]
    # primary
    assert recipients[0][0] == ""  # primary recipient_id is the empty string
    assert recipients[0][1] == vector["kek_algorithm"]
    assert recipients[0][2] == _fill(vector["wrapped_dek"])
    # additional
    assert recipients[1:] == _additional(vector)


def test_single_recipient_emits_no_trailing_block(vector):
    """The §6 single-recipient vectors MUST NOT carry a trailing block, so
    they stay byte-identical to transport-spec §4.4."""
    if vector["additional_recipients"]:
        pytest.skip("multi-recipient vector")
    assert vector["recipient_block_hex"] == ""


def test_pre_phase_a_reader_recovers_primary():
    """An un-upgraded (pre-Phase-A) reader parses only the five §4.4 fields
    and recovers the primary recipient from a real multi-recipient packet,
    ignoring the trailing block (spec §4 P2 / §6 (d))."""
    pre = _DOC["pre_phase_a_primary"]
    vector = next(v for v in _DOC["vectors"] if v["name"] == pre["from_vector"])
    body = bytes.fromhex(vector["body_hex"])

    # Replay the pre-Phase-A field walk: cipher_suite, kek, wrapped_dek,
    # signature_algorithm, public_key — then stop (trailing block ignored).
    off = 0
    _cipher_suite, off = unpack_string(body, off, width=2)
    kek_algorithm, off = unpack_string(body, off, width=2)
    import struct
    (wl,) = struct.unpack_from("<I", body, off)
    off += 4
    wrapped = bytes(body[off:off + wl])

    assert kek_algorithm == pre["primary_kek_algorithm"]
    assert wrapped == _fill(pre["primary_wrapped_dek"])
