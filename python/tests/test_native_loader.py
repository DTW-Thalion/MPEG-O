import ctypes
import os
from pathlib import Path

import pytest

from ttio.codecs import _native_loader


@pytest.fixture(autouse=True)
def _drop_loader_cache():
    """Every test here repoints the loader, at a fake library or at
    nothing. monkeypatch restores the environment afterwards but not the
    module cache, which then holds that fake handle, or a cached miss,
    for the rest of the session: the codec bindings quietly do nothing
    and later tests read back a default they never set. Drop the cache
    on the way out so the next load resolves against the restored
    environment."""
    yield
    _native_loader.reset_cache()


def _make_fake_lib(tmp_path: Path, name: str) -> Path:
    """Compile a trivial shared lib exporting one symbol, named `name`."""
    src = tmp_path / "fake.c"
    src.write_text("int ttio_rans_probe(void){return 42;}\n")
    out = tmp_path / name
    rc = os.system(f'cc -shared -fPIC -o "{out}" "{src}"')
    if rc != 0:
        pytest.skip("no C compiler available to build the fake lib")
    return out


def test_env_path_file_wins(tmp_path, monkeypatch):
    lib = _make_fake_lib(tmp_path, "libttio_rans.so")
    monkeypatch.setenv("TTIO_RANS_LIB_PATH", str(lib))
    _native_loader.reset_cache()
    handle = _native_loader.load_ttio_rans()
    assert handle is not None
    assert handle.ttio_rans_probe() == 42


def test_env_path_directory(tmp_path, monkeypatch):
    _make_fake_lib(tmp_path, "libttio_rans.so")
    monkeypatch.setenv("TTIO_RANS_LIB_PATH", str(tmp_path))
    _native_loader.reset_cache()
    assert _native_loader.load_ttio_rans() is not None


def test_bundled_libs_dir_is_searched(tmp_path, monkeypatch):
    # No env var; lib lives only in a simulated bundled ``.libs`` dir.
    monkeypatch.delenv("TTIO_RANS_LIB_PATH", raising=False)
    libs = tmp_path / ".libs"
    libs.mkdir()
    _make_fake_lib(libs, "libttio_rans.so")
    monkeypatch.setattr(_native_loader, "_bundled_libs_dirs", lambda: [libs])
    _native_loader.reset_cache()
    assert _native_loader.load_ttio_rans() is not None


def test_missing_returns_none(tmp_path, monkeypatch):
    monkeypatch.delenv("TTIO_RANS_LIB_PATH", raising=False)
    monkeypatch.setattr(_native_loader, "_bundled_libs_dirs", lambda: [tmp_path])
    monkeypatch.setattr(_native_loader, "_bare_names", lambda: ["definitely_not_a_real_lib.so"])
    monkeypatch.setattr(ctypes.util, "find_library", lambda _: None)
    _native_loader.reset_cache()
    assert _native_loader.load_ttio_rans() is None
