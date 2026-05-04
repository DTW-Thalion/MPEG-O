"""Extract mate-info triples from a BAM file for v1<->v2 oracle testing.

Uses ``samtools view`` subprocess (avoids pysam dependency, mirrors
the ObjC CLI approach). Returns the parallel-array shape used by
mate_info_v2.encode():

    (mate_chrom_ids, mate_positions, template_lengths,
     own_chrom_ids, own_positions)

Encounter-order chrom_id assignment matches the L1 contract:
own_chrom_ids[i] = 0xFFFF for unmapped records (FLAG bit 0x4).
"""
from __future__ import annotations

import subprocess
from pathlib import Path

import numpy as np


def extract_mate_triples(bam_path: Path):
    """Return parallel int32/int64/int32/uint16/int64 arrays.

    Calls ``samtools view <bam>`` and parses SAM records line-by-line.
    Encounter-order chrom_id assignment.
    """
    chrom_id_map: dict[str, int] = {}

    def _id_for(name: str) -> int:
        if name not in chrom_id_map:
            chrom_id_map[name] = len(chrom_id_map)
        return chrom_id_map[name]

    own_chrom_ids: list[int] = []
    own_positions: list[int] = []
    mate_chrom_ids: list[int] = []
    mate_positions: list[int] = []
    template_lengths: list[int] = []

    proc = subprocess.Popen(
        ["samtools", "view", str(bam_path)],
        stdout=subprocess.PIPE,
        bufsize=1024 * 1024,  # 1 MB pipe buffer
    )
    assert proc.stdout is not None
    try:
        for raw in proc.stdout:
            line = raw.decode("ascii", errors="replace")
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 9:
                continue
            flag = int(fields[1])
            rname = fields[2]
            pos = int(fields[3])  # 1-based; convert to 0-based
            mrname = fields[6]
            mpos = int(fields[7])  # 1-based; convert to 0-based
            tlen = int(fields[8])

            # own
            if flag & 0x4:  # BAM_FUNMAP
                own_chrom_ids.append(0xFFFF)
                own_positions.append(0)
            else:
                own_chrom_ids.append(_id_for(rname))
                own_positions.append(pos - 1)

            # mate
            if mrname == "*":
                mate_chrom_ids.append(-1)
                mate_positions.append(0)
            else:
                # Resolve '=' to own_chrom_id (matches BAM canonicalisation)
                if mrname == "=":
                    if flag & 0x4:
                        mate_chrom_ids.append(-1)
                    else:
                        mate_chrom_ids.append(_id_for(rname))
                else:
                    mate_chrom_ids.append(_id_for(mrname))
                mate_positions.append(mpos - 1)

            template_lengths.append(tlen)
    finally:
        proc.stdout.close()
        proc.wait()

    if proc.returncode != 0:
        raise RuntimeError(f"samtools view exited with rc={proc.returncode}")

    return (
        np.asarray(mate_chrom_ids, dtype=np.int32),
        np.asarray(mate_positions, dtype=np.int64),
        np.asarray(template_lengths, dtype=np.int32),
        np.asarray(own_chrom_ids, dtype=np.uint16),
        np.asarray(own_positions, dtype=np.int64),
    )


def extract_sequences_for_ref_diff(bam_path: Path):
    """Extract sequences + offsets + positions + cigars from a BAM
    for ref_diff_v2 testing. Skips unmapped reads (no cigar).

    Returns:
        sequences: np.ndarray uint8, concatenated read bytes
        offsets:   np.ndarray uint64, n_reads + 1 entries
        positions: np.ndarray int64, 1-based per-read POS
        cigars:    list[str], per-read CIGAR strings
    """
    sequences_parts: list[bytes] = []
    offsets: list[int] = [0]
    positions: list[int] = []
    cigars: list[str] = []

    proc = subprocess.Popen(
        ["samtools", "view", str(bam_path)],
        stdout=subprocess.PIPE,
        bufsize=1024 * 1024,
    )
    assert proc.stdout is not None
    try:
        cur_offset = 0
        for raw in proc.stdout:
            line = raw.decode("ascii", errors="replace")
            fields = line.rstrip("\n").split("\t")
            if len(fields) < 11:
                continue
            flag = int(fields[1])
            pos = int(fields[3])  # 1-based
            cigar = fields[5]
            seq_str = fields[9]
            if flag & 0x4:  # unmapped
                continue
            if cigar == "*" or seq_str == "*":
                continue
            seq_bytes = seq_str.encode("ascii")
            sequences_parts.append(seq_bytes)
            cur_offset += len(seq_bytes)
            offsets.append(cur_offset)
            positions.append(pos)
            cigars.append(cigar)
    finally:
        proc.stdout.close()
        proc.wait()

    if proc.returncode != 0:
        raise RuntimeError(f"samtools view exited with rc={proc.returncode}")

    full_seq = b"".join(sequences_parts)
    return (
        np.frombuffer(full_seq, dtype=np.uint8).copy(),
        np.asarray(offsets, dtype=np.uint64),
        np.asarray(positions, dtype=np.int64),
        cigars,
    )


def load_chr22_reference(fasta_path: Path) -> bytes:
    """Load the chr22 FASTA reference as a single uppercase ACGTN bytes string.

    Uses a simple line-by-line FASTA parser (skips header line starting with '>').
    For BAM compatibility, returns ALL sequence bytes concatenated; the
    fasta should contain only one chromosome.
    """
    parts: list[bytes] = []
    with open(fasta_path, "rb") as f:
        for line in f:
            if line.startswith(b">"):
                continue
            parts.append(line.strip().upper())
    return b"".join(parts)
