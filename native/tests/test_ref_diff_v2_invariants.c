#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "ttio_rans.h"
#include "ref_diff_v2.h"

static int test_i3_single_read_round_trip(void) {
    uint8_t reference[200];
    for (int i = 0; i < 200; i++) reference[i] = "ACGT"[i % 4];
    uint8_t sequences[100];
    for (int i = 0; i < 100; i++) sequences[i] = reference[i];
    /* 1 substitution at pos 50 */
    if (reference[50] == 'A') reference[50] = 'C'; else reference[50] = 'A';
    sequences[50] = (reference[50] == 'A') ? 'C' : 'A';

    uint64_t offsets[2] = {0, 100};
    int64_t positions[1] = {1};
    const char *cigars[1] = {"100M"};

    ttio_ref_diff_v2_input in = {
        .sequences = sequences, .offsets = offsets, .positions = positions,
        .cigar_strings = cigars, .n_reads = 1,
        .reference = reference, .reference_length = 200,
        .reads_per_slice = 10000,
        .reference_md5 = (const uint8_t *)"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        .reference_uri = "test",
    };
    size_t cap = ttio_ref_diff_v2_max_encoded_size(1, 100);
    uint8_t *enc = malloc(cap);
    if (!enc) { fprintf(stderr, "alloc fail\n"); return 1; }
    size_t enc_len = cap;
    int rc = ttio_ref_diff_v2_encode(&in, enc, &enc_len);
    if (rc != 0) { fprintf(stderr, "single-read encode rc=%d\n", rc); free(enc); return 1; }
    if (enc_len <= 38) { fprintf(stderr, "encoded too small (%zu)\n", enc_len); free(enc); return 1; }
    if (memcmp(enc, "RDF2", 4) != 0) { fprintf(stderr, "magic mismatch\n"); free(enc); return 1; }

    uint8_t *out_seq = malloc(100);
    if (!out_seq) { fprintf(stderr, "alloc fail\n"); free(enc); return 1; }
    uint64_t out_offsets[2] = {0, 0};
    rc = ttio_ref_diff_v2_decode(enc, enc_len, positions, cigars, 1,
                                 reference, 200, out_seq, out_offsets);
    if (rc != 0) { fprintf(stderr, "single-read decode rc=%d\n", rc); free(enc); free(out_seq); return 1; }
    if (out_offsets[0] != 0 || out_offsets[1] != 100) {
        fprintf(stderr, "offsets wrong: [%lu, %lu]\n",
                (unsigned long)out_offsets[0], (unsigned long)out_offsets[1]);
        free(enc); free(out_seq); return 1;
    }
    if (memcmp(sequences, out_seq, 100) != 0) {
        fprintf(stderr, "single-read seq mismatch\n");
        for (int i = 0; i < 100; i++) if (sequences[i] != out_seq[i])
            fprintf(stderr, "  pos %d: orig=%c decoded=%c\n", i, sequences[i], out_seq[i]);
        free(enc); free(out_seq); return 1;
    }
    printf("I3 single-read round-trip: PASS\n");
    free(enc); free(out_seq);
    return 0;
}

static int test_i3_multi_read_round_trip(void) {
    const uint64_t N = 10;
    uint8_t reference[1000];
    for (int i = 0; i < 1000; i++) reference[i] = "ACGTACGT"[i % 8];

    uint8_t sequences[500];
    uint64_t offsets[11];
    int64_t positions[10];
    const char *cigars[10];

    offsets[0] = 0;
    for (uint64_t r = 0; r < N; r++) {
        for (int i = 0; i < 50; i++) {
            sequences[r * 50 + i] = reference[r * 10 + i];
        }
        /* introduce a substitution at position 25 within each read */
        uint8_t orig = reference[r * 10 + 25];
        sequences[r * 50 + 25] = (orig == 'A') ? 'C' : 'A';
        offsets[r + 1] = (r + 1) * 50;
        positions[r] = (int64_t)(r * 10 + 1);
        cigars[r] = "50M";
    }

    ttio_ref_diff_v2_input in = {
        .sequences = sequences, .offsets = offsets, .positions = positions,
        .cigar_strings = cigars, .n_reads = N,
        .reference = reference, .reference_length = 1000,
        .reads_per_slice = 10000,
        .reference_md5 = (const uint8_t *)"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        .reference_uri = "test",
    };
    size_t cap = ttio_ref_diff_v2_max_encoded_size(N, 500);
    uint8_t *enc = malloc(cap);
    if (!enc) return 1;
    size_t enc_len = cap;
    int rc = ttio_ref_diff_v2_encode(&in, enc, &enc_len);
    if (rc != 0) { fprintf(stderr, "multi encode rc=%d\n", rc); free(enc); return 1; }

    uint8_t *out_seq = malloc(500);
    if (!out_seq) { free(enc); return 1; }
    uint64_t out_offsets[11] = {0};
    rc = ttio_ref_diff_v2_decode(enc, enc_len, positions, cigars, N,
                                 reference, 1000, out_seq, out_offsets);
    if (rc != 0) { fprintf(stderr, "multi decode rc=%d\n", rc); free(enc); free(out_seq); return 1; }
    for (uint64_t r = 0; r <= N; r++) {
        if (out_offsets[r] != offsets[r]) {
            fprintf(stderr, "multi offsets[%lu] wrong: %lu vs %lu\n",
                    (unsigned long)r, (unsigned long)out_offsets[r], (unsigned long)offsets[r]);
            free(enc); free(out_seq); return 1;
        }
    }
    if (memcmp(sequences, out_seq, 500) != 0) {
        fprintf(stderr, "multi seq mismatch\n");
        for (int i = 0; i < 500; i++) if (sequences[i] != out_seq[i])
            fprintf(stderr, "  pos %d: orig=%c decoded=%c\n", i, sequences[i], out_seq[i]);
        free(enc); free(out_seq); return 1;
    }
    printf("I3 multi-read round-trip: PASS\n");
    free(enc); free(out_seq);
    return 0;
}

static int test_i5_n_escape_round_trip(void) {
    uint8_t reference[100];
    for (int i = 0; i < 100; i++) reference[i] = 'A';
    uint8_t sequences[50];
    for (int i = 0; i < 50; i++) sequences[i] = 'A';
    /* N bases at substitution positions (differs from ref A) */
    sequences[10] = 'N';
    sequences[20] = 'N';

    uint64_t offsets[2] = {0, 50};
    int64_t positions[1] = {1};
    const char *cigars[1] = {"50M"};
    ttio_ref_diff_v2_input in = {
        .sequences = sequences, .offsets = offsets, .positions = positions,
        .cigar_strings = cigars, .n_reads = 1,
        .reference = reference, .reference_length = 100,
        .reads_per_slice = 10000,
        .reference_md5 = (const uint8_t *)"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        .reference_uri = "test",
    };
    size_t cap = ttio_ref_diff_v2_max_encoded_size(1, 50);
    uint8_t *enc = malloc(cap);
    if (!enc) return 1;
    size_t enc_len = cap;
    int rc = ttio_ref_diff_v2_encode(&in, enc, &enc_len);
    if (rc != 0) { fprintf(stderr, "n-escape encode rc=%d\n", rc); free(enc); return 1; }

    uint8_t *out_seq = malloc(50);
    if (!out_seq) { free(enc); return 1; }
    memset(out_seq, 0, 50);
    uint64_t out_offsets[2] = {0, 0};
    rc = ttio_ref_diff_v2_decode(enc, enc_len, positions, cigars, 1,
                                 reference, 100, out_seq, out_offsets);
    if (rc != 0) { fprintf(stderr, "n-escape decode rc=%d\n", rc); free(enc); free(out_seq); return 1; }
    if (memcmp(sequences, out_seq, 50) != 0) {
        fprintf(stderr, "n-escape seq mismatch\n");
        for (int i = 0; i < 50; i++) if (sequences[i] != out_seq[i])
            fprintf(stderr, "  pos %d: orig=%c decoded=%c\n", i, sequences[i], out_seq[i]);
        free(enc); free(out_seq); return 1;
    }
    if (out_seq[10] != 'N' || out_seq[20] != 'N') {
        fprintf(stderr, "N not preserved: [10]=%c [20]=%c\n", out_seq[10], out_seq[20]);
        free(enc); free(out_seq); return 1;
    }
    printf("I5 N-escape round-trip: PASS\n");
    free(enc); free(out_seq);
    return 0;
}

static int test_i6_cigar_parser_smoke(void) {
    uint64_t m, ins, s;
    if (rdv2_parse_cigar_counts("100M", &m, &ins, &s) != 0 || m != 100 || ins != 0 || s != 0) {
        fprintf(stderr, "I6 100M failed: m=%lu i=%lu s=%lu\n",
                (unsigned long)m, (unsigned long)ins, (unsigned long)s);
        return 1;
    }
    if (rdv2_parse_cigar_counts("50M2I50M", &m, &ins, &s) != 0 || m != 100 || ins != 2 || s != 0) {
        fprintf(stderr, "I6 50M2I50M failed: m=%lu i=%lu s=%lu\n",
                (unsigned long)m, (unsigned long)ins, (unsigned long)s);
        return 1;
    }
    if (rdv2_parse_cigar_counts("5S95M", &m, &ins, &s) != 0 || m != 95 || s != 5 || ins != 0) {
        fprintf(stderr, "I6 5S95M failed: m=%lu i=%lu s=%lu\n",
                (unsigned long)m, (unsigned long)ins, (unsigned long)s);
        return 1;
    }
    if (rdv2_parse_cigar_counts("10M5D10M", &m, &ins, &s) != 0 || m != 20 || ins != 0 || s != 0) {
        fprintf(stderr, "I6 10M5D10M failed: m=%lu i=%lu s=%lu\n",
                (unsigned long)m, (unsigned long)ins, (unsigned long)s);
        return 1;
    }
    if (rdv2_parse_cigar_counts("5S80M3I7M5S", &m, &ins, &s) != 0 || m != 87 || ins != 3 || s != 10) {
        fprintf(stderr, "I6 5S80M3I7M5S failed: m=%lu i=%lu s=%lu\n",
                (unsigned long)m, (unsigned long)ins, (unsigned long)s);
        return 1;
    }
    printf("I6 cigar parser smoke: PASS\n");
    return 0;
}

int main(void) {
    if (test_i6_cigar_parser_smoke() != 0) return 1;
    if (test_i3_single_read_round_trip() != 0) return 1;
    if (test_i3_multi_read_round_trip() != 0) return 1;
    if (test_i5_n_escape_round_trip() != 0) return 1;
    printf("test_ref_diff_v2_invariants: ALL PASS\n");
    return 0;
}
