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
    from ..providers.base import StorageGroup


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
        references_group: the ``/study/references`` group as a
            :class:`~ttio.providers.base.StorageGroup`, or ``None`` when
            no embedded references are available. The resolver looks for
            ``<uri>/`` children under this group as the primary source.
        external_reference_path: optional explicit path to a FASTA file.
            If unset, the ``REF_PATH`` environment variable is consulted.
    """

    def __init__(
        self,
        references_group: "StorageGroup | None" = None,
        external_reference_path: Path | None = None,
    ):
        self._refs = references_group
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
        if self._refs is not None and self._refs.has_child(uri):
            ref_grp = self._refs.open_group(uri)
            embedded_md5 = bytes.fromhex(_hex_str_attr(ref_grp.get_attribute("md5")))
            if embedded_md5 != expected_md5:
                raise RefMissingError(
                    f"MD5 mismatch for embedded reference {uri!r}: "
                    f"expected {expected_md5.hex()}, got {embedded_md5.hex()}"
                )
            chroms = ref_grp.open_group("chromosomes")
            if not chroms.has_child(chromosome):
                raise RefMissingError(
                    f"chromosome {chromosome!r} not embedded in "
                    f"reference {uri!r} — covered_chromosomes are "
                    f"{sorted(chroms.child_names())}"
                )
            from . import packed_reference
            return packed_reference.read_chromosome_bytes(
                chroms.open_group(chromosome))

        # 2. Try external FASTA.
        if self._external is not None and self._external.exists():
            seq = _external_chromosome(self._external, expected_md5, chromosome)
            if seq is not None:
                return seq

        # 3. Hard error (Q5c).
        raise RefMissingError(
            f"reference {uri!r} (chromosome {chromosome!r}) not found in "
            f"file's /study/references/ and not resolvable via REF_PATH "
            f"({os.environ.get('REF_PATH', '<unset>')}). Provide via "
            f"external_reference_path= constructor arg or set REF_PATH."
        )


_LAZY: dict[Path, "object"] = {}
_SET_MD5: dict[Path, bytes] = {}


def _lazy(path: Path):
    from .lazy_reference import LazyReference
    ref = _LAZY.get(path)
    if ref is None:
        ref = _LAZY[path] = LazyReference(path, cache_chroms=2)
    return ref


def _external_chromosome(path: Path, expected_md5: bytes, chromosome: str) -> bytes | None:
    """Read ``chromosome`` from the external FASTA through its .fai index
    and check ``expected_md5`` against, in order: the md5 of that
    chromosome's case-preserved bytes, of its upper-cased bytes (both
    the pre-1.9 external check, which only ever matched a
    single-contig FASTA), then the reference-set md5 of the whole
    FASTA (every chromosome, alphabetic order, case preserved: the
    digest the writers record). Returns the upper-cased sequence, or
    None when the chromosome is not in the FASTA."""
    ref = _lazy(path)
    if chromosome not in ref:
        return None
    raw = ref[chromosome]
    upper = raw.upper()
    if hashlib.md5(raw).digest() == expected_md5 or hashlib.md5(upper).digest() == expected_md5:
        return upper
    set_md5 = _SET_MD5.get(path)
    if set_md5 is None:
        set_md5 = _SET_MD5[path] = ref.set_md5()
    if set_md5 == expected_md5:
        return upper
    raise RefMissingError(
        f"MD5 mismatch for external reference at {path}: expected "
        f"{expected_md5.hex()}, got {set_md5.hex()} for the whole FASTA and "
        f"{hashlib.md5(raw).hexdigest()} for chromosome {chromosome!r}"
    )
