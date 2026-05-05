"""Genomic-modality support modules for TTI-O.

Public surface from this subpackage:
    ReferenceResolver, RefMissingError — reference resolution for
        the REF_DIFF_V2 codec.
    ReferenceImport, compute_reference_md5 — FASTA reference value
        class staged for embedding into a ``.tio`` container.
"""
from __future__ import annotations

from .reference_import import ReferenceImport, compute_reference_md5
from .reference_resolver import ReferenceResolver, RefMissingError

__all__ = [
    "ReferenceImport",
    "compute_reference_md5",
    "ReferenceResolver",
    "RefMissingError",
]
