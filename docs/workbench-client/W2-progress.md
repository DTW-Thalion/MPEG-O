# W2 progress

Status snapshot for the **`ttio` CLI umbrella + Python SDK
foundation** milestone per
[`docs/workbench-client-workplan.md`](../workbench-client-workplan.md).

## Status (2026-05-19): COMPLETE -- in review

PR is open against `main`. 79 Python workbench tests
(37 W1 + 42 W2 new) pass locally.

## Deliverables shipped

### SDK foundation (`python/src/ttio/workbench/`)

| File | Purpose |
|---|---|
| `auth_providers.py` | `AuthProvider` ABC; four concrete providers: `PasswordTotpAuth`, `BearerAuth`, `BootstrapAdminAuth`, `OIDCAuth` (v1.1 stub). |
| `client.py` | `connect(url, auth=...)` factory; `WorkbenchClient` class with `upload_client()` / `download_client()` builders + `upload_bytes()` / `download_bytes()` async convenience methods; W3/W4 surface methods registered as `NotImplementedError`-raising stubs; `_parse_url()` accepting wss/ws/https/http/bare; `parse_filter_kv()` for the CLI's `--filter k=v` flag. |
| `cohort.py` | W3 namespace stub: `CohortQuery`, `CohortResult`. |
| `pipeline.py` | W3 namespace stub: `PipelineClient`. |
| `jobs.py` | W3 namespace stub: `Job`, `JobsClient`. |
| `sessions.py` | W4 namespace stub: `InteractiveSession`, `SessionProxy`. |

Top-level `ttio` (`python/src/ttio/__init__.py`) re-exports
`connect`, `WorkbenchClient`, `Session`, `PasswordTotpAuth`,
`BearerAuth`, `BootstrapAdminAuth`, `OIDCAuth`. The spec
section 8.3 sample literally runs (modulo `client.query()`
which raises a clear "W3" error).

### CLI (`python/src/ttio/tools/workbench_cli.py`)

`ttio` umbrella with 12 subcommands matching spec section 8.2:

| Subcommand | Implementation | Status |
|---|---|---|
| `login`     | SDK `connect()` + JSON print of `client.session` | LIVE |
| `upload`    | SDK `upload_bytes()` reading `--file` from disk | LIVE |
| `download`  | SDK `download_bytes()` writing `--output` to disk | LIVE |
| `stream`    | Like `download`; outputs raw `.tis` bytes | LIVE |
| `inspect`   | SDK `download_bytes(output_mode="stats-only")` | LIVE |
| `encode`    | Dispatches to `ttio.tools.{fastq,fasta}_import_cli` | LIVE (fastq + fasta only; W6 adds the rest) |
| `export`    | Dispatches to `ttio.tools.{fastq,fasta}_export_cli` | LIVE (same) |
| `query`     | W3 placeholder: exit 2 with milestone message | STUB |
| `submit`    | W3 placeholder | STUB |
| `jobs`      | W3 placeholder | STUB |
| `cohorts`   | W3 placeholder | STUB |
| `sessions`  | W4 placeholder | STUB |

Auth-mode resolver enforces exactly one of `--token+--owner`,
`--staging-root`, or `--username+--password+--totp` and surfaces
a clear "pick exactly one auth mode" error otherwise.

`pyproject.toml` gains `[project.scripts] ttio = ...` so
`pip install -e python/` exposes the `ttio` binary.

### Tests (`python/tests/workbench/`)

| File | Tests | Coverage |
|---|---|---|
| `test_client.py` | 21 | top-level re-exports, URL parser (5 schemes + 2 error paths), four auth providers, connect() factory, W3/W4 placeholder method dispatch, `parse_filter_kv` (7 paths). |
| `test_cli.py`    | 21 | every subcommand `--help`, auth-mode resolver (3 failure modes), W3/W4 placeholder exits, encode unsupported-format pointer to W6, repeatable `--filter` flag plumbing. |

All structural / pure-data; no daemon needed.

## Acceptance criteria

From the W2 section of the workplan:

- [x] Every `ttio` subcommand listed in spec section 8.2 has a
      working implementation OR a clear "W3"/"W4" placeholder.
- [x] `python -c "import ttio; ttio.connect(...)"` returns a
      working client (via stub auth provider in tests).
- [x] CLI smoke: `ttio --version`, `ttio --help`, every subcommand
      `--help` -- all pass.
- [x] SDK unit: mirrors the spec section 8.3 example structurally.

## Deferred to W2 follow-up

- **End-to-end notebook tutorial.** The workplan promised
  "one end-to-end notebook in `python/docs/` walks through 'ingest
  a FASTQ, upload, query metadata, download a filtered slice'".
  Deferred to a v1.4.x doc PR after W3 lands the query surface --
  without `client.query()`, the notebook would only cover half
  of the spec section 8.3 sample, which is misleading.
- **CLI ergonomic `~/.ttio/config.toml`.** Workplan open question
  6: a default-server config file would save repeating `--server`
  on every invocation. Not load-bearing for any acceptance
  criterion; lands as a usability follow-up in v1.5.x.
- **Encode/export beyond fastq + fasta.** Spec section 4.2-4.7
  formats (BAM/CRAM/VCF/mzML/IDAT/etc.) ship in W6.

## Next: W3

Cohort + pipeline + job client surface. W2's stubs become real
implementations; spec UCs 6/7/9/10/14 land. Reuses the W2 SDK
foundation (`connect()`, `Session`, `WorkbenchClient`) without
breaking changes.
