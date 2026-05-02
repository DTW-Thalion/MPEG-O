/* native/tests/test_fqzcomp_qual_strategy1.c
 *
 * Phase 2 gate: ttio_fqzcomp_qual_compress with strategy 1 (HiSeq)
 * produces output that round-trips through ttio_fqzcomp_qual_uncompress.
 *
 * Byte-equality vs htscodecs --strategy=1 is verified out-of-band by
 * comparing /tmp/our_chr22_strategy1.fqz against
 * /tmp/htscodecs_chr22_strategy1.fqz (produced by
 * tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref).
 *
 * Setup: tools/perf/m94z_v4_prototype/extract_chr22_inputs.py extracts
 * qualities + read_lengths + flags from the BAM into binary files at
 * /tmp/chr22_qual.bin, /tmp/chr22_lens.bin, /tmp/chr22_flags.bin.
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
    const char *qual_path  = "/tmp/chr22_qual.bin";
    const char *lens_path  = "/tmp/chr22_lens.bin";
    const char *flags_path = "/tmp/chr22_flags.bin";
    const char *out_path   = (argc > 1) ? argv[1] : "/tmp/our_chr22_strategy1.fqz";

    size_t qual_len = 0, lens_len = 0, flags_len = 0;
    uint8_t *qual_in  = read_file(qual_path,  &qual_len);
    uint8_t *lens_buf = read_file(lens_path,  &lens_len);
    uint8_t *flags_buf = read_file(flags_path, &flags_len);
    if (!qual_in || !lens_buf || !flags_buf) {
        /* Integration-style test: requires chr22 inputs prepared by
         * tools/perf/m94z_v4_prototype/extract_chr22_inputs.py. When the
         * inputs are absent (fresh shell, no /tmp persistence in WSL,
         * CI without the BAM corpus), skip rather than fail. */
        fprintf(stderr,
                "SKIP: missing input files; run "
                "tools/perf/m94z_v4_prototype/extract_chr22_inputs.py to enable\n"
                "  qual=%p lens=%p flags=%p\n",
                (void *)qual_in, (void *)lens_buf, (void *)flags_buf);
        free(qual_in); free(lens_buf); free(flags_buf);
        return 0;
    }

    uint32_t *read_lengths = (uint32_t *)lens_buf;
    size_t    n_reads      = lens_len / sizeof(uint32_t);

    /* flags binary is uint32 per the extractor; but our public API takes
     * uint8 *flags (Phase 2 doesn't consume them anyway under strategy 1).
     * Project flags->uint8 by taking the low byte of each uint32 — keeps
     * SAM_REVERSE_FLAG (bit 4) which is what the htscodecs encoder uses
     * via its uint32_t flags array. */
    uint32_t *flags_u32 = (uint32_t *)flags_buf;
    uint8_t  *flags_u8  = (uint8_t *)malloc(n_reads ? n_reads : 1);
    if (!flags_u8) { fprintf(stderr, "OOM\n"); return 1; }
    for (size_t i = 0; i < n_reads; i++)
        flags_u8[i] = (uint8_t)flags_u32[i];

    fprintf(stderr, "chr22: %zu qualities, %zu reads\n", qual_len, n_reads);

    size_t out_cap = qual_len + qual_len / 4 + (size_t)1024 * 1024;
    uint8_t *out = (uint8_t *)malloc(out_cap);
    if (!out) { fprintf(stderr, "OOM out\n"); return 1; }
    size_t out_len = out_cap;

    int rc = ttio_fqzcomp_qual_compress(qual_in, qual_len,
                                        read_lengths, n_reads,
                                        flags_u8,
                                        1, /* strategy 1 */
                                        out, &out_len);
    if (rc != 0) {
        fprintf(stderr, "compress rc=%d\n", rc);
        return 2;
    }
    fprintf(stderr, "encoded %zu qualities to %zu bytes\n", qual_len, out_len);
    fprintf(stderr, "B/qual = %.4f\n", (double)out_len / (double)qual_len);

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
        /* Find first mismatch for debugging */
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
