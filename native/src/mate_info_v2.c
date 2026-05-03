#include "mate_info_v2.h"
#include "../include/ttio_rans.h"

#include <string.h>

/* ── varint (LEB128, little-endian base-128) ───────────────────── */

size_t miv2_varint_encode(uint64_t value, uint8_t *out) {
    size_t i = 0;
    while (value >= 0x80) {
        out[i++] = (uint8_t)(value | 0x80);
        value >>= 7;
    }
    out[i++] = (uint8_t)value;
    return i;
}

int miv2_varint_decode(const uint8_t *in, size_t in_len, uint64_t *out_value, size_t *out_consumed) {
    uint64_t result = 0;
    size_t i = 0;
    int shift = 0;
    while (i < in_len) {
        uint8_t b = in[i++];
        result |= ((uint64_t)(b & 0x7F)) << shift;
        if ((b & 0x80) == 0) {
            *out_value = result;
            *out_consumed = i;
            return 0;
        }
        shift += 7;
        if (shift >= 64) return TTIO_RANS_ERR_CORRUPT;  /* overflow */
    }
    return TTIO_RANS_ERR_CORRUPT;  /* ran out of bytes */
}

/* ── zigzag for int64 ──────────────────────────────────────────── */

uint64_t miv2_zigzag_encode_64(int64_t value) {
    return ((uint64_t)value << 1) ^ (uint64_t)(value >> 63);
}

int64_t miv2_zigzag_decode_64(uint64_t value) {
    return (int64_t)((value >> 1) ^ -(int64_t)(value & 1));
}

/* Stub: full encoder/decoder follows in Task 3. Defining the public
 * entry points so the library links during incremental development. */

size_t ttio_mate_info_v2_max_encoded_size(uint64_t n_records) {
    /* Worst case bound: container header + 1 byte/record raw MF
     * + 10 bytes/record max varint NP + 10 bytes/record max zigzag TS
     * + 10 bytes/record NS (assume all CROSS_CHROM)
     * + 16 bytes for rANS framing overhead per substream. */
    return 34 + (size_t)n_records * 31 + 64;
}

int ttio_mate_info_v2_encode(
    const int32_t  *mate_chrom_ids,
    const int64_t  *mate_positions,
    const int32_t  *template_lengths,
    const uint16_t *own_chrom_ids,
    const int64_t  *own_positions,
    uint64_t        n_records,
    uint8_t        *out,
    size_t         *out_len)
{
    (void)mate_chrom_ids; (void)mate_positions; (void)template_lengths;
    (void)own_chrom_ids; (void)own_positions; (void)n_records;
    (void)out; (void)out_len;
    return TTIO_RANS_ERR_PARAM;  /* Task 3 will replace this */
}

int ttio_mate_info_v2_decode(
    const uint8_t  *encoded,
    size_t          encoded_size,
    const uint16_t *own_chrom_ids,
    const int64_t  *own_positions,
    uint64_t        n_records,
    int32_t        *out_mate_chrom_ids,
    int64_t        *out_mate_positions,
    int32_t        *out_template_lengths)
{
    (void)encoded; (void)encoded_size; (void)own_chrom_ids;
    (void)own_positions; (void)n_records;
    (void)out_mate_chrom_ids; (void)out_mate_positions; (void)out_template_lengths;
    return TTIO_RANS_ERR_PARAM;
}
