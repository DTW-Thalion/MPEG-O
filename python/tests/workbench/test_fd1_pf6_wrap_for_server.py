"""FD-1 PF-6 -- wrap-for-server client SDK (Python).

Covers :meth:`WorkbenchClient.wrap_for_server` and the
:class:`ServerRecipient` integration into
:meth:`WorkbenchClient.upload_encrypted_multi`.

The daemon's `/v1/key-custody/wrap-for-server` endpoint (implemented
in tti-workbench-server PR #77, FD-1-PF-4) is stubbed via the
``http_json`` injection pattern so no live server is required.
"""
from __future__ import annotations

import asyncio
import base64
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np
import pytest

from ttio.enums import AcquisitionMode, Polarity
from ttio.spectral_dataset import SpectralDataset, WrittenRun
from ttio.workbench._http import WorkbenchHttpError
from ttio.workbench.client import (
    EnvelopeRecipient,
    ServerRecipient,
    WorkbenchClient,
)


# ------------------------------------------------------------------ fixtures

KNOWN_WRAPPED = bytes([0xAB] * 48)
SERVER_KEK_ID = "server:kek-proj-adni"
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
    """WorkbenchClient with in-memory data plane; no live daemon."""
    client = WorkbenchClient.__new__(WorkbenchClient)
    from ttio.workbench.client import _Endpoint
    client._endpoint = _Endpoint(
        host="localhost", port=8443, ws_scheme="ws", http_scheme="http")
    client._session = SimpleNamespace(token="test-token")
    client._auth = None
    store: dict = {}

    async def _upload(*, project, container_uri, data, resume=None):
        store[container_uri] = data
        return SimpleNamespace(container_uri=container_uri)

    async def _download(*, container_uri, filters=None,
                        output_mode=None, max_au=0):
        return SimpleNamespace(payload=store[container_uri])

    client.upload_bytes = _upload
    client.download_bytes = _download
    client._store = store
    return client


def _wrap_ok_response():
    return (200, {"wrapped_dek": base64.b64encode(KNOWN_WRAPPED).decode("ascii")})


# ------------------------------------------------------------------ wrap_for_server


def test_wrap_for_server_happy_path():
    """Happy path: stubbed 200 response; method returns the decoded bytes."""
    client = _fake_client()
    dek = bytes(range(32))

    with patch("ttio.workbench._http.http_json",
               return_value=_wrap_ok_response()):
        result = asyncio.run(
            client.wrap_for_server(dek=dek, kek_id=SERVER_KEK_ID))

    assert result == KNOWN_WRAPPED
    assert isinstance(result, bytes)


def test_wrap_for_server_invalid_dek_length():
    """Non-32-byte DEK must raise ValueError before any network call."""
    client = _fake_client()

    with pytest.raises(ValueError, match="DEK must be 32 bytes"):
        asyncio.run(client.wrap_for_server(
            dek=bytes(16), kek_id=SERVER_KEK_ID))

    with pytest.raises(ValueError, match="DEK must be 32 bytes"):
        asyncio.run(client.wrap_for_server(dek=b"", kek_id=SERVER_KEK_ID))


def test_wrap_for_server_endpoint_404_raises():
    """404 from the daemon (unknown kek_id) must raise WorkbenchHttpError."""
    client = _fake_client()
    dek = bytes(range(32))

    with patch("ttio.workbench._http.http_json",
               return_value=(404, {"error": "kek not found"})):
        with pytest.raises(WorkbenchHttpError) as exc_info:
            asyncio.run(client.wrap_for_server(dek=dek, kek_id="server:nope"))
    assert exc_info.value.status == 404


def test_wrap_for_server_endpoint_409_raises():
    """409 from the daemon (readonly kek_id) must raise WorkbenchHttpError."""
    client = _fake_client()
    dek = bytes(range(32))

    with patch("ttio.workbench._http.http_json",
               return_value=(409, {"error": "kek is readonly"})):
        with pytest.raises(WorkbenchHttpError) as exc_info:
            asyncio.run(client.wrap_for_server(
                dek=dek, kek_id="server:readonly-kek"))
    assert exc_info.value.status == 409


def test_wrap_for_server_sends_correct_path_and_body():
    """Verify the method POSTs to the correct path with base64-encoded DEK."""
    client = _fake_client()
    dek = bytes(range(32))
    calls = []

    def _mock_http(method, host, port, path, *, scheme, token, body, **kw):
        calls.append((method, path, body))
        return _wrap_ok_response()

    with patch("ttio.workbench._http.http_json", side_effect=_mock_http):
        asyncio.run(client.wrap_for_server(dek=dek, kek_id=SERVER_KEK_ID))

    assert len(calls) == 1
    method, path, body = calls[0]
    assert method == "POST"
    assert path == "/v1/key-custody/wrap-for-server"
    assert body["kek_id"] == SERVER_KEK_ID
    assert base64.b64decode(body["dek"]) == dek


# ------------------------------------------ upload_encrypted_multi + ServerRecipient


def test_upload_encrypted_multi_with_server_recipient(tmp_path):
    """ServerRecipient in primary slot: wrap-for-server is called and the
    known blob appears in the ProtectionMetadata primary recipient slot."""
    src = _make_plain_tio(tmp_path)
    client = _fake_client()
    captured_paths = []

    def _mock_http(method, host, port, path, *, scheme, token, body, **kw):
        captured_paths.append(path)
        return _wrap_ok_response()

    with patch("ttio.workbench._http.http_json", side_effect=_mock_http):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="c", tio_path=str(src),
            recipients=[ServerRecipient("", SERVER_KEK_ID)]))

    assert "/v1/key-custody/wrap-for-server" in captured_paths

    import io
    from ttio.transport.encrypted import (
        read_encrypted_to_file,
        read_transport_recipients,
    )
    out = tmp_path / "out.tio"
    read_encrypted_to_file(io.BytesIO(client._store["c"]), str(out))
    recips = read_transport_recipients(str(out))
    assert recips, "ProtectionMetadata carries no recipients"
    primary_id, primary_algo, primary_blob = recips[0]
    assert primary_id == ""
    assert primary_algo == "aes-256-gcm"
    assert primary_blob == KNOWN_WRAPPED


def test_upload_encrypted_multi_server_recipient_auto_stamps_kek_id(tmp_path):
    """server_kek_id is automatically derived from the first ServerRecipient."""
    src = _make_plain_tio(tmp_path)
    client = _fake_client()

    with patch("ttio.workbench._http.http_json",
               return_value=_wrap_ok_response()):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="c", tio_path=str(src),
            recipients=[ServerRecipient("", SERVER_KEK_ID)]))

    import io
    from ttio.transport.encrypted import (
        read_encrypted_to_file,
        read_transport_server_kek_id,
    )
    out = tmp_path / "out.tio"
    read_encrypted_to_file(io.BytesIO(client._store["c"]), str(out))
    assert read_transport_server_kek_id(str(out)) == SERVER_KEK_ID


def test_upload_encrypted_multi_server_kek_id_consistency_check(tmp_path):
    """Passing both ServerRecipient and an inconsistent server_kek_id
    must raise ValueError before any upload."""
    src = _make_plain_tio(tmp_path)
    client = _fake_client()

    with patch("ttio.workbench._http.http_json",
               return_value=_wrap_ok_response()):
        with pytest.raises(ValueError, match="conflicts with"):
            asyncio.run(client.upload_encrypted_multi(
                project="p", container_uri="c", tio_path=str(src),
                recipients=[ServerRecipient("", kek_id="server:foo")],
                server_kek_id="server:bar"))


def test_upload_encrypted_multi_server_kek_id_consistent_is_ok(tmp_path):
    """Passing ServerRecipient and the *same* server_kek_id is allowed."""
    src = _make_plain_tio(tmp_path)
    client = _fake_client()

    with patch("ttio.workbench._http.http_json",
               return_value=_wrap_ok_response()):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="c", tio_path=str(src),
            recipients=[ServerRecipient("", kek_id=SERVER_KEK_ID)],
            server_kek_id=SERVER_KEK_ID))
    assert "c" in client._store


def test_upload_encrypted_multi_mixed_server_and_envelope_recipients(tmp_path):
    """Primary = ServerRecipient, additional = EnvelopeRecipient.
    The envelope recipient can independently unwrap the DEK."""
    src = _make_plain_tio(tmp_path)
    client = _fake_client()

    from ttio.key_rotation import _unwrap_dek
    from ttio.transport.encrypted import (
        read_encrypted_to_file,
        read_transport_recipients,
    )
    import io

    with patch("ttio.workbench._http.http_json",
               return_value=_wrap_ok_response()):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="c2", tio_path=str(src),
            recipients=[
                ServerRecipient("", SERVER_KEK_ID),
                EnvelopeRecipient("researcher", OTHER_KEK, "aes-256-gcm"),
            ]))

    out = tmp_path / "mixed.tio"
    read_encrypted_to_file(io.BytesIO(client._store["c2"]), str(out))
    recips = read_transport_recipients(str(out))
    ids = [r[0] for r in recips]
    assert "" in ids
    assert "researcher" in ids

    researcher_entry = next(r for r in recips if r[0] == "researcher")
    _rid, algo, wrapped = researcher_entry
    dek = _unwrap_dek(wrapped, OTHER_KEK, algorithm=algo)
    assert len(dek) == 32


def test_existing_envelope_recipient_path_unchanged(tmp_path):
    """Pure EnvelopeRecipient upload must NOT call wrap-for-server.
    Backward-compatibility: no daemon calls for existing callers."""
    src = _make_plain_tio(tmp_path)
    client = _fake_client()
    http_calls = []

    def _mock_http(method, host, port, path, *, scheme, token, body, **kw):
        http_calls.append(path)
        return (200, {})

    with patch("ttio.workbench._http.http_json", side_effect=_mock_http):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="c3", tio_path=str(src),
            recipients=[
                EnvelopeRecipient("", bytes([0x11] * 32), "aes-256-gcm"),
            ]))

    assert not any("/v1/key-custody" in p for p in http_calls)


# ================================================================ PF-7: unwrap_for_server


KNOWN_DEK = bytes(range(32))


def _unwrap_ok_response():
    return (200, {"dek": base64.b64encode(KNOWN_DEK).decode("ascii"),
                  "kek_id": SERVER_KEK_ID})


def test_unwrap_for_server_happy_path():
    """Happy path: stubbed 200 response; method returns the decoded 32-byte DEK."""
    client = _fake_client()
    wrapped = bytes([0xAB] * 48)

    with patch("ttio.workbench._http.http_json",
               return_value=_unwrap_ok_response()):
        result = asyncio.run(
            client.unwrap_for_server(wrapped_dek=wrapped, kek_id=SERVER_KEK_ID))

    assert result == KNOWN_DEK
    assert isinstance(result, bytes)
    assert len(result) == 32


def test_unwrap_for_server_wrong_size_dek_raises():
    """If daemon returns a non-32-byte DEK the method raises ValueError."""
    client = _fake_client()
    wrapped = bytes([0xAB] * 48)
    short_dek = bytes(16)

    with patch("ttio.workbench._http.http_json",
               return_value=(200, {
                   "dek": base64.b64encode(short_dek).decode("ascii"),
                   "kek_id": SERVER_KEK_ID,
               })):
        with pytest.raises(ValueError, match="non-32-byte DEK"):
            asyncio.run(client.unwrap_for_server(
                wrapped_dek=wrapped, kek_id=SERVER_KEK_ID))


def test_unwrap_for_server_4xx_raises():
    """404 and 422 from the daemon raise WorkbenchHttpError with correct status."""
    client = _fake_client()
    wrapped = bytes([0xAB] * 48)

    # 404 -- unknown kek_id
    with patch("ttio.workbench._http.http_json",
               return_value=(404, {"error": "kek not found"})):
        with pytest.raises(WorkbenchHttpError) as exc:
            asyncio.run(client.unwrap_for_server(
                wrapped_dek=wrapped, kek_id="server:nope"))
    assert exc.value.status == 404

    # 422 -- tampered wrapped blob
    with patch("ttio.workbench._http.http_json",
               return_value=(422, {"error": "AEAD authentication failed"})):
        with pytest.raises(WorkbenchHttpError) as exc:
            asyncio.run(client.unwrap_for_server(
                wrapped_dek=bytes([0xFF] * 48), kek_id=SERVER_KEK_ID))
    assert exc.value.status == 422


def test_unwrap_for_server_sends_correct_path_and_body():
    """Method POSTs to /v1/key-custody/unwrap-for-server with base64 wrapped_dek."""
    client = _fake_client()
    wrapped = bytes([0xAB] * 48)
    calls = []

    def _mock_http(method, host, port, path, *, scheme, token, body, **kw):
        calls.append((method, path, body))
        return _unwrap_ok_response()

    with patch("ttio.workbench._http.http_json", side_effect=_mock_http):
        asyncio.run(client.unwrap_for_server(
            wrapped_dek=wrapped, kek_id=SERVER_KEK_ID))

    assert len(calls) == 1
    method, path, body = calls[0]
    assert method == "POST"
    assert path == "/v1/key-custody/unwrap-for-server"
    assert body["kek_id"] == SERVER_KEK_ID
    assert base64.b64decode(body["wrapped_dek"]) == wrapped


# ========================================================== PF-7: download_via_server


def test_download_via_server_happy_path(tmp_path):
    """Full round-trip: upload with ServerRecipient + parallel researcher key,
    mock unwrap to return the researcher DEK, verify decrypt recovers data.

    Strategy: include both a ServerRecipient (primary) and an EnvelopeRecipient
    (researcher) holding OTHER_KEK.  The researcher recipient lets us recover the
    actual DEK via a local unwrap -- that same DEK is returned by the mock
    unwrap-for-server so download_via_server decrypts correctly.
    """
    import io

    from ttio.key_rotation import _unwrap_dek
    from ttio.transport.encrypted import (
        read_encrypted_to_file,
        read_transport_recipients,
        read_transport_server_kek_id,
    )

    src_path = _make_plain_tio(tmp_path)
    client = _fake_client()

    # Upload: ServerRecipient (primary, mock wrap) + EnvelopeRecipient (extra).
    with patch("ttio.workbench._http.http_json",
               return_value=(200, {
                   "wrapped_dek": base64.b64encode(KNOWN_WRAPPED).decode("ascii"),
               })):
        asyncio.run(client.upload_encrypted_multi(
            project="p", container_uri="srv", tio_path=str(src_path),
            recipients=[
                ServerRecipient("", SERVER_KEK_ID),
                EnvelopeRecipient("researcher", OTHER_KEK, "aes-256-gcm"),
            ]))

    # Recover the actual DEK from the researcher recipient (local unwrap).
    stage_path = str(tmp_path / "stage.tio")
    read_encrypted_to_file(io.BytesIO(client._store["srv"]), stage_path)
    recips = read_transport_recipients(stage_path)
    researcher = next(r for r in recips if r[0] == "researcher")
    _rid, algo, wrapped_researcher = researcher
    actual_dek = _unwrap_dek(wrapped_researcher, OTHER_KEK, algorithm=algo)
    assert len(actual_dek) == 32

    # download_via_server: mock unwrap returns the actual DEK.
    out_path = str(tmp_path / "out.tio")
    with patch("ttio.workbench._http.http_json",
               return_value=(200, {
                   "dek": base64.b64encode(actual_dek).decode("ascii"),
               })):
        result = asyncio.run(client.download_via_server(
            container_uri="srv", out_tio_path=out_path))

    assert result is not None
    assert isinstance(result, dict)
    assert len(result) > 0
    run_data = next(iter(result.values()))
    assert "mz" in run_data
    assert "intensity" in run_data


def test_download_via_server_no_server_recipient_raises(tmp_path):
    """Container without server-recipient must raise ValueError with clear message."""
    src = _make_plain_tio(tmp_path)
    client = _fake_client()
    local_kek = bytes([0x22] * 32)

    # Upload with a plain EnvelopeRecipient (no ServerRecipient, no server_kek_id).
    asyncio.run(client.upload_encrypted_multi(
        project="p", container_uri="plain", tio_path=str(src),
        recipients=[EnvelopeRecipient("", local_kek, "aes-256-gcm")]))

    out_path = str(tmp_path / "out.tio")
    with pytest.raises(ValueError, match="no server-recipient"):
        asyncio.run(client.download_via_server(
            container_uri="plain", out_tio_path=out_path))
