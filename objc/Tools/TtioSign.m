/*
 * TtioSign — minimal CLI that signs a dataset inside a .tio file with
 * the v0.3 canonical HMAC-SHA256 path. Used by the M18 Python parity
 * test to prove that a dataset signed by ObjC verifies cleanly from
 * Python (and therefore that the two canonical serializers agree on
 * byte layout).
 *
 * Usage: TtioSign <path-to-.tio> <dataset-path> <key-hex>
 *   key-hex is 64 hexadecimal characters (32 bytes).
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>
#import "HDF5/TTIOHDF5File.h"
#import "Protection/TTIOSignatureManager.h"

static NSData *dataFromHex(const char *hex)
{
    size_t n = strlen(hex);
    if (n % 2 != 0) return nil;
    NSMutableData *out = [NSMutableData dataWithLength:n / 2];
    uint8_t *p = out.mutableBytes;
    for (size_t i = 0; i < n / 2; i++) {
        unsigned byte;
        if (sscanf(hex + 2 * i, "%2x", &byte) != 1) return nil;
        p[i] = (uint8_t)byte;
    }
    return out;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 4) {
            fprintf(stderr, "usage: TtioSign <path> <dataset-path> <key-hex>\n");
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSString *dsetPath = [NSString stringWithUTF8String:argv[2]];
        NSData *key = dataFromHex(argv[3]);
        if (!key || key.length != 32) {
            fprintf(stderr, "TtioSign: expected 64-character hex key\n");
            return 2;
        }

        NSError *err = nil;
        BOOL ok = [TTIOSignatureManager signDataset:dsetPath
                                              inFile:path
                                             withKey:key
                                               error:&err];
        if (!ok) {
            fprintf(stderr, "TtioSign: sign failed: %s\n",
                    err.localizedDescription.UTF8String ?: "(no description)");
            return 1;
        }
        return 0;
    }
}
