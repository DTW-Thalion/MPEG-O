"""WrittenGenomicRun — write-side container for a single genomic run.

Passed to :meth:`ttio.spectral_dataset.SpectralDataset.write_minimal`
via the ``genomic_runs`` parameter. Genomic analogue of
:class:`ttio.spectral_dataset.WrittenRun`.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from .enums import Compression
from .provenance import ProvenanceRecord


@dataclass(slots=True)
class WrittenGenomicRun:
    """Data container for writing a genomic run via SpectralDataset."""

    acquisition_mode: int             # AcquisitionMode.GENOMIC_WGS or _WES (.value)
    reference_uri: str                # e.g., "GRCh38.p14"
    platform: str                     # e.g., "ILLUMINA"
    sample_name: str                  # e.g., "NA12878"

    # Per-read parallel arrays (all length == read_count)
    positions: np.ndarray             # int64
    mapping_qualities: np.ndarray     # uint8
    flags: np.ndarray                 # uint32

    # Concatenated signal data
    sequences: np.ndarray             # uint8 — one ASCII byte per base (M82)
    qualities: np.ndarray             # uint8 — Phred scores, concatenated

    # Per-read offsets into sequences/qualities
    offsets: np.ndarray               # uint64
    lengths: np.ndarray               # uint32

    # Per-read variable-length fields
    cigars: list[str]                 # one CIGAR string per read
    read_names: list[str]             # one read name per read

    # Mate info (per-read)
    mate_chromosomes: list[str]
    mate_positions: np.ndarray        # int64 (-1 if unpaired)
    template_lengths: np.ndarray      # int32 (0 if unpaired)

    # Chromosomes (per-read, for the index)
    chromosomes: list[str]

    # Optional
    provenance_records: list[ProvenanceRecord] = field(default_factory=list)
    signal_compression: str = "gzip"  # "gzip" → ZLIB; "none" → NONE

    # M86: per-channel codec opt-in. Maps channel name to a TTI-O
    # internal codec id. Only "sequences" and "qualities" are
    # accepted; only RANS_ORDER0, RANS_ORDER1, BASE_PACK are
    # accepted as codec values. Channels not in this dict use the
    # existing signal_compression string path.
    signal_codec_overrides: dict[str, Compression] = field(default_factory=dict)

    # M93 v1.2 — reference embed for the REF_DIFF codec on the
    # ``sequences`` channel. When ``embed_reference=True`` AND a
    # REF_DIFF override is set on ``sequences``, the writer embeds
    # the chromosome sequences provided in ``reference_chrom_seqs``
    # at ``/study/references/<reference_uri>/`` in the output file.
    # When ``embed_reference=False`` (the default since L3, Task #82
    # Phase B.1, 2026-05-01), the writer records ``reference_uri``
    # and ``reference_md5`` only and expects the reader to resolve
    # via REF_PATH or an explicit external path.
    #
    # The default flipped to ``False`` to match CRAM 3.1's default
    # (external reference) and to drop the ~10 MB chr22 reference
    # blob from the v1.2.0 chr22 benchmark; users who want
    # self-contained files set ``embed_reference=True`` explicitly.
    embed_reference: bool = False

    # Mapping ``chromosome_name → uppercase ACGTN bytes``, supplied at
    # write time for any chromosome that has at least one read aligned
    # to it. Required when ``embed_reference=True`` and REF_DIFF is
    # selected on the ``sequences`` channel; otherwise REF_DIFF falls
    # back to BASE_PACK per design spec Q5b.
    reference_chrom_seqs: dict[str, bytes] | None = None

    # External reference path stamped into the file's metadata for
    # decoder fallback when the embedded reference is absent. The
    # writer never reads this path; it is metadata only.
    external_reference_path: Path | None = None
