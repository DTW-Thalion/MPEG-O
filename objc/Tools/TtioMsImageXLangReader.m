/*
 * TtioMsImageXLangReader.m --- CLI for cross-language conformance.
 *
 * Reads a .tio MSImage field and writes bytes to stdout
 * in little-endian float64. Used by
 * python/tests/conformance/test_msimage_xlang.py.
 *
 * Usage: TtioMsImageXLangReader path.tio [--field=mz_axis|pixel_size_x|pixel_size_y]
 * Default field is mz_axis.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Image/TTIOMSImage.h"
#include <stdio.h>
#include <string.h>

static void write_double_le(double value)
{
    /* Portable little-endian write of one IEEE-754 double. */
    unsigned char buf[8];
    unsigned long long bits;
    memcpy(&bits, &value, 8);
    buf[0] = (unsigned char)(bits & 0xff);
    buf[1] = (unsigned char)((bits >> 8) & 0xff);
    buf[2] = (unsigned char)((bits >> 16) & 0xff);
    buf[3] = (unsigned char)((bits >> 24) & 0xff);
    buf[4] = (unsigned char)((bits >> 32) & 0xff);
    buf[5] = (unsigned char)((bits >> 40) & 0xff);
    buf[6] = (unsigned char)((bits >> 48) & 0xff);
    buf[7] = (unsigned char)((bits >> 56) & 0xff);
    fwrite(buf, 1, 8, stdout);
}

int main(int argc, const char *argv[])
{
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "usage: TtioMsImageXLangReader <path.tio> [--field=mz_axis|pixel_size_x|pixel_size_y]\n");
        return 2;
    }
    const char *field = "mz_axis";
    if (argc == 3 && strncmp(argv[2], "--field=", 8) == 0) {
        field = argv[2] + 8;
    }
    @autoreleasepool {
        NSError *err = nil;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        TTIOMSImage *img = [TTIOMSImage readFromFilePath:path error:&err];
        if (img == nil) {
            fprintf(stderr, "no MSImage in %s\n", argv[1]);
            return 3;
        }
        if (strcmp(field, "mz_axis") == 0) {
            if (img.mzAxis == nil) {
                fprintf(stderr, "no mzAxis in %s\n", argv[1]);
                return 3;
            }
            fwrite(img.mzAxis.bytes, 1, img.mzAxis.length, stdout);
        } else if (strcmp(field, "pixel_size_x") == 0) {
            write_double_le(img.pixelSizeX);
        } else if (strcmp(field, "pixel_size_y") == 0) {
            write_double_le(img.pixelSizeY);
        } else {
            fprintf(stderr, "unknown field: %s\n", field);
            return 4;
        }
        fflush(stdout);
    }
    return 0;
}
