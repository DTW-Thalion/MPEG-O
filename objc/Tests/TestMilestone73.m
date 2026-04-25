#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/TTIOSignalArray.h"
#import "Spectra/TTIORamanSpectrum.h"
#import "Spectra/TTIOIRSpectrum.h"
#import "Image/TTIORamanImage.h"
#import "Image/TTIOIRImage.h"
#import "ValueClasses/TTIOEncodingSpec.h"
#import "ValueClasses/TTIOEnums.h"
#import "HDF5/TTIOHDF5File.h"
#import "HDF5/TTIOHDF5Group.h"
#import "HDF5/TTIOHDF5Errors.h"
#import "Export/TTIOJcampDxWriter.h"
#import "Import/TTIOJcampDxReader.h"
#import <math.h>
#import <unistd.h>

static NSString *m73Path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/ttio_m73_%d_%@.tio",
            (int)getpid(), suffix];
}

static TTIOSignalArray *float64Arr(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    TTIOEncodingSpec *enc =
        [TTIOEncodingSpec specWithPrecision:TTIOPrecisionFloat64
                       compressionAlgorithm:TTIOCompressionZlib
                                  byteOrder:TTIOByteOrderLittleEndian];
    return [[TTIOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

void testMilestone73(void)
{
    // ---- 1024-point Raman spectrum round-trip ----
    {
        const NSUInteger N = 1024;
        double *wn   = malloc(N * sizeof(double));
        double *intn = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) {
            wn[i]   = 200.0 + (double)i * 2.0;           // 200..2246 cm^-1
            intn[i] = 1000.0 + 500.0 * sin((double)i * 0.05);
        }
        TTIOSignalArray *wnA = float64Arr(wn, N);
        TTIOSignalArray *inA = float64Arr(intn, N);
        free(wn); free(intn);

        NSError *err = nil;
        TTIORamanSpectrum *r =
            [[TTIORamanSpectrum alloc] initWithWavenumberArray:wnA
                                                 intensityArray:inA
                                         excitationWavelengthNm:785.0
                                                   laserPowerMw:10.0
                                             integrationTimeSec:1.5
                                                  indexPosition:3
                                                scanTimeSeconds:0
                                                          error:&err];
        PASS(r != nil, "TTIORamanSpectrum constructible");
        PASS(err == nil, "no error on construction");
        PASS(r.excitationWavelengthNm == 785.0, "excitation stored");
        PASS(r.laserPowerMw == 10.0, "laser power stored");
        PASS(r.integrationTimeSec == 1.5, "integration time stored");
        PASS(r.wavenumberArray.length == N, "wavenumber length retained");

        NSString *path = m73Path(@"raman");
        unlink([path fileSystemRepresentation]);
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        PASS([r writeToGroup:[f rootGroup] name:@"spec" error:&err],
             "Raman spectrum writes to HDF5");
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIORamanSpectrum *back =
            [TTIORamanSpectrum readFromGroup:[g rootGroup] name:@"spec" error:&err];
        PASS(back != nil, "Raman spectrum reads back");
        PASS([back isKindOfClass:[TTIORamanSpectrum class]], "decoded is TTIORamanSpectrum");
        PASS(back.wavenumberArray.length == N, "wavenumber length preserved");
        PASS(back.excitationWavelengthNm == 785.0, "excitation round-trips");
        PASS(back.laserPowerMw == 10.0, "laser power round-trips");
        PASS(back.integrationTimeSec == 1.5, "integration time round-trips");
        PASS([back isEqual:r], "Raman isEqual: original after round-trip");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- mismatched arrays → nil + error ----
    {
        double a[3] = {1, 2, 3}, b[2] = {10, 20};
        TTIOSignalArray *aA = float64Arr(a, 3), *bA = float64Arr(b, 2);
        NSError *err = nil;
        TTIORamanSpectrum *r =
            [[TTIORamanSpectrum alloc] initWithWavenumberArray:aA
                                                 intensityArray:bA
                                         excitationWavelengthNm:532
                                                   laserPowerMw:5
                                             integrationTimeSec:1
                                                  indexPosition:0
                                                scanTimeSeconds:0
                                                          error:&err];
        PASS(r == nil, "mismatched Raman construction returns nil");
        PASS(err != nil && err.code == TTIOErrorInvalidArgument,
             "error code is InvalidArgument");
    }

    // ---- 2048-point IR spectrum (absorbance) round-trip ----
    {
        const NSUInteger N = 2048;
        double *wn   = malloc(N * sizeof(double));
        double *intn = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) {
            wn[i]   = 400.0 + (double)i * 2.0;           // 400..4494 cm^-1
            intn[i] = 0.05 + 0.02 * cos((double)i * 0.03);
        }
        TTIOSignalArray *wnA = float64Arr(wn, N);
        TTIOSignalArray *inA = float64Arr(intn, N);
        free(wn); free(intn);

        NSError *err = nil;
        TTIOIRSpectrum *ir =
            [[TTIOIRSpectrum alloc] initWithWavenumberArray:wnA
                                              intensityArray:inA
                                                        mode:TTIOIRModeAbsorbance
                                             resolutionCmInv:4.0
                                               numberOfScans:32
                                               indexPosition:0
                                             scanTimeSeconds:0
                                                       error:&err];
        PASS(ir != nil, "TTIOIRSpectrum constructible");
        PASS(ir.mode == TTIOIRModeAbsorbance, "IR mode stored");
        PASS(ir.resolutionCmInv == 4.0, "IR resolution stored");
        PASS(ir.numberOfScans == 32, "IR number_of_scans stored");

        NSString *path = m73Path(@"ir");
        unlink([path fileSystemRepresentation]);
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        PASS([ir writeToGroup:[f rootGroup] name:@"spec" error:&err],
             "IR spectrum writes to HDF5");
        [f close];

        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOIRSpectrum *back =
            [TTIOIRSpectrum readFromGroup:[g rootGroup] name:@"spec" error:&err];
        PASS(back != nil, "IR spectrum reads back");
        PASS(back.mode == TTIOIRModeAbsorbance, "IR mode round-trips");
        PASS(back.resolutionCmInv == 4.0, "resolution round-trips");
        PASS(back.numberOfScans == 32, "number_of_scans round-trips");
        PASS([back isEqual:ir], "IR isEqual: original after round-trip");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- IR spectrum transmittance mode discrimination ----
    {
        double wn[4] = {1000, 1100, 1200, 1300};
        double tr[4] = {0.95, 0.80, 0.70, 0.85};
        TTIOSignalArray *wnA = float64Arr(wn, 4), *trA = float64Arr(tr, 4);
        NSError *err = nil;
        TTIOIRSpectrum *ir =
            [[TTIOIRSpectrum alloc] initWithWavenumberArray:wnA
                                              intensityArray:trA
                                                        mode:TTIOIRModeTransmittance
                                             resolutionCmInv:8.0
                                               numberOfScans:0
                                               indexPosition:0
                                             scanTimeSeconds:0
                                                       error:&err];
        NSString *path = m73Path(@"ir_trans");
        TTIOHDF5File *f = [TTIOHDF5File createAtPath:path error:&err];
        [ir writeToGroup:[f rootGroup] name:@"spec" error:&err];
        [f close];
        TTIOHDF5File *g = [TTIOHDF5File openReadOnlyAtPath:path error:&err];
        TTIOIRSpectrum *back =
            [TTIOIRSpectrum readFromGroup:[g rootGroup] name:@"spec" error:&err];
        PASS(back.mode == TTIOIRModeTransmittance,
             "IR transmittance mode round-trips");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 16x16x32 Raman imaging cube round-trip ----
    {
        const NSUInteger W = 16, H = 16, SP = 32;
        NSMutableData *cube = [NSMutableData dataWithLength:W*H*SP*sizeof(double)];
        double *p = cube.mutableBytes;
        for (NSUInteger y = 0; y < H; y++)
            for (NSUInteger x = 0; x < W; x++)
                for (NSUInteger s = 0; s < SP; s++)
                    p[(y*W + x)*SP + s] = (double)(x*100 + y*7) + s*0.01;

        NSMutableData *wn = [NSMutableData dataWithLength:SP*sizeof(double)];
        double *wp = wn.mutableBytes;
        for (NSUInteger s = 0; s < SP; s++) wp[s] = 200.0 + s * 50.0;

        TTIORamanImage *img =
            [[TTIORamanImage alloc] initWithWidth:W
                                            height:H
                                    spectralPoints:SP
                                          tileSize:8
                                              cube:cube
                                       wavenumbers:wn
                            excitationWavelengthNm:785.0
                                      laserPowerMw:15.0];
        PASS(img != nil, "16x16x32 RamanImage constructible");

        NSString *path = m73Path(@"raman_img");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([img writeToFilePath:path error:&err],
             "RamanImage writes to HDF5");

        TTIORamanImage *back = [TTIORamanImage readFromFilePath:path error:&err];
        PASS(back != nil, "RamanImage reads back");
        PASS(back.width == W && back.height == H && back.spectralPoints == SP,
             "Raman image dimensions round-trip");
        PASS([back.cube isEqualToData:cube], "Raman image cube bytes exact");
        PASS([back.wavenumbers isEqualToData:wn], "Raman wavenumbers bytes exact");
        PASS(back.excitationWavelengthNm == 785.0,
             "Raman image excitation round-trips");
        PASS(back.laserPowerMw == 15.0, "Raman image laser power round-trips");
        PASS([back isEqual:img], "RamanImage isEqual: original after round-trip");
        unlink([path fileSystemRepresentation]);
    }

    // ---- 8x8x64 IR imaging cube (absorbance) round-trip ----
    {
        const NSUInteger W = 8, H = 8, SP = 64;
        NSMutableData *cube = [NSMutableData dataWithLength:W*H*SP*sizeof(double)];
        double *p = cube.mutableBytes;
        for (NSUInteger i = 0; i < W*H*SP; i++) p[i] = (double)(i % 991) * 0.001;

        NSMutableData *wn = [NSMutableData dataWithLength:SP*sizeof(double)];
        double *wp = wn.mutableBytes;
        for (NSUInteger s = 0; s < SP; s++) wp[s] = 400.0 + s * 30.0;

        TTIOIRImage *img =
            [[TTIOIRImage alloc] initWithWidth:W
                                         height:H
                                 spectralPoints:SP
                                       tileSize:4
                                           cube:cube
                                    wavenumbers:wn
                                           mode:TTIOIRModeAbsorbance
                                resolutionCmInv:4.0];
        PASS(img != nil, "8x8x64 IRImage constructible");

        NSString *path = m73Path(@"ir_img");
        unlink([path fileSystemRepresentation]);
        NSError *err = nil;
        PASS([img writeToFilePath:path error:&err], "IRImage writes");

        TTIOIRImage *back = [TTIOIRImage readFromFilePath:path error:&err];
        PASS(back != nil, "IRImage reads back");
        PASS(back.width == W && back.height == H && back.spectralPoints == SP,
             "IR image dimensions round-trip");
        PASS([back.cube isEqualToData:cube], "IR cube bytes exact");
        PASS(back.mode == TTIOIRModeAbsorbance, "IR image mode round-trips");
        PASS(back.resolutionCmInv == 4.0, "IR resolution round-trips");
        PASS([back isEqual:img], "IRImage isEqual: original after round-trip");
        unlink([path fileSystemRepresentation]);
    }

    // ---- JCAMP-DX Raman round-trip (float-equal on intensity) ----
    {
        const NSUInteger N = 512;
        double *wn   = malloc(N * sizeof(double));
        double *intn = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) {
            wn[i]   = 100.0 + (double)i * 3.0;
            intn[i] = 500.0 + 100.0 * sin((double)i * 0.1);
        }
        TTIOSignalArray *wnA = float64Arr(wn, N), *inA = float64Arr(intn, N);

        NSError *err = nil;
        TTIORamanSpectrum *orig =
            [[TTIORamanSpectrum alloc] initWithWavenumberArray:wnA
                                                 intensityArray:inA
                                         excitationWavelengthNm:532.0
                                                   laserPowerMw:25.0
                                             integrationTimeSec:0.5
                                                  indexPosition:0
                                                scanTimeSeconds:0
                                                          error:&err];

        NSString *jdxPath = m73Path(@"raman.jdx");
        unlink([jdxPath fileSystemRepresentation]);
        PASS([TTIOJcampDxWriter writeRamanSpectrum:orig
                                             toPath:jdxPath
                                              title:@"Synthetic Raman"
                                              error:&err],
             "JCAMP-DX Raman writes");

        TTIOSpectrum *decoded = [TTIOJcampDxReader readSpectrumFromPath:jdxPath
                                                                   error:&err];
        PASS(decoded != nil, "JCAMP-DX Raman reads back");
        PASS([decoded isKindOfClass:[TTIORamanSpectrum class]],
             "JCAMP-DX Raman reader picks RamanSpectrum class");

        TTIORamanSpectrum *back = (TTIORamanSpectrum *)decoded;
        PASS(back.wavenumberArray.length == N,
             "JCAMP-DX Raman point count preserved");
        PASS(back.excitationWavelengthNm == 532.0,
             "JCAMP-DX Raman excitation round-trips");
        PASS(back.laserPowerMw == 25.0, "JCAMP-DX Raman laser power round-trips");
        PASS(back.integrationTimeSec == 0.5,
             "JCAMP-DX Raman integration time round-trips");

        // Float equality within 1 ULP-ish — %.10g has ~10 sig figs
        const double *oy = inA.buffer.bytes;
        const double *by = back.intensityArray.buffer.bytes;
        BOOL floatEqual = YES;
        for (NSUInteger i = 0; i < N; i++) {
            if (fabs(oy[i] - by[i]) > fabs(oy[i]) * 1e-9 + 1e-15) {
                floatEqual = NO; break;
            }
        }
        PASS(floatEqual, "JCAMP-DX Raman intensities float-equal after round-trip");
        free(wn); free(intn);
        unlink([jdxPath fileSystemRepresentation]);
    }

    // ---- JCAMP-DX IR round-trip (absorbance) ----
    {
        const NSUInteger N = 256;
        double *wn   = malloc(N * sizeof(double));
        double *ab   = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) {
            wn[i] = 400.0 + (double)i * 15.0;
            ab[i] = 0.1 + 0.05 * cos((double)i * 0.2);
        }
        TTIOSignalArray *wnA = float64Arr(wn, N), *abA = float64Arr(ab, N);

        NSError *err = nil;
        TTIOIRSpectrum *orig =
            [[TTIOIRSpectrum alloc] initWithWavenumberArray:wnA
                                              intensityArray:abA
                                                        mode:TTIOIRModeAbsorbance
                                             resolutionCmInv:2.0
                                               numberOfScans:64
                                               indexPosition:0
                                             scanTimeSeconds:0
                                                       error:&err];

        NSString *jdxPath = m73Path(@"ir.jdx");
        unlink([jdxPath fileSystemRepresentation]);
        PASS([TTIOJcampDxWriter writeIRSpectrum:orig
                                          toPath:jdxPath
                                           title:@"Synthetic IR"
                                           error:&err],
             "JCAMP-DX IR writes");

        TTIOSpectrum *decoded = [TTIOJcampDxReader readSpectrumFromPath:jdxPath
                                                                   error:&err];
        PASS([decoded isKindOfClass:[TTIOIRSpectrum class]],
             "JCAMP-DX IR reader picks IRSpectrum class");
        TTIOIRSpectrum *back = (TTIOIRSpectrum *)decoded;
        PASS(back.mode == TTIOIRModeAbsorbance,
             "JCAMP-DX IR mode picked from DATA TYPE=INFRARED ABSORBANCE");
        PASS(back.resolutionCmInv == 2.0, "JCAMP-DX IR resolution round-trips");
        PASS(back.numberOfScans == 64, "JCAMP-DX IR number_of_scans round-trips");
        PASS(back.wavenumberArray.length == N,
             "JCAMP-DX IR point count preserved");

        const double *oy = abA.buffer.bytes;
        const double *by = back.intensityArray.buffer.bytes;
        BOOL floatEqual = YES;
        for (NSUInteger i = 0; i < N; i++) {
            if (fabs(oy[i] - by[i]) > fabs(oy[i]) * 1e-9 + 1e-15) {
                floatEqual = NO; break;
            }
        }
        PASS(floatEqual, "JCAMP-DX IR intensities float-equal after round-trip");
        free(wn); free(ab);
        unlink([jdxPath fileSystemRepresentation]);
    }
}
