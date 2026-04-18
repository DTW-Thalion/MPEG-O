# MPEG-O v0.8 — PQC + Multi-Backend Parity + Vendor Import

> **Status:** v0.8.0 is **complete and released (2026-04-18)** — all
> milestones M49, M49.1, M52, M53, M54, M54.1, M55, M56 shipped.
> ObjC 1133 assertions, Python 341 tests, Java 207 tests. Four
> storage providers in every language: HDF5, Memory, SQLite, Zarr.
> Post-quantum crypto active (ML-KEM-1024 + ML-DSA-87). Bruker
> timsTOF `.d` importer with opentimspy binary extraction.
> 32-cell cross-language PQC conformance matrix passes.
>
> Next cycle — v0.9: see the **Deferred to v0.9+** section below.

---

## Critical Update: PQC Ecosystem Now Production-Ready

The v0.7 deferral of M49 cited immature PQC bindings. That blocker
is fully resolved:

- **OpenSSL 3.5.0** (April 8, 2025, LTS until 2030): native ML-KEM,
  ML-DSA, SLH-DSA via the default provider. No OQS plugin needed.
  This is the path for ObjC and Python (via `cryptography` library
  which wraps OpenSSL).
- **Bouncy Castle Java 1.79+** (Dec 2024): production ML-KEM and
  ML-DSA. BC-FIPS 2.1.x adds FIPS-validated PQC. This is the Java
  path.
- **liboqs 0.14+**: formally verified ML-KEM via PQCP's mlkem-native
  (CBMC-verified C, HOL-Light-verified AArch64 assembly). Available
  as a fallback if OpenSSL 3.5 is not installed.

The CipherSuite catalog (M48) already has reserved IDs for ML-KEM-1024
and ML-DSA-87 per binding decision 40. M49 fills in the implementations.

---

## First Steps

1. `git clone https://github.com/DTW-Thalion/MPEG-O.git && cd MPEG-O && git pull`
2. Read: `HANDOFF.md` (v0.7 historical record), `ARCHITECTURE.md`,
   `docs/format-spec.md`, `docs/api-review-v0.7.md`, `docs/providers.md`
3. Verify all three builds:
   ```bash
   cd objc && ./build.sh check        # 1057 assertions
   cd ../python && pip install -e ".[test,import,crypto,zarr]" && pytest  # 284 tests
   cd ../java && mvn verify -B        # 179 tests
   ```
4. Tag v0.7.0 if not already tagged.

---

## Binding Decisions — All Prior (1–41) Active, Plus:

42. **PQC library choice — REVISED in M49.** The original plan
    specified OpenSSL 3.5 for Python/ObjC and Bouncy Castle for
    Java. Empirical check at M49 kickoff (2026-04-18):
    * Python `cryptography` 46.0.7 does not expose ML-KEM / ML-DSA
      (only classical asymmetric primitives). The bundled OpenSSL
      3.5.6 has the algorithms but the Python FFI layer does not
      bind `EVP_PKEY_CTX_new_from_name`.
    * Ubuntu 24.04 LTS is stuck on `libssl-dev 3.0.13`; no apt
      route to 3.5.
    Revised binding (2026-04-18, user-approved):
    * **Python + ObjC: liboqs** (PyPI `liboqs-python>=0.14` for
      Python; direct C API for ObjC). liboqs 0.14+ ships the
      formally-verified ML-KEM from PQCP's mlkem-native.
    * **Java: Bouncy Castle** `bcprov-jdk18on:1.80` (unchanged
      from original plan — BC 1.79+ is production PQC on the JVM).
    This split is documented in `docs/pqc.md` and does not affect
    the wire format — all three languages emit byte-identical
    ML-KEM-1024 ciphertexts, ML-DSA-87 signatures, and v1.2
    wrapped-key blobs.
43. **PQC key encapsulation for DEK wrapping.** ML-KEM-1024 replaces
    AES-256-GCM key wrapping in the envelope model. The DEK itself
    (symmetric AES-256) is unchanged — AES-256 is already
    quantum-secure (Grover reduces to AES-128-equivalent).
44. **PQC signatures.** ML-DSA-87 replaces HMAC-SHA256 for dataset
    and provenance signatures. Existing `v2:` HMAC signatures remain
    verifiable. New PQC signatures carry a `v3:` prefix.
45. **Bruker TDF: direct SQLite read.** Unlike Thermo (proprietary
    binary, requires delegation), Bruker TDF stores metadata in a
    standard SQLite database (`analysis.tdf`) alongside a binary
    blob file (`analysis.tdf_bin`). The metadata is directly
    readable. The binary data uses documented frame-based compression.
    No proprietary SDK required for metadata; the binary compression
    uses open-source `opentims` algorithms.
46. **Package publishing deferred.** Internal use only until the team
    decides to go public. TestPyPI + GitHub Packages remain the
    distribution channels. PyPI and Maven Central deferred to a
    future release.

---

## Deferred Items Ledger — Full Accounting

| Item | Origin | v0.8 | Rationale |
|---|---|---|---|
| ★ M49 PQC preview | v0.7 deferred | **M49** | OpenSSL 3.5 + BC 1.79 unblock it |
| ◇ M40 PyPI + Maven Central | v0.6 deferred | **Deferred** | Internal use only for now; publish when ready for external users |
| ★ Java/ObjC ZarrProvider | v0.7 binding #41 | **M52** | Python shipped in v0.7; port to remaining langs |
| ★ Bruker TDF import | v0.4 deferred | **M53** | Second most-used vendor format; SQLite metadata is open |
| ★ v1.0 API prep | Recurring | **M55** | Deprecation pass + stability markers before freeze |
| ◇ Waters MassLynx import | v0.5 deferred | **v0.9** | Lower market share than Thermo+Bruker |
| ◇ Raman/IR support | v0.5 deferred | **v0.9** | Needs domain expert input; class hierarchy ready |
| ◇ Streaming transport | v0.2 deferred | **v1.0+** | Needs instrument vendor partnerships |
| ◇ DBMS transport | v0.6 deferred | **v0.9** | Postgres/MySQL blob storage for .mpgo data |
| ◇ Java cloud access | v0.5 deferred | **M52** (partial) | ROS3 or equivalent; bundled with Zarr port |
| ◇ ParquetProvider | v0.7 deferred | **v0.9** | Another provider stress-test |
| ◇ FIPS compliance mode | v0.7 deferred | **v1.0** | Algorithm allow-list lockdown after PQC stabilizes |
| ◇ v1.0 API freeze | Recurring | **v1.0** | After production feedback on v0.8 |

---

## Dependency Graph

```
  M49 (PQC)            M52 (Java/ObjC Zarr)     M53 (Bruker TDF)
       |                    |                        |
       v                    v                        |
  M54 (PQC cross-compat)   |                        |
       |                    |                        |
       +--------+-----------+------------------------+
                |
                v
           M55 (v1.0 API prep)
                |
                v
           M56 (v0.8.0 release)
```

M49, M52, M53 are independent. M54 validates PQC across all three
languages (needs M49 + M52 because Zarr files must also be PQC-signable).
M55 is the API deprecation pass. M56 tags the release.

---

## Milestone 49 — Post-Quantum Cryptography (All Three Languages)

**License:** LGPL-3.0

### Key Encapsulation: ML-KEM-1024

Replace AES-256-GCM key wrapping in the envelope model with ML-KEM-1024
(FIPS 203). The symmetric DEK (AES-256) is unchanged.

**ObjC:** Use OpenSSL 3.5's EVP API:
```c
EVP_PKEY *pkey = EVP_PKEY_Q_keygen(NULL, NULL, "ML-KEM-1024");
// Encapsulate: EVP_PKEY_encapsulate()
// Decapsulate: EVP_PKEY_decapsulate()
```

**Python:** Use `cryptography` >= 44.0 (wraps OpenSSL 3.5):
```python
from cryptography.hazmat.primitives.asymmetric import ml_kem
private_key = ml_kem.MLKEM1024PrivateKey.generate()
```

**Java:** Bouncy Castle 1.79+:
```java
import org.bouncycastle.pqc.jcajce.provider.BouncyCastlePQCProvider;
KeyPairGenerator kpg = KeyPairGenerator.getInstance("ML-KEM-1024", "BCPQC");
```

### Digital Signatures: ML-DSA-87

Replace HMAC-SHA256 for dataset and provenance signatures with ML-DSA-87
(FIPS 204). The `v3:` prefix distinguishes PQC signatures from `v2:`
canonical HMAC signatures.

**HDF5 layout additions:**
- `/protection/key_info/@kek_algorithm` gains value `"ml-kem-1024"`
- `@mpgo_signature` gains `v3:` prefix format: `"v3:" + base64(ml_dsa_87_sig)`
- `@signature_algorithm` attribute: `"ml-dsa-87"` or `"hmac-sha256"` (new)
- `CipherSuite` catalog updated: `ML_KEM_1024` and `ML_DSA_87` IDs activated

### Backward Compatibility

- `v2:` HMAC-SHA256 signatures remain verifiable indefinitely
- AES-256-GCM wrapped DEKs (v1.1 and v1.2 formats) remain decryptable
- `CipherSuite.detect()` auto-selects classical or PQC based on file metadata
- `pqc_preview` feature flag on files that use PQC (opt-in, not default)

### CI Requirements

- ObjC: verify `openssl version` >= 3.5.0 in CI. If Ubuntu's default
  OpenSSL is older, install from PPA or build from source.
- Python: `pip install 'cryptography>=44.0'` (ensure it links OpenSSL 3.5+)
- Java: add Bouncy Castle PQC provider dependency to `pom.xml`

### Acceptance

- [ ] ML-KEM-1024 encapsulate/decapsulate round-trip in all three languages
- [ ] ML-DSA-87 sign/verify round-trip in all three languages
- [ ] Envelope key rotation with ML-KEM KEK works
- [ ] `v3:` signature on dataset verifiable across languages
- [ ] `v2:` HMAC signatures still verifiable (backward compat)
- [ ] `CipherSuite.detect()` correctly selects classical vs PQC
- [ ] `pqc_preview` feature flag emitted on PQC-protected files
- [ ] Files encrypted with AES-GCM wrapped keys still decryptable

---

## Milestone 52 — Java/ObjC ZarrProvider

**License:** LGPL-3.0

Python shipped ZarrProvider in v0.7 M46 (binding decision 41: Python-first).
Port to Java and ObjC using the abstraction validated by Python.

**ObjC:** `MPGOZarrProvider` in `objc/Source/Providers/`. Zarr v2 format
(directory-of-files with `.zarray` JSON metadata + raw chunk files).
Uses POSIX I/O for chunk reads. No external Zarr library needed — the
format is simple enough for a self-contained implementation.

**Java:** `com.dtwthalion.mpgo.providers.ZarrProvider`. Same approach:
direct directory I/O, JSON metadata parsing via included JSON utilities.

**Both must pass the same round-trip tests as the Python ZarrProvider:**
- Create dataset with MemoryProvider → transfer to ZarrProvider → read back → verify
- Cross-provider: write with HDF5, read with Zarr (requires conversion utility)
- Canonical bytes (`read_canonical_bytes`) must produce identical output
  across HDF5, Memory, SQLite, and Zarr for the same logical data

**Acceptance**

- [ ] ObjC ZarrProvider round-trip with spectra, identifications, provenance
- [ ] Java ZarrProvider round-trip
- [ ] Python Zarr fixtures readable by ObjC and Java
- [ ] ObjC/Java Zarr fixtures readable by Python
- [ ] Canonical bytes match across all four providers
- [ ] Provider registry auto-discovers ZarrProvider in all three languages

---

## Milestone 53 — Bruker TDF Import

**License:** Apache-2.0

Bruker timsTOF data uses a two-file architecture:
- `analysis.tdf` — standard SQLite database with metadata tables
  (Frames, Precursors, Properties, etc.)
- `analysis.tdf_bin` — binary blob with compressed frame data

The SQLite metadata is openly readable. The binary compression uses
documented algorithms (ZSTD frames with Bruker's scan-to-ion mapping).
The `opentims` project provides open-source decompression.

**Approach:** Read SQLite metadata directly. For binary decompression,
delegate to `opentims` (Python) or implement the documented frame
decompression in ObjC/Java.

**Python:** `mpeg_o.importers.bruker_tdf`
```python
def read(tdf_dir: str | Path) -> SpectralDataset:
    """Read a Bruker .d directory containing analysis.tdf + analysis.tdf_bin."""
```

**ObjC:** `MPGOBrukerTDFReader` in `Import/`
**Java:** `BrukerTDFReader.java` in `importers/`

All three: read `analysis.tdf` via SQLite (`sqlite3` stdlib for Python,
`libsqlite3` for ObjC, `java.sql` for Java). Extract frames, convert to
`AcquisitionRun` with ion mobility as an additional signal channel.

**Acceptance**

- [ ] Read a Bruker `.d` directory → valid SpectralDataset with ion mobility data
- [ ] Frame count matches SQLite Frames table
- [ ] m/z and intensity values verified against `opentims` reference extraction
- [ ] Ion mobility values extracted as a third signal channel
- [ ] Instrument metadata populated from Properties table
- [ ] `docs/vendor-formats.md` updated with Bruker TDF section

---

## Milestone 54 — PQC Cross-Language Conformance

**License:** LGPL-3.0

Validates that PQC operations produce identical results across all
three languages and all four storage providers.

**Test matrix:**

| Operation | ObjC→Python | ObjC→Java | Python→Java | Python→ObjC | Java→ObjC | Java→Python |
|---|---|---|---|---|---|---|
| ML-KEM-1024 encaps/decaps | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| ML-DSA-87 sign/verify | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| v3 signature on HDF5 | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| v3 signature on Zarr | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| v3 signature on SQLite | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |
| Envelope rotation ML-KEM | ✓ | ✓ | ✓ | ✓ | ✓ | ✓ |

**Acceptance**

- [ ] 36-cell cross-language × cross-provider PQC verification matrix passes
- [ ] Classical (v2 HMAC) + PQC (v3 ML-DSA) coexist on same file
- [ ] Mixed-version verification: v0.7 classical file verifiable by v0.8 code

---

## Milestone 55 — v1.0 API Preparation

**License:** All

Not a freeze — a deprecation pass and stability audit. Tag APIs that
will change before v1.0 and document the migration path.

**Deliverables**

- `docs/api-stability-v0.8.md`: every public API marked Stable /
  Provisional / Deprecated with migration guidance
- Deprecation annotations: `@Deprecated` (Java), `MPGO_DEPRECATED_MSG`
  (ObjC), `warnings.warn` (Python) on any API planned for removal
- Provider interfaces: assess whether `native_handle()` escape hatch
  can be removed by v1.0 (M43/M44 may have eliminated all callers)
- Feature flag review: any flags that should become required by v1.0?
- `CHANGELOG.md`: created, covering v0.1 through v0.8

**Acceptance**

- [ ] `docs/api-stability-v0.8.md` committed
- [ ] All deprecated APIs emit warnings
- [ ] `CHANGELOG.md` committed with all releases documented
- [ ] No new Provisional APIs introduced in v0.8 (only Stable or Deprecated)

---

## Milestone 56 — v0.8.0 Release

**Deliverables**

- All docs updated (ARCHITECTURE, format-spec, feature-flags,
  vendor-formats, api-stability, changelog, providers, migration-guide)
- CI: three-language matrix + cross-compat + PQC + Zarr + Bruker
- Packages: TestPyPI + GitHub Packages (internal distribution only)
- Tag v0.8.0

**Acceptance**

- [ ] ObjC, Python, Java all green
- [ ] Four-provider cross-compat (HDF5, Memory, SQLite, Zarr) × three languages
- [ ] PQC cross-language conformance matrix passes
- [ ] Bruker TDF import verified
- [ ] v0.1–v0.7 backward compat preserved
- [ ] TestPyPI updated, GitHub Packages updated
- [ ] Tag pushed

---

## Known Gotchas

**Inherited (1–38):** All prior gotchas active.

**New (v0.8):**

39. **OpenSSL 3.5 availability in CI.** Ubuntu 24.04 ships OpenSSL
    3.0.x. Ubuntu 24.10+ may ship 3.5. Check `openssl version` in
    CI; if < 3.5, install from source or PPA. The `cryptography`
    Python package bundles its own OpenSSL — verify it's 3.5+ via
    `python -c "from cryptography.hazmat.bindings.openssl import binding; print(binding.Binding.lib.OpenSSL_version_text())"`.

40. **Bouncy Castle provider registration.** Java Security provider
    must be registered before PQC operations:
    `Security.addProvider(new BouncyCastlePQCProvider())`.
    Add to test setup and document in README.

41. **ML-KEM key sizes.** ML-KEM-1024 public keys are 1568 bytes;
    ciphertexts are 1568 bytes. This is much larger than AES-256-GCM
    wrapped keys (60 bytes). The `/protection/key_info/dek_wrapped`
    dataset must be resized. Use the versioned wrapped-key blob
    format (M47 v1.2) which includes a length prefix.

42. **ML-DSA-87 signature sizes.** ML-DSA-87 signatures are 4627
    bytes — much larger than HMAC-SHA256 (32 bytes base64-encoded).
    The `@mpgo_signature` attribute must accommodate this. HDF5 VL
    string attributes handle arbitrary sizes; no format change needed.

43. **Bruker TDF binary decompression.** The `analysis.tdf_bin` file
    uses ZSTD-compressed frames with a Bruker-specific scan-to-ion
    index. The `opentims` Python library handles this; for ObjC and
    Java, either delegate to a Python helper or implement the
    documented frame layout (header + ZSTD payload + scan offsets).

44. **Zarr v2 vs v3.** The Python ZarrProvider targets zarr-python
    2.18+ (v2 format). Zarr v3 (zarr-python 3.x) rewrites the
    storage API. The ObjC/Java implementations should target v2
    (directory-of-files) for compatibility. Zarr v3 migration is
    a v0.9 concern.

45. **Internal distribution only.** TestPyPI and GitHub Packages are
    the distribution channels for v0.8. Do not configure PyPI or
    Maven Central publishing workflows.

---

## Execution Checklist

1. Tag v0.7.0 if needed.
2. **M49:** PQC (all three languages). **Pause.**
3. **M52:** Java/ObjC ZarrProvider. **Pause.**
4. **M53:** Bruker TDF import. **Pause.**
5. **M54:** PQC cross-language conformance. **Pause.**
6. **M55:** v1.0 API prep. **Pause.**
7. **M56:** Tag v0.8.0.

**CI must be green before any milestone is complete.**

---

## Deferred to v0.9+

| Item | Description |
|---|---|
| M40 PyPI + Maven Central | Publish when ready for external users |
| Waters MassLynx import | Stub + real implementation |
| Raman/IR spectrum support | New Spectrum subclasses |
| DBMS transport | Postgres/MySQL blob storage |
| ParquetProvider | Columnar alternative backend |
| Zarr v3 migration | Update ZarrProvider from v2 → v3 format |
| FIPS compliance mode | Algorithm allow-list lockdown |
| Streaming transport | MPEG-G Part 2 real-time protocol |
| v1.0 API freeze | After production feedback on v0.8 |
