"""GenomicRun — lazy view over /study/genomic_runs/<name>/.

Task 8: minimal shape holding name + group + an open() classmethod
so SpectralDataset.open can populate the genomic_runs dictionary.
Task 9 will replace this with the full read implementation
(__getitem__, __iter__, reads_in_region, materialisation from signal
channels, GenomicIndex eager-load).
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from .providers.base import StorageGroup


def _wrap_hdf5_group(obj: object) -> "StorageGroup":
    """Adapt an h5py.Group to a StorageGroup; pass-through for StorageGroup."""
    from .providers.base import StorageGroup as _SG
    if isinstance(obj, _SG):
        return obj
    from .providers.hdf5 import _Group as _Hdf5Group
    return _Hdf5Group(obj)  # type: ignore[arg-type]


@dataclass(slots=True)
class GenomicRun:
    """Minimal handle to one /study/genomic_runs/<name>/ group.

    Task 8: name + group only. Task 9 fills in the read path.
    """

    name: str
    group: "StorageGroup"

    @classmethod
    def open(cls, group, name: str) -> "GenomicRun":
        """Open an existing genomic_runs/<name>/ group.

        Mirrors :meth:`ttio.acquisition_run.AcquisitionRun.open`: the
        caller resolves the child group; this classmethod wraps the
        provided handle into a StorageGroup and constructs the run.
        """
        sgroup = _wrap_hdf5_group(group)
        return cls(name=name, group=sgroup)
