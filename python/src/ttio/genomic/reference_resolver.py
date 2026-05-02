"""Reference resolver for the M93 REF_DIFF codec.

Lookup chain (per Q5c = hard error in the M93 design spec):

    embedded /study/references/<uri>/ in the open .tio file
        → external REF_PATH env var (or explicit external_reference_path=)
        → RefMissingError (no partial decode).

The resolver yields a chromosome's full uppercase ACGTN bytes. The
encoded MD5 attribute on the embedded reference group is verified
against the ``expected_md5`` argument; mismatches raise
:class:`RefMissingError` rather than silently returning the wrong
sequence.

Cross-language: ObjC ``TTIOReferenceResolver``; Java
``codecs.ReferenceResolver``.
"""
from __future__ import annotations

import hashlib
import os
from pathlib import Path
from typing import TYPE_CHECKING

import numpy as np

if TYPE_CHECKING:  # pragma: no cover — annotation only
    import h5py


def _hex_str_attr(raw: object) -> str:
    """Coerce an h5py attribute (bytes / numpy scalar / str) to a hex str."""
    if isinstance(raw, bytes):
        return raw.decode("ascii")
    if isinstance(raw, np.bytes_):
        return raw.tobytes().decode("ascii")
    if isinstance(raw, str):
        return raw
    if isinstance(raw, np.ndarray) and raw.size == 1:
        item = raw.item()
        if isinstance(item, bytes):
            return item.decode("ascii")
        return str(item)
    return str(raw)


class RefMissingError(RuntimeError):
    """Raised when a reference required for REF_DIFF decode cannot be resolved.

    Per M93 design spec Q5c: hard error rather than partial decode.
    Genomic data integrity is non-negotiable.
    """


class ReferenceResolver:
    """Resolve a reference chromosome sequence for REF_DIFF decode.

    Args:
        h5_file: open ``h5py.File`` handle in read mode. The resolver
            looks for ``/study/references/<uri>/`` as the primary source.
        external_reference_path: optional explicit path to a FASTA file.
            If unset, the ``REF_PATH`` environment variable is consulted.
    """

    def __init__(
        self,
        h5_file: "h5py.File",
        external_reference_path: Path | None = None,
    ):
        self._h5 = h5_file
        self._external = external_reference_path or self._env_path()

    @staticmethod
    def _env_path() -> Path | None:
        ref_path = os.environ.get("REF_PATH")
        return Path(ref_path) if ref_path else None

    def resolve(self, uri: str, expected_md5: bytes, chromosome: str) -> bytes:
        """Return the chromosome's reference sequence as uppercase ACGTN bytes.

        Raises:
            RefMissingError: when the reference can't be found or its
                MD5 doesn't match.
        """
        # 1. Try embedded.
        ref_grp = self._h5.get(f"/study/references/{uri}")
        if ref_grp is not None:
            embedded_md5 = bytes.fromhex(_hex_str_attr(ref_grp.attrs["md5"]))
            if embedded_md5 != expected_md5:
                raise RefMissingError(
                    f"MD5 mismatch for embedded reference {uri!r}: "
                    f"expected {expected_md5.hex()}, got {embedded_md5.hex()}"
                )
            chrom_grp = ref_grp.get(f"chromosomes/{chromosome}")
            if chrom_grp is None:
                raise RefMissingError(
                    f"chromosome {chromosome!r} not embedded in "
                    f"reference {uri!r} — covered_chromosomes are "
                    f"{sorted(ref_grp['chromosomes'].keys())}"
                )
            return bytes(np.asarray(chrom_grp["data"]).tobytes())

        # 2. Try external FASTA.
        if self._external is not None and self._external.exists():
            seq = _read_chrom_from_fasta(self._external, chromosome)
            if seq is not None:
                actual_md5 = hashlib.md5(seq).digest()
                if actual_md5 != expected_md5:
                    raise RefMissingError(
                        f"MD5 mismatch for external reference at {self._external}: "
                        f"expected {expected_md5.hex()}, got {actual_md5.hex()}"
                    )
                return seq

        # 3. Hard error (Q5c).
        raise RefMissingError(
            f"reference {uri!r} (chromosome {chromosome!r}) not found in "
            f"file's /study/references/ and not resolvable via REF_PATH "
            f"({os.environ.get('REF_PATH', '<unset>')}). Provide via "
            f"external_reference_path= constructor arg or set REF_PATH."
        )


def _read_chrom_from_fasta(path: Path, chromosome: str) -> bytes | None:
    """Tiny FASTA reader — extract a single chromosome's sequence as bytes.

    Returns ``None`` if the chromosome is not present in the FASTA.
    Matches headers on the first whitespace-delimited token after ``>``.
    L3 (Task #82 Phase B.1, 2026-05-01): uppercase-normalise the
    bytes to match the encoder's ``_load_reference_chroms`` —
    soft-masked FASTAs (lowercase repeat regions) otherwise produce
    a different MD5 than the encoder computed.
    """
    target = chromosome.encode("ascii")
    out = bytearray()
    in_target = False
    with path.open("rb") as fh:
        for line in fh:
            if line.startswith(b">"):
                if in_target:
                    return bytes(out).upper()
                # Header line: ">chrom_name optional comment\n"
                hdr = line[1:].split()[0] if len(line) > 1 else b""
                in_target = (hdr == target)
                out.clear()
            elif in_target:
                out.extend(line.strip())
    if in_target:
        return bytes(out).upper()
    return None
