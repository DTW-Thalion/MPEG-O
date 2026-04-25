"""Domain protocols defining the five cross-cutting capabilities
(CV annotation, encryption, indexability, provenance, streamability).

Each protocol mirrors the corresponding Objective-C
``@protocol`` declaration in ``objc/Source/Protocols/``. See
:doc:`/api-review-v0.6` for the three-language parity table.
"""
from __future__ import annotations

from .cv_annotatable import CVAnnotatable
from .encryptable import Encryptable
from .indexable import Indexable
from .provenanceable import Provenanceable
from .streamable import Streamable

__all__ = [
    "CVAnnotatable",
    "Encryptable",
    "Indexable",
    "Provenanceable",
    "Streamable",
]
