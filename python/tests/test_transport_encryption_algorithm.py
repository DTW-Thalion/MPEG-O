"""v0.11 Task 2.4 (transport-spec §4.23): exercise the
``ENCRYPTION_ALGORITHM`` (0x1B) packet on
:class:`TransportWriter` + :class:`TransportReader`.

Wire layout per §4.23::

    algorithm_length:  uint16
    algorithm_utf8:    bytes[algorithm_length]

All multi-byte integers are LITTLE-ENDIAN (spec §1.7).

Python parity for Java's ``TransportEncryptionAlgorithmTest`` (commit
``530a5833``).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import io
import struct
from pathlib import Path

from ttio.spectral_dataset import SpectralDataset
from ttio.transport.codec import TransportReader, TransportWriter
from ttio.transport.packets import PacketType, TRANSPORT_V0_11_FEATURE


def test_write_encryption_algorithm_emits_single_0x1B_packet() -> None:
    """Writer's low-level helper emits a single 0x1B packet whose
    payload matches §4.23 exactly."""
    out = io.BytesIO()
    with TransportWriter(out) as w:
        w.write_stream_header(
            format_version="1.2",
            title="enc-test",
            isa_investigation="isa",
            features=[],
            n_datasets=0,
        )
        w.write_encryption_algorithm("aes-256-gcm")
        w.write_end_of_stream()

    r = TransportReader(io.BytesIO(out.getvalue()))
    records = r.records_for_test()
    assert len(records) == 3, (
        f"expected StreamHeader + EncryptionAlgorithm + EndOfStream, "
        f"got {len(records)}"
    )
    assert records[1].header.packet_type == int(
        PacketType.ENCRYPTION_ALGORITHM
    )

    payload = records[1].payload
    (length,) = struct.unpack_from("<H", payload, 0)
    assert length == len(b"aes-256-gcm")
    algo = payload[2:2 + length].decode("utf-8")
    assert algo == "aes-256-gcm"
    assert 2 + length == len(payload), (
        "payload must contain only length + algorithm bytes"
    )


def test_write_dataset_emits_encryption_algorithm_when_encrypted(
    tmp_path: Path,
) -> None:
    """``write_dataset`` on an encrypted ``.tio`` emits exactly one
    ENCRYPTION_ALGORITHM packet (in the v0.11 prelude, before any
    reference groups per §5.4 ordering) AND sets the v0.11 feature
    flag in the StreamHeader."""
    src = tmp_path / "enc.tio"
    _build_encrypted_algorithm_only(src, "aes-256-gcm")
    tis = tmp_path / "enc.tis"

    with SpectralDataset.open(src) as ds:
        assert ds.is_encrypted, (
            "fixture precondition: dataset must be encrypted"
        )
        assert ds.encrypted_algorithm == "aes-256-gcm"
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    records = r.records_for_test()
    # StreamHeader features must include transport_v0_11.
    sh_payload = records[0].payload
    # Decode the StreamHeader to get its features list.
    from ttio.transport.codec import _decode_stream_header
    sh = _decode_stream_header(sh_payload)
    assert TRANSPORT_V0_11_FEATURE in sh["features"], (
        "StreamHeader must carry transport_v0_11 feature flag"
    )

    enc_count = 0
    for rec in records:
        if rec.header.packet_type == int(PacketType.ENCRYPTION_ALGORITHM):
            enc_count += 1
            (length,) = struct.unpack_from("<H", rec.payload, 0)
            algo = rec.payload[2:2 + length].decode("utf-8")
            assert algo == "aes-256-gcm"
    assert enc_count == 1, (
        f"write_dataset on encrypted .tio must emit exactly one "
        f"ENCRYPTION_ALGORITHM packet, got {enc_count}"
    )


def test_write_dataset_no_packet_when_not_encrypted(tmp_path: Path) -> None:
    """``write_dataset`` on a NON-encrypted ``.tio`` emits NO 0x1B
    packet."""
    src = tmp_path / "plain.tio"
    SpectralDataset.write_minimal(
        src,
        title="plain",
        isa_investigation_id="",
        runs={},
    )
    tis = tmp_path / "plain.tis"
    with SpectralDataset.open(src) as ds:
        assert not ds.is_encrypted, (
            "fixture precondition: dataset must not be encrypted"
        )
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    r = TransportReader(io.BytesIO(tis.read_bytes()))
    for rec in r.records_for_test():
        assert rec.header.packet_type != int(PacketType.ENCRYPTION_ALGORITHM), (
            "non-encrypted dataset must not emit ENCRYPTION_ALGORITHM"
        )


def test_encryption_algorithm_round_trips_via_write_dataset_read_to_dataset(
    tmp_path: Path,
) -> None:
    """End-to-end: writer emits ENCRYPTION_ALGORITHM, reader
    materialises it, the resulting on-disk ``.tio`` reports the same
    algorithm via ``is_encrypted`` + ``encrypted_algorithm``."""
    src = tmp_path / "src.tio"
    _build_encrypted_algorithm_only(src, "aes-256-gcm")
    tis = tmp_path / "src.tis"
    rt = tmp_path / "rt.tio"

    with SpectralDataset.open(src) as ds:
        with tis.open("wb") as out, TransportWriter(out) as w:
            w.write_dataset(ds)

    with TransportReader(io.BytesIO(tis.read_bytes())) as r:
        materialised = r.read_to_dataset(output_path=rt)
        materialised.close()

    with SpectralDataset.open(rt) as b:
        assert b.is_encrypted, (
            "round-tripped dataset must report is_encrypted == True"
        )
        assert b.encrypted_algorithm == "aes-256-gcm", (
            "round-tripped algorithm string must match source"
        )


def _build_encrypted_algorithm_only(target: Path, algorithm: str) -> None:
    """Build a minimal ``.tio`` whose root carries ``@encrypted`` =
    ``algorithm`` via the provider-level attribute setter. Mirrors
    Java's ``buildEncryptedAlgorithmOnly`` in
    ``TransportEncryptionAlgorithmTest``."""
    SpectralDataset.write_minimal(
        target,
        title="encryption_only",
        isa_investigation_id="",
        runs={},
    )
    # Re-open writable and stamp the @encrypted root attribute.
    with SpectralDataset.open(target, writable=True) as ds:
        ds.provider.root_group().set_attribute("encrypted", algorithm)
