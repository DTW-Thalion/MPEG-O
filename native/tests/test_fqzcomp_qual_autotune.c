/* native/tests/test_fqzcomp_qual_autotune.c
 *
 * Phase 3 gate: ttio_fqzcomp_qual_compress with strategy_hint = -1
 * (auto-tune) — produces output that round-trips through
 * ttio_fqzcomp_qual_uncompress, AND should be byte-equal to htscodecs
 * fqz_compress(gp=NULL) on the same input.
 *
 * Byte-equality vs htscodecs auto-tune is verified out-of-band by
 * comparing the output written here against the output of
 * tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref_autotune on the
 * same {qual,lens,flags} triple. The shell helper
 * tools/perf/htscodecs_compare.sh wraps this for the multi-corpus run.
 *
 * Argv-parametrized so the same binary can be run on chr22 / WES /
 * HG002 Illumina / HG002 PacBio HiFi inputs.
 */
#include "fqzcomp_qual.h"

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint8_t *read_file(const char *path, size_t *len) {
    FILE *f = fopen(path, "rb");
    if (!f) return NULL;
    if (fseek(f, 0, SEEK_END) != 0) { fclose(f); return NULL; }
    long sz = ftell(f);
    if (sz < 0) { fclose(f); return NULL; }
    if (fseek(f, 0, SEEK_SET) != 0) { fclose(f); return NULL; }
    *len = (size_t)sz;
    uint8_t *buf = (uint8_t *)malloc(*len ? *len : 1);
    if (!buf) { fclose(f); return NULL; }
    if (*len && fread(buf, 1, *len, f) != *len) {
        free(buf); fclose(f); return NULL;
    }
    fclose(f);
    return buf;
}

int main(int argc, char **argv) {
    if (argc < 5) {
        fprintf(stderr,
                "usage: %s qual.bin lens.bin flags.bin out.fqz\n", argv[0]);
        return 1;
    }
    const char *qual_path  = argv[1];
    const char *lens_path  = argv[2];
    const char *flags_path = argv[3];
    const char *out_path   = argv[4];

    size_t qual_len = 0, lens_len = 0, flags_len = 0;
    uint8_t *qual_in  = read_file(qual_path,  &qual_len);
    uint8_t *lens_buf = read_file(lens_path,  &lens_len);
    uint8_t *flags_buf = read_file(flags_path, &flags_len);
    if (!qual_in || !lens_buf || !flags_buf) {
        fprintf(stderr,
                "missing input files (qual=%p lens=%p flags=%p)\n",
                (void *)qual_in, (void *)lens_buf, (void *)flags_buf);
        free(qual_in); free(lens_buf); free(flags_buf);
        return 2;
    }

    uint32_t *read_lengths = (uint32_t *)lens_buf;
    size_t    n_reads      = lens_len / sizeof(uint32_t);

    /* The public API takes uint8_t* flags; our extractor emits uint32 per read.
     * Project to uint8 by taking the low byte (preserves SAM_REVERSE_FLAG bit
     * 4, the only flag bit our auto-tune currently consults; selector bits in
     * the high 16 are written internally by fqz_qual_stats and don't need to
     * come from the caller). */
    uint32_t *flags_u32 = (uint32_t *)flags_buf;
    uint8_t  *flags_u8  = (uint8_t *)malloc(n_reads ? n_reads : 1);
    if (!flags_u8) { fprintf(stderr, "OOM\n"); return 1; }
    for (size_t i = 0; i < n_reads; i++)
        flags_u8[i] = (uint8_t)flags_u32[i];

    fprintf(stderr, "input: %zu qualities, %zu reads\n", qual_len, n_reads);

    size_t out_cap = qual_len + qual_len / 4 + (size_t)1024 * 1024;
    uint8_t *out = (uint8_t *)malloc(out_cap);
    if (!out) { fprintf(stderr, "OOM out\n"); return 1; }
    size_t out_len = out_cap;

    int rc = ttio_fqzcomp_qual_compress(qual_in, qual_len,
                                        read_lengths, n_reads,
                                        flags_u8,
                                        -1, /* auto-tune */
                                        out, &out_len);
    if (rc != 0) {
        fprintf(stderr, "compress rc=%d\n", rc);
        return 2;
    }
    fprintf(stderr,
            "auto-tune encoded %zu qualities to %zu bytes (B/qual=%.4f)\n",
            qual_len, out_len, (double)out_len / (double)qual_len);

    FILE *f = fopen(out_path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", out_path); return 3; }
    if (fwrite(out, 1, out_len, f) != out_len) {
        fclose(f); fprintf(stderr, "short write\n"); return 3;
    }
    fclose(f);
    fprintf(stderr, "wrote to %s\n", out_path);

    /* Round-trip self-check */
    uint8_t *recovered = (uint8_t *)malloc(qual_len ? qual_len : 1);
    if (!recovered) { fprintf(stderr, "OOM recovered\n"); return 1; }
    int rc2 = ttio_fqzcomp_qual_uncompress(out, out_len,
                                           read_lengths, n_reads,
                                           flags_u8,
                                           recovered, qual_len);
    if (rc2 != 0) {
        fprintf(stderr, "decompress rc=%d\n", rc2);
        return 4;
    }
    if (memcmp(recovered, qual_in, qual_len) != 0) {
        size_t k;
        for (k = 0; k < qual_len; k++)
            if (recovered[k] != qual_in[k]) break;
        fprintf(stderr,
                "round-trip MISMATCH at byte %zu: got=0x%02x want=0x%02x\n",
                k, recovered[k], qual_in[k]);
        return 5;
    }
    fprintf(stderr, "round-trip: OK\n");

    free(recovered);
    free(qual_in); free(lens_buf); free(flags_buf); free(flags_u8); free(out);
    return 0;
}
