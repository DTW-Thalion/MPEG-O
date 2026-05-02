/* native/src/m94z_v4_wire.c
 *
 * Implementation of the M94.Z V4 outer wire format (see header for
 * spec) plus the top-level ttio_m94z_v4_encode/decode entry points
 * that compose pack/unpack with ttio_fqzcomp_qual_compress/uncompress.
 */
#include "m94z_v4_wire.h"
#include "fqzcomp_qual.h"

#include <stdlib.h>
#include <string.h>
#include <zlib.h>

#include "../include/ttio_rans.h"

/* RLT compression: deflate the read_lengths array as raw LE uint32. */
static int compress_rlt(const uint32_t *read_lengths, size_t n_reads,
                         uint8_t *out, size_t *out_len) {
    uLongf dst = (uLongf)(*out_len);
    int rc = compress2(out, &dst,
                        (const Bytef *)read_lengths,
                        (uLong)(n_reads * sizeof(uint32_t)),
                        9);
    if (rc != Z_OK) return -1;
    *out_len = (size_t)dst;
    return 0;
}

static int decompress_rlt(const uint8_t *in, size_t in_len,
                            uint32_t *out, size_t n_reads) {
    uLongf dst = (uLongf)(n_reads * sizeof(uint32_t));
    int rc = uncompress((Bytef *)out, &dst, in, (uLong)in_len);
    if (rc != Z_OK) return -1;
    if (dst != (uLongf)(n_reads * sizeof(uint32_t))) return -2;
    return 0;
}

int ttio_m94z_v4_pack(
    uint64_t num_qualities, uint64_t num_reads,
    const uint32_t *read_lengths,
    uint8_t pad_count,
    const uint8_t *cram_body, size_t cram_body_len,
    uint8_t *out, size_t *out_len)
{
    if (out == NULL || out_len == NULL) return -1;
    if (cram_body == NULL && cram_body_len > 0) return -1;
    if (read_lengths == NULL && num_reads > 0) return -1;

    /* Compress RLT into a scratch buffer. zlib upper bound for
     * compress2 input of size N is N + N/1000 + 12, plus a safety
     * margin for very small inputs. */
    size_t raw = (size_t)num_reads * sizeof(uint32_t);
    size_t rlt_cap = raw + (raw / 1000) + 64;
    uint8_t *rlt = (uint8_t *)malloc(rlt_cap == 0 ? 1 : rlt_cap);
    if (!rlt) return -2;
    size_t rlt_len = rlt_cap;
    if (compress_rlt(read_lengths, (size_t)num_reads, rlt, &rlt_len) != 0) {
        free(rlt);
        return -3;
    }

    /* Total = 30 + rlt_len + cram_body_len. */
    size_t need = (size_t)30 + rlt_len + cram_body_len;
    if (*out_len < need) {
        free(rlt);
        return -4;
    }

    /* Outer header. */
    memcpy(out, TTIO_M94Z_V4_MAGIC, 4);
    out[4] = TTIO_M94Z_V4_VERSION;
    /* flags: bit 0 = has_cram_body (must be 1); bits 4-5 = pad_count */
    out[5] = (uint8_t)(0x01u | ((pad_count & 0x3u) << 4));
    memcpy(out + 6,  &num_qualities, 8);
    memcpy(out + 14, &num_reads,     8);
    uint32_t rlt32 = (uint32_t)rlt_len;
    memcpy(out + 22, &rlt32, 4);
    memcpy(out + 26, rlt, rlt_len);
    uint32_t cram32 = (uint32_t)cram_body_len;
    memcpy(out + 26 + rlt_len, &cram32, 4);
    if (cram_body_len > 0) {
        memcpy(out + 30 + rlt_len, cram_body, cram_body_len);
    }
    *out_len = need;
    free(rlt);
    return 0;
}

int ttio_m94z_v4_unpack(
    const uint8_t *in, size_t in_len,
    uint64_t *out_nq, uint64_t *out_nr,
    uint32_t *out_rl,
    uint8_t  *out_pad,
    const uint8_t **out_body, size_t *out_body_len)
{
    if (in == NULL || in_len < 30) return -1;
    if (memcmp(in, TTIO_M94Z_V4_MAGIC, 4) != 0) return -2;
    if (in[4] != TTIO_M94Z_V4_VERSION) return -3;
    uint8_t flags = in[5];
    if (!(flags & 0x01u)) return -4; /* has_cram_body must be set */
    if (out_pad) *out_pad = (uint8_t)((flags >> 4) & 0x3u);
    uint64_t nq, nr;
    memcpy(&nq, in + 6,  8);
    memcpy(&nr, in + 14, 8);
    if (out_nq) *out_nq = nq;
    if (out_nr) *out_nr = nr;

    uint32_t rlt_len;
    memcpy(&rlt_len, in + 22, 4);
    if (in_len < (size_t)26 + (size_t)rlt_len + 4) return -5;
    if (nr > 0) {
        if (out_rl == NULL) return -6;
        if (decompress_rlt(in + 26, (size_t)rlt_len, out_rl, (size_t)nr) != 0) {
            return -7;
        }
    }
    uint32_t cram_len;
    memcpy(&cram_len, in + 26 + rlt_len, 4);
    if (in_len < (size_t)30 + (size_t)rlt_len + (size_t)cram_len) return -8;
    if (out_body)     *out_body     = in + 30 + rlt_len;
    if (out_body_len) *out_body_len = (size_t)cram_len;
    return 0;
}

/* ---------------------------------------------------------------- */
/* Top-level entry points: encode/decode in a single call.          */
/* These are declared in include/ttio_rans.h so the codec layers    */
/* (Python ctypes, JNI, ObjC) can dispatch on version == 4.         */
/* ---------------------------------------------------------------- */

int ttio_m94z_v4_encode(
    const uint8_t  *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t         pad_count,
    uint8_t        *out, size_t *out_len)
{
    if (out == NULL || out_len == NULL) return -1;

    /* Encode the inner CRAM body. Conservative cap: 2x input + 1KiB
     * for the parameter header + small-input slack. */
    size_t cram_cap = n_qualities * 2 + 1024;
    uint8_t *cram_body = (uint8_t *)malloc(cram_cap == 0 ? 1 : cram_cap);
    if (!cram_body) return -2;
    size_t cram_len = cram_cap;
    int rc = ttio_fqzcomp_qual_compress(qual_in, n_qualities,
                                          read_lengths, n_reads, flags,
                                          strategy_hint,
                                          cram_body, &cram_len);
    if (rc != 0) {
        free(cram_body);
        return -3;
    }

    /* Wrap with outer V4 header. */
    rc = ttio_m94z_v4_pack((uint64_t)n_qualities, (uint64_t)n_reads,
                            read_lengths, pad_count,
                            cram_body, cram_len, out, out_len);
    free(cram_body);
    return rc;
}

int ttio_m94z_v4_decode(
    const uint8_t *in, size_t in_len,
    uint32_t *read_lengths, size_t n_reads,
    const uint8_t *flags,
    uint8_t *out_qual, size_t n_qualities)
{
    uint64_t nq = 0, nr = 0;
    uint8_t pad = 0;
    const uint8_t *body = NULL;
    size_t body_len = 0;
    int rc = ttio_m94z_v4_unpack(in, in_len, &nq, &nr,
                                   read_lengths, &pad,
                                   &body, &body_len);
    if (rc != 0) return rc;
    if (nq != (uint64_t)n_qualities || nr != (uint64_t)n_reads) return -10;
    return ttio_fqzcomp_qual_uncompress(body, body_len,
                                          read_lengths, n_reads, flags,
                                          out_qual, n_qualities);
}
