# Java Branch-Coverage Gate (R4) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Gate Java JaCoCo **branch** coverage at a no-regression floor of 0.68 (currently ~0.695), alongside the existing line gate.

**Architecture:** Add one `<limit>` (counter `BRANCH`) to the existing `BUNDLE` rule in `java/pom.xml`'s `jacoco-check` execution. Config + comment only.

**Tech Stack:** Maven, jacoco-maven-plugin 0.8.12.

**Verify (WSL):** `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify`. WSL shell: `wsl -d Ubuntu -- bash -c '<cmd>'`. Commits: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...`. If a Read shows empty (WSL mount glitch), retry or `cat` via wsl.

---

## Task 1: Add the branch limit to the BUNDLE rule

**Files:**
- Modify: `java/pom.xml` (the `jacoco-maven-plugin` → `jacoco-check` execution → `<rules><rule><element>BUNDLE</element><limits>`)

**Context:** The `jacoco-check` execution (around `java/pom.xml:318-372`) has one `<rule>` with `<element>BUNDLE</element>` containing a single `<limit>` (`<counter>LINE</counter>`, `<value>COVEREDRATIO</value>`, `<minimum>0.84</minimum>`) plus shared workbench-client `<excludes>`. We add a second `<limit>` for BRANCH in the SAME `<limits>` block. Current gated branch ratio ≈ 0.695; line ≈ 0.87 (the pom's "~84.2%" comment is stale, pre-R1/R3).

- [ ] **Step 1: Read the current rule**

Read `java/pom.xml` around the `jacoco-check` execution (the `<rules>` block). Identify the exact `<limits>` element holding the LINE limit and the indentation in use.

- [ ] **Step 2: Empirically confirm the exact gated branch ratio (probe)**

Temporarily add the branch limit with an IMPOSSIBLE minimum to read the real gated ratio. Insert this `<limit>` right after the existing LINE `<limit>` (inside the same `<limits>`), matching indentation:

```xml
                                        <limit>
                                            <counter>BRANCH</counter>
                                            <value>COVEREDRATIO</value>
                                            <minimum>0.99</minimum>
                                        </limit>
```

Run: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | grep -iE "branch|coverage checks|BUILD"`
Expected: BUILD FAILURE with a line like `Rule violated for bundle ttio: branches covered ratio is 0.XX, but expected minimum 0.99`. RECORD that actual ratio `0.XX`. Confirm `0.XX >= 0.69` (so the 0.68 floor has ~1pt buffer). If the actual gated ratio is unexpectedly below 0.69, set the final floor ~1pt below it instead of 0.68 and note the deviation in your report.

- [ ] **Step 3: Set the real floor (0.68) + refresh the stale comment**

Change the probe `<minimum>` from `0.99` to `0.68`. Add a comment above the branch limit, e.g.:
```xml
                                        <!-- Branch-coverage gate (R4). No-regression floor:
                                             gated bundle branch ratio is ~0.695 (2026-06-06,
                                             post-R1/R3). 0.68 leaves ~1pt buffer; ratchet up
                                             in R6 as branch coverage improves. -->
                                        <limit>
                                            <counter>BRANCH</counter>
                                            <value>COVEREDRATIO</value>
                                            <minimum>0.68</minimum>
                                        </limit>
```
Also refresh the STALE part of the existing LINE limit's comment: it says "Local mvn verify lands at ~84.2%" — update to reflect that line coverage is now ~87% after R1 (CLI in-process tests) and R3 (fqzcomp dead-code removal), so the 0.84 floor has a wider buffer. Keep the rest of that comment's history note intact; just correct the stale "~84.2%" figure. Do NOT change the LINE `<minimum>` (stays 0.84).

- [ ] **Step 4: Verify both gates pass**

Run: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | grep -iE "coverage checks|BUILD|Tests run:.*Failures" | tail -5`
Expected: `BUILD SUCCESS`, `All coverage checks have been met.`, 0 failures. (Both LINE ≥0.84 and BRANCH ≥0.68 now enforced.)

- [ ] **Step 5: Confirm the gate actually bites (throwaway check, then revert)**

Temporarily bump the branch `<minimum>` to a value just above the actual ratio recorded in Step 2 (e.g. if actual is 0.695, set 0.71), run `JAVA_HOME=~/jdk25 mvn -o -B verify 2>&1 | grep -iE "branch|BUILD" | tail -3`, and CONFIRM it FAILS with the branch-ratio violation message. Then REVERT the `<minimum>` back to `0.68`. (This proves the gate is wired correctly, not silently ignored.) Re-run Step 4 once more to confirm green at 0.68.

- [ ] **Step 6: Confirm the diff is config-only**

Run: `wsl -d Ubuntu -- bash -c 'cd ~/TTI-O && git diff --stat'`
Expected: only `java/pom.xml` changed. No `src/` files.

- [ ] **Step 7: Commit**

```bash
git add java/pom.xml
git commit -m "build(java): gate JaCoCo branch coverage at 0.68 (no-regression floor)"
```

---

## Final verification
- [ ] `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify` → BUILD SUCCESS, "All coverage checks have been met" (both line ≥0.84 and branch ≥0.68).
- [ ] Push (Windows git), open PR vs `main`, watch CI (the Java `mvn verify` job now enforces branch), merge once green, sync main.
- [ ] Update memory (`project_tti_o_coverage_improvement`): R4 done, Java branch gated at 0.68.
