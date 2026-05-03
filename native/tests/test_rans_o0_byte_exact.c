/*
 * test_rans_o0_byte_exact.c -- Round-trip + cross-language byte-exactness
 * tests for ttio_rans_o0_encode / ttio_rans_o0_decode.
 *
 * Fixture hex values produced by:
 *   from ttio.codecs.rans import encode
 *   print(encode(b"", order=0).hex())
 *   print(encode(b"AAAA", order=0).hex())
 * Both are 1037 bytes.
 */

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ttio_rans.h"

/* encode(b"", order=0) -- 1037 bytes */
static const char EMPTY_ENCODED_HEX[] =
    "0000000000000000040000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "1000000010000000100000001000000010000000100000001000000010000000"
    "10000000100000001000800000";

/* encode(b"AAAA", order=0) -- 1037 bytes */
static const char AAAA_ENCODED_HEX[] =
    "0000000004000000040000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000001000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "00000000000000000000800000";

/* Decode a hex string (no spaces) to bytes. Returns byte count. */
static size_t hex_decode(const char *hex, uint8_t *out, size_t out_cap)
{
    size_t n = 0;
    const char *p = hex;
    while (*p && *(p + 1)) {
        unsigned int hi, lo;
        char hc = *p++;
        char lc = *p++;
        hi = (hc >= '0' && hc <= '9') ? (unsigned)(hc - '0') :
             (hc >= 'a' && hc <= 'f') ? (unsigned)(hc - 'a' + 10) :
                                        (unsigned)(hc - 'A' + 10);
        lo = (lc >= '0' && lc <= '9') ? (unsigned)(lc - '0') :
             (lc >= 'a' && lc <= 'f') ? (unsigned)(lc - 'a' + 10) :
                                        (unsigned)(lc - 'A' + 10);
        assert(n < out_cap);
        out[n++] = (uint8_t)((hi << 4) | lo);
    }
    return n;
}

/* Round-trip: encode then decode, assert identity. */
static void test_round_trip(const uint8_t *in, size_t in_len, const char *name)
{
    size_t cap = ttio_rans_o0_max_encoded_size(in_len);
    uint8_t *enc = (uint8_t *)malloc(cap);
    assert(enc);

    size_t enc_len = cap;
    int rc = ttio_rans_o0_encode(in, in_len, enc, &enc_len);
    assert(rc == 0);

    /* Min wire is always 1037 (header+freqtable+state) */
    assert(enc_len >= 1037u);
    assert(enc[0] == 0x00);  /* order byte */

    uint8_t *dec = (uint8_t *)malloc(in_len > 0 ? in_len : 1);
    assert(dec);
    size_t dec_len = in_len;
    rc = ttio_rans_o0_decode(enc, enc_len, dec, in_len, &dec_len);
    assert(rc == 0);
    assert(dec_len == in_len);
    if (in_len > 0)
        assert(memcmp(in, dec, in_len) == 0);

    printf("  round-trip %-22s (n=%6zu) PASS (encoded=%zu)\n",
           name, in_len, enc_len);

    free(enc);
    free(dec);
}

/* Cross-language fixture: compare C output byte-for-byte with Python. */
static void test_fixture(const uint8_t *input, size_t input_len,
                         const char *hex_expected, const char *name)
{
    size_t exp_cap = strlen(hex_expected) / 2 + 4;
    uint8_t *expected = (uint8_t *)malloc(exp_cap);
    assert(expected);
    size_t exp_len = hex_decode(hex_expected, expected, exp_cap);

    size_t cap = ttio_rans_o0_max_encoded_size(input_len);
    uint8_t *enc = (uint8_t *)malloc(cap);
    assert(enc);
    size_t enc_len = cap;
    int rc = ttio_rans_o0_encode(input, input_len, enc, &enc_len);
    assert(rc == 0);

    if (enc_len != exp_len || memcmp(enc, expected, enc_len) != 0) {
        size_t show = enc_len < exp_len ? enc_len : exp_len;
        if (show > 60) show = 60;
        fprintf(stderr,
                "FAIL fixture %s: C=%zu bytes Python=%zu bytes\n",
                name, enc_len, exp_len);
        fprintf(stderr, "  C   first %zu: ", show);
        { size_t i; for (i = 0; i < show; i++) fprintf(stderr, "%02x", enc[i]); }
        fprintf(stderr, "\n  Py  first %zu: ", show);
        { size_t i; for (i = 0; i < show; i++) fprintf(stderr, "%02x", expected[i]); }
        fprintf(stderr, "\n");
        {
            size_t lim = enc_len < exp_len ? enc_len : exp_len;
            size_t i;
            for (i = 0; i < lim; i++) {
                if (enc[i] != expected[i]) {
                    fprintf(stderr,
                            "  First divergence byte %zu: C=%02x Py=%02x\n",
                            i, enc[i], expected[i]);
                    break;
                }
            }
        }
        free(enc); free(expected);
        assert(0);
    }

    printf("  cross-lang  %-22s PASS (len=%zu, byte-exact with Python)\n",
           name, enc_len);
    free(enc);
    free(expected);
}

int main(void)
{
    printf("test_rans_o0_byte_exact:\n");

    /* Round-trip tests */
    test_round_trip(NULL, 0, "empty");

    {
        uint8_t one[1] = {42};
        test_round_trip(one, 1, "single byte");
    }

    {
        uint8_t same[1000];
        memset(same, 'A', sizeof(same));
        test_round_trip(same, sizeof(same), "all-same");
    }

    {
        uint8_t uniform[2560];
        size_t i;
        for (i = 0; i < sizeof(uniform); i++)
            uniform[i] = (uint8_t)(i % 256);
        test_round_trip(uniform, sizeof(uniform), "uniform");
    }

    {
        uint8_t skewed[10000];
        size_t i;
        srand(42);
        for (i = 0; i < sizeof(skewed); i++) {
            int v = 0, j;
            for (j = 0; j < 8; j++)
                if (rand() % 2) v++;
            skewed[i] = (uint8_t)(v * 32);
        }
        test_round_trip(skewed, sizeof(skewed), "skewed");
    }

    {
        uint8_t large[100000];
        size_t i;
        for (i = 0; i < sizeof(large); i++)
            large[i] = (uint8_t)rand();
        test_round_trip(large, sizeof(large), "random large");
    }

    {
        uint8_t sparse[1000];
        size_t i;
        for (i = 0; i < sizeof(sparse); i++)
            sparse[i] = (i % 3) ? 'A' : 'C';
        test_round_trip(sparse, sizeof(sparse), "sparse alphabet");
    }

    printf("\n");

    /* Cross-language byte-exact fixture tests */
    test_fixture(NULL, 0, EMPTY_ENCODED_HEX, "empty (Python ref)");

    {
        uint8_t aaaa[4] = {'A', 'A', 'A', 'A'};
        test_fixture(aaaa, 4, AAAA_ENCODED_HEX, "AAAA (Python ref)");
    }

    printf("\ntest_rans_o0_byte_exact: ALL PASS\n");
    return 0;
}
