/*
 * ttio_rans_jni.c -- JNI wrappers for global.thalion.ttio.codecs.TtioRansNative.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 *
 * Marshalling notes:
 *   - Java byte[]/short[] are read via Get<Byte|Short>ArrayElements and
 *     reinterpret-cast to uint8_t and uint16_t respectively. The bit patterns
 *     are identical, so the cast is safe.
 *   - Java int[][] freq/cum is an array of arrays (not contiguous), so we
 *     copy into a flat C uint32_t[n][256] block. Released on every error path.
 *   - We do NOT throw Java exceptions; errors are reported via the int
 *     return code (matching the C API contract). Callers in Java check the
 *     return.
 *   - The decode wrapper builds the dtab itself via
 *     ttio_rans_build_decode_table so callers don't have to round-trip the
 *     lookup table through Java arrays.
 */

#include <jni.h>
#include <stdlib.h>
#include <string.h>
#include "ttio_rans.h"

/* Copy a Java int[][] freq/cum table (shape [n_contexts][256]) into a freshly
 * allocated flat C uint32_t[n_contexts][256] block. Caller must free(). */
static int copy_table_2d(
    JNIEnv *env, jobjectArray src,
    uint32_t (**out)[256], jsize *n_contexts_out)
{
    jsize n = (*env)->GetArrayLength(env, src);
    if (n <= 0) {
        *out = NULL;
        *n_contexts_out = 0;
        return TTIO_RANS_ERR_PARAM;
    }
    uint32_t (*tbl)[256] = (uint32_t (*)[256])calloc((size_t)n, sizeof(*tbl));
    if (!tbl) return TTIO_RANS_ERR_ALLOC;

    for (jsize c = 0; c < n; c++) {
        jintArray row = (jintArray)(*env)->GetObjectArrayElement(env, src, c);
        if (!row) {
            free(tbl);
            return TTIO_RANS_ERR_PARAM;
        }
        jsize row_len = (*env)->GetArrayLength(env, row);
        if (row_len != 256) {
            (*env)->DeleteLocalRef(env, row);
            free(tbl);
            return TTIO_RANS_ERR_PARAM;
        }
        jint *row_data = (*env)->GetIntArrayElements(env, row, NULL);
        if (!row_data) {
            (*env)->DeleteLocalRef(env, row);
            free(tbl);
            return TTIO_RANS_ERR_ALLOC;
        }
        for (int s = 0; s < 256; s++) {
            tbl[c][s] = (uint32_t)row_data[s];
        }
        (*env)->ReleaseIntArrayElements(env, row, row_data, JNI_ABORT);
        (*env)->DeleteLocalRef(env, row);
    }

    *out = tbl;
    *n_contexts_out = n;
    return TTIO_RANS_OK;
}

JNIEXPORT jint JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_encodeBlock(
    JNIEnv *env, jclass clazz,
    jbyteArray symbolsJ, jshortArray contextsJ, jint nContexts,
    jobjectArray freqJ, jbyteArray outJ, jintArray outLenJ)
{
    (void)clazz;

    if (!symbolsJ || !contextsJ || !freqJ || !outJ || !outLenJ) {
        return TTIO_RANS_ERR_PARAM;
    }

    uint32_t (*freq)[256] = NULL;
    jsize freq_n = 0;
    int rc = copy_table_2d(env, freqJ, &freq, &freq_n);
    if (rc != TTIO_RANS_OK) {
        return rc;
    }
    if ((jint)freq_n != nContexts) {
        free(freq);
        return TTIO_RANS_ERR_PARAM;
    }

    jsize n_symbols = (*env)->GetArrayLength(env, symbolsJ);
    jsize n_contexts_arr = (*env)->GetArrayLength(env, contextsJ);
    if (n_contexts_arr != n_symbols) {
        free(freq);
        return TTIO_RANS_ERR_PARAM;
    }

    jbyte  *sym_data = (*env)->GetByteArrayElements(env, symbolsJ, NULL);
    if (!sym_data) {
        free(freq);
        return TTIO_RANS_ERR_ALLOC;
    }
    jshort *ctx_data = (*env)->GetShortArrayElements(env, contextsJ, NULL);
    if (!ctx_data) {
        (*env)->ReleaseByteArrayElements(env, symbolsJ, sym_data, JNI_ABORT);
        free(freq);
        return TTIO_RANS_ERR_ALLOC;
    }
    jbyte *out_data = (*env)->GetByteArrayElements(env, outJ, NULL);
    if (!out_data) {
        (*env)->ReleaseByteArrayElements(env, symbolsJ, sym_data, JNI_ABORT);
        (*env)->ReleaseShortArrayElements(env, contextsJ, ctx_data, JNI_ABORT);
        free(freq);
        return TTIO_RANS_ERR_ALLOC;
    }
    jsize out_cap = (*env)->GetArrayLength(env, outJ);

    /* Read in/out length from outLenJ[0]. */
    jint out_len_in = 0;
    (*env)->GetIntArrayRegion(env, outLenJ, 0, 1, &out_len_in);
    size_t out_len = (size_t)((out_len_in > 0 && out_len_in <= out_cap)
                              ? out_len_in : out_cap);

    rc = ttio_rans_encode_block(
        (const uint8_t *)sym_data,
        (const uint16_t *)ctx_data,
        (size_t)n_symbols,
        (uint16_t)nContexts,
        (const uint32_t (*)[256])freq,
        (uint8_t *)out_data,
        &out_len
    );

    /* Release input arrays first (no copyback). */
    (*env)->ReleaseByteArrayElements(env, symbolsJ, sym_data, JNI_ABORT);
    (*env)->ReleaseShortArrayElements(env, contextsJ, ctx_data, JNI_ABORT);

    if (rc == TTIO_RANS_OK) {
        /* Copy output bytes back to Java; writeback length. */
        (*env)->ReleaseByteArrayElements(env, outJ, out_data, 0);
        jint out_len_out = (jint)out_len;
        (*env)->SetIntArrayRegion(env, outLenJ, 0, 1, &out_len_out);
    } else {
        (*env)->ReleaseByteArrayElements(env, outJ, out_data, JNI_ABORT);
    }

    free(freq);
    return rc;
}

JNIEXPORT jint JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_decodeBlock(
    JNIEnv *env, jclass clazz,
    jbyteArray compressedJ, jshortArray contextsJ, jint nContexts,
    jobjectArray freqJ, jobjectArray cumJ,
    jbyteArray symbolsJ, jint nSymbols)
{
    (void)clazz;

    if (!compressedJ || !contextsJ || !freqJ || !cumJ || !symbolsJ) {
        return TTIO_RANS_ERR_PARAM;
    }

    uint32_t (*freq)[256] = NULL;
    uint32_t (*cum)[256] = NULL;
    uint8_t  (*dtab)[TTIO_RANS_T] = NULL;
    jsize freq_n = 0, cum_n = 0;
    int rc;

    rc = copy_table_2d(env, freqJ, &freq, &freq_n);
    if (rc != TTIO_RANS_OK) goto cleanup_tables;
    rc = copy_table_2d(env, cumJ, &cum, &cum_n);
    if (rc != TTIO_RANS_OK) goto cleanup_tables;
    if ((jint)freq_n != nContexts || (jint)cum_n != nContexts) {
        rc = TTIO_RANS_ERR_PARAM;
        goto cleanup_tables;
    }

    /* Build the decode table — cheaper than round-tripping it through Java. */
    dtab = (uint8_t (*)[TTIO_RANS_T])calloc((size_t)nContexts, TTIO_RANS_T);
    if (!dtab) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup_tables; }
    rc = ttio_rans_build_decode_table(
        (uint16_t)nContexts,
        (const uint32_t (*)[256])freq,
        (const uint32_t (*)[256])cum,
        dtab);
    if (rc != TTIO_RANS_OK) goto cleanup_tables;

    jsize comp_len_arr = (*env)->GetArrayLength(env, compressedJ);
    jsize n_contexts_arr = (*env)->GetArrayLength(env, contextsJ);
    jsize sym_cap = (*env)->GetArrayLength(env, symbolsJ);
    if ((jint)n_contexts_arr < nSymbols || (jint)sym_cap < nSymbols) {
        rc = TTIO_RANS_ERR_PARAM;
        goto cleanup_tables;
    }

    jbyte  *comp_data = (*env)->GetByteArrayElements(env, compressedJ, NULL);
    if (!comp_data) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup_tables; }
    jshort *ctx_data = (*env)->GetShortArrayElements(env, contextsJ, NULL);
    if (!ctx_data) {
        (*env)->ReleaseByteArrayElements(env, compressedJ, comp_data, JNI_ABORT);
        rc = TTIO_RANS_ERR_ALLOC;
        goto cleanup_tables;
    }
    jbyte  *sym_data = (*env)->GetByteArrayElements(env, symbolsJ, NULL);
    if (!sym_data) {
        (*env)->ReleaseByteArrayElements(env, compressedJ, comp_data, JNI_ABORT);
        (*env)->ReleaseShortArrayElements(env, contextsJ, ctx_data, JNI_ABORT);
        rc = TTIO_RANS_ERR_ALLOC;
        goto cleanup_tables;
    }

    rc = ttio_rans_decode_block(
        (const uint8_t *)comp_data,
        (size_t)comp_len_arr,
        (const uint16_t *)ctx_data,
        (uint16_t)nContexts,
        (const uint32_t (*)[256])freq,
        (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        (uint8_t *)sym_data,
        (size_t)nSymbols);

    /* Release inputs without copyback. */
    (*env)->ReleaseByteArrayElements(env, compressedJ, comp_data, JNI_ABORT);
    (*env)->ReleaseShortArrayElements(env, contextsJ, ctx_data, JNI_ABORT);
    /* Release output WITH copyback (mode 0) on success; abort on failure. */
    (*env)->ReleaseByteArrayElements(env, symbolsJ, sym_data,
                                     rc == TTIO_RANS_OK ? 0 : JNI_ABORT);

cleanup_tables:
    free(freq);
    free(cum);
    free(dtab);
    return rc;
}

JNIEXPORT jstring JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_kernelName(
    JNIEnv *env, jclass clazz)
{
    (void)clazz;
    const char *name = ttio_rans_kernel_name();
    if (!name) name = "unknown";
    return (*env)->NewStringUTF(env, name);
}

/* ── Streaming decode (Task 26c) ─────────────────────────────────── */

/*
 * Per-callback bridge state.  Lives on the JNI stack frame for the
 * duration of one decodeBlockStreaming() call.  The C callback uses
 * the cached env/resolver/method so per-symbol overhead is one
 * CallIntMethod plus one ExceptionCheck.
 *
 * Performance reality (Task 26c): JNI CallIntMethod from a per-symbol
 * C callback is much heavier than ctypes CFUNCTYPE dispatch in Python
 * (which itself was a wash with pure-Python in Task 26b).  The streaming
 * path is therefore expected to be SLOWER than pure-Java decode for
 * realistic block sizes.  This binding ships as infrastructure: it
 * proves the streaming C API is wired end-to-end and sets up future
 * fully-C context derivation (where the callback overhead disappears).
 */
typedef struct {
    JNIEnv   *env;
    jobject   resolver;
    jmethodID resolve_mid;
    int       error;        /* set non-zero if Java callback threw */
} jni_streaming_ctx;

static uint16_t jni_streaming_resolver(void *user_data, size_t i, uint8_t prev_sym) {
    jni_streaming_ctx *ctx = (jni_streaming_ctx *)user_data;
    if (ctx->error) return 0;  /* short-circuit after first error */
    JNIEnv *env = ctx->env;
    jint result = (*env)->CallIntMethod(env, ctx->resolver, ctx->resolve_mid,
                                         (jlong)i, (jint)(unsigned int)prev_sym);
    if ((*env)->ExceptionCheck(env)) {
        /* Don't clear; let the JNI return path propagate.  Mark the ctx
         * so subsequent callbacks short-circuit and let the streaming
         * decoder unwind quickly. */
        ctx->error = 1;
        return 0;
    }
    return (uint16_t)result;
}

JNIEXPORT jint JNICALL
Java_global_thalion_ttio_codecs_TtioRansNative_decodeBlockStreaming(
    JNIEnv *env, jclass clazz,
    jbyteArray compressedJ, jint nContexts,
    jobjectArray freqJ, jobjectArray cumJ,
    jbyteArray symbolsJ, jint nSymbols,
    jobject resolverObj)
{
    (void)clazz;

    if (!compressedJ || !freqJ || !cumJ || !symbolsJ || !resolverObj) {
        return TTIO_RANS_ERR_PARAM;
    }

    uint32_t (*freq)[256] = NULL;
    uint32_t (*cum)[256] = NULL;
    uint8_t  (*dtab)[TTIO_RANS_T] = NULL;
    jsize freq_n = 0, cum_n = 0;
    int rc;

    rc = copy_table_2d(env, freqJ, &freq, &freq_n);
    if (rc != TTIO_RANS_OK) goto cleanup_tables;
    rc = copy_table_2d(env, cumJ, &cum, &cum_n);
    if (rc != TTIO_RANS_OK) goto cleanup_tables;
    if ((jint)freq_n != nContexts || (jint)cum_n != nContexts) {
        rc = TTIO_RANS_ERR_PARAM;
        goto cleanup_tables;
    }

    dtab = (uint8_t (*)[TTIO_RANS_T])calloc((size_t)nContexts, TTIO_RANS_T);
    if (!dtab) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup_tables; }
    rc = ttio_rans_build_decode_table(
        (uint16_t)nContexts,
        (const uint32_t (*)[256])freq,
        (const uint32_t (*)[256])cum,
        dtab);
    if (rc != TTIO_RANS_OK) goto cleanup_tables;

    /* Resolve the callback method id once: ContextResolver.resolve(JI)I */
    jclass resolverCls = (*env)->GetObjectClass(env, resolverObj);
    if (!resolverCls) { rc = TTIO_RANS_ERR_PARAM; goto cleanup_tables; }
    jmethodID resolveMid = (*env)->GetMethodID(env, resolverCls, "resolve", "(JI)I");
    (*env)->DeleteLocalRef(env, resolverCls);
    if (!resolveMid) {
        if ((*env)->ExceptionCheck(env)) (*env)->ExceptionClear(env);
        rc = TTIO_RANS_ERR_PARAM;
        goto cleanup_tables;
    }

    jsize comp_len_arr = (*env)->GetArrayLength(env, compressedJ);
    jsize sym_cap = (*env)->GetArrayLength(env, symbolsJ);
    if ((jint)sym_cap < nSymbols) {
        rc = TTIO_RANS_ERR_PARAM;
        goto cleanup_tables;
    }

    jbyte *comp_data = (*env)->GetByteArrayElements(env, compressedJ, NULL);
    if (!comp_data) { rc = TTIO_RANS_ERR_ALLOC; goto cleanup_tables; }
    jbyte *sym_data = (*env)->GetByteArrayElements(env, symbolsJ, NULL);
    if (!sym_data) {
        (*env)->ReleaseByteArrayElements(env, compressedJ, comp_data, JNI_ABORT);
        rc = TTIO_RANS_ERR_ALLOC;
        goto cleanup_tables;
    }

    jni_streaming_ctx jniCtx = { env, resolverObj, resolveMid, 0 };

    rc = ttio_rans_decode_block_streaming(
        (const uint8_t *)comp_data,
        (size_t)comp_len_arr,
        (uint16_t)nContexts,
        (const uint32_t (*)[256])freq,
        (const uint32_t (*)[256])cum,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        (uint8_t *)sym_data,
        (size_t)nSymbols,
        jni_streaming_resolver,
        &jniCtx);

    /* If the Java callback raised, surface that as ERR_PARAM.  The
     * pending exception will be visible to the Java caller on return. */
    if (jniCtx.error && rc == TTIO_RANS_OK) {
        rc = TTIO_RANS_ERR_PARAM;
    }

    (*env)->ReleaseByteArrayElements(env, compressedJ, comp_data, JNI_ABORT);
    (*env)->ReleaseByteArrayElements(env, symbolsJ, sym_data,
                                     rc == TTIO_RANS_OK ? 0 : JNI_ABORT);

cleanup_tables:
    free(freq);
    free(cum);
    free(dtab);
    return rc;
}

/* ----- V4 (CRAM 3.1 fqzcomp byte-compatible) JNI bindings ----- */

#include <stdio.h>  /* snprintf */

/*
 * Java_global_thalion_ttio_codecs_TtioRansNative_encodeV4Native
 *   ([B[I[III)[B
 *
 * Marshal Java arrays -> C uint8/uint32 buffers, call ttio_m94z_v4_encode,
 * marshal C output -> new Java byte[].
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
    /* lens_u32 -> jint copy (same width on LP64) */
    (*env)->SetIntArrayRegion(env, lensResult, 0, (jsize)numReads,
                                (const jint *)lens_u32);
    (*env)->SetObjectArrayElement(env, result, 1, lensResult);

    free(lens_u32);
    free(qual_out);
    return result;
}
