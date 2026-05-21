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

**Partially resolved.** `ttio export --format nmrml` and
`--format imzml` are now wired — the extraction reads
`AcquisitionRun.spectra()` → `NMRSpectrum` and
`MSImage.to_pixel_spectra()` → `ImzMLPixelSpectrum`.

**Residual gap — JCAMP-DX (both directions).** This is *not* mere CLI
glue: Python's `AcquisitionRun._materialize_spectrum` only reconstructs
`MassSpectrum` / `NMRSpectrum` from a `.tio`, not the vibrational types
(`IRSpectrum` / `RamanSpectrum` / `UVVisSpectrum`). So there is no
`.tio` → vibrational-`Spectrum` read path, and no vibrational-`Spectrum`
→ `.tio` write path either. Closing it requires a **core** change
(extend `_materialize_spectrum` + the write side to handle the
vibrational spectrum classes), after which `ttio encode --format
jcamp-dx` and `ttio export --format jcamp-dx` can be wired. The JCAMP
reader/writer codecs themselves already exist in all three languages.

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
- The repo commits generated Javadoc HTML under `docs/api/java`
  (DOC-AUDIT convention) while the new `docs.yml` CI also builds it as
  an artifact. Decide whether to keep committing generated HTML or move
  fully to CI artifacts (the committed copy currently lags the W6
  workbench classes).

## 4. Method

Per-language directory inventories of `importers/`, `exporters/`,
`providers/`, `codecs/`, `protection/` (Protection), and `transport/`
(Transport), cross-referenced for capability presence; entry-point
signatures checked where a difference was suspected (JCAMP-DX reader,
nmrML/imzML writers, PQC backends). Findings corroborated against the
cross-language conformance CI job. No source was modified.
