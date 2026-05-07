/*
 * TtioRefXLangWriter — tio-browser Phase 0 Task 0.6 standalone CLI
 * helper that writes the canonical embedded-reference fixture to a
 * single .tio file via the same direct-graft pattern as the Python
 * `_seed_references` and Java `RefXLangWriter` test helpers.
 *
 * Direct-graft (rather than the production writer's
 * `_TTIO_M93_EmbedReferences` path) keeps this tool runnable in CI
 * without the libttio_rans native dependency: the production writer
 * unconditionally requires `[TTIORefDiffV2 nativeAvailable]`. The
 * direct-graft writes the /study/references/<uri>/ subtree
 * byte-identically to what the production writer emits (sorted
 * chromosome names, @md5 as 32-char lowercase hex, @reference_uri,
 * per-chromosome @length, UINT8 `data` dataset).
 *
 * Usage: TtioRefXLangWriter <out.tio>
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOReferenceImport.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "ValueClasses/TTIOEnums.h"
#include <openssl/md5.h>
#include <stdio.h>

/** The single canonical @md5 form (unified in v1.1.0): sort by
 *  chromosome name, then digest the concatenated sequence bytes
 *  verbatim. Mirrors `_TTIO_M93_ReferenceMD5ForRun` in
 *  TTIOSpectralDataset.m and matches
 *  +[TTIOReferenceImport computeMd5WithChromosomes:sequences:]
 *  byte-for-byte. */
static NSString *xlangMd5HexForChroms(NSDictionary<NSString *, NSData *> *seqs)
{
    NSArray<NSString *> *names =
        [seqs.allKeys sortedArrayUsingSelector:@selector(compare:)];
    uint8_t digest[16];
    MD5_CTX c; MD5_Init(&c);
    for (NSString *name in names) {
        NSData *seq = seqs[name];
        MD5_Update(&c, seq.bytes, seq.length);
    }
    MD5_Final(digest, &c);
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    for (int i = 0; i < 16; i++) [hex appendFormat:@"%02x", digest[i]];
    return hex;
}

/** Direct-graft /study/references/<uri>/ with the canonical layout.
 *  Mirrors the seedReferences helper in TTIOReferencesAccessorTests.m
 *  exactly. */
static BOOL xlangSeedReferences(NSString *path,
                                NSString *uri,
                                NSDictionary<NSString *, NSData *> *seqs,
                                NSError **error)
{
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:error];
    if (f == nil) return NO;
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (study == nil) { [f close]; return NO; }

    TTIOHDF5Group *refsG = nil;
    if ([study hasChildNamed:@"references"]) {
        refsG = [study openGroupNamed:@"references" error:error];
    } else {
        refsG = [study createGroupNamed:@"references" error:error];
    }
    if (refsG == nil) { [f close]; return NO; }

    TTIOHDF5Group *refG = [refsG createGroupNamed:uri error:error];
    if (refG == nil) { [f close]; return NO; }

    NSString *md5Hex = xlangMd5HexForChroms(seqs);
    if (![refG setStringAttribute:@"md5" value:md5Hex error:error]) {
        [f close]; return NO;
    }
    if (![refG setStringAttribute:@"reference_uri" value:uri error:error]) {
        [f close]; return NO;
    }

    TTIOHDF5Group *chromsG =
        [refG createGroupNamed:@"chromosomes" error:error];
    if (chromsG == nil) { [f close]; return NO; }

    NSArray *cnames =
        [seqs.allKeys sortedArrayUsingSelector:@selector(compare:)];
    for (NSString *cname in cnames) {
        TTIOHDF5Group *cg = [chromsG createGroupNamed:cname error:error];
        if (cg == nil) { [f close]; return NO; }
        NSData *seq = seqs[cname];
        if (![cg setIntegerAttribute:@"length"
                               value:(int64_t)seq.length error:error]) {
            [f close]; return NO;
        }
        TTIOHDF5Dataset *ds =
            [cg createDatasetNamed:@"data"
                          precision:TTIOPrecisionUInt8
                             length:seq.length
                          chunkSize:65536
                        compression:TTIOCompressionZlib
                   compressionLevel:6
                              error:error];
        if (ds == nil) { [f close]; return NO; }
        if (![ds writeData:seq error:error]) { [f close]; return NO; }
    }
    [f close];
    return YES;
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        if (argc != 2) {
            fprintf(stderr, "usage: TtioRefXLangWriter <out.tio>\n");
            return 2;
        }
        NSString *path = [NSString stringWithUTF8String:argv[1]];

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

        NSData *chr1 = [@"ACGTACGTACGT"
            dataUsingEncoding:NSASCIIStringEncoding];
        NSData *chr2 = [@"TTTTAAAACCCC"
            dataUsingEncoding:NSASCIIStringEncoding];
        NSDictionary<NSString *, NSData *> *seqs =
            @{@"chr1": chr1, @"chr2": chr2};

        if (!xlangSeedReferences(path, @"xlang-test-v1", seqs, &err)) {
            fprintf(stderr, "seedReferences failed: %s\n",
                    [[err description] UTF8String]);
            return 1;
        }
    }
    return 0;
}
