/*
 * TestTransportRamanImage.m — Stage 5.3 of transport-spec v0.11
 * (Deferral 1).
 *
 * Exercises -[TTIOTransportWriter writeRamanImage:] + the matching
 * reader modality-dispatch path for modality=1 (Raman). The
 * IMAGE_HEADER carries a 16-byte modality_extras slot at its tail
 * containing two FLOAT64s: excitation_wavelength_nm + laser_power_mw.
 *
 * Cross-language parity:
 *   Java TransportRamanImageTest (commit f99ec47d)
 *   Python tests/test_transport_raman_image.py (commit 6abead73)
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
#import "Image/TTIORamanImage.h"
#import "Image/TTIOIRImage.h"
#import "Image/TTIOMSImage.h"
#include <unistd.h>

static NSString *makeRamanTempPath(NSString *suffix)
{
    NSString *base = [NSString stringWithFormat:@"ttio_tr_raman_%d_%@.tio",
                       (int)getpid(), suffix];
    return [NSTemporaryDirectory() stringByAppendingPathComponent:base];
}

static uint16_t leU16Rm(const uint8_t *b)
{
    return (uint16_t)((uint32_t)b[0] | ((uint32_t)b[1] << 8));
}

static uint32_t leU32Rm(const uint8_t *b)
{
    return (uint32_t)b[0]
         | ((uint32_t)b[1] << 8)
         | ((uint32_t)b[2] << 16)
         | ((uint32_t)b[3] << 24);
}

static double leF64Rm(const uint8_t *b)
{
    uint64_t lo = (uint64_t)leU32Rm(b);
    uint64_t hi = (uint64_t)leU32Rm(b + 4);
    uint64_t bits = lo | (hi << 32);
    double d;
    memcpy(&d, &bits, 8);
    return d;
}

static TTIORamanImage *buildRamanFixture(void)
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

// -------- 1. wire layout: modality=1 + 16-byte Raman extras tail ----------

static void testRamanImageWireLayout(void)
{
    TTIORamanImage *img = buildRamanFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"raman-wire"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "5.3 raman wire: StreamHeader");
    PASS([w writeRamanImage:img error:&err],
         "5.3 raman wire: writeRamanImage emitted");
    PASS([w writeEndOfStreamWithError:&err],
         "5.3 raman wire: EndOfStream");

    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    NSArray<TTIOTransportPacketRecord *> *records =
        [r readAllPacketsWithError:&err];
    // StreamHeader + IMAGE_HEADER + 9 IMAGE_PIXEL + EOI + EOS = 13
    PASS(records.count == 13,
         "5.3 raman wire: 13 packets total");

    NSData *hdr = records[1].payload;
    const uint8_t *hb = hdr.bytes;
    NSUInteger ho = 0;
    PASS(hb[ho] == 1u,
         "5.3 raman wire: modality == 1 (Raman)"); ho += 1;
    PASS(leU32Rm(&hb[ho]) == 3u, "5.3 raman wire: width == 3"); ho += 4;
    PASS(leU32Rm(&hb[ho]) == 3u, "5.3 raman wire: height == 3"); ho += 4;
    PASS(leU32Rm(&hb[ho]) == 4u, "5.3 raman wire: bins == 4"); ho += 4;
    PASS(leF64Rm(&hb[ho]) == 12.5, "5.3 raman wire: pixel_size_x"); ho += 8;
    PASS(leF64Rm(&hb[ho]) == 12.5, "5.3 raman wire: pixel_size_y"); ho += 8;
    PASS(hb[ho] == 0u, "5.3 raman wire: scan_pattern == 0 (raster)"); ho += 1;
    PASS(hb[ho] == 1u, "5.3 raman wire: axis_kind == 1 (wavenumber)"); ho += 1;
    uint32_t axisLen = leU32Rm(&hb[ho]); ho += 4;
    PASS(axisLen == 4u, "5.3 raman wire: axis_length == 4");
    for (NSUInteger i = 0; i < axisLen; i++) {
        double exp = 500.0 + (double)i * 50.0;
        PASS(leF64Rm(&hb[ho]) == exp,
             "5.3 raman wire: wavenumber byte-equal");
        ho += 8;
    }
    PASS(hb[ho] == 1u, "5.3 raman wire: is_continuous == 1"); ho += 1;
    uint16_t titleLen = leU16Rm(&hb[ho]); ho += 2; ho += titleLen;
    uint16_t isaLen = leU16Rm(&hb[ho]); ho += 2; ho += isaLen;
    uint16_t extrasLen = leU16Rm(&hb[ho]); ho += 2;
    PASS(extrasLen == 16u,
         "5.3 raman wire: modality_extras_length == 16 (8B excitation + 8B power)");
    double excitation = leF64Rm(&hb[ho]); ho += 8;
    double laserPower = leF64Rm(&hb[ho]); ho += 8;
    PASS(excitation == 785.0, "5.3 raman wire: excitation_wavelength_nm");
    PASS(laserPower == 50.0,  "5.3 raman wire: laser_power_mw");
    PASS(ho == hdr.length, "5.3 raman wire: no trailing bytes");
}

// -------- 2. round-trip via writeTtioToPath: -> reopen RamanImage ----------

static void testRamanImageRoundTrip(void)
{
    TTIORamanImage *img = buildRamanFixture();
    // Persist as a .tio so the writer can read it through the dataset.
    NSString *srcPath = makeRamanTempPath(@"rt-src");
    unlink([srcPath fileSystemRepresentation]);
    NSError *err = nil;
    PASS([img writeToFilePath:srcPath error:&err] && err == nil,
         "5.3 raman rt: source .tio written");

    TTIOSpectralDataset *ds = [TTIOSpectralDataset readFromFilePath:srcPath
                                                                error:&err];
    PASS(ds != nil && ds.ramanImage != nil,
         "5.3 raman rt: source dataset carries RamanImage");

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"raman_fixture"
                               isaInvestigation:@""
                                       features:@[TTIOTransportV011Feature]
                                      nDatasets:0
                                          error:&err],
         "5.3 raman rt: StreamHeader");
    PASS([w writeRamanImage:ds.ramanImage error:&err],
         "5.3 raman rt: writeRamanImage");
    PASS([w writeEndOfStreamWithError:&err], "5.3 raman rt: EndOfStream");

    NSString *rtPath = makeRamanTempPath(@"rt");
    unlink([rtPath fileSystemRepresentation]);
    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:buf];
    PASS([r writeTtioToPath:rtPath error:&err] && err == nil,
         "5.3 raman rt: writeTtioToPath materialised");

    TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:rtPath
                                                                error:&err];
    PASS(rt != nil && rt.ramanImage != nil,
         "5.3 raman rt: round-tripped dataset carries RamanImage");
    TTIORamanImage *back = rt.ramanImage;
    PASS(back.width == img.width
        && back.height == img.height
        && back.spectralPoints == img.spectralPoints,
         "5.3 raman rt: dims match");
    PASS(back.excitationWavelengthNm == img.excitationWavelengthNm,
         "5.3 raman rt: excitation_wavelength_nm round-trip");
    PASS(back.laserPowerMw == img.laserPowerMw,
         "5.3 raman rt: laser_power_mw round-trip");
    PASS([back.cube isEqualToData:img.cube],
         "5.3 raman rt: cube byte-equal");
    PASS([back.wavenumbers isEqualToData:img.wavenumbers],
         "5.3 raman rt: wavenumbers byte-equal");
    // The materialised .tio carries only Raman; MS/IR remain absent.
    PASS(rt.irImage == nil,
         "5.3 raman rt: irImage stays nil");

    [ds closeFile];
    [rt closeFile];
    unlink([srcPath fileSystemRepresentation]);
    unlink([rtPath fileSystemRepresentation]);
}

// -------- 3. unknown modality (99) is logged + skipped ---------------------

static void testReaderSkipsUnknownModality(void)
{
    // Hand-roll the IMAGE_HEADER for modality=99 + a single dummy
    // pixel + END_OF_IMAGE via the writer's low-level emitPacket
    // API. The writer doesn't expose emitPacket directly — synthesise
    // by patching a Raman stream's IMAGE_HEADER modality byte to 99.
    TTIORamanImage *img = buildRamanFixture();

    NSMutableData *buf = [NSMutableData data];
    TTIOTransportWriter *w =
        [[TTIOTransportWriter alloc] initWithMutableData:buf];
    NSError *err = nil;
    PASS([w writeStreamHeaderWithFormatVersion:@"1.2"
                                          title:@"unknown_mod"
                               isaInvestigation:@""
                                       features:@[]
                                      nDatasets:0
                                          error:&err],
         "5.3 unknown: StreamHeader");
    PASS([w writeRamanImage:img error:&err],
         "5.3 unknown: wrote Raman image (will patch modality)");
    PASS([w writeEndOfStreamWithError:&err], "5.3 unknown: EndOfStream");

    // Locate the IMAGE_HEADER payload's first byte (the modality)
    // and flip it from 1 to 99. The IMAGE_HEADER payload starts
    // with `modality(u8)=1 + width(u32 LE)=3 + height(u32 LE)=3 +
    // spectrum_bins(u32 LE)=4`, so the byte pattern is
    // 01 03 00 00 00 03 00 00 00 04 00 00 00 ...
    NSMutableData *mut = [buf mutableCopy];
    uint8_t *p = mut.mutableBytes;
    NSUInteger n = mut.length;
    NSUInteger headerOff = NSNotFound;
    for (NSUInteger i = 0; i + 13 <= n; i++) {
        if (p[i]   == 0x01 && p[i+1] == 0x03 && p[i+2] == 0x00
         && p[i+3] == 0x00 && p[i+4] == 0x00 && p[i+5] == 0x03
         && p[i+6] == 0x00 && p[i+7] == 0x00 && p[i+8] == 0x00
         && p[i+9] == 0x04 && p[i+10] == 0x00 && p[i+11] == 0x00
         && p[i+12] == 0x00) {
            headerOff = i;
            break;
        }
    }
    PASS(headerOff != NSNotFound,
         "5.3 unknown: located Raman IMAGE_HEADER modality byte");
    if (headerOff != NSNotFound) {
        p[headerOff] = 99u;
    }

    NSString *outPath = makeRamanTempPath(@"unknown");
    unlink([outPath fileSystemRepresentation]);
    TTIOTransportReader *r = [[TTIOTransportReader alloc] initWithData:mut];
    BOOL ok = [r writeTtioToPath:outPath error:&err];
    PASS(ok && err == nil,
         "5.3 unknown: reader accepts stream (skipping unknown modality)");

    // The materialised .tio has no Raman image (the unknown-modality
    // block was skipped).
    TTIOSpectralDataset *rt = [TTIOSpectralDataset readFromFilePath:outPath
                                                                error:&err];
    PASS(rt != nil, "5.3 unknown: re-opened materialised");
    PASS(rt.ramanImage == nil,
         "5.3 unknown: unknown-modality stream produces no RamanImage");
    PASS(rt.irImage == nil,
         "5.3 unknown: unknown-modality stream produces no IRImage");
    // msImage's placeholder semantics — check width==0.
    PASS(rt.msImage == nil || rt.msImage.width == 0,
         "5.3 unknown: unknown-modality stream produces no MSImage cube");

    [rt closeFile];
    unlink([outPath fileSystemRepresentation]);
}

// -------- entry point ------------------------------------------------------

void testTransportRamanImage(void);
void testTransportRamanImage(void)
{
    testRamanImageWireLayout();
    testRamanImageRoundTrip();
    testReaderSkipsUnknownModality();
}
