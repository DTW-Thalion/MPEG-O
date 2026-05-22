# Multi-recipient `ProtectionMetadata` conformance vectors (FD-1 Phase A-4)

`vectors.json` is the cross-language byte contract for the FD-1 Phase A
multi-recipient `ProtectionMetadata` wire format. It is generated from the
Python reference encoder (`gen_vectors.py`) and asserted byte-equal by the
Python, Java, and ObjC conformance suites:

| language | test |
|----------|------|
| Python   | `python/tests/conformance/test_multi_recipient_xlang.py` |
| Java     | `java/.../protection/MultiRecipientXLangTest.java` |
| ObjC     | `objc/Tests/TestMultiRecipientXLang.m` |

Each test reads this file, reconstructs each vector's inputs, and asserts:

1. **encode** — its `encodeRecipientBlock(additional_recipients)` equals
   `recipient_block_hex`;
2. **decode** — decoding `recipient_block_hex` yields the same recipient
   list (round-trip `encode∘decode = id`).

Because every language asserts against the *same* committed hex,
`python == golden ∧ java == golden ∧ objc == golden ⟹ python == java == objc`
— byte-parity is transitive, with no cross-language runtime plumbing.

The Python suite additionally pins the full protection-metadata `body_hex`
(the §4.4 primary fields + the trailing block) and the pre-Phase-A
primary-recovery guarantee (`pre_phase_a_primary`): an un-upgraded reader of
a multi-recipient packet parses only the five §4.4 fields and recovers the
primary recipient. Java/ObjC full-body parity follows transitively — the
five-field §4.4 prefix is locked by the existing single-recipient golden
fixtures, and the trailing block is pinned here.

## Vectors

| name | recipients | notes |
|------|-----------|-------|
| `prot_single_byok` | 1 | empty wrapped DEK; **no** trailing block (byte-identical to transport-spec §4.4) |
| `prot_single_envelope` | 1 | aes-256-gcm wrapped DEK |
| `prot_single_pqc` | 1 | ml-kem-1024 wrapped DEK |
| `prot_multi_server_researcher` | 2 | primary server aes-256-gcm + researcher ml-kem-1024 (the FD-1 output shape) |
| `prot_multi_three` | 3 | mixed algorithms, exercises the loop |

## Regenerating

```sh
python conformance/multi_recipient/gen_vectors.py
```

**Do not hand-edit `vectors.json`.** A change to the golden bytes is a
wire-format change — re-run the generator, review the diff, and justify it
against the [Phase A spec](../../docs/superpowers/specs/2026-05-21-fd1-phase-a-multi-recipient-protection-metadata-spec.md).
Spec §6 defines this corpus.
