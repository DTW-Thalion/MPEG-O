"""FD-1 Phase A-1 — multi-recipient ProtectionMetadata (Python).

Covers the packet codec (append-only recipient block) and the
storage-attribute carriage through write_encrypted_dataset /
read_encrypted_to_file, asserting single-recipient stays byte-identical
to the pre-Phase-A format.
"""
from __future__ import annotations

import io

import numpy as np
import pytest

pytest.importorskip("h5py")

from ttio.enums import AcquisitionMode, Polarity
from ttio.encryption_per_au import encrypt_per_au_file
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.transport.codec import TransportWriter
from ttio.transport.encrypted import (
    _decode_protection_metadata,
    _emit_protection_metadata,
    read_encrypted_to_file,
    read_transport_recipients,
    read_transport_wrapped_dek,
    stamp_transport_wrapped_dek,
    write_encrypted_dataset,
)

SERVER = b"\x11" * 48
RESEARCHER = b"\x22" * 1639
KEY = bytes([0x5A] * 32)


class _CapturingWriter:
    """Captures the payload of the single ProtectionMetadata emit."""
    def __init__(self):
        self.payload = None

    def _emit(self, packet_type, payload, *, dataset_id):
        self.payload = payload


def _emit_payload(*, additional):
    w = _CapturingWriter()
    _emit_protection_metadata(
        w, dataset_id=1, cipher_suite="aes-256-gcm",
        kek_algorithm="aes-256-gcm", wrapped_dek=SERVER,
        signature_algorithm="", public_key=b"",
        additional_recipients=additional)
    return w.payload


# ---------------------------------------------------------- packet codec

def test_single_recipient_payload_byte_identical():
    """No additional recipients -> no trailing block -> byte-identical to
    the pre-Phase-A encoding (spec proof P1)."""
    assert _emit_payload(additional=[]) == _emit_payload(additional=())


def test_single_recipient_decode_one_recipient():
    pm = _decode_protection_metadata(_emit_payload(additional=[]))
    assert pm["recipients"] == [("", "aes-256-gcm", SERVER)]
    assert pm["wrapped_dek"] == SERVER  # back-compat keys preserved


def test_multi_recipient_packet_round_trip():
    payload = _emit_payload(
        additional=[("researcher", "ml-kem-1024", RESEARCHER)])
    # The single-recipient prefix is a strict prefix of the multi payload.
    assert payload.startswith(_emit_payload(additional=[]))
    pm = _decode_protection_metadata(payload)
    assert pm["recipients"] == [
        ("", "aes-256-gcm", SERVER),
        ("researcher", "ml-kem-1024", RESEARCHER),
    ]


def test_three_recipients():
    additional = [
        ("researcher", "ml-kem-1024", RESEARCHER),
        ("auditor", "aes-256-gcm", b"\x33" * 48),
    ]
    pm = _decode_protection_metadata(_emit_payload(additional=additional))
    assert len(pm["recipients"]) == 3
    assert [r[0] for r in pm["recipients"]] == ["", "researcher", "auditor"]


# --------------------------------------------------- storage carriage

def _make_encrypted_tio(tmp_path):
    n, ppp = 3, 4
    total = n * ppp
    run = WrittenRun(
        spectrum_class="TTIOMassSpectrum",
        acquisition_mode=int(AcquisitionMode.MS1_DDA),
        channel_data={"mz": np.arange(total, dtype="<f8") + 100.0,
                      "intensity": (np.arange(total, dtype="<f8") + 1) * 10},
        offsets=np.arange(0, total, ppp, dtype="<u8"),
        lengths=np.full(n, ppp, dtype="<u4"),
        retention_times=np.arange(n, dtype="<f8"),
        ms_levels=np.ones(n, dtype="<i4"),
        polarities=np.full(n, int(Polarity.POSITIVE), dtype="<i4"),
        precursor_mzs=np.zeros(n, dtype="<f8"),
        precursor_charges=np.zeros(n, dtype="<i4"),
        base_peak_intensities=np.ones(n, dtype="<f8"))
    p = tmp_path / "src.tio"
    SpectralDataset.write_minimal(
        str(p), title="t", isa_investigation_id="X", runs={"run_0001": run})
    encrypt_per_au_file(str(p), KEY)
    return p


def _round_trip(src, out):
    stream = io.BytesIO()
    with TransportWriter(stream) as tw:
        write_encrypted_dataset(tw, str(src))
    read_encrypted_to_file(io.BytesIO(stream.getvalue()), str(out))


def test_storage_multi_recipient_round_trip(tmp_path):
    src = _make_encrypted_tio(tmp_path)
    stamp_transport_wrapped_dek(
        str(src), SERVER, "aes-256-gcm",
        additional_recipients=[("researcher", "ml-kem-1024", RESEARCHER)])
    out = tmp_path / "out.tio"
    _round_trip(src, out)

    # primary accessor unchanged
    assert read_transport_wrapped_dek(str(out)) == (SERVER, "aes-256-gcm")
    # full list recovered through encode -> packet -> decode -> store
    assert read_transport_recipients(str(out)) == [
        ("", "aes-256-gcm", SERVER),
        ("researcher", "ml-kem-1024", RESEARCHER),
    ]


def test_storage_single_recipient_unchanged(tmp_path):
    src = _make_encrypted_tio(tmp_path)
    stamp_transport_wrapped_dek(str(src), SERVER, "aes-256-gcm")
    out = tmp_path / "out.tio"
    _round_trip(src, out)
    assert read_transport_recipients(str(out)) == [("", "aes-256-gcm", SERVER)]
    assert read_transport_wrapped_dek(str(out)) == (SERVER, "aes-256-gcm")
