"""TTI-O M93 — REF_DIFF C-extension package.

Houses the Cython-built ``_ref_diff`` accelerator module. The pure-Python
reference implementation in :mod:`ttio.codecs.ref_diff` is the byte-exact
contract; this package only accelerates the four hot functions named in
the chr22 profile (``walk_read_against_reference``,
``pack_read_diff_bitstream``, ``_unpack_read_diff_with_consumed``,
``reconstruct_read_from_walk``). ObjC + Java port the ALGORITHM (not the
C code).

If the compiled extension is absent (e.g. user did `pip install` without
building extensions), the parent module silently falls back to the
pure-Python path. Behaviour is byte-identical either way.
"""
from __future__ import annotations

try:  # pragma: no cover — extension may be absent in source-only installs
    from . import _ref_diff  # noqa: F401
    HAVE_EXTENSION = True
except ImportError:  # pragma: no cover
    HAVE_EXTENSION = False

__all__ = ["HAVE_EXTENSION"]
