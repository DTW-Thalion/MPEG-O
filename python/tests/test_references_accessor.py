"""Phase 0 Task 0.4 — failing test for ``SpectralDataset.references``.

The library already writes embedded references at
``/study/references/<uri>/`` when a :class:`WrittenGenomicRun` is built
with ``embed_reference=True`` plus a non-None ``reference_chrom_seqs``
mapping (see :func:`ttio.spectral_dataset._embed_references_for_runs`).
What is missing is a public read-back path: this test drives that
addition.

Note on test fixture: the Python writer's embed gate requires either a
context-aware codec override on ``sequences`` or the native ref-diff-v2
library to be available. In CI the native lib is typically absent, so
to keep the test free-standing we write the canonical layout directly
via the same :func:`_embed_references_for_runs` helper that the writer
uses, after a minimal :meth:`SpectralDataset.write_minimal` call. The
on-disk shape this exercises is byte-identical to what the writer
produces when its gate fires (Java/ObjC parity hinges on that shape).

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import numpy as np

from ttio import SpectralDataset
from ttio.genomic.reference_import import ReferenceImport  # re-exported

# We seed /study/references/<uri>/ with the canonical layout via the
# same private helper the writer uses, so the test exercises the
# byte-exact on-disk shape that cross-language conformance depends on.
from ttio.spectral_dataset import _embed_references_for_runs
from ttio.providers.hdf5 import _Group as _H5Group
from ttio.written_genomic_run import WrittenGenomicRun

import h5py


def _seed_references(tio: Path, ref_seqs: dict[str, bytes], uri: str) -> None:
    """Populate /study/references/<uri>/ with the canonical embed shape.

    Builds a synthetic :class:`WrittenGenomicRun` carrying the
    chromosome sequences and a context-aware codec override on
    ``sequences``, which is the writer's documented trigger for
    embedding (independent of native-lib availability).
    """
    from ttio.enums import Compression

    # An empty-read run with embed_reference=True + a context-aware
    # codec override on sequences is enough to drive the embed
    # writer, regardless of whether the native ref-diff-v2 library is
    # installed.
    run = WrittenGenomicRun(
        acquisition_mode=7,  # AcquisitionMode.GENOMIC_WGS
        reference_uri=uri,
        platform="ILLUMINA",
        sample_name="REF_TEST",
        positions=np.zeros(0, dtype=np.int64),
        mapping_qualities=np.zeros(0, dtype=np.uint8),
        flags=np.zeros(0, dtype=np.uint32),
        sequences=np.zeros(0, dtype=np.uint8),
        qualities=np.zeros(0, dtype=np.uint8),
        offsets=np.zeros(0, dtype=np.uint64),
        lengths=np.zeros(0, dtype=np.uint32),
        cigars=[],
        read_names=[],
        mate_chromosomes=[],
        mate_positions=np.zeros(0, dtype=np.int64),
        template_lengths=np.zeros(0, dtype=np.int32),
        chromosomes=[],
        signal_codec_overrides={"sequences": Compression.REF_DIFF_V2},
        reference_chrom_seqs=ref_seqs,
        embed_reference=True,
    )

    with h5py.File(str(tio), "r+") as f:
        study = f["study"]
        _embed_references_for_runs(_H5Group(study), {"_seed": run})


def test_freshly_opened_dataset_exposes_embedded_references(tmp_path):
    tio = tmp_path / "with_refs.tio"
    ref_seqs = {
        "chr1": b"ACGTACGTACGT",
        "chr2": b"TTTTAAAACCCC",
    }

    # Minimal .tio with no genomic runs; we then graft the
    # /study/references/ subtree on via the canonical writer helper.
    SpectralDataset.write_minimal(
        tio,
        title="ref-test",
        isa_investigation_id="REFTEST001",
        runs={},
    )
    _seed_references(tio, ref_seqs, uri="test-ref-v1")

    with SpectralDataset.open(str(tio)) as opened:
        refs = opened.references
        assert refs is not None
        assert list(refs.keys()) == ["test-ref-v1"]
        r = refs["test-ref-v1"]
        # The embed writer sorts chromosome names alphabetically before
        # persisting, so the read-back order is alphabetic.
        assert r.chromosomes == ["chr1", "chr2"]
        assert r.chromosome("chr1") == b"ACGTACGTACGT"
        assert r.chromosome("chr2") == b"TTTTAAAACCCC"
        assert r.total_bases == 24


def test_dataset_without_references_returns_empty_dict(tmp_path):
    tio = tmp_path / "no_refs.tio"
    SpectralDataset.write_minimal(
        tio,
        title="no-ref",
        isa_investigation_id="NOREF001",
        runs={},
    )

    with SpectralDataset.open(str(tio)) as opened:
        refs = opened.references
        assert refs is not None
        assert dict(refs) == {}
