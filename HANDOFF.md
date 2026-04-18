# MPEG-O v0.7 — Storage & Crypto Abstraction Hardening

> **Status (2026-04-18):** v0.6.1 shipped (SQLiteProvider, full API docs,
> ROS3 cloud reads, 6 Appendix B gap resolutions). v0.7 plan now active.
> Current test counts: ObjC 1002 assertions, Python 219 tests, Java 152 tests.
> Cross-compat 8/8.
>
> **v0.7 goal:** close the remaining HDF5 / classical-crypto couplings the
> v0.6.1 code review surfaced so that (a) a non-HDF5 storage backend
> (Zarr, Parquet, future formats) can host MPEG-O data end-to-end, and
> (b) post-quantum cryptographic primitives (ML-KEM, ML-DSA) can drop in
> as the NIST standards mature. See `## v0.7 Milestone Block` below.
>
> **v0.6 retained (shipped) — see the lower half of this document for
> historical milestone records M37-M42.**

---

## First Steps

1. `git clone https://github.com/DTW-Thalion/MPEG-O.git && cd MPEG-O && git pull`
2. Read: `README.md`, `ARCHITECTURE.md`, `WORKPLAN.md`, `docs/format-spec.md`, `docs/feature-flags.md`, `docs/api-review-v0.6.md`
3. Verify all three builds:
   ```bash
   cd objc && ./build.sh check
   cd ../python && pip install -e ".[test,import,crypto]" && pytest
   cd ../java && mvn verify -B
   ```
4. Expected: ObjC 1002 assertions, Python 219, Java 152, all pass.

---

## v0.7 Milestone Block

### Context

v0.6.1 closed the six Appendix B gaps that the SQLite provider stress
test surfaced. A subsequent tri-area code review (cross-language
consistency, storage backend replaceability, crypto algorithm agility)
turned up a coherent set of remaining couplings that share a common
structure: **the protocol abstractions are sound, but specific byte-level
code paths still reach through them to HDF5 primitives or classical
crypto constants**. v0.7 closes those couplings without breaking any
existing public API.

The work splits into three convergent tracks (A, B, C) that can be
sequenced independently within their own track but have controlled
cross-track ordering.

### v0.7 Dependency Graph

```
Track A — Storage                Track B — Crypto           Track C — Consistency
─────────────────                 ─────────────              ─────────────────────
  M43 (byte-level                   M47 (versioned             M50 (API-shape
       protocol)                         wrapped-key                drift polish)
       │                                 blob)                       │
       ▼                                 │                            ▼
  M44 (Run/Image                         ▼                      M51 (compound
       protocol-native)               M48 (algorithm=                byte-parity)
       │                                  API)
       ▼                                  │
  M45 (create_dataset_nd                  │
       complete)                          │
       │                                  │
       ├─── stretch ──┐                   │
       ▼              │                   ▼
  M46 (ZarrProvider)  │             M49 (PQC preview ─ stretch,
                      │                  gated on liboqs / BC-PQC
                      │                  maturity)
                      │
                      └──── M46 validates A; M49 validates B.
```

**Ordering rules:**
- M43 → M44 (Run/Image refactor depends on the byte-level protocol landing first).
- M45 parallels M44 (independent file set).
- M47 → M48 (the algorithm= API layer needs a format to dispatch to).
- M50 and M51 parallel everything — no cross-track dependencies.
- M46 is stretch; implement only after M45 lands.
- M49 is stretch AND external-dependency-gated (liboqs for Python/ObjC; Bouncy Castle post-quantum final release for Java).

### v0.7.0 Minimum Cut

**Must-have for the v0.7.0 tag:** M43, M44, M45, M47, M48, M50.
**Stretch for the v0.7.0 tag:** M46, M51.
**Must-defer (v0.8+):** M49 — requires production-grade PQC binding.

---

## Binding Decisions — All Prior (1–36) Active, Plus:

37. **Byte-level protocol surface.** `StorageDataset` grows a new method
    `read_canonical_bytes(offset, count)` / `readCanonicalBytesAtOffset:count:error:`.
    All cryptographic code paths (signatures, encryption, key rotation)
    consume canonical bytes through this method, not through
    `native_handle()`. The canonical byte form is the layered contract
    between MPGO data model and storage backend — stable across
    backends, stable across endianness.
38. **Legacy wrapped-key compat forever.** The v1.1 AES-GCM-only 60-byte
    wrapped-key blob is readable by v0.7+ code indefinitely. New files
    default to the v1.2 versioned layout (M47). No format deprecation
    planned for v1.0.
39. **Algorithm selection is explicit, catalog-backed, not
    plugin-discoverable.** `CipherSuite` is a fixed allow-list in each
    language. Adding a new algorithm is a source-code change, not a
    runtime registration. Avoids FIPS/compliance surprises.
40. **PQC swap targets are ML-KEM-1024 (key encapsulation) and
    ML-DSA-87 (signatures).** AES-256-GCM intensity-channel encryption
    is **not** replaced — AES-256 is already quantum-secure (Grover
    reduces to AES-128-equivalent strength). Only the KEM and signature
    primitives change in the PQC path.
41. **Python-first reference providers.** When validating a new
    abstraction (M46: Zarr), Python ships first; Java and ObjC follow in
    v0.8 once the abstraction has absorbed whatever the Python
    implementation surfaced.

---

## Milestone 43 — Storage Byte-Level Protocol (Track A)

**License:** LGPL-3.0

Byte-level code (signatures, encryption, key rotation) currently reads
raw HDF5 bytes via `provider.native_handle()` / `-[provider nativeHandle]`
to construct canonical byte sequences for cryptographic operations. Each
operation iterates HDF5 type layouts (H5T_COMPOUND field offsets, VL
string length prefixes) to build the byte stream. This coupling means a
ZarrProvider / ParquetProvider cannot sign, encrypt, or key-rotate
without carrying its own copy of the HDF5 canonical-bytes code.

Move the canonical byte form into the protocol itself. Each provider
emits its own normalized byte stream; byte-level code reads via the
protocol instead of the native handle.

**Deliverables**

Python `StorageDataset` ABC (`providers/base.py`):
```python
@abstractmethod
def read_canonical_bytes(self, offset: int = 0, count: int = -1) -> bytes:
    """Return the dataset's contents as a byte stream in the MPGO
    canonical layout: little-endian packed primitives; compound rows
    packed in field declaration order with VL strings encoded as a
    4-byte little-endian length prefix followed by utf-8 bytes.

    Signatures and encryption consume this method so that a signed
    or encrypted dataset verifies identically regardless of which
    provider wrote it. Appendix B Gap 2 follow-up — extends
    ``read_rows()`` by promising a stable byte form, not just a
    stable row form."""
```

Java `StorageDataset`:
```java
byte[] readCanonicalBytes(long offset, int count);
```

ObjC `MPGOStorageDataset`:
```objc
- (NSData *)readCanonicalBytesAtOffset:(NSUInteger)offset
                                  count:(NSUInteger)count
                                  error:(NSError **)error;
```

Concrete implementations:
- **Hdf5Provider.** `H5Dread` into an aligned buffer, then explicit
  little-endian normalization (no-op on x86/x86_64; a byteswap pass
  on big-endian hosts). Compound rows: walk fields in declaration
  order, emit each field's canonical bytes.
- **MemoryProvider.** `np.ndarray.tobytes()` (Python) with explicit
  `<` endian flag; equivalent packing in Java (`ByteBuffer.LITTLE_ENDIAN`)
  and ObjC (`CFByteOrderLittleEndian`-aware packing).
- **SqliteProvider.** For primitives: select the BLOB column, assert
  it was written with the canonical byte order, return as-is. For
  compounds: select rows, reassemble fields in declaration order,
  emit canonical bytes.

Callers migrated in this milestone (each switches from native_handle
to `read_canonical_bytes`):
- `python/src/mpeg_o/signatures.py::_dataset_canonical_bytes` → thin
  wrapper around `dataset.read_canonical_bytes()`.
- `python/src/mpeg_o/encryption.py::_plaintext_for_channel`.
- `python/src/mpeg_o/key_rotation.py::_unwrap_dek` (wrapped-blob read).
- `objc/Source/Protection/MPGOSignatureManager.m` — every
  `H5Dread`-based canonicaliser.
- `objc/Source/Protection/MPGOEncryptionManager.m` — plaintext capture.
- `objc/Source/Protection/MPGOKeyRotationManager.m` — wrapped-blob
  read.
- Java analogs in `com.dtwthalion.mpgo.protection.*`.

**Acceptance Criteria**

- [ ] `read_canonical_bytes` / `readCanonicalBytesAtOffset:count:error:` /
      `readCanonicalBytes(long, int)` implemented on every
      `StorageDataset` concrete class in all three languages (HDF5,
      Memory, SQLite). Compound and primitive datasets both handled.
- [ ] Byte form is bit-identical across backends for the same logical
      content. New cross-backend round-trip test
      (`tests/test_canonical_bytes_cross_backend.py`) writes a signal
      channel and a compound dataset via each provider, calls
      `read_canonical_bytes()`, and asserts byte equality.
- [ ] Sign on `Hdf5Provider`, verify on `MemoryProvider`: passes.
- [ ] Sign on `MemoryProvider`, verify on `Hdf5Provider`: passes.
- [ ] Encrypt on `MemoryProvider`, decrypt on `Hdf5Provider`: plaintext
      recovers.
- [ ] All existing 1002/219/152 tests green — no behavioural regression.
- [ ] Every `native_handle()` call in `signatures.py`, `encryption.py`,
      `key_rotation.py` (and ObjC/Java equivalents) is removed or
      documented as "last remaining byte-level escape hatch" with a
      v0.8 follow-up entry.
- [ ] `docs/format-spec.md` §7 (signature canonical form) and §8
      (envelope encryption) rewritten to reference the protocol's
      canonical bytes, not HDF5's on-disk layout.

**Risk:** Endianness normalization must be *exactly* stable. A spec
bump forced by an unexpected byteswap would orphan signed v0.6 files.
Mitigation: CI matrix includes a big-endian test job (qemu-s390x or
similar) that verifies `read_canonical_bytes` emits little-endian on
both architectures.

---

## Milestone 44 — Run / Image Protocol-Native Access (Track A)

**License:** LGPL-3.0

`AcquisitionRun` and `MSImage` hold direct references to `h5py.Group` /
`MPGOHDF5Group` / `Hdf5Group` plus cached `h5py.Dataset` /
`MPGOHDF5Dataset` / `Hdf5Dataset` handles for signal channels. Lazy
materialisation uses bare h5py slicing (Python) or HDF5 hyperslab calls
(ObjC/Java). This is the second-largest remaining HDF5 leak.

Replace the run and image classes' internal references with provider
types. Hyperslab reads route through `dataset.read(offset=..., count=...)`.

**Deliverables**

Python `acquisition_run.py`:
- `AcquisitionRun.group`: `h5py.Group` → `StorageGroup`.
- `AcquisitionRun._signal_cache`: `dict[str, h5py.Dataset]` →
  `dict[str, StorageDataset]`.
- `AcquisitionRun.open(group, name)` signature accepts `StorageGroup`.
- `_materialize_spectrum` uses `dataset.read(offset=off, count=len)`
  instead of bare h5py slicing.
- Numpress-delta path (`_numpress_channels`) is already provider-
  agnostic (holds `np.ndarray`); no change.

ObjC `MPGOAcquisitionRun.{h,m}`:
- Instance variable `_channelDatasets` becomes
  `NSDictionary<NSString *, id<MPGOStorageDataset>> *`.
- `+readFromGroup:name:error:` signature accepts
  `id<MPGOStorageGroup>` instead of `MPGOHDF5Group *`.
- `-spectrumAtIndex:error:` uses protocol read.

Java `AcquisitionRun.java`:
- Analogous: `StorageGroup group`, `Map<String, StorageDataset> signalCache`.

Similar treatment for `MSImage` / `MPGOMSImage` / `MSImage.java` — store
the image-cube `StorageDataset` reference; hyperslab reads via
`readSlice`.

**Acceptance Criteria**

- [ ] `AcquisitionRun` and `MSImage` in all three languages hold only
      protocol types as instance state (grep for `h5py.Group` /
      `MPGOHDF5Group` / `Hdf5Group` in those classes returns zero).
- [ ] Spectrum and image-slice reads route through the provider protocol.
- [ ] All existing 1002/219/152 tests pass.
- [ ] New cross-backend test
      (`tests/test_run_cross_backend.py`): write a run via
      `Hdf5Provider`, re-open via `MemoryProvider` (round-trip), read
      spectra; then the reverse. Both paths produce identical results.
- [ ] File-handle lifetime test
      (`tests/test_run_lifecycle.py`): open a dataset, close the
      provider before reading spectra; call MUST raise a clear
      `IOError` / `MPGOErrorDatasetRead` / `IllegalStateException`,
      not silently return stale data or segfault.

**Risk:** File-handle retention chain changes. Today `h5py.Dataset`
holds an implicit reference back to the file; replacing with
`StorageDataset` means the provider's lifetime management takes over.
Easy to get this wrong and leak file handles. Mitigation: write the
lifecycle test before starting the refactor.

---

## Milestone 45 — N-D Dataset Support Across Providers (Track A)

**License:** LGPL-3.0

`StorageProvider.create_dataset_nd` is declared on the protocol but only
implemented on the HDF5 backend. `MemoryProvider.create_dataset_nd` and
`SqliteProvider.create_dataset_nd` raise `NotImplementedError`.
`MSImage` cube writes bypass the protocol for this reason.

**Deliverables**

Python:
- `MemoryProvider._Group.create_dataset_nd`: store `np.ndarray` with
  full shape in the dict tree; slicing goes via standard numpy indexing.
- `SqliteProvider.create_dataset_nd`: flatten N-D → 1-D BLOB on write;
  persist shape tuple as a dataset attribute (`@shape_json` already
  exists for this). Read path reverses: unpack attribute, reshape.
- `Hdf5Provider._Group.create_dataset_nd`: already implemented. Add
  explicit test that chunking hints are honored.

Java, ObjC: analogous.

**Acceptance Criteria**

- [ ] All three providers in all three languages implement
      `create_dataset_nd` without raising `NotImplementedError`.
- [ ] New cross-backend round-trip test
      (`tests/test_msimage_cross_backend.py`): write a 3-D MSImage cube
      through each provider, read back from all three backends, verify
      element-for-element equality.
- [ ] `MSImage` writes in all three languages no longer call
      `native_handle()` — they use the provider protocol.
- [ ] Provider capability queries (`supports_chunking`,
      `supports_compression`) correctly reflect whether chunking hints
      were honored.

---

## Milestone 46 — ZarrProvider Reference Implementation (Track A, stretch)

**License:** LGPL-3.0

Validate that the storage abstraction after M43+M44+M45 truly
generalizes beyond HDF5. Zarr is the most mature alternative container
format with a first-class Python binding (zarr-python ≥ 2.18).

**Deliverables**

- `mpeg_o.providers.zarr.ZarrProvider` implementing the full
  `StorageProvider`/`StorageGroup`/`StorageDataset` contract.
- `pyproject.toml` optional dependency: `zarr>=2.18`.
- Entry point: `[project.entry-points."mpeg_o.providers"] zarr =
  "mpeg_o.providers.zarr:ZarrProvider"`.
- URL schemes: `zarr:///path/to/store.zarr` (directory store),
  `zarr+s3://bucket/key` (cloud via fsspec), `zarr+memory://name` (in-memory).
- Full test parity: run the existing `test_providers.py` matrix over
  `zarr` as a fourth provider (alongside `hdf5`, `memory`, `sqlite`).

**Explicit non-deliverable (v0.7):** Java and ObjC ZarrProviders defer
to v0.8 — Python first to stress-test the abstraction.

**Acceptance Criteria**

- [ ] All existing Python provider contract tests pass with
      `zarr` as the provider.
- [ ] Python-written Zarr store round-trips: write identifications +
      compound datasets + signal channels, read back, all bit-equal.
- [ ] Any abstraction leaks surfaced during implementation are either
      (a) fixed inline by extending the protocol, or (b) filed as
      explicit v0.8 follow-ups with file:line pointers.
- [ ] New `docs/providers.md` lists all four providers with feature
      matrix (chunking/compression/transactions/N-D/attributes types).

---

## Milestone 47 — Crypto Algorithm Discriminator in On-Disk Format (Track B)

**License:** LGPL-3.0

The wrapped-key envelope blob is today a fixed 60-byte layout
`[32 cipher | 12 IV | 16 tag]` specific to AES-256-GCM. ML-KEM
ciphertext is 1568 bytes; any PQC KEK replacement needs a different
layout. Similarly, the `"v2:"` signature prefix implicitly means
HMAC-SHA256; no algorithm discriminator exists.

Bump format-spec to v1.2 with a versioned, algorithm-discriminated
envelope layout. Preserve backward compatibility — v1.1 readers
continue to read AES-GCM-wrapped files; new writers emit v1.2 by
default once the `wrapped_key_v2` feature flag is active.

### v1.2 Wrapped-Key Blob Layout

```
Offset   Length  Field
+0       2       magic        = 0x4D 0x57  ('M','W' — MPGO Wrap)
+2       1       version      = 0x02
+3       2       algorithm_id (big-endian)
                   0x0000 = AES-256-GCM  (legacy-equivalent)
                   0x0001 = ML-KEM-1024  (reserved for M49)
                   0x0002 = reserved
+5       4       ciphertext_len (big-endian)
+9       2       metadata_len   (big-endian) — algorithm-specific
+11      M       metadata (M = metadata_len bytes)
                   AES-256-GCM: [12-byte IV | 16-byte tag] (M=28)
                   ML-KEM-1024: empty (M=0)
+11+M    C       ciphertext (C = ciphertext_len bytes)
```

**Backward-compat probe** (all three languages): if
`blob[0:2] != b"MW"` OR file's `@mpeg_o_version < "1.2"`, fall back to
legacy 60-byte AES-GCM layout.

### Signature Format

Introduce `"v3:"` prefix for PQC-era signatures, reserving it for M49.
v2 HMAC-SHA256 signatures continue to work unchanged. v3 layout:

```
"v3:" | <algorithm_name> | ":" | <base64_signature>
```

where `algorithm_name ∈ {"ml-dsa-87", ...}`. v2 verifiers encountering a
v3 signature must fail cleanly with "unknown signature version", not
silently pass.

**Deliverables per language**

Python:
- `key_rotation.py::pack_wrapped_blob_v2(algorithm_id, ciphertext, metadata) -> bytes`
- `key_rotation.py::unpack_wrapped_blob(blob) -> WrappedBlobV2 | WrappedBlobLegacy`
- `key_rotation.py::_wrap_dek`: dispatch on the new
  `wrapped_key_v2` feature flag; default v2.
- `signatures.py::verify_signature` accepts both v2 and v3 prefixes;
  v3 raises `UnsupportedSignatureError` pending M49.

Java: analogous in `KeyRotationManager.java`, `SignatureManager.java`.

ObjC: analogous in `MPGOKeyRotationManager.m`, `MPGOSignatureManager.m`.

**Feature flag:** `wrapped_key_v2` — writers default to emitting v2;
readers detect both. Documented in `docs/feature-flags.md`.

**Acceptance Criteria**

- [ ] v1.2 blob format round-trips in all three languages.
- [ ] v1.1 legacy AES-GCM files still wrap/unwrap under v0.7 code paths.
      Regression test: the v1.1 fixture bundle (`objc/Tests/Fixtures/`)
      continues to load without modification.
- [ ] Cross-language interop: Python writes v2, ObjC/Java read v2;
      all six permutations (write-in-X × read-in-Y).
- [ ] `docs/format-spec.md` §8 rewritten with v1.2 layout plus an
      explicit v1.1 compat note.
- [ ] `docs/feature-flags.md` records `wrapped_key_v2` semantics.
- [ ] `"v3:"` signature prefix reserved; a v3 signature encounter in
      v0.7 raises `UnsupportedSignatureError` (not silent pass).

---

## Milestone 48 — Algorithm-Parameter API Generalization (Track B)

**License:** LGPL-3.0

With v1.2 on-disk format in place (M47), generalize the public API so
algorithms can be selected explicitly. **No new algorithms are
activated in this milestone** — the goal is to shape the parameter
hole so that M49 is a pure plug-in.

### CipherSuite Catalog

Each language ships a static catalog of supported algorithms:

```
algorithm_id           | category   | key_size | nonce_size | tag_size | status
"aes-256-gcm"          | AEAD       | 32       | 12         | 16       | active (default)
"ml-kem-1024"          | KEM        | 1568     | 0          | 0        | reserved (M49)
"hmac-sha256"          | MAC        | up to 64 | 0          | 32       | active (default)
"ml-dsa-87"            | Signature  | 4864     | 0          | ~4600    | reserved (M49)
"sha-256"              | Hash       | 0        | 0          | 32       | active (default)
"shake256"             | Hash/XOF   | 0        | 0          | variable | reserved (M49)
```

### API Shape

Python:
```python
def encrypt_bytes(plaintext: bytes, key: bytes, *,
                  algorithm: str = "aes-256-gcm") -> EncryptResult: ...

def sign_dataset(ds, key: bytes, *,
                 algorithm: str = "hmac-sha256") -> str: ...

def wrap_dek(dek: bytes, kek: bytes, *,
             algorithm: str = "aes-256-gcm") -> bytes: ...

class CipherSuite:
    @staticmethod
    def is_supported(algorithm: str) -> bool: ...
    @staticmethod
    def validate_key(algorithm: str, key: bytes) -> None:
        """Raises InvalidKeyError if key length does not match
        ``algorithm``. Replaces the inline ``len(key) == 32`` checks
        scattered through encryption.py and key_rotation.py."""
    @staticmethod
    def nonce_length(algorithm: str) -> int:
        """Replaces the module-level AES_IV_LEN = 12 constant."""
    @staticmethod
    def tag_length(algorithm: str) -> int: ...
```

Java: analogous in `com.dtwthalion.mpgo.protection.CipherSuite`.
`EncryptionManager.encrypt(plaintext, key, algorithm)` overload.

ObjC: analogous in `MPGOCipherSuite`. New selector
`+encryptData:withKey:algorithm:error:`.

### Key-size / IV-length migration

The hardcoded checks and constants are the primary target:

| File (Python)                  | Line        | Replacement                                   |
|-------------------------------|-------------|-----------------------------------------------|
| `encryption.py:67-68`         | `len(key) == 32` | `CipherSuite.validate_key(algo, key)`    |
| `encryption.py:36-37`         | `AES_IV_LEN = 12` | `CipherSuite.nonce_length(algo)`        |
| `encryption.py:85-86`         | `AES_TAG_LEN = 16` | `CipherSuite.tag_length(algo)`         |
| `key_rotation.py:113`         | 32-byte assert | `CipherSuite.validate_key("aes-256-gcm", dek)` |

(Equivalent replacements in Java `EncryptionManager.java:28-30` and
ObjC `MPGOEncryptionManager.m:14-15,27-30`.)

**Acceptance Criteria**

- [ ] All three languages accept an `algorithm` parameter (keyword or
      positional overload) on `encrypt`, `sign`, `wrap_dek`, plus the
      unwrap-side equivalents.
- [ ] Default behaviour preserved — every existing test passes without
      modification.
- [ ] `CipherSuite` catalog is the single source of truth for key/IV/
      tag sizes in each language.
- [ ] Passing an unknown algorithm raises
      `UnsupportedAlgorithmError` / equivalent with a clear message.
- [ ] New `docs/api-review-v0.7.md` (checkpoint analogous to v0.6) notes
      the algorithm parameter + CipherSuite catalog shape.

---

## Milestone 49 — PQC Preview Mode (Track B, stretch)

**License:** LGPL-3.0

With M47 (versioned blob) and M48 (algorithm= API) landed, plug in a
reference PQC implementation. Python uses `liboqs-python` (Open Quantum
Safe bindings). Java uses Bouncy Castle PQC provider once the final
NIST standards ship (targeting BC 1.81+). ObjC links directly against
liboqs.

### Algorithm Suite (v0.7 PQC preview)

| Primitive | Classical | Post-quantum replacement | Status |
|-----------|-----------|--------------------------|--------|
| Key encapsulation (DEK wrap) | AES-KW / AES-GCM | ML-KEM-1024 (Kyber) | preview |
| Signatures (v3 prefix) | HMAC-SHA256 (v2) | ML-DSA-87 (Dilithium) | preview |
| Bulk encryption | AES-256-GCM | *unchanged* | active |
| Hash | SHA-256 | SHAKE256 (optional) | preview |

**Explicit non-replacement:** AES-256-GCM intensity-channel encryption
stays classical. Grover's algorithm reduces AES-256's quantum security
margin to ~AES-128-equivalent, which remains computationally
infeasible. The PQC concern is *public-key* primitives (ECDSA, DH
key-exchange), not symmetric ciphers.

**Feature flag:** `pqc_preview` — marks files as experimental. v1.0 API
freeze may require format changes in this area. Files carrying the flag
MUST NOT be treated as long-term archival.

**Deliverables**

Python:
- `mpeg_o.pqc` new submodule.
- `pyproject.toml` optional dep: `liboqs>=0.10` (install via
  `pip install 'mpeg-o[pqc-preview]'`).
- `mpeg_o.key_rotation.wrap_dek(..., algorithm="ml-kem-1024")`:
  generates an ML-KEM keypair on demand, encapsulates the DEK under
  the public key, packs using M47's v1.2 envelope with `algorithm_id=0x0001`.
- `mpeg_o.signatures.sign_dataset(..., algorithm="ml-dsa-87")`: emits
  v3-prefixed signature.

Java: analogous in `com.dtwthalion.mpgo.pqc`.

ObjC: analogous in `MPGOQuantumEncryption`, `MPGOQuantumSignature`.

**Acceptance Criteria**

- [ ] ML-KEM-1024 DEK wrap round-trips through M47's v1.2 blob format.
- [ ] ML-DSA-87 signatures round-trip with v3 prefix.
- [ ] Cross-language PQC interop: wrap/sign in Python, unwrap/verify in
      ObjC and Java; all permutations pass.
- [ ] `pqc_preview` flag documented and enforced — a file without it
      continues to use AES-GCM + HMAC-SHA256 even if PQC APIs are
      invoked.
- [ ] Graceful fallback test: a PQC-wrapped file opened by a pre-v0.7
      reader fails with a clear "unsupported format; upgrade to v0.7+"
      error, not a silent misread.

---

## Milestone 50 — Cross-Language Consistency Hardening (Track C)

**License:** LGPL-3.0

Close the API-shape drift the v0.6.1 code review surfaced. Six small
independent sub-items; none block each other.

### 50.1 — `open()` dispatch documentation parity

**Decision:** Java and ObjC stay factory-only (mutation-style doesn't
idiom-match those languages). Python keeps dual-style.

- Update Python `StorageProvider.open` docstring to explicitly note the
  cross-language inconsistency: "**Cross-language note:** Java and
  ObjC are factory-only. Callers targeting multiple languages should
  use `Provider.open(path)` uniformly."
- Add the note to `docs/api-review-v0.7.md` under "Known Stylistic
  Differences."

### 50.2 — ObjC `readRows:` implementation audit

`-readRows:` is `@optional` on `MPGOStorageDataset`. A provider that
forgets to implement it silently responds with
`doesNotRecognizeSelector:` at runtime. Enforce an explicit
implementation on every concrete dataset class.

- Audit: `MPGOHDF5DatasetAdapter`, `MPGOHDF5CompoundDatasetAdapter`,
  `MPGOMemDataset`, `MPGOSqliteDataset` all implement `readRows:`
  (confirmed in the current tree; this milestone makes it enforceable).
- Make `-readRows:` **@required** on the protocol. Any custom provider
  the user writes now fails at compile-time if omitted.
- Add a test:
  `[provider.rootGroup openDatasetNamed:@"x" error:nil respondsToSelector:@selector(readRows:)]`
  across all shipping providers.

### 50.3 — Java typed exception hierarchy for importers

Java `MzMLReader.java:35-46` throws bare `Exception`. Callers cannot
distinguish parse errors from I/O errors.

- New base: `com.dtwthalion.mpgo.importers.MpgoReaderException extends IOException`.
- Specific: `MzMLParseException`, `NmrMLParseException`,
  `ThermoRawException`.
- `MzMLReader.read()` declares `throws MzMLParseException, IOException`.
- Similarly for `NmrMLReader`, `ThermoRawReader`.
- Test: catches `MzMLParseException` specifically on a malformed
  fixture.

### 50.4 — Java `@since` tag audit

Pass over every public class / method in `com.dtwthalion.mpgo.*` and
add `@since` tags for v0.5, v0.6, v0.6.1, v0.7 introductions.

- Tool: `grep -Lr "@since" java/src/main/java/` — flag every public
  type without one.
- Correctness check: cross-reference git blame against the
  introducing milestone.
- Generated Javadoc's Since column populates correctly.

### 50.5 — Cross-language error-domain mapping appendix

New section in `docs/api-review-v0.7.md` Appendix C:

```
Objective-C error code                 | Java exception             | Python class
MPGOMzMLReaderErrorParseFailed         | MzMLParseException         | MzMLParseError
MPGOErrorFileNotFound                  | FileNotFoundException      | FileNotFoundError
MPGOErrorFileOpen                      | IOException                | IOError
MPGOErrorFileCreate                    | IOException                | IOError
MPGOErrorDatasetRead                   | RuntimeException           | RuntimeError
MPGOErrorAttributeRead                 | RuntimeException           | KeyError / RuntimeError
UnsupportedSignatureError (M47)        | UnsupportedSignatureException | UnsupportedSignatureError
UnsupportedAlgorithmError (M48)        | UnsupportedAlgorithmException | UnsupportedAlgorithmError
```

One row per error. Specific error-code names confirmed against each
language's source.

### 50.6 — Appendix B Gap 7 cross-references

Java `Enums.java:27-34` documents the Gap 7 HDF5-JNI decoupling motivation
uniquely. Add mirror notes to:

- `python/src/mpeg_o/enums.py` — one-line docstring: "Precision is a
  pure enum; HDF5 type mapping lives in
  `mpeg_o.providers.hdf5._hdf5_types`. Appendix B Gap 7."
- `objc/Source/ValueClasses/MPGOEnums.h` — analogous comment in the
  MPGOPrecision block.

**Acceptance Criteria**

- [ ] Python `open()` docstring + `docs/api-review-v0.7.md` note the
      dual-style asymmetry.
- [ ] `-readRows:` is `@required` on `MPGOStorageDataset` protocol; test
      asserts every shipping provider responds.
- [ ] Java importers throw typed exceptions; test catches
      `MzMLParseException` specifically.
- [ ] `grep -Lr "@since" java/src/main/java/` returns empty for public
      types.
- [ ] `docs/api-review-v0.7.md` Appendix C (error-domain mapping)
      committed.
- [ ] Python and ObjC `Precision` docs reference Appendix B Gap 7.

---

## Milestone 51 — Cross-Language Byte-Parity for Compound Writes (Track C)

**License:** LGPL-3.0

The M51 parity harness (commit `d14fb76`) covers mzML writes. Extend
the same pattern to compound-dataset writes
(identifications / quantifications / provenance) so format-spec §11.1
("identical JSON-mirror attrs across languages") is test-enforced, not
spot-checked.

**Deliverables**

1. `objc/Tools/MpgoDumpIdentifications.m`: read a `.mpgo` and emit
   `/study/identifications` as deterministic JSON to stdout (sorted
   keys, stable float formatting: `%.17g`, LF line endings).
2. Java tool: `com.dtwthalion.mpgo.tools.DumpIdentifications` —
   executable via Maven `exec:java`.
3. Python: add module entry point:
   `python -m mpeg_o.tools.dump_identifications <path>`. Reuse the
   existing `Identification.to_json_dict` logic.
4. `python/tests/test_compound_writer_parity.py`:
   synthesise a fixture with N=5 identifications, N=3 quantifications,
   N=7 provenance records. Write three copies — one via each language.
   Dump each via each language's dumper. Assert all nine byte-streams
   match pairwise (9-way interop grid).

**Acceptance Criteria**

- [ ] `MpgoDumpIdentifications` CLI ships in ObjC (`objc/Tools/`).
- [ ] Java `DumpIdentifications` ships under `java/.../tools/`.
- [ ] Python `mpeg_o.tools.dump_identifications` module ships.
- [ ] `test_compound_writer_parity.py` passes the 9-way interop grid.
- [ ] Any divergences found during implementation are filed as bugs,
      **not hidden behind xfail markers** — this is the catch-net for
      the kind of write-path drift the uint64 probe bug (commit
      `303e324`) represented.
- [ ] Documented in `docs/api-review-v0.7.md` as "cross-language
      compound round-trip verified."

---

## Known Gotchas — v0.7 Additions

**Inherited (1–31):** all prior v0.6 gotchas active.

**New (v0.7):**

32. **`read_canonical_bytes` endianness.** HDF5 stores in file-native
    byte order (little-endian on x86/x86_64 — the dominant target).
    The canonical form is ALWAYS little-endian. On big-endian hosts
    (Power9, s390x), HDF5's automatic type conversion on read does the
    byteswap; **do not rely on that** for the canonical form.
    Explicitly normalize via `htole64` / `ByteBuffer.order(LITTLE_ENDIAN)`
    / `CFByteOrderLittleEndian`-aware packing in each language.
    CI should run a big-endian test job (qemu-s390x) to catch regressions.

33. **AcquisitionRun / MSImage lifetime coupling.** When M44 switches
    from `h5py.Group` to `StorageGroup`, the file-handle retention
    chain changes. Today `h5py.Dataset` retains an implicit reference
    back to the file; tomorrow `StorageDataset` delegates to
    `StorageProvider`. Tests that close the provider before reading
    spectra must fail LOUDLY, not silently use a zombie handle. Write
    the lifecycle test before the refactor (not after).

34. **v1.1 backward-compat test matrix.** Every v1.2 format change in
    M47 must be round-trip-tested against a v1.1 fixture. The
    `MakeFixtures` tool keeps producing both versions indefinitely.
    Regression: if a future writer forgets to honor `wrapped_key_v2`
    default, old readers may encounter v2-only code and break.

35. **`CipherSuite` is a static catalog, not a plugin system.** The
    algorithm parameter in M48 validates against a fixed allow-list.
    Do not introduce runtime algorithm registration — that invites
    FIPS / compliance headaches that v0.7 is not ready for. PQC
    algorithms land in v0.7 via explicit source changes, not
    discoverable plug-ins.

36. **liboqs / Bouncy Castle PQC dependency is experimental.** For M49,
    liboqs is an OQS project binding to NIST reference implementations;
    it is NOT production-hardened. The `pqc_preview` feature flag
    exists precisely because we expect to replace the binding when
    production-grade ML-KEM / ML-DSA ship (likely OpenSSL 3.4+ and
    Bouncy Castle 1.81+). Do not ship `pqc_preview` files as
    long-term archival.

37. **Comment-escape discipline.** The fix in commit `141907f`
    escaped `<run>`, `<spectrum>` etc. in ObjC header comments. Apply
    the same `&lt;` / `&gt;` / `&amp;` discipline to any new doc
    comments written during v0.7 — autogsdoc's tokenizer is
    unforgiving.

38. **Re-entrancy under protocol-native signal reads (M44).** The
    Numpress-delta eager-decode path (`_numpress_channels`) is
    decoupled from the storage protocol by design — it holds plain
    `np.ndarray` data. Do not refactor it to go through the protocol
    in M44; the per-run decode is a one-shot at open time and has no
    analog on a non-HDF5 backend. Document this in the caller-refactor
    status table so future readers understand why one channel type is
    provider-ignorant.

---

## v0.7 Execution Checklist

1. **M50** (cross-language polish). Non-blocking; six small independent
   sub-items. Ship early to get visible value fast and build PR-review
   momentum.
2. **M47** (versioned wrapped-key blob format). No API change yet; just
   on-disk. Must land before M48.
3. **M43** (byte-level protocol method). Parallel with M47.
4. **M48** (algorithm= API generalization). Sequential after M47.
5. **M44** (Run/Image refactor). Sequential after M43.
6. **M45** (`create_dataset_nd` completion). Parallel with M44.
7. **M51** (compound byte-parity). Parallel with anything; catches
   regressions from M43/M44/M45.
8. **M46** (ZarrProvider). Stretch; validates M43+M44+M45 stack.
9. **M49** (PQC preview). Stretch; validates M47+M48 stack, gated on
   external crypto-library maturity.
10. **Tag v0.7.0** after must-haves (M43, M44, M45, M47, M48, M50)
    complete. M46 / M51 land in v0.7.x patches or v0.8.0.

**CI must be green before any milestone is complete.**

---

## Deferred to v0.8+

Updated from v0.6's deferred table:

| Item | Description |
|---|---|
| Java + ObjC `ZarrProvider` | Python-only in v0.7; port after Python impl (M46) absorbs abstraction feedback |
| `ParquetProvider` | Alternative columnar backend; another stress test of the abstraction |
| `DBMSTransport` | `.mpgo` data in Postgres/MySQL; transport concern (separate from storage) |
| Java cloud access | ROS3 VFD or equivalent for Java (ObjC shipped in v0.6 via commit `c68157e`) |
| Bruker TDF import | Real implementation via TDF SDK |
| Waters MassLynx import | Stub + implementation |
| Raman / IR support | New `Spectrum` subclasses |
| Streaming transport | MPEG-G Part 2 protocol |
| PQC production mode | Once NIST final standards + OpenSSL/BC bindings mature, upgrade `pqc_preview` → stable |
| FIPS compliance mode | Algorithm allow-list lockdown; required for regulated deployments |
| v1.0 API freeze | After production feedback on provider + crypto architecture |

---

---

# Historical Record — v0.6 Milestone Block (SHIPPED)

The section below is the v0.6 plan as written during development.
Milestones M37–M42 are all shipped; M40 (Maven Central / PyPI
publishing) was explicitly deferred per user instruction and remains
open as "v0.8 or later, once external infrastructure is arranged."
The binding decisions and gotchas below are referenced by the v0.7
block above as "All Prior (1–36)" and "Inherited (1–31)" respectively.

## Binding Decisions — v0.6 (decisions 29–36):

29. **Storage/Transport Provider abstraction.** The data model and API are the standard; the storage backend is a pluggable implementation detail. All three languages define provider protocols/ABCs/interfaces. HDF5 becomes one implementation, not the only one.
30. **Provider auto-discovery.** ObjC: `NSBundle` + `+load` registration. Python: `importlib.metadata` entry points. Java: `java.util.ServiceLoader`. Providers register themselves; upper layers query the registry.
31. **Provider capability floor.** Every storage provider MUST support: hierarchical groups, named datasets with typed arrays, partial reads (hyperslab equivalent), chunked storage, compression, compound types with VL strings, and scalar/array attributes on groups and datasets. The interface defines all of these; providers that cannot deliver a capability throw a clear `UnsupportedOperationException` / `NSError` / `NotImplementedError`.
32. **Two providers in v0.6.** `Hdf5Provider` (refactored from existing code) and `MemoryProvider` (in-memory, for tests and transient pipelines). The MemoryProvider proves the abstraction actually works.
33. **Transport is orthogonal to storage.** `LocalTransport` (POSIX), `S3Transport` (ROS3 for ObjC, fsspec for Python), `HttpTransport` (range requests). Transport delivers bytes; storage interprets them.
34. **Thermo `.raw` via delegation to ThermoRawFileParser.** No proprietary code in MPEG-O's dependency tree. Shell out to `ThermoRawFileParser` (user-installed), capture mzML output, read with existing mzML reader.
35. **Maven Central groupId: `global.thalion`** (reversed `thalion.global`). Full artifact: `global.thalion:mpgo:0.6.0`.
36. **Multiple releases before v1.0.** v0.6 API review is a checkpoint, not a freeze.

---

## Dependency Graph

```
  M37 (Java compound I/O)     M38 (Thermo delegation)
       |                           |
       v                           |
  M39 (Provider abstraction — all three languages)
       |                           |
       +------------+--------------+
                    |
                    v
               M40 (Publishing: PyPI + Maven Central)
                    |
                    v
               M41 (API review checkpoint)
                    |
                    v
               M42 (v0.6.0 release)
```

M37 and M38 are independent and can start in parallel. M39 depends on M37 (Java needs working compound I/O before refactoring into providers). M40 depends on M39 (publish the provider-based architecture). M38 feeds into M39 (Thermo reader uses the format provider pattern).

---

## Milestone 37 — Java Compound Dataset I/O + JSON Parsing

**License:** LGPL-3.0

v0.5 Java writes JSON attributes and returns `List.of()` for compound reads. This blocks Java from properly reading ObjC/Python-written files.

**Deliverables**

- `Hdf5CompoundType.java` upgraded: VL-string-aware compound type creation, read, write via `H5Tcreate(H5T_COMPOUND)` + `H5Tset_size(H5T_VARIABLE)`
- `SpectralDataset.create()` writes native compound datasets matching `format-spec.md` §6
- `SpectralDataset.open()` reads native compound datasets for identifications, quantifications, provenance
- Full JSON parsing for `readCompoundIdentifications`, `readCompoundQuantifications`, `readCompoundProvenance` (currently return `List.of()`)
- JSON fallback retained for v0.1/v0.2 files
- JSON attribute mirror retained on write for backward compat

**Acceptance**

- [x] Java writes compound identifications matching format-spec §6.1
- [x] Java reads ObjC-written compound idents/quants/provenance — all fields match
- [x] Java-written compound datasets readable by ObjC and Python
- [x] v0.1 JSON fallback works
- [x] Three-way cross-compat green

**Shipped:** commit `e4fac3c`. Native compound write via
`NativeStringPool` (sun.misc.Unsafe-backed C-string pool); JSON
attribute mirror emitted by all three languages per format-spec
§11.1; fixtures regenerated.

---

## Milestone 38 — Thermo `.raw` Import via ThermoRawFileParser Delegation

**License:** Apache-2.0

No proprietary code in MPEG-O. Shell out to the user-installed `ThermoRawFileParser` binary, which converts `.raw` → mzML, then read the mzML with our existing reader.

**Deliverables**

**Python: `mpeg_o.importers.thermo_raw`**

```python
def read(path: str | Path, *,
         thermorawfileparser: str | None = None) -> SpectralDataset:
    """Import a Thermo .raw file via ThermoRawFileParser.

    Args:
        path: Path to the .raw file
        thermorawfileparser: Path to ThermoRawFileParser binary.
            If None, searches PATH. Raises FileNotFoundError if not found.

    The binary is invoked as:
        ThermoRawFileParser -i <raw> -o <tmpdir> -f 2  # format 2 = mzML

    The resulting mzML is parsed with mpeg_o.importers.mzml.read(),
    then the temp file is deleted.
    """
```

**ObjC: `MPGOThermoRawReader`**

Replace the stub with a real implementation that:
1. Uses `NSTask` to invoke `ThermoRawFileParser` (or `mono ThermoRawFileParser.exe` on systems without .NET 8)
2. Captures the mzML output in a temp directory
3. Reads with `MPGOMzMLReader`
4. Cleans up temp files
5. Returns nil + descriptive NSError if ThermoRawFileParser not found

**Java: `ThermoRawReader.java`**

Same pattern: `ProcessBuilder` to invoke ThermoRawFileParser, parse mzML output with `MzMLReader`.

**`docs/vendor-formats.md` update:**
- Installation instructions for ThermoRawFileParser (.NET 8 runtime, or Mono, or Conda/BioContainers)
- Note that Thermo's `.raw` format has no open specification
- Link to CompOmics ThermoRawFileParser repo

**Testing:**
- If ThermoRawFileParser is on PATH, run integration test with a small `.raw` fixture
- If not on PATH, skip gracefully with log message
- Unit test the delegation mechanism with a mock binary that outputs known mzML

**Acceptance**

- [x] Python: `thermo_raw.read("sample.raw")` returns valid SpectralDataset (when ThermoRawFileParser available)
- [x] ObjC: `MPGOThermoRawReader` returns dataset (when available)
- [x] Java: `ThermoRawReader.read()` returns dataset (when available)
- [x] Missing binary → clear error, not crash
- [x] Mock-binary unit test works in CI without ThermoRawFileParser installed
- [x] `docs/vendor-formats.md` updated

**Shipped:** commit `5fd96bc`. Binary resolution order: explicit arg →
`THERMORAWFILEPARSER` env → `ThermoRawFileParser` on PATH →
`ThermoRawFileParser.exe` + mono. Integration tests use a bash mock
binary so CI doesn't need the real parser installed.

---

## Milestone 39 — Storage/Transport Provider Abstraction (All Three Languages)

**License:** LGPL-3.0

This is the headline milestone. Extract protocols/ABCs/interfaces for storage and transport. Refactor all existing HDF5 code to implement the new protocols. Add a MemoryProvider to prove the abstraction.

### Part A — Define the Provider Interfaces

**ObjC protocols** (in `objc/Source/Providers/`):

```objc
@protocol MPGOStorageProvider <NSObject>
- (id<MPGOStorageGroup>)rootGroup:(NSError **)error;
- (BOOL)close:(NSError **)error;
- (BOOL)isOpen;
- (NSString *)providerName;  // "hdf5", "memory", etc.
@end

@protocol MPGOStorageGroup <NSObject>
- (NSString *)name;
- (BOOL)hasChild:(NSString *)name;
- (NSArray<NSString *> *)childNames:(NSError **)error;

// Subgroup navigation
- (id<MPGOStorageGroup>)openGroup:(NSString *)name error:(NSError **)error;
- (id<MPGOStorageGroup>)createGroup:(NSString *)name error:(NSError **)error;
- (BOOL)deleteChild:(NSString *)name error:(NSError **)error;

// Dataset access
- (id<MPGOStorageDataset>)openDataset:(NSString *)name error:(NSError **)error;
- (id<MPGOStorageDataset>)createDataset:(NSString *)name
                              precision:(MPGOPrecision)precision
                                 length:(NSUInteger)length
                              chunkSize:(NSUInteger)chunkSize
                       compressionLevel:(NSInteger)level
                                  error:(NSError **)error;

// Compound dataset access
- (id<MPGOStorageDataset>)createCompoundDataset:(NSString *)name
                                          fields:(NSArray<MPGOCompoundField *> *)fields
                                           count:(NSUInteger)count
                                           error:(NSError **)error;

// Attributes
- (BOOL)hasAttribute:(NSString *)name;
- (NSString *)stringAttribute:(NSString *)name error:(NSError **)error;
- (BOOL)setStringAttribute:(NSString *)name value:(NSString *)value error:(NSError **)error;
- (int64_t)integerAttribute:(NSString *)name defaultValue:(int64_t)def;
- (BOOL)setIntegerAttribute:(NSString *)name value:(int64_t)value error:(NSError **)error;
@end

@protocol MPGOStorageDataset <NSObject>
- (MPGOPrecision)precision;
- (NSUInteger)length;
- (NSData *)readAll:(NSError **)error;
- (NSData *)readSlice:(NSRange)range error:(NSError **)error;   // hyperslab
- (BOOL)writeData:(NSData *)data error:(NSError **)error;
- (BOOL)close;
@end
```

**Python ABCs** (in `mpeg_o/providers/base.py`):

```python
class StorageProvider(ABC):
    @abstractmethod
    def root_group(self) -> "StorageGroup": ...
    @abstractmethod
    def close(self) -> None: ...
    @abstractmethod
    def provider_name(self) -> str: ...

class StorageGroup(ABC):
    @abstractmethod
    def has_child(self, name: str) -> bool: ...
    @abstractmethod
    def child_names(self) -> list[str]: ...
    @abstractmethod
    def open_group(self, name: str) -> "StorageGroup": ...
    @abstractmethod
    def create_group(self, name: str) -> "StorageGroup": ...
    @abstractmethod
    def open_dataset(self, name: str) -> "StorageDataset": ...
    @abstractmethod
    def create_dataset(self, name: str, precision: Precision,
                       length: int, chunk_size: int = 16384,
                       compression_level: int = 6) -> "StorageDataset": ...
    @abstractmethod
    def create_compound_dataset(self, name: str,
                                 fields: list[CompoundField],
                                 count: int) -> "StorageDataset": ...
    @abstractmethod
    def get_attribute(self, name: str) -> str | int | None: ...
    @abstractmethod
    def set_attribute(self, name: str, value: str | int) -> None: ...
    @abstractmethod
    def has_attribute(self, name: str) -> bool: ...

class StorageDataset(ABC):
    @abstractmethod
    def read(self, offset: int = 0, count: int = -1) -> np.ndarray: ...
    @abstractmethod
    def write(self, data: np.ndarray) -> None: ...
    @abstractmethod
    def precision(self) -> Precision: ...
    @abstractmethod
    def length(self) -> int: ...
```

**Java interfaces** (in `com.dtwthalion.mpgo.providers`):

```java
public interface StorageProvider extends AutoCloseable {
    StorageGroup rootGroup();
    String providerName();
}

public interface StorageGroup extends AutoCloseable {
    boolean hasChild(String name);
    List<String> childNames();
    StorageGroup openGroup(String name);
    StorageGroup createGroup(String name);
    StorageDataset openDataset(String name);
    StorageDataset createDataset(String name, Precision precision,
                                  long length, int chunkSize, int compressionLevel);
    StorageDataset createCompoundDataset(String name,
                                          List<CompoundField> fields, int count);
    String getStringAttribute(String name);
    void setStringAttribute(String name, String value);
    long getIntegerAttribute(String name, long defaultValue);
    void setIntegerAttribute(String name, long value);
    boolean hasAttribute(String name);
}

public interface StorageDataset extends AutoCloseable {
    Object readData();                      // full read
    Object readSlice(long offset, int count); // hyperslab
    void writeData(Object data);
    Precision precision();
    long length();
}
```

### Part B — Provider Registry + Auto-Discovery

**ObjC:** `MPGOProviderRegistry` singleton. Providers register via `+load`:

```objc
@interface MPGOProviderRegistry : NSObject
+ (instancetype)shared;
- (void)registerProvider:(Class<MPGOStorageProvider>)providerClass
                 forScheme:(NSString *)scheme;  // "file", "s3", "memory"
- (id<MPGOStorageProvider>)providerForURL:(NSURL *)url error:(NSError **)error;
@end

// In MPGOHDF5Provider.m:
+ (void)load {
    [[MPGOProviderRegistry shared] registerProvider:self forScheme:@"file"];
    [[MPGOProviderRegistry shared] registerProvider:self forScheme:@"hdf5"];
}
```

**Python:** `importlib.metadata` entry points:

```toml
# pyproject.toml
[project.entry-points."mpeg_o.providers"]
hdf5 = "mpeg_o.providers.hdf5:Hdf5Provider"
memory = "mpeg_o.providers.memory:MemoryProvider"
```

```python
# mpeg_o/providers/registry.py
from importlib.metadata import entry_points

def discover_providers() -> dict[str, type[StorageProvider]]:
    eps = entry_points(group="mpeg_o.providers")
    return {ep.name: ep.load() for ep in eps}
```

**Java:** `java.util.ServiceLoader`:

```java
// META-INF/services/com.dtwthalion.mpgo.providers.StorageProvider
// contains: com.dtwthalion.mpgo.providers.Hdf5Provider
// contains: com.dtwthalion.mpgo.providers.MemoryProvider

public class ProviderRegistry {
    public static StorageProvider forScheme(String scheme) {
        for (StorageProvider p : ServiceLoader.load(StorageProvider.class)) {
            if (p.supportsScheme(scheme)) return p;
        }
        throw new IllegalArgumentException("No provider for scheme: " + scheme);
    }
}
```

### Part C — Refactor Existing HDF5 Code into Hdf5Provider

**ObjC:**
- `MPGOHDF5Provider` implements `<MPGOStorageProvider>` — wraps `MPGOHDF5File`
- `MPGOHDF5GroupAdapter` implements `<MPGOStorageGroup>` — wraps `MPGOHDF5Group`
- `MPGOHDF5DatasetAdapter` implements `<MPGOStorageDataset>` — wraps `MPGOHDF5Dataset`
- Existing `MPGOHDF5File`/`Group`/`Dataset` classes remain internally but are no longer called directly by upper layers
- `MPGOAcquisitionRun`, `MPGOSpectralDataset`, `MPGOCompoundIO`, `MPGOSignatureManager`, `MPGOEncryptionManager`, `MPGOKeyRotationManager` all switch from direct HDF5 calls to `<MPGOStorageGroup>` / `<MPGOStorageDataset>` protocol calls
- Thread safety (`pthread_rwlock_t`) stays on `MPGOHDF5File`; the adapter delegates lock calls

**Python:**
- `mpeg_o.providers.hdf5.Hdf5Provider` wraps `h5py.File`
- `mpeg_o.providers.hdf5.Hdf5Group` wraps `h5py.Group`
- `mpeg_o.providers.hdf5.Hdf5Dataset` wraps `h5py.Dataset`
- `_hdf5_io.py` helper functions refactored to use provider interfaces
- `SpectralDataset.open()` resolves provider via registry, then proceeds with provider-agnostic code
- fsspec cloud access becomes a transport concern: `Hdf5Provider` accepts either a path or a file-like object

**Java:**
- `com.dtwthalion.mpgo.providers.Hdf5Provider` wraps existing `Hdf5File`
- Same adapter pattern

### Part D — MemoryProvider (Second Provider)

In-memory storage for tests and transient pipelines. Proves the abstraction works without touching disk.

**Data model:** `Map<String, Object>` tree where groups are nested maps and datasets are typed arrays. Attributes are a parallel metadata map.

```python
class MemoryProvider(StorageProvider):
    """In-memory storage provider. Data lives in Python dicts.
    Useful for tests and transient pipelines where no file I/O is needed."""

    def __init__(self):
        self._root = {"__attrs__": {}, "__datasets__": {}, "__children__": {}}

    def root_group(self) -> "MemoryGroup":
        return MemoryGroup(self._root)
```

**Three-language implementation:** ObjC (NSDictionary tree), Python (dict tree), Java (HashMap tree).

**Validation:** Create a `SpectralDataset` using `MemoryProvider`, populate with spectra, read back, verify all values match. This is the proof that the abstraction works — if `SpectralDataset` functions identically over `MemoryProvider` and `Hdf5Provider`, the protocol contract is correct.

### Part E — SpectralDataset.open() Factory

```python
def open(path_or_url: str, *, provider: str | None = None, **kwargs):
    if provider:
        # Explicit provider override
        cls = registry.get(provider)
    elif "://" in path_or_url:
        scheme = path_or_url.split("://")[0]
        cls = registry.for_scheme(scheme)
    else:
        # Local file — detect by extension or content
        cls = registry.for_scheme("file")
    return cls.open(path_or_url, **kwargs)
```

### Acceptance

- [x] ObjC: `MPGOStorageProvider` / `Group` / `Dataset` protocols defined
- [x] Python: `StorageProvider` / `Group` / `Dataset` ABCs defined
- [x] Java: `StorageProvider` / `Group` / `Dataset` interfaces defined
- [x] `Hdf5Provider` passes all existing tests (no regression)
- [x] `MemoryProvider` passes a round-trip test: create dataset with spectra, read back, verify
- [x] Provider registry auto-discovers both providers in all three languages
- [x] `SpectralDataset.open()` resolves providers by URL scheme (via factory + ServiceLoader / entry-points / +load)
- [x] Three-way cross-compat still green (HDF5 path unchanged)
- [x] S3 transport works via HDF5 provider (Python: fsspec; Java/ObjC cloud deferred to v0.7)
- [x] `ARCHITECTURE.md` updated with provider architecture diagram

**Shipped:** commits `109a3bd` (protocols + providers + registries) and
`1429b89` (protocol extensions — N-D, `native_handle()` escape — plus
SpectralDataset.open routed through Hdf5Provider in all three languages).

**Caller refactor scope deliberately narrowed** (tracked in
`ARCHITECTURE.md` "Caller refactor status" table): top-level
SpectralDataset.open/create/write go through a Provider; byte-level
code (AcquisitionRun signal channels, MSImage cubes, signature /
encryption / key-rotation classes, compound metadata helpers) uses
`provider.native_handle()` and stays HDF5-shaped. A non-HDF5
provider (Zarr, SQLite) in v0.7 will drive the remaining protocol
extensions (codec metadata on datasets, byte-level dataset access,
higher-rank support on Hdf5Provider) organically.

---

## Milestone 40 — Package Publishing (PyPI + Maven Central)

**License:** N/A

**PyPI:**
- Publish `mpeg-o` v0.6.0 to PyPI proper. `pip install mpeg-o` works globally.
- Includes provider entry points for auto-discovery.

**Maven Central:**
- Publish `global.thalion:mpgo:0.6.0` via Sonatype OSSRH.
- Requires: GPG-signed artifacts, Sonatype JIRA account, domain `thalion.global` verified.
- `pom.xml` groupId changes from `com.dtwthalion` to `global.thalion`.
- Includes `META-INF/services` for ServiceLoader discovery.

**GitHub Packages:** Continue as mirror for both.

**Acceptance**

- [ ] `pip install mpeg-o` from PyPI works
- [ ] `global.thalion:mpgo` resolves from Maven Central without special repo config
- [ ] Both packages include correct license, URLs, description
- [ ] Entry points / ServiceLoader configs present and functional

---

## Milestone 41 — API Review Checkpoint (SHIPPED 2026-04-17)

**License:** All

Not a freeze — a checkpoint for consistency and documentation before more releases.

**Deliverables**

- `docs/api-review-v0.6.md`: lists every public class/method/interface across three languages, flags inconsistencies
- Provider interfaces marked as **Provisional** (may change before v1.0)
- Core data model classes (SignalArray, Spectrum, AcquisitionRun, SpectralDataset) marked as **Stable**
- All public APIs have docstrings/javadoc/header comments
- `docs/migration-guide.md`: mzML → MPEG-O and nmrML → MPEG-O workflows

**Shipped:** 9 commits (d63018a / 621d9b9 / 8b300a9 / 551e157 / fc88d8e /
00b9f2b / d57a036 / 13c024e / final commit). ObjC is normative. Python and
Java brought to semantic parity across 8 subsystems:

- 41.1: Domain protocols + ValueClasses (d63018a)
- 41.2: Core + Spectra (621d9b9)
- 41.3: Run + Image (8b300a9)
- 41.4: Dataset (551e157)
- 41.5: Protection (fc88d8e)
- 41.6: Query (00b9f2b)
- 41.7: Storage providers (d57a036)
- 41.8: Import/Export (13c024e)
- 41.9: Docs assembly (this commit)

Test counts end-of-M41: ObjC 867, Python 184, Java 126. Cross-compat 8/8.
Deferred items documented in `docs/api-review-v0.6.md` Known Stylistic Differences and Deferred sections.

**Acceptance**

- [x] `docs/api-review-v0.6.md` committed
- [x] `docs/migration-guide.md` committed
- [x] No undocumented public APIs
- [x] Provider interfaces clearly marked Provisional

---

## Milestone 42 — v0.6.0 Release

**Deliverables**

- All docs updated (ARCHITECTURE with provider diagram, format-spec, feature-flags, vendor-formats, api-review, migration-guide)
- CI: three-language matrix + cross-compat + provider tests
- Packages on PyPI and Maven Central
- `pom.xml` groupId: `global.thalion`
- Tag v0.6.0

**Acceptance**

- [ ] All three languages green
- [ ] Three-way cross-compat green
- [ ] MemoryProvider round-trip passes in all three languages
- [ ] `pip install mpeg-o` from PyPI
- [ ] Maven Central resolves
- [ ] v0.1–v0.5 backward compat preserved
- [ ] Tag pushed

---

## Known Gotchas

**Inherited (1–25):** All prior gotchas active.

**New (v0.6):**

26. **Provider refactor scope.** Every class that currently calls `MPGOHDF5Group` or `MPGOHDF5Dataset` directly must be updated to use `<MPGOStorageGroup>` / `<MPGOStorageDataset>`. This includes `MPGOAcquisitionRun`, `MPGOSpectralDataset`, `MPGOCompoundIO`, `MPGOSignatureManager`, `MPGOEncryptionManager`, `MPGOKeyRotationManager`, `MPGOAnonymizer`, `MPGOFeatureFlags`. Grep for `MPGOHDF5` in the source to find all call sites.

27. **MemoryProvider compound types.** The MemoryProvider must support compound datasets (list-of-dicts internally). This is simpler than HDF5 compound types but the interface must be identical from the caller's perspective.

28. **Provider entry point naming.** Python entry points use `mpeg_o.providers` group. Java uses `com.dtwthalion.mpgo.providers.StorageProvider` service interface (note: this must be updated to `global.thalion.mpgo.providers.StorageProvider` when groupId changes in M40). ObjC uses `+load` class method registration.

29. **ThermoRawFileParser detection.** Search PATH for `ThermoRawFileParser` (Linux .NET 8 self-contained), `ThermoRawFileParser.exe` (Mono), or check `THERMORAWFILEPARSER` env var. The binary name varies by installation method (Conda, Docker, manual).

30. **Maven Central groupId migration.** Changing from `com.dtwthalion` to `global.thalion` is a breaking change for any Java consumer. Since v0.5 was only on GitHub Packages (not Maven Central), the blast radius is minimal, but document the change clearly.

31. **Sonatype OSSRH setup.** Requires: Sonatype JIRA account, domain verification for `thalion.global` (TXT record or GitHub repo proof), GPG key for artifact signing, CI secrets for deployment. This setup work should happen early in the release cycle, not during M40.

---

## Execution Checklist

1. Tag v0.5.0 if needed.
2. **M37:** Java compound I/O fix. **Pause.**
3. **M38:** Thermo delegation. **Pause.**
4. **M39:** Provider abstraction (all three languages). **Pause.**
5. **M40:** PyPI + Maven Central publishing. **Pause.**
6. **M41:** API review checkpoint. **Pause.**
7. **M42:** Tag v0.6.0.

**CI must be green before any milestone is complete.**

---

## Deferred to v0.7+ (v0.6 snapshot — now superseded)

This v0.6-era table is preserved for historical traceability.
Supersessions:

- **SQLiteProvider** shipped ahead of schedule in v0.6.1
  (commits `44baf65`, `b3d5b46`).
- **ZarrProvider** moved into the v0.7 active plan (M46).
- Remaining items (Java cloud access, Bruker TDF, Waters MassLynx,
  Raman/IR, streaming transport, v1.0 freeze) migrated to the v0.7
  block's "Deferred to v0.8+" table.

| Item | Description |
|---|---|
| ZarrProvider | **→ Moved to v0.7 M46** |
| SQLiteProvider | **→ Shipped in v0.6.1** |
| DBMSTransport | Store .mpgo data in Postgres/MySQL |
| Java cloud access | ROS3 VFD or equivalent for Java |
| Bruker TDF import | Real implementation via TDF SDK |
| Waters MassLynx import | Stub + implementation |
| Raman/IR support | New Spectrum subclasses |
| Streaming transport | MPEG-G Part 2 protocol |
| v1.0 API freeze | After production feedback on provider architecture |
