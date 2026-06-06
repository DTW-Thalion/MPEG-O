# Java Branch-Coverage Gate (R4) — Design

**Date:** 2026-06-06
**Origin:** `docs/architecture/2026-06-06-coverage-analysis.md` recommendation R4 (finding F1).
**Scope:** Add a JaCoCo **branch**-coverage gate to the Java SDK at a no-regression floor.
Config + comment change only; no production or test code.

## Problem (F1)
The Java JaCoCo gate enforces only **LINE** coverage (BUNDLE ≥ 0.84). **Branch** coverage
is measured but ungated — currently ~69.5% (gated bundle, excluding the workbench client
classes). A line-only gate passes code whose error/edge branches are never exercised both
ways. (Python already gates branches via `branch=true`; ObjC is separate, R2.)

## Change
In `java/pom.xml`, the `jacoco-maven-plugin` `jacoco-check` execution already defines one
`<rule>` with `<element>BUNDLE</element>`, a single `LINE COVEREDRATIO ≥ 0.84` `<limit>`,
and a shared set of workbench-client `<excludes>`. Add a **second `<limit>`** to that same
rule:

```xml
<limit>
  <counter>BRANCH</counter>
  <value>COVEREDRATIO</value>
  <minimum>0.68</minimum>
</limit>
```

Branch coverage is now gated alongside line, sharing the existing excludes. No new rule,
no new excludes, no change to the line limit.

## Floor: no-regression, ratchet later
**0.68**, just below the current gated branch ratio (~0.695). This prevents backsliding
while tolerating normal PR-to-PR branch fluctuation; it is a deliberate floor to be
ratcheted upward later (R6) as branch coverage improves.

**Empirically confirm the exact gated ratio before locking the literal.** JaCoCo's bundle
computation (with `<excludes>`) can differ slightly from a raw `jacoco.csv` sum. Procedure:
temporarily set the branch `<minimum>` to an impossible value (e.g. `0.99`), run
`mvn -o -B verify`, and read JaCoCo's failure message — it prints the actual ratio
("branches covered ratio is 0.69, but expected minimum 0.99"). Confirm the real gated
ratio is comfortably above 0.68 (if it were unexpectedly below ~0.69, reduce the floor to
keep ~1pt buffer and note it). Then set the `<minimum>` to `0.68`.

## Hygiene (same comment block)
The line-limit's inline comment claims "Local mvn verify lands at ~84.2%" — stale; actual
is ~87% after R1 (CLI tests) + R3 (fqzcomp dead-code removal). Refresh it to current
reality and add a short note explaining the branch floor is a no-regression gate to be
ratcheted later.

## Invariants & verification
- **Config + comment only** — no `src/main` or `src/test` change.
- `cd java && JAVA_HOME=~/jdk25 mvn -o -B verify` passes with BOTH the line (≥0.84) and
  branch (≥0.68) limits enforced ("All coverage checks have been met").
- Prove the gate bites: a throwaway run with branch `<minimum>` set too high must FAIL the
  build (then revert to 0.68).
- CI: the Java job's `mvn verify` now enforces branch coverage.

## Success criteria
`java/pom.xml` gates BUNDLE branch ≥ 0.68 alongside line ≥ 0.84; `mvn verify` green; the
gate demonstrably fails when branch coverage would drop below the floor. One small PR.

## Out of scope (tracked separately)
R2 (ObjC gate enforcement + lcov scope), R5 (per-class/package floor), R6 (ratchet the
line + branch gates up after gains), R7/R8 (live-daemon + native coverage). Raising branch
coverage itself (writing more branch tests) is R6/future, not R4 — R4 only locks in the
current level.
