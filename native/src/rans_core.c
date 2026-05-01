#include "ttio_rans.h"
#include <string.h>

int ttio_rans_build_decode_table(
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    uint8_t        (*dtab)[TTIO_RANS_T])
{
    for (uint16_t ctx = 0; ctx < n_contexts; ctx++) {
        memset(dtab[ctx], 0, TTIO_RANS_T);
        uint32_t running = 0;
        for (int sym = 0; sym < 256; sym++) {
            uint32_t f = freq[ctx][sym];
            uint32_t c = cum[ctx][sym];
            /* Guard: cumulative + freq must not exceed T */
            if (f > 0 && c + f > TTIO_RANS_T)
                return TTIO_RANS_ERR_PARAM;
            running += f;
            for (uint32_t s = 0; s < f; s++) {
                dtab[ctx][c + s] = (uint8_t)sym;
            }
        }
        /* Guard total sum must not exceed T */
        if (running > TTIO_RANS_T)
            return TTIO_RANS_ERR_PARAM;
    }
    return TTIO_RANS_OK;
}
