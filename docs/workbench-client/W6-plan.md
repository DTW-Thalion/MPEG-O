# W6 plan — SDK polish + formats + PQC/BYOK + federation

Companion to [`docs/workbench-client-workplan.md`](../workbench-client-workplan.md).
Final workplan milestone: closes the spec's Phase 5 (Production
Hardening) on the client side. Brings the SDK to release quality,
expands `ttio encode --format` to the full spec §4 format set,
wires BYOK / envelope / PQC encryption through the workbench
client path, adds a graceful federation client, and ships SDK
reference docs.

## Status (2026-05-20): W6.3 in progress

W1–W5 are merged (client SDK + tio-browser GUI, all nine spec
§8.1 components) and the live-daemon end-to-end smoke is green
(8/8 against a real daemon). W6 is the last milestone.

Progress: **W6.1 done** (#117 + #118). **W6.2 done** (#119) — BYOK
+ envelope blob protection + ProtectionMetadata JSON anchor;
per-AU stream modes (ENCRYPTED / ENCRYPTED_HEADER) stay in the core
`encrypt_per_au` path, carried opaquely by upload. **W6.3 in
progress** — PQC client (ML-KEM-1024 + ML-DSA-87) on the envelope
path, `opt_pqc_preview`-gated.

## What already exists (grounding)

W6 is mostly **exposing existing core capabilities through the
workbench client surface** + finalisation — not building crypto
or codecs from scratch.

- **Core crypto already present** at the library level:
  `ttio/pqc.py` (ML-KEM / ML-DSA via the pyoqs wrapper),
  `ttio/encryption.py`, `ttio/encryption_per_au.py`,
  `ttio/transport/encrypted.py`, and the `ttio_pqc_cli` tool.
  There is **no** `ttio/workbench/{encryption,pqc}.py` yet — W6
  adds the client-path wrappers (BYOK upload, envelope, etc.).
- **Format codecs already present**: the tio-browser
  `ImportFormatRegistry` already wires 13 formats (mzML, mzTab,
  imzML, nmrML, JCAMP-DX, Bruker timsTOF, Waters MassLynx,
  Thermo .raw, BAM, SAM, CRAM, FASTA, FASTQ). But the `ttio
  encode` CLI front-door only accepts `fastq | fasta` today
  (W2 stub). W6.4 wires the existing codecs into the CLI
  front-door so all three surfaces (CLI / SDK / GUI) cover the
  same set.
- **Federation**: the v1.0 server is single-node; spec §12.3
  marks federation v1.1+. W6 ships the *client* surface that
  gracefully no-ops against a v1.0 server (detects the absence
  of `/v1/federation/peers`).

## Decisions carried in

- **Decision 2 (lockstep):** Python + Java SDK ship together at
  every sub-phase. ObjC stays server-runtime (not extended for
  client purposes). CLI stays Python-only. Cross-language
  byte-equivalence anchors as in W1–W5.
- **Decision 9 (PQC gating):** PQC client support sits behind
  the `opt_pqc_preview` feature flag, matching the server's
  existing feature-flag gating. BYOK / envelope are
  ENCRYPTION-OPTIONAL (the server accepts unencrypted streams).
- **Rust SDK:** explicitly deferred to v1.2 (workplan Open
  Question 1). Not in W6.

## Sub-phases

Each is one PR (Python + Java lockstep where SDK code is
involved), gated by the `tio-browser` + (where touched) the
`workbench-live` CI we built in W5/live-smoke.

| W#   | Title | Touches | Est. LOC |
|------|-------|---------|----------|
| W6.0 | Kickoff: this plan | docs | ~20 |
| W6.1 | **Progress feedback for ALL client-server interactions** (% by source size + per-phase) | python + java + tio-browser | ~900 |
| W6.2 | BYOK + envelope encryption client (`workbench/encryption`) | python + java | ~700 |
| W6.3 | PQC client (`workbench/pqc`, `opt_pqc_preview`) | python + java | ~500 |
| W6.4 | Format expansion: wire spec §4 codecs into `ttio encode --format` + GUI parity | python + java + tio-browser | ~600 |
| W6.5 | Federation client (graceful no-op vs v1.0) | python + java | ~350 |
| W6.6 | SDK reference docs (Sphinx + Javadoc) + tutorial notebook + finalisation | python + java + docs | ~400 |
| **Total** | | | ~3,470 |

**Priority note (2026-05-20):** W6.1 was promoted to the front of
the milestone after a live cross-environment test — a multi-contig
FASTA `Encode + upload` showed *no feedback* for minutes (it was
working, not hung; see issue #113 / #114). Progress feedback is a
**gating requirement** for every client-server interaction, so it
leads W6 ahead of the encryption/PQC work.

## W6.1 — Progress feedback for ALL client-server interactions

**Goal:** every client↔server operation (and the local
encode/decode that brackets it) shows its current **phase** and a
**% by source size** — never a bare spinner or static label. A
user can always tell *working* from *hung*. Tracked in issue #113;
the `ReferenceImport` slowness that exposed it is issue #114.

**Phase model** — each op reports `(phase, bytesDone, bytesTotal)`:

| Operation | Phases |
|---|---|
| Encode + upload | reading(source) → encoding → uploading |
| Download + export | downloading → decoding → writing(target) |
| Plain upload (.tio) | reading → uploading |
| Plain download | downloading → writing |

**Deliverables:**
- **SDK (the root gap):** `WorkbenchTransportClient.upload/download`
  (Python + Java, lockstep) gain a progress callback
  (`bytesSent/bytesReceived`, total when known). Today both block
  with no callback — that's why W5.3's bars are indeterminate.
- `ImportTask` / `ExportTask` already extend `javafx.concurrent.Task`;
  thread `updateProgress(done,total)` + `updateMessage(phase)` from
  the underlying codec / import path (incl. `ReferenceImport`).
- **GUI:** `EncodingPanel`, `TransferQueueView`,
  `DownloadStartDialog`, `ExportPanel` show a **determinate**
  `ProgressBar` + phase label + `% / bytes`. Indeterminate only
  when a total is genuinely unknowable (streaming
  `expected_au_count = 0`), and even then show bytes-so-far +
  elapsed.

**Acceptance:**
- [ ] No client↔server op (or its bracketing encode/decode)
      presents only an indeterminate/static state.
- [ ] Encode / upload / download / export each show phase + %
      (bytes-based) wherever a total is known.
- [ ] `WorkbenchTransportClient` progress callback shipped in
      both languages; cross-language parity verified.
- [ ] Re-running the `whale_sequences` encode+upload shows live
      phase + % the whole way through.

## W6.2 — BYOK + envelope encryption client

**Goal:** spec UC-03.2/3 on the client side. A researcher
supplies a public key; the client builds `ProtectionMetadata` and
encrypts the `.tis` stream before upload (BYOK), or wraps the DEK
under both the server KEK and the researcher key (envelope), or
runs full ENCRYPTED / ENCRYPTED_HEADER mode.

**Deliverables:**
- `python/src/ttio/workbench/encryption.py` — thin client wrapper
  over the core `ttio.encryption` + `ttio.transport.encrypted`,
  producing the upload-path `ProtectionMetadata`. BYOK / envelope
  / ENCRYPTED / ENCRYPTED_HEADER modes.
- Java mirror under `global.thalion.ttio.workbench.encryption.*`.
- Wire into the W1 transport upload path (an optional
  `protection=` arg).
- Cross-language anchor: the `ProtectionMetadata` JSON for a
  fixed BYOK key.

**Acceptance:** BYOK round-trip — encrypt with a researcher key
→ upload → re-download → decrypt with the same key → bytes
match (deferred live-daemon variant; unit-level byte-equivalence
in this PR).

## W6.3 — PQC client

**Goal:** ML-KEM-1024 + ML-DSA-87 via the core `ttio.pqc`
(pyoqs), gated by the `opt_pqc_preview` StreamHeader flag.

**Deliverables:**
- `python/src/ttio/workbench/pqc.py` — client surface; refuses
  unless `opt_pqc_preview` is set (matches server gating).
- Java mirror.
- Cross-language anchor on the PQC-wrapped envelope shape.

**Acceptance:** PQC round-trip with `opt_pqc_preview` enabled
(unit-level; live variant deferred).

## W6.4 — Format expansion

**Goal:** every format in spec §4 reachable via `ttio encode
--format <fmt>`, matching the GUI's existing 13-format coverage.

**Deliverables:**
- `ttio.tools.workbench_cli` — promote the `encode` / `export`
  dispatch from the `fastq | fasta` stub to the full set,
  dispatching to the existing per-format importer/exporter
  modules (the same backends the tio-browser
  `ImportFormatRegistry` / `ExportFormatRegistry` already use).
- Confirm GUI ↔ CLI ↔ SDK parity (all three cover the same
  format list).

**Acceptance:** `ttio encode --format <fmt>` works for every
spec §4 entry that has a codec; unknown formats fail with a
clear message.

## W6.5 — Federation client

**Goal:** spec §12.3 client surface that gracefully degrades
against a single-node v1.0 server.

**Deliverables:**
- `python/src/ttio/workbench/federation.py` —
  `client.federation().peers()` hits `/v1/federation/peers`;
  on 404 (v1.0 single-node) returns an empty peer list instead
  of raising.
- Java mirror.
- Unit test: 404 → empty list, not an error.

**Acceptance:** federation client treats a v1.0 server as
single-node (no error).

## W6.6 — SDK docs + finalisation

**Goal:** release-quality reference docs + a runnable tutorial.

**Deliverables:**
- Sphinx (Python) + Javadoc (Java) for the `workbench` surface,
  auto-built in CI.
- Tutorial notebook in `python/docs/tutorials/` expanding the
  spec §8.3 example (ingest → upload → query → submit →
  download).
- Final CHANGELOG roll-up; consider tagging the Python package
  (`ttio==1.3.x`) + Java artifact once W6 lands.

**Acceptance:** docs build in CI; the tutorial runs end-to-end
against a live daemon (reusing the W5 live-smoke harness).

## Out of scope (carried from the workplan)

- Rust SDK (v1.2).
- Web/mobile clients (v2).
- Live sequencer ingestion.
- Cost-accounting UI.

## Cross-repo note

W6 is TTI-O-only (python + java + tio-browser + docs). No server
changes expected — the v1.0 server already exposes the
ProtectionMetadata path + feature flags; the federation endpoint
is intentionally absent in v1.0 and the client no-ops against
that. Any server gap surfaced (as with the cohort handler in the
live smoke) gets a tti-workbench-server follow-up, not a TTI-O
workaround.
