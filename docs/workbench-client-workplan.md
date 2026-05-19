# TTI-O Workbench Client — workplan

Companion to [`TTI-O_Workbench_FunctionalSpec_v0.2.docx`](TTI-O_Workbench_FunctionalSpec_v0.2.docx).
Defines the **client-side** work needed to land the full client-server
architecture described in that spec on top of the already-released
[`tti-workbench-server` v1.0.0](https://github.com/DTW-Thalion/tti-workbench-server/releases/tag/v1.0.0).

The server side is done. This document scopes everything between the
existing TTI-O reference libraries and the spec's three client
surfaces: **WC Desktop GUI** (§8.1), **WC CLI** (§8.2), and **SDK /
Library API** (§8.3).

## Status going in (2026-05-19)

| Surface | What exists today | Gap to spec |
|---|---|---|
| **tti-workbench-server** | v1.0.0 released. REST control plane (`/v1/auth`, `/containers`, `/cohorts`, `/pipelines`, `/jobs`, `/sessions`) + WS data plane (`/transport`) + WS session proxy (`/v1/sessions/{id}/`) + `/metrics`. Auth via OAuth-shaped bearer tokens + TOTP. 1364/1364 unit + 3 daemon smokes. | Done. Server-side is the v1.0 target of [`tti-workbench-server`](https://github.com/DTW-Thalion/tti-workbench-server); the deferrals (ArangoDB, federation, PQC) are tracked in that repo's KNOWN-ISSUES. |
| **TTI-O Python** (`python/src/ttio/`) | `ttio.transport.{client,server,codec,packets,filters,ingest,walker}`; CLIs under `ttio.tools.*` covering encode / decode / server / per-AU / simulator / sign / verify / pqc. Speaks the **reference** transport protocol (no auth, no `container_uri`, no `project`/`owner` in the handshake). | No workbench-aware client. No `ttio` umbrella CLI per spec §8.2. No SDK surface matching §8.3 (`ttio.connect`, `client.query`, `client.stream`, `client.submit_pipeline`). |
| **TTI-O Java** (`java/src/main/java/global/thalion/ttio/`) | `transport.TransportClient` + `TransportServer` + `TransportWriter` + `TransportReader` + `TransportIngest`. Same reference-protocol target as the Python side. | No workbench-aware client; the Javadoc on `TransportClient` explicitly says "Connects to a Python reference server." |
| **TTI-O ObjC** (`objc/Source/`) | `TTIOTransportClient` + `TTIOTransportWriter` + `TTIOTransportReader` + `TTIOTransportIngest`. Reference-protocol. Consumed by `tti-workbench-server` to read uploads. | Not a client surface in the spec sense — ObjC is the server-side runtime. Stays as the server's HDF5 worker library; not extended for WC purposes. |
| **tio-browser** ([`DTW-Thalion/tio-browser`](https://github.com/DTW-Thalion/tio-browser)) | v1.4.0 — Java desktop app, JavaFX UI, bundled HDF5 1.14.6 + LZ4 for true out-of-box install. Browses local `.tio` files; no server connectivity. | The natural seed for **WC Desktop GUI** (§8.1). Needs every component in §8.1 except the local file browser (which already exists): connection manager, container browser against WS, encoding panel, upload/download manager, selective-access panel, cohort builder, pipeline launcher, job monitor, interactive-session launcher, export panel. |
| **`tti` / `ttio` CLI umbrella** | none | New. Spec §8.2 has a concrete CLI shape (`ttio encode`, `ttio upload --server`, `ttio download --server --filter`, `ttio stream`, `ttio export`). Likely lives under `python/src/ttio/tools/` as a top-level `ttio.tools.workbench_cli` that re-uses the existing format-specific CLIs. |

**Reference protocol vs. workbench protocol — concrete diff:**

| Field | Reference Python server | Workbench server v1.0.0 |
|---|---|---|
| WS endpoint URL | `ws://host:8443/` | `wss://host:8443/transport` (TLS required in prod) |
| Handshake auth | none | `{"token": "ttiowbs_..."}` JSON frame as first message |
| Handshake fields | `{"mode": "upload"|"download", ...}` | adds `"owner"`, `"project"`, `"container_uri"` (download) or auto-derives URI on upload |
| Resumable upload | partial (in-memory only) | full resumable via monotonic `au_sequence` per dataset; staging retained 24h |
| Selective access | filters in handshake | same; server evaluates against AU header before transmit |
| Errors | close-with-reason | close codes 1008 (auth) / 1011 (server) / 1000 (clean); plus 4xx on `/v1/auth/login` |

The **only** existing client code that already speaks the workbench
protocol is `tti-workbench-server`'s own `scripts/smoke_*` and
`Tests/load/upload_one.py` / `download_one.py` — built as bench
harnesses, not productionised. They are the de-facto reference of the
v1.0 wire contract; the client work below replaces them with a real
library + CLI + GUI surface.

## Phase plan (6 client milestones)

Cadence mirrors the server's S1–S9: kickoff prompt → phased PRs →
tests + docs per phase → cross-repo coordination notes →
KNOWN-ISSUES on each repo. Each phase is multi-repo: TTI-O for the
library / CLI / SDK, tio-browser for the GUI, occasionally
tti-workbench-server for contract clarifications.

| W# | Title | Estimated LOC | Touches | Spec UCs covered |
|---|---|---|---|---|
| **W1** | Workbench-aware transport client (Python + Java) | ~1,200 | TTI-O python + java | UC-01, UC-02, UC-04 (upload + download + filtered stream against v1.0 server) |
| **W2** | `ttio` CLI umbrella (Python only) + SDK foundation (Python + Java) | ~1,400 | TTI-O python + java | UC-01 → UC-05 CLI surface; SDK §8.3 base shape (`ttio.connect`, `.query`, `.stream`, `.materialize`); Java mirror under `global.thalion.ttio.workbench.WorkbenchClient` |
| **W3** | Cohort + pipeline + job client surface | ~1,100 | TTI-O python + java | UC-06, UC-07, UC-09, UC-10, UC-14 (cohort query → pipeline submit → job poll → result download) |
| **W4** | Interactive sessions client | ~700 | TTI-O python + java | UC-11 (session create → WS proxy attach → bytes round-trip → terminate) |
| **W5** | tio-browser → WC Desktop GUI evolution | ~3,000 | tio-browser + TTI-O java SDK | UC-01 → UC-14 GUI surface per spec §8.1 component list |
| **W6** | SDK polish + remaining formats + PQC + federation client | ~1,500 | TTI-O python + java + objc | §8.3 SDK finalisation; UC-03.2/3 BYOK + envelope + ENCRYPTED_HEADER; spec Phase 5 hardening; UC-13 longitudinal helpers |

Total estimated client-side LOC: ~8,400. Comparable to the
tti-workbench-server v1.0 build (about ~12k LOC across 8 milestones)
because the wire-format work, query AST, dispatcher, and crypto
primitives are already done on the server.

After each phase commits + merges, the user types `proceed to W<N+1>`
to advance. Phases are not strictly sequential — W5 (GUI) can begin in
parallel with W3/W4 once W2's SDK foundation lands, and W6 can begin
in parallel with W5 once W3 ships.

## Defaulted decisions

1. **WC CLI umbrella name: `ttio`**, matching spec §8.2 verbatim. Lives
   as a `console_scripts` entry in `python/pyproject.toml`. Existing
   format-specific CLIs (`fastq_export_cli`, `fasta_import_cli`,
   etc.) stay as importable modules but `ttio encode` becomes the
   discoverable front-door. The `ttio` command dispatches subcommands
   to the existing implementations to avoid reshipping format logic.

2. **Python + Java SDK ship in lockstep at every milestone.**
   *Amended 2026-05-19 after the W2 PR shipped Python-only.* Each
   W has both a Python (`ttio.workbench.*`) and Java
   (`global.thalion.ttio.workbench.*`) deliverable; cross-language
   byte-equivalence anchored via identical literal assertions in
   both test suites. The spec §8.3 sample is Python, but tio-browser
   (W5) and any non-tio-browser Java consumer needs the same
   ergonomic surface (`WorkbenchClient.connect()`, `*Auth` providers,
   placeholder methods for future Ws). ObjC stays server-runtime
   (`tti-workbench-server`'s HDF5 worker library) -- the workplan
   does NOT extend ObjC for client purposes. Rust SDK explicitly
   v1.2+ (spec §8.3 says "Python and/or Rust"; Rust deferred).

   *CLI exception*: the `ttio` umbrella console-script is
   Python-only (Decision 1). Java consumers drive the SDK directly
   from JVM code (tio-browser for v1.0; arbitrary Java callers for
   v1.1+). A Java CLI doesn't fit the v1.0 deployment model and
   would duplicate the Python `ttio`'s subcommand grammar without
   any new consumer.

3. **`ttio.workbench` is the new namespace.** Existing
   `ttio.transport.{client,server}` stay reference-protocol; new
   workbench-aware code lives under `ttio.workbench.{auth, transport,
   cohort, pipeline, jobs, sessions}`. Lets reference-protocol users
   stay on their current import paths and gives workbench users a
   dedicated entry point. The top-level `ttio.connect()` of spec §8.3
   wraps `ttio.workbench.connect`.

4. **Java workbench client lives at `global.thalion.ttio.workbench.*`**
   under the existing `java/src/main/java/global/thalion/ttio/`
   tree. Mirrors the Python layout. tio-browser depends on the
   existing TTI-O Maven artifact + the new workbench classes ship in
   the same artifact (no separate Maven coordinate in v1.0.x).

5. **WS handshake first-frame is JSON, second-frame onward is binary
   .tis** — already the workbench server's contract. The client's WS
   library (`websockets` in Python; `org.java_websocket` in Java —
   both already in use for the reference protocol) handles the
   transport. No protocol changes; W1 is purely additive client code.

6. **Auth flow: bootstrap-credentials → login → bearer in handshake.**
   v1.0 servers expose `POST /v1/auth/login` returning a session
   bearer. The client caches it in memory for the session lifetime;
   it does NOT write the token to disk (per spec §10.1 — disk caching
   is a v1+ feature when SSO/OIDC lands and refresh tokens are part
   of the model). The CLI accepts `--token` directly OR
   `--staging-root <path>` (bootstrap admin handoff) OR
   `--login <user>` (TOTP prompt). The smoke harness in the server
   repo uses the staging-root path; the CLI's primary path is
   `--login`.

7. **tio-browser stays a separate repo.** It depends on the TTI-O
   Java SDK and ships its own release cadence. The W5 work happens
   in `DTW-Thalion/tio-browser`; W5's TTI-O dependency lands first as
   a tagged TTI-O release, then tio-browser bumps. This mirrors the
   server's relationship to the TTI-O ObjC library (server pins
   to a tagged TTI-O release, never `main`).

8. **Selective-access filter UI lives in the GUI; CLI accepts
   `--filter k=v` repeatedly** matching the spec §8.2 sample
   commands verbatim. The SDK accepts a `filters: dict` per spec
   §8.3 sample. All three surfaces validate filters against the
   workbench server's known predicate set (rt_min, rt_max, ms_level,
   polarity, precursor_mz_min, precursor_mz_max, chromosome,
   position_min, position_max, dataset_id, max_au) before opening
   the WS — invalid filters fail client-side with a clear error
   rather than 400'ing at the server.

9. **No PQC on the client path for W1–W5.** The v1.0 server's
   ProtectionMetadata path is wired but BYOK / envelope / PQC are
   ENCRYPTION-OPTIONAL on the client (the server accepts streams
   without ProtectionMetadata for unencrypted containers). W6 adds
   PQC client support behind the `opt_pqc_preview` feature flag,
   matching the server's existing feature-flag gating.

10. **No interactive-session GUI surface in W4.** W4 ships the CLI +
    SDK + WS-proxy library calls so a researcher can `ttio
    session create` and get a `wss://` URL they paste into their
    own browser (e.g., a JupyterHub deployment). The full Jupyter-
    embedded-in-tio-browser surface (spec §7.4 step 3) is W5.

## W1 deliverable detail — Workbench-aware transport client

**Goal:** ship a `ttio.workbench.transport.{UploadClient, DownloadClient,
FilteredDownloadClient}` (Python) and the matching Java classes that
speak the v1.0 server's auth-aware handshake. Removes the
"reference-protocol-only" gap.

**Touches:** TTI-O python + java only. No GUI work. No CLI work
(W2 layers the CLI on top).

**Python deliverables:**

- `python/src/ttio/workbench/__init__.py` — namespace
- `python/src/ttio/workbench/auth.py` — `login()`, `current_totp()`,
  `Session` token holder
- `python/src/ttio/workbench/transport/__init__.py`
- `python/src/ttio/workbench/transport/handshake.py` — JSON
  first-frame builder + parser
- `python/src/ttio/workbench/transport/upload.py` —
  `UploadClient(host, port, token, owner, project, uri)` driving a
  `.tio` file or in-memory transport stream over the workbench WS
- `python/src/ttio/workbench/transport/download.py` —
  `DownloadClient(host, port, token, container_uri, filters=None)`
  reading a filtered `.tis` stream
- `python/src/ttio/workbench/transport/resume.py` — resume-from
  `au_sequence` per `dataset_id` per spec §5.2

**Java deliverables (`global.thalion.ttio.workbench.*`):**

- `auth/Session.java`, `auth/Login.java`, `auth/Totp.java`
- `transport/WorkbenchTransportClient.java` (upload + download in one
  class, mode-switched on construction)
- `transport/WorkbenchHandshake.java` — JSON first-frame builder
- `transport/ResumeState.java`

**Tests:**

- Python unit tests against the smoke harness's daemon recipe
  (mirrors `tti-workbench-server/scripts/smoke_jobs.sh`).
- Java tests via Testcontainers spinning up the workbench-server
  Docker image (operator builds the image once; the test suite caches
  it). Falls back to skipping if the image isn't reachable.
- One cross-language equivalence test: same upload payload via
  Python and Java clients produces byte-identical `.tio` on the
  server. Probably lives in `python/tests/integration/` since CI
  already has a Python smoke pattern.

**Acceptance:**

- [ ] `ttio.workbench.transport.UploadClient` uploads a 1 MB
      synthesised `.tis` against a fresh `tti-workbench-server` daemon,
      receives the registration ack, and the container appears in
      `GET /v1/containers`.
- [ ] `ttio.workbench.transport.DownloadClient` with no filters
      retrieves a previously uploaded container's bytes.
- [ ] Same client with `filters={"chromosome": "chr6",
      "position_min": 28_000_000, "position_max": 34_000_000}` retrieves
      only matching AUs (verify via AU count delta).
- [ ] Resume after explicit WS close re-opens, replays the resume
      request, and continues from the last acked `au_sequence`.
- [ ] Java cross-language test produces the same `.tio` byte stream
      as Python for the same input.

## W2 deliverable detail — `ttio` CLI umbrella + Python SDK

**Goal:** spec §8.2's exact CLI shape, plus the §8.3 SDK base
(`ttio.connect`, `client.query`, `client.stream`, `stream.materialize`).
CLI is a thin layer on the SDK; the SDK is a thin layer on W1's
transport classes.

**Touches:** TTI-O python only.

**CLI deliverables:**

- `python/src/ttio/tools/workbench_cli.py` — argparse-based dispatcher
  for `ttio {encode, upload, download, stream, export, login, query,
  submit, jobs, sessions, inspect}` subcommands
- `python/pyproject.toml` — `[project.scripts] ttio =
  "ttio.tools.workbench_cli:main"`
- Existing format-specific CLIs become subcommand backends:
  `ttio encode` dispatches to `ttio.tools.fastq_import_cli` /
  `fasta_import_cli` based on the input file's detected format
  (per spec §5.1).

**SDK deliverables:**

- `python/src/ttio/workbench/client.py` — top-level `connect()`
  factory returning a `WorkbenchClient` holding auth + connection
  pool
- `python/src/ttio/workbench/cohort.py` — `client.query()` →
  `CohortResult` with `.subjects`, `.containers`, `.layers(...)`,
  `.save(name)` (POST /v1/cohorts)
- `python/src/ttio/workbench/sessions.py` — placeholder for W4
- `python/src/ttio/workbench/pipeline.py` — placeholder for W3
- `python/src/ttio/__init__.py` — re-export `connect`, `OIDCAuth`,
  `PasswordTotpAuth` at the top level to match spec §8.3's
  `ttio.connect(...)` shape

**Tests:**

- CLI smoke: `ttio --version`, `ttio encode --help`, end-to-end
  `ttio encode → ttio upload → ttio download --filter ms_level=2`
  round-trip against a daemon.
- SDK unit + integration: mirror the spec §8.3 example verbatim
  (`client.query(...).layers(...).submit_pipeline(...)`).

**Acceptance:**

- [ ] Every `ttio` subcommand listed in spec §8.2 has a working
      implementation.
- [ ] `python -c "import ttio; ttio.connect(...)"` returns a
      working client.
- [ ] One end-to-end notebook in `python/docs/` walks through
      "ingest a FASTQ, upload, query metadata, download a filtered
      slice".

## W3 deliverable detail — Cohort + pipeline + job client

**Goal:** spec §6.2 (cohort), §7.2 (pipeline execution), §7.3
(batch), §7.7 (provenance) on the client side. Pipelines and
provenance are server-defined; the client surfaces them in CLI
and SDK form.

**Touches:** TTI-O python + java.

**Python deliverables:**

- `python/src/ttio/workbench/cohort.py` — query builder mirroring
  the server's JSON cohort-query AST (TTI-O server's
  `TTIOWBCohortQuery` shape). Supports predicate composition
  (AND/OR/NOT), phenotypic filters, assay-availability filters,
  cohort-membership filters per spec §6.2.
- `python/src/ttio/workbench/pipeline.py` — `client.submit_pipeline(
  pipeline, inputs, params)` returning a `Job` handle.
- `python/src/ttio/workbench/jobs.py` — `Job.wait()`, `Job.cancel()`,
  `Job.status()`, `Job.events_sse()` long-poll, `Job.output_container()`.
- `python/src/ttio/workbench/provenance.py` — `Container.provenance()`
  returning a W3C PROV-compatible DAG (spec §7.7).

**CLI deliverables:**

- `ttio query --where 'diagnosis="AD" AND has_layer(variants)'`
- `ttio submit --pipeline eqtl-analysis --cohort cohort_2026Q2
  --param p_threshold=1e-5`
- `ttio jobs ls`, `ttio jobs status <id>`, `ttio jobs cancel <id>`,
  `ttio jobs events <id>` (tail SSE)
- `ttio provenance <container_uri>` — pretty-prints the PROV chain

**Java deliverables:**

- `workbench/cohort/CohortQuery.java` + `CohortResult.java`
- `workbench/pipeline/PipelineClient.java` + `Job.java`
- `workbench/provenance/ProvenanceChain.java`

**Acceptance:**

- [ ] `ttio query ... | ttio submit -` end-to-end submits a job
      against the daemon's built-in shell engine.
- [ ] `ttio jobs events <id>` streams SSE state transitions and
      terminates when the job hits a terminal state.
- [ ] Provenance DAG round-trips: a job that produces a derived
      container reports the input container in
      `ttio provenance <derived_uri>`.

## W4 deliverable detail — Interactive sessions client

**Goal:** spec §7.4 (UC-11) on the client side. Researcher does
`ttio session create --engine shell --command bash` and gets back
a `wss://` URL they can attach to (today via the smoke harness's
WS-proxy library calls; in W5 the GUI embeds the proxy directly).

**Touches:** TTI-O python + java.

**Python deliverables:**

- `python/src/ttio/workbench/sessions.py` — `client.session_create(
  engine, command, env, bind_mounts, project)` returning a
  `Session` handle with `.attach_url`, `.terminate()`, `.last_seen_at`.
- `python/src/ttio/workbench/session_proxy.py` — WS proxy attach
  helper (`SessionProxy.attach(token)`) that opens the
  `/v1/sessions/{id}/` WS and pumps stdin/stdout against a
  user-supplied byte-stream pair. Mirrors the server's
  `TTIOWBSessionProxy` attach/authorize/ring-buffer shape.

**CLI deliverables:**

- `ttio session create --engine shell --command bash --bind-mount
  /data:ro`
- `ttio session ls`, `ttio session attach <id>` (interactive
  terminal in the current TTY using the proxy lib)
- `ttio session terminate <id>`

**Java deliverables:**

- `workbench/sessions/SessionClient.java`
- `workbench/sessions/SessionProxy.java` (WS proxy attach helper)

**Acceptance:**

- [ ] `ttio session create --engine shell --command "echo hello;
      sleep 60" --project test` returns a session id that appears
      in `GET /v1/sessions`.
- [ ] `ttio session attach <id>` proxies stdin to the session's
      bash and prints its stdout in real time.
- [ ] `ttio session terminate <id>` transitions the session to
      `terminating` then `terminated` within the configured
      cancel-grace window.

## W5 deliverable detail — tio-browser → WC Desktop GUI

**Goal:** spec §8.1's complete component list, evolving the
existing tio-browser into the workbench GUI. Lives in the
[`tio-browser/`](../tio-browser) subdirectory of TTI-O — *not* a
separate repo. The TTI-O Java module (`java/`) ships the SDK that
tio-browser depends on (W1 + W3 + W4 Java deliverables); the
W5.0 kickoff bumps `java/pom.xml` to v1.3.0 and
`tio-browser/pom.xml`'s `<ttio.version>` in lockstep so the new
panels can `import global.thalion.ttio.workbench.*`.

**Touches:** `tio-browser/` and `java/` (for any SDK gaps surfaced
during integration); single-repo, no cross-repo coordination.

**Phasing:** spelt out in [`docs/workbench-client/W5-plan.md`](workbench-client/W5-plan.md)
— W5.0 kickoff (this PR: version bumps + plan), W5.1–W5.7 each
deliver one or two of the spec §8.1 components plus a smoke
test at W5.7.

**New tio-browser components:**

- **Connection Manager** — server URL, login flow, mTLS upload,
  session-token cache (in-memory only per Decision 6), WS
  connection health indicator
- **Container Browser** — tree view of `GET /v1/containers` with
  filtering, sort, per-container manifest drill-down. Replaces
  the existing local-only file browser with a dual-source tree
  (local files + workbench server)
- **Encoding Panel** — per spec §8.1: source file selection,
  format detection, codec selection, compression level, per-layer
  annotation, reference-genome picker
- **Upload/Download Manager** — queue with progress bars,
  pause/resume, per-AU throughput, resumable-upload state
- **Selective Access Panel** — visual filter builder per spec
  §8.1: RT range, MS level, polarity, precursor m/z, chromosome,
  position range, max AU
- **Cohort Query Builder** — predicate-composition UI (AND/OR/NOT),
  saved queries, result-set viewer
- **Pipeline Launcher** — pipeline picker, input binding, parameter
  form (driven by the server's pipeline definition schema)
- **Job Monitor** — dashboard of active / queued / completed jobs
  with SSE-live status updates
- **Interactive Session Launcher** — environment picker, resource
  allocator, embedded notebook iframe (proxies through the API
  Gateway per spec §7.4 step 3)
- **Export Panel** — layer picker, target format picker, server-
  side vs. client-side export choice, progress

**Tests:**

- JavaFX TestFX coverage for each panel (existing pattern in
  tio-browser).
- One end-to-end smoke spinning up a workbench-server Docker image
  and driving the GUI through a representative workflow:
  login → browse containers → upload one → submit a pipeline →
  observe job → download result.

**Acceptance:**

- [ ] Every component in spec §8.1 has a working tio-browser
      panel.
- [ ] One operator can complete UC-01 → UC-04 → UC-07 → UC-09 →
      UC-04 (encode → upload → query → submit → download result)
      entirely in the GUI.

**Dependency note (single-repo):** `tio-browser/pom.xml`'s
`<ttio.version>` property tracks the `java/` module's version. The
W5.0 kickoff bumps both 1.2.0 → 1.3.0; the new
`global.thalion.ttio.workbench.*` classes ship in the same artifact
(workplan Decision 4). Local builds require
`cd java && mvn install -DskipTests -Djacoco.skip=true` so the new
1.3.0 artifact is in `~/.m2` before `cd tio-browser && mvn test`
runs.

## W6 deliverable detail — SDK polish + remaining formats + PQC

**Goal:** close the spec's Phase 5 (Production Hardening) on the
client side. Brings the SDK to release-quality, adds the format
support deferred in W1 (genomics + clinical were enough for W1; W6
adds transcriptomics, epigenomics, proteomics, metabolomics,
imaging per spec §4.2–4.7), wires PQC and BYOK envelope encryption,
and ships the SDK reference docs.

**Touches:** TTI-O python + java + (lightly) objc.

**Python + Java deliverables:**

- Format expansion: importers/exporters for every entry in spec
  §4.2–4.7. Many already exist as TTI-O codecs; W6 wires them into
  `ttio encode --format <fmt>` and into the GUI's encoding panel.
- `python/src/ttio/workbench/encryption.py` — BYOK (researcher
  provides a public key; client builds ProtectionMetadata),
  envelope (both server KEK and researcher key wrap the DEK),
  ENCRYPTED + ENCRYPTED_HEADER mode (full end-to-end).
- `python/src/ttio/workbench/pqc.py` — ML-KEM-1024 + ML-DSA-87
  via the existing `ttio.pqc` module's pyoqs wrapper, gated by
  `opt_pqc_preview` feature flag in the StreamHeader.
- Federation client: `client.connect(host)` learns about peer
  workbench instances via a `/v1/federation/peers` endpoint
  (spec §12.3 Federated mode; server-side scope is v1.1, but the
  client surface can ship first and gracefully no-op against
  v1.0 servers).

**Rust SDK:** deferred to v1.2 (no v1 commitment per Decision 2).

**Tests + docs:**

- SDK reference (Sphinx for Python, Javadoc for Java) auto-built
  in CI; published to `gh-pages` or to a docs site.
- Tutorial notebook: spec §8.3 example expanded into a runnable
  Jupyter notebook in `python/docs/tutorials/`.
- Format-roundtrip tests per spec §4 entry.

**Acceptance:**

- [ ] Every format in spec §4 has a working
      `ttio encode --format <fmt>` path.
- [ ] BYOK round-trip: client encrypts with researcher key →
      uploads → re-downloads → decrypts with the same key →
      bytes match.
- [ ] PQC round-trip with `opt_pqc_preview` enabled.
- [ ] SDK docs site builds in CI.

## Cross-repo coordination

This is a 3-repo programme. Coordination notes:

- **TTI-O ↔ tti-workbench-server:** the wire contract is whatever
  the v1.0 server expects. Workbench-server v1.0.0 is now the
  reference; client work conforms to its handshake, REST endpoints,
  SSE format, and audit-event shape. Any contract clarifications
  needed by the client go into `tti-workbench-server`'s
  `Documentation/*.md` as patch-release work; the client doesn't
  change the wire.

- **TTI-O → tio-browser:** TTI-O is the dependency, tio-browser is
  the consumer. The W1/W3/W4 Java SDK lands first; tio-browser bumps
  its dependency to that TTI-O release before W5 work begins.

- **tio-browser ↔ tti-workbench-server:** zero direct relationship.
  All comms go through the TTI-O SDK. This is intentional —
  swapping the server (or swapping the client) is a TTI-O SDK
  version bump, not a Pythagorean coupling.

- **Release tagging:** the TTI-O Java artifact gets a tagged
  release per W1, W3, W4 (so tio-browser can pin to a stable
  TTI-O release at the start of W5). Python package gets a
  PyPI release at the same cadence (`ttio==1.3.0`).

## Implementation phase mapping (spec §13 → workplan)

| Spec phase | Months | Server status | Client milestones |
|---|---|---|---|
| Phase 1: Core Data Management | 1–4 | done in `tti-workbench-server` S1+S2 | **W1, W2** |
| Phase 2: Biobank and Query | 3–6 | done in S6 | **W3 (cohort+pipeline+job slice)** |
| Phase 3: Compute Engine | 5–9 | done in S7 | **W3 (pipeline+job slice continued)** |
| Phase 4: Advanced Analysis | 8–12 | done in S8 | **W4, W5** |
| Phase 5: Production Hardening | 10–14 | done in S9 | **W6** |

Months 1–4 of the spec's timeline map onto W1+W2; the GUI track
(W5) and PQC track (W6) reach into Months 10–14 alongside the
server's Phase 5 production hardening work.

## Open questions

1. **Rust SDK:** spec §8.3 says "Python and/or Rust SDK". Default
   is Python-only for v1.x. If a Rust client materialises as a
   priority (e.g., embedded inside a CLI-first tool that doesn't
   want a Python runtime), it becomes W7 and ships against the same
   wire contract.

2. **JupyterHub-embedded interactive session (spec §7.4 step 3).**
   Two implementation choices: (a) tio-browser embeds the Jupyter
   HTML in a JavaFX WebView; (b) tio-browser opens the Jupyter URL
   in the operator's system browser. (a) is more integrated; (b) is
   more robust and Jupyter-version-agnostic. W5 likely lands (b),
   defers (a) to a tio-browser follow-up. Track as a tio-browser
   issue, not in TTI-O.

3. **Federation client behaviour on v1.0 servers.** Spec §12.3
   marks federation as a future extension. v1.0 server-side stays
   single-node. W6's federation client should detect the absence of
   `/v1/federation/peers` and gracefully treat the connection as
   single-node — not error out. Worth a unit test.

4. **CLI authentication scopes.** Spec §10.1 mentions OIDC as
   primary and password+TOTP as fallback. v1.0 server-side
   ships password+TOTP only (OIDC is v1.1+). The CLI's `ttio login`
   surface is built around the v1.0 reality (password+TOTP); the
   OIDC pluggable point (`OIDCAuth()` per spec §8.3) is stubbed for
   v1.0 and wired against the server's eventual OIDC endpoint in
   v1.1.

5. **Selective access for genomic codec v2 blobs (bulk mode).**
   The workbench server supports
   `bulk_mode_v2_blobs` feature flag for byte-identical genomic
   transport. The client's W1 download path should request bulk
   mode when receiving a container with v2 codecs and the user
   hasn't asked for filtering — saves a re-encode round-trip.
   Default ON for unfiltered downloads, default OFF for filtered
   downloads (selective access needs decoded headers).

6. **CLI configuration file.** Spec §8.2 sample commands repeat
   `--server wss://biobank.thalion.org/transport` on every
   invocation. A `~/.ttio/config.toml` with a default server URL
   would be ergonomic. Defer to W2 — not load-bearing for any
   acceptance criterion.

## Out of scope (v1.x client)

- **Web client (browser-based SPA).** The spec's "WC" terminology
  refers to the desktop GUI and CLI only. A browser-based front-end
  is a v2 concern.

- **Mobile clients.** Not in the spec.

- **Direct sequencer integration (UC live ingestion).** Spec §14
  open question 3 calls this out as a future consideration.
  v1.x client emits batch streams; live `expected_au_count = 0`
  ingestion ships when an instrument vendor partner integration
  drives the requirement.

- **Cost accounting client surfaces (spec §14 open question 7).**
  Server-side audit log captures the data; UI for charge-back
  reporting is a v2 admin concern.

---

**Status:** workplan v0.1, drafted 2026-05-19 against
`TTI-O_Workbench_FunctionalSpec_v0.2.docx`. Awaiting kickoff
approval before W1 work begins.
