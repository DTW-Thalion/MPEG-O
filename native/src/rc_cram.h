/* native/src/rc_cram.h
 *
 * CRAM 3.1 fqzcomp Range Coder primitives. Byte-compatible with
 * the embedded RC inside htscodecs/fqzcomp_qual.c.
 *
 * This is NOT shared with V3's adaptive RC kernel
 * (rans_encode_adaptive.c); CRAM's RC has subtle differences
 * (state init, renorm threshold, end-of-stream handling) that
 * make a unified primitive infeasible without breaking V3 byte
 * compatibility.
 */
#ifndef TTIO_RC_CRAM_H
#define TTIO_RC_CRAM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Encoder state. Caller-allocates; opaque. */
typedef struct rc_cram_encoder {
    uint32_t low;
    uint32_t range;
    uint32_t carry;   /* carry flag for overflow propagation */
    uint32_t ff_num;  /* count of pending 0xFF bytes (deferred emit) */
    uint32_t cache;   /* top byte of low, ready to emit on next flush */
    uint8_t  *out;          /* output buffer (caller-owned) */
    size_t    out_pos;      /* next write position */
    size_t    out_cap;      /* output buffer capacity */
    int       err;          /* 0 = OK; negative = error */
} rc_cram_encoder;

/* Decoder state. Caller-allocates; opaque. */
typedef struct rc_cram_decoder {
    uint32_t low;
    uint32_t range;
    uint32_t code;
    const uint8_t *in;
    size_t    in_pos;
    size_t    in_len;
    int       err;
} rc_cram_decoder;

/* Initialise encoder. out_cap must be >= input_size + slack. */
void rc_cram_encoder_init(rc_cram_encoder *e, uint8_t *out, size_t out_cap);

/* Initialise decoder by reading the first 5 bytes from `in`. */
void rc_cram_decoder_init(rc_cram_decoder *d, const uint8_t *in, size_t in_len);

/* Encode one symbol given its cumulative-frequency interval [cf, cf+f)
 * and the total frequency T. */
void rc_cram_encode(rc_cram_encoder *e, uint32_t cf, uint32_t f, uint32_t T);

/* Decode the next symbol. Caller maintains the freq table; this returns
 * the cumulative-frequency value to look up in the table. */
uint32_t rc_cram_decode_target(rc_cram_decoder *d, uint32_t T);

/* After decoding the symbol from the freq table, call this with the
 * decoded symbol's [cf, cf+f) to advance the decoder. */
void rc_cram_decode_advance(rc_cram_decoder *d, uint32_t cf, uint32_t f, uint32_t T);

/* Flush the encoder to produce the final byte stream. Returns the
 * number of bytes written. */
size_t rc_cram_encoder_finish(rc_cram_encoder *e);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_RC_CRAM_H */
