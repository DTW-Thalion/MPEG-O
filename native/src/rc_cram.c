/* native/src/rc_cram.c
 *
 * CRAM 3.1 fqzcomp Range Coder primitives. See rc_cram.h.
 *
 * Implementation mirrors the embedded RC inside
 * htscodecs/fqzcomp_qual.c (functions RC_StartEncode, RC_FinishEncode,
 * RC_StartDecode, RC_GetFreq, RC_Decode, RC_Encode in the htscodecs
 * source). Byte-equality with htscodecs is enforced by
 * test_rc_cram_byte_equal.c (Phase 1 gate).
 */
#include "rc_cram.h"
#include <string.h>

#define TOP    (1u << 24)
#define BOTTOM (1u << 16)

void rc_cram_encoder_init(rc_cram_encoder *e, uint8_t *out, size_t out_cap) {
    e->low = 0;
    e->range = 0xFFFFFFFFu;
    e->carry = 0;
    e->out = out;
    e->out_pos = 0;
    e->out_cap = out_cap;
    e->err = 0;
}

void rc_cram_decoder_init(rc_cram_decoder *d, const uint8_t *in, size_t in_len) {
    d->in = in;
    d->in_len = in_len;
    d->in_pos = 0;
    d->low = 0;
    d->range = 0xFFFFFFFFu;
    d->code = 0;
    d->err = 0;
    if (in_len < 5) { d->err = -1; return; }
    /* htscodecs reads first byte separately, then 4 more for code */
    d->code = ((uint32_t)in[1] << 24)
            | ((uint32_t)in[2] << 16)
            | ((uint32_t)in[3] <<  8)
            | ((uint32_t)in[4]);
    d->in_pos = 5;
}

void rc_cram_encode(rc_cram_encoder *e, uint32_t cf, uint32_t f, uint32_t T) {
    /* TODO Phase 1 Task 3: implement matching htscodecs RC_Encode */
    (void)e; (void)cf; (void)f; (void)T;
}

uint32_t rc_cram_decode_target(rc_cram_decoder *d, uint32_t T) {
    /* TODO Phase 1 Task 3: implement matching htscodecs RC_GetFreq */
    (void)d; (void)T;
    return 0;
}

void rc_cram_decode_advance(rc_cram_decoder *d, uint32_t cf, uint32_t f, uint32_t T) {
    /* TODO Phase 1 Task 3: implement matching htscodecs RC_Decode */
    (void)d; (void)cf; (void)f; (void)T;
}

size_t rc_cram_encoder_finish(rc_cram_encoder *e) {
    /* TODO Phase 1 Task 3: implement matching htscodecs RC_FinishEncode */
    return e->out_pos;
}
