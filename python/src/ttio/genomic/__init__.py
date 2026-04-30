"""Genomic-modality support modules for TTI-O.

Public surface from this subpackage:
    ReferenceResolver, RefMissingError — M93 reference resolution
        for the REF_DIFF codec.
"""
from __future__ import annotations

from .reference_resolver import ReferenceResolver, RefMissingError

__all__ = ["ReferenceResolver", "RefMissingError"]
