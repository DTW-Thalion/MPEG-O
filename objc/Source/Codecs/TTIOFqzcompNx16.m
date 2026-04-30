/*
 * TTIOFqzcompNx16.m — clean-room FQZCOMP_NX16 lossless quality codec.
 *
 * Mirrors python/src/ttio/codecs/fqzcomp_nx16.py byte-for-byte. See
 * the header for the wire format spec.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import "Codecs/TTIOFqzcompNx16.h"
#import "Codecs/TTIORans.h"

#include <stdint.h>
#include <stdlib.h>
#include <string.h>

NSString * const TTIOFqzcompNx16ErrorDomain = @"TTIOFqzcompNx16Error";

// ── Wire-format / algorithm constants ─────────────────────────────

static const uint8_t kFqzMagic[4]  = { 'F', 'Q', 'Z', 'N' };
static const uint8_t kFqzVersion   = 0x01;

enum {
    kFqzHeaderFixedPrefix       = 22,   // magic..rlt_compressed_len
    kFqzContextModelParamsSize  = 16,
    kFqzStateInitSize           = 16,
    kFqzTrailerSize             = 16,

    kFqzDefaultTableSizeLog2    = 12,
    kFqzDefaultLearningRate     = 16,
    kFqzDefaultMaxCount         = 4096,
    kFqzDefaultFreqTableInit    = 0,
    kFqzNumStreams              = 4,

    // rANS constants — must match TTIORans's M83 implementation.
    kFqzRansMBits  = 12,
    kFqzRansM      = 1 << kFqzRansMBits,           // 4096
    kFqzRansMMask  = kFqzRansM - 1,
    kFqzRansBBits  = 8,
};

#define kFqzDefaultContextHashSeed   0xC0FFEEu

#define kFqzRansL   ((uint64_t)1 << 23)
#define kFqzRansXMaxF(f) (((kFqzRansL >> kFqzRansMBits) << kFqzRansBBits) * (uint64_t)(f))

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

static void fqz_set_error(NSError * _Nullable * _Nullable outError,
                          NSInteger code,
                          NSString *fmt, ...) NS_FORMAT_FUNCTION(3, 4);

static void fqz_set_error(NSError * _Nullable * _Nullable outError,
                          NSInteger code,
                          NSString *fmt, ...)
{
    if (!outError) return;
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    *outError = [NSError errorWithDomain:TTIOFqzcompNx16ErrorDomain
                                    code:code
                                userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// ── Bucketing helpers ─────────────────────────────────────────────

static inline int fqz_position_bucket(int position, int read_length)
{
    if (read_length <= 0) return 0;
    if (position <= 0) return 0;
    if (position >= read_length) return 15;
    int b = (position * 16) / read_length;
    return (b > 15) ? 15 : b;
}

static inline int fqz_length_bucket(int read_length)
{
    if (read_length <= 0) return 0;
    static const int kBounds[7] = { 50, 100, 150, 200, 300, 1000, 10000 };
    for (int i = 0; i < 7; i++) {
        if (read_length < kBounds[i]) return i;
    }
    return 7;
}

// ── Context hash (SplitMix64 finaliser) ───────────────────────────
//
// Cross-language byte-exact contract — ObjC + Python + Java MUST
// produce the same key. uint64_t arithmetic in C is naturally mod
// 2**64; no explicit mask needed (Python uses & 0xFFFFFFFFFFFFFFFF
// only to stay non-negative, and Java masks to defeat its sign bit).

static inline uint64_t fqz_context_hash(uint8_t prev_q0, uint8_t prev_q1,
                                         uint8_t prev_q2, int pos_bucket,
                                         int revcomp, int len_bucket,
                                         uint32_t seed,
                                         int table_size_log2)
{
    uint64_t key = (uint64_t)(prev_q0 & 0xFFu);
    key |= (uint64_t)(prev_q1 & 0xFFu) << 8;
    key |= (uint64_t)(prev_q2 & 0xFFu) << 16;
    key |= (uint64_t)(pos_bucket & 0xF) << 24;
    key |= (uint64_t)(revcomp & 0x1) << 28;
    key |= (uint64_t)(len_bucket & 0x7) << 29;
    key |= (uint64_t)(seed & 0xFFFFFFFFu) << 32;

    key ^= key >> 33;
    key  = key * 0xff51afd7ed558ccdULL;
    key ^= key >> 33;
    key  = key * 0xc4ceb9fe1a85ec53ULL;
    key ^= key >> 33;

    return key & (((uint64_t)1 << table_size_log2) - 1);
}

// ── Adaptive count update (256-entry uint16 table) ────────────────

static inline void fqz_adaptive_update(uint16_t *count, uint8_t symbol,
                                        int learning_rate, int max_count)
{
    int v = (int)count[symbol] + learning_rate;
    if (v > 0xFFFF) v = 0xFFFF;
    count[symbol] = (uint16_t)v;
    if ((int)count[symbol] > max_count) {
        for (int k = 0; k < 256; k++) {
            int h = (int)count[k] >> 1;
            count[k] = (uint16_t)((h >= 1) ? h : 1);
        }
    }
}

// ── Cumulative + slot tables ──────────────────────────────────────

static void fqz_cumulative(const uint16_t freq[256], uint16_t cum[257])
{
    uint16_t s = 0;
    for (int i = 0; i < 256; i++) {
        cum[i] = s;
        s = (uint16_t)(s + freq[i]);
    }
    cum[256] = s;
}

// Fast path when all eligible counts are tied — produces the same
// freq table TTIORansNormaliseFreqs would, in O(256) without the sort.
// Returns 1 if the shortcut applied (freq filled), 0 otherwise (caller
// falls through to the generic normaliser, which also handles errors).
static int fqz_normalise_all_tied(const uint64_t count[256], uint16_t freq[256])
{
    int firstNonzero = -1;
    uint64_t tiedValue = 0;
    int n_eligible = 0;
    for (int s = 0; s < 256; s++) {
        if (count[s] > 0) {
            if (firstNonzero < 0) {
                firstNonzero = s;
                tiedValue = count[s];
            } else if (count[s] != tiedValue) {
                return 0;  // not tied
            }
            n_eligible++;
        }
    }
    if (n_eligible == 0) return 0;
    const int M = kFqzRansM;
    int base = M / n_eligible;
    int remainder = M - base * n_eligible;
    // Zero non-eligible entries first.
    for (int s = 0; s < 256; s++) freq[s] = 0;
    // Distribute base + (1 if i < remainder else 0) in ASCENDING sym
    // order — matches the generic normaliser tie-break (counts tied,
    // so the (key, sym) ordering collapses to ascending sym).
    int idx = 0;
    for (int s = 0; s < 256; s++) {
        if (count[s] > 0) {
            freq[s] = (uint16_t)(base + (idx < remainder ? 1 : 0));
            idx++;
        }
    }
    return 1;
}

// ── Incremental sort-order maintenance for normaliser ─────────────
//
// The legacy hot-path normaliser (TTIORansNormaliseFreqs) qsorts the
// 256-entry count table on every symbol. Profiling showed >85% of CPU
// in qsort + comparator. The Python reference (see
// python/src/ttio/codecs/_fqzcomp_nx16/_fqzcomp_nx16.pyx) keeps a
// per-context (sorted_desc, inv_sort) pair maintained incrementally
// across _adapt calls — bubble-up after each +learning_rate increment,
// full rebuild only on the rare halve event.

// Bubble symbol `sym` up sorted_desc after `count[sym]` was just
// increased. Maintains the (-count, sym_asc) order. O(amortised 1)
// for typical +16 increments; worst case O(n_eligible).
static inline void fqz_bubble_up(uint8_t *sorted_desc, uint8_t *inv_sort,
                                  const uint16_t *count, int sym)
{
    int pos = inv_sort[sym];
    uint16_t cnt_sym = count[sym];
    while (pos > 0) {
        int prev = sorted_desc[pos - 1];
        uint16_t cnt_prev = count[prev];
        // sym belongs BEFORE prev iff cnt_sym > cnt_prev
        // OR (cnt_sym == cnt_prev AND sym < prev)
        if (cnt_sym > cnt_prev || (cnt_sym == cnt_prev && sym < prev)) {
            sorted_desc[pos] = (uint8_t)prev;
            sorted_desc[pos - 1] = (uint8_t)sym;
            inv_sort[prev] = (uint8_t)pos;
            inv_sort[sym] = (uint8_t)(pos - 1);
            pos--;
        } else {
            break;
        }
    }
}

// Rebuild sorted_desc + inv_sort from scratch (used after halve).
// Sort order: descending count, ascending sym tiebreak.
static void fqz_rebuild_sorted_desc(uint8_t *sorted_desc, uint8_t *inv_sort,
                                     const uint16_t *count)
{
    // Insertion sort on uint8_t indices, comparing via count[].
    for (int i = 0; i < 256; i++) sorted_desc[i] = (uint8_t)i;
    for (int i = 1; i < 256; i++) {
        uint8_t s = sorted_desc[i];
        uint16_t cnt_s = count[s];
        int j = i - 1;
        while (j >= 0) {
            uint8_t prev = sorted_desc[j];
            uint16_t cnt_prev = count[prev];
            if (cnt_s > cnt_prev || (cnt_s == cnt_prev && s < prev)) {
                sorted_desc[j + 1] = prev;
                j--;
            } else {
                break;
            }
        }
        sorted_desc[j + 1] = s;
    }
    for (int i = 0; i < 256; i++) inv_sort[sorted_desc[i]] = (uint8_t)i;
}

// Normaliser using maintained sorted_desc. Byte-exact with
// TTIORansNormaliseFreqs for delta>=0; falls back for delta<0 (rare).
// Returns 0 on success, non-zero on error from the fallback path.
static int fqz_normalise_inplace_incremental(const uint16_t *count,
                                              const uint8_t *sorted_desc,
                                              uint16_t *freq)
{
    const uint32_t M = (uint32_t)kFqzRansM;
    uint32_t total = 0;
    for (int s = 0; s < 256; s++) total += count[s];
    if (total == 0) return -1;

    int32_t freq_sum = 0;
    for (int s = 0; s < 256; s++) {
        uint32_t c = count[s];
        if (c > 0) {
            uint32_t scaled = (c * M) / total;
            freq[s] = (uint16_t)(scaled >= 1 ? scaled : 1);
            freq_sum += freq[s];
        } else {
            freq[s] = 0;
        }
    }
    int32_t delta = (int32_t)M - freq_sum;
    if (delta == 0) return 0;
    if (delta > 0) {
        // Distribute +1 round-robin in (descending count, ascending sym) order.
        int i = 0;
        while (delta > 0) {
            freq[sorted_desc[i & 0xFF]] += 1;
            i++;
            delta--;
        }
        return 0;
    }
    // delta < 0: fall back. Convert count to uint64 once for the
    // legacy normaliser. Rare path (typically only on first-touch
    // contexts where all counts are still tied at 1, but the
    // tied-shortcut catches that case before we get here).
    uint64_t cnt_u64[256];
    for (int s = 0; s < 256; s++) cnt_u64[s] = count[s];
    return TTIORansNormaliseFreqs(cnt_u64, freq);
}

// ── Codec header (de)serialisation ────────────────────────────────

@implementation TTIOFqzcompNx16CodecHeader

+ (nullable instancetype)headerFromData:(NSData *)blob
                          bytesConsumed:(NSUInteger *)outConsumed
                                   error:(NSError * _Nullable *)error
{
    if (blob.length < kFqzHeaderFixedPrefix) {
        fqz_set_error(error, 1,
            @"FQZCOMP_NX16 header too short: %lu bytes",
            (unsigned long)blob.length);
        return nil;
    }
    const uint8_t *p = (const uint8_t *)blob.bytes;
    if (memcmp(p, kFqzMagic, 4) != 0) {
        fqz_set_error(error, 2,
            @"FQZCOMP_NX16 bad magic: %02x %02x %02x %02x (expected FQZN)",
            p[0], p[1], p[2], p[3]);
        return nil;
    }
    if (p[4] != kFqzVersion) {
        fqz_set_error(error, 3,
            @"FQZCOMP_NX16 unsupported version: 0x%02x", p[4]);
        return nil;
    }
    uint8_t  flags = p[5];
    if ((flags >> 6) & 0x3) {
        fqz_set_error(error, 4,
            @"FQZCOMP_NX16 reserved flag bits 6-7 must be 0, got 0x%02x",
            flags);
        return nil;
    }
    uint64_t numQ  = le_read_u64(p + 6);
    uint32_t numR  = le_read_u32(p + 14);
    uint32_t rlt   = le_read_u32(p + 18);

    NSUInteger rltEnd = (NSUInteger)kFqzHeaderFixedPrefix + (NSUInteger)rlt;
    NSUInteger needed = rltEnd + kFqzContextModelParamsSize + kFqzStateInitSize;
    if (blob.length < needed) {
        fqz_set_error(error, 5, @"FQZCOMP_NX16 header truncated (need %lu, got %lu)",
            (unsigned long)needed, (unsigned long)blob.length);
        return nil;
    }

    NSData *rltBytes = [blob subdataWithRange:NSMakeRange(kFqzHeaderFixedPrefix, rlt)];
    const uint8_t *cp = p + rltEnd;
    uint8_t  tableLog2 = cp[0];
    uint8_t  lr        = cp[1];
    uint16_t maxCount  = le_read_u16(cp + 2);
    uint8_t  ftInit    = cp[4];
    uint32_t seed      = le_read_u32(cp + 5);
    // cp[9..15] reserved (must be 0)
    const uint8_t *sp = cp + kFqzContextModelParamsSize;
    uint32_t s0 = le_read_u32(sp + 0);
    uint32_t s1 = le_read_u32(sp + 4);
    uint32_t s2 = le_read_u32(sp + 8);
    uint32_t s3 = le_read_u32(sp + 12);

    TTIOFqzcompNx16CodecHeader *h = [[TTIOFqzcompNx16CodecHeader alloc] init];
    h->_flags                = flags;
    h->_numQualities         = numQ;
    h->_numReads             = numR;
    h->_rltCompressedLen     = rlt;
    h->_readLengthTable      = [rltBytes copy];
    h->_contextTableSizeLog2 = tableLog2;
    h->_learningRate         = lr;
    h->_maxCount             = maxCount;
    h->_freqTableInit        = ftInit;
    h->_contextHashSeed      = seed;
    h->_stateInit0           = s0;
    h->_stateInit1           = s1;
    h->_stateInit2           = s2;
    h->_stateInit3           = s3;
    if (outConsumed) *outConsumed = needed;
    return h;
}

@end

// ── Read-length table sidecar ─────────────────────────────────────

static NSData *fqz_encode_read_lengths(NSArray<NSNumber *> *readLengths)
{
    NSUInteger n = readLengths.count;
    NSMutableData *raw = [NSMutableData dataWithLength:n * 4];
    uint8_t *p = (uint8_t *)raw.mutableBytes;
    for (NSUInteger i = 0; i < n; i++) {
        uint32_t v = (uint32_t)[readLengths[i] unsignedLongLongValue];
        le_pack_u32(p + 4 * i, v);
    }
    return TTIORansEncode(raw, 0);
}

static NSArray<NSNumber *> *fqz_decode_read_lengths(NSData *encoded,
                                                     uint32_t numReads,
                                                     NSError **error)
{
    if (numReads == 0) return @[];
    NSError *e = nil;
    NSData *raw = TTIORansDecode(encoded, &e);
    if (!raw) {
        if (error) *error = e ?: [NSError errorWithDomain:TTIOFqzcompNx16ErrorDomain
                                                     code:50
                                                 userInfo:@{NSLocalizedDescriptionKey: @"rlt rANS decode failed"}];
        return nil;
    }
    if (raw.length != (NSUInteger)numReads * 4) {
        fqz_set_error(error, 51,
            @"decode_read_lengths: expected %lu raw bytes, got %lu",
            (unsigned long)numReads * 4, (unsigned long)raw.length);
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

// ── 4-way rANS encoder pass (in C for speed) ──────────────────────
//
// Returns 0 on success; -1 on allocation failure. Writes
// out_body, *out_state_init[4], *out_state_final[4], *out_pad_count.
// The body buffer is malloc'd; caller frees.
//
// `qualities`/`n_qualities` describes the input; padding bytes (0)
// are inserted up to n_padded = n_qualities + ((-n_qualities) & 3)
// using the all-zero context.

static int fqz_rans_four_way_encode(const uint8_t *qualities, size_t n_qualities,
                                     const uint32_t *read_lengths, size_t n_reads,
                                     const uint8_t *revcomp_flags,
                                     int table_size_log2,
                                     int learning_rate,
                                     int max_count,
                                     uint32_t seed,
                                     uint8_t **out_body, size_t *out_body_len,
                                     uint32_t out_state_init[4],
                                     uint32_t out_state_final[4],
                                     int *out_pad_count)
{
    size_t n = n_qualities;
    size_t pad_count = (size_t)((-(int64_t)n) & 3);
    size_t n_padded = n + pad_count;

    size_t n_contexts = (size_t)1 << table_size_log2;
    uint16_t **ctx_counts      = (uint16_t **)calloc(n_contexts, sizeof(uint16_t *));
    uint8_t  **ctx_sorted_desc = (uint8_t  **)calloc(n_contexts, sizeof(uint8_t  *));
    uint8_t  **ctx_inv_sort    = (uint8_t  **)calloc(n_contexts, sizeof(uint8_t  *));
    if (!ctx_counts || !ctx_sorted_desc || !ctx_inv_sort) {
        free(ctx_counts); free(ctx_sorted_desc); free(ctx_inv_sort);
        return -1;
    }

    uint16_t *snap_f = (uint16_t *)calloc(n_padded, sizeof(uint16_t));
    uint16_t *snap_c = (uint16_t *)calloc(n_padded, sizeof(uint16_t));
    if (!snap_f || !snap_c) {
        free(snap_f); free(snap_c);
        for (size_t i = 0; i < n_contexts; i++) {
            free(ctx_counts[i]);
            free(ctx_sorted_desc[i]);
            free(ctx_inv_sort[i]);
        }
        free(ctx_counts); free(ctx_sorted_desc); free(ctx_inv_sort);
        return -1;
    }

    // Padding context (all-zero context vector).
    uint64_t pad_ctx = fqz_context_hash(0, 0, 0, 0, 0, 0, seed, table_size_log2);

    size_t read_idx = 0;
    int pos_in_read = 0;
    int cur_read_len = (n_reads > 0) ? (int)read_lengths[0] : 0;
    int cur_revcomp = (n_reads > 0) ? (int)revcomp_flags[0] : 0;
    size_t cumulative_read_end = (size_t)cur_read_len;
    uint8_t prev_q0 = 0, prev_q1 = 0, prev_q2 = 0;

    // M-normalised freq table reused across the loop (avoid re-alloc).
    uint16_t freq[256];
    uint16_t cum[257];

    for (size_t i = 0; i < n_padded; i++) {
        uint64_t ctx;
        uint8_t sym;
        if (i < n) {
            if (i >= cumulative_read_end &&
                read_idx < n_reads - 1) {
                read_idx++;
                pos_in_read = 0;
                cur_read_len = (int)read_lengths[read_idx];
                cur_revcomp = (int)revcomp_flags[read_idx];
                cumulative_read_end += (size_t)cur_read_len;
                prev_q0 = 0; prev_q1 = 0; prev_q2 = 0;
            }
            int pb = fqz_position_bucket(pos_in_read, cur_read_len);
            int lb = fqz_length_bucket(cur_read_len);
            ctx = fqz_context_hash(prev_q0, prev_q1, prev_q2, pb,
                                    cur_revcomp & 1, lb,
                                    seed, table_size_log2);
            sym = qualities[i];
        } else {
            ctx = pad_ctx;
            sym = 0;
        }

        if (ctx_counts[ctx] == NULL) {
            uint16_t *t  = (uint16_t *)malloc(sizeof(uint16_t) * 256);
            uint8_t  *sd = (uint8_t  *)malloc(sizeof(uint8_t)  * 256);
            uint8_t  *iv = (uint8_t  *)malloc(sizeof(uint8_t)  * 256);
            if (!t || !sd || !iv) { free(t); free(sd); free(iv); goto err; }
            for (int k = 0; k < 256; k++) {
                t[k]  = 1;
                sd[k] = (uint8_t)k;
                iv[k] = (uint8_t)k;
            }
            ctx_counts[ctx]      = t;
            ctx_sorted_desc[ctx] = sd;
            ctx_inv_sort[ctx]    = iv;
        }
        uint16_t *count       = ctx_counts[ctx];
        uint8_t  *sorted_desc = ctx_sorted_desc[ctx];
        uint8_t  *inv_sort    = ctx_inv_sort[ctx];

        // M-normalise count → freq using the maintained sorted_desc
        // (eliminates the per-symbol qsort that dominated profiles).
        if (fqz_normalise_inplace_incremental(count, sorted_desc, freq) != 0) goto err;
        fqz_cumulative(freq, cum);

        snap_f[i] = freq[sym];
        snap_c[i] = cum[sym];

        // Adaptive update with incremental sort-order maintenance.
        // Mirrors fqz_adaptive_update + bubble_up / rebuild semantics.
        int v = (int)count[sym] + learning_rate;
        if (v > 0xFFFF) v = 0xFFFF;
        count[sym] = (uint16_t)v;
        if ((int)count[sym] > max_count) {
            for (int k = 0; k < 256; k++) {
                int h = (int)count[k] >> 1;
                count[k] = (uint16_t)((h >= 1) ? h : 1);
            }
            fqz_rebuild_sorted_desc(sorted_desc, inv_sort, count);
        } else {
            fqz_bubble_up(sorted_desc, inv_sort, count, sym);
        }

        if (i < n) {
            prev_q2 = prev_q1;
            prev_q1 = prev_q0;
            prev_q0 = sym;
            pos_in_read++;
        }
    }

    // ── Reverse rANS encoder pass over each substream. ──
    uint64_t state[4] = { kFqzRansL, kFqzRansL, kFqzRansL, kFqzRansL };
    out_state_init[0] = (uint32_t)state[0];
    out_state_init[1] = (uint32_t)state[1];
    out_state_init[2] = (uint32_t)state[2];
    out_state_init[3] = (uint32_t)state[3];

    // LIFO collected renorm bytes per substream.
    size_t cap[4] = { n_padded / 4 + 64, n_padded / 4 + 64,
                      n_padded / 4 + 64, n_padded / 4 + 64 };
    size_t r[4]   = { 0, 0, 0, 0 };
    uint8_t *renorm[4];
    for (int s = 0; s < 4; s++) {
        renorm[s] = (uint8_t *)malloc(cap[s]);
        if (!renorm[s]) goto err_renorm;
    }

    for (ssize_t i = (ssize_t)n_padded - 1; i >= 0; i--) {
        int sidx = (int)(i & 3);
        uint16_t f = snap_f[i];
        uint16_t c = snap_c[i];
        uint64_t x = state[sidx];
        uint64_t xm = kFqzRansXMaxF(f);
        while (x >= xm) {
            if (r[sidx] >= cap[sidx]) {
                size_t nc = cap[sidx] * 2;
                uint8_t *nb = (uint8_t *)realloc(renorm[sidx], nc);
                if (!nb) goto err_renorm;
                renorm[sidx] = nb;
                cap[sidx] = nc;
            }
            renorm[sidx][r[sidx]++] = (uint8_t)(x & 0xFF);
            x >>= 8;
        }
        x = (x / f) * (uint64_t)kFqzRansM + (x % f) + (uint64_t)c;
        state[sidx] = x;
    }

    out_state_final[0] = (uint32_t)state[0];
    out_state_final[1] = (uint32_t)state[1];
    out_state_final[2] = (uint32_t)state[2];
    out_state_final[3] = (uint32_t)state[3];

    // Reverse each substream's collected renorm bytes (LIFO → emit-order).
    for (int s = 0; s < 4; s++) {
        size_t lo = 0, hi = (r[s] > 0 ? r[s] - 1 : 0);
        while (lo < hi) {
            uint8_t t = renorm[s][lo];
            renorm[s][lo] = renorm[s][hi];
            renorm[s][hi] = t;
            lo++; hi--;
        }
    }

    // Round-robin interleave, zero-padded to max length.
    size_t max_len = 0;
    for (int s = 0; s < 4; s++) if (r[s] > max_len) max_len = r[s];
    size_t body_len = 16 + (size_t)4 * max_len;
    uint8_t *body = (uint8_t *)malloc(body_len);
    if (!body) goto err_renorm;

    le_pack_u32(body + 0,  (uint32_t)r[0]);
    le_pack_u32(body + 4,  (uint32_t)r[1]);
    le_pack_u32(body + 8,  (uint32_t)r[2]);
    le_pack_u32(body + 12, (uint32_t)r[3]);
    size_t off = 16;
    for (size_t j = 0; j < max_len; j++) {
        for (int s = 0; s < 4; s++) {
            body[off++] = (j < r[s]) ? renorm[s][j] : 0;
        }
    }

    for (int s = 0; s < 4; s++) free(renorm[s]);

    free(snap_f); free(snap_c);
    for (size_t i = 0; i < n_contexts; i++) {
        free(ctx_counts[i]);
        free(ctx_sorted_desc[i]);
        free(ctx_inv_sort[i]);
    }
    free(ctx_counts); free(ctx_sorted_desc); free(ctx_inv_sort);

    *out_body = body;
    *out_body_len = body_len;
    *out_pad_count = (int)pad_count;
    return 0;

err_renorm:
    for (int s = 0; s < 4; s++) free(renorm[s]);
err:
    free(snap_f); free(snap_c);
    for (size_t i = 0; i < n_contexts; i++) {
        free(ctx_counts[i]);
        free(ctx_sorted_desc[i]);
        free(ctx_inv_sort[i]);
    }
    free(ctx_counts); free(ctx_sorted_desc); free(ctx_inv_sort);
    return -1;
}

// ── 4-way rANS decoder pass (in C for speed) ──────────────────────

static int fqz_rans_four_way_decode(const uint8_t *body, size_t body_len,
                                     uint32_t state_init[4],
                                     uint32_t state_final[4],
                                     size_t n_qualities, size_t n_padded,
                                     const uint32_t *read_lengths, size_t n_reads,
                                     const uint8_t *revcomp_flags,
                                     int table_size_log2,
                                     int learning_rate,
                                     int max_count,
                                     uint32_t seed,
                                     uint8_t *out_qualities)
{
    if (body_len < 16) return -1;
    uint32_t sub_lens[4];
    sub_lens[0] = le_read_u32(body + 0);
    sub_lens[1] = le_read_u32(body + 4);
    sub_lens[2] = le_read_u32(body + 8);
    sub_lens[3] = le_read_u32(body + 12);
    const uint8_t *payload = body + 16;
    size_t payload_len = body_len - 16;
    size_t max_len = 0;
    for (int s = 0; s < 4; s++) if (sub_lens[s] > max_len) max_len = sub_lens[s];
    if (payload_len < (size_t)4 * max_len) return -1;

    // De-interleave round-robin into per-substream buffers.
    uint8_t *streams[4] = {0};
    for (int s = 0; s < 4; s++) {
        if (sub_lens[s] == 0) { streams[s] = NULL; continue; }
        streams[s] = (uint8_t *)malloc(sub_lens[s]);
        if (!streams[s]) {
            for (int q = 0; q < s; q++) free(streams[q]);
            return -1;
        }
    }
    {
        size_t cursor = 0;
        for (size_t j = 0; j < max_len; j++) {
            for (int s = 0; s < 4; s++) {
                uint8_t b = payload[cursor++];
                if (j < sub_lens[s]) streams[s][j] = b;
            }
        }
    }

    // Decoder context state (mirrors encoder's forward pass).
    size_t n_contexts = (size_t)1 << table_size_log2;
    uint16_t **ctx_counts      = (uint16_t **)calloc(n_contexts, sizeof(uint16_t *));
    uint8_t  **ctx_sorted_desc = (uint8_t  **)calloc(n_contexts, sizeof(uint8_t  *));
    uint8_t  **ctx_inv_sort    = (uint8_t  **)calloc(n_contexts, sizeof(uint8_t  *));
    if (!ctx_counts || !ctx_sorted_desc || !ctx_inv_sort) {
        for (int s = 0; s < 4; s++) free(streams[s]);
        free(ctx_counts); free(ctx_sorted_desc); free(ctx_inv_sort);
        return -1;
    }
    uint64_t pad_ctx = fqz_context_hash(0, 0, 0, 0, 0, 0, seed, table_size_log2);

    size_t read_idx = 0;
    int pos_in_read = 0;
    int cur_read_len = (n_reads > 0) ? (int)read_lengths[0] : 0;
    int cur_revcomp = (n_reads > 0) ? (int)revcomp_flags[0] : 0;
    size_t cumulative_read_end = (size_t)cur_read_len;
    uint8_t prev_q0 = 0, prev_q1 = 0, prev_q2 = 0;

    uint64_t state[4];
    state[0] = state_final[0];
    state[1] = state_final[1];
    state[2] = state_final[2];
    state[3] = state_final[3];
    size_t sub_pos[4] = { 0, 0, 0, 0 };

    uint16_t freq[256];
    uint16_t cum[257];

    int rc = 0;
    for (size_t i = 0; i < n_padded; i++) {
        uint64_t ctx;
        if (i >= n_qualities) {
            ctx = pad_ctx;
        } else {
            if (i >= cumulative_read_end &&
                read_idx < n_reads - 1) {
                read_idx++;
                pos_in_read = 0;
                cur_read_len = (int)read_lengths[read_idx];
                cur_revcomp = (int)revcomp_flags[read_idx];
                cumulative_read_end += (size_t)cur_read_len;
                prev_q0 = 0; prev_q1 = 0; prev_q2 = 0;
            }
            int pb = fqz_position_bucket(pos_in_read, cur_read_len);
            int lb = fqz_length_bucket(cur_read_len);
            ctx = fqz_context_hash(prev_q0, prev_q1, prev_q2, pb,
                                    cur_revcomp & 1, lb,
                                    seed, table_size_log2);
        }

        if (ctx_counts[ctx] == NULL) {
            uint16_t *t  = (uint16_t *)malloc(sizeof(uint16_t) * 256);
            uint8_t  *sd = (uint8_t  *)malloc(sizeof(uint8_t)  * 256);
            uint8_t  *iv = (uint8_t  *)malloc(sizeof(uint8_t)  * 256);
            if (!t || !sd || !iv) { free(t); free(sd); free(iv); rc = -1; goto cleanup; }
            for (int k = 0; k < 256; k++) {
                t[k]  = 1;
                sd[k] = (uint8_t)k;
                iv[k] = (uint8_t)k;
            }
            ctx_counts[ctx]      = t;
            ctx_sorted_desc[ctx] = sd;
            ctx_inv_sort[ctx]    = iv;
        }
        uint16_t *count       = ctx_counts[ctx];
        uint8_t  *sorted_desc = ctx_sorted_desc[ctx];
        uint8_t  *inv_sort    = ctx_inv_sort[ctx];

        if (fqz_normalise_inplace_incremental(count, sorted_desc, freq) != 0) { rc = -1; goto cleanup; }
        fqz_cumulative(freq, cum);

        int sidx = (int)(i & 3);
        uint64_t x = state[sidx];
        uint16_t slot = (uint16_t)(x & kFqzRansMMask);
        // Binary search for largest sym in [0, 256) such that cum[sym] <= slot.
        // Invariant on exit: cum[sym] <= slot < cum[sym+1].
        int lo = 0, hi = 256;
        while (lo < hi) {
            int mid = (lo + hi) >> 1;
            if (cum[mid + 1] <= (uint16_t)slot) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        uint8_t sym = (uint8_t)lo;
        if (i < n_qualities) out_qualities[i] = sym;
        uint16_t f = freq[sym];
        uint16_t c = cum[sym];
        x = (uint64_t)f * (x >> kFqzRansMBits) + (uint64_t)slot - (uint64_t)c;
        while (x < kFqzRansL) {
            if (sub_pos[sidx] >= sub_lens[sidx]) { rc = -1; goto cleanup; }
            x = (x << 8) | (uint64_t)streams[sidx][sub_pos[sidx]];
            sub_pos[sidx]++;
        }
        state[sidx] = x;

        // Adaptive update with incremental sort-order maintenance.
        // Mirrors fqz_adaptive_update + bubble_up / rebuild semantics.
        int v = (int)count[sym] + learning_rate;
        if (v > 0xFFFF) v = 0xFFFF;
        count[sym] = (uint16_t)v;
        if ((int)count[sym] > max_count) {
            for (int k = 0; k < 256; k++) {
                int h = (int)count[k] >> 1;
                count[k] = (uint16_t)((h >= 1) ? h : 1);
            }
            fqz_rebuild_sorted_desc(sorted_desc, inv_sort, count);
        } else {
            fqz_bubble_up(sorted_desc, inv_sort, count, sym);
        }
        if (i < n_qualities) {
            prev_q2 = prev_q1;
            prev_q1 = prev_q0;
            prev_q0 = sym;
            pos_in_read++;
        }
    }

    // Post-decode states must equal encoder's state_init.
    if ((uint32_t)state[0] != state_init[0] ||
        (uint32_t)state[1] != state_init[1] ||
        (uint32_t)state[2] != state_init[2] ||
        (uint32_t)state[3] != state_init[3]) {
        rc = -1;
    }

cleanup:
    for (int s = 0; s < 4; s++) free(streams[s]);
    for (size_t i = 0; i < n_contexts; i++) {
        free(ctx_counts[i]);
        free(ctx_sorted_desc[i]);
        free(ctx_inv_sort[i]);
    }
    free(ctx_counts); free(ctx_sorted_desc); free(ctx_inv_sort);
    return rc;
}

// ── Top-level encode/decode ───────────────────────────────────────

@implementation TTIOFqzcompNx16

+ (nullable NSData *)encodeWithQualities:(NSData *)qualities
                              readLengths:(NSArray<NSNumber *> *)readLengths
                             revcompFlags:(NSArray<NSNumber *> *)revcompFlags
                                    error:(NSError * _Nullable *)error
{
    if (qualities == nil) {
        fqz_set_error(error, 100, @"qualities must not be nil");
        return nil;
    }
    if (readLengths.count != revcompFlags.count) {
        fqz_set_error(error, 101, @"readLengths.count (%lu) != revcompFlags.count (%lu)",
            (unsigned long)readLengths.count, (unsigned long)revcompFlags.count);
        return nil;
    }
    uint64_t total = 0;
    NSUInteger nReads = readLengths.count;
    uint32_t *rls = (uint32_t *)malloc(sizeof(uint32_t) * (nReads ?: 1));
    uint8_t  *rcs = (uint8_t  *)malloc(sizeof(uint8_t)  * (nReads ?: 1));
    if (!rls || !rcs) { free(rls); free(rcs); fqz_set_error(error, 102, @"alloc failed"); return nil; }
    for (NSUInteger i = 0; i < nReads; i++) {
        uint32_t v = (uint32_t)[readLengths[i] unsignedLongLongValue];
        rls[i] = v;
        total += v;
        rcs[i] = ([revcompFlags[i] unsignedIntegerValue] & 1u) ? 1 : 0;
    }
    if (total != qualities.length) {
        free(rls); free(rcs);
        fqz_set_error(error, 103,
            @"sum(readLengths) (%llu) != qualities.length (%lu)",
            (unsigned long long)total, (unsigned long)qualities.length);
        return nil;
    }

    uint8_t *body = NULL;
    size_t body_len = 0;
    uint32_t state_init[4]  = { 0, 0, 0, 0 };
    uint32_t state_final[4] = { 0, 0, 0, 0 };
    int pad_count = 0;
    int rc = fqz_rans_four_way_encode(
        (const uint8_t *)qualities.bytes, qualities.length,
        rls, nReads, rcs,
        kFqzDefaultTableSizeLog2,
        kFqzDefaultLearningRate,
        kFqzDefaultMaxCount,
        kFqzDefaultContextHashSeed,
        &body, &body_len,
        state_init, state_final, &pad_count);
    free(rls);
    free(rcs);
    if (rc != 0) {
        fqz_set_error(error, 110, @"FQZCOMP_NX16 encode failed (alloc or normaliser error)");
        return nil;
    }

    // ── Build header. ──
    NSData *rlt = fqz_encode_read_lengths(readLengths);
    NSUInteger L = rlt.length;
    NSUInteger headerSize = (NSUInteger)kFqzHeaderFixedPrefix + L
                          + kFqzContextModelParamsSize + kFqzStateInitSize;

    uint8_t flagsByte = 0;
    // bits 0..3 set (revcomp/pos/length/prev_q context flags ON by default)
    flagsByte |= 0x0F;
    flagsByte |= (uint8_t)((pad_count & 0x3) << 4);

    NSMutableData *out = [NSMutableData dataWithLength:headerSize + body_len + kFqzTrailerSize];
    uint8_t *p = (uint8_t *)out.mutableBytes;
    memcpy(p, kFqzMagic, 4); p += 4;
    *p++ = kFqzVersion;
    *p++ = flagsByte;
    le_pack_u64(p, (uint64_t)qualities.length); p += 8;
    le_pack_u32(p, (uint32_t)nReads);          p += 4;
    le_pack_u32(p, (uint32_t)L);               p += 4;
    if (L) memcpy(p, rlt.bytes, L);
    p += L;
    // context_model_params
    *p++ = (uint8_t)kFqzDefaultTableSizeLog2;
    *p++ = (uint8_t)kFqzDefaultLearningRate;
    le_pack_u16(p, (uint16_t)kFqzDefaultMaxCount); p += 2;
    *p++ = (uint8_t)kFqzDefaultFreqTableInit;
    le_pack_u32(p, (uint32_t)kFqzDefaultContextHashSeed); p += 4;
    memset(p, 0, 7); p += 7;
    // state_init
    le_pack_u32(p +  0, state_init[0]);
    le_pack_u32(p +  4, state_init[1]);
    le_pack_u32(p +  8, state_init[2]);
    le_pack_u32(p + 12, state_init[3]);
    p += 16;
    // body
    memcpy(p, body, body_len); p += body_len;
    // trailer
    le_pack_u32(p +  0, state_final[0]);
    le_pack_u32(p +  4, state_final[1]);
    le_pack_u32(p +  8, state_final[2]);
    le_pack_u32(p + 12, state_final[3]);

    free(body);
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
        fqz_set_error(error, 200, @"data must not be nil");
        return nil;
    }
    NSError *headerErr = nil;
    NSUInteger headerEnd = 0;
    TTIOFqzcompNx16CodecHeader *h =
        [TTIOFqzcompNx16CodecHeader headerFromData:data
                                      bytesConsumed:&headerEnd
                                              error:&headerErr];
    if (!h) {
        if (error) *error = headerErr;
        return nil;
    }
    uint64_t numQ  = h.numQualities;
    uint32_t numR  = h.numReads;
    int pad_count  = (h.flags >> 4) & 0x3;
    uint64_t n_padded = numQ + (uint64_t)pad_count;
    if (n_padded & 3) {
        fqz_set_error(error, 201,
            @"FQZCOMP_NX16: n_padded %llu not a multiple of 4 (numQ=%llu, pad=%d)",
            (unsigned long long)n_padded, (unsigned long long)numQ, pad_count);
        return nil;
    }
    if (data.length < headerEnd + kFqzTrailerSize) {
        fqz_set_error(error, 202, @"FQZCOMP_NX16: encoded too short for body+trailer");
        return nil;
    }
    NSUInteger trailerOff = data.length - kFqzTrailerSize;
    if (trailerOff < headerEnd) {
        fqz_set_error(error, 203, @"FQZCOMP_NX16: trailer overlaps header");
        return nil;
    }

    NSError *e2 = nil;
    NSArray<NSNumber *> *readLengths =
        fqz_decode_read_lengths(h.readLengthTable, numR, &e2);
    if (!readLengths) { if (error) *error = e2; return nil; }

    if (revcompFlags == nil) {
        NSMutableArray<NSNumber *> *zeros = [NSMutableArray arrayWithCapacity:numR];
        for (uint32_t i = 0; i < numR; i++) [zeros addObject:@0];
        revcompFlags = zeros;
    } else if (revcompFlags.count != numR) {
        fqz_set_error(error, 210,
            @"revcompFlags.count %lu != num_reads %u",
            (unsigned long)revcompFlags.count, numR);
        return nil;
    }

    uint32_t *rls = (uint32_t *)malloc(sizeof(uint32_t) * (numR ?: 1));
    uint8_t  *rcs = (uint8_t  *)malloc(sizeof(uint8_t)  * (numR ?: 1));
    if (!rls || !rcs) { free(rls); free(rcs);
        fqz_set_error(error, 211, @"alloc failed"); return nil; }
    for (uint32_t i = 0; i < numR; i++) {
        rls[i] = (uint32_t)[readLengths[i] unsignedLongLongValue];
        rcs[i] = ([revcompFlags[i] unsignedIntegerValue] & 1u) ? 1 : 0;
    }

    uint32_t state_init[4] = { h.stateInit0, h.stateInit1, h.stateInit2, h.stateInit3 };
    const uint8_t *bp = (const uint8_t *)data.bytes;
    uint32_t state_final[4];
    state_final[0] = le_read_u32(bp + trailerOff + 0);
    state_final[1] = le_read_u32(bp + trailerOff + 4);
    state_final[2] = le_read_u32(bp + trailerOff + 8);
    state_final[3] = le_read_u32(bp + trailerOff + 12);

    NSMutableData *outQ = [NSMutableData dataWithLength:(NSUInteger)numQ];
    int rc = fqz_rans_four_way_decode(
        bp + headerEnd, trailerOff - headerEnd,
        state_init, state_final,
        (size_t)numQ, (size_t)n_padded,
        rls, numR, rcs,
        h.contextTableSizeLog2, h.learningRate, h.maxCount,
        h.contextHashSeed,
        (uint8_t *)outQ.mutableBytes);
    free(rls);
    free(rcs);
    if (rc != 0) {
        fqz_set_error(error, 220, @"FQZCOMP_NX16 decode failed (truncated body or post-decode state mismatch)");
        return nil;
    }
    return @{
        @"qualities": outQ,
        @"readLengths": readLengths,
    };
}

@end
