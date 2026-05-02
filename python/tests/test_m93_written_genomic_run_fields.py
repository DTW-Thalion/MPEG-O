"""Smoke tests for the M93 additions to WrittenGenomicRun."""
from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from ttio import WrittenGenomicRun
from ttio.enums import AcquisitionMode, Compression


def _minimal_run(**overrides):
    """Build a minimal valid WrittenGenomicRun, allow callers to override."""
    base = dict(
        acquisition_mode=int(AcquisitionMode.GENOMIC_WGS),
        reference_uri="test-uri",
        platform="ILLUMINA",
        sample_name="test_sample",
        positions=np.array([1], dtype=np.int64),
        mapping_qualities=np.array([60], dtype=np.uint8),
        flags=np.array([0], dtype=np.uint32),
        sequences=np.frombuffer(b"ACGT", dtype=np.uint8),
        qualities=np.full(4, 30, dtype=np.uint8),
        offsets=np.array([0], dtype=np.uint64),
        lengths=np.array([4], dtype=np.uint32),
        cigars=["4M"],
        read_names=["r0"],
        mate_chromosomes=["*"],
        mate_positions=np.array([-1], dtype=np.int64),
        template_lengths=np.array([0], dtype=np.int32),
        chromosomes=["22"],
    )
    base.update(overrides)
    return WrittenGenomicRun(**base)


def test_default_embed_reference_is_false():
    # L3 (Task #82 Phase B.1, 2026-05-01): the default flipped from
    # True to False so chr22-style benchmarks don't carry the ~10 MB
    # embedded reference blob by default. CRAM 3.1's default is also
    # external-reference; users that want self-contained .tio files
    # set embed_reference=True explicitly.
    r = _minimal_run()
    assert r.embed_reference is False
    assert r.reference_chrom_seqs is None
    assert r.external_reference_path is None


def test_embed_reference_can_be_enabled():
    r = _minimal_run(embed_reference=True)
    assert r.embed_reference is True


def test_reference_chrom_seqs_accepts_dict():
    r = _minimal_run(reference_chrom_seqs={"22": b"ACGTACGT"})
    assert r.reference_chrom_seqs == {"22": b"ACGTACGT"}


def test_external_reference_path_accepts_pathlib():
    p = Path("/some/where/ref.fa")
    r = _minimal_run(external_reference_path=p)
    assert r.external_reference_path == p


def test_signal_codec_overrides_accepts_ref_diff():
    r = _minimal_run(
        signal_codec_overrides={"sequences": Compression.REF_DIFF},
        reference_chrom_seqs={"22": b"ACGT"},
    )
    assert r.signal_codec_overrides == {"sequences": Compression.REF_DIFF}
