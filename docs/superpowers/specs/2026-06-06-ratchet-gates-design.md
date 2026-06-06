# Ratchet Coverage Gates (R6) — Design

**Date:** 2026-06-06
**Origin:** `docs/architecture/2026-06-06-coverage-analysis.md` recommendation R6.
**Scope:** Raise the two *stable aggregate line* coverage gates (Java BUNDLE line, Python
total) from 0.84 to 0.86 to lock in the R1/R3 gains. Config + comment only.

## Problem
After R1 (CLI tests) and R3 (fqzcomp dead-code removal), both aggregate line gates sit far
above their floors: Java BUNDLE line 87.07% (gate 0.84), Python total 87.15% in CI (gate
0.84). The ~3pt slack means coverage could silently erode most of the way back to 0.84
without the gate noticing. Ratchet the floors up so the gains can't be lost.

## What ratchets — and what deliberately does NOT
**Ratchet (stable, ~3pt headroom, deterministic):**
- **Java BUNDLE LINE: 0.84 → 0.86** (`java/pom.xml`; actual 87.07% local & CI — JVM line
  coverage is deterministic).
- **Python total: 0.84 → 0.86** (`--cov-fail-under` in `.github/workflows/ci.yml` AND
  `fail_under` in `python/pyproject.toml`; CI actual 87.15%, confirmed from the latest
  main run — pure-Python coverage is deterministic given the same tests + extras).

**Leave unchanged (with reason):**
- **ObjC line floor (67):** R2 deliberately set a wide buffer because ObjC scoped coverage
  swings ~5pt CI↔local (libhdf5/runner — see the recorded finding). Ratcheting a volatile
  metric invites false CI failures.
- **Python per-module floor (0.50):** the binding module (`importers/bruker_tdf_cli.py`)
  is *exactly* 0.50 — no room to ratchet without excluding it.
- **Java BUNDLE branch (0.68):** only ~1.5pt headroom (actual 69.51%) and branch coverage
  is volatile; 0.69 would be a ~0.5pt knife-edge prone to false failures.
- **Java PACKAGE floor (0.50):** lowest package 55.7%; just landed in R5; modest value to
  bump now.

Rationale: ratcheting is only worthwhile where there is real, *stable* headroom. The two
aggregate line gates are the clear wins; forcing ratchets on volatile/knife-edge gates
trades a tiny lock-in for recurring false-failure risk.

## Changes
1. `java/pom.xml`: the BUNDLE rule's LINE `<limit>` `<minimum>` 0.84 → **0.86**. Update the
   inline comment (already refreshed in R4 to note ~87% line) to record the 0.86 ratchet
   and a "never decrease without a recorded reason" note.
2. `.github/workflows/ci.yml`: the gated Python step's `--cov-fail-under=84` → **86**.
   Update the adjacent comment.
3. `python/pyproject.toml`: `[tool.coverage.report] fail_under = 84` → **86** (keeps local
   `pytest --cov` aligned with CI). Update its comment.

The BRANCH limit, PACKAGE rule, ObjC `TTIO_COV_MIN`, and the Python per-module checker are
untouched.

## Invariants & verification
- Config + comment only — no production/test code.
- Java `cd java && JAVA_HOME=~/jdk25 mvn -o -B verify` passes with LINE ≥0.86 (and the
  unchanged branch/package rules). If it fails, CI Java line is below 86 — lower to 0.85.
- Python `cd python && ... pytest --cov=src/ttio --cov-fail-under=86` passes locally
  (actual ~87%). The pyproject `fail_under=86` matches.
- Gate-bites is inherent (the gate already enforces; we only raised the number) — confirm
  the suites still pass at 0.86, i.e. the actuals clear the new floor with buffer.
- CI: Java `mvn verify` + Python gated job enforce the new 0.86 floors.

## Success criteria
Java BUNDLE line and Python total gates are at 0.86; all suites pass with ~1pt buffer; the
other gates are unchanged. One small PR.

## Out of scope (tracked separately)
R7/R8 (live-daemon integration tests to un-exclude workbench clients; native C/Cython
coverage). Future ratchets of branch/package/ObjC/per-module once their actuals rise and
stabilize.
