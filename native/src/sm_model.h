/* native/src/sm_model.h
 *
 * Adaptive simple model shared by the fqzcomp qualities coders
 * (V4 CRAM body in fqzcomp_qual.c, V5 sequence-context body in
 * fqzcomp_seqctx.c). Moved verbatim from fqzcomp_qual.c.
 */
#ifndef TTIO_SM_MODEL_H
#define TTIO_SM_MODEL_H

#include <stdint.h>
#include <stdlib.h>

#include "rc_cram.h"

/* htscodecs c_simple_model.h: MAX_FREQ = (1<<16)-17, STEP = 16 */
#define SM_MAX_FREQ ((1u<<16) - 17u)
#define SM_STEP     16u

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
/* Initialise into caller-supplied storage of nsym+2 entries, which
 * must already be zeroed. The model does not own it, so sm_destroy is
 * not called on a model set up this way: a bank of contexts is then one
 * allocation instead of one per context. */
static inline void sm_init_at(sm_model *m, int nsym, int max_sym,
                              sm_symfreq *storage) {
    m->nsym = nsym;
    m->F = storage;
    m->F[0].symbol = 0;
    m->F[0].freq   = (uint16_t)SM_MAX_FREQ;
    for (int i = 0; i < max_sym; i++) {
        m->F[i + 1].symbol = (uint16_t)i;
        m->F[i + 1].freq   = 1;
    }
    for (int i = max_sym; i < nsym; i++) {
        m->F[i + 1].symbol = (uint16_t)i;
        m->F[i + 1].freq   = 0;
    }
    m->tot_freq = (uint32_t)max_sym;
}

static inline int sm_init(sm_model *m, int nsym, int max_sym) {
    /* +2: one for the sentinel at [0], one for the terminal at [nsym+1] */
    sm_symfreq *f = (sm_symfreq *)calloc((size_t)(nsym + 2), sizeof(*f));
    if (!f) return -1;
    sm_init_at(m, nsym, max_sym, f);
    return 0;
}


static inline void sm_destroy(sm_model *m) {
    if (m->F) { free(m->F); m->F = NULL; }
}

static inline void sm_normalize(sm_model *m) {
    sm_symfreq *s;
    m->tot_freq = 0;
    /* Walk forward through F[1..] until freq==0 (terminal stops loop). */
    for (s = &m->F[1]; s->freq; s++) {
        s->freq -= s->freq >> 1;
        m->tot_freq += s->freq;
    }
}

static inline void sm_encode(sm_model *m, rc_cram_encoder *e, uint16_t sym) {
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

static inline uint16_t sm_decode(sm_model *m, rc_cram_decoder *d) {
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

#endif /* TTIO_SM_MODEL_H */
