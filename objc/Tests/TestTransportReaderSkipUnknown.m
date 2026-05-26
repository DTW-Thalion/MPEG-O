/*
 * TestTransportReaderSkipUnknown — forward-compat: v0.10 readers
 * must tolerate unknown packet type bytes by length-prefix-skipping
 * the payload (transport-spec §6, v0.11 task 0.7).
 *
 * Cross-language parity:
 *   - Java: TransportReaderSkipUnknownTest (commit 0a777019)
 *   - Python: tests/test_reader_skip_unknown.py (commit 6446fa36)
 *
 * SPDX-License-Identifier: Apache-2.0
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOTransportPacket.h"
#import "Transport/TTIOTransportPacket+Internal.h"
#import "Transport/TTIOTransportReader.h"
#import "Transport/TTIOTransportReader+Internal.h"
#import "Transport/TTIOTransportWriter.h"

void testTransportReaderSkipUnknown(void)
{
    NSMutableData *bytes = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:bytes];

    NSError *err = nil;
    BOOL ok = [w writeStreamHeaderWithFormatVersion:@"1.2"
                                               title:@"test"
                                    isaInvestigation:@""
                                            features:@[TTIOTransportV011Feature]
                                          nDatasets:0
                                               error:&err];
    PASS(ok, "stream-header written");

    // Splice a packet whose type byte (0x7E) is not a known
    // TTIOTransportPacketType. The reader must consume the length-
    // prefixed payload and continue past it to EndOfStream.
    NSData *payload =
        [@"future-extension-data" dataUsingEncoding:NSUTF8StringEncoding];
    NSData *rawHeader =
        [TTIOTransportPacketHeader encodeRawWithTypeByte:0x7E
                                                    flags:0
                                                datasetId:0
                                               auSequence:0
                                            payloadLength:(uint32_t)payload.length
                                              timestampNs:0];
    [bytes appendData:rawHeader];
    [bytes appendData:payload];

    ok = [w writeEndOfStreamWithError:&err];
    PASS(ok, "end-of-stream written");

    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:bytes];
    NSArray<TTIOTransportPacketRecord *> *records = [r recordsForTest];
    PASS(records != nil, "reader did not throw on unknown packet type");
    PASS(records.count == 3,
         "expected StreamHeader + unknown + EndOfStream (3 records)");

    if (records.count == 3) {
        TTIOTransportPacketRecord *rec0 = records[0];
        TTIOTransportPacketRecord *rec1 = records[1];
        TTIOTransportPacketRecord *rec2 = records[2];

        PASS(rec0.header.packetTypeByte == TTIOTransportPacketStreamHeader,
             "record 0: StreamHeader (0x01)");
        PASS(TTIOTransportIsKnownPacketType(rec0.header.packetTypeByte),
             "record 0: known packet type");

        PASS(rec1.header.packetTypeByte == 0x7E,
             "record 1: raw type byte 0x7E preserved on header");
        PASS(!TTIOTransportIsKnownPacketType(rec1.header.packetTypeByte),
             "record 1: unknown packet type reported as unknown");
        PASS(rec1.header.packetType == (TTIOTransportPacketType)0,
             "record 1: typed packetType reset to 0 sentinel for unknown byte");
        PASS([rec1.payload isEqualToData:payload],
             "record 1: payload bytes length-prefix-copied verbatim");

        PASS(rec2.header.packetTypeByte == TTIOTransportPacketEndOfStream,
             "record 2: EndOfStream (0xFF)");
    }

    // Also exercise the materialize loop: it must early-continue on
    // the unknown packet rather than raising MissingStreamHeader /
    // UnexpectedPayload. Materialize should fail cleanly because the
    // stream declared 0 datasets and shipped none — but the failure
    // must NOT be triggered by the unknown packet.
    NSString *tmp = [NSTemporaryDirectory()
        stringByAppendingPathComponent:@"skip-unknown.tio"];
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
    NSError *mErr = nil;
    TTIOTransportReader *r2 =
        [[TTIOTransportReader alloc] initWithData:bytes];
    BOOL mok = [r2 writeTtioToPath:tmp error:&mErr];
    // Empty-stream materialize is fine — the test's invariant is
    // "skip-unknown didn't cascade into a structural-error path".
    if (!mok) {
        PASS(mErr.code != TTIOTransportErrorMissingStreamHeader,
             "materialize did not misattribute unknown packet to "
             "MissingStreamHeader");
        PASS(mErr.code != TTIOTransportErrorUnexpectedPayload,
             "materialize did not misattribute unknown packet to "
             "UnexpectedPayload");
    } else {
        PASS(YES, "materialize succeeded across unknown packet");
        PASS(YES, "(no error misattribution to check)");
    }
    [[NSFileManager defaultManager] removeItemAtPath:tmp error:NULL];
}
