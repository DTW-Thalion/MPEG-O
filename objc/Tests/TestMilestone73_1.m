#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/MPGOSignalArray.h"
#import "Spectra/MPGORamanSpectrum.h"
#import "Spectra/MPGOIRSpectrum.h"
#import "Spectra/MPGOUVVisSpectrum.h"
#import "Spectra/MPGOTwoDimensionalCorrelationSpectrum.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOHDF5Errors.h"
#import "Import/MPGOJcampDxDecode.h"
#import "Import/MPGOJcampDxReader.h"
#import "Export/MPGOJcampDxWriter.h"
#import <math.h>
#import <unistd.h>

static NSString *m73_1Path(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_m73_1_%d_%@.jdx",
            (int)getpid(), suffix];
}

static MPGOSignalArray *float64Arr(const double *src, NSUInteger n)
{
    NSData *buf = [NSData dataWithBytes:src length:n * sizeof(double)];
    MPGOEncodingSpec *enc =
        [MPGOEncodingSpec specWithPrecision:MPGOPrecisionFloat64
                       compressionAlgorithm:MPGOCompressionZlib
                                  byteOrder:MPGOByteOrderLittleEndian];
    return [[MPGOSignalArray alloc] initWithBuffer:buf
                                            length:n
                                          encoding:enc
                                              axis:nil];
}

static BOOL floatsClose(const double *a, const double *b, NSUInteger n,
                        double relTol, double absTol)
{
    for (NSUInteger i = 0; i < n; i++) {
        if (fabs(a[i] - b[i]) > fabs(a[i]) * relTol + absTol) return NO;
    }
    return YES;
}

void testMilestone73_1(void)
{
    // ---- hasCompression: AFFN (with scientific notation) is NOT compressed ----
    {
        NSString *affn = @"1000 1.234e-05\n1001 2.345E+02\n1002 3.0";
        PASS(![MPGOJcampDxDecode hasCompression:affn],
             "AFFN with e/E is not flagged as compressed");
    }

    // ---- hasCompression: SQZ token IS detected ----
    {
        NSString *sqz = @"1000 A50\n1001 B25";
        PASS([MPGOJcampDxDecode hasCompression:sqz],
             "SQZ body is flagged as compressed");
    }

    // ---- hasCompression: DIF token IS detected ----
    {
        NSString *dif = @"1000 A50 J5\n1001 K3";
        PASS([MPGOJcampDxDecode hasCompression:dif],
             "DIF body is flagged as compressed");
    }

    // ---- decode SQZ-only line: expected Ys from known JCAMP sample ----
    {
        // Line: X  A0 B5 C3  →  Y values 10, 25, 33
        NSArray *lines = @[ @"1000 A0 B5 C3" ];
        NSMutableArray *xs = [NSMutableArray array], *ys = [NSMutableArray array];
        NSError *err = nil;
        BOOL ok = [MPGOJcampDxDecode decodeLines:lines
                                          firstx:1000
                                          deltax:1
                                         xfactor:1
                                         yfactor:1
                                           outXs:xs
                                           outYs:ys
                                           error:&err];
        PASS(ok, "SQZ-only decode succeeds");
        PASS(ys.count == 3, "SQZ-only decode yields 3 Y values");
        if (ys.count == 3) {
            PASS([ys[0] doubleValue] == 10.0, "SQZ A0 = 10");
            PASS([ys[1] doubleValue] == 25.0, "SQZ B5 = 25");
            PASS([ys[2] doubleValue] == 33.0, "SQZ C3 = 33");
        }
    }

    // ---- decode DIF with Y-check drop between lines ----
    {
        // Line 1: A50    (Y = 150)
        // Line 2: A50 J5 (first token = 150, Y-check drops it; then +15 → 165)
        NSArray *lines = @[ @"1000 A50", @"1001 A50 J5" ];
        NSMutableArray *xs = [NSMutableArray array], *ys = [NSMutableArray array];
        NSError *err = nil;
        BOOL ok = [MPGOJcampDxDecode decodeLines:lines
                                          firstx:1000
                                          deltax:1
                                         xfactor:1
                                         yfactor:1
                                           outXs:xs
                                           outYs:ys
                                           error:&err];
        PASS(ok, "DIF with Y-check decode succeeds");
        PASS(ys.count == 2, "Y-check drops duplicate first token");
        if (ys.count == 2) {
            PASS([ys[0] doubleValue] == 150.0, "DIF Y[0] = 150");
            PASS([ys[1] doubleValue] == 165.0, "DIF Y[1] = 165");
        }
    }

    // ---- decode DUP: repeats prior Y (count - 1) times ----
    {
        // A50 T  →  Y=150 total 3 times (T=3): [150, 150, 150]
        NSArray *lines = @[ @"1000 A50 T" ];
        NSMutableArray *xs = [NSMutableArray array], *ys = [NSMutableArray array];
        NSError *err = nil;
        BOOL ok = [MPGOJcampDxDecode decodeLines:lines
                                          firstx:1000
                                          deltax:1
                                         xfactor:1
                                         yfactor:1
                                           outXs:xs
                                           outYs:ys
                                           error:&err];
        PASS(ok, "DUP decode succeeds");
        PASS(ys.count == 3, "DUP expands to 3 Y values");
        if (ys.count == 3) {
            PASS([ys[0] doubleValue] == 150.0, "DUP Y[0] = 150");
            PASS([ys[1] doubleValue] == 150.0, "DUP Y[1] = 150 (repeat)");
            PASS([ys[2] doubleValue] == 150.0, "DUP Y[2] = 150 (repeat)");
        }
    }

    // ---- reader dispatch: compressed JCAMP-DX Raman body ----
    {
        NSString *jdx =
            @"##TITLE=compressed\n"
             "##JCAMP-DX=5.01\n"
             "##DATA TYPE=RAMAN SPECTRUM\n"
             "##XUNITS=1/CM\n"
             "##YUNITS=ARBITRARY UNITS\n"
             "##FIRSTX=1000\n"
             "##LASTX=1002\n"
             "##NPOINTS=3\n"
             "##XFACTOR=1\n"
             "##YFACTOR=1\n"
             "##XYDATA=(X++(Y..Y))\n"
             "1000 A0 B5 C3\n"
             "##END=\n";
        NSString *p = m73_1Path(@"raman_compressed");
        [jdx writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
        NSError *err = nil;
        id spec = [MPGOJcampDxReader readSpectrumFromPath:p error:&err];
        PASS(spec != nil, "compressed JCAMP-DX reads");
        PASS([spec isKindOfClass:[MPGORamanSpectrum class]],
             "compressed JCAMP-DX Raman classified correctly");
        MPGORamanSpectrum *r = (MPGORamanSpectrum *)spec;
        PASS(r.wavenumberArray.length == 3, "compressed decode yields 3 points");
        const double *ys = r.intensityArray.buffer.bytes;
        PASS(ys[0] == 10.0 && ys[1] == 25.0 && ys[2] == 33.0,
             "compressed Y values match SQZ table");
        const double *xs = r.wavenumberArray.buffer.bytes;
        PASS(xs[0] == 1000.0 && xs[1] == 1001.0 && xs[2] == 1002.0,
             "compressed X values reconstructed from FIRSTX/deltax");
        unlink([p fileSystemRepresentation]);
    }

    // ---- UVVisSpectrum construction + properties ----
    {
        const NSUInteger N = 4;
        double wl[4] = { 200, 250, 300, 400 };
        double ab[4] = { 0.1, 0.3, 0.5, 0.2 };
        MPGOSignalArray *wlA = float64Arr(wl, N);
        MPGOSignalArray *abA = float64Arr(ab, N);
        NSError *err = nil;
        MPGOUVVisSpectrum *uv =
            [[MPGOUVVisSpectrum alloc] initWithWavelengthArray:wlA
                                                absorbanceArray:abA
                                                   pathLengthCm:1.0
                                                        solvent:@"water"
                                                  indexPosition:0
                                                scanTimeSeconds:0
                                                          error:&err];
        PASS(uv != nil, "UVVisSpectrum constructible");
        PASS(err == nil, "no error on UVVisSpectrum construction");
        PASS(uv.wavelengthArray.length == N, "wavelength length retained");
        PASS(uv.absorbanceArray.length == N, "absorbance length retained");
        PASS(uv.pathLengthCm == 1.0, "path length stored");
        PASS([uv.solvent isEqualToString:@"water"], "solvent stored");
    }

    // ---- UVVisSpectrum mismatched lengths → nil + error ----
    {
        double a[3] = { 1, 2, 3 }, b[2] = { 0.1, 0.2 };
        MPGOSignalArray *aA = float64Arr(a, 3), *bA = float64Arr(b, 2);
        NSError *err = nil;
        MPGOUVVisSpectrum *uv =
            [[MPGOUVVisSpectrum alloc] initWithWavelengthArray:aA
                                                absorbanceArray:bA
                                                   pathLengthCm:0
                                                        solvent:@""
                                                  indexPosition:0
                                                scanTimeSeconds:0
                                                          error:&err];
        PASS(uv == nil, "mismatched UV-Vis returns nil");
        PASS(err != nil && err.code == MPGOErrorInvalidArgument,
             "mismatched UV-Vis error code is InvalidArgument");
    }

    // ---- JCAMP-DX UV-Vis round-trip (write + read) ----
    {
        const NSUInteger N = 64;
        double *wl = malloc(N * sizeof(double));
        double *ab = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) {
            wl[i] = 200.0 + (double)i * 5.0;   // 200..515 nm
            ab[i] = 0.2 + 0.1 * sin((double)i * 0.1);
        }
        MPGOSignalArray *wlA = float64Arr(wl, N);
        MPGOSignalArray *abA = float64Arr(ab, N);

        NSError *err = nil;
        MPGOUVVisSpectrum *orig =
            [[MPGOUVVisSpectrum alloc] initWithWavelengthArray:wlA
                                                absorbanceArray:abA
                                                   pathLengthCm:1.0
                                                        solvent:@"ethanol"
                                                  indexPosition:0
                                                scanTimeSeconds:0
                                                          error:&err];

        NSString *p = m73_1Path(@"uvvis");
        unlink([p fileSystemRepresentation]);
        PASS([MPGOJcampDxWriter writeUVVisSpectrum:orig
                                             toPath:p
                                              title:@"Synthetic UV-Vis"
                                              error:&err],
             "JCAMP-DX UV-Vis writes");

        id decoded = [MPGOJcampDxReader readSpectrumFromPath:p error:&err];
        PASS(decoded != nil, "JCAMP-DX UV-Vis reads back");
        PASS([decoded isKindOfClass:[MPGOUVVisSpectrum class]],
             "JCAMP-DX UV-Vis reader picks UVVisSpectrum class");
        MPGOUVVisSpectrum *back = (MPGOUVVisSpectrum *)decoded;
        PASS(back.wavelengthArray.length == N, "UV-Vis point count preserved");
        PASS(back.pathLengthCm == 1.0, "UV-Vis path length round-trips");
        PASS([back.solvent isEqualToString:@"ethanol"],
             "UV-Vis solvent round-trips");
        const double *by = back.absorbanceArray.buffer.bytes;
        PASS(floatsClose(ab, by, N, 1e-9, 1e-15),
             "UV-Vis absorbance float-equal after round-trip");
        free(wl); free(ab);
        unlink([p fileSystemRepresentation]);
    }

    // ---- TwoDimensionalCorrelationSpectrum construction ----
    {
        const NSUInteger SIZE = 4;
        double sync[16];
        double asyn[16];
        for (NSUInteger i = 0; i < SIZE * SIZE; i++) {
            sync[i] = (double)i;
            asyn[i] = (double)i * 0.5;
        }
        NSData *syncD = [NSData dataWithBytes:sync length:sizeof(sync)];
        NSData *asynD = [NSData dataWithBytes:asyn length:sizeof(asyn)];

        MPGOValueRange *axisRange =
            [MPGOValueRange rangeWithMinimum:0 maximum:(double)(SIZE - 1)];
        MPGOAxisDescriptor *axis =
            [[MPGOAxisDescriptor alloc] initWithName:@"wavenumber"
                                                 unit:@"1/cm"
                                           valueRange:axisRange
                                         samplingMode:MPGOSamplingModeNonUniform];

        NSError *err = nil;
        MPGOTwoDimensionalCorrelationSpectrum *cos =
            [[MPGOTwoDimensionalCorrelationSpectrum alloc]
                initWithSynchronousMatrix:syncD
                       asynchronousMatrix:asynD
                               matrixSize:SIZE
                             variableAxis:axis
                             perturbation:@"temperature"
                         perturbationUnit:@"K"
                           sourceModality:@"raman"
                            indexPosition:0
                                    error:&err];
        PASS(cos != nil, "2D-COS spectrum constructible");
        PASS(err == nil, "no error on 2D-COS construction");
        PASS(cos.matrixSize == SIZE, "matrixSize stored");
        PASS([cos.synchronousMatrix isEqualToData:syncD],
             "synchronous matrix stored");
        PASS([cos.asynchronousMatrix isEqualToData:asynD],
             "asynchronous matrix stored");
        PASS([cos.perturbation isEqualToString:@"temperature"],
             "perturbation stored");
        PASS([cos.perturbationUnit isEqualToString:@"K"],
             "perturbationUnit stored");
        PASS([cos.sourceModality isEqualToString:@"raman"],
             "sourceModality stored");
    }

    // ---- 2D-COS mismatched matrix length → nil + error ----
    {
        double s[16] = {0}, a[9] = {0}; // 4x4 sync but 3x3 asyn
        NSData *sD = [NSData dataWithBytes:s length:sizeof(s)];
        NSData *aD = [NSData dataWithBytes:a length:sizeof(a)];
        NSError *err = nil;
        MPGOTwoDimensionalCorrelationSpectrum *cos =
            [[MPGOTwoDimensionalCorrelationSpectrum alloc]
                initWithSynchronousMatrix:sD
                       asynchronousMatrix:aD
                               matrixSize:4
                             variableAxis:nil
                             perturbation:@""
                         perturbationUnit:@""
                           sourceModality:@""
                            indexPosition:0
                                    error:&err];
        PASS(cos == nil, "mismatched 2D-COS returns nil");
        PASS(err != nil && err.code == MPGOErrorInvalidArgument,
             "mismatched 2D-COS error code is InvalidArgument");
    }
}
