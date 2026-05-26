/*
 * TestTransportReaderReference — Task 3.3 of transport-spec v0.11.
 *
 * Round-trip: build a TTIOReferenceImport, emit it via
 * -writeReferenceGroup: into an in-memory transport buffer, then drive
 * the buffer through TTIOTransportReader -writeTtioToPath:. Re-open
 * the materialised .tio and verify the embedded reference matches the
 * source by URI + chromosome name + sequence bytes.
 *
 * Cross-language parity: Java TransportReaderReferenceTest (commit
 * 7f3dec46) and Python tests/test_reader_reference_group.py (commit
 * 415fc24f). Exercises both encoding=0 (raw) and encoding=1 (zlib)
 * payload paths.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOTransportWriter.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Genomics/TTIOReferenceImport.h"
#include <unistd.h>

static NSString *makeTempPathR(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_ref_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:base];
}

// ---------- helper: encode {ref, refN}... into a transport buffer ----------

static NSData *encodeReferencesAsTransport(
    NSArray<TTIOReferenceImport *> *refs,
    NSError **err)
{
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    if (![w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"ref-rt-test"
                               isaInvestigation:@"ISA_REFRT"
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:err]) return nil;
    for (TTIOReferenceImport *r in refs) {
        if (![w writeReferenceGroup:r error:err]) return nil;
    }
    if (![w writeEndOfStreamWithError:err]) return nil;
    return buf;
}

// ---------- happy-path: single ref, small contig (encoding=0) ----------

static void testReaderDecodesShortReferenceGroup(void)
{
    NSData *chr1 = [@"ACGTACGTACGT" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *chr2 = [@"TTTTAAAACCCC" dataUsingEncoding:NSUTF8StringEncoding];
    TTIOReferenceImport *src =
        [[TTIOReferenceImport alloc] initWithUri:@"reader-rt-v1"
                                     chromosomes:@[@"chr1", @"chr2"]
                                       sequences:@[chr1, chr2]];

    NSError *err = nil;
    NSData *bytes = encodeReferencesAsTransport(@[src], &err);
    PASS(bytes != nil && err == nil,
         "3.3: encodeReferencesAsTransport produced bytes");

    NSString *outPath = makeTempPathR(@"short");
    unlink([outPath fileSystemRepresentation]);

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:bytes];
    err = nil;
    BOOL ok = [r writeTtioToPath:outPath error:&err];
    PASS(ok && err == nil,
         "3.3: writeTtioToPath: materialises ref-only stream");

    TTIOSpectralDataset *opened =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(opened != nil, "3.3: re-opened materialised .tio");

    NSDictionary<NSString *, TTIOReferenceImport *> *refs =
        opened.references;
    PASS([refs count] == 1,
         "3.3: materialised dataset has exactly 1 embedded reference");

    TTIOReferenceImport *got = refs[@"reader-rt-v1"];
    PASS(got != nil, "3.3: reference URI 'reader-rt-v1' present");
    if (got != nil) {
        PASS([got.chromosomes isEqualToArray:(@[@"chr1", @"chr2"])],
             "3.3: chromosomes preserved in alphabetic order");
        PASS([[got chromosomeNamed:@"chr1"] isEqualToData:chr1],
             "3.3: chr1 sequence byte-equal after transport round-trip");
        PASS([[got chromosomeNamed:@"chr2"] isEqualToData:chr2],
             "3.3: chr2 sequence byte-equal after transport round-trip");
        PASS([got totalBases]
                == [src totalBases],
             "3.3: totalBases preserved");
        PASS([got.md5 isEqualToData:src.md5],
             "3.3: MD5 preserved verbatim");
    }

    [opened closeFile];
    unlink([outPath fileSystemRepresentation]);
}

// ---------- zlib path: large contig (encoding=1) ----------

static void testReaderDecodesLargeReferenceGroup(void)
{
    // 8 KiB chromosome to force encoding=1 on the wire.
    NSUInteger n = 8192;
    NSMutableData *big = [NSMutableData dataWithLength:n];
    uint8_t *bbytes = big.mutableBytes;
    static const char *acgt = "ACGT";
    for (NSUInteger i = 0; i < n; i++) bbytes[i] = (uint8_t)acgt[i & 3];

    TTIOReferenceImport *src =
        [[TTIOReferenceImport alloc] initWithUri:@"reader-rt-large"
                                     chromosomes:@[@"chrL"]
                                       sequences:@[big]];

    NSError *err = nil;
    NSData *bytes = encodeReferencesAsTransport(@[src], &err);
    PASS(bytes != nil && err == nil,
         "3.3 zlib: encodeReferencesAsTransport produced bytes");

    NSString *outPath = makeTempPathR(@"large");
    unlink([outPath fileSystemRepresentation]);

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:bytes];
    err = nil;
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "3.3 zlib: writeTtioToPath: materialises large-ref stream");

    TTIOSpectralDataset *opened =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(opened != nil, "3.3 zlib: re-opened materialised .tio");

    TTIOReferenceImport *got = opened.references[@"reader-rt-large"];
    PASS(got != nil, "3.3 zlib: large-ref URI present");
    if (got != nil) {
        NSData *gotSeq = [got chromosomeNamed:@"chrL"];
        PASS(gotSeq.length == n,
             "3.3 zlib: 8 KiB sequence length preserved");
        PASS([gotSeq isEqualToData:big],
             "3.3 zlib: 8 KiB chromosome bytes preserved through inflate");
        PASS([got.md5 isEqualToData:src.md5],
             "3.3 zlib: MD5 preserved verbatim");
    }

    [opened closeFile];
    unlink([outPath fileSystemRepresentation]);
}

// ---------- v0.10 stream stays empty-ref ----------

static void testReaderV010StreamHasNoReferences(void)
{
    // Bare StreamHeader + EOS with no reference packets — the
    // materialised dataset must have an empty references dict.
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"v010-bare"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.3 v0.10: bare StreamHeader");
    PASS([w writeEndOfStreamWithError:&err],
         "3.3 v0.10: EndOfStream");

    NSString *outPath = makeTempPathR(@"v010_bare");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    err = nil;
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "3.3 v0.10: bare stream materialises");

    TTIOSpectralDataset *opened =
        [TTIOSpectralDataset readFromFilePath:outPath error:&err];
    PASS(opened != nil, "3.3 v0.10: opened bare dataset");
    PASS([opened.references count] == 0,
         "3.3 v0.10: bare stream produces empty references dict");
    [opened closeFile];
    unlink([outPath fileSystemRepresentation]);
}

void testTransportReaderReference(void);
void testTransportReaderReference(void)
{
    testReaderDecodesShortReferenceGroup();
    testReaderDecodesLargeReferenceGroup();
    testReaderV010StreamHasNoReferences();
}
