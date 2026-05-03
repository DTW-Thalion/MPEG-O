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
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

/* fast_log: vendored verbatim from htscodecs/utils.h:69 to match the
 * auto-tune entropy calculations bit-for-bit. (htscodecs's fqz_qual_stats
 * uses fast_log() for the do_qa entropy and log() for the do_r2 entropy;
 * we mirror that exactly.) */
static inline double fast_log_local(double a) {
    union { double d; long long x; } u = { a };
    return (u.x - 4606921278410026770LL) * 1.539095918623324e-16;
}

/* Helpers extracted from htscodecs's two divide-by-log expressions.
 * htscodecs writes:
 *   e1 /= -log(2)/8;   // do_qa branch
 *   e1 /= log(2)*8;    // do_r2 branch
 * We compute these once at link time; grouping them in helpers keeps
 * the qual_stats body close to the htscodecs source. */
static inline double log_local(double a)        { return log(a); }
static inline double log_local_2_div_8(void)    { return log(2.0) / 8.0; }
static inline double log_local_2_x_8(void)      { return log(2.0) * 8.0; }

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
    /* Stored in parameter header. NOTE: htscodecs uses signed `int` for these
     * (qbits, qshift, etc.) and stores -1 as a "auto-tune" sentinel for
     * pshift / do_qa. We mirror that with `int`. The on-the-wire encoding
     * still nibble-packs them as uint8 in fqz_store_parameters1 (auto-tune
     * runs first and resolves negatives before any storage). */
    int      context;
    uint8_t  pflags;
    int      max_sym;     /* max symbol value (NOT count) */
    int      qbits;
    int      qshift;
    int      qloc;
    int      sloc;
    int      ploc;
    int      dloc;

    /* Computed from stored bits */
    int      pbits;
    int      pshift;
    int      dbits;
    int      dshift;
    int      sbits;       /* selector bits — derived from sloc, kept for table */
    uint32_t qmask;       /* (1<<qbits) - 1 */

    /* Auto-tune control + outputs of fqz_qual_stats */
    int      do_qa;       /* -1 = auto, 0 = off, >=2 = forced split */
    int      do_r2;       /* 1 = consider READ1/READ2 split */
    int      do_sel;
    int      do_dedup;
    int      fixed_len;
    int      store_qmap;
    int      nsym;        /* unique-symbol count; populated by fqz_qual_stats */
    int      max_sel;     /* max selector index used; populated by stats */

    int      use_qtab;
    int      use_ptab;
    int      use_dtab;

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
 * Strategy preset table + auto-tune (Phase 3)
 *
 * Verbatim mirror of htscodecs strat_opts[][12] (lines ~175-200).
 * Field order: { qbits, qshift, pbits, pshift, dbits, dshift,
 *                qloc, sloc, ploc, dloc, do_r2, do_qa }.
 *
 * Note pshift=-1 (strategy 0) and do_qa=-1 (strategies 0,1) are signed
 * sentinels resolved by fqz_pick_parameters.
 *
 * dsqr table from htscodecs (approx sqrt(delta), used for dtab[]).
 * ------------------------------------------------------------------------ */

#define FQZ_NSTRATS 5

typedef struct {
    int qbits, qshift, pbits, pshift, dbits, dshift;
    int qloc, sloc, ploc, dloc;
    int do_r2, do_qa;
} fqz_strat_opts_t;

static const fqz_strat_opts_t FQZ_STRAT_OPTS[FQZ_NSTRATS] = {
    /* 0: Generic (level<7) */ {10, 5, 4,-1, 2, 1, 0, 14, 10, 14, 0,-1},
    /* 1: HiSeq 2000        */ { 8, 5, 7, 0, 0, 0, 0, 14,  8, 14, 1,-1},
    /* 2: MiSeq             */ {12, 6, 2, 0, 2, 3, 0,  9, 12, 14, 0, 0},
    /* 3: IonTorrent        */ {12, 6, 0, 0, 0, 0, 0, 12,  0,  0, 0, 0},
    /* 4: Custom (reserved) */ { 0, 0, 0, 0, 0, 0, 0,  0,  0,  0, 0, 0},
};

static const int g_dsqr[] = {
    0, 1, 1, 1, 2, 2, 2, 2, 2, 3, 3, 3, 3, 3, 3, 3,
    4, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5,
    5, 5, 5, 5, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
    6, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7
};

/* Per-record metadata for fqz_qual_stats / fqz_pick_parameters. The selector
 * lives in the high 16 bits of `flags[rec]` (matches htscodecs convention).
 *
 * Memory ownership: the caller (compress entry) allocates `flags[]` from the
 * public-API uint8 stream and writes selector bits into the high half during
 * auto-tune. */
typedef struct {
    size_t          num_records;
    const uint32_t *len;     /* size num_records */
    uint32_t       *flags;   /* size num_records — mutable for selector bits */
} fqz_slice_internal;

/* Configure gparams from a raw preset index (no histogram pass / no
 * auto-tune adjustments). Used by `strategy_hint = 0..3`; the auto-tune
 * (-1) path goes through fqz_pick_parameters_internal instead.
 *
 * Generalised replacement for the original strategy-1-only fqz_setup_strat1,
 * extended to all four real presets via FQZ_STRAT_OPTS.
 *
 * NB: do_qa = -1 in the preset is a sentinel for the auto-tune path; raw
 * mode just clamps it to 0 (no average-quality split). */
static int fqz_setup_strategy(fqz_gparams *gp, int strat_idx,
                              const uint32_t *read_lengths, size_t n_reads) {
    if (strat_idx < 0 || strat_idx >= FQZ_NSTRATS - 1) return -1;

    memset(gp, 0, sizeof(*gp));
    gp->vers    = FQZ_VERS;
    gp->gflags  = 0;
    gp->nparam  = 1;
    gp->max_sel = 0;
    gp->max_sym = 255;

    fqz_param *pm = &gp->p;
    pm->context = 0;

    pm->qbits  = FQZ_STRAT_OPTS[strat_idx].qbits;
    pm->qshift = FQZ_STRAT_OPTS[strat_idx].qshift;
    pm->qloc   = FQZ_STRAT_OPTS[strat_idx].qloc;
    pm->sloc   = FQZ_STRAT_OPTS[strat_idx].sloc;
    pm->ploc   = FQZ_STRAT_OPTS[strat_idx].ploc;
    pm->dloc   = FQZ_STRAT_OPTS[strat_idx].dloc;
    pm->pbits  = FQZ_STRAT_OPTS[strat_idx].pbits;
    pm->pshift = FQZ_STRAT_OPTS[strat_idx].pshift;
    pm->dbits  = FQZ_STRAT_OPTS[strat_idx].dbits;
    pm->dshift = FQZ_STRAT_OPTS[strat_idx].dshift;
    pm->do_r2  = FQZ_STRAT_OPTS[strat_idx].do_r2;
    pm->do_qa  = 0;  /* raw mode: skip auto-tune entirely */

    /* pshift = -1 (strategy 0) is an auto-tune sentinel meaning
     * "derive from read length". Raw mode falls back to 0. */
    if (pm->pshift < 0) pm->pshift = 0;

    pm->qmask    = (1u << pm->qbits) - 1u;
    pm->store_qmap = 0;
    pm->do_sel     = 0;
    pm->do_dedup   = 0;

    pm->fixed_len = (n_reads > 0) ? 1 : 0;
    for (size_t i = 1; i < n_reads; i++) {
        if (read_lengths[i] != read_lengths[0]) { pm->fixed_len = 0; break; }
    }

    pm->use_qtab = 0;
    pm->use_ptab = (pm->pbits > 0) ? 1 : 0;
    pm->use_dtab = (pm->dbits > 0) ? 1 : 0;
    pm->max_sym  = 255;

    for (int i = 0; i < 256; i++) {
        pm->qmap[i] = (uint32_t)i;
        pm->qtab[i] = (uint32_t)i;
    }

    if (pm->pbits) {
        for (int i = 0; i < 1024; i++)
            pm->ptab[i] = (uint32_t)MIN((1 << pm->pbits) - 1, i >> pm->pshift);
    } else {
        for (int i = 0; i < 1024; i++) pm->ptab[i] = 0;
    }

    {
        int dlim = (pm->dbits == 0) ? 0 : ((1 << pm->dbits) - 1);
        int dlen = (int)(sizeof(g_dsqr) / sizeof(*g_dsqr));
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
    return 0;
}

/* ---------------------------------------------------------------------------
 * fqz_qual_stats — verbatim port from htscodecs (lines 392-674).
 *
 * Walks the quality stream, builds per-position histograms, sets nsym, do_dedup,
 * and (when do_qa != 0) computes 1/2/4-way average-quality selector entropy and
 * may write selector indices into the high 16 bits of s->flags[rec].
 *
 * Skipped: the `one_param` path (htscodecs only uses it from TEST_MAIN).
 * We always pass one_param=-1 (gather over the whole input).
 * ------------------------------------------------------------------------ */

static void fqz_qual_stats_internal(fqz_slice_internal *s,
                                    const uint8_t *in, size_t in_size,
                                    fqz_param *pm,
                                    uint32_t qhist[256])
{
#define NP 32
    uint32_t qhistb[NP][256] = {{0}};   /* both reads */
    uint32_t qhist1[NP][256] = {{0}};   /* READ1 only */
    uint32_t qhist2[NP][256] = {{0}};   /* READ2 only */
    uint64_t t1[NP] = {0};
    uint64_t t2[NP] = {0};
    uint32_t avg[2560] = {0};

    int dir = 0;
    int last_len = 0;
    int do_dedup = 0;
    size_t rec;
    size_t i, j;
    int num_rec = 0;

    int max_sel = 0;
    int has_r2 = 0;
    for (rec = 0; rec < s->num_records; rec++) {
        num_rec++;
        if (max_sel < (int)(s->flags[rec] >> 16))
            max_sel = (int)(s->flags[rec] >> 16);
        if (s->flags[rec] & FQZ_FREAD2)
            has_r2 = 1;
    }

    int *avg_qual = (int *)calloc((s->num_records + 1), sizeof(int));
    if (!avg_qual) return;

    rec = i = j = 0;
    while (i < in_size) {
        if (rec < s->num_records) {
            j = s->len[rec];
            dir = (s->flags[rec] & FQZ_FREAD2) ? 1 : 0;
            if (i > 0 && (int)j == last_len &&
                !memcmp(in + i - last_len, in + i, j))
                do_dedup++;
        } else {
            j = in_size - i;
            dir = 0;
        }
        last_len = (int)j;

        uint32_t (*qh)[256] = dir ? qhist2 : qhist1;
        uint64_t *th        = dir ? t2     : t1;

        uint32_t tot = 0;
        for (; i < in_size && j > 0; i++, j--) {
            tot += in[i];
            qhist[in[i]]++;
            qhistb[j & (NP - 1)][in[i]]++;
            qh    [j & (NP - 1)][in[i]]++;
            th    [j & (NP - 1)]++;
        }
        tot = last_len ? (uint32_t)((tot * 10.0) / last_len + 0.5) : 0;

        avg_qual[rec] = (int)tot;
        avg[MIN(2559u, tot)]++;
        rec++;
    }
    pm->do_dedup = (((int)rec + 1) / (do_dedup + 1) < 500) ? 1 : 0;

    last_len = 0;

    /* Unique symbol count */
    pm->max_sym = 0;
    pm->nsym    = 0;
    for (i = 0; i < 256; i++) {
        if (qhist[i]) {
            pm->max_sym = (int)i;
            pm->nsym++;
        }
    }

    /* Auto-tune: does average-quality help? */
    if (pm->do_qa != 0) {
        double qf0 = pm->nsym > 8 ? 0.2 : 0.05;
        double qf1 = pm->nsym > 8 ? 0.5 : 0.22;
        double qf2 = pm->nsym > 8 ? 0.8 : 0.60;

        int total = 0;
        i = 0;
        while (i < 2560) {
            total += avg[i];
            if (total > qf0 * num_rec) break;
            avg[i++] = 0;
        }
        while (i < 2560) {
            total += avg[i];
            if (total > qf1 * num_rec) break;
            avg[i++] = 1;
        }
        while (i < 2560) {
            total += avg[i];
            if (total > qf2 * num_rec) break;
            avg[i++] = 2;
        }
        while (i < 2560)
            avg[i++] = 3;

        /* Compute simple entropy of merged signal vs split signal. */
        int qbin4[4][NP][256] = {{{0}}};
        int qbin2[2][NP][256] = {{{0}}};
        int qbin1   [NP][256] = {{0}};
        int qcnt4[4][NP] = {{0}};
        int qcnt2[4][NP] = {{0}};
        int qcnt1   [NP] = {0};

        i = 0; rec = 0;
        while (i < in_size) {
            if ((rec & 7) && rec < s->num_records) {
                /* Subsample for speed */
                i += s->len[rec++];
                continue;
            }
            if (rec < s->num_records)
                j = s->len[rec];
            else
                j = in_size - i;
            last_len = (int)j;

            uint32_t tot = (uint32_t)avg_qual[rec];
            int qb4 = (int)avg[MIN(2559u, tot)];
            int qb2 = qb4 / 2;

            for (; i < in_size && j > 0; i++, j--) {
                int x = (int)(j & (NP - 1));
                qbin4[qb4][x][in[i]]++;  qcnt4[qb4][x]++;
                qbin2[qb2][x][in[i]]++;  qcnt2[qb2][x]++;
                qbin1     [x][in[i]]++;  qcnt1     [x]++;
            }
            rec++;
        }

        double e1 = 0, e2 = 0, e4 = 0;
        for (j = 0; j < NP; j++) {
            for (i = 0; i < 256; i++) {
                if (qbin1   [j][i]) e1 += qbin1   [j][i] * fast_log_local(qbin1   [j][i] / (double)qcnt1   [j]);
                if (qbin2[0][j][i]) e2 += qbin2[0][j][i] * fast_log_local(qbin2[0][j][i] / (double)qcnt2[0][j]);
                if (qbin2[1][j][i]) e2 += qbin2[1][j][i] * fast_log_local(qbin2[1][j][i] / (double)qcnt2[1][j]);
                if (qbin4[0][j][i]) e4 += qbin4[0][j][i] * fast_log_local(qbin4[0][j][i] / (double)qcnt4[0][j]);
                if (qbin4[1][j][i]) e4 += qbin4[1][j][i] * fast_log_local(qbin4[1][j][i] / (double)qcnt4[1][j]);
                if (qbin4[2][j][i]) e4 += qbin4[2][j][i] * fast_log_local(qbin4[2][j][i] / (double)qcnt4[2][j]);
                if (qbin4[3][j][i]) e4 += qbin4[3][j][i] * fast_log_local(qbin4[3][j][i] / (double)qcnt4[3][j]);
            }
        }
        e1 /= -log_local_2_div_8();
        e2 /= -log_local_2_div_8();
        e4 /= -log_local_2_div_8();

        double qm = pm->do_qa > 0 ? 1.0 : 0.98;
        if ((pm->do_qa == -1 || pm->do_qa >= 4) &&
            e4 + (double)s->num_records / 4 < e2 * qm + (double)s->num_records / 8 &&
            e4 + (double)s->num_records / 4 < e1 * qm) {
            for (i = 0; i < s->num_records; i++)
                s->flags[i] |= avg[MIN(2559u, (uint32_t)avg_qual[i])] << 16;
            pm->do_sel = 1;
            max_sel = 3;
        } else if ((pm->do_qa == -1 || pm->do_qa >= 2) &&
                   e2 + (double)s->num_records / 8 < e1 * qm) {
            for (i = 0; i < s->num_records; i++)
                s->flags[i] |= (avg[MIN(2559u, (uint32_t)avg_qual[i])] >> 1) << 16;
            pm->do_sel = 1;
            max_sel = 1;
        }

        if (pm->do_qa == -1) {
            /* Assume qual, pos, delta in that order. */
            if (pm->pbits > 0 && pm->dbits > 0) {
                pm->sloc = pm->dloc - 1;
                pm->pbits--;
                pm->dbits--;
                pm->dloc++;
            } else if (pm->dbits >= 2) {
                pm->sloc = pm->dloc;
                pm->dbits -= 2;
                pm->dloc += 2;
            } else if (pm->qbits >= 2) {
                pm->qbits -= 2;
                pm->ploc -= 2;
                pm->sloc = 16 - 2 - pm->do_r2;
                if (pm->qbits == 6 && pm->qshift == 5)
                    pm->qbits--;
            }
            pm->do_qa = 4;
        }
    }

    /* Auto-tune: does READ1/READ2 split help? */
    if (has_r2 || pm->do_r2) {
        double e1 = 0, e2 = 0;

        for (j = 0; j < NP; j++) {
            if (!t1[j] || !t2[j]) continue;
            for (i = 0; i < 256; i++) {
                if (!qhistb[j][i]) continue;
                e1 -= (qhistb[j][i]) * log_local((double)qhistb[j][i] / (double)(t1[j] + t2[j]));
                if (qhist1[j][i])
                    e2 -= qhist1[j][i] * log_local((double)qhist1[j][i] / (double)t1[j]);
                if (qhist2[j][i])
                    e2 -= qhist2[j][i] * log_local((double)qhist2[j][i] / (double)t2[j]);
            }
        }
        e1 /= log_local_2_x_8();
        e2 /= log_local_2_x_8();

        double qm = pm->do_r2 > 0 ? 1.0 : 0.95;
        if (e2 + (8 + (double)s->num_records / 8) < e1 * qm) {
            for (rec = 0; rec < s->num_records; rec++) {
                int sel = (int)(s->flags[rec] >> 16);
                s->flags[rec] = (s->flags[rec] & 0xffff) |
                    ((s->flags[rec] & FQZ_FREAD2)
                     ? ((uint32_t)((sel * 2) + 1) << 16)
                     : ((uint32_t)((sel * 2) + 0) << 16));
                if (max_sel < (int)(s->flags[rec] >> 16))
                    max_sel = (int)(s->flags[rec] >> 16);
            }
        }
    }

    if (max_sel > 0) {
        pm->do_sel  = 1;
        pm->max_sel = max_sel;
    }

    free(avg_qual);
#undef NP
}

/* ---------------------------------------------------------------------------
 * fqz_pick_parameters — verbatim port from htscodecs (lines 736-925).
 *
 * Builds a fqz_gparams from the strategy preset and the histogram pass.
 * `strat == FQZ_NSTRATS-1` (Custom) bypasses the auto-adjust pass — used
 * internally by Custom; we don't expose strategy_hint=4 to public callers.
 * ------------------------------------------------------------------------ */

static int fqz_pick_parameters_internal(fqz_gparams *gp,
                                        int vers,
                                        int strat,
                                        fqz_slice_internal *s,
                                        const uint8_t *in,
                                        size_t in_size)
{
    /* dsqr from htscodecs — local copy; clamped per-call by dbits below. */
    int dsqr[64];
    for (int k = 0; k < 64; k++) dsqr[k] = g_dsqr[k];

    uint32_t qhist[256] = {0};

    if (strat >= FQZ_NSTRATS) strat = FQZ_NSTRATS - 1;

    memset(gp, 0, sizeof(*gp));
    gp->vers    = FQZ_VERS;
    gp->nparam  = 1;
    gp->max_sel = 0;

    /* CRAM 3.1 doesn't reverse upfront, so DO_REV is gated on vers == 3
     * (which we never use). */
    if (vers == 3) gp->gflags |= GFLAG_DO_REV;

    fqz_param *pm = &gp->p;

    pm->qbits  = FQZ_STRAT_OPTS[strat].qbits;
    pm->qshift = FQZ_STRAT_OPTS[strat].qshift;
    pm->pbits  = FQZ_STRAT_OPTS[strat].pbits;
    pm->pshift = FQZ_STRAT_OPTS[strat].pshift;
    pm->dbits  = FQZ_STRAT_OPTS[strat].dbits;
    pm->dshift = FQZ_STRAT_OPTS[strat].dshift;
    pm->qloc   = FQZ_STRAT_OPTS[strat].qloc;
    pm->sloc   = FQZ_STRAT_OPTS[strat].sloc;
    pm->ploc   = FQZ_STRAT_OPTS[strat].ploc;
    pm->dloc   = FQZ_STRAT_OPTS[strat].dloc;
    pm->do_r2  = FQZ_STRAT_OPTS[strat].do_r2;
    pm->do_qa  = FQZ_STRAT_OPTS[strat].do_qa;

    /* Validity-check input lengths vs buffer size (htscodecs does this). */
    size_t tlen = 0;
    for (size_t i = 0; i < s->num_records; i++) {
        if (tlen + s->len[i] > in_size) {
            /* htscodecs mutates s->len[i] here; we treat it as a hard error
             * since our public API guarantees sum(read_lengths)==n_qualities
             * (compress entry already validated). */
            return -1;
        }
        tlen += s->len[i];
    }
    if (s->num_records > 0 && tlen < in_size) {
        return -1;
    }

    /* Quality stats over all records (one_param=-1) */
    fqz_qual_stats_internal(s, in, in_size, pm, qhist);

    pm->store_qmap = (pm->nsym <= 8 && pm->nsym * 2 < pm->max_sym) ? 1 : 0;

    /* Fixed-length detection */
    {
        uint32_t first_len = s->num_records ? s->len[0] : 0;
        size_t i;
        for (i = 1; i < s->num_records; i++) {
            if (s->len[i] != first_len) break;
        }
        pm->fixed_len = (i == s->num_records) ? 1 : 0;
    }
    pm->use_qtab = 0;

    if (strat >= FQZ_NSTRATS - 1)
        goto manually_set;

    if (pm->pshift < 0) {
        double l0 = (double)(s->num_records ? s->len[0] : 1);
        pm->pshift = (int)MAX(0, log_local((double)l0 / (1 << pm->pbits)) /
                                  log_local(2.0) + 0.5);
    }

    if (pm->nsym <= 4) {
        /* NovaSeq Q4 */
        pm->qshift = 2;
        if (in_size < 5000000) {
            pm->pbits  = 2;
            pm->pshift = 5;
        }
    } else if (pm->nsym <= 8) {
        /* HiSeqX */
        pm->qbits  = MIN(pm->qbits, 9);
        pm->qshift = 3;
        if (in_size < 5000000)
            pm->qbits = 6;
    }

    if (in_size < 300000) {
        pm->qbits = pm->qshift;
        pm->dbits = 2;
    }

manually_set:
    {
        size_t k;
        for (k = 0; k < sizeof(dsqr) / sizeof(*dsqr); k++)
            if (dsqr[k] > (1 << pm->dbits) - 1)
                dsqr[k] = (1 << pm->dbits) - 1;
    }

    if (pm->store_qmap) {
        int j;
        size_t i2;
        for (i2 = 0, j = 0; i2 < 256; i2++) {
            if (qhist[i2]) pm->qmap[i2] = (uint32_t)j++;
            else           pm->qmap[i2] = (uint32_t)INT_MAX;
        }
        pm->max_sym = pm->nsym;
    } else {
        pm->nsym = 255;
        for (size_t i2 = 0; i2 < 256; i2++)
            pm->qmap[i2] = (uint32_t)i2;
    }
    if (gp->max_sym < pm->max_sym)
        gp->max_sym = pm->max_sym;

    /* qtab: 1:1 (htscodecs leaves room for custom mappings) */
    if (pm->qbits) {
        for (size_t i2 = 0; i2 < 256; i2++)
            pm->qtab[i2] = (uint32_t)i2;
    }
    pm->qmask = (1u << pm->qbits) - 1u;

    if (pm->pbits) {
        for (size_t i2 = 0; i2 < 1024; i2++)
            pm->ptab[i2] = (uint32_t)MIN((1 << pm->pbits) - 1,
                                          (int)(i2 >> pm->pshift));
    }

    if (pm->dbits) {
        for (size_t i2 = 0; i2 < 256; i2++)
            pm->dtab[i2] = (uint32_t)dsqr[MIN(
                sizeof(dsqr)/sizeof(*dsqr) - 1,
                (size_t)(i2 >> pm->dshift))];
    }

    pm->use_ptab = (pm->pbits > 0) ? 1 : 0;
    pm->use_dtab = (pm->dbits > 0) ? 1 : 0;

    pm->pflags =
        (uint8_t)((pm->use_qtab   ? PFLAG_HAVE_QTAB : 0) |
                  (pm->use_dtab   ? PFLAG_HAVE_DTAB : 0) |
                  (pm->use_ptab   ? PFLAG_HAVE_PTAB : 0) |
                  (pm->do_sel     ? PFLAG_DO_SEL    : 0) |
                  (pm->fixed_len  ? PFLAG_DO_LEN    : 0) |
                  (pm->do_dedup   ? PFLAG_DO_DEDUP  : 0) |
                  (pm->store_qmap ? PFLAG_HAVE_QMAP : 0));

    gp->max_sel = 0;
    if (pm->do_sel) {
        gp->max_sel = 1;
        gp->gflags |= GFLAG_HAVE_STAB;
        /* stab is already zero from memset */
    }

    if (gp->max_sel && s->num_records) {
        int max = 0;
        for (size_t i2 = 0; i2 < s->num_records; i2++) {
            if (max < (int)(s->flags[i2] >> 16))
                max = (int)(s->flags[i2] >> 16);
        }
        gp->max_sel = max;
    }

    return 0;
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
    out[idx++] = (uint8_t)pm->max_sym;

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
                             const uint32_t *flags_u32,
                             const uint8_t *qual_in,
                             size_t *in_i,
                             fqz_state *st,
                             fqz_model *model,
                             rc_cram_encoder *e,
                             uint32_t *last) {
    (void)gp;

    if (pm->do_sel) {
        /* Selector lives in the high 16 bits of flags_u32[rec] (placed there
         * by fqz_qual_stats during auto-tune). Mirror htscodecs's encoder. */
        st->s = (st->rec < n_reads && flags_u32)
                ? (flags_u32[st->rec] >> 16)
                : 0;
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
        /* Mirror htscodecs (lines 983-998): emit a 1-bit dup flag indicating
         * whether this read is byte-identical to the previous one. If yes,
         * skip its quality bytes; the decoder will re-emit them from the
         * previous read's buffer. */
        size_t i = *in_i;
        if (i && len == st->last_len &&
            qual_in &&
            !memcmp(qual_in + i - st->last_len, qual_in + i, (size_t)len)) {
            sm_encode(&model->dup, e, 1);
            *in_i = i + (size_t)(len - 1);
            st->p = 0;
            st->last_len = len;
            return 1;  /* signal "is a dup, skip quality emit" */
        } else {
            sm_encode(&model->dup, e, 0);
        }
        st->last_len = len;
    }

    return 0;
}

static int decompress_new_read(const fqz_gparams *gp,
                               const fqz_param *pm_in,
                               size_t expected_reads,
                               const uint32_t *read_lengths,
                               uint8_t *out_buf,
                               size_t *out_i,
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
    /* matches htscodecs decompress_new_read line 1416-1417: `len <= 0` is rejected. */
    if (len == 0 || len > out_remaining) return -1;

    /* Sanity: if we know read_lengths up front (Phase 2 always does),
     * cross-check. This catches off-by-one parameter-header errors early. */
    if (read_lengths && st->rec < expected_reads) {
        if (len != read_lengths[st->rec]) return -1;
    }

    if (pm_in->do_dedup) {
        /* Mirror htscodecs decompress_new_read (around line 1428):
         * read 1-bit dup flag; if set, copy previous read's qualities into
         * out_buf and advance, returning 1 to signal "no quality decode". */
        uint16_t dup_flag = sm_decode(&model->dup, d);
        if (dup_flag == 1) {
            if (!out_buf || !out_i) return -1;
            size_t i = *out_i;
            if (i < (size_t)st->last_len) return -1;
            if (i + (size_t)len > i + out_remaining) return -1;
            memcpy(out_buf + i, out_buf + i - st->last_len, (size_t)len);
            *out_i = i + len;
            st->rec++;
            st->p = 0;
            st->last_len = (int)len;
            return 1;
        }
        st->last_len = (int)len;
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
    /* Strategy 4 (Custom) is reserved for internal auto-tune use; not exposed
     * via the public API. */
    if (!(strategy_hint == -1 ||
          (strategy_hint >= 0 && strategy_hint <= 3))) return -2;
    if (!qual_in || !read_lengths || !out || !out_len) return -3;
    if (n_reads == 0 || n_qualities == 0) return -3;

    /* Sanity: sum(read_lengths) == n_qualities */
    size_t tlen = 0;
    for (size_t i = 0; i < n_reads; i++) tlen += read_lengths[i];
    if (tlen != n_qualities) return -3;

    size_t out_cap = *out_len;
    if (out_cap < 64) return -4;

    fqz_gparams gp;
    uint32_t *flags_u32 = NULL;

    if (strategy_hint == -1) {
        /* Auto-tune: histogram pass + htscodecs-style parameter dispatch.
         * fqz_qual_stats writes selector bits into the high 16 bits of
         * flags[], so we need a mutable uint32_t copy of the public uint8
         * stream. */
        flags_u32 = (uint32_t *)calloc(n_reads ? n_reads : 1, sizeof(uint32_t));
        if (!flags_u32) return -5;
        if (flags) {
            for (size_t i = 0; i < n_reads; i++)
                flags_u32[i] = (uint32_t)flags[i];
        }
        fqz_slice_internal slice = { n_reads, read_lengths, flags_u32 };
        /* Default starting strategy for auto-tune is 0 (Generic, level<7),
         * matching htscodecs's typical interp_compress dispatch. */
        if (fqz_pick_parameters_internal(&gp, FQZ_VERS, /*strat=*/0,
                                         &slice, qual_in, n_qualities) < 0) {
            free(flags_u32);
            return -5;
        }
    } else {
        /* Fixed preset: raw values from FQZ_STRAT_OPTS, no histogram pass.
         * No selector ever set, so flags_u32 stays NULL. */
        if (fqz_setup_strategy(&gp, strategy_hint, read_lengths, n_reads) < 0)
            return -5;
    }

    /* Header: var_put_u32(in_size) + parameter block */
    int hdr = 0;
    hdr += var_put_u32(out + hdr, (uint32_t)n_qualities);
    hdr += fqz_store_parameters(&gp, out + hdr);

    if ((size_t)hdr + 5 > out_cap) { free(flags_u32); return -4; }

    /* Pre-shift ptab/dtab so the inner loop is plain add */
    fqz_pre_shift_tables(&gp.p);

    /* Build models.
     * Heap-allocate: fqz_model is ~2 MB (sm_model qual[65536]); larger than
     * default thread stack on JVM/ObjC NSOperation queues. */
    fqz_model *model = malloc(sizeof(fqz_model));
    if (!model) { free(flags_u32); return -5; }
    if (fqz_create_models(model, &gp) < 0) {
        free(model);
        free(flags_u32);
        return -5;
    }

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
            int r = compress_new_read(&gp, pm, read_lengths, n_reads,
                                      flags_u32, qual_in, &i,
                                      &st, model, &e, &last);
            if (r < 0) {
                fqz_destroy_models(model);
                free(model);
                free(flags_u32);
                return -6;
            }
            if (r > 0) {
                /* Dedup hit: compress_new_read already advanced `i` to the
                 * last byte of this read; bump past it and continue. */
                i++;
                continue;
            }
        }

        /* Emit one quality */
        uint8_t q  = qual_in[i++];
        uint8_t qm = (uint8_t)pm->qmap[q];
        sm_encode(&model->qual[last], &e, qm);
        last = fqz_update_ctx(pm, &st, qm);

        if (e.err) {
            fqz_destroy_models(model);
            free(model);
            free(flags_u32);
            return -7;
        }
    }

    size_t rc_bytes = rc_cram_encoder_finish(&e);
    if (e.err) {
        fqz_destroy_models(model);
        free(model);
        free(flags_u32);
        return -7;
    }

    *out_len = (size_t)hdr + rc_bytes;
    fqz_destroy_models(model);
    free(model);
    free(flags_u32);
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
    /* flags: unused in Phase 2 strategy 1 (GFLAG_DO_REV=0, do_sel=0). When
     * Task 8 lands auto-tune, flags becomes the per-read flag stream that
     * decompress_new_read consumes for do_r2 / do_sel — pass it through
     * to the helper rather than discarding here. */
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

    /* Heap-allocate: fqz_model is ~2 MB (sm_model qual[65536]); larger than
     * default thread stack on JVM/ObjC NSOperation queues. */
    fqz_model *model = malloc(sizeof(fqz_model));
    if (!model) return -5;
    if (fqz_create_models(model, &gp) < 0) { free(model); return -5; }

    rc_cram_decoder d;
    rc_cram_decoder_init(&d, in + hdr, in_len - (size_t)hdr);
    if (d.err) { fqz_destroy_models(model); free(model); return -6; }

    fqz_state st = {0};
    st.first_len = 1;
    st.rec       = 0;

    uint32_t last = 0;
    const fqz_param *pm = &gp.p;

    size_t i = 0;
    while (i < n_qualities) {
        if (st.p == 0) {
            int r = decompress_new_read(&gp, pm, n_reads, read_lengths,
                                        out, &i,
                                        &st, model, &d, &pm,
                                        n_qualities - i);
            if (r < 0) { fqz_destroy_models(model); free(model); return -6; }
            if (r > 0) continue;  /* dedup hit: bytes already copied into out */
            last = st.ctx;
        }

        do {
            uint16_t Q = sm_decode(&model->qual[last], &d);
            last = fqz_update_ctx(pm, &st, Q);
            out[i++] = (uint8_t)pm->qmap[Q];
            if (d.err) { fqz_destroy_models(model); free(model); return -6; }
        } while (st.p != 0 && i < n_qualities);
    }

    fqz_destroy_models(model);
    free(model);
    return 0;
}
