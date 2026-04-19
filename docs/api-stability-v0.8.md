# API Stability Guide — v0.8

Classification of every public API surface across the three language
implementations (Python / Java / Objective-C) ahead of the v1.0
freeze. Three categories:

| Tag | Meaning |
|---|---|
| **Stable** | API shape + semantics are frozen. Breaking changes are a v2.0 concern. Minor additions allowed. |
| **Provisional** | Shipped but subject to refinement through the v0.8 and v0.9 cycles. Breaking changes permitted with a full minor-version bump. Callers should expect to update. |
| **Deprecated** | Scheduled for removal by v1.0. Still functional; emits a deprecation warning. |

**v0.8 M55 acceptance rule (HANDOFF):** no new `Provisional` APIs
are introduced during v0.8 — everything added in this release is
either `Stable` (firm contract) or `Deprecated` (no new contract).

This document is advisory: the authoritative annotations live in
the source (`@since`, `@Deprecated`, `MPGO_DEPRECATED_MSG`,
`warnings.warn`).

---

## 1. Core dataset model

### 1.1 `SpectralDataset` (all languages)

| API | Status | Since | Notes |
|---|---|---|---|
| `SpectralDataset.open(path, mode="r")` | **Stable** | v0.2 | Primary entry point. `mode` values `r`, `r+`, `w`, `w-` (matches h5py). |
| `SpectralDataset.write_minimal(path, title, runs, ...)` | **Stable** | v0.3 | Convenience writer that builds a full `.mpgo` from `WrittenRun` buffers. |
| `_pack_run` / `WrittenRun` | **Stable** | v0.3 | Internal but documented; used by importers to assemble runs. The `channel_data` dict accepts arbitrary channel names (v0.8 M53 adds `inv_ion_mobility`). |
| `close()` / context-manager | **Stable** | v0.2 | |

### 1.2 `AcquisitionRun`, `MSImage`, spectrum subclasses

| API | Status | Since | Notes |
|---|---|---|---|
| `MPGOMassSpectrum`, `MPGONMRSpectrum`, `MPGONMR2DSpectrum`, `MPGOFreeInductionDecay`, `MPGOChromatogram` | **Stable** | v0.1 | Class hierarchy frozen. |
| `AcquisitionRun.open(group, name)` | **Stable** | v0.4 | |
| `MSImage` native-rank-3 cube layout (`opt_native_msimage_cube`) | **Stable** | v0.4 | |
| `AcquisitionRun.encryptWithKey:level:error:` (ObjC) | **Stable** | v0.4 | Supersedes `MPGOEncryptionManager.encryptIntensityChannelInRun:atFilePath:...` (see §4.1). |

### 1.3 Compound datasets (identifications / quantifications / provenance)

| API | Status | Since | Notes |
|---|---|---|---|
| `Identification`, `Quantification`, `ProvenanceRecord` | **Stable** | v0.2 | Field layout frozen — changes require a format bump. |
| `compound_per_run_provenance` flag | **Stable** | v0.3 (M17) | |
| `CompoundField` protocol / record | **Stable** | v0.6 (M39) | Four supported kinds: UINT32, INT64, FLOAT64, VL_STRING. |

---

## 2. Storage providers

### 2.1 Provider contract

| API | Status | Since | Notes |
|---|---|---|---|
| `StorageProvider` interface / protocol | **Stable** | v0.6 | All four shipping providers implement. |
| `StorageGroup` / `StorageDataset` | **Stable** | v0.6 | |
| `StorageDataset.readCanonicalBytes` | **Stable** | v0.7 (M43) | Byte-level signature / encryption contract. |
| `StorageDataset.readRows` (compound) | **Stable** | v0.7 (M50) | Promoted from `@optional` to `@required` on the ObjC protocol. |
| `ProviderRegistry.open(url, mode)` / `open_provider` | **Stable** | v0.6 | URL-scheme dispatch. |
| **`StorageProvider.native_handle()` / `nativeHandle`** | **Deprecated (v1.0 removal)** | v0.6 | Escape hatch from provider abstraction. M43-M45 eliminated every internal caller; any external use should migrate to the protocol. Scheduled for removal at v1.0 per HANDOFF M55 review. |

### 2.2 Per-backend status

| Provider | Python | Java | ObjC |
|---|---|---|---|
| HDF5 | Stable | Stable | Stable |
| Memory | Stable | Stable | Stable |
| SQLite | Stable | Stable | Stable |
| Zarr (file + memory) | **Provisional** (Python) | **Stable** (v0.8 M52, local paths only) | **Stable** (v0.8 M52, local paths only) |

**Provisional note on Python Zarr:** `zarr+memory://` and `zarr+s3://`
remain Python-only. Java and ObjC implementations will either gain
the alternative stores in a later release or the extra schemes will
be marked unsupported in v1.0. The on-disk format migrated from Zarr
v2 to v3 in v0.9 — pre-deployment, no migration shim was required;
the read side still accepts legacy v2 dtype strings (`<f8`, `<i4`, …)
for safety.

---

## 3. Protection (signatures, encryption, key wrap)

### 3.1 Signatures

| API | Status | Since | Notes |
|---|---|---|---|
| `sign_dataset(ds, key, algorithm="hmac-sha256")` | **Stable** | v0.3 | Python h5py-native path; used for historical HDF5 signing. |
| `sign_storage_dataset(ds, key, algorithm=…)` | **Stable** | v0.8 (M54.1) | Provider-agnostic path. Recommended for new code. |
| `verify_dataset` / `verify_storage_dataset` | **Stable** | v0.3 / v0.8 | |
| `v2:` HMAC-SHA256 prefix | **Stable** | v0.3 | Readable indefinitely. |
| `v3:` ML-DSA-87 prefix | **Stable** | v0.8 (M49) | FIPS 204 signature. |
| Unprefixed "v1" native-byte signatures | **Deprecated (v1.0 removal)** | v0.2 | v0.2 legacy path. Readable via fallback; no longer emitted. Plan to remove the fallback reader in v1.0 once the only remaining v1 fixtures are replaced with `v2:` equivalents. |
| `SignatureManager.sign(data, key)` (Java, 2-arg form) | **Stable** | v0.6 | Shorthand for the algorithm-parameterised entry. |
| `SignatureManager.sign(data, key, algorithm)` | **Stable** | v0.8 (M49) | Adds `ml-dsa-87`. |

### 3.2 Encryption

| API | Status | Since | Notes |
|---|---|---|---|
| `EncryptionManager.encryptData:/decryptData:` low-level primitives | **Stable** | v0.4 | AES-256-GCM. |
| `EncryptionManager.wrapKey(dek, kek[, legacyV1, algorithm])` | **Stable** | v0.7 (M47) | v1.2 wrapped-key blob envelope. |
| `MPGOEncryptionManager.encryptIntensityChannelInRun:atFilePath:...` | **Deprecated (v1.0 removal)** | v0.4 | Superseded by `-encryptWithKey:level:error:` on `MPGOAcquisitionRun`. Already carries `__attribute__((deprecated))`; hard-remove at v1.0. |
| `MPGOEncryptionManager.decryptIntensityChannelInRun:...` | **Deprecated (v1.0 removal)** | v0.4 | Same. |
| `MPGOEncryptionManager.isIntensityChannelEncryptedInRun:...` | **Deprecated (v1.0 removal)** | v0.4 | Migrate to `MPGOAcquisitionRun.accessPolicy`. |

### 3.3 Key rotation / envelope

| API | Status | Since | Notes |
|---|---|---|---|
| `KeyRotationManager.enableEnvelopeEncryption(f, kek, kek_id[, algorithm])` | **Stable** | v0.4 / v0.8 | Algorithm parameter added in v0.8 M49. |
| `KeyRotationManager.unwrap_dek(f, kek[, algorithm])` | **Stable** | v0.4 / v0.8 | |
| `KeyRotationManager.rotate_key(f, old_kek, new_kek[, algorithm, new_algorithm])` | **Stable** | v0.4 / v0.8 | v0.8 adds cross-algorithm migration. |
| v1.1 60-byte wrapped blob | **Readable forever** | v0.4 | Never emitted by v0.7+; readable as documented in binding decision 38. Not scheduled for removal. |
| v1.2 wrapped blob (algorithm-discriminated) | **Stable** | v0.7 (M47) | Default output. `algorithm_id` field is an extension point for future KEMs. |

### 3.4 Post-quantum crypto (v0.8 M49)

| API | Status | Since | Notes |
|---|---|---|---|
| `mpeg_o.pqc.kem_keygen / kem_encapsulate / kem_decapsulate` | **Stable** | v0.8 | Thin liboqs wrapper; the public surface is expected to be stable. |
| `mpeg_o.pqc.sig_keygen / sig_sign / sig_verify` | **Stable** | v0.8 | |
| `PostQuantumCrypto.kemKeygen / kemEncapsulate / kemDecapsulate` (Java) | **Stable** | v0.8 | Bouncy Castle wrapper. Same shape as Python and ObjC. |
| `MPGOPostQuantumCrypto +kemKeygenWithError: / …` (ObjC) | **Stable** | v0.8 | Same shape. |
| `CipherSuite.validatePublicKey` / `validatePrivateKey` | **Stable** | v0.8 | |
| `CipherSuite.publicKeySize` / `privateKeySize` | **Stable** | v0.8 | |
| `CipherSuite.validateKey` (on asymmetric input) | **Stable behaviour change** | v0.8 | Now raises with a redirect message instead of silently accepting. |

### 3.5 Cipher-suite catalog

| Algorithm | Status | Notes |
|---|---|---|
| `aes-256-gcm` | **Active / Stable** | |
| `hmac-sha256` | **Active / Stable** | |
| `sha-256` | **Active / Stable** | |
| `ml-kem-1024` | **Active / Stable (v0.8)** | |
| `ml-dsa-87` | **Active / Stable (v0.8)** | |
| `shake256` | **Reserved** | No consumer yet in the protection APIs. May activate in v0.9 as a domain-separator primitive, else drop from the catalog at v1.0. |

---

## 4. Importers / exporters

| API | Status | Since | Notes |
|---|---|---|---|
| mzML reader | **Stable** | v0.1 | |
| nmrML reader | **Stable** | v0.3 | |
| Thermo `.raw` reader (delegation to ThermoRawFileParser) | **Stable** | v0.6 (M38) | |
| Bruker `.d` reader (`opentimspy` delegation) | **Stable** | v0.8 (M53) | Binary-extraction Python subprocess from Java / ObjC is expected to be replaced by a native port in v0.9. The public `read()` / `read_metadata()` surface stays stable. |
| mzML / nmrML / ISA-Tab writers | **Stable** | v0.4 | |

---

## 5. Feature flags

`docs/feature-flags.md` is the normative registry. Categorisation
for v1.0 planning:

| Flag | Status | Required? | Notes |
|---|---|---|---|
| `base_v1` | Stable | required | |
| `compound_identifications` / `compound_quantifications` / `compound_provenance` | Stable | required | |
| `compound_per_run_provenance` | Stable | required | |
| `opt_compound_headers` / `opt_native_2d_nmr` / `opt_native_msimage_cube` | Stable | optional | |
| `opt_dataset_encryption` / `opt_digital_signatures` | Stable | optional | |
| `opt_canonical_signatures` | Stable | optional | |
| `opt_key_rotation` | Stable | optional | |
| `opt_anonymized` | Stable | optional | |
| `wrapped_key_v2` | Stable | optional | Default on for v0.7+ files. Under consideration for promotion to `required` at v1.0 — every shipping reader supports it. |
| `opt_pqc_preview` | **Provisional** | optional (v0.8) | New in v0.8; kept provisional through the v0.8 series so the PQC code-paths can be tuned based on real-world usage before freezing. |

**v1.0 flag-promotion candidates:** `wrapped_key_v2` (every reader
handles it), `opt_canonical_signatures` (every signer emits it). A
promotion would make v0.6-and-earlier readers refuse v0.8 files —
requires explicit migration guidance before landing.

---

## 6. Deprecation ledger — scheduled for v1.0 removal

The following APIs are **scheduled for removal at v1.0**. Each emits
a deprecation warning when invoked in v0.8.

1. `MPGOEncryptionManager.encryptIntensityChannelInRun:atFilePath:withKey:error:`
   — migrate to `MPGOAcquisitionRun -encryptWithKey:level:error:`.
2. `MPGOEncryptionManager.decryptIntensityChannelInRun:…` —
   migrate to `MPGOAcquisitionRun -decryptWithKey:error:`.
3. `MPGOEncryptionManager.isIntensityChannelEncryptedInRun:…` —
   migrate to `MPGOAcquisitionRun.accessPolicy`.
4. `StorageProvider.native_handle()` / `nativeHandle` — M43-M45
   eliminated every internal caller. External callers should drop
   direct backend handles in favour of the provider protocol.
5. Unprefixed v1 HMAC signatures (read fallback). v0.2 fixtures
   that still use this layout should be re-signed with `v2:` before
   v1.0. No writer emits v1 since v0.3; the v1.0 freeze removes the
   read fallback.

No API added in v0.8 is deprecated (per HANDOFF M55 acceptance rule).

---

## 7. Migration guidance for v1.0

See `docs/migration-guide.md` for the step-by-step instructions once
the removals land. v0.8 → v0.9 is a pure minor release; the v1.0
freeze is the inflection point.

---

*This document is regenerated every major release. Prior versions
live in git history under the tags `v0.7.0`, `v0.6.1`, …*
