"""Shared pytest fixtures for the mpeg-o package."""
from __future__ import annotations

from pathlib import Path
import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]
_OBJC_FIXTURES = _REPO_ROOT / "objc" / "Tests" / "Fixtures" / "mpgo"


@pytest.fixture(scope="session")
def objc_fixtures_dir() -> Path:
    """Directory of reference .mpgo fixtures produced by the ObjC build."""
    if not _OBJC_FIXTURES.is_dir():
        pytest.skip(f"ObjC fixtures not found at {_OBJC_FIXTURES}")
    return _OBJC_FIXTURES


@pytest.fixture()
def minimal_ms_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "minimal_ms.mpgo"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


@pytest.fixture()
def full_ms_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "full_ms.mpgo"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


@pytest.fixture()
def nmr_1d_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "nmr_1d.mpgo"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


@pytest.fixture()
def encrypted_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "encrypted.mpgo"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


@pytest.fixture()
def signed_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "signed.mpgo"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p
