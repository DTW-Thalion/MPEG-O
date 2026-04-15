#import <Foundation/Foundation.h>
#import "Testing.h"
#import "Core/MPGOSignalArray.h"
#import "Spectra/MPGOSpectrum.h"
#import "Spectra/MPGOMassSpectrum.h"
#import "Spectra/MPGONMRSpectrum.h"
#import "Spectra/MPGONMR2DSpectrum.h"
#import "Spectra/MPGOFreeInductionDecay.h"
#import "Spectra/MPGOChromatogram.h"
#import "ValueClasses/MPGOEncodingSpec.h"
#import "ValueClasses/MPGOAxisDescriptor.h"
#import "ValueClasses/MPGOValueRange.h"
#import "ValueClasses/MPGOEnums.h"
#import "HDF5/MPGOHDF5File.h"
#import "HDF5/MPGOHDF5Group.h"
#import "HDF5/MPGOHDF5Errors.h"
#import <math.h>
#import <unistd.h>

static NSString *spath(NSString *suffix)
{
    return [NSString stringWithFormat:@"/tmp/mpgo_test_spec_%d_%@.mpgo",
            (int)getpid(), suffix];
}

static MPGOSignalArray *float64ArrayWithValues(const double *src, NSUInteger n)
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

void testSpectra(void)
{
    // ---- 200-peak centroided MassSpectrum round-trip ----
    {
        const NSUInteger N = 200;
        double *mz   = malloc(N * sizeof(double));
        double *intn = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) {
            mz[i]   = 100.0 + (double)i * 4.5;
            intn[i] = 1.0e6 * (1.0 + sin((double)i * 0.1));
        }
        MPGOSignalArray *mzA = float64ArrayWithValues(mz, N);
        MPGOSignalArray *inA = float64ArrayWithValues(intn, N);
        free(mz); free(intn);

        NSError *err = nil;
        MPGOMassSpectrum *ms =
            [[MPGOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:1
                                             polarity:MPGOPolarityPositive
                                           scanWindow:[MPGOValueRange rangeWithMinimum:50 maximum:2000]
                                        indexPosition:42
                                      scanTimeSeconds:123.456
                                          precursorMz:0
                                      precursorCharge:0
                                                error:&err];
        PASS(ms != nil, "MPGOMassSpectrum constructible with matched arrays");
        PASS(err == nil, "no error on construction");
        PASS(ms.msLevel == 1, "ms_level stored");
        PASS(ms.polarity == MPGOPolarityPositive, "polarity stored");
        PASS(ms.mzArray.length == 200, "mz length retained");

        NSString *path = spath(@"ms");
        unlink([path fileSystemRepresentation]);
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([ms writeToGroup:[f rootGroup] name:@"spec" error:&err],
             "200-peak MassSpectrum writes to HDF5");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOMassSpectrum *back =
            [MPGOMassSpectrum readFromGroup:[g rootGroup] name:@"spec" error:&err];
        PASS(back != nil, "200-peak MassSpectrum reads back");
        PASS([back isKindOfClass:[MPGOMassSpectrum class]], "decoded is MPGOMassSpectrum");
        PASS(back.mzArray.length == 200 && back.intensityArray.length == 200,
             "200-peak arrays preserved");
        PASS(back.msLevel == 1, "msLevel round-trips");
        PASS(back.polarity == MPGOPolarityPositive, "polarity round-trips");
        PASS(back.scanWindow.maximum == 2000, "scanWindow.max round-trips");
        PASS(back.indexPosition == 42, "indexPosition round-trips");
        PASS(fabs(back.scanTimeSeconds - 123.456) < 1e-12, "scanTime round-trips");
        PASS([back isEqual:ms], "200-peak MassSpectrum isEqual: original after round-trip");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- mismatched mz/intensity → nil + error ----
    {
        double mz[3] = {1, 2, 3};
        double in[2] = {10, 20};
        MPGOSignalArray *mzA = float64ArrayWithValues(mz, 3);
        MPGOSignalArray *inA = float64ArrayWithValues(in, 2);
        NSError *err = nil;
        MPGOMassSpectrum *ms =
            [[MPGOMassSpectrum alloc] initWithMzArray:mzA
                                       intensityArray:inA
                                              msLevel:1
                                             polarity:MPGOPolarityPositive
                                           scanWindow:nil
                                        indexPosition:0
                                      scanTimeSeconds:0
                                          precursorMz:0
                                      precursorCharge:0
                                                error:&err];
        PASS(ms == nil, "mismatched mz/intensity construction returns nil");
        PASS(err != nil, "mismatched construction populates NSError");
        PASS(err.code == MPGOErrorInvalidArgument, "error code is InvalidArgument");
    }

    // ---- 32768-point NMR FID round-trip with real/imag intact ----
    {
        const NSUInteger N = 32768;
        double *cplx = malloc(N * 2 * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) {
            double t = (double)i * 1e-4;
            cplx[2*i]     = exp(-t * 5.0) * cos(t * 1000.0);
            cplx[2*i + 1] = exp(-t * 5.0) * sin(t * 1000.0);
        }
        NSData *buf = [NSData dataWithBytes:cplx length:N*2*sizeof(double)];

        MPGOFreeInductionDecay *fid =
            [[MPGOFreeInductionDecay alloc] initWithComplexBuffer:buf
                                                     complexLength:N
                                                  dwellTimeSeconds:1e-4
                                                         scanCount:16
                                                      receiverGain:42.5];
        PASS(fid.length == N, "FID length = number of complex points");

        NSString *path = spath(@"fid");
        NSError *err = nil;
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([fid writeToGroup:[f rootGroup]
                          name:@"fid"
                     chunkSize:4096
              compressionLevel:0
                         error:&err],
             "32768-point FID writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGOFreeInductionDecay *back =
            [MPGOFreeInductionDecay readFromGroup:[g rootGroup] name:@"fid" error:&err];
        PASS(back != nil, "32768-point FID reads");
        PASS(back.length == N, "FID length preserved");
        PASS(back.scanCount == 16, "scanCount round-trips");
        PASS(fabs(back.dwellTimeSeconds - 1e-4) < 1e-18, "dwellTime round-trips");
        PASS(back.receiverGain == 42.5, "receiverGain round-trips");
        PASS([back.buffer isEqualToData:buf], "FID real/imag bytes byte-exact");
        PASS([back isEqual:fid], "FID isEqual: original after round-trip");
        free(cplx);
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 512×1024 2D NMR matrix round-trip ----
    {
        const NSUInteger W = 1024, H = 512;
        const NSUInteger total = W * H;
        double *mat = malloc(total * sizeof(double));
        for (NSUInteger i = 0; i < total; i++) mat[i] = (double)(i % 997) * 0.001;
        NSData *matData = [NSData dataWithBytes:mat length:total * sizeof(double)];

        MPGOAxisDescriptor *f1 =
            [MPGOAxisDescriptor descriptorWithName:@"F1"
                                              unit:@"ppm"
                                        valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:200]
                                      samplingMode:MPGOSamplingModeUniform];
        MPGOAxisDescriptor *f2 =
            [MPGOAxisDescriptor descriptorWithName:@"F2"
                                              unit:@"ppm"
                                        valueRange:[MPGOValueRange rangeWithMinimum:0 maximum:12]
                                      samplingMode:MPGOSamplingModeUniform];
        NSError *err = nil;
        MPGONMR2DSpectrum *nmr2d =
            [[MPGONMR2DSpectrum alloc] initWithIntensityMatrix:matData
                                                          width:W
                                                         height:H
                                                         f1Axis:f1
                                                         f2Axis:f2
                                                      nucleusF1:@"13C"
                                                      nucleusF2:@"1H"
                                                  indexPosition:0
                                                          error:&err];
        PASS(nmr2d != nil, "2D NMR constructible");

        NSString *path = spath(@"nmr2d");
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([nmr2d writeToGroup:[f rootGroup] name:@"hsqc" error:&err],
             "512x1024 2D NMR writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGONMR2DSpectrum *back =
            [MPGONMR2DSpectrum readFromGroup:[g rootGroup] name:@"hsqc" error:&err];
        PASS(back != nil, "2D NMR reads back");
        PASS(back.width == W && back.height == H, "matrix dimensions preserved");
        PASS([back.intensityMatrix isEqualToData:matData], "matrix bytes byte-exact");
        PASS([back.nucleusF1 isEqualToString:@"13C"], "nucleusF1 round-trips");
        PASS([back.nucleusF2 isEqualToString:@"1H"], "nucleusF2 round-trips");
        free(mat);
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- 1D NMR spectrum round-trip ----
    {
        const NSUInteger N = 1024;
        double *cs   = malloc(N * sizeof(double));
        double *intn = malloc(N * sizeof(double));
        for (NSUInteger i = 0; i < N; i++) {
            cs[i]   = (double)i * 0.01;
            intn[i] = sin((double)i * 0.05);
        }
        MPGOSignalArray *csA = float64ArrayWithValues(cs, N);
        MPGOSignalArray *inA = float64ArrayWithValues(intn, N);
        free(cs); free(intn);

        NSError *err = nil;
        MPGONMRSpectrum *nmr =
            [[MPGONMRSpectrum alloc] initWithChemicalShiftArray:csA
                                                  intensityArray:inA
                                                     nucleusType:@"1H"
                                        spectrometerFrequencyMHz:600.13
                                                   indexPosition:7
                                                 scanTimeSeconds:0
                                                           error:&err];
        PASS(nmr != nil, "1D NMR constructible");

        NSString *path = spath(@"nmr");
        MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
        PASS([nmr writeToGroup:[f rootGroup] name:@"proton" error:&err],
             "1D NMR writes");
        [f close];

        MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
        MPGONMRSpectrum *back =
            [MPGONMRSpectrum readFromGroup:[g rootGroup] name:@"proton" error:&err];
        PASS(back != nil, "1D NMR reads");
        PASS([back.nucleusType isEqualToString:@"1H"], "nucleusType round-trips");
        PASS(back.spectrometerFrequencyMHz == 600.13, "spectrometer freq round-trips");
        PASS(back.chemicalShiftArray.length == N, "CS array length preserved");
        PASS([back isEqual:nmr], "1D NMR isEqual: original");
        [g close];
        unlink([path fileSystemRepresentation]);
    }

    // ---- Chromatogram round-trip for each type ----
    {
        const NSUInteger N = 100;
        double *t = malloc(N * sizeof(double));
        double *i = malloc(N * sizeof(double));
        for (NSUInteger k = 0; k < N; k++) { t[k] = (double)k * 0.5; i[k] = (double)k; }
        MPGOSignalArray *tA = float64ArrayWithValues(t, N);
        MPGOSignalArray *iA = float64ArrayWithValues(i, N);
        free(t); free(i);

        struct { MPGOChromatogramType type; double tgt, prec, prod; const char *label; } cases[] = {
            { MPGOChromatogramTypeTIC, 0.0,  0.0,    0.0,    "TIC" },
            { MPGOChromatogramTypeXIC, 524.3, 0.0,   0.0,    "XIC" },
            { MPGOChromatogramTypeSRM, 0.0,  524.3, 396.2,  "SRM" },
        };
        for (int k = 0; k < 3; k++) {
            NSError *err = nil;
            MPGOChromatogram *ch =
                [[MPGOChromatogram alloc] initWithTimeArray:tA
                                             intensityArray:iA
                                                       type:cases[k].type
                                                   targetMz:cases[k].tgt
                                                precursorMz:cases[k].prec
                                                  productMz:cases[k].prod
                                                      error:&err];
            PASS(ch != nil, "chromatogram constructible");

            NSString *path = spath([NSString stringWithFormat:@"chrom_%s", cases[k].label]);
            MPGOHDF5File *f = [MPGOHDF5File createAtPath:path error:&err];
            PASS([ch writeToGroup:[f rootGroup] name:@"ch" error:&err],
                 "chromatogram writes");
            [f close];

            MPGOHDF5File *g = [MPGOHDF5File openReadOnlyAtPath:path error:&err];
            MPGOChromatogram *back =
                [MPGOChromatogram readFromGroup:[g rootGroup] name:@"ch" error:&err];
            PASS(back != nil, "chromatogram reads");
            PASS(back.type == cases[k].type, "chromatogram type round-trips");
            PASS(back.targetMz == cases[k].tgt, "targetMz round-trips");
            PASS(back.precursorProductMz == cases[k].prec, "precursor round-trips");
            PASS(back.productMz == cases[k].prod, "productMz round-trips");
            PASS([back isEqual:ch], "chromatogram isEqual: original");
            [g close];
            unlink([path fileSystemRepresentation]);
        }
    }
}
