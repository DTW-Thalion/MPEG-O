"""Deterministic WrittenGenomicRun builder shared by the streaming tests.

Reads are copied from a synthetic reference with a ~2% substitution rate
so REF_DIFF_V2 engages when ``with_reference=True``; qualities vary per
read so the fqzcomp auto-tune has something to model.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import numpy as np

from ttio.written_genomic_run import WrittenGenomicRun


def make_written_genomic_run(n_reads: int, read_len: int, *,
                             with_reference: bool = False,
                             chromosomes: list[str] | None = None,
                             paired: bool = False,
                             mate_chromosomes: list[str] | None = None,
                             seed: int = 7) -> WrittenGenomicRun:
    rng = np.random.default_rng(seed)
    if chromosomes is None:
        chromosomes = ["chr1"] * n_reads
    assert len(chromosomes) == n_reads
    positions = (np.arange(n_reads) * 10 + 1).astype(np.int64)
    ref_len = int(positions[-1]) + read_len + 100
    ref_bytes = bytes(ord("ACGT"[int(x)]) for x in rng.integers(0, 4, ref_len))
    seqs = bytearray()
    for i in range(n_reads):
        start = int(positions[i]) - 1
        read = bytearray(ref_bytes[start:start + read_len])
        for j in range(read_len):
            if int(rng.integers(0, 50)) == 0:
                read[j] = b"ACGT"[(b"ACGT".index(read[j]) + 1) % 4]
        seqs.extend(read)
    quals = np.clip(rng.normal(32, 4, n_reads * read_len).astype(np.int64), 2, 41).astype(np.uint8)
    flags = np.where(np.arange(n_reads) % 2 == 0, 0, 16).astype(np.uint32)
    if paired:
        flags = (flags | 1 | np.where(np.arange(n_reads) % 2 == 0, 64, 128)).astype(np.uint32)
        mate_chroms = [chromosomes[i ^ 1] if (i ^ 1) < n_reads else "*" for i in range(n_reads)]
        mate_pos = np.array([int(positions[i ^ 1]) if (i ^ 1) < n_reads else -1 for i in range(n_reads)],
                            dtype=np.int64)
        tlen = np.array([(int(positions[i ^ 1]) - int(positions[i])) if (i ^ 1) < n_reads else 0
                         for i in range(n_reads)], dtype=np.int32)
    else:
        mate_chroms = ["*"] * n_reads
        mate_pos = np.full(n_reads, -1, dtype=np.int64)
        tlen = np.zeros(n_reads, dtype=np.int32)
    if mate_chromosomes is not None:
        assert len(mate_chromosomes) == n_reads
        mate_chroms = list(mate_chromosomes)
    kw = {}
    if with_reference:
        kw = {"reference_chrom_seqs": {c: ref_bytes for c in sorted(set(chromosomes))},
              "embed_reference": True}
    return WrittenGenomicRun(
        acquisition_mode=7,
        reference_uri="synthetic.ref",
        platform="ILLUMINA",
        sample_name="SYN",
        positions=positions,
        mapping_qualities=np.full(n_reads, 60, dtype=np.uint8),
        flags=flags,
        sequences=np.frombuffer(bytes(seqs), dtype=np.uint8),
        qualities=quals,
        offsets=(np.arange(n_reads, dtype=np.uint64) * read_len),
        lengths=np.full(n_reads, read_len, dtype=np.uint32),
        cigars=[f"{read_len}M"] * n_reads,
        read_names=[f"r{i}" for i in range(n_reads)],
        mate_chromosomes=mate_chroms,
        mate_positions=mate_pos,
        template_lengths=tlen,
        chromosomes=list(chromosomes),
        **kw,
    )
