// TestM89GenomicTransport.m — v0.11 M89 ObjC parity.
//
// Mirrors the Python tests:
//   python/tests/test_transport_packets.py    (TestAccessUnit::test_genomic_*)
//   python/tests/test_transport_codec.py      (TestGenomicRoundTrip,
//                                              TestMultiplexedRoundTrip)
//   python/tests/test_au_filter.py            (TestGenomicPredicates)
//   python/tests/test_m89_5_genomic_encryption.py
//
// Locked wire layout (transport-spec §4.3.4, AU spectrum_class==5):
//   chromosome_len  uint16 LE
//   chromosome      bytes[chromosome_len]  UTF-8
//   position        int64  LE   (-1 = unmapped, BAM convention)
//   mapping_quality uint8
//   flags           uint16 LE
//
// SPDX-License-Identifier: LGPL-3.0-or-later

#import <Foundation/Foundation.h>
#import "Testing.h"
#import <string.h>
#import <unistd.h>

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOAccessUnit.h"
#import "Transport/TTIOAUFilter.h"
#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOTransportReader.h"
#import "Dataset/TTIOSpectralDataset.h"
#import "Dataset/TTIOWrittenRun.h"
#import "Genomics/TTIOWrittenGenomicRun.h"
#import "Genomics/TTIOGenomicRun.h"
#import "Genomics/TTIOGenomicIndex.h"
#import "Genomics/TTIOAlignedRead.h"
#import "Protection/TTIOPerAUEncryption.h"
#import "ValueClasses/TTIOEnums.h"

// ── Helpers ────────────────────────────────────────────────────────

static NSString *m89TmpPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m89_%d_%@",
            (int)getpid(), suffix];
}

static void m89RmFile(NSString *path)
{
    [[NSFileManager defaultManager] removeItemAtPath:path error:NULL];
}

static TTIOAccessUnit *makeGenomicAU(NSString *chromosome,
                                       int64_t position,
                                       uint8_t mapq,
                                       uint16_t flags,
                                       NSArray<TTIOTransportChannelData *> *channels)
{
    return [[TTIOAccessUnit alloc]
        initWithSpectrumClass:5
              acquisitionMode:0
                      msLevel:0
                     polarity:2
                retentionTime:0.0
                  precursorMz:0.0
              precursorCharge:0
                  ionMobility:0.0
            basePeakIntensity:0.0
                     channels:(channels ?: @[])
                       pixelX:0 pixelY:0 pixelZ:0
                   chromosome:chromosome
                     position:position
               mappingQuality:mapq
                        flags:flags];
}

static TTIOAccessUnit *makeMSAU(double rt, uint8_t msLevel, uint8_t polarity)
{
    return [[TTIOAccessUnit alloc]
        initWithSpectrumClass:0
              acquisitionMode:0
                      msLevel:msLevel
                     polarity:polarity
                retentionTime:rt
                  precursorMz:0.0
              precursorCharge:0
                  ionMobility:0.0
            basePeakIntensity:100.0
                     channels:@[]
                       pixelX:0 pixelY:0 pixelZ:0];
}

// ── 1. AccessUnit suffix round-trips ───────────────────────────────

static void testGenomicAURoundTrip(void)
{
    TTIOTransportChannelData *seq =
        [[TTIOTransportChannelData alloc] initWithName:@"seq"
                                              precision:TTIOPrecisionUInt8
                                            compression:TTIOCompressionNone
                                              nElements:8
                                                   data:[NSData dataWithBytes:"\0\0\0\0\0\0\0\0" length:8]];
    TTIOAccessUnit *au = makeGenomicAU(@"chr1", 123456789, 60, 0x0003, @[seq]);
    NSData *encoded = [au encode];
    NSError *err = nil;
    TTIOAccessUnit *decoded =
        [TTIOAccessUnit decodeFromBytes:encoded.bytes length:encoded.length error:&err];
    PASS(decoded != nil, "M89.1: GenomicRead AU decodes successfully");
    PASS(decoded.spectrumClass == 5, "M89.1: spectrumClass == 5 round-trips");
    PASS([decoded.chromosome isEqualToString:@"chr1"],
         "M89.1: chromosome 'chr1' round-trips");
    PASS(decoded.position == 123456789,
         "M89.1: position 123456789 round-trips");
    PASS(decoded.mappingQuality == 60,
         "M89.1: mappingQuality 60 round-trips");
    PASS(decoded.flags == 0x0003,
         "M89.1: flags 0x0003 round-trips");
    PASS(decoded.channels.count == 1,
         "M89.1: channels preserved alongside genomic suffix");
}

static void testGenomicAUUnmapped(void)
{
    TTIOAccessUnit *au = makeGenomicAU(@"*", -1, 0, 0x0004, @[]);
    NSData *encoded = [au encode];
    NSError *err = nil;
    TTIOAccessUnit *decoded =
        [TTIOAccessUnit decodeFromBytes:encoded.bytes length:encoded.length error:&err];
    PASS(decoded != nil, "M89.1: unmapped AU decodes");
    PASS([decoded.chromosome isEqualToString:@"*"],
         "M89.1: chromosome='*' (unmapped sentinel) round-trips");
    PASS(decoded.position == -1,
         "M89.1: position=-1 (BAM unmapped) round-trips");
    PASS(decoded.flags == 0x0004,
         "M89.1: flags 0x0004 (segment unmapped) round-trips");
}

static void testGenomicAULongChromosomeAndMaxes(void)
{
    NSString *longChr = @"chr22_KI270739v1_random";
    TTIOAccessUnit *au = makeGenomicAU(longChr, 42, 255, 0xFFFF, @[]);
    NSData *encoded = [au encode];
    NSError *err = nil;
    TTIOAccessUnit *decoded =
        [TTIOAccessUnit decodeFromBytes:encoded.bytes length:encoded.length error:&err];
    PASS(decoded != nil, "M89.1: long-chromosome AU decodes");
    PASS([decoded.chromosome isEqualToString:longChr],
         "M89.1: long decoy contig name round-trips");
    PASS(decoded.mappingQuality == 255,
         "M89.1: mappingQuality 255 (u8 max) round-trips");
    PASS(decoded.flags == 0xFFFF,
         "M89.1: flags 0xFFFF (u16 max) round-trips");
}

static void testGenomicAUTruncatedSuffix(void)
{
    TTIOAccessUnit *au = makeGenomicAU(@"chr1", 100, 60, 0, @[]);
    NSData *full = [au encode];
    // Drop the trailing flags (last 2 bytes) so the suffix is short.
    NSData *truncated = [full subdataWithRange:NSMakeRange(0, full.length - 2)];
    NSError *err = nil;
    TTIOAccessUnit *decoded =
        [TTIOAccessUnit decodeFromBytes:truncated.bytes length:truncated.length error:&err];
    PASS(decoded == nil,
         "M89.1: truncated suffix returns nil (does not silently zero-fill)");
    PASS(err != nil && err.code == TTIOTransportErrorTruncated,
         "M89.1: truncated suffix yields Truncated error");
    NSString *desc = err.userInfo[NSLocalizedDescriptionKey];
    PASS(desc && [desc rangeOfString:@"GenomicRead"].location != NSNotFound,
         "M89.1: error message names GenomicRead suffix");
}

static void testGenomicSuffixOnlyWhenClass5(void)
{
    // An MS-class AU with chromosome accidentally set must not write
    // a genomic suffix; decoding back yields default values.
    TTIOAccessUnit *au = [[TTIOAccessUnit alloc]
        initWithSpectrumClass:0
              acquisitionMode:0
                      msLevel:1
                     polarity:0
                retentionTime:1.0
                  precursorMz:0.0
              precursorCharge:0
                  ionMobility:0.0
            basePeakIntensity:0.0
                     channels:@[]
                       pixelX:0 pixelY:0 pixelZ:0
                   chromosome:@"should-be-ignored"
                     position:999
               mappingQuality:42
                        flags:0xBEEF];
    NSData *encoded = [au encode];
    NSError *err = nil;
    TTIOAccessUnit *decoded =
        [TTIOAccessUnit decodeFromBytes:encoded.bytes length:encoded.length error:&err];
    PASS(decoded != nil, "M89.1: MS AU with stray chromosome decodes");
    PASS(decoded.spectrumClass == 0,
         "M89.1: spectrum_class 0 preserved");
    PASS([decoded.chromosome isEqualToString:@""],
         "M89.1: MS AU chromosome silently defaults to empty string");
    PASS(decoded.position == 0,
         "M89.1: MS AU position defaults to 0");
    PASS(decoded.mappingQuality == 0,
         "M89.1: MS AU mappingQuality defaults to 0");
    PASS(decoded.flags == 0,
         "M89.1: MS AU flags defaults to 0");
}

// ── 2. AUFilter genomic predicates (M89.3) ─────────────────────────

static TTIOAUFilter *filterFromJSON(NSString *json)
{
    return [TTIOAUFilter filterFromQueryJSON:json];
}

static void testAUFilterChromosomeMatch(void)
{
    TTIOAUFilter *f = filterFromJSON(@"{\"type\":\"query\",\"filters\":{\"chromosome\":\"chr1\"}}");
    TTIOAccessUnit *chr1 = makeGenomicAU(@"chr1", 100, 60, 0, @[]);
    TTIOAccessUnit *chr2 = makeGenomicAU(@"chr2", 100, 60, 0, @[]);
    PASS([f matches:chr1 datasetId:1], "M89.3: chromosome=chr1 filter matches chr1 AU");
    PASS(![f matches:chr2 datasetId:1], "M89.3: chromosome=chr1 filter excludes chr2 AU");
}

static void testAUFilterPositionRange(void)
{
    TTIOAUFilter *f = filterFromJSON(
        @"{\"type\":\"query\",\"filters\":{\"position_min\":100,\"position_max\":200}}");
    PASS(![f matches:makeGenomicAU(@"chr1", 50, 60, 0, @[]) datasetId:1],
         "M89.3: position 50 < min=100 excluded");
    PASS([f matches:makeGenomicAU(@"chr1", 100, 60, 0, @[]) datasetId:1],
         "M89.3: position 100 == min included (inclusive)");
    PASS([f matches:makeGenomicAU(@"chr1", 150, 60, 0, @[]) datasetId:1],
         "M89.3: position 150 in range included");
    PASS([f matches:makeGenomicAU(@"chr1", 200, 60, 0, @[]) datasetId:1],
         "M89.3: position 200 == max included (inclusive)");
    PASS(![f matches:makeGenomicAU(@"chr1", 201, 60, 0, @[]) datasetId:1],
         "M89.3: position 201 > max excluded");
}

static void testAUFilterChromosomeAndPositionCombined(void)
{
    TTIOAUFilter *f = filterFromJSON(
        @"{\"type\":\"query\",\"filters\":{\"chromosome\":\"chr3\",\"position_min\":1000,\"position_max\":2000}}");
    PASS([f matches:makeGenomicAU(@"chr3", 1500, 60, 0, @[]) datasetId:1],
         "M89.3: chr3 + position 1500 in [1000,2000] included");
    PASS(![f matches:makeGenomicAU(@"chr1", 1500, 60, 0, @[]) datasetId:1],
         "M89.3: wrong chromosome excluded even when position matches");
    PASS(![f matches:makeGenomicAU(@"chr3", 500, 60, 0, @[]) datasetId:1],
         "M89.3: right chromosome but position out of range excluded");
}

static void testAUFilterUnmappedReadsMatchStar(void)
{
    TTIOAUFilter *f = filterFromJSON(
        @"{\"type\":\"query\",\"filters\":{\"chromosome\":\"*\"}}");
    PASS([f matches:makeGenomicAU(@"*", -1, 0, 0x0004, @[]) datasetId:1],
         "M89.3: chromosome=* matches BAM unmapped sentinel");
}

static void testAUFilterChromosomeExcludesMS(void)
{
    TTIOAUFilter *f = filterFromJSON(
        @"{\"type\":\"query\",\"filters\":{\"chromosome\":\"chr1\"}}");
    TTIOAccessUnit *ms = makeMSAU(1.0, 1, 0);
    PASS(![f matches:ms datasetId:1],
         "M89.3: chromosome filter excludes MS AU (chromosome defaults to empty)");
}

static void testAUFilterPositionExcludesMS(void)
{
    TTIOAUFilter *f = filterFromJSON(
        @"{\"type\":\"query\",\"filters\":{\"position_min\":100}}");
    TTIOAccessUnit *ms = makeMSAU(1.0, 1, 0);
    PASS(![f matches:ms datasetId:1],
         "M89.3: position filter excludes MS AU (no position semantics)");
}

static void testAUFilterEmptyAcceptsAllGenomic(void)
{
    TTIOAUFilter *f = [TTIOAUFilter emptyFilter];
    PASS([f matches:makeGenomicAU(@"chrZ", 999, 60, 0, @[]) datasetId:1],
         "M89.3: empty filter accepts every genomic AU");
}

// ── 3. Per-AU AES-GCM round-trip preserves the genomic suffix (M89.5)

static TTIOAccessUnit *makeGenomicAUWithSeqQual(NSString *chrom, int64_t pos,
                                                  uint8_t mapq, uint16_t flags,
                                                  NSData *seq, NSData *qual)
{
    TTIOTransportChannelData *seqCh =
        [[TTIOTransportChannelData alloc] initWithName:@"sequences"
                                              precision:TTIOPrecisionUInt8
                                            compression:TTIOCompressionNone
                                              nElements:(uint32_t)seq.length
                                                   data:seq];
    TTIOTransportChannelData *qualCh =
        [[TTIOTransportChannelData alloc] initWithName:@"qualities"
                                              precision:TTIOPrecisionUInt8
                                            compression:TTIOCompressionNone
                                              nElements:(uint32_t)qual.length
                                                   data:qual];
    return makeGenomicAU(chrom, pos, mapq, flags, @[seqCh, qualCh]);
}

static void testGenomicAUEncryptionRoundTrip(void)
{
    uint8_t keyBuf[32]; memset(keyBuf, 0x42, 32);
    uint8_t ivBuf[12];  memset(ivBuf, 0x11, 12);
    NSData *key = [NSData dataWithBytes:keyBuf length:32];
    NSData *iv = [NSData dataWithBytes:ivBuf length:12];
    NSData *aad = [@"m89-genomic" dataUsingEncoding:NSUTF8StringEncoding];

    NSData *seq = [@"ACGTACGT" dataUsingEncoding:NSASCIIStringEncoding];
    NSMutableData *qual = [NSMutableData dataWithLength:8];
    memset(qual.mutableBytes, 30, 8);

    TTIOAccessUnit *au = makeGenomicAUWithSeqQual(
        @"chr1", 123456789, 60, 0x0003, seq, qual);
    NSData *plaintext = [au encode];
    NSData *tag = nil;
    NSError *err = nil;
    NSData *ct = [TTIOPerAUEncryption encryptWithPlaintext:plaintext
                                                        key:key iv:iv aad:aad
                                                     outTag:&tag error:&err];
    PASS(ct != nil && tag.length == 16,
         "M89.5: AES-GCM encrypts genomic AU bytes");

    NSData *roundTripPt = [TTIOPerAUEncryption decryptWithCiphertext:ct
                                                                 key:key iv:iv tag:tag aad:aad
                                                               error:&err];
    PASS([roundTripPt isEqualToData:plaintext],
         "M89.5: decrypt recovers exact plaintext");

    TTIOAccessUnit *decoded =
        [TTIOAccessUnit decodeFromBytes:roundTripPt.bytes
                                  length:roundTripPt.length
                                   error:&err];
    PASS(decoded != nil, "M89.5: decrypted bytes parse back as AU");
    PASS(decoded.spectrumClass == 5, "M89.5: spectrum_class==5 preserved");
    PASS([decoded.chromosome isEqualToString:@"chr1"],
         "M89.5: chromosome preserved through AES-GCM");
    PASS(decoded.position == 123456789,
         "M89.5: position preserved through AES-GCM");
    PASS(decoded.mappingQuality == 60,
         "M89.5: mappingQuality preserved through AES-GCM");
    PASS(decoded.flags == 0x0003,
         "M89.5: flags preserved through AES-GCM");
    PASS(decoded.channels.count == 2,
         "M89.5: sequences + qualities channels preserved");
}

static void testGenomicAUEncryptionUnmapped(void)
{
    uint8_t keyBuf[32]; memset(keyBuf, 0x42, 32);
    uint8_t ivBuf[12];  memset(ivBuf, 0x77, 12);
    NSData *key = [NSData dataWithBytes:keyBuf length:32];
    NSData *iv = [NSData dataWithBytes:ivBuf length:12];
    NSData *aad = [@"m89-unmapped" dataUsingEncoding:NSUTF8StringEncoding];

    TTIOAccessUnit *au = makeGenomicAUWithSeqQual(
        @"*", -1, 0, 0x0004,
        [@"NNNNNN" dataUsingEncoding:NSASCIIStringEncoding],
        [NSMutableData dataWithLength:6]);
    NSData *pt = [au encode];
    NSData *tag = nil;
    NSError *err = nil;
    NSData *ct = [TTIOPerAUEncryption encryptWithPlaintext:pt
                                                        key:key iv:iv aad:aad
                                                     outTag:&tag error:&err];
    PASS(ct != nil, "M89.5: encrypts unmapped genomic AU");
    NSData *back = [TTIOPerAUEncryption decryptWithCiphertext:ct
                                                          key:key iv:iv tag:tag aad:aad
                                                        error:&err];
    TTIOAccessUnit *dec = [TTIOAccessUnit decodeFromBytes:back.bytes length:back.length error:&err];
    PASS([dec.chromosome isEqualToString:@"*"],
         "M89.5: unmapped chromosome '*' preserved through encryption");
    PASS(dec.position == -1,
         "M89.5: unmapped position -1 preserved through encryption");
    PASS(dec.flags == 0x0004,
         "M89.5: unmapped flag 0x0004 preserved through encryption");
}

// ── 4. M89.2 GenomicRun round-trip via writeGenomicRun: ────────────

// Build a 4-read minimal genomic run mirroring the Python fixture.
static TTIOWrittenGenomicRun *makeMinimalGenomicWrittenRun(void)
{
    NSUInteger nReads = 4;
    NSUInteger readLen = 12;

    NSArray<NSString *> *chroms = @[@"chr1", @"chr1", @"chr2", @"*"];

    int64_t positions[4] = {100, 200, 50, -1};
    NSData *positionsData = [NSData dataWithBytes:positions length:sizeof(positions)];

    uint8_t mapqs[4] = {60, 55, 40, 0};
    NSData *mapqData = [NSData dataWithBytes:mapqs length:sizeof(mapqs)];

    uint32_t flags[4] = {0x0003, 0x0003, 0x0003, 0x0004};
    NSData *flagsData = [NSData dataWithBytes:flags length:sizeof(flags)];

    NSMutableData *seqData = [NSMutableData dataWithCapacity:nReads * readLen];
    for (NSUInteger i = 0; i < nReads; i++) {
        [seqData appendBytes:"ACGTACGTACGT" length:readLen];
    }
    NSMutableData *qualData = [NSMutableData dataWithLength:nReads * readLen];
    memset(qualData.mutableBytes, 30, nReads * readLen);

    uint64_t offsets[4] = {0, 12, 24, 36};
    NSData *offsetsData = [NSData dataWithBytes:offsets length:sizeof(offsets)];
    uint32_t lengths[4] = {12, 12, 12, 12};
    NSData *lengthsData = [NSData dataWithBytes:lengths length:sizeof(lengths)];

    NSMutableArray *cigars = [NSMutableArray array];
    NSMutableArray *names = [NSMutableArray array];
    NSMutableArray *mateChroms = [NSMutableArray array];
    for (NSUInteger i = 0; i < nReads; i++) {
        [cigars addObject:[NSString stringWithFormat:@"%luM", (unsigned long)readLen]];
        [names addObject:[NSString stringWithFormat:@"read_%03lu", (unsigned long)i]];
        [mateChroms addObject:@""];
    }
    NSMutableData *matePosData = [NSMutableData dataWithLength:nReads * sizeof(int64_t)];
    int64_t *matePosBuf = (int64_t *)matePosData.mutableBytes;
    for (NSUInteger i = 0; i < nReads; i++) matePosBuf[i] = -1;
    NSMutableData *tlenData = [NSMutableData dataWithLength:nReads * sizeof(int32_t)];

    return [[TTIOWrittenGenomicRun alloc]
        initWithAcquisitionMode:TTIOAcquisitionModeGenomicWGS
                   referenceUri:@"GRCh38.p14"
                       platform:@"ILLUMINA"
                     sampleName:@"NA12878"
                      positions:positionsData
               mappingQualities:mapqData
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
              signalCompression:TTIOCompressionNone];
}

static void testGenomicRunTransportRoundTrip(void)
{
    NSString *srcPath = m89TmpPath(@"src.tio");
    NSString *rtPath  = m89TmpPath(@"rt.tio");
    m89RmFile(srcPath);
    m89RmFile(rtPath);

    TTIOWrittenGenomicRun *wgr = makeMinimalGenomicWrittenRun();
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:srcPath
                                                  title:@"M89.2 fixture"
                                    isaInvestigationId:@"ISA-M89-TEST"
                                                msRuns:@{}
                                            genomicRuns:@{@"genomic_0001": wgr}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "M89.2: source genomic .tio written");

    TTIOSpectralDataset *src = [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
    PASS(src != nil, "M89.2: source genomic .tio re-readable");

    // Encode to transport bytes via writeDataset (MS-empty + 1 genomic).
    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([tw writeDataset:src error:&err],
         "M89.2: writeDataset emits genomic run");
    [tw close];

    TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *packets = [tr readAllPacketsWithError:&err];
    PASS(packets != nil,
         "M89.2: transport bytes parse back to packet records");

    // Expect StreamHeader + 1 DatasetHeader + 4 AUs + EndOfDataset + EndOfStream = 8
    PASS(packets.count == 8,
         "M89.2: 4-read genomic run emits 8 packets");

    // Verify all AUs are spectrum_class=5 with the right suffix.
    NSMutableArray<TTIOAccessUnit *> *aus = [NSMutableArray array];
    for (TTIOTransportPacketRecord *rec in packets) {
        if (rec.header.packetType == TTIOTransportPacketAccessUnit) {
            TTIOAccessUnit *au =
                [TTIOAccessUnit decodeFromBytes:rec.payload.bytes
                                          length:rec.payload.length
                                           error:&err];
            if (au) [aus addObject:au];
        }
    }
    PASS(aus.count == 4, "M89.2: 4 access units recovered");
    BOOL allClass5 = YES;
    for (TTIOAccessUnit *au in aus) {
        if (au.spectrumClass != 5) { allClass5 = NO; break; }
    }
    PASS(allClass5, "M89.2: every emitted AU has spectrum_class==5");

    if (aus.count == 4) {
        PASS([aus[0].chromosome isEqualToString:@"chr1"]
             && [aus[1].chromosome isEqualToString:@"chr1"]
             && [aus[2].chromosome isEqualToString:@"chr2"]
             && [aus[3].chromosome isEqualToString:@"*"],
             "M89.2: chromosomes [chr1, chr1, chr2, *]");
        PASS(aus[0].position == 100 && aus[1].position == 200
             && aus[2].position == 50 && aus[3].position == -1,
             "M89.2: positions [100, 200, 50, -1]");
        PASS(aus[0].mappingQuality == 60 && aus[1].mappingQuality == 55
             && aus[2].mappingQuality == 40 && aus[3].mappingQuality == 0,
             "M89.2: mapqs [60, 55, 40, 0]");
        PASS(aus[0].flags == 0x0003 && aus[3].flags == 0x0004,
             "M89.2: flags [0x3, 0x3, 0x3, 0x4]");
    }

    // Now full round-trip back to a .tio file and verify we can re-read.
    TTIOTransportReader *tr2 = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([tr2 writeTtioToPath:rtPath error:&err],
         "M89.2: transport stream materialised back to .tio");
    TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:rtPath error:&err];
    PASS(rt != nil, "M89.2: round-tripped .tio opens");
    TTIOGenomicRun *gr = rt.genomicRuns[@"genomic_0001"];
    PASS(gr != nil, "M89.2: genomic_0001 present after round-trip");
    PASS(gr.readCount == 4, "M89.2: 4 reads round-trip");

    [src closeFile];
    [rt closeFile];
    m89RmFile(srcPath);
    m89RmFile(rtPath);
}

// ── 5. Multiplexed MS + genomic round-trip (M89.4) ─────────────────

static TTIOWrittenRun *makeMinimalMSWrittenRun(void)
{
    NSUInteger n = 3, p = 4, total = n * p;
    NSMutableData *mzD = [NSMutableData dataWithCapacity:total * 8];
    NSMutableData *intD = [NSMutableData dataWithCapacity:total * 8];
    for (NSUInteger i = 0; i < total; i++) {
        double mz = 100.0 + (double)i;
        double inten = (double)(i + 1) * 1000.0;
        [mzD appendBytes:&mz length:8];
        [intD appendBytes:&inten length:8];
    }
    uint64_t offsets[3] = {0, 4, 8};
    uint32_t lengths[3] = {4, 4, 4};
    double rts[3] = {1.0, 2.0, 3.0};
    int32_t msLevels[3] = {1, 2, 1};
    int32_t pols[3] = {1, 1, 1};
    double pmzs[3] = {0.0, 500.25, 0.0};
    int32_t pcs[3] = {0, 2, 0};
    double bpis[3] = {4000.0, 8000.0, 12000.0};

    return [[TTIOWrittenRun alloc]
        initWithSpectrumClassName:@"TTIOMassSpectrum"
                  acquisitionMode:(int64_t)TTIOAcquisitionModeMS1DDA
                      channelData:@{@"mz": mzD, @"intensity": intD}
                          offsets:[NSData dataWithBytes:offsets length:sizeof(offsets)]
                          lengths:[NSData dataWithBytes:lengths length:sizeof(lengths)]
                   retentionTimes:[NSData dataWithBytes:rts length:sizeof(rts)]
                         msLevels:[NSData dataWithBytes:msLevels length:sizeof(msLevels)]
                       polarities:[NSData dataWithBytes:pols length:sizeof(pols)]
                     precursorMzs:[NSData dataWithBytes:pmzs length:sizeof(pmzs)]
                 precursorCharges:[NSData dataWithBytes:pcs length:sizeof(pcs)]
              basePeakIntensities:[NSData dataWithBytes:bpis length:sizeof(bpis)]];
}

static void testMultiplexedMSAndGenomicRoundTrip(void)
{
    NSString *srcPath = m89TmpPath(@"mux_src.tio");
    NSString *rtPath  = m89TmpPath(@"mux_rt.tio");
    m89RmFile(srcPath);
    m89RmFile(rtPath);

    TTIOWrittenRun *msRun = makeMinimalMSWrittenRun();
    TTIOWrittenGenomicRun *gRun = makeMinimalGenomicWrittenRun();
    NSError *err = nil;
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:srcPath
                                                  title:@"M89.4 mux"
                                    isaInvestigationId:@"ISA-M89-MUX"
                                                msRuns:@{@"run_0001": msRun}
                                            genomicRuns:@{@"genomic_0001": gRun}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "M89.4: multiplexed source .tio written");

    TTIOSpectralDataset *src = [TTIOSpectralDataset readFromFilePath:srcPath error:&err];
    PASS(src != nil, "M89.4: multiplexed source re-readable");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *tw = [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([tw writeDataset:src error:&err],
         "M89.4: writeDataset emits both MS + genomic");
    [tw close];

    TTIOTransportReader *tr = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *packets = [tr readAllPacketsWithError:&err];
    PASS(packets != nil, "M89.4: multiplexed transport bytes parse");

    // Expect: StreamHeader, 2 DatasetHeaders, 3 MS AUs + EOD,
    // 4 genomic AUs + EOD, EndOfStream = 13 packets.
    PASS(packets.count == 13, "M89.4: 13 packets total in mux stream");

    // Verify dataset_id segregation: MS AUs all have did==1, genomic
    // AUs all have did==2.
    NSMutableArray *auIds = [NSMutableArray array];
    for (TTIOTransportPacketRecord *rec in packets) {
        if (rec.header.packetType == TTIOTransportPacketAccessUnit) {
            [auIds addObject:@(rec.header.datasetId)];
        }
    }
    PASS(auIds.count == 7, "M89.4: 3 MS + 4 genomic AUs total");
    BOOL idsCorrect =
        [auIds[0] unsignedIntValue] == 1 &&
        [auIds[1] unsignedIntValue] == 1 &&
        [auIds[2] unsignedIntValue] == 1 &&
        [auIds[3] unsignedIntValue] == 2 &&
        [auIds[4] unsignedIntValue] == 2 &&
        [auIds[5] unsignedIntValue] == 2 &&
        [auIds[6] unsignedIntValue] == 2;
    PASS(idsCorrect, "M89.4: AU dataset_ids = [1,1,1,2,2,2,2]");

    TTIOTransportReader *tr2 = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([tr2 writeTtioToPath:rtPath error:&err],
         "M89.4: mux stream materialised back to .tio");
    TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:rtPath error:&err];
    PASS(rt != nil, "M89.4: mux round-tripped .tio opens");
    PASS(rt.msRuns[@"run_0001"] != nil, "M89.4: MS run preserved through mux");
    TTIOGenomicRun *gr = rt.genomicRuns[@"genomic_0001"];
    PASS(gr != nil && gr.readCount == 4,
         "M89.4: genomic run preserved through mux");

    // Genomic-filter behaviour on the mux stream: a chromosome filter
    // should accept exactly the 3 AUs whose chromosome=="chr1".
    TTIOAUFilter *f = filterFromJSON(
        @"{\"type\":\"query\",\"filters\":{\"chromosome\":\"chr1\"}}");
    NSUInteger nMatched = 0;
    for (TTIOTransportPacketRecord *rec in packets) {
        if (rec.header.packetType != TTIOTransportPacketAccessUnit) continue;
        TTIOAccessUnit *au =
            [TTIOAccessUnit decodeFromBytes:rec.payload.bytes
                                      length:rec.payload.length
                                       error:NULL];
        if (au && [f matches:au datasetId:rec.header.datasetId]) nMatched++;
    }
    PASS(nMatched == 2,
         "M89.4: chromosome=chr1 filter accepts only the 2 chr1 genomic AUs (excludes MS + chr2 + unmapped)");

    [src closeFile];
    [rt closeFile];
    m89RmFile(srcPath);
    m89RmFile(rtPath);
}

// ── Entry point ────────────────────────────────────────────────────

void testM89GenomicTransport(void)
{
    testGenomicAURoundTrip();
    testGenomicAUUnmapped();
    testGenomicAULongChromosomeAndMaxes();
    testGenomicAUTruncatedSuffix();
    testGenomicSuffixOnlyWhenClass5();

    testAUFilterChromosomeMatch();
    testAUFilterPositionRange();
    testAUFilterChromosomeAndPositionCombined();
    testAUFilterUnmappedReadsMatchStar();
    testAUFilterChromosomeExcludesMS();
    testAUFilterPositionExcludesMS();
    testAUFilterEmptyAcceptsAllGenomic();

    testGenomicAUEncryptionRoundTrip();
    testGenomicAUEncryptionUnmapped();

    testGenomicRunTransportRoundTrip();
    testMultiplexedMSAndGenomicRoundTrip();
}
