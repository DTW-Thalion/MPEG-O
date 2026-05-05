/*
 * TtioTransportEncode — v0.10 M70.
 *
 * Encode a .tio file as an TTI-O transport stream. Parallel to
 * Python ttio.tools.transport_encode_cli and Java
 * global.thalion.ttio.tools.TransportEncodeCli.
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
        // Parse positional + flag args. Accepts --bulk (Phase 2c-T).
        const char *input = NULL;
        const char *output = NULL;
        BOOL bulk = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--bulk") == 0) { bulk = YES; continue; }
            if (input == NULL) { input = argv[i]; }
            else if (output == NULL) { output = argv[i]; }
        }
        if (input == NULL || output == NULL) {
            fprintf(stderr, "usage: TtioTransportEncode [--bulk] <input.tio> <output.tis>\n");
            return 2;
        }
        NSString *inputS = [NSString stringWithUTF8String:input];
        NSString *outputS = [NSString stringWithUTF8String:output];
        NSError *err = nil;
        TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:inputS error:&err];
        if (!ds) {
            fprintf(stderr, "open failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithOutputPath:outputS];
        tw.useBulkMode = bulk;
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
