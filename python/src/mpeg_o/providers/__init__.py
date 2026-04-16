"""Storage/transport provider abstraction — Milestone 39.

The MPEG-O data model and API are the standard; the storage backend is
a pluggable implementation detail. Providers register via
``importlib.metadata`` entry points (group ``mpeg_o.providers``) and
are resolved by URL scheme or explicit override.

Two providers ship with v0.6:

* :class:`~mpeg_o.providers.hdf5.Hdf5Provider` — wraps ``h5py``.
* :class:`~mpeg_o.providers.memory.MemoryProvider` — in-memory tree
  for tests and transient pipelines.

See :mod:`mpeg_o.providers.base` for the abstract contract and
:mod:`mpeg_o.providers.registry` for discovery + factory helpers.

SPDX-License-Identifier: LGPL-3.0-or-later
"""
from __future__ import annotations

from .base import (
    CompoundField,
    CompoundFieldKind,
    StorageDataset,
    StorageGroup,
    StorageProvider,
)
from .registry import (
    discover_providers,
    open_provider,
    register_provider,
)

__all__ = [
    "CompoundField",
    "CompoundFieldKind",
    "StorageDataset",
    "StorageGroup",
    "StorageProvider",
    "discover_providers",
    "open_provider",
    "register_provider",
]
