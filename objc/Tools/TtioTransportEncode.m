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
#import "Image/TTIOImage.h"
#import "Image/TTIOMSImage.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportPacket.h"
#include <stdio.h>

int main(int argc, const char **argv)
{
    @autoreleasepool {
        // Parse positional + flag args.
        //   --bulk             Phase 2c-T bulk-mode v2 blobs.
        //   --image-processed  Stage 5 / Task 5.6 (Deferral 1):
        //                      emit MSImage via writeImageProcessed
        //                      (sparse wire mode).
        const char *input = NULL;
        const char *output = NULL;
        BOOL bulk = NO;
        BOOL imageProcessed = NO;
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--bulk") == 0) { bulk = YES; continue; }
            if (strcmp(argv[i], "--image-processed") == 0) {
                imageProcessed = YES;
                continue;
            }
            if (input == NULL) { input = argv[i]; }
            else if (output == NULL) { output = argv[i]; }
        }
        if (input == NULL || output == NULL) {
            fprintf(stderr,
                "usage: TtioTransportEncode [--bulk] "
                "[--image-processed] <input.tio> <output.tis>\n");
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
        BOOL ok;
        if (imageProcessed) {
            // Focused affordance for the MS_IMAGE_PROCESSED cross-
            // language accessor cell. Emits a minimal v0.11 stream:
            // stream-header + IMAGE_HEADER (is_continuous=0) + N x
            // IMAGE_PIXEL + END_OF_IMAGE + EOS. Other dataset
            // content is intentionally ignored — this is not a
            // general encode override.
            ok = [tw writeStreamHeaderWithFormatVersion:@"1.2"
                                                    title:(ds.title ?: @"")
                                         isaInvestigation:(ds.isaInvestigationId ?: @"")
                                                 features:@[TTIOTransportV011Feature]
                                                nDatasets:0
                                                    error:&err];
            if (ok) ok = [tw writeImageProcessed:(TTIOMSImage *)[ds imageForKind:TTIOImageKindMS] error:&err];
            if (ok) ok = [tw writeEndOfStreamWithError:&err];
        } else {
            tw.useBulkMode = bulk;
            ok = [tw writeDataset:ds error:&err];
        }
        [tw close];
        if (!ok) {
            fprintf(stderr, "encode failed: %s\n",
                    err.localizedDescription.UTF8String ?: "unknown");
            return 1;
        }
    }
    return 0;
}
