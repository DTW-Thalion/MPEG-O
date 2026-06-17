# R8 — Native C + Cython coverage visibility

**Date:** 2026-06-17
**Campaign:** TTI-O coverage improvement, round R8 (final item; F8 finding).
**Status:** design approved, spec for implementation.

## Background

The coverage campaign (analysis `docs/architecture/2026-06-06-coverage-analysis.md`,
findings F1–F8) closed R1–R7. The last open item, **F8**, is that the native C
rANS library (`native/src/*.c`) and the three Cython codec accelerators
(`python/src/ttio/codecs/{_rans,_delta_rans,_fqzcomp_nx16_z}/*.pyx`) have **no
coverage measurement at all** today:

- The native C unit tests (`native/tests/test_*.c`, 23 files wired into
  `native/CMakeLists.txt` under `BUILD_TESTING`) **do not run in CI** — the
  `.github/actions/build-native` composite action only builds
  `libttio_rans.so` for the language jobs; nothing invokes `ctest`.
- The `.pyx` accelerators are compiled by `python/CMakeLists.txt` with a plain
  `cython -3` command (no `linetrace`), so `coverage.py` reports 0% / omits
  them. The pure-Python references in `ttio.codecs` are byte-exact fallbacks,
  and they ARE measured by the always-on Python gate; the compiled path is not.

The analysis framed F8 as "(Optional) … if the codec paths warrant it. Low
priority." The campaign decided (this round) to make both paths **visible**,
with enforcement scaled to each path's measurement stability.

## Scope decision (approved)

**Hybrid enforcement, dedicated workflow.**

- **Native C: report-only.** `dispatch.c` selects scalar / SSE4.1 / AVX2 kernels
  at runtime by CPU. On a typical AVX2 GitHub runner the scalar and SSE4.1
  encode/decode translation units show as near-uncovered even though they are
  correct, so a per-file C line *gate* would false-fail depending on runner CPU
  — exactly the volatility R6 declined to ratchet. We therefore run the ctests
  in CI and emit a coverage report/artifact with **no floor**. (ctest *failures*
  still fail the job — running the native unit tests in CI for the first time is
  a real win independent of coverage.)
- **Cython: enforced floor.** Linetrace coverage is deterministic (pure codec
  logic, no CPU dispatch), like R5's per-module Python gate, so a calibrated
  `--fail-under` floor is defensible.
- **Placement: a new dedicated workflow** `.github/workflows/native-coverage.yml`,
  not `ci.yml`. The instrumented/linetrace rebuilds are slower and separate from
  the production build; keeping them off the every-PR critical path mirrors the
  R7 `workbench-live.yml` separation. Nothing in `ci.yml` or the always-on
  gates changes.

Nothing on the production build path changes: both instrumentation modes live
behind CMake options that default `OFF`.

## Half A — Native C coverage (report-only)

### A1. CMake option
`native/CMakeLists.txt`: add `option(TTIO_COVERAGE "Instrument for gcov coverage" OFF)`.
When `ON` and the compiler is GCC or Clang (not MSVC), add `--coverage -O0 -g`
to the compile AND link options of:
- the `ttio_rans` library target, and
- every test executable (gcov emits `.gcno` at compile and needs the library
  instrumented to attribute `.gcda` runtime arcs).

The existing per-file SIMD flags (`-msse4.1` / `-mavx2`, set via
`set_source_files_properties(... COMPILE_FLAGS ...)`) coexist with the
target-level coverage flags — no conflict. Do not instrument `bench/` or the
optional TSAN target.

### A2. Driver script `scripts/native-coverage.sh`
- Configure a **fresh** out-of-tree build dir `native/_covbuild` (must never be
  `native/_build`, which other CI jobs and local dev reuse uninstrumented) with
  `-DTTIO_COVERAGE=ON -DBUILD_TESTING=ON`.
- Build, then `ctest --output-on-failure`.
- Run `gcovr` rooted at `native/`, filtered to `native/src/` (exclude
  `tests/`, `bench/`, system headers), producing: a console summary table, a
  total line+branch %, a Cobertura XML (`native/_covbuild/coverage.xml`), and
  HTML (`native/_covbuild/coverage-html/`).
- **No floor / no nonzero exit on coverage.** Exit nonzero only if cmake, the
  build, or ctest fails.

### A3. ctest-clean prerequisite
Some registered ctests may depend on on-disk fixtures generated outside the
suite (candidates: `rc_cram_byte_equal`, `fqzcomp_qual_strategy1`). Before
wiring CI, verify a clean-checkout `ctest` is fully green. If any registered
test requires an external fixture it cannot self-generate, exclude it with
`ctest -E <regex>` AND echo the exclusion in the script output (no silent caps
— R7 lesson). Document any exclusion in the script comment with the reason.

## Half B — Cython coverage (enforced floor)

### B1. CMake option
`python/CMakeLists.txt`: add `option(TTIO_CYTHON_LINETRACE "Compile .pyx with linetrace for coverage" OFF)`.
When `ON`, for each of `_rans`, `_delta_rans`, `_fqzcomp_nx16_z`:
- append `-X linetrace=True` to the `cython -3 -o <out>.c <in>.pyx` custom command, and
- add `target_compile_definitions(<mod> PRIVATE CYTHON_TRACE_NOGIL=1)` to the
  `Python_add_library` target.

Default `OFF` ⇒ production wheels are unaffected (no linetrace slowdown).

### B2. Coverage config
New `python/coverage-cython.cfg` (separate file, mirrors R7's
`coverage-live.cfg` so the always-on `[tool.coverage]` gate in `pyproject.toml`
is untouched):
- `[run] plugins = Cython.Coverage`
- `source` scoped to the three `.pyx` directories under
  `python/src/ttio/codecs/`.
- `[report]` with `show_missing = true`.

### B3. Coverage run
In the `cython-coverage` job (and reproducibly via the driver script):
1. Build/install the package editable with linetrace:
   `pip install -e . --config-settings=cmake.define.TTIO_CYTHON_LINETRACE=ON`
   (plus the existing native-lib config). Confirm the `.pyx` accelerators load
   (`_HAVE_C_EXTENSION` true) so the codec public API exercises the compiled
   path, not the pure-Python fallback.
2. `CYTHON_TRACE=1 coverage run --rcfile=python/coverage-cython.cfg -m pytest <codec tests>`
   where `<codec tests>` are the rANS / delta-rANS / fqzcomp_nx16_z codec test
   modules under `python/tests/` (exact node IDs resolved during
   implementation; scope to the codec tests that drive the three extensions).
3. `coverage report --rcfile=python/coverage-cython.cfg --fail-under=<FLOOR>`.

### B4. Floor calibration
Measure the linetrace baseline during implementation, set
`FLOOR = round(measured) − buffer` with a tight buffer (~2–3 pts; deterministic,
no SIMD/CPU variance, unlike ObjC's 5pt). Record the measured number and the
chosen floor in the workflow comment and in the campaign memory.

## Workflow `.github/workflows/native-coverage.yml`

- **Triggers:** `pull_request` and `push` (branches: main), `paths` filtered to:
  `native/**`, `python/src/ttio/codecs/**`, `python/CMakeLists.txt`,
  `scripts/native-coverage.sh`, and `.github/workflows/native-coverage.yml`
  itself; plus `workflow_dispatch`.
- **Job `c-coverage`** (ubuntu-latest): install `cmake ninja-build zlib1g-dev
  gcovr` (pin GCC; ubuntu default `cc` is gcc, avoiding clang↔gcov mismatch),
  run `scripts/native-coverage.sh`, write the total to `$GITHUB_STEP_SUMMARY`,
  upload `coverage.xml` + HTML as an artifact. Assert ctest count > 0 in the
  log. Report-only (no coverage floor).
- **Job `cython-coverage`** (ubuntu-latest): set up Python 3.12, install system
  deps + build deps (cmake/ninja/zlib, cython, coverage), build editable with
  linetrace, run the codec tests under coverage, enforce `--fail-under`. Assert
  measured Cython coverage > 0 (so a silently-unmeasured build fails loudly).

## Error handling / gotchas

1. **gcov ↔ compiler match.** Use GCC + `gcovr`; do not mix clang-built objects
   with GNU `gcov`. Pin the toolchain in the workflow.
2. **Fresh instrumented build dir.** `native/_covbuild` only; never reuse or
   leave coverage flags in `native/_build`.
3. **linetrace is coverage-only.** `CYTHON_TRACE=1` and the CMake option are set
   only in the coverage job; production builds keep the default `OFF`.
4. **Verify it measured something.** Both jobs assert nonzero work (ctest count,
   Cython %) so we never ship a green gate that measured nothing (R7 lesson).
5. **ctest fixtures.** Per A3, confirm clean-checkout ctest green; exclude +
   log any fixture-dependent test rather than letting the job fail opaquely.

## Validation

- **Local (WSL `~/TTI-O`):** run both halves. C: sensible total prints, ctests
  green. Cython: floor passes; a negative control (break a `.pyx` line or raise
  the floor above measured) fails as expected.
- **CI:** `native-coverage.yml` goes green; ctest-count and nonzero-Cython
  assertions visible in logs; artifact uploaded.
- Existing `ci.yml`, `workbench-live.yml`, and all always-on gates unchanged.

## Out of scope

- Genomic-codec C reached only via Python/Java/ObjC bindings (measured
  indirectly by language suites, not by native ctests) — not added to the C
  report this round.
- Any C coverage *floor* (deferred; revisit only if the SIMD-dispatch
  volatility can be neutralised, e.g. forcing scalar dispatch).
- Java JNI wrapper coverage.

## Workflow (campaign-standard)

Build/test in WSL `~/TTI-O`; push via Windows git, `gh` on the Windows side.
Subagent-driven implementation (implementer + spec-review + code-quality).
Watch CI, squash-merge, sync, update memory. Measure exit codes via PowerShell
`$LASTEXITCODE`, not `; echo $?` nested in `wsl bash -lc`.

## Post-implementation notes (divergence from design)

Three things changed during implementation versus this design — all
documented in the shipped code and recorded here for coherence:

1. **Cython measures 2 extensions, not 3.** `_fqzcomp_nx16_z`'s Cython
   extension is dead: its wrapper (`fqzcomp_nx16_z.py`) requires the native
   `libttio_rans` and never falls back to the Cython `_ext` (V1/V2/V3 were
   removed in the v1.0 reset; V4 is native-only — `_ext` has zero call
   sites). It is excluded from the Cython floor `source`; the native
   fqzcomp C is covered by the C half instead. Flagged as a separate
   dead-code-removal follow-up (R3-style), out of R8 scope.
2. **A dedicated runner replaces a bare `coverage run -m pytest`.**
   `python/scripts/run_cython_coverage.py` encapsulates the coverage.py 7.x
   + `Cython.Coverage` + numpy 2.x workarounds that a plain `coverage run`
   cannot do: `COVERAGE_CORE=ctrace` (the default sys.monitoring core has no
   Cython plugin), numpy + extension pre-import before the C tracer starts,
   staging the linetrace-generated `.c` next to each `.pyx`, `-p no:cov`,
   and deselecting a throughput perf test that linetrace slows below its
   assert floor.
3. **A latent native bug was fixed.** Running the native ctests in CI for
   the first time surfaced `test_name_tok_v2_stress`: truncated-header
   input returned `BAD_MAGIC` instead of `ERR_CORRUPT`. Fixed in its own
   commit; no cross-language contract regression.

Measured baselines: native C **77.3% line** (report-only); Cython
**76.3% line** over `_rans` + `_delta_rans`, enforced floor **73**.
