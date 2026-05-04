/* Round-trip + invariants tests for the NAME_TOKENIZED v2 codec. */
#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ttio_rans.h"
#include "name_tok_v2.h"

static int round_trip(const char * const *names, uint64_t n) {
    size_t total_bytes = 0;
    for (uint64_t i = 0; i < n; i++) total_bytes += strlen(names[i]);
    size_t cap = ttio_name_tok_v2_max_encoded_size(n, total_bytes > 0 ? total_bytes : 1);
    uint8_t *enc = (uint8_t *)malloc(cap);
    if (!enc) return -200;
    size_t enc_len = cap;
    int rc = ttio_name_tok_v2_encode(names, n, enc, &enc_len);
    if (rc != 0) { free(enc); return rc; }
    if (memcmp(enc, "NTK2", 4) != 0) { free(enc); return -100; }
    char **dec = NULL;
    uint64_t dec_n = 0;
    rc = ttio_name_tok_v2_decode(enc, enc_len, &dec, &dec_n);
    if (rc != 0) { free(enc); return rc; }
    if (dec_n != n) {
        for (uint64_t j = 0; j < dec_n; j++) free(dec[j]);
        free(dec); free(enc);
        return -101;
    }
    for (uint64_t i = 0; i < n; i++) {
        if (strcmp(names[i], dec[i]) != 0) {
            fprintf(stderr, "mismatch at %llu: '%s' vs '%s'\n",
                    (unsigned long long)i, names[i], dec[i]);
            for (uint64_t j = 0; j < dec_n; j++) free(dec[j]);
            free(dec); free(enc);
            return -102;
        }
    }
    for (uint64_t i = 0; i < dec_n; i++) free(dec[i]);
    free(dec); free(enc);
    return 0;
}

static void test_empty(void) {
    int rc = round_trip(NULL, 0);
    assert(rc == 0);
    printf("test_empty: PASS\n");
}

static void test_single(void) {
    const char *names[] = {"EAS220_R1:8:1:0:1234"};
    int rc = round_trip(names, 1);
    assert(rc == 0);
    printf("test_single: PASS\n");
}

static void test_dup(void) {
    const char *names[] = {
        "EAS220_R1:8:1:0:1234",
        "EAS220_R1:8:1:0:1234",
    };
    int rc = round_trip(names, 2);
    assert(rc == 0);
    printf("test_dup: PASS\n");
}

static void test_match(void) {
    const char *names[] = {
        "EAS220_R1:8:1:0:1234",
        "EAS220_R1:8:1:0:1235",
        "EAS220_R1:8:1:0:1236",
        "EAS220_R1:8:1:0:1237",
    };
    int rc = round_trip(names, 4);
    assert(rc == 0);
    printf("test_match: PASS\n");
}

static void test_columnar(void) {
    /* 50 Illumina-style names with varying tile/x/y/run. */
    const uint64_t N = 50;
    char **names = (char **)malloc(N * sizeof(*names));
    assert(names);
    for (uint64_t i = 0; i < N; i++) {
        names[i] = (char *)malloc(64);
        assert(names[i]);
        snprintf(names[i], 64, "EAS220_R1:8:1:%llu:%llu",
                 (unsigned long long)(100 + i),
                 (unsigned long long)(2000 + i * 3));
    }
    int rc = round_trip((const char * const *)names, N);
    assert(rc == 0);
    for (uint64_t i = 0; i < N; i++) free(names[i]);
    free(names);
    printf("test_columnar: PASS\n");
}

static void test_two_blocks(void) {
    /* 4097 names — forces a 2-block split (block size 4096). */
    const uint64_t N = 4097;
    char **names = (char **)malloc(N * sizeof(*names));
    assert(names);
    for (uint64_t i = 0; i < N; i++) {
        names[i] = (char *)malloc(64);
        assert(names[i]);
        snprintf(names[i], 64, "READ:%llu:%llu",
                 (unsigned long long)(i / 100),
                 (unsigned long long)i);
    }
    int rc = round_trip((const char * const *)names, N);
    assert(rc == 0);
    for (uint64_t i = 0; i < N; i++) free(names[i]);
    free(names);
    printf("test_two_blocks: PASS\n");
}

static void test_mixed_shapes(void) {
    /* Heterogeneous tokenisations: forces VERB for some rows.  The
     * first row sets COL shape; rows that don't match it must fall
     * back to VERB. */
    const char *names[] = {
        "EAS220_R1:8:1:0:1234",            /* str:num:num:num:num */
        "EAS220_R1:8:1:0:1235",            /* matches → MATCH-K */
        "READ_NAME_NO_NUMBERS_HERE",       /* one str token → VERB */
        "EAS220_R1:8:1:0:1236",            /* MATCH-K again */
        "ABC:1:2",                         /* different shape → VERB */
        "EAS220_R1:8:1:0:1237",            /* MATCH-K */
    };
    int rc = round_trip(names, 6);
    assert(rc == 0);
    printf("test_mixed_shapes: PASS\n");
}

int main(void) {
    test_empty();
    test_single();
    test_dup();
    test_match();
    test_columnar();
    test_two_blocks();
    test_mixed_shapes();
    return 0;
}
