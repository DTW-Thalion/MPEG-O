# Per-Unit Coverage Floors (R5) — Design

**Date:** 2026-06-06
**Origin:** `docs/architecture/2026-06-06-coverage-analysis.md` recommendation R5 (finding F6).
**Scope:** Stop a single class/module from silently regressing to ~0 while the aggregate
gate still passes. Add a Java per-**package** jacoco floor and a Python per-**module** CI
check. Config + one small script; no production/test code.

## Problem (F6)
Both gates are single aggregates: Java BUNDLE line ≥0.84 / branch ≥0.68; Python total
≥0.84. A class or module can collapse to near-zero coverage while the aggregate holds.

## Why package (Java) / module (Python), not per-class
Measured 2026-06-06 (post-R1–R4): Java has 13 classes at 0% and ~32 below 50% that are
*legitimately* low (exception types, marker interfaces, subprocess-only CLIs, thin reader
adapters, the live-daemon `WorkbenchClient`). A per-class floor would need a ~32-entry
exclude list — high maintenance. **Per-package** smooths that noise: the lowest real
packages are `importers.readers` 55.7% and `workbench` 56.0% (and gated `workbench` is
higher once the existing client `<excludes>` apply); every other package ≥69%; only the
2-line `protocols.Indexable` marker is 0% noise. Python is naturally per-module (files).

## Changes

### Java — PACKAGE-element jacoco rule (`java/pom.xml`, `jacoco-check`)
Add a **second `<rule>`** to the existing `jacoco-check` execution:
```xml
<rule>
  <element>PACKAGE</element>
  <limits>
    <limit>
      <counter>LINE</counter>
      <value>COVEREDRATIO</value>
      <minimum>0.50</minimum>
    </limit>
  </limits>
</rule>
```
The execution-level `<excludes>` apply to all rules; add `**/protocols/Indexable*` to that
shared list so the 2-line marker package doesn't trip the floor. The existing BUNDLE rule
(line 0.84 + branch 0.68) is unchanged. No package below 50% line → catches a subsystem
regressing; current lowest gated package ~55.7% gives ~5pt buffer.

Empirically confirm before locking: temporarily set the PACKAGE `<minimum>` to 0.99, run
`mvn -o -B verify`, read which package + ratio jacoco reports as lowest, confirm it's
≥~0.55 (so 0.50 has buffer). If the lowest gated package is below ~0.52, either lower the
floor to ~2pt below it or add that package to a documented exclude — note the deviation.

### Python — per-module floor check (`python/scripts/check_module_coverage.py` + CI wiring)
New script parsing the `coverage.xml` the CI Python job already emits
(`pytest ... --cov-report=xml`). For each `<class filename=...>`, compute line ratio
(`hits>0` over total `<line>`); **fail (exit 1)** listing any module below the floor.
- Floor: **0.50**, override via `--min`/env.
- Excludes (documented known-low, matched by path suffix): `exporters/_select.py` (35.9%),
  `workbench/transport/errors.py` (45%). (The `omit`-listed workbench live-daemon clients
  never appear in `coverage.xml`, so they're naturally out.)
- Usage: `python scripts/check_module_coverage.py coverage.xml` (default min 0.50).
- CI wiring: in `.github/workflows/ci.yml`, the gated Python job, add a step **after** the
  `pytest ... --cov-report=xml --cov-fail-under=84` step that runs the checker against the
  emitted `coverage.xml` (path = `python/coverage.xml` relative to repo, or `coverage.xml`
  in the job's `python` working-dir — match the existing step's working-directory).

The script must be self-contained (stdlib only — `xml.etree`, `argparse`, `sys`), print a
clear table of violators, and exit 0 when all included modules meet the floor.

### Floor = no-regression, ratchet later
0.50 both sides — below the current lowest *included* unit, locking in "no subsystem/module
abandoned" without blocking normal work. Ratcheted in R6.

## Invariants & verification
- Config + one new script only — no production/test code change.
- Java: `cd java && JAVA_HOME=~/jdk25 mvn -o -B verify` passes ALL rules (BUNDLE line+branch
  AND PACKAGE ≥0.50). Gate-bites: a throwaway PACKAGE `<minimum>` above the lowest package
  FAILS; revert.
- Python: `cd python && .venv/bin/python scripts/check_module_coverage.py coverage.xml`
  exits 0 on the current coverage.xml; a throwaway `--min 0.70` FAILS (proving it bites);
  excludes are honored.
- CI: both the jacoco PACKAGE rule (via `mvn verify`) and the new Python checker step
  enforce on every run.

## Success criteria
A Java package or Python module dropping below 50% fails CI. `mvn verify` green with the
new rule; the Python checker green on current coverage and demonstrably failing below
floor. One PR.

## Out of scope (tracked separately)
R6 (ratchet all gates up toward current actuals), R7/R8 (live-daemon + native coverage).
Raising any specific unit's coverage is future, not R5 — R5 only adds the floors.
