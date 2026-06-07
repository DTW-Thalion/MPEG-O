# Perf P1d — PQC + mate_info_v2 benches + encryption.genomic stability — Design

**Date:** 2026-06-07
**Origin:** perf-suite analysis coverage gaps (PQC sign/verify; mate_info_v2) + the
`encryption.genomic` report-only override carried since P1a. Fourth sub-cycle of P1.
**Scope:** Three independent perf-harness additions/fixes across all three SDKs. Perf-tooling
only — no SDK product code.

## (A) Fix `encryption.genomic` stability (drop the report-only override)
**Finding:** the P1a "impossible 3.7ms/10MB" premise was wrong — that is ~5 GB/s AES-NI, correct.
The bench encrypts the full 10 MiB non-destructively under min-of-N (verified). The ±25-85%
swing is just jitter on a **sub-5ms op** (ObjC ~1.8ms, Python ~2.5ms — under the floor; Java
~19.7ms, inflated by `Cipher.getInstance` inside the timed block).

**Fix:**
1. **Scale the payload 10 MiB → 64 MiB** in `bench_encryption_genomic` (all 3 harnesses) so the
   op runs well above the 5ms floor and is jitter-stable. `bytes_mb` is derived, so it updates
   automatically. Keep it a fixed size (does not scale with `n`).
2. **Java:** hoist `Cipher.getInstance(...)` + key-spec creation OUT of the timed lambda (build
   the cipher once; time only `doFinal`) to remove provider-lookup variance. (Check
   `EncryptionManager.encrypt` is called per-rep — if the API forces getInstance internally, time
   it as-is but note it; do NOT change product code.)
3. **baseline.json `_meta`:** remove `encryption.genomic.encrypt`/`decrypt` from
   `metric_overrides` (they become normally-gated at the 15% global) and correct the note that
   called the timing "impossible".

**Verify:** after scaling, `encryption.genomic.encrypt` back-to-back drift is <15% above the
floor in all 3 SDKs (measure 2 runs). If a SDK still exceeds 15%, keep its override (documented).

## (B) Add `signatures.pqc` bench (ML-DSA-87 sign/verify)
The existing `signatures` bench is classical HMAC-SHA256. Add a sibling `signatures.pqc` bench
(or extend the signatures bench with `pqc_sign`/`pqc_verify` phases) that keygens ONCE outside
the timed loop, then times `sign` + `verify` (min-of-N; both pure/rep-safe) on a fixed small
message (ML-DSA cost is message-size-insensitive).

**APIs (all offline; ML-DSA-87 / FIPS 204):**
- Python: `from ttio import pqc` → `kp = pqc.sig_keygen(); s = pqc.sig_sign(kp.private_key, msg);
  pqc.sig_verify(kp.public_key, msg, s)`. **Guard on `pqc.is_available()`** (liboqs version skew
  0.15 lib vs 0.14.1 wrapper — works now but may raise); N/A if unavailable.
- Java: `PostQuantumCrypto.sigKeygen()/.sigSign(priv,msg)/.sigVerify(pub,msg,sig)` (BouncyCastle
  1.80). Guard on `PostQuantumCrypto.isAvailable()` if present.
- ObjC: `+[TTIOPostQuantumCrypto sigKeygenWithError:]` / `sigSignWithPrivateKey:message:error:` /
  `sigVerifyWithPublicKey:message:signature:error:`. **Guard on `+isAvailable`** → N/A if NO.

**Runtime dep:** liboqs at `~/_oqs/lib` (ObjC/Python). The ObjC harness links libTTIO which has
undefined `OQS_SIG_*` symbols; ensure `build_and_run_objc_full.sh` puts `~/_oqs/lib` on
`LD_LIBRARY_PATH` so the PQC calls resolve at runtime (the harness loads today because OQS
binding is lazy; a PQC *call* needs the lib). Python uses `liboqs-python` in the venv.

## (C) Add mate_info_v2 to `codecs.genomic`
Add `mate_info_v2_encode`/`mate_info_v2_decode` phases to the existing `codecs.genomic` bench in
all 3 harnesses, following the `delta_rans` pattern exactly (build inputs once, time encode then
decode via min-of-N; both pure). **Same `libttio_rans` dep as the existing genomic codecs — no
new dependency.**

**APIs:**
- Python: `from ttio.codecs import mate_info_v2` → `enc = mate_info_v2.encode(mate_chrom_ids,
  mate_positions, template_lengths, own_chrom_ids, own_positions)`; `mate_info_v2.decode(enc,
  own_chrom_ids, own_positions, n_records)`.
- Java: `MateInfoV2.encode(int[] mateChromIds, long[] matePositions, int[] templateLengths,
  short[] ownChromIds, long[] ownPositions)`; `MateInfoV2.decode(enc, ownChromIds, ownPositions,
  nRecords)`.
- ObjC: `+[TTIOMateInfoV2 encodeMateChromIds:matePositions:templateLengths:ownChromIds:
  ownPositions:error:]` (NSData inputs) / `+decodeData:...`.

**Inputs (build once, ~same scale as existing genomic codec inputs, e.g. reuse the positions
generator):** `mate_chrom_ids` int32, `mate_positions` int64, `template_lengths` int32,
`own_chrom_ids` uint16, `own_positions` int64 — n parallel records. Guard on native-lib presence
like the existing genomic codec benches (0.0/skip if absent).

## Invariants & verification
- Perf-tooling only — no `src/`/SDK product code; only the 3 harness files + the ObjC build
  script (LD_LIBRARY_PATH) + baseline.json.
- All three harnesses build + run; new phases produce finite numbers (PQC may be N/A only if
  liboqs genuinely unavailable — it IS available here).
- `encryption.genomic` drift <15% above floor after scaling (else keep override, documented).
- Cross-SDK: PQC and mate_info_v2 numbers in the same order of magnitude (same algorithms/lib).
- baseline.json re-captured at n=100000; override list updated.

## Success criteria
`encryption.genomic` scaled + stable with its override removed; `signatures.pqc` and
`codecs.genomic.mate_info_v2_{encode,decode}` benched in all three SDKs; baseline re-captured;
numbers reported. One PR.

## Out of scope
P1e cross-SDK perf-parity check (the final P1 sub-cycle).
