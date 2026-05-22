# FD-1 Phase A — Multi-recipient `ProtectionMetadata` Wire Spec + Proof

**Status:** SPEC-PROOF (pre-implementation). Wire-format-breaking change →
proof phase required before code (per the discipline applied to M94.X /
phase-2c-T). The backward-compat claims below are demonstrated by the
executable proof at
[`2026-05-21-fd1-phase-a-proof.py`](2026-05-21-fd1-phase-a-proof.py)
(run: `python3 docs/superpowers/specs/2026-05-21-fd1-phase-a-proof.py`).

**Context:** Phase A of the FD-1 plan
(`tti-workbench-server` `Documentation/encrypted-pipeline-processing.md`
§8). FD-1's processed output wraps the per-run DEK for **multiple
recipients** (server KEK + researcher key). The transport
`ProtectionMetadata` packet today carries exactly one wrapped DEK; this
spec extends it to N, **without** breaking existing BYOK / envelope / PQC
containers, and is the prerequisite for Phases B–F.

## 1. Problem and goal

A per-run DEK can be wrapped independently for several recipients (same
DEK, different KEKs). The container must carry one wrapped copy per
recipient so either party recovers the DEK. The wire carrier is the
`ProtectionMetadata` packet (transport-spec §4.4), which is single-DEK
today. Goal: a multi-recipient layout that

1. is **byte-identical to today for the single-recipient case** (BYOK,
   envelope, PQC — the overwhelmingly common case), so existing files,
   fixtures, and golden bytes are untouched; and
2. lets current (un-upgraded) readers parse a multi-recipient packet
   without error, recovering at least the primary recipient.

## 2. Current format (verified)

transport-spec §4.4, little-endian, identical in Python / Java / ObjC:

```
cipher_suite_len:    uint16 ; cipher_suite:        bytes
kek_algorithm_len:   uint16 ; kek_algorithm:       bytes
wrapped_dek_len:     uint32 ; wrapped_dek:         bytes
signature_algo_len:  uint16 ; signature_algorithm: bytes
public_key_len:      uint32 ; public_key:          bytes
```

Verified reader behaviour (the compat lever):

- **Python** `_decode_protection_metadata` reads all five fields and
  returns; it does **not** assert end-of-payload, so trailing bytes are
  ignored.
- **Java** `EncryptedTransport.parseProtection` reads only
  `cipher_suite`/`kek_algorithm`/`wrapped_dek` and returns, ignoring
  `signature_algorithm`, `public_key`, and anything after.
- The daemon does not parse the body for storage — it detects the packet
  *type* (`0x04`) to flag the stream `encrypted:YES` and stores it
  verbatim (#31). So the daemon is format-agnostic here.

## 3. New wire format (append-only multi-recipient) — normative

The existing five fields are retained **unchanged** as the **primary
recipient**. When (and only when) there are additional recipients, an
optional trailing block is appended:

```
# --- primary recipient (identical to §4.4) ---
cipher_suite_len:        uint16 ; cipher_suite:        bytes
kek_algorithm_len:       uint16 ; kek_algorithm:       bytes   # primary recipient KEK algo
wrapped_dek_len:         uint32 ; wrapped_dek:         bytes   # primary wrapped DEK
signature_algo_len:      uint16 ; signature_algorithm: bytes
public_key_len:          uint32 ; public_key:          bytes
# --- OPTIONAL trailing block; present iff additional_recipient_count > 0 ---
additional_recipient_count: uint16
  repeated additional_recipient_count times:
    recipient_id_len:    uint16 ; recipient_id:        bytes   # opaque, e.g. "researcher", "server:kek-proj-42"
    kek_algorithm_len:   uint16 ; kek_algorithm:       bytes
    wrapped_dek_len:     uint32 ; wrapped_dek:         bytes
```

- **Total recipients** = 1 (primary) + `additional_recipient_count`.
- A single-recipient packet **MUST NOT** emit the trailing block (not
  even `additional_recipient_count = 0`), so it stays byte-identical to
  §4.4.
- `recipient_id` is an opaque UTF-8 label used by a reader to pick the
  entry it holds a key for; the empty string denotes the primary.
- The primary recipient SHOULD be the entry an un-upgraded consumer is
  most likely to need (for FD-1 server output, the server KEK).

## 4. Backward / forward compatibility — proof

Demonstrated by the executable proof (P1–P4) against the real decoder:

- **P1 — single-recipient is byte-identical.** `encode_multi(...,
  additional=[])` produces bytes equal to the current encoder. ⇒ existing
  BYOK / envelope / PQC containers and golden fixtures are unchanged; no
  re-encoding, no version bump needed for the common case.
- **P2 — new reader reads old packets.** An old packet has no trailing
  block; the new decoder, after the five fields, sees `off == len` and
  yields exactly one recipient — identical semantics. (Symmetric to P1.)
- **P2 (cont.) — old reader reads new packets.** The current Python and
  Java readers parse the primary fields and ignore the trailing block, so
  a multi-recipient packet decodes without error, recovering the primary
  recipient. Verified: `_decode_protection_metadata(multi)` returns the
  primary `wrapped_dek` and raises nothing.
- **P3 — new reader recovers all N.** The proposed decoder returns the
  primary plus each trailing recipient with its `recipient_id` /
  `kek_algorithm` / `wrapped_dek`.
- **P4 — regression.** Today's packets still decode under the current
  reader.

No `format_version` bump is required: the format is **self-describing**
(trailing block present ⟺ multi-recipient) and the change is invisible to
single-recipient producers/consumers. A reader distinguishes "no more
bytes" (1 recipient) from "trailing block" purely by remaining length,
which is bounded by the packet header's `payload_length`.

## 5. Invariants & validation

1. All recipients wrap the **same** 32-byte DEK under different KEKs
   (semantic contract; not structurally checkable). Unwrapping any
   recipient MUST yield the identical DEK.
2. `recipient_id` values within a packet are unique; the primary's id is
   the empty string.
3. A reader selecting a recipient: match by the key it holds (by
   `recipient_id` or by attempting unwrap); if none match → the container
   is not decryptable by this party (for the daemon: the BYOK-refusal /
   `409` path in server Phase C).
4. `additional_recipient_count == 0` MUST NOT be serialized (omit the
   block). Readers MAY tolerate a literal `0` for robustness but writers
   never emit it.
5. Trailing-block parsing is bounded by `payload_length`; a truncated or
   over-long block is a hard parse error (malformed packet).

## 6. Test corpus (Phase A-4 cross-language conformance)

Golden byte vectors checked into `conformance/` and asserted byte-equal
across Python / Java / ObjC:

- `prot_single_byok` — 1 recipient, empty wrapped DEK (BYOK). MUST equal
  the existing golden (regression that single-recipient is unchanged).
- `prot_single_envelope` — 1 recipient, aes-256-gcm wrapped DEK.
- `prot_single_pqc` — 1 recipient, ml-kem-1024 wrapped DEK.
- `prot_multi_server_researcher` — 2 recipients: primary = server
  aes-256-gcm KEK; additional[0] = researcher ml-kem-1024.
- `prot_multi_three` — 3 recipients, mixed algorithms, to exercise the
  loop.

Each language MUST: (a) encode each vector to identical bytes; (b) decode
each to the same recipient list; (c) round-trip (encode∘decode = id); and
(d) decode a multi-recipient vector with the *pre-Phase-A* reader and
recover the primary (the P2 guarantee), pinned as a frozen byte vector.

## 7. Implementation plan (Phase A sub-steps)

- **A-1 (Python) — DONE.** `_emit_protection_metadata` /
  `_decode_protection_metadata` carry the append-only recipient block;
  `write_encrypted_dataset` / `read_encrypted_to_file` carry the
  additional recipients via a `<channel>_wrapped_dek_recipients` storage
  attribute; `stamp_transport_wrapped_dek` grows an
  `additional_recipients` arg and `read_transport_recipients` returns the
  full list (`read_transport_wrapped_dek` stays the single-recipient
  accessor). Single-recipient stays byte-identical. Covered by
  `tests/test_fd1_multi_recipient_protection.py`.
- **A-2 (Java) — DONE.** `EncryptedTransport` gains a public `Recipient`
  record; `encodeProtection` appends the trailing block,
  `parseProtection` consumes signature/public-key then decodes it into
  `ProtectionMeta.additionalRecipients`; the write/materialize paths
  carry a base64 `<channel>_wrapped_dek_recipients` storage attribute;
  `stampTransportWrappedDek` gains a multi-recipient overload and
  `readTransportRecipients` returns the full list. Covered by
  `MultiRecipientProtectionTest`. The block encoder is byte-identical to
  Python's (the A-4 conformance contract).
- **A-3 (ObjC) — DONE.** `TTIOEncryptedTransport` gains
  `encodeRecipientBlock` / `decodeRecipientBlock` (byte-identical to
  Python/Java); `parseProtection` consumes signature/public-key then the
  trailing block into `ProtectionMeta.additionalRecipients`; the MS +
  genomic write paths append the stored block, and both materialize paths
  persist it as `<channel>_wrapped_dek_recipients`. Covered by
  `TestFD1MultiRecipient`. ObjC is server-runtime (no workbench client),
  so there is no stamp/read client helper here.
- **A-4 (cross-language).** The §6 conformance vectors wired into the
  parity harness; assert byte-parity + the pre-Phase-A primary-recovery
  vector.

The storage-attribute representation of multiple wrapped DEKs (the
`<channel>_wrapped_dek` run attribute, which today holds one blob) is
extended in lockstep — a parallel `<channel>_wrapped_dek_recipients`
structure or a length-prefixed concatenation — specified in A-1 and
mirrored in A-2/A-3. (Per-language on-disk encoding need not match across
languages, as established for the vibrational attrs in §3.1; only the
transport packet bytes are the cross-language contract.)

## 8. Non-goals

- Changing single-recipient behaviour or any existing golden bytes.
- The server-side decrypt/process logic (FD-1 Phases C–F) — this spec is
  only the wire carrier (Phase A) + its client API consumes it (Phase B).
- A `format_version` bump — shown unnecessary in §4.
