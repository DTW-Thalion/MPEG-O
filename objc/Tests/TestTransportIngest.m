/*
 * TestTransportIngest — incremental transport-stream parser.
 *
 * Covers:
 *   - Whole-stream feed → all packets delivered + EOS callback fires
 *   - Byte-by-byte feed → identical packet count, identical ordering
 *   - Bad magic at start of stream → didFail + parse error returned
 *   - Truncated stream (no EndOfStream) → finish returns NO with
 *     TTIOTransportErrorTruncated
 *   - Missing StreamHeader (first packet is AU) → MissingStreamHeader
 *
 * Test packets are crafted by hand via TTIOTransportPacketHeader
 * encoders so the test stays scoped to the ingest's streaming
 * behaviour, not the full dataset/writer pipeline (which has its own
 * tests in TestTransportCodec.m).
 *
 * Cross-language equivalent: planned alongside the planned
 * Python/Java TransportIngest port.
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOTransportIngest.h"

#pragma mark - Crafting helpers

static NSData *encodeHeader(TTIOTransportPacketType type,
                            uint16_t flags,
                            uint16_t datasetId,
                            uint32_t auSequence,
                            uint32_t payloadLength)
{
    TTIOTransportPacketHeader *h =
        [[TTIOTransportPacketHeader alloc] initWithPacketType:type
                                                        flags:flags
                                                    datasetId:datasetId
                                                   auSequence:auSequence
                                                payloadLength:payloadLength
                                                  timestampNs:0];
    return [h encode];
}

static void appendU32LE(NSMutableData *m, uint32_t v)
{
    uint8_t b[4] = {
        (uint8_t)(v & 0xFF),
        (uint8_t)((v >> 8) & 0xFF),
        (uint8_t)((v >> 16) & 0xFF),
        (uint8_t)((v >> 24) & 0xFF)
    };
    [m appendBytes:b length:4];
}

static NSData *craftPacket(TTIOTransportPacketType type,
                           uint16_t flags,
                           uint16_t datasetId,
                           uint32_t auSequence,
                           NSData *payload)
{
    NSMutableData *out = [NSMutableData data];
    [out appendData:encodeHeader(type, flags, datasetId, auSequence,
                                  (uint32_t)payload.length)];
    [out appendData:payload];
    if (flags & TTIOTransportPacketFlagHasChecksum) {
        uint32_t crc = TTIOTransportCRC32C((const uint8_t *)payload.bytes,
                                            payload.length);
        appendU32LE(out, crc);
    }
    return out;
}

/// Minimal but valid stream: StreamHeader + 3 AU + EndOfStream.
/// All packets use HasChecksum so the ingest exercises that path.
static NSData *craftSampleStream(void)
{
    NSMutableData *stream = [NSMutableData data];

    NSData *shdrPayload = [@"v0" dataUsingEncoding:NSUTF8StringEncoding];
    [stream appendData:craftPacket(TTIOTransportPacketStreamHeader,
                                   TTIOTransportPacketFlagHasChecksum,
                                   0, 0, shdrPayload)];

    for (uint32_t i = 1; i <= 3; i++) {
        char tag[24];
        snprintf(tag, sizeof(tag), "au-%u-payload", i);
        NSData *p = [NSData dataWithBytes:tag length:strlen(tag)];
        [stream appendData:craftPacket(TTIOTransportPacketAccessUnit,
                                       TTIOTransportPacketFlagHasChecksum,
                                       /* datasetId */ 1, /* auSequence */ i, p)];
    }

    [stream appendData:craftPacket(TTIOTransportPacketEndOfStream,
                                   TTIOTransportPacketFlagHasChecksum,
                                   0, 0, [NSData data])];
    return stream;
}

#pragma mark - Recording delegate

@interface IngestRecorder : NSObject <TTIOTransportIngestDelegate>
@property (nonatomic, strong) NSMutableArray<TTIOTransportPacketRecord *> *packets;
@property (nonatomic, assign) BOOL endOfStreamFired;
@property (nonatomic, strong, nullable) NSError *failureError;
@end

@implementation IngestRecorder
- (instancetype)init
{
    if ((self = [super init])) {
        _packets = [NSMutableArray array];
    }
    return self;
}
- (void)ingest:(TTIOTransportIngest *)ingest
    didReceivePacket:(TTIOTransportPacketRecord *)record
{
    [_packets addObject:record];
}
- (void)ingestDidReceiveEndOfStream:(TTIOTransportIngest *)ingest
{
    _endOfStreamFired = YES;
}
- (void)ingest:(TTIOTransportIngest *)ingest didFailWithError:(NSError *)error
{
    _failureError = error;
}
@end

#pragma mark - Tests

static void test_whole_stream_feed(void)
{
    NSData *stream = craftSampleStream();
    TTIOTransportIngest *ingest = [TTIOTransportIngest new];
    IngestRecorder *rec = [IngestRecorder new];
    ingest.delegate = rec;

    NSError *err = nil;
    BOOL ok = [ingest feedData:stream error:&err];
    PASS(ok, "whole-stream feed returns YES");
    PASS(err == nil, "no parse error on whole-stream feed");
    PASS(rec.packets.count == 5,
         "5 packets delivered (StreamHeader + 3 AU + EndOfStream)");
    PASS(rec.endOfStreamFired,
         "ingestDidReceiveEndOfStream callback fired");
    PASS(ingest.isFinished, "ingest.isFinished is YES after EOS");
    PASS(ingest.packetCount == 5, "ingest.packetCount = 5");
    PASS(rec.failureError == nil, "no failure callback fired");
}

static void test_byte_by_byte_feed(void)
{
    NSData *stream = craftSampleStream();
    TTIOTransportIngest *ingest = [TTIOTransportIngest new];
    IngestRecorder *rec = [IngestRecorder new];
    ingest.delegate = rec;

    const uint8_t *p = stream.bytes;
    NSUInteger len = stream.length;
    BOOL anyError = NO;
    for (NSUInteger i = 0; i < len; i++) {
        NSError *err = nil;
        if (![ingest feedBytes:&p[i] length:1 error:&err]) {
            anyError = YES;
            break;
        }
    }
    PASS(!anyError, "byte-by-byte feed completed without error");
    PASS(rec.packets.count == 5,
         "byte-by-byte: 5 packets delivered (same as whole-stream)");
    PASS(rec.endOfStreamFired, "byte-by-byte: EOS callback fired");
    PASS(ingest.packetCount == 5, "byte-by-byte: packetCount = 5");
}

static void test_chunked_feed(void)
{
    // Feed in 7-byte chunks — guarantees most chunks straddle a
    // packet boundary, exercises the rolling-buffer drain logic
    // more thoroughly than byte-by-byte.
    NSData *stream = craftSampleStream();
    TTIOTransportIngest *ingest = [TTIOTransportIngest new];
    IngestRecorder *rec = [IngestRecorder new];
    ingest.delegate = rec;

    const uint8_t *p = stream.bytes;
    NSUInteger len = stream.length;
    NSUInteger offset = 0;
    NSUInteger chunk = 7;
    while (offset < len) {
        NSUInteger n = MIN(chunk, len - offset);
        NSError *err = nil;
        BOOL ok = [ingest feedBytes:&p[offset] length:n error:&err];
        if (!ok) {
            PASS(NO, "chunked feed should not fail");
            return;
        }
        offset += n;
    }
    PASS(rec.packets.count == 5, "chunked-7: 5 packets delivered");
    PASS(rec.endOfStreamFired, "chunked-7: EOS callback fired");
}

static void test_bad_magic_fails(void)
{
    // Craft 24 bytes that look like a header but with bogus magic.
    uint8_t garbage[24] = {0};
    garbage[0] = 'X';
    garbage[1] = 'X';
    garbage[2] = 0x01;

    TTIOTransportIngest *ingest = [TTIOTransportIngest new];
    IngestRecorder *rec = [IngestRecorder new];
    ingest.delegate = rec;

    NSError *err = nil;
    BOOL ok = [ingest feedBytes:garbage length:sizeof(garbage) error:&err];
    PASS(!ok, "bad-magic feed returns NO");
    PASS(err != nil, "bad-magic feed populates error");
    PASS([err.domain isEqualToString:TTIOTransportErrorDomain],
         "bad-magic error is TTIOTransportErrorDomain");
    PASS(rec.failureError != nil,
         "delegate didFailWithError fired on bad magic");
    PASS(ingest.isFinished, "ingest is in finished/failed state");
}

static void test_truncated_finish_fails(void)
{
    // Feed only the StreamHeader's header bytes, then finish.
    // The header advertises a 16-byte payload that never arrives.
    NSMutableData *partial = [NSMutableData data];
    [partial appendData:encodeHeader(TTIOTransportPacketStreamHeader,
                                     0, 0, 0, /* payloadLength */ 16)];

    TTIOTransportIngest *ingest = [TTIOTransportIngest new];
    IngestRecorder *rec = [IngestRecorder new];
    ingest.delegate = rec;

    NSError *err = nil;
    PASS([ingest feedData:partial error:&err],
         "header-only feed accepted (waiting for payload)");
    PASS(ingest.packetCount == 0,
         "no packets emitted yet — payload incomplete");
    PASS(ingest.bufferedBytes == 24,
         "24 bytes buffered awaiting the missing payload");

    NSError *finErr = nil;
    PASS(![ingest finishWithError:&finErr],
         "finish on partial returns NO");
    PASS(finErr != nil && finErr.code == TTIOTransportErrorTruncated,
         "finish error is TTIOTransportErrorTruncated");
}

static void test_missing_stream_header_fails(void)
{
    // Send an AU before any StreamHeader.
    NSData *au = craftPacket(TTIOTransportPacketAccessUnit,
                             TTIOTransportPacketFlagHasChecksum,
                             1, 1,
                             [@"orphan" dataUsingEncoding:NSUTF8StringEncoding]);

    TTIOTransportIngest *ingest = [TTIOTransportIngest new];
    IngestRecorder *rec = [IngestRecorder new];
    ingest.delegate = rec;

    NSError *err = nil;
    PASS(![ingest feedData:au error:&err],
         "AU-before-StreamHeader rejected");
    PASS(err.code == TTIOTransportErrorMissingStreamHeader,
         "error code is TTIOTransportErrorMissingStreamHeader");
}

#pragma mark - Entry point

void testTransportIngest(void)
{
    test_whole_stream_feed();
    test_byte_by_byte_feed();
    test_chunked_feed();
    test_bad_magic_fails();
    test_truncated_finish_fails();
    test_missing_stream_header_fails();
}
