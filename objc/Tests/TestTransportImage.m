/*
 * TestTransportImage.m — Task 3.6 of transport-spec v0.11.
 *
 * Exercises IMAGE_HEADER (0x13) + IMAGE_PIXEL (0x14) + END_OF_IMAGE
 * (0x15) writer + reader. Continuous-mode only at Task 3.6.
 *
 * Wire layout per transport-spec §4.16-§4.18:
 *   IMAGE_HEADER:  u8 modality + u32 width + u32 height + u32 bins +
 *                  f64 pixel_size_x + f64 pixel_size_y +
 *                  u8 scan_pattern + u8 axis_kind + u32 axis_length +
 *                  N x f64 mz_axis + u8 is_continuous +
 *                  u16 + UTF-8 title + u16 + UTF-8 isa_id
 *   IMAGE_PIXEL:   u32 x + u32 y + u8 precision + u8 compression +
 *                  u32 payload_length + intensities[..]
 *                  (auSequence on the header carries y*width+x)
 *   END_OF_IMAGE:  u32 pixel_count_seen
 * All LE.
 *
 * Cross-language parity:
 *   Java TransportImageTest (commit a6b1e5d9)
 *   Python tests/test_transport_image.py (commit 1f619ced)
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

static NSString *makeTempPathI(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_img_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory()
        stringByAppendingPathComponent:base];
}

static uint16_t leU16I(const uint8_t *b)
{
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}

static uint32_t leU32I(const uint8_t *b)
{
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

static double leF64I(const uint8_t *b)
{
    uint64_t lo = (uint64_t)leU32I(b);
    uint64_t hi = (uint64_t)leU32I(b + 4);
    uint64_t bits = lo | (hi << 32);
    double d;
    memcpy(&d, &bits, 8);
    return d;
}

// Deterministic 4x4x5 MSImage that mirrors the Java
// `FixtureBuilder.buildImageMsContinuous` cube. The intensity formula
// is `(k+1) * (x + y*width)` so pixel (0,0) is all zeros and pixel
// (3,3) carries the largest values. The mz_axis is 100,110,120,130,140.
static TTIOMSImage *buildContinuousFixture(void)
{
    const NSUInteger w = 4;
    const NSUInteger h = 4;
    const NSUInteger s = 5;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    for (NSUInteger y = 0; y < h; y++) {
        for (NSUInteger x = 0; x < w; x++) {
            NSUInteger pixelIdx = x + y * w;
            NSUInteger base = (y * w + x) * s;
            for (NSUInteger k = 0; k < s; k++) {
                p[base + k] = (double)(k + 1) * (double)pixelIdx;
            }
        }
    }
    NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
    double *mzp = (double *)mz.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) mzp[i] = 100.0 + (double)i * 10.0;

    return [[TTIOMSImage alloc]
                initWithTitle:@"image_ms_continuous"
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

// -------- 1. packet ordering: header + N pixels + EOI ----------------------

static void testWriteImageEmitsHeaderThenNPixelsThenEoi(void)
{
    TTIOMSImage *img = buildContinuousFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"img-order"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.6 order: StreamHeader");
    PASS([w writeImage:img error:&err],
         "3.6 order: writeImage: emitted");
    PASS([w writeEndOfStreamWithError:&err],
         "3.6 order: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    // StreamHeader + IMAGE_HEADER + 16 IMAGE_PIXEL + END_OF_IMAGE + EndOfStream
    PASS(records.count == 1 + 1 + 16 + 1 + 1,
         "3.6 order: 20 packets (header + 1 + 16 + 1 + EOS)");

    PASS(records[1].header.packetType
            == TTIOTransportPacketImageHeader,
         "3.6 order: packet 1 is IMAGE_HEADER (0x13)");

    for (NSUInteger i = 0; i < 16; i++) {
        TTIOTransportPacketRecord *rec = records[2 + i];
        PASS(rec.header.packetType
                == TTIOTransportPacketImagePixel,
             "3.6 order: pixel packet is IMAGE_PIXEL (0x14)");
        PASS(rec.header.auSequence == i,
             "3.6 order: pixel auSequence == raster index");
    }

    PASS(records[18].header.packetType
            == TTIOTransportPacketEndOfImage,
         "3.6 order: packet 18 is END_OF_IMAGE (0x15)");

    // END_OF_IMAGE payload: u32 pixel_count_seen = 16
    NSData *eoiPayload = records[18].payload;
    PASS(eoiPayload.length == 4,
         "3.6 order: END_OF_IMAGE payload is 4 bytes");
    PASS(leU32I(eoiPayload.bytes) == 16u,
         "3.6 order: END_OF_IMAGE pixel_count_seen == width*height");
}

// -------- 2. IMAGE_HEADER wire layout (byte parity with Java/Python) -------

static void testImageHeaderWireLayout(void)
{
    TTIOMSImage *img = buildContinuousFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"img-wire"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.6 wire: StreamHeader");
    PASS([w writeImage:img error:&err],
         "3.6 wire: writeImage emitted");
    PASS([w writeEndOfStreamWithError:&err], "3.6 wire: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];

    // IMAGE_HEADER payload structural checks (Java parity).
    NSData *hdrPayload = records[1].payload;
    const uint8_t *hb = hdrPayload.bytes;
    NSUInteger ho = 0;
    PASS(hb[ho] == 0u, "3.6 wire: modality == 0 (MS)"); ho += 1;
    PASS(leU32I(&hb[ho]) == 4u, "3.6 wire: width == 4");   ho += 4;
    PASS(leU32I(&hb[ho]) == 4u, "3.6 wire: height == 4");  ho += 4;
    PASS(leU32I(&hb[ho]) == 5u, "3.6 wire: spectrum_bins == 5"); ho += 4;
    PASS(leF64I(&hb[ho]) == 10.0, "3.6 wire: pixel_size_x == 10"); ho += 8;
    PASS(leF64I(&hb[ho]) == 10.0, "3.6 wire: pixel_size_y == 10"); ho += 8;
    PASS(hb[ho] == 0u, "3.6 wire: scan_pattern == 0 (raster/flyback)"); ho += 1;
    PASS(hb[ho] == 0u, "3.6 wire: axis_kind == 0 (mz)"); ho += 1;
    uint32_t axisLen = leU32I(&hb[ho]); ho += 4;
    PASS(axisLen == 5u, "3.6 wire: axis_length == 5");
    double expectedMz[5] = { 100.0, 110.0, 120.0, 130.0, 140.0 };
    for (NSUInteger i = 0; i < axisLen; i++) {
        PASS(leF64I(&hb[ho]) == expectedMz[i],
             "3.6 wire: mz_axis byte-equal");
        ho += 8;
    }
    PASS(hb[ho] == 1u, "3.6 wire: is_continuous == 1"); ho += 1;
    uint16_t titleLen = leU16I(&hb[ho]); ho += 2;
    PASS(titleLen == strlen("image_ms_continuous"),
         "3.6 wire: title length");
    NSString *title = [[NSString alloc] initWithBytes:&hb[ho]
                                                length:titleLen
                                              encoding:NSUTF8StringEncoding];
    PASS([title isEqualToString:@"image_ms_continuous"],
         "3.6 wire: title bytes");
    ho += titleLen;
    uint16_t isaLen = leU16I(&hb[ho]); ho += 2;
    PASS(isaLen == 0u, "3.6 wire: isa_id length == 0"); ho += isaLen;
    // v0.11 Stage 5.3: modality_extras tail. MS modality (0) carries
    // an empty extras body (length=0) but the 2-byte length prefix
    // is still on the wire so unknown-modality readers can advance
    // past the header uniformly.
    uint16_t extrasLen = leU16I(&hb[ho]); ho += 2;
    PASS(extrasLen == 0u,
         "3.6 wire: modality=0 modality_extras_length == 0");
    PASS(ho == hdrPayload.length,
         "3.6 wire: no trailing IMAGE_HEADER bytes after modality_extras");
}

// -------- 3. IMAGE_PIXEL wire layout + intensity round-trip ----------------

static void testImagePixelWireLayout(void)
{
    TTIOMSImage *img = buildContinuousFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"img-pixel"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "3.6 pixel: StreamHeader");
    PASS([w writeImage:img error:&err], "3.6 pixel: writeImage");
    PASS([w writeEndOfStreamWithError:&err], "3.6 pixel: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];

    // Spot-check pixel (3,3) — the largest-values pixel.
    // raster index for (x=3, y=3) is 3 + 3*4 = 15
    TTIOTransportPacketRecord *p33 = records[2 + 15];
    PASS(p33.header.packetType == TTIOTransportPacketImagePixel,
         "3.6 pixel: (3,3) is IMAGE_PIXEL");
    PASS(p33.header.auSequence == 15u,
         "3.6 pixel: (3,3) auSequence == 15");
    const uint8_t *pb = p33.payload.bytes;
    NSUInteger po = 0;
    PASS(leU32I(&pb[po]) == 3u, "3.6 pixel: x == 3"); po += 4;
    PASS(leU32I(&pb[po]) == 3u, "3.6 pixel: y == 3"); po += 4;
    PASS(pb[po] == 1u, "3.6 pixel: precision == 1 (FLOAT64)"); po += 1;
    PASS(pb[po] == 0u, "3.6 pixel: compression == 0 (NONE)"); po += 1;
    uint32_t payloadLen = leU32I(&pb[po]); po += 4;
    PASS(payloadLen == (uint32_t)(5 * sizeof(double)),
         "3.6 pixel: payload_length == bins * 8");

    // For pixel idx 15, expected intensities are (k+1) * 15 for k=0..4
    for (NSUInteger k = 0; k < 5; k++) {
        double expected = (double)(k + 1) * 15.0;
        PASS(leF64I(&pb[po]) == expected,
             "3.6 pixel: (3,3) intensity[k] byte-equal");
        po += 8;
    }
    PASS(po == p33.payload.length,
         "3.6 pixel: no trailing pixel bytes");
}

// -------- 4. round-trip via writeTtioToPath: -> reopen MSImage -------------

static void testImageRoundTripViaMaterialize(void)
{
    TTIOMSImage *img = buildContinuousFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"image_ms_continuous"
                               isaInvestigation:@""
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "3.6 rt: StreamHeader");
    PASS([w writeImage:img error:&err], "3.6 rt: writeImage");
    PASS([w writeEndOfStreamWithError:&err], "3.6 rt: EndOfStream");

    NSString *outPath = makeTempPathI(@"rt");
    unlink([outPath fileSystemRepresentation]);

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([r writeTtioToPath:outPath error:&err] && err == nil,
         "3.6 rt: writeTtioToPath materialised");

    TTIOMSImage *back = [TTIOMSImage readFromFilePath:outPath error:&err];
    PASS(back != nil && err == nil,
         "3.6 rt: re-opened materialised image");
    PASS(back.width == img.width
        && back.height == img.height
        && back.spectralPoints == img.spectralPoints,
         "3.6 rt: round-trip dims match");
    PASS([back.cube isEqualToData:img.cube],
         "3.6 rt: round-trip cube byte-equal");
    PASS([back.mzAxis isEqualToData:img.mzAxis],
         "3.6 rt: round-trip mz_axis byte-equal");
    PASS([back.title isEqualToString:img.title],
         "3.6 rt: round-trip title matches");
    PASS([back.scanPattern isEqualToString:@"raster"],
         "3.6 rt: round-trip scan_pattern == raster");

    unlink([outPath fileSystemRepresentation]);
}

// -------- 5. v0.10 dataset with no image -> zero image packets -------------

static void testNoImagePacketsForImagelessDataset(void)
{
    NSError *err = nil;
    NSString *src = makeTempPathI(@"noimg");
    unlink([src fileSystemRepresentation]);
    BOOL ok = [TTIOSpectralDataset writeMinimalToPath:src
                                                  title:@"plain"
                                     isaInvestigationId:@""
                                                 msRuns:@{}
                                        identifications:nil
                                        quantifications:nil
                                      provenanceRecords:nil
                                                  error:&err];
    PASS(ok, "3.6 noimg: minimal .tio created");

    TTIOSpectralDataset *ds =
        [TTIOSpectralDataset readFromFilePath:src error:&err];
    PASS(ds != nil, "3.6 noimg: opened dataset");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err],
         "3.6 noimg: writeDataset on image-less .tio");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    BOOL sawAnyImage = NO;
    for (TTIOTransportPacketRecord *rec in records) {
        TTIOTransportPacketType t = rec.header.packetType;
        if (t == TTIOTransportPacketImageHeader
            || t == TTIOTransportPacketImagePixel
            || t == TTIOTransportPacketEndOfImage) {
            sawAnyImage = YES;
            break;
        }
    }
    PASS(!sawAnyImage,
         "3.6 noimg: image-less dataset emits no IMAGE_* packets");

    [ds closeFile];
    unlink([src fileSystemRepresentation]);
}

// -------- 6. END_OF_IMAGE mismatch -> reader rejects -----------------------

// Hand-roll a stream that lies about pixel_count_seen so the reader's
// guard fires deterministically. We emit a tiny 1x1 image with the
// correct prefix but a deliberately-wrong END_OF_IMAGE.payload.
static void testEoiPixelCountMismatchRejected(void)
{
    // Build a 1x1 image first using the writer, then patch the
    // END_OF_IMAGE payload to declare 99 pixels seen.
    const NSUInteger w = 1, h = 1, s = 2;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    NSMutableData *mz = [NSMutableData dataWithLength:s * sizeof(double)];
    double *mzp = (double *)mz.mutableBytes;
    mzp[0] = 100.0; mzp[1] = 110.0;
    TTIOMSImage *tiny = [[TTIOMSImage alloc]
                            initWithTitle:@"tiny"
                       isaInvestigationId:@""
                          identifications:@[]
                          quantifications:@[]
                        provenanceRecords:@[]
                                    width:w
                                   height:h
                           spectralPoints:s
                                 tileSize:32
                               pixelSizeX:0
                               pixelSizeY:0
                              scanPattern:@"raster"
                                     cube:cube
                                   mzAxis:mz];

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w2 =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w2 writeStreamHeaderWithFormatVersion:@"1.2"
                                           title:@"img-mismatch"
                                isaInvestigation:@""
                                        features:@[]
                                       nDatasets:0
                                           error:&err],
         "3.6 mism: StreamHeader");
    PASS([w2 writeImage:tiny error:&err], "3.6 mism: writeImage");
    PASS([w2 writeEndOfStreamWithError:&err], "3.6 mism: EndOfStream");

    // Parse the packet structure so we can target the EOI payload
    // precisely. The reader exposes the per-packet (header, payload)
    // pairs; we sum up the on-wire byte sizes to find the END_OF_IMAGE
    // payload's absolute offset, then overwrite its 4-byte
    // pixel_count_seen field with 99. Patching the EOI alone keeps the
    // earlier IMAGE_HEADER + IMAGE_PIXEL packets byte-identical so the
    // failure is unambiguously "END_OF_IMAGE pixel_count_seen
    // mismatch", not a structural corruption further upstream.
    TTIOTransportReader *probeM =
        [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *probeRecs =
        [probeM readAllPacketsWithError:&err];
    PASS(probeRecs != nil, "3.6 mism: parsed probe stream");
    NSMutableData *mut = [buf mutableCopy];
    // Walk the packets and stop at END_OF_IMAGE; track running byte
    // offset assuming each record contributes header+payload+(crc?)
    // on the wire. Easier: encode a single fresh writeImage into a
    // known buffer, locate the trailing END_OF_IMAGE bytes by reverse-
    // searching for the EOI packet type byte (0x15) inside the packet
    // header region. The packet header marker 0x15 only appears once
    // per stream segment (the EOI packet); follow it past the fixed
    // header to land on payload[0] and patch the 4-byte pixel_count.
    uint8_t *p = mut.mutableBytes;
    NSUInteger n = mut.length;
    NSUInteger eoiPacketStart = NSNotFound;
    // Packet wire layout (see TTIOTransportPacket.m): every packet
    // starts with the 4-byte signature {'T', 'I', version=0x01,
    // type_byte}. For END_OF_IMAGE the type is 0x15. Earlier versions
    // of this test scanned backwards for byte 0x15 alone — that's a
    // common byte value that collides with the float64 intensity
    // payload bytes upstream, producing intermittent CI flakes
    // (PR #175). Anchor on the full 4-byte magic+version+type prefix
    // to make the scan deterministic regardless of payload content.
    for (NSUInteger i = n; i >= 4; i--) {
        if (p[i - 4] == 'T' && p[i - 3] == 'I'
                && p[i - 2] == 0x01 && p[i - 1] == 0x15) {
            eoiPacketStart = i - 4;
            break;
        }
    }
    PASS(eoiPacketStart != NSNotFound,
         "3.6 mism: located END_OF_IMAGE packet header [T,I,01,15]");
    // From TTIOTransportHeaderSize == 24, the EOI payload starts at
    // eoiPacketStart + 24. The pixel_count_seen field is the first
    // 4 bytes of that payload. Patch in place.
    BOOL patched = NO;
    if (eoiPacketStart != NSNotFound && eoiPacketStart + 24 + 4 <= n) {
        NSUInteger payloadIdx = eoiPacketStart + 24;
        // Sanity check: should currently read 0x01 0x00 0x00 0x00 (one pixel).
        if (p[payloadIdx]     == 0x01 && p[payloadIdx + 1] == 0x00
                && p[payloadIdx + 2] == 0x00 && p[payloadIdx + 3] == 0x00) {
            p[payloadIdx]     = 0x63;  // 99 little-endian
            p[payloadIdx + 1] = 0x00;
            p[payloadIdx + 2] = 0x00;
            p[payloadIdx + 3] = 0x00;
            patched = YES;
        }
    }
    PASS(patched, "3.6 mism: patched EOI pixel_count_seen to 99");

    NSString *outPath = makeTempPathI(@"mism");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r =
        [[TTIOTransportReader alloc] initWithData:mut];
    BOOL ok = [r writeTtioToPath:outPath error:&err];
    PASS(!ok && err != nil,
         "3.6 mism: reader rejects mismatched END_OF_IMAGE pixel_count_seen");

    unlink([outPath fileSystemRepresentation]);
}

// -------- entry point ------------------------------------------------------

void testTransportImage(void);
void testTransportImage(void)
{
    testWriteImageEmitsHeaderThenNPixelsThenEoi();
    testImageHeaderWireLayout();
    testImagePixelWireLayout();
    testImageRoundTripViaMaterialize();
    testNoImagePacketsForImagelessDataset();
    testEoiPixelCountMismatchRejected();
}
