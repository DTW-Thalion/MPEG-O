"""Shared provider-matrix helper for v0.9 integration tests.

Centralizes the ``["hdf5", "memory", "sqlite", "zarr"]`` parametrize
list, the per-provider URL convention, and the M64.5 wiring flag.

The single source of truth is :data:`WRITE_PROVIDERS_WIRED`. While
the milestone M64.5 caller refactor was outstanding it was ``False``
and non-HDF5 cells skipped with a HANDOFF citation. M64.5 phase A
(write_minimal + open() routed through StorageProvider) flipped it
to ``True``; every cross-provider matrix in the integration suite
now exercises Memory / SQLite / Zarr alongside HDF5.
"""
from __future__ import annotations

import uuid
from pathlib import Path

import pytest

PROVIDERS: tuple[str, ...] = ("hdf5", "memory", "sqlite", "zarr")

# v0.9 M64.5 phase A: SpectralDataset.write_minimal accepts a
# ``provider=`` kwarg and SpectralDataset.open detects URL schemes.
# Memory/SQLite/Zarr round-trips work end-to-end through the storage
# protocol. ARCHITECTURE.md "Caller refactor status" updated to
# reflect provider-aware bulk writes.
WRITE_PROVIDERS_WIRED: bool = True

_NATIVE_WRITE_ONLY: frozenset[str] = frozenset({"memory", "sqlite", "zarr"})


def _zarr_available() -> bool:
    """Cached check for the optional ``zarr`` package."""
    global _ZARR_AVAILABLE
    if _ZARR_AVAILABLE is None:
        try:
            import zarr  # noqa: F401
            _ZARR_AVAILABLE = True
        except ImportError:
            _ZARR_AVAILABLE = False
    return _ZARR_AVAILABLE


_ZARR_AVAILABLE: bool | None = None


def maybe_skip_provider(provider: str) -> None:
    """Skip the calling test if ``provider`` cannot accept writes yet.

    Two skip paths:

    * The optional ``zarr`` package is not installed in this
      environment — `zarr` cells skip cleanly. Install via
      ``pip install ttio[zarr]`` to enable.
    * Pre-M64.5 caller-refactor: any non-HDF5 provider when
      :data:`WRITE_PROVIDERS_WIRED` is ``False``. With M64.5 phase A
      shipped this is a no-op; left in place so subsequent
      milestones can re-enable selective skipping for paths that
      aren't yet provider-aware.
    """
    if provider == "zarr" and not _zarr_available():
        pytest.skip(
            "provider 'zarr' requires the optional 'zarr' package; "
            "install via 'pip install ttio[zarr]' or 'pip install zarr'"
        )
    if WRITE_PROVIDERS_WIRED:
        return
    if provider in _NATIVE_WRITE_ONLY:
        pytest.skip(
            f"provider '{provider}' write path not yet wired through "
            "SpectralDataset.write_minimal — see HANDOFF.md "
            "'Milestone 64.5 — Caller Refactor'"
        )


def provider_url(provider: str, tmp_path: Path, stem: str = "rt") -> str:
    """Return a URL/path suitable for the given provider.

    ``hdf5`` returns a bare ``.tio`` path; the other providers use
    their canonical URL schemes so :meth:`SpectralDataset.open` routes
    correctly. The unique-id suffix on Memory URLs prevents store
    name collisions across parametrized matrix cells running in the
    same process.
    """
    if provider == "hdf5":
        return str(tmp_path / f"{stem}.tio")
    if provider == "memory":
        return f"memory://{stem}-{uuid.uuid4().hex[:8]}"
    if provider == "sqlite":
        return f"sqlite://{tmp_path / (stem + '.sqlite')}"
    if provider == "zarr":
        return f"zarr://{tmp_path / (stem + '.zarr')}"
    raise ValueError(f"unknown provider {provider!r}")
