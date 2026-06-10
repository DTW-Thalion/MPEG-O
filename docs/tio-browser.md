# tio-browser user guide

A short walkthrough of every action the JavaFX desktop GUI exposes.
For build/install instructions see
[`tio-browser/README.md`](../tio-browser/README.md).

> **Screenshots TBD.** A release build needs to run on a real display
> to capture the activity-rail layout. This page is the textual
> reference until those land.

## Shell layout

The window is divided into four persistent regions:

- **Top header bar** — app title, connection status chip
  (`workbench: connected (alice@host)` / `workbench: disconnected`),
  click the chip to open the Login dialog or view session details.
- **Left activity rail** — four icon buttons selecting the active
  workspace:
  - 📁 **Containers** — local files + server containers
  - 🔬 **Cohorts** — cohort query builder
  - ⚙ **Jobs & Sessions** — pipelines and interactive sessions
  - ⇅ **Transfers** — `.tis` upload/download queue
- **Centre** — the active workspace's content (changes with rail
  selection).
- **Bottom transfer strip** — always-visible summary of in-flight
  transfers with bytes, rate, ETA. Auto-hides when no transfers are
  active. Click `view all` to jump to the Transfers workspace.

The menu bar has only two real menus: `File` (Open, Open Recent,
Encode, Import, Export, Save As, Close, Exit) and `Help` (About,
User guide, Diagnostics).

## Containers workspace (📁)

The Containers workspace is a three-pane layout:

- **Left** — unified tree with two top-level branches:
  - **Local** — currently-open `.tio` (if any), Recent files, and
    three action nodes: `+ Open file…`, `+ Encode…`, `+ Import…`.
  - **Servers** — each connected workbench instance with its
    projects, plus a `+ Connect another server…` action node.
- **Middle** (visible only when a local `.tio` is open) — the
  dataset tree showing `SpectralDataset` structure: MS / NMR /
  vibrational / UV-Vis runs, `GenomicRun` reads + index,
  provenance chains, identifications + quantifications.
- **Right** — context-sensitive detail:
  - When `Local` is selected: empty-state with the three big CTAs.
  - When the open file's dataset tree node is selected:
    spectrum/read/headers/overview/etc. tabs (same as before).
  - When a `ServerProject` is selected: paged container table.
  - When a `ServerContainer` row is selected: metadata +
    Download / Selective download / Server-side export /
    Run pipeline actions.

Drag-and-drop a `.tio` onto the window to open it; drop any other
recognised format and the Import wizard opens with the format
pre-selected.

### Opening a file

- **File → Open…** (`Shortcut+O`) picks a `.tio` from a file dialog.
- **File → Open Recent ▸** lists the 8 most recently opened paths.
- **Drag-and-drop** any `.tio` onto the window.
- **CLI**: `java -jar tio-browser-1.7.1-<your-os>.jar --open path/to/dataset.tio`.

### Importing a foreign format

- **File → Import…** opens the Import wizard. Pick a format, source
  path, target `.tio`, and run name. Drag-drop a recognised foreign
  format file onto the window to pre-select the format.

Supported formats: mzML, ImzML, nmrML, JCAMP-DX (Raman/IR/UV-Vis),
BAM/SAM/CRAM (pure-Java htsjdk, no external binary), FASTA, FASTQ, mzTab, Thermo
`.raw` (ThermoRawFileParser required), Waters MassLynx `.RAW`
(masslynxraw required), Bruker timsTOF `.d` (Python + opentimspy
required). Format rows whose required external binary is missing
are greyed out with a tooltip explaining what's needed (see
Diagnostics below).

### Encoding a local source file → local `.tio`

- **File → Encode…** (`Shortcut+E`) opens the Encoding panel.

### Exporting

- **File → Export…** opens the Export dialog. Format rows that don't
  apply to the open file are greyed out with a tooltip explaining
  why. Supported export targets cover the same modality range as
  Import.

### Plot views and Read Inspector

Selecting a spectrum row in the MS/NMR/Raman/IR/UV-Vis Headers tab
populates the Spectrum plot tab. Selecting a chromatogram row
populates the Chromatogram plot tab. Selecting an aligned-read row
in a genomic run opens the Read Inspector with sequence, qualities,
mapping coordinates, mate-pair chrom/pos, and the AU's tag
dictionary.

### Provenance, FeatureFlags, Encryption

Three structural detail tabs apply to the open dataset:

- **Provenance** — every recorded provenance entry's timestamp,
  software, parameters, input refs, output refs.
- **FeatureFlags** — which optional features are enabled.
- **Encryption** — for encrypted datasets, shows status and a
  `Decrypt with key…` button.

## Cohorts workspace (🔬)

Build cohort queries against the connected workbench. Offline state
shows a "Connect to a workbench server" CTA; once connected, the
query builder is available. (Saved cohorts list and result-preview
table polish lands in a follow-up.)

## Jobs & Sessions workspace (⚙)

Stacked layout:

- **Top** — Jobs table. `New job…` opens the Pipeline Launcher
  modal. Selecting a row shows the events / log tail inline.
- **Bottom** — Interactive Sessions table. `New session…` opens
  the Session Launcher modal.

## Transfers workspace (⇅)

Single queue for all `.tis` transfers (uploads + downloads). Filter
by All / Active / Completed / Failed. `Clear completed` removes
finished rows. `Start new transfer…` opens the unified transfer
dialog with:

- Direction (Upload / Download)
- Server scope:
  - **Connected workbench** (default when an authenticated session
    exists) — uses the workbench WS handshake with
    `project` + `container_uri`. Targets the workbench server you
    logged into via the header chip.
  - **Anonymous URL** (default when offline) — uses the legacy
    `.tis` transport (HTTP `PUT /` with optional Bearer token, or
    WS `{"type":"upload","filename":"X"}` text frame + binary chunks
    + `{"type":"end"}`). This is for non-workbench endpoints
    (simple `.tis` drop services, legacy uploaders). Pasting a
    workbench URL here will fail — use the Connected scope for
    workbench transfers.
- Source / target file picker
- Project + Container URI (Connected scope) or URL + optional
  Bearer token (Anonymous scope)
- Selective Access section (visible for downloads only): RT range,
  MS level, polarity, m/z range, dataset-id list, max AU count, etc.
- Per-packet CRC-32C checksum option

The bottom transfer strip mirrors active transfers from this queue
and is reachable from any workspace.

## Progress reporting

Every long-running operation (Open, Encode, Import, Export, Upload,
Download) reports a `ProgressReport` with:

- Percent complete (when total is known)
- Bytes processed / bytes total
- Instantaneous rate (5-second EWMA)
- ETA seconds
- Stalled detection (rate < 100 B/s and > 10s of silence)

These appear as: `"42.0% · 1.2 GB / 2.8 GB · 18.4 MB/s · ETA 1m 27s"`
in the bottom strip and per-row in the Transfers queue. When totals
are unknown the line falls back to `"1.2 GB processed · 18.4 MB/s ·
elapsed 1m 12s"`. When stalled: `"stalled — last activity 12s ago"`.

## Diagnostics

**Help → Diagnostics…** opens a modal dialog probing every external
binary the library can use: HDF5 JNI (in-process), htsjdk SAM/BAM/CRAM
(in-process), `ThermoRawFileParser`, `masslynxraw`, and the Bruker
Python helper.
Each probe shows status (OK / NOT_FOUND / ERROR), resolved path,
and a version string when available.

The **Re-probe** button reruns all probes asynchronously. Open
Import / Export dialogs are notified via a listener bus and refresh
their format-list cell factories — newly-installed binaries become
available without restarting the app.

## Reporting issues

`tio-browser` issues, feature requests, and crash reports go to the
TTI-O monorepo issue tracker. Please include the
**Help → Diagnostics** output and the full stderr from a terminal-
launched `java -jar tio-browser-<version>-<your-os>.jar` invocation.
