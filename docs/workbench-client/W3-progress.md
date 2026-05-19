# W3 progress

Status snapshot for the **cohort + pipeline + job client surface
(Python + Java, lockstep)** milestone per
[`docs/workbench-client-workplan.md`](../workbench-client-workplan.md).

## Status (2026-05-19): COMPLETE -- in review

131 Python + cross-language Java workbench tests pass locally.

## Server-side survey (kickoff input)

Before writing client code, surveyed the
[`tti-workbench-server` v1.0.0](https://github.com/DTW-Thalion/tti-workbench-server/releases/tag/v1.0.0)
wire contract for W3 surfaces:
`/v1/cohorts/{query,preview-count}`, `/v1/pipelines{,/{id}}`,
`/v1/jobs{,/{id},/{id}/events}`. Confirmed against the
`Documentation/{cohort,pipeline}-protocol.md` and the handler
code at `Source/HTTP/handlers/{TTIOWBCohortsHandler,
TTIOWBPipelinesHandler,TTIOWBJobsHandler}.m`.

**v1.0 server deferrals** that the W3 client respects:

- **No `GET /v1/cohorts` / `POST /v1/cohorts`** -- cohort queries
  are ephemeral; saved-cohort support is a future server upgrade.
- **No `has_layer(...)` assay-availability filters** in the
  cohort predicate AST. Documented as a v1.x server feature.
- **No `Last-Event-Id` SSE resumption** -- clients reconnect for
  a full state replay.
- **No `GET /v1/containers/{uri}/provenance` HTTP endpoint** --
  `provenance_edges` table is populated server-side but not
  exposed. The CLI's `ttio provenance` subcommand surfaces a
  clear deferral.

**Cohort predicate AST**: 4 leaf kinds (`container_field`,
`subject_field`, `sample_field`, `phenotype`) with allow-listed
columns per kind; 9 operators (eq/ne/lt/gt/le/ge/in/like/exists);
3 composites (and/or/not). Phenotype leaves rejected under OR /
NOT (column-join can't reason about NULL the same way as
structural fields -- server returns 422).

**Job state machine**: queued → starting → running → completed |
failed | cancelled. Terminal statuses: completed, failed,
cancelled. `DELETE /v1/jobs/{id}` cancels (queued → cancelled
directly, running → SIGTERM + cancel-grace-window).

**SSE wire format**: plain HTTP body, no chunked encoding;
`event: <name>\\ndata: <json>\\n\\n`. v1.0 emits only
`job.state` events.

## Deliverables shipped

### Python (`python/src/ttio/workbench/`)

| File | Purpose |
|---|---|
| `cohort.py` | Predicate AST + `CohortQuery` builder + `CohortResult` parser. Operator overloading (`&` / `|` / `~`). Allow-list validation per leaf kind. Phenotype-under-OR/NOT rejection (with deep-nesting detection). |
| `pipeline.py` | `Pipeline` dataclass + `PipelinesClient` (register / list / get). |
| `jobs.py` | `Job` dataclass + `JobsClient` (submit / list / get / cancel) + `JobEvent` + async-iterator `events()` SSE parser. `build_cohort_input()` builds Decision-4 envelope. |
| `_http.py` | Internal REST helper (urllib, zero new deps). |
| `client.py` | `WorkbenchClient.query / preview_count / submit_pipeline / pipelines() / jobs()` promoted from W2 stubs to live methods. |

### Java (`java/src/main/java/global/thalion/ttio/workbench/`)

| File | Purpose |
|---|---|
| `cohort/CohortPredicate.java` + 7 subclasses | Mirror of the Python AST. Same validation rules. JSON serialiser produces output byte-identical to Python. |
| `cohort/CohortQuery.java` | Builder mirror. |
| `cohort/CohortResult.java` | Result record. |
| `pipeline/Pipeline.java`, `PipelinesClient.java` | Pipeline registry surface. |
| `jobs/Job.java`, `JobEvent.java`, `JobsClient.java` | Job + SSE surface. Callback-driven `events(jobId, Consumer<JobEvent>)` rather than async iterator -- fits the existing Java-WebSocket pattern. |
| `WorkbenchHttp.java` | Internal REST helper over `java.net.http.HttpClient`. |
| `WorkbenchClient.java` | `query()` / `previewCount()` / `pipelines()` / `jobs()` live. |

### CLI (`python/src/ttio/tools/workbench_cli.py`)

W2-era placeholder subcommands promoted to live implementations:

| Subcommand | Implementation | Status |
|---|---|---|
| `query` | POST /v1/cohorts/query (or preview-count via `--count-only`); predicate from `--predicate-json` or `--predicate-file` | LIVE |
| `submit` | POST /v1/jobs with `--pipeline` + `--inputs-file` + optional `--params-file` | LIVE |
| `jobs ls/status/cancel/events` | Wraps `JobsClient`. `events` streams SSE one JSON line per event | LIVE |
| `pipelines ls/get/register` | Wraps `PipelinesClient` | LIVE |
| `cohorts` | Alias for `query` (v1.0 has no saved cohorts) | LIVE |
| `provenance` | Surfaces a clear "v1.0 doesn't expose this endpoint" deferral + exit 2 | DEFERRED |
| `sessions` | W4 placeholder (unchanged from W2) | STUB |

## Cross-language byte-equivalence

The cohort predicate AST has a single anchor literal pinned in
both test suites. Same `(container_field=project, eq=alpha) AND
(phenotype=diagnosis, eq=Alzheimer's)` input produces:

```
{"op":"and","children":[{"container_field":"project","op":"eq","value":"alpha"},{"phenotype":"diagnosis","op":"eq","value":"Alzheimer's"}]}
```

in both Python (`json.dumps(separators=(",", ":"))`) and Java
(`WorkbenchJson.encode`). Any drift in either client fails both
test suites simultaneously.

## Acceptance criteria

From the W3 section of the workplan:

- [x] `ttio query ... | ttio submit -` end-to-end shape works at
      argparse + SDK level (live daemon validation is the W3 follow-up).
- [x] `ttio jobs events <id>` streams SSE and terminates on
      terminal state (parser tested; daemon round-trip is a
      W3 follow-up).
- [ ] Provenance DAG round-trips -- BLOCKED by v1.0 server (no
      HTTP endpoint). Surfaces a clear deferral message instead.

## Deferred to W3 follow-up

- **Live daemon round-trip integration tests.** Same shape as the
  W1 follow-up -- needs to vendor or build the workbench-server
  binary in CI.
- **`ttio provenance` HTTP support** -- needs a v1.x server release
  that adds `GET /v1/containers/{uri}/provenance`.
- **Notebook tutorial** -- post-W4 doc PR once interactive
  sessions land.

## Next: W4

Interactive sessions client. Wires the `/v1/sessions` REST
surface + the `/v1/sessions/{id}/` WS-proxy attach helper. Reuses
the W3 SDK foundation; CLI's `ttio sessions` subcommand becomes
live.
