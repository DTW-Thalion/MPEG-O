# Per-Unit Coverage Floors (R5) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stop a single Java package / Python module from silently dropping to ~0 while the aggregate gate holds. Add a jacoco PACKAGE floor (0.50) and a Python per-module CI checker (0.50, 2 known-low excludes).

**Architecture:** Java — second `<rule>` (`<element>PACKAGE</element>`) in the existing `jacoco-check`. Python — new stdlib-only `scripts/check_module_coverage.py` parsing the `coverage.xml` CI already emits, wired into the gated Python job. Config + one script; no production/test code.

**Verify (WSL):** Java `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify`; Python `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/python scripts/check_module_coverage.py coverage.xml`. WSL: `wsl -d Ubuntu -- bash -c '<cmd>'`. Commits: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...`. If a Read shows empty (WSL mount glitch), retry or `cat` via wsl.

**Measured baseline (2026-06-06):** Java lowest real package `importers.readers` 55.7%, `workbench` 56.0% (gated higher), all others ≥69%; only 2-line `protocols.Indexable` is 0%. Python lowest modules `exporters/_select.py` 35.9%, `workbench/transport/errors.py` 45%, then `importers/bruker_tdf_cli.py` 50.0%.

---

## Task 1: Java PACKAGE-element jacoco floor

**Files:**
- Modify: `java/pom.xml` (the `jacoco-maven-plugin` → `jacoco-check` execution)

**Context:** The `jacoco-check` execution has `<excludes>` (workbench clients) shared across rules and one `<rule>` `<element>BUNDLE</element>` with LINE ≥0.84 + BRANCH ≥0.68 limits. Add a SECOND `<rule>` for PACKAGE LINE ≥0.50, and add `**/protocols/Indexable*` to the shared `<excludes>` (2-line marker that would otherwise be a 0% package).

- [ ] **Step 1: Read the current `jacoco-check` execution** in `java/pom.xml` (the `<excludes>` + `<rules>` blocks). Note the indentation.

- [ ] **Step 2: Add the protocols marker to the shared excludes.** In the `<excludes>` list (alongside the `**/workbench/...` entries), add:
```xml
                                <!-- 2-line marker interface; a 0% "package"
                                     that would trip the PACKAGE floor. -->
                                <exclude>**/protocols/Indexable*</exclude>
```

- [ ] **Step 3: Probe the lowest gated package.** Temporarily add the PACKAGE rule with an impossible minimum, right after the existing BUNDLE `</rule>` (inside `<rules>`), matching indentation:
```xml
                                <rule>
                                    <element>PACKAGE</element>
                                    <limits>
                                        <limit>
                                            <counter>LINE</counter>
                                            <value>COVEREDRATIO</value>
                                            <minimum>0.99</minimum>
                                        </limit>
                                    </limits>
                                </rule>
```
Run `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | grep -iE "Rule violated|package|coverage checks|BUILD" | tail -10`. jacoco prints a violation per package below 0.99 — find the LOWEST `global.thalion.ttio.*` package ratio. RECORD it. Confirm the lowest gated package is ≥ ~0.52 (so 0.50 has buffer). If the lowest is below ~0.52, either set the floor ~2pt below it OR add that package to `<excludes>` with a documented reason — note the deviation in your report.

- [ ] **Step 4: Set the real floor (0.50) + comment.** Change the probe `<minimum>` from `0.99` to `0.50`, and add a comment above the PACKAGE rule:
```xml
                                <!-- R5 per-package floor: no package below 50%
                                     line coverage, so a subsystem can't silently
                                     regress behind the BUNDLE aggregate. Lowest
                                     gated package ~55.7% (importers.readers,
                                     2026-06-06); 0.50 leaves buffer. Shares the
                                     excludes above. Ratchet in R6. -->
```

- [ ] **Step 5: Verify all rules pass.** `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | grep -iE "coverage checks|BUILD|Tests run:.*Failures" | tail -4` → `BUILD SUCCESS`, `All coverage checks have been met.`, 0 failures (BUNDLE line+branch AND PACKAGE ≥0.50 all enforced).

- [ ] **Step 6: Gate-bites proof (then revert).** Set the PACKAGE `<minimum>` to just above the lowest package recorded in Step 3 (e.g. lowest 0.557 → set 0.58), run `JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | grep -iE "Rule violated|package|BUILD" | tail -4`, CONFIRM it FAILS naming a package below threshold. Then REVERT to `0.50` and re-run Step 5 to confirm green.

- [ ] **Step 7: Confirm diff is pom-only + commit.**
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git diff --stat'   # only java/pom.xml
git add java/pom.xml
git commit -m "build(java): add per-package jacoco floor (no package below 0.50)"
```

---

## Task 2: Python per-module floor checker + CI wiring

**Files:**
- Create: `python/scripts/check_module_coverage.py`
- Modify: `.github/workflows/ci.yml` (the gated Python job)

**Context:** CI's gated step (`.github/workflows/ci.yml`, `working-directory: python`) runs `pytest -v --tb=short --cov=src/ttio --cov-report=term --cov-report=xml --cov-report=html --cov-fail-under=84` (line ~194), emitting `python/coverage.xml`. Add a checker that fails if any included module is below 0.50, excluding the 2 known-low modules, and run it right after. The `omit`-listed workbench live-daemon clients never appear in coverage.xml, so they're naturally excluded.

- [ ] **Step 1: Create the checker script** `python/scripts/check_module_coverage.py`:

```python
#!/usr/bin/env python3
"""Per-module coverage floor (R5).

Fail if any measured module's line coverage is below a floor (default 0.50).
Parses the coverage.xml that ``pytest --cov-report=xml`` emits. Complements
the aggregate ``--cov-fail-under`` gate by catching a single module silently
regressing to near-zero behind the total.

A small set of known-low modules is excluded (documented below); the
coverage ``omit`` list (live-daemon workbench clients) never appears in
coverage.xml, so those are excluded automatically.

Usage:
    python scripts/check_module_coverage.py coverage.xml [--min 0.50]

SPDX-License-Identifier: Apache-2.0
"""
from __future__ import annotations

import argparse
import sys
import xml.etree.ElementTree as ET

# Known-low modules, excluded from the floor with a recorded reason.
# Matched by path suffix against each <class filename="...">.
EXCLUDES = (
    "exporters/_select.py",          # 35.9% — thin selection helper
    "workbench/transport/errors.py", # 45%  — error-type definitions
)


def module_ratios(xml_path: str) -> list[tuple[str, float, int]]:
    """Return [(filename, line_ratio, n_lines)] for every measured class."""
    root = ET.parse(xml_path).getroot()
    out = []
    for cls in root.iter("class"):
        filename = cls.get("filename", "")
        lines_el = cls.find("lines")
        if lines_el is None:
            continue
        lines = lines_el.findall("line")
        if not lines:
            continue
        hit = sum(1 for ln in lines if int(ln.get("hits", "0")) > 0)
        out.append((filename, hit / len(lines), len(lines)))
    return out


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="Per-module coverage floor check.")
    p.add_argument("coverage_xml", help="path to coverage.xml")
    p.add_argument("--min", type=float, default=0.50,
                   help="minimum per-module line ratio (default 0.50)")
    args = p.parse_args(argv)

    def excluded(fn: str) -> bool:
        return any(fn.endswith(suffix) for suffix in EXCLUDES)

    violations = []
    for filename, ratio, n in module_ratios(args.coverage_xml):
        if excluded(filename):
            continue
        if ratio < args.min:
            violations.append((filename, ratio, n))

    if violations:
        print(f"Per-module coverage floor {args.min:.0%} violated:", file=sys.stderr)
        for filename, ratio, n in sorted(violations, key=lambda t: t[1]):
            print(f"  {ratio:6.1%}  ({n:4d} lines)  {filename}", file=sys.stderr)
        print(f"\n{len(violations)} module(s) below floor. "
              f"Add a test, or (if intentional) add to EXCLUDES with a reason.",
              file=sys.stderr)
        return 1

    print(f"Per-module coverage floor {args.min:.0%}: OK "
          f"(all measured modules at or above floor).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 2: Confirm it passes on the current coverage.xml.** First ensure a coverage.xml exists (generate from the existing `.coverage` if needed: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m coverage xml -o coverage.xml`). Then:
```
cd ~/TTI-O/python && .venv/bin/python scripts/check_module_coverage.py coverage.xml
```
Expected: `Per-module coverage floor 50%: OK`. (If it reports a violation other than the 2 excluded modules, the baseline shifted — list the violator and either it needs the exclude or the floor lowered; report it. The 2 EXCLUDES + the omit'd clients should be the only sub-50% items.)

- [ ] **Step 3: Gate-bites proof.** `cd ~/TTI-O/python && .venv/bin/python scripts/check_module_coverage.py coverage.xml --min 0.70; echo "rc=$?"` → must list several modules and `rc=1` (proves it bites). And confirm excludes work: it must NOT list `exporters/_select.py` or `workbench/transport/errors.py` even at `--min 0.70`.

- [ ] **Step 4: Wire into CI.** In `.github/workflows/ci.yml`, the gated Python job, add a step IMMEDIATELY AFTER the `Run pytest ...` step (the one with `--cov-report=xml --cov-fail-under=84`, `working-directory: python`):
```yaml
      - name: Per-module coverage floor (R5)
        working-directory: python
        run: python scripts/check_module_coverage.py coverage.xml
```
(Same `working-directory: python` so `coverage.xml` resolves. It runs on every matrix leg, after the pytest step that produced the xml.)

- [ ] **Step 5: Confirm diff + commit.**
```bash
wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git diff --stat; git status --porcelain'   # python/scripts/check_module_coverage.py (new) + .github/workflows/ci.yml
git add python/scripts/check_module_coverage.py .github/workflows/ci.yml
git commit -m "ci(python): add per-module coverage floor check (no module below 0.50)"
```

---

## Final verification
- [ ] Java: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify` → BUILD SUCCESS, all coverage checks met (BUNDLE + PACKAGE).
- [ ] Python: `cd ~/TTI-O/python && .venv/bin/python scripts/check_module_coverage.py coverage.xml` → OK; `--min 0.70` → fails (bites).
- [ ] Push (Windows git), open PR vs `main`, watch CI (Java `mvn verify` enforces PACKAGE; new Python step enforces per-module). If the ObjC job hangs on `setup-libarrow`, cancel + `gh run rerun --failed`. Merge once green, sync main.
- [ ] Update memory (`project_tti_o_coverage_improvement`): R5 done — Java PACKAGE floor 0.50, Python per-module floor 0.50.
