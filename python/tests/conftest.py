"""Shared pytest fixtures for the ttio package."""
from __future__ import annotations

import importlib.util
import shutil
import sys
from pathlib import Path
import pytest

_REPO_ROOT = Path(__file__).resolve().parents[2]
_OBJC_FIXTURES = _REPO_ROOT / "objc" / "Tests" / "Fixtures" / "ttio"
_FIXTURES_DIR = Path(__file__).resolve().parent / "fixtures"
_GENERATED_DIR = _FIXTURES_DIR / "_generated"


def _load_fixture_module(name: str):
    """Import ``tests/fixtures/<name>.py`` without requiring tests to be a package.

    The existing test layout has no ``__init__.py``, so ``import
    tests.fixtures`` would change pytest's discovery mode (rootdir,
    conftest scope). Loading the file by path keeps the new modules
    importable from fixtures/conftest while leaving discovery alone.
    """
    mod_name = f"_ttio_fixture_{name}"
    if mod_name in sys.modules:
        return sys.modules[mod_name]
    spec = importlib.util.spec_from_file_location(mod_name, _FIXTURES_DIR / f"{name}.py")
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    sys.modules[mod_name] = module
    spec.loader.exec_module(module)
    return module


# v0.9 M57 — register markers for integration / stress / network gating.
# Default CI runs ``pytest -m "not stress and not requires_network and not aspirational"``;
# nightly CI runs the full suite. See HANDOFF.md binding decision 49.
_MARKERS = (
    ("requires_thermorawfileparser", "skip without ThermoRawFileParser CLI on PATH"),
    ("requires_opentims", "skip without opentimspy installed"),
    ("requires_pyimzml", "skip without pyimzml installed"),
    ("requires_pyteomics", "skip without pyteomics installed"),
    ("requires_pymzml", "skip without pymzml installed"),
    ("requires_isatools", "skip without isatools installed"),
    ("requires_network", "skip without network access (downloads fixtures)"),
    ("requires_s3", "skip without S3 / MinIO endpoint available"),
    ("stress", "long-running stress / benchmark test"),
    ("aspirational", "depends on a not-yet-implemented feature; tracks intent"),
)


def pytest_configure(config: pytest.Config) -> None:
    for name, doc in _MARKERS:
        config.addinivalue_line("markers", f"{name}: {doc}")


@pytest.fixture(scope="session")
def objc_fixtures_dir() -> Path:
    """Directory of reference .tio fixtures produced by the ObjC build."""
    if not _OBJC_FIXTURES.is_dir():
        pytest.skip(f"ObjC fixtures not found at {_OBJC_FIXTURES}")
    return _OBJC_FIXTURES


@pytest.fixture()
def minimal_ms_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "minimal_ms.tio"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


@pytest.fixture()
def full_ms_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "full_ms.tio"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


@pytest.fixture()
def nmr_1d_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "nmr_1d.tio"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


@pytest.fixture()
def encrypted_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "encrypted.tio"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


@pytest.fixture()
def signed_fixture(objc_fixtures_dir: Path) -> Path:
    p = objc_fixtures_dir / "signed.tio"
    if not p.is_file():
        pytest.skip(f"{p} missing")
    return p


# ---------------------------------------------------------------------------
# v0.9 M57 — synthetic + downloaded fixture access helpers.
# ---------------------------------------------------------------------------

@pytest.fixture(scope="session")
def fixtures_dir() -> Path:
    """Root of the in-repo fixture tooling."""
    return _FIXTURES_DIR


@pytest.fixture(scope="session")
def synth_fixture(tmp_path_factory: pytest.TempPathFactory):
    """Generate (or reuse) one of the synthetic .tio fixtures by name.

    Generation is cached for the test session; large fixtures
    (``synth_100k``) are produced lazily on first request.
    """
    generate = _load_fixture_module("generate")

    target = _GENERATED_DIR
    target.mkdir(parents=True, exist_ok=True)
    cache: dict[str, Path] = {}

    def _factory(name: str) -> Path:
        if name in cache:
            return cache[name]
        if name not in generate.GENERATORS:
            pytest.fail(f"unknown synthetic fixture: {name}")
        out = target / f"{name}.tio"
        if not out.is_file():
            generate.GENERATORS[name](target)
        cache[name] = out
        return out

    return _factory


@pytest.fixture(scope="session")
def downloaded_fixture():
    """Resolve a cached downloaded fixture by name; skip if not present.

    Tests that need a network-only fixture should be marked
    ``@pytest.mark.requires_network`` and use this fixture to access
    the file without forcing a download from inside the test.
    """
    download = _load_fixture_module("download")

    def _resolve(name: str) -> Path:
        path = download.get(name)
        if path is None:
            pytest.skip(f"fixture '{name}' not downloaded; run tests/fixtures/download.py fetch {name}")
        return path

    return _resolve


def pytest_collection_modifyitems(config: pytest.Config, items: list[pytest.Item]) -> None:
    """Auto-skip tests requiring optional third-party packages when absent."""
    package_for_marker = {
        "requires_pyimzml": "pyimzml",
        "requires_pyteomics": "pyteomics",
        "requires_pymzml": "pymzml",
        "requires_isatools": "isatools",
        "requires_opentims": "opentimspy",
    }
    for item in items:
        for marker in item.iter_markers():
            pkg = package_for_marker.get(marker.name)
            if pkg is None:
                continue
            try:
                __import__(pkg)
            except ImportError:
                item.add_marker(pytest.mark.skip(reason=f"requires {pkg}"))
        if "requires_thermorawfileparser" in {m.name for m in item.iter_markers()}:
            if shutil.which("ThermoRawFileParser") is None and shutil.which("thermorawfileparser") is None:
                item.add_marker(pytest.mark.skip(reason="ThermoRawFileParser CLI not on PATH"))
