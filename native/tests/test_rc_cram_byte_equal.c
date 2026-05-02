/* native/tests/test_rc_cram_byte_equal.c
 *
 * Phase 1 byte-equality gate: rc_cram primitives produce byte-equal
 * output to htscodecs c_range_coder.h when both encode the same
 * synthetic 1M-symbol pseudorandom input against a flat freq table.
 *
 * The actual cmp comparison happens at the shell level after this
 * test writes /tmp/rc_cram_ours.bin and the htscodecs reference
 * program writes /tmp/rc_cram_htscodecs.bin.
 */
#include "rc_cram.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Same LCG as rc_cram_htscodecs_ref.c */
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

    rc_cram_encoder e;
    rc_cram_encoder_init(&e, enc, N * 2 + 16);
    for (size_t i = 0; i < N; i++) {
        rc_cram_encode(&e, syms[i], 1, 256);
    }
    size_t enc_len = rc_cram_encoder_finish(&e);
    if (enc_len == 0) { fprintf(stderr, "encode failed\n"); return 3; }
    if (e.err) { fprintf(stderr, "encode error: %d\n", e.err); return 3; }
    fprintf(stderr, "rc_cram encoded %zu symbols to %zu bytes\n", N, enc_len);

    /* Self-consistency: decode should recover the input */
    rc_cram_decoder d;
    rc_cram_decoder_init(&d, enc, enc_len);
    if (d.err) { fprintf(stderr, "decoder init failed\n"); return 4; }
    for (size_t i = 0; i < N; i++) {
        uint32_t target = rc_cram_decode_target(&d, 256);
        uint8_t  sym    = (uint8_t)target;
        rc_cram_decode_advance(&d, sym, 1, 256);
        if (d.err) {
            fprintf(stderr, "decode error at i=%zu\n", i);
            return 4;
        }
        if (sym != syms[i]) {
            fprintf(stderr, "self-consistency MISMATCH at i=%zu: got=%u expected=%u\n",
                    i, sym, syms[i]);
            return 4;
        }
    }
    fprintf(stderr, "rc_cram self-consistency: OK\n");

    /* Write encoded bytes for cmp comparison */
    const char *out_path = (argc > 1) ? argv[1] : "/tmp/rc_cram_ours.bin";
    FILE *f = fopen(out_path, "wb");
    if (!f) { fprintf(stderr, "cannot open %s\n", out_path); return 5; }
    if (fwrite(enc, 1, enc_len, f) != enc_len) { fclose(f); return 6; }
    fclose(f);
    fprintf(stderr, "wrote encoded bytes to %s\n", out_path);

    free(syms); free(enc);
    return 0;
}
