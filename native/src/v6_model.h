/* native/src/v6_model.h
 *
 * Adaptive symbol model for M94.Z V6, backed by a Fenwick tree.
 *
 * The V4 and V5 bodies use sm_model, which keeps symbols loosely sorted
 * by frequency and finds one by walking the array from the front. That
 * costs on average half the alphabet in dependent loads per coded
 * symbol, and the walk length varies per symbol, which on a GPU makes
 * every lane in a warp wait for its slowest member. Measured on the
 * Phase 2 spike, it is the difference between 140 MB/s and 700 MB/s.
 *
 * This model keeps symbols in dense alphabet order and holds their
 * cumulative frequencies in a Fenwick tree, so both the encoder's
 * prefix-sum lookup and the decoder's inverse search are O(log nsym)
 * with a fixed, data-independent step count.
 *
 * Compressed size is unaffected. The range coder advances as
 * range = (range / tot) * freq, which does not involve the cumulative
 * frequency, so the renormalisation count -- and therefore the output
 * length -- depends only on the sequence of (freq, tot) pairs. Those
 * evolve identically here. Only the byte values differ, plus whatever
 * the coder's deferred carry bytes contribute at the very end.
 *
 * sm_model is untouched: V4 and V5 are shipped formats and must keep
 * producing the bytes they produce today.
 */
#ifndef TTIO_V6_MODEL_H
#define TTIO_V6_MODEL_H

#include <stddef.h>
#include <stdint.h>

/* Same ceiling and step the CRAM model uses. */
#define V6_SM_MAX_FREQ ((1u << 16) - 17u)
#define V6_SM_STEP     16u

/* One contiguous u16 block per context: freq[nsym], then a 1-based
 * Fenwick tree of nsym+1 entries. */
typedef struct {
    uint16_t *freq;   /* nsym entries, dense alphabet order */
    uint16_t *tree;   /* tree[1..nsym] */
    unsigned  nsym;
    unsigned  tot;
} v6_model;

static inline size_t v6_model_words(unsigned nsym) {
    return (size_t)nsym * 2u + 2u;
}

static inline unsigned v6_lsb(unsigned i) {
    return i & (unsigned)(-(int)i);
}

static inline void v6_tree_build(v6_model *m) {
    for (unsigned i = 1; i <= m->nsym; i++) m->tree[i] = m->freq[i - 1];
    for (unsigned i = 1; i <= m->nsym; i++) {
        unsigned j = i + v6_lsb(i);
        if (j <= m->nsym) m->tree[j] = (uint16_t)(m->tree[j] + m->tree[i]);
    }
}

/* pool must hold v6_model_words(nsym) entries. seed[i] is the starting
 * frequency of dense symbol i and must be >= 1: a symbol with zero
 * frequency cannot be coded at all. */
static inline void v6_model_init(v6_model *m, uint16_t *pool, unsigned nsym,
                                 const uint16_t *seed) {
    m->nsym = nsym;
    m->freq = pool;
    m->tree = pool + nsym;   /* tree[0] unused, so nsym+1 entries follow */
    m->tot = 0;
    for (unsigned i = 0; i < nsym; i++) {
        m->freq[i] = seed[i];
        m->tot += seed[i];
    }
    for (unsigned i = 0; i <= nsym; i++) m->tree[i] = 0;
    v6_tree_build(m);
}

static inline unsigned v6_model_freq(const v6_model *m, unsigned s) {
    return m->freq[s];
}

/* Sum of freq[0 .. s-1]. */
static inline unsigned v6_model_prefix(const v6_model *m, unsigned s) {
    unsigned acc = 0;
    for (unsigned i = s; i > 0; i -= v6_lsb(i)) acc += m->tree[i];
    return acc;
}

/* The inverse: the symbol whose interval contains target, and that
 * interval's base. Requires target < tot. */
static inline unsigned v6_model_find(const v6_model *m, unsigned target,
                                     unsigned *out_cf) {
    unsigned pos = 0, rem = target, pw = 1;
    while ((pw << 1) <= m->nsym) pw <<= 1;
    for (; pw > 0; pw >>= 1) {
        unsigned nxt = pos + pw;
        if (nxt <= m->nsym && m->tree[nxt] <= rem) {
            pos = nxt;
            rem -= m->tree[nxt];
        }
    }
    *out_cf = target - rem;
    return pos;
}

static inline void v6_model_normalize(v6_model *m) {
    m->tot = 0;
    for (unsigned i = 0; i < m->nsym; i++) {
        unsigned f = m->freq[i];
        f -= f >> 1;              /* never reaches 0 from a nonzero start */
        m->freq[i] = (uint16_t)f;
        m->tot += f;
    }
    v6_tree_build(m);
}

static inline void v6_model_update(v6_model *m, unsigned s) {
    m->freq[s] = (uint16_t)(m->freq[s] + V6_SM_STEP);
    for (unsigned i = s + 1; i <= m->nsym; i += v6_lsb(i))
        m->tree[i] = (uint16_t)(m->tree[i] + V6_SM_STEP);
    m->tot += V6_SM_STEP;
    if (m->tot > V6_SM_MAX_FREQ) v6_model_normalize(m);
}

#endif /* TTIO_V6_MODEL_H */
