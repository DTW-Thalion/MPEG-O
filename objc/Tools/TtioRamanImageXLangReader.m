/*
 * TtioRamanImageXLangReader.m — CLI for cross-language conformance.
 *
 * Reads a .tio's TTIORamanImage.wavenumbers and writes the bytes to
 * stdout in little-endian float64. Used by
 * python/tests/conformance/test_raman_image_xlang.py.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Image/TTIORamanImage.h"
#include <stdio.h>

int main(int argc, const char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: TtioRamanImageXLangReader <path.tio>\n");
        return 2;
    }
    @autoreleasepool {
        NSError *err = nil;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        TTIORamanImage *img = [TTIORamanImage readFromFilePath:path error:&err];
        if (img == nil || img.wavenumbers == nil) {
            fprintf(stderr, "no RamanImage or wavenumbers in %s\n", argv[1]);
            return 3;
        }
        fwrite(img.wavenumbers.bytes, 1, img.wavenumbers.length, stdout);
        fflush(stdout);
    }
    return 0;
}
