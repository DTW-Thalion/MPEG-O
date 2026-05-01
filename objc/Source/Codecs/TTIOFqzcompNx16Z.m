/*
 * TTIOFqzcompNx16Z.m — CRAM-mimic FQZCOMP_NX16 (rANS-Nx16) codec.
 *
 * Mirrors python/src/ttio/codecs/fqzcomp_nx16_z.py byte-for-byte.
 * See the header for the wire format spec.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIOFqzcompNx16Z.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <zlib.h>

// ── Optional native rANS fast path (Task 17, Phase B) ────────────────
// libttio_rans (native/) ships an SIMD-dispatched rANS-Nx16 kernel. The
// build wires it in only when present (see Source/GNUmakefile.preamble).
// We probe with __has_include so this translation unit still compiles
// when the header is absent; +backendName then returns "pure-objc".
//
// V2 dispatch (Task 23): when the encode-options dictionary specifies
// "preferNative":@YES (or env var TTIO_M94Z_USE_NATIVE is set), encode
// emits a V2 wire-format stream (version byte = 2) whose body is
// produced by ttio_rans_encode_block. V1 streams remain the default
// and round-trip via the existing pure-ObjC path. V2 decode is also
// pure-ObjC because contexts in M94.Z are derived from previously-
// decoded symbols, which the C library's pre-computed-contexts API
// cannot supply (option E).
#if __has_include("ttio_rans.h")
#  include "ttio_rans.h"
#  define TTIO_HAS_NATIVE_RANS 1
#else
#  define TTIO_HAS_NATIVE_RANS 0
#endif

NSString * const TTIOFqzcompNx16ZErrorDomain = @"TTIOFqzcompNx16ZError";

// ── Algorithm constants (per spec §1) ──────────────────────────────

enum {
    kZ_L            = 1 << 15,            // 32 768
    kZ_B_BITS       = 16,
    kZ_B_MASK       = 0xFFFF,
    kZ_T            = 1 << 12,            // 4096
    kZ_T_BITS       = 12,
    kZ_T_MASK       = (1 << 12) - 1,
    kZ_NUM_STREAMS  = 4,
    kZ_X_MAX_PREFACTOR = (kZ_L >> kZ_T_BITS) << kZ_B_BITS,  // 524288 = 2^19

    // Default context params (spec §4.3).
    kZ_DEFAULT_QBITS = 12,
    kZ_DEFAULT_PBITS = 2,
    kZ_DEFAULT_DBITS = 0,
    kZ_DEFAULT_SLOC  = 14,

    // Wire format constants.
    kZ_MAGIC_LEN              = 4,
    kZ_VERSION                = 1,
    kZ_VERSION_V2_NATIVE      = 2,  // V2 body produced by libttio_rans
    kZ_CONTEXT_PARAMS_SIZE    = 8,
    kZ_HEADER_FIXED_PREFIX    = 4 + 1 + 1 + 8 + 4 + 4 + 8 + 4,  // 34
    kZ_STATE_INIT_SIZE        = 16,
    kZ_TRAILER_SIZE           = 16,
};

static const uint8_t kZ_MAGIC[4] = { 'M', '9', '4', 'Z' };

// ── LE byte helpers ───────────────────────────────────────────────

static inline void le_pack_u16(uint8_t *p, uint16_t v) {
    p[0] = (uint8_t)( v        & 0xFF);
    p[1] = (uint8_t)((v >> 8)  & 0xFF);
}
static inline void le_pack_u32(uint8_t *p, uint32_t v) {
    p[0] = (uint8_t)( v        & 0xFF);
    p[1] = (uint8_t)((v >> 8)  & 0xFF);
    p[2] = (uint8_t)((v >> 16) & 0xFF);
    p[3] = (uint8_t)((v >> 24) & 0xFF);
}
static inline void le_pack_u64(uint8_t *p, uint64_t v) {
    for (int i = 0; i < 8; i++) p[i] = (uint8_t)((v >> (i * 8)) & 0xFF);
}
static inline uint16_t le_read_u16(const uint8_t *p) {
    return (uint16_t)((uint16_t)p[0] | ((uint16_t)p[1] << 8));
}
static inline uint32_t le_read_u32(const uint8_t *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) |
           ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static inline uint64_t le_read_u64(const uint8_t *p) {
    uint64_t v = 0;
    for (int i = 0; i < 8; i++) v |= (uint64_t)p[i] << (i * 8);
    return v;
}

// ── Error helper ──────────────────────────────────────────────────

static void z_set_error(NSError * _Nullable * _Nullable outError,
                          NSInteger code,
                          NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void z_set_error(NSError * _Nullable * _Nullable outError,
                          NSInteger code,
                          NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:TTIOFqzcompNx16ZErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// ── Position bucket (per spec §4.2) ───────────────────────────────

static inline uint32_t z_pos_bucket(int32_t position, int32_t read_length, int32_t pbits)
{
    if (pbits <= 0) return 0;
    int32_t n_buckets = 1 << pbits;
    if (read_length <= 0 || position <= 0) return 0;
    if (position >= read_length) return (uint32_t)(n_buckets - 1);
    int32_t b = (position * n_buckets) / read_length;
    if (b > n_buckets - 1) b = n_buckets - 1;
    return (uint32_t)b;
}

// ── Bit-pack context (per spec §4.2) ──────────────────────────────

static inline uint32_t z_context(uint32_t prev_q, uint32_t pos_bucket,
                                  uint32_t revcomp,
                                  int32_t qbits, int32_t pbits, int32_t sloc)
{
    uint32_t qmask = ((uint32_t)1 << qbits) - 1;
    uint32_t pmask = ((uint32_t)1 << pbits) - 1;
    uint32_t smask = ((uint32_t)1 << sloc) - 1;
    uint32_t ctx = prev_q & qmask;
    ctx |= (pos_bucket & pmask) << qbits;
    ctx |= (revcomp & 1u) << (qbits + pbits);
    return ctx & smask;
}

// ── Frequency-table normalisation (per spec §3.3) ────────────────
//
// Mirrors python/src/ttio/codecs/fqzcomp_nx16_z.py::normalise_to_total
// byte-exactly. Algorithm:
//   1. If sum is 0, set freq[0] = T (degenerate).
//   2. For each c > 0: scaled = (c*T + s/2) // s; floor at 1.
//   3. delta > 0: round-robin +1 over present symbols sorted by
//      (-freq, sym ascending).
//   4. delta < 0: repeatedly decrement the largest freq among those
//      still > 1, ties by smallest sym.
//
// Returns 0 on success, -1 on the rare "cannot reduce below floor=1"
// path.

static int z_normalise_to_total(const int32_t raw_count[256],
                                 uint16_t freq_out[256])
{
    int64_t s = 0;
    for (int i = 0; i < 256; i++) {
        s += raw_count[i];
        freq_out[i] = 0;
    }
    if (s == 0) {
        freq_out[0] = (uint16_t)kZ_T;
        return 0;
    }

    int32_t fsum = 0;
    for (int i = 0; i < 256; i++) {
        if (raw_count[i] == 0) continue;
        int64_t numerator = (int64_t)raw_count[i] * (int64_t)kZ_T + (s >> 1);
        int32_t scaled = (int32_t)(numerator / s);
        if (scaled < 1) scaled = 1;
        freq_out[i] = (uint16_t)scaled;
        fsum += scaled;
    }

    int32_t delta = (int32_t)kZ_T - fsum;
    if (delta == 0) return 0;

    if (delta > 0) {
        // Build ordered list of present symbols sorted by
        // (-freq, sym ascending). Insertion-sort, n <= 256.
        int32_t order_buf[256];
        int32_t n = 0;
        for (int i = 0; i < 256; i++) {
            if (raw_count[i] > 0) order_buf[n++] = i;
        }
        if (n == 0) {
            freq_out[0] = (uint16_t)kZ_T;
            return 0;
        }
        for (int32_t i = 1; i < n; i++) {
            int32_t tmp_i = order_buf[i];
            int32_t tmp_f = (int32_t)freq_out[tmp_i];
            int32_t j = i - 1;
            while (j >= 0) {
                int32_t fp = (int32_t)freq_out[order_buf[j]];
                if (fp < tmp_f || (fp == tmp_f && order_buf[j] > tmp_i)) {
                    order_buf[j + 1] = order_buf[j];
                    j--;
                } else {
                    break;
                }
            }
            order_buf[j + 1] = tmp_i;
        }
        int32_t k = 0;
        while (delta > 0) {
            freq_out[order_buf[k % n]] = (uint16_t)(freq_out[order_buf[k % n]] + 1);
            k++;
            delta--;
        }
        return 0;
    }

    // delta < 0: decrement largest while > 1.
    int32_t deficit = -delta;
    while (deficit > 0) {
        int32_t best_i = -1;
        int32_t best_v = -1;
        for (int i = 0; i < 256; i++) {
            if (freq_out[i] > 1 && (int32_t)freq_out[i] > best_v) {
                best_v = (int32_t)freq_out[i];
                best_i = i;
            }
        }
        if (best_i < 0) return -1;
        freq_out[best_i] = (uint16_t)(freq_out[best_i] - 1);
        deficit--;
    }
    return 0;
}

// ── Build the per-symbol context sequence (encoder pass 1) ───────

static void z_build_context_seq(const uint8_t *qualities, int32_t n_qualities,
                                  int32_t n_padded,
                                  const int32_t *read_lengths, int32_t n_reads,
                                  const int8_t *revcomp_flags,
                                  int32_t qbits, int32_t pbits, int32_t sloc,
                                  uint32_t *contexts_out)
{
    uint32_t pad_ctx = z_context(0, 0, 0, qbits, pbits, sloc);
    int32_t read_idx = 0;
    int32_t pos_in_read = 0;
    int32_t cur_read_len = (n_reads > 0) ? read_lengths[0] : 0;
    uint32_t cur_revcomp = (n_reads > 0) ? (uint32_t)revcomp_flags[0] : 0;
    int32_t cumulative_read_end = cur_read_len;
    uint32_t prev_q = 0;
    int32_t shift = qbits / 3;
    if (shift < 1) shift = 1;
    uint32_t qmask_local = ((uint32_t)1 << qbits) - 1;
    uint32_t shift_mask = ((uint32_t)1 << shift) - 1;

    for (int32_t i = 0; i < n_padded; i++) {
        if (i < n_qualities) {
            if (i >= cumulative_read_end && read_idx < n_reads - 1) {
                read_idx++;
                pos_in_read = 0;
                cur_read_len = read_lengths[read_idx];
                cur_revcomp = (uint32_t)revcomp_flags[read_idx];
                cumulative_read_end += cur_read_len;
                prev_q = 0;
            }
            uint32_t pb = z_pos_bucket(pos_in_read, cur_read_len, pbits);
            contexts_out[i] = z_context(prev_q, pb, cur_revcomp & 1,
                                          qbits, pbits, sloc);
            uint8_t sym = qualities[i];
            prev_q = ((prev_q << shift) | ((uint32_t)sym & shift_mask))
                       & qmask_local;
            pos_in_read++;
        } else {
            contexts_out[i] = pad_ctx;
        }
    }
}

// ── Read-length sidecar (deflate-compressed uint32 LE array) ─────

static NSData *z_encode_read_lengths(NSArray<NSNumber *> *readLengths)
{
    NSUInteger n = readLengths.count;
    if (n == 0) {
        // zlib.compress(b"")
        Bytef out_buf[64];
        uLongf out_len = sizeof(out_buf);
        int rc = compress2(out_buf, &out_len, (const Bytef *)"", 0, 6);
        if (rc != Z_OK) return [NSData data];
        return [NSData dataWithBytes:out_buf length:(NSUInteger)out_len];
    }
    NSMutableData *raw = [NSMutableData dataWithLength:n * 4];
    uint8_t *p = (uint8_t *)raw.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        uint32_t v = (uint32_t)[readLengths[i] unsignedLongLongValue];
        le_pack_u32(p + 4 * i, v);
    }
    uLongf cap = compressBound((uLong)raw.length);
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)cap];
    uLongf out_len = cap;
    int rc = compress2((Bytef *)out.mutableBytes, &out_len,
                        (const Bytef *)raw.bytes, (uLong)raw.length, 6);
    if (rc != Z_OK) return nil;
    [out setLength:(NSUInteger)out_len];
    return out;
}

// Returns nil + sets error on failure. Caller owns the returned array.
static NSArray<NSNumber *> *z_decode_read_lengths(NSData *encoded,
                                                    uint32_t numReads,
                                                    NSError **error)
{
    if (numReads == 0) {
        // Verify decompression yields empty.
        if (encoded.length == 0) return @[];
        // Decompress and ensure raw is empty.
        Bytef tmp[8];
        uLongf tmp_len = sizeof(tmp);
        int rc = uncompress(tmp, &tmp_len, (const Bytef *)encoded.bytes,
                              (uLong)encoded.length);
        if (rc != Z_OK || tmp_len != 0) {
            z_set_error(error, 60, @"M94Z: read_length_table non-empty but num_reads=0");
            return nil;
        }
        return @[];
    }
    uLongf raw_len = (uLongf)numReads * 4;
    NSMutableData *raw = [NSMutableData dataWithLength:(NSUInteger)raw_len];
    int rc = uncompress((Bytef *)raw.mutableBytes, &raw_len,
                          (const Bytef *)encoded.bytes,
                          (uLong)encoded.length);
    if (rc != Z_OK) {
        z_set_error(error, 61, @"M94Z: rlt deflate inflate failed (rc=%d)", rc);
        return nil;
    }
    if (raw_len != (uLongf)numReads * 4) {
        z_set_error(error, 62,
            @"M94Z: rlt raw length %lu != %lu",
            (unsigned long)raw_len, (unsigned long)numReads * 4);
        return nil;
    }
    const uint8_t *p = (const uint8_t *)raw.bytes;
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:numReads];
    for (uint32_t i = 0; i < numReads; i++) {
        uint32_t v = le_read_u32(p + 4 * i);
        [out addObject:@(v)];
    }
    return out;
}

// ── Freq tables sidecar (deflate-compressed sparse map) ──────────

static NSData *z_serialize_freq_tables(const uint32_t *active_ctxs,
                                         size_t n_active,
                                         uint16_t * const *freq_tables,
                                         int32_t sloc)
{
    NSUInteger raw_len = 4 + n_active * (4 + 256 * 2);
    NSMutableData *raw = [NSMutableData dataWithLength:raw_len];
    uint8_t *p = (uint8_t *)raw.mutableBytes;
    le_pack_u32(p, (uint32_t)n_active);
    p += 4;
    uint32_t smask = ((uint32_t)1 << sloc) - 1;
    for (size_t i = 0; i < n_active; i++) {
        uint32_t ctx = active_ctxs[i];
        if (ctx & ~smask) {
            // Should be impossible — defensive.
            return nil;
        }
        le_pack_u32(p, ctx);
        p += 4;
        const uint16_t *freq = freq_tables[i];
        for (int k = 0; k < 256; k++) {
            le_pack_u16(p, freq[k]);
            p += 2;
        }
    }
    uLongf cap = compressBound((uLong)raw.length);
    NSMutableData *out = [NSMutableData dataWithLength:(NSUInteger)cap];
    uLongf out_len = cap;
    int rc = compress2((Bytef *)out.mutableBytes, &out_len,
                        (const Bytef *)raw.bytes, (uLong)raw.length, 6);
    if (rc != Z_OK) return nil;
    [out setLength:(NSUInteger)out_len];
    return out;
}

// On success returns 0 and writes:
//   *out_n_active     count
//   *out_active_ctxs  malloc'd uint32 array (caller frees)
//   *out_freq_tables  malloc'd uint16* array of malloc'd uint16[256]
//                     (caller frees both levels)
// On failure returns non-zero and sets error.
static int z_deserialize_freq_tables(NSData *encoded,
                                       size_t *out_n_active,
                                       uint32_t **out_active_ctxs,
                                       uint16_t ***out_freq_tables,
                                       NSError **error)
{
    *out_n_active = 0;
    *out_active_ctxs = NULL;
    *out_freq_tables = NULL;
    // Inflate. We don't know the raw size up-front; loop with growing buffer.
    // The blob format is bounded: max raw size = 4 + (1 << sloc) * 516 bytes.
    // For the default sloc=14, that's ~8.4 MB. We grow doubling.
    uLongf cap = (uLongf)encoded.length * 4;
    if (cap < 4096) cap = 4096;
    NSMutableData *raw = nil;
    int rc;
    for (int attempts = 0; attempts < 30; attempts++) {
        raw = [NSMutableData dataWithLength:(NSUInteger)cap];
        uLongf out_len = cap;
        rc = uncompress((Bytef *)raw.mutableBytes, &out_len,
                          (const Bytef *)encoded.bytes,
                          (uLong)encoded.length);
        if (rc == Z_OK) {
            [raw setLength:(NSUInteger)out_len];
            break;
        }
        if (rc == Z_BUF_ERROR) {
            cap *= 2;
            continue;
        }
        z_set_error(error, 70, @"M94Z: freq_tables inflate failed (rc=%d)", rc);
        return -1;
    }
    if (rc != Z_OK) {
        z_set_error(error, 71, @"M94Z: freq_tables inflate buffer too small");
        return -1;
    }
    if (raw.length < 4) {
        z_set_error(error, 72, @"M94Z: freq_tables blob too short");
        return -1;
    }
    const uint8_t *rp = (const uint8_t *)raw.bytes;
    uint32_t n_active = le_read_u32(rp);
    NSUInteger expected = 4 + (NSUInteger)n_active * (4 + 256 * 2);
    if (raw.length != expected) {
        z_set_error(error, 73,
            @"M94Z: freq_tables raw len %lu != expected %lu",
            (unsigned long)raw.length, (unsigned long)expected);
        return -1;
    }
    uint32_t *active_ctxs = (uint32_t *)malloc(sizeof(uint32_t) * (n_active ?: 1));
    uint16_t **freq_tables = (uint16_t **)calloc(n_active ?: 1, sizeof(uint16_t *));
    if (!active_ctxs || !freq_tables) {
        free(active_ctxs); free(freq_tables);
        z_set_error(error, 74, @"M94Z: freq_tables alloc failed");
        return -1;
    }
    NSUInteger cursor = 4;
    for (uint32_t i = 0; i < n_active; i++) {
        active_ctxs[i] = le_read_u32(rp + cursor);
        cursor += 4;
        uint16_t *ft = (uint16_t *)malloc(sizeof(uint16_t) * 256);
        if (!ft) {
            for (uint32_t j = 0; j < i; j++) free(freq_tables[j]);
            free(freq_tables); free(active_ctxs);
            z_set_error(error, 75, @"M94Z: freq table alloc failed");
            return -1;
        }
        for (int k = 0; k < 256; k++) {
            ft[k] = le_read_u16(rp + cursor);
            cursor += 2;
        }
        freq_tables[i] = ft;
    }
    *out_n_active = n_active;
    *out_active_ctxs = active_ctxs;
    *out_freq_tables = freq_tables;
    return 0;
}

// ── Encoder pipeline ──────────────────────────────────────────────
//
// Returns 0 on success; nonzero on failure (and sets error).
// On success:
//   *out_streams  malloc'd 4 byte buffers (caller frees both levels)
//   *out_stream_lens  uint32 lengths
//   out_state_init[4], out_state_final[4]
//   *out_active_ctxs (sorted ascending), *out_freq_tables, *out_n_active
//     — caller responsible for freeing.

static int z_encode_full(const uint8_t *qualities, int32_t n_qualities,
                           const int32_t *read_lengths, int32_t n_reads,
                           const int8_t *revcomp_flags,
                           int32_t qbits, int32_t pbits, int32_t sloc,
                           uint8_t ***out_streams, uint32_t out_stream_lens[4],
                           uint32_t out_state_init[4],
                           uint32_t out_state_final[4],
                           uint32_t **out_active_ctxs,
                           uint16_t ***out_freq_tables,
                           size_t *out_n_active,
                           NSError **error)
{
    int rc = -1;
    int32_t pad_count = (-n_qualities) & 3;
    int32_t n_padded = n_qualities + pad_count;
    int32_t n_contexts = 1 << sloc;

    int32_t **ctx_counts = (int32_t **)calloc(n_contexts, sizeof(int32_t *));
    uint16_t **ctx_freq  = (uint16_t **)calloc(n_contexts, sizeof(uint16_t *));
    uint32_t *ctx_cum_storage = NULL; // built per-context as needed
    uint32_t **ctx_cum  = (uint32_t **)calloc(n_contexts, sizeof(uint32_t *));
    uint32_t *contexts  = (uint32_t *)malloc(sizeof(uint32_t) *
                                                ((n_padded > 0) ? n_padded : 1));
    uint8_t  *symbols   = (uint8_t  *)malloc((n_padded > 0) ? n_padded : 1);
    uint16_t *lane_chunks[4] = { NULL, NULL, NULL, NULL };
    uint8_t  *lane_bytes[4]  = { NULL, NULL, NULL, NULL };
    uint8_t  **streams_out = NULL;

    if (!ctx_counts || !ctx_freq || !ctx_cum || !contexts || !symbols) {
        z_set_error(error, 80, @"M94Z encoder: alloc failed");
        goto cleanup;
    }
    (void)ctx_cum_storage;

    if (n_padded > 0) {
        memset(symbols, 0, n_padded);
        for (int32_t i = 0; i < n_qualities; i++) symbols[i] = qualities[i];
    }

    // Build context sequence.
    z_build_context_seq(qualities, n_qualities, n_padded,
                          read_lengths, n_reads, revcomp_flags,
                          qbits, pbits, sloc, contexts);

    // Pass 1: gather per-context counts.
    for (int32_t i = 0; i < n_padded; i++) {
        uint32_t ctx = contexts[i];
        if (ctx_counts[ctx] == NULL) {
            ctx_counts[ctx] = (int32_t *)calloc(256, sizeof(int32_t));
            if (!ctx_counts[ctx]) {
                z_set_error(error, 81, @"M94Z encoder: per-context count alloc failed");
                goto cleanup;
            }
        }
        ctx_counts[ctx][symbols[i]]++;
    }

    // Normalise each active context.
    for (int32_t ctx = 0; ctx < n_contexts; ctx++) {
        if (ctx_counts[ctx] == NULL) continue;
        ctx_freq[ctx] = (uint16_t *)malloc(sizeof(uint16_t) * 256);
        ctx_cum[ctx]  = (uint32_t *)malloc(sizeof(uint32_t) * 257);
        if (!ctx_freq[ctx] || !ctx_cum[ctx]) {
            z_set_error(error, 82, @"M94Z encoder: per-ctx freq/cum alloc failed");
            goto cleanup;
        }
        if (z_normalise_to_total(ctx_counts[ctx], ctx_freq[ctx]) != 0) {
            z_set_error(error, 83,
                @"M94Z encoder: normalise_to_total cannot reduce below floor=1");
            goto cleanup;
        }
        ctx_cum[ctx][0] = 0;
        for (int k = 0; k < 256; k++) {
            ctx_cum[ctx][k + 1] = ctx_cum[ctx][k] + (uint32_t)ctx_freq[ctx][k];
        }
    }

    // Pass 2: rANS encode reverse.
    int32_t cap_per_lane = (n_padded / 4 + 16) * 2 + 32;
    if (cap_per_lane < 32) cap_per_lane = 32;
    for (int s = 0; s < 4; s++) {
        lane_chunks[s] = (uint16_t *)malloc(sizeof(uint16_t) * cap_per_lane);
        if (!lane_chunks[s]) {
            z_set_error(error, 84, @"M94Z encoder: lane chunk alloc failed");
            goto cleanup;
        }
    }
    int32_t lane_n[4] = { 0, 0, 0, 0 };
    uint32_t state[4] = { kZ_L, kZ_L, kZ_L, kZ_L };

    for (int32_t i = n_padded - 1; i >= 0; i--) {
        int s_idx = i & 3;
        uint32_t ctx = contexts[i];
        uint8_t sym = symbols[i];
        uint32_t f = (uint32_t)ctx_freq[ctx][sym];
        uint32_t c = ctx_cum[ctx][sym];
        // f > 0 always: pass 1 counted this symbol.
        uint32_t x = state[s_idx];
        uint32_t x_max = (uint32_t)kZ_X_MAX_PREFACTOR * f;
        while (x >= x_max) {
            lane_chunks[s_idx][lane_n[s_idx]++] = (uint16_t)(x & kZ_B_MASK);
            x >>= kZ_B_BITS;
        }
        state[s_idx] = (x / f) * (uint32_t)kZ_T + (x % f) + c;
    }

    out_state_init[0] = (uint32_t)kZ_L;
    out_state_init[1] = (uint32_t)kZ_L;
    out_state_init[2] = (uint32_t)kZ_L;
    out_state_init[3] = (uint32_t)kZ_L;
    out_state_final[0] = state[0];
    out_state_final[1] = state[1];
    out_state_final[2] = state[2];
    out_state_final[3] = state[3];

    // Build per-stream byte buffers (reverse chunk order, emit each as LE pair).
    streams_out = (uint8_t **)calloc(4, sizeof(uint8_t *));
    if (!streams_out) {
        z_set_error(error, 85, @"M94Z encoder: streams_out alloc failed");
        goto cleanup;
    }
    for (int s_idx = 0; s_idx < 4; s_idx++) {
        int32_t n_chunks = lane_n[s_idx];
        size_t bsize = (size_t)2 * (size_t)n_chunks;
        uint8_t *buf = (uint8_t *)malloc(bsize > 0 ? bsize : 1);
        if (!buf) {
            z_set_error(error, 86, @"M94Z encoder: stream buffer alloc failed");
            goto cleanup;
        }
        for (int32_t k = 0; k < n_chunks; k++) {
            uint16_t chunk = lane_chunks[s_idx][k];
            size_t j = (size_t)(n_chunks - 1 - k);
            buf[2 * j]     = (uint8_t)(chunk & 0xFF);
            buf[2 * j + 1] = (uint8_t)((chunk >> 8) & 0xFF);
        }
        streams_out[s_idx] = buf;
        out_stream_lens[s_idx] = (uint32_t)bsize;
    }
    *out_streams = streams_out;
    streams_out = NULL;  // ownership transferred

    // Build sorted active_ctxs + parallel freq table list.
    size_t n_active = 0;
    for (int32_t ctx = 0; ctx < n_contexts; ctx++) {
        if (ctx_counts[ctx] != NULL) n_active++;
    }
    uint32_t *act = (uint32_t *)malloc(sizeof(uint32_t) * (n_active ?: 1));
    uint16_t **ft  = (uint16_t **)calloc(n_active ?: 1, sizeof(uint16_t *));
    if (!act || !ft) {
        free(act); free(ft);
        z_set_error(error, 87, @"M94Z encoder: active_ctxs alloc failed");
        goto cleanup;
    }
    size_t ai = 0;
    for (int32_t ctx = 0; ctx < n_contexts; ctx++) {
        if (ctx_counts[ctx] == NULL) continue;
        act[ai] = (uint32_t)ctx;
        ft[ai] = (uint16_t *)malloc(sizeof(uint16_t) * 256);
        if (!ft[ai]) {
            for (size_t j = 0; j < ai; j++) free(ft[j]);
            free(ft); free(act);
            z_set_error(error, 88, @"M94Z encoder: per-ctx freq dup alloc failed");
            goto cleanup;
        }
        memcpy(ft[ai], ctx_freq[ctx], sizeof(uint16_t) * 256);
        ai++;
    }
    *out_active_ctxs = act;
    *out_freq_tables = ft;
    *out_n_active = n_active;

    rc = 0;

cleanup:
    if (streams_out) {
        for (int s = 0; s < 4; s++) free(streams_out[s]);
        free(streams_out);
    }
    for (int s = 0; s < 4; s++) {
        free(lane_chunks[s]);
        free(lane_bytes[s]);
    }
    free(symbols);
    free(contexts);
    if (ctx_counts) {
        for (int32_t ctx = 0; ctx < n_contexts; ctx++) free(ctx_counts[ctx]);
        free(ctx_counts);
    }
    if (ctx_freq) {
        for (int32_t ctx = 0; ctx < n_contexts; ctx++) free(ctx_freq[ctx]);
        free(ctx_freq);
    }
    if (ctx_cum) {
        for (int32_t ctx = 0; ctx < n_contexts; ctx++) free(ctx_cum[ctx]);
        free(ctx_cum);
    }
    return rc;
}

// ── Decoder ──────────────────────────────────────────────────────
//
// Per-context decode info, compact form. For each active context we
// store ONLY the symbols that actually have freq > 0, packed into a
// single contiguous block:
//
//   uint16_t cum[n_act + 1]   // cumulative offsets, cum[n_act] = T
//   uint16_t freq_c[n_act]    // freq for sym_c[k]
//   uint8_t  sym_c[n_act]     // symbol values, ascending by sym
//
// Accessed through z_ctx_decode_info indexed by ctx id.
//
// Why compact: typical Illumina-quality contexts have ~10–25 active
// symbols (out of 256). Storing only those keeps each context's data
// well under 256 B, so the working set for ~16 K active contexts is
// ≈ 2–3 MB — fits in L3. The slot→sym lookup is a short binary search
// over cum_c[] (≈ log2(25) ≈ 5 iters), all inside one cache line.
//
// This wins over the dense slot_to_sym[4096] (4 KB per ctx) approach
// because that representation needs 16 K × 4 KB = 64 MB of slot tables,
// which spills to RAM and turns every decode op into an L3 miss.
typedef struct {
    uint16_t  n_syms;
    uint16_t  pad;
    const uint16_t *cum;     // length n_syms + 1
    const uint16_t *freq_c;  // length n_syms
    const uint8_t  *sym_c;   // length n_syms
} z_ctx_decode_info;

static int z_decode_full(const uint8_t * const streams[4],
                           const uint32_t stream_lens[4],
                           const uint32_t state_init[4],
                           const uint32_t state_final[4],
                           int32_t n_qualities, int32_t n_padded,
                           const int32_t *read_lengths, int32_t n_reads,
                           const int8_t *revcomp_flags,
                           const uint32_t *active_ctxs,
                           uint16_t * const *freq_tables,
                           size_t n_active,
                           int32_t qbits, int32_t pbits, int32_t sloc,
                           uint8_t *out_qualities,
                           NSError **error)
{
    int32_t n_contexts = 1 << sloc;
    z_ctx_decode_info *info = (z_ctx_decode_info *)calloc(
        n_contexts, sizeof(z_ctx_decode_info));
    // Worst case per ctx: 256 syms → (257 + 256) * 2 + 256 = 1282 B.
    // Bump-allocator into one arena keeps everything contiguous.
    size_t arena_cap = (n_active > 0)
        ? n_active * (size_t)1288  // padded for 8 B alignment
        : (size_t)64;
    uint8_t *arena = (uint8_t *)malloc(arena_cap);
    if (!info || !arena) {
        free(info); free(arena);
        z_set_error(error, 90, @"M94Z decoder: lookup alloc failed");
        return -1;
    }
    int rc = -1;
    size_t arena_off = 0;
    for (size_t i = 0; i < n_active; i++) {
        uint32_t ctx = active_ctxs[i];
        if (ctx >= (uint32_t)n_contexts) {
            z_set_error(error, 91, @"M94Z decoder: ctx %u out of range",
                        (unsigned)ctx);
            goto cleanup;
        }
        const uint16_t *src_freq = freq_tables[i];
        // Count active syms for this context.
        int n_act = 0;
        for (int k = 0; k < 256; k++) if (src_freq[k] > 0) n_act++;
        // Lay out cum[n_act+1] u16, freq_c[n_act] u16, sym_c[n_act] u8,
        // then bump to next 8 B boundary.
        size_t base = (arena_off + 7u) & ~(size_t)7;
        uint16_t *cum_c  = (uint16_t *)(arena + base);
        uint16_t *freq_c = cum_c + (n_act + 1);
        uint8_t  *sym_c  = (uint8_t *)(freq_c + n_act);
        size_t bytes = (size_t)(n_act + 1) * 2 + (size_t)n_act * 3;
        arena_off = base + bytes;
        if (arena_off > arena_cap) {
            z_set_error(error, 92, @"M94Z decoder: arena overflow");
            goto cleanup;
        }
        // Build compact arrays.
        uint32_t running = 0;
        int j = 0;
        for (int k = 0; k < 256; k++) {
            if (src_freq[k] > 0) {
                cum_c[j]  = (uint16_t)running;
                freq_c[j] = src_freq[k];
                sym_c[j]  = (uint8_t)k;
                running  += src_freq[k];
                j++;
            }
        }
        cum_c[n_act] = (uint16_t)running;  // sentinel = T
        info[ctx].n_syms = (uint16_t)n_act;
        info[ctx].cum    = cum_c;
        info[ctx].freq_c = freq_c;
        info[ctx].sym_c  = sym_c;
    }

    uint32_t pad_ctx = z_context(0, 0, 0, qbits, pbits, sloc);
    int32_t shift = qbits / 3;
    if (shift < 1) shift = 1;
    uint32_t qmask_local = ((uint32_t)1 << qbits) - 1;
    uint32_t shift_mask = ((uint32_t)1 << shift) - 1;

    int32_t read_idx = 0;
    int32_t pos_in_read = 0;
    int32_t cur_read_len = (n_reads > 0) ? read_lengths[0] : 0;
    uint32_t cur_revcomp = (n_reads > 0) ? (uint32_t)revcomp_flags[0] : 0;
    int32_t cumulative_read_end = cur_read_len;
    uint32_t prev_q = 0;

    uint32_t state[4] = { state_final[0], state_final[1], state_final[2], state_final[3] };
    uint32_t pos[4] = { 0, 0, 0, 0 };

    // Hot phase: i in [0, n_qualities). We must handle read boundaries.
    // The pad phase (i in [n_qualities, n_padded)) is at most 3 ops.
    for (int32_t i = 0; i < n_qualities; i++) {
        if (i >= cumulative_read_end && read_idx < n_reads - 1) {
            read_idx++;
            pos_in_read = 0;
            cur_read_len = read_lengths[read_idx];
            cur_revcomp = (uint32_t)revcomp_flags[read_idx];
            cumulative_read_end += cur_read_len;
            prev_q = 0;
        }
        uint32_t pb = z_pos_bucket(pos_in_read, cur_read_len, pbits);
        uint32_t ctx = z_context(prev_q, pb, cur_revcomp & 1,
                                 qbits, pbits, sloc);

        const z_ctx_decode_info *ci = &info[ctx];
        if (__builtin_expect(ci->n_syms == 0, 0)) {
            z_set_error(error, 93,
                @"M94Z decoder: ctx %u not in freq tables", (unsigned)ctx);
            goto cleanup;
        }
        const uint16_t *cum = ci->cum;
        const uint16_t *freq_c = ci->freq_c;
        const uint8_t  *sym_c = ci->sym_c;
        int n_act = (int)ci->n_syms;

        int s_idx = i & 3;
        uint32_t x = state[s_idx];
        uint32_t slot = x & (uint32_t)kZ_T_MASK;

        // Linear scan from the top: cum[] is ascending with cum[n_act] = T.
        // Find largest k with cum[k] <= slot. With ~10-25 active syms,
        // this is competitive with binary search and has better branch
        // prediction (consecutive monotonic compares hit on the same
        // cache line, no mispredict penalties for the unpredictable
        // pivot of binary search).
        int lo = n_act - 1;
        while (cum[lo] > slot) lo--;
        int sym = (int)sym_c[lo];
        out_qualities[i] = (uint8_t)sym;

        uint32_t f = (uint32_t)freq_c[lo];
        uint32_t c = (uint32_t)cum[lo];
        x = f * (x >> kZ_T_BITS) + slot - c;
        while (x < (uint32_t)kZ_L) {
            if (__builtin_expect(pos[s_idx] + 1 >= stream_lens[s_idx], 0)) {
                z_set_error(error, 94,
                    @"M94Z decoder: substream %d exhausted (pos=%u, len=%u)",
                    s_idx, (unsigned)pos[s_idx], (unsigned)stream_lens[s_idx]);
                goto cleanup;
            }
            uint32_t chunk = (uint32_t)streams[s_idx][pos[s_idx]] |
                              ((uint32_t)streams[s_idx][pos[s_idx] + 1] << 8);
            pos[s_idx] += 2;
            x = (x << kZ_B_BITS) | chunk;
        }
        state[s_idx] = x;

        prev_q = ((prev_q << shift) | ((uint32_t)sym & shift_mask))
                   & qmask_local;
        pos_in_read++;
    }

    // Pad phase: at most 3 iterations (n_padded - n_qualities ∈ [0, 3]).
    for (int32_t i = n_qualities; i < n_padded; i++) {
        const z_ctx_decode_info *ci = &info[pad_ctx];
        if (ci->n_syms == 0) {
            z_set_error(error, 93,
                @"M94Z decoder: ctx %u not in freq tables", (unsigned)pad_ctx);
            goto cleanup;
        }
        const uint16_t *cum = ci->cum;
        const uint16_t *freq_c = ci->freq_c;
        int n_act = (int)ci->n_syms;

        int s_idx = i & 3;
        uint32_t x = state[s_idx];
        uint32_t slot = x & (uint32_t)kZ_T_MASK;
        int lo = n_act - 1;
        while (cum[lo] > slot) lo--;
        uint32_t f = (uint32_t)freq_c[lo];
        uint32_t c = (uint32_t)cum[lo];
        x = f * (x >> kZ_T_BITS) + slot - c;
        while (x < (uint32_t)kZ_L) {
            if (pos[s_idx] + 1 >= stream_lens[s_idx]) {
                z_set_error(error, 94,
                    @"M94Z decoder: substream %d exhausted (pos=%u, len=%u)",
                    s_idx, (unsigned)pos[s_idx], (unsigned)stream_lens[s_idx]);
                goto cleanup;
            }
            uint32_t chunk = (uint32_t)streams[s_idx][pos[s_idx]] |
                              ((uint32_t)streams[s_idx][pos[s_idx] + 1] << 8);
            pos[s_idx] += 2;
            x = (x << kZ_B_BITS) | chunk;
        }
        state[s_idx] = x;
    }

    // Verify post-decode state matches state_init.
    if (state[0] != state_init[0] || state[1] != state_init[1] ||
        state[2] != state_init[2] || state[3] != state_init[3]) {
        z_set_error(error, 95,
            @"M94Z decoder: post-decode state mismatch "
            @"(got [%u,%u,%u,%u], want [%u,%u,%u,%u])",
            (unsigned)state[0], (unsigned)state[1],
            (unsigned)state[2], (unsigned)state[3],
            (unsigned)state_init[0], (unsigned)state_init[1],
            (unsigned)state_init[2], (unsigned)state_init[3]);
        goto cleanup;
    }
    rc = 0;

cleanup:
    free(arena);
    free(info);
    return rc;
}

// ── V2 native dispatch (Task 23) ─────────────────────────────────
//
// Mirrors python/src/ttio/codecs/fqzcomp_nx16_z.py::_encode_v2_native
// and java FqzcompNx16Z.encodeV2Native. V2 wire format = same header
// fields as V1 EXCEPT version byte = 2 and no 16-byte state_init suffix
// (V2 body embeds final states at its own offset 0..15). V2 body =
// raw ttio_rans_encode_block output (self-contained).
//
// V2 encode dispatches on TTIO_HAS_NATIVE_RANS at compile time AND on
// the runtime presence of preferNative=@YES (or env var). When the
// native lib is absent, callers are silently downgraded to V1.

#if TTIO_HAS_NATIVE_RANS
static NSData *z_encode_v2_native(const uint8_t *qualities, int32_t n_qualities,
                                    NSArray<NSNumber *> *readLengthsArr,
                                    const int32_t *read_lengths, int32_t n_reads,
                                    const int8_t *revcomp_flags,
                                    int32_t qbits, int32_t pbits,
                                    int32_t dbits, int32_t sloc,
                                    NSError **error)
{
    int32_t pad_count = (-n_qualities) & 3;
    int32_t n_padded = n_qualities + pad_count;
    int32_t n_contexts = 1 << sloc;

    int32_t **ctx_counts = (int32_t **)calloc(n_contexts, sizeof(int32_t *));
    uint32_t *contexts   = (uint32_t *)malloc(sizeof(uint32_t)
                                                * ((n_padded > 0) ? n_padded : 1));
    uint8_t  *symbols    = (uint8_t  *)malloc((n_padded > 0) ? n_padded : 1);
    if (!ctx_counts || !contexts || !symbols) {
        free(ctx_counts); free(contexts); free(symbols);
        z_set_error(error, 150, @"M94Z V2 native: alloc failed");
        return nil;
    }

    if (n_padded > 0) {
        memset(symbols, 0, n_padded);
        for (int32_t i = 0; i < n_qualities; i++) symbols[i] = qualities[i];
    }

    z_build_context_seq(qualities, n_qualities, n_padded,
                          read_lengths, n_reads, revcomp_flags,
                          qbits, pbits, sloc, contexts);

    // Helper macro for failure-path cleanup of the C buffers we own
    // before any NSObject is created. Defined inline to avoid the
    // ARC-vs-goto-jump-past-strong-init issue.
    #define Z_V2_FAIL_C() do { \
        if (ctx_counts) { \
            for (int32_t cc_ = 0; cc_ < n_contexts; cc_++) free(ctx_counts[cc_]); \
            free(ctx_counts); \
        } \
        free(contexts); free(symbols); \
        return nil; \
    } while (0)

    // Pass 1: per-context raw counts.
    for (int32_t i = 0; i < n_padded; i++) {
        uint32_t ctx = contexts[i];
        if (ctx_counts[ctx] == NULL) {
            ctx_counts[ctx] = (int32_t *)calloc(256, sizeof(int32_t));
            if (!ctx_counts[ctx]) {
                z_set_error(error, 151, @"M94Z V2 native: per-ctx count alloc failed");
                Z_V2_FAIL_C();
            }
        }
        ctx_counts[ctx][symbols[i]]++;
    }

    // Count active and normalise per-ctx freq tables.
    size_t n_active = 0;
    for (int32_t c = 0; c < n_contexts; c++) {
        if (ctx_counts[c]) n_active++;
    }
    if (n_active == 0 || n_active > 0xFFFFu) {
        z_set_error(error, 152,
            @"M94Z V2 native: nActive (%zu) must be in [1, 65535]", n_active);
        Z_V2_FAIL_C();
    }

    uint32_t *active_ctxs = (uint32_t *)malloc(sizeof(uint32_t) * n_active);
    uint16_t **ft_orig    = (uint16_t **)calloc(n_active, sizeof(uint16_t *));
    int32_t  *ctx_remap   = (int32_t *)malloc(sizeof(int32_t) * n_contexts);
    uint32_t *freq_dense  = (uint32_t *)calloc(n_active * 256, sizeof(uint32_t));
    uint16_t *contexts_remapped = (uint16_t *)malloc(sizeof(uint16_t)
                                          * ((n_padded > 0) ? n_padded : 1));

    // From here on, additional buffers must be cleaned via this macro.
    #define Z_V2_FREE_DENSE_C() do { \
        if (ft_orig) { \
            for (size_t jj_ = 0; jj_ < n_active; jj_++) free(ft_orig[jj_]); \
        } \
        free(ft_orig); free(active_ctxs); free(ctx_remap); \
        free(freq_dense); free(contexts_remapped); \
    } while (0)

    if (!active_ctxs || !ft_orig || !ctx_remap || !freq_dense || !contexts_remapped) {
        z_set_error(error, 153, @"M94Z V2 native: dense alloc failed");
        Z_V2_FREE_DENSE_C();
        Z_V2_FAIL_C();
    }
    for (int32_t c = 0; c < n_contexts; c++) ctx_remap[c] = -1;

    size_t ai = 0;
    int normalize_failed = 0;
    int alloc_failed = 0;
    for (int32_t c = 0; c < n_contexts; c++) {
        if (!ctx_counts[c]) continue;
        active_ctxs[ai] = (uint32_t)c;
        ctx_remap[c] = (int32_t)ai;
        uint16_t *fr = (uint16_t *)malloc(sizeof(uint16_t) * 256);
        if (!fr) { alloc_failed = 1; break; }
        if (z_normalise_to_total(ctx_counts[c], fr) != 0) {
            free(fr); normalize_failed = 1; break;
        }
        ft_orig[ai] = fr;
        for (int k = 0; k < 256; k++) {
            freq_dense[ai * 256 + k] = (uint32_t)fr[k];
        }
        ai++;
    }
    if (alloc_failed) {
        z_set_error(error, 154, @"M94Z V2 native: freq dup alloc failed");
        n_active = ai;  // only [0..ai) freq arrays were allocated
        Z_V2_FREE_DENSE_C();
        Z_V2_FAIL_C();
    }
    if (normalize_failed) {
        z_set_error(error, 155,
            @"M94Z V2 native: normalise_to_total cannot reduce below floor=1");
        n_active = ai;
        Z_V2_FREE_DENSE_C();
        Z_V2_FAIL_C();
    }

    // Build remapped (dense) contexts buffer.
    for (int32_t i = 0; i < n_padded; i++) {
        int32_t dense = ctx_remap[contexts[i]];
        contexts_remapped[i] = (uint16_t)(dense & 0xFFFF);
    }

    // Native encode.
    size_t out_cap = (size_t)n_padded * 4 + 64;
    if (out_cap < 64) out_cap = 64;
    uint8_t *out_buf = (uint8_t *)malloc(out_cap);
    if (!out_buf) {
        z_set_error(error, 156, @"M94Z V2 native: out buffer alloc failed");
        Z_V2_FREE_DENSE_C();
        Z_V2_FAIL_C();
    }
    size_t out_len = out_cap;
    int rc = ttio_rans_encode_block(
        symbols,
        contexts_remapped,
        (size_t)n_padded,
        (uint16_t)n_active,
        (const uint32_t (*)[256])freq_dense,
        out_buf,
        &out_len);
    if (rc != 0) {
        free(out_buf);
        z_set_error(error, 157,
            @"M94Z V2 native: ttio_rans_encode_block failed (rc=%d)", rc);
        Z_V2_FREE_DENSE_C();
        Z_V2_FAIL_C();
    }

    // Build sidecars: rlt + freq_tables blob (with ORIGINAL sparse ctx ids).
    NSData *rlt = z_encode_read_lengths(readLengthsArr);
    if (!rlt) {
        free(out_buf);
        z_set_error(error, 158, @"M94Z V2 native: rlt deflate failed");
        Z_V2_FREE_DENSE_C();
        Z_V2_FAIL_C();
    }
    NSData *ft_blob = z_serialize_freq_tables(active_ctxs, n_active,
                                                ft_orig, sloc);
    if (!ft_blob) {
        free(out_buf);
        z_set_error(error, 159, @"M94Z V2 native: freq_tables deflate failed");
        Z_V2_FREE_DENSE_C();
        Z_V2_FAIL_C();
    }

    // V2 wire format: header (no state_init suffix) + native body.
    NSUInteger header_size = (NSUInteger)kZ_HEADER_FIXED_PREFIX
                               + (NSUInteger)rlt.length
                               + (NSUInteger)ft_blob.length;
    NSUInteger total_size = header_size + (NSUInteger)out_len;
    NSMutableData *out = [NSMutableData dataWithLength:total_size];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    uint8_t flagsByte = (uint8_t)((pad_count & 0x3) << 4);

    memcpy(p, kZ_MAGIC, 4); p += 4;
    *p++ = (uint8_t)kZ_VERSION_V2_NATIVE;
    *p++ = flagsByte;
    le_pack_u64(p, (uint64_t)n_qualities);     p += 8;
    le_pack_u32(p, (uint32_t)n_reads);          p += 4;
    le_pack_u32(p, (uint32_t)rlt.length);       p += 4;
    *p++ = (uint8_t)(qbits & 0xFF);
    *p++ = (uint8_t)(pbits & 0xFF);
    *p++ = (uint8_t)(dbits & 0xFF);
    *p++ = (uint8_t)(sloc  & 0xFF);
    memset(p, 0, 4); p += 4;
    le_pack_u32(p, (uint32_t)ft_blob.length); p += 4;
    if (rlt.length) memcpy(p, rlt.bytes, rlt.length);
    p += rlt.length;
    if (ft_blob.length) memcpy(p, ft_blob.bytes, ft_blob.length);
    p += ft_blob.length;
    memcpy(p, out_buf, out_len);

    // Cleanup all C resources.
    free(out_buf);
    Z_V2_FREE_DENSE_C();
    for (int32_t c = 0; c < n_contexts; c++) free(ctx_counts[c]);
    free(ctx_counts); free(contexts); free(symbols);
    #undef Z_V2_FREE_DENSE_C
    #undef Z_V2_FAIL_C
    return out;
}
#endif  /* TTIO_HAS_NATIVE_RANS */

// ── V2 native streaming decode (Task 26c) ────────────────────────
//
// Routes the inner rANS decode loop through libttio_rans's
// ttio_rans_decode_block_streaming API, with a per-symbol C resolver
// callback that derives M94.Z contexts on the fly.
//
// Performance reality (Task 26c): the per-symbol callback adds
// indirect-call overhead inside the C decode loop.  Unlike Python
// (ctypes CFUNCTYPE) and Java (JNI CallIntMethod), ObjC has direct
// C linkage so the callback cost is only an indirect function call.
// However, the overall path is still expected to be on par with or
// slightly slower than the pure-ObjC V2 decoder for realistic blocks
// because the resolver dominates the inner-loop cost vs the SIMD
// kernel's unrolled multi-lane scalar ops.  Shipped as infrastructure
// proving the streaming C API works end-to-end across all bindings.
//
// The streaming path is gated on TTIO_M94Z_USE_NATIVE_STREAMING env
// var (default off) because the C library does not validate the
// post-decode final state, so a corrupt stream may decode silently
// to the wrong bytes.  The pure-ObjC path below is more defensive
// and remains the default.

#if TTIO_HAS_NATIVE_RANS

typedef struct {
    int32_t n_qualities;
    int32_t qbits;
    int32_t pbits;
    int32_t sloc;
    int32_t shift;
    uint32_t qmask_local;
    uint32_t shift_mask;

    // Read-tracking state.
    int32_t read_idx;
    int32_t pos_in_read;
    int32_t cur_read_len;
    uint32_t cur_revcomp;
    int32_t cumulative_read_end;
    uint32_t prev_q;

    int32_t n_reads;
    const int32_t *read_lengths;
    const int8_t  *revcomp_flags;

    // Sparse → dense ctx remap.  Indexed by sparse ctx id; -1 means
    // absent (defensive — should not happen on a valid blob).
    const int32_t *ctx_remap;
    int32_t pad_ctx_dense;
} z_streaming_resolver_state;

static uint16_t z_streaming_resolver_cb(void *user_data,
                                          size_t i,
                                          uint8_t prev_sym)
{
    z_streaming_resolver_state *st = (z_streaming_resolver_state *)user_data;

    // C library does not call this for i >= n_symbols (padding),
    // but be defensive anyway.
    if ((int32_t)i >= st->n_qualities) {
        return (uint16_t)st->pad_ctx_dense;
    }

    if (i > 0) {
        st->prev_q = ((st->prev_q << st->shift)
                      | ((uint32_t)prev_sym & st->shift_mask)) & st->qmask_local;
        st->pos_in_read++;
    }

    // Read-boundary advance.
    if (i > 0 && (int32_t)i >= st->cumulative_read_end
        && st->read_idx < st->n_reads - 1) {
        st->read_idx++;
        st->pos_in_read = 0;
        st->cur_read_len = st->read_lengths[st->read_idx];
        st->cur_revcomp  = (uint32_t)(st->revcomp_flags[st->read_idx] & 1);
        st->cumulative_read_end += st->cur_read_len;
        st->prev_q = 0;
    }

    uint32_t pb = z_pos_bucket(st->pos_in_read, st->cur_read_len, st->pbits);
    uint32_t ctx_sparse = z_context(st->prev_q, pb, st->cur_revcomp & 1,
                                     st->qbits, st->pbits, st->sloc);
    int32_t dense = st->ctx_remap[ctx_sparse];
    if (dense < 0) return (uint16_t)st->pad_ctx_dense;
    return (uint16_t)dense;
}

/*
 * Pre-condition: caller has parsed the V2 header and recovered the
 * sparse freq tables.  This function builds the dense (sorted-by-ctx)
 * freq+cum tables, the dtab via ttio_rans_build_decode_table, and the
 * sparse→dense remap, then calls ttio_rans_decode_block_streaming.
 *
 * On success, returns a retained NSDictionary identical in shape to
 * z_decode_v2's output: { @"qualities": NSData, @"readLengths": NSArray }.
 * On failure, sets *error and returns nil.
 *
 * Always returns nil (rather than throwing) on any error, so the
 * caller can transparently fall back to the pure-ObjC decoder.
 */
static NSDictionary *z_decode_v2_via_native_streaming(
    const uint8_t *body, NSUInteger body_len,
    int32_t n_qualities, int32_t n_padded,
    NSArray<NSNumber *> *readLengths,
    NSArray<NSNumber *> *revcompFlags,
    int32_t qbits, int32_t pbits, int32_t sloc,
    size_t n_active, const uint32_t *active_ctxs,
    uint16_t * const *freq_tables_orig)
{
    if (n_active == 0 || n_active > 0xFFFFu) return nil;

    int32_t n_contexts_sparse = 1 << sloc;

    // Allocate dense freq + cum + dtab + sparse→dense remap.
    uint32_t *freq_dense = (uint32_t *)calloc(n_active * 256, sizeof(uint32_t));
    uint32_t *cum_dense  = (uint32_t *)calloc(n_active * 256, sizeof(uint32_t));
    uint8_t  *dtab       = (uint8_t  *)calloc(n_active * (size_t)kZ_T,
                                                sizeof(uint8_t));
    int32_t  *ctx_remap  = (int32_t  *)malloc(sizeof(int32_t) * n_contexts_sparse);
    if (!freq_dense || !cum_dense || !dtab || !ctx_remap) {
        free(freq_dense); free(cum_dense); free(dtab); free(ctx_remap);
        return nil;
    }
    for (int32_t c = 0; c < n_contexts_sparse; c++) ctx_remap[c] = -1;

    for (size_t ai = 0; ai < n_active; ai++) {
        uint32_t sparse = active_ctxs[ai];
        if ((int32_t)sparse >= n_contexts_sparse) {
            free(freq_dense); free(cum_dense); free(dtab); free(ctx_remap);
            return nil;
        }
        ctx_remap[sparse] = (int32_t)ai;
        const uint16_t *fr = freq_tables_orig[ai];
        uint32_t running = 0;
        for (int s = 0; s < 256; s++) {
            freq_dense[ai * 256 + s] = (uint32_t)fr[s];
            cum_dense[ai * 256 + s]  = running;
            running += (uint32_t)fr[s];
        }
    }

    int rc = ttio_rans_build_decode_table(
        (uint16_t)n_active,
        (const uint32_t (*)[256])freq_dense,
        (const uint32_t (*)[256])cum_dense,
        (uint8_t (*)[TTIO_RANS_T])dtab);
    if (rc != 0) {
        free(freq_dense); free(cum_dense); free(dtab); free(ctx_remap);
        return nil;
    }

    // Build read-length / revcomp C arrays for the resolver.
    int32_t n_reads = (int32_t)readLengths.count;
    int32_t *rl_arr = (int32_t *)malloc(sizeof(int32_t)
                                          * (n_reads ? n_reads : 1));
    int8_t  *rc_arr = (int8_t  *)malloc(sizeof(int8_t)
                                          * (n_reads ? n_reads : 1));
    if (!rl_arr || !rc_arr) {
        free(rl_arr); free(rc_arr);
        free(freq_dense); free(cum_dense); free(dtab); free(ctx_remap);
        return nil;
    }
    for (int32_t k = 0; k < n_reads; k++) {
        rl_arr[k] = (int32_t)[readLengths[k] unsignedLongLongValue];
        rc_arr[k] = (int8_t)([revcompFlags[k] unsignedIntegerValue] & 1u);
    }

    uint32_t pad_ctx_sparse = z_context(0, 0, 0, qbits, pbits, sloc);
    int32_t pad_ctx_dense = (pad_ctx_sparse < (uint32_t)n_contexts_sparse)
                              ? ctx_remap[pad_ctx_sparse] : -1;
    if (pad_ctx_dense < 0) pad_ctx_dense = 0;  // defensive

    int32_t shift = qbits / 3;
    if (shift < 1) shift = 1;

    z_streaming_resolver_state state = {
        .n_qualities = n_qualities,
        .qbits = qbits, .pbits = pbits, .sloc = sloc,
        .shift = shift,
        .qmask_local = ((uint32_t)1 << qbits) - 1,
        .shift_mask  = ((uint32_t)1 << shift) - 1,
        .read_idx = 0,
        .pos_in_read = 0,
        .cur_read_len = (n_reads > 0) ? rl_arr[0] : 0,
        .cur_revcomp  = (n_reads > 0) ? (uint32_t)rc_arr[0] : 0,
        .cumulative_read_end = (n_reads > 0) ? rl_arr[0] : 0,
        .prev_q = 0,
        .n_reads = n_reads,
        .read_lengths = rl_arr,
        .revcomp_flags = rc_arr,
        .ctx_remap = ctx_remap,
        .pad_ctx_dense = pad_ctx_dense,
    };

    uint8_t *out_buf = (uint8_t *)calloc((n_padded > 0) ? n_padded : 1, 1);
    if (!out_buf) {
        free(rl_arr); free(rc_arr);
        free(freq_dense); free(cum_dense); free(dtab); free(ctx_remap);
        return nil;
    }

    rc = ttio_rans_decode_block_streaming(
        body, body_len,
        (uint16_t)n_active,
        (const uint32_t (*)[256])freq_dense,
        (const uint32_t (*)[256])cum_dense,
        (const uint8_t (*)[TTIO_RANS_T])dtab,
        out_buf, (size_t)n_padded,
        z_streaming_resolver_cb,
        &state);

    NSDictionary *result = nil;
    if (rc == 0) {
        NSData *qData = [NSData dataWithBytes:out_buf
                                       length:(NSUInteger)n_qualities];
        result = @{
            @"qualities":   qData,
            @"readLengths": readLengths,
        };
    }

    free(out_buf);
    free(rl_arr); free(rc_arr);
    free(freq_dense); free(cum_dense); free(dtab); free(ctx_remap);
    return result;
}

#endif  /* TTIO_HAS_NATIVE_RANS */

// ── V2 decode (pure-ObjC; option E) ──────────────────────────────
//
// Pure-ObjC walk-forward decoder for V2 streams. Mirrors the Python
// _decode_v2_with_metadata and Java decodeV2 implementations. The
// streaming variant above (z_decode_v2_via_native_streaming) is used
// opportunistically when TTIO_M94Z_USE_NATIVE_STREAMING is set; this
// pure-ObjC path remains the canonical reference and the default
// because it validates post-decode invariants the C library does not.

static NSDictionary *z_decode_v2(NSData *data,
                                   NSArray<NSNumber *> *revcompFlags,
                                   NSError **error)
{
    const uint8_t *p = (const uint8_t *)data.bytes;
    if (data.length < kZ_HEADER_FIXED_PREFIX) {
        z_set_error(error, 220, @"M94Z V2: encoded too short (%lu bytes)",
                    (unsigned long)data.length);
        return nil;
    }
    // Magic + version were already checked by the caller.
    uint8_t flags = p[5];
    uint64_t numQ = le_read_u64(p + 6);
    uint32_t numR = le_read_u32(p + 14);
    uint32_t rlt_len = le_read_u32(p + 18);
    int32_t qbits = (int32_t)p[22];
    int32_t pbits = (int32_t)p[23];
    // dbits = p[24]; ignored
    int32_t sloc  = (int32_t)p[25];
    uint32_t ft_len = le_read_u32(p + 30);

    int32_t pad_count = (flags >> 4) & 0x3;

    NSUInteger header_end = (NSUInteger)kZ_HEADER_FIXED_PREFIX
                              + (NSUInteger)rlt_len
                              + (NSUInteger)ft_len;
    if (data.length < header_end) {
        z_set_error(error, 221,
            @"M94Z V2: header size %lu exceeds data length %lu",
            (unsigned long)header_end, (unsigned long)data.length);
        return nil;
    }
    NSData *rltData    = [data subdataWithRange:NSMakeRange(34, rlt_len)];
    NSData *ftBlobData = [data subdataWithRange:NSMakeRange(34 + rlt_len, ft_len)];

    NSError *rltErr = nil;
    NSArray<NSNumber *> *readLengths = z_decode_read_lengths(rltData, numR, &rltErr);
    if (!readLengths) {
        if (error) *error = rltErr;
        return nil;
    }

    if (revcompFlags == nil) {
        NSMutableArray *zeros = [NSMutableArray arrayWithCapacity:numR];
        for (uint32_t i = 0; i < numR; i++) [zeros addObject:@0];
        revcompFlags = zeros;
    } else if (revcompFlags.count != numR) {
        z_set_error(error, 222,
            @"M94Z V2: revcompFlags.count %lu != num_reads %u",
            (unsigned long)revcompFlags.count, numR);
        return nil;
    }

    uint64_t n_padded64 = numQ + (uint64_t)pad_count;
    if (n_padded64 & 3) {
        z_set_error(error, 223,
            @"M94Z V2: n_padded %llu not a multiple of 4 (numQ=%llu, pad=%d)",
            (unsigned long long)n_padded64, (unsigned long long)numQ, pad_count);
        return nil;
    }
    int32_t n_padded = (int32_t)n_padded64;

    // Body parse: starts at header_end, must hold at least 32 bytes
    // (4×state + 4×lane_size).
    NSUInteger body_off = header_end;
    NSUInteger body_len = data.length - body_off;
    if (body_len < 32) {
        z_set_error(error, 224, @"M94Z V2: body shorter than native header (%lu)",
                    (unsigned long)body_len);
        return nil;
    }
    uint32_t state[4];
    uint32_t lane_bytes[4];
    for (int k = 0; k < 4; k++) state[k] = le_read_u32(p + body_off + k * 4);
    for (int k = 0; k < 4; k++) lane_bytes[k] = le_read_u32(p + body_off + 16 + k * 4);
    uint64_t total_data = (uint64_t)lane_bytes[0] + lane_bytes[1]
                          + lane_bytes[2] + lane_bytes[3];
    if ((uint64_t)body_len < 32u + total_data) {
        z_set_error(error, 225,
            @"M94Z V2: body truncated (have %lu, need %llu)",
            (unsigned long)body_len, (unsigned long long)(32u + total_data));
        return nil;
    }
    const uint8_t *lane_base[4];
    {
        NSUInteger off = body_off + 32;
        for (int k = 0; k < 4; k++) {
            lane_base[k] = p + off;
            off += lane_bytes[k];
        }
    }
    uint32_t lane_pos[4] = { 0, 0, 0, 0 };

    // Recover sparse freq tables.
    size_t n_active = 0;
    uint32_t *active_ctxs = NULL;
    uint16_t **freq_tables = NULL;
    NSError *ftErr = nil;
    if (z_deserialize_freq_tables(ftBlobData, &n_active, &active_ctxs,
                                    &freq_tables, &ftErr) != 0) {
        if (error) *error = ftErr;
        return nil;
    }

#if TTIO_HAS_NATIVE_RANS
    // ── Optional native streaming dispatch (Task 26c) ─────────────
    // Gated on TTIO_M94Z_USE_NATIVE_STREAMING env var; default off.
    // The pure-ObjC fallback below is more defensive (validates
    // post-decode invariants the C library skips).
    {
        const char *streamEnv = getenv("TTIO_M94Z_USE_NATIVE_STREAMING");
        BOOL streamOn = NO;
        if (streamEnv && *streamEnv) {
            if (strcasecmp(streamEnv, "1") == 0
                || strcasecmp(streamEnv, "true") == 0
                || strcasecmp(streamEnv, "yes") == 0
                || strcasecmp(streamEnv, "on") == 0) {
                streamOn = YES;
            }
        }
        if (streamOn) {
            NSDictionary *streamResult = z_decode_v2_via_native_streaming(
                p + body_off + 0, body_len,
                (int32_t)numQ, n_padded,
                readLengths, revcompFlags,
                qbits, pbits, sloc,
                n_active, active_ctxs, freq_tables);
            if (streamResult) {
                free(active_ctxs);
                for (size_t i = 0; i < n_active; i++) free(freq_tables[i]);
                free(freq_tables);
                return streamResult;
            }
            // Fall through to pure-ObjC decoder on streaming failure.
        }
    }
#endif

    // Build per-ctx lookup arrays (freq + cum) indexed by sparse ctx id.
    int32_t n_contexts = 1 << sloc;
    uint16_t **freq_by_ctx = (uint16_t **)calloc(n_contexts, sizeof(uint16_t *));
    uint32_t **cum_by_ctx  = (uint32_t **)calloc(n_contexts, sizeof(uint32_t *));
    if (!freq_by_ctx || !cum_by_ctx) {
        free(freq_by_ctx); free(cum_by_ctx);
        free(active_ctxs);
        for (size_t i = 0; i < n_active; i++) free(freq_tables[i]);
        free(freq_tables);
        z_set_error(error, 226, @"M94Z V2 decoder: per-ctx alloc failed");
        return nil;
    }
    uint32_t *cum_storage = (uint32_t *)calloc(n_active * 257, sizeof(uint32_t));
    if (!cum_storage) {
        free(freq_by_ctx); free(cum_by_ctx);
        free(active_ctxs);
        for (size_t i = 0; i < n_active; i++) free(freq_tables[i]);
        free(freq_tables);
        z_set_error(error, 227, @"M94Z V2 decoder: cum_storage alloc failed");
        return nil;
    }
    for (size_t i = 0; i < n_active; i++) {
        uint32_t c = active_ctxs[i];
        if (c >= (uint32_t)n_contexts) {
            free(cum_storage);
            free(freq_by_ctx); free(cum_by_ctx);
            free(active_ctxs);
            for (size_t j = 0; j < n_active; j++) free(freq_tables[j]);
            free(freq_tables);
            z_set_error(error, 228, @"M94Z V2 decoder: ctx %u out of range",
                        (unsigned)c);
            return nil;
        }
        freq_by_ctx[c] = freq_tables[i];
        uint32_t *cum = cum_storage + i * 257;
        cum[0] = 0;
        for (int k = 0; k < 256; k++) cum[k + 1] = cum[k] + (uint32_t)freq_tables[i][k];
        cum_by_ctx[c] = cum;
    }

    NSMutableData *outQ = [NSMutableData dataWithLength:(NSUInteger)numQ];
    uint8_t *outBuf = (uint8_t *)outQ.mutableBytes;

    uint32_t pad_ctx = z_context(0, 0, 0, qbits, pbits, sloc);
    int32_t shift = qbits / 3;
    if (shift < 1) shift = 1;
    uint32_t qmask_local = ((uint32_t)1 << qbits) - 1;
    uint32_t shift_mask = ((uint32_t)1 << shift) - 1;

    int32_t read_idx = 0;
    int32_t pos_in_read = 0;
    int32_t cur_read_len = (numR > 0)
                           ? (int32_t)[readLengths[0] unsignedLongLongValue]
                           : 0;
    uint32_t cur_revcomp = (numR > 0)
                           ? (uint32_t)([revcompFlags[0] unsignedIntegerValue] & 1u)
                           : 0;
    int32_t cumulative_read_end = cur_read_len;
    uint32_t prev_q = 0;

    int rc = -1;

    for (int32_t i = 0; i < n_padded; i++) {
        int s_idx = i & 3;
        uint32_t ctx;
        if (i < (int32_t)numQ) {
            if (i >= cumulative_read_end && read_idx < (int32_t)numR - 1) {
                read_idx++;
                pos_in_read = 0;
                cur_read_len = (int32_t)[readLengths[read_idx] unsignedLongLongValue];
                cur_revcomp = (uint32_t)(
                    [revcompFlags[read_idx] unsignedIntegerValue] & 1u);
                cumulative_read_end += cur_read_len;
                prev_q = 0;
            }
            uint32_t pb = z_pos_bucket(pos_in_read, cur_read_len, pbits);
            ctx = z_context(prev_q, pb, cur_revcomp & 1, qbits, pbits, sloc);
        } else {
            ctx = pad_ctx;
        }

        const uint16_t *freq = freq_by_ctx[ctx];
        const uint32_t *cum  = cum_by_ctx[ctx];
        if (!freq) {
            z_set_error(error, 229,
                @"M94Z V2 decoder: ctx %u not in freq_tables", (unsigned)ctx);
            goto v2_cleanup;
        }

        uint32_t x = state[s_idx];
        uint32_t slot = x & (uint32_t)kZ_T_MASK;

        // bisect_right(cum, slot) - 1: linear scan from top is fine
        // for small symbol set; matches V1 decoder pattern.
        int sym = 255;
        while (sym > 0 && cum[sym] > slot) sym--;
        uint32_t f = (uint32_t)freq[sym];
        uint32_t c = cum[sym];
        x = f * (x >> kZ_T_BITS) + slot - c;
        // Renormalise.
        while (x < (uint32_t)kZ_L) {
            uint32_t lp = lane_pos[s_idx];
            if (lp + 2 > lane_bytes[s_idx]) {
                z_set_error(error, 230,
                    @"M94Z V2: lane %d exhausted at i=%d (pos=%u, len=%u)",
                    s_idx, i, (unsigned)lp, (unsigned)lane_bytes[s_idx]);
                goto v2_cleanup;
            }
            uint32_t chunk = (uint32_t)lane_base[s_idx][lp]
                             | ((uint32_t)lane_base[s_idx][lp + 1] << 8);
            lane_pos[s_idx] = lp + 2;
            x = (x << kZ_B_BITS) | chunk;
        }
        state[s_idx] = x;

        if (i < (int32_t)numQ) {
            outBuf[i] = (uint8_t)sym;
            prev_q = ((prev_q << shift) | ((uint32_t)sym & shift_mask))
                       & qmask_local;
            pos_in_read++;
        }
        // Else: padding — symbol decoded but not stored.
    }

    // Sanity: post-decode states must equal L (encoder's initial state).
    for (int k = 0; k < 4; k++) {
        if (state[k] != (uint32_t)kZ_L) {
            z_set_error(error, 231,
                @"M94Z V2: post-decode state[%d]=%u != L=%u; stream is corrupt",
                k, (unsigned)state[k], (unsigned)kZ_L);
            goto v2_cleanup;
        }
        if (lane_pos[k] != lane_bytes[k]) {
            z_set_error(error, 232,
                @"M94Z V2: lane %d consumed %u of %u bytes; stream may be malformed",
                k, (unsigned)lane_pos[k], (unsigned)lane_bytes[k]);
            goto v2_cleanup;
        }
    }
    rc = 0;

v2_cleanup:
    free(cum_storage);
    free(freq_by_ctx); free(cum_by_ctx);
    free(active_ctxs);
    for (size_t i = 0; i < n_active; i++) free(freq_tables[i]);
    free(freq_tables);
    if (rc != 0) return nil;

    return @{
        @"qualities": outQ,
        @"readLengths": readLengths,
    };
}

// ── Top-level encode / decode ────────────────────────────────────

@implementation TTIOFqzcompNx16Z

+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                    error:(NSError * _Nullable *)error
{
    return [self encodeWithQualities:qualities
                          readLengths:readLengths
                         revcompFlags:revcompFlags
                              options:nil
                                error:error];
}

+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                  options:(nullable NSDictionary<NSString *, id> *)options
                                    error:(NSError * _Nullable *)error
{
    if (qualities == nil) {
        z_set_error(error, 100, @"qualities must not be nil");
        return nil;
    }
    if (readLengths.count != revcompFlags.count) {
        z_set_error(error, 101,
            @"readLengths.count (%lu) != revcompFlags.count (%lu)",
            (unsigned long)readLengths.count, (unsigned long)revcompFlags.count);
        return nil;
    }
    uint64_t total = 0;
    NSUInteger nReads = readLengths.count;
    int32_t *rls = (int32_t *)malloc(sizeof(int32_t) * (nReads ?: 1));
    int8_t  *rcs = (int8_t  *)malloc(sizeof(int8_t)  * (nReads ?: 1));
    if (!rls || !rcs) {
        free(rls); free(rcs);
        z_set_error(error, 102, @"alloc failed");
        return nil;
    }
    for (NSUInteger i = 0; i < nReads; i++) {
        uint32_t v = (uint32_t)[readLengths[i] unsignedLongLongValue];
        rls[i] = (int32_t)v;
        total += v;
        rcs[i] = ([revcompFlags[i] unsignedIntegerValue] & 1u) ? 1 : 0;
    }
    if (total != qualities.length) {
        free(rls); free(rcs);
        z_set_error(error, 103,
            @"sum(readLengths) (%llu) != qualities.length (%lu)",
            (unsigned long long)total, (unsigned long)qualities.length);
        return nil;
    }

    int32_t qbits = kZ_DEFAULT_QBITS;
    int32_t pbits = kZ_DEFAULT_PBITS;
    int32_t dbits = kZ_DEFAULT_DBITS;
    int32_t sloc  = kZ_DEFAULT_SLOC;

    // ── V2 native dispatch decision ────────────────────────────────
    BOOL preferNative = NO;
    BOOL preferNativeSet = NO;
    if (options != nil) {
        id v = options[@"preferNative"];
        if ([v isKindOfClass:[NSNumber class]]) {
            preferNative = [(NSNumber *)v boolValue];
            preferNativeSet = YES;
        }
    }
    if (!preferNativeSet) {
        const char *envc = getenv("TTIO_M94Z_USE_NATIVE");
        if (envc && envc[0]) {
            // Lower-case compare against "1", "true", "yes", "on".
            // Use NSString for trimming + case-insensitive compare.
            NSString *envStr = [[NSString stringWithUTF8String:envc]
                stringByTrimmingCharactersInSet:
                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
            NSString *lower = [envStr lowercaseString];
            if ([lower isEqualToString:@"1"] || [lower isEqualToString:@"true"]
                || [lower isEqualToString:@"yes"] || [lower isEqualToString:@"on"]) {
                preferNative = YES;
            }
        }
    }
#if TTIO_HAS_NATIVE_RANS
    if (preferNative) {
        NSData *v2 = z_encode_v2_native(
            (const uint8_t *)qualities.bytes, (int32_t)qualities.length,
            readLengths,
            rls, (int32_t)nReads, rcs,
            qbits, pbits, dbits, sloc,
            error);
        free(rls); free(rcs);
        return v2;  // nil on failure (error set by helper)
    }
#else
    (void)preferNative;
#endif

    uint8_t **streams = NULL;
    uint32_t stream_lens[4] = { 0, 0, 0, 0 };
    uint32_t state_init[4]  = { 0, 0, 0, 0 };
    uint32_t state_final[4] = { 0, 0, 0, 0 };
    uint32_t *active_ctxs = NULL;
    uint16_t **freq_tables = NULL;
    size_t n_active = 0;

    int rc = z_encode_full(
        (const uint8_t *)qualities.bytes, (int32_t)qualities.length,
        rls, (int32_t)nReads, rcs,
        qbits, pbits, sloc,
        &streams, stream_lens,
        state_init, state_final,
        &active_ctxs, &freq_tables, &n_active,
        error);
    free(rls);
    free(rcs);
    if (rc != 0) return nil;

    int32_t n = (int32_t)qualities.length;
    int32_t pad_count = (-n) & 3;

    // Build the deflated read-length-table sidecar.
    NSData *rlt = z_encode_read_lengths(readLengths);
    if (!rlt) {
        z_set_error(error, 104, @"M94Z: rlt deflate failed");
        for (int s = 0; s < 4; s++) free(streams[s]);
        free(streams);
        free(active_ctxs);
        for (size_t i = 0; i < n_active; i++) free(freq_tables[i]);
        free(freq_tables);
        return nil;
    }

    // Build the deflated freq-tables sidecar.
    NSData *ft_blob = z_serialize_freq_tables(active_ctxs, n_active,
                                                freq_tables, sloc);
    free(active_ctxs);
    for (size_t i = 0; i < n_active; i++) free(freq_tables[i]);
    free(freq_tables);
    if (!ft_blob) {
        z_set_error(error, 105, @"M94Z: freq_tables deflate failed");
        for (int s = 0; s < 4; s++) free(streams[s]);
        free(streams);
        return nil;
    }

    // Compute body size.
    NSUInteger body_size = 16;
    for (int s = 0; s < 4; s++) body_size += stream_lens[s];

    NSUInteger header_size = (NSUInteger)kZ_HEADER_FIXED_PREFIX
                               + (NSUInteger)rlt.length
                               + (NSUInteger)ft_blob.length
                               + (NSUInteger)kZ_STATE_INIT_SIZE;

    NSUInteger total_size = header_size + body_size + (NSUInteger)kZ_TRAILER_SIZE;
    NSMutableData *out = [NSMutableData dataWithLength:total_size];
    uint8_t *p = (uint8_t *)out.mutableBytes;

    uint8_t flagsByte = (uint8_t)((pad_count & 0x3) << 4);

    memcpy(p, kZ_MAGIC, 4); p += 4;
    *p++ = (uint8_t)kZ_VERSION;
    *p++ = flagsByte;
    le_pack_u64(p, (uint64_t)qualities.length); p += 8;
    le_pack_u32(p, (uint32_t)nReads);          p += 4;
    le_pack_u32(p, (uint32_t)rlt.length);      p += 4;
    // context_params (8 bytes): qbits, pbits, dbits, sloc, 4 pad
    *p++ = (uint8_t)(qbits & 0xFF);
    *p++ = (uint8_t)(pbits & 0xFF);
    *p++ = (uint8_t)(dbits & 0xFF);
    *p++ = (uint8_t)(sloc  & 0xFF);
    memset(p, 0, 4); p += 4;
    le_pack_u32(p, (uint32_t)ft_blob.length); p += 4;
    if (rlt.length) memcpy(p, rlt.bytes, rlt.length);
    p += rlt.length;
    if (ft_blob.length) memcpy(p, ft_blob.bytes, ft_blob.length);
    p += ft_blob.length;
    le_pack_u32(p +  0, state_init[0]);
    le_pack_u32(p +  4, state_init[1]);
    le_pack_u32(p +  8, state_init[2]);
    le_pack_u32(p + 12, state_init[3]);
    p += 16;
    // Body: 16 bytes substream lengths, then concatenated streams.
    le_pack_u32(p +  0, stream_lens[0]);
    le_pack_u32(p +  4, stream_lens[1]);
    le_pack_u32(p +  8, stream_lens[2]);
    le_pack_u32(p + 12, stream_lens[3]);
    p += 16;
    for (int s = 0; s < 4; s++) {
        if (stream_lens[s]) memcpy(p, streams[s], stream_lens[s]);
        p += stream_lens[s];
    }
    // Trailer.
    le_pack_u32(p +  0, state_final[0]);
    le_pack_u32(p +  4, state_final[1]);
    le_pack_u32(p +  8, state_final[2]);
    le_pack_u32(p + 12, state_final[3]);

    for (int s = 0; s < 4; s++) free(streams[s]);
    free(streams);
    return out;
}

+ (nullable NSDictionary *)decodeData:(NSData *)data
                                 error:(NSError * _Nullable *)error
{
    return [self decodeData:data revcompFlags:nil error:error];
}

+ (nullable NSDictionary *)decodeData:(NSData *)data
                          revcompFlags:(nullable NSArray<NSNumber *> *)revcompFlags
                                 error:(NSError * _Nullable *)error
{
    if (data == nil) {
        z_set_error(error, 200, @"data must not be nil");
        return nil;
    }
    // Need enough bytes to read magic + version byte before dispatching.
    if (data.length < 5) {
        z_set_error(error, 201, @"M94Z: encoded too short (%lu bytes)",
                    (unsigned long)data.length);
        return nil;
    }
    const uint8_t *p = (const uint8_t *)data.bytes;
    if (memcmp(p, kZ_MAGIC, 4) != 0) {
        z_set_error(error, 202,
            @"M94Z: bad magic %02x %02x %02x %02x (expected M94Z)",
            p[0], p[1], p[2], p[3]);
        return nil;
    }
    uint8_t version = p[4];
    // ── V2 dispatch (Task 23, option E: pure-ObjC decoder) ──
    if (version == kZ_VERSION_V2_NATIVE) {
        return z_decode_v2(data, revcompFlags, error);
    }
    if (version != kZ_VERSION) {
        z_set_error(error, 203, @"M94Z: unsupported version 0x%02x", version);
        return nil;
    }
    // V1: re-validate full minimum length.
    if (data.length < kZ_HEADER_FIXED_PREFIX + kZ_STATE_INIT_SIZE + kZ_TRAILER_SIZE) {
        z_set_error(error, 201, @"M94Z: encoded too short (%lu bytes)",
                    (unsigned long)data.length);
        return nil;
    }
    uint8_t flags = p[5];
    uint64_t numQ = le_read_u64(p + 6);
    uint32_t numR = le_read_u32(p + 14);
    uint32_t rlt_len = le_read_u32(p + 18);
    int32_t qbits = (int32_t)p[22];
    int32_t pbits = (int32_t)p[23];
    // dbits = p[24]; ignored (must be 0 for v1)
    int32_t sloc  = (int32_t)p[25];
    // p[26..29] reserved/pad
    uint32_t ft_len = le_read_u32(p + 30);

    int32_t pad_count = (flags >> 4) & 0x3;

    NSUInteger header_end = (NSUInteger)kZ_HEADER_FIXED_PREFIX
                              + (NSUInteger)rlt_len
                              + (NSUInteger)ft_len
                              + (NSUInteger)kZ_STATE_INIT_SIZE;
    if (data.length < header_end + kZ_TRAILER_SIZE) {
        z_set_error(error, 204,
            @"M94Z: header size %lu + trailer exceeds data length %lu",
            (unsigned long)header_end, (unsigned long)data.length);
        return nil;
    }
    NSData *rltData    = [data subdataWithRange:NSMakeRange(34, rlt_len)];
    NSData *ftBlobData = [data subdataWithRange:NSMakeRange(34 + rlt_len, ft_len)];
    uint32_t state_init[4];
    state_init[0] = le_read_u32(p + 34 + rlt_len + ft_len + 0);
    state_init[1] = le_read_u32(p + 34 + rlt_len + ft_len + 4);
    state_init[2] = le_read_u32(p + 34 + rlt_len + ft_len + 8);
    state_init[3] = le_read_u32(p + 34 + rlt_len + ft_len + 12);

    NSError *rltErr = nil;
    NSArray<NSNumber *> *readLengths = z_decode_read_lengths(rltData, numR, &rltErr);
    if (!readLengths) {
        if (error) *error = rltErr;
        return nil;
    }

    if (revcompFlags == nil) {
        NSMutableArray *zeros = [NSMutableArray arrayWithCapacity:numR];
        for (uint32_t i = 0; i < numR; i++) [zeros addObject:@0];
        revcompFlags = zeros;
    } else if (revcompFlags.count != numR) {
        z_set_error(error, 210,
            @"revcompFlags.count %lu != num_reads %u",
            (unsigned long)revcompFlags.count, numR);
        return nil;
    }

    uint64_t n_padded64 = numQ + (uint64_t)pad_count;
    if (n_padded64 & 3) {
        z_set_error(error, 211,
            @"M94Z: n_padded %llu not a multiple of 4 (numQ=%llu, pad=%d)",
            (unsigned long long)n_padded64, (unsigned long long)numQ, pad_count);
        return nil;
    }
    int32_t n_padded = (int32_t)n_padded64;

    // Body parse.
    NSUInteger trailerOff = data.length - kZ_TRAILER_SIZE;
    if (trailerOff < header_end) {
        z_set_error(error, 212, @"M94Z: trailer overlaps header");
        return nil;
    }
    if (trailerOff - header_end < 16) {
        z_set_error(error, 213, @"M94Z: body too short for substream lengths");
        return nil;
    }
    uint32_t sub_lens[4];
    sub_lens[0] = le_read_u32(p + header_end + 0);
    sub_lens[1] = le_read_u32(p + header_end + 4);
    sub_lens[2] = le_read_u32(p + header_end + 8);
    sub_lens[3] = le_read_u32(p + header_end + 12);
    NSUInteger body_payload_off = header_end + 16;
    NSUInteger want_payload = (NSUInteger)sub_lens[0] + sub_lens[1]
                              + sub_lens[2] + sub_lens[3];
    if (body_payload_off + want_payload != trailerOff) {
        z_set_error(error, 214,
            @"M94Z: substream length sum %lu != body payload len %lu",
            (unsigned long)want_payload,
            (unsigned long)(trailerOff - body_payload_off));
        return nil;
    }
    const uint8_t *streams[4];
    NSUInteger cursor = body_payload_off;
    for (int s = 0; s < 4; s++) {
        streams[s] = p + cursor;
        cursor += sub_lens[s];
    }

    uint32_t state_final[4];
    state_final[0] = le_read_u32(p + trailerOff + 0);
    state_final[1] = le_read_u32(p + trailerOff + 4);
    state_final[2] = le_read_u32(p + trailerOff + 8);
    state_final[3] = le_read_u32(p + trailerOff + 12);

    // Deserialize freq tables.
    size_t n_active = 0;
    uint32_t *active_ctxs = NULL;
    uint16_t **freq_tables = NULL;
    NSError *ftErr = nil;
    if (z_deserialize_freq_tables(ftBlobData, &n_active, &active_ctxs,
                                    &freq_tables, &ftErr) != 0) {
        if (error) *error = ftErr;
        return nil;
    }

    // Build read-length / revcomp arrays.
    int32_t *rls = (int32_t *)malloc(sizeof(int32_t) * (numR ?: 1));
    int8_t  *rcs = (int8_t  *)malloc(sizeof(int8_t)  * (numR ?: 1));
    if (!rls || !rcs) {
        free(rls); free(rcs);
        free(active_ctxs);
        for (size_t i = 0; i < n_active; i++) free(freq_tables[i]);
        free(freq_tables);
        z_set_error(error, 215, @"alloc failed");
        return nil;
    }
    for (uint32_t i = 0; i < numR; i++) {
        rls[i] = (int32_t)[readLengths[i] unsignedLongLongValue];
        rcs[i] = ([revcompFlags[i] unsignedIntegerValue] & 1u) ? 1 : 0;
    }

    NSMutableData *outQ = [NSMutableData dataWithLength:(NSUInteger)numQ];
    int rc = z_decode_full(streams, sub_lens, state_init, state_final,
                              (int32_t)numQ, n_padded,
                              rls, (int32_t)numR, rcs,
                              active_ctxs, freq_tables, n_active,
                              qbits, pbits, sloc,
                              (uint8_t *)outQ.mutableBytes, error);
    free(rls); free(rcs);
    free(active_ctxs);
    for (size_t i = 0; i < n_active; i++) free(freq_tables[i]);
    free(freq_tables);
    if (rc != 0) return nil;

    return @{
        @"qualities": outQ,
        @"readLengths": readLengths,
    };
}

// ── Backend introspection (Task 17, Phase B) ─────────────────────────
// Mirrors Python's get_backend_name() and Java's FqzcompNx16Z.getBackendName().
// The native library is currently exposed for direct use only; the V1
// encode/decode dispatch above is unchanged.

+ (NSString *)backendName
{
#if TTIO_HAS_NATIVE_RANS
    const char *kernel = ttio_rans_kernel_name();
    if (kernel == NULL || kernel[0] == '\0') {
        return @"native-unknown";
    }
    return [NSString stringWithFormat:@"native-%s", kernel];
#else
    return @"pure-objc";
#endif
}

@end
