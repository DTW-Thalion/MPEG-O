/*
 * TtioTransportEncode — v0.10 M70.
 *
 * Encode a .tio file as an TTI-O transport stream. Parallel to
 * Python ttio.tools.transport_encode_cli and Java
 * com.dtwthalion.ttio.tools.TransportEncodeCli.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Transport/TTIOTransportWriter.h"
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: TtioTransportEncode <input.tio> <output.tis>\n");
            return 2;
        }
        NSString *input = [NSString stringWithUTF8String:argv[1]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        NSError *err = nil;
        TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:input error:&err];
        if (!ds) {
            fprintf(stderr, "open failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithOutputPath:output];
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
