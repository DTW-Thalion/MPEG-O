"""Sanity check: package imports and exposes its version."""
import re

import ttio


def test_version_string() -> None:
    assert isinstance(ttio.__version__, str)
    # Match SemVer (MAJOR.MINOR.PATCH, optionally with -prerelease).
    assert re.match(r"^\d+\.\d+\.\d+", ttio.__version__), \
        f"version {ttio.__version__!r} doesn't look like SemVer"


def test_format_version() -> None:
    # FORMAT_VERSION is the on-disk .tio container version; it bumps
    # on backward-incompatible HDF5 layout changes (currently "1.3"
    # post-M74 / -M82-era extensions). Match MAJOR.MINOR rather than
    # pinning a specific number so format bumps don't churn this test.
    assert isinstance(ttio.FORMAT_VERSION, str)
    assert re.match(r"^\d+\.\d+$", ttio.FORMAT_VERSION), \
        f"FORMAT_VERSION {ttio.FORMAT_VERSION!r} should look like 'M.N'"
