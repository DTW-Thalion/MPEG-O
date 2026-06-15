"""Single loader for the native ``libttio_rans`` shared library.

Search order:
  1. ``$TTIO_RANS_LIB_PATH`` — a full path to the lib, or a directory containing it.
  2. Package-bundled ``ttio/.libs/`` (populated in binary wheels).
  3. Bare names, letting the system loader use LD_LIBRARY_PATH / DYLD_LIBRARY_PATH
     / PATH / RPATH.
  4. ``ctypes.util.find_library("ttio_rans")``.

Returns the ``ctypes.CDLL`` handle, or ``None`` if no library is found
(callers treat absence as "native acceleration unavailable" and either fall
back to pure Python or raise a clear RuntimeError, per codec).
"""
from __future__ import annotations

import ctypes
import ctypes.util
import os
from pathlib import Path

_LIB_NAMES = ("libttio_rans.so", "libttio_rans.dylib", "ttio_rans.dll", "libttio_rans.dll")

_cached: ctypes.CDLL | None = None
_attempted = False


def _bare_names() -> list[str]:
    return list(_LIB_NAMES)


def _bundled_libs_dirs() -> list[Path]:
    """Directories inside the installed package that may hold a bundled lib."""
    here = Path(__file__).resolve()
    pkg_root = here.parent.parent  # .../ttio
    return [pkg_root / ".libs", pkg_root]


def _candidates() -> list[str]:
    out: list[str] = []
    env = os.environ.get("TTIO_RANS_LIB_PATH")
    if env:
        if os.path.isdir(env):
            out += [os.path.join(env, n) for n in _LIB_NAMES]
        else:
            out.append(env)
    for d in _bundled_libs_dirs():
        out += [str(d / n) for n in _LIB_NAMES]
    out += _bare_names()
    return out


def reset_cache() -> None:
    """Clear the memoised handle (test hook)."""
    global _cached, _attempted
    _cached = None
    _attempted = False


def load_ttio_rans() -> ctypes.CDLL | None:
    global _cached, _attempted
    if _attempted:
        return _cached
    _attempted = True
    for name in _candidates():
        try:
            _cached = ctypes.CDLL(name)
            return _cached
        except OSError:
            continue
    found = ctypes.util.find_library("ttio_rans")
    if found:
        try:
            _cached = ctypes.CDLL(found)
        except OSError:
            _cached = None
    return _cached
