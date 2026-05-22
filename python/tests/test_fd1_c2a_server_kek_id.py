"""FD-1 Phase C-2a — server_kek_id in ProtectionMetadata (Python).

Spec + proof: docs/superpowers/specs/2026-05-22-fd1-c2a-server-kek-id-spec.md.

Covers the append-only server_kek_id field: packet byte-identity when
absent, round-trip when present (with and without additional recipients),
and storage carriage through stamp -> write -> read.
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
    read_transport_server_kek_id,
    stamp_transport_wrapped_dek,
    write_encrypted_dataset,
)

SERVER = b"\x11" * 48
RESEARCHER = b"\x22" * 1568
KEY = bytes([0x5A] * 32)
KID = "server:kek-proj-adni"


class _CapturingWriter:
    def __init__(self):
        self.payload = None

    def _emit(self, packet_type, payload, *, dataset_id):
        self.payload = payload


def _emit_payload(*, additional=(), server_kek_id=None):
    w = _CapturingWriter()
    _emit_protection_metadata(
        w, dataset_id=1, cipher_suite="aes-256-gcm",
        kek_algorithm="aes-256-gcm", wrapped_dek=SERVER,
        signature_algorithm="", public_key=b"",
        additional_recipients=additional, server_kek_id=server_kek_id)
    return w.payload


# ---------------------------------------------------------- packet codec

def test_absent_server_kek_id_byte_identical():
    # No additional, no server_kek_id => identical to the pre-C-2a packet.
    assert _emit_payload() == _emit_payload(additional=(), server_kek_id=None)
    # And the decoder reports None.
    pm = _decode_protection_metadata(_emit_payload())
    assert pm["server_kek_id"] is None
    assert pm["recipients"] == [("", "aes-256-gcm", SERVER)]


def test_server_kek_id_round_trip_single_recipient():
    # count=0 + server_kek_id for a single-recipient server-processable run.
    payload = _emit_payload(server_kek_id=KID)
    pm = _decode_protection_metadata(payload)
    assert pm["server_kek_id"] == KID
    assert pm["recipients"] == [("", "aes-256-gcm", SERVER)]


def test_server_kek_id_round_trip_with_additional():
    additional = [("researcher", "ml-kem-1024", RESEARCHER)]
    payload = _emit_payload(additional=additional, server_kek_id=KID)
    pm = _decode_protection_metadata(payload)
    assert pm["server_kek_id"] == KID
    assert pm["recipients"] == [
        ("", "aes-256-gcm", SERVER),
        ("researcher", "ml-kem-1024", RESEARCHER),
    ]


def test_additional_without_server_kek_id_unchanged():
    additional = [("researcher", "ml-kem-1024", RESEARCHER)]
    pm = _decode_protection_metadata(_emit_payload(additional=additional))
    assert pm["server_kek_id"] is None
    assert pm["recipients"][1] == ("researcher", "ml-kem-1024", RESEARCHER)


# ---------------------------------------------------------- storage carriage

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


def test_storage_server_kek_id_round_trip(tmp_path):
    src = _make_encrypted_tio(tmp_path)
    stamp_transport_wrapped_dek(str(src), SERVER, "aes-256-gcm",
                                server_kek_id=KID)
    out = tmp_path / "out.tio"
    _round_trip(src, out)
    assert read_transport_server_kek_id(str(out)) == KID


def test_storage_byok_has_no_server_kek_id(tmp_path):
    src = _make_encrypted_tio(tmp_path)
    stamp_transport_wrapped_dek(str(src), SERVER, "aes-256-gcm")
    out = tmp_path / "out.tio"
    _round_trip(src, out)
    assert read_transport_server_kek_id(str(out)) is None
