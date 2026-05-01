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
