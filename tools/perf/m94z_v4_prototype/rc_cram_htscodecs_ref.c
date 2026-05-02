/* tools/perf/m94z_v4_prototype/rc_cram_htscodecs_ref.c
 *
 * Phase 1 byte-equality gate: htscodecs reference program.
 *
 * Encodes 1M pseudorandom symbols against a flat freq table (T=256, f=1)
 * using htscodecs c_range_coder.h directly, then writes the byte stream
 * to /tmp/rc_cram_htscodecs.bin for comparison against our rc_cram output.
 *
 * Compile (header-only, no library link needed):
 *   gcc -O2 -I/home/toddw/TTI-O/tools/perf/htscodecs/htscodecs  *       rc_cram_htscodecs_ref.c -o rc_cram_htscodecs_ref
 *   ./rc_cram_htscodecs_ref
 */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* htscodecs range coder -- header-only, all static inlines */
#include "c_range_coder.h"

/* Same LCG as native/tests/test_rc_cram_byte_equal.c */
static void make_synthetic_input(uint8_t *buf, size_t n, uint32_t seed) {
    uint32_t s = seed;
    for (size_t i = 0; i < n; i++) {
        s = s * 1103515245u + 12345u;
        buf[i] = (uint8_t)(s >> 16);
    }
}

int main(int argc, char **argv) {
    const size_t N = 1u << 20;  /* 1 M symbols */

    uint8_t *syms = malloc(N);
    uint8_t *enc  = malloc(N * 2 + 16);
    if (!syms || !enc) { fprintf(stderr, "OOM\n"); return 2; }

    make_synthetic_input(syms, N, 0xDEADBEEFu);

    /* Encode using htscodecs RangeCoder directly */
    RangeCoder rc;
    memset(&rc, 0, sizeof(rc));

    RC_SetOutput(&rc, (char *)enc);
    RC_SetOutputEnd(&rc, (char *)(enc + N * 2 + 16));
    RC_StartEncode(&rc);

    for (size_t i = 0; i < N; i++) {
        /* Flat freq table: T=256, each symbol has cumFreq=sym, freq=1 */
        RC_Encode(&rc, syms[i], 1, 256);
    }

    if (RC_FinishEncode(&rc) != 0) {
        fprintf(stderr, "RC_FinishEncode returned error\n");
        return 3;
    }

    size_t enc_len = RC_OutSize(&rc);
    fprintf(stderr, "htscodecs encoded %zu symbols to %zu bytes\n", N, enc_len);

    /* Write to output file */
    const char *out_path = (argc > 1) ? argv[1] : "/tmp/rc_cram_htscodecs.bin";
    FILE *f = fopen(out_path, "wb");
    if (!f) { fprintf(stderr, "cannot open %s\n", out_path); return 5; }
    if (fwrite(enc, 1, enc_len, f) != enc_len) { fclose(f); return 6; }
    fclose(f);
    fprintf(stderr, "wrote encoded bytes to %s\n", out_path);

    free(syms); free(enc);
    return 0;
}
