/*
 * TtioVerify — minimal CLI that opens a .tio file and prints a JSON
 * summary suitable for the Python cross-compat test (M16). The output is
 * intentionally a flat, stable shape so the Python harness can parse it
 * without depending on a full ObjC reader.
 *
 * Build with gnustep-make (see GNUmakefile).
 * Usage: TtioVerify <path-to-.tio>
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */

#import <Foundation/Foundation.h>

#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Run/TTIOAcquisitionRun.h"
#import "Run/TTIOSpectrumIndex.h"
#import "Genomics/TTIOGenomicRun.h"

static NSString *JSONEscape(NSString *s)
{
    if (!s) return @"\"\"";
    NSMutableString *out = [NSMutableString stringWithString:@"\""];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        switch (c) {
            case '"':  [out appendString:@"\\\""]; break;
            case '\\': [out appendString:@"\\\\"]; break;
            case '\n': [out appendString:@"\\n"];  break;
            case '\r': [out appendString:@"\\r"];  break;
            case '\t': [out appendString:@"\\t"];  break;
            default:
                if (c < 0x20) [out appendFormat:@"\\u%04x", c];
                else          [out appendFormat:@"%C", c];
        }
    }
    [out appendString:@"\""];
    return out;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc < 2) {
            fprintf(stderr, "usage: TtioVerify <path-to-.tio>\n");
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];

        NSError *err = nil;
        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:path error:&err];
        if (!ds) {
            fprintf(stderr, "TtioVerify: failed to open %s: %s\n",
                    argv[1], err.localizedDescription.UTF8String ?: "");
            return 1;
        }

        NSMutableString *out = [NSMutableString stringWithString:@"{"];
        [out appendFormat:@"\"title\":%@,", JSONEscape(ds.title)];
        [out appendFormat:@"\"isa_investigation_id\":%@,",
            JSONEscape(ds.isaInvestigationId)];

        // MS runs
        [out appendString:@"\"ms_runs\":{"];
        BOOL firstRun = YES;
        NSArray *runNames = [[ds.msRuns allKeys]
            sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *rname in runNames) {
            TTIOAcquisitionRun *run = ds.msRuns[rname];
            if (!firstRun) [out appendString:@","];
            firstRun = NO;
            [out appendFormat:@"%@:{\"spectrum_count\":%lu}",
                JSONEscape(rname), (unsigned long)run.spectrumIndex.count];
        }
        [out appendString:@"},"];

        // Genomic runs (M82.4 cross-language conformance matrix).
        [out appendString:@"\"genomic_runs\":{"];
        BOOL firstGRun = YES;
        NSArray *gRunNames = [[ds.genomicRuns allKeys]
            sortedArrayUsingSelector:@selector(compare:)];
        for (NSString *gname in gRunNames) {
            TTIOGenomicRun *gr = ds.genomicRuns[gname];
            if (!firstGRun) [out appendString:@","];
            firstGRun = NO;
            [out appendFormat:@"%@:{\"read_count\":%lu,"
                              @"\"reference_uri\":%@,"
                              @"\"platform\":%@,"
                              @"\"sample_name\":%@}",
                JSONEscape(gname), (unsigned long)gr.readCount,
                JSONEscape(gr.referenceUri),
                JSONEscape(gr.platform),
                JSONEscape(gr.sampleName)];
        }
        [out appendString:@"},"];

        [out appendFormat:@"\"identification_count\":%lu,",
            (unsigned long)ds.identifications.count];
        [out appendFormat:@"\"quantification_count\":%lu,",
            (unsigned long)ds.quantifications.count];
        [out appendFormat:@"\"provenance_count\":%lu",
            (unsigned long)ds.provenanceRecords.count];
        [out appendString:@"}"];

        puts([out UTF8String]);
        return 0;
    }
}
