/*
 * TTIOQuality.m — clean-room QUALITY_BINNED genomic quality-score codec.
 *
 * Mirrors python/src/ttio/codecs/quality.py byte-for-byte. See the
 * header for the wire-format spec. No htslib / CRUMBLE / NCBI SRA
 * toolkit source consulted.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIOQuality.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── Wire-format constants (HANDOFF M85 §3) ─────────────────────────

enum {
    TTIO_Q_VERSION    = 0x00,
    TTIO_Q_SCHEME_I8  = 0x00,  // illumina-8
    TTIO_Q_HEADER_LEN = 6,
};

static NSString * const kTTIOQualityErrorDomain = @"TTIOQualityError";

// ── Lookup tables (Illumina-8 scheme; HANDOFF binding §91/§92/§93) ─
//
// s_pack_table[b]: bin index 0..7 for input Phred byte b.
//   0..1   -> 0      25..29 -> 4
//   2..9   -> 1      30..34 -> 5
//   10..19 -> 2      35..39 -> 6
//   20..24 -> 3      40..255 -> 7    (saturates)
//
// s_centre_table[bin]: bin centre (output Phred byte). Indices 0..7
// hold the Illumina-8 centres; 8..15 are unreachable from a
// well-formed stream (encoder only emits 0..7) but the decode pass
// indexes by the high/low nibble values 0..15, so we keep the table
// 16-entry and silently map 8..15 to 0 (mirrors the Python reference,
// HANDOFF gotcha §11).

static const uint8_t s_pack_table[256] = {
    /* 0..1 -> 0 */
    0, 0,
    /* 2..9 -> 1 */
    1, 1, 1, 1, 1, 1, 1, 1,
    /* 10..19 -> 2 */
    2, 2, 2, 2, 2, 2, 2, 2, 2, 2,
    /* 20..24 -> 3 */
    3, 3, 3, 3, 3,
    /* 25..29 -> 4 */
    4, 4, 4, 4, 4,
    /* 30..34 -> 5 */
    5, 5, 5, 5, 5,
    /* 35..39 -> 6 */
    6, 6, 6, 6, 6,
    /* 40..255 -> 7 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 40..49 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 50..59 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 60..69 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 70..79 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 80..89 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 90..99 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 100..109 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 110..119 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 120..129 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 130..139 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 140..149 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 150..159 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 160..169 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 170..179 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 180..189 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 190..199 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 200..209 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 210..219 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 220..229 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 230..239 */
    7, 7, 7, 7, 7, 7, 7, 7, 7, 7,    /* 240..249 */
    7, 7, 7, 7, 7, 7,                /* 250..255 */
};

// 16-entry: bin 0..7 -> centre, 8..15 -> 0 (unreachable from valid
// streams; matches Python's "trust the encoder" policy).
static const uint8_t s_centre_table[16] = {
    0, 5, 15, 22, 27, 32, 37, 40,
    0, 0,  0,  0,  0,  0,  0,  0,
};

// ── Big-endian byte packing helpers ────────────────────────────────

static inline void be_pack_u32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)((v >> 24) & 0xFF);
    p[1] = (uint8_t)((v >> 16) & 0xFF);
    p[2] = (uint8_t)((v >>  8) & 0xFF);
    p[3] = (uint8_t)( v        & 0xFF);
}

static inline uint32_t be_read_u32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] <<  8) | ((uint32_t)p[3]);
}

// ── Error helper ───────────────────────────────────────────────────

static void ttio_q_set_error(NSError * _Nullable * _Nullable outError,
                             NSInteger code,
                             NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void ttio_q_set_error(NSError * _Nullable * _Nullable outError,
                             NSInteger code,
                             NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:kTTIOQualityErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
#if !__has_feature(objc_arc)
    [msg release];
#endif
}

// ── C core: encode ─────────────────────────────────────────────────

static NSData *ttio_q_encode(const uint8_t *src, size_t orig_len)
{
    const size_t body_len = (orig_len + 1) >> 1;
    const size_t total    = (size_t)TTIO_Q_HEADER_LEN + body_len;

    NSMutableData *out = [NSMutableData dataWithLength:total];
    uint8_t *dst = (uint8_t *)out.mutableBytes;

    // Header: version, scheme_id, original_length (uint32 BE).
    dst[0] = TTIO_Q_VERSION;
    dst[1] = TTIO_Q_SCHEME_I8;
    be_pack_u32(dst + 2, (uint32_t)orig_len);

    if (orig_len == 0) {
        return out;
    }

    uint8_t *body = dst + TTIO_Q_HEADER_LEN;

    // Pack two bin indices per body byte, big-endian within byte:
    // first input quality in the high nibble (binding decision §95).
    // Walk full pairs, then handle a possible odd tail with zero
    // padding in the low nibble (binding decision §96).
    const size_t pairs = orig_len >> 1;
    for (size_t k = 0; k < pairs; k++) {
        const uint8_t hi = s_pack_table[src[2 * k]];
        const uint8_t lo = s_pack_table[src[2 * k + 1]];
        body[k] = (uint8_t)((hi << 4) | lo);
    }
    if (orig_len & 1u) {
        const uint8_t hi = s_pack_table[src[orig_len - 1]];
        body[pairs] = (uint8_t)(hi << 4);   // low nibble = 0 padding
    }

    return out;
}

// ── C core: decode ─────────────────────────────────────────────────

static NSData * _Nullable ttio_q_decode(const uint8_t *src,
                                        size_t enc_len,
                                        NSError * _Nullable * _Nullable outError)
{
    if (enc_len < (size_t)TTIO_Q_HEADER_LEN) {
        ttio_q_set_error(outError, 1,
            @"QUALITY_BINNED stream too short for header: %lu < %d",
            (unsigned long)enc_len, TTIO_Q_HEADER_LEN);
        return nil;
    }

    const uint8_t version = src[0];
    if (version != TTIO_Q_VERSION) {
        ttio_q_set_error(outError, 2,
            @"QUALITY_BINNED bad version byte: 0x%02x (expected 0x%02x)",
            (unsigned)version, (unsigned)TTIO_Q_VERSION);
        return nil;
    }

    const uint8_t scheme_id = src[1];
    if (scheme_id != TTIO_Q_SCHEME_I8) {
        ttio_q_set_error(outError, 3,
            @"QUALITY_BINNED unknown scheme_id: 0x%02x (only 0x%02x = 'illumina-8' is defined)",
            (unsigned)scheme_id, (unsigned)TTIO_Q_SCHEME_I8);
        return nil;
    }

    const uint32_t orig_len = be_read_u32(src + 2);
    const uint64_t expected_body  = ((uint64_t)orig_len + 1u) >> 1;
    const uint64_t expected_total = (uint64_t)TTIO_Q_HEADER_LEN + expected_body;
    if ((uint64_t)enc_len != expected_total) {
        ttio_q_set_error(outError, 4,
            @"QUALITY_BINNED stream length mismatch: %lu != %llu (header %d + body ceil(%u/2) = %llu)",
            (unsigned long)enc_len, (unsigned long long)expected_total,
            TTIO_Q_HEADER_LEN, (unsigned)orig_len,
            (unsigned long long)expected_body);
        return nil;
    }

    if (orig_len == 0) {
        return [NSData data];
    }

    NSMutableData *out = [NSMutableData dataWithLength:orig_len];
    uint8_t *dst = (uint8_t *)out.mutableBytes;
    const uint8_t *body = src + TTIO_Q_HEADER_LEN;

    // Walk body byte-by-byte: high nibble -> output[2k], low nibble
    // -> output[2k+1]. For odd orig_len, the final low nibble is the
    // zero padding (binding decision §96) and we don't write it.
    const uint32_t pairs = orig_len >> 1;
    for (uint32_t k = 0; k < pairs; k++) {
        const uint8_t b = body[k];
        dst[2u * k]      = s_centre_table[(b >> 4) & 0x0F];
        dst[2u * k + 1u] = s_centre_table[ b       & 0x0F];
    }
    if (orig_len & 1u) {
        const uint8_t b = body[pairs];
        dst[orig_len - 1u] = s_centre_table[(b >> 4) & 0x0F];
    }

    return out;
}

// ── ObjC entry points ──────────────────────────────────────────────

NSData *TTIOQualityEncode(NSData *data)
{
    if (data == nil) {
        return ttio_q_encode(NULL, 0);
    }
    return ttio_q_encode((const uint8_t *)data.bytes, (size_t)data.length);
}

NSData * _Nullable TTIOQualityDecode(NSData *encoded,
                                     NSError * _Nullable * _Nullable error)
{
    if (encoded == nil) {
        ttio_q_set_error(error, 1,
            @"QUALITY_BINNED stream too short for header: 0 < %d",
            TTIO_Q_HEADER_LEN);
        return nil;
    }
    return ttio_q_decode((const uint8_t *)encoded.bytes,
                         (size_t)encoded.length, error);
}
