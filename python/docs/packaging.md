# Packaging & releasing `ttio`

How the `ttio` distribution is built, how the native `libttio_rans` library is
bundled, and how to cut a (Test)PyPI release.

## How the native library ships

`ttio` is a pure-Python package **plus** a native C library, `libttio_rans`,
whose sources live in the repo at `../native/` (sibling of `python/`). Several
codecs (`REF_DIFF_V2`, `NAME_TOKENIZED_V2`, `FQZCOMP_NX16_Z` V4, `MATE_INLINE_V2`)
load it via `ctypes` and hard-fail without it, so a usable distribution must
bundle it. The pipeline:

1. **`_build_backend.py`** (the in-tree PEP 517 backend, configured in
   `pyproject.toml` `[build-system]`) wraps `scikit-build-core`. Before every
   sdist/wheel build it copies `../native` into `python/_native/` so the build
   is self-contained — an sdist cannot legally contain files above its own root.
2. **`CMakeLists.txt`** (driven by scikit-build-core) builds `libttio_rans` from
   `_native/` and `install()`s it into the wheel at **`ttio/.libs/`**. It also
   builds the optional Cython accelerators when Cython + headers are present
   (their pure-Python fallbacks are byte-identical, just slower).
3. **`ttio/codecs/_native_loader.py`** finds the library at runtime. Search
   order: `$TTIO_RANS_LIB_PATH` → bundled `ttio/.libs/` → system loader (bare
   names) → `ctypes.util.find_library`. The bundled-`.libs` step is what makes
   a pip-installed wheel work with no environment configuration.
4. For **binary wheels**, the repair tools (`auditwheel` on Linux,
   `delocate` on macOS, `delvewheel` on Windows) vendor `libttio_rans` (and its
   `zlib` dependency) into the wheel and fix up the dynamic-loader paths.

## Local builds

```bash
cd python

# sdist (self-contained: vendors _native/). ~2 MB.
python -m build --sdist --outdir dist

# Verify the sdist is self-contained and not bloated:
tar tzf dist/ttio-1.7.1.tar.gz | grep _native/src/rans_core.c   # present
du -m dist/ttio-1.7.1.tar.gz                                    # ~2 MB, not 100s

# Install the sdist into a clean venv and confirm the native lib is bundled:
python -m venv /tmp/v && /tmp/v/bin/pip install websockets dist/ttio-1.7.1.tar.gz
/tmp/v/bin/python -c "from ttio.codecs import fqzcomp_nx16_z as f; assert f._HAVE_NATIVE_LIB"
```

> `websockets` is installed above only because `import ttio` eagerly imports the
> workbench client. Real consumers get it via the `network`/`all` extras.

## Building wheels (cibuildwheel)

**Build wheels from the sdist, not the project directory.** cibuildwheel mounts
only the package dir into its build container, so the sibling `../native` is not
reachable there — but the sdist already vendors `_native/`, so it builds cleanly:

```bash
cd python
python -m build --sdist --outdir dist
# Linux x86_64 (needs Docker):
python -m cibuildwheel --platform linux --only cp312-manylinux_x86_64 \
    --output-dir wheelhouse dist/ttio-1.7.1.tar.gz

# Confirm the wheel vendors the lib:
unzip -l wheelhouse/ttio-1.7.1-cp312-*_x86_64.whl | grep -E "\.libs/|libttio_rans"
```

The full matrix (cp311/cp312 × {linux x86_64/aarch64, macOS x86_64/arm64,
Windows AMD64}) runs in CI — see `.github/workflows/publish-ttio.yml`. Config
lives in `[tool.cibuildwheel]` in `pyproject.toml`. The Linux build installs
`zlib-devel` (`before-all`); Windows provisions zlib via the workflow; macOS
uses the SDK's zlib.

## Cutting a release

1. Bump the version in **two** places (keep them in sync):
   - `pyproject.toml` → `[project] version`
   - `src/ttio/__init__.py` → `__version__`
2. Update `CHANGELOG`/release notes as applicable.
3. Commit, open a PR, merge to `main`.
4. Tag and push — the tag triggers `publish-ttio.yml`:
   ```bash
   git tag ttio-vX.Y.Z && git push origin ttio-vX.Y.Z
   ```
   The workflow builds the sdist + the wheel matrix, runs `twine check`, and
   publishes to **TestPyPI** via trusted publishing.
5. Verify the upload:
   ```bash
   python -m venv /tmp/tp && /tmp/tp/bin/pip install \
     --index-url https://test.pypi.org/simple/ \
     --extra-index-url https://pypi.org/simple/ "ttio==X.Y.Z"
   ```
   (`--extra-index-url` resolves runtime deps — h5py/numpy/pyarrow — from real
   PyPI.)

## TestPyPI → PyPI

The workflow targets TestPyPI today. To publish to real PyPI:

1. Create the `ttio` project + a trusted publisher on **pypi.org** (Publishing →
   add a GitHub Actions publisher: repo `DTW-Thalion/TTI-O`, workflow
   `publish-ttio.yml`, environment `pypi`).
2. In `publish-ttio.yml`, point the publish job at PyPI: drop the
   `repository-url` override (defaults to PyPI) and switch the job `environment`
   from `testpypi` to `pypi`.
3. Because the build is sdist + binary wheels with no direct-URL dependencies,
   the distribution is PyPI-acceptable (unlike `ttio-mcp`, which currently
   depends on `ttio` via a `git+` URL — that flips to `ttio>=1.7` once `ttio`
   is on PyPI).

## Gotchas

- **Never** let the sdist balloon: scikit-build-core can't scope it via git
  (the package is a repo subdirectory), so `[tool.scikit-build] sdist.exclude`
  must keep out `.venv`, `docs`, `build`, coverage HTML, and caches.
- Keep `__version__` and `[project].version` in lockstep — `test_smoke` only
  checks SemVer shape, so a mismatch won't be caught by tests.
- Building wheels from the **project dir** (not the sdist) fails: `../native`
  is outside the cibuildwheel mount.
