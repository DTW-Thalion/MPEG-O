"""WrittenGenomicRun — write-side container for a single genomic run.

Passed to :meth:`ttio.spectral_dataset.SpectralDataset.write_minimal`
via the ``genomic_runs`` parameter. Genomic analogue of
:class:`ttio.spectral_dataset.WrittenRun`.
"""
from __future__ import annotations

from dataclasses import dataclass, field

import numpy as np

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
