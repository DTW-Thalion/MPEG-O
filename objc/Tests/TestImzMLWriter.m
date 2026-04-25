/*
 * TestImzMLWriter — v0.9+ imzML exporter round-trip + layout tests.
 *
 * Mirrors the Python suite (tests/test_imzml_writer.py); every
 * assertion here has a matching assertion there so byte-parity
 * regressions surface at the per-language test layer.
 */
#import <Foundation/Foundation.h>
#import "Testing.h"
#import <unistd.h>
#import <openssl/sha.h>

#import "Export/TTIOImzMLWriter.h"
#import "Import/TTIOImzMLReader.h"


static NSString *tmpImzML(NSString *suffix) {
    return [NSString stringWithFormat:@"/tmp/ttio_imzml_writer_%d_%@.imzML",
            (int)getpid(), suffix];
}

static NSData *doublesToData(const double *values, NSUInteger count) {
    return [NSData dataWithBytes:values length:count * sizeof(double)];
}

static TTIOImzMLPixelSpectrum *makePixel(NSInteger x, NSInteger y,
                                          const double *mz, NSUInteger mzN,
                                          const double *inten, NSUInteger intN) {
    NSError *err = nil;
    TTIOImzMLPixelSpectrum *p =
        [[TTIOImzMLPixelSpectrum alloc] initWithX:x y:y z:1
                                             mzArray:doublesToData(mz, mzN)
                                      intensityArray:doublesToData(inten, intN)
                                               error:&err];
    return p;
}

void testImzMLWriter(void) {
    @autoreleasepool {
        // ── Continuous mode round-trip ─────────────────────────────────
        NSString *cPath = tmpImzML(@"cont");
        unlink([cPath fileSystemRepresentation]);
        unlink([[[cPath stringByDeletingPathExtension] stringByAppendingPathExtension:@"ibd"]
                fileSystemRepresentation]);

        double mz[128];
        for (int i = 0; i < 128; i++) mz[i] = 100.0 + i * (800.0 / 127.0);
        double in1[128], in2[128], in3[128], in4[128];
        for (int i = 0; i < 128; i++) {
            in1[i] = (double)i;
            in2[i] = (double)i + 10.0;
            in3[i] = (double)i + 20.0;
            in4[i] = (double)i + 30.0;
        }

        NSArray *pixels = @[
            makePixel(1, 1, mz, 128, in1, 128),
            makePixel(2, 1, mz, 128, in2, 128),
            makePixel(1, 2, mz, 128, in3, 128),
            makePixel(2, 2, mz, 128, in4, 128),
        ];

        NSError *err = nil;
        TTIOImzMLWriteResult *res = [TTIOImzMLWriter
            writePixels:pixels
            toImzMLPath:cPath
                ibdPath:nil
                   mode:@"continuous"
              gridMaxX:2 gridMaxY:2 gridMaxZ:1
             pixelSizeX:50.0 pixelSizeY:50.0
             scanPattern:@"flyback"
                uuidHex:nil
                  error:&err];
        PASS(res != nil, "imzML writer continuous-mode succeeds");
        PASS([res.mode isEqualToString:@"continuous"], "continuous mode preserved");
        PASS(res.nPixels == 4, "4 pixels written");
        PASS(res.uuidHex.length == 32, "UUID is 32 hex chars");

        // Round-trip via our reader.
        TTIOImzMLImport *imp = [TTIOImzMLReader readFromImzMLPath:cPath
                                                          ibdPath:nil
                                                            error:&err];
        PASS(imp != nil, "TTIOImzMLReader re-parses writer output");
        PASS([imp.mode isEqualToString:@"continuous"], "mode continuous round-trips");
        PASS([imp.uuidHex isEqualToString:res.uuidHex], "UUID round-trips");
        PASS(imp.gridMaxX == 2 && imp.gridMaxY == 2, "grid extents round-trip");
        PASS(imp.pixelSizeX == 50.0 && imp.pixelSizeY == 50.0, "pixel sizes round-trip");
        PASS(imp.spectra.count == 4, "4 pixels after re-read");
        if (imp.spectra.count == 4) {
            TTIOImzMLPixelSpectrum *p0 = imp.spectra[0];
            PASS(p0.mzCount == 128, "pixel 0 has 128 mz points");
            const double *csmz = p0.mzArray.bytes;
            const double *csin = p0.intensityArray.bytes;
            PASS(csmz[0] == 100.0, "shared mz[0] round-trips exactly");
            PASS(csin[0] == 0.0, "pixel 0 intensity[0] round-trips exactly");
            TTIOImzMLPixelSpectrum *p1 = imp.spectra[1];
            const double *p1in = p1.intensityArray.bytes;
            PASS(p1in[0] == 10.0, "pixel 1 intensity[0] round-trips exactly");
        }
        unlink([cPath fileSystemRepresentation]);

        // ── Processed mode round-trip ──────────────────────────────────
        NSString *pPath = tmpImzML(@"proc");
        unlink([pPath fileSystemRepresentation]);
        double m0[] = {100, 200, 300};
        double i0[] = {1, 2, 3};
        double m1[] = {100, 200, 300, 400};
        double i1[] = {4, 5, 6, 7};
        NSArray *ppixels = @[
            makePixel(1, 1, m0, 3, i0, 3),
            makePixel(2, 1, m1, 4, i1, 4),
        ];
        err = nil;
        TTIOImzMLWriteResult *pres = [TTIOImzMLWriter
            writePixels:ppixels
            toImzMLPath:pPath ibdPath:nil mode:@"processed"
              gridMaxX:0 gridMaxY:0 gridMaxZ:0
             pixelSizeX:0.0 pixelSizeY:0.0
             scanPattern:@"flyback"
                uuidHex:nil error:&err];
        PASS(pres != nil, "processed-mode writer succeeds");
        TTIOImzMLImport *pimp = [TTIOImzMLReader readFromImzMLPath:pPath
                                                            ibdPath:nil
                                                              error:&err];
        PASS(pimp != nil, "processed-mode round-trip parses");
        PASS([pimp.mode isEqualToString:@"processed"], "processed mode preserved");
        PASS(pimp.gridMaxX == 2 && pimp.gridMaxY == 1,
             "grid extents derived from pixel coordinates");
        PASS(pimp.spectra.count == 2, "2 processed pixels");
        if (pimp.spectra.count == 2) {
            PASS(pimp.spectra[0].mzCount == 3, "pixel 0 has 3 mz points");
            PASS(pimp.spectra[1].mzCount == 4, "pixel 1 has 4 mz points");
        }
        unlink([pPath fileSystemRepresentation]);

        // ── Continuous mode rejects divergent mz axis ──────────────────
        double mdiv[128];
        memcpy(mdiv, mz, sizeof(mz));
        mdiv[0] = 99.9;
        NSArray *badPixels = @[
            makePixel(1, 1, mz,    128, in1, 128),
            makePixel(2, 1, mdiv,  128, in2, 128),
        ];
        err = nil;
        TTIOImzMLWriteResult *badRes = [TTIOImzMLWriter
            writePixels:badPixels
            toImzMLPath:tmpImzML(@"bad") ibdPath:nil
                   mode:@"continuous"
              gridMaxX:0 gridMaxY:0 gridMaxZ:0
             pixelSizeX:0.0 pixelSizeY:0.0
             scanPattern:@"flyback" uuidHex:nil error:&err];
        PASS(badRes == nil, "continuous mode rejects divergent mz axis");
        PASS(err != nil, "error populated on divergent axis");

        // ── UUID normalisation ─────────────────────────────────────────
        NSString *uPath = tmpImzML(@"uuid");
        double uu[] = {100, 200};
        double ui[] = {1, 2};
        NSArray *upixels = @[ makePixel(1, 1, uu, 2, ui, 2) ];
        err = nil;
        TTIOImzMLWriteResult *ures = [TTIOImzMLWriter
            writePixels:upixels toImzMLPath:uPath ibdPath:nil
                   mode:@"processed"
              gridMaxX:0 gridMaxY:0 gridMaxZ:0
             pixelSizeX:0.0 pixelSizeY:0.0
             scanPattern:@"flyback"
                uuidHex:@"{11223344-5566-7788-99AA-BBCCDDEEFF00}"
                  error:&err];
        PASS(ures != nil, "UUID with braces/dashes accepted");
        PASS([ures.uuidHex isEqualToString:@"112233445566778899aabbccddeeff00"],
             "UUID normalised to 32 lowercase hex chars");
        unlink([uPath fileSystemRepresentation]);
    }
}
