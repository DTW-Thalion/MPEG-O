#ifndef TTIO_REF_DIFF_V2_INTERNAL_H
#define TTIO_REF_DIFF_V2_INTERNAL_H

#include <stddef.h>
#include <stdint.h>

/* Outer container constants (spec §4.3) */
#define RDV2_MAGIC       "RDF2"
#define RDV2_MAGIC_LEN   4
#define RDV2_VERSION     0x01
#define RDV2_OUTER_FIXED 38   /* 4 + 1 + 3 + 4 + 8 + 16 + 2 */
#define RDV2_SLICE_INDEX_ENTRY 32  /* same as v1 */

/* Slice body sub-header (spec §4.4): 6 × u32 LE */
#define RDV2_SLICE_SUBHDR 24

/* Substream IDs for ESC (spec §4.9) */
#define RDV2_ESC_BS 0
#define RDV2_ESC_IN 1
#define RDV2_ESC_SC 2

/* 2-bit ACGT mapping (spec §4.6) */
#define RDV2_BASE_A 0
#define RDV2_BASE_C 1
#define RDV2_BASE_G 2
#define RDV2_BASE_T 3
#define RDV2_BASE_INVALID 0xFF

/* Internal helpers exposed for tests only. */
uint8_t rdv2_base_to_2bit(uint8_t base);   /* returns 0..3 or 0xFF if non-ACGT */
uint8_t rdv2_2bit_to_base(uint8_t code);   /* code in 0..3 → 'A'/'C'/'G'/'T' */

/* Cigar parsing — returns # of M/=/X bases, # of I bases, # of S bases.
 * Returns 0 on success, -1 on malformed cigar. */
int rdv2_parse_cigar_counts(const char *cigar,
                            uint64_t *out_match_count,
                            uint64_t *out_ins_count,
                            uint64_t *out_sc_count);

/* 2-bit pack/unpack helpers. */
size_t rdv2_pack_2bit(const uint8_t *codes, uint64_t n_codes, uint8_t *out);
void   rdv2_unpack_2bit(const uint8_t *in, uint64_t n_codes, uint8_t *out_codes);

#endif /* TTIO_REF_DIFF_V2_INTERNAL_H */
