# Plan — per-AU encrypted upload (W6.2 rework)

**Status:** scheduled (2026-05-20). Supersedes the blob-level BYOK
approach shipped in W6.2.

## Why

W6.2 sealed an entire upload payload into one opaque AES-GCM blob
(`ttio.workbench.encryption.seal` / `WorkbenchClient.upload_protected`).
The 3.2 live-daemon validation (see
[`../parity-audit-v1.0.md`](../parity-audit-v1.0.md) §3.2) proved this
**cannot round-trip through the daemon**:

- The daemon parses every upload as a transport stream and rejects
  bytes without valid packet magic (`transport stream error: invalid
  packet magic`). An opaque ciphertext blob is refused outright.
- On download the daemon **re-encodes** a fresh `.tis` from stored
  state — uploads are not byte-preserved, only the *data* round-trips.
  So even if a blob were accepted, it would not come back verbatim.

The blob model passed its unit tests only because they never touched a
daemon. The correct model is **per-AU encryption**: encrypt the channel
payloads (and optionally AU headers) *inside* an otherwise-valid `.tis`,
carry a `ProtectionMetadata` packet in the stream, and let the daemon
ingest and re-emit it like any other stream. The encrypted AU payloads
travel as opaque bytes the daemon never needs to interpret.

## What already exists (reuse, don't rebuild)

The per-AU crypto + encrypted transport already exist in all three
core libraries — only the *workbench-client wiring* is missing.

| Capability | Python | Java | ObjC |
|---|---|---|---|
| Per-AU encrypt a `.tio` | `encryption_per_au.encrypt_per_au` | `PerAUFile.encryptFile` | `TTIOPerAUFile` |
| Per-AU decrypt (read) | `encryption_per_au.decrypt_per_au` | `PerAUFile` | `TTIOPerAUFile` |
| Encrypted `.tio` → `.tis` | `transport.encrypted.write_encrypted_dataset` | `EncryptedTransport.writeEncryptedDataset` | `TTIOEncryptedTransport` |
| Encrypted `.tis` → `.tio` | `transport.encrypted.read_encrypted_to_file` | `EncryptedTransport.readEncryptedToPath` | `TTIOEncryptedTransport` |
| Detect encrypted file | `is_per_au_encrypted` | `isPerAUEncrypted` | — |

The W6.2/W6.3 client wrappers (`workbench/encryption.py`,
`workbench/pqc.py`) and the `ProtectionMetadata` JSON anchor are kept;
only the blob `seal`/`open` upload path is replaced.

## Phase 0 — daemon faithfulness (GATING; do this first)

**Open question:** does the daemon's ingest → re-emit preserve an
encrypted `.tis` end-to-end — specifically the `ProtectionMetadata`
packet and the encrypted AU channel payloads (and the
`opt_per_au_encryption` feature flag)? If the daemon re-codecs AU
payloads (e.g. recompresses) or drops the protection packet, encrypted
upload needs daemon-side work too.

**Validate against a real daemon** (reuse `scripts/workbench-live-smoke.sh`):
encrypt a `.tio` per-AU → `write_encrypted_dataset` → `upload_bytes`
→ `download_bytes` → `read_encrypted_to_file` → `decrypt_per_au` →
assert the plaintext channels match the original. If this passes, the
rework is pure client wiring (Phases 1-3). If it fails, file a
`tti-workbench-server` issue first.

### Phase 0 RESULT: GREEN (resolved 2026-05-21)

**Initial finding (2026-05-20): RED.** Run against a real daemon, the
encrypted `.tis` was accepted (valid packet magic — per-AU encryption
produces a valid stream, unlike opaque-blob BYOK), but the **re-emitted**
stream on download had **no `ProtectionMetadata` packet and its AUs
lacked the `ENCRYPTED` flag** (`read_encrypted_to_file` →
"encrypted-transport reader saw plaintext AU"). The encode/read path
round-tripped perfectly **locally** (`tests/test_encrypted_transport.py`),
so the gap was **daemon-side**: ingest + the download re-encode dropped
the protection packet and per-AU flags. Filed as `tti-workbench-server`
issue #30.

**Resolved by `tti-workbench-server` #31** (encryption-aware passthrough:
the daemon now detects an encrypted stream on ingest, stores the raw
`.tis` verbatim as an opaque blob — `encrypted:YES` — instead of
materialising to `.tio`, and streams it back unchanged on download).
Re-validated against a daemon built from merged server `main`:
`test_workbench_live.py::test_per_au_encrypted_upload_round_trip` now
**passes** (encrypt → upload → download → decrypt → channel values
match); full live suite 10/10.

**Phases 1-4 are now unblocked.** Client-side per-AU encrypt/decrypt +
encrypted-`.tis` encode already work; the daemon preserves the stream.

## Phases

1. **Python client path — DONE.** `WorkbenchClient.upload_encrypted(*,
   project, container_uri, tio_path, key, encrypt_headers=False)`
   encrypts a *copy* of the `.tio` per-AU (`encrypt_per_au`) →
   `write_encrypted_dataset` → `upload_bytes`.
   `download_decrypted(*, container_uri, key, out_tio_path)` →
   `download_bytes` → `read_encrypted_to_file` (materialises the
   still-encrypted `.tio`) → returns `decrypt_per_au(...)` channels.
   The daemon-incompatible blob `upload_protected` / `download_and_open`
   now raise `NotImplementedError` pointing here. Validated e2e by
   `test_per_au_encrypted_upload_round_trip` (live smoke, 10/10).
2. **Java mirror** (lockstep, Decision 2): `WorkbenchClient.uploadEncrypted`
   / `downloadDecrypted` over `PerAUFile` + `EncryptedTransport`.
3. **PQC variant** (`opt_pqc_preview`): the same path with an ML-KEM
   wrapped DEK in the `ProtectionMetadata`, gated as in W6.3.
4. **Live round-trips** added to `workbench-live` (the deferred §3.2
   tests): BYOK + envelope + PQC encrypt → upload → download → decrypt.

## Acceptance

- A per-AU-encrypted `.tio` round-trips through the **real daemon**:
  encrypt → upload → download → decrypt → channel data matches.
- Wrong key fails to decrypt; `opt_pqc_preview` still gates PQC.
- Python + Java lockstep; cross-language `ProtectionMetadata` anchor
  preserved.
- The misleading blob-BYOK upload path is removed or clearly fenced off
  as non-daemon (in-memory only).

## Out of scope

- New crypto primitives (per-AU AES-GCM + ML-KEM wrap already exist).
- ObjC client wiring (ObjC stays server-runtime; Decision 2).
