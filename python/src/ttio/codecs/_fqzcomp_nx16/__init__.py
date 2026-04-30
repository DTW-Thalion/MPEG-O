"""TTI-O M94 — FQZCOMP_NX16 C-extension package.

Houses the Cython-built ``_fqzcomp_nx16`` accelerator module. The pure-
Python reference implementation in :mod:`ttio.codecs.fqzcomp_nx16` is the
byte-exact contract; this package only accelerates the inner state
machine. ObjC + Java port the ALGORITHM (not the C code).

If the compiled extension is absent (e.g. user did `pip install` without
building extensions), the parent module silently falls back to the
pure-Python path. Behaviour is byte-identical either way.
"""
from __future__ import annotations

try:  # pragma: no cover — extension may be absent in source-only installs
    from . import _fqzcomp_nx16  # noqa: F401
    HAVE_EXTENSION = True
except ImportError:  # pragma: no cover
    HAVE_EXTENSION = False

__all__ = ["HAVE_EXTENSION"]
