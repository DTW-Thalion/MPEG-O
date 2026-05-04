#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "ref_diff_v2.h"

static void test_base_to_2bit_roundtrip(void) {
    /* I1: ACGT bijectivity */
    uint8_t bases[]  = {'A','C','G','T'};
    uint8_t codes[]  = {0, 1, 2, 3};
    for (int i = 0; i < 4; i++) {
        assert(rdv2_base_to_2bit(bases[i]) == codes[i]);
        assert(rdv2_2bit_to_base(codes[i]) == bases[i]);
    }
    /* lowercase normalises to uppercase */
    assert(rdv2_base_to_2bit('a') == 0);
    assert(rdv2_base_to_2bit('c') == 1);
    assert(rdv2_base_to_2bit('g') == 2);
    assert(rdv2_base_to_2bit('t') == 3);
    /* N + other non-ACGT → INVALID */
    assert(rdv2_base_to_2bit('N') == RDV2_BASE_INVALID);
    assert(rdv2_base_to_2bit('n') == RDV2_BASE_INVALID);
    assert(rdv2_base_to_2bit(0)   == RDV2_BASE_INVALID);
    assert(rdv2_base_to_2bit(255) == RDV2_BASE_INVALID);
    printf("base_to_2bit roundtrip: PASS\n");
}

static void test_pack_unpack_2bit(void) {
    /* Pack 8 codes → 2 bytes; unpack and verify */
    uint8_t codes[8] = {0, 1, 2, 3, 3, 2, 1, 0};
    uint8_t packed[2] = {0, 0};
    size_t n_bytes = rdv2_pack_2bit(codes, 8, packed);
    assert(n_bytes == 2);
    /* LSB-first within byte: byte0 = (3<<6)|(2<<4)|(1<<2)|0 = 0xE4
     *                       byte1 = (0<<6)|(1<<4)|(2<<2)|3 = 0x1B */
    assert(packed[0] == 0xE4);
    assert(packed[1] == 0x1B);

    uint8_t unpacked[8] = {0};
    rdv2_unpack_2bit(packed, 8, unpacked);
    for (int i = 0; i < 8; i++) assert(unpacked[i] == codes[i]);

    /* Odd length: 5 codes → 2 bytes (4 in first, 1 in second; rest pad zero) */
    uint8_t codes5[5] = {1, 2, 3, 0, 1};
    uint8_t packed5[2] = {0, 0};
    n_bytes = rdv2_pack_2bit(codes5, 5, packed5);
    assert(n_bytes == 2);
    uint8_t unpacked5[5] = {0};
    rdv2_unpack_2bit(packed5, 5, unpacked5);
    for (int i = 0; i < 5; i++) assert(unpacked5[i] == codes5[i]);
    printf("pack/unpack 2bit: PASS\n");
}

static void test_cigar_counts(void) {
    uint64_t m, i, s;
    /* 100M → 100 M, 0 I, 0 S */
    assert(rdv2_parse_cigar_counts("100M", &m, &i, &s) == 0);
    assert(m == 100 && i == 0 && s == 0);
    /* 50M5I45M → 95 M, 5 I, 0 S */
    assert(rdv2_parse_cigar_counts("50M5I45M", &m, &i, &s) == 0);
    assert(m == 95 && i == 5 && s == 0);
    /* 5S90M5S → 90 M, 0 I, 10 S */
    assert(rdv2_parse_cigar_counts("5S90M5S", &m, &i, &s) == 0);
    assert(m == 90 && i == 0 && s == 10);
    /* M / = / X all count as match-eligible per spec §4.10 */
    assert(rdv2_parse_cigar_counts("50=50X", &m, &i, &s) == 0);
    assert(m == 100 && i == 0 && s == 0);
    /* 10M2D10M3N5M → 25 M, 0 I, 0 S (D and N skip ref, no payload) */
    assert(rdv2_parse_cigar_counts("10M2D10M3N5M", &m, &i, &s) == 0);
    assert(m == 25 && i == 0 && s == 0);
    /* Empty cigar → 0/0/0 */
    assert(rdv2_parse_cigar_counts("", &m, &i, &s) == 0);
    assert(m == 0 && i == 0 && s == 0);
    /* Malformed cigar → -1 */
    assert(rdv2_parse_cigar_counts("XYZ", &m, &i, &s) == -1);
    printf("cigar_counts: PASS\n");
}

int main(void) {
    test_base_to_2bit_roundtrip();
    test_pack_unpack_2bit();
    test_cigar_counts();
    printf("test_ref_diff_v2_helpers: PASS\n");
    return 0;
}
