# TTI-O v1.0 Three-Language Parity Audit

**Date:** 2026-05-20
**Scope:** Python (`python/src/ttio`), Java (`java/.../global/thalion/ttio`),
Objective-C (`objc/Source`). Supersedes the parity notes in
[`api-review-v0.7.md`](api-review-v0.7.md) (which predates the
transport, workbench-client, PQC, and format-expansion work).

## Verdict

**The core library is at full three-language parity**, and that parity
is *enforced*, not just structural: the CI job **"Cross-language parity
(ObjC ⇄ Python ⇄ Java)"** (`.github/workflows/ci.yml`) runs 15+
byte-level conformance tests on every PR — codecs (M94z, name-tokenizer,
ref-diff, mate-info), formats (mzML, nmrML, Raman/IR, FASTA/FASTQ),
genomics (M87–M90), per-AU encryption, and PQC (M54).

The only cross-language asymmetries are at the **application-surface**
layer, and all of the significant ones are **intentional** (workplan
decisions). The genuine follow-on items are narrow and listed in
§3.

## 1. Core library — full parity (all three languages)

| Domain | Python | Java | ObjC | Status |
|---|---|---|---|---|
| Dataset / runs / spectra / value classes | ✓ | ✓ | ✓ | parity |
| References + genomics (ReferenceImport, AlignedRead) | ✓ | ✓ | ✓ | parity |
| Storage providers: HDF5 / Memory / SQLite / Zarr | ✓ | ✓ | ✓ | parity |
| Codecs: rANS, DeltaRans, M94z, REF_DIFF, MateInfo, NameTokenizer, Quality, BasePack | ✓ | ✓ | ✓ | parity |
| Stream / transport reader+writer, compound I/O, walker, ingest, client, server, simulator, filters, stats | ✓ | ✓ | ✓ | parity |
| Encryption (AES-256-GCM), per-AU encryption (+ encrypted headers) | ✓ | ✓ | ✓ | parity |
| Key wrap/rotation (v1.1 + v1.2 blobs), cipher-suite catalog | ✓ | ✓ | ✓ | parity |
| Signatures + verification, access policy, anonymization | ✓ | ✓ | ✓ | parity |
| PQC: ML-KEM-1024 + ML-DSA-87 | ✓ | ✓ | ✓ | parity¹ |
| ProtectionMetadata packet, encrypted transport, selective access | ✓ | ✓ | ✓ | parity |
| **File-format codecs** (import: mzML, mzTab, imzML, nmrML, JCAMP-DX, Bruker timsTOF, Waters MassLynx, Thermo .raw, BAM, SAM, CRAM, FASTA, FASTQ; export: those + ISA) | ✓ | ✓ | ✓ | parity² |

¹ **PQC backend differs by language** (an implementation detail, not a
gap): Python uses `liboqs` (pyoqs), Java uses BouncyCastle, ObjC uses
`liboqs` (and returns `TTIOErrorPQCUnavailable` when libTTIO was built
without it). The wire/envelope shapes are conformance-tested (M54).

² **Format codecs are at parity at the *library* level in all three
languages.** Note that the JCAMP-DX reader and the nmrML / JCAMP-DX /
imzML *writers* operate at the spectrum/pixel level in **every**
language (e.g. Java `JcampDxReader.readSpectrum() → Spectrum`,
`NmrMLWriter.write(AcquisitionRun, …)`), not at the whole-dataset level.
The dataset↔spectrum extraction glue lives in the *application* layer
(see §3.1), not the core — so this is not a core-codec gap.

## 2. Intended asymmetries (NOT gaps)

These are deliberate per the workbench-client workplan and are **not**
follow-on work:

- **Workbench client SDK** (`ttio.workbench` / `…workbench.*`): connect,
  upload/download, cohorts, pipelines, jobs, sessions, and the
  encryption / PQC / federation client wrappers ship in **Python +
  Java only**. ObjC is the **server-runtime + reference implementation**
  and is intentionally not extended for client purposes (workplan
  Decision 2). There is no `objc/Source/*workbench*`.
- **CLI (`ttio`)**: **Python only** (workplan Decision 1).
- **GUI (`tio-browser`)**: **Java only** (JavaFX desktop app). Not a
  language-parity concern.
- **Rust SDK**: explicitly deferred to v1.2 (workplan Open Question 1).

## 3. Genuine follow-on items

All of these are *narrow* and none block v1.0. They are surface-level,
not core-codec, gaps.

### 3.1 Python CLI format coverage (dataset↔spectrum glue)

The Python `ttio` CLI format registries (added in W6.4) cover the
formats with a clean dataset-level path but **omit**:

- `ttio encode --format jcamp-dx` (JDX → `.tio` import)
- `ttio export --format {nmrml, jcamp-dx, imzml}` (`.tio` → format)

The **codecs exist in Python** — what's missing is the
`.tio`-layer → `Spectrum`/pixel extraction helper that the Java
tio-browser `ExportTask` / import path already has. A small Python
extraction helper (dataset run → `NMRSpectrum` / `IR`/`Raman`/`UVVis`
spectrum / `ImzMLPixelSpectrum`) would close the CLI gap and let the
registries wire these three formats. Tracked informally in the W6.4
CHANGELOG entries.

### 3.2 Live-daemon round-trips for workbench encryption / PQC

W6.2 (BYOK / envelope) and W6.3 (PQC) shipped **unit-level**
byte-equivalence + cross-language JSON anchors; the **live-daemon**
"encrypt → upload → re-download → decrypt against a real daemon"
variant was deferred. The W5 `workbench-live` smoke harness exists and
could host these.

### 3.3 Flaky WebSocket test

`tio-browser` `TisWsUploaderTest.uploadSendsCorrectFrameSequence` uses a
10 s `CountDownLatch.await` against an embedded WS server and flakes on
loaded CI runners (its large-file sibling already uses 15 s). Harden the
connection wait / bump the timeout.

### 3.4 Documentation hygiene

- The `api-review-v0.7.md` parity notes are stale relative to the v1.x
  surface; this document is the current snapshot.
- **Resolved:** keep committing the generated Javadoc HTML under
  `docs/api/java` (Javadoc remains the Java reference-doc solution);
  the committed copy was refreshed to include the W6 workbench classes
  (`workbench.encryption` / `pqc` / `federation`, etc.). The `docs.yml`
  CI continues to build Javadoc as a PR gate.

## 4. Method

Per-language directory inventories of `importers/`, `exporters/`,
`providers/`, `codecs/`, `protection/` (Protection), and `transport/`
(Transport), cross-referenced for capability presence; entry-point
signatures checked where a difference was suspected (JCAMP-DX reader,
nmrML/imzML writers, PQC backends). Findings corroborated against the
cross-language conformance CI job. No source was modified.
