"""Per-conftest guard: ensure ttio resolves to a checkout that
has the v1.1.0 references() accessor.

Without this guard, an editable install pointing at a sibling
worktree (or stale main checkout) would either fail with
AttributeError deep in the test, or — worse — silently pass
against unexpected behavior.
"""
from pathlib import Path

import pytest


@pytest.fixture(scope="session", autouse=True)
def _verify_ttio_has_references_accessor():
    """Fail fast if the installed ttio lacks v1.1.0 references()."""
    from ttio import SpectralDataset
    if not hasattr(SpectralDataset, "references"):
        worktree = Path(__file__).resolve().parents[3]
        import ttio
        installed_path = Path(ttio.__file__).resolve()
        pytest.skip(
            f"Installed ttio at {installed_path} lacks SpectralDataset.references. "
            f"Run `pip install -e {worktree / 'python'}` (with `--break-system-packages` "
            f"if needed) to point the editable install at this worktree."
        )
