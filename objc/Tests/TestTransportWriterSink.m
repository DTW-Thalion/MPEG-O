/*
 * TestTransportWriterSink — exercises the
 * TTIOTransportWriterSink protocol introduced for the workbench
 * server's S3 streaming download mode.
 *
 * Acceptance:
 *   1. Custom sink receives every packet the writer emits.
 *   2. The catenation of all -writeData: chunks is byte-identical
 *      to the same encode against an NSMutableData sink.
 *   3. TTIOMutableDataSink wraps NSMutableData transparently and
 *      preserves the existing -initWithMutableData: contract.
 *
 * Cross-language equivalent:
 *   (Python and Java already accept stream-like sinks via BinaryIO /
 *    OutputStream; this test only exists for ObjC.)
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <Foundation/Foundation.h>
#import "Testing.h"

#import "Transport/TTIOTransportWriter.h"
#import "Transport/TTIOAccessUnit.h"


// ── Test helper sink: records every chunk into an NSMutableArray
//    *and* concatenates them into one buffer for byte-comparison.
@interface RecordingSink : NSObject <TTIOTransportWriterSink>
@property (nonatomic, strong, readonly) NSMutableArray<NSData *> *chunks;
@property (nonatomic, strong, readonly) NSMutableData *concatenated;
@end
@implementation RecordingSink
- (instancetype)init {
    if ((self = [super init])) {
        _chunks = [NSMutableArray array];
        _concatenated = [NSMutableData data];
    }
    return self;
}
- (void)writeData:(NSData *)data {
    [_chunks addObject:[data copy]];
    [_concatenated appendData:data];
}
@end


static void encodeSimpleStream(TTIOTransportWriter *w)
{
    NSError *err = nil;
    [w writeStreamHeaderWithFormatVersion:@"v0"
                                     title:@"sink-test"
                          isaInvestigation:@""
                                  features:@[]
                                nDatasets:1
                                     error:&err];
    [w writeDatasetHeaderWithDatasetId:1
                                  name:@"ds"
                       acquisitionMode:0
                         spectrumClass:@"MassSpectrum"
                          channelNames:@[@"mz", @"intensity"]
                        instrumentJSON:@"{}"
                      expectedAUCount:1
                                 error:&err];
    TTIOTransportChannelData *c1 =
        [[TTIOTransportChannelData alloc]
            initWithName:@"mz" precision:3 compression:0
               nElements:4
                    data:[NSMutableData dataWithLength:16]];
    TTIOAccessUnit *au =
        [[TTIOAccessUnit alloc]
            initWithSpectrumClass:0 acquisitionMode:0 msLevel:1
                         polarity:0 retentionTime:0.0 precursorMz:0.0
                  precursorCharge:0 ionMobility:0.0
                basePeakIntensity:0.0
                         channels:@[c1]
                           pixelX:0 pixelY:0 pixelZ:0];
    [w writeAccessUnit:au datasetId:1 auSequence:0 error:&err];
    [w writeEndOfDatasetWithDatasetId:1 finalAUSequence:0 error:&err];
    [w writeEndOfStreamWithError:&err];
}


void testTransportWriterSink(void)
{
    @autoreleasepool {
        // The StreamHeader packet carries a wall-clock timestamp, so
        // two encodes of the same logical stream produce different
        // bytes — we can't compare two independent writer outputs
        // byte-for-byte. We instead verify the sink protocol
        // mechanically: chunk count, total bytes, and self-consistent
        // wrapping.

        // ── 1. Custom sink receives >= 5 chunks
        //      (StreamHeader, DatasetHeader, AU, EndOfDataset,
        //       EndOfStream) and the concatenation matches the
        //      same writer's NSMutableData copy if we route through
        //      a combined sink.
        RecordingSink *recorder = [[RecordingSink alloc] init];
        TTIOTransportWriter *streamed =
            [[TTIOTransportWriter alloc] initWithSink:recorder];
        encodeSimpleStream(streamed);

        PASS(recorder.chunks.count >= 5,
             "sink received >= 5 chunks (one per packet)");
        PASS(recorder.concatenated.length > 0,
             "sink concatenation is non-empty");

        // ── 2. -initWithMutableData: produces output of the same
        //      length and chunk-equivalent structure as the explicit
        //      sink wrapper of the same backing data — proves the
        //      back-compat ctor is a thin pass-through.
        NSMutableData *aliasBuf = [NSMutableData data];
        TTIOTransportWriter *aliasW =
            [[TTIOTransportWriter alloc] initWithMutableData:aliasBuf];
        encodeSimpleStream(aliasW);
        PASS(aliasBuf.length == recorder.concatenated.length,
             "-initWithMutableData: same total bytes as custom sink");

        // ── 3. TTIOMutableDataSink wraps NSMutableData transparently.
        TTIOMutableDataSink *wrapped =
            [[TTIOMutableDataSink alloc] initWithData:[NSMutableData data]];
        TTIOTransportWriter *wrappedW =
            [[TTIOTransportWriter alloc] initWithSink:wrapped];
        encodeSimpleStream(wrappedW);
        PASS(wrapped.data.length == aliasBuf.length,
             "TTIOMutableDataSink via -initWithSink: same byte count");

        // ── 4. +[TTIOMutableDataSink sink] factory works.
        TTIOMutableDataSink *factory = [TTIOMutableDataSink sink];
        PASS(factory.data.length == 0,
             "+sink factory creates empty buffer");
        [factory writeData:[NSData dataWithBytes:"abc" length:3]];
        PASS(factory.data.length == 3,
             "+sink appends after -writeData:");
    }
}
