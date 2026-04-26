/*
 * TTIORans.m — clean-room rANS entropy codec implementation.
 *
 * Mirrors python/src/ttio/codecs/rans.py byte-for-byte.  See the
 * header for the wire-format spec.  No htslib source consulted.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIORans.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

// ── Algorithm constants (Binding Decisions §75-§78) ─────────────────

enum {
    TTIO_RANS_M_BITS    = 12,
    TTIO_RANS_M         = 1 << TTIO_RANS_M_BITS,        // 4096
    TTIO_RANS_M_MASK    = TTIO_RANS_M - 1,
    TTIO_RANS_B_BITS    = 8,
    TTIO_RANS_HEADER    = 9,
    TTIO_RANS_FT_O0     = 1024,                          // 256 * 4 bytes
};

#define TTIO_RANS_L          ((uint64_t)1 << 23)         // 2^23
#define TTIO_RANS_X_MAX_F(f) (((TTIO_RANS_L >> TTIO_RANS_M_BITS) << TTIO_RANS_B_BITS) * (uint64_t)(f))

static NSString * const kTTIORansErrorDomain = @"TTIORansError";

// ── Error helper ────────────────────────────────────────────────────

static void ttio_rans_set_error(NSError * _Nullable * _Nullable outError,
                                NSInteger code,
                                NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void ttio_rans_set_error(NSError * _Nullable * _Nullable outError,
                                NSInteger code,
                                NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:kTTIORansErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
#if !__has_feature(objc_arc)
    [msg release];
#endif
}

// ── Big-endian byte packing ────────────────────────────────────────

static inline void be_pack_u32(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)((v >> 24) & 0xFF);
    p[1] = (uint8_t)((v >> 16) & 0xFF);
    p[2] = (uint8_t)((v >>  8) & 0xFF);
    p[3] = (uint8_t)( v        & 0xFF);
}

static inline void be_pack_u16(uint8_t *p, uint16_t v)
{
    p[0] = (uint8_t)((v >> 8) & 0xFF);
    p[1] = (uint8_t)( v       & 0xFF);
}

static inline uint32_t be_read_u32(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] <<  8) | ((uint32_t)p[3]);
}

static inline uint16_t be_read_u16(const uint8_t *p)
{
    return (uint16_t)(((uint32_t)p[0] << 8) | (uint32_t)p[1]);
}

// ── Frequency normalisation (HANDOFF §78, Python `_normalise_freqs`) ─
//
//  1. f[s] = max(1, cnt[s]*M / total)  if cnt[s] > 0 else 0
//  2. delta = M - sum(f)
//  3. delta > 0: round-robin +1 over symbols sorted by descending
//     count, ascending symbol on tie.
//  4. delta < 0: round-robin -1 over symbols sorted by ascending
//     count, ascending symbol on tie; never below 1.
//
// The comparator needs the count vector — we capture it via a
// per-call file-scope pointer (qsort is deliberately not qsort_r
// to keep the code portable).  No threading concern because each
// call to ttio_rans_normalise_freqs uses the helper synchronously
// before returning.

static const uint64_t *s_norm_cnt = NULL;

static int cmp_desc_count_asc_sym(const void *a, const void *b)
{
    int sa = *(const int *)a, sb = *(const int *)b;
    uint64_t ca = s_norm_cnt[sa], cb = s_norm_cnt[sb];
    if (ca != cb) return (ca < cb) ? 1 : -1;   // descending count
    return (sa < sb) ? -1 : (sa > sb);          // ascending symbol
}

static int cmp_asc_count_asc_sym(const void *a, const void *b)
{
    int sa = *(const int *)a, sb = *(const int *)b;
    uint64_t ca = s_norm_cnt[sa], cb = s_norm_cnt[sb];
    if (ca != cb) return (ca < cb) ? -1 : 1;    // ascending count
    return (sa < sb) ? -1 : (sa > sb);          // ascending symbol
}

// freq[256] out, cnt[256] in.  Returns 0 on success, -1 if the
// alphabet is too large to fit M (can only happen if >M distinct
// symbols are present, which is impossible for a 256-byte alphabet
// with M=4096 — kept here for defensiveness).
static int ttio_rans_normalise_freqs(const uint64_t cnt[256], uint16_t freq[256])
{
    uint64_t total = 0;
    for (int s = 0; s < 256; s++) total += cnt[s];
    if (total == 0) return -1;

    int sum = 0;
    for (int s = 0; s < 256; s++) {
        if (cnt[s] > 0) {
            uint64_t scaled = (cnt[s] * (uint64_t)TTIO_RANS_M) / total;
            uint16_t f = (scaled >= 1) ? (uint16_t)scaled : (uint16_t)1;
            freq[s] = f;
            sum += f;
        } else {
            freq[s] = 0;
        }
    }

    int delta = TTIO_RANS_M - sum;
    if (delta == 0) return 0;

    int eligible[256];
    int n = 0;
    for (int s = 0; s < 256; s++) {
        if (cnt[s] > 0) eligible[n++] = s;
    }
    if (n == 0) return -1;

    s_norm_cnt = cnt;

    if (delta > 0) {
        qsort(eligible, (size_t)n, sizeof(int), cmp_desc_count_asc_sym);
        int i = 0;
        while (delta > 0) {
            freq[eligible[i % n]] += 1;
            i++;
            delta--;
        }
    } else {
        qsort(eligible, (size_t)n, sizeof(int), cmp_asc_count_asc_sym);
        int idx = 0;
        int guard = 0;
        while (delta < 0) {
            int s = eligible[idx % n];
            if (freq[s] > 1) {
                freq[s] -= 1;
                delta++;
                guard = 0;
            } else {
                guard++;
                if (guard > n) {
                    s_norm_cnt = NULL;
                    return -1;
                }
            }
            idx++;
        }
    }

    s_norm_cnt = NULL;
    return 0;
}

// ── Cumulative + slot tables ───────────────────────────────────────

static void ttio_rans_cumulative(const uint16_t freq[256], uint16_t cum[257])
{
    uint16_t s = 0;
    for (int i = 0; i < 256; i++) {
        cum[i] = s;
        s = (uint16_t)(s + freq[i]);
    }
    cum[256] = s;
}

// Build slot -> symbol table of size M (=4096).
static void ttio_rans_slot_table(const uint16_t freq[256], uint8_t slot_to_sym[TTIO_RANS_M])
{
    int pos = 0;
    for (int s = 0; s < 256; s++) {
        uint16_t f = freq[s];
        if (f == 0) continue;
        memset(slot_to_sym + pos, s, f);
        pos += f;
    }
}

// ── Order-0 encode core ────────────────────────────────────────────
//
// Returns a freshly allocated payload buffer (caller frees) and writes
// the freq table into `freq_out[256]`.  *payload_len_out gets the
// payload size.  Returns NULL on allocation failure.
//
// Encoding mirrors the Python version exactly:
//   - empty input → flat freq (16,16,...) and payload = 4-byte BE L
//   - else: count, normalise, accumulate; encode reverse with renorm
//     before each symbol; final state prepended BE; renorm bytes
//     reversed (LIFO collected, decoder reads forward).
static uint8_t *ttio_rans_encode_o0(const uint8_t *data, size_t n,
                                    uint16_t freq_out[256],
                                    size_t *payload_len_out)
{
    if (n == 0) {
        for (int s = 0; s < 256; s++) freq_out[s] = TTIO_RANS_M / 256;
        uint8_t *payload = (uint8_t *)malloc(4);
        if (!payload) return NULL;
        be_pack_u32(payload, (uint32_t)TTIO_RANS_L);
        *payload_len_out = 4;
        return payload;
    }

    uint64_t cnt[256] = {0};
    for (size_t i = 0; i < n; i++) cnt[data[i]] += 1;

    if (ttio_rans_normalise_freqs(cnt, freq_out) != 0) return NULL;

    uint16_t cum[257];
    ttio_rans_cumulative(freq_out, cum);

    uint64_t x_max[256];
    for (int s = 0; s < 256; s++) {
        x_max[s] = TTIO_RANS_X_MAX_F(freq_out[s]);
    }

    // Worst-case renorm bytes: encoding can emit up to ~2 bytes per
    // input symbol in the limit, but in practice ≤ ceil(log2(M)/8) per
    // symbol = ≤ 1.  Use 2*n + 32 cushion for safety.
    size_t cap = n * 2 + 32;
    uint8_t *renorm = (uint8_t *)malloc(cap);
    if (!renorm) return NULL;
    size_t r = 0;

    uint64_t x = TTIO_RANS_L;
    for (size_t i = n; i-- > 0; ) {
        uint8_t s = data[i];
        uint16_t f = freq_out[s];
        uint16_t c = cum[s];
        uint64_t xm = x_max[s];
        while (x >= xm) {
            if (r + 1 > cap) {
                cap *= 2;
                uint8_t *nr = (uint8_t *)realloc(renorm, cap);
                if (!nr) { free(renorm); return NULL; }
                renorm = nr;
            }
            renorm[r++] = (uint8_t)(x & 0xFF);
            x >>= 8;
        }
        x = (x / f) * (uint64_t)TTIO_RANS_M + (x % f) + c;
    }

    size_t payload_len = 4 + r;
    uint8_t *payload = (uint8_t *)malloc(payload_len);
    if (!payload) { free(renorm); return NULL; }
    be_pack_u32(payload, (uint32_t)x);
    // Decoder reads bytes in original emit order, which is LIFO from
    // our perspective — so reverse the renorm buffer when copying.
    for (size_t i = 0; i < r; i++) {
        payload[4 + i] = renorm[r - 1 - i];
    }
    free(renorm);
    *payload_len_out = payload_len;
    return payload;
}

// ── Order-0 decode core ────────────────────────────────────────────
//
// Returns 0 on success, -1 on truncated payload.  out[orig_len] must
// be allocated by the caller.
static int ttio_rans_decode_o0(const uint8_t *payload, size_t payload_len,
                               size_t orig_len, const uint16_t freq[256],
                               uint8_t *out)
{
    if (orig_len == 0) return 0;
    if (payload_len < 4) return -1;

    uint16_t cum[257];
    ttio_rans_cumulative(freq, cum);
    uint8_t slot_to_sym[TTIO_RANS_M];
    ttio_rans_slot_table(freq, slot_to_sym);

    uint64_t x = (uint64_t)be_read_u32(payload);
    size_t pos = 4;

    for (size_t i = 0; i < orig_len; i++) {
        uint16_t slot = (uint16_t)(x & TTIO_RANS_M_MASK);
        uint8_t s = slot_to_sym[slot];
        out[i] = s;
        uint16_t f = freq[s];
        uint16_t c = cum[s];
        x = (uint64_t)f * (x >> TTIO_RANS_M_BITS) + slot - c;
        while (x < TTIO_RANS_L) {
            if (pos >= payload_len) return -1;
            x = (x << 8) | payload[pos++];
        }
    }
    return 0;
}

// ── Order-1 encode core ────────────────────────────────────────────
//
// freqs_out is a 256x256 uint16 row-major flat array (caller-owned);
// every row sums to either 0 (no transitions seen) or M.
static uint8_t *ttio_rans_encode_o1(const uint8_t *data, size_t n,
                                    uint16_t *freqs_out,
                                    size_t *payload_len_out)
{
    memset(freqs_out, 0, 256 * 256 * sizeof(uint16_t));

    if (n == 0) {
        uint8_t *payload = (uint8_t *)malloc(4);
        if (!payload) return NULL;
        be_pack_u32(payload, (uint32_t)TTIO_RANS_L);
        *payload_len_out = 4;
        return payload;
    }

    // Build per-context counts.
    uint64_t (*counts)[256] = (uint64_t (*)[256])calloc(256, sizeof(uint64_t[256]));
    if (!counts) return NULL;
    {
        uint8_t prev = 0;
        for (size_t i = 0; i < n; i++) {
            counts[prev][data[i]] += 1;
            prev = data[i];
        }
    }

    // Normalise each non-empty row.
    for (int ctx = 0; ctx < 256; ctx++) {
        uint64_t total = 0;
        for (int s = 0; s < 256; s++) total += counts[ctx][s];
        if (total == 0) continue;
        uint16_t row[256];
        if (ttio_rans_normalise_freqs(counts[ctx], row) != 0) {
            free(counts);
            return NULL;
        }
        memcpy(&freqs_out[ctx * 256], row, sizeof(row));
    }
    free(counts);

    // Pre-compute cumulative + x_max per non-empty row.
    static uint16_t cums[256][257];
    static uint64_t xmaxes[256][256];
    char nonempty[256] = {0};
    for (int ctx = 0; ctx < 256; ctx++) {
        const uint16_t *row = &freqs_out[ctx * 256];
        int sum = 0;
        for (int s = 0; s < 256; s++) sum += row[s];
        if (sum == 0) continue;
        nonempty[ctx] = 1;
        ttio_rans_cumulative(row, cums[ctx]);
        for (int s = 0; s < 256; s++) {
            xmaxes[ctx][s] = TTIO_RANS_X_MAX_F(row[s]);
        }
    }

    size_t cap = n * 2 + 32;
    uint8_t *renorm = (uint8_t *)malloc(cap);
    if (!renorm) return NULL;
    size_t r = 0;

    uint64_t x = TTIO_RANS_L;
    for (size_t i = n; i-- > 0; ) {
        uint8_t s = data[i];
        uint8_t ctx = (i > 0) ? data[i - 1] : 0;
        uint16_t f = freqs_out[ctx * 256 + s];
        // f cannot legitimately be zero — if it is, the freqs table
        // is inconsistent with the input.  Bail out.
        if (f == 0 || !nonempty[ctx]) { free(renorm); return NULL; }
        uint16_t c = cums[ctx][s];
        uint64_t xm = xmaxes[ctx][s];
        while (x >= xm) {
            if (r + 1 > cap) {
                cap *= 2;
                uint8_t *nr = (uint8_t *)realloc(renorm, cap);
                if (!nr) { free(renorm); return NULL; }
                renorm = nr;
            }
            renorm[r++] = (uint8_t)(x & 0xFF);
            x >>= 8;
        }
        x = (x / f) * (uint64_t)TTIO_RANS_M + (x % f) + c;
    }

    size_t payload_len = 4 + r;
    uint8_t *payload = (uint8_t *)malloc(payload_len);
    if (!payload) { free(renorm); return NULL; }
    be_pack_u32(payload, (uint32_t)x);
    for (size_t i = 0; i < r; i++) payload[4 + i] = renorm[r - 1 - i];
    free(renorm);
    *payload_len_out = payload_len;
    return payload;
}

// ── Order-1 decode core ────────────────────────────────────────────

static int ttio_rans_decode_o1(const uint8_t *payload, size_t payload_len,
                               size_t orig_len, const uint16_t *freqs,
                               uint8_t *out)
{
    if (orig_len == 0) return 0;
    if (payload_len < 4) return -1;

    static uint16_t cums[256][257];
    static uint8_t  slot_tables[256][TTIO_RANS_M];
    char nonempty[256] = {0};
    for (int ctx = 0; ctx < 256; ctx++) {
        const uint16_t *row = &freqs[ctx * 256];
        int sum = 0;
        for (int s = 0; s < 256; s++) sum += row[s];
        if (sum == 0) continue;
        nonempty[ctx] = 1;
        ttio_rans_cumulative(row, cums[ctx]);
        ttio_rans_slot_table(row, slot_tables[ctx]);
    }

    uint64_t x = (uint64_t)be_read_u32(payload);
    size_t pos = 4;
    uint8_t prev = 0;
    for (size_t i = 0; i < orig_len; i++) {
        if (!nonempty[prev]) return -1;
        uint16_t slot = (uint16_t)(x & TTIO_RANS_M_MASK);
        uint8_t s = slot_tables[prev][slot];
        out[i] = s;
        uint16_t f = freqs[prev * 256 + s];
        uint16_t c = cums[prev][s];
        x = (uint64_t)f * (x >> TTIO_RANS_M_BITS) + slot - c;
        while (x < TTIO_RANS_L) {
            if (pos >= payload_len) return -1;
            x = (x << 8) | payload[pos++];
        }
        prev = s;
    }
    return 0;
}

// ── Frequency table (de)serialisation ──────────────────────────────

static void ttio_rans_serialise_o0(const uint16_t freq[256], uint8_t out[TTIO_RANS_FT_O0])
{
    for (int s = 0; s < 256; s++) {
        be_pack_u32(&out[s * 4], (uint32_t)freq[s]);
    }
}

static int ttio_rans_deserialise_o0(const uint8_t *buf, size_t n, size_t off,
                                    uint16_t freq[256], size_t *new_off)
{
    if (off + TTIO_RANS_FT_O0 > n) return -1;
    uint32_t sum = 0;
    for (int s = 0; s < 256; s++) {
        uint32_t v = be_read_u32(&buf[off + s * 4]);
        if (v > TTIO_RANS_M) return -1;
        freq[s] = (uint16_t)v;
        sum += v;
    }
    if (sum != TTIO_RANS_M) return -1;
    *new_off = off + TTIO_RANS_FT_O0;
    return 0;
}

// Returns serialised buffer (caller frees) and size in *out_len.
static uint8_t *ttio_rans_serialise_o1(const uint16_t *freqs, size_t *out_len)
{
    size_t cap = 0;
    for (int ctx = 0; ctx < 256; ctx++) {
        int n_nz = 0;
        for (int s = 0; s < 256; s++) if (freqs[ctx * 256 + s] > 0) n_nz++;
        cap += 2 + (size_t)n_nz * 3;
    }
    uint8_t *out = (uint8_t *)malloc(cap);
    if (!out) return NULL;
    size_t off = 0;
    for (int ctx = 0; ctx < 256; ctx++) {
        int n_nz = 0;
        for (int s = 0; s < 256; s++) if (freqs[ctx * 256 + s] > 0) n_nz++;
        be_pack_u16(&out[off], (uint16_t)n_nz);
        off += 2;
        for (int s = 0; s < 256; s++) {
            uint16_t f = freqs[ctx * 256 + s];
            if (f == 0) continue;
            out[off++] = (uint8_t)s;
            be_pack_u16(&out[off], f);
            off += 2;
        }
    }
    *out_len = cap;
    return out;
}

static int ttio_rans_deserialise_o1(const uint8_t *buf, size_t n, size_t off,
                                    uint16_t *freqs, size_t *new_off)
{
    memset(freqs, 0, 256 * 256 * sizeof(uint16_t));
    for (int ctx = 0; ctx < 256; ctx++) {
        if (off + 2 > n) return -1;
        uint16_t n_nz = be_read_u16(&buf[off]);
        off += 2;
        if (n_nz == 0) continue;
        if (n_nz > 256) return -1;
        uint32_t row_sum = 0;
        for (int e = 0; e < n_nz; e++) {
            if (off + 3 > n) return -1;
            uint8_t s = buf[off];
            uint16_t f = be_read_u16(&buf[off + 1]);
            if (f == 0) return -1;
            freqs[ctx * 256 + s] = f;
            row_sum += f;
            off += 3;
        }
        if (row_sum != TTIO_RANS_M) return -1;
    }
    *new_off = off;
    return 0;
}

// ── ObjC entry points ──────────────────────────────────────────────

NSData *TTIORansEncode(NSData *data, int order)
{
    if (order != 0 && order != 1) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIORansEncode: unsupported order %d", order];
    }
    if (data == nil) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIORansEncode: data must not be nil"];
    }
    NSUInteger n = data.length;
    if (n > 0xFFFFFFFFu) {
        [NSException raise:NSInvalidArgumentException
                    format:@"TTIORansEncode: input exceeds 4 GiB header limit"];
    }
    const uint8_t *bytes = (const uint8_t *)data.bytes;

    NSMutableData *out = [NSMutableData data];
    uint8_t header[TTIO_RANS_HEADER];
    header[0] = (uint8_t)order;
    be_pack_u32(&header[1], (uint32_t)n);
    // payload_length filled in after we encode.

    if (order == 0) {
        uint16_t freq[256];
        size_t payload_len = 0;
        uint8_t *payload = ttio_rans_encode_o0(bytes, (size_t)n, freq, &payload_len);
        if (!payload) {
            [NSException raise:NSInternalInconsistencyException
                        format:@"TTIORansEncode: order-0 encode failed"];
        }
        be_pack_u32(&header[5], (uint32_t)payload_len);
        [out appendBytes:header length:TTIO_RANS_HEADER];
        uint8_t ft[TTIO_RANS_FT_O0];
        ttio_rans_serialise_o0(freq, ft);
        [out appendBytes:ft length:TTIO_RANS_FT_O0];
        [out appendBytes:payload length:payload_len];
        free(payload);
    } else {
        uint16_t *freqs = (uint16_t *)calloc(256 * 256, sizeof(uint16_t));
        if (!freqs) {
            [NSException raise:NSInternalInconsistencyException
                        format:@"TTIORansEncode: alloc failed"];
        }
        size_t payload_len = 0;
        uint8_t *payload = ttio_rans_encode_o1(bytes, (size_t)n, freqs, &payload_len);
        if (!payload) {
            free(freqs);
            [NSException raise:NSInternalInconsistencyException
                        format:@"TTIORansEncode: order-1 encode failed"];
        }
        size_t ft_len = 0;
        uint8_t *ft = ttio_rans_serialise_o1(freqs, &ft_len);
        free(freqs);
        if (!ft) {
            free(payload);
            [NSException raise:NSInternalInconsistencyException
                        format:@"TTIORansEncode: alloc failed"];
        }
        be_pack_u32(&header[5], (uint32_t)payload_len);
        [out appendBytes:header length:TTIO_RANS_HEADER];
        [out appendBytes:ft length:ft_len];
        [out appendBytes:payload length:payload_len];
        free(ft);
        free(payload);
    }
    return out;
}

NSData *TTIORansDecode(NSData *encoded, NSError * _Nullable * _Nullable error)
{
    if (encoded == nil) {
        ttio_rans_set_error(error, 1, @"TTIORansDecode: input must not be nil");
        return nil;
    }
    NSUInteger n = encoded.length;
    if (n < TTIO_RANS_HEADER) {
        ttio_rans_set_error(error, 2,
            @"rANS: stream length %lu shorter than header (%d)",
            (unsigned long)n, TTIO_RANS_HEADER);
        return nil;
    }
    const uint8_t *buf = (const uint8_t *)encoded.bytes;
    int order = buf[0];
    if (order != 0 && order != 1) {
        ttio_rans_set_error(error, 3, @"rANS: unsupported order byte 0x%02x", order);
        return nil;
    }
    uint32_t orig_len = be_read_u32(&buf[1]);
    uint32_t payload_len = be_read_u32(&buf[5]);
    size_t off = TTIO_RANS_HEADER;

    if (order == 0) {
        uint16_t freq[256];
        if (ttio_rans_deserialise_o0(buf, n, off, freq, &off) != 0) {
            ttio_rans_set_error(error, 4,
                @"rANS: order-0 frequency table truncated or sum != M");
            return nil;
        }
        if ((uint64_t)off + payload_len != n) {
            ttio_rans_set_error(error, 5,
                @"rANS: declared total length %llu != actual %lu",
                (unsigned long long)((uint64_t)off + payload_len),
                (unsigned long)n);
            return nil;
        }
        NSMutableData *out = [NSMutableData dataWithLength:orig_len];
        if (ttio_rans_decode_o0(buf + off, payload_len, orig_len, freq,
                                (uint8_t *)out.mutableBytes) != 0) {
            ttio_rans_set_error(error, 6,
                @"rANS: order-0 payload truncated during renormalisation");
            return nil;
        }
        return out;
    } else {
        uint16_t *freqs = (uint16_t *)calloc(256 * 256, sizeof(uint16_t));
        if (!freqs) {
            ttio_rans_set_error(error, 7, @"rANS: alloc failed");
            return nil;
        }
        if (ttio_rans_deserialise_o1(buf, n, off, freqs, &off) != 0) {
            free(freqs);
            ttio_rans_set_error(error, 8,
                @"rANS: order-1 frequency table malformed (truncated, "
                @"row sum != M, or zero-freq nonzero entry)");
            return nil;
        }
        if ((uint64_t)off + payload_len != n) {
            free(freqs);
            ttio_rans_set_error(error, 9,
                @"rANS: declared total length %llu != actual %lu",
                (unsigned long long)((uint64_t)off + payload_len),
                (unsigned long)n);
            return nil;
        }
        NSMutableData *out = [NSMutableData dataWithLength:orig_len];
        int rc = ttio_rans_decode_o1(buf + off, payload_len, orig_len, freqs,
                                     (uint8_t *)out.mutableBytes);
        free(freqs);
        if (rc != 0) {
            ttio_rans_set_error(error, 10,
                @"rANS: order-1 payload truncated or referenced empty context");
            return nil;
        }
        return out;
    }
}
