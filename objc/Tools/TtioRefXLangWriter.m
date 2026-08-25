/*
 * TtioRefXLangWriter — standalone CLI helper that writes the
 * canonical embedded-reference fixture to a single .tio file.
 *
 * Drives the production writable-open path (M100): write a minimal
 * dataset, reopen it with
 * +[TTIOSpectralDataset readFromFilePath:writable:error:], then
 * embed the reference through
 * -[TTIOReferenceImport writeToDataset:overwrite:error:]. The same
 * three steps as the Python writer (SpectralDataset.write_minimal,
 * open(writable=True), ReferenceImport.write_to_dataset) and the
 * Java writer (create + close, open(path, true), writeToDataset).
 * writeToDataset goes purely through the storage-provider layer;
 * no native codec is touched.
 *
 * Usage: TtioRefXLangWriter <out.tio>
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOReferenceImport.h"
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

        NSError *err = nil;
        BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                    title:@"xlang"
                                       isaInvestigationId:@"XLANG001"
                                                   msRuns:@{}
                                          identifications:nil
                                          quantifications:nil
                                        provenanceRecords:nil
                                                    error:&err];
        if (!ok) {
            fprintf(stderr, "writeMinimalToPath failed: %s\n",
                    [[err description] UTF8String]);
            return 1;
        }

        TTIOSpectralDataset *ds =
            [TTIOSpectralDataset readFromFilePath:path
                                         writable:YES
                                            error:&err];
        if (ds == nil) {
            fprintf(stderr, "writable open failed: %s\n",
                    [[err description] UTF8String]);
            return 1;
        }

        TTIOReferenceImport *ri = [[TTIOReferenceImport alloc]
            initWithUri:@"xlang-test-v1"
            chromosomes:@[@"chr1", @"chr2"]
              sequences:@[chr1, chr2]];
        if (![ri writeToDataset:ds error:&err]) {
            fprintf(stderr, "writeToDataset failed: %s\n",
                    [[err description] UTF8String]);
            [ds closeFile];
            return 1;
        }
        [ds closeFile];
    }
    return 0;
}
