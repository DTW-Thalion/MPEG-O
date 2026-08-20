/* native/src/m94z_v6.c
 *
 * V6 single-chain qualities coder. Same sm_model + CRAM range coder
 * the V4 and V5 bodies use; only the context word differs, and the
 * chain covers one segment rather than a whole block.
 */
#include <pthread.h>
#include <stdlib.h>
#include <string.h>

#include "fqzcomp_seqctx.h"
#include "m94z_v4_wire.h"
#include "m94z_v6.h"
#include "rc_cram.h"
#include "ttio_engine.h"
#include "v6_model.h"

/* Fixed by the ratio sweep over the four reference corpora
 * (docs/codecs/m94z_v6.md section 6).
 *
 * C = Q + P + D = 11 is deliberately far below what V4 uses. V4 models
 * a whole 64 MiB block, so it can afford a large context space; a V6
 * segment is a few hundred thousand symbols, and spreading those over
 * 2^14 contexts leaves each one too sparse to learn. This is the split
 * whose worst corpus is best, and it beats every larger context space
 * measured while using a fraction of the memory.
 *
 * D = 1 rather than 0 or 2: one delta bit is what NovaSeq needs and
 * what the long-read corpora can spare. Dropping it costs NovaSeq
 * about 0.8 points, and a second bit costs the other three more than
 * it returns.
 *
 * The seed mass is flat between 256 and 384 and falls away sharply
 * above 4096, because a heavy prior stops the per-context model
 * adapting. qshift 7 discards quality history at Q = 6, which measures
 * better than retaining it on three of the four corpora. */
const ttio_v6_param TTIO_V6_DEFAULT = { 6, 7, 4, 4, 1, 256 };

#ifndef MIN
#  define MIN(a,b) ((a)<(b)?(a):(b))
#endif

#define V6_SEED_MAX 32768u

void ttio_v6_alphabet_build(const uint8_t *qual, size_t n_qualities,
                            unsigned seed_total, ttio_v6_alphabet *ab) {
    uint64_t count[256];
    memset(count, 0, sizeof count);
    for (size_t i = 0; i < n_qualities; i++) count[qual[i]]++;

    memset(ab->map, 0, sizeof ab->map);
    memset(ab->inv, 0, sizeof ab->inv);
    memset(ab->seed, 0, sizeof ab->seed);
    ab->n = 0;
    for (unsigned q = 0; q < 256; q++) {
        if (count[q]) {
            ab->map[q] = (uint8_t)ab->n;
            ab->inv[ab->n] = (uint8_t)q;
            ab->n++;
        }
    }
    if (ab->n == 0) {
        ab->n = 1;               /* an empty block still needs a model */
        ab->seed[0] = 1;
        ab->seed_total = 1;
        return;
    }

    if (seed_total < ab->n) seed_total = ab->n;
    if (seed_total > V6_SEED_MAX) seed_total = V6_SEED_MAX;

    /* Integer scaling, so encoder and decoder cannot disagree. Every
     * present symbol keeps at least 1 or it could not be coded. */
    ab->seed_total = 0;
    for (unsigned i = 0; i < ab->n; i++) {
        uint64_t c = count[ab->inv[i]];
        uint64_t w = (c * seed_total + n_qualities / 2) / n_qualities;
        if (w < 1) w = 1;
        if (w > 0xFFFFu) w = 0xFFFFu;
        ab->seed[i] = (uint16_t)w;
        ab->seed_total += (uint32_t)w;
    }

    /* Keep headroom under the model's normalisation threshold. */
    while (ab->seed_total > V6_SEED_MAX) {
        ab->seed_total = 0;
        for (unsigned i = 0; i < ab->n; i++) {
            ab->seed[i] = (uint16_t)(ab->seed[i] - (ab->seed[i] >> 1));
            if (ab->seed[i] == 0) ab->seed[i] = 1;
            ab->seed_total += ab->seed[i];
        }
    }
}

static int alphabet_valid(const ttio_v6_alphabet *ab) {
    if (!ab || ab->n < 1 || ab->n > 256) return 0;
    if (ab->seed_total < ab->n || ab->seed_total > V6_SEED_MAX) return 0;
    for (unsigned i = 0; i < ab->n; i++)
        if (ab->seed[i] == 0) return 0;
    return 1;
}

static int param_valid(const ttio_v6_param *pm) {
    if (!pm) return 0;
    if (pm->qshift > 8) return 0;
    if ((unsigned)pm->qbits + pm->pbits + pm->dbits > TTIO_V6_MAX_CTX_BITS)
        return 0;
    return 1;
}

static int lengths_sum(const uint32_t *lengths, size_t n_reads,
                       uint64_t *total) {
    uint64_t t = 0;
    for (size_t r = 0; r < n_reads; r++) t += lengths[r];
    *total = t;
    return 0;
}

/* Every segment starts from a cold model, so the per-context allocation
 * the V5 body does once per block would happen N times per block here.
 * One contiguous pool for the whole context array replaces n_ctx
 * callocs, and every context is seeded from the same prepared block. */
typedef struct {
    v6_model *models;
    uint16_t *pool;
} v6_models;

static int models_init(v6_models *vm, size_t n_ctx,
                       const ttio_v6_alphabet *ab) {
    const unsigned nsym = ab->n;
    const size_t   words = v6_model_words(nsym);

    vm->models = (v6_model *)malloc(n_ctx * sizeof(*vm->models));
    vm->pool = (uint16_t *)malloc(n_ctx * words * sizeof(*vm->pool));
    if (!vm->models || !vm->pool) {
        free(vm->models);
        free(vm->pool);
        vm->models = NULL;
        vm->pool = NULL;
        return TTIO_SEQCTX_ERR_OOM;
    }

    /* Build the first context, then copy it: the seeded state is the
     * same for every context, and a memcpy beats rebuilding the tree
     * n_ctx times. */
    v6_model_init(&vm->models[0], vm->pool, nsym, ab->seed);
    for (size_t c = 1; c < n_ctx; c++) {
        uint16_t *p = vm->pool + c * words;
        memcpy(p, vm->pool, words * sizeof(*p));
        vm->models[c].freq = p;
        vm->models[c].tree = p + nsym;
        vm->models[c].nsym = nsym;
        vm->models[c].tot = vm->models[0].tot;
    }
    return 0;
}

static void models_free(v6_models *vm) {
    free(vm->models);
    free(vm->pool);
    vm->models = NULL;
    vm->pool = NULL;
}

/* Shared coding loop. do_encode: qual is input and rc_e is active.
 * Otherwise qual is output and rc_d is active. */
static int code_pass(const ttio_v6_param *pm, const ttio_v6_alphabet *ab,
                     uint8_t *qual,
                     const uint32_t *lengths, size_t n_reads,
                     rc_cram_encoder *rc_e, rc_cram_decoder *rc_d,
                     int do_encode) {
    size_t   n_ctx = (size_t)1 << (pm->qbits + pm->pbits + pm->dbits);
    v6_models vm;
    int      rc = models_init(&vm, n_ctx, ab);
    if (rc != 0) return rc;

    const unsigned qmask = (1u << pm->qbits) - 1u;
    const unsigned pmax = (1u << pm->pbits) - 1u;
    const unsigned dmax = (1u << pm->dbits) - 1u;
    const int      ploc = pm->qbits;
    const int      dloc = pm->qbits + pm->pbits;

    size_t k = 0;
    for (size_t r = 0; r < n_reads; r++) {
        unsigned qctx = 0, qp = 0, qpp = 0;
        uint32_t len = lengths[r];
        for (uint32_t i = 0; i < len; i++, k++) {
            unsigned pos = MIN(pmax, (unsigned)((len - 1 - i) >> pm->pshift));
            unsigned d = 0;
            if (i >= 2) {
                unsigned ad = qp > qpp ? qp - qpp : qpp - qp;
                d = MIN(dmax, ad);
            }
            unsigned ctx = (qctx & qmask) | (pos << ploc) | (d << dloc);
            v6_model *mdl = &vm.models[ctx];
            unsigned  q;
            if (do_encode) {
                q = ab->map[qual[k]];
                rc_cram_encode(rc_e, v6_model_prefix(mdl, q),
                               v6_model_freq(mdl, q), mdl->tot);
            } else {
                unsigned target = rc_cram_decode_target(rc_d, mdl->tot);
                unsigned cf = 0;
                if (target >= mdl->tot) {
                    models_free(&vm);
                    return TTIO_SEQCTX_ERR_CORRUPT;
                }
                q = v6_model_find(mdl, target, &cf);
                if (q >= ab->n) {
                    models_free(&vm);
                    return TTIO_SEQCTX_ERR_CORRUPT;
                }
                rc_cram_decode_advance(rc_d, cf, v6_model_freq(mdl, q),
                                       mdl->tot);
                qual[k] = ab->inv[q];
            }
            v6_model_update(mdl, q);
            qctx = (qctx << pm->qshift) + q;
            qpp = qp;
            qp = q;
        }
    }

    models_free(&vm);
    return 0;
}

int ttio_v6_chain_encode(const ttio_v6_param *pm,
                         const ttio_v6_alphabet *ab,
                         const uint8_t *qual,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *out, size_t *out_len) {
    uint64_t n_qualities = 0;

    if (!param_valid(pm)) return TTIO_SEQCTX_ERR_PARAM;
    if (!alphabet_valid(ab)) return TTIO_SEQCTX_ERR_PARAM;
    if (!out || !out_len) return TTIO_SEQCTX_ERR_ARGS;
    if (n_reads > 0 && !lengths) return TTIO_SEQCTX_ERR_ARGS;
    lengths_sum(lengths, n_reads, &n_qualities);
    if (n_qualities > 0 && !qual) return TTIO_SEQCTX_ERR_ARGS;

    if (n_qualities == 0) {
        *out_len = 0;
        return 0;
    }

    rc_cram_encoder e;
    rc_cram_encoder_init(&e, out, *out_len);
    int rc = code_pass(pm, ab, (uint8_t *)qual, lengths, n_reads, &e, NULL, 1);
    if (rc != 0) return rc;
    size_t body = rc_cram_encoder_finish(&e);
    if (e.err != 0) return TTIO_SEQCTX_ERR_ARGS;
    *out_len = body;
    return 0;
}

int ttio_v6_chain_decode(const ttio_v6_param *pm,
                         const ttio_v6_alphabet *ab,
                         const uint8_t *in, size_t in_len,
                         const uint32_t *lengths, size_t n_reads,
                         uint8_t *qual_out, size_t n_qualities) {
    uint64_t total = 0;

    if (!param_valid(pm)) return TTIO_SEQCTX_ERR_PARAM;
    if (!alphabet_valid(ab)) return TTIO_SEQCTX_ERR_PARAM;
    if (n_qualities == 0) return 0;
    if (!in || !qual_out || !lengths) return TTIO_SEQCTX_ERR_ARGS;
    lengths_sum(lengths, n_reads, &total);
    if (total != (uint64_t)n_qualities) return TTIO_SEQCTX_ERR_ARGS;

    rc_cram_decoder d;
    rc_cram_decoder_init(&d, in, in_len);
    return code_pass(pm, ab, qual_out, lengths, n_reads, NULL, &d, 0);
}

/* ------------------------------------------------------------------ */
/* Segmented block coder                                              */
/* ------------------------------------------------------------------ */

#define V6_BODY_HDR 16

typedef struct {
    size_t   first_read;
    size_t   n_reads;
    uint64_t qual_off;
    uint64_t n_qual;
} v6_seg;

/* Segments hold whole reads: accumulate reads until the symbol count
 * reaches seg_symbols, then close at that read boundary. Determined by
 * the read lengths alone, so encoder and decoder agree without the
 * split being stored. Pass segs = NULL to count only. */
static size_t v6_plan(const uint32_t *lengths, size_t n_reads,
                      uint32_t seg_symbols, v6_seg *segs) {
    size_t   n = 0, r = 0;
    uint64_t off = 0;
    while (r < n_reads) {
        size_t   first = r;
        uint64_t acc = 0;
        while (r < n_reads && acc < (uint64_t)seg_symbols) {
            acc += lengths[r];
            r++;
        }
        if (segs) {
            segs[n].first_read = first;
            segs[n].n_reads = r - first;
            segs[n].qual_off = off;
            segs[n].n_qual = acc;
        }
        off += acc;
        n++;
    }
    return n;
}

typedef struct {
    const ttio_v6_param    *pm;
    const ttio_v6_alphabet *ab;
    const v6_seg           *segs;
    size_t               n_segs;
    const uint32_t      *lengths;
    uint8_t            **bufs;
    size_t              *lens;
    int                 *errs;
    const uint8_t       *qual_in;
    uint8_t             *qual_out;
    int                  do_encode;
    size_t               next;
    pthread_mutex_t      mu;
} v6_job;

static void v6_run_one(v6_job *j, size_t i) {
    const v6_seg *s = &j->segs[i];
    if (j->do_encode) {
        size_t cap = j->lens[i];
        j->errs[i] = ttio_v6_chain_encode(j->pm, j->ab,
                                          j->qual_in + s->qual_off,
                                          j->lengths + s->first_read,
                                          s->n_reads, j->bufs[i], &cap);
        if (j->errs[i] == 0) j->lens[i] = cap;
    } else {
        j->errs[i] = ttio_v6_chain_decode(j->pm, j->ab, j->bufs[i],
                                          j->lens[i],
                                          j->lengths + s->first_read,
                                          s->n_reads,
                                          j->qual_out + s->qual_off,
                                          (size_t)s->n_qual);
    }
}

static void *v6_worker(void *arg) {
    v6_job *j = (v6_job *)arg;
    for (;;) {
        size_t i;
        pthread_mutex_lock(&j->mu);
        i = j->next++;
        pthread_mutex_unlock(&j->mu);
        if (i >= j->n_segs) break;
        v6_run_one(j, i);
    }
    return NULL;
}

static int v6_run(v6_job *j, int threads) {
    size_t nt = 1;
    if (threads > 1) {
        nt = (size_t)threads;
        if (nt > j->n_segs) nt = j->n_segs;
    }
    if (nt <= 1) {
        for (size_t i = 0; i < j->n_segs; i++) v6_run_one(j, i);
    } else {
        pthread_t *th = (pthread_t *)malloc(nt * sizeof(*th));
        if (!th) return TTIO_SEQCTX_ERR_OOM;
        size_t started = 0;
        j->next = 0;
        pthread_mutex_init(&j->mu, NULL);
        for (size_t i = 0; i < nt; i++) {
            if (pthread_create(&th[i], NULL, v6_worker, j) != 0) break;
            started++;
        }
        if (started == 0) {
            for (size_t i = 0; i < j->n_segs; i++) v6_run_one(j, i);
        } else {
            v6_worker(j);
            for (size_t i = 0; i < started; i++) pthread_join(th[i], NULL);
        }
        pthread_mutex_destroy(&j->mu);
        free(th);
    }
    for (size_t i = 0; i < j->n_segs; i++)
        if (j->errs[i] != 0) return j->errs[i];
    return 0;
}

/* CPU engine entry: run a prepared job on the segment pool. */
int ttio_v6_encode_job_cpu(ttio_v6_job *job) {
    v6_job j;
    memset(&j, 0, sizeof j);
    j.pm = job->pm;
    j.ab = job->ab;
    j.segs = (const v6_seg *)job->segs;
    j.n_segs = job->n_segs;
    j.lengths = job->read_lengths;
    j.bufs = job->bufs;
    j.lens = job->lens;
    j.errs = job->errs;
    j.qual_in = job->qual;
    j.do_encode = 1;
    return v6_run(&j, job->threads);
}

static void v6_put_u16(uint8_t *p, uint16_t v) { memcpy(p, &v, 2); }
static void v6_put_u32(uint8_t *p, uint32_t v) { memcpy(p, &v, 4); }

static uint16_t v6_get_u16(const uint8_t *p) {
    uint16_t v;
    memcpy(&v, p, 2);
    return v;
}

static uint32_t v6_get_u32(const uint8_t *p) {
    uint32_t v;
    memcpy(&v, p, 4);
    return v;
}

int ttio_m94z_v6_encode(const uint8_t *qual, size_t n_qualities,
                        const uint32_t *read_lengths, size_t n_reads,
                        const ttio_v6_param *pm, uint32_t seg_symbols,
                        int threads, uint8_t *out, size_t *out_len) {
    uint64_t  total = 0, chain_bytes = 0;
    ttio_v6_alphabet ab;
    v6_seg   *segs = NULL;
    uint8_t **bufs = NULL;
    size_t   *lens = NULL;
    int      *errs = NULL;
    uint8_t  *pool = NULL, *body = NULL;
    size_t    n_segs, body_len;
    int       rc = 0;

    if (!param_valid(pm)) return TTIO_SEQCTX_ERR_PARAM;
    if (!out || !out_len) return TTIO_SEQCTX_ERR_ARGS;
    if (seg_symbols == 0) return TTIO_SEQCTX_ERR_PARAM;
    if (n_reads > 0 && !read_lengths) return TTIO_SEQCTX_ERR_ARGS;
    lengths_sum(read_lengths, n_reads, &total);
    if (total != (uint64_t)n_qualities) return TTIO_SEQCTX_ERR_ARGS;
    if (n_qualities > 0 && !qual) return TTIO_SEQCTX_ERR_ARGS;

    n_segs = v6_plan(read_lengths, n_reads, seg_symbols, NULL);
    if (n_segs > 0xFFFFu) return TTIO_SEQCTX_ERR_PARAM;

    /* One alphabet for the whole block: every segment codes against the
     * same dense symbol set, and it is written once into the header. */
    ttio_v6_alphabet_build(qual, n_qualities, pm->seed_total, &ab);

    if (n_segs > 0) {
        uint64_t pool_bytes = 0, at = 0;
        segs = (v6_seg *)malloc(n_segs * sizeof(*segs));
        bufs = (uint8_t **)malloc(n_segs * sizeof(*bufs));
        lens = (size_t *)malloc(n_segs * sizeof(*lens));
        errs = (int *)calloc(n_segs, sizeof(*errs));
        if (!segs || !bufs || !lens || !errs) {
            rc = TTIO_SEQCTX_ERR_OOM;
            goto done;
        }
        v6_plan(read_lengths, n_reads, seg_symbols, segs);

        for (size_t i = 0; i < n_segs; i++) {
            lens[i] = (size_t)segs[i].n_qual + (size_t)segs[i].n_qual / 2
                    + 4096;
            pool_bytes += lens[i];
        }
        pool = (uint8_t *)malloc((size_t)pool_bytes);
        if (!pool) {
            rc = TTIO_SEQCTX_ERR_OOM;
            goto done;
        }
        for (size_t i = 0; i < n_segs; i++) {
            bufs[i] = pool + at;
            at += lens[i];
        }

        {
            ttio_v6_job job;
            memset(&job, 0, sizeof job);
            job.pm = pm;
            job.ab = &ab;
            job.qual = qual;
            job.read_lengths = read_lengths;
            job.n_reads = n_reads;
            job.n_qualities = n_qualities;
            job.seg_symbols = seg_symbols;
            job.threads = threads;
            job.segs = segs;
            job.n_segs = n_segs;
            job.bufs = bufs;
            job.lens = lens;
            job.errs = errs;
            rc = ttio_engine_cpu()->qual_v6_encode(&job);
        }
        if (rc != 0) goto done;
    }

    for (size_t i = 0; i < n_segs; i++) chain_bytes += lens[i];
    body_len = V6_BODY_HDR + 3u * ab.n + 4u * n_segs
             + (size_t)chain_bytes;
    body = (uint8_t *)malloc(body_len);
    if (!body) {
        rc = TTIO_SEQCTX_ERR_OOM;
        goto done;
    }

    memset(body, 0, V6_BODY_HDR);
    body[0] = 1;
    v6_put_u16(body + 2, (uint16_t)n_segs);
    v6_put_u32(body + 4, seg_symbols);
    body[8] = pm->qbits;
    body[9] = pm->qshift;
    body[10] = pm->pbits;
    body[11] = pm->pshift;
    body[12] = pm->dbits;
    v6_put_u16(body + 14, (uint16_t)ab.n);
    memcpy(body + V6_BODY_HDR, ab.inv, ab.n);
    for (unsigned i = 0; i < ab.n; i++)
        v6_put_u16(body + V6_BODY_HDR + ab.n + 2u * i, ab.seed[i]);
    {
        uint8_t *tab = body + V6_BODY_HDR + 3u * ab.n;
        uint8_t *at = tab + 4u * n_segs;
        for (size_t i = 0; i < n_segs; i++) {
            v6_put_u32(tab + 4u * i, (uint32_t)lens[i]);
            memcpy(at, bufs[i], lens[i]);
            at += lens[i];
        }
    }

    rc = ttio_m94z_v6_pack((uint64_t)n_qualities, (uint64_t)n_reads,
                           read_lengths, 0, body, body_len, out, out_len);

done:
    free(segs);
    free(bufs);
    free(lens);
    free(errs);
    free(pool);
    free(body);
    return rc;
}

int ttio_m94z_v6_decode(const uint8_t *in, size_t in_len,
                        uint32_t *read_lengths, size_t n_reads,
                        int threads, uint8_t *qual_out,
                        size_t n_qualities) {
    uint64_t       nq = 0, nr = 0;
    uint8_t        pad = 0;
    const uint8_t *body = NULL, *tab = NULL, *at = NULL;
    size_t         body_len = 0, n_segs, avail, a_size;
    uint32_t       seg_symbols;
    ttio_v6_param  pm;
    ttio_v6_alphabet ab;
    v6_seg        *segs = NULL;
    uint8_t      **bufs = NULL;
    size_t        *lens = NULL;
    int           *errs = NULL;
    int            rc;

    if (!in || in_len < 30) return TTIO_SEQCTX_ERR_CORRUPT;
    if (n_reads > 0 && !read_lengths) return TTIO_SEQCTX_ERR_ARGS;

    /* Check the header counts against what the caller expects BEFORE
     * unpacking, so a wrong count cannot overrun read_lengths. */
    {
        uint64_t hdr_nq, hdr_nr;
        memcpy(&hdr_nq, in + 6, 8);
        memcpy(&hdr_nr, in + 14, 8);
        if (hdr_nr != (uint64_t)n_reads) return TTIO_SEQCTX_ERR_ARGS;
        if (hdr_nq != (uint64_t)n_qualities) return TTIO_SEQCTX_ERR_ARGS;
    }

    rc = ttio_m94z_v6_unpack(in, in_len, &nq, &nr, read_lengths, &pad, &body,
                             &body_len);
    if (rc != 0) return rc;
    if (n_qualities == 0) return 0;
    if (!qual_out) return TTIO_SEQCTX_ERR_ARGS;
    if (body_len < V6_BODY_HDR) return TTIO_SEQCTX_ERR_CORRUPT;
    if (body[0] != 1) return TTIO_SEQCTX_ERR_CORRUPT;

    n_segs = v6_get_u16(body + 2);
    seg_symbols = v6_get_u32(body + 4);
    pm.qbits = body[8];
    pm.qshift = body[9];
    pm.pbits = body[10];
    pm.pshift = body[11];
    pm.dbits = body[12];
    if (!param_valid(&pm)) return TTIO_SEQCTX_ERR_PARAM;
    if (seg_symbols == 0) return TTIO_SEQCTX_ERR_CORRUPT;

    a_size = v6_get_u16(body + 14);
    if (a_size < 1 || a_size > 256) return TTIO_SEQCTX_ERR_CORRUPT;
    if (body_len < V6_BODY_HDR + 3u * a_size + 4u * n_segs)
        return TTIO_SEQCTX_ERR_CORRUPT;

    /* Rebuild the map from the stored alphabet. The values ascend, so a
     * stream claiming otherwise is corrupt. */
    memset(ab.map, 0, sizeof ab.map);
    memset(ab.inv, 0, sizeof ab.inv);
    memset(ab.seed, 0, sizeof ab.seed);
    ab.n = (unsigned)a_size;
    ab.seed_total = 0;
    for (size_t i = 0; i < a_size; i++) {
        uint8_t  q = body[V6_BODY_HDR + i];
        uint16_t w = v6_get_u16(body + V6_BODY_HDR + a_size + 2u * i);
        if (i > 0 && q <= body[V6_BODY_HDR + i - 1])
            return TTIO_SEQCTX_ERR_CORRUPT;
        if (w == 0) return TTIO_SEQCTX_ERR_CORRUPT;
        ab.inv[i] = q;
        ab.map[q] = (uint8_t)i;
        ab.seed[i] = w;
        ab.seed_total += w;
    }
    if (!alphabet_valid(&ab)) return TTIO_SEQCTX_ERR_CORRUPT;

    if (v6_plan(read_lengths, (size_t)nr, seg_symbols, NULL) != n_segs)
        return TTIO_SEQCTX_ERR_CORRUPT;

    segs = (v6_seg *)malloc(n_segs * sizeof(*segs));
    bufs = (uint8_t **)malloc(n_segs * sizeof(*bufs));
    lens = (size_t *)malloc(n_segs * sizeof(*lens));
    errs = (int *)calloc(n_segs, sizeof(*errs));
    if (!segs || !bufs || !lens || !errs) {
        rc = TTIO_SEQCTX_ERR_OOM;
        goto done;
    }
    v6_plan(read_lengths, (size_t)nr, seg_symbols, segs);

    tab = body + V6_BODY_HDR + 3u * a_size;
    at = tab + 4u * n_segs;
    avail = body_len - V6_BODY_HDR - 3u * a_size - 4u * n_segs;
    for (size_t i = 0; i < n_segs; i++) {
        uint32_t sl = v6_get_u32(tab + 4u * i);
        if (sl > avail) {
            rc = TTIO_SEQCTX_ERR_CORRUPT;
            goto done;
        }
        bufs[i] = (uint8_t *)at;
        lens[i] = sl;
        at += sl;
        avail -= sl;
    }

    {
        v6_job j;
        memset(&j, 0, sizeof j);
        j.pm = &pm;
        j.segs = segs;
        j.n_segs = n_segs;
        j.lengths = read_lengths;
        j.bufs = bufs;
        j.lens = lens;
        j.errs = errs;
        j.ab = &ab;
        j.qual_out = qual_out;
        j.do_encode = 0;
        rc = v6_run(&j, threads);
    }

done:
    free(segs);
    free(bufs);
    free(lens);
    free(errs);
    return rc;
}
