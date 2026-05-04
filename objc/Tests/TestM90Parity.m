// TestM90Parity.m - M90.8 + M90.9 + M90.10 ObjC parity tests.
//
// Mirrors the Python tests:
//   python/tests/test_m90_8_encrypted_transport_genomic.py
//   python/tests/test_m90_9_au_compound_fields.py
//   python/tests/test_m90_10_genomic_wire_codec.py
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import <string.h>
#import <unistd.h>

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOAccessUnit.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOEncryptedTransport.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Protection/TTIOPerAUFile.h"
#import "ValueClasses/TTIOEnums.h"

static NSString *m90TmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m90parity_%d_%@",
            (int)getpid(), suffix];
}

static void m90RmFile(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static TTIOWrittenGenomicRun *makeM90GenomicRun(NSDictionary<NSString *, NSNumber *> *codecOverrides)
{
    NSUInteger n = 4;
    NSUInteger L = 8;
    NSArray<NSString *> *chroms = @[@"chr1", @"chr1", @"chr2", @"chr2"];
    int64_t positions[4] = {100, 200, 300, 400};
    uint8_t mapqs[4] = {60, 60, 60, 60};
    uint32_t flags[4] = {0x0003, 0x0003, 0x0003, 0x0003};
    NSData *positionsData = [NSData dataWithBytes:positions length:sizeof(positions)];
    NSData *mqData = [NSData dataWithBytes:mapqs length:sizeof(mapqs)];
    NSData *flagsData = [NSData dataWithBytes:flags length:sizeof(flags)];

    NSMutableData *seqData = [NSMutableData dataWithCapacity:n * L];
    for (NSUInteger i = 0; i < n; i++) {
        [seqData appendBytes:"ACGTACGT" length:L];
    }
    NSMutableData *qualData = [NSMutableData dataWithLength:n * L];
    memset(qualData.mutableBytes, 30, n * L);

    uint64_t offsets[4] = {0, 8, 16, 24};
    uint32_t lengths[4] = {8, 8, 8, 8};
    NSData *offsetsData = [NSData dataWithBytes:offsets length:sizeof(offsets)];
    NSData *lengthsData = [NSData dataWithBytes:lengths length:sizeof(lengths)];

    NSArray *cigars = @[@"8M", @"4M2I2M", @"5M3D", @"2S6M"];
    NSArray *names = @[@"read_aaaa", @"read_bbbb", @"read_cccc", @"read_dddd"];
    NSArray *mateChroms = @[@"chr1", @"chr1", @"=", @""];

    int64_t mp[4] = {350, 200, 0, -1};
    NSData *matePosData = [NSData dataWithBytes:mp length:sizeof(mp)];
    int32_t tl[4] = {250, 0, -300, 0};
    NSData *tlenData = [NSData dataWithBytes:tl length:sizeof(tl)];

    TTIOWrittenGenomicRun *run =
        [[TTIOWrittenGenomicRun alloc]
         initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                    referenceUri:@"GRCh38.p14"
                        platform:@"ILLUMINA"
                      sampleName:@"NA12878"
                       positions:positionsData
                mappingQualities:mqData
                           flags:flagsData
                       sequences:seqData
                       qualities:qualData
                         offsets:offsetsData
                         lengths:lengthsData
                          cigars:cigars
                       readNames:names
                 mateChromosomes:mateChroms
                   matePositions:matePosData
                 templateLengths:tlenData
                     chromosomes:chroms
               signalCompression:TTIOCompressionNone
            signalCodecOverrides:(codecOverrides ?: @{})];
    return run;
}

static void testM90_9_AUMateExtensionRoundTrip(void)
{
    TTIOAccessUnit *au = [[TTIOAccessUnit alloc]
        initWithSpectrumClass:5
              acquisitionMode:7 msLevel:0 polarity:2
                retentionTime:0.0 precursorMz:0.0 precursorCharge:0
                  ionMobility:0.0 basePeakIntensity:0.0
                     channels:@[]
                       pixelX:0 pixelY:0 pixelZ:0
                   chromosome:@"chr1" position:100 mappingQuality:60
                        flags:0x0003 matePosition:350 templateLength:250];
    NSData *encoded = [au encode];
    NSError *err = nil;
    TTIOAccessUnit *decoded =
        [TTIOAccessUnit decodeFromBytes:encoded.bytes
                                  length:encoded.length error:&err];
    PASS(decoded != nil, "M90.9: AU with mate extension decodes");
    PASS([decoded.chromosome isEqualToString:@"chr1"],
         "M90.9: chromosome round-trips");
    PASS(decoded.position == 100, "M90.9: position round-trips");
    PASS(decoded.matePosition == 350, "M90.9: matePosition round-trips");
    PASS(decoded.templateLength == 250, "M90.9: templateLength round-trips");
}

static void testM90_9_BackwardCompatNoMateExtension(void)
{
    // Build an M90.9-vintage AU then truncate to drop the 12-byte
    // mate extension (M89.1-shaped payload). Decoder must default
    // matePosition to -1 and templateLength to 0.
    TTIOAccessUnit *au = [[TTIOAccessUnit alloc]
        initWithSpectrumClass:5
              acquisitionMode:7 msLevel:0 polarity:2
                retentionTime:0.0 precursorMz:0.0 precursorCharge:0
                  ionMobility:0.0 basePeakIntensity:0.0
                     channels:@[]
                       pixelX:0 pixelY:0 pixelZ:0
                   chromosome:@"chr1" position:100 mappingQuality:60
                        flags:0x0003 matePosition:999 templateLength:777];
    NSData *full = [au encode];
    NSData *m89Payload = [full subdataWithRange:NSMakeRange(0, full.length - 12)];
    NSError *err = nil;
    TTIOAccessUnit *decoded =
        [TTIOAccessUnit decodeFromBytes:m89Payload.bytes
                                  length:m89Payload.length error:&err];
    PASS(decoded != nil, "M90.9: M89.1 payload still decodes");
    PASS([decoded.chromosome isEqualToString:@"chr1"],
         "M90.9: M89.1 chromosome preserved");
    PASS(decoded.matePosition == -1,
         "M90.9: M89.1 payload defaults matePosition to -1");
    PASS(decoded.templateLength == 0,
         "M90.9: M89.1 payload defaults templateLength to 0");
}

static void testM90_9_RoundTripCompoundFields(void)
{
    NSString *srcPath = m90TmpPath(@"m9_src.tio");
    NSString *rtPath = m90TmpPath(@"m9_rt.tio");
    m90RmFile(srcPath);
    m90RmFile(rtPath);

    TTIOWrittenGenomicRun *wgr = makeM90GenomicRun(nil);
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:srcPath
                                                  title:@"M90.9 fixture"
                                    isaInvestigationId:@"ISA-M90-9"
                                                msRuns:@{}
                                            genomicRuns:@{@"genomic_0001": wgr}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "M90.9: source genomic .tio written");

    TTIOSpectralDataset *src = [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
    PASS(src != nil, "M90.9: source genomic .tio re-readable");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([tw writeDataset:src error:&err], "M90.9: writeDataset emits genomic stream");
    [tw close];

    TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([tr writeTtioToPath:rtPath error:&err],
         "M90.9: transport stream materialises back to .tio");
    TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:rtPath error:&err];
    PASS(rt != nil, "M90.9: round-tripped .tio opens");

    TTIOGenomicRun *gr = rt.genomicRuns[@"genomic_0001"];
    PASS(gr != nil && gr.readCount == 4, "M90.9: 4 reads round-trip");

    TTIOAlignedRead *r0 = [gr readAtIndex:0 error:&err];
    TTIOAlignedRead *r1 = [gr readAtIndex:1 error:&err];
    TTIOAlignedRead *r2 = [gr readAtIndex:2 error:&err];
    TTIOAlignedRead *r3 = [gr readAtIndex:3 error:&err];
    PASS(r0 && r1 && r2 && r3, "M90.9: 4 reads materialise");
    PASS([r0.cigar isEqualToString:@"8M"]
         && [r1.cigar isEqualToString:@"4M2I2M"]
         && [r2.cigar isEqualToString:@"5M3D"]
         && [r3.cigar isEqualToString:@"2S6M"],
         "M90.9: cigars round-trip per-AU");
    PASS([r0.readName isEqualToString:@"read_aaaa"]
         && [r3.readName isEqualToString:@"read_dddd"],
         "M90.9: read_names round-trip");
    // v1.7 #11: After a transport round-trip the TTIOTransportReader
    // reconstructs a fresh TTIOWrittenGenomicRun (no opt-out flag) which is
    // re-serialised via inline_v2.  The v2 codec normalises:
    //   ""  (v1 unmapped sentinel) → "*"
    //   "=" (same-chrom shorthand) → resolved chromosome name ("chr2" for r2)
    PASS([r0.mateChromosome isEqualToString:@"chr1"]
         && [r2.mateChromosome isEqualToString:@"chr2"]
         && [r3.mateChromosome isEqualToString:@"*"],
         "M90.9: mate_chromosomes round-trip");
    PASS(r0.matePosition == 350 && r1.matePosition == 200
         && r2.matePosition == 0 && r3.matePosition == -1,
         "M90.9: matePositions round-trip");
    PASS(r0.templateLength == 250 && r1.templateLength == 0
         && r2.templateLength == -300 && r3.templateLength == 0,
         "M90.9: templateLengths round-trip");

    [src closeFile];
    [rt closeFile];
    m90RmFile(srcPath);
    m90RmFile(rtPath);
}

static NSDictionary<NSString *, NSArray<NSNumber *> *> *
auCompressionsPerChannel(NSData *streamBytes)
{
    NSMutableDictionary<NSString *, NSMutableArray *> *out = [NSMutableDictionary dictionary];
    TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:streamBytes];
    NSArray<TTIOTransportPacketRecord *> *packets = [tr readAllPacketsWithError:NULL];
    for (TTIOTransportPacketRecord *rec in packets) {
        if (rec.header.packetType != TTIOTransportPacketAccessUnit) continue;
        TTIOAccessUnit *au = [TTIOAccessUnit decodeFromBytes:rec.payload.bytes
                                                       length:rec.payload.length
                                                        error:NULL];
        if (!au) continue;
        for (TTIOTransportChannelData *ch in au.channels) {
            NSMutableArray *arr = out[ch.name];
            if (!arr) { arr = [NSMutableArray array]; out[ch.name] = arr; }
            [arr addObject:@(ch.compression)];
        }
    }
    return out;
}

static void testM90_10_NoCodecSourceEmitsUncompressed(void)
{
    NSString *srcPath = m90TmpPath(@"m10_none.tio");
    m90RmFile(srcPath);
    TTIOWrittenGenomicRun *wgr = makeM90GenomicRun(nil);
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:srcPath
                                       title:@"M90.10 none"
                         isaInvestigationId:@"ISA-M90-10"
                                     msRuns:@{}
                                 genomicRuns:@{@"genomic_0001": wgr}
                             identifications:nil
                             quantifications:nil
                           provenanceRecords:nil
                                       error:&err];
    TTIOSpectralDataset *src = [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
    [tw writeDataset:src error:&err];
    [tw close];

    NSDictionary *codecs = auCompressionsPerChannel(buf);
    BOOL allNone = YES;
    for (NSNumber *n in codecs[@"sequences"]) {
        if (n.unsignedIntValue != TTIOCompressionNone) { allNone = NO; break; }
    }
    PASS(allNone && [codecs[@"sequences"] count] == 4,
         "M90.10: no-codec source emits NONE on sequences for every AU");
    BOOL qualNone = YES;
    for (NSNumber *n in codecs[@"qualities"]) {
        if (n.unsignedIntValue != TTIOCompressionNone) { qualNone = NO; break; }
    }
    PASS(qualNone && [codecs[@"qualities"] count] == 4,
         "M90.10: no-codec source emits NONE on qualities for every AU");

    [src closeFile];
    m90RmFile(srcPath);
}

static void testM90_10_BasePackSourceEmitsBasePackWire(void)
{
    NSString *srcPath = m90TmpPath(@"m10_bp.tio");
    m90RmFile(srcPath);
    TTIOWrittenGenomicRun *wgr = makeM90GenomicRun(@{
        @"sequences": @(TTIOCompressionBasePack),
    });
    NSError *err = nil;
    [TTIOSpectralDataset writeMinimalToPath:srcPath
                                       title:@"M90.10 bp"
                         isaInvestigationId:@"ISA-M90-10"
                                     msRuns:@{}
                                 genomicRuns:@{@"genomic_0001": wgr}
                             identifications:nil
                             quantifications:nil
                           provenanceRecords:nil
                                       error:&err];
    TTIOSpectralDataset *src = [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
    [tw writeDataset:src error:&err];
    [tw close];

    NSDictionary *codecs = auCompressionsPerChannel(buf);
    BOOL allBP = YES;
    for (NSNumber *n in codecs[@"sequences"]) {
        if (n.unsignedIntValue != TTIOCompressionBasePack) { allBP = NO; break; }
    }
    PASS(allBP && [codecs[@"sequences"] count] == 4,
         "M90.10: BASE_PACK source emits BASE_PACK on sequences for every AU");
    BOOL qualNone = YES;
    for (NSNumber *n in codecs[@"qualities"]) {
        if (n.unsignedIntValue != TTIOCompressionNone) { qualNone = NO; break; }
    }
    PASS(qualNone, "M90.10: qualities stays NONE when only sequences opts in");

    [src closeFile];
    m90RmFile(srcPath);
}

static void testM90_10_RoundTripPreservesBytes(void)
{
    TTIOCompression codecs[3] = {
        TTIOCompressionRansOrder0,
        TTIOCompressionRansOrder1,
        TTIOCompressionBasePack,
    };
    for (int ci = 0; ci < 3; ci++) {
        NSString *srcPath = m90TmpPath([NSString stringWithFormat:@"m10_rt_%d.tio", (int)codecs[ci]]);
        NSString *rtPath = m90TmpPath([NSString stringWithFormat:@"m10_out_%d.tio", (int)codecs[ci]]);
        m90RmFile(srcPath);
        m90RmFile(rtPath);
        TTIOWrittenGenomicRun *wgr = makeM90GenomicRun(@{
            @"sequences": @(codecs[ci]),
        });
        NSError *err = nil;
        [TTIOSpectralDataset writeMinimalToPath:srcPath
                                           title:@"M90.10 rt"
                             isaInvestigationId:@"ISA-M90-10"
                                         msRuns:@{}
                                     genomicRuns:@{@"genomic_0001": wgr}
                                 identifications:nil
                                 quantifications:nil
                               provenanceRecords:nil
                                           error:&err];
        TTIOSpectralDataset *src = [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
        NSMutableData *buf = [NSMutableData data];
        TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
        [tw writeDataset:src error:&err];
        [tw close];

        TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:buf];
        BOOL ok = [tr writeTtioToPath:rtPath error:&err];
        PASS(ok, "M90.10: codec round-trip materialises .tio");
        TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:rtPath error:&err];
        TTIOGenomicRun *gr = rt.genomicRuns[@"genomic_0001"];
        PASS(gr != nil && gr.readCount == 4, "M90.10: 4 reads round-trip via codec");
        for (NSUInteger i = 0; i < gr.readCount; i++) {
            TTIOAlignedRead *r = [gr readAtIndex:i error:&err];
            PASS([r.sequence isEqualToString:@"ACGTACGT"],
                 "M90.10: per-read sequence ACGTACGT preserved through codec");
        }
        [src closeFile];
        [rt closeFile];
        m90RmFile(srcPath);
        m90RmFile(rtPath);
    }
}

static void testM90_8_GenomicEncryptedRoundTrip(void)
{
    NSString *srcPath = m90TmpPath(@"m8_src.tio");
    NSString *rtPath = m90TmpPath(@"m8_rt.tio");
    m90RmFile(srcPath);
    m90RmFile(rtPath);

    TTIOWrittenGenomicRun *wgr = makeM90GenomicRun(nil);
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:srcPath
                                                  title:@"M90.8 enc-transport genomic fixture"
                                    isaInvestigationId:@"ISA-M90-8"
                                                msRuns:@{}
                                            genomicRuns:@{@"genomic_0001": wgr}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "M90.8: source genomic .tio written");

    uint8_t keyBuf[32]; memset(keyBuf, 0x42, 32);
    NSData *key = [NSData dataWithBytes:keyBuf length:32];
    BOOL encOk = [TTIOPerAUFile encryptFilePath:srcPath
                                              key:key
                                  encryptHeaders:NO
                                     providerName:nil
                                            error:&err];
    PASS(encOk, "M90.8: encryptFilePath on genomic .tio");
    PASS([TTIOEncryptedTransport isPerAUEncryptedAtPath:srcPath providerName:nil],
         "M90.8: file detected as per-AU-encrypted after encryption");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
    BOOL writeOk = [TTIOEncryptedTransport writeEncryptedDataset:srcPath
                                                            writer:tw
                                                      providerName:nil
                                                             error:&err];
    PASS(writeOk, "M90.8: writeEncryptedDataset emits genomic dataset");
    [tw close];

    BOOL readOk = [TTIOEncryptedTransport readEncryptedToPath:rtPath
                                                   fromStream:buf
                                                  providerName:nil
                                                         error:&err];
    PASS(readOk, "M90.8: readEncryptedToPath rebuilds genomic .tio");

    // decryptInPlaceAtPath only handles MS runs; for genomic we use
    // decryptFilePath which returns {run: {channel: NSData}} maps.
    NSDictionary *plainMap = [TTIOPerAUFile decryptFilePath:rtPath
                                                          key:key
                                                 providerName:nil
                                                        error:&err];
    PASS(plainMap != nil, "M90.8: decryptFilePath on materialised .tio");
    NSDictionary *genomic = plainMap[@"genomic_0001"];
    PASS(genomic != nil, "M90.8: genomic_0001 present in plaintext map");
    NSData *seq = genomic[@"sequences"];
    PASS(seq.length == 32,
         "M90.8: sequences plaintext is 4 reads x 8 bases = 32 bytes");
    NSData *expected = [NSData dataWithBytes:"ACGTACGTACGTACGTACGTACGTACGTACGT" length:32];
    PASS([seq isEqualToData:expected],
         "M90.8: sequences plaintext byte-exact after enc round-trip");
    NSData *qual = genomic[@"qualities"];
    PASS(qual.length == 32,
         "M90.8: qualities plaintext is 32 bytes");
    BOOL allThirty = YES;
    const uint8_t *qb = (const uint8_t *)qual.bytes;
    for (NSUInteger i = 0; i < qual.length; i++) {
        if (qb[i] != 30) { allThirty = NO; break; }
    }
    PASS(allThirty, "M90.8: qualities plaintext all 30 (Phred)");
    m90RmFile(srcPath);
    m90RmFile(rtPath);
}

void testM90Parity(void)
{
    testM90_9_AUMateExtensionRoundTrip();
    testM90_9_BackwardCompatNoMateExtension();
    testM90_9_RoundTripCompoundFields();

    testM90_10_NoCodecSourceEmitsUncompressed();
    testM90_10_BasePackSourceEmitsBasePackWire();
    testM90_10_RoundTripPreservesBytes();

    testM90_8_GenomicEncryptedRoundTrip();
}
