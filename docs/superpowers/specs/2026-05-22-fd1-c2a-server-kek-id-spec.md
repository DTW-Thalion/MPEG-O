# FD-1 Phase C-2a — `server_kek_id` in `ProtectionMetadata` (wire spec + proof)

**Status:** SPEC-PROOF (pre-implementation). Append-only wire change →
proof phase required before code (per `feedback_phase_0_spec_proof`, the
discipline applied to Phase A). Backward-compat claims below are
demonstrated by the executable proof at
[`2026-05-22-fd1-c2a-server-kek-id-proof.py`](2026-05-22-fd1-c2a-server-kek-id-proof.py)
(run: `python3 docs/superpowers/specs/2026-05-22-fd1-c2a-server-kek-id-proof.py`;
all 7 points PASS against the real current decoder).

**Context:** FD-1 Phase C-2 (`tti-workbench-server`
`Documentation/c2-submit-authz-design.md`). The daemon must decide at job
**submit** time whether an encrypted container is server-processable, which
hinges on a **server-resolvable `kek_id`**. The daemon already inspects the
`ProtectionMetadata` packet *type* at upload but never its body; carrying
the `kek_id` *in that packet* lets the daemon record it at upload (no
materialize) and answer `409 container_not_server_decryptable` at submit for
BYOK/unresolvable containers. This spec adds that field, append-only,
without breaking Phase A / §4.4 packets.

## 1. Goal

Add an optional `server_kek_id` to `ProtectionMetadata` that names the KEK
under which the **primary** recipient's `wrapped_dek` is wrapped (the
primary is the server recipient for the UC1 input shape). It must:

1. be **byte-identical to today** for containers with neither additional
   recipients nor a `server_kek_id` (pure BYOK / §4.4 single-recipient); and
2. let current (Phase A / pre-C-2a) readers parse a packet that carries
   `server_kek_id` without error, recovering the primary (+ any additional)
   recipient.

## 2. Current format (verified)

transport-spec §4.4 + the Phase A append-only recipient block:

```
cipher_suite        u16 len + bytes
kek_algorithm       u16 len + bytes
wrapped_dek         u32 len + bytes
signature_algorithm u16 len + bytes
public_key          u32 len + bytes
# Phase A: present iff additional_recipient_count > 0
additional_recipient_count u16
  repeated: recipient_id (u16+bytes), kek_algorithm (u16+bytes), wrapped_dek (u32+bytes)
```

Current readers (`_decode_protection_metadata`, ObjC `parseProtection`,
Java `parseProtection`) read the five fields, then — if bytes remain —
decode the recipient block and **stop**, ignoring anything after it.

## 3. New format (append-only) — normative

A trailing section is emitted **iff** there are additional recipients
**OR** a `server_kek_id`:

```
# --- present iff (additional_recipient_count > 0) OR server_kek_id present ---
additional_recipient_count u16
  repeated additional_recipient_count times:
    recipient_id (u16+bytes), kek_algorithm (u16+bytes), wrapped_dek (u32+bytes)
# --- present iff server_kek_id present (detected by "bytes remain") ---
server_kek_id  u16 len + UTF-8
```

- `server_kek_id` is a dedicated field — **not** overloaded onto
  `recipient_id` or `kek_algorithm`. It is an opaque label the daemon
  resolves via its key custody.
- **Detection:** after the recipient block, any remaining bytes are the
  `server_kek_id`.
- A single-recipient **server-processable** container emits
  `additional_recipient_count = 0` followed by `server_kek_id`. This is the
  one case where a count of 0 is serialized; Phase A already permits readers
  to tolerate a literal 0 (Phase A spec §5.4), so existing readers handle
  it (recover the primary, ignore the trailing field) — see P2a.
- A container with **neither** additional recipients **nor** `server_kek_id`
  emits **no** trailing section → byte-identical to §4.4 (P1).
- Absent `server_kek_id` ⇒ not server-processable ⇒ the daemon answers
  `409` (BYOK / researcher-only / PQC-to-researcher).

## 4. Backward / forward compatibility — proof (P1–P4)

Demonstrated against the real current decoder:

- **P1** — no additional + no `server_kek_id` ⇒ byte-identical to §4.4.
- **P2a/P2b** — the current reader recovers the primary (+ additional) from
  a packet carrying `server_kek_id`, ignoring the trailing field; no error.
- **P3a/P3b** — the proposed C-2a decoder recovers `server_kek_id` and all
  recipients.
- **P4a/P4b** — regression: §4.4 and Phase A multi packets still decode; the
  C-2a decoder reports `server_kek_id = None` for them.

No `format_version` bump: the change is self-describing (trailing bytes
after the recipient block ⟺ `server_kek_id`) and invisible to producers /
consumers that set none. Trailing-section parsing stays bounded by the
packet header's `payload_length`.

## 5. Invariants

1. `server_kek_id`, when present, names the KEK of the **primary** recipient
   (index 0). The daemon resolves it via `TTIOWBKeyCustody.resolvesKekId:`
   and unwraps the primary `wrapped_dek` with it at job start (Phase D).
2. `server_kek_id` is informational to non-server consumers (the researcher
   downloads by `recipient_id` as before); only the daemon acts on it.
3. A BYOK / researcher-only container MUST NOT carry a `server_kek_id`.

## 6. Implementation plan (C-2a sub-steps, after this proof)

- **Python:** `_emit_protection_metadata(..., server_kek_id=None)` appends
  the field; `_decode_protection_metadata` returns `server_kek_id`;
  `stamp_transport_wrapped_dek` / `read_transport_*` thread it; the W-client
  `upload_encrypted_multi` grows a `server_kek_id` arg.
- **Java / ObjC:** mirror emit + parse; expose `server_kek_id` on the
  decoded `ProtectionMeta`.
- **Conformance (A-4 style):** extend the golden vectors with a
  `prot_server_kek_id` case asserting byte-parity + the pre-C-2a
  primary-recovery (P2) frozen vector.

## 7. Non-goals

- The server-side authz / 409 / audit (FD-1 Phase C-2b, server repo).
- Changing single-recipient byte output for non-server-processable
  containers (unchanged — P1).
