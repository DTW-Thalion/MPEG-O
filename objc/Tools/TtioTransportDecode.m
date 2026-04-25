/*
 * TtioTransportDecode — v0.10 M70.
 *
 * Decode an TTI-O transport stream into a .tio file. Parallel to
 * Python ttio.tools.transport_decode_cli and Java
 * com.dtwthalion.ttio.tools.TransportDecodeCli.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Transport/TTIOTransportReader.h"
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: TtioTransportDecode <input.tis> <output.tio>\n");
            return 2;
        }
        NSString *input = [NSString stringWithUTF8String:argv[1]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithInputPath:input];
        NSError *err = nil;
        BOOL ok = [tr writeTtioToPath:output error:&err];
        if (!ok) {
            fprintf(stderr, "decode failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
    }
    return 0;
}
