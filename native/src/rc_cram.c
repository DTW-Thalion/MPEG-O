/* native/src/rc_cram.c
 *
 * CRAM 3.1 fqzcomp Range Coder primitives. See rc_cram.h.
 *
 * Implementation mirrors the embedded RC inside
 * htscodecs/c_range_coder.h (functions RC_StartEncode, RC_FinishEncode,
 * RC_StartDecode, RC_GetFreq, RC_Decode, RC_Encode in the htscodecs
 * source). Byte-equality with htscodecs is enforced by
 * test_rc_cram_byte_equal.c (Phase 1 gate).
 *
 * Key constants (must match htscodecs c_range_coder.h exactly):
 *   TOP   = 1<<24   -- renorm threshold
 *   Thres = 255*TOP -- carry-detect threshold for ShiftLow
 */
#include "rc_cram.h"
#include <string.h>

/* Match htscodecs c_range_coder.h exactly */
#define TOP    (1u << 24)
#define THRES  ((unsigned)(255u * TOP))

/* ---------------------------------------------------------------------------
 * Internal helper: RC_ShiftLowCheck (bounds-checked version).
 * Called from RC_Encode and RC_FinishEncode.
 *
 * htscodecs equivalent:
 *   static inline void RC_ShiftLowCheck(RangeCoder *rc) { ... }
 * ------------------------------------------------------------------------ */
static void shift_low(rc_cram_encoder *e) {
    if (e->low < THRES || e->carry) {
        /* Emit the cached byte, propagating carry */
        if (e->out_pos < e->out_cap) {
            e->out[e->out_pos++] = (uint8_t)(e->cache + e->carry);
        } else {
            e->err = -1;
            return;
        }
        /* Flush any pending 0xFF bytes (carry-1 because carry was 0 when stored) */
        while (e->ff_num) {
            if (e->out_pos < e->out_cap) {
                e->out[e->out_pos++] = (uint8_t)(e->carry - 1);
            } else {
                e->err = -1;
                return;
            }
            e->ff_num--;
        }
        /* Snapshot new top byte */
        e->cache = e->low >> 24;
        e->carry = 0;
    } else {
        /* low == 0xFFxxxxxx: defer the 0xFF byte */
        e->ff_num++;
    }
    e->low <<= 8;
}

/* ---------------------------------------------------------------------------
 * rc_cram_encoder_init
 * Mirrors RC_StartEncode.
 * ------------------------------------------------------------------------ */
void rc_cram_encoder_init(rc_cram_encoder *e, uint8_t *out, size_t out_cap) {
    e->low     = 0;
    e->range   = 0xFFFFFFFFu;
    e->carry   = 0;
    e->ff_num  = 0;
    e->cache   = 0;
    e->out     = out;
    e->out_pos = 0;
    e->out_cap = out_cap;
    e->err     = 0;
}

/* ---------------------------------------------------------------------------
 * rc_cram_decoder_init
 * Mirrors RC_StartDecode: initialise then read 5 bytes into code.
 * htscodecs: DO(5) rc->code = (rc->code<<8) | *rc->in_buf++;
 * ------------------------------------------------------------------------ */
void rc_cram_decoder_init(rc_cram_decoder *d, const uint8_t *in, size_t in_len) {
    d->in     = in;
    d->in_len = in_len;
    d->in_pos = 0;
    d->low    = 0;
    d->range  = 0xFFFFFFFFu;
    d->code   = 0;
    d->err    = 0;
    if (in_len < 5) {
        d->err = -1;
        return;
    }
    /* htscodecs reads first 5 bytes: DO(5) code = (code<<8) | *in_buf++ */
    for (int i = 0; i < 5; i++)
        d->code = (d->code << 8) | d->in[d->in_pos++];
}

/* ---------------------------------------------------------------------------
 * rc_cram_encode
 * Mirrors RC_Encode.
 *
 * htscodecs:
 *   tmp = low;
 *   low  += cumFreq * (range /= totFreq);
 *   range *= freq;
 *   Carry += low < tmp;
 *   while (range < TOP) { range <<= 8; RC_ShiftLowCheck(); }
 * ------------------------------------------------------------------------ */
void rc_cram_encode(rc_cram_encoder *e, uint32_t cf, uint32_t f, uint32_t T) {
    uint32_t tmp = e->low;
    e->low  += cf * (e->range /= T);
    e->range *= f;
    e->carry += (e->low < tmp);   /* overflow detection */
    while (e->range < TOP) {
        e->range <<= 8;
        shift_low(e);
        if (e->err) return;
    }
}

/* ---------------------------------------------------------------------------
 * rc_cram_decode_target
 * Mirrors RC_GetFreq.
 *
 * htscodecs:
 *   return (totFreq && range >= totFreq) ? code / (range /= totFreq) : 0;
 * ------------------------------------------------------------------------ */
uint32_t rc_cram_decode_target(rc_cram_decoder *d, uint32_t T) {
    if (!T || d->range < T) return 0;
    return d->code / (d->range /= T);
}

/* ---------------------------------------------------------------------------
 * rc_cram_decode_advance
 * Mirrors RC_Decode.
 *
 * htscodecs:
 *   code  -= cumFreq * range;
 *   range *= freq;
 *   while (range < TOP) {
 *       if (in_buf >= in_end) { err=-1; return; }
 *       code = (code<<8) + *in_buf++;
 *       range <<= 8;
 *   }
 * ------------------------------------------------------------------------ */
void rc_cram_decode_advance(rc_cram_decoder *d, uint32_t cf, uint32_t f, uint32_t T) {
    /* NOTE: range was already divided by T inside rc_cram_decode_target.
     * htscodecs RC_Decode receives pre-divided range (range /= totFreq was
     * done in RC_GetFreq), so we must NOT divide by T again here. */
    (void)T;
    d->code  -= cf * d->range;
    d->range *= f;
    while (d->range < TOP) {
        if (d->in_pos >= d->in_len) {
            d->err = -1;
            return;
        }
        d->code   = (d->code << 8) + d->in[d->in_pos++];
        d->range <<= 8;
    }
}

/* ---------------------------------------------------------------------------
 * rc_cram_encoder_finish
 * Mirrors RC_FinishEncode: DO(5) RC_ShiftLowCheck().
 * Returns number of bytes written, or sets err on overflow.
 * ------------------------------------------------------------------------ */
size_t rc_cram_encoder_finish(rc_cram_encoder *e) {
    for (int i = 0; i < 5; i++) {
        shift_low(e);
        if (e->err) return e->out_pos;
    }
    return e->out_pos;
}
