#include "ref_diff_v2.h"
#include "../include/ttio_rans.h"

#include <stdlib.h>
#include <string.h>

/* ── ACGT 2-bit mapping ────────────────────────────────────────── */

uint8_t rdv2_base_to_2bit(uint8_t base) {
    /* upper-case normalisation */
    if (base >= 'a' && base <= 'z') base -= 32;
    switch (base) {
        case 'A': return RDV2_BASE_A;
        case 'C': return RDV2_BASE_C;
        case 'G': return RDV2_BASE_G;
        case 'T': return RDV2_BASE_T;
        default:  return RDV2_BASE_INVALID;
    }
}

uint8_t rdv2_2bit_to_base(uint8_t code) {
    static const uint8_t table[4] = {'A', 'C', 'G', 'T'};
    return (code < 4) ? table[code] : 'N';
}

/* ── 2-bit pack/unpack (LSB-first within byte) ──────────────────── */

size_t rdv2_pack_2bit(const uint8_t *codes, uint64_t n_codes, uint8_t *out) {
    size_t n_bytes = (n_codes + 3) / 4;
    memset(out, 0, n_bytes);
    for (uint64_t i = 0; i < n_codes; i++) {
        size_t byte_idx = i / 4;
        size_t bit_pos = (i % 4) * 2;
        out[byte_idx] |= (uint8_t)((codes[i] & 0x3) << bit_pos);
    }
    return n_bytes;
}

void rdv2_unpack_2bit(const uint8_t *in, uint64_t n_codes, uint8_t *out_codes) {
    for (uint64_t i = 0; i < n_codes; i++) {
        size_t byte_idx = i / 4;
        size_t bit_pos = (i % 4) * 2;
        out_codes[i] = (in[byte_idx] >> bit_pos) & 0x3;
    }
}

/* ── Cigar parser — counts only ─────────────────────────────────── */

int rdv2_parse_cigar_counts(const char *cigar,
                            uint64_t *out_match_count,
                            uint64_t *out_ins_count,
                            uint64_t *out_sc_count) {
    *out_match_count = 0;
    *out_ins_count = 0;
    *out_sc_count = 0;
    if (!cigar) return 0;
    const char *p = cigar;
    while (*p) {
        uint64_t length = 0;
        if (*p < '0' || *p > '9') return -1;
        while (*p >= '0' && *p <= '9') {
            length = length * 10 + (uint64_t)(*p - '0');
            p++;
        }
        char op = *p++;
        switch (op) {
            case 'M': case '=': case 'X':
                *out_match_count += length; break;
            case 'I':
                *out_ins_count += length; break;
            case 'S':
                *out_sc_count += length; break;
            case 'D': case 'N': case 'H': case 'P':
                break;
            default:
                return -1;
        }
    }
    return 0;
}

/* ── Public stubs — full impl in Task 3 ─────────────────────────── */

size_t ttio_ref_diff_v2_max_encoded_size(uint64_t n_reads, uint64_t total_bases) {
    /* Generous bound covering header + slice index + bodies */
    uint64_t n_slices = (n_reads + 9999) / 10000;
    if (n_slices == 0) n_slices = 1;
    return 4096 + 38 + n_slices * (32 + 24 + 4 * 1037 + total_bases / n_slices + 1024);
}

int ttio_ref_diff_v2_encode(
    const ttio_ref_diff_v2_input *in, uint8_t *out, size_t *out_len)
{
    (void)in; (void)out; (void)out_len;
    return TTIO_RANS_ERR_PARAM;
}

int ttio_ref_diff_v2_decode(
    const uint8_t *encoded, size_t encoded_size,
    const int64_t *positions, const char **cigar_strings,
    uint64_t n_reads, const uint8_t *reference, uint64_t reference_length,
    uint8_t *out_sequences, uint64_t *out_offsets)
{
    (void)encoded; (void)encoded_size; (void)positions; (void)cigar_strings;
    (void)n_reads; (void)reference; (void)reference_length;
    (void)out_sequences; (void)out_offsets;
    return TTIO_RANS_ERR_PARAM;
}
