"""Provider registry + factory — Milestone 39 Part B/E.

Providers register via ``importlib.metadata`` entry points in the
``mpeg_o.providers`` group. In-process registration
(:func:`register_provider`) is also supported for testing.

Lookup by provider name (``"hdf5"``, ``"memory"``) or by URL scheme
(``"file"``, ``"memory"``, ``"s3"``, ``"http"``, ``"https"``).

Entry points are declared in ``pyproject.toml``:

.. code-block:: toml

    [project.entry-points."mpeg_o.providers"]
    hdf5 = "mpeg_o.providers.hdf5:Hdf5Provider"
    memory = "mpeg_o.providers.memory:MemoryProvider"

Cross-language equivalents
--------------------------
Objective-C: ``MPGOProviderRegistry`` class ·
Java: ``com.dtwthalion.mpgo.providers.ProviderRegistry`` class ·
Python: module-level functions
(``discover_providers``, ``open_provider``, ``register_provider``)
— idiomatic for Python packaging.

API status: Stable (Provisional per M39).

SPDX-License-Identifier: LGPL-3.0-or-later
"""
from __future__ import annotations

from importlib.metadata import entry_points
from typing import Any

from .base import StorageProvider


# ── In-process registry ───────────────────────────────────────────────

_REGISTRY: dict[str, type[StorageProvider]] = {}


def register_provider(name: str, cls: type[StorageProvider]) -> None:
    """Register ``cls`` under ``name``. Overrides an existing entry."""
    _REGISTRY[name] = cls


def discover_providers() -> dict[str, type[StorageProvider]]:
    """Return the full map of registered providers, loading entry
    points lazily on first call. Subsequent calls reuse the cache."""
    if _REGISTRY:
        return dict(_REGISTRY)
    try:
        eps = entry_points(group="mpeg_o.providers")
    except TypeError:  # pragma: no cover — older importlib.metadata
        eps = entry_points().get("mpeg_o.providers", [])
    for ep in eps:
        try:
            cls = ep.load()
        except Exception:
            continue
        if isinstance(cls, type) and issubclass(cls, StorageProvider):
            _REGISTRY[ep.name] = cls
    # Fall back to built-in providers if entry points didn't land
    # (editable install without regenerating the metadata, etc.).
    if "hdf5" not in _REGISTRY:
        from .hdf5 import Hdf5Provider
        _REGISTRY["hdf5"] = Hdf5Provider
    if "memory" not in _REGISTRY:
        from .memory import MemoryProvider
        _REGISTRY["memory"] = MemoryProvider
    if "sqlite" not in _REGISTRY:
        from .sqlite import SqliteProvider
        _REGISTRY["sqlite"] = SqliteProvider
    # v0.7 M46: register the optional ZarrProvider when zarr is
    # available. Absence is fine — importers that need it will fall
    # through to ImportError from the provider module.
    if "zarr" not in _REGISTRY:
        try:
            from .zarr import ZarrProvider
        except ImportError:
            pass
        else:
            _REGISTRY["zarr"] = ZarrProvider
    return dict(_REGISTRY)


def _class_for_scheme(scheme: str) -> type[StorageProvider]:
    providers = discover_providers()
    if scheme in providers:
        return providers[scheme]
    # Map transport / filesystem schemes onto storage providers.
    aliases = {
        "file": "hdf5", "http": "hdf5", "https": "hdf5", "s3": "hdf5",
        # v0.7 M46: zarr composite schemes all route to the
        # ZarrProvider; the provider itself inspects the URL to pick
        # the backing store (DirectoryStore, FSStore, MemoryStore).
        "zarr": "zarr", "zarr+memory": "zarr",
        "zarr+s3": "zarr", "zarr+file": "zarr",
    }
    mapped = aliases.get(scheme)
    if mapped and mapped in providers:
        return providers[mapped]
    raise ValueError(
        f"no provider registered for scheme '{scheme}'. "
        f"Known: {sorted(providers.keys())}")


# ── Public factory ────────────────────────────────────────────────────


def open_provider(path_or_url: str, *, provider: str | None = None,
                   mode: str = "r", **kwargs: Any) -> StorageProvider:
    """Resolve a provider and open a backing store.

    * ``provider`` — explicit provider name (bypasses URL detection).
    * URL scheme — e.g. ``memory://foo``, ``s3://bucket/key.mpgo``,
      ``file:///path/to/data.mpgo``.
    * Otherwise — bare path, routed to the ``hdf5`` provider.
    """
    if provider is not None:
        cls = discover_providers().get(provider)
        if cls is None:
            raise ValueError(
                f"unknown provider '{provider}'. "
                f"Known: {sorted(discover_providers().keys())}")
    else:
        if "://" in path_or_url:
            scheme = path_or_url.split("://", 1)[0]
            cls = _class_for_scheme(scheme)
        else:
            cls = _class_for_scheme("file")
    return cls.open(path_or_url, mode=mode, **kwargs)
