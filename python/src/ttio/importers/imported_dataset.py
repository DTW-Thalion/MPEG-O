"""``ImportedDataset`` — the normalized in-memory draft every importer
produces. The single call site of :meth:`SpectralDataset.write_minimal`,
collapsing the per-format adapter normalization the registry used to do.
"""
from __future__ import annotations

from dataclasses import dataclass, field
from pathlib import Path
from typing import TYPE_CHECKING

from ..identification import Identification
from ..provenance import ProvenanceRecord
from ..quantification import Quantification
from ..spectral_dataset import SpectralDataset, WrittenRun

if TYPE_CHECKING:
    from ..genomic_run import WrittenGenomicRun


@dataclass(slots=True)
class ImportedDataset:
    """In-memory bundle of built runs + dataset metadata, ready to write."""

    title: str = ""
    isa_investigation_id: str = ""
    runs: dict[str, WrittenRun] = field(default_factory=dict)
    genomic_runs: dict = field(default_factory=dict)  # name -> WrittenGenomicRun
    identifications: list[Identification] = field(default_factory=list)
    quantifications: list[Quantification] = field(default_factory=list)
    provenance: list[ProvenanceRecord] = field(default_factory=list)
    image: object | None = None
    raman_image: object | None = None
    ir_image: object | None = None
    subjects: list = field(default_factory=list)
    samples: list = field(default_factory=list)

    def write(self, path: str | Path, *, features: list[str] | None = None,
              provider: str = "hdf5", progress=None) -> Path:
        return SpectralDataset.write_minimal(
            path,
            title=self.title or "imported",
            isa_investigation_id=self.isa_investigation_id,
            runs=self.runs,
            genomic_runs=self.genomic_runs or None,
            identifications=self.identifications or None,
            quantifications=self.quantifications or None,
            provenance=self.provenance or None,
            features=features,
            provider=provider,
            image=self.image,
            raman_image=self.raman_image,
            ir_image=self.ir_image,
            subjects=self.subjects or None,
            samples=self.samples or None,
            progress=progress,
        )
