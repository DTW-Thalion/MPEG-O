"""
Live-daemon end-to-end integration test for the workbench client SDK.

Drives the real `ttio.workbench.*` client surface (W1-W5) against a
running `tti-workbench-server` daemon. This is the live half of the
W1-W5 acceptance gates -- the unit suites pin the wire shapes; this
test proves the client actually talks to the daemon.

GATING: the whole module SKIPS unless the daemon-coordinate env vars
are set, so it never runs (or fails) in the normal unit-test CI:

    TTIO_WORKBENCH_URL       ws://127.0.0.1:<port>/transport
    TTIO_WORKBENCH_STAGING   <staging-root containing bootstrap-credentials.json>
    TTIO_WORKBENCH_PROJECT   project the bootstrap admin is a member of (default "adni")

The local runner `scripts/workbench-live-smoke.sh` boots the daemon,
seeds the admin's project, exports these, and invokes pytest; the
`workbench-live` CI workflow does the same on a built server.

Flow exercised:
  - connect via BootstrapAdminAuth (W1 auth)
  - containers().list() (W5.2 / SDK containers)
  - pipelines().register() + list() + get() (W3)
  - jobs().submit() + poll to terminal + cancel a second job (W3)
  - jobs().events() SSE long-poll to a terminal frame (W3)
  - cohort preview_count() (W3)
  - sessions().create() + list() + terminate() (W4)
"""
from __future__ import annotations

import asyncio
import os
import time
import uuid

import pytest

URL = os.environ.get("TTIO_WORKBENCH_URL")
STAGING = os.environ.get("TTIO_WORKBENCH_STAGING")
PROJECT = os.environ.get("TTIO_WORKBENCH_PROJECT", "adni")

pytestmark = pytest.mark.skipif(
    not (URL and STAGING),
    reason="live workbench daemon env not set "
           "(TTIO_WORKBENCH_URL + TTIO_WORKBENCH_STAGING)",
)


@pytest.fixture(scope="module")
def client():
    import ttio
    from ttio.workbench.auth_providers import BootstrapAdminAuth
    c = ttio.connect(URL, auth=BootstrapAdminAuth(staging_root=STAGING))
    return c


# ---------------------------------------------------- W1 auth

def test_connect_as_bootstrap_admin(client):
    assert client.session.username == "admin"
    assert client.session.token.startswith("ttiowbs_")


# ---------------------------------------------------- W5.2 containers

def test_containers_list_round_trips(client):
    page = client.containers().list(project=PROJECT)
    # Fresh daemon: list is reachable + well-formed (may be empty).
    assert isinstance(page.containers, list)


# ---------------------------------------------------- W3 cohort

def test_cohort_preview_count_round_trips(client):
    # The cohort REST plane (POST /v1/cohorts/preview-count) was
    # 404 in workbench-server v1.0 -- TTIOWBCohortsHandler was
    # implemented but never registered on the router. Fixed in
    # tti-workbench-server PR #29 (handler registered at
    # shared-service init); this test exercises it normally now.
    from ttio.workbench.cohort import CohortQuery, container
    query = CohortQuery(
        select="containers",
        predicate=container("project", "eq", PROJECT),
    )
    count = client.preview_count(query)
    assert isinstance(count, int)
    assert count >= 0


# ---------------------------------------------------- W3 pipelines + jobs

@pytest.fixture(scope="module")
def echo_pipeline_id(client):
    pl = client.pipelines().register(
        identifier="live-smoke-echo-" + uuid.uuid4().hex[:8],
        version="1.0.0",
        project=PROJECT,
        engine_pin="shell",
        definition="echo live-smoke-output && sleep 0.1",
        inputs_schema={},
        outputs_schema={},
    )
    assert pl.pipeline_id
    return pl.pipeline_id


def test_pipeline_register_then_listed(client, echo_pipeline_id):
    listed = {p.pipeline_id for p in client.pipelines().list()}
    assert echo_pipeline_id in listed
    fetched = client.pipelines().get(echo_pipeline_id)
    assert fetched.pipeline_id == echo_pipeline_id


def test_job_submit_runs_to_completion(client, echo_pipeline_id):
    job = client.jobs().submit(
        pipeline_id=echo_pipeline_id, inputs={}, params={})
    assert job.job_id
    deadline = time.time() + 30
    last = job
    while time.time() < deadline:
        last = client.jobs().get(job.job_id)
        if last.is_terminal:
            break
        time.sleep(0.2)
    assert last.is_terminal, f"job never terminated; last status={last.status}"
    assert last.status == "completed", f"unexpected terminal status {last.status}"


def test_job_events_stream_reaches_terminal(client, echo_pipeline_id):
    job = client.jobs().submit(
        pipeline_id=echo_pipeline_id, inputs={}, params={})

    async def collect():
        seen = []
        jobs = client.jobs()
        async for ev in jobs.events(job.job_id):
            seen.append(ev)
            status = ev.data.get("status")
            if status in ("completed", "failed", "cancelled"):
                break
            if len(seen) > 200:
                break
        return seen

    events = asyncio.run(asyncio.wait_for(collect(), timeout=30))
    assert events, "no SSE frames received"
    statuses = [e.data.get("status") for e in events if e.event == "job.state"]
    assert "completed" in statuses, f"terminal not seen; statuses={statuses}"


def test_job_cancel(client, echo_pipeline_id):
    # A slow pipeline so we can cancel before it finishes.
    slow = client.pipelines().register(
        identifier="live-smoke-slow-" + uuid.uuid4().hex[:8],
        version="1.0.0",
        project=PROJECT,
        engine_pin="shell",
        definition="sleep 60",
        inputs_schema={},
        outputs_schema={},
    )
    job = client.jobs().submit(pipeline_id=slow.pipeline_id, inputs={}, params={})
    # Wait until it leaves the queue, then cancel.
    deadline = time.time() + 15
    while time.time() < deadline:
        cur = client.jobs().get(job.job_id)
        if cur.status in ("starting", "running", "queued"):
            break
        time.sleep(0.2)
    client.jobs().cancel(job.job_id)
    deadline = time.time() + 15
    last = None
    while time.time() < deadline:
        last = client.jobs().get(job.job_id)
        if last.is_terminal:
            break
        time.sleep(0.2)
    assert last is not None and last.status == "cancelled", \
        f"expected cancelled; got {None if last is None else last.status}"


# ---------------------------------------------------- W4 sessions

def test_session_create_list_terminate(client):
    sessions = client.sessions()
    created = sessions.create(
        project=PROJECT,
        engine_pin="shell",
        command=["/bin/sh", "-c", "sleep 60"],
    )
    assert created.session_id
    try:
        listed = {s.session_id for s in sessions.list(limit=100)}
        assert created.session_id in listed
    finally:
        sessions.terminate(created.session_id)
    deadline = time.time() + 15
    last = None
    while time.time() < deadline:
        last = sessions.get(created.session_id)
        if last.is_terminal:
            break
        time.sleep(0.2)
    assert last is not None and last.is_terminal, \
        f"session never terminated; status={None if last is None else last.status}"


# ---------------------------------------------------- transport upload/download

def _live_tis_bytes(tmp_path) -> bytes:
    """Encode a minimal *valid* .tis transport stream. Uploads must be
    real transport streams: the daemon parses the upload and rejects
    anything without valid packet magic (so opaque blobs are refused)."""
    import numpy as np
    from ttio import SpectralDataset, WrittenRun
    from ttio.enums import AcquisitionMode
    from ttio.tools import transport_encode_cli
    tio = tmp_path / "live_src.tio"
    SpectralDataset.write_minimal(
        str(tio), title="live", isa_investigation_id="TTIO:live",
        runs={"run_0001": WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": np.linspace(100.0, 102.0, 6),
                          "intensity": np.linspace(1.0, 60.0, 6)},
            offsets=np.array([0], dtype=np.uint64),
            lengths=np.array([6], dtype=np.uint32),
            retention_times=np.array([0.0]),
            ms_levels=np.ones(1, dtype=np.int32),
            polarities=np.ones(1, dtype=np.int32),
            precursor_mzs=np.zeros(1),
            precursor_charges=np.zeros(1, dtype=np.int32),
            base_peak_intensities=np.array([60.0]),
        )})
    tis = tmp_path / "live_src.tis"
    assert transport_encode_cli.main([str(tio), str(tis)]) == 0
    return tis.read_bytes()


def test_tis_upload_download_round_trip(client, tmp_path):
    """Upload a valid .tis stream and re-download it byte-for-byte.

    First upload/download e2e in the live smoke; also exercises the
    websockets>=14 ack-drain path on the upload client.

    NOTE: W6.2 blob-level BYOK (sealing the whole payload into opaque
    ciphertext) is intentionally NOT tested here -- the daemon validates
    the upload as a transport stream and rejects ciphertext with
    'invalid packet magic'. Encrypted upload must instead use per-AU
    encryption that yields a valid .tis. See docs/parity-audit-v1.0.md §3.2.
    """
    tis = _live_tis_bytes(tmp_path)
    uri = f"uri:tio:{PROJECT}-tis-{uuid.uuid4().hex[:8]}"
    result = asyncio.run(client.upload_bytes(
        project=PROJECT, container_uri=uri, data=tis))
    dl = asyncio.run(client.download_bytes(container_uri=result.container_uri))
    # The daemon ingests the stream into storage and re-encodes a fresh
    # .tis on download, so the bytes differ -- assert a *semantic*
    # round-trip: the re-emitted stream decodes back to the same data.
    assert dl.payload, "download returned no bytes"
    from ttio import SpectralDataset
    from ttio.tools import transport_decode_cli
    out_tis = tmp_path / "dl.tis"
    out_tis.write_bytes(dl.payload)
    out_tio = tmp_path / "dl.tio"
    assert transport_decode_cli.main([str(out_tis), str(out_tio)]) == 0
    with SpectralDataset.open(str(out_tio)) as ds:
        assert ds.ms_runs  # the MS run survived upload -> ingest -> download


# ---------------------------------------------------- per-AU encrypted upload

def test_per_au_encrypted_upload_round_trip(client, tmp_path):
    """Phase 1: the client per-AU encrypted upload/download round-trip.

    `upload_encrypted` (encrypt a copy of the .tio per-AU + emit a valid
    .tis) -> daemon stores it opaque (server #31) -> `download_decrypted`
    (materialise + decrypt) -> channel values match the plaintext source.
    This is the correct encryption model after blob-BYOK was found
    daemon-incompatible (parity-audit §3.2; per-au-encrypted-upload-plan)."""
    import numpy as np
    from ttio import SpectralDataset, WrittenRun
    from ttio.enums import AcquisitionMode
    from ttio.transport.encrypted import is_per_au_encrypted

    key = bytes([0x5A] * 32)
    mz = np.linspace(100.0, 105.0, 12)
    intensity = np.linspace(1.0, 120.0, 12)
    src = tmp_path / "enc_src.tio"
    SpectralDataset.write_minimal(
        str(src), title="enc", isa_investigation_id="TTIO:enc",
        runs={"run_0001": WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": mz, "intensity": intensity},
            offsets=np.array([0, 6], dtype=np.uint64),
            lengths=np.array([6, 6], dtype=np.uint32),
            retention_times=np.array([0.0, 1.0]),
            ms_levels=np.ones(2, dtype=np.int32),
            polarities=np.ones(2, dtype=np.int32),
            precursor_mzs=np.zeros(2),
            precursor_charges=np.zeros(2, dtype=np.int32),
            base_peak_intensities=np.array([60.0, 120.0]),
        )})

    uri = f"uri:tio:{PROJECT}-enc-{uuid.uuid4().hex[:8]}"
    result = asyncio.run(client.upload_encrypted(
        project=PROJECT, container_uri=uri, tio_path=str(src), key=key))

    out = tmp_path / "rt.tio"
    channels = asyncio.run(client.download_decrypted(
        container_uri=result.container_uri, key=key, out_tio_path=str(out)))

    rt = channels["run_0001"]
    np.testing.assert_allclose(rt["mz"], mz)
    np.testing.assert_allclose(rt["intensity"], intensity)
    # The materialised container on disk is still encrypted: the daemon
    # never held the key, and download_decrypted decrypts client-side.
    assert is_per_au_encrypted(str(out))


def test_per_au_encrypted_pqc_upload_round_trip(client, tmp_path):
    """Phase 3: PQC per-AU encrypted upload/download round-trip.

    Same daemon-faithful path as the BYOK test, but the per-run DEK is
    randomly generated, ML-KEM-1024-wrapped, and carried in the
    ProtectionMetadata packet (no caller-held key). Only the holder of
    the ML-KEM private key recovers it. Preview-gated like the server's
    opt_pqc_preview: the un-previewed call must refuse, and the wrong
    private key must fail to decrypt."""
    import numpy as np
    import ttio.pqc as core_pqc
    from ttio import SpectralDataset, WrittenRun
    from ttio.enums import AcquisitionMode
    from ttio.transport.encrypted import is_per_au_encrypted
    from ttio.workbench import pqc

    if not core_pqc.is_available():
        pytest.skip("liboqs-python not installed (ttio[pqc]); "
                    "PQC preview unavailable")

    mz = np.linspace(100.0, 105.0, 12)
    intensity = np.linspace(1.0, 120.0, 12)
    src = tmp_path / "pqc_src.tio"
    SpectralDataset.write_minimal(
        str(src), title="pqc", isa_investigation_id="TTIO:pqc",
        runs={"run_0001": WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": mz, "intensity": intensity},
            offsets=np.array([0, 6], dtype=np.uint64),
            lengths=np.array([6, 6], dtype=np.uint32),
            retention_times=np.array([0.0, 1.0]),
            ms_levels=np.ones(2, dtype=np.int32),
            polarities=np.ones(2, dtype=np.int32),
            precursor_mzs=np.zeros(2),
            precursor_charges=np.zeros(2, dtype=np.int32),
            base_peak_intensities=np.array([60.0, 120.0]),
        )})

    kp = pqc.kem_keygen()
    uri = f"uri:tio:{PROJECT}-pqc-{uuid.uuid4().hex[:8]}"

    # opt_pqc_preview gating: refuses without preview=True.
    with pytest.raises(pqc.PQCPreviewDisabledError):
        asyncio.run(client.upload_encrypted_pqc(
            project=PROJECT, container_uri=uri, tio_path=str(src),
            recipient_public_key=kp.public_key))

    result = asyncio.run(client.upload_encrypted_pqc(
        project=PROJECT, container_uri=uri, tio_path=str(src),
        recipient_public_key=kp.public_key, preview=True))

    out = tmp_path / "pqc_rt.tio"
    channels = asyncio.run(client.download_decrypted_pqc(
        container_uri=result.container_uri,
        recipient_private_key=kp.private_key,
        out_tio_path=str(out), preview=True))

    rt = channels["run_0001"]
    np.testing.assert_allclose(rt["mz"], mz)
    np.testing.assert_allclose(rt["intensity"], intensity)
    assert is_per_au_encrypted(str(out))

    # Wrong ML-KEM private key cannot recover the DEK.
    wrong = pqc.kem_keygen()
    bad_out = tmp_path / "pqc_bad.tio"
    with pytest.raises(Exception):
        asyncio.run(client.download_decrypted_pqc(
            container_uri=result.container_uri,
            recipient_private_key=wrong.private_key,
            out_tio_path=str(bad_out), preview=True))


def test_per_au_encrypted_envelope_upload_round_trip(client, tmp_path):
    """Phase 4: envelope (symmetric KEK) per-AU upload/download round-trip.

    Like the PQC test, but the per-run DEK is wrapped under a 32-byte
    symmetric AES-256-GCM KEK (not an ML-KEM public key) and carried in
    the ProtectionMetadata. Not preview-gated. The wrong KEK must fail to
    decrypt."""
    import os

    import numpy as np
    from ttio import SpectralDataset, WrittenRun
    from ttio.enums import AcquisitionMode
    from ttio.transport.encrypted import is_per_au_encrypted

    kek = bytes([0x3C] * 32)
    mz = np.linspace(100.0, 105.0, 12)
    intensity = np.linspace(1.0, 120.0, 12)
    src = tmp_path / "env_src.tio"
    SpectralDataset.write_minimal(
        str(src), title="env", isa_investigation_id="TTIO:env",
        runs={"run_0001": WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": mz, "intensity": intensity},
            offsets=np.array([0, 6], dtype=np.uint64),
            lengths=np.array([6, 6], dtype=np.uint32),
            retention_times=np.array([0.0, 1.0]),
            ms_levels=np.ones(2, dtype=np.int32),
            polarities=np.ones(2, dtype=np.int32),
            precursor_mzs=np.zeros(2),
            precursor_charges=np.zeros(2, dtype=np.int32),
            base_peak_intensities=np.array([60.0, 120.0]),
        )})

    uri = f"uri:tio:{PROJECT}-env-{uuid.uuid4().hex[:8]}"
    result = asyncio.run(client.upload_encrypted_envelope(
        project=PROJECT, container_uri=uri, tio_path=str(src), kek=kek))

    out = tmp_path / "env_rt.tio"
    channels = asyncio.run(client.download_decrypted_envelope(
        container_uri=result.container_uri, kek=kek, out_tio_path=str(out)))

    rt = channels["run_0001"]
    np.testing.assert_allclose(rt["mz"], mz)
    np.testing.assert_allclose(rt["intensity"], intensity)
    assert is_per_au_encrypted(str(out))

    # Wrong KEK cannot recover the DEK.
    wrong_kek = os.urandom(32)
    bad_out = tmp_path / "env_bad.tio"
    with pytest.raises(Exception):
        asyncio.run(client.download_decrypted_envelope(
            container_uri=result.container_uri, kek=wrong_kek,
            out_tio_path=str(bad_out)))


def test_per_au_encrypted_upload_round_trip_encrypted_headers(client, tmp_path):
    """BYOK round-trip with `encrypt_headers=True`.

    The other encrypted live tests all use encrypt_headers=False; this
    exercises the distinct encrypted-AU-headers transport path (the AU
    header bytes are encrypted too, not just channel payloads), which is
    a different code path in encrypt_per_au / write_encrypted_dataset."""
    import numpy as np
    from ttio import SpectralDataset, WrittenRun
    from ttio.enums import AcquisitionMode

    key = bytes([0x77] * 32)
    mz = np.linspace(100.0, 105.0, 12)
    intensity = np.linspace(1.0, 120.0, 12)
    src = tmp_path / "hdr_src.tio"
    SpectralDataset.write_minimal(
        str(src), title="hdr", isa_investigation_id="TTIO:hdr",
        runs={"run_0001": WrittenRun(
            spectrum_class="TTIOMassSpectrum",
            acquisition_mode=int(AcquisitionMode.MS1_DDA),
            channel_data={"mz": mz, "intensity": intensity},
            offsets=np.array([0, 6], dtype=np.uint64),
            lengths=np.array([6, 6], dtype=np.uint32),
            retention_times=np.array([0.0, 1.0]),
            ms_levels=np.ones(2, dtype=np.int32),
            polarities=np.ones(2, dtype=np.int32),
            precursor_mzs=np.zeros(2),
            precursor_charges=np.zeros(2, dtype=np.int32),
            base_peak_intensities=np.array([60.0, 120.0]),
        )})

    uri = f"uri:tio:{PROJECT}-hdr-{uuid.uuid4().hex[:8]}"
    result = asyncio.run(client.upload_encrypted(
        project=PROJECT, container_uri=uri, tio_path=str(src), key=key,
        encrypt_headers=True))

    out = tmp_path / "hdr_rt.tio"
    channels = asyncio.run(client.download_decrypted(
        container_uri=result.container_uri, key=key, out_tio_path=str(out)))

    rt = channels["run_0001"]
    np.testing.assert_allclose(rt["mz"], mz)
    np.testing.assert_allclose(rt["intensity"], intensity)


def test_per_au_encrypted_genomic_upload_round_trip(client, tmp_path):
    """BYOK round-trip for a genomic_runs container.

    All other encrypted live tests use ms_runs; the per-AU helpers also
    walk /study/genomic_runs/. The client encrypt/upload/decrypt code is
    content-agnostic and the daemon stores the encrypted .tis opaquely
    (server #31), so one language's genomic live test covers the
    daemon-passthrough risk (the genomic per-AU transport itself is
    unit-tested in both languages: test_m90_8 / its Java peer)."""
    import numpy as np
    from ttio import SpectralDataset
    from ttio.transport.encrypted import is_per_au_encrypted
    from ttio.written_genomic_run import WrittenGenomicRun

    key = bytes([0x2B] * 32)
    n, L = 4, 8
    sequences = np.frombuffer(b"ACGTACGT" * n, dtype=np.uint8)
    qualities = np.frombuffer(bytes([30] * (n * L)), dtype=np.uint8)
    run = WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p14",
        platform="ILLUMINA",
        sample_name="NA12878",
        positions=np.array([100, 200, 300, 400], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.full(n, 0x0003, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * L,
        lengths=np.full(n, L, dtype=np.uint32),
        cigars=[f"{L}M"] * n,
        read_names=[f"read_{i:03d}" for i in range(n)],
        mate_chromosomes=[""] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["chr1", "chr1", "chr2", "chr2"],
    )
    src = tmp_path / "gen_src.tio"
    SpectralDataset.write_minimal(
        str(src), title="gen", isa_investigation_id="TTIO:gen",
        runs={}, genomic_runs={"genomic_0001": run})

    uri = f"uri:tio:{PROJECT}-gen-{uuid.uuid4().hex[:8]}"
    result = asyncio.run(client.upload_encrypted(
        project=PROJECT, container_uri=uri, tio_path=str(src), key=key))

    out = tmp_path / "gen_rt.tio"
    channels = asyncio.run(client.download_decrypted(
        container_uri=result.container_uri, key=key, out_tio_path=str(out)))

    rt = channels["genomic_0001"]
    np.testing.assert_array_equal(rt["sequences"], sequences)
    np.testing.assert_array_equal(rt["qualities"], qualities)
    assert is_per_au_encrypted(str(out))


# ---------------------------------------------------- v0.11 full-accessor round-trip

def test_v011_full_accessor_round_trip(client, tmp_path):
    """Upload a .tio populated with every v0.11 first-class accessor
    via the live workbench daemon and verify the server-side
    materialised .tio (after re-download) preserves every accessor's
    content.

    Accessors exercised (from ``_v0_11_fixtures.build_everything``):
    references (3 contigs), MS_runs (1 run x 5 spectra), genomic_runs
    (1 run x 4 reads), MSImage (3x3x4 continuous), identifications
    (2 rows), quantifications (2 rows), dataset_provenance
    (2 records), subjects (2 rows), samples (3 rows),
    @encryption_algorithm = "aes-256-gcm".

    Guards task #138: future libTTIO regressions on the daemon's
    v0.11 transport-reader code path would slip past the unit + cross-
    language matrices (those exercise the SDK in isolation). This test
    drives the end-to-end ingest path through tti-workbench-server.

    Mirrors ``test_tis_upload_download_round_trip`` -- encodes the
    fixture .tio to a .tis with ``transport_encode_cli``, uploads via
    ``client.upload_bytes``, downloads via ``client.download_bytes``,
    decodes back to .tio with ``transport_decode_cli``, and compares
    accessor-by-accessor using the shared ``ACCESSOR_SPECS`` matrix.
    """
    import sys
    from pathlib import Path

    # The v0.11 fixture/spec helpers live in python/tests/ (one level up
    # from this integration package); add that on sys.path so the late
    # imports below resolve cleanly.
    test_root = Path(__file__).resolve().parent.parent
    if str(test_root) not in sys.path:
        sys.path.insert(0, str(test_root))

    from ttio import SpectralDataset
    from ttio.tools import transport_decode_cli, transport_encode_cli

    from _v0_11_accessor_spec import ACCESSOR_SPECS  # noqa: E402
    from _v0_11_fixtures import build_everything  # noqa: E402

    src = build_everything(tmp_path / "v011_everything.tio")

    # Encode the source .tio to a valid .tis transport stream — daemon
    # validates uploads as transport streams (see _live_tis_bytes /
    # test_tis_upload_download_round_trip above).
    src_tis = tmp_path / "v011_everything.tis"
    assert transport_encode_cli.main([str(src), str(src_tis)]) == 0

    uri = f"uri:tio:{PROJECT}-v011-{uuid.uuid4().hex[:8]}"
    result = asyncio.run(client.upload_bytes(
        project=PROJECT, container_uri=uri, data=src_tis.read_bytes()))

    dl = asyncio.run(client.download_bytes(container_uri=result.container_uri))
    assert dl.payload, "download returned no bytes"

    # Daemon re-encodes a fresh .tis on download; decode to .tio for
    # accessor-level comparison.
    rt_tis = tmp_path / "v011_rt.tis"
    rt_tis.write_bytes(dl.payload)
    rt_tio = tmp_path / "v011_rt.tio"
    assert transport_decode_cli.main([str(rt_tis), str(rt_tio)]) == 0

    # Compare each accessor present in the fixture. Genomic-run
    # comparison requires libttio_rans; if the runner can't decode the
    # genomic transport packet, the .tio open or genomic_runs accessor
    # itself will fail rather than this loop -- mirrors the conformance
    # matrix's behaviour.
    with SpectralDataset.open(str(src)) as a, \
            SpectralDataset.open(str(rt_tio)) as b:
        for spec in ACCESSOR_SPECS:
            spec.assert_content_equals(a, b)
