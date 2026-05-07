/*
 * TtioRefXLangWriter — tio-browser Phase 0 Task 0.6 standalone CLI
 * helper that writes the canonical embedded-reference fixture to a
 * single .tio file.
 *
 * Phase 0 Task 0.12 (tio-browser) upgrades this helper from the
 * direct-graft pattern (used in Task 0.6) to a production-writer
 * path. ObjC has no public "open writable" class method on
 * TTIOSpectralDataset, so the upgrade uses Option A from the task
 * spec: a single empty-read TTIOWrittenGenomicRun carrying
 * `embedReference=YES + referenceChromSeqs=...`, fed to the
 * `+writeMinimalToPath:...:genomicRuns:...error:` overload. Task 0.11
 * softened the embed gate so this path no longer requires
 * libttio_rans — the writer's `_TTIO_M93_EmbedReferences` helper
 * fires purely via HDF5 I/O (mirrored by
 * TTIOReferencesAccessorTests::testEmbedReferencesWithoutNativeLib).
 *
 * Setting `signalCompression:TTIOCompressionNone` side-steps the
 * v1.5 default-codec gate so the empty-quality byte channel doesn't
 * pull in FQZCOMP_NX16_Z.
 *
 * Usage: TtioRefXLangWriter <out.tio>
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "ValueClasses/TTIOEnums.h"
#include <stdio.h>

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: TtioRefXLangWriter <out.tio>\n");
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];

        NSData *chr1 = [@"ACGTACGTACGT"
            dataUsingEncoding:NSASCIIStringEncoding];
        NSData *chr2 = [@"TTTTAAAACCCC"
            dataUsingEncoding:NSASCIIStringEncoding];
        NSDictionary<NSString *, NSData *> *seqs =
            @{@"chr1": chr1, @"chr2": chr2};

        // Empty-read genomic run carrying embedReference=YES drives
        // the canonical writer's embed loop without triggering any
        // native codec. NSData *empty zero-length channels keep
        // every flat-buffer column at length 0.
        NSData *empty = [NSData data];
        TTIOWrittenGenomicRun *g = [[TTIOWrittenGenomicRun alloc]
            initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                       referenceUri:@"xlang-test-v1"
                           platform:@"ILLUMINA"
                         sampleName:@"REF_TEST"
                          positions:empty
                   mappingQualities:empty
                              flags:empty
                          sequences:empty
                          qualities:empty
                            offsets:empty
                            lengths:empty
                             cigars:@[]
                          readNames:@[]
                    mateChromosomes:@[]
                      matePositions:empty
                    templateLengths:empty
                        chromosomes:@[]
                  signalCompression:TTIOCompressionNone];
        g.embedReference = YES;
        g.referenceChromSeqs = seqs;

        NSError *err = nil;
        BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                    title:@"xlang"
                                       isaInvestigationId:@"XLANG001"
                                                   msRuns:@{}
                                              genomicRuns:@{@"g0": g}
                                          identifications:nil
                                          quantifications:nil
                                        provenanceRecords:nil
                                                    error:&err];
        if (!ok) {
            fprintf(stderr, "writeMinimalToPath failed: %s\n",
                    [[err description] UTF8String]);
            return 1;
        }
    }
    return 0;
}
