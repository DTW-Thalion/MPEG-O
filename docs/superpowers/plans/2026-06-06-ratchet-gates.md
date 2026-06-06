# Ratchet Coverage Gates (R6) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Raise the two stable aggregate line gates (Java BUNDLE line, Python total) 0.84 → 0.86 to lock in the R1/R3 gains. Config + comment only; leave branch/package/ObjC/per-module gates unchanged.

**Verify (WSL):** Java `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify`; Python `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q --cov=src/ttio --cov-fail-under=86`. WSL: `wsl -d Ubuntu -- bash -c '<cmd>'`. Commits: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...`. If a Read shows empty, retry or `cat` via wsl.

**Confirmed actuals (2026-06-06):** Java BUNDLE line 87.07% (local & CI, deterministic); Python total 87.15% (CI, latest main) / ~87% local. Both clear 0.86 with ~1pt buffer.

---

## Task 1: Ratchet Java BUNDLE line + Python total to 0.86

**Files:**
- Modify: `java/pom.xml` (BUNDLE LINE limit, ~line 388)
- Modify: `.github/workflows/ci.yml` (gated Python step `--cov-fail-under`, ~line 194)
- Modify: `python/pyproject.toml` (`[tool.coverage.report] fail_under`, ~line 189)

**Context:** Java `jacoco-check` BUNDLE rule has a LINE limit `<minimum>0.84</minimum>` (line 388) — change to 0.86. Do NOT touch the BRANCH limit (0.68, ~line 397) or the PACKAGE rule (0.50). Python is gated in two aligned places: the CI step `--cov-fail-under=84` (ci.yml:194) and `pyproject.toml` `fail_under = 84` (line 189) — change both to 86. Leave ObjC (`TTIO_COV_MIN` in build.sh) and the per-module checker untouched.

- [ ] **Step 1: Java — raise the BUNDLE LINE minimum.** In `java/pom.xml`, change the BUNDLE rule's LINE `<minimum>0.84</minimum>` (the one under `<counter>LINE</counter>`, ~line 388 — NOT the branch limit) to `<minimum>0.86</minimum>`. Update its inline comment's last sentence to record the ratchet, e.g. append: `Ratcheted to 0.86 (R6, 2026-06-06) to lock in the ~87% actual; never decrease without a recorded reason.` Leave the BRANCH (0.68) and PACKAGE (0.50) rules unchanged.

- [ ] **Step 2: Java — verify.** `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | grep -iE "coverage checks|BUILD|Tests run:.*Failures" | tail -4` → `BUILD SUCCESS`, `All coverage checks have been met.`, 0 failures (LINE ≥0.86 now enforced alongside branch/package). If it FAILS on the line rule, CI/local Java line is below 86 — set 0.85 instead and note it.

- [ ] **Step 3: Python — raise both gate values.**
  - `.github/workflows/ci.yml` line ~194: change `--cov-fail-under=84` to `--cov-fail-under=86`. Update the adjacent comment (lines ~190-193) to note the R6 ratchet to 86.
  - `python/pyproject.toml` line ~189: change `fail_under = 84` to `fail_under = 86`. Update its comment (lines ~185-188, currently "~85% ... 84 floor") to reflect the ~87% actual and the 86 floor (R6).
  Keep the two values identical (86).

- [ ] **Step 4: Python — verify.** `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q --cov=src/ttio --cov-fail-under=86 -p no:cacheprovider 2>&1 | tail -5` → must end with `Required test coverage of 86% reached. Total coverage: ~87%` and pass (ignore the known `tests/validation` JDK-classfile env failures if any appear — the coverage gate line is what matters; confirm "Required test coverage of 86% reached"). If coverage is below 86, set both values to 85 and note it.

  NOTE: the full suite is slow (~8 min) and may show env-only `tests/validation` cross-language failures (JDK classfile mismatch) — those do NOT affect the coverage % computation. To get a clean, fast coverage-gate signal you may instead reuse the existing `.coverage` data: `cd ~/TTI-O/python && .venv/bin/python -m coverage report --fail-under=86 2>&1 | tail -3` (uses the last run's data; confirms ≥86). Use whichever is reliable; the goal is to confirm the actual total clears 86.

- [ ] **Step 5: Confirm diff is config/comment only.** `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git diff --stat'` → only `java/pom.xml`, `.github/workflows/ci.yml`, `python/pyproject.toml`. No `src/` / test files.

- [ ] **Step 6: Commit.**
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git add java/pom.xml .github/workflows/ci.yml python/pyproject.toml && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "build: ratchet Java line + Python total coverage gates 0.84 -> 0.86 (R6)

Lock in the R1/R3 gains: Java BUNDLE line and Python total both sit at ~87%
(CI-confirmed), so raise their floors from 0.84 to 0.86 (~1pt buffer). Branch
(0.68), package (0.50), ObjC (67), and per-module (0.50) gates are left as-is
(volatile or knife-edge)."'
```

---

## Final verification
- [ ] Java `mvn -o -B verify` → BUILD SUCCESS, all coverage checks met (LINE ≥0.86).
- [ ] Python coverage ≥86 confirmed (gate passes).
- [ ] Push (Windows git), open PR vs `main`, watch CI (Java `mvn verify` enforces 0.86; Python gated job enforces `--cov-fail-under=86`). If Java line or Python total comes in below 86 in CI, lower that gate to 0.85 and re-push. If the ObjC job hangs on `setup-libarrow`, cancel + `gh run rerun --failed`. Merge once green, sync main.
- [ ] Update memory (`project_tti_o_coverage_improvement`): R6 done — Java line + Python total ratcheted to 0.86; campaign R1–R6 complete; only R7/R8 remain.
