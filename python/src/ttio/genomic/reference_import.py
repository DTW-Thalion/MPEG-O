"""Reference-FASTA value class and embedding helpers.

A ``ReferenceImport`` is the parsed result of a reference-FASTA file
(many short or long chromosome records, no quality scores). It carries
the chromosome names, per-chromosome sequence bytes, and a content-MD5
suitable for the ``@md5`` attribute on
``/study/references/<uri>/`` groups inside a ``.tio`` container.

The same value class is produced by :class:`ttio.importers.fasta.FastaReader`
and consumed by :class:`ttio.exporters.fasta.FastaWriter`, so a
FASTA -> .tio -> FASTA round-trip preserves chromosome names, byte
contents (case-preserving), and MD5.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOReferenceImport`` ·
Java: ``global.thalion.ttio.genomic.ReferenceImport``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import hashlib
from dataclasses import dataclass, field
from typing import TYPE_CHECKING

if TYPE_CHECKING:  # pragma: no cover
    from pathlib import Path

    from ..io.progress import ProgressSinkLike
    from ..providers.base import StorageGroup
    from ..spectral_dataset import SpectralDataset


__all__ = ["ReferenceImport", "compute_reference_md5"]


def compute_reference_md5(chromosomes: list[str], sequences: list[bytes]) -> bytes:
    """Compute the canonical MD5 over a reference's chromosome set.

    Algorithm (cross-language byte-exact):
        for each (name, seq) in sorted(zip(chromosomes, sequences),
                                       key=name):
            h.update(seq)
        return h.digest()

    Sorting by name makes the MD5 invariant to FASTA record order;
    sequence bytes are concatenated verbatim (case-preserving) without
    any framing. This is the single canonical form used both by the
    REF_DIFF_V2 auto-embed writer (``_reference_md5_for_run``) and by
    the FASTA-import path's ``@md5`` stamping — unified in v1.1.0
    (previously the FASTA-import / public-helper path used a
    name-framed form that disagreed with the writer; see CHANGELOG).

    Returns
    -------
    bytes
        16-byte MD5 digest.
    """
    if len(chromosomes) != len(sequences):
        raise ValueError(
            f"chromosome / sequence length mismatch: "
            f"{len(chromosomes)} names vs {len(sequences)} sequences"
        )
    items = sorted(zip(chromosomes, sequences), key=lambda kv: kv[0])
    h = hashlib.md5()
    for _name, seq in items:
        h.update(seq)
    return h.digest()


@dataclass(slots=True)
class ReferenceImport:
    """Reference-FASTA contents staged for embedding into a ``.tio`` container.

    Parameters
    ----------
    uri : str
        Reference identifier (e.g. ``"GRCh38.p14"``). Becomes the
        sub-group name under ``/study/references/<uri>/``.
    chromosomes : list[str]
        Chromosome names in FASTA file order. The on-disk MD5 is
        order-invariant (see :func:`compute_reference_md5`).
    sequences : list[bytes]
        Per-chromosome sequence bytes, one entry per chromosome,
        case-preserved. Newlines and whitespace stripped.
    md5 : bytes
        16-byte content MD5 (see :func:`compute_reference_md5`). If
        omitted, computed from ``chromosomes`` + ``sequences``.

    Notes
    -----
    A round-trip FASTA -> :class:`FastaReader` -> ``ReferenceImport``
    -> :class:`FastaWriter` -> FASTA preserves byte content
    (including soft-masking via lowercase). The Reference Resolver's
    upper-casing for REF_DIFF_V2 is a separate normalisation that
    happens at decode time.
    """

    uri: str
    chromosomes: list[str]
    sequences: list[bytes]
    md5: bytes = field(default=b"")

    def __post_init__(self) -> None:
        if not self.md5:
            self.md5 = compute_reference_md5(self.chromosomes, self.sequences)
        if len(self.md5) != 16:
            raise ValueError(
                f"md5 must be 16 bytes, got {len(self.md5)}"
            )
        if len(self.chromosomes) != len(self.sequences):
            raise ValueError(
                f"chromosomes / sequences length mismatch: "
                f"{len(self.chromosomes)} vs {len(self.sequences)}"
            )

    @property
    def total_bases(self) -> int:
        """Sum of sequence lengths across all chromosomes."""
        return sum(len(s) for s in self.sequences)

    def chromosome(self, name: str) -> bytes:
        """Return the named chromosome's sequence bytes.

        Raises
        ------
        KeyError
            If ``name`` is not in this reference.
        """
        for n, s in zip(self.chromosomes, self.sequences):
            if n == name:
                return s
        raise KeyError(
            f"chromosome {name!r} not present in reference {self.uri!r} "
            f"(known: {sorted(self.chromosomes)})"
        )

    @classmethod
    def read_from_group(cls, ref_group: "StorageGroup") -> "ReferenceImport":
        """Read an embedded reference from ``/study/references/<uri>/``.

        Inverse of :func:`ttio.spectral_dataset._embed_references_for_runs`.
        Per-chromosome sequences live at
        ``<uri>/chromosomes/<name>/data`` (UINT8); the URI group
        carries ``@reference_uri`` (the canonical URI string) and
        ``@md5`` (32-character lowercase hex). The MD5 is preserved
        verbatim from the on-disk attribute when present, so the
        read-back value carries the same digest bytes the writer used —
        load-bearing for cross-language byte-exact round-trip. When the
        attribute is absent or malformed, the constructor falls back to
        recomputing via :func:`compute_reference_md5`.

        Chromosome names are returned in the order
        :meth:`StorageGroup.child_names` yields them, which for the
        canonical writer is alphabetic (the embed helper sorts before
        persisting).

        Cross-language equivalents
        --------------------------
        Java: ``ReferenceImport.readFromGroup(StorageGroup)``.

        :since: 1.1.0
        """
        from .. import _hdf5_io as io

        # URI: prefer @reference_uri, fall back to the leaf group name.
        uri = io.read_string_attr(ref_group, "reference_uri", default=None)
        if not uri:
            # StorageGroup.name gives the full path for HDF5; take the
            # leaf to mirror Java's refGroup.name() semantics.
            full = ref_group.name
            uri = full.rsplit("/", 1)[-1] if "/" in full else full

        # MD5: read @md5 (lowercase hex string) verbatim. Parse to 16
        # bytes; on absence or malformed input, leave as empty so the
        # ReferenceImport constructor recomputes from sequences.
        md5_bytes = b""
        md5_hex = io.read_string_attr(ref_group, "md5", default=None)
        if md5_hex and len(md5_hex) == 32:
            try:
                md5_bytes = bytes.fromhex(md5_hex)
            except ValueError:
                md5_bytes = b""

        from . import packed_reference

        chrom_names: list[str] = []
        sequences: list[bytes] = []
        chroms_grp = ref_group.open_group("chromosomes")
        try:
            for name in chroms_grp.child_names():
                chrom_grp = chroms_grp.open_group(name)
                try:
                    # Dispatches on layout: data_packed (2-bit + run
                    # mask) when present, legacy raw data otherwise.
                    chrom_names.append(name)
                    sequences.append(
                        packed_reference.read_chromosome_bytes(chrom_grp))
                finally:
                    chrom_grp.close()
        finally:
            chroms_grp.close()

        return cls(
            uri=uri,
            chromosomes=chrom_names,
            sequences=sequences,
            md5=md5_bytes,
        )

    def write_to_dataset(
        self,
        dataset: "SpectralDataset",
        *,
        overwrite: bool = False,
        progress: "ProgressSinkLike | None" = None,
    ) -> None:
        """Embed this reference at ``/study/references/<uri>/``
        inside ``dataset``'s open HDF5 file.

        Layout (cross-language byte-equal — matches Java's
        ``SpectralDataset.embedReferencesForRuns`` and Python's
        :func:`ttio.spectral_dataset._embed_references_for_runs`,
        the canonical writer used by ``embedReference=True`` runs):

        ``/study/references/<uri>/``
          attr ``md5`` : 32-character lowercase hex string.
          attr ``reference_uri`` : the URI string (mirrors the leaf
              path; ``read_from_group`` falls back to the leaf when
              absent, but the canonical writer always emits this).
          ``chromosomes/<name>/`` one sub-group per chromosome, in
              alphabetic order:

            attr ``length`` : int64 sequence length in bytes.
            ``data_packed`` : UINT8 dataset holding the 2-bit + run-mask
                packed stream (``packed_reference`` layout), ZLIB-
                compressed — written when packing beats the raw bytes.
            ``data`` : UINT8 dataset of the chromosome's raw sequence
                bytes (case-preserving, no newlines), ZLIB-compressed —
                the fallback when packing does not win (soft-masked or
                IUPAC-dense sequences), and the only layout pre-change
                readers understand.

        ``@total_bases`` (a v1.1.0-era attribute written here only,
        never by the canonical embed-helper / Java writer) is no
        longer emitted; ``ReferenceImport.read_from_group`` recomputes
        it from the per-chromosome data, so the on-disk attribute
        carried no information that wasn't also derivable.

        Parameters
        ----------
        dataset : SpectralDataset
            Open dataset (writable HDF5 backing).
        overwrite : bool
            If ``True``, replace any existing reference under the same
            URI; if ``False``, raise on collision.
        progress : ProgressSinkLike or None
            Optional runtime progress callback. Fires ``(0, N)`` before
            the embed loop then ``(i+1, N)`` after each contig (N =
            sorted contig count), mirroring Java's
            ``ReferenceImport.writeToDataset(..., ProgressSink)``. A
            bare ``(done, total) -> None`` callable is also accepted.
            Progress is a runtime callback only -- no on-disk change.

        Raises
        ------
        FileExistsError
            If a reference with the same ``uri`` is already embedded
            and ``overwrite`` is ``False``.
        RuntimeError
            If ``dataset``'s storage backend doesn't expose a provider
            (an open dataset always does).
        """
        from .. import _hdf5_io as io
        from ..io.progress import _fire
        from . import packed_reference

        provider = getattr(dataset, "provider", None)
        if provider is None:
            raise RuntimeError(
                "ReferenceImport.write_to_dataset requires a "
                "provider-backed dataset; got "
                f"{type(dataset).__name__} with no .provider."
            )
        root = provider.root_group()
        study = (
            root.open_group("study")
            if root.has_child("study")
            else root.create_group("study")
        )
        references = (
            study.open_group("references")
            if study.has_child("references")
            else study.create_group("references")
        )
        path = f"/study/references/{self.uri}"
        if references.has_child(self.uri):
            if not overwrite:
                raise FileExistsError(
                    f"reference {self.uri!r} already embedded at {path}; "
                    f"pass overwrite=True to replace."
                )
            references.delete_child(self.uri)

        # Write through the StorageGroup protocol so the attribute layout
        # (NULLTERM fixed-length strings via write_fixed_string_attr,
        # int64 via write_int_attr) matches the canonical embed-helper
        # writer and Java's embedReferencesForRuns byte-for-byte.
        ref_grp = references.create_group(self.uri)
        io.write_fixed_string_attr(ref_grp, "md5", self.md5.hex())
        io.write_fixed_string_attr(ref_grp, "reference_uri", self.uri)
        chroms_grp = ref_grp.create_group("chromosomes")
        # Sort alphabetically so the on-disk child order matches what
        # the canonical writer emits (read_from_group surfaces names in
        # on-disk order).
        sorted_names = sorted(self.chromosomes)
        total = len(sorted_names)
        # Mirror Java ReferenceImport.writeToDataset: (0, N) then
        # (i+1, N) per contig. Progress is a runtime callback only.
        _fire(progress, 0, total)
        for i, name in enumerate(sorted_names):
            seq = self.chromosome(name)
            c = chroms_grp.create_group(name)
            io.write_int_attr(c, "length", len(seq))
            packed_reference.write_chromosome_dataset(c, seq)
            _fire(progress, i + 1, total)
