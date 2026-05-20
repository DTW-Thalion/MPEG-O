# Live-daemon end-to-end smoke

Closes the cross-W deferral that ran through W1-W5: every prior
sub-phase shipped "implementation present; live verification
deferred." This wires a real `tti-workbench-server` daemon into
CI and drives the actual `ttio.workbench.*` client SDK against
it.

## What it proves

The unit suites pin the wire shapes (cross-language anchors,
record parsing). This smoke proves the client *actually talks to
the daemon* end-to-end:

| Flow | Milestone | Live-test |
|---|---|---|
| connect via BootstrapAdminAuth | W1 auth | `test_connect_as_bootstrap_admin` |
| `containers().list()` | W5.2 / SDK | `test_containers_list_round_trips` |
| `pipelines().register/list/get` | W3 | `test_pipeline_register_then_listed` |
| `jobs().submit` + poll to terminal | W3 | `test_job_submit_runs_to_completion` |
| `jobs().events()` SSE to terminal | W3 | `test_job_events_stream_reaches_terminal` |
| `jobs().cancel()` | W3 | `test_job_cancel` |
| `sessions().create/list/terminate` | W4 | `test_session_create_list_terminate` |
| cohort `preview_count()` | W3 | `test_cohort_preview_count_round_trips` |

## Pieces

| File | Role |
|---|---|
| `python/tests/integration/test_workbench_live.py` | The test. Env-gated: SKIPS unless `TTIO_WORKBENCH_URL` + `TTIO_WORKBENCH_STAGING` are set, so the normal unit CI is untouched. |
| `scripts/workbench-live-smoke.sh` | Local runner. Boots the daemon with a temp SQLite config, seeds the bootstrap admin's project, exports the env vars, runs pytest, tears down. |
| `.github/workflows/workbench-live.yml` | CI. Builds the GNUstep/ObjC toolchain + libTTIO (from the PR checkout) + the pinned `tti-workbench-server`, boots the daemon, runs the smoke. |

## Running locally

The server must be built once
(`cd tti-workbench-server && bash scripts/build.sh`); then:

```bash
cd TTI-O
TTIO_REPO_PATH=$PWD PYTHONPATH=python/src \
  bash scripts/workbench-live-smoke.sh
```

Expected: `8 passed`.

## CI

`workbench-live.yml` runs on:
- PRs touching `python/src/ttio/workbench/**`, the test, the
  runner, or the workflow itself
- manual dispatch

It is **not** a blanket per-PR gate (the cold GNUstep build is
~10-15 min; warm-cache ~2-3 min). The toolchain build is copied
faithfully from the server repo's proven `setup-daemon`
composite action, with libTTIO built from the PR's TTI-O
checkout (not `main`) so the smoke validates the PR's client
code.

**Secret requirement:** cross-repo checkout of the private
sibling repos (`tti-workbench-server`, `libobjc2`, `libs-base`)
needs `TTIO_LIBRARY_CHECKOUT_TOKEN` (a PAT with repo scope) in
the TTI-O repo secrets. Falls back to `GITHUB_TOKEN`, which works
only if those repos are readable by the default token. This is
the same secret the server repo's own CI uses.

## Bugs / gaps the smoke caught

1. **W5.2 `containers.py` keyword-arg bug** (fixed in this PR).
   `ContainersClient` called `http_json(...)` and
   `WorkbenchHttpError(...)` with positional args for
   keyword-only parameters (`scheme`, `token`, `body` / `status`,
   `body`). The W5.2 unit tests only covered the pure dataclasses
   (the HTTP methods are coverage-excluded), so this was invisible
   until the live round-trip. All five methods (`list` / `get` /
   `layers` / `manifest` / `delete`) are fixed to use keyword
   args.

2. **Server-side: cohort HTTP handler not registered** (FIXED in
   tti-workbench-server PR #29). `TTIOWBCohortsHandler` was
   implemented in `tti-workbench-server` but never registered in
   `Source/Core/TTIOWBServer.m` (the daemon wired
   Containers / Auth / Pipelines / Jobs / Sessions / Metrics, but
   not Cohorts), so `/v1/cohorts/query` and
   `/v1/cohorts/preview-count` returned 404 on the v1.0 daemon --
   the cohort plane was exercised only by the server's parity
   binary, never over HTTP. The client SDK request was already
   correct (it raised a clean `WorkbenchHttpError(404)`). PR #29
   constructs a shared `TTIOWBCohortService` + registers the
   handler (and wires the same service into `TTIOWBJobsHandler`,
   previously `cohortService:nil`); the server CI now guards it
   with `scripts/smoke_cohort.sh`. The cohort live test
   (`test_cohort_preview_count_round_trips`) runs normally as of
   that merge.

## Java client live coverage (added)

`java/src/test/java/global/thalion/ttio/workbench/WorkbenchLiveTest.java`
is the parity counterpart to the Python smoke -- same flow
(connect -> containers -> cohort -> pipelines -> jobs
submit/poll/events/cancel -> sessions), gated by the same
`TTIO_WORKBENCH_URL` env var (`@EnabledIfEnvironmentVariable`, so
normal `mvn verify` skips it). The `workbench-live` workflow runs
it against the same daemon as the Python smoke
(`TTIOWB_JAVA_TEST=1`); the runner combines both exit codes.

This closed a real gap: the Java REST surface had only ever been
byte-equivalence tested, which hid two Java-side bugs until the
win-x64 GUI was run by hand --
(1) `java.net.http.HttpClient` defaulting to HTTP/2 (the daemon
is libwebsockets HTTP/1.1-only; the h2c upgrade made it close the
connection -> "EOF reached while reading"), and
(2) the `LoginDialog` bound-button crash. Both fixed; the Java
live test now exercises the path that would have caught them.

## Still deferred (genuine v1.1 / server-dependent)

- **Upload + download live round-trip.** Needs a synthesised
  `.tis` payload + a writable project; the transport WS path is
  unit-tested + cross-language-anchored (W1), but a live
  byte-round-trip is a natural next addition to this smoke.
