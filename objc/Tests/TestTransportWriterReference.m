/*
 * TestTransportWriterReference — Task 3.2 of transport-spec v0.11.
 *
 * Mirror of Java TransportWriterReferenceTest (commit 622aa8bd) and
 * Python's tests/test_writer_reference_group.py (commit ec529a8b).
 * Exercises -[TTIOTransportWriter writeReferenceGroup:error:] and
 * verifies the emitted packet sequence matches transport-spec
 * §4.13-§4.15.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import <zlib.h>
#import "Testing.h"

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOTransportReader+Internal.h"
#import "Transport/TTIOTransportWriter.h"
#import "Genomics/TTIOReferenceImport.h"

// ----- LE readers for payload field inspection -----------------------

static inline uint16_t leU16(const uint8_t *b) {
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}
static inline uint32_t leU32(const uint8_t *b) {
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}
static inline uint64_t leU64(const uint8_t *b) {
    uint64_t lo = (uint64_t)leU32(b);
    uint64_t hi = (uint64_t)leU32(b + 4);
    return lo | (hi << 32);
}

// ----- happy-path: 2 short chromosomes -> encoding=0 raw -------------

static void testWriteReferenceGroup_emitsHeaderChromosomesEofInOrder(void)
{
    NSData *chr1 = [@"ACGT" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *chr2 = [@"TTTTCC" dataUsingEncoding:NSUTF8StringEncoding];
    TTIOReferenceImport *ref =
        [[TTIOReferenceImport alloc] initWithUri:@"fixture-test-ref-v1"
                                     chromosomes:@[@"chr1", @"chr2"]
                                       sequences:@[chr1, chr2]];

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];

    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"ref-test"
                               isaInvestigation:@"isa"
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "3.2: StreamHeader written");
    PASS([w writeReferenceGroup:ref error:&err],
         "3.2: writeReferenceGroup: succeeds");
    PASS([w writeEndOfStreamWithError:&err],
         "3.2: EndOfStream written");

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records = [r recordsForTest];
    PASS(records != nil, "3.2: reader produced records");
    PASS(records.count == 6,
         "3.2: expected 6 packets (StreamHeader, RefGroupHeader, "
         "2x RefChromosome, EOR, EOS)");

    if (records.count == 6) {
        PASS(records[0].header.packetType
                == TTIOTransportPacketStreamHeader,
             "3.2: record 0 is StreamHeader");
        PASS(records[1].header.packetType
                == TTIOTransportPacketReferenceGroupHeader,
             "3.2: record 1 is ReferenceGroupHeader (0x10)");
        PASS(records[2].header.packetType
                == TTIOTransportPacketReferenceChromosome,
             "3.2: record 2 is ReferenceChromosome (0x11)");
        PASS(records[3].header.packetType
                == TTIOTransportPacketReferenceChromosome,
             "3.2: record 3 is ReferenceChromosome (0x11)");
        PASS(records[4].header.packetType
                == TTIOTransportPacketEndOfReferenceGroup,
             "3.2: record 4 is EndOfReferenceGroup (0x12)");
        PASS(records[5].header.packetType
                == TTIOTransportPacketEndOfStream,
             "3.2: record 5 is EndOfStream");

        // ----- REFERENCE_GROUP_HEADER payload --------------------------
        const uint8_t *hpl = records[1].payload.bytes;
        NSUInteger hplen = records[1].payload.length;
        NSUInteger off = 0;
        PASS(off + 2 <= hplen, "3.2: header has uri_len");
        uint16_t uriLen = leU16(&hpl[off]); off += 2;
        PASS(uriLen == [ref.uri lengthOfBytesUsingEncoding:NSUTF8StringEncoding],
             "3.2: uri_len matches ref.uri UTF-8 length");
        NSString *uriOut = [[NSString alloc] initWithBytes:&hpl[off]
                                                     length:uriLen
                                                   encoding:NSUTF8StringEncoding];
        off += uriLen;
        PASS([uriOut isEqualToString:@"fixture-test-ref-v1"],
             "3.2: uri round-trips byte-equal");
        PASS(off + 4 <= hplen, "3.2: header has chromosome_count");
        uint32_t chromCount = leU32(&hpl[off]); off += 4;
        PASS(chromCount == 2, "3.2: chromosome_count == 2");
        PASS(off + 8 <= hplen, "3.2: header has total_bases");
        uint64_t totalBases = leU64(&hpl[off]); off += 8;
        PASS(totalBases == 10, "3.2: total_bases == 10 (4 + 6)");
        PASS(off + 32 <= hplen, "3.2: header has md5_hex[32]");
        NSString *md5HexOut = [[NSString alloc] initWithBytes:&hpl[off]
                                                        length:32
                                                      encoding:NSASCIIStringEncoding];
        off += 32;
        PASS([md5HexOut isEqualToString:[ref md5Hex]],
             "3.2: md5_hex matches ReferenceImport.md5Hex()");
        PASS(off == hplen,
             "3.2: header payload fully consumed (no trailing bytes)");

        // ----- chr1 record (uncompressed; 4 < 4096) -------------------
        const uint8_t *c1 = records[2].payload.bytes;
        NSUInteger c1len = records[2].payload.length;
        off = 0;
        PASS(off + 2 <= c1len, "3.2: chr1 has name_len");
        uint16_t n1 = leU16(&c1[off]); off += 2;
        PASS(n1 == 4, "3.2: chr1 name_len == 4");
        NSString *name1 = [[NSString alloc] initWithBytes:&c1[off]
                                                    length:n1
                                                  encoding:NSUTF8StringEncoding];
        off += n1;
        PASS([name1 isEqualToString:@"chr1"], "3.2: chr1 name");
        PASS(off + 8 <= c1len, "3.2: chr1 has sequence_length");
        uint64_t seqLen1 = leU64(&c1[off]); off += 8;
        PASS(seqLen1 == 4, "3.2: chr1 sequence_length == 4");
        PASS(off + 1 <= c1len, "3.2: chr1 has encoding byte");
        uint8_t enc1 = c1[off]; off += 1;
        PASS(enc1 == 0, "3.2: encoding=0 raw for short chromosome");
        PASS(off + 4 <= c1len, "3.2: chr1 has data_len");
        uint32_t pl1 = leU32(&c1[off]); off += 4;
        PASS(pl1 == 4, "3.2: chr1 data_len == 4");
        PASS(off + pl1 <= c1len, "3.2: chr1 payload fits");
        NSData *data1 = [NSData dataWithBytes:&c1[off] length:pl1];
        off += pl1;
        PASS([data1 isEqualToData:chr1], "3.2: chr1 data round-trips");
        PASS(off == c1len, "3.2: chr1 payload fully consumed");
        // auSequence carries the chromosome index.
        PASS(records[2].header.auSequence == 0,
             "3.2: chr1 au_sequence == 0");

        // ----- chr2 record (also short -> encoding=0) ------------------
        const uint8_t *c2 = records[3].payload.bytes;
        NSUInteger c2len = records[3].payload.length;
        off = 0;
        uint16_t n2 = leU16(&c2[off]); off += 2;
        PASS(n2 == 4, "3.2: chr2 name_len == 4");
        NSString *name2 = [[NSString alloc] initWithBytes:&c2[off]
                                                    length:n2
                                                  encoding:NSUTF8StringEncoding];
        off += n2;
        PASS([name2 isEqualToString:@"chr2"], "3.2: chr2 name");
        uint64_t seqLen2 = leU64(&c2[off]); off += 8;
        PASS(seqLen2 == 6, "3.2: chr2 sequence_length == 6");
        uint8_t enc2 = c2[off]; off += 1;
        PASS(enc2 == 0, "3.2: chr2 encoding=0");
        uint32_t pl2 = leU32(&c2[off]); off += 4;
        PASS(pl2 == 6, "3.2: chr2 data_len == 6");
        NSData *data2 = [NSData dataWithBytes:&c2[off] length:pl2];
        off += pl2;
        PASS([data2 isEqualToData:chr2], "3.2: chr2 data round-trips");
        PASS(records[3].header.auSequence == 1,
             "3.2: chr2 au_sequence == 1");

        // ----- END_OF_REFERENCE_GROUP carries count -------------------
        const uint8_t *epl = records[4].payload.bytes;
        PASS(records[4].payload.length == 4,
             "3.2: EOR payload is uint32");
        uint32_t eorCount = leU32(epl);
        PASS(eorCount == 2,
             "3.2: EOR chromosome_count == 2 (matches header)");
    }
}

// ----- zlib path: >= 4 KiB sequence -> encoding=1 --------------------

static void testWriteReferenceGroup_zlibPathAboveThreshold(void)
{
    // 8 KiB chromosome to force encoding=1.
    NSUInteger n = 8192;
    NSMutableData *big = [NSMutableData dataWithLength:n];
    uint8_t *bbytes = big.mutableBytes;
    static const char *acgt = "ACGT";
    for (NSUInteger i = 0; i < n; i++) bbytes[i] = (uint8_t)acgt[i & 3];

    TTIOReferenceImport *ref =
        [[TTIOReferenceImport alloc] initWithUri:@"ref-large"
                                     chromosomes:@[@"chrL"]
                                       sequences:@[big]];

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];

    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"ref-test"
                               isaInvestigation:@"isa"
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "3.2 zlib: StreamHeader written");
    PASS([w writeReferenceGroup:ref error:&err],
         "3.2 zlib: writeReferenceGroup: succeeds");
    PASS([w writeEndOfStreamWithError:&err],
         "3.2 zlib: EndOfStream written");

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records = [r recordsForTest];
    PASS(records.count == 5,
         "3.2 zlib: 5 packets (StreamHeader, RefGroupHeader, "
         "1x RefChromosome, EOR, EOS)");

    if (records.count == 5) {
        PASS(records[2].header.packetType
                == TTIOTransportPacketReferenceChromosome,
             "3.2 zlib: record 2 is ReferenceChromosome");
        const uint8_t *c = records[2].payload.bytes;
        NSUInteger clen = records[2].payload.length;
        NSUInteger off = 0;
        uint16_t nameLen = leU16(&c[off]); off += 2;
        off += nameLen;
        uint64_t seqLen = leU64(&c[off]); off += 8;
        PASS(seqLen == 8192, "3.2 zlib: sequence_length == 8192");
        uint8_t encoding = c[off]; off += 1;
        PASS(encoding == 1,
             "3.2 zlib: encoding=1 for >= 4096-byte chromosome");
        uint32_t dataLen = leU32(&c[off]); off += 4;
        PASS(dataLen < 8192,
             "3.2 zlib: deflated payload smaller than raw");
        PASS(off + dataLen <= clen,
             "3.2 zlib: deflated payload fits");

        // Inflate and compare.
        uLongf destLen = (uLongf)n;
        NSMutableData *out = [NSMutableData dataWithLength:n];
        int rc = uncompress((Bytef *)out.mutableBytes, &destLen,
                              (const Bytef *)&c[off], (uLong)dataLen);
        PASS(rc == Z_OK, "3.2 zlib: zlib uncompress() succeeds");
        PASS(destLen == n,
             "3.2 zlib: inflated length matches raw length");
        PASS([out isEqualToData:big],
             "3.2 zlib: inflated bytes match raw chromosome");
    }
}

void testTransportWriterReference(void);
void testTransportWriterReference(void)
{
    testWriteReferenceGroup_emitsHeaderChromosomesEofInOrder();
    testWriteReferenceGroup_zlibPathAboveThreshold();
}
