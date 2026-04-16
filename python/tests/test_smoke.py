"""Sanity check: package imports and exposes its version."""
import mpeg_o


def test_version_string() -> None:
    assert isinstance(mpeg_o.__version__, str)
    assert mpeg_o.__version__.startswith("0.4.")


def test_format_version() -> None:
    assert mpeg_o.FORMAT_VERSION == "1.1"
