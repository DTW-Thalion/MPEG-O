"""TTI-O M85B — NAME_TOKENIZED C-extension package.

Houses the Cython-built ``_name_tokenizer`` accelerator module. The
pure-Python reference implementation in :mod:`ttio.codecs.name_tokenizer`
is the byte-exact contract; this package only accelerates the hot
functions named in the chr22 profile (``_tokenize``, ``_encode_columnar``,
``_decode_columnar``, ``_encode_verbatim``, ``_decode_verbatim``).
ObjC + Java port the ALGORITHM (not the C code).

If the compiled extension is absent (e.g. user did `pip install` without
building extensions), the parent module silently falls back to the
pure-Python path. Behaviour is byte-identical either way.
"""
from __future__ import annotations

try:  # pragma: no cover — extension may be absent in source-only installs
    from . import _name_tokenizer  # noqa: F401
    HAVE_EXTENSION = True
except ImportError:  # pragma: no cover
    HAVE_EXTENSION = False

__all__ = ["HAVE_EXTENSION"]
