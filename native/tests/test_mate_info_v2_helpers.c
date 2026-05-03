#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mate_info_v2.h"

static void test_varint_roundtrip(uint64_t value) {
    uint8_t buf[16];
    size_t encoded_len = miv2_varint_encode(value, buf);
    assert(encoded_len > 0 && encoded_len <= 10);
    uint64_t decoded;
    size_t consumed;
    int rc = miv2_varint_decode(buf, encoded_len, &decoded, &consumed);
    assert(rc == 0);
    assert(consumed == encoded_len);
    assert(decoded == value);
}

static void test_zigzag_roundtrip(int64_t value) {
    uint64_t z = miv2_zigzag_encode_64(value);
    int64_t back = miv2_zigzag_decode_64(z);
    assert(back == value);
}

int main(void) {
    /* Varint boundary + sample values */
    uint64_t varint_samples[] = {
        0, 1, 127, 128, 255, 256, 16383, 16384,
        (1ULL<<28) - 1, 1ULL<<28, (1ULL<<35) - 1, 1ULL<<35,
        (1ULL<<63) - 1, UINT64_MAX
    };
    for (size_t i = 0; i < sizeof(varint_samples)/sizeof(varint_samples[0]); i++) {
        test_varint_roundtrip(varint_samples[i]);
    }

    /* Zigzag boundary + sample values */
    int64_t zigzag_samples[] = {
        0, 1, -1, 2, -2, 127, -128,
        (int64_t)(1u<<31), -(int64_t)(1u<<31),
        (int64_t)(1ULL<<62), -(int64_t)(1ULL<<62),
        INT64_MAX, INT64_MIN
    };
    for (size_t i = 0; i < sizeof(zigzag_samples)/sizeof(zigzag_samples[0]); i++) {
        test_zigzag_roundtrip(zigzag_samples[i]);
    }

    /* Random samples (deterministic seed) */
    srand(42);
    for (int i = 0; i < 10000; i++) {
        uint64_t v = ((uint64_t)rand() << 32) | (uint32_t)rand();
        test_varint_roundtrip(v);
        int64_t s = (int64_t)v;
        test_zigzag_roundtrip(s);
    }

    /* Specific decoder error: incomplete varint */
    uint8_t bad[] = {0x80, 0x80, 0x80};  /* high bit set on every byte */
    uint64_t out;
    size_t consumed;
    int err = miv2_varint_decode(bad, 3, &out, &consumed);
    assert(err < 0);  /* expect TTIO_RANS_ERR_CORRUPT */

    printf("test_mate_info_v2_helpers: PASS\n");
    return 0;
}
