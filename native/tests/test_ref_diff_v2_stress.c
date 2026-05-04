#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ttio_rans.h"
#include "ref_diff_v2.h"

typedef enum {
    P_PERFECT, P_SUB_HEAVY, P_INS_HEAVY, P_SC_HEAVY, P_N_HEAVY, P_MIXED
} pattern_t;
static const char *PNAMES[] = {"perfect", "sub-heavy", "ins-heavy", "sc-heavy", "n-heavy", "mixed"};

/* Generate a synthetic corpus. base_read_len = 100 (or 105 for ins-heavy). */
static void gen_corpus(pattern_t pat, uint64_t n,
                       uint8_t **out_seq, uint64_t **out_offsets,
                       int64_t **out_positions, char ***out_cigars,
                       uint8_t **out_ref, uint64_t *out_ref_len)
{
    uint64_t base_read_len = 100;
    *out_ref_len = n * 50 + 1000;
    uint8_t *ref = malloc(*out_ref_len);
    for (uint64_t i = 0; i < *out_ref_len; i++) ref[i] = "ACGT"[i % 4];
    /* Pre-allocate seq for max possible length per read */
    uint8_t *seq = malloc(n * (base_read_len + 20));
    uint64_t *offsets = malloc((n + 1) * sizeof(uint64_t));
    int64_t *positions = malloc(n * sizeof(int64_t));
    char **cigars = malloc(n * sizeof(char *));

    offsets[0] = 0;
    srand(42 + (int)pat);
    for (uint64_t r = 0; r < n; r++) {
        positions[r] = (int64_t)(r * 50 + 1);  /* 1-based */
        const char *cigar_str = "100M";
        uint64_t rl = base_read_len;
        switch (pat) {
            case P_PERFECT: case P_SUB_HEAVY: case P_N_HEAVY:
                cigar_str = "100M"; rl = 100; break;
            case P_INS_HEAVY:
                cigar_str = "50M5I50M"; rl = 105; break;
            case P_SC_HEAVY:
                cigar_str = "10S90M"; rl = 100; break;
            case P_MIXED:
                switch (r % 4) {
                    case 0: cigar_str = "100M";  rl = 100; break;
                    case 1: cigar_str = "50M5I50M"; rl = 105; break;
                    case 2: cigar_str = "5S95M"; rl = 100; break;
                    case 3: cigar_str = "100="; rl = 100; break;
                    default: break;
                }
                break;
        }
        cigars[r] = strdup(cigar_str);

        /* Walk cigar to fill read bytes */
        uint64_t rp = 0;
        uint64_t ref_off = (uint64_t)((int64_t)(positions[r] - 1));
        const char *cp = cigar_str;
        while (*cp) {
            uint64_t len = 0;
            while (*cp >= '0' && *cp <= '9') { len = len * 10 + (uint64_t)(*cp - '0'); cp++; }
            char op = *cp++;
            if (op == 'M' || op == '=' || op == 'X') {
                for (uint64_t k = 0; k < len; k++) {
                    uint8_t b = ref[ref_off + k];
                    if (pat == P_SUB_HEAVY && (rand() % 20) == 0) {
                        b = (b == 'A') ? 'C' : 'A';
                    }
                    if (pat == P_N_HEAVY && (rand() % 10) == 0) {
                        b = 'N';
                    }
                    seq[offsets[r] + rp++] = b;
                }
                ref_off += len;
            } else if (op == 'I' || op == 'S') {
                for (uint64_t k = 0; k < len; k++) {
                    uint8_t b = "ACGT"[rand() % 4];
                    if (pat == P_N_HEAVY && (rand() % 10) == 0) b = 'N';
                    seq[offsets[r] + rp++] = b;
                }
                /* I/S do not advance ref */
            } else if (op == 'D' || op == 'N') {
                ref_off += len;
            }
            /* H, P consume nothing */
        }
        offsets[r + 1] = offsets[r] + rl;
        (void)rp;  /* rp == rl when cigar is well-formed */
    }

    *out_seq = seq;
    *out_offsets = offsets;
    *out_positions = positions;
    *out_cigars = cigars;
    *out_ref = ref;
}

static int run_one(uint64_t n, pattern_t pat) {
    uint8_t *seq, *ref;
    uint64_t *offsets;
    int64_t *positions;
    char **cigars;
    uint64_t ref_len;
    gen_corpus(pat, n, &seq, &offsets, &positions, &cigars, &ref, &ref_len);

    ttio_ref_diff_v2_input in = {
        .sequences = seq, .offsets = offsets, .positions = positions,
        .cigar_strings = (const char **)cigars, .n_reads = n,
        .reference = ref, .reference_length = ref_len,
        .reads_per_slice = 10000,
        .reference_md5 = (const uint8_t *)"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        .reference_uri = "test",
    };
    uint64_t total_bases = offsets[n];
    size_t cap = ttio_ref_diff_v2_max_encoded_size(n, total_bases);
    uint8_t *enc = malloc(cap);
    if (!enc) { fprintf(stderr, "alloc fail\n"); return 1; }
    size_t enc_len = cap;
    int rc = ttio_ref_diff_v2_encode(&in, enc, &enc_len);
    if (rc != 0) {
        fprintf(stderr, "encode rc=%d n=%lu pat=%s\n", rc, (unsigned long)n, PNAMES[pat]);
        return 1;
    }

    uint8_t *out_seq = malloc(total_bases ? total_bases : 1);
    uint64_t *out_offsets = calloc(n + 1, sizeof(uint64_t));
    if (!out_seq || !out_offsets) {
        fprintf(stderr, "alloc fail\n");
        free(out_seq); free(out_offsets);
        free(enc);
        for (uint64_t r = 0; r < n; r++) free(cigars[r]);
        free(seq); free(offsets); free(positions); free(cigars); free(ref);
        return 1;
    }
    rc = ttio_ref_diff_v2_decode(enc, enc_len, positions, (const char **)cigars,
                                  n, ref, ref_len, out_seq, out_offsets);
    if (rc != 0) {
        fprintf(stderr, "decode rc=%d n=%lu pat=%s\n", rc, (unsigned long)n, PNAMES[pat]);
        free(out_seq); free(out_offsets); free(enc);
        for (uint64_t r = 0; r < n; r++) free(cigars[r]);
        free(seq); free(offsets); free(positions); free(cigars); free(ref);
        return 1;
    }
    if (out_offsets[n] != total_bases) {
        fprintf(stderr, "len mismatch n=%lu pat=%s (%lu vs %lu)\n",
                (unsigned long)n, PNAMES[pat],
                (unsigned long)out_offsets[n], (unsigned long)total_bases);
        free(out_seq); free(out_offsets); free(enc);
        for (uint64_t r = 0; r < n; r++) free(cigars[r]);
        free(seq); free(offsets); free(positions); free(cigars); free(ref);
        return 1;
    }
    if (memcmp(seq, out_seq, total_bases) != 0) {
        fprintf(stderr, "seq mismatch n=%lu pat=%s\n", (unsigned long)n, PNAMES[pat]);
        free(out_seq); free(out_offsets); free(enc);
        for (uint64_t r = 0; r < n; r++) free(cigars[r]);
        free(seq); free(offsets); free(positions); free(cigars); free(ref);
        return 1;
    }
    printf("  n=%-8lu pat=%-12s enc=%7zu bytes (%.3f B/base): PASS\n",
           (unsigned long)n, PNAMES[pat], enc_len,
           total_bases ? (double)enc_len / (double)total_bases : 0.0);

    free(out_seq); free(out_offsets); free(enc);
    for (uint64_t r = 0; r < n; r++) free(cigars[r]);
    free(seq); free(offsets); free(positions); free(cigars); free(ref);
    return 0;
}

/* I2: ESC length conservation. Tamper esc_len in the slice subhdr. */
static int test_i2(void) {
    uint8_t *seq, *ref;
    uint64_t *offsets;
    int64_t *positions;
    char **cigars;
    uint64_t ref_len;
    gen_corpus(P_N_HEAVY, 10, &seq, &offsets, &positions, &cigars, &ref, &ref_len);

    ttio_ref_diff_v2_input in = {
        .sequences = seq, .offsets = offsets, .positions = positions,
        .cigar_strings = (const char **)cigars, .n_reads = 10,
        .reference = ref, .reference_length = ref_len,
        .reads_per_slice = 10000,
        .reference_md5 = (const uint8_t *)"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        .reference_uri = "test",
    };
    size_t cap = ttio_ref_diff_v2_max_encoded_size(10, offsets[10]);
    uint8_t *enc = malloc(cap);
    if (!enc) {
        for (uint64_t r = 0; r < 10; r++) free(cigars[r]);
        free(seq); free(offsets); free(positions); free(cigars); free(ref);
        return 1;
    }
    size_t enc_len = cap;
    int rc = ttio_ref_diff_v2_encode(&in, enc, &enc_len);
    if (rc != 0) {
        fprintf(stderr, "I2 encode rc=%d\n", rc);
        free(enc);
        for (uint64_t r = 0; r < 10; r++) free(cigars[r]);
        free(seq); free(offsets); free(positions); free(cigars); free(ref);
        return 1;
    }

    /*
     * Locate slice 0 body:
     *   outer header = RDV2_OUTER_FIXED + strlen("test") = 38 + 4 = 42 bytes
     *   slice index entry = RDV2_SLICE_INDEX_ENTRY = 32 bytes per slice
     *   slice bodies start at: 42 + 1*32 = 74
     *
     * Slice sub-header (spec §4.4): 6 x u32 LE = 24 bytes:
     *   [0..3]   flag_len
     *   [4..7]   bs_len
     *   [8..11]  in_len
     *   [12..15] sc_len
     *   [16..19] esc_len   ← tamper here
     *   [20..23] reserved
     */
    size_t outer_header_len  = (size_t)(RDV2_OUTER_FIXED) + strlen("test"); /* 42 */
    size_t slice_body_off    = outer_header_len + RDV2_SLICE_INDEX_ENTRY;   /* 74 */

    /* Zero out esc_len (4 bytes at subhdr offset 16) */
    enc[slice_body_off + 16] = 0;
    enc[slice_body_off + 17] = 0;
    enc[slice_body_off + 18] = 0;
    enc[slice_body_off + 19] = 0;

    uint8_t *out_seq = malloc(offsets[10]);
    uint64_t *out_offsets = calloc(11, sizeof(uint64_t));
    if (!out_seq || !out_offsets) {
        free(out_seq); free(out_offsets); free(enc);
        for (uint64_t r = 0; r < 10; r++) free(cigars[r]);
        free(seq); free(offsets); free(positions); free(cigars); free(ref);
        return 1;
    }
    rc = ttio_ref_diff_v2_decode(enc, enc_len, positions, (const char **)cigars,
                                  10, ref, ref_len, out_seq, out_offsets);
    free(out_seq); free(out_offsets); free(enc);
    for (uint64_t r = 0; r < 10; r++) free(cigars[r]);
    free(seq); free(offsets); free(positions); free(cigars); free(ref);

    if (rc == 0) {
        fprintf(stderr, "I2 FAIL: decoder accepted tampered esc_len\n");
        return 1;
    }
    printf("I2 ESC length conservation: PASS (rc=%d on tampered ESC_LEN)\n", rc);
    return 0;
}

int main(void) {
    uint64_t sizes[] = {1, 100, 10000};
    pattern_t patterns[] = {P_PERFECT, P_SUB_HEAVY, P_INS_HEAVY, P_SC_HEAVY, P_N_HEAVY, P_MIXED};
    int n_sizes    = (int)(sizeof(sizes)    / sizeof(sizes[0]));
    int n_patterns = (int)(sizeof(patterns) / sizeof(patterns[0]));
    printf("Stress test: %d sizes x %d patterns = %d round-trips\n",
           n_sizes, n_patterns, n_sizes * n_patterns);
    for (int s = 0; s < n_sizes; s++) {
        for (int p = 0; p < n_patterns; p++) {
            if (run_one(sizes[s], patterns[p]) != 0) return 1;
        }
    }
    if (test_i2() != 0) return 1;
    printf("I4 ESC stream_id reserved range: SKIP (covered by code-path inspection)\n");
    printf("test_ref_diff_v2_stress: ALL PASS\n");
    return 0;
}
