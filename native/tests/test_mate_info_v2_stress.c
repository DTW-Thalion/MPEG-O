#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ttio_rans.h"
#include "mate_info_v2.h"

typedef enum {
    PATTERN_ALL_PROPER,
    PATTERN_ALL_CROSS,
    PATTERN_ALL_UNMAPPED,
    PATTERN_MIXED,
} pattern_t;

static void gen_record(pattern_t pat, uint64_t i, uint16_t *oc, int64_t *op,
                       int32_t *mc, int64_t *mp, int32_t *ts) {
    *oc = (uint16_t)(i % 24);
    *op = (int64_t)(i * 137);
    *ts = (int32_t)((i % 1000) - 500);
    switch (pat) {
        case PATTERN_ALL_PROPER:
            *mc = (int32_t)*oc;
            *mp = *op + ((int64_t)((i % 1000) - 500));
            break;
        case PATTERN_ALL_CROSS:
            *mc = (int32_t)((*oc + 1) % 24);
            *mp = (int64_t)((i * 311) % 100000000);
            break;
        case PATTERN_ALL_UNMAPPED:
            *mc = -1;
            *mp = 0;
            break;
        case PATTERN_MIXED:
        default: {
            uint64_t r = i % 10;
            if (r < 5) {
                *mc = (int32_t)*oc;
                *mp = *op + (int64_t)((i % 1000) - 500);
            } else if (r < 8) {
                *mc = (int32_t)((*oc + 1) % 24);
                *mp = (int64_t)((i * 311) % 100000000);
            } else {
                *mc = -1;
                *mp = 0;
            }
            break;
        }
    }
}

static int run_one(uint64_t n, pattern_t pat, const char *pat_name) {
    int32_t  *mc = malloc(n * sizeof(int32_t));
    int64_t  *mp = malloc(n * sizeof(int64_t));
    int32_t  *ts = malloc(n * sizeof(int32_t));
    uint16_t *oc = malloc(n * sizeof(uint16_t));
    int64_t  *op = malloc(n * sizeof(int64_t));
    if (!mc || !mp || !ts || !oc || !op) { fprintf(stderr, "alloc fail\n"); return 1; }

    for (uint64_t i = 0; i < n; i++) {
        gen_record(pat, i, &oc[i], &op[i], &mc[i], &mp[i], &ts[i]);
    }

    size_t cap = ttio_mate_info_v2_max_encoded_size(n);
    uint8_t *enc = malloc(cap);
    if (!enc) { fprintf(stderr, "alloc fail\n"); return 1; }
    size_t enc_size = cap;
    int rc = ttio_mate_info_v2_encode(mc, mp, ts, oc, op, n, enc, &enc_size);
    if (rc != 0) { fprintf(stderr, "encode failed: rc=%d n=%llu pat=%s\n", rc, (unsigned long long)n, pat_name); return 1; }

    int32_t *mc2 = malloc(n * sizeof(int32_t));
    int64_t *mp2 = malloc(n * sizeof(int64_t));
    int32_t *ts2 = malloc(n * sizeof(int32_t));
    if (!mc2 || !mp2 || !ts2) { fprintf(stderr, "alloc fail\n"); return 1; }
    rc = ttio_mate_info_v2_decode(enc, enc_size, oc, op, n, mc2, mp2, ts2);
    if (rc != 0) { fprintf(stderr, "decode failed: rc=%d n=%llu pat=%s\n", rc, (unsigned long long)n, pat_name); return 1; }

    for (uint64_t i = 0; i < n; i++) {
        if (mc[i] != mc2[i] || mp[i] != mp2[i] || ts[i] != ts2[i]) {
            fprintf(stderr, "mismatch at i=%llu n=%llu pat=%s\n", (unsigned long long)i, (unsigned long long)n, pat_name);
            return 1;
        }
    }
    printf("  n=%llu pattern=%-12s enc=%zu bytes (%.2f B/rec): PASS\n",
           (unsigned long long)n, pat_name, enc_size, (double)enc_size / (double)n);

    free(mc); free(mp); free(ts); free(oc); free(op); free(enc);
    free(mc2); free(mp2); free(ts2);
    return 0;
}

/* I4: NS length conservation — corrupt NUM_CROSS in header, assert decode rejects. */
static int test_i4_ns_length_conservation(void) {
    const uint64_t N = 100;
    int32_t  *mc = malloc(N * sizeof(int32_t));
    int64_t  *mp = malloc(N * sizeof(int64_t));
    int32_t  *ts = malloc(N * sizeof(int32_t));
    uint16_t *oc = malloc(N * sizeof(uint16_t));
    int64_t  *op = malloc(N * sizeof(int64_t));
    if (!mc || !mp || !ts || !oc || !op) { fprintf(stderr, "I4 alloc fail\n"); return 1; }
    for (uint64_t i = 0; i < N; i++) {
        gen_record(PATTERN_ALL_CROSS, i, &oc[i], &op[i], &mc[i], &mp[i], &ts[i]);
    }
    size_t cap = ttio_mate_info_v2_max_encoded_size(N);
    uint8_t *enc = malloc(cap);
    if (!enc) { fprintf(stderr, "I4 alloc fail\n"); return 1; }
    size_t enc_size = cap;
    int rc = ttio_mate_info_v2_encode(mc, mp, ts, oc, op, N, enc, &enc_size);
    if (rc != 0) { fprintf(stderr, "I4 encode failed: rc=%d\n", rc); return 1; }

    /* Patch NUM_CROSS field (header offset 14) to N-1.
     * NUM_CROSS is u32 LE, so byte 14 = low byte. With N=100, original
     * = 0x64; patched = 0x63. Decode should detect mismatch — either
     * NS varint walk runs short OR ns_consumed_count != num_cross. */
    enc[14] = (uint8_t)((N - 1) & 0xff);

    int32_t *mc2 = malloc(N * sizeof(int32_t));
    int64_t *mp2 = malloc(N * sizeof(int64_t));
    int32_t *ts2 = malloc(N * sizeof(int32_t));
    if (!mc2 || !mp2 || !ts2) { fprintf(stderr, "I4 alloc fail\n"); return 1; }
    rc = ttio_mate_info_v2_decode(enc, enc_size, oc, op, N, mc2, mp2, ts2);
    if (rc == 0) {
        fprintf(stderr, "I4 FAIL: decoder did not detect NUM_CROSS tampering\n");
        return 1;
    }
    printf("I4 NS length conservation: PASS (rc=%d on tampered NUM_CROSS)\n", rc);

    free(mc); free(mp); free(ts); free(oc); free(op); free(enc);
    free(mc2); free(mp2); free(ts2);
    return 0;
}

/* I5: MF auto-pick equivalence — both rANS-wins and raw-pack-wins
 * cases round-trip cleanly to the same MF[] reconstruction.
 *
 * rANS wins over raw-pack once raw_pack_bytes > rANS_encoded_size.
 * raw-pack uses ceil(n/4) bytes; rANS-O0 has ~1040-byte fixed overhead.
 * Crossover is around n=8192 (raw=2048 > rans~1040).  Use n=10000 to
 * guarantee the rANS path, n=8 for raw-pack. */
static int test_i5_mf_autopick_equivalence(void) {
    /* Case A: 10000 records, all MF=0 (rANS wins: raw=2500 > ~1040). */
    /* Case B: 8 records, alternating MF (raw-pack wins on tiny N). */
    uint64_t cases[][2] = {{10000, 0}, {8, 1}};
    for (int c = 0; c < 2; c++) {
        uint64_t n = cases[c][0];
        int32_t  *mc = malloc(n * sizeof(int32_t));
        int64_t  *mp = malloc(n * sizeof(int64_t));
        int32_t  *ts = malloc(n * sizeof(int32_t));
        uint16_t *oc = malloc(n * sizeof(uint16_t));
        int64_t  *op = malloc(n * sizeof(int64_t));
        if (!mc || !mp || !ts || !oc || !op) { fprintf(stderr, "I5 alloc fail\n"); return 1; }
        for (uint64_t i = 0; i < n; i++) {
            oc[i] = (uint16_t)(i % 24);
            op[i] = (int64_t)(i * 137);
            ts[i] = (int32_t)i;
            if (c == 0) {
                mc[i] = (int32_t)oc[i];
                mp[i] = op[i];
            } else {
                int v = (int)(i % 3);
                if (v == 0) { mc[i] = (int32_t)oc[i]; mp[i] = op[i]; }
                else if (v == 1) { mc[i] = (int32_t)((oc[i]+1)%24); mp[i] = (int64_t)(i*7); }
                else { mc[i] = -1; mp[i] = 0; }
            }
        }

        size_t cap = ttio_mate_info_v2_max_encoded_size(n);
        uint8_t *enc = malloc(cap);
        if (!enc) { fprintf(stderr, "I5 alloc fail\n"); return 1; }
        size_t enc_size = cap;
        int rc = ttio_mate_info_v2_encode(mc, mp, ts, oc, op, n, enc, &enc_size);
        if (rc != 0) { fprintf(stderr, "I5 encode failed: rc=%d n=%llu\n", rc, (unsigned long long)n); return 1; }

        /* Verify MF substream selector for awareness. Header is 34 bytes,
         * MF starts at offset 34 with the selector byte. */
        printf("  I5 case n=%llu MF selector = 0x%02x (%s)\n",
               (unsigned long long)n, enc[34],
               enc[34] == 0x00 ? "raw-pack" : enc[34] == 0x01 ? "rANS-O0" : "INVALID");

        int32_t *mc2 = malloc(n * sizeof(int32_t));
        int64_t *mp2 = malloc(n * sizeof(int64_t));
        int32_t *ts2 = malloc(n * sizeof(int32_t));
        if (!mc2 || !mp2 || !ts2) { fprintf(stderr, "I5 alloc fail\n"); return 1; }
        rc = ttio_mate_info_v2_decode(enc, enc_size, oc, op, n, mc2, mp2, ts2);
        if (rc != 0) { fprintf(stderr, "I5 decode failed: rc=%d n=%llu\n", rc, (unsigned long long)n); return 1; }
        for (uint64_t i = 0; i < n; i++) {
            if (mc[i] != mc2[i] || mp[i] != mp2[i] || ts[i] != ts2[i]) {
                fprintf(stderr, "I5 mismatch at i=%llu n=%llu\n", (unsigned long long)i, (unsigned long long)n);
                return 1;
            }
        }
        free(mc); free(mp); free(ts); free(oc); free(op); free(enc);
        free(mc2); free(mp2); free(ts2);
    }
    printf("I5 MF auto-pick equivalence: PASS (both small + large cases)\n");
    return 0;
}

int main(void) {
    uint64_t sizes[] = {1, 100, 10000, 1000000};
    pattern_t patterns[] = {PATTERN_ALL_PROPER, PATTERN_ALL_CROSS, PATTERN_ALL_UNMAPPED, PATTERN_MIXED};
    const char *pnames[] = {"all-proper", "all-cross", "all-unmapped", "mixed"};

    printf("Stress test: %d sizes x %d patterns = %d round-trips\n",
           (int)(sizeof(sizes)/sizeof(sizes[0])),
           (int)(sizeof(patterns)/sizeof(patterns[0])),
           (int)((sizeof(sizes)/sizeof(sizes[0])) * (sizeof(patterns)/sizeof(patterns[0]))));

    for (size_t s = 0; s < sizeof(sizes)/sizeof(sizes[0]); s++) {
        for (size_t p = 0; p < sizeof(patterns)/sizeof(patterns[0]); p++) {
            if (run_one(sizes[s], patterns[p], pnames[p]) != 0) return 1;
        }
    }

    if (test_i4_ns_length_conservation() != 0) return 1;
    if (test_i5_mf_autopick_equivalence() != 0) return 1;

    printf("test_mate_info_v2_stress: ALL PASS\n");
    return 0;
}
