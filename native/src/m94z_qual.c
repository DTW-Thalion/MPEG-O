/* native/src/m94z_qual.c
 *
 * Umbrella qualities encode/decode across the M94.Z flavors.
 *
 * Encode auto-tunes over the V4 presets (via ttio_m94z_v4_encode)
 * plus the S5/S6 sequence-context strategies and keeps the smallest
 * stream by exact size; ties go to V4 (compatibility wins at equal
 * size). S5/S6 are tried only when sequences are supplied and the
 * channel is at least TTIO_M94Z_V5_MIN_QUALITIES bytes; forced hints
 * 5/6 bypass the floor but still require sequences.
 *
 * Decode dispatches on the version byte at offset 4: version 4 goes
 * to ttio_m94z_v4_decode (sequences ignored), version 5 unpacks the
 * outer wire and decodes the seqctx body (sequences required).
 */
#include <stdlib.h>
#include <string.h>

#include "../include/ttio_rans.h"
#include "fqzcomp_seqctx.h"
#include "m94z_v4_wire.h"

static int encode_v5_candidate(
    const uint8_t *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t *seq_in, const ttio_seqctx_param *pm,
    uint8_t pad_count,
    uint8_t *scratch_body, size_t body_cap,
    uint8_t *scratch_stream, size_t *stream_len)
{
    size_t body_len = body_cap;
    int rc = ttio_fqz_seqctx_compress(qual_in, n_qualities,
                                      read_lengths, n_reads, seq_in,
                                      pm, scratch_body, &body_len);
    if (rc != 0) return rc;
    return ttio_m94z_v5_pack((uint64_t)n_qualities, (uint64_t)n_reads,
                             read_lengths, pad_count,
                             scratch_body, body_len,
                             scratch_stream, stream_len);
}

int ttio_m94z_qual_encode(
    const uint8_t  *qual_in, size_t n_qualities,
    const uint32_t *read_lengths, size_t n_reads,
    const uint8_t  *flags, const uint8_t *seq_in,
    int strategy_hint, uint8_t pad_count,
    uint8_t *out, size_t *out_len)
{
    if (!out || !out_len) return -1;
    const size_t cap = *out_len;

    if (strategy_hint == 5 || strategy_hint == 6) {
        if (!seq_in) return TTIO_SEQCTX_ERR_NO_SEQ;
        const ttio_seqctx_param *pm =
            strategy_hint == 5 ? &TTIO_SEQCTX_S5 : &TTIO_SEQCTX_S6;
        uint8_t *body = malloc(cap ? cap : 1);
        if (!body) return TTIO_SEQCTX_ERR_OOM;
        size_t stream_len = cap;
        int rc = encode_v5_candidate(qual_in, n_qualities,
                                     read_lengths, n_reads, seq_in, pm,
                                     pad_count, body, cap, out,
                                     &stream_len);
        free(body);
        if (rc != 0) return rc;
        *out_len = stream_len;
        return 0;
    }

    /* V4 first (hint -1 or 0..4 passes straight through). */
    size_t v4_len = cap;
    int rc = ttio_m94z_v4_encode(qual_in, n_qualities, read_lengths,
                                 n_reads, flags, strategy_hint,
                                 pad_count, out, &v4_len);
    if (rc != 0) return rc;
    *out_len = v4_len;

    if (strategy_hint != -1) return 0;
    if (!seq_in) return 0;
    if (n_qualities < TTIO_M94Z_V5_MIN_QUALITIES) return 0;

    uint8_t *body = malloc(cap);
    uint8_t *stream = malloc(cap);
    if (!body || !stream) { free(body); free(stream); return 0; }

    const ttio_seqctx_param *cands[2] = { &TTIO_SEQCTX_S5,
                                          &TTIO_SEQCTX_S6 };
    for (int c = 0; c < 2; c++) {
        size_t stream_len = cap;
        if (encode_v5_candidate(qual_in, n_qualities, read_lengths,
                                n_reads, seq_in, cands[c], pad_count,
                                body, cap, stream, &stream_len) != 0)
            continue;
        if (stream_len < *out_len) {
            memcpy(out, stream, stream_len);
            *out_len = stream_len;
        }
    }
    free(body);
    free(stream);
    return 0;
}

int ttio_m94z_qual_decode(
    const uint8_t *in, size_t in_len,
    uint32_t *read_lengths, size_t n_reads,
    const uint8_t *flags, const uint8_t *seq_in,
    uint8_t *out_qual, size_t n_qualities)
{
    if (!in || in_len < 5) return -1;
    if (in[4] == TTIO_M94Z_V5_WIRE_VERSION) {
        uint64_t nq = 0, nr = 0;
        uint8_t pad = 0;
        const uint8_t *body = NULL;
        size_t body_len = 0;
        int rc = ttio_m94z_v5_unpack(in, in_len, &nq, &nr, read_lengths,
                                     &pad, &body, &body_len);
        if (rc != 0) return rc;
        if (nq != (uint64_t)n_qualities || nr != (uint64_t)n_reads)
            return TTIO_SEQCTX_ERR_ARGS;
        if (!seq_in) return TTIO_SEQCTX_ERR_NO_SEQ;
        return ttio_fqz_seqctx_uncompress(body, body_len, read_lengths,
                                          n_reads, seq_in, out_qual,
                                          n_qualities);
    }
    (void)seq_in;
    return ttio_m94z_v4_decode(in, in_len, read_lengths, n_reads,
                               flags, out_qual, n_qualities);
}
