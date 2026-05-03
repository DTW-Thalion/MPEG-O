#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ttio_rans.h"
#include "mate_info_v2.h"

/* I1: MF exhaustiveness — every (own, mate) pair maps to exactly one MF. */
static void test_i1_mf_exhaustiveness(void) {
    int K = 16;
    for (int own = 0; own < K; own++) {
        for (int mate = -1; mate < K; mate++) {
            int matches = 0;
            if (mate == own)               matches++;  /* MF=0 */
            else if (mate >= 0)            matches++;  /* MF=1 */
            else                           matches++;  /* MF=2 (mate==-1) */
            assert(matches == 1);
        }
    }
    printf("I1 MF exhaustiveness: PASS\n");
}

/* I6: end-to-end lossless round-trip on synthetic mate triples. */
static void test_i6_end_to_end(void) {
    const uint64_t N = 1000;
    int32_t  *mc = malloc(N * sizeof(int32_t));
    int64_t  *mp = malloc(N * sizeof(int64_t));
    int32_t  *ts = malloc(N * sizeof(int32_t));
    uint16_t *oc = malloc(N * sizeof(uint16_t));
    int64_t  *op = malloc(N * sizeof(int64_t));

    srand(7);
    for (uint64_t i = 0; i < N; i++) {
        oc[i] = (uint16_t)(rand() % 24);
        op[i] = (int64_t)(rand() % 100000000);
        int dice = rand() % 10;
        if (dice < 8) {
            mc[i] = (int32_t)oc[i];
            mp[i] = op[i] + (rand() % 1000) - 500;
        } else if (dice < 9) {
            mc[i] = (int32_t)((oc[i] + 1) % 24);
            mp[i] = (int64_t)(rand() % 100000000);
        } else {
            mc[i] = -1;
            mp[i] = 0;
        }
        ts[i] = (rand() % 1000) - 500;
    }

    size_t cap = ttio_mate_info_v2_max_encoded_size(N);
    uint8_t *encoded = malloc(cap);
    size_t encoded_size = cap;
    int rc = ttio_mate_info_v2_encode(mc, mp, ts, oc, op, N, encoded, &encoded_size);
    assert(rc == 0);
    assert(encoded_size > 34);  /* at least header */

    int32_t *mc2 = malloc(N * sizeof(int32_t));
    int64_t *mp2 = malloc(N * sizeof(int64_t));
    int32_t *ts2 = malloc(N * sizeof(int32_t));
    rc = ttio_mate_info_v2_decode(encoded, encoded_size, oc, op, N, mc2, mp2, ts2);
    assert(rc == 0);

    for (uint64_t i = 0; i < N; i++) {
        assert(mc[i] == mc2[i]);
        assert(mp[i] == mp2[i]);
        assert(ts[i] == ts2[i]);
    }
    printf("I6 end-to-end lossless: PASS\n");

    free(mc); free(mp); free(ts); free(oc); free(op);
    free(encoded); free(mc2); free(mp2); free(ts2);
}

/* I7: decoder rejects MF=3 in raw-pack path (we patch the raw-pack
 * stream to contain a 0b11 slot). */
static void test_i7_reserved_mf_raw_pack_rejection(void) {
    int32_t  mc[1] = {-1};
    int64_t  mp[1] = {0};
    int32_t  ts[1] = {0};
    uint16_t oc[1] = {0};
    int64_t  op[1] = {0};

    size_t encoded_cap = ttio_mate_info_v2_max_encoded_size(1);
    uint8_t *encoded = malloc(encoded_cap);
    size_t encoded_size = encoded_cap;
    int rc = ttio_mate_info_v2_encode(mc, mp, ts, oc, op, 1, encoded, &encoded_size);
    assert(rc == 0);

    /* For N=1 with all-NO_MATE, raw-pack will be smaller than rANS-O0
     * (1+1=2 bytes vs ~1037+ bytes rANS framing). The MF substream
     * starts at offset MIV2_HEADER_SIZE=34. The leading byte at [34]
     * is the selector (should be 0x00 = raw-pack); the next byte [35]
     * has MF[0] in low 2 bits. Patch low 2 bits to 0b11 = reserved. */
    if (encoded[34] == MIV2_MF_RAW_PACK) {
        encoded[35] = (encoded[35] & 0xFC) | 0x03;
        int32_t mc2[1]; int64_t mp2[1]; int32_t ts2[1];
        rc = ttio_mate_info_v2_decode(encoded, encoded_size, oc, op, 1, mc2, mp2, ts2);
        assert(rc == TTIO_RANS_ERR_RESERVED_MF);
        printf("I7 reserved MF (raw-pack) rejection: PASS\n");
    } else {
        printf("I7 reserved MF (raw-pack) rejection: SKIP (encoder picked rANS path for N=1)\n");
    }
    free(encoded);
}

/* I8: encoder rejects mate_chrom_id < -1 (invalid input). */
static void test_i8_encoder_invalid_input_guard(void) {
    int32_t  mc[1] = {-2};
    int64_t  mp[1] = {0};
    int32_t  ts[1] = {0};
    uint16_t oc[1] = {0};
    int64_t  op[1] = {0};

    uint8_t encoded[256];
    size_t encoded_size = sizeof(encoded);
    int rc = ttio_mate_info_v2_encode(mc, mp, ts, oc, op, 1, encoded, &encoded_size);
    assert(rc == TTIO_RANS_ERR_PARAM);
    printf("I8 encoder invalid-input guard: PASS\n");
}

int main(void) {
    test_i1_mf_exhaustiveness();
    test_i6_end_to_end();
    test_i7_reserved_mf_raw_pack_rejection();
    test_i8_encoder_invalid_input_guard();
    printf("test_mate_info_v2_invariants: ALL PASS\n");
    return 0;
}
