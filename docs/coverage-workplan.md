# Coverage Improvement Workplan (C-series)

> **Status:** DRAFT for review (2026-04-27). Separate from
> `WORKPLAN.md` and `verification-workplan.md`. C-series milestones
> are coverage-debt repayments — adding tests for already-shipped
> code paths that V1's instrumentation revealed as untested.

---

## 1. Baseline (2026-04-27, post-V1d / -P1-P4 / -fix V1c)

| Language | Tool | Lines | **Line cov** | Branch cov |
|---|---|---:|---:|---:|
| Python | pytest-cov 7.1 | 10,462 | 85.8% | 73.6% |
| Java | JaCoCo 0.8.12 | 12,423 | 79.9% | 61.7% |
| ObjC | clang `-fprofile-instr-generate` + llvm-cov | 22,575 | 76.6% | ~52% |

The lowest-covered packages, common across all three languages:

| Area | Python | Java | ObjC | Notes |
|---|---:|---:|---:|---|
| `tools` (CLI mains) | 22.5% | 0.0% | ~21% | Highest single-area gap |
| `providers` | 85.9% | 73.2% | 63.0% | ObjC outlier |
| `hdf5` wrapper | (h5py — n/a) | 68.4% | 74.5% | Error-path coverage thin |
| `genomics` (M82+) | (~89% root) | 84.0% | 68.5% | Recent, less mature |
| `protection` | (~89% root) | 92.3% | 74.1% | ObjC outlier |
| Branch coverage overall | 73.6% | 61.7% | ~52% | 10-30 pts behind line cov |

## 2. Targets (per language, end of C-series)

| Language | Line cov target | Branch cov target | Stretch |
|---|---:|---:|---:|
| Python | **≥ 92%** (from 85.8%, +6.2 pts) | ≥ 80% (from 73.6%) | ≥ 95% line |
| Java | **≥ 88%** (from 79.9%, +8.1 pts) | ≥ 70% (from 61.7%) | ≥ 92% line |
| ObjC | **≥ 85%** (from 76.6%, +8.4 pts) | ≥ 65% (from ~52%) | ≥ 90% line |

These are ambitious but reachable — the gap is concentrated in a
handful of packages (CLI tools, providers, hdf5, genomics) rather
than spread thin across the codebase.

## 3. C-series milestones

Each C-milestone is a discrete unit of work scoped to a specific
coverage gap. Per-milestone target: lift named packages by named
% delta.

### C1 — CLI mains coverage (3 languages)

**Effort:** S (3-5 days). **Highest single ROI.**

**Scope:** The `tools/` packages (Python `ttio.tools.*`, Java
`global.thalion.ttio.tools.*`, ObjC `objc/Tools/*`) hold the user-
facing CLI entry points (`ttio-sign`, `ttio-verify`, `ttio-pqc`,
`TtioBamDump`, `TtioPerAU`, `TtioVerify`, `TtioSign`, etc.). They
are exercised end-to-end by integration tests via subprocess, but
the `main()` argparse parsing, `--help` output, error-message
formatting, and exit-code branches show as uncovered because no
unit test imports them in-process.

**Files (per language):**
* Python: `python/tests/tools/test_*_cli.py` — one file per
  CLI tool. Each test imports the `main` function and calls it
  with various `argv` arrays (happy path, `--help`, missing args,
  bad args). Use `capsys` fixture to assert stderr content.
* Java: `java/src/test/java/global/thalion/ttio/tools/*MainTest.java` —
  same pattern using `System.setOut` / `setErr` redirection. Note
  Java's `System.exit` calls require a `SecurityManager` workaround
  or refactoring the mains to return ints; the latter is cleaner.
* ObjC: `objc/Tests/TestToolsCli.m` — one test that fork-execs each
  CLI binary with various argv and asserts stdout/stderr + exit
  codes. Different from Python/Java because GNUstep ObjC tests
  can't easily import-and-call a `main()` from another `tool`
  binary.

**Target:** Lift `tools` from 0-22% to **≥ 70%** in all three.

**Acceptance:**
* Python: `tools` coverage ≥ 70% (from 22.5%).
* Java: `tools` coverage ≥ 70% (from 0%).
* ObjC: `objc/Tools/` aggregate coverage ≥ 70% (from ~21% mixed in
  `(other)`).
* Each CLI tool has at least: 1 happy-path test, 1 missing-arg
  test, 1 invalid-arg test, 1 `--help`-prints-something test.

**Estimated overall lift:** Python +1.5 pts, Java +5.5 pts, ObjC
+2 pts.

---

### C2 — HDF5 wrapper error-path coverage (Java + ObjC)

**Effort:** M (1 week). Java + ObjC; Python uses h5py (not our code).

**Scope:** The Java `global.thalion.ttio.hdf5` (68.4%) and ObjC
`objc/Source/HDF5` (74.5%) packages wrap libhdf5 directly. Most
uncovered code is error paths — H5Fopen / H5Dcreate / H5Sselect
returning negative values. V8 covers some (truncation, missing
file), but the full matrix of "every libhdf5 call's error
recovery" is not exercised.

**Files:**
* Java: `java/src/test/java/global/thalion/ttio/hdf5/Hdf5ErrorPathTest.java` —
  each test forces a specific libhdf5 failure mode (read-only mode
  + write attempt; chunked dataset with invalid chunk shape;
  attribute on a closed object; etc.) and asserts the right
  `Hdf5Errors.*` subclass is thrown.
* ObjC: `objc/Tests/TestHDF5ErrorPaths.m` — analogous tests using
  `NSError` out-params.

**Target:**
* Java `hdf5` 68.4% → **≥ 85%** (15 tests).
* ObjC `objc/Source/HDF5` 74.5% → **≥ 85%** (15 tests).

**Estimated overall lift:** Java +1 pt, ObjC +1.5 pts.

---

### C3 — Providers error-path coverage (3 languages, ObjC heaviest)

**Effort:** M-L (1-2 weeks). ObjC is the priority.

**Scope:** All three languages have `providers/` packages wrapping
HDF5, Memory, SQLite, and (Python only) Zarr. ObjC at 63.0% is the
biggest gap. V9 covered some Python edge cases; V8 covered some
HDF5 corruption — but providers' read-with-bad-precision /
create-with-existing-name / open-after-close paths are still thin.

**Files:**
* Python: `python/tests/test_v9_provider_edge.py` is the seed —
  expand to cover SqliteProvider lock contention, MemoryProvider
  concurrent stores, ZarrProvider chunk-shape mismatches.
* Java: `java/src/test/java/global/thalion/ttio/providers/*ErrorTest.java`
  — analogous per-provider error tests.
* ObjC: `objc/Tests/TestProvidersErrorPaths.m` — most needed.

**Target:**
* Python `providers` 85.9% → **≥ 92%**.
* Java `providers` 73.2% → **≥ 85%**.
* ObjC `objc/Source/Providers` 63.0% → **≥ 80%**.

**Estimated overall lift:** Python +0.7 pts, Java +2.5 pts, ObjC
+2.0 pts.

---

### C4 — Genomics package gap (Java + ObjC)

**Effort:** M (1 week). Java + ObjC; Python `genomics/` is mixed
into the root and already reasonably covered.

**Scope:** M82-M86 genomics code is recent and lacks the years of
incremental test additions that older spectrometry code has. Java
`genomics` at 84.0% and ObjC `objc/Source/Genomics` at 68.5% have
gaps in: GenomicIndex edge cases, mate-info schema variant paths,
empty-channel handling, signal-codec dispatch tables.

**Files:**
* Java: extend `java/src/test/java/global/thalion/ttio/GenomicRunTest.java`
  + add new `GenomicIndexErrorTest.java`, `MateInfoVariantTest.java`.
* ObjC: extend `objc/Tests/TestM82GenomicRun.m` + new
  `TestGenomicEdgeCases.m`.

**Target:**
* Java `genomics` 84.0% → **≥ 90%**.
* ObjC `objc/Source/Genomics` 68.5% → **≥ 80%**.

**Estimated overall lift:** Java +0.3 pts, ObjC +1.5 pts.

---

### C5 — ObjC Protection package gap

**Effort:** S (3-5 days). ObjC-only.

**Scope:** ObjC `objc/Source/Protection` at 74.1% lags Java
(92.3%) and Python (~89% in root). Mostly missing: PQC error
paths (M49 ML-KEM-1024 / ML-DSA-87 wrong-key + tamper detection),
key rotation failure modes, signature verification with corrupted
blobs.

**Files:**
* ObjC: `objc/Tests/TestProtectionErrorPaths.m` — 10-15 tests
  covering wrong-key decrypt, tampered ciphertext, malformed
  PQC blob, missing KEK metadata, etc.

**Target:** ObjC `objc/Source/Protection` 74.1% → **≥ 88%**.

**Estimated overall lift:** ObjC +1.5 pts.

---

### C6 — Branch coverage push (3 languages)

**Effort:** L (2-3 weeks). Largest C-series milestone but lowest
per-test ROI.

**Scope:** Across all packages, branch coverage is 10-30 points
behind line coverage. Most missing branches are `if (error)`
guards in C-style ObjC code, `if (result < 0)` returns in Java,
`if not isinstance(...)` defensive checks in Python. Add tests
that specifically exercise these error branches.

This is more of an ongoing discipline than a single milestone —
add tests for branch gaps as you encounter them. C6 sets aside a
chunk of focused time to push the numbers up.

**Files:** Spread across all test directories. Pick the 5 most-
critical files per language (highest line count × lowest branch
coverage) and add error-branch tests until each crosses 75%.

**Target:**
* Python branch 73.6% → **≥ 80%**.
* Java branch 61.7% → **≥ 70%**.
* ObjC branch ~52% → **≥ 65%**.

**Estimated overall lift on line cov:** Python +0.5 pts, Java +1
pt, ObjC +0.5 pts (most branch tests don't add new line coverage).

---

### C7 — Coverage thresholds in CI ✅ DONE 2026-04-27

**Effort actual:** ~1 day. Landed after C1-C5 (C4/C6 deferred to a
later coverage push — see Section 4 sequencing notes).

**What landed:**
* `python/pyproject.toml` — `[tool.coverage.report] fail_under = 84`
  (post-C-series achieved baseline 85% per `coverage report`, set
  1 pt below to allow drift).
* `.github/workflows/ci.yml` — pytest invocation gained
  `--cov-fail-under=84` (pytest-cov ignores the pyproject.toml
  setting; the CLI flag is what gates the build).
* `java/pom.xml` — added `jacoco-check` execution under the
  existing `jacoco-maven-plugin` with rule
  `BUNDLE LINE COVEREDRATIO minimum=0.84`. Verified locally:
  `mvn verify` reports "All coverage checks have been met" and
  exits 0 at the post-C-series Java baseline (~86%).
* `objc/build.sh` — after `llvm-cov export`, sums `LH:`/`LF:`
  totals across `coverage.lcov` and exits 1 if below
  `${TTIO_COV_MIN:-82}`% (post-C-series ObjC baseline 83.93%
  per `awk` over the existing lcov, set 1 pt below).

**Why the floors look low vs targets in §2:**
The §2 targets (Python ≥92, Java ≥88, ObjC ≥85) were aspirational
end-of-series stretch goals. Actuals after C1-C5 landed are
85/86/84 — held back by vendor-importer paths (Bruker timsTOF,
Thermo RAW, Waters MassLynx) that need proprietary fixtures, and
genomics + cloud paths deferred from C4/C6. The CI floors are set
1 pt below current actuals to lock in the C-series gains while
allowing drift; bump them in tandem after intentional coverage
improvements.

**Override:** ObjC accepts `TTIO_COV_MIN=<pct>` in env for local
overrides (e.g. when bisecting on a branch).

---

### C8 — Codecov integration (optional)

**Effort:** S (1 day).

**Scope:** Upload coverage XML/lcov to Codecov.io for nice diffs
on PRs (per-PR coverage delta visible inline in GitHub UI).
Currently artefacts are only inspectable via "Download artifact"
+ open HTML report.

**Files:**
* `.github/workflows/ci.yml` — add `codecov/codecov-action@v4`
  steps after the existing upload-artifact steps.

**Target:** PR comments show coverage delta automatically.

**Note:** Optional because Codecov.io is third-party and adds a
build dependency. Could use `codecov-cli` self-hosted instead.

---

## 4. Recommended sequencing

**Phase 1 (week 1, parallelisable, high ROI):**
* C1 (CLI mains × 3) — biggest single win, 5+ percentage points
  of overall coverage in some langs.

**Phase 2 (weeks 2-3, parallelisable):**
* C2 (HDF5 error paths) — Java + ObjC.
* C5 (ObjC Protection) — ObjC standalone.

**Phase 3 (weeks 3-4):**
* C3 (Providers error paths) — most painful but moves all three.
* C4 (Genomics) — Java + ObjC.

**Phase 4 (weeks 5-7):**
* C6 (Branch coverage push) — broadest scope, longest pole.

**Phase 5 (week 8):**
* C7 (CI thresholds) — locks in the wins.
* C8 (Codecov) — optional, do if PR-review velocity matters.

**Total estimated time:** 6-8 weeks if phases run sequentially,
4-5 weeks if Phases 2+3 parallelise.

## 5. Out-of-scope

Excluded from C-series:

* **Mutation testing** — `pitest` (Java), `mutmut` (Python). High
  signal but doubles CI time. Revisit once line coverage ≥ 90%
  everywhere.
* **Coverage of `python/_jcamp_decode.py`** — vendored helper,
  intentionally omitted in `pyproject.toml`.
* **Test-code coverage** — meaningless metric (test code by
  definition runs to completion). Already excluded.
* **Aggressive testing of trivial getters/setters** — net coverage
  improvement is real but the ROI per test is poor; skip unless a
  package needs the lift.

## 6. Per-language headline impact projection

If all C1-C6 land:

| Language | Today | C1 | C2/C5 | C3 | C4 | C6 | **Projected** |
|---|---:|---:|---:|---:|---:|---:|---:|
| Python | 85.8% | +1.5 | n/a | +0.7 | n/a | +0.5 | **≥ 88.5%** |
| Java | 79.9% | +5.5 | +1.0 | +2.5 | +0.3 | +1.0 | **≥ 90.2%** |
| ObjC | 76.6% | +2.0 | +3.0 | +2.0 | +1.5 | +0.5 | **≥ 85.6%** |

Numbers are conservative (assumes only the named packages move; in
practice tests for one package often touch shared helpers and lift
others). Stretch targets in §2 are reachable if C6 lifts more than
projected.

---

*This plan is a draft. Once approved, C-series milestones will be
worked in the recommended sequence with a HANDOFF spec per
milestone (matching M-series and V-series convention). C-series
CHANGELOG entries go under their own
`[Unreleased] — C-series coverage improvement` section.*
