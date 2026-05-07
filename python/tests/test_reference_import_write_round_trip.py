"""Phase 0 Task 0.10 — round-trip + canonical-layout tests for
``ReferenceImport.write_to_dataset`` against
``ReferenceImport.read_from_group``.

Before this fix, ``write_to_dataset`` produced a layout with a
``@total_bases`` attribute on the URI group but **no**
``@reference_uri`` and **no** per-chromosome ``@length`` attributes,
diverging from the canonical embed layout that
:func:`_embed_references_for_runs` writes (and that
``ReferenceImport.read_from_group`` consumes).

The reader ``read_from_group`` papers over the missing
``@reference_uri`` by falling back to the leaf group name, so a
plain round-trip alone passes even with the divergent layout. The
locked-down canonical-layout test below catches the missing
``@reference_uri`` and per-chromosome ``@length`` directly, mirroring
what :func:`_embed_references_for_runs` (the canonical writer used
by ``embedReference=True`` runs) produces, and what Java's
``embedReferencesForRuns`` writes for cross-language byte-equality.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from pathlib import Path

import h5py

from ttio.genomic.reference_import import ReferenceImport
from ttio.spectral_dataset import SpectralDataset


def _embed_via_write_to_dataset(tio_path: Path, ri: ReferenceImport) -> None:
    SpectralDataset.write_minimal(
        tio_path, title="", isa_investigation_id="", runs={},
    )
    with SpectralDataset.open(tio_path, writable=True) as ds:
        ri.write_to_dataset(ds)


def test_write_to_dataset_round_trips_through_read_from_group(
    tmp_path: Path,
) -> None:
    """``ReferenceImport`` -> ``write_to_dataset`` -> reopened
    ``SpectralDataset.references`` -> equivalent ``ReferenceImport``.

    Asserts byte-equality on uri, chromosome names + bytes,
    ``total_bases``, and 16-byte MD5.
    """
    tio_path = tmp_path / "round_trip.tio"
    chrom_names = ["chr1", "chr2"]
    sequences = [b"ACGTACGTACGT", b"TTTTAAAACCCC"]

    ri_in = ReferenceImport(
        uri="round-trip-v1",
        chromosomes=list(chrom_names),
        sequences=list(sequences),
    )

    _embed_via_write_to_dataset(tio_path, ri_in)

    # Read the reference back through the canonical Phase 0 reader.
    with SpectralDataset.open(tio_path) as ds_back:
        refs = ds_back.references
        assert list(refs.keys()) == ["round-trip-v1"]
        ri_out = refs["round-trip-v1"]

    # Same uri.
    assert ri_out.uri == ri_in.uri

    # Same chromosomes, same byte content. The canonical embed sorts
    # alphabetically before persisting; the input is already
    # alphabetic, so ordering matches.
    assert ri_out.chromosomes == chrom_names
    for name, expected in zip(chrom_names, sequences):
        assert ri_out.chromosome(name) == expected

    # Same derived totals.
    assert ri_out.total_bases == ri_in.total_bases

    # MD5 preserved verbatim through the on-disk @md5 attribute.
    assert ri_out.md5 == ri_in.md5
    assert len(ri_out.md5) == 16


def test_write_to_dataset_emits_canonical_layout(tmp_path: Path) -> None:
    """Lock the on-disk shape that Java + the embed-helper writer share.

    The canonical layout (see :func:`_embed_references_for_runs` and
    Java ``SpectralDataset.embedReferencesForRuns``) carries:

        ``/study/references/<uri>/``
          attr ``md5``           = 32-char lowercase hex
          attr ``reference_uri`` = the URI (mirrors leaf path)
          ``chromosomes/<name>/``
            attr ``length``      = int64 sequence length
            ``data``             = UINT8 dataset of sequence bytes

    No ``@total_bases`` attribute (it's a derived view recomputed at
    read time). This test guards against drift in either direction.
    """
    tio_path = tmp_path / "canonical.tio"
    ri = ReferenceImport(
        uri="canon-v1",
        chromosomes=["chr1", "chr2"],
        sequences=[b"ACGTACGTACGT", b"TTTTAAAACCCC"],
    )
    _embed_via_write_to_dataset(tio_path, ri)

    with h5py.File(str(tio_path), "r") as f:
        ref_grp = f["/study/references/canon-v1"]

        # @md5: 32-char lowercase hex.
        md5_attr = ref_grp.attrs["md5"]
        if isinstance(md5_attr, bytes):
            md5_attr = md5_attr.decode("ascii")
        assert isinstance(md5_attr, str)
        assert len(md5_attr) == 32
        assert md5_attr == md5_attr.lower()
        assert bytes.fromhex(md5_attr) == ri.md5

        # @reference_uri: matches the path leaf.
        assert "reference_uri" in ref_grp.attrs, (
            "canonical embed layout requires @reference_uri on the "
            "URI group; missing here means write_to_dataset is "
            "diverging from _embed_references_for_runs / Java's "
            "embedReferencesForRuns."
        )
        ru_attr = ref_grp.attrs["reference_uri"]
        if isinstance(ru_attr, bytes):
            ru_attr = ru_attr.decode("ascii")
        assert ru_attr == "canon-v1"

        # No @total_bases on the canonical layout (Q: derived view).
        assert "total_bases" not in ref_grp.attrs, (
            "@total_bases is not part of the canonical embed layout; "
            "it is recomputed at read time. Found here means "
            "write_to_dataset still emits the legacy attribute."
        )

        # Per-chromosome @length and data dataset.
        chroms_grp = ref_grp["chromosomes"]
        for name, seq in zip(ri.chromosomes, ri.sequences):
            c = chroms_grp[name]
            assert "length" in c.attrs, (
                f"canonical embed layout requires @length on each "
                f"chromosome sub-group; missing on {name!r}."
            )
            assert int(c.attrs["length"]) == len(seq)
            assert "data" in c
            assert bytes(c["data"][:].tobytes()) == seq
