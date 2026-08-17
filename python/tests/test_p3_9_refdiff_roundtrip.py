"""P3.9 byte-parity characterization test for the REF_DIFF decode path.

This is the fence for the P3.9 PR-4 refactor that migrates
:class:`ttio.genomic.reference_resolver.ReferenceResolver` off raw h5py
onto the :class:`~ttio.providers.base.StorageGroup` protocol.

It builds a genomic run with an embedded reference and reads with a
non-zero substitution rate (so REF_DIFF_V2 decode must actually consult
the resolved reference sequence to reconstruct the reads), writes it via
the public ``SpectralDataset`` writer, re-opens, and asserts the decoded
read sequences are byte-identical to the input. The decoded bytes MUST
remain identical before and after the refactor.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

# These tests exercise the v1.8 whole-channel layout (per-AU and region
# encryption slice plaintext channels, per-dataset signatures and the
# refdiff_v2 group shape); every genomic write in this module uses it.
pytestmark = pytest.mark.usefixtures("legacy_genomic_layout")

from ttio.codecs import ref_diff_v2 as rdv2
from ttio.enums import Compression

if not rdv2.HAVE_NATIVE_LIB:
    pytest.skip(
        "requires native libttio_rans.so via TTIO_RANS_LIB_PATH",
        allow_module_level=True,
    )

N = 40
READ_LEN = 100
TOTAL_BASES = N * READ_LEN


def _build_run_with_subs(seed: int = 7):
    """Build a WrittenGenomicRun whose reads differ from the reference.

    A ~2% per-base substitution rate guarantees the REF_DIFF_V2 decode
    path reconstructs each read from the resolved reference plus the
    encoded diffs, exercising the ReferenceResolver end-to-end.
    """
    from ttio.written_genomic_run import WrittenGenomicRun

    rng = np.random.default_rng(seed)
    positions = (np.arange(N) * 50 + 1).astype(np.int64)
    chromosomes = ["22"] * N
    cigars = [f"{READ_LEN}M"] * N

    ref_len = int(positions[-1]) + READ_LEN + 100
    ref_bytes = bytes(ord("ACGT"[i % 4]) for i in range(ref_len))
    reference_chrom_seqs = {"22": ref_bytes}

    sequences_parts = bytearray()
    for i in range(N):
        ref_start = int(positions[i]) - 1  # 0-based
        read = bytearray(ref_bytes[ref_start:ref_start + READ_LEN])
        for j in range(READ_LEN):
            if int(rng.integers(0, 50)) == 0:  # ~2% sub rate
                idx = b"ACGT".index(read[j])
                read[j] = b"ACGT"[(idx + 1) % 4]
        sequences_parts.extend(read)
    seq_bytes = bytes(sequences_parts)
    qual_bytes = bytes([30] * TOTAL_BASES)

    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="GRCh38.p3_9_test",
        platform="ILLUMINA",
        sample_name="P3_9_TEST",
        positions=positions,
        mapping_qualities=np.full(N, 60, dtype=np.uint8),
        flags=np.zeros(N, dtype=np.uint32),
        sequences=np.frombuffer(seq_bytes, dtype=np.uint8),
        qualities=np.frombuffer(qual_bytes, dtype=np.uint8),
        offsets=np.arange(N, dtype=np.uint64) * READ_LEN,
        lengths=np.full(N, READ_LEN, dtype=np.uint32),
        cigars=cigars,
        read_names=[f"r{i}" for i in range(N)],
        mate_chromosomes=["*"] * N,
        mate_positions=np.zeros(N, dtype=np.int64),
        template_lengths=np.zeros(N, dtype=np.int32),
        chromosomes=chromosomes,
        reference_chrom_seqs=reference_chrom_seqs,
        embed_reference=True,
    )


def _decode_all_sequences(grun) -> bytes:
    out = bytearray()
    for i in range(len(grun)):
        seq = grun[i].sequence
        out.extend(seq.encode("ascii") if isinstance(seq, str) else bytes(seq))
    return bytes(out)


def test_refdiff_v2_embedded_reference_roundtrip_byte_identical(tmp_path: Path):
    from ttio.spectral_dataset import SpectralDataset

    run = _build_run_with_subs()
    expected_seq = bytes(run.sequences.tobytes())

    out = tmp_path / "p3_9_rt.tio"
    SpectralDataset.write_minimal(
        out,
        title="p3_9_test",
        isa_investigation_id="P39001",
        runs={},
        genomic_runs={"r0": run},
    )

    # Confirm the v2 (refdiff) group layout was actually produced, so the
    # decode path under test is the embedded-reference REF_DIFF path.
    import h5py
    with h5py.File(out, "r") as f:
        seq_node = f["study/genomic_runs/r0/signal_channels/sequences"]
        assert isinstance(seq_node, h5py.Group), "expected REF_DIFF_V2 group layout"
        assert int(seq_node["refdiff_v2"].attrs["compression"]) == int(
            Compression.REF_DIFF_V2
        )

    ds = SpectralDataset.open(out)
    try:
        grun = ds.genomic_runs["r0"]
        assert len(grun) == N
        decoded = _decode_all_sequences(grun)
    finally:
        ds.close()

    assert decoded == expected_seq
