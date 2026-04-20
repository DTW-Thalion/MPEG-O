/*
 * MpgoTransportDecode — v0.10 M70.
 *
 * Decode an MPEG-O transport stream into a .mpgo file. Parallel to
 * Python mpeg_o.tools.transport_decode_cli and Java
 * com.dtwthalion.mpgo.tools.TransportDecodeCli.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Transport/MPGOTransportReader.h"
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        if (argc < 3) {
            fprintf(stderr, "usage: MpgoTransportDecode <input.mots> <output.mpgo>\n");
            return 2;
        }
        NSString *input = [NSString stringWithUTF8String:argv[1]];
        NSString *output = [NSString stringWithUTF8String:argv[2]];
        MPGOTransportReader *tr = [[MPGOTransportReader alloc] initWithInputPath:input];
        NSError *err = nil;
        BOOL ok = [tr writeMpgoToPath:output error:&err];
        if (!ok) {
            fprintf(stderr, "decode failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
    }
    return 0;
}
