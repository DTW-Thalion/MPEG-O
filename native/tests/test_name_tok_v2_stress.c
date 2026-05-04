#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "ttio_rans.h"
#include "name_tok_v2.h"

static char *random_name(unsigned *seed) {
    /* Generate Illumina-style structured names with variation */
    char *out = malloc(64);
    int run = rand_r(seed) % 8;
    int lane = rand_r(seed) % 8 + 1;
    int tile = rand_r(seed) % 100;
    int x = rand_r(seed) % 5000;
    int y = rand_r(seed) % 5000;
    snprintf(out, 64, "EAS%d_R1:%d:%d:%d:%d", run, lane, tile, x, y);
    return out;
}

static void test_random_corpus(uint64_t n) {
    unsigned seed = 42;
    char **names = malloc(sizeof(char*) * n);
    size_t total_bytes = 0;
    for (uint64_t i = 0; i < n; i++) {
        names[i] = random_name(&seed);
        total_bytes += strlen(names[i]);
    }

    size_t cap = ttio_name_tok_v2_max_encoded_size(n, total_bytes);
    uint8_t *enc = malloc(cap);
    size_t enc_len = cap;
    int rc = ttio_name_tok_v2_encode((const char * const *)names, n, enc, &enc_len);
    assert(rc == 0);

    char **dec = NULL;
    uint64_t dec_n = 0;
    rc = ttio_name_tok_v2_decode(enc, enc_len, &dec, &dec_n);
    assert(rc == 0);
    assert(dec_n == n);
    for (uint64_t i = 0; i < n; i++) {
        if (strcmp(names[i], dec[i]) != 0) {
            fprintf(stderr, "stress n=%llu mismatch at %llu: '%s' vs '%s'\n",
                    (unsigned long long)n, (unsigned long long)i, names[i], dec[i]);
            assert(0);
        }
        free(names[i]);
        free(dec[i]);
    }
    free(names); free(dec); free(enc);
    printf("stress n=%llu: PASS (encoded %zu bytes)\n",
           (unsigned long long)n, enc_len);
}

static void test_paired_pattern(uint64_t n_pairs) {
    /* Each name appears twice in a row — DUP-heavy pattern */
    unsigned seed = 7;
    uint64_t n = n_pairs * 2;
    char **names = malloc(sizeof(char*) * n);
    for (uint64_t i = 0; i < n_pairs; i++) {
        char *base = random_name(&seed);
        names[i*2] = base;
        names[i*2 + 1] = strdup(base);
    }
    size_t cap = ttio_name_tok_v2_max_encoded_size(n, 64 * n);
    uint8_t *enc = malloc(cap);
    size_t enc_len = cap;
    int rc = ttio_name_tok_v2_encode((const char * const *)names, n, enc, &enc_len);
    assert(rc == 0);
    char **dec = NULL;
    uint64_t dec_n = 0;
    rc = ttio_name_tok_v2_decode(enc, enc_len, &dec, &dec_n);
    assert(rc == 0);
    assert(dec_n == n);
    for (uint64_t i = 0; i < n; i++) {
        assert(strcmp(names[i], dec[i]) == 0);
        free(names[i]); free(dec[i]);
    }
    free(names); free(dec); free(enc);
    printf("paired pattern n_pairs=%llu: PASS\n", (unsigned long long)n_pairs);
}

static void test_malformed_inputs(void) {
    char **dec = NULL;
    uint64_t dec_n = 0;
    int rc;

    /* Bad magic */
    uint8_t bad_magic[12] = {'X','X','X','X', 0x01, 0x00, 0,0,0,0, 0,0};
    rc = ttio_name_tok_v2_decode(bad_magic, 12, &dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_NTV2_BAD_MAGIC);

    /* Bad version */
    uint8_t bad_version[12] = {'N','T','K','2', 0x99, 0x00, 0,0,0,0, 0,0};
    rc = ttio_name_tok_v2_decode(bad_version, 12, &dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_NTV2_BAD_VERSION);

    /* Truncated header (less than 12 bytes) */
    rc = ttio_name_tok_v2_decode(bad_magic, 5, &dec, &dec_n);
    assert(rc == TTIO_RANS_ERR_PARAM || rc == TTIO_RANS_ERR_CORRUPT);

    /* Empty stream (valid: flags.bit0 = 1, n_reads = 0, n_blocks = 0) */
    uint8_t empty_stream[12] = {'N','T','K','2', 0x01, 0x01, 0,0,0,0, 0,0};
    rc = ttio_name_tok_v2_decode(empty_stream, 12, &dec, &dec_n);
    assert(rc == 0);
    assert(dec_n == 0);
    if (dec) free(dec);

    printf("malformed inputs: PASS\n");
}

int main(void) {
    test_random_corpus(100);
    test_random_corpus(10000);
    test_random_corpus(50000);
    test_paired_pattern(100);
    test_paired_pattern(5000);
    test_malformed_inputs();
    return 0;
}
