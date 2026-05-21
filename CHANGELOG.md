# CHANGELOG

All notable changes to the TTI-O multi-omics data standard reference
implementation.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
Versioning follows [Semantic Versioning](https://semver.org/); the
public API is stable from onward.

---

## [Unreleased]

### Added -- workbench client per-AU encrypted upload/download, PQC variant (2026-05-21)

Phase 3 of the per-AU encrypted-upload rework: the post-quantum
(ML-KEM-1024) variant, gated behind `opt_pqc_preview` (Python + Java
lockstep, Decision 2). Unlike BYOK (Phases 1-2, caller-held key), the
per-run DEK is randomly generated, ML-KEM-wrapped into the
`ProtectionMetadata` packet, and recoverable only with the recipient's
ML-KEM private key — the daemon never holds a key.

- Python `WorkbenchClient.upload_encrypted_pqc(*, project,
  container_uri, tio_path, recipient_public_key, preview,
  encrypt_headers=False)` / `download_decrypted_pqc(*, container_uri,
  recipient_private_key, out_tio_path, preview)`. Java
  `WorkbenchClient.uploadEncryptedPqc(...)` /
  `downloadDecryptedPqc(...)`. All four refuse unless `preview` is set
  (`PQCPreviewDisabledError` / `PqcPreviewDisabledException`), mirroring
  the server's `opt_pqc_preview`.
- New transport helpers stamp/read the wrapped DEK on a run's
  `signal_channels` so `write_encrypted_dataset` carries it and the
  receiver can unwrap it: Python
  `transport.encrypted.stamp_transport_wrapped_dek` /
  `read_transport_wrapped_dek`; Java
  `EncryptedTransport.stampTransportWrappedDek` /
  `readTransportWrappedDek`. The wrapped DEK is stored as a `uint8`
  attribute array (not a VLEN string) so the v1.2 / ML-KEM blob's
  embedded NULs survive the round-trip.

Validated end-to-end against a live daemon (Python
`test_per_au_encrypted_pqc_upload_round_trip`, Java
`perAuEncryptedPqcUploadRoundTrip`: ML-KEM-wrapped encrypt → upload →
download → unwrap → decrypt → channel data matches; the un-previewed
call refuses and the wrong private key fails to decrypt).

### Added -- workbench client per-AU encrypted upload/download (Java) (2026-05-21)

Phase 2 of the per-AU encrypted-upload rework: the Java mirror of the
Python Phase 1 client (lockstep, Decision 2).

- `WorkbenchClient.uploadEncrypted(project, containerUri, tioPath, key,
  encryptHeaders)` — encrypts a *copy* of the plaintext `.tio` per-AU
  (`PerAUFile.encryptFile`) into a valid `.tis`
  (`EncryptedTransport.writeEncryptedDataset` via a
  `ByteArrayOutputStream` `TransportWriter`) and uploads it. The source
  is not mutated; the daemon stores/serves it opaque (server #31).
- `WorkbenchClient.downloadDecrypted(containerUri, key, outTioPath)` —
  downloads, `readEncryptedToPath` materialises the still-encrypted
  `.tio`, and returns `PerAUFile.decryptFile(...)` channels per run.
- The blob `uploadProtected` / `downloadAndOpen` (W6.2) now throw
  `UnsupportedOperationException` pointing to the per-AU methods.

Validated end-to-end against a live daemon
(`WorkbenchLiveTest.perAuEncryptedUploadRoundTrip`: encrypt → upload →
download → decrypt → channel bytes match the plaintext source).

### Added -- workbench client per-AU encrypted upload/download (Python) (2026-05-21)

Phase 1 of the per-AU encrypted-upload rework (replaces the
daemon-incompatible W6.2 blob BYOK).

- `WorkbenchClient.upload_encrypted(*, project, container_uri,
  tio_path, key, encrypt_headers=False)` — encrypts a *copy* of the
  plaintext `.tio` per-AU (AES-256-GCM, channel payloads + optional AU
  headers) into a valid `.tis` carrying a `ProtectionMetadata` packet,
  and uploads it. The daemon stores/serves it opaque (server #31); it
  never sees plaintext or holds a key.
- `WorkbenchClient.download_decrypted(*, container_uri, key,
  out_tio_path)` — downloads the encrypted container, materialises the
  still-encrypted `.tio`, and returns the decrypted channels
  (`{run: {channel: ndarray}}`).
- The blob-level `upload_protected` / `download_and_open` (W6.2) now
  raise `NotImplementedError` with a pointer to the per-AU methods:
  sealing a whole payload into one opaque ciphertext blob is rejected
  by the daemon (it validates uploads as transport streams).

Validated end-to-end against a live daemon
(`test_per_au_encrypted_upload_round_trip`: encrypt → upload → download
→ decrypt → channel values match). Java mirror + PQC variant follow.

### Fixed -- workbench upload ack-drain on websockets >= 14 (2026-05-20)

`UploadClient._drain_acks` read `self._ws.messages`, a deque the
`websockets` >= 14 asyncio `ClientConnection` no longer exposes, so
**every** live upload crashed with `AttributeError`. No live test had
exercised `upload_bytes` against a real daemon, so this went uncaught.
Rewritten to a cancel-safe non-blocking `recv()` drain (acks are still
fully processed by `_wait_for_done`).

Added a valid-`.tis` upload -> ingest -> download -> decode round-trip
to the `workbench-live` smoke (the first upload/download e2e there;
9/9 against a local daemon). This also documents -- via
`docs/parity-audit-v1.0.md` 3.2 -- that **W6.2 blob-level BYOK is not
daemon-compatible**: the daemon validates uploads as transport streams
(rejects opaque ciphertext) and re-encodes on download, so encrypted
upload must use per-AU encryption yielding a valid `.tis`. That rework
is the real W6.2 follow-up.

### Added -- W6.6: SDK reference docs + quickstart + finalisation (2026-05-20)

Closes **W6** (the final workbench-client milestone) — W1–W6 ship a
complete client SDK (Python + Java), the tio-browser GUI, the CLI,
and now reference docs.

- **Sphinx** (Python) already autoapi-covers the whole `ttio`
  package; added a `workbench` landing link + a **quickstart
  notebook** (`python/docs/tutorials/workbench_quickstart.ipynb`)
  rendered via `myst-nb` (execution off — the live flow is verified
  by the `workbench-live` smoke, not the docs build). The notebook
  walks the spec §8.3 path: connect → encode → upload → query →
  submit a pipeline → download, plus the federation no-op.
- **Javadoc** for the Java SDK (the `maven-javadoc-plugin` was
  configured but never run in CI).
- New **`docs` CI workflow** builds both (Sphinx + Javadoc) on PRs
  touching the SDK or docs, so doc-breaking changes are caught.

### Added -- W6.5: federation client (graceful no-op vs v1.0) (2026-05-20)

Client surface for the v1.1+ federation endpoint (spec §12.3) that
degrades gracefully against a v1.0 single-node server.

- New `ttio.workbench.federation.FederationClient` (Python) /
  `global.thalion.ttio.workbench.federation.FederationClient` (Java),
  reached via `client.federation()`.
- `peers()` hits `GET /v1/federation/peers`; on **404** (the v1.0
  server doesn't expose it) it returns an **empty list** instead of
  raising, so callers never special-case version detection. Other
  non-2xx statuses still raise. `is_federated()` / `isFederated()`
  is a convenience over an empty peer list.

Tested both languages incl. the 404→empty contract (Java via a
local `HttpServer` stub).

### Added -- W6.4b: ttio export --format expansion (2026-05-20)

Export-side mirror of W6.4a: `ttio export --format` graduates from
the `fastq | fasta` stub to the dataset-level exporters.

- New `ttio.exporters.registry` (mirrors `ttio.importers.registry`).
  Each format wraps its exporter in a uniform
  `adapter(tio_path, layer, output, **opts)`:
  - mzML / mzTab / ISA-Tab/JSON (whole-dataset writers),
  - BAM / CRAM (genomic-run writers; samtools at runtime; CRAM needs
    `--extra --reference <fasta>`).
- `fasta` / `fastq` keep their dedicated CLIs.
- Unknown formats fail with rc 3 and a clear message.

Parity: a test pins the GUI export writers against the CLI's. The
documented gaps are **nmrML / JCAMP-DX / imzML** -- those export
from per-spectrum / per-pixel objects and the Python side has no
`.tio`-layer→object extraction helper yet (GUI/Java only).

### Added -- ExportPanel progress bar (2026-05-20)

The tio-browser "Export container" dialog now shows a progress bar
during the open→export run instead of only a static status label,
mirroring the W6.1b EncodingPanel. The bar is indeterminate (the
open/export tasks don't report granular progress) but distinguishes
working from hung. Closes the last surface noted in #113 (a local
`.tio`→file export, not a client-server interaction).

### Added -- W6.3: PQC client (ML-KEM-1024 + ML-DSA-87, opt_pqc_preview) (2026-05-20)

Post-quantum payload protection on the workbench client, gated
behind the `opt_pqc_preview` flag (spec Decision 9), built on the
W6.2 envelope path + core `ttio.pqc` / `PostQuantumCrypto`.

- New `ttio.workbench.pqc` (Python) /
  `global.thalion.ttio.workbench.pqc` (Java):
  - `seal_pqc` / `open_pqc` -- envelope whose DEK is wrapped under an
    **ML-KEM-1024** encapsulation key; the recipient decapsulates
    with the matching private key.
  - Optional **ML-DSA-87** signing of the sealed ciphertext; the
    signer key + algorithm land in `ProtectionMetadata`, the
    detached signature rides alongside. `verify_pqc` checks it.
  - `kem_keygen` / `sig_keygen` passthroughs.
  - Every entry point refuses unless `preview=True`
    (`PQCPreviewDisabledError` / `PqcPreviewDisabledException`),
    mirroring the server's `opt_pqc_preview` gating.
- Fix: the W6.2 Java `WorkbenchEncryptor.openSealed` now dispatches
  unwrap on `kekAlgorithm` (the 2-arg `unwrapKey` only handled
  AES-256-GCM), so ML-KEM envelopes unwrap. Mirrors the Python
  `open_sealed`, which already passed the algorithm through.

Cross-language: the PQC-envelope `ProtectionMetadata` shape
(`kek_algorithm="ml-kem-1024"` / `signature_algorithm="ml-dsa-87"`)
is byte-identical across languages (matching anchor literals).
Round-trips are unit-level; live-daemon variant deferred. Tests:
`test_pqc.py` (6, crypto cases skip without liboqs),
`WorkbenchPqcTest` (6).

### Added -- W6.2: BYOK + envelope encryption client (Python + Java) (2026-05-20)

Client-side payload protection for encrypted workbench uploads
(spec UC-03.2/3), a thin wrapper over the existing core crypto
(`ttio.encryption` / `EncryptionManager` + the v1.2 DEK wrap).

- New `ttio.workbench.encryption` (Python) /
  `global.thalion.ttio.workbench.encryption` (Java):
  - `ProtectionMode` (BYOK / ENVELOPE).
  - `seal(payload, ...)` / `open_sealed(...)` -- **BYOK** seals under
    a researcher-supplied 32-byte DEK (key never leaves the client;
    empty `wrapped_dek`); **ENVELOPE** generates a fresh DEK, seals,
    and wraps the DEK under a KEK via the shared v1.2 wrap. Framing
    is `iv(12) || tag(16) || ciphertext` in both languages.
  - `ProtectionMetadata` with a canonical `to_json` / `from_json`
    (sorted keys, compact separators, standard base64) -- the
    cross-language anchor.
- `WorkbenchClient.upload_protected` / `download_and_open` (Python)
  and `uploadProtected` / `downloadAndOpen` (Java) seal-then-upload
  and download-then-decrypt, returning/consuming the
  `ProtectionMetadata`.

Cross-language: the BYOK `ProtectionMetadata` JSON is byte-identical
across Python and Java (anchored by matching test literals).
Round-trips are unit-level (BYOK + envelope); the live-daemon
variant is deferred. Tests: `test_encryption.py` (9),
`WorkbenchEncryptionTest` (8).

### Added -- W6.1b: tio-browser determinate transfer progress (2026-05-20)

Second slice of W6.1: wires the W6.1a `TransferProgress` callback
through the GUI so a running upload shows a real percentage
instead of an indeterminate spinner (the gap that made the
`whale_sequences` upload look hung).

- `WorkbenchClient` gains progress-bearing `upload` / `download`
  facade overloads delegating to the transport client.
- `TransferManager` passes a coalesced progress callback (at most
  one pending FX update, so a fast transfer can't flood the event
  loop) that drives each `Transfer`'s byte count + a
  `"Uploading... NN%"` / bytes-so-far message.
- `TransferQueueView` progress column is now a determinate
  fraction (`bytesTransferred / sizeBytes`) for uploads; downloads
  stream without a known total and stay indeterminate.
- `EncodingPanel` shows a progress bar bound to the encode task's
  message during the local encode phase (indeterminate -- the
  importer doesn't yet report granular progress, see #114), then
  hands off to the determinate Transfers queue for the upload.

### Added -- W6.1a: transport progress callback (Python + Java) (2026-05-20)

First slice of W6.1 (progress feedback). Adds a progress
callback to the workbench transport client so uploads/downloads
can drive a determinate progress bar instead of an indeterminate
spinner -- the root SDK gap behind issue #113.

Java (`global.thalion.ttio.workbench.transport`):
- New `TransferProgress` functional interface --
  `onProgress(bytesDone, bytesTotal)`, with an `UNKNOWN_TOTAL`
  (-1) sentinel for streamed downloads. Throwing callbacks are
  swallowed so they can't abort a transfer.
- `WorkbenchTransportClient.upload(..., TransferProgress)` and
  `.download(..., TransferProgress)` overloads. Upload reports
  `(bytesSent, payload.length)` per chunk (determinate); download
  reports `(bytesReceived, UNKNOWN_TOTAL)` per binary frame.

Python (`ttio.workbench.transport`):
- `UploadClient.upload_bytes(..., progress=)` and
  `DownloadClient.download(..., progress=)` accept a
  `Callable[[int, int], None]` with the same `(done, total)`
  contract; `_report_progress` helper swallows callback
  exceptions. Cross-language equivalent of the Java interface.

Tests: `TransferProgressTest` (Java, 3) pins the sentinel +
contract + that the overloads exist; `test_transport_progress.py`
(Python, 6) pins `_report_progress` + the `progress=` kwargs.
The end-to-end "callback fires with rising bytes" assertion lands
with W6.1b (GUI wiring) / a live-upload test.

### Changed -- W6 plan: progress feedback promoted to W6.1 (2026-05-20)

Reprioritised docs/workbench-client/W6-plan.md so **progress
feedback for all client-server interactions** leads the milestone
(was unscheduled; now W6.1, ahead of encryption/PQC). Encryption
-> W6.2, PQC -> W6.3, formats -> W6.4, federation -> W6.5, docs
-> W6.6. Driven by a live cross-environment test where a
multi-contig FASTA encode+upload showed no feedback for minutes
(working, not hung). Requirement: every client-server op (and the
encode/decode bracketing it) shows phase (reading/writing,
encoding/decoding, uploading/downloading) + % by source size;
no bare spinners. Tracked in issues #113 (requirement) and #114
(the ReferenceImport per-attribute H5Acreate slowness that
exposed it).

### Added -- W6.0: kickoff plan (SDK polish + formats + PQC/BYOK + federation) (2026-05-20)

Kickoff for the final workplan milestone. docs/workbench-client/
W6-plan.md lays out six sub-phases: W6.0 kickoff (this), W6.1
BYOK + envelope encryption client, W6.2 PQC client
(opt_pqc_preview), W6.3 format expansion (wire the spec §4 codecs
into `ttio encode --format` for CLI/SDK/GUI parity), W6.4
federation client (graceful no-op vs v1.0), W6.5 SDK reference
docs + tutorial + finalisation. Plan-only PR; sub-phases follow.

Grounding: the core crypto (ttio/pqc.py, ttio/encryption.py,
ttio/transport/encrypted.py) and the 13-format codec set already
exist at the library level; W6 exposes them through the workbench
client surface (no ttio/workbench/{encryption,pqc}.py yet) and
finalises docs. Python + Java lockstep per Decision 2; Rust SDK
deferred to v1.2.

### Changed -- Un-xfail cohort live test after server fix (2026-05-19)

tti-workbench-server PR #29 registered TTIOWBCohortsHandler (the
cohort REST plane was 404 in v1.0 -- the gap the live smoke
exposed). With the server fix on main, the live smoke's cohort
test (test_cohort_preview_count_round_trips) is un-xfailed and
now passes normally: the workbench-live workflow checks out the
server at main. Live smoke is now 8 passed (was 7 passed, 1
xfailed). Doc updated in docs/workbench-client/live-daemon-smoke.md.

### Added -- Live-daemon end-to-end smoke (closes the W1-W5 live-acceptance deferral) (2026-05-19)

Wires a real tti-workbench-server daemon into CI and drives the
actual ttio.workbench.* client SDK against it -- the live half
of the W1-W5 acceptance gates that every prior sub-phase
deferred.

Pieces:
- python/tests/integration/test_workbench_live.py -- env-gated
  (TTIO_WORKBENCH_URL + TTIO_WORKBENCH_STAGING) test driving
  connect (BootstrapAdminAuth) -> containers.list ->
  pipelines.register/list/get -> jobs.submit + poll + events
  (SSE) + cancel -> sessions.create/list/terminate. SKIPS when
  the env vars are unset, so the normal unit CI is untouched.
- scripts/workbench-live-smoke.sh -- local runner; boots the
  daemon with a temp SQLite config, seeds the admin project,
  runs pytest, tears down. Validated locally: 7 passed, 1
  xfailed.
- .github/workflows/workbench-live.yml -- CI that builds the
  GNUstep/ObjC toolchain + libTTIO (from the PR checkout) + the
  pinned tti-workbench-server, boots the daemon, runs the smoke.
  Runs on workbench-client-path PRs + manual dispatch (not a
  blanket per-PR gate; cold GNUstep build is ~10-15 min). Needs
  the TTIO_LIBRARY_CHECKOUT_TOKEN secret for cross-repo checkout.

Bugs the smoke caught:
- W5.2 containers.py keyword-arg bug (FIXED in this change).
  ContainersClient called http_json() and WorkbenchHttpError()
  with positional args for keyword-only params (scheme / token /
  body / status). The W5.2 unit tests only covered the pure
  dataclasses (HTTP methods are coverage-excluded), so this was
  invisible until the live round-trip. All five methods fixed.
- Server-side gap (tti-workbench-server repo follow-up):
  TTIOWBCohortsHandler is implemented but never registered in
  Source/Core/TTIOWBServer.m, so /v1/cohorts/{query,preview-count}
  return 404 on the v1.0 daemon. The cohort live test is marked
  xfail(strict=False) and flips to XPASS once the server wires
  the handler. The client SDK request is correct (raises a clean
  WorkbenchHttpError(404)).

Full detail in docs/workbench-client/live-daemon-smoke.md.

### Added -- W5.7: tio-browser Encoding + Export panels + 1.5.0 (closes W5) (2026-05-19)

Seventh and final W5 sub-phase. Adds the last two spec section
8.1 GUI components, bumps tio-browser to 1.5.0, and lands the
GUI-assembly end-to-end smoke. Completes the WC Desktop GUI
track: all nine spec section 8.1 components now have a working
tio-browser panel.

tio-browser new files in workbench/:
- EncodingPanel: modal encode + upload coordinator. Picks a
  source file, detects format via FormatSniffer, encodes to a
  temp .tio via the existing Phase-8 ImportTask, then enqueues
  an upload through the W5.3 TransferManager under a derived
  container URI. Static helpers deriveContainerUri (project +
  filename to uri:tio:...), deriveTempTio, isValidProject.
- ExportPanel: modal client-side export. Opens a local .tio
  (typically just downloaded via the W5.3 download dialog) and
  runs the existing Phase-9 ExportTask to a target format.
  Static helpers extensionFor (format to conventional
  extension), deriveExportTarget, isValidTioPath. v1.0 is
  client-side export; server-side export (export pipeline on the
  daemon) is a follow-up.

MainWindow gains two new menu items under Workbench: Encode +
upload and Export container.

Version: tio-browser 1.4.1 -> 1.5.0 (workbench-aware GUI). The
java/python ttio library stays at 1.3.0 (the W5.0 SDK bump);
tio-browser versions independently per the carry-forward rule.

Tests:
- EncodingPanelTest 10 tests: deriveContainerUri (simple name,
  path + extension strip, lowercase + hyphenate, no-project,
  empty-base fallback, dot-prefixed name, Windows backslash
  path); deriveTempTio (.tio suffix + name); isValidProject.
- ExportPanelTest 7 tests: extensionFor (known formats +
  unknown fallback); deriveExportTarget (extension swap,
  directory preserved, no-directory, null-source fallback);
  isValidTioPath.
- WorkbenchMenuSmokeTest 2 TestFX tests (end-to-end GUI
  assembly): the Workbench menu exposes every W5.1-W5.7 action;
  every Workbench action has an onAction handler. This is the
  GUI-assembly half of the W5 acceptance gate; the live-daemon
  round-trip (login to browse to upload to submit to download)
  remains a shared cross-W follow-up needing the workbench-server
  Docker image in CI.

W5 COMPLETE. Spec section 8.1 component coverage:
- Connection Manager (W5.1)
- Container Browser (W5.2)
- Upload/Download Manager + Selective Access Panel (W5.3)
- Cohort Query Builder (W5.4)
- Pipeline Launcher + Job Monitor (W5.5)
- Interactive Session Launcher (W5.6)
- Encoding Panel + Export Panel (W5.7)

Deferred across W5 (tracked in docs/workbench-client/W5.7-progress.md):
live-daemon round-trip smoke; schema-driven pipeline form;
save-as-cohort (needs server v1.1); embedded Jupyter WebView;
server-side export pipeline; tree-style cohort editor.

### Added -- W5.6: tio-browser Interactive Session Launcher (2026-05-19)

Sixth W5 sub-phase. JavaFX surfaces wrap the W4 SessionsClient
SDK -- no new wire surface, no new SDK code.

Decision (W5-plan open-question 2): interactive attach happens
through the operator's own WS-capable client (CLI
`ttio sessions attach` or a terminal), not an embedded JavaFX
WebView. The session list copies the `wss://` attach URL to the
clipboard and shows it in a copyable dialog. Embedded Jupyter
WebView (spec 7.4 step 3 option a) is a v1.1 enhancement.

tio-browser new files in workbench/:
- SessionLauncher: modal create form (project / engine pin /
  image / command / bind-mounts / env). Builds a
  SessionsClient.CreateRequest and calls create. Static parsers
  parseCommand, parseBindMounts, parseEnv are the testable
  boundary.
- SessionList: non-modal TableView Session with session id,
  status, project, engine, host-port columns; refresh,
  copy-attach-URL, terminate controls. Static attachUrl Session,
  WorkbenchClient returns the wss URL for running sessions, null
  otherwise.

MainWindow gains two new menu items under Workbench: Launch
session and Sessions after Jobs.

Tests:
- SessionLauncherTest 15 tests: parseCommand whitespace split +
  blank/null empty; parseBindMounts basic host:container, drops
  :mode suffix, skips blank lines, rejects missing/leading/
  trailing colon; parseEnv KEY=VALUE, value-with-equals
  preserved, skips blanks, rejects no-equals/leading-equals;
  isValidProject blank rejection.
- SessionListTest 4 tests: attachUrl builds the WS proxy URL for
  running sessions (wss + ws scheme variants); null for
  non-running / null args.

Cross-language scope: GUI-only Java; no new SDK code. The W4
Session record + SessionProxy URL builder already have
cross-language byte-equivalence pinned in W4 tests.

Deferred follow-ups: live-daemon round-trip smoke (shared);
embedded Jupyter WebView (spec 7.4 step 3 option a); auto-refresh
/ live session status.

### Added -- W5.5: tio-browser Pipeline Launcher + Job Monitor (2026-05-19)

Fifth W5 sub-phase. JavaFX surfaces wrap the W3 PipelinesClient
and JobsClient SDKs -- no new wire surface, no new SDK code.

tio-browser new files in workbench/:
- PipelineLauncher: modal pipeline picker. ChoiceBox loaded from
  PipelinesClient.list; pipeline metadata + schema preview pane;
  raw JSON textareas for inputs and params (v1.0 -- schema-driven
  form generation is v1.1); submit button calls
  JobsClient.submit and shows an info Alert with the resulting
  job id. Static isValidJsonObject(String) is the testable
  JSON-object validator.
- JobMonitor: non-modal job dashboard. TableView Job with job
  id, pipeline, status, project, queued, started, completed
  columns; status-filter ChoiceBox driving JobsClient.list;
  refresh, cancel-selected, tail-events controls. Static helpers
  formatTimestamp Long (ISO-8601 UTC) and filterValue String
  (resolves "(all)" to null) testable without FX.
- JobEventsView: non-modal SSE tail viewer for a single job.
  Worker thread calls JobsClient.events jobId, consumer; the
  consumer marshals each frame to the FX thread via
  Platform.runLater. Auto-closes the stream on terminal-state
  event (Completed / Failed / Cancelled). Static formatFrame
  JobEvent and isTerminalEvent JobEvent testable without FX.

MainWindow gains two new menu items under Workbench:
Launch pipeline and Jobs after Cohort query.

v1.0 scope: raw JSON textareas for pipeline inputs / params.
Schema-driven form rendering is a v1.1 enhancement; the SDK
already accepts Map String, Object so only the form pair
changes.

Tests:
- PipelineLauncherTest 9 tests: isValidJsonObject accepts
  populated objects, rejects blank / null / array / scalar /
  malformed; renderSchemaPreview surfaces identifier, version,
  project, owner, engine-pin, schemas; empty schemas render as
  none; engine-pin omitted when null/empty; stable output.
- JobMonitorTest 6 tests: formatTimestamp UTC ISO-8601 for
  positive seconds, blank for null / 0 / negative; filterValue
  resolves "(all)" / "" / null to null, passes through known
  statuses.
- JobEventsViewTest 7 tests: formatFrame event-name and
  key=value pairs, empty data map, null event name; isTerminalEvent
  detects completed / failed / cancelled, false for queued /
  starting / running, false for non-state events, missing
  status, null.

Cross-language scope: GUI-only Java; no new SDK code. The W3
Pipeline / Job / JobEvent records already have cross-language
byte-equivalence pinned in W3 tests.

Deferred follow-ups: live-daemon round-trip smoke (shared);
schema-driven inputs form; richer job filters (project, owner,
since); re-submit job.

### Added -- W5.4: tio-browser Cohort Query Builder (2026-05-19)

Fourth W5 sub-phase. Adds a visual predicate-composition window
to tio-browser that drives the W3 `CohortQuery` SDK; no new
wire surface (the v1.0 server's POST /v1/cohorts/query +
/v1/cohorts/preview-count endpoints already cover the
GUI-supported flows).

tio-browser new files in workbench/:
- CohortLeafRow -- mutable row for the leaf-predicate table
  with JavaFX-property-backed fields (kind / field / op /
  rawValue). toPredicate builds the matching CohortPredicate
  leaf; coerceValue raw, op converts the raw text input to a
  typed value (int / double / bool / string / comma-separated
  list for in).
- CohortQueryBuilder -- window with composite-root choice (AND
  / OR / NOT), select-kind choice (containers / subjects /
  samples), TableView CohortLeafRow with editable cells, Run
  and Preview Count buttons, result TableView. Static
  buildPredicate(composite, rows) is the testable boundary
  between form and SDK.

MainWindow integration: new Workbench menu item Cohort query
after Transfers.

Client-side rule enforcement (mirrors v1.0 server rules):
- phenotype rejected under OR / NOT (server enforces this
  too; client-side catch gives a clearer error than a 400).
- NOT requires exactly one leaf.

v1.0 scope: flat leaf list under a single composite root.
Nested composite trees + drag-drop reorder are a v1.1
enhancement. The W3 SDK already supports nested composites;
the GUI just does not surface them in v1.0.

Tests:
- tio-browser CohortLeafRowTest 13 tests: coerceValue parsers
  (int / double / bool / string / list for in / blank for
  exists), toPredicate builds the right leaf subclass per
  kind, blank field rejection, Kind.fromLabel round-trip.
- tio-browser CohortQueryBuilderTest 11 tests: AND with one
  leaf collapses to leaf, AND/OR composite construction,
  phenotype rejected under OR/NOT, NOT with non-1 leaves
  rejected, empty leaf list rejected, unknown composite
  rejected.

Cross-language scope: GUI-only; no new SDK code. The W3
cohort-predicate AST is already cross-language byte-equivalent.

Deferred follow-ups: live-daemon round-trip smoke (shared);
save-as-cohort needs server v1.1 POST /v1/cohorts; tree-style
editor with nested composites + drag-drop; field-level
autocomplete.

### Added -- W5.3: Transfer Manager + Selective Access Panel + filter builder (2026-05-19)

Third W5 sub-phase. Wires the W1 `WorkbenchTransportClient`
into a JavaFX queue UI, adds a visual filter form for selective
downloads, and pins a typed-builder filter API on both SDKs.

No new server wire surface; W5.3 builds on top of the existing
W1 `/transport` WS handshake. The download-filter allowlist
(`ms_level`, `polarity`, `retention_time_{min,max}`,
`precursor_mz_{min,max}`, `precursor_charge`, `max_au`) is
unchanged.

Java SDK new file `workbench/transport/SelectiveAccessFilter.java`:
- Fluent typed setters per allowed filter key.
- Per-key range checks throw `IllegalArgumentException`.
- Cross-key `validate()` checks `rt_max >= rt_min` and
  `mz_max >= mz_min`, throws `IllegalStateException`.
- `build()` returns a `LinkedHashMap<String, Object>` ready
  for `WorkbenchTransportClient.download`.

Python SDK new file `workbench/transport/selective_access.py`:
- Single-class mirror of the Java builder. Same method names
  (snake_case), same exception semantics (`ValueError` per-key,
  `RuntimeError` cross-key).

tio-browser new package `browser/workbench/`:
- `TransferKind` / `TransferState` enums + `Transfer` mutable
  entry with JavaFX properties.
- `TransferManager` -- process-wide singleton; daemon-thread
  executor; FX-thread-safe state mutation; `enqueueUpload`,
  `enqueueDownload`.
- `SelectiveAccessPanel` -- GridPane filter form with one
  input per allowed filter key; `buildFilter()` delegates to
  the SDK `SelectiveAccessFilter` and runs `validate()`.
- `UploadStartDialog` -- modal source file + project + URI
  picker; container-URI validator.
- `DownloadStartDialog` -- modal URI + destination + embedded
  selective-access panel.
- `TransferQueueView` -- non-modal TableView<Transfer> with
  indeterminate ProgressBar while RUNNING; bound to the
  manager's observable list.

`MainWindow` gains three new menu items under `Workbench`:
`Upload to workbench...`, `Download from workbench...`,
`Transfers...`.

Tests:
- Java `SelectiveAccessFilterTest` (18 tests) covers accept /
  reject / cross-key validation + cross-language anchor.
- Python `test_selective_access.py` (20 tests) mirrors the
  Java suite.
- tio-browser: `SelectiveAccessPanelTest`, `TransferStateTest`,
  `TransferTest`, `UploadDownloadDialogTest` (17 pure-unit
  tests total) cover parsers, state-machine predicates, queue
  defensive copy, and URI/project validators.

Cross-language byte-equivalence: canonical filter dict pinned
in both test suites is the fifth independent cross-language
anchor (after W1 handshake, W3 cohort predicate, W4 attach
handshake, W5.2 container list-page).

Coverage: no new excludes; `SelectiveAccessFilter` /
`selective_access.py` are pure data and stay measured.

Deferred follow-ups: live-daemon round-trip smoke (shared with
W1/W3/W4/W5.1/W5.2); true progress percentage (needs a
progress-callback API on `WorkbenchTransportClient`); pause /
cancel (needs a cancellation primitive on the W1 client);
chromosome / position genomic filters (not in v1.0 server
allowlist).

### Added -- W5.2: Container Browser + /v1/containers SDK (Python + Java) (2026-05-19)

Second W5 sub-phase. Adds the `/v1/containers` REST surface to
both SDKs (Decision-2 lockstep) and a JavaFX Container Browser
window to tio-browser.

Pre-implementation: surveyed `tti-workbench-server/Source/HTTP/
handlers/TTIOWBContainersHandler.{h,m}` for the wire contract.
Five endpoints: list / get / layers / manifest / delete; opaque
base64url cursor pagination; container shape
`{uri, project, owner, encrypted, storage_path, created_at,
updated_at}`; gates via `containers.read.any_project` /
`containers.delete.{any,own_uploads}` server-side; existence
never leaked (404 vs 403).

Java SDK (new package `global.thalion.ttio.workbench.containers`):
- `Container` / `ContainerDetail` records (list + detail shapes).
- `ContainerListPage` with `nextCursor` + `hasMore()`.
- `ContainerLayer` record.
- `ContainerManifest` outer record + nested `MsRunSummary` /
  `NmrRunSummary` / `GenomicRunSummary` records.
- `ContainersClient`: `list`, `get`, `layers`, `manifest`,
  `delete`.
- `WorkbenchClient.containers()` factory.

Python SDK (`ttio/workbench/containers.py`):
- Frozen-dataclass mirrors of every Java record.
- `ContainersClient` with identical method shape.
- `WorkbenchClient.containers()` factory.

tio-browser (`workbench/ContainerBrowser.java`):
- Modal-but-non-modal window. TableView<Container> with
  sortable URI / project / owner / encrypted / created /
  updated columns.
- Filter row (project / owner / limit) + Refresh button +
  Load-more button driving cursor pagination.
- Manifest pane in a SplitPane; selecting a row fetches and
  renders the manifest as plain-text summary.
- Opened via new `MainWindow` menu item `Workbench -> Browse
  containers...`; gated on `ConnectionManager.isConnected()`.

Tests:
- `ContainersTest` (Java, 13 tests) covers all records +
  parsing edge cases + the cross-language anchor.
- `test_containers.py` (Python, 14 tests) mirrors the Java
  suite.
- `ContainerBrowserTest` (tio-browser, 11 pure-unit tests)
  covers static helpers (`parseLimit`, `formatTimestamp`,
  `renderManifest`).
- `WorkbenchClientTest.w3W4W5SubClientsAreLive` /
  `test_client.test_w3_w4_w5_sub_clients_are_live` extended
  to assert `containers()` returns non-null.

Cross-language byte-equivalence: the GET /v1/containers
list-page parser is the fourth independent cross-language anchor
(after W1 handshake, W3 cohort predicate, W4 attach handshake).
Same literal JSON pinned in both test suites.

Coverage adjustments:
- `java/pom.xml` JaCoCo excludes extended to
  `ContainersClient*` (HTTP-method wrappers need a live daemon).
  Records stay measured.
- `python/pyproject.toml` `[tool.coverage.run].omit` extended to
  `*/workbench/containers.py` (matches jobs.py / pipeline.py).

Deferred follow-ups: live-daemon round-trip smoke (shared with
W1/W3/W4/W5.1); unified DataSourceTree merging local + remote
sources (per W5-plan); GUI surface for the layer breakdown
(client method present, no UI yet).

### Added -- W5.1: tio-browser Connection Manager (2026-05-19)

First substantive W5 sub-phase. Adds the JavaFX foundation that
every other W5 panel will hang off: an observable workbench
connection holder, a modal login dialog, and a status-bar
indicator. Wires the W1+W3+W4 `global.thalion.ttio.workbench.
WorkbenchClient` SDK into the GUI for the first time.

New package `tio-browser/src/main/java/global/thalion/ttio/
browser/workbench/`:
- `ConnectionState` enum (DISCONNECTED / CONNECTING / CONNECTED
  / FAILED).
- `ConnectionListener` functional interface.
- `ConnectionManager` -- process-wide singleton holding the
  `WorkbenchClient` instance + state machine. Thread-safe
  listeners; `connect(url, auth)` and `disconnect()` drive
  state transitions; throwing listeners do not block siblings.
- `LoginDialog` -- modal `Stage`-based form with server URL +
  username + password + TOTP. Static validators
  (`isValidUrl`, `isValidTotp`, `isValidUsername`,
  `isValidPassword`). `Bindings.createBooleanBinding`
  disables the Connect button until valid; worker `Task<Session>`
  calls `ConnectionManager.connect()` off the FX thread.
- `StatusIndicator` -- small HBox (coloured Circle + Label +
  Tooltip) for the status bar; subscribes to `ConnectionManager`
  and renders the four colour states.

`MainWindow` integration:
- New `Workbench` menu between `Transport` and `Tools` with
  `Connect...`, `Disconnect`, `Status...` items.
- Status bar gains the right-aligned indicator.
- `showWorkbenchStatus()` modal Alert summarises endpoint /
  user / provider / projects / capability count / session id;
  surfaces the last failure message when disconnected.
- `dispose()` detaches the indicator listener.

Tests:
- `ConnectionManagerTest` (8 tests, pure unit) covers state
  transitions, listener dispatch, idempotent disconnect,
  throwing-listener tolerance, post-failure reconnect.
- `LoginDialogTest` (9 tests) covers the static validators
  (URL forms, TOTP 6-digit rule, blank-rejection).
- `StatusIndicatorSmokeTest` (3 TestFX tests) verifies the
  three colour transitions render correctly and the tooltip
  carries the failure message.

CI: new `tio-browser-test` job in `ci.yml` mirrors the
release-shaded-jar workflow's linux-x64 leg (JDK 25 + HDF5 +
native libttio_rans build + `mvn install` of `java/` to local
M2 + `mvn -P linux-x64 test` of `tio-browser/`). Every PR is
now compile- and TestFX-verified at PR time, not just on tag
push.

Deferred to W5.1 follow-up: live-daemon round-trip (shared
deferral with W1/W3/W4).

### Changed -- W5.0: TTI-O Java SDK 1.3.0 (kickoff) (2026-05-19)

Fifth workbench-client milestone kickoff. Bumps `java/pom.xml`
1.2.0 -> 1.3.0 (line marker for the workbench-client Java
surface added in W1+W3+W4) and `tio-browser/pom.xml`'s
`<ttio.version>` in lockstep so the JavaFX GUI can consume the
new `global.thalion.ttio.workbench.*` classes. Corrects the
workplan's W5 cross-repo language: tio-browser is a sibling
subdirectory of `java/`, not a separate GitHub repository.

W5 phasing recorded in `docs/workbench-client/W5-plan.md` --
eight sub-phases (W5.0 kickoff -> W5.7 encoding+export+smoke)
delivering spec section 8.1's nine GUI components into
tio-browser. Subsequent W5.x PRs add the panels themselves;
this PR is admin-only (version bumps + plan + workplan
correction).

Library SemVer bump: minor. No breaking changes to existing
TTI-O format APIs; the workbench-client surface is purely
additive on top of v1.2.0.

### Added -- W4: interactive sessions client (Python + Java) (2026-05-19)

Fourth workbench-client milestone. Wraps the workbench server's
`/v1/sessions` REST surface + the `ttio-session-proxy` WS attach
helper (spec UC-11). Python + Java in lockstep per Decision-2.

Pre-implementation: deep-surveyed the v1.0.0 server contract --
`Documentation/session-protocol.md` cross-referenced with
`Source/HTTP/handlers/TTIOWBSessionsHandler.m`,
`Source/Sessions/{TTIOWBSessionRegistry,TTIOWBSessionLifecycle,
TTIOWBSessionProxy}.m`. Survey findings recorded in
`docs/workbench-client/W4-progress.md`. v1.0 deferrals
respected: idle-timeout sweep, host-port allocator, ring-buffer
backpressure are all server-side -- client just observes.

Python (`python/src/ttio/workbench/`):
- `sessions.py` -- `Session` dataclass (5 status enum, runtime
  fields, `is_terminal` / `is_attachable` properties),
  `SessionsClient` (create / list / get / terminate),
  `validate_bind_mounts()` client-side validator mirroring the
  server's rules (absolute, no `..`, project-scope check when
  `container_storage_root` is known).
- `session_proxy.py` -- `build_attach_handshake()` and
  `session_proxy_url()` pure helpers, `SessionProxyAttach` async
  context manager that opens the `ttio-session-proxy` WS, sends
  the JSON attach frame, pumps bytes bidirectionally between
  caller-supplied byte streams (stdin/stdout or in-memory).
- `client.py` -- `WorkbenchClient.sessions()` /
  `.session_create()` / `.session_proxy()` promoted from W2-era
  stub to live methods. No remaining `NotImplementedError`
  paths -- the v1.0 client SDK is feature-complete for the
  spec section 8.3 sample.

Java (`java/src/main/java/global/thalion/ttio/workbench/`):
- `sessions/Session.java` -- mirror record.
- `sessions/BindMountValidator.java` -- same validation rules.
- `sessions/SessionsClient.java` -- REST surface with
  fluent `CreateRequest` builder.
- `sessions/SessionProxy.java` -- pure builders + URL constructor.
- `sessions/SessionProxyAttach.java` -- callback-driven WS
  attach (built on `org.java_websocket`), pumps `InputStream`
  <-> `OutputStream` until close.
- `WorkbenchClient.sessions()` / `.sessionProxy()` live.

CLI (`python/src/ttio/tools/workbench_cli.py`): `ttio sessions`
promoted from W3-era stub to live verb subcommand:
  - `ttio sessions create --engine X --project Y [--image Z]
                         [--command CMD...] [--env K=V]
                         [--bind-mount HOST:CONT]`
  - `ttio sessions ls [--status X] [--limit N]`
  - `ttio sessions status <id>`
  - `ttio sessions attach <id> [--path /]` -- proxies stdin /
    stdout against the engine subprocess.
  - `ttio sessions terminate <id>` -- DELETE /v1/sessions/{id}.

Tests:
- **Python:** 156 workbench tests pass locally (+25 over W3):
  `test_sessions.py` (25 tests) covering Session parsing across
  all statuses, bind-mount validator (5 failure paths + happy +
  noop), attach handshake builder, URL constructor, status-set
  pinning, cross-language anchor literal.
- **Java:** `SessionsTest` mirrors the Python suite including
  the cross-language attach-handshake JSON literal.

Cross-language anchor: identical attach-handshake JSON literal
pinned in both Python + Java session test suites.

JaCoCo + Python coverage excludes extended to the new
daemon-required classes (`SessionsClient`, `SessionProxyAttach`
on Java; `session_proxy.py` on Python). The pure-data `Session`
record + `BindMountValidator` + attach builders stay measured.

### Added -- W3: cohort + pipeline + job client (Python + Java) (2026-05-19)

Third workbench-client milestone. Wraps the workbench server's
REST + SSE surface for the cohort / pipeline / job plane (spec
UCs 6, 7, 9, 10). Python + Java in lockstep per the workplan
Decision-2 parity rule.

Pre-implementation: deep-surveyed the v1.0.0 server wire
contract for the W3 endpoints (`/v1/cohorts/{query,preview-count}`,
`/v1/pipelines{,/{id}}`, `/v1/jobs{,/{id},/{id}/events}`).
Survey findings recorded in
`docs/workbench-client/W3-progress.md`. v1.0 deferrals
documented:
  - No `GET /v1/cohorts` / `POST /v1/cohorts` (saved cohorts);
    queries are ephemeral.
  - No `has_layer(...)` assay-availability filters in the cohort
    AST.
  - No `Last-Event-Id` SSE resumption; reconnect for full replay.
  - No `GET /v1/containers/{uri}/provenance`; `provenance_edges`
    lives in the DB but isn't surfaced over HTTP.

Python (`python/src/ttio/workbench/`):
- `cohort.py` -- predicate AST (4 leaf kinds + 3 composites).
  `OR` / `NOT` reject nested phenotype leaves per the server's
  column-join semantics. Operator overloading (`&`, `|`, `~`)
  for fluent composition. `CohortQuery` builder, `CohortResult`
  parser.
- `pipeline.py` -- `Pipeline` dataclass + `PipelinesClient`.
- `jobs.py` -- `Job` dataclass with `is_terminal`; `JobsClient`
  (submit / list / get / cancel); `JobEvent` + async-iterator
  `events(job_id)` SSE parser. `build_cohort_input()` builds
  the Decision-4 envelope.
- `_http.py` -- internal REST helper (urllib-based; zero new
  runtime deps).
- `client.py` -- `WorkbenchClient.query()` /
  `.preview_count()` / `.pipelines()` / `.submit_pipeline()` /
  `.jobs()` promoted from W2-era stubs to live implementations.
  Only `session_create()` remains a W4 stub.

Java (`java/src/main/java/global/thalion/ttio/workbench/`):
- `cohort/` -- `CohortPredicate` abstract + 7 subclasses with the
  same validation rules as Python. `CohortQuery` builder,
  `CohortResult` record.
- `pipeline/` -- `Pipeline` record + `PipelinesClient`.
- `jobs/` -- `Job` + `JobEvent` records + `JobsClient` with
  callback-driven SSE (`events(jobId, Consumer<JobEvent>)`).
- `WorkbenchHttp` -- internal REST helper over
  `java.net.http.HttpClient`; emits compact JSON byte-matching
  Python.
- `WorkbenchClient.query()` / `.previewCount()` / `.pipelines()` /
  `.jobs()` live.

CLI: W2-era placeholder subcommands promoted to live impls --
`ttio query` / `submit` / `jobs {ls,status,cancel,events}` /
`pipelines {ls,get,register}` / `cohorts` (alias for `query`).
`ttio provenance` surfaces the v1.0 "endpoint not exposed"
deferral. `ttio sessions` still W4-stubbed.

Tests:
- **Python:** 131 workbench tests pass locally (+52 over W2):
  `test_cohort.py` (33), `test_jobs.py` (13), `test_pipelines.py`
  (4), plus updates to W2 tests for W3-promoted methods.
- **Java:** `CohortPredicateTest` (predicate AST + CohortQuery),
  `JobAndPipelineTest` (Job / Pipeline / JobEvent / clients).
- Cross-language anchor: identical predicate JSON literal pinned
  in both suites.

JaCoCo + Python coverage excludes extended to the new
daemon-required classes (`WorkbenchHttp`, `PipelinesClient`,
`JobsClient` in Java; `_http.py`, `pipeline.py`, `jobs.py` in
Python). Pure-data records + predicate AST + parsers stay
measured.

### Added -- W2: `ttio` CLI umbrella + Python SDK foundation (2026-05-19)

Second milestone of the
[Workbench Client workplan](docs/workbench-client-workplan.md).
Lands the spec section 8.2 CLI surface verbatim and the section
8.3 SDK shape (`ttio.connect(...)`, auth providers,
`WorkbenchClient`). All Python; the Java equivalent for W2 lives
inside W5 when tio-browser bumps its TTI-O dep.

SDK foundation (`python/src/ttio/workbench/`):
- `auth_providers.py` -- `AuthProvider` ABC plus four concrete
  providers: `PasswordTotpAuth` (interactive creds via W1
  `login_password`), `BearerAuth` (caller already holds a
  bearer; synthesises a `Session` without round-trip),
  `BootstrapAdminAuth` (reads `<staging_root>/bootstrap-
  credentials.json`; smoke / dev path), and `OIDCAuth` (v1.1
  stub that raises a clear NotImplementedError).
- `client.py` -- `connect(url, auth=...)` factory + the
  `WorkbenchClient` class. Resolves WSS/WS/HTTPS/HTTP URLs,
  authenticates through the provider, exposes
  `upload_client(...)` / `download_client(...)` builders + the
  `upload_bytes(...)` / `download_bytes(...)` async
  convenience methods. W3 surfaces (`query`, `submit_pipeline`,
  `jobs`) and W4 surfaces (`session_create`) registered as
  methods that raise NotImplementedError pointing to the
  milestone.
- `cohort.py`, `pipeline.py`, `jobs.py`, `sessions.py` --
  namespace stubs so the eventual W3/W4 implementations have
  the import path reserved and IDE-completion works today.
- Top-level `ttio` re-exports `connect`, `WorkbenchClient`,
  `Session`, and all four `*Auth` providers so the spec section
  8.3 sample (`ttio.connect(..., auth=ttio.OIDCAuth())`) works
  without operators digging into sub-modules.
- `parse_filter_kv()` helper turns repeated `--filter k=v`
  arguments into a dict with numeric coercion.

CLI (`python/src/ttio/tools/workbench_cli.py`):
- `ttio` umbrella console-script with subcommands matching
  spec section 8.2:
    - `login` -- resolve credentials, print the auth JSON.
    - `upload` -- WS upload of a local `.tio`.
    - `download` -- WS download to a local `.tio` with optional
      selective-access filters (`--filter k=v`, repeatable).
    - `stream` -- WS download saved as raw `.tis`.
    - `inspect` -- stats-only WS read; prints the per-AU
      summary frames.
    - `encode` / `export` -- dispatch into the existing
      `ttio.tools.{fastq,fasta}_{import,export}_cli`.
    - `query`, `submit`, `jobs`, `cohorts` -- W3 placeholders
      (exit 2 with milestone deferral message).
    - `sessions` -- W4 placeholder.
- Auth-mode resolver enforces exactly one of `--token+--owner`,
  `--staging-root`, or `--username+--password+--totp`.
- `pyproject.toml`: `[project.scripts] ttio = ...` so
  `pip install -e .` exposes `ttio` on PATH.

Tests (`python/tests/workbench/`):
- `test_client.py` -- 21 tests covering top-level re-exports,
  URL parsing, all four auth providers, the `connect()`
  factory, W3/W4 placeholder method dispatch, and the
  filter-key parser.
- `test_cli.py` -- 21 tests covering every spec section 8.2
  verb's `--help`, the auth-mode resolver's three failure
  modes, the W3/W4 placeholder exit codes, the encode-format
  pointer to W6.

Java (`java/src/main/java/global/thalion/ttio/workbench/`) --
**added in the same PR after a cross-language parity review:**
- `auth/AuthProvider.java` interface + four concrete providers
  (`PasswordTotpAuth`, `BearerAuth`, `BootstrapAdminAuth`,
  `OIDCAuth` stub).
- `WorkbenchClient.java` top-level entry: `connect(url, auth)`
  factory, `transportClient()` builder, `upload()` / `download()`
  convenience methods, W3 / W4 placeholder methods, and
  `parseUrl()` byte-matching the Python URL parser.
- JaCoCo excludes extended to the new daemon-required classes
  (`BootstrapAdminAuth`, `PasswordTotpAuth`).
- 23 new Java tests covering URL parser, all four auth
  providers, `connect()`, `reauth()`, `close()`, W3 / W4
  placeholders.

Workplan amendment in this PR
(`docs/workbench-client-workplan.md` Decision 2): **Python +
Java SDK ship in lockstep at every milestone.** The `ttio` CLI
stays Python-only by design (Decision 1: console-script). ObjC
stays server-runtime (not extended for client purposes).

Coverage: 79 Python workbench tests (37 W1 + 42 W2) plus 83
Java workbench tests (60 W1 + 23 W2), all pass locally. The W1
cross-language byte-equivalence anchor (handshake JSON literals
in both test suites) carries forward into W2.

### Added -- W1: Workbench client (Python + Java) (2026-05-19)

First milestone of the
[Workbench Client workplan](docs/workbench-client-workplan.md).
Ships the workbench-aware transport client (Python + Java) that
speaks `tti-workbench-server` v1.0.0's auth-bearing handshake.
Replaces the existing reference-protocol-only clients
(`ttio.transport.client` / `global.thalion.ttio.transport.TransportClient`)
which target the Python reference server.

Python (`python/src/ttio/workbench/`):
- `auth` -- RFC 6238 TOTP (HMAC-SHA1, 30s, 6 digits), `Session`
  dataclass, `login_password(host, port, user, pass, totp)` POSTing
  to `/v1/auth/login`. Typed exceptions for 401 / 423 / 429 paths;
  `Retry-After` surfaced on rate-limit.
- `transport.handshake` -- pure JSON builders for upload + download
  first-frames. Client-side filter-key validation matching the
  daemon's accept list.
- `transport.upload.UploadClient` -- async context manager that
  drives one upload over `ws://host:port/transport` with the
  `ttio-transport` subprotocol. Per-AU acks, EndOfStream
  acknowledgment, resumable-upload support via `ResumeState`.
- `transport.download.DownloadClient` -- analogous async download
  with selective-access filtering, three output modes (binary /
  stats-only / stats-with-payload), stats-frame collection.

Java (`java/src/main/java/global/thalion/ttio/workbench/`):
- `WorkbenchJson` -- minimal compact JSON encoder + parser scoped
  to the handshake / ack frames. No Jackson / Gson dependency
  (matches the existing hand-rolled pattern in `BamDump` +
  `ProvenanceJsonParse`).
- `auth.Totp`, `auth.Session`, `auth.Login` -- Java mirror of the
  Python auth module, using `java.net.http.HttpClient` for the
  REST POST.
- `transport.WorkbenchHandshake` -- pure JSON builders + parser.
- `transport.WorkbenchTransportClient` -- end-to-end upload +
  download built on `org.java_websocket.WebSocketClient` (the
  existing TTI-O Java WS dep), with builder construction
  (`WorkbenchTransportClient.forSession(host, port, session)`).
- `transport.ResumeState` -- resume bookkeeping record.
- `transport.WorkbenchTransportException` -- base + Handshake +
  Upload + Download subclasses carrying WS close code + reason.

Tests:
- Python (`python/tests/workbench/`): 37 tests across `test_auth.py`,
  `test_handshake.py`, `test_cross_language.py`. All pass.
- Java (`java/src/test/java/global/thalion/ttio/workbench/`):
  `TotpTest`, `WorkbenchHandshakeTest`. Both suites pin against
  the same RFC 6238 TOTP vectors + the same handshake JSON
  literals as the Python tests -- this is the cross-language
  byte-equivalence anchor (a Python or Java drift will fail both
  sides).
- Daemon round-trip integration tests deferred to a W1 follow-up:
  they need a running `tti-workbench-server` binary in CI, which
  requires building the binary on the runner or vendoring a
  prebuilt -- out of scope for this PR.

Per the [W1 progress doc](docs/workbench-client/W1-progress.md),
W2 (`ttio` CLI umbrella + Python SDK foundation) follows.

## [1.4.1] - 2026-05-11

This release was re-tagged in flight: the initial v1.4.1 build shipped
class files compiled with `--enable-preview` (Java 21 preview FFM API),
which a stock JDK launcher refused to load with
"Preview features are not enabled for `Hdf5CompoundIO$FieldKind`
(class file version 65.65535)". The retag drops `--enable-preview`
and targets Java 22 (where FFM is a stable API). Tag and release
assets at https://github.com/DTW-Thalion/TTI-O/releases/tag/v1.4.1
were replaced.

### Fixed

- **`tio-browser` Windows: opens `.tio` files with genomic data.** v1.4.0
  launched cleanly on Windows (after the MinGW DLL closure was bundled),
  but it could not open `.tio` files containing BAM/CRAM-style genomic
  data because the Java implementation shelled out to the
  `samtools` CLI binary — not installed on a fresh Windows machine.
  Replaced the samtools subprocess across `BamReader`, `BamWriter`,
  `CramReader`, and `CramWriter` with [htsjdk](https://github.com/samtools/htsjdk)
  4.1.3 — the pure-Java SAM/BAM/CRAM library used by GATK, Picard, and
  IGV. No external binary required at runtime; tio-browser now works
  end-to-end on Windows with only a JDK 22+ installed.
- **`tio-browser`: opens `.tio` files on a fresh JDK install.** The
  first v1.4.1 build hit a class-loader rejection on
  `Hdf5CompoundIO$FieldKind` because the compile used `--enable-preview`
  (Java 21 preview FFM API). Bumped the compile target from Java
  21+preview to Java 22-stable; FFM is a stable API in JDK 22 and the
  API surface is identical, so no source changes were needed.

### Changed

- **Minimum JDK bumped from 17 to 22.** The FFM API used by
  `Hdf5CompoundIO` / `VlBytesFFM` is stable in JDK 22+; an older JDK
  cannot load the compiled classes (class file version 66).
  Adoptium/Temurin ships JDK 22 binaries for all 3 supported
  platforms.

### Internal

- `htsjdk` added as a Maven runtime dependency (`com.github.samtools:htsjdk:4.1.3`).
- `BamReader.SamtoolsNotFoundException` retained as a no-throw alias
  for source compat with callers and tests that catch it.
- `BamReader.isSamtoolsAvailable()` returns `true` unconditionally
  (htsjdk is always available as a Maven dep).
- CRAM reference handling: custom `InMemoryFastaReferenceSource`
  bypasses htsjdk's stock `ReferenceSource` strict length/MD5
  validation, matching samtools' lenient default behaviour. Existing
  samtools-produced CRAMs (with placeholder `@SQ LN`) decode without
  modification.
- `BamReader` static initializer sets
  `samjdk.cram.use_alignment_md5_check=false` for the same reason.
- `WrittenGenomicRun.qualities` byte semantics preserved: ASCII Phred+33
  on the cross-language wire (M87/M88 convention); htsjdk's raw-Phred
  byte arrays are converted with ±33 in the reader/writer.
- 0-byte BAM/SAM rejection: explicit `Files.size(path) == 0` check
  before opening (htsjdk would otherwise treat as a 0-record BAM).
- `enable-preview` compiler flag removed from `maven-compiler-plugin`
  configuration in `java/pom.xml`.
- `enable-preview` removed from `surefire-plugin` `<argLine>` in both
  `java/pom.xml` and `tio-browser/pom.xml`.
- CI workflows (`ci.yml`, `release-shaded-jar.yml`): `setup-java`
  `java-version: '21'` → `'22'` (4 invocations).
- `tio-browser/README.md` + `docs/tio-browser.md`: "JDK 17+" → "JDK 22+".

## [1.4.0] - 2026-05-09

### Changed

- **`tio-browser` distribution model: per-platform JARs.** Replaces the
  prior universal shaded JAR with three platform-specific JARs
  (`tio-browser-1.4.0-linux-x64.jar`, `tio-browser-1.4.0-mac-aarch64.jar`,
  `tio-browser-1.4.0-win-x64.jar`). Each JAR is ~31 MB instead of the
  universal-with-HDF5 alternative (~64 MB), carries only its own
  platform's natives, and **bundles HDF5 1.14 + the LZ4 filter plugin**
  so `java -jar tio-browser-1.4.0-<your-os>.jar` on a fresh machine
  works out of the box with only a JDK 17+ — no system HDF5 install
  required.
- New `Hdf5NativeLoader` extracts the bundled HDF5 native libs to a
  per-JVM temp dir at `App.start()`, calls `System.load` in dependency
  order (hdf5 → hdf5_hl → hdf5_java), and registers the LZ4 plugin
  search path via `H5.H5PLappend`. Idempotent; throws
  `Hdf5NativeLoadException` on hard failures (modal Alert + exit, with
  a headless detector that suppresses the exit during TestFX runs).
- Wrong-JAR-for-OS detection: running `tio-browser-1.4.0-linux-x64.jar`
  on a Mac shows a clear modal Alert with the correct download name.
- `release-shaded-jar.yml` workflow restructured: each platform's
  build job now produces its own complete shaded JAR end-to-end (no
  separate assembly job). Workflow grants `contents: write`
  permission so the auto-publish step works without the v1.3.0 manual
  workaround.
- `jarhdf5` switched from `<scope>system</scope>` to a vendored
  `org.hdfgroup:jarhdf5:1.14.6` Maven dep at `tio-browser/local-repo/`,
  so the JHI5 classes ship in each per-platform shaded JAR.

## [1.3.0] - 2026-05-09

### Added

- **`tio-browser` desktop GUI (Phases 0–13 + native bundling)** —
  JavaFX desktop application for inspecting `.tio` datasets, peer to
  the Java / Python / ObjC reference implementations. Cross-platform
  shaded jar bundles `libttio_rans_jni` for **Linux x86_64**, **macOS
  Apple Silicon (arm64)**, and **Windows x86_64**; end users can run
  `java -jar tio-browser-<ver>-shaded.jar` without any toolchain
  setup beyond a JDK 17+ runtime.

  - **Phase 8** — Import wizard: 13-format dispatch (mzML, ImzML,
    nmrML, JCAMP-DX, BAM/SAM/CRAM, FASTA, FASTQ, mzTab, Thermo,
    Waters, Bruker), drag-and-drop with format auto-detection.
  - **Phase 9** — Export dialog: 11 export formats with eligibility-
    based greying when the open `.tio` doesn't contain the required
    run kind.
  - **Phase 10/11** — Transport: download `.tis` streams from
    `http(s)`/`ws(s)` URLs into a local `.tio`; upload a local `.tio`
    as a `.tis` byte stream to the same URL families. Server-side
    filters (run kind, dataset-id list, RT range) let clients fetch
    subsets without downloading the whole file.
  - **Phase 12** — Diagnostics dialog (Tools → Diagnostics): probes
    HDF5 JNI, `samtools`, `ThermoRawFileParser`, `masslynxraw`, and
    the Bruker Python helper. Greys out Import/Export format rows
    whose binary isn't available, with tooltips listing the missing
    dep. Re-probe button picks up newly-installed binaries without
    restarting the app via a listener bus.
  - **Phase 13** — Distribution: `--open <path>` CLI flag for the
    shaded JAR opens a dataset at launch; `mvn -P native-package
    package` runs `jpackage` to produce platform-native installers
    (`.deb`/`.rpm`/`.dmg`/`.msi`) at `target/installer/`. `NativeLibraryLoader` resolves the
  library via `System.loadLibrary` → bundled-resource extract →
  graceful degradation (Intel Mac and other unbundled platforms get
  a placeholder in the genomic Read Inspector; all non-genomic
  features keep working). Built and validated via the
  `release-shaded-jar.yml` GitHub Actions matrix workflow
  (`ubuntu-22.04` + `macos-14` arm64 + `windows-2022` MinGW UCRT64).
  See [`tio-browser/README.md`](tio-browser/README.md) for the
  install matrix, build-from-source instructions, release path, and
  rationale for arm64-only macOS / MinGW-w64 Windows.

- `Quantification.unit` field (Java / Python / ObjC) — optional
  per-quantification unit string (e.g. `"fmol"`, `"ng/mL"`). Stored
  as a JSON-array sidecar attribute `@quantification_units` on
  `/study/quantifications` for backward-compat (legacy datasets read
  back with empty units). Surfaced as a column in `tio-browser`'s
  Quantifications tab.

- `MassSpectrum.isCentroided()` / `is_centroided` / `isCentroided`
  (Java / Python / ObjC) — per-spectrum centroid-vs-profile
  classification, stored as a parallel-array column
  `spectrum_index/centroideds` (int32, 0=profile, 1=centroided).
  Wire-format additive optional column; legacy files read as
  `false` for all rows. Used by `tio-browser`'s spectrum plot to
  auto-select stem rendering for centroided MS.

- `AcquisitionRun.spectra() : List<Spectrum>` (Java) /
  `acquisition_run.spectra` property (Python) /
  `-[TTIOAcquisitionRun spectra]` (ObjC) — modality-uniform spectrum
  enumeration, replacing the `for(i)+objectAtIndex+instanceof`
  pattern. Includes new `AcquisitionMode` constants
  `RAMAN` / `IR` / `UV_VIS` (ordinals 9 / 10 / 11) and an
  `AcquisitionRun.solvent` attribute (default `""`) for NMR runs.

- `ReferenceImport.writeToDataset` (Java),
  `-[TTIOReferenceImport writeToDataset:overwrite:error:]` (ObjC) —
  public counterpart to Python's `ReferenceImport.write_to_dataset`,
  closing the cross-language API parity gap on the reference-write
  path. Each language now has matching `readFromGroup` /
  `writeToDataset` symmetry. All three writers produce a
  byte-identical `/study/references/<uri>/` subtree (same `@md5`,
  `@reference_uri`, per-chromosome `@length`, and ZLIB-compressed
  UINT8 `data`); verified by structural comparison across Python,
  Java, and ObjC fixtures.

---

## [1.2.0] — 2026-05-08

### Added
- **`MSImage.mz_axis`**: shared m/z spectral axis on `MSImage` across
  Java, Python, and ObjC. Persisted as a 1-D FLOAT64 dataset under
  `/study/image_cube/mz_axis`. Required for imzML export of an
  `MSImage`-bearing `.tio`.
- **`MSImage.toPixelSpectra()` / `to_pixel_spectra()` / `-pixelSpectra`**:
  continuous-mode projection of the cube into per-pixel `(mz, intensity)`
  records suitable for `ImzMLWriter.write`.
- **`SpectralDataset.image()` / `.image` / `-msImage`**: accessor on the
  open dataset returning the materialised `MSImage` if `/study/image_cube`
  is present. Pattern mirrors the 1.1.0 `references()` accessor.
- **Python `SpectralDataset.write_minimal(image=...)`**: high-level
  kwarg writes the image cube alongside runs.
- **Python `MSImage.write_to(study_group)` / `MSImage.read_from(study_group)`**:
  standalone storage methods mirroring Java's `writeTo` / `readFrom`.
- **ObjC `TTIOPixelSpectrum`**: new value class for `-pixelSpectra` output.

### Backwards compatibility
- v1.1.x `.tio` files without `mz_axis` read as empty axis; the imzML
  exporter raises a clear error pointing at re-import.
- v1.1.x readers transparently skip the `mz_axis` dataset when reading
  v1.2.0-written files.

### Cross-language conformance
- New `python/tests/conformance/test_msimage_xlang.py` asserts byte-equal
  `mz_axis` payloads when written by Python and read back by Java + ObjC.
- Bug fix: `Hdf5Group.openDataset` (Java) now correctly handles N-D datasets,
  fixing a silent length-truncation that previously made Python-written
  `.tio` files unreadable from Java.

## [1.1.0] — 2026-05-06

Pure additive release. No wire-format change: `.tio` files written
by 1.0.0 are read identically by 1.1.0 and vice versa.

### Added

- `SpectralDataset.references()` (Java),
  `SpectralDataset.references` property (Python), and
  `[TTIOSpectralDataset references]` (ObjC) — enumerates embedded
  references at `/study/references/<reference_uri>/` for opened
  datasets, keyed by reference URI. Datasets written without
  embedded references (writer flag `embedReference = false`) return
  an empty map regardless of whether individual genomic runs carry a
  `referenceUri`. Cross-language parity verified by
  `python/tests/conformance/test_references_xlang.py` (9 directed
  pairs).
- `ReferenceImport.readFromGroup` (Java) /
  `ReferenceImport.read_from_group` (Python) /
  `+[TTIOReferenceImport readFromGroup:]` (ObjC) — factory that
  materialises a `ReferenceImport` from its on-disk group.

### Fixed

- ObjC writer's reference-embed path no longer requires `libttio_rans`
  to be available. Embedding `/study/references/<uri>/...` is pure HDF5
  I/O and now fires whenever `embedReference=YES` on a
  `TTIOWrittenGenomicRun`, matching Python's behavior. Signal-channel
  encoding via REF_DIFF_V2 still gates on the native lib (unchanged).
  Resolves the writer-gate asymmetry finding from Phase 0 Task 0.6.

### Changed

- Unified `@md5` attribute computation on
  `/study/references/<uri>/` to a single seq-only form across all
  writers and helpers. Previously, REF_DIFF_V2 auto-embed used
  `MD5(seq_a || seq_b || ...)` (sorted by name) while FASTA-import
  writers and the public canonical helpers
  (`compute_reference_md5` / `ReferenceImport.computeMd5` /
  `+[TTIOReferenceImport computeMd5WithChromosomes:sequences:]`)
  used `MD5(name_a || 0x0A || seq_a || 0x0A || ...)`. All three
  paths now agree on the seq-only form, which was already the
  authoritative on-disk digest. Existing v1.0.0 files written via
  REF_DIFF_V2 auto-embed are unchanged (their on-disk `@md5` was
  already seq-only). Existing v1.0.0 files written via FASTA-import
  retain their on-disk `@md5` verbatim through the v1.1.0
  `read_from_group` / `readFromGroup` path; only the auto-recompute
  fallback (when `md5=None` / `md5=null` / `md5:nil` is passed to
  the constructor) now produces a seq-only digest. Resolves the
  three-form `@md5` finding from Phase 0 Task 0.6.

### Notes

- ObjC has no canonical library-version constant; the version bump
  applies only to the Java pom and Python `__version__` /
  `pyproject.toml` metadata.
- The on-disk reference layout itself is unchanged from 1.0.0 —
  v1.1.0 only fills in the previously-missing read path. See
  `docs/format-spec.md` §10.10 (subsection "Reading embedded
  references") for the exact byte layout and the `@md5` form note.

---

## [post-v1.0.0 perf + parity tweaks — included in 1.1.0]

All correctness-neutral (same wire bytes, same on-disk container).
Headline numbers + reproducer instructions consolidated in
`docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md`
§11.

### Performance

- **24× FASTQ re-export speedup** (Python). The hot loop in
  `FastqWriter.write(GenomicRun, ...)` materialised one
  `AlignedRead` per record, which decoded cigar + mate triple
  for every read — fields FASTQ does not need. Now pre-fetches
  the whole `sequences` + `qualities` byte buffers + read-names
  list once, slices in-memory. 11K reads/s → 265K reads/s on
  1M reads × 100bp (commit `ae9441d`).
- **Java + ObjC FASTQ writer bulk-fetch parity** mirrors the
  same fix. Java now sustains ~750K reads/s on the same 1M
  workload; ObjC ~635K reads/s (commit `0f99852`). New
  microbenches: `FastqBulkBenchTest` (Java, opt-in via
  `-DTTIO_FASTQ_BENCH=1`) + `objc/Tools/obj/TtioFastqBench`.
- **Java transport genomic encode 33 → 235K reads/s (+612%)** at
  100K reads × 100bp (commits `758b340` + `701f310`). Two
  fixes: (1) memoised `GenomicRun.isMateInfoInlineV2()` after
  noticing the probe reopened the `mate_info` HDF5 group 3× per
  record (300K group opens at 100K reads, ~2.2s of pure
  framework overhead — ObjC already cached this via
  `_mateInfoLinkType`), and (2) eager-cached the M82 compound
  fall-through of `cigarAt` + bypassed per-record `AlignedRead`
  materialisation in `TransportWriter`. At 1M reads: 328K rps.
  Java is now ~40% faster than ObjC on this workload. New
  microbench: `TransportEncodeBenchTest`.
- **ObjC transport genomic encode 70 → 164K reads/s (+134%)**
  (commit `d5e2e25`). Same per-record `[grun readAtIndex:i]` →
  `dataUsingEncoding:` re-encode roundtrip Java had. Now bulk-
  fetches `wholeSequencesData` / `wholeQualitiesData` /
  `allReadNames` once. New microbench: `TtioTransportEncodeBench`.
- **Python + ObjC `cigar_at` eager-cache (parity with Java)**
  (commit `7ac32e4`). M82 compound fall-through no longer
  re-decodes per call. Python: 10 → 36K rps at 100K reads
  transport encode (+260%). ObjC: net-neutral on the test
  fixture but protective for any NSData-typed compound returns.
- **Byte-channel cache audit** (`GenomicRun.byteChannelSlice` /
  `-byteChannelSliceNamed:`). The codec-compressed path cached;
  the uncompressed path returned the raw HDF5 buffer per call,
  so `sequencesFull` / `-wholeSequencesData` warmups were
  silently a no-op for files written with `signal_compression =
  NONE`. Fixed in both Java + ObjC (commit `221611c`).

### Cross-language parity gates

- **nmrML 3-way probe parity** — `NmrMLProbe.java`,
  `TtioNmrMLProbe.m`, and a Python harness drive all three
  readers against synthetic + `bmse000325` inputs and assert
  bit-exact JSON for `numberOfScans` /
  `spectrometerFrequencyMHz` / `fidReal` / `fidImag` (commit
  `8c6b8b0`).
- **mzML 3-way probe parity** — `MzMLProbe.java`,
  `TtioMzMLProbe.m`, and `test_mzml_cross_lang_parity.py` cover
  synthetic + `tiny.pwiz.1.1.mzML` fixtures with full mz +
  intensity arrays plus precursor / polarity / RT scalars.

### mzML reader bug-fixes

- **Java**: `endElement("binary")` no longer skips spectra with
  empty `<binary></binary>` arrays (PSI-MS reference fixture
  intentionally tests this via its "spectrum with no data"
  userParam). 4-spectrum `tiny.pwiz` now reports 4 spectra (was
  3) (commit `01ca2b4`).
- **Python + ObjC**: `<referenceableParamGroupRef>` is now
  resolved. Both readers buffer cvParams under each
  `<referenceableParamGroup id="...">` and replay them when a
  spectrum / chromatogram cites the group via
  `<referenceableParamGroupRef ref="...">`. Polarity (and any
  other CV param) on referenced groups now reaches the
  per-spectrum surface (same commit).

### Documentation

- `docs/cross-language-matrix.md` gains entries for the two new
  probe-style parity tests + CLI inventory rows for the four
  new probe binaries.
- `docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md`
  §11 documents the post-v1.0.0 perf tweaks with reproducer
  invocations.

---

## [v1.0.0] — 2026-05-04 — first stable release

This is the first stable release of TTI-O. The format string is
`ttio_format_version = "1.0"`; container ABI, codec wire formats,
encryption envelope, and digital-signature canonicalisations are
contractually frozen at this point. Pre-v1.0 development was never
publicly released; that history lives in `git log`.

### Format

- HDF5-backed `.tio` container; opaque `study/` group with per-modality
  child groups (`ms_runs/`, `genomic_runs/`, `chromatograms/`,
  `nmr_runs/`, `image_cubes/`, …).
- Deterministic write order; the Python, Java, and Objective-C
  reference implementations all produce byte-identical output for the
  same input. Cross-language byte-equality is part of the contract,
  not a coincidence — see `pytest -m integration`.
- Feature-flag preamble (`ttio_features` JSON array attribute) for
  forward-compatible optional capabilities. ISA-Tab investigation
  linkage on every container.

### Codecs

| Id | Symbol               | Description                                          | Channels                                              |
|---:|----------------------|------------------------------------------------------|-------------------------------------------------------|
| 0  | NONE                 | Passthrough                                          | any                                                   |
| 1  | ZLIB                 | HDF5 deflate filter (level 6 default)                | any                                                   |
| 2  | LZ4                  | HDF5 filter id 32004 (~35× faster write than zlib)   | any                                                   |
| 3  | NUMPRESS_DELTA       | Numpress + delta encode (sub-ppm lossy)              | numeric MS m/z channels                               |
| 4  | RANS_ORDER0          | rANS order-0 entropy coder                           | sequences / qualities / cigars / integers             |
| 5  | RANS_ORDER1          | rANS order-1 entropy coder                           | sequences / qualities / cigars / integers             |
| 6  | BASE_PACK            | 2-bit ACGT pack with sidecar mask for IUPAC bases    | sequences                                             |
| 7  | QUALITY_BINNED       | Illumina-8 binning (lossy, CRUMBLE-derived)          | qualities                                             |
| 11 | DELTA_RANS_ORDER0    | Delta + rANS-O0                                      | sortable integer channels                             |
| 12 | FQZCOMP_NX16_Z       | CRAM-mimic adaptive quality (V4 only, magic `M94Z`)  | qualities                                             |
| 13 | MATE_INLINE_V2       | Inlined mate_info v2 (single channel)                | mate_info compound                                    |
| 14 | REF_DIFF_V2          | Reference-diff v2 (slice-based, embedded reference)  | sequences                                             |
| 15 | NAME_TOKENIZED_V2    | 8-substream multi-token columnar codec               | read_names                                            |

Ids 8, 9, 10 are reserved on the wire (Java enum ordinal stability)
but carry no live codec. Reader paths reject them with migration
errors. Codec wire formats are documented in `docs/codecs/*.md`;
per-channel pipeline wiring is documented in `docs/format-spec.md`
§10.4–§10.10.

### Modalities

- Mass spectrometry: LC-MS, MS-image cubes, ion mobility, profile +
  centroid spectra.
- Nuclear magnetic resonance: 1-D and native 2-D (HSQC, COSY, NOESY).
- Vibrational imaging: Raman, IR.
- UV-Vis spectra.
- Two-dimensional correlation spectroscopy (2DCOS).
- Chromatograms.
- Genomic alignment runs: full BAM/CRAM importer parity, per-record
  metadata, codec-aware channel wiring.

### Format I/O — FASTA / FASTQ

- **FASTA importer**: `FastaReader` reads reference genomes (for
  embedding at `/study/references/<uri>/`, paired with BAM/CRAM
  input) or unaligned reads (panels, target lists, quality-stripped
  reads → `WrittenGenomicRun` with SAM unmapped sentinels). gzip
  auto-detected via magic bytes regardless of extension.
- **FASTA exporter**: `FastaWriter` writes a `ReferenceImport` or a
  `WrittenGenomicRun` to FASTA with configurable line wrap
  (default 60 chars) and a samtools-compatible `.fai` index
  emitted alongside.
- **FASTQ importer**: `FastqReader` parses 4-line records into
  unaligned `WrittenGenomicRun` instances. Phred offset is auto-
  detected (`33` modern Illumina / Sanger vs `64` legacy
  Illumina); detected source recorded for round-trip planning.
  Internal storage normalises to Phred+33.
- **FASTQ exporter**: `FastqWriter` writes a run to FASTQ with
  Phred+33 default and Phred+64 selectable. The `0xFF` "qualities
  unknown" sentinel is mapped to Phred 0 (`!`) on output so the
  result is always parseable.
- **Cross-language byte equality**: Python, Java, and ObjC produce
  byte-identical FASTA + FASTQ output for the same input — proven
  by the `test_fasta_fastq_cross_language.py` 3-way harness.
- **CLIs**: Python `python -m ttio.tools.{fasta,fastq}_{import,export}_cli`,
  Java `FastaRoundTrip` / `FastqRoundTrip`, ObjC `TtioFastaRoundTrip`
  / `TtioFastqRoundTrip`.

### Encryption + signing

- **Per-AU encryption** (AES-256-GCM) on signal-channel datasets and
  compound-metadata payloads. Versioned wrapped-key blob carries DEK
  rotation history; envelope decryption supported via local key, KMS,
  or user-supplied callback.
- **Digital signatures**: HMAC-SHA256 (canonical) plus post-quantum
  ML-DSA via liboqs. Signatures verify identically across all three
  reference implementations.

### Language bindings

- **Python** (`pip install ttio`): full read/write/encryption/sign;
  ctypes wrapper for the native rANS / v2-codec library.
- **Java** (Maven Central `global.thalion:ttio`): full parity; JNI
  wrapper for the same native library.
- **Objective-C** (GNUstep): full parity; native library linked
  directly. `objc/Tools/MakeFixtures` produces the canonical
  cross-language reference fixtures.

### Cross-language guarantee

Byte-equal output for shared codec paths under the test corpora in
`data/genomic/` (NA12878 chr22, NA12878 WES, HG002 Illumina 2×250,
HG002 PacBio HiFi subset). Verified on every commit via
`pytest -m integration`; SHA-256 hashes match Python ↔ Java ↔
Objective-C.

### Native library

`libttio_rans` (CMake / clang) ships the v2 codec kernels (rANS,
ref_diff_v2, mate_info_v2, name_tokenized_v2, fqzcomp_nx16_z V4).
Mandatory at runtime for genomic-run write/read on all three
language bindings (`TTIO_RANS_LIB_PATH` env var, or `libttio_rans.so` /
`.dylib` / `.jni` on the loader search path).

### Transport — genomic bulk mode (Phase 2c-T)

- New packet types `BlobV2MateInfo` (0x09), `BlobV2RefDiff` (0x0A),
  `BlobV2NameTok` (0x0B) carry the verbatim v2 codec blobs
  (`mate_info/inline_v2`, `sequences/refdiff_v2`,
  `read_names/name_tok_v2`) on the wire. See
  `docs/transport-spec.md` §3.2 / §4.10–4.12 / §5.8 / §6.4.
- Stream-level feature flag `bulk_mode_v2_blobs` (required, no
  `opt_` prefix). Receivers that cannot honor verbatim blob
  injection refuse the stream.
- CLIs accept `--bulk` on encode: Python
  `python -m ttio.tools.transport_encode_cli --bulk`, Java
  `TransportEncodeCli --bulk`, ObjC `TtioTransportEncode --bulk`.
- Cross-language byte-identity verified by the 9-cell
  Python/Java/ObjC matrix in
  `python/tests/validation/test_phase_2c_t_bulk_mode.py`.
- Storage-provider parity: HDF5, memory://, sqlite://, and zarr://
  write paths all honor `bulk_v2_blobs` and write the verbatim
  blob bytes — see
  `python/tests/validation/test_phase_2c_t_storage_providers.py`.
- Measured speedup: receiver-side decode runs **1.36×–1.43× faster**
  in bulk mode (10K and 50K-read fixtures); encode is near-parity
  (≤3% delta), wire size grows ~4% from the additional blob
  packets. See
  `docs/benchmarks/2026-05-05-phase-2c-T-bulk-mode.md`.

### Cross-language nmrML reader parity

The Python `ImportResult` gained four nmrML acquisition-parameter
fields on 2026-05-05 (`spectrometer_frequency_mhz`,
`number_of_scans`, `fid_real`, `fid_imag`); Java and ObjC sibling
readers now surface the same fields:

- **Java** `NmrMLReader.NmrMLResult` exposes
  `spectrometerFrequencyMHz()`, `numberOfScans()`, `fidReal()`,
  `fidImag()`. The parser also accepts
  `<irradiationFrequency value="...">` directly inside
  `<acquisitionParameterSet>` (matches Python; previously
  required `<directDimensionParameterSet>`).
- **ObjC** `TTIONmrMLReader` now also exposes deinterleaved
  `fidReal` / `fidImag` `NSData` properties alongside the
  pre-existing `spectrometerFrequencyMHz` / `numberOfScans`.

### Native codec fixes

- **NAME_TOKENIZED_V2** (codec id 15): decoder MATCH path no
  longer rejects valid encoded blobs whose pool entry has a
  different total token count than the block's column shape.
  Surfaced by the production-corpus decode benchmark on real
  Illumina BAMs with mixed flowcell prefixes (e.g. `H2YHMBCXX`
  tokenises to 3 tokens vs `H2YT5BCXX`'s 5 tokens because of
  the internal digit). Permanent regression guard at
  `python/tests/test_name_tokenizer_v2_native.py::test_mixed_flowcell_token_count_regression`;
  minimal failing fixture preserved at
  `python/tests/fixtures/codecs/name_tok_v2_corrupt_94.txt`.
- **Bruker TDF importer**: `frame2retention_time` returned a 1-D
  ndarray under opentimspy ≥ 1.2 even for scalar input; the
  per-frame list comprehension produced a `(n, 1)` 2-D
  `retention_times` buffer that the writer rejected. Now passes
  the whole `frame_ids` array at once.
- **Zarr 3.x empty-chunk**: `ZarrProvider.create_dataset` now
  clamps chunk dims to ≥ 1 so empty datasets (length == 0) build
  cleanly under zarr-python 3.x.

### Format support — Bruker .tsf

`ttio.importers.bruker_tdf.read_metadata()` now recognises both
`analysis.tdf` (TIMS) and `analysis.tsf` (non-TIMS Bruker QTOF /
MALDI) `.d` directories. The SQLite metadata schema is shared,
so frame counts / retention times / instrument-vendor strings
parse identically. Full per-frame `read()` is TDF-only in v1.0
(opentimspy is TDF-only); calling it on a `.tsf` directory raises
`BrukerTDFUnavailableError` with a pointer at the
`msconvert` → mzML workaround.

### Performance — benchmark suites + microbench tooling

Three new perf harnesses for release-to-release tracking:

- **`python/tests/stress/test_fasta_fastq_benchmark.py`** —
  five scenarios per fixture size (FASTQ export / import,
  FASTA export / import, FASTQ → `.tio` → FASTQ round-trip)
  at 1K, 10K, plus opt-in 100K and 1M reads via
  `TTIO_INCLUDE_LONG_TAIL=1`.
- **`python/tests/stress/test_production_corpus_benchmark.py`** —
  BAM → `.tio` → decode-all-reads cycle against the real corpora
  under `data/genomic/` (synthetic, na12878 chr22, na12878 WES,
  hg002 Illumina subset, hg002 PacBio). The full 1.6 GB
  hg002 chr22 BAM is opt-in via `TTIO_INCLUDE_FULL_CORPUS=1`.
- **`global.thalion.ttio.tools.Benchmark` (Java) +
  `TtioBenchmark` (ObjC)** — pair with the Python harnesses to
  give cross-language perf-tracking parity. Both emit the same
  JSON schema so a single `jq` over the three result files
  diffs cleanly.

Headline numbers consolidated in
`docs/benchmarks/2026-05-05-v1.0-comprehensive-perf-report.md`.

### Build + dev workflow

- **`scripts/dev-setup.sh`** — one-shot Python developer setup:
  builds `libttio_rans.so` + JNI wrapper, installs the package
  with the broadest test extras, prints required env-var
  exports. PEP 668 (Ubuntu 24.04+ externally-managed) friendly.
- **`scripts/fetch-vendor-fixtures.sh`** — downloads + sha256-
  verifies the public Thermo `small.RAW` (MIT, ~1.5 MB) and
  Bruker `diaPASEF.d` (Apache-2.0, ~1 MB) fixtures from upstream
  repos. Manifests pinned at `data/vendor/{thermo,bruker}/*.sha256`.
- **CI** (`.github/workflows/ci.yml`):
  - All Python jobs (`python-test`, `python-validation`,
    `python-stress`) now build the native rANS library + JNI
    wrapper before running pytest. Previously skipped ~90 v2-codec
    tests silently because the runtime library was never present.
  - New `python-vendor-fixtures` job exercises the Bruker TDF +
    Thermo `.raw` integration paths on every push/PR (mono +
    ThermoRawFileParser v1.4.5 + sha256-pinned fixtures).
- **`CONTRIBUTING.md`** added — top-level entry point with
  quick-start, repo layout, per-language test commands, optional
  fixture flow, code style notes.
