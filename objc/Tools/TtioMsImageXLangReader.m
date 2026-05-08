/*
 * TtioMsImageXLangReader.m — CLI for cross-language conformance.
 *
 * Reads a .tio's MSImage.mzAxis and writes the bytes to stdout
 * in little-endian float64. Used by
 * python/tests/conformance/test_msimage_xlang.py.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Image/TTIOMSImage.h"
#include <stdio.h>

int main(int argc, const char *argv[])
{
    if (argc != 2) {
        fprintf(stderr, "usage: TtioMsImageXLangReader <path.tio>\n");
        return 2;
    }
    @autoreleasepool {
        NSError *err = nil;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        TTIOMSImage *img = [TTIOMSImage readFromFilePath:path error:&err];
        if (img == nil || img.mzAxis == nil) {
            fprintf(stderr, "no MSImage or mzAxis in %s\n", argv[1]);
            return 3;
        }
        fwrite(img.mzAxis.bytes, 1, img.mzAxis.length, stdout);
        fflush(stdout);
    }
    return 0;
}
