# TTI-O `ttio` PyPI Publishing (sdist + binary wheels) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Publish the `ttio` Python SDK to (Test)PyPI as a self-contained distribution — a buildable sdist **and** cross-platform binary wheels that bundle the native `libttio_rans` shared library — so downstream packages (e.g. `ttio-mcp`) can depend on `ttio>=1.7` from an index instead of a `git+` URL.

**Architecture:** Switch the build backend to **scikit-build-core** (CMake-native Python builds). An **in-tree PEP 517 backend wrapper** copies the sibling `native/` C sources into the package tree before every sdist/wheel build, so both are self-contained. A new `python/CMakeLists.txt` drives CMake to build `libttio_rans` and install it into `ttio/.libs/` inside the wheel. The four ctypes codec loaders are unified into one shared helper that *also* searches the bundled `ttio/.libs/` directory. **cibuildwheel** produces manylinux/macOS/Windows wheels (zlib provided per-platform; libs vendored via auditwheel/delocate/delvewheel). A GitHub Actions workflow builds sdist + wheels on tag and publishes to **TestPyPI** via trusted publishing.

**Tech Stack:** Python 3.11/3.12, scikit-build-core, CMake ≥3.16, cibuildwheel, auditwheel/delocate/delvewheel, GitHub Actions OIDC trusted publishing, pytest, twine.

---

## Context & key facts (read before starting)

- The package lives in `python/` (`name = "ttio"`, version `1.7.1`, currently `setuptools` backend with optional Cython extensions in `setup.py`).
- The native library source is a **sibling** of the package: `native/src/*.c` + `native/include/`, built by `native/CMakeLists.txt` into target `ttio_rans` (SHARED). It requires `Threads` and `ZLIB`.
- Four modules each define their own ctypes loader (`_load_native_lib`) for `libttio_rans`:
  `python/src/ttio/codecs/{ref_diff_v2,fqzcomp_nx16_z,mate_info_v2,name_tokenizer_v2}.py`.
  Their current search order is: `$TTIO_RANS_LIB_PATH` → bare names (system loader) → `ctypes.util.find_library`. **None search the installed package dir.**
- `python/setup.py` also builds optional Cython accelerators (`_rans`, `_delta_rans`, `_fqzcomp_nx16_z`) with a pure-Python fallback. These must continue to build.
- CI (`.github/workflows/ci.yml`) builds `native/` and sets `TTIO_RANS_LIB_PATH=.../native/_build/libttio_rans.so` for Python jobs. Reuse that build invocation.
- Local dev box can build/test **Linux** artifacts (WSL Ubuntu, Python 3.12.3, CMake 3.28.3). macOS and Windows wheel legs are **CI-validated only** — tasks that touch them say so explicitly.

## File Structure

- `python/pyproject.toml` — **Modify.** Swap build backend to the in-tree wrapper; move Cython/native build config to scikit-build-core; add `[tool.cibuildwheel]`.
- `python/_build_backend.py` — **Create.** In-tree PEP 517 backend: vendors `../native` into `python/_native/`, then delegates to `scikit_build_core.build`.
- `python/CMakeLists.txt` — **Create.** Top-level CMake that builds `libttio_rans` from the vendored `_native/` sources and installs it into the wheel as `ttio/.libs/…`, plus builds the Cython extensions.
- `python/src/ttio/codecs/_native_loader.py` — **Create.** Single `load_ttio_rans()` helper; adds a bundled-`ttio/.libs/` search path.
- `python/src/ttio/codecs/{ref_diff_v2,fqzcomp_nx16_z,mate_info_v2,name_tokenizer_v2}.py` — **Modify.** Replace each private loader with the shared helper.
- `python/tests/test_native_loader.py` — **Create.** Unit tests for the shared loader's search order, including the bundled path.
- `python/setup.py` — **Delete** at the end (its Cython logic moves into `CMakeLists.txt`).
- `.github/workflows/publish-ttio.yml` — **Create.** Tag-triggered sdist+wheel build → TestPyPI.
- `python/docs/packaging.md` — **Create.** Maintainer runbook (how to cut a release, how to flip TestPyPI→PyPI, how the native lib is bundled).

---

## Phase 1 — Unify the native-library loader (locally testable, no build changes)

This phase is pure Python + tests and is independent of the build-system swap. Do it first; it de-risks everything downstream.

### Task 1: Shared loader helper with a bundled-path search

**Files:**
- Create: `python/src/ttio/codecs/_native_loader.py`
- Test: `python/tests/test_native_loader.py`

- [ ] **Step 1: Write the failing test**

```python
# python/tests/test_native_loader.py
import ctypes
import os
from pathlib import Path

import pytest

from ttio.codecs import _native_loader


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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd python && python -m pytest tests/test_native_loader.py -v`
Expected: FAIL — `ModuleNotFoundError: No module named 'ttio.codecs._native_loader'`

- [ ] **Step 3: Write the shared loader**

```python
# python/src/ttio/codecs/_native_loader.py
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
from functools import lru_cache
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd python && python -m pytest tests/test_native_loader.py -v`
Expected: PASS (4 passed, or some skipped if no `cc`).

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/codecs/_native_loader.py python/tests/test_native_loader.py
git commit -m "feat(codecs): shared libttio_rans loader with bundled .libs search"
```

### Task 2: Route the four codec modules through the shared loader

**Files:**
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py` (replace `_load_native_lib`/`_native_lib` usage)
- Modify: `python/src/ttio/codecs/ref_diff_v2.py`
- Modify: `python/src/ttio/codecs/mate_info_v2.py`
- Modify: `python/src/ttio/codecs/name_tokenizer_v2.py`

- [ ] **Step 1: Replace the loader in `fqzcomp_nx16_z.py`**

Delete the in-module `_load_native_lib` function (the `def _load_native_lib(): … return None` block) and the `_native_lib = None` global, and replace the line:

```python
_HAVE_NATIVE_LIB = _load_native_lib() is not None
```

with:

```python
from ttio.codecs._native_loader import load_ttio_rans  # noqa: E402

_native_lib = load_ttio_rans()
_HAVE_NATIVE_LIB = _native_lib is not None
```

Leave the subsequent `if _HAVE_NATIVE_LIB: _lib = _native_lib` and all ctypes
argtype/restype wiring unchanged.

- [ ] **Step 2: Repeat for the other three modules**

In each of `ref_diff_v2.py`, `mate_info_v2.py`, `name_tokenizer_v2.py`, find the
local loader (each has its own `ctypes.CDLL` search block / `_load_native_lib`)
and replace it with the same two-line pattern:

```python
from ttio.codecs._native_loader import load_ttio_rans

_native_lib = load_ttio_rans()
```

Preserve each module's existing `RuntimeError("… requires libttio_rans …")`
guards that fire when `_native_lib is None`.

- [ ] **Step 3: Run the codec test suites**

Run: `cd python && TTIO_RANS_LIB_PATH="$PWD/../native/_build/libttio_rans.so" python -m pytest tests -k "rans or fqz or ref_diff or mate_info or name_tok or codec" -q`
Expected: PASS — same results as before the refactor (the env-var path still resolves the lib).

- [ ] **Step 4: Run the full unit suite to confirm no regressions**

Run: `cd python && TTIO_RANS_LIB_PATH="$PWD/../native/_build/libttio_rans.so" python -m pytest -q`
Expected: PASS with coverage ≥ `fail_under` (86). If `native/_build/libttio_rans.so` is missing, build it first: `cmake -S native -B native/_build -DBUILD_TESTING=OFF && cmake --build native/_build`.

- [ ] **Step 5: Commit**

```bash
git add python/src/ttio/codecs/{fqzcomp_nx16_z,ref_diff_v2,mate_info_v2,name_tokenizer_v2}.py
git commit -m "refactor(codecs): use shared libttio_rans loader in all four codecs"
```

---

## Phase 2 — Self-contained build via scikit-build-core + in-tree backend

The sibling `native/` directory cannot be referenced from inside the sdist
(sdists cannot contain files above their root). The in-tree backend vendors a
copy into `python/_native/` at build time; CMake then builds from that copy, so
**both** sdist and wheel are self-contained.

### Task 3: Top-level CMake that builds the lib and the Cython extensions

**Files:**
- Create: `python/CMakeLists.txt`
- Modify: `python/.gitignore` (add `_native/`) — create the file if absent.

- [ ] **Step 1: Write `python/CMakeLists.txt`**

```cmake
cmake_minimum_required(VERSION 3.16)
project(ttio_python LANGUAGES C)

# The in-tree build backend copies ../native into ./_native before the build,
# so a self-contained sdist can rebuild the native library at install time.
# When developing in the full repo checkout, fall back to the sibling tree.
set(_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/_native")
if(NOT EXISTS "${_NATIVE_DIR}/CMakeLists.txt")
    set(_NATIVE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/../native")
endif()
if(NOT EXISTS "${_NATIVE_DIR}/CMakeLists.txt")
    message(FATAL_ERROR "native sources not found at ${_NATIVE_DIR}")
endif()

# Build libttio_rans (no tests, no JNI) and install it into the wheel under
# ttio/.libs so the runtime loader (_native_loader.py) finds it.
set(BUILD_TESTING OFF CACHE BOOL "" FORCE)
set(TTIO_RANS_BUILD_JNI OFF CACHE BOOL "" FORCE)
add_subdirectory("${_NATIVE_DIR}" "${CMAKE_CURRENT_BINARY_DIR}/native_build")

install(TARGETS ttio_rans
        LIBRARY DESTINATION ttio/.libs
        RUNTIME DESTINATION ttio/.libs   # Windows .dll
        ARCHIVE DESTINATION ttio/.libs)

# Optional Cython accelerators (byte-identical pure-Python fallback exists).
find_package(Python COMPONENTS Interpreter Development.Module REQUIRED)
find_program(CYTHON_EXECUTABLE cython)
if(CYTHON_EXECUTABLE)
    foreach(mod _rans _delta_rans _fqzcomp_nx16_z)
        set(_pyx "src/ttio/codecs/${mod}/${mod}.pyx")
        if(EXISTS "${CMAKE_CURRENT_SOURCE_DIR}/${_pyx}")
            set(_c "${CMAKE_CURRENT_BINARY_DIR}/${mod}.c")
            add_custom_command(OUTPUT "${_c}"
                COMMAND ${CYTHON_EXECUTABLE} -3 -o "${_c}" "${CMAKE_CURRENT_SOURCE_DIR}/${_pyx}"
                DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/${_pyx}")
            Python_add_library(${mod} MODULE "${_c}" WITH_SOABI)
            install(TARGETS ${mod} LIBRARY DESTINATION "ttio/codecs/${mod}")
        endif()
    endforeach()
endif()
```

> Note: `add_subdirectory` on `../native` requires a binary dir argument (given
> above) because it is outside the source tree in dev checkouts. In the sdist the
> path is `_native`, inside the tree, so this is robust either way.

- [ ] **Step 2: Add `_native/` to `python/.gitignore`**

Append the line `_native/` to `python/.gitignore` (create the file with that single line if it does not exist).

- [ ] **Step 3: Smoke-build the lib install locally**

Run: `cd python && cmake -S . -B build_smoke -DPython_EXECUTABLE=$(which python) && cmake --build build_smoke --target ttio_rans && cmake --install build_smoke --prefix build_smoke/stage`
Expected: `build_smoke/stage/ttio/.libs/libttio_rans.so` exists.
(Uses the sibling `../native` fallback since `_native/` is not yet vendored.)

- [ ] **Step 4: Commit**

```bash
git add python/CMakeLists.txt python/.gitignore
git commit -m "build(ttio): top-level CMake builds + installs libttio_rans into ttio/.libs"
```

### Task 4: In-tree PEP 517 backend that vendors `../native`

**Files:**
- Create: `python/_build_backend.py`
- Modify: `python/pyproject.toml` (`[build-system]`)

- [ ] **Step 1: Write the in-tree backend**

```python
# python/_build_backend.py
"""In-tree PEP 517 backend wrapping scikit-build-core.

Before each sdist/wheel build it copies the sibling ``../native`` C-library
sources into ``./_native`` so the produced artifact is self-contained (an sdist
cannot legally contain files above its own root). Delegates all real work to
``scikit_build_core.build``.
"""
from __future__ import annotations

import shutil
from pathlib import Path

from scikit_build_core import build as _skb

_HERE = Path(__file__).parent
_SRC = _HERE.parent / "native"
_DST = _HERE / "_native"


def _vendor_native() -> None:
    if not _SRC.is_dir():
        # Already vendored (building from an unpacked sdist) — nothing to do.
        if _DST.is_dir():
            return
        raise RuntimeError(f"native sources not found at {_SRC} or {_DST}")
    if _DST.is_dir():
        shutil.rmtree(_DST)
    shutil.copytree(
        _SRC, _DST,
        ignore=shutil.ignore_patterns("_build", "_build_tsan", "*.o", "*.so", "*.dll", "*.dylib"),
    )


# --- PEP 517 hooks: vendor, then delegate -------------------------------------
def build_wheel(wheel_directory, config_settings=None, metadata_directory=None):
    _vendor_native()
    return _skb.build_wheel(wheel_directory, config_settings, metadata_directory)


def build_sdist(sdist_directory, config_settings=None):
    _vendor_native()
    return _skb.build_sdist(sdist_directory, config_settings)


def build_editable(wheel_directory, config_settings=None, metadata_directory=None):
    _vendor_native()
    return _skb.build_editable(wheel_directory, config_settings, metadata_directory)


# Pass-through optional hooks.
get_requires_for_build_wheel = getattr(_skb, "get_requires_for_build_wheel", None)
get_requires_for_build_sdist = getattr(_skb, "get_requires_for_build_sdist", None)
get_requires_for_build_editable = getattr(_skb, "get_requires_for_build_editable", None)
prepare_metadata_for_build_wheel = getattr(_skb, "prepare_metadata_for_build_wheel", None)
prepare_metadata_for_build_editable = getattr(_skb, "prepare_metadata_for_build_editable", None)
```

- [ ] **Step 2: Rewrite `[build-system]` + add scikit-build-core config in `pyproject.toml`**

Replace the existing `[build-system]` block with:

```toml
[build-system]
requires = ["scikit-build-core>=0.9", "cython>=3.0"]
build-backend = "_build_backend"
backend-path = ["."]
```

Then add a scikit-build-core section (keep the existing `[project]` table as-is;
scikit-build-core reads PEP 621 metadata directly):

```toml
[tool.scikit-build]
minimum-version = "0.9"
build-dir = "build/{wheel_tag}"
wheel.packages = ["src/ttio"]
sdist.include = ["_native/**", "src/ttio/py.typed"]
sdist.exclude = ["_native/_build", "_native/_build_tsan"]
cmake.version = ">=3.16"
```

Remove the now-obsolete `[tool.setuptools*]` tables (`[tool.setuptools]`,
`[tool.setuptools.packages.find]`, `[tool.setuptools.package-data]`).

- [ ] **Step 3: Build an sdist and verify it is self-contained**

Run:
```bash
cd python && python -m build --sdist --outdir dist_test
tar tzf dist_test/ttio-1.7.1.tar.gz | grep -E "_native/(CMakeLists.txt|src/rans_core.c)" | head
```
Expected: both `_native/CMakeLists.txt` and `_native/src/rans_core.c` are listed
inside the tarball.

- [ ] **Step 4: Install the sdist into a fresh venv and import + use a native codec**

```bash
python -m venv /tmp/ttio_sdist && /tmp/ttio_sdist/bin/pip install dist_test/ttio-1.7.1.tar.gz
/tmp/ttio_sdist/bin/python -c "
from ttio.codecs import fqzcomp_nx16_z as f
assert f._HAVE_NATIVE_LIB, 'native lib not bundled/loaded'
print('OK: native lib loaded from wheel-bundled .libs')
"
```
Expected: `OK: native lib loaded from wheel-bundled .libs` (the lib was built
from the vendored sources and installed into `ttio/.libs/`, and the shared
loader found it with no env var set).

- [ ] **Step 5: Delete `setup.py` (logic now in CMake)**

```bash
git rm python/setup.py
```

- [ ] **Step 6: Commit**

```bash
git add python/_build_backend.py python/pyproject.toml
git commit -m "build(ttio): scikit-build-core + in-tree backend vendoring native sources"
```

### Task 5: Verify editable install + full test suite under the new backend

**Files:** none (verification only).

- [ ] **Step 1: Editable install in a clean venv**

```bash
python -m venv /tmp/ttio_dev && /tmp/ttio_dev/bin/pip install -e "python[test]"
```
Expected: install succeeds; `ttio/.libs/libttio_rans.so` present under the
build tree.

- [ ] **Step 2: Run the full unit suite (no env var — must use the bundled lib)**

Run: `/tmp/ttio_dev/bin/python -m pytest python/tests -q`
Expected: PASS at coverage ≥ 86, **without** `TTIO_RANS_LIB_PATH` set — proving
the bundled-path loader works end to end.

- [ ] **Step 3: Commit (if any lockfile/docs changed; otherwise skip)**

---

## Phase 3 — Cross-platform wheels via cibuildwheel (CI-validated)

Local box validates the **Linux** legs only. macOS/Windows legs are exercised in
CI; their tasks define acceptance by the green CI job, not a local run.

### Task 6: cibuildwheel configuration with per-platform zlib + lib repair

**Files:**
- Modify: `python/pyproject.toml` (add `[tool.cibuildwheel]`)

- [ ] **Step 1: Add cibuildwheel config**

```toml
[tool.cibuildwheel]
build = "cp311-* cp312-*"
skip = "*-musllinux_i686 *_i686 pp*"
build-frontend = "build"
test-command = "python -c \"from ttio.codecs import fqzcomp_nx16_z as f; assert f._HAVE_NATIVE_LIB\""

[tool.cibuildwheel.linux]
# manylinux needs zlib headers to satisfy find_package(ZLIB) in the native build.
before-all = "yum install -y zlib-devel || apt-get update && apt-get install -y zlib1g-dev"
archs = ["x86_64", "aarch64"]
repair-wheel-command = "auditwheel repair -w {dest_dir} {wheel}"

[tool.cibuildwheel.macos]
archs = ["x86_64", "arm64"]
# zlib ships with macOS SDK; delocate vendors libttio_rans into the wheel.
repair-wheel-command = "delocate-wheel --require-archs {delocate_archs} -w {dest_dir} -v {wheel}"

[tool.cibuildwheel.windows]
archs = ["AMD64"]
# delvewheel vendors the DLL; zlib comes from the toolchain (see Task 7 notes).
before-build = "pip install delvewheel"
repair-wheel-command = "delvewheel repair -w {dest_dir} {wheel}"
```

- [ ] **Step 2: Build Linux wheels locally with cibuildwheel**

Run: `cd python && pipx run cibuildwheel --platform linux --only cp312-manylinux_x86_64`
Expected: a repaired `ttio-1.7.1-cp312-cp312-manylinux_*_x86_64.whl` in
`wheelhouse/`, and the in-build `test-command` passes (native lib bundled).

- [ ] **Step 3: Inspect the wheel to confirm the lib is vendored**

Run: `unzip -l python/wheelhouse/ttio-1.7.1-cp312-*_x86_64.whl | grep -E "\.libs/|libttio_rans"`
Expected: the wheel contains `ttio/.libs/libttio_rans*.so` (and the auditwheel
hash-suffixed copy).

- [ ] **Step 4: Commit**

```bash
git add python/pyproject.toml
git commit -m "build(ttio): cibuildwheel config (manylinux/macos/windows, lib vendoring)"
```

### Task 7: Resolve the Windows zlib dependency for the native build

**Files:**
- Modify: `native/CMakeLists.txt` *(only if needed — see step 1)* or `python/pyproject.toml` `[tool.cibuildwheel.windows]`.

This is a focused investigation task: `find_package(ZLIB REQUIRED)` must succeed
inside the Windows cibuildwheel container, which has no system zlib by default.

- [ ] **Step 1: Choose a zlib provisioning approach and apply it**

Pick the lowest-friction option that makes `find_package(ZLIB)` succeed on the
Windows runner, and wire it into `[tool.cibuildwheel.windows].before-all`:
  - **Option A (preferred):** install zlib via the runner's vcpkg and pass
    `CMAKE_TOOLCHAIN_FILE`:
    `before-all = "vcpkg install zlib:x64-windows-static-md"` and add
    `[tool.cibuildwheel.windows.environment]`
    `CMAKE_ARGS = "-DCMAKE_TOOLCHAIN_FILE=$VCPKG_INSTALLATION_ROOT/scripts/buildsystems/vcpkg.cmake -DVCPKG_TARGET_TRIPLET=x64-windows-static-md"`.
  - **Option B:** vendor a minimal zlib via CMake `FetchContent` in
    `native/CMakeLists.txt`, guarded by `if(WIN32 AND NOT ZLIB_FOUND)`.

Acceptance: the Windows job in Task 9 builds wheels green; do not merge with a
red Windows leg unless explicitly descoped (see Task 10).

- [ ] **Step 2: Commit the chosen change**

```bash
git add native/CMakeLists.txt python/pyproject.toml
git commit -m "build(ttio): provision zlib for the Windows wheel build"
```

---

## Phase 4 — Publish workflow + docs (TestPyPI)

### Task 8: Maintainer packaging runbook

**Files:**
- Create: `python/docs/packaging.md`

- [ ] **Step 1: Write the runbook**

Write `python/docs/packaging.md` covering, with exact commands: how the native
lib is bundled (`_build_backend.py` vendors `../native` → CMake installs into
`ttio/.libs/` → repair tools vendor it; runtime found by `_native_loader.py`);
how to build locally (`python -m build`, `cibuildwheel --platform linux`); how to
cut a release (bump `version` in `pyproject.toml`, tag `vX.Y.Z`, push tag); the
TestPyPI vs PyPI flip (change the workflow `repository-url` / environment and the
PyPI project's trusted-publisher config); and the `twine check dist/*` gate.

- [ ] **Step 2: Commit**

```bash
git add python/docs/packaging.md
git commit -m "docs(ttio): packaging + release runbook"
```

### Task 9: GitHub Actions — build sdist + wheels, publish to TestPyPI

**Files:**
- Create: `.github/workflows/publish-ttio.yml`

- [ ] **Step 1: Write the workflow**

```yaml
name: publish-ttio
on:
  push:
    tags: ["ttio-v*"]   # e.g. ttio-v1.7.1
  workflow_dispatch:

jobs:
  sdist:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with: { python-version: "3.12" }
      - run: pipx run build --sdist python --outdir dist
      - run: pipx run twine check dist/*
      - uses: actions/upload-artifact@v4
        with: { name: sdist, path: dist/*.tar.gz }

  wheels:
    strategy:
      matrix:
        os: [ubuntu-latest, macos-13, macos-14, windows-latest]
    runs-on: ${{ matrix.os }}
    steps:
      - uses: actions/checkout@v4
      - uses: pypa/cibuildwheel@v2.21
        with: { package-dir: python }
      - uses: actions/upload-artifact@v4
        with:
          name: wheels-${{ matrix.os }}
          path: wheelhouse/*.whl

  publish-testpypi:
    needs: [sdist, wheels]
    runs-on: ubuntu-latest
    environment: testpypi          # configure trusted publishing on TestPyPI
    permissions: { id-token: write }
    steps:
      - uses: actions/download-artifact@v4
        with: { path: dist, merge-multiple: true }
      - uses: pypa/gh-action-pypi-publish@release/v1
        with:
          repository-url: https://test.pypi.org/legacy/
          packages-dir: dist
```

- [ ] **Step 2: Validate the workflow on a throwaway tag**

```bash
git push origin packaging/ttio-pypi-wheels
git tag ttio-v1.7.1-rc1 && git push origin ttio-v1.7.1-rc1
```
Expected: the `sdist` and all four `wheels` matrix jobs go green; `twine check`
passes. The `publish-testpypi` job uploads to TestPyPI **only after** the
TestPyPI project + trusted publisher are configured (maintainer action — see
Task 8). Until then it will fail at the publish step with an auth error, which is
expected and does not invalidate the build jobs.

- [ ] **Step 3: Verify install from TestPyPI (after trusted publishing is set up)**

```bash
python -m venv /tmp/ttio_tp && /tmp/ttio_tp/bin/pip install \
  --index-url https://test.pypi.org/simple/ \
  --extra-index-url https://pypi.org/simple/ "ttio==1.7.1"
/tmp/ttio_tp/bin/python -c "from ttio.codecs import fqzcomp_nx16_z as f; assert f._HAVE_NATIVE_LIB; print('TestPyPI install OK')"
```
Expected: `TestPyPI install OK` on at least Linux (the platform whose wheel
matches the runner). `--extra-index-url` resolves `ttio`'s runtime deps
(h5py/numpy/pyarrow) from real PyPI.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/publish-ttio.yml
git commit -m "ci(ttio): build sdist + wheels and publish to TestPyPI on tag"
```

### Task 10: Open the PR; record any descoped platform legs

**Files:** none (process).

- [ ] **Step 1: Open the PR (push from Windows git per repo convention)**

```bash
# from Windows:
"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O" push -u origin packaging/ttio-pypi-wheels
gh pr create --repo DTW-Thalion/TTI-O --base main \
  --title "Package ttio for PyPI: sdist + cross-platform wheels (TestPyPI)" \
  --body "Implements docs/superpowers/plans/2026-06-14-ttio-pypi-wheels.md."
```

- [ ] **Step 2: If a platform leg is not green and is being deferred, say so explicitly**

If (e.g.) the Windows leg is descoped for a follow-up, add a checklist item to the
PR body listing exactly which wheels ship and which are deferred — never let a
red/absent leg read as "all platforms covered."

---

## Downstream follow-up (separate change, after `ttio` is on an index)

Once `ttio` resolves from (Test)PyPI, update **`TTIO-MCP-Server`**:
`pyproject.toml` dependency `ttio[network,crypto] @ git+…@v1.7.1` →
`ttio[network,crypto]>=1.7`; same for the `pqc`/`cloud` extras; then `ttio-mcp`
itself becomes publishable. (Tracked separately; not part of this plan.)

---

## Self-Review

- **Spec coverage:** "Both, staged in one PR" → Phases 1–4 land together (loader, sdist, wheels, workflow). "TestPyPI for now" → Task 9 targets `test.pypi.org/legacy/`; Task 8 documents the PyPI flip. Native-lib bundling (the core blocker) → Tasks 1–4 + 6–7. sdist self-containment (sibling dir) → Task 4 in-tree backend. Loader can't find bundled lib → Task 1.
- **Placeholder scan:** Task 7 is an investigation task with explicit options + a concrete acceptance criterion (green Windows job), not a "TODO"; all code steps include full code.
- **Type consistency:** the loader API (`load_ttio_rans()`, `reset_cache()`, `_bundled_libs_dirs`, `_bare_names`) is used identically in Task 1 tests, Task 1 impl, and Task 2 call sites; the install path `ttio/.libs/` is consistent across CMake (Task 3), the loader (Task 1), and the wheel-inspection checks (Tasks 4, 6).
