/* native/tests/test_v6_model.c
 *
 * The V6 Fenwick-backed adaptive model: prefix sums, the search that
 * inverts them, adaptive update, and normalisation. These are the
 * invariants the range coder depends on; if any of them slips the
 * stream stops round-tripping.
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "../src/v6_model.h"

static int failures = 0;
#define CHECK(cond, name) do { \
    if (cond) printf("ok   %s\n", name); \
    else { printf("FAIL %s\n", name); failures++; } \
} while (0)

/* Independent reference: sum the frequency array directly. */
static unsigned ref_prefix(const v6_model *m, unsigned s) {
    unsigned acc = 0;
    for (unsigned i = 0; i < s; i++) acc += v6_model_freq(m, i);
    return acc;
}

static int prefixes_agree(const v6_model *m, const char *what) {
    for (unsigned s = 0; s <= m->nsym; s++) {
        if (v6_model_prefix(m, s) != ref_prefix(m, s)) {
            printf("     prefix mismatch at %u (%s): tree %u ref %u\n", s,
                   what, v6_model_prefix(m, s), ref_prefix(m, s));
            return 0;
        }
    }
    return 1;
}

/* Every target in [0, tot) must map back to the symbol whose interval
 * contains it, with the matching cumulative frequency. */
static int search_inverts_prefix(const v6_model *m) {
    for (unsigned t = 0; t < m->tot; t++) {
        unsigned cf = 0;
        unsigned s = v6_model_find(m, t, &cf);
        if (s >= m->nsym) return 0;
        unsigned lo = ref_prefix(m, s);
        unsigned hi = lo + v6_model_freq(m, s);
        if (t < lo || t >= hi || cf != lo) {
            printf("     search wrong for target %u: sym %u cf %u "
                   "interval [%u,%u)\n", t, s, cf, lo, hi);
            return 0;
        }
    }
    return 1;
}

int main(void) {
    enum { A = 7 };
    uint16_t seed[A] = { 40, 3, 12, 1, 25, 8, 1 };
    unsigned seed_total = 0;
    for (int i = 0; i < A; i++) seed_total += seed[i];

    size_t    words = v6_model_words(A);
    uint16_t *pool = calloc(words, sizeof(uint16_t));
    v6_model  m;
    v6_model_init(&m, pool, A, seed);

    CHECK(m.tot == seed_total, "seeded total matches the seed table");
    CHECK(prefixes_agree(&m, "after seeding"), "prefix sums after seeding");
    CHECK(search_inverts_prefix(&m), "search inverts prefix after seeding");

    /* Symbol order is the dense alphabet order, not frequency order:
     * that is what lets the search be a tree walk. */
    int ordered = 1;
    for (unsigned i = 0; i < A; i++)
        if (v6_model_freq(&m, i) != seed[i]) ordered = 0;
    CHECK(ordered, "symbols stay in dense alphabet order");

    /* Adaptive update. */
    for (int r = 0; r < 500; r++) {
        v6_model_update(&m, (unsigned)(r % A));
    }
    CHECK(prefixes_agree(&m, "after updates"), "prefix sums after updates");
    CHECK(search_inverts_prefix(&m), "search inverts prefix after updates");

    {
        unsigned sum = 0;
        for (unsigned i = 0; i < A; i++) sum += v6_model_freq(&m, i);
        CHECK(sum == m.tot, "total tracks the frequency array");
    }

    /* Drive it over the normalisation threshold. */
    unsigned before = m.tot;
    int      normalised = 0;
    for (int r = 0; r < 200000 && !normalised; r++) {
        v6_model_update(&m, 2);
        if (m.tot < before) normalised = 1;
        before = m.tot;
    }
    CHECK(normalised, "normalisation triggers below the frequency ceiling");
    CHECK(m.tot <= V6_SM_MAX_FREQ, "total stays under the ceiling");
    CHECK(prefixes_agree(&m, "after normalise"),
          "prefix sums after normalisation");
    CHECK(search_inverts_prefix(&m),
          "search inverts prefix after normalisation");

    {
        int all_live = 1;
        for (unsigned i = 0; i < A; i++)
            if (v6_model_freq(&m, i) == 0) all_live = 0;
        CHECK(all_live, "no symbol is normalised out of existence");
    }

    /* A one-symbol alphabet is the degenerate case the block coder can
     * hand us for a uniform block. */
    {
        uint16_t one_seed[1] = { 1 };
        uint16_t *p1 = calloc(v6_model_words(1), sizeof(uint16_t));
        v6_model m1;
        v6_model_init(&m1, p1, 1, one_seed);
        unsigned cf = 99;
        CHECK(v6_model_find(&m1, 0, &cf) == 0 && cf == 0,
              "single-symbol alphabet resolves");
        v6_model_update(&m1, 0);
        CHECK(v6_model_freq(&m1, 0) == 1 + V6_SM_STEP,
              "single-symbol alphabet updates");
        free(p1);
    }

    free(pool);
    printf("%s\n", failures ? "FAILURES" : "all passed");
    return failures ? 1 : 0;
}
