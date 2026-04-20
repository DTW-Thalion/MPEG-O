/*
 * MpgoTransportEncode — v0.10 M70.
 *
 * Encode a .mpgo file as an MPEG-O transport stream. Parallel to
 * Python mpeg_o.tools.transport_encode_cli and Java
 * com.dtwthalion.mpgo.tools.TransportEncodeCli.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Dataset/MPGOSpectralDataset.h"
#import "Transport/MPGOTransportWriter.h"
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: MpgoTransportEncode <input.mpgo> <output.mots>\n");
            return 2;
        }
        NSString *input = [NSString stringWithUTF8String:argv[1]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        NSError *err = nil;
        MPGOSpectralDataset *ds = [MPGOSpectralDataset readFromFilePath:input error:&err];
        if (!ds) {
            fprintf(stderr, "open failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
        MPGOTransportWriter *tw = [[MPGOTransportWriter alloc] initWithOutputPath:output];
        BOOL ok = [tw writeDataset:ds error:&err];
        [tw close];
        if (!ok) {
            fprintf(stderr, "encode failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
    }
    return 0;
}
