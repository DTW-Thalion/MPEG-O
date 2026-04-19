"""Shared provider-matrix helper for v0.9 integration tests.

Centralizes the ``["hdf5", "memory", "sqlite", "zarr"]`` parametrize
list and the skip logic for backends that aren't yet wired through
:meth:`mpeg_o.SpectralDataset.write_minimal`.

The single source of truth is :data:`WRITE_PROVIDERS_WIRED`. While
the milestone M64.5 caller refactor is outstanding (see HANDOFF.md
"Milestone 64.5 — Caller Refactor"), it stays ``False`` and tests
that touch a non-HDF5 provider call :func:`maybe_skip_provider` to
skip with a citation.

When M64.5 lands, flipping the flag to ``True`` is the single change
required to light up every cross-provider matrix in the integration
suite (M58, M61, M62) — no per-test edits needed.
"""
from __future__ import annotations

import pytest

PROVIDERS: tuple[str, ...] = ("hdf5", "memory", "sqlite", "zarr")

# Set to True once HANDOFF.md M64.5 ships. Until then the non-HDF5
# matrix cells skip cleanly. ARCHITECTURE.md "Caller refactor status"
# tracks the same gap from the architecture side.
WRITE_PROVIDERS_WIRED: bool = False

_NATIVE_WRITE_ONLY: frozenset[str] = frozenset({"memory", "sqlite", "zarr"})


def maybe_skip_provider(provider: str) -> None:
    """Skip the calling test if ``provider`` cannot accept writes yet."""
    if WRITE_PROVIDERS_WIRED:
        return
    if provider in _NATIVE_WRITE_ONLY:
        pytest.skip(
            f"provider '{provider}' write path not yet wired through "
            "SpectralDataset.write_minimal — see HANDOFF.md "
            "'Milestone 64.5 — Caller Refactor'"
        )
