#ifndef TTIO_RANS_H
#define TTIO_RANS_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define TTIO_RANS_L       (1u << 15)
#define TTIO_RANS_B_BITS  16
#define TTIO_RANS_B       (1u << 16)
#define TTIO_RANS_B_MASK  (TTIO_RANS_B - 1)
#define TTIO_RANS_T       (1u << 12)
#define TTIO_RANS_T_BITS  12
#define TTIO_RANS_T_MASK  (TTIO_RANS_T - 1)
#define TTIO_RANS_STREAMS 4
#define TTIO_RANS_X_MAX_PREFACTOR  ((TTIO_RANS_L >> TTIO_RANS_T_BITS) << TTIO_RANS_B_BITS)

#define TTIO_RANS_OK           0
#define TTIO_RANS_ERR_PARAM   -1
#define TTIO_RANS_ERR_ALLOC   -2
#define TTIO_RANS_ERR_CORRUPT -3

typedef struct ttio_rans_pool ttio_rans_pool;

int ttio_rans_encode_block(
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    uint8_t        *out,
    size_t         *out_len
);

int ttio_rans_decode_block(
    const uint8_t  *compressed,
    size_t          comp_len,
    const uint16_t *contexts,
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    const uint8_t  (*dtab)[TTIO_RANS_T],
    uint8_t        *symbols,
    size_t          n_symbols
);

int ttio_rans_build_decode_table(
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    uint8_t        (*dtab)[TTIO_RANS_T]
);

ttio_rans_pool *ttio_rans_pool_create(int n_threads);

int ttio_rans_encode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *symbols,
    const uint16_t *contexts,
    size_t          n_symbols,
    uint16_t        n_contexts,
    size_t          reads_per_block,
    const size_t   *read_lengths,
    size_t          n_reads,
    uint8_t        *out,
    size_t         *out_len
);

int ttio_rans_decode_mt(
    ttio_rans_pool *pool,
    const uint8_t  *compressed,
    size_t          comp_len,
    uint8_t        *symbols,
    size_t         *n_symbols
);

void ttio_rans_pool_destroy(ttio_rans_pool *pool);

/* Diagnostic: name of the kernel selected at library-load time by cpuid
 * dispatch.  Returns a pointer to a static string — one of
 * "scalar", "sse4.1", "avx2".  Never returns NULL. */
const char *ttio_rans_kernel_name(void);

#ifdef __cplusplus
}
#endif

#endif /* TTIO_RANS_H */
