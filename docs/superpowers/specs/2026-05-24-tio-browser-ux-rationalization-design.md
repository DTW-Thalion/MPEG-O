# tio-browser UX Rationalization — Design

**Status:** Draft for review
**Date:** 2026-05-24
**Author:** Todd White / The Thalion Initiative
**Scope:** `tio-browser/` JavaFX desktop application
**Related:** `docs/TTI-O_Workbench_FunctionalSpec_v0.2.docx` §8.1 (WC Desktop GUI)

## 1. Context and Problem

tio-browser today exposes its capabilities as a flat catalogue of menu
items and dialogs. Every action is reachable, but the application has
no information architecture organizing those actions around the user's
actual jobs. Observed problems:

- **Seven top-level menus** (`File`, `Import`, `Export`, `Transport`,
  `Workbench`, `Tools`, `Help`), three of which contain a single item.
- **Duplicate upload/download paths.** `Transport → Upload…` and
  `Workbench → Upload to workbench…` invoke different code paths
  (`transport.UploadDialog` vs `workbench.UploadStartDialog`); the
  toolbar `Upload…` always picks the legacy `Transport` one regardless
  of whether the user is connected to a workbench server.
- **`Workbench` menu is a 14-item junk drawer.** Each item opens its
  own top-level `Stage` window; the user accumulates floating windows
  with no shared frame.
- **Local Encoding (UC-01) has no home.** It only appears as `Workbench
  → Encode + upload…`, even though UC-01 is explicitly a local-only
  operation in the spec.
- **The Selective Access Panel** is buried inside the Download dialog
  even though the spec lists it as a first-class §8.1 component.
- **Progress indicators are decorative** in several places — the user
  cannot derive a quantitative ETA from what is shown.
- **No empty / onboarding state.** With no file open and no server
  connection, the user faces an empty tree and an empty detail pane
  with no guidance on what to do.

The current `DetailPane` already does context-sensitive tabs well
(`AbstractDetailTab.appliesTo(node)`), and the dataset tree is the
right primary surface for inspecting a file. The fix is structural,
not a wholesale rewrite of inspection internals.

## 2. Goals

- Re-organise the surface around tasks the user is actually doing,
  using the spec's §8.1 components as the canonical list.
- Eliminate every duplicate action path; one action, one place.
- Surface connection state, transfer progress, and current dataset
  context persistently rather than burying them behind menus.
- Make every long-running operation report quantitative progress with
  an ETA where one is computable.
- Provide a discoverable empty state for first-time and disconnected
  users.

## 3. Non-Goals

- No changes to the workbench client SDK (`ConnectionManager`,
  `TransferManager`, REST/WebSocket clients).
- No changes to the dataset model (`OpenDataset`, `DatasetTreeNode`,
  `DatasetTreeBuilder`) or to the in-process detail-tab mechanism
  (`AbstractDetailTab.appliesTo`).
- No new wire protocol, no new server features. This is a desktop UX
  refactor against the existing workbench server API surface.
- No new external dependencies (no new JavaFX themeing libraries, no
  CSS frameworks).
- No telemetry, no auto-update, no crash reporter — those remain out
  of scope as today.

## 4. Architecture — Shell

The main window is a `BorderPane` with four persistent regions:

```
┌────────────────────────────────────────────────────────────────┐
│ Top header bar   (~36 px)                                      │
├──┬─────────────────────────────────────────────────────────────┤
│Ra│                                                             │
│il│        Active workspace content                             │
│  │        (fills remaining width and height)                   │
│  │                                                             │
├──┴─────────────────────────────────────────────────────────────┤
│ Transfer strip   (~32 px, collapses when no transfers)         │
└────────────────────────────────────────────────────────────────┘
```

### 4.1 Top header bar

Slim row, fixed height ~36 px. Contents left-to-right:

- **App title** — `tio-browser` (read-only label).
- **Connection chip** — a single clickable region showing one of:
  - `⬤ workbench: connected (alice@biobank.thalion.org)` when an
    authenticated session is active. Click opens a popover with
    `Disconnect`, `Switch account…`, `View session details`.
  - `○ workbench: offline` when no session. Click opens the
    `LoginDialog`.
  - `⟳ workbench: connecting…` during handshake.
- **Settings (⚙)** — icon button, opens a settings popover (theme
  toggle placeholder; reserved for future use).
- **Help (?)** — icon button, opens the `Help` menu as a popover
  (`About`, `User guide`, `Diagnostics…`).

The connection chip is the single source of truth for workbench
session state. It binds to `ConnectionManager.instance()` via the
existing `ConnectionListener` mechanism.

### 4.2 Left activity rail

Fixed-width column ~48 px. Four icon buttons stacked top-aligned,
single-selection (radio behaviour). Icons + tooltips only — no labels
under the icons.

| Icon | Tooltip            | Workspace key |
|------|--------------------|---------------|
| 📁    | Containers         | `containers` |
| 🔬    | Cohorts            | `cohorts` |
| ⚙     | Jobs & Sessions    | `jobs` |
| ⇅     | Transfers          | `transfers` |

The currently-selected button has a visible selection indicator
(e.g. a left-edge accent bar matching the brand colour, or
high-contrast background). Hover state shows the tooltip after
~600 ms via JavaFX `Tooltip` with a short show-delay.

A `Workspace` interface owns its content; the shell holds a
`Map<String, Workspace>` and swaps the centre region by setting
`root.setCenter(workspace.node())`. Each workspace is constructed
eagerly at app start (so state is preserved across switches) but its
heavy data loads are lazy (first-show triggers initial query).

### 4.3 Centre content area

Fills the remaining width and height. Contents are entirely owned by
the active workspace. The shell does not impose internal layout on
workspaces; each one builds its own `SplitPane`, `BorderPane`, or
similar.

### 4.4 Bottom transfer strip

Fixed height ~32 px when visible. Single-line summary:

```
↑ sample_001.tio  41% · 1.2/2.8 GB · 18.4 MB/s · ETA 1m 27s  [view all]
```

When more than one transfer is active, shows a rollup:

```
3 transfers active · ↑ 22.4 MB/s · ↓ 4.1 MB/s            [view all]
```

`[view all]` is a click target that switches the rail to `transfers`.

The strip auto-hides (height collapses to 0) when
`TransferManager.activeTransfers().isEmpty()`.

### 4.5 Menus

Two real menus on the menu bar:

- **File**
  - Open… (Ctrl+O)
  - Open Recent ▸ (last 8 paths, persisted in user prefs)
  - Encode… (Ctrl+E)
  - Import…
  - Export…  (disabled when no dataset open)
  - Save As…  (disabled when no dataset open)
  - ─
  - Close (Ctrl+W)
  - Exit (Ctrl+Q)
- **Help**
  - About
  - User guide
  - Diagnostics…  (opens existing modal `DiagnosticsDialog`)

All `Workbench → *` menu items, the top-level `Import`, `Export`,
`Transport`, `Tools` menus, and the entire current `ToolBar` are
removed. The actions live in their owning workspace.

## 5. The Four Activities

Each activity below specifies: purpose, components, the empty /
loading / error states, what existing class it replaces, and how
state is preserved across workspace switches.

### 5.1 Containers (📁)

**Purpose:** Single surface for inspecting any container the user has
access to, whether on local disk or on a connected workbench server.
Replaces the current main-window file tree, the current
`ContainerBrowser` window, and the workbench `Connect/Disconnect`
menu entries.

**Layout:** `SplitPane` (horizontal, default divider 30 %):

- **Left:** Unified containers tree (`UnifiedContainerTreeView`).
- **Right:** Detail pane — the existing `DetailPane` with
  `AbstractDetailTab`s, extended with new tabs that apply to server
  container nodes.

**Unified tree node hierarchy:**

```
Root (hidden)
├── 📂 Local
│   ├── <open file>: sample_001.tio        [LocalOpenFileNode]
│   │   └── (existing DatasetTreeNode subtree built by
│   │        DatasetTreeBuilder.build())
│   ├── Recent ▸                          [LocalRecentGroupNode]
│   │   ├── cohort_42.tio
│   │   └── …
│   ├── + Open file…                       [LocalOpenActionNode]
│   ├── + Encode…                          [LocalEncodeActionNode]
│   └── + Import…                          [LocalImportActionNode]
└── ☁ Servers
    ├── alice@biobank.thalion.org          [ServerRootNode]
    │   ├── Project: ADNI_cohort (245)     [ServerProjectNode]
    │   └── Project: PD_longitudinal (87)
    └── + Connect another server…          [ServerConnectActionNode]
```

`ServerProjectNode`s are leaves in the tree — they do **not** expand
into per-container children. Containers are not navigated in the
tree; they live in the right-side `ProjectListingTab` (paged table)
that appears when a project is selected. Container detail is reached
by clicking a row in that table, which selects an in-memory
`ServerContainerNode` and switches the detail pane to
`ServerContainerOverviewTab`. This keeps the tree small and
predictable; paging belongs in tables, not trees.

Action-style nodes (`+ Open file…`, `+ Encode…`, `+ Import…`,
`+ Connect another server…`) render with a distinct italic style and
no expand triangle; clicking them invokes the corresponding action
directly (open file chooser, open EncodingPanel modal, open
ImportDialog, open LoginDialog respectively).

The `Local` branch always shows even when no file is open — `Recent`
and the three `+ …` action nodes serve as the empty-state CTA.

The `Servers` branch shows `+ Connect another server…` when no
session exists. After login it expands to show the authenticated
server's projects.

**Detail pane:** keeps the existing `DetailPane` + `register(tab)`
mechanism unchanged. New tabs:

- `LocalRootInfoTab` — shown when the `Local` group node is selected
  (recent-files list with click-to-open, big `Open file…`,
  `Encode…`, `Import…` buttons).
- `ServerContainerOverviewTab` — shown when a `ServerContainerNode`
  is selected. Shows the server-side container metadata (manifest,
  layer list with codecs, encryption status, provenance summary),
  plus an action row: `Download…`, `Selective download…`,
  `Export… (server-side)`, `Run pipeline…`.
- `ProjectListingTab` — shown when a `ServerProjectNode` is selected.
  Shows the paged container table for that project.

Existing tabs (`OverviewTab`, `MsHeadersTable`, `NmrHeadersTable`,
`RamanHeadersTable`, `GenomicHeadersTable`, `ReadInspectorTab`,
`SpectrumPlotTab`, `ChannelHexTab`, `ChromatogramPlotTab`,
`ChromDistributionView`, `ReferenceTab`, `IdentificationsTab`,
`QuantificationsTab`, `ProvenanceTab`, `FeatureFlagsTab`,
`EncryptionTab`) continue to apply to local `DatasetTreeNode` types
exactly as today, via their existing `appliesTo()` predicates.

**Action affordances on tree nodes:** right-click context menu on
each node kind, matching its capability:

| Node kind                | Right-click actions |
|--------------------------|---------------------|
| `LocalOpenFileNode`      | Save As…, Close, Export…, Encode-derived… |
| `ServerContainerNode` (a row in the `ProjectListingTab` table — not a tree node) | Download…, Selective download…, Export (server-side)…, Run pipeline…, Copy URI, View metadata |
| `ServerProjectNode`      | New cohort from project…, Refresh |
| `ServerRootNode`         | Disconnect, Refresh, Settings |
| Action `+ …` nodes       | (single-click only — no context menu) |

**States:**

- *Empty (cold start):* tree shows the static skeleton above. Detail
  pane shows the `LocalRootInfoTab` content (recent-files list +
  three big buttons). No error.
- *Loading server projects:* under each `ServerRootNode`, a single
  child `Loading…` row with an indeterminate spinner; replaced when
  the `GET /v1/projects` call returns.
- *Server query failure:* the server node shows a `⚠ <message>` child
  row with a `Retry` action.
- *Switching connections:* the previous server's subtree is replaced;
  the local subtree is untouched. Tab selection in the detail pane is
  preserved if `appliesTo()` still holds for the new selection,
  otherwise reset to the first applicable tab.

**State persistence across rail switches:** workspace caches its
tree-view expansion state and selection. On return, the same node is
selected and the same detail tab is shown.

**Replaces (deletions / renames):**

- `MainWindow.buildMenuBar()` `File` / `Import` / `Export` /
  `Transport` / `Workbench` / `Tools` menus collapse to the new
  `File` + `Help` per §4.5.
- `workbench.ContainerBrowser` (top-level `Stage`) — its table moves
  into `ProjectListingTab`; the `Stage` class is deleted.
- `workbench.LoginDialog` — kept as a modal but invoked from the
  connection chip or from `+ Connect another server…`, not from a
  menu item.

### 5.2 Cohorts (🔬)

**Purpose:** Build, save, and use cohort queries that span server
projects.

**Layout:** `BorderPane`:

- **Left (~25 %):** Saved-cohorts list (`SavedCohortsList`).
  Lists `GET /v1/cohorts` results; right-click row gives
  `Open`, `Rename`, `Delete`, `Submit to pipeline…`.
- **Centre:** Query builder pane — the existing
  `workbench.CohortQueryBuilder` content (`VBox` of predicates,
  preview-count toggle, pagination controls) embedded directly. The
  surrounding `Stage` is removed.
- **Bottom (~30 %):** Result preview table — the matching subjects /
  containers; right-click row gives `Open container` (jumps to
  Containers workspace with that node selected), `Add to pipeline`
  (jumps to Jobs & Sessions, pre-fills the launcher).

**States:**

- *Disconnected:* whole pane shows a single CTA: "Connect to a
  workbench server to build cohort queries." with a `Connect…`
  button (opens `LoginDialog`).
- *Connected, no saved cohorts:* left list shows "(no saved
  cohorts)". Builder is usable.
- *Query running:* result table shows a progress overlay with
  `Loading… <N> rows so far`.
- *Query error:* result table shows the error message + `Retry`.

**Replaces:** `workbench.CohortQueryBuilder` (top-level `Stage`); its
content moves here, the `Stage` wrapper is deleted.

### 5.3 Jobs & Sessions (⚙)

**Purpose:** Submit and monitor compute work (batch jobs and
interactive sessions).

**Layout:** `SplitPane` (vertical, default divider 60 % / 40 %):

- **Top: Jobs.** Header row: `New job…` button → opens the existing
  `PipelineLauncher` modal. Below: jobs table (the existing
  `JobMonitor` content). Selecting a row reveals a detail panel on
  the right with status, parameters, logs (the existing
  `JobEventsView` content embedded, not its own `Stage`).
- **Bottom: Interactive sessions.** Header row: `New session…`
  button → opens the existing `SessionLauncher` modal. Below:
  sessions table (the existing `SessionList` content). Selecting a
  row shows session detail + `Connect`, `Suspend`, `Terminate`
  actions.

**States:**

- *Disconnected:* whole pane shows the same Connect CTA as Cohorts.
- *Connected, no jobs:* table shows "(no jobs)"; `New job…` button
  enabled.
- *Submitting a job:* `New job…` modal shows quantitative progress
  during file uploads (if any inputs are local).
- *Job failed / cancelled:* row shows the terminal status; logs
  remain accessible.

**Replaces:** `workbench.JobMonitor`, `workbench.SessionList`,
`workbench.JobEventsView` (their `Stage` wrappers are deleted; their
content moves here). `PipelineLauncher` and `SessionLauncher`
remain as modals invoked from this workspace.

### 5.4 Transfers (⇅)

**Purpose:** The single point for all `.tis` transfers — uploads and
downloads, session-based and anonymous-URL.

**Layout:** `BorderPane`:

- **Top:** `Start new transfer…` button + filter (All / Active /
  Completed / Failed) + a `Clear completed` button.
- **Centre:** Transfer queue table (the existing
  `workbench.TransferQueueView` table). Columns: direction
  (↑/↓), name, project / URL, progress (bar + numeric line per
  §6), state, started, finished.
- **Right slide-out (on row selection):** transfer detail showing
  the full `ProgressReport` history, the originating dialog
  parameters, and `Pause`, `Resume`, `Cancel`, `Retry` actions
  (whichever are valid for the current state).

**`Start new transfer…` modal — unified `TransferStartDialog`:**

A single new dialog replacing four existing ones
(`transport.UploadDialog`, `transport.DownloadDialog`,
`workbench.UploadStartDialog`, `workbench.DownloadStartDialog`).

Structure (top-to-bottom):

1. **Direction:** radio: `Upload` / `Download`.
2. **Source / target:** when `Upload`, a "Local `.tio`" file picker;
   when `Download`, a "Save to local `.tio`" file picker (with
   default name derived from URI).
3. **Server scope:** radio:
   - *Connected workbench* (default when a session exists). Shows the
     active session host and lets the user pick project + (for
     download) container URI.
   - *Anonymous URL* (default when offline; behind an "Advanced"
     expander when connected). Plain URL text field (`ws://` /
     `wss://` / `http://` / `https://`) + optional Bearer token. This
     covers the legacy `transport.*Dialog` use cases.
4. **Selective access (download only):** the existing
   `SelectiveAccessPanel` content embedded inline. Run-kind toggles,
   dataset-id list, RT range (MS), MS level, polarity, m/z range,
   chromosome + position range (genomic), max AU count.
5. **Options:** per-packet CRC-32C checksum checkbox, bulk-mode-v2
   checkbox (upload only, enabled when the source contains v2-encoded
   genomic blobs).
6. **Submit / Cancel.**

On submit, the dialog enqueues a `Transfer` into `TransferManager`
and closes; progress is then visible in the queue.

**States:**

- *Empty (no transfers ever):* table shows "(no transfers yet)";
  big `Start new transfer…` button centred.
- *No connection, no anonymous URL:* the submit button is disabled
  with an inline hint "Connect to a server, or expand Advanced for
  anonymous URL upload/download."
- *Transfer failed:* row state = `Failed`, with the error message
  inline + a `Retry` action.
- *Transfer paused / stalled:* state column reflects it; progress
  line shows `stalled — last activity 12s ago` per §6.

**Replaces:** `workbench.TransferQueueView` (content kept, `Stage`
removed), `workbench.UploadStartDialog`,
`workbench.DownloadStartDialog`, `transport.UploadDialog`,
`transport.DownloadDialog`. The legacy `transport.*Uploader` /
`transport.*Task` classes are kept (they implement the actual
transfer logic); only the four legacy dialog classes are deleted.

### 5.5 Workspace state model

Each workspace implements:

```java
public interface Workspace {
    String key();          // "containers" | "cohorts" | "jobs" | "transfers"
    String tooltip();      // shown on rail hover
    String iconText();     // single glyph for the rail button
    Region node();         // the workspace's root Region (eagerly built)
    void onShow();         // called when the workspace becomes active
    void onHide();         // called when leaving (cancel async listeners)
}
```

Workspaces are built once at shell construction time and reused.
`onShow()` triggers any lazy initial-load; `onHide()` releases
non-essential listeners. State (selection, scroll position, query
filters) is held in the workspace's fields and survives switches.

## 6. Progress / ETA Contract

### 6.1 `ProgressReport`

A new immutable value class in
`global.thalion.ttio.browser.progress`:

```java
public final record ProgressReport(
    String  phase,             // e.g. "uploading", "encoding", "verifying"
    long    bytesDone,         // -1 if unknown
    long    bytesTotal,        // -1 if unknown
    long    unitsDone,         // e.g. AU count; -1 if not applicable
    long    unitsTotal,        // -1 if not applicable
    double  rateBytesPerSec,   // 5-sec EWMA, NaN if not yet warm
    double  rateUnitsPerSec,   // 5-sec EWMA, NaN if not applicable
    long    etaSeconds,        // -1 if not computable
    long    elapsedSeconds,
    long    lastActivityEpochMs
) {
    public boolean isDeterminate() { return bytesTotal > 0 || unitsTotal > 0; }
    public boolean isStalled(long nowMs) {
        return rateBytesPerSec < 100 && (nowMs - lastActivityEpochMs) > 10_000;
    }
    public double percent() { /* 0..1 from whichever total is set */ }
}
```

### 6.2 `ProgressListener` and producers

```java
@FunctionalInterface
public interface ProgressListener {
    void onProgress(ProgressReport r);
}
```

Producers that must emit `ProgressReport`s (one per ~200 ms or per
significant phase change, whichever comes first):

- `transport.UploadTask`, `transport.DownloadTask`
- `transport.TisHttpUploader`, `transport.TisWsUploader`
- `workbench.TransferManager` (per active transfer)
- `importers.ImportTask`
- `exporters.ExportTask`
- `workbench.EncodingPanel`'s encode worker thread
- `model.DatasetOpenTask`

For each producer, this means plumbing through the existing
`Task<T>.updateProgress(done, total)` plus a new
`updateValue(ProgressReport)` so the UI can render the full numeric
line, not just the bar.

### 6.3 Standard renderer

A reusable `ProgressDisplay` component:

- `ProgressBar` (determinate when `r.isDeterminate()`, indeterminate
  otherwise).
- A `Label` below the bar bound to `r`, formatted by
  `ProgressFormatter.line(r)` →

  | Case | Output |
  |---|---|
  | Bytes known, units N/A | `"42.3% · 1.2 GB / 2.8 GB · 18.4 MB/s · ETA 1m 27s"` |
  | Units known, bytes N/A | `"1,247 / 8,420 AUs · 312 AU/s · ETA 23s"` |
  | Both known            | `"42.3% · 1.2 / 2.8 GB · 1,247 AUs · 18.4 MB/s · ETA 1m 27s"` |
  | Neither total known   | `"1.2 GB processed · 18.4 MB/s · elapsed 1m 12s"` |
  | Stalled               | `"stalled — last activity 12s ago"` (rate hidden) |

- ETA is hidden when `r.etaSeconds < 0` or when `r.isStalled(now)`.
- Bytes are formatted with `Units.humanBytes(n)` (`B`, `KB`, `MB`,
  `GB`, `TB`); rates use `Units.humanRate(n)`.

`ProgressDisplay` is used wherever progress is shown — transfer
queue rows, encode dialog, import wizard, export wizard,
dataset-open status, bottom transfer strip rollup.

### 6.4 5-second EWMA implementation

`ProgressTracker` is a small mutable helper that the producer feeds
raw `(bytesDone, unitsDone)` snapshots into. It maintains a 5-second
sliding window of samples and emits `ProgressReport` instances. Lives
alongside `ProgressReport` in `browser.progress`.

## 7. Action Consolidation — Final Map

| User intent | Where it lives in the new shell | Removes |
|---|---|---|
| Open a local `.tio` | `File → Open…`, `Containers → + Open file…` action node, drag-drop onto window | toolbar `Open` button |
| Re-open recent file | `File → Open Recent ▸` | (new) |
| Encode local source → local `.tio` (UC-01) | `File → Encode…`, `Containers → + Encode…` action node | Workbench menu "Encode + upload" (was the only entry point) |
| Import foreign format | `File → Import…`, `Containers → + Import…` action node, drag-drop foreign file | top-level `Import` menu, toolbar `Import…` button |
| Export local layer to foreign format | `File → Export…`, context menu on `LocalOpenFileNode` | top-level `Export` menu, toolbar `Export…` button |
| Save copy of open `.tio` | `File → Save As…`, context menu on `LocalOpenFileNode` | toolbar `Save As` button |
| Close open file | `File → Close`, context menu on `LocalOpenFileNode` | (kept) |
| Connect to workbench | Header chip click (offline state), `Containers → + Connect another server…` action node | `Workbench → Connect…` menu item |
| Disconnect / switch account / view session | Header chip click (online state) → popover | `Workbench → Disconnect`, `Workbench → Status…` menu items |
| Browse server containers | `Containers` workspace → expand `Servers` branch | `Workbench → Browse containers…` menu, `ContainerBrowser` `Stage` |
| Upload local → server | `Transfers → Start new transfer…` (direction = Upload, scope = Connected workbench) | `Workbench → Upload to workbench…` menu, `Transport → Upload to server…` menu, toolbar `Upload…` button, `transport.UploadDialog`, `workbench.UploadStartDialog` |
| Download server → local (full) | `Transfers → Start new transfer…` (direction = Download), or right-click container node → `Download…` | `Workbench → Download from workbench…` menu, `Transport → Download from server…` menu, toolbar `Download…` button, `transport.DownloadDialog`, `workbench.DownloadStartDialog` |
| Selective download (.tis filters) | Same dialog; selective-access section embedded inline; also right-click container node → `Selective download…` | (selective access was hidden inside Download dialog only) |
| Server-side export of container | Right-click `ServerContainerNode` → `Export (server-side)…` | `Workbench → Export container…` menu |
| Anonymous-URL transfer (no auth) | `Transfers → Start new transfer…` → scope = Anonymous URL (default offline, behind Advanced when connected) | `Transport` top-level menu entirely |
| Track transfer progress | Bottom strip (summary) + `Transfers` workspace (full queue) | `Workbench → Transfers…` menu, `TransferQueueView` `Stage` |
| Build cohort query | `Cohorts` workspace | `Workbench → Cohort query…` menu, `CohortQueryBuilder` `Stage` |
| Submit pipeline job | `Jobs & Sessions → Jobs → New job…` (opens `PipelineLauncher` modal) | `Workbench → Launch pipeline…` menu |
| Monitor jobs | `Jobs & Sessions → Jobs` table | `Workbench → Jobs…` menu, `JobMonitor` `Stage`, `JobEventsView` `Stage` |
| Launch interactive session | `Jobs & Sessions → Interactive sessions → New session…` (opens `SessionLauncher` modal) | `Workbench → Launch session…` menu |
| Manage sessions | `Jobs & Sessions → Interactive sessions` table | `Workbench → Sessions…` menu, `SessionList` `Stage` |
| Diagnostics | `Help → Diagnostics…` (opens existing modal) | `Tools` top-level menu, toolbar `Diagnostics` button |

## 8. Empty / Loading / Error State Catalogue

| Where | Empty | Loading | Error |
|---|---|---|---|
| Shell | (always shows the rail and chip) | — | — |
| Containers — Local branch | Tree shows `Recent` (possibly empty) + three `+ …` action nodes; detail pane shows `LocalRootInfoTab` with the three big buttons | `Opening sample_001.tio… (1.2 MB processed, 18.4 MB/s)` in detail pane | Modal `Alert` with the open error, tree state restored |
| Containers — Servers branch (no connection) | Single child `+ Connect another server…` action node | — | — |
| Containers — Servers branch (connecting) | `Connecting to alice@biobank…` child row with spinner | (same) | `⚠ <error>` child row with `Retry` action |
| Containers — Project listing | `(no containers in this project)` | `Loading… <N> of <M>` row at bottom of paged list | `⚠ <error>` overlay + `Retry` |
| Cohorts (offline) | Centered "Connect to a workbench server to build cohort queries" with `Connect…` button | — | — |
| Cohorts (online, no saved) | Left list shows "(no saved cohorts)"; builder usable | Result preview shows `Loading… <N> rows so far` overlay | Result preview shows error inline + `Retry` |
| Jobs & Sessions (offline) | Same Connect CTA as Cohorts | — | — |
| Jobs & Sessions (online, no jobs) | Table: "(no jobs)"; `New job…` enabled | (per-job submission progress in the modal) | Failed jobs visible as rows; logs accessible |
| Transfers (no transfers ever) | Centered "(no transfers yet)" + `Start new transfer…` button | (per-transfer progress in the row) | Failed transfers visible as rows with error + `Retry` |
| Transfer-start dialog (offline, anonymous not expanded) | Submit disabled, hint "Connect to a server, or expand Advanced for anonymous URL upload/download." | — | — |
| Bottom transfer strip | Strip auto-hidden when no active transfers | (per-transfer numeric line per §6) | "stalled" / "Failed" indicator in line |

## 9. Code-Level Changes

### 9.1 New classes

- `global.thalion.ttio.browser.shell.AppShell` — replaces the content
  of `MainWindow`; constructs header / rail / centre / strip and the
  four `Workspace`s.
- `global.thalion.ttio.browser.shell.Workspace` — interface (per §5.5).
- `global.thalion.ttio.browser.shell.ActivityRail` — the icon-button
  column control.
- `global.thalion.ttio.browser.shell.ConnectionChip` — the header-bar
  chip bound to `ConnectionManager`.
- `global.thalion.ttio.browser.shell.TransferStrip` — the bottom strip.
- `global.thalion.ttio.browser.shell.workspaces.ContainersWorkspace`
- `global.thalion.ttio.browser.shell.workspaces.CohortsWorkspace`
- `global.thalion.ttio.browser.shell.workspaces.JobsWorkspace`
- `global.thalion.ttio.browser.shell.workspaces.TransfersWorkspace`
- `global.thalion.ttio.browser.shell.containers.UnifiedContainerTreeView`
- `global.thalion.ttio.browser.shell.containers.UnifiedContainerNode`
  — sum type / abstract base with subclasses `LocalRootNode`,
  `LocalOpenFileNode` (wraps existing `DatasetTreeNode` root),
  `LocalRecentGroupNode`, `LocalOpenActionNode`,
  `LocalEncodeActionNode`, `LocalImportActionNode`, `ServerRootNode`,
  `ServerProjectNode`, `ServerContainerNode`,
  `ServerConnectActionNode`.
- `global.thalion.ttio.browser.view.LocalRootInfoTab` — empty-state
  recent-files detail.
- `global.thalion.ttio.browser.view.ProjectListingTab` — project's
  container table as a detail tab.
- `global.thalion.ttio.browser.view.ServerContainerOverviewTab` —
  server-container metadata + action row.
- `global.thalion.ttio.browser.workbench.TransferStartDialog` —
  replaces the four existing transfer dialogs.
- `global.thalion.ttio.browser.progress.ProgressReport` (record).
- `global.thalion.ttio.browser.progress.ProgressListener`.
- `global.thalion.ttio.browser.progress.ProgressTracker` (5-sec
  EWMA helper).
- `global.thalion.ttio.browser.progress.ProgressFormatter`
  (numeric-line formatter).
- `global.thalion.ttio.browser.progress.ProgressDisplay` (reusable
  bar+label JavaFX component).
- `global.thalion.ttio.browser.util.RecentFiles` (persisted list,
  java.util.prefs).
- `global.thalion.ttio.browser.util.Units` (`humanBytes`, `humanRate`,
  `humanDuration`).

### 9.2 Modified classes

- `MainWindow` — body replaced; the existing test-only accessors
  (`openMenuItem()`, `closeMenuItem()`, `exitMenuItem()`,
  `diagnosticsMenuItem()`, `statusLabel()`, `treeContainer()`,
  `detailContainer()`) are preserved by routing them to the new
  shell's equivalents (the `File → Open…` MenuItem, etc.). This keeps
  existing smoke tests green.
- `DetailPane` — unchanged interface; new tabs are simply registered
  alongside the existing ones in `ContainersWorkspace`.
- `AbstractDetailTab` — unchanged.
- All `*Task` classes listed in §6.2 — gain a `ProgressListener` and
  emit `ProgressReport`s alongside the existing `Task.updateProgress`.
- `TransferManager` — emits `ProgressReport` per active transfer to
  any subscriber (the strip and the queue table both subscribe).
- `Hdf5NativeLoader` etc. — unchanged.

### 9.3 Deleted classes

- `workbench.ContainerBrowser` (was a `Stage`; content moves to
  `ProjectListingTab` + `ServerContainerOverviewTab`).
- `workbench.UploadStartDialog`
- `workbench.DownloadStartDialog`
- `transport.UploadDialog`
- `transport.DownloadDialog`
- `workbench.TransferQueueView` as a `Stage` (its inner content moves
  to `TransfersWorkspace`).
- `workbench.JobMonitor` as a `Stage` (its inner content moves to
  `JobsWorkspace`).
- `workbench.SessionList` as a `Stage` (content moves to
  `JobsWorkspace`).
- `workbench.JobEventsView` as a `Stage` (content embeds in the
  job-detail panel inside `JobsWorkspace`).
- `workbench.CohortQueryBuilder` as a `Stage` (content moves to
  `CohortsWorkspace`).

Where a deletion target's content is reused, the substantive
JavaFX-control building code is extracted into a non-`Stage`
`Region`-returning method on the new owner class, not duplicated.

### 9.4 Kept as-is

- `model.*` (`OpenDataset`, `DatasetOpenTask`, `DatasetTreeNode`,
  `DatasetTreeBuilder`).
- `view.headers.*`, `view.plot.*`, `view.overview.OverviewTab`,
  `view.IdentificationsTab`, `view.QuantificationsTab`,
  `view.ProvenanceTab`, `view.FeatureFlagsTab`,
  `view.EncryptionTab`, `view.ReferenceTab`, `view.ChannelHexTab`,
  `view.ChannelHexView`, `view.DatasetTreeView` (still used as the
  inner control for the `LocalOpenFileNode` subtree).
- `workbench.ConnectionManager`, `ConnectionListener`,
  `ConnectionState`, `StatusIndicator` (the chip extends/reuses
  `StatusIndicator`'s state-binding logic).
- `workbench.TransferManager`, `Transfer`, `TransferKind`,
  `TransferState`, `SelectiveAccessPanel`.
- `workbench.LoginDialog`, `EncodingPanel`, `ExportPanel`,
  `PipelineLauncher`, `SessionLauncher` (still modal, invoked from
  their owning workspace).
- `transport.TisEncoder`, `TisHttpUploader`, `TisWsUploader`,
  `UploadTask`, `DownloadTask` (the actual transfer logic).
- `importers.*`, `exporters.*`, `diag.*`, `util.*`.

## 10. Migration Order (Staged)

Each stage is independently reviewable and keeps the test suite
green. Stage N's tests pass before stage N+1 begins.

| Stage | Scope | Risk |
|---|---|---|
| **0** | Add `progress` package (`ProgressReport`, `ProgressListener`, `ProgressTracker`, `ProgressFormatter`, `ProgressDisplay`, `Units`). No UI changes yet. New unit tests. | Low — additive only. |
| **1** | Wire `ProgressReport` through the existing `*Task` producers and `TransferManager`. Display still uses the current places (legacy dialogs, current `TransferQueueView`). New numeric line appears under existing bars. | Low — additive to existing widgets; tests for new emissions. |
| **2** | Build `AppShell` skeleton: header bar, rail, centre with a single workspace stub, bottom strip. `MainWindow` switches to host the new shell. Test-only accessors on `MainWindow` route to new shell equivalents. The new shell hosts a `ContainersWorkspace` whose initial implementation just wraps the existing `DatasetTreeView` + `DetailPane` (no unified tree yet). Existing menus / toolbar deleted; `File` + `Help` menus added. | Medium — touches every UI smoke test. Each test that asserts a menu item is updated to look it up in the new `File` menu or its workspace home. |
| **3** | `TransfersWorkspace`: move `TransferQueueView` content into the workspace; build `TransferStartDialog`; delete `transport.UploadDialog`, `transport.DownloadDialog`, `workbench.UploadStartDialog`, `workbench.DownloadStartDialog`, `workbench.TransferQueueView`. Bottom strip wired. | Medium — four-dialog deletion; test migration. |
| **4** | `JobsWorkspace`: move `JobMonitor` + `SessionList` + `JobEventsView` content; delete those `Stage` wrappers. `PipelineLauncher` / `SessionLauncher` stay as modals invoked from the workspace. | Medium. |
| **5** | `CohortsWorkspace`: move `CohortQueryBuilder` content; delete the `Stage` wrapper. | Low-medium. |
| **6** | Unified container tree: introduce `UnifiedContainerNode` hierarchy, `UnifiedContainerTreeView`, `LocalRootInfoTab`, `ProjectListingTab`, `ServerContainerOverviewTab`. Replace `ContainersWorkspace`'s stub content with the unified tree. Delete `workbench.ContainerBrowser` `Stage`. | Highest — net-new tree control with action nodes and context menus, server-side data loading, paging. |
| **7** | Polish: empty / error states per §8, recent-files persistence, drag-drop on the unified tree, keyboard shortcuts, accessibility passes (focus traversal across rail and workspaces). | Low. |

## 11. Testing Strategy

- **Existing tests:** every `*Test.java` under
  `src/test/java/global/thalion/ttio/browser/` keeps running.
  Tests that asserted menu structure (`AppSmokeTest`,
  `WorkbenchMenuSmokeTest`, `MainWindowOpenTest`) are migrated to
  assert the new `File` + `Help` structure and to assert the new
  rail + workspace presence.
- **New tests:**
  - `ProgressReportTest`, `ProgressTrackerTest`,
    `ProgressFormatterTest` (covering the every-row of §6.3 table
    plus stalled / not-yet-warm cases).
  - `ProgressDisplayTest` (renders the right text for given
    `ProgressReport`s).
  - `AppShellSmokeTest` — boots the shell, verifies all four
    workspaces are present, switching the rail changes the centre.
  - `ActivityRailTest` — selection model, tooltip text.
  - `ConnectionChipTest` — three states + popover actions.
  - `UnifiedContainerTreeViewTest` — node hierarchy, action-node
    behaviour, context menus per node kind.
  - `TransferStartDialogTest` — direction radio, scope-toggle visibility,
    selective-access panel collapse, submit-enabled rules.
  - One workspace-level integration test per workspace (selects rail,
    asserts the workspace's empty state when disconnected, asserts
    the connected state with a mocked `ConnectionManager`).
- **Test infrastructure:** existing `TestFx`-style headless setup is
  used. The mocked `ConnectionManager` pattern already in
  `ConnectionManagerTest` extends to drive the chip and the
  workspaces.

## 12. Out of Scope (Future Work)

These are intentionally not addressed:

- Multi-document tabs for multiple open local `.tio` files. The
  unified tree could hold multiple `LocalOpenFileNode` entries
  later; today only one is supported (matching current behaviour).
- Alignment-coverage track visualization (per the existing README
  known-limitations list).
- SSO / OIDC login flows in the GUI (server-side scope).
- Theme picker beyond the existing single stylesheet.
- Localization / i18n.
- Telemetry, auto-update, crash reporter.
- Webhook / notification UI for job-state transitions (the spec's
  §9.3 Event interface is server-side only for now).
- Settings popover content beyond a placeholder.

## 13. Open Questions for Implementation Plan

(To be resolved when writing the staged implementation plan, not in
this design.)

- Exact keyboard-shortcut assignments per OS (Mac vs Win/Linux
  modifier keys).
- Persistence backend for `Recent Files` and rail selection — use
  `java.util.prefs.Preferences` (no new dependency) vs a JSON config
  file under `~/.tio-browser/`.
- Whether `LocalEncodeActionNode` and `LocalImportActionNode` should
  also offer "drag a file onto me" affordances, or whether window-
  level drag-drop (already implemented) is sufficient.
- Whether the connection chip's "Switch account…" should disconnect
  the current session before opening the login dialog, or support
  multiple concurrent server connections (the unified tree's
  `Servers` branch can show multiple `ServerRootNode`s, but
  `ConnectionManager` today holds a single session).
