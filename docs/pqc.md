# Post-Quantum Cryptography in TTI-O (v0.8 M49)

TTI-O activates two NIST-standardized post-quantum primitives in
v0.8:

| Algorithm       | FIPS      | Role in TTI-O                           | Identifier in catalog |
|-----------------|-----------|------------------------------------------|-----------------------|
| **ML-KEM-1024** | FIPS 203  | Envelope key wrap (replaces AES-KEK)     | `ml-kem-1024`         |
| **ML-DSA-87**   | FIPS 204  | Dataset signatures (`v3:` prefix)        | `ml-dsa-87`           |

Classical primitives (AES-256-GCM, HMAC-SHA256) remain fully active
and are the default for new files unless the caller explicitly opts
into PQC via `algorithm="ml-kem-1024"` / `algorithm="ml-dsa-87"`.

The data-encryption key (DEK) itself is still AES-256 — that's
quantum-resistant already (Grover's algorithm only halves the
effective key size of a symmetric cipher, making AES-256 ≈ AES-128
under quantum attack, which remains far beyond brute-force feasible).
M49 replaces only the **key encapsulation** and the **signature**
primitives.

---

## Binding decision 42 — library choice per language

The original HANDOFF text proposed a single shared dependency —
OpenSSL 3.5 for Python/ObjC and Bouncy Castle 1.79+ for Java — on
the assumption that the Python `cryptography` 44+ wrapper would
expose ML-KEM / ML-DSA through its public API, and that a stable
OpenSSL 3.5 package would ship on Ubuntu 24.04 LTS in time for
v0.8.

**Neither assumption held** as of 2026-04-18:

* Python `cryptography` 46.0.7 (the current release) still exposes
  only classical asymmetric primitives in
  `cryptography.hazmat.primitives.asymmetric` — no `ml_kem` or
  `ml_dsa` submodules. The wheel bundles OpenSSL 3.5.6 internally
  but the Python bindings do not expose `EVP_PKEY_CTX_new_from_name`,
  so the PQC primitives are unreachable from user code.
* Ubuntu 24.04 LTS (Noble) ships `libssl-dev 3.0.13`. There is no
  apt path to 3.5.x as of 2026-04.

Consequently binding decision 42 was revised in M49:

| Language   | PQC backend              | Package/source                                  |
|------------|--------------------------|-------------------------------------------------|
| **Python** | liboqs (via `liboqs-python`) | PyPI: `liboqs-python>=0.14,<1`                |
| **ObjC**   | liboqs (direct C API)    | Source build at `$HOME/_oqs` by default         |
| **Java**   | **Bouncy Castle** 1.79+  | Maven Central: `org.bouncycastle:bcprov-jdk18on:1.80` |

The split is deliberate.

* **Python and ObjC share liboqs** because liboqs 0.14+ ships a stable
  C ABI plus the formally-verified ML-KEM implementation from PQCP's
  `mlkem-native` (CBMC-verified C, HOL-Light-verified AArch64
  assembly — much stronger assurance than Bouncy Castle's Java
  implementation today).
* **Java uses Bouncy Castle** because liboqs's Java bindings rely on a
  JNI shim that is brittle across platforms (particularly in
  MSYS2/MinGW) and adds a build-system dependency that has no
  Maven-Central analog. Bouncy Castle 1.79+ ships production-
  quality PQC natively in pure Java, is already on Maven Central,
  and is widely deployed in the JVM ecosystem.

**Acceptable divergence.** The three implementations produce
byte-compatible output: same ML-KEM-1024 key and ciphertext sizes,
same ML-DSA-87 signature format, same on-disk wrapped-key blob
layout (§ "Wire format" below). The cross-language conformance
test (M54) validates this explicitly.

---

## Installation

### Python

```bash
pip install 'ttio[pqc]'
```

This pulls `liboqs-python` from PyPI. On first import, `liboqs-python`
auto-builds a liboqs shared library into `$HOME/_oqs` via CMake +
Ninja (takes a couple of minutes). To pre-install liboqs system-wide
and skip the auto-build:

```bash
git clone https://github.com/open-quantum-safe/liboqs.git
cd liboqs
cmake -B build -GNinja -DBUILD_SHARED_LIBS=ON -DOQS_BUILD_ONLY_LIB=ON \
      -DCMAKE_INSTALL_PREFIX=/usr/local
ninja -C build && sudo ninja -C build install
```

### ObjC

The build picks up liboqs automatically from `$OQS_PREFIX`,
`$HOME/_oqs`, `/usr/local/oqs`, `/opt/oqs`, `/usr/local`, or `/usr`
— first found wins. If liboqs is absent at build time, the PQC
entry points in `TTIOPostQuantumCrypto` return `NO` with a clear
"libTTIO was built without liboqs" error message at runtime, and
existing AES-GCM / HMAC code paths are unaffected.

### Java

Bouncy Castle is a plain Maven dependency pinned in `java/pom.xml`.
No additional setup required:

```xml
<dependency>
    <groupId>org.bouncycastle</groupId>
    <artifactId>bcprov-jdk18on</artifactId>
    <version>1.80</version>
</dependency>
```

---

## Wire format

### ML-DSA-87 dataset signatures — `v3:` prefix

Stored as a variable-length string attribute `@mpgo_signature` on
the signed dataset:

```
v3:<base64(ml_dsa_87_signature_bytes)>
```

Raw signature is 4627 bytes (FIPS 204, parameter set 5). Base64
encoding brings the attribute string length to about 6176 bytes.
HDF5 VL string attributes handle arbitrary sizes, so no format
change was required beyond the prefix reservation introduced in
v0.7 M47.

**Backward compatibility:** `v2:` HMAC-SHA256 signatures remain
fully valid and verifiable. A verifier that sees `v3:` but does
not support PQC raises `UnsupportedAlgorithmError` / equivalent —
it does not silently pass the verification.

### ML-KEM-1024 envelope wrap

Inside the v1.2 wrapped-key blob (§ 8 of `format-spec.md`):

```
+0   2  magic       = 'M' 'W'
+2   1  version     = 0x02
+3   2  algorithm_id = 0x0001  (ML-KEM-1024)
+5   4  ciphertext_len (big-endian)   = 32
+9   2  metadata_len   (big-endian)   = 1596
+11  1596 metadata = kem_ciphertext(1568) || aes_iv(12) || aes_tag(16)
+1607 32 ciphertext = AES-256-GCM wrapped DEK
```

Total blob length: 11 + 1596 + 32 = **1639 bytes**.

The envelope decryption chain is:

1. Read the v1.2 blob from `/protection/key_info/dek_wrapped`.
2. Parse the metadata: split into `kem_ct` (1568), `aes_iv` (12),
   `aes_tag` (16).
3. `shared_secret = ML_KEM_1024.decapsulate(kem_ct, recipient_sk)`
   → 32 bytes.
4. `dek = AES_256_GCM.decrypt(aes_iv, ciphertext || aes_tag,
   key=shared_secret)` → 32 bytes.

ML-KEM decapsulation itself is *unauthenticated*. The chain is
authenticated by the AES-GCM tag on the inner wrap — a tampered
`kem_ct` yields a garbage shared secret which fails the AES-GCM
tag check.

**Backward compatibility:** v1.2 AES-256-GCM blobs (algorithm_id
`0x0000`, 71 bytes total) and v1.1 legacy blobs (60 bytes fixed)
remain readable forever (HANDOFF binding decision 38).

### `opt_pqc_preview` feature flag

Any file that uses `ml-kem-1024` for key wrapping or `ml-dsa-87`
for signatures gets `opt_pqc_preview` added to its root
`@ttio_features` list. Because it carries the `opt_` prefix,
readers without PQC support can still open the file — they just
cannot verify v3 signatures or unwrap ML-KEM-wrapped DEKs (AES-GCM
wrapped DEKs on the same file remain unwrappable).

---

## API shape per language

### Python

```python
from ttio import pqc, signatures, key_rotation

# Primitives
kp = pqc.kem_keygen()                       # KeyPair(pk=1568, sk=3168)
ct, ss = pqc.kem_encapsulate(kp.public_key) # 1568 / 32
ss2 = pqc.kem_decapsulate(kp.private_key, ct)

sig_kp = pqc.sig_keygen()                   # KeyPair(pk=2592, sk=4896)
sig = pqc.sig_sign(sig_kp.private_key, msg) # 4627 bytes
ok = pqc.sig_verify(sig_kp.public_key, msg, sig)

# Dataset signing (v3)
signatures.sign_dataset(ds, sig_kp.private_key, algorithm="ml-dsa-87")
signatures.verify_dataset(ds, sig_kp.public_key, algorithm="ml-dsa-87")

# Envelope wrap
dek = key_rotation.enable_envelope_encryption(
    f, kp.public_key, kek_id="kem-1", algorithm="ml-kem-1024"
)
dek = key_rotation.unwrap_dek(f, kp.private_key, algorithm="ml-kem-1024")
```

### Java

```java
import global.thalion.ttio.protection.*;

// Primitives
PostQuantumCrypto.KeyPair kp = PostQuantumCrypto.kemKeygen();
PostQuantumCrypto.KemEncapResult r =
    PostQuantumCrypto.kemEncapsulate(kp.publicKey());

PostQuantumCrypto.KeyPair sk = PostQuantumCrypto.sigKeygen();
byte[] sig = PostQuantumCrypto.sigSign(sk.privateKey(), msg);
boolean ok = PostQuantumCrypto.sigVerify(sk.publicKey(), msg, sig);

// Dataset signing (v3) — via SignatureManager.sign(..., algorithm)
String stored = SignatureManager.sign(data, sk.privateKey(), "ml-dsa-87");
SignatureManager.verify(data, stored, sk.publicKey(), "ml-dsa-87");

// Envelope wrap — EncryptionManager.wrapKey with algorithm
byte[] wrapped = EncryptionManager.wrapKey(dek, kp.publicKey(),
                                             false, "ml-kem-1024");
byte[] unwrapped = EncryptionManager.unwrapKey(
    wrapped, kp.privateKey(), "ml-kem-1024");
```

### Objective-C

```objc
#import <TTIOPostQuantumCrypto.h>
#import <TTIOKeyRotationManager.h>
#import <TTIOSignatureManager.h>

// Primitives
TTIOPQCKeyPair *kp = [TTIOPostQuantumCrypto kemKeygenWithError:&err];
TTIOPQCKemEncapResult *r =
    [TTIOPostQuantumCrypto kemEncapsulateWithPublicKey:kp.publicKey
                                                 error:&err];
NSData *ss2 =
    [TTIOPostQuantumCrypto kemDecapsulateWithPrivateKey:kp.privateKey
                                             ciphertext:r.ciphertext
                                                  error:&err];

TTIOPQCKeyPair *sk = [TTIOPostQuantumCrypto sigKeygenWithError:&err];
NSData *sig = [TTIOPostQuantumCrypto sigSignWithPrivateKey:sk.privateKey
                                                   message:msg
                                                     error:&err];
BOOL ok = [TTIOPostQuantumCrypto sigVerifyWithPublicKey:sk.publicKey
                                                message:msg
                                              signature:sig
                                                  error:&err];

// Dataset signing (v3) — TTIOSignatureManager algorithm-parameterized
[TTIOSignatureManager signDataset:@"/payload"
                           inFile:path
                          withKey:sk.privateKey
                        algorithm:@"ml-dsa-87"
                            error:&err];
[TTIOSignatureManager verifyDataset:@"/payload"
                             inFile:path
                            withKey:sk.publicKey
                          algorithm:@"ml-dsa-87"
                              error:&err];

// Envelope wrap — TTIOKeyRotationManager algorithm-parameterized
TTIOKeyRotationManager *mgr =
    [TTIOKeyRotationManager managerWithFile:f];
NSData *dek = [mgr enableEnvelopeEncryptionWithKEK:kp.publicKey
                                              kekId:@"kem-1"
                                          algorithm:@"ml-kem-1024"
                                              error:&err];
NSData *dekRead = [mgr unwrapDEKWithKEK:kp.privateKey
                               algorithm:@"ml-kem-1024"
                                   error:&err];
```

---

## Key sizes reference

| Quantity                         | Bytes |
|----------------------------------|-------|
| ML-KEM-1024 public key           | 1568  |
| ML-KEM-1024 private key          | 3168  |
| ML-KEM-1024 ciphertext           | 1568  |
| ML-KEM-1024 shared secret        | 32    |
| ML-DSA-87 public key             | 2592  |
| ML-DSA-87 private key            | 4896  |
| ML-DSA-87 signature              | 4627  |

These are pinned in `TTIOCipherSuite` (ObjC) /
`ttio.cipher_suite` (Python) / `CipherSuite` (Java) catalog
entries. See the dedicated accessors:
`public_key_size` / `private_key_size` per language.

---

## Transport encryption composition (v1.0)

Per-AU encryption (`opt_per_au_encryption`) composes with PQC
without any special casing: the KEM (ML-KEM-1024 or classical
RSA-OAEP) wraps the DEK once per run, exactly as in the wire-format
section above; the DEK then drives **per-Access-Unit**
AES-256-GCM operations for each spectrum's channel bytes (and,
when `opt_encrypted_au_headers` is set, for each AU's 36-byte
semantic header). `ProtectionMetadata` on the transport wire
carries the same wrapped DEK bytes the `<channel>_wrapped_dek`
attribute would hold on disk. See
`docs/transport-encryption-design.md` for the full per-AU
encryption design.

## Related docs

* `docs/format-spec.md` § 10b — wrapped-key blob layout.
* `docs/format-spec.md` § 9.1 — per-AU encrypted channel layout.
* `docs/feature-flags.md` — `opt_pqc_preview`, `opt_per_au_encryption`,
  `opt_encrypted_au_headers`.
* `docs/transport-encryption-design.md` — per-AU encryption spec.
* `docs/migration-guide.md` — upgrading from classical to PQC.
* `HANDOFF.md` — M49 acceptance criteria and binding decisions.
