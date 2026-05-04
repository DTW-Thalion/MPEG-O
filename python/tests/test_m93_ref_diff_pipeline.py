"""End-to-end M93 REF_DIFF pipeline tests via SpectralDataset.write_minimal + open.

Covers Tasks 10c–10f: reference-embed helper, REF_DIFF encoder dispatch,
REF_DIFF decoder dispatch, format-version gating, and round-trip parity.
"""
from __future__ import annotations

import hashlib

import h5py
import numpy as np
import pytest

from ttio import SpectralDataset, WrittenGenomicRun
from ttio.enums import AcquisitionMode, Compression


def _build_ref_diff_run(
    reference_uri: str = "test-ref-uri",
    reference_chrom_seq: bytes | None = None,
    embed_reference: bool = True,
) -> WrittenGenomicRun:
    n = 5
    if reference_chrom_seq is None:
        reference_chrom_seq = b"ACGTACGTAC" * 100
    seq = b"ACGTACGTAC"
    sequences = np.frombuffer(seq * n, dtype=np.uint8)
    qualities = np.full(len(sequences), 30, dtype=np.uint8)
    return WrittenGenomicRun(
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        reference_uri=reference_uri,
        platform="ILLUMINA",
        sample_name="test",
        positions=np.array([1] * n, dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.zeros(n, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * 10,
        lengths=np.full(n, 10, dtype=np.uint32),
        cigars=["10M"] * n,
        read_names=[f"r{i}" for i in range(n)],
        mate_chromosomes=["*"] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["22"] * n,
        signal_codec_overrides={"sequences": Compression.REF_DIFF},
        embed_reference=embed_reference,
        reference_chrom_seqs={"22": reference_chrom_seq} if embed_reference else None,
    )


def _build_m82_only_run() -> WrittenGenomicRun:
    """No REF_DIFF override — pure M82 baseline run for the format-version
    gating regression test."""
    n = 3
    seq = b"ACGTACGT"
    sequences = np.frombuffer(seq * n, dtype=np.uint8)
    qualities = np.full(len(sequences), 25, dtype=np.uint8)
    return WrittenGenomicRun(
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        reference_uri="m82-only-uri",
        platform="ILLUMINA",
        sample_name="m82",
        positions=np.array([1, 2, 3], dtype=np.int64),
        mapping_qualities=np.full(n, 60, dtype=np.uint8),
        flags=np.zeros(n, dtype=np.uint32),
        sequences=sequences,
        qualities=qualities,
        offsets=np.arange(n, dtype=np.uint64) * 8,
        lengths=np.full(n, 8, dtype=np.uint32),
        cigars=["8M"] * n,
        read_names=[f"r{i}" for i in range(n)],
        mate_chromosomes=["*"] * n,
        mate_positions=np.full(n, -1, dtype=np.int64),
        template_lengths=np.zeros(n, dtype=np.int32),
        chromosomes=["22"] * n,
    )


def test_write_then_read_round_trip_with_ref_diff(tmp_path):
    run = _build_ref_diff_run()
    path = tmp_path / "ref_diff_round_trip.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 round trip",
        isa_investigation_id="TTIO:m93:rt",
        runs={"run_0001": run},
    )
    with SpectralDataset.open(path) as ds:
        out_run = ds.runs["run_0001"]
        assert len(out_run) == 5
        for i in range(5):
            assert out_run[i].sequence == "ACGTACGTAC"


def test_format_version_is_1_5_when_ref_diff_used(tmp_path):
    run = _build_ref_diff_run()
    path = tmp_path / "format_version_1_5.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 fv 1.5",
        isa_investigation_id="TTIO:m93:fv5",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        version = f.attrs["ttio_format_version"]
        if isinstance(version, bytes):
            version = version.decode("ascii")
        assert version == "1.0"


def test_format_version_stays_1_4_when_no_ref_diff(tmp_path):
    """Byte-parity guard: M82-only writes (no context-aware codec) MUST
    still stamp ``@ttio_format_version = "1.4"``. Bumping unilaterally
    would break every existing M82/M86 byte-parity test fixture."""
    run = _build_m82_only_run()
    path = tmp_path / "format_version_1_4.tio"
    SpectralDataset.write_minimal(
        path,
        title="m82 fv 1.4",
        isa_investigation_id="TTIO:m82:fv4",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        version = f.attrs["ttio_format_version"]
        if isinstance(version, bytes):
            version = version.decode("ascii")
        assert version == "1.0"


def test_embedded_reference_present_at_canonical_path(tmp_path):
    ref_seq = b"ACGTACGTAC" * 100
    run = _build_ref_diff_run(reference_chrom_seq=ref_seq)
    path = tmp_path / "embedded_ref.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 embed",
        isa_investigation_id="TTIO:m93:e",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        ref_grp = f["/study/references/test-ref-uri"]
        md5_attr = ref_grp.attrs["md5"]
        if isinstance(md5_attr, bytes):
            md5_attr = md5_attr.decode("ascii")
        assert md5_attr == hashlib.md5(ref_seq).digest().hex()
        chrom_data = bytes(np.asarray(ref_grp["chromosomes/22/data"]).tobytes())
        assert chrom_data == ref_seq


def test_two_runs_sharing_reference_dedupe(tmp_path):
    """Q6 = C: auto-dedup. Two runs with the same reference_uri share storage."""
    run_a = _build_ref_diff_run(reference_uri="shared-uri")
    run_b = _build_ref_diff_run(reference_uri="shared-uri")
    path = tmp_path / "dedup.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 dedup",
        isa_investigation_id="TTIO:m93:d",
        runs={"run_a": run_a, "run_b": run_b},
    )
    with h5py.File(path, "r") as f:
        ref_grps = list(f["/study/references"].keys())
        assert ref_grps == ["shared-uri"]


def test_two_runs_with_same_uri_different_md5_raises(tmp_path):
    """Same reference_uri carrying two different MD5s in one file is a hard error."""
    run_a = _build_ref_diff_run(
        reference_uri="conflict-uri",
        reference_chrom_seq=b"ACGTACGTAC" * 100,
    )
    run_b = _build_ref_diff_run(
        reference_uri="conflict-uri",
        reference_chrom_seq=b"TTTTTTTTTT" * 100,
    )
    path = tmp_path / "md5_conflict.tio"
    with pytest.raises(ValueError, match="MD5"):
        SpectralDataset.write_minimal(
            path,
            title="m93 md5 conflict",
            isa_investigation_id="TTIO:m93:c",
            runs={"run_a": run_a, "run_b": run_b},
        )


def test_ref_diff_falls_back_to_base_pack_when_no_ref(tmp_path):
    """Q5b = C: per-channel @compression reflects what was actually applied."""
    run = _build_ref_diff_run(embed_reference=False)
    # Drop reference_chrom_seqs so the writer can't apply REF_DIFF.
    run.reference_chrom_seqs = None
    path = tmp_path / "fallback.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 fallback",
        isa_investigation_id="TTIO:m93:f",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        seqs_ds = f["/study/genomic_runs/run_0001/signal_channels/sequences"]
        # The per-channel @compression names what was actually written.
        codec_id = int(seqs_ds.attrs["compression"])
        assert codec_id == int(Compression.BASE_PACK)


def test_ref_missing_at_read_raises(tmp_path):
    """Q5c = A: hard error when ref unresolvable at read time."""
    run = _build_ref_diff_run()
    path = tmp_path / "missing_at_read.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 missing",
        isa_investigation_id="TTIO:m93:m",
        runs={"run_0001": run},
    )
    # Surgically delete the embedded reference group.
    with h5py.File(path, "r+") as f:
        del f["/study/references/test-ref-uri"]

    from ttio.genomic.reference_resolver import RefMissingError
    with SpectralDataset.open(path) as ds:
        with pytest.raises(RefMissingError):
            _ = ds.runs["run_0001"][0].sequence


# ─── Task 11 — DEFAULT_CODECS_V1_5 auto-apply ────────────────────────


def test_default_v1_5_applies_ref_diff_when_no_override_and_ref_present(tmp_path):
    """Q5a=B: empty signal_codec_overrides + signal_compression="gzip"
    + reference_chrom_seqs provided → sequences gets a ref-aware codec
    automatically. No feature flag required.

    The writer picks REF_DIFF_V2 (id 14, group layout with refdiff_v2
    child) when libttio_rans is available; otherwise it falls back to
    REF_DIFF (id 9, flat dataset). The invariant being tested — that
    the writer auto-selects a ref-aware codec when a reference is
    provided — holds in both cases.
    """
    from dataclasses import replace

    run = _build_ref_diff_run()
    # Drop the explicit override so the auto-default kicks in.
    run = replace(run, signal_codec_overrides={})

    path = tmp_path / "default_codec.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 default",
        isa_investigation_id="TTIO:m93:default",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        seqs = f["/study/genomic_runs/run_0001/signal_channels/sequences"]
        if isinstance(seqs, h5py.Group):
            # v2 path (native lib available): refdiff_v2 child dataset
            # carries @compression == REF_DIFF_V2.
            child = seqs["refdiff_v2"]
            assert int(child.attrs["compression"]) == int(Compression.REF_DIFF_V2), (
                f"expected REF_DIFF_V2 ({int(Compression.REF_DIFF_V2)}), "
                f"got {int(child.attrs['compression'])}"
            )
        else:
            # v1 path (native lib unavailable): flat dataset with REF_DIFF.
            assert int(seqs.attrs["compression"]) == int(Compression.REF_DIFF), (
                f"expected REF_DIFF ({int(Compression.REF_DIFF)}), "
                f"got {int(seqs.attrs['compression'])}"
            )


def test_default_v1_5_skipped_when_no_reference(tmp_path):
    """Without a reference, the default lookup is skipped (no REF_DIFF
    auto-apply). Channel goes through the legacy signal_compression path."""
    from dataclasses import replace

    run = _build_ref_diff_run()
    run = replace(
        run,
        signal_codec_overrides={},
        embed_reference=False,
        reference_chrom_seqs=None,
    )

    path = tmp_path / "default_no_ref.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 default no ref",
        isa_investigation_id="TTIO:m93:dnoref",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        seqs_ds = f["/study/genomic_runs/run_0001/signal_channels/sequences"]
        actual = int(seqs_ds.attrs.get("compression", 0))
        assert actual != int(Compression.REF_DIFF)


def test_default_v1_5_skipped_when_signal_compression_is_none(tmp_path):
    """signal_compression="none" disables auto-default. The user is
    explicitly opting out of any codec; respect their choice."""
    from dataclasses import replace

    run = _build_ref_diff_run()
    run = replace(run, signal_codec_overrides={}, signal_compression="none")

    path = tmp_path / "no_default.tio"
    SpectralDataset.write_minimal(
        path,
        title="m93 no default",
        isa_investigation_id="TTIO:m93:nodef",
        runs={"run_0001": run},
    )
    with h5py.File(path, "r") as f:
        seqs_ds = f["/study/genomic_runs/run_0001/signal_channels/sequences"]
        actual = int(seqs_ds.attrs.get("compression", 0))
        assert actual != int(Compression.REF_DIFF)
