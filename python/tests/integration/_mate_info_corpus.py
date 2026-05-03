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
