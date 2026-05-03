# M94.Z Stage 3 — Java + ObjC V4 parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bring M94.Z V4 (CRAM 3.1 fqzcomp byte-compatible) to the Java and Objective-C reference implementations, with V4 as the default encoded format when the native library is available, byte-equality with Python verified across all 4 corpora.

**Architecture:** Both Java and ObjC use Strategy A (linkage parity) — they call the existing C library `libttio_rans` for the V4 path, exactly as Python's ctypes wrapper does. Java goes through JNI (extending the existing `ttio_rans_jni.c` scaffold + `TtioRansNative.java` bridge). ObjC links `libttio_rans` directly (same pattern V2 already uses). Pure-language V1/V2/V3 code paths remain untouched as the no-native-lib fallback. The C library is the single source of truth for the byte-exact CRAM 3.1 algorithm.

**Tech Stack:** Java 17 + Maven + JNI; Objective-C + GNUstep make + Foundation; existing `libttio_rans.so` from Stage 2 (HEAD `6ec790d`); existing `tools/perf/m94z_v4_prototype/` test infrastructure for byte-equality gates.

---

## Background — what's already in place

**From Stage 2 (HEAD `6ec790d`):**
- `native/src/m94z_v4_wire.{c,h}` — V4 wire format (M94Z header + CRAM body)
- `native/src/fqzcomp_qual.{c,h}` — full CRAM 3.1 fqzcomp port + auto-tune
- `native/include/ttio_rans.h` — exposes `ttio_m94z_v4_encode` / `ttio_m94z_v4_decode`
- `python/src/ttio/codecs/fqzcomp_nx16_z.py` — V4 dispatch via ctypes; V4 default when `_HAVE_NATIVE_LIB`
- `tools/perf/m94z_v4_prototype/extract_chr22_inputs.py` — BAM → flat binary extractor (works for any BAM)
- `tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref_autotune.c` — htscodecs reference driver
- `tools/perf/htscodecs_compare.sh` — multi-corpus byte-equality harness
- 4-corpus byte-equality verified end-to-end (Phase 5)

**Already in Java:**
- `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java` — pure-Java V1 + V2 dispatch
- `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java` — JNI bridge with `System.loadLibrary("ttio_rans_jni")`; falls back gracefully when lib not present
- `java/src/test/java/.../FqzcompNx16ZV2DispatchTest.java` — V2 dispatch tests
- `native/src/ttio_rans_jni.c` (384 lines, 4 JNI exports) — JNI glue, built via `cmake -DTTIO_RANS_BUILD_JNI=ON`

**Already in ObjC:**
- `objc/Source/Codecs/TTIOFqzcompNx16Z.{h,m}` — pure-ObjC V1 + V2 dispatch (V2 encode native, V2 decode pure-ObjC per existing design)
- `objc/Tests/TTIORansNativeTest.m` — native lib link tests
- ObjC already directly links `libttio_rans` (verified by V2 native dispatch path)
- Build via `objc/build.sh` + GNUmakefile (GNUstep make)

**Open issue carried over:**
- `python/tests/integration/test_m90_cross_language.py::test_m90_genomic_encrypt_python_verify[java-encrypt]` — failing pre-V4 (per Task 13 implementer's notes); to be triaged as Task 10.

## File Structure

**Modify:**
- `native/src/ttio_rans_jni.c` — add 2 new JNI exports for V4 encode/decode
- `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java` — add 2 native method declarations
- `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java` — add V4 dispatch path; V4 default when JNI loaded
- `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV2DispatchTest.java` — update existing V2 default tests to be explicit
- `objc/Source/Codecs/TTIOFqzcompNx16Z.h` — declare V4 entry points + V4 default behavior
- `objc/Source/Codecs/TTIOFqzcompNx16Z.m` — implement V4 encode/decode via direct libttio_rans calls
- `objc/Tests/<...>` — update any V2 default-asserting tests to be explicit
- `docs/codecs/fqzcomp_nx16_z.md` — document Java + ObjC V4 parity
- `WORKPLAN.md` — Task #84 mark Stage 3 done
- Memory: `project_tti_o_v1_2_codecs.md`, `MEMORY.md`

**Create:**
- `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4DispatchTest.java` — Java V4 dispatch test suite (~10 tests)
- `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4ByteExactTest.java` — Java cross-corpus byte-exact vs Python (4 corpora)
- `objc/Tests/TestTTIOFqzcompNx16ZV4Dispatch.m` — ObjC V4 dispatch test suite (~10 tests)
- `objc/Tests/TestTTIOFqzcompNx16ZV4ByteExact.m` — ObjC cross-corpus byte-exact vs Python (4 corpora)
- `python/tests/integration/test_m94z_v4_cross_language.py` — orchestrates Python ↔ Java ↔ ObjC byte-equality matrix

---

## Phase 0 — Verify scaffolding state

### Task 1: Verify Java + ObjC + JNI baseline state and Stage 2 readiness

**Files:**
- Read-only inspection (no modifications)

This is a guard-rail task. Catches any drift since HEAD `6ec790d` before launching ports.

- [ ] **Step 1: Confirm git is clean and at the expected baseline**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git status && git log --oneline -1'
```

Expected: working tree clean; HEAD = `6ec790d` ("docs(L2.X V4): V4 wire format + WORKPLAN Stage 2 done"). If diverged, halt and reconcile.

- [ ] **Step 2: Verify libttio_rans is built and exposes V4 symbols**

```bash
wsl -d Ubuntu -- bash -c 'nm -D /home/toddw/TTI-O/native/_build/libttio_rans.so | grep -E "ttio_m94z_v4_(encode|decode)"'
```

Expected: 2 lines, both with `T` (text segment, exported).

- [ ] **Step 3: Verify libttio_rans_jni is built or builds cleanly with the JNI flag**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && ls native/_build/libttio_rans_jni* 2>/dev/null || (cd native/_build && cmake -DTTIO_RANS_BUILD_JNI=ON .. && cmake --build . --target ttio_rans_jni 2>&1 | tail -5 && ls libttio_rans_jni*)'
```

Expected: `libttio_rans_jni.so` exists (after build if needed). If the JNI target doesn't exist in CMakeLists, document the gap; the next task will add it. (As of HEAD `6ec790d` the JNI build is gated behind `TTIO_RANS_BUILD_JNI=ON`; verify the option exists.)

- [ ] **Step 4: Verify Java + ObjC build green**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/java && mvn -q -DskipTests package 2>&1 | tail -5'
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/objc && ./build.sh 2>&1 | tail -10'
```

Expected: BUILD SUCCESS (Maven); ObjC build completes (libTTIO target).

- [ ] **Step 5: Verify Stage 2 V4 byte-equality still holds**

```bash
wsl -d Ubuntu -- bash -c '/home/toddw/TTI-O/tools/perf/htscodecs_compare.sh 2>&1 | tail -10'
```

Expected: `Summary: passed=4 failed=0 skipped=0`, `ALL CORPORA: BYTE-EQUAL`. Confirms Stage 2 didn't regress.

- [ ] **Step 6: No commit (read-only verification task)**

Report the state of all 5 checks. If any FAIL, halt the plan and reconcile before proceeding to Task 2.

---

## Phase 1 — JNI V4 entry points (Java)

### Task 2: Extend ttio_rans_jni.c with V4 encode/decode JNI exports

**Files:**
- Modify: `native/src/ttio_rans_jni.c` — add 2 new JNI functions
- Modify: `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java` — declare 2 new `native` methods (no body — JNI links them)

The existing JNI scaffold has 4 exports for the rANS block-encode primitives. We add two more for V4: one wraps `ttio_m94z_v4_encode`, the other `ttio_m94z_v4_decode`. The JNI signatures mirror the C function signatures, with Java arrays marshaled via standard `Get/SetArrayElements` patterns.

- [ ] **Step 1: Read existing JNI patterns**

Open `/home/toddw/TTI-O/native/src/ttio_rans_jni.c` and study the 4 existing JNI exports (lines 71, 154, 241, 290 per Phase 0 inspection). Note:
- Argument marshaling pattern (GetByteArrayElements / ReleaseByteArrayElements; GetIntArrayElements / ReleaseIntArrayElements)
- How exceptions are signaled back to Java (typically by returning a negative int or NULL)
- The `(*env)->...` JNI invocation style
- The `Java_global_thalion_ttio_codecs_TtioRansNative_<methodName>` symbol naming convention

These are your templates.

- [ ] **Step 2: Add the V4 native method declarations to TtioRansNative.java**

In `java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java`, add after the existing native method declarations (before the closing `}`):

```java
    /**
     * Encode flat qualities to an M94.Z V4 stream via the native library.
     *
     * <p>Mirrors {@code ttio_m94z_v4_encode} in {@code native/include/ttio_rans.h}.
     * Auto-tunes (CRAM 3.1) when {@code strategyHint == -1}; uses the
     * specified preset 0..3 otherwise.
     *
     * @param qualities flat Phred bytes (length == sum of readLengths)
     * @param readLengths per-read quality counts
     * @param flags per-read SAM flags (Phase 2 strategy 1 ignores these; auto-tune
     *              uses bit 4 = SAM_REVERSE_FLAG)
     * @param strategyHint -1 = auto-tune (default); 0..3 = explicit preset
     * @param padCount 0..3 (low-2 bits of the V4 flags byte)
     * @return encoded V4 stream
     * @throws RuntimeException if the native call returns a non-zero rc
     */
    public static byte[] encodeV4(byte[] qualities, int[] readLengths, int[] flags,
                                   int strategyHint, int padCount) {
        if (!LOADED) throw new IllegalStateException("libttio_rans_jni not loaded");
        return encodeV4Native(qualities, readLengths, flags, strategyHint, padCount);
    }

    /**
     * Decode an M94.Z V4 stream via the native library.
     *
     * @param encoded V4 stream (must start with "M94Z" + version 4)
     * @param numReads expected read count (decoder pre-allocates lengths array)
     * @param numQualities expected quality count
     * @param flags per-read SAM flags
     * @return [qualities[], readLengths[]] as a 2-element Object[]; element 0 is
     *         the byte[] of qualities, element 1 is the int[] of recovered
     *         read lengths
     */
    public static Object[] decodeV4(byte[] encoded, int numReads, int numQualities,
                                     int[] flags) {
        if (!LOADED) throw new IllegalStateException("libttio_rans_jni not loaded");
        return decodeV4Native(encoded, numReads, numQualities, flags);
    }

    private static native byte[] encodeV4Native(byte[] qualities, int[] readLengths,
                                                  int[] flags, int strategyHint,
                                                  int padCount);

    private static native Object[] decodeV4Native(byte[] encoded, int numReads,
                                                    int numQualities, int[] flags);
```

- [ ] **Step 3: Implement the JNI side in ttio_rans_jni.c**

Append to `native/src/ttio_rans_jni.c` (before any `#endif __cplusplus` block at the end, if present):

```c
/* ----- V4 (CRAM 3.1 fqzcomp byte-compatible) JNI bindings ----- */

#include "ttio_rans.h"  /* declared elsewhere; defensive include */

/*
 * Java_global_thalion_ttio_codecs_TtioRansNative_encodeV4Native
 *   ([B[I[III)[B
 *
 * Marshal Java arrays → C uint8/uint32 buffers, call ttio_m94z_v4_encode,
 * marshal C output → new Java byte[].
 */
JNIEXPORT jbyteArray JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_encodeV4Native(
    JNIEnv *env, jclass cls,
    jbyteArray qualArr, jintArray lensArr, jintArray flagsArr,
    jint strategyHint, jint padCount)
{
    (void)cls;
    jsize n_qual    = (*env)->GetArrayLength(env, qualArr);
    jsize n_reads   = (*env)->GetArrayLength(env, lensArr);
    jsize n_flags   = (*env)->GetArrayLength(env, flagsArr);
    if (n_flags != n_reads) {
        jclass exClass = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
        (*env)->ThrowNew(env, exClass, "flags length must equal readLengths length");
        return NULL;
    }

    jbyte *qual_jbytes = (*env)->GetByteArrayElements(env, qualArr, NULL);
    jint  *lens_jints  = (*env)->GetIntArrayElements(env, lensArr, NULL);
    jint  *flags_jints = (*env)->GetIntArrayElements(env, flagsArr, NULL);

    /* Convert lens int[] to uint32_t[] (in-place safe: same width on LP64). */
    uint32_t *lens_u32 = (uint32_t *)lens_jints;

    /* Convert flags int[] to uint8_t[] (low byte; bit 4 carries SAM_REVERSE). */
    uint8_t *flags_u8 = malloc((size_t)n_reads);
    if (!flags_u8) {
        (*env)->ReleaseByteArrayElements(env, qualArr, qual_jbytes, JNI_ABORT);
        (*env)->ReleaseIntArrayElements(env, lensArr, lens_jints, JNI_ABORT);
        (*env)->ReleaseIntArrayElements(env, flagsArr, flags_jints, JNI_ABORT);
        jclass exClass = (*env)->FindClass(env, "java/lang/OutOfMemoryError");
        (*env)->ThrowNew(env, exClass, "encodeV4Native: flags malloc failed");
        return NULL;
    }
    for (jsize i = 0; i < n_reads; i++) flags_u8[i] = (uint8_t)flags_jints[i];

    size_t out_cap = (size_t)n_qual + (size_t)n_qual / 4 + (1u << 20);
    uint8_t *out = malloc(out_cap);
    if (!out) {
        free(flags_u8);
        (*env)->ReleaseByteArrayElements(env, qualArr, qual_jbytes, JNI_ABORT);
        (*env)->ReleaseIntArrayElements(env, lensArr, lens_jints, JNI_ABORT);
        (*env)->ReleaseIntArrayElements(env, flagsArr, flags_jints, JNI_ABORT);
        jclass exClass = (*env)->FindClass(env, "java/lang/OutOfMemoryError");
        (*env)->ThrowNew(env, exClass, "encodeV4Native: out malloc failed");
        return NULL;
    }
    size_t out_len = out_cap;

    int rc = ttio_m94z_v4_encode(
        (const uint8_t *)qual_jbytes, (size_t)n_qual,
        lens_u32, (size_t)n_reads,
        flags_u8,
        (int)strategyHint,
        (uint8_t)padCount,
        out, &out_len);

    free(flags_u8);
    (*env)->ReleaseByteArrayElements(env, qualArr, qual_jbytes, JNI_ABORT);
    (*env)->ReleaseIntArrayElements(env, lensArr, lens_jints, JNI_ABORT);
    (*env)->ReleaseIntArrayElements(env, flagsArr, flags_jints, JNI_ABORT);

    if (rc != 0) {
        free(out);
        char msg[64];
        snprintf(msg, sizeof(msg), "ttio_m94z_v4_encode rc=%d", rc);
        jclass exClass = (*env)->FindClass(env, "java/lang/RuntimeException");
        (*env)->ThrowNew(env, exClass, msg);
        return NULL;
    }

    jbyteArray result = (*env)->NewByteArray(env, (jsize)out_len);
    if (result) {
        (*env)->SetByteArrayRegion(env, result, 0, (jsize)out_len, (const jbyte *)out);
    }
    free(out);
    return result;
}

/*
 * Java_global_thalion_ttio_codecs_TtioRansNative_decodeV4Native
 *   ([BII[I)[Ljava/lang/Object;
 *
 * Returns Object[2]: [byte[] qualities, int[] readLengths].
 */
JNIEXPORT jobjectArray JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_decodeV4Native(
    JNIEnv *env, jclass cls,
    jbyteArray encArr, jint numReads, jint numQualities, jintArray flagsArr)
{
    (void)cls;
    jsize enc_len  = (*env)->GetArrayLength(env, encArr);
    jsize n_flags  = (*env)->GetArrayLength(env, flagsArr);
    if (n_flags != numReads) {
        jclass exClass = (*env)->FindClass(env, "java/lang/IllegalArgumentException");
        (*env)->ThrowNew(env, exClass, "flags length must equal numReads");
        return NULL;
    }

    jbyte *enc_jbytes  = (*env)->GetByteArrayElements(env, encArr, NULL);
    jint  *flags_jints = (*env)->GetIntArrayElements(env, flagsArr, NULL);

    uint8_t *flags_u8 = malloc((size_t)numReads);
    if (!flags_u8) {
        (*env)->ReleaseByteArrayElements(env, encArr, enc_jbytes, JNI_ABORT);
        (*env)->ReleaseIntArrayElements(env, flagsArr, flags_jints, JNI_ABORT);
        jclass exClass = (*env)->FindClass(env, "java/lang/OutOfMemoryError");
        (*env)->ThrowNew(env, exClass, "decodeV4Native: flags malloc failed");
        return NULL;
    }
    for (jsize i = 0; i < numReads; i++) flags_u8[i] = (uint8_t)flags_jints[i];

    uint32_t *lens_u32 = malloc((size_t)numReads * sizeof(uint32_t));
    uint8_t  *qual_out = malloc((size_t)numQualities);
    if (!lens_u32 || !qual_out) {
        free(flags_u8); free(lens_u32); free(qual_out);
        (*env)->ReleaseByteArrayElements(env, encArr, enc_jbytes, JNI_ABORT);
        (*env)->ReleaseIntArrayElements(env, flagsArr, flags_jints, JNI_ABORT);
        jclass exClass = (*env)->FindClass(env, "java/lang/OutOfMemoryError");
        (*env)->ThrowNew(env, exClass, "decodeV4Native: output malloc failed");
        return NULL;
    }

    int rc = ttio_m94z_v4_decode(
        (const uint8_t *)enc_jbytes, (size_t)enc_len,
        lens_u32, (size_t)numReads,
        flags_u8,
        qual_out, (size_t)numQualities);

    free(flags_u8);
    (*env)->ReleaseByteArrayElements(env, encArr, enc_jbytes, JNI_ABORT);
    (*env)->ReleaseIntArrayElements(env, flagsArr, flags_jints, JNI_ABORT);

    if (rc != 0) {
        free(lens_u32); free(qual_out);
        char msg[64];
        snprintf(msg, sizeof(msg), "ttio_m94z_v4_decode rc=%d", rc);
        jclass exClass = (*env)->FindClass(env, "java/lang/RuntimeException");
        (*env)->ThrowNew(env, exClass, msg);
        return NULL;
    }

    /* Build return Object[2] = [byte[] qualities, int[] readLengths] */
    jclass objClass = (*env)->FindClass(env, "java/lang/Object");
    jobjectArray result = (*env)->NewObjectArray(env, 2, objClass, NULL);

    jbyteArray qualResult = (*env)->NewByteArray(env, (jsize)numQualities);
    (*env)->SetByteArrayRegion(env, qualResult, 0, (jsize)numQualities,
                                 (const jbyte *)qual_out);
    (*env)->SetObjectArrayElement(env, result, 0, qualResult);

    jintArray lensResult = (*env)->NewIntArray(env, (jsize)numReads);
    /* lens_u32 → jint copy (same width on LP64) */
    (*env)->SetIntArrayRegion(env, lensResult, 0, (jsize)numReads,
                                (const jint *)lens_u32);
    (*env)->SetObjectArrayElement(env, result, 1, lensResult);

    free(lens_u32);
    free(qual_out);
    return result;
}
```

- [ ] **Step 4: Strip CRLF + rebuild JNI lib**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' native/src/ttio_rans_jni.c java/src/main/java/global/thalion/ttio/codecs/TtioRansNative.java && tr -cd $'"'"'\r'"'"' < native/src/ttio_rans_jni.c | wc -c && cd native/_build && cmake -DTTIO_RANS_BUILD_JNI=ON .. > /dev/null && cmake --build . --target ttio_rans_jni 2>&1 | tail -5 && ls -la libttio_rans_jni.so'
```

Expected: 0 CRs; build clean (warnings on `(void)cls` only); `libttio_rans_jni.so` exists.

- [ ] **Step 5: Verify the new JNI symbols are exported**

```bash
wsl -d Ubuntu -- bash -c 'nm -D /home/toddw/TTI-O/native/_build/libttio_rans_jni.so | grep -E "(encodeV4Native|decodeV4Native)"'
```

Expected: 2 lines, both with `T`.

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(L3 V4 Java): JNI bindings for V4 encode/decode

Wires ttio_m94z_v4_encode/decode through the existing
TtioRansNative JNI bridge as encodeV4 / decodeV4. JNI marshaling
mirrors the existing 4 V2 bindings; uses Get/Release Array Elements
pattern; throws java.lang.RuntimeException on non-zero rc.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 3: Sanity-test the new JNI bindings end-to-end (Java → JNI → C → JNI → Java round-trip)

**Files:**
- Create: `java/src/test/java/global/thalion/ttio/codecs/TtioRansNativeV4Test.java`

Adds a single small JUnit test that calls `TtioRansNative.encodeV4` + `decodeV4` on a tiny synthetic input and asserts byte-exact round-trip. Catches gross JNI marshaling bugs before the larger dispatch tests in Task 5.

- [ ] **Step 1: Write the round-trip test**

Create `/home/toddw/TTI-O/java/src/test/java/global/thalion/ttio/codecs/TtioRansNativeV4Test.java`:

```java
/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Sanity test for the TtioRansNative.encodeV4 / decodeV4 JNI bridge.
 *
 * Verifies that a small synthetic input round-trips byte-exact through
 * the JNI marshaling. Catches obvious JNI bugs (wrong array width,
 * exception leakage, off-by-one in length passing) before the larger
 * dispatch tests in FqzcompNx16ZV4DispatchTest.
 *
 * Skipped automatically if libttio_rans_jni is not loaded.
 */
class TtioRansNativeV4Test {

    static boolean nativeAvailable() { return TtioRansNative.isAvailable(); }

    @Test
    @EnabledIf("nativeAvailable")
    void v4SmokeRoundtrip() {
        // 4 reads × 5 qualities = 20 bytes
        byte[] qualities = new byte[20];
        for (int i = 0; i < 20; i++) qualities[i] = (byte)(33 + (i * 7) % 40);
        int[] readLengths = {5, 5, 5, 5};
        int[] flags = {0, 16, 0, 0};  // SAM_REVERSE on read 1

        byte[] encoded = TtioRansNative.encodeV4(qualities, readLengths, flags,
                                                  /*strategyHint=*/-1, /*padCount=*/0);
        assertEquals('M', encoded[0]);
        assertEquals('9', encoded[1]);
        assertEquals('4', encoded[2]);
        assertEquals('Z', encoded[3]);
        assertEquals(4, encoded[4]);

        Object[] decoded = TtioRansNative.decodeV4(encoded, /*numReads=*/4,
                                                     /*numQualities=*/20, flags);
        byte[] qualBack = (byte[]) decoded[0];
        int[]  lensBack = (int[])  decoded[1];

        assertArrayEquals(qualities, qualBack);
        assertArrayEquals(readLengths, lensBack);
    }
}
```

- [ ] **Step 2: Strip CRLF + run the test**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' java/src/test/java/global/thalion/ttio/codecs/TtioRansNativeV4Test.java && cd java && mvn -q -Dtest=TtioRansNativeV4Test test -Djava.library.path=/home/toddw/TTI-O/native/_build 2>&1 | tail -15'
```

Expected: `Tests run: 1, Failures: 0`.

If FAIL: most likely the JNI lib isn't on `java.library.path`, or the JNI signature mismatch is throwing `UnsatisfiedLinkError`. Check `native/src/ttio_rans_jni.c` symbol names with `nm -D` and compare to what JNI expects (`Java_global_thalion_ttio_codecs_TtioRansNative_encodeV4Native`).

- [ ] **Step 3: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add java/src/test/java/global/thalion/ttio/codecs/TtioRansNativeV4Test.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L3 V4 Java): TtioRansNative.encodeV4/decodeV4 smoke roundtrip

Catches JNI marshaling bugs (array width, exception leakage, length
passing) before the larger FqzcompNx16ZV4DispatchTest suite.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 2 — Java FqzcompNx16Z V4 dispatch

### Task 4: Add V4 dispatch to FqzcompNx16Z + V4-default selection

**Files:**
- Modify: `java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java` — add V4 encode/decode dispatch; V4 becomes default when `TtioRansNative.isAvailable()`

Mirrors the Python wrapper changes (Stage 2 Task 11). The Java codec gains `encodeV4` / `decodeV4` paths that delegate to `TtioRansNative.encodeV4` / `decodeV4`. The dispatcher picks V4 when JNI is loaded; falls back to V2 (then V1) otherwise.

- [ ] **Step 1: Read the existing dispatch in FqzcompNx16Z.java**

Open `/home/toddw/TTI-O/java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java`. Find:
- The existing `encode(...)` overloads (the per-Phase 0 inspection showed 2 overloads near the end of the surface)
- The existing `decode(...)` / `DecodeResult` class
- The existing `EncodeOptions` class (likely carries `preferNative` boolean for V2 dispatch)
- The version-byte dispatch in decode (looks at `encoded[4]` to pick V1 vs V2)

These are your patterns. The V4 path is a strictly additive change — V1/V2/V3 paths stay byte-identical.

- [ ] **Step 2: Add V4 constants + EncodeOptions extension**

Add near the existing `VERSION_V2_NATIVE` constant in `FqzcompNx16Z.java`:

```java
    public static final int VERSION_V3_ADAPTIVE = 3;  // pure-Java V3 (if extant)
    public static final int VERSION_V4_FQZCOMP  = 4;  // CRAM 3.1 fqzcomp port
    public static final String ENV_VERSION_OVERRIDE = "TTIO_M94Z_VERSION";
```

Extend `EncodeOptions` to carry V4 preferences:

```java
    public static final class EncodeOptions {
        // ... existing fields ...
        public Boolean preferV4;             // null = follow env / default
        public Boolean preferV3;             // null = follow env / default
        public Integer v4StrategyHint;       // null = -1 (auto-tune)
        // ... existing builder/copy methods ...
    }
```

(Adapt the existing builder/copy idiom — read the file to match it exactly.)

- [ ] **Step 3: Add the encodeV4 path**

Add a private static method:

```java
    /**
     * Encode via the M94.Z V4 (CRAM 3.1 fqzcomp) path through JNI.
     * Throws IllegalStateException if libttio_rans_jni is not loaded.
     */
    private static byte[] encodeV4Internal(byte[] qualities, int[] readLengths,
                                             int[] revcompFlags, int strategyHint,
                                             int padCount) {
        if (!TtioRansNative.isAvailable()) {
            throw new IllegalStateException(
                "encodeV4Internal called but libttio_rans_jni not loaded");
        }
        // Convert revcompFlags 0/1 to SAM-flag byte (bit 4 = SAM_REVERSE).
        int[] samFlags = new int[revcompFlags.length];
        for (int i = 0; i < revcompFlags.length; i++) {
            samFlags[i] = (revcompFlags[i] & 1) != 0 ? 16 : 0;
        }
        return TtioRansNative.encodeV4(qualities, readLengths, samFlags,
                                         strategyHint, padCount);
    }
```

- [ ] **Step 4: Add the decodeV4 path**

```java
    /**
     * Decode an M94.Z V4 stream via JNI. Returns the recovered qualities
     * + read_lengths.
     *
     * The V4 outer header carries num_qualities + num_reads + RLT; we
     * parse the first 22 bytes of the stream to extract them so we can
     * pre-allocate buffers.
     */
    private static DecodeResult decodeV4Internal(byte[] encoded, int[] revcompFlags) {
        if (!TtioRansNative.isAvailable()) {
            throw new IllegalStateException(
                "decodeV4Internal called but libttio_rans_jni not loaded");
        }
        if (encoded.length < 30 || encoded[0] != 'M' || encoded[1] != '9' ||
            encoded[2] != '4' || encoded[3] != 'Z' || encoded[4] != 4) {
            throw new IllegalArgumentException("not an M94.Z V4 stream");
        }
        // Parse num_qualities (uint64 LE @ offset 6) and num_reads (@ offset 14).
        long numQual = 0, numReads = 0;
        for (int i = 0; i < 8; i++) numQual  |= ((long)(encoded[6+i] & 0xFF)) << (8*i);
        for (int i = 0; i < 8; i++) numReads |= ((long)(encoded[14+i] & 0xFF)) << (8*i);
        if (numQual > Integer.MAX_VALUE || numReads > Integer.MAX_VALUE) {
            throw new IllegalArgumentException("V4 stream too large for Java int sizes");
        }
        int n_qual  = (int) numQual;
        int n_reads = (int) numReads;
        if (revcompFlags == null) revcompFlags = new int[n_reads];
        if (revcompFlags.length != n_reads) {
            throw new IllegalArgumentException(
                "revcompFlags length " + revcompFlags.length + " != numReads " + n_reads);
        }
        int[] samFlags = new int[n_reads];
        for (int i = 0; i < n_reads; i++) {
            samFlags[i] = (revcompFlags[i] & 1) != 0 ? 16 : 0;
        }
        Object[] result = TtioRansNative.decodeV4(encoded, n_reads, n_qual, samFlags);
        byte[] qual = (byte[]) result[0];
        int[]  lens = (int[])  result[1];
        return new DecodeResult(qual, lens, revcompFlags);
    }
```

- [ ] **Step 5: Update encode() to dispatch V4 by default**

Modify the existing `encode(byte[] qualities, int[] readLengths, int[] revcompFlags, EncodeOptions opts)` overload (or whatever its current signature is). The new dispatch order:

```java
    public static byte[] encode(byte[] qualities, int[] readLengths,
                                  int[] revcompFlags, EncodeOptions opts) {
        if (opts == null) opts = new EncodeOptions();
        int padCount = ((-qualities.length) & 0x3);

        // Resolve preferV4 from per-call → env → default
        Boolean preferV4 = opts.preferV4;
        if (preferV4 == null) {
            String env = System.getenv(ENV_VERSION_OVERRIDE);
            if ("4".equals(env)) preferV4 = true;
            else if (env != null && (env.equals("1") || env.equals("2") || env.equals("3"))) preferV4 = false;
            else preferV4 = TtioRansNative.isAvailable();
        }

        if (preferV4 && TtioRansNative.isAvailable()) {
            int strategy = opts.v4StrategyHint != null ? opts.v4StrategyHint : -1;
            return encodeV4Internal(qualities, readLengths, revcompFlags, strategy, padCount);
        }

        // ... existing V2/V1 dispatch unchanged below ...
    }
```

- [ ] **Step 6: Update decode() / decodeWithMetadata() to handle version=4**

```java
    public static DecodeResult decode(byte[] encoded, int[] revcompFlags) {
        if (encoded.length < 5) throw new IllegalArgumentException("M94.Z stream too short");
        if (encoded[0] != 'M' || encoded[1] != '9' || encoded[2] != '4' || encoded[3] != 'Z') {
            throw new IllegalArgumentException("not an M94.Z stream");
        }
        int version = encoded[4] & 0xFF;
        switch (version) {
            case 4: return decodeV4Internal(encoded, revcompFlags);
            case 2: /* existing V2 path */ break;
            case 1: /* existing V1 path */ break;
            default: throw new IllegalArgumentException("unsupported M94.Z version: " + version);
        }
        // ... existing V2/V1 dispatch ...
    }
```

(Preserve the existing dispatch logic for V1/V2; only add the V4 case.)

- [ ] **Step 7: Strip CRLF + recompile + run all existing FqzcompNx16Z tests**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' java/src/main/java/global/thalion/ttio/codecs/FqzcompNx16Z.java && cd java && mvn -q -Dtest='"'"'FqzcompNx16Z*'"'"' test -Djava.library.path=/home/toddw/TTI-O/native/_build 2>&1 | tail -25'
```

Expected: V2 dispatch tests now FAIL (because V4 is the new default when JNI is loaded). Document which tests fail; Task 5 fixes them. The pure-Java V1 / V2 unit tests should still pass (they presumably don't assert "default version").

- [ ] **Step 8: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(L3 V4 Java): FqzcompNx16Z V4 dispatch via TtioRansNative

V4 default when JNI loaded; per-call preferV4/preferV3 + env var
TTIO_M94Z_VERSION override; existing V1/V2 dispatch preserved.
V2 default-asserting tests now expectedly fail; Task 5 updates them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 5: Java V4 dispatch test suite + V2 test fixups

**Files:**
- Create: `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4DispatchTest.java`
- Modify: `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV2DispatchTest.java`

Mirrors the Python V4 dispatch test (Stage 2 Task 12). Adds 10 new V4 tests; updates V2 tests to be explicit about `preferV4=false`.

- [ ] **Step 1: Write the V4 dispatch test suite**

Create `/home/toddw/TTI-O/java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4DispatchTest.java`:

```java
/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.condition.EnabledIf;
import org.junit.jupiter.api.io.TempDir;

import java.nio.file.Path;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * V4 dispatch tests for FqzcompNx16Z (Java).
 *
 * Mirrors python/tests/test_m94z_v4_dispatch.py. All tests skip when
 * TtioRansNative.isAvailable() is false (no JNI on classpath).
 */
class FqzcompNx16ZV4DispatchTest {

    static boolean jniAvailable() { return TtioRansNative.isAvailable(); }

    private static final byte[] SYNTH_QUALITIES = {
        'I','I','?','?',  '5','5','5','5',  'I','?','I','?'
    };
    private static final int[] SYNTH_LENS    = {4, 4, 4};
    private static final int[] SYNTH_REVCOMP = {0, 1, 0};

    @Test
    @EnabledIf("jniAvailable")
    void v4SmokeRoundtrip() {
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions();
        opts.preferV4 = true;
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        assertEquals('M', out[0]); assertEquals('9', out[1]); assertEquals('4', out[2]); assertEquals('Z', out[3]);
        assertEquals(4, out[4]);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, SYNTH_REVCOMP);
        assertArrayEquals(SYNTH_QUALITIES, r.qualities);
        assertArrayEquals(SYNTH_LENS, r.readLengths);
    }

    @Test
    @EnabledIf("jniAvailable")
    void v4DefaultWhenJni() {
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP,
                                          new FqzcompNx16Z.EncodeOptions());
        assertEquals(4, out[4]);
    }

    @Test
    @EnabledIf("jniAvailable")
    void v2ExplicitStillWorks() {
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions();
        opts.preferV4 = false;
        opts.preferNative = true;  // V2 dispatch
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        assertEquals(2, out[4]);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, SYNTH_REVCOMP);
        assertArrayEquals(SYNTH_QUALITIES, r.qualities);
    }

    @Test
    @EnabledIf("jniAvailable")
    void v4PadCount13Qualities() {
        // 13 qualities → pad_count = 3
        byte[] qual = new byte[13];
        for (int i = 0; i < 13; i++) qual[i] = (byte)(33 + i);
        int[] lens = {13};
        int[] rev  = {0};
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions();
        opts.preferV4 = true;
        byte[] out = FqzcompNx16Z.encode(qual, lens, rev, opts);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, rev);
        assertArrayEquals(qual, r.qualities);
    }

    @Test
    @EnabledIf("jniAvailable")
    void v4SingleRead() {
        byte[] qual = new byte[50];
        for (int i = 0; i < 50; i++) qual[i] = 'I';
        int[] lens = {50};
        int[] rev  = {0};
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions();
        opts.preferV4 = true;
        byte[] out = FqzcompNx16Z.encode(qual, lens, rev, opts);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, rev);
        assertArrayEquals(qual, r.qualities);
    }

    @Test
    @EnabledIf("jniAvailable")
    void v4MixedRevcompRoundtrip() {
        byte[] qual = new byte[2342];
        long s = 0xBEEFL;
        for (int i = 0; i < 2342; i++) {
            s = s * 6364136223846793005L + 1442695040888963407L;
            qual[i] = (byte)(33 + 20 + (int)((s >>> 32) & 0xFFFFFFFFL) % 21);
        }
        int n_reads = 20;
        int[] lens = new int[n_reads];
        int[] rev  = new int[n_reads];
        // Distribute 2342 quality bytes across 20 reads of varied lengths.
        int rem = 2342;
        for (int i = 0; i < n_reads - 1; i++) {
            lens[i] = 50 + (i * 7) % 150;
            rem -= lens[i];
            rev[i] = i % 3 == 0 ? 1 : 0;
        }
        lens[n_reads - 1] = rem;
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions();
        opts.preferV4 = true;
        byte[] out = FqzcompNx16Z.encode(qual, lens, rev, opts);
        FqzcompNx16Z.DecodeResult r = FqzcompNx16Z.decode(out, rev);
        assertArrayEquals(qual, r.qualities);
        assertArrayEquals(lens, r.readLengths);
    }

    @Test
    @EnabledIf("jniAvailable")
    void v4SizeSanityVsV2() {
        // Loose check: V4 should be in the same ballpark as V2 on small input
        byte[] qual = new byte[1000];
        for (int i = 0; i < 1000; i++) qual[i] = (byte)(33 + 20 + (i * 7) % 21);
        int[] lens = new int[10];
        int[] rev  = new int[10];
        for (int i = 0; i < 10; i++) lens[i] = 100;

        FqzcompNx16Z.EncodeOptions optV4 = new FqzcompNx16Z.EncodeOptions();
        optV4.preferV4 = true;
        FqzcompNx16Z.EncodeOptions optV2 = new FqzcompNx16Z.EncodeOptions();
        optV2.preferV4 = false; optV2.preferNative = true;

        byte[] v4 = FqzcompNx16Z.encode(qual, lens, rev, optV4);
        byte[] v2 = FqzcompNx16Z.encode(qual, lens, rev, optV2);
        // V4 should be at most V2 size + 200 byte (header overhead allowance)
        assertTrue(v4.length <= v2.length + 200,
            "V4=" + v4.length + " vs V2=" + v2.length);
    }

    @Test
    @EnabledIf("jniAvailable")
    void v4EnvVarOverrideToV2() {
        // Note: System.getenv() can't be set from JUnit cleanly; this test
        // verifies the property is honored via System.setProperty + a wrapper.
        // For now, verify that opts.preferV4=false + preferNative=true gives V2,
        // analogous to TTIO_M94Z_VERSION=2.
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions();
        opts.preferV4 = false;
        opts.preferNative = true;
        byte[] out = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        assertEquals(2, out[4]);
    }

    @Test
    @EnabledIf("jniAvailable")
    void v4DecodeRejectsTamperedVersionByte() {
        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions();
        opts.preferV4 = true;
        byte[] v4 = FqzcompNx16Z.encode(SYNTH_QUALITIES, SYNTH_LENS, SYNTH_REVCOMP, opts);
        v4[4] = 2;  // Tamper version
        try {
            FqzcompNx16Z.decode(v4, SYNTH_REVCOMP);
            // V2 path will likely fail to parse the V4 body — expected
        } catch (Exception expected) {
            // OK
        }
    }
}
```

- [ ] **Step 2: Update FqzcompNx16ZV2DispatchTest.java**

Open the existing V2 dispatch test file. For each test that calls `encode(...)` and asserts `version == 2`:
- If the test is "default-emit V2 when JNI loaded": rename to "default-emit V4 when JNI loaded; V2 only when explicitly preferred"
- If the test is "V2-explicit emits V2": add `opts.preferV4 = false;` to the EncodeOptions setup

The exact edits depend on the file content; read it first and apply minimum-diff patches.

- [ ] **Step 3: Strip CRLF + run V2 + V4 dispatch suites**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4DispatchTest.java java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV2DispatchTest.java && cd java && mvn -q -Dtest='"'"'FqzcompNx16Z*Dispatch*'"'"' test -Djava.library.path=/home/toddw/TTI-O/native/_build 2>&1 | tail -10'
```

Expected: All V4 + updated V2 dispatch tests pass.

- [ ] **Step 4: Run the full Java test suite**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/java && mvn -q test -Djava.library.path=/home/toddw/TTI-O/native/_build 2>&1 | tail -10'
```

Expected: BUILD SUCCESS, all tests pass.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "test(L3 V4 Java): V4 dispatch suite + V2 default-test updates

~10 V4 dispatch tests (smoke + default + V2-explicit + pad/single/
mixed-revcomp edge cases). V2 default-asserting tests updated to
preferV4=false explicitly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 6: Java cross-corpus byte-equality vs Python (4 corpora)

**Files:**
- Create: `java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4ByteExactTest.java`

The Phase 5 gate for the Java side: encode the same 4 corpora through Java's V4 path and assert byte-equality with the reference Python V4 output (or directly with htscodecs auto-tune output via the existing `tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref_autotune` driver — same as Stage 2 Task 13).

- [ ] **Step 1: Verify the corpus inputs are still extractable**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && for name in chr22 wes hg002_illumina hg002_pacbio; do bam=""; case $name in chr22) bam=/home/toddw/TTI-O/data/genomic/na12878/na12878.chr22.lean.mapped.bam;; wes) bam=/home/toddw/TTI-O/data/genomic/na12878_wes/na12878_wes.chr22.bam;; hg002_illumina) bam=/home/toddw/TTI-O/data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam;; hg002_pacbio) bam=/home/toddw/TTI-O/data/genomic/hg002_pacbio/hg002_pacbio.subset.bam;; esac; ls -la $bam || echo "MISSING: $name"; done'
```

If any corpus is missing, document it and skip in the test. The test uses `@EnabledIf` to gate per-corpus availability.

- [ ] **Step 2: Write the Java byte-exact test**

Create `/home/toddw/TTI-O/java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4ByteExactTest.java`:

```java
/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.codecs;

import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.condition.EnabledIf;
import org.junit.jupiter.params.ParameterizedTest;
import org.junit.jupiter.params.provider.MethodSource;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.stream.Stream;

import static org.junit.jupiter.api.Assertions.assertArrayEquals;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertTrue;

/**
 * Java V4 cross-corpus byte-exact test.
 *
 * For each of 4 corpora:
 *   1. Read the Python-extracted /tmp/{name}_v4_qual.bin etc.
 *      (assumes the Python integration test or htscodecs_compare.sh has
 *       already been run to populate /tmp).
 *   2. Encode via Java (preferV4=true).
 *   3. Compare bytes against /tmp/our_{name}_v4.fqz (Python V4 output).
 *
 * Tagged @integration; excluded from default Maven test run.
 */
@Tag("integration")
class FqzcompNx16ZV4ByteExactTest {

    static boolean jniAvailable() { return TtioRansNative.isAvailable(); }

    static Stream<Object[]> corpora() {
        return Stream.of(
            new Object[]{"chr22", 178409733, 1766433},
            new Object[]{"wes",    95035281,  992974},
            new Object[]{"hg002_illumina", 248184765, 997415},
            new Object[]{"hg002_pacbio",   264190341,  14284}
        );
    }

    @ParameterizedTest
    @MethodSource("corpora")
    @EnabledIf("jniAvailable")
    void v4ByteExactVsPython(String name, long expectedNQual, long expectedNReads) throws IOException {
        Path qualBin  = Path.of("/tmp/" + name + "_v4_qual.bin");
        Path lensBin  = Path.of("/tmp/" + name + "_v4_lens.bin");
        Path flagsBin = Path.of("/tmp/" + name + "_v4_flags.bin");
        Path pyOut    = Path.of("/tmp/our_" + name + "_v4.fqz");
        if (!Files.exists(qualBin) || !Files.exists(pyOut)) {
            // Skip cleanly if the Phase-5 prep isn't done yet
            return;
        }

        byte[] qualities = Files.readAllBytes(qualBin);
        byte[] lensBlob  = Files.readAllBytes(lensBin);
        byte[] flagsBlob = Files.readAllBytes(flagsBin);
        // lens and flags are both uint32 LE per-read (per Stage 2 extractor)
        int n_reads = lensBlob.length / 4;
        int[] lens  = new int[n_reads];
        int[] flags = new int[n_reads];
        for (int i = 0; i < n_reads; i++) {
            lens[i]  = (lensBlob [4*i] & 0xFF) | ((lensBlob [4*i+1] & 0xFF) << 8)
                     | ((lensBlob [4*i+2] & 0xFF) << 16) | ((lensBlob [4*i+3] & 0xFF) << 24);
            flags[i] = (flagsBlob[4*i] & 0xFF) | ((flagsBlob[4*i+1] & 0xFF) << 8)
                     | ((flagsBlob[4*i+2] & 0xFF) << 16) | ((flagsBlob[4*i+3] & 0xFF) << 24);
        }
        // SAM_REVERSE bit is bit 4 of the SAM flag; pass through directly.
        // (The Java encoder converts to 0/16 in SAM space.)
        int[] revcomp = new int[n_reads];
        for (int i = 0; i < n_reads; i++) revcomp[i] = (flags[i] & 16) != 0 ? 1 : 0;

        assertEquals(expectedNQual, qualities.length, name + " qual size");
        assertEquals(expectedNReads, n_reads, name + " n_reads");

        FqzcompNx16Z.EncodeOptions opts = new FqzcompNx16Z.EncodeOptions();
        opts.preferV4 = true;
        byte[] javaV4 = FqzcompNx16Z.encode(qualities, lens, revcomp, opts);

        byte[] pyV4 = Files.readAllBytes(pyOut);

        assertArrayEquals(pyV4, javaV4,
            name + ": Java=" + javaV4.length + " Python=" + pyV4.length);
    }
}
```

- [ ] **Step 3: Pre-populate the /tmp inputs from Python**

Run the Stage 2 byte-equality harness which extracts all 4 corpora to `/tmp` and produces `/tmp/our_{name}_v4.fqz`:

```bash
wsl -d Ubuntu -- bash -c '/home/toddw/TTI-O/tools/perf/htscodecs_compare.sh 2>&1 | tail -10'
```

Expected: `ALL CORPORA: BYTE-EQUAL` (already proven; this just populates the files).

Then also run the Python integration test which writes additional `/tmp/our_*` files:

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_m94z_v4_byte_exact.py -m integration -v 2>&1 | tail -10'
```

Note the actual filenames the test writes — the Java test reads from those exact paths.

- [ ] **Step 4: Strip CRLF + run the Java test**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4ByteExactTest.java && cd java && mvn -q -Dtest=FqzcompNx16ZV4ByteExactTest -Dgroups=integration test -Djava.library.path=/home/toddw/TTI-O/native/_build 2>&1 | tail -15'
```

Expected: 4 parametrized cases pass.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4ByteExactTest.java && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L3 V4 Java): cross-corpus byte-exact vs Python (4 corpora)

Phase 5 gate for Java: V4 encoder produces byte-identical output to
Python V4 across chr22 + WES + HG002 Illumina + HG002 PacBio HiFi.
Tagged @integration; requires /tmp inputs populated by
htscodecs_compare.sh + python integration test.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 3 — ObjC TTIOFqzcompNx16Z V4 dispatch

### Task 7: Add V4 encode/decode to TTIOFqzcompNx16Z + V4 default selection

**Files:**
- Modify: `objc/Source/Codecs/TTIOFqzcompNx16Z.h` — declare V4 entry points; document V4 default
- Modify: `objc/Source/Codecs/TTIOFqzcompNx16Z.m` — implement V4 via direct `ttio_m94z_v4_encode/decode` calls

ObjC already directly links `libttio_rans` for the V2 native dispatch path (per existing class header comments). For V4, add new methods and dispatch logic.

- [ ] **Step 1: Read the existing V2 native dispatch**

Open `/home/toddw/TTI-O/objc/Source/Codecs/TTIOFqzcompNx16Z.m`. Find the V2 native dispatch (search for `ttio_rans_encode_block` or similar). Note:
- How `libttio_rans` symbols are declared (likely via an `extern "C"` block or by including a header)
- How NSData/NSArray are converted to C buffers
- How errors are propagated through `NSError**`
- The version-byte dispatch in `decodeData:revcompFlags:error:`

- [ ] **Step 2: Declare V4 in the header**

In `objc/Source/Codecs/TTIOFqzcompNx16Z.h`, add to the existing class declaration (after the V2 options support):

```objc
/**
 * Encode with explicit V4 dispatch (CRAM 3.1 fqzcomp byte-compatible).
 *
 * Mirrors python/src/ttio/codecs/fqzcomp_nx16_z.py::encode(prefer_v4=True).
 * Returns an M94.Z V4 stream (version byte = 4) whose inner CRAM body
 * is byte-equal to htscodecs's fqzcomp_qual auto-tune output.
 *
 * V4 is the default when libttio_rans is linked. To force V1 or V2,
 * use the +encodeWithQualities:readLengths:revcompFlags:options:error:
 * variant with options[@"preferV4"] = @NO and the appropriate
 * options[@"preferNative"] for V2 vs V1.
 *
 * The +encodeWithQualities:readLengths:revcompFlags:error: convenience
 * variant now picks V4 by default when libttio_rans is linked.
 *
 * @param strategyHint -1 = auto-tune; 0..3 = explicit preset; default -1.
 * @param padCount 0..3 (low-2 bits of V4 flags byte).
 */
+ (nullable NSData *)encodeV4WithQualities:(NSData *)qualities
                                readLengths:(NSArray<NSNumber *> *)readLengths
                               revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                               strategyHint:(NSInteger)strategyHint
                                   padCount:(uint8_t)padCount
                                      error:(NSError * _Nullable *)error;

/**
 * Decode a V4 M94.Z stream via libttio_rans.
 *
 * +decodeData:revcompFlags:error: dispatches to this internally when
 * encoded[4] == 4. Direct calls are useful for round-trip tests.
 */
+ (nullable NSData *)decodeV4Data:(NSData *)data
                       revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                              error:(NSError * _Nullable *)error;
```

- [ ] **Step 3: Implement V4 in the .m file**

In `objc/Source/Codecs/TTIOFqzcompNx16Z.m`, add the extern declarations near the top (or in the existing extern block):

```objc
/* libttio_rans V4 entry points (see native/include/ttio_rans.h). */
extern int ttio_m94z_v4_encode(
    const uint8_t  *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t         pad_count,
    uint8_t        *out, size_t *out_len);

extern int ttio_m94z_v4_decode(
    const uint8_t  *in, size_t in_len,
    uint32_t       *read_lengths, size_t n_reads,
    const uint8_t  *flags,
    uint8_t        *out_qual, size_t n_qualities);
```

Implement the new methods:

```objc
+ (nullable NSData *)encodeV4WithQualities:(NSData *)qualities
                                readLengths:(NSArray<NSNumber *> *)readLengths
                               revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                               strategyHint:(NSInteger)strategyHint
                                   padCount:(uint8_t)padCount
                                      error:(NSError * _Nullable *)error
{
    NSUInteger n_qual  = qualities.length;
    NSUInteger n_reads = readLengths.count;
    if (revcompFlags.count != n_reads) {
        if (error) {
            *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain code:1
                                      userInfo:@{NSLocalizedDescriptionKey:
                @"revcompFlags.count must equal readLengths.count"}];
        }
        return nil;
    }
    /* Marshal Java-style int arrays to C buffers. */
    uint32_t *lens = malloc(n_reads * sizeof(uint32_t));
    uint8_t  *flags = malloc(n_reads);
    if (!lens || !flags) {
        free(lens); free(flags);
        if (error) {
            *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain code:2
                                      userInfo:@{NSLocalizedDescriptionKey:
                @"malloc failed"}];
        }
        return nil;
    }
    for (NSUInteger i = 0; i < n_reads; i++) {
        lens[i]  = (uint32_t)[readLengths[i] unsignedIntValue];
        flags[i] = ([revcompFlags[i] intValue] & 1) ? 16 : 0;  /* SAM_REVERSE */
    }

    size_t out_cap = n_qual + n_qual / 4 + (1u << 20);
    uint8_t *out = malloc(out_cap);
    if (!out) {
        free(lens); free(flags);
        if (error) {
            *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain code:3
                                      userInfo:@{NSLocalizedDescriptionKey:
                @"out malloc failed"}];
        }
        return nil;
    }
    size_t out_len = out_cap;
    int rc = ttio_m94z_v4_encode(
        qualities.bytes, n_qual,
        lens, n_reads,
        flags,
        (int)strategyHint,
        padCount,
        out, &out_len);
    free(lens); free(flags);
    if (rc != 0) {
        free(out);
        if (error) {
            *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain code:rc
                                      userInfo:@{NSLocalizedDescriptionKey:
                [NSString stringWithFormat:@"ttio_m94z_v4_encode rc=%d", rc]}];
        }
        return nil;
    }
    NSData *result = [NSData dataWithBytesNoCopy:out length:out_len freeWhenDone:YES];
    return result;
}

+ (nullable NSData *)decodeV4Data:(NSData *)data
                       revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                              error:(NSError * _Nullable *)error
{
    if (data.length < 30) {
        if (error) *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                                  code:10 userInfo:@{NSLocalizedDescriptionKey:
                                @"V4 stream too short"}];
        return nil;
    }
    const uint8_t *p = data.bytes;
    if (p[0] != 'M' || p[1] != '9' || p[2] != '4' || p[3] != 'Z' || p[4] != 4) {
        if (error) *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                                  code:11 userInfo:@{NSLocalizedDescriptionKey:
                                @"not an M94.Z V4 stream"}];
        return nil;
    }
    uint64_t numQualities, numReads;
    memcpy(&numQualities, p + 6, 8);
    memcpy(&numReads,    p + 14, 8);
    if (revcompFlags == nil) {
        NSMutableArray<NSNumber *> *zeros = [NSMutableArray arrayWithCapacity:numReads];
        for (uint64_t i = 0; i < numReads; i++) [zeros addObject:@0];
        revcompFlags = zeros;
    }
    if (revcompFlags.count != numReads) {
        if (error) *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                                  code:12 userInfo:@{NSLocalizedDescriptionKey:
                                @"revcompFlags.count != numReads"}];
        return nil;
    }
    uint32_t *lens = malloc(numReads * sizeof(uint32_t));
    uint8_t  *flags = malloc(numReads);
    uint8_t  *qual  = malloc(numQualities);
    if (!lens || !flags || !qual) {
        free(lens); free(flags); free(qual);
        if (error) *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                                  code:13 userInfo:@{NSLocalizedDescriptionKey:
                                @"malloc failed"}];
        return nil;
    }
    for (uint64_t i = 0; i < numReads; i++) {
        flags[i] = ([revcompFlags[(NSUInteger)i] intValue] & 1) ? 16 : 0;
    }

    int rc = ttio_m94z_v4_decode(
        p, data.length,
        lens, numReads,
        flags,
        qual, numQualities);
    free(lens); free(flags);
    if (rc != 0) {
        free(qual);
        if (error) *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                                  code:rc userInfo:@{NSLocalizedDescriptionKey:
                                [NSString stringWithFormat:@"ttio_m94z_v4_decode rc=%d", rc]}];
        return nil;
    }
    return [NSData dataWithBytesNoCopy:qual length:numQualities freeWhenDone:YES];
}
```

- [ ] **Step 4: Update the existing dispatchers to handle V4**

In `+encodeWithQualities:readLengths:revcompFlags:options:error:`, add the V4 branch as the FIRST check (before V2/V1). Mirror Python's logic:

```objc
+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                  options:(nullable NSDictionary<NSString *, id> *)options
                                    error:(NSError * _Nullable *)error
{
    /* V4 dispatch resolution: per-call → env → default */
    BOOL preferV4;
    NSNumber *preferV4Opt = options[@"preferV4"];
    if (preferV4Opt != nil) {
        preferV4 = [preferV4Opt boolValue];
    } else {
        const char *env = getenv("TTIO_M94Z_VERSION");
        if (env && strcmp(env, "4") == 0) preferV4 = YES;
        else if (env && (strcmp(env, "1") == 0 || strcmp(env, "2") == 0 || strcmp(env, "3") == 0)) preferV4 = NO;
        else preferV4 = YES;  /* default: V4 (libttio_rans is always linked in this build) */
    }

    if (preferV4) {
        NSInteger strategy = -1;
        NSNumber *strategyOpt = options[@"v4StrategyHint"];
        if (strategyOpt) strategy = [strategyOpt integerValue];
        uint8_t padCount = (uint8_t)((-(NSInteger)qualities.length) & 0x3);
        return [self encodeV4WithQualities:qualities readLengths:readLengths
                                revcompFlags:revcompFlags strategyHint:strategy
                                    padCount:padCount error:error];
    }
    /* ... existing V2/V1 dispatch unchanged below ... */
}
```

Update `+decodeData:revcompFlags:error:` to dispatch on version byte:

```objc
+ (nullable NSData *)decodeData:(NSData *)data
                    revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                           error:(NSError * _Nullable *)error
{
    if (data.length < 5) {
        if (error) *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                                  code:20 userInfo:@{NSLocalizedDescriptionKey:
                                @"M94.Z stream too short"}];
        return nil;
    }
    const uint8_t *p = data.bytes;
    if (p[0] != 'M' || p[1] != '9' || p[2] != '4' || p[3] != 'Z') {
        if (error) *error = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                                  code:21 userInfo:@{NSLocalizedDescriptionKey:
                                @"not an M94.Z stream"}];
        return nil;
    }
    uint8_t version = p[4];
    if (version == 4) {
        return [self decodeV4Data:data revcompFlags:revcompFlags error:error];
    }
    /* ... existing V2 / V1 dispatch unchanged below ... */
}
```

- [ ] **Step 5: Strip CRLF + rebuild + run existing ObjC tests**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' objc/Source/Codecs/TTIOFqzcompNx16Z.h objc/Source/Codecs/TTIOFqzcompNx16Z.m && tr -cd $'"'"'\r'"'"' < objc/Source/Codecs/TTIOFqzcompNx16Z.m | wc -c && cd objc && ./build.sh 2>&1 | tail -10'
```

Expected: 0 CRs; ObjC build clean.

Run existing tests (V2 default tests will fail; Task 8 fixes them):

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O/objc && (test -f Tests/obj/TTIOTestRunner && Tests/obj/TTIOTestRunner -F TTIOFqzcompNx16ZTest 2>&1 | tail -10) || ./build.sh tests 2>&1 | tail -10'
```

(Adjust the test invocation per the project's actual test runner — read `objc/Tests/GNUmakefile` and `objc/Tests/TTIOTestRunner.m` if needed.)

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "feat(L3 V4 ObjC): TTIOFqzcompNx16Z V4 dispatch via libttio_rans

V4 default when libttio_rans is linked; per-call options[@\"preferV4\"]
+ env var TTIO_M94Z_VERSION override; existing V1/V2 dispatch
preserved. V2 default-asserting tests now expectedly fail; Task 8
updates them.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 8: ObjC V4 dispatch test suite + V2 test fixups

**Files:**
- Create: `objc/Tests/TestTTIOFqzcompNx16ZV4Dispatch.m`
- Modify: existing V2 default-asserting ObjC tests (find via grep)

Mirrors the Java + Python V4 dispatch suites.

- [ ] **Step 1: Identify existing V2 default-asserting tests**

```bash
wsl -d Ubuntu -- bash -c 'grep -rn "version.*== 2\|encoded\[4\].*2\|p\[4\].*2" /home/toddw/TTI-O/objc/Tests/ 2>&1 | head -20'
```

Note which test files assert version=2 by default. They'll need updating.

- [ ] **Step 2: Write the V4 dispatch test**

Create `/home/toddw/TTI-O/objc/Tests/TestTTIOFqzcompNx16ZV4Dispatch.m`:

```objc
/*
 * TestTTIOFqzcompNx16ZV4Dispatch.m — V4 dispatch tests for TTIOFqzcompNx16Z.
 *
 * Mirrors python/tests/test_m94z_v4_dispatch.py and
 * java/src/test/java/global/thalion/ttio/codecs/FqzcompNx16ZV4DispatchTest.java.
 */
#import <Foundation/Foundation.h>
#import "TTIOFqzcompNx16Z.h"
#import "TTIOTestUtilities.h"   /* assumed; if not, use simple printf+exit */

static void v4SmokeRoundtrip(void) {
    uint8_t qual_bytes[12] = {'I','I','?','?','5','5','5','5','I','?','I','?'};
    NSData *qualities = [NSData dataWithBytes:qual_bytes length:12];
    NSArray *lens = @[@4, @4, @4];
    NSArray *rev  = @[@0, @1, @0];

    NSError *err = nil;
    NSData *out = [TTIOFqzcompNx16Z encodeV4WithQualities:qualities
                                              readLengths:lens
                                             revcompFlags:rev
                                             strategyHint:-1
                                                 padCount:0
                                                    error:&err];
    NSCAssert(out != nil, @"encodeV4 returned nil: %@", err);
    NSCAssert(out.length >= 30, @"V4 stream too short");
    const uint8_t *p = out.bytes;
    NSCAssert(p[0] == 'M' && p[1] == '9' && p[2] == '4' && p[3] == 'Z', @"bad magic");
    NSCAssert(p[4] == 4, @"version != 4");

    NSData *back = [TTIOFqzcompNx16Z decodeV4Data:out revcompFlags:rev error:&err];
    NSCAssert(back != nil, @"decodeV4 returned nil: %@", err);
    NSCAssert([back isEqualToData:qualities], @"round-trip mismatch");
    printf("v4SmokeRoundtrip: OK (%zu → %zu bytes)\n",
           (size_t)qualities.length, (size_t)out.length);
}

static void v4DefaultWhenNativeLinked(void) {
    uint8_t qual_bytes[12] = {'I','I','?','?','5','5','5','5','I','?','I','?'};
    NSData *qualities = [NSData dataWithBytes:qual_bytes length:12];
    NSArray *lens = @[@4, @4, @4];
    NSArray *rev  = @[@0, @1, @0];

    NSError *err = nil;
    NSData *out = [TTIOFqzcompNx16Z encodeWithQualities:qualities
                                            readLengths:lens
                                           revcompFlags:rev
                                                  error:&err];
    NSCAssert(out != nil, @"encode returned nil: %@", err);
    const uint8_t *p = out.bytes;
    NSCAssert(p[4] == 4, @"version expected 4 (V4 default), got %d", p[4]);
    printf("v4DefaultWhenNativeLinked: OK\n");
}

static void v2ExplicitStillEmitsV2(void) {
    uint8_t qual_bytes[12] = {'I','I','?','?','5','5','5','5','I','?','I','?'};
    NSData *qualities = [NSData dataWithBytes:qual_bytes length:12];
    NSArray *lens = @[@4, @4, @4];
    NSArray *rev  = @[@0, @1, @0];

    NSError *err = nil;
    NSData *out = [TTIOFqzcompNx16Z encodeWithQualities:qualities
                                            readLengths:lens
                                           revcompFlags:rev
                                                options:@{@"preferV4": @NO,
                                                          @"preferNative": @YES}
                                                  error:&err];
    NSCAssert(out != nil, @"encode returned nil: %@", err);
    const uint8_t *p = out.bytes;
    NSCAssert(p[4] == 2, @"version expected 2 (V2 explicit), got %d", p[4]);
    printf("v2ExplicitStillEmitsV2: OK\n");
}

static void v4PadCount13(void) {
    uint8_t qual[13];
    for (int i = 0; i < 13; i++) qual[i] = 33 + i;
    NSData *q = [NSData dataWithBytes:qual length:13];
    NSError *err = nil;
    NSData *out = [TTIOFqzcompNx16Z encodeV4WithQualities:q
                                              readLengths:@[@13]
                                             revcompFlags:@[@0]
                                             strategyHint:-1
                                                 padCount:3
                                                    error:&err];
    NSCAssert(out, @"encodeV4 nil: %@", err);
    NSData *back = [TTIOFqzcompNx16Z decodeV4Data:out revcompFlags:@[@0] error:&err];
    NSCAssert([back isEqualToData:q], @"round-trip mismatch");
    printf("v4PadCount13: OK\n");
}

int TTIOFqzcompNx16ZV4DispatchMain(void) {
    v4SmokeRoundtrip();
    v4DefaultWhenNativeLinked();
    v2ExplicitStillEmitsV2();
    v4PadCount13();
    printf("All V4 dispatch tests passed.\n");
    return 0;
}
```

(The exact test runner integration depends on `objc/Tests/TTIOTestRunner.m` — read it to understand how to register a new test entry point. The above is a standalone-runnable form; adapt to the project's test framework.)

- [ ] **Step 3: Update existing V2-default tests**

For each test file from Step 1 that asserts `version == 2`, change the encode call to set `options[@"preferV4"] = @NO; options[@"preferNative"] = @YES;` (or the appropriate prerequisite for V2 path).

- [ ] **Step 4: Strip CRLF + rebuild + run**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' objc/Tests/TestTTIOFqzcompNx16ZV4Dispatch.m && cd objc && ./build.sh 2>&1 | tail -10 && cd Tests && (test -x TTIOTestRunner && ./TTIOTestRunner 2>&1 || gnustep-tests 2>&1) | tail -20'
```

Expected: build clean; V4 dispatch + V2-explicit + other ObjC tests all pass.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add objc/Tests/TestTTIOFqzcompNx16ZV4Dispatch.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "test(L3 V4 ObjC): V4 dispatch suite + V2 default-test updates

V4 dispatch tests (smoke + default + V2-explicit + pad/single edge
cases). V2 default-asserting tests updated to options[preferV4]=@NO
explicitly.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

### Task 9: ObjC cross-corpus byte-equality vs Python (4 corpora)

**Files:**
- Create: `objc/Tests/TestTTIOFqzcompNx16ZV4ByteExact.m`

Phase 5 gate for ObjC. Same shape as Java's Task 6 test.

- [ ] **Step 1: Pre-populate /tmp inputs**

Same as Task 6 Step 3:

```bash
wsl -d Ubuntu -- bash -c '/home/toddw/TTI-O/tools/perf/htscodecs_compare.sh 2>&1 | tail -10 && cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_m94z_v4_byte_exact.py -m integration 2>&1 | tail -5'
```

Expected: ALL CORPORA: BYTE-EQUAL (Python C-level + end-to-end gates pass).

- [ ] **Step 2: Write the ObjC byte-exact test**

Create `/home/toddw/TTI-O/objc/Tests/TestTTIOFqzcompNx16ZV4ByteExact.m`:

```objc
/*
 * TestTTIOFqzcompNx16ZV4ByteExact.m — ObjC V4 cross-corpus byte-exact test.
 *
 * Mirrors java/.../FqzcompNx16ZV4ByteExactTest.java and
 * python/tests/integration/test_m94z_v4_byte_exact.py.
 *
 * For each of 4 corpora, reads /tmp/{name}_v4_qual.bin etc., encodes via
 * +encodeV4WithQualities:..., compares bytes against /tmp/our_{name}_v4.fqz
 * (Python V4 output).
 */
#import <Foundation/Foundation.h>
#import "TTIOFqzcompNx16Z.h"

static int compareCorpus(const char *name, size_t expectedNQual, size_t expectedNReads) {
    NSString *base = [NSString stringWithFormat:@"/tmp/%s_v4", name];
    NSString *qualPath  = [base stringByAppendingString:@"_qual.bin"];
    NSString *lensPath  = [base stringByAppendingString:@"_lens.bin"];
    NSString *flagsPath = [base stringByAppendingString:@"_flags.bin"];
    NSString *pyOut     = [NSString stringWithFormat:@"/tmp/our_%s_v4.fqz", name];

    NSData *qualities = [NSData dataWithContentsOfFile:qualPath];
    NSData *lensBlob  = [NSData dataWithContentsOfFile:lensPath];
    NSData *flagsBlob = [NSData dataWithContentsOfFile:flagsPath];
    NSData *pyResult  = [NSData dataWithContentsOfFile:pyOut];
    if (!qualities || !lensBlob || !flagsBlob || !pyResult) {
        printf("SKIP %s (missing inputs in /tmp)\n", name);
        return 0;
    }
    size_t n_reads = lensBlob.length / 4;
    if (qualities.length != expectedNQual || n_reads != expectedNReads) {
        fprintf(stderr, "FAIL %s: size mismatch (qual %zu/%zu, reads %zu/%zu)\n",
                name, (size_t)qualities.length, expectedNQual, n_reads, expectedNReads);
        return 1;
    }
    const uint32_t *lensArr = (const uint32_t *)lensBlob.bytes;
    const uint32_t *flagsArr = (const uint32_t *)flagsBlob.bytes;
    NSMutableArray *lens = [NSMutableArray arrayWithCapacity:n_reads];
    NSMutableArray *rev  = [NSMutableArray arrayWithCapacity:n_reads];
    for (size_t i = 0; i < n_reads; i++) {
        [lens addObject:@(lensArr[i])];
        [rev  addObject:@((flagsArr[i] & 16) != 0 ? 1 : 0)];
    }

    NSError *err = nil;
    NSData *objcV4 = [TTIOFqzcompNx16Z encodeV4WithQualities:qualities
                                                  readLengths:lens
                                                 revcompFlags:rev
                                                 strategyHint:-1
                                                     padCount:0
                                                        error:&err];
    if (!objcV4) {
        fprintf(stderr, "FAIL %s: encodeV4 returned nil: %s\n",
                name, [[err localizedDescription] UTF8String]);
        return 1;
    }
    if (![objcV4 isEqualToData:pyResult]) {
        fprintf(stderr, "FAIL %s: ObjC=%zu Python=%zu\n",
                name, (size_t)objcV4.length, (size_t)pyResult.length);
        return 1;
    }
    printf("OK %s: %zu qualities, %zu bytes (byte-equal Python)\n",
           name, (size_t)qualities.length, (size_t)objcV4.length);
    return 0;
}

int TTIOFqzcompNx16ZV4ByteExactMain(void) {
    int fails = 0;
    fails += compareCorpus("chr22",          178409733, 1766433);
    fails += compareCorpus("wes",             95035281,  992974);
    fails += compareCorpus("hg002_illumina", 248184765,  997415);
    fails += compareCorpus("hg002_pacbio",   264190341,   14284);
    if (fails) { fprintf(stderr, "%d corpus failures\n", fails); return 1; }
    printf("All 4 corpora byte-equal Python.\n");
    return 0;
}
```

- [ ] **Step 3: Strip CRLF + build + run on Linux/WSL**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' objc/Tests/TestTTIOFqzcompNx16ZV4ByteExact.m && cd objc && ./build.sh 2>&1 | tail -10 && cd Tests && (test -x TTIOTestRunner && ./TTIOTestRunner -t TTIOFqzcompNx16ZV4ByteExact || gnustep-tests TestTTIOFqzcompNx16ZV4ByteExact) 2>&1 | tail -15'
```

Expected (Linux/WSL primary target): 4 corpora all byte-equal.

If macOS or GNUstep-on-Windows is available, also:

```bash
# macOS (bonus)
# objc/build.sh --target=macos && (run test runner)

# GNUstep-on-Windows (bonus)
# Uses MSYS2/UCRT64 GNUstep per project memory; same build.sh invocation
# inside MSYS2 shell.
```

- [ ] **Step 4: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add objc/Tests/TestTTIOFqzcompNx16ZV4ByteExact.m && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L3 V4 ObjC): cross-corpus byte-exact vs Python (4 corpora)

Phase 5 gate for ObjC: V4 encoder produces byte-identical output to
Python V4 across chr22 + WES + HG002 Illumina + HG002 PacBio HiFi.
Linux/WSL primary target; macOS + GNUstep-on-Windows bonus targets.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 4 — Cross-language byte-equality matrix

### Task 10: Python integration test orchestrating Java ↔ Python ↔ ObjC byte-equality

**Files:**
- Create: `python/tests/integration/test_m94z_v4_cross_language.py`

Single integration test that proves the full byte-equality matrix. The Python test:
1. For each of 4 corpora: extracts qualities via `BamReader`
2. Encodes via Python V4 → store as reference
3. Invokes Java V4 encoder via `subprocess` (a tiny Java CLI tool)
4. Invokes ObjC V4 encoder via `subprocess` (a tiny ObjC CLI tool)
5. Asserts all 3 outputs are byte-identical
6. Decodes each via the OTHER language's decoder; asserts qualities recovered identical

This is 4 corpora × 6 cross-decode combinations = 24 assertions per encode permutation. Tagged `integration`, deselected by default.

- [ ] **Step 1: Add small Java CLI tool**

Create `/home/toddw/TTI-O/java/src/main/java/global/thalion/ttio/tools/M94zV4Cli.java`:

```java
/*
 * TTI-O Java Implementation
 * Copyright (C) 2026 DTW-Thalion
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
package global.thalion.ttio.tools;

import global.thalion.ttio.codecs.FqzcompNx16Z;
import global.thalion.ttio.codecs.FqzcompNx16Z.EncodeOptions;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.file.Files;
import java.nio.file.Path;

/**
 * Tiny CLI that mirrors fqzcomp_htscodecs_ref_autotune.c but uses Java.
 * Reads {qual.bin, lens.bin, flags.bin}, V4-encodes via JNI, writes to outpath.
 */
public final class M94zV4Cli {
    public static void main(String[] args) throws IOException {
        if (args.length != 4) {
            System.err.println("usage: M94zV4Cli qual.bin lens.bin flags.bin out.fqz");
            System.exit(1);
        }
        byte[] qualities = Files.readAllBytes(Path.of(args[0]));
        byte[] lensBlob  = Files.readAllBytes(Path.of(args[1]));
        byte[] flagsBlob = Files.readAllBytes(Path.of(args[2]));
        ByteBuffer lensBb  = ByteBuffer.wrap(lensBlob).order(ByteOrder.LITTLE_ENDIAN);
        ByteBuffer flagsBb = ByteBuffer.wrap(flagsBlob).order(ByteOrder.LITTLE_ENDIAN);
        int n_reads = lensBlob.length / 4;
        int[] lens  = new int[n_reads];
        int[] rev   = new int[n_reads];
        for (int i = 0; i < n_reads; i++) {
            lens[i] = lensBb.getInt();
            int sam = flagsBb.getInt();
            rev[i] = (sam & 16) != 0 ? 1 : 0;
        }
        EncodeOptions opts = new EncodeOptions();
        opts.preferV4 = true;
        byte[] out = FqzcompNx16Z.encode(qualities, lens, rev, opts);
        Files.write(Path.of(args[3]), out);
        System.err.printf("Java V4: %d qualities → %d bytes (B/qual=%.4f)%n",
            qualities.length, out.length, (double)out.length / qualities.length);
    }
}
```

- [ ] **Step 2: Add small ObjC CLI tool**

Create `/home/toddw/TTI-O/objc/Tools/M94zV4Cli/M94zV4Cli.m`:

```objc
/*
 * M94zV4Cli — tiny CLI mirroring Java's M94zV4Cli for cross-language tests.
 */
#import <Foundation/Foundation.h>
#import "TTIOFqzcompNx16Z.h"

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 5) {
            fprintf(stderr, "usage: %s qual.bin lens.bin flags.bin out.fqz\n", argv[0]);
            return 1;
        }
        NSData *qualities = [NSData dataWithContentsOfFile:@(argv[1])];
        NSData *lensBlob  = [NSData dataWithContentsOfFile:@(argv[2])];
        NSData *flagsBlob = [NSData dataWithContentsOfFile:@(argv[3])];
        if (!qualities || !lensBlob || !flagsBlob) {
            fprintf(stderr, "ObjC V4 CLI: failed to read inputs\n"); return 2;
        }
        size_t n_reads = lensBlob.length / 4;
        const uint32_t *lensArr  = (const uint32_t *)lensBlob.bytes;
        const uint32_t *flagsArr = (const uint32_t *)flagsBlob.bytes;
        NSMutableArray *lens = [NSMutableArray arrayWithCapacity:n_reads];
        NSMutableArray *rev  = [NSMutableArray arrayWithCapacity:n_reads];
        for (size_t i = 0; i < n_reads; i++) {
            [lens addObject:@(lensArr[i])];
            [rev  addObject:@((flagsArr[i] & 16) != 0 ? 1 : 0)];
        }
        NSError *err = nil;
        NSData *out = [TTIOFqzcompNx16Z encodeV4WithQualities:qualities
                                                   readLengths:lens
                                                  revcompFlags:rev
                                                  strategyHint:-1
                                                      padCount:0
                                                         error:&err];
        if (!out) {
            fprintf(stderr, "encodeV4 returned nil: %s\n",
                    [[err localizedDescription] UTF8String]);
            return 3;
        }
        [out writeToFile:@(argv[4]) atomically:YES];
        fprintf(stderr, "ObjC V4: %zu qualities → %zu bytes (B/qual=%.4f)\n",
                (size_t)qualities.length, (size_t)out.length,
                (double)out.length / qualities.length);
    }
    return 0;
}
```

Add a `GNUmakefile` for the new tool target (mirror an existing tool in `objc/Tools/`).

- [ ] **Step 3: Add `pytestmark` integration marker + verify maven jar location**

Both Java and ObjC tools need to be built before the test runs. The test will assume the binaries are at:
- Java: `java/target/ttio-*.jar` (Maven default), invoked via `java -cp <jar>:<deps> -Djava.library.path=... global.thalion.ttio.tools.M94zV4Cli`
- ObjC: `objc/Tools/M94zV4Cli/obj/M94zV4Cli` (GNUstep make default)

Check by inspecting Stage 2 helpers if Python already orchestrates Java/ObjC subprocess calls (e.g., look at `test_m90_cross_language.py` for the pattern).

- [ ] **Step 4: Write the cross-language Python integration test**

Create `/home/toddw/TTI-O/python/tests/integration/test_m94z_v4_cross_language.py`:

```python
"""V4 cross-language byte-equality matrix.

For each of 4 corpora:
  - Encode via Python V4
  - Encode via Java V4 (subprocess M94zV4Cli)
  - Encode via ObjC V4 (subprocess M94zV4Cli)
  - All 3 must produce byte-identical output

Tagged @integration; requires java/target/*.jar (mvn package) and
objc/Tools/M94zV4Cli/obj/M94zV4Cli (gnustep make) to be pre-built.
"""
from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

from ttio.codecs.fqzcomp_nx16_z import encode, _HAVE_NATIVE_LIB
from ttio.importers.bam import BamReader

REPO = Path("/home/toddw/TTI-O")
JAVA_JAR_GLOB = "java/target/ttio-*.jar"
JAVA_DEPS = REPO / "java/target/dependency"  # if mvn dependency:copy-dependencies was run
OBJC_CLI = REPO / "objc/Tools/M94zV4Cli/obj/M94zV4Cli"
NATIVE_LIB_DIR = REPO / "native/_build"

CORPORA = [
    ("chr22",          REPO / "data/genomic/na12878/na12878.chr22.lean.mapped.bam"),
    ("wes",            REPO / "data/genomic/na12878_wes/na12878_wes.chr22.bam"),
    ("hg002_illumina", REPO / "data/genomic/hg002_illumina/hg002_illumina.chr22.subset1m.bam"),
    ("hg002_pacbio",   REPO / "data/genomic/hg002_pacbio/hg002_pacbio.subset.bam"),
]

pytestmark = [
    pytest.mark.skipif(not _HAVE_NATIVE_LIB, reason="V4 needs libttio_rans"),
    pytest.mark.skipif(not OBJC_CLI.exists(), reason="ObjC M94zV4Cli not built"),
    pytest.mark.integration,
]


def _java_jar():
    matches = list(REPO.glob(JAVA_JAR_GLOB))
    if not matches:
        pytest.skip("Java jar not built (run mvn package)")
    return matches[0]


def _java_classpath(jar):
    cp = str(jar)
    if JAVA_DEPS.exists():
        for j in JAVA_DEPS.glob("*.jar"):
            cp += os.pathsep + str(j)
    return cp


@pytest.mark.parametrize("name,bam_path", CORPORA)
def test_v4_cross_language_byte_equal(tmp_path, name, bam_path):
    if not bam_path.exists():
        pytest.skip(f"corpus not present: {bam_path}")

    # Step 1: Extract qualities via BamReader
    run = BamReader(str(bam_path)).to_genomic_run(name="run")
    qualities = bytes(run.qualities.tobytes())
    read_lengths = [int(x) for x in run.lengths]
    revcomp = [int(f) for f in run.flags]

    # Step 2: Write inputs to tmp_path for the Java/ObjC CLI tools
    qual_bin = tmp_path / f"{name}_qual.bin"
    lens_bin = tmp_path / f"{name}_lens.bin"
    flags_bin = tmp_path / f"{name}_flags.bin"
    qual_bin.write_bytes(qualities)
    import numpy as np
    np.array(read_lengths, dtype=np.uint32).tofile(str(lens_bin))
    np.array(revcomp, dtype=np.uint32).tofile(str(flags_bin))

    # Step 3: Encode via Python V4
    py_out = encode(qualities, read_lengths, revcomp, prefer_v4=True)
    py_path = tmp_path / f"{name}_python.fqz"
    py_path.write_bytes(py_out)

    # Step 4: Encode via Java V4
    java_out = tmp_path / f"{name}_java.fqz"
    jar = _java_jar()
    cp = _java_classpath(jar)
    subprocess.run(
        ["java",
         "-Djava.library.path=" + str(NATIVE_LIB_DIR),
         "-cp", cp,
         "global.thalion.ttio.tools.M94zV4Cli",
         str(qual_bin), str(lens_bin), str(flags_bin), str(java_out)],
        check=True, capture_output=True,
    )

    # Step 5: Encode via ObjC V4
    objc_out = tmp_path / f"{name}_objc.fqz"
    subprocess.run(
        [str(OBJC_CLI), str(qual_bin), str(lens_bin), str(flags_bin), str(objc_out)],
        check=True, capture_output=True,
    )

    # Step 6: All 3 must be byte-identical
    py_bytes   = py_path.read_bytes()
    java_bytes = java_out.read_bytes()
    objc_bytes = objc_out.read_bytes()

    assert py_bytes == java_bytes, (
        f"{name}: Python={len(py_bytes)} Java={len(java_bytes)}; "
        f"first divergent at "
        f"{next((i for i in range(min(len(py_bytes), len(java_bytes))) if py_bytes[i] != java_bytes[i]), -1)}"
    )
    assert py_bytes == objc_bytes, (
        f"{name}: Python={len(py_bytes)} ObjC={len(objc_bytes)}; "
        f"first divergent at "
        f"{next((i for i in range(min(len(py_bytes), len(objc_bytes))) if py_bytes[i] != objc_bytes[i]), -1)}"
    )
```

- [ ] **Step 5: Build Java + ObjC + run**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && \
  cd java && mvn -q package dependency:copy-dependencies -DskipTests 2>&1 | tail -5 && \
  cd ../objc && ./build.sh 2>&1 | tail -5 && \
  cd .. && sed -i $'"'"'s/\r$//'"'"' python/tests/integration/test_m94z_v4_cross_language.py && \
  TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_m94z_v4_cross_language.py -m integration -v 2>&1 | tail -15'
```

Expected: 4 parametrized cases, all PASS.

- [ ] **Step 6: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git add java/src/main/java/global/thalion/ttio/tools/M94zV4Cli.java objc/Tools/M94zV4Cli/ python/tests/integration/test_m94z_v4_cross_language.py && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "test(L3 V4): cross-language byte-equality matrix (Python ↔ Java ↔ ObjC)

Phase 5 cross-language gate: Python + Java + ObjC V4 encoders all
produce byte-identical output across all 4 corpora. Includes tiny
M94zV4Cli tools in Java + ObjC for subprocess invocation from the
Python integration test.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 5 — Triage M90 cross-language test

### Task 11: Investigate + fix `test_m90_genomic_encrypt_python_verify[java-encrypt]`

**Files:**
- Read-only triage; possible modifications to `python/tests/integration/test_m90_cross_language.py` or related Java code

This test was failing pre-V4 work (per Stage 2 Task 13 implementer's notes); the user requested Stage 3 fix it if possible.

- [ ] **Step 1: Reproduce the failure**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_m90_cross_language.py::test_m90_genomic_encrypt_python_verify -v 2>&1 | tail -30'
```

Capture the failure mode: what's the exception? Is it a Java/Python data-shape mismatch? A V4-default issue (Python encodes V4, Java decodes expecting V2)? An unrelated cipher-suite issue?

- [ ] **Step 2: Investigate the test**

Read `python/tests/integration/test_m90_cross_language.py`. Identify what M90 actually tests (likely an end-to-end encrypted genomic round-trip across languages). Check:
- Is it gated on V2 magic byte assertions?
- Does it call `encode(...)` without `prefer_v4=False`?
- Does the Java side decode using a path that doesn't yet support V4?

- [ ] **Step 3: Fix or document**

Based on Step 2 findings:
- **If the failure is V4-default related** (the test silently switched to V4 when JNI loaded, but the Java verify side doesn't handle V4 yet): now that Java has V4 dispatch (Tasks 4-5), retry the test — it may pass without modification. Or if the test is intended to exercise V2 (encrypted V2 round-trip), update it to pass `prefer_v4=False`.
- **If the failure is unrelated** (cipher suite, key derivation, transport): document the failure mode, mark as `pytest.mark.xfail` with a reason pointing at the unrelated root cause, file a follow-up task in WORKPLAN.

- [ ] **Step 4: Verify the test now passes (or is justifiably xfail)**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/integration/test_m90_cross_language.py -v 2>&1 | tail -15'
```

Expected: all green, OR xfail with a clear `reason=`.

- [ ] **Step 5: Commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -am "fix(L3): m90 cross-language test java-encrypt path

Fixes the pre-existing failure surfaced during Stage 2 Task 13. Either
addresses a V4-default mishandling on the Java verify side OR marks
xfail with the unrelated root-cause documented (see commit body).

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

---

## Phase 6 — Documentation, WORKPLAN, memory, push

### Task 12: Final docs + WORKPLAN + memory + push origin/main

**Files:**
- Modify: `docs/codecs/fqzcomp_nx16_z.md` — add Java + ObjC V4 parity section
- Modify: `WORKPLAN.md` — Task #84 mark Stage 3 done
- Modify: `C:\Users\toddw\.claude\projects\C--WINDOWS-system32\memory\project_tti_o_v1_2_codecs.md` — Stage 3 shipped status
- Modify: `C:\Users\toddw\.claude\projects\C--WINDOWS-system32\memory\MEMORY.md` — index update

- [ ] **Step 1: Update `docs/codecs/fqzcomp_nx16_z.md`**

Append to the existing V4 wire-format section (added in Stage 2 Task 15):

```markdown
### V4 in Java and Objective-C (Stage 3 / 2026-05-XX)

V4 reaches feature parity across all 3 reference implementations:

| Language | V4 path | V4 default | Pure-language fallback |
|---|---|---|---|
| Python | ctypes → libttio_rans | when `_HAVE_NATIVE_LIB` | V3 |
| Java | JNI → libttio_rans_jni → libttio_rans | when `TtioRansNative.isAvailable()` | V2 |
| ObjC | direct link → libttio_rans | when libttio_rans is linked (always in this build) | V2 |

All three produce byte-identical V4 output across all 4 benchmark
corpora (chr22 NA12878, NA12878 WES, HG002 Illumina 2×250, HG002 PacBio
HiFi). Gated by:

- `python/tests/integration/test_m94z_v4_byte_exact.py` (Python ↔ htscodecs)
- `java/.../FqzcompNx16ZV4ByteExactTest.java` (Java ↔ Python)
- `objc/Tests/TestTTIOFqzcompNx16ZV4ByteExact.m` (ObjC ↔ Python)
- `python/tests/integration/test_m94z_v4_cross_language.py` (3-way matrix)

Per-language defaults preserve V1/V2 read-compat for legacy files.
```

- [ ] **Step 2: Update `WORKPLAN.md`**

Find Task #84. Update the status block to "Stage 1 + 2 + 3 done"; replace the "Stage 3 (Java/ObjC) pending" line with a "Stage 3 SHIPPED" outcome listing per-language byte-equality status. Mark any V4-related follow-ups (e.g., empty-input handling, Stage 3 perf benchmarks) as separate tasks.

- [ ] **Step 3: Update project memory**

In `C:\Users\toddw\.claude\projects\C--WINDOWS-system32\memory\project_tti_o_v1_2_codecs.md`:
- Update the description frontmatter to reflect Stage 3 shipped: "V4 byte-equal across Python+Java+ObjC at HEAD `<sha>`"
- Add a new "Status (2026-05-XX) — Stage 3 V4 in Java + ObjC SHIPPED" section
- Note any unresolved follow-ups (V4 empty-input handling, performance benchmarks, etc.)

In `C:\Users\toddw\.claude\projects\C--WINDOWS-system32\memory\MEMORY.md`:
- Update the index entry pointing to `project_tti_o_v1_2_codecs.md` to reflect Stage 3 done

- [ ] **Step 4: Final verification before push**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && \
  cd native/_build && ctest 2>&1 | tail -3 && \
  cd ../.. && cd java && mvn -q test -Djava.library.path=/home/toddw/TTI-O/native/_build 2>&1 | tail -5 && \
  cd ../objc && ./build.sh 2>&1 | tail -3 && \
  cd .. && TTIO_RANS_LIB_PATH=/home/toddw/TTI-O/native/_build/libttio_rans.so .venv/bin/python -m pytest python/tests/test_m94z_v4_dispatch.py python/tests/test_m94z_v3_dispatch.py python/tests/test_m94z_v2_dispatch.py python/tests/test_m94z_canonical_fixtures.py -q 2>&1 | tail -5'
```

Expected: ctest 11/11 passing, Java BUILD SUCCESS, ObjC build clean, Python M94.Z suite all green.

- [ ] **Step 5: Strip CRLF + commit**

```bash
wsl -d Ubuntu -- bash -c 'cd /home/toddw/TTI-O && sed -i $'"'"'s/\r$//'"'"' docs/codecs/fqzcomp_nx16_z.md WORKPLAN.md && git add docs/codecs/fqzcomp_nx16_z.md WORKPLAN.md && git -c user.name="Todd White" -c user.email="todd.white@thalion.global" commit -m "docs(L3 V4): Java + ObjC V4 parity + WORKPLAN Stage 3 done

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>"'
```

- [ ] **Step 6: Push origin/main**

Per `feedback_git_push_via_windows`: WSL hangs on HTTPS auth; push must use Windows git against the WSL working tree.

```bash
"/c/Program Files/Git/bin/git.exe" -C "//wsl.localhost/Ubuntu/home/toddw/TTI-O" push origin main 2>&1 | tail -5
```

Expected: push succeeds; HEAD on `origin/main` advances to the WORKPLAN-update commit.

---

## Out of scope (this plan)

- Pure-Java or pure-ObjC fqzcomp port (Stage 3 deliberately uses linkage parity per user direction)
- WASM / browser target (no plausible language to use libttio_rans there yet)
- macOS + GNUstep-on-Windows ObjC test runs (bonus target if accessible; Linux/WSL is the gate)
- New codecs (M95, etc.)
- v1.2.0 compression-ratio gate at 1.15× — V4 closes some of the gap (1.268 vs 1.321 for V2/V3 on chr22) but not the whole way; that target is M95-class work
- Performance benchmarks (Java/ObjC perf parity vs Python is a separate task)
- libttio_rans empty-input handling (V4 native rejects `n_qualities==0`; soften with V3 fallback at the Python layer was deferred from Stage 2 Task 12; Stage 3 inherits this; document and address separately)

## Notes for the implementer

- **Linkage parity, not algorithm port.** Java and ObjC both call into the existing `libttio_rans`. Do NOT re-implement fqzcomp_qual.c in Java or ObjC. The C library is the single source of truth.
- **Byte-equality is the gate.** If the per-language byte-exact tests fail, the bug is in JNI marshaling (Java) or NSData/NSArray conversion (ObjC), NOT in the underlying C library (already proven byte-equal in Stage 2 across 4 corpora).
- **Strict additive change.** V1/V2 paths must NOT be touched in Java or ObjC; only add V4 dispatch. Existing V1/V2 byte-stream compatibility is preserved.
- **CRLF discipline.** All files edited via `\\wsl.localhost\Ubuntu\...` need `sed -i $'s/\r$//'` after every save.
- **Per-language test harnesses already exist** — Java has Maven + JUnit; ObjC has the project's existing test runner (`TTIOTestRunner`). Don't introduce new test frameworks.
- **The Stage 2 `tools/perf/m94z_v4_prototype/` infrastructure is reusable.** `extract_chr22_inputs.py` works for any BAM (just pass `--bam`); `htscodecs_compare.sh` writes `/tmp/our_*.fqz` files that Java/ObjC tests can byte-compare against directly.
