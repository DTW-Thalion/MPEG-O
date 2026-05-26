/*
 * TestTransportImageProcessed.m — Task 5.1 of transport-spec v0.11
 * (Deferral 1).
 *
 * Exercises -[TTIOTransportWriter writeImageProcessed:] (sparse
 * IMAGE_PIXEL payloads) + the matching reader path that reconstructs
 * the dense intensity cube. The TTIOMSImage data model stays dense;
 * processed mode is purely a wire optimisation for sparse cubes.
 *
 * Wire layout per transport-spec §4.17 (LITTLE-ENDIAN). The
 * IMAGE_HEADER is identical to -writeImage: except for
 * is_continuous == 0; each IMAGE_PIXEL payload is:
 *
 *   x(u32) + y(u32) + precision(u8) + compression(u8) +
 *   payload_length(u32) +
 *   payload_bytes = nonzero_count(u32) +
 *     nonzero_count × { channel_index(u32) + intensity(f64) }
 *
 * Cross-language parity:
 *   Java TransportImageProcessedTest (commit 1889343e)
 *   Python tests/test_transport_image_processed.py (commit 8eac605a)
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
#import "Image/TTIOMSImage.h"
#include <unistd.h>

// -------- helpers ----------------------------------------------------------

static NSString *makeTempPathIp(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_imgp_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

static uint32_t leU32Ip(const uint8_t *b)
{
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

static double leF64Ip(const uint8_t *b)
{
    uint64_t lo = (uint64_t)leU32Ip(b);
    uint64_t hi = (uint64_t)leU32Ip(b + 4);
    uint64_t bits = lo | (hi << 32);
    double d;
    memcpy(&d, &bits, 8);
    return d;
}

// Sparse 3x3x10 cube: each pixel has a deterministic handful of
// nonzero channels (mirrors Python _build_sparse_image fixture).
static TTIOMSImage *buildSparseFixture(void)
{
    const NSUInteger w = 3;
    const NSUInteger h = 3;
    const NSUInteger s = 10;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    // Initialise to zero, then seed sparse nonzeros.
    for (NSUInteger y = 0; y < h; y++) {
        for (NSUInteger x = 0; x < w; x++) {
            NSUInteger pixelIdx = x + y * w;
            NSUInteger base = (y * w + x) * s;
            // 2 nonzero channels per pixel at varying positions.
            NSUInteger ch1 = pixelIdx % s;
            NSUInteger ch2 = (pixelIdx * 3 + 7) % s;
            p[base + ch1] = (double)(pixelIdx + 1) * 1.5;
            if (ch2 != ch1) {
                p[base + ch2] = (double)(pixelIdx + 1) * 2.5;
            }
        }
    }
    NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
    double *mzp = (double *)mz.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) mzp[i] = 100.0 + (double)i * 10.0;

    return [[TTIOMSImage alloc]
                initWithTitle:@"sparse_processed"
           isaInvestigationId:@""
              identifications:@[]
              quantifications:@[]
            provenanceRecords:@[]
                        width:w
                       height:h
               spectralPoints:s
                     tileSize:32
                   pixelSizeX:10.0
                   pixelSizeY:10.0
                  scanPattern:@"raster"
                         cube:cube
                       mzAxis:mz];
}

// -------- 1. round-trip a sparse cube --------------------------------------

static void testProcessedModeRoundTripsSparseCube(void)
{
    TTIOMSImage *img = buildSparseFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"img-proc-rt"
                               isaInvestigation:@""
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "5.1 rt: StreamHeader");
    PASS([w writeImageProcessed:img error:&err],
         "5.1 rt: writeImageProcessed: emitted");
    PASS([w writeEndOfStreamWithError:&err], "5.1 rt: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    // StreamHeader + IMAGE_HEADER + 9 IMAGE_PIXEL + END_OF_IMAGE + EndOfStream
    PASS(records.count == 1 + 1 + 9 + 1 + 1,
         "5.1 rt: 13 packets (header + 1 + 9 + 1 + EOS)");

    PASS(records[1].header.packetType
            == TTIOTransportPacketImageHeader,
         "5.1 rt: packet 1 is IMAGE_HEADER (0x13)");

    // Verify is_continuous=0 on the wire.
    NSData *hdrPayload = records[1].payload;
    const uint8_t *hb = hdrPayload.bytes;
    // is_continuous offset: 1 (modality) + 4 + 4 + 4 (w,h,bins) +
    // 8 + 8 (pxX, pxY) + 1 (scan) + 1 (axis_kind) + 4 (axis_length)
    // + 8 * axis_length(10) = 113
    NSUInteger isContOff = 1 + 4 + 4 + 4 + 8 + 8 + 1 + 1 + 4 + 8 * 10;
    PASS(hb[isContOff] == 0u,
         "5.1 rt: IMAGE_HEADER is_continuous == 0 (processed mode)");

    // Materialise the stream back into a .tio and re-read the MSImage.
    NSString *outPath = makeTempPathIp(@"rt");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r2 = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([r2 writeTtioToPath:outPath error:&err] && err == nil,
         "5.1 rt: writeTtioToPath materialised processed-mode stream");

    TTIOMSImage *back = [TTIOMSImage readFromFilePath:outPath error:&err];
    PASS(back != nil && err == nil,
         "5.1 rt: re-opened materialised image");
    PASS(back.width == img.width
        && back.height == img.height
        && back.spectralPoints == img.spectralPoints,
         "5.1 rt: round-trip dims match");
    PASS([back.cube isEqualToData:img.cube],
         "5.1 rt: round-trip cube byte-equal (sparse -> dense)");
    PASS([back.mzAxis isEqualToData:img.mzAxis],
         "5.1 rt: round-trip mz_axis byte-equal");
    unlink([outPath fileSystemRepresentation]);
}

// -------- 2. all-zero pixel emits nonzero_count = 0 ------------------------

static void testAllZeroPixelEmitsNonzeroCountZero(void)
{
    const NSUInteger w = 2, h = 1, s = 5;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    // intentionally left zero
    NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
    double *mzp = (double *)mz.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) mzp[i] = 100.0 + (double)i * 10.0;
    TTIOMSImage *img = [[TTIOMSImage alloc]
                            initWithTitle:@"all_zero"
                       isaInvestigationId:@""
                          identifications:@[]
                          quantifications:@[]
                        provenanceRecords:@[]
                                    width:w
                                   height:h
                           spectralPoints:s
                                 tileSize:32
                               pixelSizeX:10.0
                               pixelSizeY:10.0
                              scanPattern:@"raster"
                                     cube:cube
                                   mzAxis:mz];

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w2 =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w2 writeStreamHeaderWithFormatVersion:@"1.2"
                                           title:@"img-zero"
                                isaInvestigation:@""
                                        features:@[]
                                       nDatasets:0
                                           error:&err],
         "5.1 zero: StreamHeader");
    PASS([w2 writeImageProcessed:img error:&err],
         "5.1 zero: writeImageProcessed");
    PASS([w2 writeEndOfStreamWithError:&err], "5.1 zero: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    // SH + IMAGE_HEADER + 2 IMAGE_PIXEL + EOI + EOS = 6
    PASS(records.count == 6,
         "5.1 zero: 6 packets total");

    // Each IMAGE_PIXEL: payload_length must be exactly 4 (the
    // nonzero_count field alone), and nonzero_count must be 0.
    for (NSUInteger i = 0; i < 2; i++) {
        TTIOTransportPacketRecord *rec = records[2 + i];
        const uint8_t *pb = rec.payload.bytes;
        NSUInteger po = 0;
        po += 4;       // x
        po += 4;       // y
        po += 1 + 1;   // precision + compression
        uint32_t payloadLen = leU32Ip(&pb[po]); po += 4;
        PASS(payloadLen == 4u,
             "5.1 zero: all-zero pixel payload_length == 4 (just nonzero_count)");
        uint32_t nonzero = leU32Ip(&pb[po]);
        PASS(nonzero == 0u,
             "5.1 zero: all-zero pixel nonzero_count == 0");
    }
}

// -------- 3. fully-dense pixel round-trips correctly ------------------------

static void testFullyDensePixelRoundTrips(void)
{
    const NSUInteger w = 1, h = 1, s = 8;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    for (NSUInteger k = 0; k < s; k++) p[k] = (double)(k + 1) * 7.5;
    NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
    double *mzp = (double *)mz.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) mzp[i] = 200.0 + (double)i;
    TTIOMSImage *img = [[TTIOMSImage alloc]
                            initWithTitle:@"dense"
                       isaInvestigationId:@""
                          identifications:@[]
                          quantifications:@[]
                        provenanceRecords:@[]
                                    width:w
                                   height:h
                           spectralPoints:s
                                 tileSize:32
                               pixelSizeX:5.0
                               pixelSizeY:5.0
                              scanPattern:@"raster"
                                     cube:cube
                                   mzAxis:mz];

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w2 =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w2 writeStreamHeaderWithFormatVersion:@"1.2"
                                           title:@"img-dense"
                                isaInvestigation:@""
                                        features:@[TTIOTransportV011Feature]
                                       nDatasets:0
                                           error:&err],
         "5.1 dense: StreamHeader");
    PASS([w2 writeImageProcessed:img error:&err],
         "5.1 dense: writeImageProcessed");
    PASS([w2 writeEndOfStreamWithError:&err], "5.1 dense: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    PASS(records.count == 5,
         "5.1 dense: SH + IMAGE_HEADER + 1 IMAGE_PIXEL + EOI + EOS");

    TTIOTransportPacketRecord *pixRec = records[2];
    const uint8_t *pb = pixRec.payload.bytes;
    NSUInteger po = 4 + 4 + 1 + 1;  // skip x, y, precision, compression
    uint32_t payloadLen = leU32Ip(&pb[po]); po += 4;
    // Fully-dense pixel: payload = 4 + s*(4+8) = 4 + 8*12 = 100.
    PASS(payloadLen == (uint32_t)(4 + s * (4 + 8)),
         "5.1 dense: fully-dense pixel payload size");
    uint32_t nonzero = leU32Ip(&pb[po]); po += 4;
    PASS(nonzero == (uint32_t)s,
         "5.1 dense: nonzero_count == bins (every channel)");
    // Each entry: u32 channel + f64 intensity. Channels MUST appear
    // in ascending order (matches Java/Python iteration).
    for (NSUInteger k = 0; k < s; k++) {
        uint32_t ch = leU32Ip(&pb[po]); po += 4;
        double v = leF64Ip(&pb[po]);    po += 8;
        PASS(ch == (uint32_t)k,
             "5.1 dense: channels ascending");
        PASS(v == (double)(k + 1) * 7.5,
             "5.1 dense: intensities round-trip byte-exact");
    }

    // Full round-trip via materialise.
    NSString *outPath = makeTempPathIp(@"dense");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r2 = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([r2 writeTtioToPath:outPath error:&err] && err == nil,
         "5.1 dense: writeTtioToPath materialised");
    TTIOMSImage *back = [TTIOMSImage readFromFilePath:outPath error:&err];
    PASS([back.cube isEqualToData:img.cube],
         "5.1 dense: round-trip cube byte-equal");
    unlink([outPath fileSystemRepresentation]);
}

// -------- 4. mixed sparse + dense pixels round-trip ------------------------

static void testMixedSparseAndDensePixels(void)
{
    const NSUInteger w = 2, h = 2, s = 4;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    // pixel (0,0) all zero; (1,0) one nonzero; (0,1) all nonzero;
    // (1,1) two nonzeros at non-contiguous channels.
    p[(0 * w + 1) * s + 2] = 7.25;
    for (NSUInteger k = 0; k < s; k++) p[(1 * w + 0) * s + k] = (double)(k + 1) * 3.5;
    p[(1 * w + 1) * s + 0] = 11.0;
    p[(1 * w + 1) * s + 3] = 99.5;
    NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
    double *mzp = (double *)mz.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) mzp[i] = 50.0 + (double)i * 5.0;

    TTIOMSImage *img = [[TTIOMSImage alloc]
                            initWithTitle:@"mixed"
                       isaInvestigationId:@""
                          identifications:@[]
                          quantifications:@[]
                        provenanceRecords:@[]
                                    width:w
                                   height:h
                           spectralPoints:s
                                 tileSize:32
                               pixelSizeX:1.0
                               pixelSizeY:1.0
                              scanPattern:@"raster"
                                     cube:cube
                                   mzAxis:mz];

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w2 =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w2 writeStreamHeaderWithFormatVersion:@"1.2"
                                           title:@"img-mixed"
                                isaInvestigation:@""
                                        features:@[TTIOTransportV011Feature]
                                       nDatasets:0
                                           error:&err],
         "5.1 mixed: StreamHeader");
    PASS([w2 writeImageProcessed:img error:&err],
         "5.1 mixed: writeImageProcessed");
    PASS([w2 writeEndOfStreamWithError:&err], "5.1 mixed: EndOfStream");

    NSString *outPath = makeTempPathIp(@"mixed");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "5.1 mixed: materialised");
    TTIOMSImage *back = [TTIOMSImage readFromFilePath:outPath error:&err];
    PASS(back != nil, "5.1 mixed: re-opened");
    PASS([back.cube isEqualToData:img.cube],
         "5.1 mixed: round-trip cube byte-equal (mixed sparsity)");
    unlink([outPath fileSystemRepresentation]);
}

// -------- entry point ------------------------------------------------------

void testTransportImageProcessed(void);
void testTransportImageProcessed(void)
{
    testProcessedModeRoundTripsSparseCube();
    testAllZeroPixelEmitsNonzeroCountZero();
    testFullyDensePixelRoundTrips();
    testMixedSparseAndDensePixels();
}
