"""In-tree PEP 517 backend wrapping scikit-build-core.

Before each sdist/wheel build it copies the sibling ``../native`` C-library
sources into ``./_native`` so the produced artifact is self-contained (an sdist
cannot legally contain files above its own root). All real work is delegated to
``scikit_build_core.build``.

When building from an already-unpacked sdist the sibling ``../native`` is gone
but ``./_native`` is already present, so vendoring is a no-op.
"""
from __future__ import annotations

import shutil
from pathlib import Path

from scikit_build_core import build as _skb

_HERE = Path(__file__).parent
_SRC = _HERE.parent / "native"
_DST = _HERE / "_native"


def _vendor_native() -> None:
    if _SRC.is_dir():
        if _DST.is_dir():
            shutil.rmtree(_DST)
        shutil.copytree(
            _SRC,
            _DST,
            ignore=shutil.ignore_patterns(
                "_build", "_build_tsan", "*.o", "*.so", "*.dll", "*.dylib", "*.a"
            ),
        )
    elif not _DST.is_dir():
        raise RuntimeError(f"libttio_rans native sources not found at {_SRC} or {_DST}")


# --- PEP 517 hooks: vendor (where a build/configure happens), then delegate ---
def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    _vendor_native()
    return _skb.build_wheel(wheel_directory, config_settings, metadata_directory)


def build_sdist(sdist_directory, config_settings=None):
    _vendor_native()
    return _skb.build_sdist(sdist_directory, config_settings)


def build_editable(wheel_directory, config_settings=None, metadata_directory=None):
    _vendor_native()
    return _skb.build_editable(wheel_directory, config_settings, metadata_directory)


def prepare_metadata_for_build_wheel(metadata_directory, config_settings=None):
    _vendor_native()
    return _skb.prepare_metadata_for_build_wheel(metadata_directory, config_settings)


def prepare_metadata_for_build_editable(metadata_directory, config_settings=None):
    _vendor_native()
    return _skb.prepare_metadata_for_build_editable(metadata_directory, config_settings)


# These run before any configure and need no vendored sources — plain delegation.
def get_requires_for_build_wheel(config_settings=None):
    return _skb.get_requires_for_build_wheel(config_settings)


def get_requires_for_build_sdist(config_settings=None):
    return _skb.get_requires_for_build_sdist(config_settings)


def get_requires_for_build_editable(config_settings=None):
    return _skb.get_requires_for_build_editable(config_settings)
