#ifndef TTIO_MATE_INFO_V2_INTERNAL_H
#define TTIO_MATE_INFO_V2_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

/* Container layout constants (spec §4.3) */
#define MIV2_MAGIC      "MIv2"
#define MIV2_MAGIC_LEN  4
#define MIV2_VERSION    0x01
#define MIV2_HEADER_SIZE 34   /* 4 + 1 + 1 + 8 + 4 + 16 */

/* MF taxonomy (spec §4.4) */
#define MIV2_MF_SAME_CHROM   0
#define MIV2_MF_CROSS_CHROM  1
#define MIV2_MF_NO_MATE      2
#define MIV2_MF_RESERVED     3   /* must never be emitted */

/* MF substream leading-byte selector (spec §4.5) */
#define MIV2_MF_RAW_PACK   0x00
#define MIV2_MF_RANS_O0    0x01

/* Sentinel values */
#define MIV2_OWN_UNMAPPED  0xFFFFu  /* uint16 sentinel for own_chrom_id == -1 */

/* Internal helpers — exposed for tests only. */
size_t miv2_varint_encode(uint64_t value, uint8_t *out);
int    miv2_varint_decode(const uint8_t *in, size_t in_len, uint64_t *out_value, size_t *out_consumed);

uint64_t miv2_zigzag_encode_64(int64_t value);
int64_t  miv2_zigzag_decode_64(uint64_t value);

#endif /* TTIO_MATE_INFO_V2_INTERNAL_H */
