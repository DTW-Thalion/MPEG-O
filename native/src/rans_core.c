#include "ttio_rans.h"
#include <string.h>

void ttio_rans_build_decode_table(
    uint16_t        n_contexts,
    const uint32_t (*freq)[256],
    const uint32_t (*cum)[256],
    uint8_t        (*dtab)[TTIO_RANS_T])
{
    for (uint16_t ctx = 0; ctx < n_contexts; ctx++) {
        memset(dtab[ctx], 0, TTIO_RANS_T);
        for (int sym = 0; sym < 256; sym++) {
            uint32_t f = freq[ctx][sym];
            uint32_t c = cum[ctx][sym];
            for (uint32_t s = 0; s < f; s++) {
                dtab[ctx][c + s] = (uint8_t)sym;
            }
        }
    }
}
