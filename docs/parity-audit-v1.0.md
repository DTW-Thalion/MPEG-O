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

**JCAMP-DX vibrational round-trip — RESOLVED (Python).** The core gap
is closed in Python: `AcquisitionRun._materialize_spectrum` now
reconstructs `IRSpectrum` / `RamanSpectrum` / `UVVisSpectrum` (alongside
`MassSpectrum` / `NMRSpectrum`), and the per-class metadata (IR mode /
resolution / scans, Raman excitation / power / integration, UV-Vis
path-length / solvent) round-trips via scalar run-group attributes
written by `WrittenRun` / `_write_run` and read in `AcquisitionRun.open`.
`ttio encode --format jcamp-dx` and `ttio export --format jcamp-dx` are
wired (no longer `DEFERRED_PYTHON`); covered by
`tests/test_jcamp_tio_roundtrip.py`.

**Cross-language parity:** Java done — `AcquisitionRun` materializes
IR/Raman/UV-Vis and reads/writes the same run-attribute contract
(`JcampVibrationalRoundTripTest`). ObjC parity is the remaining
follow-up so a Python- or Java-written vibrational `.tio` reads
everywhere.

### 3.2 Live-daemon round-trips for workbench encryption / PQC

**Investigated against a real daemon — surfaced two findings.**

1. **Bug fixed.** The `workbench-live` smoke had *no* upload/download
   e2e at all, so a real bug in the upload client went uncaught:
   `UploadClient._drain_acks` read `self._ws.messages`, a deque the
   `websockets` ≥ 14 asyncio `ClientConnection` no longer exposes — so
   *any* live upload crashed with `AttributeError`. Rewritten to a
   cancel-safe non-blocking `recv()` drain. A valid-`.tis`
   upload → ingest → download → decode round-trip is now in the smoke
   (9/9 against a local daemon).

2. **W6.2 blob-level BYOK is NOT daemon-compatible (design gap).** The
   daemon parses every upload as a transport stream and rejects
   anything without valid packet magic (`transport stream error:
   invalid packet magic`), and on download it **re-encodes** a fresh
   `.tis` from storage (uploads are *not* byte-preserved — only the
   data round-trips). W6.2 BYOK seals the whole payload into an opaque
   ciphertext blob, which therefore cannot survive an upload. The unit
   suite passed only because it never touched the daemon. **Correct
   model:** encrypted upload must use **per-AU encryption** that yields
   a *valid* `.tis` (the core `encrypt_per_au` → `write_encrypted_dataset`
   path). Tracked in
   [`workbench-client/per-au-encrypted-upload-plan.md`](workbench-client/per-au-encrypted-upload-plan.md).

   **Phase 0 — resolved.** A first run against a real daemon found the
   daemon's ingest → re-emit dropped the `ProtectionMetadata` packet and
   per-AU `ENCRYPTED` flags (re-download read as plaintext). Fixed in
   `tti-workbench-server` #31 (encryption-aware passthrough: encrypted
   containers are stored + served as opaque `.tis` verbatim). The live
   round-trip (`test_per_au_encrypted_upload_round_trip`: encrypt →
   upload → download → decrypt → channels match) now **passes**. The
   per-AU client wiring (`upload_encrypted` / `download_decrypted`, +
   the PQC variant) is unblocked — Phases 1-4 of the plan.

### 3.3 Flaky WebSocket test — RESOLVED

`tio-browser` `TisWsUploaderTest.uploadSendsCorrectFrameSequence` used a
10 s `CountDownLatch.await` against an embedded WS server and flaked on
loaded CI runners. Fixed in two parts: PR #128 bumped the await budgets
(`done.await` 10 s/15 s → 30 s, `serverStarted` 5 s → 15 s); the
follow-up added a deterministic TCP-readiness probe in `@BeforeEach`
(`awaitPortAccepting`) so the client never dials before the embedded
server is actually accepting — closing the connection-wait race that a
larger timeout alone does not remove.

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
