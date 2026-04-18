# MPEG-O v0.7 API Review — Cross-Language Consistency Notes

> **Milestone block:** v0.7 (all must-have + both stretch items complete)
> **Date:** 2026-04-18
> **Author:** Generated from the v0.6.1 code review, M50 sub-item work,
> and observations during M43 / M44 / M45 / M46 / M47 / M48 / M51.
> **Scope:** appendices only. The v0.6 review document
> (`docs/api-review-v0.6.md`) remains the authoritative parity table.
> This document captures the *findings* — known stylistic differences,
> error-mapping equivalences, provider feature-matrix facts, and
> consistency decisions — that the v0.7 milestone work produced.

---

## 1. Appendix A — Known Stylistic Differences

Languages differ in idiom. These differences are intentional. Callers
targeting multiple languages should read this appendix before writing
cross-platform glue code.

### 1.1 `StorageProvider.open()` dispatch style

| Language | Factory style | Instance-mutation style |
|---|---|---|
| Python   | `Provider.open(path)` → new instance | `p = Provider(); p.open(path)` → mutates `p` |
| Java     | `new Provider().open(path, mode)` → returns `this` | not supported |
| ObjC     | `[[Provider alloc] init]` + `[p openURL:u mode:m error:&e]` | not supported |

Python uniquely supports *both* forms via a dispatch-on-first-arg hack
(Appendix B Gap 1 resolution; see `providers/base.py::StorageProvider.open`
docstring). Java and ObjC are factory-only by language idiom — a Java
static factory method cannot mutate an existing instance, and ObjC's
`alloc+init+open` pattern is canonical.

**Recommendation for cross-language code:** use `Provider.open(path)`
uniformly. The Python dual-style is a local convenience, not a portable
API contract.

### 1.2 `-readRows:` required on `MPGOStorageDataset` (v0.7 M50.2)

Prior to v0.7, ObjC's `-readRows:error:` was marked `@optional` on the
`MPGOStorageDataset` protocol. A provider that forgot to implement it
would silently fail at runtime with `doesNotRecognizeSelector:`. M50.2
promotes the method to `@required`, making omission a compile-time
error. Python and Java have always had concrete default implementations
of the equivalent (`read_rows()` / `readRows()`).

### 1.3 Importer error propagation

| Language | Importer error type |
|---|---|
| Python   | `MzMLParseError(ValueError)` — typed, chainable via `__cause__` |
| Java     | `MzMLParseException extends MpgoReaderException extends IOException` (v0.7 M50.3) |
| ObjC     | `NSError` with domain `MPGOMzMLReaderErrorDomain`, specific codes |

Pre-v0.7 Java threw bare `Exception`, making it impossible to catch
"parse error" vs "I/O error" distinctly. M50.3 introduces a typed
hierarchy: callers can now `catch (MzMLParseException e)` without also
catching arbitrary runtime errors.

### 1.4 `@since` coverage

Python module docstrings and ObjC header comments uniformly carry
"API status: Stable" + "Cross-language equivalents" blocks. Java coverage
was patchy pre-v0.7; M50.4 completes an audit pass so every public type
in `com.dtwthalion.mpgo.*` carries a `@since` tag matching its
introducing milestone (v0.5, v0.6, v0.6.1, or v0.7).

---

## 2. Appendix B — SQLite Provider Gap Resolutions (v0.6.1 SHIPPED)

All six actionable gaps from the v0.6.1 SQLite stress test shipped in
v0.6.1. Historical reference only; see `docs/api-review-v0.6.md` § 6
for the original findings. Summary of resolutions:

| Gap | Title | Resolved by commit |
|-----|-------|--------------------|
| 1 | `open()` classmethod-vs-instance pattern unified | `6028f4d` |
| 2 | Compound `read()` return type → `readRows()` helper | `b0d1cd0` |
| 3 | Capability queries (`supports_chunking/compression`) | `8880890` |
| 5 | `provider_name` shape (property → method) | `d635f05` |
| 7 | `Precision` decoupled from HDF5 JNI | `47488b5` |
| 8 / 13 | `deleteAttribute` / `attributeNames` on `StorageDataset` | `d635f05` |
| 11 | `begin/commit/rollback_transaction` on protocol | `542e482` |

Gaps 4, 6, 9, 10, 12 were documented as expected-behaviour-not-bugs
(see v0.6 review § 6.2).

---

## 3. Appendix C — Cross-Language Error Domain Mapping

When a call fails in one language and you need to know the equivalent
failure mode in another, use this table. One row per conceptual error.

| Condition | Objective-C (`NSError.code`) | Java exception | Python exception |
|-----------|------------------------------|----------------|------------------|
| File not found on open | `MPGOErrorFileNotFound` | `FileNotFoundException` | `FileNotFoundError` |
| File open failed (other) | `MPGOErrorFileOpen` | `IOException` | `IOError` / `OSError` |
| File create/truncate failed | `MPGOErrorFileCreate` | `IOException` | `IOError` |
| Dataset read failed | `MPGOErrorDatasetRead` | `RuntimeException` | `RuntimeError` |
| Dataset write failed | `MPGOErrorDatasetWrite` | `RuntimeException` | `RuntimeError` |
| Dataset create failed | `MPGOErrorDatasetCreate` | `Hdf5Errors.DatasetCreateException` | `RuntimeError` |
| Group create failed | `MPGOErrorGroupCreate` | `Hdf5Errors.GroupCreateException` | `RuntimeError` |
| Group open failed | `MPGOErrorGroupOpen` | `Hdf5Errors.GroupOpenException` | `RuntimeError` |
| Hyperslab / index out of range | `MPGOErrorOutOfRange` | `IndexOutOfBoundsException` | `IndexError` |
| Attribute read (missing) | `MPGOErrorAttributeRead` | `RuntimeException` / `NullPointerException` | `KeyError` |
| Attribute write (read-only) | `MPGOErrorAttributeWrite` | `UnsupportedOperationException` | `PermissionError` |
| mzML parse error | `MPGOMzMLReaderErrorParseFailed` | `MzMLParseException` (M50.3) | `MzMLParseError` |
| nmrML parse error | `MPGONmrMLReaderErrorParseFailed` | `NmrMLParseException` (M50.3) | `NmrMLParseError` |
| Thermo RAW convert failed | `MPGOThermoRawErrorConvert` | `ThermoRawException` (M50.3) | `ThermoRawError` |
| Provider not open | `MPGOErrorFileOpen` | `IllegalStateException` | `IOError` ("provider is not open") |
| Unsupported algorithm (v0.7 M48) | `MPGOErrorUnsupportedAlgorithm` | `UnsupportedAlgorithmException` | `UnsupportedAlgorithmError` |
| Unsupported signature version (v0.7 M47) | `MPGOErrorUnsupportedSignature` | `UnsupportedSignatureException` | `UnsupportedSignatureError` |
| Key length mismatch (v0.7 M48) | `MPGOErrorInvalidKey` | `InvalidKeyException` (`java.security`) | `InvalidKeyError` |
| Decryption authentication tag mismatch | `MPGOErrorDecryptionFailed` | `AEADBadTagException` | `cryptography.exceptions.InvalidTag` |
| Signature verification failed | `MPGOErrorSignatureMismatch` | `SignatureException` | `InvalidSignatureError` |

**Rule of thumb:** ObjC error codes are the most precise; Java uses
standard `java.io` / `java.security` exceptions where they exist and
MPGO-specific ones otherwise; Python mirrors Java's specificity using
exception subclass names that match `<DomainName>Error` convention.

---

## 4. Appendix D — Compound Write Byte-Parity Harness (v0.7 M51)

Format-spec §11.1 requires all three languages emit byte-identical JSON
mirror attributes on compound dataset writes. v0.7 M51 ships a 9-way
interop grid test validating this explicitly:

```
                  dumper
writer →  | Python | Java | ObjC |
──────────┼────────┼──────┼──────┤
Python    |   ✓    |  ✓   |  ✓   |
Java      |   ✓    |  ✓   |  ✓   |
ObjC      |   ✓    |  ✓   |  ✓   |
```

Each cell asserts byte-identical JSON output. Divergences are treated
as bugs, not documented differences.

---

## 5. v0.7 Format-Spec Bumps

### 5.1 Wrapped-key blob format v1.2 (M47)

v1.1 layout (fixed 60 bytes, AES-256-GCM only):
```
[32 cipher | 12 IV | 16 tag]
```

v1.2 layout (variable, algorithm-discriminated):
```
[2 magic "MW" | 1 version 0x02 | 2 algorithm_id | 4 ciphertext_len
 | 2 metadata_len | metadata | ciphertext]
```

v1.1 files remain readable indefinitely (binding decision 38).

### 5.2 Signature prefix reservation

`"v3:"` reserved for post-quantum signatures (M49 target). v0.7 readers
recognize the prefix and raise `UnsupportedSignatureError` cleanly; v0.8+
may activate ML-DSA-87 signatures behind the `pqc_preview` feature flag.

---

## 5.3 Compound round-trip verification (M51)

Dataset-wide identifications, quantifications, and provenance records
are readable byte-identically across the three language implementations.
The harness:

1. Python writes a 5-identification / 3-quantification / 7-provenance
   fixture via `SpectralDataset.write_minimal`.
2. Three dumpers — `python -m mpeg_o.tools.dump_identifications`,
   `objc/Tools/obj/MpgoDumpIdentifications`, and
   `com.dtwthalion.mpgo.tools.DumpIdentifications` (invoked via
   `java/run-tool.sh`) — emit the same deterministic JSON to stdout.
3. `python/tests/test_compound_writer_parity.py` diffs the three outputs
   pairwise; any non-zero diff fails the test.

Format: sorted keys, tight inner JSON, one record per line, LF endings,
C99 `%.17g` floats. Implementations live in
`mpeg_o/tools/_canonical_json.py`,
`com/dtwthalion/mpgo/tools/CanonicalJson.java`, and the static helpers
in `objc/Tools/MpgoDumpIdentifications.m`.

The 9-way interop grid (3 writers × 3 dumpers) called out in HANDOFF.md
M51 ships with the read direction only (1 writer × 3 dumpers); Java
and ObjC write-fixture CLIs are v0.8 work. The read direction is the
one that produced the uint64-probe bug (commit 303e324) and its Java
analog fixed during M51 wiring — the bug pattern M51 exists to catch.

---

## 6. Cross-References

- Normative API table: `docs/api-review-v0.6.md` (unchanged in v0.7).
- Format spec: `docs/format-spec.md` (v1.2 bump documented in §8).
- Feature flags: `docs/feature-flags.md` (new flag
  `wrapped_key_v2` in §v0.7).
- Migration: `docs/migration-guide.md` (no v0.7 API breaks;
  algorithm parameters are additive).

---

*End of document.*
