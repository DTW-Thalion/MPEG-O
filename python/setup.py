"""TTI-O — setuptools entry point for the Cython extensions.

Most package metadata lives in ``pyproject.toml``. This file only exists
because Cython extensions need ``Extension`` declarations that PEP 621
``[project]`` doesn't support.

When ``Cython`` is unavailable, the build silently emits no extension
modules — the pure-Python references provide byte-identical output, just
slower. ObjC + Java implementations are unaffected.
"""
from __future__ import annotations

from setuptools import setup

ext_modules: list = []
try:
    from Cython.Build import cythonize  # type: ignore[import-not-found]
    from setuptools import Extension

    ext_modules = cythonize(
        [
            Extension(
                name="ttio.codecs._fqzcomp_nx16_z._fqzcomp_nx16_z",
                sources=[
                    "src/ttio/codecs/_fqzcomp_nx16_z/_fqzcomp_nx16_z.pyx",
                ],
            ),
            Extension(
                name="ttio.codecs._ref_diff._ref_diff",
                sources=[
                    "src/ttio/codecs/_ref_diff/_ref_diff.pyx",
                ],
            ),
            Extension(
                name="ttio.codecs._name_tokenizer._name_tokenizer",
                sources=[
                    "src/ttio/codecs/_name_tokenizer/_name_tokenizer.pyx",
                ],
            ),
        ],
        compiler_directives={"language_level": "3"},
    )
except ImportError:  # pragma: no cover — Cython optional
    ext_modules = []

setup(ext_modules=ext_modules)
