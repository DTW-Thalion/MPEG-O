/*
 * TTIOBasePack.m — clean-room BASE_PACK genomic-sequence codec.
 *
 * Mirrors python/src/ttio/codecs/base_pack.py byte-for-byte. See the
 * header for the wire-format spec. No htslib / CRAM tools-Java / jbzip
 * source consulted.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIOBasePack.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── Wire-format constants (HANDOFF §2) ─────────────────────────────

enum {
    TTIO_BP_VERSION       = 0x00,
    TTIO_BP_HEADER_LEN    = 13,
    TTIO_BP_MASK_ENTRY_LEN = 5,
};

static NSString * const kTTIOBasePackErrorDomain = @"TTIOBasePackError";

// ── Pack lookup tables (HANDOFF §1, binding decision §81) ──────────
//
// _PACK_TABLE[b]: 2-bit slot value for byte b.
//   A->0b00, C->0b01, G->0b10, T->0b11, anything else -> 0 (placeholder).
//
// _MARK_TABLE[b]: 1 if b is non-ACGT (needs a mask entry), else 0.

static const uint8_t s_pack_table[256] = {
    /* 0x00..0x3F */
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    /* 0x40..0x7F: 'A' = 0x41 -> 0, 'C' = 0x43 -> 1,
                   'G' = 0x47 -> 2, 'T' = 0x54 -> 3 */
    0,0,0,1,0,0,0,2, 0,0,0,0,0,0,0,0,    /* 0x40..0x4F: A=1, C=3, G=7 */
    0,0,0,0,3,0,0,0, 0,0,0,0,0,0,0,0,    /* 0x50..0x5F: T at offset 4 */
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,    /* 0x60..0x6F */
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,    /* 0x70..0x7F */
    /* 0x80..0xFF */
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
    0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0,
};

static const uint8_t s_mark_table[256] = {
    /* All-1 by default, with ACGT cleared at 0x41/0x43/0x47/0x54 */
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,0,1,0,1,1,1,0, 1,1,1,1,1,1,1,1,    /* 0x40..0x4F: A,C,G clear */
    1,1,1,1,0,1,1,1, 1,1,1,1,1,1,1,1,    /* 0x50..0x5F: T at 0x54 clear */
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
    1,1,1,1,1,1,1,1, 1,1,1,1,1,1,1,1,
};

// 4-entry decode table (slot value -> ASCII base).
static const uint8_t s_unpack_table[4] = {'A', 'C', 'G', 'T'};

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

static void ttio_bp_set_error(NSError * _Nullable * _Nullable outError,
                              NSInteger code,
                              NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void ttio_bp_set_error(NSError * _Nullable * _Nullable outError,
                              NSInteger code,
                              NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:kTTIOBasePackErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
#if !__has_feature(objc_arc)
    [msg release];
#endif
}

// ── C core: encode ─────────────────────────────────────────────────
//
// Two-pass design:
//   Pass 1: count mask entries via s_mark_table to size the output.
//   Pass 2: write packed body and mask entries directly to the output
//           buffer in a single scan (no intermediate allocations).

static NSData *ttio_bp_encode(const uint8_t *src, size_t orig_len)
{
    const size_t packed_len = (orig_len + 3) / 4;

    // Pass 1: count mask entries.
    size_t mask_count = 0;
    for (size_t i = 0; i < orig_len; i++) {
        mask_count += s_mark_table[src[i]];
    }

    const size_t total = TTIO_BP_HEADER_LEN
                       + packed_len
                       + (size_t)TTIO_BP_MASK_ENTRY_LEN * mask_count;

    NSMutableData *out = [NSMutableData dataWithLength:total];
    uint8_t *dst = (uint8_t *)out.mutableBytes;

    // Header.
    dst[0] = TTIO_BP_VERSION;
    be_pack_u32(dst + 1, (uint32_t)orig_len);
    be_pack_u32(dst + 5, (uint32_t)packed_len);
    be_pack_u32(dst + 9, (uint32_t)mask_count);

    // Body + mask are written in a single left-to-right scan. The mask
    // entries are appended in input order, which is naturally ascending
    // by position (binding decision §84).
    uint8_t *body = dst + TTIO_BP_HEADER_LEN;
    uint8_t *mask = dst + TTIO_BP_HEADER_LEN + packed_len;

    // Pre-zero the body so the final padded byte's unused bits are
    // already zero (HANDOFF binding decision §83 / gotcha §94).
    if (packed_len > 0) {
        memset(body, 0, packed_len);
    }

    for (size_t i = 0; i < orig_len; i++) {
        uint8_t b = src[i];
        const size_t byte_idx = i >> 2;
        const unsigned slot = (unsigned)(i & 3);
        // Big-endian within byte: first base = highest two bits.
        // shift = (3 - slot) * 2  =>  slot 0 -> 6, 1 -> 4, 2 -> 2, 3 -> 0.
        const unsigned shift = (3u - slot) * 2u;
        body[byte_idx] |= (uint8_t)(s_pack_table[b] << shift);

        if (s_mark_table[b]) {
            be_pack_u32(mask, (uint32_t)i);
            mask[4] = b;
            mask += TTIO_BP_MASK_ENTRY_LEN;
        }
    }

    return out;
}

// ── C core: decode ─────────────────────────────────────────────────

static NSData * _Nullable ttio_bp_decode(const uint8_t *src,
                                         size_t enc_len,
                                         NSError * _Nullable * _Nullable outError)
{
    if (enc_len < (size_t)TTIO_BP_HEADER_LEN) {
        ttio_bp_set_error(outError, 1,
            @"BASE_PACK stream too short for header: %lu < %d",
            (unsigned long)enc_len, TTIO_BP_HEADER_LEN);
        return nil;
    }

    const uint8_t version = src[0];
    if (version != TTIO_BP_VERSION) {
        ttio_bp_set_error(outError, 2,
            @"BASE_PACK bad version byte: 0x%02x (expected 0x%02x)",
            (unsigned)version, (unsigned)TTIO_BP_VERSION);
        return nil;
    }

    const uint32_t orig_len   = be_read_u32(src + 1);
    const uint32_t packed_len = be_read_u32(src + 5);
    const uint32_t mask_count = be_read_u32(src + 9);

    const uint64_t expected_packed = ((uint64_t)orig_len + 3u) / 4u;
    if ((uint64_t)packed_len != expected_packed) {
        ttio_bp_set_error(outError, 3,
            @"BASE_PACK packed_length mismatch: %u != ceil(%u/4) = %llu",
            (unsigned)packed_len, (unsigned)orig_len,
            (unsigned long long)expected_packed);
        return nil;
    }

    const uint64_t expected_total = (uint64_t)TTIO_BP_HEADER_LEN
                                  + (uint64_t)packed_len
                                  + (uint64_t)TTIO_BP_MASK_ENTRY_LEN * (uint64_t)mask_count;
    if ((uint64_t)enc_len != expected_total) {
        ttio_bp_set_error(outError, 4,
            @"BASE_PACK stream length mismatch: %lu != %llu (header %d + body %u + mask %d*%u)",
            (unsigned long)enc_len, (unsigned long long)expected_total,
            TTIO_BP_HEADER_LEN, (unsigned)packed_len,
            TTIO_BP_MASK_ENTRY_LEN, (unsigned)mask_count);
        return nil;
    }

    NSMutableData *out = [NSMutableData dataWithLength:orig_len];
    uint8_t *dst = (uint8_t *)out.mutableBytes;

    // Unpack body. Walk full body bytes that produce a complete 4-base
    // run, then handle the final partial byte separately so we never
    // write beyond orig_len.
    const uint8_t *body = src + TTIO_BP_HEADER_LEN;
    if (orig_len > 0) {
        const uint32_t full_bytes = orig_len >> 2;
        const uint32_t tail = orig_len - (full_bytes << 2);
        for (uint32_t k = 0; k < full_bytes; k++) {
            const uint8_t b = body[k];
            uint8_t *o = dst + (size_t)k * 4u;
            o[0] = s_unpack_table[(b >> 6) & 0x3];
            o[1] = s_unpack_table[(b >> 4) & 0x3];
            o[2] = s_unpack_table[(b >> 2) & 0x3];
            o[3] = s_unpack_table[ b       & 0x3];
        }
        if (tail) {
            const uint8_t b = body[full_bytes];
            uint8_t *o = dst + (size_t)full_bytes * 4u;
            // Emit `tail` bases from the high-order slots.
            for (uint32_t s = 0; s < tail; s++) {
                const unsigned shift = (3u - s) * 2u;
                o[s] = s_unpack_table[(b >> shift) & 0x3];
            }
        }
    }

    // Apply mask. Validate ascending positions and 0 <= pos < orig_len
    // in a single scan.
    const uint8_t *mask = src + TTIO_BP_HEADER_LEN + packed_len;
    int64_t prev_pos = -1;
    for (uint32_t k = 0; k < mask_count; k++) {
        const uint8_t *entry = mask + (size_t)k * TTIO_BP_MASK_ENTRY_LEN;
        const uint32_t pos = be_read_u32(entry);
        const uint8_t  byte = entry[4];
        if (pos >= orig_len) {
            ttio_bp_set_error(outError, 5,
                @"BASE_PACK mask position %u out of range [0, %u)",
                (unsigned)pos, (unsigned)orig_len);
            return nil;
        }
        if ((int64_t)pos <= prev_pos) {
            ttio_bp_set_error(outError, 6,
                @"BASE_PACK mask positions not strictly ascending: %u after %lld",
                (unsigned)pos, (long long)prev_pos);
            return nil;
        }
        prev_pos = (int64_t)pos;
        dst[pos] = byte;
    }

    return out;
}

// ── ObjC entry points ──────────────────────────────────────────────

NSData *TTIOBasePackEncode(NSData *data)
{
    if (data == nil) {
        return ttio_bp_encode(NULL, 0);
    }
    return ttio_bp_encode((const uint8_t *)data.bytes, (size_t)data.length);
}

NSData * _Nullable TTIOBasePackDecode(NSData *encoded,
                                      NSError * _Nullable * _Nullable error)
{
    if (encoded == nil) {
        ttio_bp_set_error(error, 1,
            @"BASE_PACK stream too short for header: 0 < %d",
            TTIO_BP_HEADER_LEN);
        return nil;
    }
    return ttio_bp_decode((const uint8_t *)encoded.bytes,
                          (size_t)encoded.length, error);
}
