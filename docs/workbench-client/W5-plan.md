# W5 plan — tio-browser → WC Desktop GUI

Companion to [`docs/workbench-client-workplan.md`](../workbench-client-workplan.md).
Spells out the eight sub-phases that deliver spec §8.1's GUI
component list inside the existing
[`tio-browser/`](../../tio-browser) JavaFX desktop app.

## Status (2026-05-19): W5.0 in flight

W1+W3+W4 Java SDK code (`global.thalion.ttio.workbench.*`) is
merged on `main` but unreleased — `java/pom.xml` is still at 1.2.0,
the artifact tio-browser pins against. W5.0 lifts that pin and
opens the door for W5.1+ to wire the SDK into JavaFX panels.

## Single-repo, not cross-repo

The earlier workplan draft described tio-browser as a separate
repo (`DTW-Thalion/tio-browser`). Corrected 2026-05-19:
`tio-browser/` is a sibling directory of `java/` in this repo. No
GitHub release tag or Maven Central publication is required to
unblock W5 work; the local `mvn install` in `java/` populates `~/.m2`
with `global.thalion:ttio:1.3.0` and tio-browser resolves it via its
existing `${ttio.version}` property.

## Existing tio-browser surface (carry-forward)

tio-browser 1.4.1 already ships:

- `MainWindow` (BorderPane shell) with menu / toolbar / split /
  status bar.
- Local file open (File → Open + drag-drop `.tio`).
- `DatasetTreeView` + `DetailPane` + `AbstractDetailTab`
  interface (existing tabs: Overview, FeatureFlags, Encryption,
  Provenance, MS/NMR/Raman headers, Spectrum/Chromatogram plots,
  Read inspector, Channel hex).
- `importers/ImportDialog` (13 formats) — Phase 8.
- `exporters/ExportDialog` (11 formats) — Phase 9.
- `transport/DownloadDialog` + `transport/UploadDialog` — Phases 10/11.
  These speak the **reference** transport protocol (no auth, no
  workbench handshake). W5.3 supersedes them with workbench-aware
  versions; the reference-protocol dialogs stay for local
  reference-server testing.

W5 adds a new `tio-browser/.../workbench/` package alongside
`transport/`, leaving the reference-protocol surfaces intact.

## Sub-phases

Each sub-phase is one PR (or two for the larger components). Phases
land sequentially; W5.7 finalises with a tio-browser version bump
and the end-to-end smoke.

| W#   | Title | Estimated LOC | Primary spec §8.1 component |
|------|-------|---------------|----------------------------|
| W5.0 | Kickoff: TTI-O Java SDK 1.3.0 + tio-browser pin bump + plan doc (**this PR**) | ~120 | — (admin) |
| W5.1 | Connection Manager + WorkbenchSession plumbing | ~600 | Connection Manager |
| W5.2 | Container Browser (remote tree) | ~500 | Container Browser |
| W5.3 | Upload/Download Manager + Selective Access Panel | ~700 | Upload/Download Manager, Selective Access Panel |
| W5.4 | Cohort Query Builder | ~400 | Cohort Query Builder |
| W5.5 | Pipeline Launcher + Job Monitor | ~500 | Pipeline Launcher, Job Monitor |
| W5.6 | Interactive Session Launcher (open in system browser) | ~250 | Interactive Session Launcher |
| W5.7 | Encoding Panel + Export Panel + tio-browser 1.5.0 bump + end-to-end smoke | ~400 | Encoding Panel, Export Panel |
| **Total** | | ~3,470 | 9 of 9 §8.1 components |

## W5.0 — kickoff (this PR)

**Touches:** `java/pom.xml`, `tio-browser/pom.xml`,
`docs/workbench-client-workplan.md`, this file, `CHANGELOG.md`.

- Bump `java/pom.xml` `<version>` 1.2.0 → 1.3.0. The 1.3.0 line
  marker captures the W1+W3+W4 workbench-client Java surface.
  Library SemVer: minor bump (new public surface, no breaking
  changes to existing TTI-O format APIs).
- Bump `tio-browser/pom.xml` `<ttio.version>` 1.2.0 → 1.3.0 in
  lockstep. tio-browser does *not* yet use the new classes — that's
  W5.1+ — but the dependency pin is moved now so subsequent PRs
  don't conflate "wire the import" with "bump the dep."
- Correct the workplan W5 section's cross-repo language.
- Add this plan file.
- CHANGELOG entry under `[Unreleased]`.

**Acceptance:**

- [x] Java CI green at version 1.3.0 (no test changes).
- [ ] Local `cd java && mvn install -DskipTests -Djacoco.skip=true`
      followed by `cd tio-browser && mvn -q test` continues to pass
      against the bumped pin (deferred: requires JDK 22+; CI exercises
      release-shaded-jar.yml on tag push).

## W5.1 — Connection Manager + WorkbenchSession plumbing

**Goal:** the foundation panel everything else depends on. A modal
"Connect to workbench server…" dialog drives
`WorkbenchClient.connect(serverUrl, PasswordTotpAuth(...))`,
caches the resulting session in `MainWindow`, and updates the
status bar with a connection indicator (`disconnected` /
`connecting` / `connected: alice@biobank.thalion.org`).

**Deliverables:**

- `workbench/ConnectionManager.java` — `connect()`, `disconnect()`,
  `currentSession()`, `addSessionListener(SessionListener)`. Holds
  the `WorkbenchClient` instance; null when disconnected.
- `workbench/LoginDialog.java` — JavaFX `Dialog<Session>` with server
  URL / username / password / TOTP fields. Calls
  `ConnectionManager.connect(...)` and returns the established
  session.
- `workbench/StatusIndicator.java` — small status-bar Node showing
  connection state + colour swatch (red/yellow/green).
- `MainWindow.java` — File menu adds "Workbench → Connect…",
  "Workbench → Disconnect", "Workbench → Status…". Status bar
  gains the indicator.
- Tests: TestFX `ConnectionManagerTest` exercising connect/disconnect
  state transitions with a stubbed `WorkbenchClient`. `LoginDialogTest`
  exercising the form's validation rules (empty fields → button
  disabled, TOTP not 6 digits → field highlighted).

**Acceptance:**

- [ ] `Workbench → Connect…` opens the dialog; valid credentials
      against a live workbench-server daemon produce a green status
      indicator and `connected: <user>@<host>` label.
- [ ] `Workbench → Disconnect` clears the session and flips the
      indicator to red.
- [ ] State survives focus loss (i.e., session token isn't lost
      when the dialog closes).

## W5.2 — Container Browser

**Goal:** a tree view of `GET /v1/containers` showing project →
container → manifest hierarchy. Sort by upload time / size /
project. Per-container drill-down (Container manifest tab in the
detail pane).

**Deliverables:**

- `workbench/ContainerBrowser.java` — TableView<ContainerSummary>,
  per-column filtering, sort, double-click → load into the existing
  `DetailPane`.
- `workbench/RemoteContainerOpenTask.java` — JavaFX `Task<OpenDataset>`
  fetching the container metadata + opening it via the existing
  `DatasetOpenTask` path (download-on-demand or streaming).
- `MainWindow.java` — split pane gains a tab/section "Remote
  containers" alongside "Local files". A unified
  `DataSourceTree` may emerge here but is OK to stay separate for
  v1.0.

**Acceptance:**

- [ ] Browser shows containers from `GET /v1/containers` paginated.
- [ ] Filtering by `project=` reduces the list.
- [ ] Selecting a container shows its manifest in the detail pane.

## W5.3 — Upload/Download Manager + Selective Access Panel

**Goal:** spec §8.1's two largest GUI surfaces. Queue-based upload
and download with progress bars; visual filter builder for
selective downloads.

**Deliverables:**

- `workbench/TransferManager.java` — a service holding upload +
  download queues, each item with state machine (pending /
  uploading / paused / completed / failed). Drives
  `WorkbenchTransportClient`.
- `workbench/TransferQueueView.java` — ListView of transfers with
  inline progress bar, per-row pause/cancel buttons.
- `workbench/UploadStartDialog.java`,
  `workbench/DownloadStartDialog.java` — modal dialogs to start a
  new transfer.
- `workbench/SelectiveAccessPanel.java` — embedded in the download
  dialog. RT range / MS level / polarity / precursor m/z /
  chromosome / position range / max AU. Builds the `filters` dict
  passed to `WorkbenchTransportClient`.
- `MainWindow.java` — "Workbench → Transfers…" opens the queue view.

**Acceptance:**

- [ ] Upload a `.tio` to the daemon, observe progress, get a
      container URI back.
- [ ] Download with filter `chromosome=chr6` returns a smaller
      `.tis` than the unfiltered case.
- [ ] Pause + resume an upload preserves the `au_sequence` state.

## W5.4 — Cohort Query Builder

**Goal:** spec §6.2 predicate composition UI driving `CohortClient`.

**Deliverables:**

- `workbench/CohortQueryBuilder.java` — tree-style predicate
  composition (root = AND/OR/NOT composite, leaves =
  container_field / subject_field / sample_field / phenotype with
  the 9 operators). Drag-drop reorder, per-leaf typed input
  (date / number / string).
- `workbench/CohortResultView.java` — TableView of the result set;
  "Save as cohort…" button calls `CohortClient.create(name,
  predicate)`.
- `MainWindow.java` — "Workbench → Cohorts → New…", "Workbench →
  Cohorts → Open…".

**Acceptance:**

- [ ] Build a 3-clause cohort, run it, see the container list.
- [ ] Save the cohort by name; reload it from "Workbench → Cohorts
      → Open…".

## W5.5 — Pipeline Launcher + Job Monitor

**Goal:** spec §7.2 + §7.3 surfaces.

**Deliverables:**

- `workbench/PipelineLauncher.java` — pipeline picker (loaded from
  `GET /v1/pipelines`), input binding form (container selection
  + parameter form driven by the pipeline definition's parameter
  schema), submit button calling `PipelinesClient.submit(...)`.
- `workbench/JobMonitor.java` — dashboard of active/queued/completed
  jobs; per-row "Tail events" opens an SSE-driven log view via
  `JobsClient.events(jobId)`.
- `workbench/JobEventsView.java` — scrolling log of `event:`/`data:`
  frames with terminal-state detection.
- `MainWindow.java` — "Workbench → Pipelines → Launch…",
  "Workbench → Jobs…".

**Acceptance:**

- [ ] Launch the daemon's built-in shell engine, observe the job
      appear in the monitor, see live state transitions.
- [ ] Cancel a running job; status transitions to `cancelled`.
- [ ] A failed job's events view shows the error frame.

## W5.6 — Interactive Session Launcher (open in system browser)

**Goal:** spec §7.4 step 3 — researcher creates a session and
attaches via their preferred terminal/browser. Per workplan open
question 2 Decision: open the attach URL in the operator's
system browser (option b — robust, Jupyter-version-agnostic). The
embedded WebView (option a) is a follow-up.

**Deliverables:**

- `workbench/SessionLauncher.java` — engine picker, project
  picker, image entry, bind-mount table, command entry. Calls
  `SessionsClient.create(...)` and surfaces the resulting
  `wss://` attach URL with a "Open in browser" button
  (`Desktop.browse(URI)`).
- `workbench/SessionList.java` — TableView<Session> with status,
  attach button (re-opens URL), terminate button.
- `MainWindow.java` — "Workbench → Sessions → Launch…",
  "Workbench → Sessions → List…".

**Acceptance:**

- [ ] Launch a shell session, get an attach URL, clicking "Open in
      browser" launches the default browser.
- [ ] Terminate from the list view; status transitions to
      `terminating` then `terminated` within the cancel-grace
      window.

## W5.7 — Encoding + Export Panels + smoke + version bump

**Goal:** the remaining two §8.1 components, plus the
end-to-end gate.

**Deliverables:**

- `workbench/EncodingPanel.java` — source file selection, format
  detection (reuses Phase 8 `FormatSniffer`), codec selection,
  compression level, per-layer annotation, reference-genome picker.
  Drives the existing `importers/ImportTask` → uploads via the W5.3
  manager.
- `workbench/ExportPanel.java` — layer picker, target format,
  server-side vs client-side export choice. Server-side calls a
  pipeline (W5.5); client-side downloads + transcodes.
- `tio-browser/pom.xml` bump 1.4.1 → 1.5.0 (workbench-aware GUI
  major surface).
- `CHANGELOG.md` — full W5 entry under a new `[1.5.0]` section.
- `tio-browser-W5-smoke-test/` (or similar in `src/test/java/...`) —
  end-to-end TestFX smoke spinning up a workbench-server in
  Testcontainers (or a manual operator-driven test if Testcontainers
  isn't viable on the GHA matrix), driving: login → browse →
  upload → submit pipeline → observe job → download result.

**Acceptance:**

- [ ] Every component in spec §8.1 has a working tio-browser panel.
- [ ] The smoke test (manual or automated) passes: one operator
      completes UC-01 → UC-04 → UC-07 → UC-09 → UC-04 entirely in
      the GUI.

## Cross-language byte-equivalence

W5 doesn't add new wire surfaces — every byte the GUI emits goes
through the W1+W3+W4 Java SDK, which already shares anchor
literals with the Python SDK (W1 handshake, W3 cohort predicate,
W4 attach handshake). No new cross-language anchors needed unless
W5 surfaces a new wire shape (e.g., a pipeline-parameter
serialization format would need pinning in both Python and Java
test suites).

## Deferred to W5 follow-up / W6

- **Embedded Jupyter notebook in JavaFX WebView** (spec §7.4 step 3
  option a). Decision 2 in workplan defers this; W5.6 ships
  system-browser attach.
- **Live workbench-server in CI** for the end-to-end smoke. Same
  shape as the W1/W3/W4 follow-ups — needs to vendor the
  workbench-server Docker image. Tracked as a single cross-W
  follow-up.
- **Federation client UI** — spec §12.3 marks federation as v1.1+.
  No GUI surface in v1.0.
