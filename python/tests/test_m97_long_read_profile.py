"""M97 long-read profile tests.

The ``@read_role`` attribute, the QUALITY_BINNED platform guard, and
the REF_DIFF_V2 ``slice_bytes`` byte budget — at the codec level and
through both writer paths (legacy whole-channel and blocks_v1).

Mirrors:
    objc/Tests/TestM97LongReadProfile.m
    java/src/test/java/.../M97LongReadProfileTest.java
"""
from __future__ import annotations

import struct
from pathlib import Path

import numpy as np
import pytest

from ttio.codecs import quality
from ttio.codecs import ref_diff_v2 as rdv2
from ttio.enums import Compression

if not rdv2.HAVE_NATIVE_LIB:
    pytest.skip(
        "requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
        allow_module_level=True,
    )


# ---------------------------------------------------------------------------
# fixtures
# ---------------------------------------------------------------------------

N = 40
READ_LEN = 10


def _ref_bytes(length: int = 10_000) -> bytes:
    return (b"ACGTACGTAC" * (length // 10 + 1))[:length]


def _build_run(platform: str = "ILLUMINA", **extra):
    """An aligned 40-read single-chromosome run, 10 bp per read."""
    from ttio.written_genomic_run import WrittenGenomicRun

    positions = (np.arange(N) * 20 + 1).astype(np.int64)
    ref = _ref_bytes()
    seqs = bytearray()
    for i in range(N):
        start = int(positions[i]) - 1
        seqs.extend(ref[start:start + READ_LEN])

    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.m97_test",
        platform=platform,
        sample_name="HG002",
        positions=positions,
        mapping_qualities=np.full(N, 60, dtype=np.uint8),
        flags=np.zeros(N, dtype=np.uint32),
        sequences=np.frombuffer(bytes(seqs), dtype=np.uint8),
        qualities=np.frombuffer(bytes([30] * (N * READ_LEN)), dtype=np.uint8),
        offsets=np.arange(N, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N, READ_LEN, dtype=np.uint32),
        cigars=[f"{READ_LEN}M"] * N,
        read_names=[f"r{i}" for i in range(N)],
        mate_chromosomes=["*"] * N,
        mate_positions=np.zeros(N, dtype=np.int64),
        template_lengths=np.zeros(N, dtype=np.int32),
        chromosomes=["22"] * N,
        reference_chrom_seqs={"22": ref},
        embed_reference=True,
        **extra,
    )


def _write_run(tmp_path: Path, run, fname: str = "m97.tio") -> Path:
    from ttio.spectral_dataset import SpectralDataset

    out = tmp_path / fname
    SpectralDataset.write_minimal(
        out,
        title="m97_test",
        isa_investigation_id="M97",
        runs={},
        genomic_runs={"r0": run},
    )
    return out


def _n_slices(blob: bytes) -> int:
    """The outer header's n_slices (u32 LE at offset 8)."""
    return struct.unpack_from("<I", blob, 8)[0]


# ---------------------------------------------------------------------------
# QUALITY_BINNED platform guard
# ---------------------------------------------------------------------------

def test_binned_allowed_for_platform():
    assert quality.binned_allowed_for_platform(None)
    assert quality.binned_allowed_for_platform("")
    assert quality.binned_allowed_for_platform("ILLUMINA")
    # ont only counts as a whole token — IONTORRENT contains it.
    assert quality.binned_allowed_for_platform("IONTORRENT")
    assert not quality.binned_allowed_for_platform("ONT")
    assert not quality.binned_allowed_for_platform("PacBio HiFi")
    assert not quality.binned_allowed_for_platform("HIFI")
    assert not quality.binned_allowed_for_platform("Oxford Nanopore")


def test_quality_binned_guard_write_minimal(tmp_path: Path):
    run = _build_run(
        platform="ONT",
        opt_legacy_whole_channel=True,
        signal_codec_overrides={"qualities": Compression.QUALITY_BINNED},
    )
    with pytest.raises(ValueError, match="QUALITY_BINNED"):
        _write_run(tmp_path, run)

    # The same override on a short-read platform writes fine.
    ok = _build_run(
        platform="ILLUMINA",
        opt_legacy_whole_channel=True,
        signal_codec_overrides={"qualities": Compression.QUALITY_BINNED},
    )
    assert _write_run(tmp_path, ok, "ok.tio").exists()


def test_quality_binned_guard_stream_writer(tmp_path: Path):
    from ttio.genomic.stream_writer import GenomicStreamWriter
    from ttio.spectral_dataset import SpectralDataset

    out = tmp_path / "guard.tio"
    SpectralDataset.write_minimal(out, title="", isa_investigation_id="",
                                  runs={})
    with SpectralDataset.open(out, writable=True) as ds:
        with pytest.raises(ValueError, match="QUALITY_BINNED"):
            GenomicStreamWriter(
                ds.study_group, "g",
                acquisition_mode=7, reference_uri="", platform="PacBio HiFi",
                sample_name="",
                signal_codec_overrides={
                    "qualities": Compression.QUALITY_BINNED},
            )


# ---------------------------------------------------------------------------
# @read_role round-trip
# ---------------------------------------------------------------------------

def test_read_role_round_trip_legacy(tmp_path: Path):
    from ttio.spectral_dataset import SpectralDataset

    run = _build_run(platform="PacBio HiFi",
                     opt_legacy_whole_channel=True, read_role="hifi")
    out = _write_run(tmp_path, run)
    with SpectralDataset.open(out) as ds:
        assert ds.genomic_runs["r0"].read_role == "hifi"

    plain = _build_run(opt_legacy_whole_channel=True)
    out2 = _write_run(tmp_path, plain, "plain.tio")
    with SpectralDataset.open(out2) as ds:
        # Absent attribute (pre-M97 file shape) reads back as None.
        assert ds.genomic_runs["r0"].read_role is None


def test_read_role_round_trip_blocks(tmp_path: Path):
    from ttio.genomic.stream_writer import GenomicStreamWriter
    from ttio.spectral_dataset import SpectralDataset

    out = tmp_path / "blocks.tio"
    SpectralDataset.write_minimal(out, title="", isa_investigation_id="",
                                  runs={})
    run = _build_run(platform="ONT")
    with SpectralDataset.open(out, writable=True) as ds:
        w = GenomicStreamWriter(
            ds.study_group, "g",
            acquisition_mode=7, reference_uri=run.reference_uri,
            platform="ONT", sample_name="HG002",
            reference_chrom_seqs=run.reference_chrom_seqs,
            read_role="ont_ul",
        )
        w.append_batch(run)
        w.close()
    import h5py
    with h5py.File(out, "r") as f:
        rg = f["study/genomic_runs/g"]
        assert rg.attrs["read_role"] in ("ont_ul", b"ont_ul")
    with SpectralDataset.open(out) as ds:
        assert ds.genomic_runs["g"].read_role == "ont_ul"


# ---------------------------------------------------------------------------
# REF_DIFF_V2 slice_bytes — codec level
# ---------------------------------------------------------------------------

def test_slice_bytes_codec_byte_budget():
    """Non-uniform boundaries the fixed-count writer cannot produce,
    round-tripped by the unmodified decoder. Mirrors
    native/tests/test_ref_diff_v2_invariants.c test_m97_slice_bytes_policy."""
    n = 40
    ref = _ref_bytes(4096)
    lengths = [20 if r % 2 == 0 else 100 for r in range(n)]
    positions = np.array([r * 60 + 1 for r in range(n)], dtype=np.int64)
    offsets = np.zeros(n + 1, dtype=np.uint64)
    seqs = bytearray()
    for r in range(n):
        start = int(positions[r]) - 1
        read = bytearray(ref[start:start + lengths[r]])
        read[3] = ord("C") if read[3] == ord("A") else ord("A")
        seqs.extend(read)
        offsets[r + 1] = offsets[r] + lengths[r]
    total = int(offsets[n])
    cigars = [f"{L}M" for L in lengths]
    seq_arr = np.frombuffer(bytes(seqs), dtype=np.uint8)
    md5 = bytes(16)

    base = rdv2.encode(seq_arr, offsets, positions, cigars, ref, md5,
                       "m97", reads_per_slice=10_000)
    full = rdv2.encode(seq_arr, offsets, positions, cigars, ref, md5,
                       "m97", reads_per_slice=10_000, slice_bytes=total)
    assert full == base, "full budget must be byte-identical to default"

    budgeted = rdv2.encode(seq_arr, offsets, positions, cigars, ref, md5,
                           "m97", reads_per_slice=10_000, slice_bytes=200)
    assert _n_slices(budgeted) > 1
    assert budgeted != base

    # Non-uniform read counts: parse the 32-byte index entries
    # (num_reads is the u32 at entry offset 28).
    hdr = 38 + len("m97")
    counts = [
        struct.unpack_from("<I", budgeted, hdr + 32 * s + 28)[0]
        for s in range(_n_slices(budgeted))
    ]
    assert sum(counts) == n
    assert len(set(counts)) >= 2, f"uniform counts {counts}"

    out_seq, out_off = rdv2.decode(budgeted, positions, cigars, ref, n, total)
    assert out_seq.tobytes() == bytes(seqs)
    assert out_off.tobytes() == offsets.tobytes()


# ---------------------------------------------------------------------------
# REF_DIFF_V2 slice_bytes — through the writers
# ---------------------------------------------------------------------------

def test_slice_bytes_through_legacy_writer(tmp_path: Path):
    import h5py
    from ttio.spectral_dataset import SpectralDataset

    blob_path = "study/genomic_runs/r0/signal_channels/sequences/refdiff_v2"

    plain = _build_run(opt_legacy_whole_channel=True)
    out = _write_run(tmp_path, plain, "default.tio")
    with h5py.File(out, "r") as f:
        assert _n_slices(bytes(f[blob_path][()])) == 1

    budgeted = _build_run(opt_legacy_whole_channel=True,
                          ref_diff_slice_bytes=100)
    out2 = _write_run(tmp_path, budgeted, "budget.tio")
    with h5py.File(out2, "r") as f:
        # 100-base budget over 40 x 10 bp reads -> 4 slices of 10.
        assert _n_slices(bytes(f[blob_path][()])) == 4

    # The budgeted file round-trips through the ordinary reader.
    with SpectralDataset.open(out2) as ds:
        run = ds.genomic_runs["r0"]
        ref = _ref_bytes()
        for i in range(N):
            start = i * 20
            expect = ref[start:start + READ_LEN].decode("ascii")
            assert run[i].sequence == expect


def test_slice_bytes_through_blocks_writer(tmp_path: Path):
    import h5py
    from ttio.genomic.stream_writer import GenomicStreamWriter
    from ttio.spectral_dataset import SpectralDataset

    out = tmp_path / "blocks.tio"
    SpectralDataset.write_minimal(out, title="", isa_investigation_id="",
                                  runs={})
    run = _build_run()
    with SpectralDataset.open(out, writable=True) as ds:
        w = GenomicStreamWriter(
            ds.study_group, "g",
            acquisition_mode=7, reference_uri=run.reference_uri,
            platform="PacBio HiFi", sample_name="HG002",
            reference_chrom_seqs=run.reference_chrom_seqs,
            ref_diff_slice_bytes=100,
        )
        w.append_batch(run)
        w.close()
    with h5py.File(out, "r") as f:
        rg = f["study/genomic_runs/g"]
        idx = rg["blocks/index"][0]
        codec = int(idx["sequences_codec"])
        assert codec == int(Compression.REF_DIFF_V2)
        off, length = int(idx["sequences_off"]), int(idx["sequences_len"])
        blob = bytes(rg["signal_channels/sequences/data"][off:off + length])
        assert blob[:4] == b"RDF2"
        assert _n_slices(blob) == 4
