# R7 — workbench-client coverage via the live daemon

> Coverage campaign follow-up (R7, from `docs/architecture/2026-06-06-coverage-analysis.md`).
> Implements: subagent-driven, each task validated locally then in `workbench-live.yml`.

**Goal:** make the existing live-daemon integration tests (`test_workbench_live.py`,
`WorkbenchLiveTest.java`) earn coverage credit and **gate** the workbench-client
modules that are currently dropped from coverage — *in the live workflow*, where
the daemon actually runs.

**Why not the main gate:** the daemon only runs in `workbench-live.yml` (path-filtered,
needs a private cross-repo PAT, ~10–15 min cold build). Forcing it onto `ci.yml`'s
always-on `python-test`/`java-test` would break fork PRs and tax every PR. So the
global `omit`/`<excludes>` stay (they keep `ci.yml`'s gate honest); R7 **adds** a
workbench-scoped coverage gate that runs alongside the live tests.

**Today:** the runner skips coverage entirely — Python live run has no `--cov`;
Java runs `-Djacoco.skip=true`. So the live tests exercise the client code but
earn zero credit. (jacoco `prepare-agent` `<excludes>` also means workbench
classes aren't even instrumented in the normal build.)

## Architecture

- A new env flag **`TTIOWB_COVERAGE=1`** in `scripts/workbench-live-smoke.sh` turns
  on coverage collection + the scoped gate for both languages. Default off, so
  local Python-only runs are unaffected.
- **Python:** a dedicated coverage config `python/coverage-live.cfg` that measures
  `src/ttio/workbench` **without** the workbench omits, with a `fail_under` floor.
  The live pytest run adds `--cov=src/ttio/workbench --cov-config=coverage-live.cfg
  --cov-report=term-missing --cov-report=xml:<work>/workbench-cov.xml`.
- **Java:** a Maven profile **`live-coverage`** that (a) re-instruments workbench
  classes (its own `prepare-agent` without the workbench excludes) and (b) runs a
  jacoco `check` scoped via `<includes>**/workbench/**</includes>` with a LINE
  floor, bound to the `test` phase (the runner calls `mvn … test`).
- `workbench-live.yml` sets `TTIOWB_COVERAGE=1` and uploads the coverage artifacts.
- Floors are set empirically from a first measured run, with a buffer (the R4/R5
  method). The `tools/workbench_cli.py` CLI stays out of scope (it lives under
  `tools/`, not `workbench/`, and isn't exercised by the live client tests).

## Tasks

### Task 1: Python live coverage config + runner flag
**Files:** Create `python/coverage-live.cfg`; modify `scripts/workbench-live-smoke.sh`.
- `coverage-live.cfg`: `[run] source = src/ttio/workbench`, `branch = true`,
  `omit` only non-client noise (none of the W1–W5 client modules); `[report]
  fail_under = <FLOOR>` (set after measuring), `show_missing = true`,
  `exclude_lines` mirroring pyproject.
- Runner: when `TTIOWB_COVERAGE=1`, append the `--cov`/`--cov-config`/`--cov-report`
  args to the python pytest invocation (line ~110).
- **Validate:** run the live smoke locally with `TTIOWB_COVERAGE=1`; record the
  measured `src/ttio/workbench` coverage; set the floor ~2pt below it.

### Task 2: Java `live-coverage` Maven profile + runner
**Files:** modify `java/pom.xml` (add profile), `scripts/workbench-live-smoke.sh`.
- Profile `live-coverage`: a jacoco `prepare-agent` (id `jacoco-live-prepare`)
  with excludes = only `**/protocols/Indexable*` (drop the workbench excludes), and
  a `check` (id `jacoco-live-check`, phase `test`) with `<includes>**/workbench/**</includes>`
  and a BUNDLE LINE floor `<FLOOR>`. Must not disturb the default executions used
  by `ci.yml`'s `mvn verify`.
- Runner: when `TTIOWB_COVERAGE=1`, run the Java leg with `-Plive-coverage` and
  **without** `-Djacoco.skip=true`.
- **Validate:** locally `TTIOWB_JAVA_TEST=1 TTIOWB_COVERAGE=1`; confirm the jacoco
  report lists the workbench classes with real coverage and the check enforces;
  set the floor ~2pt below measured. Confirm plain `mvn verify` (no profile) is
  unchanged.

### Task 3: Wire `workbench-live.yml` + refresh exclusion comments
**Files:** `.github/workflows/workbench-live.yml`; comment-only touches to
`python/pyproject.toml` (omit block) and `java/pom.xml` (excludes blocks).
- Set `TTIOWB_COVERAGE: '1'` on the live-smoke step; upload `workbench-cov.xml` +
  the jacoco workbench report as artifacts.
- Update the `omit`/`<excludes>` comments to note these modules are now coverage-
  **gated in `workbench-live.yml`** (not unmeasured), linking this plan.
- **Validate:** the full `workbench-live.yml` run is green and the gate is active
  (flip the floor impossibly high once to confirm it fails, then restore).

## Verification
- Local: `TTIO_REPO_PATH=$PWD TTIOWB_JAVA_TEST=1 TTIOWB_COVERAGE=1 bash scripts/workbench-live-smoke.sh` → both legs pass, both gates enforce.
- CI: `workbench-live.yml` green with coverage artifacts; `ci.yml` python-test/java-test unchanged (still excluded there).
- Negative control: temporarily raise a floor → the live job fails on the gate.
