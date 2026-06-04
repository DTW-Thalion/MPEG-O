/*
 * TestImageBase.m
 *
 * OIT1 fence test for the TTIOImage base-class extraction. Verifies:
 *  - byte-identical .tio round-trips for MS / Raman / IR images
 *    (the common props + the distinct per-subclass axis/fields),
 *  - each subclass is a kind of TTIOImage,
 *  - the polymorphic kind / spectralAxis / spectralAxisKind accessors.
 *
 * SPDX-License-Identifier: LGPL-3.0-or-later
 * Copyright (c) 2026 The Thalion Initiative
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Image/TTIOImage.h"
#import "Image/TTIOMSImage.h"
#import "Image/TTIORamanImage.h"
#import "Image/TTIOIRImage.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5Errors.h"
#import <unistd.h>

static NSString *baseImgPath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_imgbase_%d_%@.tio",
            (int)getpid(), suffix];
}

static NSData *makeCube(NSUInteger w, NSUInteger h, NSUInteger sp)
{
    NSMutableData *cube = [NSMutableData dataWithLength:w * h * sp * sizeof(double)];
    double *p = cube.mutableBytes;
    for (NSUInteger y = 0; y < h; y++)
        for (NSUInteger x = 0; x < w; x++)
            for (NSUInteger s = 0; s < sp; s++)
                p[(y * w + x) * sp + s] = (double)(x * 1000 + y * 13) + (double)s * 0.001;
    return cube;
}

static NSData *makeAxis(NSUInteger sp)
{
    NSMutableData *axis = [NSMutableData dataWithLength:sp * sizeof(double)];
    double *p = axis.mutableBytes;
    for (NSUInteger s = 0; s < sp; s++) p[s] = 100.0 + (double)s * 2.5;
    return axis;
}

void testImageBase(void)
{
    const NSUInteger W = 8, H = 6, SP = 4, TS = 32;
    NSData *cube = makeCube(W, H, SP);
    NSData *axis = makeAxis(SP);
    NSError *err = nil;

    // ---- MS ----
    {
        TTIOMSImage *img = [[TTIOMSImage alloc]
            initWithTitle:@"ms-title"
       isaInvestigationId:@"isa-ms"
          identifications:@[]
          quantifications:@[]
        provenanceRecords:@[]
                    width:W height:H spectralPoints:SP tileSize:TS
               pixelSizeX:1.5 pixelSizeY:2.5
              scanPattern:@"raster"
                     cube:cube mzAxis:axis];

        PASS([img isKindOfClass:[TTIOImage class]], "MSImage is a TTIOImage");
        PASS(img.kind == TTIOImageKindMS, "MSImage.kind == MS");
        PASS([img.spectralAxis isEqualToData:axis], "MSImage.spectralAxis == mzAxis");
        PASS(img.spectralAxisKind == TTIOSpectralAxisKindMZ, "MSImage.spectralAxisKind == MZ");

        NSString *path = baseImgPath(@"ms");
        unlink([path fileSystemRepresentation]);
        PASS([img writeToFilePath:path error:&err], "MS writes .tio");
        TTIOMSImage *back = [TTIOMSImage readFromFilePath:path error:&err];
        PASS(back != nil, "MS reads back");
        PASS([back.title isEqualToString:@"ms-title"], "MS title round-trips");
        PASS([back.isaInvestigationId isEqualToString:@"isa-ms"], "MS isaId round-trips");
        PASS(back.width == W && back.height == H && back.spectralPoints == SP,
             "MS dims round-trip");
        PASS(back.tileSize == TS, "MS tileSize round-trips");
        PASS(back.pixelSizeX == 1.5 && back.pixelSizeY == 2.5, "MS pixel sizes round-trip");
        PASS([back.scanPattern isEqualToString:@"raster"], "MS scanPattern round-trips");
        PASS([back.cube isEqualToData:cube], "MS cube bytes identical");
        PASS([back.mzAxis isEqualToData:axis], "MS mzAxis bytes identical");
        PASS([back.spectralAxis isEqualToData:axis], "MS spectralAxis bytes identical");
        PASS(back.kind == TTIOImageKindMS, "MS round-trip kind == MS");
        unlink([path fileSystemRepresentation]);
    }

    // ---- Raman ----
    {
        TTIORamanImage *img = [[TTIORamanImage alloc]
            initWithTitle:@"raman-title"
       isaInvestigationId:@"isa-raman"
          identifications:@[]
          quantifications:@[]
        provenanceRecords:@[]
                    width:W height:H spectralPoints:SP tileSize:TS
               pixelSizeX:3.0 pixelSizeY:4.0
              scanPattern:@"snake"
   excitationWavelengthNm:785.0 laserPowerMw:10.0
                     cube:cube wavenumbers:axis];

        PASS([img isKindOfClass:[TTIOImage class]], "RamanImage is a TTIOImage");
        PASS(img.kind == TTIOImageKindRaman, "RamanImage.kind == Raman");
        PASS([img.spectralAxis isEqualToData:axis], "RamanImage.spectralAxis == wavenumbers");
        PASS(img.spectralAxisKind == TTIOSpectralAxisKindWavenumber,
             "RamanImage.spectralAxisKind == Wavenumber");

        NSString *path = baseImgPath(@"raman");
        unlink([path fileSystemRepresentation]);
        PASS([img writeToFilePath:path error:&err], "Raman writes .tio");
        TTIORamanImage *back = [TTIORamanImage readFromFilePath:path error:&err];
        PASS(back != nil, "Raman reads back");
        PASS([back.title isEqualToString:@"raman-title"], "Raman title round-trips");
        PASS([back.isaInvestigationId isEqualToString:@"isa-raman"], "Raman isaId round-trips");
        PASS(back.width == W && back.height == H && back.spectralPoints == SP,
             "Raman dims round-trip");
        PASS(back.tileSize == TS, "Raman tileSize round-trips");
        PASS(back.pixelSizeX == 3.0 && back.pixelSizeY == 4.0, "Raman pixel sizes round-trip");
        PASS([back.scanPattern isEqualToString:@"snake"], "Raman scanPattern round-trips");
        PASS(back.excitationWavelengthNm == 785.0, "Raman excitation round-trips");
        PASS(back.laserPowerMw == 10.0, "Raman laser power round-trips");
        PASS([back.cube isEqualToData:cube], "Raman cube bytes identical");
        PASS([back.wavenumbers isEqualToData:axis], "Raman wavenumbers bytes identical");
        PASS([back.spectralAxis isEqualToData:axis], "Raman spectralAxis bytes identical");
        PASS(back.kind == TTIOImageKindRaman, "Raman round-trip kind == Raman");
        unlink([path fileSystemRepresentation]);
    }

    // ---- IR ----
    {
        TTIOIRImage *img = [[TTIOIRImage alloc]
            initWithTitle:@"ir-title"
       isaInvestigationId:@"isa-ir"
          identifications:@[]
          quantifications:@[]
        provenanceRecords:@[]
                    width:W height:H spectralPoints:SP tileSize:TS
               pixelSizeX:5.0 pixelSizeY:6.0
              scanPattern:@"raster"
                     mode:TTIOIRModeAbsorbance
          resolutionCmInv:4.0
                     cube:cube wavenumbers:axis];

        PASS([img isKindOfClass:[TTIOImage class]], "IRImage is a TTIOImage");
        PASS(img.kind == TTIOImageKindIR, "IRImage.kind == IR");
        PASS([img.spectralAxis isEqualToData:axis], "IRImage.spectralAxis == wavenumbers");
        PASS(img.spectralAxisKind == TTIOSpectralAxisKindWavenumber,
             "IRImage.spectralAxisKind == Wavenumber");

        NSString *path = baseImgPath(@"ir");
        unlink([path fileSystemRepresentation]);
        PASS([img writeToFilePath:path error:&err], "IR writes .tio");
        TTIOIRImage *back = [TTIOIRImage readFromFilePath:path error:&err];
        PASS(back != nil, "IR reads back");
        PASS([back.title isEqualToString:@"ir-title"], "IR title round-trips");
        PASS([back.isaInvestigationId isEqualToString:@"isa-ir"], "IR isaId round-trips");
        PASS(back.width == W && back.height == H && back.spectralPoints == SP,
             "IR dims round-trip");
        PASS(back.tileSize == TS, "IR tileSize round-trips");
        PASS(back.pixelSizeX == 5.0 && back.pixelSizeY == 6.0, "IR pixel sizes round-trip");
        PASS([back.scanPattern isEqualToString:@"raster"], "IR scanPattern round-trips");
        PASS(back.mode == TTIOIRModeAbsorbance, "IR mode round-trips");
        PASS(back.resolutionCmInv == 4.0, "IR resolution round-trips");
        PASS([back.cube isEqualToData:cube], "IR cube bytes identical");
        PASS([back.wavenumbers isEqualToData:axis], "IR wavenumbers bytes identical");
        PASS([back.spectralAxis isEqualToData:axis], "IR spectralAxis bytes identical");
        PASS(back.kind == TTIOImageKindIR, "IR round-trip kind == IR");
        unlink([path fileSystemRepresentation]);
    }
}
