"""FD-1 Phase B-1 — multi-recipient envelope client API (Python).

Covers :meth:`WorkbenchClient.upload_encrypted_multi` /
:meth:`download_decrypted_multi`: one per-run DEK wrapped for several
recipients, each of whom independently recovers the *same* plaintext with
its own key. Daemon-free — ``upload_bytes`` / ``download_bytes`` are
replaced with an in-memory store, so this exercises the real crypto +
transport path without a live server (the end-to-end daemon path is the
live smoke's job).
"""
import asyncio
from types import SimpleNamespace

import numpy as np
import pytest

from ttio import pqc as core_pqc
from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.workbench.client import EnvelopeRecipient, WorkbenchClient
from ttio.workbench.pqc import ML_KEM_1024, PQCPreviewDisabledError, kem_keygen

requires_pqc = pytest.mark.skipif(
    not core_pqc.is_available(), reason="liboqs-python not available")

SERVER_KEK = bytes([0x11] * 32)
OTHER_KEK = bytes([0x77] * 32)


def _make_plain_tio(tmp_path):
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
    p = tmp_path / "plain.tio"
    SpectralDataset.write_minimal(
        str(p), title="t", isa_investigation_id="X", runs={"run_0001": run})
    return p


def _fake_client():
    """A WorkbenchClient with an in-memory data plane (no daemon)."""
    client = WorkbenchClient.__new__(WorkbenchClient)
    store: dict[str, bytes] = {}

    async def _upload(*, project, container_uri, data, resume=None):
        store[container_uri] = data
        return SimpleNamespace(container_uri=container_uri)

    async def _download(*, container_uri, filters=None,
                        output_mode=None, max_au=0):
        return SimpleNamespace(payload=store[container_uri])

    client.upload_bytes = _upload
    client.download_bytes = _download
    return client


def _assert_same_values(a, b):
    assert a.keys() == b.keys()
    for run in a:
        assert a[run].keys() == b[run].keys()
        for ch in a[run]:
            np.testing.assert_array_equal(a[run][ch], b[run][ch])


def test_two_symmetric_recipients_round_trip(tmp_path):
    """Two AES-256-GCM recipients; each KEK independently recovers the
    identical plaintext (always runs — no liboqs needed)."""
    src = _make_plain_tio(tmp_path)
    client = _fake_client()
    recipients = [
        EnvelopeRecipient("server", SERVER_KEK, "aes-256-gcm"),
        EnvelopeRecipient("auditor", OTHER_KEK, "aes-256-gcm"),
    ]
    asyncio.run(client.upload_encrypted_multi(
        project="p", container_uri="c", tio_path=str(src),
        recipients=recipients))

    # primary recovered with recipient_id="" (primary id is "" on the wire)
    primary = asyncio.run(client.download_decrypted_multi(
        container_uri="c", key=SERVER_KEK,
        out_tio_path=str(tmp_path / "primary.tio")))
    # additional recovered by its label
    auditor = asyncio.run(client.download_decrypted_multi(
        container_uri="c", key=OTHER_KEK, recipient_id="auditor",
        out_tio_path=str(tmp_path / "auditor.tio")))

    _assert_same_values(primary, auditor)
    assert "run_0001" in primary


@requires_pqc
def test_server_kek_plus_researcher_mlkem_round_trip(tmp_path):
    """The FD-1 output shape: primary = server symmetric KEK, additional =
    researcher ML-KEM-1024. Both recover the same plaintext, the daemon
    holds no key."""
    src = _make_plain_tio(tmp_path)
    kp = kem_keygen()
    client = _fake_client()
    recipients = [
        EnvelopeRecipient("server", SERVER_KEK, "aes-256-gcm"),
        EnvelopeRecipient("researcher", kp.public_key, ML_KEM_1024),
    ]
    asyncio.run(client.upload_encrypted_multi(
        project="p", container_uri="c", tio_path=str(src),
        recipients=recipients, preview=True))

    server = asyncio.run(client.download_decrypted_multi(
        container_uri="c", key=SERVER_KEK,
        out_tio_path=str(tmp_path / "server.tio")))
    researcher = asyncio.run(client.download_decrypted_multi(
        container_uri="c", key=kp.private_key, recipient_id="researcher",
        preview=True, out_tio_path=str(tmp_path / "researcher.tio")))

    _assert_same_values(server, researcher)


def test_empty_recipients_rejected(tmp_path):
    src = _make_plain_tio(tmp_path)
    client = _fake_client()
    with pytest.raises(ValueError, match="requires >= 1 recipient"):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="c", tio_path=str(src), recipients=[]))


def test_duplicate_or_empty_additional_ids_rejected(tmp_path):
    src = _make_plain_tio(tmp_path)
    client = _fake_client()
    dup = [
        EnvelopeRecipient("server", SERVER_KEK, "aes-256-gcm"),
        EnvelopeRecipient("dupe", OTHER_KEK, "aes-256-gcm"),
        EnvelopeRecipient("dupe", OTHER_KEK, "aes-256-gcm"),
    ]
    with pytest.raises(ValueError, match="unique and non-empty"):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="c", tio_path=str(src), recipients=dup))


@requires_pqc
def test_mlkem_recipient_requires_preview(tmp_path):
    src = _make_plain_tio(tmp_path)
    kp = kem_keygen()
    client = _fake_client()
    recipients = [
        EnvelopeRecipient("server", SERVER_KEK, "aes-256-gcm"),
        EnvelopeRecipient("researcher", kp.public_key, ML_KEM_1024),
    ]
    with pytest.raises(PQCPreviewDisabledError):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="c", tio_path=str(src),
            recipients=recipients))  # preview defaults to False


def test_unknown_recipient_id_rejected(tmp_path):
    src = _make_plain_tio(tmp_path)
    client = _fake_client()
    asyncio.run(client.upload_encrypted_multi(
        project="p", container_uri="c", tio_path=str(src),
        recipients=[EnvelopeRecipient("server", SERVER_KEK, "aes-256-gcm")]))
    with pytest.raises(ValueError, match="no recipient with id"):
        asyncio.run(client.download_decrypted_multi(
            container_uri="c", key=SERVER_KEK, recipient_id="nobody",
            out_tio_path=str(tmp_path / "x.tio")))
