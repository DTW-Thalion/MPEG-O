# tio-browser user guide

A short walkthrough of every action the JavaFX desktop GUI exposes.
For build/install instructions see
[`tio-browser/README.md`](../tio-browser/README.md).

> **Screenshots TBD.** A release build needs to run on a real display
> to capture the main-window and Read-Inspector views. This page is
> the textual reference until those land.

## Opening a file

- **File → Open** picks a `.tio` from a file dialog.
- **Drag-and-drop** any `.tio` onto the window (drops on file types
  the importer recognizes route through the Import wizard instead).
- **CLI**: `java -jar tio-browser-1.4.0-<your-os>.jar --open path/to/dataset.tio`
  opens the dataset at launch.

The status bar shows `path · vN.N.N · MS=N · Genomic=N · Refs=N · 🔓/🔒`
once the dataset is loaded. Selecting nodes in the left tree drives
the detail tabs on the right.

## Importing a foreign format

**File → Import** opens the Import wizard. Pick a format, source
path, target `.tio`, and run name. The wizard auto-detects the format
when you drop a file onto the main window. Format rows whose
required external binary is missing are greyed out with a tooltip
explaining what's needed (see Diagnostics below).

Supported formats:

- **MS**: mzML, ImzML
- **NMR**: nmrML
- **Vibrational**: JCAMP-DX (Raman, IR, UV-Vis)
- **Genomic**: BAM, SAM, CRAM (samtools required), FASTA (reference
  or unaligned), FASTQ
- **Tabular**: mzTab
- **Vendor (binary)**: Thermo `.raw` (ThermoRawFileParser required),
  Waters MassLynx `.RAW` (masslynxraw required), Bruker timsTOF `.d`
  (Python + opentimspy required)

## Exporting

**File → Export** opens the Export dialog. Format rows that don't
apply to the open file (e.g. nmrML when there are no NMR runs, or BAM
when `samtools` isn't on PATH) are greyed out with a tooltip
explaining why.

Supported export targets cover the same modality range as Import,
plus signed-bytes export for the canonical-bytes audit trail.

## Plot views

Selecting a spectrum row in the MS/NMR/Raman/IR/UV-Vis Headers tab
populates the Spectrum plot tab. Centroided MS spectra render as
stems; profile MS as lines. The MinMaxBucketDownsampler keeps high-
density profile spectra responsive.

Selecting a chromatogram row populates the Chromatogram plot tab.

The plot toolbar provides:

- Linear / log Y toggle
- Reset zoom (returns to auto-range)
- Save as PNG (manual rasterization, no Swing dependency)

## Headers tables

For every analytical run kind there's a dedicated headers table:

- **MS Headers** — m/z range, scan time, MS level, polarity,
  precursor charge, base-peak intensity, idx
- **NMR Headers** — nucleus, scan time, idx, solvent
- **Raman / IR / UV-Vis Headers** — integration time, idx,
  wavelength range

All columns are sortable; row selection drives the Plot tab.

## Read Inspector (genomic runs)

Selecting an aligned-read row in a genomic run opens the Read
Inspector with sequence, qualities, mapping coordinates, mate-pair
chrom/pos, and the AU's tag dictionary. On platforms where
`libttio_rans_jni` couldn't load (Intel Mac and other unbundled
platforms), the inspector shows a placeholder explaining the
limitation.

## Provenance, FeatureFlags, Encryption

Three structural detail tabs:

- **Provenance** — every recorded provenance entry's timestamp,
  software, parameters, input refs, output refs.
- **FeatureFlags** — which optional features are enabled in the
  open dataset (genomic, encryption, transport-bulk-mode-v2, etc.).
- **Encryption** — for encrypted datasets, shows status and a
  `Decrypt with key…` button. The button accepts a binary key file;
  bytes are passed verbatim to `SpectralDataset.decryptInPlace(path,
  key)`. The dataset is closed and reopened post-decrypt to refresh
  state.

## Transport

Transport → Download from server requests a `.tis` stream from a
`http://`, `https://`, `ws://`, or `wss://` URL and materializes a
local `.tio`. Transport → Upload sends a local `.tio` as a `.tis`
byte stream to the same URL families.

The download dialog also accepts query-side filters (run kind,
dataset-id list, RT range for MS, etc.) so you can fetch a subset
of a remote dataset without downloading the whole file.

## Diagnostics

**Tools → Diagnostics** opens a modal dialog probing every external
binary the library can use: HDF5 JNI (in-process), `samtools`,
`ThermoRawFileParser`, `masslynxraw`, and the Bruker Python helper.
Each probe shows status (OK / NOT_FOUND / ERROR), resolved path,
and a version string when available.

The **Re-probe** button reruns all probes asynchronously. Open
Import / Export dialogs are notified via a listener bus and refresh
their format-list cell factories — newly-installed binaries become
available without restarting the app.

## Reporting issues

`tio-browser` issues, feature requests, and crash reports go to the
TTI-O monorepo issue tracker. Please include the
**Tools → Diagnostics** output and the full stderr from a terminal-
launched `java -jar tio-browser-<version>-<your-os>.jar` invocation.
