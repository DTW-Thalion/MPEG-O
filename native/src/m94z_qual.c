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
#include <pthread.h>
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

/* One auto-tune candidate: V4 (pm == NULL) or a seqctx parameter set. */
typedef struct {
    const uint8_t *qual_in; size_t n_qualities;
    const uint32_t *read_lengths; size_t n_reads;
    const uint8_t *flags; const uint8_t *seq_in;
    const ttio_seqctx_param *pm;
    uint8_t pad_count;
    size_t cap;
    uint8_t *stream; size_t len;
    int rc;
} m94z_cand;

static void *m94z_cand_run(void *arg)
{
    m94z_cand *c = (m94z_cand *)arg;
    c->len = c->cap;
    if (c->pm == NULL) {
        c->rc = ttio_m94z_v4_encode(c->qual_in, c->n_qualities, c->read_lengths,
                                    c->n_reads, c->flags, -1, c->pad_count,
                                    c->stream, &c->len);
    } else {
        uint8_t *body = malloc(c->cap ? c->cap : 1);
        if (!body) { c->rc = TTIO_SEQCTX_ERR_OOM; return NULL; }
        c->rc = encode_v5_candidate(c->qual_in, c->n_qualities, c->read_lengths,
                                    c->n_reads, c->seq_in, c->pm, c->pad_count,
                                    body, c->cap, c->stream, &c->len);
        free(body);
    }
    return NULL;
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

    /* A fixed hint (0..4), or auto-tune without sequences or on a small
     * block: V4 alone. */
    if (strategy_hint != -1 || !seq_in || n_qualities < TTIO_M94Z_V5_MIN_QUALITIES) {
        size_t v4_len = cap;
        int rc = ttio_m94z_v4_encode(qual_in, n_qualities, read_lengths,
                                     n_reads, flags, strategy_hint,
                                     pad_count, out, &v4_len);
        if (rc != 0) return rc;
        *out_len = v4_len;
        return 0;
    }

    /* Auto-tune: V4, S5 and S6 are independent encodes of the same block
     * and each takes about the same time, so they run on three threads and
     * the smallest stream wins; ties go to the earlier candidate (V4, S5,
     * S6), the order the sequential loop used, so the output is the byte
     * sequence the sequential auto-tune produced. TTIO_M94Z_SEQUENTIAL=1
     * runs them one after the other. */
    m94z_cand cand[3];
    memset(cand, 0, sizeof(cand));
    for (int i = 0; i < 3; i++) {
        cand[i].qual_in = qual_in; cand[i].n_qualities = n_qualities;
        cand[i].read_lengths = read_lengths; cand[i].n_reads = n_reads;
        cand[i].flags = flags; cand[i].seq_in = seq_in;
        cand[i].pad_count = pad_count; cand[i].cap = cap;
        cand[i].pm = i == 1 ? &TTIO_SEQCTX_S5 : i == 2 ? &TTIO_SEQCTX_S6 : NULL;
        cand[i].stream = malloc(cap ? cap : 1);
        cand[i].rc = -1;
        if (!cand[i].stream) {
            for (int j = 0; j <= i; j++) free(cand[j].stream);
            return TTIO_SEQCTX_ERR_OOM;
        }
    }
    const char *seq_env = getenv("TTIO_M94Z_SEQUENTIAL");
    int sequential = seq_env && seq_env[0] == '1';
    pthread_t th[3];
    int started[3] = {0, 0, 0};
    for (int i = 0; i < 3; i++) {
        if (!sequential && pthread_create(&th[i], NULL, m94z_cand_run, &cand[i]) == 0) started[i] = 1;
        else m94z_cand_run(&cand[i]);
    }
    for (int i = 0; i < 3; i++) if (started[i]) pthread_join(th[i], NULL);
    if (cand[0].rc != 0) {  /* V4 is the reference path: its failure is the call's failure */
        int rc = cand[0].rc;
        for (int i = 0; i < 3; i++) free(cand[i].stream);
        return rc;
    }
    int best = 0;
    for (int i = 1; i < 3; i++)
        if (cand[i].rc == 0 && cand[i].len < cand[best].len) best = i;
    memcpy(out, cand[best].stream, cand[best].len);
    *out_len = cand[best].len;
    for (int i = 0; i < 3; i++) free(cand[i].stream);
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
