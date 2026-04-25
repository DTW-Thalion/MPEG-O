"""Sanity check: package imports and exposes its version."""
import ttio


def test_version_string() -> None:
    assert isinstance(ttio.__version__, str)
    assert ttio.__version__.startswith("0.4.")


def test_format_version() -> None:
    assert ttio.FORMAT_VERSION == "1.1"
