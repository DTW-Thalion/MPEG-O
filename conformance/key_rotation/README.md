# `dek_wrapped` envelope-encryption cross-language conformance

These fixtures are the cross-language contract for the dataset-level
envelope-encryption wrapped-DEK stored at
`/protection/key_info/dek_wrapped`. They prove that a `dek_wrapped`
blob written by one language is correctly **read and unwrapped** by the
others — the NxN writer×reader matrix.

## Why this exists

A bug shipped where Python stored `dek_wrapped` spec-compliantly
(`uint8[N]`, exact length) but Java/ObjC stored it as an `int32`-packed,
4-byte-padded dataset. A file written by one language then crashed
(`ClassCastException`) or corrupted (the 1639-byte ML-KEM blob truncated
to 60) when read by another. All three now write `uint8[N]`. **Its
absence is why the bug shipped** — there was no test that read one
language's `dek_wrapped` from another.

## Layout

| file | contents |
|------|----------|
| `kek_aes.bin` | fixed 32-byte AES-256-GCM KEK (all `0x2b`) |
| `kek_mlkem_pub.bin` / `kek_mlkem_priv.bin` | fixed ML-KEM-1024 keypair (1568 / 3168 bytes) |
| `fixtures/<writer>_<alg>.tio` | one reference `.tio` per writer × algorithm |
| `expected.json` | per-fixture algorithm + expected plaintext DEK hex |

`dek_wrapped` must be `uint8[N]` at the exact blob length: **71 bytes**
for AES-GCM, **1639 bytes** for ML-KEM-1024.

## Coverage

| algorithm | blob | writers |
|-----------|------|---------|
| `aes-256-gcm` | 71 B | Python, Java, ObjC (full 3×3) |
| `ml-kem-1024` | 1639 B | Python, ObjC |

ML-KEM is covered for Python/ObjC only: the Java `KeyRotationManager`
exposes no dataset-level PQC enable/read path. PQC fixtures are skipped
when liboqs is unavailable.

## The tests

Each language reads **every** committed fixture, unwraps with the
shared KEK, and asserts the recovered DEK equals `expected_dek_hex`:

| language | test |
|----------|------|
| Python | `python/tests/conformance/test_dek_wrapped_xlang.py` |
| Java | `java/.../protection/DekWrappedXLangTest.java` (AES only) |
| ObjC | `objc/Tests/TestDekWrappedXLang.m` |

Tests skip gracefully when a peer build / liboqs is unavailable.

## Regenerating

The fixtures are produced by driving each language's `wrap` CLI
(`ttio.tools.dek_envelope_cli` / `DekEnvelopeCli` / `TtioDekEnvelope`):

```sh
python conformance/key_rotation/gen_fixtures.py
```

Because AES-GCM and ML-KEM ciphertexts embed fresh random IVs /
encapsulations, the `.tio` bytes are **not** reproducible run-to-run;
the committed contract is the *unwrappability* of each fixture to its
committed DEK, not byte-identity of the file. Re-run the generator with
all three toolchains built and review the `expected.json` diff.
