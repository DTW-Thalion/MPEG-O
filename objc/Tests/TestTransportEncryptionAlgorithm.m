/*
 * TestTransportEncryptionAlgorithm.m — Task 3.4 of transport-spec v0.11.
 *
 * Exercises ENCRYPTION_ALGORITHM (0x1B) writer + reader. Wire layout
 * per transport-spec §4.23: `uint16 algorithm_length + bytes
 * algorithm_utf8[length]`, all LE.
 *
 * Cross-language parity:
 *   Java TransportEncryptionAlgorithmTest (commit 530a5833)
 *   Python tests/test_transport_encryption_algorithm.py (commit bf38bdc9)
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
#include <unistd.h>

static NSString *makeTempPathE(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_enc_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:base];
}

// ---------- helper: read u16 LE ----------

static uint16_t leU16(const uint8_t *b)
{
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}

// ---------- writer low-level: single 0x1B packet ----------

static void testWriteEncryptionAlgorithmEmitsSingle0x1BPacket(void)
{
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"enc-test"
                               isaInvestigation:@"isa"
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.4: writeStreamHeader for low-level enc test");
    PASS([w writeEncryptionAlgorithm:@"AES-256-GCM" error:&err],
         "3.4: writeEncryptionAlgorithm emitted bytes");
    PASS([w writeEndOfStreamWithError:&err],
         "3.4: EndOfStream emitted");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records.count == 3,
         "3.4: expected StreamHeader + EncryptionAlgorithm + EndOfStream");
    PASS(records[1].header.packetType
            == TTIOTransportPacketEncryptionAlgorithm,
         "3.4: middle packet is ENCRYPTION_ALGORITHM (0x1B)");

    NSData *payload = records[1].payload;
    const uint8_t *bytes = payload.bytes;
    NSUInteger len = payload.length;
    PASS(len >= 2, "3.4: payload at least 2 bytes (uint16 length)");
    uint16_t algoLen = leU16(bytes);
    NSString *algo = [[NSString alloc] initWithBytes:&bytes[2]
                                                length:algoLen
                                              encoding:NSUTF8StringEncoding];
    PASS([algo isEqualToString:@"AES-256-GCM"],
         "3.4: algorithm decodes to AES-256-GCM");
    PASS((NSUInteger)(2 + algoLen) == len,
         "3.4: payload contains only length + algorithm bytes");
}

// ---------- writer: writeDataset on encrypted .tio emits 0x1B ----------

// Build a .tio whose root carries @encrypted = "aes-256-gcm" by writing
// a plain minimal dataset, then mutating the root attribute directly via
// TTIOHDF5File. Self-contained so we don't depend on TTIOEncryption.
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"

static NSString *buildEncryptedAlgorithmOnlyTio(NSString *base, NSError **err)
{
    NSString *path = makeTempPathE(base);
    unlink([path fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:path
                                                  title:@"enc-fixture"
                                     isaInvestigationId:@"ISA_ENC"
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:err];
    if (!ok) return nil;
    TTIOHDF5File *f = [TTIOHDF5File openAtPath:path error:err];
    if (!f) return nil;
    TTIOHDF5Group *root = [f rootGroup];
    if (![root setStringAttribute:@"encrypted"
                              value:@"aes-256-gcm"
                              error:err]) {
        [f close];
        return nil;
    }
    if (![f close]) return nil;
    return path;
}

static void testWriteDatasetEmitsEncryptionAlgorithmWhenEncrypted(void)
{
    NSError *err = nil;
    NSString *src = buildEncryptedAlgorithmOnlyTio(@"src_enc", &err);
    PASS(src != nil && err == nil, "3.4: built @encrypted fixture .tio");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil && ds.isEncrypted,
         "3.4: fixture dataset reports isEncrypted=YES");
    PASS([ds.encryptedAlgorithm isEqualToString:@"aes-256-gcm"],
         "3.4: fixture dataset reports encryptedAlgorithm=aes-256-gcm");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.4: writeDataset on encrypted .tio");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records != nil, "3.4: reader parsed encrypted-dataset stream");

    // StreamHeader features must carry transport_v0_11. The features
    // list is buried in the payload; quickest check is to scan as
    // UTF-8 bytes (Java + Python tests do the same).
    NSString *sh = [[NSString alloc] initWithData:records[0].payload
                                          encoding:NSUTF8StringEncoding];
    PASS(sh != nil && [sh containsString:@"transport_v0_11"],
         "3.4: StreamHeader carries transport_v0_11 feature flag");

    int encCount = 0;
    NSString *seenAlgo = nil;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketEncryptionAlgorithm) {
            encCount++;
            const uint8_t *bytes = rec.payload.bytes;
            uint16_t algoLen = leU16(bytes);
            seenAlgo = [[NSString alloc] initWithBytes:&bytes[2]
                                                  length:algoLen
                                                encoding:NSUTF8StringEncoding];
        }
    }
    PASS(encCount == 1,
         "3.4: writeDataset on encrypted .tio emits exactly one 0x1B");
    PASS([seenAlgo isEqualToString:@"aes-256-gcm"],
         "3.4: emitted algorithm string matches source");

    [ds closeFile];
    unlink([src fileSystemRepresentation]);
}

// ---------- writer: writeDataset on plain .tio emits NO 0x1B ----------

static void testWriteDatasetNoPacketWhenNotEncrypted(void)
{
    NSError *err = nil;
    NSString *src = makeTempPathE(@"plain");
    unlink([src fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:src
                                                  title:@"plain"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok && err == nil, "3.4 plain: minimal .tio created");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil && !ds.isEncrypted,
         "3.4 plain: dataset reports isEncrypted=NO");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.4 plain: writeDataset on plain .tio");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records != nil, "3.4 plain: reader parsed plain stream");

    BOOL sawEnc = NO;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType
                == TTIOTransportPacketEncryptionAlgorithm) {
            sawEnc = YES;
            break;
        }
    }
    PASS(!sawEnc,
         "3.4 plain: non-encrypted dataset emits no 0x1B packet");

    [ds closeFile];
    unlink([src fileSystemRepresentation]);
}

// ---------- end-to-end round-trip ----------

static void testEncryptionAlgorithmRoundTripsViaMaterialize(void)
{
    NSError *err = nil;
    NSString *src = buildEncryptedAlgorithmOnlyTio(@"src_rt", &err);
    PASS(src != nil, "3.4 rt: built encrypted source");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.4 rt: opened encrypted source");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.4 rt: writeDataset emitted stream");

    NSString *rt = makeTempPathE(@"rt");
    unlink([rt fileSystemRepresentation]);
    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([r writeTtioToPath:rt error:&err] && err == nil,
         "3.4 rt: writeTtioToPath: materialised round-trip .tio");

    TTIOSpectralDataset *back =
        [TTIOSpectralDataset readFromFilePath:rt error:&err];
    PASS(back != nil, "3.4 rt: re-opened materialised .tio");
    PASS(back.isEncrypted,
         "3.4 rt: round-tripped dataset reports isEncrypted=YES");
    PASS([back.encryptedAlgorithm isEqualToString:@"aes-256-gcm"],
         "3.4 rt: round-tripped algorithm matches source");

    [ds closeFile];
    [back closeFile];
    unlink([src fileSystemRepresentation]);
    unlink([rt fileSystemRepresentation]);
}

void testTransportEncryptionAlgorithm(void);
void testTransportEncryptionAlgorithm(void)
{
    testWriteEncryptionAlgorithmEmitsSingle0x1BPacket();
    testWriteDatasetEmitsEncryptionAlgorithmWhenEncrypted();
    testWriteDatasetNoPacketWhenNotEncrypted();
    testEncryptionAlgorithmRoundTripsViaMaterialize();
}
