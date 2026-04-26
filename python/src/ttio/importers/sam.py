"""SAM importer — M87 thin wrapper over :class:`BamReader`.

``samtools view -h`` reads both SAM and BAM transparently (auto-
detecting via magic bytes), so :class:`SamReader` is functionally
identical to :class:`~ttio.importers.bam.BamReader`. The class is
kept as a separate, discoverable name for callsites that want to
make "this is SAM input" explicit.

Cross-language equivalents
--------------------------
Objective-C: ``TTIOSamReader`` · Java:
``global.thalion.ttio.importers.SamReader``.

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

from .bam import BamReader


__all__ = ["SamReader"]


class SamReader(BamReader):
    """Convenience alias for :class:`BamReader` on SAM-text input.

    Functionally identical: samtools handles SAM and BAM the same
    way. Use :class:`SamReader` when the calling code wants the type
    name to communicate "this is SAM-text input" to the reader.
    """
    pass
