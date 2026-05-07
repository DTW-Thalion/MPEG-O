// TTIOReferencesAccessorTests.m — Phase 0 Task 0.5 tio-browser.
//
// Mirror of the Java + Python tests landed in commits f2971ba / 6bc8d24:
// drives the public read-back path for embedded references at
// /study/references/<uri>/. The writer's
// _TTIO_M93_EmbedReferences helper requires the native ref_diff_v2
// library, which is not available in CI; to stay free-standing we
// write the canonical 3-level on-disk layout directly via the
// TTIOHDF5* APIs. The shape exercised here is byte-identical to what
// the writer produces when its embed gate fires (cross-language parity
// hinges on that shape — see ReferenceImport.readFromGroup in the
// Java side, and ReferenceImport.read_from_group in the Python side).
//
// Phase 0 Task 0.11 (tio-browser) extends this file with
// testEmbedReferencesWithoutNativeLib, which verifies that the writer
// embeds chromosome bytes purely via HDF5 I/O — without requiring
// libttio_rans to be linked.
//
// SPDX-License-Identifier: Apache-2.0
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Codecs/TTIORefDiffV2.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Dataset.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

static NSString *makeTempPath(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_refs_%d_%@.tio",
                      (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

/** Compute the canonical content MD5 (sorted by chrom name, then
 *  concatenated sequence bytes — unified seq-only form, v1.1.0+) and
 *  return its 32-char lowercase-hex form. Mirrors the writer's md5
 *  attribute exactly so cross-language byte-equal MD5 is exercised on
 *  the read path. */
static NSString *md5HexForChroms(NSDictionary<NSString *, NSData *> *seqs)
{
    NSArray<NSString *> *names =
        [seqs.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSArray<NSData *> *vals = ({
        NSMutableArray *a = [NSMutableArray arrayWithCapacity:names.count];
        for (NSString *n in names) [a addObject:seqs[n]];
        a;
    });
    NSData *digest = [TTIOReferenceImport computeMd5WithChromosomes:names
                                                          sequences:vals];
    NSMutableString *hex = [NSMutableString stringWithCapacity:32];
    const uint8_t *p = digest.bytes;
    for (NSUInteger i = 0; i < digest.length; i++) [hex appendFormat:@"%02x", p[i]];
    return hex;
}

/** Seed /study/references/<uri>/ with the canonical layout. Parallel
 *  to the Python test's _seed_references helper. The on-disk shape
 *  matches _TTIO_M93_EmbedReferences exactly. */
static BOOL seedReferences(NSString *path,
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

    NSString *md5Hex = md5HexForChroms(seqs);
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

static void testFreshlyOpenedDatasetExposesEmbeddedReferences(void)
{
    NSString *path = makeTempPath(@"with_refs");
    unlink([path fileSystemRepresentation]);

    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                title:@"ref-test"
                                   isaInvestigationId:@"REFTEST001"
                                               msRuns:@{}
                                      identifications:nil
                                      quantifications:nil
                                    provenanceRecords:nil
                                                error:&err];
    PASS(ok, "1.1.0: writeMinimalToPath succeeds for ref-only seed");

    NSData *chr1 = [@"ACGTACGTACGT" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *chr2 = [@"TTTTAAAACCCC" dataUsingEncoding:NSASCIIStringEncoding];
    NSDictionary<NSString *, NSData *> *seqs = @{@"chr1": chr1, @"chr2": chr2};

    PASS(seedReferences(path, @"test-ref-v1", seqs, &err),
         "1.1.0: seed /study/references/<uri>/ with canonical layout");

    TTIOSpectralDataset *opened =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(opened != nil && err == nil,
         "1.1.0: readFromFilePath reopens the seeded file");

    NSDictionary<NSString *, TTIOReferenceImport *> *refs = opened.references;
    PASS(refs != nil, "1.1.0: -references is non-nil");
    PASS([refs count] == 1, "1.1.0: exactly one embedded reference");

    TTIOReferenceImport *r = refs[@"test-ref-v1"];
    PASS(r != nil, "1.1.0: 'test-ref-v1' present in -references");
    // The writer sorts chromosome names alphabetically before
    // persisting, so the read-back order is alphabetic for any file
    // produced by this library.
    PASS([r.chromosomes isEqualToArray:(@[@"chr1", @"chr2"])],
         "1.1.0: chromosomes ordered alphabetically");
    PASS([[r chromosomeNamed:@"chr1"] isEqualToData:chr1],
         "1.1.0: chr1 sequence round-trips");
    PASS([[r chromosomeNamed:@"chr2"] isEqualToData:chr2],
         "1.1.0: chr2 sequence round-trips");
    PASS([r totalBases] == 24, "1.1.0: totalBases sums to 24");

    // MD5 must be preserved verbatim from @md5; recomputing in the
    // ctor would also yield the same digest, so the cross-check uses
    // the canonical digest helper (which is what the writer used).
    NSString *expectedHex = md5HexForChroms(seqs);
    PASS([[r md5Hex] isEqualToString:expectedHex],
         "1.1.0: MD5 attribute preserved verbatim from @md5");

    PASS([r.uri isEqualToString:@"test-ref-v1"],
         "1.1.0: reference URI matches @reference_uri attribute");

    [opened closeFile];
    unlink([path fileSystemRepresentation]);
}

static void testDatasetWithoutReferencesReturnsEmptyDict(void)
{
    NSString *path = makeTempPath(@"no_refs");
    unlink([path fileSystemRepresentation]);

    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                title:@"no-ref"
                                   isaInvestigationId:@"NOREF001"
                                               msRuns:@{}
                                      identifications:nil
                                      quantifications:nil
                                    provenanceRecords:nil
                                                error:&err];
    PASS(ok, "1.1.0: writeMinimalToPath without refs succeeds");

    TTIOSpectralDataset *opened =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(opened != nil, "1.1.0: readFromFilePath succeeds for no-ref file");

    NSDictionary<NSString *, TTIOReferenceImport *> *refs = opened.references;
    PASS(refs != nil, "1.1.0: -references on no-ref file is non-nil");
    PASS([refs count] == 0,
         "1.1.0: -references on no-ref file is empty (not nil)");

    [opened closeFile];
    unlink([path fileSystemRepresentation]);
}

/** Phase 0 Task 0.11: empty-read TTIOWrittenGenomicRun carrying
 *  ``embedReference=YES`` plus a non-nil ``referenceChromSeqs``
 *  drives the writer's embed loop without touching the native
 *  REF_DIFF_V2 encoder. ``signalCompression=TTIOCompressionNone``
 *  side-steps the v1.5 default-codec gate so the empty-quality byte
 *  channel goes through plain HDF5 I/O instead of the FQZCOMP_NX16_Z
 *  default that v1.5-candidate runs trigger when zlib is the channel
 *  compression. */
static TTIOWrittenGenomicRun *makeEmptyRunWithEmbedRefs(
    NSDictionary<NSString *, NSData *> *seqs,
    NSString *uri)
{
    NSData *empty = [NSData data];
    TTIOWrittenGenomicRun *g = [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:uri
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
    return g;
}

static void testEmbedReferencesWithoutNativeLib(void)
{
    // Sanity: the env this test is meant to certify has no native lib.
    // (The test still passes when native IS available, since the new
    // gate is "embedReference=YES + referenceChromSeqs!=nil" — which
    // strictly subsumes the old [TTIORefDiffV2 nativeAvailable] case.
    // The PASS message records the actual env state for the log.)
    BOOL haveNative = [TTIORefDiffV2 nativeAvailable];
    if (haveNative) {
        PASS(YES,
             "1.1.0 #0.11: native REF_DIFF_V2 available — embed gate "
             "must fire (subsuming case)");
    } else {
        PASS(YES,
             "1.1.0 #0.11: native REF_DIFF_V2 NOT available — embed "
             "gate must fire on embedReference=YES alone");
    }

    NSString *path = makeTempPath(@"embed_no_native");
    unlink([path fileSystemRepresentation]);

    NSData *chr1 = [@"ACGTACGTACGT" dataUsingEncoding:NSASCIIStringEncoding];
    NSData *chr2 = [@"TTTTAAAACCCC" dataUsingEncoding:NSASCIIStringEncoding];
    NSDictionary<NSString *, NSData *> *seqs =
        @{@"chr1": chr1, @"chr2": chr2};

    TTIOWrittenGenomicRun *g =
        makeEmptyRunWithEmbedRefs(seqs, @"test-ref-no-native");

    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                title:@"embed-no-native"
                                   isaInvestigationId:@"NONATIVE001"
                                               msRuns:@{}
                                          genomicRuns:@{@"g0": g}
                                      identifications:nil
                                      quantifications:nil
                                    provenanceRecords:nil
                                                error:&err];
    PASS(ok,
         "1.1.0 #0.11: writeMinimalToPath succeeds for "
         "embedReference=YES + empty-read run, no native lib");
    PASS(err == nil,
         "1.1.0 #0.11: writer leaves NSError nil on embed success");

    TTIOSpectralDataset *opened =
        [TTIOSpectralDataset readFromFilePath:path error:&err];
    PASS(opened != nil && err == nil,
         "1.1.0 #0.11: reopens the produced .tio cleanly");

    NSDictionary<NSString *, TTIOReferenceImport *> *refs = opened.references;
    PASS(refs != nil, "1.1.0 #0.11: -references is non-nil");
    PASS([refs count] == 1,
         "1.1.0 #0.11: exactly one embedded reference present "
         "(writer embed gate fired without native)");

    TTIOReferenceImport *r = refs[@"test-ref-no-native"];
    PASS(r != nil,
         "1.1.0 #0.11: the run's reference URI is keyed in -references");
    PASS([r.chromosomes isEqualToArray:(@[@"chr1", @"chr2"])],
         "1.1.0 #0.11: embedded chromosomes ordered alphabetically");
    PASS([[r chromosomeNamed:@"chr1"] isEqualToData:chr1],
         "1.1.0 #0.11: chr1 sequence round-trips byte-exact via embed path");
    PASS([[r chromosomeNamed:@"chr2"] isEqualToData:chr2],
         "1.1.0 #0.11: chr2 sequence round-trips byte-exact via embed path");

    [opened closeFile];
    unlink([path fileSystemRepresentation]);
}

void testReferencesAccessor(void);
void testReferencesAccessor(void)
{
    testFreshlyOpenedDatasetExposesEmbeddedReferences();
    testDatasetWithoutReferencesReturnsEmptyDict();
    testEmbedReferencesWithoutNativeLib();
}
