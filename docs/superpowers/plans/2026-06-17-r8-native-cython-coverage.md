# R8 — Native C + Cython Coverage Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make native C (gcov, report-only) and Cython (linetrace, enforced floor) codec coverage visible in a dedicated CI workflow, without changing the production build path or any always-on gate.

**Architecture:** Two opt-in CMake options (`TTIO_COVERAGE` in `native/CMakeLists.txt`, `TTIO_CYTHON_LINETRACE` in `python/CMakeLists.txt`) default `OFF`. A driver script builds an instrumented native tree and runs `ctest` + `gcovr`. A separate `coverage-cython.cfg` + curated codec tests measure linetrace coverage. A new `.github/workflows/native-coverage.yml` runs both halves in two path-filtered jobs (C report-only, Cython enforced).

**Tech Stack:** CMake, gcc 13 + `gcov`/`gcovr`, Cython 3, coverage.py + `Cython.Coverage` plugin, GitHub Actions. Build/test in WSL `~/TTI-O`.

**Spec:** `docs/superpowers/specs/2026-06-17-r8-native-cython-coverage-design.md`

**Branch:** `feat/r8-native-cython-coverage` (already created; spec already committed at `ef46faab`).

---

## Environment notes (read first)

- All build/test commands run in WSL Ubuntu at `~/TTI-O`. From the harness, prefix with `wsl.exe -d Ubuntu -- bash -lc '...'` or run inside a WSL shell.
- Measure exit codes with PowerShell `$LASTEXITCODE`, NOT `; echo $?` nested in `wsl bash -lc` (it misreports — campaign lesson).
- `gcovr` is NOT installed locally — install once: `pip install --user gcovr` (or into the active venv).
- `gcc 13.3`, `gcov`, `cython`, `coverage` are present. Local Python venv: `python/.venv`.
- Push via Windows git; `gh` on the Windows side. Do NOT push from WSL.
- Commit identity in WSL: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit`. Multi-line messages via `-F` file or stdin heredoc (apostrophes/parens break `-m '...'`).

## File Structure

- **Modify** `native/CMakeLists.txt` — add `TTIO_COVERAGE` option (directory-level instrumentation flags).
- **Create** `scripts/native-coverage.sh` — instrumented build + ctest + gcovr driver.
- **Modify** `python/CMakeLists.txt` — add `TTIO_CYTHON_LINETRACE` option (cython `-X linetrace=True` + `CYTHON_TRACE_NOGIL=1`).
- **Create** `python/coverage-cython.cfg` — coverage.py config with the `Cython.Coverage` plugin, scoped to the 3 `.pyx` dirs.
- **Create** `.github/workflows/native-coverage.yml` — two jobs: `c-coverage` (report-only), `cython-coverage` (enforced floor).

---

## Task 1: Native C — `TTIO_COVERAGE` CMake option

**Files:**
- Modify: `native/CMakeLists.txt` (insert after `find_package(ZLIB REQUIRED)`, before `add_library(ttio_rans ...)`)

Rationale: a directory-level `add_compile_options`/`add_link_options` placed BEFORE any target is defined instruments the `ttio_rans` library AND all 23 test executables in one block — no need to edit each `add_executable`. `bench/` gets `.gcno` files but is never run by ctest (no `.gcda`), and `gcovr` filters it out anyway.

- [ ] **Step 1: Add the option block**

In `native/CMakeLists.txt`, immediately after the line `find_package(ZLIB REQUIRED)`, insert:

```cmake
# Optional gcov/llvm-cov instrumentation (R8 coverage visibility).
# Default OFF so production / wheel / ObjC / Java builds are unaffected.
# Placed before any target so it instruments the library AND every test
# executable defined below in one shot. MSVC has no --coverage; gcov is a
# GCC/Clang feature, so this is a no-op there. Use a fresh build dir
# (native/_covbuild) — never the shared native/_build.
option(TTIO_COVERAGE "Instrument with --coverage for gcov reporting" OFF)
if(TTIO_COVERAGE AND NOT MSVC)
    add_compile_options(--coverage -O0 -g)
    add_link_options(--coverage)
    message(STATUS "ttio_rans: gcov coverage instrumentation ENABLED")
endif()
```

- [ ] **Step 2: Configure an instrumented build and verify the flag takes effect**

Run:
```bash
cd ~/TTI-O/native && rm -rf _covbuild && \
  cmake -S . -B _covbuild -G Ninja -DTTIO_COVERAGE=ON -DBUILD_TESTING=ON 2>&1 | grep -i "coverage instrumentation"
```
Expected: prints `ttio_rans: gcov coverage instrumentation ENABLED`.

- [ ] **Step 3: Build and confirm `.gcno` instrumentation files were emitted**

Run:
```bash
cd ~/TTI-O/native && cmake --build _covbuild 2>&1 | tail -3 && \
  find _covbuild -name '*.gcno' | head && echo "gcno count: $(find _covbuild -name '*.gcno' | wc -l)"
```
Expected: build succeeds; `gcno count` is > 0 (one per instrumented translation unit, ~20+).

- [ ] **Step 4: Commit**

```bash
cd ~/TTI-O && git add native/CMakeLists.txt && \
  git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "R8: add TTIO_COVERAGE CMake option for native gcov instrumentation

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(`_covbuild/` is a build dir — confirm it is gitignored or NOT staged. Check `git status`; if `_covbuild` shows as untracked, add `native/_covbuild/` to `.gitignore` in this commit.)

---

## Task 2: Native C — `scripts/native-coverage.sh` driver

**Files:**
- Create: `scripts/native-coverage.sh`
- Possibly modify: `.gitignore` (ignore `native/_covbuild/`)

- [ ] **Step 1: Write the driver script**

Create `scripts/native-coverage.sh` with exactly:

```bash
#!/usr/bin/env bash
# scripts/native-coverage.sh -- Build native/_covbuild with gcov
# instrumentation, run the native ctest suite, and emit a gcovr coverage
# report (console + Cobertura XML + HTML) scoped to native/src.
#
# REPORT-ONLY: this script never fails on a coverage threshold. It exits
# nonzero only if cmake configure, the build, or ctest fails. The C rANS
# kernels are SIMD-dispatched (scalar/SSE4.1/AVX2 chosen at runtime by CPU),
# so per-file line counts depend on the runner CPU and a floor would
# false-fail. See docs/superpowers/specs/2026-06-17-r8-native-cython-coverage-design.md.
#
# Uses a dedicated build dir (native/_covbuild) so the uninstrumented
# native/_build reused by other jobs / local dev is never contaminated.
#
# Deps: cmake, ninja, a C compiler with matching gcov, gcovr, zlib1g-dev.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
NATIVE_DIR="${REPO_ROOT}/native"
BUILD_DIR="${NATIVE_DIR}/_covbuild"

# Registered ctests that need external on-disk fixtures and cannot
# self-generate them are excluded here (and logged). Verified during R8
# implementation; update the regex + comment if the suite changes.
CTEST_EXCLUDE="${TTIO_CTEST_EXCLUDE:-}"

echo "==> Configuring instrumented build at ${BUILD_DIR}"
rm -rf "${BUILD_DIR}"
cmake -S "${NATIVE_DIR}" -B "${BUILD_DIR}" -G Ninja \
    -DTTIO_COVERAGE=ON -DBUILD_TESTING=ON

echo "==> Building"
cmake --build "${BUILD_DIR}"

echo "==> Running ctest"
if [ -n "${CTEST_EXCLUDE}" ]; then
    echo "    (excluding fixture-dependent tests: ${CTEST_EXCLUDE})"
    ( cd "${BUILD_DIR}" && ctest --output-on-failure -E "${CTEST_EXCLUDE}" )
else
    ( cd "${BUILD_DIR}" && ctest --output-on-failure )
fi

echo "==> Generating gcovr report (scoped to native/src)"
mkdir -p "${BUILD_DIR}/coverage-html"
gcovr \
    --root "${NATIVE_DIR}" \
    --filter "${NATIVE_DIR}/src/" \
    --print-summary \
    --xml-pretty -o "${BUILD_DIR}/coverage.xml" \
    --html-details "${BUILD_DIR}/coverage-html/index.html" \
    "${BUILD_DIR}"

echo "==> Native C coverage report written to ${BUILD_DIR}/coverage.xml"
```

- [ ] **Step 2: Make it executable**

Run: `chmod +x ~/TTI-O/scripts/native-coverage.sh`
Expected: no output.

- [ ] **Step 3: Run it; verify clean ctest and record any fixture exclusions**

Run: `cd ~/TTI-O && pip install --user gcovr >/dev/null 2>&1; ./scripts/native-coverage.sh`
Expected: configure + build succeed; ctest runs and reports `100% tests passed` (or identifies failing tests). gcovr prints a `lines: NN.N%` summary and writes `coverage.xml`.

If any registered ctest FAILS because it needs an external fixture (candidates: `rc_cram_byte_equal`, `fqzcomp_qual_strategy1`), confirm it is fixture-dependent (read the test source), then re-run with the exclusion and bake it into the script's default `CTEST_EXCLUDE` value (replace the empty default) with a one-line comment naming the reason. Do NOT exclude a test that fails for a real reason. Record the final passing ctest count and the coverage % in the commit message.

- [ ] **Step 4: Confirm the report is scoped to `native/src` only**

Run: `grep -o 'filename="[^"]*"' ~/TTI-O/native/_covbuild/coverage.xml | sort -u | head -30`
Expected: every path is under `src/` (no `tests/`, no `bench/`, no `/usr/` system headers).

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O && git add scripts/native-coverage.sh .gitignore && \
  git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -F - <<'MSG'
R8: native-coverage.sh — instrumented ctest + gcovr report (report-only)

Runs the 23 native ctests under gcov in a fresh native/_covbuild and emits
a gcovr report scoped to native/src. Report-only (no floor): SIMD dispatch
makes per-file counts CPU-dependent. <RECORD ctest count + coverage % here>.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
MSG
```

---

## Task 3: Cython — `TTIO_CYTHON_LINETRACE` CMake option

**Files:**
- Modify: `python/CMakeLists.txt` (the `find_package(Python ...)` / `foreach(mod ...)` block near the end)

- [ ] **Step 1: Add the option and thread it through the foreach**

In `python/CMakeLists.txt`, find the block that begins `find_package(Python COMPONENTS Interpreter Development.Module)`. Add the option just before it:

```cmake
# Optional Cython linetrace instrumentation (R8 coverage visibility).
# Default OFF: linetrace adds per-line tracing overhead, so production
# wheels must NOT enable it. When ON, the .pyx are cythonized with
# `-X linetrace=True` and the C extensions compiled with
# CYTHON_TRACE_NOGIL=1, which coverage.py's Cython.Coverage plugin reads.
option(TTIO_CYTHON_LINETRACE "Compile .pyx with linetrace for coverage" OFF)
```

Then inside the `if(Python_Development.Module_FOUND AND CYTHON_EXECUTABLE)` block, modify the cython invocation and the library target. Replace the existing `foreach` body so it reads:

```cmake
    set(_cython_flags -3)
    if(TTIO_CYTHON_LINETRACE)
        list(APPEND _cython_flags -X linetrace=True)
        message(STATUS "ttio: Cython linetrace coverage ENABLED")
    endif()
    foreach(mod _rans _delta_rans _fqzcomp_nx16_z)
        set(_pyx "${CMAKE_CURRENT_SOURCE_DIR}/src/ttio/codecs/${mod}/${mod}.pyx")
        if(EXISTS "${_pyx}")
            set(_c "${CMAKE_CURRENT_BINARY_DIR}/${mod}.c")
            add_custom_command(
                OUTPUT "${_c}"
                COMMAND "${CYTHON_EXECUTABLE}" ${_cython_flags} -o "${_c}" "${_pyx}"
                DEPENDS "${_pyx}"
                VERBATIM)
            Python_add_library(${mod} MODULE "${_c}" WITH_SOABI)
            if(TTIO_CYTHON_LINETRACE)
                target_compile_definitions(${mod} PRIVATE CYTHON_TRACE_NOGIL=1)
            endif()
            install(TARGETS ${mod} LIBRARY DESTINATION "ttio/codecs/${mod}")
            message(STATUS "ttio: Cython accelerator ${mod} enabled")
        else()
            message(STATUS "ttio: ${mod}.pyx absent — using pure-Python fallback")
        endif()
    endforeach()
```

- [ ] **Step 2: Build the package with linetrace and confirm the extensions load**

Run:
```bash
cd ~/TTI-O/python && source .venv/bin/activate && \
  pip install -e . --no-build-isolation \
    --config-settings=cmake.define.TTIO_CYTHON_LINETRACE=ON 2>&1 | grep -i "linetrace coverage ENABLED" && \
  python -c "from ttio.codecs.rans import _HAVE_C_EXTENSION; print('rans ext loaded:', _HAVE_C_EXTENSION)"
```
Expected: cmake prints `Cython linetrace coverage ENABLED`; final line prints `rans ext loaded: True`.

Note: `--no-build-isolation` requires the build deps (`scikit-build-core`, `cython`) already in the venv; if the install fails on a missing build dep, drop `--no-build-isolation`. If `--config-settings` does not reach CMake, confirm scikit-build-core version with `pip show scikit-build-core` (≥0.9 supports `cmake.define.*`).

- [ ] **Step 3: Commit**

```bash
cd ~/TTI-O && git add python/CMakeLists.txt && \
  git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "R8: add TTIO_CYTHON_LINETRACE option for .pyx coverage builds

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Cython — `coverage-cython.cfg`, measure baseline, set floor

**Files:**
- Create: `python/coverage-cython.cfg`

The curated codec test set that drives the three extensions (confirmed present):
`test_rans_unit.py test_m83_rans.py test_delta_rans_fallback.py test_delta_rans_vectorization.py test_m95_delta_rans.py test_codec_registry.py test_m94z_v4_dispatch.py`

- [ ] **Step 1: Write the coverage config**

Create `python/coverage-cython.cfg`:

```ini
# coverage.py config for the R8 Cython linetrace coverage run ONLY.
# Separate from pyproject.toml's [tool.coverage] so the always-on Python
# gate is untouched. Requires the package built with
# -DTTIO_CYTHON_LINETRACE=ON and the env var CYTHON_TRACE=1 at runtime.
[run]
plugins = Cython.Coverage
branch = True
source =
    ttio.codecs._rans
    ttio.codecs._delta_rans
    ttio.codecs._fqzcomp_nx16_z

[report]
show_missing = True
skip_covered = False
```

- [ ] **Step 2: Measurement spike — run the codec tests under linetrace coverage**

With the linetrace build from Task 3 active, run:
```bash
cd ~/TTI-O/python && source .venv/bin/activate && \
  CYTHON_TRACE=1 coverage run --rcfile=coverage-cython.cfg -m pytest -q \
    tests/test_rans_unit.py tests/test_m83_rans.py \
    tests/test_delta_rans_fallback.py tests/test_delta_rans_vectorization.py \
    tests/test_m95_delta_rans.py tests/test_codec_registry.py \
    tests/test_m94z_v4_dispatch.py && \
  coverage report --rcfile=coverage-cython.cfg
```
Expected: tests pass; the report lists the three `.pyx` files with NONZERO line coverage and a TOTAL %.

Known wrinkle — if the report shows the `.pyx` files at 0% / "No data" or errors with "Cython.Coverage" cannot find the C file: the `Cython.Coverage` plugin must locate the cython-generated `.c` (it lives in the scikit-build temp build dir for an editable install). Resolve by ONE of:
  (a) point the plugin at a persistent build: build into a kept dir with `pip install -e . --config-settings=build-dir=build/cov --config-settings=cmake.define.TTIO_CYTHON_LINETRACE=ON`, so the generated `_*.c` files persist under `build/cov` next to the install; or
  (b) copy the generated `_<mod>.c` next to each `.pyx` before running coverage (the plugin searches the .pyx directory).
Record which fix was needed in the workflow comment so CI reproduces it.

- [ ] **Step 3: Record the measured numbers and choose the floor**

Read the TOTAL line % from the report. Set `FLOOR = floor(measured_total) - 3` (a ~2–3 pt buffer; deterministic, no CPU variance). If any single `.pyx` measures 0% because the curated tests genuinely never drive it, note it explicitly — either add a test module that does, or document the gap in the cfg comment (no silent exclusion). Write the measured TOTAL and chosen FLOOR into the cfg as a comment line.

Add to the top `[report]` section of `python/coverage-cython.cfg`:
```ini
# R8 baseline measured <DATE>: TOTAL <measured>% line. Floor set to
# <FLOOR> (measured - ~3pt buffer). Enforced in native-coverage.yml.
```

- [ ] **Step 4: Verify the floor passes and a negative control fails**

Run (floor pass):
```bash
cd ~/TTI-O/python && coverage report --rcfile=coverage-cython.cfg --fail-under=<FLOOR>; echo "exit=$?"
```
Expected: `exit=0`.

Run (negative control — impossible floor):
```bash
cd ~/TTI-O/python && coverage report --rcfile=coverage-cython.cfg --fail-under=100; echo "exit=$?"
```
Expected: `exit=2` (coverage.py returns 2 when under the floor) — proves the gate actually bites.

- [ ] **Step 5: Commit**

```bash
cd ~/TTI-O && git add python/coverage-cython.cfg && \
  git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -F - <<'MSG'
R8: coverage-cython.cfg — linetrace coverage config for .pyx codecs

Cython.Coverage plugin scoped to the 3 codec extensions. Baseline measured
<measured>%; enforced floor <FLOOR> wired in native-coverage.yml (Task 5).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
MSG
```

---

## Task 5: Workflow `.github/workflows/native-coverage.yml`

**Files:**
- Create: `.github/workflows/native-coverage.yml`

Mirror the proven dependency setup from `ci.yml`'s `python-test` job (action versions, `setup-hdf5`, liboqs cache, `build-native`). Substitute `<FLOOR>` with the value chosen in Task 4 and `<CTEST_EXCLUDE>`/build-dir fix with whatever Tasks 2/4 determined (use empty string / omit if none needed).

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/native-coverage.yml`:

```yaml
name: Native + Cython coverage

# R8 (final coverage-campaign item). Dedicated workflow — the instrumented
# native build + Cython linetrace rebuild are slower than the production
# build and are kept off the every-PR ci.yml critical path. C half is
# REPORT-ONLY (SIMD dispatch makes per-file counts CPU-dependent); Cython
# half ENFORCES a linetrace floor (deterministic). Path-filtered so only
# codec/native changes trigger it.
on:
  push:
    branches: [main]
    paths:
      - 'native/**'
      - 'python/src/ttio/codecs/**'
      - 'python/CMakeLists.txt'
      - 'python/coverage-cython.cfg'
      - 'scripts/native-coverage.sh'
      - '.github/workflows/native-coverage.yml'
  pull_request:
    paths:
      - 'native/**'
      - 'python/src/ttio/codecs/**'
      - 'python/CMakeLists.txt'
      - 'python/coverage-cython.cfg'
      - 'scripts/native-coverage.sh'
      - '.github/workflows/native-coverage.yml'
  workflow_dispatch:

jobs:
  c-coverage:
    name: Native C — ctest + gcov (report-only)
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v5
      - name: Install system dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            zlib1g-dev cmake ninja-build gcovr
      - name: Build (instrumented) + ctest + gcovr
        run: bash scripts/native-coverage.sh
      - name: Publish coverage total to job summary
        if: always()
        run: |
          echo "## Native C coverage (report-only)" >> "$GITHUB_STEP_SUMMARY"
          gcovr --root native --filter native/src/ --print-summary native/_covbuild \
            2>/dev/null | tail -5 >> "$GITHUB_STEP_SUMMARY" || true
      - name: Upload coverage artifact
        if: always()
        uses: actions/upload-artifact@v6
        with:
          name: native-c-coverage
          path: |
            native/_covbuild/coverage.xml
            native/_covbuild/coverage-html/
          if-no-files-found: warn
          retention-days: 14

  cython-coverage:
    name: Cython — linetrace coverage (enforced floor)
    runs-on: ubuntu-latest
    env:
      TTIO_RANS_LIB_PATH: ${{ github.workspace }}/native/_build/libttio_rans.so
    steps:
      - uses: actions/checkout@v5
      - name: Install system dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y --no-install-recommends \
            zlib1g-dev cmake ninja-build samtools
      - uses: ./.github/actions/setup-hdf5
      - uses: ./.github/actions/build-native
      - name: Set up Python 3.12
        uses: actions/setup-python@v6
        with:
          python-version: '3.12'
      - name: Cache liboqs
        id: cache-liboqs
        uses: actions/cache@v5
        with:
          path: /usr/local/lib/liboqs.so
          key: liboqs-0.14.0-${{ runner.os }}
      - name: Install liboqs (PQC native library)
        if: steps.cache-liboqs.outputs.cache-hit != 'true'
        run: bash scripts/install-liboqs.sh 0.14.0
      - name: Update ldconfig for liboqs (always)
        run: sudo ldconfig /usr/local/lib
      - name: Install ttio with linetrace instrumentation
        working-directory: python
        run: |
          python -m pip install --upgrade pip setuptools wheel
          pip install -e ".[test]" \
            --config-settings=cmake.define.TTIO_CYTHON_LINETRACE=ON
      - name: Run codec tests under Cython linetrace coverage
        working-directory: python
        env:
          CYTHON_TRACE: '1'
        run: |
          coverage run --rcfile=coverage-cython.cfg -m pytest -q \
            tests/test_rans_unit.py tests/test_m83_rans.py \
            tests/test_delta_rans_fallback.py tests/test_delta_rans_vectorization.py \
            tests/test_m95_delta_rans.py tests/test_codec_registry.py \
            tests/test_m94z_v4_dispatch.py
      - name: Report + enforce floor (and assert nonzero measured)
        working-directory: python
        run: |
          coverage report --rcfile=coverage-cython.cfg
          # Fail loudly if the build measured nothing (linetrace silently off).
          total=$(coverage report --rcfile=coverage-cython.cfg | tail -1 | grep -oE '[0-9]+%' | tr -d '%')
          echo "Measured Cython total: ${total}%"
          if [ -z "${total}" ] || [ "${total}" -eq 0 ]; then
            echo "ERROR: Cython coverage measured 0% — linetrace build is broken." >&2
            exit 1
          fi
          coverage report --rcfile=coverage-cython.cfg --fail-under=<FLOOR>
```

If Task 4 required a persistent build-dir or generated-`.c` copy for the plugin to find the C files, replicate that here (e.g. add the matching `--config-settings=build-dir=...` to the install step, or a copy step before the coverage run).

- [ ] **Step 2: Lint the YAML locally**

Run: `cd ~/TTI-O && python -c "import yaml,sys; yaml.safe_load(open('.github/workflows/native-coverage.yml')); print('YAML OK')"`
Expected: `YAML OK`.

- [ ] **Step 3: Commit**

```bash
cd ~/TTI-O && git add .github/workflows/native-coverage.yml && \
  git -c user.name="Todd White" -c user.email="todd.white@thalion.global" \
  commit -m "R8: native-coverage.yml — C report-only + Cython enforced floor jobs

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Push, open PR, watch CI

- [ ] **Step 1: Push the branch via Windows git**

From PowerShell:
```powershell
& "C:\Program Files\Git\bin\git.exe" -C "\\wsl.localhost\Ubuntu\home\toddw\TTI-O" push -u origin feat/r8-native-cython-coverage
```
(First push of a WSL-path branch may need the `safe.directory` exception already configured for this repo.)

- [ ] **Step 2: Open the PR**

```powershell
gh pr create --repo DTW-Thalion/TTI-O --base main --head feat/r8-native-cython-coverage `
  --title "R8: native C + Cython codec coverage visibility" `
  --body "Final coverage-campaign item (F8). Adds a dedicated native-coverage.yml: native C ctest+gcov (report-only, also the first CI run of the 23 native unit tests) and Cython linetrace coverage (enforced floor). No change to ci.yml or any always-on gate. Spec + plan under docs/superpowers/."
```

- [ ] **Step 3: Watch CI; confirm BOTH jobs and the gates**

```powershell
gh pr checks --repo DTW-Thalion/TTI-O --watch
```
Verify: `c-coverage` green (and its log shows ctest ran N>0 tests + a coverage % in the job summary); `cython-coverage` green (log shows `Measured Cython total: NN%` > 0 and the `--fail-under` step passed). Also confirm the existing required `ci.yml` jobs (Cross-language parity etc.) are unaffected. Ignore local `tests/validation` JDK-classfile env failures if they appear locally (not CI).

- [ ] **Step 4: Squash-merge once green; then sync `main` in WSL**

After merge (user-approved per campaign discipline), sync WSL `main` to `origin/main` and update the campaign memory marking R8 DONE.

---

## Self-Review

**Spec coverage:**
- Half A CMake option → Task 1. ✓
- Half A driver script + ctest-clean prerequisite (A3) → Task 2 (Step 3 records exclusions). ✓
- Half B CMake linetrace option (B1) → Task 3. ✓
- Half B coverage config (B2), coverage run (B3), floor calibration (B4) → Task 4. ✓
- Dedicated workflow with two jobs (report-only C, enforced Cython) → Task 5. ✓
- Gotchas: gcov↔compiler (Task 5 uses gcc+gcovr), fresh build dir (Task 1/2 `_covbuild`), linetrace coverage-only (Task 3 default OFF), assert-nonzero-measured (Task 5 Step 1 + Task 2 Step 3), ctest fixtures (Task 2 Step 3). ✓
- Validation (local + negative control + CI) → Task 4 Step 4 + Task 6 Step 3. ✓

**Placeholder scan:** `<FLOOR>`, `<measured>`, `<DATE>`, `<RECORD ...>`, `<CTEST_EXCLUDE>` are deliberate calibration values resolved by an explicit measurement procedure (Task 2 Step 3, Task 4 Steps 2–3) — not vague "fill in later" gaps. Every code/file artifact is given in full.

**Type/name consistency:** Option names `TTIO_COVERAGE` / `TTIO_CYTHON_LINETRACE`, build dir `native/_covbuild`, config `python/coverage-cython.cfg`, env `CYTHON_TRACE=1` + macro `CYTHON_TRACE_NOGIL=1`, and the curated test list are identical across Tasks 1–5. ✓
