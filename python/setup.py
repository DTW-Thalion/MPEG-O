"""TTI-O — setuptools entry point for the Cython extensions.

Most package metadata lives in ``pyproject.toml``. This file only exists
because Cython extensions need ``Extension`` declarations that PEP 621
``[project]`` doesn't support.

When ``Cython`` is unavailable, the build silently emits no extension
modules — the pure-Python references provide byte-identical output, just
slower. ObjC + Java implementations are unaffected.

Two of the v2 codecs — REF_DIFF_V2 and NAME_TOKENIZED_V2 — do not have
Cython accelerators here because their Python wrappers
(``ttio.codecs.ref_diff_v2``, ``ttio.codecs.name_tokenizer_v2``) are
thin ctypes shims around the native ``libttio_rans`` C library. All
hot work runs in C; the Python glue is only argument marshalling.
Adding Cython on top would be a no-op layer. Empty placeholder
package directories were removed 2026-05-05.

Extensions whose ``.pyx`` source files are missing on disk are still
silently skipped so a partial-source checkout (e.g. minimum-clone for
build metadata only) keeps ``pip install -e .`` working.
"""
from __future__ import annotations

from pathlib import Path
from setuptools import setup

_HERE = Path(__file__).parent

# (extension_name, source_path) pairs. Only extensions whose source
# file exists on disk get built; missing sources are silently skipped.
_CYTHON_TARGETS = [
    (
        "ttio.codecs._fqzcomp_nx16_z._fqzcomp_nx16_z",
        "src/ttio/codecs/_fqzcomp_nx16_z/_fqzcomp_nx16_z.pyx",
    ),
    (
        "ttio.codecs._rans._rans",
        "src/ttio/codecs/_rans/_rans.pyx",
    ),
    # Note: REF_DIFF_V2 and NAME_TOKENIZED_V2 use the native C library
    # via ctypes; no Python-side Cython accelerator is meaningful. See
    # the module docstring above.
]

ext_modules: list = []
try:
    from Cython.Build import cythonize  # type: ignore[import-not-found]
    from setuptools import Extension

    extensions = []
    for name, source in _CYTHON_TARGETS:
        if (_HERE / source).is_file():
            extensions.append(Extension(name=name, sources=[source]))
    if extensions:
        ext_modules = cythonize(
            extensions,
            compiler_directives={"language_level": "3"},
        )
except ImportError:  # pragma: no cover — Cython optional
    ext_modules = []

setup(ext_modules=ext_modules)
