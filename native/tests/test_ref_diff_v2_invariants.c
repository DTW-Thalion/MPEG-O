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


/* v1.9 UL substream: unmapped reads (CIGAR "*") inside a mapped slice.
 * Their bases ride in SC (with an ESC for the N), their lengths in UL, and
 * a slice without one still writes 0 in the sub-header word at +20. */
static int test_ul_unmapped_reads_round_trip(void) {
    uint8_t reference[400];
    for (int i = 0; i < 400; i++) reference[i] = "ACGT"[(i * 7 + i / 5) % 4];
    /* 4 reads of 50: mapped, unmapped (differs from ref, has N), mapped, unmapped */
    uint8_t sequences[200];
    memcpy(sequences + 0,   reference + 0,   50);
    for (int i = 0; i < 50; i++) sequences[50 + i] = "TTGCAN"[i % 6];
    memcpy(sequences + 100, reference + 100, 50);
    for (int i = 0; i < 50; i++) sequences[150 + i] = "GATTACA"[i % 7];
    uint64_t offsets[5] = {0, 50, 100, 150, 200};
    int64_t positions[4] = {1, 60, 101, 160};
    const char *cigars[4] = {"50M", "*", "50M", "*"};

    ttio_ref_diff_v2_input in = {
        .sequences = sequences, .offsets = offsets, .positions = positions,
        .cigar_strings = cigars, .n_reads = 4,
        .reference = reference, .reference_length = 400,
        .reads_per_slice = 10000,
        .reference_md5 = (const uint8_t *)"\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0\0",
        .reference_uri = "test",
    };
    size_t cap = ttio_ref_diff_v2_max_encoded_size(4, 200);
    uint8_t *enc = malloc(cap);
    if (!enc) { fprintf(stderr, "alloc fail\n"); return 1; }
    size_t enc_len = cap;
    int rc = ttio_ref_diff_v2_encode(&in, enc, &enc_len);
    if (rc != 0) { fprintf(stderr, "UL encode rc=%d\n", rc); free(enc); return 1; }
    /* one slice: its body starts after the outer header (38 + 4) and the
     * slice index entry (RDV2_SLICE_INDEX_ENTRY); ul_rans_len at +20 must be > 0 */
    size_t body = 38 + 4 + RDV2_SLICE_INDEX_ENTRY;
    uint32_t ul_len = (uint32_t)enc[body + 20] | ((uint32_t)enc[body + 21] << 8)
                    | ((uint32_t)enc[body + 22] << 16) | ((uint32_t)enc[body + 23] << 24);
    if (ul_len == 0) { fprintf(stderr, "UL length is 0 with unmapped reads\n"); free(enc); return 1; }

    uint8_t out_seq[200];
    uint64_t out_offsets[5] = {0, 0, 0, 0, 0};
    rc = ttio_ref_diff_v2_decode(enc, enc_len, positions, cigars, 4,
                                 reference, 400, out_seq, out_offsets);
    if (rc != 0) { fprintf(stderr, "UL decode rc=%d\n", rc); free(enc); return 1; }
    for (int i = 0; i < 5; i++) if (out_offsets[i] != offsets[i]) {
        fprintf(stderr, "UL offsets wrong at %d: %lu\n", i, (unsigned long)out_offsets[i]); free(enc); return 1;
    }
    if (memcmp(sequences, out_seq, 200) != 0) {
        fprintf(stderr, "UL seq mismatch\n"); free(enc); return 1;
    }
    free(enc);

    /* a slice without unmapped reads keeps the word at +20 zero */
    const char *cigars_mapped[4] = {"50M", "50M", "50M", "50M"};
    for (int i = 0; i < 200; i++) sequences[i] = reference[i];
    int64_t positions_mapped[4] = {1, 51, 101, 151};
    in.cigar_strings = cigars_mapped; in.positions = positions_mapped;
    enc = malloc(cap); enc_len = cap;
    rc = ttio_ref_diff_v2_encode(&in, enc, &enc_len);
    if (rc != 0) { fprintf(stderr, "mapped encode rc=%d\n", rc); free(enc); return 1; }
    if (enc[body + 20] | enc[body + 21] | enc[body + 22] | enc[body + 23]) {
        fprintf(stderr, "reserved word not zero for a mapped-only slice\n"); free(enc); return 1;
    }
    free(enc);
    printf("UL unmapped-read round-trip: PASS\n");
    return 0;
}

int main(void) {
    if (test_i6_cigar_parser_smoke() != 0) return 1;
    if (test_i3_single_read_round_trip() != 0) return 1;
    if (test_i3_multi_read_round_trip() != 0) return 1;
    if (test_i5_n_escape_round_trip() != 0) return 1;
    if (test_ul_unmapped_reads_round_trip() != 0) return 1;
    printf("test_ref_diff_v2_invariants: ALL PASS\n");
    return 0;
}
