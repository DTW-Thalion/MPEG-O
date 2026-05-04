#ifndef TTIO_NAME_TOK_V2_INTERNAL_H
#define TTIO_NAME_TOK_V2_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

/* Wire constants per spec §3, §4.1 */
#define NTV2_MAGIC         "NTK2"
#define NTV2_MAGIC_LEN     4
#define NTV2_VERSION       0x01
#define NTV2_POOL_SIZE     8
#define NTV2_BLOCK_SIZE    4096
/* Container header: magic(4) + version(1) + flags(1) + n_reads(4) + n_blocks(2) */
#define NTV2_HEADER_FIXED  12
#define NTV2_FLAG_EMPTY    0x01

/* FLAG values (2-bit) */
#define NTV2_FLAG_DUP   0
#define NTV2_FLAG_MATCH 1
#define NTV2_FLAG_COL   2
#define NTV2_FLAG_VERB  3

/* Substream slots in body order */
#define NTV2_SUB_FLAG       0
#define NTV2_SUB_POOL_IDX   1
#define NTV2_SUB_MATCH_K    2
#define NTV2_SUB_COL_TYPES  3
#define NTV2_SUB_NUM_DELTA  4
#define NTV2_SUB_DICT_CODE  5
#define NTV2_SUB_DICT_LIT   6
#define NTV2_SUB_VERB_LIT   7
#define NTV2_SUB_COUNT      8

/* Per-substream encoding mode */
#define NTV2_MODE_RAW     0x00
#define NTV2_MODE_RANS_O0 0x01

/* Token type */
#define NTV2_TOK_NUM 0
#define NTV2_TOK_STR 1

/* Internal helpers exposed for tests only. */

/* Tokenises a NUL-terminated ASCII name into up to 255 tokens.
 * Returns 0 on success, -1 on non-ASCII or oversize. The numeric
 * criterion mirrors v1 (`name_tokenizer.py:_tokenize`):
 *   - "0" is a valid numeric token (value 0)
 *   - non-zero leading-digit run is numeric
 *   - leading-zero run of length >= 1 absorbs into surrounding string
 * Numeric overflow demotes the run to a string token (absorbed).
 *
 * Output arrays must each hold at least 256 entries.
 * num_values_out is meaningful only for tokens of type NTV2_TOK_NUM.
 */
int ntv2_tokenise(
    const char *name,
    uint8_t  *types_out,
    uint16_t *starts_out,
    uint16_t *lens_out,
    uint8_t  *n_tokens_out,
    uint64_t *num_values_out);

/* MSB-first bit packing helpers. */
size_t ntv2_pack_2bits(const uint8_t *vals, size_t n, uint8_t *out);
void   ntv2_unpack_2bits(const uint8_t *in, size_t n, uint8_t *out);
size_t ntv2_pack_3bits(const uint8_t *vals, size_t n, uint8_t *out);
void   ntv2_unpack_3bits(const uint8_t *in, size_t n, uint8_t *out);

/* LEB128 varints. Encode functions return # bytes written.
 * Decode functions return # bytes read. */
size_t ntv2_uvarint_encode(uint64_t v, uint8_t *out);
size_t ntv2_uvarint_decode(const uint8_t *in, uint64_t *v);
size_t ntv2_svarint_encode(int64_t v, uint8_t *out);
size_t ntv2_svarint_decode(const uint8_t *in, int64_t *v);

#endif /* TTIO_NAME_TOK_V2_INTERNAL_H */
