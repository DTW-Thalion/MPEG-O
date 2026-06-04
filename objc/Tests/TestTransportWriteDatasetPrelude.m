/*
 * TestTransportWriteDatasetPrelude.m — Task 3.9 of transport-spec v0.11.
 *
 * End-to-end verification of -[TTIOTransportWriter writeDataset:]'s
 * v0.11 prelude wiring. The prelude emits in this strict order per
 * spec §5.4:
 *
 *   §5.4.1 ENCRYPTION_ALGORITHM (0x1B)  — when ds.isEncrypted
 *   §5.4.2 DATASET_PROVENANCE   (0x18)  — when ds.provenanceRecords non-empty
 *   §5.4.3 SUBJECT_METADATA / SAMPLE_METADATA  — deferred
 *   §5.4.4 reference groups (0x10/0x11/0x12)   — one per ds.references value
 *   §5.4.5 image cube (0x13/0x14/0x15)         — when ds.msImage != nil
 *   §5.4.6 IDENTIFICATIONS_TABLE (0x16) / QUANTIFICATIONS_TABLE (0x17)
 *
 * The transport_v0_11 feature flag rides on StreamHeader.features when
 * any of the above is non-empty / non-nil.
 *
 * Cross-language parity:
 *   Java TransportWriterReferenceWireUpTest (commit dc0de926)
 *   Python tests/test_transport_write_dataset_prelude.py (commit 6f51e81b)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "Testing.h"

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOTransportReader+Internal.h"
#import "Transport/TTIOTransportWriter.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOIdentification.h"
#import "Dataset/TTIOQuantification.h"
#import "Dataset/TTIOProvenanceRecord.h"
#import "Genomics/TTIOReferenceImport.h"
#import "Image/TTIOMSImage.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "Providers/TTIOHDF5Provider.h"
#import "Providers/TTIOStorageProtocols.h"
#include <unistd.h>

// -------- helpers ----------------------------------------------------------

static NSString *makeTempPathP(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_pre_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:base];
}

// Build a .tio with exactly one reference embedded and nothing else.
// The reference has both a small chromosome (below the 4 KiB zlib
// threshold) and a large chromosome (above it) so both encoding
// branches in -writeReferenceGroup: get exercised.
static NSString *buildReferenceOnlyTio(NSString *suffix, NSError **error)
{
    NSString *path = makeTempPathP(suffix);
    unlink([path fileSystemRepresentation]);

    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"ref-only"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:error];
    if (!ok) return nil;

    // Construct the reference and embed via the writeToDataset trick
    // (object_setIvar to attach a writable provider). Pattern from
    // TTIOReferenceImportWriteToDatasetTests.m.
    NSData *small = [@"ACGTACGT" dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *big = [NSMutableData dataWithLength:8192];
    uint8_t *bp = (uint8_t *)big.mutableBytes;
    const char alphabet[4] = {'A', 'C', 'G', 'T'};
    for (NSUInteger i = 0; i < big.length; i++) bp[i] = alphabet[i & 3];
    TTIOReferenceImport *ref =
        [[TTIOReferenceImport alloc] initWithUri:@"prelude-ref-v1"
                                     chromosomes:@[@"chrA", @"chrB"]
                                       sequences:@[small, big]];

    TTIOHDF5Provider *p = [[TTIOHDF5Provider alloc] init];
    if (![p openURL:path mode:TTIOStorageOpenModeReadWrite error:error]) {
        return nil;
    }
    TTIOSpectralDataset *ds =
        [[TTIOSpectralDataset alloc] initWithTitle:@"ref-only"
                                isaInvestigationId:@""
                                            msRuns:@{}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    Ivar provIvar = class_getInstanceVariable([TTIOSpectralDataset class],
                                                "_provider");
    if (provIvar == NULL) return nil;
    object_setIvar(ds, provIvar, p);
    if (![ref writeToDataset:ds error:error]) {
        [ds closeFile];
        return nil;
    }
    [ds closeFile];
    return path;
}

// -------- 1. reference-only round-trip via writeDataset --------------------

// Regression for the silent-drop bug: writeDataset on a reference-only
// .tio must produce a .tis that round-trips losslessly back to .tio
// with the references intact. Before Task 3.9 the references were
// dropped because writeDataset emitted nothing for the references
// accessor.
static void testReferenceOnlyRoundTripsThroughWriteDataset(void)
{
    NSError *err = nil;
    NSString *src = buildReferenceOnlyTio(@"refonly_src", &err);
    PASS(src != nil && err == nil,
         "3.9 ref-rt: built reference-only fixture .tio");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil && ds.references.count == 1,
         "3.9 ref-rt: fixture dataset surfaces 1 reference on open");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.9 ref-rt: writeDataset on reference-only .tio");
    [ds closeFile];

    // Floor check: a silent-drop run would have produced just a
    // StreamHeader + EndOfStream (a couple hundred bytes). 8 KiB ACGT
    // compresses to ~40 bytes via zlib, so we gate on a conservative
    // 300-byte floor.
    PASS(buf.length > 300,
         "3.9 ref-rt: stream is non-trivial (>300 bytes, "
         "rules out silent drop)");

    NSString *outPath = makeTempPathP(@"refonly_rt");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    err = nil;
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "3.9 ref-rt: writeTtioToPath materialised");

    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(back != nil, "3.9 ref-rt: re-opened materialised .tio");
    PASS(back.references.count == 1,
         "3.9 ref-rt: references round-tripped (count=1)");
    TTIOReferenceImport *origRef = ds.references[@"prelude-ref-v1"];
    TTIOReferenceImport *backRef = back.references[@"prelude-ref-v1"];
    PASS(backRef != nil,
         "3.9 ref-rt: back-side reference looked up by URI");
    if (origRef && backRef) {
        PASS([backRef.chromosomes isEqualToArray:origRef.chromosomes],
             "3.9 ref-rt: chromosome names round-trip");
        PASS(backRef.totalBases == origRef.totalBases,
             "3.9 ref-rt: total bases round-trip");
        PASS([backRef.md5 isEqualToData:origRef.md5],
             "3.9 ref-rt: MD5 round-trips byte-equal");
    }

    [back closeFile];
    unlink([outPath fileSystemRepresentation]);
    unlink([src fileSystemRepresentation]);
}

// -------- 2. feature flag set when any v0.11 content present ---------------

static void testFeatureFlagSetWhenReferencesPresent(void)
{
    NSError *err = nil;
    NSString *src = buildReferenceOnlyTio(@"flag_src", &err);
    PASS(src != nil && err == nil,
         "3.9 flag: built reference-only fixture .tio");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.9 flag: opened fixture dataset");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.9 flag: writeDataset emitted stream");

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records.count > 0,
         "3.9 flag: parsed stream into packet records");
    PASS(records[0].header.packetType
            == TTIOTransportPacketStreamHeader,
         "3.9 flag: first packet is StreamHeader");

    // The features list rides as UTF-8 length-prefixed strings inside
    // the StreamHeader payload — a substring search is sufficient
    // (matches Java + Python test patterns).
    NSString *sh = [[NSString alloc] initWithData:records[0].payload
                                          encoding:NSUTF8StringEncoding];
    PASS(sh != nil && [sh containsString:@"transport_v0_11"],
         "3.9 flag: StreamHeader carries transport_v0_11 feature flag");

    [ds closeFile];
    unlink([src fileSystemRepresentation]);
}

// -------- 3. v0.10 dataset unchanged: no flag, no v0.11 packets ------------

static void testV010DatasetEmitsNoV011FlagOrPackets(void)
{
    NSError *err = nil;
    NSString *src = makeTempPathP(@"v010");
    unlink([src fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:src
                                                  title:@"v010-only"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "3.9 v010: minimal .tio with no v0.11 content");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.9 v010: opened v0.10 dataset");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.9 v010: writeDataset on v0.10-only fixture");

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records.count > 0, "3.9 v010: parsed stream");
    PASS(records[0].header.packetType
            == TTIOTransportPacketStreamHeader,
         "3.9 v010: first packet is StreamHeader");

    NSString *sh = [[NSString alloc] initWithData:records[0].payload
                                          encoding:NSUTF8StringEncoding];
    PASS(sh != nil && ![sh containsString:@"transport_v0_11"],
         "3.9 v010: v0.10-only dataset does NOT advertise transport_v0_11");

    // None of the v0.11 packet types may appear on a v0.10 stream.
    NSSet<NSNumber *> *v011Types = [NSSet setWithArray:@[
        @(TTIOTransportPacketReferenceGroupHeader),
        @(TTIOTransportPacketReferenceChromosome),
        @(TTIOTransportPacketEndOfReferenceGroup),
        @(TTIOTransportPacketImageHeader),
        @(TTIOTransportPacketImagePixel),
        @(TTIOTransportPacketEndOfImage),
        @(TTIOTransportPacketIdentificationsTable),
        @(TTIOTransportPacketQuantificationsTable),
        @(TTIOTransportPacketDatasetProvenance),
        @(TTIOTransportPacketEncryptionAlgorithm),
    ]];
    BOOL sawAny = NO;
    for (TTIOTransportPacketRecord *rec in records) {
        if ([v011Types containsObject:@(rec.header.packetType)]) {
            sawAny = YES;
            break;
        }
    }
    PASS(!sawAny,
         "3.9 v010: v0.10 stream contains zero v0.11 packets");

    [ds closeFile];
    unlink([src fileSystemRepresentation]);
}

// -------- 4. multi-section: all 6 accessors -> strict §5.4 order -----------

// Builds a .tio carrying every v0.11 first-class accessor: encryption
// algorithm root attr, dataset_provenance, one reference, an image
// cube, identifications, and quantifications. Verifies the writer
// emits them in §5.4 order on the wire.
static NSString *buildMultiSectionTio(NSError **error)
{
    NSString *path = makeTempPathP(@"multi");
    unlink([path fileSystemRepresentation]);

    // Start with an image-bearing dataset so the on-disk layout
    // includes /study/image_cube/. TTIOMSImage -writeToFilePath:
    // creates the full /study/ skeleton + the cube + axis.
    const NSUInteger w = 2, h = 2, s = 3;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
    double *mzp = (double *)mz.mutableBytes;
    mzp[0] = 100.0; mzp[1] = 110.0; mzp[2] = 120.0;
    TTIOIdentification *ident = [[TTIOIdentification alloc]
        initWithRunName:@"r1"
          spectrumIndex:0
         chemicalEntity:@"CompoundA"
        confidenceScore:0.5
          evidenceChain:@[@"e1"]];
    TTIOQuantification *quant = [[TTIOQuantification alloc]
        initWithChemicalEntity:@"CompoundA"
                     sampleRef:@"s1"
                     abundance:1.0
           normalizationMethod:@"intensity-sum"
                          unit:@"counts"];
    TTIOProvenanceRecord *prov = [[TTIOProvenanceRecord alloc]
        initWithInputRefs:@[]
                 software:@"ttio-test"
               parameters:@{@"k": @"v"}
               outputRefs:@[]
            timestampUnix:12345];

    TTIOMSImage *image = [[TTIOMSImage alloc]
                            initWithTitle:@"multi-img"
                       isaInvestigationId:@""
                          identifications:@[ident]
                          quantifications:@[quant]
                        provenanceRecords:@[prov]
                                    width:w
                                   height:h
                           spectralPoints:s
                                 tileSize:32
                               pixelSizeX:10.0
                               pixelSizeY:10.0
                              scanPattern:@"raster"
                                     cube:cube
                                   mzAxis:mz];
    if (![image writeToFilePath:path error:error]) return nil;

    // Embed a reference via the same writeToDataset trick.
    NSData *small = [@"ACGT" dataUsingEncoding:NSASCIIStringEncoding];
    TTIOReferenceImport *ref =
        [[TTIOReferenceImport alloc] initWithUri:@"multi-ref-v1"
                                     chromosomes:@[@"chr1"]
                                       sequences:@[small]];
    TTIOHDF5Provider *p = [[TTIOHDF5Provider alloc] init];
    if (![p openURL:path mode:TTIOStorageOpenModeReadWrite error:error]) {
        return nil;
    }
    TTIOSpectralDataset *seed =
        [[TTIOSpectralDataset alloc] initWithTitle:@"multi"
                                isaInvestigationId:@""
                                            msRuns:@{}
                                           nmrRuns:@{}
                                   identifications:@[]
                                   quantifications:@[]
                                 provenanceRecords:@[]
                                       transitions:nil];
    Ivar provIvar = class_getInstanceVariable([TTIOSpectralDataset class],
                                                "_provider");
    if (provIvar == NULL) return nil;
    object_setIvar(seed, provIvar, p);
    if (![ref writeToDataset:seed error:error]) {
        [seed closeFile];
        return nil;
    }
    [seed closeFile];

    // Set the @encrypted root attribute so isEncrypted+encryptedAlgorithm
    // surface non-empty on open. (Encryption algorithm string only —
    // we're not exercising the cipher pipeline, just the prelude emit.)
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:error];
    if (!f) return nil;
    TTIOHDF5Group *root = [f rootGroup];
    if (![root setStringAttribute:@"encrypted"
                              value:@"aes-256-gcm"
                              error:error]) {
        [f close];
        return nil;
    }
    if (![f close]) return nil;
    return path;
}

static void testMultiSectionPreludeEmitsInSpec54Order(void)
{
    NSError *err = nil;
    NSString *src = buildMultiSectionTio(&err);
    PASS(src != nil && err == nil,
         "3.9 multi: built multi-section fixture .tio");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.9 multi: opened fixture dataset");
    // Sanity-check fixture preconditions.
    PASS(ds.isEncrypted,
         "3.9 multi: fixture precondition: isEncrypted");
    PASS(ds.provenanceRecords.count > 0,
         "3.9 multi: fixture precondition: provenance non-empty");
    PASS(ds.references.count > 0,
         "3.9 multi: fixture precondition: references non-empty");
    PASS([ds imageForKind:TTIOImageKindMS] != nil,
         "3.9 multi: fixture precondition: msImage non-nil");
    PASS(ds.identifications.count > 0,
         "3.9 multi: fixture precondition: identifications non-empty");
    PASS(ds.quantifications.count > 0,
         "3.9 multi: fixture precondition: quantifications non-empty");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.9 multi: writeDataset on multi-section .tio");

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records.count > 0, "3.9 multi: parsed stream");

    NSInteger encIdx = -1, provIdx = -1, refIdx = -1;
    NSInteger imgIdx = -1, idsIdx = -1, quantIdx = -1;
    for (NSUInteger i = 0; i < records.count; i++) {
        TTIOTransportPacketType t = records[i].header.packetType;
        if (t == TTIOTransportPacketEncryptionAlgorithm    && encIdx < 0)   encIdx = (NSInteger)i;
        if (t == TTIOTransportPacketDatasetProvenance      && provIdx < 0)  provIdx = (NSInteger)i;
        if (t == TTIOTransportPacketReferenceGroupHeader   && refIdx < 0)   refIdx = (NSInteger)i;
        if (t == TTIOTransportPacketImageHeader            && imgIdx < 0)   imgIdx = (NSInteger)i;
        if (t == TTIOTransportPacketIdentificationsTable   && idsIdx < 0)   idsIdx = (NSInteger)i;
        if (t == TTIOTransportPacketQuantificationsTable   && quantIdx < 0) quantIdx = (NSInteger)i;
    }
    PASS(encIdx   > 0, "3.9 multi: ENCRYPTION_ALGORITHM emitted");
    PASS(provIdx  > 0, "3.9 multi: DATASET_PROVENANCE emitted");
    PASS(refIdx   > 0, "3.9 multi: REFERENCE_GROUP_HEADER emitted");
    PASS(imgIdx   > 0, "3.9 multi: IMAGE_HEADER emitted");
    PASS(idsIdx   > 0, "3.9 multi: IDENTIFICATIONS_TABLE emitted");
    PASS(quantIdx > 0, "3.9 multi: QUANTIFICATIONS_TABLE emitted");

    PASS(encIdx < provIdx,
         "3.9 multi: §5.4: ENCRYPTION_ALGORITHM precedes "
         "DATASET_PROVENANCE");
    PASS(provIdx < refIdx,
         "3.9 multi: §5.4: DATASET_PROVENANCE precedes REFERENCE_*");
    PASS(refIdx < imgIdx,
         "3.9 multi: §5.4: REFERENCE_* precedes IMAGE_*");
    PASS(imgIdx < idsIdx,
         "3.9 multi: §5.4: IMAGE_* precedes IDENTIFICATIONS_TABLE");
    PASS(idsIdx < quantIdx,
         "3.9 multi: §5.4: IDENTIFICATIONS_TABLE precedes "
         "QUANTIFICATIONS_TABLE");

    [ds closeFile];
    unlink([src fileSystemRepresentation]);
}

// -------- entry point ------------------------------------------------------

void testTransportWriteDatasetPrelude(void);
void testTransportWriteDatasetPrelude(void)
{
    testReferenceOnlyRoundTripsThroughWriteDataset();
    testFeatureFlagSetWhenReferencesPresent();
    testV010DatasetEmitsNoV011FlagOrPackets();
    testMultiSectionPreludeEmitsInSpec54Order();
}
