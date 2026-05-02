/* native/src/fqzcomp_qual.c
 *
 * CRAM 3.1 fqzcomp_qual encode/decode port. Phase 2 skeleton:
 * strategy 1 (HiSeq) hardcoded; auto-tune deferred to Phase 3.
 *
 * Mirrors htscodecs/fqzcomp_qual.c::compress_block_fqz2f /
 * uncompress_block_fqz2f. The Range Coder primitives are the
 * shared rc_cram.{h,c} unit (Phase 1 byte-equal vs htscodecs).
 *
 * Self-contained: vendors a slim simple_model frequency-table
 * primitive (NSYM=2, NSYM=256) — semantics and update rule
 * verbatim from htscodecs/c_simple_model.h.
 *
 * Public entry points:
 *   ttio_fqzcomp_qual_compress
 *   ttio_fqzcomp_qual_uncompress
 */
#include "fqzcomp_qual.h"

#include <limits.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* ---------------------------------------------------------------------------
 * Constants and helpers
 * ------------------------------------------------------------------------ */

#ifndef MIN
#  define MIN(a,b) ((a)<(b)?(a):(b))
#  define MAX(a,b) ((a)>(b)?(a):(b))
#endif

/* htscodecs c_simple_model.h: MAX_FREQ = (1<<16)-17, STEP = 16 */
#define SM_MAX_FREQ ((1u<<16) - 17u)
#define SM_STEP     16u

/* htscodecs/fqzcomp_qual.c: CTX_BITS=16, CTX_SIZE=65536, QMAX=256 */
#define CTX_BITS 16
#define CTX_SIZE (1u << CTX_BITS)
#define QMAX     256

/* htscodecs/fqzcomp_qual.h: FQZ_VERS = 5 */
#define FQZ_VERS 5

/* Param flags (htscodecs) */
#define PFLAG_DO_DEDUP   2
#define PFLAG_DO_LEN     4
#define PFLAG_DO_SEL     8
#define PFLAG_HAVE_QMAP  16
#define PFLAG_HAVE_PTAB  32
#define PFLAG_HAVE_DTAB  64
#define PFLAG_HAVE_QTAB  128

/* Global flags (htscodecs) */
#define GFLAG_MULTI_PARAM 1
#define GFLAG_HAVE_STAB   2
#define GFLAG_DO_REV      4

/* SAM flags re-exported from htscodecs/fqzcomp_qual.h */
#define FQZ_FREVERSE 16
#define FQZ_FREAD2  128

/* ---------------------------------------------------------------------------
 * varint (mirrors htscodecs/varint.h, BIG_END default)
 * ------------------------------------------------------------------------ */

static int var_put_u32(uint8_t *cp, uint32_t i) {
    if (i < (1u<<7)) {
        cp[0] = (uint8_t)i;
        return 1;
    } else if (i < (1u<<14)) {
        cp[0] = (uint8_t)(((i>> 7) & 0x7f) | 128);
        cp[1] = (uint8_t)(  i      & 0x7f);
        return 2;
    } else if (i < (1u<<21)) {
        cp[0] = (uint8_t)(((i>>14) & 0x7f) | 128);
        cp[1] = (uint8_t)(((i>> 7) & 0x7f) | 128);
        cp[2] = (uint8_t)(  i      & 0x7f);
        return 3;
    } else if (i < (1u<<28)) {
        cp[0] = (uint8_t)(((i>>21) & 0x7f) | 128);
        cp[1] = (uint8_t)(((i>>14) & 0x7f) | 128);
        cp[2] = (uint8_t)(((i>> 7) & 0x7f) | 128);
        cp[3] = (uint8_t)(  i      & 0x7f);
        return 4;
    } else {
        cp[0] = (uint8_t)(((i>>28) & 0x7f) | 128);
        cp[1] = (uint8_t)(((i>>21) & 0x7f) | 128);
        cp[2] = (uint8_t)(((i>>14) & 0x7f) | 128);
        cp[3] = (uint8_t)(((i>> 7) & 0x7f) | 128);
        cp[4] = (uint8_t)(  i      & 0x7f);
        return 5;
    }
}

static int var_get_u32(const uint8_t *cp, const uint8_t *endp, uint32_t *i) {
    const uint8_t *op = cp;
    uint8_t  c;
    uint32_t j = 0;
    int n = 5;
    if (cp >= endp) { *i = 0; return 0; }
    do {
        c = *cp++;
        j = (j << 7) | (c & 0x7f);
    } while ((c & 0x80) && n-- > 0 && cp < endp);
    *i = j;
    return (int)(cp - op);
}

/* ---------------------------------------------------------------------------
 * Simple model (frequency table with single-step bubble sort + adaptive update).
 *
 * Vendored verbatim from htscodecs/c_simple_model.h, but generalised to a
 * single struct + functions parameterised by nsym at runtime instead of
 * macro-template specialisation. Symbol values are uint16_t internally so
 * NSYM=256 (qual) and NSYM=2 (revcomp/dup) both fit.
 * ------------------------------------------------------------------------ */

typedef struct {
    uint16_t freq;
    uint16_t symbol;
} sm_symfreq;

typedef struct {
    uint32_t    tot_freq;
    int         nsym;          /* allocation: F[0..nsym], plus terminal at [nsym] */
    sm_symfreq  sentinel;      /* placed BEFORE F[0] in memory layout? No: we use
                                  index-based access [-1] via &F[0]; we keep
                                  sentinel separately and provide a dedicated
                                  sort-pred check. See sm_encode comments. */
    sm_symfreq *F;             /* size nsym+1 */
} sm_model;

/* Allocate F[nsym+1]; init max_sym entries with freq=1. Layout is
 * F[-1] = sentinel slot (we reserve index 0 for sentinel access via
 * the sort-step). htscodecs's c_simple_model uses an inline struct
 * with sentinel preceding F[] in memory; we replicate that with one
 * extra slot at index 0. */
static int sm_init(sm_model *m, int nsym, int max_sym) {
    m->nsym = nsym;
    /* +2: one for sentinel at [0], one for terminal at [nsym+1] */
    m->F = (sm_symfreq *)calloc((size_t)(nsym + 2), sizeof(*m->F));
    if (!m->F) return -1;

    /* Sentinel at F[0] */
    m->F[0].symbol = 0;
    m->F[0].freq   = (uint16_t)SM_MAX_FREQ;

    /* Real symbols at F[1..max_sym] init to freq=1; F[max_sym+1..nsym] freq=0;
     * terminal at F[nsym+1] freq=0 (implicit via calloc).
     * NB: htscodecs uses 0-indexed F[] while sentinel sits "before". To stay
     * one-to-one with that loop:
     *   for (i=0; i<max_sym; i++) F[i].Symbol=i, F[i].Freq=1;
     *   for (; i<NSYM; i++)       F[i].Symbol=i, F[i].Freq=0;
     *   sentinel.Symbol=0, sentinel.Freq=MAX_FREQ;
     *   F[NSYM].Freq=0;
     * Encode loop walks F[0..] until it finds the symbol and uses F[-1] for
     * the sort-up swap (which goes through sentinel).
     * We adopt the same layout but offset by 1: real symbols live at indices
     * 1..nsym; F[0] is the sentinel; F[nsym+1] is terminal. The sort-up
     * compares against F[i-1] which for i=1 hits the sentinel — exactly the
     * htscodecs semantics. */
    for (int i = 0; i < max_sym; i++) {
        m->F[i + 1].symbol = (uint16_t)i;
        m->F[i + 1].freq   = 1;
    }
    for (int i = max_sym; i < nsym; i++) {
        m->F[i + 1].symbol = (uint16_t)i;
        m->F[i + 1].freq   = 0;
    }
    m->tot_freq = (uint32_t)max_sym;
    /* terminal at [nsym+1] freq=0 already from calloc */
    return 0;
}

static void sm_destroy(sm_model *m) {
    if (m->F) { free(m->F); m->F = NULL; }
}

static void sm_normalize(sm_model *m) {
    sm_symfreq *s;
    m->tot_freq = 0;
    /* Walk forward through F[1..] until freq==0 (terminal stops loop). */
    for (s = &m->F[1]; s->freq; s++) {
        s->freq -= s->freq >> 1;
        m->tot_freq += s->freq;
    }
}

static void sm_encode(sm_model *m, rc_cram_encoder *e, uint16_t sym) {
    sm_symfreq *s = &m->F[1];
    uint32_t acc = 0;
    while (s->symbol != sym) {
        acc += s->freq;
        s++;
    }
    rc_cram_encode(e, acc, s->freq, m->tot_freq);
    s->freq    += SM_STEP;
    m->tot_freq += SM_STEP;

    if (m->tot_freq > SM_MAX_FREQ)
        sm_normalize(m);

    /* Single-step bubble-sort: swap with previous if heavier. The previous
     * for s == &F[1] is the sentinel at F[0] (freq=MAX_FREQ), so swap is
     * suppressed (s->freq is never > sentinel's). */
    if (s[0].freq > s[-1].freq) {
        sm_symfreq t = s[0];
        s[0]  = s[-1];
        s[-1] = t;
    }
}

static uint16_t sm_decode(sm_model *m, rc_cram_decoder *d) {
    sm_symfreq *s = &m->F[1];
    uint32_t freq = rc_cram_decode_target(d, m->tot_freq);
    uint32_t acc;

    if (freq > SM_MAX_FREQ)
        return 0; /* error sentinel */

    /* Walk forward. Terminal at F[nsym+1] has freq=0; if we hit it the
     * decoder is corrupt. Mirror htscodecs's "s - F > NSYM" check. */
    for (acc = 0; (acc += s->freq) <= freq; s++) {
        if ((s - &m->F[1]) > m->nsym)
            return 0;
    }
    acc -= s->freq;

    rc_cram_decode_advance(d, acc, s->freq, m->tot_freq);
    s->freq    += SM_STEP;
    m->tot_freq += SM_STEP;

    if (m->tot_freq > SM_MAX_FREQ)
        sm_normalize(m);

    if (s[0].freq > s[-1].freq) {
        sm_symfreq t = s[0];
        s[0]  = s[-1];
        s[-1] = t;
        return t.symbol;
    }
    return s->symbol;
}

/* ---------------------------------------------------------------------------
 * Internal fqz_param + state (subset of htscodecs's structures).
 * Only the fields needed for the strategy 1 path are populated.
 * ------------------------------------------------------------------------ */

typedef struct {
    /* Stored in parameter header */
    uint16_t context;
    uint8_t  pflags;
    uint8_t  max_sym;     /* max symbol value (NOT count) */
    uint8_t  qbits;
    uint8_t  qshift;
    uint8_t  qloc;
    uint8_t  sloc;
    uint8_t  ploc;
    uint8_t  dloc;

    /* Computed from stored bits */
    uint8_t  pbits;
    uint8_t  pshift;
    uint8_t  dbits;
    uint8_t  dshift;
    uint32_t qmask;       /* (1<<qbits) - 1 */

    int      use_qtab;
    int      use_ptab;
    int      use_dtab;
    int      do_sel;
    int      do_dedup;
    int      fixed_len;
    int      store_qmap;

    /* Tables — values include the <<ploc / <<dloc shift that has been
     * factored in after fqz_create_models. qmap is plain (no shift). */
    uint32_t qmap[256];
    uint32_t qtab[256];
    uint32_t ptab[1024];
    uint32_t dtab[256];
} fqz_param;

typedef struct {
    int      vers;
    uint8_t  gflags;
    int      nparam;
    int      max_sel;
    int      max_sym;     /* max across all params */
    uint32_t stab[256];
    fqz_param p;          /* Phase 2: single param block */
} fqz_gparams;

typedef struct {
    sm_model qual[CTX_SIZE];
    sm_model len[4];
    sm_model revcomp;
    sm_model sel;
    sm_model dup;
} fqz_model;

/* Per-read encode/decode running state */
typedef struct {
    uint32_t qctx;
    int      p;           /* bytes remaining in current read */
    uint32_t delta;
    uint32_t prevq;
    uint32_t s;           /* selector */
    uint32_t qtot, qlen;  /* unused in Phase 2 (do_qa = 0) */
    int      first_len;
    int      last_len;
    size_t   rec;
    uint32_t ctx;
} fqz_state;

/* ---------------------------------------------------------------------------
 * Strategy 1 (HiSeq) parameterisation
 *
 * htscodecs strat_opts[1] = {qb=8,qs=5,pb=7,ps=0,db=0,ds=0,
 *                            ql=0,sl=14,pl=8,dl=14, r2=1,qa=-1}
 *
 * Phase 2 skips fqz_qual_stats / auto-tune entirely:
 *   - do_qa is forced to 0 (no average-quality selector)
 *   - do_sel  = 0 (no selector encoded)
 *   - do_r2 = 1 in strat_opts[1] only takes effect via auto-tune; here it's
 *             a no-op without auto-tune.
 *
 * dsqr table from htscodecs (approx sqrt(delta), used for dtab[]). With
 * dbits=0 for HiSeq, dtab[] collapses to all-zero anyway.
 * ------------------------------------------------------------------------ */

static const int g_dsqr[] = {
    0, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7
};

/* Configure gparams for strategy 1 against the given quality stream metadata.
 * Mirrors fqz_pick_parameters but skips fqz_qual_stats (auto-tune). */
static void fqz_setup_strat1(fqz_gparams *gp,
                             const uint32_t *read_lengths, size_t n_reads) {
    memset(gp, 0, sizeof(*gp));
    gp->vers    = FQZ_VERS;
    gp->gflags  = 0;            /* CRAM 3.1: no GFLAG_DO_REV */
    gp->nparam  = 1;
    gp->max_sel = 0;
    gp->max_sym = 255;          /* full-byte alphabet (no qmap stripping) */

    fqz_param *pm = &gp->p;
    pm->context  = 0;

    /* HiSeq preset, exact values */
    pm->qbits  = 8;
    pm->qshift = 5;
    pm->qloc   = 0;
    pm->sloc   = 14;
    pm->ploc   = 8;
    pm->dloc   = 14;
    pm->pbits  = 7;
    pm->pshift = 0;
    pm->dbits  = 0;
    pm->dshift = 0;
    pm->qmask  = (1u << pm->qbits) - 1u;

    pm->store_qmap = 0;         /* identity qmap */
    pm->do_sel     = 0;
    pm->do_dedup   = 0;

    /* fixed_len iff all read_lengths are equal AND non-zero */
    pm->fixed_len = (n_reads > 0);
    for (size_t i = 1; i < n_reads; i++) {
        if (read_lengths[i] != read_lengths[0]) { pm->fixed_len = 0; break; }
    }

    pm->use_qtab = 0;           /* identity qtab */
    pm->use_ptab = (pm->pbits > 0);
    pm->use_dtab = (pm->dbits > 0);

    pm->max_sym = 255;          /* full alphabet */

    /* qmap: identity (since !store_qmap) */
    for (int i = 0; i < 256; i++)
        pm->qmap[i] = (uint32_t)i;

    /* qtab: identity */
    for (int i = 0; i < 256; i++)
        pm->qtab[i] = (uint32_t)i;

    /* ptab: MIN((1<<pbits)-1, i>>pshift) */
    for (int i = 0; i < 1024; i++)
        pm->ptab[i] = (uint32_t)MIN((1<<pm->pbits)-1, i >> pm->pshift);

    /* dtab: dsqr[MIN(63, i>>dshift)], capped at (1<<dbits)-1.
     * For dbits=0, dtab values get clamped to 0 below. */
    {
        int dlim = (pm->dbits == 0) ? 0 : ((1 << pm->dbits) - 1);
        int dlen = (int)(sizeof(g_dsqr)/sizeof(*g_dsqr));
        for (int i = 0; i < 256; i++) {
            int v = g_dsqr[MIN(dlen - 1, i >> pm->dshift)];
            if (v > dlim) v = dlim;
            pm->dtab[i] = (uint32_t)v;
        }
    }

    pm->pflags =
        (uint8_t)((pm->use_qtab   ? PFLAG_HAVE_QTAB : 0) |
                  (pm->use_dtab   ? PFLAG_HAVE_DTAB : 0) |
                  (pm->use_ptab   ? PFLAG_HAVE_PTAB : 0) |
                  (pm->do_sel     ? PFLAG_DO_SEL    : 0) |
                  (pm->fixed_len  ? PFLAG_DO_LEN    : 0) |
                  (pm->do_dedup   ? PFLAG_DO_DEDUP  : 0) |
                  (pm->store_qmap ? PFLAG_HAVE_QMAP : 0));
}

/* Pre-shift ptab/dtab so the inner loop is a plain add. Mirrors the
 * "Optimise tables to remove shifts in loop" passes in
 * compress_block_fqz2f / uncompress_block_fqz2f. */
static void fqz_pre_shift_tables(fqz_param *pm) {
    for (int i = 0; i < 1024; i++)
        pm->ptab[i] <<= pm->ploc;
    for (int i = 0; i < 256; i++)
        pm->dtab[i] <<= pm->dloc;
}

/* ---------------------------------------------------------------------------
 * store_array / read_array — RLE+RLE encoding for ptab/dtab/qtab arrays.
 * Verbatim port from htscodecs/fqzcomp_qual.c (lines 102-190).
 * ------------------------------------------------------------------------ */

static int store_array(uint8_t *out, const uint32_t *array, int size) {
    uint8_t tmp[2048];
    int i = 0, j = 0, k = 0;

    for (i = j = k = 0; i < size; j++) {
        int run_len = i;
        while (i < size && array[i] == (uint32_t)j)
            i++;
        run_len = i - run_len;

        int r;
        do {
            r = MIN(255, run_len);
            tmp[k++] = (uint8_t)r;
            run_len -= r;
        } while (r == 255);
    }
    while (i < size) {
        tmp[k++] = 0;
        j++;
    }

    /* Outer RLE pass */
    int last = -1;
    for (i = 0, j = 0; j < k; i++) {
        out[i] = tmp[j++];
        if (out[i] == last) {
            int n = j;
            while (j < k && tmp[j] == last)
                j++;
            out[++i] = (uint8_t)(j - n);
        } else {
            last = out[i];
        }
    }
    return i;
}

static int read_array(const uint8_t *in, size_t in_size, uint32_t *array, int size) {
    uint8_t R[1024];
    int i, j, z, last = -1, nb = 0;

    if (size > 1024) size = 1024;

    /* Remove level-1 RLE */
    for (i = j = z = 0; z < size && i < (int)in_size; i++) {
        int run = in[i];
        R[j++] = (uint8_t)run;
        z += run;
        if (run == last) {
            if (i + 1 >= (int)in_size) return -1;
            int copy = in[++i];
            z += run * copy;
            while (copy-- && z <= size && j < 1024)
                R[j++] = (uint8_t)run;
        }
        if (j >= 1024) return -1;
        last = run;
    }
    nb = i;

    /* Expand level-2 RLE */
    int R_max = j;
    for (i = j = z = 0; j < size; i++) {
        int run_len = 0;
        int run_part;
        if (z >= R_max) return -1;
        do {
            run_part = R[z++];
            run_len += run_part;
        } while (run_part == 255 && z < R_max);
        if (run_part == 255) return -1;

        while (run_len && j < size) {
            run_len--;
            array[j++] = (uint32_t)i;
        }
    }

    return nb;
}

/* ---------------------------------------------------------------------------
 * fqz_store_parameters / fqz_read_parameters
 * Mirrors htscodecs fqz_store_parameters{,1} and fqz_read_parameters{,1}.
 * ------------------------------------------------------------------------ */

static int fqz_store_parameters1(const fqz_param *pm, uint8_t *out) {
    int idx = 0;

    out[idx++] = (uint8_t)(pm->context & 0xff);
    out[idx++] = (uint8_t)(pm->context >> 8);

    out[idx++] = pm->pflags;
    out[idx++] = pm->max_sym;

    out[idx++] = (uint8_t)((pm->qbits << 4) | pm->qshift);
    out[idx++] = (uint8_t)((pm->qloc  << 4) | pm->sloc);
    out[idx++] = (uint8_t)((pm->ploc  << 4) | pm->dloc);

    if (pm->store_qmap) {
        for (int i = 0; i < 256; i++)
            if (pm->qmap[i] != (uint32_t)INT_MAX)
                out[idx++] = (uint8_t)i;
    }

    if (pm->qbits && pm->use_qtab)
        idx += store_array(out + idx, pm->qtab, 256);

    if (pm->pbits && pm->use_ptab)
        idx += store_array(out + idx, pm->ptab, 1024);

    if (pm->dbits && pm->use_dtab)
        idx += store_array(out + idx, pm->dtab, 256);

    return idx;
}

static int fqz_store_parameters(const fqz_gparams *gp, uint8_t *out) {
    int idx = 0;
    out[idx++] = (uint8_t)gp->vers;
    out[idx++] = gp->gflags;

    if (gp->gflags & GFLAG_MULTI_PARAM)
        out[idx++] = (uint8_t)gp->nparam;

    if (gp->gflags & GFLAG_HAVE_STAB) {
        out[idx++] = (uint8_t)gp->max_sel;
        idx += store_array(out + idx, gp->stab, 256);
    }

    /* Phase 2: single param block */
    idx += fqz_store_parameters1(&gp->p, out + idx);
    return idx;
}

static int fqz_read_parameters1(fqz_param *pm, const uint8_t *in, size_t in_size) {
    int idx = 0;
    if (in_size < 7) return -1;

    pm->context = (uint16_t)(in[idx] | (in[idx+1] << 8));
    idx += 2;

    pm->pflags     = in[idx++];
    pm->use_qtab   = (pm->pflags & PFLAG_HAVE_QTAB)  ? 1 : 0;
    pm->use_dtab   = (pm->pflags & PFLAG_HAVE_DTAB)  ? 1 : 0;
    pm->use_ptab   = (pm->pflags & PFLAG_HAVE_PTAB)  ? 1 : 0;
    pm->do_sel     = (pm->pflags & PFLAG_DO_SEL)     ? 1 : 0;
    pm->fixed_len  = (pm->pflags & PFLAG_DO_LEN)     ? 1 : 0;
    pm->do_dedup   = (pm->pflags & PFLAG_DO_DEDUP)   ? 1 : 0;
    pm->store_qmap = (pm->pflags & PFLAG_HAVE_QMAP)  ? 1 : 0;

    pm->max_sym    = in[idx++];

    pm->qbits      = (uint8_t)(in[idx] >> 4);
    pm->qmask      = (1u << pm->qbits) - 1u;
    pm->qshift     = (uint8_t)(in[idx++] & 15);
    pm->qloc       = (uint8_t)(in[idx] >> 4);
    pm->sloc       = (uint8_t)(in[idx++] & 15);
    pm->ploc       = (uint8_t)(in[idx] >> 4);
    pm->dloc       = (uint8_t)(in[idx++] & 15);

    /* pbits/dbits not stored; the decoder doesn't need them as it uses
     * the tables directly. We leave them at 0; only ptab/dtab existence
     * is signalled via use_ptab/use_dtab. */
    pm->pbits = 0; pm->pshift = 0;
    pm->dbits = 0; pm->dshift = 0;

    if (pm->store_qmap) {
        for (int i = 0; i < 256; i++) pm->qmap[i] = (uint32_t)INT_MAX;
        if (idx + pm->max_sym > (int)in_size) return -1;
        for (int i = 0; i < pm->max_sym; i++)
            pm->qmap[i] = in[idx++];
    } else {
        for (int i = 0; i < 256; i++) pm->qmap[i] = (uint32_t)i;
    }

    if (pm->qbits) {
        if (pm->use_qtab) {
            int used = read_array(in + idx, in_size - idx, pm->qtab, 256);
            if (used < 0) return -1;
            idx += used;
        } else {
            for (int i = 0; i < 256; i++) pm->qtab[i] = (uint32_t)i;
        }
    }

    if (pm->use_ptab) {
        int used = read_array(in + idx, in_size - idx, pm->ptab, 1024);
        if (used < 0) return -1;
        idx += used;
    } else {
        for (int i = 0; i < 1024; i++) pm->ptab[i] = 0;
    }

    if (pm->use_dtab) {
        int used = read_array(in + idx, in_size - idx, pm->dtab, 256);
        if (used < 0) return -1;
        idx += used;
    } else {
        for (int i = 0; i < 256; i++) pm->dtab[i] = 0;
    }

    return idx;
}

static int fqz_read_parameters(fqz_gparams *gp, const uint8_t *in, size_t in_size) {
    int idx = 0;
    if (in_size < 10) return -1;

    gp->vers = in[idx++];
    if (gp->vers != FQZ_VERS) return -1;

    gp->gflags = in[idx++];
    gp->nparam = (gp->gflags & GFLAG_MULTI_PARAM) ? in[idx++] : 1;
    if (gp->nparam <= 0) return -1;
    gp->max_sel = (gp->nparam > 1) ? gp->nparam : 0;

    if (gp->gflags & GFLAG_HAVE_STAB) {
        gp->max_sel = in[idx++];
        int used = read_array(in + idx, in_size - idx, gp->stab, 256);
        if (used < 0) return -1;
        idx += used;
    } else {
        for (int i = 0; i < gp->nparam; i++) gp->stab[i] = (uint32_t)i;
        for (int i = gp->nparam; i < 256; i++) gp->stab[i] = (uint32_t)(gp->nparam - 1);
    }

    /* Phase 2: only nparam=1 supported */
    if (gp->nparam != 1) return -1;
    int e = fqz_read_parameters1(&gp->p, in + idx, in_size - idx);
    if (e < 0) return -1;
    idx += e;

    gp->max_sym = gp->p.max_sym;
    return idx;
}

/* ---------------------------------------------------------------------------
 * Model lifecycle (replaces htscodecs's fqz_create_models / fqz_destroy_models)
 * ------------------------------------------------------------------------ */

static int fqz_create_models(fqz_model *m, const fqz_gparams *gp) {
    memset(m, 0, sizeof(*m));
    int max_sym_plus_one = gp->max_sym + 1;

    for (uint32_t i = 0; i < CTX_SIZE; i++) {
        if (sm_init(&m->qual[i], QMAX, max_sym_plus_one) < 0) {
            /* unwind */
            for (uint32_t k = 0; k < i; k++) sm_destroy(&m->qual[k]);
            return -1;
        }
    }
    for (int i = 0; i < 4; i++)
        if (sm_init(&m->len[i], 256, 256) < 0) goto err;

    if (sm_init(&m->revcomp, 2, 2) < 0) goto err;
    if (sm_init(&m->dup,     2, 2) < 0) goto err;
    if (gp->max_sel > 0) {
        if (sm_init(&m->sel, 256, gp->max_sel + 1) < 0) goto err;
    } else {
        /* Initialise to a degenerate 1-symbol model; never encoded against
         * because do_sel=0, but sm_destroy on it is safe. */
        m->sel.F = NULL;
    }
    return 0;

err:
    for (uint32_t i = 0; i < CTX_SIZE; i++) sm_destroy(&m->qual[i]);
    for (int i = 0; i < 4; i++) sm_destroy(&m->len[i]);
    sm_destroy(&m->revcomp);
    sm_destroy(&m->dup);
    sm_destroy(&m->sel);
    return -1;
}

static void fqz_destroy_models(fqz_model *m) {
    for (uint32_t i = 0; i < CTX_SIZE; i++) sm_destroy(&m->qual[i]);
    for (int i = 0; i < 4; i++) sm_destroy(&m->len[i]);
    sm_destroy(&m->revcomp);
    sm_destroy(&m->dup);
    sm_destroy(&m->sel);
}

/* ---------------------------------------------------------------------------
 * fqz_update_ctx
 * Mirrors htscodecs fqz_update_ctx (line 344). Returns context for next q.
 * Tables ptab/dtab are pre-shifted by ploc/dloc so just sum them.
 * ------------------------------------------------------------------------ */

static inline uint32_t fqz_update_ctx(const fqz_param *pm, fqz_state *st, int q) {
    uint32_t last = 0;
    st->qctx = (st->qctx << pm->qshift) + pm->qtab[q];
    last += (st->qctx & pm->qmask) << pm->qloc;
    last += pm->ptab[MIN(1023, (int)st->p)];
    last += pm->dtab[MIN(255,  (int)st->delta)];
    last += st->s << pm->sloc;

    st->delta += (st->prevq != (uint32_t)q);
    st->prevq = (uint32_t)q;
    st->p--;

    return last & (CTX_SIZE - 1);
}

/* ---------------------------------------------------------------------------
 * Per-read encode/decode helpers
 * ------------------------------------------------------------------------ */

static int compress_new_read(const fqz_gparams *gp,
                             const fqz_param *pm,
                             const uint32_t *read_lengths,
                             size_t n_reads,
                             const uint8_t *flags,
                             fqz_state *st,
                             fqz_model *model,
                             rc_cram_encoder *e,
                             uint32_t *last) {
    (void)gp;
    (void)flags; /* with do_sel=0 and gflags & GFLAG_DO_REV = 0, flags are unused */

    if (pm->do_sel) {
        st->s = 0;
        sm_encode(&model->sel, e, (uint16_t)st->s);
    } else {
        st->s = 0;
    }

    if (st->rec >= n_reads) return -1;
    int len = (int)read_lengths[st->rec];

    if (!pm->fixed_len || st->first_len) {
        sm_encode(&model->len[0], e, (uint16_t)((len >>  0) & 0xff));
        sm_encode(&model->len[1], e, (uint16_t)((len >>  8) & 0xff));
        sm_encode(&model->len[2], e, (uint16_t)((len >> 16) & 0xff));
        sm_encode(&model->len[3], e, (uint16_t)((len >> 24) & 0xff));
        st->first_len = 0;
    }

    /* CRAM 3.1: GFLAG_DO_REV is not set, so we do NOT emit the revcomp bit. */

    st->rec++;
    st->qtot = 0;
    st->qlen = 0;
    st->p = len;
    st->delta = 0;
    st->qctx = 0;
    st->prevq = 0;

    *last = pm->context;

    if (pm->do_dedup) {
        /* Phase 2: do_dedup is forced 0; this branch is unreachable. */
        return -1;
    }

    return 0;
}

static int decompress_new_read(const fqz_gparams *gp,
                               const fqz_param *pm_in,
                               size_t expected_reads,
                               const uint32_t *read_lengths,
                               fqz_state *st,
                               fqz_model *model,
                               rc_cram_decoder *d,
                               const fqz_param **pm_out_param,
                               size_t out_remaining) {
    (void)gp;

    if (pm_in->do_sel) {
        st->s = sm_decode(&model->sel, d);
    } else {
        st->s = 0;
    }

    /* Phase 2: nparam=1, no stab; param is unchanged. */
    *pm_out_param = pm_in;

    uint32_t len = (uint32_t)st->last_len;
    if (!pm_in->fixed_len || st->first_len) {
        len  = sm_decode(&model->len[0], d);
        len |= (uint32_t)sm_decode(&model->len[1], d) << 8;
        len |= (uint32_t)sm_decode(&model->len[2], d) << 16;
        len |= (uint32_t)sm_decode(&model->len[3], d) << 24;
        st->first_len = 0;
        st->last_len  = (int)len;
    }
    if (len == 0 || len > out_remaining) return -1;

    /* Sanity: if we know read_lengths up front (Phase 2 always does),
     * cross-check. This catches off-by-one parameter-header errors early. */
    if (read_lengths && st->rec < expected_reads) {
        if (len != read_lengths[st->rec]) return -1;
    }

    if (pm_in->do_dedup) {
        /* Phase 2: do_dedup is forced 0; this branch is unreachable. */
        return -1;
    }

    st->rec++;
    st->p     = (int)len;
    st->delta = 0;
    st->prevq = 0;
    st->qctx  = 0;
    st->ctx   = pm_in->context;
    return 0;
}

/* ---------------------------------------------------------------------------
 * Public API: ttio_fqzcomp_qual_compress
 * ------------------------------------------------------------------------ */

int ttio_fqzcomp_qual_compress(
    const uint8_t  *qual_in,
    size_t          n_qualities,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *flags,
    int             strategy_hint,
    uint8_t        *out,
    size_t         *out_len)
{
    /* Phase 2: only strategy 1 supported. Auto-tune (-1) and other
     * presets land in Phase 3. */
    if (strategy_hint != 1) return -2;
    if (!qual_in || !read_lengths || !out || !out_len) return -3;
    if (n_reads == 0 || n_qualities == 0) return -3;

    /* Sanity: sum(read_lengths) == n_qualities */
    size_t tlen = 0;
    for (size_t i = 0; i < n_reads; i++) tlen += read_lengths[i];
    if (tlen != n_qualities) return -3;

    size_t out_cap = *out_len;
    if (out_cap < 64) return -4;

    fqz_gparams gp;
    fqz_setup_strat1(&gp, read_lengths, n_reads);

    /* Header: var_put_u32(in_size) + parameter block */
    int hdr = 0;
    hdr += var_put_u32(out + hdr, (uint32_t)n_qualities);
    hdr += fqz_store_parameters(&gp, out + hdr);

    if ((size_t)hdr + 5 > out_cap) return -4;

    /* Pre-shift ptab/dtab so the inner loop is plain add */
    fqz_pre_shift_tables(&gp.p);

    /* Build models */
    fqz_model model;
    if (fqz_create_models(&model, &gp) < 0) return -5;

    /* Range coder writes after the header */
    rc_cram_encoder e;
    rc_cram_encoder_init(&e, out + hdr, out_cap - (size_t)hdr);

    fqz_state st = {0};
    st.first_len = 1;
    st.rec       = 0;

    uint32_t last = 0;
    fqz_param *pm = &gp.p;

    size_t i = 0;
    while (i < n_qualities) {
        if (st.p == 0) {
            int r = compress_new_read(&gp, pm, read_lengths, n_reads, flags,
                                      &st, &model, &e, &last);
            if (r < 0) { fqz_destroy_models(&model); return -6; }
            if (r > 0) continue; /* dedup hit (unreachable Phase 2) */
        }

        /* Emit one quality */
        uint8_t q  = qual_in[i++];
        uint8_t qm = (uint8_t)pm->qmap[q];
        sm_encode(&model.qual[last], &e, qm);
        last = fqz_update_ctx(pm, &st, qm);

        if (e.err) {
            fqz_destroy_models(&model);
            return -7;
        }
    }

    size_t rc_bytes = rc_cram_encoder_finish(&e);
    if (e.err) {
        fqz_destroy_models(&model);
        return -7;
    }

    *out_len = (size_t)hdr + rc_bytes;
    fqz_destroy_models(&model);
    return 0;
}

/* ---------------------------------------------------------------------------
 * Public API: ttio_fqzcomp_qual_uncompress
 * ------------------------------------------------------------------------ */

int ttio_fqzcomp_qual_uncompress(
    const uint8_t  *in,
    size_t          in_len,
    const uint32_t *read_lengths,
    size_t          n_reads,
    const uint8_t  *flags,
    uint8_t        *out,
    size_t          n_qualities)
{
    (void)flags;

    if (!in || !out || in_len < 10) return -3;

    /* Read in_size header */
    uint32_t expected_sz = 0;
    int hdr = var_get_u32(in, in + in_len, &expected_sz);
    if (hdr <= 0) return -3;
    if ((size_t)expected_sz != n_qualities) return -4;

    fqz_gparams gp;
    int pe = fqz_read_parameters(&gp, in + hdr, in_len - (size_t)hdr);
    if (pe < 0) return -5;
    hdr += pe;

    /* Pre-shift ptab/dtab (decoder mirrors encoder) */
    fqz_pre_shift_tables(&gp.p);

    fqz_model model;
    if (fqz_create_models(&model, &gp) < 0) return -5;

    rc_cram_decoder d;
    rc_cram_decoder_init(&d, in + hdr, in_len - (size_t)hdr);
    if (d.err) { fqz_destroy_models(&model); return -6; }

    fqz_state st = {0};
    st.first_len = 1;
    st.rec       = 0;

    uint32_t last = 0;
    const fqz_param *pm = &gp.p;

    size_t i = 0;
    while (i < n_qualities) {
        if (st.p == 0) {
            int r = decompress_new_read(&gp, pm, n_reads, read_lengths,
                                        &st, &model, &d, &pm,
                                        n_qualities - i);
            if (r < 0) { fqz_destroy_models(&model); return -6; }
            last = st.ctx;
        }

        do {
            uint16_t Q = sm_decode(&model.qual[last], &d);
            last = fqz_update_ctx(pm, &st, Q);
            out[i++] = (uint8_t)pm->qmap[Q];
            if (d.err) { fqz_destroy_models(&model); return -6; }
        } while (st.p != 0 && i < n_qualities);
    }

    fqz_destroy_models(&model);
    return 0;
}
