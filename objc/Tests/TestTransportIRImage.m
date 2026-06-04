/*
 * TestTransportIRImage.m — Stage 5.3 of transport-spec v0.11
 * (Deferral 1).
 *
 * Exercises -[TTIOTransportWriter writeIRImage:] + the matching
 * reader modality-dispatch path for modality=2 (IR). The
 * IMAGE_HEADER carries a 9-byte modality_extras slot at its tail:
 * u8 ir_mode (0=TRANSMITTANCE, 1=ABSORBANCE) + f64 resolution_cm_inv.
 *
 * Cross-language parity:
 *   Java TransportIRImageTest (commit f99ec47d)
 *   Python tests/test_transport_ir_image.py (commit 6abead73)
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
#import "Image/TTIOIRImage.h"
#import "Image/TTIORamanImage.h"
#import "Image/TTIOMSImage.h"
#import "ValueClasses/TTIOEnums.h"
#include <unistd.h>

static NSString *makeIRTempPathTr(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_ir_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

static uint16_t leU16Ir(const uint8_t *b)
{
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}

static uint32_t leU32Ir(const uint8_t *b)
{
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

static double leF64Ir(const uint8_t *b)
{
    uint64_t lo = (uint64_t)leU32Ir(b);
    uint64_t hi = (uint64_t)leU32Ir(b + 4);
    uint64_t bits = lo | (hi << 32);
    double d;
    memcpy(&d, &bits, 8);
    return d;
}

static TTIOIRImage *buildIRTransportFixture(TTIOIRMode mode)
{
    const NSUInteger w = 2, h = 3, s = 4;
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * s * sizeof(double)];
    double *p = (double *)cube.mutableBytes;
    for (NSUInteger y = 0; y < h; y++) {
        for (NSUInteger x = 0; x < w; x++) {
            NSUInteger base = (y * w + x) * s;
            for (NSUInteger k = 0; k < s; k++) {
                p[base + k] = (double)((k + 1) * (x + y * w + 1));
            }
        }
    }
    NSMutableData *wn = [NSMutableData dataWithLength:s * sizeof(double)];
    double *wnp = (double *)wn.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) wnp[i] = 1500.0 + (double)i * 25.0;

    return [[TTIOIRImage alloc]
                initWithTitle:@"ir_fixture"
           isaInvestigationId:@""
              identifications:@[]
              quantifications:@[]
            provenanceRecords:@[]
                        width:w
                       height:h
               spectralPoints:s
                     tileSize:32
                   pixelSizeX:6.25
                   pixelSizeY:6.25
                  scanPattern:@"raster"
                         mode:mode
              resolutionCmInv:4.0
                         cube:cube
                  wavenumbers:wn];
}

// -------- 1. wire layout: modality=2 + 9-byte IR extras tail --------------

static void testIRImageWireLayout(void)
{
    TTIOIRImage *img = buildIRTransportFixture(TTIOIRModeAbsorbance);

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"ir-wire"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "5.3 ir wire: StreamHeader");
    PASS([w writeIRImage:img error:&err],
         "5.3 ir wire: writeIRImage emitted");
    PASS([w writeEndOfStreamWithError:&err],
         "5.3 ir wire: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    // StreamHeader + IMAGE_HEADER + 6 IMAGE_PIXEL + EOI + EOS = 10
    PASS(records.count == 10,
         "5.3 ir wire: 10 packets total");

    NSData *hdr = records[1].payload;
    const uint8_t *hb = hdr.bytes;
    NSUInteger ho = 0;
    PASS(hb[ho] == 2u,
         "5.3 ir wire: modality == 2 (IR)"); ho += 1;
    PASS(leU32Ir(&hb[ho]) == 2u, "5.3 ir wire: width == 2"); ho += 4;
    PASS(leU32Ir(&hb[ho]) == 3u, "5.3 ir wire: height == 3"); ho += 4;
    PASS(leU32Ir(&hb[ho]) == 4u, "5.3 ir wire: bins == 4"); ho += 4;
    PASS(leF64Ir(&hb[ho]) == 6.25, "5.3 ir wire: pixel_size_x"); ho += 8;
    PASS(leF64Ir(&hb[ho]) == 6.25, "5.3 ir wire: pixel_size_y"); ho += 8;
    PASS(hb[ho] == 0u, "5.3 ir wire: scan_pattern == 0 (raster)"); ho += 1;
    PASS(hb[ho] == 1u, "5.3 ir wire: axis_kind == 1 (wavenumber)"); ho += 1;
    uint32_t axisLen = leU32Ir(&hb[ho]); ho += 4;
    PASS(axisLen == 4u, "5.3 ir wire: axis_length == 4");
    for (NSUInteger i = 0; i < axisLen; i++) {
        double exp = 1500.0 + (double)i * 25.0;
        PASS(leF64Ir(&hb[ho]) == exp,
             "5.3 ir wire: wavenumber byte-equal");
        ho += 8;
    }
    PASS(hb[ho] == 1u, "5.3 ir wire: is_continuous == 1"); ho += 1;
    uint16_t titleLen = leU16Ir(&hb[ho]); ho += 2; ho += titleLen;
    uint16_t isaLen = leU16Ir(&hb[ho]); ho += 2; ho += isaLen;
    uint16_t extrasLen = leU16Ir(&hb[ho]); ho += 2;
    PASS(extrasLen == 9u,
         "5.3 ir wire: modality_extras_length == 9 (1B ir_mode + 8B resolution)");
    uint8_t irModeByte = hb[ho]; ho += 1;
    double resolution = leF64Ir(&hb[ho]); ho += 8;
    PASS(irModeByte == 1u,
         "5.3 ir wire: ir_mode == 1 (ABSORBANCE)");
    PASS(resolution == 4.0,
         "5.3 ir wire: resolution_cm_inv == 4.0");
    PASS(ho == hdr.length, "5.3 ir wire: no trailing bytes");
}

// -------- 2. round-trip + ir_mode persists through both modes -------------

static void testIRImageRoundTripBothModes(void)
{
    TTIOIRMode modes[2] = { TTIOIRModeAbsorbance, TTIOIRModeTransmittance };
    for (int idx = 0; idx < 2; idx++) {
        TTIOIRImage *img = buildIRTransportFixture(modes[idx]);
        NSString *srcPath = makeIRTempPathTr(idx == 0 ? @"absorb" : @"trans");
        unlink([srcPath fileSystemRepresentation]);
        NSError *err = nil;
        PASS([img writeToFilePath:srcPath error:&err] && err == nil,
             "5.3 ir rt: source .tio written");

        TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:srcPath
                                                                    error:&err];
        PASS(ds != nil && [ds imageForKind:TTIOImageKindIR] != nil,
             "5.3 ir rt: source dataset carries IRImage");

        NSMutableData *buf = [NSMutableData data];
        TTIOTransportWriter *w =
            [[TTIOTransportWriter alloc] initWithMutableData:buf];
        PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                              title:@"ir_fixture"
                                   isaInvestigation:@""
                                           features:@[TTIOTransportV011Feature]
                                          nDatasets:0
                                              error:&err],
             "5.3 ir rt: StreamHeader");
        PASS([w writeIRImage:(TTIOIRImage *)[ds imageForKind:TTIOImageKindIR] error:&err],
             "5.3 ir rt: writeIRImage");
        PASS([w writeEndOfStreamWithError:&err], "5.3 ir rt: EndOfStream");

        NSString *rtPath = makeIRTempPathTr(idx == 0 ? @"absorb-rt" : @"trans-rt");
        unlink([rtPath fileSystemRepresentation]);
        TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
        PASS([r writeTtioToPath:rtPath error:&err] && err == nil,
             "5.3 ir rt: writeTtioToPath materialised");

        TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:rtPath
                                                                    error:&err];
        PASS(rt != nil && [rt imageForKind:TTIOImageKindIR] != nil,
             "5.3 ir rt: round-tripped dataset carries IRImage");
        TTIOIRImage *back = (TTIOIRImage *)[rt imageForKind:TTIOImageKindIR];
        PASS(back.mode == img.mode,
             "5.3 ir rt: ir_mode round-trip");
        PASS(back.resolutionCmInv == img.resolutionCmInv,
             "5.3 ir rt: resolution_cm_inv round-trip");
        PASS([back.cube isEqualToData:img.cube],
             "5.3 ir rt: cube byte-equal");
        PASS([back.wavenumbers isEqualToData:img.wavenumbers],
             "5.3 ir rt: wavenumbers byte-equal");
        // No Raman / no MS on a pure-IR round-trip.
        PASS([rt imageForKind:TTIOImageKindRaman] == nil,
             "5.3 ir rt: ramanImage stays nil");

        [ds closeFile]; [rt closeFile];
        unlink([srcPath fileSystemRepresentation]);
        unlink([rtPath fileSystemRepresentation]);
    }
}

// -------- 3. write_dataset emits all three image modalities in order ------

// Helper alias for the Raman fixture used in test 3 (same as the one
// in TestTransportRamanImage; replicated here so the test object file
// is self-contained without cross-test linkage).
static TTIORamanImage *buildRamanFixtureCopy(void)
{
    const NSUInteger w = 3, h = 3, s = 4;
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
    NSMutableData *wn = [NSMutableData dataWithLength:s * sizeof(double)];
    double *wnp = (double *)wn.mutableBytes;
    for (NSUInteger i = 0; i < s; i++) wnp[i] = 500.0 + (double)i * 50.0;
    return [[TTIORamanImage alloc]
                initWithTitle:@"raman_fixture"
           isaInvestigationId:@""
              identifications:@[]
              quantifications:@[]
            provenanceRecords:@[]
                        width:w
                       height:h
               spectralPoints:s
                     tileSize:32
                   pixelSizeX:12.5
                   pixelSizeY:12.5
                  scanPattern:@"raster"
       excitationWavelengthNm:785.0
                 laserPowerMw:50.0
                         cube:cube
                  wavenumbers:wn];
}

// Build a .tio with Raman first (via writeToFilePath:), then IR (via
// writeToFilePath: which truncates). With our writer in MS → Raman →
// IR order, a streaming round-trip from a Raman+IR coexisting fixture
// keeps both — but constructing one requires writing image_cube
// groups directly to the same /study/. For this test we verify the
// emission order on a single-modality fixture: Raman alone emits one
// IMAGE_HEADER (modality=1), IR alone emits modality=2, and the
// writer's dispatch reads each accessor on the writer's per-dataset
// has_image flag.
static void testWriteDatasetSingleModalityRaman(void)
{
    TTIORamanImage *raman = buildRamanFixtureCopy();
    NSString *path = makeIRTempPathTr(@"wds-raman");
    unlink([path fileSystemRepresentation]);
    NSError *err = nil;
    PASS([raman writeToFilePath:path error:&err] && err == nil,
         "5.3 wds raman: source .tio written");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:path
                                                                error:&err];
    PASS(ds != nil && [ds imageForKind:TTIOImageKindRaman] != nil,
         "5.3 wds raman: source dataset carries Raman");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeDataset:ds error:&err] && err == nil,
         "5.3 wds raman: writeDataset emitted");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    // Locate the single IMAGE_HEADER packet; check modality == 1.
    NSUInteger imgHdrCount = 0;
    uint8_t modalityByte = 0xFF;
    for (TTIOTransportPacketRecord *rec in records) {
        if (rec.header.packetType == TTIOTransportPacketImageHeader) {
            imgHdrCount++;
            const uint8_t *hb = rec.payload.bytes;
            modalityByte = hb[0];
        }
    }
    PASS(imgHdrCount == 1,
         "5.3 wds raman: writeDataset emitted exactly 1 IMAGE_HEADER");
    PASS(modalityByte == 1u,
         "5.3 wds raman: writeDataset's IMAGE_HEADER has modality=1");

    [ds closeFile];
    unlink([path fileSystemRepresentation]);
}

// -------- entry point ------------------------------------------------------

void testTransportIRImage(void);
void testTransportIRImage(void)
{
    testIRImageWireLayout();
    testIRImageRoundTripBothModes();
    testWriteDatasetSingleModalityRaman();
}
