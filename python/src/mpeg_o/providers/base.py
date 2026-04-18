"""Abstract storage-provider contract — Milestone 39 Part A.

A storage provider exposes a hierarchical group tree where each group
owns typed datasets (primitive 1-D arrays + compound records) and
attributes. HDF5 is one implementation; in-memory is another; a
future Zarr provider is yet another. Upper layers
(:class:`~mpeg_o.SpectralDataset` et al.) must talk to these ABCs and
stay backend-agnostic.

The capability floor — what every provider MUST support — matches
HANDOFF binding decision #31:

* hierarchical groups
* named datasets with typed arrays
* partial reads (hyperslab-equivalent slicing)
* chunked storage
* compression
* compound types with variable-length string fields
* scalar and array attributes on groups and datasets

Providers that cannot deliver a capability raise
``NotImplementedError`` with a clear message; callers degrade or
error out at the caller layer.

Cross-language equivalents
--------------------------
Objective-C: ``MPGOStorageProtocols.h`` · Java:
``com.dtwthalion.mpgo.providers`` package.

API status: Stable (Provisional per M39 — may change before v1.0).

SPDX-License-Identifier: LGPL-3.0-or-later
"""
from __future__ import annotations

from abc import ABC, abstractmethod
from dataclasses import dataclass
from enum import Enum
from typing import Any

import numpy as np

from ..enums import Compression, Precision


class CompoundFieldKind(Enum):
    """Kinds of fields allowed inside a compound dataset record.

    Kept small on purpose: these are the kinds MPEG-O §6 actually uses
    across identifications, quantifications, provenance, and compound
    spectrum-index headers. Adding a new kind is a spec change.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOCompoundFieldKind`` · Java:
    ``com.dtwthalion.mpgo.providers.CompoundField.Kind``.
    """

    UINT32 = "uint32"
    INT64 = "int64"
    FLOAT64 = "float64"
    VL_STRING = "vl_string"


@dataclass(frozen=True)
class CompoundField:
    """One field inside a compound-dataset record.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOCompoundField`` · Java:
    ``com.dtwthalion.mpgo.providers.CompoundField``.
    """

    name: str
    kind: CompoundFieldKind


class StorageDataset(ABC):
    """A typed array (or compound record array) stored under a
    :class:`StorageGroup`. 1-D is the common case; N-D is supported
    for image cubes and 2-D NMR (see :meth:`create_dataset_nd`).

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOStorageDataset`` · Java:
    ``com.dtwthalion.mpgo.providers.StorageDataset``.
    """

    # ── Type and shape ──────────────────────────────────────────────

    @property
    @abstractmethod
    def name(self) -> str: ...

    @property
    @abstractmethod
    def precision(self) -> Precision | None:
        """Element precision for primitive datasets; ``None`` for
        compound datasets (use :meth:`compound_fields` there)."""

    @property
    @abstractmethod
    def shape(self) -> tuple[int, ...]:
        """Full shape tuple. 1-D datasets return ``(N,)``."""

    @property
    def length(self) -> int:
        """Size along the first axis (= shape[0]). Convenience for
        callers that only deal with 1-D datasets."""
        return self.shape[0] if self.shape else 0

    @property
    def chunks(self) -> tuple[int, ...] | None:
        """Chunk shape, or ``None`` for contiguous storage. Default
        ``None`` — providers that care override."""
        return None

    @property
    @abstractmethod
    def compound_fields(self) -> tuple[CompoundField, ...] | None:
        """Field schema for compound datasets, or ``None`` for
        primitive datasets."""

    # ── Read / write ────────────────────────────────────────────────

    @abstractmethod
    def read(self, offset: int = 0, count: int = -1) -> np.ndarray:
        """Read ``count`` elements starting at ``offset``. ``count == -1``
        reads from ``offset`` to the end. Compound datasets return a
        structured ndarray whose dtype matches :meth:`compound_fields`."""

    @abstractmethod
    def write(self, data: np.ndarray) -> None:
        """Write the full array. Shape must match :meth:`length` and
        dtype must match the declared precision / compound schema."""

    # ── Attributes ──────────────────────────────────────────────────

    @abstractmethod
    def has_attribute(self, name: str) -> bool: ...

    @abstractmethod
    def get_attribute(self, name: str) -> Any: ...

    @abstractmethod
    def set_attribute(self, name: str, value: Any) -> None: ...

    @abstractmethod
    def delete_attribute(self, name: str) -> None:
        """Remove an attribute. No-op if absent. Appendix B Gap 8."""

    @abstractmethod
    def attribute_names(self) -> list[str]:
        """List attribute names; empty list if none. Appendix B Gap 8."""

    # ── Lifecycle ───────────────────────────────────────────────────

    def close(self) -> None:
        """Release any per-dataset resources. Default no-op."""
        return None

    def __enter__(self) -> "StorageDataset":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


class StorageGroup(ABC):
    """A named directory of sub-groups and datasets.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOStorageGroup`` · Java:
    ``com.dtwthalion.mpgo.providers.StorageGroup``.
    """

    # ── Identity ────────────────────────────────────────────────────

    @property
    @abstractmethod
    def name(self) -> str: ...

    # ── Children ────────────────────────────────────────────────────

    @abstractmethod
    def child_names(self) -> list[str]: ...

    @abstractmethod
    def has_child(self, name: str) -> bool: ...

    @abstractmethod
    def open_group(self, name: str) -> "StorageGroup": ...

    @abstractmethod
    def create_group(self, name: str) -> "StorageGroup": ...

    @abstractmethod
    def delete_child(self, name: str) -> None: ...

    # ── Datasets ────────────────────────────────────────────────────

    @abstractmethod
    def open_dataset(self, name: str) -> StorageDataset: ...

    @abstractmethod
    def create_dataset(self, name: str, precision: Precision,
                       length: int, *,
                       chunk_size: int = 0,
                       compression: Compression = Compression.NONE,
                       compression_level: int = 6) -> StorageDataset:
        """Create a primitive 1-D dataset.

        ``chunk_size == 0`` selects a contiguous (unchunked) layout.
        ``compression == NONE`` disables filters regardless of
        ``compression_level``."""

    def create_dataset_nd(self, name: str, precision: Precision,
                           shape: tuple[int, ...], *,
                           chunks: tuple[int, ...] | None = None,
                           compression: Compression = Compression.NONE,
                           compression_level: int = 6) -> StorageDataset:
        """Create a multi-dimensional dataset. 1-D path delegates to
        :meth:`create_dataset` for backward compat; overrides extend
        to higher ranks."""
        if len(shape) == 1:
            chunk_size = chunks[0] if chunks else 0
            return self.create_dataset(name, precision, shape[0],
                                         chunk_size=chunk_size,
                                         compression=compression,
                                         compression_level=compression_level)
        raise NotImplementedError(
            f"{type(self).__name__} does not implement N-D datasets "
            f"(shape={shape})")

    @abstractmethod
    def create_compound_dataset(self, name: str,
                                 fields: list[CompoundField],
                                 count: int) -> StorageDataset:
        """Create a 1-D compound dataset with the given field schema."""

    # ── Attributes ──────────────────────────────────────────────────

    @abstractmethod
    def has_attribute(self, name: str) -> bool: ...

    @abstractmethod
    def get_attribute(self, name: str) -> Any: ...

    @abstractmethod
    def set_attribute(self, name: str, value: Any) -> None: ...

    @abstractmethod
    def delete_attribute(self, name: str) -> None: ...

    @abstractmethod
    def attribute_names(self) -> list[str]: ...

    # ── Lifecycle ───────────────────────────────────────────────────

    def close(self) -> None:
        """Release any per-group resources. Default no-op."""
        return None

    def __enter__(self) -> "StorageGroup":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


class StorageProvider(ABC):
    """Opens a storage backend and exposes its root group.

    Cross-language equivalents
    --------------------------
    Objective-C: ``MPGOStorageProvider`` · Java:
    ``com.dtwthalion.mpgo.providers.StorageProvider``.
    """

    @classmethod
    @abstractmethod
    def open(cls, path_or_url: str, *, mode: str = "r", **kwargs
             ) -> "StorageProvider":
        """Open an existing backing store.

        ``mode`` mirrors h5py semantics: ``"r"`` read-only, ``"r+"``
        read/write existing, ``"w"`` create/truncate, ``"a"`` append."""

    @abstractmethod
    def provider_name(self) -> str:
        """Short identifier used for logging and registry lookup
        (``"hdf5"``, ``"memory"``, ``"zarr"``, …).

        Exposed as a method (not a property) to mirror the ObjC
        ``-providerName`` selector and Java ``providerName()`` getter.
        Appendix B Gap 5 — Provisional storage-provider convergence."""

    @abstractmethod
    def root_group(self) -> StorageGroup: ...

    @abstractmethod
    def is_open(self) -> bool: ...

    @abstractmethod
    def close(self) -> None: ...

    # ── Capabilities (Appendix B Gap 3) ──────────────────────────

    def supports_chunking(self) -> bool:
        """Returns True if the backend honors ``chunk_size`` in
        :meth:`StorageGroup.create_dataset`. HDF5 returns True; Memory
        and SQLite return False (chunk_size is accepted for interface
        compatibility but silently ignored).

        Callers that depend on chunked I/O for streaming large datasets
        can query this to degrade gracefully."""
        return False

    def supports_compression(self) -> bool:
        """Returns True if the backend honors ``compression`` /
        ``compression_level``. HDF5 returns True (zlib + LZ4); Memory
        and SQLite return False."""
        return False

    def native_handle(self) -> Any:
        """Return the underlying native storage handle — ``h5py.File``
        for :class:`Hdf5Provider`, ``None`` for :class:`MemoryProvider`.

        Escape hatch for byte-level code (signatures, encryption,
        native compression filters) that cannot be expressed through
        the protocol. Any caller that invokes this is pinned to a
        specific backend."""
        return None

    def __enter__(self) -> "StorageProvider":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()
