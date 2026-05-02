/* tools/perf/m94z_v4_prototype/fqzcomp_htscodecs_ref_autotune.c
 *
 * Phase 3 byte-equality gate: htscodecs reference encoder, AUTO-TUNE mode.
 *
 * Unlike fqzcomp_htscodecs_ref.c (Phase 2, manual gp), this driver passes
 * gp == NULL to fqz_compress, causing htscodecs's fqz_pick_parameters to
 * run its own auto-tune over the input. This must produce byte-identical
 * output to ttio_fqzcomp_qual_compress(strategy_hint = -1) since our
 * auto-tune is a verbatim port of htscodecs's pick_parameters.
 *
 * Parameter choices to match our internal auto-tune dispatcher:
 *   vers  = 4   (any value != 3 is safe; vers only triggers GFLAG_DO_REV
 *               when vers==3; our internal pick_parameters passes
 *               FQZ_VERS=5 which behaves identically wrt output bytes)
 *   strat = 0   (Generic; matches the hardcoded default in
 *               ttio_fqzcomp_qual_compress's strategy_hint == -1 branch)
 *
 * Compile (same flags/libs as Phase 2 driver):
 *   cc -O2 \
 *      -I/home/toddw/TTI-O/tools/perf/htscodecs \
 *      fqzcomp_htscodecs_ref_autotune.c \
 *      /home/toddw/TTI-O/tools/perf/htscodecs/htscodecs/.libs/libhtscodecs.a \
 *      -lz -pthread -lm \
 *      -o fqzcomp_htscodecs_ref_autotune
 *
 * Usage:
 *   ./fqzcomp_htscodecs_ref_autotune qual.bin lens.bin flags.bin out.fqz
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "htscodecs/fqzcomp_qual.h"

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
    uint8_t *qual_in   = read_file(qual_path,  &qual_len);
    uint8_t *lens_buf  = read_file(lens_path,  &lens_len);
    uint8_t *flags_buf = read_file(flags_path, &flags_len);
    if (!qual_in || !lens_buf || !flags_buf) {
        fprintf(stderr, "read failure\n");
        return 2;
    }

    uint32_t *read_lengths = (uint32_t *)lens_buf;
    uint32_t *flags_u32    = (uint32_t *)flags_buf;
    size_t    n_reads      = lens_len / sizeof(uint32_t);

    fprintf(stderr,
            "htscodecs ref autotune: %zu qualities, %zu reads\n",
            qual_len, n_reads);

    fqz_slice s;
    s.num_records = (int)n_reads;
    s.len   = read_lengths;
    s.flags = flags_u32;

    /* Auto-tune: gp == NULL forces htscodecs to run fqz_pick_parameters
     * itself. vers=4, strat=0 to match our internal dispatcher. */
    size_t out_size = 0;
    char *out = fqz_compress(/*vers=*/4, &s,
                             (char *)qual_in, qual_len,
                             &out_size, /*strat=*/0, /*gp=*/NULL);
    if (!out) {
        fprintf(stderr, "fqz_compress (auto-tune) returned NULL\n");
        return 4;
    }
    fprintf(stderr,
            "htscodecs auto-tune encoded %zu qualities to %zu bytes\n",
            qual_len, out_size);
    fprintf(stderr, "B/qual = %.4f\n", (double)out_size / (double)qual_len);

    FILE *f = fopen(out_path, "wb");
    if (!f) { fprintf(stderr, "cannot write %s\n", out_path); return 5; }
    if (fwrite(out, 1, out_size, f) != out_size) {
        fclose(f); fprintf(stderr, "short write\n"); return 5;
    }
    fclose(f);
    fprintf(stderr, "wrote to %s\n", out_path);

    free(out);
    free(qual_in); free(lens_buf); free(flags_buf);
    return 0;
}
