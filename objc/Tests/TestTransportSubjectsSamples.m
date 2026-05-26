/*
 * TestTransportSubjectsSamples.m — Stage 6 (transport-spec v0.11,
 * Deferral 2 / Task 6.4 Commit 3).
 *
 * Exercises SUBJECT_METADATA (0x19) + SAMPLE_METADATA (0x1A) writer +
 * reader. Each packet carries a single length-prefixed Apache Arrow
 * IPC stream per transport-spec §4.22:
 *   uint32 arrow_ipc_length (LE)
 *   bytes  arrow_ipc[arrow_ipc_length]
 *
 * Round-trip path:
 *   writer -writeSubjectMetadata:/-writeSampleMetadata:
 *     -> Arrow IPC bytes
 *       -> reader 0x19/0x1A decoder
 *         -> /study/{subjects,samples}/<id>/ HDF5 per-row groups
 *           -> SpectralDataset.subjects / .samples accessors
 *
 * Cross-language parity:
 *   Java TransportSubjectsSamplesTest (commit dd211600)
 *   Python tests/test_transport_subjects_samples.py (commit 00c7e1b7)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOTransportReader+Internal.h"
#import "Transport/TTIOTransportWriter.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOSubject.h"
#import "Dataset/TTIOSample.h"
#include <unistd.h>

// -------- helpers ----------------------------------------------------------

static NSString *makeTempPath_TSS(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_ss_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:base];
}

// ── 1. subjects-only round-trip via writeDataset: ────────────────────

static void testSubjectsOnlyRoundTrip(void)
{
    // Build a fixture .tio via SpectralDataset.writeMinimalToPath:
    // then layer subjects directly by reopening via the same path
    // the SpectralDataset Commit 1 tests use. Then drive a full
    // writeDataset: -> writeTtioToPath: round-trip and verify the
    // subjects accessor on the materialised file matches.
    TTIOSubject *s1 = [[TTIOSubject alloc] initWithExternalId:@"S1"
                                                         project:@"STUDY-A"
                                                             sex:@"F"
                                                       birthYear:1985
                                                      attributes:@{ @"site": @"NYC" }];
    TTIOSubject *s2 = [[TTIOSubject alloc] initWithExternalId:@"S2"
                                                         project:nil
                                                             sex:nil
                                                       birthYear:0
                                                      attributes:nil];

    // Write packets directly via the fine-grained writer API.
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"subjects-only"
                               isaInvestigation:@""
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "6.4 subj-only: StreamHeader");
    PASS([w writeSubjectMetadata:(@[s1, s2]) error:&err],
         "6.4 subj-only: writeSubjectMetadata emitted");
    PASS([w writeEndOfStreamWithError:&err],
         "6.4 subj-only: EndOfStream");

    // Verify exactly one 0x19 and zero 0x1A.
    TTIOTransportReader *probe =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [probe readAllPacketsWithError:&err];
    int subjCount = 0, sampCount = 0;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketSubjectMetadata) subjCount++;
        if (rec.header.packetType
                == TTIOTransportPacketSampleMetadata)  sampCount++;
    }
    PASS(subjCount == 1, "6.4 subj-only: exactly one 0x19 on wire");
    PASS(sampCount == 0, "6.4 subj-only: zero 0x1A packets");

    NSString *outPath = makeTempPath_TSS(@"subj-rt");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    err = nil;
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "6.4 subj-only: writeTtioToPath materialised");

    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(back != nil, "6.4 subj-only: re-opened materialised .tio");
    PASS(back.subjects.count == 2, "6.4 subj-only: 2 subjects materialised");
    PASS(back.samples.count == 0,  "6.4 subj-only: no samples on disk");

    TTIOSubject *r1 = nil, *r2 = nil;
    for (TTIOSubject *s in back.subjects) {
        if ([s.externalId isEqualToString:@"S1"]) r1 = s;
        if ([s.externalId isEqualToString:@"S2"]) r2 = s;
    }
    PASS(r1 != nil && r2 != nil,
         "6.4 subj-only: both subjects present after wire round-trip");
    if (r1 != nil) {
        PASS([r1.project isEqualToString:@"STUDY-A"], "6.4 subj-only: r1.project");
        PASS([r1.sex isEqualToString:@"F"],            "6.4 subj-only: r1.sex");
        PASS(r1.birthYear == 1985,                      "6.4 subj-only: r1.birthYear");
        PASS([r1.attributes[@"site"] isEqualToString:@"NYC"],
             "6.4 subj-only: r1.attributes.site");
    }
    if (r2 != nil) {
        PASS([r2.project isEqualToString:@""],
             "6.4 subj-only: r2 empty project (null wire -> @\"\")");
        PASS(r2.birthYear == 0,
             "6.4 subj-only: r2 sentinel birthYear (null wire -> 0)");
    }

    [back closeFile];
    unlink([outPath fileSystemRepresentation]);
}

// ── 2. samples-only round-trip ───────────────────────────────────────

static void testSamplesOnlyRoundTrip(void)
{
    TTIOSample *m1 = [[TTIOSample alloc] initWithSampleId:@"M1"
                                         subjectExternalId:@"S1"
                                                sampleKind:@"plasma"
                                               collectedAt:1716671000
                                                attributes:@{ @"freezer": @"L-80" }];
    TTIOSample *m2 = [[TTIOSample alloc] initWithSampleId:@"M2"
                                         subjectExternalId:nil
                                                sampleKind:nil
                                               collectedAt:0
                                                attributes:nil];

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"samples-only"
                               isaInvestigation:@""
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "6.4 samp-only: StreamHeader");
    PASS([w writeSampleMetadata:(@[m1, m2]) error:&err],
         "6.4 samp-only: writeSampleMetadata emitted");
    PASS([w writeEndOfStreamWithError:&err],
         "6.4 samp-only: EndOfStream");

    TTIOTransportReader *probe =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [probe readAllPacketsWithError:&err];
    int subjCount = 0, sampCount = 0;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketSubjectMetadata) subjCount++;
        if (rec.header.packetType
                == TTIOTransportPacketSampleMetadata)  sampCount++;
    }
    PASS(subjCount == 0, "6.4 samp-only: zero 0x19 packets");
    PASS(sampCount == 1, "6.4 samp-only: exactly one 0x1A on wire");

    NSString *outPath = makeTempPath_TSS(@"samp-rt");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    err = nil;
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "6.4 samp-only: writeTtioToPath materialised");

    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(back != nil, "6.4 samp-only: re-opened");
    PASS(back.subjects.count == 0, "6.4 samp-only: no subjects on disk");
    PASS(back.samples.count == 2,  "6.4 samp-only: 2 samples materialised");

    TTIOSample *r1 = nil, *r2 = nil;
    for (TTIOSample *s in back.samples) {
        if ([s.sampleId isEqualToString:@"M1"]) r1 = s;
        if ([s.sampleId isEqualToString:@"M2"]) r2 = s;
    }
    PASS(r1 != nil && r2 != nil,
         "6.4 samp-only: both samples present");
    if (r1 != nil) {
        PASS([r1.subjectExternalId isEqualToString:@"S1"],
             "6.4 samp-only: r1.subjectExternalId");
        PASS([r1.sampleKind isEqualToString:@"plasma"],
             "6.4 samp-only: r1.sampleKind");
        PASS(r1.collectedAt == 1716671000,
             "6.4 samp-only: r1.collectedAt");
        PASS([r1.attributes[@"freezer"] isEqualToString:@"L-80"],
             "6.4 samp-only: r1.attributes.freezer");
    }
    if (r2 != nil) {
        PASS([r2.subjectExternalId isEqualToString:@""],
             "6.4 samp-only: r2 empty FK (null wire -> @\"\")");
        PASS([r2.sampleKind isEqualToString:@""],
             "6.4 samp-only: r2 empty kind");
        PASS(r2.collectedAt == 0,
             "6.4 samp-only: r2 sentinel collectedAt");
    }

    [back closeFile];
    unlink([outPath fileSystemRepresentation]);
}

// ── 3. empty subjects/samples -> no packets ──────────────────────────

static void testEmptyEmitsNoPackets(void)
{
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"empty"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "6.4 empty: StreamHeader");
    // Empty lists must produce zero packets per spec §5.4 step 5.
    PASS([w writeSubjectMetadata:@[] error:&err],
         "6.4 empty: writeSubjectMetadata @[] no-op");
    PASS([w writeSampleMetadata:@[] error:&err],
         "6.4 empty: writeSampleMetadata @[] no-op");
    PASS([w writeEndOfStreamWithError:&err],
         "6.4 empty: EndOfStream");

    TTIOTransportReader *probe =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [probe readAllPacketsWithError:&err];
    int subjCount = 0, sampCount = 0;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketSubjectMetadata) subjCount++;
        if (rec.header.packetType
                == TTIOTransportPacketSampleMetadata)  sampCount++;
    }
    PASS(subjCount == 0,
         "6.4 empty: writeSubjectMetadata @[] emits zero 0x19 packets");
    PASS(sampCount == 0,
         "6.4 empty: writeSampleMetadata @[] emits zero 0x1A packets");
}

// ── 4. both populated -> 0x19 emitted before 0x1A in §5.4 order ──────
//
// Build a source .tio carrying both subjects + samples (via the same
// build-fixture pattern Commit 1 uses), drive it through
// -writeDataset:, then assert the on-wire ordering: 0x19 must precede
// 0x1A so forward references resolve during streaming.

#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"

static NSString *buildSourceTioWithBoth(TTIOSubject *s,
                                         TTIOSample *m,
                                         NSError **error)
{
    NSString *path = makeTempPath_TSS(@"both-src");
    unlink([path fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"both-src"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:error];
    if (!ok) return nil;
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:error];
    if (f == nil) return nil;
    TTIOHDF5Group *root = [f rootGroup];
    TTIOHDF5Group *study = [root openGroupNamed:@"study" error:error];
    if (study == nil) { [f close]; return nil; }
    TTIOHDF5Group *sg = [study createGroupNamed:@"subjects" error:error];
    TTIOHDF5Group *srow = [sg createGroupNamed:s.externalId error:error];
    [srow setStringAttribute:@"external_id" value:s.externalId error:error];
    if (s.project.length > 0)
        [srow setStringAttribute:@"project" value:s.project error:error];
    if (s.sex.length > 0)
        [srow setStringAttribute:@"sex" value:s.sex error:error];
    [srow setIntegerAttribute:@"birth_year" value:s.birthYear error:error];
    [srow setStringAttribute:@"attributes_json" value:[s attributesJson] error:error];

    TTIOHDF5Group *smg = [study createGroupNamed:@"samples" error:error];
    TTIOHDF5Group *mrow = [smg createGroupNamed:m.sampleId error:error];
    [mrow setStringAttribute:@"sample_id" value:m.sampleId error:error];
    if (m.subjectExternalId.length > 0)
        [mrow setStringAttribute:@"subject_external_id" value:m.subjectExternalId error:error];
    if (m.sampleKind.length > 0)
        [mrow setStringAttribute:@"sample_kind" value:m.sampleKind error:error];
    [mrow setIntegerAttribute:@"collected_at" value:m.collectedAt error:error];
    [mrow setStringAttribute:@"attributes_json" value:[m attributesJson] error:error];
    [f close];
    return path;
}

static void testBothOrdering(void)
{
    TTIOSubject *s = [[TTIOSubject alloc] initWithExternalId:@"S1"
                                                        project:nil
                                                            sex:nil
                                                      birthYear:0
                                                     attributes:nil];
    TTIOSample *m = [[TTIOSample alloc] initWithSampleId:@"M1"
                                        subjectExternalId:@"S1"
                                               sampleKind:nil
                                              collectedAt:0
                                               attributes:nil];
    NSError *err = nil;
    NSString *srcPath = buildSourceTioWithBoth(s, m, &err);
    PASS(srcPath != nil, "6.4 both: source fixture built");

    TTIOSpectralDataset *src =
        [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
    PASS(src != nil, "6.4 both: source dataset opens");
    PASS(src.subjects.count == 1, "6.4 both: src subjects count");
    PASS(src.samples.count  == 1, "6.4 both: src samples count");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:src error:&err],
         "6.4 both: writeDataset emitted full prelude");

    // Walk packet sequence; assert 0x19 appears before 0x1A.
    TTIOTransportReader *probe =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [probe readAllPacketsWithError:&err];
    NSInteger firstSubj = -1, firstSamp = -1;
    NSInteger idx = 0;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType == TTIOTransportPacketSubjectMetadata
            && firstSubj < 0) firstSubj = idx;
        if (rec.header.packetType == TTIOTransportPacketSampleMetadata
            && firstSamp < 0) firstSamp = idx;
        idx++;
    }
    PASS(firstSubj >= 0, "6.4 both: 0x19 present in stream");
    PASS(firstSamp >= 0, "6.4 both: 0x1A present in stream");
    PASS(firstSubj < firstSamp,
         "6.4 both: 0x19 emitted BEFORE 0x1A (§5.4 ordering)");

    // Round-trip to a fresh .tio and verify both surfaced.
    NSString *outPath = makeTempPath_TSS(@"both-rt");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    PASS([r writeTtioToPath:outPath error:&err],
         "6.4 both: writeTtioToPath materialised");
    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(back != nil && back.subjects.count == 1 && back.samples.count == 1,
         "6.4 both: both accessors round-tripped");

    [back closeFile];
    [src closeFile];
    unlink([outPath fileSystemRepresentation]);
    unlink([srcPath fileSystemRepresentation]);
}

void testTransportSubjectsSamples(void)
{
    testSubjectsOnlyRoundTrip();
    testSamplesOnlyRoundTrip();
    testEmptyEmitsNoPackets();
    testBothOrdering();
}
