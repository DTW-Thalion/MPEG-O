"""Run — modality-agnostic Protocol for an acquisition or sequencing
run inside a TTI-O SpectralDataset.

A "run" is a sequence of measurements (spectra in the MS / NMR / FID
case, aligned reads in the genomic case) that share an acquisition
mode, instrument context, and provenance chain. Both
:class:`ttio.acquisition_run.AcquisitionRun` and
:class:`ttio.genomic_run.GenomicRun` conform structurally — no
explicit subclassing required.

Code that wants to operate uniformly on either modality should type-
hint against :class:`Run` and use only the methods listed below.
Modality-specific work (e.g. extracting a CIGAR string from an
aligned read, or a precursor m/z from a mass spectrum) requires
narrowing via ``isinstance()`` to the concrete class.

API status: Provisional (Phase 1 abstraction polish, post-M91).
"""
from __future__ import annotations

from typing import Any, Iterator, Protocol, runtime_checkable

from ..enums import AcquisitionMode
from ..provenance import ProvenanceRecord


@runtime_checkable
class Run(Protocol):
    """Common surface shared by every run type (MS, NMR, FID,
    MSImage, Genomic).

    Attributes
    ----------
    name : str
        Run identifier as stored in the .tio file (e.g.
        ``"run_0001"`` or ``"genomic_0001"``).
    acquisition_mode : AcquisitionMode
        Acquisition mode enum value identifying the instrument /
        protocol context.

    Methods
    -------
    __len__() -> int
        Number of measurements in the run.
    __iter__() -> Iterator
        Yield each measurement in storage order. The yielded type
        is modality-specific (Spectrum / AlignedRead).
    __getitem__(i: int)
        Return the i-th measurement. Negative indices count from
        the end. Raises IndexError on out-of-bounds.
    provenance_chain() -> list[ProvenanceRecord]
        Return the per-run provenance records in insertion order.
        Empty list when the run has no provenance attached.
    """

    name: str
    acquisition_mode: AcquisitionMode

    def __len__(self) -> int: ...

    def __iter__(self) -> Iterator[Any]: ...

    def __getitem__(self, i: int) -> Any: ...

    def provenance_chain(self) -> list[ProvenanceRecord]: ...
