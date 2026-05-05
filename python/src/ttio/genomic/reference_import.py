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

    from ..spectral_dataset import SpectralDataset


__all__ = ["ReferenceImport", "compute_reference_md5"]


def compute_reference_md5(chromosomes: list[str], sequences: list[bytes]) -> bytes:
    """Compute the canonical MD5 over a reference's chromosome set.

    Algorithm (cross-language byte-exact):
        for each (name, seq) in sorted(zip(chromosomes, sequences),
                                       key=name):
            h.update(name_utf8 + b"\\n")
            h.update(seq)
            h.update(b"\\n")
        return h.digest()

    Sorting by name makes the MD5 invariant to FASTA record order.
    Names are encoded UTF-8; sequences are passed through verbatim
    (case-preserving). The trailing ``\\n`` separators are pure
    framing and never appear inside sequence bytes (FASTA forbids
    embedded newlines per record).

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
    for name, seq in items:
        h.update(name.encode("utf-8"))
        h.update(b"\n")
        h.update(seq)
        h.update(b"\n")
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

    def write_to_dataset(
        self,
        dataset: "SpectralDataset",
        *,
        overwrite: bool = False,
    ) -> None:
        """Embed this reference at ``/study/references/<uri>/``
        inside ``dataset``'s open HDF5 file.

        Layout (cross-language byte-equal):

        ``/study/references/<uri>/``
          attr ``md5``: 32-character lowercase hex string
          attr ``total_bases``: int64 sum of sequence lengths
          ``chromosomes/<name>/data``  uint8 dataset of the
              chromosome's sequence bytes (case-preserving, no
              newlines).

        Parameters
        ----------
        dataset : SpectralDataset
            Open dataset (writable HDF5 backing).
        overwrite : bool
            If ``True``, replace any existing reference under the same
            URI; if ``False``, raise on collision.

        Raises
        ------
        FileExistsError
            If a reference with the same ``uri`` is already embedded
            and ``overwrite`` is ``False``.
        RuntimeError
            If ``dataset``'s storage backend doesn't expose an open
            HDF5 group (only HDF5-backed datasets support reference
            embed).
        """
        import numpy as np

        h5 = getattr(dataset, "file", None)
        if h5 is None:
            raise RuntimeError(
                "ReferenceImport.write_to_dataset requires an "
                "HDF5-backed dataset; got "
                f"{type(dataset).__name__} with no .file handle."
            )
        path = f"/study/references/{self.uri}"
        if path in h5:
            if not overwrite:
                raise FileExistsError(
                    f"reference {self.uri!r} already embedded at {path}; "
                    f"pass overwrite=True to replace."
                )
            del h5[path]
        ref_grp = h5.create_group(path)
        ref_grp.attrs["md5"] = self.md5.hex().encode("ascii")
        ref_grp.attrs["total_bases"] = np.int64(self.total_bases)
        chrom_grp = ref_grp.create_group("chromosomes")
        for name, seq in zip(self.chromosomes, self.sequences):
            sub = chrom_grp.create_group(name)
            sub.create_dataset(
                "data",
                data=np.frombuffer(seq, dtype=np.uint8),
                compression="gzip",
            )
