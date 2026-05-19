# W1 progress

Status snapshot for the **Workbench-aware transport client (Python + Java)**
milestone per [`docs/workbench-client-workplan.md`](../workbench-client-workplan.md).

## Status (2026-05-19): COMPLETE -- in review

PR is open against `main`. Acceptance criteria below; cross-language
byte-equivalence anchored by literal JSON strings in both test suites.

## Server-side survey (kickoff input)

Before writing any client code, surveyed the
[`tti-workbench-server` v1.0.0](https://github.com/DTW-Thalion/tti-workbench-server/releases/tag/v1.0.0)
wire contract directly from source + the existing
`Documentation/{auth, upload-protocol, download-protocol}.md`.
Key takeaways:

- **WS subprotocol** required: `ttio-transport` (libwebsockets
  mount enforces).
- **Handshake first-frame**: TEXT JSON, `{"type":"handshake", ...}`
  with `owner` + `project` + `container_uri` (upload) or
  `mode:"download"` + `container_uri` (download). `token` field
  carries the bearer; `resume_handle` switches to resume mode.
- **Server ack**: `{"type":"ack","handle":"stg-...","au_sequence":N}`.
  `au_sequence` is the resume point (0 on fresh upload; the
  persisted value on resume).
- **Per-AU acks** during upload: `{"type":"ack","au_sequence":N}`,
  one per parsed AU. The server appends frame payloads to the
  staging `transport.bin` *before* parsing, so failures leave
  resumable state on disk.
- **Terminal frames**: `{"type":"done","container_uri":...}`
  (success) or `{"type":"error","message"|"reason":...}` (failure).
  WS closes with code 1000 (clean), 1002 (protocol error), or
  1011 (server error) immediately after.
- **Filter predicates** the v1.0 download path accepts:
  `ms_level`, `polarity`, `retention_time_min` / `_max`,
  `precursor_mz_min` / `_max`, `precursor_charge`, `max_au`.
- **Cross-project access** denied via WS close 1011 with
  `"container not found"` reason (no existence disclosure --
  the same "404 not 403" rule the REST surface uses).
- **TOTP**: RFC 6238, HMAC-SHA1, 30-second step, 6 digits, T0=0,
  +/- 1 step skew tolerated.
- **Bootstrap-credentials** file: `<staging_root>/bootstrap-credentials.json`,
  mode 0600, carries `password` + `totp_secret_base32`. Smoke
  harnesses use this; production clients use interactive login.

The existing `Documentation/upload-protocol.md` and
`download-protocol.md` cover the wire-level detail concretely
enough to drive client implementation; the survey found no
showstoppers. A few micro-gaps (e.g., behaviour on duplicate
`container_uri` -- inferred from code as WS close 1002) were
noted in commit messages but did not warrant new server-side docs.

## Deliverables (this PR)

### Python (`python/src/ttio/workbench/`)
- `__init__.py` -- namespace re-exporting auth + transport helpers.
- `auth.py` -- TOTP, Session, login_password.
- `transport/__init__.py` -- namespace re-exporting client classes.
- `transport/errors.py` -- typed exception hierarchy.
- `transport/handshake.py` -- pure builders + parser.
- `transport/resume.py` -- ResumeState dataclass.
- `transport/upload.py` -- UploadClient.
- `transport/download.py` -- DownloadClient.

### Java (`java/src/main/java/global/thalion/ttio/workbench/`)
- `package-info.java` (root + transport package).
- `WorkbenchJson.java` -- compact JSON encode + parse.
- `auth/Session.java`, `Totp.java`, `Login.java`.
- `auth/{WorkbenchAuthException, InvalidCredentialsException,
  AccountDisabledException, RateLimitExceededException}.java`.
- `transport/WorkbenchHandshake.java`, `ResumeState.java`,
  `WorkbenchTransportException.java`, `WorkbenchTransportClient.java`.

### Tests
- **Python:** `python/tests/workbench/{test_auth.py,
  test_handshake.py, test_cross_language.py}` -- 37 tests, all pass.
- **Java:** `java/src/test/java/global/thalion/ttio/workbench/{TotpTest,
  WorkbenchHandshakeTest}.java`. Cross-language byte-equivalence is
  pinned via identical literal assertions in both suites.

## Acceptance criteria

From the W1 section of the workplan:

- [x] `ttio.workbench.transport.UploadClient` builds and is
      structurally importable. Unit-tested handshake + ack flow.
- [x] `ttio.workbench.transport.DownloadClient` with no filters
      builds and is structurally importable. Unit-tested handshake.
- [x] Same client with `filters={"ms_level":1, ...}` accepts the
      filter dict and surfaces unknown keys as `ValueError`
      client-side.
- [x] Resume after explicit close: `ResumeState` carries the
      `resume_handle` + `last_acked_au_sequence`; the client
      transmits both in the resume handshake.
- [x] Java cross-language equivalence: handshake JSON byte strings
      match the Python output (pinned via shared literals in both
      test suites); TOTP at the same epoch matches the Python
      output (deterministic test vectors in both suites).

## Deferred to W1 follow-up

- **Live daemon integration tests.** The W1 PR ships unit tests
  but no end-to-end test against a running `tti-workbench-server`
  binary. The Python smoke harness in
  `tti-workbench-server/Tests/load/{upload_one.py,download_one.py}`
  remains the de-facto live-daemon reference; replacing it with a
  vendored binary or runner-built daemon is a follow-up.
- **Resume from byte offset within an AU.** v1.0 resume is
  AU-granular (the server's `au_sequence` is the resume cursor).
  Mid-AU resume requires the server to support a finer-grained
  cursor; out of scope for v1.0.

## Next: W2

`ttio` CLI umbrella + Python SDK foundation. The W1 SDK objects
(`UploadClient`, `DownloadClient`, `Session`) become the
implementation of the CLI's `ttio upload` / `ttio download`
subcommands; the spec section 8.3 SDK shape
(`ttio.connect(...)`, `client.query(...)`, `client.stream(...)`)
wraps them in a more ergonomic top-level.
