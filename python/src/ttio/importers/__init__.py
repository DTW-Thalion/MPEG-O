"""mzML and nmrML readers for the ``ttio`` package.

This subpackage is Apache-2.0 licensed (see ``LICENSE-IMPORT-EXPORT`` at the
repository root); the core ``ttio`` package is LGPL-3.0-or-later. Keeping
the import layer under a more permissive license mirrors the Objective-C
reference implementation and matches common bioinformatics practice where
format translators are freely embeddable.

Cross-language equivalents
--------------------------
Objective-C: ``Source/Import/`` headers (``TTIOMzMLReader``,
``TTIONmrMLReader``, etc.) · Java:
``global.thalion.ttio.importers`` package

API status: Stable.
"""
from __future__ import annotations

from .import_result import ImportResult
from . import mzml, nmrml

__all__ = ["ImportResult", "mzml", "nmrml"]
