/*
 * rans_o0.c -- Plain rANS-O0 encode/decode, byte-exact port of
 *             python/src/ttio/codecs/_rans/_rans.pyx (order-0 path)
 *             and the Java/ObjC equivalents.
 *
 * Algorithm parameters (must match rans.py / _rans.pyx):
 *   M       = 1 << 12 = 4096   (total normalised frequency)
 *   M_BITS  = 12
 *   M_MASK  = M - 1
 *   L       = 1 << 23          (state lower bound)
 *   R_BASE  = L >> M_BITS = 1 << 11
 *   B_BITS  = 8
 *   B       = 1 << 8 = 256    (renorm chunk = 1 byte)
 *   x_max(f) = R_BASE * B * f = (1 << 19) * f
 *   state width: uint64_t (64-bit unsigned)
 *   initial x  = L
 *   encode order: REVERSE (last input byte first)
 *
 * Wire format (big-endian):
 *   [0]       1     order byte    = 0x00
 *   [1..4]    4     orig_len      uint32 BE
 *   [5..8]    4     payload_len   uint32 BE
 *   [9..1032] 1024  freq table    256 x uint32 BE
 *   [1033..]  var   payload:
 *               4 bytes: final encoder state BE
 *               var: renorm byte stream (read forward at decode)
 *
 * Empty input (orig_len == 0):
 *   freq table = [16] * 256  (flat, sums to 4096)
 *   payload    = L in 4 bytes BE = 00 80 00 00
 *   Total wire = 9 + 1024 + 4 = 1037 bytes.
 */

#include <stdint.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>

#include "ttio_rans.h"

/* Algorithm constants */
#define O0_M_BITS   12u
#define O0_M        (1u << O0_M_BITS)       /* 4096 */
#define O0_M_MASK   (O0_M - 1u)
#define O0_L        ((uint64_t)1u << 23)    /* 8388608 */
#define O0_R_BASE   ((uint64_t)1u << 11)    /* L >> M_BITS */
#define O0_XMAX(f)  (O0_R_BASE * (uint64_t)256u * (uint64_t)(f))

#define O0_HEADER_LEN   9u
#define O0_FREQ_LEN     (256u * 4u)          /* 1024 bytes */
#define O0_MIN_WIRE     (O0_HEADER_LEN + O0_FREQ_LEN + 4u)  /* 1037 */

/*
 * _normalise_freqs: byte-exact port of _normalise_freqs_c in _rans.pyx
 * (lines 42-153).
 *
 * Steps:
 *   1. f[s] = max(1, cnt[s] * M / total)  for cnt[s] > 0, else 0
 *   2. delta = M - sum(f)
 *   3. delta > 0: stable insertion sort by (-cnt[s], +s), round-robin +1
 *   4. delta < 0: stable insertion sort by (+cnt[s], +s), round-robin -1,
 *      skipping freq==1; return -1 if stuck.
 *
 * The insertion sort is STABLE and matches Python's stable sort exactly.
 */
static int _normalise_freqs(const int32_t cnt[256], int32_t freq[256])
{
    int64_t total = 0;
    int32_t s, i, j, delta;
    int32_t order_buf[256];
    int32_t n_eligible;
    int32_t tmp_s;

    for (s = 0; s < 256; s++)
        total += cnt[s];
    if (total <= 0)
        return -1;

    /* Step 1: proportional scale, clamp to >=1 for any cnt > 0 */
    for (s = 0; s < 256; s++) {
        if (cnt[s] > 0) {
            int64_t scaled = ((int64_t)cnt[s] * (int64_t)O0_M) / total;
            freq[s] = (int32_t)(scaled >= 1 ? scaled : 1);
        } else {
            freq[s] = 0;
        }
    }

    /* delta = M - sum(freq) */
    delta = (int32_t)O0_M;
    for (s = 0; s < 256; s++)
        delta -= freq[s];

    if (delta == 0)
        return 0;

    /* Build eligible list: only symbols with cnt > 0 */
    n_eligible = 0;
    for (s = 0; s < 256; s++) {
        if (cnt[s] > 0)
            order_buf[n_eligible++] = s;
    }

    if (delta > 0) {
        /*
         * Sort by descending cnt, ascending s (stable insertion sort).
         * Verbatim port of Cython lines 98-111.
         *
         * Cython:
         *   while j > 0:
         *       if cnt[order_buf[j-1]] < cnt[tmp_s]: swap, j--
         *       elif cnt[order_buf[j-1]] == cnt[tmp_s] and order_buf[j-1] > tmp_s: swap, j--
         *       else: break
         */
        for (i = 1; i < n_eligible; i++) {
            tmp_s = order_buf[i];
            j = i;
            while (j > 0) {
                int32_t prev = order_buf[j - 1];
                if (cnt[prev] < cnt[tmp_s]) {
                    order_buf[j] = prev;
                    j--;
                } else if (cnt[prev] == cnt[tmp_s] && prev > tmp_s) {
                    order_buf[j] = prev;
                    j--;
                } else {
                    break;
                }
            }
            order_buf[j] = tmp_s;
        }
        /* Round-robin +1 */
        {
            int32_t idx = 0;
            while (delta > 0) {
                freq[order_buf[idx % n_eligible]] += 1;
                idx++;
                delta--;
            }
        }
    } else {
        /*
         * Sort by ascending cnt, ascending s (stable insertion sort).
         * Verbatim port of Cython lines 124-137.
         *
         * Cython:
         *   while j > 0:
         *       if cnt[order_buf[j-1]] > cnt[tmp_s]: swap, j--
         *       elif cnt[order_buf[j-1]] == cnt[tmp_s] and order_buf[j-1] > tmp_s: swap, j--
         *       else: break
         */
        for (i = 1; i < n_eligible; i++) {
            tmp_s = order_buf[i];
            j = i;
            while (j > 0) {
                int32_t prev = order_buf[j - 1];
                if (cnt[prev] > cnt[tmp_s]) {
                    order_buf[j] = prev;
                    j--;
                } else if (cnt[prev] == cnt[tmp_s] && prev > tmp_s) {
                    order_buf[j] = prev;
                    j--;
                } else {
                    break;
                }
            }
            order_buf[j] = tmp_s;
        }
        /* Round-robin -1, skipping freq==1 */
        {
            int32_t idx = 0;
            int32_t guard = 0;
            while (delta < 0) {
                s = order_buf[idx % n_eligible];
                if (freq[s] > 1) {
                    freq[s] -= 1;
                    delta++;
                    guard = 0;
                } else {
                    guard++;
                    if (guard > n_eligible)
                        return -1;
                }
                idx++;
            }
        }
    }

    return 0;
}

static void _cumulative(const int32_t freq[256], int32_t cum[257])
{
    int32_t s, running = 0;
    for (s = 0; s < 256; s++) {
        cum[s] = running;
        running += freq[s];
    }
    cum[256] = running;
}

static void _slot_to_symbol(const int32_t freq[256], uint8_t table[4096])
{
    int32_t s, pos = 0;
    for (s = 0; s < 256; s++) {
        int32_t f = freq[s];
        int32_t jj;
        for (jj = 0; jj < f; jj++)
            table[pos + jj] = (uint8_t)s;
        pos += f;
    }
}

static inline void write_u32_be(uint8_t *p, uint32_t v)
{
    p[0] = (uint8_t)((v >> 24) & 0xFF);
    p[1] = (uint8_t)((v >> 16) & 0xFF);
    p[2] = (uint8_t)((v >>  8) & 0xFF);
    p[3] = (uint8_t)( v        & 0xFF);
}

static inline uint32_t read_u32_be(const uint8_t *p)
{
    return ((uint32_t)p[0] << 24)
         | ((uint32_t)p[1] << 16)
         | ((uint32_t)p[2] <<  8)
         |  (uint32_t)p[3];
}

/* Public: max encoded size */
size_t ttio_rans_o0_max_encoded_size(size_t in_len)
{
    /*
     * Header (9) + freq table (1024) + payload.
     * Payload = 4 (final state) + at most in_len renorm bytes + 64 slop.
     */
    return O0_HEADER_LEN + O0_FREQ_LEN + 4 + in_len + 64;
}

/* Public: encode */
int ttio_rans_o0_encode(
    const uint8_t *in,
    size_t         in_len,
    uint8_t       *out,
    size_t        *out_len)
{
    if (!out || !out_len)
        return TTIO_RANS_ERR_PARAM;
    if (in_len > 0 && !in)
        return TTIO_RANS_ERR_PARAM;

    size_t cap = *out_len;
    if (cap < O0_MIN_WIRE)
        return TTIO_RANS_ERR_PARAM;

    /* Empty input path */
    if (in_len == 0) {
        if (cap < 1037u)
            return TTIO_RANS_ERR_PARAM;
        uint8_t *p = out;
        p[0] = 0x00;                   /* order = 0 */
        write_u32_be(p + 1, 0u);       /* orig_len = 0 */
        write_u32_be(p + 5, 4u);       /* payload_len = 4 */
        p += 9;
        /* freq table: 256 x 16 */
        {
            int s;
            for (s = 0; s < 256; s++) {
                write_u32_be(p, 16u);
                p += 4;
            }
        }
        /* payload: L = 1<<23 = 0x00800000 */
        write_u32_be(p, (uint32_t)O0_L);
        p += 4;
        *out_len = (size_t)(p - out);
        return TTIO_RANS_OK;
    }

    /* Count occurrences */
    int32_t cnt[256];
    memset(cnt, 0, sizeof(cnt));
    {
        size_t ii;
        for (ii = 0; ii < in_len; ii++)
            cnt[in[ii]]++;
    }

    /* Normalise */
    int32_t freq[256];
    if (_normalise_freqs(cnt, freq) != 0)
        return TTIO_RANS_ERR_PARAM;

    /* Cumulative */
    int32_t cum[257];
    _cumulative(freq, cum);

    /* Per-symbol x_max threshold */
    uint64_t x_max_sym[256];
    {
        int s;
        for (s = 0; s < 256; s++)
            x_max_sym[s] = O0_XMAX(freq[s]);
    }

    /*
     * Encode in REVERSE: last byte of input first.
     * Renorm bytes accumulate LIFO in a dynamic buffer.
     */
    size_t renorm_cap = in_len + 16;
    uint8_t *renorm = (uint8_t *)malloc(renorm_cap);
    if (!renorm)
        return TTIO_RANS_ERR_ALLOC;

    size_t renorm_len = 0;
    uint64_t x = O0_L;

    {
        size_t ii;
        for (ii = in_len; ii > 0; ii--) {
            uint8_t sym = in[ii - 1];
            uint64_t xm = x_max_sym[(int)sym];
            while (x >= xm) {
                if (renorm_len >= renorm_cap) {
                    renorm_cap *= 2;
                    uint8_t *tmp = (uint8_t *)realloc(renorm, renorm_cap);
                    if (!tmp) { free(renorm); return TTIO_RANS_ERR_ALLOC; }
                    renorm = tmp;
                }
                renorm[renorm_len++] = (uint8_t)(x & 0xFF);
                x >>= 8;
            }
            x = (x / (uint64_t)freq[(int)sym]) * (uint64_t)O0_M
              + (x % (uint64_t)freq[(int)sym])
              + (uint64_t)cum[(int)sym];
        }
    }

    size_t payload_len = 4 + renorm_len;
    size_t total_len   = O0_HEADER_LEN + O0_FREQ_LEN + payload_len;
    if (total_len > cap) {
        free(renorm);
        return TTIO_RANS_ERR_PARAM;
    }

    /* Compose wire */
    {
        int s;
        uint8_t *p = out;
        p[0] = 0x00;
        write_u32_be(p + 1, (uint32_t)in_len);
        write_u32_be(p + 5, (uint32_t)payload_len);
        p += 9;

        for (s = 0; s < 256; s++) {
            write_u32_be(p, (uint32_t)freq[s]);
            p += 4;
        }

        /* Final state BE */
        write_u32_be(p, (uint32_t)x);
        p += 4;

        /* Renorm bytes in reverse-of-emission order (LIFO -> FIFO) */
        {
            size_t k;
            for (k = renorm_len; k > 0; k--)
                *p++ = renorm[k - 1];
        }
    }

    free(renorm);
    *out_len = total_len;
    return TTIO_RANS_OK;
}

/* Public: decode */
int ttio_rans_o0_decode(
    const uint8_t *in,
    size_t         in_len,
    uint8_t       *out,
    size_t         out_capacity,
    size_t        *out_len)
{
    if (!in || !out_len)
        return TTIO_RANS_ERR_PARAM;

    if (in_len < O0_MIN_WIRE)
        return TTIO_RANS_ERR_CORRUPT;

    if (in[0] != 0x00)
        return TTIO_RANS_ERR_CORRUPT;   /* order must be 0 */

    uint32_t orig_len_u32 = read_u32_be(in + 1);
    uint32_t payload_len  = read_u32_be(in + 5);
    size_t   orig_len     = (size_t)orig_len_u32;

    /* Validate sizes */
    if ((size_t)(O0_HEADER_LEN + O0_FREQ_LEN) + (size_t)payload_len != in_len)
        return TTIO_RANS_ERR_CORRUPT;
    if (payload_len < 4)
        return TTIO_RANS_ERR_CORRUPT;

    /* Read and validate freq table */
    int32_t freq[256];
    {
        int s;
        const uint8_t *fp = in + O0_HEADER_LEN;
        uint32_t freq_sum = 0;
        for (s = 0; s < 256; s++) {
            freq[s] = (int32_t)read_u32_be(fp + s * 4);
            freq_sum += (uint32_t)freq[s];
        }
        if (freq_sum != O0_M)
            return TTIO_RANS_ERR_CORRUPT;
    }

    if (orig_len == 0) {
        *out_len = 0;
        return TTIO_RANS_OK;
    }

    if (!out || out_capacity < orig_len)
        return TTIO_RANS_ERR_PARAM;

    /* Build cumulative table and slot->symbol decode table */
    int32_t cum[257];
    _cumulative(freq, cum);

    uint8_t slot_table[4096];  /* M = 4096 */
    _slot_to_symbol(freq, slot_table);

    /* Bootstrap state from first 4 bytes of payload */
    const uint8_t *payload = in + O0_HEADER_LEN + O0_FREQ_LEN;
    size_t plen = (size_t)payload_len;
    uint64_t x = (uint64_t)read_u32_be(payload);
    size_t pos = 4;

    /* Decode loop */
    {
        size_t ii;
        for (ii = 0; ii < orig_len; ii++) {
            uint32_t slot = (uint32_t)(x & (uint64_t)O0_M_MASK);
            uint8_t sym = slot_table[slot];
            out[ii] = sym;
            x = (uint64_t)freq[(int)sym] * (x >> O0_M_BITS)
              + (uint64_t)slot
              - (uint64_t)cum[(int)sym];
            while (x < O0_L) {
                if (pos >= plen)
                    return TTIO_RANS_ERR_CORRUPT;
                x = (x << 8) | (uint64_t)payload[pos++];
            }
        }
    }

    *out_len = orig_len;
    return TTIO_RANS_OK;
}
