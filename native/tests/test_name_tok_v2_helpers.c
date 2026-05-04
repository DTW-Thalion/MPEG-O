#include <assert.h>
#include <stdio.h>
#include <string.h>
#include "name_tok_v2.h"

static void test_tokenise_basic(void) {
    uint8_t types[256];
    uint16_t starts[256], lens[256];
    uint8_t n;
    uint64_t nums[256];
    int rc = ntv2_tokenise("READ:1:2", types, starts, lens, &n, nums);
    assert(rc == 0);
    assert(n == 4);
    assert(types[0] == NTV2_TOK_STR);  /* "READ:" */
    assert(types[1] == NTV2_TOK_NUM);  /* 1 */
    assert(types[2] == NTV2_TOK_STR);  /* ":" */
    assert(types[3] == NTV2_TOK_NUM);  /* 2 */
    assert(nums[1] == 1);
    assert(nums[3] == 2);
    assert(starts[0] == 0 && lens[0] == 5);
    assert(starts[1] == 5 && lens[1] == 1);
    printf("tokenise basic: PASS\n");
}

static void test_tokenise_leading_zero(void) {
    uint8_t types[256];
    uint16_t starts[256], lens[256];
    uint8_t n;
    uint64_t nums[256];
    int rc = ntv2_tokenise("r007:1", types, starts, lens, &n, nums);
    assert(rc == 0);
    assert(n == 2);
    assert(types[0] == NTV2_TOK_STR);  /* "r007:" — 007 invalid num */
    assert(types[1] == NTV2_TOK_NUM);  /* 1 */
    assert(lens[0] == 5);
    assert(nums[1] == 1);
    printf("tokenise leading-zero: PASS\n");
}

static void test_tokenise_zero_alone(void) {
    uint8_t types[256];
    uint16_t starts[256], lens[256];
    uint8_t n;
    uint64_t nums[256];
    int rc = ntv2_tokenise("r0", types, starts, lens, &n, nums);
    assert(rc == 0);
    assert(n == 2);
    assert(types[0] == NTV2_TOK_STR);
    assert(types[1] == NTV2_TOK_NUM);
    assert(nums[1] == 0);
    printf("tokenise zero: PASS\n");
}

static void test_tokenise_empty(void) {
    uint8_t types[256];
    uint16_t starts[256], lens[256];
    uint8_t n;
    uint64_t nums[256];
    int rc = ntv2_tokenise("", types, starts, lens, &n, nums);
    assert(rc == 0);
    assert(n == 0);
    printf("tokenise empty: PASS\n");
}

static void test_tokenise_non_ascii(void) {
    uint8_t types[256];
    uint16_t starts[256], lens[256];
    uint8_t n;
    uint64_t nums[256];
    int rc = ntv2_tokenise("R\xC3\xA9", types, starts, lens, &n, nums);
    assert(rc == -1);
    printf("tokenise non-ASCII reject: PASS\n");
}

static void test_pack_2bits(void) {
    uint8_t vals[8] = {0, 1, 2, 3, 0, 1, 2, 3};
    uint8_t out[2];
    size_t n = ntv2_pack_2bits(vals, 8, out);
    assert(n == 2);
    assert(out[0] == 0x1B);  /* 00 01 10 11 = 0b00011011 */
    assert(out[1] == 0x1B);
    uint8_t round[8];
    ntv2_unpack_2bits(out, 8, round);
    assert(memcmp(round, vals, 8) == 0);
    printf("pack 2bits roundtrip: PASS\n");
}

static void test_pack_2bits_partial(void) {
    /* 5 values → ⌈5*2/8⌉ = 2 bytes; last byte has padding */
    uint8_t vals[5] = {3, 2, 1, 0, 3};
    uint8_t out[2];
    size_t n = ntv2_pack_2bits(vals, 5, out);
    assert(n == 2);
    uint8_t round[5];
    ntv2_unpack_2bits(out, 5, round);
    assert(memcmp(round, vals, 5) == 0);
    printf("pack 2bits partial: PASS\n");
}

static void test_pack_3bits(void) {
    uint8_t vals[8] = {7, 0, 1, 2, 3, 4, 5, 6};
    uint8_t out[3];
    size_t n = ntv2_pack_3bits(vals, 8, out);
    assert(n == 3);
    uint8_t round[8];
    ntv2_unpack_3bits(out, 8, round);
    assert(memcmp(round, vals, 8) == 0);
    printf("pack 3bits roundtrip: PASS\n");
}

static void test_pack_3bits_partial(void) {
    /* 5 values → 15 bits → 2 bytes */
    uint8_t vals[5] = {7, 0, 1, 2, 3};
    uint8_t out[2];
    size_t n = ntv2_pack_3bits(vals, 5, out);
    assert(n == 2);
    uint8_t round[5];
    ntv2_unpack_3bits(out, 5, round);
    assert(memcmp(round, vals, 5) == 0);
    printf("pack 3bits partial: PASS\n");
}

static void test_uvarint(void) {
    uint8_t buf[16];
    uint64_t v;
    /* 0 fits in 1 byte */
    size_t n = ntv2_uvarint_encode(0, buf);
    assert(n == 1 && buf[0] == 0);
    n = ntv2_uvarint_decode(buf, &v);
    assert(n == 1 && v == 0);
    /* 127 fits in 1 byte */
    n = ntv2_uvarint_encode(127, buf);
    assert(n == 1 && buf[0] == 127);
    /* 128 needs 2 bytes */
    n = ntv2_uvarint_encode(128, buf);
    assert(n == 2);
    n = ntv2_uvarint_decode(buf, &v);
    assert(n == 2 && v == 128);
    /* large */
    n = ntv2_uvarint_encode(0xFFFFFFFFULL, buf);
    n = ntv2_uvarint_decode(buf, &v);
    assert(v == 0xFFFFFFFFULL);
    printf("uvarint roundtrip: PASS\n");
}

static void test_svarint(void) {
    uint8_t buf[16];
    int64_t s;
    /* 0 */
    ntv2_svarint_encode(0, buf);
    ntv2_svarint_decode(buf, &s);
    assert(s == 0);
    /* -1 */
    ntv2_svarint_encode(-1, buf);
    ntv2_svarint_decode(buf, &s);
    assert(s == -1);
    /* 63 */
    ntv2_svarint_encode(63, buf);
    ntv2_svarint_decode(buf, &s);
    assert(s == 63);
    /* -64 */
    ntv2_svarint_encode(-64, buf);
    ntv2_svarint_decode(buf, &s);
    assert(s == -64);
    /* large positive */
    ntv2_svarint_encode(123456789LL, buf);
    ntv2_svarint_decode(buf, &s);
    assert(s == 123456789LL);
    /* large negative */
    ntv2_svarint_encode(-987654321LL, buf);
    ntv2_svarint_decode(buf, &s);
    assert(s == -987654321LL);
    printf("svarint roundtrip: PASS\n");
}

int main(void) {
    test_tokenise_basic();
    test_tokenise_leading_zero();
    test_tokenise_zero_alone();
    test_tokenise_empty();
    test_tokenise_non_ascii();
    test_pack_2bits();
    test_pack_2bits_partial();
    test_pack_3bits();
    test_pack_3bits_partial();
    test_uvarint();
    test_svarint();
    return 0;
}
