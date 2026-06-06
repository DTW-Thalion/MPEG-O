# fqzcomp Dead-Code Removal + Live-Path Tests (R3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Delete the unreachable V1/V2/V3 fqzcomp (M94.Z) code in all three SDKs so coverage reflects live code, and add tests for the live V4 path.

**Architecture:** The codec is V4-only at runtime (V4 = wrapper over native `libttio_rans`; v1/2/3 decode already throws). Remove the dead pure-language V1/V2/V3 bodies + their orphaned helpers/fixtures/tests, keep the v1/2/3 rejection branches, add live-V4 edge/error tests. No live-wire/`.tio`/registry change.

**Tech Stack:** Python (pytest), Java (JUnit 5 + JaCoCo), ObjC (GNUstep `Testing.h`), native `libttio_rans` via ctypes/JNI/C.

**Deletion guidance:** Delete by SYMBOL NAME (line numbers shift as you delete). Read each file first, then remove the named functions/types entirely. After each deletion pass, verify nothing inside the file still references a removed symbol (grep the file for the name). The authoritative keep/delete lists are below.

**Build/verify (WSL):**
- Python: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest <args>`
- Java: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B <args>`
- ObjC: `cd ~/TTI-O/objc && ./build.sh check`
- WSL shell: `wsl -d Ubuntu -- bash -c '<cmd>'`. Commits: `git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit ...`. If a Read shows empty (WSL mount glitch), retry or `cat` via wsl.

---

## Task 1: Python — delete dead V1/V2/V3 + trim exports + orphaned fixtures + live tests

**Files:**
- Modify: `python/src/ttio/codecs/fqzcomp_nx16_z.py`
- Modify: `python/tests/test_m94z_v4_dispatch.py`
- Delete: `python/tests/fixtures/codecs/m94z_{a,b,c,d,f,g,h}.bin`

**Context:** Live entrypoints are `encode(qualities, read_lengths, revcomp_flags, ...)` and `decode_with_metadata(encoded, revcomp_flags=None)`; both route to the V4 ctypes wrappers `_encode_v4_native` / `_decode_v4_via_native`. `decode_with_metadata` rejects version bytes 1/2/3 with `raise ValueError(... no longer supported ...)` — KEEP that. The native loader (`_load_native_lib`, `_HAVE_NATIVE_LIB`, `_native_lib`, `get_backend_name`, `_native_kernel_name`) is shared with other codecs — KEEP. Existing live tests are in `test_m94z_v4_dispatch.py` (9 tests, gated `@pytest.mark.skipif(not _HAVE_NATIVE_LIB)`). The module's `__all__` currently exports dead helpers.

- [ ] **Step 1: Read the module and confirm the keep/delete sets**

Read `python/src/ttio/codecs/fqzcomp_nx16_z.py` fully. Confirm the live call graph (`encode` → `_encode_v4_native`; `decode_with_metadata` → `_decode_v4_via_native`; both via `_native_lib`).

- [ ] **Step 2: Delete the dead symbols**

DELETE these (functions, dataclasses, and constants used only by them):
`_encode_body`, `_decode_body`, `_encode_one_step`, `_decode_one_step`, `_build_context_seq`, `_build_context_seq_arr_vec`, `_vectorize_first_encounter`, `_serialize_freq_tables`, `_deserialize_freq_tables`, `_encode_read_lengths`, `_decode_read_lengths`, `_pack_codec_header`, `_unpack_codec_header`, `_pack_codec_header_v2`, `_unpack_codec_header_v2`, `_pack_codec_header_v3`, `_unpack_codec_header_v3`, `normalise_to_total`, `cumulative`, `m94z_context`, `position_bucket_pbits`, `pack_context_params`, `unpack_context_params`, and the `ContextParams` and `CodecHeader` dataclasses.

KEEP: `encode`, `decode_with_metadata` (incl. its v1/2/3 rejection branch), `_encode_v4_native`, `_decode_v4_via_native`, `_load_native_lib`, `_native_lib`/`_HAVE_NATIVE_LIB`, `_native_kernel_name`, `get_backend_name`, `MAGIC`, `VERSION_V4_FQZCOMP`, and any V4 sizing constants still referenced by the V4 wrappers. Remove now-unused constants `VERSION`, `VERSION_V2_NATIVE`, `VERSION_V3_ADAPTIVE`, `ADAPTIVE_STEP`, `ADAPTIVE_T_MAX`, `T`, `T_BITS`, etc. ONLY if nothing kept references them (grep the file after deleting).

- [ ] **Step 3: Trim `__all__`**

Reduce `__all__` to only the surviving public surface (`encode`, `decode_with_metadata`, `get_backend_name`, `MAGIC`, `VERSION_V4_FQZCOMP`, and any sizing constant still used/exported). Remove dead entries.

- [ ] **Step 4: Verify the module imports and has no dangling refs**

Run: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/python -c "import ttio.codecs.fqzcomp_nx16_z as m; print('import OK', m.get_backend_name()); print(m.__all__)"`
Expected: imports cleanly, prints a backend name. Then grep the file for each deleted symbol name to confirm zero internal references remain.

- [ ] **Step 5: Delete orphaned v3 fixtures + confirm unreferenced**

First confirm nothing reads them: `wsl -d Ubuntu -- bash -c "cd ~/TTI-O && grep -rn 'm94z_a\|m94z_b\|m94z_c\|m94z_d\|m94z_f\|m94z_g\|m94z_h' --include=*.py python | grep -v __pycache__"` (expect no active references). Then delete `python/tests/fixtures/codecs/m94z_{a,b,c,d,f,g,h}.bin` (NOT the `fqzcomp_nx16_*.bin` files).

- [ ] **Step 6: Add live V4 edge/error tests**

Append to `python/tests/test_m94z_v4_dispatch.py` (match its existing gating + style — read it first; tests gated on `_HAVE_NATIVE_LIB`, no slow/perf/integration marker). Add only branches not already covered:

```python
def test_v4_encode_rejects_length_mismatch():
    """read_lengths summing to != len(qualities) is rejected."""
    if not _HAVE_NATIVE_LIB:
        pytest.skip("native libttio_rans not available")
    from ttio.codecs.fqzcomp_nx16_z import encode
    with pytest.raises((ValueError, RuntimeError)):
        encode(bytes([40, 40, 40]), [2], [0])  # sum(lengths)=2 != 3


def test_v4_encode_rejects_revcomp_length_mismatch():
    if not _HAVE_NATIVE_LIB:
        pytest.skip("native libttio_rans not available")
    from ttio.codecs.fqzcomp_nx16_z import encode
    with pytest.raises((ValueError, RuntimeError)):
        encode(bytes([40, 40, 40, 40]), [2, 2], [0])  # 1 flag for 2 reads


def test_v4_decode_rejects_truncated_blob():
    if not _HAVE_NATIVE_LIB:
        pytest.skip("native libttio_rans not available")
    from ttio.codecs.fqzcomp_nx16_z import decode_with_metadata
    with pytest.raises((ValueError, RuntimeError)):
        decode_with_metadata(b"\x00\x01")  # too short for a header


def test_v4_decode_rejects_bad_magic():
    if not _HAVE_NATIVE_LIB:
        pytest.skip("native libttio_rans not available")
    from ttio.codecs.fqzcomp_nx16_z import decode_with_metadata
    with pytest.raises((ValueError, RuntimeError)):
        decode_with_metadata(b"XXXX" + bytes(32))  # wrong magic


def test_v4_decode_rejects_legacy_version_byte():
    """v1/2/3 tagged blobs must be rejected (no backward-compat decode)."""
    if not _HAVE_NATIVE_LIB:
        pytest.skip("native libttio_rans not available")
    from ttio.codecs.fqzcomp_nx16_z import encode, decode_with_metadata
    blob = bytearray(encode(bytes([40, 40, 40, 40]), [4], [0]))
    blob[4] = 3  # tamper version byte → legacy
    with pytest.raises((ValueError, RuntimeError)):
        decode_with_metadata(bytes(blob))
```

IMPORTANT: verify the exact validation behavior against the kept `encode`/`decode_with_metadata` source (the explorer found length/sum validation at ~1540-1555 and version rejection at ~1602-1622). Adjust the expected exception type and the magic/header offsets to match reality. If `_HAVE_NATIVE_LIB` is imported at module top in the test file, reuse that import rather than re-importing. Do not duplicate a branch already covered by an existing test in the file.

- [ ] **Step 7: Run the codec tests + coverage**

Run: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest tests/test_m94z_v4_dispatch.py -q` → all pass.
Then: `... .venv/bin/pytest -q --cov=src/ttio --cov-report=term-missing tests/test_m94z_v4_dispatch.py` and confirm `fqzcomp_nx16_z.py` coverage is now high (dead code gone). Note: a focused run won't reflect the full-suite gate — the gate is checked in final verification.

- [ ] **Step 8: Commit**

```bash
git add python/src/ttio/codecs/fqzcomp_nx16_z.py python/tests/test_m94z_v4_dispatch.py
git rm python/tests/fixtures/codecs/m94z_a.bin python/tests/fixtures/codecs/m94z_b.bin python/tests/fixtures/codecs/m94z_c.bin python/tests/fixtures/codecs/m94z_d.bin python/tests/fixtures/codecs/m94z_f.bin python/tests/fixtures/codecs/m94z_g.bin python/tests/fixtures/codecs/m94z_h.bin
git commit -m "refactor(python): remove dead fqzcomp V1/V2/V3 code; test live V4 path"
```

---

## Task 2: Java — delete dead code + dead tests + orphaned fixtures + live tests

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`
- Modify: `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZUnitTest.java`
- Possibly modify: `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4DispatchTest.java`
- Delete: `java/src/test/resources/ttio/codecs/m94z_{a,b,c,d,f,g,h}.bin`

**Context:** Live API: `encode(byte[] qualities, int[] readLengths, int[] revcompFlags)` (+ overloads with `EncodeOptions`/`ContextParams`), `decode(byte[], int[] revcompFlags) -> DecodeResult`. Live `encode` → `encodeV4Internal`; live `decode` → `decodeV4Internal`; `decode` of version 1/2/3 → `throw IllegalStateException(...)` (KEEP). The dead methods have zero live callers. JaCoCo BUNDLE LINE gate ≥0.84 (currently ~0.8498) — deleting dead code AND its tests together is net-neutral-to-positive; run FULL `mvn verify`.

- [ ] **Step 1: Read the class + its tests; confirm the call graph**

Read `FqzcompNx16Z.java`, `FqzcompNx16ZUnitTest.java`, `FqzcompNx16ZV4DispatchTest.java`. Confirm `encode`/`decode` only reach `encodeV4Internal`/`decodeV4Internal` and the v1/2/3 throw.

- [ ] **Step 2: Delete the dead methods/types in `FqzcompNx16Z.java`**

DELETE: `encodeV2Native`, `decodeV2`, `decodeV2PureJava`, `decodeV2ViaNativeStreaming` (+ its resolver lambda), `decodeV2ForceNativeStreamingForTest`, `preferNativeStreamingDecode` (if only used by the V2 path), `buildContextSeq`, `serializeFreqTables`, `deserializeFreqTables`, `packCodecHeader`, `unpackCodecHeader`, `packCodecHeaderV2`, `unpackCodecHeaderV2`, `normaliseToTotal`, `cumulative`, `m94zContext`, `positionBucketPbits`, `packContextParams`, `unpackContextParams`, `encodeReadLengths`, `decodeReadLengths`, and the `ContextParams` nested type (if unused after the above). Remove constants only used by deleted code (`T`, `T_BITS`, `T_MASK`, `DEFAULT_QBITS/PBITS/DBITS/SLOC`, `CONTEXT_PARAMS_SIZE`, `VERSION_V2_NATIVE` ONLY if `decode`'s rejection no longer references it — note `decode` checks `version == VERSION_V2_NATIVE` to throw, so KEEP `VERSION_V2_NATIVE` and `VERSION` if the rejection uses them).

KEEP: `encode` overloads, `decode`, `EncodeOptions`, `DecodeResult`, `encodeV4Internal`, `decodeV4Internal`, `getBackendName`, `MAGIC`, `VERSION`, `VERSION_V4_FQZCOMP`, `VERSION_V2_NATIVE` (referenced by the rejection branch), and the v1/2/3 `throw` in `decode`.

After deleting, grep the file for each removed name to confirm no dangling references; if `decode`'s rejection references a now-deleted constant, keep that constant.

- [ ] **Step 3: Remove the dead tests + fixtures in `FqzcompNx16ZUnitTest.java`**

DELETE the test methods that exercised removed helpers: `positionBucketPbitsBasics`, `contextBitPackBasics`, `contextParamsRoundTrip`, `readLengthsRoundTrip`, `readLengthsRoundTripEmpty`, and the dead `fixtureA..H` builder methods (and any `PyRandom` import if it becomes unused). KEEP `constantsMatchSpec`, `magicIsM94Z`, the JNI-gated V4 round-trips, and `unpackRejectsBadMagic` ONLY if it tests the live `decode` (if it tested the deleted `unpackCodecHeader`, remove it). Verify each kept test still compiles against the trimmed class.

- [ ] **Step 4: Delete orphaned v1 fixtures**

Confirm unreferenced: `wsl -d Ubuntu -- bash -c "cd ~/TTI-O && grep -rn 'm94z_a\|m94z_b\|m94z_c\|m94z_d\|m94z_f\|m94z_g\|m94z_h' java/src --include=*.java"` (expect none). Then `git rm java/src/test/resources/ttio/codecs/m94z_{a,b,c,d,f,g,h}.bin` (leave `fqzcomp_nx16_*.bin`).

- [ ] **Step 5: Add live V4 edge/error tests**

Append to `FqzcompNx16ZV4DispatchTest.java` (match its JNI gating `@EnabledIf("isNativeAvailable")` + house style — read it first). Add branches not already covered:

```java
@Test
@DisplayName("V4: decode rejects a legacy (v1/2/3) version byte")
void v4DecodeRejectsLegacyVersion() {
    org.junit.jupiter.api.Assumptions.assumeTrue(isNativeAvailable());
    byte[] q = "IIIIIIII".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
    byte[] enc = FqzcompNx16Z.encode(q, new int[]{8}, new int[]{0});
    enc[4] = 2; // tamper version → legacy V2
    assertThrows(IllegalStateException.class,
        () -> FqzcompNx16Z.decode(enc, new int[]{0}));
}

@Test
@DisplayName("V4: encode rejects readLengths/revcompFlags length mismatch")
void v4EncodeRejectsRevcompMismatch() {
    org.junit.jupiter.api.Assumptions.assumeTrue(isNativeAvailable());
    byte[] q = "IIIIIIII".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
    assertThrows(IllegalArgumentException.class,
        () -> FqzcompNx16Z.encode(q, new int[]{4, 4}, new int[]{0})); // 1 flag, 2 reads
}

@Test
@DisplayName("V4: encode rejects sum(readLengths) != qualities.length")
void v4EncodeRejectsSumMismatch() {
    org.junit.jupiter.api.Assumptions.assumeTrue(isNativeAvailable());
    byte[] q = "III".getBytes(java.nio.charset.StandardCharsets.US_ASCII);
    assertThrows(IllegalArgumentException.class,
        () -> FqzcompNx16Z.encode(q, new int[]{2}, new int[]{0}));
}

@Test
@DisplayName("V4: decode rejects bad magic")
void v4DecodeRejectsBadMagic() {
    org.junit.jupiter.api.Assumptions.assumeTrue(isNativeAvailable());
    byte[] bad = new byte[32];
    bad[0] = 'X';
    assertThrows(IllegalArgumentException.class,
        () -> FqzcompNx16Z.decode(bad, new int[]{0}));
}
```

Verify the exact exception types against the kept `encode`/`decode` source (the explorer noted `IllegalArgumentException` for validation, `IllegalStateException` for v1/2/3 rejection, and a bad-magic check in `decode`). Adjust assertion exception classes / argument shapes to match. Skip any branch already covered in the file (e.g. `v4DecodeRejectsTamperedVersionByte` may already exist — don't duplicate).

- [ ] **Step 6: Compile + run codec tests, then FULL verify**

Run: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B test -Dtest='FqzcompNx16Z*'` → all pass, no compile errors.
Then FULL: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify` → BUILD SUCCESS with JaCoCo gate met. Check `target/site/jacoco/jacoco.csv` for `FqzcompNx16Z` — LINE coverage should be much higher (dead code removed).

- [ ] **Step 7: Commit**

```bash
git add java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZUnitTest.java java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4DispatchTest.java
git rm java/src/test/resources/ttio/codecs/m94z_a.bin java/src/test/resources/ttio/codecs/m94z_b.bin java/src/test/resources/ttio/codecs/m94z_c.bin java/src/test/resources/ttio/codecs/m94z_d.bin java/src/test/resources/ttio/codecs/m94z_f.bin java/src/test/resources/ttio/codecs/m94z_g.bin java/src/test/resources/ttio/codecs/m94z_h.bin
git commit -m "refactor(java): remove dead fqzcomp V1/V2 code + tests; test live V4 path"
```

---

## Task 3: ObjC — delete dead z_* statics + fix stale comments + live tests

**Files:**
- Modify: `objc/Source/Codecs/TTIOFqzcompNx16Z.m`
- Modify: `objc/Source/Codecs/TTIOFqzcompNx16Z.h` (stale doc only)
- Modify: `objc/Tests/TestM94ZV4Dispatch.m`

**Context:** Live: `encodeWithQualities:readLengths:revcompFlags:error:` (+ `:options:error:`) → `encodeV4WithQualities:` under `#if TTIO_HAS_NATIVE_RANS` (else error); `decodeData:revcompFlags:error:` → `decodeV4Data:` for version 4, and version 1/2/3 → error 203 (KEEP). The dead `z_*` V1/V2 statics are unreachable. Tests: `TestM94ZV4Dispatch.m`, `TestM94ZV4ByteExact.m`, `TestM94ZFqzcompPerf.m` (V4-only). Assertion style: inline `PASS(cond, "msg")`.

- [ ] **Step 1: Read `.m`/`.h` + test; confirm the live dispatch**

Read `TTIOFqzcompNx16Z.m`, `.h`, `TestM94ZV4Dispatch.m`. Confirm `encode`/`decode` reach only V4 + the v1/2/3 error.

- [ ] **Step 2: Delete the dead `z_*` statics in `.m`**

DELETE: `z_encode_full`, `z_decode_full`, `z_encode_v2_native`, `z_decode_v2`, `z_decode_v2_via_native_streaming`, `z_streaming_resolver_cb`, `z_normalise_to_total`, `z_build_context_seq`, `z_serialize_freq_tables`, `z_deserialize_freq_tables`, `z_encode_read_lengths`, `z_decode_read_lengths`, `z_context`, `z_pos_bucket`, and any file-static constants/structs used only by them. KEEP the V4 path (`encodeV4WithQualities:`, `decodeV4Data:`), the public `encode`/`decode` that route to V4, the v1/2/3 rejection (error 203), `backendName`. After deleting, grep the `.m` for each removed name to confirm no remaining references.

- [ ] **Step 3: Fix stale comments**

Correct the comments that still claim V1 fallback/auto-downgrade: `.m` near lines ~24-25 and ~943-945 ("silently downgraded to V1"), the `.h` doc on `…:options:error:`, and `TestM94ZV4Dispatch.m:11-12`. Make them state the real behavior: encode emits V4 (requires native lib, else errors); decode accepts V4 only and rejects v1/2/3. If `…:options:error:` still takes V1/V2-selection params that are now no-ops, document them as accepted-and-ignored (keep the signature for ABI parity).

- [ ] **Step 4: Build + run to confirm green**

Run: `cd ~/TTI-O/objc && ./build.sh check` → "all tests passed", no FAIL (confirms the live path still compiles/links and the dead-code removal didn't break anything).

- [ ] **Step 5: Add live V4 edge/error tests**

Extend `objc/Tests/TestM94ZV4Dispatch.m` (inline `PASS` style — read it first) with branches not already covered: decode of a tampered legacy version byte → error; encode revcomp/read-length mismatch → error; decode bad-magic/truncated → error. Example shape (ADAPT to the actual method signatures + `NSError**` patterns you read in Step 1):

```objc
        // V4: decode rejects a tampered legacy (v1/2/3) version byte.
        {
            NSData *q = [@"IIIIIIII" dataUsingEncoding:NSUTF8StringEncoding];
            NSError *err = nil;
            NSData *enc = [TTIOFqzcompNx16Z encodeV4WithQualities:q
                              readLengths:@[@8] revcompFlags:@[@0] error:&err];
            if (enc) {
                NSMutableData *t = [enc mutableCopy];
                ((uint8_t *)t.mutableBytes)[4] = 2;  // tamper → legacy V2
                NSError *derr = nil;
                NSData *dec = [TTIOFqzcompNx16Z decodeData:t revcompFlags:@[@0] error:&derr];
                PASS(dec == nil && derr != nil,
                     "M94Z V4: decode rejects tampered legacy version byte");
            }
        }
```

Verify the real method names/signatures (`encodeV4WithQualities:...` vs the public `encodeWithQualities:...`, and the `error:` out-param pattern) and the rejection error domain/code (203) against Step-1 reading; adjust. Don't duplicate the existing version-rewrite rejection test if `TestM94ZV4Dispatch.m` already has one — add only the uncovered branches (mismatch validation, bad magic/truncated).

- [ ] **Step 6: Build + run**

Run: `cd ~/TTI-O/objc && ./build.sh check` → all PASS, no FAIL. Optionally `./build.sh --coverage check` if `llvm-cov` present (confirm `TTIOFqzcompNx16Z.m` coverage rose).

- [ ] **Step 7: Commit**

```bash
git add objc/Source/Codecs/TTIOFqzcompNx16Z.m objc/Source/Codecs/TTIOFqzcompNx16Z.h objc/Tests/TestM94ZV4Dispatch.m
git commit -m "refactor(objc): remove dead fqzcomp V1/V2 code; fix stale docs; test live V4 path"
```

---

## Final verification (after all three tasks)
- [ ] Python: `cd ~/TTI-O/python && TTIO_RANS_LIB_PATH=$HOME/TTI-O/native/_build/libttio_rans.so .venv/bin/pytest -q --cov=src/ttio --cov-fail-under=84` → passes, ≥84%. (Run WITHOUT a concurrent `mvn` build to avoid the JDK-classfile race that makes `tests/validation` flaky — see the known env gotcha; the gated jobs are what matter.)
- [ ] Java: `cd ~/TTI-O/java && JAVA_HOME=~/jdk25 mvn -o -B verify` → BUILD SUCCESS, JaCoCo gate met.
- [ ] ObjC: `cd ~/TTI-O/objc && ./build.sh check` → no FAIL.
- [ ] Push (Windows git), open PR vs `main`, watch CI (gated jobs + "Cross-language parity"), merge once green, sync main.
- [ ] Update memory (`project_tti_o_coverage_improvement`): R3 done, fqzcomp dead code removed across 3 SDKs.
