/*
 * rc_arith.h — Range Coder (arithmetic coder) primitives for L2.
 *
 * Replaces the L2 rANS-Nx16 adaptive scheme (which fails the rANS
 * state invariant x in [L, M) when T_max > 2^15 — see
 * memory feedback_rans_nx16_variable_t_invariant). Uses the
 * Subbotin-style 32-bit range coder, identical in spirit to
 * htslib/htscodecs's c_range_coder.h. CRAM 3.1 fqzcomp_qual.c
 * uses the same coder, so the byte-pairing math is well-trodden.
 *
 * Key advantages over rANS for adaptive freq:
 * - No [L, M) state invariant — any T fits.
 * - Byte stream emission is FIFO (no LIFO reversal needed in
 *   encoder).
 * - Carry handling via the Subbotin "merged renorm" idiom:
 *   the test (low ^ (low + range)) < RC_TOP detects when the top
 *   byte is stable AND not pending-carry.
 *
 * State layout per coder:
 *   uint32_t low    — low end of current range, top byte may
 *                     spill into a virtual "carry" byte (handled
 *                     by integer overflow in 32-bit).
 *   uint32_t range  — width of current range.
 *   uint32_t code   — decoder only; current input window.
 *
 * Renorm constants:
 *   RC_TOP = 2^24 — top-byte boundary
 *   RC_BOT = 2^16 — minimum range threshold (squeeze trigger)
 *
 * Output format:
 *   Encoder emits one byte per renorm step. Decoder consumes one
 *   byte per renorm step. Decoder must read exactly the bytes the
 *   encoder produced, in order.
 *
 * Initialisation:
 *   Encoder: low = 0, range = 0xFFFFFFFF.
 *   Decoder: low = 0, range = 0xFFFFFFFF, code = first 4 bytes.
 *
 * Termination (encoder):
 *   Flush by emitting 4 more bytes (one per simulated renorm).
 *   This empties the state into the byte stream.
 *
 * Copyright (c) 2026 Thalion Global. All rights reserved.
 */
#ifndef TTIO_RC_ARITH_H
#define TTIO_RC_ARITH_H

#include <stdint.h>
#include <stddef.h>

#define TTIO_RC_TOP  (1u << 24)
#define TTIO_RC_BOT  (1u << 16)

typedef struct {
    uint32_t low;
    uint32_t range;
    uint8_t *out;
    uint8_t *out_end;
    int err;
} ttio_rc_enc_t;

typedef struct {
    uint32_t low;
    uint32_t range;
    uint32_t code;
    const uint8_t *in;
    const uint8_t *in_end;
    int err;
} ttio_rc_dec_t;

static inline void ttio_rc_enc_init(ttio_rc_enc_t *rc, uint8_t *out,
                                    size_t cap)
{
    rc->low = 0;
    rc->range = 0xFFFFFFFFu;
    rc->out = out;
    rc->out_end = out + cap;
    rc->err = 0;
}

static inline void ttio_rc_enc_renorm(ttio_rc_enc_t *rc)
{
    /* Subbotin's merged renorm:
     *  - If top byte stable: emit (low >> 24), shift.
     *  - If range too small but top byte unstable (carry pending):
     *    squeeze range to nearest byte boundary and emit anyway.
     */
    while ((rc->low ^ (rc->low + rc->range)) < TTIO_RC_TOP
           || (rc->range < TTIO_RC_BOT
               && ((rc->range = (uint32_t)(-(int32_t)rc->low) & (TTIO_RC_BOT - 1)), 1))) {
        if (rc->out >= rc->out_end) { rc->err = 1; return; }
        *rc->out++ = (uint8_t)(rc->low >> 24);
        rc->range <<= 8;
        rc->low <<= 8;
    }
}

static inline void ttio_rc_enc_encode(ttio_rc_enc_t *rc,
                                      uint32_t cumf, uint32_t freq,
                                      uint32_t total)
{
    rc->range /= total;
    rc->low += cumf * rc->range;
    rc->range *= freq;
    ttio_rc_enc_renorm(rc);
}

static inline size_t ttio_rc_enc_finish(ttio_rc_enc_t *rc)
{
    /* Flush 4 bytes to drain the state. */
    for (int i = 0; i < 4; i++) {
        if (rc->out >= rc->out_end) { rc->err = 1; break; }
        *rc->out++ = (uint8_t)(rc->low >> 24);
        rc->low <<= 8;
    }
    return (size_t)(rc->out - (rc->out_end - (rc->out_end - rc->out)));
}

static inline size_t ttio_rc_enc_bytes_written(const ttio_rc_enc_t *rc,
                                               const uint8_t *out_base)
{
    return (size_t)(rc->out - out_base);
}

static inline int ttio_rc_dec_init(ttio_rc_dec_t *rc, const uint8_t *in,
                                   size_t cap)
{
    rc->low = 0;
    rc->range = 0xFFFFFFFFu;
    rc->in = in;
    rc->in_end = in + cap;
    rc->err = 0;
    if (cap < 4) { rc->err = 1; rc->code = 0; return -1; }
    rc->code = ((uint32_t)rc->in[0] << 24) | ((uint32_t)rc->in[1] << 16)
             | ((uint32_t)rc->in[2] << 8)  | (uint32_t)rc->in[3];
    rc->in += 4;
    return 0;
}

static inline uint32_t ttio_rc_dec_get_freq(ttio_rc_dec_t *rc,
                                            uint32_t total)
{
    rc->range /= total;
    uint32_t slot = (rc->code - rc->low) / rc->range;
    return slot < total ? slot : total - 1u;
}

static inline void ttio_rc_dec_advance(ttio_rc_dec_t *rc,
                                       uint32_t cumf, uint32_t freq)
{
    rc->low += cumf * rc->range;
    rc->range *= freq;
    while ((rc->low ^ (rc->low + rc->range)) < TTIO_RC_TOP
           || (rc->range < TTIO_RC_BOT
               && ((rc->range = (uint32_t)(-(int32_t)rc->low) & (TTIO_RC_BOT - 1)), 1))) {
        if (rc->in >= rc->in_end) { rc->err = 1; return; }
        rc->code = (rc->code << 8) | (uint32_t)(*rc->in++);
        rc->range <<= 8;
        rc->low <<= 8;
    }
}

#endif /* TTIO_RC_ARITH_H */
