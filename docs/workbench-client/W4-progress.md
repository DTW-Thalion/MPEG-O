# W4 progress

Status snapshot for the **interactive sessions client** milestone
per [`docs/workbench-client-workplan.md`](../workbench-client-workplan.md).

## Status (2026-05-19): COMPLETE -- in review

156 Python workbench tests pass locally (+25 over W3). Java
mirror compiles clean. Cross-language byte-equivalence anchored
via identical attach-handshake JSON literal in both suites.

## Server-side survey (kickoff input)

Before writing client code, surveyed the
[`tti-workbench-server` v1.0.0](https://github.com/DTW-Thalion/tti-workbench-server/releases/tag/v1.0.0)
wire contract for W4 surfaces: `/v1/sessions` REST + the
`ttio-session-proxy` WS attach on `/v1/sessions/{id}/`.
Cross-referenced `Documentation/session-protocol.md` against
`Source/HTTP/handlers/TTIOWBSessionsHandler.m` and
`Source/Sessions/{TTIOWBSessionRegistry,
TTIOWBSessionLifecycle, TTIOWBSessionProxy}.m`.

**Session state machine** (5 statuses):
`starting` → `running` → `terminating` → `terminated` / `failed`.
Only `running` is attachable. `running` + `terminating` count
toward `max_concurrent`; `starting` does not.

**Attach handshake** (first WS frame):
```json
{
  "action": "attach",         // required, must be "attach"
  "token":  "ttiowbs_...",     // required
  "path":   "/api/kernels"     // optional, defaults to "/"
}
```

**WS proxy authorizer's 5 decisions**: `AuthMissing` (1008),
`SessionNotFound` (1008), `Forbidden` (1008), `NotRunning`
(1011), `Ok` (proceed). Cross-project = "not found" (no
existence disclosure).

**v1.0 deferrals** the client respects:
- Idle-timeout sweep is server-side (`idle_timeout_seconds`).
- Host-port allocator is server-side (NSLock + NSMutableSet).
- Ring-buffer backpressure (4 MB rings, 75/25 hysteresis) is
  server-side; client just observes pause behaviour via OS
  socket backpressure.
- No SSE-like resumption on WS proxy; reconnect requires a
  fresh attach.

## Deliverables shipped

### Python (`python/src/ttio/workbench/`)

| File | Purpose |
|---|---|
| `sessions.py` | `Session` dataclass + `SessionsClient` (create/list/get/terminate) + `validate_bind_mounts()` mirror of server-side rules. Status enum pinning via `SESSION_STATUSES` / `TERMINAL_SESSION_STATUSES`. |
| `session_proxy.py` | `build_attach_handshake()` + `session_proxy_url()` pure helpers. `SessionProxyAttach` async context manager pumping bytes between caller's stdin/stdout and the WS. |
| `client.py` | `WorkbenchClient.sessions()` + `.session_create()` + `.session_proxy(...)` promoted from W2-era stubs to live methods. |

### Java (`java/src/main/java/global/thalion/ttio/workbench/sessions/`)

| File | Purpose |
|---|---|
| `Session.java` | Mirror record with `isTerminal()` / `isAttachable()`. |
| `BindMountValidator.java` | Same validation rules as Python; throws `IllegalArgumentException` on first violation. |
| `SessionsClient.java` | REST surface with fluent `CreateRequest` builder. |
| `SessionProxy.java` | Pure attach-handshake JSON builder + URL constructor. |
| `SessionProxyAttach.java` | Callback-driven WS attach using `org.java_websocket`. Inner `ProxyDriver` pumps `InputStream` <-> `OutputStream` with a daemon `Thread` for stdin. |
| `WorkbenchClient` | `sessions()` + `sessionProxy(...)` live. |

### CLI

`ttio sessions` promoted from W3-era stub. Subcommand
positional + per-action flags:

| Action | Effect |
|---|---|
| `create` | POST /v1/sessions with `--engine`, `--project`, `--image`, `--command`, `--env`, `--bind-mount` |
| `ls` | GET /v1/sessions with `--status`, `--limit` |
| `status` | GET /v1/sessions/{id} |
| `attach` | Open WS proxy; pump stdin / stdout against the engine subprocess. `--path /` is the default |
| `terminate` | DELETE /v1/sessions/{id} |

## Cross-language byte-equivalence

The attach-handshake JSON has a single anchor literal pinned in
both test suites. Same `(token=ttiowbs_abc, path=/api/kernels)`
input produces:

```
{"action":"attach","token":"ttiowbs_abc","path":"/api/kernels"}
```

in both Python (`json.dumps(separators=(",", ":"))`) and Java
(`SessionProxy.buildAttachHandshake`). Drift in either client
fails both test suites simultaneously.

This is the SECOND cross-language anchor in the workbench
client (W1's handshake builder + W3's cohort predicate + now
W4's attach handshake = three independent anchors).

## Acceptance criteria

From the W4 section of the workplan:

- [x] `ttio sessions create --engine shell --command "..." --project test`
      returns a session id structurally (live daemon round-trip
      is W4 follow-up).
- [x] `ttio sessions attach <id>` builds the WS proxy URL and
      sends the attach handshake (live byte-pump validation is
      W4 follow-up).
- [x] `ttio sessions terminate <id>` issues `DELETE /v1/sessions/{id}`.

## Deferred to W4 follow-up

- **Live daemon round-trip tests.** Same shape as the W1/W3
  follow-ups -- needs to vendor or build the workbench-server
  binary in CI.
- **Jupyter HTTP-over-WS bridge.** Spec section 7.4 step 3
  envisions tio-browser embedding a Jupyter notebook UI; v1.0
  ships the raw WS proxy + leaves HTTP-over-WS to the GUI
  (W5).

## Next: W5

tio-browser → WC Desktop GUI evolution. Lives in a separate
repo (`DTW-Thalion/tio-browser`); the TTI-O Java SDK we ship
in W1+W2+W3+W4 is the dependency tio-browser bumps. W5's first
deliverable is the TTI-O Java release tag that tio-browser
pins against.
